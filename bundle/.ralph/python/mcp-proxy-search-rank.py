#!/usr/bin/env python3
"""BM25/IDF lexical ranker for ralph_proxy_search (stdlib only, no index)."""
from __future__ import annotations

import argparse
import importlib.util
import math
import os
import re
import sys
from pathlib import Path
from typing import TYPE_CHECKING

if TYPE_CHECKING:
    from search_context import LineContext

K1 = 1.2
B = 0.75

# Context field boosts (applied separately from content; do not mutate returned lines).
WEIGHT_CONTEXT_PATH = 1.5
WEIGHT_CONTEXT_SYMBOL = 4.0
WEIGHT_CONTEXT_HEADING = 3.0

COMMON_TOKENS = frozenset(
    {
        "a", "an", "the", "and", "or", "not", "if", "else", "for", "while", "do",
        "in", "of", "to", "from", "with", "as", "at", "by", "on", "is", "it",
        "function", "func", "def", "class", "const", "let", "var", "return",
        "import", "export", "true", "false", "null", "none", "self",
        "public", "private", "static", "void", "int", "str", "bool",
    }
)

DEF_PATTERNS = [
    re.compile(r"\b(function|def|class|struct|interface|type|enum|fn|func)\b"),
    re.compile(r"\b(const|let|var|export)\s+\w+"),
    re.compile(r"^\s*(def|class|function)\s+\w+"),
]

IDENT_RE = re.compile(r"[A-Za-z_][\w]*")


def _load_search_context_module():
    script_dir = Path(__file__).resolve().parent
    module_path = script_dir / "search_context.py"
    spec = importlib.util.spec_from_file_location("search_context", module_path)
    if spec is None or spec.loader is None:
        raise ImportError(f"unable to load {module_path}")
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


def normalize_terms(query: str) -> list[str]:
    terms: list[str] = []
    seen: set[str] = set()
    for raw in query.split():
        term = raw.strip("`'\".,;:!?()[]{}").strip()
        if not term:
            continue
        key = term.lower()
        if key in seen:
            continue
        seen.add(key)
        terms.append(term)
    return terms


def tokenize(text: str) -> list[str]:
    return [t.lower() for t in IDENT_RE.findall(text)]


def parse_candidate(line: str) -> tuple[str, int, str] | None:
    parts = line.split(":", 2)
    if len(parts) < 3:
        return None
    filepath, lineno, content = parts[0], parts[1], parts[2]
    try:
        line_no = int(lineno)
    except ValueError:
        return None
    return filepath, line_no, content


def compute_idf(doc_freq: int, num_docs: int) -> float:
    return math.log((num_docs - doc_freq + 0.5) / (doc_freq + 0.5) + 1.0)


def term_frequency(term_lower: str, content_lower: str, tokens: list[str]) -> int:
    tf = sum(1 for t in tokens if t == term_lower)
    if tf > 0:
        return tf
    if term_lower in content_lower:
        return content_lower.count(term_lower) or 1
    return 0


def _term_match_boost(term: str, text: str, idf: float, *, exact_mult: float, case_mult: float) -> float:
    boost = 0.0
    ident_pat = r"(?<![\w])" + re.escape(term) + r"(?![\w])"
    if re.search(ident_pat, text, re.IGNORECASE):
        boost += idf * exact_mult
    if re.search(ident_pat, text):
        boost += idf * case_mult
    return boost


def score_context_fields(
    filepath: str,
    context: LineContext | None,
    terms: list[str],
    term_idf: dict[str, float],
) -> float:
    score = 0.0
    path_lower = filepath.lower()
    basename = filepath.rsplit("/", 1)[-1].lower()
    fields: list[tuple[str, float]] = [(path_lower, WEIGHT_CONTEXT_PATH), (basename, WEIGHT_CONTEXT_PATH)]
    if context is not None:
        if context.symbol:
            fields.append((context.symbol.lower(), WEIGHT_CONTEXT_SYMBOL))
        if context.heading:
            fields.append((context.heading.lower(), WEIGHT_CONTEXT_HEADING))

    for field_text, weight in fields:
        if not field_text:
            continue
        for term in terms:
            term_lower = term.lower()
            idf = term_idf.get(term_lower, 0.0)
            if term_lower in field_text:
                score += idf * weight
            score += _term_match_boost(term, field_text, idf, exact_mult=weight, case_mult=weight * 0.5)
    return score


def score_candidate(
    filepath: str,
    content: str,
    terms: list[str],
    term_idf: dict[str, float],
    avg_dl: float,
    context: LineContext | None = None,
) -> float:
    content_lower = content.lower()
    tokens = tokenize(content)
    dl = len(tokens) or 1
    basename = filepath.rsplit("/", 1)[-1]
    score = 0.0

    for term in terms:
        term_lower = term.lower()
        tf = term_frequency(term_lower, content_lower, tokens)
        idf = term_idf.get(term_lower, 0.0)
        if term_lower in COMMON_TOKENS:
            idf *= 0.25

        if tf > 0:
            bm25 = idf * (tf * (K1 + 1)) / (tf + K1 * (1 - B + B * dl / avg_dl))
            score += bm25

        score += _term_match_boost(term, content, idf, exact_mult=2.0, case_mult=3.0)

        if term_lower in basename.lower():
            score += idf * 2.5
        if term_lower in filepath.lower():
            score += idf * 1.5

    for pat in DEF_PATTERNS:
        if pat.search(content):
            for term in terms:
                ident_pat = r"(?<![\w])" + re.escape(term) + r"(?![\w])"
                if re.search(ident_pat, content, re.IGNORECASE):
                    score += term_idf.get(term.lower(), 0.0) * 2.0
            break

    if len(terms) >= 2:
        positions: list[int] = []
        for term in terms:
            match = re.search(re.escape(term), content, re.IGNORECASE)
            if match:
                positions.append(match.start())
        if len(positions) >= 2:
            span = max(positions) - min(positions)
            if span <= 40:
                score += 5.0
            elif span <= 80:
                score += 2.0

    score += score_context_fields(filepath, context, terms, term_idf)
    return score


def resolve_state_root(project_root: Path, explicit: str | None) -> Path:
    if explicit:
        return Path(explicit).resolve()
    env_root = os.environ.get("RALPH_PLAN_WORKSPACE_ROOT")
    if env_root:
        return Path(env_root).resolve()
    return (project_root / ".ralph-workspace").resolve()


def contextual_enabled_flag(explicit: str | None) -> bool:
    if explicit is not None:
        return explicit.lower() in {"1", "true", "yes", "on"}
    try:
        search_context = _load_search_context_module()
    except ImportError:
        return False
    return search_context.contextual_search_enabled()


def rank_candidates(
    query: str,
    candidates: list[tuple[tuple[str, int, str], str]],
    max_results: int,
    *,
    project_root: Path | None = None,
    state_root: Path | None = None,
    contextual: bool = False,
) -> list[str]:
    terms = normalize_terms(query)
    if not terms or not candidates:
        return []

    num_docs = len(candidates)
    term_doc_freq: dict[str, int] = {}
    total_dl = 0

    for (filepath, _line_no, content), _raw in candidates:
        tokens = tokenize(content)
        total_dl += len(tokens) or 1
        seen_terms: set[str] = set(tokens)
        content_lower = content.lower()
        for term in terms:
            tl = term.lower()
            if tl in content_lower:
                seen_terms.add(tl)
        if filepath:
            path_lower = filepath.lower()
            for term in terms:
                tl = term.lower()
                if tl in path_lower:
                    seen_terms.add(tl)
        for token in seen_terms:
            term_doc_freq[token] = term_doc_freq.get(token, 0) + 1

    avg_dl = total_dl / num_docs if num_docs else 1.0

    term_idf: dict[str, float] = {}
    for term in terms:
        tl = term.lower()
        term_idf[tl] = compute_idf(term_doc_freq.get(tl, 0), num_docs)

    context_map: dict[tuple[str, int], LineContext] = {}
    if contextual and project_root is not None and state_root is not None:
        try:
            search_context = _load_search_context_module()
            parsed = [item[0] for item in candidates]
            context_map = search_context.build_context_map(project_root, state_root, parsed)
        except (ImportError, OSError):
            context_map = {}

    scored: list[tuple[float, str, str, int]] = []
    for (filepath, line_no, content), raw_line in candidates:
        ctx = context_map.get((filepath.replace("\\", "/"), line_no))
        s = score_candidate(filepath, content, terms, term_idf, avg_dl, context=ctx)
        scored.append((s, raw_line, filepath, line_no))

    scored.sort(key=lambda item: (-item[0], item[2], item[3], item[1]))
    return [raw_line for _score, raw_line, _filepath, _line_no in scored[:max_results]]


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--query", required=True)
    parser.add_argument("--max-results", type=int, default=50)
    parser.add_argument("--project-root", default="")
    parser.add_argument("--state-root", default="")
    parser.add_argument("--contextual", choices=("0", "1", "auto"), default="auto")
    args = parser.parse_args()

    terms = normalize_terms(args.query)
    if not terms:
        return 0

    candidates: list[tuple[tuple[str, int, str], str]] = []
    for raw_line in sys.stdin:
        raw_line = raw_line.rstrip("\n")
        if not raw_line:
            continue
        parsed = parse_candidate(raw_line)
        if parsed:
            candidates.append((parsed, raw_line))

    if not candidates:
        return 0

    project_root = Path(args.project_root).resolve() if args.project_root else None
    state_root = (
        resolve_state_root(project_root, args.state_root)
        if project_root is not None
        else None
    )
    if args.contextual == "auto":
        contextual = contextual_enabled_flag(None)
    else:
        contextual = args.contextual == "1"

    for line in rank_candidates(
        args.query,
        candidates,
        args.max_results,
        project_root=project_root,
        state_root=state_root,
        contextual=contextual,
    ):
        print(line)

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
