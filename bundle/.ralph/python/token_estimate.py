#!/usr/bin/env python3
"""Dependency-free token estimator for Ralph proxy and compaction telemetry."""

from __future__ import annotations

import sys
from typing import TextIO


def estimate_tokens(text: str) -> int:
    """Return a whitespace- and punctuation-aware token estimate.

    Words (ASCII letters, digits, underscore) are split into subword-sized
    chunks using a 4-character heuristic. Each punctuation symbol counts as one
    token. Whitespace is ignored. This tracks code more closely than len/4.
    """
    if not text:
        return 0

    total = 0
    index = 0
    length = len(text)
    while index < length:
        char = text[index]
        if char.isspace():
            index += 1
            continue
        if char.isalnum() or char == "_":
            end = index + 1
            while end < length and (text[end].isalnum() or text[end] == "_"):
                end += 1
            word_len = end - index
            total += max(1, (word_len + 3) // 4)
            index = end
            continue
        total += 1
        index += 1
    return total


def read_all(stream: TextIO) -> str:
    return stream.read()


def main(argv: list[str] | None = None) -> int:
    args = list(sys.argv[1:] if argv is None else argv)
    if args and args[0] in ("-h", "--help"):
        print("Usage: token_estimate.py [file]", file=sys.stderr)
        print("Estimate tokens from a file or stdin.", file=sys.stderr)
        return 0

    if args:
        with open(args[0], encoding="utf-8", errors="replace") as handle:
            text = handle.read()
    else:
        text = read_all(sys.stdin)

    print(estimate_tokens(text))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
