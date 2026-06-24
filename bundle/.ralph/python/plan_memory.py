#!/usr/bin/env python3
"""Bounded Ralph-owned per-plan memory store (stdlib only)."""

from __future__ import annotations

import argparse
import fcntl
import hashlib
import json
import os
import re
import sys
import tempfile
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

SCHEMA_VERSION = 1

DEFAULT_MAX_ENTRIES = 100
DEFAULT_MAX_BYTES_PER_ENTRY = 65536
DEFAULT_MAX_TOTAL_BYTES = 1048576
DEFAULT_MAX_KEY_LENGTH = 128

RESERVED_KEYS = frozenset(
    {
        "index.json",
        ".lock",
        "entries",
        "metadata",
        ".",
        "..",
    }
)
RESERVED_KEY_PREFIXES = (".env",)

CONTROL_CHAR_RE = re.compile(r"[\x00-\x1f\x7f]")
PLAN_KEY_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]*$")


class MemoryError(Exception):
    pass


def _env_bool(name: str) -> str | None:
    raw = os.environ.get(name)
    if raw is None:
        return None
    stripped = raw.strip()
    return stripped if stripped else None


def _env_positive_int(name: str, default: int) -> int:
    raw = os.environ.get(name, "").strip()
    if not raw:
        return default
    try:
        value = int(raw)
    except ValueError:
        return default
    return value if value > 0 else default


def plan_memory_enabled(*, explicit: str | None = None, ralph_mode: str | None = None) -> bool:
    value = explicit if explicit is not None else _env_bool("RALPH_PLAN_MEMORY")
    if value is not None:
        normalized = value.lower()
        if normalized in {"1", "true", "yes", "on"}:
            return True
        if normalized in {"0", "false", "no", "off"}:
            return False
        raise ValueError(f"RALPH_PLAN_MEMORY: invalid value '{value}' (use 0 or 1)")
    mode = (ralph_mode if ralph_mode is not None else os.environ.get("RALPH_MODE", "no")).lower()
    return mode in {"ralph", "hybrid"}


def limits_from_env() -> dict[str, int]:
    return {
        "max_entries": _env_positive_int("RALPH_PLAN_MEMORY_MAX_ENTRIES", DEFAULT_MAX_ENTRIES),
        "max_bytes_per_entry": _env_positive_int(
            "RALPH_PLAN_MEMORY_MAX_BYTES_PER_ENTRY", DEFAULT_MAX_BYTES_PER_ENTRY
        ),
        "max_total_bytes": _env_positive_int(
            "RALPH_PLAN_MEMORY_MAX_TOTAL_BYTES", DEFAULT_MAX_TOTAL_BYTES
        ),
        "max_key_length": _env_positive_int(
            "RALPH_PLAN_MEMORY_MAX_KEY_LENGTH", DEFAULT_MAX_KEY_LENGTH
        ),
    }


def utc_now() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def validate_plan_key(plan_key: str) -> None:
    if not plan_key:
        raise MemoryError("plan key is required")
    if "/" in plan_key or ".." in plan_key:
        raise MemoryError("plan key traversal rejected")
    if not PLAN_KEY_RE.match(plan_key):
        raise MemoryError("plan key has invalid characters")


def validate_memory_key(key: str, max_key_length: int) -> None:
    if not key:
        raise MemoryError("memory key is required")
    if key.startswith("/") or key.startswith("\\"):
        raise MemoryError("memory key must not be absolute")
    if "/" in key or "\\" in key or ".." in key:
        raise MemoryError("memory key must not contain path separators or traversal")
    if CONTROL_CHAR_RE.search(key):
        raise MemoryError("memory key contains control characters")
    lowered = key.lower()
    for prefix in RESERVED_KEY_PREFIXES:
        if lowered == prefix or lowered.startswith(prefix + "."):
            raise MemoryError("memory key is reserved (.env-like)")
    if lowered in RESERVED_KEYS or key in RESERVED_KEYS:
        raise MemoryError("memory key is reserved")
    if len(key) > max_key_length:
        raise MemoryError(f"memory key exceeds max length {max_key_length}")


def resolve_state_root(workspace: str, state_root_arg: str | None) -> Path:
    workspace_path = Path(workspace).resolve()
    if state_root_arg:
        candidate = Path(state_root_arg)
        if not candidate.is_absolute():
            candidate = workspace_path / candidate
        state_root = candidate.resolve()
    else:
        state_root = (workspace_path / ".ralph-workspace").resolve()
    if state_root != workspace_path and not str(state_root).startswith(str(workspace_path) + os.sep):
        raise MemoryError("state root is outside workspace")
    return state_root


def memory_root(state_root: Path, plan_key: str) -> Path:
    validate_plan_key(plan_key)
    return state_root / "memory" / plan_key


def content_relpath(key: str) -> str:
    digest = hashlib.sha256(key.encode("utf-8")).hexdigest()[:32]
    return f"entries/{digest}.txt"


def content_hash(content: bytes) -> str:
    return hashlib.sha256(content).hexdigest()


def path_under_root(root: Path, candidate: Path) -> Path:
    root_real = root.resolve()
    if candidate.exists() or candidate.is_symlink():
        candidate_real = candidate.resolve()
    else:
        parent_real = candidate.parent.resolve()
        candidate_real = parent_real / candidate.name
    if candidate_real == root_real or str(candidate_real).startswith(str(root_real) + os.sep):
        return candidate_real
    raise MemoryError("path escapes memory root")


def memory_lock_path(state_root: Path) -> Path:
    return state_root / "memory" / ".lock"


def locked_run(state_root: Path, callback):
    lock_path = memory_lock_path(state_root)
    lock_path.parent.mkdir(parents=True, exist_ok=True)
    with open(lock_path, "a+", encoding="utf-8") as lock_fh:
        fcntl.flock(lock_fh.fileno(), fcntl.LOCK_EX)
        try:
            return callback()
        finally:
            fcntl.flock(lock_fh.fileno(), fcntl.LOCK_UN)


def load_index(index_path: Path) -> dict[str, Any]:
    if not index_path.is_file():
        return {"schema_version": SCHEMA_VERSION, "entries": []}
    with open(index_path, encoding="utf-8") as handle:
        data = json.load(handle)
    if not isinstance(data, dict):
        raise MemoryError("memory index is malformed")
    entries = data.get("entries")
    if not isinstance(entries, list):
        raise MemoryError("memory index entries must be a list")
    return data


def atomic_write_bytes(path: Path, payload: bytes) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp_name = tempfile.mkstemp(prefix=".mem-", dir=str(path.parent))
    os.close(fd)
    tmp_path = Path(tmp_name)
    try:
        tmp_path.write_bytes(payload)
        os.replace(tmp_path, path)
    finally:
        if tmp_path.exists():
            tmp_path.unlink(missing_ok=True)


def atomic_write_json(path: Path, payload: dict[str, Any]) -> None:
    atomic_write_bytes(path, json.dumps(payload, indent=2, sort_keys=True).encode("utf-8"))


def total_bytes(entries: list[dict[str, Any]]) -> int:
    return sum(int(entry.get("byte_size", 0) or 0) for entry in entries)


def find_entry(entries: list[dict[str, Any]], key: str) -> dict[str, Any] | None:
    for entry in entries:
        if entry.get("key") == key:
            return entry
    return None


def append_log(state_root: Path, plan_key: str, record: dict[str, Any]) -> None:
    log_dir = state_root / "logs" / plan_key
    log_dir.mkdir(parents=True, exist_ok=True)
    log_path = log_dir / "plan-memory.jsonl"
    line = json.dumps(record, sort_keys=True, separators=(",", ":"))
    with open(log_path, "a", encoding="utf-8") as handle:
        handle.write(line + "\n")


def log_action(
    state_root: Path,
    plan_key: str,
    *,
    action: str,
    key: str = "",
    content_hash_value: str = "",
    byte_size: int = 0,
    outcome: str = "ok",
) -> None:
    append_log(
        state_root,
        plan_key,
        {
            "timestamp": utc_now(),
            "action": action,
            "plan_key": plan_key,
            "key": key,
            "content_hash": content_hash_value,
            "byte_size": byte_size,
            "outcome": outcome,
        },
    )


def list_entries(state_root: Path, plan_key: str) -> dict[str, Any]:
    root = memory_root(state_root, plan_key)
    index_path = root / "index.json"
    if not index_path.is_file():
        return {"schema_version": SCHEMA_VERSION, "plan_key": plan_key, "entries": []}
    index = load_index(index_path)
    public_entries = []
    for entry in index.get("entries", []):
        if not isinstance(entry, dict):
            continue
        public_entries.append(
            {
                "key": entry.get("key", ""),
                "byte_size": entry.get("byte_size", 0),
                "created_at": entry.get("created_at", ""),
                "updated_at": entry.get("updated_at", ""),
                "source_todo": entry.get("source_todo", ""),
                "source_stage": entry.get("source_stage", ""),
                "content_hash": entry.get("content_hash", ""),
            }
        )
    return {
        "schema_version": SCHEMA_VERSION,
        "plan_key": plan_key,
        "entries": public_entries,
    }


def read_entry(state_root: Path, plan_key: str, key: str) -> dict[str, Any]:
    limits = limits_from_env()
    validate_memory_key(key, limits["max_key_length"])
    root = memory_root(state_root, plan_key)
    index_path = root / "index.json"
    if not index_path.is_file():
        raise MemoryError(f"memory key not found: {key}")

    def _read() -> dict[str, Any]:
        index = load_index(index_path)
        entry = find_entry(index.get("entries", []), key)
        if entry is None:
            raise MemoryError(f"memory key not found: {key}")
        rel_path = entry.get("content_path", "")
        if not isinstance(rel_path, str) or not rel_path:
            raise MemoryError("memory entry missing content path")
        content_path = path_under_root(root, root / rel_path)
        if not content_path.is_file():
            raise MemoryError(f"memory content missing for key: {key}")
        data = content_path.read_bytes()
        return {
            "key": key,
            "content": data.decode("utf-8"),
            "byte_size": len(data),
            "created_at": entry.get("created_at", ""),
            "updated_at": entry.get("updated_at", ""),
            "source_todo": entry.get("source_todo", ""),
            "source_stage": entry.get("source_stage", ""),
            "content_hash": entry.get("content_hash", ""),
        }

    result = locked_run(state_root, _read)
    log_action(
        state_root,
        plan_key,
        action="read",
        key=key,
        content_hash_value=result.get("content_hash", ""),
        byte_size=int(result.get("byte_size", 0) or 0),
    )
    return result


def write_entry(
    state_root: Path,
    plan_key: str,
    key: str,
    content: str,
    *,
    source_todo: str = "",
    source_stage: str = "",
) -> dict[str, Any]:
    limits = limits_from_env()
    validate_memory_key(key, limits["max_key_length"])
    payload = content.encode("utf-8")
    if len(payload) > limits["max_bytes_per_entry"]:
        raise MemoryError(
            f"memory content exceeds max bytes per entry ({limits['max_bytes_per_entry']})"
        )

    root = memory_root(state_root, plan_key)
    index_path = root / "index.json"
    rel_path = content_relpath(key)
    content_path = root / rel_path
    now = utc_now()
    digest = content_hash(payload)

    def _write() -> dict[str, Any]:
        root.mkdir(parents=True, exist_ok=True)
        index = load_index(index_path)
        entries = index.setdefault("entries", [])
        if not isinstance(entries, list):
            raise MemoryError("memory index entries must be a list")
        existing = find_entry(entries, key)
        old_size = int(existing.get("byte_size", 0) or 0) if existing else 0
        projected_total = total_bytes(entries) - old_size + len(payload)
        if projected_total > limits["max_total_bytes"]:
            raise MemoryError(
                f"memory store exceeds max total bytes ({limits['max_total_bytes']})"
            )
        if existing is None and len(entries) >= limits["max_entries"]:
            raise MemoryError(f"memory store exceeds max entries ({limits['max_entries']})")

        path_under_root(root, content_path)
        atomic_write_bytes(content_path, payload)

        record = {
            "key": key,
            "content_path": rel_path,
            "byte_size": len(payload),
            "created_at": existing.get("created_at", now) if existing else now,
            "updated_at": now,
            "source_todo": source_todo or (existing or {}).get("source_todo", ""),
            "source_stage": source_stage or (existing or {}).get("source_stage", ""),
            "content_hash": digest,
        }
        if existing is None:
            entries.append(record)
        else:
            entries[:] = [record if item.get("key") == key else item for item in entries]

        index["schema_version"] = SCHEMA_VERSION
        atomic_write_json(index_path, index)
        return {
            "key": key,
            "byte_size": len(payload),
            "created_at": record["created_at"],
            "updated_at": record["updated_at"],
            "source_todo": record["source_todo"],
            "source_stage": record["source_stage"],
            "content_hash": digest,
            "created": existing is None,
        }

    result = locked_run(state_root, _write)
    log_action(
        state_root,
        plan_key,
        action="write",
        key=key,
        content_hash_value=result.get("content_hash", ""),
        byte_size=int(result.get("byte_size", 0) or 0),
    )
    return result


def delete_entry(state_root: Path, plan_key: str, key: str) -> dict[str, Any]:
    limits = limits_from_env()
    validate_memory_key(key, limits["max_key_length"])
    root = memory_root(state_root, plan_key)
    index_path = root / "index.json"
    if not index_path.is_file():
        raise MemoryError(f"memory key not found: {key}")

    def _delete() -> dict[str, Any]:
        index = load_index(index_path)
        entries = index.get("entries", [])
        entry = find_entry(entries, key)
        if entry is None:
            raise MemoryError(f"memory key not found: {key}")
        rel_path = entry.get("content_path", "")
        if isinstance(rel_path, str) and rel_path:
            content_path = path_under_root(root, root / rel_path)
            if content_path.is_file():
                content_path.unlink()
        index["entries"] = [item for item in entries if item.get("key") != key]
        index["schema_version"] = SCHEMA_VERSION
        atomic_write_json(index_path, index)
        return {
            "key": key,
            "deleted": True,
            "content_hash": entry.get("content_hash", ""),
            "byte_size": int(entry.get("byte_size", 0) or 0),
        }

    result = locked_run(state_root, _delete)
    log_action(
        state_root,
        plan_key,
        action="delete",
        key=key,
        content_hash_value=result.get("content_hash", ""),
        byte_size=int(result.get("byte_size", 0) or 0),
    )
    return result


def cmd_list(args: argparse.Namespace) -> int:
    state_root = resolve_state_root(args.workspace, args.state_root)
    payload = list_entries(state_root, args.plan_key)
    print(json.dumps(payload, indent=2, sort_keys=True))
    return 0


def cmd_read(args: argparse.Namespace) -> int:
    state_root = resolve_state_root(args.workspace, args.state_root)
    payload = read_entry(state_root, args.plan_key, args.key)
    print(json.dumps(payload, indent=2, sort_keys=True))
    return 0


def cmd_write(args: argparse.Namespace) -> int:
    state_root = resolve_state_root(args.workspace, args.state_root)
    content = sys.stdin.read()
    payload = write_entry(
        state_root,
        args.plan_key,
        args.key,
        content,
        source_todo=args.source_todo or "",
        source_stage=args.source_stage or "",
    )
    print(json.dumps(payload, indent=2, sort_keys=True))
    return 0


def cmd_delete(args: argparse.Namespace) -> int:
    state_root = resolve_state_root(args.workspace, args.state_root)
    payload = delete_entry(state_root, args.plan_key, args.key)
    print(json.dumps(payload, indent=2, sort_keys=True))
    return 0


def cmd_enabled(args: argparse.Namespace) -> int:
    enabled = plan_memory_enabled(
        explicit=args.plan_memory,
        ralph_mode=args.ralph_mode,
    )
    print("1" if enabled else "0")
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Ralph per-plan memory store")
    sub = parser.add_subparsers(dest="command", required=True)

    def add_common(subparser: argparse.ArgumentParser) -> None:
        subparser.add_argument("--workspace", required=True)
        subparser.add_argument("--state-root", default="")
        subparser.add_argument("--plan-key", required=True)

    list_parser = sub.add_parser("list")
    add_common(list_parser)
    list_parser.set_defaults(func=cmd_list)

    read_parser = sub.add_parser("read")
    add_common(read_parser)
    read_parser.add_argument("--key", required=True)
    read_parser.set_defaults(func=cmd_read)

    write_parser = sub.add_parser("write")
    add_common(write_parser)
    write_parser.add_argument("--key", required=True)
    write_parser.add_argument("--source-todo", default="")
    write_parser.add_argument("--source-stage", default="")
    write_parser.set_defaults(func=cmd_write)

    delete_parser = sub.add_parser("delete")
    add_common(delete_parser)
    delete_parser.add_argument("--key", required=True)
    delete_parser.set_defaults(func=cmd_delete)

    enabled_parser = sub.add_parser("enabled")
    enabled_parser.add_argument("--ralph-mode", default="")
    enabled_parser.add_argument("--plan-memory", default="")
    enabled_parser.set_defaults(func=cmd_enabled)

    return parser


def main(argv: list[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    try:
        return args.func(args)
    except MemoryError as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 1
    except ValueError as exc:
        print(str(exc), file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
