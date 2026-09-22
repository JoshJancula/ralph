#!/usr/bin/env python3
"""Unit tests for jev_usage aggregation and jev_client.record_usage."""

from __future__ import annotations

import json
import os
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

REPO_ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO_ROOT / "bundle" / ".ralph" / "python"))

import jev_client  # noqa: E402
import jev_usage  # noqa: E402


def _rec(**overrides: object) -> dict:
    base = {
        "timestamp": "2026-09-21T00:00:00Z",
        "model": "jev-1.13.0",
        "questionSetId": "graph.router-confidence",
        "input_tokens": 296,
        "output_tokens": 20,
        "usageSource": "measured",
        "transport": "https",
        "planKey": "plan-a",
    }
    base.update(overrides)
    return base


class TestAggregate(unittest.TestCase):
    def test_sums_tokens_and_groups_by_question_set_and_model(self) -> None:
        out = jev_usage.aggregate(
            [
                _rec(),
                _rec(input_tokens=100, output_tokens=5),
                _rec(questionSetId="compaction.line-relevance", model="jev-1.14.0"),
            ]
        )
        self.assertEqual(out["calls"], 3)
        self.assertEqual(out["input_tokens"], 692)
        self.assertEqual(out["output_tokens"], 45)
        self.assertEqual(out["by_question_set"]["graph.router-confidence"]["calls"], 2)
        self.assertEqual(out["by_model"]["jev-1.14.0"]["calls"], 1)

    def test_unavailable_usage_is_counted_separately_not_as_measured(self) -> None:
        out = jev_usage.aggregate(
            [_rec(), _rec(input_tokens=0, output_tokens=0, usageSource="unavailable")]
        )
        self.assertEqual(out["calls_measured"], 1)
        self.assertEqual(out["calls_unavailable"], 1)

    def test_fixture_transport_excluded_unless_requested(self) -> None:
        recs = [_rec(), _rec(transport="fixture")]
        self.assertEqual(jev_usage.aggregate(recs)["calls"], 1)
        self.assertEqual(jev_usage.aggregate(recs, include_fixture=True)["calls"], 2)

    def test_plan_key_filter(self) -> None:
        recs = [_rec(planKey="plan-a"), _rec(planKey="plan-b")]
        self.assertEqual(jev_usage.aggregate(recs, plan_key="plan-b")["calls"], 1)

    def test_malformed_numbers_do_not_crash_or_go_negative(self) -> None:
        out = jev_usage.aggregate(
            [
                _rec(input_tokens="x", output_tokens=-5),
                _rec(input_tokens=True, output_tokens=None),
            ]
        )
        self.assertEqual(out["input_tokens"], 0)
        self.assertEqual(out["output_tokens"], 0)

    def test_cost_defaults_price_input_only_because_output_is_free(self) -> None:
        with mock.patch.dict(os.environ, {}, clear=False):
            os.environ.pop("RALPH_JEV_INPUT_USD_PER_MTOK", None)
            os.environ.pop("RALPH_JEV_OUTPUT_USD_PER_MTOK", None)
            out = jev_usage.aggregate([_rec(input_tokens=1_000_000, output_tokens=1_000_000)])
        self.assertAlmostEqual(out["cost"]["estimated_usd"], 0.042)
        self.assertEqual(out["cost"]["output_rate_usd_per_mtok"], 0.0)
        self.assertEqual(out["cost"]["note"], "estimated")

    def test_output_rate_env_adds_output_cost(self) -> None:
        env = {"RALPH_JEV_INPUT_USD_PER_MTOK": "1", "RALPH_JEV_OUTPUT_USD_PER_MTOK": "2"}
        with mock.patch.dict(os.environ, env):
            out = jev_usage.aggregate([_rec(input_tokens=1_000_000, output_tokens=1_000_000)])
        self.assertAlmostEqual(out["cost"]["estimated_usd"], 3.0)

    def test_empty_has_no_cost(self) -> None:
        self.assertIsNone(jev_usage.aggregate([])["cost"])

    def test_read_records_skips_bad_lines_and_missing_file(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            path = os.path.join(tmp, "usage.jsonl")
            with open(path, "w", encoding="utf-8") as fh:
                fh.write(json.dumps(_rec()) + "\n\nnot json\n[1,2]\n")
            self.assertEqual(len(list(jev_usage.read_records(path))), 1)
            self.assertEqual(list(jev_usage.read_records(path + ".missing")), [])


class TestRecordUsage(unittest.TestCase):
    def _run(self, response: dict) -> list[dict]:
        with tempfile.TemporaryDirectory() as tmp:
            env = {
                "RALPH_JEV_STATE_DIR": tmp,
                "JEV_TRANSPORT": "https",
                "RALPH_PLAN_KEY": "plan-x",
            }
            with mock.patch.dict(os.environ, env):
                os.environ.pop("RALPH_ARTIFACT_NS", None)
                jev_client.record_usage({"questionSetId": "qs.one"}, response)
            return list(jev_usage.read_records(os.path.join(tmp, "usage.jsonl")))

    def test_records_measured_usage_from_response(self) -> None:
        (rec,) = self._run(
            {"model": "jev-1.13.0", "answers": {}, "usage": {"input_tokens": 296, "output_tokens": 20}}
        )
        self.assertEqual(rec["input_tokens"], 296)
        self.assertEqual(rec["output_tokens"], 20)
        self.assertEqual(rec["usageSource"], "measured")
        self.assertEqual(rec["questionSetId"], "qs.one")
        self.assertEqual(rec["model"], "jev-1.13.0")
        self.assertEqual(rec["planKey"], "plan-x")

    def test_missing_usage_is_marked_unavailable_not_zero_measured(self) -> None:
        (rec,) = self._run({"model": "jev-1.13.0", "answers": {}})
        self.assertEqual(rec["usageSource"], "unavailable")
        self.assertEqual(rec["input_tokens"], 0)

    def test_alias_model_is_not_recorded(self) -> None:
        (rec,) = self._run({"model": "jev-latest", "answers": {}, "usage": {"input_tokens": 1}})
        self.assertEqual(rec["model"], "")


if __name__ == "__main__":
    unittest.main()
