#!/usr/bin/env python3
"""Normalize search query terms (one per line on stdout).

Default mode emits deduplicated original terms. With --expand it also emits
derived identifier subtokens (camelCase / snake_case / kebab / digit splits)
after the originals, so the candidate gather step can reach morphological
variants. The split here MUST match split_identifier in mcp-proxy-search-rank.py.
"""
import re
import sys

STRIP_CHARS = "`'\".,;:!?()[]{}"
SUBTOKEN_RE = re.compile(r"[A-Z]+(?=[A-Z][a-z])|[A-Z]?[a-z]+|[A-Z]+|[0-9]+")
MIN_SUBTOKEN_LEN = 3


def normalize(query):
    seen = set()
    terms = []
    for raw in query.split():
        term = raw.strip(STRIP_CHARS).strip()
        if not term:
            continue
        key = term.lower()
        if key in seen:
            continue
        seen.add(key)
        terms.append(term)
    return terms


def split_identifier(term):
    term_lower = term.lower()
    subs = []
    seen = set()
    for piece in SUBTOKEN_RE.findall(term):
        sub = piece.lower()
        if len(sub) < MIN_SUBTOKEN_LEN:
            continue
        if sub == term_lower or sub in seen:
            continue
        seen.add(sub)
        subs.append(sub)
    return subs


def main(argv):
    expand = False
    args = argv[1:]
    if args and args[0] == "--expand":
        expand = True
        args = args[1:]
    query = args[0] if args else ""
    terms = normalize(query)
    out = list(terms)
    if expand:
        seen = {t.lower() for t in terms}
        for term in terms:
            for sub in split_identifier(term):
                if sub in seen:
                    continue
                seen.add(sub)
                out.append(sub)
    print("\n".join(out))
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
