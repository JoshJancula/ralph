#!/usr/bin/env python3
"""Return 0 when Ralph Cursor hooks are present in a hooks.json file."""
import json
import os
import sys

path = sys.argv[1]
required = {
    "pre-tool-shell-policy.sh",
    "post-tool-shell-telemetry.sh",
    "post-tool-mcp-compact.sh",
    "after-shell-telemetry.sh",
}

try:
    with open(path) as fh:
        data = json.load(fh)
except (OSError, json.JSONDecodeError):
    sys.exit(1)

hooks = data.get("hooks") or {}
found = set()


def scan_entries(entries):
    for entry in entries or []:
        cmd = entry.get("command") or ""
        base = os.path.basename(cmd)
        if base in required:
            found.add(base)


for event in ("preToolUse", "postToolUse", "afterShellExecution"):
    scan_entries(hooks.get(event))

if found == required:
    sys.exit(0)
sys.exit(1)
