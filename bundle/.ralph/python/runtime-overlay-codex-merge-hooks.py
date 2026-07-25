#!/usr/bin/env python3
"""Merge Ralph Codex hook template entries into a hooks.json file."""
import copy
import json
import os
import sys

target, template = sys.argv[1:]

RALPH_BASES = {
    "pre-tool-bash-policy.sh",
    "post-tool-bash-telemetry.sh",
    "post-tool-native-result-compact.sh",
}


def load_json(path):
    if not os.path.isfile(path):
        return {}
    with open(path) as fh:
        return json.load(fh)


def command_basename(command):
    return os.path.basename(command or "")


def hook_command(hook):
    return hook.get("command") or ""


def merge_hooks(existing_hooks, template_hooks):
    existing_cmds = {hook_command(h) for h in existing_hooks}
    existing_bases = {command_basename(hook_command(h)) for h in existing_hooks}
    for hook in template_hooks:
        cmd = hook_command(hook)
        base = command_basename(cmd)
        if cmd in existing_cmds:
            continue
        if base in existing_bases:
            continue
        if base in RALPH_BASES and any(
            command_basename(hook_command(entry)) == base for entry in existing_hooks
        ):
            continue
        existing_hooks.append(copy.deepcopy(hook))
        existing_cmds.add(cmd)
        if base:
            existing_bases.add(base)


def find_matcher_group(groups, matcher):
    for group in groups:
        if group.get("matcher") == matcher:
            return group
    return None


data = load_json(target)
with open(template) as fh:
    template_data = json.load(fh)

template_hooks_root = template_data.get("hooks") or {}
hooks = data.setdefault("hooks", {})

for event, template_groups in template_hooks_root.items():
    hooks.setdefault(event, [])
    for template_group in template_groups:
        matcher = template_group.get("matcher")
        hooks_list = template_group.get("hooks") or []
        if matcher:
            group = find_matcher_group(hooks[event], matcher)
            if group is None:
                group = {"matcher": matcher, "hooks": []}
                hooks[event].append(group)
            group.setdefault("hooks", [])
            merge_hooks(group["hooks"], hooks_list)
        else:
            existing_cmds = set()
            for group in hooks[event]:
                for entry in group.get("hooks") or []:
                    existing_cmds.add(hook_command(entry))
            new_hooks = [h for h in hooks_list if hook_command(h) not in existing_cmds]
            if new_hooks:
                hooks[event].append({"hooks": copy.deepcopy(new_hooks)})

os.makedirs(os.path.dirname(target) or ".", exist_ok=True)
with open(target, "w") as fh:
    json.dump(data, fh, indent=2)
    fh.write("\n")
