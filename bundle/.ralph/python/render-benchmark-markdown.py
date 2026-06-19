#!/usr/bin/env python3
"""Render a benchmark report JSON (from ralph-benchmark-report.py) as Markdown."""

from __future__ import annotations

import json
import sys
from typing import Any, Mapping, Sequence

PATH_LABELS: dict[str, str] = {
    "pre_tool_rewrite": "Shortened commands before running them",
    "hook_compaction": "Trimmed long command output",
    "proxy_shell_compaction": "Trimmed long command output (proxy mode)",
    "result_windowing": "Sent only the relevant slice of big results",
}

# Order in which optimization paths are presented.
PATH_ORDER = [
    "pre_tool_rewrite",
    "hook_compaction",
    "proxy_shell_compaction",
    "result_windowing",
]


def fmt_int(value: Any) -> str:
    if value is None:
        return "-"
    try:
        return f"{int(value):,}"
    except (TypeError, ValueError):
        return "-"


def fmt_pct(value: Any) -> str:
    if value is None:
        return "-"
    try:
        return f"{float(value):.1f}%"
    except (TypeError, ValueError):
        return "-"


def _as_int(value: Any) -> int:
    try:
        return int(value or 0)
    except (TypeError, ValueError):
        return 0


def _run_date(run: Mapping[str, Any]) -> str:
    started = run.get("started_at")
    ended = run.get("ended_at")
    if started and ended and started != ended:
        return f"{started} to {ended}"
    if started:
        return str(started)
    if ended:
        return str(ended)
    return "-"


def _session_usage_rows(session_usage: Mapping[str, Any]) -> list[list[str]]:
    labels = {
        "input_tokens": "Input tokens",
        "output_tokens": "Output tokens",
        "cache_creation_input_tokens": "Cache creation input tokens",
        "cache_read_input_tokens": "Cache read input tokens",
    }
    rows: list[list[str]] = []
    for key, label in labels.items():
        value = session_usage.get(key)
        if value is not None:
            rows.append([label, fmt_int(value)])
    prompt_bytes = session_usage.get("prompt_bytes")
    if prompt_bytes is not None:
        rows.append(["Prompt bytes", fmt_int(prompt_bytes)])
    tool_calls = session_usage.get("tool_calls_total")
    if tool_calls is not None:
        rows.append(["Tool calls total", fmt_int(tool_calls)])
    return rows


def _tool_output_rows(tool_output: Mapping[str, Any]) -> list[list[str]]:
    return [
        [
            "Hypothetical without Ralph",
            fmt_int(tool_output.get("hypothetical_without_ralph_bytes")),
            fmt_int(tool_output.get("hypothetical_without_ralph_tokens")),
        ],
        [
            "Actual with Ralph",
            fmt_int(tool_output.get("actual_with_ralph_bytes")),
            fmt_int(tool_output.get("actual_with_ralph_tokens")),
        ],
        [
            "Net savings",
            fmt_int(tool_output.get("net_savings_bytes")),
            fmt_int(tool_output.get("net_savings_tokens")),
        ],
        [
            "Net savings rate",
            fmt_pct(tool_output.get("net_savings_percent")),
            "-",
        ],
    ]


def _root_cause_lines(
    per_path: Mapping[str, Mapping[str, Any]],
    tool_output: Mapping[str, Any],
    readback_summary: Mapping[str, Any],
    could_have_saved: Mapping[str, Any],
    optimization_opportunities: Mapping[str, Any] | None,
) -> list[str]:
    """Build root-cause bullets when net savings is 0% or near 0%."""
    net_pct = float(tool_output.get("net_savings_percent") or 0)
    if net_pct > 5.0:
        return []

    lines: list[str] = []
    for path_name in PATH_ORDER:
        bucket = per_path.get(path_name) or {}
        status = str(bucket.get("status") or "inactive")
        label = PATH_LABELS.get(path_name, path_name)
        pre = _as_int(bucket.get("pre_optimization_bytes"))
        count = _as_int(bucket.get("count"))
        if status == "inactive" and pre <= 0 and count <= 0:
            lines.append(f"- **{label}** was inactive for this workspace mode.")
        elif status == "negated" and path_name == "result_windowing":
            gross = _as_int(bucket.get("gross_readback_bytes"))
            net_consumed = _as_int(readback_summary.get("net_consumed_bytes"))
            eff_rate = float(readback_summary.get("effective_windowing_savings_rate") or 0)
            lines.append(
                f"- **Result-windowing savings were negated by readback**: agents re-read "
                f"{fmt_int(gross)} bytes of stored results (net consumed {fmt_int(net_consumed)} bytes; "
                f"effective windowing savings rate {fmt_pct(eff_rate * 100)})."
            )

    measured_not_applied = _as_int(
        tool_output.get("compaction_measured_not_applied_bytes")
    )
    if measured_not_applied <= 0:
        measured_not_applied = _as_int(
            could_have_saved.get("compaction_measured_not_applied_bytes")
        )
    if measured_not_applied > 0:
        lines.append(
            f"- **Native compaction was measured but not applied**: {fmt_int(measured_not_applied)} "
            "bytes of compaction savings were observed but unavailable in this runtime mode "
            "(for example, native-mode runs without Ralph proxy)."
        )

    if optimization_opportunities:
        missed = optimization_opportunities.get("missed_compaction_opportunities")
        if isinstance(missed, list) and missed:
            top = missed[0]
            if isinstance(top, Mapping):
                reason = str(top.get("skip_reason") or top.get("skip_type") or "compaction skipped")
                lines.append(
                    f"- **Discover opportunity**: top missed compaction opportunity is "
                    f"`{reason}` ({fmt_int(top.get('original_bytes', 0))} bytes)."
                )
        patterns = optimization_opportunities.get("sequence_patterns")
        if isinstance(patterns, list) and patterns:
            names = [str(p.get("pattern_id") or "-") for p in patterns[:2]]
            lines.append(
                f"- **Usage pattern opportunities**: {', '.join(names)}. "
                "Prefer ralph_proxy_batch for independent reads and compacted byte ranges before raw result reads."
            )

    if not lines and net_pct <= 5.0:
        lines.append(
            "- No single dominant root cause identified; tool-output savings were low across all active paths."
        )
    return lines


def render_markdown(report: Mapping[str, Any]) -> str:
    saved_bytes = int(report.get("saved_bytes", 0) or 0)
    saved_tokens = int(report.get("saved_tokens", 0) or 0)
    run_count = int(report.get("runs_count", report.get("run_count", 1)) or 1)
    date_range = report.get("date_range", {})
    per_path = report.get("per_path", {})
    tool_output = report.get("tool_output_counterfactual", {})
    session_usage = report.get("session_usage", {})
    readback_summary = report.get("readback_summary") or {}
    cache_info = report.get("cache", {})
    could_have_saved = report.get("could_have_saved", {})
    runs = report.get("runs", [])
    optimization_opportunities = report.get("optimization_opportunities")

    net_savings_bytes = _as_int(tool_output.get("net_savings_bytes"))
    net_savings_tokens = _as_int(tool_output.get("net_savings_tokens"))
    net_savings_pct = tool_output.get("net_savings_percent", 0)

    # Fallback to top-level legacy fields when schema v2 counterfactual is absent.
    if not tool_output:
        net_savings_bytes = saved_bytes
        net_savings_tokens = saved_tokens
        net_savings_pct = report.get("savings_percent", 0)

    started = date_range.get("started_at") if date_range else None
    ended = date_range.get("ended_at") if date_range else None

    lines: list[str] = []
    lines.append("# Ralph Savings Report")
    lines.append("")
    lines.append(
        f"Across {run_count} plan run{'s' if run_count != 1 else ''}, Ralph's tool-output "
        f"optimizations netted **{fmt_int(net_savings_bytes)} bytes** "
        f"(~{fmt_int(net_savings_tokens)} tokens) after stored-result readbacks."
    )
    lines.append("")
    lines.append(
        f"Of the tool output Ralph inspected, it trimmed {fmt_pct(net_savings_pct)} "
        "before the AI read it (net of stored-result readbacks)."
    )
    lines.append("")
    lines.append(
        "Bytes are measured from actual output differences; token figures are estimated "
        "at roughly 4 bytes per token. These are tool-output counterfactuals, not a discount "
        "off the billed session tokens below."
    )
    lines.append("")
    lines.append(
        "> **Generated file -- do not hand-edit.** "
        "Regenerate via `ralph benchmark --write-doc`."
    )
    lines.append("")

    if session_usage:
        lines.append("## Session usage")
        lines.append("")
        lines.append("Actual billed token usage from the session:")
        lines.append("")
        session_rows = _session_usage_rows(session_usage)
        if session_rows:
            lines.append("| Metric | Count |")
            lines.append("| --- | --- |")
            for row in session_rows:
                lines.append(f"| {row[0]} | {row[1]} |")
            lines.append("")
        cache_read = _as_int(cache_info.get("cache_read_tokens"))
        cache_hit = cache_info.get("cache_hit_ratio", 0)
        if isinstance(cache_hit, (int, float)) and cache_hit <= 1:
            cache_hit_display = fmt_pct(float(cache_hit) * 100)
        else:
            cache_hit_display = fmt_pct(cache_hit)
        if cache_read > 0 or cache_hit:
            lines.append(
                f"Context reuse: **{fmt_int(cache_read)}** cache-read tokens "
                f"(hit ratio **{cache_hit_display}**). Cache reuse is not counted as savings above."
            )
            lines.append("")

    if tool_output:
        lines.append("## Tool output: with vs without Ralph")
        lines.append("")
        lines.append(
            "Estimated tool-output bytes/tokens that would have reached the model with vs without Ralph. "
            "'Actual with Ralph' includes stored-result readbacks that re-consumed tool output."
        )
        lines.append("")
        lines.append("| Metric | Bytes | Tokens |")
        lines.append("| --- | --- | --- |")
        for row in _tool_output_rows(tool_output):
            lines.append(f"| {row[0]} | {row[1]} | {row[2]} |")
        not_applied = _as_int(
            tool_output.get("compaction_measured_not_applied_bytes")
        )
        if not_applied > 0:
            lines.append("")
            lines.append(
                f"**Measured but not applied:** {fmt_int(not_applied)} bytes of compaction savings "
                "were measured but unavailable in this runtime mode (for example, native-mode runs "
                "without Ralph proxy)."
            )
        lines.append("")

    if runs:
        lines.append("## Per run")
        lines.append("")
        per_run_headers = [
            "Run",
            "Date",
            "Bytes saved (measured)",
            "Est. tokens saved",
            "Trimmed % (of inspected output)",
        ]
        lines.append("| " + " | ".join(per_run_headers) + " |")
        lines.append("| " + " | ".join(["---"] * len(per_run_headers)) + " |")
        for run in runs:
            run_id = run.get("id", "-")
            lines.append(
                "| {run} | {date} | {bytes} | {tokens} | {trimmed} |".format(
                    run=run_id,
                    date=_run_date(run),
                    bytes=fmt_int(run.get("saved_bytes", 0)),
                    tokens=fmt_int(run.get("saved_tokens", 0)),
                    trimmed=fmt_pct(run.get("savings_percent", 0)),
                )
            )
        lines.append("")

    if isinstance(readback_summary, Mapping) and _as_int(
        readback_summary.get("envelope_count", 0)
    ) > 0:
        lines.append("## Stored result follow-ups")
        lines.append("")
        lines.append(
            "Result windowing sends a compact preview; follow-up reads add bytes back. "
            "Effective windowing savings rate is the decision-grade net signal after capping "
            "readbacks at the original envelope size."
        )
        lines.append("")
        lines.append(
            f"- Envelopes: **{fmt_int(readback_summary.get('envelope_count'))}**; "
            f"readbacks: **{fmt_int(readback_summary.get('readback_count'))}** "
            f"(compacted **{fmt_int(readback_summary.get('compacted_readback_count'))}**, "
            f"raw **{fmt_int(readback_summary.get('raw_readback_count'))}**). "
            f"Full preview re-reads: **{fmt_int(readback_summary.get('full_preview_rereads'))}**."
        )
        lines.append(
            f"- Gross follow-up reads: **{fmt_int(readback_summary.get('gross_readback_bytes'))} bytes** "
            f"(~{fmt_int(readback_summary.get('gross_readback_tokens'))} tokens); "
            f"net consumed: **{fmt_int(readback_summary.get('net_consumed_bytes'))} bytes** "
            f"(~{fmt_int(readback_summary.get('net_consumed_tokens'))} tokens)."
        )
        lines.append(
            f"- Effective windowing savings rate: **{fmt_pct(float(readback_summary.get('effective_windowing_savings_rate', 0) or 0) * 100)}** "
            "of original envelope bytes (net of capped readbacks)."
        )
        if _as_int(readback_summary.get("readback_count")) > 0:
            raw_share = float(readback_summary.get("raw_readback_share") or 0)
            lines.append(
                f"- Raw readback share: **{fmt_pct(raw_share * 100)}** of follow-up reads; "
                f"diagnostic gross negation rate: **{fmt_pct(float(readback_summary.get('readback_negation_rate', 0) or 0) * 100)}** "
                "of envelope original bytes."
            )
        lines.append("")

    root_causes = _root_cause_lines(
        per_path,
        tool_output if tool_output else {"net_savings_percent": net_savings_pct},
        readback_summary,
        could_have_saved,
        optimization_opportunities,
    )
    if root_causes:
        lines.append("## Why savings are low")
        lines.append("")
        lines.extend(root_causes)
        lines.append("")

    if isinstance(optimization_opportunities, Mapping) and optimization_opportunities:
        lines.append("## Improvement opportunities")
        lines.append("")
        missed = optimization_opportunities.get("missed_compaction_opportunities")
        if isinstance(missed, list) and missed:
            lines.append("Missed compaction opportunities:")
            seen: set[str] = set()
            shown = 0
            for item in missed:
                if not isinstance(item, Mapping):
                    continue
                try:
                    key = json.dumps(item, sort_keys=True, separators=(",", ":"), ensure_ascii=False)
                except TypeError:
                    key = repr(sorted(item.items()))
                if key in seen:
                    continue
                seen.add(key)
                reason = str(
                    item.get("skip_reason") or item.get("skip_type") or "compaction skipped"
                )
                lines.append(
                    f"- `{reason}` ({fmt_int(item.get('original_bytes', 0))} bytes)"
                )
                shown += 1
                if shown >= 3:
                    break
            lines.append("")
        patterns = optimization_opportunities.get("sequence_patterns")
        if isinstance(patterns, list) and patterns:
            lines.append("Usage pattern opportunities:")
            for pattern in patterns[:3]:
                pid = str(pattern.get("pattern_id") or "-")
                desc = str(pattern.get("description") or "")
                lines.append(f"- `{pid}`{(': ' + desc) if desc else ''}")
            lines.append("")
        stored_usage = optimization_opportunities.get("stored_result_usage")
        if isinstance(stored_usage, Mapping):
            recommendation = stored_usage.get("recommendation")
            if recommendation:
                lines.append(f"Stored result usage: {recommendation}")
                lines.append("")
        native_findings = optimization_opportunities.get("native_read_findings")
        if isinstance(native_findings, list) and native_findings:
            lines.append("Native read findings:")
            for finding in native_findings[:3]:
                pid = str(finding.get("pattern_id") or "-")
                share = float(finding.get("native_read_share") or 0)
                lines.append(
                    f"- `{pid}`: {fmt_pct(share * 100)} of read-like calls were native reads."
                )
            lines.append("")

    skipped = int(report.get("skipped_summaries", 0) or 0)
    if skipped > 0:
        lines.append("## Data quality")
        lines.append("")
        lines.append(
            f"- **Skipped:** {fmt_int(skipped)} unreadable summary "
            f"file{'s' if skipped != 1 else ''} were excluded (malformed JSON); "
            "their savings are not counted above."
        )
        lines.append("")

    lines.append("## How to read this")
    lines.append("")
    lines.append(
        "- **Session usage** shows cumulative billed tokens (input/output/cache) from the plan run "
        "(these are the actual API call totals across all invocations). This is independent of the "
        "estimated tool-output counterfactuals below."
    )
    lines.append(
        "- **Tool output: with vs without Ralph** estimates the bytes/tokens that would have reached "
        "the model from tool output if Ralph had not trimmed it. These are counterfactual estimates "
        "of what the model would have ingested, not a discount off the billed session input tokens above. "
        "'Actual with Ralph' includes follow-up stored-result readbacks, so heavy rereads can drive "
        "net savings toward zero even when previews were compact."
    )
    lines.append(
        "- **Net savings** (in the Tool output table) is the estimated reduction in bytes/tokens sent "
        "to the model after Ralph's optimizations. This is measured from tool-output differences only, "
        "not from the billed session usage totals."
    )
    lines.append(
        "- **Stored result follow-ups** distinguishes gross re-read bytes (diagnostic) from "
        "net effective windowing savings. A high gross negation rate is expected when agents "
        "escalate to raw or full-preview views."
    )
    lines.append(
        "- **Why savings are low** prints root causes only when the net savings rate is near 0%: "
        "inactive paths, readback-negated windowing, or compaction measured but not applied."
    )
    lines.append("- This report does not measure end-to-end wall-clock speedup.")
    lines.append("")

    if started or ended:
        lines.append(f"Date range: {started or 'unknown'} to {ended or 'unknown'}.")
        lines.append("")

    return "\n".join(lines)


def main(argv: Sequence[str] | None = None) -> int:
    args = list(sys.argv[1:] if argv is None else argv)
    if not args or args[0] in ("-h", "--help"):
        print(
            "Usage: render-benchmark-markdown.py benchmark-report.json",
            file=sys.stderr,
        )
        return 0 if args else 2

    path = args[0]
    with open(path, encoding="utf-8") as fh:
        report = json.load(fh)

    print(render_markdown(report))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
