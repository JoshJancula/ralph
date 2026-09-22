#!/usr/bin/env python3
"""Stable command fingerprint for duration learning across plan runs.

Hashes the normalized argv produced by shell_command_registry.try_parse_tokens
(env assignments and wrapper prefixes stripped; arguments kept). Compound
commands, pipelines, redirects, background operators, subshells, and function
definitions are not fingerprintable and return None.

Callers without python3 must degrade to recording nothing rather than failing.
Use bundle/.ralph/bash-lib/command-fingerprint.sh (ralph_command_fingerprint),
which prints an empty string when python3 is absent.
"""

from __future__ import annotations

import hashlib
import json
import os
import sys

sys.path.insert(0, os.path.dirname(__file__))

from shell_command_registry import try_parse_tokens


def fingerprint(command: str) -> str | None:
    """Return a sha256 hex digest of the normalized argv, or None.

    Arguments are part of the key: ``bash scripts/run-bats.sh`` and
    ``bash scripts/run-bats.sh --filter x`` must differ. Leading env
    assignments do not change the key. Unparseable / bail-shaped commands
    return None (never record, never auto-background).
    """
    if command is None:
        return None
    parsed = try_parse_tokens(command)
    if parsed is None:
        return None
    _cmd, tokens, _rewrite_prefix = parsed
    if not tokens:
        return None
    # Null-separated argv keeps arguments that contain spaces unambiguous.
    payload = "\0".join(tokens).encode("utf-8")
    return hashlib.sha256(payload).hexdigest()


def _fingerprint_cli(payload: dict[str, object]) -> int:
    command = str(payload.get("command") or "")
    digest = fingerprint(command)
    sys.stdout.write(json.dumps({"fingerprint": digest}, ensure_ascii=False))
    sys.stdout.write("\n")
    return 0


def main(argv: list[str] | None = None) -> int:
    args = argv if argv is not None else sys.argv[1:]
    if args != ["fingerprint"]:
        print(
            "Usage: command_fingerprint.py fingerprint  (read JSON object on stdin)",
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
    return _fingerprint_cli(payload)


if __name__ == "__main__":
    raise SystemExit(main())
