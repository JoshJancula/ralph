#!/usr/bin/env python3
"""Capture and validate backend-neutral graph node changesets."""

from __future__ import annotations

import argparse
import fnmatch
import hashlib
import json
import os
import shutil
import subprocess
import sys
import tempfile
from datetime import datetime, timezone
from pathlib import Path, PurePosixPath
from typing import Dict, Iterable, List, Sequence

# Reuse the snapshot scanner so source identities, modes, symlink rules, and
# cache exclusions are identical at run-base and changeset boundaries.
from graph_source_snapshot import CaptureError, canonical_json, identity, scan


CONTROL_ROOTS = {".git", ".ralph", ".ralph-workspace"}


def load_json(path: Path) -> dict:
    value = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(value, dict):
        raise CaptureError(f"JSON object required: {path}")
    return value


def manifest_for(workspace: Path) -> dict:
    entries = scan(workspace, {".ralph-workspace"})
    # Runtime-created local state is never project output and must not be part
    # of the optimistic baseline or a publishable changeset.
    entries = [
        entry
        for entry in entries
        if PurePosixPath(str(entry["path"])).parts[0] != ".ralph-workspace"
    ]
    return {
        "schemaVersion": 1,
        "algorithm": "sha256-canonical-manifest-v1",
        "filesystemIdentity": identity(entries),
        "entryCount": len(entries),
        "entries": entries,
    }


def atomic_write(path: Path, payload: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, temporary = tempfile.mkstemp(prefix=".graph-json-", dir=str(path.parent))
    try:
        with os.fdopen(fd, "wb") as stream:
            stream.write(canonical_json(payload) + b"\n")
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
        os.chmod(path, 0o444)
    except BaseException:
        try:
            os.unlink(temporary)
        except OSError:
            pass
        raise


def cmd_baseline(args: argparse.Namespace) -> int:
    workspace = Path(args.workspace).resolve()
    if not workspace.is_dir():
        raise CaptureError(f"workspace is not a directory: {workspace}")
    payload = manifest_for(workspace)
    atomic_write(Path(args.output).resolve(), payload)
    print(canonical_json(payload).decode("utf-8"))
    return 0


def validate_scopes(raw: object) -> List[str]:
    if not isinstance(raw, list) or not raw or not all(isinstance(v, str) for v in raw):
        raise CaptureError("writeScopes must be a non-empty array of strings")
    scopes: List[str] = []
    for value in raw:
        pure = PurePosixPath(value)
        if pure.is_absolute() or ".." in pure.parts or "\\" in value or value in {"", "."}:
            raise CaptureError(f"unsafe write scope: {value}")
        if pure.parts[0] in CONTROL_ROOTS:
            raise CaptureError(f"write scope cannot include control path: {value}")
        scopes.append(pure.as_posix())
    return scopes


def in_scope(path: str, scopes: Sequence[str]) -> bool:
    for pattern in scopes:
        if fnmatch.fnmatchcase(path, pattern):
            return True
        # A recursive ownership pattern also owns the directory that anchors
        # it; otherwise creating `src/` and `src/file` under `src/**` would
        # reject the parent directory while accepting the file.
        if pattern.endswith("/**") and path == pattern[:-3].rstrip("/"):
            return True
        # A directory-like exact scope includes descendants.
        if not any(char in pattern for char in "*?[") and path.startswith(pattern.rstrip("/") + "/"):
            return True
    return False


def entry_map(manifest: dict) -> Dict[str, dict]:
    entries = manifest.get("entries")
    if not isinstance(entries, list):
        raise CaptureError("baseline manifest entries must be an array")
    result: Dict[str, dict] = {}
    for entry in entries:
        if not isinstance(entry, dict) or not isinstance(entry.get("path"), str):
            raise CaptureError("invalid baseline manifest entry")
        result[str(entry["path"])] = entry
    return result


def is_binary(path: Path) -> bool:
    with path.open("rb") as stream:
        return b"\0" in stream.read(8192)


def changed_entries(before: dict, after: dict) -> List[dict]:
    old = entry_map(before)
    new = entry_map(after)
    changes: List[dict] = []
    for path in sorted(set(old) | set(new)):
        prior = old.get(path)
        current = new.get(path)
        if prior == current:
            continue
        if prior is None:
            changes.append({"operation": "added", "path": path, "after": current})
        elif current is None:
            changes.append({"operation": "deleted", "path": path, "before": prior})
        else:
            changes.append(
                {"operation": "modified", "path": path, "before": prior, "after": current}
            )
    return changes


def coalesce_renames(changes: Sequence[dict]) -> List[dict]:
    deleted: Dict[str, List[dict]] = {}
    for change in changes:
        prior = change.get("before") or {}
        if change["operation"] == "deleted" and prior.get("type") == "file":
            deleted.setdefault(str(prior.get("sha256", "")), []).append(change)
    consumed = set()
    result: List[dict] = []
    for change in changes:
        current = change.get("after") or {}
        digest = str(current.get("sha256", ""))
        if change["operation"] == "added" and current.get("type") == "file" and deleted.get(digest):
            prior_change = deleted[digest].pop(0)
            consumed.add(id(prior_change))
            result.append(
                {
                    "operation": "renamed",
                    "fromPath": prior_change["path"],
                    "path": change["path"],
                    "before": prior_change["before"],
                    "after": current,
                }
            )
            consumed.add(id(change))
    result.extend(change for change in changes if id(change) not in consumed)
    return sorted(result, key=lambda item: (str(item.get("path", "")), item["operation"]))


def submodule_paths(workspace: Path) -> set[str]:
    if not (workspace / ".git").exists() or shutil.which("git") is None:
        return set()
    proc = subprocess.run(
        ["git", "-C", str(workspace), "ls-files", "--stage", "-z"],
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
        check=False,
    )
    if proc.returncode != 0:
        return set()
    paths = set()
    for record in proc.stdout.split(b"\0"):
        if record.startswith(b"160000 ") and b"\t" in record:
            paths.add(record.split(b"\t", 1)[1].decode("utf-8", "surrogateescape"))
    return paths


def copy_blob(source: Path, blob: Path) -> None:
    blob.parent.mkdir(parents=True, exist_ok=True)
    if blob.exists():
        return
    fd, temporary = tempfile.mkstemp(prefix=".blob-", dir=str(blob.parent))
    os.close(fd)
    try:
        shutil.copyfile(source, temporary)
        os.replace(temporary, blob)
        os.chmod(blob, 0o444)
    except BaseException:
        try:
            os.unlink(temporary)
        except OSError:
            pass
        raise


def cmd_capture(args: argparse.Namespace) -> int:
    workspace = Path(args.workspace).resolve()
    baseline = load_json(Path(args.baseline).resolve())
    scopes = validate_scopes(json.loads(args.write_scopes_json))
    after = manifest_for(workspace)
    changes = coalesce_renames(changed_entries(baseline, after))
    control = []
    outside = []
    submodules = submodule_paths(workspace)
    for change in changes:
        paths = [str(change["path"])]
        if change["operation"] == "renamed":
            paths.append(str(change["fromPath"]))
        for path in paths:
            root = PurePosixPath(path).parts[0]
            if root in CONTROL_ROOTS or path.endswith(".plan.md"):
                control.append(path)
            if not in_scope(path, scopes):
                outside.append(path)
            if any(path == sub or path.startswith(sub + "/") for sub in submodules):
                control.append(path)
    if control or outside:
        detail = {
            "controlPaths": sorted(set(control)),
            "outOfScope": sorted(set(outside)),
        }
        raise CaptureError("changeset scope verification failed: " + canonical_json(detail).decode("utf-8"))

    output = Path(args.output).resolve()
    blob_root = output.parent / "blobs"
    enriched: List[dict] = []
    for change in changes:
        item = dict(change)
        current = item.get("after") or {}
        if current.get("type") == "file":
            source = workspace / str(item["path"])
            digest = str(current["sha256"])
            copy_blob(source, blob_root / digest)
            item["blob"] = f"blobs/{digest}"
            item["binary"] = is_binary(source)
        enriched.append(item)
    content_identity = hashlib.sha256(canonical_json(enriched)).hexdigest()
    usage = json.loads(args.usage_json) if args.usage_json else None
    payload = {
        "schemaVersion": 1,
        "kind": "graph-changeset",
        "baseIdentity": args.base_identity,
        "baselineIdentity": baseline.get("filesystemIdentity"),
        "resultIdentity": after.get("filesystemIdentity"),
        "contentIdentity": content_identity,
        "nodeId": args.node_id,
        "attemptId": args.attempt_id,
        "workspaceMode": args.workspace_mode,
        "writeScopes": scopes,
        "createdAt": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "changes": enriched,
        "laneVerification": {
            "status": "passed",
            "controlPaths": [],
            "outOfScope": [],
            "concurrentInterferenceDetected": False,
        },
        "usage": usage,
    }
    atomic_write(output, payload)
    print(canonical_json(payload).decode("utf-8"))
    return 0


def parser() -> argparse.ArgumentParser:
    top = argparse.ArgumentParser()
    commands = top.add_subparsers(dest="command", required=True)
    baseline = commands.add_parser("baseline")
    baseline.add_argument("--workspace", required=True)
    baseline.add_argument("--output", required=True)
    baseline.set_defaults(handler=cmd_baseline)
    capture = commands.add_parser("capture")
    capture.add_argument("--workspace", required=True)
    capture.add_argument("--baseline", required=True)
    capture.add_argument("--output", required=True)
    capture.add_argument("--node-id", required=True)
    capture.add_argument("--attempt-id", required=True)
    capture.add_argument("--workspace-mode", required=True, choices=("shared", "snapshot", "worktree"))
    capture.add_argument("--base-identity", required=True)
    capture.add_argument("--write-scopes-json", required=True)
    capture.add_argument("--usage-json")
    capture.set_defaults(handler=cmd_capture)
    return top


def main() -> int:
    args = parser().parse_args()
    try:
        return int(args.handler(args))
    except (CaptureError, OSError, ValueError, json.JSONDecodeError) as exc:
        print(f"Error: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
