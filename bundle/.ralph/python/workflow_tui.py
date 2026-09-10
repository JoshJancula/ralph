#!/usr/bin/env python3
"""Engine-neutral read model for the public workflow terminal UI.

The loader deliberately knows only the public ``ralph workflow status`` JSON
contract.  It never locates or reads a Sequential or Dependency engine tree.
"""

from __future__ import annotations

import json
import re
import subprocess
from dataclasses import dataclass, replace
from typing import Any, Mapping, Optional, Sequence, Tuple


PUBLIC_STATUS_SCHEMA_VERSION = 1
# One refresh shells out to `ralph workflow status`, a bash CLI that sources a
# large library set before it prints anything. The machine most likely to be
# busy is the one running the workflow you are watching, so a tight budget
# fails exactly when the viewer is most wanted. RALPH_WORKFLOW_STATUS_TIMEOUT
# overrides it for slow hosts and for tests that want a deterministic bound.
def _default_status_timeout() -> float:
    import os as _os

    raw = str(_os.environ.get("RALPH_WORKFLOW_STATUS_TIMEOUT") or "").strip()
    if raw:
        try:
            value = float(raw)
        except ValueError:
            value = 0.0
        if value > 0:
            return value
    return 20.0


DEFAULT_STATUS_TIMEOUT_SECONDS = _default_status_timeout()

# Error kinds a retry can plausibly clear. invalid-run-id and invalid-timeout
# are deterministic caller errors and must fail immediately instead.
TRANSIENT_ERROR_KINDS = frozenset({"timeout", "unavailable"})

RUN_STATES = frozenset(
    {"queued", "running", "waiting", "blocked", "stale", "failed", "cancelled", "succeeded"}
)
STAGE_STATES = RUN_STATES | frozenset({"skipped"})
STAGE_KINDS = frozenset({"executable", "plan-backed", "approval", "supervisor"})
WORKFLOW_MODES = frozenset({"sequential", "dependency"})


class SnapshotValidationError(ValueError):
    """Raised by the strict public-snapshot parser, never by the safe loader."""


@dataclass(frozen=True)
class UiError:
    code: str
    message: str
    detail: str = ""


@dataclass(frozen=True)
class NextAction:
    label: str
    argv: Tuple[str, ...]


@dataclass(frozen=True)
class Progress:
    completed: int
    total: int
    current_todo_id: Optional[str] = None

    @property
    def fraction(self) -> Optional[float]:
        if self.total <= 0:
            return None
        return min(self.completed, self.total) / self.total


@dataclass(frozen=True)
class RunSummary:
    run_id: str
    workflow_id: Optional[str]
    mode: str
    entry_kind: str
    task: str
    task_provenance: str
    state: str
    source_kind: str
    created_at: str
    updated_at: str
    input_progress: Optional[Progress]


@dataclass(frozen=True)
class StageDependency:
    stage_id: str
    condition: Optional[str] = None


@dataclass(frozen=True)
class Stage:
    id: str
    index: int
    state: str
    kind: str
    attempt: int
    progress: Progress
    wave: Optional[int]
    terminal_result: Optional[str]
    reason_code: Optional[str]
    plan_source_kind: Optional[str]
    plan_source_stage_id: Optional[str]
    dependencies: Tuple[StageDependency, ...]
    artifacts: Tuple[str, ...]
    workspace_mode: Optional[str]
    workspace_path: Optional[str]
    workspace_available: bool
    base_revision: Optional[str]
    changeset_manifest: Optional[str]
    changed_files: Tuple[str, ...]
    evidence: Tuple[str, ...]
    blocker_kind: Optional[str]
    blocker_reason_code: Optional[str]
    request_id: Optional[str]
    request_state: Optional[str]
    request_question: Optional[str]
    approval_question: Optional[str]
    changes_target: Optional[str]
    created_at: Optional[str]
    updated_at: Optional[str]


@dataclass(frozen=True)
class Diagnosis:
    state: str
    reason_code: str
    summary: str
    stage_id: Optional[str]
    request_kind: Optional[str]
    request_id: Optional[str]
    evidence: Tuple[str, ...]
    retryable: bool
    next_action: Optional[NextAction]


@dataclass(frozen=True)
class WorkflowSnapshot:
    run: RunSummary
    stages: Tuple[Stage, ...]
    diagnosis: Diagnosis
    next_action: Optional[NextAction]


def topology_ordered_stages(snapshot: WorkflowSnapshot) -> Tuple[Stage, ...]:
    """Return Dependency stages in stable prerequisite-first order.

    Public Dependency projections are not required to arrive in graph order.
    The frozen graph is acyclic (rework is compile-time unrolled), so a stable
    topological order gives both the tree renderer and keyboard navigation one
    operator-readable sequence. Sequential workflows retain authored order.
    """

    if snapshot.run.mode != "dependency":
        return snapshot.stages
    known = {stage.id for stage in snapshot.stages}
    original_position = {stage.id: position for position, stage in enumerate(snapshot.stages)}
    remaining = {stage.id: stage for stage in snapshot.stages}
    emitted: list[Stage] = []
    emitted_ids: set[str] = set()
    while remaining:
        ready = [
            stage
            for stage in remaining.values()
            if all(
                dependency.stage_id not in known or dependency.stage_id in emitted_ids
                for dependency in stage.dependencies
            )
        ]
        if not ready:
            # Defensive fallback for malformed snapshots. Validation owns cycle
            # rejection; the viewer must still remain navigable if one leaks in.
            ready = list(remaining.values())
        ready.sort(key=lambda stage: (original_position[stage.id], stage.id))
        for stage in ready:
            emitted.append(stage)
            emitted_ids.add(stage.id)
            remaining.pop(stage.id, None)
    return tuple(emitted)


def deferred_progress_stage_ids(snapshot: WorkflowSnapshot) -> frozenset[str]:
    """Return never-entered conditional futures hidden from live progress.

    Dependency workflows freeze every possible route before execution.  That
    topology is valuable to the supervisor, but presenting every unchosen
    approval and rework route as pending work makes the operator-facing tree
    misleading.  A conditional route becomes visible once it records an
    attempt or leaves its initial queued/skipped state; its ordinary
    descendants are revealed with it.
    """

    if snapshot.run.mode != "dependency":
        return frozenset()
    deferred = {
        stage.id
        for stage in snapshot.stages
        if stage.state in {"queued", "skipped"}
        and stage.attempt == 0
        and any(dependency.condition for dependency in stage.dependencies)
    }
    changed = True
    while changed:
        changed = False
        for stage in snapshot.stages:
            if (
                stage.id in deferred
                or stage.state not in {"queued", "skipped"}
                or stage.attempt > 0
            ):
                continue
            if any(dependency.stage_id in deferred for dependency in stage.dependencies):
                deferred.add(stage.id)
                changed = True
    return frozenset(deferred)


def revealed_progress_stages(snapshot: WorkflowSnapshot) -> Tuple[Stage, ...]:
    """Return the operator-visible execution path in prerequisite-first order."""

    ordered = topology_ordered_stages(snapshot)
    deferred = deferred_progress_stage_ids(snapshot)
    return tuple(stage for stage in ordered if stage.id not in deferred)


@dataclass(frozen=True)
class WorkflowViewModel:
    snapshot: Optional[WorkflowSnapshot]
    selected_stage_id: Optional[str]
    error: Optional[UiError] = None

    @property
    def run(self) -> Optional[RunSummary]:
        return self.snapshot.run if self.snapshot else None

    @property
    def stages(self) -> Tuple[Stage, ...]:
        return self.snapshot.stages if self.snapshot else ()

    @property
    def diagnosis(self) -> Optional[Diagnosis]:
        return self.snapshot.diagnosis if self.snapshot else None

    @property
    def next_action(self) -> Optional[NextAction]:
        return self.snapshot.next_action if self.snapshot else None

    @property
    def selected_stage(self) -> Optional[Stage]:
        if self.selected_stage_id is None:
            return None
        return next((stage for stage in self.stages if stage.id == self.selected_stage_id), None)


def _object(value: Any, path: str) -> Mapping[str, Any]:
    if not isinstance(value, dict):
        raise SnapshotValidationError(f"{path} must be an object")
    return value


def _required(obj: Mapping[str, Any], key: str, path: str) -> Any:
    if key not in obj:
        raise SnapshotValidationError(f"{path}.{key} is required")
    return obj[key]


def _string(
    value: Any, path: str, *, nullable: bool = False, allow_empty: bool = False
) -> Optional[str]:
    if value is None and nullable:
        return None
    if not isinstance(value, str) or (not value and not allow_empty):
        qualifier = "a string" if allow_empty else "a non-empty string"
        raise SnapshotValidationError(f"{path} must be {qualifier}")
    return value


def _optional_string(
    obj: Mapping[str, Any], key: str, path: str, *, allow_empty: bool = False
) -> Optional[str]:
    value = obj.get(key)
    if value is None:
        return None
    return _string(value, f"{path}.{key}", allow_empty=allow_empty)


def _integer(value: Any, path: str, *, minimum: int = 0) -> int:
    if isinstance(value, bool) or not isinstance(value, int) or value < minimum:
        raise SnapshotValidationError(f"{path} must be an integer greater than or equal to {minimum}")
    return value


def _optional_integer(obj: Mapping[str, Any], key: str, path: str) -> Optional[int]:
    value = obj.get(key)
    if value is None:
        return None
    return _integer(value, f"{path}.{key}")


def _string_array(value: Any, path: str) -> Tuple[str, ...]:
    if not isinstance(value, list):
        raise SnapshotValidationError(f"{path} must be an array")
    result = []
    for index, item in enumerate(value):
        result.append(_string(item, f"{path}[{index}]") or "")
    return tuple(result)


def _evidence_label(value: Any, path: str) -> str:
    if isinstance(value, str) and value:
        return value
    if isinstance(value, dict):
        for key in ("summary", "label", "message", "path"):
            candidate = value.get(key)
            if isinstance(candidate, str) and candidate:
                return candidate
        return json.dumps(value, sort_keys=True, separators=(",", ":"), default=str)
    raise SnapshotValidationError(f"{path} must be a string or object")


def _stage_dependencies(value: Any, path: str) -> Tuple[StageDependency, ...]:
    if not isinstance(value, list):
        raise SnapshotValidationError(f"{path} must be an array")
    result = []
    for index, item in enumerate(value):
        item_path = f"{path}[{index}]"
        obj = _object(item, item_path)
        stage_id = _string(_required(obj, "stageId", item_path), f"{item_path}.stageId") or ""
        condition = _optional_string(obj, "condition", item_path, allow_empty=True)
        result.append(StageDependency(stage_id=stage_id, condition=condition or None))
    return tuple(result)


def _next_action(value: Any, path: str) -> Optional[NextAction]:
    if value is None:
        return None
    obj = _object(value, path)
    label = _string(_required(obj, "label", path), f"{path}.label") or ""
    argv = _string_array(_required(obj, "argv", path), f"{path}.argv")
    return NextAction(label=label, argv=argv)


def _parse_run(value: Any) -> RunSummary:
    path = "run"
    obj = _object(value, path)
    required = (
        "runId",
        "workflowId",
        "mode",
        "entryKind",
        "task",
        "taskProvenance",
        "sourcePath",
        "sourceKind",
        "state",
        "inputPath",
        "inputPlan",
        "createdAt",
        "updatedAt",
    )
    for key in required:
        _required(obj, key, path)

    mode = _string(obj["mode"], "run.mode") or ""
    if mode not in WORKFLOW_MODES:
        raise SnapshotValidationError("run.mode must be sequential or dependency")
    state = _string(obj["state"], "run.state") or ""
    if state not in RUN_STATES:
        raise SnapshotValidationError(f"run.state is unsupported: {state}")
    entry_kind = _string(obj["entryKind"], "run.entryKind") or ""
    if entry_kind not in {"task", "plan"}:
        raise SnapshotValidationError("run.entryKind must be task or plan")

    workflow_id = _string(obj["workflowId"], "run.workflowId", nullable=True, allow_empty=True)
    input_progress = None
    if obj["inputPlan"] is not None:
        plan = _object(obj["inputPlan"], "run.inputPlan")
        completed = _integer(plan.get("completedTodos", 0), "run.inputPlan.completedTodos")
        total = _integer(plan.get("totalTodos", 0), "run.inputPlan.totalTodos")
        input_progress = Progress(completed=completed, total=total)

    # Validate required public strings even when the current view does not render
    # each one. This prevents a partial record from becoming a misleading frame.
    _string(obj["sourcePath"], "run.sourcePath")
    _string(obj["inputPath"], "run.inputPath")
    return RunSummary(
        run_id=_string(obj["runId"], "run.runId") or "",
        workflow_id=workflow_id,
        mode=mode,
        entry_kind=entry_kind,
        task=_string(obj["task"], "run.task") or "",
        task_provenance=_string(obj["taskProvenance"], "run.taskProvenance") or "",
        state=state,
        source_kind=_string(obj["sourceKind"], "run.sourceKind") or "",
        created_at=_string(obj["createdAt"], "run.createdAt") or "",
        updated_at=_string(obj["updatedAt"], "run.updatedAt") or "",
        input_progress=input_progress,
    )


def _parse_stage(value: Any, source_index: int) -> Stage:
    path = f"stages[{source_index}]"
    obj = _object(value, path)
    stage_id = _string(_required(obj, "id", path), f"{path}.id") or ""
    state = _string(_required(obj, "state", path), f"{path}.state") or ""
    if state not in STAGE_STATES:
        raise SnapshotValidationError(f"{path}.state is unsupported: {state}")
    kind = _string(_required(obj, "stageKind", path), f"{path}.stageKind") or ""
    if kind not in STAGE_KINDS:
        raise SnapshotValidationError(f"{path}.stageKind is unsupported: {kind}")

    declared_index = _optional_integer(obj, "index", path)
    completed = _integer(obj.get("completedTodos", 0), f"{path}.completedTodos")
    total = _integer(obj.get("totalTodos", 0), f"{path}.totalTodos")
    blocker = obj.get("blocker")
    blocker_obj: Mapping[str, Any] = {}
    if blocker is not None:
        blocker_obj = _object(blocker, f"{path}.blocker")
    approval = obj.get("approval")
    approval_obj: Mapping[str, Any] = {}
    if approval is not None:
        approval_obj = _object(approval, f"{path}.approval")

    artifacts = _string_array(obj.get("artifacts", []), f"{path}.artifacts")
    workspace_mode = _optional_string(obj, "workspaceMode", path)
    if workspace_mode not in {None, "shared", "snapshot", "worktree"}:
        raise SnapshotValidationError(f"{path}.workspaceMode is unsupported: {workspace_mode}")
    workspace_available = obj.get("workspaceAvailable", False)
    if not isinstance(workspace_available, bool):
        raise SnapshotValidationError(f"{path}.workspaceAvailable must be a boolean")
    evidence_raw = obj.get("evidence", [])
    if not isinstance(evidence_raw, list):
        raise SnapshotValidationError(f"{path}.evidence must be an array")
    evidence = tuple(
        _evidence_label(item, f"{path}.evidence[{index}]") for index, item in enumerate(evidence_raw)
    )
    return Stage(
        id=stage_id,
        index=source_index if declared_index is None else declared_index,
        state=state,
        kind=kind,
        attempt=_integer(obj.get("attempt", 0), f"{path}.attempt"),
        progress=Progress(
            completed=completed,
            total=total,
            current_todo_id=_optional_string(obj, "currentTodoId", path, allow_empty=True),
        ),
        wave=_optional_integer(obj, "wave", path),
        terminal_result=_optional_string(obj, "terminalResult", path, allow_empty=True),
        reason_code=_optional_string(obj, "reasonCode", path, allow_empty=True),
        plan_source_kind=_optional_string(obj, "planSourceKind", path),
        plan_source_stage_id=_optional_string(obj, "planSourceStageId", path, allow_empty=True),
        dependencies=_stage_dependencies(obj.get("dependencies", []), f"{path}.dependencies"),
        artifacts=artifacts,
        workspace_mode=workspace_mode,
        workspace_path=_optional_string(obj, "workspacePath", path),
        workspace_available=workspace_available,
        base_revision=_optional_string(obj, "baseRevision", path, allow_empty=True),
        changeset_manifest=_optional_string(obj, "changesetManifest", path),
        changed_files=_string_array(obj.get("changedFiles", []), f"{path}.changedFiles"),
        evidence=evidence,
        blocker_kind=_optional_string(blocker_obj, "kind", f"{path}.blocker"),
        blocker_reason_code=_optional_string(blocker_obj, "reasonCode", f"{path}.blocker"),
        request_id=_optional_string(obj, "requestId", path)
        or _optional_string(blocker_obj, "requestId", f"{path}.blocker"),
        request_state=_optional_string(obj, "requestState", path),
        request_question=_optional_string(obj, "requestQuestion", path, allow_empty=True),
        approval_question=_optional_string(
            approval_obj, "question", f"{path}.approval", allow_empty=True
        ),
        changes_target=_optional_string(
            approval_obj, "changesTarget", f"{path}.approval", allow_empty=True
        )
        or _optional_string(blocker_obj, "changesTarget", f"{path}.blocker", allow_empty=True),
        created_at=_optional_string(obj, "createdAt", path),
        updated_at=_optional_string(obj, "updatedAt", path),
    )


def _parse_diagnosis(value: Any) -> Diagnosis:
    path = "diagnosis"
    obj = _object(value, path)
    for key in (
        "state",
        "reasonCode",
        "summary",
        "stageId",
        "requestKind",
        "requestId",
        "evidence",
        "retryable",
        "nextAction",
    ):
        _required(obj, key, path)
    state = _string(obj["state"], "diagnosis.state") or ""
    if state not in RUN_STATES:
        raise SnapshotValidationError(f"diagnosis.state is unsupported: {state}")
    retryable = obj["retryable"]
    if not isinstance(retryable, bool):
        raise SnapshotValidationError("diagnosis.retryable must be a boolean")
    return Diagnosis(
        state=state,
        reason_code=_string(obj["reasonCode"], "diagnosis.reasonCode") or "",
        summary=_string(obj["summary"], "diagnosis.summary", allow_empty=True) or "",
        stage_id=_string(obj["stageId"], "diagnosis.stageId", nullable=True),
        request_kind=_string(obj["requestKind"], "diagnosis.requestKind", nullable=True),
        request_id=_string(obj["requestId"], "diagnosis.requestId", nullable=True),
        evidence=_string_array(obj["evidence"], "diagnosis.evidence"),
        retryable=retryable,
        next_action=_next_action(obj["nextAction"], "diagnosis.nextAction"),
    )


def parse_status_snapshot(payload: Any) -> WorkflowSnapshot:
    """Parse one public status value, ignoring additive unknown fields."""

    root = _object(payload, "status")
    for key in ("schemaVersion", "run", "stages", "diagnosis", "nextAction"):
        _required(root, key, "status")
    version = _integer(root["schemaVersion"], "schemaVersion", minimum=1)
    if version != PUBLIC_STATUS_SCHEMA_VERSION:
        raise SnapshotValidationError(f"unsupported workflow status schema version: {version}")
    run = _parse_run(root["run"])
    raw_stages = root["stages"]
    if not isinstance(raw_stages, list):
        raise SnapshotValidationError("stages must be an array")
    indexed_stages = [(_parse_stage(item, position), position) for position, item in enumerate(raw_stages)]
    ids = [stage.id for stage, _ in indexed_stages]
    if len(ids) != len(set(ids)):
        raise SnapshotValidationError("stages must have unique ids")
    indexed_stages.sort(key=lambda item: (item[0].index, item[1]))
    diagnosis = _parse_diagnosis(root["diagnosis"])
    next_action = _next_action(root["nextAction"], "nextAction")
    return WorkflowSnapshot(
        run=run,
        stages=tuple(stage for stage, _ in indexed_stages),
        diagnosis=diagnosis,
        next_action=next_action,
    )


def parse_status_json(text: str) -> WorkflowSnapshot:
    try:
        payload = json.loads(text)
    except (json.JSONDecodeError, TypeError) as exc:
        raise SnapshotValidationError("workflow status returned malformed JSON") from exc
    return parse_status_snapshot(payload)


def primary_stage_id(snapshot: WorkflowSnapshot) -> Optional[str]:
    """Return the public stage needing attention, then the active stage."""

    known_ids = {stage.id for stage in snapshot.stages}
    if snapshot.diagnosis.stage_id in known_ids:
        return snapshot.diagnosis.stage_id
    for states in (("waiting", "failed", "blocked", "stale"), ("running",)):
        for stage in snapshot.stages:
            if stage.state in states:
                return stage.id
    return snapshot.stages[0].id if snapshot.stages else None


def view_from_snapshot(
    snapshot: WorkflowSnapshot, previous_selected_stage_id: Optional[str] = None
) -> WorkflowViewModel:
    """Pure selection reconciliation for a successfully parsed snapshot."""

    known_ids = {stage.id for stage in snapshot.stages}
    selected = previous_selected_stage_id if previous_selected_stage_id in known_ids else primary_stage_id(snapshot)
    return WorkflowViewModel(snapshot=snapshot, selected_stage_id=selected)


def reconcile_refresh(previous: WorkflowViewModel, refreshed: WorkflowSnapshot) -> WorkflowViewModel:
    """Purely reconcile a refreshed snapshot with the prior UI selection."""

    previous_selection = None
    if previous.run is not None and previous.run.run_id == refreshed.run.run_id:
        previous_selection = previous.selected_stage_id
    return view_from_snapshot(refreshed, previous_selection)


def status_command(run_id: str, command: Sequence[str] = ("ralph",)) -> Tuple[str, ...]:
    if not isinstance(run_id, str) or not run_id or "\x00" in run_id or run_id == "latest":
        raise ValueError("an exact workflow run id is required")
    prefix = tuple(command)
    if not prefix or any(not isinstance(part, str) or not part for part in prefix):
        raise ValueError("status command must contain at least one non-empty argv item")
    return prefix + ("workflow", "status", run_id, "--json")


def _safe_detail(stderr: Any) -> str:
    if not isinstance(stderr, str):
        return ""
    detail = re.sub(r"[\x00-\x1f\x7f]+", " ", stderr).strip()
    return detail[:240]


def _error_view(error: UiError, previous: Optional[WorkflowViewModel]) -> WorkflowViewModel:
    if previous is not None and previous.snapshot is not None:
        return replace(previous, error=error)
    return WorkflowViewModel(snapshot=None, selected_stage_id=None, error=error)


def _previous_for_run(
    previous: Optional[WorkflowViewModel], run_id: str
) -> Optional[WorkflowViewModel]:
    if previous is None or previous.run is None or previous.run.run_id != run_id:
        return None
    return previous


def load_workflow_view(
    run_id: str,
    *,
    previous: Optional[WorkflowViewModel] = None,
    timeout: float = DEFAULT_STATUS_TIMEOUT_SECONDS,
    command: Sequence[str] = ("ralph",),
) -> WorkflowViewModel:
    """Load one exact run through the public Bash CLI and return a safe UI value."""

    prior = _previous_for_run(previous, run_id)
    try:
        argv = status_command(run_id, command)
    except ValueError as exc:
        return _error_view(UiError("invalid-run-id", "An exact workflow run ID is required.", str(exc)), prior)
    if timeout <= 0:
        return _error_view(UiError("invalid-timeout", "Workflow status timeout must be positive."), prior)
    try:
        completed = subprocess.run(
            argv,
            capture_output=True,
            text=True,
            check=False,
            timeout=timeout,
        )
    except subprocess.TimeoutExpired:
        return _error_view(UiError("timeout", "Workflow status refresh timed out."), prior)
    except OSError as exc:
        return _error_view(
            UiError("unavailable", "Workflow status is unavailable.", _safe_detail(str(exc))), prior
        )
    if completed.returncode != 0:
        return _error_view(
            UiError("unavailable", "Workflow status is unavailable.", _safe_detail(completed.stderr)), prior
        )
    try:
        snapshot = parse_status_json(completed.stdout)
        if snapshot.run.run_id != run_id:
            raise SnapshotValidationError("returned run identity does not match the requested exact run id")
    except SnapshotValidationError as exc:
        code = "malformed-json" if "malformed JSON" in str(exc) else "invalid-snapshot"
        message = (
            "Workflow status returned malformed JSON."
            if code == "malformed-json"
            else "Workflow status data is incomplete or invalid."
        )
        return _error_view(UiError(code, message, str(exc)), prior)
    if prior is None:
        return view_from_snapshot(snapshot)
    return reconcile_refresh(prior, snapshot)
