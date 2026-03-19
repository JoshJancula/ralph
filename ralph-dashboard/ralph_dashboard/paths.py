from __future__ import annotations

from pathlib import Path, PurePosixPath

REPO_ROOT = Path(__file__).resolve().parent.parent.parent
STATIC_DIR = Path(__file__).resolve().parent.parent / "static"
ALLOWED_ROOTS = {
    "plans": REPO_ROOT / ".agents" / "orchestration-plans",
    "artifacts": REPO_ROOT / ".agents" / "artifacts",
    "logs": REPO_ROOT / ".agents" / "logs",
    "docs": REPO_ROOT / "docs",
    "cursor_agents": REPO_ROOT / ".cursor" / "agents",
    "claude_agents": REPO_ROOT / ".claude" / "agents",
    "codex_agents": REPO_ROOT / ".codex" / "agents",
    "cursor_skills": REPO_ROOT / ".cursor" / "skills",
    "claude_skills": REPO_ROOT / ".claude" / "skills",
    "codex_skills": REPO_ROOT / ".codex" / "skills",
}


def clean_relative_path(raw_path: str) -> Path:
    normalized_input = raw_path or ""
    relative = PurePosixPath(normalized_input or ".")
    if relative.is_absolute():
        raise ValueError("absolute paths are not allowed")

    segments = normalized_input.split("/") if normalized_input else []
    while len(segments) > 1 and segments[-1] == "":
        segments.pop()

    normalized = Path(".")
    for segment in segments:
        if segment == ".":
            continue
        if segment == "" or segment == "..":
            raise ValueError("path traversal is not allowed")
        normalized /= segment
    return normalized


def resolve_allowed_path(root_key: str, raw_path: str) -> Path:
    try:
        base = ALLOWED_ROOTS[root_key].resolve(strict=True)
    except KeyError as exc:
        raise ValueError(f"unknown root: {root_key}") from exc

    target = (base / clean_relative_path(raw_path)).resolve()
    if not target.is_relative_to(base):
        raise ValueError("requested path escapes allowlisted root")
    return target
