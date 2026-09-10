#!/usr/bin/env python3
"""Tests for planner-output v2 contract (planner_contract.py)."""

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

SCHEMA = REPO_ROOT / "bundle/.ralph/schemas/planner-output.schema.json"
MANIFEST_SCHEMA = REPO_ROOT / "bundle/.ralph/schemas/workflow-plan-manifest.schema.json"
VALIDATE_PLAN = REPO_ROOT / "bundle/.ralph/validate-plan.sh"


def _v2_output(**overrides: object) -> dict:
    base = {
        "schemaVersion": 2,
        "name": "demo-plan",
        "overview": "Implement the demo change",
        "rationale": "Cover the change with the fewest independently verifiable TODOs.",
        "todos": [
            {
                "id": "implement-core",
                "content": "Update owned files for the demo change.",
                "verification": "test -f README.md",
                "status": "pending",
            },
            {
                "id": "verify-tests",
                "content": "Run the narrow unit tests.",
                "verification": "bash scripts/run-python-unit-tests.sh -k plan_split",
                "status": "pending",
                "model": "gpt-5",
            },
        ],
    }
    base.update(overrides)
    return base


class PlannerContractV2Tests(unittest.TestCase):
    def test_validate_planner_config_plan_file_defaults_max_todos(self) -> None:
        cfg = pc.validate_planner_config({"outputMode": "plan-file"})
        self.assertEqual(cfg["outputMode"], "plan-file")
        self.assertEqual(cfg["maxTodos"], 100)

    def test_validate_planner_config_rejects_stages_mode(self) -> None:
        with self.assertRaises(pc.PlannerContractError) as ctx:
            pc.validate_planner_config({"outputMode": "stages", "maxTodos": 3})
        self.assertIn("stages", str(ctx.exception))
        self.assertIn("generated Ralph plan", str(ctx.exception))

    def test_validate_planner_config_rejects_removed_role_allowlists(self) -> None:
        with self.assertRaises(pc.PlannerContractError) as ctx:
            pc.validate_planner_config(
                {
                    "outputMode": "plan-file",
                    "maxTodos": 8,
                    "allowedRoles": ["implementation"],
                }
            )
        self.assertIn("allowedRoles", str(ctx.exception))

    def test_validate_planner_config_rejects_max_over_200(self) -> None:
        with self.assertRaises(pc.PlannerContractError) as ctx:
            pc.validate_planner_config({"outputMode": "plan-file", "maxTodos": 201})
        self.assertIn("200", str(ctx.exception))

    def test_validate_output_accepts_model_only_and_runtime_only(self) -> None:
        output = _v2_output(
            todos=[
                {
                    "id": "model-only",
                    "content": "Use plan default runtime.",
                    "verification": "true",
                    "status": "pending",
                    "model": "gpt-5",
                },
                {
                    "id": "runtime-only",
                    "content": "Switch runtime.",
                    "verification": "true",
                    "status": "pending",
                    "runtime": "codex",
                },
                {
                    "id": "paired",
                    "content": "Explicit pair.",
                    "verification": "true",
                    "status": "pending",
                    "runtime": "claude",
                    "model": "claude-4",
                },
            ]
        )
        pc.validate_output(output, max_todos=10)

    def test_validate_output_rejects_session_strategy(self) -> None:
        output = _v2_output()
        output["sessionStrategy"] = "fresh"
        with self.assertRaises(pc.PlannerContractError) as ctx:
            pc.validate_output(output)
        self.assertIn("sessionStrategy", str(ctx.exception))

    def test_validate_output_rejects_completed_status(self) -> None:
        output = _v2_output()
        output["todos"][0]["status"] = "completed"
        with self.assertRaises(pc.PlannerContractError):
            pc.validate_output(output)

    def test_validate_output_rejects_duplicate_ids(self) -> None:
        output = _v2_output()
        output["todos"][1]["id"] = output["todos"][0]["id"]
        with self.assertRaises(pc.PlannerContractError) as ctx:
            pc.validate_output(output)
        self.assertIn("duplicate", str(ctx.exception))

    def test_validate_output_rejects_over_configured_max(self) -> None:
        todos = [
            {
                "id": f"todo-{index}",
                "content": f"Work {index}",
                "verification": "true",
                "status": "pending",
            }
            for index in range(1, 4)
        ]
        output = _v2_output(todos=todos)
        with self.assertRaises(pc.PlannerContractError) as ctx:
            pc.validate_output(output, max_todos=2)
        self.assertIn("maxTodos", str(ctx.exception))

    def test_load_output_requires_schema_v2(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            artifact = Path(tmp) / "planner.json"
            artifact.write_text(json.dumps({"rationale": "x", "items": []}), encoding="utf-8")
            with self.assertRaises(pc.PlannerContractError):
                pc.load_output(str(artifact), str(SCHEMA))

    def test_load_and_validate_round_trip(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            artifact = Path(tmp) / "planner.json"
            artifact.write_text(json.dumps(_v2_output()), encoding="utf-8")
            loaded = pc.load_output(str(artifact), str(SCHEMA))
            pc.validate_output(loaded, max_todos=40)

    def test_render_plan_writes_defaults_and_passes_validate_plan(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            artifact = Path(tmp) / "planner.json"
            plan_out = Path(tmp) / "generated.plan.md"
            artifact.write_text(json.dumps(_v2_output()), encoding="utf-8")
            output = pc.load_output(str(artifact), str(SCHEMA))
            text = pc.render_and_validate_plan(
                output,
                default_runtime="cursor",
                default_model="auto",
                output_path=str(plan_out),
                validate_plan_sh=str(VALIDATE_PLAN),
                max_todos=40,
            )
            self.assertTrue(plan_out.is_file())
            self.assertIn("runtime: cursor", text)
            self.assertIn("model: auto", text)
            self.assertIn("sessionStrategy: fresh", text)
            self.assertIn("model: gpt-5", text)
            self.assertNotIn("role:", text)
            self.assertIn("Execute exactly one TODO", text)

    def test_render_freezes_defaults_and_preserves_todo_overrides(self) -> None:
        """Pure render: plan defaults freeze; model-only/runtime-only/paired stay local."""
        output = _v2_output(
            todos=[
                {
                    "id": "use-defaults",
                    "content": "Inherit frozen plan defaults.",
                    "verification": "true",
                    "status": "pending",
                },
                {
                    "id": "model-only",
                    "content": "Override model only.",
                    "verification": "true",
                    "status": "pending",
                    "model": "gpt-5",
                },
                {
                    "id": "runtime-only",
                    "content": "Override runtime only.",
                    "verification": "true",
                    "status": "pending",
                    "runtime": "codex",
                },
                {
                    "id": "paired",
                    "content": "Override both.",
                    "verification": "true",
                    "status": "pending",
                    "runtime": "claude",
                    "model": "claude-4",
                },
            ]
        )
        text = pc.render_plan_markdown(
            output,
            default_runtime="cursor",
            default_model="auto",
        )
        # Frozen plan defaults (routing belongs on the rendered plan, not JSON).
        self.assertIn("runtime: cursor", text)
        self.assertIn("model: auto", text)
        self.assertIn("sessionStrategy: fresh", text)
        # Default TODO has no local runtime/model lines.
        self.assertRegex(
            text,
            r"(?ms)  - id: use-defaults\n    content:",
        )
        # Model-only keeps model, does not invent a local runtime line.
        self.assertRegex(
            text,
            r"(?ms)  - id: model-only\n    model: gpt-5\n    content:",
        )
        # Runtime-only switches runtime without a model line.
        self.assertRegex(
            text,
            r"(?ms)  - id: runtime-only\n    runtime: codex\n    content:",
        )
        # Paired override is an explicit pair.
        self.assertRegex(
            text,
            r"(?ms)  - id: paired\n    runtime: claude\n    model: claude-4\n    content:",
        )
        # Planner JSON remains routing-neutral: render does not mutate input.
        self.assertNotIn("runtime", output["todos"][0])
        self.assertNotIn("model", output["todos"][0])

    def test_render_omits_nullable_default_model(self) -> None:
        text = pc.render_plan_markdown(
            _v2_output(),
            default_runtime="opencode",
            default_model="",
        )
        self.assertIn("runtime: opencode", text)
        self.assertNotRegex(text, r"(?m)^model:")

    def test_stdlib_one_todo_implementation_and_qa_rendering(self) -> None:
        """Atomic fixes must render as one executable TODO without padding."""
        cases = (
            (
                "implementation",
                "Fix the defect and verify .ralph-workspace/artifacts/ns/implementation-handoff.md.",
            ),
            (
                "qa",
                "Run independent checks and write .ralph-workspace/artifacts/ns/qa-handoff.md.",
            ),
        )
        for name, content in cases:
            with self.subTest(name=name):
                output = _v2_output(
                    name=f"bug-fix-{name}",
                    todos=[
                        {
                            "id": f"{name}-atomic",
                            "content": content,
                            "verification": f"test -s .ralph-workspace/artifacts/ns/{name}-handoff.md",
                            "status": "pending",
                        }
                    ],
                )
                text = pc.render_plan_markdown(
                    output,
                    default_runtime="cursor",
                    default_model="auto",
                )
                self.assertEqual(len(__import__("re").findall(r"(?m)^  - id: ", text)), 1)
                self.assertIn(content, text)
                self.assertIn("Execute exactly one TODO", text)

    def test_stdlib_76_todo_implementation_and_short_qa_handoff(self) -> None:
        """Large plans stay complete while QA remains independently handoff-driven."""
        implementation_todos = [
            {
                "id": f"implementation-slice-{index:02d}",
                "content": f"Implement independently verifiable slice {index}.",
                "verification": f"test -f slice-{index:02d}.ok",
                "status": "pending",
            }
            for index in range(1, 77)
        ]
        implementation = _v2_output(
            name="feature-delivery-implementation",
            todos=implementation_todos,
        )
        implementation_text = pc.render_plan_markdown(
            implementation,
            default_runtime="cursor",
            default_model="auto",
        )
        implementation_ids = __import__("re").findall(
            r"(?m)^  - id: ([a-z0-9-]+)$", implementation_text
        )
        self.assertEqual(len(implementation_ids), 76)
        self.assertEqual(implementation_ids, [todo["id"] for todo in implementation_todos])
        self.assertNotIn("padding", implementation_text.lower())
        self.assertNotIn("truncated", implementation_text.lower())
        self.assertIn("slice-76.ok", implementation_text)

        qa = _v2_output(
            name="feature-delivery-qa",
            todos=[
                {
                    "id": "acceptance-check",
                    "content": "Run the independent acceptance check using the implementation handoff.",
                    "verification": "test -s .ralph-workspace/artifacts/ns/implementation-handoff.md",
                    "status": "pending",
                },
                {
                    "id": "regression-check",
                    "content": "Run the cheapest justified regression check.",
                    "verification": "test -s .ralph-workspace/artifacts/ns/qa-handoff.md",
                    "status": "pending",
                },
            ],
        )
        qa_text = pc.render_plan_markdown(
            qa,
            default_runtime="cursor",
            default_model="auto",
        )
        self.assertEqual(len(__import__("re").findall(r"(?m)^  - id: ", qa_text)), 2)
        self.assertIn("implementation handoff", qa_text)
        self.assertIn("qa-handoff.md", qa_text)

    def test_render_rejects_unsupported_or_missing_default_runtime(self) -> None:
        with self.assertRaises(pc.PlannerContractError) as missing:
            pc.render_plan_markdown(_v2_output(), default_runtime="")
        self.assertIn("default runtime", str(missing.exception))
        with self.assertRaises(pc.PlannerContractError) as bad:
            pc.render_plan_markdown(_v2_output(), default_runtime="not-a-runtime")
        self.assertIn("default runtime", str(bad.exception))

    def test_build_and_validate_manifest(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            plan = Path(tmp) / "plan.md"
            plan.write_text(
                "---\nname: x\noverview: y\nruntime: cursor\ntodos:\n"
                "  - id: one\n    content: do\n    verification: true\n    status: pending\n---\n",
                encoding="utf-8",
            )
            source = Path(tmp) / "planner.json"
            source.write_text("{}", encoding="utf-8")
            manifest = pc.build_manifest(
                producer_stage_id="plan-implementation",
                producer_attempt=1,
                source_artifact=str(source),
                plan_path=str(plan),
                todo_count=1,
                created_at="2026-01-01T00:00:00Z",
            )
            pc.validate_manifest(manifest, schema_path=str(MANIFEST_SCHEMA))
            self.assertEqual(manifest["schemaVersion"], 1)
            self.assertEqual(manifest["todoCount"], 1)
            self.assertTrue(manifest["planPath"].startswith("/"))

    def test_legacy_parser_is_read_only_and_drops_roles(self) -> None:
        legacy = {
            "rationale": "old",
            "items": [
                {
                    "id": "worker-1",
                    "content": "Do work",
                    "runtime": "cursor",
                    "role": "implementation",
                }
            ],
            "verification": "true",
        }
        parsed = pc.parse_legacy_planner_artifact(legacy)
        self.assertEqual(parsed["items"][0]["id"], "worker-1")
        self.assertNotIn("role", parsed["items"][0])
        self.assertNotIn("runtime", parsed["items"][0])

    def test_legacy_parser_rejects_v2(self) -> None:
        with self.assertRaises(pc.PlannerContractError):
            pc.parse_legacy_planner_artifact(_v2_output())

    def test_no_discover_roles_or_stage_materialize_exports(self) -> None:
        self.assertFalse(hasattr(pc, "discover_roles"))
        self.assertFalse(hasattr(pc, "DEFAULT_ROLES"))
        self.assertFalse(hasattr(pc, "materialize_output"))
        self.assertFalse(hasattr(pc, "HARD_MAX_STAGES"))

    def test_render_plan_includes_operator_input_protocol(self) -> None:
        text = pc.render_plan_markdown(
            _v2_output(),
            default_runtime="cursor",
            default_model="gpt-5",
        )
        self.assertIn("<!-- OPERATOR_INPUT: START -->", text)
        self.assertIn("<!-- OPERATOR_INPUT: END -->", text)
        self.assertIn("ralph workflow actions request --question", text)
        self.assertIn("never request the secret value", text)
        # Nonce content must never appear in rendered instructions.
        self.assertNotRegex(text, r"\bnonce\b")

    def test_operator_input_protocol_block_helper(self) -> None:
        block = pc.operator_input_protocol_block()
        self.assertTrue(block.startswith("<!-- OPERATOR_INPUT: START -->"))
        self.assertIn("<!-- OPERATOR_INPUT: END -->", block)
        self.assertIn("ralph workflow actions request", block)
        self.assertNotRegex(block, r"\bnonce\b")


if __name__ == "__main__":
    unittest.main()
