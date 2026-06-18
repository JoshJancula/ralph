#!/usr/bin/env python3
"""Check whether a TODO text contains suspicious completion phrases."""
import re
import sys

text = sys.argv[1].lower()
patterns = [
    r'marked\s+.*complete',
    r'no\s+further\s+action',
    r'no\s+additional\s+steps',
    r'done\s+and\s+stop',
]
print("1" if any(re.search(pattern, text) for pattern in patterns) else "0")
