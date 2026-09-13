#!/usr/bin/env python3
"""Subprocess-based unit tests for expand_rework_nodes in plan-todo.sh.

plan-todo.sh embeds its pipeline parser/compiler as a python3 heredoc
invoked from bash functions. These tests source the shell library and call
plan_pipeline_rework_debug_json (a thin wrapper around the internal
rework-debug mode) the same way callers would, since the parser is not
importable as a standalone python module.
"""

from __future__ import annotations

import json
import re
import subprocess
import tempfile
import unittest
from pathlib import Path

PROJECT_ROOT = Path(__file__).parent.parent.parent
PLAN_TODO_LIB = PROJECT_ROOT / "bundle" / ".ralph" / "bash-lib" / "plan-todo.sh"
EVALUATOR_SCHEMA = "bundle/.ralph/schemas/evaluator-verdict.schema.json"
NODE_ID_RE = re.compile(r"^[a-z0-9]+(-[a-z0-9]+)*$")

VERDICT_PATH_TEMPLATE = "artifacts/{{ARTIFACT_NS}}/{{STAGE_ID}}/verdict.json"


def _plan_content(on_exhausted: str = "") -> str:
    on_exhausted_line = f"\n      onExhausted: {on_exhausted}" if on_exhausted else ""
    return f"""---
execution: graph
pipeline:
  stages:
    - id: implement
      runtime: cursor
      instructions: Implement the change end to end.
      produces:
        - path: shared/output.md
    - id: review
      runtime: cursor
      instructions: Review the change and report findings.
      dependsOn:
        - implement
      produces:
        - path: {VERDICT_PATH_TEMPLATE}
          schema: {EVALUATOR_SCHEMA}
      loopBackTo: implement
      maxIterations: 2{on_exhausted_line}
      loopCheck:
        path: {VERDICT_PATH_TEMPLATE}
        schema: {EVALUATOR_SCHEMA}
todos:
  - id: implement-1
    stage: implement
    content: implement the feature
    status: pending
  - id: review-1
    stage: review
    content: review the feature
    status: pending
---
"""


def _write_plan(tmp_dir: str, name: str, content: str) -> Path:
    path = Path(tmp_dir) / name
    path.write_text(content, encoding="utf-8")
    return path


def _expand(tmp_dir: str, name: str, on_exhausted: str = "") -> dict:
    plan = _write_plan(tmp_dir, name, _plan_content(on_exhausted))
    script = f"source '{PLAN_TODO_LIB}'; plan_pipeline_rework_debug_json '{plan}' review 2"
    result = subprocess.run(
        ["bash", "-c", script],
        capture_output=True,
        text=True,
        encoding="utf-8",
        cwd=PROJECT_ROOT,
    )
    if result.returncode != 0:
        raise AssertionError(f"expand failed: {result.stdout}\n{result.stderr}")
    return json.loads(result.stdout)


class TestExpandReworkNodes(unittest.TestCase):
    """Direct tests of expand_rework_nodes(review, stages_by_id, todos_by_stage, iterations=2)."""

    def test_exactly_five_nodes_emitted(self) -> None:
        with tempfile.TemporaryDirectory() as tmp_dir:
            doc = _expand(tmp_dir, "five-nodes.plan.md")
            node_ids = sorted(n["id"] for n in doc["nodes"])
            self.assertEqual(
                node_ids,
                ["implement-r1", "implement-r2", "review-approved", "review-r1", "review-r2"],
            )

    def test_all_node_ids_match_stage_id_pattern(self) -> None:
        with tempfile.TemporaryDirectory() as tmp_dir:
            doc = _expand(tmp_dir, "id-pattern.plan.md")
            for node in doc["nodes"]:
                self.assertRegex(node["id"], NODE_ID_RE)

    def test_all_passed_edges_terminate_at_approved_join(self) -> None:
        with tempfile.TemporaryDirectory() as tmp_dir:
            doc = _expand(tmp_dir, "passed-edges.plan.md")
            passed_edges = [e for e in doc["edges"] if e.get("condition") == "passed"]
            self.assertEqual(len(passed_edges), 3)
            for edge in passed_edges:
                self.assertEqual(edge["to"], "review-approved")
            sources = sorted(e["from"] for e in passed_edges)
            self.assertEqual(sources, ["review", "review-r1", "review-r2"])

    def test_dependson_matches_incoming_rework_edges(self) -> None:
        with tempfile.TemporaryDirectory() as tmp_dir:
            doc = _expand(tmp_dir, "dependson.plan.md")
            nodes_by_id = {n["id"]: n for n in doc["nodes"]}
            self.assertEqual(nodes_by_id["implement-r1"]["dependsOn"], ["review"])
            self.assertEqual(nodes_by_id["implement-r2"]["dependsOn"], ["review-r1"])
            self.assertEqual(nodes_by_id["review-r1"]["dependsOn"], ["implement-r1"])
            self.assertEqual(nodes_by_id["review-r2"]["dependsOn"], ["implement-r2"])
            self.assertEqual(nodes_by_id["review-approved"]["dependsOn"], [])

    def test_target_round_requires_exact_preceding_review_artifact(self) -> None:
        with tempfile.TemporaryDirectory() as tmp_dir:
            doc = _expand(tmp_dir, "requires.plan.md")
            nodes_by_id = {n["id"]: n for n in doc["nodes"]}
            r1_requires = nodes_by_id["implement-r1"]["stage"]["inputArtifacts"]
            r2_requires = nodes_by_id["implement-r2"]["stage"]["inputArtifacts"]
            r1_paths = [item["path"] for item in r1_requires]
            r2_paths = [item["path"] for item in r2_requires]
            self.assertIn("artifacts/{{ARTIFACT_NS}}/review/verdict.json", r1_paths)
            self.assertIn("artifacts/{{ARTIFACT_NS}}/review-r1/verdict.json", r2_paths)
            for path in r1_paths + r2_paths:
                self.assertNotIn("{{STAGE_ID}}", path)

    def test_on_exhausted_fail_omits_final_changes_required_edge(self) -> None:
        with tempfile.TemporaryDirectory() as tmp_dir:
            doc = _expand(tmp_dir, "exhausted-fail.plan.md", on_exhausted="fail")
            offending = [
                e
                for e in doc["edges"]
                if e["from"] == "review-r2" and e.get("condition") == "changes-required"
            ]
            self.assertEqual(offending, [])

    def test_on_exhausted_proceed_adds_exactly_one_final_changes_required_edge(self) -> None:
        with tempfile.TemporaryDirectory() as tmp_dir:
            doc = _expand(tmp_dir, "exhausted-proceed.plan.md", on_exhausted="proceed")
            matching = [
                e
                for e in doc["edges"]
                if e["from"] == "review-r2" and e.get("condition") == "changes-required"
            ]
            self.assertEqual(len(matching), 1)
            self.assertEqual(matching[0]["to"], "review-approved")


if __name__ == "__main__":
    unittest.main()
