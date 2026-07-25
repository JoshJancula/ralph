#!/usr/bin/env python3
"""Render per-invocation usage summaries as boxed plain-text tables."""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
from typing import Any, List, Optional, Sequence

sys.path.insert(0, os.path.dirname(__file__))

from tool_call_classification import classify_tool_calls

_ANSI_RE = re.compile(r"\x1b\[[0-9;]*m")

# RALPH_INVOCATION_SUMMARY_COLOR=1 forces color when the caller captures stdout
# (command substitution) but ultimately prints to a color-capable terminal.
_COLOR_CODES = {
    "reset": "\x1b[0m",
    "cyan": "\x1b[1;36m",
    "green": "\x1b[32m",
    "yellow": "\x1b[33m",
    "red": "\x1b[31m",
    "blue": "\x1b[34m",
    "dim": "\x1b[2m",
}


def emit(line: str = "") -> None:
    sys.stdout.buffer.write((line + "\n").encode("utf-8"))


def visible_len(text: str) -> int:
    return len(_ANSI_RE.sub("", text))


def fmt_int(value: Any) -> str:
    if value in (None, ""):
        return ""
    try:
        return f"{int(value):,}"
    except (TypeError, ValueError):
        return str(value)


def display_tool_family(name: str) -> str:
    counts = classify_tool_calls({name: 1})
    if counts["ralph_proxy_calls"] > 0:
        return "ralph"
    if counts["other_mcp_calls"] > 0:
        return "mcp"
    if counts["runtime_hook_rewrite_calls"] > 0 or counts["runtime_hook_compaction_calls"] > 0:
        return "hooks"
    if counts["unknown_tool_calls"] > 0:
        return "unknown"
    return "native"


def family_color_name(family: str) -> str:
    return {
        "native": "green",
        "ralph": "blue",
        "hooks": "yellow",
        "mcp": "dim",
    }.get(family, "dim")


class InvocationSummaryRenderer:
    def __init__(self, *, color: bool, ascii_only: bool) -> None:
        self.color = bool(color)
        self.ascii_only = bool(ascii_only)
        if self.ascii_only:
            self.tl = self.tr = self.bl = self.br = "+"
            self.hz = "-"
            self.vt = "|"
            self.mid_left = self.mid_right = "+"
        else:
            self.tl, self.tr, self.bl, self.br = "\u250c", "\u2510", "\u2514", "\u2518"
            self.hz = "\u2500"
            self.vt = "\u2502"
            self.mid_left, self.mid_right = "\u251c", "\u2524"

    def paint(self, text: str, code_name: str) -> str:
        if not self.color:
            return text
        code = _COLOR_CODES.get(code_name, "")
        if not code:
            return text
        return f"{code}{text}{_COLOR_CODES['reset']}"

    def fit(self, text: str, width: int, align: str = "l") -> str:
        pad = max(0, width - visible_len(text))
        if align == "r":
            return (" " * pad) + text
        if align == "c":
            left = pad // 2
            return (" " * left) + text + (" " * (pad - left))
        return text + (" " * pad)

    def render_table(
        self,
        title: str,
        headers: Sequence[str],
        rows: Sequence[Optional[Sequence[str]]],
        *,
        aligns: Optional[Sequence[str]] = None,
        row_label_codes: Optional[Sequence[str]] = None,
        title_code: str = "cyan",
        header_code: str = "cyan",
        inner_width: Optional[int] = None,
        flex_col: Optional[int] = None,
    ) -> List[str]:
        cols = len(headers)
        aligns = list(aligns or (["l"] + ["r"] * (cols - 1)))
        row_list = list(rows or [])
        widths = [visible_len(h) for h in headers]
        for row in row_list:
            if row is None:
                continue
            for idx in range(cols):
                if idx < len(row):
                    widths[idx] = max(widths[idx], visible_len(row[idx]))

        natural = sum(widths) + (cols - 1) * 3
        if inner_width is not None and inner_width > natural:
            target = flex_col if flex_col is not None else (cols - 1)
            widths[target] += inner_width - natural
            natural = inner_width
        inner = natural

        border_code = "dim"
        bar = self.paint(self.vt, border_code)
        col_sep = " " + bar + " "

        def rule(left: str, right: str) -> str:
            return self.paint(left + (self.hz * (inner + 2)) + right, border_code)

        def shell(content: str) -> str:
            return bar + " " + content + " " + bar

        out = [rule(self.tl, self.tr)]
        out.append(shell(self.fit(self.paint(title, title_code), inner, "l")))
        out.append(rule(self.mid_left, self.mid_right))
        header_cells = [
            self.fit(self.paint(headers[i], header_code), widths[i], aligns[i]) for i in range(cols)
        ]
        out.append(shell(col_sep.join(header_cells)))
        out.append(rule(self.mid_left, self.mid_right))
        if row_list:
            for r_index, row in enumerate(row_list):
                if row is None:
                    out.append(shell(" " * inner))
                    continue
                cells: List[str] = []
                for i in range(cols):
                    value = row[i] if i < len(row) else ""
                    if (
                        i == 0
                        and row_label_codes
                        and r_index < len(row_label_codes)
                        and row_label_codes[r_index]
                    ):
                        value = self.paint(value, row_label_codes[r_index])
                    cells.append(self.fit(value, widths[i], aligns[i]))
                out.append(shell(col_sep.join(cells)))
        else:
            out.append(shell(self.fit("(none)", inner, "l")))
        out.append(rule(self.bl, self.br))
        return out

    @staticmethod
    def table_width(lines: Sequence[str]) -> int:
        return max((visible_len(line) for line in lines), default=0)

    def join_side_by_side(
        self,
        left: Sequence[str],
        right: Sequence[str],
        gap: str = "   ",
    ) -> List[str]:
        lw = self.table_width(left)
        height = max(len(left), len(right))
        out: List[str] = []
        for i in range(height):
            left_line = self.fit(left[i], lw, "l") if i < len(left) else (" " * lw)
            right_line = right[i] if i < len(right) else ""
            out.append(left_line + gap + right_line)
        return out


def resolve_color_enabled(args: argparse.Namespace) -> bool:
    if args.ascii_only:
        return False
    if args.color:
        return os.environ.get("NO_COLOR", "") == ""
    if args.no_color:
        return False
    return os.environ.get("NO_COLOR", "") == "" and (
        sys.stdout.isatty() or os.environ.get("RALPH_INVOCATION_SUMMARY_COLOR", "") == "1"
    )


def load_usage_json(raw: str, path: Optional[str]) -> str:
    if path:
        try:
            with open(path, "r", encoding="utf-8") as fh:
                return fh.read()
        except OSError as exc:
            sys.stderr.write(f"Error: unable to read usage JSON file: {exc}\n")
            raise SystemExit(2)
    return raw


def render_invocation_summary(
    *,
    iteration: str,
    runtime: str,
    model: str,
    input_tokens: str,
    output_tokens: str,
    tool_calls: str,
    cache_create: str,
    cache_read: str,
    cache_hit: str,
    rate_limit_status: str,
    usage_json: str,
    todo_ordinal: str,
    todo_line: str,
    todos_done: str,
    todos_total: str,
    elapsed: str,
    color: bool,
    ascii_only: bool,
) -> str:
    renderer = InvocationSummaryRenderer(color=color, ascii_only=ascii_only)

    usage_data: dict = {}
    if usage_json:
        try:
            usage_data = json.loads(usage_json)
        except (ValueError, TypeError):
            usage_data = {}
    usage_unsupported = bool(usage_data.get("usage_unsupported"))

    rate_limit_display = (
        rate_limit_status if rate_limit_status and rate_limit_status != "none" else "n/a"
    )
    todo_display = "-"
    if todo_ordinal and todos_total:
        todo_display = f"{todo_ordinal}/{todos_total}"
        if todo_line:
            todo_display = f"{todo_display} (line {todo_line})"
    elif todo_line:
        todo_display = f"line {todo_line}"

    runtime_rows: List[Optional[List[str]]] = [
        ["Todo", todo_display],
        ["Invocation", iteration],
        ["Runtime", runtime or "-"],
        ["Model", model or "-"],
        ["Elapsed", f"{elapsed}s"],
        ["Rate Limit", rate_limit_display],
    ]
    runtime_label_codes = ["cyan", "dim", "cyan", "cyan", "cyan", "cyan"]

    try:
        hit_pct = float(cache_hit)
    except (TypeError, ValueError):
        hit_pct = 0.0
    if hit_pct >= 90:
        hit_code = "green"
    elif hit_pct >= 70:
        hit_code = "yellow"
    elif hit_pct > 0:
        hit_code = "red"
    else:
        hit_code = "dim"

    usage_rows: List[Optional[List[str]]] = [
        ["Input", "n/a" if usage_unsupported else fmt_int(input_tokens)],
        ["Output", "n/a" if usage_unsupported else fmt_int(output_tokens)],
        ["Tool Calls", fmt_int(tool_calls)],
        ["Cache Read", "n/a" if usage_unsupported else fmt_int(cache_read)],
        ["Cache Write", "n/a" if usage_unsupported else fmt_int(cache_create)],
        [
            "Cache Hit",
            "n/a" if usage_unsupported else renderer.paint(f"{cache_hit}%", hit_code),
        ],
    ]
    usage_label_codes = ["green", "green", "cyan", "yellow", "yellow", "yellow"]

    height = max(len(runtime_rows), len(usage_rows))
    runtime_rows_padded = runtime_rows + [None] * (height - len(runtime_rows))
    usage_rows_padded = usage_rows + [None] * (height - len(usage_rows))

    runtime_card = renderer.render_table(
        "Runtime Details",
        ["Field", "Value"],
        runtime_rows_padded,
        aligns=["l", "r"],
        row_label_codes=runtime_label_codes,
    )
    usage_card = renderer.render_table(
        "Usage Summary",
        ["Metric", "Count"],
        usage_rows_padded,
        aligns=["l", "l"],
        row_label_codes=usage_label_codes,
    )

    top_block = renderer.join_side_by_side(runtime_card, usage_card)
    combined_width = renderer.table_width(top_block)

    detail_rows: List[List[str]] = []
    if usage_data:
        tool_counts = usage_data.get("tool_calls_by_tool") or {}
        detail_rows = [
            [display_tool_family(name), str(name), fmt_int(count)]
            for name, count in sorted(
                ((str(name), int(count)) for name, count in tool_counts.items() if int(count) > 0),
                key=lambda item: (-item[1], item[0]),
            )
        ]

    if detail_rows:
        detail_codes = [family_color_name(row[0]) for row in detail_rows]
        tool_block = renderer.render_table(
            "Tool Usage Details",
            ["Family", "Tool", "Count"],
            detail_rows,
            aligns=["l", "c", "r"],
            row_label_codes=detail_codes,
            inner_width=combined_width - 4,
            flex_col=1,
        )
    else:
        tool_block = renderer.render_table(
            "Tool Usage Details",
            ["Family", "Tool", "Count"],
            [["-", "(none)", "-"]],
            aligns=["l", "c", "r"],
            row_label_codes=["dim"],
            inner_width=combined_width - 4,
            flex_col=1,
        )

    return "\n".join(top_block + [""] + tool_block)


def parse_args(argv: Sequence[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        prog="ralph-invocation-summary-text.py",
        description="Render per-invocation usage JSON as boxed plain text.",
    )
    parser.add_argument(
        "--color",
        action="store_true",
        help="Force ANSI color (respects NO_COLOR).",
    )
    parser.add_argument(
        "--no-color",
        action="store_true",
        help="Disable ANSI color.",
    )
    parser.add_argument(
        "--ascii-only",
        action="store_true",
        help="Use ASCII box glyphs and disable color.",
    )
    parser.add_argument(
        "--elapsed",
        default=None,
        help="Elapsed seconds for the invocation (default: _inv_elapsed env or 0).",
    )
    parser.add_argument(
        "--usage-json-file",
        default=None,
        help="Path to a usage JSON file (overrides positional usage_json).",
    )
    parser.add_argument("iteration", nargs="?", default="")
    parser.add_argument("runtime", nargs="?", default="")
    parser.add_argument("model", nargs="?", default="")
    parser.add_argument("input_tokens", nargs="?", default="")
    parser.add_argument("output_tokens", nargs="?", default="")
    parser.add_argument("tool_calls", nargs="?", default="")
    parser.add_argument("cache_create", nargs="?", default="")
    parser.add_argument("cache_read", nargs="?", default="")
    parser.add_argument("cache_hit", nargs="?", default="")
    parser.add_argument("prompt_bytes", nargs="?", default="")
    parser.add_argument("todo_bytes", nargs="?", default="")
    parser.add_argument("todo_continuation_lines", nargs="?", default="")
    parser.add_argument("rate_limit_status", nargs="?", default="")
    parser.add_argument("usage_json", nargs="?", default="")
    parser.add_argument("todo_ordinal", nargs="?", default="")
    parser.add_argument("todo_line", nargs="?", default="")
    parser.add_argument("todos_done", nargs="?", default="")
    parser.add_argument("todos_total", nargs="?", default="")
    return parser.parse_args(argv)


def main(argv: Sequence[str]) -> int:
    args = parse_args(argv)
    if args.color and args.no_color:
        sys.stderr.write("Error: --color and --no-color are mutually exclusive.\n")
        return 2

    color = resolve_color_enabled(args)
    elapsed = args.elapsed
    if elapsed is None:
        elapsed = os.environ.get("_inv_elapsed", "0")

    usage_json = load_usage_json(args.usage_json, args.usage_json_file)
    block = render_invocation_summary(
        iteration=args.iteration,
        runtime=args.runtime,
        model=args.model,
        input_tokens=args.input_tokens,
        output_tokens=args.output_tokens,
        tool_calls=args.tool_calls,
        cache_create=args.cache_create,
        cache_read=args.cache_read,
        cache_hit=args.cache_hit,
        rate_limit_status=args.rate_limit_status,
        usage_json=usage_json,
        todo_ordinal=args.todo_ordinal,
        todo_line=args.todo_line,
        todos_done=args.todos_done,
        todos_total=args.todos_total,
        elapsed=elapsed,
        color=color,
        ascii_only=args.ascii_only,
    )
    emit(block)
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
