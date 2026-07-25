#!/usr/bin/env python3
"""Mark a runtime overlay journal as cleaned."""
import json, sys, time

path, cleanup_ts = sys.argv[1:]
cleanup_time = int(cleanup_ts) if cleanup_ts.isdigit() else int(time.time())
data = json.load(open(path))
for entry in data.get("generated_files", []):
    entry["cleaned"] = True
for entry in data.get("mutated_files", []):
    entry["restored"] = True
data["cleanup_status"] = "cleaned"
data["cleanup_time"] = cleanup_time
with open(path, "w") as fh:
    json.dump(data, fh, indent=2)
