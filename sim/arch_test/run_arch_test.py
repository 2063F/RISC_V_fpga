#!/usr/bin/env python3
"""
run_arch_test.py - Run riscv-arch-test 2.7.4 on the CPU in Icarus Verilog

    git clone --depth 1 --branch 2.7.4 \\
        https://github.com/riscv-non-isa/riscv-arch-test.git <suite>
    python3 sim/arch_test/run_arch_test.py <suite> [-j N] [test-name ...]

Each test is built with model_test.h and link.ld from this directory, run on
a one-hart cpu_top (tb_arch_test.v), and its signature compared with the
reference output that 2.7.4 ships. Later versions of the suite no longer ship
reference outputs (they are generated with the Sail model), which is why this
pins 2.7.4. Test names may be given as e.g. "add-01" to run a subset.

Covered: rv32i_m/I, M and privilege. Zifencei is left out: its test
rewrites an instruction and executes it, and this CPU fetches from ROM only.
Tests whose code does not fit in the 32 KB ROM (the branch tests and jal-01,
over 200 KB each) are split into parts that do, each part a run of the
test's cases, and every part's signature is checked against the reference.
A case too large for the ROM even on its own (some jal-01 cases jump over
hundreds of KB) is left out and counted in the result.

Where this directory has its own references/<test>.reference_output, it is
used instead of the suite's. Those are the misaligned branch/jump tests in
privilege: the shipped references assume the C extension, under which a
2-byte aligned target is legal, while this CPU (no C) must trap. Their trap
records (mcause 0, mepc = the jump, mtval = its target) were checked by hand.

arch_test.h of 2.7.4 contains "la x0, ..." (in TEST_JALR_OP), which current
binutils reject. The script builds against a copy in which that one LA is
an auipc/addi pair of the same size.
"""

from __future__ import annotations

import argparse
import concurrent.futures
import os
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO = HERE.parent.parent
SUITES = ["I", "M", "privilege"]

CC = "riscv64-unknown-elf-gcc"
OBJCOPY = "riscv64-unknown-elf-objcopy"
NM = "riscv64-unknown-elf-nm"


def run(cmd: list[str], **kw) -> subprocess.CompletedProcess:
    return subprocess.run(cmd, capture_output=True, text=True, **kw)


def build_sim(work: Path) -> Path:
    """Compile the testbench and the CPU once."""
    srcs = [str(p) for p in sorted((REPO / "src").glob("*.v"))]
    out = work / "tb_arch_test.vvp"
    r = run(["iverilog", "-I", str(REPO / "src"), "-s", "tb_arch_test", "-o", str(out),
             str(HERE / "tb_arch_test.v"), *srcs])
    if r.returncode != 0:
        sys.exit("iverilog failed:\n" + r.stdout + r.stderr)
    return out


def defines_for(src: Path) -> list[str]:
    """The `def NAME=True` entries of the test's RVTEST_CASE strings
    (TEST_CASE_1 is defined by arch_test.h itself)."""
    names = set(re.findall(r"def\s+(\w+)\s*=\s*True", src.read_text()))
    names.discard("TEST_CASE_1")
    return [f"-D{n}=True" for n in sorted(names)]


def patched_env(suite_root: Path, work: Path) -> Path:
    """A copy of the suite's env/ that current binutils accept."""
    env = work / "env"
    shutil.copytree(suite_root / "riscv-test-suite" / "env", env, dirs_exist_ok=True)
    h = env / "arch_test.h"
    text = h.read_text()
    old = "    LA(rd,5b                                 ) ;\\\n"
    new = ("    .option push; .option norelax              ;\\\n"
           "    6: auipc rd, %pcrel_hi(5b)                 ;\\\n"
           "    addi rd, rd, %pcrel_lo(6b)                 ;\\\n"
           "    .option pop                                ;\\\n")
    if old not in text:
        sys.exit("arch_test.h is not the 2.7.4 one (TEST_JALR_OP not found)")
    h.write_text(text.replace(old, new))
    return env


TOO_BIG = "does not fit in the 32 KB ROM"
UNWRITTEN = "deadbeef"      # what the signature area is filled with


def build_and_run(env_dir: Path, src: Path, defines: list[str], vvp: Path, d: Path):
    """Build one program and run it. Returns the signature words, TOO_BIG,
    or an error string starting with "BUILD FAILED" / "DID NOT HALT"."""
    d.mkdir(parents=True, exist_ok=True)
    elf, binf, hexf, sig = d / "t.elf", d / "t.bin", d / "t.hex", d / "t.sig"

    r = run([CC, "-march=rv32im_zicsr", "-mabi=ilp32", "-static", "-mcmodel=medany",
             "-nostdlib", "-nostartfiles", "-DXLEN=32",
             "-I", str(HERE), "-I", str(env_dir), *defines,
             "-T", str(HERE / "link.ld"), str(src), "-o", str(elf)])
    if r.returncode != 0 and TOO_BIG in r.stderr:
        return TOO_BIG
    if r.returncode != 0:
        return "BUILD FAILED: " + (r.stderr.strip().splitlines() or ["?"])[-1]
    run([OBJCOPY, "-O", "binary", str(elf), str(binf)])
    run([sys.executable, str(REPO / "tools" / "bin2hex.py"), str(binf), str(hexf)])

    syms = {}
    for line in run([NM, str(elf)]).stdout.splitlines():
        parts = line.split()
        if len(parts) == 3:
            syms[parts[2]] = parts[0]

    r = run(["vvp", "-n", str(vvp), f"+hex={hexf}", f"+halt={syms['rvmodel_halt']}",
             f"+begin={syms['begin_signature']}", f"+end={syms['end_signature']}",
             f"+sig={sig}"], timeout=600)
    if "HALTED" not in r.stdout:
        return "DID NOT HALT: " + (r.stdout.strip().splitlines() or ["no output"])[-1]
    return [w.lower() for w in sig.read_text().split()]


# -----------------------------------------------------------------------------
# Splitting a test that does not fit
# -----------------------------------------------------------------------------
# The test cases sit between "#ifdef TEST_CASE_1" and its "#endif", each
# starting at an "inst_<n>:" label and writing its results at fixed offsets
# from the current RVTEST_SIGBASE register. A part keeps everything around the
# cases, plus a run of consecutive cases preceded by the RVTEST_SIGBASE line
# in force where the run starts. The data section, and so the signature
# layout, is the same in every part; a word a part does not write keeps
# UNWRITTEN.

SIGBASE = re.compile(r"^\s*RVTEST_SIGBASE\(")
CASE = re.compile(r"^inst_\d+:")


def split_cases(text: str):
    lines = text.splitlines(keepends=True)
    first = next(i for i, l in enumerate(lines) if CASE.match(l))
    endif = next(i for i in range(first, len(lines)) if lines[i].startswith("#endif"))
    starts = [i for i in range(first, endif) if CASE.match(lines[i])]
    cases, sigbase = [], None
    for i in range(first):
        if SIGBASE.match(lines[i]):
            sigbase = lines[i]
    for k, a in enumerate(starts):
        b = starts[k + 1] if k + 1 < len(starts) else endif
        cases.append((sigbase, "".join(lines[a:b])))
        for l in lines[a:b]:
            if SIGBASE.match(l):
                sigbase = l
    return "".join(lines[:first]), cases, "".join(lines[endif:])


def run_split(env_dir, src, defines, vvp, d, want):
    head, cases, tail = split_cases(src.read_text())
    written = [False] * len(want)
    skipped, parts = [], 0
    todo = [(0, len(cases))]
    while todo:
        a, b = todo.pop()
        part = d / f"part_{a}_{b}"
        part.mkdir(parents=True, exist_ok=True)
        psrc = part / src.name
        psrc.write_text(head + cases[a][0] + "".join(c for _, c in cases[a:b]) + tail)
        got = build_and_run(env_dir, psrc, defines, vvp, part)
        if got == TOO_BIG:
            if b - a == 1:
                skipped.append(a)
            else:
                m = (a + b) // 2
                todo += [(m, b), (a, m)]
            continue
        if isinstance(got, str):
            return f"{got} (cases {a}..{b - 1})"
        if len(got) != len(want):
            return f"FAIL: signature has {len(got)} words, reference {len(want)}"
        for i, (g, w) in enumerate(zip(got, want)):
            if g != UNWRITTEN:
                if g != w:
                    return (f"FAIL: word {i} is {g}, want {w} (cases {a}..{b - 1})")
                written[i] = True
        parts += 1
    missing = [i for i, w in enumerate(want) if w != UNWRITTEN and not written[i]]
    if missing and not skipped:
        return f"FAIL: word {missing[0]} never written"
    note = f"in {parts} parts"
    if skipped:
        return (f"PASS ({len(cases) - len(skipped)} of {len(cases)} cases {note}; "
                f"{len(skipped)} too large for the ROM even alone)")
    return f"PASS ({len(cases)} cases {note})"


def run_one(env_dir: Path, src: Path, ref: Path, vvp: Path, work: Path) -> tuple[str, str]:
    name = src.stem
    defines = defines_for(src)
    want = [w.lower() for w in ref.read_text().split()]

    got = build_and_run(env_dir, src, defines, vvp, work / name)
    if got == TOO_BIG:
        return name, run_split(env_dir, src, defines, vvp, work / name, want)
    if isinstance(got, str):
        return name, got
    if len(got) != len(want):
        return name, f"FAIL: signature has {len(got)} words, reference {len(want)}"
    bad = [i for i, (g, w) in enumerate(zip(got, want)) if g != w]
    if bad:
        i = bad[0]
        return name, (f"FAIL: {len(bad)} of {len(want)} words differ, first at word {i} "
                      f"(got {got[i]}, want {want[i]})")
    return name, "PASS"


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("suite", type=Path, help="riscv-arch-test 2.7.4 checkout")
    ap.add_argument("tests", nargs="*", help="run only these tests (e.g. add-01)")
    ap.add_argument("-j", type=int, default=os.cpu_count() or 1, help="parallel jobs")
    ap.add_argument("--keep", type=Path, help="keep the build files in this directory")
    args = ap.parse_args()

    base = args.suite.resolve() / "riscv-test-suite" / "rv32i_m"
    jobs = []
    for s in SUITES:
        for src in sorted((base / s / "src").glob("*.S")):
            if args.tests and src.stem not in args.tests:
                continue
            ref = HERE / "references" / (src.stem + ".reference_output")
            if not ref.exists():
                ref = base / s / "references" / (src.stem + ".reference_output")
            jobs.append((s, src, ref))
    if not jobs:
        sys.exit("no tests found - is this a riscv-arch-test 2.7.4 checkout?")

    tmp = None
    if args.keep:
        work = args.keep.resolve()
        work.mkdir(parents=True, exist_ok=True)
    else:
        tmp = tempfile.TemporaryDirectory()
        work = Path(tmp.name)

    vvp = build_sim(work)
    env_dir = patched_env(args.suite.resolve(), work)
    results = {}
    with concurrent.futures.ThreadPoolExecutor(max_workers=args.j) as ex:
        futs = {ex.submit(run_one, env_dir, src, ref, vvp, work / s): (s, src.stem)
                for s, src, ref in jobs}
        for f in concurrent.futures.as_completed(futs):
            s, _ = futs[f]
            name, status = f.result()
            results[(s, name)] = status

    failed = skipped = 0
    for (s, name), status in sorted(results.items()):
        print(f"{s:10s} {name:22s} {status}")
        skipped += status.startswith("SKIP")
        failed += not status.startswith(("PASS", "SKIP"))
    ran = len(results) - skipped
    print(f"\n{ran - failed} / {ran} passed, {skipped} skipped")
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
