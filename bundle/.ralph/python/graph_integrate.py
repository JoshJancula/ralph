#!/usr/bin/env python3
"""Deterministically apply graph changeset manifests into an integration workspace."""

from __future__ import annotations

import argparse
import difflib
import hashlib
import json
import os
import shutil
import stat
import sys
import tempfile
from datetime import datetime, timezone
from pathlib import Path, PurePosixPath
from typing import Dict, List, Sequence

from graph_source_snapshot import CaptureError, canonical_json, identity, scan


def load(path: Path) -> dict:
    value = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(value, dict):
        raise CaptureError(f"manifest must be an object: {path}")
    return value


def atomic_json(path: Path, value: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, temporary = tempfile.mkstemp(prefix=".integration-", dir=str(path.parent))
    try:
        with os.fdopen(fd, "wb") as stream:
            stream.write(canonical_json(value) + b"\n")
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


def safe_relative(value: str) -> str:
    pure = PurePosixPath(value)
    if not value or pure.is_absolute() or ".." in pure.parts or "\\" in value:
        raise CaptureError(f"unsafe changeset path: {value}")
    if pure.parts[0] in {".git", ".ralph", ".ralph-workspace"}:
        raise CaptureError(f"changeset targets control path: {value}")
    return pure.as_posix()


def result_signature(change: dict) -> bytes:
    return canonical_json(
        {
            "operation": change.get("operation"),
            "fromPath": change.get("fromPath"),
            "after": change.get("after"),
        }
    )


def conflict_hunks(first: dict, second: dict) -> List[str]:
    left = first["change"]
    right = second["change"]
    left_after = left.get("after") or {}
    right_after = right.get("after") or {}
    if left.get("operation") == "deleted" or right.get("operation") == "deleted":
        return ["delete/modify conflict"]
    if left.get("operation") == "renamed" or right.get("operation") == "renamed":
        return [
            f"rename conflict: {left.get('fromPath')} -> {left.get('path')} vs "
            f"{right.get('fromPath')} -> {right.get('path')}"
        ]
    if left_after.get("type") != "file" or right_after.get("type") != "file":
        return ["file type or metadata differs"]
    try:
        left_blob = first["manifestPath"].parent / str(left["blob"])
        right_blob = second["manifestPath"].parent / str(right["blob"])
        left_bytes = left_blob.read_bytes()
        right_bytes = right_blob.read_bytes()
        if b"\0" in left_bytes[:8192] or b"\0" in right_bytes[:8192]:
            return ["binary content differs"]
        diff = list(
            difflib.unified_diff(
                left_bytes.decode("utf-8", "replace").splitlines(),
                right_bytes.decode("utf-8", "replace").splitlines(),
                fromfile=first["nodeId"],
                tofile=second["nodeId"],
                lineterm="",
            )
        )
        return diff[:200] or ["content metadata differs"]
    except (OSError, KeyError):
        return ["content differs; conflict blobs unavailable"]


def conflicts_for(items: Sequence[dict]) -> tuple[List[dict], List[dict]]:
    owners: Dict[str, dict] = {}
    accepted: List[dict] = []
    conflicts: List[dict] = []
    for item in items:
        change = item["change"]
        paths = [safe_relative(str(change.get("path", "")))]
        if change.get("operation") == "renamed":
            paths.append(safe_relative(str(change.get("fromPath", ""))))
        duplicate = False
        for path in paths:
            prior = owners.get(path)
            if prior is None:
                continue
            if result_signature(prior["change"]) == result_signature(change):
                duplicate = True
                continue
            conflicts.append(
                {
                    "path": path,
                    "firstNode": prior["nodeId"],
                    "secondNode": item["nodeId"],
                    "firstChangeset": str(prior["manifestPath"]),
                    "secondChangeset": str(item["manifestPath"]),
                    "firstOperation": prior["change"].get("operation"),
                    "secondOperation": change.get("operation"),
                    "hunks": conflict_hunks(prior, item),
                }
            )
        if not duplicate and not conflicts:
            accepted.append(item)
        for path in paths:
            owners.setdefault(path, item)
    return accepted, conflicts


def remove_path(path: Path) -> None:
    if path.is_symlink() or path.is_file():
        path.unlink()
    elif path.is_dir():
        shutil.rmtree(path)


def install_after(workspace: Path, item: dict) -> None:
    change = item["change"]
    relative = safe_relative(str(change["path"]))
    target = workspace / relative
    after = change.get("after") or {}
    kind = after.get("type")
    mode = int(after.get("mode", 0o644))
    target.parent.mkdir(parents=True, exist_ok=True)
    if target.exists() or target.is_symlink():
        remove_path(target)
    if kind == "directory":
        target.mkdir(parents=True, exist_ok=True)
        os.chmod(target, mode)
    elif kind == "file":
        blob_rel = str(change.get("blob", ""))
        blob = (item["manifestPath"].parent / blob_rel).resolve()
        if not blob.is_file() or hashlib.sha256(blob.read_bytes()).hexdigest() != after.get("sha256"):
            raise CaptureError(f"missing or corrupt changeset blob for {relative}")
        fd, temporary = tempfile.mkstemp(prefix=".apply-", dir=str(target.parent))
        os.close(fd)
        try:
            shutil.copyfile(blob, temporary)
            os.chmod(temporary, mode)
            os.replace(temporary, target)
        except BaseException:
            try:
                os.unlink(temporary)
            except OSError:
                pass
            raise
    elif kind == "symlink":
        link_target = str(after.get("target", ""))
        if os.path.isabs(link_target):
            raise CaptureError(f"absolute symlink in changeset: {relative}")
        resolved = (target.parent / link_target).resolve(strict=False)
        try:
            resolved.relative_to(workspace)
        except ValueError:
            raise CaptureError(f"escaping symlink in changeset: {relative}")
        os.symlink(link_target, target)
    else:
        raise CaptureError(f"unsupported changeset entry type for {relative}: {kind}")


def integrate(args: argparse.Namespace) -> int:
    workspace = Path(args.workspace).resolve()
    output = Path(args.output).resolve()
    conflict_output = Path(args.conflict_output).resolve()
    if not workspace.is_dir():
        raise CaptureError(f"integration workspace missing: {workspace}")
    if output.exists():
        previous = output.with_name(output.name + ".previous")
        os.replace(output, previous)
    items: List[dict] = []
    input_records: List[dict] = []
    for raw in args.manifest:
        path = Path(raw).resolve()
        if not path.is_file():
            raise CaptureError(f"predecessor changeset missing: {path}")
        manifest = load(path)
        if manifest.get("kind") != "graph-changeset" or manifest.get("schemaVersion") != 1:
            raise CaptureError(f"invalid predecessor changeset: {path}")
        if manifest.get("baseIdentity") != args.base_identity:
            raise CaptureError(
                f"wrong-base changeset {path}: {manifest.get('baseIdentity')} != {args.base_identity}"
            )
        node_id = str(manifest.get("nodeId", ""))
        input_records.append(
            {
                "nodeId": node_id,
                "attemptId": manifest.get("attemptId"),
                "contentIdentity": manifest.get("contentIdentity"),
                "manifestPath": str(path),
            }
        )
        for change in manifest.get("changes", []):
            if not isinstance(change, dict):
                raise CaptureError(f"invalid change entry in {path}")
            items.append(
                {"nodeId": node_id, "manifestPath": path, "change": change}
            )

    accepted, conflicts = conflicts_for(items)
    if conflicts:
        artifact = {
            "schemaVersion": 1,
            "kind": "integration-conflict",
            "integrationNodeId": args.node_id,
            "baseIdentity": args.base_identity,
            "inputs": input_records,
            "conflicts": conflicts,
        }
        atomic_json(conflict_output, artifact)
        raise CaptureError(f"integration conflicts detected; see {conflict_output}")

    # Deletions and rename sources first, deepest paths first. Re-running after
    # interruption is safe because missing deletes are accepted and installs
    # atomically replace their destination.
    removals: List[Path] = []
    for item in accepted:
        change = item["change"]
        if change.get("operation") == "deleted":
            removals.append(workspace / safe_relative(str(change["path"])))
        elif change.get("operation") == "renamed":
            removals.append(workspace / safe_relative(str(change["fromPath"])))
    for target in sorted(removals, key=lambda path: len(path.parts), reverse=True):
        if target.exists() or target.is_symlink():
            remove_path(target)
    interrupt_after = int(os.environ.get("RALPH_GRAPH_INTEGRATION_TEST_INTERRUPT_AFTER", "0") or "0")
    applied_count = 0
    for item in accepted:
        if item["change"].get("operation") != "deleted":
            install_after(workspace, item)
            applied_count += 1
            if interrupt_after and applied_count >= interrupt_after:
                raise CaptureError("simulated interrupted integration apply")

    entries = scan(workspace, {".ralph-workspace"})
    result_identity = identity(entries)
    manifest = {
        "schemaVersion": 1,
        "kind": "graph-integration",
        "nodeId": args.node_id,
        "baseIdentity": args.base_identity,
        "resultIdentity": result_identity,
        "inputs": input_records,
        "appliedOrder": [record["nodeId"] for record in input_records],
        "changeCount": len(accepted),
        "workspacePath": str(workspace),
        "createdAt": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    }
    if conflict_output.exists():
        conflict_output.unlink()
    atomic_json(output, manifest)
    print(canonical_json(manifest).decode("utf-8"))
    return 0


def parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser()
    parser.add_argument("--workspace", required=True)
    parser.add_argument("--output", required=True)
    parser.add_argument("--conflict-output", required=True)
    parser.add_argument("--node-id", required=True)
    parser.add_argument("--base-identity", required=True)
    parser.add_argument("--manifest", action="append", default=[])
    return parser


def main() -> int:
    args = parser().parse_args()
    try:
        return integrate(args)
    except (CaptureError, OSError, ValueError, json.JSONDecodeError) as exc:
        print(f"Error: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
