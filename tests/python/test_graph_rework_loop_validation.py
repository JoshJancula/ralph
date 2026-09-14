#!/usr/bin/env python3
"""Subprocess-based unit tests for graph-mode loopBackTo rework validation.

plan-todo.sh embeds its pipeline parser/validator as a python3 heredoc
invoked from bash functions (plan_pipeline_validate_plan). These tests
source the shell library and call that function the same way callers
(bats, run-plan.sh) do, since the parser is not importable as a standalone
python module.
"""

from __future__ import annotations

import subprocess
import tempfile
import unittest
from pathlib import Path

PROJECT_ROOT = Path(__file__).parent.parent.parent
PLAN_TODO_LIB = PROJECT_ROOT / "bundle" / ".ralph" / "bash-lib" / "plan-todo.sh"
EVALUATOR_SCHEMA = "bundle/.ralph/schemas/evaluator-verdict.schema.json"

BASE_STAGES = """\
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
        - path: shared/verdict.json
          schema: {schema}
      loopBackTo: implement
      maxIterations: 2
      loopCheck:
        path: shared/verdict.json
        schema: {schema}
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


def validate(tmp_dir: str, name: str, content: str) -> subprocess.CompletedProcess:
    plan = write_plan(tmp_dir, name, content)
    return run_lib_function(f"plan_pipeline_validate_plan '{plan}'")


class TestGraphReworkLoopValidation(unittest.TestCase):
    """Graph-mode loopBackTo rework macro validation, keyed off validate_loop_rules."""

    def test_valid_direct_dependency_compiles(self) -> None:
        content = f"""---
execution: graph
pipeline:
  stages:
{BASE_STAGES.format(schema=EVALUATOR_SCHEMA)}
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
        with tempfile.TemporaryDirectory() as tmp_dir:
            result = validate(tmp_dir, "valid.plan.md", content)
            self.assertEqual(result.returncode, 0, msg=result.stdout + result.stderr)

    def test_pipeline_default_max_rework_iterations_used_when_stage_omits_it(self) -> None:
        content = f"""---
execution: graph
pipeline:
  maxReworkIterations: 2
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
        - path: shared/verdict.json
          schema: {EVALUATOR_SCHEMA}
      loopBackTo: implement
      loopCheck:
        path: shared/verdict.json
        schema: {EVALUATOR_SCHEMA}
todos:
  - id: implement-1
    stage: implement
    content: implement the feature
    status: pending
---
"""
        with tempfile.TemporaryDirectory() as tmp_dir:
            result = validate(tmp_dir, "default-iterations.plan.md", content)
            self.assertEqual(result.returncode, 0, msg=result.stdout + result.stderr)

    def test_missing_max_iterations_and_pipeline_default_fails(self) -> None:
        content = f"""---
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
        - path: shared/verdict.json
          schema: {EVALUATOR_SCHEMA}
      loopBackTo: implement
      loopCheck:
        path: shared/verdict.json
        schema: {EVALUATOR_SCHEMA}
todos:
  - id: implement-1
    stage: implement
    content: implement the feature
    status: pending
---
"""
        with tempfile.TemporaryDirectory() as tmp_dir:
            result = validate(tmp_dir, "no-iterations.plan.md", content)
            self.assertNotEqual(result.returncode, 0)
            combined = result.stdout + result.stderr
            self.assertIn("maxIterations", combined)
            self.assertIn("maxReworkIterations", combined)

    def test_transitive_not_direct_dependency_fails_naming_both_ids(self) -> None:
        content = f"""---
execution: graph
pipeline:
  stages:
    - id: implement
      runtime: cursor
      instructions: Implement the change end to end.
      produces:
        - path: shared/output.md
    - id: mid
      runtime: cursor
      instructions: Implement the change end to end.
      dependsOn:
        - implement
      produces:
        - path: shared/mid.md
    - id: review
      runtime: cursor
      instructions: Review the change and report findings.
      dependsOn:
        - mid
      produces:
        - path: shared/verdict.json
          schema: {EVALUATOR_SCHEMA}
      loopBackTo: implement
      maxIterations: 2
      loopCheck:
        path: shared/verdict.json
        schema: {EVALUATOR_SCHEMA}
todos:
  - id: implement-1
    stage: implement
    content: implement the feature
    status: pending
  - id: mid-1
    stage: mid
    content: mid step
    status: pending
---
"""
        with tempfile.TemporaryDirectory() as tmp_dir:
            result = validate(tmp_dir, "transitive.plan.md", content)
            self.assertNotEqual(result.returncode, 0)
            combined = result.stdout + result.stderr
            self.assertIn("review", combined)
            self.assertIn("implement", combined)
            self.assertIn("direct dependency", combined)

    def test_missing_loop_check_path_fails(self) -> None:
        content = """---
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
        - path: shared/verdict.json
      loopBackTo: implement
      maxIterations: 2
todos:
  - id: implement-1
    stage: implement
    content: implement the feature
    status: pending
---
"""
        with tempfile.TemporaryDirectory() as tmp_dir:
            result = validate(tmp_dir, "no-loopcheck-path.plan.md", content)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("loopCheck.path", result.stdout + result.stderr)

    def test_planfile_on_review_fails_naming_stage(self) -> None:
        content = f"""---
execution: graph
pipeline:
  stages:
    - id: implement
      runtime: cursor
      instructions: Implement the change end to end.
      produces:
        - path: shared/output.md
    - id: review
      planFile: some/other.plan.md
      runtime: cursor
      dependsOn:
        - implement
      produces:
        - path: shared/verdict.json
          schema: {EVALUATOR_SCHEMA}
      loopBackTo: implement
      maxIterations: 2
      loopCheck:
        path: shared/verdict.json
        schema: {EVALUATOR_SCHEMA}
todos:
  - id: implement-1
    stage: implement
    content: implement the feature
    status: pending
---
"""
        with tempfile.TemporaryDirectory() as tmp_dir:
            result = validate(tmp_dir, "planfile-review.plan.md", content)
            self.assertNotEqual(result.returncode, 0)
            combined = result.stdout + result.stderr
            self.assertIn("review", combined)
            self.assertIn("planFile", combined)
            self.assertIn("inline TODOs", combined)

    def test_planfile_on_target_fails_naming_stage(self) -> None:
        content = f"""---
execution: graph
pipeline:
  stages:
    - id: implement
      planFile: some/other.plan.md
      runtime: cursor
      produces:
        - path: shared/output.md
    - id: review
      runtime: cursor
      instructions: Review the change and report findings.
      dependsOn:
        - implement
      produces:
        - path: shared/verdict.json
          schema: {EVALUATOR_SCHEMA}
      loopBackTo: implement
      maxIterations: 2
      loopCheck:
        path: shared/verdict.json
        schema: {EVALUATOR_SCHEMA}
todos: []
---
"""
        with tempfile.TemporaryDirectory() as tmp_dir:
            result = validate(tmp_dir, "planfile-target.plan.md", content)
            self.assertNotEqual(result.returncode, 0)
            combined = result.stdout + result.stderr
            self.assertIn("implement", combined)
            self.assertIn("planFile", combined)
            self.assertIn("inline TODOs", combined)

    def test_missing_evaluator_schema_fails(self) -> None:
        content = """---
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
        - path: shared/verdict.json
      loopBackTo: implement
      maxIterations: 2
      loopCheck:
        path: shared/verdict.json
todos:
  - id: implement-1
    stage: implement
    content: implement the feature
    status: pending
---
"""
        with tempfile.TemporaryDirectory() as tmp_dir:
            result = validate(tmp_dir, "missing-schema.plan.md", content)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("loopCheck.schema", result.stdout + result.stderr)

    def test_wrong_evaluator_schema_fails(self) -> None:
        content = BASE_STAGES.format(schema="bundle/.ralph/schemas/router-decision.schema.json")
        plan = f"""---
execution: graph
pipeline:
  stages:
{content}
todos:
  - id: implement-1
    stage: implement
    content: implement the feature
    status: pending
---
"""
        with tempfile.TemporaryDirectory() as tmp_dir:
            result = validate(tmp_dir, "wrong-schema.plan.md", plan)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn(EVALUATOR_SCHEMA, result.stdout + result.stderr)

    def test_non_agent_participant_fails(self) -> None:
        content = f"""---
execution: graph
pipeline:
  stages:
    - id: implement
      runtime: cursor
      instructions: Implement the change end to end.
      produces:
        - path: shared/output.md
    - id: review
      type: join
      dependsOn:
        - implement
      produces:
        - path: shared/verdict.json
          schema: {EVALUATOR_SCHEMA}
      loopBackTo: implement
      maxIterations: 2
      loopCheck:
        path: shared/verdict.json
        schema: {EVALUATOR_SCHEMA}
todos:
  - id: implement-1
    stage: implement
    content: implement the feature
    status: pending
---
"""
        with tempfile.TemporaryDirectory() as tmp_dir:
            result = validate(tmp_dir, "non-agent.plan.md", content)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("agent node", result.stdout + result.stderr)

    def test_conditional_downstream_dependency_on_review_fails(self) -> None:
        content = f"""---
execution: graph
pipeline:
  stages:
{BASE_STAGES.format(schema=EVALUATOR_SCHEMA)}
    - id: after
      runtime: cursor
      instructions: Implement the change end to end.
      dependsOn:
        - id: review
          condition: passed
      produces:
        - path: shared/after.md
todos:
  - id: implement-1
    stage: implement
    content: implement the feature
    status: pending
  - id: after-1
    stage: after
    content: after step
    status: pending
---
"""
        with tempfile.TemporaryDirectory() as tmp_dir:
            result = validate(tmp_dir, "conditional-downstream.plan.md", content)
            self.assertNotEqual(result.returncode, 0)
            combined = result.stdout + result.stderr
            self.assertIn("unconditional", combined)
            self.assertIn("after", combined)
            self.assertIn("review", combined)

    def test_authored_review_approved_id_collision_fails(self) -> None:
        content = f"""---
execution: graph
pipeline:
  stages:
{BASE_STAGES.format(schema=EVALUATOR_SCHEMA)}
    - id: review-approved
      runtime: cursor
      instructions: Implement the change end to end.
      produces:
        - path: shared/other.md
todos:
  - id: implement-1
    stage: implement
    content: implement the feature
    status: pending
---
"""
        with tempfile.TemporaryDirectory() as tmp_dir:
            result = validate(tmp_dir, "approved-collision.plan.md", content)
            self.assertNotEqual(result.returncode, 0)
            combined = result.stdout + result.stderr
            self.assertIn("review-approved", combined)
            self.assertIn("collides", combined)

    def test_two_reviews_looping_to_same_target_id_collision_fails(self) -> None:
        content = f"""---
execution: graph
pipeline:
  stages:
    - id: implement
      runtime: cursor
      instructions: Implement the change end to end.
      produces:
        - path: shared/output.md
    - id: review-a
      runtime: cursor
      instructions: Review the change and report findings.
      dependsOn:
        - implement
      produces:
        - path: shared/verdict-a.json
          schema: {EVALUATOR_SCHEMA}
      loopBackTo: implement
      maxIterations: 2
      loopCheck:
        path: shared/verdict-a.json
        schema: {EVALUATOR_SCHEMA}
    - id: review-b
      runtime: cursor
      instructions: Review the change and report findings.
      dependsOn:
        - implement
      produces:
        - path: shared/verdict-b.json
          schema: {EVALUATOR_SCHEMA}
      loopBackTo: implement
      maxIterations: 2
      loopCheck:
        path: shared/verdict-b.json
        schema: {EVALUATOR_SCHEMA}
todos:
  - id: implement-1
    stage: implement
    content: implement the feature
    status: pending
---
"""
        with tempfile.TemporaryDirectory() as tmp_dir:
            result = validate(tmp_dir, "duplicate-target.plan.md", content)
            self.assertNotEqual(result.returncode, 0)
            combined = result.stdout + result.stderr
            self.assertIn("implement-r1", combined)
            self.assertIn("collides", combined)


if __name__ == "__main__":
    unittest.main()
