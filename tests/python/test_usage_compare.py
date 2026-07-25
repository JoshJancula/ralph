#!/usr/bin/env python3
"""Unit tests for scripts/usage-compare.py."""

from __future__ import annotations

import io
import json
import sys
import tempfile
import unittest
from contextlib import redirect_stdout
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))

from ralph_script_loader import load_script_by_path

REPO_ROOT = Path(__file__).resolve().parents[2]
USAGE_COMPARE = load_script_by_path(REPO_ROOT / "scripts" / "usage-compare.py")

# Inline invocation-usage.json fixtures (stdlib dicts, no external files).
BASELINE_INVOCATION: dict = {
    "runtime": "claude",
    "iteration": 1,
    "input_tokens": 100,
    "cache_creation_input_tokens": 0,
    "cache_read_input_tokens": 1_000_000,
    "output_tokens": 50,
    "tool_turns": 10,
    "tool_calls_total": 100,
    "byte_savings_by_path": {
        "pre_tool_rewrite": {
            "count": 5,
            "saved_bytes": 1000,
            "hidden_from_context": 500,
        },
        "hook_compaction": {
            "count": 2,
            "saved_bytes": 200,
            "hidden_from_context": 100,
        },
        "proxy_shell_compaction": {
            "count": 1,
            "saved_bytes": 50,
            "hidden_from_context": 25,
        },
    },
}

CANDIDATE_SIMILAR_TOOL_CALLS: dict = {
    "runtime": "claude",
    "iteration": 1,
    "input_tokens": 100,
    "cache_creation_input_tokens": 0,
    "cache_read_input_tokens": 500_000,
    "output_tokens": 50,
    "tool_turns": 10,
    "tool_calls_total": 105,
    "byte_savings_by_path": {
        "pre_tool_rewrite": {
            "count": 8,
            "saved_bytes": 1500,
            "hidden_from_context": 800,
        },
        "hook_compaction": {
            "count": 3,
            "saved_bytes": 300,
            "hidden_from_context": 150,
        },
    },
}

CANDIDATE_LARGE_TOOL_CALLS_GAP: dict = {
    "runtime": "claude",
    "iteration": 1,
    "input_tokens": 100,
    "cache_creation_input_tokens": 0,
    "cache_read_input_tokens": 500_000,
    "output_tokens": 50,
    "tool_turns": 10,
    "tool_calls_total": 150,
}


def _usage_payload(*invocations: dict) -> dict:
    return {"invocations": list(invocations)}


def _rows_by_metric(rows: list[dict]) -> dict[str, dict]:
    return {row["metric"]: row for row in rows}


class TestTokenDeltas(unittest.TestCase):
    def test_token_metric_deltas(self) -> None:
        rows = USAGE_COMPARE.compute_token_deltas(
            BASELINE_INVOCATION,
            CANDIDATE_SIMILAR_TOOL_CALLS,
        )
        by_metric = _rows_by_metric(rows)

        self.assertEqual(by_metric["input_tokens"]["delta"], 0)
        self.assertEqual(by_metric["input_tokens"]["pct_change"], "0.0%")
        self.assertEqual(by_metric["cache_read_input_tokens"]["delta"], -500_000)
        self.assertEqual(by_metric["cache_read_input_tokens"]["pct_change"], "-50.0%")
        self.assertEqual(by_metric["output_tokens"]["delta"], 0)
        self.assertEqual(by_metric["tool_turns"]["delta"], 0)
        self.assertEqual(by_metric["tool_calls_total"]["delta"], 5)
        self.assertEqual(by_metric["tool_calls_total"]["pct_change"], "+5.0%")

    def test_derived_metric_deltas(self) -> None:
        rows = USAGE_COMPARE.compute_token_deltas(
            BASELINE_INVOCATION,
            CANDIDATE_SIMILAR_TOOL_CALLS,
        )
        by_metric = _rows_by_metric(rows)

        self.assertAlmostEqual(
            by_metric["tool_turns/tool_calls_total"]["baseline"],
            0.1,
        )
        self.assertAlmostEqual(
            by_metric["tool_turns/tool_calls_total"]["candidate"],
            10 / 105,
        )
        self.assertAlmostEqual(
            by_metric["tool_turns/tool_calls_total"]["delta"],
            (10 / 105) - 0.1,
        )
        self.assertAlmostEqual(
            by_metric["cache_read_per_tool_turn"]["baseline"],
            100_000.0,
        )
        self.assertAlmostEqual(
            by_metric["cache_read_per_tool_turn"]["candidate"],
            50_000.0,
        )
        self.assertAlmostEqual(
            by_metric["cache_read_per_tool_turn"]["delta"],
            -50_000.0,
        )


class TestByteSavingsDeltas(unittest.TestCase):
    def test_byte_savings_deltas_with_missing_bucket(self) -> None:
        rows = USAGE_COMPARE.compute_byte_savings_deltas(
            BASELINE_INVOCATION,
            CANDIDATE_SIMILAR_TOOL_CALLS,
        )
        by_metric = _rows_by_metric(rows)

        self.assertEqual(len(rows), len(USAGE_COMPARE.BYTE_SAVINGS_BUCKETS) * 3)
        self.assertEqual(by_metric["pre_tool_rewrite.count"]["delta"], 3)
        self.assertEqual(by_metric["pre_tool_rewrite.saved_bytes"]["delta"], 500)
        self.assertEqual(by_metric["hook_compaction.hidden_from_context"]["delta"], 50)
        self.assertEqual(by_metric["proxy_shell_compaction.count"]["baseline"], 1)
        self.assertEqual(by_metric["proxy_shell_compaction.count"]["candidate"], 0)
        self.assertEqual(by_metric["proxy_shell_compaction.count"]["delta"], -1)
        self.assertEqual(by_metric["result_windowing.count"]["baseline"], 0)
        self.assertEqual(by_metric["result_windowing.count"]["candidate"], 0)
        self.assertEqual(by_metric["result_windowing.saved_bytes"]["delta"], 0)


class TestVerdict(unittest.TestCase):
    def test_candidate_wins_without_warning(self) -> None:
        verdict = USAGE_COMPARE.compute_verdict(
            BASELINE_INVOCATION,
            CANDIDATE_SIMILAR_TOOL_CALLS,
        )
        line = USAGE_COMPARE.format_verdict_line(verdict)

        self.assertEqual(verdict["winner"], "candidate")
        self.assertFalse(verdict["warning"])
        self.assertAlmostEqual(verdict["tool_calls_gap_pct"], 5.0)
        self.assertEqual(line, "verdict: candidate used fewer cache_read tokens")

    def test_warning_when_tool_calls_gap_exceeds_20_percent(self) -> None:
        verdict = USAGE_COMPARE.compute_verdict(
            BASELINE_INVOCATION,
            CANDIDATE_LARGE_TOOL_CALLS_GAP,
        )
        line = USAGE_COMPARE.format_verdict_line(verdict)

        self.assertEqual(verdict["winner"], "candidate")
        self.assertTrue(verdict["warning"])
        self.assertAlmostEqual(verdict["tool_calls_gap_pct"], 50.0)
        self.assertEqual(
            line,
            "verdict: candidate used fewer cache_read tokens; "
            "WARNING: tool_calls_total differs by 50.0% (not apples-to-apples)",
        )

    def test_exactly_20_percent_gap_does_not_warn(self) -> None:
        candidate = dict(CANDIDATE_SIMILAR_TOOL_CALLS)
        candidate["tool_calls_total"] = 120
        verdict = USAGE_COMPARE.compute_verdict(BASELINE_INVOCATION, candidate)

        self.assertAlmostEqual(verdict["tool_calls_gap_pct"], 20.0)
        self.assertFalse(verdict["warning"])


class TestMainIntegration(unittest.TestCase):
    def test_main_json_output_uses_inline_fixtures(self) -> None:
        baseline_payload = _usage_payload(BASELINE_INVOCATION)
        candidate_payload = _usage_payload(CANDIDATE_LARGE_TOOL_CALLS_GAP)

        with tempfile.TemporaryDirectory() as tmpdir:
            tmp = Path(tmpdir)
            baseline_path = tmp / "baseline.json"
            candidate_path = tmp / "candidate.json"
            baseline_path.write_text(
                json.dumps(baseline_payload),
                encoding="utf-8",
            )
            candidate_path.write_text(
                json.dumps(candidate_payload),
                encoding="utf-8",
            )

            buffer = io.StringIO()
            with redirect_stdout(buffer):
                exit_code = USAGE_COMPARE.main(
                    [str(baseline_path), str(candidate_path), "--json"],
                )

            self.assertEqual(exit_code, 0)
            summary = json.loads(buffer.getvalue().strip())
            self.assertEqual(summary["status"], "loaded OK")
            self.assertTrue(summary["verdict"]["warning"])
            self.assertIn("WARNING", summary["verdict_line"])
            self.assertEqual(
                summary["byte_savings_deltas"][0]["metric"],
                "pre_tool_rewrite.count",
            )


if __name__ == "__main__":
    unittest.main()
