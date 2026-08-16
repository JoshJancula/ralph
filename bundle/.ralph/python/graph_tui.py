#!/usr/bin/env python3
"""Graph TUI read model, renderer, log pane, operator actions, and lifecycle.

Loads a point-in-time snapshot of one graph run, then renders a deterministic
colorless frame. Log pane reads use the same contained ledger-path contract as
the CLI. Operator decisions bind to `graph-run.sh actions respond` and
`graph-run.sh recover`; this module never writes ledger JSON itself.
Key-to-state navigation stays pure. Curses I/O is loaded only for an
interactive session and is never imported at module load. When curses or a
suitable TTY is unavailable, the same snapshot renders as concise streaming
status. Terminal settings are restored on normal exit, exception, SIGINT,
and SIGTERM.
"""

from __future__ import annotations

import hashlib
import importlib
import json
import os
import re
import subprocess
import sys
import time
from dataclasses import dataclass, field, replace
from datetime import datetime, timezone
from pathlib import Path, PurePosixPath
from typing import Any, Callable, Dict, List, Mapping, Optional, Sequence, Tuple


LOG_STREAMS = ("runner", "agent", "usage")
HEALTH_STATES = ("healthy", "stale", "unknown")
USAGE_RELIABILITY_AUTHORITATIVE = "authoritative"
USAGE_RELIABILITY_UNAVAILABLE = "unavailable"
USAGE_RELIABILITY_MIXED = "mixed"
DEFAULT_HEARTBEAT_TTL_SECONDS = 60
DEFAULT_FRAME_WIDTH = 80
DEFAULT_FRAME_HEIGHT = 24
DEFAULT_PAGE_SIZE = 10
DEFAULT_LOG_TAIL_LINES = 40
DEFAULT_LOG_READ_BYTES = 65536
ATOMIC_READ_ATTEMPTS = 5
ATOMIC_READ_RETRY_SECONDS = 0.01
ACTION_DECISIONS = ("allow-once", "allow-run", "allow-always", "deny")
DEFAULT_ACTION_DECISION = "allow-once"
PERSISTENT_DECISIONS = frozenset({"allow-always"})
CONFIRM_RECOVER = "recover"
CONFIRM_ALLOW_ALWAYS = "allow-always"
_REPLACEMENT = "\ufffd"
_ELLIPSIS = "..."
_CONTROL_CHARS = dict.fromkeys(range(32))
_CONTROL_CHARS[ord("\t")] = " "
REQUEST_ID_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]*$")
ISO_SECONDS_RE = re.compile(r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$")
ATOMIC_TEMP_PREFIXES = (".atomic-json-", ".graph-", ".graph-json-")
_NAV_ACTIONS = {
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
    "q": "quit",
    "r": "refresh",
    "s": "stream-next",
    "f": "follow",
    "/": "filter-start",
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
}
_CURSES_KEY_CODES = {
    258: "down",
    259: "up",
    338: "page-down",
    339: "page-up",
    263: "backspace",
    343: "enter",
    27: "escape",
}

ProcessLookup = Callable[[int], Tuple[str, Optional[str]]]
CommandRunner = Callable[[Sequence[str]], object]


class GraphTuiError(Exception):
    """Raised when a run snapshot cannot be loaded at all."""


@dataclass(frozen=True)
class GraphTuiRun:
    run_id: str
    namespace: str
    status: str
    started_at: Optional[str]
    plan_path: Optional[str]
    schema_version: int
    supervisor_pid: Optional[int]
    owner_hostname: Optional[str]
    owner_process_start_id: Optional[str]
    heartbeat_at: Optional[str]
    max_parallel: Optional[int]
    raw: Mapping[str, object] = field(default_factory=dict)


@dataclass(frozen=True)
class GraphTuiAttempt:
    attempt_id: str
    node_id: str
    outcome: Optional[str]
    started_at: Optional[str]
    finished_at: Optional[str]
    runtime: Optional[str]
    usage_snapshot: Optional[Mapping[str, object]]
    usage_reliable: Optional[bool]
    usage_reliability: str
    log_paths: Mapping[str, str]


@dataclass(frozen=True)
class GraphTuiNode:
    node_id: str
    type: str
    runtime: Optional[str]
    status: str
    attempt_count: int
    attempts: Tuple[GraphTuiAttempt, ...]
    last_attempt_id: Optional[str]
    workspace_mode: Optional[str]
    frozen_base: Optional[str]
    write_scopes: Tuple[str, ...]


@dataclass(frozen=True)
class GraphTuiPendingAction:
    request_id: str
    node_id: str
    runtime: str
    action: str
    resource: str
    effect: str
    choices: Tuple[str, ...]
    classification: str = ""


@dataclass(frozen=True)
class GraphTuiLogMetadata:
    stream: str
    node_id: Optional[str]
    attempt_id: Optional[str]
    relative_path: Optional[str]
    exists: bool
    size_bytes: Optional[int]
    missing: bool
    uncontained: bool
    symlink: bool
    truncated: bool
    error: Optional[str]


@dataclass(frozen=True)
class GraphTuiLogPane:
    """Bounded, contained view of one selected attempt stream."""

    stream: str
    node_id: Optional[str]
    attempt_id: Optional[str]
    relative_path: Optional[str]
    lines: Tuple[str, ...]
    exists: bool
    size_bytes: Optional[int]
    missing: bool
    uncontained: bool
    symlink: bool
    truncated: bool
    omitted: bool
    replaced: bool
    follow: bool
    reset: bool
    offset: int
    inode: Optional[int]
    error: Optional[str]


@dataclass(frozen=True)
class GraphTuiSnapshot:
    run: GraphTuiRun
    nodes: Tuple[GraphTuiNode, ...]
    attempts: Tuple[GraphTuiAttempt, ...]
    health: str
    usage_reliability: str
    pending_actions: Tuple[GraphTuiPendingAction, ...]
    selected_log: GraphTuiLogMetadata
    events: Tuple[Mapping[str, object], ...]
    warnings: Tuple[str, ...]


@dataclass(frozen=True)
class GraphTuiState:
    """Pure interactive navigation and action-selection state. No I/O."""

    selected_node_id: Optional[str] = None
    selected_attempt_id: Optional[str] = None
    selected_index: int = 0
    page_size: int = DEFAULT_PAGE_SIZE
    filter_query: str = ""
    filter_editing: bool = False
    filter_backup: str = ""
    quit_requested: bool = False
    refresh_requested: bool = False
    selected_stream: str = "runner"
    log_follow: bool = False
    log_offset: int = 0
    log_inode: Optional[int] = None
    log_seen: bool = False
    action_open: bool = False
    selected_request_id: Optional[str] = None
    selected_decision: str = DEFAULT_ACTION_DECISION
    confirm_kind: Optional[str] = None
    confirm_rule: Optional[str] = None
    action_pending_submit: bool = False
    last_action_error: Optional[str] = None
    last_action_command: Optional[Tuple[str, ...]] = None


@dataclass(frozen=True)
class GraphTuiCommand:
    """Argv for the existing graph-run action/recover CLI."""

    argv: Tuple[str, ...]
    kind: str
    request_id: Optional[str] = None
    decision: Optional[str] = None
    confirm_rule: Optional[str] = None
    needs_confirmation: bool = False


@dataclass(frozen=True)
class GraphTuiCommandResult:
    returncode: int
    stdout: str = ""
    stderr: str = ""
    argv: Tuple[str, ...] = ()


def sanitize_id(identifier: str) -> str:
    return re.sub(r"[^A-Za-z0-9._-]", "_", identifier)


def classify_health(
    run: Mapping[str, object],
    *,
    now_epoch: Optional[int] = None,
    ttl_seconds: int = DEFAULT_HEARTBEAT_TTL_SECONDS,
    process_lookup: Optional[ProcessLookup] = None,
) -> str:
    """Read-only owner-health classifier. Matches graph-heartbeat.sh."""
    heartbeat_at = _optional_str(run.get("heartbeatAt"))
    if not heartbeat_at:
        return "unknown"
    heartbeat_epoch = _iso_to_epoch(heartbeat_at)
    if heartbeat_epoch is None:
        return "unknown"
    if ttl_seconds < 0:
        ttl_seconds = DEFAULT_HEARTBEAT_TTL_SECONDS
    if now_epoch is None:
        now_epoch = int(time.time())
    if (now_epoch - heartbeat_epoch) < ttl_seconds:
        return "healthy"

    pid = _optional_int(run.get("supervisorPid"))
    owner_start_id = _optional_str(run.get("ownerProcessStartId"))
    if pid is None or not owner_start_id:
        return "unknown"
    lookup = process_lookup or inspect_process
    status, current_start_id = lookup(pid)
    if status == "unavailable":
        return "unknown"
    if status == "dead":
        return "stale"
    if current_start_id != owner_start_id:
        return "stale"
    return "unknown"


def inspect_process(pid: int) -> Tuple[str, Optional[str]]:
    """Best-effort process-start identity. Fail-closed to unavailable."""
    if os.environ.get("GRAPH_TUI_PROCESS_LOOKUP") == "off":
        return "unavailable", None
    if pid <= 0:
        return "dead", None
    proc_dir = Path("/proc") / str(pid)
    if Path("/proc").is_dir():
        if proc_dir.is_dir():
            try:
                start = str(int(proc_dir.stat().st_ctime))
            except OSError:
                return "unavailable", None
            return "alive", start
        return "dead", None
    return "unavailable", None


def unique_attempts(records: Sequence[Mapping[str, object]], node_id: str) -> List[GraphTuiAttempt]:
    """Collapse v1 running+terminal duplicates to one record per attemptId."""
    merged: Dict[str, Dict[str, object]] = {}
    order: List[str] = []
    for raw in records:
        if not isinstance(raw, Mapping):
            continue
        attempt_id = _optional_str(raw.get("attemptId"))
        if not attempt_id:
            continue
        if attempt_id not in merged:
            merged[attempt_id] = {}
            order.append(attempt_id)
        merged[attempt_id] = _merge_attempt(merged[attempt_id], raw)
    return [_attempt_from_record(node_id, attempt_id, merged[attempt_id]) for attempt_id in order]


def load_snapshot(
    run_dir: str | os.PathLike[str],
    *,
    selected_node_id: Optional[str] = None,
    selected_attempt_id: Optional[str] = None,
    selected_stream: str = "runner",
    now_epoch: Optional[int] = None,
    heartbeat_ttl_seconds: int = DEFAULT_HEARTBEAT_TTL_SECONDS,
    process_lookup: Optional[ProcessLookup] = None,
) -> GraphTuiSnapshot:
    """Load a side-effect-free snapshot of one graph run directory."""
    root = Path(run_dir)
    warnings: List[str] = []
    run_raw = _read_json_atomic(root / "run.json")
    if run_raw is None:
        raise GraphTuiError(f"run.json is missing or unreadable: {root / 'run.json'}")
    run = _normalize_run(run_raw, root)

    graph_raw = _read_json_atomic(root / "graph.json")
    graph_nodes = _graph_node_specs(graph_raw) if graph_raw is not None else []
    if graph_raw is None and (root / "graph.json").exists():
        warnings.append("frozen graph.json was unreadable; node order falls back to ledger files")

    nodes = _load_nodes(root, graph_nodes, warnings)
    attempts = tuple(attempt for node in nodes for attempt in node.attempts)
    health = classify_health(
        run.raw,
        now_epoch=now_epoch,
        ttl_seconds=heartbeat_ttl_seconds,
        process_lookup=process_lookup,
    )
    usage_reliability = _aggregate_usage_reliability(attempts)
    pending_actions = tuple(_load_pending_actions(root, warnings))
    events, event_warnings = read_events(root / "events.jsonl")
    warnings.extend(event_warnings)
    selected_log = select_log_metadata(
        root,
        nodes,
        selected_node_id=selected_node_id,
        selected_attempt_id=selected_attempt_id,
        selected_stream=selected_stream,
    )
    return GraphTuiSnapshot(
        run=run,
        nodes=tuple(nodes),
        attempts=attempts,
        health=health,
        usage_reliability=usage_reliability,
        pending_actions=pending_actions,
        selected_log=selected_log,
        events=tuple(events),
        warnings=tuple(warnings),
    )


def read_events(path: Path) -> Tuple[List[Mapping[str, object]], List[str]]:
    """Read events.jsonl. Ignore one truncated final line. Interior errors warn."""
    if not path.is_file() or path.is_symlink():
        return [], []
    try:
        raw = _read_bytes_atomic(path)
    except OSError:
        return [], ["event journal could not be read"]
    if raw is None:
        return [], []
    ends_newline = bool(raw) and raw.endswith(b"\n")
    text = raw.decode("utf-8", errors="replace")
    lines = text.splitlines()
    events: List[Mapping[str, object]] = []
    for index, line in enumerate(lines):
        if not line.strip():
            continue
        try:
            payload = json.loads(line)
        except json.JSONDecodeError:
            if index == len(lines) - 1 and not ends_newline:
                return events, []
            return events, ["event journal has a malformed interior line; event-derived details omitted"]
        if not isinstance(payload, dict):
            if index == len(lines) - 1 and not ends_newline:
                return events, []
            return events, ["event journal has a malformed interior line; event-derived details omitted"]
        events.append(payload)
    return events, []


def select_log_metadata(
    run_dir: Path,
    nodes: Sequence[GraphTuiNode],
    *,
    selected_node_id: Optional[str] = None,
    selected_attempt_id: Optional[str] = None,
    selected_stream: str = "runner",
) -> GraphTuiLogMetadata:
    stream = selected_stream if selected_stream in LOG_STREAMS else "runner"
    node = _select_node(nodes, selected_node_id)
    if node is None:
        return GraphTuiLogMetadata(
            stream=stream,
            node_id=selected_node_id,
            attempt_id=selected_attempt_id,
            relative_path=None,
            exists=False,
            size_bytes=None,
            missing=True,
            uncontained=False,
            symlink=False,
            truncated=False,
            error=None,
        )
    attempt = _select_attempt(node, selected_attempt_id)
    if attempt is None:
        return GraphTuiLogMetadata(
            stream=stream,
            node_id=node.node_id,
            attempt_id=selected_attempt_id or node.last_attempt_id,
            relative_path=None,
            exists=False,
            size_bytes=None,
            missing=True,
            uncontained=False,
            symlink=False,
            truncated=False,
            error=None,
        )
    rel = attempt.log_paths.get(stream)
    if not rel:
        return GraphTuiLogMetadata(
            stream=stream,
            node_id=node.node_id,
            attempt_id=attempt.attempt_id,
            relative_path=None,
            exists=False,
            size_bytes=None,
            missing=True,
            uncontained=False,
            symlink=False,
            truncated=False,
            error=None,
        )
    if not _is_contained_rel(rel):
        return GraphTuiLogMetadata(
            stream=stream,
            node_id=node.node_id,
            attempt_id=attempt.attempt_id,
            relative_path=rel,
            exists=False,
            size_bytes=None,
            missing=False,
            uncontained=True,
            symlink=False,
            truncated=False,
            error="graph log path is not a ledger-owned contained relative path",
        )
    resolved = _resolve_contained(run_dir, rel)
    if resolved is None:
        return GraphTuiLogMetadata(
            stream=stream,
            node_id=node.node_id,
            attempt_id=attempt.attempt_id,
            relative_path=rel,
            exists=False,
            size_bytes=None,
            missing=False,
            uncontained=True,
            symlink=False,
            truncated=False,
            error="graph log path is not contained in the run-dir",
        )
    if resolved.is_symlink():
        return GraphTuiLogMetadata(
            stream=stream,
            node_id=node.node_id,
            attempt_id=attempt.attempt_id,
            relative_path=rel,
            exists=False,
            size_bytes=None,
            missing=False,
            uncontained=False,
            symlink=True,
            truncated=False,
            error="refusing to read a graph log symlink",
        )
    if not resolved.is_file():
        return GraphTuiLogMetadata(
            stream=stream,
            node_id=node.node_id,
            attempt_id=attempt.attempt_id,
            relative_path=rel,
            exists=False,
            size_bytes=None,
            missing=True,
            uncontained=False,
            symlink=False,
            truncated=False,
            error=None,
        )
    try:
        size = resolved.stat().st_size
        truncated = False
        if size > 0:
            with resolved.open("rb") as handle:
                handle.seek(-1, os.SEEK_END)
                truncated = handle.read(1) != b"\n"
    except OSError:
        return GraphTuiLogMetadata(
            stream=stream,
            node_id=node.node_id,
            attempt_id=attempt.attempt_id,
            relative_path=rel,
            exists=False,
            size_bytes=None,
            missing=True,
            uncontained=False,
            symlink=False,
            truncated=False,
            error="graph log file could not be inspected",
        )
    return GraphTuiLogMetadata(
        stream=stream,
        node_id=node.node_id,
        attempt_id=attempt.attempt_id,
        relative_path=rel,
        exists=True,
        size_bytes=size,
        missing=False,
        uncontained=False,
        symlink=False,
        truncated=truncated,
        error=None,
    )


def normalize_log_stream(stream: Optional[str]) -> str:
    if stream in LOG_STREAMS:
        return stream
    return "runner"


def cycle_log_stream(stream: Optional[str], *, delta: int = 1) -> str:
    current = normalize_log_stream(stream)
    index = LOG_STREAMS.index(current)
    return LOG_STREAMS[(index + delta) % len(LOG_STREAMS)]


def read_log_pane(
    run_dir: str | os.PathLike[str],
    snapshot: GraphTuiSnapshot,
    state: Optional[GraphTuiState] = None,
    *,
    tail_lines: int = DEFAULT_LOG_TAIL_LINES,
) -> Tuple[GraphTuiLogPane, GraphTuiState]:
    """Read the selected attempt stream through the CLI contained-path contract.

    Follow refresh reuses a byte/inode cursor. A smaller file or inode change
    resets the cursor. Invalid UTF-8 and NUL bytes become U+FFFD. Never writes.
    """
    root = Path(run_dir)
    current = state if state is not None else initial_state(snapshot)
    stream = normalize_log_stream(current.selected_stream)
    current = replace(current, selected_stream=stream)
    tail_n = _clamp_tail_lines(tail_lines)
    meta = select_log_metadata(
        root,
        snapshot.nodes,
        selected_node_id=current.selected_node_id,
        selected_attempt_id=current.selected_attempt_id,
        selected_stream=stream,
    )
    follow = bool(current.log_follow)
    if meta.uncontained or meta.symlink or meta.missing or not meta.exists or not meta.relative_path:
        pane = _pane_from_meta(meta, follow=follow, omitted=False, replaced=False, reset=False, offset=0, inode=None)
        return pane, _reset_log_cursor(current)

    resolved = _resolve_contained(root, meta.relative_path)
    if resolved is None:
        pane = _pane_from_meta(
            replace(meta, uncontained=True, exists=False, missing=False, error="graph log path is not contained in the run-dir"),
            follow=follow,
            omitted=False,
            replaced=False,
            reset=False,
            offset=0,
            inode=None,
        )
        return pane, _reset_log_cursor(current)
    if resolved.is_symlink():
        pane = _pane_from_meta(
            replace(meta, symlink=True, exists=False, error="refusing to read a graph log symlink"),
            follow=follow,
            omitted=False,
            replaced=False,
            reset=False,
            offset=0,
            inode=None,
        )
        return pane, _reset_log_cursor(current)
    if not resolved.is_file():
        pane = _pane_from_meta(
            replace(meta, missing=True, exists=False, size_bytes=None),
            follow=follow,
            omitted=False,
            replaced=False,
            reset=False,
            offset=0,
            inode=None,
        )
        return pane, _reset_log_cursor(current)

    try:
        stat = resolved.stat()
        size = int(stat.st_size)
        inode = int(stat.st_ino)
        raw, omitted_bytes = _read_log_tail_bytes(resolved, size)
    except OSError:
        pane = _pane_from_meta(
            replace(meta, exists=False, missing=True, size_bytes=None, error="graph log file could not be inspected"),
            follow=follow,
            omitted=False,
            replaced=False,
            reset=False,
            offset=0,
            inode=None,
        )
        return pane, _reset_log_cursor(current)

    reset = False
    if current.log_seen:
        if current.log_inode is not None and inode != current.log_inode:
            reset = True
        elif current.log_offset > size:
            reset = True

    text, replaced = _decode_log_bytes(raw)
    all_lines = tuple(_sanitize_log_line(line) for line in text.splitlines())
    omitted = omitted_bytes
    if tail_n < len(all_lines):
        lines = all_lines[-tail_n:]
        omitted = True
    else:
        lines = all_lines

    pane = GraphTuiLogPane(
        stream=meta.stream,
        node_id=meta.node_id,
        attempt_id=meta.attempt_id,
        relative_path=meta.relative_path,
        lines=lines,
        exists=True,
        size_bytes=size,
        missing=False,
        uncontained=False,
        symlink=False,
        truncated=bool(meta.truncated or reset),
        omitted=omitted,
        replaced=replaced,
        follow=follow,
        reset=reset,
        offset=size,
        inode=inode,
        error=None,
    )
    updated = replace(current, log_offset=size, log_inode=inode, log_seen=True)
    return pane, updated


def clip_text(text: str, width: int, *, pad: bool = False) -> str:
    """Truncate to width without raising. Optional space-padding for frames."""
    width = _clamp_dim(width, 0)
    cleaned = _sanitize_text(text)
    if width <= 0:
        return ""
    if len(cleaned) <= width:
        return cleaned.ljust(width) if pad else cleaned
    if width <= 3:
        return cleaned[:width]
    return cleaned[: width - len(_ELLIPSIS)] + _ELLIPSIS


def format_duration(started_at: Optional[str], finished_at: Optional[str]) -> str:
    """Format attempt elapsed time as HH:MM:SS, or '-' when incomplete."""
    if not started_at or not finished_at:
        return "-"
    start = _iso_to_epoch(started_at)
    end = _iso_to_epoch(finished_at)
    if start is None or end is None or end < start:
        return "-"
    hours, rem = divmod(end - start, 3600)
    minutes, seconds = divmod(rem, 60)
    return f"{hours:02d}:{minutes:02d}:{seconds:02d}"


def format_scopes(scopes: Sequence[str]) -> str:
    if not scopes:
        return "-"
    if len(scopes) == 1:
        return scopes[0]
    return f"{scopes[0]} +{len(scopes) - 1}"


def render_frame(
    snapshot: GraphTuiSnapshot,
    *,
    width: int = DEFAULT_FRAME_WIDTH,
    height: int = DEFAULT_FRAME_HEIGHT,
    selected_node_id: Optional[str] = None,
    selected_attempt_id: Optional[str] = None,
    log_pane: Optional[GraphTuiLogPane] = None,
    state: Optional[GraphTuiState] = None,
) -> str:
    """Render a deterministic colorless frame. No curses and no I/O."""
    return "\n".join(
        render_lines(
            snapshot,
            width=width,
            height=height,
            selected_node_id=selected_node_id,
            selected_attempt_id=selected_attempt_id,
            log_pane=log_pane,
            state=state,
        )
    )


def render_lines(
    snapshot: GraphTuiSnapshot,
    *,
    width: int = DEFAULT_FRAME_WIDTH,
    height: int = DEFAULT_FRAME_HEIGHT,
    selected_node_id: Optional[str] = None,
    selected_attempt_id: Optional[str] = None,
    log_pane: Optional[GraphTuiLogPane] = None,
    state: Optional[GraphTuiState] = None,
) -> List[str]:
    """Return exactly `height` lines, each exactly `width` characters."""
    width = _clamp_dim(width, DEFAULT_FRAME_WIDTH)
    height = _clamp_dim(height, DEFAULT_FRAME_HEIGHT)
    if height == 0:
        return []

    selected = _resolve_selected_node(snapshot.nodes, selected_node_id)
    attempt = _resolve_selected_attempt(selected, selected_attempt_id)
    header = _render_header(snapshot)
    summary = _render_summary(snapshot)
    detail = _render_detail(snapshot, selected, attempt)
    footer = _render_footer(snapshot, state)
    table_header = _table_header()
    pending_block = _render_pending_block(snapshot, state)
    log_block = _render_log_block(log_pane) if log_pane is not None else []

    if height == 1:
        return [_fit_line(header, width)]

    body_budget = height - 2
    summary_budget = min(len(summary), body_budget)
    remaining = body_budget - summary_budget
    detail_budget = min(len(detail), remaining)
    remaining -= detail_budget
    separator_budget = 1 if remaining > 0 and detail_budget > 0 else 0
    remaining -= separator_budget
    pending_budget = 0
    pending_separator = 0
    log_budget = 0
    log_separator = 0
    if pending_block and remaining > 0:
        min_table = 2 if snapshot.nodes and remaining >= 4 else 0
        pending_budget = min(len(pending_block), max(0, remaining - min_table))
        if pending_budget > 0:
            remaining -= pending_budget
            if remaining > min_table:
                pending_separator = 1
                remaining -= 1
    if log_block and remaining > 0:
        min_table = 2 if snapshot.nodes and remaining >= 4 else 0
        log_budget = min(len(log_block), max(0, remaining - min_table))
        if log_budget > 0:
            remaining -= log_budget
            if remaining > min_table:
                log_separator = 1
                remaining -= 1
    table_budget = remaining

    lines: List[str] = [header]
    lines.extend(summary[:summary_budget])
    if table_budget > 0:
        lines.append(table_header)
        row_budget = table_budget - 1
        if row_budget > 0:
            lines.extend(_table_rows(snapshot.nodes, selected, row_budget))
    if separator_budget:
        lines.append("-" * max(width, 1))
    lines.extend(detail[:detail_budget])
    if pending_separator:
        lines.append("-" * max(width, 1))
    lines.extend(pending_block[:pending_budget])
    if log_separator:
        lines.append("-" * max(width, 1))
    lines.extend(log_block[:log_budget])
    lines.append(footer)

    fitted = [_fit_line(line, width) for line in lines[:height]]
    while len(fitted) < height:
        insert_at = max(len(fitted) - 1, 0)
        fitted.insert(insert_at, _fit_line("", width))
    return fitted[:height]


def initial_state(
    snapshot: GraphTuiSnapshot,
    *,
    page_size: int = DEFAULT_PAGE_SIZE,
    selected_node_id: Optional[str] = None,
    selected_attempt_id: Optional[str] = None,
    selected_stream: Optional[str] = None,
    log_follow: bool = False,
) -> GraphTuiState:
    """Build navigation state with a valid selection for `snapshot`."""
    selected = _resolve_selected_node(snapshot.nodes, selected_node_id)
    attempt = _resolve_selected_attempt(selected, selected_attempt_id)
    stream = normalize_log_stream(selected_stream or snapshot.selected_log.stream)
    state = GraphTuiState(
        selected_node_id=selected.node_id if selected else None,
        selected_attempt_id=attempt.attempt_id if attempt else (selected.last_attempt_id if selected else None),
        page_size=_clamp_page_size(page_size),
        selected_stream=stream,
        log_follow=bool(log_follow),
    )
    return _reconcile_action(_reconcile_selection(state, snapshot), snapshot)


def visible_nodes(snapshot: GraphTuiSnapshot, state: GraphTuiState) -> Tuple[GraphTuiNode, ...]:
    """Return nodes matching the current filter, preserving snapshot order."""
    query = (state.filter_query or "").casefold()
    if not query:
        return snapshot.nodes
    matched = [node for node in snapshot.nodes if _node_matches_filter(node, query)]
    return tuple(matched)


def apply_key(state: GraphTuiState, key: object, snapshot: GraphTuiSnapshot) -> GraphTuiState:
    """Return the next navigation or action-selection state. Never mutates inputs."""
    if state.filter_editing:
        return _apply_filter_key(state, key, snapshot)
    if state.confirm_kind:
        confirmed = _apply_confirm_key(state, key, snapshot)
        if confirmed is not None:
            return confirmed
    action = _nav_action(key)
    if state.action_open:
        handled = _apply_action_key(state, key, snapshot, action)
        if handled is not None:
            return handled
    elif _is_action_open_key(key) and snapshot.pending_actions:
        return _open_action(state, snapshot)
    elif _is_deny_key(key) and snapshot.pending_actions:
        return _request_submit(_open_action(state, snapshot), snapshot, decision="deny")
    elif _is_recover_key(key) and snapshot.health == "stale":
        return replace(state, confirm_kind=CONFIRM_RECOVER, action_pending_submit=False)
    if action == "down":
        return _move_selection(state, snapshot, 1)
    if action == "up":
        return _move_selection(state, snapshot, -1)
    if action == "page-down":
        return _move_selection(state, snapshot, state.page_size)
    if action == "page-up":
        return _move_selection(state, snapshot, -state.page_size)
    if action == "filter-start":
        return replace(state, filter_editing=True, filter_backup=state.filter_query, filter_query="")
    if action == "quit":
        return replace(state, quit_requested=True)
    if action == "refresh":
        return replace(state, refresh_requested=True)
    if action == "stream-next":
        return _reset_log_cursor(replace(state, selected_stream=cycle_log_stream(state.selected_stream)))
    if action == "follow":
        return replace(state, log_follow=not state.log_follow)
    return state


def apply_keys(
    state: GraphTuiState,
    keys: Sequence[object],
    snapshot: GraphTuiSnapshot,
) -> GraphTuiState:
    current = state
    for key in keys:
        current = apply_key(current, key, snapshot)
    return current


def apply_snapshot(state: GraphTuiState, snapshot: GraphTuiSnapshot) -> GraphTuiState:
    """Revalidate selection after a refresh or node-set change. Pure."""
    current = replace(
        state,
        refresh_requested=False,
        page_size=_clamp_page_size(state.page_size),
        selected_stream=normalize_log_stream(state.selected_stream),
    )
    previous_node = current.selected_node_id
    previous_attempt = current.selected_attempt_id
    previous_stream = current.selected_stream
    reconciled = _reconcile_action(_reconcile_selection(current, snapshot), snapshot)
    reconciled = replace(reconciled, action_pending_submit=False)
    if (
        reconciled.selected_node_id != previous_node
        or reconciled.selected_attempt_id != previous_attempt
        or reconciled.selected_stream != previous_stream
    ):
        return _reset_log_cursor(reconciled)
    return reconciled


def default_graph_run() -> Path:
    return Path(__file__).resolve().parent.parent / "graph-run.sh"


def available_decisions(action: GraphTuiPendingAction) -> Tuple[str, ...]:
    if action.choices:
        return tuple(choice for choice in action.choices if choice in ACTION_DECISIONS)
    return ACTION_DECISIONS


def default_decision(action: GraphTuiPendingAction) -> str:
    choices = available_decisions(action)
    if DEFAULT_ACTION_DECISION in choices:
        return DEFAULT_ACTION_DECISION
    if choices:
        return choices[0]
    return DEFAULT_ACTION_DECISION


def decision_requires_confirmation(decision: str) -> bool:
    return decision in PERSISTENT_DECISIONS


def selected_pending_action(
    snapshot: GraphTuiSnapshot, state: GraphTuiState
) -> Optional[GraphTuiPendingAction]:
    if not snapshot.pending_actions:
        return None
    if state.selected_request_id:
        for item in snapshot.pending_actions:
            if item.request_id == state.selected_request_id:
                return item
    return snapshot.pending_actions[0]


def normalize_approval_resource(resource: str) -> str:
    value = (resource or "").strip()
    while value.startswith("./"):
        value = value[2:]
    while "//" in value:
        value = value.replace("//", "/")
    if value != "/" and value.endswith("/"):
        value = value.rstrip("/")
    return value


def approval_rule_id(runtime: str, action: str, resource: str, effect: str) -> str:
    """Match graph_approval_rule_id: sha256 of normalized runtime/action/resource/effect lines."""
    runtime_n = (runtime or "").strip().lower()
    action_n = (action or "").strip()
    resource_n = normalize_approval_resource(resource)
    effect_n = (effect or "").strip().lower()
    payload = f"{runtime_n}\n{action_n}\n{resource_n}\n{effect_n}\n"
    return hashlib.sha256(payload.encode("utf-8")).hexdigest()


def build_action_command(
    snapshot: GraphTuiSnapshot,
    state: GraphTuiState,
    *,
    graph_run: Optional[str | os.PathLike[str]] = None,
    workspace: Optional[str | os.PathLike[str]] = None,
) -> Optional[GraphTuiCommand]:
    """Build argv for graph-run.sh actions respond or recover. No I/O."""
    script = str(graph_run or default_graph_run())
    if state.confirm_kind == CONFIRM_RECOVER:
        argv = [
            "bash",
            script,
            "recover",
            "--namespace",
            snapshot.run.namespace,
            "--run",
            snapshot.run.run_id,
        ]
        if workspace:
            argv.extend(["--workspace", str(workspace)])
        return GraphTuiCommand(
            argv=tuple(argv),
            kind="recover",
            needs_confirmation=not state.action_pending_submit,
        )
    action = selected_pending_action(snapshot, state)
    if action is None:
        return None
    decision = state.selected_decision
    if decision not in available_decisions(action):
        decision = default_decision(action)
    argv = [
        "bash",
        script,
        "actions",
        "respond",
        action.request_id,
        "--decision",
        decision,
        "--namespace",
        snapshot.run.namespace,
        "--run",
        snapshot.run.run_id,
        "--json",
    ]
    if workspace:
        argv.extend(["--workspace", str(workspace)])
    confirm_rule = state.confirm_rule if decision == CONFIRM_ALLOW_ALWAYS else None
    if confirm_rule:
        argv.extend(["--confirm-rule", confirm_rule])
    return GraphTuiCommand(
        argv=tuple(argv),
        kind="respond",
        request_id=action.request_id,
        decision=decision,
        confirm_rule=confirm_rule,
        needs_confirmation=decision_requires_confirmation(decision) and not confirm_rule,
    )


def dispatch_action(
    state: GraphTuiState,
    snapshot: GraphTuiSnapshot,
    *,
    runner: Optional[CommandRunner] = None,
    graph_run: Optional[str | os.PathLike[str]] = None,
    workspace: Optional[str | os.PathLike[str]] = None,
) -> GraphTuiState:
    """Invoke the action command API when a submit is pending. Refresh on success."""
    if not state.action_pending_submit:
        return state
    command = build_action_command(snapshot, state, graph_run=graph_run, workspace=workspace)
    if command is None:
        return replace(state, action_pending_submit=False, last_action_error="no pending action")
    if command.kind == "respond" and command.decision == CONFIRM_ALLOW_ALWAYS and not command.confirm_rule:
        action = selected_pending_action(snapshot, state)
        rule = (
            approval_rule_id(action.runtime, action.action, action.resource, action.effect)
            if action is not None
            else None
        )
        return replace(
            state,
            action_pending_submit=False,
            confirm_kind=CONFIRM_ALLOW_ALWAYS,
            confirm_rule=rule,
            last_action_error="allow-always requires confirmation",
        )
    invoke = runner or run_action_command
    result = _as_command_result(invoke(command.argv), command.argv)
    if result.returncode == 0:
        return replace(
            state,
            action_pending_submit=False,
            action_open=False,
            confirm_kind=None,
            confirm_rule=None,
            refresh_requested=True,
            last_action_error=None,
            last_action_command=command.argv,
        )
    error = _command_error_line(result)
    return replace(
        state,
        action_pending_submit=False,
        refresh_requested=False,
        last_action_error=error,
        last_action_command=command.argv,
    )


def apply_action_key(
    state: GraphTuiState,
    key: object,
    snapshot: GraphTuiSnapshot,
    *,
    runner: Optional[CommandRunner] = None,
    graph_run: Optional[str | os.PathLike[str]] = None,
    workspace: Optional[str | os.PathLike[str]] = None,
) -> GraphTuiState:
    """Apply one key, then dispatch a pending submit through the action API."""
    next_state = apply_key(state, key, snapshot)
    return dispatch_action(
        next_state,
        snapshot,
        runner=runner,
        graph_run=graph_run,
        workspace=workspace,
    )


def run_action_command(argv: Sequence[str]) -> GraphTuiCommandResult:
    completed = subprocess.run(list(argv), capture_output=True, text=True)
    return GraphTuiCommandResult(
        returncode=int(completed.returncode),
        stdout=completed.stdout or "",
        stderr=completed.stderr or "",
        argv=tuple(argv),
    )


def _as_command_result(raw: object, argv: Sequence[str]) -> GraphTuiCommandResult:
    if isinstance(raw, GraphTuiCommandResult):
        return raw
    return GraphTuiCommandResult(
        returncode=int(getattr(raw, "returncode", 1) or 0),
        stdout=str(getattr(raw, "stdout", "") or ""),
        stderr=str(getattr(raw, "stderr", "") or ""),
        argv=tuple(getattr(raw, "argv", argv) or argv),
    )


def _command_error_line(result: GraphTuiCommandResult) -> str:
    for blob in (result.stderr, result.stdout):
        text = (blob or "").strip()
        if text:
            return text.splitlines()[-1]
    return "action command failed"


def _reconcile_action(state: GraphTuiState, snapshot: GraphTuiSnapshot) -> GraphTuiState:
    pending = snapshot.pending_actions
    pending_ids = [item.request_id for item in pending]
    confirm_kind = state.confirm_kind
    if confirm_kind == CONFIRM_RECOVER and snapshot.health != "stale":
        confirm_kind = None
    if confirm_kind == CONFIRM_ALLOW_ALWAYS and state.selected_decision != CONFIRM_ALLOW_ALWAYS:
        confirm_kind = None
    if state.selected_request_id and state.selected_request_id in pending_ids:
        action = next(item for item in pending if item.request_id == state.selected_request_id)
        decision = (
            state.selected_decision
            if state.selected_decision in available_decisions(action)
            else default_decision(action)
        )
        if confirm_kind == CONFIRM_ALLOW_ALWAYS and decision != CONFIRM_ALLOW_ALWAYS:
            confirm_kind = None
        return replace(
            state,
            selected_request_id=action.request_id,
            selected_decision=decision,
            confirm_kind=confirm_kind,
            confirm_rule=state.confirm_rule if confirm_kind == CONFIRM_ALLOW_ALWAYS else None,
            action_open=state.action_open,
        )
    if pending:
        action = pending[0]
        return replace(
            state,
            selected_request_id=action.request_id,
            selected_decision=default_decision(action),
            action_open=state.action_open,
            confirm_kind=confirm_kind if confirm_kind == CONFIRM_RECOVER else None,
            confirm_rule=None,
        )
    return replace(
        state,
        selected_request_id=None,
        selected_decision=DEFAULT_ACTION_DECISION,
        action_open=False,
        confirm_kind=confirm_kind if confirm_kind == CONFIRM_RECOVER else None,
        confirm_rule=None,
        action_pending_submit=False,
    )


def _is_action_open_key(key: object) -> bool:
    return _key_letter(key) == "a"


def _is_deny_key(key: object) -> bool:
    return _key_letter(key) == "d"


def _is_recover_key(key: object) -> bool:
    return _key_letter(key) == "c"


def _key_letter(key: object) -> Optional[str]:
    if isinstance(key, str) and len(key) == 1 and key.isalpha():
        return key.lower()
    return None


def _decision_from_key(key: object) -> Optional[str]:
    if key in {"1", "o", "O"}:
        return "allow-once"
    if key in {"2"}:
        return "allow-run"
    if key in {"3"}:
        return "allow-always"
    if key in {"4"}:
        return "deny"
    letter = _key_letter(key)
    if letter == "o":
        return "allow-once"
    return None


def _apply_confirm_key(
    state: GraphTuiState, key: object, _snapshot: GraphTuiSnapshot
) -> Optional[GraphTuiState]:
    action = _nav_action(key)
    letter = _key_letter(key)
    if letter == "y" or action == "enter":
        return replace(state, action_pending_submit=True)
    if letter == "n" or action == "escape":
        if state.confirm_kind == CONFIRM_RECOVER:
            return replace(state, confirm_kind=None, action_pending_submit=False, confirm_rule=None)
        return replace(state, confirm_kind=None, confirm_rule=None, action_pending_submit=False)
    if action == "quit":
        return replace(state, quit_requested=True)
    if action == "refresh":
        return replace(state, refresh_requested=True)
    return state


def _apply_action_key(
    state: GraphTuiState,
    key: object,
    snapshot: GraphTuiSnapshot,
    action: Optional[str],
) -> Optional[GraphTuiState]:
    if action in {"down", "up"} or _is_action_open_key(key):
        delta = 1 if action == "down" or _is_action_open_key(key) else -1
        return _move_pending(state, snapshot, delta)
    decision = _decision_from_key(key)
    if decision:
        item = selected_pending_action(snapshot, state)
        if item is None or decision not in available_decisions(item):
            return state
        return replace(
            state,
            selected_decision=decision,
            confirm_kind=None,
            confirm_rule=None,
            action_pending_submit=False,
        )
    if _is_deny_key(key):
        return _request_submit(state, snapshot, decision="deny")
    if action == "enter":
        return _request_submit(state, snapshot)
    if action == "escape":
        return replace(
            state,
            action_open=False,
            action_pending_submit=False,
            confirm_kind=None,
            confirm_rule=None,
        )
    return None


def _open_action(state: GraphTuiState, snapshot: GraphTuiSnapshot) -> GraphTuiState:
    if not snapshot.pending_actions:
        return state
    if state.action_open:
        return _move_pending(state, snapshot, 1)
    current = selected_pending_action(snapshot, state) or snapshot.pending_actions[0]
    return replace(
        state,
        action_open=True,
        selected_request_id=current.request_id,
        selected_decision=default_decision(current),
        action_pending_submit=False,
        confirm_kind=None,
        confirm_rule=None,
    )


def _move_pending(state: GraphTuiState, snapshot: GraphTuiSnapshot, delta: int) -> GraphTuiState:
    pending = snapshot.pending_actions
    if not pending:
        return replace(state, action_open=False, selected_request_id=None, action_pending_submit=False)
    ids = [item.request_id for item in pending]
    if state.selected_request_id in ids:
        index = ids.index(state.selected_request_id)
    else:
        index = 0
    index = min(max(index + delta, 0), len(pending) - 1)
    item = pending[index]
    return replace(
        state,
        action_open=True,
        selected_request_id=item.request_id,
        selected_decision=default_decision(item),
        confirm_kind=None,
        confirm_rule=None,
        action_pending_submit=False,
    )


def _request_submit(
    state: GraphTuiState,
    snapshot: GraphTuiSnapshot,
    *,
    decision: Optional[str] = None,
) -> GraphTuiState:
    action = selected_pending_action(snapshot, state)
    if action is None:
        return state
    chosen = decision or state.selected_decision
    if chosen not in available_decisions(action):
        chosen = default_decision(action)
    if decision_requires_confirmation(chosen):
        rule = approval_rule_id(action.runtime, action.action, action.resource, action.effect)
        if state.confirm_kind == chosen and state.confirm_rule:
            return replace(
                state,
                action_open=True,
                selected_decision=chosen,
                confirm_kind=chosen,
                confirm_rule=rule,
                action_pending_submit=True,
            )
        return replace(
            state,
            action_open=True,
            selected_decision=chosen,
            confirm_kind=chosen,
            confirm_rule=rule,
            action_pending_submit=False,
        )
    return replace(
        state,
        action_open=True,
        selected_decision=chosen,
        confirm_kind=None,
        confirm_rule=None,
        action_pending_submit=True,
    )


def _reconcile_selection(state: GraphTuiState, snapshot: GraphTuiSnapshot) -> GraphTuiState:
    current = replace(state, page_size=_clamp_page_size(state.page_size))
    nodes = snapshot.nodes
    visible = visible_nodes(snapshot, current)
    all_ids = [node.node_id for node in nodes]
    visible_ids = [node.node_id for node in visible]

    if current.selected_node_id and current.selected_node_id in visible_ids:
        node = next(item for item in visible if item.node_id == current.selected_node_id)
        return _state_with_node(current, node, visible_ids.index(current.selected_node_id))

    if visible:
        index = min(max(current.selected_index, 0), len(visible) - 1)
        return _state_with_node(current, visible[index], index)

    if current.selected_node_id and current.selected_node_id in all_ids:
        node = next(item for item in nodes if item.node_id == current.selected_node_id)
        attempt = _resolve_selected_attempt(node, current.selected_attempt_id)
        return replace(
            current,
            selected_attempt_id=attempt.attempt_id if attempt else node.last_attempt_id,
            selected_index=0,
        )
    return replace(current, selected_node_id=None, selected_attempt_id=None, selected_index=0)


def _clamp_page_size(value: object) -> int:
    parsed = _clamp_dim(value, DEFAULT_PAGE_SIZE)
    return max(1, parsed)


def _node_matches_filter(node: GraphTuiNode, query: str) -> bool:
    fields = (node.node_id, node.type, node.status, node.runtime or "")
    return any(query in field.casefold() for field in fields)


def _nav_action(key: object) -> Optional[str]:
    if isinstance(key, int):
        mapped = _CURSES_KEY_CODES.get(key)
        if mapped:
            return mapped
        key = str(key)
    if not isinstance(key, str) or not key:
        return None
    action = _NAV_ACTIONS.get(key)
    if action:
        return action
    if len(key) == 1 and key.isalpha():
        return _NAV_ACTIONS.get(key.lower())
    return _NAV_ACTIONS.get(key.lower()) if key.lower() in _NAV_ACTIONS else None


def _is_filter_char(key: object) -> bool:
    return isinstance(key, str) and len(key) == 1 and key.isprintable() and key not in {"\n", "\r", "\x1b"}


def _apply_filter_key(state: GraphTuiState, key: object, snapshot: GraphTuiSnapshot) -> GraphTuiState:
    action = _nav_action(key)
    if action == "enter":
        return _reconcile_selection(replace(state, filter_editing=False, filter_backup=""), snapshot)
    if action == "escape":
        return _reconcile_selection(
            replace(state, filter_editing=False, filter_query=state.filter_backup, filter_backup=""),
            snapshot,
        )
    if action == "backspace":
        return _reconcile_selection(replace(state, filter_query=state.filter_query[:-1]), snapshot)
    if _is_filter_char(key):
        return _reconcile_selection(replace(state, filter_query=state.filter_query + str(key)), snapshot)
    return state


def _move_selection(state: GraphTuiState, snapshot: GraphTuiSnapshot, delta: int) -> GraphTuiState:
    visible = visible_nodes(snapshot, state)
    if not visible:
        return state
    visible_ids = [node.node_id for node in visible]
    if state.selected_node_id in visible_ids:
        index = visible_ids.index(state.selected_node_id)
    else:
        index = min(max(state.selected_index, 0), len(visible) - 1)
    index = min(max(index + delta, 0), len(visible) - 1)
    node = visible[index]
    attempt_hint = state.selected_attempt_id if node.node_id == state.selected_node_id else None
    return _state_with_node(replace(state, selected_attempt_id=attempt_hint), node, index)


def _state_with_node(state: GraphTuiState, node: GraphTuiNode, index: int) -> GraphTuiState:
    attempt = _resolve_selected_attempt(node, state.selected_attempt_id)
    attempt_id = attempt.attempt_id if attempt else node.last_attempt_id
    changed = node.node_id != state.selected_node_id or attempt_id != state.selected_attempt_id
    next_state = replace(
        state,
        selected_node_id=node.node_id,
        selected_index=max(0, index),
        selected_attempt_id=attempt_id,
    )
    return _reset_log_cursor(next_state) if changed else next_state


def _reset_log_cursor(state: GraphTuiState) -> GraphTuiState:
    return replace(state, log_offset=0, log_inode=None, log_seen=False)


def _clamp_tail_lines(value: object) -> int:
    parsed = _clamp_dim(value, DEFAULT_LOG_TAIL_LINES)
    return max(1, parsed)


def _pane_from_meta(
    meta: GraphTuiLogMetadata,
    *,
    follow: bool,
    omitted: bool,
    replaced: bool,
    reset: bool,
    offset: int,
    inode: Optional[int],
    lines: Tuple[str, ...] = (),
) -> GraphTuiLogPane:
    return GraphTuiLogPane(
        stream=meta.stream,
        node_id=meta.node_id,
        attempt_id=meta.attempt_id,
        relative_path=meta.relative_path,
        lines=lines,
        exists=meta.exists,
        size_bytes=meta.size_bytes,
        missing=meta.missing,
        uncontained=meta.uncontained,
        symlink=meta.symlink,
        truncated=meta.truncated,
        omitted=omitted,
        replaced=replaced,
        follow=follow,
        reset=reset,
        offset=offset,
        inode=inode,
        error=meta.error,
    )


def _read_log_tail_bytes(path: Path, size: int, *, max_bytes: int = DEFAULT_LOG_READ_BYTES) -> Tuple[bytes, bool]:
    if size <= 0:
        return b"", False
    with path.open("rb") as handle:
        if size <= max_bytes:
            return handle.read(), False
        handle.seek(-max_bytes, os.SEEK_END)
        raw = handle.read()
        newline = raw.find(b"\n")
        if newline != -1:
            raw = raw[newline + 1 :]
        return raw, True


def _decode_log_bytes(raw: bytes) -> Tuple[str, bool]:
    text = raw.decode("utf-8", errors="replace")
    replaced = _REPLACEMENT in text or "\x00" in text
    if "\x00" in text:
        text = text.replace("\x00", _REPLACEMENT)
    return text, replaced


def _sanitize_log_line(text: str) -> str:
    if not text:
        return ""
    return text.replace("\r", "").translate(_CONTROL_CHARS)


def _render_log_block(pane: GraphTuiLogPane) -> List[str]:
    flags: List[str] = []
    if pane.follow:
        flags.append("follow=on")
    if pane.missing:
        flags.append("missing")
    if pane.uncontained:
        flags.append("uncontained")
    if pane.symlink:
        flags.append("symlink")
    if pane.truncated:
        flags.append("truncated")
    if pane.omitted:
        flags.append("omitted")
    if pane.replaced:
        flags.append("replaced")
    if pane.reset:
        flags.append("reset")
    header = f"log stream={pane.stream} path={pane.relative_path or '-'}"
    if flags:
        header = f"{header} {' '.join(flags)}"
    lines = [header]
    if pane.error:
        lines.append(pane.error)
        return lines
    lines.extend(pane.lines)
    return lines


def _sanitize_text(text: str) -> str:
    if not text:
        return ""
    return str(text).replace("\r", " ").replace("\n", " ").translate(_CONTROL_CHARS)


def _clamp_dim(value: object, default: int) -> int:
    if value is None:
        return default
    try:
        parsed = int(value)
    except (TypeError, ValueError):
        return default
    return max(0, parsed)


def _fit_line(text: str, width: int) -> str:
    return clip_text(text, width, pad=True)


def _dash(value: Optional[str]) -> str:
    return value if value else "-"


def _resolve_selected_node(
    nodes: Sequence[GraphTuiNode], node_id: Optional[str]
) -> Optional[GraphTuiNode]:
    selected = _select_node(nodes, node_id)
    if selected is None:
        selected = _select_node(nodes, None)
    return selected


def _resolve_selected_attempt(
    node: Optional[GraphTuiNode], attempt_id: Optional[str]
) -> Optional[GraphTuiAttempt]:
    if node is None:
        return None
    selected = _select_attempt(node, attempt_id)
    if selected is None:
        selected = _select_attempt(node, None)
    return selected


def _render_header(snapshot: GraphTuiSnapshot) -> str:
    run = snapshot.run
    return (
        f"ralph graph  run={run.run_id}  ns={run.namespace}  "
        f"status={run.status}  health={snapshot.health}"
    )


def _render_summary(snapshot: GraphTuiSnapshot) -> List[str]:
    run = snapshot.run
    counts = _status_counts(snapshot.nodes)
    return [
        (
            f"plan={_dash(run.plan_path)}  started={_dash(run.started_at)}  "
            f"parallel={_dash(None if run.max_parallel is None else str(run.max_parallel))}  "
            f"usage={snapshot.usage_reliability}  pending={len(snapshot.pending_actions)}"
        ),
        (
            f"nodes={len(snapshot.nodes)}  running={counts['running']}  "
            f"succeeded={counts['succeeded']}  failed={counts['failed']}  "
            f"pending={counts['pending']}"
        ),
    ]


def _render_detail(
    snapshot: GraphTuiSnapshot,
    node: Optional[GraphTuiNode],
    attempt: Optional[GraphTuiAttempt],
) -> List[str]:
    if node is None:
        return ["node=-  type=-  runtime=-  status=-  attempts=0"]
    duration = format_duration(attempt.started_at, attempt.finished_at) if attempt else "-"
    outcome = attempt.outcome if attempt else None
    usage = attempt.usage_reliability if attempt else USAGE_RELIABILITY_UNAVAILABLE
    attempt_id = attempt.attempt_id if attempt else node.last_attempt_id
    return [
        (
            f"node={node.node_id}  type={node.type}  runtime={_dash(node.runtime)}  "
            f"status={node.status}  attempts={node.attempt_count}"
        ),
        (
            f"attempt={_dash(attempt_id)}  outcome={_dash(outcome)}  "
            f"duration={duration}  usage={usage}"
        ),
        (
            f"mode={_dash(node.workspace_mode)}  scopes={format_scopes(node.write_scopes)}  "
            f"log={_log_label(snapshot, node, attempt)}"
        ),
    ]


def _render_footer(snapshot: GraphTuiSnapshot, state: Optional[GraphTuiState] = None) -> str:
    warning_count = len(snapshot.warnings)
    stream = normalize_log_stream(state.selected_stream if state is not None else snapshot.selected_log.stream)
    follow = "on" if state is not None and state.log_follow else "off"
    return (
        f"q quit  r refresh  pending={len(snapshot.pending_actions)}  "
        f"warnings={warning_count}  j/k select  / filter  s stream={stream}  "
        f"f follow={follow}"
    )


def _render_pending_block(
    snapshot: GraphTuiSnapshot, state: Optional[GraphTuiState]
) -> List[str]:
    lines: List[str] = []
    confirm_kind = state.confirm_kind if state is not None else None
    if confirm_kind == CONFIRM_RECOVER:
        lines.append(f"confirm recover  run={snapshot.run.run_id}  health={snapshot.health}")
        lines.append("y confirm recovery  n cancel")
        if state is not None and state.last_action_error:
            lines.append(f"error={state.last_action_error}")
        return lines
    if snapshot.health == "stale":
        lines.append("c recover  health=stale")
    if not snapshot.pending_actions:
        if state is not None and state.last_action_error:
            lines.append(f"error={state.last_action_error}")
        return lines
    selected_id = state.selected_request_id if state is not None else None
    action_open = bool(state is not None and state.action_open)
    lines.append("pending requests")
    for item in snapshot.pending_actions:
        marker = ">" if action_open and item.request_id == selected_id else " "
        lines.append(
            f"{marker} {item.request_id}  node={item.node_id}  runtime={item.runtime}  "
            f"action={item.action}  resource={item.resource}  effect={item.effect}"
        )
    action = selected_pending_action(snapshot, state) if state is not None else snapshot.pending_actions[0]
    if action is not None:
        choices = available_decisions(action)
        lines.append(f"  choices={','.join(choices) if choices else '-'}")
        if action_open:
            parts: List[str] = []
            selected_decision = state.selected_decision if state is not None else DEFAULT_ACTION_DECISION
            for choice in ACTION_DECISIONS:
                if choice not in choices:
                    continue
                mark = "*" if choice == selected_decision else " "
                parts.append(f"[{mark}]{choice}")
            if parts:
                lines.append("  " + "  ".join(parts))
            if confirm_kind == CONFIRM_ALLOW_ALWAYS:
                rule = state.confirm_rule if state is not None else None
                lines.append("y confirm  n cancel  allow-always")
                lines.append(f"rule={rule or '-'}")
            else:
                lines.append(
                    f"selected={selected_decision}  default={DEFAULT_ACTION_DECISION}  "
                    "enter submit  1/2/3/4 choose"
                )
        else:
            lines.append("a action  d deny")
    if state is not None and state.last_action_error:
        lines.append(f"error={state.last_action_error}")
    return lines


def _table_header() -> str:
    return (
        f"  {_cell('NODE', 16)} {_cell('TYPE', 8)} {_cell('RUNTIME', 9)} "
        f"{_cell('STATE', 11)} {_cell('ATTEMPTS', 8)} {_cell('DURATION', 8)} MODE"
    )


def _table_rows(
    nodes: Sequence[GraphTuiNode],
    selected: Optional[GraphTuiNode],
    row_budget: int,
) -> List[str]:
    if row_budget <= 0 or not nodes:
        return []
    selected_id = selected.node_id if selected is not None else None
    selected_index = 0
    if selected_id:
        for index, node in enumerate(nodes):
            if node.node_id == selected_id:
                selected_index = index
                break
    visible = _visible_window(list(nodes), selected_index, row_budget)
    rows: List[str] = []
    for node in visible:
        marker = ">" if selected_id is not None and node.node_id == selected_id else " "
        last = node.attempts[-1] if node.attempts else None
        duration = format_duration(last.started_at, last.finished_at) if last else "-"
        rows.append(
            f"{marker} {_cell(node.node_id, 16)} {_cell(node.type, 8)} "
            f"{_cell(_dash(node.runtime), 9)} {_cell(node.status, 11)} "
            f"{_cell(str(node.attempt_count), 8)} {_cell(duration, 8)} "
            f"{_dash(node.workspace_mode)}"
        )
    return rows


def _visible_window(items: Sequence[GraphTuiNode], selected_index: int, max_rows: int) -> List[GraphTuiNode]:
    if max_rows <= 0:
        return []
    if len(items) <= max_rows:
        return list(items)
    start = max(0, selected_index - max_rows // 2)
    start = min(start, len(items) - max_rows)
    return list(items[start : start + max_rows])


def _cell(text: str, width: int) -> str:
    return clip_text(_dash(text if text else None), width, pad=True)


def _status_counts(nodes: Sequence[GraphTuiNode]) -> Dict[str, int]:
    counts = {"running": 0, "succeeded": 0, "failed": 0, "pending": 0}
    for node in nodes:
        if node.status in counts:
            counts[node.status] += 1
    return counts


def _log_label(
    snapshot: GraphTuiSnapshot,
    node: GraphTuiNode,
    attempt: Optional[GraphTuiAttempt],
) -> str:
    stream = snapshot.selected_log.stream if snapshot.selected_log.stream in LOG_STREAMS else "runner"
    rel = attempt.log_paths.get(stream) if attempt else None
    meta = snapshot.selected_log
    matches = meta.node_id == node.node_id and (
        attempt is None or meta.attempt_id == attempt.attempt_id
    )
    if matches:
        if meta.uncontained:
            return "uncontained"
        if meta.symlink:
            return "symlink"
        if meta.missing or not meta.exists:
            return rel or "missing"
        if rel and meta.truncated:
            return f"{rel} truncated"
        if rel:
            return rel
        return "missing"
    return rel or "-"


def _load_nodes(
    run_dir: Path,
    graph_nodes: Sequence[Mapping[str, object]],
    warnings: List[str],
) -> List[GraphTuiNode]:
    nodes_dir = run_dir / "nodes"
    specs = list(graph_nodes)
    if not specs:
        specs = _ledger_node_specs(nodes_dir)
    loaded: List[GraphTuiNode] = []
    for spec in specs:
        node_id = _optional_str(spec.get("id")) or ""
        if not node_id:
            continue
        node_file = nodes_dir / f"{sanitize_id(node_id)}.json"
        raw = _read_json_atomic(node_file) if node_file.exists() else None
        if node_file.exists() and raw is None:
            warnings.append(f"node ledger was unreadable during atomic replacement: {node_id}")
        records: Sequence[Mapping[str, object]] = []
        status = "pending"
        last_attempt_id = None
        workspace_mode = _optional_str(spec.get("workspaceMode"))
        frozen_base = None
        write_scopes: Tuple[str, ...] = ()
        if isinstance(raw, Mapping):
            status = _optional_str(raw.get("status")) or "pending"
            last_attempt_id = _optional_str(raw.get("lastAttemptId"))
            workspace_mode = _optional_str(raw.get("workspaceMode")) or workspace_mode
            frozen_base = _optional_str(raw.get("frozenBase"))
            scopes = raw.get("writeScopes")
            if isinstance(scopes, list):
                write_scopes = tuple(str(item) for item in scopes if item is not None)
            attempts_raw = raw.get("attempts")
            if isinstance(attempts_raw, list):
                records = [item for item in attempts_raw if isinstance(item, Mapping)]
            if not workspace_mode and records:
                workspace_mode = _optional_str(records[-1].get("workspaceMode"))
            if not frozen_base and records:
                frozen_base = _optional_str(records[-1].get("frozenBase"))
            if not write_scopes and records:
                last_scopes = records[-1].get("writeScopes")
                if isinstance(last_scopes, list):
                    write_scopes = tuple(str(item) for item in last_scopes if item is not None)
        attempts = tuple(unique_attempts(records, node_id))
        if last_attempt_id is None and attempts:
            last_attempt_id = attempts[-1].attempt_id
        loaded.append(
            GraphTuiNode(
                node_id=node_id,
                type=_optional_str(spec.get("type")) or "stage",
                runtime=_optional_str(spec.get("runtime")),
                status=status,
                attempt_count=len(attempts),
                attempts=attempts,
                last_attempt_id=last_attempt_id,
                workspace_mode=workspace_mode,
                frozen_base=frozen_base,
                write_scopes=write_scopes,
            )
        )
    return loaded


def _ledger_node_specs(nodes_dir: Path) -> List[Dict[str, object]]:
    if not nodes_dir.is_dir() or nodes_dir.is_symlink():
        return []
    specs: List[Dict[str, object]] = []
    for path in sorted(nodes_dir.glob("*.json")):
        if path.name.startswith(".") or _is_atomic_temp(path.name):
            continue
        raw = _read_json_atomic(path)
        node_id = _optional_str(raw.get("nodeId")) if raw else path.stem
        specs.append({"id": node_id or path.stem, "type": "stage", "runtime": None})
    return specs


def _graph_node_specs(graph: Optional[Mapping[str, object]]) -> List[Dict[str, object]]:
    if not isinstance(graph, Mapping):
        return []
    nodes = graph.get("nodes")
    if not isinstance(nodes, list):
        return []
    specs: List[Dict[str, object]] = []
    for item in nodes:
        if not isinstance(item, Mapping):
            continue
        node_id = _optional_str(item.get("id"))
        if not node_id:
            continue
        stage = item.get("stage") if isinstance(item.get("stage"), Mapping) else {}
        specs.append(
            {
                "id": node_id,
                "type": _optional_str(item.get("type")) or "stage",
                "runtime": _optional_str(stage.get("runtime")) if isinstance(stage, Mapping) else None,
                "workspaceMode": _optional_str(stage.get("workspaceMode")) if isinstance(stage, Mapping) else None,
            }
        )
    return specs


def _load_pending_actions(run_dir: Path, warnings: List[str]) -> List[GraphTuiPendingAction]:
    req_dir = run_dir / "operator" / "requests"
    dec_dir = run_dir / "operator" / "decisions"
    if not req_dir.is_dir() or req_dir.is_symlink():
        return []
    pending: List[GraphTuiPendingAction] = []
    for path in sorted(req_dir.glob("*.json")):
        if path.is_symlink() or _is_atomic_temp(path.name):
            continue
        request_id = path.stem
        if not REQUEST_ID_RE.match(request_id):
            warnings.append(f"skipping unsafe operator request filename: {request_id}")
            continue
        decision = dec_dir / f"{request_id}.json"
        if decision.is_file() and not decision.is_symlink():
            continue
        raw = _read_json_atomic(path)
        if raw is None:
            warnings.append(f"skipping unreadable operator request: {request_id}")
            continue
        choices_raw = raw.get("choices")
        choices = (
            tuple(str(item) for item in choices_raw if item is not None)
            if isinstance(choices_raw, list)
            else ()
        )
        pending.append(
            GraphTuiPendingAction(
                request_id=_optional_str(raw.get("requestId")) or request_id,
                node_id=_optional_str(raw.get("nodeId")) or "",
                runtime=_optional_str(raw.get("runtime")) or "",
                action=_optional_str(raw.get("action")) or "",
                resource=_optional_str(raw.get("resource")) or "",
                effect=_optional_str(raw.get("effect")) or "",
                choices=choices,
                classification=_optional_str(raw.get("classification")) or "",
            )
        )
    pending.sort(key=lambda item: item.request_id)
    return pending


def _normalize_run(raw: Mapping[str, object], run_dir: Path) -> GraphTuiRun:
    schema_version = _optional_int(raw.get("schemaVersion")) or 1
    namespace = _optional_str(raw.get("namespace")) or run_dir.parent.name
    return GraphTuiRun(
        run_id=_optional_str(raw.get("runId")) or run_dir.name,
        namespace=namespace,
        status=_optional_str(raw.get("status")) or "unknown",
        started_at=_optional_str(raw.get("startedAt")),
        plan_path=_optional_str(raw.get("planPath")),
        schema_version=schema_version,
        supervisor_pid=_optional_int(raw.get("supervisorPid")),
        owner_hostname=_optional_str(raw.get("ownerHostname")),
        owner_process_start_id=_optional_str(raw.get("ownerProcessStartId")),
        heartbeat_at=_optional_str(raw.get("heartbeatAt")),
        max_parallel=_optional_int(raw.get("maxParallel")),
        raw=dict(raw),
    )


def _attempt_from_record(node_id: str, attempt_id: str, raw: Mapping[str, object]) -> GraphTuiAttempt:
    usage = raw.get("usageSnapshot")
    if usage is None:
        usage = raw.get("usage")
    usage_map = dict(usage) if isinstance(usage, Mapping) else None
    usage_reliable = raw.get("usageReliable")
    reliable_bool = usage_reliable if isinstance(usage_reliable, bool) else None
    reliability = _attempt_usage_reliability(reliable_bool, usage_map)
    log_paths_raw = raw.get("logPaths")
    log_paths: Dict[str, str] = {}
    if isinstance(log_paths_raw, Mapping):
        for stream in LOG_STREAMS:
            value = log_paths_raw.get(stream)
            if isinstance(value, str) and value:
                log_paths[stream] = value
    return GraphTuiAttempt(
        attempt_id=attempt_id,
        node_id=node_id,
        outcome=_optional_str(raw.get("outcome")),
        started_at=_optional_str(raw.get("startedAt")),
        finished_at=_optional_str(raw.get("finishedAt")),
        runtime=_optional_str(raw.get("runtime")),
        usage_snapshot=usage_map,
        usage_reliable=reliable_bool,
        usage_reliability=reliability,
        log_paths=log_paths,
    )


def _attempt_usage_reliability(
    usage_reliable: Optional[bool], usage_snapshot: Optional[Mapping[str, object]]
) -> str:
    if usage_reliable is True and usage_snapshot is not None:
        return USAGE_RELIABILITY_AUTHORITATIVE
    return USAGE_RELIABILITY_UNAVAILABLE


def _aggregate_usage_reliability(attempts: Sequence[GraphTuiAttempt]) -> str:
    if not attempts:
        return USAGE_RELIABILITY_UNAVAILABLE
    values = {attempt.usage_reliability for attempt in attempts}
    if values == {USAGE_RELIABILITY_AUTHORITATIVE}:
        return USAGE_RELIABILITY_AUTHORITATIVE
    if values == {USAGE_RELIABILITY_UNAVAILABLE}:
        return USAGE_RELIABILITY_UNAVAILABLE
    return USAGE_RELIABILITY_MIXED


def _merge_attempt(base: Mapping[str, object], incoming: Mapping[str, object]) -> Dict[str, object]:
    merged = dict(base)
    for key, value in incoming.items():
        if value is None and key in merged and merged[key] is not None:
            continue
        merged[key] = value
    return merged


def _select_node(nodes: Sequence[GraphTuiNode], node_id: Optional[str]) -> Optional[GraphTuiNode]:
    if not nodes:
        return None
    if node_id:
        for node in nodes:
            if node.node_id == node_id:
                return node
        return None
    for node in nodes:
        if node.last_attempt_id:
            return node
    return nodes[0]


def _select_attempt(node: GraphTuiNode, attempt_id: Optional[str]) -> Optional[GraphTuiAttempt]:
    if not node.attempts:
        return None
    wanted = attempt_id or node.last_attempt_id
    if wanted:
        for attempt in node.attempts:
            if attempt.attempt_id == wanted:
                return attempt
        return None
    return node.attempts[-1]


def _is_contained_rel(rel: str) -> bool:
    if not rel or rel.startswith("/") or "\\" in rel:
        return False
    parts = PurePosixPath(rel).parts
    if not parts or any(part in {"", ".", ".."} for part in parts):
        return False
    return True


def _resolve_contained(run_dir: Path, rel: str) -> Optional[Path]:
    if not _is_contained_rel(rel):
        return None
    try:
        run_real = run_dir.resolve()
    except OSError:
        return None
    current = run_real
    for component in PurePosixPath(rel).parts:
        next_path = current / component
        if next_path.is_symlink():
            if next_path.is_dir():
                try:
                    resolved = next_path.resolve()
                except OSError:
                    return None
                if resolved != run_real and run_real not in resolved.parents:
                    return None
                current = resolved
                continue
            return next_path
        current = next_path
    try:
        if current.exists():
            resolved = current.resolve()
            if resolved != run_real and run_real not in resolved.parents:
                return None
    except OSError:
        return None
    return current


def _read_json_atomic(path: Path) -> Optional[Dict[str, object]]:
    if _is_atomic_temp(path.name):
        return None
    last_error: Optional[Exception] = None
    for _ in range(ATOMIC_READ_ATTEMPTS):
        try:
            if not path.exists() or path.is_symlink() or not path.is_file():
                return None
            raw = path.read_bytes()
            if not raw.strip():
                last_error = ValueError("empty")
                time.sleep(ATOMIC_READ_RETRY_SECONDS)
                continue
            payload = json.loads(raw.decode("utf-8"))
            if isinstance(payload, dict):
                return payload
            last_error = ValueError("not an object")
        except FileNotFoundError:
            last_error = None
            time.sleep(ATOMIC_READ_RETRY_SECONDS)
            continue
        except (OSError, UnicodeDecodeError, json.JSONDecodeError) as exc:
            last_error = exc
            time.sleep(ATOMIC_READ_RETRY_SECONDS)
            continue
        time.sleep(ATOMIC_READ_RETRY_SECONDS)
    if last_error is not None:
        return None
    return None


def _read_bytes_atomic(path: Path) -> Optional[bytes]:
    last_error: Optional[Exception] = None
    for _ in range(ATOMIC_READ_ATTEMPTS):
        try:
            if not path.exists() or path.is_symlink() or not path.is_file():
                return None
            return path.read_bytes()
        except FileNotFoundError as exc:
            last_error = exc
            time.sleep(ATOMIC_READ_RETRY_SECONDS)
            continue
        except OSError as exc:
            last_error = exc
            time.sleep(ATOMIC_READ_RETRY_SECONDS)
            continue
    if last_error is not None:
        raise last_error
    return None


def _is_atomic_temp(name: str) -> bool:
    return any(name.startswith(prefix) for prefix in ATOMIC_TEMP_PREFIXES)


def _optional_str(value: object) -> Optional[str]:
    if value is None or value == "":
        return None
    if isinstance(value, str):
        return value
    return str(value)


def _optional_int(value: object) -> Optional[int]:
    if isinstance(value, bool) or value is None or value == "":
        return None
    if isinstance(value, int):
        return value
    try:
        return int(str(value))
    except (TypeError, ValueError):
        return None


def _iso_to_epoch(value: str) -> Optional[int]:
    if not ISO_SECONDS_RE.match(value):
        return None
    try:
        parsed = datetime.strptime(value, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc)
    except ValueError:
        return None
    return int(parsed.timestamp())


MODE_AUTO = "auto"
MODE_TUI = "tui"
MODE_NO_TUI = "no-tui"
LAUNCH_CURSES = "curses"
LAUNCH_STATUS = "status"
REASON_CURSES = "curses"
REASON_TTY = "tty"
REASON_TERM = "term"
REASON_CI = "ci"
REASON_PLAIN = "plain"
REASON_SCREEN_READER = "screen-reader"
TERMINAL_RUN_STATUSES = frozenset({"succeeded", "failed", "cancelled"})
DEFAULT_REFRESH_INTERVAL = 1.0
STREAMING_FRAME_HEIGHT = 14
STREAM_SEPARATOR = "---"


@dataclass(frozen=True)
class TuiCapabilities:
    python_ok: bool = True
    curses_ok: bool = False
    tty_ok: bool = False
    reason: Optional[str] = None

    @property
    def available(self) -> bool:
        return bool(self.python_ok and self.curses_ok and self.tty_ok)


@dataclass(frozen=True)
class TuiLaunchPlan:
    backend: str
    fallback: bool = False
    reason: Optional[str] = None
    message: Optional[str] = None


@dataclass(frozen=True)
class TuiSessionResult:
    exit_code: int
    frames: int = 0
    quit_requested: bool = False
    backend: str = LAUNCH_STATUS
    fallback: bool = False
    reason: Optional[str] = None


@dataclass(frozen=True)
class TuiArgv:
    run_dir: Optional[str] = None
    workspace: Optional[str] = None
    graph_run: Optional[str] = None
    mode: str = MODE_AUTO
    refresh_interval: float = DEFAULT_REFRESH_INTERVAL
    probe: bool = False
    help: bool = False


def is_terminal_run_status(status: Optional[str]) -> bool:
    return (status or "") in TERMINAL_RUN_STATUSES


def probe_tui_capabilities(
    *,
    stdin_isatty: Optional[bool] = None,
    stdout_isatty: Optional[bool] = None,
    term: Optional[str] = None,
    columns: Optional[int] = None,
    environ: Optional[Mapping[str, str]] = None,
    curses_importer: Optional[Callable[[], Any]] = None,
    python_ok: bool = True,
) -> TuiCapabilities:
    """Return whether an interactive curses session can be started.

    Checks are injectable so tests do not need a real TTY. `columns` is
    accepted for callers that already measured the screen; narrow widths
    stay renderable and do not fail the probe.
    """
    del columns
    if not python_ok:
        return TuiCapabilities(python_ok=False, reason="python")
    env = dict(os.environ if environ is None else environ)
    if _env_flag(env, "RALPH_GRAPH_PLAIN") or _env_flag(env, "RALPH_GRAPH_NO_TUI"):
        return TuiCapabilities(python_ok=True, reason=REASON_PLAIN)
    if _env_flag(env, "RALPH_GRAPH_SCREEN_READER") or _env_flag(env, "ACCESSIBILITY_SCREEN_READER"):
        return TuiCapabilities(python_ok=True, reason=REASON_SCREEN_READER)
    if _env_flag(env, "CI"):
        return TuiCapabilities(python_ok=True, reason=REASON_CI)
    term_value = term if term is not None else env.get("TERM", "")
    if not term_value or term_value == "dumb":
        return TuiCapabilities(python_ok=True, reason=REASON_TERM)
    in_tty = sys.stdin.isatty() if stdin_isatty is None else bool(stdin_isatty)
    out_tty = sys.stdout.isatty() if stdout_isatty is None else bool(stdout_isatty)
    if not in_tty or not out_tty:
        return TuiCapabilities(python_ok=True, tty_ok=False, reason=REASON_TTY)
    importer = curses_importer or _load_curses
    try:
        importer()
    except Exception:
        return TuiCapabilities(python_ok=True, tty_ok=True, curses_ok=False, reason=REASON_CURSES)
    return TuiCapabilities(python_ok=True, curses_ok=True, tty_ok=True)


def decide_tui_launch(mode: str, caps: TuiCapabilities) -> TuiLaunchPlan:
    """Choose curses or concise streaming status. Never raises."""
    normalized = (mode or MODE_AUTO).strip().lower()
    if normalized not in {MODE_AUTO, MODE_TUI, MODE_NO_TUI}:
        normalized = MODE_AUTO
    if normalized == MODE_NO_TUI:
        return TuiLaunchPlan(backend=LAUNCH_STATUS, fallback=False, reason=REASON_PLAIN)
    if caps.available:
        return TuiLaunchPlan(backend=LAUNCH_CURSES)
    reason = caps.reason or REASON_TTY
    return TuiLaunchPlan(
        backend=LAUNCH_STATUS,
        fallback=True,
        reason=reason,
        message=f"graph tui: falling back to concise streaming status ({reason} unavailable)",
    )


def render_streaming_status(
    snapshot: GraphTuiSnapshot,
    *,
    width: int = DEFAULT_FRAME_WIDTH,
    state: Optional[GraphTuiState] = None,
) -> str:
    """Concise colorless status frame used when curses cannot run."""
    return render_frame(
        snapshot,
        width=width,
        height=STREAMING_FRAME_HEIGHT,
        state=state,
    )


class TerminalRestorer:
    """Save and restore terminal attributes. Restore is idempotent."""

    def __init__(
        self,
        fd: Optional[int] = None,
        *,
        termios_mod: Any = None,
        signal_mod: Any = None,
        curses_mod: Any = None,
        raise_on_sigint: bool = True,
    ) -> None:
        self.fd = 0 if fd is None else fd
        self._termios = termios_mod
        self._signal = signal_mod
        self._curses = curses_mod
        self._raise_on_sigint = raise_on_sigint
        self._saved: Any = None
        self._prev_handlers: Dict[int, Any] = {}
        self._termios_restored = False
        self._endwin_done = False
        self._installed = False
        self.restore_count = 0

    def install(self) -> None:
        if self._installed:
            return
        termios_mod = self._termios if self._termios is not None else _load_termios()
        signal_mod = self._signal if self._signal is not None else _load_signal()
        self._termios = termios_mod
        self._signal = signal_mod
        if termios_mod is not None:
            try:
                self._saved = termios_mod.tcgetattr(self.fd)
            except Exception:
                self._saved = None
        self._termios_restored = False
        self._endwin_done = False
        if signal_mod is not None:
            for signum in _lifecycle_signals(signal_mod):
                try:
                    self._prev_handlers[signum] = signal_mod.signal(signum, self._handle_signal)
                except Exception:
                    continue
        self._installed = True

    def restore(self) -> None:
        self.restore_count += 1
        if self._curses is not None and not self._endwin_done:
            self._endwin_done = True
            try:
                self._curses.endwin()
            except Exception:
                pass
        if self._termios_restored:
            return
        self._termios_restored = True
        if self._saved is None or self._termios is None:
            return
        when = getattr(self._termios, "TCSANOW", 0)
        try:
            self._termios.tcsetattr(self.fd, when, self._saved)
        except Exception:
            pass

    def close(self) -> None:
        self.restore()
        self._uninstall_handlers()
        self._installed = False

    def __enter__(self) -> "TerminalRestorer":
        self.install()
        return self

    def __exit__(self, exc_type: object, exc: object, tb: object) -> None:
        self.close()

    def _handle_signal(self, signum: int, frame: object) -> None:
        self.restore()
        self._uninstall_handlers()
        signal_mod = self._signal
        sigint = getattr(signal_mod, "SIGINT", None) if signal_mod is not None else None
        if self._raise_on_sigint and sigint is not None and signum == sigint:
            raise KeyboardInterrupt
        raise SystemExit(_signal_exit_code(signum))

    def _uninstall_handlers(self) -> None:
        signal_mod = self._signal
        if signal_mod is None:
            self._prev_handlers.clear()
            return
        for signum, previous in list(self._prev_handlers.items()):
            try:
                signal_mod.signal(signum, previous)
            except Exception:
                pass
        self._prev_handlers.clear()


def run_tui_session(
    run_dir: str | os.PathLike[str],
    *,
    keys: Optional[Sequence[object]] = None,
    get_key: Optional[Callable[[], object]] = None,
    painter: Optional[Callable[[str], None]] = None,
    load: Optional[Callable[..., GraphTuiSnapshot]] = None,
    sleep: Callable[[float], None] = lambda _seconds: None,
    refresh_interval: float = DEFAULT_REFRESH_INTERVAL,
    max_frames: Optional[int] = None,
    graph_run: Optional[str | os.PathLike[str]] = None,
    workspace: Optional[str | os.PathLike[str]] = None,
    runner: Optional[CommandRunner] = None,
    width: int = DEFAULT_FRAME_WIDTH,
    height: int = DEFAULT_FRAME_HEIGHT,
    now_epoch: Optional[int] = None,
    process_lookup: Optional[ProcessLookup] = None,
    exit_on_terminal: bool = True,
) -> TuiSessionResult:
    """Drive one interactive session with injected I/O. No curses import."""
    loader = load or load_snapshot
    key_iter = iter(keys or ())
    frames = 0
    snapshot = loader(
        run_dir,
        now_epoch=now_epoch,
        process_lookup=process_lookup,
    )
    state = initial_state(snapshot)
    while True:
        if state.refresh_requested:
            snapshot = loader(
                run_dir,
                selected_node_id=state.selected_node_id,
                selected_attempt_id=state.selected_attempt_id,
                selected_stream=state.selected_stream,
                now_epoch=now_epoch,
                process_lookup=process_lookup,
            )
            state = apply_snapshot(replace(state, refresh_requested=False), snapshot)
        pane, state = read_log_pane(Path(run_dir), snapshot, state)
        frame = render_frame(
            snapshot,
            width=width,
            height=height,
            state=state,
            log_pane=pane,
        )
        if painter is not None:
            painter(frame)
        frames += 1
        if state.quit_requested:
            return TuiSessionResult(
                exit_code=0,
                frames=frames,
                quit_requested=True,
                backend=LAUNCH_CURSES,
            )
        if exit_on_terminal and is_terminal_run_status(snapshot.run.status):
            return TuiSessionResult(exit_code=0, frames=frames, backend=LAUNCH_CURSES)
        if max_frames is not None and frames >= max_frames:
            return TuiSessionResult(exit_code=0, frames=frames, backend=LAUNCH_CURSES)
        key: object
        if get_key is not None:
            key = get_key()
        else:
            try:
                key = next(key_iter)
            except StopIteration:
                key = -1
        if key is None or key == -1:
            sleep(refresh_interval)
            state = replace(state, refresh_requested=True)
            continue
        state = apply_action_key(
            state,
            key,
            snapshot,
            runner=runner,
            graph_run=graph_run,
            workspace=workspace,
        )


def run_streaming_status(
    run_dir: str | os.PathLike[str],
    *,
    output: Optional[Callable[[str], None]] = None,
    load: Optional[Callable[..., GraphTuiSnapshot]] = None,
    sleep: Callable[[float], None] = lambda _seconds: None,
    refresh_interval: float = DEFAULT_REFRESH_INTERVAL,
    max_frames: Optional[int] = None,
    width: int = DEFAULT_FRAME_WIDTH,
    now_epoch: Optional[int] = None,
    process_lookup: Optional[ProcessLookup] = None,
    exit_on_terminal: bool = True,
    fallback: bool = False,
    reason: Optional[str] = None,
) -> TuiSessionResult:
    """Print concise status frames until the run is terminal or bounded."""
    loader = load or load_snapshot
    writer = output or (lambda text: print(text, flush=True))
    frames = 0
    while True:
        snapshot = loader(run_dir, now_epoch=now_epoch, process_lookup=process_lookup)
        state = initial_state(snapshot)
        writer(render_streaming_status(snapshot, width=width, state=state))
        frames += 1
        if exit_on_terminal and is_terminal_run_status(snapshot.run.status):
            return TuiSessionResult(
                exit_code=0,
                frames=frames,
                backend=LAUNCH_STATUS,
                fallback=fallback,
                reason=reason,
            )
        if max_frames is not None and frames >= max_frames:
            return TuiSessionResult(
                exit_code=0,
                frames=frames,
                backend=LAUNCH_STATUS,
                fallback=fallback,
                reason=reason,
            )
        writer(STREAM_SEPARATOR)
        sleep(refresh_interval)


def run_curses_session(
    run_dir: str | os.PathLike[str],
    *,
    curses_mod: Any = None,
    restorer: Optional[TerminalRestorer] = None,
    refresh_interval: float = DEFAULT_REFRESH_INTERVAL,
    graph_run: Optional[str | os.PathLike[str]] = None,
    workspace: Optional[str | os.PathLike[str]] = None,
    runner: Optional[CommandRunner] = None,
    load: Optional[Callable[..., GraphTuiSnapshot]] = None,
    now_epoch: Optional[int] = None,
    process_lookup: Optional[ProcessLookup] = None,
    keys: Optional[Sequence[object]] = None,
    max_frames: Optional[int] = None,
) -> TuiSessionResult:
    """Paint frames through curses.wrapper. Always restores the terminal."""
    curses = curses_mod if curses_mod is not None else _load_curses()
    guard = restorer or TerminalRestorer(curses_mod=curses)
    if restorer is None:
        guard._curses = curses
    key_iter = iter(keys or ())

    def _wrapped(stdscr: Any) -> TuiSessionResult:
        try:
            stdscr.timeout(max(int(refresh_interval * 1000), 0))
        except Exception:
            pass

        def get_key() -> object:
            try:
                return next(key_iter)
            except StopIteration:
                try:
                    return stdscr.getch()
                except Exception:
                    return -1

        def painter(frame: str) -> None:
            _paint_curses_frame(stdscr, frame, curses)

        return run_tui_session(
            run_dir,
            get_key=get_key,
            painter=painter,
            load=load,
            refresh_interval=refresh_interval,
            max_frames=max_frames,
            graph_run=graph_run,
            workspace=workspace,
            runner=runner,
            now_epoch=now_epoch,
            process_lookup=process_lookup,
            width=_curses_width(stdscr),
            height=_curses_height(stdscr),
        )

    guard.install()
    try:
        wrapper = getattr(curses, "wrapper", None)
        if callable(wrapper):
            return wrapper(_wrapped)
        stdscr = curses.initscr()
        try:
            return _wrapped(stdscr)
        finally:
            curses.endwin()
    except KeyboardInterrupt:
        return TuiSessionResult(exit_code=130, backend=LAUNCH_CURSES)
    finally:
        guard.close()


def parse_tui_argv(argv: Optional[Sequence[str]] = None) -> TuiArgv:
    args = list(sys.argv[1:] if argv is None else argv)
    parsed = TuiArgv()
    i = 0
    while i < len(args):
        token = args[i]
        if token in {"-h", "--help"}:
            return replace(parsed, help=True)
        if token == "--probe":
            parsed = replace(parsed, probe=True)
            i += 1
            continue
        if token == "--run-dir":
            parsed = replace(parsed, run_dir=_require_argv_value(args, i, token))
            i += 2
            continue
        if token.startswith("--run-dir="):
            parsed = replace(parsed, run_dir=token.split("=", 1)[1])
            i += 1
            continue
        if token == "--workspace":
            parsed = replace(parsed, workspace=_require_argv_value(args, i, token))
            i += 2
            continue
        if token.startswith("--workspace="):
            parsed = replace(parsed, workspace=token.split("=", 1)[1])
            i += 1
            continue
        if token == "--graph-run":
            parsed = replace(parsed, graph_run=_require_argv_value(args, i, token))
            i += 2
            continue
        if token.startswith("--graph-run="):
            parsed = replace(parsed, graph_run=token.split("=", 1)[1])
            i += 1
            continue
        if token == "--mode":
            parsed = replace(parsed, mode=_require_argv_value(args, i, token))
            i += 2
            continue
        if token.startswith("--mode="):
            parsed = replace(parsed, mode=token.split("=", 1)[1])
            i += 1
            continue
        if token == "--refresh-interval":
            parsed = replace(parsed, refresh_interval=_parse_interval(_require_argv_value(args, i, token)))
            i += 2
            continue
        if token.startswith("--refresh-interval="):
            parsed = replace(parsed, refresh_interval=_parse_interval(token.split("=", 1)[1]))
            i += 1
            continue
        raise GraphTuiError(f"unknown option '{token}'")
    return parsed


def main(
    argv: Optional[Sequence[str]] = None,
    *,
    capabilities: Optional[TuiCapabilities] = None,
    curses_mod: Any = None,
    restorer: Optional[TerminalRestorer] = None,
    output: Optional[Callable[[str], None]] = None,
    err: Optional[Callable[[str], None]] = None,
    load: Optional[Callable[..., GraphTuiSnapshot]] = None,
    sleep: Callable[[float], None] = time.sleep,
    max_frames: Optional[int] = None,
    keys: Optional[Sequence[object]] = None,
) -> int:
    """CLI entry for `graph-run.sh tui`. Falls back to streaming status."""
    err_write = err or (lambda text: print(text, file=sys.stderr))
    try:
        parsed = parse_tui_argv(argv)
    except GraphTuiError as exc:
        err_write(f"Error: {exc}")
        return 1
    if parsed.help:
        err_write(_tui_usage())
        return 0
    caps = capabilities if capabilities is not None else probe_tui_capabilities()
    if parsed.probe:
        payload = {
            "available": caps.available,
            "pythonOk": caps.python_ok,
            "cursesOk": caps.curses_ok,
            "ttyOk": caps.tty_ok,
            "reason": caps.reason,
        }
        (output or (lambda text: print(text)))(json.dumps(payload, separators=(",", ":")))
        return 0 if caps.available else 2
    if not parsed.run_dir:
        err_write("Error: graph tui requires --run-dir <path>")
        return 1
    plan = decide_tui_launch(parsed.mode, caps)
    if plan.message:
        err_write(plan.message)
    if plan.backend == LAUNCH_CURSES:
        result = run_curses_session(
            parsed.run_dir,
            curses_mod=curses_mod,
            restorer=restorer,
            refresh_interval=parsed.refresh_interval,
            graph_run=parsed.graph_run or default_graph_run(),
            workspace=parsed.workspace,
            load=load,
            keys=keys,
            max_frames=max_frames,
        )
        return result.exit_code
    result = run_streaming_status(
        parsed.run_dir,
        output=output,
        load=load,
        sleep=sleep,
        refresh_interval=parsed.refresh_interval,
        max_frames=max_frames if max_frames is not None else 1,
        fallback=plan.fallback,
        reason=plan.reason,
    )
    return result.exit_code


def _tui_usage() -> str:
    return (
        "Usage: graph_tui.py --run-dir <path> [--workspace <dir>] "
        "[--graph-run <path>] [--mode auto|tui|no-tui] [--refresh-interval <sec>] "
        "[--probe]"
    )


def _require_argv_value(args: Sequence[str], index: int, token: str) -> str:
    if index + 1 >= len(args):
        raise GraphTuiError(f"{token} requires a value")
    return args[index + 1]


def _parse_interval(raw: str) -> float:
    try:
        value = float(raw)
    except (TypeError, ValueError) as exc:
        raise GraphTuiError(f"--refresh-interval requires a number, got {raw!r}") from exc
    if value < 0:
        return 0.0
    return value


def _env_flag(env: Mapping[str, str], name: str) -> bool:
    value = str(env.get(name, "") or "").strip().lower()
    return value in {"1", "true", "yes", "on"}


def _load_curses() -> Any:
    return importlib.import_module("curses")


def _load_termios() -> Any:
    try:
        return importlib.import_module("termios")
    except Exception:
        return None


def _load_signal() -> Any:
    try:
        return importlib.import_module("signal")
    except Exception:
        return None


def _lifecycle_signals(signal_mod: Any) -> Tuple[int, ...]:
    names = ("SIGINT", "SIGTERM")
    found: List[int] = []
    for name in names:
        value = getattr(signal_mod, name, None)
        if isinstance(value, int):
            found.append(value)
    return tuple(found)


def _signal_exit_code(signum: int) -> int:
    return 128 + int(signum)


def _curses_width(stdscr: Any) -> int:
    try:
        _height, width = stdscr.getmaxyx()
        return _clamp_dim(width, DEFAULT_FRAME_WIDTH)
    except Exception:
        return DEFAULT_FRAME_WIDTH


def _curses_height(stdscr: Any) -> int:
    try:
        height, _width = stdscr.getmaxyx()
        return _clamp_dim(height, DEFAULT_FRAME_HEIGHT)
    except Exception:
        return DEFAULT_FRAME_HEIGHT


def _paint_curses_frame(stdscr: Any, frame: str, curses: Any) -> None:
    try:
        stdscr.erase()
    except Exception:
        pass
    height = _curses_height(stdscr)
    width = _curses_width(stdscr)
    error_type = getattr(curses, "error", Exception)
    for row, line in enumerate(frame.split("\n")[:height]):
        try:
            stdscr.addnstr(row, 0, line, max(width - 1, 0))
        except error_type:
            continue
        except Exception:
            continue
    try:
        stdscr.refresh()
    except Exception:
        pass


if __name__ == "__main__":
    sys.exit(main())
