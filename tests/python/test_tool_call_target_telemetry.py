#!/usr/bin/env python3
"""Unit tests for tool_call_target_telemetry readback analysis."""

from __future__ import annotations

import json
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent.parent.parent / "bundle" / ".ralph" / "python"))

from tool_call_target_telemetry import (  # noqa: E402
    analyze_result_windowing_log,
    optimization_hint_line,
    stored_result_readback_guidance,
)


class TestToolCallTargetTelemetry(unittest.TestCase):
    def test_analyze_result_windowing_log_counts_raw_and_full_rereads(self) -> None:
        lines = [
            {
                "event": "envelope",
                "resultId": "abc123456789abcd",
                "originalBytes": 1000,
                "returnedBytes": 500,
            },
            {
                "event": "readback",
                "resultId": "abc123456789abcd",
                "view": "compacted",
                "returnedBytes": 500,
            },
            {
                "event": "readback",
                "resultId": "def9876543210fed",
                "view": "raw",
                "returnedBytes": 200,
            },
        ]
        with tempfile.NamedTemporaryFile("w", encoding="utf-8", delete=False) as handle:
            for line in lines:
                handle.write(json.dumps(line) + "\n")
            path = handle.name
        try:
            stats = analyze_result_windowing_log(path)
        finally:
            Path(path).unlink(missing_ok=True)

        self.assertEqual(stats["envelope_count"], 1)
        self.assertEqual(stats["readback_count"], 2)
        self.assertEqual(stats["raw_readback_count"], 1)
        self.assertEqual(stats["compacted_readback_count"], 1)
        self.assertEqual(stats["full_preview_rereads"], 1)

    def test_optimization_hint_line_mentions_result_read_without_search(self) -> None:
        usage = {
            "tool_calls_sequence": [
                "ralph_proxy_read",
                "ralph_proxy_result_read",
                "ralph_proxy_result_read",
            ]
        }
        hint = optimization_hint_line(usage)
        self.assertIn("result_read", hint)
        self.assertIn("result_search", hint)

    def test_stored_result_readback_guidance(self) -> None:
        text = stored_result_readback_guidance(
            {
                "full_preview_rereads": 2,
                "raw_readback_count": 3,
                "raw_readback_share": 0.75,
                "readback_count": 4,
            }
        )
        self.assertIn("view=raw", text)
        self.assertIn("result_search", text)
        self.assertIn("avoid full preview re-reads", text)

    def test_stored_result_readback_guidance_without_high_reread_threshold(self) -> None:
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

    def test_readback_reason_counts_are_aggregated(self) -> None:
        lines = [
            {
                "event": "envelope",
                "resultId": "r1",
                "originalBytes": 1000,
                "returnedBytes": 100,
            },
            {
                "event": "readback",
                "resultId": "r1",
                "view": "compacted",
                "returnedBytes": 50,
                "reason": "search_followup",
            },
            {
                "event": "readback",
                "resultId": "r1",
                "view": "raw",
                "returnedBytes": 100,
                "reason": "raw_exactness",
            },
        ]
        with tempfile.NamedTemporaryFile("w", encoding="utf-8", delete=False) as handle:
            for line in lines:
                handle.write(json.dumps(line) + "\n")
            path = handle.name
        try:
            stats = analyze_result_windowing_log(path)
        finally:
            Path(path).unlink(missing_ok=True)

        self.assertEqual(stats["readback_reason_counts"], {
            "search_followup": 1,
            "raw_exactness": 1,
        })

    def test_readback_analysis_stable_when_reason_absent(self) -> None:
        lines = [
            {
                "event": "envelope",
                "resultId": "r1",
                "originalBytes": 1000,
                "returnedBytes": 100,
            },
            {
                "event": "readback",
                "resultId": "r1",
                "view": "compacted",
                "returnedBytes": 50,
            },
        ]
        with tempfile.NamedTemporaryFile("w", encoding="utf-8", delete=False) as handle:
            for line in lines:
                handle.write(json.dumps(line) + "\n")
            path = handle.name
        try:
            stats = analyze_result_windowing_log(path)
        finally:
            Path(path).unlink(missing_ok=True)

        self.assertEqual(stats["readback_count"], 1)
        self.assertEqual(stats["readback_reason_counts"], {})
        self.assertEqual(stats["net_consumed_bytes"], 150)

    def test_readback_negation_rate_can_exceed_one_but_net_savings_zero(self) -> None:
        """Gross readback can exceed original, but net savings is capped at zero.

        With per-resultId netting, preview bytes plus follow-up readback bytes
        are capped at the original envelope bytes before savings are computed.
        Gross readback/original can therefore exceed 1.0 while the effective
        windowing savings rate is exactly 0.
        """
        lines = [
            {
                "event": "envelope",
                "resultId": "r1",
                "originalBytes": 1000,
                "returnedBytes": 100,
            },
            {
                "event": "readback",
                "resultId": "r1",
                "view": "compacted",
                "returnedBytes": 600,
            },
            {
                "event": "readback",
                "resultId": "r1",
                "view": "raw",
                "returnedBytes": 800,
            },
        ]
        with tempfile.NamedTemporaryFile("w", encoding="utf-8", delete=False) as handle:
            for line in lines:
                handle.write(json.dumps(line) + "\n")
            path = handle.name
        try:
            stats = analyze_result_windowing_log(path)
        finally:
            Path(path).unlink(missing_ok=True)

        self.assertGreater(stats["gross_readback_bytes"] / stats["envelope_original_bytes"], 1.0)
        self.assertEqual(stats["net_consumed_bytes"], 1000)
        self.assertEqual(stats["effective_windowing_savings_rate"], 0.0)


if __name__ == "__main__":
    unittest.main()
