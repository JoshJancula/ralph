#!/usr/bin/env python3
"""Guarded, journaled application of a graph integration changeset."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import shutil
import sys
import tempfile
from datetime import datetime, timezone
from pathlib import Path, PurePosixPath
from typing import Dict, Iterable, List

from graph_source_snapshot import CaptureError, canonical_json, identity, scan


CONTROL_ROOTS = {".git", ".ralph-workspace"}


def now() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def load_json(path: Path) -> dict:
    value = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(value, dict):
        raise CaptureError(f"JSON object required: {path}")
    return value


def atomic_json(path: Path, value: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, temporary = tempfile.mkstemp(prefix=".publish-", dir=str(path.parent))
    try:
        with os.fdopen(fd, "wb") as stream:
            stream.write(canonical_json(value) + b"\n")
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
    except BaseException:
        try:
            os.unlink(temporary)
        except OSError:
            pass
        raise


def append_journal(journal_path: Path, event: str, **fields: object) -> None:
    journal_path.parent.mkdir(parents=True, exist_ok=True)
    record = {"at": now(), "event": event, **fields}
    with journal_path.open("ab") as stream:
        stream.write(canonical_json(record) + b"\n")
        stream.flush()
        os.fsync(stream.fileno())


def safe_relative(value: str) -> str:
    pure = PurePosixPath(value)
    if (
        not value
        or pure.is_absolute()
        or ".." in pure.parts
        or "\\" in value
        or pure.parts[0] in CONTROL_ROOTS
    ):
        raise CaptureError(f"unsafe publish path: {value}")
    return pure.as_posix()


def workspace_identity(workspace: Path) -> str:
    entries = scan(workspace, {".ralph-workspace"})
    entries = [
        item
        for item in entries
        if PurePosixPath(str(item["path"])).parts[0] != ".ralph-workspace"
    ]
    return identity(entries)


def remove_path(path: Path) -> None:
    if path.is_symlink() or path.is_file():
        path.unlink()
    elif path.is_dir():
        shutil.rmtree(path)


def copy_path(source: Path, destination: Path) -> None:
    destination.parent.mkdir(parents=True, exist_ok=True)
    if source.is_symlink():
        os.symlink(os.readlink(source), destination)
    elif source.is_dir():
        shutil.copytree(source, destination, symlinks=True)
    else:
        shutil.copy2(source, destination, follow_symlinks=False)


def minimal_roots(paths: Iterable[str]) -> List[str]:
    ordered = sorted({safe_relative(value) for value in paths}, key=lambda value: (len(PurePosixPath(value).parts), value))
    roots: List[str] = []
    for value in ordered:
        parts = PurePosixPath(value).parts
        if any(parts[: len(PurePosixPath(root).parts)] == PurePosixPath(root).parts for root in roots):
            continue
        roots.append(value)
    return roots


def install_after(workspace: Path, manifest_dir: Path, change: dict) -> None:
    relative = safe_relative(str(change["path"]))
    target = workspace / relative
    after = change.get("after") or {}
    kind = after.get("type")
    mode = int(after.get("mode", 0o644))
    target.parent.mkdir(parents=True, exist_ok=True)
    if kind == "directory":
        if target.is_symlink() or (target.exists() and not target.is_dir()):
            remove_path(target)
        target.mkdir(parents=True, exist_ok=True)
        os.chmod(target, mode)
        return
    if kind == "file":
        blob = (manifest_dir / str(change.get("blob", ""))).resolve()
        expected = str(after.get("sha256", ""))
        if not blob.is_file() or hashlib.sha256(blob.read_bytes()).hexdigest() != expected:
            raise CaptureError(f"missing or corrupt publish blob for {relative}")
        fd, temporary = tempfile.mkstemp(prefix=".publish-apply-", dir=str(target.parent))
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
        return
    if kind == "symlink":
        link_target = str(after.get("target", ""))
        if os.path.isabs(link_target):
            raise CaptureError(f"absolute symlink in publish changeset: {relative}")
        resolved = (target.parent / link_target).resolve(strict=False)
        try:
            resolved.relative_to(workspace)
        except ValueError as exc:
            raise CaptureError(f"escaping symlink in publish changeset: {relative}") from exc
        if target.exists() or target.is_symlink():
            remove_path(target)
        os.symlink(link_target, target)
        return
    raise CaptureError(f"unsupported publish entry type for {relative}: {kind}")


def recovery_payload(
    status: str,
    workspace: Path,
    integration_workspace: Path,
    journal: Path,
    command: str,
    detail: str,
) -> dict:
    return {
        "schemaVersion": 1,
        "kind": "graph-publish-recovery",
        "status": status,
        "callerWorkspace": str(workspace),
        "integrationWorkspace": str(integration_workspace),
        "journalPath": str(journal),
        "detail": detail,
        "instructions": [
            "Do not reset, stash, checkout, or delete caller changes.",
            "Preserve any caller edits, then restore the caller workspace to the exact frozen run base.",
            f"Retry with: {command}",
        ],
        "updatedAt": now(),
    }


def apply(args: argparse.Namespace) -> int:
    workspace = Path(args.workspace).resolve()
    integration_workspace = Path(args.integration_workspace).resolve()
    manifest_path = Path(args.manifest).resolve()
    status_path = Path(args.status).resolve()
    journal_path = Path(args.journal).resolve()
    recovery_path = Path(args.recovery).resolve()
    backup_root = recovery_path.parent / "backups" / datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%S%fZ")
    if not workspace.is_dir() or not integration_workspace.is_dir():
        raise CaptureError("caller and integration workspaces must exist")
    manifest = load_json(manifest_path)
    if manifest.get("kind") != "graph-changeset" or manifest.get("schemaVersion") != 1:
        raise CaptureError("invalid publish changeset")
    if manifest.get("baseIdentity") != args.expected_base_identity:
        raise CaptureError("publish changeset does not match frozen run base")
    if manifest.get("resultIdentity") != args.expected_result_identity:
        raise CaptureError("publish changeset does not match verified integration result")

    current = workspace_identity(workspace)
    if current == args.expected_result_identity:
        append_journal(journal_path, "publish-noop", filesystemIdentity=current)
        atomic_json(
            status_path,
            {
                "schemaVersion": 1,
                "kind": "graph-publish-status",
                "status": "published",
                "filesystemIdentity": current,
                "idempotent": True,
                "updatedAt": now(),
            },
        )
        return 0
    if current != args.expected_base_identity:
        raise CaptureError(
            f"caller filesystem identity drifted: expected {args.expected_base_identity}, found {current}"
        )

    changes = manifest.get("changes", [])
    if not isinstance(changes, list) or not all(isinstance(item, dict) for item in changes):
        raise CaptureError("invalid publish change list")
    affected: List[str] = []
    for change in changes:
        affected.append(safe_relative(str(change.get("path", ""))))
        if change.get("operation") == "renamed":
            affected.append(safe_relative(str(change.get("fromPath", ""))))
    roots = minimal_roots(affected)
    backups: Dict[str, Path | None] = {}
    backup_root.mkdir(parents=True, exist_ok=False)
    append_journal(journal_path, "publish-started", baseIdentity=current, backupRoot=str(backup_root))
    for index, relative in enumerate(roots):
        source = workspace / relative
        backup = backup_root / f"{index:06d}"
        if source.exists() or source.is_symlink():
            copy_path(source, backup)
            backups[relative] = backup
            append_journal(journal_path, "backup-completed", path=relative, backupPath=str(backup))
        else:
            backups[relative] = None
            append_journal(journal_path, "backup-completed", path=relative, backupPath=None)

    applied_count = 0
    interrupt_after = int(os.environ.get("RALPH_GRAPH_PUBLISH_TEST_INTERRUPT_AFTER", "0") or "0")
    try:
        removals: List[str] = []
        for change in changes:
            if change.get("operation") == "deleted":
                removals.append(safe_relative(str(change["path"])))
            elif change.get("operation") == "renamed":
                removals.append(safe_relative(str(change["fromPath"])))
        for relative in sorted(set(removals), key=lambda value: len(PurePosixPath(value).parts), reverse=True):
            target = workspace / relative
            append_journal(journal_path, "filesystem-action-started", action="remove", path=relative)
            if target.exists() or target.is_symlink():
                remove_path(target)
            append_journal(journal_path, "filesystem-action-completed", action="remove", path=relative)
            applied_count += 1
            if interrupt_after and applied_count >= interrupt_after:
                raise RuntimeError("simulated publish interruption")
        for change in changes:
            if change.get("operation") == "deleted":
                continue
            relative = safe_relative(str(change["path"]))
            append_journal(journal_path, "filesystem-action-started", action="install", path=relative)
            install_after(workspace, manifest_path.parent, change)
            append_journal(journal_path, "filesystem-action-completed", action="install", path=relative)
            applied_count += 1
            if interrupt_after and applied_count >= interrupt_after:
                raise RuntimeError("simulated publish interruption")
        result = workspace_identity(workspace)
        if result != args.expected_result_identity:
            raise CaptureError(
                f"published filesystem identity mismatch: expected {args.expected_result_identity}, found {result}"
            )
    except BaseException as exc:
        append_journal(journal_path, "rollback-started", detail=str(exc))
        rollback_errors: List[str] = []
        for relative in sorted(roots, key=lambda value: len(PurePosixPath(value).parts), reverse=True):
            target = workspace / relative
            try:
                if target.exists() or target.is_symlink():
                    remove_path(target)
                backup = backups[relative]
                if backup is not None:
                    copy_path(backup, target)
                append_journal(journal_path, "rollback-action-completed", path=relative)
            except BaseException as rollback_exc:
                rollback_errors.append(f"{relative}: {rollback_exc}")
                append_journal(journal_path, "rollback-action-failed", path=relative, detail=str(rollback_exc))
        restored = workspace_identity(workspace)
        rolled_back = restored == args.expected_base_identity and not rollback_errors
        detail = str(exc)
        if rollback_errors:
            detail += "; rollback errors: " + "; ".join(rollback_errors)
        append_journal(
            journal_path,
            "rollback-completed" if rolled_back else "rollback-incomplete",
            filesystemIdentity=restored,
            detail=detail,
        )
        atomic_json(
            recovery_path,
            recovery_payload(
                "rolled-back" if rolled_back else "recovery-required",
                workspace,
                integration_workspace,
                journal_path,
                args.recovery_command,
                detail,
            ),
        )
        atomic_json(
            status_path,
            {
                "schemaVersion": 1,
                "kind": "graph-publish-status",
                "status": "rolled-back" if rolled_back else "recovery-required",
                "filesystemIdentity": restored,
                "detail": detail,
                "updatedAt": now(),
            },
        )
        raise

    append_journal(journal_path, "publish-completed", filesystemIdentity=args.expected_result_identity)
    atomic_json(
        recovery_path,
        recovery_payload(
            "published",
            workspace,
            integration_workspace,
            journal_path,
            args.recovery_command,
            "No recovery is required.",
        ),
    )
    atomic_json(
        status_path,
        {
            "schemaVersion": 1,
            "kind": "graph-publish-status",
            "status": "published",
            "filesystemIdentity": args.expected_result_identity,
            "idempotent": False,
            "updatedAt": now(),
        },
    )
    return 0


def parser() -> argparse.ArgumentParser:
    top = argparse.ArgumentParser()
    top.add_argument("--workspace", required=True)
    top.add_argument("--integration-workspace", required=True)
    top.add_argument("--manifest", required=True)
    top.add_argument("--expected-base-identity", required=True)
    top.add_argument("--expected-result-identity", required=True)
    top.add_argument("--status", required=True)
    top.add_argument("--journal", required=True)
    top.add_argument("--recovery", required=True)
    top.add_argument("--recovery-command", required=True)
    return top


def main() -> int:
    args = parser().parse_args()
    try:
        return apply(args)
    except (CaptureError, OSError, ValueError, json.JSONDecodeError, RuntimeError) as exc:
        print(f"graph-publish: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
