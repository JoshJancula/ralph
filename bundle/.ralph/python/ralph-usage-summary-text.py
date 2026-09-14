#!/usr/bin/env python3
"""Render Ralph plan and orchestration usage summaries as plain text."""

from __future__ import annotations

import argparse
import importlib.util
import json
import os
import re
import sys
from typing import Any, Dict, List, Sequence, Set, Tuple

sys.path.insert(0, os.path.dirname(__file__))

_SAVINGS_REPORT_PATH = os.path.join(os.path.dirname(__file__), "ralph-benchmark-report.py")

def _load_savings_report_module() -> Any | None:
    try:
        spec = importlib.util.spec_from_file_location("ralph_benchmark_report", _SAVINGS_REPORT_PATH)
        if spec is None or spec.loader is None:
            return None
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        return module
    except (OSError, ImportError, ValueError, AttributeError):
        return None

_SAVINGS_REPORT_MODULE = _load_savings_report_module()

from tool_call_classification import SAVINGS_PATH_NAMES
from usage_accounting import aggregate_records, normalize_usage


def emit(line: str = "") -> None:
    sys.stdout.buffer.write((line + "\n").encode("utf-8"))


# RALPH_USAGE_SUMMARY_COLOR=1 forces color when the caller captures stdout
# (command substitution) but ultimately prints to a color-capable terminal.
_COLOR_ENABLED = os.environ.get("NO_COLOR", "") == "" and (
    sys.stdout.isatty() or os.environ.get("RALPH_USAGE_SUMMARY_COLOR", "") == "1"
)
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
ROW_DIVIDER = "__RALPH_ROW_DIVIDER__"
# Horizontal rule only under columns after "project" — keeps the project column visually open within a workspace group.
ROW_DIVIDER_WITHIN_PROJECT = "__RALPH_ROW_DIVIDER_WITHIN_PROJECT__"
# Limit plan column width in aggregate text tables (long artifact filenames should not stretch the whole row).
PLAN_COLUMN_DISPLAY_MAX = 36
# TOOL_BREAKDOWN_KEYS captures transcript-level tool call counters.
# These are aggregated across invocations and reported in usage summaries.
# Key distinctions (four semantic layers):
# 1) Ralph proxy adoption: ralph_proxy_calls (actual Ralph MCP tool calls from transcript)
# 2) Transcript-level hook-tool counters: runtime_hook_rewrite_calls, runtime_hook_compaction_calls
#    (hook-shaped tool calls recorded in CLI transcript, distinct from overlay-observed activity)
# 3) Overlay-observed hook activity: hook_rewrites, hook_compactions, hook_original_bytes,
#    hook_compacted_bytes, native_hook_events (from overlay journals: bash-rewrite.jsonl,
#    bash-compact.jsonl, proxy-shell-compact.jsonl)
# 4) Capability flags: native_hooks_effective (proven capability on tested build),
#    native_hooks_used_on_run (true when hook telemetry observed events this run)
# - native_*_calls: native tool calls from transcript (including exploration, read, write)
TOOL_BREAKDOWN_KEYS = (
    "native_read_like_calls",
    "native_write_like_calls",
    "ralph_proxy_calls",
    "other_mcp_calls",
    "runtime_hook_rewrite_calls",
    "runtime_hook_compaction_calls",
    "unknown_tool_calls",
)


def c(name: str, text: str) -> str:
    if not _COLOR_ENABLED:
        return text
    code = _COLOR_CODES.get(name, "")
    if not code:
        return text
    return f"{code}{text}{_COLOR_CODES['reset']}"


def visible_len(text: str) -> int:
    return len(_ANSI_RE.sub("", text))


def truncate_plan_display(text: str, max_len: int = PLAN_COLUMN_DISPLAY_MAX) -> str:
    """Shorten plan labels for table display (plain text cells; keeps terminal tables readable)."""
    if max_len <= 0:
        return text
    if visible_len(text) <= max_len:
        return text
    if max_len <= 3:
        return text[:max_len]
    return text[: max_len - 3] + "..."


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


def fmt_tokens(value: Any) -> str:
    """Comma-format integer token counts; defer to fmt_value otherwise."""
    try:
        return f"{int(value):,}"
    except (TypeError, ValueError):
        return fmt_value(value)


# Cache pricing, as multiples of the model's base input-token price.
# Reads are cheap; writes are priced by the TTL of the breakpoint they land on.
CACHE_READ_PRICE = 0.10
CACHE_WRITE_5M_PRICE = 1.25
CACHE_WRITE_1H_PRICE = 2.00


def cache_write_price(tokens_5m: int, tokens_1h: int, total: int) -> float:
    """Blended write price for a measured 5m/1h TTL mix.

    Falls back to the 1-hour rate when the split is unreported: measured Claude
    Code runs write entirely at the 1-hour TTL, so assuming the cheaper 5-minute
    rate would understate cost on exactly the runtime this reports on most.
    """
    split_total = max(0, tokens_5m) + max(0, tokens_1h)
    if split_total <= 0:
        return CACHE_WRITE_1H_PRICE
    return (
        max(0, tokens_5m) * CACHE_WRITE_5M_PRICE
        + max(0, tokens_1h) * CACHE_WRITE_1H_PRICE
    ) / split_total


def cache_write_cost_share(
    cache_read: Any, cache_create: Any, tokens_5m: Any = 0, tokens_1h: Any = 0
) -> int:
    """Percent of cached-token spend attributable to the cache-write premium.

    Token counts alone misrepresent cost: writes are a small fraction of cached
    volume but a large fraction of the bill. A high share means writes were not
    amortized -- the invocation paid the write premium on context it then barely
    re-read. Break-even is ~2 reads per write at the 5-minute TTL and ~3 at the
    1-hour TTL.
    """
    write_tokens = max(0, as_int(cache_create))
    price = cache_write_price(as_int(tokens_5m), as_int(tokens_1h), write_tokens)
    read_cost = max(0, as_int(cache_read)) * CACHE_READ_PRICE
    write_cost = write_tokens * price
    total = read_cost + write_cost
    return round(100 * write_cost / total) if total > 0 else 0


def color_write_cost_token(share: int) -> str:
    """Render a write_cost=<pct>% token; high shares are the expensive case."""
    text = f"write_cost={share}%"
    if share >= 60:
        return c("red", text)
    if share >= 40:
        return c("yellow", text)
    return c("green", text)


def color_cache_hit_token(ratio: Any) -> str:
    """Render a cache_hit_ratio=<value> token, colored by ratio but keeping the raw value."""
    text = f"cache_hit_ratio={fmt_value(ratio)}"
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
        if len(row) == 1 and row[0] in (ROW_DIVIDER, ROW_DIVIDER_WITHIN_PROJECT):
            continue
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
        if len(row) == 1 and row[0] == ROW_DIVIDER:
            lines.append(border_line)
        elif len(row) == 1 and row[0] == ROW_DIVIDER_WITHIN_PROJECT:
            if len(widths) <= 1:
                lines.append(border_line)
            else:
                inner = (
                    "|"
                    + pad("", widths[0], "l")
                    + "+"
                    + "+".join("-" * (w + 2) for w in widths[1:])
                    + "+"
                )
                lines.append(indent + c("dim", inner))
        else:
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
    if key == "cache_hit_ratio" or key == "cache_efficiency_ratio":
        if key in summary and summary.get(key) is not None:
            return summary.get(key)
        canonical = normalize_usage(summary) if not records else aggregate_records(records)
        return canonical.get("cache_efficiency_ratio", canonical.get("cache_hit_ratio", 0))
    if key in {"cache_read_per_tool_turn", "cache_read_per_tool_call"}:
        cache_read = as_int(summary_value(summary, "cache_read_input_tokens", records))
        tool_turns = as_int(summary_value(summary, "tool_turns", records, 0))
        tool_calls = as_int(summary_value(summary, "tool_calls_total", records, 0))
        per_turn, per_call = derive_cache_read_ratios(cache_read, tool_turns, tool_calls)
        return per_turn if key.endswith("turn") else per_call
    return fallback


def latest_byte_savings_by_path(
    summary: Dict[str, Any],
    records: Sequence[Dict[str, Any]],
) -> Dict[str, Dict[str, Any]]:
    """Return final per-path savings, preferring the summary-level snapshot."""
    summary_savings = summary.get("byte_savings_by_path")
    if isinstance(summary_savings, dict):
        out: Dict[str, Dict[str, Any]] = {}
        for path_name in SAVINGS_PATH_NAMES:
            path_data = summary_savings.get(path_name)
            if isinstance(path_data, dict):
                out[path_name] = path_data
        if out:
            return out

    latest: Dict[str, Dict[str, Any]] = {}
    for record in records:
        savings = record.get("byte_savings_by_path")
        if not isinstance(savings, dict):
            continue
        for path_name in SAVINGS_PATH_NAMES:
            path_data = savings.get(path_name)
            if isinstance(path_data, dict):
                latest[path_name] = path_data
    return latest


def aggregate(records: Sequence[Dict[str, Any]]) -> Dict[str, Any]:
    canonical = aggregate_records(records)
    totals = {
        "input_tokens": canonical["input_tokens"],
        "output_tokens": canonical["output_tokens"],
        "cache_creation_input_tokens": canonical["cache_creation_input_tokens"],
        "cache_read_input_tokens": canonical["cache_read_input_tokens"],
        "uncached_input_tokens": canonical["uncached_input_tokens"],
        "total_input_tokens": canonical["total_input_tokens"],
        "cache_efficiency_ratio": canonical["cache_efficiency_ratio"],
        "cache_hit_ratio": canonical["cache_hit_ratio"],
        "measurement_source": canonical["measurement_source"],
        "max_turn_total_tokens": max((as_int(r.get("max_turn_total_tokens")) for r in records), default=0),
        "elapsed_seconds": sum(as_int(r.get("elapsed_seconds")) for r in records),
        "tool_calls_total": sum(as_int(r.get("tool_calls_total")) for r in records),
        "tool_turns": sum(as_int(r.get("tool_turns")) for r in records),
    }
    for key in TOOL_BREAKDOWN_KEYS:
        totals[key] = sum(as_int(r.get(key)) for r in records)
    return totals


def derive_cache_read_ratios(cache_read: Any, tool_turns: Any, tool_calls: Any) -> Tuple[float, float]:
    cache_read = float(cache_read or 0)
    tool_turns = int(tool_turns or 0)
    tool_calls = int(tool_calls or 0)
    denom = tool_turns if tool_turns > 0 else (tool_calls if tool_calls > 0 else 1)
    per_turn = cache_read / denom if denom else 0.0
    per_call = cache_read / tool_calls if tool_calls > 0 else 0.0
    return per_turn, per_call


def parse_invocations_doc(invocation_doc: Any) -> List[Dict[str, Any]]:
    if isinstance(invocation_doc, dict):
        invocations = invocation_doc.get("invocations", []) or []
    elif isinstance(invocation_doc, list):
        invocations = invocation_doc
    else:
        invocations = []
    if not isinstance(invocations, list):
        return []
    return [record for record in invocations if isinstance(record, dict)]


def plan_summary_with_invocation_fallback(summary: Dict[str, Any], invocations: Sequence[Dict[str, Any]]) -> Dict[str, Any]:
    effective = dict(summary)
    if not invocations:
        return effective

    totals = aggregate(invocations)
    canonical = normalize_usage(summary) if not invocations else totals
    effective["invocations"] = len(invocations)
    effective["elapsed_seconds"] = totals["elapsed_seconds"]
    effective["input_tokens"] = totals["input_tokens"]
    effective["output_tokens"] = totals["output_tokens"]
    effective["cache_creation_input_tokens"] = totals["cache_creation_input_tokens"]
    effective["cache_read_input_tokens"] = totals["cache_read_input_tokens"]
    effective["uncached_input_tokens"] = totals.get("uncached_input_tokens", totals["input_tokens"])
    effective["total_input_tokens"] = totals.get("total_input_tokens", 0)
    effective["cache_efficiency_ratio"] = totals.get("cache_efficiency_ratio", totals.get("cache_hit_ratio", 0))
    effective["measurement_source"] = totals.get("measurement_source", canonical.get("measurement_source", {}))
    effective["max_turn_total_tokens"] = totals["max_turn_total_tokens"]
    effective["tool_calls_total"] = totals["tool_calls_total"]
    effective["cache_hit_ratio"] = totals.get("cache_hit_ratio", effective["cache_efficiency_ratio"])
    effective["runtimes"] = unique_record_values(invocations, "runtime")
    effective["models"] = unique_record_values(invocations, "model")
    effective["usage_unsupported"] = all_unsupported(invocations)
    return effective


def model_label(record: Dict[str, Any]) -> str:
    return as_text(record.get("model")).strip() or "-"


def unique_record_values(records: Sequence[Dict[str, Any]], key: str) -> List[str]:
    seen: Set[str] = set()
    ordered: List[str] = []
    for record in records:
        if not isinstance(record, dict):
            continue
        value = as_text(record.get(key)).strip()
        if not value or value in seen:
            continue
        seen.add(value)
        ordered.append(value)
    return ordered


def unique_summary_breakdown_values(summary: Dict[str, Any], key: str) -> List[str]:
    breakdown = summary.get("model_breakdown")
    if not isinstance(breakdown, list):
        return []
    return unique_record_values([item for item in breakdown if isinstance(item, dict)], key)


def plan_values(summary: Dict[str, Any], invocations: Sequence[Dict[str, Any]], key: str) -> List[str]:
    values = unique_record_values(invocations, key) or unique_summary_breakdown_values(summary, key)
    if values:
        return values
    fallback = as_text(summary.get(key)).strip()
    return [fallback] if fallback else []


def total_values_label(values: Sequence[str], total_label: str) -> str:
    if not values:
        return "-"
    if len(values) == 1:
        return values[0]
    return total_label


def plan_runtime_label(summary: Dict[str, Any], invocations: Sequence[Dict[str, Any]]) -> str:
    values = plan_values(summary, invocations, "runtime")
    return ",".join(values) if values else "-"


def plan_model_label(summary: Dict[str, Any], invocations: Sequence[Dict[str, Any]]) -> str:
    values = plan_values(summary, invocations, "model")
    return ",".join(values) if values else "-"


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


def all_unsupported(records: Sequence[Dict[str, Any]]) -> bool:
    """True iff every record in the set has usage_unsupported truthy (and the set is non-empty)."""
    recs = [r for r in records if isinstance(r, dict)]
    if not recs:
        return False
    return all(bool(r.get("usage_unsupported")) for r in recs)


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
        agg["invocation_count"] = len(recs)
        agg["usage_unsupported"] = all_unsupported(recs)
        out.append((key, agg, recs))
    return out


def aggregate_by_runtime_model(invocations: Sequence[Dict[str, Any]]) -> List[Tuple[str, str, Dict[str, Any]]]:
    """Group invocations by runtime/model pair; preserve first-seen pair order."""
    buckets: Dict[Tuple[str, str], List[Dict[str, Any]]] = {}
    order: List[Tuple[str, str]] = []
    for record in invocations:
        if not isinstance(record, dict):
            continue
        runtime = as_text(record.get("runtime")).strip() or "-"
        model = as_text(record.get("model")).strip() or "-"
        key = (runtime, model)
        if key not in buckets:
            order.append(key)
            buckets[key] = []
        buckets[key].append(record)
    out: List[Tuple[str, str, Dict[str, Any]]] = []
    for runtime, model in order:
        recs = buckets[(runtime, model)]
        agg = aggregate(recs)
        agg["invocation_count"] = len(recs)
        agg["usage_unsupported"] = all_unsupported(recs)
        has_todo_completion = any("todo_completed" in record for record in recs)
        if has_todo_completion:
            agg["todos_done"] = sum(1 for record in recs if record.get("todo_completed") is True)
            agg["todos_estimated"] = False
        else:
            agg["todos_done"] = len(recs)
            agg["todos_estimated"] = True
        out.append((runtime, model, agg))
    return out


def emit_model_totals_line(model_name: str, agg: Dict[str, Any], recs: Sequence[Dict[str, Any]]) -> None:
    rt = runtimes_for_model(list(recs))
    per_turn, per_call = derive_cache_read_ratios(
        agg.get("cache_read_input_tokens"),
        agg.get("tool_turns"),
        agg.get("tool_calls_total"),
    )
    parts = [
        f"model={model_name}",
        f"runtime={rt}",
        f"invocations={agg.get('invocation_count', len(recs))}",
        f"input={fmt_value(agg.get('input_tokens'))}",
        f"output={fmt_value(agg.get('output_tokens'))}",
        f"cache_create={fmt_value(agg.get('cache_creation_input_tokens'))}",
        f"cache_read={fmt_value(agg.get('cache_read_input_tokens'))}",
        f"cache_read_per_turn={fmt_value(per_turn)}",
        f"cache_read_per_call={fmt_value(per_call)}",
        f"max_turn={fmt_value(agg.get('max_turn_total_tokens'))}",
        f"tool_calls={fmt_value(agg.get('tool_calls_total'))}",
        f"cache_hit_ratio={fmt_value(agg.get('cache_hit_ratio'))}",
    ]
    emit("  " + " ".join(parts))


def summarize_plan(summary: Dict[str, Any], invocations: Sequence[Dict[str, Any]], summary_path: str, invocations_path: str) -> None:
    emit(c("bold_cyan", "Plan usage summary"))
    emit(f"  {c('dim', 'Plan:')}        {as_text(summary.get('plan')).strip() or '-'}")
    emit(
        f"  {c('dim', 'Key:')}         "
        f"plan_key={as_text(summary.get('plan_key')).strip() or '-'} "
        f"stage_id={as_text(summary.get('stage_id')).strip() or '-'}"
    )
    emit(
        f"  {c('dim', 'Runtime:')}     "
        f"runtime={plan_runtime_label(summary, invocations)} "
        f"model={plan_model_label(summary, invocations)}"
    )
    emit(
        f"  {c('dim', 'Progress:')}    "
        f"invocations={summary_value(summary, 'invocations', invocations, len(invocations))} "
        f"todos={summary_value(summary, 'todos_done', invocations, 0)}/{summary_value(summary, 'todos_total', invocations, 0)}"
    )
    timing = summary_timing(summary)
    if timing:
        emit(f"  {c('dim', 'Window:')}      {timing}")
    totals = aggregate(invocations)
    plan_unsupported = all_unsupported(invocations)
    emit()
    emit(c("bold", "Totals"))
    emit(
        f"  input={'n/a' if plan_unsupported else fmt_tokens(summary_value(summary, 'input_tokens', invocations, totals['input_tokens']))} "
        f"output={'n/a' if plan_unsupported else fmt_tokens(summary_value(summary, 'output_tokens', invocations, totals['output_tokens']))} "
        f"cache_create={'n/a' if plan_unsupported else fmt_tokens(summary_value(summary, 'cache_creation_input_tokens', invocations, totals['cache_creation_input_tokens']))} "
        f"cache_read={'n/a' if plan_unsupported else fmt_tokens(summary_value(summary, 'cache_read_input_tokens', invocations, totals['cache_read_input_tokens']))}"
    )
    cache_hit_ratio = summary_value(summary, 'cache_hit_ratio', invocations, 0)
    write_share = cache_write_cost_share(
        summary_value(summary, 'cache_read_input_tokens', invocations, totals['cache_read_input_tokens']),
        summary_value(summary, 'cache_creation_input_tokens', invocations, totals['cache_creation_input_tokens']),
        sum(as_int(r.get('cache_creation_5m_input_tokens')) for r in invocations),
        sum(as_int(r.get('cache_creation_1h_input_tokens')) for r in invocations),
    )
    emit(
        f"  max_turn={'n/a' if plan_unsupported else fmt_tokens(summary_value(summary, 'max_turn_total_tokens', invocations, totals['max_turn_total_tokens']))} "
        f"tool_calls={fmt_tokens(summary_value(summary, 'tool_calls_total', invocations, totals['tool_calls_total']))} "
        + (
            "n/a"
            if plan_unsupported
            else f"{color_cache_hit_token(cache_hit_ratio)} {color_write_cost_token(write_share)}"
        )
    )
    per_turn = summary_value(summary, "cache_read_per_tool_turn", invocations, None)
    per_call = summary_value(summary, "cache_read_per_tool_call", invocations, None)
    if per_turn is None or per_call is None:
        fallback_turn, fallback_call = derive_cache_read_ratios(
            totals["cache_read_input_tokens"],
            totals.get("tool_turns", 0),
            totals["tool_calls_total"],
        )
        if per_turn is None:
            per_turn = fallback_turn
        if per_call is None:
            per_call = fallback_call
    emit(
        f"  cache_read_per_turn={fmt_value(per_turn)} cache_read_per_call={fmt_value(per_call)}"
    )

    emit()
    emit(c("bold", "Byte savings by optimization path"))
    total_pre_bytes = 0
    total_saved_bytes = 0
    total_pre_tokens = 0
    total_saved_tokens = 0
    has_any_savings = False
    savings_by_path = latest_byte_savings_by_path(summary, invocations)
    for path_name in SAVINGS_PATH_NAMES:
        path_data = savings_by_path.get(path_name, {})
        if not path_data or path_data.get("count", 0) == 0:
            continue
        has_any_savings = True
        pre_bytes = as_int(path_data.get("pre_optimization_bytes"))
        post_bytes = as_int(path_data.get("post_optimization_bytes"))
        saved = as_int(path_data.get("saved_bytes"))
        hidden = as_int(path_data.get("hidden_from_context"))
        pre_tokens = as_int(path_data.get("pre_optimization_tokens"))
        post_tokens = as_int(path_data.get("post_optimization_tokens"))
        saved_tokens = as_int(path_data.get("saved_tokens"))
        hidden_tokens = as_int(path_data.get("hidden_from_context_tokens"))
        token_cap_triggers = as_int(path_data.get("token_cap_triggers"))
        count = as_int(path_data.get("count"))
        savings_pct = path_data.get("savings_percent", 0.0)
        savings_pct_tokens = path_data.get("savings_percent_tokens", 0.0)
        total_pre_bytes += pre_bytes
        total_saved_bytes += saved
        total_pre_tokens += pre_tokens
        total_saved_tokens += saved_tokens
        path_label = path_name.replace("_", " ").title()
        line = (
            f"  {path_label}: "
            f"pre={fmt_value(pre_bytes)}B post={fmt_value(post_bytes)}B "
            f"saved={fmt_value(saved)}B ({savings_pct}%) count={count}"
        )
        if pre_tokens > 0 or saved_tokens > 0:
            line += (
                f" tokens_pre={fmt_value(pre_tokens)} tokens_saved={fmt_value(saved_tokens)}"
                f" ({savings_pct_tokens}%)"
            )
        if token_cap_triggers > 0:
            line += f" token_cap_triggers={token_cap_triggers}"
        emit(line)
        if path_name == "result_windowing":
            emit("    (net of raw-view escalations: bytes the agent re-read via "
                 "ralph_proxy_result_read/search are subtracted)")
        if hidden > 0:
            emit(f"    (hidden_from_context={fmt_value(hidden)}B)")
        if hidden_tokens > 0:
            emit(f"    (hidden_from_context_tokens={fmt_value(hidden_tokens)})")
    if has_any_savings and total_pre_bytes > 0:
        total_savings_pct = round((total_saved_bytes / total_pre_bytes) * 100, 1)
        total_line = f"  Total: saved={fmt_value(total_saved_bytes)}B ({total_savings_pct}%)"
        if total_pre_tokens > 0:
            total_token_pct = round((total_saved_tokens / total_pre_tokens) * 100, 1)
            total_line += (
                f" tokens_saved={fmt_value(total_saved_tokens)} ({total_token_pct}%)"
            )
        emit(total_line)
    elif not has_any_savings:
        emit("  (none)")
    emit()
    emit(c("bold", "Tools (transcript-level counters)"))
    emit(
        f"  native_total={fmt_value(totals['native_read_like_calls'] + totals['native_write_like_calls'])} "
        f"native_read_like={fmt_value(totals['native_read_like_calls'])} "
        f"native_write_like={fmt_value(totals['native_write_like_calls'])}"
    )
    emit(
        f"  ralph_total={fmt_value(totals['ralph_proxy_calls'])} "
        f"ralph_proxy={fmt_value(totals['ralph_proxy_calls'])} "
        f"other_mcp={fmt_value(totals['other_mcp_calls'])} "
        f"unknown={fmt_value(totals['unknown_tool_calls'])}"
    )
    emit(
        f"  runtime_hook_rewrite={fmt_value(totals['runtime_hook_rewrite_calls'])} "
        f"runtime_hook_compaction={fmt_value(totals['runtime_hook_compaction_calls'])}"
    )
    emit()
    emit(c("bold", "Overlay (capability flags and observed activity)"))
    emit(
        f"  native_hooks_effective={fmt_value(summary.get('native_hooks_effective', False))} "
        f"native_hooks_used_on_run={fmt_value(summary.get('native_hooks_used_on_run', False))}"
    )
    native_hooks_observed_reason = str(summary.get("native_hooks_observed_reason") or "").strip()
    measured_not_applied = as_int(summary.get("compaction_measured_not_applied_bytes"))
    if measured_not_applied > 0:
        reason_text = native_hooks_observed_reason or "runtime mode prevented applying measured native compaction savings"
        emit(
            f"  measured-not-applied={fmt_value(measured_not_applied)}B "
            f"reason={reason_text}"
        )
    emit()
    emit(c("bold", "Advisory (mixed usage semantics)"))
    native_exploration = totals.get("native_read_like_calls", 0) + totals.get("native_search_calls", 0) + totals.get("native_shell_calls", 0)
    native_write = totals.get("native_write_like_calls", 0)
    proxy = totals.get("ralph_proxy_calls", 0)
    hook_compacted = as_int(summary.get("hook_compactions", 0)) > 0 and as_int(summary.get("hook_original_bytes", 0)) > 0
    proxy_shell_compacted = as_int(summary.get("proxy_shell_compactions", 0)) > 0 and as_int(summary.get("proxy_shell_original_bytes", 0)) > 0
    compaction_proven = hook_compacted or proxy_shell_compacted
    if proxy == 0 and native_exploration == 0 and native_write > 0:
        emit(c("green", "  Edit-adjacent native read/write flow (acceptable): native reads used only for edits"))
    elif native_exploration > 0 and compaction_proven:
        emit(c("green", "  Native exploration with compaction (acceptable): native tools used but output was proven compacted"))
        if hook_compacted:
            emit(f"    - native hook compaction: {summary.get('hook_compactions')} events, {fmt_value(summary.get('hook_original_bytes'))}B reduced")
        if proxy_shell_compacted:
            emit(f"    - proxy shell compaction: {summary.get('proxy_shell_compactions')} events, {fmt_value(summary.get('proxy_shell_original_bytes'))}B reduced")
    elif proxy > 0 and native_exploration > 0 and not compaction_proven:
        emit(c("yellow", "  Mixed tool usage without compaction: prefer ralph_proxy_* exclusively for exploration"))
    elif proxy == 0 and native_exploration > 0 and not compaction_proven:
        emit(c("yellow", "  Native exploration without compaction: consider ralph_proxy_* for better token usage"))
    elif proxy > 0:
        emit(c("green", "  Proxy adoption active: agent primarily used ralph_proxy_* tools"))
    else:
        emit(c("dim", "  No mixed usage patterns detected"))
    grouped = aggregate_by_model(invocations)
    emit()
    emit(c("bold", f"By model ({len(grouped)}):"))
    for model_name, agg, recs in grouped:
        emit_model_totals_line(model_name, agg, recs)
    emit()
    emit(c("dim", f"Summary path: {os.path.abspath(summary_path)}"))
    emit(c("dim", f"Invocation path: {os.path.abspath(invocations_path)}"))


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


def _has_usage_summary_children(path: str) -> bool:
    try:
        for entry in os.listdir(path):
            entry_path = os.path.join(path, entry)
            if not os.path.isdir(entry_path):
                continue
            if os.path.isfile(os.path.join(entry_path, "plan-usage-summary.json")):
                return True
            if os.path.isfile(os.path.join(entry_path, "orchestration-usage-summary.json")):
                return True
    except (OSError, IOError):
        return False
    return False


def discover_logs_roots(search_root: str) -> List[str]:
    roots: List[str] = []
    seen: Set[str] = set()
    if not os.path.isdir(search_root):
        return roots

    noisy_dirs = {".git", "node_modules"}

    def add_root(path: str) -> None:
        if not _has_usage_summary_children(path):
            return
        resolved = os.path.realpath(path)
        if resolved in seen:
            return
        seen.add(resolved)
        roots.append(path)

    try:
        for current, dirs, _files in os.walk(search_root, topdown=True, followlinks=False):
            dirs[:] = [d for d in sorted(dirs) if d not in noisy_dirs]
            add_root(current)
    except (OSError, IOError):
        pass

    roots.sort(key=os.path.realpath)
    return roots


def source_label_for_summary_path(summary_path: str) -> str:
    """Infer a compact workspace/project label from a summary file path."""
    plan_dir = os.path.dirname(summary_path)
    logs_root = os.path.dirname(plan_dir)
    workspace_root = os.path.dirname(os.path.dirname(logs_root))

    # Standard layout: <workspace>/.ralph-workspace/logs/<plan>/plan-usage-summary.json
    if os.path.basename(logs_root) == "logs" and os.path.basename(os.path.dirname(logs_root)) == ".ralph-workspace":
        label = os.path.basename(workspace_root.rstrip(os.sep))
        return label or workspace_root

    # Fallback for explicit custom logs dirs or nonstandard test fixtures.
    label = os.path.basename(logs_root.rstrip(os.sep))
    return label or logs_root


def aggregate_all(plans: List[Tuple[str, str]], orchestrations: List[Tuple[str, str]]) -> Dict[str, Any]:
    all_invocations: List[Dict[str, Any]] = []
    plan_summaries: Dict[str, Dict[str, Any]] = {}
    plan_effective_summaries: Dict[str, Dict[str, Any]] = {}
    orch_summaries: Dict[str, Dict[str, Any]] = {}
    runtime_buckets: Dict[str, Dict[str, Any]] = {}
    invocations_by_summary_path: Dict[str, List[Dict[str, Any]]] = {}

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
        invocations = parse_invocations_doc(invocation_doc)
        invocations_by_summary_path[summary_path] = invocations

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
                    "tool_calls_total": 0,
                    "usage_unsupported": True,
                }
            bucket = runtime_buckets[rt]
            bucket["input_tokens"] += as_int(record.get("input_tokens"))
            bucket["output_tokens"] += as_int(record.get("output_tokens"))
            bucket["cache_creation_input_tokens"] += as_int(record.get("cache_creation_input_tokens"))
            bucket["cache_read_input_tokens"] += as_int(record.get("cache_read_input_tokens"))
            bucket["tool_calls_total"] += as_int(record.get("tool_calls_total"))
            bucket["usage_unsupported"] = bucket["usage_unsupported"] and bool(record.get("usage_unsupported"))
            bucket["elapsed_seconds"] += float(record.get("elapsed_seconds", 0)) if record.get("elapsed_seconds") else 0.0
            max_turn = as_int(record.get("max_turn_total_tokens"))
            if max_turn > bucket["max_turn_total_tokens"]:
                bucket["max_turn_total_tokens"] = max_turn
            bucket["invocation_count"] += 1

    for summary_path, _ in loaded_plans:
        summary = plan_summaries.get(summary_path) or {}
        plan_effective_summaries[summary_path] = plan_summary_with_invocation_fallback(
            summary, invocations_by_summary_path.get(summary_path, [])
        )

    overall_totals = aggregate(all_invocations)
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
        canonical = aggregate_records(
            [
                {
                    "input_tokens": bucket["input_tokens"],
                    "cache_creation_input_tokens": bucket["cache_creation_input_tokens"],
                    "cache_read_input_tokens": bucket["cache_read_input_tokens"],
                }
            ]
        )
        bucket["cache_hit_ratio"] = canonical["cache_hit_ratio"]
        bucket["cache_efficiency_ratio"] = canonical["cache_efficiency_ratio"]

    by_model = aggregate_by_model(all_invocations)

    return {
        "overall": overall_totals,
        "by_runtime": runtime_buckets,
        "by_model": by_model,
        "plan_summaries": plan_summaries,
        "plan_effective_summaries": plan_effective_summaries,
        "orch_summaries": orch_summaries,
        "loaded_plans": loaded_plans,
        "loaded_orchestrations": loaded_orchestrations,
        "invocations_by_summary_path": invocations_by_summary_path,
    }


def _summary_paths_from_entries(entries: Sequence[Tuple[str, str]]) -> List[str]:
    return [path for path, _ in entries if path]


def _build_savings_report_from_paths(paths: Sequence[str]) -> Dict[str, Any] | None:
    if not paths or _SAVINGS_REPORT_MODULE is None:
        return None
    valid = [path for path in paths if isinstance(load_json_quiet(path), dict)]
    if not valid:
        return None
    try:
        return _SAVINGS_REPORT_MODULE.build_report(valid)
    except (OSError, ValueError, json.JSONDecodeError):
        return None


def _collect_savings_report(
    plans: Sequence[Tuple[str, str]], orchestrations: Sequence[Tuple[str, str]]
) -> Dict[str, Any] | None:
    paths = _summary_paths_from_entries(plans) + _summary_paths_from_entries(orchestrations)
    return _build_savings_report_from_paths(paths)


def _render_savings_block(report: Dict[str, Any]) -> None:
    saved_tokens = as_int(report.get("saved_tokens", 0))
    saved_bytes = as_int(report.get("saved_bytes", 0))
    emit(c("bold", "Savings"))
    emit(
        f"  kept ~{fmt_tokens(saved_tokens)} tokens (~{fmt_int(saved_bytes)} bytes) "
        "out of model context"
    )
    per_path = report.get("per_path") or {}
    rendered = False
    for path_name in SAVINGS_PATH_NAMES:
        bucket = per_path.get(path_name) or {}
        path_saved_tokens = as_int(bucket.get("saved_tokens", 0))
        path_saved_bytes = as_int(bucket.get("saved_bytes", 0))
        if path_saved_tokens <= 0 and path_saved_bytes <= 0:
            continue
        label = path_name.replace("_", " ").title()
        line = (
            f"  {label}: saved ~{fmt_tokens(path_saved_tokens)} tokens "
            f"(~{fmt_int(path_saved_bytes)} bytes)"
        )
        savings_pct = bucket.get("savings_percent")
        if savings_pct not in (None, "", 0):
            line += f" ({savings_pct}%)"
        count = as_int(bucket.get("count", 0))
        if count:
            line += f" over {count} events"
        emit(line)
        rendered = True
    if not rendered:
        emit("  (no path-level savings recorded)")
    cache_hit_ratio = (report.get("cache") or {}).get("cache_hit_ratio", 0)
    emit(f"  context efficiency: {color_cache_hit(cache_hit_ratio)} cache hit ratio")


def summarize_all(
    aggregated: Dict[str, Any],
    plans: List[Tuple[str, str]],
    orchestrations: List[Tuple[str, str]],
    workspace: str = "",
    logs_dir: str = "",
    savings_report: Dict[str, Any] | None = None,
) -> None:
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
        f"tool_calls={fmt_int(overall.get('tool_calls_total'))} "
        f"cache_hit={color_cache_hit(overall.get('cache_hit_ratio'))}"
    )
    emit()

    by_runtime = aggregated["by_runtime"]
    emit(c("bold", f"By runtime ({len(by_runtime)}):"))
    if by_runtime:
        headers = [
            "runtime",
            "invocations",
            "elapsed",
            "input",
            "output",
            "cache_create",
            "cache_read",
            "tool_calls",
            "cache_hit",
        ]
        aligns = ["l", "r", "r", "r", "r", "r", "r", "r", "r", "r"]
        rows = []
        for runtime in sorted(by_runtime.keys()):
            agg = by_runtime[runtime]
            unsupported = bool(agg.get("usage_unsupported"))
            rows.append([
                runtime,
                str(agg.get("invocation_count", 0)),
                format_elapsed(agg.get("elapsed_seconds")),
                "n/a" if unsupported else fmt_int(agg.get("input_tokens")),
                "n/a" if unsupported else fmt_int(agg.get("output_tokens")),
                "n/a" if unsupported else fmt_int(agg.get("cache_creation_input_tokens")),
                "n/a" if unsupported else fmt_int(agg.get("cache_read_input_tokens")),
                fmt_int(agg.get("tool_calls_total")),
                "n/a" if unsupported else color_cache_hit(agg.get("cache_hit_ratio")),
            ])
        for line in render_table(headers, rows, aligns):
            emit(line)
    else:
        emit("  (none)")
    emit()

    if savings_report:
        _render_savings_block(savings_report)
        emit()

    by_model = aggregated["by_model"]
    emit(c("bold", f"By model ({len(by_model)}):"))
    if by_model:
        headers = [
            "model",
            "runtime",
            "invocations",
            "elapsed",
            "input",
            "output",
            "cache_read",
            "tool_calls",
            "cache_hit",
        ]
        aligns = ["l", "l", "r", "r", "r", "r", "r", "r", "r", "r"]
        rows = []
        sorted_models = sorted(
            by_model,
            key=lambda m: as_int(m[1].get("elapsed_seconds")),
            reverse=True,
        )
        for model_name, agg, recs in sorted_models:
            runtimes = runtimes_for_model(list(recs))
            unsupported = bool(agg.get("usage_unsupported"))
            rows.append([
                model_name,
                runtimes,
                str(agg.get("invocation_count", len(recs))),
                format_elapsed(agg.get("elapsed_seconds")),
                "n/a" if unsupported else fmt_int(agg.get("input_tokens")),
                "n/a" if unsupported else fmt_int(agg.get("output_tokens")),
                "n/a" if unsupported else fmt_int(agg.get("cache_read_input_tokens")),
                fmt_int(agg.get("tool_calls_total")),
                "n/a" if unsupported else color_cache_hit(agg.get("cache_hit_ratio")),
            ])
        for line in render_table(headers, rows, aligns):
            emit(line)
    else:
        emit("  (none)")
    emit()

    plan_summaries = aggregated.get("plan_effective_summaries") or aggregated.get("plan_summaries") or {}
    loaded_plans = aggregated.get("loaded_plans") or [
        (s, i) for (s, i) in plans if s in plan_summaries
    ]
    emit(c("bold", f"Plans ({len(loaded_plans)}):"))
    if loaded_plans:
        invocations_by_summary_path = aggregated.get("invocations_by_summary_path") or {}
        show_plan_tool_calls = os.environ.get("RALPH_USAGE_REPORT_SHOW_TOOLS") == "1"
        if len(loaded_plans) > 1:
            show_plan_tool_calls = True

        def _plan_sort_key(entry: Tuple[str, str]) -> str:
            s = plan_summaries.get(entry[0], {})
            return as_text(s.get("started_at")).strip() or entry[0]

        headers = ["project", "plan", "runtime", "model", "invocations", "todos", "elapsed", "input", "output"]
        aligns = ["l", "l", "l", "l", "r", "r", "r", "r", "r"]
        if show_plan_tool_calls:
            headers.append("tools")
            aligns.append("r")
        headers.extend(["cache_hit", "status"])
        aligns.extend(["r", "l"])
        rows: List[List[str]] = []

        by_project: Dict[str, List[Tuple[str, str]]] = {}
        for entry in loaded_plans:
            project = source_label_for_summary_path(entry[0])
            by_project.setdefault(project, []).append(entry)

        sorted_projects = sorted(by_project.keys())
        for pidx, project in enumerate(sorted_projects):
            project_entries = sorted(by_project[project], key=_plan_sort_key, reverse=True)
            first_in_project = True
            n_in_project = len(project_entries)
            for idx, (summary_path, invocations_path) in enumerate(project_entries):
                summary = plan_summaries.get(summary_path) or {}
                plan_key = as_text(summary.get("plan_key")).strip() or "-"
                plan_cell = truncate_plan_display(plan_key)
                plan_invocations = invocations_by_summary_path.get(summary_path, [])
                effective_summary = plan_summary_with_invocation_fallback(summary, plan_invocations)
                runtime_values = plan_values(summary, plan_invocations, "runtime")
                model_values = plan_values(summary, plan_invocations, "model")
                runtime = total_values_label(runtime_values, "total")
                model = total_values_label(model_values, "all")
                invocations = as_int(effective_summary.get("invocations"), 0)
                todos_done = as_int(summary.get("todos_done"), 0)
                todos_total = as_int(summary.get("todos_total"), 0)
                elapsed = format_elapsed(effective_summary.get("elapsed_seconds", 0))
                plan_unsupported = bool(effective_summary.get("usage_unsupported"))
                input_tokens = "n/a" if plan_unsupported else fmt_int(effective_summary.get("input_tokens", 0))
                output_tokens = "n/a" if plan_unsupported else fmt_int(effective_summary.get("output_tokens", 0))
                cache_hit_val = effective_summary.get("cache_hit_ratio", 0)
                status = c("yellow", "incomplete") if todos_done < todos_total else c("dim", "ok")
                proj_cell = project if first_in_project else ""
                rows.append([
                    proj_cell,
                    plan_cell,
                    runtime,
                    model,
                    str(invocations),
                    f"{todos_done}/{todos_total}",
                    elapsed,
                    input_tokens,
                    output_tokens,
                ])
                if show_plan_tool_calls:
                    rows[-1].append(fmt_int(effective_summary.get("tool_calls_total", 0)))
                rows[-1].extend([
                    "n/a" if plan_unsupported else color_cache_hit(cache_hit_val),
                    status,
                ])
                pair_breakdown = aggregate_by_runtime_model(plan_invocations)
                if len(pair_breakdown) > 1:
                    for runtime_name, model_name, pair in pair_breakdown:
                        pair_todos = as_int(pair.get("todos_done"), 0)
                        pair_todos_label = f"~{pair_todos}" if pair.get("todos_estimated") else str(pair_todos)
                        pair_unsupported = bool(pair.get("usage_unsupported"))
                        pair_row = [
                            "",
                            "",
                            runtime_name,
                            model_name,
                            str(pair.get("invocation_count", 0)),
                            pair_todos_label,
                            format_elapsed(pair.get("elapsed_seconds", 0)),
                            "n/a" if pair_unsupported else fmt_int(pair.get("input_tokens", 0)),
                            "n/a" if pair_unsupported else fmt_int(pair.get("output_tokens", 0)),
                        ]
                        if show_plan_tool_calls:
                            pair_row.append(fmt_int(pair.get("tool_calls_total", 0)))
                        pair_row.extend([
                            "n/a" if pair_unsupported else color_cache_hit(pair.get("cache_hit_ratio", 0)),
                            "",
                        ])
                        rows.append(pair_row)
                first_in_project = False
                last_in_project = idx == n_in_project - 1
                last_project = pidx == len(sorted_projects) - 1
                if last_in_project and last_project:
                    rows.append([ROW_DIVIDER_WITHIN_PROJECT])
                elif last_in_project:
                    rows.append([ROW_DIVIDER])
                else:
                    rows.append([ROW_DIVIDER_WITHIN_PROJECT])
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
        headers = ["project", "artifact_ns", "steps", "elapsed", "input", "output", "cache_read"]
        aligns = ["l", "l", "r", "r", "r", "r", "r"]
        rows = []
        stage_lines: List[Tuple[str, List[List[str]]]] = []
        for summary_path, invocations_path in loaded_orchestrations:
            summary = orch_summaries.get(summary_path) or {}
            project = source_label_for_summary_path(summary_path)
            ns = as_text(summary.get("artifact_ns")).strip() or as_text(summary.get("plan_key")).strip() or "-"
            steps = as_int(summary.get("steps"), 0)
            elapsed = format_elapsed(summary.get("elapsed_seconds", 0))
            input_tokens = fmt_int(summary.get("input_tokens", 0))
            output_tokens = fmt_int(summary.get("output_tokens", 0))
            cache_read = fmt_int(summary.get("cache_read_input_tokens", 0))
            rows.append([project, ns, str(steps), elapsed, input_tokens, output_tokens, cache_read])

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
    all_mode.add_argument("--logs-dir", required=True, action="append", help="Directory containing plan and orchestration logs (may be specified multiple times)")
    all_mode.add_argument("--format", choices=["text", "json"], default="text", help="Output format (default: text)")
    all_mode.add_argument("--workspace", default=None, help="Workspace path (informational, included in output header)")

    return parser.parse_args(argv)


def main(argv: Sequence[str]) -> int:
    args = parse_args(argv)

    if args.mode == "all":
        plans: List[Tuple[str, str]] = []
        orchestrations: List[Tuple[str, str]] = []
        seen_roots: Set[str] = set()
        for logs_dir in args.logs_dir:
            resolved = os.path.realpath(logs_dir)
            if resolved in seen_roots:
                continue
            seen_roots.add(resolved)
            for logs_root in discover_logs_roots(logs_dir):
                root_plans, root_orchestrations = discover_summaries(logs_root)
                plans.extend(root_plans)
                orchestrations.extend(root_orchestrations)
        aggregated = aggregate_all(plans, orchestrations)
        savings_report = _collect_savings_report(plans, orchestrations)

        if args.format == "json":
            plan_summaries = aggregated.get("plan_effective_summaries") or aggregated.get("plan_summaries") or {}
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
                        "tool_calls_total": agg.get("tool_calls_total"),
                        "cache_hit_ratio": agg.get("cache_hit_ratio"),
                    }
                    for model, agg, recs in aggregated["by_model"]
                ],
                "plans": plans_data,
                "orchestrations": orchestrations_data,
                "savings": savings_report or {},
            }
            emit(json.dumps(output, sort_keys=True))
        else:
            summarize_all(
                aggregated,
                plans,
                orchestrations,
                args.workspace,
                ", ".join(args.logs_dir),
                savings_report=savings_report,
            )
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
