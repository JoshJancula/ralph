#!/usr/bin/env python3
"""Return 0 when Ralph Claude hooks are present in a settings.json file."""
import json
import sys

path = sys.argv[1]
try:
    with open(path) as fh:
        data = json.load(fh)
except (OSError, json.JSONDecodeError):
    sys.exit(1)

hooks = data.get("hooks") or {}


def group_commands(event, matcher):
    out = []
    for group in hooks.get(event) or []:
        if group.get("matcher") != matcher:
            continue
        for entry in group.get("hooks") or []:
            cmd = entry.get("command") or ""
            if cmd:
                out.append(cmd)
    return out


def has_cmd(commands, needle):
    return any(needle in cmd or cmd.endswith(needle) for cmd in commands)


pre = hooks.get("PreToolUse") or []
post = hooks.get("PostToolUse") or []
_ = pre, post

env_cmds = group_commands("PreToolUse", "Read|Edit|MultiEdit|Glob|Grep|LS")
bash_pre = group_commands("PreToolUse", "Bash")
bash_post = group_commands("PostToolUse", "Bash")

if not has_cmd(env_cmds, "block-env-reads.sh"):
    sys.exit(1)
if not has_cmd(bash_pre, "rewrite-bash-command.sh"):
    sys.exit(1)
if not has_cmd(bash_post, "compact-bash-output.sh"):
    sys.exit(1)
sys.exit(0)
