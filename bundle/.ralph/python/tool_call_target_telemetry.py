#!/usr/bin/env python3
"""Lightweight tool target telemetry for run-plan usage accounting."""

from __future__ import annotations

import hashlib
import os
import re
import sys
from pathlib import Path
from typing import Any, Dict, List, Mapping, Optional, Sequence, Tuple

from tool_call_classification import classify_tool_calls

sys.path.insert(0, os.path.dirname(__file__))
from result_windowing_metrics import (  # noqa: E402
    analyze_result_windowing_log,
    stored_result_readback_guidance,
)

_TARGET_MAX_LEN = 200
_TOOL_TARGETS_CAP = 50000
_PLAN_FILE_MARKER = ".ralph-workspace/plans/"

_NESTED_INPUT_KEYS = ("args", "input", "arguments", "params", "state")

_GENERIC_TARGET_KEYS = (
    "path",
    "file_path",
    "filePath",
    "pattern",
    "globPattern",
    "glob",
    "query",
    "command",
    "url",
    "description",
)

_READ_TOOL_EXACT = frozenset(
    {
        "read",
        "read_file",
        "readfile",
        "read_file_v2",
        "resources/read",
        "ralph_proxy_read",
        "ralph_proxy_result_read",
        "notebookread",
    }
)
_READ_TOOL_SUFFIXES = ("read", "view")
_SEARCH_TOOL_EXACT = frozenset(
    {
        "grep",
        "glob",
        "codebase_search",
        "semanticsearch",
        "semsearch",
        "file_search",
        "list_dir",
        "listdir",
        "ls",
        "ralph_proxy_grep",
        "ralph_proxy_glob",
        "ralph_proxy_search",
        "ralph_proxy_result_search",
    }
)
_SHELL_TOOL_EXACT = frozenset(
    {
        "bash",
        "shell",
        "exec",
        "run_terminal_cmd",
        "run_command",
        "execute_command",
        "shell_command",
        "command",
        "ralph_proxy_shell",
        "ralph_proxy_shell_start",
        "ralph_proxy_shell_wait",
    }
)
_WRITE_TOOL_EXACT = frozenset(
    {
        "write",
        "write_file",
        "create_file",
        "edit",
        "multiedit",
        "apply_patch",
        "applypatch",
        "str_replace",
        "strreplace",
        "ralph_proxy_write",
    }
)

_TELEMETRY_COUNTERS = (
    "adjacent_duplicate_tool_calls",
    "repeated_read_targets",
    "repeated_read_extra_calls",
    "plan_file_read_calls",
)


def init_tool_target_telemetry() -> Dict[str, Any]:
    return {
        "tool_call_targets": [],
        "_telemetry_entries": [],
        "adjacent_duplicate_tool_calls": 0,
        "repeated_read_targets": 0,
        "repeated_read_extra_calls": 0,
        "plan_file_read_calls": 0,
    }


def _safe_str(value: Any) -> str:
    if value is None:
        return ""
    return str(value)


def _truncate(text: str, limit: int = _TARGET_MAX_LEN) -> str:
    text = text.strip()
    if len(text) <= limit:
        return text
    return text[: max(0, limit - 3)].rstrip() + "..."


def _normalize_slashes(text: str) -> str:
    return re.sub(r"/+", "/", text.replace("\\", "/"))


def _display_path(value: str) -> str:
    text = _normalize_slashes(value.strip())
    if not text:
        return ""
    cwd = os.getcwd().rstrip(os.sep) + os.sep
    if text.startswith(cwd):
        return text[len(cwd) :]
    return text


def _command_hash(command: str) -> str:
    return hashlib.sha256(command.encode("utf-8")).hexdigest()


def _iter_input_candidates(tool_input: Mapping[str, Any]) -> List[Mapping[str, Any]]:
    out: List[Mapping[str, Any]] = []
    queue: List[Tuple[Mapping[str, Any], int]] = [(tool_input, 0)]
    while queue:
        current, depth = queue.pop(0)
        out.append(current)
        if depth >= 3:
            continue
        for key in _NESTED_INPUT_KEYS:
            nested = current.get(key)
            if isinstance(nested, Mapping):
                queue.append((nested, depth + 1))
    return out


def extract_tool_input(item: Mapping[str, Any]) -> Dict[str, Any]:
    """Best-effort extraction of tool arguments from a stream event fragment."""
    if not isinstance(item, Mapping):
        return {}
    for key in ("input", "arguments", "params"):
        value = item.get(key)
        if isinstance(value, Mapping):
            return dict(value)
    for key in _NESTED_INPUT_KEYS:
        value = item.get(key)
        if isinstance(value, Mapping):
            return dict(value)
    state = item.get("state")
    if isinstance(state, Mapping):
        for key in ("input", "arguments", "params"):
            nested = state.get(key)
            if isinstance(nested, Mapping):
                return dict(nested)
    return {key: value for key, value in item.items() if key not in {"result", "error", "failure"}}


def _first_arg_value(candidates: List[Mapping[str, Any]], keys: Tuple[str, ...]) -> str:
    for candidate in candidates:
        for key in keys:
            value = candidate.get(key)
            if isinstance(value, str) and value.strip():
                return value.strip()
    return ""


def _read_window_suffix(tool_input: Mapping[str, Any]) -> str:
    candidates = _iter_input_candidates(tool_input)
    parts: List[str] = []
    for key in ("offset", "byteStart", "lineStart"):
        raw = _first_arg_value(candidates, (key,))
        if raw:
            parts.append(f"{key.lower()}={raw}")
            break
    for key in ("limit", "byteEnd", "lineLimit"):
        raw = _first_arg_value(candidates, (key,))
        if raw:
            parts.append(f"{key.lower()}={raw}")
            break
    if not parts:
        return ""
    return ":" + ":".join(parts)


def sanitize_target(tool_name: str, tool_input: Optional[Mapping[str, Any]] = None) -> str:
    """Return a compact target string; never emit large argument blobs."""
    if not isinstance(tool_input, Mapping) or not tool_input:
        return ""

    candidates = _iter_input_candidates(tool_input)
    lower = (tool_name or "").strip().lower()

    for key in ("path", "file_path", "filePath"):
        value = _first_arg_value(candidates, (key,))
        if value:
            target = _display_path(value)
            if lower.endswith("read") or "read" in lower or lower in _READ_TOOL_EXACT:
                target += _read_window_suffix(tool_input)
            return _truncate(target)

    for key in ("pattern", "globPattern", "glob", "query", "url"):
        value = _first_arg_value(candidates, (key,))
        if value:
            return _truncate(value)

    command = _first_arg_value(candidates, ("command",))
    if command:
        return f"sha256:{_command_hash(command)}"

    description = _first_arg_value(candidates, ("description",))
    if description:
        return _truncate(description)

    return ""


def tool_family(tool_name: str) -> str:
    lower = (tool_name or "").strip().lower()
    if not lower:
        return "other"
    if lower.startswith("ralph_proxy_") or "ralph_proxy" in lower:
        if "read" in lower or "result_read" in lower:
            return "read"
        if any(token in lower for token in ("grep", "glob", "search", "result_search", "result_summary", "result_reduce")):
            return "search"
        if "shell" in lower:
            return "shell"
        if "write" in lower:
            return "write"
        return "proxy"
    if lower in _READ_TOOL_EXACT or lower.endswith(_READ_TOOL_SUFFIXES):
        return "read"
    if lower in _SEARCH_TOOL_EXACT or any(lower.startswith(prefix) for prefix in ("grep", "glob", "search", "find")):
        return "search"
    if lower in _SHELL_TOOL_EXACT or any(
        lower.startswith(prefix) for prefix in ("bash", "shell", "exec", "run_terminal", "terminal")
    ):
        return "shell"
    if lower in _WRITE_TOOL_EXACT or any(lower.startswith(prefix) for prefix in ("write", "edit", "apply_patch")):
        return "write"
    classified = classify_tool_calls({tool_name: 1})
    if classified.get("native_file_read_calls") or classified.get("native_read_compatibility_calls"):
        return "read"
    if classified.get("native_search_calls"):
        return "search"
    if classified.get("native_shell_calls"):
        return "shell"
    if classified.get("native_write_like_calls"):
        return "write"
    if classified.get("ralph_proxy_calls"):
        return "proxy"
    if classified.get("other_mcp_calls"):
        return "mcp"
    return "other"


def is_read_like(tool_name: str, family: str) -> bool:
    return family == "read"


def is_plan_file_target(target: str) -> bool:
    normalized = _normalize_slashes(target.strip())
    if not normalized:
        return False
    marker_index = normalized.find(_PLAN_FILE_MARKER)
    if marker_index < 0:
        return False
    suffix = normalized[marker_index + len(_PLAN_FILE_MARKER) :]
    return bool(suffix) and suffix != "/"


def record_tool_target(
    acc: Dict[str, Any],
    tool_name: str,
    tool_input: Optional[Mapping[str, Any]] = None,
) -> None:
    normalized = (tool_name or "unknown").strip() or "unknown"
    family = tool_family(normalized)
    target = sanitize_target(normalized, tool_input)
    entry = {
        "tool": normalized,
        "family": family,
        "target": target,
        "is_read": is_read_like(normalized, family),
        "read_key": target if is_read_like(normalized, family) else "",
        "dedupe_key": (normalized, target),
    }
    entries = acc.setdefault("_telemetry_entries", [])
    if isinstance(entries, list):
        entries.append(entry)
    targets = acc.setdefault("tool_call_targets", [])
    if isinstance(targets, list) and len(targets) < _TOOL_TARGETS_CAP:
        targets.append({"tool": normalized, "family": family, "target": target})


def finalize_tool_target_telemetry(acc: Dict[str, Any]) -> None:
    entries = acc.pop("_telemetry_entries", [])
    if not isinstance(entries, list):
        entries = []

    adjacent = 0
    read_counts: Dict[str, int] = {}
    plan_reads = 0
    prev_key: Optional[Tuple[str, str]] = None

    for entry in entries:
        if not isinstance(entry, dict):
            continue
        dedupe_key = entry.get("dedupe_key")
        if isinstance(dedupe_key, tuple) and len(dedupe_key) == 2:
            if prev_key == dedupe_key:
                adjacent += 1
            prev_key = dedupe_key

        if entry.get("is_read"):
            read_key = str(entry.get("read_key") or entry.get("target") or "")
            read_counts[read_key] = read_counts.get(read_key, 0) + 1
            if is_plan_file_target(str(entry.get("target") or "")):
                plan_reads += 1

    repeated_targets = sum(1 for count in read_counts.values() if count > 1)
    repeated_extra = sum(count - 1 for count in read_counts.values() if count > 1)

    acc["adjacent_duplicate_tool_calls"] = adjacent
    acc["repeated_read_targets"] = repeated_targets
    acc["repeated_read_extra_calls"] = repeated_extra
    acc["plan_file_read_calls"] = plan_reads

    if not isinstance(acc.get("tool_call_targets"), list):
        acc["tool_call_targets"] = []


def _batch_max_operations() -> int:
    raw = os.environ.get("RALPH_MCP_PROXY_BATCH_MAX_OPERATIONS", "8")
    try:
        value = int(raw)
    except (TypeError, ValueError):
        value = 8
    return value if value >= 1 else 8


def _batch_guidance_text() -> str:
    return (
        f"batch independent reads with ralph_proxy_batch "
        f"(max {_batch_max_operations()} operations per call) and avoid rereading the same target"
    )


def _lower_tool_label(label: Any) -> str:
    return (str(label or "")).strip().lower()


def _is_grep_like_label(label: str) -> bool:
    lower = _lower_tool_label(label)
    if not lower:
        return False
    if "ralph_proxy_grep" in lower or lower.endswith("_grep") or lower == "grep":
        return True
    return lower.startswith("grep")


def _is_read_only_native_label(label: str) -> bool:
    lower = _lower_tool_label(label)
    if not lower:
        return False
    if "ralph_proxy" in lower or lower.startswith("mcp__"):
        return False
    if lower.startswith("grep"):
        return False
    if lower.startswith(("bash", "glob", "shell")):
        return False
    return lower.startswith("read") or lower in ("read_file", "readfile")


def _is_native_read_like_label(label: str) -> bool:
    counts = classify_tool_calls({label: 1})
    return counts["native_read_like_calls"] > 0


def scan_sequence_antipatterns(
    sequence: Sequence[Any],
    *,
    invocation_ref: int = 0,
) -> List[Dict[str, Any]]:
    findings: List[Dict[str, Any]] = []
    labels = [str(item or "").strip() for item in sequence if str(item or "").strip()]
    if len(labels) < 2:
        return findings

    for idx in range(len(labels) - 1):
        left, right = labels[idx], labels[idx + 1]
        if _is_native_read_like_label(left) and _is_native_read_like_label(right):
            findings.append(
                {
                    "pattern_id": "repeated_native_read_like",
                    "invocation_ref": invocation_ref,
                    "sequence_index": idx,
                    "tools": [left, right],
                }
            )
        if _is_grep_like_label(left) and _is_read_only_native_label(right):
            findings.append(
                {
                    "pattern_id": "native_read_after_grep",
                    "invocation_ref": invocation_ref,
                    "sequence_index": idx,
                    "tools": [left, right],
                }
            )
    return findings


def count_sequence_antipatterns(sequence: Sequence[Any]) -> Dict[str, int]:
    counts = {
        "repeated_native_read_like": 0,
        "native_read_after_grep": 0,
        "result_read_without_search": 0,
        "repeated_result_read": 0,
    }
    labels = [str(item or "").strip() for item in sequence if str(item or "").strip()]
    for finding in scan_sequence_antipatterns(sequence):
        pattern_id = str(finding.get("pattern_id") or "")
        if pattern_id in counts:
            counts[pattern_id] += 1
    result_reads = sum(1 for label in labels if "ralph_proxy_result_read" in label.lower())
    result_search = sum(1 for label in labels if "ralph_proxy_result_search" in label.lower())
    if result_reads > 0 and result_search == 0:
        counts["result_read_without_search"] = result_reads
    if result_reads > 1:
        counts["repeated_result_read"] = result_reads - 1
    return counts


def result_windowing_log_path(
    plan_key: str = "",
    workspace_root: str = "",
) -> Optional[Path]:
    project = Path(os.environ.get("RALPH_MCP_WORKSPACE") or os.getcwd()).resolve()
    state_raw = (workspace_root or os.environ.get("RALPH_PLAN_WORKSPACE_ROOT") or "").strip()
    if state_raw:
        root = Path(state_raw)
        if not root.is_absolute():
            root = project / root
    else:
        root = project / ".ralph-workspace"
    plan = (
        plan_key
        or os.environ.get("RALPH_PLAN_KEY")
        or os.environ.get("RALPH_ARTIFACT_NS")
        or ""
    ).strip()
    if not plan:
        return None
    path = root / "runtime-config" / plan / "result-windowing.jsonl"
    return path if path.is_file() else None




SEQUENCE_ANTIPATTERN_RECOMMENDATIONS = {
    "repeated_native_read_like": (
        "Prefer ralph_proxy_batch (max {max_ops} operations per call) for independent "
        "read/search/glob sequences"
    ),
    "native_read_after_grep": (
        "Prefer ralph_proxy_grep then ralph_proxy_read in one ralph_proxy_batch call "
        "(max {max_ops} operations per call)"
    ),
    "repeated_shell_status_polling": (
        "Prefer ralph_proxy_shell_wait to block server-side, or declare verification "
        "commands in TODO metadata so the runner executes them out-of-process"
    ),
}


def sequence_antipattern_recommendation(pattern_id: str) -> str:
    template = SEQUENCE_ANTIPATTERN_RECOMMENDATIONS.get(pattern_id, "")
    if not template:
        return ""
    return template.format(max_ops=_batch_max_operations())


_SHELL_STATUS_POLL_MIN_CALLS = 3
_SHELL_STATUS_POLL_RATIO = 2


def _shell_status_poll_count(usage: Mapping[str, Any]) -> int:
    """Return excess shell_status poll count above the expected wait+start baseline.

    Returns 0 when polling is proportional to shell_wait/start usage or below
    the minimum threshold, matching the discover-report detection logic.
    """
    by_tool = usage.get("tool_calls_by_tool")
    if not isinstance(by_tool, Mapping):
        return 0
    status_calls = 0
    wait_calls = 0
    start_calls = 0
    for name, count in by_tool.items():
        lower = (str(name or "")).strip().lower()
        if "ralph_proxy_shell_status" in lower:
            status_calls += int(count or 0)
        elif "ralph_proxy_shell_wait" in lower:
            wait_calls += int(count or 0)
        elif "ralph_proxy_shell_start" in lower:
            start_calls += int(count or 0)
    if status_calls < _SHELL_STATUS_POLL_MIN_CALLS:
        return 0
    if status_calls <= (wait_calls + start_calls) * _SHELL_STATUS_POLL_RATIO:
        return 0
    return status_calls - (wait_calls + start_calls) * _SHELL_STATUS_POLL_RATIO


def optimization_hint_line(usage: Mapping[str, Any]) -> str:
    adjacent = int(usage.get("adjacent_duplicate_tool_calls") or 0)
    repeated_extra = int(usage.get("repeated_read_extra_calls") or 0)
    plan_reads = int(usage.get("plan_file_read_calls") or 0)
    cache_read_per_turn = float(usage.get("cache_read_per_tool_turn") or 0)
    threshold = 60000
    env_threshold = os.environ.get("RALPH_CACHE_READ_PER_TURN_WARN")
    if env_threshold:
        try:
            threshold = int(env_threshold)
        except ValueError:
            threshold = 60000

    sequence_counts = {
        "repeated_native_read_like": 0,
        "native_read_after_grep": 0,
        "result_read_without_search": 0,
        "repeated_result_read": 0,
    }
    seq = usage.get("tool_calls_sequence")
    if isinstance(seq, list):
        sequence_counts = count_sequence_antipatterns(seq)

    # Auto-load windowing metrics only when usage names a plan_key explicitly.
    # Do not fall back to ambient RALPH_PLAN_KEY / RALPH_ARTIFACT_NS here: that
    # makes sequence-only callers (baselines, unit tests) inherit unrelated
    # workspace result-windowing.jsonl noise from the active agent session.
    readback_stats = usage.get("stored_result_readbacks")
    if not isinstance(readback_stats, Mapping):
        plan_key = str(usage.get("plan_key") or usage.get("planKey") or "").strip()
        if plan_key:
            windowing_path = result_windowing_log_path(plan_key=plan_key)
            if windowing_path is not None:
                readback_stats = analyze_result_windowing_log(
                    windowing_path, plan_key=plan_key
                )
            else:
                readback_stats = {}
        else:
            readback_stats = {}

    parts: List[str] = []
    if adjacent > 0:
        parts.append(f"{adjacent} adjacent duplicate tool call(s)")
    if repeated_extra > 0:
        parts.append(f"{repeated_extra} repeated read(s)")
    if sequence_counts["repeated_native_read_like"] > 0:
        parts.append(
            f"{sequence_counts['repeated_native_read_like']} consecutive native read/search pair(s)"
        )
    if sequence_counts["native_read_after_grep"] > 0:
        parts.append(
            f"{sequence_counts['native_read_after_grep']} native read(s) after grep"
        )
    if sequence_counts["result_read_without_search"] > 0:
        parts.append(
            f"{sequence_counts['result_read_without_search']} result_read(s) without prior result_search"
        )
    if sequence_counts["repeated_result_read"] > 0:
        parts.append(
            f"{sequence_counts['repeated_result_read']} repeated result_read call(s)"
        )
    readback_guidance = stored_result_readback_guidance(readback_stats)
    shell_status_poll_count = _shell_status_poll_count(usage)
    if plan_reads > 0:
        parts.append(f"{plan_reads} plan file read(s)")
    if cache_read_per_turn > threshold:
        parts.append(f"{int(round(cache_read_per_turn))} cache-read tokens/turn")
    if shell_status_poll_count > 0:
        parts.append(f"{shell_status_poll_count} excess shell_status poll(s)")

    guidance: List[str] = []
    if (
        adjacent > 0
        or repeated_extra > 0
        or sequence_counts["repeated_native_read_like"] > 0
        or sequence_counts["native_read_after_grep"] > 0
    ):
        guidance.append(_batch_guidance_text())
    if plan_reads > 0:
        guidance.append("the runner marks TODOs; read the active plan only when the TODO requires it")
    if cache_read_per_turn > threshold:
        guidance.append(f"context bloat exceeds {threshold} tokens/turn; trim context or reduce tool turns")
    if readback_guidance:
        guidance.append(readback_guidance)
    if shell_status_poll_count > 0:
        guidance.append(
            "prefer ralph_proxy_shell_wait or runner-owned verification over repeated shell_status polls"
        )

    if not parts:
        return ""

    hint = "HINT: " + ", ".join(parts)
    if guidance:
        hint += "; " + "; ".join(guidance)
    return hint
