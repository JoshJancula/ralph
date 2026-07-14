#!/usr/bin/env python3
"""Unit tests: _build_tool_output_counterfactual uses per-path token totals,
not bytes-divided-by-four, when v2 token data is present (PLAN15).
"""

from __future__ import annotations

import unittest
from unittest import mock

from ralph_script_loader import load_ralph_script


REPORT = load_ralph_script("ralph-benchmark-report")


def _bucket(pre_bytes, post_bytes, pre_tokens, post_tokens):
    bucket = {
        "pre_optimization_bytes": pre_bytes,
        "post_optimization_bytes": post_bytes,
        "saved_bytes": pre_bytes - post_bytes,
        "pre_optimization_tokens": pre_tokens,
        "post_optimization_tokens": post_tokens,
        "saved_tokens": pre_tokens - post_tokens,
        "count": 1,
    }
    return bucket


class TestToolOutputCounterfactualV2(unittest.TestCase):
    def test_headline_uses_per_path_token_sums_with_non_4to1_ratios(self) -> None:
        # Deliberately non-4:1 byte/token ratios (e.g. 10:1 and 2:1) so a
        # bytes/4 computation would produce a different answer than summing
        # the actual per-path token totals.
        per_path = {name: REPORT.empty_savings_bucket() for name in REPORT.SAVINGS_PATH_NAMES}
        per_path["hook_compaction"] = _bucket(10000, 1000, 1000, 100)  # 10:1 ratio
        per_path["proxy_shell_compaction"] = _bucket(4000, 2000, 2000, 1000)  # 2:1 ratio

        result = REPORT._build_tool_output_counterfactual(per_path, 0)

        expected_pre_tokens = 1000 + 2000
        expected_post_tokens = 100 + 1000
        self.assertEqual(result["hypothetical_without_ralph_tokens"], expected_pre_tokens)
        self.assertEqual(result["actual_with_ralph_tokens"], expected_post_tokens)
        self.assertEqual(result["token_quality"], "measured")

    def test_does_not_call_estimate_tokens_from_bytes_when_v2_token_data_present(self) -> None:
        per_path = {name: REPORT.empty_savings_bucket() for name in REPORT.SAVINGS_PATH_NAMES}
        per_path["hook_compaction"] = _bucket(10000, 1000, 1000, 100)

        with mock.patch.object(
            REPORT, "_estimate_tokens_from_bytes", wraps=REPORT._estimate_tokens_from_bytes
        ) as spy:
            REPORT._build_tool_output_counterfactual(per_path, 0)
            # The main hypothetical/actual token figures must come from the
            # per-path token totals, not a byte-derived estimate. (The
            # separate compaction_measured_not_applied_tokens field is an
            # inherently byte-only "opportunity" figure and may still call
            # this helper with its own, unrelated byte count.)
            called_with = [call.args[0] for call in spy.call_args_list]
            self.assertNotIn(10000, called_with)
            self.assertNotIn(1000, called_with)

    def test_all_zero_token_fixture_falls_back_to_byte_estimate_and_labels_legacy(self) -> None:
        per_path = {name: REPORT.empty_savings_bucket() for name in REPORT.SAVINGS_PATH_NAMES}
        per_path["hook_compaction"] = _bucket(10000, 1000, 0, 0)

        result = REPORT._build_tool_output_counterfactual(per_path, 0)
        self.assertGreater(result["hypothetical_without_ralph_tokens"], 0)
        self.assertEqual(result["token_quality"], "legacy_or_mixed")

    def test_arithmetic_reconciles_net_savings(self) -> None:
        per_path = {name: REPORT.empty_savings_bucket() for name in REPORT.SAVINGS_PATH_NAMES}
        per_path["hook_compaction"] = _bucket(10000, 1000, 1000, 100)

        result = REPORT._build_tool_output_counterfactual(per_path, 0)
        self.assertEqual(
            result["net_savings_bytes"],
            result["hypothetical_without_ralph_bytes"] - result["actual_with_ralph_bytes"],
        )
        self.assertEqual(
            result["net_savings_tokens"],
            result["hypothetical_without_ralph_tokens"] - result["actual_with_ralph_tokens"],
        )

    def test_windowing_token_fields_come_from_the_recomputed_bucket(self) -> None:
        # The counterfactual sources windowing from the per_path bucket, which is
        # recomputed from result-windowing.jsonl and whose post totals already
        # include readbacks. The summary's own windowing totals are no longer
        # consulted: they stop at the delivered preview and omit readback cost.
        per_path = {name: REPORT.empty_savings_bucket() for name in REPORT.SAVINGS_PATH_NAMES}
        per_path["result_windowing"] = _bucket(5000, 500, 1250, 125)

        result = REPORT._build_tool_output_counterfactual(per_path, 0)
        self.assertEqual(result["hypothetical_without_ralph_tokens"], 1250)
        self.assertEqual(result["actual_with_ralph_tokens"], 125)
        self.assertEqual(result["net_savings_bytes"], 4500)


if __name__ == "__main__":
    unittest.main()
