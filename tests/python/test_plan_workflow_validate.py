#!/usr/bin/env python3
"""Subprocess-based unit tests for reusable workflow file validation.

Workflow sources live at .ralph-workspace/workflows/<name>.workflow.md and are
pipeline plans carrying 'kind: workflow' plus one authoritative
'engine: graph|orchestration'. plan-todo.sh exposes plan_workflow_validate as
the shell entry point, backed by the internal 'workflow-validate' python mode.
"""

from __future__ import annotations

import subprocess
import tempfile
import unittest
from pathlib import Path

PROJECT_ROOT = Path(__file__).parent.parent.parent
PLAN_TODO_LIB = PROJECT_ROOT / "bundle" / ".ralph" / "bash-lib" / "plan-todo.sh"

GRAPH_WORKFLOW = """---
name: Graph Workflow
kind: workflow
engine: graph
pipeline:
  maxReworkIterations: 3
  stages:
    - id: implement
      runtime: cursor
      instructions: Implement the change end to end.
      produces:
        - path: shared/output.md
todos:
  - id: implement-1
    stage: implement
    content: Implement {{TASK}} end to end.
    status: pending
---
"""

ORCH_WORKFLOW = """---
name: Orchestration Workflow
kind: workflow
engine: orchestration
pipeline:
  stages:
    - id: research
      runtime: cursor
      instructions: Research the topic and write findings.
      produces:
        - path: .ralph-workspace/artifacts/{{ARTIFACT_NS}}/research.md
          required: true
todos:
  - id: research-1
    stage: research
    content: Research {{TASK}} and write findings.
    verification: Confirm research.md exists.
    status: pending
---
"""


def write_workflow(tmp_dir: str, name: str, content: str) -> Path:
    path = Path(tmp_dir) / name
    path.write_text(content, encoding="utf-8")
    return path


def run_lib_function(function_call: str) -> subprocess.CompletedProcess:
    script = f"source '{PLAN_TODO_LIB}'; {function_call}"
    return subprocess.run(
        ["bash", "-c", script],
        capture_output=True,
        text=True,
        encoding="utf-8",
        cwd=PROJECT_ROOT,
    )


def validate(tmp_dir: str, name: str, content: str) -> subprocess.CompletedProcess:
    path = write_workflow(tmp_dir, name, content)
    return run_lib_function(f"plan_workflow_validate '{path}'")


class TestWorkflowValidate(unittest.TestCase):
    def test_valid_graph_workflow_passes(self) -> None:
        with tempfile.TemporaryDirectory() as tmp_dir:
            result = validate(tmp_dir, "valid.workflow.md", GRAPH_WORKFLOW)
            self.assertEqual(
                result.returncode,
                0,
                msg=f"validate failed: {result.stdout}\n{result.stderr}",
            )

    def test_valid_orchestration_workflow_passes(self) -> None:
        with tempfile.TemporaryDirectory() as tmp_dir:
            result = validate(tmp_dir, "valid-orch.workflow.md", ORCH_WORKFLOW)
            self.assertEqual(
                result.returncode,
                0,
                msg=f"validate failed: {result.stdout}\n{result.stderr}",
            )

    def test_missing_task_token_fails(self) -> None:
        with tempfile.TemporaryDirectory() as tmp_dir:
            content = GRAPH_WORKFLOW.replace(
                "Implement {{TASK}} end to end.", "Implement the feature end to end."
            )
            result = validate(tmp_dir, "no-task.workflow.md", content)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("{{TASK}}", result.stdout + result.stderr)

    def test_unknown_token_fails_naming_token_and_todo(self) -> None:
        with tempfile.TemporaryDirectory() as tmp_dir:
            content = GRAPH_WORKFLOW.replace(
                "Implement {{TASK}} end to end.",
                "Implement {{TASK}} using {{BOGUS}} settings.",
            )
            result = validate(tmp_dir, "bogus.workflow.md", content)
            self.assertNotEqual(result.returncode, 0)
            combined = result.stdout + result.stderr
            self.assertIn("{{BOGUS}}", combined)
            self.assertIn("implement-1", combined)

    def test_invalid_engine_value_fails(self) -> None:
        with tempfile.TemporaryDirectory() as tmp_dir:
            content = GRAPH_WORKFLOW.replace("engine: graph", "engine: pipeline")
            result = validate(tmp_dir, "engine-pipeline.workflow.md", content)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("engine", result.stdout + result.stderr)

    def test_engine_and_execution_together_fails(self) -> None:
        with tempfile.TemporaryDirectory() as tmp_dir:
            content = GRAPH_WORKFLOW.replace(
                "engine: graph", "engine: graph\nexecution: graph"
            )
            result = validate(tmp_dir, "both.workflow.md", content)
            self.assertNotEqual(result.returncode, 0)
            combined = result.stdout + result.stderr
            self.assertIn("engine", combined)
            self.assertIn("execution", combined)

    def test_missing_kind_fails(self) -> None:
        with tempfile.TemporaryDirectory() as tmp_dir:
            content = GRAPH_WORKFLOW.replace("kind: workflow\n", "")
            result = validate(tmp_dir, "no-kind.workflow.md", content)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("kind: workflow", result.stdout + result.stderr)

    def test_graph_only_field_under_orchestration_engine_fails(self) -> None:
        with tempfile.TemporaryDirectory() as tmp_dir:
            content = ORCH_WORKFLOW.replace(
                "pipeline:\n", "pipeline:\n  maxReworkIterations: 3\n"
            )
            result = validate(tmp_dir, "orch-graph-field.workflow.md", content)
            self.assertNotEqual(result.returncode, 0)
            combined = result.stdout + result.stderr
            self.assertIn("unknown pipeline field", combined)
            self.assertIn("maxReworkIterations", combined)

    def test_engine_after_pipeline_behaves_identically(self) -> None:
        with tempfile.TemporaryDirectory() as tmp_dir:
            before = validate(tmp_dir, "engine-before.workflow.md", GRAPH_WORKFLOW)
            # Place engine after the pipeline block instead.
            after_content = GRAPH_WORKFLOW.replace("engine: graph\n", "")
            after_content = after_content.replace(
                "todos:\n", "engine: graph\ntodos:\n", 1
            )
            after = validate(tmp_dir, "engine-after.workflow.md", after_content)
            self.assertEqual(before.returncode, 0, msg=before.stdout + before.stderr)
            self.assertEqual(
                after.returncode,
                0,
                msg=f"engine after pipeline failed: {after.stdout}\n{after.stderr}",
            )

    def test_engine_after_pipeline_still_rejects_bad_token(self) -> None:
        with tempfile.TemporaryDirectory() as tmp_dir:
            content = GRAPH_WORKFLOW.replace("engine: graph\n", "")
            content = content.replace("todos:\n", "engine: graph\ntodos:\n", 1)
            content = content.replace(
                "Implement {{TASK}} end to end.",
                "Implement {{TASK}} using {{BOGUS}} settings.",
            )
            result = validate(tmp_dir, "engine-after-bogus.workflow.md", content)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("{{BOGUS}}", result.stdout + result.stderr)

    def test_workflow_source_rejected_by_graph_compilation(self) -> None:
        with tempfile.TemporaryDirectory() as tmp_dir:
            path = write_workflow(tmp_dir, "runnable.workflow.md", GRAPH_WORKFLOW)
            result = run_lib_function(f"plan_pipeline_graph_json '{path}'")
            self.assertNotEqual(result.returncode, 0)
            combined = result.stdout + result.stderr
            self.assertIn("workflow source", combined)
            self.assertNotIn("{{TASK}}", result.stdout)


if __name__ == "__main__":
    unittest.main()
