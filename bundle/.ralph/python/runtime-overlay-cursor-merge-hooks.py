#!/usr/bin/env python3
"""Merge Ralph Cursor hook template entries into a hooks.json file."""
import copy
import json
import os
import sys

target, template = sys.argv[1:]

RALPH_BASES = {
    "pre-tool-shell-policy.sh",
    "pre-tool-exploration-policy.sh",
    "pre-tool-proxy-read-handoff.sh",
    "post-tool-shell-telemetry.sh",
    "post-tool-native-result-compact.sh",
    "after-shell-telemetry.sh",
}


def load_json(path):
    if not os.path.isfile(path):
        return {}
    with open(path) as fh:
        return json.load(fh)


def entry_command(entry):
    return entry.get("command") or ""


def entry_basename(entry):
    return os.path.basename(entry_command(entry))


def merge_entries(existing, template_entries):
    existing_cmds = {entry_command(e) for e in existing}
    existing_bases = {entry_basename(e) for e in existing if entry_basename(e)}
    for entry in template_entries:
        cmd = entry_command(entry)
        base = entry_basename(entry)
        if cmd in existing_cmds:
            continue
        if base in existing_bases:
            continue
        if any(cmd.endswith(b) for b in existing_bases if b):
            continue
        existing.append(copy.deepcopy(entry))
        existing_cmds.add(cmd)
        if base:
            existing_bases.add(base)


data = load_json(target)
with open(template) as fh:
    template_data = json.load(fh)

data.setdefault("version", template_data.get("version", 1))
template_hooks = template_data.get("hooks") or {}
hooks = data.setdefault("hooks", {})

for event, template_entries in template_hooks.items():
    hooks.setdefault(event, [])
    merge_entries(hooks[event], template_entries)

os.makedirs(os.path.dirname(target) or ".", exist_ok=True)
with open(target, "w") as fh:
    json.dump(data, fh, indent=2)
    fh.write("\n")
