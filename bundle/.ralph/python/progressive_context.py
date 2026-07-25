#!/usr/bin/env python3
"""Progressive disclosure for Ralph agent rules and skills (stdlib only)."""

from __future__ import annotations

import argparse
import importlib.util
import json
import os
import re
import sys
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

from context_metadata import RuleSkillMetadata, parse_rule_or_skill_file

DEFAULT_THRESHOLD = 1.5
DEFAULT_MAX_ITEMS = 8
MAX_RULE_INLINE_BYTES = 65536

_MENTION_PATH_RE = re.compile(r"`([^`]+)`")


def _load_search_rank_module():
    script_dir = Path(__file__).resolve().parent
    module_path = script_dir / "mcp-proxy-search-rank.py"
    spec = importlib.util.spec_from_file_location("mcp_proxy_search_rank", module_path)
    if spec is None or spec.loader is None:
        raise ImportError(f"unable to load {module_path}")
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


def _env_bool(name: str) -> str | None:
    raw = os.environ.get(name)
    if raw is None:
        return None
    stripped = raw.strip()
    return stripped if stripped else None


def progressive_context_enabled(*, explicit: str | None = None, ralph_mode: str | None = None) -> bool:
    value = explicit if explicit is not None else _env_bool("RALPH_PROGRESSIVE_CONTEXT")
    if value is not None:
        normalized = value.lower()
        if normalized in {"1", "true", "yes", "on"}:
            return True
        if normalized in {"0", "false", "no", "off"}:
            return False
        raise ValueError(
            f"RALPH_PROGRESSIVE_CONTEXT: invalid value '{value}' (use 0 or 1)"
        )
    mode = (ralph_mode if ralph_mode is not None else os.environ.get("RALPH_MODE", "no")).lower()
    return mode in {"ralph", "hybrid"}


def _env_float(name: str, default: float) -> float:
    raw = os.environ.get(name, "").strip()
    if not raw:
        return default
    try:
        return float(raw)
    except ValueError:
        return default


def _env_positive_int(name: str, default: int) -> int:
    raw = os.environ.get(name, "").strip()
    if not raw:
        return default
    try:
        value = int(raw)
    except ValueError:
        return default
    return value if value > 0 else default


def _resolve_workspace_path(workspace: Path, rel: str, agents_root: Path | None) -> Path:
    rel_clean = rel.lstrip("/")
    candidate = workspace / rel_clean
    if candidate.is_file():
        return candidate
    if agents_root is not None:
        runtime_root = agents_root.parent
        runtime_dir = runtime_root.name
        rel_without_runtime = rel_clean
        if rel_clean.startswith(f"{runtime_dir}/"):
            rel_without_runtime = rel_clean[len(runtime_dir) + 1 :]
        alt = runtime_root / rel_without_runtime
        if alt.is_file():
            return alt
    return candidate


def _load_config_paths(config_path: Path) -> tuple[list[str], list[str], str, str]:
    data = json.loads(config_path.read_text(encoding="utf-8"))
    rules = [str(item) for item in data.get("rules", []) if isinstance(item, str)]
    skills = [str(item) for item in data.get("skills", []) if isinstance(item, str)]
    name = str(data.get("name", "")).strip()
    description = str(data.get("description", "")).strip()
    return rules, skills, name, description


def _collect_items(
    workspace: Path,
    agents_root: Path,
    rule_paths: list[str],
    skill_paths: list[str],
) -> list[RuleSkillMetadata]:
    items: list[RuleSkillMetadata] = []
    for rel in rule_paths:
        path = _resolve_workspace_path(workspace, rel, agents_root)
        items.append(parse_rule_or_skill_file(path, kind="rule", rel_path=rel))
    for rel in skill_paths:
        path = _resolve_workspace_path(workspace, rel, agents_root)
        items.append(parse_rule_or_skill_file(path, kind="skill", rel_path=rel))
    return items


def _mention_tokens(item: RuleSkillMetadata) -> set[str]:
    tokens = {
        item.path.lower(),
        Path(item.path).name.lower(),
        Path(item.path).stem.lower(),
    }
    if item.name:
        tokens.add(item.name.lower())
    return {token for token in tokens if token}


def explicitly_mentioned(item: RuleSkillMetadata, query_text: str) -> bool:
    if not query_text.strip():
        return False
    query_lower = query_text.lower()
    for token in _mention_tokens(item):
        if token in query_lower:
            return True
        pattern = r"(?<![\w./-])" + re.escape(token) + r"(?![\w./-])"
        if re.search(pattern, query_lower):
            return True
    for match in _MENTION_PATH_RE.finditer(query_text):
        mentioned = match.group(1).strip().lower()
        if mentioned and (
            mentioned == item.path.lower()
            or mentioned.endswith("/" + Path(item.path).name.lower())
            or mentioned == item.name.lower()
        ):
            return True
    return False


def build_query_text(
    *,
    todo_text: str = "",
    stage_description: str = "",
    agent_name: str = "",
    agent_description: str = "",
    explicit_files: list[str] | None = None,
) -> str:
    parts = [
        todo_text.strip(),
        stage_description.strip(),
        agent_name.strip(),
        agent_description.strip(),
    ]
    if explicit_files:
        parts.extend(path.strip() for path in explicit_files if path.strip())
    return "\n".join(part for part in parts if part)


def rank_optional_items(
    items: list[RuleSkillMetadata],
    query_text: str,
) -> list[tuple[RuleSkillMetadata, float]]:
    search_rank = _load_search_rank_module()
    terms = search_rank.normalize_terms(query_text)
    if not terms:
        return [(item, 0.0) for item in items]

    corpus: list[tuple[RuleSkillMetadata, str]] = []
    for item in items:
        doc = " ".join(
            part
            for part in (
                item.name,
                item.description,
                item.path,
                Path(item.path).name,
                " ".join(item.globs),
            )
            if part
        )
        corpus.append((item, doc))

    term_doc_freq: dict[str, int] = {}
    for term in terms:
        term_lower = term.lower()
        count = 0
        for _, doc in corpus:
            if term_lower in doc.lower():
                count += 1
        term_doc_freq[term_lower] = count

    num_docs = len(corpus) or 1
    term_idf = {
        term.lower(): search_rank.compute_idf(term_doc_freq.get(term.lower(), 0), num_docs)
        for term in terms
    }
    doc_lengths = [len(search_rank.tokenize(doc)) or 1 for _, doc in corpus]
    avg_dl = sum(doc_lengths) / len(doc_lengths) if doc_lengths else 1.0

    scored: list[tuple[RuleSkillMetadata, float]] = []
    for (item, doc), _dl in zip(corpus, doc_lengths, strict=False):
        score = search_rank.score_candidate(
            item.path,
            doc,
            terms,
            term_idf,
            avg_dl,
            context=None,
        )
        scored.append((item, score))

    scored.sort(key=lambda pair: (-pair[1], pair[0].path))
    return scored


@dataclass
class SelectionResult:
    stable_full: list[RuleSkillMetadata] = field(default_factory=list)
    volatile_full: list[RuleSkillMetadata] = field(default_factory=list)
    tier1_optional: list[RuleSkillMetadata] = field(default_factory=list)
    warnings: list[str] = field(default_factory=list)
    progressive: bool = False


def select_items(
    items: list[RuleSkillMetadata],
    *,
    query_text: str,
    threshold: float,
    max_items: int,
) -> SelectionResult:
    result = SelectionResult(progressive=True)
    optional: list[RuleSkillMetadata] = []

    for item in items:
        result.warnings.extend(item.warnings)
        if not item.metadata_complete:
            result.stable_full.append(item)
            continue
        if item.kind == "rule" and item.always_apply is True:
            result.stable_full.append(item)
            continue
        optional.append(item)

    ranked = rank_optional_items(optional, query_text)
    selected_volatile: list[RuleSkillMetadata] = []
    selected_paths: set[str] = set()

    for item in optional:
        if explicitly_mentioned(item, query_text):
            selected_volatile.append(item)
            selected_paths.add(item.path)

    for item, score in ranked:
        if item.path in selected_paths:
            continue
        if score >= threshold and len(selected_volatile) < max_items:
            selected_volatile.append(item)
            selected_paths.add(item.path)

    selected_volatile.sort(key=lambda entry: entry.path)
    result.volatile_full = selected_volatile
    result.tier1_optional = [item for item in optional if item.path not in selected_paths]
    return result


def _truncate_body(body: str) -> str:
    encoded = body.encode("utf-8")
    if len(encoded) <= MAX_RULE_INLINE_BYTES:
        return body
    truncated = encoded[:MAX_RULE_INLINE_BYTES].decode("utf-8", errors="ignore")
    return truncated + f"\n[Truncated after {MAX_RULE_INLINE_BYTES} bytes]"


def _render_full_item(item: RuleSkillMetadata) -> str:
    label = "Rule file" if item.kind == "rule" else "Skill file"
    body = item.body_without_frontmatter or item.body
    return f"--- {label}: `{item.path}` ---\n{_truncate_body(body)}\n"


def render_legacy_context(
    *,
    agent_name: str,
    agent_description: str,
    items: list[RuleSkillMetadata],
    compact_mode: bool,
) -> str:
    lines = [
        "",
        "**Prebuilt agent profile**",
        f"- **name:** {agent_name}",
        f"- **role:** {agent_description}",
        "",
    ]
    rules = [item for item in items if item.kind == "rule"]
    skills = [item for item in items if item.kind == "skill"]

    if compact_mode:
        lines.append("**Rules (read and follow; paths only):**")
    else:
        lines.append("**Rules (read and follow; full text inlined below):**")
    for item in rules:
        lines.append(f"  - `{item.path}`")
    lines.append("")
    if not compact_mode:
        for item in rules:
            lines.extend(_render_full_item(item).splitlines())
            lines.append("")

    lines.append("**Skill paths (read these files in the repo as needed):**")
    if skills:
        for item in skills:
            lines.append(f"  - `{item.path}`")
    else:
        lines.append("  - (none configured)")
    lines.append("")
    return "\n".join(lines)


def render_progressive_context(
    *,
    agent_name: str,
    agent_description: str,
    config_path: str,
    selection: SelectionResult,
) -> tuple[str, str]:
    stable_lines = [
        "",
        "**Prebuilt agent profile**",
        f"- **name:** {agent_name}",
        f"- **role:** {agent_description}",
        "",
        "**Rules and skills (Tier 1 metadata; full bodies load when selected as relevant):**",
    ]
    for item in selection.tier1_optional:
        stable_lines.append(item.tier1_text)
    if not selection.tier1_optional:
        stable_lines.append("  - (all configured rules/skills loaded in full below or per TODO)")
    stable_lines.append("")

    for item in selection.stable_full:
        stable_lines.extend(_render_full_item(item).splitlines())
        stable_lines.append("")

    stable_lines.append(f"**Agent config:** `{config_path}` (validated).")
    stable_lines.append("")

    volatile_lines: list[str] = []
    if selection.volatile_full:
        volatile_lines.append("**Selected rules and skills (full bodies for this TODO):**")
        volatile_lines.append("")
        for item in selection.volatile_full:
            volatile_lines.extend(_render_full_item(item).splitlines())
            volatile_lines.append("")

    return "\n".join(stable_lines), "\n".join(volatile_lines).strip()


def assemble_context(payload: dict[str, Any]) -> dict[str, Any]:
    workspace = Path(payload["workspace"]).resolve()
    config_path = Path(payload["config_path"]).resolve()
    agents_root = Path(payload["agents_root"]).resolve()
    agent_name = str(payload.get("agent_name", "")).strip()
    agent_description = str(payload.get("agent_description", "")).strip()
    todo_text = str(payload.get("todo_text", "")).strip()
    stage_description = str(payload.get("stage_description", "")).strip()
    explicit_files = payload.get("explicit_files") or []
    compact_mode = str(payload.get("compact_mode", "0")).strip() == "1"
    part = str(payload.get("part", "all")).strip().lower()

    rule_paths, skill_paths, cfg_name, cfg_desc = _load_config_paths(config_path)
    if not agent_name:
        agent_name = cfg_name
    if not agent_description:
        agent_description = cfg_desc

    items = _collect_items(workspace, agents_root, rule_paths, skill_paths)
    warnings: list[str] = []
    for item in items:
        warnings.extend(item.warnings)

    enabled = progressive_context_enabled(
        explicit=payload.get("progressive_context"),
        ralph_mode=payload.get("ralph_mode"),
    )

    if not enabled:
        legacy = render_legacy_context(
            agent_name=agent_name,
            agent_description=agent_description,
            items=items,
            compact_mode=compact_mode,
        )
        return {
            "stable": legacy,
            "volatile": "",
            "progressive": False,
            "warnings": warnings,
        }

    query_text = build_query_text(
        todo_text=todo_text,
        stage_description=stage_description,
        agent_name=agent_name,
        agent_description=agent_description,
        explicit_files=[str(path) for path in explicit_files],
    )
    threshold = _env_float("RALPH_PROGRESSIVE_CONTEXT_THRESHOLD", DEFAULT_THRESHOLD)
    max_items = _env_positive_int("RALPH_PROGRESSIVE_CONTEXT_MAX_ITEMS", DEFAULT_MAX_ITEMS)
    selection = select_items(items, query_text=query_text, threshold=threshold, max_items=max_items)
    selection.warnings.extend(warnings)

    stable, volatile = render_progressive_context(
        agent_name=agent_name,
        agent_description=agent_description,
        config_path=str(config_path),
        selection=selection,
    )

    if part == "stable":
        return {"stable": stable, "volatile": "", "progressive": True, "warnings": selection.warnings}
    if part == "volatile":
        return {"stable": "", "volatile": volatile, "progressive": True, "warnings": selection.warnings}

    return {
        "stable": stable,
        "volatile": volatile,
        "progressive": True,
        "warnings": selection.warnings,
    }


def _cmd_assemble(args: argparse.Namespace) -> None:
    payload = {
        "workspace": args.workspace,
        "config_path": args.config_path,
        "agents_root": args.agents_root,
        "agent_name": args.agent_name or "",
        "agent_description": args.agent_description or "",
        "todo_text": args.todo_text or "",
        "stage_description": args.stage_description or "",
        "compact_mode": args.compact_mode or "0",
        "part": args.part or "all",
        "progressive_context": args.progressive_context,
        "ralph_mode": args.ralph_mode,
    }
    result = assemble_context(payload)
    for warning in result.get("warnings", []):
        print(f"Warning: {warning}", file=sys.stderr)
    print(json.dumps(result, ensure_ascii=False))


def main(argv: list[str] | None = None) -> None:
    parser = argparse.ArgumentParser(description="Progressive rule/skill context assembler")
    sub = parser.add_subparsers(dest="command", required=True)

    assemble = sub.add_parser("assemble", help="Build stable/volatile context blocks")
    assemble.add_argument("--workspace", required=True)
    assemble.add_argument("--config-path", required=True)
    assemble.add_argument("--agents-root", required=True)
    assemble.add_argument("--agent-name", default="")
    assemble.add_argument("--agent-description", default="")
    assemble.add_argument("--todo-text", default="")
    assemble.add_argument("--stage-description", default="")
    assemble.add_argument("--compact-mode", default="0")
    assemble.add_argument("--part", choices=("all", "stable", "volatile"), default="all")
    assemble.add_argument("--progressive-context", default=None)
    assemble.add_argument("--ralph-mode", default=None)
    assemble.set_defaults(func=_cmd_assemble)

    args = parser.parse_args(argv)
    args.func(args)


if __name__ == "__main__":
    main()
