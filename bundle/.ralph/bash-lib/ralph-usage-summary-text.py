#!/usr/bin/env python3
"""Render Ralph plan and orchestration usage summaries as plain text."""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
from typing import Any, Dict, List, Sequence, Tuple


def emit(line: str = "") -> None:
    sys.stdout.buffer.write((line + "\n").encode("ascii", "backslashreplace"))


_COLOR_ENABLED = sys.stdout.isatty() and os.environ.get("NO_COLOR", "") == ""
_COLOR_CODES = {
    "reset": "\x1b[0m",
    "bold": "\x1b[1m",
    "dim": "\x1b[2m",
    "red": "\x1b[31m",
    "green": "\x1b[32m",
    "yellow": "\x1b[33m",
    "blue": "\x1b[34m",
    "magenta": "\x1b[35m",
    "cyan": "\x1b[36m",
    "bold_cyan": "\x1b[1;36m",
    "bold_white": "\x1b[1;37m",
}
_ANSI_RE = re.compile(r"\x1b\[[0-9;]*m")


def c(name: str, text: str) -> str:
    if not _COLOR_ENABLED:
        return text
    code = _COLOR_CODES.get(name, "")
    if not code:
        return text
    return f"{code}{text}{_COLOR_CODES['reset']}"


def visible_len(text: str) -> int:
    return len(_ANSI_RE.sub("", text))


def color_cache_hit(ratio: Any) -> str:
    text = fmt_pct(ratio)
    try:
        r = float(ratio) if ratio not in (None, "") else 0.0
    except (TypeError, ValueError):
        r = 0.0
    if r >= 0.9:
        return c("green", text)
    if r >= 0.7:
        return c("yellow", text)
    if r > 0:
        return c("red", text)
    return c("dim", text)


def render_table(
    headers: Sequence[str],
    rows: Sequence[Sequence[str]],
    aligns: Sequence[str],
    indent: str = "  ",
) -> List[str]:
    widths = [visible_len(h) for h in headers]
    for row in rows:
        for i, cell in enumerate(row):
            if i < len(widths):
                widths[i] = max(widths[i], visible_len(cell))

    def pad(cell: str, width: int, align: str) -> str:
        gap = width - visible_len(cell)
        if gap < 0:
            gap = 0
        if align == "r":
            return " " + (" " * gap) + cell + " "
        return " " + cell + (" " * gap) + " "

    border = "+" + "+".join("-" * (w + 2) for w in widths) + "+"
    border_line = indent + c("dim", border)

    def format_row(row: Sequence[str], align_row: Sequence[str]) -> str:
        cells = [pad(cell, widths[i], align_row[i] if i < len(align_row) else "l") for i, cell in enumerate(row)]
        return indent + c("dim", "|") + c("dim", "|").join(cells) + c("dim", "|")

    header_cells = [c("bold_cyan", h) for h in headers]
    header_aligns = ["l"] * len(headers)

    lines = [border_line, format_row(header_cells, header_aligns), border_line]
    for row in rows:
        lines.append(format_row(list(row), list(aligns)))
    lines.append(border_line)
    return lines


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


def load_json_quiet(path: str) -> Any:
    """Return parsed JSON or None on any error, without printing to stderr."""
    try:
        with open(path, "r", encoding="utf-8") as fh:
            return json.load(fh)
    except (FileNotFoundError, PermissionError, OSError, json.JSONDecodeError, UnicodeDecodeError):
        return None


def fmt_int(value: Any) -> str:
    n = as_int(value, 0)
    return f"{n:,}"


def fmt_pct(value: Any) -> str:
    if value in (None, ""):
        return "0.00%"
    try:
        ratio = float(value)
    except (TypeError, ValueError):
        return "0.00%"
    return f"{ratio * 100:.2f}%"


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


def format_elapsed(seconds: Any) -> str:
    total = as_int(seconds, 0)
    if total <= 0:
        return "0s"
    h = total // 3600
    rem = total % 3600
    m = rem // 60
    s = rem % 60
    if h > 0:
        return f"{h}h {m}m {s}s"
    elif m > 0:
        return f"{m}m {s}s"
    else:
        return f"{s}s"


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
        "elapsed_seconds": sum(as_int(r.get("elapsed_seconds")) for r in records),
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


def discover_summaries(logs_dir: str) -> Tuple[List[Tuple[str, str]], List[Tuple[str, str]]]:
    plans: List[Tuple[str, str]] = []
    orchestrations: List[Tuple[str, str]] = []

    if not os.path.isdir(logs_dir):
        return plans, orchestrations

    try:
        for entry in os.listdir(logs_dir):
            entry_path = os.path.join(logs_dir, entry)
            if not os.path.isdir(entry_path):
                continue

            plan_summary = os.path.join(entry_path, "plan-usage-summary.json")
            if os.path.isfile(plan_summary):
                invocations = os.path.join(entry_path, "invocation-usage.json")
                plans.append((plan_summary, invocations))

            orch_summary = os.path.join(entry_path, "orchestration-usage-summary.json")
            if os.path.isfile(orch_summary):
                invocations = os.path.join(entry_path, "invocation-usage.json")
                orchestrations.append((orch_summary, invocations))
    except (OSError, IOError):
        pass

    return plans, orchestrations


def aggregate_all(plans: List[Tuple[str, str]], orchestrations: List[Tuple[str, str]]) -> Dict[str, Any]:
    all_invocations: List[Dict[str, Any]] = []
    plan_summaries: Dict[str, Dict[str, Any]] = {}
    orch_summaries: Dict[str, Dict[str, Any]] = {}
    runtime_buckets: Dict[str, Dict[str, Any]] = {}

    for summary_path, invocations_path in plans:
        summary = load_json_quiet(summary_path)
        if isinstance(summary, dict):
            plan_summaries[summary_path] = summary

    for summary_path, invocations_path in orchestrations:
        summary = load_json_quiet(summary_path)
        if isinstance(summary, dict):
            orch_summaries[summary_path] = summary

    loaded_plans = [(s, i) for (s, i) in plans if s in plan_summaries]
    loaded_orchestrations = [(s, i) for (s, i) in orchestrations if s in orch_summaries]

    for summary_path, invocations_path in loaded_plans + loaded_orchestrations:
        invocation_doc = load_json_quiet(invocations_path) if os.path.isfile(invocations_path) else None
        invocations = []
        if isinstance(invocation_doc, dict):
            invocations = invocation_doc.get("invocations", []) or []
        elif isinstance(invocation_doc, list):
            invocations = invocation_doc

        if invocations:
            all_invocations.extend(invocations)

        for record in invocations:
            if not isinstance(record, dict):
                continue
            rt = as_text(record.get("runtime")).strip() or "-"
            if rt not in runtime_buckets:
                runtime_buckets[rt] = {
                    "input_tokens": 0,
                    "output_tokens": 0,
                    "cache_creation_input_tokens": 0,
                    "cache_read_input_tokens": 0,
                    "max_turn_total_tokens": 0,
                    "elapsed_seconds": 0,
                    "invocation_count": 0,
                }
            bucket = runtime_buckets[rt]
            bucket["input_tokens"] += as_int(record.get("input_tokens"))
            bucket["output_tokens"] += as_int(record.get("output_tokens"))
            bucket["cache_creation_input_tokens"] += as_int(record.get("cache_creation_input_tokens"))
            bucket["cache_read_input_tokens"] += as_int(record.get("cache_read_input_tokens"))
            bucket["elapsed_seconds"] += float(record.get("elapsed_seconds", 0)) if record.get("elapsed_seconds") else 0.0
            max_turn = as_int(record.get("max_turn_total_tokens"))
            if max_turn > bucket["max_turn_total_tokens"]:
                bucket["max_turn_total_tokens"] = max_turn
            bucket["invocation_count"] += 1

    overall_totals = aggregate(all_invocations)
    denom = overall_totals["input_tokens"] + overall_totals["cache_creation_input_tokens"] + overall_totals["cache_read_input_tokens"]
    overall_totals["cache_hit_ratio"] = round(overall_totals["cache_read_input_tokens"] / denom, 4) if denom > 0 else 0
    overall_totals["elapsed_seconds"] = sum(
        float(s.get("elapsed_seconds", 0)) for s in plan_summaries.values() if s.get("elapsed_seconds")
    ) + sum(
        float(s.get("elapsed_seconds", 0)) for s in orch_summaries.values() if s.get("elapsed_seconds")
    )
    overall_totals["invocation_count"] = len(all_invocations)
    overall_totals["plan_count"] = len(plan_summaries)
    overall_totals["orchestration_count"] = len(orch_summaries)

    for runtime in runtime_buckets:
        bucket = runtime_buckets[runtime]
        denom = bucket["input_tokens"] + bucket["cache_creation_input_tokens"] + bucket["cache_read_input_tokens"]
        bucket["cache_hit_ratio"] = round(bucket["cache_read_input_tokens"] / denom, 4) if denom > 0 else 0

    by_model = aggregate_by_model(all_invocations)

    return {
        "overall": overall_totals,
        "by_runtime": runtime_buckets,
        "by_model": by_model,
        "plan_summaries": plan_summaries,
        "orch_summaries": orch_summaries,
        "loaded_plans": loaded_plans,
        "loaded_orchestrations": loaded_orchestrations,
    }


def summarize_all(aggregated: Dict[str, Any], plans: List[Tuple[str, str]], orchestrations: List[Tuple[str, str]], workspace: str = "", logs_dir: str = "") -> None:
    emit(c("bold_cyan", "Ralph usage report"))
    if workspace:
        emit(f"  {c('dim', 'Workspace:')} {workspace}")
    if logs_dir:
        emit(f"  {c('dim', 'Logs dir: ')} {logs_dir}")
    emit()

    overall = aggregated["overall"]
    plan_count = as_int(overall.get("plan_count"), len(aggregated.get("plan_summaries") or {}))
    orch_count = as_int(overall.get("orchestration_count"), len(aggregated.get("orch_summaries") or {}))
    emit(c("bold", "Overall totals"))
    emit(
        f"  plans={c('bold', str(plan_count))} "
        f"orchestrations={c('bold', str(orch_count))} "
        f"invocations={c('bold', str(overall.get('invocation_count', 0)))} "
        f"elapsed={c('bold', format_elapsed(overall.get('elapsed_seconds')))}"
    )
    emit(
        f"  input={fmt_int(overall.get('input_tokens'))} "
        f"output={fmt_int(overall.get('output_tokens'))} "
        f"cache_create={fmt_int(overall.get('cache_creation_input_tokens'))} "
        f"cache_read={fmt_int(overall.get('cache_read_input_tokens'))}"
    )
    emit(
        f"  max_turn={fmt_int(overall.get('max_turn_total_tokens'))} "
        f"cache_hit={color_cache_hit(overall.get('cache_hit_ratio'))}"
    )
    emit()

    by_runtime = aggregated["by_runtime"]
    emit(c("bold", f"By runtime ({len(by_runtime)}):"))
    if by_runtime:
        headers = ["runtime", "invocations", "elapsed", "input", "output", "cache_create", "cache_read", "cache_hit"]
        aligns = ["l", "r", "r", "r", "r", "r", "r", "r"]
        rows = []
        for runtime in sorted(by_runtime.keys()):
            agg = by_runtime[runtime]
            rows.append([
                runtime,
                str(agg.get("invocation_count", 0)),
                format_elapsed(agg.get("elapsed_seconds")),
                fmt_int(agg.get("input_tokens")),
                fmt_int(agg.get("output_tokens")),
                fmt_int(agg.get("cache_creation_input_tokens")),
                fmt_int(agg.get("cache_read_input_tokens")),
                color_cache_hit(agg.get("cache_hit_ratio")),
            ])
        for line in render_table(headers, rows, aligns):
            emit(line)
    else:
        emit("  (none)")
    emit()

    by_model = aggregated["by_model"]
    emit(c("bold", f"By model ({len(by_model)}):"))
    if by_model:
        headers = ["model", "runtime", "invocations", "elapsed", "input", "output", "cache_read", "cache_hit"]
        aligns = ["l", "l", "r", "r", "r", "r", "r", "r"]
        rows = []
        sorted_models = sorted(
            by_model,
            key=lambda m: as_int(m[1].get("elapsed_seconds")),
            reverse=True,
        )
        for model_name, agg, recs in sorted_models:
            runtimes = runtimes_for_model(list(recs))
            rows.append([
                model_name,
                runtimes,
                str(agg.get("invocation_count", len(recs))),
                format_elapsed(agg.get("elapsed_seconds")),
                fmt_int(agg.get("input_tokens")),
                fmt_int(agg.get("output_tokens")),
                fmt_int(agg.get("cache_read_input_tokens")),
                color_cache_hit(agg.get("cache_hit_ratio")),
            ])
        for line in render_table(headers, rows, aligns):
            emit(line)
    else:
        emit("  (none)")
    emit()

    plan_summaries = aggregated.get("plan_summaries") or {}
    loaded_plans = aggregated.get("loaded_plans") or [
        (s, i) for (s, i) in plans if s in plan_summaries
    ]
    emit(c("bold", f"Plans ({len(loaded_plans)}):"))
    if loaded_plans:
        def _plan_sort_key(entry: Tuple[str, str]) -> str:
            s = plan_summaries.get(entry[0], {})
            return as_text(s.get("started_at")).strip() or entry[0]

        headers = ["plan", "runtime", "model", "invocations", "todos", "elapsed", "input", "output", "cache_hit", "status"]
        aligns = ["l", "l", "l", "r", "r", "r", "r", "r", "r", "l"]
        rows = []
        for summary_path, invocations_path in sorted(loaded_plans, key=_plan_sort_key, reverse=True):
            summary = plan_summaries.get(summary_path) or {}
            plan_key = as_text(summary.get("plan_key")).strip() or "-"
            runtime = as_text(summary.get("runtime")).strip() or "-"
            model = as_text(summary.get("model")).strip() or "-"
            invocations = as_int(summary.get("invocations"), 0)
            todos_done = as_int(summary.get("todos_done"), 0)
            todos_total = as_int(summary.get("todos_total"), 0)
            elapsed = format_elapsed(summary.get("elapsed_seconds", 0))
            input_tokens = fmt_int(summary.get("input_tokens", 0))
            output_tokens = fmt_int(summary.get("output_tokens", 0))
            cache_hit_val = summary.get("cache_hit_ratio", 0)
            status = c("yellow", "incomplete") if todos_done < todos_total else c("dim", "ok")
            rows.append([
                plan_key,
                runtime,
                model,
                str(invocations),
                f"{todos_done}/{todos_total}",
                elapsed,
                input_tokens,
                output_tokens,
                color_cache_hit(cache_hit_val),
                status,
            ])
        for line in render_table(headers, rows, aligns):
            emit(line)
    else:
        emit("  (none)")
    emit()

    orch_summaries = aggregated.get("orch_summaries") or {}
    loaded_orchestrations = aggregated.get("loaded_orchestrations") or [
        (s, i) for (s, i) in orchestrations if s in orch_summaries
    ]
    emit(c("bold", f"Orchestrations ({len(loaded_orchestrations)}):"))
    if loaded_orchestrations:
        headers = ["artifact_ns", "steps", "elapsed", "input", "output", "cache_read"]
        aligns = ["l", "r", "r", "r", "r", "r"]
        rows = []
        stage_lines: List[Tuple[str, List[List[str]]]] = []
        for summary_path, invocations_path in loaded_orchestrations:
            summary = orch_summaries.get(summary_path) or {}
            ns = as_text(summary.get("artifact_ns")).strip() or as_text(summary.get("plan_key")).strip() or "-"
            steps = as_int(summary.get("steps"), 0)
            elapsed = format_elapsed(summary.get("elapsed_seconds", 0))
            input_tokens = fmt_int(summary.get("input_tokens", 0))
            output_tokens = fmt_int(summary.get("output_tokens", 0))
            cache_read = fmt_int(summary.get("cache_read_input_tokens", 0))
            rows.append([ns, str(steps), elapsed, input_tokens, output_tokens, cache_read])

            stages = summary.get("stages")
            if not isinstance(stages, list):
                stages = []
            srows: List[List[str]] = []
            for idx, stage in enumerate(stages, 1):
                if not isinstance(stage, dict):
                    continue
                stage_total = aggregate([stage])
                denom = stage_total["input_tokens"] + stage_total["cache_creation_input_tokens"] + stage_total["cache_read_input_tokens"]
                ratio = (stage_total["cache_read_input_tokens"] / denom) if denom > 0 else 0
                step = as_text(stage.get("step")).strip() or str(idx)
                srows.append([
                    step,
                    as_text(stage.get("agent")).strip() or "-",
                    as_text(stage.get("runtime")).strip() or "-",
                    fmt_int(stage.get("input_tokens")),
                    fmt_int(stage.get("output_tokens")),
                    color_cache_hit(ratio),
                ])
            if srows:
                stage_lines.append((ns, srows))

        for line in render_table(headers, rows, aligns):
            emit(line)

        for ns, srows in stage_lines:
            emit()
            emit(c("dim", f"  stages for {ns}:"))
            sheaders = ["step", "agent", "runtime", "input", "output", "cache_hit"]
            saligns = ["l", "l", "l", "r", "r", "r"]
            for line in render_table(sheaders, srows, saligns, indent="    "):
                emit(line)
    else:
        emit("  (none)")


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

    all_mode = subparsers.add_parser("all", help="Aggregate and render usage summaries for all plans and orchestrations.")
    all_mode.add_argument("--logs-dir", required=True, help="Directory containing plan and orchestration logs")
    all_mode.add_argument("--format", choices=["text", "json"], default="text", help="Output format (default: text)")
    all_mode.add_argument("--workspace", default=None, help="Workspace path (informational, included in output header)")

    return parser.parse_args(argv)


def main(argv: Sequence[str]) -> int:
    args = parse_args(argv)

    if args.mode == "all":
        plans, orchestrations = discover_summaries(args.logs_dir)
        aggregated = aggregate_all(plans, orchestrations)

        if args.format == "json":
            plan_summaries = aggregated.get("plan_summaries") or {}
            orch_summaries = aggregated.get("orch_summaries") or {}
            plans_data = [plan_summaries[p] for p, _ in (aggregated.get("loaded_plans") or []) if p in plan_summaries]
            orchestrations_data = [orch_summaries[p] for p, _ in (aggregated.get("loaded_orchestrations") or []) if p in orch_summaries]

            output = {
                "overall": aggregated["overall"],
                "by_runtime": aggregated["by_runtime"],
                "by_model": [
                    {
                        "model": model,
                        "invocation_count": agg.get("invocation_count"),
                        "input_tokens": agg.get("input_tokens"),
                        "output_tokens": agg.get("output_tokens"),
                        "cache_creation_input_tokens": agg.get("cache_creation_input_tokens"),
                        "cache_read_input_tokens": agg.get("cache_read_input_tokens"),
                        "max_turn_total_tokens": agg.get("max_turn_total_tokens"),
                        "cache_hit_ratio": agg.get("cache_hit_ratio"),
                    }
                    for model, agg, recs in aggregated["by_model"]
                ],
                "plans": plans_data,
                "orchestrations": orchestrations_data,
            }
            emit(json.dumps(output, sort_keys=True))
        else:
            summarize_all(aggregated, plans, orchestrations, args.workspace, args.logs_dir)
        return 0

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
