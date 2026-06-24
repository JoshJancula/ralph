#!/usr/bin/env python3
"""Build a lightweight discover report from invocation-usage.json.

Only reports patterns supported by existing usage fields (tool names, sequences,
counters, token/cache metrics). Whole-file-read detection is intentionally omitted
until sanitized tool arguments exist.
"""

from __future__ import annotations

import argparse
import json
import os
import sys
from datetime import datetime, timezone
from typing import Any, Dict, List, Mapping, MutableMapping, Optional, Sequence, Tuple

sys.path.insert(0, os.path.dirname(__file__))

from tool_call_classification import (
    SAVINGS_PATH_NAMES,
    classify_tool_calls,
    empty_savings_bucket,
    finalize_savings_bucket,
    merge_savings_buckets,
    savings_from_path_data,
)
from result_windowing_metrics import (
    analyze_result_windowing_log,
    stored_result_readback_guidance,
)
from usage_accounting import normalize_usage
from tool_call_target_telemetry import (
    result_windowing_log_path,
    scan_sequence_antipatterns,
    sequence_antipattern_recommendation,
)

_SCHEMA_VERSION = 1
_HIGH_TOKEN_INPUT_THRESHOLD = 50_000
_LOW_CACHE_HIT_RATIO = 0.15
_HEAVY_NATIVE_READ_RATIO = 0.70
_MIN_READ_TOOLS_FOR_RATIO = 5
_LARGE_OUTPUT_THRESHOLD = 5_000
_LOW_SAVINGS_PERCENT_THRESHOLD = 10
_MIN_BYTES_FOR_SAVINGS_ANALYSIS = 1_000
_SHELL_STATUS_POLL_MIN_CALLS = 3
_SHELL_STATUS_POLL_RATIO = 2


def _lower_label(label: Any) -> str:
    return (str(label or "")).strip().lower()


def _is_proxy_label(label: str) -> bool:
    lower = _lower_label(label)
    return "ralph_proxy" in lower or lower.startswith("mcp__ralph__")


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


def _as_bool(value: Any) -> bool:
    if isinstance(value, bool):
        return value
    text = str(value or "").strip().lower()
    if not text:
        return False
    return text in ("1", "true", "yes", "on")


def _invocation_index(record: Mapping[str, Any], fallback: int) -> int:
    for key in ("iteration", "todo_ordinal"):
        if key in record:
            try:
                return int(record[key])
            except (TypeError, ValueError):
                pass
    return fallback


def _runtime_tool_access_rows(
    invocations: Sequence[Mapping[str, Any]],
) -> List[Dict[str, Any]]:
    grouped: Dict[str, MutableMapping[str, int]] = {}
    for record in invocations:
        runtime = str(record.get("runtime") or "unknown")
        tool_access = str(record.get("agent_tool_access") or "unknown")
        bucket_key = f"{runtime}|{tool_access}"
        bucket = grouped.setdefault(
            bucket_key,
            {
                "runtime": runtime,
                "agent_tool_access": tool_access,
                "invocations": 0,
                "tool_calls_total": 0,
                "native_read_like_calls": 0,
                "native_search_calls": 0,
                "native_shell_calls": 0,
                "ralph_proxy_calls": 0,
                "other_mcp_calls": 0,
                "native_write_like_calls": 0,
            },
        )
        bucket["invocations"] += 1
        bucket["tool_calls_total"] += _as_int(record.get("tool_calls_total"))
        for key in (
            "native_read_like_calls",
            "native_search_calls",
            "native_shell_calls",
            "ralph_proxy_calls",
            "other_mcp_calls",
            "native_write_like_calls",
        ):
            bucket[key] += _as_int(record.get(key))
    rows: List[Dict[str, Any]] = []
    for bucket_key in sorted(grouped):
        bucket = grouped[bucket_key]
        read_total = bucket["native_read_like_calls"] + bucket["ralph_proxy_calls"]
        native_share = 0.0
        if read_total > 0:
            native_share = round(bucket["native_read_like_calls"] / read_total, 4)
        proxy_adoption = 0.0
        explore_total = bucket["ralph_proxy_calls"] + bucket["native_search_calls"] + bucket["native_shell_calls"]
        if explore_total > 0:
            proxy_adoption = round(bucket["ralph_proxy_calls"] / explore_total, 4)
        rows.append(
            {
                **bucket,
                "native_read_share": native_share,
                "ralph_proxy_adoption_share": proxy_adoption,
            }
        )
    return rows


def _high_token_low_cache_invocations(
    invocations: Sequence[Mapping[str, Any]],
) -> List[Dict[str, Any]]:
    flagged: List[Dict[str, Any]] = []
    for idx, record in enumerate(invocations):
        canonical = normalize_usage(record)
        input_tokens = canonical["uncached_input_tokens"]
        if input_tokens < _HIGH_TOKEN_INPUT_THRESHOLD:
            continue
        ratio = float(canonical.get("cache_efficiency_ratio") or canonical.get("cache_hit_ratio") or 0)
        if ratio >= _LOW_CACHE_HIT_RATIO:
            continue
        flagged.append(
            {
                "invocation_ref": _invocation_index(record, idx + 1),
                "runtime": str(record.get("runtime") or ""),
                "model": str(record.get("model") or ""),
                "input_tokens": input_tokens,
                "uncached_input_tokens": canonical["uncached_input_tokens"],
                "total_input_tokens": canonical["total_input_tokens"],
                "cache_efficiency_ratio": ratio,
                "cache_hit_ratio": ratio,
                "measurement_source": canonical.get("measurement_source", {}),
                "cache_read_input_tokens": canonical["cache_read_input_tokens"],
                "cache_creation_input_tokens": canonical["cache_creation_input_tokens"],
            }
        )
    return flagged


def _summarize_patterns(findings: Sequence[Mapping[str, Any]]) -> List[Dict[str, Any]]:
    counts: Dict[str, int] = {}
    for item in findings:
        pid = str(item.get("pattern_id") or "")
        if pid:
            counts[pid] = counts.get(pid, 0) + 1
    summaries: List[Dict[str, Any]] = []
    descriptions = {
        "repeated_native_read_like": "Consecutive native read/search tool calls in tool_calls_sequence",
        "native_read_after_grep": "Native read immediately after grep in tool_calls_sequence",
        "repeated_shell_status_polling": "Excessive ralph_proxy_shell_status calls without matching shell_wait or verification delegation",
    }
    for pid in sorted(counts):
        summaries.append(
            {
                "pattern_id": pid,
                "count": counts[pid],
                "description": descriptions.get(pid, ""),
                "recommendation": sequence_antipattern_recommendation(pid),
            }
        )
    return summaries


def _large_uncompacted_outputs(
    invocations: Sequence[Mapping[str, Any]],
) -> List[Dict[str, Any]]:
    """Identify large outputs that were not compacted (missed savings opportunities)."""
    findings: List[Dict[str, Any]] = []
    for idx, record in enumerate(invocations):
        compaction_records = record.get("compaction_telemetry") or []
        if not isinstance(compaction_records, list):
            continue
        for telemetry in compaction_records:
            if not isinstance(telemetry, Mapping):
                continue
            original_bytes = _telemetry_int(telemetry, "original_bytes", "originalBytes")
            compacted_bytes = _telemetry_int(telemetry, "compacted_bytes", "compactedBytes")
            compaction_skipped = _telemetry_bool(
                telemetry, "compaction_skipped", "compactionSkipped"
            )
            family = str(telemetry.get("family") or "")
            command_hash = str(telemetry.get("command_hash") or "")
            skip_reason = str(
                telemetry.get("skip_reason") or telemetry.get("skipReason") or ""
            )
            if (
                original_bytes >= _LARGE_OUTPUT_THRESHOLD
                and compaction_skipped is True
            ):
                findings.append(
                    {
                        "invocation_ref": _invocation_index(record, idx + 1),
                        "original_bytes": original_bytes,
                        "family": family if family else None,
                        "command_hash": command_hash if command_hash else None,
                        "skip_reason": skip_reason if skip_reason else None,
                        "skip_type": "compaction_skipped",
                    }
                )
            elif (
                original_bytes >= _LARGE_OUTPUT_THRESHOLD
                and not compaction_skipped
                and compacted_bytes > 0
            ):
                savings_percent = round(
                    (1 - compacted_bytes / original_bytes) * 100, 1
                )
                if savings_percent < _LOW_SAVINGS_PERCENT_THRESHOLD:
                    findings.append(
                        {
                            "invocation_ref": _invocation_index(record, idx + 1),
                            "original_bytes": original_bytes,
                            "compacted_bytes": compacted_bytes,
                            "savings_percent": savings_percent,
                            "family": family,
                            "command_hash": command_hash if command_hash else None,
                            "skip_type": "low_savings",
                        }
                    )
    return findings


def _ralph_mode_adoption_findings(
    invocations: Sequence[Mapping[str, Any]],
) -> List[Dict[str, Any]]:
    findings: List[Dict[str, Any]] = []
    for idx, record in enumerate(invocations):
        if str(record.get("agent_tool_access") or "") != "ralph":
            continue
        native_search = _as_int(record.get("native_search_calls"))
        native_shell = _as_int(record.get("native_shell_calls"))
        native_file_read = _as_int(record.get("native_file_read_calls"))
        compat_read = _as_int(record.get("native_read_compatibility_calls"))
        proxy = _as_int(record.get("ralph_proxy_calls"))
        native_write = _as_int(record.get("native_write_like_calls"))
        explore_native = native_search + native_shell + native_file_read
        if explore_native <= 0:
            continue
        hook_compactions = _as_int(record.get("hook_compactions", 0))
        hook_original_bytes = _as_int(record.get("hook_original_bytes", 0))
        proxy_shell_compactions = _as_int(record.get("proxy_shell_compactions", 0))
        proxy_shell_original_bytes = _as_int(record.get("proxy_shell_original_bytes", 0))
        hook_compacted = hook_compactions > 0 and hook_original_bytes > 0
        proxy_compacted = proxy_shell_compactions > 0 and proxy_shell_original_bytes > 0
        compaction_proven = hook_compacted or proxy_compacted
        edit_adjacent_pattern = (native_file_read > 0 and native_shell == 0 and native_search == 0 and native_write > 0)
        if compaction_proven or edit_adjacent_pattern:
            continue
        findings.append(
            {
                "pattern_id": "ralph_mode_native_explore_tools",
                "invocation_ref": _invocation_index(record, idx + 1),
                "runtime": str(record.get("runtime") or ""),
                "ralph_proxy_calls": proxy,
                "native_search_calls": native_search,
                "native_shell_calls": native_shell,
                "native_file_read_calls": native_file_read,
                "native_read_compatibility_calls": compat_read,
                "native_write_like_calls": native_write,
            }
        )
    return findings


def _native_shell_bypass_findings(
    invocations: Sequence[Mapping[str, Any]],
) -> List[Dict[str, Any]]:
    findings: List[Dict[str, Any]] = []
    for idx, record in enumerate(invocations):
        if str(record.get("agent_tool_access") or "") != "ralph":
            continue
        shell_calls = _as_int(record.get("native_shell_calls"))
        if shell_calls <= 0:
            continue
        proxy_shell = 0
        by_tool = record.get("tool_calls_by_tool")
        if isinstance(by_tool, Mapping):
            for name, count in by_tool.items():
                lower = _lower_label(name)
                if "ralph_proxy_shell" in lower:
                    proxy_shell += _as_int(count)
        hook_compactions = _as_int(record.get("hook_compactions", 0))
        proxy_shell_compactions = _as_int(record.get("proxy_shell_compactions", 0))
        hook_original_bytes = _as_int(record.get("hook_original_bytes", 0))
        proxy_shell_original_bytes = _as_int(record.get("proxy_shell_original_bytes", 0))
        hook_compacted = hook_compactions > 0 and hook_original_bytes > 0
        proxy_compacted = proxy_shell_compactions > 0 and proxy_shell_original_bytes > 0
        compaction_proven = hook_compacted or proxy_compacted
        if compaction_proven:
            continue
        findings.append(
            {
                "pattern_id": "native_shell_bypassed_compaction",
                "invocation_ref": _invocation_index(record, idx + 1),
                "runtime": str(record.get("runtime") or ""),
                "native_shell_calls": shell_calls,
                "ralph_proxy_shell_calls": proxy_shell,
                "note": "Native shell used without proven compaction (prefer ralph_proxy_shell for compaction)",
            }
        )
    return findings


def _async_shell_polling_findings(
    invocations: Sequence[Mapping[str, Any]],
) -> List[Dict[str, Any]]:
    """Flag invocations dominated by ralph_proxy_shell_status polling instead of shell_wait."""
    findings: List[Dict[str, Any]] = []
    for idx, record in enumerate(invocations):
        by_tool = record.get("tool_calls_by_tool")
        if not isinstance(by_tool, Mapping):
            continue
        status_calls = 0
        wait_calls = 0
        start_calls = 0
        for name, count in by_tool.items():
            lower = _lower_label(name)
            if "ralph_proxy_shell_status" in lower:
                status_calls += _as_int(count)
            elif "ralph_proxy_shell_wait" in lower:
                wait_calls += _as_int(count)
            elif "ralph_proxy_shell_start" in lower:
                start_calls += _as_int(count)
        if status_calls < _SHELL_STATUS_POLL_MIN_CALLS:
            continue
        if status_calls <= (wait_calls + start_calls) * _SHELL_STATUS_POLL_RATIO:
            continue
        findings.append(
            {
                "pattern_id": "repeated_shell_status_polling",
                "invocation_ref": _invocation_index(record, idx + 1),
                "runtime": str(record.get("runtime") or ""),
                "ralph_proxy_shell_status_calls": status_calls,
                "ralph_proxy_shell_wait_calls": wait_calls,
                "ralph_proxy_shell_start_calls": start_calls,
                "note": "Repeated ralph_proxy_shell_status polling; prefer ralph_proxy_shell_wait to block server-side, or declare verification commands in TODO metadata so the runner executes them out-of-process",
            }
        )
    return findings


def _telemetry_plan_key(telemetry: Mapping[str, Any]) -> str:
    return str(telemetry.get("plan_key") or telemetry.get("planKey") or "").strip()


def _telemetry_int(telemetry: Mapping[str, Any], *names: str) -> int:
    for name in names:
        if name in telemetry:
            return _as_int(telemetry[name])
    return 0


def _telemetry_bool(telemetry: Mapping[str, Any], *names: str) -> bool:
    for name in names:
        if name in telemetry:
            return _as_bool(telemetry[name])
    return False


def _telemetry_signature(
    plan_key: str, telemetry: Mapping[str, Any]
) -> Tuple[str, str, str, str, str, int, int, bool, str]:
    return (
        plan_key or "",
        _telemetry_plan_key(telemetry),
        str(telemetry.get("timestamp") or ""),
        str(telemetry.get("storage_path") or telemetry.get("storagePath") or ""),
        str(telemetry.get("command_hash") or telemetry.get("commandHash") or ""),
        str(telemetry.get("family") or ""),
        _telemetry_int(telemetry, "original_bytes", "originalBytes"),
        _telemetry_int(telemetry, "compacted_bytes", "compactedBytes"),
        _telemetry_bool(telemetry, "compaction_skipped", "compactionSkipped"),
        str(telemetry.get("exit_code") or telemetry.get("exitCode") or ""),
    )


def _summarize_byte_savings_by_path(
    invocations: Sequence[Mapping[str, Any]],
    plan_key: str = "",
) -> Dict[str, Any]:
    """Summarize byte and estimated-token savings by optimization path across invocations.

    The runtime overlay writes each invocation's byte_savings_by_path as a
    cumulative running total (it re-reads the whole telemetry log every
    iteration). Summing those snapshots across iterations multiplies the real
    savings, so we key only by (plan_key, path_name) and keep the final
    cumulative snapshot rather than summing.
    """
    summary: Dict[str, Any] = {
        path_name: empty_savings_bucket(
            include_hidden=path_name
            in ("hook_compaction", "proxy_shell_compaction", "result_windowing")
        )
        for path_name in SAVINGS_PATH_NAMES
    }
    target_plan_key = str(plan_key or "").strip()

    # Keep the final cumulative snapshot per (plan_key, path_name). These
    # totals can decrease when later readbacks consume raw/full stored results,
    # so the last record wins, matching ralph-benchmark-report.py semantics.
    latest: Dict[Tuple[str, str], Dict[str, Any]] = {}
    for record in invocations:
        byte_savings = record.get("byte_savings_by_path")
        if not isinstance(byte_savings, dict):
            continue
        record_plan = str(record.get("plan_key") or "").strip()
        if target_plan_key and record_plan and record_plan != target_plan_key:
            continue

        for path_name, path_data in byte_savings.items():
            if not isinstance(path_data, dict):
                continue
            if path_name not in summary:
                continue
            key = (target_plan_key or record_plan, path_name)
            latest[key] = savings_from_path_data(path_data)

    for (_key_plan, path_name), path_bucket in latest.items():
        merge_savings_buckets({path_name: summary[path_name]}, {path_name: path_bucket})

    for path_name in summary:
        finalize_savings_bucket(summary[path_name])

    return summary


def _summarize_compaction_telemetry(
    invocations: Sequence[Mapping[str, Any]],
    plan_key: str = "",
) -> Dict[str, Any]:
    """Summarize compaction telemetry across invocations."""
    summary: Dict[str, object] = {
        "total_compaction_records": 0,
        "total_original_bytes": 0,
        "total_compacted_bytes": 0,
        "total_original_tokens": 0,
        "total_compacted_tokens": 0,
        "token_cap_triggers": 0,
        "compactions_applied": 0,
        "compactions_skipped": 0,
        "by_family": {},
        "skip_reasons": {},
    }
    target_plan_key = str(plan_key or "").strip()
    seen: set[Tuple[str, str, str, str, str, int, int, bool, str]] = set()
    for record in invocations:
        compaction_records = record.get("compaction_telemetry") or []
        if not isinstance(compaction_records, list):
            continue
        for telemetry in compaction_records:
            if not isinstance(telemetry, Mapping):
                continue
            telemetry_plan = _telemetry_plan_key(telemetry)
            if target_plan_key and telemetry_plan and telemetry_plan != target_plan_key:
                continue
            key = _telemetry_signature(target_plan_key, telemetry)
            if key in seen:
                continue
            seen.add(key)
            summary["total_compaction_records"] = _as_int(
                summary["total_compaction_records"]
            ) + 1
            original_bytes = _telemetry_int(telemetry, "original_bytes", "originalBytes")
            original_tokens = _telemetry_int(telemetry, "original_tokens", "originalTokens")
            if _telemetry_bool(telemetry, "token_cap_triggered", "tokenCapTriggered"):
                summary["token_cap_triggers"] = _as_int(summary["token_cap_triggers"]) + 1
            summary["total_original_bytes"] = _as_int(
                summary["total_original_bytes"]
            ) + original_bytes
            if original_tokens > 0:
                summary["total_original_tokens"] = _as_int(
                    summary["total_original_tokens"]
                ) + original_tokens
            compaction_skipped = _telemetry_bool(
                telemetry, "compaction_skipped", "compactionSkipped"
            )
            if not compaction_skipped:
                compacted_bytes = _telemetry_int(
                    telemetry, "compacted_bytes", "compactedBytes"
                )
                compacted_tokens = _telemetry_int(
                    telemetry, "compacted_tokens", "compactedTokens"
                )
                summary["total_compacted_bytes"] = _as_int(
                    summary["total_compacted_bytes"]
                ) + compacted_bytes
                if compacted_tokens > 0:
                    summary["total_compacted_tokens"] = _as_int(
                        summary["total_compacted_tokens"]
                    ) + compacted_tokens
                summary["compactions_applied"] = _as_int(
                    summary["compactions_applied"]
                ) + 1
            else:
                summary["compactions_skipped"] = _as_int(
                    summary["compactions_skipped"]
                ) + 1
                skip_reason = str(
                    telemetry.get("skip_reason") or telemetry.get("skipReason") or ""
                )
                if skip_reason:
                    by_reason = summary["skip_reasons"]
                    if isinstance(by_reason, dict):
                        by_reason[skip_reason] = _as_int(
                            by_reason.get(skip_reason)
                        ) + 1
            family = str(telemetry.get("family") or "unknown")
            by_family = summary["by_family"]
            if isinstance(by_family, dict):
                if family not in by_family:
                    by_family[family] = {
                        "total": 0,
                        "compacted": 0,
                        "skipped": 0,
                        "total_bytes": 0,
                        "compacted_bytes": 0,
                    }
                family_entry = by_family[family]
                if isinstance(family_entry, dict):
                    family_entry["total"] = _as_int(family_entry.get("total")) + 1
                    family_entry["total_bytes"] = _as_int(
                        family_entry.get("total_bytes")
                    ) + original_bytes
                    if not compaction_skipped:
                        family_entry["compacted"] = _as_int(
                            family_entry.get("compacted")
                        ) + 1
                        compacted_bytes = _telemetry_int(
                            telemetry, "compacted_bytes", "compactedBytes"
                        )
                        family_entry["compacted_bytes"] = _as_int(
                            family_entry.get("compacted_bytes")
                        ) + compacted_bytes
                    else:
                        family_entry["skipped"] = _as_int(
                            family_entry.get("skipped")
                        ) + 1
    if _as_int(summary["total_original_bytes"]) > 0:
        total_original = _as_int(summary["total_original_bytes"])
        total_compacted = _as_int(summary["total_compacted_bytes"])
        summary["total_savings_percent"] = round(
            (1 - total_compacted / total_original) * 100, 1
        )
    if _as_int(summary["total_original_tokens"]) > 0:
        total_original_tokens = _as_int(summary["total_original_tokens"])
        total_compacted_tokens = _as_int(summary["total_compacted_tokens"])
        summary["total_savings_percent_tokens"] = round(
            (1 - total_compacted_tokens / total_original_tokens) * 100, 1
        )
    return summary


def build_discover_report(
    usage_doc: Mapping[str, Any],
    *,
    plan_key: str = "",
) -> Dict[str, Any]:
    invocations_raw = usage_doc.get("invocations")
    invocations: List[Mapping[str, Any]] = (
        [item for item in invocations_raw if isinstance(item, Mapping)]
        if isinstance(invocations_raw, list)
        else []
    )
    if plan_key:
        filtered = []
        for item in invocations:
            record_plan = str(item.get("plan_key") or "").strip()
            if not record_plan or record_plan == plan_key:
                filtered.append(item)
        invocations = filtered

    sequence_findings: List[Dict[str, Any]] = []
    totals = {
        "invocations": len(invocations),
        "tool_calls_total": 0,
        "native_read_like_calls": 0,
        "ralph_proxy_calls": 0,
        "other_mcp_calls": 0,
        "native_write_like_calls": 0,
        "proxy_read_bytes": 0,
    }

    for idx, record in enumerate(invocations):
        ref = _invocation_index(record, idx + 1)
        totals["tool_calls_total"] += _as_int(record.get("tool_calls_total"))
        for key in (
            "native_read_like_calls",
            "ralph_proxy_calls",
            "other_mcp_calls",
            "native_write_like_calls",
        ):
            totals[key] += _as_int(record.get(key))
        totals["proxy_read_bytes"] += _as_int(record.get("proxy_read_bytes"))

        seq = record.get("tool_calls_sequence")
        if isinstance(seq, list) and len(seq) >= 2:
            sequence_findings.extend(scan_sequence_antipatterns(seq, invocation_ref=ref))

    read_tools = totals["native_read_like_calls"] + totals["ralph_proxy_calls"]
    native_read_share = 0.0
    if read_tools > 0:
        native_read_share = round(totals["native_read_like_calls"] / read_tools, 4)

    aggregate_findings: List[Dict[str, Any]] = []
    if (
        read_tools >= _MIN_READ_TOOLS_FOR_RATIO
        and native_read_share >= _HEAVY_NATIVE_READ_RATIO
        and totals["ralph_proxy_calls"] == 0
    ):
        aggregate_findings.append(
            {
                "pattern_id": "heavy_native_read_no_proxy",
                "native_read_like_calls": totals["native_read_like_calls"],
                "ralph_proxy_calls": totals["ralph_proxy_calls"],
                "native_read_share": native_read_share,
            }
        )
    elif (
        read_tools >= _MIN_READ_TOOLS_FOR_RATIO
        and native_read_share >= _HEAVY_NATIVE_READ_RATIO
    ):
        aggregate_findings.append(
            {
                "pattern_id": "heavy_native_read_vs_proxy",
                "native_read_like_calls": totals["native_read_like_calls"],
                "ralph_proxy_calls": totals["ralph_proxy_calls"],
                "native_read_share": native_read_share,
            }
        )

    runtime_rows = _runtime_tool_access_rows(invocations)
    runtime_differences: List[Dict[str, Any]] = []
    if len(runtime_rows) >= 2:
        shares = [row["native_read_share"] for row in runtime_rows]
        spread = max(shares) - min(shares)
        if spread >= 0.25:
            runtime_differences.append(
                {
                    "pattern_id": "runtime_native_read_share_spread",
                    "spread": round(spread, 4),
                    "runtimes": [
                        {
                            "runtime": row["runtime"],
                            "agent_tool_access": row.get("agent_tool_access"),
                            "native_read_share": row["native_read_share"],
                            "native_read_like_calls": row["native_read_like_calls"],
                            "ralph_proxy_calls": row["ralph_proxy_calls"],
                        }
                        for row in runtime_rows
                    ],
                }
            )

    high_token_low_cache = _high_token_low_cache_invocations(invocations)
    compaction_summary = _summarize_compaction_telemetry(invocations, plan_key=plan_key)
    byte_savings_summary = _summarize_byte_savings_by_path(invocations, plan_key=plan_key)
    large_uncompacted = _large_uncompacted_outputs(invocations)
    ralph_mode_findings = _ralph_mode_adoption_findings(invocations)
    native_shell_bypass = _native_shell_bypass_findings(invocations)
    missed_savings = large_uncompacted + native_shell_bypass
    async_shell_polling_findings = _async_shell_polling_findings(invocations)

    stored_result_usage: Dict[str, Any] = {}
    windowing_path = result_windowing_log_path(plan_key=plan_key)
    if windowing_path is not None:
        stored_result_usage = analyze_result_windowing_log(windowing_path)
    seq_result_reads = 0
    seq_result_search = 0
    for record in invocations:
        seq = record.get("tool_calls_sequence")
        if not isinstance(seq, list):
            continue
        for label in seq:
            lower = str(label or "").lower()
            if "ralph_proxy_result_read" in lower:
                seq_result_reads += 1
            if "ralph_proxy_result_search" in lower:
                seq_result_search += 1
    stored_result_usage["sequence_result_read_calls"] = seq_result_reads
    stored_result_usage["sequence_result_search_calls"] = seq_result_search
    recommendation = stored_result_readback_guidance(stored_result_usage)
    if recommendation:
        stored_result_usage["recommendation"] = recommendation

    data_sources = [
        "tool_calls_sequence",
        "tool_call_counters",
        "token_usage",
        "cache_hit_ratio",
    ]
    if compaction_summary.get("total_compaction_records", 0) > 0:
        data_sources.append("compaction_telemetry")
    if any(v.get("count", 0) > 0 for v in byte_savings_summary.values()):
        data_sources.append("byte_savings_by_path")
    if stored_result_usage.get("readback_count", 0) > 0 or stored_result_usage.get(
        "envelope_count", 0
    ) > 0:
        data_sources.append("result_windowing_readbacks")

    aggregate_findings = list(aggregate_findings)

    return {
        "schema_version": _SCHEMA_VERSION,
        "kind": "discover_report",
        "generated_at": datetime.now(timezone.utc)
        .isoformat()
        .replace("+00:00", "Z"),
        "plan_key": plan_key,
        "data_sources": data_sources,
        "limitations": [
            "whole_file_reads: not available without sanitized tool arguments or ralph_proxy_result metadata"
        ],
        "totals": {**totals, "native_read_share": native_read_share},
        "sequence_patterns": _summarize_patterns(sequence_findings),
        "sequence_findings": sequence_findings,
        "aggregate_findings": aggregate_findings,
        "runtime_tool_access": runtime_rows,
        "runtime_differences": runtime_differences,
        "ralph_mode_adoption_findings": ralph_mode_findings,
        "async_shell_polling_findings": async_shell_polling_findings,
        "high_token_low_cache_invocations": high_token_low_cache,
        "compaction_summary": compaction_summary,
        "byte_savings_summary": byte_savings_summary,
        "missed_compaction_opportunities": missed_savings,
        "stored_result_usage": stored_result_usage,
    }


def write_discover_report(
    usage_path: str,
    output_path: str,
    *,
    plan_key: str = "",
) -> Dict[str, Any]:
    with open(usage_path, "r", encoding="utf-8") as fh:
        usage_doc = json.load(fh)
    if not isinstance(usage_doc, Mapping):
        raise ValueError("invalid invocation usage document")
    report = build_discover_report(usage_doc, plan_key=plan_key)
    os.makedirs(os.path.dirname(output_path) or ".", exist_ok=True)
    tmp = f"{output_path}.tmp.{os.getpid()}"
    with open(tmp, "w", encoding="utf-8") as fh:
        json.dump(report, fh, indent=2)
        fh.write("\n")
    os.replace(tmp, output_path)
    return report


def main(argv: Optional[Sequence[str]] = None) -> int:
    parser = argparse.ArgumentParser(description="Generate Ralph discover report JSON")
    parser.add_argument("--invocations", required=True, help="Path to invocation-usage.json")
    parser.add_argument("--output", required=True, help="Path to write discover-report.json")
    parser.add_argument("--plan-key", default="", help="Plan key for the report header")
    args = parser.parse_args(list(argv) if argv is not None else None)
    try:
        write_discover_report(args.invocations, args.output, plan_key=args.plan_key)
    except Exception as exc:
        sys.stderr.write(
            f"ralph-discover-report failed: {type(exc).__name__}: {exc}\n"
        )
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
