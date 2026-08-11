#!/usr/bin/env python3
"""Deterministic, Git-independent source capture for Ralph graph runs."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import glob
import shutil
import stat
import subprocess
import sys
import tempfile
import time
from pathlib import Path, PurePosixPath
from typing import Dict, List, Optional, Sequence, Set, Tuple


DEFAULT_CACHE_NAMES = {
    ".cache",
    ".mypy_cache",
    ".pytest_cache",
    ".ruff_cache",
    ".tox",
    ".venv",
    "__pycache__",
    "node_modules",
}


class CaptureError(RuntimeError):
    pass


def canonical_json(value: object) -> bytes:
    return json.dumps(
        value, ensure_ascii=False, separators=(",", ":"), sort_keys=True
    ).encode("utf-8")


def sha256_bytes(value: bytes) -> str:
    return hashlib.sha256(value).hexdigest()


def read_excludes(
    path: Optional[str], source: Path, state_root: Optional[Path]
) -> Set[str]:
    excludes: Set[str] = set()
    if path:
        for raw in Path(path).read_text(encoding="utf-8").splitlines():
            item = raw.strip()
            if not item or item.startswith("#"):
                continue
            pure = PurePosixPath(item)
            if pure.is_absolute() or ".." in pure.parts or item in {".", ""}:
                raise CaptureError(
                    f"secret exclusion must be a project-relative path: {item}"
                )
            excludes.add(pure.as_posix().rstrip("/"))
    if state_root is not None:
        try:
            state_relative = state_root.resolve().relative_to(source)
        except ValueError:
            pass
        else:
            if state_relative.parts:
                excludes.add(PurePosixPath(*state_relative.parts).as_posix())
    return excludes


def is_excluded(relative: str, explicit: Set[str], source: Optional[Path] = None) -> bool:
    parts = PurePosixPath(relative).parts
    if ".git" in parts:
        return True
    for item in explicit:
        if relative == item or relative.startswith(item + "/"):
            return True
    for index, part in enumerate(parts):
        if part not in DEFAULT_CACHE_NAMES:
            continue
        if source is None:
            return True
        candidate = source.joinpath(*parts[: index + 1])
        if candidate.is_dir() and not candidate.is_symlink():
            return True
    return False


def validate_symlink(
    path: Path, relative: str, source: Path, explicit: Set[str]
) -> None:
    target = os.readlink(path)
    if os.path.isabs(target):
        raise CaptureError(f"unsafe absolute symlink in source: {relative}")
    try:
        resolved = (path.parent / target).resolve(strict=False)
        target_relative = resolved.relative_to(source).as_posix()
    except (OSError, RuntimeError, ValueError):
        raise CaptureError(f"unsafe escaping symlink in source: {relative}")
    if resolved == path or resolved in path.parents:
        raise CaptureError(f"unsafe cyclic symlink in source: {relative}")
    if is_excluded(target_relative, explicit, source):
        raise CaptureError(f"symlink targets excluded source content: {relative}")


def hash_file(path: Path) -> Tuple[str, int]:
    digest = hashlib.sha256()
    size = 0
    with path.open("rb") as stream:
        while True:
            block = stream.read(1024 * 1024)
            if not block:
                break
            digest.update(block)
            size += len(block)
    return digest.hexdigest(), size


def entry_for(path: Path, relative: str) -> Dict[str, object]:
    info = path.lstat()
    mode = stat.S_IMODE(info.st_mode)
    if stat.S_ISDIR(info.st_mode):
        return {"path": relative, "type": "directory", "mode": mode}
    if stat.S_ISREG(info.st_mode):
        digest, size = hash_file(path)
        return {
            "path": relative,
            "type": "file",
            "mode": mode,
            "size": size,
            "sha256": digest,
        }
    if stat.S_ISLNK(info.st_mode):
        return {
            "path": relative,
            "type": "symlink",
            "mode": mode,
            "target": os.readlink(path),
        }
    raise CaptureError(f"unsupported source file type: {relative}")


def scan(source: Path, explicit: Set[str]) -> List[Dict[str, object]]:
    entries: List[Dict[str, object]] = []

    def visit(directory: Path, prefix: PurePosixPath) -> None:
        try:
            children = sorted(os.scandir(directory), key=lambda item: item.name)
        except OSError as exc:
            raise CaptureError(f"cannot read source directory {directory}: {exc}")
        for child in children:
            relative_path = prefix / child.name
            relative = relative_path.as_posix()
            if is_excluded(relative, explicit, source):
                continue
            path = Path(child.path)
            if path.is_symlink():
                validate_symlink(path, relative, source, explicit)
            entry = entry_for(path, relative)
            entries.append(entry)
            if entry["type"] == "directory":
                visit(path, relative_path)

    visit(source, PurePosixPath())
    entries.sort(key=lambda entry: str(entry["path"]))
    return entries


def identity(entries: Sequence[Dict[str, object]]) -> str:
    return sha256_bytes(canonical_json(list(entries)))


def copy_source(
    source: Path, destination: Path, entries: Sequence[Dict[str, object]]
) -> List[Dict[str, object]]:
    destination.mkdir(mode=0o700)
    copied: List[Dict[str, object]] = []
    directories: List[Tuple[Path, int]] = []
    for expected in entries:
        relative = str(expected["path"])
        source_path = source / relative
        target_path = destination / relative
        kind = str(expected["type"])
        mode = int(expected["mode"])
        if kind == "directory":
            target_path.mkdir(mode=0o700)
            directories.append((target_path, mode))
            copied.append(dict(expected))
            continue
        elif kind == "file":
            target_path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
            digest = hashlib.sha256()
            size = 0
            with source_path.open("rb") as source_stream, target_path.open(
                "xb"
            ) as target_stream:
                while True:
                    block = source_stream.read(1024 * 1024)
                    if not block:
                        break
                    target_stream.write(block)
                    digest.update(block)
                    size += len(block)
            os.chmod(target_path, mode)
            copied.append(
                {
                    "path": relative,
                    "type": "file",
                    "mode": mode,
                    "size": size,
                    "sha256": digest.hexdigest(),
                }
            )
            continue
        elif kind == "symlink":
            target_path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
            os.symlink(os.readlink(source_path), target_path)
            copied.append(entry_for(target_path, relative))
            continue
        else:
            raise CaptureError(f"unsupported manifest entry type: {kind}")
        copied.append(entry_for(target_path, relative))
    for path, mode in reversed(directories):
        os.chmod(path, mode)
    copied.sort(key=lambda entry: str(entry["path"]))
    return copied


def capture(args: argparse.Namespace) -> int:
    source = Path(args.source).resolve()
    destination = Path(args.destination).resolve()
    manifest_path = Path(args.manifest).resolve()
    state_root = Path(args.state_root).resolve() if args.state_root else None
    if not source.is_dir():
        raise CaptureError(f"source root is not a directory: {source}")
    if destination.exists():
        raise CaptureError(f"snapshot destination already exists: {destination}")
    if source == destination or source in destination.parents and state_root is None:
        raise CaptureError("snapshot destination inside source requires a state-root exclusion")

    explicit = read_excludes(args.exclude_file, source, state_root)
    before = scan(source, explicit)
    before_identity = identity(before)
    if args.ready_file:
        Path(args.ready_file).write_text("ready\n", encoding="utf-8")
    if args.delay_ms:
        time.sleep(args.delay_ms / 1000.0)

    destination.parent.mkdir(parents=True, exist_ok=True)
    temporary = Path(
        tempfile.mkdtemp(prefix=".source-capture-", dir=str(destination.parent))
    )
    try:
        temporary.rmdir()
        copied = copy_source(source, temporary, before)
        copied_identity = identity(copied)
        after = scan(source, explicit)
        after_identity = identity(after)
        if not (
            before_identity == copied_identity
            and before_identity == after_identity
            and before == copied
            and before == after
        ):
            raise CaptureError("source changed while materializing frozen run base")
        os.replace(temporary, destination)
    except BaseException:
        shutil.rmtree(temporary, ignore_errors=True)
        raise

    manifest = {
        "schemaVersion": 1,
        "algorithm": "sha256-canonical-manifest-v1",
        "filesystemIdentity": before_identity,
        "entryCount": len(before),
        "entries": before,
    }
    manifest_path.parent.mkdir(parents=True, exist_ok=True)
    manifest_temp = manifest_path.with_name(manifest_path.name + ".tmp")
    manifest_temp.write_bytes(canonical_json(manifest) + b"\n")
    os.replace(manifest_temp, manifest_path)
    sys.stdout.write(canonical_json(manifest).decode("utf-8") + "\n")
    return 0


def git_status(args: argparse.Namespace) -> int:
    source = Path(args.source).resolve()
    state_root = Path(args.state_root).resolve() if args.state_root else None
    explicit = read_excludes(args.exclude_file, source, state_root)
    raw = Path(args.status_file).read_bytes().split(b"\0")
    records: List[Dict[str, str]] = []
    index = 0
    while index < len(raw):
        record = raw[index]
        index += 1
        if not record:
            continue
        text = record.decode("utf-8", "surrogateescape")
        if len(text) < 4:
            raise CaptureError("invalid git status record")
        code = text[:2]
        path = text[3:]
        original = ""
        if "R" in code or "C" in code:
            if index >= len(raw):
                raise CaptureError("truncated git rename status record")
            original = raw[index].decode("utf-8", "surrogateescape")
            index += 1
        paths = [path] + ([original] if original else [])
        if all(is_excluded(item, explicit, source) for item in paths):
            continue
        item = {"code": code, "path": path}
        if original:
            item["originalPath"] = original
        records.append(item)
    records.sort(key=lambda item: (item["path"], item["code"], item.get("originalPath", "")))
    payload = {
        "clean": not records,
        "fingerprint": sha256_bytes(canonical_json(records)),
        "entryCount": len(records),
    }
    sys.stdout.write(canonical_json(payload).decode("utf-8") + "\n")
    return 0


def source_identity(args: argparse.Namespace) -> int:
    source = Path(args.source).resolve()
    state_root = Path(args.state_root).resolve() if args.state_root else None
    if not source.is_dir():
        raise CaptureError(f"source root is not a directory: {source}")
    explicit = read_excludes(args.exclude_file, source, state_root)
    entries = scan(source, explicit)
    payload = {
        "filesystemIdentity": identity(entries),
        "entryCount": len(entries),
    }
    sys.stdout.write(canonical_json(payload).decode("utf-8") + "\n")
    return 0


def validate_relative_pattern(value: str, label: str, allow_glob: bool) -> str:
    if not value or "\\" in value:
        raise CaptureError(f"{label} must be a non-empty POSIX project-relative path: {value}")
    pure = PurePosixPath(value)
    if pure.is_absolute() or ".." in pure.parts or value in {".", ""}:
        raise CaptureError(f"{label} must be a project-relative path: {value}")
    if not allow_glob and any(char in value for char in "*?["):
        raise CaptureError(f"{label} must name an exact path, not a glob: {value}")
    if ".git" in pure.parts:
        raise CaptureError(f"{label} cannot include Git metadata: {value}")
    return pure.as_posix().rstrip("/")


def path_is_under(relative: str, allowed: str) -> bool:
    return relative == allowed or relative.startswith(allowed + "/")


def git_ignored_paths(source: Path, relatives: Sequence[str]) -> Set[str]:
    git_dir = source / ".git"
    if not git_dir.exists() or not shutil.which("git") or not relatives:
        return set()
    process = subprocess.run(
        ["git", "-C", str(source), "check-ignore", "--stdin", "-z"],
        input=("\0".join(relatives) + "\0").encode("utf-8"),
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )
    if process.returncode not in {0, 1}:
        raise CaptureError("failed to classify ignored setup-profile paths")
    return {
        item.decode("utf-8", "surrogateescape")
        for item in process.stdout.split(b"\0")
        if item
    }


def copy_profile_entry(source: Path, destination: Path, relative: str) -> None:
    source_path = source / relative
    destination_path = destination / relative
    try:
        resolved = source_path.resolve(strict=True)
        resolved.relative_to(source)
    except (OSError, RuntimeError, ValueError):
        raise CaptureError(f"setup include escapes the project root: {relative}")
    current = source_path
    while current != source:
        if current.is_symlink():
            raise CaptureError(f"setup include must not contain symlinks: {relative}")
        current = current.parent
    if source_path.is_symlink():
        raise CaptureError(f"setup include must not be a symlink: {relative}")
    if source_path.is_dir():
        for root, directories, files in os.walk(source_path, followlinks=False):
            root_path = Path(root)
            for name in directories + files:
                child = root_path / name
                if child.is_symlink():
                    child_relative = child.relative_to(source).as_posix()
                    raise CaptureError(
                        f"setup include must not contain symlinks: {child_relative}"
                    )
        destination_path.parent.mkdir(parents=True, exist_ok=True)
        if destination_path.exists():
            shutil.rmtree(destination_path)
        shutil.copytree(source_path, destination_path, symlinks=False)
    elif source_path.is_file():
        destination_path.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(source_path, destination_path)
    else:
        raise CaptureError(f"unsupported setup include file type: {relative}")


def profile_entry_paths(source: Path, relative: str) -> Set[str]:
    source_path = source / relative
    try:
        resolved = source_path.resolve(strict=True)
        resolved.relative_to(source)
    except (OSError, RuntimeError, ValueError):
        raise CaptureError(f"setup include escapes the project root: {relative}")
    current = source_path
    while current != source:
        if current.is_symlink():
            raise CaptureError(f"setup include must not contain symlinks: {relative}")
        current = current.parent
    paths = {relative}
    if source_path.is_dir():
        for root, directories, files in os.walk(source_path, followlinks=False):
            root_path = Path(root)
            for name in directories + files:
                child = root_path / name
                child_relative = child.relative_to(source).as_posix()
                if child.is_symlink():
                    raise CaptureError(
                        f"setup include must not contain symlinks: {child_relative}"
                    )
                paths.add(child_relative)
    elif not source_path.is_file():
        raise CaptureError(f"unsupported setup include file type: {relative}")
    return paths


def copy_includes(args: argparse.Namespace) -> int:
    source = Path(args.source).resolve()
    destination = Path(args.destination).resolve()
    if not source.is_dir() or not destination.is_dir():
        raise CaptureError("setup include source and destination must be directories")
    profile = json.loads(args.profile_json)
    if not isinstance(profile, dict):
        raise CaptureError("setup profile must be an object")
    patterns = profile.get("includePatterns", [])
    allowed_raw = profile.get("allowedIgnoredPaths", [])
    if not isinstance(patterns, list) or not all(isinstance(item, str) for item in patterns):
        raise CaptureError("setup profile includePatterns must be an array of strings")
    if not isinstance(allowed_raw, list) or not all(
        isinstance(item, str) for item in allowed_raw
    ):
        raise CaptureError("setup profile allowedIgnoredPaths must be an array of strings")
    allowed = {
        validate_relative_pattern(item, "allowed ignored path", False)
        for item in allowed_raw
    }
    secret_raw = json.loads(args.secret_excludes_json or "[]")
    if not isinstance(secret_raw, list) or not all(
        isinstance(item, str) for item in secret_raw
    ):
        raise CaptureError("secret exclusions must be an array of strings")
    secrets = {
        validate_relative_pattern(item, "secret exclusion", False)
        for item in secret_raw
        if item
    }
    matches: Set[str] = set()
    for raw_pattern in patterns:
        pattern = validate_relative_pattern(raw_pattern, "setup include pattern", True)
        absolute_pattern = str(source / pattern)
        resolved_matches = sorted(glob.glob(absolute_pattern, recursive=True))
        if not resolved_matches:
            raise CaptureError(f"setup include pattern did not match any path: {pattern}")
        for match in resolved_matches:
            relative = Path(match).relative_to(source).as_posix()
            validate_relative_pattern(relative, "setup include match", False)
            matches.add(relative)
    included_paths: Set[str] = set()
    for relative in sorted(matches):
        included_paths.update(profile_entry_paths(source, relative))
    ignored = git_ignored_paths(source, sorted(included_paths))
    for relative in sorted(included_paths):
        is_secret = any(path_is_under(relative, item) for item in secrets)
        is_ignored = relative in ignored
        if (is_secret or is_ignored) and not any(
            path_is_under(relative, item) for item in allowed
        ):
            classification = "secret" if is_secret else "ignored"
            raise CaptureError(
                f"setup include {relative} is {classification}; "
                "name it in allowedIgnoredPaths to copy it"
            )
    for relative in sorted(matches):
        copy_profile_entry(source, destination, relative)
    payload = {"copied": sorted(matches), "count": len(matches)}
    sys.stdout.write(canonical_json(payload).decode("utf-8") + "\n")
    return 0


def scrub_excludes(args: argparse.Namespace) -> int:
    destination = Path(args.destination).resolve()
    if not destination.is_dir():
        raise CaptureError("secret scrub destination must be a directory")
    secret_raw = json.loads(args.secret_excludes_json or "[]")
    if not isinstance(secret_raw, list) or not all(
        isinstance(item, str) for item in secret_raw
    ):
        raise CaptureError("secret exclusions must be an array of strings")
    removed: List[str] = []
    for raw in sorted(set(secret_raw)):
        if not raw:
            continue
        relative = validate_relative_pattern(raw, "secret exclusion", False)
        target = destination / relative
        try:
            target.parent.resolve(strict=True).relative_to(destination)
        except (OSError, RuntimeError, ValueError):
            raise CaptureError(f"secret exclusion escapes the workspace: {relative}")
        if target.is_symlink() or target.is_file():
            target.unlink()
            removed.append(relative)
        elif target.is_dir():
            shutil.rmtree(target)
            removed.append(relative)
    payload = {"removed": removed, "count": len(removed)}
    sys.stdout.write(canonical_json(payload).decode("utf-8") + "\n")
    return 0


def parser() -> argparse.ArgumentParser:
    top = argparse.ArgumentParser()
    subparsers = top.add_subparsers(dest="command", required=True)

    capture_parser = subparsers.add_parser("capture")
    capture_parser.add_argument("--source", required=True)
    capture_parser.add_argument("--destination", required=True)
    capture_parser.add_argument("--manifest", required=True)
    capture_parser.add_argument("--state-root")
    capture_parser.add_argument("--exclude-file")
    capture_parser.add_argument("--delay-ms", type=int, default=0)
    capture_parser.add_argument("--ready-file")
    capture_parser.set_defaults(handler=capture)

    status_parser = subparsers.add_parser("git-status")
    status_parser.add_argument("--source", required=True)
    status_parser.add_argument("--status-file", required=True)
    status_parser.add_argument("--state-root")
    status_parser.add_argument("--exclude-file")
    status_parser.set_defaults(handler=git_status)

    identity_parser = subparsers.add_parser("identity")
    identity_parser.add_argument("--source", required=True)
    identity_parser.add_argument("--state-root")
    identity_parser.add_argument("--exclude-file")
    identity_parser.set_defaults(handler=source_identity)

    includes_parser = subparsers.add_parser("copy-includes")
    includes_parser.add_argument("--source", required=True)
    includes_parser.add_argument("--destination", required=True)
    includes_parser.add_argument("--profile-json", required=True)
    includes_parser.add_argument("--secret-excludes-json", default="[]")
    includes_parser.set_defaults(handler=copy_includes)

    scrub_parser = subparsers.add_parser("scrub-excludes")
    scrub_parser.add_argument("--destination", required=True)
    scrub_parser.add_argument("--secret-excludes-json", default="[]")
    scrub_parser.set_defaults(handler=scrub_excludes)
    return top


def main() -> int:
    args = parser().parse_args()
    try:
        return int(args.handler(args))
    except (CaptureError, OSError, ValueError) as exc:
        print(f"Error: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
