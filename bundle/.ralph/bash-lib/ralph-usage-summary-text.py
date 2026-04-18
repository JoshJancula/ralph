#!/usr/bin/env python3
"""Render Ralph plan and orchestration usage summaries as plain text."""

from __future__ import annotations

import argparse
import json
import os
import sys
from typing import Any, Dict, List, Sequence, Tuple


def emit(line: str = "") -> None:
    sys.stdout.buffer.write((line + "\n").encode("ascii", "backslashreplace"))


def fail(message: str) -> "None":
    sys.stderr.write(message + "\n")
    raise SystemExit(2)


def load_json(path: str) -> Any:
    try:
        with open(path, "r", encoding="utf-8") as fh:
            return json.load(fh)
    except FileNotFoundError:
        fail(f"Error: file not found: {path}")
    except json.JSONDecodeError as exc:
        fail(f"Error: invalid JSON in {path}: {exc.msg}")


def as_text(value: Any) -> str:
    if value is None:
        return ""
    return str(value)


def as_int(value: Any, default: int = 0) -> int:
    if value in (None, ""):
        return default
    try:
        return int(value)
    except (TypeError, ValueError):
        try:
            return int(float(value))
        except (TypeError, ValueError):
            return default


def fmt_value(value: Any) -> str:
    if value in (None, ""):
        return "0"
    if isinstance(value, bool):
        return "1" if value else "0"
    if isinstance(value, int):
        return str(value)
    if isinstance(value, float):
        text = f"{value:.4f}".rstrip("0").rstrip(".")
        return text or "0"
    text = as_text(value).strip()
    if not text:
        return "0"
    try:
        number = float(text)
    except ValueError:
        return text
    return fmt_value(number)


def fmt_seconds(value: Any) -> str:
    if value in (None, ""):
        return "0s"
    return f"{fmt_value(value)}s"


def summary_timing(summary: Dict[str, Any]) -> str:
    started_at = as_text(summary.get("started_at")).strip()
    ended_at = as_text(summary.get("ended_at")).strip()
    elapsed_seconds = summary.get("elapsed_seconds")
    parts: List[str] = []
    if started_at:
        parts.append(f"started_at={started_at}")
    if ended_at:
        parts.append(f"ended_at={ended_at}")
    if not parts and elapsed_seconds is not None:
        parts.append(f"elapsed={fmt_seconds(elapsed_seconds)}")
    elif elapsed_seconds is not None:
        parts.append(f"elapsed={fmt_seconds(elapsed_seconds)}")
    return " ".join(parts)


def summary_value(summary: Dict[str, Any], key: str, records: Sequence[Dict[str, Any]], fallback: Any = 0) -> Any:
    if key in summary and summary.get(key) is not None:
        return summary.get(key)
    if key == "max_turn_total_tokens":
        return max((as_int(r.get("max_turn_total_tokens")) for r in records), default=0)
    if key == "cache_hit_ratio":
        input_tokens = as_int(summary_value(summary, "input_tokens", records))
        cache_create = as_int(summary_value(summary, "cache_creation_input_tokens", records))
        cache_read = as_int(summary_value(summary, "cache_read_input_tokens", records))
        denom = input_tokens + cache_create + cache_read
        return round(cache_read / denom, 4) if denom > 0 else 0
    return fallback


def aggregate(records: Sequence[Dict[str, Any]]) -> Dict[str, Any]:
    return {
        "input_tokens": sum(as_int(r.get("input_tokens")) for r in records),
        "output_tokens": sum(as_int(r.get("output_tokens")) for r in records),
        "cache_creation_input_tokens": sum(as_int(r.get("cache_creation_input_tokens")) for r in records),
        "cache_read_input_tokens": sum(as_int(r.get("cache_read_input_tokens")) for r in records),
        "max_turn_total_tokens": max((as_int(r.get("max_turn_total_tokens")) for r in records), default=0),
    }


def model_label(record: Dict[str, Any]) -> str:
    return as_text(record.get("model")).strip() or "-"


def runtimes_for_model(records: Sequence[Dict[str, Any]]) -> str:
    seen = set()
    ordered: List[str] = []
    for r in records:
        if not isinstance(r, dict):
            continue
        rt = as_text(r.get("runtime")).strip() or "-"
        if rt not in seen:
            seen.add(rt)
            ordered.append(rt)
    return ",".join(ordered) if ordered else "-"


def aggregate_by_model(invocations: Sequence[Dict[str, Any]]) -> List[Tuple[str, Dict[str, Any], List[Dict[str, Any]]]]:
    """Group invocations by model; preserve first-seen model order."""
    buckets: Dict[str, List[Dict[str, Any]]] = {}
    order: List[str] = []
    for record in invocations:
        if not isinstance(record, dict):
            continue
        key = model_label(record)
        if key not in buckets:
            order.append(key)
            buckets[key] = []
        buckets[key].append(record)
    out: List[Tuple[str, Dict[str, Any], List[Dict[str, Any]]]] = []
    for key in order:
        recs = buckets[key]
        agg = aggregate(recs)
        denom = agg["input_tokens"] + agg["cache_creation_input_tokens"] + agg["cache_read_input_tokens"]
        agg["cache_hit_ratio"] = round(agg["cache_read_input_tokens"] / denom, 4) if denom > 0 else 0
        agg["invocation_count"] = len(recs)
        out.append((key, agg, recs))
    return out


def emit_model_totals_line(model_name: str, agg: Dict[str, Any], recs: Sequence[Dict[str, Any]]) -> None:
    rt = runtimes_for_model(list(recs))
    parts = [
        f"model={model_name}",
        f"runtime={rt}",
        f"invocations={agg.get('invocation_count', len(recs))}",
        f"input={fmt_value(agg.get('input_tokens'))}",
        f"output={fmt_value(agg.get('output_tokens'))}",
        f"cache_create={fmt_value(agg.get('cache_creation_input_tokens'))}",
        f"cache_read={fmt_value(agg.get('cache_read_input_tokens'))}",
        f"max_turn={fmt_value(agg.get('max_turn_total_tokens'))}",
        f"cache_hit_ratio={fmt_value(agg.get('cache_hit_ratio'))}",
    ]
    emit("  " + " ".join(parts))


def summarize_plan(summary: Dict[str, Any], invocations: Sequence[Dict[str, Any]], summary_path: str, invocations_path: str) -> None:
    emit("Plan usage summary")
    emit(f"Summary path: {os.path.abspath(summary_path)}")
    emit(f"Invocation path: {os.path.abspath(invocations_path)}")
    emit(
        "Summary: "
        f"plan={as_text(summary.get('plan')).strip() or '-'} "
        f"plan_key={as_text(summary.get('plan_key')).strip() or '-'} "
        f"stage_id={as_text(summary.get('stage_id')).strip() or '-'} "
        f"runtime={as_text(summary.get('runtime')).strip() or '-'} "
        f"model={as_text(summary.get('model')).strip() or '-'} "
        f"invocations={summary_value(summary, 'invocations', invocations, len(invocations))} "
        f"todos={summary_value(summary, 'todos_done', invocations, 0)}/{summary_value(summary, 'todos_total', invocations, 0)}"
    )
    timing = summary_timing(summary)
    if timing:
        emit(f"Window: {timing}")
    totals = aggregate(invocations)
    emit(
        "Totals: "
        f"input={fmt_value(summary_value(summary, 'input_tokens', invocations, totals['input_tokens']))} "
        f"output={fmt_value(summary_value(summary, 'output_tokens', invocations, totals['output_tokens']))} "
        f"cache_create={fmt_value(summary_value(summary, 'cache_creation_input_tokens', invocations, totals['cache_creation_input_tokens']))} "
        f"cache_read={fmt_value(summary_value(summary, 'cache_read_input_tokens', invocations, totals['cache_read_input_tokens']))} "
        f"max_turn={fmt_value(summary_value(summary, 'max_turn_total_tokens', invocations, totals['max_turn_total_tokens']))} "
        f"cache_hit_ratio={fmt_value(summary_value(summary, 'cache_hit_ratio', invocations, 0))}"
    )
    grouped = aggregate_by_model(invocations)
    emit(f"By model ({len(grouped)}):")
    for model_name, agg, recs in grouped:
        emit_model_totals_line(model_name, agg, recs)


def summarize_orch(summary: Dict[str, Any], invocations: Sequence[Dict[str, Any]], summary_path: str, invocations_path: str) -> None:
    emit("Orchestration usage summary")
    emit(f"Summary path: {os.path.abspath(summary_path)}")
    emit(f"Invocation path: {os.path.abspath(invocations_path)}")
    emit(
        "Summary: "
        f"orchestration={as_text(summary.get('orchestration')).strip() or '-'} "
        f"plan_key={as_text(summary.get('plan_key')).strip() or '-'} "
        f"artifact_ns={as_text(summary.get('artifact_ns')).strip() or '-'} "
        f"steps={summary_value(summary, 'steps', invocations, len(summary.get('stages', [])) if isinstance(summary.get('stages'), list) else len(invocations))} "
        f"input={fmt_value(summary_value(summary, 'input_tokens', invocations, aggregate(invocations)['input_tokens']))} "
        f"output={fmt_value(summary_value(summary, 'output_tokens', invocations, aggregate(invocations)['output_tokens']))} "
        f"cache_create={fmt_value(summary_value(summary, 'cache_creation_input_tokens', invocations, aggregate(invocations)['cache_creation_input_tokens']))} "
        f"cache_read={fmt_value(summary_value(summary, 'cache_read_input_tokens', invocations, aggregate(invocations)['cache_read_input_tokens']))}"
    )
    timing = summary_timing(summary)
    if timing:
        emit(f"Window: {timing}")
    grouped = aggregate_by_model(invocations)
    emit(f"By model ({len(grouped)}):")
    for model_name, agg, recs in grouped:
        emit_model_totals_line(model_name, agg, recs)
    stages = summary.get("stages")
    if not isinstance(stages, list):
        stages = []
    emit(f"Stages ({len(stages)}):")
    for idx, stage in enumerate(stages, 1):
        if not isinstance(stage, dict):
            continue
        stage_total = aggregate([stage])
        denom = stage_total["input_tokens"] + stage_total["cache_creation_input_tokens"] + stage_total["cache_read_input_tokens"]
        cache_hit = fmt_value(round(stage_total["cache_read_input_tokens"] / denom, 4)) if denom > 0 else "0"
        step = as_text(stage.get("step")).strip() or str(idx)
        emit(
            "  "
            + " ".join(
                [
                    f"step={step}",
                    f"agent={as_text(stage.get('agent')).strip() or '-'}",
                    f"runtime={as_text(stage.get('runtime')).strip() or '-'}",
                    f"input={fmt_value(stage.get('input_tokens'))}",
                    f"output={fmt_value(stage.get('output_tokens'))}",
                    f"cache_create={fmt_value(stage.get('cache_creation_input_tokens'))}",
                    f"cache_read={fmt_value(stage.get('cache_read_input_tokens'))}",
                    f"cache_hit_ratio={cache_hit}",
                ]
            )
        )


def parse_args(argv: Sequence[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        prog="ralph-usage-summary-text.py",
        description="Render Ralph usage summary JSON as plain ASCII text.",
    )
    subparsers = parser.add_subparsers(dest="mode")
    subparsers.required = True

    plan = subparsers.add_parser("plan", help="Render plan usage summary text.")
    plan.add_argument("--summary", required=True, help="Path to plan-usage-summary.json")
    plan.add_argument("--invocations", required=True, help="Path to invocation-usage.json")

    orch = subparsers.add_parser("orch", help="Render orchestration usage summary text.")
    orch.add_argument("--summary", required=True, help="Path to orchestration-usage-summary.json")
    orch.add_argument("--invocations", required=True, help="Path to invocation-usage.json")

    return parser.parse_args(argv)


def main(argv: Sequence[str]) -> int:
    args = parse_args(argv)
    summary = load_json(args.summary)
    invocation_doc = load_json(args.invocations)
    if isinstance(invocation_doc, dict):
        invocations = invocation_doc.get("invocations", [])
    else:
        invocations = invocation_doc
    if not isinstance(summary, dict):
        fail(f"Error: summary JSON must be an object: {args.summary}")
    if not isinstance(invocations, list):
        fail(f"Error: invocations JSON must contain a list: {args.invocations}")
    if args.mode == "plan":
        summarize_plan(summary, invocations, args.summary, args.invocations)
    elif args.mode == "orch":
        summarize_orch(summary, invocations, args.summary, args.invocations)
    else:
        fail(f"Error: unsupported mode: {args.mode}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
