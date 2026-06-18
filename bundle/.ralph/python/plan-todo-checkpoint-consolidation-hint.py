#!/usr/bin/env python3
"""Emit a one-time stderr hint for checkpoint plans with many adjacent tiny open TODOs.

Tiny = single-line open checkbox body length at or below RALPH_PLAN_CHECKPOINT_TINY_TODO_CHARS
(default 100). A run is consecutive such lines without a blank line or markdown heading between.
When the longest run is at least RALPH_PLAN_CHECKPOINT_TINY_TODO_RUN (default 8), print guidance to
stderr suggesting RALPH_PLAN_CONSOLIDATE=1 or RALPH_PLAN_CONSOLIDATE_CHECKPOINT=1.

Exit 0 always. No output when the plan is not default markdown or PyYAML frontmatter is detected.
"""

from __future__ import annotations

import os
import re
import sys

OPEN_RE = re.compile(r"^\s*-\s+\[\s\]\s*(.*)$")
HEADING_RE = re.compile(r"^#{1,6}\s")


def _is_yaml_frontmatter(text: str) -> bool:
    if not text.startswith("---"):
        return False
    parts = text.split("---", 2)
    return len(parts) > 1 and "todos:" in parts[1]


_is_cursorish = _is_yaml_frontmatter  # compatibility alias


def _max_tiny_run(lines: list[str], max_chars: int) -> int:
    cur = 0
    best = 0
    for raw in lines:
        line = raw.rstrip("\r\n")
        if not line.strip():
            cur = 0
            continue
        if HEADING_RE.match(line):
            cur = 0
            continue
        m = OPEN_RE.match(line)
        if m and len(m.group(1).strip()) <= max_chars:
            cur += 1
            best = max(best, cur)
        else:
            cur = 0
    return best


def main() -> int:
    if len(sys.argv) != 2:
        print("usage: plan-todo-checkpoint-consolidation-hint.py <plan.md>", file=sys.stderr)
        return 2
    if os.environ.get("RALPH_PLAN_CHECKPOINT_CONSOLIDATE_HINT", "1") == "0":
        return 0
    path = sys.argv[1]
    try:
        text = open(path, encoding="utf-8").read()
    except OSError as exc:
        print(str(exc), file=sys.stderr)
        return 0
    if _is_yaml_frontmatter(text):
        return 0
    max_chars = int(os.environ.get("RALPH_PLAN_CHECKPOINT_TINY_TODO_CHARS", "100"))
    need_run = int(os.environ.get("RALPH_PLAN_CHECKPOINT_TINY_TODO_RUN", "8"))
    lines = text.splitlines()
    if _max_tiny_run(lines, max_chars) < need_run:
        return 0
    print(
        "Ralph hint (checkpoint): this plan has many adjacent short open TODOs. "
        "Consider RALPH_PLAN_CONSOLIDATE=1 for a conservative merge at run start "
        "(manual, destructive, and verification-gate items are never merged), or "
        "RALPH_PLAN_CONSOLIDATE_CHECKPOINT=1 to enable that pass automatically in checkpoint mode. "
        "Set RALPH_PLAN_CHECKPOINT_CONSOLIDATE_HINT=0 to suppress this message.",
        file=sys.stderr,
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
