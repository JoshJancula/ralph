#!/usr/bin/env python3
"""Unit tests for PLAN15 render additions: token-quality labeling, the
data-quality section, the event-observability line, and hook status by
runtime.
"""

from __future__ import annotations

import unittest

from ralph_script_loader import load_ralph_script


RENDER = load_ralph_script("render-benchmark-markdown")


def _base_report(**overrides):
    report = {
        "schema_version": 2,
        "run_count": 1,
        "optimization_events_total": 0,
        "date_range": {"started_at": None, "ended_at": None},
        "saved_bytes": 0,
        "saved_tokens": 0,
        "savings_percent": 0,
        "session_usage": {"tool_calls_total": 0},
        "tool_output_counterfactual": {},
        "per_path": {},
        "per_channel": {},
        "runs": [],
        "skipped_summaries": 0,
        "telemetry_unattributed": [],
        "hook_config_by_runtime": {},
    }
    report.update(overrides)
    return report


class TestEventObservabilityLine(unittest.TestCase):
    def test_line_shows_events_and_calls_with_no_coverage_percentage(self) -> None:
        report = _base_report(
            optimization_events_total=7,
            session_usage={"tool_calls_total": 42},
        )
        md = RENDER.render_markdown(report)
        self.assertIn("Ralph recorded 7 optimization events across 42 tool calls", md)
        self.assertIn("not unique-call coverage", md)
        self.assertNotRegex(md, r"7\s*/\s*42|16\.\d%|coverage.*%")

    def test_zero_events_and_zero_calls_render_cleanly(self) -> None:
        report = _base_report(optimization_events_total=0, session_usage={"tool_calls_total": 0})
        md = RENDER.render_markdown(report)
        self.assertIn("Ralph recorded 0 optimization events across 0 tool calls", md)


class TestTokenQualityLabel(unittest.TestCase):
    def test_measured_quality_does_not_claim_universal_4_bytes_per_token(self) -> None:
        report = _base_report(
            tool_output_counterfactual={
                "hypothetical_without_ralph_bytes": 1000,
                "actual_with_ralph_bytes": 200,
                "net_savings_bytes": 800,
                "hypothetical_without_ralph_tokens": 250,
                "actual_with_ralph_tokens": 50,
                "net_savings_tokens": 200,
                "net_savings_percent": 80.0,
                "token_quality": "measured",
            }
        )
        md = RENDER.render_markdown(report)
        self.assertNotIn("roughly 4 bytes per token", md)
        self.assertIn("dependency-free token estimator", md)

    def test_legacy_quality_is_labeled_and_points_to_data_quality(self) -> None:
        report = _base_report(
            tool_output_counterfactual={
                "hypothetical_without_ralph_bytes": 1000,
                "actual_with_ralph_bytes": 200,
                "net_savings_bytes": 800,
                "hypothetical_without_ralph_tokens": 250,
                "actual_with_ralph_tokens": 50,
                "net_savings_tokens": 200,
                "net_savings_percent": 80.0,
                "token_quality": "legacy_or_mixed",
            }
        )
        md = RENDER.render_markdown(report)
        self.assertIn("bytes/4-equivalent fallback", md)
        self.assertIn("## Data quality", md)


class TestDataQualitySection(unittest.TestCase):
    def test_unattributed_telemetry_rendered_as_diagnostics_not_savings(self) -> None:
        report = _base_report(
            telemetry_unattributed=[
                {"logKind": "bash_compact", "observedKey": "bash-hook", "fallback": True, "count": 1, "bytes": 500},
                {"logKind": "bash_compact", "observedKey": "nested-plan", "fallback": False, "count": 1, "bytes": 700},
            ],
        )
        md = RENDER.render_markdown(report)
        self.assertIn("## Data quality", md)
        self.assertIn("2** unattributed telemetry group", md)
        self.assertIn("bash-hook", md)
        self.assertIn("nested-plan", md)

    def test_skipped_summaries_surfaced_in_data_quality(self) -> None:
        report = _base_report(skipped_summaries=3)
        md = RENDER.render_markdown(report)
        self.assertIn("## Data quality", md)
        self.assertIn("3** run summary file(s)", md)

    def test_clean_fixture_has_no_data_quality_section(self) -> None:
        report = _base_report(
            tool_output_counterfactual={
                "hypothetical_without_ralph_bytes": 1000,
                "actual_with_ralph_bytes": 200,
                "net_savings_bytes": 800,
                "hypothetical_without_ralph_tokens": 250,
                "actual_with_ralph_tokens": 50,
                "net_savings_tokens": 200,
                "net_savings_percent": 80.0,
                "token_quality": "measured",
            },
            skipped_summaries=0,
            telemetry_unattributed=[],
        )
        md = RENDER.render_markdown(report)
        self.assertNotIn("## Data quality", md)


class TestHookStatusByRuntime(unittest.TestCase):
    def test_enabled_disabled_mixed_and_two_runtimes_rendered_with_reasons(self) -> None:
        report = _base_report(
            hook_config_by_runtime={
                "claude": {
                    "bash_compact": {"status": "enabled", "reasons": ["proven_channel:mode_default"]},
                    "native_result_compact": {"status": "mixed", "reasons": ["gate_disabled", "proven_channel:mode_default"]},
                },
                "opencode": {
                    "proxy_shell_compact": {"status": "disabled", "reasons": ["gate_disabled"]},
                },
            }
        )
        md = RENDER.render_markdown(report)
        self.assertIn("## Hook status by runtime", md)
        self.assertIn("claude", md)
        self.assertIn("opencode", md)
        self.assertIn("enabled", md)
        self.assertIn("mixed", md)
        self.assertIn("disabled", md)
        self.assertIn("proven_channel:mode_default", md)

    def test_legacy_run_with_no_hook_config_shows_unknown_no_record(self) -> None:
        report = _base_report(hook_config_by_runtime={})
        report["hook_config_by_runtime"] = None
        md = RENDER.render_markdown(report)
        self.assertIn("unknown (no config record)", md)

    def test_zero_channels_enabled_are_distinguished_from_disabled(self) -> None:
        report = _base_report(
            hook_config_by_runtime={
                "claude": {"bash_compact": {"status": "enabled", "reasons": []}},
            }
        )
        md = RENDER.render_markdown(report)
        self.assertIn("| claude | bash_compact | enabled |", md)


if __name__ == "__main__":
    unittest.main()
