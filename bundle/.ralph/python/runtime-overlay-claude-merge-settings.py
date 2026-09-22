#!/usr/bin/env python3
"""Merge Ralph Claude hook template entries into a settings.json file."""
import json
import os
import shlex
import sys

target, template = sys.argv[1:3]
# Setup merges through a temporary file: never infer the installation path
# from that file. Overlays explicitly pass the framework's hook directory.
hooks_dir = os.path.abspath(sys.argv[3]) if len(sys.argv) > 3 else os.path.abspath(
    os.path.join(os.path.dirname(target), "hooks")
)
include_stop = len(sys.argv) <= 4 or sys.argv[4] == "1"
hook_timeout = int(sys.argv[5]) if len(sys.argv) > 5 else None


def load_json(path):
    if not os.path.isfile(path):
        return {}
    with open(path) as fh:
        return json.load(fh)


data = load_json(target)
with open(template) as fh:
    template_data = json.load(fh)

template_hooks = template_data.get("hooks") or {}
hooks = data.setdefault("hooks", {})

replacements = {}
for event, groups in template_hooks.items():
    if event == "Stop" and not include_stop:
        continue
    for group in groups:
        for entry in group.get("hooks") or []:
            command = entry.get("command", "")
            if command.startswith(".claude/hooks/"):
                replacements[command] = shlex.quote(os.path.join(hooks_dir, os.path.basename(command)))
                entry["command"] = replacements[command]
            if event == "Stop" and hook_timeout is not None:
                entry["timeout"] = hook_timeout

# Repair only exact Ralph template commands, preserving custom commands and
# entry metadata. Do this before deduplication so setup is repeatable.
for groups in hooks.values():
    for group in groups:
        for entry in group.get("hooks") or []:
            command = entry.get("command", "")
            if command in replacements:
                entry["command"] = replacements[command]

for event, groups in template_hooks.items():
    if event == "Stop" and not include_stop:
        continue
    hooks.setdefault(event, [])
    for tpl_group in groups:
        matcher = tpl_group.get("matcher")
        tpl_entries = tpl_group.get("hooks") or []
        existing = None
        for group in hooks[event]:
            if group.get("matcher") == matcher:
                existing = group
                break
        if existing is None:
            hooks[event].append(json.loads(json.dumps(tpl_group)))
            continue
        existing.setdefault("hooks", [])
        existing_cmds = {
            (entry.get("command") or "")
            for entry in existing["hooks"]
        }
        for entry in tpl_entries:
            cmd = entry.get("command") or ""
            if cmd in existing_cmds:
                continue
            existing["hooks"].append(json.loads(json.dumps(entry)))

os.makedirs(os.path.dirname(target) or ".", exist_ok=True)
with open(target, "w") as fh:
    json.dump(data, fh, indent=2)
    fh.write("\n")
