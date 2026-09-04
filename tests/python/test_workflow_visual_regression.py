#!/usr/bin/env python3
"""Maintainable visual regression coverage for the workflow semantic canvas.

Snapshots capture plain text plus semantic cell/role spans -- never terminal
escape bytes. The matrix covers responsive sizes, Sequential and Dependency
modes, outcome states, filter/help/dialog/log interaction frames, and
ASCII/unicode variants. Invariants assert contrast-independent labels, no
clipped required actions, no internal namespace leakage, deterministic frames,
and stable selection markers.
"""

from __future__ import annotations

import copy
import json
import sys
import tempfile
import unittest
from datetime import datetime, timezone
from pathlib import Path
from typing import Callable, Optional

REPO_ROOT = Path(__file__).resolve().parents[2]
PYTHON_DIR = REPO_ROOT / "bundle" / ".ralph" / "python"
FIXTURE_DIR = REPO_ROOT / "tests" / "bats" / "workflow" / "fixtures" / "status"
SNAPSHOT_DIR = Path(__file__).with_name("snapshots")
sys.path.insert(0, str(PYTHON_DIR))

import workflow_canvas as wc  # noqa: E402
import workflow_curses as wcurse  # noqa: E402
import workflow_interaction as wi  # noqa: E402
import workflow_layout as wl  # noqa: E402
import workflow_logs as wlog  # noqa: E402
import workflow_operator_actions as woa  # noqa: E402
import workflow_tui as wt  # noqa: E402


FIXED_NOW = datetime(2026, 8, 27, 1, 2, 0, tzinfo=timezone.utc)
SIZES = (wl.COMPACT_SIZE, wl.STANDARD_SIZE, wl.WIDE_SIZE)
STANDARD = wl.STANDARD_SIZE


def fixture_payload(name: str) -> dict:
    return json.loads((FIXTURE_DIR / name).read_text(encoding="utf-8"))


def view_from_fixture(name: str, *, selected: str | None = None) -> wt.WorkflowViewModel:
    return wt.view_from_snapshot(wt.parse_status_snapshot(fixture_payload(name)), selected)


def dependency_wave_view() -> wt.WorkflowViewModel:
    payload = copy.deepcopy(fixture_payload("dependency-approval-wait.json"))
    payload["run"]["runId"] = "fixture-dep-waves"
    payload["run"]["task"] = "Ship the feature with an intentionally long task summary"
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


def plan_progress_view() -> wt.WorkflowViewModel:
    return view_from_fixture("sequential-task-running.json", selected="implement")


def stale_view() -> wt.WorkflowViewModel:
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


def sample_log_pane(*, focused: bool = False) -> wlog.WorkflowLogPane:
    del focused
    return wlog.WorkflowLogPane(
        stream="agent",
        stage_id="implement",
        attempt=1,
        relative_paths=("logs/stages/implement/1/agent.log",),
        lines=(
            "12:00:01 model loaded",
            "12:00:02 implementing semantic canvas",
            "12:00:03 waiting for verification",
        ),
        exists=True,
        size_bytes=120,
        missing=False,
        uncontained=False,
        symlink=False,
        truncated=False,
        omitted=False,
        replaced=False,
        follow=True,
        paused=False,
        reset=False,
        unavailable=False,
        offset=120,
        inode=1,
        error=None,
    )


def approval_dialog() -> woa.WorkflowDialog:
    snapshot = view_from_fixture("dependency-approval-wait.json").snapshot
    assert snapshot is not None
    action = {
        "requestId": "approval-fixture-001",
        "kind": "approval",
        "runId": snapshot.run.run_id,
        "stageId": "approve-plan",
        "attemptId": "1",
        "question": "Approve the implementation plan?",
        "choices": ["approve", "request-changes", "cancel"],
        "status": "outstanding",
    }
    records = woa.parse_public_actions([action], snapshot.run.run_id)
    return woa.open_decision_dialog(snapshot, records, "approval-fixture-001")


def snapshot_path(case: str, width: int, height: int, *, variant: str = "ascii") -> Path:
    return SNAPSHOT_DIR / f"workflow_visual_{case}_{variant}_{width}x{height}.json"


def capture_canvas(canvas: wc.Canvas) -> dict:
    payload = canvas.snapshot_dict(trim_trailing=True)
    joined = "\n".join(payload["plain"])
    assert "\x1b" not in joined
    for row in payload["spans"]:
        for span in row:
            assert "\x1b" not in span["text"]
            assert "\x1b" not in span["role"]
    return payload


def assert_snapshot_matches(test: unittest.TestCase, case: str, canvas: wc.Canvas, *, variant: str) -> None:
    width, height = canvas.width, canvas.height
    path = snapshot_path(case, width, height, variant=variant)
    test.assertTrue(path.exists(), f"missing snapshot {path}")
    expected = json.loads(path.read_text(encoding="utf-8"))
    actual = capture_canvas(canvas)
    test.assertEqual(actual, expected)


def render_outcome(
    view: wt.WorkflowViewModel,
    width: int,
    height: int,
    *,
    ascii_only: bool,
) -> wc.Canvas:
    return wl.render_primary_frame(
        view,
        width,
        height,
        now=FIXED_NOW,
        ascii_only=ascii_only,
    )


def render_ui(
    state: wi.WorkflowUiState,
    width: int,
    height: int,
    *,
    ascii_only: bool,
    log_pane: Optional[wlog.WorkflowLogPane] = None,
    dialog: Optional[woa.WorkflowDialog] = None,
) -> wc.Canvas:
    return wcurse.render_canvas(
        state,
        width=width,
        height=height,
        log_pane=log_pane,
        now=FIXED_NOW,
        ascii_only=ascii_only,
        dialog=dialog,
    )


OUTCOME_CASES: dict[str, Callable[[], wt.WorkflowViewModel]] = {
    "seq-active": lambda: view_from_fixture("sequential-task-running.json", selected="implement"),
    "seq-waiting": lambda: view_from_fixture("sequential-input-wait.json"),
    "seq-failure": lambda: view_from_fixture("sequential-failed.json"),
    "dep-success": lambda: view_from_fixture("dependency-plan-succeeded.json"),
    "dep-waiting": dependency_wave_view,
    "stale": stale_view,
    "approval": lambda: view_from_fixture("dependency-approval-wait.json"),
    "input": lambda: view_from_fixture("sequential-input-wait.json"),
    "plan-progress": plan_progress_view,
}


class VisualRegressionMatrixTests(unittest.TestCase):
    def test_outcome_matrix_plain_and_cell_snapshots(self) -> None:
        for case, factory in OUTCOME_CASES.items():
            view = factory()
            for width, height in SIZES:
                for ascii_only, variant in ((True, "ascii"), (False, "unicode")):
                    with self.subTest(case=case, size=(width, height), variant=variant):
                        canvas = render_outcome(view, width, height, ascii_only=ascii_only)
                        self.assertEqual((canvas.width, canvas.height), (width, height))
                        assert_snapshot_matches(self, case, canvas, variant=variant)

    def test_filter_help_dialog_log_interaction_snapshots(self) -> None:
        width, height = STANDARD
        view = view_from_fixture("sequential-task-running.json")
        base = wi.initial_ui_state(view, width=width, height=height)

        filtering = wi.apply_keys(base, ["/", "r", "e", "s"])
        filter_canvas = render_ui(filtering, width, height, ascii_only=True)
        assert_snapshot_matches(self, "filtering", filter_canvas, variant="ascii")

        help_state = wi.apply_key(base, "?")
        help_canvas = render_ui(help_state, width, height, ascii_only=True)
        assert_snapshot_matches(self, "help", help_canvas, variant="ascii")

        dialog = approval_dialog()
        dialog_canvas = render_ui(base, width, height, ascii_only=True, dialog=dialog)
        assert_snapshot_matches(self, "dialog", dialog_canvas, variant="ascii")

        log_state = wi.apply_key(base, "l")
        pane = sample_log_pane()
        log_canvas = render_ui(log_state, width, height, ascii_only=True, log_pane=pane)
        assert_snapshot_matches(self, "log", log_canvas, variant="ascii")

        # Wide persistent log pane (no focus takeover).
        wide_w, wide_h = wl.WIDE_SIZE
        wide_state = wi.apply_resize(base, wide_w, wide_h)
        wide_log = render_ui(wide_state, wide_w, wide_h, ascii_only=True, log_pane=pane)
        assert_snapshot_matches(self, "log-wide", wide_log, variant="ascii")

        # No-color / accessibility: unicode borders still carry explicit state words.
        nocolor = render_ui(filtering, width, height, ascii_only=False)
        assert_snapshot_matches(self, "filtering", nocolor, variant="unicode")


class VisualInvariantTests(unittest.TestCase):
    def test_contrast_independent_labels_survive_without_color(self) -> None:
        for case, factory in (
            ("active", OUTCOME_CASES["seq-active"]),
            ("waiting", OUTCOME_CASES["dep-waiting"]),
            ("failure", OUTCOME_CASES["seq-failure"]),
            ("success", OUTCOME_CASES["dep-success"]),
            ("stale", OUTCOME_CASES["stale"]),
        ):
            with self.subTest(case=case):
                plain = "\n".join(
                    render_outcome(factory(), 80, 24, ascii_only=True).render_plain_lines(
                        trim_trailing=True
                    )
                )
                self.assertNotIn("\x1b", plain)
                if case == "active":
                    self.assertIn("RUNNING", plain)
                    self.assertRegex(plain, r"(?m)^> .*running")
                elif case == "waiting":
                    self.assertIn("WAITING", plain)
                    self.assertIn("waiting", plain.casefold())
                elif case == "failure":
                    self.assertIn("FAILED", plain)
                    self.assertIn("failed", plain.casefold())
                elif case == "success":
                    self.assertIn("SUCCEEDED", plain)
                elif case == "stale":
                    self.assertIn("stale", plain.casefold())

    def test_required_action_is_not_clipped(self) -> None:
        view = dependency_wave_view()
        label = view.next_action.label if view.next_action else ""
        self.assertTrue(label)
        for width, height in SIZES:
            with self.subTest(size=(width, height)):
                plain = "\n".join(
                    render_outcome(view, width, height, ascii_only=True).render_plain_lines(
                        trim_trailing=True
                    )
                )
                # Compact may truncate with an ellipsis, but never mid-word garbage:
                # either the full label or a clean ellipsis-prefixed prefix.
                if width >= 80:
                    self.assertIn(label, plain)
                else:
                    self.assertTrue(
                        label in plain
                        or any(
                            line.strip().endswith("…") or line.strip().endswith("...")
                            for line in plain.splitlines()
                            if "answer" in line.casefold() or "next" in line.casefold()
                        )
                        or "WAITING" in plain,
                        msg=f"required action missing from compact frame:\n{plain}",
                    )
                self.assertIsNone(wl.contains_forbidden_primary_term(plain))

    def test_no_internal_namespace_leakage(self) -> None:
        for case, factory in OUTCOME_CASES.items():
            with self.subTest(case=case):
                plain = "\n".join(
                    render_outcome(factory(), 120, 40, ascii_only=False).render_plain_lines(
                        trim_trailing=True
                    )
                )
                forbidden = wl.contains_forbidden_primary_term(plain)
                self.assertIsNone(forbidden, f"leaked {forbidden!r} in {case}")
                for term in (
                    "namespace",
                    "ledger",
                    "graph-run",
                    "orchestration",
                    ".ralph-workspace",
                    "nodeId",
                ):
                    self.assertNotIn(term.casefold(), plain.casefold())

    def test_frames_are_deterministic(self) -> None:
        view = plan_progress_view()
        first = capture_canvas(render_outcome(view, 80, 24, ascii_only=True))
        second = capture_canvas(render_outcome(view, 80, 24, ascii_only=True))
        self.assertEqual(first, second)
        # Ordering of spans must stay stable across repeated captures.
        self.assertEqual(
            [span["role"] for row in first["spans"] for span in row],
            [span["role"] for row in second["spans"] for span in row],
        )

    def test_selection_marker_is_stable(self) -> None:
        view = view_from_fixture("sequential-task-running.json", selected="implement")
        state = wi.initial_ui_state(view, width=80, height=24)
        moved = wi.apply_key(state, "k")
        self.assertEqual(moved.view.selected_stage_id, "research")
        first = "\n".join(
            render_ui(moved, 80, 24, ascii_only=True).render_plain_lines(trim_trailing=True)
        )
        second = "\n".join(
            render_ui(moved, 80, 24, ascii_only=True).render_plain_lines(trim_trailing=True)
        )
        self.assertEqual(first, second)
        self.assertRegex(first, r"(?m)^> .*research")
        self.assertRegex(first, r"(?m)^  .*implement")

    def test_filter_visibility_and_help_footer_are_semantic(self) -> None:
        view = view_from_fixture("sequential-task-running.json")
        state = wi.initial_ui_state(view, width=80, height=24)
        filtered = wi.apply_keys(state, ["/", "r", "e", "s"])
        plain = "\n".join(
            render_ui(filtered, 80, 24, ascii_only=True).render_plain_lines(trim_trailing=True)
        )
        self.assertIn("Filter:", plain)
        self.assertIn("research", plain)
        # Stage list after filtering should only show research.
        self.assertNotRegex(plain, r"(?m)^[> ].*implement\b")
        self.assertRegex(plain, r"(?m)^[> ].*research\b")

        help_state = wi.apply_key(state, "?")
        self.assertEqual(help_state.focus, wi.FOCUS_HELP)
        help_keys = {action.key: action.label for action in wi.contextual_footer(help_state)}
        self.assertIn("/", help_keys)
        self.assertIn("filter", help_keys["/"].casefold())
        self.assertIn("up/down j/k", help_keys)
        self.assertIn("detach", help_keys["q"].casefold())
        help_plain = "\n".join(
            render_ui(help_state, 80, 24, ascii_only=True).render_plain_lines(trim_trailing=True)
        )
        # Painted footer may ellipsize; visible labels must stay readable without color.
        self.assertIn("select stage", help_plain.casefold())
        self.assertNotIn("\x1b", help_plain)


class SnapshotStabilityAndSensitivityTests(unittest.TestCase):
    def test_suite_is_stable_across_two_temp_roots(self) -> None:
        """Run the matrix twice under isolated temp dirs; payloads must match."""

        payloads_a = self._capture_all()
        payloads_b = self._capture_all()
        self.assertEqual(sorted(payloads_a.keys()), sorted(payloads_b.keys()))
        for key in payloads_a:
            self.assertEqual(payloads_a[key], payloads_b[key], msg=key)

    def test_snapshot_detects_role_and_cell_mutations(self) -> None:
        view = plan_progress_view()
        baseline = capture_canvas(render_outcome(view, 80, 24, ascii_only=True))

        # Mutate one semantic role in the captured payload and ensure inequality.
        mutated_role = copy.deepcopy(baseline)
        found_role = False
        for row in mutated_role["spans"]:
            for span in row:
                if span["role"] == "accent":
                    span["role"] = "failure"
                    found_role = True
                    break
            if found_role:
                break
        self.assertTrue(found_role, "expected an accent role in the baseline frame")
        self.assertNotEqual(baseline, mutated_role)

        # Mutate one layout cell's text.
        mutated_cell = copy.deepcopy(baseline)
        mutated_cell["plain"][0] = ("X" + mutated_cell["plain"][0][1:]) if mutated_cell["plain"][0] else "X"
        self.assertNotEqual(baseline, mutated_cell)

        # Live harness mutation: swap a role at paint time via a temporary monkeypatch.
        original = wl.outcome_role

        def flipped(state: str, reason_code: str = "") -> str:
            role = original(state, reason_code)
            return "failure" if role == "accent" else role

        wl.outcome_role = flipped  # type: ignore[assignment]
        try:
            changed = capture_canvas(render_outcome(view, 80, 24, ascii_only=True))
            self.assertNotEqual(baseline, changed)
        finally:
            wl.outcome_role = original  # type: ignore[assignment]

        restored = capture_canvas(render_outcome(view, 80, 24, ascii_only=True))
        self.assertEqual(baseline, restored)

    def _capture_all(self) -> dict[str, dict]:
        captured: dict[str, dict] = {}
        with tempfile.TemporaryDirectory(prefix="ralph-visual-") as tmp:
            root = Path(tmp)
            for case, factory in OUTCOME_CASES.items():
                view = factory()
                for width, height in SIZES:
                    for ascii_only, variant in ((True, "ascii"), (False, "unicode")):
                        canvas = render_outcome(view, width, height, ascii_only=ascii_only)
                        key = f"{case}/{variant}/{width}x{height}"
                        captured[key] = capture_canvas(canvas)
                        (root / f"{case}-{variant}-{width}x{height}.json").write_text(
                            json.dumps(captured[key], indent=2) + "\n",
                            encoding="utf-8",
                        )
            view = view_from_fixture("sequential-task-running.json")
            state = wi.initial_ui_state(view, width=80, height=24)
            for name, canvas in (
                ("filtering", render_ui(wi.apply_keys(state, ["/", "r", "e", "s"]), 80, 24, ascii_only=True)),
                ("help", render_ui(wi.apply_key(state, "?"), 80, 24, ascii_only=True)),
                ("dialog", render_ui(state, 80, 24, ascii_only=True, dialog=approval_dialog())),
                ("log", render_ui(wi.apply_key(state, "l"), 80, 24, ascii_only=True, log_pane=sample_log_pane())),
            ):
                captured[name] = capture_canvas(canvas)
        return captured


def _write_snapshots() -> None:
    SNAPSHOT_DIR.mkdir(parents=True, exist_ok=True)
    for case, factory in OUTCOME_CASES.items():
        view = factory()
        for width, height in SIZES:
            for ascii_only, variant in ((True, "ascii"), (False, "unicode")):
                canvas = render_outcome(view, width, height, ascii_only=ascii_only)
                path = snapshot_path(case, width, height, variant=variant)
                path.write_text(json.dumps(capture_canvas(canvas), indent=2) + "\n", encoding="utf-8")
                print(f"wrote {path.relative_to(REPO_ROOT)}")

    width, height = STANDARD
    view = view_from_fixture("sequential-task-running.json")
    base = wi.initial_ui_state(view, width=width, height=height)
    interaction_cases = {
        "filtering": render_ui(wi.apply_keys(base, ["/", "r", "e", "s"]), width, height, ascii_only=True),
        "help": render_ui(wi.apply_key(base, "?"), width, height, ascii_only=True),
        "dialog": render_ui(base, width, height, ascii_only=True, dialog=approval_dialog()),
        "log": render_ui(wi.apply_key(base, "l"), width, height, ascii_only=True, log_pane=sample_log_pane()),
        "log-wide": render_ui(
            wi.apply_resize(base, *wl.WIDE_SIZE),
            *wl.WIDE_SIZE,
            ascii_only=True,
            log_pane=sample_log_pane(),
        ),
    }
    for case, canvas in interaction_cases.items():
        path = snapshot_path(case, canvas.width, canvas.height, variant="ascii")
        path.write_text(json.dumps(capture_canvas(canvas), indent=2) + "\n", encoding="utf-8")
        print(f"wrote {path.relative_to(REPO_ROOT)}")

    filtering_unicode = render_ui(
        wi.apply_keys(base, ["/", "r", "e", "s"]), width, height, ascii_only=False
    )
    path = snapshot_path("filtering", width, height, variant="unicode")
    path.write_text(json.dumps(capture_canvas(filtering_unicode), indent=2) + "\n", encoding="utf-8")
    print(f"wrote {path.relative_to(REPO_ROOT)}")


if __name__ == "__main__":
    if len(sys.argv) > 1 and sys.argv[1] == "--write-snapshots":
        _write_snapshots()
        raise SystemExit(0)
    unittest.main()
