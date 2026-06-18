#!/usr/bin/env python3
"""Classify tool call names for usage accounting and logging."""

from __future__ import annotations

from typing import Dict, Mapping

# Legacy buckets kept for backward-compatible usage JSON and summaries.
_LEGACY_ACCOUNTING_KEYS = (
    "ralph_proxy_calls",
    "other_mcp_calls",
    "native_read_like_calls",
    "native_write_like_calls",
)

# Granular buckets emitted alongside legacy fields.
_GRANULAR_ACCOUNTING_KEYS = (
    "native_file_read_calls",
    "native_read_compatibility_calls",
    "native_search_calls",
    "native_shell_calls",
    "ralph_mcp_calls",
    "runtime_hook_rewrite_calls",
    "runtime_hook_compaction_calls",
    "unknown_tool_calls",
)

ACCOUNTING_KEYS = _LEGACY_ACCOUNTING_KEYS + _GRANULAR_ACCOUNTING_KEYS

_NATIVE_FILE_READ_PREFIXES = ("read", "view", "notebookread")
_NATIVE_FILE_READ_EXACT = frozenset(
    {
        "read_file",
        "readfile",
        "read_file_v2",
        "resources/read",
    }
)

_NATIVE_SEARCH_PREFIXES = ("grep", "glob", "search", "find", "rg", "ripgrep")
_NATIVE_SEARCH_EXACT = frozenset(
    {
        "codebase_search",
        "semanticsearch",
        "semsearch",
        "file_search",
        "list_dir",
        "listdir",
        "ls",
    }
)

_NATIVE_SHELL_PREFIXES = (
    "bash",
    "shell",
    "exec",
    "command_execution",
    "run_terminal",
    "terminal",
    "subprocess",
)
_NATIVE_SHELL_EXACT = frozenset(
    {
        "run_terminal_cmd",
        "run_command",
        "execute_command",
        "shell_command",
        "command",
    }
)

_NATIVE_WRITE_PREFIXES = ("write", "edit", "save", "append")
_NATIVE_WRITE_EXACT = frozenset({"apply_patch", "applypatch", "str_replace", "strreplace"})

_HOOK_REWRITE_MARKERS = (
    "rewrite-bash",
    "rewrite_bash",
    "bash_rewrite",
    "hook_rewrite",
    "pre-tool-bash",
    "shell-command-rewrite",
    "ralph_hook_rewrite",
)

_HOOK_COMPACTION_MARKERS = (
    "compact-bash",
    "compact_bash",
    "bash_compact",
    "hook_compact",
    "post-tool-bash",
    "shell-output-compact",
    "ralph_hook_compact",
    "ralph_bash_compact",
)


def classify_tool_calls(by_tool: Mapping[str, int] | None) -> Dict[str, int]:
    """Return per-category counts derived from a tool_calls_by_tool map."""
    counts: Dict[str, int] = {key: 0 for key in ACCOUNTING_KEYS}
    if not isinstance(by_tool, Mapping):
        return counts
    for raw_label, raw_value in by_tool.items():
        label = (str(raw_label or "")).strip()
        if not label:
            continue
        lower = label.lower()
        try:
            value = int(raw_value or 0)
        except (TypeError, ValueError):
            try:
                value = int(float(raw_value))
            except (TypeError, ValueError):
                value = 0
        if value <= 0:
            continue
        bucket = _classify_label(lower)
        counts[bucket] += value
    counts["ralph_mcp_calls"] = counts["ralph_proxy_calls"]
    counts["native_read_like_calls"] = (
        counts["native_file_read_calls"]
        + counts["native_search_calls"]
        + counts["native_shell_calls"]
        + counts["native_read_compatibility_calls"]
    )
    return counts


def _classify_label(lower: str) -> str:
    if _is_proxy_tool(lower):
        return "ralph_proxy_calls"
    if _is_other_mcp_tool(lower):
        return "other_mcp_calls"
    if _is_hook_rewrite_tool(lower):
        return "runtime_hook_rewrite_calls"
    if _is_hook_compaction_tool(lower):
        return "runtime_hook_compaction_calls"
    if _is_native_write_tool(lower):
        return "native_write_like_calls"
    if _is_native_read_compatibility_tool(lower):
        return "native_read_compatibility_calls"
    if _is_native_file_read_tool(lower):
        return "native_file_read_calls"
    if _is_native_search_tool(lower):
        return "native_search_calls"
    if _is_native_shell_tool(lower):
        return "native_shell_calls"
    return "unknown_tool_calls"


def _is_proxy_tool(lower: str) -> bool:
    return "ralph_proxy" in lower


def _is_other_mcp_tool(lower: str) -> bool:
    return lower.startswith("mcp__")


def _is_hook_rewrite_tool(lower: str) -> bool:
    return any(marker in lower for marker in _HOOK_REWRITE_MARKERS)


def _is_hook_compaction_tool(lower: str) -> bool:
    return any(marker in lower for marker in _HOOK_COMPACTION_MARKERS)


def _is_native_file_read_tool(lower: str) -> bool:
    if lower in _NATIVE_FILE_READ_EXACT:
        return True
    return any(lower.startswith(prefix) for prefix in _NATIVE_FILE_READ_PREFIXES)


def _is_native_search_tool(lower: str) -> bool:
    if lower in _NATIVE_SEARCH_EXACT:
        return True
    return any(lower.startswith(prefix) for prefix in _NATIVE_SEARCH_PREFIXES)


def _is_native_shell_tool(lower: str) -> bool:
    if lower in _NATIVE_SHELL_EXACT:
        return True
    return any(lower.startswith(prefix) for prefix in _NATIVE_SHELL_PREFIXES)


def _is_native_write_tool(lower: str) -> bool:
    if lower in _NATIVE_WRITE_EXACT:
        return True
    return any(lower.startswith(prefix) for prefix in _NATIVE_WRITE_PREFIXES)


def _is_native_read_compatibility_tool(lower: str) -> bool:
    return lower == "read"


# Optimization-path savings telemetry (bytes and estimated tokens; additive only).
SAVINGS_PATH_NAMES = (
    "pre_tool_rewrite",
    "hook_compaction",
    "proxy_shell_compaction",
    "result_windowing",
)


def _coerce_int(value: object, default: int = 0) -> int:
    if value in (None, ""):
        return default
    try:
        return int(value)  # type: ignore[arg-type]
    except (TypeError, ValueError):
        try:
            return int(float(value))  # type: ignore[arg-type]
        except (TypeError, ValueError):
            return default


def _coerce_bool(value: object) -> bool:
    if isinstance(value, bool):
        return value
    text = str(value or "").strip().lower()
    if not text:
        return False
    return text in ("1", "true", "yes", "on")


def empty_savings_bucket(*, include_hidden: bool = False) -> dict[str, int | float]:
    """Return a zeroed savings bucket with additive byte and token fields."""
    bucket: dict[str, int | float] = {
        "pre_optimization_bytes": 0,
        "post_optimization_bytes": 0,
        "saved_bytes": 0,
        "count": 0,
        "pre_optimization_tokens": 0,
        "post_optimization_tokens": 0,
        "saved_tokens": 0,
        "token_cap_triggers": 0,
    }
    if include_hidden:
        bucket["hidden_from_context"] = 0
        bucket["hidden_from_context_tokens"] = 0
    return bucket


def finalize_savings_bucket(bucket: dict[str, int | float]) -> None:
    """Compute savings_percent fields for bytes and tokens when pre > 0."""
    pre_bytes = _coerce_int(bucket.get("pre_optimization_bytes"))
    saved_bytes = _coerce_int(bucket.get("saved_bytes"))
    if pre_bytes > 0:
        bucket["savings_percent"] = round((saved_bytes / pre_bytes) * 100, 1)
    pre_tokens = _coerce_int(bucket.get("pre_optimization_tokens"))
    saved_tokens = _coerce_int(bucket.get("saved_tokens"))
    if pre_tokens > 0:
        bucket["savings_percent_tokens"] = round((saved_tokens / pre_tokens) * 100, 1)


def accumulate_savings_event(
    bucket: dict[str, int | float],
    *,
    pre_bytes: int,
    post_bytes: int,
    pre_tokens: int = 0,
    post_tokens: int = 0,
    token_cap_trigger: bool = False,
    hidden_from_context: bool = False,
) -> None:
    """Add one optimization event into a per-path savings bucket."""
    saved_bytes = pre_bytes - post_bytes
    saved_tokens = pre_tokens - post_tokens
    bucket["pre_optimization_bytes"] = _coerce_int(bucket.get("pre_optimization_bytes")) + pre_bytes
    bucket["post_optimization_bytes"] = _coerce_int(bucket.get("post_optimization_bytes")) + post_bytes
    bucket["saved_bytes"] = _coerce_int(bucket.get("saved_bytes")) + saved_bytes
    bucket["pre_optimization_tokens"] = _coerce_int(bucket.get("pre_optimization_tokens")) + pre_tokens
    bucket["post_optimization_tokens"] = _coerce_int(bucket.get("post_optimization_tokens")) + post_tokens
    bucket["saved_tokens"] = _coerce_int(bucket.get("saved_tokens")) + saved_tokens
    bucket["count"] = _coerce_int(bucket.get("count")) + 1
    if token_cap_trigger:
        bucket["token_cap_triggers"] = _coerce_int(bucket.get("token_cap_triggers")) + 1
    if hidden_from_context:
        if "hidden_from_context" in bucket:
            bucket["hidden_from_context"] = _coerce_int(bucket.get("hidden_from_context")) + saved_bytes
        if "hidden_from_context_tokens" in bucket:
            bucket["hidden_from_context_tokens"] = (
                _coerce_int(bucket.get("hidden_from_context_tokens")) + saved_tokens
            )


def merge_savings_buckets(
    target: dict[str, dict[str, int | float]],
    source: dict[str, dict[str, int | float]],
) -> None:
    """Merge per-path savings buckets additively."""
    for path_name, path_data in source.items():
        if path_name not in target or not isinstance(path_data, dict):
            continue
        bucket = target[path_name]
        for key in (
            "pre_optimization_bytes",
            "post_optimization_bytes",
            "saved_bytes",
            "count",
            "pre_optimization_tokens",
            "post_optimization_tokens",
            "saved_tokens",
            "token_cap_triggers",
            "hidden_from_context",
            "hidden_from_context_tokens",
        ):
            if key in path_data:
                bucket[key] = _coerce_int(bucket.get(key)) + _coerce_int(path_data.get(key))


def savings_from_path_data(path_data: Mapping[str, object] | None) -> dict[str, int | float]:
    """Copy savings fields from an invocation or summary path_data dict."""
    out = empty_savings_bucket(include_hidden="hidden_from_context" in (path_data or {}))
    if not isinstance(path_data, Mapping):
        return out
    for key in out:
        if key in path_data:
            if key.endswith("_percent") or key.endswith("_percent_tokens"):
                out[key] = float(path_data.get(key) or 0)
            else:
                out[key] = _coerce_int(path_data.get(key))
    return out


def token_fields_from_record(record: Mapping[str, object]) -> tuple[int, int, bool]:
    """Return (original_tokens, compacted_or_returned_tokens, token_cap_triggered)."""
    original = _coerce_int(
        record.get("originalTokens", record.get("original_tokens"))
    )
    compacted = _coerce_int(
        record.get("compactedTokens", record.get("compacted_tokens"))
    )
    if compacted <= 0:
        compacted = _coerce_int(
            record.get("returnedTokens", record.get("returned_tokens"))
        )
    token_cap = _coerce_bool(
        record.get("tokenCapTriggered", record.get("token_cap_triggered"))
    )
    return original, compacted, token_cap
