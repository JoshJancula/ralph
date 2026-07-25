#!/usr/bin/env python3
"""Unit tests for the cross-runtime tool evaluation harness."""

from __future__ import annotations

import json
import os
import sys
import unittest
from pathlib import Path
from unittest import mock

REPO_ROOT = Path(__file__).resolve().parents[2]
FIXTURE_DIR = REPO_ROOT / "tests" / "fixtures" / "tool-eval"
TASKS_FIXTURE = FIXTURE_DIR / "tasks.json"
TRACES_FIXTURE = FIXTURE_DIR / "offline-traces.json"
BASELINE_FIXTURE = FIXTURE_DIR / "baseline-report.json"

sys.path.insert(0, str(REPO_ROOT / "bundle" / ".ralph" / "python"))

import tool_eval as teval  # noqa: E402


class TestToolEvalTasksFixture(unittest.TestCase):
    def test_fixture_has_at_least_fifteen_tasks(self) -> None:
        payload = json.loads(TASKS_FIXTURE.read_text(encoding="utf-8"))
        tasks = payload.get("tasks") or []
        self.assertGreaterEqual(len(tasks), 15)

    def test_tasks_declare_required_fields(self) -> None:
        payload = json.loads(TASKS_FIXTURE.read_text(encoding="utf-8"))
        categories = set()
        for task in payload.get("tasks") or []:
            teval.validate_task(task)
            categories.add(task.get("category"))
        required_categories = {
            "read",
            "grep",
            "glob",
            "lexical_search",
            "repomap",
            "stored_result",
            "batching",
            "shell_compaction",
            "tool_search",
            "permission_denial",
            "artifact_lookup",
            "catalog_failure",
        }
        self.assertTrue(required_categories.issubset(categories))


class TestToolEvalOfflineHarness(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.scores = teval.run_offline_evaluation(REPO_ROOT, TASKS_FIXTURE, TRACES_FIXTURE)
        cls.baseline = json.loads(BASELINE_FIXTURE.read_text(encoding="utf-8"))

    def test_offline_scores_match_baseline(self) -> None:
        failures = teval.compare_to_baseline(self.scores, self.baseline)
        self.assertEqual(failures, [], msg="\n".join(failures))

    def test_offline_report_is_deterministic(self) -> None:
        text_a = teval.emit_json_report(self.scores, mode="offline")
        text_b = teval.emit_json_report(self.scores, mode="offline")
        self.assertEqual(text_a, text_b)
        payload = json.loads(text_a)
        self.assertEqual(payload["kind"], "tool_eval_report")
        self.assertEqual(payload["mode"], "offline")

    def test_duplicate_read_task_records_waste(self) -> None:
        by_id = {score.task_id: score for score in self.scores}
        dup = by_id["duplicate-read-penalty"]
        self.assertGreaterEqual(dup.duplicate_reads, 2)
        self.assertGreaterEqual(dup.tool_calls, 3)

    def test_serial_batch_opportunity_is_flagged(self) -> None:
        by_id = {score.task_id: score for score in self.scores}
        serial = by_id["serial-batch-opportunity"]
        self.assertGreaterEqual(serial.batchable_serial_calls, 1)

    def test_catalog_failure_detection_tasks(self) -> None:
        by_id = {score.task_id: score for score in self.scores}
        self.assertIn("missing_tool_catalog", by_id["catalog-missing"].catalog_discovery_failures)
        self.assertIn(
            "next_cursor_null_tool_drop",
            by_id["next-cursor-null"].catalog_discovery_failures,
        )
        self.assertIn(
            "excessive_shell_status_polling",
            by_id["shell-status-polling"].catalog_discovery_failures,
        )
        self.assertIn(
            "failed_discovery_dispatch",
            by_id["discovery-dispatch-fail"].catalog_discovery_failures,
        )


class TestToolEvalCatalogHelpers(unittest.TestCase):
    def test_validate_mcp_tools_list_empty_catalog(self) -> None:
        failures = teval.validate_mcp_tools_list({"tools": []})
        self.assertEqual(failures, ["missing_tool_catalog"])

    def test_validate_mcp_tools_list_null_next_cursor(self) -> None:
        failures = teval.validate_mcp_tools_list(
            {"tools": [{"name": "ralph_proxy_read"}], "nextCursor": None}
        )
        self.assertIn("next_cursor_null_tool_drop", failures)

    def test_validate_mcp_tools_list_missing_required_tool(self) -> None:
        failures = teval.validate_mcp_tools_list({"tools": [{"name": "ralph_proxy_read"}]})
        self.assertTrue(any(item.startswith("missing_required_tool:") for item in failures))


class TestToolEvalErgonomics(unittest.TestCase):
    def test_valid_ergonomics_payload(self) -> None:
        payload = {
            "naming": "clear",
            "parameters": "documented",
            "error_messages": "actionable",
            "missing_tools": "none",
        }
        self.assertTrue(teval.validate_ergonomics(payload))

    def test_invalid_ergonomics_payload(self) -> None:
        self.assertFalse(teval.validate_ergonomics({"naming": "only one field"}))

    def test_offline_ergonomics_does_not_gate_ci(self) -> None:
        trace = json.loads(TRACES_FIXTURE.read_text(encoding="utf-8"))["traces"]["read-basic"]
        trace = dict(trace)
        trace["ergonomics"] = {"naming": "bad"}
        task = next(
            item
            for item in json.loads(TASKS_FIXTURE.read_text(encoding="utf-8"))["tasks"]
            if item["id"] == "read-basic"
        )
        score = teval.score_task(task, trace)
        self.assertFalse(score.ergonomics_valid)
        self.assertEqual(score.accuracy, 1.0)


class TestToolEvalLiveMode(unittest.TestCase):
    def test_live_mode_disabled_without_env(self) -> None:
        with mock.patch.dict(os.environ, {}, clear=True):
            self.assertFalse(teval.is_live_mode_enabled())
        with self.assertRaises(teval.ToolEvalError):
            teval.run_live_evaluation(REPO_ROOT, TASKS_FIXTURE, runtimes=["cursor"], task_ids=["read-basic"])

    def test_live_mode_blocked_in_ci_by_default(self) -> None:
        env = {"RALPH_TOOL_EVAL": "live", "CI": "true"}
        with mock.patch.dict(os.environ, env, clear=True):
            with self.assertRaises(teval.ToolEvalError) as ctx:
                teval.run_live_evaluation(
                    REPO_ROOT,
                    TASKS_FIXTURE,
                    runtimes=["cursor"],
                    task_ids=["read-basic"],
                )
            self.assertIn("disabled in CI", str(ctx.exception))

    def test_live_output_dir_is_under_state_root(self) -> None:
        path = teval._tool_eval_output_dir(REPO_ROOT)
        self.assertTrue(str(path).endswith(".ralph-workspace/tool-eval"))


class TestToolEvalDiscoverReuse(unittest.TestCase):
    def test_score_task_uses_discover_report_patterns(self) -> None:
        task = {
            "id": "discover-pattern-probe",
            "category": "read",
            "prompt": "probe",
            "fixture": "tests/fixtures/tool-eval/workspace",
            "expected": {},
            "max_tool_calls": 5,
            "timeout_seconds": 10,
            "scoring_method": "deterministic_match",
            "mutation_permitted": False,
        }
        trace = {
            "completed": True,
            "output": "",
            "duration_ms": 100,
            "tool_calls_total": 2,
            "tool_calls_sequence": ["grep", "read_file"],
            "tool_calls_by_tool": {"grep": 1, "read_file": 1},
            "tool_durations_ms": {"grep": 40, "read_file": 60},
            "tool_call_targets": [],
        }
        score = teval.score_task(task, trace)
        self.assertIn("native_read_after_grep", score.discover_pattern_ids)


if __name__ == "__main__":
    unittest.main()
