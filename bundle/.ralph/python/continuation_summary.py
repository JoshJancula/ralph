#!/usr/bin/env python3
"""Ralph-owned between-TODO continuation summary state and renderer.

State lives at .ralph-workspace/sessions/<plan-key>/continuation-summary.json.
All content is derived from runner-verifiable sources only; no model-generated
summaries are invented in this module.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import sys
import tempfile
from datetime import datetime, timezone
from typing import Any

try:
    import verification_result as vr
except ModuleNotFoundError:  # pragma: no cover - direct execution
    _MODULE_DIR = os.path.dirname(os.path.abspath(__file__))
    sys.path.insert(0, _MODULE_DIR)
    import verification_result as vr

SCHEMA_VERSION = 2
SUMMARY_GENERATION_VERSION = 1

DEFAULT_MAX_COMPLETED_TODOS = 20
DEFAULT_MAX_TODO_EXCERPT_BYTES = 2048
DEFAULT_MAX_ERROR_BYTES_PER = 2048
DEFAULT_MAX_ERROR_BYTES_TOTAL = 8192
DEFAULT_MAX_HUMAN_DECISIONS = 10
DEFAULT_MAX_COMPLETION_SUMMARY_BYTES = 512
DEFAULT_RECENT_DETAIL_COUNT = 5
DEFAULT_GROUP_WINDOW = 5
DEFAULT_MAX_RENDER_BYTES = 16384

FOOTER_MARKERS = (
    "TODO_COMPLETION:",
    "AGENT_INVOCATION_COMPLETE",
    "TODO_VERIFICATION:",
    "VERIFICATION_RESULT:",
    "VERIFICATION STATUS:",
)

UNRESOLVED_VERIFICATION_STATUSES = frozenset({"fail"})


class ContinuationSummaryError(Exception):
    """Raised when state or input violates the continuation summary contract."""


def _env_bool(name: str) -> str | None:
    raw = os.environ.get(name)
    if raw is None:
        return None
    stripped = raw.strip()
    return stripped if stripped else None


def hierarchical_continuation_enabled(
    *,
    explicit: str | None = None,
    ralph_mode: str | None = None,
) -> bool:
    value = explicit if explicit is not None else _env_bool("RALPH_CONTINUATION_SUMMARY_HIERARCHICAL")
    if value is not None:
        normalized = value.lower()
        if normalized in {"1", "true", "yes", "on"}:
            return True
        if normalized in {"0", "false", "no", "off"}:
            return False
        raise ValueError(
            f"RALPH_CONTINUATION_SUMMARY_HIERARCHICAL: invalid value '{value}' (use 0 or 1)"
        )
    mode = (ralph_mode if ralph_mode is not None else os.environ.get("RALPH_MODE", "no")).lower()
    return mode in {"ralph", "hybrid"}


def _env_positive_int(name: str, default: int) -> int:
    raw = os.environ.get(name, "").strip()
    if not raw:
        return default
    try:
        value = int(raw)
    except ValueError:
        return default
    return value if value > 0 else default


def _env_group_by(default: str = "window") -> str:
    raw = os.environ.get("RALPH_CONTINUATION_SUMMARY_GROUP_BY", "").strip().lower()
    if raw in {"window", "stage"}:
        return raw
    return default


def load_limits() -> dict[str, Any]:
    return {
        "max_completed_todos": _env_positive_int(
            "RALPH_CONTINUATION_SUMMARY_MAX_COMPLETED_TODOS",
            DEFAULT_MAX_COMPLETED_TODOS,
        ),
        "max_todo_excerpt_bytes": _env_positive_int(
            "RALPH_CONTINUATION_SUMMARY_MAX_TODO_EXCERPT_BYTES",
            DEFAULT_MAX_TODO_EXCERPT_BYTES,
        ),
        "max_error_bytes_per": _env_positive_int(
            "RALPH_CONTINUATION_SUMMARY_MAX_ERROR_BYTES_PER",
            DEFAULT_MAX_ERROR_BYTES_PER,
        ),
        "max_error_bytes_total": _env_positive_int(
            "RALPH_CONTINUATION_SUMMARY_MAX_ERROR_BYTES_TOTAL",
            DEFAULT_MAX_ERROR_BYTES_TOTAL,
        ),
        "max_human_decisions": _env_positive_int(
            "RALPH_CONTINUATION_SUMMARY_MAX_HUMAN_DECISIONS",
            DEFAULT_MAX_HUMAN_DECISIONS,
        ),
        "max_completion_summary_bytes": _env_positive_int(
            "RALPH_CONTINUATION_SUMMARY_MAX_COMPLETION_SUMMARY_BYTES",
            DEFAULT_MAX_COMPLETION_SUMMARY_BYTES,
        ),
        "recent_detail_count": _env_positive_int(
            "RALPH_CONTINUATION_SUMMARY_RECENT_DETAIL_COUNT",
            DEFAULT_RECENT_DETAIL_COUNT,
        ),
        "group_window": _env_positive_int(
            "RALPH_CONTINUATION_SUMMARY_GROUP_WINDOW",
            DEFAULT_GROUP_WINDOW,
        ),
        "group_by": _env_group_by(),
        "max_render_bytes": _env_positive_int(
            "RALPH_CONTINUATION_SUMMARY_MAX_RENDER_BYTES",
            DEFAULT_MAX_RENDER_BYTES,
        ),
    }


def plan_fingerprint(plan_path: str) -> str:
    digest = hashlib.sha256()
    with open(plan_path, "rb") as handle:
        while True:
            chunk = handle.read(65536)
            if not chunk:
                break
            digest.update(chunk)
    return digest.hexdigest()


def _utc_now() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def _bounded_text(text: str, max_bytes: int) -> tuple[str, bool]:
    encoded = text.encode("utf-8")
    if len(encoded) <= max_bytes:
        return text, False
    truncated = encoded[:max_bytes].decode("utf-8", errors="ignore")
    return truncated, True


def _empty_state(plan_key: str, plan_path: str, fingerprint: str) -> dict[str, Any]:
    return {
        "schema_version": SCHEMA_VERSION,
        "summary_generation_version": SUMMARY_GENERATION_VERSION,
        "plan_key": plan_key,
        "plan_path": plan_path,
        "plan_fingerprint": fingerprint,
        "completed_todos": [],
        "verification_outcomes": [],
        "output_artifacts": [],
        "recent_errors": [],
        "human_decisions": [],
        "next_todo": None,
        "stats": {
            "truncation_count": 0,
            "completed_entry_count": 0,
        },
    }


def _read_json(path: str) -> dict[str, Any] | None:
    if not os.path.isfile(path):
        return None
    with open(path, encoding="utf-8") as handle:
        raw = handle.read()
    if not raw.strip():
        return None
    doc = json.loads(raw)
    if not isinstance(doc, dict):
        raise ContinuationSummaryError(f"state root must be an object: {path}")
    return doc


def _validate_state_types(state: dict[str, Any]) -> None:
    required_lists = (
        "completed_todos",
        "verification_outcomes",
        "output_artifacts",
        "recent_errors",
        "human_decisions",
    )
    for key in required_lists:
        value = state.get(key)
        if value is not None and not isinstance(value, list):
            raise ContinuationSummaryError(f"{key} must be a list")
    next_todo = state.get("next_todo")
    if next_todo is not None and not isinstance(next_todo, dict):
        raise ContinuationSummaryError("next_todo must be an object or null")


def migrate_state(state: dict[str, Any]) -> dict[str, Any]:
    version = int(state.get("schema_version", 1) or 1)
    if version > SCHEMA_VERSION:
        raise ContinuationSummaryError(
            f"unsupported continuation summary schema_version {version}"
        )
    if version < SCHEMA_VERSION:
        state["schema_version"] = SCHEMA_VERSION
    state.setdefault("summary_generation_version", SUMMARY_GENERATION_VERSION)
    state.setdefault(
        "stats",
        {"truncation_count": 0, "completed_entry_count": len(state.get("completed_todos") or [])},
    )
    return state


def write_state_atomic(path: str, state: dict[str, Any]) -> None:
    state = migrate_state(dict(state))
    _validate_state_types(state)
    directory = os.path.dirname(path) or "."
    os.makedirs(directory, exist_ok=True)
    fd, tmp_path = tempfile.mkstemp(prefix=".continuation-summary.", dir=directory)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            json.dump(state, handle, indent=2, sort_keys=True)
            handle.write("\n")
        os.replace(tmp_path, path)
    finally:
        if os.path.exists(tmp_path):
            os.unlink(tmp_path)


def ensure_plan_state(
    state_path: str,
    plan_key: str,
    plan_path: str,
    *,
    enabled: bool = True,
) -> dict[str, Any]:
    if not enabled:
        return _empty_state(plan_key, plan_path, plan_fingerprint(plan_path))

    fingerprint = plan_fingerprint(plan_path)
    existing = _read_json(state_path)
    if existing is None:
        return _empty_state(plan_key, plan_path, fingerprint)

    _validate_state_types(existing)
    if (
        existing.get("plan_key") != plan_key
        or existing.get("plan_path") != plan_path
        or existing.get("plan_fingerprint") != fingerprint
    ):
        return _empty_state(plan_key, plan_path, fingerprint)
    return migrate_state(existing)


def extract_completion_summary(text: str, max_bytes: int) -> str:
    lines = text.splitlines()
    footer_index = len(lines)
    for index in range(len(lines) - 1, -1, -1):
        stripped = lines[index].strip().lstrip("*-")
        if any(stripped.startswith(marker) for marker in FOOTER_MARKERS):
            footer_index = index
    body_lines: list[str] = []
    for line in lines[:footer_index]:
        if line.strip():
            body_lines.append(line.rstrip())
    if not body_lines:
        return ""
    summary = body_lines[-1].strip()
    if len(body_lines) >= 2 and len(summary) < 40:
        summary = body_lines[-2].strip()
    bounded, _ = _bounded_text(summary, max_bytes)
    return bounded


def _append_error(
    state: dict[str, Any],
    *,
    todo_line: int,
    text: str,
    source: str,
    limits: dict[str, Any],
) -> None:
    if not text.strip():
        return
    bounded, per_trunc = _bounded_text(text, limits["max_error_bytes_per"])
    entry = {
        "todo_line": todo_line,
        "text": bounded,
        "source": source,
        "truncated": per_trunc,
    }
    errors = list(state.get("recent_errors") or [])
    errors.append(entry)
    total = 0
    trimmed: list[dict[str, Any]] = []
    total_trunc = bool(state.get("stats", {}).get("truncation_count", 0))
    for item in reversed(errors):
        item_bytes = len(str(item.get("text", "")).encode("utf-8"))
        if total + item_bytes > limits["max_error_bytes_total"]:
            total_trunc = True
            state.setdefault("stats", {})["truncation_count"] = int(
                state.get("stats", {}).get("truncation_count", 0)
            ) + 1
            continue
        total += item_bytes
        trimmed.insert(0, item)
    if per_trunc:
        state.setdefault("stats", {})["truncation_count"] = int(
            state.get("stats", {}).get("truncation_count", 0)
        ) + 1
    state["recent_errors"] = trimmed


def _append_human_decision(state: dict[str, Any], entry: dict[str, Any], limits: dict[str, Any]) -> None:
    decisions = list(state.get("human_decisions") or [])
    decisions.append(entry)
    if len(decisions) > limits["max_human_decisions"]:
        drop = len(decisions) - limits["max_human_decisions"]
        decisions = decisions[drop:]
        state.setdefault("stats", {})["truncation_count"] = int(
            state.get("stats", {}).get("truncation_count", 0)
        ) + drop
    state["human_decisions"] = decisions


def update_state(
    state_path: str,
    payload: dict[str, Any],
    *,
    enabled: bool = True,
) -> dict[str, Any]:
    if not enabled:
        return {"written": False, "state": None}

    limits = load_limits()
    plan_key = str(payload.get("plan_key", ""))
    plan_path = str(payload.get("plan_path", ""))
    if not plan_key or not plan_path:
        raise ContinuationSummaryError("plan_key and plan_path are required")

    state = ensure_plan_state(state_path, plan_key, plan_path, enabled=True)
    stats = state.setdefault("stats", {"truncation_count": 0, "completed_entry_count": 0})

    if payload.get("record_error"):
        error = payload["record_error"]
        _append_error(
            state,
            todo_line=int(error.get("todo_line", 0)),
            text=str(error.get("text", "")),
            source=str(error.get("source", "verification")),
            limits=limits,
        )
        write_state_atomic(state_path, state)
        return {"written": True, "state": state}

    completed = payload.get("completed_todo")
    if isinstance(completed, dict):
        content = str(completed.get("content", ""))
        excerpt, content_trunc = _bounded_text(content, limits["max_todo_excerpt_bytes"])
        summary = str(completed.get("completion_summary", ""))
        summary, summary_trunc = _bounded_text(summary, limits["max_completion_summary_bytes"])
        if content_trunc or summary_trunc:
            stats["truncation_count"] = int(stats.get("truncation_count", 0)) + int(content_trunc) + int(summary_trunc)

        entry = {
            "id": str(completed.get("id", "")),
            "ordinal": int(completed.get("ordinal", 0) or 0),
            "line": int(completed.get("line", 0) or 0),
            "hash": str(completed.get("hash", "")),
            "content": excerpt,
            "content_truncated": content_trunc,
            "completed_at": str(completed.get("completed_at") or _utc_now()),
            "completion_summary": summary,
        }
        stage_id = str(completed.get("stage_id", "") or payload.get("stage_id", "")).strip()
        if stage_id:
            entry["stage_id"] = stage_id

        completed_list = list(state.get("completed_todos") or [])
        completed_list.append(entry)
        if len(completed_list) > limits["max_completed_todos"]:
            drop = len(completed_list) - limits["max_completed_todos"]
            completed_list = completed_list[drop:]
            stats["truncation_count"] = int(stats.get("truncation_count", 0)) + drop
        state["completed_todos"] = completed_list
        stats["completed_entry_count"] = len(completed_list)

        verification = payload.get("verification")
        if isinstance(verification, dict):
            state.setdefault("verification_outcomes", []).append(
                {
                    "todo_line": entry["line"],
                    "status": str(verification.get("status", "none")),
                    "reason": str(verification.get("reason", "")),
                    "artifact_path": str(verification.get("artifact_path", "")),
                }
            )

        artifacts = payload.get("output_artifacts")
        if isinstance(artifacts, list) and artifacts:
            state.setdefault("output_artifacts", []).append(
                {
                    "todo_line": entry["line"],
                    "paths": [str(path) for path in artifacts if str(path).strip()],
                }
            )

    human = payload.get("human_decision")
    if isinstance(human, dict) and human:
        _append_human_decision(state, human, limits)

    next_todo = payload.get("next_todo")
    if isinstance(next_todo, dict):
        excerpt, trunc = _bounded_text(str(next_todo.get("content", "")), limits["max_todo_excerpt_bytes"])
        if trunc:
            stats["truncation_count"] = int(stats.get("truncation_count", 0)) + 1
        state["next_todo"] = {
            "line": int(next_todo.get("line", 0) or 0),
            "ordinal": int(next_todo.get("ordinal", 0) or 0),
            "id": str(next_todo.get("id", "")),
            "content_excerpt": excerpt,
            "content_truncated": trunc,
        }
    elif payload.get("clear_next_todo"):
        state["next_todo"] = None

    write_state_atomic(state_path, state)
    return {"written": True, "state": state}


def _entry_sort_key(entry: dict[str, Any]) -> tuple[int, int]:
    ordinal = int(entry.get("ordinal", 0) or 0)
    line = int(entry.get("line", 0) or 0)
    return (ordinal if ordinal > 0 else line, line)


def _sort_completed(completed: list[dict[str, Any]]) -> list[dict[str, Any]]:
    return sorted(completed, key=_entry_sort_key)


def _index_by_todo_line(items: list[dict[str, Any]]) -> dict[int, list[dict[str, Any]]]:
    indexed: dict[int, list[dict[str, Any]]] = {}
    for item in items:
        line = int(item.get("todo_line", 0) or 0)
        if line <= 0:
            continue
        indexed.setdefault(line, []).append(item)
    return indexed


def _verification_for_line(
    verifications_by_line: dict[int, list[dict[str, Any]]],
    line: int,
) -> dict[str, Any] | None:
    items = verifications_by_line.get(line) or []
    if not items:
        return None
    return items[-1]


def _is_unresolved_verification(status: str) -> bool:
    return status.strip().lower() in UNRESOLVED_VERIFICATION_STATUSES


def _format_verification(item: dict[str, Any]) -> str:
    status = item.get("status", "none")
    todo_line = item.get("todo_line", "?")
    reason = str(item.get("reason", "")).strip()
    detail = f"line {todo_line}: {status}"
    if reason:
        detail += f" ({reason})"
    return detail


def _render_entry_detail(entry: dict[str, Any]) -> list[str]:
    lines: list[str] = []
    label_parts = []
    if entry.get("ordinal"):
        label_parts.append(f"#{entry['ordinal']}")
    if entry.get("line"):
        label_parts.append(f"line {entry['line']}")
    if entry.get("id"):
        label_parts.append(f"id {entry['id']}")
    label = " ".join(label_parts) if label_parts else "TODO"
    lines.append(f"- **{label}**")
    content = str(entry.get("content", "")).strip()
    if content:
        lines.append(f"  - Task: {content}")
        if entry.get("content_truncated"):
            lines.append("  - Task excerpt truncated")
    summary = str(entry.get("completion_summary", "")).strip()
    if summary:
        lines.append(f"  - Summary: {summary}")
    return lines


def _window_group_key(entry: dict[str, Any], group_window: int) -> int:
    ordinal = int(entry.get("ordinal", 0) or 0)
    if ordinal > 0:
        return (ordinal - 1) // group_window
    line = int(entry.get("line", 0) or 0)
    if line > 0:
        return (line - 1) // group_window
    return 0


def _group_label(group_key: int, group_by: str, stage_id: str, group_window: int) -> str:
    if group_by == "stage":
        label = stage_id if stage_id else "(no stage)"
        return f"stage {label}"
    start = group_key * group_window + 1
    end = (group_key + 1) * group_window
    return f"TODOs #{start}-#{end} (window)"


def build_consolidated_groups(
    completed: list[dict[str, Any]],
    *,
    verifications: list[dict[str, Any]],
    artifacts: list[dict[str, Any]],
    human_decisions: list[dict[str, Any]],
    limits: dict[str, Any],
) -> list[dict[str, Any]]:
    recent_count = int(limits["recent_detail_count"])
    sorted_entries = _sort_completed(completed)
    if len(sorted_entries) <= recent_count:
        return []

    older = sorted_entries[: len(sorted_entries) - recent_count]
    verifications_by_line = _index_by_todo_line(verifications)
    artifacts_by_line = _index_by_todo_line(artifacts)
    decisions_by_line = _index_by_todo_line(human_decisions)

    grouped: dict[tuple[str, int | str], list[dict[str, Any]]] = {}
    group_by = str(limits["group_by"])
    group_window = int(limits["group_window"])

    for entry in older:
        if group_by == "stage":
            stage_id = str(entry.get("stage_id", "") or "")
            key: tuple[str, int | str] = ("stage", stage_id)
        else:
            key = ("window", _window_group_key(entry, group_window))
        grouped.setdefault(key, []).append(entry)

    groups: list[dict[str, Any]] = []
    for key in sorted(grouped, key=lambda item: (item[0], str(item[1]))):
        kind, group_key = key
        entries = _sort_completed(grouped[key])
        lines = [entry.get("line", 0) for entry in entries]
        ordinals = [entry.get("ordinal", 0) for entry in entries if entry.get("ordinal")]
        ids = [str(entry.get("id", "")) for entry in entries if entry.get("id")]
        stage_id = str(entries[0].get("stage_id", "") or "") if kind == "stage" else ""
        label = _group_label(int(group_key) if kind == "window" else 0, group_by, stage_id, group_window)

        verification_items: list[str] = []
        artifact_paths: list[str] = []
        unresolved: list[str] = []
        group_decisions: list[str] = []

        for entry in entries:
            line = int(entry.get("line", 0) or 0)
            verification = _verification_for_line(verifications_by_line, line)
            if verification:
                verification_items.append(_format_verification(verification))
                if _is_unresolved_verification(str(verification.get("status", ""))):
                    unresolved.append(_format_verification(verification))
            for artifact_group in artifacts_by_line.get(line, []):
                for path in artifact_group.get("paths") or []:
                    path_text = str(path).strip()
                    if path_text and path_text not in artifact_paths:
                        artifact_paths.append(path_text)
            for decision in decisions_by_line.get(line, []):
                question = str(decision.get("question", "")).strip()
                response = str(decision.get("response", "")).strip()
                if question or response:
                    group_decisions.append(f"line {line}: Q={question} A={response}")

        groups.append(
            {
                "label": label,
                "kind": kind,
                "entries": entries,
                "ids": ids,
                "lines": lines,
                "ordinals": ordinals,
                "verification_items": verification_items,
                "artifact_paths": artifact_paths,
                "unresolved": unresolved,
                "human_decisions": group_decisions,
            }
        )
    return groups


def _render_group(group: dict[str, Any]) -> list[str]:
    lines = [f"### Consolidated {group['label']}"]
    count = len(group.get("entries") or [])
    lines.append(f"- Completed: {count}")
    ids = group.get("ids") or []
    if ids:
        lines.append(f"- IDs: {', '.join(ids)}")
    todo_lines = group.get("lines") or []
    if todo_lines:
        lines.append(f"- Lines: {', '.join(str(line) for line in todo_lines)}")
    verification_items = group.get("verification_items") or []
    if verification_items:
        lines.append(f"- Verification: {'; '.join(verification_items)}")
    artifact_paths = group.get("artifact_paths") or []
    if artifact_paths:
        lines.append("- Artifacts:")
        for path in artifact_paths:
            lines.append(f"  - `{path}`")
    group_decisions = group.get("human_decisions") or []
    if group_decisions:
        lines.append("- Human decisions:")
        for item in group_decisions:
            lines.append(f"  - {item}")
    return lines


def _render_verification_section(verifications: list[dict[str, Any]]) -> list[str]:
    lines: list[str] = []
    if not verifications:
        return lines
    lines.append("")
    lines.append("Verification outcomes:")
    for item in verifications:
        lines.append(f"- {_format_verification(item)}")
        artifact = str(item.get("artifact_path", "")).strip()
        if artifact:
            lines.append(f"  - Artifact: `{artifact}`")
    return lines


def _render_artifacts_section(artifacts: list[dict[str, Any]]) -> list[str]:
    lines: list[str] = []
    if not artifacts:
        return lines
    lines.append("")
    lines.append("Output artifacts:")
    for group in artifacts:
        todo_line = group.get("todo_line", "?")
        for path in group.get("paths") or []:
            lines.append(f"- line {todo_line}: `{path}`")
    return lines


def _render_errors_section(errors: list[dict[str, Any]]) -> list[str]:
    lines: list[str] = []
    if not errors:
        return lines
    lines.append("")
    lines.append("Recent errors (bounded, verbatim):")
    for err in errors:
        text = str(err.get("text", ""))
        source = str(err.get("source", ""))
        lines.append(f"- line {err.get('todo_line', '?')} [{source}]: {text}")
        if err.get("truncated"):
            lines.append("  - Error text truncated")
    return lines


def _render_decisions_section(decisions: list[dict[str, Any]]) -> list[str]:
    lines: list[str] = []
    if not decisions:
        return lines
    lines.append("")
    lines.append("Human decisions:")
    for decision in decisions:
        todo_line = decision.get("todo_line", "?")
        question = str(decision.get("question", "")).strip()
        response = str(decision.get("response", "")).strip()
        if question:
            lines.append(f"- line {todo_line} Q: {question}")
        if response:
            lines.append(f"  - A: {response}")
    return lines


def _render_next_todo(next_todo: dict[str, Any] | None) -> list[str]:
    if not isinstance(next_todo, dict):
        return []
    lines = ["", "Next action:"]
    parts = []
    if next_todo.get("ordinal"):
        parts.append(f"#{next_todo['ordinal']}")
    if next_todo.get("line"):
        parts.append(f"line {next_todo['line']}")
    if next_todo.get("id"):
        parts.append(f"id {next_todo['id']}")
    label = " ".join(parts) if parts else "next TODO"
    excerpt = str(next_todo.get("content_excerpt", "")).strip()
    lines.append(f"- {label}: {excerpt}")
    if next_todo.get("content_truncated"):
        lines.append("  - Next-task excerpt truncated")
    return lines


def _collect_unresolved_verifications(verifications: list[dict[str, Any]]) -> list[dict[str, Any]]:
    return [
        item
        for item in verifications
        if _is_unresolved_verification(str(item.get("status", "")))
    ]


def _render_unresolved_section(unresolved: list[dict[str, Any]]) -> list[str]:
    if not unresolved:
        return []
    lines = ["", "Unresolved verification failures:"]
    for item in unresolved:
        lines.append(f"- {_format_verification(item)}")
        artifact = str(item.get("artifact_path", "")).strip()
        if artifact:
            lines.append(f"  - Artifact: `{artifact}`")
    return lines


def _apply_render_byte_limit(
    sections: dict[str, Any],
    *,
    max_bytes: int,
) -> tuple[list[str], list[str]]:
    """Return rendered lines and omission notes under max_bytes."""
    omission_notes: list[str] = []

    def flatten(keys: list[str]) -> list[str]:
        lines: list[str] = []
        for key in keys:
            block = sections.get(key)
            if not block:
                continue
            if key == "groups":
                group_blocks: list[list[str]] = block
                for group_lines in group_blocks:
                    if lines and group_lines:
                        lines.append("")
                    lines.extend(group_lines)
                continue
            if lines and block and block[0] != "":
                lines.append("")
            lines.extend(block)
        return lines

    def body_bytes(keys: list[str]) -> int:
        text = "\n".join(flatten(keys)).rstrip()
        if text:
            text += "\n"
        return len(text.encode("utf-8"))

    render_keys = ["header", "groups", "recent", "unresolved", "errors", "decisions", "next"]
    if body_bytes(render_keys) <= max_bytes:
        return flatten(["header"] + render_keys[1:]), omission_notes

    group_blocks = list(sections.get("groups") or [])
    recent = list(sections.get("recent") or [])
    dropped_groups: list[str] = []

    while group_blocks:
        sections["groups"] = group_blocks
        sections["recent"] = recent
        if body_bytes(render_keys) <= max_bytes:
            break
        removed = group_blocks.pop(0)
        label = ""
        for line in removed:
            if line.startswith("### Consolidated "):
                label = line.replace("### Consolidated ", "")
                break
        dropped_groups.append(label or "group")

    trimmed_summaries = 0
    sections["groups"] = group_blocks
    sections["recent"] = recent
    if body_bytes(render_keys) > max_bytes:
        compact_recent: list[str] = []
        for line in recent:
            if line.strip().startswith("- Summary:"):
                trimmed_summaries += 1
                continue
            compact_recent.append(line)
        recent = compact_recent
        sections["recent"] = recent

    if body_bytes(render_keys) > max_bytes:
        kept: list[str] = []
        for line in recent:
            if line.startswith("- **") or line.startswith("  - Task:"):
                kept.append(line)
        dropped_detail = max(0, len(recent) - len(kept))
        if dropped_detail:
            omission_notes.append(f"{dropped_detail} recent detail line(s)")
        recent = kept
        sections["recent"] = recent

    if dropped_groups:
        omission_notes.append(f"{len(dropped_groups)} consolidated group(s) ({', '.join(dropped_groups)})")
    if trimmed_summaries:
        omission_notes.append(f"{trimmed_summaries} recent completion summary line(s)")

    lines = flatten(["header"] + render_keys[1:])
    if omission_notes:
        lines.extend(
            [
                "",
                f"Omitted from this summary (byte limit {max_bytes}):",
            ]
        )
        for note in omission_notes:
            lines.append(f"- {note}")
    return lines, omission_notes


def render_markdown(state: dict[str, Any] | None) -> str:
    if not state:
        return ""
    state = migrate_state(dict(state))
    completed = state.get("completed_todos") or []
    if not completed:
        return ""

    limits = load_limits()
    verifications = state.get("verification_outcomes") or []
    artifacts = state.get("output_artifacts") or []
    errors = state.get("recent_errors") or []
    decisions = state.get("human_decisions") or []
    next_todo = state.get("next_todo")

    if not hierarchical_continuation_enabled():
        lines = ["## Continuation summary", ""]
        lines.append("Completed work (runner-verified, deterministic):")
        lines.append("")
        for entry in completed:
            lines.extend(_render_entry_detail(entry))
        lines.extend(_render_verification_section(verifications))
        lines.extend(_render_artifacts_section(artifacts))
        lines.extend(_render_errors_section(errors))
        lines.extend(_render_decisions_section(decisions))
        lines.extend(_render_next_todo(next_todo if isinstance(next_todo, dict) else None))
        return "\n".join(lines).rstrip() + "\n"

    sorted_entries = _sort_completed(completed)
    recent_count = int(limits["recent_detail_count"])
    recent_entries = sorted_entries[-recent_count:] if recent_count > 0 else []
    groups = build_consolidated_groups(
        completed,
        verifications=verifications,
        artifacts=artifacts,
        human_decisions=decisions,
        limits=limits,
    )

    header = [
        "## Continuation summary",
        "",
        "Completed work (runner-verified, deterministic):",
        "",
    ]
    if groups:
        header.append("Consolidated earlier work:")
        header.append("")

    group_blocks = [_render_group(group) for group in groups]

    recent_lines: list[str] = []
    if recent_entries:
        recent_lines.append("Recent completed work (detailed):")
        recent_lines.append("")
        for entry in recent_entries:
            recent_lines.extend(_render_entry_detail(entry))
            line = int(entry.get("line", 0) or 0)
            verification = _verification_for_line(_index_by_todo_line(verifications), line)
            if verification:
                recent_lines.append(f"  - Verification: {_format_verification(verification)}")
            artifact_groups = _index_by_todo_line(artifacts).get(line, [])
            for artifact_group in artifact_groups:
                for path in artifact_group.get("paths") or []:
                    recent_lines.append(f"  - Artifact: `{path}`")

    unresolved = _collect_unresolved_verifications(verifications)
    sections = {
        "header": header,
        "groups": group_blocks,
        "recent": recent_lines,
        "unresolved": _render_unresolved_section(unresolved),
        "errors": _render_errors_section(errors),
        "decisions": _render_decisions_section(decisions),
        "next": _render_next_todo(next_todo if isinstance(next_todo, dict) else None),
    }
    lines, _ = _apply_render_byte_limit(sections, max_bytes=int(limits["max_render_bytes"]))
    return "\n".join(lines).rstrip() + "\n"


def rebuild_markdown(state: dict[str, Any]) -> str:
    """Deterministic render from source state; repairs stale derived fields."""
    migrated = migrate_state(dict(state))
    return render_markdown(migrated)


def metrics_from_state(state: dict[str, Any] | None, rendered: str) -> dict[str, int]:
    stats = (state or {}).get("stats") or {}
    return {
        "continuation_summary_bytes": len(rendered.encode("utf-8")),
        "continuation_summary_entry_count": int(stats.get("completed_entry_count", 0)),
        "continuation_summary_truncation_count": int(stats.get("truncation_count", 0)),
    }


def load_human_decision(session_dir: str, todo_line: int) -> dict[str, Any] | None:
    request_path = os.path.join(session_dir, "human-request.json")
    response_path = os.path.join(session_dir, "operator-response.txt")
    if not os.path.isfile(request_path):
        return None
    try:
        request = json.loads(open(request_path, encoding="utf-8").read())
    except (OSError, json.JSONDecodeError):
        return None
    question = str(request.get("question", "")).strip()
    response = ""
    if os.path.isfile(response_path):
        raw = open(response_path, encoding="utf-8").read().strip()
        if raw:
            try:
                parsed = json.loads(raw)
                if isinstance(parsed, dict):
                    response = str(parsed.get("answer") or parsed.get("decision") or parsed.get("response") or "")
                else:
                    response = raw
            except json.JSONDecodeError:
                response = raw
    if not question and not response:
        return None
    return {
        "todo_line": todo_line,
        "kind": str(request.get("kind", "guidance")),
        "question": question,
        "response": response,
    }


def collect_output_artifact_paths(
    plan_path: str,
    todo_target: str,
    workspace: str,
    artifact_entries_fn: Any | None = None,
) -> list[str]:
    if artifact_entries_fn is None:
        return []
    paths: list[str] = []
    for required_flag, raw_path in artifact_entries_fn(plan_path, todo_target, "produces"):
        if not raw_path:
            continue
        resolved = raw_path
        abs_path = resolved if os.path.isabs(resolved) else os.path.join(workspace, resolved)
        if os.path.isfile(abs_path) and os.path.getsize(abs_path) > 0:
            paths.append(resolved)
        elif required_flag:
            paths.append(resolved)
    return paths


def main() -> int:
    parser = argparse.ArgumentParser(description="Continuation summary state helper")
    sub = parser.add_subparsers(dest="command", required=True)

    check = sub.add_parser("check-plan")
    check.add_argument("--state", required=True)
    check.add_argument("--plan-path", required=True)
    check.add_argument("--plan-key", required=True)
    check.add_argument("--write", action="store_true")

    render = sub.add_parser("render")
    render.add_argument("--state", required=True)

    rebuild = sub.add_parser("rebuild")
    rebuild.add_argument("--state", required=True)
    rebuild.add_argument("--write", action="store_true")

    update = sub.add_parser("update")
    update.add_argument("--state", required=True)
    update.add_argument("--input", required=True)

    metrics = sub.add_parser("metrics")
    metrics.add_argument("--state", required=True)

    extract = sub.add_parser("extract-summary")
    extract.add_argument("--max-bytes", type=int, default=DEFAULT_MAX_COMPLETION_SUMMARY_BYTES)

    args = parser.parse_args()

    if args.command == "check-plan":
        state = ensure_plan_state(args.state, args.plan_key, args.plan_path, enabled=True)
        if args.write:
            write_state_atomic(args.state, state)
        print(json.dumps({"ok": True, "completed": len(state.get("completed_todos") or [])}))
        return 0

    if args.command == "render":
        state = _read_json(args.state)
        block = render_markdown(state)
        sys.stdout.write(block)
        return 0

    if args.command == "rebuild":
        state = _read_json(args.state)
        if state is None:
            raise ContinuationSummaryError(f"state not found: {args.state}")
        migrated = migrate_state(state)
        block = rebuild_markdown(migrated)
        if args.write:
            write_state_atomic(args.state, migrated)
        sys.stdout.write(block)
        return 0

    if args.command == "update":
        payload = json.loads(open(args.input, encoding="utf-8").read())
        result = update_state(args.state, payload, enabled=True)
        print(json.dumps({"written": result["written"]}))
        return 0

    if args.command == "metrics":
        state = _read_json(args.state)
        block = render_markdown(state)
        print(json.dumps(metrics_from_state(state, block)))
        return 0

    if args.command == "extract-summary":
        text = sys.stdin.read()
        limits = load_limits()
        max_bytes = args.max_bytes if args.max_bytes > 0 else limits["max_completion_summary_bytes"]
        print(extract_completion_summary(text, max_bytes))
        return 0

    return 2


if __name__ == "__main__":
    raise SystemExit(main())
