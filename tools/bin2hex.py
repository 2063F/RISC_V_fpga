#!/usr/bin/env python3
"""
Convert a raw binary file into one 32-bit word per line in hex format.
This is useful for generating instruction-memory initialization files for the CPU.
"""

from __future__ import annotations

import argparse
import struct
from pathlib import Path


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Convert raw binary to one 32-bit word per line in hex format."
    )
    parser.add_argument("input", help="Input binary file")
    parser.add_argument(
        "output",
        nargs="?",
        help="Output hex file (defaults to stdout)",
    )
    args = parser.parse_args()

    data = Path(args.input).read_bytes()

    # Pad to a multiple of 4 bytes so the output is word-aligned.
    if len(data) % 4 != 0:
        data += b"\x00" * (4 - (len(data) % 4))

    words = []
    for i in range(0, len(data), 4):
        word = struct.unpack("<I", data[i : i + 4])[0]
        words.append(f"{word:08x}")

    output_text = "\n".join(words) + ("\n" if words else "")

    if args.output:
        Path(args.output).write_text(output_text, encoding="ascii")
    else:
        print(output_text, end="")


if __name__ == "__main__":
    main()
