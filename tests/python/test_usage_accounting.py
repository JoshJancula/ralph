#!/usr/bin/env python3
"""Unit tests for usage_accounting canonical token buckets."""

from __future__ import annotations

import sys
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO_ROOT / "bundle" / ".ralph" / "python"))

from usage_accounting import (  # noqa: E402
    ESTIMATED,
    MEASURED,
    MIXED,
    UNAVAILABLE,
    aggregate_records,
    cache_efficiency_ratio,
    combine_sources,
    enrich_record,
    normalize_usage,
    total_input_tokens,
)


class TestUsageAccounting(unittest.TestCase):
    def test_legacy_record_reads_input_tokens_as_uncached(self) -> None:
        canonical = normalize_usage(
            {
                "input_tokens": 100,
                "output_tokens": 20,
                "cache_creation_input_tokens": 5,
                "cache_read_input_tokens": 10,
            }
        )
        self.assertEqual(canonical["uncached_input_tokens"], 100)
        self.assertEqual(canonical["input_tokens"], 100)
        self.assertEqual(canonical["total_input_tokens"], 115)
        self.assertEqual(canonical["cache_efficiency_ratio"], round(10 / 115, 4))
        self.assertEqual(canonical["measurement_source"]["uncached_input_tokens"], MEASURED)
        self.assertEqual(canonical["measurement_source"]["cache_read_input_tokens"], MEASURED)

    def test_missing_cache_fields_are_unavailable_not_zero_measured(self) -> None:
        canonical = normalize_usage({"input_tokens": 50, "output_tokens": 5})
        self.assertEqual(canonical["cache_read_input_tokens"], 0)
        self.assertEqual(canonical["measurement_source"]["cache_read_input_tokens"], UNAVAILABLE)
        self.assertEqual(canonical["measurement_source"]["cache_creation_input_tokens"], UNAVAILABLE)
        self.assertEqual(canonical["cache_efficiency_ratio"], 0.0)

    def test_opencode_estimate_is_labeled(self) -> None:
        canonical = normalize_usage(
            {
                "input_tokens": 200,
                "output_tokens": 30,
                "cache_read_input_tokens": 0,
                "cache_read_input_tokens_estimated": 150,
            }
        )
        self.assertEqual(canonical["cache_read_input_tokens"], 150)
        self.assertEqual(canonical["measurement_source"]["cache_read_input_tokens"], ESTIMATED)
        self.assertEqual(canonical["total_input_tokens"], 350)
        self.assertEqual(canonical["cache_efficiency_ratio"], round(150 / 350, 4))

    def test_aggregate_marks_mixed_when_sources_differ(self) -> None:
        records = [
            {
                "input_tokens": 10,
                "output_tokens": 1,
                "cache_read_input_tokens": 5,
            },
            {
                "input_tokens": 10,
                "output_tokens": 1,
                "cache_read_input_tokens": 0,
                "cache_read_input_tokens_estimated": 8,
            },
        ]
        agg = aggregate_records(records)
        self.assertEqual(agg["uncached_input_tokens"], 20)
        self.assertEqual(agg["cache_read_input_tokens"], 13)
        self.assertEqual(agg["measurement_source"]["cache_read_input_tokens"], MIXED)

    def test_identical_records_compute_identical_ratios(self) -> None:
        record = {
            "uncached_input_tokens": 80,
            "cache_creation_input_tokens": 10,
            "cache_read_input_tokens": 40,
            "output_tokens": 12,
            "measurement_source": {
                "uncached_input_tokens": MEASURED,
                "cache_creation_input_tokens": MEASURED,
                "cache_read_input_tokens": MEASURED,
                "output_tokens": MEASURED,
            },
        }
        single = normalize_usage(record)
        doubled = aggregate_records([record, record])
        self.assertEqual(single["cache_efficiency_ratio"], doubled["cache_efficiency_ratio"])
        self.assertEqual(single["cache_hit_ratio"], doubled["cache_hit_ratio"])

    def test_enrich_record_writes_canonical_and_legacy_fields(self) -> None:
        record = {
            "input_tokens": 12,
            "output_tokens": 3,
            "cache_creation_input_tokens": 1,
            "cache_read_input_tokens": 4,
        }
        enrich_record(record)
        self.assertEqual(record["uncached_input_tokens"], 12)
        self.assertEqual(record["total_input_tokens"], 17)
        self.assertIn("measurement_source", record)
        self.assertEqual(record["cache_hit_ratio"], record["cache_efficiency_ratio"])

    def test_combine_sources_helpers(self) -> None:
        self.assertEqual(combine_sources([MEASURED, MEASURED]), MEASURED)
        self.assertEqual(combine_sources([ESTIMATED, ESTIMATED]), ESTIMATED)
        self.assertEqual(combine_sources([MEASURED, ESTIMATED]), MIXED)
        self.assertEqual(combine_sources([UNAVAILABLE]), UNAVAILABLE)

    def test_total_input_and_ratio_zero_safe(self) -> None:
        self.assertEqual(total_input_tokens(0, 0, 0), 0)
        self.assertEqual(cache_efficiency_ratio(10, 0), 0.0)
        self.assertEqual(cache_efficiency_ratio(10, 100), 0.1)

    def test_observability_identity_fields_survive_usage_enrichment_without_old_labels(self) -> None:
        record = {
            "runtime": "codex",
            "role": "implementation",
            "modelSource": "runtime saved/default",
            "nativeSubagents": "inherit",
            "delegatedRunId": "delegated-run-001",
            "input_tokens": 4,
            "output_tokens": 2,
        }
        enrich_record(record)
        for field in ("runtime", "role", "modelSource", "nativeSubagents", "delegatedRunId"):
            self.assertIn(field, record)
        self.assertNotIn("agent", record)
        self.assertNotIn("brokeredChildren", record)


if __name__ == "__main__":
    unittest.main()
