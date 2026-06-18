#!/usr/bin/env python3
"""Aider-style repo-map digest helpers (stdlib only)."""

from __future__ import annotations

import json
import re
import sys
from collections import defaultdict
from typing import Dict, Iterable, List, Tuple

_SYMBOL_KINDS = {
    "c": "class",
    "C": "class",
    "d": "macro",
    "e": "enum",
    "f": "function",
    "F": "field",
    "g": "enum",
    "i": "interface",
    "l": "local",
    "m": "member",
    "M": "method",
    "n": "namespace",
    "p": "property",
    "s": "struct",
    "t": "typedef",
    "T": "type",
    "u": "union",
    "v": "variable",
    "x": "extern",
    "z": "parameter",
}

_DEF_LINE_RE = re.compile(
    r"^\s*(?:export\s+)?(?:async\s+)?(?:function|class|interface|type|enum)\s+([A-Za-z_][\w$]*)"
)
_DEF_PY_RE = re.compile(r"^\s*(?:async\s+)?def\s+([A-Za-z_][\w]*)")
_CLASS_PY_RE = re.compile(r"^\s*class\s+([A-Za-z_][\w]*)")
_DEF_SH_RE = re.compile(r"^\s*(?:function\s+)?([A-Za-z_][\w]*)\s*\(\)\s*\{?")


def _kind_label(kind: str) -> str:
    if not kind:
        return "symbol"
    primary = kind[0]
    return _SYMBOL_KINDS.get(primary, "symbol")


def parse_ctags_json(raw: str) -> Dict[str, List[str]]:
    by_file: Dict[str, List[str]] = defaultdict(list)
    for line in raw.splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            entry = json.loads(line)
        except json.JSONDecodeError:
            continue
        path = entry.get("path") or entry.get("file")
        name = entry.get("name")
        if not path or not name:
            continue
        kind = _kind_label(str(entry.get("kind", "")))
        label = f"{kind} {name}"
        if label not in by_file[path]:
            by_file[path].append(label)
    return dict(by_file)


def parse_rg_lines(raw: str) -> Dict[str, List[str]]:
    by_file: Dict[str, List[str]] = defaultdict(list)
    for line in raw.splitlines():
        if not line.strip():
            continue
        parts = line.split(":", 2)
        if len(parts) < 3:
            continue
        path, _lineno, text = parts[0], parts[1], parts[2]
        symbol = _symbol_from_line(text)
        if symbol and symbol not in by_file[path]:
            by_file[path].append(symbol)
    return dict(by_file)


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


def extract_regex_files(files: Iterable[Tuple[str, str]]) -> Dict[str, List[str]]:
    by_file: Dict[str, List[str]] = {}
    for relpath, content in files:
        symbols: List[str] = []
        for line in content.splitlines():
            symbol = _symbol_from_line(line)
            if symbol and symbol not in symbols:
                symbols.append(symbol)
        if symbols:
            by_file[relpath] = symbols
    return by_file


def format_digest(by_file: Dict[str, List[str]]) -> str:
    lines: List[str] = []
    for path in sorted(by_file.keys()):
        lines.append(f"{path}:")
        for symbol in by_file[path]:
            lines.append(f"  {symbol}")
    return "\n".join(lines) + ("\n" if lines else "")


def main() -> int:
    mode = sys.argv[1] if len(sys.argv) > 1 else ""
    if mode == "ctags":
        raw = sys.stdin.read()
        print(format_digest(parse_ctags_json(raw)), end="")
        return 0
    if mode == "rg":
        raw = sys.stdin.read()
        print(format_digest(parse_rg_lines(raw)), end="")
        return 0
    if mode == "regex":
        files: List[Tuple[str, str]] = []
        payload = sys.stdin.read()
        current_path = ""
        current_lines: List[str] = []
        for line in payload.splitlines():
            if line.startswith("@@FILE@@"):
                if current_path:
                    files.append((current_path, "\n".join(current_lines)))
                current_path = line[len("@@FILE@@") :]
                current_lines = []
                continue
            current_lines.append(line)
        if current_path:
            files.append((current_path, "\n".join(current_lines)))
        print(format_digest(extract_regex_files(files)), end="")
        return 0
    print("usage: repo_map.py {ctags|rg|regex}", file=sys.stderr)
    return 2


if __name__ == "__main__":
    raise SystemExit(main())
