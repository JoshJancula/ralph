#!/usr/bin/env python3
"""Unit tests for antigravity plain-text handling in run-plan-cli-json-demux.py.

Antigravity (`agy --print`) emits plain text, not NDJSON, so every line falls
into the demux script's generic plain-text passthrough branch. These tests
verify the fix that recovers tool-call counts from agy's own bullet
convention (`* toolname(args)`) and marks the record `usage_unsupported`
since agy never reports token/cache usage anywhere accessible.
"""

from __future__ import annotations

import io
import json
import sys
import tempfile
import unittest
from pathlib import Path

from ralph_script_loader import load_ralph_script

DEMUX = load_ralph_script("run-plan-cli-json-demux")

SAMPLE_LINES = [
    "* ralph_proxy_glob(bundle)",
    "- ... +212 more lines",
    "I'll search for the relevant files now.",
    "* ralph_proxy_read(bundle/.ralph/python/foo.py)",
    "Done reviewing the file.",
]


def _run_demux(lines: list[str]) -> dict:
    with tempfile.TemporaryDirectory() as td:
        usage_path = str(Path(td) / "usage.json")
        sid_path = str(Path(td) / "sid.txt")
        old_argv = sys.argv
        old_stdin = sys.stdin
        try:
            sys.argv = ["run-plan-cli-json-demux.py", "antigravity", sid_path, usage_path, ""]
            sys.stdin = io.StringIO("\n".join(lines) + "\n")
            DEMUX.main()
        finally:
            sys.argv = old_argv
            sys.stdin = old_stdin
        with open(usage_path, encoding="utf-8") as fh:
            return json.load(fh)


class TestAntigravityPlainToolCallExtraction(unittest.TestCase):
    def test_tool_calls_extracted_from_plain_bullets(self) -> None:
        doc = _run_demux(SAMPLE_LINES)
        self.assertEqual(doc["tool_calls_total"], 2)
        self.assertEqual(doc["tool_calls_by_tool"].get("ralph_proxy_glob"), 1)
        self.assertEqual(doc["tool_calls_by_tool"].get("ralph_proxy_read"), 1)

    def test_non_bullet_lines_are_not_counted_as_tool_calls(self) -> None:
        doc = _run_demux(["I'll search for the relevant files now.", "- ... +212 more lines"])
        self.assertEqual(doc["tool_calls_total"], 0)

    def test_repeated_tool_calls_each_counted(self) -> None:
        doc = _run_demux(
            [
                "* ralph_proxy_read(a.py)",
                "* ralph_proxy_read(b.py)",
            ]
        )
        self.assertEqual(doc["tool_calls_total"], 2)
        self.assertEqual(doc["tool_calls_by_tool"].get("ralph_proxy_read"), 2)


class TestAntigravityUsageUnsupported(unittest.TestCase):
    def test_usage_unsupported_flag_set(self) -> None:
        doc = _run_demux(SAMPLE_LINES)
        self.assertTrue(doc["usage_unsupported"])

    def test_other_modes_unaffected(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            usage_path = str(Path(td) / "usage.json")
            sid_path = str(Path(td) / "sid.txt")
            old_argv = sys.argv
            old_stdin = sys.stdin
            try:
                sys.argv = ["run-plan-cli-json-demux.py", "claude", sid_path, usage_path, ""]
                sys.stdin = io.StringIO("plain line, no json here\n")
                DEMUX.main()
            finally:
                sys.argv = old_argv
                sys.stdin = old_stdin
            with open(usage_path, encoding="utf-8") as fh:
                doc = json.load(fh)
        self.assertNotIn("usage_unsupported", doc)


if __name__ == "__main__":
    unittest.main()
