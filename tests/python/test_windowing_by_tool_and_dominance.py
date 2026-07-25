#!/usr/bin/env python3
"""Unit tests for PLAN15: windowing-by-source-tool aggregation, source-cap
operational summary, and single-event dominance flagging (data layer and
rendering).
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
RENDER = load_ralph_script("render-benchmark-markdown")


class TestWindowingBySourceTool(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp_dir = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.tmp_dir, ignore_errors=True)

    def _write(self, records: list[dict[str, Any]]) -> str:
        path = self.tmp_dir / "result-windowing.jsonl"
        with open(path, "w", encoding="utf-8") as fh:
            for record in records:
                fh.write(json.dumps(record) + "\n")
        return str(path)

    def test_two_tools_one_readback_one_source_capped_one_legacy(self) -> None:
        path = self._write([
            {
                "event": "envelope", "toolName": "Read", "resultId": "a" * 16,
                "measurementVersion": 2, "originalBytes": 5000, "returnedBytes": 500,
                "inlineCandidateBytes": 4800, "inlineCandidateTokens": 1200,
                "deliveredBytes": 600, "deliveredTokens": 150,
            },
            {
                "event": "readback", "toolName": "Read", "resultId": "a" * 16,
                "view": "raw", "returnedBytes": 4800, "returnedTokens": 1200,
            },
            {
                "event": "envelope", "toolName": "Grep", "resultId": "b" * 16,
                "measurementVersion": 2, "originalBytes": 60000, "returnedBytes": 6000,
                "sourceCapped": True, "capReason": "byte_cap", "capLimitBytes": 262144,
                "storedBytes": 60000,
                "inlineCandidateBytes": 14000, "inlineCandidateTokens": 3500,
                "deliveredBytes": 6500, "deliveredTokens": 1600,
            },
            {
                "event": "envelope", "toolName": "Glob", "resultId": "c" * 16,
                "originalBytes": 3000, "returnedBytes": 300,
                "originalTokens": 750, "returnedTokens": 75,
            },
        ])

        by_tool = METRICS.aggregate_windowing_by_source_tool(path)
        self.assertEqual(set(by_tool.keys()), {"Read", "Grep", "Glob"})

        self.assertEqual(by_tool["Read"]["events"], 1)
        # Preview (600) plus a full raw readback (4800) against a 4800-byte inline
        # candidate: 5400 consumed, uncapped, so windowing lost 600 bytes here.
        self.assertEqual(by_tool["Read"]["net_consumed_bytes"], 5400)
        self.assertEqual(by_tool["Read"]["net_saved_bytes"], -600)
        self.assertEqual(by_tool["Read"]["measurement_quality"], "v2_measured")

        self.assertEqual(by_tool["Grep"]["source_capped_count"], 1)
        self.assertEqual(by_tool["Grep"]["inline_candidate_bytes"], 14000)

        self.assertEqual(by_tool["Glob"]["measurement_quality"], "legacy_storage_counterfactual")

    def test_envelope_overhead_reports_negative_savings_with_no_readback(self) -> None:
        """An envelope bigger than the output it wraps is a loss, not a wash.

        This is the PLAN23 defect: the inline candidate already fit under the
        byte cap, so windowing it only added envelope scaffolding. No readback is
        involved -- the delivered envelope alone costs more than inlining would
        have, and every layer must carry the negative through.
        """
        path = self._write([
            {
                "event": "envelope", "toolName": "Grep", "resultId": "f" * 16,
                "measurementVersion": 2,
                "originalBytes": 640000, "returnedBytes": 6400,
                "inlineCandidateBytes": 6400, "inlineCandidateTokens": 1600,
                "deliveredBytes": 7555, "deliveredTokens": 1889,
            },
        ])

        by_tool = METRICS.aggregate_windowing_by_source_tool(path)
        self.assertEqual(by_tool["Grep"]["inline_candidate_bytes"], 6400)
        self.assertEqual(by_tool["Grep"]["delivered_bytes"], 7555)
        self.assertEqual(by_tool["Grep"]["net_consumed_bytes"], 7555)
        self.assertEqual(by_tool["Grep"]["net_saved_bytes"], -1155)

        totals = METRICS.aggregate_windowing_savings(path)["total"]
        self.assertEqual(totals["saved_bytes"], -1155)

    def test_markdown_renders_negative_channel_savings(self) -> None:
        """A losing channel must render as a negative number, never as a blank."""
        markdown = RENDER.render_markdown(
            {
                "run_count": 1,
                "windowing_by_source_tool": {
                    "ralph_proxy_grep": {
                        "events": 1,
                        "inline_candidate_bytes": 6400,
                        "delivered_bytes": 7555,
                        "net_consumed_bytes": 7555,
                        "net_saved_bytes": -1155,
                        "source_capped_count": 0,
                        "measurement_quality": "v2_measured",
                    }
                },
                "tool_output_counterfactual": {
                    "hypothetical_without_ralph_bytes": 6400,
                    "actual_with_ralph_bytes": 7555,
                    "net_savings_bytes": -1155,
                    "net_savings_tokens": -289,
                    "net_savings_percent": -18.0,
                },
            }
        )
        self.assertIn("-1,155", markdown)
        self.assertIn("cost 1,155 bytes", markdown)
        self.assertIn("-18.0%", markdown)

    def test_source_cap_operational_summary_never_estimates_avoided_bytes(self) -> None:
        path = self._write([
            {
                "event": "envelope", "toolName": "Grep", "resultId": "d" * 16,
                "sourceCapped": True, "capReason": "line_cap", "capLimitBytes": 262144,
                "storedBytes": 200000,
            },
            {
                "event": "envelope", "toolName": "Grep", "resultId": "e" * 16,
                "sourceCapped": True, "capReason": "byte_cap", "capLimitBytes": 262144,
                "storedBytes": 262144,
            },
        ])
        summary = METRICS.aggregate_source_cap_operational_summary(path)
        self.assertEqual(summary["capped_event_count"], 2)
        self.assertEqual(summary["stored_bytes_total"], 462144)
        self.assertEqual(summary["cap_reasons"], {"line_cap": 1, "byte_cap": 1})
        self.assertNotIn("avoided_bytes", summary)
        self.assertNotIn("avoided_tokens", summary)

    def test_uncapped_only_fixture_has_zero_capped_events(self) -> None:
        path = self._write([
            {
                "event": "envelope", "toolName": "Read", "resultId": "f" * 16,
                "originalBytes": 1000, "returnedBytes": 100,
            },
        ])
        summary = METRICS.aggregate_source_cap_operational_summary(path)
        self.assertEqual(summary["capped_event_count"], 0)


class TestDominanceRendering(unittest.TestCase):
    def _report(self, **overrides):
        report = {
            "schema_version": 2, "run_count": 1, "optimization_events_total": 0,
            "date_range": {"started_at": None, "ended_at": None},
            "saved_bytes": 0, "saved_tokens": 0, "savings_percent": 0,
            "session_usage": {"tool_calls_total": 0},
            "tool_output_counterfactual": {}, "per_path": {}, "per_channel": {},
            "runs": [], "skipped_summaries": 0, "telemetry_unattributed": [],
            "hook_config_by_runtime": {}, "windowing_by_source_tool": {},
            "source_cap_operational_summary": {"capped_event_count": 0, "stored_bytes_total": 0,
                                                "cap_reasons": {}, "configured_limits_bytes": []},
            "dominance_warning": None,
        }
        report.update(overrides)
        return report

    def test_dominant_event_renders_caution_with_tool_share_and_quality(self) -> None:
        report = self._report(
            dominance_warning={
                "surfaced_tool": "Grep", "share": 0.91, "net_saved_bytes": 91000,
                "measurement_quality": "v2_measured", "threshold": 0.5,
            }
        )
        md = RENDER.render_markdown(report)
        self.assertIn("Caution", md)
        self.assertIn("Grep", md)
        self.assertIn("91.0%", md)

    def test_no_dominance_warning_renders_nothing(self) -> None:
        report = self._report(dominance_warning=None)
        md = RENDER.render_markdown(report)
        self.assertNotIn("Caution", md)

    def test_windowing_by_source_tool_table_renders(self) -> None:
        report = self._report(
            windowing_by_source_tool={
                "Read": {"events": 3, "inline_candidate_bytes": 9000, "delivered_bytes": 1500,
                         "net_consumed_bytes": 1500, "net_saved_bytes": 7500,
                         "source_capped_count": 0, "measurement_quality": "v2_measured"},
            }
        )
        md = RENDER.render_markdown(report)
        self.assertIn("## Result windowing by source tool", md)
        self.assertIn("Read", md)
        self.assertIn("7,500", md)

    def test_source_cap_summary_renders_without_avoided_byte_claim(self) -> None:
        report = self._report(
            source_cap_operational_summary={
                "capped_event_count": 2, "stored_bytes_total": 400000,
                "cap_reasons": {"byte_cap": 2}, "configured_limits_bytes": [262144],
            }
        )
        md = RENDER.render_markdown(report)
        self.assertIn("## Source-capped search operations", md)
        self.assertIn("are unknown", md)
        # No numeric avoided-byte/avoided-token claim anywhere in the section.
        self.assertNotRegex(md, r"avoided[^.]*\d")


if __name__ == "__main__":
    unittest.main()
