#!/usr/bin/env python3
"""Subprocess-based unit tests for pipeline.tooling parsing/validation.

plan-todo.sh embeds its pipeline parser/validator as a python3 heredoc
invoked from bash functions (plan_pipeline_validate_plan,
plan_pipeline_graph_json, plan_pipeline_orch_json). These tests source the
shell library and call those functions the same way callers (bats,
run-plan.sh) do, since the parser is not importable as a standalone python
module.
"""

from __future__ import annotations

import json
import subprocess
import tempfile
import unittest
from pathlib import Path

PROJECT_ROOT = Path(__file__).parent.parent.parent
PLAN_TODO_LIB = PROJECT_ROOT / "bundle" / ".ralph" / "bash-lib" / "plan-todo.sh"

GRAPH_PLAN_TEMPLATE = """---
execution: graph
pipeline:
  stages:
    - id: research
      runtime: cursor
      instructions: Research the topic and write findings.
      produces:
        - path: shared/research.md
    - id: qa
      runtime: cursor
      instructions: Run QA and report results.
      dependsOn:
        - research
      produces:
        - path: shared/qa.md
{tooling_block}
todos:
  - id: research-1
    stage: research
    content: do the research
    status: pending
  - id: qa-1
    stage: qa
    content: check the research
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


TOOLING_BLOCK_VALID = """  tooling:
    defaultProfile: ralph-compact
    overrides:
      qa: ralph-read-heavy
"""

TOOLING_BLOCK_UNKNOWN_STAGE = """  tooling:
    defaultProfile: ralph-compact
    overrides:
      bogus-stage: ralph-read-heavy
"""

TOOLING_BLOCK_UNKNOWN_PROFILE = """  tooling:
    defaultProfile: ralph-compact
    overrides:
      qa: not-a-real-profile
"""

TOOLING_BLOCK_NO_DEFAULT = """  tooling:
    overrides:
      qa: ralph-read-heavy
"""

TOOLING_BLOCK_WITH_RALPH_MODE = """  ralphMode: ralph
  tooling:
    defaultProfile: ralph-compact
"""

STAGE_TOOLING_PROFILE_PLAN = """---
execution: graph
pipeline:
  stages:
    - id: research
      runtime: cursor
      instructions: Research the topic and write findings.
      toolingProfile: {profile}
      produces:
        - path: shared/research.md
todos:
  - id: research-1
    stage: research
    content: do the research
    status: pending
---
"""

STAGE_RALPH_MODE_PLAN = """---
execution: graph
pipeline:
  stages:
    - id: research
      runtime: cursor
      instructions: Research the topic and write findings.
      ralphMode: ralph
      produces:
        - path: shared/research.md
todos:
  - id: research-1
    stage: research
    content: do the research
    status: pending
---
"""


class TestPipelineToolingParsing(unittest.TestCase):
    """Tests for the pipeline.tooling authoring block."""

    def test_valid_tooling_compiles_and_applies_override(self) -> None:
        with tempfile.TemporaryDirectory() as tmp_dir:
            plan = write_plan(
                tmp_dir,
                "graph-tooling-valid.plan.md",
                GRAPH_PLAN_TEMPLATE.format(tooling_block=TOOLING_BLOCK_VALID),
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
            graph = json.loads(graph_result.stdout)

            self.assertEqual(
                graph.get("tooling"),
                {"defaultProfile": "ralph-compact", "overrides": {"qa": "ralph-read-heavy"}},
            )

            nodes_by_id = {node["id"]: node for node in graph["nodes"]}
            self.assertEqual(nodes_by_id["research"]["stage"]["toolingProfile"], "ralph-compact")
            self.assertEqual(nodes_by_id["qa"]["stage"]["toolingProfile"], "ralph-read-heavy")

    def test_orchestration_tooling_round_trips(self) -> None:
        with tempfile.TemporaryDirectory() as tmp_dir:
            plan = write_plan(
                tmp_dir,
                "orch-tooling-valid.plan.md",
                GRAPH_PLAN_TEMPLATE.format(tooling_block=TOOLING_BLOCK_VALID).replace(
                    "execution: graph", "execution: orchestration"
                ),
            )
            orch_result = run_lib_function(f"plan_pipeline_orch_json '{plan}'")
            self.assertEqual(
                orch_result.returncode,
                0,
                msg=f"orch compile failed: {orch_result.stdout}\n{orch_result.stderr}",
            )
            orch = json.loads(orch_result.stdout)
            self.assertEqual(
                orch.get("tooling"),
                {"defaultProfile": "ralph-compact", "overrides": {"qa": "ralph-read-heavy"}},
            )
            stages_by_id = {stage["id"]: stage for stage in orch["stages"]}
            self.assertEqual(stages_by_id["research"]["toolingProfile"], "ralph-compact")
            self.assertEqual(stages_by_id["qa"]["toolingProfile"], "ralph-read-heavy")

    def test_override_unknown_stage_fails(self) -> None:
        with tempfile.TemporaryDirectory() as tmp_dir:
            plan = write_plan(
                tmp_dir,
                "graph-tooling-unknown-stage.plan.md",
                GRAPH_PLAN_TEMPLATE.format(tooling_block=TOOLING_BLOCK_UNKNOWN_STAGE),
            )
            result = run_lib_function(f"plan_pipeline_validate_plan '{plan}'")
            self.assertNotEqual(result.returncode, 0)
            combined = result.stdout + result.stderr
            self.assertIn("bogus-stage", combined)

    def test_unknown_profile_name_fails(self) -> None:
        with tempfile.TemporaryDirectory() as tmp_dir:
            plan = write_plan(
                tmp_dir,
                "graph-tooling-unknown-profile.plan.md",
                GRAPH_PLAN_TEMPLATE.format(tooling_block=TOOLING_BLOCK_UNKNOWN_PROFILE),
            )
            result = run_lib_function(f"plan_pipeline_validate_plan '{plan}'")
            self.assertNotEqual(result.returncode, 0)
            combined = result.stdout + result.stderr
            self.assertIn("not-a-real-profile", combined)

    def test_missing_default_profile_fails(self) -> None:
        with tempfile.TemporaryDirectory() as tmp_dir:
            plan = write_plan(
                tmp_dir,
                "graph-tooling-no-default.plan.md",
                GRAPH_PLAN_TEMPLATE.format(tooling_block=TOOLING_BLOCK_NO_DEFAULT),
            )
            result = run_lib_function(f"plan_pipeline_validate_plan '{plan}'")
            self.assertNotEqual(result.returncode, 0)
            combined = result.stdout + result.stderr
            self.assertIn("defaultProfile", combined)

    def test_stage_toolingProfile_is_accepted_by_the_stage_key_parser(self) -> None:
        with tempfile.TemporaryDirectory() as tmp_dir:
            plan = write_plan(
                tmp_dir,
                "graph-stage-tooling-profile.plan.md",
                STAGE_TOOLING_PROFILE_PLAN.format(profile="ralph-compact"),
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
            graph = json.loads(graph_result.stdout)
            nodes_by_id = {node["id"]: node for node in graph["nodes"]}
            self.assertEqual(nodes_by_id["research"]["stage"]["toolingProfile"], "ralph-compact")

    def test_stage_toolingProfile_bogus_value_is_accepted_by_the_stage_key_parser(self) -> None:
        # The stage/node key parser only decides whether the field name is
        # recognized syntax; value-level enum validation for toolingProfile
        # lives in the schema validators (validate-graph-schema.sh and
        # validate-orchestration-schema.sh), not in this parser.
        with tempfile.TemporaryDirectory() as tmp_dir:
            plan = write_plan(
                tmp_dir,
                "graph-stage-tooling-profile-bogus.plan.md",
                STAGE_TOOLING_PROFILE_PLAN.format(profile="bogus"),
            )
            validate_result = run_lib_function(f"plan_pipeline_validate_plan '{plan}'")
            self.assertEqual(
                validate_result.returncode,
                0,
                msg=f"validate failed: {validate_result.stdout}\n{validate_result.stderr}",
            )

    def test_stage_ralphMode_is_rejected_as_unknown_field(self) -> None:
        with tempfile.TemporaryDirectory() as tmp_dir:
            plan = write_plan(
                tmp_dir,
                "graph-stage-ralph-mode.plan.md",
                STAGE_RALPH_MODE_PLAN,
            )
            result = run_lib_function(f"plan_pipeline_validate_plan '{plan}'")
            self.assertNotEqual(result.returncode, 0)
            combined = result.stdout + result.stderr
            self.assertIn("ralphMode", combined)
            self.assertIn("unknown", combined.lower())

    def test_ralph_mode_and_tooling_together_fails_naming_both(self) -> None:
        with tempfile.TemporaryDirectory() as tmp_dir:
            plan = write_plan(
                tmp_dir,
                "graph-tooling-and-ralph-mode.plan.md",
                GRAPH_PLAN_TEMPLATE.format(tooling_block=TOOLING_BLOCK_WITH_RALPH_MODE),
            )
            result = run_lib_function(f"plan_pipeline_validate_plan '{plan}'")
            self.assertNotEqual(result.returncode, 0)
            combined = result.stdout + result.stderr
            self.assertIn("ralphMode", combined)
            self.assertIn("tooling", combined)


if __name__ == "__main__":
    unittest.main()
