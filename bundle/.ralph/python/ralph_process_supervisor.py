#!/usr/bin/env python3
"""Ralph process lifecycle supervisor.

The supervisor deliberately uses only the Python standard library.  It gives
each runtime invocation its own session, records that session before waiting,
and leaves a detached run guardian behind so children are still reclaimed if
the shell runner is killed abruptly.
"""

from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import json
import os
import secrets
import shlex
import shutil
import signal
import subprocess
import sys
import time
from pathlib import Path
from typing import Any, Iterable


EXIT_LIMIT = 78
EXIT_SURVIVORS = 79


def utc_now() -> str:
    return dt.datetime.now(dt.timezone.utc).isoformat().replace("+00:00", "Z")


def atomic_json(path: Path, value: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_name(f".{path.name}.{os.getpid()}.{secrets.token_hex(4)}.tmp")
    with tmp.open("w", encoding="utf-8") as handle:
        json.dump(value, handle, sort_keys=True)
        handle.write("\n")
        handle.flush()
        os.fsync(handle.fileno())
    os.replace(tmp, path)


def read_json(path: Path) -> dict[str, Any] | None:
    try:
        with path.open(encoding="utf-8") as handle:
            value = json.load(handle)
        return value if isinstance(value, dict) else None
    except (OSError, ValueError):
        return None


def append_event(run_dir: Path, event: str, **fields: Any) -> None:
    value = {"at": utc_now(), "event": event, **fields}
    try:
        with (run_dir / "process-lifecycle.jsonl").open("a", encoding="utf-8") as handle:
            handle.write(json.dumps(value, sort_keys=True, separators=(",", ":")) + "\n")
    except OSError:
        pass


def pid_alive(pid: int) -> bool:
    if pid <= 0:
        return False
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    return True


def pid_identity(pid: int) -> str:
    """Return a stable birth identity so a reused PID is never trusted."""
    if pid <= 0:
        return ""
    stat_path = Path(f"/proc/{pid}/stat")
    try:
        raw = stat_path.read_text(encoding="utf-8", errors="replace")
        _, separator, remainder = raw.rpartition(")")
        fields = remainder.strip().split()
        if separator and len(fields) > 19:
            return f"proc-start:{fields[19]}"
    except OSError:
        pass
    try:
        value = subprocess.check_output(
            ["ps", "-p", str(pid), "-o", "lstart="],
            text=True,
            stderr=subprocess.DEVNULL,
        ).strip()
        return f"ps-start:{value}" if value else ""
    except (OSError, subprocess.CalledProcessError):
        return ""


def pid_matches(pid: int, identity: str) -> bool:
    if not pid_alive(pid):
        return False
    current = pid_identity(pid)
    return not identity or not current or current == identity


def process_table() -> dict[int, dict[str, Any]]:
    """Return a portable pid/ppid/pgid/session/state snapshot."""
    commands = [
        ["ps", "-axo", "pid=,ppid=,pgid=,state=,command="],
        ["ps", "-eo", "pid=,ppid=,pgid=,state=,args="],
    ]
    output = ""
    for command in commands:
        try:
            output = subprocess.check_output(command, text=True, stderr=subprocess.DEVNULL)
            break
        except (OSError, subprocess.CalledProcessError):
            continue
    result: dict[int, dict[str, Any]] = {}
    for line in output.splitlines():
        parts = line.strip().split(None, 4)
        if len(parts) < 4:
            continue
        try:
            pid, ppid, pgid = (int(parts[index]) for index in range(3))
        except ValueError:
            continue
        try:
            sid = os.getsid(pid)
        except (ProcessLookupError, PermissionError, OSError):
            sid = 0
        result[pid] = {
            "pid": pid,
            "ppid": ppid,
            "pgid": pgid,
            "sid": sid,
            "state": parts[3],
            "command": parts[4] if len(parts) > 4 else "",
        }
    return result


def token_pid_map(tokens: Iterable[str]) -> dict[str, set[int]]:
    """Find scope tokens in one process snapshot without exposing command data."""
    clean_tokens = {token for token in tokens if token}
    found = {token: set() for token in clean_tokens}
    if not clean_tokens:
        return found
    markers = {token: f"RALPH_PROCESS_SCOPE_TOKEN={token}".encode() for token in clean_tokens}
    proc = Path("/proc")
    if proc.is_dir():
        for entry in proc.iterdir():
            if not entry.name.isdigit():
                continue
            try:
                environ = set((entry / "environ").read_bytes().split(b"\0"))
                for token, marker in markers.items():
                    if marker in environ:
                        found[token].add(int(entry.name))
            except OSError:
                continue
        return found
    try:
        output = subprocess.check_output(
            ["ps", "eww", "-axo", "pid=,command="],
            text=True,
            errors="replace",
            stderr=subprocess.DEVNULL,
        )
    except (OSError, subprocess.CalledProcessError):
        return found
    for line in output.splitlines():
        first = line.strip().split(None, 1)
        if not first or not first[0].isdigit():
            continue
        for token, marker in markers.items():
            if marker.decode() in line:
                found[token].add(int(first[0]))
    return found


def scope_members(
    scope: dict[str, Any],
    table: dict[int, dict[str, Any]] | None = None,
    token_members: dict[str, set[int]] | None = None,
) -> set[int]:
    if table is None:
        table = process_table()
    token = str(scope.get("token") or "")
    if token_members is None:
        token_members = token_pid_map([token])
    sid = int(scope.get("session_id") or 0)
    members = {
        pid
        for pid, row in table.items()
        if not str(row["state"]).startswith("Z") and sid > 0 and row["sid"] == sid
    }
    members.update(
        pid
        for pid in token_members.get(token, set())
        if pid in table and not str(table[pid]["state"]).startswith("Z")
    )
    members.discard(os.getpid())
    return members


def signal_pids(pids: Iterable[int], sig: signal.Signals) -> None:
    for pid in sorted(set(pids)):
        try:
            os.kill(pid, sig)
        except (ProcessLookupError, PermissionError):
            pass


def terminate_scope(scope_path: Path, reason: str, force: bool = False) -> list[int]:
    scope = read_json(scope_path)
    if not scope or scope.get("status") not in {"starting", "running", "stopping"}:
        return []
    run_dir = scope_path.parent.parent
    root_pid = int(scope.get("root_pid") or 0)
    term_grace = max(0.0, float(os.environ.get("RALPH_PROCESS_TERM_GRACE_SECONDS", "5")))
    kill_grace = max(0.0, float(os.environ.get("RALPH_PROCESS_KILL_GRACE_SECONDS", "2")))
    scope["status"] = "stopping"
    scope["termination_reason"] = reason
    atomic_json(scope_path, scope)
    append_event(run_dir, "scope-stop-start", scope_id=scope.get("scope_id"), reason=reason)

    members = scope_members(scope)
    # Stop the supervisor/root first so it cannot create replacements while
    # descendants are being reaped.  Every later pass is a fresh snapshot.
    if root_pid in members:
        signal_pids([root_pid], signal.SIGKILL if force else signal.SIGTERM)
    signal_pids(members - {root_pid}, signal.SIGKILL if force else signal.SIGTERM)

    deadline = time.monotonic() + (0.0 if force else term_grace)
    while time.monotonic() < deadline:
        members = scope_members(scope)
        if not members:
            break
        signal_pids(members, signal.SIGTERM)
        time.sleep(0.1)

    members = scope_members(scope)
    if members:
        signal_pids(members, signal.SIGKILL)
        deadline = time.monotonic() + kill_grace
        while time.monotonic() < deadline:
            members = scope_members(scope)
            if not members:
                break
            signal_pids(members, signal.SIGKILL)
            time.sleep(0.1)

    survivors = sorted(scope_members(scope))
    scope["status"] = "survivors" if survivors else "stopped"
    scope["ended_at"] = utc_now()
    scope["survivor_pids"] = survivors
    atomic_json(scope_path, scope)
    append_event(
        run_dir,
        "scope-stop-finish",
        scope_id=scope.get("scope_id"),
        reason=reason,
        survivor_count=len(survivors),
    )
    return survivors


def active_scope_paths(run_dir: Path, scope_owner_pid: int = 0) -> list[Path]:
    paths: list[Path] = []
    for path in sorted((run_dir / "scopes").glob("*.json")):
        value = read_json(path)
        if (
            value
            and value.get("status") in {"starting", "running", "stopping"}
            and (not scope_owner_pid or int(value.get("scope_owner_pid") or 0) == scope_owner_pid)
        ):
            paths.append(path)
    return paths


def live_run_pids(run_dir: Path) -> set[int]:
    scopes = [scope for path in active_scope_paths(run_dir) if (scope := read_json(path))]
    table = process_table()
    token_members = token_pid_map(str(scope.get("token") or "") for scope in scopes)
    result: set[int] = set()
    for scope in scopes:
        result.update(scope_members(scope, table, token_members))
    return result


def stop_run(run_dir: Path, reason: str, force: bool = False) -> list[int]:
    survivors: set[int] = set()
    # Repeat because a live scope wrapper may register a child during shutdown.
    for _ in range(3):
        paths = active_scope_paths(run_dir)
        if not paths:
            break
        for path in paths:
            survivors.update(terminate_scope(path, reason, force))
    run = read_json(run_dir / "run.json") or {}
    run["status"] = "survivors" if survivors else "stopped"
    run["ended_at"] = utc_now()
    run["termination_reason"] = reason
    run["survivor_pids"] = sorted(survivors)
    atomic_json(run_dir / "run.json", run)
    release_run_leases(run_dir)
    append_event(run_dir, "run-stop", reason=reason, survivor_count=len(survivors))
    return sorted(survivors)


def lease_key(plan_path: str) -> str:
    canonical = os.path.realpath(plan_path)
    return hashlib.sha256(canonical.encode()).hexdigest()


def lease_dir(state_root: Path) -> Path:
    return state_root / "processes" / "leases"


def release_run_leases(run_dir: Path) -> None:
    run = read_json(run_dir / "run.json") or {}
    state_root_raw = run.get("state_root")
    if not state_root_raw:
        return
    for path in lease_dir(Path(str(state_root_raw))).glob("*.json"):
        value = read_json(path)
        if value and value.get("run_dir") == str(run_dir):
            try:
                path.unlink()
            except OSError:
                pass


def acquire_lease(state_root: Path, run_dir: Path, plan_path: str, owner_pid: int) -> Path:
    leases = lease_dir(state_root)
    leases.mkdir(parents=True, exist_ok=True)
    path = leases / f"{lease_key(plan_path)}.json"
    value = {
        "plan_path": os.path.realpath(plan_path),
        "run_dir": str(run_dir),
        "owner_pid": owner_pid,
        "owner_identity": pid_identity(owner_pid),
        "acquired_at": utc_now(),
    }
    for _ in range(2):
        try:
            descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
            with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
                json.dump(value, handle, sort_keys=True)
                handle.write("\n")
            append_event(run_dir, "plan-lease-acquired", plan_path=value["plan_path"])
            return path
        except FileExistsError:
            existing = read_json(path) or {}
            existing_dir = Path(str(existing.get("run_dir") or ""))
            existing_run = read_json(existing_dir / "run.json") if str(existing_dir) else None
            existing_owner = int(existing.get("owner_pid") or 0)
            if existing_dir == run_dir and existing_owner == owner_pid:
                return path
            if (
                not existing_run
                or existing_run.get("status") != "running"
                or not pid_matches(existing_owner, str(existing.get("owner_identity") or ""))
            ):
                try:
                    path.unlink()
                except OSError:
                    pass
                continue
            raise RuntimeError(
                f"plan is already active in Ralph run {existing_run.get('run_id', 'unknown')} "
                f"(owner pid {existing_owner})"
            )
    raise RuntimeError("could not acquire plan lease")


def start_guardian(run_dir: Path) -> int:
    log_path = run_dir / "guardian.log"
    log_handle = log_path.open("ab", buffering=0)
    process = subprocess.Popen(
        [sys.executable, str(Path(__file__).resolve()), "guard", "--run-dir", str(run_dir)],
        stdin=subprocess.DEVNULL,
        stdout=log_handle,
        stderr=log_handle,
        start_new_session=True,
        close_fds=True,
    )
    log_handle.close()
    return process.pid


def shell_exports(values: dict[str, Any]) -> str:
    return "\n".join(f"export {key}={shlex.quote(str(value))}" for key, value in values.items())


def command_init(args: argparse.Namespace) -> int:
    state_root = Path(args.state_root).resolve()
    active = state_root / "processes" / "active"
    active.mkdir(parents=True, exist_ok=True)
    run_id = f"{time.strftime('%Y%m%dT%H%M%S')}-{args.owner_pid}-{secrets.token_hex(4)}"
    run_dir = active / run_id
    run_dir.mkdir(mode=0o700)
    (run_dir / "scopes").mkdir()
    run = {
        "version": 1,
        "run_id": run_id,
        "run_dir": str(run_dir),
        "state_root": str(state_root),
        "project_root": os.path.realpath(args.project_root),
        "plan_path": os.path.realpath(args.plan),
        "owner_pid": args.owner_pid,
        "owner_identity": pid_identity(args.owner_pid),
        "owner_start": args.owner_start,
        "kind": args.kind,
        "token": secrets.token_hex(24),
        "status": "running",
        "started_at": utc_now(),
        "max_live": args.max_live,
    }
    atomic_json(run_dir / "run.json", run)
    try:
        acquire_lease(state_root, run_dir, args.plan, args.owner_pid)
        guardian_pid = start_guardian(run_dir)
    except Exception:
        release_run_leases(run_dir)
        shutil.rmtree(run_dir, ignore_errors=True)
        raise
    run["guardian_pid"] = guardian_pid
    run["guardian_identity"] = pid_identity(guardian_pid)
    atomic_json(run_dir / "run.json", run)
    append_event(run_dir, "run-start", kind=args.kind, owner_pid=args.owner_pid)
    print(
        shell_exports(
            {
                "RALPH_PROCESS_RUN_ID": run_id,
                "RALPH_PROCESS_RUN_DIR": run_dir,
                "RALPH_PROCESS_RUN_TOKEN": run["token"],
                "RALPH_PROCESS_GUARDIAN_PID": guardian_pid,
                "RALPH_PROCESS_RUN_OWNED": 1,
            }
        )
    )
    return 0


def command_attach(args: argparse.Namespace) -> int:
    run_dir = Path(args.run_dir).resolve()
    run = read_json(run_dir / "run.json")
    if not run or run.get("status") != "running":
        raise RuntimeError("parent Ralph process run is not active")
    if not pid_matches(int(run.get("guardian_pid") or 0), str(run.get("guardian_identity") or "")):
        raise RuntimeError("parent Ralph process guardian is not active")
    acquire_lease(Path(str(run["state_root"])), run_dir, args.plan, args.lease_owner_pid)
    print(
        shell_exports(
            {
                "RALPH_PROCESS_RUN_ID": run["run_id"],
                "RALPH_PROCESS_RUN_DIR": run_dir,
                "RALPH_PROCESS_RUN_TOKEN": run["token"],
                "RALPH_PROCESS_GUARDIAN_PID": run.get("guardian_pid", ""),
                "RALPH_PROCESS_RUN_OWNED": 0,
            }
        )
    )
    return 0


def command_release_lease(args: argparse.Namespace) -> int:
    run_dir = Path(args.run_dir).resolve()
    run = read_json(run_dir / "run.json")
    if not run:
        return 0
    path = lease_dir(Path(str(run["state_root"]))) / f"{lease_key(args.plan)}.json"
    value = read_json(path)
    if (
        value
        and value.get("run_dir") == str(run_dir)
        and int(value.get("owner_pid") or 0) == args.lease_owner_pid
    ):
        try:
            path.unlink()
        except OSError:
            pass
        append_event(run_dir, "plan-lease-released", plan_path=os.path.realpath(args.plan))
    return 0


def command_guard(args: argparse.Namespace) -> int:
    run_dir = Path(args.run_dir)
    scan_interval = max(0.1, float(os.environ.get("RALPH_PROCESS_SCAN_INTERVAL_SECONDS", "10")))
    # Short, healthy invocations should complete without a process-table scan.
    # The scan exists only as a runaway fuse, not as the normal wait mechanism.
    next_scan = time.monotonic() + scan_interval
    while True:
        run = read_json(run_dir / "run.json")
        if not run or run.get("status") != "running":
            return 0
        owner_pid = int(run.get("owner_pid") or 0)
        if not pid_matches(owner_pid, str(run.get("owner_identity") or "")):
            append_event(run_dir, "guardian-owner-dead", owner_pid=owner_pid)
            survivors = stop_run(run_dir, "owner-exited")
            return EXIT_SURVIVORS if survivors else 0
        now = time.monotonic()
        if now < next_scan:
            time.sleep(min(0.25, next_scan - now))
            continue
        next_scan = now + scan_interval
        scope_values = [scope for path in active_scope_paths(run_dir) if (scope := read_json(path))]
        table = process_table()
        # Session membership is sufficient for periodic limits and avoids the
        # expensive all-environment scan. Token discovery is reserved for the
        # teardown boundary where escaped sessions must be recovered.
        token_members: dict[str, set[int]] = {}
        live: set[int] = set()
        exceeded_scope: tuple[dict[str, Any], int] | None = None
        for scope in scope_values:
            members = scope_members(scope, table, token_members)
            live.update(members)
            scope_limit = int(scope.get("max_live") or 128)
            if len(members) > scope_limit and exceeded_scope is None:
                exceeded_scope = (scope, len(members))
        limit = int(run.get("max_live") or 256)
        if exceeded_scope or len(live) > limit:
            reason = "scope-process-limit" if exceeded_scope else "run-process-limit"
            observed = exceeded_scope[1] if exceeded_scope else len(live)
            observed_limit = int(exceeded_scope[0].get("max_live") or 128) if exceeded_scope else limit
            abort = {
                "at": utc_now(),
                "reason": reason,
                "live": observed,
                "limit": observed_limit,
                "exit_code": EXIT_LIMIT,
            }
            atomic_json(run_dir / "abort.json", abort)
            append_event(run_dir, "process-limit-exceeded", live=observed, limit=observed_limit, reason=reason)
            stop_run(run_dir, reason)
            return EXIT_LIMIT


def command_run_scope(args: argparse.Namespace) -> int:
    command = list(args.command)
    if command and command[0] == "--":
        command.pop(0)
    if not command:
        raise RuntimeError("scope command is required")
    run_dir = Path(args.run_dir).resolve()
    run = read_json(run_dir / "run.json")
    if not run or run.get("status") != "running":
        raise RuntimeError("Ralph process guardian is not active")
    guardian_pid = int(run.get("guardian_pid") or 0)
    if not pid_matches(guardian_pid, str(run.get("guardian_identity") or "")):
        raise RuntimeError("Ralph process guardian exited before scope launch")
    scope_id = f"{args.scope_id}-{os.getpid()}-{secrets.token_hex(4)}"
    scope_path = run_dir / "scopes" / f"{scope_id}.json"
    token = secrets.token_hex(24)
    environment = os.environ.copy()
    environment["RALPH_PROCESS_SCOPE_TOKEN"] = token
    environment["RALPH_PROCESS_RUN_ID"] = str(run["run_id"])
    environment["RALPH_PROCESS_RUN_DIR"] = str(run_dir)
    process = subprocess.Popen(command, env=environment, start_new_session=True)
    scope = {
        "version": 1,
        "scope_id": scope_id,
        "kind": args.kind,
        "runtime": args.runtime,
        "root_pid": process.pid,
        "root_identity": pid_identity(process.pid),
        "session_id": process.pid,
        "wrapper_pid": os.getpid(),
        "scope_owner_pid": args.scope_owner_pid,
        "token": token,
        "status": "running",
        "started_at": utc_now(),
        "max_live": args.max_live,
    }
    atomic_json(scope_path, scope)
    if args.pid_file:
        Path(args.pid_file).write_text(f"{process.pid}\n", encoding="utf-8")
    append_event(run_dir, "scope-start", scope_id=scope_id, kind=args.kind, runtime=args.runtime, root_pid=process.pid)

    received: list[int] = []

    def on_signal(signum: int, _frame: Any) -> None:
        received.append(signum)

    for sig in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
        signal.signal(sig, on_signal)
    exit_code = 0
    reason = "completed"
    while process.poll() is None:
        if received:
            reason = f"wrapper-signal-{received[0]}"
            terminate_scope(scope_path, reason)
            break
        time.sleep(0.1)
    if process.poll() is None:
        try:
            process.wait(timeout=0.5)
        except subprocess.TimeoutExpired:
            terminate_scope(scope_path, reason, force=True)
    return_code = process.poll()
    # A runtime returning does not make its background servers safe to keep.
    # Reap every remaining member before marking the scope terminal.
    if scope_members(scope):
        terminate_scope(scope_path, "root-exited-with-live-descendants")
    if exit_code == 0:
        if (run_dir / "abort.json").is_file():
            exit_code = EXIT_LIMIT
        elif received:
            exit_code = 128 + received[0]
        elif return_code is None:
            exit_code = EXIT_SURVIVORS
        elif return_code < 0:
            exit_code = 128 + abs(return_code)
        else:
            exit_code = return_code
    final_scope = read_json(scope_path) or scope
    if final_scope.get("status") == "survivors":
        exit_code = EXIT_SURVIVORS
    if final_scope.get("status") == "running":
        final_scope["status"] = "exited"
        final_scope["ended_at"] = utc_now()
        final_scope["exit_code"] = exit_code
        atomic_json(scope_path, final_scope)
    append_event(run_dir, "scope-exit", scope_id=scope_id, exit_code=exit_code, reason=reason)
    return exit_code


def command_stop_active(args: argparse.Namespace) -> int:
    run_dir = Path(args.run_dir)
    survivors: set[int] = set()
    for path in active_scope_paths(run_dir, args.owner_pid):
        survivors.update(terminate_scope(path, args.reason, args.force))
    return EXIT_SURVIVORS if survivors else 0


def command_close(args: argparse.Namespace) -> int:
    run_dir = Path(args.run_dir)
    survivors = stop_run(run_dir, args.reason, args.force)
    return EXIT_SURVIVORS if survivors else 0


def runs_for_state_root(state_root: Path) -> list[tuple[Path, dict[str, Any]]]:
    result = []
    for path in sorted((state_root / "processes" / "active").glob("*/run.json")):
        value = read_json(path)
        if value and value.get("status") == "running":
            result.append((path.parent, value))
    return result


def command_list(args: argparse.Namespace) -> int:
    rows = []
    for run_dir, run in runs_for_state_root(Path(args.state_root).resolve()):
        rows.append(
            {
                "run_id": run.get("run_id"),
                "kind": run.get("kind"),
                "plan_path": run.get("plan_path"),
                "owner_pid": run.get("owner_pid"),
                "owner_alive": pid_matches(int(run.get("owner_pid") or 0), str(run.get("owner_identity") or "")),
                "live_processes": len(live_run_pids(run_dir)),
                "started_at": run.get("started_at"),
            }
        )
    if args.json:
        print(json.dumps(rows, indent=2, sort_keys=True))
    elif not rows:
        print("No active Ralph process runs.")
    else:
        print("RUN ID\tOWNER\tLIVE\tKIND\tPLAN")
        for row in rows:
            print(f"{row['run_id']}\t{row['owner_pid']}\t{row['live_processes']}\t{row['kind']}\t{row['plan_path']}")
    return 0


def command_stop(args: argparse.Namespace) -> int:
    state_root = Path(args.state_root).resolve()
    matches: list[tuple[Path, dict[str, Any]]] = []
    plan = os.path.realpath(args.plan) if args.plan else None
    for run_dir, run in runs_for_state_root(state_root):
        if args.all or (args.run and run.get("run_id") == args.run) or (plan and run.get("plan_path") == plan):
            matches.append((run_dir, run))
    if not matches:
        print("No matching active Ralph process runs.", file=sys.stderr)
        return 1
    survivor_count = 0
    for run_dir, run in matches:
        survivors = stop_run(run_dir, "operator-stop", args.force)
        survivor_count += len(survivors)
        owner = int(run.get("owner_pid") or 0)
        if pid_alive(owner):
            try:
                os.kill(owner, signal.SIGKILL if args.force else signal.SIGTERM)
            except (ProcessLookupError, PermissionError):
                pass
        print(f"Stopped Ralph run {run.get('run_id')} ({len(survivors)} survivors).")
    return EXIT_SURVIVORS if survivor_count else 0


def parser() -> argparse.ArgumentParser:
    root = argparse.ArgumentParser(description=__doc__)
    commands = root.add_subparsers(dest="subcommand", required=True)
    init = commands.add_parser("init")
    init.add_argument("--state-root", required=True)
    init.add_argument("--project-root", required=True)
    init.add_argument("--plan", required=True)
    init.add_argument("--kind", choices=("plan", "orchestrator"), required=True)
    init.add_argument("--owner-pid", type=int, required=True)
    init.add_argument("--owner-start", default="")
    init.add_argument("--max-live", type=int, default=256)
    init.set_defaults(func=command_init)
    attach = commands.add_parser("attach")
    attach.add_argument("--run-dir", required=True)
    attach.add_argument("--plan", required=True)
    attach.add_argument("--lease-owner-pid", type=int, required=True)
    attach.set_defaults(func=command_attach)
    release = commands.add_parser("release-lease")
    release.add_argument("--run-dir", required=True)
    release.add_argument("--plan", required=True)
    release.add_argument("--lease-owner-pid", type=int, required=True)
    release.set_defaults(func=command_release_lease)
    guard = commands.add_parser("guard")
    guard.add_argument("--run-dir", required=True)
    guard.set_defaults(func=command_guard)
    scope = commands.add_parser("run-scope")
    scope.add_argument("--run-dir", required=True)
    scope.add_argument("--scope-id", required=True)
    scope.add_argument("--kind", required=True)
    scope.add_argument("--runtime", default="")
    scope.add_argument("--max-live", type=int, default=128)
    scope.add_argument("--pid-file", default="")
    scope.add_argument("--scope-owner-pid", type=int, required=True)
    scope.add_argument("command", nargs=argparse.REMAINDER)
    scope.set_defaults(func=command_run_scope)
    active = commands.add_parser("stop-active")
    active.add_argument("--run-dir", required=True)
    active.add_argument("--reason", default="runner-teardown")
    active.add_argument("--force", action="store_true")
    active.add_argument("--owner-pid", type=int, default=0)
    active.set_defaults(func=command_stop_active)
    close = commands.add_parser("close")
    close.add_argument("--run-dir", required=True)
    close.add_argument("--reason", default="runner-exit")
    close.add_argument("--force", action="store_true")
    close.set_defaults(func=command_close)
    listing = commands.add_parser("list")
    listing.add_argument("--state-root", required=True)
    listing.add_argument("--json", action="store_true")
    listing.set_defaults(func=command_list)
    stop = commands.add_parser("stop")
    stop.add_argument("--state-root", required=True)
    target = stop.add_mutually_exclusive_group(required=True)
    target.add_argument("--run")
    target.add_argument("--plan")
    target.add_argument("--all", action="store_true")
    stop.add_argument("--force", action="store_true")
    stop.set_defaults(func=command_stop)
    return root


def main() -> int:
    args = parser().parse_args()
    try:
        return int(args.func(args))
    except RuntimeError as error:
        print(f"ralph process: {error}", file=sys.stderr)
        return 2
    except KeyboardInterrupt:
        return 130


if __name__ == "__main__":
    raise SystemExit(main())
