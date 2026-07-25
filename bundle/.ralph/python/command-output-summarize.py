#!/usr/bin/env python3
"""Summarize captured command output (stdin) for a known npm command pattern.

Reads full stdin as bytes (for accurate UTF-8 byte counts), decodes as UTF-8
with replacement for parsing. Emits one JSON object on stdout.
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from typing import Any, Dict, List, Optional, Tuple


_ANSI_RE = re.compile(r"\x1b\[[0-?]*[ -/]*[@-~]")


def strip_ansi(text: str) -> str:
    return _ANSI_RE.sub("", text)


def normalize_pattern(pattern: str) -> str:
    return " ".join(pattern.strip().split())


def read_stdin_bytes() -> Tuple[bytes, str]:
    raw = sys.stdin.buffer.read()
    text = raw.decode("utf-8", errors="replace")
    return raw, strip_ansi(text)


def emit(obj: Dict[str, Any]) -> None:
    sys.stdout.write(json.dumps(obj, ensure_ascii=True, indent=2) + "\n")


def head_tail_lines(text: str, head_n: int, tail_n: int) -> Tuple[List[str], List[str]]:
    lines = text.splitlines()
    if not lines:
        return [], []
    head = lines[:head_n]
    tail = lines[-tail_n:]
    return head, tail


def summarize_unknown(pattern: str, raw: bytes, text: str) -> Dict[str, Any]:
    head, tail = head_tail_lines(text, 20, 20)
    return {
        "pattern": pattern,
        "kind": "unknown",
        "total_bytes": len(raw),
        "head_lines": head,
        "tail_lines": tail,
    }


_RE_JEST_TESTS = re.compile(
    r"Tests:\s+(?:(?P<failed1>\d+)\s+failed,\s+(?P<passed1>\d+)\s+passed|(?P<passed2>\d+)\s+passed,\s+(?P<failed2>\d+)\s+failed)(?:,\s*(?P<total>\d+)\s+total)?",
    re.IGNORECASE,
)
_RE_JEST_SUITES = re.compile(
    r"Test Suites:\s+(?:(?P<sf>\d+)\s+failed,\s+(?P<sp>\d+)\+?\s*passed|(?P<sp2>\d+)\s+passed,\s+(?P<sf2>\d+)\s+failed)(?:,\s*(?P<st>\d+)\s+total)?",
    re.IGNORECASE,
)
_RE_VITEST_TESTS = re.compile(
    r"Tests\s+(?P<failed>\d+)\s+failed(?:\s+\((?P<passed1>\d+)\s+passed\)|\s*\|\s*(?P<passed2>\d+)\s+passed)",
    re.IGNORECASE,
)
_RE_MOCHA = re.compile(
    r"(?P<passing>\d+)\s+passing(?:.*?)(?P<failing>\d+)\s+failing",
    re.IGNORECASE | re.DOTALL,
)
_RE_MOCHA_PASS_ONLY = re.compile(r"(?P<passing>\d+)\s+passing", re.IGNORECASE)
_RE_FAIL_LINE = re.compile(r"^FAIL\s+(\S[^\n]*)", re.MULTILINE)
_RE_JEST_TEST_NAME = re.compile(r"^\s+(?:\u25cf|\u2715|×)\s+(.+)$", re.MULTILINE)
_RE_JEST_NUMBERED = re.compile(r"^\s+\d+\)\s+(.+)$", re.MULTILINE)


def _jest_test_counts(text: str) -> Tuple[Optional[int], Optional[int]]:
    m = _RE_JEST_TESTS.search(text)
    if not m:
        return None, None
    failed = m.group("failed1") or m.group("failed2")
    passed = m.group("passed1") or m.group("passed2")
    if failed is None or passed is None:
        return None, None
    return int(passed), int(failed)


def _vitest_test_counts(text: str) -> Tuple[Optional[int], Optional[int]]:
    m = _RE_VITEST_TESTS.search(text)
    if not m:
        return None, None
    passed_g = m.group("passed1") or m.group("passed2")
    if passed_g is None:
        return None, None
    return int(passed_g), int(m.group("failed"))


def _mocha_test_counts(text: str) -> Tuple[Optional[int], Optional[int]]:
    m = _RE_MOCHA.search(text)
    if m:
        return int(m.group("passing")), int(m.group("failing"))
    m2 = _RE_MOCHA_PASS_ONLY.search(text)
    if m2:
        return int(m2.group("passing")), 0
    return None, None


def _first_failing_test_and_assertion(text: str) -> Tuple[Optional[str], Optional[str]]:
    fail_file = None
    fm = _RE_FAIL_LINE.search(text)
    if fm:
        fail_file = fm.group(1).strip()

    test_name: Optional[str] = None
    for rx in (_RE_JEST_TEST_NAME, _RE_JEST_NUMBERED):
        mm = rx.search(text)
        if mm:
            test_name = mm.group(1).strip()
            break

    if test_name is None and fail_file:
        test_name = fail_file

    assertion: Optional[str] = None
    lines = text.splitlines()
    for i, line in enumerate(lines):
        if "expect(" in line or "AssertionError" in line or re.search(r"\bExpected:\s", line):
            window = lines[i : min(len(lines), i + 8)]
            parts: List[str] = []
            for s in window:
                st = s.strip()
                if not st:
                    continue
                if re.match(r"^Tests:\s", st) or re.match(r"^Test Suites:\s", st):
                    break
                parts.append(st)
            assertion = "\n".join(parts)
            if len(assertion) > 800:
                assertion = assertion[:800] + "..."
            break

    return test_name, assertion


def summarize_npm_test(pattern: str, raw: bytes, text: str) -> Dict[str, Any]:
    passed: Optional[int] = None
    failed: Optional[int] = None

    p, f = _jest_test_counts(text)
    if p is not None and f is not None:
        passed, failed = p, f
    if passed is None:
        p2, f2 = _vitest_test_counts(text)
        if p2 is not None:
            passed, failed = p2, f2
    if passed is None:
        p3, f3 = _mocha_test_counts(text)
        if p3 is not None:
            passed, failed = p3, f3

    if passed is None and failed is None:
        sm = _RE_JEST_SUITES.search(text)
        if sm:
            failed = int(sm.group("sf") or sm.group("sf2") or 0)
            passed = int(sm.group("sp") or sm.group("sp2") or 0)

    first_test, assertion = _first_failing_test_and_assertion(text)

    return {
        "pattern": pattern,
        "kind": "npm_test",
        "pass_count": passed,
        "fail_count": failed,
        "first_failing_test": first_test,
        "first_assertion_excerpt": assertion,
    }


_RE_ESLINT_PROBLEMS = re.compile(
    r"(?P<count>\d+)\s+problems?\s*\((?P<errors>\d+)\s+errors?(?:,\s*(?P<warnings>\d+)\s+warnings?)?\)",
    re.IGNORECASE,
)
_RE_ESLINT_ERRORS_PLAIN = re.compile(r"(?P<errors>\d+)\s+errors?", re.IGNORECASE)


def _eslint_error_lines(text: str, limit: int = 3) -> Tuple[int, List[str]]:
    m = _RE_ESLINT_PROBLEMS.search(text)
    err_count: Optional[int] = None
    if m:
        err_count = int(m.group("errors"))
    else:
        m2 = _RE_ESLINT_ERRORS_PLAIN.search(text)
        if m2:
            err_count = int(m2.group("errors"))

    candidates: List[str] = []
    for line in text.splitlines():
        s = line.strip()
        if not s or s.startswith("> ") or s.startswith("$ "):
            continue
        # Typical: path:line:col: error ...
        if re.search(r":\d+:\d+:\s+error\s", line) or re.search(r"\s+error\s+", line):
            if "problems (" not in line.lower():
                candidates.append(line.rstrip())
        if len(candidates) >= limit:
            break

    if err_count is None:
        err_count = len(candidates) if candidates else 0

    return err_count, candidates[:limit]


def summarize_npm_run_lint(pattern: str, raw: bytes, text: str) -> Dict[str, Any]:
    err_count, lines = _eslint_error_lines(text, 3)
    return {
        "pattern": pattern,
        "kind": "npm_run_lint",
        "error_count": err_count,
        "error_lines": lines,
    }


_RE_TSC_ERROR = re.compile(r"error\s+TS\d+:\s*(.+)", re.IGNORECASE)
_RE_ERROR_IN = re.compile(r"ERROR in\s+(.+)", re.IGNORECASE)
_RE_ELIFECYCLE = re.compile(r"npm ERR!.*ELIFECYCLE", re.IGNORECASE)
_RE_GENERIC_ERR = re.compile(r"^(?:Error|ERROR):\s*(.+)$", re.MULTILINE)


def summarize_npm_run_build(pattern: str, raw: bytes, text: str) -> Dict[str, Any]:
    lower = text.lower()

    def lifecycle_build_error_line() -> Optional[str]:
        if not _RE_ELIFECYCLE.search(text):
            return None
        for line in text.splitlines():
            ll = line.lower().lstrip()
            if "error" in ll and not ll.startswith("npm err"):
                return line.strip()
        return None

    failure_hints = (
        "elifecycle",
        "error ts",
        "error in ./",
        "failed to compile",
        "build failed",
        "compilation failed",
        "npm err!",
        " exited with code ",
        "cannot find module",
        "syntaxerror",
    )
    has_failure_hint = any(h in lower for h in failure_hints)
    first: Optional[str] = None
    for rx in (_RE_TSC_ERROR, _RE_ERROR_IN, _RE_GENERIC_ERR):
        mm = rx.search(text)
        if mm:
            g1 = mm.group(1)
            first = g1.strip() if g1 else mm.group(0).strip()
            break

    if first is None:
        first = lifecycle_build_error_line()

    if first is None and has_failure_hint:
        for line in text.splitlines():
            low = line.lower()
            if not any(h in low for h in failure_hints):
                continue
            if low.lstrip().startswith("npm err") and "error ts" not in low and "error in" not in low:
                continue
            first = line.strip()
            break

    if first is not None:
        return {
            "pattern": pattern,
            "kind": "npm_run_build",
            "status": "failure",
            "first_error": first,
        }

    if has_failure_hint:
        return {
            "pattern": pattern,
            "kind": "npm_run_build",
            "status": "failure",
            "first_error": "Build failed (no specific error line matched; inspect log).",
        }

    return {
        "pattern": pattern,
        "kind": "npm_run_build",
        "status": "success",
        "first_error": None,
    }


def summarize_for_pattern(pattern: str, raw: bytes) -> Dict[str, Any]:
    """Summarize captured output bytes for a command pattern (shared with checkpoint persist)."""
    text = strip_ansi(raw.decode("utf-8", errors="replace"))
    pattern_n = normalize_pattern(pattern)
    handlers: Dict[str, Any] = {
        "npm test": summarize_npm_test,
        "npm run build": summarize_npm_run_build,
        "npm run lint": summarize_npm_run_lint,
    }
    fn = handlers.get(pattern_n)
    if fn is None:
        return summarize_unknown(pattern_n, raw, text)
    return fn(pattern_n, raw, text)


def main() -> int:
    ap = argparse.ArgumentParser(description="Summarize stdin for a command pattern.")
    ap.add_argument(
        "pattern",
        help='Command pattern, e.g. "npm test", "npm run build", "npm run lint"',
    )
    args = ap.parse_args()
    raw, _text = read_stdin_bytes()
    emit(summarize_for_pattern(args.pattern, raw))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
