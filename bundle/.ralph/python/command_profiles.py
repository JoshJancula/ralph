#!/usr/bin/env python3
"""Repo-scoped learned command-duration store under .ralph-workspace/command-profiles/.

Shared across plans: a slow suite is slow regardless of which plan invokes it.
Writes use an exclusive flock (same pattern as plan_memory.locked_run). A failed
lock acquisition or any write error drops the observation silently so PostToolUse
hooks never fail the agent's tool call.
"""

from __future__ import annotations

import fcntl
import json
import os
import re
import sys
import tempfile
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

_SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
if _SCRIPT_DIR not in sys.path:
    sys.path.insert(0, _SCRIPT_DIR)

from command_fingerprint import fingerprint as command_fingerprint_fn  # noqa: E402
from shell_command_registry import (  # noqa: E402
    _basename,
    _has_background,
    try_parse_tokens,
)

SCHEMA_VERSION = 1
DURATION_HISTORY_CAP = 10
DISPLAY_COMMAND_MAX = 240

# Single observation above this duration promotes long_running immediately so the
# next invocation can be backgrounded without waiting for a sample window.
LONG_RUNNING_THRESHOLD_MS = 60000
# Demotion waits for at least this many retained observations so a median can
# self-correct; a lone cold-cache spike cannot pin a fast command forever.
MIN_OBSERVATIONS_FOR_DEMOTION = 2

# Pre/post pairing markers for runtimes that do not deliver elapsed time in the
# post-tool payload (Codex, OpenCode). Stale markers older than this are dropped
# so an interrupted run cannot leak entries forever.
INFLIGHT_MAX_AGE_SECONDS = 3600
INFLIGHT_DIRNAME = "inflight"

# Operator-extensible denylist file under .ralph-workspace/command-profiles/.
# One regex per line; blank lines and # comments are ignored. No env var.
NEVER_BACKGROUND_FILENAME = "never-background"

_SENSITIVE_ASSIGN = re.compile(
    r"(?i)\b(password|passwd|secret|token|api[_-]?key|private[_-]?key|"
    r"authorization|auth|bearer)=([^\s]+)"
)

# Dependency installs must finish before later build/test steps can run.
_NPM_LIKE = frozenset({"npm", "pnpm", "yarn"})
_PIP_LIKE = frozenset({"pip", "pip3"})
_GIT_MUTATING = frozenset({
    "clone",
    "pull",
    "fetch",
    "push",
    "merge",
    "rebase",
    "checkout",
})
# DB migrate/seed and ship steps: ordering failures are hard to diagnose when
# these are auto-backgrounded, so they stay denylisted regardless of duration.
_MIGRATE_SEED_RE = re.compile(
    r"(?i)\b(?:migrate|migration|migrations|seed|seeds|seeding)\b"
)
_DEPLOY_PUBLISH_RELEASE_RE = re.compile(r"(?i)\b(?:deploy|publish|release)\b")


def profiles_dir(state_root: Path) -> Path:
    return Path(state_root) / "command-profiles"


def profiles_path(state_root: Path) -> Path:
    return profiles_dir(state_root) / "profiles.json"


def profiles_lock_path(state_root: Path) -> Path:
    """Lock file beside the store (mirrors plan_memory.memory_lock_path)."""
    return profiles_dir(state_root) / ".lock"


def never_background_path(state_root: Path) -> Path:
    """Newline-delimited regex denylist beside profiles.json."""
    return profiles_dir(state_root) / NEVER_BACKGROUND_FILENAME


def inflight_dir(state_root: Path) -> Path:
    """Pre/post pairing markers under .ralph-workspace/command-profiles/inflight/."""
    return profiles_dir(state_root) / INFLIGHT_DIRNAME


def _utc_now_iso() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def _utc_now_ms() -> int:
    return int(datetime.now(timezone.utc).timestamp() * 1000)


def _safe_token(value: str, *, max_length: int = 120) -> str:
    """Filesystem-safe token for inflight marker filenames."""
    text = re.sub(r"[^A-Za-z0-9._-]+", "_", str(value or "").strip())
    text = text.strip("._-") or "unknown"
    return text[:max_length]


def redact_command_display(command: str, *, max_length: int = DISPLAY_COMMAND_MAX) -> str:
    """Return a short, credential-safe display form of the command."""
    text = " ".join(str(command or "").split())
    text = _SENSITIVE_ASSIGN.sub(r"\1=[REDACTED]", text)
    limit = max(1, int(max_length))
    if len(text) > limit:
        return text[: limit - 3] + "..."
    return text


def _median_ms(durations: list[int]) -> int:
    if not durations:
        return 0
    ordered = sorted(int(d) for d in durations)
    n = len(ordered)
    mid = n // 2
    if n % 2 == 1:
        return ordered[mid]
    return (ordered[mid - 1] + ordered[mid]) // 2


def _empty_store() -> dict[str, Any]:
    return {"schema_version": SCHEMA_VERSION, "entries": {}}


def _normalize_store(data: Any) -> dict[str, Any]:
    if not isinstance(data, dict):
        return _empty_store()
    entries = data.get("entries")
    if isinstance(entries, dict):
        normalized_entries = {
            str(key): value for key, value in entries.items() if isinstance(value, dict)
        }
    elif isinstance(entries, list):
        normalized_entries = {}
        for item in entries:
            if not isinstance(item, dict):
                continue
            fp = item.get("fingerprint")
            if isinstance(fp, str) and fp:
                normalized_entries[fp] = item
    else:
        normalized_entries = {}
    return {
        "schema_version": int(data.get("schema_version") or SCHEMA_VERSION),
        "entries": normalized_entries,
    }


def read_store(state_root: Path) -> dict[str, Any]:
    """Load the profiles store. Corrupt or missing files become an empty store."""
    path = profiles_path(state_root)
    if not path.is_file():
        return _empty_store()
    try:
        raw = path.read_text(encoding="utf-8")
    except OSError:
        return _empty_store()
    if not raw.strip():
        return _empty_store()
    try:
        data = json.loads(raw)
    except (json.JSONDecodeError, ValueError, TypeError):
        return _empty_store()
    return _normalize_store(data)


def locked_run(state_root: Path, callback):
    """Run callback under an exclusive flock (same pattern as plan_memory)."""
    lock_path = profiles_lock_path(state_root)
    lock_path.parent.mkdir(parents=True, exist_ok=True)
    with open(lock_path, "a+", encoding="utf-8") as lock_fh:
        fcntl.flock(lock_fh.fileno(), fcntl.LOCK_EX)
        try:
            return callback()
        finally:
            fcntl.flock(lock_fh.fileno(), fcntl.LOCK_UN)


def try_locked_run(state_root: Path, callback):
    """Non-blocking flock. Contested or failed acquisition returns None (silent drop)."""
    lock_path = profiles_lock_path(state_root)
    try:
        lock_path.parent.mkdir(parents=True, exist_ok=True)
        with open(lock_path, "a+", encoding="utf-8") as lock_fh:
            try:
                fcntl.flock(lock_fh.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
            except (BlockingIOError, OSError):
                return None
            try:
                return callback()
            finally:
                try:
                    fcntl.flock(lock_fh.fileno(), fcntl.LOCK_UN)
                except OSError:
                    pass
    except OSError:
        return None


def _atomic_write_json(path: Path, payload: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp_name = tempfile.mkstemp(prefix=".profiles-", dir=str(path.parent))
    os.close(fd)
    tmp_path = Path(tmp_name)
    try:
        tmp_path.write_text(
            json.dumps(payload, indent=2, sort_keys=True) + "\n",
            encoding="utf-8",
        )
        os.replace(tmp_path, path)
    finally:
        if tmp_path.exists():
            tmp_path.unlink(missing_ok=True)


def _apply_observation(
    store: dict[str, Any],
    *,
    fingerprint: str,
    command: str,
    duration_ms: int,
) -> dict[str, Any]:
    entries = store.setdefault("entries", {})
    existing = entries.get(fingerprint)
    promoted_at: str | None = None
    demoted_at: str | None = None
    if isinstance(existing, dict):
        durations = list(existing.get("durations_ms") or [])
        observation_count = int(existing.get("observation_count") or 0)
        long_running = bool(existing.get("long_running"))
        display = existing.get("command") or redact_command_display(command)
        prior_promoted = existing.get("promoted_at")
        prior_demoted = existing.get("demoted_at")
        if isinstance(prior_promoted, str) and prior_promoted:
            promoted_at = prior_promoted
        if isinstance(prior_demoted, str) and prior_demoted:
            demoted_at = prior_demoted
    else:
        durations = []
        observation_count = 0
        long_running = False
        display = redact_command_display(command)

    durations.append(int(duration_ms))
    if len(durations) > DURATION_HISTORY_CAP:
        durations = durations[-DURATION_HISTORY_CAP:]
    observation_count += 1
    median = _median_ms(durations)
    now = _utc_now_iso()

    # Promote on the first observation that exceeds the threshold (fast learning).
    # Demote only once a median over enough samples falls below it (self-correct).
    if not long_running and int(duration_ms) > LONG_RUNNING_THRESHOLD_MS:
        long_running = True
        promoted_at = now
    elif (
        long_running
        and observation_count >= MIN_OBSERVATIONS_FOR_DEMOTION
        and median < LONG_RUNNING_THRESHOLD_MS
    ):
        long_running = False
        demoted_at = now

    entry: dict[str, Any] = {
        "fingerprint": fingerprint,
        "command": display,
        "observation_count": observation_count,
        "durations_ms": durations,
        "median_ms": median,
        "long_running": long_running,
        "last_seen": now,
    }
    if promoted_at:
        entry["promoted_at"] = promoted_at
    if demoted_at:
        entry["demoted_at"] = demoted_at
    entries[fingerprint] = entry
    store["schema_version"] = SCHEMA_VERSION
    return entry


def record_observation(
    state_root: Path,
    fingerprint: str,
    command: str,
    duration_ms: int,
) -> dict[str, Any] | None:
    """Append one duration observation. Returns the updated entry, or None on drop.

    Failed lock acquisition, I/O errors, and malformed inputs drop silently.
    """
    if not fingerprint or not isinstance(fingerprint, str):
        return None
    try:
        duration = int(duration_ms)
    except (TypeError, ValueError):
        return None
    if duration < 0:
        return None

    def _write() -> dict[str, Any]:
        store = read_store(state_root)
        entry = _apply_observation(
            store,
            fingerprint=fingerprint,
            command=command,
            duration_ms=duration,
        )
        _atomic_write_json(profiles_path(state_root), store)
        return entry

    # Blocking flock (plan_memory pattern) serializes parallel PostToolUse writers.
    # Any lock/I/O failure drops the observation silently — never raises to the hook.
    try:
        return locked_run(state_root, _write)
    except Exception:
        return None


def get_entry(state_root: Path, fingerprint: str) -> dict[str, Any] | None:
    """Return one entry by fingerprint, or None."""
    if not fingerprint:
        return None
    store = read_store(state_root)
    entry = store.get("entries", {}).get(fingerprint)
    return entry if isinstance(entry, dict) else None


def list_entries(state_root: Path) -> list[dict[str, Any]]:
    """Return store entries sorted by median duration descending.

    Each dict includes the stored fields plus ``denylisted`` (bool) derived
    from the current never-background rules against the redacted command.
    """
    store = read_store(state_root)
    rows: list[dict[str, Any]] = []
    for fingerprint, raw in (store.get("entries") or {}).items():
        if not isinstance(raw, dict):
            continue
        entry = dict(raw)
        entry["fingerprint"] = str(entry.get("fingerprint") or fingerprint)
        command = str(entry.get("command") or "")
        entry["denylisted"] = is_never_background(command, state_root)
        try:
            entry["median_ms"] = int(entry.get("median_ms") or 0)
        except (TypeError, ValueError):
            entry["median_ms"] = 0
        rows.append(entry)
    rows.sort(key=lambda row: (-int(row.get("median_ms") or 0), str(row.get("fingerprint") or "")))
    return rows


def find_entries_by_prefix(state_root: Path, prefix: str) -> list[dict[str, Any]]:
    """Return entries whose fingerprint equals or starts with prefix."""
    needle = str(prefix or "").strip()
    if not needle:
        return []
    matches: list[dict[str, Any]] = []
    for entry in list_entries(state_root):
        fp = str(entry.get("fingerprint") or "")
        if fp == needle or fp.startswith(needle):
            matches.append(entry)
    return matches


def resolve_fingerprint_prefix(
    state_root: Path,
    prefix: str,
) -> dict[str, Any] | None:
    """Resolve a unique fingerprint prefix to one entry.

    Returns the entry on a unique match. Returns None when nothing matches.
    Raises ValueError when the prefix is empty or ambiguous.
    """
    needle = str(prefix or "").strip()
    if not needle:
        raise ValueError("fingerprint prefix is required")
    matches = find_entries_by_prefix(state_root, needle)
    if not matches:
        return None
    if len(matches) > 1:
        fps = ", ".join(str(m.get("fingerprint") or "") for m in matches[:8])
        extra = "" if len(matches) <= 8 else f" (+{len(matches) - 8} more)"
        raise ValueError(
            f"ambiguous fingerprint prefix {needle!r} matches {len(matches)} "
            f"entries: {fps}{extra}"
        )
    return matches[0]


def delete_entry(state_root: Path, fingerprint: str) -> bool:
    """Remove one entry by exact fingerprint. Returns True when removed."""
    fp = str(fingerprint or "").strip()
    if not fp:
        return False

    removed = {"ok": False}

    def _write() -> None:
        store = read_store(state_root)
        entries = store.get("entries") or {}
        if fp not in entries:
            return
        del entries[fp]
        store["entries"] = entries
        store["schema_version"] = SCHEMA_VERSION
        _atomic_write_json(profiles_path(state_root), store)
        removed["ok"] = True

    try:
        locked_run(state_root, _write)
    except Exception:
        return False
    return bool(removed["ok"])


def reset_all_entries(state_root: Path) -> int:
    """Clear the entire profiles store. Returns the number of entries removed."""
    removed_count = {"n": 0}

    def _write() -> None:
        store = read_store(state_root)
        entries = store.get("entries") or {}
        removed_count["n"] = len(entries) if isinstance(entries, dict) else 0
        _atomic_write_json(profiles_path(state_root), _empty_store())

    try:
        locked_run(state_root, _write)
    except Exception:
        return 0
    return int(removed_count["n"])


def is_long_running(state_root: Path, fingerprint: str) -> bool:
    """True when the store marks this fingerprint as long-running."""
    entry = get_entry(state_root, fingerprint)
    if entry is None:
        return False
    return bool(entry.get("long_running"))


def _truthy_background_flag(value: Any) -> bool:
    if value is True:
        return True
    if value is False or value is None:
        return False
    return str(value).strip().lower() in {"1", "true", "yes", "on"}


def _matches_dependency_install(tokens: list[str]) -> bool:
    if not tokens:
        return False
    first = _basename(tokens[0]).lower()
    second = tokens[1].lower() if len(tokens) >= 2 else ""
    third = tokens[2].lower() if len(tokens) >= 3 else ""

    if first in _NPM_LIKE:
        if first == "yarn":
            # Bare `yarn` installs; `yarn install` is explicit.
            return len(tokens) == 1 or second == "install"
        return second in {"install", "ci"}
    if first in _PIP_LIKE and second == "install":
        return True
    if first == "cargo" and second == "fetch":
        return True
    if first == "bundle" and second == "install":
        return True
    if first == "go" and second == "mod" and third == "download":
        return True
    return False


def _matches_git_mutating(tokens: list[str]) -> bool:
    if len(tokens) < 2 or _basename(tokens[0]).lower() != "git":
        return False
    # try_parse_tokens already strips git global options into rewrite_prefix,
    # so tokens[1] is the subcommand when present.
    return tokens[1].lower() in _GIT_MUTATING


def _matches_builtin_denylist(command: str) -> bool:
    """Built-in never-background shapes (ordering-sensitive or already async)."""
    text = str(command or "")
    if not text.strip():
        return False
    if _has_background(text):
        return True
    if _MIGRATE_SEED_RE.search(text) or _DEPLOY_PUBLISH_RELEASE_RE.search(text):
        return True

    parsed = try_parse_tokens(text)
    if parsed is not None:
        _cmd, tokens, _rewrite_prefix = parsed
        if _matches_dependency_install(tokens) or _matches_git_mutating(tokens):
            return True
        return False

    # Unparseable (compound/pipeline) still match install/git shapes via a
    # coarse token split so denylist safety does not depend on fingerprinting.
    rough = text.strip().split()
    if not rough:
        return False
    # Drop leading FOO=bar assignments the same way try_parse_tokens would.
    while rough and "=" in rough[0] and not rough[0].startswith("-"):
        rough = rough[1:]
    return _matches_dependency_install(rough) or _matches_git_mutating(rough)


def load_never_background_patterns(state_root: Path) -> list[re.Pattern[str]]:
    """Load operator regexes from never-background; invalid lines are skipped."""
    path = never_background_path(state_root)
    if not path.is_file():
        return []
    try:
        raw = path.read_text(encoding="utf-8")
    except OSError:
        return []
    patterns: list[re.Pattern[str]] = []
    for line in raw.splitlines():
        stripped = line.strip()
        if not stripped or stripped.startswith("#"):
            continue
        try:
            patterns.append(re.compile(stripped))
        except re.error:
            continue
    return patterns


def is_never_background(
    command: str,
    state_root: Path | None = None,
    *,
    run_in_background: Any = False,
) -> bool:
    """True when this command must never be auto-background injected.

    Recording durations is independent: denylisted commands are still observed.
    Extension point is the never-background data file, not an environment variable.
    """
    if _truthy_background_flag(run_in_background):
        return True
    if _matches_builtin_denylist(command):
        return True
    if state_root is None:
        return False
    text = str(command or "")
    for pattern in load_never_background_patterns(state_root):
        if pattern.search(text):
            return True
    return False


def is_injection_eligible(
    state_root: Path,
    fingerprint: str,
    command: str,
    *,
    run_in_background: Any = False,
) -> bool:
    """True when long_running and not denylisted — safe to inject background."""
    if not fingerprint:
        return False
    if is_never_background(
        command,
        state_root,
        run_in_background=run_in_background,
    ):
        return False
    return is_long_running(state_root, fingerprint)


def _inflight_id_path(state_root: Path, invocation_id: str) -> Path:
    return inflight_dir(state_root) / f"id.{_safe_token(invocation_id)}.json"


def _inflight_fp_prefix(fingerprint: str) -> str:
    return f"fp.{_safe_token(fingerprint)}."


def expire_stale_inflight(
    state_root: Path,
    *,
    max_age_seconds: int = INFLIGHT_MAX_AGE_SECONDS,
    now_ms: int | None = None,
) -> int:
    """Delete inflight markers older than max_age_seconds. Returns count removed."""
    directory = inflight_dir(state_root)
    if not directory.is_dir():
        return 0
    now = int(now_ms if now_ms is not None else _utc_now_ms())
    max_age_ms = max(0, int(max_age_seconds)) * 1000
    removed = 0
    try:
        entries = list(directory.iterdir())
    except OSError:
        return 0
    for path in entries:
        if not path.is_file() or path.suffix != ".json":
            continue
        try:
            data = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError, UnicodeError):
            try:
                path.unlink(missing_ok=True)
                removed += 1
            except OSError:
                pass
            continue
        started = data.get("started_at_ms") if isinstance(data, dict) else None
        try:
            started_ms = int(started)
        except (TypeError, ValueError):
            started_ms = None
        if started_ms is None or (now - started_ms) > max_age_ms:
            try:
                path.unlink(missing_ok=True)
                removed += 1
            except OSError:
                pass
    return removed


def mark_inflight_start(
    state_root: Path,
    command: str,
    invocation_id: str = "",
    *,
    fingerprint: str | None = None,
    started_at_ms: int | None = None,
) -> bool:
    """Record a start timestamp for pre/post duration pairing. Fail-open."""
    try:
        fp = (fingerprint or "").strip() or (command_fingerprint_fn(command) or "")
        if not fp:
            return False
        expire_stale_inflight(state_root)
        started = int(started_at_ms if started_at_ms is not None else _utc_now_ms())
        payload = {
            "fingerprint": fp,
            "command": str(command or ""),
            "invocation_id": str(invocation_id or ""),
            "started_at_ms": started,
            "started_at": _utc_now_iso(),
        }
        directory = inflight_dir(state_root)
        directory.mkdir(parents=True, exist_ok=True)
        inv = str(invocation_id or "").strip()
        if inv:
            path = _inflight_id_path(state_root, inv)
        else:
            # No invocation id: unique file so concurrent identical commands
            # can still pair FIFO on complete (oldest first).
            path = directory / f"{_inflight_fp_prefix(fp)}{started}.{os.getpid()}.json"
        tmp = path.with_suffix(path.suffix + ".tmp")
        tmp.write_text(json.dumps(payload, separators=(",", ":")) + "\n", encoding="utf-8")
        os.replace(tmp, path)
        return True
    except Exception:
        return False


def _read_inflight_marker(path: Path) -> dict[str, Any] | None:
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError, UnicodeError):
        return None
    if not isinstance(data, dict):
        return None
    return data


def _pop_inflight_marker(
    state_root: Path,
    *,
    invocation_id: str = "",
    fingerprint: str = "",
) -> dict[str, Any] | None:
    """Locate and delete one inflight marker. Prefer invocation_id, else oldest fp."""
    directory = inflight_dir(state_root)
    inv = str(invocation_id or "").strip()
    if inv:
        path = _inflight_id_path(state_root, inv)
        if path.is_file():
            data = _read_inflight_marker(path)
            try:
                path.unlink(missing_ok=True)
            except OSError:
                pass
            return data
        return None

    fp = str(fingerprint or "").strip()
    if not fp or not directory.is_dir():
        return None
    prefix = _inflight_fp_prefix(fp)
    candidates: list[tuple[int, Path, dict[str, Any]]] = []
    try:
        for path in directory.iterdir():
            if not path.is_file() or not path.name.startswith(prefix):
                continue
            data = _read_inflight_marker(path)
            if not data:
                continue
            try:
                started = int(data.get("started_at_ms"))
            except (TypeError, ValueError):
                continue
            candidates.append((started, path, data))
    except OSError:
        return None
    if not candidates:
        return None
    candidates.sort(key=lambda item: item[0])
    _, path, data = candidates[0]
    try:
        path.unlink(missing_ok=True)
    except OSError:
        pass
    return data


def complete_inflight(
    state_root: Path,
    *,
    invocation_id: str = "",
    fingerprint: str = "",
    command: str = "",
    ended_at_ms: int | None = None,
) -> dict[str, Any] | None:
    """Consume an inflight marker, record the elapsed duration, return the entry.

    Keys on invocation_id when the runtime supplies one (tolerates concurrent
    identical commands). Falls back to oldest fingerprint-keyed marker.
    """
    try:
        expire_stale_inflight(state_root)
        fp_hint = (fingerprint or "").strip()
        if not fp_hint and command:
            fp_hint = command_fingerprint_fn(command) or ""
        marker = _pop_inflight_marker(
            state_root,
            invocation_id=invocation_id,
            fingerprint=fp_hint,
        )
        if not marker:
            return None
        try:
            started = int(marker.get("started_at_ms"))
        except (TypeError, ValueError):
            return None
        ended = int(ended_at_ms if ended_at_ms is not None else _utc_now_ms())
        duration = max(0, ended - started)
        fp = str(marker.get("fingerprint") or fp_hint or "").strip()
        cmd = str(marker.get("command") or command or "")
        if not fp:
            return None
        return record_observation(state_root, fp, cmd, duration)
    except Exception:
        return None


def _record_cli(payload: dict[str, object]) -> int:
    """stdin JSON: state_root, fingerprint, command, duration_ms. Always exit 0."""
    try:
        state_root = Path(str(payload.get("state_root") or ""))
        fingerprint = str(payload.get("fingerprint") or "")
        command = str(payload.get("command") or "")
        duration_ms = payload.get("duration_ms")
        if not fingerprint and command:
            fingerprint = command_fingerprint_fn(command) or ""
        record_observation(state_root, fingerprint, command, duration_ms)  # type: ignore[arg-type]
    except Exception:
        pass
    return 0


def _mark_start_cli(payload: dict[str, object]) -> int:
    """stdin JSON: state_root, command, invocation_id?, fingerprint?. Always exit 0."""
    try:
        state_root = Path(str(payload.get("state_root") or ""))
        command = str(payload.get("command") or "")
        invocation_id = str(payload.get("invocation_id") or "")
        fingerprint_raw = str(payload.get("fingerprint") or "")
        fingerprint = fingerprint_raw or None
        mark_inflight_start(
            state_root,
            command,
            invocation_id,
            fingerprint=fingerprint,
        )
    except Exception:
        pass
    return 0


def _complete_cli(payload: dict[str, object]) -> int:
    """stdin JSON: state_root, invocation_id?, fingerprint?, command?. Always exit 0."""
    try:
        state_root = Path(str(payload.get("state_root") or ""))
        complete_inflight(
            state_root,
            invocation_id=str(payload.get("invocation_id") or ""),
            fingerprint=str(payload.get("fingerprint") or ""),
            command=str(payload.get("command") or ""),
        )
    except Exception:
        pass
    return 0


def _median_seconds(median_ms: Any) -> float:
    try:
        return max(0, int(median_ms)) / 1000.0
    except (TypeError, ValueError):
        return 0.0


def _format_yes_no(value: Any) -> str:
    return "yes" if value else "no"


def _cli_list(state_root: Path) -> int:
    rows = list_entries(state_root)
    if not rows:
        print("(no learned command profiles)")
        return 0
    # Header then one row per entry, longest median first.
    print(
        f"{'median_s':>8}  {'obs':>4}  {'long':<4}  {'deny':<4}  "
        f"{'fingerprint':<16}  command"
    )
    for entry in rows:
        median_s = _median_seconds(entry.get("median_ms"))
        obs = int(entry.get("observation_count") or 0)
        long_running = _format_yes_no(entry.get("long_running"))
        denylisted = _format_yes_no(entry.get("denylisted"))
        fp = str(entry.get("fingerprint") or "")
        fp_short = fp if len(fp) <= 16 else fp[:16]
        command = str(entry.get("command") or "")
        print(
            f"{median_s:8.1f}  {obs:4d}  {long_running:<4}  {denylisted:<4}  "
            f"{fp_short:<16}  {command}"
        )
    return 0


def _cli_show(state_root: Path, prefix: str) -> int:
    try:
        entry = resolve_fingerprint_prefix(state_root, prefix)
    except ValueError as exc:
        print(f"Error: {exc}", file=sys.stderr)
        return 1
    if entry is None:
        print(f"Error: no profile matches fingerprint prefix {prefix!r}", file=sys.stderr)
        return 1
    median_ms = int(entry.get("median_ms") or 0)
    print(f"fingerprint: {entry.get('fingerprint')}")
    print(f"command: {entry.get('command')}")
    print(f"observation_count: {entry.get('observation_count')}")
    print(f"median_ms: {median_ms}")
    print(f"median_s: {_median_seconds(median_ms):.1f}")
    print(f"long_running: {_format_yes_no(entry.get('long_running'))}")
    print(f"denylisted: {_format_yes_no(entry.get('denylisted'))}")
    print(f"durations_ms: {json.dumps(entry.get('durations_ms') or [])}")
    print(f"promoted_at: {entry.get('promoted_at') or ''}")
    print(f"demoted_at: {entry.get('demoted_at') or ''}")
    print(f"last_seen: {entry.get('last_seen') or ''}")
    return 0


def _cli_reset(state_root: Path, prefix: str | None) -> int:
    if prefix:
        try:
            entry = resolve_fingerprint_prefix(state_root, prefix)
        except ValueError as exc:
            print(f"Error: {exc}", file=sys.stderr)
            return 1
        if entry is None:
            print(
                f"Error: no profile matches fingerprint prefix {prefix!r}",
                file=sys.stderr,
            )
            return 1
        fp = str(entry.get("fingerprint") or "")
        if not delete_entry(state_root, fp):
            print(f"Error: failed to reset profile {fp}", file=sys.stderr)
            return 1
        print(f"Reset profile {fp}")
        return 0
    count = reset_all_entries(state_root)
    print(f"Reset all command profiles ({count} removed)")
    return 0


def main(argv: list[str] | None = None) -> int:
    args = argv if argv is not None else sys.argv[1:]
    if not args:
        print(
            "Usage: command_profiles.py record|mark-start|complete"
            "  (read JSON object on stdin)\n"
            "       command_profiles.py list <state_root>\n"
            "       command_profiles.py show <state_root> <fingerprint-prefix>\n"
            "       command_profiles.py reset <state_root> [<fingerprint-prefix>]",
            file=sys.stderr,
        )
        return 2

    action = args[0]
    if action in ("record", "mark-start", "complete"):
        if len(args) != 1:
            print(
                "Usage: command_profiles.py record|mark-start|complete"
                "  (read JSON object on stdin)",
                file=sys.stderr,
            )
            return 2
        try:
            payload = json.load(sys.stdin)
        except json.JSONDecodeError:
            return 0
        if not isinstance(payload, dict):
            return 0
        if action == "record":
            return _record_cli(payload)
        if action == "mark-start":
            return _mark_start_cli(payload)
        return _complete_cli(payload)

    if action == "list":
        if len(args) != 2:
            print("Usage: command_profiles.py list <state_root>", file=sys.stderr)
            return 2
        return _cli_list(Path(args[1]))

    if action == "show":
        if len(args) != 3:
            print(
                "Usage: command_profiles.py show <state_root> <fingerprint-prefix>",
                file=sys.stderr,
            )
            return 2
        return _cli_show(Path(args[1]), args[2])

    if action == "reset":
        if len(args) not in (2, 3):
            print(
                "Usage: command_profiles.py reset <state_root> [<fingerprint-prefix>]",
                file=sys.stderr,
            )
            return 2
        prefix = args[2] if len(args) == 3 else None
        return _cli_reset(Path(args[1]), prefix)

    print(
        "Usage: command_profiles.py record|mark-start|complete"
        "  (read JSON object on stdin)\n"
        "       command_profiles.py list <state_root>\n"
        "       command_profiles.py show <state_root> <fingerprint-prefix>\n"
        "       command_profiles.py reset <state_root> [<fingerprint-prefix>]",
        file=sys.stderr,
    )
    return 2


if __name__ == "__main__":
    raise SystemExit(main())
