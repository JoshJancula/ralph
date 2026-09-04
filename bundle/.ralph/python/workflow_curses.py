#!/usr/bin/env python3
"""Curses backend for the engine-neutral workflow semantic canvas.

The workflow model, layout, interaction, and log readers deliberately remain
free of terminal I/O.  This module is the only workflow UI module that imports
``curses``, and it does so only after a suitable interactive terminal has been
confirmed.  Its terminal guard records every resource it changes and restores
each one at most once, including on incomplete startup and signal delivery.
"""

from __future__ import annotations

import importlib
import os
import signal as _stdlib_signal
import sys
import threading
import time
from dataclasses import dataclass, replace
from datetime import datetime, timezone
from typing import Any, Callable, Dict, Mapping, Optional, Sequence, Tuple

import workflow_canvas as wc
import workflow_interaction as wi
import workflow_layout as wl
import workflow_logs as wlog
import workflow_tui as wt


DEFAULT_REFRESH_INTERVAL = 1.0
DEFAULT_INPUT_TIMEOUT_SECONDS = 0.20
DEFAULT_WIDTH = 80
DEFAULT_HEIGHT = 24


@dataclass(frozen=True)
class CursesCapabilities:
    available: bool
    reason: Optional[str] = None


@dataclass(frozen=True)
class CursesSessionResult:
    exit_code: int
    frames: int = 0
    quit_requested: bool = False


class _BackgroundViewLoader:
    """Run at most one bounded status refresh without blocking terminal input."""

    def __init__(
        self,
        loader: Callable[[str, Optional[wt.WorkflowViewModel]], wt.WorkflowViewModel],
        run_id: str,
    ) -> None:
        self._loader = loader
        self._run_id = run_id
        self._lock = threading.Lock()
        self._active = False
        self._result: Optional[wt.WorkflowViewModel] = None

    def start(self, previous: wt.WorkflowViewModel) -> bool:
        with self._lock:
            if self._active or self._result is not None:
                return False
            self._active = True

        def load() -> None:
            result = _load_view(self._loader, self._run_id, previous)
            with self._lock:
                self._result = result
                self._active = False

        threading.Thread(
            target=load,
            name="ralph-workflow-status-refresh",
            daemon=True,
        ).start()
        return True

    def take(self) -> Optional[wt.WorkflowViewModel]:
        with self._lock:
            result = self._result
            self._result = None
            return result


def _env_flag(env: Mapping[str, str], name: str) -> bool:
    return str(env.get(name, "")).strip().lower() in {"1", "true", "yes", "on"}


def probe_curses_capabilities(
    *,
    stdin_isatty: Optional[bool] = None,
    stdout_isatty: Optional[bool] = None,
    term: Optional[str] = None,
    environ: Optional[Mapping[str, str]] = None,
    curses_importer: Optional[Callable[[], Any]] = None,
) -> CursesCapabilities:
    """Check terminal suitability before attempting the optional curses import."""

    env = dict(os.environ if environ is None else environ)
    if _env_flag(env, "CI") or _env_flag(env, "RALPH_WORKFLOW_NO_COLOR"):
        return CursesCapabilities(False, "plain")
    if _env_flag(env, "RALPH_GRAPH_PLAIN") or _env_flag(env, "RALPH_GRAPH_NO_TUI"):
        return CursesCapabilities(False, "plain")
    if _env_flag(env, "RALPH_GRAPH_SCREEN_READER") or _env_flag(env, "ACCESSIBILITY_SCREEN_READER"):
        return CursesCapabilities(False, "screen-reader")
    term_value = term if term is not None else env.get("TERM", "")
    if not term_value or term_value == "dumb":
        return CursesCapabilities(False, "term")
    in_tty = sys.stdin.isatty() if stdin_isatty is None else bool(stdin_isatty)
    out_tty = sys.stdout.isatty() if stdout_isatty is None else bool(stdout_isatty)
    if not in_tty or not out_tty:
        return CursesCapabilities(False, "tty")
    try:
        (curses_importer or _load_curses)()
    except Exception:
        return CursesCapabilities(False, "curses")
    return CursesCapabilities(True)


class TerminalRestorer:
    """Own terminal resources and restore each acquired resource once."""

    def __init__(
        self,
        *,
        fd: int = 0,
        termios_mod: Any = None,
        signal_mod: Any = None,
        curses_mod: Any = None,
        raise_on_sigint: bool = True,
    ) -> None:
        self.fd = fd
        self._termios = termios_mod
        self._signal = signal_mod
        self._curses = curses_mod
        self._raise_on_sigint = raise_on_sigint
        self._saved_termios: Any = None
        self._saved_handlers: Dict[int, Any] = {}
        self._stdscr: Any = None
        self._installed = False
        self._handlers_restored = False
        self._termios_restored = False
        self._screen_started = False
        self._screen_restored = False
        self._echo_changed = False
        self._mode_changed: Optional[str] = None
        self._keypad_enabled = False
        self._cursor_changed = False
        self._cursor_previous: Optional[int] = None

    def install(self) -> None:
        if self._installed:
            return
        if self._termios is None:
            self._termios = _load_termios()
        if self._signal is None:
            self._signal = _load_signal()
        if self._termios is not None:
            try:
                self._saved_termios = self._termios.tcgetattr(self.fd)
            except Exception:
                self._saved_termios = None
        if self._signal is not None:
            for signum in _lifecycle_signals(self._signal):
                try:
                    self._saved_handlers[signum] = self._signal.signal(signum, self._handle_signal)
                except Exception:
                    continue
        self._installed = True

    def begin_screen(self) -> None:
        """Mark curses as acquired before startup, covering partial startup failures."""

        self._screen_started = True
        self._screen_restored = False

    def configure_input(self, stdscr: Any, *, raw: bool = False) -> None:
        """Enable one-key input and record exactly which resources changed."""

        self._stdscr = stdscr
        curses = self._curses
        if curses is None:
            return
        self._echo_changed = True
        curses.noecho()
        self._mode_changed = "raw" if raw else "cbreak"
        (curses.raw if raw else curses.cbreak)()
        self._keypad_enabled = True
        stdscr.keypad(True)
        self._cursor_changed = True
        previous = curses.curs_set(0)
        if isinstance(previous, int):
            self._cursor_previous = previous

    def restore(self) -> None:
        """Restore curses, input, and termios resources without duplicate calls."""

        curses = self._curses
        if curses is not None:
            if self._cursor_changed:
                self._cursor_changed = False
                try:
                    curses.curs_set(1 if self._cursor_previous is None else self._cursor_previous)
                except Exception:
                    pass
            if self._keypad_enabled:
                self._keypad_enabled = False
                try:
                    self._stdscr.keypad(False)
                except Exception:
                    pass
            if self._mode_changed == "raw":
                self._mode_changed = None
                try:
                    curses.noraw()
                except Exception:
                    pass
            elif self._mode_changed == "cbreak":
                self._mode_changed = None
                try:
                    curses.nocbreak()
                except Exception:
                    pass
            if self._echo_changed:
                self._echo_changed = False
                try:
                    curses.echo()
                except Exception:
                    pass
            if self._screen_started and not self._screen_restored:
                self._screen_restored = True
                try:
                    curses.endwin()
                except Exception:
                    pass
        if not self._termios_restored:
            self._termios_restored = True
            if self._saved_termios is not None and self._termios is not None:
                try:
                    self._termios.tcsetattr(
                        self.fd, getattr(self._termios, "TCSANOW", 0), self._saved_termios
                    )
                except Exception:
                    pass

    def close(self) -> None:
        self.restore()
        self._restore_handlers()
        self._installed = False

    def __enter__(self) -> "TerminalRestorer":
        self.install()
        return self

    def __exit__(self, exc_type: object, exc: object, tb: object) -> None:
        self.close()

    def _handle_signal(self, signum: int, frame: object) -> None:
        self.close()
        sigint = getattr(self._signal, "SIGINT", None) if self._signal is not None else None
        if self._raise_on_sigint and signum == sigint:
            raise KeyboardInterrupt
        raise SystemExit(128 + int(signum))

    def _restore_handlers(self) -> None:
        if self._handlers_restored:
            return
        self._handlers_restored = True
        if self._signal is not None:
            for signum, previous in list(self._saved_handlers.items()):
                try:
                    self._signal.signal(signum, previous)
                except Exception:
                    pass
        self._saved_handlers.clear()


def init_palette(curses: Any) -> Mapping[str, int]:
    """Return semantic attributes, falling back safely on monochrome terminals."""

    normal = int(getattr(curses, "A_NORMAL", 0))
    bold = int(getattr(curses, "A_BOLD", 0))
    dim = int(getattr(curses, "A_DIM", 0))
    reverse = int(getattr(curses, "A_REVERSE", 0))
    colors = {"accent": 0, "success": 0, "warning": 0, "failure": 0}
    try:
        if bool(curses.has_colors()):
            curses.start_color()
            background = -1
            try:
                curses.use_default_colors()
            except Exception:
                background = getattr(curses, "COLOR_BLACK", 0)
            for role, pair, foreground in (
                ("accent", 1, getattr(curses, "COLOR_CYAN", 6)),
                ("success", 2, getattr(curses, "COLOR_GREEN", 2)),
                ("warning", 3, getattr(curses, "COLOR_YELLOW", 3)),
                ("failure", 4, getattr(curses, "COLOR_RED", 1)),
            ):
                curses.init_pair(pair, foreground, background)
                colors[role] = int(curses.color_pair(pair))
    except Exception:
        colors = {"accent": 0, "success": 0, "warning": 0, "failure": 0}
    return {
        "default": normal,
        "heading": bold | colors["accent"],
        "accent": colors["accent"],
        "success": colors["success"],
        "warning": bold | colors["warning"],
        "failure": bold | colors["failure"],
        "muted": dim,
        "path": dim,
        "command": bold,
        "focus": reverse | bold,
    }


def role_attr(role: str, palette: Mapping[str, int]) -> int:
    return int(palette.get(role, palette.get("default", 0)))


def paint_canvas(
    stdscr: Any,
    canvas: wc.Canvas,
    *,
    curses: Any,
    palette: Mapping[str, int],
    previous: Optional[wc.Canvas] = None,
) -> wc.Canvas:
    """Paint only cells whose text or role changed, then commit one refresh."""

    prior_width = previous.width if previous is not None else 0
    prior_height = previous.height if previous is not None else 0
    if previous is None or (prior_width, prior_height) != (canvas.width, canvas.height):
        _safe_call(stdscr, "erase")
        previous = None
    max_height = max(canvas.height, prior_height)
    max_width = max(canvas.width, prior_width)
    for y in range(max_height):
        for x in range(max_width):
            new = canvas.cell(x, y)
            old = previous.cell(x, y) if previous is not None else None
            if new == old:
                continue
            if new is None:
                _paint_cell(stdscr, y, x, " ", role_attr("default", palette), curses)
            elif not new.continuation:
                _paint_cell(
                    stdscr, y, x, new.text or " ", role_attr(new.role, palette), curses
                )
    _safe_call(stdscr, "refresh")
    return canvas


def render_canvas(
    state: wi.WorkflowUiState,
    *,
    width: int,
    height: int,
    log_pane: Optional[wlog.WorkflowLogPane] = None,
    now: Optional[datetime] = None,
    ascii_only: bool = False,
    dialog: Optional[object] = None,
) -> wc.Canvas:
    """Compose a semantic frame, reserving a visible contextual footer."""

    frame_height = max(0, int(height))
    body_height = max(0, frame_height - 1)
    visible = wi.visible_stage_ids(state) if (state.filter_query or state.filter_editing) else None
    if dialog is not None:
        canvas = _render_dialog_canvas(dialog, max(0, int(width)), body_height, ascii_only=ascii_only)
    elif state.focus == wi.FOCUS_COMMANDS:
        all_commands = wi.workflow_command_lines(state)
        visible_commands = wi.visible_command_lines(state)
        start = min(state.command_offset, max(0, len(all_commands) - 1)) + 1
        end = min(len(all_commands), start + len(visible_commands) - 1)
        title = f"Stage links {start}-{end}/{len(all_commands)}"
        canvas = wl.render_modal_frame(
            title=title,
            body=tuple((wc.StyledText(command, "command"),) for command in visible_commands),
            width=max(0, int(width)),
            height=body_height,
            ascii_only=ascii_only,
        )
    else:
        inspection_lines = (
            ()
            if (
                state.filter_editing
                or state.focus != wi.FOCUS_STAGES
                or state.log_state.focused
                or (
                    state.details_view
                    and wl.layout_tier(max(0, int(width)), frame_height) == "compact"
                )
            )
            else _primary_inspection_lines(
                state, max(0, int(width)), max(0, int(height))
            )
        )
        canvas = wl.render_primary_frame(
            state.view,
            max(0, int(width)),
            body_height,
            now=now,
            ascii_only=ascii_only,
            details_view=state.details_view,
            log_pane=log_pane,
            log_focused=state.log_state.focused,
            visible_stage_ids=visible,
            filter_query=state.filter_query,
            filter_editing=state.filter_editing,
            inspection_lines=inspection_lines,
            tier_width=max(0, int(width)),
            tier_height=frame_height,
        )
    if frame_height == body_height:
        return canvas
    footer_canvas = wc.Canvas(max(0, int(width)), frame_height)
    for y, row in enumerate(canvas.cells):
        for x, cell in enumerate(row):
            if not cell.continuation:
                footer_canvas.write(x, y, cell.text, role=cell.role)
    message = _footer_text(state, dialog=dialog)
    role = "warning" if state.view.error is not None else "muted"
    footer_canvas.draw_text(0, frame_height - 1, footer_canvas.width, message, role=role)
    return footer_canvas


def _primary_inspection_lines(
    state: wi.WorkflowUiState, width: int, height: int
) -> Tuple[Tuple[wc.StyledText, ...], ...]:
    """Persistent, explained inspection commands for the normal viewer frame."""

    commands = wi.workflow_command_lines(state)
    if state.view.run is None or len(commands) < 8:
        return ()

    def row(label: str, help_text: str, command: str) -> Tuple[wc.StyledText, ...]:
        return (
            wc.StyledText(f"{label}  ", "accent"),
            wc.StyledText(f"{help_text}  ", "muted"),
            wc.StyledText(command, "command"),
        )

    status = commands[3]
    watch = commands[7]
    status_watch = (
        wc.StyledText("Status  ", "accent"),
        wc.StyledText("one-shot summary  ", "muted"),
        wc.StyledText(status, "command"),
        wc.StyledText("    Reattach  ", "accent"),
        wc.StyledText(watch, "command"),
    )
    # A narrow terminal cannot physically hold both commands on one row. Keep
    # both exact by splitting them; the layout will use the available rows.
    if sum(span.width for span in status_watch) > width:
        status_rows: Tuple[Tuple[wc.StyledText, ...], ...] = (
            row("Status", "one-shot summary", status),
            row("Reattach", "open this viewer later", watch),
        )
    else:
        status_rows = (status_watch,)

    snapshot = state.view.snapshot
    has_request = bool(
        snapshot
        and (
            snapshot.diagnosis.request_kind in {"approval", "input", "permission"}
            or any(
                stage.request_id
                or stage.blocker_kind in {"approval", "input", "permission"}
                for stage in snapshot.stages
            )
        )
    )
    live_row = row("Live logs", "agent + supervisor; follows", commands[0])
    agent_row = row("Agent logs", "runtime output only; follows", commands[1])
    request_row = row("Requests", "approval, input, and permission", commands[5])
    artifact_row = row("Artifacts", "files produced by every stage", commands[6])
    handoff_row = row("Handoff", "task, code location, and retry", commands[8])
    if wl.layout_tier(width, height) != "compact":
        extra_rows = (
            (handoff_row,)
            if snapshot
            and wl.effective_outcome_state(snapshot.run.state, snapshot.diagnosis.state) == "failed"
            else ()
        )
        return status_rows + (live_row, agent_row, request_row, artifact_row) + extra_rows

    stage = state.view.selected_stage
    if stage is None:
        inspect_row = (
            wc.StyledText("Inspect  ", "accent"),
            wc.StyledText("no stage selected  ", "muted"),
            wc.StyledText("Up/Down or j/k selects a stage  c all stage links", "command"),
        )
    else:
        inspect_row = (
            wc.StyledText("Inspect  ", "accent"),
            wc.StyledText(
                f"> {stage.id} ({wl.stage_inspection_state_label(state.view, stage)})",
                "focus",
            ),
            wc.StyledText("  Up/Down or j/k selects a different stage  ", "muted"),
            wc.StyledText("d details  l logs  c all stage links", "command"),
        )
    return (inspect_row,)


def _render_dialog_canvas(dialog: object, width: int, height: int, *, ascii_only: bool) -> wc.Canvas:
    import workflow_operator_actions as woa

    if not isinstance(dialog, woa.WorkflowDialog):
        raise TypeError("dialog must be a WorkflowDialog")
    return woa.render_dialog_frame(dialog, width, height, ascii_only=ascii_only)


def run_curses_session(
    run_id: str,
    *,
    curses_mod: Any = None,
    restorer: Optional[TerminalRestorer] = None,
    loader: Optional[Callable[[str, Optional[wt.WorkflowViewModel]], wt.WorkflowViewModel]] = None,
    log_reader: Optional[
        Callable[
            [wt.WorkflowViewModel, wlog.WorkflowLogState, Optional[wlog.WorkflowLogPane]],
            Tuple[wlog.WorkflowLogPane, wlog.WorkflowLogState],
        ]
    ] = None,
    command: Sequence[str] = ("ralph",),
    refresh_interval: float = DEFAULT_REFRESH_INTERVAL,
    input_timeout_seconds: float = DEFAULT_INPUT_TIMEOUT_SECONDS,
    clock: Callable[[], float] = time.monotonic,
    now: Callable[[], datetime] = lambda: datetime.now(timezone.utc),
    keys: Optional[Sequence[object]] = None,
    max_frames: Optional[int] = None,
    should_stop: Optional[Callable[[wt.WorkflowViewModel], bool]] = None,
    action_runner: Optional[Callable[[Sequence[str]], object]] = None,
    background_refresh: Optional[bool] = None,
) -> CursesSessionResult:
    """Run the alternate-screen viewer with serialized bounded status refreshes."""

    curses = curses_mod if curses_mod is not None else _load_curses()
    guard = restorer or TerminalRestorer(curses_mod=curses)
    if getattr(guard, "_curses", None) is None:
        guard._curses = curses
    fetch = loader or (
        lambda identifier, previous: wt.load_workflow_view(identifier, previous=previous, command=command)
    )
    if background_refresh is None:
        background_refresh = loader is None
    read_logs = log_reader or _default_log_reader(command)
    key_iter = iter(keys or ())
    refresh_interval = max(0.05, float(refresh_interval))
    input_timeout_ms = max(1, int(max(0.01, float(input_timeout_seconds)) * 1000))
    frames = 0
    previous_canvas: Optional[wc.Canvas] = None
    log_pane: Optional[wlog.WorkflowLogPane] = None
    # Operator-action modal state. Loaded lazily: the actions list costs a
    # public CLI call, so it is only fetched when the operator opens a dialog.
    dialog: Optional[object] = None
    actions: Optional[object] = None

    guard.install()
    try:
        guard.begin_screen()
        stdscr = curses.initscr()
        guard.configure_input(stdscr)
        _safe_call(stdscr, "timeout", input_timeout_ms)
        palette = init_palette(curses)
        view = _load_view(fetch, run_id, None)
        state = wi.initial_ui_state(view, width=_screen_width(stdscr), height=_screen_height(stdscr))
        refresh_loader = _BackgroundViewLoader(fetch, run_id) if background_refresh else None
        next_refresh = clock() + refresh_interval
        while True:
            width, height = _screen_width(stdscr), _screen_height(stdscr)
            if (width, height) != (state.width, state.height):
                state = wi.apply_resize(state, width, height)

            loaded = refresh_loader.take() if refresh_loader is not None else None
            if loaded is not None:
                if loaded.snapshot is not None:
                    state = wi.apply_refresh(state, loaded.snapshot)
                elif loaded.error is not None:
                    state = wi.apply_error(state, loaded.error)
                else:
                    state = replace(state, view=loaded, refresh_requested=False)
                next_refresh = clock() + refresh_interval
                if state.log_state.focused or log_pane is None:
                    log_pane, next_log_state = read_logs(state.view, state.log_state, log_pane)
                    state = replace(state, log_state=next_log_state)

            refresh_due = state.refresh_requested or clock() >= next_refresh
            if refresh_due:
                if refresh_loader is not None:
                    refresh_loader.start(state.view)
                else:
                    loaded = _load_view(fetch, run_id, state.view)
                    if loaded.snapshot is not None:
                        state = wi.apply_refresh(state, loaded.snapshot)
                    elif loaded.error is not None:
                        state = wi.apply_error(state, loaded.error)
                    else:
                        state = replace(state, view=loaded, refresh_requested=False)
                    next_refresh = clock() + refresh_interval
                    if state.log_state.focused or log_pane is None:
                        log_pane, next_log_state = read_logs(state.view, state.log_state, log_pane)
                        state = replace(state, log_state=next_log_state)

            canvas = render_canvas(
                state,
                width=state.width,
                height=state.height,
                log_pane=log_pane,
                now=now(),
                dialog=dialog,
            )
            previous_canvas = paint_canvas(
                stdscr, canvas, curses=curses, palette=palette, previous=previous_canvas
            )
            frames += 1
            if state.quit_requested:
                return CursesSessionResult(exit_code=130 if state.detach_reason == wi.DETACH_INTERRUPT else 0,
                                           frames=frames, quit_requested=True)
            if should_stop is not None and should_stop(state.view):
                return CursesSessionResult(exit_code=0, frames=frames)
            if max_frames is not None and frames >= max_frames:
                return CursesSessionResult(exit_code=0, frames=frames)
            try:
                key = next(key_iter)
            except StopIteration:
                try:
                    key = stdscr.getch()
                except Exception:
                    key = -1
            if key != -1 and key is not None:
                if wi.resolve_action(key) == "resize":
                    state = wi.apply_resize(state, _screen_width(stdscr), _screen_height(stdscr))
                elif dialog is not None:
                    dialog, actions, state = _handle_dialog_key(
                        dialog, actions, state, key, command=command, runner=action_runner
                    )
                elif _is_open_dialog_key(key) and _dialog_target(state) is not None:
                    dialog, actions = _open_dialog(state, command=command, runner=action_runner)
                else:
                    state = wi.apply_key(state, key)
    except KeyboardInterrupt:
        return CursesSessionResult(exit_code=130, frames=frames, quit_requested=True)
    finally:
        guard.close()


# --- operator action dialog plumbing ---------------------------------------
#
# The dialog itself (validation, confirmation, command construction, dispatch)
# lives in workflow_operator_actions. These helpers only connect it to the
# curses loop: which key opens it, which stage it targets, and where its
# refresh request lands.

def _operator_actions_module() -> Any:
    import workflow_operator_actions as woa

    return woa


def _is_open_dialog_key(key: object) -> bool:
    return wi.resolve_action(key) == "respond"


def _dialog_target(state: wi.WorkflowUiState) -> Optional[str]:
    """Request id the selected stage is waiting on, if any."""

    if state.focus == wi.FOCUS_LOG or state.filter_editing:
        return None
    return _operator_actions_module().outstanding_request_id(state.view)


def _open_dialog(
    state: wi.WorkflowUiState,
    *,
    command: Sequence[str],
    runner: Optional[Callable[[Sequence[str]], object]] = None,
) -> Tuple[Optional[object], Optional[object]]:
    """Load outstanding actions and open a decision dialog for the selection."""

    woa = _operator_actions_module()
    snapshot = state.view.snapshot
    request_id = _dialog_target(state)
    if snapshot is None or request_id is None:
        return None, None
    actions = woa.load_action_records(snapshot, runner=runner, command=command)
    return woa.open_decision_dialog(snapshot, actions, request_id), actions


def _handle_dialog_key(
    dialog: object,
    actions: object,
    state: wi.WorkflowUiState,
    key: object,
    *,
    command: Sequence[str],
    runner: Optional[Callable[[Sequence[str]], object]] = None,
) -> Tuple[Optional[object], Optional[object], wi.WorkflowUiState]:
    """Feed one key to the open dialog and apply whatever it asks for."""

    woa = _operator_actions_module()
    next_dialog, intent = woa.apply_dialog_key(dialog, key)
    if intent == woa.DIALOG_CLOSE:
        return None, None, state
    if intent != woa.DIALOG_SUBMIT:
        return next_dialog, actions, state

    snapshot = state.view.snapshot
    if snapshot is None:
        return None, None, state
    submitted = woa.dispatch_dialog(
        snapshot, actions, next_dialog, confirmed=True, runner=runner, command=command
    )
    if getattr(submitted, "error", None):
        # Keep the modal open so the operator can read why it was refused.
        return submitted, actions, state
    # Success: close and pull a fresh snapshot so the stage's new state shows.
    return None, None, replace(state, refresh_requested=True)


def _default_log_reader(
    command: Sequence[str],
) -> Callable[
    [wt.WorkflowViewModel, wlog.WorkflowLogState, Optional[wlog.WorkflowLogPane]],
    Tuple[wlog.WorkflowLogPane, wlog.WorkflowLogState],
]:
    def read(
        view: wt.WorkflowViewModel,
        state: wlog.WorkflowLogState,
        previous: Optional[wlog.WorkflowLogPane],
    ) -> Tuple[wlog.WorkflowLogPane, wlog.WorkflowLogState]:
        return wlog.read_log_pane(view, state, previous_pane=previous, command=command)

    return read


def _load_view(
    loader: Callable[[str, Optional[wt.WorkflowViewModel]], wt.WorkflowViewModel],
    run_id: str,
    previous: Optional[wt.WorkflowViewModel],
) -> wt.WorkflowViewModel:
    try:
        return loader(run_id, previous)
    except Exception as exc:
        prior = previous if previous is not None else wt.WorkflowViewModel(None, None)
        return replace(prior, error=wt.UiError("unavailable", "Workflow status is unavailable.", str(exc)[:240]))


def _footer_text(state: wi.WorkflowUiState, *, dialog: Optional[object] = None) -> str:
    prefix = ""
    if state.view.error is not None:
        prefix = f"STALE: {state.view.error.message} | "
    if dialog is not None:
        import workflow_operator_actions as woa

        if isinstance(dialog, woa.WorkflowDialog):
            if dialog.confirming:
                return prefix + "y confirm  n cancel  Esc back"
            if dialog.error:
                return prefix + f"error: {dialog.error}  Esc close"
            return prefix + "j/k choice  Enter confirm  Esc cancel"
    if state.filter_editing:
        query = state.filter_query
        return prefix + f"Filter: {query}_  type filter  Enter apply  Esc cancel  Backspace delete"
    actions = "  ".join(f"{action.key} {action.label}" for action in wi.contextual_footer(state))
    return prefix + actions


def _paint_cell(stdscr: Any, y: int, x: int, text: str, attr: int, curses: Any) -> None:
    try:
        stdscr.addstr(y, x, text, attr)
    except Exception as exc:
        # The lower-right cell often raises after drawing on common curses
        # implementations.  A clipped semantic canvas must not take down the
        # viewer for that cosmetic limitation.
        expected = getattr(curses, "error", ())
        if expected and isinstance(exc, expected):
            return
        raise


def _safe_call(target: Any, name: str, *args: object) -> None:
    method = getattr(target, name, None)
    if callable(method):
        try:
            method(*args)
        except Exception:
            pass


def _screen_width(stdscr: Any) -> int:
    try:
        _height, width = stdscr.getmaxyx()
        return max(0, int(width))
    except Exception:
        return DEFAULT_WIDTH


def _screen_height(stdscr: Any) -> int:
    try:
        height, _width = stdscr.getmaxyx()
        return max(0, int(height))
    except Exception:
        return DEFAULT_HEIGHT


def _load_curses() -> Any:
    return importlib.import_module("curses")


def _load_termios() -> Any:
    try:
        return importlib.import_module("termios")
    except Exception:
        return None


def _load_signal() -> Any:
    return _stdlib_signal


def _lifecycle_signals(signal_mod: Any) -> Tuple[int, ...]:
    values = []
    for name in ("SIGINT", "SIGTERM"):
        value = getattr(signal_mod, name, None)
        if isinstance(value, int):
            values.append(value)
    return tuple(values)
