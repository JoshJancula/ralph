#!/usr/bin/env python3
"""Pure keyboard-interaction state machine for the workflow terminal UI.

This module owns stage selection/navigation, incremental stage filtering,
the details toggle, the stage-links overlay, the contextual ``?`` help
overlay, refresh reconciliation, and ``q``/Ctrl-C detach for
``ralph workflow watch``. It is deliberately backend-neutral: it never
imports ``curses`` and never reaches into a Sequential or Dependency engine
tree. It only depends on the public read model (``workflow_tui``).

The viewer never streams log content itself. Log output is reached through
the exact ``ralph workflow logs ... --follow`` commands this module builds,
so stage navigation stays instant instead of blocking on a CLI call per
selection change.

All public functions are pure: given the same inputs they return the same
output and never mutate their arguments. The curses backend (a later TODO)
is responsible for translating real key presses into the key tokens this
module understands and for painting the footer this module describes.
"""

from __future__ import annotations

import shlex
from dataclasses import dataclass, replace
from typing import Optional, Sequence, Tuple

import workflow_tui as wt


FOCUS_STAGES = "stages"
FOCUS_HELP = "help"
FOCUS_COMMANDS = "commands"

DETACH_QUIT = "quit"
DETACH_INTERRUPT = "interrupt"

DEFAULT_PAGE_SIZE = 10

# Curses assigns integer codes to non-printable navigation keys. Listing the
# literal integers here does not require importing curses.
_CURSES_KEY_CODES = {
    258: "down",
    259: "up",
    338: "page-down",
    339: "page-up",
    262: "home",
    360: "end",
    263: "backspace",
    343: "enter",
    27: "escape",
    410: "resize",
}

_KEY_ACTIONS = {
    "a": "respond",
    "j": "down",
    "KEY_DOWN": "down",
    "down": "down",
    "k": "up",
    "KEY_UP": "up",
    "up": "up",
    "KEY_NPAGE": "page-down",
    "page-down": "page-down",
    "pagedown": "page-down",
    "KEY_PPAGE": "page-up",
    "page-up": "page-up",
    "pageup": "page-up",
    "KEY_HOME": "home",
    "home": "home",
    "g": "home",
    "KEY_END": "end",
    "end": "end",
    "G": "end",
    "/": "filter-start",
    "?": "help-toggle",
    "c": "commands-toggle",
    "C": "commands-toggle",
    "d": "details-toggle",
    "D": "details-toggle",
    "r": "refresh",
    "R": "refresh",
    "l": "commands-toggle",
    "L": "commands-toggle",
    "q": "quit",
    "Q": "quit",
    "\x1b": "escape",
    "esc": "escape",
    "escape": "escape",
    "KEY_EXIT": "escape",
    "\n": "enter",
    "\r": "enter",
    "enter": "enter",
    "KEY_ENTER": "enter",
    "\x7f": "backspace",
    "\b": "backspace",
    "KEY_BACKSPACE": "backspace",
    "backspace": "backspace",
    "\x03": "interrupt",
    "KEY_RESIZE": "resize",
    "resize": "resize",
}

_NAV_ACTIONS = frozenset({"down", "up", "page-down", "page-up", "home", "end"})


@dataclass(frozen=True)
class WorkflowUiState:
    """Pure, serializable interaction state for one attached run.

    ``view`` carries the reconciled read-model selection. Everything else in
    this dataclass is interaction-only state that ``workflow_tui`` does not
    know about.
    """

    view: wt.WorkflowViewModel
    focus: str = FOCUS_STAGES
    previous_focus: str = FOCUS_STAGES
    filter_query: str = ""
    filter_editing: bool = False
    filter_backup: str = ""
    details_view: bool = False
    page_size: int = DEFAULT_PAGE_SIZE
    width: int = 80
    height: int = 24
    selection_touched: bool = False
    command_offset: int = 0
    refresh_requested: bool = False
    quit_requested: bool = False
    detach_reason: Optional[str] = None


@dataclass(frozen=True)
class FooterAction:
    """One contextual footer entry. ``key`` is the label shown, e.g. ``"j/k"``."""

    key: str
    label: str


def initial_ui_state(
    view: wt.WorkflowViewModel,
    *,
    width: int = 80,
    height: int = 24,
    page_size: int = DEFAULT_PAGE_SIZE,
) -> WorkflowUiState:
    """Build the starting interaction state for a freshly loaded view."""

    return WorkflowUiState(
        view=view,
        width=max(0, int(width)),
        height=max(0, int(height)),
        page_size=max(1, int(page_size)),
    )


def _stage_matches_filter(stage: wt.Stage, query: str) -> bool:
    if not query:
        return True
    needle = query.casefold()
    fields = (stage.id, stage.kind, stage.state)
    return any(needle in field.casefold() for field in fields if field)


def filtered_stage_ids(view: wt.WorkflowViewModel, query: str) -> Tuple[str, ...]:
    """Return stage ids in display order that match the incremental filter."""

    stages = (
        wt.revealed_progress_stages(view.snapshot)
        if view.snapshot is not None
        else view.stages
    )
    return tuple(stage.id for stage in stages if _stage_matches_filter(stage, query))


def visible_stage_ids(state: WorkflowUiState) -> Tuple[str, ...]:
    return filtered_stage_ids(state.view, state.filter_query)


def _with_selection(state: WorkflowUiState, stage_id: Optional[str]) -> WorkflowUiState:
    if state.view.selected_stage_id == stage_id:
        return state
    next_view = replace(state.view, selected_stage_id=stage_id)
    return replace(state, view=next_view)


def _reconcile_filtered_selection(state: WorkflowUiState) -> WorkflowUiState:
    """Clamp the selection into the current filtered set. Pure, idempotent."""

    visible = visible_stage_ids(state)
    if not visible:
        return _with_selection(state, None)
    if state.view.selected_stage_id in visible:
        return state
    return _with_selection(state, visible[0])


def _move_selection(state: WorkflowUiState, delta: int) -> WorkflowUiState:
    visible = visible_stage_ids(state)
    if not visible:
        return replace(_with_selection(state, None), selection_touched=True)
    current = state.view.selected_stage_id
    if current in visible:
        index = visible.index(current)
    else:
        index = 0 if delta >= 0 else len(visible) - 1
        return replace(_with_selection(state, visible[index]), selection_touched=True)
    next_index = min(max(index + delta, 0), len(visible) - 1)
    return replace(_with_selection(state, visible[next_index]), selection_touched=True)


def _jump_selection(state: WorkflowUiState, *, to_end: bool) -> WorkflowUiState:
    visible = visible_stage_ids(state)
    if not visible:
        return replace(_with_selection(state, None), selection_touched=True)
    return replace(
        _with_selection(state, visible[-1] if to_end else visible[0]),
        selection_touched=True,
    )


def _key_text(key: object) -> Optional[str]:
    if isinstance(key, str):
        return key
    if isinstance(key, bytes):
        try:
            return key.decode("utf-8")
        except UnicodeDecodeError:
            return None
    return None


def resolve_action(key: object) -> Optional[str]:
    """Map one raw key token (str, bytes, or curses int code) to an action name."""

    if isinstance(key, int) and not isinstance(key, bool):
        return _CURSES_KEY_CODES.get(key)
    text = _key_text(key)
    if not text:
        return None
    if text in _KEY_ACTIONS:
        return _KEY_ACTIONS[text]
    if len(text) == 1 and text.isalpha():
        return _KEY_ACTIONS.get(text.lower())
    return None


def _is_filter_char(key: object) -> bool:
    text = _key_text(key)
    return bool(text) and len(text) == 1 and text.isprintable() and text not in {"\n", "\r", "\x1b"}


def has_log_target(state: WorkflowUiState) -> bool:
    """True when a stage is selected, so its live-tail commands are offerable."""

    return state.view.selected_stage is not None


def produced_artifacts(stage: wt.Stage) -> Tuple[str, ...]:
    """Artifact paths attributable to a stage that actually ran.

    Frozen workflow projections may carry a declared path onto a queued or
    skipped rework clone even when another branch produced the file. Treating
    that shared path as output from the dormant stage is misleading.
    """

    if stage.state in {"queued", "skipped"}:
        return ()
    return tuple(path for path in stage.artifacts if path)


def selected_stage_has_request(state: WorkflowUiState) -> bool:
    """True when the selected stage is waiting on an operator decision.

    Gates the "a" binding so the footer only offers responding when there is
    something to respond to, the same rule the rest of contextual_footer keeps.
    """

    stage = state.view.selected_stage
    return stage is not None and bool(getattr(stage, "request_id", None))


def _apply_filter_editing_key(state: WorkflowUiState, key: object) -> WorkflowUiState:
    action = resolve_action(key)
    if action == "enter":
        return _reconcile_filtered_selection(replace(state, filter_editing=False, filter_backup=""))
    if action == "escape":
        reverted = replace(
            state,
            filter_editing=False,
            filter_query=state.filter_backup,
            filter_backup="",
        )
        return _reconcile_filtered_selection(reverted)
    if action == "backspace":
        return _reconcile_filtered_selection(replace(state, filter_query=state.filter_query[:-1]))
    if _is_filter_char(key):
        appended = replace(state, filter_query=state.filter_query + str(_key_text(key)))
        return _reconcile_filtered_selection(appended)
    return state


def _apply_help_focus_key(state: WorkflowUiState, key: object) -> WorkflowUiState:
    action = resolve_action(key)
    if action == "quit":
        return replace(state, quit_requested=True, detach_reason=DETACH_QUIT)
    if action == "interrupt":
        return replace(state, quit_requested=True, detach_reason=DETACH_INTERRUPT)
    if action in ("escape", "help-toggle"):
        return replace(state, focus=state.previous_focus)
    if action == "resize":
        return state
    return state


def workflow_command_lines(state: WorkflowUiState) -> Tuple[str, ...]:
    """Exact public commands for the run, selected stage, and every stage link."""

    run = state.view.run
    if run is None:
        return ("Workflow status is unavailable; refresh with r.",)

    run_id = shlex.quote(run.run_id)
    stage = state.view.selected_stage
    stage_args = ""
    stage_filter = ".stages[]"
    if stage is not None:
        stage_id = shlex.quote(stage.id)
        stage_args = f" --stage {stage_id}"
        if stage.attempt > 0:
            stage_args += f" --attempt {stage.attempt}"
        stage_filter = f'.stages[] | select(.id=="{stage.id}")'

    lines = [
        f"ralph workflow logs {run_id}{stage_args} --stream combined --tail 200 --follow",
        f"ralph workflow logs {run_id}{stage_args} --stream agent --tail 200 --follow",
        f"ralph workflow logs {run_id}{stage_args} --stream supervisor --tail 200 --no-follow",
        f"ralph workflow status {run_id}",
        f"ralph workflow status {run_id} --json | jq '{stage_filter}'",
        f"ralph workflow actions list {run_id}",
        f"ralph workflow status {run_id} --json | jq -r '.stages[] | .artifacts[]?'",
        f"ralph workflow watch {run_id}",
        f"ralph workflow handoff {run_id}",
    ]
    if stage is not None:
        lines.extend(f"less {shlex.quote(path)}" for path in produced_artifacts(stage))
    lines.append(f"ralph usage --run {run_id}")
    lines.append("# All stage logs and artifacts")
    catalog_stages = (
        wt.revealed_progress_stages(state.view.snapshot)
        if state.view.snapshot is not None
        else state.view.stages
    )
    for item in catalog_stages:
        item_id = shlex.quote(item.id)
        item_args = f" --stage {item_id}"
        if item.attempt > 0:
            item_args += f" --attempt {item.attempt}"
        lines.append(f"# {item.id} ({item.state})")
        if item.workspace_path:
            availability = "available" if item.workspace_available else "not available"
            lines.append(f"# workspace {item.workspace_mode or 'unknown'} ({availability})")
            if item.workspace_available:
                lines.append(f"cd {shlex.quote(item.workspace_path)}")
        if item.changeset_manifest:
            lines.append(f"less {shlex.quote(item.changeset_manifest)}")
        lines.append(
            f"ralph workflow logs {run_id}{item_args} "
            "--stream combined --tail 200 --follow"
        )
        item_artifacts = produced_artifacts(item)
        lines.extend(f"less {shlex.quote(path)}" for path in item_artifacts)
        if not item_artifacts:
            lines.append("# no artifacts produced")
    return tuple(lines)


COMMAND_WRAP_INDENT = "    "


def command_page_size(state: WorkflowUiState) -> int:
    """Rows available inside the command modal after borders and footer."""

    return max(1, state.height - 3)


def command_wrap_width(state: WorkflowUiState) -> int:
    """Usable text width inside the command modal (two borders, two paddings)."""

    return max(20, state.width - 4)


def _wrap_command(line: str, width: int) -> Tuple[str, ...]:
    """Fold one command onto ``width`` at argument boundaries.

    Commands in this overlay exist to be copied, so they are wrapped rather
    than truncated. A word longer than the width is emitted whole and allowed
    to clip rather than being silently cut mid-token.
    """

    if len(line) <= width:
        return (line,)
    rows: list = []
    current = ""
    indent = ""
    for word in line.split(" "):
        candidate = word if not current else f"{current} {word}"
        if len(candidate) <= width or not current:
            current = candidate
            continue
        rows.append(current)
        indent = COMMAND_WRAP_INDENT
        current = f"{indent}{word}"
    if current:
        rows.append(current)
    return tuple(rows)


def wrapped_command_lines(state: WorkflowUiState) -> Tuple[str, ...]:
    """Command catalog folded to the modal width. Paging counts these rows."""

    width = command_wrap_width(state)
    rows: list = []
    for line in workflow_command_lines(state):
        rows.extend(_wrap_command(line, width))
    return tuple(rows)


def visible_command_lines(state: WorkflowUiState) -> Tuple[str, ...]:
    lines = wrapped_command_lines(state)
    page_size = command_page_size(state)
    max_offset = max(0, len(lines) - page_size)
    offset = min(max(0, state.command_offset), max_offset)
    return lines[offset : offset + page_size]


def _scroll_commands(state: WorkflowUiState, delta: int) -> WorkflowUiState:
    lines = wrapped_command_lines(state)
    max_offset = max(0, len(lines) - command_page_size(state))
    return replace(state, command_offset=min(max(state.command_offset + delta, 0), max_offset))


def _apply_commands_focus_key(state: WorkflowUiState, key: object) -> WorkflowUiState:
    action = resolve_action(key)
    if action == "quit":
        return replace(state, quit_requested=True, detach_reason=DETACH_QUIT)
    if action == "interrupt":
        return replace(state, quit_requested=True, detach_reason=DETACH_INTERRUPT)
    if action in ("escape", "commands-toggle"):
        return replace(state, focus=state.previous_focus, command_offset=0)
    if action == "down":
        return _scroll_commands(state, 1)
    if action == "up":
        return _scroll_commands(state, -1)
    if action == "page-down":
        return _scroll_commands(state, command_page_size(state))
    if action == "page-up":
        return _scroll_commands(state, -command_page_size(state))
    if action == "home":
        return replace(state, command_offset=0)
    if action == "end":
        return replace(
            state,
            command_offset=max(0, len(wrapped_command_lines(state)) - command_page_size(state)),
        )
    return state


def _apply_stages_focus_key(state: WorkflowUiState, action: Optional[str]) -> WorkflowUiState:
    if action == "down":
        return _move_selection(state, 1)
    if action == "up":
        return _move_selection(state, -1)
    if action == "page-down":
        return _move_selection(state, state.page_size)
    if action == "page-up":
        return _move_selection(state, -state.page_size)
    if action == "home":
        return _jump_selection(state, to_end=False)
    if action == "end":
        return _jump_selection(state, to_end=True)
    if action == "filter-start":
        return replace(
            state,
            filter_editing=True,
            filter_backup=state.filter_query,
            selection_touched=True,
        )
    if action == "details-toggle":
        if state.view.selected_stage is None:
            return state
        return replace(state, details_view=not state.details_view)
    if action == "escape":
        if state.filter_query:
            return _reconcile_filtered_selection(replace(state, filter_query=""))
        return state
    return None


def apply_key(state: WorkflowUiState, key: object) -> WorkflowUiState:
    """Apply one raw key token and return the next pure UI state.

    Never mutates ``state``. Terminal keys (``q``, Ctrl-C) only set the
    detach flags; the caller is responsible for actually leaving the viewer.
    """

    if state.quit_requested:
        return state

    if state.filter_editing:
        return _apply_filter_editing_key(state, key)

    if state.focus == FOCUS_HELP:
        return _apply_help_focus_key(state, key)
    if state.focus == FOCUS_COMMANDS:
        return _apply_commands_focus_key(state, key)

    action = resolve_action(key)

    if action == "quit":
        return replace(state, quit_requested=True, detach_reason=DETACH_QUIT)
    if action == "interrupt":
        return replace(state, quit_requested=True, detach_reason=DETACH_INTERRUPT)
    if action == "resize":
        return state
    if action == "refresh":
        return replace(state, refresh_requested=True)
    if action == "help-toggle":
        return replace(state, focus=FOCUS_HELP, previous_focus=state.focus)
    if action == "commands-toggle":
        return replace(
            state,
            focus=FOCUS_COMMANDS,
            previous_focus=state.focus,
            command_offset=0,
        )

    handled = _apply_stages_focus_key(state, action)
    if handled is not None:
        return handled
    return state


def apply_keys(state: WorkflowUiState, keys: Sequence[object]) -> WorkflowUiState:
    current = state
    for key in keys:
        current = apply_key(current, key)
    return current


def apply_resize(state: WorkflowUiState, width: int, height: int) -> WorkflowUiState:
    """Record a terminal resize. Preserves selection, filter, and focus."""

    return replace(state, width=max(0, int(width)), height=max(0, int(height)))


def apply_refresh(state: WorkflowUiState, snapshot: wt.WorkflowSnapshot) -> WorkflowUiState:
    """Reconcile a freshly loaded snapshot into the interaction state.

    Preserves the filter query, focus, and details toggle.
    Selection is reconciled by ``workflow_tui`` first, then re-clamped into
    the active filter so an incremental filter never shows a selection that
    the filter would exclude.
    """

    previous_primary = (
        wt.primary_stage_id(state.view.snapshot)
        if state.view.snapshot is not None
        else None
    )
    refreshed_primary = wt.primary_stage_id(snapshot)
    attention_advanced = previous_primary != refreshed_primary
    preserve_manual_selection = state.selection_touched and not attention_advanced
    next_view = (
        wt.reconcile_refresh(state.view, snapshot)
        if preserve_manual_selection
        else wt.view_from_snapshot(snapshot)
    )
    refreshed = replace(
        state,
        view=next_view,
        selection_touched=preserve_manual_selection,
        refresh_requested=False,
    )
    return _reconcile_filtered_selection(refreshed)


def apply_error(state: WorkflowUiState, error: wt.UiError) -> WorkflowUiState:
    """Surface a failed refresh without discarding the last good snapshot/state."""

    return replace(state, view=replace(state.view, error=error), refresh_requested=False)


def contextual_footer(state: WorkflowUiState) -> Tuple[FooterAction, ...]:
    """Return only the footer actions valid for the current focus/mode.

    Help mode expands to the full documented binding list; every other mode
    shows strictly the actions that ``apply_key`` will actually honor right
    now, so an unavailable action never appears.
    """

    if state.filter_editing:
        return (
            FooterAction("type", "filter"),
            FooterAction("Enter", "apply"),
            FooterAction("Esc", "cancel"),
            FooterAction("Backspace", "delete"),
        )

    if state.focus == FOCUS_HELP:
        return full_help_footer(state)
    if state.focus == FOCUS_COMMANDS:
        return (
            FooterAction("j/k", "scroll"),
            FooterAction("PgUp/PgDn", "page"),
            FooterAction("Home/End", "first/last"),
            FooterAction("Esc/c", "close"),
            FooterAction("q", "detach"),
        )

    actions: list = []
    # FOCUS_STAGES
    visible = visible_stage_ids(state)
    if len(visible) > 1:
        actions.append(FooterAction("up/down j/k", "select"))
        actions.append(FooterAction("PgUp/PgDn", "page"))
        actions.append(FooterAction("Home/End", "first/last"))
    actions.append(FooterAction("/", "filter"))
    if state.filter_query:
        actions.append(FooterAction("Esc", "clear filter"))
    if state.view.selected_stage is not None:
        actions.append(FooterAction("d", "details"))
    if selected_stage_has_request(state):
        actions.append(FooterAction("a", "respond"))
    if has_log_target(state):
        actions.append(FooterAction("l", "live tail"))
    actions.append(FooterAction("c", "commands"))
    actions.append(FooterAction("r", "refresh"))
    actions.append(FooterAction("?", "help"))
    run = state.view.run
    run_continues = run is not None and run.state not in {"succeeded", "failed", "cancelled"}
    actions.append(
        FooterAction("q", "detach; run continues" if run_continues else "close viewer")
    )
    return tuple(actions)


def full_help_footer(state: WorkflowUiState) -> Tuple[FooterAction, ...]:
    """Every documented binding, shown by the expanded ``?`` help overlay."""

    return (
        FooterAction("up/down j/k", "select stage"),
        FooterAction("PgUp/PgDn", "page selection"),
        FooterAction("Home/End", "first/last stage"),
        FooterAction("/", "start incremental stage filter"),
        FooterAction("Esc", "clear filter / close overlay"),
        FooterAction("d", "toggle stage detail/reveal"),
        FooterAction("a", "respond to the selected stage's approval or input request"),
        FooterAction("l", "show live tail and artifact commands"),
        FooterAction("c", "show live tail and artifact commands"),
        FooterAction("r", "refresh now"),
        FooterAction("?", "toggle this help"),
        FooterAction(
            "q",
            "detach (workflow keeps running)"
            if state.view.run is not None
            and state.view.run.state not in {"succeeded", "failed", "cancelled"}
            else "close viewer",
        ),
        FooterAction("Ctrl-C", "detach"),
    )
