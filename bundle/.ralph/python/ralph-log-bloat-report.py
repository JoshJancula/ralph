#!/usr/bin/env python3
"""Estimate visible prompt/tool bloat from Ralph plan logs.

This report combines a plan's output log with invocation-usage.json to show:
- visible prompt section sizes parsed from the transcript
- tool access mode and observed tool families
- per-invocation token usage
- a residual "hidden overhead" estimate for unattributed input tokens

The hidden overhead estimate is intentionally approximate. It is useful for
comparing runs (for example, native vs ralph) rather than asserting an exact
provider-side prompt payload.
"""

from __future__ import annotations

import argparse
import glob
import json
import math
import os
import re
import sys
from collections import Counter, defaultdict
from typing import Any, Dict, Iterable, List, Mapping, Optional, Sequence, Tuple


INVOCATION_START_RE = re.compile(
    r"^\[(?P<ts>[^\]]+)\] Invocation (?P<iteration>\d+) \| TODO \(line (?P<line>\d+)\): (?P<todo>.*)$"
)
AGENT_TOOL_ACCESS_RE = re.compile(r"^# Agent Tool Access: (?P<mode>\S+)")
SYSTEM_INIT_PREFIX = '{"type":"system","subtype":"init"'
JSON_LINE_RE = re.compile(r'^\{".*')

PROMPT_CONTINUATION_PREFIXES = (
    "Complete exactly this TODO",
    "**TODO (line ",
    "**Plan file:**",
    "Rules:",
    "- ",
    "Artifact namespace:",
    "Use namespace-aware artifact paths",
    "## Agent Tool Access",
    "Ralph MCP ",
    "Native `",
    "Prefer ",
    "If ",
    "For ",
    "Do not ",
    "Open `",
    "Reset contract:",
    "Compact contract:",
    "Start with ",
    "When a proxy response",
    "Direct names",
    "MCP-qualified names",
    "Ralph MCP proxy tools available",
    "Using mixed tools",
    "Strict proxy is active",
    "The downstream stages below rely on you",
    "- Stage ID:",
    "## Stage Plan Generation Responsibility",
    "## Human operator answers",
    "[Note: trimmed",
    "**Post-verification failure:**",
    "Command:",
    "Full output stored at `",
    "OpenCode runtime note:",
)


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


def read_text(path: str) -> str:
    try:
        with open(path, "r", encoding="utf-8") as fh:
            return fh.read()
    except FileNotFoundError:
        fail(f"Error: file not found: {path}")


def estimate_tokens_from_bytes(byte_count: int) -> int:
    if byte_count <= 0:
        return 0
    return int(math.ceil(byte_count / 4.0))


def compact_text_bytes(lines: Sequence[str]) -> int:
    if not lines:
        return 0
    return len(("\n".join(lines)).encode("utf-8"))


def classify_tool_event(tool_call: Mapping[str, Any]) -> Tuple[str, str]:
    if "mcpToolCall" in tool_call:
        mcp = tool_call.get("mcpToolCall") or {}
        args = mcp.get("args") or {}
        tool_name = str(args.get("toolName") or args.get("name") or "mcp")
        return ("mcp", tool_name)
    if "readToolCall" in tool_call:
        return ("native", "readToolCall")
    if "editToolCall" in tool_call:
        return ("native", "editToolCall")
    if "writeToolCall" in tool_call:
        return ("native", "writeToolCall")
    if "shellToolCall" in tool_call:
        return ("native", "shellToolCall")
    return ("unknown", "unknown")


def find_output_log(logs_dir: str) -> str:
    candidates = sorted(glob.glob(os.path.join(logs_dir, "*-output.log")))
    if not candidates:
        fail(f"Error: no *-output.log found in {logs_dir}")
    if len(candidates) > 1:
        specific = [p for p in candidates if re.search(r"plan-runner-[A-Za-z0-9_.-]+-output\.log$", os.path.basename(p))]
        if len(specific) == 1:
            return specific[0]
    return candidates[0]


def parse_invocation_segments(output_text: str) -> List[Dict[str, Any]]:
    lines = output_text.splitlines()
    starts: List[Tuple[int, Dict[str, Any]]] = []
    current_tool_access = "unknown"
    for idx, line in enumerate(lines):
        tool_match = AGENT_TOOL_ACCESS_RE.match(line)
        if tool_match:
            current_tool_access = tool_match.group("mode")
            continue
        start_match = INVOCATION_START_RE.match(line)
        if start_match:
            starts.append(
                (
                    idx,
                    {
                        "iteration": int(start_match.group("iteration")),
                        "line_num": int(start_match.group("line")),
                        "todo_text": start_match.group("todo").strip(),
                        "tool_access": current_tool_access,
                        "header_timestamp": start_match.group("ts"),
                    },
                )
            )
    segments: List[Dict[str, Any]] = []
    for pos, (start_idx, meta) in enumerate(starts):
        end_idx = starts[pos + 1][0] if pos + 1 < len(starts) else len(lines)
        segment_lines = lines[start_idx:end_idx]
        entry = dict(meta)
        entry["segment_lines"] = segment_lines
        entry["segment_text"] = "\n".join(segment_lines)
        segments.append(entry)
    return segments


def parse_prompt_sections(segment_lines: Sequence[str]) -> Dict[str, Any]:
    prompt_start = None
    for idx, line in enumerate(segment_lines):
        if line.startswith(SYSTEM_INIT_PREFIX):
            prompt_start = idx + 1
            break
    if prompt_start is None or prompt_start >= len(segment_lines):
        return {
            "prompt_lines": [],
            "prompt_sections": {},
            "parsed_prompt_bytes": 0,
            "prompt_start_index": None,
            "prompt_end_index": None,
        }

    prompt_lines: List[str] = []
    prompt_end_index = prompt_start
    for rel_idx, line in enumerate(segment_lines[prompt_start:]):
        stripped = line.strip()
        if line.startswith('{"type":"tool_call"') or line.startswith('{"type":"thinking"') or line.startswith('{"type":"result"'):
            break
        if not stripped:
            prompt_lines.append(line)
            prompt_end_index = prompt_start + rel_idx + 1
            continue
        if any(stripped.startswith(prefix) for prefix in PROMPT_CONTINUATION_PREFIXES):
            prompt_lines.append(line)
            prompt_end_index = prompt_start + rel_idx + 1
            continue
        break

    sections: Dict[str, List[str]] = defaultdict(list)
    current = "base"
    for line in prompt_lines:
        stripped = line.strip()
        if stripped.startswith("## Agent Tool Access"):
            current = "tool_access"
        elif stripped.startswith("Artifact namespace:") or stripped.startswith("Use namespace-aware artifact paths"):
            current = "namespace"
        elif stripped.startswith("## Human operator answers") or stripped.startswith("[Note: trimmed"):
            current = "human_context"
        elif stripped.startswith("## Stage Plan Generation Responsibility") or stripped.startswith("The downstream stages below rely on you") or stripped.startswith("- Stage ID:"):
            current = "downstream_context"
        elif stripped.startswith("**Post-verification failure:**") or stripped.startswith("Full output stored at `") or stripped.startswith("Command:"):
            current = "post_verification"
        elif stripped.startswith("OpenCode runtime note:"):
            current = "runtime_guidance"
        elif stripped.startswith("Complete exactly this TODO") or stripped.startswith("Reset contract:") or stripped.startswith("Compact contract:"):
            current = "base"
        sections[current].append(line)

    prompt_sections = {
        key: {
            "lines": value,
            "bytes": compact_text_bytes(value),
        }
        for key, value in sections.items()
        if value
    }
    parsed_prompt_bytes = sum(section["bytes"] for section in prompt_sections.values())
    return {
        "prompt_lines": prompt_lines,
        "prompt_sections": prompt_sections,
        "parsed_prompt_bytes": parsed_prompt_bytes,
        "prompt_start_index": prompt_start,
        "prompt_end_index": prompt_end_index,
    }


def parse_tool_events(segment_lines: Sequence[str]) -> Dict[str, Any]:
    family_counts: Counter[str] = Counter()
    tool_counts: Counter[str] = Counter()
    for line in segment_lines:
        if not JSON_LINE_RE.match(line):
            continue
        try:
            obj = json.loads(line)
        except json.JSONDecodeError:
            continue
        if obj.get("type") != "tool_call":
            continue
        tool_call = obj.get("tool_call") or {}
        family, tool_name = classify_tool_event(tool_call)
        family_counts[family] += 1
        tool_counts[tool_name] += 1
    return {
        "tool_family_counts": dict(sorted(family_counts.items())),
        "tool_name_counts": dict(sorted(tool_counts.items())),
        "uses_mcp": family_counts.get("mcp", 0) > 0,
    }


def parse_visible_payloads(
    segment_lines: Sequence[str],
    prompt_end_index: Optional[int],
) -> Dict[str, Any]:
    if prompt_end_index is None:
        return {
            "visible_tool_output_lines": [],
            "visible_tool_output_bytes": 0,
            "visible_assistant_output_lines": [],
            "visible_assistant_output_bytes": 0,
        }

    tool_output_lines: List[str] = []
    assistant_output_lines: List[str] = []
    current_mode = "assistant"

    for line in segment_lines[prompt_end_index:]:
        if line.startswith("invocation ") or line.startswith("--- End invocation") or line.startswith("################################################################################"):
            break
        if JSON_LINE_RE.match(line):
            try:
                obj = json.loads(line)
            except json.JSONDecodeError:
                current_mode = "assistant"
                continue
            obj_type = obj.get("type")
            if obj_type == "tool_call":
                current_mode = "tool_output"
            elif obj_type in ("thinking", "result", "system"):
                current_mode = "assistant"
            else:
                current_mode = "assistant"
            continue
        stripped = line.strip()
        if not stripped:
            continue
        if current_mode == "tool_output":
            tool_output_lines.append(line)
        else:
            assistant_output_lines.append(line)

    return {
        "visible_tool_output_lines": tool_output_lines,
        "visible_tool_output_bytes": compact_text_bytes(tool_output_lines),
        "visible_assistant_output_lines": assistant_output_lines,
        "visible_assistant_output_bytes": compact_text_bytes(assistant_output_lines),
    }


def summarize_invocation(
    logs_dir: str,
    output_log: str,
    segment: Mapping[str, Any],
    usage_record: Optional[Mapping[str, Any]],
    global_index: int,
) -> Dict[str, Any]:
    prompt = parse_prompt_sections(segment["segment_lines"])
    tool_info = parse_tool_events(segment["segment_lines"])
    visible_payloads = parse_visible_payloads(segment["segment_lines"], prompt.get("prompt_end_index"))
    record = usage_record or {}
    prompt_bytes = int(record.get("prompt_bytes") or prompt["parsed_prompt_bytes"] or 0)
    input_tokens = int(record.get("input_tokens") or 0)
    output_tokens = int(record.get("output_tokens") or 0)
    cache_read = int(record.get("cache_read_input_tokens") or 0)
    cache_create = int(record.get("cache_creation_input_tokens") or 0)
    visible_prompt_tokens_est = estimate_tokens_from_bytes(prompt_bytes)
    parsed_prompt_tokens_est = estimate_tokens_from_bytes(prompt["parsed_prompt_bytes"])
    visible_tool_output_tokens_est = estimate_tokens_from_bytes(visible_payloads["visible_tool_output_bytes"])
    visible_assistant_output_tokens_est = estimate_tokens_from_bytes(visible_payloads["visible_assistant_output_bytes"])
    visible_total_tokens_est = (
        visible_prompt_tokens_est
        + visible_tool_output_tokens_est
        + visible_assistant_output_tokens_est
    )
    hidden_overhead_tokens_est = max(input_tokens - visible_total_tokens_est, 0)
    hidden_uncached_tokens_est = max(input_tokens - cache_read - visible_total_tokens_est, 0)
    return {
        "logs_dir": logs_dir,
        "output_log": output_log,
        "global_index": global_index,
        "iteration": segment.get("iteration"),
        "line_num": segment.get("line_num"),
        "todo_text": segment.get("todo_text"),
        "tool_access": segment.get("tool_access") or str(record.get("agent_tool_access") or "unknown"),
        "runtime": str(record.get("runtime") or ""),
        "model": str(record.get("model") or ""),
        "input_tokens": input_tokens,
        "output_tokens": output_tokens,
        "cache_read_input_tokens": cache_read,
        "cache_creation_input_tokens": cache_create,
        "cache_hit_ratio": record.get("cache_hit_ratio"),
        "prompt_bytes_recorded": prompt_bytes,
        "prompt_bytes_parsed": prompt["parsed_prompt_bytes"],
        "prompt_bytes_delta": prompt_bytes - prompt["parsed_prompt_bytes"],
        "visible_prompt_tokens_est": visible_prompt_tokens_est,
        "parsed_prompt_tokens_est": parsed_prompt_tokens_est,
        "visible_tool_output_bytes": visible_payloads["visible_tool_output_bytes"],
        "visible_tool_output_tokens_est": visible_tool_output_tokens_est,
        "visible_assistant_output_bytes": visible_payloads["visible_assistant_output_bytes"],
        "visible_assistant_output_tokens_est": visible_assistant_output_tokens_est,
        "visible_total_tokens_est": visible_total_tokens_est,
        "hidden_overhead_tokens_est": hidden_overhead_tokens_est,
        "hidden_uncached_tokens_est": hidden_uncached_tokens_est,
        "todo_bytes": int(record.get("todo_bytes") or len(str(segment.get("todo_text") or "").encode("utf-8"))),
        "tool_calls_total": int(record.get("tool_calls_total") or 0),
        "tool_turns": int(record.get("tool_turns") or 0),
        "tool_family_counts": tool_info["tool_family_counts"],
        "tool_name_counts": tool_info["tool_name_counts"],
        "uses_mcp": tool_info["uses_mcp"],
        "prompt_sections": {
            name: {
                "bytes": section["bytes"],
                "tokens_est": estimate_tokens_from_bytes(section["bytes"]),
            }
            for name, section in prompt["prompt_sections"].items()
        },
    }


def aggregate_by(rows: Sequence[Mapping[str, Any]], key_name: str) -> List[Dict[str, Any]]:
    buckets: Dict[str, Dict[str, Any]] = {}
    for row in rows:
        key = str(row.get(key_name) or "unknown")
        bucket = buckets.setdefault(
            key,
            {
                key_name: key,
                "invocations": 0,
                "input_tokens": 0,
                "cache_read_input_tokens": 0,
                "prompt_bytes_recorded": 0,
                "visible_tool_output_bytes": 0,
                "visible_assistant_output_bytes": 0,
                "hidden_overhead_tokens_est": 0,
                "hidden_uncached_tokens_est": 0,
                "tool_calls_total": 0,
                "uses_mcp_invocations": 0,
            },
        )
        bucket["invocations"] += 1
        for metric in (
            "input_tokens",
            "cache_read_input_tokens",
            "prompt_bytes_recorded",
            "visible_tool_output_bytes",
            "visible_assistant_output_bytes",
            "hidden_overhead_tokens_est",
            "hidden_uncached_tokens_est",
            "tool_calls_total",
        ):
            bucket[metric] += int(row.get(metric) or 0)
        if row.get("uses_mcp"):
            bucket["uses_mcp_invocations"] += 1

    out: List[Dict[str, Any]] = []
    for key in sorted(buckets):
        bucket = buckets[key]
        invocations = bucket["invocations"] or 1
        bucket["avg_input_tokens"] = round(bucket["input_tokens"] / invocations, 2)
        bucket["avg_cache_read_input_tokens"] = round(bucket["cache_read_input_tokens"] / invocations, 2)
        bucket["avg_prompt_bytes_recorded"] = round(bucket["prompt_bytes_recorded"] / invocations, 2)
        bucket["avg_visible_tool_output_bytes"] = round(bucket["visible_tool_output_bytes"] / invocations, 2)
        bucket["avg_visible_assistant_output_bytes"] = round(bucket["visible_assistant_output_bytes"] / invocations, 2)
        bucket["avg_hidden_overhead_tokens_est"] = round(bucket["hidden_overhead_tokens_est"] / invocations, 2)
        bucket["avg_hidden_uncached_tokens_est"] = round(bucket["hidden_uncached_tokens_est"] / invocations, 2)
        out.append(bucket)
    return out


def aggregate_by_runtime_tool_access(rows: Sequence[Mapping[str, Any]]) -> List[Dict[str, Any]]:
    buckets: Dict[Tuple[str, str], Dict[str, Any]] = {}
    for row in rows:
        runtime = str(row.get("runtime") or "unknown")
        tool_access = str(row.get("tool_access") or "unknown")
        key = (runtime, tool_access)
        bucket = buckets.setdefault(
            key,
            {
                "runtime": runtime,
                "tool_access": tool_access,
                "invocations": 0,
                "input_tokens": 0,
                "cache_read_input_tokens": 0,
                "prompt_bytes_recorded": 0,
                "visible_tool_output_bytes": 0,
                "visible_assistant_output_bytes": 0,
                "hidden_overhead_tokens_est": 0,
                "hidden_uncached_tokens_est": 0,
                "tool_calls_total": 0,
                "uses_mcp_invocations": 0,
            },
        )
        bucket["invocations"] += 1
        for metric in (
            "input_tokens",
            "cache_read_input_tokens",
            "prompt_bytes_recorded",
            "visible_tool_output_bytes",
            "visible_assistant_output_bytes",
            "hidden_overhead_tokens_est",
            "hidden_uncached_tokens_est",
            "tool_calls_total",
        ):
            bucket[metric] += int(row.get(metric) or 0)
        if row.get("uses_mcp"):
            bucket["uses_mcp_invocations"] += 1

    out: List[Dict[str, Any]] = []
    for key in sorted(buckets):
        bucket = buckets[key]
        invocations = bucket["invocations"] or 1
        bucket["avg_input_tokens"] = round(bucket["input_tokens"] / invocations, 2)
        bucket["avg_cache_read_input_tokens"] = round(bucket["cache_read_input_tokens"] / invocations, 2)
        bucket["avg_prompt_bytes_recorded"] = round(bucket["prompt_bytes_recorded"] / invocations, 2)
        bucket["avg_visible_tool_output_bytes"] = round(bucket["visible_tool_output_bytes"] / invocations, 2)
        bucket["avg_visible_assistant_output_bytes"] = round(bucket["visible_assistant_output_bytes"] / invocations, 2)
        bucket["avg_hidden_overhead_tokens_est"] = round(bucket["hidden_overhead_tokens_est"] / invocations, 2)
        bucket["avg_hidden_uncached_tokens_est"] = round(bucket["hidden_uncached_tokens_est"] / invocations, 2)
        bucket["avg_tool_calls_total"] = round(bucket["tool_calls_total"] / invocations, 2)
        out.append(bucket)
    return out


def build_runtime_tool_access_comparisons(rows: Sequence[Mapping[str, Any]]) -> List[Dict[str, Any]]:
    grouped: Dict[str, Dict[str, Dict[str, Any]]] = defaultdict(dict)
    for agg in aggregate_by_runtime_tool_access(rows):
        grouped[agg["runtime"]][agg["tool_access"]] = agg

    comparisons: List[Dict[str, Any]] = []
    for runtime in sorted(grouped):
        modes = grouped[runtime]
        if "native" not in modes or "ralph" not in modes:
            continue
        native = modes["native"]
        ralph = modes["ralph"]
        comparisons.append(
            {
                "runtime": runtime,
                "native_invocations": native["invocations"],
                "ralph_invocations": ralph["invocations"],
                "avg_input_tokens_delta": round(ralph["avg_input_tokens"] - native["avg_input_tokens"], 2),
                "avg_cache_read_input_tokens_delta": round(
                    ralph["avg_cache_read_input_tokens"] - native["avg_cache_read_input_tokens"], 2
                ),
                "avg_prompt_bytes_delta": round(
                    ralph["avg_prompt_bytes_recorded"] - native["avg_prompt_bytes_recorded"], 2
                ),
                "avg_visible_tool_output_bytes_delta": round(
                    ralph["avg_visible_tool_output_bytes"] - native["avg_visible_tool_output_bytes"], 2
                ),
                "avg_visible_assistant_output_bytes_delta": round(
                    ralph["avg_visible_assistant_output_bytes"] - native["avg_visible_assistant_output_bytes"], 2
                ),
                "avg_hidden_overhead_tokens_delta": round(
                    ralph["avg_hidden_overhead_tokens_est"] - native["avg_hidden_overhead_tokens_est"], 2
                ),
                "avg_hidden_uncached_tokens_delta": round(
                    ralph["avg_hidden_uncached_tokens_est"] - native["avg_hidden_uncached_tokens_est"], 2
                ),
                "avg_tool_calls_total_delta": round(
                    ralph["avg_tool_calls_total"] - native["avg_tool_calls_total"], 2
                ),
            }
        )
    return comparisons


def build_plan_runtime_mode_comparisons(rows: Sequence[Mapping[str, Any]]) -> List[Dict[str, Any]]:
    grouped: Dict[Tuple[str, str], Dict[str, List[Mapping[str, Any]]]] = defaultdict(lambda: defaultdict(list))
    for row in rows:
        plan_key = os.path.basename(str(row.get("logs_dir") or ""))
        runtime = str(row.get("runtime") or "unknown")
        tool_access = str(row.get("tool_access") or "unknown")
        grouped[(plan_key, runtime)][tool_access].append(row)

    comparisons: List[Dict[str, Any]] = []
    for (plan_key, runtime), modes in sorted(grouped.items()):
        if "native" not in modes or "ralph" not in modes:
            continue

        def summarize(mode_rows: Sequence[Mapping[str, Any]]) -> Dict[str, float]:
            count = len(mode_rows) or 1
            return {
                "invocations": len(mode_rows),
                "avg_input_tokens": round(sum(int(r.get("input_tokens") or 0) for r in mode_rows) / count, 2),
                "avg_cache_read_input_tokens": round(
                    sum(int(r.get("cache_read_input_tokens") or 0) for r in mode_rows) / count, 2
                ),
                "avg_prompt_bytes_recorded": round(
                    sum(int(r.get("prompt_bytes_recorded") or 0) for r in mode_rows) / count, 2
                ),
                "avg_visible_tool_output_bytes": round(
                    sum(int(r.get("visible_tool_output_bytes") or 0) for r in mode_rows) / count, 2
                ),
                "avg_visible_assistant_output_bytes": round(
                    sum(int(r.get("visible_assistant_output_bytes") or 0) for r in mode_rows) / count, 2
                ),
                "avg_hidden_overhead_tokens_est": round(
                    sum(int(r.get("hidden_overhead_tokens_est") or 0) for r in mode_rows) / count, 2
                ),
                "avg_hidden_uncached_tokens_est": round(
                    sum(int(r.get("hidden_uncached_tokens_est") or 0) for r in mode_rows) / count, 2
                ),
                "avg_tool_calls_total": round(
                    sum(int(r.get("tool_calls_total") or 0) for r in mode_rows) / count, 2
                ),
            }

        native = summarize(modes["native"])
        ralph = summarize(modes["ralph"])
        comparisons.append(
            {
                "plan_key": plan_key,
                "runtime": runtime,
                "native": native,
                "ralph": ralph,
                "delta": {
                    "avg_input_tokens": round(ralph["avg_input_tokens"] - native["avg_input_tokens"], 2),
                    "avg_cache_read_input_tokens": round(
                        ralph["avg_cache_read_input_tokens"] - native["avg_cache_read_input_tokens"], 2
                    ),
                    "avg_prompt_bytes_recorded": round(
                        ralph["avg_prompt_bytes_recorded"] - native["avg_prompt_bytes_recorded"], 2
                    ),
                    "avg_visible_tool_output_bytes": round(
                        ralph["avg_visible_tool_output_bytes"] - native["avg_visible_tool_output_bytes"], 2
                    ),
                    "avg_visible_assistant_output_bytes": round(
                        ralph["avg_visible_assistant_output_bytes"] - native["avg_visible_assistant_output_bytes"], 2
                    ),
                    "avg_hidden_overhead_tokens_est": round(
                        ralph["avg_hidden_overhead_tokens_est"] - native["avg_hidden_overhead_tokens_est"], 2
                    ),
                    "avg_hidden_uncached_tokens_est": round(
                        ralph["avg_hidden_uncached_tokens_est"] - native["avg_hidden_uncached_tokens_est"], 2
                    ),
                    "avg_tool_calls_total": round(
                        ralph["avg_tool_calls_total"] - native["avg_tool_calls_total"], 2
                    ),
                },
            }
        )
    return comparisons


def build_report(logs_dirs: Sequence[str]) -> Dict[str, Any]:
    invocations: List[Dict[str, Any]] = []
    mismatches: List[Dict[str, Any]] = []
    global_index = 0

    for logs_dir in logs_dirs:
        usage_path = os.path.join(logs_dir, "invocation-usage.json")
        output_log = find_output_log(logs_dir)
        usage_doc = load_json(usage_path)
        usage_records = usage_doc.get("invocations") or []
        output_text = read_text(output_log)
        segments = parse_invocation_segments(output_text)
        if len(segments) != len(usage_records):
            mismatches.append(
                {
                    "logs_dir": logs_dir,
                    "usage_records": len(usage_records),
                    "output_segments": len(segments),
                }
            )
        pair_count = min(len(segments), len(usage_records))
        for idx in range(pair_count):
            global_index += 1
            invocations.append(
                summarize_invocation(logs_dir, output_log, segments[idx], usage_records[idx], global_index)
            )

    top_hidden = sorted(
        invocations,
        key=lambda item: (
            int(item.get("hidden_overhead_tokens_est") or 0),
            int(item.get("input_tokens") or 0),
        ),
        reverse=True,
    )

    return {
        "schema_version": 1,
        "kind": "log_bloat_report",
        "logs_dirs": list(logs_dirs),
        "mismatches": mismatches,
        "invocations": invocations,
        "aggregate_by_runtime": aggregate_by(invocations, "runtime"),
        "aggregate_by_tool_access": aggregate_by(invocations, "tool_access"),
        "aggregate_by_runtime_tool_access": aggregate_by_runtime_tool_access(invocations),
        "runtime_tool_access_comparisons": build_runtime_tool_access_comparisons(invocations),
        "plan_runtime_mode_comparisons": build_plan_runtime_mode_comparisons(invocations),
        "top_hidden_overhead_invocations": top_hidden[:20],
    }


def parse_args(argv: Optional[Sequence[str]] = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Estimate visible prompt/tool bloat from Ralph logs.",
    )
    parser.add_argument(
        "--logs-dir",
        action="append",
        required=True,
        help="Plan logs directory containing invocation-usage.json and *-output.log. Repeatable.",
    )
    parser.add_argument(
        "--output",
        help="Write JSON report to this path instead of stdout.",
    )
    return parser.parse_args(argv)


def main(argv: Optional[Sequence[str]] = None) -> int:
    args = parse_args(argv)
    report = build_report(args.logs_dir)
    text = json.dumps(report, indent=2, sort_keys=False)
    if args.output:
        with open(args.output, "w", encoding="utf-8") as fh:
            fh.write(text)
            fh.write("\n")
    else:
        sys.stdout.write(text + "\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
