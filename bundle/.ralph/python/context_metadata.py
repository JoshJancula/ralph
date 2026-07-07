#!/usr/bin/env python3
"""Shared frontmatter metadata parser for Ralph rules and SKILL.md files (stdlib only)."""

from __future__ import annotations

import re
from dataclasses import dataclass, field
from pathlib import Path

_BOOL_TRUE = frozenset({"true", "yes", "1", "on"})
_BOOL_FALSE = frozenset({"false", "no", "0", "off"})


def _unquote(value: str) -> str:
    value = value.strip()
    if len(value) >= 2 and value[0] == '"' and value[-1] == '"':
        value = value[1:-1]
        value = value.replace('\\"', '"').replace("\\\\", "\\")
    elif len(value) >= 2 and value[0] == "'" and value[-1] == "'":
        value = value[1:-1]
    return value


def _parse_inline_array(value: str) -> list[str]:
    value = value.strip()
    if not (value.startswith("[") and value.endswith("]")):
        raise ValueError(f"invalid inline array: {value}")
    inner = value[1:-1]
    if not inner.strip():
        return []
    items: list[str] = []
    current: list[str] = []
    in_quote: str | None = None
    for ch in inner:
        if ch in ('"', "'"):
            if in_quote is None:
                in_quote = ch
            elif in_quote == ch:
                in_quote = None
            current.append(ch)
        elif ch == "," and in_quote is None:
            items.append(_unquote("".join(current)))
            current = []
        else:
            current.append(ch)
    if current or inner.strip().endswith(","):
        items.append(_unquote("".join(current)))
    return items


def _parse_key_value(content: str) -> tuple[str, str | None] | None:
    content = content.rstrip()
    match = re.match(r"^([A-Za-z0-9_\-]+):\s*(.*)$", content)
    if not match:
        return None
    key = match.group(1)
    value = match.group(2).strip()
    if not value:
        return key, None
    return key, _unquote(value)


def extract_frontmatter(text: str) -> list[str]:
    lines = text.splitlines()
    if not lines or lines[0].strip() != "---":
        return []
    end = None
    for idx in range(1, len(lines)):
        if lines[idx].strip() == "---":
            end = idx
            break
    if end is None:
        return []
    return lines[1:end]


def _collect_block_sequence(fm_lines: list[str], start: int) -> tuple[list[str], int]:
    """Collect an indented `- item` block sequence starting after index `start`.

    Returns the parsed items and the index of the first line that is not part of
    the sequence. Used for block-style `globs:`/`paths:` lists emitted by the
    native Claude/Antigravity rule renderers.
    """
    items: list[str] = []
    idx = start
    n = len(fm_lines)
    while idx < n:
        raw = fm_lines[idx]
        stripped = raw.strip()
        if not stripped or stripped.startswith("#"):
            idx += 1
            continue
        # Sequence items are indented and start with a dash.
        if (len(raw) - len(raw.lstrip())) > 0 and stripped.startswith("-"):
            item = stripped[1:].strip()
            if item:
                items.append(_unquote(item))
            idx += 1
            continue
        break
    return items, idx


def parse_frontmatter_dict(fm_lines: list[str]) -> dict[str, object]:
    data: dict[str, object] = {}
    idx = 0
    n = len(fm_lines)
    while idx < n:
        line = fm_lines[idx]
        stripped = line.strip()
        if not stripped or stripped.startswith("#"):
            idx += 1
            continue
        kv = _parse_key_value(stripped)
        if not kv:
            idx += 1
            continue
        key, value = kv
        if value is None:
            # A bare `key:` may introduce a block-style sequence on the
            # following indented `- item` lines (globs/paths).
            items, next_idx = _collect_block_sequence(fm_lines, idx + 1)
            if items:
                data[key] = items
                idx = next_idx
                continue
            idx += 1
            continue
        if key in ("globs", "paths") and isinstance(value, str) and value.startswith("["):
            try:
                data[key] = _parse_inline_array(value)
            except ValueError:
                data[key] = value
        elif key == "alwaysApply" and isinstance(value, str):
            lowered = value.strip().lower()
            if lowered in _BOOL_TRUE:
                data[key] = True
            elif lowered in _BOOL_FALSE:
                data[key] = False
            else:
                data[key] = value
        else:
            data[key] = value
        idx += 1
    return data


def body_without_frontmatter(text: str) -> str:
    lines = text.splitlines()
    if not lines or lines[0].strip() != "---":
        return text
    for idx in range(1, len(lines)):
        if lines[idx].strip() == "---":
            remainder = lines[idx + 1 :]
            while remainder and not remainder[0].strip():
                remainder = remainder[1:]
            return "\n".join(remainder)
    return text


def parse_bool(value: object) -> bool | None:
    if isinstance(value, bool):
        return value
    if isinstance(value, str):
        lowered = value.strip().lower()
        if lowered in _BOOL_TRUE:
            return True
        if lowered in _BOOL_FALSE:
            return False
    return None


@dataclass
class RuleSkillMetadata:
    kind: str
    path: str
    name: str
    description: str
    globs: list[str] = field(default_factory=list)
    always_apply: bool | None = None
    body: str = ""
    body_without_frontmatter: str = ""
    metadata_complete: bool = True
    warnings: list[str] = field(default_factory=list)

    @property
    def tier1_text(self) -> str:
        lines = [
            f"- **{self.kind}:** `{self.path}`",
            f"  - name: {self.name or '(missing)'}",
            f"  - description: {self.description or '(missing)'}",
        ]
        if self.kind == "rule" and self.globs:
            globs_text = ", ".join(f"`{g}`" for g in self.globs)
            lines.append(f"  - globs: {globs_text}")
        if self.kind == "rule" and self.always_apply is not None:
            lines.append(f"  - alwaysApply: {str(self.always_apply).lower()}")
        return "\n".join(lines)


def _derive_name(path: str, fm: dict[str, object]) -> str:
    raw = fm.get("name")
    if isinstance(raw, str) and raw.strip():
        return raw.strip()
    stem = Path(path).stem
    if stem.upper() == "SKILL":
        return Path(path).parent.name
    return stem


def _derive_description(path: str, fm: dict[str, object]) -> str:
    raw = fm.get("description")
    if isinstance(raw, str) and raw.strip():
        return raw.strip()
    return ""


def _derive_globs(fm: dict[str, object]) -> list[str]:
    # Native Claude rules scope with `paths`; treat it as a glob source when
    # `globs` is absent (Cursor/Antigravity keep using `globs`).
    raw = fm.get("globs")
    if raw is None:
        raw = fm.get("paths")
    if isinstance(raw, list):
        return [str(item).strip() for item in raw if str(item).strip()]
    if isinstance(raw, str) and raw.strip():
        if raw.strip().startswith("["):
            try:
                return _parse_inline_array(raw.strip())
            except ValueError:
                return [raw.strip()]
        return [raw.strip()]
    return []


def _derive_always_apply(fm: dict[str, object]) -> bool | None:
    """Resolve always-apply across the three native rule schemas.

    Precedence: explicit Cursor `alwaysApply` > Antigravity `trigger` >
    Claude `paths` presence > default. A rule with no scoping information
    defaults to always-apply (load the full body), which is the safe default.
    """
    if "alwaysApply" in fm:
        return parse_bool(fm.get("alwaysApply"))
    trigger = fm.get("trigger")
    if isinstance(trigger, str) and trigger.strip():
        # `always_on` loads unconditionally; `glob`/`model_decision` are scoped.
        return trigger.strip().lower() == "always_on"
    if "paths" in fm:
        # Claude: presence of `paths` means the rule is path-scoped.
        return False
    return True


def parse_rule_or_skill_file(path: Path, *, kind: str, rel_path: str) -> RuleSkillMetadata:
    warnings: list[str] = []
    try:
        text = path.read_text(encoding="utf-8", errors="replace")
    except OSError as exc:
        return RuleSkillMetadata(
            kind=kind,
            path=rel_path,
            name=Path(rel_path).stem,
            description="",
            metadata_complete=False,
            warnings=[f"could not read {rel_path}: {exc}"],
        )

    fm_lines = extract_frontmatter(text)
    body = body_without_frontmatter(text)
    if not fm_lines:
        warnings.append(f"missing or malformed frontmatter in {rel_path}; loading full body")
        return RuleSkillMetadata(
            kind=kind,
            path=rel_path,
            name=_derive_name(rel_path, {}),
            description="",
            body=text,
            body_without_frontmatter=body or text,
            metadata_complete=False,
            warnings=warnings,
        )

    fm = parse_frontmatter_dict(fm_lines)
    name = _derive_name(rel_path, fm)
    description = _derive_description(rel_path, fm)
    always_apply = _derive_always_apply(fm) if kind == "rule" else None
    globs = _derive_globs(fm) if kind == "rule" else []

    metadata_complete = True
    if not description:
        metadata_complete = False
        warnings.append(f"missing description in {rel_path}; loading full body")
    if kind == "rule" and always_apply is None:
        metadata_complete = False
        warnings.append(f"invalid alwaysApply in {rel_path}; loading full body")
    if kind == "skill" and not name:
        metadata_complete = False
        warnings.append(f"missing name in {rel_path}; loading full body")

    return RuleSkillMetadata(
        kind=kind,
        path=rel_path,
        name=name,
        description=description,
        globs=globs,
        always_apply=always_apply,
        body=text,
        body_without_frontmatter=body,
        metadata_complete=metadata_complete,
        warnings=warnings,
    )
