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
import subprocess
import sys
import tempfile
import unittest
from unittest import mock
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
BASELINE_FIXTURE_DIR = REPO_ROOT / "tests" / "fixtures" / "benchmark-channel-attribution"
OVERLAY_WRITE_SCRIPT = REPO_ROOT / "bundle" / ".ralph" / "python" / "runtime-overlay-write-summary.py"
OVERLAY_FIELDS_SCRIPT = REPO_ROOT / "bundle" / ".ralph" / "python" / "ralph_overlay_usage_fields.py"

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
            {
                "event": "envelope",
                "resultId": "abc123",
                "runtime": "cursor",
                "channel": "proxy_read_windowing",
                "originalBytes": 2000,
                "returnedBytes": 200,
            },
            {
                "event": "readback",
                "resultId": "abc123",
                "runtime": "cursor",
                "channel": "stored_result_readback",
                "sourceResultChannel": "proxy_read_windowing",
                "view": "compacted",
                "returnedBytes": 300,
            },
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
        # 100-byte preview plus a 500-byte raw readback: the agent consumed 600
        # against a 500-byte baseline, so windowing cost 100 bytes net.
        self.assertEqual(stats["net_consumed_bytes"], 600)

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


class TestRuntimeOverlayPerRuntimeSummaries(unittest.TestCase):
    """Per-runtime summaries are isolated; aggregate summary.json is regenerated."""

    def _write_overlay_summary(self, summary_path: Path, env: dict[str, str]) -> None:
        merged = os.environ.copy()
        merged.update(env)
        state_dir = env.get("RUNTIME_OVERLAY_STATE_DIR_VALUE") or str(summary_path.parent)
        merged.setdefault("RUNTIME_OVERLAY_STATE_DIR_VALUE", state_dir)
        proc = subprocess.run(
            [
                sys.executable,
                str(OVERLAY_WRITE_SCRIPT),
                str(summary_path),
                str(OVERLAY_FIELDS_SCRIPT),
            ],
            env=merged,
            capture_output=True,
            text=True,
            check=False,
        )
        self.assertEqual(
            proc.returncode,
            0,
            msg=proc.stderr or proc.stdout,
        )

    def test_runtime_overlay_per_runtime_summaries_isolated_and_aggregate_merged(
        self,
    ) -> None:
        fixture = json.loads(
            (BASELINE_FIXTURE_DIR / "mixed-runtime-overlay-stale-summary.json").read_text(
                encoding="utf-8"
            )
        )
        with tempfile.TemporaryDirectory() as tmp:
            state_dir = Path(tmp)
            summary_path = state_dir / "summary.json"
            first_env = dict(fixture["first_write_env"])
            first_env["RUNTIME_OVERLAY_STATE_DIR_VALUE"] = str(state_dir)
            self._write_overlay_summary(summary_path, first_env)

            cursor_path = state_dir / "summaries" / "cursor.json"
            self.assertTrue(cursor_path.is_file())
            cursor_summary = json.loads(cursor_path.read_text(encoding="utf-8"))
            self.assertEqual(cursor_summary["runtime"], "cursor")
            self.assertEqual(cursor_summary["tool_access_mode"], "native")

            first_aggregate = json.loads(summary_path.read_text(encoding="utf-8"))
            self.assertEqual(first_aggregate["runtime"], "cursor")
            self.assertEqual(first_aggregate["runtimes_present"], ["cursor"])
            self.assertEqual(first_aggregate["tool_access_mode"], "native")

            second_env = dict(fixture["second_write_env"])
            second_env["RUNTIME_OVERLAY_SUMMARY_RUNTIME_VALUE"] = "opencode"
            second_env["RUNTIME_OVERLAY_STATE_DIR_VALUE"] = str(state_dir)
            self._write_overlay_summary(summary_path, second_env)

            opencode_path = state_dir / "summaries" / "opencode.json"
            self.assertTrue(opencode_path.is_file())
            opencode_summary = json.loads(opencode_path.read_text(encoding="utf-8"))
            self.assertEqual(opencode_summary["runtime"], "opencode")
            self.assertEqual(opencode_summary["tool_access_mode"], "ralph")
            self.assertEqual(opencode_summary["native_hooks_effective"], "false")
            self.assertEqual(opencode_summary["mcp_effective"], "true")
            self.assertEqual(opencode_summary["overlay_mode"], "hybrid")

            cursor_again = json.loads(cursor_path.read_text(encoding="utf-8"))
            self.assertEqual(cursor_again["runtime"], "cursor")
            self.assertEqual(cursor_again["tool_access_mode"], "native")
            self.assertEqual(cursor_again["native_hooks_effective"], "true")
            self.assertEqual(cursor_again["mcp_effective"], "false")
            self.assertEqual(cursor_again["overlay_mode"], "bounded")

            aggregate = json.loads(summary_path.read_text(encoding="utf-8"))
            self.assertEqual(aggregate["plan_key"], fixture["plan_key"])
            self.assertEqual(aggregate["runtimes_present"], ["cursor", "opencode"])
            self.assertEqual(aggregate["runtime"], "opencode")
            self.assertIn("runtime_overlays", aggregate)
            self.assertEqual(
                aggregate["runtime_overlays"]["cursor"]["tool_access_mode"],
                "native",
            )
            self.assertEqual(
                aggregate["runtime_overlays"]["opencode"]["tool_access_mode"],
                "ralph",
            )
            self.assertEqual(
                aggregate["runtime_overlays"]["cursor"]["native_hooks_effective"],
                "true",
            )
            self.assertEqual(
                aggregate["runtime_overlays"]["opencode"]["native_hooks_effective"],
                "false",
            )
            self.assertNotIn("tool_access_mode", aggregate)


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



class TestProcessOwnershipPredicates(unittest.TestCase):
    """Process-supervisor ownership never trusts PID alone."""

    def test_pid_matches_requires_identity(self) -> None:
        import ralph_process_supervisor as supervisor

        identity = "proc-start:current"
        pid = os.getpid()
        # Some locked-down macOS runners prohibit process-table inspection.
        # Exercise the ownership predicate with controlled liveness/identity
        # evidence instead of treating that host restriction as a product bug.
        with (
            mock.patch.object(supervisor, "pid_identity", return_value=identity),
            mock.patch.object(supervisor, "pid_alive", return_value=True),
        ):
            self.assertTrue(supervisor.pid_matches(pid, identity))
            self.assertFalse(supervisor.pid_matches(pid, ""))
            self.assertFalse(supervisor.pid_matches(pid, "wrong-start-id"))
            self.assertFalse(supervisor.pid_matches(0, identity))
            self.assertFalse(supervisor.pid_matches(-1, identity))

    def test_pid_matches_rejects_reused_pid_with_foreign_identity(self) -> None:
        import ralph_process_supervisor as supervisor

        # Live PID with a fabricated prior start id must not match.
        with (
            mock.patch.object(supervisor, "pid_identity", return_value="proc-start:current"),
            mock.patch.object(supervisor, "pid_alive", return_value=True),
        ):
            self.assertFalse(supervisor.pid_matches(os.getpid(), "proc-start:not-this-process"))

    def test_ownership_proof_serialization_never_claims_pid_alone(self) -> None:
        import ralph_process_supervisor as supervisor

        pid = os.getpid()
        identity = "proc-start:current"
        with (
            mock.patch.object(supervisor, "pid_identity", return_value=identity),
            mock.patch.object(supervisor, "pid_alive", return_value=True),
        ):
            empty = supervisor.ownership_proof(pid, "")
            self.assertEqual(empty["pid"], pid)
            self.assertIsNone(empty["identity"])
            self.assertFalse(empty["matches"])
            self.assertTrue(empty["alive"])

            good = supervisor.ownership_proof(pid, identity)
        self.assertTrue(good["matches"])
        self.assertEqual(good["identity"], good["current_identity"])
        # Stable JSON shape for adapters / audit.
        encoded = json.dumps(good, sort_keys=True)
        decoded = json.loads(encoded)
        self.assertEqual(decoded["matches"], True)
        self.assertEqual(decoded["pid"], pid)


if __name__ == "__main__":
    unittest.main()
