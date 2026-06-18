#!/usr/bin/env python3
"""BM25/IDF lexical ranker for ralph_proxy_search (stdlib only, no index)."""
from __future__ import annotations

import argparse
import math
import re
import sys

K1 = 1.2
B = 0.75

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


def score_candidate(
    filepath: str,
    content: str,
    terms: list[str],
    term_idf: dict[str, float],
    avg_dl: float,
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

        ident_pat = r"(?<![\w])" + re.escape(term) + r"(?![\w])"
        if re.search(ident_pat, content, re.IGNORECASE):
            score += idf * 2.0
        if re.search(ident_pat, content):
            score += idf * 3.0

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

    return score


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--query", required=True)
    parser.add_argument("--max-results", type=int, default=50)
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

    scored: list[tuple[float, str, str, int]] = []
    for (filepath, line_no, content), raw_line in candidates:
        s = score_candidate(filepath, content, terms, term_idf, avg_dl)
        scored.append((s, raw_line, filepath, line_no))

    scored.sort(key=lambda item: (-item[0], item[2], item[3], item[1]))

    for _score, raw_line, _filepath, _line_no in scored[: args.max_results]:
        print(raw_line)

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
