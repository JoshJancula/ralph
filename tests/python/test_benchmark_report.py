#!/usr/bin/env python3
"""Unit tests for ralph-benchmark-report.py."""

from __future__ import annotations

import json
import shutil
import tempfile
import unittest
from pathlib import Path
from typing import Any

from ralph_script_loader import load_ralph_script


SAVINGS_REPORT = load_ralph_script("ralph-benchmark-report")
DISCOVER_REPORT = load_ralph_script("ralph-discover-report")


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

    def test_multi_readback_gross_exceeds_one_but_net_savings_is_zero(self) -> None:
        """Gross readback can exceed 100%; the report reports net savings as primary."""
        from tool_call_target_telemetry import analyze_result_windowing_log

        run_dir = self.tmp_dir / "multi_readback"
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

        # Write a result-windowing log adjacent to the summary.
        # _windowing_log_for_summary looks at ../runtime-config/<plan>/result-windowing.jsonl
        # relative to the summary's parent. Build that directory tree.
        plan_key = run_dir.name
        # _windowing_log_for_summary calls .resolve() on the summary path, so on
        # macOS the runtime-config tree must be built under the resolved tmp_dir.
        runtime_config_dir = self.tmp_dir.resolve() / "runtime-config" / plan_key
        runtime_config_dir.mkdir(parents=True, exist_ok=True)
        log_path = runtime_config_dir / "result-windowing.jsonl"
        with log_path.open("w", encoding="utf-8") as handle:
            for record in [
                {"event": "envelope", "resultId": "r1",
                 "originalBytes": 1000, "returnedBytes": 100},
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

        # The benchmark report surfaces effective_windowing_savings_rate as the
        # primary signal and caps net consumed bytes at original bytes.
        self.assertEqual(report["per_path"]["result_windowing"]["saved_bytes"], 0)
        self.assertEqual(
            report["per_path"]["result_windowing"]["status"], "negated"
        )
        self.assertEqual(report["saved_bytes"], 0)
        readback = report["readback_summary"]
        self.assertGreater(readback["readback_negation_rate"], 1.0)
        self.assertEqual(readback["effective_windowing_savings_rate"], 0.0)
        self.assertEqual(readback["net_consumed_bytes"], 1000)
        self.assertEqual(readback["gross_readback_bytes"], 1400)
        self.assertEqual(
            report["tool_output_counterfactual"]["net_savings_bytes"], 0
        )
        self.assertEqual(
            report["tool_output_counterfactual"]["net_savings_percent"], 0.0
        )

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
            "saved_bytes": 1180,
            "session_usage": {
                "input_tokens": 800,
                "output_tokens": 100,
                "cache_creation_input_tokens": 50,
                "cache_read_input_tokens": 150,
                "prompt_bytes": 960,
                "tool_calls_total": 24,
            },
            "tool_output_counterfactual": {
                "hypothetical_without_ralph_bytes": 1900,
                "actual_with_ralph_bytes": 870,
                "net_savings_bytes": 1180,
                "net_savings_percent": 62.1,
                "compaction_measured_not_applied_bytes": 64,
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
        # The aggregate report uses explicit windowing totals (original=1000,
        # returned=200) for the counterfactual, so the readback cost is already
        # folded into returned_bytes and actual_with_ralph stays at 720.
        self.assertEqual(counterfactual["actual_with_ralph_bytes"], 720)
        self.assertEqual(counterfactual["net_savings_bytes"], 1180)
        self.assertEqual(counterfactual["net_savings_percent"], 62.1)
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
