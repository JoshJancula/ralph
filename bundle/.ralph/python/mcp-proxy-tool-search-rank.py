#!/usr/bin/env python3
"""BM25 lexical ranker for ralph_proxy_tool_search (stdlib only)."""
from __future__ import annotations

import argparse
import importlib.util
import json
import math
import re
import sys
from pathlib import Path
from typing import Any

K1 = 1.2
B = 0.75

IDENT_RE = re.compile(r"[A-Za-z_][\w]*")


def _load_search_rank_module():
    script_dir = Path(__file__).resolve().parent
    rank_path = script_dir / "mcp-proxy-search-rank.py"
    spec = importlib.util.spec_from_file_location("mcp_proxy_search_rank", rank_path)
    if spec is None or spec.loader is None:
        raise ImportError(f"unable to load {rank_path}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


search_rank = _load_search_rank_module()
normalize_terms = search_rank.normalize_terms
tokenize = search_rank.tokenize
compute_idf = search_rank.compute_idf


def compact_schema_summary(input_schema: dict[str, Any] | None) -> str:
    if not isinstance(input_schema, dict):
        return ""
    props = input_schema.get("properties")
    if not isinstance(props, dict):
        return ""
    required = set(input_schema.get("required") or [])
    parts: list[str] = []
    for name, spec in props.items():
        if not isinstance(spec, dict):
            continue
        typ = spec.get("type", "?")
        req = "*" if name in required else ""
        desc = str(spec.get("description") or "")
        if len(desc) > 72:
            desc = desc[:69] + "..."
        parts.append(f"{name}{req}:{typ}" + (f" ({desc})" if desc else ""))
        if len(parts) >= 16:
            break
    return "; ".join(parts)


def tool_document_text(tool: dict[str, Any]) -> str:
    parts = [str(tool.get("name") or ""), str(tool.get("description") or "")]
    schema = tool.get("inputSchema")
    if isinstance(schema, dict):
        props = schema.get("properties")
        if isinstance(props, dict):
            for pname, pspec in props.items():
                parts.append(str(pname))
                if isinstance(pspec, dict):
                    parts.append(str(pspec.get("description") or ""))
                    enum_vals = pspec.get("enum")
                    if isinstance(enum_vals, list):
                        parts.extend(str(v) for v in enum_vals)
    return " ".join(part for part in parts if part)


def term_frequency(term_lower: str, content_lower: str, tokens: list[str]) -> int:
    tf = sum(1 for t in tokens if t == term_lower)
    if tf > 0:
        return tf
    if term_lower in content_lower:
        return content_lower.count(term_lower) or 1
    return 0


def score_tool_document(
    tool: dict[str, Any],
    document: str,
    terms: list[str],
    term_idf: dict[str, float],
    avg_dl: float,
) -> float:
    content_lower = document.lower()
    tokens = tokenize(document)
    dl = len(tokens) or 1
    name = str(tool.get("name") or "")
    name_lower = name.lower()
    score = 0.0

    for term in terms:
        term_lower = term.lower()
        tf = term_frequency(term_lower, content_lower, tokens)
        idf = term_idf.get(term_lower, 0.0)
        if term_lower in search_rank.COMMON_TOKENS:
            idf *= 0.25

        if tf > 0:
            bm25 = idf * (tf * (K1 + 1)) / (tf + K1 * (1 - B + B * dl / avg_dl))
            score += bm25

        ident_pat = r"(?<![\w])" + re.escape(term) + r"(?![\w])"
        if re.search(ident_pat, document, re.IGNORECASE):
            score += idf * 2.0
        if re.search(ident_pat, document):
            score += idf * 3.0

        if term_lower in name_lower:
            score += idf * 4.0
        if term_lower.replace("_", "") in name_lower.replace("_", ""):
            score += idf * 2.0

    return score


def rank_tools(catalog: list[dict[str, Any]], query: str, max_results: int) -> list[dict[str, Any]]:
    terms = normalize_terms(query)
    if not terms or not catalog:
        return []

    documents = [tool_document_text(tool) for tool in catalog]
    num_docs = len(documents)
    term_doc_freq: dict[str, int] = {}
    total_dl = 0

    for document in documents:
        tokens = tokenize(document)
        total_dl += len(tokens) or 1
        seen_terms: set[str] = set(tokens)
        content_lower = document.lower()
        for term in terms:
            tl = term.lower()
            if tl in content_lower:
                seen_terms.add(tl)
        for token in seen_terms:
            term_doc_freq[token] = term_doc_freq.get(token, 0) + 1

    avg_dl = total_dl / num_docs if num_docs else 1.0
    term_idf: dict[str, float] = {}
    for term in terms:
        tl = term.lower()
        term_idf[tl] = compute_idf(term_doc_freq.get(tl, 0), num_docs)

    scored: list[tuple[float, int, dict[str, Any]]] = []
    for idx, tool in enumerate(catalog):
        document = documents[idx]
        score = score_tool_document(tool, document, terms, term_idf, avg_dl)
        scored.append((score, idx, tool))

    scored.sort(key=lambda item: (-item[0], str(item[2].get("name") or ""), item[1]))

    results: list[dict[str, Any]] = []
    rank = 0
    for score, _idx, tool in scored:
        if score <= 0.0:
            continue
        rank += 1
        if rank > max_results:
            break
        results.append(
            {
                "rank": rank,
                "name": tool.get("name"),
                "description": tool.get("description"),
                "schemaSummary": compact_schema_summary(tool.get("inputSchema")),
                "score": round(score, 4),
            }
        )
    return results


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--query", required=True)
    parser.add_argument("--max-results", type=int, default=10)
    args = parser.parse_args()

    try:
        catalog = json.load(sys.stdin)
    except json.JSONDecodeError:
        print("[]")
        return 0

    if not isinstance(catalog, list):
        print("[]")
        return 0

    max_results = max(1, min(args.max_results, 50))
    results = rank_tools(catalog, args.query, max_results)
    json.dump(results, sys.stdout, separators=(",", ":"))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
