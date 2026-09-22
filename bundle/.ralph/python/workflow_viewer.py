#!/usr/bin/env python3
"""Public entry for ``ralph workflow watch``: curses or streaming plain output.

This module is the only workflow UI process entrypoint. It loads status through
the public ``ralph workflow status <exact-run-id> --json`` boundary, never
writes registry or engine state, and selects curses only when stdin/stdout and
accessibility/plain/CI overrides permit it.
"""

from __future__ import annotations

import argparse
import os
import signal
import sys
import time
from dataclasses import dataclass
from typing import Callable, Mapping, Optional, Sequence, Tuple

import workflow_curses as wcurse
import workflow_plain as wp
import workflow_tui as wt


BACKEND_CURSES = "curses"
BACKEND_PLAIN = "plain"

TERMINAL_STATES = frozenset({"succeeded", "failed", "cancelled"})
WAITING_STATES = frozenset({"waiting"})
# States where watching longer can still show the operator something new.
# queued/running advance on their own. stale is deliberate: the supervisor is
# gone but the run is recoverable, so an operator running `ralph workflow
# recover` in another terminal revives it under this viewer -- see
# test_workflow_viewer.StopWatchingTests. Everything else, blocked included, has
# no supervisor behind it and no recovery path, so polling only reprints the
# same frame.
PROGRESSING_STATES = frozenset({"queued", "running", "stale"})

# How many times a first status refresh may fail transiently before watch gives
# up. Bounded so a genuinely broken run still exits promptly.
COLD_START_RETRY_LIMIT = 3


@dataclass(frozen=True)
class ViewerLaunchPlan:
    backend: str
    reason: Optional[str] = None


@dataclass(frozen=True)
class ViewerSessionResult:
    exit_code: int
    backend: str
    frames: int = 0
    quit_requested: bool = False


def should_stop_watching(view: wt.WorkflowViewModel) -> bool:
    """Return True when watch should detach: terminal or persisted-wait."""

    if view.snapshot is None or view.diagnosis is None:
        return False
    state = view.diagnosis.state
    if not state:
        return False
    # Deny-list on purpose: a diagnosis state added later should stop and show
    # the operator rather than hang the viewer on a run nothing is driving.
    return state not in PROGRESSING_STATES


def select_viewer_backend(
    *,
    force_plain: bool = False,
    stdin_isatty: Optional[bool] = None,
    stdout_isatty: Optional[bool] = None,
    environ: Optional[Mapping[str, str]] = None,
    curses_importer: Optional[Callable[[], object]] = None,
) -> ViewerLaunchPlan:
    """Choose curses or plain streaming. Never raises."""

    env = os.environ if environ is None else environ
    in_tty = sys.stdin.isatty() if stdin_isatty is None else bool(stdin_isatty)
    out_tty = sys.stdout.isatty() if stdout_isatty is None else bool(stdout_isatty)
    if wp.plain_output_required(
        force_plain=force_plain,
        stdin_isatty=in_tty,
        stdout_isatty=out_tty,
        environ=env,
    ):
        return ViewerLaunchPlan(backend=BACKEND_PLAIN, reason="plain")
    caps = wcurse.probe_curses_capabilities(
        stdin_isatty=in_tty,
        stdout_isatty=out_tty,
        environ=env,
        curses_importer=curses_importer,
    )
    if caps.available:
        return ViewerLaunchPlan(backend=BACKEND_CURSES)
    return ViewerLaunchPlan(backend=BACKEND_PLAIN, reason=caps.reason or "fallback")


def _follow_interval(environ: Optional[Mapping[str, str]] = None) -> float:
    env = os.environ if environ is None else environ
    raw = str(env.get("RALPH_WORKFLOW_FOLLOW_INTERVAL") or env.get("RALPH_GRAPH_FOLLOW_INTERVAL") or "1")
    try:
        value = float(raw)
    except ValueError:
        return 1.0
    if value <= 0:
        return 1.0
    return value


def _max_polls(environ: Optional[Mapping[str, str]] = None) -> Optional[int]:
    env = os.environ if environ is None else environ
    raw = str(env.get("RALPH_WORKFLOW_FOLLOW_MAX_POLLS") or "").strip()
    if not raw:
        return None
    if raw.isdigit() and int(raw) > 0:
        return int(raw)
    return None


def run_plain_watch(
    run_id: str,
    *,
    command: Sequence[str] = ("ralph",),
    loader: Optional[Callable[[str, Optional[wt.WorkflowViewModel]], wt.WorkflowViewModel]] = None,
    output: Optional[Callable[[str], None]] = None,
    sleep: Callable[[float], None] = time.sleep,
    refresh_interval: Optional[float] = None,
    max_polls: Optional[int] = None,
    environ: Optional[Mapping[str, str]] = None,
) -> ViewerSessionResult:
    """Stream concise status frames until terminal, waiting, bound, or interrupt."""

    fetch = loader or (
        lambda identifier, previous: wt.load_workflow_view(identifier, previous=previous, command=command)
    )
    writer = output or (lambda text: print(text, flush=True))
    interval = _follow_interval(environ) if refresh_interval is None else max(0.05, float(refresh_interval))
    poll_limit = _max_polls(environ) if max_polls is None else max_polls
    renderer = wp.PlainWatchRenderer()
    previous: Optional[wt.WorkflowViewModel] = None
    frames = 0
    polls = 0
    cold_start_retries = 0

    interrupted = {"value": False}

    def _on_signal(_signum: int, _frame: object) -> None:
        interrupted["value"] = True
        raise KeyboardInterrupt

    previous_int = signal.signal(signal.SIGINT, _on_signal)
    previous_term = signal.signal(signal.SIGTERM, _on_signal)
    try:
        while not interrupted["value"]:
            view = fetch(run_id, previous)
            previous = view
            update = renderer.render(view)
            if update.frame is not None:
                writer("\n".join(update.frame))
                frames += 1
            for event in update.events:
                writer(event)
            if view.error is not None and view.snapshot is None:
                # No snapshot yet. Once one has been seen, load_workflow_view
                # carries it forward and a slow refresh is already survivable;
                # only this cold start was fatal, so a single slow first status
                # call -- the norm on a host busy running the very workflow
                # being watched -- exited 1 before printing anything. Retry the
                # kinds a retry can clear, and fail fast on the ones it cannot.
                if (
                    view.error.code in wt.TRANSIENT_ERROR_KINDS
                    and cold_start_retries < COLD_START_RETRY_LIMIT
                ):
                    cold_start_retries += 1
                    previous = None
                    sleep(interval)
                    continue
                return ViewerSessionResult(exit_code=1, backend=BACKEND_PLAIN, frames=frames)
            if should_stop_watching(view):
                return ViewerSessionResult(exit_code=0, backend=BACKEND_PLAIN, frames=frames)
            polls += 1
            if poll_limit is not None and polls >= poll_limit:
                return ViewerSessionResult(exit_code=0, backend=BACKEND_PLAIN, frames=frames)
            sleep(interval)
    except KeyboardInterrupt:
        interrupted["value"] = True
    finally:
        signal.signal(signal.SIGINT, previous_int)
        signal.signal(signal.SIGTERM, previous_term)

    return ViewerSessionResult(exit_code=130, backend=BACKEND_PLAIN, frames=frames, quit_requested=True)


def run_curses_watch(
    run_id: str,
    *,
    command: Sequence[str] = ("ralph",),
    curses_mod: object = None,
    restorer: Optional[wcurse.TerminalRestorer] = None,
    loader: Optional[Callable[[str, Optional[wt.WorkflowViewModel]], wt.WorkflowViewModel]] = None,
    keys: Optional[Sequence[object]] = None,
    max_frames: Optional[int] = None,
    refresh_interval: Optional[float] = None,
) -> ViewerSessionResult:
    """Interactive viewer; q detaches with 0, Ctrl-C with 130, idle states with 0."""

    interval = DEFAULT_REFRESH if refresh_interval is None else max(0.05, float(refresh_interval))
    result = wcurse.run_curses_session(
        run_id,
        curses_mod=curses_mod,
        restorer=restorer,
        loader=loader,
        command=command,
        refresh_interval=interval,
        keys=keys,
        max_frames=max_frames,
        should_stop=should_stop_watching,
    )
    return ViewerSessionResult(
        exit_code=result.exit_code,
        backend=BACKEND_CURSES,
        frames=result.frames,
        quit_requested=result.quit_requested,
    )


DEFAULT_REFRESH = wcurse.DEFAULT_REFRESH_INTERVAL


def run_workflow_viewer(
    run_id: str,
    *,
    force_plain: bool = False,
    command: Sequence[str] = ("ralph",),
    stdin_isatty: Optional[bool] = None,
    stdout_isatty: Optional[bool] = None,
    environ: Optional[Mapping[str, str]] = None,
    curses_importer: Optional[Callable[[], object]] = None,
    curses_mod: object = None,
    restorer: Optional[wcurse.TerminalRestorer] = None,
    loader: Optional[Callable[[str, Optional[wt.WorkflowViewModel]], wt.WorkflowViewModel]] = None,
    output: Optional[Callable[[str], None]] = None,
    sleep: Callable[[float], None] = time.sleep,
    keys: Optional[Sequence[object]] = None,
    max_frames: Optional[int] = None,
    max_polls: Optional[int] = None,
    refresh_interval: Optional[float] = None,
) -> ViewerSessionResult:
    """Select backend and run until detach, interrupt, terminal, or waiting."""

    plan = select_viewer_backend(
        force_plain=force_plain,
        stdin_isatty=stdin_isatty,
        stdout_isatty=stdout_isatty,
        environ=environ,
        curses_importer=curses_importer,
    )
    if plan.backend == BACKEND_CURSES:
        try:
            return run_curses_watch(
                run_id,
                command=command,
                curses_mod=curses_mod,
                restorer=restorer,
                loader=loader,
                keys=keys,
                max_frames=max_frames,
                refresh_interval=refresh_interval,
            )
        except Exception:
            # Startup/paint failure must fall back to streaming rather than crash
            # the operator's terminal after restoration.
            pass
    return run_plain_watch(
        run_id,
        command=command,
        loader=loader,
        output=output,
        sleep=sleep,
        refresh_interval=refresh_interval,
        max_polls=max_polls,
        environ=environ,
    )


def _parse_argv(argv: Sequence[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        prog="workflow_viewer.py",
        description="Engine-neutral viewer for ralph workflow watch",
    )
    parser.add_argument("--run-id", required=True, help="Exact workflow run id")
    parser.add_argument(
        "--plain",
        action="store_true",
        help="Force deterministic line-oriented streaming output",
    )
    parser.add_argument(
        "--command",
        action="append",
        default=[],
        help="Argv prefix for public ralph CLI (repeatable; default: ralph)",
    )
    parser.add_argument(
        "--refresh-interval",
        type=float,
        default=None,
        help="Status refresh interval in seconds",
    )
    parser.add_argument(
        "--max-polls",
        type=int,
        default=None,
        help="Bound plain follow loops (tests)",
    )
    parser.add_argument(
        "--max-frames",
        type=int,
        default=None,
        help="Bound curses frames (tests)",
    )
    parser.add_argument(
        "--probe",
        action="store_true",
        help="Print selected backend and exit without watching",
    )
    return parser.parse_args(list(argv))


def main(argv: Optional[Sequence[str]] = None) -> int:
    args = _parse_argv(tuple(sys.argv[1:] if argv is None else argv))
    run_id = str(args.run_id)
    if not run_id or run_id == "latest" or "/" in run_id or run_id in {".", ".."}:
        print(
            "Error: workflow watch requires an exact run id (latest and paths are refused)",
            file=sys.stderr,
        )
        return 2
    command: Tuple[str, ...]
    if args.command:
        command = tuple(str(part) for part in args.command)
    else:
        command = ("ralph",)

    if args.probe:
        plan = select_viewer_backend(force_plain=bool(args.plain))
        print(plan.backend)
        return 0

    result = run_workflow_viewer(
        run_id,
        force_plain=bool(args.plain),
        command=command,
        refresh_interval=args.refresh_interval,
        max_polls=args.max_polls,
        max_frames=args.max_frames,
    )
    return int(result.exit_code)


if __name__ == "__main__":
    raise SystemExit(main())
