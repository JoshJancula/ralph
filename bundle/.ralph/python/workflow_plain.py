#!/usr/bin/env python3
"""Deterministic, line-oriented rendering for workflow status and watch.

This module consumes only the public workflow status read model.  It neither
reads workflow state nor emits terminal control sequences, so it is suitable
for redirected output, CI logs, and screen readers.
"""

from __future__ import annotations

import json
import os
import re
import shlex
import sys
from dataclasses import dataclass
from typing import Iterable, Mapping, Optional, Sequence, Tuple

import workflow_tui as wt


_CONTROL = re.compile(
    r"\x1b(?:\[[0-?]*[ -/]*[@-~]|\][^\x07]*(?:\x07|\x1b\\))|[\x00-\x08\x0b-\x1f\x7f]"
)
_TRUTHY = frozenset({"1", "true", "yes", "on"})
_PLAIN_ENVIRONMENT = (
    "CI",
    "RALPH_GRAPH_PLAIN",
    "RALPH_GRAPH_NO_TUI",
    "RALPH_GRAPH_SCREEN_READER",
    "ACCESSIBILITY_SCREEN_READER",
)


@dataclass(frozen=True)
class PlainWatchUpdate:
    """The frame and events that have not already been announced."""

    frame: Optional[Tuple[str, ...]]
    events: Tuple[str, ...]


def plain_output_required(
    *,
    force_plain: bool = False,
    stdin_isatty: bool = True,
    stdout_isatty: bool = True,
    environ: Optional[Mapping[str, str]] = None,
) -> bool:
    """Return whether the public viewer must use streaming text."""

    environment = os.environ if environ is None else environ
    return (
        force_plain
        or not stdin_isatty
        or not stdout_isatty
        or str(environment.get("TERM", "")).strip().lower() == "dumb"
        or any(str(environment.get(name, "")).strip().lower() in _TRUTHY for name in _PLAIN_ENVIRONMENT)
    )


def _clean(value: object, *, limit: int = 240) -> str:
    text = _CONTROL.sub(" ", str(value))
    text = " ".join(text.split())
    return text[:limit].rstrip()


def _action_text(action: Optional[wt.NextAction]) -> str:
    if action is None:
        return "none required"
    command = _clean(" ".join(action.argv))
    label = _clean(action.label)
    if command and label:
        return f"{label}: {command}"
    return command or label or "none required"


def _question(stage: Optional[wt.Stage], diagnosis: wt.Diagnosis) -> str:
    if stage is not None:
        for candidate in (stage.request_question, stage.approval_question):
            text = _clean(candidate or "")
            if text:
                return text
    if diagnosis.request_kind in {"approval", "input"}:
        return _clean(diagnosis.summary)
    return ""


def _stage_reset_target(action: Optional[wt.NextAction]) -> str:
    if action is None:
        return ""
    try:
        index = action.argv.index("--stage")
    except ValueError:
        return ""
    if index + 1 >= len(action.argv):
        return ""
    return _clean(action.argv[index + 1])


def _task_code_stage(snapshot: wt.WorkflowSnapshot) -> Optional[wt.Stage]:
    reset_target = _stage_reset_target(snapshot.next_action)
    if reset_target:
        target = next((item for item in snapshot.stages if item.id == reset_target), None)
        if target is not None:
            return target
    candidates = [
        item
        for item in snapshot.stages
        if item.workspace_path or item.changeset_manifest or item.changed_files
    ]
    return max(candidates, key=lambda item: (item.attempt, item.index)) if candidates else None


def render_status_lines(view: wt.WorkflowViewModel) -> Tuple[str, ...]:
    """Render one finite, screen-reader-friendly frame from a workflow view."""

    if view.error is not None:
        return (
            "Workflow status",
            f"State: unavailable ({_clean(view.error.code)})",
            f"Summary: {_clean(view.error.message)}",
        )
    if view.snapshot is None or view.run is None or view.diagnosis is None:
        return ("Workflow status", "State: unavailable", "Summary: no workflow status is available")

    snapshot = view.snapshot
    run = snapshot.run
    diagnosis = snapshot.diagnosis
    stage = view.selected_stage
    lines = [
        "Workflow status",
        f"State: {_clean(diagnosis.state)} ({_clean(diagnosis.reason_code)})",
        (
            f"Run: {_clean(run.run_id)} | Workflow: {_clean(run.workflow_id or '-')} "
            f"| Mode: {_clean(run.mode)}"
        ),
    ]
    task = _clean(run.task)
    if task:
        lines.append(f"Task: {task}")
    summary = _clean(diagnosis.summary)
    if summary:
        lines.append(f"Summary: {summary}")
    if diagnosis.reason_code == "loop-exhausted":
        findings = tuple(
            item[len("requested change: ") :]
            for item in diagnosis.evidence
            if item.startswith("requested change: ")
        )
        for index, finding in enumerate(findings[:4], start=1):
            lines.append(f"Review note {index}: {_clean(finding)}")
        if len(findings) > 4:
            lines.append(f"More review notes: {len(findings) - 4}")
    if stage is not None:
        lines.append(f"Stage: {_clean(stage.id)} [{_clean(stage.state)}]")
        if stage.progress.total > 0:
            todo = _clean(stage.progress.current_todo_id or "")
            progress = f"{stage.progress.completed}/{stage.progress.total}"
            lines.append(f"Progress: {progress}" + (f" TODO {todo}" if todo else ""))
        question = _question(stage, diagnosis)
        if question:
            lines.append(f"Question: {question}")
        if stage.evidence:
            lines.append(f"Evidence: {len(stage.evidence)} item(s)")
        if diagnosis.reason_code == "loop-exhausted" and stage.artifacts:
            verdict = stage.artifacts[0]
            lines.append(f"Review verdict: {_clean(verdict)}")
            lines.append(f"Requested changes: jq -r '.feedback[]' {shlex.quote(verdict)}")
    elif diagnosis.stage_id:
        lines.append(f"Stage: {_clean(diagnosis.stage_id)}")
    lines.append(f"Action: {_action_text(snapshot.next_action)}")
    if diagnosis.reason_code == "loop-exhausted":
        reset_target = _stage_reset_target(snapshot.next_action)
        if reset_target and stage is not None:
            lines.append(
                f"Retry behavior: reset {reset_target}; its next fresh attempt receives "
                f"{stage.id}'s final review feedback"
            )
            lines.append(
                f"Preview retry: ralph workflow reset {run.run_id} "
                f"--stage {reset_target} --dry-run"
            )
            lines.append(f"Continue run: ralph workflow resume {run.run_id}")
    if diagnosis.state == "failed" or run.state == "failed":
        code_stage = _task_code_stage(snapshot)
        lines.append("Finish task: retry this run from the repair stage or generate a handoff report")
        if code_stage is not None:
            lines.append(f"Code stage: {_clean(code_stage.id)}")
            if code_stage.workspace_mode:
                availability = "available" if code_stage.workspace_available else "not available"
                lines.append(f"Workspace: {_clean(code_stage.workspace_mode)} ({availability})")
                lines.append(
                    "Git worktree: "
                    + ("yes" if code_stage.workspace_mode == "worktree" else "no")
                )
            if code_stage.workspace_path:
                lines.append(f"Agent workspace: {_clean(code_stage.workspace_path, limit=1000)}")
                if code_stage.workspace_available:
                    lines.append(f"Open code: cd {shlex.quote(code_stage.workspace_path)}")
            if code_stage.changeset_manifest:
                lines.append(f"Changeset: {_clean(code_stage.changeset_manifest, limit=1000)}")
            if code_stage.changed_files:
                lines.append(f"Changed files: {len(code_stage.changed_files)}")
        else:
            lines.append("Code location: not recorded")
        lines.append(f"Handoff report: ralph workflow handoff {run.run_id}")
    return tuple(lines)


class PlainWatchRenderer:
    """Emit an initial frame, then only changed frames and unseen events."""

    def __init__(self) -> None:
        self._last_frame: Optional[Tuple[str, ...]] = None
        self._seen_events: set[str] = set()

    def render(
        self, view: wt.WorkflowViewModel, events: Iterable[str] = ()
    ) -> PlainWatchUpdate:
        frame = render_status_lines(view)
        changed_frame = frame if frame != self._last_frame else None
        self._last_frame = frame
        unseen = []
        for event in events:
            cleaned = _clean(event, limit=500)
            if cleaned and cleaned not in self._seen_events:
                self._seen_events.add(cleaned)
                unseen.append(cleaned)
        return PlainWatchUpdate(frame=changed_frame, events=tuple(unseen))


def _read_status() -> wt.WorkflowViewModel:
    snapshot = wt.parse_status_json(sys.stdin.read())
    return wt.view_from_snapshot(snapshot)


def main(argv: Sequence[str]) -> int:
    if tuple(argv) != ("status",):
        print("Usage: workflow_plain.py status", file=sys.stderr)
        return 2
    try:
        lines = render_status_lines(_read_status())
    except (OSError, wt.SnapshotValidationError, ValueError, json.JSONDecodeError) as exc:
        print(f"Error: cannot render workflow status: {_clean(exc)}", file=sys.stderr)
        return 1
    print("\n".join(lines))
    return 0


if __name__ == "__main__":
    raise SystemExit(main(tuple(sys.argv[1:])))
