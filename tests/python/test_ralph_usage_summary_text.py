#!/usr/bin/env python3
"""Unit tests for the usage_unsupported n/a display path in ralph-usage-summary-text.py.

Antigravity invocations never carry real token/cache usage (agy has no
accessible telemetry for it); records for that runtime are marked
usage_unsupported. Buckets made up entirely of such records should report
n/a rather than a fabricated-looking zero, while buckets mixing antigravity
with a runtime that does report usage must keep summing normally.
"""

from __future__ import annotations

import unittest

from ralph_script_loader import load_ralph_script

usage_summary = load_ralph_script("ralph-usage-summary-text")


def _antigravity_record(tool_calls: int = 1) -> dict:
    return {
        "runtime": "antigravity",
        "model": "antigravity/test-model",
        "usage_unsupported": True,
        "input_tokens": 0,
        "output_tokens": 0,
        "cache_read_input_tokens": 0,
        "cache_creation_input_tokens": 0,
        "tool_calls_total": tool_calls,
    }


def _cursor_record(input_tokens: int = 100, output_tokens: int = 50) -> dict:
    return {
        "runtime": "cursor",
        "model": "composer-2.5",
        "input_tokens": input_tokens,
        "output_tokens": output_tokens,
        "cache_read_input_tokens": 10,
        "cache_creation_input_tokens": 5,
        "tool_calls_total": 2,
    }


class TestAllUnsupported(unittest.TestCase):
    def test_empty_records_not_unsupported(self) -> None:
        self.assertFalse(usage_summary.all_unsupported([]))

    def test_all_antigravity_records_are_unsupported(self) -> None:
        records = [_antigravity_record(), _antigravity_record()]
        self.assertTrue(usage_summary.all_unsupported(records))

    def test_mixed_records_are_not_unsupported(self) -> None:
        records = [_antigravity_record(), _cursor_record()]
        self.assertFalse(usage_summary.all_unsupported(records))

    def test_all_supported_records_are_not_unsupported(self) -> None:
        records = [_cursor_record(), _cursor_record()]
        self.assertFalse(usage_summary.all_unsupported(records))


class TestAggregateByModelUnsupportedFlag(unittest.TestCase):
    def test_pure_antigravity_bucket_flags_unsupported(self) -> None:
        grouped = usage_summary.aggregate_by_model(
            [_antigravity_record(), _antigravity_record()]
        )
        self.assertEqual(len(grouped), 1)
        _, agg, recs = grouped[0]
        self.assertTrue(agg["usage_unsupported"])
        self.assertEqual(len(recs), 2)

    def test_mixed_model_buckets_sum_correctly(self) -> None:
        grouped = usage_summary.aggregate_by_model(
            [_antigravity_record(), _cursor_record(), _cursor_record()]
        )
        by_model = {model: (agg, recs) for model, agg, recs in grouped}
        agg, recs = by_model["composer-2.5"]
        self.assertFalse(agg["usage_unsupported"])
        self.assertEqual(agg["input_tokens"], 200)
        self.assertEqual(agg["output_tokens"], 100)

        agg, recs = by_model["antigravity/test-model"]
        self.assertTrue(agg["usage_unsupported"])
        self.assertEqual(agg["input_tokens"], 0)


class TestAggregateByRuntimeModelUnsupportedFlag(unittest.TestCase):
    def test_pure_antigravity_pair_flags_unsupported(self) -> None:
        pairs = usage_summary.aggregate_by_runtime_model(
            [_antigravity_record(), _antigravity_record()]
        )
        self.assertEqual(len(pairs), 1)
        _, _, agg = pairs[0]
        self.assertTrue(agg["usage_unsupported"])

    def test_mixed_runtime_pairs_each_flagged_independently(self) -> None:
        pairs = usage_summary.aggregate_by_runtime_model(
            [_antigravity_record(), _cursor_record()]
        )
        flags = {runtime: agg["usage_unsupported"] for runtime, _, agg in pairs}
        self.assertTrue(flags["antigravity"])
        self.assertFalse(flags["cursor"])


if __name__ == "__main__":
    unittest.main()


class TestCacheWriteCostShare(unittest.TestCase):
    """Cache writes bill at ~1.25x and reads at ~0.1x, so the write premium is a
    large share of cost while being a small share of tokens. A high share means
    writes were never amortized (break-even is roughly two reads per write)."""

    def test_price_weighting_not_token_counts(self) -> None:
        # 100 writes at the 1h rate (200) vs 200 reads (20): a third of the
        # tokens, 91% of cost.
        self.assertEqual(usage_summary.cache_write_cost_share(200, 100, 0, 100), 91)

    def test_five_minute_ttl_is_cheaper_than_one_hour(self) -> None:
        five = usage_summary.cache_write_cost_share(200, 100, 100, 0)
        hour = usage_summary.cache_write_cost_share(200, 100, 0, 100)
        self.assertEqual(five, 86)
        self.assertLess(five, hour)

    def test_unreported_split_assumes_the_expensive_ttl(self) -> None:
        # Measured Claude Code runs write entirely at the 1h TTL; defaulting to
        # the cheaper rate would understate cost on the main runtime.
        self.assertEqual(
            usage_summary.cache_write_cost_share(200, 100),
            usage_summary.cache_write_cost_share(200, 100, 0, 100),
        )

    def test_amortized_writes_are_a_small_share(self) -> None:
        self.assertEqual(usage_summary.cache_write_cost_share(200000, 1000, 0, 1000), 9)

    def test_no_cache_activity_is_zero_not_a_crash(self) -> None:
        self.assertEqual(usage_summary.cache_write_cost_share(0, 0), 0)

    def test_negative_and_garbage_inputs_are_clamped(self) -> None:
        self.assertEqual(usage_summary.cache_write_cost_share(-5, -5), 0)
        self.assertEqual(usage_summary.cache_write_cost_share(None, "x"), 0)

    def test_token_renders_percent_and_is_greppable(self) -> None:
        self.assertIn("write_cost=86%", usage_summary.color_write_cost_token(86))
