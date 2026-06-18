#!/usr/bin/env python3
"""Detect an agent-reported verification verdict line in text.

The runner asks the agent to run a TODO's verification steps itself when no
runnable command can be machine-extracted, and to end with a line of the form:

    VERIFICATION STATUS: PASS
    VERIFICATION STATUS: FAIL: <reason>
    VERIFICATION_RESULT: PASS
    VERIFICATION_RESULT: FAIL: <reason>
    VERIFICATION_RESULT: PASS tool_result_ids=<id1>,<id2>
    VERIFICATION STATUS: PASS tool_result_ids=<id1>,<id2>

This module reports the agent's final verdict (the last such line wins) as one of
"pass", "fail", or "none". It mirrors completion_sentinel.py: assistant-authored
text only, tolerant of a leading bullet and surrounding whitespace.
"""

from __future__ import annotations

import re
import sys
from typing import Optional, Tuple

VERIFICATION_MARKERS = ("VERIFICATION_RESULT", "VERIFICATION STATUS")
_RESULT_RE = re.compile(
    r"^[\*●\-]?\s*"
    + r"(?:" + "|".join(re.escape(marker) for marker in VERIFICATION_MARKERS) + r")"
    + r"\s*:\s*(PASS|FAIL)\b\s*:?\s*(.*)$",
    re.IGNORECASE,
)


def line_verification_result(line: str) -> Optional[Tuple[str, str]]:
    match = _RESULT_RE.match(line.strip())
    if not match:
        return None
    status = match.group(1).strip().lower()
    reason = match.group(2).strip()
    return status, reason


def text_verification_result(text: str) -> Tuple[str, str]:
    """Return (status, reason); status is "pass", "fail", or "none".

    The last verification-result line in the text wins, so an agent that retries
    within one invocation and ends on PASS is reported as a pass.
    """
    status = "none"
    reason = ""
    for raw in text.splitlines():
        parsed = line_verification_result(raw)
        if parsed is not None:
            status, reason = parsed
    return status, reason


def main() -> int:
    if len(sys.argv) < 2 or sys.argv[1] != "text":
        print("usage: verification_result.py text", file=sys.stderr)
        return 2
    status, reason = text_verification_result(sys.stdin.read())
    print(status)
    if reason:
        print(reason)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
