#!/usr/bin/env python3
"""Subprocess-based unit tests for pipeline.maxReworkIterations parsing.

plan-todo.sh embeds its pipeline parser/validator as a python3 heredoc
invoked from bash functions (plan_pipeline_validate_plan,
plan_pipeline_graph_json). These tests source the shell library and call
those functions the same way callers (bats, run-plan.sh) do, since the
parser is not importable as a standalone python module.
"""

from __future__ import annotations

import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

PROJECT_ROOT = Path(__file__).parent.parent.parent
PLAN_TODO_LIB = PROJECT_ROOT / "bundle" / ".ralph" / "bash-lib" / "plan-todo.sh"

GRAPH_PLAN_TEMPLATE = """---
execution: graph
pipeline:
  stages:
    - id: implement
      runtime: cursor
      instructions: Implement the change end to end.
      produces:
        - path: shared/output.md
{max_rework_line}
todos:
  - id: implement-1
    stage: implement
    content: implement the feature
    status: pending
---
"""

ORCHESTRATION_PLAN_TEMPLATE = """---
name: Orch Rework Iterations
execution: orchestration
pipeline:
  stages:
    - id: research
      runtime: cursor
      instructions: Research the topic and write findings.
      produces:
        - path: .ralph-workspace/artifacts/{{ARTIFACT_NS}}/research.md
          required: true
  maxReworkIterations: 3
todos:
  - id: research-1
    stage: research
    content: Do the research and write findings.
    verification: Confirm research.md exists.
    status: pending
---
"""


def write_plan(tmp_dir: str, name: str, content: str) -> Path:
    path = Path(tmp_dir) / name
    path.write_text(content, encoding="utf-8")
    return path


def run_lib_function(function_call: str) -> subprocess.CompletedProcess:
    """Source plan-todo.sh and invoke the given function call via bash."""
    script = f"source '{PLAN_TODO_LIB}'; {function_call}"
    return subprocess.run(
        ["bash", "-c", script],
        capture_output=True,
        text=True,
        encoding="utf-8",
        cwd=PROJECT_ROOT,
    )


class TestMaxReworkIterationsParsing(unittest.TestCase):
    """Tests for the graph-only pipeline.maxReworkIterations field."""

    def test_valid_value_parses_and_round_trips(self) -> None:
        with tempfile.TemporaryDirectory() as tmp_dir:
            plan = write_plan(
                tmp_dir,
                "graph-rework-valid.plan.md",
                GRAPH_PLAN_TEMPLATE.format(max_rework_line="  maxReworkIterations: 3"),
            )
            validate_result = run_lib_function(f"plan_pipeline_validate_plan '{plan}'")
            self.assertEqual(
                validate_result.returncode,
                0,
                msg=f"validate failed: {validate_result.stdout}\n{validate_result.stderr}",
            )

            graph_result = run_lib_function(f"plan_pipeline_graph_json '{plan}'")
            self.assertEqual(
                graph_result.returncode,
                0,
                msg=f"graph compile failed: {graph_result.stdout}\n{graph_result.stderr}",
            )
            self.assertTrue(graph_result.stdout.strip(), "expected graph json output")

    def test_zero_fails_compile_and_names_field(self) -> None:
        with tempfile.TemporaryDirectory() as tmp_dir:
            plan = write_plan(
                tmp_dir,
                "graph-rework-zero.plan.md",
                GRAPH_PLAN_TEMPLATE.format(max_rework_line="  maxReworkIterations: 0"),
            )
            result = run_lib_function(f"plan_pipeline_validate_plan '{plan}'")
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("maxReworkIterations", result.stdout + result.stderr)

    def test_six_fails_compile_and_names_field(self) -> None:
        with tempfile.TemporaryDirectory() as tmp_dir:
            plan = write_plan(
                tmp_dir,
                "graph-rework-six.plan.md",
                GRAPH_PLAN_TEMPLATE.format(max_rework_line="  maxReworkIterations: 6"),
            )
            result = run_lib_function(f"plan_pipeline_validate_plan '{plan}'")
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("maxReworkIterations", result.stdout + result.stderr)

    def test_orchestration_plan_rejects_unknown_field(self) -> None:
        with tempfile.TemporaryDirectory() as tmp_dir:
            plan = write_plan(
                tmp_dir,
                "orch-rework.plan.md",
                ORCHESTRATION_PLAN_TEMPLATE,
            )
            result = run_lib_function(f"plan_pipeline_validate_plan '{plan}'")
            self.assertNotEqual(result.returncode, 0)
            combined = result.stdout + result.stderr
            self.assertIn("unknown pipeline field", combined)
            self.assertIn("maxReworkIterations", combined)


if __name__ == "__main__":
    unittest.main()
