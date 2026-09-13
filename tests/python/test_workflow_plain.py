#!/usr/bin/env python3
"""Golden and streaming tests for the plain workflow renderer."""

from __future__ import annotations

import json
import sys
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
PYTHON_DIR = REPO_ROOT / "bundle" / ".ralph" / "python"
FIXTURE_DIR = REPO_ROOT / "tests" / "bats" / "workflow" / "fixtures" / "status"
SNAPSHOT_DIR = Path(__file__).with_name("snapshots")
sys.path.insert(0, str(PYTHON_DIR))

import workflow_plain as wp  # noqa: E402
import workflow_tui as wt  # noqa: E402


def view_from_fixture(name: str, **stage_updates: object) -> wt.WorkflowViewModel:
    payload = json.loads((FIXTURE_DIR / name).read_text(encoding="utf-8"))
    if stage_updates:
        payload["stages"][0].update(stage_updates)
    return wt.view_from_snapshot(wt.parse_status_snapshot(payload))


class TestPlainStatusGoldenOutput(unittest.TestCase):
    def test_approval_and_input_frames_match_golden_text(self) -> None:
        cases = (
            ("dependency-approval-wait.json", {}, "workflow_plain_approval.txt"),
            (
                "sequential-input-wait.json",
                {"requestQuestion": "Which staging configuration should Ralph use?"},
                "workflow_plain_input.txt",
            ),
        )
        for fixture, updates, snapshot_name in cases:
            with self.subTest(fixture=fixture):
                actual = "\n".join(wp.render_status_lines(view_from_fixture(fixture, **updates))) + "\n"
                expected = (SNAPSHOT_DIR / snapshot_name).read_text(encoding="utf-8")
                self.assertEqual(actual, expected)

    def test_renderer_removes_terminal_control_sequences(self) -> None:
        view = view_from_fixture(
            "sequential-input-wait.json",
            requestQuestion="\x1b[31mChoose the staging configuration\x1b[0m",
        )
        output = "\n".join(wp.render_status_lines(view))
        self.assertNotIn("\x1b", output)
        self.assertIn("Question: Choose the staging configuration", output)

    def test_exhausted_review_includes_verdict_and_two_step_recovery(self) -> None:
        payload = json.loads(
            json.dumps(
                {
                    "schemaVersion": 1,
                    "run": {
                        "runId": "run-exhausted",
                        "workflowId": "bug-fix",
                        "mode": "dependency",
                        "entryKind": "task",
                        "task": "Fix regression",
                        "taskProvenance": "explicit",
                        "state": "failed",
                        "sourcePath": "/tmp/bug-fix.workflow.md",
                        "sourceKind": "project",
                        "inputPath": "/tmp/bug-fix.graph.json",
                        "createdAt": "2026-09-02T00:00:00Z",
                        "updatedAt": "2026-09-02T01:00:00Z",
                        "inputPlan": None,
                    },
                    "stages": [
                        {
                            "id": "implement-r2",
                            "index": 0,
                            "state": "succeeded",
                            "stageKind": "plan-backed",
                            "attempt": 1,
                            "completedTodos": 2,
                            "totalTodos": 2,
                            "artifacts": [],
                            "evidence": [],
                            "workspaceMode": "worktree",
                            "workspacePath": "/tmp/ralph-worktree",
                            "workspaceAvailable": True,
                            "changesetManifest": "/tmp/changeset.json",
                            "changedFiles": ["src/model.sh"],
                        },
                        {
                            "id": "review-r2",
                            "index": 1,
                            "state": "failed",
                            "stageKind": "executable",
                            "attempt": 1,
                            "completedTodos": 0,
                            "totalTodos": 0,
                            "artifacts": ["/tmp/review-r2-verdict.json"],
                            "evidence": [],
                        }
                    ],
                    "diagnosis": {
                        "state": "blocked",
                        "reasonCode": "loop-exhausted",
                        "summary": "final review still requested changes",
                        "stageId": "review-r2",
                        "requestKind": None,
                        "requestId": None,
                        "evidence": ["requested change: remove the unrelated resolver rewrite"],
                        "retryable": False,
                        "nextAction": {
                            "label": "retry final repair",
                            "argv": ["ralph", "workflow", "reset", "run-exhausted", "--stage", "implement-r2"],
                        },
                    },
                    "nextAction": {
                        "label": "retry final repair",
                        "argv": ["ralph", "workflow", "reset", "run-exhausted", "--stage", "implement-r2"],
                    },
                }
            )
        )
        output = "\n".join(
            wp.render_status_lines(wt.view_from_snapshot(wt.parse_status_snapshot(payload)))
        )
        self.assertIn("Review verdict: /tmp/review-r2-verdict.json", output)
        self.assertIn("Review note 1: remove the unrelated resolver rewrite", output)
        self.assertIn("Requested changes: jq -r '.feedback[]'", output)
        self.assertIn("Retry behavior: reset implement-r2", output)
        self.assertIn("Continue run: ralph workflow resume run-exhausted", output)
        self.assertIn("Workspace: worktree (available)", output)
        self.assertIn("Git worktree: yes", output)
        self.assertIn("Open code: cd /tmp/ralph-worktree", output)
        self.assertIn("Handoff report: ralph workflow handoff run-exhausted", output)


class TestPlainWatchStreaming(unittest.TestCase):
    def test_initial_frame_then_only_changed_frames_and_events(self) -> None:
        renderer = wp.PlainWatchRenderer()
        view = view_from_fixture("dependency-approval-wait.json")

        first = renderer.render(view, ("stage approve-plan waiting",))
        self.assertIsNotNone(first.frame)
        self.assertEqual(first.events, ("stage approve-plan waiting",))

        unchanged = renderer.render(view, ("stage approve-plan waiting",))
        self.assertIsNone(unchanged.frame)
        self.assertEqual(unchanged.events, ())

        changed_payload = json.loads((FIXTURE_DIR / "dependency-approval-wait.json").read_text())
        changed_payload["diagnosis"]["state"] = "blocked"
        changed_payload["stages"][0]["state"] = "blocked"
        changed = renderer.render(
            wt.view_from_snapshot(wt.parse_status_snapshot(changed_payload)),
            ("stage approve-plan blocked",),
        )
        self.assertIn("State: blocked (human-approval)", changed.frame or ())
        self.assertEqual(changed.events, ("stage approve-plan blocked",))


class TestPlainCapabilitySelection(unittest.TestCase):
    def test_plain_is_required_for_noninteractive_and_accessibility_conditions(self) -> None:
        cases = (
            {"force_plain": True},
            {"stdin_isatty": False},
            {"stdout_isatty": False},
            {"environ": {"CI": "1"}},
            {"environ": {"TERM": "dumb"}},
            {"environ": {"RALPH_GRAPH_SCREEN_READER": "yes"}},
            {"environ": {"ACCESSIBILITY_SCREEN_READER": "true"}},
        )
        for options in cases:
            with self.subTest(options=options):
                self.assertTrue(wp.plain_output_required(**options))

    def test_no_color_plain_frame_is_identical_and_escape_free(self) -> None:
        view = view_from_fixture("dependency-approval-wait.json")
        normal = "\n".join(wp.render_status_lines(view))
        no_color = "\n".join(wp.render_status_lines(view))
        self.assertEqual(normal, no_color)
        self.assertNotIn("\x1b", no_color)


if __name__ == "__main__":
    unittest.main()
