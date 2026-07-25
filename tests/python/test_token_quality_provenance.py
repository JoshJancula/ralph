#!/usr/bin/env python3
"""Unit tests for token measurement provenance on savings buckets (PLAN15).

Distinguishes tokens estimated from actual text (Ralph's dependency-free
estimator) from a legacy bytes/4-equivalent fallback and missing token data.
Mixed aggregates must report "mixed".
"""

from __future__ import annotations

import unittest

from ralph_script_loader import load_ralph_script


TCC = load_ralph_script("tool_call_classification")


class TestTokenQualityProvenance(unittest.TestCase):
    def test_all_measured_events_report_measured(self) -> None:
        bucket = TCC.empty_savings_bucket()
        TCC.accumulate_savings_event(bucket, pre_bytes=1000, post_bytes=200, pre_tokens=250, post_tokens=50)
        TCC.accumulate_savings_event(bucket, pre_bytes=2000, post_bytes=400, pre_tokens=500, post_tokens=100)
        TCC.finalize_savings_bucket(bucket)
        self.assertEqual(bucket["token_quality"], "measured")

    def test_all_legacy_events_report_legacy(self) -> None:
        bucket = TCC.empty_savings_bucket()
        TCC.accumulate_savings_event(
            bucket, pre_bytes=1000, post_bytes=200, pre_tokens=250, post_tokens=50,
            token_quality=TCC.TOKEN_QUALITY_LEGACY,
        )
        TCC.finalize_savings_bucket(bucket)
        self.assertEqual(bucket["token_quality"], "legacy_bytes_div4")

    def test_no_token_data_reports_missing(self) -> None:
        bucket = TCC.empty_savings_bucket()
        TCC.accumulate_savings_event(bucket, pre_bytes=1000, post_bytes=200, pre_tokens=0, post_tokens=0)
        TCC.finalize_savings_bucket(bucket)
        self.assertEqual(bucket["token_quality"], "missing")

    def test_mixed_measured_and_legacy_reports_mixed(self) -> None:
        bucket = TCC.empty_savings_bucket()
        TCC.accumulate_savings_event(bucket, pre_bytes=1000, post_bytes=200, pre_tokens=250, post_tokens=50)
        TCC.accumulate_savings_event(
            bucket, pre_bytes=2000, post_bytes=400, pre_tokens=500, post_tokens=100,
            token_quality=TCC.TOKEN_QUALITY_LEGACY,
        )
        TCC.finalize_savings_bucket(bucket)
        self.assertEqual(bucket["token_quality"], "mixed")

    def test_empty_bucket_reports_missing(self) -> None:
        bucket = TCC.empty_savings_bucket()
        TCC.finalize_savings_bucket(bucket)
        self.assertEqual(bucket["token_quality"], "missing")

    def test_legacy_record_numeric_fields_unchanged(self) -> None:
        bucket = TCC.empty_savings_bucket()
        TCC.accumulate_savings_event(
            bucket, pre_bytes=4000, post_bytes=1000, pre_tokens=1000, post_tokens=250,
            token_quality=TCC.TOKEN_QUALITY_LEGACY,
        )
        TCC.finalize_savings_bucket(bucket)
        self.assertEqual(bucket["pre_optimization_bytes"], 4000)
        self.assertEqual(bucket["post_optimization_bytes"], 1000)
        self.assertEqual(bucket["saved_bytes"], 3000)
        self.assertEqual(bucket["pre_optimization_tokens"], 1000)
        self.assertEqual(bucket["saved_tokens"], 750)

    def test_merge_savings_buckets_sums_quality_counters(self) -> None:
        a = TCC.empty_savings_bucket()
        TCC.accumulate_savings_event(a, pre_bytes=1000, post_bytes=200, pre_tokens=250, post_tokens=50)
        b = TCC.empty_savings_bucket()
        TCC.accumulate_savings_event(
            b, pre_bytes=2000, post_bytes=400, pre_tokens=500, post_tokens=100,
            token_quality=TCC.TOKEN_QUALITY_LEGACY,
        )
        target = {"path": a}
        TCC.merge_savings_buckets(target, {"path": b})
        TCC.finalize_savings_bucket(target["path"])
        self.assertEqual(target["path"]["token_quality"], "mixed")
        self.assertEqual(target["path"]["pre_optimization_bytes"], 3000)


if __name__ == "__main__":
    unittest.main()
