#!/usr/bin/env python3
"""Regression tests for Claude token accounting in run-plan-cli-json-demux.py.

Claude stream-json emits one `assistant` event per CONTENT BLOCK, not per API
request. Every block of one response repeats the same message.id and a copy of
that request's usage, so summing raw assistant events multiplies each request's
tokens by its block count. The fixture here is a real captured session (5 API
requests, 11 assistant events) reduced to its usage-bearing structure; the
expected values are that session's terminal result event, which is the exact
cross-request sum.

Before the dedupe fix this session reported cache_read 210913 instead of 97257
(2.17x) and output 38 instead of 598 (15.7x low).
"""

from __future__ import annotations

import io
import json
import sys
import tempfile
import unittest
from pathlib import Path

# Pytest invoked from the repository root does not add this directory to
# sys.path; keep the focused test runnable with the TODO's exact command.
sys.path.insert(0, str(Path(__file__).parent))

from ralph_script_loader import load_ralph_script

DEMUX = load_ralph_script("run-plan-cli-json-demux")

FIXTURE = (
    Path(__file__).resolve().parents[1]
    / "fixtures"
    / "run-plan-cli-json-demux"
    / "claude-multiblock-usage.jsonl"
)
TEXT_ONLY_FIXTURE = (
    Path(__file__).resolve().parents[1]
    / "fixtures"
    / "run-plan-cli-json-demux"
    / "claude-text-only-usage.jsonl"
)
TOOL_RESULT_FIXTURE = (
    Path(__file__).resolve().parents[1]
    / "fixtures"
    / "run-plan-cli-json-demux"
    / "claude-tool-result-bytes.jsonl"
)

# Ground truth: the captured session's terminal result event.
EXPECTED = {
    "input_tokens": 42,
    "output_tokens": 598,
    "cache_creation_input_tokens": 4191,
    "cache_read_input_tokens": 97257,
}
EXPECTED_REQUESTS = 5

# What summing every assistant event produced instead (the bug being guarded).
BUGGY_CACHE_READ = 210913


def _run_demux(lines: list[str]) -> dict:
    """Feed NDJSON lines through the demux and return the usage record."""
    with tempfile.TemporaryDirectory() as tmp:
        usage_path = Path(tmp) / "usage.json"
        sid_path = Path(tmp) / "sid.txt"
        argv = ["demux", "claude", str(sid_path), str(usage_path)]
        stdin, stdout, stderr = sys.stdin, sys.stdout, sys.stderr
        sys.stdin = io.StringIO("\n".join(lines) + "\n")
        sys.stdout = io.StringIO()
        sys.stderr = io.StringIO()
        try:
            sys.argv = argv
            DEMUX.main()
        except SystemExit:
            pass
        finally:
            sys.stdin, sys.stdout, sys.stderr = stdin, stdout, stderr
        return json.loads(usage_path.read_text())


class ClaudeUsageDedupeTest(unittest.TestCase):
    def setUp(self) -> None:
        self.lines = FIXTURE.read_text().splitlines()

    def test_usage_matches_result_event_exactly(self) -> None:
        usage = _run_demux(self.lines)
        for field, expected in EXPECTED.items():
            self.assertEqual(usage[field], expected, f"{field} mismatch")

    def test_records_first_request_prefix_tokens(self) -> None:
        usage = _run_demux(self.lines)
        self.assertEqual(usage["first_request_input_tokens"], 19948)

    def test_repeated_content_blocks_are_not_double_counted(self) -> None:
        usage = _run_demux(self.lines)
        self.assertNotEqual(usage["cache_read_input_tokens"], BUGGY_CACHE_READ)
        self.assertLess(usage["cache_read_input_tokens"], BUGGY_CACHE_READ)

    def test_tool_turns_counts_api_requests_not_events(self) -> None:
        assistant_events = sum(
            1 for line in self.lines if json.loads(line).get("type") == "assistant"
        )
        self.assertGreater(assistant_events, EXPECTED_REQUESTS)  # fixture is multi-block
        usage = _run_demux(self.lines)
        self.assertEqual(usage["tool_turns"], EXPECTED_REQUESTS)

    def test_output_tokens_come_from_result_not_stale_block_snapshots(self) -> None:
        # Per-event output_tokens are stale partials (they sum to 38 here).
        usage = _run_demux(self.lines)
        self.assertEqual(usage["output_tokens"], EXPECTED["output_tokens"])

    def test_interrupted_stream_falls_back_to_deduped_sum(self) -> None:
        """No result event: cost fields stay exact via dedupe-by-message-id."""
        truncated = [
            line for line in self.lines if json.loads(line).get("type") != "result"
        ]
        usage = _run_demux(truncated)
        for field in (
            "input_tokens",
            "cache_creation_input_tokens",
            "cache_read_input_tokens",
        ):
            self.assertEqual(usage[field], EXPECTED[field], f"{field} mismatch")
        self.assertEqual(usage["tool_turns"], EXPECTED_REQUESTS)
        # output_tokens is unrecoverable without the result event; it must at least
        # not be inflated by counting the same block snapshots repeatedly.
        self.assertLess(usage["output_tokens"], EXPECTED["output_tokens"])

    def test_counts_deduped_text_only_requests(self) -> None:
        usage = _run_demux(TEXT_ONLY_FIXTURE.read_text().splitlines())
        self.assertEqual(usage["tool_turns"], 4)
        self.assertEqual(usage["requests_without_tool_use"], 2)

    def test_counts_tool_result_bytes_by_tool(self) -> None:
        usage = _run_demux(TOOL_RESULT_FIXTURE.read_text().splitlines())
        self.assertEqual(usage["tool_result_bytes_by_tool"], {"Read": 14, "Bash": 4})
        self.assertEqual(usage["tool_result_bytes_total"], 18)


if __name__ == "__main__":
    unittest.main()
