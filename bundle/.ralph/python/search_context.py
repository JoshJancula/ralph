#!/usr/bin/env python3
"""Deterministic search context lookup with state-root cache (stdlib only)."""
from __future__ import annotations

import hashlib
import json
import os
import re
from dataclasses import dataclass
from pathlib import Path
from typing import Any

_HEADING_MD_RE = re.compile(r"^(#{1,6})\s+(.+?)\s*$")
_HEADING_ASCIIDOC_RE = re.compile(r"^(=+)\s+(.+?)\s*$")
_DOC_SUFFIXES = frozenset({".md", ".markdown", ".adoc", ".asciidoc", ".rst"})

_DEF_LINE_RE = re.compile(
    r"^\s*(?:export\s+)?(?:async\s+)?(?:function|class|interface|type|enum)\s+([A-Za-z_][\w$]*)"
)
_DEF_PY_RE = re.compile(r"^\s*(?:async\s+)?def\s+([A-Za-z_][\w]*)")
_CLASS_PY_RE = re.compile(r"^\s*class\s+([A-Za-z_][\w]*)")
_DEF_SH_RE = re.compile(r"^\s*(?:function\s+)?([A-Za-z_][\w]*)\s*\(\)\s*\{?")


def _symbol_from_line(text: str) -> str:
    for regex, prefix in (
        (_DEF_LINE_RE, ""),
        (_CLASS_PY_RE, "class "),
        (_DEF_PY_RE, "def "),
        (_DEF_SH_RE, "function "),
    ):
        match = regex.match(text)
        if match:
            name = match.group(1)
            return f"{prefix}{name}".strip()
    return ""


@dataclass(frozen=True)
class LineContext:
    relpath: str
    symbol: str = ""
    heading: str = ""

    def as_dict(self) -> dict[str, str]:
        payload = {"relpath": self.relpath}
        if self.symbol:
            payload["symbol"] = self.symbol
        if self.heading:
            payload["heading"] = self.heading
        return payload


def contextual_search_enabled(explicit: str | None = None, ralph_mode: str | None = None) -> bool:
    if explicit is not None:
        value = str(explicit).strip().lower()
        if value in {"1", "true", "yes", "on"}:
            return True
        if value in {"0", "false", "no", "off"}:
            return False

    # When callers provide an explicit ralph_mode, it must override any
    # contextual-search env var. This keeps the behavior deterministic for
    # unit tests and for explicit runtime mode selection.
    if ralph_mode is not None:
        mode = str(ralph_mode).strip().lower()
        return mode in {"ralph", "hybrid"}

    value = os.environ.get("RALPH_MCP_CONTEXTUAL_SEARCH")
    if value is not None and str(value).strip() != "":
        normalized = str(value).strip().lower()
        if normalized in {"1", "true", "yes", "on"}:
            return True
        if normalized in {"0", "false", "no", "off"}:
            return False

    mode = str(os.environ.get("RALPH_MODE", "no")).strip().lower()
    return mode in {"ralph", "hybrid"}


def _project_slug(project_root: Path) -> str:
    digest = hashlib.sha256(str(project_root.resolve()).encode("utf-8")).hexdigest()
    return digest[:16]


def _cache_path(
    state_root: Path,
    project_root: Path,
    relpath: str,
    mtime: int,
    backend: str,
) -> Path:
    slug = _project_slug(project_root)
    safe_name = relpath.replace("/", "__").replace("\\", "__")
    name = f"{safe_name}.{mtime}.{backend}.json"
    return state_root / "search-context" / slug / name


def _is_doc_file(relpath: str) -> bool:
    return Path(relpath).suffix.lower() in _DOC_SUFFIXES


def extract_symbol_locations(content: str) -> list[tuple[int, str]]:
    locations: list[tuple[int, str]] = []
    for idx, line in enumerate(content.splitlines(), start=1):
        symbol = _symbol_from_line(line)
        if symbol:
            locations.append((idx, symbol))
    return locations


def extract_heading_locations(content: str) -> list[tuple[int, str]]:
    headings: list[tuple[int, str]] = []
    for idx, line in enumerate(content.splitlines(), start=1):
        match = _HEADING_MD_RE.match(line) or _HEADING_ASCIIDOC_RE.match(line)
        if match:
            headings.append((idx, match.group(2).strip()))
    return headings


def nearest_at_or_before(entries: list[tuple[int, str]], line_no: int) -> str:
    best = ""
    best_line = 0
    for entry_line, label in entries:
        if entry_line <= line_no and entry_line >= best_line:
            best_line = entry_line
            best = label
    return best


def _read_file_entry(project_root: Path, relpath: str) -> tuple[int, str, str]:
    abs_path = (project_root / relpath).resolve()
    project_resolved = project_root.resolve()
    try:
        abs_path.relative_to(project_resolved)
    except ValueError:
        raise FileNotFoundError(relpath) from None
    if not abs_path.is_file():
        raise FileNotFoundError(relpath)
    content = abs_path.read_text(encoding="utf-8", errors="replace")
    stat = abs_path.stat()
    mtime = int(stat.st_mtime)
    return mtime, content, "regex"


def load_file_index(
    project_root: Path,
    state_root: Path,
    relpath: str,
    *,
    force_refresh: bool = False,
) -> dict[str, Any]:
    mtime, content, backend = _read_file_entry(project_root, relpath)
    cache_file = _cache_path(state_root, project_root, relpath, mtime, backend)
    if not force_refresh and cache_file.is_file():
        try:
            payload = json.loads(cache_file.read_text(encoding="utf-8"))
            if (
                payload.get("relpath") == relpath
                and int(payload.get("mtime", -1)) == mtime
                and payload.get("backend") == backend
            ):
                return payload
        except (OSError, ValueError, TypeError):
            pass

    symbols = [{"line": line, "label": label} for line, label in extract_symbol_locations(content)]
    headings: list[dict[str, Any]] = []
    if _is_doc_file(relpath):
        headings = [{"line": line, "text": text} for line, text in extract_heading_locations(content)]

    payload = {
        "schema_version": 1,
        "relpath": relpath,
        "mtime": mtime,
        "backend": backend,
        "symbols": symbols,
        "headings": headings,
    }
    cache_file.parent.mkdir(parents=True, exist_ok=True)
    cache_file.write_text(json.dumps(payload, sort_keys=True), encoding="utf-8")
    return payload


def resolve_line_context(
    project_root: Path,
    state_root: Path,
    relpath: str,
    line_no: int,
    *,
    file_index: dict[str, Any] | None = None,
) -> LineContext:
    norm = relpath.replace("\\", "/")
    index = file_index if file_index is not None else load_file_index(project_root, state_root, norm)
    symbol_entries = [(int(item["line"]), str(item["label"])) for item in index.get("symbols") or []]
    heading_entries = [(int(item["line"]), str(item["text"])) for item in index.get("headings") or []]
    symbol = nearest_at_or_before(symbol_entries, line_no)
    heading = nearest_at_or_before(heading_entries, line_no) if _is_doc_file(norm) else ""
    return LineContext(relpath=norm, symbol=symbol, heading=heading)


def build_context_map(
    project_root: Path,
    state_root: Path,
    candidates: list[tuple[str, int, str]],
) -> dict[tuple[str, int], LineContext]:
    contexts: dict[tuple[str, int], LineContext] = {}
    file_cache: dict[str, dict[str, Any]] = {}
    for relpath, line_no, _content in candidates:
        norm = relpath.replace("\\", "/")
        key = (norm, line_no)
        if key in contexts:
            continue
        if norm not in file_cache:
            try:
                file_cache[norm] = load_file_index(project_root, state_root, norm)
            except OSError:
                file_cache[norm] = {"symbols": [], "headings": []}
        contexts[key] = resolve_line_context(
            project_root,
            state_root,
            norm,
            line_no,
            file_index=file_cache[norm],
        )
    return contexts
