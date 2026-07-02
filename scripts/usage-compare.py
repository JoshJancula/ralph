#!/usr/bin/env python3
"""Compare invocation-usage.json files for token-usage remediation (stdlib only)."""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path
from typing import Any

TOKEN_METRICS: tuple[tuple[str, str], ...] = (
    ("input_tokens", "input_tokens"),
    ("cache_creation_input_tokens", "cache_creation_input_tokens"),
    ("cache_read_input_tokens", "cache_read_input_tokens"),
    ("output_tokens", "output_tokens"),
)

DERIVED_INT_METRICS: tuple[tuple[str, str], ...] = (
    ("tool_turns", "tool_turns"),
    ("tool_calls_total", "tool_calls_total"),
)

BYTE_SAVINGS_BUCKETS: tuple[str, ...] = (
    "pre_tool_rewrite",
    "hook_compaction",
    "proxy_shell_compaction",
    "result_windowing",
)

BYTE_SAVINGS_FIELDS: tuple[str, ...] = (
    "count",
    "saved_bytes",
    "hidden_from_context",
)


def load_usage(path: Path) -> dict[str, Any]:
    with path.open(encoding="utf-8") as fh:
        data = json.load(fh)
    if not isinstance(data, dict):
        raise ValueError(f"{path}: expected JSON object")
    invocations = data.get("invocations")
    if not isinstance(invocations, list):
        raise ValueError(f"{path}: missing invocations array")
    return data


def resolve_target(invocations: list[Any], *, label: str) -> dict[str, Any]:
    claude = [
        record
        for record in invocations
        if isinstance(record, dict) and record.get("runtime") == "claude"
    ]
    if not claude:
        raise ValueError(f"{label}: no invocation with runtime == 'claude'")
    return max(claude, key=lambda record: int(record.get("tool_turns") or 0))


def token_value(invocation: dict[str, Any], key: str) -> int:
    return int(invocation.get(key) or 0)


def format_number(value: int | float) -> str:
    if isinstance(value, float):
        text = f"{value:.4f}".rstrip("0").rstrip(".")
        return text or "0"
    return str(value)


def format_delta(value: int | float) -> str:
    if isinstance(value, float):
        text = format_number(value)
        if value > 0:
            return f"+{text}"
        return text
    if value > 0:
        return f"+{value}"
    return str(value)


def format_pct_change(delta: int | float, baseline: int | float) -> str:
    if baseline == 0:
        return "0%" if delta == 0 else "n/a"
    pct = (delta / baseline) * 100
    sign = "+" if pct > 0 else ""
    return f"{sign}{pct:.1f}%"


def tool_turns_per_call(invocation: dict[str, Any]) -> float:
    tool_turns = token_value(invocation, "tool_turns")
    tool_calls = token_value(invocation, "tool_calls_total")
    if tool_calls == 0:
        return 0.0
    return tool_turns / tool_calls


def cache_read_per_tool_turn(invocation: dict[str, Any]) -> float:
    cache_read = token_value(invocation, "cache_read_input_tokens")
    tool_turns = token_value(invocation, "tool_turns")
    if tool_turns == 0:
        return 0.0
    return cache_read / tool_turns


def bucket_field_value(invocation: dict[str, Any], bucket: str, field: str) -> int:
    savings = invocation.get("byte_savings_by_path")
    if not isinstance(savings, dict):
        return 0
    bucket_data = savings.get(bucket)
    if not isinstance(bucket_data, dict):
        return 0
    return int(bucket_data.get(field) or 0)


def append_int_metric_row(
    rows: list[dict[str, Any]],
    *,
    label: str,
    baseline_value: int,
    candidate_value: int,
) -> None:
    delta = candidate_value - baseline_value
    rows.append(
        {
            "metric": label,
            "baseline": baseline_value,
            "candidate": candidate_value,
            "delta": delta,
            "pct_change": format_pct_change(delta, baseline_value),
        }
    )


def append_float_metric_row(
    rows: list[dict[str, Any]],
    *,
    label: str,
    baseline_value: float,
    candidate_value: float,
) -> None:
    delta = candidate_value - baseline_value
    rows.append(
        {
            "metric": label,
            "baseline": baseline_value,
            "candidate": candidate_value,
            "delta": delta,
            "pct_change": format_pct_change(delta, baseline_value),
        }
    )


def compute_token_deltas(
    baseline_inv: dict[str, Any],
    candidate_inv: dict[str, Any],
) -> list[dict[str, Any]]:
    rows: list[dict[str, Any]] = []
    for label, key in TOKEN_METRICS:
        append_int_metric_row(
            rows,
            label=label,
            baseline_value=token_value(baseline_inv, key),
            candidate_value=token_value(candidate_inv, key),
        )
    for label, key in DERIVED_INT_METRICS:
        append_int_metric_row(
            rows,
            label=label,
            baseline_value=token_value(baseline_inv, key),
            candidate_value=token_value(candidate_inv, key),
        )
    append_float_metric_row(
        rows,
        label="tool_turns/tool_calls_total",
        baseline_value=tool_turns_per_call(baseline_inv),
        candidate_value=tool_turns_per_call(candidate_inv),
    )
    append_float_metric_row(
        rows,
        label="cache_read_per_tool_turn",
        baseline_value=cache_read_per_tool_turn(baseline_inv),
        candidate_value=cache_read_per_tool_turn(candidate_inv),
    )
    return rows


def compute_byte_savings_deltas(
    baseline_inv: dict[str, Any],
    candidate_inv: dict[str, Any],
) -> list[dict[str, Any]]:
    rows: list[dict[str, Any]] = []
    for bucket in BYTE_SAVINGS_BUCKETS:
        for field in BYTE_SAVINGS_FIELDS:
            append_int_metric_row(
                rows,
                label=f"{bucket}.{field}",
                baseline_value=bucket_field_value(baseline_inv, bucket, field),
                candidate_value=bucket_field_value(candidate_inv, bucket, field),
            )
    return rows


TOOL_CALLS_GAP_WARNING_PCT = 20.0


def compute_verdict(
    baseline_inv: dict[str, Any],
    candidate_inv: dict[str, Any],
) -> dict[str, Any]:
    baseline_cache = token_value(baseline_inv, "cache_read_input_tokens")
    candidate_cache = token_value(candidate_inv, "cache_read_input_tokens")
    baseline_calls = token_value(baseline_inv, "tool_calls_total")
    candidate_calls = token_value(candidate_inv, "tool_calls_total")

    if candidate_cache < baseline_cache:
        winner = "candidate"
    elif baseline_cache < candidate_cache:
        winner = "baseline"
    else:
        winner = "tie"

    if baseline_calls == 0:
        calls_gap_pct: float | None = None if candidate_calls == 0 else float("inf")
        warn = candidate_calls != 0
    else:
        calls_gap_pct = abs(candidate_calls - baseline_calls) / baseline_calls * 100
        warn = calls_gap_pct > TOOL_CALLS_GAP_WARNING_PCT

    return {
        "winner": winner,
        "baseline_cache_read": baseline_cache,
        "candidate_cache_read": candidate_cache,
        "baseline_tool_calls": baseline_calls,
        "candidate_tool_calls": candidate_calls,
        "tool_calls_gap_pct": calls_gap_pct,
        "warning": warn,
    }


def format_verdict_line(verdict: dict[str, Any]) -> str:
    if verdict["winner"] == "candidate":
        text = "verdict: candidate used fewer cache_read tokens"
    elif verdict["winner"] == "baseline":
        text = "verdict: baseline used fewer cache_read tokens"
    else:
        text = "verdict: cache_read tokens tied"

    if verdict["warning"]:
        gap_pct = verdict["tool_calls_gap_pct"]
        if gap_pct is None:
            gap_text = "0%"
        elif gap_pct == float("inf"):
            gap_text = "n/a"
        else:
            gap_text = f"{gap_pct:.1f}%"
        text += (
            f"; WARNING: tool_calls_total differs by {gap_text} "
            "(not apples-to-apples)"
        )
    return text


def print_token_delta_table(rows: list[dict[str, Any]]) -> None:
    headers = ("metric", "baseline", "candidate", "delta", "pct_change")
    widths = {header: len(header) for header in headers}
    for row in rows:
        for header in headers:
            widths[header] = max(widths[header], len(str(row[header])))

    header_line = "  ".join(header.ljust(widths[header]) for header in headers)
    print(header_line)
    print("  ".join("-" * widths[header] for header in headers))
    for row in rows:
        values = (
            row["metric"],
            format_number(row["baseline"]),
            format_number(row["candidate"]),
            format_delta(row["delta"]),
            row["pct_change"],
        )
        print(
            "  ".join(
                str(value).ljust(widths[header])
                for header, value in zip(headers, values, strict=True)
            )
        )


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="Compare invocation-usage.json baseline and candidate files.",
    )
    parser.add_argument(
        "baseline",
        type=Path,
        help="Path to baseline invocation-usage.json",
    )
    parser.add_argument(
        "candidate",
        type=Path,
        help="Path to candidate invocation-usage.json",
    )
    parser.add_argument(
        "--json",
        action="store_true",
        help="Emit the load summary as JSON",
    )
    args = parser.parse_args(argv)

    baseline_data = load_usage(args.baseline)
    candidate_data = load_usage(args.candidate)
    baseline_inv = resolve_target(baseline_data["invocations"], label=str(args.baseline))
    candidate_inv = resolve_target(candidate_data["invocations"], label=str(args.candidate))

    baseline_iteration = int(baseline_inv.get("iteration") or 0)
    candidate_iteration = int(candidate_inv.get("iteration") or 0)
    token_deltas = compute_token_deltas(baseline_inv, candidate_inv)
    byte_savings_deltas = compute_byte_savings_deltas(baseline_inv, candidate_inv)
    verdict = compute_verdict(baseline_inv, candidate_inv)
    verdict_line = format_verdict_line(verdict)

    if args.json:
        summary = {
            "status": "loaded OK",
            "baseline": {
                "path": str(args.baseline),
                "iteration": baseline_iteration,
                "tool_turns": int(baseline_inv.get("tool_turns") or 0),
            },
            "candidate": {
                "path": str(args.candidate),
                "iteration": candidate_iteration,
                "tool_turns": int(candidate_inv.get("tool_turns") or 0),
            },
            "token_deltas": token_deltas,
            "byte_savings_deltas": byte_savings_deltas,
            "verdict": verdict,
            "verdict_line": verdict_line,
        }
        print(json.dumps(summary, sort_keys=True))
    else:
        print(
            "loaded OK: "
            f"baseline iteration={baseline_iteration}, "
            f"candidate iteration={candidate_iteration}"
        )
        print_token_delta_table(token_deltas)
        print()
        print("byte_savings_by_path:")
        print_token_delta_table(byte_savings_deltas)
        print()
        print(verdict_line)
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, ValueError, json.JSONDecodeError) as exc:
        print(f"error: {exc}", file=sys.stderr)
        raise SystemExit(1) from exc
