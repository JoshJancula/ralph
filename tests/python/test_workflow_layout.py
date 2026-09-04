#!/usr/bin/env python3
"""Deterministic primary-layout snapshots for the workflow terminal UI."""

from __future__ import annotations

import copy
import json
import sys
import unittest
from datetime import datetime, timezone
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
PYTHON_DIR = REPO_ROOT / "bundle" / ".ralph" / "python"
FIXTURE_DIR = REPO_ROOT / "tests" / "bats" / "workflow" / "fixtures" / "status"
SNAPSHOT_DIR = Path(__file__).with_name("snapshots")
sys.path.insert(0, str(PYTHON_DIR))

import workflow_canvas as wc  # noqa: E402
import workflow_layout as wl  # noqa: E402
import workflow_tui as wt  # noqa: E402


FIXED_NOW = datetime(2026, 8, 27, 1, 2, 0, tzinfo=timezone.utc)
SIZES = (wl.COMPACT_SIZE, wl.STANDARD_SIZE, wl.WIDE_SIZE)


def fixture_payload(name: str) -> dict:
    return json.loads((FIXTURE_DIR / name).read_text(encoding="utf-8"))


def view_from_fixture(name: str, *, selected: str | None = None) -> wt.WorkflowViewModel:
    snapshot = wt.parse_status_snapshot(fixture_payload(name))
    return wt.view_from_snapshot(snapshot, selected)


def dependency_wave_view() -> wt.WorkflowViewModel:
    """Dependency run with public wave metadata, failure, and derived blocked."""

    payload = fixture_payload("dependency-approval-wait.json")
    payload = copy.deepcopy(payload)
    payload["run"]["runId"] = "fixture-dep-waves"
    payload["run"]["task"] = (
        "Ship the feature with an intentionally long task summary for truncation checks"
    )
    payload["run"]["createdAt"] = "2026-08-27T01:00:00Z"
    payload["run"]["updatedAt"] = "2026-08-27T01:01:30Z"
    payload["run"]["state"] = "running"
    payload["stages"] = [
        {
            "id": "research",
            "index": 0,
            "wave": 0,
            "state": "succeeded",
            "stageKind": "executable",
            "attempt": 1,
            "completedTodos": 0,
            "totalTodos": 0,
            "artifacts": ["/fixtures/research.md"],
            "blocker": None,
            "createdAt": "2026-08-27T01:00:00Z",
            "updatedAt": "2026-08-27T01:00:20Z",
        },
        {
            "id": "implement",
            "index": 1,
            "wave": 0,
            "state": "failed",
            "stageKind": "plan-backed",
            "attempt": 1,
            "terminalResult": "failed",
            "completedTodos": 1,
            "totalTodos": 4,
            "artifacts": [],
            "blocker": None,
            "createdAt": "2026-08-27T01:00:20Z",
            "updatedAt": "2026-08-27T01:01:00Z",
        },
        {
            "id": "approve-plan",
            "index": 2,
            "wave": 1,
            "state": "waiting",
            "stageKind": "approval",
            "attempt": 1,
            "completedTodos": 0,
            "totalTodos": 0,
            "artifacts": [],
            "blocker": {"kind": "approval", "requestId": "approval-fixture-001"},
            "approval": {
                "question": "Approve the implementation plan?",
                "changesTarget": "implement",
            },
            "requestId": "approval-fixture-001",
            "requestState": "outstanding",
            "evidence": [],
            "createdAt": "2026-08-27T01:01:00Z",
            "updatedAt": "2026-08-27T01:01:30Z",
        },
        {
            "id": "integrate",
            "index": 3,
            "wave": 2,
            "state": "blocked",
            "stageKind": "supervisor",
            "attempt": 0,
            "completedTodos": 0,
            "totalTodos": 0,
            "artifacts": [],
            "blocker": None,
            "createdAt": "2026-08-27T01:00:00Z",
            "updatedAt": "2026-08-27T01:01:30Z",
        },
    ]
    payload["diagnosis"] = {
        "state": "waiting",
        "reasonCode": "human-approval",
        "summary": "the run is waiting for the operator to decide an approval gate",
        "stageId": "approve-plan",
        "requestKind": "approval",
        "requestId": "approval-fixture-001",
        "evidence": ["stage approve-plan is waiting"],
        "retryable": False,
        "nextAction": {
            "label": "answer the outstanding request",
            "argv": ["ralph", "workflow", "actions", "list", "fixture-dep-waves"],
        },
    }
    payload["nextAction"] = payload["diagnosis"]["nextAction"]
    return wt.view_from_snapshot(wt.parse_status_snapshot(payload))


def sequential_ordered_view() -> wt.WorkflowViewModel:
    return view_from_fixture("sequential-task-running.json", selected="implement")


def executable_view() -> wt.WorkflowViewModel:
    return view_from_fixture("sequential-task-running.json", selected="research")


def plan_backed_generated_view() -> wt.WorkflowViewModel:
    return sequential_ordered_view()


def plan_backed_provided_view() -> wt.WorkflowViewModel:
    payload = copy.deepcopy(fixture_payload("sequential-task-running.json"))
    payload["run"]["runId"] = "fixture-seq-provided"
    payload["stages"][1]["planSourceKind"] = "provided"
    payload["stages"][1]["planSourceStageId"] = None
    payload["stages"][1]["originalPlanPath"] = "/fixtures/original.plan.md"
    payload["stages"][1]["currentTodoId"] = "apply-patch"
    payload["stages"][1]["completedTodos"] = 1
    payload["stages"][1]["totalTodos"] = 3
    return wt.view_from_snapshot(wt.parse_status_snapshot(payload), "implement")


def approval_view() -> wt.WorkflowViewModel:
    return view_from_fixture("dependency-approval-wait.json")


def input_wait_view() -> wt.WorkflowViewModel:
    return view_from_fixture("sequential-input-wait.json")


def failed_view() -> wt.WorkflowViewModel:
    return view_from_fixture("sequential-failed.json")


def stale_stage_view() -> wt.WorkflowViewModel:
    payload = copy.deepcopy(fixture_payload("sequential-stale.json"))
    payload["stages"] = [
        {
            "id": "implement",
            "index": 0,
            "state": "stale",
            "stageKind": "executable",
            "attempt": 2,
            "completedTodos": 0,
            "totalTodos": 0,
            "artifacts": [],
            "blocker": None,
            "createdAt": "2026-08-27T05:00:00Z",
            "updatedAt": "2026-08-27T05:01:00Z",
        }
    ]
    payload["diagnosis"]["stageId"] = "implement"
    return wt.view_from_snapshot(wt.parse_status_snapshot(payload))


def rework_view() -> wt.WorkflowViewModel:
    return view_from_fixture("dependency-human-changes-requested.json")


def render_case(
    name: str, view: wt.WorkflowViewModel, width: int, height: int
) -> tuple[str, ...]:
    return wl.render_primary_lines(
        view,
        width,
        height,
        now=FIXED_NOW,
        ascii_only=True,
        trim_trailing=True,
    )


def detail_keys(view: wt.WorkflowViewModel, *, max_lines: int | None = None) -> list[str]:
    lines = wl.build_stage_detail_lines(
        view, now=FIXED_NOW, reveal_paths=False, max_lines=max_lines
    )
    return [line.key for line in lines]


def snapshot_name(case: str, width: int, height: int) -> str:
    return f"workflow_layout_{case}_{width}x{height}.json"


def detail_snapshot_name(case: str, width: int, height: int) -> str:
    return f"workflow_detail_{case}_{width}x{height}.json"


class TestElapsedAndLabels(unittest.TestCase):
    def test_elapsed_and_update_formatting(self) -> None:
        self.assertEqual(wl.format_elapsed_seconds(0), "0s")
        self.assertEqual(wl.format_elapsed_seconds(45), "45s")
        self.assertEqual(wl.format_elapsed_seconds(60), "1m 0s")
        self.assertEqual(wl.format_elapsed_seconds(125), "2m 5s")
        self.assertEqual(wl.format_elapsed_seconds(3723), "1h 2m 3s")
        self.assertEqual(
            wl.format_elapsed("2026-08-27T01:00:00Z", FIXED_NOW),
            "2m 0s",
        )
        self.assertEqual(
            wl.format_last_update("2026-08-27T01:01:00Z", FIXED_NOW),
            "1m ago",
        )
        self.assertEqual(
            wl.format_last_update("2026-08-27T01:01:58Z", FIXED_NOW),
            "just now",
        )

    def test_terminal_run_duration_stops_at_its_recorded_update(self) -> None:
        view = view_from_fixture("dependency-cancelled.json")
        self.assertEqual(wl.run_duration_label(view.run, FIXED_NOW), "1m 0s")

    def test_outcome_and_mode_labels_are_public(self) -> None:
        self.assertEqual(wl.mode_label("sequential"), "Sequential")
        self.assertEqual(wl.mode_label("dependency"), "Dependency")
        self.assertEqual(wl.outcome_badge("running"), "RUNNING")
        self.assertEqual(wl.outcome_badge("failed"), "FAILED")
        self.assertEqual(wl.effective_outcome_state("failed", "blocked"), "failed")
        self.assertEqual(wl.effective_outcome_state("running", "blocked"), "blocked")
        self.assertEqual(wl.public_state_label("blocked"), "blocked")
        self.assertEqual(wl.public_state_label("skipped"), "skipped")

    def test_lifecycle_groups_do_not_report_skipped_stages_as_complete(self) -> None:
        payload = copy.deepcopy(fixture_payload("sequential-task-running.json"))
        payload["stages"][0]["state"] = "skipped"
        view = wt.view_from_snapshot(wt.parse_status_snapshot(payload))
        groups = {
            label: [stage.id for stage in stages]
            for label, _role, stages in wl.lifecycle_groups(view.stages)
        }
        self.assertEqual(groups["Skipped"], ["research"])
        self.assertNotIn("Complete", groups)
        self.assertEqual(groups["Active"], ["implement"])

    def test_lifecycle_sections_show_next_and_later_dependency_edges(self) -> None:
        payload = copy.deepcopy(fixture_payload("sequential-task-running.json"))
        payload["run"]["mode"] = "dependency"
        payload["stages"][1]["dependencies"] = [
            {"stageId": "research", "condition": None}
        ]
        template = copy.deepcopy(payload["stages"][1])
        template.update(
            id="review",
            index=2,
            state="queued",
            attempt=0,
            currentTodoId=None,
            completedTodos=0,
            totalTodos=0,
            artifacts=[],
            dependencies=[{"stageId": "implement", "condition": None}],
        )
        qa = copy.deepcopy(template)
        qa.update(
            id="qa",
            index=3,
            dependencies=[{"stageId": "review", "condition": None}],
        )
        payload["stages"].extend((template, qa))
        view = wt.view_from_snapshot(wt.parse_status_snapshot(payload))

        rendered = ["".join(span.text for span in line) for line in wl.lifecycle_section_lines(view, ascii_only=True)]
        self.assertEqual(len(rendered), 3)
        self.assertIn("Now        Active 1: implement", rendered[0])
        self.assertIn("Pending    2 | Next: review <- implement", rendered[1])
        self.assertIn("Later: qa <- review", rendered[1])
        self.assertEqual(rendered[2], "Completed  1: research")
        details = [
            "".join(span.text for span in line.spans)
            for line in wl.build_stage_detail_lines(view, now=FIXED_NOW)
        ]
        self.assertIn("Depends on  research", details)
        self.assertIn("Unlocks  review", details)

    def test_conditional_rework_is_not_reported_as_required_pending_work(self) -> None:
        payload = copy.deepcopy(fixture_payload("sequential-task-running.json"))
        payload["run"]["mode"] = "dependency"
        payload["stages"][0]["state"] = "running"
        payload["stages"][1]["state"] = "queued"
        payload["stages"][1]["dependencies"] = [
            {"stageId": "research", "condition": "passed"}
        ]
        rework = copy.deepcopy(payload["stages"][1])
        rework.update(
            id="implement-r1",
            index=2,
            attempt=0,
            dependencies=[{"stageId": "research", "condition": "changes-required"}],
        )
        review_rework = copy.deepcopy(rework)
        review_rework.update(
            id="review-r1",
            index=3,
            dependencies=[{"stageId": "implement-r1", "condition": None}],
        )
        payload["stages"].extend((rework, review_rework))
        view = wt.view_from_snapshot(wt.parse_status_snapshot(payload))

        self.assertEqual(
            wl.conditional_rework_stage_ids(view.snapshot),
            frozenset({"implement-r1", "review-r1"}),
        )
        rendered = [
            "".join(span.text for span in line)
            for line in wl.lifecycle_section_lines(view, ascii_only=True)
        ]
        self.assertIn("Pending    1 | Next: implement <- research [passed]", rendered[1])
        self.assertNotIn("implement-r1", rendered[1])
        self.assertNotIn("review-r1", rendered[1])
        stage_by_id = {stage.id: stage for stage in view.stages}
        self.assertEqual(
            wl.stage_inspection_state_label(view, stage_by_id["implement-r1"]),
            "conditional",
        )

        for stage in payload["stages"]:
            if stage["id"] in {"implement-r1", "review-r1"}:
                stage["state"] = "skipped"
        view = wt.view_from_snapshot(wt.parse_status_snapshot(payload))
        rendered = [
            "".join(span.text for span in line)
            for line in wl.lifecycle_section_lines(view, ascii_only=True)
        ]
        self.assertNotIn("conditional rework", rendered[2])
        self.assertNotIn("implement-r1", rendered[2])
        self.assertNotIn("review-r1", rendered[2])

    def test_progress_tree_reveals_only_the_conditional_route_that_is_entered(self) -> None:
        payload = copy.deepcopy(fixture_payload("sequential-task-running.json"))
        payload["run"]["mode"] = "dependency"
        review = payload["stages"][0]
        review.update(id="review", index=0, state="running", attempt=1, dependencies=[])
        implement_r1 = payload["stages"][1]
        implement_r1.update(
            id="implement-r1",
            index=1,
            state="queued",
            attempt=0,
            dependencies=[{"stageId": "review", "condition": "changes-required"}],
        )
        review_r1 = copy.deepcopy(implement_r1)
        review_r1.update(
            id="review-r1",
            index=2,
            dependencies=[{"stageId": "implement-r1", "condition": None}],
        )
        approved = copy.deepcopy(implement_r1)
        approved.update(
            id="review-approved",
            index=3,
            dependencies=[
                {"stageId": "review", "condition": "passed"},
                {"stageId": "review-r1", "condition": "passed"},
            ],
        )
        integrate = copy.deepcopy(implement_r1)
        integrate.update(
            id="integrate",
            index=4,
            dependencies=[{"stageId": "review-approved", "condition": None}],
        )
        payload["stages"] = [review, implement_r1, review_r1, approved, integrate]

        view = wt.view_from_snapshot(wt.parse_status_snapshot(payload))
        self.assertEqual(
            [node.stage.id for node in wl.progress_tree_nodes(view)],
            ["review"],
        )
        self.assertEqual(wl.dependent_summary(view, "review"), "")
        summary = "".join(span.text for span in wl._progress_summary_spans(view))
        self.assertEqual(summary, "Progress  0 complete · 1 in progress · 0 remaining")

        implement_r1["state"] = "running"
        implement_r1["attempt"] = 1
        view = wt.view_from_snapshot(wt.parse_status_snapshot(payload))
        self.assertEqual(
            [node.stage.id for node in wl.progress_tree_nodes(view)],
            ["review", "implement-r1", "review-r1"],
        )
        self.assertNotIn("review-approved", wl.dependent_summary(view, "review"))

        implement_r1["state"] = "skipped"
        implement_r1["attempt"] = 0
        approved["state"] = "succeeded"
        approved["attempt"] = 1
        review["state"] = "succeeded"
        view = wt.view_from_snapshot(wt.parse_status_snapshot(payload))
        self.assertEqual(
            [node.stage.id for node in wl.progress_tree_nodes(view)],
            ["review", "review-approved", "integrate"],
        )
        nodes = {node.stage.id: node for node in wl.progress_tree_nodes(view)}
        approved_line = "".join(
            span.text
            for span in wl._progress_tree_row_spans(
                view,
                nodes["review-approved"],
                now=FIXED_NOW,
                next_ids=set(),
                ascii_only=True,
            )
        )
        self.assertIn("review-approved (complete)", approved_line)
        self.assertNotIn("if approved", approved_line)

    def test_progress_tree_routes_join_through_the_activated_rework_branch(self) -> None:
        payload = copy.deepcopy(fixture_payload("sequential-task-running.json"))
        payload["run"]["mode"] = "dependency"
        review = payload["stages"][0]
        review.update(id="review", index=0, state="succeeded", dependencies=[])
        implement_r1 = payload["stages"][1]
        implement_r1.update(
            id="implement-r1",
            index=1,
            state="succeeded",
            dependencies=[{"stageId": "review", "condition": "changes-required"}],
        )
        review_r1 = copy.deepcopy(implement_r1)
        review_r1.update(
            id="review-r1",
            index=2,
            state="running",
            dependencies=[{"stageId": "implement-r1", "condition": None}],
        )
        approved = copy.deepcopy(review_r1)
        approved.update(
            id="review-approved",
            index=3,
            state="running",
            attempt=1,
            dependencies=[
                {"stageId": "review", "condition": "passed"},
                {"stageId": "review-r1", "condition": "passed"},
            ],
        )
        payload["stages"] = [review, implement_r1, review_r1, approved]
        view = wt.view_from_snapshot(
            wt.parse_status_snapshot(payload), previous_selected_stage_id="review-r1"
        )
        nodes = {node.stage.id: node for node in wl.progress_tree_nodes(view)}

        self.assertEqual(nodes["implement-r1"].incoming_condition, "changes-required")
        self.assertEqual(len(nodes["review-r1"].ancestor_continues), 2)
        self.assertEqual(len(nodes["review-approved"].ancestor_continues), 3)
        self.assertEqual(
            wl.progress_tree_stage_label(view, nodes["review-r1"].stage, set()),
            "in progress",
        )


class TestStageOrderAndWaveGrouping(unittest.TestCase):
    def test_sequential_keeps_index_order_without_wave_headers(self) -> None:
        view = sequential_ordered_view()
        groups = wl.group_stages_for_list(view.snapshot)
        self.assertEqual(len(groups), 1)
        self.assertIsNone(groups[0][0])
        self.assertEqual([stage.id for stage in groups[0][1]], ["research", "implement"])
        entries = wl.build_stage_list_entries(view)
        self.assertEqual([entry.label for entry in entries], ["research", "implement"])
        self.assertTrue(any(entry.selected and entry.label == "implement" for entry in entries))

    def test_dependency_groups_by_public_wave_metadata(self) -> None:
        view = dependency_wave_view()
        groups = wl.group_stages_for_list(view.snapshot)
        self.assertEqual(
            [(label, [stage.id for stage in stages]) for label, stages in groups],
            [
                ("Wave 0", ["research", "implement"]),
                ("Wave 1", ["approve-plan"]),
                ("Wave 2", ["integrate"]),
            ],
        )
        entries = wl.build_stage_list_entries(view)
        labels = [entry.label for entry in entries]
        self.assertEqual(
            labels,
            [
                "Wave 0",
                "research",
                "implement",
                "Wave 1",
                "approve-plan",
                "Wave 2",
                "integrate",
            ],
        )
        selected = next(entry for entry in entries if entry.selected)
        self.assertEqual(selected.label, "approve-plan")
        failed = next(entry for entry in entries if entry.label == "implement")
        blocked = next(entry for entry in entries if entry.label == "integrate")
        self.assertEqual(failed.state_role, "failure")
        self.assertEqual(failed.state_label, "failed")
        self.assertEqual(blocked.state_role, "muted")
        self.assertEqual(blocked.state_label, "blocked")


class TestPrimaryLayoutSnapshots(unittest.TestCase):
    CASES = {
        "seq-running": sequential_ordered_view,
        "seq-waiting": lambda: view_from_fixture("sequential-input-wait.json"),
        "seq-failed": lambda: view_from_fixture("sequential-failed.json"),
        "dep-succeeded": lambda: view_from_fixture("dependency-plan-succeeded.json"),
        "dep-waves": dependency_wave_view,
    }

    def test_responsive_snapshots_for_outcomes_and_modes(self) -> None:
        for case, factory in self.CASES.items():
            view = factory()
            for width, height in SIZES:
                with self.subTest(case=case, size=(width, height)):
                    lines = render_case(case, view, width, height)
                    self.assertEqual(len(lines), height)
                    for line in lines:
                        self.assertLessEqual(wc.display_width(line), width)
                    joined = "\n".join(lines)
                    forbidden = wl.contains_forbidden_primary_term(joined)
                    self.assertIsNone(forbidden, f"leaked term {forbidden!r} in {case}")
                    for term in (
                        "namespace",
                        "ledger",
                        "orchestration",
                        "graph-run",
                        "nodeId",
                        "waveFailures",
                        "parallelStages",
                        ".ralph-workspace",
                    ):
                        self.assertNotIn(term.casefold(), joined.casefold())
                    expected_path = SNAPSHOT_DIR / snapshot_name(case, width, height)
                    self.assertTrue(expected_path.exists(), f"missing snapshot {expected_path}")
                    expected = json.loads(expected_path.read_text(encoding="utf-8"))
                    self.assertEqual(list(lines), expected)

    def test_selected_marker_and_non_color_state_labels(self) -> None:
        view = sequential_ordered_view()
        lines = render_case("seq-running", view, 80, 24)
        joined = "\n".join(lines)
        self.assertIn("RUNNING", joined)
        self.assertRegex(joined, r"(?m)^> .*running +implement")
        self.assertRegex(joined, r"(?m)^  .*succeeded +research")
        self.assertIn("2m 0s", joined)
        self.assertIn("1m ago", joined)

    def test_task_truncation_at_compact_width(self) -> None:
        view = dependency_wave_view()
        lines = render_case("dep-waves", view, 40, 12)
        joined = "\n".join(lines)
        self.assertIn("WAITING", joined)
        self.assertIn("…", joined)
        self.assertNotIn(view.run.task, joined)
        self.assertIn("approve-plan", joined)
        self.assertNotIn("Wave 0", joined)

    def test_wave_headers_appear_outside_compact(self) -> None:
        view = dependency_wave_view()
        standard = "\n".join(render_case("dep-waves", view, 80, 24))
        self.assertIn("Wave 0", standard)
        self.assertIn("Wave 1", standard)
        self.assertIn("Wave 2", standard)
        self.assertRegex(standard, r"(?m)^> .*waiting +approve-plan")

    def test_canvas_has_no_ansi_and_module_stays_backend_neutral(self) -> None:
        view = sequential_ordered_view()
        canvas = wl.render_primary_frame(view, 80, 24, now=FIXED_NOW, ascii_only=True)
        plain = canvas.render_plain()
        self.assertNotIn("\x1b", plain)
        for span in canvas.iter_spans():
            self.assertNotIn("\x1b", span.text)
            self.assertNotIn("\x1b", span.role)


class TestStageDetailPane(unittest.TestCase):
    DETAIL_CASES = {
        "executable": executable_view,
        "plan-generated": plan_backed_generated_view,
        "plan-provided": plan_backed_provided_view,
        "approval": approval_view,
        "input-wait": input_wait_view,
        "failed": failed_view,
        "stale": stale_stage_view,
        "rework": rework_view,
    }

    def test_detail_snapshots_for_stage_kinds(self) -> None:
        for case, factory in self.DETAIL_CASES.items():
            view = factory()
            for width, height in SIZES:
                with self.subTest(case=case, size=(width, height)):
                    lines = render_case(case, view, width, height)
                    self.assertEqual(len(lines), height)
                    joined = "\n".join(lines)
                    self.assertIsNone(wl.contains_forbidden_primary_term(joined))
                    expected_path = SNAPSHOT_DIR / detail_snapshot_name(case, width, height)
                    self.assertTrue(expected_path.exists(), f"missing snapshot {expected_path}")
                    expected = json.loads(expected_path.read_text(encoding="utf-8"))
                    self.assertEqual(list(lines), expected)

    def test_plan_backed_progress_and_next_action_match_fixtures(self) -> None:
        generated = plan_backed_generated_view()
        provided = plan_backed_provided_view()
        self.assertEqual(
            (generated.selected_stage.progress.completed, generated.selected_stage.progress.total),
            (2, 5),
        )
        self.assertEqual(generated.selected_stage.progress.current_todo_id, "implement-core")
        self.assertEqual(generated.selected_stage.plan_source_kind, "generated")
        self.assertIsNone(generated.next_action)

        self.assertEqual(
            (provided.selected_stage.progress.completed, provided.selected_stage.progress.total),
            (1, 3),
        )
        self.assertEqual(provided.selected_stage.plan_source_kind, "provided")

        keys = detail_keys(generated)
        self.assertIn("progress", keys)
        self.assertIn("todo", keys)
        self.assertIn("plan_source", keys)
        self.assertNotIn("question", keys)

        joined = "\n".join(render_case("plan-generated", generated, 80, 24))
        self.assertIn("2/5", joined)
        self.assertIn("implement-core", joined)
        self.assertIn("generated", joined)
        self.assertIn("implementation.md", joined)
        self.assertNotIn("/fixtures/implementation.md", joined)

        provided_joined = "\n".join(render_case("plan-provided", provided, 80, 24))
        self.assertIn("1/3", provided_joined)
        self.assertIn("provided", provided_joined)
        self.assertIn("apply-patch", provided_joined)

    def test_approval_omits_plan_fields_and_paths(self) -> None:
        view = approval_view()
        self.assertEqual(view.next_action.label, "answer the outstanding request")
        self.assertEqual(
            view.next_action.argv,
            ("ralph", "workflow", "actions", "list", "fixture-dep-approval"),
        )
        keys = detail_keys(view)
        self.assertIn("question", keys)
        self.assertIn("request", keys)
        self.assertIn("changes", keys)
        self.assertIn("evidence", keys)
        self.assertIn("next", keys)
        self.assertNotIn("todo", keys)
        self.assertNotIn("progress", keys)
        self.assertNotIn("plan_source", keys)
        self.assertNotIn("artifacts", keys)

        joined = "\n".join(render_case("approval", view, 80, 24))
        self.assertIn("Approve the implementation plan?", joined)
        self.assertIn("outstanding", joined)
        self.assertIn("Changes target", joined)
        self.assertIn("implement", joined)
        self.assertIn("Evidence  1", joined)
        self.assertFalse(wl.contains_plan_path_leak(joined))
        self.assertNotIn("/fixtures/", joined)
        self.assertNotIn("control.plan", joined)
        self.assertNotIn("source.plan", joined)

        rework = rework_view()
        rework_joined = "\n".join(render_case("rework", rework, 80, 24))
        self.assertEqual(rework.next_action.label, "reset to the approval changes target")
        self.assertIn("reset to the approval changes target", rework_joined)
        self.assertIn("human-changes-requested", rework_joined)
        self.assertFalse(wl.contains_plan_path_leak(rework_joined))

    def test_input_failed_stale_and_executable_fields(self) -> None:
        input_view = input_wait_view()
        self.assertEqual(input_view.next_action.label, "answer the outstanding request")
        input_joined = "\n".join(render_case("input-wait", input_view, 80, 24))
        self.assertIn("executable", input_joined)
        self.assertIn("input", input_joined)
        self.assertIn("answer the outstanding request", input_joined)

        failed = failed_view()
        self.assertIsNone(failed.next_action)
        failed_keys = detail_keys(failed)
        self.assertIn("identity", failed_keys)
        self.assertNotIn("next", failed_keys)
        failed_joined = "\n".join(render_case("failed", failed, 80, 24))
        self.assertIn("failed", failed_joined)

        stale = stale_stage_view()
        self.assertEqual(stale.next_action.label, "recover the abandoned run")
        stale_joined = "\n".join(render_case("stale", stale, 80, 24))
        self.assertIn("stale", stale_joined)
        self.assertIn("recover the abandoned run", stale_joined)

        executable = executable_view()
        exec_keys = detail_keys(executable)
        self.assertIn("artifacts", exec_keys)
        self.assertNotIn("plan_source", exec_keys)
        exec_joined = "\n".join(render_case("executable", executable, 80, 24))
        self.assertIn("research.md", exec_joined)
        self.assertNotIn("/fixtures/research.md", exec_joined)

    def test_narrow_layouts_omit_lower_priority_details(self) -> None:
        view = plan_backed_generated_view()
        full_keys = detail_keys(view)
        self.assertIn("artifacts", full_keys)
        self.assertIn("plan_source", full_keys)

        narrow = detail_keys(view, max_lines=3)
        self.assertEqual(len(narrow), 3)
        self.assertIn("identity", narrow)
        # Lower-priority artifacts / plan_source must drop rather than corrupt.
        self.assertNotIn("artifacts", narrow)
        for key in narrow:
            self.assertIn(key, full_keys)

        compact = "\n".join(render_case("plan-generated", view, 40, 12))
        self.assertIn("implement", compact)
        self.assertIn("plan-backed", compact)
        # Compact omits low-priority artifact labels rather than leaking full paths.
        self.assertNotIn("/fixtures/", compact)
        self.assertNotIn("namespace", compact.casefold())

    def test_details_help_view_reveals_full_contained_paths(self) -> None:
        view = plan_backed_generated_view()
        primary = "\n".join(render_case("plan-generated", view, 80, 24))
        self.assertIn("implementation.md", primary)
        self.assertNotIn("/fixtures/implementation.md", primary)

        details = wl.render_primary_lines(
            view,
            80,
            24,
            now=FIXED_NOW,
            ascii_only=True,
            trim_trailing=True,
            details_view=True,
        )
        joined = "\n".join(details)
        self.assertIn("/fixtures/implementation.md", joined)

    def test_stage_details_expose_workspace_and_changeset_handoff_paths(self) -> None:
        payload = copy.deepcopy(fixture_payload("sequential-task-running.json"))
        stage = payload["stages"][1]
        stage.update(
            workspaceMode="worktree",
            workspacePath="/fixtures/worktrees/implement",
            workspaceAvailable=True,
            baseRevision="a" * 40,
            changesetManifest="/fixtures/changesets/implement.json",
            changedFiles=["src/model.sh", "tests/model.bats"],
        )
        view = wt.view_from_snapshot(wt.parse_status_snapshot(payload), "implement")
        self.assertIn("workspace", detail_keys(view))
        self.assertIn("changeset", detail_keys(view))

        detail_lines = wl.build_stage_detail_lines(
            view, now=FIXED_NOW, reveal_paths=True
        )
        joined = "\n".join("".join(span.text for span in line.spans) for line in detail_lines)
        self.assertIn("Workspace  worktree (available) · /fixtures/worktrees/implement", joined)
        self.assertIn("Open code  cd /fixtures/worktrees/implement", joined)
        self.assertIn("Changeset  /fixtures/changesets/implement.json · 2 changed file(s)", joined)

        approval = approval_view()
        approval_details = "\n".join(
            wl.render_primary_lines(
                approval,
                80,
                24,
                now=FIXED_NOW,
                ascii_only=True,
                details_view=True,
            )
        )
        self.assertIn("/fixtures/evidence.md", approval_details)
        self.assertFalse(wl.contains_plan_path_leak(approval_details))


def _write_snapshots() -> None:
    SNAPSHOT_DIR.mkdir(parents=True, exist_ok=True)
    cases = TestPrimaryLayoutSnapshots.CASES
    for case, factory in cases.items():
        view = factory()
        for width, height in SIZES:
            lines = render_case(case, view, width, height)
            path = SNAPSHOT_DIR / snapshot_name(case, width, height)
            path.write_text(json.dumps(list(lines), indent=2) + "\n", encoding="utf-8")
            print(f"wrote {path.relative_to(REPO_ROOT)}")
    for case, factory in TestStageDetailPane.DETAIL_CASES.items():
        view = factory()
        for width, height in SIZES:
            lines = render_case(case, view, width, height)
            path = SNAPSHOT_DIR / detail_snapshot_name(case, width, height)
            path.write_text(json.dumps(list(lines), indent=2) + "\n", encoding="utf-8")
            print(f"wrote {path.relative_to(REPO_ROOT)}")


if __name__ == "__main__":
    if len(sys.argv) > 1 and sys.argv[1] == "--write-snapshots":
        _write_snapshots()
        raise SystemExit(0)
    unittest.main()
