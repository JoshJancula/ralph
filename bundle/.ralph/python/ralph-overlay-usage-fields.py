"""Runtime overlay fields for invocation-usage.json records.

This module defines overlay-observed hook activity and capability flags that are
separate from transcript-level tool call counters. Key distinctions:

1) Ralph proxy adoption: ralph_proxy_calls (actual Ralph MCP tool calls from transcript)
2) Transcript-level hook-tool counters: runtime_hook_rewrite_calls, runtime_hook_compaction_calls
   (hook-shaped tool calls recorded in CLI transcript, distinct from overlay-observed activity)
3) Overlay-observed hook activity: hook_rewrites, hook_compactions, hook_original_bytes,
   hook_compacted_bytes, native_hook_events (from overlay journals: bash-rewrite.jsonl,
   bash-compact.jsonl, proxy-shell-compact.jsonl, result-windowing.jsonl)
4) Capability flags: native_hooks_effective (proven capability on tested build),
   native_hooks_used_on_run (true when hook telemetry observed events this run)
"""

from __future__ import annotations

import json
import os
import sys
from typing import Any

sys.path.insert(0, os.path.dirname(__file__))

from result_windowing_metrics import aggregate_windowing_savings
from tool_call_classification import (
    SAVINGS_PATH_NAMES,
    accumulate_savings_event,
    empty_savings_bucket,
    finalize_savings_bucket,
)

try:
    from token_estimate import estimate_tokens
except ImportError:  # pragma: no cover - optional when PYTHONPATH omits bash-lib
    def estimate_tokens(text: str) -> int:  # type: ignore[misc]
        return max(1, (len(text or "") + 3) // 4) if text else 0

OVERLAY_USAGE_DEFAULTS: dict[str, Any] = {
    "native_hooks_effective": False,
    "native_hooks_configured": False,
    "native_hook_events": 0,
    "native_hooks_observed_effect": "",
    "native_hooks_observed_reason": "",
    "native_hooks_used_on_run": False,
    "native_output_mutation_proven": False,
    "native_shell_wrapper_enabled": False,
    "native_shell_wrapper_effective": False,
    "native_shell_wrapper_reason": "",
    "native_shell_compaction_authoritative": "",
    "fallback_path_active": False,
    "hook_compactions": 0,
    "hook_rewrites": 0,
    "hook_original_bytes": 0,
    "hook_compacted_bytes": 0,
    "proxy_shell_compaction_events": 0,
    "proxy_shell_compactions": 0,
    "proxy_shell_original_bytes": 0,
    "proxy_shell_compacted_bytes": 0,
    "mcp_effective": False,
    "runtime_overlay_mode": "",
    "runtime_overlay_warnings": [],
    "byte_savings_by_path": {},
}

HOOK_METRIC_KEYS = (
    "native_hook_events",
    "native_hooks_configured",
    "native_hooks_observed_effect",
    "native_hooks_observed_reason",
    "native_hooks_used_on_run",
    "native_shell_wrapper_enabled",
    "native_shell_wrapper_effective",
    "native_shell_wrapper_reason",
    "native_shell_compaction_authoritative",
    "hook_compactions",
    "hook_rewrites",
    "hook_original_bytes",
    "hook_compacted_bytes",
    "proxy_shell_compaction_events",
    "proxy_shell_compactions",
    "proxy_shell_original_bytes",
    "proxy_shell_compacted_bytes",
    "byte_savings_by_path",
)


def coerce_bool(value: Any) -> bool:
    if isinstance(value, bool):
        return value
    if value is None:
        return False
    text = str(value).strip().lower()
    if not text:
        return False
    return text in ("1", "true", "yes", "on")


def coerce_int(value: Any) -> int:
    if value is None or value == "":
        return 0
    try:
        return int(value)
    except (TypeError, ValueError):
        try:
            return int(float(value))
        except (TypeError, ValueError):
            return 0


def coerce_warnings(value: Any) -> list[str]:
    if not isinstance(value, list):
        return []
    return [str(item) for item in value if str(item).strip()]


def aggregate_byte_savings_by_path(state_dir: str, plan_key: str = "") -> dict[str, dict[str, int | float]]:
    """Aggregate byte and estimated-token savings telemetry by optimization path."""
    savings_by_path: dict[str, dict[str, int | float]] = {
        "pre_tool_rewrite": empty_savings_bucket(),
        "hook_compaction": empty_savings_bucket(include_hidden=True),
        "proxy_shell_compaction": empty_savings_bucket(include_hidden=True),
        "result_windowing": empty_savings_bucket(include_hidden=True),
    }
    if not state_dir:
        return savings_by_path

    plan_key = str(plan_key or "").strip()

    def _record_matches(record: dict[str, Any]) -> bool:
        record_plan_key = str(record.get("plan_key") or record.get("planKey") or "").strip()
        if plan_key and record_plan_key and record_plan_key != plan_key:
            return False
        return True

    def _accumulate_compact(path: str, bucket_name: str) -> None:
        if not os.path.isfile(path):
            return
        bucket = savings_by_path[bucket_name]
        try:
            with open(path, "r", encoding="utf-8") as fh:
                lines = fh.readlines()
        except OSError:
            return
        for raw in lines:
            line = raw.strip()
            if not line:
                continue
            try:
                record = json.loads(line)
            except json.JSONDecodeError:
                continue
            if not isinstance(record, dict) or not _record_matches(record):
                continue
            if record.get("compactionSkipped") is True:
                continue

            original_bytes = coerce_int(record.get("originalBytes"))
            compacted_bytes = coerce_int(record.get("compactedBytes"))
            original_tokens, compacted_tokens, token_cap = token_fields_from_record(record)
            if original_tokens <= 0 and compacted_tokens <= 0 and original_bytes > 0:
                original_tokens = estimate_tokens("x" * original_bytes)
                compacted_tokens = estimate_tokens("x" * compacted_bytes)

            accumulate_savings_event(
                bucket,
                pre_bytes=original_bytes,
                post_bytes=compacted_bytes,
                pre_tokens=original_tokens,
                post_tokens=compacted_tokens,
                token_cap_trigger=token_cap,
                hidden_from_context=True,
            )

    _accumulate_compact(os.path.join(state_dir, "bash-compact.jsonl"), "hook_compaction")
    _accumulate_compact(os.path.join(state_dir, "proxy-shell-compact.jsonl"), "proxy_shell_compaction")

    rewrite_path = os.path.join(state_dir, "bash-rewrite.jsonl")
    if os.path.isfile(rewrite_path):
        try:
            with open(rewrite_path, "r", encoding="utf-8") as fh:
                rewrite_lines = fh.readlines()
        except OSError:
            rewrite_lines = []
        rewrite_bucket = savings_by_path["pre_tool_rewrite"]
        for raw in rewrite_lines:
            line = raw.strip()
            if not line:
                continue
            try:
                record = json.loads(line)
            except json.JSONDecodeError:
                continue
            if not isinstance(record, dict) or not _record_matches(record):
                continue
            if record.get("rewriteApplied") is not True:
                continue
            original_command = str(record.get("command") or "")
            rewritten_command = str(record.get("rewrittenCommand") or "")
            pre_bytes = len(original_command.encode("utf-8"))
            post_bytes = len(rewritten_command.encode("utf-8"))
            pre_tokens = estimate_tokens(original_command)
            post_tokens = estimate_tokens(rewritten_command)
            accumulate_savings_event(
                rewrite_bucket,
                pre_bytes=pre_bytes,
                post_bytes=post_bytes,
                pre_tokens=pre_tokens,
                post_tokens=post_tokens,
            )

    window_path = os.path.join(state_dir, "result-windowing.jsonl")
    if os.path.isfile(window_path):
        window_bucket = savings_by_path["result_windowing"]
        # Result windowing savings must reflect what the agent actually consumed.
        # The shared aggregate_windowing_savings module handles per-resultId
        # netting (preview + readback capped at original bytes/tokens) and legacy
        # per-line records without resultId.
        aggregated = aggregate_windowing_savings(
            window_path, estimate_tokens_fn=lambda b: estimate_tokens("x" * b)
        )
        for row in aggregated["per_result"]:
            accumulate_savings_event(
                window_bucket,
                pre_bytes=row["original_bytes"],
                post_bytes=row["net_post_bytes"],
                pre_tokens=row["original_tokens"],
                post_tokens=row["net_post_tokens"],
                token_cap_trigger=bool(row["token_cap_triggered"]),
                hidden_from_context=True,
            )
        for entry in aggregated["legacy_events"]:
            accumulate_savings_event(
                window_bucket,
                pre_bytes=entry["original_bytes"],
                post_bytes=entry["returned_bytes"],
                pre_tokens=entry["original_tokens"],
                post_tokens=entry["returned_tokens"],
                token_cap_trigger=bool(entry["token_cap"]),
                hidden_from_context=True,
            )

    for path_name in SAVINGS_PATH_NAMES:
        finalize_savings_bucket(savings_by_path[path_name])

    return savings_by_path


def aggregate_hook_telemetry(state_dir: str, plan_key: str = "") -> dict[str, int]:
    metrics = {key: 0 for key in HOOK_METRIC_KEYS}
    if not state_dir:
        return metrics

    plan_key = str(plan_key or "").strip()

    compact_path = os.path.join(state_dir, "bash-compact.jsonl")
    proxy_compact_path = os.path.join(state_dir, "proxy-shell-compact.jsonl")
    rewrite_path = os.path.join(state_dir, "bash-rewrite.jsonl")

    for path, kind in ((compact_path, "compact"), (proxy_compact_path, "proxy_compact"), (rewrite_path, "rewrite")):
        if not os.path.isfile(path):
            continue
        try:
            with open(path, "r", encoding="utf-8") as fh:
                lines = fh.readlines()
        except OSError:
            continue
        for raw in lines:
            line = raw.strip()
            if not line:
                continue
            try:
                record = json.loads(line)
            except json.JSONDecodeError:
                continue
            if not isinstance(record, dict):
                continue
            record_plan_key = str(record.get("plan_key") or record.get("planKey") or "").strip()
            if plan_key and record_plan_key and record_plan_key != plan_key:
                continue
            if kind in ("compact", "rewrite"):
                metrics["native_hook_events"] += 1
            if kind == "compact":
                if record.get("compactionSkipped") is False:
                    metrics["hook_compactions"] += 1
                metrics["hook_original_bytes"] += coerce_int(record.get("originalBytes"))
                metrics["hook_compacted_bytes"] += coerce_int(record.get("compactedBytes"))
            elif kind == "proxy_compact":
                metrics["proxy_shell_compaction_events"] += 1
                if record.get("compactionSkipped") is False:
                    metrics["proxy_shell_compactions"] += 1
                metrics["proxy_shell_original_bytes"] += coerce_int(record.get("originalBytes"))
                metrics["proxy_shell_compacted_bytes"] += coerce_int(record.get("compactedBytes"))
            elif record.get("rewriteApplied") is True:
                metrics["hook_rewrites"] += 1

    return metrics


def fields_from_summary(summary: Any) -> dict[str, Any]:
    out = dict(OVERLAY_USAGE_DEFAULTS)
    if not isinstance(summary, dict):
        return out

    out["native_hooks_effective"] = coerce_bool(summary.get("native_hooks_effective"))
    out["native_hooks_configured"] = coerce_bool(summary.get("native_hooks_configured"))
    out["mcp_effective"] = coerce_bool(summary.get("mcp_effective"))
    out["native_hook_events"] = coerce_int(summary.get("native_hook_events"))
    out["native_hooks_observed_effect"] = str(summary.get("native_hooks_observed_effect") or "")
    out["native_hooks_observed_reason"] = str(summary.get("native_hooks_observed_reason") or "")
    out["native_hooks_used_on_run"] = coerce_bool(summary.get("native_hooks_used_on_run"))
    out["native_output_mutation_proven"] = coerce_bool(summary.get("native_output_mutation_proven"))
    out["native_shell_wrapper_enabled"] = coerce_bool(summary.get("native_shell_wrapper_enabled"))
    out["native_shell_wrapper_effective"] = coerce_bool(summary.get("native_shell_wrapper_effective"))
    out["native_shell_wrapper_reason"] = str(summary.get("native_shell_wrapper_reason") or "")
    out["native_shell_compaction_authoritative"] = str(summary.get("native_shell_compaction_authoritative") or "")
    out["fallback_path_active"] = coerce_bool(summary.get("fallback_path_active"))
    out["hook_compactions"] = coerce_int(summary.get("hook_compactions"))
    out["hook_rewrites"] = coerce_int(summary.get("hook_rewrites"))
    out["hook_original_bytes"] = coerce_int(summary.get("hook_original_bytes"))
    out["hook_compacted_bytes"] = coerce_int(summary.get("hook_compacted_bytes"))
    out["proxy_shell_compaction_events"] = coerce_int(summary.get("proxy_shell_compaction_events"))
    out["proxy_shell_compactions"] = coerce_int(summary.get("proxy_shell_compactions"))
    out["proxy_shell_original_bytes"] = coerce_int(summary.get("proxy_shell_original_bytes"))
    out["proxy_shell_compacted_bytes"] = coerce_int(summary.get("proxy_shell_compacted_bytes"))

    mode = summary.get("runtime_overlay_mode")
    if mode is None or mode == "":
        mode = summary.get("overlay_mode")
    out["runtime_overlay_mode"] = str(mode or "")

    warnings = summary.get("runtime_overlay_warnings")
    if warnings is None:
        warnings = summary.get("warnings")
    out["runtime_overlay_warnings"] = coerce_warnings(warnings)

    byte_savings = summary.get("byte_savings_by_path")
    if isinstance(byte_savings, dict):
        out["byte_savings_by_path"] = byte_savings
    return out


def load_summary(path: str) -> dict[str, Any] | None:
    if not path or not os.path.isfile(path):
        return None
    try:
        with open(path, "r", encoding="utf-8") as fh:
            data = json.load(fh)
    except (OSError, json.JSONDecodeError, ValueError):
        return None
    return data if isinstance(data, dict) else None


def _normalize_compaction_record(raw: Any) -> dict[str, Any] | None:
    if not isinstance(raw, dict):
        return None
    original_bytes = coerce_int(raw.get("original_bytes") or raw.get("originalBytes"))
    compacted_bytes = coerce_int(raw.get("compacted_bytes") or raw.get("compactedBytes"))
    compaction_skipped = raw.get("compaction_skipped")
    if compaction_skipped is None:
        compaction_skipped = raw.get("compactionSkipped")
    skipped = coerce_bool(compaction_skipped) if compaction_skipped is not None else False
    family = str(raw.get("family") or "")
    command_hash = str(raw.get("command_hash") or raw.get("commandHash") or "")
    skip_reason = str(raw.get("skip_reason") or raw.get("skipReason") or "")
    plan_key = str(raw.get("plan_key") or raw.get("planKey") or "").strip()
    timestamp = str(raw.get("timestamp") or raw.get("time") or "")
    storage_path = str(raw.get("storage_path") or raw.get("storagePath") or "")
    exit_code_raw = raw.get("exit_code")
    if exit_code_raw is None:
        exit_code_raw = raw.get("exitCode")
    exit_code = coerce_int(exit_code_raw) if exit_code_raw is not None else None
    out: dict[str, Any] = {
        "original_bytes": original_bytes,
        "compacted_bytes": compacted_bytes,
        "compaction_skipped": skipped,
        "family": family,
        "command_hash": command_hash,
        "plan_key": plan_key,
        "timestamp": timestamp,
        "storage_path": storage_path,
    }
    if exit_code is not None:
        out["exit_code"] = exit_code
    if skip_reason:
        out["skip_reason"] = skip_reason
    if original_bytes > 0 and compacted_bytes > 0 and not skipped:
        out["savings_percent"] = round((1 - compacted_bytes / original_bytes) * 100, 1)
    original_tokens, compacted_tokens, token_cap = token_fields_from_record(raw)
    if original_tokens > 0:
        out["original_tokens"] = original_tokens
    if compacted_tokens > 0:
        out["compacted_tokens"] = compacted_tokens
    if token_cap:
        out["token_cap_triggered"] = True
    if original_tokens > 0 and compacted_tokens >= 0 and not skipped:
        saved_tokens = original_tokens - compacted_tokens
        if saved_tokens > 0:
            out["saved_tokens"] = saved_tokens
            out["savings_percent_tokens"] = round((saved_tokens / original_tokens) * 100, 1)
    return out


_OVERLAY_JOURNAL_FILES = (
    "bash-compact.jsonl",
    "proxy-shell-compact.jsonl",
    "bash-rewrite.jsonl",
    "result-windowing.jsonl",
)


def _overlay_journals_exist(state_dir: str) -> bool:
    if not state_dir:
        return False
    return any(os.path.isfile(os.path.join(state_dir, name)) for name in _OVERLAY_JOURNAL_FILES)


def resolve_overlay_state_dir(summary_path: str, summary: dict[str, Any] | None = None) -> str:
    """Resolve overlay journal directory for a summary file or snapshot copy."""
    summary_path = str(summary_path or "").strip()
    if isinstance(summary, dict):
        stored = str(summary.get("overlay_state_dir") or "").strip()
        if stored and _overlay_journals_exist(stored):
            return stored
    summary_dir = os.path.dirname(summary_path)
    if _overlay_journals_exist(summary_dir):
        return summary_dir
    if isinstance(summary, dict):
        stored = str(summary.get("overlay_state_dir") or "").strip()
        if stored:
            return stored
    return summary_dir


def _byte_savings_has_data(byte_savings: Any) -> bool:
    if not isinstance(byte_savings, dict):
        return False
    for path_data in byte_savings.values():
        if not isinstance(path_data, dict):
            continue
        if coerce_int(path_data.get("count")) > 0:
            return True
        if coerce_int(path_data.get("saved_bytes")) > 0:
            return True
    return False


def load_compaction_telemetry(state_dir: str, plan_key: str = "") -> list[dict[str, Any]]:
    if not state_dir:
        return []
    records: list[dict[str, Any]] = []
    plan_key = str(plan_key or "").strip()
    for filename in ("proxy-shell-compact.jsonl", "bash-compact.jsonl"):
        path = os.path.join(state_dir, filename)
        if not os.path.isfile(path):
            continue
        try:
            with open(path, "r", encoding="utf-8") as fh:
                lines = fh.readlines()
        except OSError:
            continue
        for raw_line in lines:
            line = raw_line.strip()
            if not line:
                continue
            try:
                parsed = json.loads(line)
            except json.JSONDecodeError:
                continue
            normalized = _normalize_compaction_record(parsed)
            if normalized is not None:
                if plan_key:
                    record_plan = str(normalized.get("plan_key") or "").strip()
                    if record_plan and record_plan != plan_key:
                        continue
                records.append(normalized)
    return records


def merge_overlay_fields(record: dict[str, Any], summary_path: str) -> None:
    summary = load_summary(summary_path)
    record.update(fields_from_summary(summary))
    plan_key = ""
    if isinstance(summary, dict):
        plan_key = str(summary.get("plan_key") or "").strip()

    state_dir = resolve_overlay_state_dir(summary_path, summary if isinstance(summary, dict) else None)
    telemetry = load_compaction_telemetry(state_dir, plan_key=plan_key)
    if telemetry:
        record["compaction_telemetry"] = telemetry

    existing_savings = record.get("byte_savings_by_path")
    byte_savings = aggregate_byte_savings_by_path(state_dir, plan_key=plan_key)
    if _byte_savings_has_data(byte_savings):
        record["byte_savings_by_path"] = byte_savings
    elif not _byte_savings_has_data(existing_savings):
        record["byte_savings_by_path"] = byte_savings


def main() -> int:
    if len(sys.argv) < 2:
        return 2
    command = sys.argv[1]
    if command == "fields-from-summary" and len(sys.argv) == 3:
        summary = load_summary(sys.argv[2])
        json.dump(fields_from_summary(summary), sys.stdout)
        sys.stdout.write("\n")
        return 0
    if command == "aggregate-hook-telemetry" and len(sys.argv) >= 3:
        plan_key = sys.argv[3] if len(sys.argv) > 3 else ""
        json.dump(aggregate_hook_telemetry(sys.argv[2], plan_key=plan_key), sys.stdout)
        sys.stdout.write("\n")
        return 0
    if command == "aggregate-byte-savings" and len(sys.argv) >= 3:
        plan_key = sys.argv[3] if len(sys.argv) > 3 else ""
        json.dump(aggregate_byte_savings_by_path(sys.argv[2], plan_key=plan_key), sys.stdout)
        sys.stdout.write("\n")
        return 0
    return 2


if __name__ == "__main__":
    raise SystemExit(main())
