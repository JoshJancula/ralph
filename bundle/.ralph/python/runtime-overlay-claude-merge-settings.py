#!/usr/bin/env python3
"""Merge Ralph Claude hook template entries into a settings.json file."""
import json
import os
import sys

target, template = sys.argv[1:]


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

for event, groups in template_hooks.items():
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
            if any(cmd.endswith(os.path.basename(c)) for c in existing_cmds if c):
                continue
            existing["hooks"].append(json.loads(json.dumps(entry)))

os.makedirs(os.path.dirname(target) or ".", exist_ok=True)
with open(target, "w") as fh:
    json.dump(data, fh, indent=2)
    fh.write("\n")
