#!/usr/bin/env python3
"""Stdlib tests for wizard-workflow-template discovery and materialize routing.

Contracts:
- Bundled workflows resolve under .ralph/workflows/ (not workflow-templates/).
- Listing the canonical dir yields exactly the shipped IDs in EXPECTED_IDS.
- Public mode sequential|dependency maps to internal execution; legacy engine
  maps back to mode; serializers emit mode never engine; mutual exclusion and
  unknown-mode errors are raised.
- Materialize routing: fallback fills unresolved stages only; explicit overrides
  preserved; provided-plan header is consumer-only; skipped model stays absent;
  run-entry metadata captures mode/defaults/planInput before strip.
Loaded via ralph_script_loader (hyphenated script path).
"""

from __future__ import annotations

import io
import sys
import tempfile
import unittest
from contextlib import redirect_stdout
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))

from ralph_script_loader import load_ralph_script

REPO_ROOT = Path(__file__).resolve().parents[2]
RALPH_ROOT = REPO_ROOT / "bundle" / ".ralph"
EXPECTED_IDS = (
    "bug-fix",
    "feature-delivery",
    "human-verified-delivery",
    "investigation",
    "plan-delivery",
    "refactor",
    "release-gate",
)

wft = load_ralph_script("wizard-workflow-template")


class TestBundledWorkflowsPath(unittest.TestCase):
    def test_bundled_workflows_dir_is_canonical_workflows_subdir(self) -> None:
        path = wft.bundled_workflows_dir(RALPH_ROOT)
        self.assertEqual(path, RALPH_ROOT / "workflows")
        self.assertEqual(wft.BUNDLED_WORKFLOWS_SUBDIR, "workflows")
        self.assertNotEqual(path.name, wft.LEGACY_WORKFLOWS_SUBDIR)
        self.assertEqual(wft.LEGACY_WORKFLOWS_SUBDIR, "workflow-templates")

    def test_old_workflow_templates_directory_absent(self) -> None:
        legacy = RALPH_ROOT / wft.LEGACY_WORKFLOWS_SUBDIR
        self.assertFalse(legacy.exists(), f"legacy path still present: {legacy}")
        self.assertFalse(legacy.is_dir())


class TestListWorkflows(unittest.TestCase):
    def test_list_workflows_exact_seven_ids_from_canonical_path(self) -> None:
        workflows_dir = wft.bundled_workflows_dir(RALPH_ROOT)
        self.assertTrue(workflows_dir.is_dir(), f"missing canonical dir: {workflows_dir}")
        entries = wft.list_workflows(workflows_dir)
        ids = [entry["id"] for entry in entries]
        self.assertEqual(ids, list(EXPECTED_IDS))
        self.assertEqual(len(ids), len(EXPECTED_IDS))
        for entry in entries:
            self.assertTrue(Path(entry["path"]).is_file())
            self.assertTrue(entry["path"].endswith(f"{entry['id']}.workflow.md"))
            # Bundled sources still carry legacy engine until a later TODO;
            # list exposes the public mode mapping only.
            self.assertEqual(entry["mode"], "dependency")
            self.assertNotIn("engine", entry)

    def test_cmd_list_prints_json_lines_for_exact_seven(self) -> None:
        workflows_dir = wft.bundled_workflows_dir(RALPH_ROOT)
        buf = io.StringIO()
        with redirect_stdout(buf):
            wft.cmd_list(str(workflows_dir))
        lines = [line for line in buf.getvalue().splitlines() if line.strip()]
        self.assertEqual(len(lines), len(EXPECTED_IDS))
        import json

        ids = [json.loads(line)["id"] for line in lines]
        self.assertEqual(ids, list(EXPECTED_IDS))
        for line in lines:
            payload = json.loads(line)
            self.assertEqual(payload["mode"], "dependency")
            self.assertNotIn("engine", payload)

    def test_list_workflows_empty_when_dir_missing(self) -> None:
        missing = RALPH_ROOT / "no-such-workflows-dir"
        self.assertEqual(wft.list_workflows(missing), [])


class TestWorkflowModeLegacyMapAndSerializer(unittest.TestCase):
    def test_mode_to_execution_matrix(self) -> None:
        self.assertEqual(wft.mode_to_execution("sequential"), "orchestration")
        self.assertEqual(wft.mode_to_execution("dependency"), "graph")

    def test_legacy_engine_maps_to_public_mode(self) -> None:
        self.assertEqual(wft.execution_to_mode("orchestration"), "sequential")
        self.assertEqual(wft.execution_to_mode("graph"), "dependency")
        mode, execution = wft.resolve_workflow_mode(engine="graph")
        self.assertEqual(mode, "dependency")
        self.assertEqual(execution, "graph")
        mode, execution = wft.resolve_workflow_mode(engine="orchestration")
        self.assertEqual(mode, "sequential")
        self.assertEqual(execution, "orchestration")

    def test_resolve_mode_maps_to_internal_execution(self) -> None:
        self.assertEqual(
            wft.resolve_workflow_mode(mode="sequential"),
            ("sequential", "orchestration"),
        )
        self.assertEqual(
            wft.resolve_workflow_mode(mode="dependency"),
            ("dependency", "graph"),
        )

    def test_both_mode_and_engine_raises(self) -> None:
        with self.assertRaises(wft.WorkflowModeError) as ctx:
            wft.resolve_workflow_mode(mode="dependency", engine="graph")
        self.assertIn("mode and engine", str(ctx.exception))

    def test_unknown_mode_raises(self) -> None:
        with self.assertRaises(wft.WorkflowModeError) as ctx:
            wft.mode_to_execution("pipeline")
        self.assertIn("mode", str(ctx.exception))
        self.assertIn("sequential", str(ctx.exception))

    def test_serialize_workflow_mode_never_emits_engine(self) -> None:
        self.assertEqual(wft.serialize_workflow_mode("sequential"), "mode: sequential")
        self.assertEqual(wft.serialize_workflow_mode("dependency"), "mode: dependency")
        line = wft.serialize_workflow_mode("dependency")
        self.assertNotIn("engine", line)

    def test_normalize_frontmatter_maps_legacy_engine_and_drops_engine(self) -> None:
        lines = [
            "name: demo",
            "kind: workflow",
            "engine: graph",
            "pipeline:",
        ]
        out = wft.normalize_workflow_frontmatter_mode(lines)
        joined = "\n".join(out)
        self.assertIn("mode: dependency", out)
        self.assertNotIn("engine:", joined)
        self.assertTrue(any(line.startswith("kind:") for line in out))

    def test_normalize_frontmatter_rejects_both_mode_and_engine(self) -> None:
        lines = [
            "kind: workflow",
            "mode: sequential",
            "engine: orchestration",
        ]
        with self.assertRaises(wft.WorkflowModeError):
            wft.normalize_workflow_frontmatter_mode(lines)

    def test_cmd_write_serializer_emits_mode_not_engine(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            src = Path(tmp) / "src.workflow.md"
            dest = Path(tmp) / "out.workflow.md"
            src.write_text(
                "---\n"
                "name: src\n"
                "kind: workflow\n"
                "engine: orchestration\n"
                "pipeline:\n"
                "  stages:\n"
                "    - id: only\n"
                "      runtime: cursor\n"
                "todos:\n"
                "  - id: t1\n"
                "    stage: only\n"
                "    content: '{{TASK}}'\n"
                "    status: pending\n"
                "---\n",
                encoding="utf-8",
            )
            wft.cmd_write(str(src), str(dest), "written", "overview text", None)
            text = dest.read_text(encoding="utf-8")
            self.assertIn("mode: sequential", text)
            self.assertNotIn("engine:", text)
            self.assertIn("name: written", text)


class TestMaterializeRoutingPure(unittest.TestCase):
    def test_capture_run_entry_metadata_before_strip(self) -> None:
        meta = wft.capture_run_entry_metadata(
            {
                "kind": "workflow",
                "mode": "dependency",
                "execution": "graph",
                "defaults": {"runtime": "cursor", "model": "auto"},
                "_plan_input_present": True,
                "planInput": {"stage": "implement", "required": False},
            }
        )
        self.assertEqual(meta["kind"], "workflow")
        self.assertEqual(meta["mode"], "dependency")
        self.assertEqual(meta["execution"], "graph")
        self.assertEqual(meta["defaults"], {"runtime": "cursor", "model": "auto"})
        self.assertEqual(meta["planInput"], {"stage": "implement", "required": False})

    def test_fallback_fills_unresolved_and_skips_model(self) -> None:
        stages = [
            {"id": "research", "instructions": "keep"},
            {"id": "implement", "planFrom": "plan-implementation"},
            {"id": "approve", "type": "approval", "question": "ok?", "changesTarget": "research"},
        ]
        out = wft.apply_materialized_stage_routing(
            stages, fallback_runtime="claude"
        )
        self.assertEqual(out[0]["runtime"], "claude")
        self.assertNotIn("model", out[0])
        self.assertEqual(out[0]["instructions"], "keep")
        self.assertEqual(out[1]["runtime"], "claude")
        self.assertEqual(out[1]["planFrom"], "plan-implementation")
        self.assertNotIn("runtime", out[2])
        self.assertNotIn("model", out[2])

    def test_explicit_override_and_different_runtime(self) -> None:
        stages = [
            {"id": "a"},
            {"id": "b", "runtime": "cursor"},
            {"id": "c", "runtime": "claude", "model": "sonnet"},
        ]
        out = wft.apply_materialized_stage_routing(
            stages,
            fallback_runtime="codex",
            fallback_model="gpt-x",
        )
        self.assertEqual(out[0]["runtime"], "codex")
        self.assertEqual(out[0]["model"], "gpt-x")
        self.assertEqual(out[1]["runtime"], "cursor")
        self.assertNotIn("model", out[1])
        self.assertEqual(out[2]["runtime"], "claude")
        self.assertEqual(out[2]["model"], "sonnet")

    def test_provided_plan_header_consumer_only(self) -> None:
        stages = [
            {"id": "plan-implementation", "planner": {"outputMode": "plan-file"}},
            {"id": "implement", "planFrom": "plan-implementation"},
            {"id": "qa"},
        ]
        out = wft.apply_materialized_stage_routing(
            stages,
            provided_plan_runtime="antigravity",
            provided_plan_model="agy-1",
            plan_input_stage="implement",
        )
        self.assertNotIn("runtime", out[0])
        self.assertEqual(out[1]["runtime"], "antigravity")
        self.assertEqual(out[1]["model"], "agy-1")
        self.assertNotIn("runtime", out[2])
        self.assertNotIn("model", out[2])

    def test_workflow_defaults_fill_when_no_invocation(self) -> None:
        stages = [{"id": "research"}, {"id": "pinned", "runtime": "claude"}]
        out = wft.apply_materialized_stage_routing(
            stages,
            workflow_runtime="cursor",
            workflow_model="auto",
        )
        self.assertEqual(out[0]["runtime"], "cursor")
        self.assertEqual(out[0]["model"], "auto")
        self.assertEqual(out[1]["runtime"], "claude")
        self.assertNotIn("model", out[1])

    def test_todos_routing_guard(self) -> None:
        before = [{"id": "t1", "content": "x", "status": "pending"}]
        after = [{"id": "t1", "content": "x", "status": "pending", "runtime": "cursor"}]
        with self.assertRaises(wft.WorkflowMaterializeError):
            wft.assert_todos_routing_untouched(before, after)


if __name__ == "__main__":
    unittest.main()
