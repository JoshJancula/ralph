#!/usr/bin/env python3
"""Classify a TODO line into manual_gate, destructive_gate, verification_gate, implementation_gate, or normal."""
import re
import sys

text = sys.argv[1]
lower = text.lower()

manual_patterns = [
    r'\bmanual\b',
    r'\bsmoke\b',
    r'\bgolden[ -]path\b',
    r'\bnot run in this session\b',
    r'\bask the user\b',
]
destructive_patterns = [
    r'\bdelete\b',
    r'\bdrop\b',
    r'\bdestroy\b',
    r'\bpurge\b',
    r'\btruncate\b',
    r'\bwipe\b',
    r'\brollback\b',
    r'\bmigrate down\b',
    r'\bdown-migrate\b',
    r'\bremove\b',
]
implementation_patterns = [
    r'\bimplement\b',
    r'\badd\b',
    r'\bupdate\b',
    r'\bfix\b',
    r'\bcreate\b',
    r'\bmodify\b',
    r'\bpatch\b',
    r'\bwire\b',
    r'\bintegrate\b',
    r'\brefactor\b',
    r'\bchange\b',
    r'\bchanges\b',
    r'\bchanged\b',
    r'\bmake\b.*\bchanges?\b',
    r'\bremove\b',
    r'\breplace\b',
    r'\bdelete\b',
    r'\binsert\b',
    r'\bwrap\b',
    r'\bdelete\b',
]
normal_patterns = [
    r'\bdocs?\b',
    r'\bdocumentation\b',
    r'\brunbook\b',
    r'\banalysis\b',
    r'\breview\b',
    r'\binvestigate\b',
    r'\bexplain\b',
    r'\bsummarize\b',
    r'\bread\b',
]

if any(re.search(pattern, lower) for pattern in manual_patterns):
    print("manual_gate")
elif any(re.search(pattern, lower) for pattern in destructive_patterns):
    print("destructive_gate")
else:
    command_prefixes = (
        "./",
        "/",
        "npm",
        "npx",
        "yarn",
        "pnpm",
        "git",
        "bash",
        "sh",
        "python",
        "python3",
        "pytest",
        "playwright",
        "node",
        "make",
        "go",
        "cargo",
        "bun",
        "deno",
        "grep",
        "rg",
        "sed",
        "awk",
        "find",
        "cat",
        "curl",
        "docker",
        "kubectl",
        "mvn",
        "gradle",
        "tsc",
        "eslint",
        "prettier",
        "vitest",
        "jest",
        "rspec",
        "bundle",
        "rake",
        "uv",
    )

    def looks_like_command(candidate: str) -> bool:
        candidate = candidate.strip()
        if not candidate:
            return False
        first = candidate.split(None, 1)[0]
        if first.startswith("./") or first.startswith("/"):
            return True
        return first in command_prefixes

    verification_hint = False
    if re.search(r'(^|\n)\s*(verification|verify)\s*:', text, re.I):
        verification_hint = True
    else:
        for candidate in re.findall(r'`([^`]+)`', text):
            if looks_like_command(candidate):
                verification_hint = True
                break
        if not verification_hint and re.search(r'(^|\n).*(?:&&|\|\||;).+', text):
            verification_hint = True

    if verification_hint:
        print("verification_gate")
    elif any(re.search(pattern, lower) for pattern in implementation_patterns) and not any(re.search(pattern, lower) for pattern in normal_patterns):
        print("implementation_gate")
    else:
        print("normal")
