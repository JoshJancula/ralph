#!/usr/bin/env python3
"""Shadow-mode calibration report for Jev decision logs.

Reads decisions.jsonl and prints, per (surface, questionSetId):
  1. sample size (first and prominent — rates over tiny samples are noise)
  2. agreement rate vs the deterministic result
  3. disagreement count and a short listing
  4. UNSAFE disagreement count (Jev more permissive than deterministic)
  5. latency distribution: min, median, p95, max
  6. breaker activations and total input tokens

Usage:
  python3 jev_shadow_report.py [path/to/decisions.jsonl]
"""

from __future__ import annotations

import json
import math
import sys
from collections import defaultdict
from typing import Any, Iterable, Mapping, Sequence

# Higher rank = more permissive (more willing to trust / act on Jev).
_DECISION_RANK = {
    "fallback": 0,
    "gather": 1,
    "act": 2,
}

_MIN_USEFUL_SAMPLES = 5


def _as_decision(value: Any) -> str:
    if isinstance(value, str) and value in _DECISION_RANK:
        return value
    return "fallback"


def _deterministic_result(record: Mapping[str, Any]) -> str:
    """Resolve what the deterministic path used for this record.

    Explicit deterministicResult wins. Shadow mode always forces the caller onto
    the deterministic path (fallback). Otherwise fallbackUsed means the
    deterministic path ran; else the recorded decision was applied.
    """
    explicit = record.get("deterministicResult")
    if isinstance(explicit, str) and explicit in _DECISION_RANK:
        return explicit
    if record.get("shadow") is True:
        return "fallback"
    if record.get("fallbackUsed") is True:
        return "fallback"
    return _as_decision(record.get("decision"))


def _input_tokens(record: Mapping[str, Any]) -> int:
    usage = record.get("usage")
    if not isinstance(usage, Mapping):
        return 0
    for key in ("input_tokens", "inputTokens"):
        raw = usage.get(key)
        if isinstance(raw, bool):
            continue
        if isinstance(raw, (int, float)):
            return max(0, int(raw))
        if isinstance(raw, str):
            try:
                return max(0, int(float(raw)))
            except ValueError:
                continue
    return 0


def _latency_ms(record: Mapping[str, Any]) -> float | None:
    raw = record.get("latencyMs")
    if isinstance(raw, bool):
        return None
    if isinstance(raw, (int, float)):
        return float(raw)
    if isinstance(raw, str):
        try:
            return float(raw)
        except ValueError:
            return None
    return None


def _is_breaker_activation(record: Mapping[str, Any]) -> bool:
    if record.get("breakerState") == "open":
        return True
    return record.get("reason") == "breaker-open"


def _percentile_nearest(sorted_vals: Sequence[float], p: float) -> float:
    """Nearest-rank percentile; p in [0, 100]."""
    if not sorted_vals:
        return 0.0
    if len(sorted_vals) == 1:
        return float(sorted_vals[0])
    rank = (p / 100.0) * (len(sorted_vals) - 1)
    lo = int(math.floor(rank))
    hi = int(math.ceil(rank))
    if lo == hi:
        return float(sorted_vals[lo])
    weight = rank - lo
    return float(sorted_vals[lo]) * (1.0 - weight) + float(sorted_vals[hi]) * weight


def _group_key(record: Mapping[str, Any]) -> tuple[str, str]:
    surface = record.get("surface")
    qsid = record.get("questionSetId")
    return (
        surface if isinstance(surface, str) and surface else "(none)",
        qsid if isinstance(qsid, str) and qsid else "(none)",
    )


def load_records(path: str) -> list[dict[str, Any]]:
    records: list[dict[str, Any]] = []
    with open(path, encoding="utf-8") as handle:
        for line_no, line in enumerate(handle, start=1):
            text = line.strip()
            if not text:
                continue
            try:
                obj = json.loads(text)
            except json.JSONDecodeError:
                print(
                    f"warning: skipping unparseable line {line_no}",
                    file=sys.stderr,
                )
                continue
            if isinstance(obj, dict):
                records.append(obj)
    return records


def _format_disagreement(record: Mapping[str, Any], deterministic: str) -> str:
    decision = _as_decision(record.get("decision"))
    chosen = record.get("chosen")
    confidence = record.get("confidence")
    reason = record.get("reason")
    parts = [
        f"decision={decision}",
        f"deterministic={deterministic}",
    ]
    if confidence is not None:
        parts.append(f"confidence={confidence}")
    if chosen is not None:
        parts.append(f"chosen={chosen}")
    if isinstance(reason, str) and reason:
        parts.append(f"reason={reason}")
    ts = record.get("timestamp")
    if isinstance(ts, str) and ts:
        parts.append(f"timestamp={ts}")
    return "  - " + " ".join(parts)


def analyze_group(records: Sequence[Mapping[str, Any]]) -> dict[str, Any]:
    sample_size = len(records)
    agreements = 0
    disagreements: list[str] = []
    unsafe = 0
    latencies: list[float] = []
    breaker_activations = 0
    input_tokens_total = 0

    for record in records:
        would_have = _as_decision(record.get("decision"))
        deterministic = _deterministic_result(record)
        if would_have == deterministic:
            agreements += 1
        else:
            disagreements.append(_format_disagreement(record, deterministic))
            if _DECISION_RANK[would_have] > _DECISION_RANK[deterministic]:
                unsafe += 1

        latency = _latency_ms(record)
        if latency is not None:
            latencies.append(latency)
        if _is_breaker_activation(record):
            breaker_activations += 1
        input_tokens_total += _input_tokens(record)

    latencies_sorted = sorted(latencies)
    if latencies_sorted:
        latency_stats = {
            "min": latencies_sorted[0],
            "median": _percentile_nearest(latencies_sorted, 50),
            "p95": _percentile_nearest(latencies_sorted, 95),
            "max": latencies_sorted[-1],
            "n": len(latencies_sorted),
        }
    else:
        latency_stats = None

    agreement_rate = (agreements / sample_size) if sample_size else 0.0
    return {
        "sample_size": sample_size,
        "agreements": agreements,
        "agreement_rate": agreement_rate,
        "disagreements": disagreements,
        "unsafe_disagreements": unsafe,
        "latency": latency_stats,
        "breaker_activations": breaker_activations,
        "input_tokens_total": input_tokens_total,
    }


def render_report(records: Iterable[Mapping[str, Any]]) -> str:
    groups: dict[tuple[str, str], list[Mapping[str, Any]]] = defaultdict(list)
    for record in records:
        groups[_group_key(record)].append(record)

    if not groups:
        return "sample_size: 0\n(no decision records)\n"

    lines: list[str] = []
    for surface, qsid in sorted(groups.keys()):
        stats = analyze_group(groups[(surface, qsid)])
        sample_size = stats["sample_size"]
        lines.append(f"=== surface={surface} questionSetId={qsid} ===")
        lines.append(f"SAMPLE SIZE: {sample_size}")
        if sample_size < _MIN_USEFUL_SAMPLES:
            lines.append(
                f"(note: sample size < {_MIN_USEFUL_SAMPLES}; rates are noise)"
            )
        rate = stats["agreement_rate"]
        agreements = stats["agreements"]
        lines.append(
            f"agreement_rate: {rate:.3f} ({agreements}/{sample_size})"
        )
        disagreements = stats["disagreements"]
        lines.append(f"disagreements: {len(disagreements)}")
        # Cap the listing so a large log stays readable.
        for row in disagreements[:50]:
            lines.append(row)
        if len(disagreements) > 50:
            lines.append(f"  ... and {len(disagreements) - 50} more")
        lines.append(f"unsafe_disagreements: {stats['unsafe_disagreements']}")
        latency = stats["latency"]
        if latency is None:
            lines.append("latency_ms: (none)")
        else:
            lines.append(
                "latency_ms: "
                f"min={latency['min']:.1f} "
                f"median={latency['median']:.1f} "
                f"p95={latency['p95']:.1f} "
                f"max={latency['max']:.1f} "
                f"(n={latency['n']})"
            )
        lines.append(f"breaker_activations: {stats['breaker_activations']}")
        lines.append(f"input_tokens_total: {stats['input_tokens_total']}")
        lines.append("")
    return "\n".join(lines).rstrip() + "\n"


def main(argv: Sequence[str] | None = None) -> int:
    args = list(sys.argv[1:] if argv is None else argv)
    if not args or args[0] in ("-h", "--help"):
        print(
            "Usage: jev_shadow_report.py <decisions.jsonl>",
            file=sys.stderr,
        )
        return 0 if args and args[0] in ("-h", "--help") else 2

    path = args[0]
    try:
        records = load_records(path)
    except OSError as exc:
        print(f"Error: cannot read {path}: {exc}", file=sys.stderr)
        return 1

    sys.stdout.write(render_report(records))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
