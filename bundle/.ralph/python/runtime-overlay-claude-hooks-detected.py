#!/usr/bin/env python3
"""Exit 0 when Ralph Claude hooks are present in a settings.json file.

Usage: runtime-overlay-claude-hooks-detected.py SETTINGS_FILE [STRICT]

STRICT=1 requires each hook command to be a single absolute path to an
executable file whose basename matches the hook script.
"""
import json
import os
import shlex
import sys

path = sys.argv[1]
strict = len(sys.argv) > 2 and sys.argv[2] == "1"
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
    if strict:
        for cmd in commands:
            try:
                words = shlex.split(cmd)
            except ValueError:
                continue
            if (len(words) == 1 and os.path.isabs(words[0])
                    and os.path.basename(words[0]) == needle
                    and os.path.isfile(words[0]) and os.access(words[0], os.X_OK)):
                return True
        return False
    return any(needle in cmd or cmd.endswith(needle) for cmd in commands)


env_cmds = group_commands("PreToolUse", "Read|Edit|MultiEdit|Glob|Grep|LS")
bash_pre = group_commands("PreToolUse", "Bash")
bash_post = group_commands("PostToolUse", "Bash")
exploration_post = group_commands("PostToolUse", "Read|Grep|Glob")
stop_cmds = []
for group in hooks.get("Stop") or []:
    for entry in group.get("hooks") or []:
        cmd = entry.get("command") or ""
        if cmd:
            stop_cmds.append(cmd)

if not has_cmd(env_cmds, "block-env-reads.sh"):
    sys.exit(1)
if not has_cmd(bash_pre, "rewrite-bash-command.sh"):
    sys.exit(1)
if not has_cmd(bash_post, "compact-bash-output.sh"):
    sys.exit(1)
if not (
    has_cmd(exploration_post, "native-result-compact.sh")
    or has_cmd(exploration_post, "compact-native-result-output.sh")
):
    sys.exit(1)
if not has_cmd(stop_cmds, "stop-continuation.sh"):
    sys.exit(1)
sys.exit(0)
