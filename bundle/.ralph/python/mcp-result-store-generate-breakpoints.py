#!/usr/bin/env python3
"""Generate deterministic paging breakpoints JSON for stored MCP results."""
import json
import sys

result_path, original_s, returned_s, cap_s, match_json = sys.argv[1:6]
original_bytes = int(original_s)
returned_bytes = int(returned_s)
envelope_byte_cap = int(cap_s)
match_metadata = json.loads(match_json)

window = returned_bytes if returned_bytes > 0 else (original_bytes if original_bytes > 0 else 1)
orig = max(0, original_bytes)
context_lines = 1

breakpoints = [
    {"kind": "start", "byteStart": 0, "byteEnd": min(window, orig if orig > 0 else window)},
    {
        "kind": "end",
        "byteStart": max(0, orig - window) if orig > window else 0,
        "byteEnd": orig,
    },
]

line_starts = [0]
data = b""
if result_path:
    with open(result_path, "rb") as fh:
        data = fh.read()
    for index, byte in enumerate(data):
        if byte == ord("\n"):
            line_starts.append(index + 1)
total_lines = max(1, len(line_starts))


def normalize_match(entry):
    if isinstance(entry, dict):
        line_start = entry.get("lineStart")
        line_end = entry.get("lineEnd")
        if line_start is not None and line_end is not None:
            try:
                ls = int(line_start)
                le = int(line_end)
            except (TypeError, ValueError):
                return None
            if ls < 1 or le < ls:
                return None
            return ("cluster", ls, le)
        line = entry.get("line")
    else:
        line = entry
    try:
        line_no = int(line)
    except (TypeError, ValueError):
        return None
    if line_no < 1:
        return None
    return ("line", line_no)


match_entries = []
seen = set()
for entry in match_metadata:
    norm = normalize_match(entry)
    if norm is None:
        continue
    if norm[0] == "cluster":
        key = ("cluster", norm[1], norm[2])
    else:
        key = ("line", norm[1])
    if key in seen:
        continue
    seen.add(key)
    match_entries.append(norm)

match_entries.sort(key=lambda item: item[1])

for norm in match_entries:
    if norm[0] == "cluster":
        line_start = max(1, norm[1] - context_lines)
        line_end = min(total_lines, norm[2] + context_lines)
        entry = {
            "kind": "matchCluster",
            "lineStart": line_start,
            "lineEnd": line_end,
        }
    else:
        line_no = norm[1]
        line_start = max(1, line_no - context_lines)
        line_end = min(total_lines, line_no + context_lines)
        entry = {
            "kind": "match",
            "lineStart": line_start,
            "lineEnd": line_end,
        }
    if data:
        byte_start = line_starts[line_start - 1]
        if line_end >= total_lines:
            byte_end = len(data)
        else:
            byte_end = line_starts[line_end]
        entry["byteStart"] = byte_start
        entry["byteEnd"] = byte_end
    breakpoints.append(entry)


def compact_size(items):
    return len(json.dumps(items, separators=(",", ":")).encode("utf-8"))


if envelope_byte_cap > 0:
    preview_bytes = min(returned_bytes if returned_bytes > 0 else window, orig if orig > 0 else window)
    fixed_overhead = 220
    budget = max(64, envelope_byte_cap - preview_bytes - fixed_overhead)
    while compact_size(breakpoints) > budget and len(breakpoints) > 2:
        breakpoints.pop()

print(json.dumps(breakpoints, separators=(",", ":")))
