#!/usr/bin/env python3
"""Thin CLI adapter for shell command rewrite (registry-backed)."""

from __future__ import annotations

import json
import os
import sys

sys.path.insert(0, os.path.dirname(__file__))

from shell_command_registry import RewriteResult, rewrite_command


def _rewrite_cli(payload: dict[str, object]) -> int:
    command = str(payload.get("command") or "")
    result = rewrite_command(command)
    sys.stdout.write(json.dumps(result.to_dict(), ensure_ascii=False))
    sys.stdout.write("\n")
    return 0


def main(argv: list[str] | None = None) -> int:
    args = argv if argv is not None else sys.argv[1:]
    if args != ["rewrite"]:
        print(
            "Usage: shell-command-rewrite.py rewrite  (read JSON object on stdin)",
            file=sys.stderr,
        )
        return 2
    try:
        payload = json.load(sys.stdin)
    except json.JSONDecodeError as exc:
        print(f"Invalid JSON input: {exc}", file=sys.stderr)
        return 2
    if not isinstance(payload, dict):
        print("Expected a JSON object on stdin", file=sys.stderr)
        return 2
    return _rewrite_cli(payload)


if __name__ == "__main__":
    raise SystemExit(main())
