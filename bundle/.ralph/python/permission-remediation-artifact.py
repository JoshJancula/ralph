#!/usr/bin/env python3
"""Build permission-remediation.json from a small input directory (see ralph_write_permission_remediation_artifact)."""

from __future__ import annotations

import argparse
import json
import re
import sys
from datetime import datetime, timezone
from pathlib import Path


def _read_text(path: Path) -> str:
    if not path.is_file():
        return ""
    return path.read_text(encoding="utf-8", errors="replace")


def _actions_from_hint(hint: str) -> list[str]:
    actions: list[str] = []
    for line in hint.splitlines():
        if re.match(r"^\s+-\s", line) or re.match(r"^\s*\d+\)\s", line):
            actions.append(line.strip())
    if actions:
        return actions
    stripped = hint.strip()
    if stripped:
        return [stripped]
    return []


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("input_dir", type=Path, help="Directory containing meta.json and text blobs")
    ap.add_argument("output_json", type=Path, help="Destination permission-remediation.json path")
    args = ap.parse_args()
    indir: Path = args.input_dir
    out: Path = args.output_json

    meta_path = indir / "meta.json"
    if not meta_path.is_file():
        print("permission-remediation-artifact: missing meta.json", file=sys.stderr)
        return 1
    meta = json.loads(meta_path.read_text(encoding="utf-8"))

    denial = _read_text(indir / "denial.txt")
    max_excerpt = int(meta.get("denial_excerpt_max_bytes", 8192))
    if len(denial) > max_excerpt:
        denial = denial[:max_excerpt] + "\n[truncated]"

    hint = _read_text(indir / "hint.txt")
    resume = _read_text(indir / "resume.txt").strip()

    todo_line = int(meta["todo_line"])
    doc = {
        "schema_version": 1,
        "kind": "permission_remediation",
        "generated_at": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "runtime": meta.get("runtime", ""),
        "session_strategy": meta.get("session_strategy", "fresh"),
        "todo": {
            "line": todo_line,
            "text": _read_text(indir / "todo.txt"),
            "line_text": _read_text(indir / "full_line.txt"),
        },
        "classification": meta.get("classification", ""),
        "blocked_command_or_tool": meta.get("blocked_command_or_tool", ""),
        "blocked_path": meta.get("blocked_path", ""),
        "raw_denial_excerpt": denial,
        "runtime_specific_explanation": hint,
        "recommended_operator_actions": _actions_from_hint(hint),
        "resume_command": resume,
    }

    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(json.dumps(doc, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
