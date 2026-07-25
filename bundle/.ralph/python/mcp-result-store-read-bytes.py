#!/usr/bin/env python3
"""Read a byte range from a file and write it to stdout."""
import sys

path, offset_s, limit_s = sys.argv[1:4]
offset = int(offset_s)
limit = int(limit_s)
with open(path, "rb") as fh:
    fh.seek(offset)
    data = fh.read(limit if limit > 0 else None)
sys.stdout.buffer.write(data)
