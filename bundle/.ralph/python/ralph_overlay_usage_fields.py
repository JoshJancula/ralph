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
from typing import Any, Mapping, MutableMapping, Sequence

sys.path.insert(0, os.path.dirname(__file__))

from result_windowing_metrics import (
    WINDOWING_CHANNEL_NAMES,
    aggregate_windowing_savings,
    aggregate_windowing_savings_by_channel,
)
from tool_call_classification import (
    SAVINGS_PATH_NAMES,
    TOKEN_QUALITY_LEGACY,
    TOKEN_QUALITY_MEASURED,
    accumulate_savings_event,
    empty_savings_bucket,
    finalize_savings_bucket,
    token_fields_from_record,
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
    "byte_savings_by_channel": {},
    "native_optimization_proven_channels": [],
    "fallback_channels_active": [],
    "channel_activity_counts": {},
}

OPENCODE_CACHE_DEMUX_KEYS = (
    "opencode_cache_fields_seen",
    "cache_read_input_tokens_estimated",
    "cache_read_estimate_method",
)


def opencode_cache_key_injected_from_env() -> bool:
    """True when Ralph injected or detected ambient OpenCode cache settings."""
    prompt = os.environ.get("RALPH_OPENCODE_PROMPT_CACHE_KEY_INJECTED", "")
    ambient = os.environ.get("RALPH_OPENCODE_AMBIENT_CACHE_SETTINGS", "")
    return coerce_bool(prompt) or coerce_bool(ambient)


def merge_demux_opencode_cache_fields(
    record: MutableMapping[str, Any],
    demux_usage: Mapping[str, Any],
) -> None:
    """Copy OpenCode cache telemetry from demux USAGE_FILE into an invocation record."""
    if not isinstance(demux_usage, Mapping):
        return
    for key in OPENCODE_CACHE_DEMUX_KEYS:
        if key in demux_usage:
            record[key] = demux_usage[key]
    if "tool_turns" in demux_usage:
        record["tool_turns"] = coerce_int(demux_usage.get("tool_turns"))


def aggregate_opencode_cache_summary(
    invocations: Sequence[Mapping[str, Any]],
) -> dict[str, Any]:
    """Summarize OpenCode cache telemetry across plan invocations."""
    opencode = [
        record
        for record in invocations
        if isinstance(record, Mapping) and record.get("runtime") == "opencode"
    ]
    if not opencode:
        return {}

    fields_seen_known = any("opencode_cache_fields_seen" in record for record in opencode)
    fields_seen = any(coerce_bool(record.get("opencode_cache_fields_seen")) for record in opencode)
    estimated_total = sum(
        coerce_int(record.get("cache_read_input_tokens_estimated")) for record in opencode
    )
    estimate_methods = [
        str(record.get("cache_read_estimate_method") or "none").strip()
        for record in opencode
        if str(record.get("cache_read_estimate_method") or "none").strip() not in ("", "none")
    ]
    estimate_method = estimate_methods[0] if estimate_methods else "none"
    key_injected = any(
        coerce_bool(record.get("opencode_cache_key_injected")) for record in opencode
    ) or opencode_cache_key_injected_from_env()

    out: dict[str, Any] = {"opencode_cache_key_injected": key_injected}
    if fields_seen_known:
        out["opencode_cache_fields_seen"] = 1 if fields_seen else 0
    if estimated_total > 0 or any(
        "cache_read_input_tokens_estimated" in record for record in opencode
    ):
        out["cache_read_input_tokens_estimated"] = estimated_total
        out["cache_read_estimate_method"] = estimate_method
    return out


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
    "byte_savings_by_channel",
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


def build_result_windowing_bucket(
    window_path: str, plan_key: str = ""
) -> dict[str, int | float]:
    """Build the result_windowing savings bucket from a result-windowing.jsonl.

    Result windowing savings must reflect what the agent actually consumed.
    aggregate_windowing_savings handles per-resultId netting (preview plus
    readbacks, uncapped) and legacy per-line records without a resultId.

    Savings can be negative: when the envelope scaffolding costs more than
    inlining the result would have, windowing is a net context loss and the
    bucket must say so.

    This is the single builder for the bucket. The runtime overlay calls it to
    write plan-usage-summary.json, and the benchmark report calls it to recompute
    from the log rather than trusting a summary baked by an older build.

    The bucket also carries verified_* / unverified_* sub-tallies, split on
    measurement quality. Only v2_measured events have an inlineCandidateBytes
    baseline, so only they support a defensible counterfactual. Legacy records
    compare against the full stored source -- bytes the tool's own limits would
    have trimmed before the model ever saw them -- and systematically overstate
    savings. The headline counts the verified half; the rest is reported
    separately as an unverifiable historical estimate.
    """
    bucket = empty_savings_bucket(include_hidden=True)
    verified = empty_savings_bucket(include_hidden=True)
    unverified = empty_savings_bucket(include_hidden=True)
    aggregated = aggregate_windowing_savings(
        window_path, estimate_tokens_fn=lambda b: estimate_tokens("x" * b), plan_key=plan_key
    )
    for row in aggregated["per_result"]:
        is_v2 = row.get("measurement_quality") == "v2_measured"
        row_quality = TOKEN_QUALITY_MEASURED if is_v2 else TOKEN_QUALITY_LEGACY
        for target in (bucket, verified if is_v2 else unverified):
            accumulate_savings_event(
                target,
                pre_bytes=row["original_bytes"],
                post_bytes=row["net_post_bytes"],
                pre_tokens=row["original_tokens"],
                post_tokens=row["net_post_tokens"],
                token_cap_trigger=bool(row["token_cap_triggered"]),
                hidden_from_context=True,
                token_quality=row_quality,
            )
    for entry in aggregated["legacy_events"]:
        for target in (bucket, unverified):
            accumulate_savings_event(
                target,
                pre_bytes=entry["original_bytes"],
                post_bytes=entry["returned_bytes"],
                pre_tokens=entry["original_tokens"],
                post_tokens=entry["returned_tokens"],
                token_cap_trigger=bool(entry["token_cap"]),
                token_quality=TOKEN_QUALITY_LEGACY,
                hidden_from_context=True,
            )

    finalize_savings_bucket(bucket)
    finalize_savings_bucket(verified)
    finalize_savings_bucket(unverified)
    for prefix, source in (("verified", verified), ("unverified", unverified)):
        for field in (
            "pre_optimization_bytes",
            "post_optimization_bytes",
            "saved_bytes",
            "pre_optimization_tokens",
            "post_optimization_tokens",
            "saved_tokens",
            "count",
        ):
            bucket[f"{prefix}_{field}"] = source[field]
    return bucket


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
            token_quality = TOKEN_QUALITY_MEASURED
            if original_tokens <= 0 and compacted_tokens <= 0 and original_bytes > 0:
                original_tokens = estimate_tokens("x" * original_bytes)
                compacted_tokens = estimate_tokens("x" * compacted_bytes)
                token_quality = TOKEN_QUALITY_LEGACY

            accumulate_savings_event(
                bucket,
                pre_bytes=original_bytes,
                post_bytes=compacted_bytes,
                pre_tokens=original_tokens,
                post_tokens=compacted_tokens,
                token_cap_trigger=token_cap,
                hidden_from_context=True,
                token_quality=token_quality,
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
        savings_by_path["result_windowing"] = build_result_windowing_bucket(
            window_path, plan_key=plan_key
        )

    for path_name in SAVINGS_PATH_NAMES:
        finalize_savings_bucket(savings_by_path[path_name])

    return savings_by_path


_UNATTRIBUTED_LOG_SOURCES = (
    ("bash-compact.jsonl", "bash_compact"),
    ("proxy-shell-compact.jsonl", "proxy_shell_compact"),
    ("bash-rewrite.jsonl", "bash_rewrite"),
    ("result-windowing.jsonl", "result_windowing"),
)


def aggregate_telemetry_unattributed(state_dir: str, plan_key: str = "") -> list[dict[str, Any]]:
    """Diagnostics for telemetry records that did not positively attribute to
    plan_key: a mismatched plan_key, a fallback-marked key, or a missing key.

    Never included in SAVINGS_PATH_NAMES buckets, per-path/channel totals, or
    tool-output counterfactuals -- aggregate_byte_savings_by_path already
    excludes these records via its own _record_matches filter; this function
    independently re-scans the same logs purely to surface what got excluded
    and why, as a separate data-quality object.
    """
    plan_key = str(plan_key or "").strip()
    if not state_dir or not plan_key:
        return []

    diagnostics: dict[tuple[str, str, bool], dict[str, int]] = {}

    def _record_bytes(record: dict[str, Any]) -> int:
        for key in ("originalBytes", "compactedBytes"):
            value = record.get(key)
            if value is not None:
                return coerce_int(value)
        command = record.get("command")
        if isinstance(command, str):
            return len(command.encode("utf-8"))
        return 0

    def _scan(filename: str, log_kind: str) -> None:
        path = os.path.join(state_dir, filename)
        if not os.path.isfile(path):
            return
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
            if not isinstance(record, dict):
                continue
            observed_key = str(record.get("plan_key") or record.get("planKey") or "").strip()
            if observed_key == plan_key:
                continue  # positively attributed; not a diagnostic
            fallback = coerce_bool(record.get("planKeyFallback"))
            bucket_key = (log_kind, observed_key or "(missing)", fallback)
            bucket = diagnostics.setdefault(bucket_key, {"count": 0, "bytes": 0})
            bucket["count"] += 1
            bucket["bytes"] += _record_bytes(record)

    for filename, log_kind in _UNATTRIBUTED_LOG_SOURCES:
        _scan(filename, log_kind)

    return [
        {
            "logKind": key[0],
            "observedKey": key[1],
            "fallback": key[2],
            "count": value["count"],
            "bytes": value["bytes"],
        }
        for key, value in sorted(diagnostics.items())
    ]


def channel_activity_counts_from_savings(
    channel_savings: Mapping[str, Any] | None,
) -> dict[str, int]:
    """Derive per-channel event counts from byte_savings_by_channel buckets."""
    counts = {channel: 0 for channel in WINDOWING_CHANNEL_NAMES}
    if not isinstance(channel_savings, Mapping):
        return counts
    for channel_name, bucket in channel_savings.items():
        if channel_name not in counts or not isinstance(bucket, Mapping):
            continue
        counts[channel_name] = coerce_int(bucket.get("count"))
    return counts


def aggregate_byte_savings_by_channel(state_dir: str, plan_key: str = "") -> dict[str, dict[str, int | float | str]]:
    """Aggregate byte and estimated-token savings telemetry by optimization channel."""
    savings_by_channel: dict[str, dict[str, int | float | str]] = {
        channel: empty_savings_bucket(include_hidden=True)
        for channel in WINDOWING_CHANNEL_NAMES
    }
    for bucket in savings_by_channel.values():
        bucket["attribution"] = "exact"
    if not state_dir:
        return savings_by_channel

    plan_key = str(plan_key or "").strip()

    def _record_matches(record: dict[str, Any]) -> bool:
        record_plan_key = str(record.get("plan_key") or record.get("planKey") or "").strip()
        if plan_key and record_plan_key and record_plan_key != plan_key:
            return False
        return True

    def _accumulate_compact(path: str, channel_name: str) -> None:
        if not os.path.isfile(path):
            return
        bucket = savings_by_channel[channel_name]
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
            token_quality = TOKEN_QUALITY_MEASURED
            if original_tokens <= 0 and compacted_tokens <= 0 and original_bytes > 0:
                original_tokens = estimate_tokens("x" * original_bytes)
                compacted_tokens = estimate_tokens("x" * compacted_bytes)
                token_quality = TOKEN_QUALITY_LEGACY

            accumulate_savings_event(
                bucket,
                pre_bytes=original_bytes,
                post_bytes=compacted_bytes,
                pre_tokens=original_tokens,
                post_tokens=compacted_tokens,
                token_cap_trigger=token_cap,
                hidden_from_context=True,
                token_quality=token_quality,
            )

    _accumulate_compact(os.path.join(state_dir, "bash-compact.jsonl"), "native_result_hook")
    _accumulate_compact(os.path.join(state_dir, "proxy-shell-compact.jsonl"), "proxy_shell")

    window_path = os.path.join(state_dir, "result-windowing.jsonl")
    if os.path.isfile(window_path):
        window_channels = aggregate_windowing_savings_by_channel(
            window_path,
            estimate_tokens_fn=lambda b: estimate_tokens("x" * b),
            plan_key=plan_key or None,
        )
        for channel_name, channel_data in window_channels.items():
            if channel_name not in savings_by_channel:
                continue
            if not isinstance(channel_data, dict):
                continue
            target = savings_by_channel[channel_name]
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
                if key in channel_data:
                    target[key] = coerce_int(target.get(key)) + coerce_int(channel_data.get(key))
            channel_attribution = str(channel_data.get("attribution") or "exact")
            if channel_attribution == "legacy" or target.get("attribution") == "legacy":
                target["attribution"] = "legacy"
            else:
                target["attribution"] = "exact"

    for channel_name in WINDOWING_CHANNEL_NAMES:
        finalize_savings_bucket(savings_by_channel[channel_name])

    return savings_by_channel


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


def aggregate_hook_config_by_runtime(hooks_config_path: str, plan_key: str = "") -> dict[str, Any]:
    """Aggregate hooks-config.jsonl snapshots into a per-runtime, per-channel
    enabled/disabled/mixed/unknown status with all distinct reasons observed.

    A legacy run with no snapshot file (or an empty file) produces an empty
    dict rather than fabricating a runtime entry, so callers can distinguish
    "no config recorded" (render as unknown) from "recorded, all disabled".
    """
    result: dict[str, Any] = {}
    if not hooks_config_path or not os.path.isfile(hooks_config_path):
        return result

    plan_key = str(plan_key or "").strip()

    # runtime -> channel -> {"enabled": set[bool], "reasons": set[str]}
    buckets: dict[str, dict[str, dict[str, Any]]] = {}

    try:
        with open(hooks_config_path, "r", encoding="utf-8") as fh:
            lines = fh.readlines()
    except OSError:
        return result

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
        record_plan_key = str(record.get("planKey") or "").strip()
        if plan_key and record_plan_key and record_plan_key != plan_key:
            continue
        runtime = str(record.get("runtime") or "unknown").strip() or "unknown"
        channels = record.get("channels")
        if not isinstance(channels, list):
            continue
        runtime_bucket = buckets.setdefault(runtime, {})
        for channel_record in channels:
            if not isinstance(channel_record, dict):
                continue
            channel_name = str(channel_record.get("channel") or "").strip()
            if not channel_name:
                continue
            channel_bucket = runtime_bucket.setdefault(
                channel_name, {"enabled": set(), "reasons": set()}
            )
            channel_bucket["enabled"].add(coerce_bool(channel_record.get("enabled")))
            reason = str(channel_record.get("reason") or "").strip()
            if reason:
                channel_bucket["reasons"].add(reason)

    for runtime, channel_buckets in buckets.items():
        runtime_out: dict[str, Any] = {}
        for channel_name, channel_bucket in channel_buckets.items():
            enabled_states = channel_bucket["enabled"]
            if not enabled_states:
                status = "unknown"
            elif enabled_states == {True}:
                status = "enabled"
            elif enabled_states == {False}:
                status = "disabled"
            else:
                status = "mixed"
            runtime_out[channel_name] = {
                "status": status,
                "reasons": sorted(channel_bucket["reasons"]),
            }
        result[runtime] = runtime_out

    return result


def fields_from_summary(summary: Any) -> dict[str, Any]:
    out = dict(OVERLAY_USAGE_DEFAULTS)
    if not isinstance(summary, dict):
        return out

    out["native_hooks_effective"] = coerce_bool(summary.get("native_hooks_effective"))
    out["native_hooks_configured"] = coerce_bool(summary.get("native_hooks_configured"))
    out["mcp_effective"] = coerce_bool(summary.get("mcp_effective"))
    out["mcp_config_sources"] = coerce_warnings(summary.get("mcp_config_sources"))
    out["mcp_effective_names"] = coerce_warnings(summary.get("mcp_effective_names"))
    out["mcp_override_decisions"] = coerce_warnings(summary.get("mcp_override_decisions"))
    out["mcp_failure_reason"] = str(summary.get("mcp_failure_reason") or "")
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
    channel_savings = summary.get("byte_savings_by_channel")
    if isinstance(channel_savings, dict):
        out["byte_savings_by_channel"] = channel_savings
    proven_channels = summary.get("native_optimization_proven_channels")
    if isinstance(proven_channels, list):
        out["native_optimization_proven_channels"] = proven_channels
    fallback_channels = summary.get("fallback_channels_active")
    if isinstance(fallback_channels, list):
        out["fallback_channels_active"] = fallback_channels
    activity_counts = summary.get("channel_activity_counts")
    if isinstance(activity_counts, dict):
        out["channel_activity_counts"] = activity_counts
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


RUNTIME_OVERLAY_SCALAR_FIELDS = (
    "tool_access_mode",
    "native_hooks_requested",
    "native_hooks_configured",
    "native_hooks_observed_effect",
    "native_hooks_observed_reason",
    "native_hooks_effective",
    "native_hooks_reason",
    "native_hooks_used_on_run",
    "native_output_mutation_proven",
    "native_shell_wrapper_enabled",
    "native_shell_wrapper_effective",
    "native_shell_wrapper_reason",
    "native_shell_compaction_authoritative",
    "fallback_path_active",
    "mcp_effective",
    "mcp_failure_reason",
    "mcp_preflight_outcome",
    "mcp_tool_namespace",
    "proxy_shell_compact_effective",
    "cache_key_injected",
    "cache_key_injected_provider_id",
    "overlay_mode",
)

RUNTIME_OVERLAY_NUMERIC_FIELDS = (
    "native_hook_events",
    "hook_compactions",
    "hook_rewrites",
    "hook_original_bytes",
    "hook_compacted_bytes",
    "proxy_shell_compaction_events",
    "proxy_shell_compactions",
    "proxy_shell_original_bytes",
    "proxy_shell_compacted_bytes",
    "compaction_original_bytes",
    "compaction_compacted_bytes",
    "compaction_saved_bytes",
    "compaction_measured_not_applied_bytes",
)

RUNTIME_OVERLAY_LIST_FIELDS = (
    "mcp_config_sources",
    "mcp_effective_names",
    "mcp_override_decisions",
    "generated_files",
    "mutated_files",
    "warnings",
    "capabilities",
    "native_optimization_proven_channels",
    "fallback_channels_active",
)


def _merge_unique_lists(*lists: Sequence[Any] | None) -> list[Any]:
    seen: set[Any] = set()
    merged: list[Any] = []
    for lst in lists:
        if not lst:
            continue
        for item in lst:
            if item in seen:
                continue
            seen.add(item)
            merged.append(item)
    return merged


def _merge_channel_activity_counts(*dicts: Mapping[str, Any] | None) -> dict[str, int]:
    merged = {channel: 0 for channel in WINDOWING_CHANNEL_NAMES}
    for payload in dicts:
        if not isinstance(payload, Mapping):
            continue
        for channel_name, count in payload.items():
            if channel_name not in merged:
                continue
            merged[channel_name] = merged[channel_name] + coerce_int(count)
    return merged


def _extract_runtime_overlay_scalars(summary: Mapping[str, Any]) -> dict[str, Any]:
    out: dict[str, Any] = {}
    for key in RUNTIME_OVERLAY_SCALAR_FIELDS:
        if key in summary:
            out[key] = summary[key]
    optimizations = summary.get("optimizations")
    if isinstance(optimizations, dict):
        out["optimizations"] = optimizations
    activity_counts = summary.get("channel_activity_counts")
    if isinstance(activity_counts, dict):
        out["channel_activity_counts"] = activity_counts
    return out


def merge_runtime_overlay_summaries(state_dir: str, plan_key: str = "") -> dict[str, Any]:
    """Build the compatibility aggregate summary.json from per-runtime summaries."""
    summaries_dir = os.path.join(state_dir, "summaries")
    per_runtime: dict[str, dict[str, Any]] = {}
    if os.path.isdir(summaries_dir):
        for name in sorted(os.listdir(summaries_dir)):
            if not name.endswith(".json"):
                continue
            runtime = name[:-5].strip()
            if not runtime:
                continue
            loaded = load_summary(os.path.join(summaries_dir, name))
            if not isinstance(loaded, dict):
                continue
            loaded["runtime"] = runtime
            per_runtime[runtime] = loaded

    runtimes_present = sorted(per_runtime.keys())
    if not runtimes_present:
        return {}

    resolved_plan_key = str(plan_key or "").strip()
    if not resolved_plan_key:
        for summary in per_runtime.values():
            candidate = str(summary.get("plan_key") or "").strip()
            if candidate:
                resolved_plan_key = candidate
                break

    aggregate: dict[str, Any] = {
        "plan_key": resolved_plan_key,
        "runtimes_present": runtimes_present,
        "overlay_state_dir": state_dir,
    }

    for field in RUNTIME_OVERLAY_NUMERIC_FIELDS:
        aggregate[field] = sum(coerce_int(per_runtime[r].get(field)) for r in runtimes_present)

    for field in RUNTIME_OVERLAY_LIST_FIELDS:
        aggregate[field] = _merge_unique_lists(*(per_runtime[r].get(field) for r in runtimes_present))

    byte_savings_by_path = aggregate_byte_savings_by_path(state_dir, plan_key=resolved_plan_key)
    if _byte_savings_has_data(byte_savings_by_path):
        aggregate["byte_savings_by_path"] = byte_savings_by_path

    byte_savings_by_channel = aggregate_byte_savings_by_channel(state_dir, plan_key=resolved_plan_key)
    if _channel_savings_has_data(byte_savings_by_channel):
        aggregate["byte_savings_by_channel"] = byte_savings_by_channel

    aggregate["native_optimization_proven_channels"] = _merge_unique_lists(
        *(per_runtime[r].get("native_optimization_proven_channels") for r in runtimes_present)
    )
    aggregate["fallback_channels_active"] = _merge_unique_lists(
        *(per_runtime[r].get("fallback_channels_active") for r in runtimes_present)
    )
    aggregate["channel_activity_counts"] = _merge_channel_activity_counts(
        *(per_runtime[r].get("channel_activity_counts") for r in runtimes_present)
    )
    if _channel_savings_has_data(byte_savings_by_channel):
        telemetry_counts = channel_activity_counts_from_savings(byte_savings_by_channel)
        merged_counts = aggregate["channel_activity_counts"]
        for channel_name, count in telemetry_counts.items():
            if count > merged_counts.get(channel_name, 0):
                merged_counts[channel_name] = count
        aggregate["channel_activity_counts"] = merged_counts

    runtime_overlays = {
        runtime: _extract_runtime_overlay_scalars(per_runtime[runtime])
        for runtime in runtimes_present
    }
    aggregate["runtime_overlays"] = runtime_overlays

    latest_runtime = max(
        runtimes_present,
        key=lambda runtime: str(per_runtime[runtime].get("updated_at") or ""),
    )
    aggregate["runtime"] = latest_runtime
    aggregate["updated_at"] = str(per_runtime[latest_runtime].get("updated_at") or "")

    if len(runtimes_present) == 1:
        only_runtime = runtimes_present[0]
        source = per_runtime[only_runtime]
        for key in RUNTIME_OVERLAY_SCALAR_FIELDS:
            if key in source:
                aggregate[key] = source[key]
        optimizations = source.get("optimizations")
        if isinstance(optimizations, dict):
            aggregate["optimizations"] = optimizations
        for key in ("mcp_config_sources", "mcp_effective_names", "mcp_override_decisions"):
            if key in source and key not in aggregate:
                aggregate[key] = source[key]
        for key in (
            "native_optimization_proven_channels",
            "fallback_channels_active",
            "channel_activity_counts",
        ):
            if key in source:
                aggregate[key] = source[key]

    return aggregate


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


def _channel_savings_has_data(channel_savings: Any) -> bool:
    return _byte_savings_has_data(channel_savings)


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

    existing_channel_savings = record.get("byte_savings_by_channel")
    channel_savings = aggregate_byte_savings_by_channel(state_dir, plan_key=plan_key)
    if _channel_savings_has_data(channel_savings):
        record["byte_savings_by_channel"] = channel_savings
    elif not _channel_savings_has_data(existing_channel_savings):
        record["byte_savings_by_channel"] = channel_savings


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
    if command == "aggregate-byte-savings-by-channel" and len(sys.argv) >= 3:
        plan_key = sys.argv[3] if len(sys.argv) > 3 else ""
        json.dump(aggregate_byte_savings_by_channel(sys.argv[2], plan_key=plan_key), sys.stdout)
        sys.stdout.write("\n")
        return 0
    if command == "merge-runtime-summaries" and len(sys.argv) >= 3:
        plan_key = sys.argv[3] if len(sys.argv) > 3 else ""
        json.dump(merge_runtime_overlay_summaries(sys.argv[2], plan_key=plan_key), sys.stdout)
        sys.stdout.write("\n")
        return 0
    return 2


if __name__ == "__main__":
    raise SystemExit(main())
