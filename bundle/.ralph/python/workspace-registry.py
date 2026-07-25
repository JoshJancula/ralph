#!/usr/bin/env python3
"""Best-effort atomic updater for Ralph's user workspace registry."""

from __future__ import annotations

import json
import os
import sys
import tempfile
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Any


def _abs_path(value: str) -> str:
    return os.path.abspath(os.path.expanduser(value))


def _load_existing(path: Path) -> list[dict[str, Any]]:
    if not path.exists():
        return []
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except Exception:
        return []
    if not isinstance(data, list):
        return []
    records: list[dict[str, Any]] = []
    for item in data:
        if isinstance(item, dict):
            records.append(dict(item))
    return records


def update_registry(registry_path: str, workspace: str, plan_key: str, runtime: str) -> None:
    path = Path(registry_path)
    workspace_abs = _abs_path(workspace)
    now = datetime.now(timezone.utc).isoformat(timespec="seconds").replace("+00:00", "Z")
    new_record = {
        "path": workspace_abs,
        "lastSeen": now,
        "planKey": plan_key,
        "runtime": runtime,
    }

    deduped_reversed: list[dict[str, Any]] = []
    seen: set[str] = set()
    for item in reversed([*_load_existing(path), new_record]):
        existing_path = item.get("path")
        if not isinstance(existing_path, str) or not existing_path:
            continue
        existing_abs = _abs_path(existing_path)
        if existing_abs in seen:
            continue
        item["path"] = existing_abs
        deduped_reversed.append(item)
        seen.add(existing_abs)
    records = list(reversed(deduped_reversed))[-100:]
    _write_registry(path, records)


def _write_registry(path: Path, records: list[dict[str, Any]]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp_name = tempfile.mkstemp(prefix=".workspaces.", suffix=".tmp", dir=str(path.parent))
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            json.dump(records, handle, indent=2)
            handle.write("\n")
        os.replace(tmp_name, path)
    except Exception:
        try:
            os.unlink(tmp_name)
        except FileNotFoundError:
            pass
        raise


def _record_value(record: dict[str, Any], key: str) -> str:
    value = record.get(key, "")
    return value if isinstance(value, str) else ""


def list_registry(registry_path: str) -> None:
    records = _load_existing(Path(registry_path))
    if not records:
        print("No workspaces registered.")
        return

    rows = []
    for record in reversed(records):
        rows.append((
            _record_value(record, "path"),
            _record_value(record, "lastSeen"),
            _record_value(record, "planKey"),
            _record_value(record, "runtime"),
        ))
    headers = ("PATH", "LAST SEEN", "PLAN KEY", "RUNTIME")
    widths = [len(header) for header in headers]
    for row in rows:
        for idx, value in enumerate(row):
            widths[idx] = max(widths[idx], len(value))

    print("  ".join(header.ljust(widths[idx]) for idx, header in enumerate(headers)))
    print("  ".join("-" * width for width in widths))
    for row in rows:
        print("  ".join(value.ljust(widths[idx]) for idx, value in enumerate(row)))


def _parse_last_seen(value: str) -> datetime | None:
    if not value:
        return None
    try:
        parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        return None
    if parsed.tzinfo is None:
        parsed = parsed.replace(tzinfo=timezone.utc)
    return parsed.astimezone(timezone.utc)


def prune_registry(registry_path: str, days: int) -> tuple[int, int]:
    path = Path(registry_path)
    cutoff = datetime.now(timezone.utc) - timedelta(days=days)
    kept = []
    for record in _load_existing(path):
        workspace = _record_value(record, "path")
        last_seen = _parse_last_seen(_record_value(record, "lastSeen"))
        if not workspace or last_seen is None:
            continue
        if not Path(workspace).exists():
            continue
        if last_seen < cutoff:
            continue
        kept.append(record)
    removed = len(_load_existing(path)) - len(kept)
    _write_registry(path, kept)
    return removed, len(kept)


def paths_registry(registry_path: str) -> None:
    """Print absolute, deduped workspace paths that exist on disk."""
    records = _load_existing(Path(registry_path))
    seen: set[str] = set()
    for record in records:
        workspace = _record_value(record, "path")
        if not workspace:
            continue
        abs_workspace = _abs_path(workspace)
        if abs_workspace in seen:
            continue
        if not Path(abs_workspace).is_dir():
            continue
        seen.add(abs_workspace)
        print(abs_workspace)


def main(argv: list[str]) -> int:
    if len(argv) == 5 and argv[1] not in {"list", "prune", "add"}:
        update_registry(argv[1], argv[2], argv[3], argv[4])
        return 0

    if len(argv) < 3:
        print(
            "usage: workspace-registry.py <registry-file> <workspace> <plan-key> <runtime> | "
            "{list|prune|add|paths} <registry-file> [args]",
            file=sys.stderr,
        )
        return 2

    command = argv[1]
    registry_path = argv[2]
    if command == "list" and len(argv) == 3:
        list_registry(registry_path)
        return 0
    if command == "prune" and len(argv) == 4:
        try:
            days = int(argv[3])
        except ValueError:
            print("prune days must be an integer", file=sys.stderr)
            return 2
        if days < 0:
            print("prune days must be non-negative", file=sys.stderr)
            return 2
        removed, kept = prune_registry(registry_path, days)
        print(f"Pruned {removed} workspace(s); kept {kept}.")
        return 0
    if command == "add" and len(argv) == 4:
        workspace = _abs_path(argv[3])
        if not Path(workspace).is_dir():
            print(f"workspace does not exist: {workspace}", file=sys.stderr)
            return 1
        update_registry(registry_path, workspace, "manual", "manual")
        print(f"Added workspace: {workspace}")
        return 0
    if command == "paths" and len(argv) == 3:
        paths_registry(registry_path)
        return 0

    print(f"invalid workspace registry command or arguments: {command}", file=sys.stderr)
    return 2


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
