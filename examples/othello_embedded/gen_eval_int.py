#!/usr/bin/env python3
"""
gen_eval_int.py - eval_weights.h (double) -> eval_weights_int.h (int16)

The CPU has no floating point; double arithmetic runs in libgcc and was
a quarter of every evaluation. evaluate.c therefore uses these weights
scaled by EVAL_SCALE and rounded to integers. Run this again whenever
eval_weights.h is regenerated:

    python3 examples/othello_embedded/gen_eval_int.py
"""

import re
from pathlib import Path

SCALE = 1024    # EVAL_SCALE: an evaluation of 1 disc = 1024

here = Path(__file__).resolve().parent
src = (here / "eval_weights.h").read_text(encoding="utf-8")

rows = re.findall(r"/\* phase=\s*(\d+) \*/ \{([^}]*)\}", src)
assert len(rows) == 60, len(rows)

out = [
    "/* 自動生成ファイル: gen_eval_int.py で eval_weights.h から生成。手で編集しないこと。",
    f"   eval_weights.h の重みを EVAL_SCALE (= {SCALE}) 倍して整数に丸めたもの。",
    "   評価値も EVAL_SCALE 倍の整数になる (石 1 個の差 = EVAL_SCALE) */",
    "#ifndef EVAL_WEIGHTS_INT_H",
    "#define EVAL_WEIGHTS_INT_H",
    "",
    "#include <stdint.h>",
    "",
    "#define EVAL_N_PHASE 60",
    "#define EVAL_N_FEATURES 8",
    f"#define EVAL_SCALE {SCALE}",
    "",
    "static const int16_t EVAL_WEIGHTS_INT[EVAL_N_PHASE][EVAL_N_FEATURES + 1] = {",
]
for phase, body in rows:
    vals = [round(float(x) * SCALE) for x in body.split(",")]
    assert len(vals) == 9 and all(-32768 <= v <= 32767 for v in vals)
    out.append(f"    /* phase={int(phase):2d} */ {{ " + ", ".join(f"{v:6d}" for v in vals) + " },")
out += ["};", "", "#endif /* EVAL_WEIGHTS_INT_H */", ""]
(here / "eval_weights_int.h").write_text("\n".join(out), encoding="utf-8")
print("wrote eval_weights_int.h")
