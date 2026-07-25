#!/usr/bin/env python3
"""Validate Ralph skill packages and optional agent version fields (stdlib only)."""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
from pathlib import Path

from context_metadata import extract_frontmatter, parse_frontmatter_dict

MAX_NAME_LEN = 64
MAX_DESCRIPTION_LEN = 1024
PACKAGE_NAME_RE = re.compile(r"^[a-z0-9]+(-[a-z0-9]+)*$")
SEMVER_RE = re.compile(
    r"^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)"
    r"(-[0-9A-Za-z-]+(\.[0-9A-Za-z-]+)*)?"
    r"(\+[0-9A-Za-z-]+(\.[0-9A-Za-z-]+)*)?$"
)
RESOURCE_DIRS = ("scripts", "resources")


def _fail(message: str) -> None:
    print(message, file=sys.stderr)
    sys.exit(1)


def is_env_secret_basename(name: str) -> bool:
    return bool(name) and name.startswith(".env")


def valid_package_name(name: str) -> bool:
    if not name or len(name) > MAX_NAME_LEN:
        return False
    return PACKAGE_NAME_RE.fullmatch(name) is not None


def valid_description(description: str) -> bool:
    return bool(description.strip()) and len(description) <= MAX_DESCRIPTION_LEN


def valid_semver(version: str) -> bool:
    return bool(version.strip()) and SEMVER_RE.fullmatch(version.strip()) is not None


def _read_skill_frontmatter(skill_md: Path) -> dict[str, object]:
    try:
        text = skill_md.read_text(encoding="utf-8", errors="replace")
    except OSError as exc:
        _fail(f"could not read {skill_md}: {exc}")
    fm_lines = extract_frontmatter(text)
    if not fm_lines:
        _fail(f"missing or malformed frontmatter in {skill_md}")
    return parse_frontmatter_dict(fm_lines)


def _resolve_within_package(package_dir: Path, rel_path: str) -> Path:
    rel = Path(rel_path)
    if rel.is_absolute() or ".." in rel.parts:
        _fail(f"path traversal blocked: {rel_path}")
    candidate = (package_dir / rel).resolve()
    package_real = package_dir.resolve()
    try:
        candidate.relative_to(package_real)
    except ValueError:
        _fail(f"path escapes package directory: {rel_path}")
    return candidate


def _validate_resource_entry(package_dir: Path, rel_path: str) -> None:
    target = _resolve_within_package(package_dir, rel_path)
    if not target.exists():
        _fail(f"missing package resource: {rel_path}")
    if target.is_symlink():
        real = target.resolve()
        try:
            real.relative_to(package_dir.resolve())
        except ValueError:
            _fail(f"escaping symlink in package: {rel_path}")
    if target.is_dir():
        _fail(f"expected file, found directory: {rel_path}")
    if is_env_secret_basename(target.name):
        _fail(f"secret-like file blocked in package: {rel_path}")


def list_package_resources(package_dir: Path) -> list[str]:
    resources: list[str] = []
    for subdir in RESOURCE_DIRS:
        root = package_dir / subdir
        if not root.is_dir():
            continue
        for dirpath, dirnames, filenames in os.walk(root):
            dirnames[:] = sorted(dirnames)
            rel_dir = Path(dirpath).relative_to(package_dir)
            for filename in sorted(filenames):
                rel = (rel_dir / filename).as_posix()
                resources.append(rel)
    return sorted(resources)


def validate_skill_package(package_dir: Path, skill_id: str) -> dict[str, str]:
    package_dir = package_dir.resolve()
    if not package_dir.is_dir():
        _fail(f"skill package directory not found: {package_dir}")

    skill_md = package_dir / "SKILL.md"
    if not skill_md.is_file():
        _fail(f"missing required SKILL.md in {package_dir}")

    fm = _read_skill_frontmatter(skill_md)
    name = fm.get("name")
    description = fm.get("description")
    version = fm.get("version")

    if not isinstance(name, str) or not valid_package_name(name):
        _fail(f"invalid skill name in {skill_md}")
    if name != skill_id:
        _fail(f"skill name '{name}' must match directory name '{skill_id}'")
    if not isinstance(description, str) or not valid_description(description):
        _fail(f"invalid skill description in {skill_md}")
    if version is not None:
        if not isinstance(version, str) or not valid_semver(version):
            _fail(f"invalid skill version in {skill_md}")

    for rel in list_package_resources(package_dir):
        _validate_resource_entry(package_dir, rel)

    for subdir in RESOURCE_DIRS:
        candidate = package_dir / subdir
        if candidate.exists() and candidate.is_symlink():
            _fail(f"escaping symlink in package: {subdir}/")

    result = {
        "name": name,
        "description": description.strip(),
        "skill_id": skill_id,
    }
    if isinstance(version, str) and version.strip():
        result["version"] = version.strip()
    return result


def validate_agent_version(agent_file: Path, agent_id: str | None = None) -> str | None:
    fm = _read_skill_frontmatter(agent_file)
    version = fm.get("version")
    if version is None:
        return None
    if not isinstance(version, str) or not valid_semver(version):
        _fail(f"invalid agent version in {agent_file}")
    if agent_id is not None:
        name = fm.get("name")
        if isinstance(name, str) and name.strip() and name.strip() != agent_id:
            _fail(f"agent name '{name}' must match id '{agent_id}'")
    return version.strip()


def cmd_validate(args: argparse.Namespace) -> int:
    meta = validate_skill_package(Path(args.package_dir), args.skill_id)
    if args.json:
        print(json.dumps(meta, sort_keys=True))
    return 0


def cmd_list_resources(args: argparse.Namespace) -> int:
    package_dir = Path(args.package_dir)
    for rel in list_package_resources(package_dir):
        print(rel)
    return 0


def cmd_validate_agent(args: argparse.Namespace) -> int:
    version = validate_agent_version(Path(args.agent_file), args.agent_id)
    if args.json:
        payload: dict[str, object] = {"version": version}
        print(json.dumps(payload, sort_keys=True))
    elif version:
        print(version)
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Ralph skill package validation")
    sub = parser.add_subparsers(dest="command", required=True)

    validate = sub.add_parser("validate", help="Validate a skill package directory")
    validate.add_argument("--package-dir", required=True)
    validate.add_argument("--skill-id", required=True)
    validate.add_argument("--json", action="store_true")
    validate.set_defaults(func=cmd_validate)

    resources = sub.add_parser("list-resources", help="List package resource paths")
    resources.add_argument("--package-dir", required=True)
    resources.set_defaults(func=cmd_list_resources)

    agent = sub.add_parser("validate-agent", help="Validate optional agent version")
    agent.add_argument("--agent-file", required=True)
    agent.add_argument("--agent-id")
    agent.add_argument("--json", action="store_true")
    agent.set_defaults(func=cmd_validate_agent)

    return parser


def main(argv: list[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    return args.func(args)


if __name__ == "__main__":
    raise SystemExit(main())
