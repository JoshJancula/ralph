#!/usr/bin/env python3
"""Append an entry to a journal field."""
import json, sys

path = sys.argv[1]
field = sys.argv[2]
entry_json = sys.argv[3]
entry = json.loads(entry_json)
with open(path) as fh:
    data = json.load(fh)
data.setdefault(field, []).append(entry)
with open(path, "w") as fh:
    json.dump(data, fh, indent=2)
