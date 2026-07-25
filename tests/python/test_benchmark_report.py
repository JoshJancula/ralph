#!/usr/bin/env python3
"""Unit tests for ralph-benchmark-report.py."""

from __future__ import annotations

import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from typing import Any

from ralph_script_loader import load_ralph_script


REPO_ROOT = Path(__file__).resolve().parents[2]
BASELINE_FIXTURE_DIR = REPO_ROOT / "tests" / "fixtures" / "benchmark-channel-attribution"
OVERLAY_WRITE_SCRIPT = REPO_ROOT / "bundle" / ".ralph" / "python" / "runtime-overlay-write-summary.py"
OVERLAY_FIELDS_SCRIPT = REPO_ROOT / "bundle" / ".ralph" / "python" / "ralph_overlay_usage_fields.py"

SAVINGS_REPORT = load_ralph_script("ralph-benchmark-report")
DISCOVER_REPORT = load_ralph_script("ralph-discover-report")
OVERLAY_FIELDS = load_ralph_script("ralph_overlay_usage_fields")
RENDER_MARKDOWN = load_ralph_script("render-benchmark-markdown")

E2E_FIXTURE_DIR = BASELINE_FIXTURE_DIR / "e2e"
E2E_MANIFEST = E2E_FIXTURE_DIR / "manifest.json"


class TestSavingsReport(unittest.TestCase):
    """Verify savings report aggregation and guarding behavior."""

    def setUp(self) -> None:
        self.tmp_dir = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.tmp_dir, ignore_errors=True)
        self.report_module = SAVINGS_REPORT
        self.estimate_tokens = self.report_module.estimate_tokens

    def _write_json(self, target: Path, payload: Any) -> None:
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(json.dumps(payload), encoding="utf-8")

    def _write_summary(self, directory: Path, summary: dict[str, Any]) -> Path:
        summary_path = directory / "plan-usage-summary.json"
        self._write_json(summary_path, summary)
        return summary_path

    def _write_invocation(self, summary_path: Path, invocations: list[dict[str, Any]]) -> Path:
        invocation_path = summary_path.parent / "invocation-usage.json"
        self._write_json(invocation_path, {"invocations": invocations})
        return invocation_path

    def _load_baseline_fixture(self, name: str) -> dict[str, Any]:
        return json.loads((BASELINE_FIXTURE_DIR / name).read_text(encoding="utf-8"))

    def _assert_no_pricing_fields(self, value: Any) -> None:
        if isinstance(value, dict):
            for key, nested in value.items():
                lowered = key.lower()
                self.assertNotIn("pricing", lowered)
                self.assertNotIn("dollar", lowered)
                self._assert_no_pricing_fields(nested)
        elif isinstance(value, list):
            for item in value:
                self._assert_no_pricing_fields(item)

    def test_estimate_tokens_from_bytes_uses_constant_time_formula(self) -> None:
        original_estimate_tokens = self.report_module.estimate_tokens

        def fail_if_called(_: str) -> int:
            raise AssertionError("estimate_tokens() should not be called here")

        self.report_module.estimate_tokens = fail_if_called
        self.addCleanup(setattr, self.report_module, "estimate_tokens", original_estimate_tokens)

        byte_count = 1_000_003
        self.assertEqual(
            self.report_module._estimate_tokens_from_bytes(byte_count),
            max(1, (byte_count + 3) // 4),
        )

    def test_normalize_optimization_opportunities_deduplicates_missed_entries(self) -> None:
        discover = {
            "missed_compaction_opportunities": [
                {"original_bytes": 5000, "skip_reason": "native shell output not compacted"},
                {"original_bytes": 5000, "skip_reason": "native shell output not compacted"},
                {"original_bytes": 4000, "skip_reason": "low savings due to proxy limits"},
            ],
            "sequence_patterns": [{"pattern_id": "p1"}],
        }

        normalized = self.report_module._normalize_optimization_opportunities(discover)
        self.assertIsNotNone(normalized)
        missed = normalized["missed_compaction_opportunities"]
        self.assertEqual(len(missed), 2)
        self.assertEqual(missed[0]["skip_reason"], "native shell output not compacted")
        self.assertEqual(missed[1]["skip_reason"], "low savings due to proxy limits")

    def test_build_report_aggregates_paths_and_tokens(self) -> None:
        paths_dir = self.tmp_dir / "with_paths"
        summary_with_paths = {
            "invocations": 3,
            "input_tokens": 10,
            "cache_creation_input_tokens": 4,
            "cache_read_input_tokens": 6,
            "compaction_measured_not_applied_bytes": 13,
            "started_at": "2026-01-01T00:00:00Z",
            "ended_at": "2026-01-01T00:10:00Z",
            "byte_savings_by_path": {
                "pre_tool_rewrite": {
                    "pre_optimization_bytes": 100,
                    "post_optimization_bytes": 60,
                    "saved_bytes": 40,
                    "pre_optimization_tokens": 16,
                    "post_optimization_tokens": 10,
                    "saved_tokens": 6,
                    "count": 1,
                    "token_cap_triggers": 0,
                },
                "hook_compaction": {
                    "pre_optimization_bytes": 200,
                    "post_optimization_bytes": 150,
                    "saved_bytes": 50,
                    "pre_optimization_tokens": 40,
                    "post_optimization_tokens": 30,
                    "saved_tokens": 10,
                    "count": 1,
                    "token_cap_triggers": 1,
                },
            },
        }
        summary_path = self._write_summary(paths_dir, summary_with_paths)

        compaction_dir = self.tmp_dir / "with_compaction"
        summary_without_paths = {
            "invocations": 1,
            "input_tokens": 3,
            "cache_creation_input_tokens": 2,
            "cache_read_input_tokens": 4,
            "compaction_measured_not_applied_bytes": 0,
            "started_at": "2026-01-01T00:05:00Z",
            "ended_at": "2026-01-01T00:06:00Z",
        }
        compaction_summary_path = self._write_summary(compaction_dir, summary_without_paths)

        original_bytes = 120
        compacted_bytes = 80
        invocation = {
            "plan_key": "plan",
            "stage_id": "stage1",
            "iteration": 1,
            "compaction_telemetry": [
                {
                    "family": "proxy",
                    "originalBytes": original_bytes,
                    "compactedBytes": compacted_bytes,
                    "originalTokens": 0,
                    "compactedTokens": 0,
                }
            ],
        }
        self._write_invocation(compaction_summary_path, [invocation])

        report = self.report_module.build_report(
            [str(summary_path), str(compaction_summary_path)]
        )

        expected_original_tokens = self.estimate_tokens("x" * original_bytes)
        expected_compacted_tokens = self.estimate_tokens("x" * compacted_bytes)
        expected_proxy_saved_tokens = max(0, expected_original_tokens - expected_compacted_tokens)

        self.assertEqual(report["run_count"], 4)
        self.assertEqual(report["saved_bytes"], 130)
        self.assertEqual(report["could_have_saved"]["compaction_measured_not_applied_bytes"], 13)
        self.assertEqual(report["cache"]["cache_read_tokens"], 10)
        self.assertEqual(report["cache"]["cache_hit_ratio"], round(10 / 29, 4))

        per_path = report["per_path"]
        self.assertEqual(per_path["pre_tool_rewrite"]["saved_bytes"], 40)
        self.assertEqual(per_path["hook_compaction"]["token_cap_triggers"], 1)
        self.assertGreater(per_path["proxy_shell_compaction"]["saved_bytes"], 0)
        self.assertEqual(per_path["proxy_shell_compaction"]["saved_bytes"], original_bytes - compacted_bytes)
        self.assertEqual(
            per_path["proxy_shell_compaction"]["pre_optimization_tokens"], expected_original_tokens
        )
        self.assertEqual(
            per_path["proxy_shell_compaction"]["post_optimization_tokens"], expected_compacted_tokens
        )
        self.assertEqual(
            per_path["proxy_shell_compaction"]["saved_tokens"], expected_proxy_saved_tokens
        )
        self.assertEqual(
            per_path["proxy_shell_compaction"]["savings_percent"],
            round((original_bytes - compacted_bytes) / original_bytes * 100, 1),
        )
        self.assertEqual(per_path["result_windowing"]["saved_bytes"], 0)

        self.assertEqual(
            report["saved_tokens"],
            16 + expected_proxy_saved_tokens,
        )
        self.assertEqual(
            report["savings_percent"],
            round(130 / (300 + original_bytes) * 100, 1),
        )

        runs = report["runs"]
        self.assertEqual(report["runs_count"], len(runs))
        self.assertEqual(len(runs), 2)
        for run in runs:
            self.assertIn("saved_bytes", run)
            self.assertIn("saved_tokens", run)
            self.assertIn("pre_optimization_bytes", run)
            self.assertIn("savings_percent", run)

        run_with_paths = runs[0]
        self.assertEqual(run_with_paths["id"], "with_paths")
        self.assertEqual(run_with_paths["saved_bytes"], 90)
        self.assertEqual(run_with_paths["saved_tokens"], 16)
        self.assertEqual(run_with_paths["pre_optimization_bytes"], 300)
        self.assertEqual(run_with_paths["savings_percent"], 30.0)

        run_with_compaction = runs[1]
        self.assertEqual(run_with_compaction["id"], "with_compaction")
        self.assertEqual(run_with_compaction["saved_bytes"], original_bytes - compacted_bytes)
        self.assertEqual(run_with_compaction["saved_tokens"], expected_proxy_saved_tokens)
        self.assertEqual(run_with_compaction["pre_optimization_bytes"], original_bytes)
        self.assertEqual(
            run_with_compaction["savings_percent"],
            round((original_bytes - compacted_bytes) / original_bytes * 100, 1),
        )

        self._assert_no_pricing_fields(report)

        # schema v2 exposes session usage aggregated from plan-usage-summary.json.
        self.assertEqual(report["schema_version"], 2)
        self.assertIn("session_usage", report)
        self.assertEqual(report["session_usage"]["input_tokens"], 13)
        self.assertEqual(report["session_usage"]["output_tokens"], 0)
        self.assertEqual(
            report["session_usage"]["cache_creation_input_tokens"], 6
        )
        self.assertEqual(report["session_usage"]["cache_read_input_tokens"], 10)
        # Summaries in this test do not set tool_calls_total, so the aggregate is 0.
        self.assertEqual(report["session_usage"]["tool_calls_total"], 0)

        # tool_output_counterfactual covers with-vs-without-Ralph estimates.
        self.assertIn("tool_output_counterfactual", report)
        counterfactual = report["tool_output_counterfactual"]
        self.assertIn("hypothetical_without_ralph_bytes", counterfactual)
        self.assertIn("actual_with_ralph_bytes", counterfactual)
        self.assertIn("net_savings_bytes", counterfactual)
        self.assertIn("hypothetical_without_ralph_tokens", counterfactual)
        self.assertIn("actual_with_ralph_tokens", counterfactual)
        self.assertIn("net_savings_tokens", counterfactual)
        self.assertIn("net_savings_percent", counterfactual)
        self.assertEqual(
            counterfactual["compaction_measured_not_applied_bytes"], 13
        )

        # effective_windowing_savings_rate is present as the decision-grade
        # signal; gross readback_negation_rate remains as a diagnostic only.
        self.assertIn("effective_windowing_savings_rate", report["readback_summary"])
        self.assertIn("gross_readback_bytes", report["readback_summary"])
        self.assertIn("net_consumed_bytes", report["readback_summary"])

        # Per-path rows carry pre/post bytes/tokens and diagnostics.
        for path_name in ("pre_tool_rewrite", "hook_compaction",
                          "proxy_shell_compaction", "result_windowing"):
            bucket = report["per_path"][path_name]
            self.assertIn("pre_optimization_bytes", bucket)
            self.assertIn("post_optimization_bytes", bucket)
            self.assertIn("pre_optimization_tokens", bucket)
            self.assertIn("post_optimization_tokens", bucket)

        self.assertIn("gross_hidden_bytes", report["per_path"]["hook_compaction"])
        self.assertIn(
            "compaction_measured_not_applied_bytes",
            report["per_path"]["proxy_shell_compaction"],
        )

    def test_cumulative_invocation_snapshots_use_latest_value(self) -> None:
        """Per-invocation byte_savings_by_path are cumulative running totals.

        The aggregator must keep the latest snapshot per path, not the largest
        or the sum. Result-windowing savings can drop when an agent later reads
        the raw/full stored result.
        """
        run_dir = self.tmp_dir / "cumulative"
        summary = {
            "invocations": 3,
            "started_at": "2026-02-01T00:00:00Z",
            "ended_at": "2026-02-01T00:30:00Z",
        }
        summary_path = self._write_summary(run_dir, summary)

        def _window_bucket(saved: int) -> dict[str, Any]:
            return {
                "pre_optimization_bytes": saved + 1000,
                "post_optimization_bytes": 1000,
                "saved_bytes": saved,
                "pre_optimization_tokens": 0,
                "post_optimization_tokens": 0,
                "saved_tokens": 0,
                "count": 1,
                "token_cap_triggers": 0,
                "hidden_from_context": saved,
                "hidden_from_context_tokens": 0,
            }

        # Cumulative snapshots: 10k, then 25k, then 0 after raw readback.
        invocations = [
            {"plan_key": "plan", "iteration": i + 1,
             "byte_savings_by_path": {"result_windowing": _window_bucket(saved)}}
            for i, saved in enumerate((10_000, 25_000, 0))
        ]
        self._write_invocation(summary_path, invocations)

        report = self.report_module.build_report([str(summary_path)])

        self.assertEqual(report["per_path"]["result_windowing"]["saved_bytes"], 0)
        self.assertEqual(report["saved_bytes"], 0)
        self.assertEqual(report["runs"][0]["saved_bytes"], 0)
        self.assertEqual(report["skipped_summaries"], 0)

    def test_skipped_summaries_are_counted(self) -> None:
        """Malformed summaries are counted so the report can surface data loss."""
        good_dir = self.tmp_dir / "good"
        good_path = self._write_summary(
            good_dir,
            {"invocations": 1, "started_at": "2026-03-01T00:00:00Z",
             "ended_at": "2026-03-01T00:01:00Z"},
        )
        bad_dir = self.tmp_dir / "bad"
        bad_dir.mkdir(parents=True, exist_ok=True)
        bad_path = bad_dir / "plan-usage-summary.json"
        bad_path.write_text('{"todos_done":23 25,"todos_total":,}', encoding="utf-8")

        report = self.report_module.build_report([str(good_path), str(bad_path)])
        self.assertEqual(report["skipped_summaries"], 1)

    def test_schema_v2_exposes_session_usage_and_counterfactual(self) -> None:
        """Overhauled report separates billed session usage from estimated savings.

        schema v2 keeps the backward-compatible top-level saved_bytes/saved_tokens
        fields but adds an explicit `session_usage` block with billed tokens and
        a `tool_output_counterfactual` block that estimates with-vs-without-Ralph
        tool-output bytes/tokens.
        """
        run_dir = self.tmp_dir / "billed_only"
        summary_path = self._write_summary(
            run_dir,
            {
                "invocations": 2,
                "input_tokens": 1000,
                "output_tokens": 200,
                "cache_creation_input_tokens": 300,
                "cache_read_input_tokens": 700,
                "prompt_bytes": 1200,
                "tool_calls_total": 42,
                "started_at": "2026-04-01T00:00:00Z",
                "ended_at": "2026-04-01T00:01:00Z",
                "byte_savings_by_path": {
                    "pre_tool_rewrite": {
                        "pre_optimization_bytes": 400,
                        "post_optimization_bytes": 200,
                        "saved_bytes": 200,
                        "pre_optimization_tokens": 100,
                        "post_optimization_tokens": 50,
                        "saved_tokens": 50,
                        "count": 1,
                        "token_cap_triggers": 0,
                    },
                },
            },
        )

        report = self.report_module.build_report([str(summary_path)])

        self.assertEqual(report["schema_version"], 2)
        self.assertEqual(report["saved_tokens"], 50)
        self.assertIn("session_usage", report)
        self.assertIn("tool_output_counterfactual", report)
        session = report["session_usage"]
        self.assertEqual(session["input_tokens"], 1000)
        self.assertEqual(session["output_tokens"], 200)
        self.assertEqual(session["cache_creation_input_tokens"], 300)
        self.assertEqual(session["cache_read_input_tokens"], 700)
        self.assertEqual(session["prompt_bytes"], 1200)
        self.assertEqual(session["tool_calls_total"], 42)
        # Backward-compatible top-level fields remain present.
        self.assertIn("saved_bytes", report)
        self.assertIn("saved_tokens", report)
        # Cache remains exposed under the dedicated cache section only.
        self.assertIn("cache", report)
        self.assertNotIn("input_tokens", report["cache"])

    def test_tool_output_counterfactual_totals_across_runs(self) -> None:
        """Aggregate counterfactual covers all runs' pre/post optimization bytes."""
        run_a = self.tmp_dir / "run_a"
        self._write_summary(
            run_a,
            {
                "invocations": 1,
                "input_tokens": 100,
                "output_tokens": 10,
                "cache_creation_input_tokens": 0,
                "cache_read_input_tokens": 50,
                "prompt_bytes": 120,
                "tool_calls_total": 5,
                "started_at": "2026-04-01T00:00:00Z",
                "ended_at": "2026-04-01T00:01:00Z",
                "byte_savings_by_path": {
                    "pre_tool_rewrite": {
                        "pre_optimization_bytes": 400,
                        "post_optimization_bytes": 200,
                        "saved_bytes": 200,
                        "pre_optimization_tokens": 100,
                        "post_optimization_tokens": 50,
                        "saved_tokens": 50,
                        "count": 1,
                        "token_cap_triggers": 0,
                    },
                },
            },
        )

        run_b = self.tmp_dir / "run_b"
        self._write_summary(
            run_b,
            {
                "invocations": 1,
                "input_tokens": 200,
                "output_tokens": 20,
                "cache_creation_input_tokens": 0,
                "cache_read_input_tokens": 100,
                "prompt_bytes": 240,
                "tool_calls_total": 10,
                "started_at": "2026-04-01T00:02:00Z",
                "ended_at": "2026-04-01T00:03:00Z",
                "byte_savings_by_path": {
                    "hook_compaction": {
                        "pre_optimization_bytes": 600,
                        "post_optimization_bytes": 300,
                        "saved_bytes": 300,
                        "pre_optimization_tokens": 150,
                        "post_optimization_tokens": 75,
                        "saved_tokens": 75,
                        "count": 1,
                        "token_cap_triggers": 0,
                        "hidden_from_context": 300,
                        "hidden_from_context_tokens": 75,
                    },
                },
            },
        )

        report = self.report_module.build_report([str(run_a / "plan-usage-summary.json"), str(run_b / "plan-usage-summary.json")])

        counterfactual = report["tool_output_counterfactual"]
        self.assertEqual(
            counterfactual["hypothetical_without_ralph_bytes"], 1000
        )
        self.assertEqual(counterfactual["actual_with_ralph_bytes"], 500)
        self.assertEqual(counterfactual["net_savings_bytes"], 500)
        self.assertGreater(counterfactual["net_savings_tokens"], 0)
        self.assertEqual(counterfactual["net_savings_percent"], 50.0)

        # Session usage aggregates across both summaries.
        session = report["session_usage"]
        self.assertEqual(session["input_tokens"], 300)
        self.assertEqual(session["output_tokens"], 30)
        self.assertEqual(session["cache_read_input_tokens"], 150)
        self.assertEqual(session["prompt_bytes"], 360)
        self.assertEqual(session["tool_calls_total"], 15)

    def test_multi_readback_gross_exceeds_one_and_net_savings_is_negative(self) -> None:
        """Gross readback can exceed 100%; the report reports net savings as primary."""
        from tool_call_target_telemetry import analyze_result_windowing_log

        run_dir = self.tmp_dir / "logs" / "multi_readback"
        summary = {
            "invocations": 3,
            "input_tokens": 100,
            "output_tokens": 10,
            "cache_creation_input_tokens": 0,
            "cache_read_input_tokens": 50,
            "prompt_bytes": 120,
            "tool_calls_total": 5,
            "started_at": "2026-05-01T00:00:00Z",
            "ended_at": "2026-05-01T00:30:00Z",
            "byte_savings_by_path": {
                "result_windowing": {
                    "pre_optimization_bytes": 1000,
                    "post_optimization_bytes": 1000,
                    "saved_bytes": 0,
                    "pre_optimization_tokens": 250,
                    "post_optimization_tokens": 250,
                    "saved_tokens": 0,
                    "count": 1,
                    "token_cap_triggers": 0,
                    "hidden_from_context": 0,
                    "hidden_from_context_tokens": 0,
                },
            },
        }
        summary_path = self._write_summary(run_dir, summary)

        # One envelope, two readbacks whose returned bytes exceed original bytes.
        invocation = {
            "plan_key": "plan",
            "iteration": 1,
            "byte_savings_by_path": {
                "result_windowing": {
                    "pre_optimization_bytes": 1000,
                    "post_optimization_bytes": 1000,
                    "saved_bytes": 0,
                    "pre_optimization_tokens": 250,
                    "post_optimization_tokens": 250,
                    "saved_tokens": 0,
                    "count": 1,
                    "token_cap_triggers": 0,
                    "hidden_from_context": 0,
                    "hidden_from_context_tokens": 0,
                }
            },
        }
        self._write_invocation(summary_path, [invocation])

        # Write a result-windowing log where _windowing_log_for_summary expects it.
        # For a summary at logs/<run>/plan-usage-summary.json, the resolver looks
        # for runtime-config/<run>/result-windowing.jsonl two levels above the run.
        plan_key = run_dir.name
        runtime_config_dir = self.tmp_dir.resolve() / "runtime-config" / plan_key
        runtime_config_dir.mkdir(parents=True, exist_ok=True)
        log_path = runtime_config_dir / "result-windowing.jsonl"
        # v2-measured, so the loss is verifiable and reaches the headline. A
        # legacy record would be quarantined as an unverified estimate instead
        # (see test_legacy_windowing_is_excluded_from_the_headline).
        with log_path.open("w", encoding="utf-8") as handle:
            for record in [
                {"event": "envelope", "resultId": "r1", "measurementVersion": 2,
                 "originalBytes": 5000, "returnedBytes": 100,
                 "inlineCandidateBytes": 1000, "inlineCandidateTokens": 250,
                 "deliveredBytes": 100, "deliveredTokens": 25},
                {"event": "readback", "resultId": "r1", "view": "compacted",
                 "returnedBytes": 600},
                {"event": "readback", "resultId": "r1", "view": "raw",
                 "returnedBytes": 800},
            ]:
                handle.write(json.dumps(record) + "\n")

        report = self.report_module.build_report([str(summary_path)])

        # Sanity-check that the underlying windowing analyzer still reports >1
        # gross negation rate for this fixture.
        stats = analyze_result_windowing_log(str(log_path))
        self.assertGreater(stats["readback_negation_rate"], 1.0)

        # The agent consumed the 100-byte preview plus 600 + 800 bytes of readback
        # against a 1000-byte inline baseline: 1500 consumed for 1000 of value.
        # Net consumed is not capped at the baseline, so the 500-byte loss is
        # reported as a loss rather than floored to a wash.
        self.assertEqual(report["per_path"]["result_windowing"]["saved_bytes"], -500)
        self.assertEqual(
            report["per_path"]["result_windowing"]["status"], "negated"
        )
        self.assertEqual(report["saved_bytes"], -500)
        readback = report["readback_summary"]
        self.assertGreater(readback["readback_negation_rate"], 1.0)
        self.assertEqual(readback["effective_windowing_savings_rate"], -0.5)
        self.assertEqual(readback["net_consumed_bytes"], 1500)
        self.assertEqual(readback["gross_readback_bytes"], 1400)
        self.assertEqual(
            report["tool_output_counterfactual"]["net_savings_bytes"], -500
        )
        self.assertEqual(
            report["tool_output_counterfactual"]["net_savings_percent"], -50.0
        )
        # A v2-measured loss is verifiable, so nothing is quarantined.
        self.assertEqual(
            report["tool_output_counterfactual"]["unverified_savings_bytes"], 0
        )

    def test_legacy_windowing_is_excluded_from_the_headline(self) -> None:
        """Legacy records credit the whole stored source as saved. Quarantine them.

        A legacy envelope has no inlineCandidateBytes, so its baseline is the full
        captured source -- bytes the tool's own limits would have trimmed before
        the model saw them. Counting that as savings is what produced Ralph's
        1.12 GB / 99.7% headline. The headline must ignore it and say so.
        """
        run_dir = self.tmp_dir / "logs" / "legacy-plan"
        summary = {
            "plan_key": "legacy-plan",
            "invocations": 1,
            "started_at": "2026-05-02T00:00:00Z",
            "ended_at": "2026-05-02T01:00:00Z",
        }
        summary_path = self._write_summary(run_dir, summary)

        runtime_config_dir = self.tmp_dir.resolve() / "runtime-config" / "legacy-plan"
        runtime_config_dir.mkdir(parents=True, exist_ok=True)
        log_path = runtime_config_dir / "result-windowing.jsonl"
        with log_path.open("w", encoding="utf-8") as handle:
            # 5 MB stored source, 500-byte preview. Legacy math calls that a
            # 4,999,500-byte saving; in truth the tool would never have inlined
            # 5 MB, and no field here records what it would have inlined.
            handle.write(json.dumps({
                "event": "envelope", "resultId": "r1",
                "originalBytes": 5_000_000, "returnedBytes": 500,
            }) + "\n")

        report = self.report_module.build_report([str(summary_path)])
        counterfactual = report["tool_output_counterfactual"]

        self.assertEqual(counterfactual["net_savings_bytes"], 0)
        self.assertEqual(counterfactual["net_savings_percent"], 0.0)
        self.assertEqual(counterfactual["unverified_savings_bytes"], 4_999_500)
        self.assertEqual(counterfactual["unverified_event_count"], 1)

        bucket = report["per_path"]["result_windowing"]
        self.assertEqual(bucket["verified_count"], 0)
        self.assertEqual(bucket["unverified_count"], 1)

    def test_build_report_scopes_windowing_log_to_matching_plan_key(self) -> None:
        run_dir = self.tmp_dir / "logs" / "plan-a"
        summary = {
            "plan_key": "plan-a",
            "invocations": 1,
            "started_at": "2026-05-02T00:00:00Z",
            "ended_at": "2026-05-02T00:05:00Z",
            "byte_savings_by_path": {
                "result_windowing": {
                    "pre_optimization_bytes": 1000,
                    "post_optimization_bytes": 100,
                    "saved_bytes": 900,
                    "pre_optimization_tokens": 250,
                    "post_optimization_tokens": 25,
                    "saved_tokens": 225,
                    "count": 1,
                    "token_cap_triggers": 0,
                    "hidden_from_context": 900,
                    "hidden_from_context_tokens": 225,
                },
            },
        }
        summary_path = self._write_summary(run_dir, summary)

        runtime_config_dir = self.tmp_dir / "runtime-config" / run_dir.name
        runtime_config_dir.mkdir(parents=True, exist_ok=True)
        log_path = runtime_config_dir / "result-windowing.jsonl"
        with log_path.open("w", encoding="utf-8") as handle:
            for record in [
                {
                    "event": "envelope",
                    "planKey": "plan-a",
                    "resultId": "a1",
                    "originalBytes": 1000,
                    "returnedBytes": 100,
                },
                {
                    "event": "readback",
                    "planKey": "plan-a",
                    "resultId": "a1",
                    "view": "compacted",
                    "returnedBytes": 50,
                },
                {
                    "event": "envelope",
                    "planKey": "plan-b",
                    "resultId": "b1",
                    "originalBytes": 5000,
                    "returnedBytes": 500,
                },
                {
                    "event": "readback",
                    "planKey": "plan-b",
                    "resultId": "b1",
                    "view": "raw",
                    "returnedBytes": 4500,
                },
            ]:
                handle.write(json.dumps(record) + "\n")

        report = self.report_module.build_report([str(summary_path)])

        self.assertEqual(report["readback_summary"]["envelope_original_bytes"], 1000)
        self.assertEqual(report["readback_summary"]["gross_readback_bytes"], 50)
        self.assertEqual(report["readback_summary"]["readback_count"], 1)
        self.assertIn("per_channel", report)
        self.assertIn("per_channel", report["runs"][0])
        legacy_bucket = report["per_channel"]["stored_result_readback"]
        self.assertEqual(legacy_bucket["attribution"], "legacy")
        self.assertGreater(legacy_bucket["saved_bytes"], 0)

    def test_build_report_includes_exact_per_channel_attribution(self) -> None:
        run_dir = self.tmp_dir / "logs" / "exact-channel-plan"
        summary = {
            "plan_key": "exact-channel-plan",
            "invocations": 1,
            "started_at": "2026-05-03T00:00:00Z",
            "ended_at": "2026-05-03T00:05:00Z",
        }
        summary_path = self._write_summary(run_dir, summary)

        runtime_config_dir = self.tmp_dir / "runtime-config" / run_dir.name
        runtime_config_dir.mkdir(parents=True, exist_ok=True)
        log_path = runtime_config_dir / "result-windowing.jsonl"
        with log_path.open("w", encoding="utf-8") as handle:
            for record in [
                {
                    "event": "envelope",
                    "planKey": "exact-channel-plan",
                    "resultId": "read-1",
                    "channel": "proxy_read_windowing",
                    "originalBytes": 1000,
                    "returnedBytes": 200,
                },
                {
                    "event": "readback",
                    "planKey": "exact-channel-plan",
                    "resultId": "read-1",
                    "sourceResultChannel": "proxy_read_windowing",
                    "view": "compacted",
                    "returnedBytes": 100,
                },
            ]:
                handle.write(json.dumps(record) + "\n")

        report = self.report_module.build_report([str(summary_path)])

        self.assertIn("per_channel", report)
        run = report["runs"][0]
        self.assertIn("per_channel", run)
        exact_bucket = report["per_channel"]["proxy_read_windowing"]
        self.assertEqual(exact_bucket["attribution"], "exact")
        self.assertEqual(exact_bucket["saved_bytes"], 700)
        self.assertEqual(exact_bucket["gross_readback_bytes"], 100)
        self.assertEqual(exact_bucket["net_consumed_bytes"], 300)
        self.assertEqual(report["per_channel"]["stored_result_readback"]["saved_bytes"], 0)

    def test_build_report_surfaces_legacy_unknown_attribution_separately(self) -> None:
        run_dir = self.tmp_dir / "logs" / "legacy-channel-plan"
        summary = {
            "plan_key": "legacy-channel-plan",
            "invocations": 1,
            "started_at": "2026-05-04T00:00:00Z",
            "ended_at": "2026-05-04T00:05:00Z",
        }
        summary_path = self._write_summary(run_dir, summary)

        runtime_config_dir = self.tmp_dir / "runtime-config" / run_dir.name
        runtime_config_dir.mkdir(parents=True, exist_ok=True)
        log_path = runtime_config_dir / "result-windowing.jsonl"
        with log_path.open("w", encoding="utf-8") as handle:
            for record in [
                {
                    "event": "envelope",
                    "planKey": "legacy-channel-plan",
                    "resultId": "legacy-1",
                    "originalBytes": 1000,
                    "returnedBytes": 200,
                },
                {
                    "event": "readback",
                    "planKey": "legacy-channel-plan",
                    "resultId": "legacy-1",
                    "view": "compacted",
                    "returnedBytes": 100,
                },
            ]:
                handle.write(json.dumps(record) + "\n")

        report = self.report_module.build_report([str(summary_path)])

        legacy_bucket = report["per_channel"]["stored_result_readback"]
        self.assertEqual(legacy_bucket["attribution"], "legacy")
        self.assertEqual(legacy_bucket["saved_bytes"], 700)
        self.assertEqual(legacy_bucket["gross_readback_bytes"], 100)
        self.assertEqual(legacy_bucket["net_consumed_bytes"], 300)
        self.assertEqual(report["per_channel"]["proxy_read_windowing"]["saved_bytes"], 0)

    def test_build_report_uses_most_recent_optimization_opportunities_source(self) -> None:
        older_dir = self.tmp_dir / "logs" / "older-plan"
        older_summary_path = self._write_summary(
            older_dir,
            {
                "plan_key": "older-plan",
                "invocations": 1,
                "started_at": "2026-05-01T00:00:00Z",
                "ended_at": "2026-05-01T00:05:00Z",
            },
        )
        self._write_json(
            older_dir / "discover-report.json",
            {
                "missed_compaction_opportunities": [
                    {"original_bytes": 2000, "skip_reason": "older-opportunity"}
                ]
            },
        )

        newest_dir = self.tmp_dir / "logs" / "newest-plan"
        newest_summary_path = self._write_summary(
            newest_dir,
            {
                "plan_key": "newest-plan",
                "invocations": 1,
                "started_at": "2026-06-01T00:00:00Z",
                "ended_at": "2026-06-01T00:05:00Z",
            },
        )
        self._write_json(
            newest_dir / "discover-report.json",
            {
                "missed_compaction_opportunities": [
                    {"original_bytes": 3000, "skip_reason": "newest-opportunity"}
                ]
            },
        )

        report = self.report_module.build_report(
            [str(older_summary_path), str(newest_summary_path)]
        )

        self.assertEqual(
            report["optimization_opportunities"]["missed_compaction_opportunities"][0][
                "skip_reason"
            ],
            "newest-opportunity",
        )
        self.assertEqual(
            report["optimization_opportunities_source"]["plan_key"], "newest-plan"
        )
        self.assertEqual(
            report["optimization_opportunities_source"]["ended_at"],
            "2026-06-01T00:05:00Z",
        )

    def test_baseline_result_windowing_is_single_blended_bucket(self) -> None:
        """Current overlay aggregation folds all windowing into one result_windowing bucket."""
        state_dir = self.tmp_dir / "runtime-config" / "blended-windowing"
        state_dir.mkdir(parents=True, exist_ok=True)
        window_path = state_dir / "result-windowing.jsonl"
        with window_path.open("w", encoding="utf-8") as handle:
            for record in [
                {
                    "event": "envelope",
                    "planKey": "blended-windowing",
                    "resultId": "proxy-read",
                    "toolName": "ralph_proxy_read",
                    "originalBytes": 5000,
                    "returnedBytes": 500,
                },
                {
                    "event": "readback",
                    "planKey": "blended-windowing",
                    "resultId": "proxy-read",
                    "view": "compacted",
                    "returnedBytes": 200,
                },
                {
                    "event": "envelope",
                    "planKey": "blended-windowing",
                    "resultId": "stored-readback",
                    "toolName": "ralph_proxy_result_read",
                    "originalBytes": 8000,
                    "returnedBytes": 800,
                },
                {
                    "event": "readback",
                    "planKey": "blended-windowing",
                    "resultId": "stored-readback",
                    "view": "raw",
                    "returnedBytes": 400,
                },
            ]:
                handle.write(json.dumps(record) + "\n")

        hook_path = state_dir / "bash-compact.jsonl"
        hook_path.write_text(
            json.dumps(
                {
                    "planKey": "blended-windowing",
                    "originalBytes": 2000,
                    "compactedBytes": 1000,
                }
            )
            + "\n",
            encoding="utf-8",
        )

        savings = OVERLAY_FIELDS.aggregate_byte_savings_by_path(
            str(state_dir), "blended-windowing"
        )

        self.assertEqual(
            set(savings.keys()),
            {
                "pre_tool_rewrite",
                "hook_compaction",
                "proxy_shell_compaction",
                "result_windowing",
            },
        )
        self.assertGreater(savings["result_windowing"]["saved_bytes"], 0)
        self.assertGreater(savings["hook_compaction"]["saved_bytes"], 0)
        for key in savings:
            self.assertNotIn("proxy_read_windowing", key)
            self.assertNotIn("stored_result_readback", key)

    def test_baseline_discover_heavy_native_finding_is_ratio_driven_not_bytes(
        self,
    ) -> None:
        """Discover flags heavy_native from tool-call ratios, not saved bytes."""
        fixture = self._load_baseline_fixture("native-heavy-with-real-optimization.json")
        invocations = fixture["invocations"]
        expected = fixture["expected_baseline"]

        report = DISCOVER_REPORT.build_discover_report(
            {"invocations": invocations},
            plan_key=fixture["plan_key"],
        )

        aggregate_ids = {
            item["pattern_id"]
            for item in report["aggregate_findings"]
            if isinstance(item, dict)
        }
        self.assertIn(expected["aggregate_finding_pattern_id"], aggregate_ids)

        savings = DISCOVER_REPORT._summarize_byte_savings_by_path(
            invocations, plan_key=fixture["plan_key"]
        )
        self.assertGreaterEqual(
            savings["result_windowing"]["saved_bytes"],
            expected["result_windowing_saved_bytes_min"],
        )
        self.assertGreaterEqual(
            savings["hook_compaction"]["saved_bytes"],
            expected["hook_compaction_saved_bytes_min"],
        )
        self.assertGreaterEqual(
            savings["proxy_shell_compaction"]["saved_bytes"],
            expected["proxy_shell_compaction_saved_bytes_min"],
        )

        native_read_share = report["aggregate_findings"][0]["native_read_share"]
        self.assertGreaterEqual(native_read_share, expected["native_read_share_min"])

    def test_discover_native_heavy_with_real_savings_separates_diagnostics_from_missed(
        self,
    ) -> None:
        """Native-heavy tool mix with real channel savings is not flagged as unoptimized."""
        fixture = self._load_baseline_fixture("native-heavy-with-real-optimization.json")
        report = DISCOVER_REPORT.build_discover_report(
            {"invocations": fixture["invocations"]},
            plan_key=fixture["plan_key"],
        )

        self.assertEqual(report["missed_compaction_opportunities"], [])
        self.assertTrue(report["optimization_evidence"]["has_meaningful_savings"])
        self.assertGreater(
            report["optimization_evidence"]["byte_savings_by_path"]["result_windowing"][
                "saved_bytes"
            ],
            0,
        )
        diagnostics = report["tool_adoption_diagnostics"]
        self.assertTrue(diagnostics["heavy_native_read_mix"])
        self.assertEqual(
            diagnostics["heavy_native_read_mix"][0]["pattern_id"],
            fixture["expected_baseline"]["aggregate_finding_pattern_id"],
        )
        self.assertEqual(diagnostics["ralph_mode_native_explore_tools"], [])
        self.assertEqual(diagnostics["native_shell_preferred_over_proxy"], [])

    def test_discover_no_channel_savings_populates_missed_compaction_from_evidence(
        self,
    ) -> None:
        """Runs without savings still surface channel-based missed compaction findings."""
        invocations = [
            {
                "plan_key": "no-channel-savings",
                "iteration": 1,
                "runtime": "cursor",
                "agent_tool_access": "ralph",
                "native_shell_calls": 2,
                "native_read_like_calls": 4,
                "ralph_proxy_calls": 0,
                "byte_savings_by_path": {
                    "hook_compaction": {
                        "pre_optimization_bytes": 0,
                        "post_optimization_bytes": 0,
                        "saved_bytes": 0,
                        "count": 0,
                        "pre_optimization_tokens": 0,
                        "post_optimization_tokens": 0,
                        "saved_tokens": 0,
                        "token_cap_triggers": 0,
                    },
                    "proxy_shell_compaction": {
                        "pre_optimization_bytes": 0,
                        "post_optimization_bytes": 0,
                        "saved_bytes": 0,
                        "count": 0,
                        "pre_optimization_tokens": 0,
                        "post_optimization_tokens": 0,
                        "saved_tokens": 0,
                        "token_cap_triggers": 0,
                    },
                    "result_windowing": {
                        "pre_optimization_bytes": 0,
                        "post_optimization_bytes": 0,
                        "saved_bytes": 0,
                        "count": 0,
                        "pre_optimization_tokens": 0,
                        "post_optimization_tokens": 0,
                        "saved_tokens": 0,
                        "token_cap_triggers": 0,
                    },
                },
                "compaction_telemetry": [
                    {
                        "plan_key": "no-channel-savings",
                        "original_bytes": 9000,
                        "compacted_bytes": 0,
                        "compaction_skipped": True,
                        "skip_reason": "below threshold",
                        "family": "shell",
                    }
                ],
            }
        ]
        report = DISCOVER_REPORT.build_discover_report(
            {"invocations": invocations},
            plan_key="no-channel-savings",
        )

        self.assertFalse(report["optimization_evidence"]["has_meaningful_savings"])
        missed = report["missed_compaction_opportunities"]
        self.assertTrue(missed)
        skip_types = {item.get("skip_type") for item in missed if "skip_type" in item}
        pattern_ids = {item.get("pattern_id") for item in missed if "pattern_id" in item}
        self.assertIn("compaction_skipped", skip_types)
        self.assertIn("shell_channel_zero_savings", pattern_ids)
        bypass = report["tool_adoption_diagnostics"]["native_shell_preferred_over_proxy"]
        self.assertEqual(len(bypass), 1)
        self.assertEqual(bypass[0]["pattern_id"], "native_shell_bypassed_compaction")
        self.assertNotIn("native_shell_bypassed_compaction", pattern_ids)

    def test_discover_report_summation_uses_latest_cumulative_snapshot(self) -> None:
        """_summarize_byte_savings_by_path now matches benchmark latest-snapshot semantics.

        The discover report's helper used to sum cumulative snapshots per
        iteration, over-counting the real total. After the overhaul it keeps the
        final cumulative snapshot per (plan_key, path_name), matching
        ralph-benchmark-report.py.
        """
        run_dir = self.tmp_dir / "discover_cumulative"
        summary = {
            "invocations": 3,
            "started_at": "2026-05-01T00:00:00Z",
            "ended_at": "2026-05-01T00:30:00Z",
        }
        summary_path = self._write_summary(run_dir, summary)

        def _window_bucket(saved: int) -> dict[str, Any]:
            return {
                "pre_optimization_bytes": saved + 1000,
                "post_optimization_bytes": 1000,
                "saved_bytes": saved,
                "pre_optimization_tokens": 0,
                "post_optimization_tokens": 0,
                "saved_tokens": 0,
                "count": 1,
                "token_cap_triggers": 0,
                "hidden_from_context": saved,
                "hidden_from_context_tokens": 0,
            }

        # Cumulative snapshots: 10k, 25k, 0. Discover now keeps the last (0).
        invocations = [
            {"plan_key": "plan", "iteration": i + 1,
             "byte_savings_by_path": {"result_windowing": _window_bucket(saved)}}
            for i, saved in enumerate((10_000, 25_000, 0))
        ]
        self._write_invocation(summary_path, invocations)

        report = self.report_module.build_report([str(summary_path)])
        self.assertEqual(report["per_path"]["result_windowing"]["saved_bytes"], 0)

        discover_summary = DISCOVER_REPORT._summarize_byte_savings_by_path(
            invocations, plan_key="plan"
        )
        # After the overhaul discover-report matches benchmark-report.
        self.assertEqual(
            discover_summary["result_windowing"]["saved_bytes"], 0
        )

    def test_readback_negation_rate_can_exceed_one(self) -> None:
        """Readback negation rate > 1.0 is possible before overhaul fixes.

        analyze_result_windowing_log totals returnedBytes across all readback
        events and divides by envelope originalBytes. When multiple readbacks
        touch the same resultId, returnedBytes can exceed the original
        envelope, producing a rate above 1.0. This test documents the current
        behavior.
        """
        from tool_call_target_telemetry import analyze_result_windowing_log

        with tempfile.NamedTemporaryFile("w", encoding="utf-8", delete=False) as handle:
            path = handle.name
            for record in [
                {"event": "envelope", "resultId": "r1",
                 "originalBytes": 1000, "returnedBytes": 100},
                {"event": "readback", "resultId": "r1", "view": "compacted",
                 "returnedBytes": 600},
                {"event": "readback", "resultId": "r1", "view": "raw",
                 "returnedBytes": 800},
            ]:
                handle.write(json.dumps(record) + "\n")

        try:
            stats = analyze_result_windowing_log(path)
        finally:
            Path(path).unlink(missing_ok=True)

        self.assertGreater(stats["readback_negation_rate"], 1.0)
        self.assertEqual(stats["readback_bytes"], 1400)

    def _build_shared_parity_fixture(self) -> tuple[Path, dict[str, Any]]:
        """Return a summary path and expected scalar fields for dashboard parity.

        The fixture is designed so the dashboard TypeScript aggregator, when fed
        the same summary and result-windowing log, should produce identical
        top-level savings and counterfactual numbers as the Python benchmark
        report.  Both aggregators read byte_savings_by_path from the summary and
        the result-windowing log from ../runtime-config/<plan>/result-windowing.jsonl.
        To match that layout, the plan summary lives under a synthetic logs dir.
        """
        run_dir = self.tmp_dir / "logs" / "dashboard_parity"
        summary = {
            "invocations": 2,
            "input_tokens": 800,
            "output_tokens": 100,
            "cache_creation_input_tokens": 50,
            "cache_read_input_tokens": 150,
            "prompt_bytes": 960,
            "tool_calls_total": 24,
            "started_at": "2026-06-01T00:00:00Z",
            "ended_at": "2026-06-01T00:10:00Z",
            "compaction_measured_not_applied_bytes": 64,
            "byte_savings_by_path": {
                "pre_tool_rewrite": {
                    "pre_optimization_bytes": 400,
                    "post_optimization_bytes": 200,
                    "saved_bytes": 200,
                    "pre_optimization_tokens": 100,
                    "post_optimization_tokens": 50,
                    "saved_tokens": 50,
                    "count": 1,
                    "token_cap_triggers": 0,
                },
                "hook_compaction": {
                    "pre_optimization_bytes": 300,
                    "post_optimization_bytes": 200,
                    "saved_bytes": 100,
                    "pre_optimization_tokens": 75,
                    "post_optimization_tokens": 50,
                    "saved_tokens": 25,
                    "count": 1,
                    "token_cap_triggers": 0,
                    "hidden_from_context": 100,
                    "hidden_from_context_tokens": 25,
                },
                "proxy_shell_compaction": {
                    "pre_optimization_bytes": 200,
                    "post_optimization_bytes": 120,
                    "saved_bytes": 80,
                    "pre_optimization_tokens": 50,
                    "post_optimization_tokens": 30,
                    "saved_tokens": 20,
                    "count": 1,
                    "token_cap_triggers": 0,
                    "hidden_from_context": 80,
                    "hidden_from_context_tokens": 20,
                },
                "result_windowing": {
                    "pre_optimization_bytes": 1000,
                    "post_optimization_bytes": 200,
                    "saved_bytes": 800,
                    "pre_optimization_tokens": 250,
                    "post_optimization_tokens": 50,
                    "saved_tokens": 200,
                    "count": 1,
                    "token_cap_triggers": 0,
                    "hidden_from_context": 800,
                    "hidden_from_context_tokens": 200,
                },
            },
        }
        summary_path = self._write_summary(run_dir, summary)

        plan_key = run_dir.name
        # _windowing_log_for_summary resolves to summary_parent_parent/runtime-config.
        # With run_dir = tmp_dir/logs/<plan>, summary_parent_parent is tmp_dir.
        runtime_config_dir = self.tmp_dir / "runtime-config" / plan_key
        runtime_config_dir.mkdir(parents=True, exist_ok=True)
        log_path = runtime_config_dir / "result-windowing.jsonl"
        with log_path.open("w", encoding="utf-8") as handle:
            for record in [
                {"event": "envelope", "resultId": "r1",
                 "originalBytes": 1000, "returnedBytes": 200,
                 "originalTokens": 250, "returnedTokens": 50},
                {"event": "readback", "resultId": "r1", "view": "compacted",
                 "returnedBytes": 100, "returnedTokens": 25},
                {"event": "readback", "resultId": "r1", "view": "raw",
                 "returnedBytes": 50, "returnedTokens": 13},
            ]:
                handle.write(json.dumps(record) + "\n")

        expected = {
            "schema_version": 2,
            "run_count": 2,
            # Windowing is recomputed from the log, not read from the summary's
            # stored bucket: 1000 baseline against 200 delivered + 150 readback
            # = 650 saved, not the 800 the summary claims by ignoring readbacks.
            # 200 + 100 + 80 (compaction) + 650 = 1030.
            "saved_bytes": 1030,
            "session_usage": {
                "input_tokens": 800,
                "output_tokens": 100,
                "cache_creation_input_tokens": 50,
                "cache_read_input_tokens": 150,
                "prompt_bytes": 960,
                "tool_calls_total": 24,
                "uncached_input_tokens": 800,
                "total_input_tokens": 1000,
                "cache_efficiency_ratio": 0.15,
            },
            # The windowing records in this fixture are legacy (no
            # measurementVersion), so they are excluded from the counterfactual
            # entirely: hypothetical drops the 1,000-byte windowing baseline and
            # actual drops its 350 net-consumed bytes, leaving compaction only.
            "tool_output_counterfactual": {
                "hypothetical_without_ralph_bytes": 900,
                "actual_with_ralph_bytes": 520,
                "net_savings_bytes": 380,
                "net_savings_percent": 42.2,
                "compaction_measured_not_applied_bytes": 64,
                "unverified_savings_bytes": 650,
            },
            "readback_summary": {
                "envelope_count": 1,
                "readback_count": 2,
                "raw_readback_count": 1,
                "compacted_readback_count": 1,
                "readback_bytes": 150,
                "envelope_original_bytes": 1000,
                "gross_readback_bytes": 150,
                "net_consumed_bytes": 350,
                "effective_windowing_savings_rate": 0.65,
            },
        }
        return summary_path, expected

    def test_python_parity_fixture_values(self) -> None:
        """The shared fixture produces predictable Python report fields."""
        summary_path, expected = self._build_shared_parity_fixture()
        report = self.report_module.build_report([str(summary_path)])

        self.assertEqual(report["schema_version"], expected["schema_version"])
        self.assertEqual(report["run_count"], expected["run_count"])
        self.assertEqual(report["saved_bytes"], expected["saved_bytes"])
        self.assertEqual(
            report["session_usage"], expected["session_usage"]
        )
        counterfactual = report["tool_output_counterfactual"]
        self.assertEqual(
            counterfactual["hypothetical_without_ralph_bytes"],
            expected["tool_output_counterfactual"]["hypothetical_without_ralph_bytes"],
        )
        # The windowing records here are legacy, so they are quarantined: the
        # headline counts compaction only, and the 650 bytes of legacy windowing
        # "savings" are reported separately as an unverifiable estimate.
        self.assertEqual(counterfactual["actual_with_ralph_bytes"], 520)
        self.assertEqual(counterfactual["net_savings_bytes"], 380)
        self.assertEqual(counterfactual["net_savings_percent"], 42.2)
        self.assertEqual(counterfactual["unverified_savings_bytes"], 650)
        # per_path still reports the full picture; only the headline is gated.
        self.assertEqual(report["per_path"]["result_windowing"]["saved_bytes"], 650)
        self.assertEqual(
            counterfactual["compaction_measured_not_applied_bytes"], 64
        )
        readback = report["readback_summary"]
        self.assertEqual(
            readback["envelope_count"], expected["readback_summary"]["envelope_count"]
        )
        self.assertEqual(
            readback["readback_count"], expected["readback_summary"]["readback_count"]
        )
        self.assertEqual(
            readback["gross_readback_bytes"],
            expected["readback_summary"]["gross_readback_bytes"],
        )
        self.assertEqual(
            readback["net_consumed_bytes"],
            expected["readback_summary"]["net_consumed_bytes"],
        )
        self.assertEqual(
            readback["effective_windowing_savings_rate"],
            expected["readback_summary"]["effective_windowing_savings_rate"],
        )
        # 0% savings path should surface status information.
        for bucket in report["per_path"].values():
            self.assertIn("pre_optimization_bytes", bucket)
            self.assertIn("post_optimization_bytes", bucket)
        self.assertEqual(readback["envelope_original_bytes"], 1000)

    def test_async_shell_polling_findings_detects_excessive_status_calls(self) -> None:
        invocations = [
            {
                "iteration": 1,
                "runtime": "claude",
                "tool_calls_by_tool": {
                    "ralph_proxy_shell_status": 10,
                    "ralph_proxy_shell_wait": 1,
                    "ralph_proxy_shell_start": 0,
                },
            },
        ]
        findings = DISCOVER_REPORT._async_shell_polling_findings(invocations)
        self.assertEqual(len(findings), 1)
        self.assertEqual(findings[0]["pattern_id"], "repeated_shell_status_polling")
        self.assertEqual(findings[0]["ralph_proxy_shell_status_calls"], 10)
        self.assertIn("shell_wait", findings[0]["note"])
        self.assertIn("runner", findings[0]["note"].lower())

    def test_async_shell_polling_findings_skips_when_proportional(self) -> None:
        invocations = [
            {
                "iteration": 1,
                "runtime": "claude",
                "tool_calls_by_tool": {
                    "ralph_proxy_shell_status": 4,
                    "ralph_proxy_shell_wait": 2,
                    "ralph_proxy_shell_start": 0,
                },
            },
        ]
        findings = DISCOVER_REPORT._async_shell_polling_findings(invocations)
        self.assertEqual(len(findings), 0)

    def test_async_shell_polling_findings_skips_below_threshold(self) -> None:
        invocations = [
            {
                "iteration": 1,
                "runtime": "claude",
                "tool_calls_by_tool": {
                    "ralph_proxy_shell_status": 2,
                    "ralph_proxy_shell_wait": 0,
                },
            },
        ]
        findings = DISCOVER_REPORT._async_shell_polling_findings(invocations)
        self.assertEqual(len(findings), 0)

    def test_async_shell_polling_findings_in_discover_report_output(self) -> None:
        invocations = [
            {
                "plan_key": "polling_report",
                "iteration": 1,
                "runtime": "opencode",
                "tool_calls_by_tool": {
                    "ralph_proxy_shell_status": 10,
                    "ralph_proxy_shell_wait": 1,
                },
            },
        ]
        findings = DISCOVER_REPORT._async_shell_polling_findings(invocations)
        self.assertTrue(len(findings) >= 1)
        self.assertEqual(findings[0]["pattern_id"], "repeated_shell_status_polling")


class TestRuntimeOverlayChannelProvenance(unittest.TestCase):
    """Runtime summaries expose explicit proven and fallback optimization channels."""

    def setUp(self) -> None:
        self.tmp_dir = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.tmp_dir, ignore_errors=True)

    def _write_overlay_summary(self, env: dict[str, str]) -> dict[str, Any]:
        state_dir = Path(env["RUNTIME_OVERLAY_STATE_DIR_VALUE"])
        summary_path = state_dir / "summary.json"
        merged = os.environ.copy()
        merged.update(env)
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
        self.assertEqual(proc.returncode, 0, msg=proc.stderr or proc.stdout)
        runtime = env["RUNTIME_OVERLAY_SUMMARY_RUNTIME_VALUE"]
        per_runtime_path = state_dir / "summaries" / f"{runtime}.json"
        return json.loads(per_runtime_path.read_text(encoding="utf-8"))

    def test_codex_summary_distinguishes_measured_hook_from_mcp_fallback(self) -> None:
        state_dir = self.tmp_dir / "runtime-config" / "codex-provenance"
        state_dir.mkdir(parents=True)
        summary = self._write_overlay_summary(
            {
                "RUNTIME_OVERLAY_STATE_DIR_VALUE": str(state_dir),
                "RUNTIME_OVERLAY_SUMMARY_RUNTIME_VALUE": "codex",
                "RUNTIME_OVERLAY_SUMMARY_PLAN_KEY_VALUE": "codex-provenance",
                "RUNTIME_OVERLAY_SUMMARY_NATIVE_OUTPUT_MUTATION_PROVEN_VALUE": "false",
                "RUNTIME_OVERLAY_SUMMARY_NATIVE_SHELL_COMPACTION_AUTHORITATIVE_VALUE": "wrapper_based_native_shell_compaction",
                "RUNTIME_OVERLAY_SUMMARY_FALLBACK_PATH_ACTIVE_VALUE": "true",
                "RUNTIME_OVERLAY_ARRAY_PROVEN_CHANNELS": "native_shell_hook\nproxy_shell\nnative_result_mcp_fallback",
                "RUNTIME_OVERLAY_ARRAY_FALLBACK_CHANNELS": "native_result_hook",
            }
        )
        self.assertIn("native_shell_hook", summary["native_optimization_proven_channels"])
        self.assertIn("proxy_shell", summary["native_optimization_proven_channels"])
        self.assertIn("native_result_mcp_fallback", summary["native_optimization_proven_channels"])
        self.assertIn("native_result_hook", summary["fallback_channels_active"])
        self.assertNotIn("native_result_hook", summary["native_optimization_proven_channels"])
        self.assertIn("channel_activity_counts", summary)

    def test_opencode_hybrid_summary_distinguishes_mcp_fallback_from_hook(self) -> None:
        state_dir = self.tmp_dir / "runtime-config" / "opencode-hybrid-provenance"
        state_dir.mkdir(parents=True)
        window_log = state_dir / "result-windowing.jsonl"
        with window_log.open("w", encoding="utf-8") as handle:
            handle.write(
                json.dumps(
                    {
                        "event": "envelope",
                        "planKey": "opencode-hybrid-provenance",
                        "resultId": "read-1",
                        "toolName": "Read",
                        "normalizedToolName": "ralph_proxy_read",
                        "channel": "native_result_mcp_fallback",
                        "originalBytes": 5000,
                        "returnedBytes": 500,
                    }
                )
                + "\n"
            )
        summary = self._write_overlay_summary(
            {
                "RUNTIME_OVERLAY_STATE_DIR_VALUE": str(state_dir),
                "RUNTIME_OVERLAY_SUMMARY_RUNTIME_VALUE": "opencode",
                "RUNTIME_OVERLAY_SUMMARY_PLAN_KEY_VALUE": "opencode-hybrid-provenance",
                "RUNTIME_OVERLAY_SUMMARY_TOOL_ACCESS_MODE_VALUE": "hybrid",
                "RUNTIME_OVERLAY_SUMMARY_NATIVE_SHELL_COMPACTION_AUTHORITATIVE_VALUE": "mcp_proxy_compaction",
                "RUNTIME_OVERLAY_SUMMARY_NATIVE_HOOKS_EFFECTIVE_VALUE": "false",
                "RUNTIME_OVERLAY_ARRAY_PROVEN_CHANNELS": "proxy_shell\nnative_result_mcp_fallback",
                "RUNTIME_OVERLAY_ARRAY_FALLBACK_CHANNELS": "native_result_hook",
            }
        )
        self.assertEqual(summary["native_shell_compaction_authoritative"], "mcp_proxy_compaction")
        self.assertIn("native_result_mcp_fallback", summary["native_optimization_proven_channels"])
        self.assertIn("native_result_hook", summary["fallback_channels_active"])
        self.assertGreater(summary["channel_activity_counts"]["native_result_mcp_fallback"], 0)
        self.assertEqual(summary["channel_activity_counts"]["native_result_hook"], 0)

    def test_aggregate_merges_provenance_from_multiple_runtimes(self) -> None:
        state_dir = self.tmp_dir / "runtime-config" / "mixed-provenance"
        state_dir.mkdir(parents=True)
        summaries_dir = state_dir / "summaries"
        summaries_dir.mkdir()
        (summaries_dir / "cursor.json").write_text(
            json.dumps(
                {
                    "runtime": "cursor",
                    "plan_key": "mixed-provenance",
                    "native_optimization_proven_channels": ["native_shell_hook", "proxy_shell"],
                    "fallback_channels_active": ["native_result_hook"],
                    "channel_activity_counts": OVERLAY_FIELDS.channel_activity_counts_from_savings({}),
                    "updated_at": "2026-07-01T10:00:00Z",
                }
            ),
            encoding="utf-8",
        )
        (summaries_dir / "opencode.json").write_text(
            json.dumps(
                {
                    "runtime": "opencode",
                    "plan_key": "mixed-provenance",
                    "native_optimization_proven_channels": [
                        "native_result_mcp_fallback",
                        "proxy_shell",
                    ],
                    "fallback_channels_active": ["native_result_hook"],
                    "channel_activity_counts": OVERLAY_FIELDS.channel_activity_counts_from_savings({}),
                    "updated_at": "2026-07-01T11:00:00Z",
                }
            ),
            encoding="utf-8",
        )
        aggregate = OVERLAY_FIELDS.merge_runtime_overlay_summaries(
            str(state_dir), plan_key="mixed-provenance"
        )
        self.assertEqual(
            sorted(aggregate["native_optimization_proven_channels"]),
            sorted(
                [
                    "native_shell_hook",
                    "proxy_shell",
                    "native_result_mcp_fallback",
                ]
            ),
        )
        self.assertEqual(aggregate["fallback_channels_active"], ["native_result_hook"])
        self.assertIn("channel_activity_counts", aggregate)


class TestBenchmarkChannelAttributionE2E(unittest.TestCase):
    """End-to-end synthetic fixture: overlay summaries, discover, benchmark JSON, Markdown."""

    def setUp(self) -> None:
        self.tmp_dir = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.tmp_dir, ignore_errors=True)
        self.manifest = json.loads(E2E_MANIFEST.read_text(encoding="utf-8"))
        self.plan_key = self.manifest["plan_key"]
        self._materialize_workspace()

    def _write_jsonl(self, path: Path, records: list[dict[str, Any]]) -> None:
        path.parent.mkdir(parents=True, exist_ok=True)
        with path.open("w", encoding="utf-8") as handle:
            for record in records:
                handle.write(json.dumps(record) + "\n")

    def _materialize_workspace(self) -> None:
        manifest = self.manifest
        runtime_cfg = manifest["runtime_config"]
        state_dir = self.tmp_dir / ".ralph-workspace" / "runtime-config" / self.plan_key
        logs_dir = self.tmp_dir / ".ralph-workspace" / "logs" / self.plan_key
        logs_dir.mkdir(parents=True, exist_ok=True)

        self._write_jsonl(
            state_dir / "bash-compact.jsonl",
            runtime_cfg["bash_compact_records"],
        )
        self._write_jsonl(
            state_dir / "proxy-shell-compact.jsonl",
            runtime_cfg["proxy_shell_compact_records"],
        )
        self._write_jsonl(
            state_dir / "result-windowing.jsonl",
            runtime_cfg["result_windowing_records"],
        )

        summaries_dir = state_dir / "summaries"
        summaries_dir.mkdir(parents=True, exist_ok=True)
        for runtime, summary in runtime_cfg["per_runtime_summaries"].items():
            (summaries_dir / f"{runtime}.json").write_text(
                json.dumps(summary), encoding="utf-8"
            )

        (logs_dir / "plan-usage-summary.json").write_text(
            json.dumps(manifest["plan_usage_summary"]), encoding="utf-8"
        )
        (logs_dir / "invocation-usage.json").write_text(
            json.dumps({"invocations": manifest["invocations"]}), encoding="utf-8"
        )

        self.state_dir = state_dir
        self.logs_dir = logs_dir
        self.summary_path = logs_dir / "plan-usage-summary.json"

    @staticmethod
    def _channel_slice(
        channels: dict[str, Any], channel_name: str
    ) -> dict[str, Any]:
        bucket = channels.get(channel_name) or {}
        out: dict[str, Any] = {
            "saved_bytes": bucket.get("saved_bytes", 0),
            "attribution": bucket.get("attribution", "exact"),
        }
        for key in ("gross_readback_bytes", "net_consumed_bytes"):
            if key in bucket:
                out[key] = bucket[key]
        return out

    def _assert_channels_match_expected(
        self,
        channels: dict[str, Any],
        *,
        source: str,
        include_readback_diagnostics: bool = False,
    ) -> None:
        expected = self.manifest["expected_per_channel"]
        for channel_name, want in expected.items():
            got = self._channel_slice(channels, channel_name)
            for key, value in want.items():
                if key in ("gross_readback_bytes", "net_consumed_bytes") and not include_readback_diagnostics:
                    continue
                self.assertEqual(
                    got.get(key),
                    value,
                    msg=f"{source} channel {channel_name}.{key}",
                )

    def test_overlay_aggregate_matches_runtime_config_telemetry(self) -> None:
        aggregate = OVERLAY_FIELDS.merge_runtime_overlay_summaries(
            str(self.state_dir), plan_key=self.plan_key
        )
        self.assertEqual(aggregate["plan_key"], self.plan_key)
        self.assertEqual(sorted(aggregate["runtimes_present"]), ["cursor", "opencode"])
        self.assertIn("byte_savings_by_channel", aggregate)
        self.assertIn("native_result_hook", aggregate["native_optimization_proven_channels"])
        self.assertIn("proxy_read_windowing", aggregate["native_optimization_proven_channels"])
        self._assert_channels_match_expected(
            aggregate["byte_savings_by_channel"], source="overlay aggregate"
        )

    def test_benchmark_discover_and_markdown_agree_on_channel_attribution(self) -> None:
        overlay = OVERLAY_FIELDS.merge_runtime_overlay_summaries(
            str(self.state_dir), plan_key=self.plan_key
        )
        overlay_channels = overlay["byte_savings_by_channel"]

        benchmark = SAVINGS_REPORT.build_report([str(self.summary_path)])
        self.assertIn("per_channel", benchmark)
        self._assert_channels_match_expected(benchmark["per_channel"], source="benchmark", include_readback_diagnostics=True)

        discover = DISCOVER_REPORT.build_discover_report(
            {"invocations": self.manifest["invocations"]},
            plan_key=self.plan_key,
        )
        self._assert_channels_match_expected(
            discover["byte_savings_by_channel"], source="discover"
        )

        markdown = RENDER_MARKDOWN.render_markdown(benchmark)
        for needle in self.manifest["expected_markdown_contains"]:
            self.assertIn(needle, markdown, msg=f"missing markdown: {needle!r}")

        expected_discover = self.manifest["expected_discover"]
        if expected_discover.get("missed_compaction_opportunities_empty"):
            self.assertEqual(discover["missed_compaction_opportunities"], [])
        if expected_discover.get("has_meaningful_savings"):
            self.assertTrue(discover["optimization_evidence"]["has_meaningful_savings"])
        if expected_discover.get("cursor_heavy_native_read_mix"):
            cursor_discover = DISCOVER_REPORT.build_discover_report(
                {"invocations": [self.manifest["invocations"][0]]},
                plan_key=self.plan_key,
            )
            diagnostics = cursor_discover["tool_adoption_diagnostics"]
            self.assertTrue(diagnostics["heavy_native_read_mix"])
            self.assertEqual(
                diagnostics["heavy_native_read_mix"][0]["pattern_id"],
                expected_discover["cursor_heavy_native_pattern_id"],
            )

        for channel_name in self.manifest["expected_per_channel"]:
            overlay_slice = self._channel_slice(overlay_channels, channel_name)
            benchmark_slice = self._channel_slice(benchmark["per_channel"], channel_name)
            discover_slice = self._channel_slice(
                discover["byte_savings_by_channel"], channel_name
            )
            for key in ("saved_bytes", "attribution"):
                self.assertEqual(overlay_slice.get(key), benchmark_slice.get(key), msg=channel_name)
                self.assertEqual(overlay_slice.get(key), discover_slice.get(key), msg=channel_name)
