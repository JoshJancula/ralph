#!/usr/bin/env python3
"""Primary responsive layout for the public workflow terminal UI.

Renders an engine-neutral frame from ``workflow_tui.WorkflowViewModel`` onto the
semantic canvas. The frame never embeds ANSI escapes or engine/namespace terms.
"""

from __future__ import annotations

import shlex
from dataclasses import dataclass
from datetime import datetime, timezone
from typing import Collection, Iterable, List, Optional, Sequence, Tuple

import workflow_canvas as wc
import workflow_logs as wlog
import workflow_tui as wt


COMPACT_SIZE = (40, 12)
STANDARD_SIZE = (80, 24)
WIDE_SIZE = (120, 40)

# Words and path fragments that must never appear in the primary operator frame.
FORBIDDEN_PRIMARY_TERMS = (
    "namespace",
    "ledger",
    "graph-run",
    "graph_run",
    "orchestration",
    "orch.json",
    "nodeid",
    "node_id",
    "wavefailures",
    "parallelstages",
    ".ralph-workspace",
    "engine.",
    "tui",
)


@dataclass(frozen=True)
class StageCounts:
    succeeded: int
    running: int
    waiting: int
    failed: int
    blocked: int
    queued: int
    other: int
    total: int

    @property
    def completed(self) -> int:
        return self.succeeded


@dataclass(frozen=True)
class StageListEntry:
    """One drawable row in the stage list (header or selectable stage)."""

    kind: str  # "wave" | "stage"
    label: str
    stage: Optional[wt.Stage] = None
    state_label: str = ""
    state_role: str = "muted"
    selected: bool = False


@dataclass(frozen=True)
class ProgressTreeNode:
    """One stage placed in the dependency tree through a primary parent."""

    stage: wt.Stage
    ancestor_continues: Tuple[bool, ...]
    is_last: bool
    incoming_condition: Optional[str]
    selected: bool


def layout_tier(width: int, height: int) -> str:
    """Return compact, standard, or wide for the tested responsive sizes."""

    width = max(0, int(width))
    height = max(0, int(height))
    if width >= WIDE_SIZE[0] and height >= WIDE_SIZE[1]:
        return "wide"
    if width >= STANDARD_SIZE[0] and height >= STANDARD_SIZE[1]:
        return "standard"
    return "compact"


def parse_iso_utc(value: Optional[str]) -> Optional[datetime]:
    if not value or not isinstance(value, str):
        return None
    text = value.strip()
    if not text:
        return None
    if text.endswith("Z"):
        text = text[:-1] + "+00:00"
    try:
        parsed = datetime.fromisoformat(text)
    except ValueError:
        return None
    if parsed.tzinfo is None:
        return parsed.replace(tzinfo=timezone.utc)
    return parsed.astimezone(timezone.utc)


def format_elapsed_seconds(seconds: int) -> str:
    """Compact human elapsed string used in the primary header."""

    total = max(0, int(seconds))
    hours, rem = divmod(total, 3600)
    minutes, secs = divmod(rem, 60)
    if hours:
        return f"{hours}h {minutes}m {secs}s"
    if minutes:
        return f"{minutes}m {secs}s"
    return f"{secs}s"


def format_elapsed(created_at: Optional[str], now: datetime) -> str:
    start = parse_iso_utc(created_at)
    if start is None:
        return "-"
    return format_elapsed_seconds(int((now - start).total_seconds()))


def run_duration_label(run: wt.RunSummary, now: datetime) -> str:
    """Elapsed wall time, frozen at the recorded end of a terminal run."""

    start = parse_iso_utc(run.created_at)
    if start is None:
        return "-"
    if run.state in {"succeeded", "failed", "cancelled"}:
        end = parse_iso_utc(run.updated_at) or now
    else:
        end = now
    return format_elapsed_seconds(max(0, int((end - start).total_seconds())))


def format_last_update(updated_at: Optional[str], now: datetime) -> str:
    stamp = parse_iso_utc(updated_at)
    if stamp is None:
        return "-"
    delta = int((now - stamp).total_seconds())
    if delta < 0:
        delta = 0
    if delta < 5:
        return "just now"
    if delta < 60:
        return f"{delta}s ago"
    if delta < 3600:
        return f"{delta // 60}m ago"
    if delta < 86400:
        return f"{delta // 3600}h ago"
    return f"{delta // 86400}d ago"


def mode_label(mode: str) -> str:
    if mode == "sequential":
        return "Sequential"
    if mode == "dependency":
        return "Dependency"
    return wc.sanitize_text(mode).title() or "Workflow"


def outcome_badge(state: str) -> str:
    """Non-color outcome word; uppercase so state remains readable without color."""

    mapping = {
        "queued": "QUEUED",
        "running": "RUNNING",
        "waiting": "WAITING",
        "blocked": "BLOCKED",
        "stale": "STALE",
        "failed": "FAILED",
        "cancelled": "CANCELLED",
        "succeeded": "SUCCEEDED",
        "skipped": "SKIPPED",
    }
    return mapping.get(state, wc.sanitize_text(state).upper() or "UNKNOWN")


def effective_outcome_state(run_state: str, diagnosis_state: str) -> str:
    """Prefer the authoritative outer outcome once a run is terminal.

    A failed stage is diagnosed as ``blocked`` because no further stage can be
    scheduled, while the outer workflow is correctly persisted as ``failed``.
    Operator-facing views must lead with that terminal workflow outcome and
    retain the diagnosis reason as the explanation.
    """

    if run_state in {"succeeded", "failed", "cancelled"}:
        return run_state
    return diagnosis_state or run_state


def outcome_role(state: str, reason_code: str = "") -> str:
    if state == "failed" or reason_code in {"stage-failed"}:
        return "failure"
    if state == "succeeded":
        return "success"
    if state in {"waiting", "stale", "blocked"}:
        return "warning"
    if state == "running":
        return "accent"
    return "muted"


def public_state_label(state: str) -> str:
    known = {
        "queued": "queued",
        "running": "running",
        "waiting": "waiting",
        "blocked": "blocked",
        "stale": "stale",
        "failed": "failed",
        "cancelled": "cancelled",
        "succeeded": "succeeded",
        "skipped": "skipped",
    }
    return known.get(state, wc.sanitize_text(state) or "unknown")


def is_derived_downstream_block(
    stage: wt.Stage, diagnosis: Optional[wt.Diagnosis]
) -> bool:
    """True when a blocked stage is muted derived blocking, not the primary fault."""

    if stage.state != "blocked":
        return False
    if diagnosis is not None and diagnosis.stage_id == stage.id:
        return False
    if stage.terminal_result == "failed":
        return False
    return True


def stage_state_role(stage: wt.Stage, diagnosis: Optional[wt.Diagnosis]) -> str:
    if stage.state == "failed" or stage.terminal_result == "failed":
        return "failure"
    if stage.state == "blocked":
        if is_derived_downstream_block(stage, diagnosis):
            return "muted"
        return "warning"
    if stage.state == "succeeded":
        return "success"
    if stage.state == "skipped":
        return "muted"
    if stage.state == "running":
        return "accent"
    if stage.state in {"waiting", "stale"}:
        return "warning"
    return "muted"


def count_stages(stages: Sequence[wt.Stage]) -> StageCounts:
    buckets = {
        "succeeded": 0,
        "running": 0,
        "waiting": 0,
        "failed": 0,
        "blocked": 0,
        "queued": 0,
        "other": 0,
    }
    for stage in stages:
        if stage.state in buckets:
            buckets[stage.state] += 1
        else:
            buckets["other"] += 1
    return StageCounts(
        succeeded=buckets["succeeded"],
        running=buckets["running"],
        waiting=buckets["waiting"],
        failed=buckets["failed"],
        blocked=buckets["blocked"],
        queued=buckets["queued"],
        other=buckets["other"],
        total=len(stages),
    )


def lifecycle_groups(
    stages: Sequence[wt.Stage],
) -> Tuple[Tuple[str, str, Tuple[wt.Stage, ...]], ...]:
    """Group public stages for an operator-readable lifecycle summary.

    Dependency workflows are not linear step counters: compiled rework and
    join nodes may execute conditionally. Grouping the concrete stage names by
    current state communicates both what happened and what remains without
    implying that ``succeeded / total`` is an ordinal position.
    """

    specifications = (
        ("Failed", "failure", frozenset({"failed"})),
        ("Active", "accent", frozenset({"running"})),
        ("Waiting", "warning", frozenset({"waiting"})),
        ("Blocked", "warning", frozenset({"blocked", "stale"})),
        ("Complete", "success", frozenset({"succeeded"})),
        ("Skipped", "muted", frozenset({"skipped"})),
        ("Pending", "muted", frozenset({"queued"})),
        ("Cancelled", "muted", frozenset({"cancelled"})),
    )
    groups: List[Tuple[str, str, Tuple[wt.Stage, ...]]] = []
    covered = set()
    for label, role, states in specifications:
        matched = tuple(stage for stage in stages if stage.state in states)
        if matched:
            groups.append((label, role, matched))
            covered.update(stage.id for stage in matched)
    other = tuple(stage for stage in stages if stage.id not in covered)
    if other:
        groups.append(("Other", "muted", other))
    return tuple(groups)


def lifecycle_stage_label(stage: wt.Stage) -> str:
    """Concise stage identity plus an operator-readable terminal cause."""

    if stage.state != "failed" or not stage.reason_code:
        return stage.id
    reason = stage.reason_code
    friendly = {
        "review-changes-required-no-edge": "rework exhausted",
        "missing-report": "missing report",
    }.get(reason, reason.replace("-", " "))
    return f"{stage.id} ({friendly})"


def _pending_stage_label(stage: wt.Stage, ascii_only: bool) -> str:
    if not stage.dependencies:
        return stage.id
    arrow = "<-" if ascii_only else "←"
    sources = []
    for dependency in stage.dependencies:
        source = dependency.stage_id
        if dependency.condition:
            source += f" [{dependency.condition}]"
        sources.append(source)
    return f"{stage.id} {arrow} {' / '.join(sources)}"


def _next_pending_stages(
    snapshot: wt.WorkflowSnapshot, pending: Sequence[wt.Stage]
) -> Tuple[wt.Stage, ...]:
    """Stages directly unlocked by the current stage, including conditional branches."""

    active_states = {"running", "waiting"}
    terminal_clear = {"succeeded", "skipped"}
    active_ids = {stage.id for stage in snapshot.stages if stage.state in active_states}
    state_by_id = {stage.id: stage.state for stage in snapshot.stages}
    ready = []
    for stage in pending:
        unconditional = tuple(dep for dep in stage.dependencies if not dep.condition)
        conditional = tuple(dep for dep in stage.dependencies if dep.condition)
        unconditional_clear = all(
            state_by_id.get(dep.stage_id) in terminal_clear | active_states
            for dep in unconditional
        )
        follows_active = any(dep.stage_id in active_ids for dep in unconditional)
        conditional_follows = any(dep.stage_id in active_ids for dep in conditional)
        if (follows_active and unconditional_clear) or conditional_follows:
            ready.append(stage)
    if not ready and not active_ids:
        ready = [stage for stage in pending if not stage.dependencies]
    return tuple(ready)


def conditional_rework_stage_ids(snapshot: wt.WorkflowSnapshot) -> frozenset[str]:
    """Stages reachable only through a changes-required/error repair branch."""

    optional = {
        stage.id
        for stage in snapshot.stages
        if any(
            dependency.condition in {"changes-required", "error"}
            for dependency in stage.dependencies
        )
    }
    changed = True
    while changed:
        changed = False
        for stage in snapshot.stages:
            if stage.id in optional or not stage.dependencies:
                continue
            if all(dependency.stage_id in optional for dependency in stage.dependencies):
                optional.add(stage.id)
                changed = True
    return frozenset(optional)


def stage_inspection_state_label(view: wt.WorkflowViewModel, stage: wt.Stage) -> str:
    deferred = (
        wt.deferred_progress_stage_ids(view.snapshot)
        if view.snapshot is not None
        else frozenset()
    )
    if stage.id in deferred:
        if stage.state == "queued":
            return "conditional"
        if stage.state == "skipped":
            return "not needed"
    return public_state_label(stage.state)


def progress_tree_nodes(view: wt.WorkflowViewModel) -> Tuple[ProgressTreeNode, ...]:
    """Project the frozen DAG into a readable primary-parent tree.

    A workflow can have joins and artifact-derived cross-dependencies, so it is
    not literally a tree. Each stage is placed beneath its nearest meaningful
    prerequisite; the selected-stage detail still reports every dependency.
    Never-entered conditional routes are omitted. Once the engine enters a
    route, that branch and its ordinary descendants are appended to the tree.
    """

    snapshot = view.snapshot
    if snapshot is None:
        return ()
    ordered = wt.revealed_progress_stages(snapshot)
    if snapshot.run.mode != "dependency":
        return tuple(
            ProgressTreeNode(
                stage=stage,
                ancestor_continues=tuple(False for _ in range(position)),
                is_last=position == len(ordered) - 1,
                incoming_condition=None,
                selected=stage.id == view.selected_stage_id,
            )
            for position, stage in enumerate(ordered)
        )

    known = {stage.id for stage in ordered}
    stage_by_id = {stage.id: stage for stage in ordered}
    rank = {stage.id: position for position, stage in enumerate(ordered)}
    optional_ids = conditional_rework_stage_ids(snapshot)
    parent_by_id: dict[str, Optional[str]] = {}
    condition_by_id: dict[str, Optional[str]] = {}
    for stage in ordered:
        dependencies = [dep for dep in stage.dependencies if dep.stage_id in known]
        if not dependencies:
            parent_by_id[stage.id] = None
            condition_by_id[stage.id] = None
            continue
        candidates = dependencies
        if stage.id not in optional_ids:
            activated_rework = [
                dep
                for dep in dependencies
                if dep.stage_id in optional_ids
                and stage_by_id[dep.stage_id].state not in {"queued", "skipped"}
            ]
            required = [dep for dep in dependencies if dep.stage_id not in optional_ids]
            if activated_rework:
                candidates = activated_rework
            elif required:
                candidates = required
        parent = max(candidates, key=lambda dep: rank.get(dep.stage_id, -1))
        parent_by_id[stage.id] = parent.stage_id
        condition_by_id[stage.id] = parent.condition

    children: dict[Optional[str], list[wt.Stage]] = {}
    for stage in ordered:
        children.setdefault(parent_by_id[stage.id], []).append(stage)

    def child_key(stage: wt.Stage) -> Tuple[int, int, int]:
        # Keep a bounded repair chain together before returning to the normal
        # approval/join path. Active/failing branches still sort first.
        attention = 0 if stage.state in {"running", "waiting", "failed"} else 1
        conditional = 0 if stage.id in optional_ids else 1
        return (attention, conditional, rank[stage.id])

    for siblings in children.values():
        siblings.sort(key=child_key)

    result: List[ProgressTreeNode] = []

    def visit(stage: wt.Stage, ancestors: Tuple[bool, ...], is_last: bool) -> None:
        result.append(
            ProgressTreeNode(
                stage=stage,
                ancestor_continues=ancestors,
                is_last=is_last,
                incoming_condition=condition_by_id.get(stage.id),
                selected=stage.id == view.selected_stage_id,
            )
        )
        siblings = children.get(stage.id, [])
        for position, child in enumerate(siblings):
            visit(child, ancestors + (not is_last,), position == len(siblings) - 1)

    roots = children.get(None, [])
    for position, root in enumerate(roots):
        visit(root, (), position == len(roots) - 1)
    return tuple(result)


def _tree_prefix(
    node: ProgressTreeNode, ascii_only: bool, *, max_depth: int = 4
) -> str:
    if not node.ancestor_continues:
        return "-- " if ascii_only else "── "
    ancestors = node.ancestor_continues
    abbreviated = len(ancestors) > max_depth
    if abbreviated:
        ancestors = ancestors[-max_depth:]
    vertical = "|  " if ascii_only else "│  "
    blank = "   "
    pieces = ["... "] if abbreviated else []
    pieces.extend(vertical if continues else blank for continues in ancestors)
    if ascii_only:
        pieces.append("`- " if node.is_last else "|- ")
    else:
        pieces.append("└─ " if node.is_last else "├─ ")
    return "".join(pieces)


def _tree_condition_label(condition: Optional[str]) -> str:
    return {
        "changes-required": "if changes requested",
        "error": "if repair is needed",
        "passed": "if approved",
        "failed": "if failed",
    }.get(condition or "", condition.replace("-", " ") if condition else "")


def _tree_condition_label_for_stage(
    stage: wt.Stage, condition: Optional[str]
) -> str:
    """Describe a conditional edge only while its target is still latent.

    Once a stage has been entered, the stage's concrete lifecycle state is
    clearer than the condition that led to it (for example, ``complete · if
    approved`` is misleading).  Queued/skipped stages with no attempt remain
    latent branches, so retain the hint for those nodes.
    """
    if not condition:
        return ""
    if stage.state not in {"queued", "skipped"} or stage.attempt > 0:
        return ""
    return _tree_condition_label(condition)


def progress_tree_stage_label(
    view: wt.WorkflowViewModel, stage: wt.Stage, next_ids: Collection[str]
) -> str:
    if stage.state == "succeeded":
        return "complete"
    if stage.state == "running":
        return "in progress"
    if stage.state == "queued":
        return "next" if stage.id in next_ids else "pending"
    return public_state_label(stage.state)


def _progress_summary_spans(view: wt.WorkflowViewModel) -> Tuple[wc.StyledText, ...]:
    assert view.snapshot is not None
    revealed = wt.revealed_progress_stages(view.snapshot)
    complete = sum(stage.state == "succeeded" for stage in revealed)
    active = sum(stage.state == "running" for stage in revealed)
    remaining = sum(stage.state == "queued" for stage in revealed)
    waiting = sum(
        stage.state in {"waiting", "blocked", "failed", "stale"} for stage in revealed
    )
    parts = [f"{complete} complete"]
    if active:
        parts.append(f"{active} in progress")
    if waiting:
        parts.append(f"{waiting} needs attention")
    parts.append(f"{remaining} remaining")
    return (
        wc.StyledText("Progress  ", "heading"),
        wc.StyledText(" · ".join(parts), "muted"),
    )


def lifecycle_section_lines(
    view: wt.WorkflowViewModel, *, ascii_only: bool = False
) -> Tuple[Tuple[wc.StyledText, ...], ...]:
    """Compact lifecycle graph split into now, pending, and completed rows."""

    if view.snapshot is None:
        return ()
    separator = " | " if ascii_only else " · "
    visible_stages = wt.revealed_progress_stages(view.snapshot)
    grouped = {
        label: (role, stages)
        for label, role, stages in lifecycle_groups(visible_stages)
    }

    now: List[wc.StyledText] = [wc.StyledText("Now        ", "heading")]
    for label in ("Failed", "Active", "Waiting", "Blocked", "Other"):
        item = grouped.get(label)
        if item is None:
            continue
        role, stages = item
        if len(now) > 1:
            now.append(wc.StyledText(separator, "muted"))
        now.extend(
            (
                wc.StyledText(f"{label} {len(stages)}: ", role),
                wc.StyledText(", ".join(lifecycle_stage_label(stage) for stage in stages), role),
            )
        )
    if len(now) == 1:
        now.append(wc.StyledText("no stage active", "muted"))

    all_pending = grouped.get("Pending", ("muted", ()))[1]
    pending = tuple(all_pending)
    next_stages = _next_pending_stages(view.snapshot, pending)
    next_ids = {stage.id for stage in next_stages}
    later = tuple(stage for stage in pending if stage.id not in next_ids)
    pending_line: List[wc.StyledText] = [
        wc.StyledText("Pending    ", "heading"),
        wc.StyledText(str(len(pending)), "muted"),
    ]
    if pending:
        if next_stages:
            pending_line.extend(
                (
                    wc.StyledText(f"{separator}Next: ", "muted"),
                    wc.StyledText(
                        "; ".join(_pending_stage_label(stage, ascii_only) for stage in next_stages),
                        "accent",
                    ),
                )
            )
        if later:
            pending_line.extend(
                (
                    wc.StyledText(f"{separator}Later: ", "muted"),
                    wc.StyledText(
                        "; ".join(_pending_stage_label(stage, ascii_only) for stage in later),
                        "muted",
                    ),
                )
            )
    else:
        pending_line.append(wc.StyledText(": none", "muted"))

    completed = grouped.get("Complete", ("success", ()))[1]
    complete_line: List[wc.StyledText] = [
        wc.StyledText("Completed  ", "success"),
        wc.StyledText(f"{len(completed)}: ", "success"),
        wc.StyledText(
            ", ".join(lifecycle_stage_label(stage) for stage in completed) or "none yet",
            "success" if completed else "muted",
        ),
    ]
    skipped = grouped.get("Skipped", ("muted", ()))[1]
    terminal_groups = (
        ("Skipped", "muted", skipped),
        ("Cancelled",) + grouped.get("Cancelled", ("muted", ())),
    )
    for label, role, stages in terminal_groups:
        if not stages:
            continue
        complete_line.extend(
            (
                wc.StyledText(separator, "muted"),
                wc.StyledText(f"{label} {len(stages)}: ", role),
                wc.StyledText(", ".join(stage.id for stage in stages), role),
            )
        )
    return (tuple(now), tuple(pending_line), tuple(complete_line))


def group_stages_for_list(
    snapshot: wt.WorkflowSnapshot,
) -> List[Tuple[Optional[str], Tuple[wt.Stage, ...]]]:
    """Group Dependency stages by public wave metadata; keep Sequential ordered."""

    stages = wt.revealed_progress_stages(snapshot)
    if snapshot.run.mode != "dependency":
        return [(None, stages)]
    if not any(stage.wave is not None for stage in stages):
        return [(None, stages)]

    groups: List[Tuple[Optional[str], Tuple[wt.Stage, ...]]] = []
    current_wave: object = object()
    current: List[wt.Stage] = []
    for stage in stages:
        wave = stage.wave
        if wave != current_wave:
            if current:
                label = None if current_wave is None else f"Wave {current_wave}"
                groups.append((label, tuple(current)))
            current_wave = wave
            current = [stage]
        else:
            current.append(stage)
    if current:
        label = None if current_wave is None else f"Wave {current_wave}"
        groups.append((label, tuple(current)))
    return groups


def build_stage_list_entries(
    view: wt.WorkflowViewModel,
    *,
    include_waves: bool = True,
    visible_stage_ids: Optional[Collection[str]] = None,
) -> Tuple[StageListEntry, ...]:
    if view.snapshot is None:
        return ()
    allowed = None if visible_stage_ids is None else set(visible_stage_ids)
    entries: List[StageListEntry] = []
    tree_by_id = (
        {node.stage.id: node for node in progress_tree_nodes(view)}
        if view.snapshot.run.mode == "dependency"
        and not any(stage.wave is not None for stage in view.snapshot.stages)
        else {}
    )
    groups = group_stages_for_list(view.snapshot)
    for wave_label, stages in groups:
        if allowed is not None:
            stages = [stage for stage in stages if stage.id in allowed]
        if not stages:
            continue
        if include_waves and wave_label:
            entries.append(StageListEntry(kind="wave", label=wave_label))
        for stage in stages:
            label = stage.id
            tree_node = tree_by_id.get(stage.id)
            if tree_node is not None:
                label = f"{_tree_prefix(tree_node, False, max_depth=8)}{stage.id}"
                condition = _tree_condition_label_for_stage(
                    stage, tree_node.incoming_condition
                )
                if condition:
                    label += f" [{condition}]"
            entries.append(
                StageListEntry(
                    kind="stage",
                    label=label,
                    stage=stage,
                    state_label=stage_inspection_state_label(view, stage),
                    state_role=stage_state_role(stage, view.diagnosis),
                    selected=stage.id == view.selected_stage_id,
                )
            )
    return tuple(entries)


def contains_forbidden_primary_term(text: str) -> Optional[str]:
    lowered = text.casefold()
    for term in FORBIDDEN_PRIMARY_TERMS:
        if term in lowered:
            return term
    return None


def _now_or_default(now: Optional[datetime]) -> datetime:
    if now is None:
        return datetime.now(timezone.utc)
    if now.tzinfo is None:
        return now.replace(tzinfo=timezone.utc)
    return now.astimezone(timezone.utc)


def _write_line(
    canvas: wc.Canvas,
    y: int,
    spans: Iterable[wc.StyledText],
    *,
    x: int = 0,
    width: Optional[int] = None,
) -> None:
    max_width = canvas.width if width is None else width
    canvas.write_spans(x, y, wc.truncate_spans(spans, max_width), max_width=max_width)


def _header_lines(
    view: wt.WorkflowViewModel,
    *,
    width: int,
    tier: str,
    now: datetime,
    ascii_only: bool,
    inspection_compact: bool = False,
) -> List[Tuple[wc.StyledText, ...]]:
    if view.snapshot is None:
        message = view.error.message if view.error else "Workflow status unavailable"
        return [(wc.StyledText(message, "failure"),)]

    run = view.snapshot.run
    diagnosis = view.snapshot.diagnosis
    progress_stages = wt.revealed_progress_stages(view.snapshot)
    counts = count_stages(progress_stages)
    outcome_state = effective_outcome_state(run.state, diagnosis.state)
    badge = outcome_badge(outcome_state)
    badge_role = outcome_role(outcome_state, diagnosis.reason_code)
    workflow = run.workflow_id or "workflow"
    mode = mode_label(run.mode)
    elapsed = run_duration_label(run, now)
    updated = format_last_update(run.updated_at, now)
    progress_completed = sum(stage.state == "succeeded" for stage in progress_stages)
    progress_total = len(progress_stages)

    sep = " | " if ascii_only else " · "
    lines: List[Tuple[wc.StyledText, ...]] = []
    if tier == "compact":
        if inspection_compact:
            entry = run.entry_kind
            if run.task_provenance:
                entry += f" ({run.task_provenance})"
            lines.append(
                (
                    wc.StyledText("Ralph ", "heading"),
                    wc.StyledText(run.run_id, "path"),
                    wc.StyledText("  ", "default"),
                    wc.StyledText(workflow, "heading"),
                    wc.StyledText(f"{sep}{mode}{sep}{entry}{sep}{elapsed}", "muted"),
                )
            )
            lines.append(
                (
                    wc.StyledText(badge, badge_role),
                    wc.StyledText("  ", "default"),
                    wc.StyledText(run.task, "default"),
                )
            )
            return lines
        lines.append(
            (
                wc.StyledText("Ralph ", "heading"),
                wc.StyledText(run.run_id, "path"),
            )
        )
        lines.append(
            (
                wc.StyledText(f"{workflow}{sep}{mode}", "muted"),
            )
        )
        lines.append(
            (
                wc.StyledText(badge, badge_role),
                wc.StyledText("  ", "default"),
                wc.StyledText(run.task, "default"),
            )
        )
        lines.append(
            (
                wc.StyledText(f"{progress_completed}/{progress_total} stages", "muted"),
                wc.StyledText("  ", "default"),
                wc.StyledText(elapsed, "muted"),
            )
        )
        return lines

    lines.append(
        (
            wc.StyledText("Ralph ", "heading"),
            wc.StyledText(run.run_id, "path"),
            wc.StyledText("  ", "default"),
            wc.StyledText(workflow, "heading"),
            wc.StyledText(f"{sep}{mode}", "muted"),
        )
    )
    lines.append(
        (
            wc.StyledText("Task  ", "muted"),
            wc.StyledText(run.task, "default"),
        )
    )
    meta: List[wc.StyledText] = [
        wc.StyledText(badge, badge_role),
        wc.StyledText("  Elapsed ", "muted"),
        wc.StyledText(elapsed, "default"),
    ]
    if width >= 56:
        meta.extend(
            (
                wc.StyledText("  Updated ", "muted"),
                wc.StyledText(updated, "default"),
            )
        )
    if width >= 68:
        meta.extend(
            (
                wc.StyledText("  Stages ", "muted"),
                wc.StyledText(f"{progress_completed}/{progress_total}", "default"),
            )
        )
    lines.append(tuple(meta))
    if tier == "wide":
        detail: List[wc.StyledText] = []
        if counts.failed:
            detail.extend(
                (wc.StyledText("failed ", "muted"), wc.StyledText(str(counts.failed), "failure"))
            )
        if counts.waiting:
            if detail:
                detail.append(wc.StyledText("  ", "default"))
            detail.extend(
                (wc.StyledText("waiting ", "muted"), wc.StyledText(str(counts.waiting), "warning"))
            )
        if counts.blocked:
            if detail:
                detail.append(wc.StyledText("  ", "default"))
            detail.extend(
                (wc.StyledText("blocked ", "muted"), wc.StyledText(str(counts.blocked), "muted"))
            )
        if detail:
            lines.append(tuple(detail))
    bar_width = max(12, min(width, 48))
    lines.append(wc.progress_spans(progress_completed, progress_total, bar_width, ascii_only=ascii_only))
    if diagnosis.summary and tier != "compact" and width >= 48:
        lines.append((wc.StyledText(diagnosis.summary, "muted"),))
    return lines


def _stage_row_spans(entry: StageListEntry, *, width: int, tier: str) -> Tuple[wc.StyledText, ...]:
    state_width = 9 if tier == "compact" else 10
    state = wc.fit_text(entry.state_label, state_width, pad=True)
    spans: List[wc.StyledText] = [wc.StyledText(f" {state} ", entry.state_role)]
    used = 1 + state_width + 1
    remaining = max(0, width - used)
    label = entry.label
    stage = entry.stage
    if tier != "compact" and stage is not None and stage.progress.total > 0 and remaining > 8:
        progress = f"{stage.progress.completed}/{stage.progress.total}"
        name_budget = max(0, remaining - wc.display_width(progress) - 1)
        spans.append(wc.StyledText(wc.truncate_text(label, name_budget), "default"))
        spans.append(wc.StyledText(f" {progress}", "muted"))
    else:
        spans.append(wc.StyledText(wc.truncate_text(label, remaining), "default"))
    return tuple(spans)


# ---------------------------------------------------------------------------
# Selected-stage detail pane
# ---------------------------------------------------------------------------

# Lower number = higher priority (kept first when vertical space is scarce).
DETAIL_PRIORITY = {
    "identity": 0,
    "next": 1,
    "reason": 1,
    "question": 2,
    "todo": 2,
    "request": 3,
    "progress": 3,
    "changes": 3,
    "attempt": 4,
    "dependencies": 1,
    "unlocks": 1,
    "plan_source": 5,
    "workspace": 4,
    "open_workspace": 5,
    "changeset": 5,
    "blocker": 6,
    "artifacts": 7,
    "evidence": 8,
}

PLAN_PATH_MARKERS = (
    "planpath",
    "sourceplan",
    "controlplan",
    "originalplan",
    "plan-path",
    "source-plan",
    "control-plan",
    "original-plan",
)


@dataclass(frozen=True)
class DetailLine:
    """One labeled detail row with a drop priority for narrow layouts."""

    key: str
    priority: int
    spans: Tuple[wc.StyledText, ...]


def path_display_label(path: str, *, reveal: bool = False) -> str:
    """Abbreviate a contained path to its basename unless reveal is requested."""

    text = wc.sanitize_text(path).strip()
    if not text:
        return ""
    if reveal:
        return text
    base = text.rsplit("/", 1)[-1]
    return base or text


def stage_kind_label(kind: str) -> str:
    known = {
        "executable": "executable",
        "plan-backed": "plan-backed",
        "approval": "approval",
        "supervisor": "supervisor",
    }
    return known.get(kind, wc.sanitize_text(kind) or "stage")


def stage_duration_label(stage: wt.Stage, now: datetime) -> Optional[str]:
    """Return a compact duration for the selected stage, or None when unknown.

    Running stages measure against ``now`` so the pane can tick locally.
    All other states use the recorded ``updated_at`` stamp when present.
    """

    start = parse_iso_utc(stage.created_at)
    if start is None:
        return None
    if stage.state == "running":
        end = now
    else:
        end = parse_iso_utc(stage.updated_at) or now
    seconds = int((end - start).total_seconds())
    if seconds < 0:
        seconds = 0
    return format_elapsed_seconds(seconds)


def blocker_summary(stage: wt.Stage) -> Optional[str]:
    if not stage.blocker_kind:
        return None
    kind = wc.sanitize_text(stage.blocker_kind)
    if stage.blocker_reason_code:
        return f"{kind}: {wc.sanitize_text(stage.blocker_reason_code)}"
    if stage.request_state:
        return f"{kind} ({wc.sanitize_text(stage.request_state)})"
    return kind or None


def dependency_summary(dependencies: Sequence[wt.StageDependency]) -> str:
    labels = []
    for dependency in dependencies:
        label = dependency.stage_id
        if dependency.condition:
            label += f" ({dependency.condition})"
        labels.append(label)
    return ", ".join(labels)


def dependent_summary(view: wt.WorkflowViewModel, stage_id: str) -> str:
    labels = []
    candidates = (
        wt.revealed_progress_stages(view.snapshot)
        if view.snapshot is not None
        else view.stages
    )
    for candidate in candidates:
        matches = [dependency for dependency in candidate.dependencies if dependency.stage_id == stage_id]
        for dependency in matches:
            label = candidate.id
            if dependency.condition:
                label += f" ({dependency.condition})"
            labels.append(label)
    return ", ".join(labels)


def is_approval_stage(stage: wt.Stage) -> bool:
    return stage.kind == "approval"


def _labeled_spans(label: str, value: str, *, value_role: str = "default") -> Tuple[wc.StyledText, ...]:
    return (
        wc.StyledText(f"{label}  ", "muted"),
        wc.StyledText(value, value_role),
    )


def _artifact_labels(paths: Sequence[str], *, reveal: bool) -> str:
    labels = [path_display_label(path, reveal=reveal) for path in paths if path]
    labels = [label for label in labels if label]
    if not labels:
        return ""
    if len(labels) == 1:
        return labels[0]
    return f"{labels[0]} +{len(labels) - 1}"


def _evidence_labels(items: Sequence[str], *, reveal: bool) -> str:
    labels = [path_display_label(item, reveal=reveal) for item in items if item]
    labels = [label for label in labels if label]
    if not labels:
        return ""
    if len(labels) == 1:
        return labels[0]
    return f"{labels[0]} +{len(labels) - 1}"


def build_stage_detail_lines(
    view: wt.WorkflowViewModel,
    *,
    now: Optional[datetime] = None,
    reveal_paths: bool = False,
    max_lines: Optional[int] = None,
    include_heading: bool = False,
) -> Tuple[DetailLine, ...]:
    """Build priority-ordered detail rows for the selected stage.

    Null and irrelevant fields are omitted. Approval stages never surface plan
    source or TODO progress. Paths are abbreviated unless ``reveal_paths``.
    When ``max_lines`` is set, lower-priority rows are dropped entirely rather
    than truncated mid-field.
    """

    now = _now_or_default(now)
    lines: List[DetailLine] = []
    if include_heading:
        lines.append(
            DetailLine(
                key="heading",
                priority=-1,
                spans=(wc.StyledText("Selected stage", "heading"),),
            )
        )

    stage = view.selected_stage
    if stage is None:
        if view.next_action is not None:
            lines.append(
                DetailLine(
                    key="next",
                    priority=DETAIL_PRIORITY["next"],
                    spans=_labeled_spans("Next", view.next_action.label, value_role="command"),
                )
            )
        if reveal_paths and view.next_action is not None and view.next_action.argv:
            command = " ".join(view.next_action.argv)
            lines.append(
                DetailLine(
                    key="command",
                    priority=DETAIL_PRIORITY["next"] + 1,
                    spans=_labeled_spans("Command", command, value_role="command"),
                )
            )
        return _fit_detail_lines(tuple(lines), max_lines)

    approval = is_approval_stage(stage)
    state_role = stage_state_role(stage, view.diagnosis)
    identity = (
        wc.StyledText(stage.id, "heading"),
        wc.StyledText("  ", "default"),
        wc.StyledText(stage_kind_label(stage.kind), "muted"),
        wc.StyledText("  ", "default"),
        wc.StyledText(stage_inspection_state_label(view, stage), state_role),
    )
    lines.append(DetailLine(key="identity", priority=DETAIL_PRIORITY["identity"], spans=identity))

    if (
        view.diagnosis is not None
        and view.diagnosis.stage_id == stage.id
        and view.diagnosis.summary
        and view.diagnosis.reason_code == "loop-exhausted"
    ):
        lines.append(
            DetailLine(
                key="reason",
                priority=DETAIL_PRIORITY["reason"],
                spans=_labeled_spans(
                    "Why", view.diagnosis.summary, value_role="warning"
                ),
            )
        )

    if view.next_action is not None:
        lines.append(
            DetailLine(
                key="next",
                priority=DETAIL_PRIORITY["next"],
                spans=_labeled_spans("Next", view.next_action.label, value_role="command"),
            )
        )
        if reveal_paths and view.next_action.argv:
            command = " ".join(view.next_action.argv)
            lines.append(
                DetailLine(
                    key="command",
                    priority=DETAIL_PRIORITY["next"] + 1,
                    spans=_labeled_spans("Command", command, value_role="command"),
                )
            )

    if approval:
        if stage.approval_question:
            lines.append(
                DetailLine(
                    key="question",
                    priority=DETAIL_PRIORITY["question"],
                    spans=_labeled_spans("Question", stage.approval_question),
                )
            )
        if stage.request_state:
            lines.append(
                DetailLine(
                    key="request",
                    priority=DETAIL_PRIORITY["request"],
                    spans=_labeled_spans("Request", stage.request_state, value_role="warning"),
                )
            )
        if stage.changes_target:
            lines.append(
                DetailLine(
                    key="changes",
                    priority=DETAIL_PRIORITY["changes"],
                    spans=_labeled_spans("Changes target", stage.changes_target, value_role="path"),
                )
            )
    else:
        if stage.progress.current_todo_id:
            lines.append(
                DetailLine(
                    key="todo",
                    priority=DETAIL_PRIORITY["todo"],
                    spans=_labeled_spans("TODO", stage.progress.current_todo_id),
                )
            )
        if stage.progress.total > 0:
            progress = f"{stage.progress.completed}/{stage.progress.total}"
            lines.append(
                DetailLine(
                    key="progress",
                    priority=DETAIL_PRIORITY["progress"],
                    spans=_labeled_spans("TODOs", progress),
                )
            )
        if stage.plan_source_kind:
            source = stage.plan_source_kind
            if stage.plan_source_stage_id:
                source = f"{source} from {stage.plan_source_stage_id}"
            lines.append(
                DetailLine(
                    key="plan_source",
                    priority=DETAIL_PRIORITY["plan_source"],
                    spans=_labeled_spans("Plan source", source),
                )
            )

    attempt_bits: List[wc.StyledText] = [
        wc.StyledText("Attempt  ", "muted"),
        wc.StyledText(str(stage.attempt), "default"),
    ]
    duration = stage_duration_label(stage, now)
    if duration is not None:
        attempt_bits.extend(
            (
                wc.StyledText("  Duration  ", "muted"),
                wc.StyledText(duration, "default"),
            )
        )
    lines.append(
        DetailLine(key="attempt", priority=DETAIL_PRIORITY["attempt"], spans=tuple(attempt_bits))
    )

    dependencies = dependency_summary(stage.dependencies)
    if dependencies:
        lines.append(
            DetailLine(
                key="dependencies",
                priority=DETAIL_PRIORITY["dependencies"],
                spans=_labeled_spans("Depends on", dependencies),
            )
        )
    unlocks = dependent_summary(view, stage.id)
    if unlocks:
        lines.append(
            DetailLine(
                key="unlocks",
                priority=DETAIL_PRIORITY["unlocks"],
                spans=_labeled_spans("Unlocks", unlocks),
            )
        )

    summary = blocker_summary(stage)
    if summary:
        lines.append(
            DetailLine(
                key="blocker",
                priority=DETAIL_PRIORITY["blocker"],
                spans=_labeled_spans("Blocker", summary, value_role="warning"),
            )
        )

    if not approval and stage.artifacts:
        artifact_text = _artifact_labels(stage.artifacts, reveal=reveal_paths)
        if artifact_text:
            lines.append(
                DetailLine(
                    key="artifacts",
                    priority=DETAIL_PRIORITY["artifacts"],
                    spans=_labeled_spans("Artifacts", artifact_text, value_role="path"),
                )
            )

    if not approval and stage.workspace_mode:
        availability = "available" if stage.workspace_available else "not available"
        workspace_value = f"{stage.workspace_mode} ({availability})"
        if stage.workspace_path:
            workspace_value += f" · {path_display_label(stage.workspace_path, reveal=reveal_paths)}"
        lines.append(
            DetailLine(
                key="workspace",
                priority=DETAIL_PRIORITY["workspace"],
                spans=_labeled_spans("Workspace", workspace_value, value_role="path"),
            )
        )
        if reveal_paths and stage.workspace_available and stage.workspace_path:
            lines.append(
                DetailLine(
                    key="open_workspace",
                    priority=DETAIL_PRIORITY["open_workspace"],
                    spans=_labeled_spans(
                        "Open code",
                        f"cd {shlex.quote(stage.workspace_path)}",
                        value_role="command",
                    ),
                )
            )
    if not approval and stage.changeset_manifest:
        changeset_value = path_display_label(stage.changeset_manifest, reveal=reveal_paths)
        if stage.changed_files:
            changeset_value += f" · {len(stage.changed_files)} changed file(s)"
        lines.append(
            DetailLine(
                key="changeset",
                priority=DETAIL_PRIORITY["changeset"],
                spans=_labeled_spans("Changeset", changeset_value, value_role="path"),
            )
        )

    evidence_count = len(stage.evidence)
    if evidence_count:
        if reveal_paths:
            evidence_text = _evidence_labels(stage.evidence, reveal=True)
            value = evidence_text or str(evidence_count)
            lines.append(
                DetailLine(
                    key="evidence",
                    priority=DETAIL_PRIORITY["evidence"],
                    spans=_labeled_spans("Evidence", value, value_role="path"),
                )
            )
        else:
            lines.append(
                DetailLine(
                    key="evidence",
                    priority=DETAIL_PRIORITY["evidence"],
                    spans=_labeled_spans("Evidence", str(evidence_count)),
                )
            )

    return _fit_detail_lines(tuple(lines), max_lines)


def _fit_detail_lines(
    lines: Tuple[DetailLine, ...], max_lines: Optional[int]
) -> Tuple[DetailLine, ...]:
    if max_lines is None or max_lines < 0 or len(lines) <= max_lines:
        return lines
    # Always keep the heading (priority < 0) when present, then highest priority.
    heading = [line for line in lines if line.priority < 0]
    body = [line for line in lines if line.priority >= 0]
    budget = max(0, max_lines - len(heading))
    body_sorted = sorted(body, key=lambda line: (line.priority, line.key))
    kept = body_sorted[:budget]
    kept_keys = {line.key for line in kept}
    ordered = heading + [line for line in body if line.key in kept_keys]
    return tuple(ordered)


def detail_reserve_rows(tier: str, available: int) -> int:
    """Rows reserved for the selected-stage detail pane."""

    available = max(0, int(available))
    if available <= 0:
        return 0
    if tier == "compact":
        return min(3, available)
    if tier == "wide":
        return min(max(8, available // 3), available)
    return min(max(6, available // 3), available)


def log_reserve_rows(tier: str, available: int, *, has_log: bool) -> int:
    """Rows reserved for the persistent wide-mode log pane."""

    if not has_log or tier != "wide":
        return 0
    available = max(0, int(available))
    if available < 4:
        return 0
    return min(max(8, available // 3), available)


def contains_plan_path_leak(text: str) -> bool:
    """True when an approval (or primary) view exposes plan-file path vocabulary."""

    lowered = text.casefold().replace(" ", "").replace("_", "")
    for marker in PLAN_PATH_MARKERS:
        if marker in lowered:
            return True
    for needle in (
        "control.plan.md",
        "source.plan.md",
        "original.plan.md",
        "/fixtures/control.plan",
        "/fixtures/source.plan",
        "/fixtures/original.plan",
    ):
        if needle.casefold() in text.casefold():
            return True
    return False


def _paint_detail_pane(
    canvas: wc.Canvas,
    view: wt.WorkflowViewModel,
    *,
    y: int,
    width: int,
    height: int,
    now: datetime,
    tier: str,
    ascii_only: bool,
    reveal_paths: bool,
) -> int:
    """Paint the selected-stage detail into ``[y, height)`` and return next y."""

    available = height - y
    if available <= 0 or width <= 0:
        return y

    use_box = tier != "compact" and available >= 4 and width >= 20
    if use_box:
        rect = wc.Rect(0, y, width, available)
        inner = canvas.draw_box(
            rect,
            title="Selected stage",
            padding=(0, 1),
            ascii_only=ascii_only,
        )
        line_budget = max(0, inner.height)
        detail_lines = build_stage_detail_lines(
            view,
            now=now,
            reveal_paths=reveal_paths,
            max_lines=line_budget,
            include_heading=False,
        )
        row = inner.y
        for detail in detail_lines:
            if row >= inner.bottom:
                break
            canvas.write_spans(
                inner.x,
                row,
                wc.truncate_spans(detail.spans, inner.width),
                max_width=inner.width,
            )
            row += 1
        return y + available

    detail_lines = build_stage_detail_lines(
        view,
        now=now,
        reveal_paths=reveal_paths,
        max_lines=available,
        include_heading=(tier != "compact"),
    )
    for detail in detail_lines:
        if y >= height:
            break
        _write_line(canvas, y, detail.spans, width=width)
        y += 1
    return y


def _paint_log_pane(
    canvas: wc.Canvas,
    pane: wlog.WorkflowLogPane,
    *,
    y: int,
    width: int,
    height: int,
    ascii_only: bool,
    title: str = "Logs",
) -> int:
    """Paint a bounded log pane into ``[y, height)`` and return next y."""

    available = height - y
    if available <= 0 or width <= 0:
        return y

    use_box = available >= 4 and width >= 20
    if use_box:
        rect = wc.Rect(0, y, width, available)
        inner = canvas.draw_box(
            rect,
            title=title,
            padding=(0, 1),
            ascii_only=ascii_only,
        )
        lines = wlog.paint_log_lines(pane, max_lines=max(0, inner.height))
        row = inner.y
        for line in lines:
            if row >= inner.bottom:
                break
            role = "muted" if row == inner.y else "path"
            if pane.missing or pane.uncontained or pane.symlink or pane.unavailable:
                role = "warning" if row > inner.y else "muted"
            canvas.write_spans(
                inner.x,
                row,
                wc.truncate_spans((wc.StyledText(line, role),), inner.width),
                max_width=inner.width,
            )
            row += 1
        return y + available

    lines = wlog.paint_log_lines(pane, max_lines=available)
    for index, line in enumerate(lines):
        if y >= height:
            break
        role = "muted" if index == 0 else "path"
        _write_line(canvas, y, (wc.StyledText(line, role),), width=width)
        y += 1
    return y


def render_log_focus_frame(
    view: wt.WorkflowViewModel,
    pane: wlog.WorkflowLogPane,
    width: int,
    height: int,
    *,
    now: Optional[datetime] = None,
    ascii_only: bool = False,
) -> wc.Canvas:
    """Focused log view used by compact/standard tiers."""

    width = max(0, int(width))
    height = max(0, int(height))
    canvas = wc.Canvas(width, height)
    if width == 0 or height == 0:
        return canvas
    now = _now_or_default(now)
    tier = layout_tier(width, height)
    y = 0
    for spans in _header_lines(view, width=width, tier=tier, now=now, ascii_only=ascii_only):
        if y >= height:
            return canvas
        _write_line(canvas, y, spans, width=width)
        y += 1
    if y < height:
        _paint_log_pane(
            canvas,
            pane,
            y=y,
            width=width,
            height=height,
            ascii_only=ascii_only,
            title="Logs (focused)",
        )
    return canvas


def _filter_status_spans(
    *,
    filter_query: str,
    filter_editing: bool,
    match_count: Optional[int],
) -> Tuple[wc.StyledText, ...]:
    label = "Filter" if filter_editing else "Filtered"
    query = wc.sanitize_text(filter_query)
    cursor = "_" if filter_editing else ""
    count = "" if match_count is None else f"  ({match_count} match{'es' if match_count != 1 else ''})"
    return (
        wc.StyledText(f"{label}: ", "warning"),
        wc.StyledText(f"{query}{cursor}", "accent" if filter_editing else "default"),
        wc.StyledText(count, "muted"),
    )


def _progress_tree_row_spans(
    view: wt.WorkflowViewModel,
    node: ProgressTreeNode,
    *,
    now: datetime,
    next_ids: Collection[str],
    ascii_only: bool,
) -> Tuple[wc.StyledText, ...]:
    stage = node.stage
    role = stage_state_role(stage, view.diagnosis)
    state_label = progress_tree_stage_label(view, stage, next_ids)
    marker = {
        "succeeded": "x",
        "running": "*",
        "waiting": "?",
        "failed": "!",
        "blocked": "!",
        "stale": "!",
        "skipped": "-",
        "cancelled": "-",
        "queued": "o",
    }.get(stage.state, "o")
    spans: List[wc.StyledText] = [
        wc.StyledText(_tree_prefix(node, ascii_only), "muted"),
        wc.StyledText(f"{marker} ", role),
        wc.StyledText(stage.id, "heading" if node.selected else "default"),
        wc.StyledText(f" ({state_label})", role),
    ]
    condition = _tree_condition_label_for_stage(stage, node.incoming_condition)
    if condition:
        spans.append(wc.StyledText(f" · {condition}", "warning"))
    if node.selected:
        metadata: List[str] = []
        if stage.attempt > 0:
            metadata.append(f"attempt {stage.attempt}")
        duration = (
            stage_duration_label(stage, now)
            if stage.state not in {"queued", "skipped"}
            else None
        )
        if duration:
            metadata.append(duration)
        if stage.progress.total > 0:
            metadata.append(f"TODO {stage.progress.completed}/{stage.progress.total}")
        if metadata:
            spans.append(wc.StyledText(f" · {' · '.join(metadata)}", "muted"))
        spans.append(wc.StyledText("  SELECTED", "focus"))
    elif stage.state == "succeeded" and stage.artifacts:
        artifact_name = wc.sanitize_text(stage.artifacts[0].rsplit("/", 1)[-1])
        if artifact_name:
            suffix = f"artifact {artifact_name}"
            if len(stage.artifacts) > 1:
                suffix += f" +{len(stage.artifacts) - 1}"
            spans.append(wc.StyledText(f" · {suffix}", "path"))
    elif stage.progress.total > 0:
        spans.append(
            wc.StyledText(
                f" · TODO {stage.progress.completed}/{stage.progress.total}", "muted"
            )
        )
    return tuple(spans)


def _selected_tree_detail_rows(
    view: wt.WorkflowViewModel,
    node: ProgressTreeNode,
) -> Tuple[Tuple[wc.StyledText, ...], ...]:
    if view.run is None:
        return ()
    stage = node.stage
    prefix_width = wc.display_width(_tree_prefix(node, True)) + 2
    prefix = " " * prefix_width
    run_id = shlex.quote(view.run.run_id)
    stage_id = shlex.quote(stage.id)
    attempt = f" --attempt {stage.attempt}" if stage.attempt > 0 else ""
    log_command = (
        f"ralph workflow logs {run_id} --stage {stage_id}{attempt} "
        "--stream combined --tail 200 --follow"
    )
    info: List[str] = []
    dependencies = dependency_summary(stage.dependencies)
    if dependencies:
        info.append(f"after {dependencies}")
    unlocks = dependent_summary(view, stage.id)
    if unlocks:
        info.append(f"unlocks {unlocks}")
    info_row = (
        wc.StyledText(prefix + "Details  ", "accent"),
        wc.StyledText(" · ".join(info) or stage_kind_label(stage.kind), "muted"),
    )
    log_row = (
        wc.StyledText(prefix + "Logs     ", "accent"),
        wc.StyledText(log_command, "command"),
    )
    action_row = (
        wc.StyledText(prefix + "Action   ", "accent"),
        wc.StyledText(f"ralph workflow actions list {run_id}", "command"),
    )
    workspace_row = None
    if stage.workspace_mode:
        availability = "available" if stage.workspace_available else "not available"
        workspace_value = f"{stage.workspace_mode} · {availability}"
        if stage.workspace_path:
            workspace_value += f" · {stage.workspace_path}"
        workspace_row = (
            wc.StyledText(prefix + "Workspace", "accent"),
            wc.StyledText("  " + workspace_value, "path"),
        )
    open_row = None
    if stage.workspace_available and stage.workspace_path:
        open_row = (
            wc.StyledText(prefix + "Open     ", "accent"),
            wc.StyledText(f"cd {shlex.quote(stage.workspace_path)}", "command"),
        )
    changeset_row = None
    if stage.changeset_manifest:
        changeset_value = stage.changeset_manifest
        if stage.changed_files:
            changeset_value += f" · {len(stage.changed_files)} changed file(s)"
        changeset_row = (
            wc.StyledText(prefix + "Changes  ", "accent"),
            wc.StyledText(changeset_value, "path"),
        )
    recovery_row = None
    if (
        view.diagnosis is not None
        and view.diagnosis.reason_code == "loop-exhausted"
        and view.diagnosis.stage_id == stage.id
        and view.next_action is not None
    ):
        recovery_row = (
            wc.StyledText(prefix + "Recover  ", "warning"),
            wc.StyledText(" ".join(view.next_action.argv), "command"),
        )
    artifacts = () if stage.state in {"queued", "skipped"} else stage.artifacts
    if artifacts:
        artifact_command = f"less {shlex.quote(artifacts[0])}"
        if len(artifacts) > 1:
            artifact_command += f"  (+{len(artifacts) - 1}; c shows all)"
        artifact_row = (
            wc.StyledText(prefix + "Artifact ", "accent"),
            wc.StyledText(artifact_command, "command"),
        )
    else:
        artifact_row = (
            wc.StyledText(prefix + "Artifact ", "accent"),
            wc.StyledText("none yet", "muted"),
        )
    code_rows = tuple(
        row for row in (workspace_row, open_row, changeset_row) if row is not None
    )
    if stage.state == "waiting" or stage.request_id or stage.blocker_kind in {
        "approval",
        "input",
        "permission",
    }:
        return (action_row, log_row, artifact_row) + code_rows
    if stage.state == "running":
        return (log_row, artifact_row) + code_rows + (info_row,)
    if stage.state == "succeeded":
        return (artifact_row, log_row) + code_rows + (info_row,)
    if stage.state in {"failed", "blocked", "stale"}:
        if recovery_row is not None:
            return (recovery_row, artifact_row, log_row) + code_rows + (info_row,)
        return (info_row, log_row, artifact_row) + code_rows
    return (info_row, log_row, artifact_row) + code_rows


def _paint_progress_tree(
    canvas: wc.Canvas,
    view: wt.WorkflowViewModel,
    *,
    y: int,
    width: int,
    height: int,
    now: datetime,
    ascii_only: bool,
) -> int:
    """Paint a selected-stage-centered slice of the progress tree."""

    if view.snapshot is None or y >= height:
        return y
    nodes = progress_tree_nodes(view)
    if not nodes:
        _write_line(canvas, y, _progress_summary_spans(view), width=width)
        return y + 1

    selected_index = next(
        (index for index, node in enumerate(nodes) if node.selected), 0
    )
    pending = tuple(
        stage
        for stage in wt.revealed_progress_stages(view.snapshot)
        if stage.state == "queued"
    )
    next_ids = {
        stage.id for stage in _next_pending_stages(view.snapshot, pending)
    }
    _write_line(canvas, y, _progress_summary_spans(view), width=width)
    y += 1
    available = max(0, height - y)
    if available == 0:
        return y

    desired_detail_budget = 1 if available <= 4 else 2 if available <= 7 else 3
    node_budget = max(1, available - desired_detail_budget)
    node_budget = min(node_budget, len(nodes))
    detail_budget = min(3, max(0, available - node_budget))
    start = max(0, selected_index - min(2, max(0, node_budget - 1)))
    start = min(start, max(0, len(nodes) - node_budget))
    visible_nodes = nodes[start : start + node_budget]
    selected_node = nodes[selected_index]
    detail_rows = _selected_tree_detail_rows(view, selected_node)[:detail_budget]

    for node in visible_nodes:
        if y >= height:
            break
        spans = _progress_tree_row_spans(
            view,
            node,
            now=now,
            next_ids=next_ids,
            ascii_only=ascii_only,
        )
        canvas.draw_row(
            wc.Rect(0, y, width, 1),
            wc.truncate_spans(spans, max(0, width - 1)),
            selected=node.selected,
            marker=">",
        )
        y += 1
        if node.selected:
            for detail in detail_rows:
                if y >= height:
                    break
                _write_line(canvas, y, detail, width=width)
                y += 1
    return y


def render_modal_frame(
    *,
    title: str,
    body: Sequence[Sequence[wc.StyledText] | str],
    width: int,
    height: int,
    ascii_only: bool = False,
    footer: Optional[str] = None,
) -> wc.Canvas:
    """Paint a focused modal onto the semantic canvas (dialog/help overlays)."""

    width = max(0, int(width))
    height = max(0, int(height))
    canvas = wc.Canvas(width, height)
    if width == 0 or height == 0:
        return canvas
    rect = wc.Rect(0, 0, width, height)
    inner = canvas.draw_box(rect, title=title, padding=(0, 1), ascii_only=ascii_only)
    row = inner.y
    for item in body:
        if row >= inner.bottom:
            break
        if isinstance(item, str):
            spans: Sequence[wc.StyledText] = (wc.StyledText(item),)
        else:
            spans = item
        canvas.write_spans(
            inner.x,
            row,
            wc.truncate_spans(spans, inner.width),
            max_width=inner.width,
        )
        row += 1
    if footer and height > 0:
        canvas.draw_text(0, height - 1, width, footer, role="muted")
    return canvas


def render_primary_frame(
    view: wt.WorkflowViewModel,
    width: int,
    height: int,
    *,
    now: Optional[datetime] = None,
    ascii_only: bool = False,
    reveal_paths: bool = False,
    details_view: bool = False,
    log_pane: Optional[wlog.WorkflowLogPane] = None,
    log_focused: bool = False,
    visible_stage_ids: Optional[Collection[str]] = None,
    filter_query: str = "",
    filter_editing: bool = False,
    inspection_lines: Optional[Sequence[Sequence[wc.StyledText]]] = None,
    tier_width: Optional[int] = None,
    tier_height: Optional[int] = None,
) -> wc.Canvas:
    """Paint the branded primary frame (header, stages, selected detail).

    ``details_view`` / ``reveal_paths`` expand abbreviated path labels to full
    contained paths inside the detail pane only. Compact layouts keep a short
    high-priority detail strip; standard and wide reserve a dedicated pane.
    Wide mode keeps a persistent log pane when ``log_pane`` is provided.
    Compact/standard open logs only as a focused view (``log_focused``).
    ``inspection_lines`` reserves a persistent bottom pane for exact public
    inspection commands. In a wide-but-shallow compact terminal, the header
    folds the active-stage details into one line so every inspection row can
    remain visible in the primary frame.

    ``tier_width`` / ``tier_height`` select the responsive tier from the full
    terminal size when the painted body is shorter (for example after reserving
    a footer row).
    """

    width = max(0, int(width))
    height = max(0, int(height))
    canvas = wc.Canvas(width, height)
    if width == 0 or height == 0:
        return canvas

    now = _now_or_default(now)
    tier = layout_tier(
        width if tier_width is None else max(0, int(tier_width)),
        height if tier_height is None else max(0, int(tier_height)),
    )
    show_paths = bool(reveal_paths or details_view)
    filtering = bool(filter_editing or filter_query)

    if log_pane is not None and log_focused and tier != "wide":
        return render_log_focus_frame(
            view,
            log_pane,
            width,
            height,
            now=now,
            ascii_only=ascii_only,
        )

    inspections = tuple(tuple(line) for line in (inspection_lines or ()))
    compact_inspection = bool(inspections and tier == "compact" and not filtering)

    y = 0
    for spans in _header_lines(
        view,
        width=width,
        tier=tier,
        now=now,
        ascii_only=ascii_only,
        inspection_compact=compact_inspection,
    ):
        if y >= height:
            return canvas
        _write_line(canvas, y, spans, width=width)
        y += 1

    if view.snapshot is None or y >= height:
        return canvas

    if compact_inspection:
        tree_height = max(y, height - len(inspections))
        y = _paint_progress_tree(
            canvas,
            view,
            y=y,
            width=width,
            height=tree_height,
            now=now,
            ascii_only=ascii_only,
        )
        y = max(y, tree_height)
        for spans in inspections:
            if y >= height:
                break
            _write_line(canvas, y, spans, width=width)
            y += 1
        return canvas

    entries = build_stage_list_entries(
        view,
        include_waves=(tier != "compact"),
        visible_stage_ids=visible_stage_ids,
    )
    if filtering and y < height:
        match_count = sum(1 for entry in entries if entry.kind == "stage")
        _write_line(
            canvas,
            y,
            _filter_status_spans(
                filter_query=filter_query,
                filter_editing=filter_editing,
                match_count=match_count,
            ),
            width=width,
        )
        y += 1

    if tier == "compact":
        # Compact keeps the attention/selected stage visible without a full list.
        selected = [entry for entry in entries if entry.kind == "stage" and entry.selected]
        if not selected:
            selected = [entry for entry in entries if entry.kind == "stage"][:1]
        entries = tuple(selected)
    else:
        if y < height:
            _write_line(
                canvas,
                y,
                (
                    wc.StyledText(
                        "Progress tree" if view.run and view.run.mode == "dependency" else "Stages",
                        "heading",
                    ),
                ),
                width=width,
            )
            y += 1

    inspection_rows = min(len(inspections), max(0, height - y))
    content_height = height - inspection_rows
    remaining = content_height - y
    show_persistent_log = log_pane is not None and tier == "wide"
    log_rows = log_reserve_rows(tier, remaining, has_log=show_persistent_log)
    body_height = content_height - log_rows
    detail_available = max(0, body_height - y)
    reserve = detail_reserve_rows(tier, detail_available)
    # Always leave room for the detail pane when any rows remain after stages.
    stage_budget = max(0, detail_available - reserve) if reserve else detail_available
    if tier == "compact" and entries:
        # Compact paints the selected stage first, then a short detail strip.
        stage_budget = min(len(entries), max(1, detail_available - min(3, detail_available)))

    if (
        tier != "compact"
        and stage_budget > 0
        and len(entries) > stage_budget
        and not any(entry.kind == "wave" for entry in entries)
    ):
        selected_index = next(
            (index for index, entry in enumerate(entries) if entry.selected), 0
        )
        start = max(0, selected_index - max(1, stage_budget // 3))
        start = min(start, max(0, len(entries) - stage_budget))
        entries = entries[start : start + stage_budget]

    painted_stages = 0
    for entry in entries:
        if painted_stages >= stage_budget or y >= body_height:
            break
        if entry.kind == "wave":
            _write_line(
                canvas,
                y,
                (wc.StyledText(entry.label, "muted"),),
                width=width,
            )
            y += 1
            painted_stages += 1
            continue
        row_width = width
        spans = _stage_row_spans(entry, width=max(0, row_width - 1), tier=tier)
        canvas.draw_row(
            wc.Rect(0, y, row_width, 1),
            spans,
            selected=entry.selected,
            marker=">",
        )
        y += 1
        painted_stages += 1

    if y < body_height:
        _paint_detail_pane(
            canvas,
            view,
            y=y,
            width=width,
            height=body_height,
            now=now,
            tier=tier,
            ascii_only=ascii_only,
            reveal_paths=show_paths,
        )

    if show_persistent_log and log_pane is not None and log_rows > 0:
        _paint_log_pane(
            canvas,
            log_pane,
            y=body_height,
            width=width,
            height=content_height,
            ascii_only=ascii_only,
            title="Logs",
        )
    inspection_y = content_height
    for spans in inspections:
        if inspection_y >= height:
            break
        _write_line(canvas, inspection_y, spans, width=width)
        inspection_y += 1
    return canvas


def render_details_help_frame(
    view: wt.WorkflowViewModel,
    width: int,
    height: int,
    *,
    now: Optional[datetime] = None,
    ascii_only: bool = False,
) -> wc.Canvas:
    """Explicit details/help view with full contained path labels revealed."""

    return render_primary_frame(
        view,
        width,
        height,
        now=now,
        ascii_only=ascii_only,
        reveal_paths=True,
        details_view=True,
    )


def render_primary_plain(
    view: wt.WorkflowViewModel,
    width: int,
    height: int,
    *,
    now: Optional[datetime] = None,
    ascii_only: bool = False,
    trim_trailing: bool = True,
    reveal_paths: bool = False,
    details_view: bool = False,
    log_pane: Optional[wlog.WorkflowLogPane] = None,
    log_focused: bool = False,
    visible_stage_ids: Optional[Collection[str]] = None,
    filter_query: str = "",
    filter_editing: bool = False,
    tier_width: Optional[int] = None,
    tier_height: Optional[int] = None,
) -> str:
    canvas = render_primary_frame(
        view,
        width,
        height,
        now=now,
        ascii_only=ascii_only,
        reveal_paths=reveal_paths,
        details_view=details_view,
        log_pane=log_pane,
        log_focused=log_focused,
        visible_stage_ids=visible_stage_ids,
        filter_query=filter_query,
        filter_editing=filter_editing,
        tier_width=tier_width,
        tier_height=tier_height,
    )
    return canvas.render_plain(trim_trailing=trim_trailing)


def render_primary_lines(
    view: wt.WorkflowViewModel,
    width: int,
    height: int,
    *,
    now: Optional[datetime] = None,
    ascii_only: bool = False,
    trim_trailing: bool = True,
    reveal_paths: bool = False,
    details_view: bool = False,
    log_pane: Optional[wlog.WorkflowLogPane] = None,
    log_focused: bool = False,
    visible_stage_ids: Optional[Collection[str]] = None,
    filter_query: str = "",
    filter_editing: bool = False,
    tier_width: Optional[int] = None,
    tier_height: Optional[int] = None,
) -> Tuple[str, ...]:
    canvas = render_primary_frame(
        view,
        width,
        height,
        now=now,
        ascii_only=ascii_only,
        reveal_paths=reveal_paths,
        details_view=details_view,
        log_pane=log_pane,
        log_focused=log_focused,
        visible_stage_ids=visible_stage_ids,
        filter_query=filter_query,
        filter_editing=filter_editing,
        tier_width=tier_width,
        tier_height=tier_height,
    )
    return canvas.render_plain_lines(trim_trailing=trim_trailing)
