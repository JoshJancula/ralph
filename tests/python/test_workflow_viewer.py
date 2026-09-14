#!/usr/bin/env python3
"""Unit tests for the public workflow watch viewer entrypoint."""

from __future__ import annotations

import json
import sys
import unittest
from pathlib import Path
from unittest import mock

REPO_ROOT = Path(__file__).resolve().parents[2]
PYTHON_DIR = REPO_ROOT / "bundle" / ".ralph" / "python"
FIXTURE_DIR = REPO_ROOT / "tests" / "bats" / "workflow" / "fixtures" / "status"
sys.path.insert(0, str(PYTHON_DIR))

import workflow_tui as wt  # noqa: E402
import workflow_viewer as viewer  # noqa: E402


def view_from_fixture(name: str) -> wt.WorkflowViewModel:
    payload = json.loads((FIXTURE_DIR / name).read_text(encoding="utf-8"))
    return wt.view_from_snapshot(wt.parse_status_snapshot(payload))


class SelectBackendTests(unittest.TestCase):
    def test_force_plain_and_non_tty_select_streaming(self) -> None:
        imported = False

        def importer() -> object:
            nonlocal imported
            imported = True
            return object()

        cases = (
            {"force_plain": True},
            {"stdin_isatty": False, "stdout_isatty": True},
            {"stdin_isatty": True, "stdout_isatty": False},
            {"environ": {"CI": "1"}},
            {"environ": {"TERM": "dumb"}},
            {"environ": {"RALPH_GRAPH_PLAIN": "1"}},
            {"environ": {"RALPH_GRAPH_NO_TUI": "yes"}},
            {"environ": {"ACCESSIBILITY_SCREEN_READER": "1"}},
        )
        for options in cases:
            with self.subTest(options=options):
                plan = viewer.select_viewer_backend(curses_importer=importer, **options)
                self.assertEqual(plan.backend, viewer.BACKEND_PLAIN)
        self.assertFalse(imported)

    def test_suitable_tty_selects_curses(self) -> None:
        plan = viewer.select_viewer_backend(
            force_plain=False,
            stdin_isatty=True,
            stdout_isatty=True,
            environ={"TERM": "xterm-256color"},
            curses_importer=lambda: object(),
        )
        self.assertEqual(plan.backend, viewer.BACKEND_CURSES)

    def test_missing_curses_falls_back_to_plain(self) -> None:
        def importer() -> object:
            raise ImportError("curses")

        plan = viewer.select_viewer_backend(
            stdin_isatty=True,
            stdout_isatty=True,
            environ={"TERM": "xterm"},
            curses_importer=importer,
        )
        self.assertEqual(plan.backend, viewer.BACKEND_PLAIN)
        self.assertEqual(plan.reason, "curses")


class StopWatchingTests(unittest.TestCase):
    def test_terminal_and_waiting_stop_running_continues(self) -> None:
        self.assertTrue(viewer.should_stop_watching(view_from_fixture("dependency-plan-succeeded.json")))
        self.assertTrue(viewer.should_stop_watching(view_from_fixture("dependency-cancelled.json")))
        self.assertTrue(viewer.should_stop_watching(view_from_fixture("dependency-approval-wait.json")))
        self.assertTrue(viewer.should_stop_watching(view_from_fixture("sequential-input-wait.json")))
        self.assertFalse(viewer.should_stop_watching(view_from_fixture("sequential-task-running.json")))
        self.assertFalse(viewer.should_stop_watching(view_from_fixture("sequential-stale.json")))


class PlainWatchTests(unittest.TestCase):
    def test_waiting_fixture_prints_one_frame_and_exits_zero(self) -> None:
        frames: list[str] = []
        result = viewer.run_plain_watch(
            "fixture-seq-input",
            loader=lambda _run_id, _prev: view_from_fixture("sequential-input-wait.json"),
            output=frames.append,
            sleep=lambda _seconds: None,
        )
        self.assertEqual(result.exit_code, 0)
        self.assertEqual(result.backend, viewer.BACKEND_PLAIN)
        self.assertEqual(result.frames, 1)
        self.assertIn("Workflow status", frames[0])
        self.assertIn("State: waiting (operator-input)", frames[0])

    def test_running_respects_max_polls_without_duplicate_frames(self) -> None:
        frames: list[str] = []
        result = viewer.run_plain_watch(
            "fixture-seq-running",
            loader=lambda _run_id, _prev: view_from_fixture("sequential-task-running.json"),
            output=frames.append,
            sleep=lambda _seconds: None,
            max_polls=3,
            refresh_interval=0.01,
        )
        self.assertEqual(result.exit_code, 0)
        self.assertEqual(result.frames, 1)
        self.assertEqual(len(frames), 1)

    def test_unavailable_status_exits_one(self) -> None:
        error_view = wt.WorkflowViewModel(
            snapshot=None,
            selected_stage_id=None,
            error=wt.UiError("unavailable", "Workflow status is unavailable."),
        )
        result = viewer.run_plain_watch(
            "missing",
            loader=lambda _run_id, _prev: error_view,
            output=lambda _text: None,
            sleep=lambda _seconds: None,
        )
        self.assertEqual(result.exit_code, 1)


class CursesWatchRoutingTests(unittest.TestCase):
    def test_q_detach_returns_zero_without_cancel(self) -> None:
        view = view_from_fixture("sequential-task-running.json")
        with mock.patch.object(viewer.wcurse, "run_curses_session") as session:
            session.return_value = viewer.wcurse.CursesSessionResult(
                exit_code=0, frames=2, quit_requested=True
            )
            result = viewer.run_curses_watch(
                "fixture-seq-running",
                loader=lambda _run_id, _prev: view,
                keys=("q",),
            )
        self.assertEqual(result.exit_code, 0)
        self.assertTrue(result.quit_requested)
        kwargs = session.call_args.kwargs
        self.assertIs(kwargs["should_stop"], viewer.should_stop_watching)

    def test_ctrl_c_returns_130(self) -> None:
        view = view_from_fixture("sequential-task-running.json")
        with mock.patch.object(viewer.wcurse, "run_curses_session") as session:
            session.return_value = viewer.wcurse.CursesSessionResult(
                exit_code=130, frames=1, quit_requested=True
            )
            result = viewer.run_curses_watch(
                "fixture-seq-running",
                loader=lambda _run_id, _prev: view,
            )
        self.assertEqual(result.exit_code, 130)

    def test_run_workflow_viewer_falls_back_when_curses_raises(self) -> None:
        frames: list[str] = []

        def boom(*_args: object, **_kwargs: object) -> viewer.ViewerSessionResult:
            raise RuntimeError("curses boom")

        with mock.patch.object(viewer, "run_curses_watch", side_effect=boom):
            result = viewer.run_workflow_viewer(
                "fixture-dep-approval",
                force_plain=False,
                stdin_isatty=True,
                stdout_isatty=True,
                environ={"TERM": "xterm"},
                curses_importer=lambda: object(),
                loader=lambda _run_id, _prev: view_from_fixture("dependency-approval-wait.json"),
                output=frames.append,
                sleep=lambda _seconds: None,
            )
        self.assertEqual(result.backend, viewer.BACKEND_PLAIN)
        self.assertEqual(result.exit_code, 0)
        self.assertTrue(any("human-approval" in frame for frame in frames))


class ArgvTests(unittest.TestCase):
    def test_latest_and_paths_are_rejected(self) -> None:
        self.assertEqual(viewer.main(["--run-id", "latest"]), 2)
        self.assertEqual(viewer.main(["--run-id", "a/b"]), 2)

    def test_probe_prints_backend(self) -> None:
        with mock.patch("builtins.print") as printed:
            code = viewer.main(["--run-id", "run-x", "--plain", "--probe"])
        self.assertEqual(code, 0)
        printed.assert_any_call("plain")


if __name__ == "__main__":
    unittest.main()


class ColdStartResilienceTests(unittest.TestCase):
    """A slow first status refresh must not kill watch.

    Every refresh shells out to the `ralph workflow status` bash CLI, and the
    host most likely to be slow is the one running the workflow being watched.
    Before this, one first-poll timeout exited 1 without printing a frame.
    """

    def _timeout_view(self):
        return wt.WorkflowViewModel(
            snapshot=None,
            selected_stage_id=None,
            error=wt.UiError("timeout", "Workflow status refresh timed out."),
        )

    def test_transient_first_poll_is_retried_then_succeeds(self) -> None:
        good = view_from_fixture("dependency-plan-succeeded.json")
        calls = {"n": 0}

        def loader(_run_id, _prev):
            calls["n"] += 1
            return self._timeout_view() if calls["n"] == 1 else good

        result = viewer.run_plain_watch(
            "run-x",
            loader=loader,
            output=lambda _text: None,
            sleep=lambda _seconds: None,
        )
        self.assertEqual(result.exit_code, 0)
        self.assertGreaterEqual(calls["n"], 2)

    def test_persistent_transient_failure_still_exits_one_and_is_bounded(self) -> None:
        calls = {"n": 0}

        def loader(_run_id, _prev):
            calls["n"] += 1
            return self._timeout_view()

        result = viewer.run_plain_watch(
            "run-x",
            loader=loader,
            output=lambda _text: None,
            sleep=lambda _seconds: None,
        )
        self.assertEqual(result.exit_code, 1)
        self.assertLessEqual(calls["n"], viewer.COLD_START_RETRY_LIMIT + 1)

    def test_deterministic_caller_error_fails_immediately(self) -> None:
        bad = wt.WorkflowViewModel(
            snapshot=None,
            selected_stage_id=None,
            error=wt.UiError("invalid-run-id", "An exact workflow run ID is required."),
        )
        calls = {"n": 0}

        def loader(_run_id, _prev):
            calls["n"] += 1
            return bad

        result = viewer.run_plain_watch(
            "nope",
            loader=loader,
            output=lambda _text: None,
            sleep=lambda _seconds: None,
        )
        self.assertEqual(result.exit_code, 1)
        self.assertEqual(calls["n"], 1, "a malformed run id must not be retried")
