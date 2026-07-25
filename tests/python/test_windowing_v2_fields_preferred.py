#!/usr/bin/env python3
"""Unit tests: aggregate_windowing_savings prefers measurementVersion:2
inline-candidate/delivered fields over legacy originalBytes/returnedBytes
(PLAN15), with legacy records retaining their old numeric output labeled
"legacy_storage_counterfactual".
"""

from __future__ import annotations

import json
import shutil
import tempfile
import unittest
from pathlib import Path
from typing import Any

from ralph_script_loader import load_ralph_script


METRICS = load_ralph_script("result_windowing_metrics")


class TestWindowingV2FieldsPreferred(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp_dir = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.tmp_dir, ignore_errors=True)

    def _write(self, records: list[dict[str, Any]]) -> str:
        path = self.tmp_dir / "result-windowing.jsonl"
        with open(path, "w", encoding="utf-8") as fh:
            for record in records:
                fh.write(json.dumps(record) + "\n")
        return str(path)

    def test_source_captured_bytes_beyond_inline_candidate_do_not_enter_savings(self) -> None:
        # A pathological source capture (originalBytes huge) but the actual
        # inline-eligible candidate was small; v2 fields must drive savings.
        path = self._write([
            {
                "event": "envelope", "toolName": "Grep", "resultId": "a" * 16,
                "measurementVersion": 2,
                "originalBytes": 67000000, "returnedBytes": 6668,
                "sourceCapturedBytes": 67000000,
                "inlineCandidateBytes": 14081, "inlineCandidateTokens": 3520,
                "deliveredBytes": 6668, "deliveredTokens": 1667,
            },
        ])
        result = METRICS.aggregate_windowing_savings(path)
        row = result["per_result"][0]
        self.assertEqual(row["original_bytes"], 14081)
        self.assertNotEqual(row["original_bytes"], 67000000)
        self.assertEqual(row["measurement_quality"], "v2_measured")

    def test_delivered_envelope_overhead_enters_delivered_cost(self) -> None:
        # deliveredBytes (post-envelope-serialization) must be used as the
        # "returned" (post) side, not the smaller preview-only returnedBytes.
        path = self._write([
            {
                "event": "envelope", "toolName": "Read", "resultId": "b" * 16,
                "measurementVersion": 2,
                "originalBytes": 50000, "returnedBytes": 4000,
                "inlineCandidateBytes": 48000, "inlineCandidateTokens": 12000,
                "deliveredBytes": 4900, "deliveredTokens": 1200,
            },
        ])
        result = METRICS.aggregate_windowing_savings(path)
        row = result["per_result"][0]
        self.assertEqual(row["returned_bytes"], 4900)
        self.assertGreater(row["returned_bytes"], 4000)

    def test_readbacks_drive_v2_net_savings_negative(self) -> None:
        path = self._write([
            {
                "event": "envelope", "toolName": "Read", "resultId": "c" * 16,
                "measurementVersion": 2,
                "originalBytes": 50000, "returnedBytes": 4000,
                "inlineCandidateBytes": 48000, "inlineCandidateTokens": 12000,
                "deliveredBytes": 4900, "deliveredTokens": 1200,
            },
            {
                "event": "readback", "toolName": "Read", "resultId": "c" * 16,
                "view": "raw", "returnedBytes": 48000, "returnedTokens": 12000,
            },
        ])
        result = METRICS.aggregate_windowing_savings(path)
        row = result["per_result"][0]
        # The agent paid for the 4,900-byte envelope and then read the full
        # 48,000-byte raw source anyway: 52,900 consumed against a 48,000-byte
        # inline baseline. Windowing cost 4,900 bytes -- exactly the envelope
        # scaffolding -- and net_post_bytes is not capped at the baseline.
        self.assertEqual(row["original_bytes"], 48000)
        self.assertEqual(row["net_post_bytes"], 52900)
        self.assertEqual(
            result["total"]["saved_bytes"], -4900
        )

    def test_legacy_record_retains_old_numeric_output_with_quality_label(self) -> None:
        path = self._write([
            {
                "event": "envelope", "toolName": "Grep", "resultId": "d" * 16,
                "originalBytes": 10000, "returnedBytes": 2000,
                "originalTokens": 2500, "returnedTokens": 500,
            },
        ])
        result = METRICS.aggregate_windowing_savings(path)
        row = result["per_result"][0]
        self.assertEqual(row["original_bytes"], 10000)
        self.assertEqual(row["returned_bytes"], 2000)
        self.assertEqual(row["measurement_quality"], "legacy_storage_counterfactual")

    def test_v2_record_missing_inline_candidate_field_falls_back_to_legacy(self) -> None:
        path = self._write([
            {
                "event": "envelope", "toolName": "Read", "resultId": "e" * 16,
                "measurementVersion": 2,
                "originalBytes": 9000, "returnedBytes": 1500,
                # deliveredBytes present but inlineCandidateBytes missing -> not "has_v2_fields"
                "deliveredBytes": 1600,
            },
        ])
        result = METRICS.aggregate_windowing_savings(path)
        row = result["per_result"][0]
        self.assertEqual(row["measurement_quality"], "legacy_storage_counterfactual")
        self.assertEqual(row["original_bytes"], 9000)


if __name__ == "__main__":
    unittest.main()
