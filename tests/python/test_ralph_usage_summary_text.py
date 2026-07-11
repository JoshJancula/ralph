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
