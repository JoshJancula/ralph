#!/usr/bin/env python3
"""Convert grep/rg output lines to match metadata JSON."""
import json
import re
import sys

text = sys.argv[1]
lines = []
seen = set()
for raw_line in text.splitlines():
    match = re.match(r"^(?:[^:]+:)?(\d+):", raw_line)
    if not match:
        continue
    line_no = int(match.group(1))
    if line_no in seen:
        continue
    seen.add(line_no)
    lines.append({"line": line_no})

lines.sort(key=lambda item: item["line"])
print(json.dumps(lines, separators=(",", ":")))
