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
    original_bytes = _coerce_int(record.get("originalBytes"))
    returned_bytes = _coerce_int(record.get("returnedBytes"))
    original_tokens = _coerce_int(record.get("originalTokens"))
    returned_tokens = _coerce_int(record.get("returnedTokens"))
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


def analyze_result_windowing_log(path: Path | str) -> Dict[str, Any]:
    """Analyze a result-windowing.jsonl log.

    Returns both diagnostic counters and decision-grade net consumption fields.
    Net consumed bytes/tokens for each resultId are capped at the original
    envelope so savings never go negative.
    """
    envelopes: Dict[str, Dict[str, int]] = {}
    readbacks: List[Dict[str, Any]] = []
    for record in _load_windowing_records(path):
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
) -> Dict[str, Any]:
    """Return per-envelope and total net savings for overlay accounting.

    Returns a dict with:
      - total: totals usable for a result_windowing savings bucket
      - per_result: list of per-resultId net consumption rows
      - readbacks_by_result: raw readback totals keyed by resultId
    """
    if estimate_tokens_fn is None:
        estimate_tokens_fn = _estimate_tokens

    records = _load_windowing_records(path)
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
