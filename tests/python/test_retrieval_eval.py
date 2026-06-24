#!/usr/bin/env python3
"""Offline retrieval evaluation harness tests."""

from __future__ import annotations

import json
import sys
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
FIXTURE_DIR = REPO_ROOT / "tests" / "fixtures" / "retrieval-eval"
QUERIES_FIXTURE = FIXTURE_DIR / "queries.json"
BASELINE_FIXTURE = FIXTURE_DIR / "baseline-metrics.json"

sys.path.insert(0, str(REPO_ROOT / "bundle" / ".ralph" / "python"))
sys.path.insert(0, str(REPO_ROOT / "tests" / "python"))

import retrieval_eval as reval  # noqa: E402


class TestRetrievalEvalHarness(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.queries_payload = json.loads(QUERIES_FIXTURE.read_text(encoding="utf-8"))
        cls.baseline = json.loads(BASELINE_FIXTURE.read_text(encoding="utf-8"))
        cls.baseline_results, cls.baseline_aggregate = reval.run_evaluation(
            REPO_ROOT,
            QUERIES_FIXTURE,
            contextual=False,
        )
        cls.results, cls.aggregate = reval.run_evaluation(
            REPO_ROOT,
            QUERIES_FIXTURE,
            contextual=True,
        )

    def test_fixture_has_at_least_thirty_queries(self) -> None:
        queries = self.queries_payload.get("queries") or []
        self.assertGreaterEqual(len(queries), 30)

    def test_queries_declare_rationale_and_paths(self) -> None:
        for entry in self.queries_payload.get("queries") or []:
            self.assertTrue(entry.get("id"), msg=entry)
            self.assertTrue(entry.get("query"), msg=entry)
            self.assertTrue(entry.get("relevant_paths"), msg=entry)
            self.assertTrue(entry.get("rationale"), msg=entry)

    def test_aggregate_metrics_within_baseline_tolerance(self) -> None:
        tol = self.baseline.get("tolerance") or {}
        base_agg = self.baseline["aggregate"]
        checks = [
            ("precision_at_5", self.aggregate.precision_at_5),
            ("recall_at_5", self.aggregate.recall_at_5),
            ("recall_at_10", self.aggregate.recall_at_10),
            ("mrr", self.aggregate.mrr),
        ]
        for key, current in checks:
            floor = float(base_agg[key]) - float(tol.get(key, 0.0))
            self.assertGreaterEqual(
                current,
                floor,
                msg=f"{key} regressed: current={current} floor={floor}",
            )

        max_delta = int(tol.get("queries_no_relevant_top10_max_delta", 0))
        allowed = int(base_agg["queries_no_relevant_top10"]) + max_delta
        self.assertLessEqual(
            self.aggregate.queries_no_relevant_top10,
            allowed,
            msg=(
                "queries_no_relevant_top10 regressed: "
                f"current={self.aggregate.queries_no_relevant_top10} allowed={allowed}"
            ),
        )

    def test_per_query_safety_top10_gate(self) -> None:
        per_base = self.baseline.get("per_query") or {}
        by_id = {r.query_id: r for r in self.results}
        for qid, entry in per_base.items():
            safety = entry.get("safety_top10") or []
            if not safety:
                continue
            result = by_id[qid]
            top_set = set(result.top_results)
            for required in safety:
                self.assertIn(
                    required,
                    top_set,
                    msg=f"safety gate failed for {qid}: missing {required!r} in top-10",
                )

    def test_json_report_is_deterministic(self) -> None:
        text_a = reval.emit_json_report(self.results, self.aggregate, "contextual-bm25")
        text_b = reval.emit_json_report(self.results, self.aggregate, "contextual-bm25")
        self.assertEqual(text_a, text_b)
        payload = json.loads(text_a)
        self.assertEqual(payload["kind"], "retrieval_eval_report")
        self.assertIn("aggregate", payload)
        self.assertIn("per_query", payload)
        for hit in payload["per_query"].values():
            for path_line in hit.get("top_results") or []:
                self.assertNotRegex(path_line, r"^/")

    def test_failure_report_documents_regressions(self) -> None:
        worsened = reval.AggregateMetrics(
            precision_at_5=0.0,
            recall_at_5=0.0,
            recall_at_10=0.0,
            mrr=0.0,
            queries_no_relevant_top10=99,
            query_count=self.aggregate.query_count,
        )
        report = reval.format_failure_report(
            self.results,
            worsened,
            self.baseline,
            self.baseline.get("tolerance") or {},
        )
        self.assertIn("REGRESSION", report)
        self.assertIn("precision@5", report)

    def test_contextual_queries_improve_or_match_baseline(self) -> None:
        contextual_ids = {
            "difficult-symbol-nearby-normalize",
            "difficult-heading-cookbook-backlog",
            "doc-retrieval-cluster",
        }
        baseline_by_id = {r.query_id: r for r in self.baseline_results}
        contextual_by_id = {r.query_id: r for r in self.results}
        for qid in contextual_ids:
            base_rr = baseline_by_id[qid].reciprocal_rank
            ctx_rr = contextual_by_id[qid].reciprocal_rank
            self.assertGreaterEqual(
                ctx_rr,
                base_rr,
                msg=f"contextual reciprocal_rank regressed for {qid}: {ctx_rr} < {base_rr}",
            )

    def test_compare_to_baseline_passes_on_current_ranker(self) -> None:
        failures = reval.compare_to_baseline(self.aggregate, self.results, self.baseline)
        self.assertEqual(failures, [])

    def test_difficult_category_queries_present(self) -> None:
        categories = {q.get("category") for q in self.queries_payload.get("queries") or []}
        self.assertIn("difficult_path_match", categories)

    def test_each_query_has_relevant_top10_at_baseline(self) -> None:
        self.assertEqual(
            self.aggregate.queries_no_relevant_top10,
            self.baseline["aggregate"]["queries_no_relevant_top10"],
        )


if __name__ == "__main__":
    unittest.main()
