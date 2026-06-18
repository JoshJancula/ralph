#!/usr/bin/env python3
"""Check whether a TODO text contains autonomous evidence phrases."""
import re
import sys

text = sys.argv[1].lower()
patterns = [
    r'\bverified\b',
    r'\bautovalidated\b',
    r'\bplaywright\b.*\b(pass(ed)?|succeed(ed)?|ok)\b',
    r'\bunit\s+test(s)?\b.*\b(pass(ed)?|succeed(ed)?|ok)\b',
    r'\btest(s)?\b.*\b(pass(ed)?|succeed(ed)?|ok)\b',
    r'\bcode\s+review\b.*\b(pass(ed)?|succeed(ed)?|ok)\b',
    r'\bautomated\s+check\b.*\b(pass(ed)?|succeed(ed)?|ok)\b',
    r'\bexit\s+0\b',
]
print("1" if any(re.search(pattern, text, re.I | re.S) for pattern in patterns) else "0")
