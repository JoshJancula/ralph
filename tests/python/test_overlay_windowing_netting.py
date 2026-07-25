#!/usr/bin/env python3
"""Unit tests for result_windowing readback netting in ralph-overlay-usage-fields.py.

The proxy returns a compacted preview (envelope) but the agent may later
escalate to the raw/full view via ralph_proxy_result_read / _search. Those
re-consumed bytes are logged as event:"readback" records keyed by resultId and
must be subtracted from that result's reported savings so a full raw escalation
collapses the savings to ~0.
"""

from __future__ import annotations

import json
import shutil
import tempfile
import unittest
from pathlib import Path
from typing import Any

from ralph_script_loader import load_ralph_script


OVERLAY = load_ralph_script("ralph_overlay_usage_fields")


class TestWindowingNetting(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp_dir = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.tmp_dir, ignore_errors=True)

    def _write_window_log(self, records: list[dict[str, Any]]) -> str:
        path = self.tmp_dir / "result-windowing.jsonl"
        with open(path, "w", encoding="utf-8") as fh:
            for record in records:
                fh.write(json.dumps(record) + "\n")
        return str(self.tmp_dir)

    def _windowing_bucket(self) -> dict[str, Any]:
        result = OVERLAY.aggregate_byte_savings_by_path(str(self.tmp_dir))
        return result["result_windowing"]

    def test_preview_only_keeps_full_savings(self) -> None:
        self._write_window_log(
            [
                {
                    "event": "envelope",
                    "resultId": "res-1",
                    "originalBytes": 1000,
                    "returnedBytes": 50,
                    "originalTokens": 250,
                    "returnedTokens": 12,
                }
            ]
        )
        bucket = self._windowing_bucket()
        self.assertEqual(bucket["pre_optimization_bytes"], 1000)
        self.assertEqual(bucket["saved_bytes"], 950)
        self.assertEqual(bucket["count"], 1)

    def test_raw_escalation_makes_savings_negative(self) -> None:
        self._write_window_log(
            [
                {
                    "event": "envelope",
                    "resultId": "res-1",
                    "originalBytes": 1000,
                    "returnedBytes": 50,
                    "originalTokens": 250,
                    "returnedTokens": 12,
                },
                {
                    "event": "readback",
                    "resultId": "res-1",
                    "view": "raw",
                    "returnedBytes": 1000,
                    "returnedTokens": 250,
                },
            ]
        )
        bucket = self._windowing_bucket()
        self.assertEqual(bucket["pre_optimization_bytes"], 1000)
        # The agent consumed the 50-byte preview AND then read the full 1000-byte
        # raw source: 1050 against a 1000-byte inline baseline. Windowing lost 50
        # bytes here, and the bucket must report the loss rather than floor at 0.
        self.assertEqual(bucket["saved_bytes"], -50)
        self.assertEqual(bucket["saved_tokens"], -12)

    def test_partial_readback_nets_proportionally(self) -> None:
        self._write_window_log(
            [
                {
                    "event": "envelope",
                    "resultId": "res-1",
                    "originalBytes": 1000,
                    "returnedBytes": 50,
                },
                {
                    "event": "readback",
                    "resultId": "res-1",
                    "view": "compacted",
                    "returnedBytes": 200,
                },
            ]
        )
        bucket = self._windowing_bucket()
        # consumed = 50 + 200 = 250 -> saved 750.
        self.assertEqual(bucket["saved_bytes"], 750)

    def test_readback_for_other_result_does_not_leak(self) -> None:
        self._write_window_log(
            [
                {
                    "event": "envelope",
                    "resultId": "res-1",
                    "originalBytes": 1000,
                    "returnedBytes": 50,
                },
                {
                    "event": "readback",
                    "resultId": "res-2",
                    "view": "raw",
                    "returnedBytes": 1000,
                },
            ]
        )
        bucket = self._windowing_bucket()
        # res-2 has no envelope; res-1 keeps full savings.
        self.assertEqual(bucket["saved_bytes"], 950)

    def test_legacy_record_without_resultid_keeps_per_line_behavior(self) -> None:
        self._write_window_log(
            [
                {
                    "originalBytes": 800,
                    "returnedBytes": 100,
                }
            ]
        )
        bucket = self._windowing_bucket()
        self.assertEqual(bucket["saved_bytes"], 700)

    def test_readback_reason_preserved_in_aggregation(self) -> None:
        self._write_window_log(
            [
                {
                    "event": "envelope",
                    "resultId": "res-reason",
                    "originalBytes": 1000,
                    "returnedBytes": 50,
                },
                {
                    "event": "readback",
                    "resultId": "res-reason",
                    "view": "compacted",
                    "returnedBytes": 200,
                    "reason": "verification",
                },
            ]
        )
        bucket = self._windowing_bucket()
        self.assertEqual(bucket["saved_bytes"], 750)

    def test_merge_overlay_fields_includes_compaction_telemetry(self) -> None:
        compact_path = self.tmp_dir / "bash-compact.jsonl"
        compact_path.write_text(
            json.dumps(
                {
                    "plan_key": "plan-1",
                    "originalBytes": 1200,
                    "compactedBytes": 300,
                    "originalTokens": 240,
                    "compactedTokens": 60,
                }
            )
            + "\n",
            encoding="utf-8",
        )
        summary_path = self.tmp_dir / "summary.json"
        summary_path.write_text(json.dumps({"plan_key": "plan-1"}), encoding="utf-8")

        record: dict[str, Any] = {}
        OVERLAY.merge_overlay_fields(record, str(summary_path))

        telemetry = record["compaction_telemetry"]
        self.assertEqual(telemetry[0]["original_tokens"], 240)
        self.assertEqual(telemetry[0]["compacted_tokens"], 60)
        self.assertEqual(telemetry[0]["saved_tokens"], 180)


class TestChannelAggregation(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp_dir = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.tmp_dir, ignore_errors=True)

    def _write_window_log(self, records: list[dict[str, Any]]) -> None:
        path = self.tmp_dir / "result-windowing.jsonl"
        with open(path, "w", encoding="utf-8") as fh:
            for record in records:
                fh.write(json.dumps(record) + "\n")

    def _channel_savings(self) -> dict[str, Any]:
        return OVERLAY.aggregate_byte_savings_by_channel(str(self.tmp_dir))

    def test_proxy_read_envelope_attributes_to_proxy_read_windowing(self) -> None:
        self._write_window_log(
            [
                {
                    "event": "envelope",
                    "resultId": "res-read",
                    "runtime": "cursor",
                    "channel": "proxy_read_windowing",
                    "originalBytes": 1000,
                    "returnedBytes": 200,
                }
            ]
        )
        channels = self._channel_savings()
        bucket = channels["proxy_read_windowing"]
        self.assertEqual(bucket["saved_bytes"], 800)
        self.assertEqual(bucket["attribution"], "exact")
        self.assertEqual(channels["stored_result_readback"]["saved_bytes"], 0)

    def test_proxy_search_envelope_attributes_to_proxy_search_windowing(self) -> None:
        self._write_window_log(
            [
                {
                    "event": "envelope",
                    "resultId": "res-search",
                    "runtime": "cursor",
                    "channel": "proxy_search_windowing",
                    "originalBytes": 2000,
                    "returnedBytes": 400,
                }
            ]
        )
        bucket = self._channel_savings()["proxy_search_windowing"]
        self.assertEqual(bucket["saved_bytes"], 1600)
        self.assertEqual(bucket["attribution"], "exact")

    def test_native_result_hook_envelope(self) -> None:
        self._write_window_log(
            [
                {
                    "event": "envelope",
                    "resultId": "res-hook",
                    "runtime": "cursor",
                    "channel": "native_result_hook",
                    "originalBytes": 5000,
                    "returnedBytes": 500,
                }
            ]
        )
        bucket = self._channel_savings()["native_result_hook"]
        self.assertEqual(bucket["saved_bytes"], 4500)
        self.assertEqual(bucket["attribution"], "exact")

    def test_native_result_mcp_fallback_envelope(self) -> None:
        self._write_window_log(
            [
                {
                    "event": "envelope",
                    "resultId": "res-fallback",
                    "runtime": "opencode",
                    "channel": "native_result_mcp_fallback",
                    "originalBytes": 8000,
                    "returnedBytes": 800,
                }
            ]
        )
        bucket = self._channel_savings()["native_result_mcp_fallback"]
        self.assertEqual(bucket["saved_bytes"], 7200)
        self.assertEqual(bucket["attribution"], "exact")

    def test_readback_netting_by_source_result_channel(self) -> None:
        self._write_window_log(
            [
                {
                    "event": "envelope",
                    "resultId": "res-net",
                    "runtime": "cursor",
                    "channel": "proxy_read_windowing",
                    "originalBytes": 1000,
                    "returnedBytes": 200,
                },
                {
                    "event": "readback",
                    "resultId": "res-net",
                    "runtime": "cursor",
                    "channel": "stored_result_readback",
                    "sourceResultChannel": "proxy_read_windowing",
                    "view": "compacted",
                    "returnedBytes": 300,
                },
            ]
        )
        channels = self._channel_savings()
        bucket = channels["proxy_read_windowing"]
        self.assertEqual(bucket["saved_bytes"], 500)
        self.assertEqual(bucket["attribution"], "exact")
        self.assertEqual(channels["stored_result_readback"]["saved_bytes"], 0)

    def test_legacy_logs_without_channel_fields_use_stored_result_readback(self) -> None:
        self._write_window_log(
            [
                {
                    "event": "envelope",
                    "resultId": "res-legacy",
                    "originalBytes": 1000,
                    "returnedBytes": 200,
                },
                {
                    "event": "readback",
                    "resultId": "res-legacy",
                    "view": "compacted",
                    "returnedBytes": 100,
                },
            ]
        )
        channels = self._channel_savings()
        bucket = channels["stored_result_readback"]
        self.assertEqual(bucket["saved_bytes"], 700)
        self.assertEqual(bucket["attribution"], "legacy")
        self.assertEqual(channels["proxy_read_windowing"]["saved_bytes"], 0)

    def test_byte_savings_by_path_remains_compatible(self) -> None:
        self._write_window_log(
            [
                {
                    "event": "envelope",
                    "resultId": "res-both",
                    "channel": "proxy_read_windowing",
                    "originalBytes": 1000,
                    "returnedBytes": 100,
                }
            ]
        )
        by_path = OVERLAY.aggregate_byte_savings_by_path(str(self.tmp_dir))
        by_channel = self._channel_savings()
        self.assertEqual(by_path["result_windowing"]["saved_bytes"], 900)
        self.assertEqual(by_channel["proxy_read_windowing"]["saved_bytes"], 900)
        self.assertIn("byte_savings_by_channel", OVERLAY.OVERLAY_USAGE_DEFAULTS)


if __name__ == "__main__":
    unittest.main()
