#!/usr/bin/env python3
"""Canonical usage accounting for Ralph plan invocations and summaries.

Shared token bucket dimensions, measurement sources, and cache-efficiency ratios.
Legacy readers accept input_tokens and cache_hit_ratio; new writers emit schema v2
fields without rewriting historical files.
"""

from __future__ import annotations

import json
import os
from datetime import datetime
from typing import Any, Mapping, MutableMapping, Sequence

USAGE_INVOCATION_SCHEMA_VERSION = 2
USAGE_SUMMARY_SCHEMA_VERSION = 2

INPUT_BUCKETS = (
    "uncached_input_tokens",
    "cache_creation_input_tokens",
    "cache_read_input_tokens",
)
OUTPUT_BUCKET = "output_tokens"
ALL_BUCKETS = INPUT_BUCKETS + (OUTPUT_BUCKET,)

MEASURED = "measured"
ESTIMATED = "estimated"
UNAVAILABLE = "unavailable"
MIXED = "mixed"
MEASUREMENT_SOURCES = (MEASURED, ESTIMATED, UNAVAILABLE, MIXED)


def as_int(value: Any) -> int:
    if value is None or value == "":
        return 0
    try:
        return int(value)
    except (TypeError, ValueError):
        try:
            return int(float(value))
        except (TypeError, ValueError):
            return 0


def _parse_iso_timestamp(value: str) -> datetime | None:
    text = (value or "").strip()
    if not text:
        return None
    if text.endswith("Z"):
        text = text[:-1] + "+00:00"
    try:
        return datetime.fromisoformat(text)
    except ValueError:
        return None


def combine_sources(sources: Sequence[str]) -> str:
    present = {str(s or "").strip().lower() for s in sources if str(s or "").strip()}
    present.discard("")
    if not present or present == {UNAVAILABLE}:
        return UNAVAILABLE
    if len(present) == 1:
        return next(iter(present))
    if present <= {MEASURED}:
        return MEASURED
    if present <= {ESTIMATED}:
        return ESTIMATED
    return MIXED


def total_input_tokens(
    uncached: int,
    cache_creation: int,
    cache_read: int,
) -> int:
    return max(0, uncached) + max(0, cache_creation) + max(0, cache_read)


def cache_efficiency_ratio(cache_read: int, total_input: int) -> float:
    if total_input <= 0:
        return 0.0
    return round(max(0, cache_read) / total_input, 4)


def _bucket_value_and_source(record: Mapping[str, Any], bucket: str) -> tuple[int, str]:
    sources = record.get("measurement_source")
    if isinstance(sources, Mapping) and bucket in sources:
        source = str(sources.get(bucket) or UNAVAILABLE).strip().lower()
        if source not in MEASUREMENT_SOURCES:
            source = UNAVAILABLE
        value = as_int(record.get(bucket))
        if source == UNAVAILABLE:
            return 0, UNAVAILABLE
        return value, source

    if bucket == "uncached_input_tokens":
        if "uncached_input_tokens" in record:
            return as_int(record.get("uncached_input_tokens")), MEASURED
        if "input_tokens" in record:
            return as_int(record.get("input_tokens")), MEASURED
        return 0, UNAVAILABLE

    if bucket == OUTPUT_BUCKET:
        if OUTPUT_BUCKET in record:
            return as_int(record.get(OUTPUT_BUCKET)), MEASURED
        return 0, UNAVAILABLE

    if bucket == "cache_creation_input_tokens":
        if "cache_creation_input_tokens" in record:
            return as_int(record.get("cache_creation_input_tokens")), MEASURED
        return 0, UNAVAILABLE

    if bucket == "cache_read_input_tokens":
        estimated = as_int(record.get("cache_read_input_tokens_estimated"))
        measured = as_int(record.get("cache_read_input_tokens")) if "cache_read_input_tokens" in record else 0
        if estimated > 0 and measured == 0:
            return estimated, ESTIMATED
        if "cache_read_input_tokens" in record:
            return measured, MEASURED
        return 0, UNAVAILABLE

    return 0, UNAVAILABLE


def normalize_usage(record: Mapping[str, Any]) -> dict[str, Any]:
    """Return canonical usage view for one invocation or summary record."""
    buckets: dict[str, int] = {}
    sources: dict[str, str] = {}
    for bucket in ALL_BUCKETS:
        value, source = _bucket_value_and_source(record, bucket)
        buckets[bucket] = value
        sources[bucket] = source

    total_input = total_input_tokens(
        buckets["uncached_input_tokens"],
        buckets["cache_creation_input_tokens"],
        buckets["cache_read_input_tokens"],
    )
    ratio = cache_efficiency_ratio(buckets["cache_read_input_tokens"], total_input)

    legacy_ratio = record.get("cache_hit_ratio")
    if legacy_ratio is not None and sources["cache_read_input_tokens"] == UNAVAILABLE:
        try:
            ratio = round(float(legacy_ratio), 4)
        except (TypeError, ValueError):
            ratio = 0.0

    return {
        "uncached_input_tokens": buckets["uncached_input_tokens"],
        "cache_creation_input_tokens": buckets["cache_creation_input_tokens"],
        "cache_read_input_tokens": buckets["cache_read_input_tokens"],
        "output_tokens": buckets["output_tokens"],
        "total_input_tokens": total_input,
        "cache_efficiency_ratio": ratio,
        "cache_hit_ratio": ratio,
        "input_tokens": buckets["uncached_input_tokens"],
        "measurement_source": sources,
    }


def enrich_record(record: MutableMapping[str, Any]) -> MutableMapping[str, Any]:
    """Add canonical usage fields to a record before persistence."""
    canonical = normalize_usage(record)
    record["uncached_input_tokens"] = canonical["uncached_input_tokens"]
    record["cache_creation_input_tokens"] = canonical["cache_creation_input_tokens"]
    record["cache_read_input_tokens"] = canonical["cache_read_input_tokens"]
    record["output_tokens"] = canonical["output_tokens"]
    record["total_input_tokens"] = canonical["total_input_tokens"]
    record["cache_efficiency_ratio"] = canonical["cache_efficiency_ratio"]
    record["cache_hit_ratio"] = canonical["cache_hit_ratio"]
    record["input_tokens"] = canonical["input_tokens"]
    record["measurement_source"] = canonical["measurement_source"]
    return record


def aggregate_records(records: Sequence[Mapping[str, Any]]) -> dict[str, Any]:
    """Aggregate usage across invocations with mixed/unavailable source handling."""
    totals = {bucket: 0 for bucket in ALL_BUCKETS}
    source_lists: dict[str, list[str]] = {bucket: [] for bucket in ALL_BUCKETS}

    for record in records:
        canonical = normalize_usage(record)
        for bucket in ALL_BUCKETS:
            source = canonical["measurement_source"][bucket]
            source_lists[bucket].append(source)
            if source != UNAVAILABLE:
                totals[bucket] += canonical[bucket]

    combined = {bucket: combine_sources(source_lists[bucket]) for bucket in ALL_BUCKETS}
    total_input = total_input_tokens(
        totals["uncached_input_tokens"],
        totals["cache_creation_input_tokens"],
        totals["cache_read_input_tokens"],
    )
    ratio = cache_efficiency_ratio(totals["cache_read_input_tokens"], total_input)

    return {
        "uncached_input_tokens": totals["uncached_input_tokens"],
        "cache_creation_input_tokens": totals["cache_creation_input_tokens"],
        "cache_read_input_tokens": totals["cache_read_input_tokens"],
        "output_tokens": totals["output_tokens"],
        "total_input_tokens": total_input,
        "cache_efficiency_ratio": ratio,
        "cache_hit_ratio": ratio,
        "input_tokens": totals["uncached_input_tokens"],
        "measurement_source": combined,
    }


def apply_canonical_to_summary(summary: MutableMapping[str, Any], records: Sequence[Mapping[str, Any]]) -> None:
    """Merge canonical aggregates into a plan or orchestration summary dict."""
    if not records:
        canonical = normalize_usage(summary)
    else:
        canonical = aggregate_records(records)
    summary.update(canonical)
    summary["schema_version"] = USAGE_SUMMARY_SCHEMA_VERSION


def load_compact_catalog_metrics(
    workspace_root: str,
    plan_key: str,
    started_at: str = "",
    ended_at: str = "",
) -> dict[str, Any]:
    """Load compact MCP tool catalog metrics for an invocation window."""
    active_raw = os.environ.get("RALPH_MCP_COMPACT_TOOL_CATALOG", "").strip().lower()
    if active_raw in ("1", "true", "yes", "on"):
        active = True
    elif active_raw in ("0", "false", "no", "off"):
        active = False
    elif active_raw:
        active = False
    else:
        active = os.environ.get("RALPH_MODE", "no").strip().lower() in ("ralph", "hybrid")
    metrics: dict[str, Any] = {"compact_tool_catalog_active": active}
    if not workspace_root or not plan_key:
        return metrics

    log_path = os.path.join(workspace_root, "logs", plan_key, "tool-catalog-telemetry.jsonl")
    if not os.path.isfile(log_path):
        return metrics

    start = _parse_iso_timestamp(started_at)
    end = _parse_iso_timestamp(ended_at)
    if start and end and end < start:
        start, end = end, start

    latest: dict[str, Any] | None = None
    try:
        with open(log_path, "r", encoding="utf-8") as fh:
            for line in fh:
                entry = line.strip()
                if not entry:
                    continue
                try:
                    doc = json.loads(entry)
                except json.JSONDecodeError:
                    continue
                if not isinstance(doc, dict):
                    continue
                if str(doc.get("event") or "") != "tools_list":
                    continue
                stored_at = _parse_iso_timestamp(str(doc.get("timestamp") or ""))
                if start and stored_at and stored_at < start:
                    continue
                if end and stored_at and stored_at > end:
                    continue
                latest = doc
    except OSError:
        return metrics

    if latest is None:
        return metrics

    tool_count = latest.get("toolsListCount")
    schema_bytes = latest.get("schemaBytes")
    if tool_count is not None:
        metrics["compact_catalog_tool_count"] = as_int(tool_count)
    if schema_bytes is not None:
        metrics["compact_catalog_serialized_bytes"] = as_int(schema_bytes)
    return metrics


def attach_auxiliary_metrics(
    record: MutableMapping[str, Any],
    *,
    plan_key: str = "",
    started_at: str = "",
    ended_at: str = "",
) -> None:
    """Attach stable-prefix and compact-catalog telemetry without prompt contents."""
    workspace_root = os.environ.get("RALPH_PLAN_WORKSPACE_ROOT", "").strip()
    catalog = load_compact_catalog_metrics(workspace_root, plan_key, started_at, ended_at)
    for key, value in catalog.items():
        if value is not None:
            record[key] = value
