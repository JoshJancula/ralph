#!/usr/bin/env python3
"""Normalize and deduplicate search query terms (one per line on stdout)."""
import sys

query = sys.argv[1]
strip_chars = "`'\".,;:!?()[]{}"
seen = set()
terms = []
for raw in query.split():
    term = raw.strip(strip_chars).strip()
    if not term:
        continue
    key = term.lower()
    if key in seen:
        continue
    seen.add(key)
    terms.append(term)
print("\n".join(terms))
