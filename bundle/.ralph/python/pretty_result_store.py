#!/usr/bin/env python3
"""Persist overflow tool bodies for the pretty renderer and direct verification."""

from __future__ import annotations

import argparse
import fcntl
import hashlib
import json
import os
import re
import sys
import time
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Optional, Tuple

_PLAN_KEY_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]*$")
_RESULT_ID_RE = re.compile(r"^[a-f0-9]{16}$")
_ENVELOPE_RESULT_ID_RE = re.compile(r'"resultId"\s*:\s*"([A-Za-z0-9_-]{4,})"')
_STORAGE_PATH_RE = re.compile(
    r"\.ralph-workspace/tool-results/([^/]+)/results/([a-f0-9]{16})\.txt"
)
_ERROR_LINE_RE = re.compile(
    r"error|fail|warning|traceback|exception", re.IGNORECASE
)
_HEAD_BIAS_TOOLS = frozenset(
    {
        "ralph_proxy_read",
        "ralph_proxy_grep",
        "ralph_proxy_glob",
        "ralph_proxy_search",
        "resources/read",
        "run_plan_pretty",
        "direct_verification",
    }
)

_write_seq = 0


def plan_key() -> str:
    for env_name in ("RALPH_PLAN_KEY", "RALPH_ARTIFACT_NS"):
        value = (os.environ.get(env_name) or "").strip()
        if value and _PLAN_KEY_RE.match(value):
            return value
    return "default"


def workspace_dir() -> Path:
    raw = (os.environ.get("RALPH_MCP_WORKSPACE") or os.getcwd()).strip()
    return Path(raw).resolve()


def workspace_root() -> Path:
    project = workspace_dir()
    candidate = (os.environ.get("RALPH_PLAN_WORKSPACE_ROOT") or "").strip()
    if not candidate:
        return project / ".ralph-workspace"
    path = Path(candidate)
    if not path.is_absolute():
        path = project / path
    return path.resolve()


def tool_results_root() -> Path:
    return workspace_root() / "tool-results"


def result_rel_path(plan: str, result_id: str) -> str:
    return f".ralph-workspace/tool-results/{plan}/results/{result_id}.txt"


def compact_rel_path(plan: str, result_id: str) -> str:
    return f".ralph-workspace/tool-results/{plan}/results/{result_id}.compact.txt"


def has_compact_view(plan: str, result_id: str) -> bool:
    return (workspace_dir() / compact_rel_path(plan, result_id)).is_file()


def full_output_pointer(plan: str, result_id: str) -> str:
    path = result_rel_path(plan, result_id)
    return f"full output: {path}; ralph_proxy_result_read resultId={result_id}"


def compact_view_bias_for_tool(tool_name: str) -> str:
    if tool_name in _HEAD_BIAS_TOOLS:
        return "head"
    return "tail"


def build_compact_view(content: str, tool_name: str = "", byte_cap: int = 0) -> str:
    if not content:
        return content
    if byte_cap <= 0:
        byte_cap = 16384
    if compact_view_bias_for_tool(tool_name) == "head":
        encoded_len = len(content.encode("utf-8"))
        if encoded_len <= byte_cap:
            return content
        lines = content.splitlines()
        if not lines:
            return content[:byte_cap]
        head_keep = 40
        tail_keep = 40
        if len(lines) <= head_keep + tail_keep:
            compacted = content
        else:
            keep = [False] * len(lines)
            for index in range(min(head_keep, len(lines))):
                keep[index] = True
            tail_start = max(0, len(lines) - tail_keep)
            for index in range(tail_start, len(lines)):
                keep[index] = True
            for index, line in enumerate(lines):
                if _ERROR_LINE_RE.search(line):
                    keep[index] = True
            out: list[str] = []
            in_omit = False
            for index, line in enumerate(lines):
                if keep[index]:
                    if in_omit:
                        out.append("... (lines omitted; full output in raw view) ...")
                        in_omit = False
                    out.append(line)
                elif not in_omit:
                    in_omit = True
            compacted = "\n".join(out)
        if len(compacted.encode("utf-8")) > byte_cap:
            return compacted.encode("utf-8")[:byte_cap].decode("utf-8", errors="ignore")
        return compacted

    lines = content.splitlines()
    if not lines:
        return content
    head_keep = 5
    tail_keep = 40
    if len(lines) <= head_keep + tail_keep:
        compacted = "\n".join(lines)
    else:
        keep = [False] * len(lines)
        for index in range(min(head_keep, len(lines))):
            keep[index] = True
        tail_start = max(0, len(lines) - tail_keep)
        for index in range(tail_start, len(lines)):
            keep[index] = True
        for index, line in enumerate(lines):
            if _ERROR_LINE_RE.search(line):
                keep[index] = True
        out: list[str] = []
        in_omit = False
        omit_marker = "... (lines omitted; full output in raw view) ..."
        for index, line in enumerate(lines):
            if keep[index]:
                if in_omit:
                    out.append(omit_marker)
                    in_omit = False
                out.append(line)
            elif not in_omit:
                in_omit = True
        compacted = "\n".join(out)

    if byte_cap > 0 and len(compacted.encode("utf-8")) > byte_cap:
        encoded = compacted.encode("utf-8")[:byte_cap]
        return encoded.decode("utf-8", errors="ignore")
    return compacted


def overflow_pointer(hidden: int, plan: str, result_id: str) -> str:
    path = result_rel_path(plan, result_id)
    return (
        f"... +{hidden} more lines "
        f"(full output: {path}; ralph_proxy_result_read resultId={result_id})"
    )


def compact_view_pointer(plan: str, result_id: str) -> str:
    path = compact_rel_path(plan, result_id)
    return (
        f"compacted view: {path}; "
        f"ralph_proxy_result_read resultId={result_id} view=compacted"
    )


def prompt_omission_pointer(plan: str, result_id: str) -> str:
    raw_path = result_rel_path(plan, result_id)
    if has_compact_view(plan, result_id):
        compact_path = compact_rel_path(plan, result_id)
        return (
            f"... (prompt rules omitted; compacted: {compact_path}; "
            f"full prompt: {raw_path}; "
            f"ralph_proxy_result_read resultId={result_id} view=compacted; "
            f"view=raw for exact inspection)"
        )
    return (
        f"... (prompt rules omitted; full prompt: {raw_path}; "
        f"ralph_proxy_result_read resultId={result_id})"
    )


def extract_existing_result_ref(text: str) -> Optional[Tuple[str, str]]:
    """Return (plan_key, result_id) when text already references stored output."""
    stripped = text.strip()
    if stripped.startswith("{"):
        try:
            obj = json.loads(stripped)
        except ValueError:
            obj = None
        if isinstance(obj, dict):
            result_id = obj.get("resultId")
            if isinstance(result_id, str) and _RESULT_ID_RE.match(result_id):
                return plan_key(), result_id

    match = _ENVELOPE_RESULT_ID_RE.search(text)
    if match:
        result_id = match.group(1)
        if _RESULT_ID_RE.match(result_id):
            return plan_key(), result_id

    path_match = _STORAGE_PATH_RE.search(text)
    if path_match:
        plan = path_match.group(1)
        result_id = path_match.group(2)
        if _PLAN_KEY_RE.match(plan) and _RESULT_ID_RE.match(result_id):
            return plan, result_id
    return None


def generate_unique_result_id() -> str:
    global _write_seq
    _write_seq += 1
    material = f"{os.getpid()}:{time.time_ns()}:{_write_seq}"
    return hashlib.sha256(material.encode("utf-8")).hexdigest()[:16]


def _utc_timestamp() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def _locked_update_index(index_path: Path, lock_path: Path, entry: dict[str, Any]) -> None:
    lock_path.parent.mkdir(parents=True, exist_ok=True)
    index_path.parent.mkdir(parents=True, exist_ok=True)
    if not index_path.exists():
        index_path.touch()

    payload = json.dumps(entry, separators=(",", ":"))
    with open(lock_path, "a+", encoding="utf-8") as lock_fh:
        fcntl.flock(lock_fh.fileno(), fcntl.LOCK_EX)
        try:
            lines: list[str] = []
            if index_path.stat().st_size > 0:
                raw = index_path.read_text(encoding="utf-8")
                for line in raw.splitlines():
                    if not line.strip():
                        continue
                    try:
                        row = json.loads(line)
                    except ValueError:
                        continue
                    if row.get("id") == entry["id"]:
                        continue
                    lines.append(json.dumps(row, separators=(",", ":")))
            lines.append(payload)
            index_path.write_text("\n".join(lines) + ("\n" if lines else ""), encoding="utf-8")
        finally:
            fcntl.flock(lock_fh.fileno(), fcntl.LOCK_UN)


def write_result(content: str, tool_name: str = "") -> Optional[str]:
    """Write full text to the per-plan result store; return result id or None."""
    if not content:
        return None
    pk = plan_key()
    if not _PLAN_KEY_RE.match(pk):
        return None

    result_id = generate_unique_result_id()
    plan_dir = tool_results_root() / pk
    results_dir = plan_dir / "results"
    results_dir.mkdir(parents=True, exist_ok=True)
    result_path = results_dir / f"{result_id}.txt"
    result_path.write_text(content, encoding="utf-8")
    compact_text = build_compact_view(content, tool_name=tool_name)
    if compact_text != content:
        compact_path = results_dir / f"{result_id}.compact.txt"
        compact_path.write_text(compact_text, encoding="utf-8")

    rel_path = result_rel_path(pk, result_id)
    entry: dict[str, Any] = {
        "id": result_id,
        "storedAt": _utc_timestamp(),
        "bytes": len(content.encode("utf-8")),
        "tool": tool_name or None,
        "path": str((workspace_dir() / rel_path).resolve()),
    }
    entry = {key: value for key, value in entry.items() if value is not None}
    _locked_update_index(plan_dir / "index.jsonl", plan_dir / ".store.lock", entry)
    return result_id


def resolve_or_store(content: str, tool_name: str = "") -> Optional[Tuple[str, str]]:
    """Reuse an existing stored result when present; otherwise write and return (plan, id)."""
    existing = extract_existing_result_ref(content)
    if existing is not None:
        return existing
    result_id = write_result(content, tool_name=tool_name)
    if not result_id:
        return None
    return plan_key(), result_id


def log_summary_lines(content: str, *, head: int = 4, tail: int = 4) -> list[str]:
    """Return head/tail preview lines for bounded log append."""
    lines = content.splitlines()
    if not lines:
        return []
    if len(lines) <= head + tail:
        return lines
    hidden = len(lines) - head - tail
    out = lines[:head]
    stored = resolve_or_store(content, tool_name="direct_verification")
    if stored is None:
        out.append(f"... (+{hidden} more lines; full output unavailable)")
        out.extend(lines[-tail:])
        return out
    plan, result_id = stored
    out.append(overflow_pointer(hidden, plan, result_id))
    out.extend(lines[-tail:])
    return out


def _cli_write() -> int:
    content = sys.stdin.read()
    stored = resolve_or_store(content, tool_name="direct_verification")
    if stored is None:
        return 1
    _, result_id = stored
    sys.stdout.write(result_id)
    return 0


def _cli_log_summary() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--head", type=int, default=4)
    parser.add_argument("--tail", type=int, default=4)
    args = parser.parse_args(sys.argv[2:])
    content = sys.stdin.read()
    for line in log_summary_lines(content, head=args.head, tail=args.tail):
        sys.stdout.write(line + "\n")
    return 0


def main(argv: Optional[list[str]] = None) -> int:
    args = argv if argv is not None else sys.argv[1:]
    if not args:
        return 2
    if args[0] == "write":
        return _cli_write()
    if args[0] == "log-summary":
        return _cli_log_summary()
    return 2


if __name__ == "__main__":
    raise SystemExit(main())
