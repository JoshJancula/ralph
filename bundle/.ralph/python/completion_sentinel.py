#!/usr/bin/env python3
"""Detect AGENT_INVOCATION_COMPLETE in assistant-authored text only."""

from __future__ import annotations

import re
from typing import Any, Iterable, List

AGENT_DONE_MARKER = "AGENT_INVOCATION_COMPLETE"
_BULLET_PREFIX_RE = re.compile(r"^[\*●\-]\s+")
_MARKER_BOUNDARY_RE = re.compile(
    r"^" + re.escape(AGENT_DONE_MARKER) + r"(?:\s|$|[^\w])"
)


def line_has_completion_sentinel(line: str) -> bool:
    stripped = _BULLET_PREFIX_RE.sub("", line.strip())
    if stripped == AGENT_DONE_MARKER:
        return True
    return bool(_MARKER_BOUNDARY_RE.match(stripped))


def text_has_completion_sentinel(text: str) -> bool:
    for raw in text.splitlines():
        if line_has_completion_sentinel(raw):
            return True
        for part in raw.splitlines():
            if line_has_completion_sentinel(part):
                return True
    return False


def chunks_have_completion_sentinel(chunks: Iterable[str]) -> bool:
    for chunk in chunks:
        if not chunk:
            continue
        if text_has_completion_sentinel(chunk):
            return True
    return False


def assistant_text_chunks(obj: Any, mode: str) -> List[str]:
    chunks: List[str] = []
    if not isinstance(obj, dict):
        return chunks

    typ = str(obj.get("type", "")).strip().lower()
    if typ == "assistant":
        message = obj.get("message")
        if isinstance(message, dict):
            content = message.get("content")
            if isinstance(content, list):
                for block in content:
                    if not isinstance(block, dict):
                        continue
                    if str(block.get("type", "")).strip().lower() != "text":
                        continue
                    text = block.get("text")
                    if isinstance(text, str) and text.strip():
                        chunks.append(text)
    elif typ == "result":
        result = obj.get("result")
        if isinstance(result, str) and result.strip():
            chunks.append(result)
    elif mode == "codex" and typ == "item.completed":
        item = obj.get("item")
        if isinstance(item, dict) and str(item.get("type", "")).strip().lower() == "agent_message":
            text = item.get("text")
            if isinstance(text, str) and text.strip():
                chunks.append(text)

    return chunks


def object_has_assistant_completion_sentinel(obj: Any, mode: str) -> bool:
    return chunks_have_completion_sentinel(assistant_text_chunks(obj, mode))


def main() -> int:
    import sys

    if len(sys.argv) < 2 or sys.argv[1] != "text":
        print("usage: completion_sentinel.py text", file=sys.stderr)
        return 2
    print("1" if text_has_completion_sentinel(sys.stdin.read()) else "0")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
