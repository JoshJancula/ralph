#!/usr/bin/env python3
"""Redact secrets from Jev state text while preserving newlines.

Reads stdin, writes redacted stdout. Exit 0 on success, 1 on failure
(with nothing written to stdout on failure paths that callers rely on).
"""

from __future__ import annotations

import os
import re
import sys


_CREDENTIAL_ASSIGNMENT = re.compile(
    r"(?i)(?:password|passwd|secret|token|api[_-]?key|private[_-]?key|"
    r"bearer|authorization|credential)\s*[=:]\s*\S+"
)

_TOKEN_SHAPES = re.compile(
    r"(?i)(?<![A-Za-z0-9_-])(?:sk-[A-Za-z0-9_-]{8,}|AKIA[0-9A-Z]{8,}|"
    r"ghp_[A-Za-z0-9]{20,}|xox[baprs]-[A-Za-z0-9-]{10,})(?![A-Za-z0-9_-])"
)

# Env-dump / declare -x style: UPPER_SNAKE=value (value is non-whitespace).
_ENV_DUMP_ASSIGNMENT = re.compile(
    r"(^|[^A-Za-z0-9_])([A-Z][A-Z0-9_]*)=(\S+)"
)

_REPLACEMENT = "[REDACTED]"


def redact_text(text: str, *, home: str | None = None, typesafe_key: str | None = None) -> str:
    """Apply Jev redaction rules to text, preserving newlines exactly."""
    if home is None:
        home = os.environ.get("HOME") or ""
    if typesafe_key is None:
        typesafe_key = os.environ.get("TYPESAFE_API_KEY") or ""

    if typesafe_key:
        text = text.replace(typesafe_key, _REPLACEMENT)

    text = _CREDENTIAL_ASSIGNMENT.sub(_REPLACEMENT, text)
    text = _TOKEN_SHAPES.sub(_REPLACEMENT, text)
    text = _ENV_DUMP_ASSIGNMENT.sub(
        lambda m: f"{m.group(1)}{m.group(2)}={_REPLACEMENT}",
        text,
    )

    if home:
        text = text.replace(home, "~")

    return text


def main() -> int:
    try:
        text = sys.stdin.read()
        out = redact_text(text)
    except Exception:
        return 1
    sys.stdout.write(out)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
