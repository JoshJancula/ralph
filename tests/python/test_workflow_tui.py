#!/usr/bin/env python3
"""Unit tests for the engine-neutral public workflow TUI read model."""

from __future__ import annotations

import copy
import hashlib
import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

REPO_ROOT = Path(__file__).resolve().parents[2]
PYTHON_DIR = REPO_ROOT / "bundle" / ".ralph" / "python"
FIXTURE_DIR = REPO_ROOT / "tests" / "bats" / "workflow" / "fixtures" / "status"
sys.path.insert(0, str(PYTHON_DIR))

import workflow_tui as wt  # noqa: E402


def fixture_payload(name: str) -> dict:
    return json.loads((FIXTURE_DIR / name).read_text(encoding="utf-8"))


def tree_fingerprint(root: Path) -> str:
    digest = hashlib.sha256()
    for path in sorted(root.rglob("*")):
        digest.update(path.relative_to(root).as_posix().encode("utf-8"))
        digest.update(b"\0")
        if path.is_file():
            digest.update(path.read_bytes())
        elif path.is_dir():
            digest.update(b"directory")
        digest.update(b"\n")
    return digest.hexdigest()


class TestFixedWorkflowStatusFixtures(unittest.TestCase):
    EXPECTED_DIAGNOSES = {
        "dependency-approval-wait.json": "human-approval",
        "dependency-blocked.json": "missing-artifact",
        "dependency-cancelled.json": "cancelled",
        "dependency-human-changes-requested.json": "human-changes-requested",
        "dependency-plan-succeeded.json": "none",
        "sequential-answered-wait.json": "operator-input",
        "sequential-failed.json": "stage-failed",
        "sequential-input-wait.json": "operator-input",
        "sequential-stale.json": "stale-owner",
        "sequential-task-running.json": "live-owner",
    }

    def test_every_fixed_fixture_builds_the_read_model(self) -> None:
        seen_modes = set()
        seen_reasons = set()
        for filename, expected_reason in self.EXPECTED_DIAGNOSES.items():
            with self.subTest(filename=filename):
                snapshot = wt.parse_status_snapshot(fixture_payload(filename))
                seen_modes.add(snapshot.run.mode)
                seen_reasons.add(snapshot.diagnosis.reason_code)
                self.assertEqual(snapshot.diagnosis.reason_code, expected_reason)
                self.assertTrue(snapshot.run.run_id.startswith("fixture-"))
                self.assertTrue(snapshot.run.task)
                self.assertEqual(
                    [stage.index for stage in snapshot.stages],
                    sorted(stage.index for stage in snapshot.stages),
                )
                view = wt.view_from_snapshot(snapshot)
                if snapshot.stages:
                    self.assertIsNotNone(view.selected_stage)
        self.assertEqual(seen_modes, {"sequential", "dependency"})
        self.assertEqual(
            seen_reasons,
            {
                "human-approval",
                "missing-artifact",
                "cancelled",
                "human-changes-requested",
                "none",
                "operator-input",
                "stage-failed",
                "stale-owner",
                "live-owner",
            },
        )

    def test_task_stage_progress_evidence_and_next_action_are_modeled(self) -> None:
        running = wt.parse_status_snapshot(fixture_payload("sequential-task-running.json"))
        implement = next(stage for stage in running.stages if stage.id == "implement")
        self.assertEqual(running.run.task, "Fix the timeout")
        self.assertEqual(implement.kind, "plan-backed")
        self.assertEqual((implement.progress.completed, implement.progress.total), (2, 5))
        self.assertEqual(implement.progress.current_todo_id, "implement-core")
        self.assertEqual(implement.progress.fraction, 0.4)
        self.assertEqual(running.diagnosis.evidence, ("owner pid 4242",))

        approval = wt.parse_status_snapshot(fixture_payload("dependency-approval-wait.json"))
        self.assertEqual(approval.stages[0].evidence, ("/fixtures/evidence.md",))
        self.assertEqual(approval.next_action.argv[:3], ("ralph", "workflow", "actions"))

    def test_dependency_edges_are_modeled_with_branch_conditions(self) -> None:
        payload = fixture_payload("dependency-approval-wait.json")
        payload["stages"][0]["dependencies"] = [
            {"stageId": "review", "condition": "passed"},
            {"stageId": "review-r1", "condition": "passed"},
        ]
        snapshot = wt.parse_status_snapshot(payload)
        self.assertEqual(
            snapshot.stages[0].dependencies,
            (
                wt.StageDependency("review", "passed"),
                wt.StageDependency("review-r1", "passed"),
            ),
        )

    def test_dependency_navigation_order_follows_prerequisites(self) -> None:
        payload = copy.deepcopy(fixture_payload("sequential-task-running.json"))
        payload["run"]["mode"] = "dependency"
        implement = payload["stages"][1]
        implement.update(
            id="implement",
            index=0,
            dependencies=[
                {"stageId": "investigate", "condition": None},
                {"stageId": "plan", "condition": None},
            ],
        )
        investigate = payload["stages"][0]
        investigate.update(id="investigate", index=1, dependencies=[])
        plan = copy.deepcopy(implement)
        plan.update(
            id="plan",
            index=2,
            dependencies=[{"stageId": "investigate", "condition": None}],
        )
        payload["stages"] = [implement, investigate, plan]
        snapshot = wt.parse_status_snapshot(payload)
        self.assertEqual(
            [stage.id for stage in wt.topology_ordered_stages(snapshot)],
            ["investigate", "plan", "implement"],
        )

    def test_dependency_progress_defers_unentered_conditional_routes(self) -> None:
        payload = copy.deepcopy(fixture_payload("sequential-task-running.json"))
        payload["run"]["mode"] = "dependency"
        root = payload["stages"][0]
        root.update(id="review", state="running", dependencies=[])
        branch = payload["stages"][1]
        branch.update(
            id="implement-r1",
            state="queued",
            attempt=0,
            dependencies=[{"stageId": "review", "condition": "changes-required"}],
        )
        child = copy.deepcopy(branch)
        child.update(
            id="review-r1",
            index=2,
            dependencies=[{"stageId": "implement-r1", "condition": None}],
        )
        payload["stages"] = [root, branch, child]

        snapshot = wt.parse_status_snapshot(payload)
        self.assertEqual(
            wt.deferred_progress_stage_ids(snapshot),
            frozenset({"implement-r1", "review-r1"}),
        )
        self.assertEqual(
            [stage.id for stage in wt.revealed_progress_stages(snapshot)],
            ["review"],
        )

        branch["state"] = "running"
        branch["attempt"] = 1
        snapshot = wt.parse_status_snapshot(payload)
        self.assertEqual(wt.deferred_progress_stage_ids(snapshot), frozenset())
        self.assertEqual(
            [stage.id for stage in wt.revealed_progress_stages(snapshot)],
            ["review", "implement-r1", "review-r1"],
        )

    def test_stage_order_uses_public_index_and_source_order_as_tiebreaker(self) -> None:
        payload = fixture_payload("sequential-task-running.json")
        payload["stages"][0]["index"] = 20
        payload["stages"][1]["index"] = 10
        payload["stages"].append(
            {"id": "verify", "index": 10, "state": "queued", "stageKind": "supervisor"}
        )
        snapshot = wt.parse_status_snapshot(payload)
        self.assertEqual([stage.id for stage in snapshot.stages], ["implement", "verify", "research"])

    def test_skipped_is_a_stage_state_but_not_a_run_state(self) -> None:
        payload = fixture_payload("sequential-task-running.json")
        payload["stages"][0]["state"] = "skipped"
        snapshot = wt.parse_status_snapshot(payload)
        self.assertEqual(snapshot.stages[0].state, "skipped")

        payload["run"]["state"] = "skipped"
        with self.assertRaisesRegex(wt.SnapshotValidationError, "run.state is unsupported"):
            wt.parse_status_snapshot(payload)


class TestSelectionAndRefresh(unittest.TestCase):
    def setUp(self) -> None:
        self.payload = fixture_payload("sequential-task-running.json")
        self.payload["stages"].append(
            {"id": "verify", "index": 2, "state": "waiting", "stageKind": "supervisor"}
        )

    def test_diagnosis_stage_wins_then_attention_wins_then_active_stage(self) -> None:
        self.payload["diagnosis"]["stageId"] = "verify"
        view = wt.view_from_snapshot(wt.parse_status_snapshot(self.payload))
        self.assertEqual(view.selected_stage_id, "verify")

        self.payload["diagnosis"]["stageId"] = None
        view = wt.view_from_snapshot(wt.parse_status_snapshot(self.payload))
        self.assertEqual(view.selected_stage_id, "verify")

        self.payload["stages"][-1]["state"] = "queued"
        view = wt.view_from_snapshot(wt.parse_status_snapshot(self.payload))
        self.assertEqual(view.selected_stage_id, "implement")

    def test_refresh_preserves_selection_when_stage_remains(self) -> None:
        original = wt.view_from_snapshot(wt.parse_status_snapshot(self.payload), "research")
        refreshed_payload = copy.deepcopy(self.payload)
        refreshed_payload["stages"][1]["state"] = "succeeded"
        refreshed = wt.reconcile_refresh(original, wt.parse_status_snapshot(refreshed_payload))
        self.assertEqual(refreshed.selected_stage_id, "research")
        self.assertIsNone(refreshed.error)

    def test_refresh_selects_attention_when_selected_stage_disappears(self) -> None:
        original = wt.view_from_snapshot(wt.parse_status_snapshot(self.payload), "research")
        refreshed_payload = copy.deepcopy(self.payload)
        refreshed_payload["stages"] = refreshed_payload["stages"][1:]
        refreshed = wt.reconcile_refresh(original, wt.parse_status_snapshot(refreshed_payload))
        self.assertEqual(refreshed.selected_stage_id, "verify")

    def test_refresh_does_not_carry_selection_across_run_identity(self) -> None:
        original = wt.view_from_snapshot(wt.parse_status_snapshot(self.payload), "research")
        different = copy.deepcopy(self.payload)
        different["run"]["runId"] = "fixture-other-run"
        different["diagnosis"]["stageId"] = "verify"
        refreshed = wt.reconcile_refresh(original, wt.parse_status_snapshot(different))
        self.assertEqual(refreshed.selected_stage_id, "verify")


class TestCompatibilityAndErrors(unittest.TestCase):
    def test_additive_unknown_fields_are_ignored_at_every_level(self) -> None:
        payload = fixture_payload("dependency-approval-wait.json")
        payload["futureTopLevel"] = {"version": 2}
        payload["run"]["futureRunField"] = True
        payload["stages"][0]["futureStageField"] = [1, 2]
        payload["diagnosis"]["futureDiagnosisField"] = "future"
        payload["nextAction"]["futureActionField"] = "future"
        snapshot = wt.parse_status_snapshot(payload)
        self.assertEqual(snapshot.run.run_id, "fixture-dep-approval")
        self.assertEqual(snapshot.stages[0].kind, "approval")

    def test_missing_required_fields_fail_with_path(self) -> None:
        cases = (
            ((), "nextAction", "status.nextAction is required"),
            (("run",), "runId", "run.runId is required"),
            (("stages", 0), "stageKind", "stages[0].stageKind is required"),
            (("diagnosis",), "evidence", "diagnosis.evidence is required"),
        )
        for parents, key, message in cases:
            with self.subTest(path=parents + (key,)):
                payload = fixture_payload("dependency-approval-wait.json")
                target = payload
                for parent in parents:
                    target = target[parent]
                del target[key]
                with self.assertRaisesRegex(wt.SnapshotValidationError, message.replace("[", "\\[").replace("]", "\\]")):
                    wt.parse_status_snapshot(payload)

    def test_malformed_json_is_a_safe_ui_error(self) -> None:
        completed = subprocess.CompletedProcess(("ralph",), 0, stdout="{not-json", stderr="")
        with mock.patch.object(wt.subprocess, "run", return_value=completed):
            view = wt.load_workflow_view("fixture-seq-running")
        self.assertIsNone(view.snapshot)
        self.assertEqual(view.error.code, "malformed-json")
        self.assertNotIn("Traceback", view.error.message)

    def test_invalid_snapshot_is_a_safe_ui_error(self) -> None:
        payload = fixture_payload("sequential-task-running.json")
        del payload["diagnosis"]["summary"]
        completed = subprocess.CompletedProcess(("ralph",), 0, stdout=json.dumps(payload), stderr="")
        with mock.patch.object(wt.subprocess, "run", return_value=completed):
            view = wt.load_workflow_view("fixture-seq-running")
        self.assertEqual(view.error.code, "invalid-snapshot")
        self.assertIn("diagnosis.summary", view.error.detail)

    def test_timeout_is_a_safe_ui_error_and_preserves_previous_frame(self) -> None:
        previous = wt.view_from_snapshot(
            wt.parse_status_snapshot(fixture_payload("sequential-task-running.json"))
        )
        with mock.patch.object(
            wt.subprocess,
            "run",
            side_effect=subprocess.TimeoutExpired(("ralph",), 0.01),
        ):
            view = wt.load_workflow_view("fixture-seq-running", previous=previous, timeout=0.01)
        self.assertIs(view.snapshot, previous.snapshot)
        self.assertEqual(view.error.code, "timeout")

    def test_failure_never_displays_a_previous_frame_from_another_run(self) -> None:
        previous = wt.view_from_snapshot(
            wt.parse_status_snapshot(fixture_payload("sequential-task-running.json"))
        )
        with mock.patch.object(
            wt.subprocess,
            "run",
            side_effect=subprocess.TimeoutExpired(("ralph",), 0.01),
        ):
            view = wt.load_workflow_view("fixture-other-run", previous=previous, timeout=0.01)
        self.assertIsNone(view.snapshot)
        self.assertEqual(view.error.code, "timeout")

    def test_nonzero_command_and_wrong_run_identity_are_safe_errors(self) -> None:
        unavailable = subprocess.CompletedProcess(("ralph",), 1, stdout="", stderr="run not found\n")
        with mock.patch.object(wt.subprocess, "run", return_value=unavailable):
            view = wt.load_workflow_view("fixture-missing")
        self.assertEqual(view.error.code, "unavailable")
        self.assertEqual(view.error.detail, "run not found")

        payload = fixture_payload("sequential-task-running.json")
        completed = subprocess.CompletedProcess(("ralph",), 0, stdout=json.dumps(payload), stderr="")
        with mock.patch.object(wt.subprocess, "run", return_value=completed):
            view = wt.load_workflow_view("fixture-different")
        self.assertEqual(view.error.code, "invalid-snapshot")
        self.assertIn("does not match", view.error.detail)


class TestPublicBoundaryAndReadOnlyLoading(unittest.TestCase):
    def test_loader_uses_exact_public_status_argv(self) -> None:
        payload = fixture_payload("sequential-task-running.json")
        completed = subprocess.CompletedProcess(("ralph",), 0, stdout=json.dumps(payload), stderr="")
        with mock.patch.object(wt.subprocess, "run", return_value=completed) as run:
            view = wt.load_workflow_view("fixture-seq-running", timeout=1.25)
        self.assertIsNone(view.error)
        run.assert_called_once_with(
            ("ralph", "workflow", "status", "fixture-seq-running", "--json"),
            capture_output=True,
            text=True,
            check=False,
            timeout=1.25,
        )
        with self.assertRaises(ValueError):
            wt.status_command("latest")

    def test_status_loading_does_not_write_registry_or_engine_tree(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            registry = root / "state" / "workflow-runs" / "fixture-seq-running"
            engine = root / "state" / "orchestration-runs" / "fixture-seq-running"
            registry.mkdir(parents=True)
            engine.mkdir(parents=True)
            (registry / "run.json").write_text('{"sentinel":"registry"}\n', encoding="utf-8")
            (engine / "ledger.json").write_text('{"sentinel":"engine"}\n', encoding="utf-8")
            fixture = root / "status.json"
            fixture.write_text(
                json.dumps(fixture_payload("sequential-task-running.json")) + "\n", encoding="utf-8"
            )
            cli = root / "ralph"
            cli.write_text(
                "#!/usr/bin/env bash\n"
                "set -euo pipefail\n"
                "[[ \"$1 $2 $3 $4\" == \"workflow status fixture-seq-running --json\" ]]\n"
                "exec /bin/cat \"$RALPH_TEST_STATUS_FIXTURE\"\n",
                encoding="utf-8",
            )
            cli.chmod(0o755)
            before_registry = tree_fingerprint(registry)
            before_engine = tree_fingerprint(engine)
            before_registry_stat = (registry / "run.json").stat()
            before_engine_stat = (engine / "ledger.json").stat()
            with mock.patch.dict(os.environ, {"RALPH_TEST_STATUS_FIXTURE": str(fixture)}):
                view = wt.load_workflow_view("fixture-seq-running", command=(str(cli),))
            self.assertIsNone(view.error)
            self.assertEqual(tree_fingerprint(registry), before_registry)
            self.assertEqual(tree_fingerprint(engine), before_engine)
            self.assertEqual((registry / "run.json").stat().st_mtime_ns, before_registry_stat.st_mtime_ns)
            self.assertEqual((engine / "ledger.json").stat().st_mtime_ns, before_engine_stat.st_mtime_ns)


if __name__ == "__main__":
    unittest.main()
