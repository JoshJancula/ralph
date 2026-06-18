#!/usr/bin/env python3
"""Select the next open markdown TODO respecting RALPH_PLAN_VERIFICATION_MODE.

Modes (argv[2]):
  per_phase -- Within each phase, defer broad verification prose until after other
    open work. Phases start at each markdown heading (#..######) and at each
    checklist item (open or done) classified as verification_gate (explicit
    verification TODO boundary).
  final     -- Defer broad verification until after all other open work in the
    whole plan, then explicit verification_gate TODOs, then broad items.
    Headings do not define phases in this mode.

The first output field matches get_next_todo for markdown plans: the 1-based
line number of the last line of the selected TODO block (same as bash when the
next item ends the prior block).

Output: one line "LINE|BLOCK" where BLOCK includes continuation lines. Exit 1
when no open TODOs.
"""

from __future__ import annotations

import re
import sys


def risk_classify(text: str) -> str:
    """Mirror bundle/.ralph/bash-lib/plan-todo.sh plan_todo_risk_classify."""
    lower = text.lower()
    manual_patterns = [
        r"\bmanual\b",
        r"\bsmoke\b",
        r"\bgolden[ -]path\b",
        r"\bnot run in this session\b",
        r"\bask the user\b",
    ]
    destructive_patterns = [
        r"\bdelete\b",
        r"\bdrop\b",
        r"\bdestroy\b",
        r"\bpurge\b",
        r"\btruncate\b",
        r"\bwipe\b",
        r"\brollback\b",
        r"\bmigrate down\b",
        r"\bdown-migrate\b",
        r"\bremove\b",
    ]
    implementation_patterns = [
        r"\bimplement\b",
        r"\badd\b",
        r"\bupdate\b",
        r"\bfix\b",
        r"\bcreate\b",
        r"\bmodify\b",
        r"\bpatch\b",
        r"\bwire\b",
        r"\bintegrate\b",
        r"\brefactor\b",
        r"\bchange\b",
        r"\bchanges\b",
        r"\bchanged\b",
        r"\bmake\b.*\bchanges?\b",
        r"\bremove\b",
        r"\breplace\b",
        r"\bdelete\b",
        r"\binsert\b",
        r"\bwrap\b",
    ]
    normal_patterns = [
        r"\bdocs?\b",
        r"\bdocumentation\b",
        r"\brunbook\b",
        r"\banalysis\b",
        r"\breview\b",
        r"\binvestigate\b",
        r"\bexplain\b",
        r"\bsummarize\b",
        r"\bread\b",
    ]

    if any(re.search(pattern, lower) for pattern in manual_patterns):
        return "manual_gate"
    if any(re.search(pattern, lower) for pattern in destructive_patterns):
        return "destructive_gate"

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
    if re.search(r"(^|\n)\s*verification\s*:", text, re.I):
        verification_hint = True
    else:
        for candidate in re.findall(r"`([^`]+)`", text):
            if looks_like_command(candidate):
                verification_hint = True
                break
        if not verification_hint and re.search(r"(^|\n).*(?:&&|\|\||;).+", text):
            verification_hint = True

    if verification_hint:
        return "verification_gate"
    if any(re.search(pattern, lower) for pattern in implementation_patterns) and not any(
        re.search(pattern, lower) for pattern in normal_patterns
    ):
        return "implementation_gate"
    return "normal"


def is_broad_verification(cls: str, text: str) -> bool:
    """Broad prose verification: defer under per_phase/final; never defer verification_gate."""
    if cls == "verification_gate":
        return False
    low = text.lower()
    if re.search(r"\b(verify|validat(e|ing|ed|ion)?)\b", low):
        return True
    if re.search(r"\bregression\b", low) and re.search(r"\b(test|tests|check|run)\b", low):
        return True
    if re.search(r"\b(smoke|sanity)\s+test(s)?\b", low):
        return True
    if re.search(r"\b(double[- ]check|confirm acceptance|manually verify)\b", low):
        return True
    return False


def parse_checkbox_blocks(lines: list[str]) -> list[dict]:
    """Parse - [ ] and - [x] blocks using the same boundaries as get_next_todo."""
    n = len(lines)
    blocks: list[dict] = []
    i = 0
    while i < n:
        line = lines[i]
        open_m = re.match(r"^(\s*)-\s+(\[\s\]|\[x\])\s*", line)
        if not open_m:
            i += 1
            continue
        bracket = open_m.group(2)
        is_open = bracket == "[ ]"
        start_line = i + 1
        block_lines = [line]
        j = i + 1
        while j < n:
            nl = lines[j]
            if re.match(r"^\s*-\s+(\[\s\]|\[x\])\s*", nl):
                break
            if re.match(r"^#{1,6}\s", nl):
                break
            if re.match(r"^---\s*$", nl):
                break
            if nl.strip() and not re.match(r"^[ \t]", nl):
                break
            block_lines.append(nl)
            j += 1
        block_text = "\n".join(block_lines)
        end_line = start_line + len(block_lines) - 1
        cls = risk_classify(block_text)
        blocks.append(
            {
                "start_line": start_line,
                "end_line": end_line,
                "block": block_text,
                "open": is_open,
                "cls": cls,
                "broad": is_broad_verification(cls, block_text),
            }
        )
        i = j
    return blocks


def phase_id_for_start_line(lines: list[str], blocks: list[dict], start_line: int) -> int:
    """Phase index for a checklist block that starts at start_line (1-based checkbox line)."""
    p = 0
    for lno in range(1, start_line + 1):
        line = lines[lno - 1]
        if re.match(r"^#{1,6}\s", line):
            p += 1
            continue
        for b in blocks:
            if b["start_line"] == lno and b["cls"] == "verification_gate":
                p += 1
                break
    return p


def pick_next(mode: str, lines: list[str], blocks: list[dict]) -> dict | None:
    open_blocks = [(i, b) for i, b in enumerate(blocks) if b["open"]]
    if not open_blocks:
        return None

    if mode == "final":
        tier0: list[tuple[int, dict]] = []
        tier1: list[tuple[int, dict]] = []
        tier2: list[tuple[int, dict]] = []
        for i, b in open_blocks:
            if b["cls"] == "verification_gate":
                tier1.append((i, b))
            elif b["broad"]:
                tier2.append((i, b))
            else:
                tier0.append((i, b))
        for tier in (tier0, tier1, tier2):
            if tier:
                tier.sort(key=lambda t: t[1]["start_line"])
                return tier[0][1]
        return open_blocks[0][1]

    phase_ids = [phase_id_for_start_line(lines, blocks, b["start_line"]) for _, b in open_blocks]
    min_phase = min(phase_ids)
    candidates = [t for t in open_blocks if phase_id_for_start_line(lines, blocks, t[1]["start_line"]) == min_phase]
    candidates.sort(key=lambda t: t[1]["start_line"])
    non_broad = [t for t in candidates if not t[1]["broad"]]
    if non_broad:
        return non_broad[0][1]
    return candidates[0][1]


def main() -> None:
    if len(sys.argv) < 3:
        print(
            "usage: plan-todo-verification-next.py <plan.md> <per_phase|final>",
            file=sys.stderr,
        )
        raise SystemExit(2)
    path = sys.argv[1]
    mode = sys.argv[2]
    if mode not in ("per_phase", "final"):
        print("mode must be per_phase or final", file=sys.stderr)
        raise SystemExit(2)
    try:
        with open(path, encoding="utf-8") as fh:
            text = fh.read()
    except OSError as e:
        print(str(e), file=sys.stderr)
        raise SystemExit(1) from e
    lines = text.splitlines()
    blocks = parse_checkbox_blocks(lines)
    chosen = pick_next(mode, lines, blocks)
    if chosen is None:
        raise SystemExit(1)
    print(f"{chosen['end_line']}|{chosen['block']}")


if __name__ == "__main__":
    main()
