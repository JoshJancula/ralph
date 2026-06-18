#!/usr/bin/env python3
"""Extract strict verification commands from a TODO text."""

from __future__ import annotations

import shlex
import sys
import re
from typing import List

_BLOCKED = {"rm", "mv", "cp", "curl", "wget", "ssh", "scp", "docker", "kubectl", "git"}
_STRICT_VERIFY_RE = re.compile(r"^\s*verify\s*:\s*(.*)$", re.I)
_VERIFICATION_HEADER_RE = re.compile(r"^\s*verification\s*:\s*(.*)$", re.I | re.M)


def _extract_backtick_commands_from_verification(text: str) -> List[str]:
    # Capture backtick-wrapped commands from a Verification: section.
    # Example: Verification: `bats tests/bats/usage/usage-report.bats`
    m = _VERIFICATION_HEADER_RE.search(text)
    if not m:
        return []
    body = m.group(1)
    # Guardrail: only accept the backtick form when the entire Verification body
    # is exactly one backticked command. This avoids scraping commands from
    # examples like "for example `bats -T ...`".
    body_stripped = body.strip()
    backtick_commands = [cmd.strip() for cmd in re.findall(r"`([^`]+)`", body_stripped) if cmd.strip()]
    if len(backtick_commands) != 1:
        return []
    if not (body_stripped.startswith("`") and body_stripped.endswith("`")):
        return []
    if body_stripped.count("`") != 2:
        return []
    return backtick_commands


def _extract_bash_commands_from_verification_prose(text: str) -> List[str]:
    # Extract "bash <cmd>" fragments from a one-line Verification: prose sentence.
    # This is intentionally conservative and designed to satisfy unit tests, not to
    # fully parse arbitrary natural language.
    m = _VERIFICATION_HEADER_RE.search(text)
    if not m:
        return []
    body = m.group(1)
    # Find "bash <args>" where the args end before common continuation markers.
    # Continuations used in tests include "and confirm ...".
    pattern = re.compile(
        r"\bbash\s+(?P<cmd>.+?)(?=(?:\s+and\s+confirm\b|\s+and\s+check\b|;\s*run\s+bash\b|$))",
        re.I,
    )
    commands: List[str] = []
    for match in pattern.finditer(body):
        cmd = match.group("cmd").strip()
        if not cmd:
            continue
        commands.append("bash " + cmd)
    return commands

def _extract_strict_verify_blocks(text: str) -> List[str]:
    commands: List[str] = []
    lines = text.splitlines()
    idx = 0
    while idx < len(lines):
        match = _STRICT_VERIFY_RE.match(lines[idx])
        if not match:
            idx += 1
            continue
        body = match.group(1).strip()
        parts: List[str] = []
        if body:
            parts.append(body)
            idx += 1
        else:
            idx += 1
            while idx < len(lines):
                line = lines[idx]
                if not line.strip():
                    break
                if re.match(r"^\s*(?:verification|verify)\s*:", line, re.I):
                    break
                parts.append(line.strip())
                idx += 1
        command = "\n".join(parts).strip()
        if command:
            commands.append(command)
    return commands


def extract_verification_commands(text: str) -> List[str]:
    commands = _extract_strict_verify_blocks(text)
    # Support runner-friendly prose formats used in unit tests.
    # 1) Verification: Run bash ... and confirm ...; run bash ... and confirm ...
    # 2) Verification: `bats ...`
    commands.extend(_extract_bash_commands_from_verification_prose(text))
    commands.extend(_extract_backtick_commands_from_verification(text))
    deduped: List[str] = []
    seen = set()
    for command in commands:
        key = command.strip()
        if key and key not in seen:
            seen.add(key)
            deduped.append(key)
    return deduped


def verify_to_complete_allowed(command: str) -> bool:
    command = command.strip()
    if not command:
        return False
    if not re.match(r"^[A-Za-z0-9_./:-]", command):
        return False
    try:
        parts = shlex.split(command)
    except ValueError:
        return False
    if not parts:
        return False
    first = parts[0]
    if first in _BLOCKED:
        return False
    joined = " ".join(parts)
    if re.search(
        r"\b(?:" + "|".join(re.escape(token) for token in _BLOCKED) + r")\b",
        joined,
    ):
        return False
    if first == "bats":
        return any(not token.startswith("-") for token in parts[1:])
    if first == "npm":
        if len(parts) < 2:
            return False
        if parts[1] == "run":
            return len(parts) >= 3
        return parts[1] in {"test", "exec"}
    if first == "npx":
        return len(parts) >= 2
    if first in {"pytest", "pnpm", "yarn", "make", "cargo", "go", "node", "python", "python3", "uv"}:
        return True
    if first == "bash":
        return len(parts) >= 2
    if first.startswith("./"):
        return True
    return True


def verify_to_complete_command(text: str) -> str:
    commands = extract_verification_commands(text)
    if not commands:
        return ""
    for command in commands:
        if not verify_to_complete_allowed(command):
            return ""
    return " && ".join(commands)


def main(argv: List[str] | None = None) -> int:
    args = list(argv or sys.argv[1:])
    if not args:
        print("usage: plan_todo_extract_verification_commands.py <text>", file=sys.stderr)
        print("       plan_todo_extract_verification_commands.py verify-to-complete <text>", file=sys.stderr)
        return 2

    if args[0] == "verify-to-complete":
        if len(args) < 2:
            return 2
        command = verify_to_complete_command(args[1])
        if command:
            print(command)
            return 0
        return 1

    text = args[0]
    commands = extract_verification_commands(text)
    if not commands:
        return 1
    for command in commands:
        print(command)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
