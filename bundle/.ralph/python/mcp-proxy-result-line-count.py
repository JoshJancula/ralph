#!/usr/bin/env python3
"""Count lines in a file (minimum 1 when file is non-empty)."""
import sys

path = sys.argv[1]
count = 0
with open(path, "rb") as fh:
    for _ in fh:
        count += 1
if count == 0:
    with open(path, "rb") as fh:
        if fh.read(1):
            count = 1
print(count)
