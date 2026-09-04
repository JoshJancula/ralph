#!/usr/bin/env python3
"""Safe, backend-neutral modal actions for ``ralph workflow watch``.

This module consumes only the public workflow status and actions-list read
models.  It never reads a workflow registry or engine directory and never
writes action records: durable operations are delegated to the public CLI.
"""

from __future__ import annotations

import json
import re
import subprocess
from dataclasses import dataclass, replace
from typing import Any, Callable, List, Mapping, Optional, Sequence, Tuple

import workflow_canvas as wc
import workflow_interaction as wi
import workflow_layout as wl
import workflow_tui as wt


DECISIONS = {
    "approval": frozenset({"approve", "request-changes", "cancel"}),
    "input": frozenset({"answer", "cancel"}),
    "permission": frozenset({"allow-once", "allow-run", "allow-always", "deny"}),
}
OUTSTANDING = "outstanding"
_REQUEST_ID = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]*$")

CommandRunner = Callable[[Sequence[str]], object]


@dataclass(frozen=True)
class CommandResult:
    returncode: int
    stdout: str = ""
    stderr: str = ""
    argv: Tuple[str, ...] = ()


@dataclass(frozen=True)
class PublicAction:
    request_id: str
    kind: str
    run_id: str
    stage_id: str
    attempt_id: str
    question: Optional[str]
    choices: Tuple[str, ...]
    status: str


@dataclass(frozen=True)
class ActionRecords:
    actions: Tuple[PublicAction, ...]
    error: Optional[str] = None


@dataclass(frozen=True)
class WorkflowDialog:
    """One focused modal operation, including its explicit confirmation state."""

    operation: str
    run_id: str
    request_id: Optional[str] = None
    stage_id: Optional[str] = None
    choices: Tuple[str, ...] = ()
    selected_choice: Optional[str] = None
    message: str = ""
    needs_confirmation: bool = True
    confirming: bool = False
    submit_pending: bool = False
    refresh_requested: bool = False
    error: Optional[str] = None
    last_command: Optional[Tuple[str, ...]] = None


def _safe_string(value: Any, field: str, *, nullable: bool = False) -> Optional[str]:
    if value is None and nullable:
        return None
    if not isinstance(value, str) or not value or "\x00" in value:
        raise ValueError(f"{field} must be a non-empty string")
    return value


def _choices(value: Any, kind: str) -> Tuple[str, ...]:
    if not isinstance(value, list) or not value:
        raise ValueError("choices must be a non-empty array")
    parsed = tuple(_safe_string(item, "choices item") or "" for item in value)
    if len(set(parsed)) != len(parsed) or any(item not in DECISIONS[kind] for item in parsed):
        raise ValueError(f"choices are invalid for {kind}")
    return parsed


def parse_public_actions(payload: Any, run_id: str) -> ActionRecords:
    """Parse public ``workflow actions list --json`` output conservatively.

    A malformed, cross-run, answered, consumed, duplicate, or conflicting
    record is never actionable.  The returned error is intended for display in
    the dialog; it is not a reason to infer an operator decision.
    """

    if not isinstance(payload, list):
        return ActionRecords((), "workflow actions returned malformed JSON")
    actions = []
    seen: dict[str, PublicAction] = {}
    for index, raw in enumerate(payload):
        try:
            if not isinstance(raw, Mapping):
                raise ValueError("record must be an object")
            request_id = _safe_string(raw.get("requestId"), "requestId") or ""
            if not _REQUEST_ID.fullmatch(request_id):
                raise ValueError("requestId is malformed")
            kind = _safe_string(raw.get("kind"), "kind") or ""
            if kind not in DECISIONS:
                raise ValueError("kind is unsupported")
            record = PublicAction(
                request_id=request_id,
                kind=kind,
                run_id=_safe_string(raw.get("runId"), "runId") or "",
                stage_id=_safe_string(raw.get("stageId"), "stageId") or "",
                attempt_id=_safe_string(raw.get("attemptId"), "attemptId") or "",
                question=_safe_string(raw.get("question"), "question", nullable=True),
                choices=_choices(raw.get("choices"), kind),
                status=_safe_string(raw.get("status"), "status") or "",
            )
        except ValueError as exc:
            return ActionRecords((), f"invalid action record {index}: {exc}")
        if record.run_id != run_id:
            return ActionRecords((), f"action {record.request_id} belongs to a different run")
        previous = seen.get(record.request_id)
        if previous is not None:
            if previous != record:
                return ActionRecords((), f"conflicting records for request {record.request_id}")
            return ActionRecords((), f"replayed record for request {record.request_id}")
        seen[record.request_id] = record
        if record.status == OUTSTANDING:
            actions.append(record)
        elif record.status not in {"answered", "consumed"}:
            return ActionRecords((), f"request {record.request_id} has unsupported status")
    return ActionRecords(tuple(actions))


def _result(raw: object, argv: Sequence[str]) -> CommandResult:
    if isinstance(raw, CommandResult):
        return raw
    return CommandResult(
        returncode=int(getattr(raw, "returncode", 1)),
        stdout=str(getattr(raw, "stdout", "") or ""),
        stderr=str(getattr(raw, "stderr", "") or ""),
        argv=tuple(getattr(raw, "argv", argv) or argv),
    )


def run_command(argv: Sequence[str]) -> CommandResult:
    completed = subprocess.run(tuple(argv), capture_output=True, text=True, check=False)
    return CommandResult(
        returncode=int(completed.returncode),
        stdout=completed.stdout or "",
        stderr=completed.stderr or "",
        argv=tuple(argv),
    )


def _error_line(result: CommandResult) -> str:
    for text in (result.stderr, result.stdout):
        lines = [line.strip() for line in text.splitlines() if line.strip()]
        if lines:
            return lines[-1][:240]
    return "workflow command failed"


def action_list_command(run_id: str, command: Sequence[str] = ("ralph",)) -> Tuple[str, ...]:
    # Reuse the exact-run-id and configured-prefix validation from the status
    # boundary, but actions has its own public subcommand path.
    prefix = wt.status_command(run_id, command)[:-4]
    return prefix + ("workflow", "actions", "list", run_id, "--json")


def load_action_records(
    snapshot: wt.WorkflowSnapshot,
    *,
    runner: Optional[CommandRunner] = None,
    command: Sequence[str] = ("ralph",),
) -> ActionRecords:
    """Load actions through the public CLI; no filesystem access is performed."""

    try:
        argv = action_list_command(snapshot.run.run_id, command)
    except ValueError as exc:
        return ActionRecords((), str(exc))
    result = _result((runner or run_command)(argv), argv)
    if result.returncode != 0:
        return ActionRecords((), _error_line(result))
    try:
        return parse_public_actions(json.loads(result.stdout), snapshot.run.run_id)
    except (json.JSONDecodeError, TypeError):
        return ActionRecords((), "workflow actions returned malformed JSON")


def _matching_stage(snapshot: wt.WorkflowSnapshot, action: PublicAction) -> Optional[wt.Stage]:
    for stage in snapshot.stages:
        # The public status contract exposes a numeric attempt count, while
        # action records carry the engine's opaque attempt ID. Do not invent a
        # conversion between them; the public run/request/stage tuple is the
        # identity available to this UI.
        if stage.id == action.stage_id and stage.request_id == action.request_id:
            return stage
    return None


def _message_required(kind: str, decision: str) -> bool:
    return (kind == "approval" and decision == "request-changes") or (
        kind == "input" and decision == "answer"
    )


def open_decision_dialog(
    snapshot: wt.WorkflowSnapshot, actions: ActionRecords, request_id: str
) -> WorkflowDialog:
    """Open a dialog only for an outstanding public action tied to this snapshot."""

    if actions.error:
        return WorkflowDialog("decision", snapshot.run.run_id, error=actions.error)
    matches = [action for action in actions.actions if action.request_id == request_id]
    if len(matches) != 1:
        return WorkflowDialog(
            "decision", snapshot.run.run_id, request_id=request_id, error="request is not outstanding"
        )
    action = matches[0]
    stage = _matching_stage(snapshot, action)
    if stage is None:
        return WorkflowDialog(
            "decision",
            snapshot.run.run_id,
            request_id=action.request_id,
            error="request identity is stale or does not match public status",
        )
    if snapshot.diagnosis.request_id == action.request_id and snapshot.diagnosis.request_kind != action.kind:
        return WorkflowDialog(
            "decision",
            snapshot.run.run_id,
            request_id=action.request_id,
            error="request kind conflicts with public status",
        )
    return WorkflowDialog(
        "decision",
        snapshot.run.run_id,
        request_id=action.request_id,
        stage_id=stage.id,
        choices=action.choices,
        selected_choice=action.choices[0],
    )


def _validate_public_next_action(
    snapshot: wt.WorkflowSnapshot, verb: str
) -> Optional[Tuple[str, ...]]:
    action = snapshot.next_action
    if action is None:
        return None
    argv = action.argv
    expected = ("ralph", "workflow", verb, snapshot.run.run_id)
    if tuple(argv[:4]) != expected:
        return None
    if verb in {"resume", "recover"} and len(argv) == 4:
        return argv
    if verb == "reset" and len(argv) == 6 and argv[4] == "--stage":
        # The reset target is an executable ancestor and need not itself be in
        # the currently projected stage list. It must nevertheless be the
        # exact target publicly attached to an approval stage.
        if any(stage.changes_target == argv[5] for stage in snapshot.stages):
            return argv
    return None


def open_lifecycle_dialog(snapshot: wt.WorkflowSnapshot, operation: str) -> WorkflowDialog:
    """Open resume, reset, or recovery only when status advertises it exactly."""

    if operation not in {"resume", "reset", "recover"}:
        raise ValueError("unsupported lifecycle operation")
    argv = _validate_public_next_action(snapshot, operation)
    if argv is None:
        return WorkflowDialog(operation, snapshot.run.run_id, error="operation is not available")
    stage_id = argv[-1] if operation == "reset" else None
    return WorkflowDialog(operation, snapshot.run.run_id, stage_id=stage_id)


def select_choice(dialog: WorkflowDialog, choice: str) -> WorkflowDialog:
    if dialog.operation != "decision" or choice not in dialog.choices:
        return dialog
    return replace(dialog, selected_choice=choice, error=None, confirming=False, submit_pending=False)


def set_message(dialog: WorkflowDialog, message: str) -> WorkflowDialog:
    if dialog.operation != "decision":
        return dialog
    return replace(dialog, message=message, error=None, refresh_requested=False)


def cancel_dialog(dialog: WorkflowDialog) -> Optional[WorkflowDialog]:
    """Cancel/back has no durable side effect."""

    return None


def dialog_body_lines(dialog: WorkflowDialog) -> List[Tuple[wc.StyledText, ...]]:
    """Return semantic lines describing the modal for canvas rendering."""

    lines: List[Tuple[wc.StyledText, ...]] = []
    if dialog.error:
        lines.append((wc.StyledText(dialog.error, "failure"),))
        return lines
    if dialog.operation == "decision":
        lines.append(
            (
                wc.StyledText("Request ", "muted"),
                wc.StyledText(dialog.request_id or "-", "heading"),
                wc.StyledText("  Stage ", "muted"),
                wc.StyledText(dialog.stage_id or "-", "default"),
            )
        )
        lines.append((wc.StyledText("Choose a public decision:", "default"),))
        for choice in dialog.choices:
            marker = ">" if choice == dialog.selected_choice else " "
            role = "focus" if choice == dialog.selected_choice else "default"
            lines.append((wc.StyledText(f"{marker} {choice}", role),))
        if dialog.message:
            lines.append(
                (
                    wc.StyledText("Message: ", "muted"),
                    wc.StyledText(dialog.message, "default"),
                )
            )
        if dialog.confirming:
            lines.append((wc.StyledText("Confirm this durable action?", "warning"),))
        return lines
    label = {
        "resume": "Resume this persisted wait",
        "reset": "Reset to the approval changes target",
        "recover": "Recover the abandoned run",
    }.get(dialog.operation, dialog.operation)
    lines.append((wc.StyledText(label, "heading"),))
    lines.append(
        (
            wc.StyledText("Run ", "muted"),
            wc.StyledText(dialog.run_id, "default"),
        )
    )
    if dialog.stage_id:
        lines.append(
            (
                wc.StyledText("Stage ", "muted"),
                wc.StyledText(dialog.stage_id, "default"),
            )
        )
    if dialog.confirming:
        lines.append((wc.StyledText("Confirm this durable action?", "warning"),))
    return lines


def render_dialog_frame(
    dialog: WorkflowDialog,
    width: int,
    height: int,
    *,
    ascii_only: bool = False,
) -> wc.Canvas:
    """Paint a focused operator dialog onto the semantic canvas."""

    title = {
        "decision": "Operator decision",
        "resume": "Resume workflow",
        "reset": "Reset workflow stage",
        "recover": "Recover workflow",
    }.get(dialog.operation, "Operator action")
    return wl.render_modal_frame(
        title=title,
        body=dialog_body_lines(dialog),
        width=width,
        height=height,
        ascii_only=ascii_only,
    )


def request_confirmation(dialog: WorkflowDialog) -> WorkflowDialog:
    """Advance a valid modal action to explicit confirmation, never dispatching."""

    if dialog.error:
        return dialog
    if dialog.operation == "decision":
        if dialog.selected_choice not in dialog.choices:
            return replace(dialog, error="select a listed decision first")
        if _message_required_for_dialog(dialog) and not dialog.message.strip():
            return replace(dialog, error=f"{dialog.selected_choice} requires feedback")
    return replace(dialog, confirming=True, submit_pending=False, refresh_requested=False, error=None)


def _message_required_for_dialog(dialog: WorkflowDialog) -> bool:
    if dialog.operation != "decision" or dialog.selected_choice is None:
        return False
    for kind, decisions in DECISIONS.items():
        if dialog.selected_choice in decisions and dialog.selected_choice in dialog.choices:
            return _message_required(kind, dialog.selected_choice)
    return False


def _configured_argv(public_argv: Sequence[str], command: Sequence[str]) -> Tuple[str, ...]:
    if not command or any(not isinstance(part, str) or not part for part in command):
        raise ValueError("workflow command must contain at least one non-empty argv item")
    return tuple(command) + tuple(public_argv[1:]) + ("--yes",)


def build_command(
    snapshot: wt.WorkflowSnapshot,
    actions: ActionRecords,
    dialog: WorkflowDialog,
    *,
    command: Sequence[str] = ("ralph",),
) -> Optional[Tuple[str, ...]]:
    """Build an existing public CLI command only after all identities validate."""

    if dialog.run_id != snapshot.run.run_id:
        return None
    if dialog.operation == "decision":
        if actions.error or not dialog.request_id or not dialog.stage_id:
            return None
        action = next((item for item in actions.actions if item.request_id == dialog.request_id), None)
        if action is None or action.stage_id != dialog.stage_id or _matching_stage(snapshot, action) is None:
            return None
        choice = dialog.selected_choice
        if choice not in action.choices:
            return None
        if _message_required(action.kind, choice) and not dialog.message.strip():
            return None
        argv = ("ralph", "workflow", "actions", "respond", snapshot.run.run_id, action.request_id,
                "--decision", choice)
        if dialog.message.strip():
            argv += ("--message", dialog.message.strip())
        return _configured_argv(argv, command)
    if dialog.operation not in {"resume", "reset", "recover"}:
        return None
    public_argv = _validate_public_next_action(snapshot, dialog.operation)
    if public_argv is None:
        return None
    if dialog.operation == "reset" and dialog.stage_id != public_argv[-1]:
        return None
    return _configured_argv(public_argv, command)


def dispatch_dialog(
    snapshot: wt.WorkflowSnapshot,
    actions: ActionRecords,
    dialog: WorkflowDialog,
    *,
    confirmed: bool,
    runner: Optional[CommandRunner] = None,
    command: Sequence[str] = ("ralph",),
) -> WorkflowDialog:
    """Run the public command after confirmation and request one UI refresh on success."""

    pending = request_confirmation(dialog) if not dialog.confirming else dialog
    if pending.error:
        return pending
    if not confirmed:
        return replace(pending, confirming=False, submit_pending=False, refresh_requested=False)
    argv = build_command(snapshot, actions, pending, command=command)
    if argv is None:
        return replace(pending, confirming=False, submit_pending=False, error="public action is no longer valid")
    result = _result((runner or run_command)(argv), argv)
    if result.returncode != 0:
        return replace(
            pending,
            confirming=False,
            submit_pending=False,
            refresh_requested=False,
            error=_error_line(result),
            last_command=argv,
        )
    return replace(
        pending,
        confirming=False,
        submit_pending=True,
        refresh_requested=True,
        error=None,
        last_command=argv,
    )


# --- key handling for an open dialog ---------------------------------------
#
# Kept pure and separate from the curses loop so the modal's behavior is
# testable without a terminal, the same way workflow_interaction handles the
# main view. Returns the next dialog plus one intent for the caller:
#   ""       stay open
#   "close"  operator dismissed it; no command ran
#   "submit" operator confirmed; caller dispatches the public command

DIALOG_STAY = ""
DIALOG_CLOSE = "close"
DIALOG_SUBMIT = "submit"


def _dialog_printable(key: object) -> str:
    text = wi._key_text(key)
    if not text or len(text) != 1:
        return ""
    if not text.isprintable() or text in {"\n", "\r", "\x1b"}:
        return ""
    return str(text)


def apply_dialog_key(dialog: WorkflowDialog, key: object) -> Tuple[WorkflowDialog, str]:
    """Apply one key to an open dialog. Never dispatches; never mutates input."""

    action = wi.resolve_action(key)
    text = _dialog_printable(key)

    # Confirmation is a deliberate second step: only an explicit y submits, and
    # anything else backs out to the editable dialog rather than the caller.
    if dialog.confirming:
        if text in {"y", "Y"}:
            return dialog, DIALOG_SUBMIT
        if text in {"n", "N"} or action == "escape":
            return replace(dialog, confirming=False, submit_pending=False), DIALOG_STAY
        return dialog, DIALOG_STAY

    if action == "escape":
        return dialog, DIALOG_CLOSE

    if dialog.error:
        # An errored dialog is a dead end: let any key close it so the operator
        # is never trapped in a modal that cannot proceed.
        return dialog, DIALOG_CLOSE

    if action == "enter":
        return request_confirmation(dialog), DIALOG_STAY

    if dialog.operation == "decision" and dialog.choices:
        if action in {"down", "up"}:
            index = 0
            if dialog.selected_choice in dialog.choices:
                index = dialog.choices.index(dialog.selected_choice)
            step = 1 if action == "down" else -1
            nxt = dialog.choices[(index + step) % len(dialog.choices)]
            return select_choice(dialog, nxt), DIALOG_STAY
        if action == "backspace":
            return set_message(dialog, dialog.message[:-1]), DIALOG_STAY
        if text:
            return set_message(dialog, dialog.message + text), DIALOG_STAY

    return dialog, DIALOG_STAY


def outstanding_request_id(state_view: Any) -> Optional[str]:
    """Request id of the currently selected stage, when it has one outstanding."""

    stage = getattr(state_view, "selected_stage", None)
    if stage is None:
        return None
    request_id = getattr(stage, "request_id", None)
    if not request_id:
        return None
    return str(request_id)
