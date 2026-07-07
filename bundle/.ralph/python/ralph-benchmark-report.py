#!/usr/bin/env python3
"""Aggregate savings telemetry from Ralph usage summaries."""

from __future__ import annotations

import json
import os
import sys
from datetime import datetime, timezone
from typing import Any, Mapping, Sequence

from pathlib import Path

sys.path.insert(0, os.path.dirname(__file__))

from ralph_overlay_usage_fields import aggregate_byte_savings_by_channel
from result_windowing_metrics import (
    WINDOWING_CHANNEL_NAMES,
    _filter_records_for_plan_key,
    _load_windowing_records,
    _parse_envelope,
    _parse_readback,
    _resolve_result_channel_target,
)
from token_estimate import estimate_tokens
from tool_call_classification import (
    SAVINGS_PATH_NAMES,
    empty_savings_bucket,
    finalize_savings_bucket,
    merge_savings_buckets,
    savings_from_path_data,
)
from tool_call_target_telemetry import analyze_result_windowing_log
from usage_accounting import aggregate_records

_CHANNEL_SAVINGS_KEYS = (
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
)


def _as_int(value: Any) -> int:
    try:
        return int(value or 0)
    except (TypeError, ValueError):
        try:
            return int(float(value or 0))
        except (TypeError, ValueError):
            return 0


def _as_float(value: Any) -> float:
    try:
        return float(value or 0)
    except (TypeError, ValueError):
        return 0.0


def _parse_ts(value: Any) -> datetime | None:
    text = str(value or "").strip()
    if not text:
        return None
    if text.endswith("Z"):
        text = text[:-1] + "+00:00"
    try:
        return datetime.fromisoformat(text)
    except ValueError:
        return None


def _isoformat(dt: datetime | None) -> str | None:
    if dt is None:
        return None
    return dt.astimezone(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")


def _empty_paths() -> dict[str, dict[str, int | float]]:
    return {
        path_name: empty_savings_bucket(
            include_hidden=path_name in ("hook_compaction", "proxy_shell_compaction", "result_windowing")
        )
        for path_name in SAVINGS_PATH_NAMES
    }


def _merge_bucket(target: dict[str, int | float], source: Mapping[str, Any]) -> None:
    for key in target:
        if key in source:
            target[key] = _as_int(target.get(key)) + _as_int(source.get(key))


def _final_snapshot_key(record: Mapping[str, Any], path_name: str) -> tuple[str, str]:
    # The runtime overlay writes each invocation's byte_savings_by_path as a
    # cumulative running total (it re-reads the whole telemetry log every
    # iteration). Summing those snapshots across iterations multiplies the real
    # savings, so we key only by (plan_key, path_name) and keep the final
    # (largest) cumulative snapshot rather than summing.
    return (str(record.get("plan_key") or ""), path_name)


def _aggregate_invocation_paths(path: str) -> dict[str, dict[str, int | float]]:
    out = _empty_paths()
    if not os.path.isfile(path):
        return out
    with open(path, encoding="utf-8") as handle:
        doc = json.load(handle)
    invocations = doc.get("invocations")
    if not isinstance(invocations, list):
        return out

    # Keep the final cumulative snapshot per (plan_key, path_name). These
    # totals can decrease when later readbacks consume raw/full stored results,
    # so "largest saved_bytes" would report max potential savings, not actual.
    latest: dict[tuple[str, str], dict[str, int | float]] = {}
    for record in invocations:
        if not isinstance(record, Mapping):
            continue
        byte_savings = record.get("byte_savings_by_path")
        if not isinstance(byte_savings, Mapping):
            continue
        for path_name in SAVINGS_PATH_NAMES:
            path_data = byte_savings.get(path_name)
            if not isinstance(path_data, Mapping):
                continue
            key = _final_snapshot_key(record, path_name)
            latest[key] = dict(path_data)

    for (_plan_key, path_name), path_data in latest.items():
        _merge_bucket(out[path_name], path_data)

    return out


def _aggregate_windowing_from_summary(summary: Mapping[str, Any]) -> dict[str, Any]:
    """Aggregate result-windowing totals already present in a summary's per-path buckets.

    plan-usage-summary.json emitted by ralph-usage-summary-text.py contains
    byte_savings_by_path.result_windowing with pre/post/ saved bytes and tokens.
    When multiple model_breakdown rows exist, they sum to the same totals, so we
    only read the top-level summary rather than double-counting.
    """
    out: dict[str, Any] = {
        "original_bytes": 0,
        "returned_bytes": 0,
        "saved_bytes": 0,
        "original_tokens": 0,
        "returned_tokens": 0,
        "saved_tokens": 0,
    }
    by_path = summary.get("byte_savings_by_path")
    if not isinstance(by_path, Mapping):
        return out
    windowing = by_path.get("result_windowing")
    if not isinstance(windowing, Mapping):
        return out
    for key in out:
        if key in windowing:
            out[key] = _as_int(windowing[key])
    return out


def _estimate_tokens_from_bytes(byte_count: int) -> int:
    if byte_count <= 0:
        return 0
    # The benchmark report only needs the token estimate for an all-letter
    # synthetic string, which is exactly ceil(byte_count / 4) under the
    # current estimator. Avoid materializing a giant string here; large
    # benchmarks can otherwise spend most of their time allocating and walking
    # that temporary buffer.
    return max(1, (byte_count + 3) // 4)


def _path_from_family(family: str) -> str | None:
    lower = family.strip().lower()
    if lower in ("hook_compaction", "bash", "hook"):
        return "hook_compaction"
    if lower in ("proxy_shell_compaction", "proxy_shell", "proxy-shell", "proxy"):
        return "proxy_shell_compaction"
    if lower in ("result_windowing", "result-windowing", "windowing", "result"):
        return "result_windowing"
    if lower in ("pre_tool_rewrite", "pre-tool-rewrite", "rewrite", "bash-rewrite"):
        return "pre_tool_rewrite"
    return None


def _windowing_log_for_summary(summary_path: str) -> Path | None:
    log_dir = Path(summary_path).resolve().parent
    plan_key = log_dir.name
    if not plan_key:
        return None
    candidate = log_dir.parent.parent / "runtime-config" / plan_key / "result-windowing.jsonl"
    return candidate if candidate.is_file() else None


def _state_dir_for_summary(summary_path: str) -> Path | None:
    log_dir = Path(summary_path).resolve().parent
    plan_key = log_dir.name
    if not plan_key:
        return None
    candidate = log_dir.parent.parent / "runtime-config" / plan_key
    return candidate if candidate.is_dir() else None


def _empty_channels() -> dict[str, dict[str, int | float | str]]:
    return {
        channel: {
            **empty_savings_bucket(include_hidden=True),
            "attribution": "exact",
        }
        for channel in WINDOWING_CHANNEL_NAMES
    }


def _channel_has_activity(bucket: Mapping[str, Any]) -> bool:
    return (
        _as_int(bucket.get("pre_optimization_bytes")) > 0
        or _as_int(bucket.get("saved_bytes")) > 0
        or _as_int(bucket.get("count")) > 0
    )


def _merge_channel_bucket(
    target: dict[str, int | float | str],
    source: Mapping[str, Any],
) -> None:
    for key in _CHANNEL_SAVINGS_KEYS:
        if key in source:
            target[key] = _as_int(target.get(key)) + _as_int(source.get(key))
    source_attribution = str(source.get("attribution") or "exact")
    if source_attribution == "legacy" or target.get("attribution") == "legacy":
        target["attribution"] = "legacy"
    else:
        target["attribution"] = "exact"


def _finalize_channel_buckets(
    channels: dict[str, dict[str, int | float | str]],
) -> dict[str, dict[str, int | float | str]]:
    per_channel: dict[str, dict[str, int | float | str]] = {}
    for channel_name in WINDOWING_CHANNEL_NAMES:
        bucket = dict(channels[channel_name])
        if _channel_has_activity(bucket):
            finalize_savings_bucket(bucket)
        per_channel[channel_name] = bucket
    return per_channel


def _aggregate_invocation_channels(
    path: str,
    plan_key: str,
) -> dict[str, dict[str, int | float | str]]:
    out = _empty_channels()
    if not os.path.isfile(path):
        return out
    with open(path, encoding="utf-8") as handle:
        doc = json.load(handle)
    invocations = doc.get("invocations")
    if not isinstance(invocations, list):
        return out

    target_plan_key = str(plan_key or "").strip()
    latest: dict[tuple[str, str], dict[str, int | float | str]] = {}
    for record in invocations:
        if not isinstance(record, Mapping):
            continue
        channel_savings = record.get("byte_savings_by_channel")
        if not isinstance(channel_savings, Mapping):
            continue
        record_plan = str(record.get("plan_key") or "").strip()
        if target_plan_key and record_plan and record_plan != target_plan_key:
            continue
        for channel_name, path_data in channel_savings.items():
            if channel_name not in out or not isinstance(path_data, Mapping):
                continue
            key = (target_plan_key or record_plan, channel_name)
            latest[key] = savings_from_path_data(path_data)
            if path_data.get("attribution") == "legacy":
                latest[key]["attribution"] = "legacy"

    for (_key_plan, channel_name), channel_bucket in latest.items():
        merge_savings_buckets(
            {channel_name: out[channel_name]},
            {channel_name: channel_bucket},
        )
        if channel_bucket.get("attribution") == "legacy":
            out[channel_name]["attribution"] = "legacy"

    return _finalize_channel_buckets(out)


def _summary_channels(
    summary: Mapping[str, Any],
    summary_path: str,
    plan_key: str,
) -> dict[str, dict[str, int | float | str]]:
    channel_data = summary.get("byte_savings_by_channel")
    if isinstance(channel_data, Mapping):
        out = _empty_channels()
        for channel_name in WINDOWING_CHANNEL_NAMES:
            raw_bucket = channel_data.get(channel_name)
            if isinstance(raw_bucket, Mapping):
                _merge_channel_bucket(out[channel_name], raw_bucket)
        if any(_channel_has_activity(bucket) for bucket in out.values()):
            return _finalize_channel_buckets(out)

    invocation_path = os.path.join(os.path.dirname(summary_path), "invocation-usage.json")
    invocation_channels = _aggregate_invocation_channels(invocation_path, plan_key)
    if any(_channel_has_activity(bucket) for bucket in invocation_channels.values()):
        return invocation_channels

    state_dir = _state_dir_for_summary(summary_path)
    if state_dir is not None:
        return aggregate_byte_savings_by_channel(str(state_dir), plan_key=plan_key)

    return _empty_channels()


def _windowing_readback_by_channel(
    path: Path | str,
    *,
    plan_key: str | None = None,
) -> dict[str, dict[str, int]]:
    stats = {
        channel: {
            "gross_readback_bytes": 0,
            "gross_readback_tokens": 0,
            "net_consumed_bytes": 0,
            "net_consumed_tokens": 0,
        }
        for channel in WINDOWING_CHANNEL_NAMES
    }
    if not os.path.isfile(str(path)):
        return stats

    records = _filter_records_for_plan_key(_load_windowing_records(path), plan_key)
    envelopes: dict[str, dict[str, Any]] = {}
    readbacks: list[dict[str, Any]] = []
    for record in records:
        event = str(record.get("event") or "").strip().lower()
        if event == "envelope":
            parsed = _parse_envelope(record)
            if parsed is not None:
                envelopes[parsed["result_id"]] = parsed
        elif event == "readback":
            parsed = _parse_readback(record)
            if parsed is not None:
                readbacks.append(parsed)

    grouped_readbacks: dict[str, list[dict[str, Any]]] = {}
    for readback in readbacks:
        grouped_readbacks.setdefault(readback["result_id"], []).append(readback)

    for result_id, envelope in envelopes.items():
        result_readbacks = grouped_readbacks.get(result_id, [])
        extra_bytes = sum(_as_int(item.get("returned_bytes")) for item in result_readbacks)
        extra_tokens = sum(_as_int(item.get("returned_tokens")) for item in result_readbacks)
        original_bytes = _as_int(envelope.get("original_bytes"))
        original_tokens = _as_int(envelope.get("original_tokens"))
        preview_bytes = _as_int(envelope.get("returned_bytes"))
        preview_tokens = _as_int(envelope.get("returned_tokens"))
        consumed_bytes = preview_bytes + extra_bytes
        consumed_tokens = preview_tokens + extra_tokens
        net_post_bytes = (
            min(original_bytes, consumed_bytes) if original_bytes > 0 else consumed_bytes
        )
        net_post_tokens = (
            min(original_tokens, consumed_tokens)
            if original_tokens > 0
            else consumed_tokens
        )
        channel_name, _attribution = _resolve_result_channel_target(envelope, result_readbacks)
        if channel_name not in stats:
            continue
        bucket = stats[channel_name]
        bucket["gross_readback_bytes"] += extra_bytes
        bucket["gross_readback_tokens"] += extra_tokens
        bucket["net_consumed_bytes"] += net_post_bytes
        bucket["net_consumed_tokens"] += net_post_tokens

    return stats


def _enrich_channel_diagnostics(
    per_channel: dict[str, dict[str, int | float | str]],
    readback_by_channel: Mapping[str, Mapping[str, int]] | None,
) -> None:
    """Add diagnostic gross/net fields to per-channel buckets."""
    for channel_name, bucket in per_channel.items():
        if channel_name in ("native_shell_hook", "proxy_shell", "native_result_hook"):
            bucket["gross_hidden_bytes"] = _as_int(bucket.get("hidden_from_context"))
            bucket["gross_hidden_tokens"] = _as_int(bucket.get("hidden_from_context_tokens"))

        if readback_by_channel:
            channel_stats = readback_by_channel.get(channel_name) or {}
            gross_readback_bytes = _as_int(channel_stats.get("gross_readback_bytes"))
            net_consumed_bytes = _as_int(channel_stats.get("net_consumed_bytes"))
            if gross_readback_bytes > 0:
                bucket["gross_readback_bytes"] = gross_readback_bytes
                bucket["gross_readback_tokens"] = _as_int(
                    channel_stats.get("gross_readback_tokens")
                )
            if net_consumed_bytes > 0:
                bucket["net_consumed_bytes"] = net_consumed_bytes
                bucket["net_consumed_tokens"] = _as_int(
                    channel_stats.get("net_consumed_tokens")
                )

        if (
            "net_consumed_bytes" not in bucket
            and channel_name
            in (
                "proxy_read_windowing",
                "proxy_search_windowing",
                "native_result_mcp_fallback",
                "stored_result_readback",
            )
            and _as_int(bucket.get("count")) > 0
        ):
            bucket["net_consumed_bytes"] = _as_int(bucket.get("post_optimization_bytes"))
            bucket["net_consumed_tokens"] = _as_int(bucket.get("post_optimization_tokens"))


def _savings_path_status(
    path_name: str,
    bucket: Mapping[str, Any],
    readback_stats: Mapping[str, Any] | None,
) -> str:
    pre_bytes = _as_int(bucket.get("pre_optimization_bytes"))
    saved_bytes = _as_int(bucket.get("saved_bytes"))
    count = _as_int(bucket.get("count"))
    if pre_bytes <= 0 and count <= 0:
        return "inactive"
    if saved_bytes > 0:
        return "saved"
    if path_name == "result_windowing" and readback_stats:
        if _as_int(readback_stats.get("readback_count")) > 0 and pre_bytes > 0:
            return "negated"
    if path_name == "result_windowing" and readback_stats:
        if _as_int(readback_stats.get("envelope_count")) > 0 and pre_bytes > 0:
            return "active"
    if pre_bytes > 0 or count > 0:
        return "active"
    return "inactive"


def _path_status_label(status: str) -> str:
    labels = {
        "inactive": "inactive",
        "saved": "saved",
        "active": "active",
        "negated": "negated by readback",
    }
    return labels.get(status, status)


def _aggregate_compaction_telemetry(path: str) -> dict[str, dict[str, int | float]]:
    out = _empty_paths()
    if not os.path.isfile(path):
        return out
    with open(path, encoding="utf-8") as handle:
        doc = json.load(handle)
    invocations = doc.get("invocations")
    if not isinstance(invocations, list):
        return out

    # compaction_telemetry is also re-emitted cumulatively per iteration, so the
    # dedupe key must NOT include iteration; identical events (same family and
    # byte sizes) are collapsed by content instead of counted once per iteration.
    seen: set[tuple[str, str, str, int, int]] = set()
    for record in invocations:
        if not isinstance(record, Mapping):
            continue
        telemetry = record.get("compaction_telemetry")
        if not isinstance(telemetry, list):
            continue
        for item in telemetry:
            if not isinstance(item, Mapping):
                continue
            if item.get("compactionSkipped") is True or item.get("compaction_skipped") is True:
                continue
            path_name = _path_from_family(str(item.get("family") or ""))
            if path_name is None:
                continue
            original_bytes = _as_int(item.get("originalBytes", item.get("original_bytes")))
            compacted_bytes = _as_int(item.get("compactedBytes", item.get("compacted_bytes")))
            if original_bytes <= 0:
                continue
            key = (
                str(record.get("plan_key") or ""),
                str(record.get("stage_id") or ""),
                path_name,
                original_bytes,
                compacted_bytes,
            )
            if key in seen:
                continue
            seen.add(key)
            bucket = out[path_name]
            original_tokens = _as_int(item.get("originalTokens", item.get("original_tokens")))
            compacted_tokens = _as_int(
                item.get("compactedTokens", item.get("compacted_tokens", item.get("returnedTokens", item.get("returned_tokens"))))
            )
            if original_tokens <= 0:
                original_tokens = _estimate_tokens_from_bytes(original_bytes)
            if compacted_tokens <= 0 and compacted_bytes > 0:
                compacted_tokens = _estimate_tokens_from_bytes(compacted_bytes)
            bucket["pre_optimization_bytes"] = _as_int(bucket.get("pre_optimization_bytes")) + original_bytes
            bucket["post_optimization_bytes"] = _as_int(bucket.get("post_optimization_bytes")) + compacted_bytes
            bucket["saved_bytes"] = _as_int(bucket.get("saved_bytes")) + max(0, original_bytes - compacted_bytes)
            bucket["pre_optimization_tokens"] = _as_int(bucket.get("pre_optimization_tokens")) + original_tokens
            bucket["post_optimization_tokens"] = _as_int(bucket.get("post_optimization_tokens")) + compacted_tokens
            bucket["saved_tokens"] = _as_int(bucket.get("saved_tokens")) + max(0, original_tokens - compacted_tokens)
            bucket["count"] = _as_int(bucket.get("count")) + 1
            if item.get("tokenCapTriggered") is True or item.get("token_cap_triggered") is True:
                bucket["token_cap_triggers"] = _as_int(bucket.get("token_cap_triggers")) + 1
            if "hidden_from_context" in bucket:
                bucket["hidden_from_context"] = _as_int(bucket.get("hidden_from_context")) + max(
                    0, original_bytes - compacted_bytes
                )
            if "hidden_from_context_tokens" in bucket:
                bucket["hidden_from_context_tokens"] = _as_int(bucket.get("hidden_from_context_tokens")) + max(
                    0, original_tokens - compacted_tokens
                )
    return out


def _load_summary(path: str) -> Mapping[str, Any]:
    with open(path, encoding="utf-8") as handle:
        data = json.load(handle)
    if not isinstance(data, Mapping):
        raise ValueError(f"summary is not a JSON object: {path}")
    return data


def _run_id(summary: Mapping[str, Any], summary_path: str) -> str:
    log_dir_name = os.path.basename(os.path.dirname(os.path.normpath(summary_path)))
    if log_dir_name:
        return log_dir_name
    return str(summary.get("plan_key") or "")


def _finalize_path_buckets(
    paths: dict[str, dict[str, int | float]],
) -> tuple[dict[str, dict[str, int | float]], int, int, int]:
    per_path: dict[str, dict[str, int | float]] = {}
    saved_bytes = 0
    saved_tokens = 0
    pre_optimization_bytes = 0
    for path_name in SAVINGS_PATH_NAMES:
        bucket = dict(paths[path_name])
        finalize_savings_bucket(bucket)
        per_path[path_name] = bucket
        saved_bytes += _as_int(bucket.get("saved_bytes"))
        saved_tokens += _as_int(bucket.get("saved_tokens"))
        pre_optimization_bytes += _as_int(bucket.get("pre_optimization_bytes"))
    return per_path, saved_bytes, saved_tokens, pre_optimization_bytes


def _enrich_path_diagnostics(
    per_path: dict[str, dict[str, int | float]],
    readback_stats: Mapping[str, Any] | None,
    compaction_measured_not_applied_bytes: int,
) -> None:
    """Add diagnostic fields to per-path buckets without changing additive totals."""
    for path_name in SAVINGS_PATH_NAMES:
        bucket = per_path[path_name]
        if path_name in ("hook_compaction", "proxy_shell_compaction", "result_windowing"):
            bucket["gross_hidden_bytes"] = _as_int(bucket.get("hidden_from_context"))
            bucket["gross_hidden_tokens"] = _as_int(bucket.get("hidden_from_context_tokens"))
        if path_name == "result_windowing":
            stats = readback_stats or {}
            bucket["gross_readback_bytes"] = _as_int(stats.get("gross_readback_bytes"))
            bucket["gross_readback_tokens"] = _as_int(stats.get("gross_readback_tokens"))
            bucket["net_readback_cost_bytes"] = max(
                0, _as_int(stats.get("net_consumed_bytes")) - _as_int(bucket.get("post_optimization_bytes"))
            )
            bucket["effective_windowing_savings_rate"] = float(
                stats.get("effective_windowing_savings_rate") or 0
            )
        if path_name == "proxy_shell_compaction":
            bucket["compaction_measured_not_applied_bytes"] = compaction_measured_not_applied_bytes


def _build_tool_output_counterfactual(
    per_path: Mapping[str, Mapping[str, Any]],
    windowing_totals: Mapping[str, int],
    compaction_measured_not_applied_bytes: int,
) -> dict[str, Any]:
    """Compute with-vs-without-Ralph byte/token counterfactuals.

    hypothetical_without_ralph is the tool output that would have reached the
    model if Ralph had not compacted or windowed anything. actual_with_ralph is
    the post-optimization tool output plus the net bytes agents re-consumed via
    stored-result readbacks, because those readbacks are real tool-output bytes
    consumed even with Ralph present.
    """
    hypothetical_without_ralph_bytes = 0
    actual_with_ralph_bytes = 0
    for path_name in SAVINGS_PATH_NAMES:
        bucket = per_path.get(path_name) or {}
        pre = _as_int(bucket.get("pre_optimization_bytes"))
        post = _as_int(bucket.get("post_optimization_bytes"))
        hypothetical_without_ralph_bytes += pre
        actual_with_ralph_bytes += post

    # Result-windowing buckets already reflect net post in saved_bytes, but we
    # can derive a cleaner counterfactual from the explicit summary windowing
    # totals when they exist. Fall back to per_path post when missing.
    window_original = _as_int(windowing_totals.get("original_bytes"))
    window_returned = _as_int(windowing_totals.get("returned_bytes"))
    if window_original > 0:
        hypothetical_without_ralph_bytes += window_original - _as_int(
            per_path.get("result_windowing", {}).get("pre_optimization_bytes", 0)
        )
        actual_with_ralph_bytes += window_returned - _as_int(
            per_path.get("result_windowing", {}).get("post_optimization_bytes", 0)
        )
    # When the summary does not include explicit original/returned windowing
    # totals, reconcile the per-path windowing bucket with net readback cost so
    # actual_with_ralph includes bytes agents re-consumed via readbacks.
    elif per_path.get("result_windowing", {}).get("pre_optimization_bytes", 0) > 0:
        rw = per_path["result_windowing"]
        net_readback_cost = _as_int(rw.get("net_readback_cost_bytes"))
        actual_with_ralph_bytes += max(0, net_readback_cost)

    actual_with_ralph_bytes = max(actual_with_ralph_bytes, 0)
    hypothetical_without_ralph_bytes = max(hypothetical_without_ralph_bytes, 0)

    hypothetical_without_ralph_tokens = _estimate_tokens_from_bytes(
        hypothetical_without_ralph_bytes
    )
    actual_with_ralph_tokens = _estimate_tokens_from_bytes(actual_with_ralph_bytes)
    net_savings_bytes = max(0, hypothetical_without_ralph_bytes - actual_with_ralph_bytes)
    net_savings_tokens = max(0, hypothetical_without_ralph_tokens - actual_with_ralph_tokens)

    # Include compaction savings that were measured but could not be applied in
    # this run mode (e.g. native-mode runs without proxy) as additional counter-
    # factual opportunity, but keep it out of the primary net savings because it
    # was not actually realized.
    counterfactual_opportunity_bytes = max(0, compaction_measured_not_applied_bytes)
    counterfactual_opportunity_tokens = _estimate_tokens_from_bytes(
        counterfactual_opportunity_bytes
    )

    net_savings_percent = (
        round((net_savings_bytes / hypothetical_without_ralph_bytes) * 100, 1)
        if hypothetical_without_ralph_bytes > 0
        else 0.0
    )

    return {
        "hypothetical_without_ralph_bytes": hypothetical_without_ralph_bytes,
        "actual_with_ralph_bytes": actual_with_ralph_bytes,
        "net_savings_bytes": net_savings_bytes,
        "hypothetical_without_ralph_tokens": hypothetical_without_ralph_tokens,
        "actual_with_ralph_tokens": actual_with_ralph_tokens,
        "net_savings_tokens": net_savings_tokens,
        "net_savings_percent": net_savings_percent,
        "compaction_measured_not_applied_bytes": counterfactual_opportunity_bytes,
        "compaction_measured_not_applied_tokens": counterfactual_opportunity_tokens,
    }


def _summary_paths(summary: Mapping[str, Any], summary_path: str) -> dict[str, dict[str, int | float]]:
    path_data = summary.get("byte_savings_by_path")
    if isinstance(path_data, Mapping):
        out = _empty_paths()
        for path_name in SAVINGS_PATH_NAMES:
            raw_bucket = path_data.get(path_name)
            if isinstance(raw_bucket, Mapping):
                _merge_bucket(out[path_name], raw_bucket)
        if any(
            _as_int(bucket.get("pre_optimization_bytes"))
            or _as_int(bucket.get("saved_bytes"))
            or _as_int(bucket.get("saved_tokens"))
            or _as_int(bucket.get("count"))
            for bucket in out.values()
        ):
            return out

    invocation_path = os.path.join(os.path.dirname(summary_path), "invocation-usage.json")
    out = _aggregate_invocation_paths(invocation_path)
    if any(
        _as_int(bucket.get("pre_optimization_bytes"))
        or _as_int(bucket.get("saved_bytes"))
        or _as_int(bucket.get("saved_tokens"))
        or _as_int(bucket.get("count"))
        for bucket in out.values()
    ):
        return out
    return _aggregate_compaction_telemetry(invocation_path)


def _load_discover_report_for_summary(summary_path: str) -> Mapping[str, Any] | None:
    """Load discover-report.json adjacent to a summary, if present."""
    discover_path = os.path.join(os.path.dirname(summary_path), "discover-report.json")
    if not os.path.isfile(discover_path):
        return None
    try:
        with open(discover_path, encoding="utf-8") as handle:
            data = json.load(handle)
        if isinstance(data, Mapping):
            return data
    except (OSError, json.JSONDecodeError):
        pass
    return None


def _summary_plan_key(summary: Mapping[str, Any], summary_path: str) -> str:
    return str(summary.get("plan_key") or "").strip() or _run_id(summary, summary_path)


def _normalize_optimization_opportunities(
    discover: Mapping[str, Any],
) -> dict[str, Any] | None:
    """Extract a normalized optimization_opportunities block from discover report."""
    out: dict[str, Any] = {}

    missed = discover.get("missed_compaction_opportunities")
    if isinstance(missed, list) and missed:
        deduped: list[Any] = []
        seen: set[str] = set()
        for item in missed:
            if not isinstance(item, Mapping):
                continue
            try:
                key = json.dumps(item, sort_keys=True, separators=(",", ":"), ensure_ascii=False)
            except TypeError:
                key = repr(sorted(item.items()))
            if key in seen:
                continue
            seen.add(key)
            deduped.append(dict(item))
        if deduped:
            out["missed_compaction_opportunities"] = deduped

    patterns = discover.get("sequence_patterns")
    if isinstance(patterns, list) and patterns:
        out["sequence_patterns"] = patterns

    stored_usage = discover.get("stored_result_usage")
    if isinstance(stored_usage, Mapping):
        recommendation = stored_usage.get("recommendation")
        if recommendation:
            out["stored_result_usage"] = {"recommendation": recommendation}

    findings = discover.get("aggregate_findings")
    if isinstance(findings, list):
        native_read_findings = [
            f for f in findings
            if str(f.get("pattern_id") or "").startswith("heavy_native_read")
        ]
        if native_read_findings:
            out["native_read_findings"] = native_read_findings

    if not out:
        return None
    return out


def build_report(paths: Sequence[str]) -> dict[str, Any]:
    aggregate_paths = _empty_paths()
    aggregate_channels = _empty_channels()
    session_usage = {
        "input_tokens": 0,
        "output_tokens": 0,
        "cache_creation_input_tokens": 0,
        "cache_read_input_tokens": 0,
        "prompt_bytes": 0,
        "tool_calls_total": 0,
    }
    cache_read_tokens = 0
    cache_create_tokens = 0
    input_tokens = 0
    run_count = 0
    could_have_saved_bytes = 0
    skipped_summaries = 0
    started_at: datetime | None = None
    ended_at: datetime | None = None
    runs: list[dict[str, Any]] = []
    readback_totals = {
        "envelope_count": 0,
        "readback_count": 0,
        "raw_readback_count": 0,
        "compacted_readback_count": 0,
        "readback_bytes": 0,
        "envelope_original_bytes": 0,
        "full_preview_rereads": 0,
        "gross_readback_bytes": 0,
        "gross_readback_tokens": 0,
        "net_consumed_bytes": 0,
        "net_consumed_tokens": 0,
        "effective_windowing_savings_rate": 0.0,
    }

    optimization_opportunities: dict[str, Any] | None = None
    optimization_opportunities_source: dict[str, Any] | None = None
    discover_candidates: list[tuple[datetime | None, str, str, str | None]] = []

    for path in paths:
        try:
            summary = _load_summary(path)
        except (OSError, ValueError, json.JSONDecodeError) as exc:
            print(f"Warning: skipping unreadable summary {path}: {exc}", file=sys.stderr)
            skipped_summaries += 1
            continue
        run_count += max(0, _as_int(summary.get("invocations", summary.get("steps", 1))))
        input_tokens += _as_int(summary.get("input_tokens"))
        cache_create_tokens += _as_int(summary.get("cache_creation_input_tokens"))
        cache_read_tokens += _as_int(summary.get("cache_read_input_tokens"))
        could_have_saved_bytes += _as_int(summary.get("compaction_measured_not_applied_bytes"))
        session_usage["input_tokens"] += _as_int(summary.get("input_tokens"))
        session_usage["output_tokens"] += _as_int(summary.get("output_tokens"))
        session_usage["cache_creation_input_tokens"] += _as_int(
            summary.get("cache_creation_input_tokens")
        )
        session_usage["cache_read_input_tokens"] += _as_int(
            summary.get("cache_read_input_tokens")
        )
        session_usage["prompt_bytes"] += _as_int(summary.get("prompt_bytes"))
        session_usage["tool_calls_total"] += _as_int(summary.get("tool_calls_total"))

        start = _parse_ts(summary.get("started_at"))
        end = _parse_ts(summary.get("ended_at"))
        if start is not None and (started_at is None or start < started_at):
            started_at = start
        if end is not None and (ended_at is None or end > ended_at):
            ended_at = end

        summary_paths = _summary_paths(summary, path)
        readback_stats: dict[str, Any] = {}
        windowing_log = _windowing_log_for_summary(path)
        plan_key = _summary_plan_key(summary, path)
        if windowing_log is not None:
            readback_stats = analyze_result_windowing_log(
                windowing_log, plan_key=plan_key
            )
            for key in readback_totals:
                if key in readback_stats:
                    # Ratio fields are recalculated from totals at the end;
                    # summing floats with _as_int would zero them out.
                    if key in ("raw_readback_share", "readback_negation_rate",
                               "effective_windowing_savings_rate"):
                        continue
                    readback_totals[key] += _as_int(readback_stats.get(key))

        run_windowing_totals = _aggregate_windowing_from_summary(summary)

        for path_name in SAVINGS_PATH_NAMES:
            bucket = summary_paths[path_name]
            status = _savings_path_status(path_name, bucket, readback_stats)
            bucket["status"] = status
            bucket["status_label"] = _path_status_label(status)

        _enrich_path_diagnostics(
            summary_paths,
            readback_stats,
            _as_int(summary.get("compaction_measured_not_applied_bytes")),
        )

        run_per_path, run_saved_bytes, run_saved_tokens, run_pre_bytes = _finalize_path_buckets(
            summary_paths
        )
        run_channels = _summary_channels(summary, path, plan_key)
        run_readback_by_channel = (
            _windowing_readback_by_channel(windowing_log, plan_key=plan_key)
            if windowing_log is not None
            else None
        )
        _enrich_channel_diagnostics(run_channels, run_readback_by_channel)
        run_tool_output = _build_tool_output_counterfactual(
            summary_paths, run_windowing_totals, _as_int(summary.get("compaction_measured_not_applied_bytes"))
        )
        runs.append(
            {
                "id": _run_id(summary, path),
                "plan_key": plan_key,
                "started_at": _isoformat(start),
                "ended_at": _isoformat(end),
                "saved_bytes": run_saved_bytes,
                "saved_tokens": run_saved_tokens,
                "pre_optimization_bytes": run_pre_bytes,
                "savings_percent": round((run_saved_bytes / run_pre_bytes) * 100, 1)
                if run_pre_bytes > 0
                else 0,
                "per_path": run_per_path,
                "per_channel": run_channels,
                "tool_output_counterfactual": run_tool_output,
                "session_usage": {
                    "input_tokens": _as_int(summary.get("input_tokens")),
                    "output_tokens": _as_int(summary.get("output_tokens")),
                    "cache_creation_input_tokens": _as_int(
                        summary.get("cache_creation_input_tokens")
                    ),
                    "cache_read_input_tokens": _as_int(summary.get("cache_read_input_tokens")),
                    "prompt_bytes": _as_int(summary.get("prompt_bytes")),
                    "tool_calls_total": _as_int(summary.get("tool_calls_total")),
                },
            }
        )
        discover_candidates.append((_parse_ts(summary.get("ended_at")), path, plan_key, _isoformat(end)))
        for path_name in SAVINGS_PATH_NAMES:
            _merge_bucket(aggregate_paths[path_name], summary_paths[path_name])
        for channel_name in WINDOWING_CHANNEL_NAMES:
            _merge_channel_bucket(
                aggregate_channels[channel_name],
                run_channels[channel_name],
            )

    discover_candidates.sort(
        key=lambda item: (
            item[0] is not None,
            item[0] or datetime.min.replace(tzinfo=timezone.utc),
        ),
        reverse=True,
    )
    for _ended_at, summary_path, plan_key, ended_at_iso in discover_candidates:
        discover_data = _load_discover_report_for_summary(summary_path)
        if discover_data is not None:
            normalized = _normalize_optimization_opportunities(discover_data)
            if normalized:
                optimization_opportunities = normalized
                optimization_opportunities_source = {
                    "plan_key": plan_key,
                    "ended_at": ended_at_iso,
                }
                break

    saved_bytes = 0
    saved_tokens = 0
    pre_optimization_bytes = 0
    per_path: dict[str, dict[str, int | float]] = {}
    aggregate_windowing_totals = _aggregate_windowing_from_summary({})
    for path_name in SAVINGS_PATH_NAMES:
        bucket = aggregate_paths[path_name]
        finalize_savings_bucket(bucket)
        status = _savings_path_status(path_name, bucket, readback_totals)
        bucket["status"] = status
        bucket["status_label"] = _path_status_label(status)
        per_path[path_name] = bucket
        saved_bytes += _as_int(bucket.get("saved_bytes"))
        saved_tokens += _as_int(bucket.get("saved_tokens"))
        pre_optimization_bytes += _as_int(bucket.get("pre_optimization_bytes"))
        if path_name == "result_windowing":
            aggregate_windowing_totals["original_bytes"] = _as_int(
                bucket.get("pre_optimization_bytes")
            )
            aggregate_windowing_totals["saved_bytes"] = _as_int(bucket.get("saved_bytes"))
            aggregate_windowing_totals["returned_bytes"] = _as_int(
                bucket.get("post_optimization_bytes")
            )
            aggregate_windowing_totals["original_tokens"] = _as_int(
                bucket.get("pre_optimization_tokens")
            )
            aggregate_windowing_totals["saved_tokens"] = _as_int(bucket.get("saved_tokens"))
            aggregate_windowing_totals["returned_tokens"] = _as_int(
                bucket.get("post_optimization_tokens")
            )

    _enrich_path_diagnostics(per_path, readback_totals, could_have_saved_bytes)

    per_channel = _finalize_channel_buckets(aggregate_channels)
    aggregate_readback_by_channel: dict[str, dict[str, int]] = {
        channel: {
            "gross_readback_bytes": 0,
            "gross_readback_tokens": 0,
            "net_consumed_bytes": 0,
            "net_consumed_tokens": 0,
        }
        for channel in WINDOWING_CHANNEL_NAMES
    }
    for run in runs:
        run_channels = run.get("per_channel")
        if not isinstance(run_channels, Mapping):
            continue
        for channel_name in WINDOWING_CHANNEL_NAMES:
            bucket = run_channels.get(channel_name)
            if not isinstance(bucket, Mapping):
                continue
            target = aggregate_readback_by_channel[channel_name]
            target["gross_readback_bytes"] += _as_int(bucket.get("gross_readback_bytes"))
            target["gross_readback_tokens"] += _as_int(bucket.get("gross_readback_tokens"))
            target["net_consumed_bytes"] += _as_int(bucket.get("net_consumed_bytes"))
            target["net_consumed_tokens"] += _as_int(bucket.get("net_consumed_tokens"))
    _enrich_channel_diagnostics(per_channel, aggregate_readback_by_channel)

    # Compute aggregate readback metrics from the net-windowing module values.
    net_consumed_bytes = _as_int(readback_totals.get("net_consumed_bytes"))
    net_consumed_tokens = _as_int(readback_totals.get("net_consumed_tokens"))
    gross_readback_bytes = _as_int(readback_totals.get("gross_readback_bytes"))
    gross_readback_tokens = _as_int(readback_totals.get("gross_readback_tokens"))
    effective_windowing_savings_rate = float(
        readback_totals.get("effective_windowing_savings_rate") or 0
    )

    tool_output_counterfactual = _build_tool_output_counterfactual(
        per_path, aggregate_windowing_totals, could_have_saved_bytes
    )

    savings_percent = round((saved_bytes / pre_optimization_bytes) * 100, 1) if pre_optimization_bytes > 0 else 0
    cache_aggregate = aggregate_records(
        [
            {
                "input_tokens": input_tokens,
                "cache_creation_input_tokens": cache_create_tokens,
                "cache_read_input_tokens": cache_read_tokens,
                "output_tokens": session_usage["output_tokens"],
            }
        ]
    )
    cache_hit_ratio = cache_aggregate["cache_efficiency_ratio"]
    session_usage.update(
        {
            "uncached_input_tokens": cache_aggregate["uncached_input_tokens"],
            "total_input_tokens": cache_aggregate["total_input_tokens"],
            "cache_efficiency_ratio": cache_aggregate["cache_efficiency_ratio"],
        }
    )

    raw_share = (
        round(readback_totals["raw_readback_count"] / readback_totals["readback_count"], 4)
        if readback_totals["readback_count"] > 0
        else 0.0
    )
    negation_rate = (
        round(readback_totals["readback_bytes"] / readback_totals["envelope_original_bytes"], 4)
        if readback_totals["envelope_original_bytes"] > 0
        else 0.0
    )
    effective_windowing_savings_rate = (
        round(
            (readback_totals["envelope_original_bytes"] - readback_totals["net_consumed_bytes"])
            / readback_totals["envelope_original_bytes"],
            4,
        )
        if readback_totals["envelope_original_bytes"] > 0
        else 0.0
    )

    return {
        "schema_version": 2,
        "kind": "ralph_benchmark_report",
        "run_count": run_count,
        "date_range": {
            "started_at": _isoformat(started_at),
            "ended_at": _isoformat(ended_at),
        },
        "saved_bytes": saved_bytes,
        "saved_tokens": saved_tokens,
        "savings_percent": savings_percent,
        "session_usage": session_usage,
        "tool_output_counterfactual": tool_output_counterfactual,
        "per_path": per_path,
        "per_channel": per_channel,
        "readback_summary": {
            "envelope_count": readback_totals["envelope_count"],
            "readback_count": readback_totals["readback_count"],
            "raw_readback_count": readback_totals["raw_readback_count"],
            "compacted_readback_count": readback_totals["compacted_readback_count"],
            "readback_bytes": readback_totals["readback_bytes"],
            "envelope_original_bytes": readback_totals["envelope_original_bytes"],
            "full_preview_rereads": readback_totals["full_preview_rereads"],
            "raw_readback_share": raw_share,
            "readback_negation_rate": negation_rate,
            "gross_readback_bytes": gross_readback_bytes,
            "gross_readback_tokens": gross_readback_tokens,
            "net_consumed_bytes": net_consumed_bytes,
            "net_consumed_tokens": net_consumed_tokens,
            "effective_windowing_savings_rate": effective_windowing_savings_rate,
        },
        "cache": {
            "cache_read_tokens": cache_read_tokens,
            "cache_hit_ratio": cache_hit_ratio,
        },
        "could_have_saved": {
            "compaction_measured_not_applied_bytes": could_have_saved_bytes,
        },
        "optimization_opportunities": optimization_opportunities,
        "optimization_opportunities_source": optimization_opportunities_source,
        "skipped_summaries": skipped_summaries,
        "runs_count": len(runs),
        "runs": runs,
    }


def main(argv: Sequence[str] | None = None) -> int:
    args = list(sys.argv[1:] if argv is None else argv)
    if not args or args[0] in ("-h", "--help"):
        print(
            "Usage: ralph-benchmark-report.py plan-usage-summary.json [more-summary-paths...]",
            file=sys.stderr,
        )
        return 0 if args else 2

    try:
        report = build_report(args)
    except (OSError, ValueError, json.JSONDecodeError) as exc:
        print(f"Error: {exc}", file=sys.stderr)
        return 1

    json.dump(report, sys.stdout, indent=2)
    sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
