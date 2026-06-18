#!/usr/bin/env python3
"""Unit tests for render-benchmark-markdown.py."""

from __future__ import annotations

import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))

from ralph_script_loader import load_ralph_script

render_module = load_ralph_script("render-benchmark-markdown")
render_markdown = render_module.render_markdown

PLAIN_LABELS = [
    "Shortened commands before running them",
    "Trimmed long command output",
    "Trimmed long command output (proxy mode)",
    "Sent only the relevant slice of big results",
]

INTERNAL_PATH_NAMES = [
    "pre_tool_rewrite",
    "hook_compaction",
    "proxy_shell_compaction",
    "result_windowing",
]


def _sample_report(**overrides: object) -> dict:
    report: dict = {
        "schema_version": 2,
        "run_count": 2,
        "saved_bytes": 150,
        "saved_tokens": 38,
        "savings_percent": 25.5,
        "date_range": {
            "started_at": "2026-01-01T00:00:00Z",
            "ended_at": "2026-01-02T00:00:00Z",
        },
        "session_usage": {
            "input_tokens": 1200,
            "output_tokens": 180,
            "cache_creation_input_tokens": 100,
            "cache_read_input_tokens": 300,
            "prompt_bytes": 1400,
            "tool_calls_total": 42,
        },
        "tool_output_counterfactual": {
            "hypothetical_without_ralph_bytes": 600,
            "actual_with_ralph_bytes": 450,
            "net_savings_bytes": 150,
            "hypothetical_without_ralph_tokens": 150,
            "actual_with_ralph_tokens": 112,
            "net_savings_tokens": 38,
            "net_savings_percent": 25.0,
            "compaction_measured_not_applied_bytes": 13,
            "compaction_measured_not_applied_tokens": 3,
        },
        "per_path": {
            "pre_tool_rewrite": {
                "pre_optimization_bytes": 100,
                "post_optimization_bytes": 60,
                "saved_bytes": 40,
                "count": 1,
                "pre_optimization_tokens": 25,
                "post_optimization_tokens": 15,
                "saved_tokens": 10,
                "token_cap_triggers": 0,
                "status": "saved",
                "status_label": "saved",
            },
            "hook_compaction": {
                "pre_optimization_bytes": 200,
                "post_optimization_bytes": 150,
                "saved_bytes": 50,
                "count": 1,
                "pre_optimization_tokens": 50,
                "post_optimization_tokens": 38,
                "saved_tokens": 12,
                "token_cap_triggers": 1,
                "hidden_from_context": 50,
                "hidden_from_context_tokens": 12,
                "status": "saved",
                "status_label": "saved",
                "gross_hidden_bytes": 50,
                "gross_hidden_tokens": 12,
            },
            "proxy_shell_compaction": {
                "pre_optimization_bytes": 200,
                "post_optimization_bytes": 150,
                "saved_bytes": 50,
                "count": 1,
                "pre_optimization_tokens": 50,
                "post_optimization_tokens": 38,
                "saved_tokens": 12,
                "token_cap_triggers": 0,
                "hidden_from_context": 50,
                "hidden_from_context_tokens": 12,
                "status": "saved",
                "status_label": "saved",
                "gross_hidden_bytes": 50,
                "gross_hidden_tokens": 12,
                "compaction_measured_not_applied_bytes": 13,
            },
            "result_windowing": {
                "pre_optimization_bytes": 1000,
                "post_optimization_bytes": 1000,
                "saved_bytes": 0,
                "count": 1,
                "pre_optimization_tokens": 250,
                "post_optimization_tokens": 250,
                "saved_tokens": 0,
                "token_cap_triggers": 0,
                "hidden_from_context": 0,
                "hidden_from_context_tokens": 0,
                "status": "negated",
                "status_label": "negated by readback",
                "gross_hidden_bytes": 0,
                "gross_hidden_tokens": 0,
                "gross_readback_bytes": 1400,
                "gross_readback_tokens": 350,
                "net_readback_cost_bytes": 1000,
                "effective_windowing_savings_rate": 0.0,
            },
        },
        "readback_summary": {
            "envelope_count": 1,
            "readback_count": 2,
            "raw_readback_count": 1,
            "compacted_readback_count": 1,
            "readback_bytes": 1400,
            "envelope_original_bytes": 1000,
            "full_preview_rereads": 1,
            "raw_readback_share": 0.5,
            "readback_negation_rate": 1.4,
            "gross_readback_bytes": 1400,
            "gross_readback_tokens": 350,
            "net_consumed_bytes": 1000,
            "net_consumed_tokens": 250,
            "effective_windowing_savings_rate": 0.0,
        },
        "cache": {
            "cache_read_tokens": 400,
            "cache_hit_ratio": 0.25,
        },
        "could_have_saved": {
            "compaction_measured_not_applied_bytes": 13,
        },
        "skipped_summaries": 1,
        "runs_count": 2,
        "runs": [
            {
                "id": "run-a",
                "started_at": "2026-01-01T00:00:00Z",
                "ended_at": "2026-01-01T00:05:00Z",
                "saved_bytes": 90,
                "saved_tokens": 22,
                "pre_optimization_bytes": 300,
                "savings_percent": 30.0,
                "per_path": {},
                "tool_output_counterfactual": {},
                "session_usage": {},
            },
            {
                "id": "run-b",
                "started_at": "2026-01-02T00:00:00Z",
                "ended_at": "2026-01-02T00:05:00Z",
                "saved_bytes": 60,
                "saved_tokens": 16,
                "pre_optimization_bytes": 300,
                "savings_percent": 20.0,
                "per_path": {},
                "tool_output_counterfactual": {},
                "session_usage": {},
            },
        ],
    }
    report.update(overrides)
    return report


class TestRenderBenchmarkMarkdown(unittest.TestCase):
    """Verify benchmark markdown matches schema v2 headings and tables."""

    def test_render_markdown_v2_sections_and_tables(self) -> None:
        output = render_markdown(_sample_report())

        self.assertIn("# Ralph Savings Report", output)
        self.assertIn("## Session usage", output)
        self.assertIn("## Tool output: with vs without Ralph", output)
        self.assertIn("## Savings by path", output)
        self.assertIn("## Stored result follow-ups", output)
        self.assertIn("## How to read this", output)
        self.assertIn("## Data quality", output)

        for label in PLAIN_LABELS:
            with self.subTest(label=label):
                self.assertIn(label, output)

        for path_name in INTERNAL_PATH_NAMES:
            with self.subTest(path_name=path_name):
                self.assertNotIn(path_name, output)

        # Session table shows actual billed tokens and prompt/tool metrics.
        self.assertIn("| Input tokens | 1,200 |", output)
        self.assertIn("| Output tokens | 180 |", output)
        self.assertIn("| Cache read input tokens | 300 |", output)
        self.assertIn("| Prompt bytes | 1,400 |", output)
        self.assertIn("| Tool calls total | 42 |", output)

        # Counterfactual table uses schema v2 fields.
        self.assertIn("| Hypothetical without Ralph | 600 | 150 |", output)
        self.assertIn("| Actual with Ralph | 450 | 112 |", output)
        self.assertIn("| Net savings | 150 | 38 |", output)
        self.assertIn("| Net savings rate | 25.0% | - |", output)
        self.assertIn("**Measured but not applied:** 13 bytes", output)

        # Per-path table uses Pre/Post/Saved/Status.
        self.assertIn("| Pre bytes | Post bytes | Saved bytes | Saved tokens |", output)
        self.assertIn("| Shortened commands before running them | saved | 100 | 60 | 40 | 10 |", output)
        self.assertIn("| Sent only the relevant slice of big results | negated by readback | 1,000 | 1,000 | 0 | 0 |", output)
        self.assertIn("| **Total** | **-** | **-** | **-** | **150** | **38** |", output)

        # Readback section distinguishes gross vs net and uses effective rate.
        self.assertIn("Effective windowing savings rate: **0.0%**", output)
        self.assertIn("Gross follow-up reads: **1,400 bytes**", output)
        self.assertIn("net consumed: **1,000 bytes**", output)
        self.assertIn("diagnostic gross negation rate: **140.0%**", output)

    def test_no_root_causes_when_net_savings_are_high(self) -> None:
        output = render_markdown(_sample_report())
        self.assertNotIn("## Why savings are low", output)

    def test_root_causes_when_net_savings_near_zero(self) -> None:
        report = _sample_report(
            saved_bytes=0,
            saved_tokens=0,
            savings_percent=0.0,
            tool_output_counterfactual={
                "hypothetical_without_ralph_bytes": 1000,
                "actual_with_ralph_bytes": 1000,
                "net_savings_bytes": 0,
                "hypothetical_without_ralph_tokens": 250,
                "actual_with_ralph_tokens": 250,
                "net_savings_tokens": 0,
                "net_savings_percent": 0.0,
                "compaction_measured_not_applied_bytes": 13,
            },
        )
        # Mark non-windowing paths inactive so root-cause diagnostics surface them.
        for path_name in ("pre_tool_rewrite", "hook_compaction", "proxy_shell_compaction"):
            bucket = report["per_path"][path_name]
            bucket["status"] = "inactive"
            bucket["status_label"] = "inactive"
            bucket["pre_optimization_bytes"] = 0
            bucket["post_optimization_bytes"] = 0
            bucket["saved_bytes"] = 0
            bucket["count"] = 0
        output = render_markdown(report)
        self.assertIn("## Why savings are low", output)
        self.assertIn("was inactive for this workspace mode", output)
        self.assertIn("Result-windowing savings were negated by readback", output)
        self.assertIn("Native compaction was measured but not applied", output)
        self.assertIn("13 bytes", output)

    def test_root_causes_with_optimization_opportunities(self) -> None:
        report = _sample_report(
            saved_bytes=0,
            saved_tokens=0,
            savings_percent=0.0,
            tool_output_counterfactual={
                "hypothetical_without_ralph_bytes": 1000,
                "actual_with_ralph_bytes": 1000,
                "net_savings_bytes": 0,
                "hypothetical_without_ralph_tokens": 250,
                "actual_with_ralph_tokens": 250,
                "net_savings_tokens": 0,
                "net_savings_percent": 0.0,
                "compaction_measured_not_applied_bytes": 0,
            },
            optimization_opportunities={
                "missed_compaction_opportunities": [
                    {"original_bytes": 5000, "skip_reason": "native shell output not compacted"},
                ],
                "sequence_patterns": [
                    {"pattern_id": "repeated_native_read_like", "count": 3},
                    {"pattern_id": "native_read_after_grep", "count": 2},
                ],
                "stored_result_usage": {
                    "recommendation": "Prefer compacted result reads before raw views.",
                },
            },
        )
        output = render_markdown(report)
        self.assertIn("## Why savings are low", output)
        self.assertIn("## Improvement opportunities", output)
        self.assertIn("Discover opportunity", output)
        self.assertIn("native shell output not compacted", output)
        self.assertIn("repeated_native_read_like", output)
        self.assertIn("Prefer compacted result reads before raw views.", output)

    def test_skipped_summaries_surfaced(self) -> None:
        report = _sample_report(skipped_summaries=2)
        output = render_markdown(report)
        self.assertIn("## Data quality", output)
        self.assertIn("Skipped", output)
        self.assertIn("2", output)

    def test_legacy_v1_report_renders_without_counterfactual(self) -> None:
        """A schema v1 report without tool_output_counterfactual still renders."""
        output = render_markdown(
            {
                "saved_bytes": 100,
                "saved_tokens": 25,
                "savings_percent": 20.0,
                "run_count": 1,
                "per_path": {},
                "runs": [],
            }
        )
        self.assertIn("# Ralph Savings Report", output)
        self.assertNotIn("## Session usage", output)
        self.assertNotIn("## Tool output: with vs without Ralph", output)
        self.assertIn("## Savings by path", output)


if __name__ == "__main__":
    unittest.main()
