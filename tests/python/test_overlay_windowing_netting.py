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


OVERLAY = load_ralph_script("ralph-overlay-usage-fields")


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

    def test_raw_escalation_collapses_savings(self) -> None:
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
        # consumed = 50 preview + 1000 raw, capped at original 1000 -> saved 0.
        self.assertEqual(bucket["saved_bytes"], 0)
        self.assertEqual(bucket["saved_tokens"], 0)

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


if __name__ == "__main__":
    unittest.main()
