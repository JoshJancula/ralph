#!/usr/bin/env python3
"""Tests for public-CLI-only workflow operator dialogs."""

from __future__ import annotations

import copy
import hashlib
import json
import sys
import tempfile
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
PYTHON_DIR = REPO_ROOT / "bundle" / ".ralph" / "python"
FIXTURE_DIR = REPO_ROOT / "tests" / "bats" / "workflow" / "fixtures" / "status"
sys.path.insert(0, str(PYTHON_DIR))

import workflow_operator_actions as woa  # noqa: E402
import workflow_tui as wt  # noqa: E402


def fixture(name: str) -> wt.WorkflowSnapshot:
    return wt.parse_status_snapshot(json.loads((FIXTURE_DIR / name).read_text(encoding="utf-8")))


def fingerprint(root: Path) -> str:
    digest = hashlib.sha256()
    for path in sorted(root.rglob("*")):
        digest.update(path.relative_to(root).as_posix().encode("utf-8"))
        digest.update(b"\0")
        if path.is_file():
            digest.update(path.read_bytes())
        digest.update(b"\n")
    return digest.hexdigest()


class RecordingRunner:
    def __init__(self, result: woa.CommandResult | None = None) -> None:
        self.calls: list[tuple[str, ...]] = []
        self.result = result or woa.CommandResult(0)

    def __call__(self, argv: object) -> woa.CommandResult:
        recorded = tuple(argv)  # type: ignore[arg-type]
        self.calls.append(recorded)
        return woa.CommandResult(
            self.result.returncode, self.result.stdout, self.result.stderr, recorded
        )


def action(
    snapshot: wt.WorkflowSnapshot,
    *,
    kind: str = "approval",
    request_id: str | None = None,
    stage_id: str | None = None,
    choices: list[str] | None = None,
    status: str = "outstanding",
) -> dict:
    stage = next(iter(snapshot.stages), None)
    assert stage is not None
    return {
        "requestId": request_id or stage.request_id,
        "kind": kind,
        "runId": snapshot.run.run_id,
        "stageId": stage_id or stage.id,
        "attemptId": f"{stage.id}-{stage.attempt}",
        "question": "Make an operator decision.",
        "choices": choices or {
            "approval": ["approve", "request-changes", "cancel"],
            "input": ["answer", "cancel"],
            "permission": ["allow-once", "allow-run", "allow-always", "deny"],
        }[kind],
        "status": status,
    }


class ActionListTests(unittest.TestCase):
    def test_loads_the_exact_public_actions_list_command(self) -> None:
        snapshot = fixture("dependency-approval-wait.json")
        runner = RecordingRunner(
            woa.CommandResult(0, json.dumps([action(snapshot)]), "")
        )
        records = woa.load_action_records(snapshot, runner=runner, command=("test-ralph",))
        self.assertIsNone(records.error)
        self.assertEqual(runner.calls, [("test-ralph", "workflow", "actions", "list",
                                         "fixture-dep-approval", "--json")])
        self.assertEqual(records.actions[0].request_id, "approval-fixture-001")

    def test_answered_but_unconsumed_requests_are_not_decision_choices(self) -> None:
        snapshot = fixture("sequential-answered-wait.json")
        records = woa.parse_public_actions([action(snapshot, kind="input", status="answered")],
                                           snapshot.run.run_id)
        self.assertEqual(records.actions, ())
        dialog = woa.open_decision_dialog(snapshot, records, "input-fixture-002")
        self.assertEqual(dialog.error, "request is not outstanding")
        resume = woa.open_lifecycle_dialog(snapshot, "resume")
        self.assertIsNone(resume.error)

    def test_stale_replayed_and_conflicting_records_are_never_actionable(self) -> None:
        snapshot = fixture("dependency-approval-wait.json")
        base = action(snapshot)
        replayed = woa.parse_public_actions([base, copy.deepcopy(base)], snapshot.run.run_id)
        self.assertIn("replayed", replayed.error or "")
        conflict = copy.deepcopy(base)
        conflict["choices"] = ["approve", "cancel"]
        conflicting = woa.parse_public_actions([base, conflict], snapshot.run.run_id)
        self.assertIn("conflicting", conflicting.error or "")
        stale = action(snapshot, request_id="old-request")
        stale_records = woa.parse_public_actions([stale], snapshot.run.run_id)
        stale_dialog = woa.open_decision_dialog(snapshot, stale_records, "old-request")
        self.assertIn("stale", stale_dialog.error or "")

    def test_cross_run_and_command_failures_are_dialog_errors(self) -> None:
        snapshot = fixture("dependency-approval-wait.json")
        wrong = action(snapshot)
        wrong["runId"] = "other-run"
        self.assertIn("different run", woa.parse_public_actions([wrong], snapshot.run.run_id).error or "")
        records = woa.load_action_records(
            snapshot,
            runner=RecordingRunner(woa.CommandResult(1, "", "Error: unavailable\n")),
        )
        self.assertEqual(records.error, "Error: unavailable")


class DecisionDialogTests(unittest.TestCase):
    def _records(self, snapshot: wt.WorkflowSnapshot, **kwargs: object) -> woa.ActionRecords:
        return woa.parse_public_actions([action(snapshot, **kwargs)], snapshot.run.run_id)

    def test_approve_requires_confirmation_then_refreshes(self) -> None:
        snapshot = fixture("dependency-approval-wait.json")
        records = self._records(snapshot)
        dialog = woa.open_decision_dialog(snapshot, records, "approval-fixture-001")
        runner = RecordingRunner()
        unconfirmed = woa.dispatch_dialog(snapshot, records, dialog, confirmed=False, runner=runner)
        self.assertFalse(unconfirmed.confirming)
        self.assertEqual(runner.calls, [])
        dispatched = woa.dispatch_dialog(snapshot, records, dialog, confirmed=True, runner=runner)
        self.assertTrue(dispatched.submit_pending)
        self.assertTrue(dispatched.refresh_requested)
        self.assertEqual(
            runner.calls,
            [("ralph", "workflow", "actions", "respond", "fixture-dep-approval",
              "approval-fixture-001", "--decision", "approve", "--yes")],
        )

    def test_permission_reject_requires_confirmation(self) -> None:
        snapshot = fixture("dependency-approval-wait.json")
        payload = copy.deepcopy(json.loads((FIXTURE_DIR / "dependency-approval-wait.json").read_text()))
        payload["stages"][0]["stageKind"] = "executable"
        payload["stages"][0]["requestId"] = "permission-fixture-001"
        payload["stages"][0]["blocker"] = {"kind": "permission", "requestId": "permission-fixture-001"}
        payload["diagnosis"]["requestKind"] = "permission"
        payload["diagnosis"]["requestId"] = "permission-fixture-001"
        snapshot = wt.parse_status_snapshot(payload)
        records = self._records(
            snapshot,
            kind="permission",
            choices=["allow-once", "allow-run", "allow-always", "deny"],
        )
        dialog = woa.select_choice(
            woa.open_decision_dialog(snapshot, records, "permission-fixture-001"), "deny"
        )
        runner = RecordingRunner()
        self.assertTrue(woa.request_confirmation(dialog).confirming)
        dispatched = woa.dispatch_dialog(snapshot, records, dialog, confirmed=True, runner=runner)
        self.assertEqual(runner.calls[0][-3:], ("--decision", "deny", "--yes"))
        self.assertTrue(dispatched.submit_pending)
        self.assertTrue(dispatched.refresh_requested)

    def test_request_changes_requires_feedback_and_uses_exact_identity(self) -> None:
        snapshot = fixture("dependency-approval-wait.json")
        records = self._records(snapshot)
        dialog = woa.select_choice(
            woa.open_decision_dialog(snapshot, records, "approval-fixture-001"), "request-changes"
        )
        self.assertIn("requires feedback", woa.request_confirmation(dialog).error or "")
        dialog = woa.set_message(dialog, "Please tighten the acceptance criteria.")
        runner = RecordingRunner()
        dispatched = woa.dispatch_dialog(snapshot, records, dialog, confirmed=True, runner=runner)
        self.assertTrue(dispatched.submit_pending)
        self.assertTrue(dispatched.refresh_requested)
        self.assertEqual(
            runner.calls[0],
            ("ralph", "workflow", "actions", "respond", "fixture-dep-approval",
             "approval-fixture-001", "--decision", "request-changes", "--message",
             "Please tighten the acceptance criteria.", "--yes"),
        )

    def test_operator_input_answer_requires_and_sends_message(self) -> None:
        snapshot = fixture("sequential-input-wait.json")
        records = self._records(snapshot, kind="input")
        dialog = woa.open_decision_dialog(snapshot, records, "input-fixture-001")
        self.assertIn("feedback", woa.request_confirmation(dialog).error or "")
        dialog = woa.set_message(dialog, "Use staging.")
        runner = RecordingRunner()
        dispatched = woa.dispatch_dialog(snapshot, records, dialog, confirmed=True, runner=runner)
        self.assertTrue(dispatched.submit_pending)
        self.assertTrue(dispatched.refresh_requested)
        self.assertIn("--message", runner.calls[0])

    def test_cancel_and_back_never_invoke_a_command(self) -> None:
        snapshot = fixture("dependency-approval-wait.json")
        records = self._records(snapshot)
        dialog = woa.open_decision_dialog(snapshot, records, "approval-fixture-001")
        self.assertIsNone(woa.cancel_dialog(dialog))
        runner = RecordingRunner()
        cancelled = woa.dispatch_dialog(snapshot, records, dialog, confirmed=False, runner=runner)
        self.assertEqual(runner.calls, [])
        self.assertFalse(cancelled.submit_pending)

    def test_command_failure_remains_in_the_dialog(self) -> None:
        snapshot = fixture("dependency-approval-wait.json")
        records = self._records(snapshot)
        dialog = woa.open_decision_dialog(snapshot, records, "approval-fixture-001")
        failed = woa.dispatch_dialog(
            snapshot, records, dialog, confirmed=True,
            runner=RecordingRunner(woa.CommandResult(1, "", "Error: already resolved\n")),
        )
        self.assertFalse(failed.submit_pending)
        self.assertFalse(failed.refresh_requested)
        self.assertEqual(failed.error, "Error: already resolved")


class LifecycleDialogTests(unittest.TestCase):
    def test_resume_reset_and_recover_use_status_advertised_commands(self) -> None:
        cases = (
            ("sequential-answered-wait.json", "resume",
             ("ralph", "workflow", "resume", "fixture-seq-answered", "--yes")),
            ("dependency-human-changes-requested.json", "reset",
             ("ralph", "workflow", "reset", "fixture-dep-changes", "--stage", "implement", "--yes")),
            ("sequential-stale.json", "recover",
             ("ralph", "workflow", "recover", "fixture-seq-stale", "--yes")),
        )
        for name, operation, expected in cases:
            with self.subTest(operation=operation):
                snapshot = fixture(name)
                dialog = woa.open_lifecycle_dialog(snapshot, operation)
                self.assertIsNone(dialog.error)
                runner = RecordingRunner()
                dispatched = woa.dispatch_dialog(
                    snapshot, woa.ActionRecords(()), dialog, confirmed=True, runner=runner
                )
                self.assertTrue(dispatched.submit_pending)
                self.assertTrue(dispatched.refresh_requested)
                self.assertEqual(runner.calls, [expected])

    def test_reset_target_must_match_public_approval_target(self) -> None:
        snapshot = fixture("dependency-human-changes-requested.json")
        dialog = woa.open_lifecycle_dialog(snapshot, "reset")
        self.assertEqual(dialog.stage_id, "implement")
        changed = woa.WorkflowDialog("reset", snapshot.run.run_id, stage_id="other")
        self.assertIsNone(woa.build_command(snapshot, woa.ActionRecords(()), changed))

    def test_lifecycle_dialog_refuses_unadvertised_or_forged_commands(self) -> None:
        snapshot = fixture("sequential-task-running.json")
        self.assertEqual(woa.open_lifecycle_dialog(snapshot, "resume").error, "operation is not available")
        self.assertIsNone(
            woa.build_command(
                snapshot, woa.ActionRecords(()), woa.WorkflowDialog("cancel", snapshot.run.run_id)
            )
        )
        payload = copy.deepcopy(json.loads((FIXTURE_DIR / "sequential-stale.json").read_text()))
        payload["nextAction"]["argv"] = ["ralph", "workflow", "recover", "other-run"]
        payload["diagnosis"]["nextAction"] = payload["nextAction"]
        forged = wt.parse_status_snapshot(payload)
        self.assertEqual(woa.open_lifecycle_dialog(forged, "recover").error, "operation is not available")


class NoDirectWritesTests(unittest.TestCase):
    def test_python_dialog_logic_never_writes_action_directories(self) -> None:
        snapshot = fixture("dependency-approval-wait.json")
        records = woa.parse_public_actions([action(snapshot)], snapshot.run.run_id)
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp) / "actions"
            (root / "requests").mkdir(parents=True)
            (root / "requests" / "approval-fixture-001.json").write_text('{"sentinel":true}\n')
            before = fingerprint(root)
            dialog = woa.open_decision_dialog(snapshot, records, "approval-fixture-001")
            dialog = woa.select_choice(dialog, "request-changes")
            dialog = woa.set_message(dialog, "Use stronger evidence.")
            dialog = woa.request_confirmation(dialog)
            self.assertIsNotNone(woa.build_command(snapshot, records, dialog))
            self.assertEqual(before, fingerprint(root))


if __name__ == "__main__":
    unittest.main()
