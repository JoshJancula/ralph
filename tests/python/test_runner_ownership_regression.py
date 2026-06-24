#!/usr/bin/env python3
"""Regression coverage for the end-to-end runner-owned verification ownership story.

Covers three properties:
1. Runner-executed verification: strict `verify:` commands run out-of-process,
   produce compact artifact summaries, and reopen the TODO on failure.
2. Compact artifact retrieval: the telemetry and result-windowing paths
   correctly compute compact views, result IDs, and net savings.
3. No agent-driven wait/status loops in the normal path: telemetry detects
   excess `shell_status` polling and guidance steers toward `shell_wait` or
   runner-owned verification.
"""

from __future__ import annotations

import json
import os
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent.parent.parent / "bundle" / ".ralph" / "python"))

from tool_call_target_telemetry import (  # noqa: E402
    _shell_status_poll_count,
    optimization_hint_line,
    stored_result_readback_guidance,
)
from verification_result import (  # noqa: E402
    line_verification_result,
    text_verification_result,
)
from completion_sentinel import (  # noqa: E402
    text_has_completion_sentinel,
)
from plan_todo_extract_verification_commands import (  # noqa: E402
    extract_verification_commands,
    verify_to_complete_command,
)
from result_windowing_metrics import (  # noqa: E402
    analyze_result_windowing_log,
)


class TestRunnerExecutedVerification(unittest.TestCase):
    """Strict verify: commands must be machine-extractable and runnable,
    while prose verification must never be passed to the shell."""

    def test_strict_verify_command_extracted(self) -> None:
        todo = (
            "Add regression tests.\n"
            "Verify: bash scripts/run-bats.sh -j 8\n"
            "Verification: Confirm the tests pass."
        )
        cmd = verify_to_complete_command(todo)
        self.assertEqual(cmd, "bash scripts/run-bats.sh -j 8")

    def test_prose_only_verification_yields_no_command(self) -> None:
        todo = (
            "Add the savings panel.\n"
            "Verification: Open the dashboard and confirm it renders."
        )
        cmd = verify_to_complete_command(todo)
        self.assertEqual(cmd, "")

    def test_blocked_command_rejected(self) -> None:
        todo = "Push changes.\nVerify: git push origin main"
        cmd = verify_to_complete_command(todo)
        self.assertEqual(cmd, "")

    def test_extract_verification_commands_from_backticks(self) -> None:
        text = "Run checks.\nVerification: `bash scripts/run-bats.sh tests/bats/foo.bats`"
        commands = extract_verification_commands(text)
        self.assertIn("bash scripts/run-bats.sh tests/bats/foo.bats", commands)

    def test_verification_result_pass(self) -> None:
        status, reason = text_verification_result("Done.\nTODO_VERIFICATION: PASS")
        self.assertEqual(status, "pass")
        self.assertEqual(reason, "")

    def test_verification_result_fail_with_reason(self) -> None:
        status, reason = text_verification_result("Failed.\nTODO_VERIFICATION: FAIL: tests red")
        self.assertEqual(status, "fail")
        self.assertEqual(reason, "tests red")

    def test_verification_result_skipped(self) -> None:
        status, reason = text_verification_result("TODO_VERIFICATION: SKIPPED")
        self.assertEqual(status, "skip")
        self.assertEqual(reason, "")

    def test_verification_result_none_when_absent(self) -> None:
        status, reason = text_verification_result("Done with work.")
        self.assertEqual(status, "none")
        self.assertEqual(reason, "")

    def test_last_verification_marker_wins(self) -> None:
        text = "First try failed\nVERIFICATION_RESULT: FAIL: oops\nFixed\nVERIFICATION_RESULT: PASS"
        status, _ = text_verification_result(text)
        self.assertEqual(status, "pass")

    def test_legacy_verification_result_pass(self) -> None:
        status, reason = text_verification_result("VERIFICATION_RESULT: PASS\nAGENT_INVOCATION_COMPLETE")
        self.assertEqual(status, "pass")
        self.assertEqual(reason, "")

    def test_legacy_verification_status_pass_with_tool_ids(self) -> None:
        status, reason = text_verification_result(
            "VERIFICATION STATUS: PASS tool_result_ids=res-123,res-456"
        )
        self.assertEqual(status, "pass")
        self.assertEqual(reason, "tool_result_ids=res-123,res-456")

    def test_line_verification_rejects_glued_sentinel(self) -> None:
        self.assertIsNone(line_verification_result("VERIFICATION_RESULT: MAYBE"))


class TestCompactArtifactRetrieval(unittest.TestCase):
    """Result windowing metrics compute correctly for compact artifact paths."""

    def test_envelope_and_compacted_readback(self) -> None:
        lines = [
            {"event": "envelope", "resultId": "abc123", "originalBytes": 2000, "returnedBytes": 200},
            {"event": "readback", "resultId": "abc123", "view": "compacted", "returnedBytes": 300},
        ]
        with tempfile.NamedTemporaryFile("w", encoding="utf-8", delete=False) as f:
            for line in lines:
                f.write(json.dumps(line) + "\n")
            path = f.name
        try:
            stats = analyze_result_windowing_log(path)
        finally:
            Path(path).unlink(missing_ok=True)

        self.assertEqual(stats["envelope_count"], 1)
        self.assertEqual(stats["readback_count"], 1)
        self.assertEqual(stats["compacted_readback_count"], 1)
        self.assertEqual(stats["raw_readback_count"], 0)
        self.assertLess(stats["net_consumed_bytes"], stats["envelope_original_bytes"])

    def test_raw_readback_increases_net_consumed(self) -> None:
        lines = [
            {"event": "envelope", "resultId": "r1", "originalBytes": 500, "returnedBytes": 100},
            {"event": "readback", "resultId": "r1", "view": "raw", "returnedBytes": 500},
        ]
        with tempfile.NamedTemporaryFile("w", encoding="utf-8", delete=False) as f:
            for line in lines:
                f.write(json.dumps(line) + "\n")
            path = f.name
        try:
            stats = analyze_result_windowing_log(path)
        finally:
            Path(path).unlink(missing_ok=True)

        self.assertEqual(stats["raw_readback_count"], 1)
        self.assertEqual(stats["net_consumed_bytes"], 500)

    def test_stored_result_readback_guidance_with_high_rereads(self) -> None:
        text = stored_result_readback_guidance(
            {
                "full_preview_rereads": 3,
                "raw_readback_count": 5,
                "raw_readback_share": 0.8,
                "readback_count": 8,
            }
        )
        self.assertIn("view=raw", text)
        self.assertIn("result_search", text)
        self.assertIn("avoid full preview re-reads", text)

    def test_stored_result_readback_guidance_without_high_rereads(self) -> None:
        text = stored_result_readback_guidance(
            {
                "full_preview_rereads": 0,
                "raw_readback_count": 1,
                "raw_readback_share": 0.25,
                "readback_count": 4,
            }
        )
        self.assertIn("view=raw", text)
        self.assertNotIn("avoid full preview re-reads", text)

    def test_readback_reason_counts_aggregated(self) -> None:
        lines = [
            {"event": "envelope", "resultId": "r1", "originalBytes": 1000, "returnedBytes": 100},
            {"event": "readback", "resultId": "r1", "view": "compacted", "returnedBytes": 50, "reason": "search_followup"},
            {"event": "readback", "resultId": "r1", "view": "raw", "returnedBytes": 100, "reason": "raw_exactness"},
        ]
        with tempfile.NamedTemporaryFile("w", encoding="utf-8", delete=False) as f:
            for line in lines:
                f.write(json.dumps(line) + "\n")
            path = f.name
        try:
            stats = analyze_result_windowing_log(path)
        finally:
            Path(path).unlink(missing_ok=True)

        self.assertEqual(stats["readback_reason_counts"], {
            "search_followup": 1,
            "raw_exactness": 1,
        })


class TestNoAgentDrivenPollingLoops(unittest.TestCase):
    """Telemetry correctly detects excess shell_status polling and steers
    agents toward shell_wait or runner-owned verification instead."""

    def test_shell_status_poll_count_zero_below_threshold(self) -> None:
        usage = {
            "tool_calls_by_tool": {
                "ralph_proxy_shell_status": 2,
                "ralph_proxy_shell_wait": 0,
            }
        }
        self.assertEqual(_shell_status_poll_count(usage), 0)

    def test_shell_status_poll_count_zero_proportional(self) -> None:
        usage = {
            "tool_calls_by_tool": {
                "ralph_proxy_shell_status": 6,
                "ralph_proxy_shell_wait": 3,
                "ralph_proxy_shell_start": 1,
            }
        }
        self.assertEqual(_shell_status_poll_count(usage), 0)

    def test_shell_status_poll_count_positive_when_excessive(self) -> None:
        usage = {
            "tool_calls_by_tool": {
                "ralph_proxy_shell_status": 10,
                "ralph_proxy_shell_wait": 1,
                "ralph_proxy_shell_start": 0,
            }
        }
        self.assertEqual(_shell_status_poll_count(usage), 8)

    def test_shell_status_poll_count_ignores_mcp_prefix(self) -> None:
        usage = {
            "tool_calls_by_tool": {
                "mcp__ralph__ralph_proxy_shell_status": 10,
                "mcp__ralph__ralph_proxy_shell_wait": 1,
            }
        }
        self.assertEqual(_shell_status_poll_count(usage), 8)

    def test_optimization_hint_includes_runner_owned_verification_when_polling(self) -> None:
        usage = {
            "adjacent_duplicate_tool_calls": 0,
            "repeated_read_extra_calls": 0,
            "plan_file_read_calls": 0,
            "cache_read_per_tool_turn": 0,
            "tool_calls_by_tool": {
                "ralph_proxy_shell_status": 10,
                "ralph_proxy_shell_wait": 1,
            },
        }
        hint = optimization_hint_line(usage)
        self.assertIn("shell_status poll", hint)
        self.assertIn("shell_wait", hint)
        self.assertIn("runner-owned verification", hint)

    def test_optimization_hint_no_polling_when_proportional(self) -> None:
        usage = {
            "adjacent_duplicate_tool_calls": 0,
            "repeated_read_extra_calls": 0,
            "plan_file_read_calls": 0,
            "cache_read_per_tool_turn": 0,
            "tool_calls_by_tool": {
                "ralph_proxy_shell_status": 4,
                "ralph_proxy_shell_wait": 2,
            },
        }
        hint = optimization_hint_line(usage)
        self.assertNotIn("shell_status poll", hint)

    def test_optimization_hint_includes_shell_wait_when_excessive(self) -> None:
        usage = {
            "tool_calls_by_tool": {
                "ralph_proxy_shell_status": 12,
                "ralph_proxy_shell_wait": 1,
            }
        }
        hint = optimization_hint_line(usage)
        self.assertIn("shell_wait", hint)
        self.assertNotIn("ralph_proxy_shell_status", hint.split(";")[0] if ";" in hint else hint)

    def test_empty_usage_produces_no_hint(self) -> None:
        hint = optimization_hint_line({})
        self.assertEqual(hint, "")

    def test_completion_sentinel_structured_footer(self) -> None:
        self.assertTrue(text_has_completion_sentinel("TODO_COMPLETION: COMPLETE\nTODO_VERIFICATION: PASS"))

    def test_completion_sentinel_legacy_marker(self) -> None:
        self.assertTrue(text_has_completion_sentinel("AGENT_INVOCATION_COMPLETE"))

    def test_completion_sentinel_glued_does_not_match(self) -> None:
        self.assertFalse(text_has_completion_sentinel("AGENT_INVOCATION_COMPLETEEarlier note"))

    def test_completion_sentinel_in_prose_does_not_match(self) -> None:
        self.assertFalse(text_has_completion_sentinel("Docs mention AGENT_INVOCATION_COMPLETE in passing."))


if __name__ == "__main__":
    unittest.main()