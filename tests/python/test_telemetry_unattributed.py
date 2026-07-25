#!/usr/bin/env python3
"""Unit tests for aggregate_telemetry_unattributed in ralph_overlay_usage_fields.py.

Plan-key filtering must be consistent across compact, rewrite, and windowing
logs: mismatched, missing-key, and fallback-key records become diagnostics,
never savings, and headline savings must equal only the positively
attributed event.
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


class TestTelemetryUnattributed(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp_dir = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.tmp_dir, ignore_errors=True)

    def _write(self, filename: str, records: list[dict[str, Any]]) -> None:
        path = self.tmp_dir / filename
        with open(path, "w", encoding="utf-8") as fh:
            for record in records:
                fh.write(json.dumps(record) + "\n")

    def test_compact_log_one_match_one_fallback_one_nested_test(self) -> None:
        self._write("bash-compact.jsonl", [
            {"planKey": "my-plan", "compactionSkipped": False, "originalBytes": 1000, "compactedBytes": 200},
            {"planKey": "bash-hook", "planKeyFallback": True, "compactionSkipped": False,
             "originalBytes": 500, "compactedBytes": 100},
            {"planKey": "my-plan-nested-test", "compactionSkipped": False,
             "originalBytes": 700, "compactedBytes": 50},
        ])

        savings = OVERLAY.aggregate_byte_savings_by_path(str(self.tmp_dir), plan_key="my-plan")
        self.assertEqual(savings["hook_compaction"]["pre_optimization_bytes"], 1000)
        self.assertEqual(savings["hook_compaction"]["post_optimization_bytes"], 200)

        diagnostics = OVERLAY.aggregate_telemetry_unattributed(str(self.tmp_dir), plan_key="my-plan")
        self.assertEqual(len(diagnostics), 2)
        by_key = {(d["logKind"], d["observedKey"]): d for d in diagnostics}
        self.assertIn(("bash_compact", "bash-hook"), by_key)
        self.assertTrue(by_key[("bash_compact", "bash-hook")]["fallback"])
        self.assertEqual(by_key[("bash_compact", "bash-hook")]["count"], 1)
        self.assertEqual(by_key[("bash_compact", "bash-hook")]["bytes"], 500)
        self.assertIn(("bash_compact", "my-plan-nested-test"), by_key)
        self.assertFalse(by_key[("bash_compact", "my-plan-nested-test")]["fallback"])

    def test_result_windowing_one_match_one_fallback_one_nested_test(self) -> None:
        self._write("result-windowing.jsonl", [
            {"planKey": "my-plan", "event": "envelope", "toolName": "Read",
             "originalBytes": 2000, "returnedBytes": 300, "resultId": "a" * 16},
            {"planKey": "bash-hook", "planKeyFallback": True, "event": "envelope", "toolName": "Read",
             "originalBytes": 900, "returnedBytes": 150, "resultId": "b" * 16},
            {"planKey": "my-plan-nested-test", "event": "envelope", "toolName": "Read",
             "originalBytes": 600, "returnedBytes": 60, "resultId": "c" * 16},
        ])

        savings = OVERLAY.aggregate_byte_savings_by_path(str(self.tmp_dir), plan_key="my-plan")
        self.assertEqual(savings["result_windowing"]["pre_optimization_bytes"], 2000)

        diagnostics = OVERLAY.aggregate_telemetry_unattributed(str(self.tmp_dir), plan_key="my-plan")
        self.assertEqual(len(diagnostics), 2)
        log_kinds = {d["logKind"] for d in diagnostics}
        self.assertEqual(log_kinds, {"result_windowing"})

    def test_missing_key_is_grouped_as_missing(self) -> None:
        self._write("bash-compact.jsonl", [
            {"compactionSkipped": False, "originalBytes": 100, "compactedBytes": 10},
        ])
        diagnostics = OVERLAY.aggregate_telemetry_unattributed(str(self.tmp_dir), plan_key="my-plan")
        self.assertEqual(diagnostics[0]["observedKey"], "(missing)")

    def test_no_plan_key_configured_returns_no_diagnostics(self) -> None:
        self._write("bash-compact.jsonl", [
            {"planKey": "anything", "compactionSkipped": False, "originalBytes": 100, "compactedBytes": 10},
        ])
        diagnostics = OVERLAY.aggregate_telemetry_unattributed(str(self.tmp_dir), plan_key="")
        self.assertEqual(diagnostics, [])

    def test_diagnostics_never_appear_in_savings_path_names(self) -> None:
        from tool_call_classification import SAVINGS_PATH_NAMES

        self._write("bash-compact.jsonl", [
            {"planKey": "other-plan", "compactionSkipped": False, "originalBytes": 100, "compactedBytes": 10},
        ])
        savings = OVERLAY.aggregate_byte_savings_by_path(str(self.tmp_dir), plan_key="my-plan")
        for path_name in SAVINGS_PATH_NAMES:
            self.assertEqual(savings[path_name]["pre_optimization_bytes"], 0)


if __name__ == "__main__":
    unittest.main()
