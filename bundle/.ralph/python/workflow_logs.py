#!/usr/bin/env python3
"""Contained log pane for the public workflow terminal UI.

Resolves content for the selected public stage and attempt through the same
contracts as ``ralph workflow logs``: public stream names (agent, supervisor,
combined), containment, credential redaction, and bounded tails. Paths never
come from status JSON. Production fetches go through the public CLI; tests and
path-aware callers supply explicit contained relative specs under a known root.
"""

from __future__ import annotations

import os
import re
import subprocess
from dataclasses import dataclass, replace
from pathlib import Path, PurePosixPath
from typing import Callable, Iterable, List, Optional, Sequence, Tuple

import workflow_tui as wt

try:
    import ralph_term as _TERM
except ImportError:  # pragma: no cover - optional shared primitives
    _TERM = None  # type: ignore[assignment]


PUBLIC_LOG_STREAMS = ("agent", "supervisor", "combined")
DEFAULT_LOG_TAIL_LINES = 40
DEFAULT_LOG_READ_BYTES = 65536
DEFAULT_LOG_LINE_MAX = 500
DEFAULT_LOGS_TIMEOUT_SECONDS = 5.0
_REPLACEMENT = _TERM.Symbols(ascii_only=True).replacement if _TERM is not None else "\ufffd"
_CONTROL_CHARS = dict.fromkeys(range(32))
_CONTROL_CHARS[ord("\t")] = " "

_CREDENTIAL_ASSIGNMENT = re.compile(
    r"(?i)(?:password|passwd|secret|token|api[_-]?key|private[_-]?key|"
    r"bearer|authorization|credential)\s*[=:]\s*\S+"
)
_CREDENTIAL_TOKEN = re.compile(
    r"(?i)(?<![A-Za-z0-9_-])(?:sk-[A-Za-z0-9_-]{8,}|AKIA[0-9A-Z]{8,}|"
    r"ghp_[A-Za-z0-9]{20,}|xox[baprs]-[A-Za-z0-9-]{10,})(?![A-Za-z0-9_-])"
)


@dataclass(frozen=True)
class LogPathSpec:
    """One ledger-owned relative log path under a containment root.

    ``relative_path`` must be a contained relative path (no absolute form, no
    ``..``). Callers must never populate this from status JSON path fields.
    """

    containment_root: Path
    relative_path: str
    label: str = ""


@dataclass(frozen=True)
class WorkflowLogPane:
    """Bounded view of one selected stage/attempt stream."""

    stream: str
    stage_id: Optional[str]
    attempt: Optional[int]
    relative_paths: Tuple[str, ...]
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
    paused: bool
    reset: bool
    unavailable: bool
    offset: int
    inode: Optional[int]
    error: Optional[str]


@dataclass(frozen=True)
class WorkflowLogState:
    """Interactive log-pane state. Never stores unbounded line history."""

    selected_stream: str = "agent"
    follow: bool = False
    paused: bool = False
    focused: bool = False
    stage_id: Optional[str] = None
    attempt: Optional[int] = None
    log_offset: int = 0
    log_inode: Optional[int] = None
    log_seen: bool = False


CliFetcher = Callable[..., Tuple[int, str, str]]
PathResolver = Callable[[wt.WorkflowViewModel, WorkflowLogState], Sequence[LogPathSpec]]


def normalize_log_stream(stream: Optional[str]) -> str:
    if stream in PUBLIC_LOG_STREAMS:
        return stream  # type: ignore[return-value]
    return "agent"


def cycle_log_stream(stream: Optional[str], *, delta: int = 1) -> str:
    current = normalize_log_stream(stream)
    index = PUBLIC_LOG_STREAMS.index(current)
    return PUBLIC_LOG_STREAMS[(index + delta) % len(PUBLIC_LOG_STREAMS)]


def map_public_stream_to_internal(stream: str) -> Tuple[str, ...]:
    """Map public stream names to Sequential/Dependency internal file kinds."""

    normalized = normalize_log_stream(stream)
    if normalized == "agent":
        return ("agent",)
    if normalized == "supervisor":
        return ("runner",)
    return ("runner", "agent")


def sequential_stage_log_rel(stage_id: str, attempt: int, public_stream: str) -> Tuple[str, ...]:
    """Relative paths under a Sequential engine directory (mirrors Bash)."""

    normalize_log_stream(public_stream)
    if not isinstance(stage_id, str) or not stage_id or "/" in stage_id or "\\" in stage_id:
        raise ValueError("stage id must be a single path component")
    if not isinstance(attempt, int) or attempt < 0:
        raise ValueError("attempt must be a non-negative integer")
    rels: List[str] = []
    for kind in map_public_stream_to_internal(public_stream):
        rels.append(f"logs/stages/{stage_id}/attempt-{attempt}/{kind}.log")
    return tuple(rels)


def logs_command(
    run_id: str,
    *,
    stage_id: str,
    attempt: int,
    stream: str = "agent",
    tail_lines: int = DEFAULT_LOG_TAIL_LINES,
    command: Sequence[str] = ("ralph",),
) -> Tuple[str, ...]:
    """Build the public ``ralph workflow logs`` argv (finite, no-follow)."""

    if not isinstance(run_id, str) or not run_id or "\x00" in run_id or run_id == "latest":
        raise ValueError("an exact workflow run id is required")
    if not isinstance(stage_id, str) or not stage_id or "\x00" in stage_id:
        raise ValueError("a public stage id is required")
    if not isinstance(attempt, int) or attempt < 0:
        raise ValueError("attempt must be a non-negative integer")
    stream = normalize_log_stream(stream)
    tail_n = _clamp_tail_lines(tail_lines)
    prefix = tuple(command)
    if not prefix or any(not isinstance(part, str) or not part for part in prefix):
        raise ValueError("logs command must contain at least one non-empty argv item")
    return prefix + (
        "workflow",
        "logs",
        run_id,
        "--stage",
        stage_id,
        "--attempt",
        str(attempt),
        "--stream",
        stream,
        "--tail",
        str(tail_n),
        "--no-follow",
    )


def looks_like_credential(text: str) -> bool:
    if not text:
        return False
    return bool(_CREDENTIAL_ASSIGNMENT.search(text) or _CREDENTIAL_TOKEN.search(text))


def redact_log_line(line: str, *, max_length: int = DEFAULT_LOG_LINE_MAX) -> str:
    """Mirror ``workflow_operator_redact_log_line`` for display safety."""

    cleaned = _sanitize_log_line(line)
    if looks_like_credential(cleaned):
        return "[REDACTED]"
    limit = max(1, int(max_length))
    if len(cleaned) > limit:
        return cleaned[:limit] + "...[truncated]"
    return cleaned


def is_contained_rel(rel: str) -> bool:
    if not rel or rel.startswith("/") or "\\" in rel:
        return False
    parts = PurePosixPath(rel).parts
    if not parts or any(part in {"", ".", ".."} for part in parts):
        return False
    return True


def resolve_contained(root: Path, rel: str) -> Optional[Path]:
    """Resolve ``rel`` under ``root`` without following escape symlinks."""

    if not is_contained_rel(rel):
        return None
    try:
        run_real = root.resolve()
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
            return resolved
    except OSError:
        return None
    return current


def initial_log_state(
    view: Optional[wt.WorkflowViewModel] = None,
    **overrides: object,
) -> WorkflowLogState:
    stage = view.selected_stage if view is not None else None
    base = WorkflowLogState(
        selected_stream="agent",
        stage_id=stage.id if stage is not None else None,
        attempt=stage.attempt if stage is not None else None,
    )
    if not overrides:
        return base
    return replace(base, **overrides)  # type: ignore[arg-type]


def reconcile_log_state(view: wt.WorkflowViewModel, state: WorkflowLogState) -> WorkflowLogState:
    """Reset the log cursor when the selected public stage or attempt changes."""

    stage = view.selected_stage
    stream = normalize_log_stream(state.selected_stream)
    if stage is None:
        if state.stage_id is None and state.attempt is None and state.selected_stream == stream:
            return state
        return replace(
            state,
            selected_stream=stream,
            stage_id=None,
            attempt=None,
            log_offset=0,
            log_inode=None,
            log_seen=False,
        )
    if state.stage_id == stage.id and state.attempt == stage.attempt and state.selected_stream == stream:
        return state
    return replace(
        state,
        selected_stream=stream,
        stage_id=stage.id,
        attempt=stage.attempt,
        log_offset=0,
        log_inode=None,
        log_seen=False,
    )


def set_log_stream(state: WorkflowLogState, stream: str) -> WorkflowLogState:
    normalized = normalize_log_stream(stream)
    if state.selected_stream == normalized:
        return state
    return replace(
        state,
        selected_stream=normalized,
        log_offset=0,
        log_inode=None,
        log_seen=False,
    )


def toggle_follow(state: WorkflowLogState) -> WorkflowLogState:
    follow = not state.follow
    return replace(state, follow=follow, paused=False if follow else state.paused)


def toggle_pause(state: WorkflowLogState) -> WorkflowLogState:
    return replace(state, paused=not state.paused)


def toggle_log_focus(state: WorkflowLogState) -> WorkflowLogState:
    return replace(state, focused=not state.focused)


def read_log_pane(
    view: wt.WorkflowViewModel,
    state: Optional[WorkflowLogState] = None,
    *,
    path_specs: Optional[Sequence[LogPathSpec]] = None,
    path_resolver: Optional[PathResolver] = None,
    cli_fetcher: Optional[CliFetcher] = None,
    command: Sequence[str] = ("ralph",),
    timeout: float = DEFAULT_LOGS_TIMEOUT_SECONDS,
    tail_lines: int = DEFAULT_LOG_TAIL_LINES,
    previous_pane: Optional[WorkflowLogPane] = None,
) -> Tuple[WorkflowLogPane, WorkflowLogState]:
    """Load a bounded log pane for the selected public stage/attempt.

    Prefer ``path_specs`` / ``path_resolver`` (contained relative reads). When
    neither supplies paths, fetch through the public ``ralph workflow logs``
    CLI. Never reads arbitrary paths from status JSON. Pausing reuses
    ``previous_pane`` without reopening files.
    """

    current = reconcile_log_state(view, state if state is not None else initial_log_state(view))
    stream = normalize_log_stream(current.selected_stream)
    current = replace(current, selected_stream=stream)
    stage = view.selected_stage
    tail_n = _clamp_tail_lines(tail_lines)

    if stage is None:
        pane = _empty_pane(
            stream=stream,
            stage_id=None,
            attempt=None,
            follow=current.follow,
            paused=current.paused,
            missing=True,
            error="no selected stage",
        )
        return pane, _reset_cursor(current)

    if current.paused and previous_pane is not None:
        return (
            replace(
                previous_pane,
                follow=current.follow,
                paused=True,
                stage_id=stage.id,
                attempt=stage.attempt,
                stream=stream,
            ),
            current,
        )

    specs: Sequence[LogPathSpec]
    if path_specs is not None:
        specs = tuple(path_specs)
    elif path_resolver is not None:
        specs = tuple(path_resolver(view, current))
    else:
        specs = ()

    if specs:
        return _read_from_path_specs(specs, current, stage=stage, stream=stream, tail_lines=tail_n)

    return _read_from_cli(
        view,
        current,
        stage=stage,
        stream=stream,
        tail_lines=tail_n,
        cli_fetcher=cli_fetcher,
        command=command,
        timeout=timeout,
    )


def paint_log_lines(pane: WorkflowLogPane, *, max_lines: int) -> Tuple[str, ...]:
    """Return at most ``max_lines`` display lines including a status header."""

    budget = max(0, int(max_lines))
    if budget <= 0:
        return ()
    header = _pane_header(pane)
    if budget == 1:
        return (header,)
    body: List[str] = []
    if pane.error and (pane.missing or pane.uncontained or pane.symlink or pane.unavailable):
        body.append(pane.error)
    else:
        body.extend(pane.lines)
    keep = budget - 1
    if len(body) > keep:
        body = list(body[-keep:])
    return (header, *body)


def _read_from_path_specs(
    specs: Sequence[LogPathSpec],
    state: WorkflowLogState,
    *,
    stage: wt.Stage,
    stream: str,
    tail_lines: int,
) -> Tuple[WorkflowLogPane, WorkflowLogState]:
    follow = bool(state.follow)
    if not specs:
        pane = _empty_pane(
            stream=stream,
            stage_id=stage.id,
            attempt=stage.attempt,
            follow=follow,
            paused=state.paused,
            missing=True,
            error="workflow log not found for stream",
        )
        return pane, _reset_cursor(state)

    collected: List[str] = []
    relative_paths: List[str] = []
    total_size = 0
    any_exists = False
    any_missing = False
    any_uncontained = False
    any_symlink = False
    any_omitted = False
    any_replaced = False
    any_truncated = False
    errors: List[str] = []
    primary_inode: Optional[int] = None
    primary_offset = 0
    reset = False

    for spec in specs:
        relative_paths.append(spec.relative_path)
        if not is_contained_rel(spec.relative_path):
            any_uncontained = True
            errors.append("workflow log path is not a contained relative path")
            continue
        resolved = resolve_contained(Path(spec.containment_root), spec.relative_path)
        if resolved is None:
            any_uncontained = True
            errors.append("workflow log path is not contained in the run root")
            continue
        if resolved.is_symlink():
            any_symlink = True
            errors.append("refusing to read a workflow log symlink")
            continue
        if not resolved.is_file():
            any_missing = True
            continue
        try:
            stat = resolved.stat()
            size = int(stat.st_size)
            inode = int(stat.st_ino)
            raw, omitted_bytes = _read_log_tail_bytes(resolved, size)
        except OSError:
            any_missing = True
            errors.append("workflow log file could not be inspected")
            continue

        any_exists = True
        total_size += size
        if primary_inode is None:
            primary_inode = inode
            primary_offset = size
            if state.log_seen:
                if state.log_inode is not None and inode != state.log_inode:
                    reset = True
                elif state.log_offset > size:
                    reset = True

        text, replaced = _decode_log_bytes(raw)
        any_replaced = any_replaced or replaced
        any_omitted = any_omitted or omitted_bytes
        if omitted_bytes or (raw and not raw.endswith(b"\n")):
            any_truncated = True
        any_truncated = any_truncated or reset

        lines = [_prepare_display_line(line) for line in text.splitlines()]
        if spec.label and len(specs) > 1:
            lines = [f"[{spec.label}] {line}" if line else f"[{spec.label}]" for line in lines]
        collected.extend(lines)

    if any_uncontained or any_symlink:
        pane = WorkflowLogPane(
            stream=stream,
            stage_id=stage.id,
            attempt=stage.attempt,
            relative_paths=tuple(relative_paths),
            lines=(),
            exists=False,
            size_bytes=None,
            missing=False,
            uncontained=any_uncontained,
            symlink=any_symlink,
            truncated=False,
            omitted=False,
            replaced=False,
            follow=follow,
            paused=state.paused,
            reset=False,
            unavailable=False,
            offset=0,
            inode=None,
            error=errors[0] if errors else "workflow log unavailable",
        )
        return pane, _reset_cursor(state)

    if not any_exists:
        pane = _empty_pane(
            stream=stream,
            stage_id=stage.id,
            attempt=stage.attempt,
            follow=follow,
            paused=state.paused,
            missing=True,
            relative_paths=tuple(relative_paths),
            error=errors[0] if errors else None,
        )
        return pane, _reset_cursor(state)

    omitted = any_omitted
    if len(collected) > tail_lines:
        lines_out = tuple(collected[-tail_lines:])
        omitted = True
    else:
        lines_out = tuple(collected)

    pane = WorkflowLogPane(
        stream=stream,
        stage_id=stage.id,
        attempt=stage.attempt,
        relative_paths=tuple(relative_paths),
        lines=lines_out,
        exists=True,
        size_bytes=total_size,
        missing=any_missing and any_exists,
        uncontained=False,
        symlink=False,
        truncated=any_truncated,
        omitted=omitted,
        replaced=any_replaced,
        follow=follow,
        paused=state.paused,
        reset=reset,
        unavailable=False,
        offset=primary_offset,
        inode=primary_inode,
        error=None,
    )
    updated = replace(state, log_offset=primary_offset, log_inode=primary_inode, log_seen=True)
    return pane, updated


def _read_from_cli(
    view: wt.WorkflowViewModel,
    state: WorkflowLogState,
    *,
    stage: wt.Stage,
    stream: str,
    tail_lines: int,
    cli_fetcher: Optional[CliFetcher],
    command: Sequence[str],
    timeout: float,
) -> Tuple[WorkflowLogPane, WorkflowLogState]:
    follow = bool(state.follow)
    run = view.run
    if run is None:
        pane = _empty_pane(
            stream=stream,
            stage_id=stage.id,
            attempt=stage.attempt,
            follow=follow,
            paused=state.paused,
            unavailable=True,
            error="workflow run is unavailable",
        )
        return pane, _reset_cursor(state)

    try:
        argv = logs_command(
            run.run_id,
            stage_id=stage.id,
            attempt=stage.attempt,
            stream=stream,
            tail_lines=tail_lines,
            command=command,
        )
    except ValueError as exc:
        pane = _empty_pane(
            stream=stream,
            stage_id=stage.id,
            attempt=stage.attempt,
            follow=follow,
            paused=state.paused,
            unavailable=True,
            error=str(exc),
        )
        return pane, _reset_cursor(state)

    if timeout <= 0:
        pane = _empty_pane(
            stream=stream,
            stage_id=stage.id,
            attempt=stage.attempt,
            follow=follow,
            paused=state.paused,
            unavailable=True,
            error="workflow logs timeout must be positive",
        )
        return pane, _reset_cursor(state)

    try:
        if cli_fetcher is not None:
            returncode, stdout, stderr = cli_fetcher(argv, timeout=timeout)
        else:
            completed = subprocess.run(
                argv,
                capture_output=True,
                text=True,
                check=False,
                timeout=timeout,
            )
            returncode = int(completed.returncode)
            stdout = completed.stdout or ""
            stderr = completed.stderr or ""
    except subprocess.TimeoutExpired:
        pane = _empty_pane(
            stream=stream,
            stage_id=stage.id,
            attempt=stage.attempt,
            follow=follow,
            paused=state.paused,
            unavailable=True,
            error="workflow logs refresh timed out",
        )
        return pane, _reset_cursor(state)
    except OSError as exc:
        pane = _empty_pane(
            stream=stream,
            stage_id=stage.id,
            attempt=stage.attempt,
            follow=follow,
            paused=state.paused,
            unavailable=True,
            error=f"workflow logs unavailable: {exc}",
        )
        return pane, _reset_cursor(state)

    stderr_l = (stderr or "").lower()
    if returncode != 0:
        missing = "not found" in stderr_l
        pane = _empty_pane(
            stream=stream,
            stage_id=stage.id,
            attempt=stage.attempt,
            follow=follow,
            paused=state.paused,
            missing=missing,
            unavailable=not missing,
            error=_safe_error(stderr) or "workflow logs unavailable",
        )
        return pane, _reset_cursor(state)

    raw_lines = stdout.splitlines()
    # CLI already redacts; still sanitize controls and bound memory.
    prepared = [_prepare_display_line(line, redact=False) for line in raw_lines]
    omitted = False
    if len(prepared) > tail_lines:
        prepared = prepared[-tail_lines:]
        omitted = True

    reset = False
    size_hint = sum(len(line) + 1 for line in prepared)
    if state.log_seen and state.log_offset > size_hint:
        reset = True

    pane = WorkflowLogPane(
        stream=stream,
        stage_id=stage.id,
        attempt=stage.attempt,
        relative_paths=(),
        lines=tuple(prepared),
        exists=True,
        size_bytes=size_hint,
        missing=False,
        uncontained=False,
        symlink=False,
        truncated=reset,
        omitted=omitted,
        replaced=False,
        follow=follow,
        paused=state.paused,
        reset=reset,
        unavailable=False,
        offset=size_hint,
        inode=None,
        error=None,
    )
    if not prepared and "not found" in stderr_l:
        pane = replace(pane, exists=False, missing=True, error=_safe_error(stderr))
        return pane, _reset_cursor(state)

    updated = replace(state, log_offset=size_hint, log_inode=None, log_seen=True)
    return pane, updated


def _prepare_display_line(line: str, *, redact: bool = True) -> str:
    if redact:
        return redact_log_line(line)
    cleaned = _sanitize_log_line(line)
    if len(cleaned) > DEFAULT_LOG_LINE_MAX:
        return cleaned[:DEFAULT_LOG_LINE_MAX] + "...[truncated]"
    return cleaned


def _pane_header(pane: WorkflowLogPane) -> str:
    flags: List[str] = []
    if pane.follow and not pane.paused:
        flags.append("follow=on")
    if pane.paused:
        flags.append("paused")
    if pane.missing:
        flags.append("missing")
    if pane.uncontained:
        flags.append("uncontained")
    if pane.symlink:
        flags.append("symlink")
    if pane.unavailable:
        flags.append("unavailable")
    if pane.truncated:
        flags.append("truncated")
    if pane.omitted:
        flags.append("omitted")
    if pane.replaced:
        flags.append("replaced")
    if pane.reset:
        flags.append("reset")
    stage = pane.stage_id or "-"
    attempt = str(pane.attempt) if pane.attempt is not None else "-"
    path = pane.relative_paths[0] if len(pane.relative_paths) == 1 else (
        f"{len(pane.relative_paths)} files" if pane.relative_paths else "-"
    )
    header = f"LOG  stream={pane.stream}  stage={stage}  attempt={attempt}  path={path}"
    if flags:
        header = f"{header}  {' '.join(flags)}"
    return header


def _empty_pane(
    *,
    stream: str,
    stage_id: Optional[str],
    attempt: Optional[int],
    follow: bool,
    paused: bool,
    missing: bool = False,
    unavailable: bool = False,
    relative_paths: Tuple[str, ...] = (),
    error: Optional[str] = None,
) -> WorkflowLogPane:
    return WorkflowLogPane(
        stream=stream,
        stage_id=stage_id,
        attempt=attempt,
        relative_paths=relative_paths,
        lines=(),
        exists=False,
        size_bytes=None,
        missing=missing,
        uncontained=False,
        symlink=False,
        truncated=False,
        omitted=False,
        replaced=False,
        follow=follow,
        paused=paused,
        reset=False,
        unavailable=unavailable,
        offset=0,
        inode=None,
        error=error,
    )


def _reset_cursor(state: WorkflowLogState) -> WorkflowLogState:
    return replace(state, log_offset=0, log_inode=None, log_seen=False)


def _clamp_tail_lines(value: object) -> int:
    try:
        parsed = int(value)  # type: ignore[arg-type]
    except (TypeError, ValueError):
        return DEFAULT_LOG_TAIL_LINES
    if parsed < 1:
        return DEFAULT_LOG_TAIL_LINES
    return min(parsed, 10_000)


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


def _safe_error(stderr: object) -> str:
    if not isinstance(stderr, str):
        return ""
    detail = re.sub(r"[\x00-\x1f\x7f]+", " ", stderr).strip()
    return detail[:240]


def iter_internal_stream_labels(public_stream: str) -> Iterable[str]:
    for kind in map_public_stream_to_internal(public_stream):
        yield "supervisor" if kind == "runner" else kind
