#!/usr/bin/env python3
"""Shared metrics for result-windowing stored-result logs.

Provides diagnostic and decision-grade fields for how much stored-result data
agents actually consume after envelope previews and follow-up readbacks.
Netting semantics: preview bytes plus follow-up readback bytes are capped at
the original envelope bytes/tokens before savings are computed, so a full raw
escalation collapses a result's savings to ~0.
"""

from __future__ import annotations

import json
from pathlib import Path
from typing import Any, Dict, List, Mapping, Sequence, Tuple

from tool_call_classification import (
    accumulate_savings_event,
    empty_savings_bucket,
    finalize_savings_bucket,
)

# Canonical optimization channel ids for result-windowing attribution.
WINDOWING_CHANNEL_NAMES = (
    "native_shell_hook",
    "proxy_shell",
    "native_result_hook",
    "native_result_mcp_fallback",
    "proxy_read_windowing",
    "proxy_search_windowing",
    "stored_result_readback",
)

CHANNEL_ATTRIBUTION_EXACT = "exact"
CHANNEL_ATTRIBUTION_LEGACY = "legacy"


def _coerce_int(value: Any, default: int = 0) -> int:
    if value in (None, ""):
        return default
    try:
        return int(value)  # type: ignore[arg-type]
    except (TypeError, ValueError):
        try:
            return int(float(value))  # type: ignore[arg-type]
        except (TypeError, ValueError):
            return default


def _estimate_tokens(bytes_count: int) -> int:
    """Rough byte-to-token estimate used when token fields are missing."""
    if bytes_count <= 0:
        return 0
    return max(1, (bytes_count + 3) // 4)


def _parse_envelope(record: Mapping[str, Any]) -> Dict[str, int] | None:
    result_id = str(record.get("resultId") or "").strip()
    if not result_id:
        return None

    # Prefer measurementVersion:2 inline-candidate/delivered fields for gross
    # and net context savings: inlineCandidateBytes is what was actually
    # eligible for inline delivery (post tool-level limits), deliveredBytes is
    # the final serialized envelope actually sent. Legacy originalBytes
    # (source/stored bytes) and returnedBytes (preview-only) overstate savings
    # when a source cap or large stored capture is present. Fall back to the
    # legacy fields, labeled accordingly, when v2 fields are absent.
    is_v2 = _coerce_int(record.get("measurementVersion")) == 2
    has_v2_fields = (
        record.get("inlineCandidateBytes") is not None
        and record.get("deliveredBytes") is not None
    )
    if is_v2 and has_v2_fields:
        original_bytes = _coerce_int(record.get("inlineCandidateBytes"))
        returned_bytes = _coerce_int(record.get("deliveredBytes"))
        original_tokens = _coerce_int(record.get("inlineCandidateTokens"))
        returned_tokens = _coerce_int(record.get("deliveredTokens"))
        measurement_quality = "v2_measured"
    else:
        original_bytes = _coerce_int(record.get("originalBytes"))
        returned_bytes = _coerce_int(record.get("returnedBytes"))
        original_tokens = _coerce_int(record.get("originalTokens"))
        returned_tokens = _coerce_int(record.get("returnedTokens"))
        measurement_quality = "legacy_storage_counterfactual"

    if original_tokens <= 0 and returned_tokens <= 0 and original_bytes > 0:
        original_tokens = _estimate_tokens(original_bytes)
        returned_tokens = _estimate_tokens(returned_bytes)
    return {
        "result_id": result_id,
        "original_bytes": original_bytes,
        "returned_bytes": returned_bytes,
        "original_tokens": original_tokens,
        "returned_tokens": returned_tokens,
        "token_cap_triggered": _coerce_int(
            record.get("tokenCapTriggered", record.get("token_cap_triggered"))
        )
        or 0,
        "channel": str(record.get("channel") or "").strip() or None,
        "measurement_quality": measurement_quality,
        "surfaced_tool": str(record.get("toolName") or "").strip() or "unknown",
        "source_capped": bool(record.get("sourceCapped") is True),
        "cap_reason": str(record.get("capReason") or "").strip() or None,
        "cap_limit_bytes": _coerce_int(record.get("capLimitBytes")) or None,
        "stored_bytes": _coerce_int(record.get("storedBytes")) or None,
    }


def _parse_readback(record: Mapping[str, Any]) -> Dict[str, Any] | None:
    result_id = str(record.get("resultId") or "").strip()
    if not result_id:
        return None
    returned_bytes = _coerce_int(record.get("returnedBytes"))
    returned_tokens = _coerce_int(record.get("returnedTokens"))
    if returned_tokens <= 0 and returned_bytes > 0:
        returned_tokens = _estimate_tokens(returned_bytes)
    return {
        "result_id": result_id,
        "view": str(record.get("view") or "compacted").lower(),
        "returned_bytes": returned_bytes,
        "returned_tokens": returned_tokens,
        "reason": str(record.get("reason") or "").strip() or None,
        "channel": str(record.get("channel") or "").strip() or None,
        "source_result_channel": str(
            record.get("sourceResultChannel", record.get("source_result_channel")) or ""
        ).strip()
        or None,
    }


def _load_windowing_records(path: Path | str) -> List[Dict[str, Any]]:
    try:
        lines = Path(path).read_text(encoding="utf-8").splitlines()
    except OSError:
        return []
    records: List[Dict[str, Any]] = []
    for raw in lines:
        line = raw.strip()
        if not line:
            continue
        try:
            record = json.loads(line)
        except json.JSONDecodeError:
            continue
        if isinstance(record, dict):
            records.append(record)
    return records


def _record_plan_key(record: Mapping[str, Any]) -> str:
    return str(record.get("planKey", record.get("plan_key")) or "").strip()


def _filter_records_for_plan_key(
    records: Sequence[Mapping[str, Any]],
    plan_key: str | None,
) -> List[Mapping[str, Any]]:
    requested = str(plan_key or "").strip()
    if not requested:
        return list(records)
    matching = [record for record in records if _record_plan_key(record) == requested]
    return matching if matching else list(records)


def _token_fields_from_record(record: Mapping[str, Any]) -> Tuple[int, int, int]:
    """Return (original_tokens, returned_tokens, token_cap_triggered_int).

    Mirrors tool_call_classification.token_fields_from_record but also falls
    back to returnedTokens when compactedTokens is absent.
    """
    original_tokens = _coerce_int(
        record.get("originalTokens", record.get("original_tokens"))
    )
    returned_tokens = _coerce_int(
        record.get("returnedTokens", record.get("returned_tokens"))
    )
    if returned_tokens <= 0:
        returned_tokens = _coerce_int(
            record.get("compactedTokens", record.get("compacted_tokens"))
        )
    token_cap = _coerce_int(
        record.get("tokenCapTriggered", record.get("token_cap_triggered"))
    )
    return original_tokens, returned_tokens, token_cap or 0


def analyze_result_windowing_log(
    path: Path | str,
    *,
    plan_key: str | None = None,
) -> Dict[str, Any]:
    """Analyze a result-windowing.jsonl log.

    Returns both diagnostic counters and decision-grade net consumption fields.
    Net consumed bytes/tokens for each resultId are capped at the original
    envelope so savings never go negative.
    """
    envelopes: Dict[str, Dict[str, int]] = {}
    readbacks: List[Dict[str, Any]] = []
    records = _filter_records_for_plan_key(_load_windowing_records(path), plan_key)
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

    raw_count = 0
    compacted_count = 0
    gross_readback_bytes = 0
    gross_readback_tokens = 0
    full_preview_rereads = 0
    reason_counts: Dict[str, int] = {}

    for record in readbacks:
        view = record["view"]
        returned_bytes = record["returned_bytes"]
        returned_tokens = record["returned_tokens"]
        reason = record.get("reason")
        gross_readback_bytes += returned_bytes
        gross_readback_tokens += returned_tokens
        if view == "raw":
            raw_count += 1
        else:
            compacted_count += 1
        if reason:
            reason_counts[reason] = reason_counts.get(reason, 0) + 1
        envelope = envelopes.get(record["result_id"])
        if envelope and returned_bytes > 0:
            preview = envelope["returned_bytes"]
            if preview > 0 and returned_bytes >= int(preview * 0.95):
                full_preview_rereads += 1

    envelope_original_bytes = sum(
        item["original_bytes"] for item in envelopes.values()
    )
    envelope_original_tokens = sum(
        item["original_tokens"] for item in envelopes.values()
    )

    net_consumed_bytes = 0
    net_consumed_tokens = 0
    for result_id, envelope in envelopes.items():
        extra_bytes = 0
        extra_tokens = 0
        for readback in readbacks:
            if readback["result_id"] == result_id:
                extra_bytes += readback["returned_bytes"]
                extra_tokens += readback["returned_tokens"]
        original_bytes = envelope["original_bytes"]
        original_tokens = envelope["original_tokens"]
        consumed_bytes = envelope["returned_bytes"] + extra_bytes
        consumed_tokens = envelope["returned_tokens"] + extra_tokens
        net_post_bytes = (
            min(original_bytes, consumed_bytes) if original_bytes > 0 else consumed_bytes
        )
        net_post_tokens = (
            min(original_tokens, consumed_tokens)
            if original_tokens > 0
            else consumed_tokens
        )
        net_consumed_bytes += net_post_bytes
        net_consumed_tokens += net_post_tokens

    readback_count = raw_count + compacted_count
    raw_share = round(raw_count / readback_count, 4) if readback_count else 0.0
    readback_negation_rate = (
        round(gross_readback_bytes / envelope_original_bytes, 4)
        if envelope_original_bytes > 0
        else 0.0
    )
    effective_windowing_savings_rate = (
        round(
            (envelope_original_bytes - net_consumed_bytes) / envelope_original_bytes,
            4,
        )
        if envelope_original_bytes > 0
        else 0.0
    )

    return {
        # Diagnostic counters
        "envelope_count": len(envelopes),
        "readback_count": readback_count,
        "raw_readback_count": raw_count,
        "compacted_readback_count": compacted_count,
        "raw_readback_share": raw_share,
        "readback_bytes": gross_readback_bytes,
        "envelope_original_bytes": envelope_original_bytes,
        "readback_negation_rate": readback_negation_rate,
        "full_preview_rereads": full_preview_rereads,
        "readback_reason_counts": reason_counts,
        # Decision-grade net consumption
        "effective_windowing_savings_rate": effective_windowing_savings_rate,
        "net_consumed_bytes": net_consumed_bytes,
        "net_consumed_tokens": net_consumed_tokens,
        "gross_readback_bytes": gross_readback_bytes,
        "gross_readback_tokens": gross_readback_tokens,
    }


def aggregate_windowing_savings(
    path: Path | str,
    *,
    estimate_tokens_fn=None,
    plan_key: str | None = None,
) -> Dict[str, Any]:
    """Return per-envelope and total net savings for overlay accounting.

    Returns a dict with:
      - total: totals usable for a result_windowing savings bucket
      - per_result: list of per-resultId net consumption rows
      - readbacks_by_result: raw readback totals keyed by resultId

    When plan_key is supplied, filtering is strict (unlike
    _filter_records_for_plan_key's report-oriented "fall back to all records
    when nothing matches" behavior): a record whose planKey does not match is
    excluded from savings entirely, consistent with the compact/rewrite log
    filtering in aggregate_byte_savings_by_path. Mismatched records are a
    caller-side diagnostics concern (see aggregate_telemetry_unattributed),
    not a savings-accounting concern.
    """
    if estimate_tokens_fn is None:
        estimate_tokens_fn = _estimate_tokens

    requested_plan_key = str(plan_key or "").strip()
    records = _load_windowing_records(path)
    if requested_plan_key:
        records = [
            record
            for record in records
            if not _record_plan_key(record) or _record_plan_key(record) == requested_plan_key
        ]
    envelopes: Dict[str, Dict[str, int]] = {}
    readbacks: List[Dict[str, Any]] = []
    legacy_events: List[Dict[str, int]] = []

    for record in records:
        event = str(record.get("event") or "").strip().lower()
        result_id = str(record.get("resultId") or "").strip()
        if event == "envelope" and result_id:
            parsed = _parse_envelope(record)
            if parsed is not None:
                envelopes[result_id] = parsed
        elif event == "readback" and result_id:
            parsed = _parse_readback(record)
            if parsed is not None:
                readbacks.append(parsed)
        elif event != "envelope" and event != "readback" and not result_id:
            # Legacy per-line result-windowing records without resultId.
            original_bytes = _coerce_int(record.get("originalBytes"))
            returned_bytes = _coerce_int(
                record.get("returnedBytes", record.get("postBytes"))
            )
            original_tokens, returned_tokens, token_cap = _token_fields_from_record(
                record
            )
            if original_tokens <= 0 and returned_tokens <= 0 and original_bytes > 0:
                original_tokens = estimate_tokens_fn(original_bytes)
                returned_tokens = estimate_tokens_fn(returned_bytes)
            legacy_events.append(
                {
                    "original_bytes": original_bytes,
                    "returned_bytes": returned_bytes,
                    "original_tokens": original_tokens,
                    "returned_tokens": returned_tokens,
                    "token_cap": token_cap,
                }
            )

    per_result: List[Dict[str, int]] = []
    readbacks_by_result: Dict[str, Dict[str, int]] = {}
    total_original_bytes = 0
    total_net_post_bytes = 0
    total_original_tokens = 0
    total_net_post_tokens = 0
    token_cap_triggers = 0

    # Group readbacks by resultId for reuse.
    grouped_readbacks: Dict[str, Dict[str, int]] = {}
    for readback in readbacks:
        bucket = grouped_readbacks.setdefault(
            readback["result_id"], {"bytes": 0, "tokens": 0, "raw": 0, "compacted": 0}
        )
        bucket["bytes"] += readback["returned_bytes"]
        bucket["tokens"] += readback["returned_tokens"]
        if readback["view"] == "raw":
            bucket["raw"] += 1
        else:
            bucket["compacted"] += 1

    for result_id, envelope in envelopes.items():
        extra = grouped_readbacks.get(
            result_id, {"bytes": 0, "tokens": 0, "raw": 0, "compacted": 0}
        )
        original_bytes = envelope["original_bytes"]
        original_tokens = envelope["original_tokens"]
        consumed_bytes = envelope["returned_bytes"] + extra["bytes"]
        consumed_tokens = envelope["returned_tokens"] + extra["tokens"]
        net_post_bytes = (
            min(original_bytes, consumed_bytes) if original_bytes > 0 else consumed_bytes
        )
        net_post_tokens = (
            min(original_tokens, consumed_tokens)
            if original_tokens > 0
            else consumed_tokens
        )
        per_result.append(
            {
                "result_id": result_id,
                "original_bytes": original_bytes,
                "returned_bytes": envelope["returned_bytes"],
                "extra_bytes": extra["bytes"],
                "net_post_bytes": net_post_bytes,
                "original_tokens": original_tokens,
                "returned_tokens": envelope["returned_tokens"],
                "extra_tokens": extra["tokens"],
                "net_post_tokens": net_post_tokens,
                "token_cap_triggered": envelope["token_cap_triggered"],
                "raw_readbacks": extra["raw"],
                "compacted_readbacks": extra["compacted"],
                "measurement_quality": envelope.get(
                    "measurement_quality", "legacy_storage_counterfactual"
                ),
                "surfaced_tool": envelope.get("surfaced_tool", "unknown"),
                "source_capped": bool(envelope.get("source_capped", False)),
            }
        )
        total_original_bytes += original_bytes
        total_net_post_bytes += net_post_bytes
        total_original_tokens += original_tokens
        total_net_post_tokens += net_post_tokens
        if envelope["token_cap_triggered"]:
            token_cap_triggers += 1

        readbacks_by_result[result_id] = {
            "bytes": extra["bytes"],
            "tokens": extra["tokens"],
            "raw": extra["raw"],
            "compacted": extra["compacted"],
        }

    total_saved_bytes = total_original_bytes - total_net_post_bytes
    total_saved_tokens = total_original_tokens - total_net_post_tokens

    return {
        "total": {
            "original_bytes": total_original_bytes,
            "net_post_bytes": total_net_post_bytes,
            "saved_bytes": total_saved_bytes,
            "original_tokens": total_original_tokens,
            "net_post_tokens": total_net_post_tokens,
            "saved_tokens": total_saved_tokens,
            "token_cap_triggers": token_cap_triggers,
            "envelope_count": len(envelopes),
            "legacy_count": len(legacy_events),
        },
        "per_result": per_result,
        "readbacks_by_result": readbacks_by_result,
        "legacy_events": legacy_events,
    }


def aggregate_windowing_by_source_tool(
    path: Path | str,
    *,
    estimate_tokens_fn=None,
    plan_key: str | None = None,
) -> Dict[str, Dict[str, Any]]:
    """Aggregate v2 result-windowing records by surfaced source tool.

    Per tool: events, inlineCandidateBytes (gross), deliveredBytes (gross),
    netConsumedBytes (post readback, capped at inline candidate), netSavedBytes,
    sourceCappedCount, and a measurementQuality label ("v2_measured",
    "legacy_storage_counterfactual", or "mixed"). Never treats stored/source
    capture bytes as the hypothetical model input -- inline candidate is the
    gross "without Ralph" figure here, consistent with the measurement
    contract used throughout this module.
    """
    aggregated = aggregate_windowing_savings(
        path, estimate_tokens_fn=estimate_tokens_fn, plan_key=plan_key
    )
    by_tool: Dict[str, Dict[str, Any]] = {}
    for row in aggregated["per_result"]:
        tool = str(row.get("surfaced_tool") or "unknown")
        bucket = by_tool.setdefault(
            tool,
            {
                "events": 0,
                "inline_candidate_bytes": 0,
                "delivered_bytes": 0,
                "net_consumed_bytes": 0,
                "net_saved_bytes": 0,
                "source_capped_count": 0,
                "_qualities": set(),
            },
        )
        bucket["events"] += 1
        bucket["inline_candidate_bytes"] += _coerce_int(row.get("original_bytes"))
        bucket["delivered_bytes"] += _coerce_int(row.get("returned_bytes"))
        bucket["net_consumed_bytes"] += _coerce_int(row.get("net_post_bytes"))
        if row.get("source_capped"):
            bucket["source_capped_count"] += 1
        bucket["_qualities"].add(str(row.get("measurement_quality") or "legacy_storage_counterfactual"))

    for bucket in by_tool.values():
        bucket["net_saved_bytes"] = max(
            0, bucket["inline_candidate_bytes"] - bucket["net_consumed_bytes"]
        )
        qualities = bucket.pop("_qualities")
        if qualities == {"v2_measured"}:
            bucket["measurement_quality"] = "v2_measured"
        elif qualities == {"legacy_storage_counterfactual"}:
            bucket["measurement_quality"] = "legacy_storage_counterfactual"
        else:
            bucket["measurement_quality"] = "mixed"

    return by_tool


def aggregate_source_cap_operational_summary(
    path: Path | str,
    *,
    plan_key: str | None = None,
) -> Dict[str, Any]:
    """Operational summary for source-capped searches: capped event count,
    captured/stored bytes, cap reasons, and configured limits. Uncaptured/
    avoided source bytes are never estimated here -- collection stopped
    early, so what was not read is genuinely unknown and must not be added
    to any token/context savings figure.
    """
    requested_plan_key = str(plan_key or "").strip()
    records = _load_windowing_records(path)
    if requested_plan_key:
        records = [
            record
            for record in records
            if not _record_plan_key(record) or _record_plan_key(record) == requested_plan_key
        ]

    capped_count = 0
    stored_bytes_total = 0
    reasons: Dict[str, int] = {}
    limits: set[int] = set()

    for record in records:
        if str(record.get("event") or "").strip().lower() != "envelope":
            continue
        if record.get("sourceCapped") is not True:
            continue
        capped_count += 1
        stored_bytes_total += _coerce_int(record.get("storedBytes"))
        reason = str(record.get("capReason") or "unknown").strip() or "unknown"
        reasons[reason] = reasons.get(reason, 0) + 1
        cap_limit = _coerce_int(record.get("capLimitBytes"))
        if cap_limit > 0:
            limits.add(cap_limit)

    return {
        "capped_event_count": capped_count,
        "stored_bytes_total": stored_bytes_total,
        "cap_reasons": reasons,
        "configured_limits_bytes": sorted(limits),
    }


def _empty_channel_bucket(*, attribution: str = CHANNEL_ATTRIBUTION_EXACT) -> dict[str, Any]:
    bucket: dict[str, Any] = empty_savings_bucket(include_hidden=True)
    bucket["attribution"] = attribution
    return bucket


def _mark_channel_attribution(bucket: dict[str, Any], attribution: str) -> None:
    current = str(bucket.get("attribution") or CHANNEL_ATTRIBUTION_EXACT)
    if current == CHANNEL_ATTRIBUTION_LEGACY or attribution == CHANNEL_ATTRIBUTION_LEGACY:
        bucket["attribution"] = CHANNEL_ATTRIBUTION_LEGACY
    else:
        bucket["attribution"] = CHANNEL_ATTRIBUTION_EXACT


def _resolve_result_channel_target(
    envelope: Mapping[str, Any],
    readbacks: Sequence[Mapping[str, Any]],
) -> tuple[str, str]:
    """Return (channel_name, attribution) for a resultId group."""
    envelope_channel = str(envelope.get("channel") or "").strip()
    if not envelope_channel:
        return "stored_result_readback", CHANNEL_ATTRIBUTION_LEGACY

    if not readbacks:
        return envelope_channel, CHANNEL_ATTRIBUTION_EXACT

    for readback in readbacks:
        source_channel = str(readback.get("source_result_channel") or "").strip()
        if not source_channel:
            return "stored_result_readback", CHANNEL_ATTRIBUTION_LEGACY
        if source_channel != envelope_channel:
            return "stored_result_readback", CHANNEL_ATTRIBUTION_LEGACY

    return envelope_channel, CHANNEL_ATTRIBUTION_EXACT


def aggregate_windowing_savings_by_channel(
    path: Path | str,
    *,
    estimate_tokens_fn=None,
    plan_key: str | None = None,
) -> dict[str, dict[str, Any]]:
    """Return per-channel net savings for result-windowing.jsonl records.

    Envelope savings net readback cost against sourceResultChannel when present.
    Legacy records without channel/source attribution accumulate under
    stored_result_readback with attribution marked legacy rather than guessing.
    """
    if estimate_tokens_fn is None:
        estimate_tokens_fn = _estimate_tokens

    records = _filter_records_for_plan_key(_load_windowing_records(path), plan_key)
    envelopes: Dict[str, Dict[str, Any]] = {}
    readbacks: List[Dict[str, Any]] = []
    legacy_events: List[Dict[str, int]] = []

    for record in records:
        event = str(record.get("event") or "").strip().lower()
        result_id = str(record.get("resultId") or "").strip()
        if event == "envelope" and result_id:
            parsed = _parse_envelope(record)
            if parsed is not None:
                envelopes[result_id] = parsed
        elif event == "readback" and result_id:
            parsed = _parse_readback(record)
            if parsed is not None:
                readbacks.append(parsed)
        elif event != "envelope" and event != "readback" and not result_id:
            original_bytes = _coerce_int(record.get("originalBytes"))
            returned_bytes = _coerce_int(
                record.get("returnedBytes", record.get("postBytes"))
            )
            original_tokens, returned_tokens, token_cap = _token_fields_from_record(
                record
            )
            if original_tokens <= 0 and returned_tokens <= 0 and original_bytes > 0:
                original_tokens = estimate_tokens_fn(original_bytes)
                returned_tokens = estimate_tokens_fn(returned_bytes)
            legacy_events.append(
                {
                    "original_bytes": original_bytes,
                    "returned_bytes": returned_bytes,
                    "original_tokens": original_tokens,
                    "returned_tokens": returned_tokens,
                    "token_cap": token_cap,
                }
            )

    buckets: dict[str, dict[str, Any]] = {
        channel: _empty_channel_bucket() for channel in WINDOWING_CHANNEL_NAMES
    }

    grouped_readbacks: Dict[str, List[Dict[str, Any]]] = {}
    for readback in readbacks:
        grouped_readbacks.setdefault(readback["result_id"], []).append(readback)

    for result_id, envelope in envelopes.items():
        result_readbacks = grouped_readbacks.get(result_id, [])
        extra_bytes = sum(item["returned_bytes"] for item in result_readbacks)
        extra_tokens = sum(item["returned_tokens"] for item in result_readbacks)
        original_bytes = envelope["original_bytes"]
        original_tokens = envelope["original_tokens"]
        consumed_bytes = envelope["returned_bytes"] + extra_bytes
        consumed_tokens = envelope["returned_tokens"] + extra_tokens
        net_post_bytes = (
            min(original_bytes, consumed_bytes) if original_bytes > 0 else consumed_bytes
        )
        net_post_tokens = (
            min(original_tokens, consumed_tokens)
            if original_tokens > 0
            else consumed_tokens
        )
        channel_name, attribution = _resolve_result_channel_target(
            envelope, result_readbacks
        )
        bucket = buckets[channel_name]
        accumulate_savings_event(
            bucket,
            pre_bytes=original_bytes,
            post_bytes=net_post_bytes,
            pre_tokens=original_tokens,
            post_tokens=net_post_tokens,
            token_cap_trigger=bool(envelope["token_cap_triggered"]),
            hidden_from_context=True,
        )
        _mark_channel_attribution(bucket, attribution)

    legacy_bucket = buckets["stored_result_readback"]
    for entry in legacy_events:
        accumulate_savings_event(
            legacy_bucket,
            pre_bytes=entry["original_bytes"],
            post_bytes=entry["returned_bytes"],
            pre_tokens=entry["original_tokens"],
            post_tokens=entry["returned_tokens"],
            token_cap_trigger=bool(entry["token_cap"]),
            hidden_from_context=True,
        )
        _mark_channel_attribution(legacy_bucket, CHANNEL_ATTRIBUTION_LEGACY)

    for channel_name, bucket in buckets.items():
        if _coerce_int(bucket.get("count")) > 0:
            finalize_savings_bucket(bucket)
        else:
            bucket.pop("savings_percent", None)
            bucket.pop("savings_percent_tokens", None)

    return buckets


def stored_result_readback_guidance(stats: Mapping[str, Any]) -> str:
    if not stats:
        return ""
    parts: List[str] = []
    full_rereads = int(stats.get("full_preview_rereads") or 0)
    if full_rereads > 0:
        parts.append(f"{full_rereads} full stored-result reread(s)")
    raw_count = int(stats.get("raw_readback_count") or 0)
    raw_share = float(stats.get("raw_readback_share") or 0)
    negation_rate = float(stats.get("readback_negation_rate") or 0)
    readback_count = int(stats.get("readback_count") or 0)
    if raw_count > 0:
        parts.append(f"{raw_count} raw result_read follow-up(s)")
    if readback_count > 0 and not parts:
        parts.append(f"{readback_count} stored-result follow-up(s)")
    if not parts:
        return ""
    guidance = "treat inline preview as sufficient, use result_search or compacted byte ranges before view=raw"
    if full_rereads > 0 or raw_share >= 0.4 or negation_rate >= 0.3:
        guidance += "; avoid full preview re-reads"
    return "; ".join(parts) + "; " + guidance
