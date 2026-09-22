#!/usr/bin/env python3
"""Report where an invocation's cached-token spend actually went.

Token counts misrepresent cost: cache reads bill at ~0.1x base input price and
cache writes at ~1.25x (5-minute TTL) or ~2x (1-hour TTL), so the write bucket is
typically a small share of volume and a large share of the bill. This report prices
both buckets from the measured TTL split and attributes the redundant-read portion.

Costs are expressed in "base-input-token equivalents" (beq): the number of
uncached input tokens that would cost the same. That keeps the report
model-independent -- multiply by a model's input rate for currency.

Usage:
    python3 scripts/cache-cost-report.py <invocation-usage.json> [--runtime claude]
"""

from __future__ import annotations

import argparse
import json
import statistics
import sys
from typing import Any, Mapping, Sequence

CACHE_READ_PRICE = 0.10
CACHE_WRITE_5M_PRICE = 1.25
CACHE_WRITE_1H_PRICE = 2.00


def write_price(record: Mapping[str, Any]) -> float:
    """Blended cache-write price from the record's measured 5m/1h TTL split.

    Falls back to the 1-hour rate when unreported: measured Claude Code runs write
    entirely at the 1-hour TTL, so assuming 5-minute would understate cost.
    """
    m5 = as_int(record.get("cache_creation_5m_input_tokens"))
    h1 = as_int(record.get("cache_creation_1h_input_tokens"))
    if m5 + h1 <= 0:
        return CACHE_WRITE_1H_PRICE
    return (m5 * CACHE_WRITE_5M_PRICE + h1 * CACHE_WRITE_1H_PRICE) / (m5 + h1)


def as_int(value: Any) -> int:
    try:
        return max(0, int(float(value)))
    except (TypeError, ValueError):
        return 0


def load_records(path: str, runtime: str) -> list[Mapping[str, Any]]:
    with open(path, "r", encoding="utf-8") as fh:
        doc = json.load(fh)
    records = doc.get("invocations", doc) if isinstance(doc, dict) else doc
    if not isinstance(records, list):
        raise SystemExit(f"{path}: no invocation list found")
    if runtime:
        records = [r for r in records if r.get("runtime") == runtime]
    return [r for r in records if isinstance(r, Mapping)]


# Why an invocation has no redundant-read measurement. These are NOT the same
# thing and must never be collapsed: one is a gap in the data, the other is a
# blind spot in the instrument.
UNMEASURED_NO_TELEMETRY = "no-telemetry"
UNMEASURED_SHELL_READS = "shell-reads"
UNMEASURED_NO_READS = "no-reads"


def redundant_read_share(record: Mapping[str, Any]) -> tuple[float | None, str]:
    """Fraction of read-family tool calls that re-read an already-read target.

    Returns (share, reason). A None share is never reported as zero waste, and
    the reason distinguishes missing telemetry from an invocation whose file
    access happened through the shell -- where Ralph hashes the command and so
    cannot tell which file was touched, let alone whether it was touched twice.
    """
    extra = record.get("repeated_read_extra_calls")
    if extra is None:
        return None, UNMEASURED_NO_TELEMETRY

    targets = record.get("tool_call_targets")
    reads = shell = 0
    if isinstance(targets, list):
        for t in targets:
            if not isinstance(t, Mapping):
                continue
            family = t.get("family")
            if family == "read":
                reads += 1
            elif family == "shell":
                shell += 1
    if reads <= 0:
        return None, UNMEASURED_SHELL_READS if shell > 0 else UNMEASURED_NO_READS
    return min(1.0, as_int(extra) / reads), ""


def report(records: Sequence[Mapping[str, Any]]) -> int:
    if not records:
        print("no matching invocations")
        return 1

    hdr = f"{'#':<3}{'reqs':>6}{'ctx/req':>10}{'text-only':>12}{'write':>10}{'read':>12}{'wr_beq':>11}{'rd_beq':>11}{'wr%':>6}{'redund':>8}{'prefix tokens (first request)':>30}"
    print(hdr)
    print("-" * len(hdr))

    tw = tr = 0.0
    measured: list[tuple[float, float, float, int]] = []
    reasons: dict[str, int] = {}
    for i, r in enumerate(records, 1):
        wr, rd = as_int(r.get("cache_creation_input_tokens")), as_int(
            r.get("cache_read_input_tokens")
        )
        reqs = as_int(r.get("tool_turns"))
        text_only = as_int(r.get("requests_without_tool_use"))
        wc, rc = wr * write_price(r), rd * CACHE_READ_PRICE
        tw, tr = tw + wc, tr + rc
        share, reason = redundant_read_share(r)
        if share is None:
            reasons[reason] = reasons.get(reason, 0) + 1
            share_txt = {
                UNMEASURED_NO_TELEMETRY: "n/a",
                UNMEASURED_SHELL_READS: "shell",
                UNMEASURED_NO_READS: "-",
            }[reason]
        else:
            measured.append((share, wc, rc, reqs))
            share_txt = f"{100 * share:.0f}%"
        # Codex request telemetry is unavailable when neither token_count nor
        # its item fallback produced a request. Avoid presenting a bogus zero-
        # divided value as a measured context size.
        if reqs:
            ctx = f"{rd // reqs:,}"
        elif r.get("runtime") == "codex":
            ctx = "n/a"
        else:
            ctx = "-"
        pct = 100 * wc / (wc + rc) if (wc + rc) > 0 else 0
        text_only_txt = f"{text_only}/{reqs} ({100 * text_only / reqs:.0f}%)" if reqs else "n/a"
        prefix = r.get("first_request_input_tokens")
        prefix_txt = f"{as_int(prefix):,}" if prefix is not None else "n/a"
        print(
            f"{i:<3}{reqs:>6}{ctx:>10}{text_only_txt:>12}{wr:>10,}{rd:>12,}{wc:>11,.0f}{rc:>11,.0f}{pct:>5.0f}%{share_txt:>8}{prefix_txt:>30}"
        )

    total = tw + tr
    print("-" * len(hdr))
    print(
        f"\ncached-token spend: {total:,.0f} beq "
        f"(write {tw:,.0f} = {100 * tw / total:.0f}%, read {tr:,.0f} = {100 * tr / total:.0f}%)"
    )

    total_records = len(records)
    if reasons.get(UNMEASURED_NO_TELEMETRY):
        print(
            f"\n{reasons[UNMEASURED_NO_TELEMETRY]} of {total_records} invocations lack "
            "read-waste telemetry (records predate its persistence)."
        )
    if reasons.get(UNMEASURED_SHELL_READS):
        print(
            f"\n{reasons[UNMEASURED_SHELL_READS]} of {total_records} invocations did all "
            "file access through the shell, not read-family tools.\n"
            "Ralph hashes shell commands, so it cannot tell which file a command touched\n"
            "and cannot detect a re-read. Read-waste is UNMEASURABLE for these, not zero --\n"
            "this is a blind spot in the instrument, not evidence of efficiency."
        )
    if reasons.get(UNMEASURED_NO_READS):
        print(
            f"\n{reasons[UNMEASURED_NO_READS]} of {total_records} invocations made no "
            "file-access tool calls at all."
        )
    print("\ntop tools by result bytes")
    result_bytes: dict[str, int] = {}
    for record in records:
        by_tool = record.get("tool_result_bytes_by_tool")
        if isinstance(by_tool, Mapping):
            for tool, size in by_tool.items():
                result_bytes[str(tool)] = result_bytes.get(str(tool), 0) + as_int(size)
    for tool, size in sorted(result_bytes.items(), key=lambda pair: (-pair[1], pair[0]))[:5]:
        print(f"{tool}: {size:,} bytes")

    prefixes = [
        as_int(record.get("first_request_input_tokens"))
        for record in records
        if record.get("first_request_input_tokens") is not None
    ]
    if prefixes:
        median = statistics.median(prefixes)
        median_txt = f"{median:,.0f}" if float(median).is_integer() else f"{median:,.1f}"
        print(
            "\nprefix tokens (first request) min/median/max per plan: "
            f"{min(prefixes):,} / {median_txt} / {max(prefixes):,}"
        )

    if not measured:
        print("\nno invocation has a measurable redundant-read share.")
        return 0

    # A redundant read costs the write premium once, plus a cache read on each
    # later request in that invocation. Averaged over an invocation, a token
    # entering context sits through roughly half the remaining requests.
    savings = 0.0
    for share, wc, rc, reqs in measured:
        savings += share * wc + share * rc
    measured_cost = sum(wc + rc for _, wc, rc, _ in measured)
    print(
        f"\nredundant-read share of measured invocations: "
        f"{100 * sum(s for s, _, _, _ in measured) / len(measured):.0f}% of read calls"
    )
    print(
        f"upper-bound saving if every redundant read were eliminated: "
        f"{savings:,.0f} beq of {measured_cost:,.0f} beq ({100 * savings / measured_cost:.0f}%)"
    )
    print(
        "\nThis is an UPPER BOUND. It assumes redundant reads carry the same average\n"
        "token weight as other reads, and that removing them removes their full write\n"
        "and read cost. Treat it as the ceiling on this lever, not a forecast."
    )
    return 0


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("path", help="path to invocation-usage.json")
    ap.add_argument("--runtime", default="", help="filter to one runtime (e.g. claude)")
    args = ap.parse_args()
    return report(load_records(args.path, args.runtime))


if __name__ == "__main__":
    sys.exit(main())
