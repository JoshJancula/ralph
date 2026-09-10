#!/usr/bin/env python3
"""Tests for the semantic workflow canvas curses backend."""

from __future__ import annotations

import json
import sys
import threading
import unittest
from dataclasses import replace
from datetime import datetime, timezone
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO_ROOT / "bundle" / ".ralph" / "python"))

import workflow_canvas as wc  # noqa: E402
import workflow_curses as backend  # noqa: E402
import workflow_interaction as wi  # noqa: E402
import workflow_operator_actions as woa  # noqa: E402
import workflow_tui as wt  # noqa: E402


class FakeCursesError(Exception):
    pass


class FakeScreen:
    def __init__(self, keys: tuple[object, ...] = ()) -> None:
        self.keys = iter(keys)
        self.height = 24
        self.width = 80
        self.added: list[tuple[int, int, str, int]] = []
        self.timeout_values: list[int] = []
        self.keypad_values: list[bool] = []
        self.erase_calls = 0
        self.refresh_calls = 0

    def getmaxyx(self) -> tuple[int, int]:
        return self.height, self.width

    def addstr(self, y: int, x: int, text: str, attr: int) -> None:
        self.added.append((y, x, text, attr))

    def timeout(self, value: int) -> None:
        self.timeout_values.append(value)

    def keypad(self, value: bool) -> None:
        self.keypad_values.append(value)

    def nodelay(self, value: bool) -> None:
        del value

    def erase(self) -> None:
        self.erase_calls += 1

    def refresh(self) -> None:
        self.refresh_calls += 1

    def getch(self) -> object:
        return next(self.keys, -1)


class FakeCurses:
    A_NORMAL = 0
    A_BOLD = 1
    A_DIM = 2
    A_REVERSE = 4
    COLOR_BLACK = 0
    COLOR_CYAN = 6
    COLOR_GREEN = 2
    COLOR_YELLOW = 3
    COLOR_RED = 1
    error = FakeCursesError

    def __init__(self, *, keys: tuple[object, ...] = (), fail_at: str = "") -> None:
        self.screen = FakeScreen(keys)
        self.fail_at = fail_at
        self.calls: list[str] = []
        self.pairs: list[tuple[int, int, int]] = []

    def _call(self, name: str) -> None:
        self.calls.append(name)
        if self.fail_at == name:
            raise RuntimeError(name)

    def initscr(self) -> FakeScreen:
        self._call("initscr")
        return self.screen

    def noecho(self) -> None:
        self._call("noecho")

    def echo(self) -> None:
        self._call("echo")

    def cbreak(self) -> None:
        self._call("cbreak")

    def nocbreak(self) -> None:
        self._call("nocbreak")

    def raw(self) -> None:
        self._call("raw")

    def noraw(self) -> None:
        self._call("noraw")

    def curs_set(self, value: int) -> int:
        self._call(f"curs_set:{value}")
        return 1

    def endwin(self) -> None:
        self._call("endwin")

    def has_colors(self) -> bool:
        return True

    def start_color(self) -> None:
        self._call("start_color")

    def use_default_colors(self) -> None:
        self._call("use_default_colors")

    def init_pair(self, pair: int, foreground: int, background: int) -> None:
        self.pairs.append((pair, foreground, background))

    def color_pair(self, pair: int) -> int:
        return pair << 8


class FakeTermios:
    TCSANOW = 0

    def __init__(self) -> None:
        self.saved = ["saved"]
        self.get_calls = 0
        self.set_calls: list[tuple[int, int, object]] = []

    def tcgetattr(self, fd: int) -> object:
        self.get_calls += 1
        return self.saved

    def tcsetattr(self, fd: int, when: int, attributes: object) -> None:
        self.set_calls.append((fd, when, attributes))


class FakeSignal:
    SIGINT = 2
    SIGTERM = 15

    def __init__(self) -> None:
        self.original = {self.SIGINT: object(), self.SIGTERM: object()}
        self.current = dict(self.original)
        self.calls: list[tuple[int, object]] = []

    def signal(self, number: int, handler: object) -> object:
        previous = self.current[number]
        self.current[number] = handler
        self.calls.append((number, handler))
        return previous


class CapabilityTests(unittest.TestCase):
    def test_unsuitable_terminal_is_rejected_before_curses_import(self) -> None:
        imported = False

        def importer() -> object:
            nonlocal imported
            imported = True
            return object()

        caps = backend.probe_curses_capabilities(
            stdin_isatty=False,
            stdout_isatty=True,
            term="xterm",
            curses_importer=importer,
        )
        self.assertFalse(caps.available)
        self.assertEqual(caps.reason, "tty")
        self.assertFalse(imported)


class PaintingTests(unittest.TestCase):
    def test_semantic_roles_are_painted_and_identical_frame_is_diffed(self) -> None:
        curses = FakeCurses()
        screen = curses.screen
        palette = backend.init_palette(curses)
        canvas = wc.Canvas(12, 2)
        canvas.write(0, 0, "run", role="accent")
        canvas.write(4, 0, "ok", role="success")
        canvas.write(7, 0, "wait", role="warning")
        canvas.write(0, 1, "bad", role="failure")
        first = backend.paint_canvas(screen, canvas, curses=curses, palette=palette)
        first_paints = len(screen.added)
        backend.paint_canvas(screen, canvas, curses=curses, palette=palette, previous=first)
        self.assertGreater(first_paints, 0)
        self.assertEqual(len(screen.added), first_paints)
        self.assertEqual(screen.refresh_calls, 2)
        self.assertGreater(len({attr for _, _, _, attr in screen.added}), 2)

    def test_unexpected_paint_error_propagates_for_lifecycle_cleanup(self) -> None:
        curses = FakeCurses()
        canvas = wc.Canvas(2, 1)
        canvas.write(0, 0, "x")

        def fail(*args: object) -> None:
            raise RuntimeError("paint")

        curses.screen.addstr = fail  # type: ignore[method-assign]
        with self.assertRaisesRegex(RuntimeError, "paint"):
            backend.paint_canvas(curses.screen, canvas, curses=curses, palette=backend.init_palette(curses))

    def test_shallow_primary_frame_separates_completed_stages(self) -> None:
        fixture = (
            REPO_ROOT
            / "tests"
            / "bats"
            / "workflow"
            / "fixtures"
            / "status"
            / "sequential-task-running.json"
        )
        payload = json.loads(fixture.read_text(encoding="utf-8"))
        payload["stages"][1]["dependencies"] = [
            {"stageId": "research", "condition": None}
        ]
        snapshot = wt.parse_status_snapshot(payload)
        view = wt.WorkflowViewModel(snapshot=snapshot, selected_stage_id="implement")
        state = wi.initial_ui_state(view, width=210, height=9)
        canvas = backend.render_canvas(
            state,
            width=210,
            height=9,
            now=datetime(2026, 8, 27, 1, 2, tzinfo=timezone.utc),
            ascii_only=True,
        )
        rendered = canvas.render_plain(trim_trailing=True)

        self.assertIn("task (explicit)", rendered)
        self.assertIn("Progress  1 complete · 1 in progress · 0 remaining", rendered)
        self.assertIn("-- x research (complete)", rendered)
        self.assertIn("implement (in progress)", rendered)
        self.assertIn("SELECTED", rendered)
        self.assertIn(
            "Inspect  > implement (running)  Up/Down or j/k selects a different stage  "
            "d details  l live tail  c all stage links",
            rendered,
        )
        self.assertIn(
            "ralph workflow logs fixture-seq-running --stage implement --attempt 1 "
            "--stream combined --tail 200 --follow",
            rendered,
        )
        self.assertIn("Artifact less /fixtures/implementation.md", rendered)
        self.assertNotIn("ralph workflow actions list fixture-seq-running", rendered)
        self.assertIn("q detach; run continues", rendered)
        roles = {span.role for span in canvas.iter_spans()}
        self.assertTrue({"accent", "command", "muted", "focus"}.issubset(roles))

        moved = backend.render_canvas(
            wi.apply_key(state, "KEY_UP"),
            width=210,
            height=9,
            now=datetime(2026, 8, 27, 1, 2, tzinfo=timezone.utc),
            ascii_only=True,
        ).render_plain(trim_trailing=True)
        self.assertIn("research (complete)", moved)
        self.assertIn("SELECTED", moved)
        self.assertIn("Inspect  > research (succeeded)", moved)
        self.assertIn("Up/Down or j/k selects a different stage", moved)

        # The viewer never streams log content: the primary inspection rows
        # keep the exact live-tail command instead.
        refreshed = backend.render_canvas(
            state,
            width=210,
            height=9,
            now=datetime(2026, 8, 27, 1, 2, 1, tzinfo=timezone.utc),
            ascii_only=True,
        ).render_plain(trim_trailing=True)
        for command in (
            "--stream combined --tail 200 --follow",
            "less /fixtures/implementation.md",
            "c all stage links",
        ):
            self.assertIn(command, refreshed)

        details = backend.render_canvas(
            wi.apply_key(state, "d"),
            width=210,
            height=9,
            now=datetime(2026, 8, 27, 1, 2, 1, tzinfo=timezone.utc),
            ascii_only=True,
        ).render_plain(trim_trailing=True)
        self.assertIn("Depends on  research", details)
        self.assertNotIn("c all stage links", details)

    def test_shallow_waiting_frame_prioritizes_request_command(self) -> None:
        fixture = (
            REPO_ROOT
            / "tests"
            / "bats"
            / "workflow"
            / "fixtures"
            / "status"
            / "dependency-approval-wait.json"
        )
        snapshot = wt.parse_status_snapshot(json.loads(fixture.read_text(encoding="utf-8")))
        view = wt.WorkflowViewModel(snapshot=snapshot, selected_stage_id="approve-plan")
        state = wi.initial_ui_state(view, width=210, height=9)
        rendered = backend.render_canvas(
            state,
            width=210,
            height=9,
            now=datetime(2026, 8, 27, 1, 2, tzinfo=timezone.utc),
            ascii_only=True,
        ).render_plain(trim_trailing=True)

        self.assertIn("Progress  0 complete · 1 needs attention · 0 remaining", rendered)
        self.assertIn("approve-plan (waiting)", rendered)
        self.assertIn("SELECTED", rendered)
        self.assertIn("Inspect  > approve-plan (waiting)", rendered)
        self.assertIn("ralph workflow actions list fixture-dep-approval", rendered)
        self.assertIn("Artifact none yet", rendered)
        self.assertIn("q detach; run continues", rendered)


class LifecycleTests(unittest.TestCase):
    def _guard(self, curses: FakeCurses, termios: FakeTermios, signals: FakeSignal) -> backend.TerminalRestorer:
        return backend.TerminalRestorer(
            termios_mod=termios, signal_mod=signals, curses_mod=curses
        )

    def test_restoration_is_complete_and_idempotent(self) -> None:
        curses, termios, signals = FakeCurses(), FakeTermios(), FakeSignal()
        guard = self._guard(curses, termios, signals)
        guard.install()
        guard.begin_screen()
        guard.configure_input(curses.initscr())
        guard.close()
        guard.close()
        self.assertEqual(len(termios.set_calls), 1)
        for call in ("echo", "nocbreak", "endwin", "curs_set:1"):
            self.assertEqual(curses.calls.count(call), 1)
        self.assertEqual(curses.screen.keypad_values, [True, False])
        self.assertEqual(signals.current, signals.original)

    def test_sigint_and_sigterm_restore_before_they_exit(self) -> None:
        for signum, expected in ((FakeSignal.SIGINT, KeyboardInterrupt), (FakeSignal.SIGTERM, SystemExit)):
            with self.subTest(signum=signum):
                curses, termios, signals = FakeCurses(), FakeTermios(), FakeSignal()
                guard = self._guard(curses, termios, signals)
                guard.install()
                guard.begin_screen()
                guard.configure_input(curses.initscr())
                handler = signals.current[signum]
                with self.assertRaises(expected):
                    handler(signum, None)
                self.assertEqual(len(termios.set_calls), 1)
                self.assertEqual(curses.calls.count("endwin"), 1)
                self.assertEqual(signals.current, signals.original)

    def test_startup_failures_restore_all_acquired_resources(self) -> None:
        for phase in ("initscr", "noecho", "cbreak", "curs_set:0"):
            with self.subTest(phase=phase):
                curses, termios, signals = FakeCurses(fail_at=phase), FakeTermios(), FakeSignal()
                guard = self._guard(curses, termios, signals)
                guard.install()
                try:
                    guard.begin_screen()
                    screen = curses.initscr()
                    guard.configure_input(screen)
                except RuntimeError:
                    pass
                finally:
                    guard.close()
                self.assertEqual(len(termios.set_calls), 1)
                self.assertEqual(curses.calls.count("endwin"), 1)
                self.assertEqual(signals.current, signals.original)

    def test_keypad_startup_failure_restores_once(self) -> None:
        curses, termios, signals = FakeCurses(), FakeTermios(), FakeSignal()
        guard = self._guard(curses, termios, signals)

        def fail_keypad(value: bool) -> None:
            if value:
                raise RuntimeError("keypad")

        curses.screen.keypad = fail_keypad  # type: ignore[method-assign]
        guard.install()
        try:
            guard.begin_screen()
            with self.assertRaisesRegex(RuntimeError, "keypad"):
                guard.configure_input(curses.initscr())
        finally:
            guard.close()
        self.assertEqual(len(termios.set_calls), 1)
        self.assertEqual(curses.calls.count("endwin"), 1)


class SessionTests(unittest.TestCase):
    def test_session_uses_bounded_timeout_resize_and_serial_refreshes(self) -> None:
        curses, termios, signals = FakeCurses(), FakeTermios(), FakeSignal()
        guard = backend.TerminalRestorer(
            termios_mod=termios, signal_mod=signals, curses_mod=curses
        )
        calls = 0
        active = False

        def load(run_id: str, previous: wt.WorkflowViewModel | None) -> wt.WorkflowViewModel:
            nonlocal calls, active
            self.assertEqual(run_id, "run-001")
            self.assertFalse(active)
            active = True
            calls += 1
            active = False
            return wt.WorkflowViewModel(
                snapshot=None,
                selected_stage_id=None,
                error=wt.UiError("unavailable", "status delayed"),
            )

        result = backend.run_curses_session(
            "run-001",
            curses_mod=curses,
            restorer=guard,
            loader=load,
            keys=("r", "KEY_RESIZE", "q"),
            max_frames=5,
            refresh_interval=10,
            input_timeout_seconds=0.05,
            now=lambda: datetime(2026, 1, 1, tzinfo=timezone.utc),
        )
        self.assertEqual(result.exit_code, 0)
        self.assertTrue(result.quit_requested)
        self.assertEqual(calls, 2)
        self.assertEqual(curses.screen.timeout_values, [50])
        self.assertGreaterEqual(curses.screen.refresh_calls, 3)
        self.assertEqual(len(termios.set_calls), 1)

    def test_session_restores_when_painting_fails(self) -> None:
        curses, termios, signals = FakeCurses(), FakeTermios(), FakeSignal()
        guard = backend.TerminalRestorer(
            termios_mod=termios, signal_mod=signals, curses_mod=curses
        )

        def fail_paint(*args: object) -> None:
            raise RuntimeError("paint failed")

        curses.screen.addstr = fail_paint  # type: ignore[method-assign]
        with self.assertRaisesRegex(RuntimeError, "paint failed"):
            backend.run_curses_session(
                "run-001",
                curses_mod=curses,
                restorer=guard,
                loader=lambda run_id, previous: wt.WorkflowViewModel(
                    snapshot=None,
                    selected_stage_id=None,
                    error=wt.UiError("unavailable", "status delayed"),
                ),
                    max_frames=1,
            )
        self.assertEqual(len(termios.set_calls), 1)
        self.assertEqual(curses.calls.count("endwin"), 1)
        self.assertEqual(signals.current, signals.original)

    def test_background_refresh_does_not_block_quit_input(self) -> None:
        curses, termios, signals = FakeCurses(), FakeTermios(), FakeSignal()
        guard = backend.TerminalRestorer(
            termios_mod=termios, signal_mod=signals, curses_mod=curses
        )
        refresh_started = threading.Event()
        release_refresh = threading.Event()
        calls = 0

        def load(run_id: str, previous: wt.WorkflowViewModel | None) -> wt.WorkflowViewModel:
            nonlocal calls
            calls += 1
            view = wt.WorkflowViewModel(
                snapshot=None,
                selected_stage_id=None,
                error=wt.UiError("unavailable", "status delayed"),
            )
            if calls > 1:
                refresh_started.set()
                release_refresh.wait(5)
            return view

        try:
            result = backend.run_curses_session(
                "run-001",
                curses_mod=curses,
                restorer=guard,
                loader=load,
                    keys=("r", "q"),
                max_frames=4,
                refresh_interval=10,
                input_timeout_seconds=0.05,
                now=lambda: datetime(2026, 1, 1, tzinfo=timezone.utc),
                background_refresh=True,
            )
            self.assertTrue(result.quit_requested)
            self.assertTrue(refresh_started.wait(1))
        finally:
            release_refresh.set()


class OperatorDialogWiringTests(unittest.TestCase):
    """The dialog subsystem must be reachable from the running viewer.

    workflow_operator_actions was fully built but nothing in the curses loop
    ever constructed a dialog, so approve/answer/cancel were unreachable
    outside tests. These drive the real session loop with injected keys.
    """

    def _session(self, keys, runner):
        curses, termios, signals = FakeCurses(), FakeTermios(), FakeSignal()
        guard = backend.TerminalRestorer(
            termios_mod=termios, signal_mod=signals, curses_mod=curses
        )
        fixture_path = (
            REPO_ROOT / "tests" / "bats" / "workflow" / "fixtures" / "status"
            / "dependency-approval-wait.json"
        )
        snapshot = wt.parse_status_snapshot(json.loads(fixture_path.read_text(encoding="utf-8")))

        def load(run_id, previous):
            return wt.WorkflowViewModel(snapshot=snapshot, selected_stage_id="approve-plan")

        return backend.run_curses_session(
            "fixture-dep-approval",
            curses_mod=curses,
            restorer=guard,
            loader=load,
            keys=keys,
            max_frames=40,
            refresh_interval=10,
            input_timeout_seconds=0.05,
            now=lambda: datetime(2026, 1, 1, tzinfo=timezone.utc),
            action_runner=runner,
        )

    def test_approving_from_the_viewer_dispatches_the_public_command(self) -> None:
        calls: list[tuple[str, ...]] = []

        def runner(argv):
            recorded = tuple(argv)
            calls.append(recorded)
            if "list" in recorded:
                payload = [
                    {
                        "requestId": "approval-fixture-001",
                        "kind": "approval",
                        "runId": "fixture-dep-approval",
                        "stageId": "approve-plan",
                        "attemptId": "approve-plan-1",
                        "question": "Approve the implementation plan?",
                        "choices": ["approve", "request-changes"],
                        "status": "outstanding",
                    }
                ]
                return woa.CommandResult(0, stdout=json.dumps(payload))
            return woa.CommandResult(0)

        # a opens the dialog, Enter asks for confirmation, y submits, q leaves.
        self._session(("a", "\n", "y", "q"), runner)

        respond = [c for c in calls if "respond" in c]
        self.assertEqual(len(respond), 1, f"expected one respond dispatch, got {calls}")
        argv = respond[0]
        self.assertIn("approval-fixture-001", argv)
        self.assertIn("--decision", argv)
        self.assertIn("approve", argv)
        self.assertIn("--yes", argv)

    def test_escape_closes_the_dialog_without_dispatching(self) -> None:
        calls: list[tuple[str, ...]] = []

        def runner(argv):
            recorded = tuple(argv)
            calls.append(recorded)
            if "list" in recorded:
                payload = [
                    {
                        "requestId": "approval-fixture-001",
                        "kind": "approval",
                        "runId": "fixture-dep-approval",
                        "stageId": "approve-plan",
                        "attemptId": "approve-plan-1",
                        "question": "Approve the implementation plan?",
                        "choices": ["approve", "request-changes"],
                        "status": "outstanding",
                    }
                ]
                return woa.CommandResult(0, stdout=json.dumps(payload))
            return woa.CommandResult(0)

        self._session(("a", "\x1b", "q"), runner)
        self.assertEqual([c for c in calls if "respond" in c], [])
