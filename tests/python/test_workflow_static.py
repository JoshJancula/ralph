#!/usr/bin/env python3
"""Unit tests for finite workflow status and runs static renderers."""

from __future__ import annotations

import json
import sys
import unittest
from datetime import datetime, timezone
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
PYTHON_DIR = REPO_ROOT / "bundle" / ".ralph" / "python"
FIXTURE_DIR = REPO_ROOT / "tests" / "bats" / "workflow" / "fixtures" / "status"
sys.path.insert(0, str(PYTHON_DIR))

import ralph_term as rt  # noqa: E402
import workflow_static as ws  # noqa: E402
import workflow_tui as wt  # noqa: E402


def load_view(name: str) -> tuple[wt.WorkflowViewModel, dict]:
    payload = ws.coerce_status_payload(json.loads((FIXTURE_DIR / name).read_text(encoding="utf-8")))
    return wt.view_from_snapshot(wt.parse_status_snapshot(payload)), payload


def plain_lines(name: str) -> list[str]:
    view, payload = load_view(name)
    style = rt.Style(0)
    return [rt.strip_ansi(line) for line in ws.render_status_with_plan_paths(view, payload, style)]


class TestStatusOutcomeClasses(unittest.TestCase):
    CASES = (
        ("sequential-task-running.json", "Outcome: running (live-owner)", "accent", "\033[36m"),
        ("dependency-plan-succeeded.json", "Outcome: succeeded (none)", "success", "\033[32m"),
        ("sequential-failed.json", "Outcome: failed (stage-failed)", "failure", "\033[31m"),
        ("sequential-stale.json", "Outcome: stale (stale-owner)", "warning", "\033[33m"),
        ("dependency-approval-wait.json", "Outcome: waiting (human-approval)", "warning", "\033[33m"),
        ("sequential-input-wait.json", "Outcome: waiting (operator-input)", "warning", "\033[33m"),
        ("dependency-cancelled.json", "Outcome: cancelled (", "muted", None),
        ("dependency-blocked.json", "Outcome: blocked (", "warning", "\033[33m"),
        ("dependency-human-changes-requested.json", "Outcome: blocked (human-changes-requested)", "warning", "\033[33m"),
        ("sequential-answered-wait.json", "Outcome: waiting (operator-input)", "warning", "\033[33m"),
    )

    def test_every_outcome_class_leads_and_colors_semantic_roles(self) -> None:
        for fixture, outcome_prefix, role, code16 in self.CASES:
            with self.subTest(fixture=fixture):
                view, payload = load_view(fixture)
                plain = ws.render_status_with_plan_paths(view, payload, rt.Style(0))
                self.assertTrue(plain[0].startswith(outcome_prefix), plain[0])
                self.assertEqual(sum(1 for line in plain if line.startswith("Action: ")), 1)

                colored = ws.render_status_with_plan_paths(view, payload, rt.Style(16))
                first = colored[0]
                self.assertIn("Outcome:", first)
                if code16 is None:
                    # cancelled uses muted (dim), which is still a role sequence
                    self.assertIn("\033[2m", first)
                else:
                    self.assertIn(code16, first)
                    # Ensure the state value — not only the label — carries the role.
                    self.assertIn(code16, first.split("Outcome:", 1)[1])

                colored256 = ws.render_status_with_plan_paths(view, payload, rt.Style(256))
                if role == "failure":
                    self.assertIn("38;5;167", colored256[0])
                elif role == "success":
                    self.assertIn("38;5;71", colored256[0])
                elif role == "accent":
                    self.assertIn("38;5;80", colored256[0])
                elif role == "warning":
                    self.assertIn("38;5;179", colored256[0])

    def test_no_color_and_depth_zero_are_ansi_free(self) -> None:
        view, payload = load_view("sequential-task-running.json")
        for style in (rt.Style(0), rt.Style(16)):
            # Depth 0 always plain; emulate NO_COLOR via Style(0).
            if style.depth == 0:
                text = "\n".join(ws.render_status_with_plan_paths(view, payload, style))
                self.assertNotIn("\033[", text)

    def test_primary_block_before_secondary_paths(self) -> None:
        lines = plain_lines("sequential-task-running.json")
        action_idx = next(i for i, line in enumerate(lines) if line.startswith("Action:"))
        run_idx = next(i for i, line in enumerate(lines) if line.startswith("Run:"))
        self.assertLess(action_idx, run_idx)
        self.assertTrue(any(line.startswith("Plan progress:") for line in lines))
        self.assertTrue(any(line.startswith("Status:") for line in lines))

    def test_status_lists_concrete_lifecycle_groups(self) -> None:
        lines = plain_lines("sequential-task-running.json")
        self.assertIn("Complete (1): research", lines)
        self.assertIn("Active (1): implement", lines)

        failed = plain_lines("sequential-failed.json")
        self.assertTrue(any(line.startswith("Failed (1): implement") for line in failed))
        self.assertIn(
            "Action: ralph workflow logs fixture-seq-failed --stage implement",
            failed,
        )
        self.assertFalse(any(line.startswith("Handoff:") for line in failed))

    def test_exhausted_review_explains_failure_and_recovery(self) -> None:
        payload = ws.coerce_status_payload(
            {
                "schemaVersion": 1,
                "run": {
                    "runId": "run-exhausted",
                    "workflowId": "bug-fix",
                    "mode": "dependency",
                    "entryKind": "task",
                    "task": "Fix the regression",
                    "taskProvenance": "explicit",
                    "state": "failed",
                },
                "stages": [
                    {
                        "id": "implement-r2",
                        "state": "succeeded",
                        "stageKind": "plan-backed",
                        "workspaceMode": "worktree",
                        "workspacePath": "/tmp/ralph-worktree",
                        "workspaceAvailable": True,
                        "baseRevision": "a" * 40,
                        "changesetManifest": "/tmp/implement-r2-changeset.json",
                        "changedFiles": ["src/model.sh", "tests/model.bats"],
                    },
                    {
                        "id": "review-r2",
                        "state": "failed",
                        "stageKind": "executable",
                        "reasonCode": "review-changes-required-no-edge",
                        "artifacts": ["/tmp/review-r2-verdict.json"],
                    }
                ],
                "diagnosis": {
                    "state": "blocked",
                    "reasonCode": "loop-exhausted",
                    "summary": "final review still requested changes; integration and verification did not run",
                    "stageId": "review-r2",
                    "requestKind": None,
                    "requestId": None,
                    "evidence": [
                        "final review verdict /tmp/review-r2-verdict.json",
                        "requested change: remove the unrelated resolver rewrite",
                    ],
                    "retryable": False,
                    "nextAction": {
                        "label": "retry final repair",
                        "argv": [
                            "ralph",
                            "workflow",
                            "reset",
                            "run-exhausted",
                            "--stage",
                            "implement-r2",
                        ],
                    },
                },
            }
        )
        payload["nextAction"] = payload["diagnosis"]["nextAction"]
        view = wt.view_from_snapshot(wt.parse_status_snapshot(payload))
        lines = ws.render_status_with_plan_paths(view, payload, rt.Style(0))
        joined = "\n".join(lines)
        self.assertIn("Review verdict: /tmp/review-r2-verdict.json", joined)
        self.assertIn("Review note 1: remove the unrelated resolver rewrite", joined)
        self.assertIn("Requested changes: jq -r '.feedback[]'", joined)
        self.assertIn("Action: ralph workflow reset run-exhausted --stage implement-r2", joined)
        self.assertIn("next fresh attempt receives review-r2's final review feedback", joined)
        self.assertIn("Continue run: ralph workflow resume run-exhausted", joined)
        self.assertIn("Code stage: implement-r2", joined)
        self.assertIn("Workspace: worktree (available)", joined)
        self.assertIn("Git worktree: yes", joined)
        self.assertIn("Open code: cd /tmp/ralph-worktree", joined)
        self.assertIn("Changeset: /tmp/implement-r2-changeset.json", joined)
        self.assertIn("Handoff report: ralph workflow handoff run-exhausted", joined)

        handoff = "\n".join(ws.render_handoff_lines(view, rt.Style(0)))
        self.assertIn("Workflow task handoff", handoff)
        self.assertIn("Retry: ralph workflow reset run-exhausted --stage implement-r2", handoff)
        self.assertIn(
            "Start new run: ralph workflow start bug-fix --task 'Fix the regression'",
            handoff,
        )
        self.assertIn("Run access: another Ralph process must use the same project and state root", handoff)
        self.assertIn("Agent instruction: Finish failed Ralph workflow run-exhausted", handoff)


class TestRunsTableAndTsv(unittest.TestCase):
    NOW = datetime(2026, 8, 27, 1, 5, tzinfo=timezone.utc)

    def _rows(self) -> list[ws.RunListRow]:
        return [
            ws.parse_run_row(
                {
                    "runId": "run-20260827T010000Z-short",
                    "workflowId": "bug-fix",
                    "mode": "sequential",
                    "entryKind": "task",
                    "state": "running",
                    "createdAt": "2026-08-27T01:00:00Z",
                    "updatedAt": "2026-08-27T01:01:00Z",
                    "task": "short",
                }
            ),
            ws.parse_run_row(
                {
                    "runId": "run-20260827T010000Z-verylongidentifier-extra",
                    "workflowId": "feature-delivery",
                    "mode": "dependency",
                    "entryKind": "plan",
                    "state": "failed",
                    "createdAt": "2026-08-27T00:00:00Z",
                    "updatedAt": "2026-08-27T00:30:00Z",
                    "task": "A very long task description that must truncate without breaking columns",
                }
            ),
            ws.parse_run_row(
                {
                    "runId": "run-20260827T010000Z-wait",
                    "workflowId": "plan-delivery",
                    "mode": "sequential",
                    "entryKind": "task",
                    "state": "waiting",
                    "createdAt": "2026-08-27T01:02:00Z",
                    "updatedAt": "2026-08-27T01:04:00Z",
                    "task": "wait for input",
                }
            ),
            ws.parse_run_row(
                {
                    "runId": "run-20260827T010000Z-ok",
                    "workflowId": "bug-fix",
                    "mode": "sequential",
                    "entryKind": "task",
                    "state": "succeeded",
                    "createdAt": "2026-08-26T01:00:00Z",
                    "updatedAt": "2026-08-26T02:00:00Z",
                    "task": "done",
                }
            ),
        ]

    def test_tsv_schema_is_stable_and_ansi_free(self) -> None:
        lines = ws.render_runs_tsv(self._rows())
        self.assertEqual(len(lines), 4)
        first = lines[0].split("\t")
        self.assertEqual(len(first), 6)
        self.assertEqual(
            first,
            [
                "run-20260827T010000Z-short",
                "bug-fix",
                "sequential",
                "task",
                "running",
                "2026-08-27T01:00:00Z",
            ],
        )
        self.assertTrue(all("\033[" not in line for line in lines))

    def test_empty_list_messages(self) -> None:
        self.assertEqual(ws.render_runs_tsv(()), ())
        self.assertEqual(
            ws.render_runs_table((), rt.Style(0), width=80, now=self.NOW),
            ("No workflow runs found.",),
        )

    def test_table_width_truncation_and_semantic_state_colors(self) -> None:
        for width in (40, 80, 120):
            with self.subTest(width=width):
                lines = ws.render_runs_table(
                    self._rows(), rt.Style(16), width=width, now=self.NOW
                )
                self.assertIn("ID", rt.strip_ansi(lines[0]))
                body = "\n".join(lines[2:])
                self.assertIn("\033[36m", body)  # running cyan
                self.assertIn("\033[31m", body)  # failed red
                self.assertIn("\033[33m", body)  # waiting yellow
                self.assertIn("\033[32m", body)  # succeeded green
                for line in lines[2:]:
                    self.assertLessEqual(rt.visible_len(line), width)

    def test_no_color_table_has_no_ansi(self) -> None:
        text = "\n".join(
            ws.render_runs_table(self._rows(), rt.Style(0), width=80, now=self.NOW)
        )
        self.assertNotIn("\033[", text)

    def test_resolve_style_honors_no_color_and_force(self) -> None:
        style, _ = ws.resolve_style(
            environ={"NO_COLOR": "1"},
            force_color=True,
            stdout_isatty=True,
        )
        self.assertEqual(style.depth, 0)
        style, _ = ws.resolve_style(
            environ={"RALPH_WORKFLOW_NO_COLOR": "1"},
            stdout_isatty=True,
        )
        self.assertEqual(style.depth, 0)
        style, width = ws.resolve_style(
            depth=256,
            width=100,
            force_color=True,
            stdout_isatty=False,
            environ={},
        )
        self.assertEqual(style.depth, 256)
        self.assertEqual(width, 100)


if __name__ == "__main__":
    unittest.main()
