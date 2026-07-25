#!/usr/bin/env python3
"""Initialize a new runtime overlay journal file."""
import json, sys

path, pid, start_time, plan_key, runtime, workspace = sys.argv[1:]
data = {
    "pid": int(pid),
    "start_time": int(start_time),
    "runtime": runtime,
    "plan_key": plan_key,
    "workspace_root": workspace,
    "cleanup_status": "pending",
    "cleanup_time": None,
    "generated_files": [],
    "mutated_files": []
}
with open(path, "w") as fh:
    json.dump(data, fh, indent=2)
