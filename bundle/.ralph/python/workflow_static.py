#!/usr/bin/env python3
"""Finite static renderers for `ralph workflow status` and `ralph workflow runs`.

Consumes only the public status JSON (status) or outer-run summary rows (runs).
TTY output uses ralph_term semantic roles; redirected / --tsv / --json paths stay
ANSI-free. Secondary paths and helper commands are present but de-emphasized.
"""

from __future__ import annotations

import argparse
import json
import os
import shlex
import sys
from dataclasses import dataclass
from datetime import datetime, timezone
from typing import Any, Mapping, Optional, Sequence, Tuple

import ralph_term as rt
import workflow_layout as wl
import workflow_tui as wt


_TRUTHY = frozenset({"1", "true", "yes", "on"})

# Existing machine TSV schema for `ralph workflow runs` (non-TTY / --tsv).
RUNS_TSV_FIELDS = ("runId", "workflowId", "mode", "entryKind", "state", "createdAt")


def coerce_status_payload(payload: Mapping[str, Any]) -> dict:
    """Fill missing public fields so incomplete fixtures still render safely."""

    root = dict(payload)
    run = dict(root.get("run") or {})
    diagnosis = dict(root.get("diagnosis") or {})
    stages = root.get("stages") if isinstance(root.get("stages"), list) else []
    coerced_stages = []
    for item in stages:
        if not isinstance(item, dict):
            continue
        stage = dict(item)
        stage.setdefault("attempt", 0)
        stage.setdefault("completedTodos", 0)
        stage.setdefault("totalTodos", 0)
        stage.setdefault("artifacts", [])
        stage.setdefault("evidence", [])
        if "stageKind" not in stage:
            stage["stageKind"] = "executable"
        coerced_stages.append(stage)

    run.setdefault("runId", "unknown-run")
    run.setdefault("workflowId", "-")
    run.setdefault("mode", "sequential")
    run.setdefault("entryKind", "task")
    run.setdefault("task", "")
    run.setdefault("taskProvenance", "")
    run.setdefault("state", diagnosis.get("state") or "running")
    run.setdefault("sourceKind", "project")
    run.setdefault("sourcePath", "/dev/null")
    run.setdefault("inputPath", "/dev/null")
    run.setdefault("createdAt", "1970-01-01T00:00:00Z")
    run.setdefault("updatedAt", run["createdAt"])
    run.setdefault("inputPlan", None)

    diagnosis.setdefault("state", run.get("state") or "running")
    diagnosis.setdefault("reasonCode", "none")
    diagnosis.setdefault("summary", "")
    diagnosis.setdefault("stageId", None)
    diagnosis.setdefault("requestKind", None)
    diagnosis.setdefault("requestId", None)
    diagnosis.setdefault("evidence", [])
    diagnosis.setdefault("retryable", False)
    diagnosis.setdefault("nextAction", root.get("nextAction"))

    root["schemaVersion"] = int(root.get("schemaVersion") or 1)
    root["run"] = run
    root["stages"] = coerced_stages
    root["diagnosis"] = diagnosis
    if "nextAction" not in root:
        root["nextAction"] = diagnosis.get("nextAction")
    return root


@dataclass(frozen=True)
class RunListRow:
    run_id: str
    workflow_id: str
    mode: str
    entry_kind: str
    state: str
    created_at: str
    updated_at: str
    task: str


def _env_truthy(environ: Mapping[str, str], name: str) -> bool:
    return str(environ.get(name, "")).strip().lower() in _TRUTHY


def resolve_style(
    *,
    depth: Optional[int] = None,
    width: Optional[int] = None,
    force_color: bool = False,
    stdout_isatty: Optional[bool] = None,
    environ: Optional[Mapping[str, str]] = None,
) -> Tuple[rt.Style, int]:
    """Resolve a Style and display width for static operator output."""

    env = os.environ if environ is None else environ
    tty = sys.stdout.isatty() if stdout_isatty is None else bool(stdout_isatty)
    if depth is not None:
        resolved = max(0, int(depth))
    elif (
        "NO_COLOR" in env
        or _env_truthy(env, "RALPH_NO_COLOR")
        or _env_truthy(env, "RALPH_WORKFLOW_NO_COLOR")
        or str(env.get("TERM", "")).strip().lower() == "dumb"
    ):
        resolved = rt.NO_COLOR
    elif force_color or _env_truthy(env, "WORKFLOW_OPERATOR_FORCE_COLOR") or _env_truthy(
        env, "FORCE_COLOR"
    ):
        # Forced color still respects an explicit 0/16/256 request via TERM.
        probe = rt.detect_depth(env=env)
        resolved = probe if probe > 0 else rt.ANSI_16
        if not tty and "NO_COLOR" not in env:
            # detect_depth returns 0 for non-TTY when using real environ; force 16.
            if env is not os.environ or not sys.stdout.isatty():
                term = str(env.get("TERM", ""))
                colorterm = str(env.get("COLORTERM", ""))
                if "256" in term or "256" in colorterm or colorterm in (
                    "truecolor",
                    "24bit",
                    "24-bit",
                ):
                    resolved = rt.ANSI_256
                else:
                    resolved = rt.ANSI_16
    elif not tty:
        resolved = rt.NO_COLOR
    else:
        resolved = rt.detect_depth(env=env)

    if width is None:
        try:
            cols = int(str(env.get("COLUMNS", "") or "0"))
        except ValueError:
            cols = 0
        if cols <= 0:
            cols = rt.detect_width(default=80, min_width=40, max_width=200)
        display_width = max(40, cols)
    else:
        display_width = max(20, int(width))

    return rt.Style(resolved), display_width


def _clean(value: object, *, limit: int = 240) -> str:
    text = " ".join(str(value).replace("\x1b", " ").split())
    return text[:limit].rstrip()


def _action_command(action: Optional[wt.NextAction]) -> str:
    if action is None:
        return "none required"
    command = _clean(" ".join(action.argv))
    return command or _clean(action.label) or "none required"


def _line(style: rt.Style, label: str, value: str, *, label_role: str = "muted", value_role: str = "default") -> str:
    label_text = style.wrap(label_role, f"{label}:") if label_role != "default" else f"{label}:"
    if value_role == "default" or style.depth <= 0:
        return f"{label_text} {value}"
    return f"{label_text} {style.wrap(value_role, value)}"


def _respond_command(run_id: str, request_id: str, kind: str) -> str:
    if kind == "input":
        return (
            f"ralph workflow actions respond {run_id} {request_id} "
            '--decision answer --message "<your answer>" --yes'
        )
    if kind == "approval":
        return f"ralph workflow actions respond {run_id} {request_id} --decision approve --yes"
    return f"ralph workflow actions respond {run_id} {request_id} --decision <choice> --yes"


def _question(stage: Optional[wt.Stage], diagnosis: wt.Diagnosis) -> str:
    if stage is not None:
        for candidate in (stage.request_question, stage.approval_question):
            text = _clean(candidate or "")
            if text:
                return text
    if diagnosis.request_kind in {"approval", "input"}:
        return _clean(diagnosis.summary)
    return ""


def _secondary_plan_lines(stage: wt.Stage) -> Tuple[str, ...]:
    lines: list[str] = []
    if stage.plan_source_kind:
        lines.append(f"Plan source: {stage.plan_source_kind}")
        producer = stage.plan_source_stage_id if stage.plan_source_stage_id else "null"
        lines.append(f"Plan producer: {producer}")
    return tuple(lines)


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


def _stage_by_id(snapshot: wt.WorkflowSnapshot, stage_id: str) -> Optional[wt.Stage]:
    return next((stage for stage in snapshot.stages if stage.id == stage_id), None)


def _task_code_stage(snapshot: wt.WorkflowSnapshot) -> Optional[wt.Stage]:
    """Return the stage whose workspace/changes best represent unfinished code."""

    reset_target = _stage_reset_target(snapshot.next_action)
    if reset_target:
        target = _stage_by_id(snapshot, reset_target)
        if target is not None:
            return target
    candidates = [
        stage
        for stage in snapshot.stages
        if stage.workspace_path or stage.changeset_manifest or stage.changed_files
    ]
    if not candidates:
        return None
    return max(candidates, key=lambda stage: (stage.attempt, stage.index))


def _changed_files_label(stage: wt.Stage, *, limit: int = 3) -> str:
    visible = stage.changed_files[:limit]
    text = ", ".join(visible)
    remaining = len(stage.changed_files) - len(visible)
    if remaining > 0:
        text += f" (+{remaining} more)"
    return text


def _code_handoff_lines(style: rt.Style, stage: Optional[wt.Stage]) -> list[str]:
    if stage is None:
        return [_line(style, "Code location", "not recorded", value_role="warning")]
    lines = [_line(style, "Code stage", stage.id, value_role="accent")]
    if stage.workspace_mode:
        availability = "available" if stage.workspace_available else "not available"
        lines.append(
            _line(
                style,
                "Workspace",
                f"{stage.workspace_mode} ({availability})",
                value_role="path" if stage.workspace_available else "warning",
            )
        )
        lines.append(
            _line(
                style,
                "Git worktree",
                "yes" if stage.workspace_mode == "worktree" else "no",
            )
        )
    if stage.workspace_path:
        lines.append(_line(style, "Agent workspace", stage.workspace_path, value_role="path"))
        if stage.workspace_available:
            lines.append(
                _line(
                    style,
                    "Open code",
                    f"cd {shlex.quote(stage.workspace_path)}",
                    value_role="command",
                )
            )
    if stage.base_revision:
        lines.append(_line(style, "Base revision", stage.base_revision, value_role="path"))
    if stage.changeset_manifest:
        lines.append(_line(style, "Changeset", stage.changeset_manifest, value_role="path"))
    if stage.changed_files:
        lines.append(
            _line(
                style,
                f"Changed files ({len(stage.changed_files)})",
                _changed_files_label(stage),
                value_role="path",
            )
        )
    return lines


def render_status_lines(
    view: wt.WorkflowViewModel,
    style: Optional[rt.Style] = None,
    *,
    width: int = 80,
) -> Tuple[str, ...]:
    """Render one finite, outcome-first status report."""

    style = style or rt.Style(rt.NO_COLOR)
    if view.error is not None:
        return (
            _line(style, "Outcome", f"unavailable ({_clean(view.error.code)})", value_role="failure"),
            _line(style, "Summary", _clean(view.error.message)),
            _line(style, "Action", "none required", label_role="heading"),
        )
    if view.snapshot is None or view.run is None or view.diagnosis is None:
        return (
            _line(style, "Outcome", "unavailable", value_role="failure"),
            _line(style, "Summary", "no workflow status is available"),
            _line(style, "Action", "none required", label_role="heading"),
        )

    snapshot = view.snapshot
    run = snapshot.run
    diagnosis = snapshot.diagnosis
    stage = view.selected_stage
    outcome_state = wl.effective_outcome_state(run.state, diagnosis.state)
    outcome_role = wl.outcome_role(outcome_state, diagnosis.reason_code)
    primary: list[str] = []
    secondary: list[str] = []

    primary.append(
        _line(
            style,
            "Outcome",
            f"{_clean(outcome_state)} ({_clean(diagnosis.reason_code)})",
            label_role="heading",
            value_role=outcome_role,
        )
    )
    summary = _clean(diagnosis.summary)
    if summary:
        primary.append(_line(style, "Reason", summary))
    if diagnosis.reason_code == "loop-exhausted":
        findings = tuple(
            item[len("requested change: ") :]
            for item in diagnosis.evidence
            if item.startswith("requested change: ")
        )
        for index, finding in enumerate(findings[:4], start=1):
            primary.append(
                _line(
                    style,
                    f"Review note {index}",
                    _clean(finding),
                    value_role="warning",
                )
            )
        if len(findings) > 4:
            primary.append(
                _line(style, "More review notes", str(len(findings) - 4), value_role="muted")
            )

    for label, role, stages in wl.lifecycle_groups(snapshot.stages):
        names = ", ".join(wl.lifecycle_stage_label(stage_item) for stage_item in stages)
        value = rt.clip_text(names, max(12, width - len(label) - 8))
        primary.append(
            _line(style, f"{label} ({len(stages)})", value, value_role=role)
        )

    if stage is not None:
        state_role = wl.stage_state_role(stage, diagnosis)
        primary.append(
            _line(
                style,
                "Stage",
                f"{_clean(stage.id)} [{_clean(stage.state)}]",
                value_role=state_role,
            )
        )
        if stage.kind == "plan-backed" and (stage.progress.total > 0 or stage.progress.current_todo_id):
            progress = f"{stage.progress.completed}/{stage.progress.total}"
            todo = _clean(stage.progress.current_todo_id or "")
            if todo:
                progress = f"{progress} TODO {todo}"
            primary.append(_line(style, "Plan progress", progress, value_role="accent"))
        question = _question(stage, diagnosis)
        if question:
            primary.append(_line(style, "Question", question, value_role="warning"))
        if stage.evidence:
            primary.append(
                _line(style, "Evidence", f"{len(stage.evidence)} artifact(s)", value_role="muted")
            )
        if diagnosis.reason_code == "loop-exhausted" and stage.artifacts:
            verdict = stage.artifacts[0]
            primary.append(_line(style, "Review verdict", _clean(verdict), value_role="path"))
            primary.append(
                _line(
                    style,
                    "Requested changes",
                    f"jq -r '.feedback[]' {shlex.quote(verdict)}",
                    value_role="command",
                )
            )
        if stage.request_id and diagnosis.reason_code in {
            "operator-input",
            "human-approval",
            "human-changes-requested",
        }:
            if diagnosis.reason_code == "operator-input" and not stage.request_state:
                request_text = _clean(stage.request_id)
            elif stage.request_state:
                request_text = f"{_clean(stage.request_id)} ({_clean(stage.request_state)})"
            else:
                request_text = _clean(stage.request_id)
            primary.append(_line(style, "Request", request_text, value_role="path"))
        if stage.changes_target and diagnosis.reason_code == "human-changes-requested":
            primary.append(
                _line(style, "Reset target", _clean(stage.changes_target), value_role="warning")
            )
        elif stage.changes_target and stage.kind == "approval":
            secondary.append(
                _line(style, "Changes target", _clean(stage.changes_target), value_role="path")
            )
    elif diagnosis.stage_id:
        primary.append(_line(style, "Stage", _clean(diagnosis.stage_id)))

    action_text = _action_command(snapshot.next_action)
    if (
        snapshot.next_action is None
        and diagnosis.state in {"blocked", "failed"}
        and stage is not None
    ):
        action_text = f"ralph workflow logs {run.run_id} --stage {stage.id}"
    if outcome_state == "failed":
        primary.append(
            _line(
                style,
                "Finish task",
                "retry this run from the repair stage or generate a handoff report",
                label_role="heading",
                value_role="warning",
            )
        )
    primary.append(
        _line(style, "Action", action_text, label_role="heading", value_role="command")
    )

    if diagnosis.reason_code == "loop-exhausted":
        reset_target = _stage_reset_target(snapshot.next_action)
        if reset_target and stage is not None:
            secondary.append(
                _line(
                    style,
                    "Retry behavior",
                    f"reset {reset_target}; its next fresh attempt receives {stage.id}'s final review feedback",
                    value_role="warning",
                )
            )
            secondary.append(
                _line(
                    style,
                    "Preview retry",
                    f"ralph workflow reset {run.run_id} --stage {reset_target} --dry-run",
                    value_role="command",
                )
            )
            secondary.append(
                _line(
                    style,
                    "Continue run",
                    f"ralph workflow resume {run.run_id}",
                    value_role="command",
                )
            )

    if outcome_state == "failed":
        secondary.extend(_code_handoff_lines(style, _task_code_stage(snapshot)))
        secondary.append(
            _line(
                style,
                "Handoff report",
                f"ralph workflow handoff {run.run_id}",
                value_role="command",
            )
        )

    # Identity and secondary guidance stay available without dominating.
    entry = _clean(run.entry_kind)
    prov = _clean(run.task_provenance)
    identity = (
        f"{_clean(run.run_id)}  Workflow: {_clean(run.workflow_id or '-')}  "
        f"Mode: {_clean(run.mode)}  Entry: {entry}"
        + (f" ({prov})" if prov else "")
    )
    secondary.append(_line(style, "Run", identity, value_role="path"))
    task = _clean(run.task)
    if task:
        clipped = rt.clip_text(task, max(12, width - 8))
        secondary.append(_line(style, "Task", clipped))

    if stage is not None and stage.kind == "plan-backed":
        for plain in _secondary_plan_lines(stage):
            label, _, value = plain.partition(": ")
            secondary.append(_line(style, label, value, value_role="path"))
        # Path fields are intentionally secondary; tests still match the labels.
        # The view model does not currently expose original/source/control paths
        # as first-class attributes on Stage — recover from snapshot JSON when
        # present via selected stage id lookup is handled by callers that still
        # need bash path printing. Keep producer/source labels above.

    # Contextual operator commands derived from diagnosis (secondary).
    reason = diagnosis.reason_code
    retryable = diagnosis.retryable
    request_id = diagnosis.request_id or (stage.request_id if stage else None)
    request_kind = diagnosis.request_kind or ""

    if reason == "operator-input" and request_id and not retryable:
        secondary.append(
            _line(
                style,
                "Respond",
                _respond_command(run.run_id, request_id, "input"),
                value_role="command",
            )
        )
    if reason == "human-approval":
        if retryable:
            secondary.append(
                _line(style, "Resume", f"ralph workflow resume {run.run_id}", value_role="command")
            )
        elif request_id:
            secondary.append(
                _line(
                    style,
                    "Decisions",
                    f"ralph workflow actions list {run.run_id}",
                    value_role="command",
                )
            )
    if reason == "operator-request" and retryable and diagnosis.state == "waiting":
        if stage is not None:
            resume_at = f"stage {stage.id}"
            todo = _clean(stage.progress.current_todo_id or "")
            if todo:
                resume_at = f"{resume_at} TODO {todo}"
            if stage.progress.total:
                resume_at = f"{resume_at} ({stage.progress.completed}/{stage.progress.total})"
            secondary.append(_line(style, "Resumes at", resume_at))
        secondary.append(
            _line(style, "Resume", f"ralph workflow resume {run.run_id}", value_role="command")
        )
    if request_kind == "input" and retryable:
        secondary.append(
            _line(style, "Resume", f"ralph workflow resume {run.run_id}", value_role="command")
        )

    # Handoff / terminal-hold cues (workflow-specific, secondary).
    stage_ids = {s.id for s in snapshot.stages}
    implement_done = any(s.id == "implement" and s.state == "succeeded" for s in snapshot.stages)
    if diagnosis.state in {"running", "waiting"} and implement_done and "review" in stage_ids:
        secondary.append(_line(style, "Handoff", "independent review/QA at stage review"))
    elif diagnosis.state in {"running", "waiting"} and implement_done and "qa" in stage_ids:
        secondary.append(_line(style, "Handoff", "independent QA at stage qa"))
    if run.workflow_id == "human-verified-delivery":
        if diagnosis.stage_id == "approve-result" and reason == "human-approval":
            secondary.append(
                _line(
                    style,
                    "Terminal hold",
                    "human-verified success held until result approval at stage approve-result",
                    value_role="warning",
                )
            )
        elif any(s.id == "approve-result" and s.state == "waiting" for s in snapshot.stages):
            secondary.append(
                _line(
                    style,
                    "Terminal hold",
                    "human-verified success held until result approval at stage approve-result",
                    value_role="warning",
                )
            )

    logs_stage = ""
    if stage is not None:
        logs_stage = stage.id
    elif diagnosis.stage_id:
        logs_stage = diagnosis.stage_id
    else:
        for candidate in snapshot.stages:
            if candidate.state == "running":
                logs_stage = candidate.id
                break
    secondary.append(
        _line(style, "Status", f"ralph workflow status {run.run_id}", value_role="command")
    )
    if logs_stage:
        secondary.append(
            _line(
                style,
                "Logs",
                f"ralph workflow logs {run.run_id} --stage {logs_stage}",
                value_role="command",
            )
        )
    else:
        secondary.append(
            _line(style, "Logs", f"ralph workflow logs {run.run_id}", value_role="command")
        )

    return tuple(primary + secondary)


def render_status_with_plan_paths(
    view: wt.WorkflowViewModel,
    status_payload: Mapping[str, Any],
    style: Optional[rt.Style] = None,
    *,
    width: int = 80,
) -> Tuple[str, ...]:
    """Status lines plus secondary plan/input paths from the raw public JSON."""

    lines = list(render_status_lines(view, style, width=width))
    style = style or rt.Style(rt.NO_COLOR)
    run_obj = status_payload.get("run") if isinstance(status_payload.get("run"), dict) else {}
    entry = str(run_obj.get("entryKind") or "")
    extras: list[str] = []

    if entry == "plan":
        input_plan = run_obj.get("inputPlan") if isinstance(run_obj.get("inputPlan"), dict) else {}
        original = input_plan.get("originalPath")
        source = input_plan.get("sourcePath")
        if original:
            extras.append(_line(style, "Original plan", _clean(original), value_role="path"))
        if source:
            extras.append(_line(style, "Supplied source", _clean(source), value_role="path"))

    stages = status_payload.get("stages") if isinstance(status_payload.get("stages"), list) else []
    selected_id = view.selected_stage_id
    stage_obj = None
    for item in stages:
        if isinstance(item, dict) and item.get("id") == selected_id:
            stage_obj = item
            break
    if stage_obj is None and stages and isinstance(stages[0], dict):
        # Fall back to diagnosis stage already selected by the view model.
        for item in stages:
            if isinstance(item, dict) and item.get("id") == (view.diagnosis.stage_id if view.diagnosis else None):
                stage_obj = item
                break

    if isinstance(stage_obj, dict) and stage_obj.get("stageKind") == "plan-backed":
        original = stage_obj.get("originalPlanPath")
        source = stage_obj.get("sourcePlanPath")
        control = stage_obj.get("controlPlanPath")
        if original and not any(line.startswith("Original plan:") or "Original plan:" in line for line in lines + extras):
            extras.append(_line(style, "Original plan", _clean(original), value_role="path"))
        if source and not any("Supplied source:" in line for line in lines + extras):
            extras.append(_line(style, "Supplied source", _clean(source), value_role="path"))
        if control:
            extras.append(_line(style, "Control plan", _clean(control), value_role="path"))

    if not extras:
        return tuple(lines)

    # Insert path extras after the Task line (or after Run when no task).
    insert_at = len(lines)
    for idx, line in enumerate(lines):
        plain = rt.strip_ansi(line)
        if plain.startswith("Task:") or plain.startswith("Run:"):
            insert_at = idx + 1
    if insert_at < len(lines) and rt.strip_ansi(lines[insert_at - 1]).startswith("Run:"):
        # Prefer after Task when present; otherwise keep after Run.
        pass
    return tuple(lines[:insert_at] + extras + lines[insert_at:])


def parse_run_row(obj: Mapping[str, Any]) -> RunListRow:
    return RunListRow(
        run_id=_clean(obj.get("runId") or ""),
        workflow_id=_clean(obj.get("workflowId") or "-") or "-",
        mode=_clean(obj.get("mode") or ""),
        entry_kind=_clean(obj.get("entryKind") or ""),
        state=_clean(obj.get("state") or ""),
        created_at=_clean(obj.get("createdAt") or ""),
        updated_at=_clean(obj.get("updatedAt") or obj.get("createdAt") or ""),
        task=_clean(obj.get("task") or ""),
    )


def render_runs_tsv(rows: Sequence[RunListRow]) -> Tuple[str, ...]:
    """Byte-stable machine TSV: runId, workflowId, mode, entryKind, state, createdAt."""

    out: list[str] = []
    for row in rows:
        fields = [
            row.run_id,
            row.workflow_id or "-",
            row.mode,
            row.entry_kind,
            row.state,
            row.created_at,
        ]
        out.append("\t".join(fields))
    return tuple(out)


def _age_label(stamp: str, now: datetime) -> str:
    return wl.format_last_update(stamp or None, now)


def render_runs_table(
    rows: Sequence[RunListRow],
    style: Optional[rt.Style] = None,
    *,
    width: int = 80,
    now: Optional[datetime] = None,
) -> Tuple[str, ...]:
    """Aligned TTY table: ID, WORKFLOW, MODE, STATE, AGE, TASK."""

    style = style or rt.Style(rt.NO_COLOR)
    now = now or datetime.now(timezone.utc)
    if not rows:
        return ("No workflow runs found.",)

    width = max(40, int(width))
    gap = 2
    gaps = gap * 5

    # Start from content maxima, then shrink fixed columns to fit width.
    id_w = max(len("ID"), max((len(r.run_id) for r in rows), default=0))
    wf_w = max(len("WORKFLOW"), max((len(r.workflow_id) for r in rows), default=0))
    mode_w = max(len("MODE"), max((len(r.mode) for r in rows), default=0))
    state_w = max(len("STATE"), max((len(r.state) for r in rows), default=0))
    ages = [_age_label(r.updated_at or r.created_at, now) for r in rows]
    age_w = max(len("AGE"), max((len(a) for a in ages), default=0))

    # Reserve at least 8 columns for TASK when possible.
    task_min = 8 if width >= 56 else 4
    budget = width - gaps - task_min
    caps = {
        "id": 36 if width >= 100 else 24 if width >= 72 else 16,
        "wf": 18 if width >= 100 else 14 if width >= 72 else 10,
        "mode": 12 if width >= 72 else 8,
        "state": 10,
        "age": 10 if width >= 72 else 8,
    }
    id_w = min(id_w, caps["id"])
    wf_w = min(wf_w, caps["wf"])
    mode_w = min(mode_w, caps["mode"])
    state_w = min(state_w, caps["state"])
    age_w = min(age_w, caps["age"])

    fixed = id_w + wf_w + mode_w + state_w + age_w
    while fixed > budget and (id_w > 12 or wf_w > 8 or mode_w > 6):
        if id_w >= wf_w and id_w > 12:
            id_w -= 1
        elif wf_w > 8:
            wf_w -= 1
        elif mode_w > 6:
            mode_w -= 1
        else:
            break
        fixed = id_w + wf_w + mode_w + state_w + age_w
    task_w = max(task_min, width - gaps - fixed)

    header = (
        f"{'ID':<{id_w}}  {'WORKFLOW':<{wf_w}}  {'MODE':<{mode_w}}  "
        f"{'STATE':<{state_w}}  {'AGE':<{age_w}}  {'TASK':<{task_w}}"
    )
    rule = (
        f"{'-' * id_w}  {'-' * wf_w}  {'-' * mode_w}  "
        f"{'-' * state_w}  {'-' * age_w}  {'-' * task_w}"
    )
    lines = [
        style.wrap("heading", rt.clip_text(header, width)) if style.depth > 0 else rt.clip_text(header, width),
        style.wrap("muted", rt.clip_text(rule, width)) if style.depth > 0 else rt.clip_text(rule, width),
    ]

    for row, age in zip(rows, ages):
        run_id = rt.clip_text(row.run_id, id_w, pad=True)
        workflow = rt.clip_text(row.workflow_id, wf_w, pad=True)
        mode = rt.clip_text(row.mode, mode_w, pad=True)
        age_plain = rt.clip_text(age, age_w, pad=True)
        task = rt.clip_text(row.task, task_w, pad=False)
        state_role = wl.outcome_role(row.state)
        state_vis = rt.pad_line(
            style.wrap(state_role, row.state) if style.depth > 0 else row.state,
            state_w,
        )
        age_vis = style.wrap("muted", age_plain) if style.depth > 0 else age_plain
        if style.depth > 0 and rt.visible_len(age_vis) < age_w:
            age_vis = age_vis + (" " * (age_w - rt.visible_len(age_vis)))
        line = f"{run_id}  {workflow}  {mode}  {state_vis}  {age_vis}  {task}"
        lines.append(rt.clip_text(line, width) if rt.visible_len(line) > width else line.rstrip())
    return tuple(lines)


def _parse_now(value: Optional[str]) -> datetime:
    if not value:
        return datetime.now(timezone.utc)
    parsed = wl.parse_iso_utc(value)
    return parsed or datetime.now(timezone.utc)


def render_handoff_lines(
    view: wt.WorkflowViewModel,
    style: Optional[rt.Style] = None,
) -> Tuple[str, ...]:
    """Render a standalone, copyable task-salvage report for another operator."""

    style = style or rt.Style(rt.NO_COLOR)
    if view.snapshot is None or view.run is None or view.diagnosis is None:
        return ("Workflow task handoff", _line(style, "Outcome", "unavailable", value_role="failure"))
    snapshot = view.snapshot
    run = view.run
    diagnosis = view.diagnosis
    outcome_state = wl.effective_outcome_state(run.state, diagnosis.state)
    failed_stage = _stage_by_id(snapshot, diagnosis.stage_id or "")
    reset_target = _stage_reset_target(snapshot.next_action)
    lines = [
        style.wrap("heading", "Workflow task handoff") if style.depth > 0 else "Workflow task handoff",
        _line(style, "Run", run.run_id, value_role="path"),
        _line(style, "Workflow", run.workflow_id or "-"),
        _line(style, "Outcome", f"{outcome_state} ({diagnosis.reason_code})", value_role="failure"),
        _line(style, "Task", _clean(run.task, limit=1000)),
    ]
    if diagnosis.summary:
        lines.append(_line(style, "Failure", _clean(diagnosis.summary, limit=1000), value_role="warning"))
    if diagnosis.stage_id:
        lines.append(_line(style, "Failed stage", diagnosis.stage_id, value_role="failure"))
    if failed_stage is not None and failed_stage.artifacts:
        verdict = failed_stage.artifacts[0]
        lines.append(_line(style, "Review verdict", verdict, value_role="path"))
        lines.append(
            _line(
                style,
                "Requested changes",
                f"jq -r '.feedback[]' {shlex.quote(verdict)}",
                value_role="command",
            )
        )

    lines.append(style.wrap("heading", "Code produced") if style.depth > 0 else "Code produced")
    lines.extend(_code_handoff_lines(style, _task_code_stage(snapshot)))

    lines.append(style.wrap("heading", "Continue the task") if style.depth > 0 else "Continue the task")
    if reset_target:
        lines.append(
            _line(
                style,
                "Preview",
                f"ralph workflow reset {run.run_id} --stage {reset_target} --dry-run",
                value_role="command",
            )
        )
        lines.append(
            _line(
                style,
                "Retry",
                f"ralph workflow reset {run.run_id} --stage {reset_target}",
                value_role="command",
            )
        )
        lines.append(
            _line(
                style,
                "Resume",
                f"ralph workflow resume {run.run_id}",
                value_role="command",
            )
        )
    else:
        lines.append(_line(style, "Retry", _action_command(snapshot.next_action), value_role="command"))
    log_stage = diagnosis.stage_id or (_task_code_stage(snapshot).id if _task_code_stage(snapshot) else "")
    if log_stage:
        lines.append(
            _line(
                style,
                "Failure logs",
                f"ralph workflow logs {run.run_id} --stage {log_stage}",
                value_role="command",
            )
        )
    if run.workflow_id:
        task_argument = " ".join(run.task.split())
        lines.append(
            _line(
                style,
                "Start new run",
                f"ralph workflow start {shlex.quote(run.workflow_id)} --task {shlex.quote(task_argument)}",
                value_role="command",
            )
        )
        lines.append(
            _line(
                style,
                "New-run note",
                "uses the code in the directory where it is started and re-resolves current workflow routing",
            )
        )
    lines.append(
        _line(
            style,
            "Routing",
            "runtime and model choices are frozen for this run; start a new run to change them",
        )
    )
    lines.append(
        _line(
            style,
            "Run access",
            "another Ralph process must use the same project and state root; this report does not export run state",
        )
    )
    lines.append(
        _line(
            style,
            "Agent instruction",
            f"Finish failed Ralph workflow {run.run_id}; inspect its status, verdict, and captured changes before editing.",
        )
    )
    return tuple(lines)


def _read_status_view() -> tuple[dict, wt.WorkflowViewModel]:
    payload = coerce_status_payload(json.loads(sys.stdin.read()))
    snapshot = wt.parse_status_snapshot(payload)
    return payload, wt.view_from_snapshot(snapshot)


def _cmd_status(argv: Sequence[str]) -> int:
    parser = argparse.ArgumentParser(prog="workflow_static.py status")
    parser.add_argument("--depth", type=int, choices=(0, 16, 256), default=None)
    parser.add_argument("--width", type=int, default=None)
    parser.add_argument("--force-color", action="store_true")
    args = parser.parse_args(list(argv))
    raw = sys.stdin.read()
    try:
        payload = coerce_status_payload(json.loads(raw))
        snapshot = wt.parse_status_snapshot(payload)
        view = wt.view_from_snapshot(snapshot)
    except (OSError, wt.SnapshotValidationError, ValueError, json.JSONDecodeError) as exc:
        print(f"Error: cannot render workflow status: {_clean(exc)}", file=sys.stderr)
        return 1
    style, width = resolve_style(
        depth=args.depth,
        width=args.width,
        force_color=args.force_color,
        stdout_isatty=sys.stdout.isatty(),
    )
    lines = render_status_with_plan_paths(view, payload, style, width=width)
    print("\n".join(lines))
    return 0


def _cmd_handoff(argv: Sequence[str]) -> int:
    parser = argparse.ArgumentParser(prog="workflow_static.py handoff")
    parser.add_argument("--depth", type=int, choices=(0, 16, 256), default=None)
    parser.add_argument("--force-color", action="store_true")
    args = parser.parse_args(list(argv))
    try:
        _payload, view = _read_status_view()
    except (OSError, wt.SnapshotValidationError, ValueError, json.JSONDecodeError) as exc:
        print(f"Error: cannot render workflow handoff: {_clean(exc)}", file=sys.stderr)
        return 1
    style, _width = resolve_style(
        depth=args.depth,
        force_color=args.force_color,
        stdout_isatty=sys.stdout.isatty(),
    )
    print("\n".join(render_handoff_lines(view, style)))
    return 0


def _cmd_runs_tsv(argv: Sequence[str]) -> int:
    parser = argparse.ArgumentParser(prog="workflow_static.py runs-tsv")
    parser.parse_args(list(argv))
    raw = sys.stdin.read().strip()
    if not raw:
        return 0
    try:
        payload = json.loads(raw)
    except json.JSONDecodeError as exc:
        print(f"Error: cannot render workflow runs: {_clean(exc)}", file=sys.stderr)
        return 1
    if not isinstance(payload, list):
        print("Error: runs input must be a JSON array", file=sys.stderr)
        return 1
    rows = [parse_run_row(item) for item in payload if isinstance(item, dict)]
    print("\n".join(render_runs_tsv(rows)))
    return 0


def _cmd_runs_table(argv: Sequence[str]) -> int:
    parser = argparse.ArgumentParser(prog="workflow_static.py runs-table")
    parser.add_argument("--depth", type=int, choices=(0, 16, 256), default=None)
    parser.add_argument("--width", type=int, default=None)
    parser.add_argument("--force-color", action="store_true")
    parser.add_argument("--now", default=None, help="ISO timestamp for deterministic ages")
    args = parser.parse_args(list(argv))
    raw = sys.stdin.read().strip()
    if not raw:
        style, width = resolve_style(
            depth=args.depth,
            width=args.width,
            force_color=args.force_color,
            stdout_isatty=sys.stdout.isatty(),
        )
        print("\n".join(render_runs_table((), style, width=width, now=_parse_now(args.now))))
        return 0
    try:
        payload = json.loads(raw)
    except json.JSONDecodeError as exc:
        print(f"Error: cannot render workflow runs: {_clean(exc)}", file=sys.stderr)
        return 1
    if not isinstance(payload, list):
        print("Error: runs input must be a JSON array", file=sys.stderr)
        return 1
    rows = [parse_run_row(item) for item in payload if isinstance(item, dict)]
    style, width = resolve_style(
        depth=args.depth,
        width=args.width,
        force_color=args.force_color,
        stdout_isatty=sys.stdout.isatty(),
    )
    print("\n".join(render_runs_table(rows, style, width=width, now=_parse_now(args.now))))
    return 0


def main(argv: Sequence[str]) -> int:
    if not argv:
        print(
            "Usage: workflow_static.py <status|handoff|runs-table|runs-tsv> [options]",
            file=sys.stderr,
        )
        return 2
    cmd, rest = argv[0], argv[1:]
    if cmd == "status":
        return _cmd_status(rest)
    if cmd == "handoff":
        return _cmd_handoff(rest)
    if cmd == "runs-table":
        return _cmd_runs_table(rest)
    if cmd == "runs-tsv":
        return _cmd_runs_tsv(rest)
    print(
        "Usage: workflow_static.py <status|handoff|runs-table|runs-tsv> [options]",
        file=sys.stderr,
    )
    return 2


if __name__ == "__main__":
    raise SystemExit(main(tuple(sys.argv[1:])))
