#!/usr/bin/env python3
"""Tests for bounded dynamic planner decomposition (planner_contract.py)."""

from __future__ import annotations

import json
import os
import tempfile
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
import sys

sys.path.insert(0, str(REPO_ROOT / "bundle/.ralph/python"))

import planner_contract as pc  # noqa: E402


def _planner_config(**overrides: object) -> dict:
    base = {
        "outputMode": "stages",
        "maxTodos": 8,
        "maxStages": 3,
        "allowedRuntimes": ["cursor"],
        "allowedAgents": ["implementation"],
        "allowedModels": ["auto"],
    }
    base.update(overrides)
    return base


def _output_items(count: int = 2) -> dict:
    items = []
    for index in range(count):
        items.append(
            {
                "id": f"worker-{index + 1}",
                "content": f"Do work slice {index + 1}",
                "runtime": "cursor",
                "agent": "implementation",
            }
        )
    return {
        "rationale": "Split the feature into bounded worker slices.",
        "items": items,
        "artifactRelationships": [
            {
                "from": ".ralph-workspace/artifacts/{{ARTIFACT_NS}}/input.md",
                "to": ".ralph-workspace/artifacts/{{ARTIFACT_NS}}/worker-1.md",
            }
        ],
        "verification": "bash scripts/run-bats.sh tests/bats/plan/validate-plan.bats",
    }


class PlannerContractTests(unittest.TestCase):
    def test_validate_orchestration_accepts_planner_stage(self) -> None:
        orchestration = {
            "stages": [
                {
                    "id": "planner",
                    "planner": _planner_config(),
                }
            ]
        }
        pc.validate_orchestration(orchestration)

    def test_validate_orchestration_rejects_missing_allowed_agents(self) -> None:
        orchestration = {
            "stages": [
                {
                    "id": "planner",
                    "planner": _planner_config(allowedAgents=[]),
                }
            ]
        }
        with self.assertRaises(pc.PlannerContractError):
            pc.validate_orchestration(orchestration)

    def test_validate_output_rejects_oversized_stages(self) -> None:
        planner = _planner_config(maxStages=1)
        output = _output_items(count=2)
        with self.assertRaises(pc.PlannerContractError):
            pc.validate_output(output, planner, planner_stage_id="planner")

    def test_validate_output_rejects_unknown_agent(self) -> None:
        planner = _planner_config()
        output = _output_items(count=1)
        output["items"][0]["agent"] = "not-a-real-agent"
        with self.assertRaises(pc.PlannerContractError):
            pc.validate_output(
                output,
                planner,
                known_agents=set(pc.DEFAULT_AGENTS),
                planner_stage_id="planner",
            )

    def test_validate_output_rejects_path_traversal(self) -> None:
        planner = _planner_config(outputMode="plan-file")
        output = _output_items(count=1)
        output["artifactRelationships"] = [{"from": "../escape.md", "to": "safe.md"}]
        with self.assertRaises(pc.PlannerContractError):
            pc.validate_output(output, planner, planner_stage_id="planner")

    def test_materialize_stages_writes_generated_plans_only(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            workspace = Path(tmp)
            operator_plan = (
                workspace
                / ".ralph-workspace/orchestration-plans/demo/demo-operator.plan.md"
            )
            operator_plan.parent.mkdir(parents=True, exist_ok=True)
            operator_plan.write_text("# operator plan\n", encoding="utf-8")

            planner = _planner_config()
            output = _output_items(count=2)
            manifest = pc.materialize_output(
                output,
                planner,
                workspace=str(workspace),
                plan_key="demo",
                planner_stage_id="planner",
            )

            self.assertEqual(manifest["outputMode"], "stages")
            self.assertEqual(len(manifest["stages"]), 2)
            generated_dir = workspace / ".ralph-workspace/orchestration-plans/demo/generated"
            self.assertTrue(generated_dir.is_dir())
            self.assertTrue((generated_dir / "worker-1.plan.md").is_file())
            self.assertTrue((generated_dir / "worker-2.plan.md").is_file())
            self.assertEqual(operator_plan.read_text(encoding="utf-8"), "# operator plan\n")

    def test_materialize_plan_file_refuses_overwrite(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            workspace = Path(tmp)
            generated = (
                workspace
                / ".ralph-workspace/orchestration-plans/demo/generated/planner-decomposition.plan.md"
            )
            generated.parent.mkdir(parents=True, exist_ok=True)
            generated.write_text("existing\n", encoding="utf-8")

            planner = _planner_config(outputMode="plan-file", maxTodos=4)
            output = _output_items(count=1)
            with self.assertRaises(pc.PlannerContractError):
                pc.materialize_output(
                    output,
                    planner,
                    workspace=str(workspace),
                    plan_key="demo",
                    planner_stage_id="planner",
                )

    def test_materialize_dry_run_does_not_write_files(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            workspace = Path(tmp)
            planner = _planner_config()
            output = _output_items(count=1)
            manifest = pc.materialize_output(
                output,
                planner,
                workspace=str(workspace),
                plan_key="demo",
                planner_stage_id="planner",
                dry_run=True,
            )
            generated = workspace / ".ralph-workspace/orchestration-plans/demo/generated"
            self.assertFalse(generated.exists())
            self.assertEqual(len(manifest["stages"]), 1)

    def test_hard_max_todos_cannot_be_exceeded_by_env(self) -> None:
        prev = os.environ.get("RALPH_PLANNER_HARD_MAX_TODOS")
        os.environ["RALPH_PLANNER_HARD_MAX_TODOS"] = "2"
        try:
            with self.assertRaises(pc.PlannerContractError):
                pc.validate_orchestration(
                    {
                        "stages": [
                            {
                                "id": "planner",
                                "planner": _planner_config(maxTodos=5, outputMode="plan-file"),
                            }
                        ]
                    }
                )
        finally:
            if prev is None:
                os.environ.pop("RALPH_PLANNER_HARD_MAX_TODOS", None)
            else:
                os.environ["RALPH_PLANNER_HARD_MAX_TODOS"] = prev

    def test_load_output_requires_schema(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            artifact = Path(tmp) / "planner.json"
            artifact.write_text(json.dumps({"rationale": "x"}), encoding="utf-8")
            with self.assertRaises(pc.PlannerContractError):
                pc.load_output(str(artifact))


if __name__ == "__main__":
    unittest.main()
