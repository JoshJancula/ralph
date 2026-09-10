#!/usr/bin/env python3
"""Table-driven unit tests for pure workflow-UI keyboard interaction."""

from __future__ import annotations

import copy
import json
import sys
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
PYTHON_DIR = REPO_ROOT / "bundle" / ".ralph" / "python"
FIXTURE_DIR = REPO_ROOT / "tests" / "bats" / "workflow" / "fixtures" / "status"
sys.path.insert(0, str(PYTHON_DIR))

import workflow_interaction as wi  # noqa: E402
import workflow_tui as wt  # noqa: E402


def fixture_payload(name: str) -> dict:
    return json.loads((FIXTURE_DIR / name).read_text(encoding="utf-8"))


def view_from_fixture(name: str, *, selected: str | None = None) -> wt.WorkflowViewModel:
    snapshot = wt.parse_status_snapshot(fixture_payload(name))
    return wt.view_from_snapshot(snapshot, selected)


def sequential_view() -> wt.WorkflowViewModel:
    """Two ordered stages: research (succeeded), implement (running, selected)."""

    return view_from_fixture("sequential-task-running.json")


def dependency_wave_view() -> wt.WorkflowViewModel:
    """Dependency run with four stages spanning three public waves."""

    payload = copy.deepcopy(fixture_payload("dependency-approval-wait.json"))
    payload["run"]["runId"] = "fixture-dep-waves"
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
            "artifacts": [],
            "blocker": None,
            "createdAt": "2026-08-27T01:00:00Z",
            "updatedAt": "2026-08-27T01:00:20Z",
        },
        {
            "id": "implement",
            "index": 1,
            "wave": 0,
            "state": "running",
            "stageKind": "plan-backed",
            "attempt": 1,
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
            "approval": {"question": "Approve the plan?", "changesTarget": "implement"},
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
    payload["diagnosis"]["stageId"] = "approve-plan"
    return wt.view_from_snapshot(wt.parse_status_snapshot(payload))


class ImportHygieneTests(unittest.TestCase):
    def test_module_imports_neither_curses_nor_engine_code(self) -> None:
        source = (PYTHON_DIR / "workflow_interaction.py").read_text(encoding="utf-8")
        self.assertNotIn("import curses", source)
        self.assertNotIn("from curses", source)
        for forbidden in ("workflow-engine-dependency", "workflow-engine-sequential", "graph_tui"):
            self.assertNotIn(forbidden, source)


class BindingTableTests(unittest.TestCase):
    """One case per documented key binding, table-driven."""

    def _state(self) -> wi.WorkflowUiState:
        return wi.initial_ui_state(sequential_view())

    def test_bindings_move_or_toggle_as_documented(self) -> None:
        # The running "implement" stage is selected by default (last in order).
        cases = [
            ("down is clamped at the last stage", "KEY_DOWN", lambda s: s.view.selected_stage_id, "implement"),
            ("j is clamped at the last stage", "j", lambda s: s.view.selected_stage_id, "implement"),
            ("k selects the previous stage", "k", lambda s: s.view.selected_stage_id, "research"),
            ("up arrow selects the previous stage", "KEY_UP", lambda s: s.view.selected_stage_id, "research"),
            ("home jumps to first stage", "g", lambda s: s.view.selected_stage_id, "research"),
            ("end jumps to last stage", "G", lambda s: s.view.selected_stage_id, "implement"),
            ("page-down clamps at the last stage", "KEY_NPAGE", lambda s: s.view.selected_stage_id, "implement"),
            ("page-up clamps at the first stage", "KEY_PPAGE", lambda s: s.view.selected_stage_id, "research"),
            ("d toggles the details view", "d", lambda s: s.details_view, True),
            ("l opens the live-tail command links", "l", lambda s: s.focus, wi.FOCUS_COMMANDS),
            ("c opens exact command help", "c", lambda s: s.focus, wi.FOCUS_COMMANDS),
            ("? opens the help overlay", "?", lambda s: s.focus, wi.FOCUS_HELP),
            ("r requests a refresh", "r", lambda s: s.refresh_requested, True),
            ("q requests quit detach", "q", lambda s: (s.quit_requested, s.detach_reason), (True, wi.DETACH_QUIT)),
            (
                "Ctrl-C requests interrupt detach",
                "\x03",
                lambda s: (s.quit_requested, s.detach_reason),
                (True, wi.DETACH_INTERRUPT),
            ),
            ("/ opens the filter editor", "/", lambda s: s.filter_editing, True),
        ]
        for description, key, extract, expected in cases:
            with self.subTest(description):
                result = wi.apply_key(self._state(), key)
                self.assertEqual(extract(result), expected)

    def test_j_k_are_equivalent_to_arrow_keys(self) -> None:
        base = self._state()
        via_letters = wi.apply_key(base, "j")
        via_arrows = wi.apply_key(base, "KEY_DOWN")
        self.assertEqual(via_letters.view.selected_stage_id, via_arrows.view.selected_stage_id)

    def test_unbound_key_is_a_no_op(self) -> None:
        base = self._state()
        result = wi.apply_key(base, "z")
        self.assertEqual(result, base)

    def test_details_toggle_requires_a_selected_stage(self) -> None:
        view = wt.WorkflowViewModel(snapshot=None, selected_stage_id=None)
        state = wi.initial_ui_state(view)
        result = wi.apply_key(state, "d")
        self.assertFalse(result.details_view)

    def test_log_toggle_without_a_selected_stage_still_lists_commands(self) -> None:
        view = wt.WorkflowViewModel(snapshot=None, selected_stage_id=None)
        state = wi.initial_ui_state(view)
        result = wi.apply_key(state, "l")
        self.assertEqual(result.focus, wi.FOCUS_COMMANDS)


class FocusTransferTests(unittest.TestCase):
    def test_commands_are_exact_stage_aware_and_scrollable(self) -> None:
        state = wi.initial_ui_state(sequential_view(), height=7)
        opened = wi.apply_key(state, "c")
        self.assertEqual(opened.focus, wi.FOCUS_COMMANDS)
        commands = wi.workflow_command_lines(opened)
        self.assertIn(
            "ralph workflow logs fixture-seq-running --stage implement --attempt 1 "
            "--stream combined --tail 200 --follow",
            commands,
        )
        self.assertIn(
            "ralph workflow status fixture-seq-running --json | jq "
            "'.stages[] | select(.id==\"implement\")'",
            commands,
        )
        self.assertIn(
            "ralph workflow status fixture-seq-running --json | jq -r "
            "'.stages[] | .artifacts[]?'",
            commands,
        )
        self.assertIn("ralph workflow handoff fixture-seq-running", commands)
        self.assertIn("# All stage logs and artifacts", commands)
        self.assertIn("ralph usage --run fixture-seq-running", commands)
        self.assertIn("# research (succeeded)", commands)
        self.assertIn(
            "ralph workflow logs fixture-seq-running --stage research --attempt 1 "
            "--stream combined --tail 200 --follow",
            commands,
        )
        self.assertIn("less /fixtures/research.md", commands)
        self.assertLess(len(wi.visible_command_lines(opened)), len(commands))
        scrolled = wi.apply_key(opened, "KEY_NPAGE")
        self.assertGreater(scrolled.command_offset, 0)
        closed = wi.apply_key(scrolled, "c")
        self.assertEqual(closed.focus, wi.FOCUS_STAGES)
        self.assertEqual(closed.command_offset, 0)

    def test_skipped_clone_does_not_claim_a_shared_declared_artifact(self) -> None:
        payload = copy.deepcopy(fixture_payload("sequential-task-running.json"))
        clone = copy.deepcopy(payload["stages"][1])
        clone.update(id="implement-r1", index=2, state="skipped", attempt=0)
        payload["stages"].append(clone)
        view = wt.view_from_snapshot(
            wt.parse_status_snapshot(payload), previous_selected_stage_id="implement-r1"
        )
        commands = wi.workflow_command_lines(wi.initial_ui_state(view))
        clone_index = commands.index("# implement-r1 (skipped)")
        self.assertIn("--stage implement-r1", commands[clone_index + 1])
        self.assertEqual(commands[clone_index + 2], "# no artifacts produced")

    def test_help_restores_the_prior_focus_from_stages(self) -> None:
        state = wi.initial_ui_state(sequential_view())
        opened = wi.apply_key(state, "?")
        closed = wi.apply_key(opened, "?")
        self.assertEqual(closed.focus, wi.FOCUS_STAGES)

    def test_help_ignores_navigation_and_reopens_on_toggle(self) -> None:
        state = wi.apply_key(wi.initial_ui_state(sequential_view()), "?")
        unmoved = wi.apply_key(state, "j")
        self.assertEqual(unmoved.focus, wi.FOCUS_HELP)
        self.assertEqual(unmoved.view.selected_stage_id, state.view.selected_stage_id)

    def test_quit_from_any_focus_is_terminal(self) -> None:
        for build in (
            lambda: wi.initial_ui_state(sequential_view()),
            lambda: wi.apply_key(wi.initial_ui_state(sequential_view()), "l"),
            lambda: wi.apply_key(wi.initial_ui_state(sequential_view()), "?"),
        ):
            with self.subTest(build):
                quitting = wi.apply_key(build(), "q")
                self.assertTrue(quitting.quit_requested)
                unchanged = wi.apply_key(quitting, "j")
                self.assertEqual(unchanged, quitting)


class FilteringTests(unittest.TestCase):
    def test_navigation_omits_conditional_routes_until_they_are_entered(self) -> None:
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
        state = wi.initial_ui_state(
            wt.view_from_snapshot(wt.parse_status_snapshot(payload))
        )
        self.assertEqual(wi.visible_stage_ids(state), ("review",))

        branch["state"] = "running"
        branch["attempt"] = 1
        state = wi.apply_refresh(state, wt.parse_status_snapshot(payload))
        self.assertEqual(
            wi.visible_stage_ids(state),
            ("review", "implement-r1", "review-r1"),
        )

    def test_command_catalog_omits_conditional_routes_until_they_are_entered(
        self,
    ) -> None:
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
        state = wi.initial_ui_state(
            wt.view_from_snapshot(wt.parse_status_snapshot(payload))
        )
        commands = wi.workflow_command_lines(state)
        catalog_start = commands.index("# All stage logs and artifacts")
        catalog = commands[catalog_start:]
        self.assertIn("# review (running)", catalog)
        catalog_text = "\n".join(catalog)
        self.assertNotIn("implement-r1", catalog_text)
        self.assertNotIn("review-r1", catalog_text)

        branch["state"] = "running"
        branch["attempt"] = 1
        state = wi.apply_refresh(state, wt.parse_status_snapshot(payload))
        commands = wi.workflow_command_lines(state)
        catalog_start = commands.index("# All stage logs and artifacts")
        catalog = commands[catalog_start:]
        self.assertIn("# review (running)", catalog)
        self.assertIn("# implement-r1 (running)", catalog)
        self.assertIn("# review-r1 (queued)", catalog)

    def test_incremental_filter_narrows_visible_stages(self) -> None:
        state = wi.initial_ui_state(sequential_view())
        editing = wi.apply_keys(state, ["/", "r", "e", "s"])
        self.assertEqual(wi.visible_stage_ids(editing), ("research",))
        self.assertEqual(editing.view.selected_stage_id, "research")

    def test_filter_is_case_insensitive_and_matches_state_and_kind(self) -> None:
        state = wi.initial_ui_state(sequential_view())
        by_state = wi.apply_keys(state, ["/", "R", "U", "N"])
        self.assertEqual(wi.visible_stage_ids(by_state), ("implement",))

    def test_empty_filter_results_clear_selection(self) -> None:
        state = wi.initial_ui_state(sequential_view())
        no_matches = wi.apply_keys(state, ["/", "z", "z", "z"])
        self.assertEqual(wi.visible_stage_ids(no_matches), ())
        self.assertIsNone(no_matches.view.selected_stage_id)

    def test_escape_while_editing_reverts_to_the_prior_query(self) -> None:
        state = wi.initial_ui_state(sequential_view())
        state = wi.apply_keys(state, ["/", "r", "e"])
        committed = wi.apply_key(state, "\n")
        editing_again = wi.apply_keys(committed, ["/", "x", "x"])
        reverted = wi.apply_key(editing_again, "\x1b")
        self.assertEqual(reverted.filter_query, "re")
        self.assertFalse(reverted.filter_editing)

    def test_escape_without_editing_clears_an_active_filter(self) -> None:
        state = wi.initial_ui_state(sequential_view())
        committed = wi.apply_key(wi.apply_keys(state, ["/", "r", "e"]), "\n")
        cleared = wi.apply_key(committed, "\x1b")
        self.assertEqual(cleared.filter_query, "")
        self.assertEqual(wi.visible_stage_ids(cleared), ("research", "implement"))

    def test_escape_without_an_active_filter_is_a_no_op(self) -> None:
        state = wi.initial_ui_state(sequential_view())
        result = wi.apply_key(state, "\x1b")
        self.assertEqual(result, state)

    def test_backspace_edits_the_filter_incrementally(self) -> None:
        state = wi.initial_ui_state(sequential_view())
        typed = wi.apply_keys(state, ["/", "r", "e", "s", "\x7f"])
        self.assertEqual(typed.filter_query, "re")

    def test_typing_while_help_is_open_does_not_leak_into_the_filter(self) -> None:
        state = wi.apply_key(wi.initial_ui_state(sequential_view()), "?")
        after_letters = wi.apply_keys(state, ["r", "e", "s"])
        self.assertEqual(after_letters.filter_query, "")
        self.assertEqual(after_letters.focus, wi.FOCUS_HELP)


class RefreshReconciliationTests(unittest.TestCase):
    def test_refresh_preserves_selection_filter_and_details_toggle(self) -> None:
        state = wi.initial_ui_state(sequential_view())
        state = wi.apply_key(wi.apply_keys(state, ["/", "i", "m"]), "\n")
        state = wi.apply_key(state, "d")
        self.assertTrue(state.details_view)

        payload = copy.deepcopy(fixture_payload("sequential-task-running.json"))
        payload["run"]["updatedAt"] = "2026-01-01T00:05:00Z"
        refreshed_snapshot = wt.parse_status_snapshot(payload)

        refreshed = wi.apply_refresh(state, refreshed_snapshot)
        self.assertEqual(refreshed.filter_query, "im")
        self.assertEqual(refreshed.view.selected_stage_id, "implement")
        self.assertTrue(refreshed.details_view)
        self.assertFalse(refreshed.refresh_requested)

    def test_refresh_tracks_new_running_stage_until_operator_moves_selection(self) -> None:
        initial_payload = copy.deepcopy(fixture_payload("sequential-task-running.json"))
        for stage in initial_payload["stages"]:
            stage["state"] = "queued"
        initial_payload["diagnosis"]["stageId"] = None
        state = wi.initial_ui_state(
            wt.view_from_snapshot(wt.parse_status_snapshot(initial_payload))
        )
        self.assertEqual(state.view.selected_stage_id, "research")
        self.assertFalse(state.selection_touched)

        running_payload = copy.deepcopy(initial_payload)
        running_payload["stages"][1]["state"] = "running"
        state = wi.apply_refresh(state, wt.parse_status_snapshot(running_payload))
        self.assertEqual(state.view.selected_stage_id, "implement")

        state = wi.apply_key(state, "k")
        self.assertEqual(state.view.selected_stage_id, "research")
        self.assertTrue(state.selection_touched)
        state = wi.apply_refresh(state, wt.parse_status_snapshot(running_payload))
        self.assertEqual(state.view.selected_stage_id, "research")

        advanced_payload = copy.deepcopy(running_payload)
        advanced_payload["stages"][1]["state"] = "succeeded"
        advanced_payload["stages"].append(
            {"id": "verify", "index": 2, "state": "running", "stageKind": "executable"}
        )
        advanced_payload["diagnosis"]["stageId"] = "verify"
        state = wi.apply_refresh(state, wt.parse_status_snapshot(advanced_payload))
        self.assertEqual(state.view.selected_stage_id, "verify")
        self.assertFalse(state.selection_touched)

    def test_opening_details_or_links_does_not_disable_auto_follow(self) -> None:
        initial_payload = copy.deepcopy(fixture_payload("sequential-task-running.json"))
        state = wi.initial_ui_state(
            wt.view_from_snapshot(wt.parse_status_snapshot(initial_payload))
        )
        self.assertEqual(state.view.selected_stage_id, "implement")

        state = wi.apply_key(state, "d")
        state = wi.apply_key(state, "l")
        self.assertFalse(state.selection_touched)

        advanced_payload = copy.deepcopy(initial_payload)
        advanced_payload["stages"][1]["state"] = "succeeded"
        advanced_payload["stages"].append(
            {"id": "verify", "index": 2, "state": "running", "stageKind": "executable"}
        )
        advanced_payload["diagnosis"]["stageId"] = "verify"
        state = wi.apply_refresh(state, wt.parse_status_snapshot(advanced_payload))
        self.assertEqual(state.view.selected_stage_id, "verify")

    def test_refresh_reclamps_selection_when_filtered_out(self) -> None:
        state = wi.initial_ui_state(sequential_view())
        state = wi.apply_keys(state, ["/", "r", "e", "s"])
        self.assertEqual(state.view.selected_stage_id, "research")

        payload = copy.deepcopy(fixture_payload("sequential-task-running.json"))
        payload["stages"][0]["id"] = "qa-check"
        refreshed_snapshot = wt.parse_status_snapshot(payload)

        refreshed = wi.apply_refresh(state, refreshed_snapshot)
        # "qa-check" no longer matches "res"; selection clears.
        self.assertEqual(wi.visible_stage_ids(refreshed), ())
        self.assertIsNone(refreshed.view.selected_stage_id)

    def test_apply_error_preserves_the_last_good_snapshot(self) -> None:
        state = wi.initial_ui_state(sequential_view())
        error = wt.UiError("unavailable", "Workflow status is unavailable.")
        errored = wi.apply_error(state, error)
        self.assertIsNotNone(errored.view.snapshot)
        self.assertEqual(errored.view.error, error)
        self.assertFalse(errored.refresh_requested)


class ResizeTests(unittest.TestCase):
    def test_resize_preserves_selection_and_filter(self) -> None:
        state = wi.initial_ui_state(sequential_view(), width=80, height=24)
        state = wi.apply_keys(state, ["/", "r", "e"])
        resized = wi.apply_resize(state, 40, 12)
        self.assertEqual(resized.width, 40)
        self.assertEqual(resized.height, 12)
        self.assertEqual(resized.filter_query, "re")
        self.assertEqual(resized.view.selected_stage_id, state.view.selected_stage_id)
        self.assertEqual(resized.filter_editing, state.filter_editing)

    def test_resize_action_key_is_a_pure_no_op(self) -> None:
        state = wi.initial_ui_state(sequential_view())
        result = wi.apply_key(state, "KEY_RESIZE")
        self.assertEqual(result, state)

    def test_resize_clamps_negative_dimensions_to_zero(self) -> None:
        state = wi.initial_ui_state(sequential_view())
        resized = wi.apply_resize(state, -5, -1)
        self.assertEqual((resized.width, resized.height), (0, 0))


class FooterContractTests(unittest.TestCase):
    def _keys(self, state: wi.WorkflowUiState) -> set:
        return {action.key for action in wi.contextual_footer(state)}

    def test_stage_focus_footer_omits_retired_log_stream_bindings(self) -> None:
        state = wi.initial_ui_state(sequential_view())
        keys = self._keys(state)
        self.assertNotIn("s", keys)
        self.assertNotIn("f", keys)
        self.assertNotIn("p", keys)

    def test_terminal_run_footer_says_close_instead_of_continues(self) -> None:
        view = view_from_fixture("dependency-cancelled.json")
        state = wi.initial_ui_state(view)
        quit_action = next(
            action for action in wi.contextual_footer(state) if action.key == "q"
        )
        self.assertEqual(quit_action.label, "close viewer")

    def test_links_overlay_footer_omits_stage_only_bindings(self) -> None:
        state = wi.apply_key(wi.initial_ui_state(sequential_view()), "l")
        keys = self._keys(state)
        for hidden in ("/", "d", "up/down j/k", "a"):
            self.assertNotIn(hidden, keys)

    def test_footer_hides_details_and_logs_without_a_selected_stage(self) -> None:
        view = wt.WorkflowViewModel(snapshot=None, selected_stage_id=None)
        state = wi.initial_ui_state(view)
        keys = self._keys(state)
        self.assertNotIn("d", keys)
        self.assertNotIn("l", keys)

    def test_footer_hides_clear_filter_when_no_filter_is_active(self) -> None:
        state = wi.initial_ui_state(sequential_view())
        actions = wi.contextual_footer(state)
        self.assertFalse(any(a.key == "Esc" and a.label == "clear filter" for a in actions))

    def test_footer_shows_clear_filter_once_a_filter_is_active(self) -> None:
        state = wi.apply_key(wi.apply_keys(wi.initial_ui_state(sequential_view()), ["/", "r"]), "\n")
        actions = wi.contextual_footer(state)
        self.assertTrue(any(a.key == "Esc" and a.label == "clear filter" for a in actions))

    def test_footer_hides_navigation_with_a_single_matching_stage(self) -> None:
        state = wi.apply_key(wi.apply_keys(wi.initial_ui_state(sequential_view()), ["/", "r", "e", "s"]), "\n")
        keys = self._keys(state)
        self.assertNotIn("up/down j/k", keys)

    def test_filter_editing_footer_only_lists_editing_actions(self) -> None:
        state = wi.apply_key(wi.initial_ui_state(sequential_view()), "/")
        actions = wi.contextual_footer(state)
        keys = {a.key for a in actions}
        self.assertEqual(keys, {"type", "Enter", "Esc", "Backspace"})

    def test_help_footer_documents_every_binding_key(self) -> None:
        help_state = wi.apply_key(wi.initial_ui_state(sequential_view()), "?")
        help_keys = {a.key for a in wi.contextual_footer(help_state)}
        expected = {
            "up/down j/k",
            "PgUp/PgDn",
            "Home/End",
            "/",
            "Esc",
            "d",
            "a",
            "l",
            "c",
            "r",
            "?",
            "q",
            "Ctrl-C",
        }
        self.assertEqual(help_keys, expected)

    def test_no_available_action_is_ever_missing_its_key_handler(self) -> None:
        """Every footer key advertised in stage focus corresponds to a bound action."""

        state = wi.initial_ui_state(sequential_view())
        for action in wi.contextual_footer(state):
            if action.key in ("up/down j/k", "PgUp/PgDn", "Home/End", "type"):
                continue
            key_for_action = {
                "/": "/",
                "d": "d",
                "l": "l",
                "c": "c",
                "r": "r",
                "?": "?",
                "q": "q",
                "Esc": "\x1b",
            }.get(action.key)
            if key_for_action is None:
                continue
            before = state
            after = wi.apply_key(state, key_for_action)
            self.assertNotEqual(
                after,
                before,
                f"footer advertises {action.key!r} but it produced no state change",
            )


class DependencyModeTests(unittest.TestCase):
    def test_navigation_and_filter_work_across_dependency_waves(self) -> None:
        state = wi.initial_ui_state(dependency_wave_view())
        stage_ids = tuple(stage.id for stage in state.view.stages)
        self.assertEqual(stage_ids, ("research", "implement", "approve-plan", "integrate"))
        first = wi.apply_key(state, "g")
        self.assertEqual(first.view.selected_stage_id, stage_ids[0])
        last = wi.apply_key(state, "G")
        self.assertEqual(last.view.selected_stage_id, stage_ids[-1])

    def test_filter_narrows_to_a_matching_stage_kind(self) -> None:
        state = wi.initial_ui_state(dependency_wave_view())
        editing = wi.apply_keys(state, ["/", "a", "p", "p", "r", "o", "v", "a", "l"])
        self.assertEqual(wi.visible_stage_ids(editing), ("approve-plan",))


if __name__ == "__main__":
    unittest.main()
