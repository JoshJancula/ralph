#!/usr/bin/env python3
"""Aggregate Jev (TypeSafe AI) per-call usage from <jev_state_dir>/usage.jsonl.

Jev is an HTTP adapter, not a CLI runtime, so its usage is kept apart from the
runtime/cache buckets in invocation-usage.json. Records are written by the
transport (jev_client.record_usage / jev_record_usage in jev-client.sh).

Usage:
  jev_usage.py [--state-dir DIR | --file PATH] [--plan-key KEY]
               [--include-fixture] [--omit-empty] [--format text|json]
  jev_usage.py --merge-json [same options]   # reads a JSON object on stdin,
                                             # adds a "jev" key when there is
                                             # usage, and prints it.

Fixture-transport lines (offline tests) are ignored unless --include-fixture.
Cost is an estimate: rates come from RALPH_JEV_INPUT_USD_PER_MTOK (default
0.042) and RALPH_JEV_OUTPUT_USD_PER_MTOK (default 0, output tokens are free);
see docs/TOOLING.md "Cost and latency".
"""
from __future__ import annotations

import argparse
import json
import os
import sys
from typing import Any, Iterable, Mapping, Optional

DEFAULT_INPUT_USD_PER_MTOK = 0.042
DEFAULT_OUTPUT_USD_PER_MTOK = 0.0


def _int(value: Any) -> int:
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        return 0
    return max(0, int(value))


def _rate(name: str, default: Optional[float]) -> Optional[float]:
    raw = os.environ.get(name, "").strip()
    if not raw:
        return default
    try:
        val = float(raw)
    except ValueError:
        return default
    return val if val >= 0 else default


def state_dir() -> str:
    explicit = os.environ.get("RALPH_JEV_STATE_DIR", "").strip()
    if explicit:
        return explicit.rstrip("/")
    root = os.environ.get("RALPH_PLAN_WORKSPACE_ROOT", "").strip() or os.path.join(
        os.getcwd(), ".ralph-workspace"
    )
    return os.path.join(root.rstrip("/"), "jev")


def read_records(path: str) -> Iterable[Mapping[str, Any]]:
    try:
        handle = open(path, "r", encoding="utf-8")
    except OSError:
        return
    with handle:
        for line in handle:
            line = line.strip()
            if not line:
                continue
            try:
                obj = json.loads(line)
            except json.JSONDecodeError:
                continue
            if isinstance(obj, dict):
                yield obj


def aggregate(
    records: Iterable[Mapping[str, Any]],
    plan_key: str = "",
    include_fixture: bool = False,
) -> dict[str, Any]:
    by_set: dict[str, dict[str, Any]] = {}
    by_model: dict[str, dict[str, int]] = {}
    total = {
        "calls": 0,
        "input_tokens": 0,
        "output_tokens": 0,
        "calls_measured": 0,
        "calls_unavailable": 0,
    }
    for rec in records:
        if not include_fixture and rec.get("transport") == "fixture":
            continue
        if plan_key and rec.get("planKey") != plan_key:
            continue
        in_tok = _int(rec.get("input_tokens"))
        out_tok = _int(rec.get("output_tokens"))
        measured = rec.get("usageSource") == "measured"
        total["calls"] += 1
        total["input_tokens"] += in_tok
        total["output_tokens"] += out_tok
        total["calls_measured" if measured else "calls_unavailable"] += 1

        qs = str(rec.get("questionSetId") or "(unnamed)")
        row = by_set.setdefault(
            qs, {"calls": 0, "input_tokens": 0, "output_tokens": 0}
        )
        row["calls"] += 1
        row["input_tokens"] += in_tok
        row["output_tokens"] += out_tok

        model = str(rec.get("model") or "(unresolved)")
        mrow = by_model.setdefault(
            model, {"calls": 0, "input_tokens": 0, "output_tokens": 0}
        )
        mrow["calls"] += 1
        mrow["input_tokens"] += in_tok
        mrow["output_tokens"] += out_tok

    in_rate = _rate("RALPH_JEV_INPUT_USD_PER_MTOK", DEFAULT_INPUT_USD_PER_MTOK)
    out_rate = _rate("RALPH_JEV_OUTPUT_USD_PER_MTOK", DEFAULT_OUTPUT_USD_PER_MTOK)
    cost: Optional[dict[str, Any]] = None
    if total["calls"]:
        usd = 0.0
        if in_rate is not None:
            usd += total["input_tokens"] * in_rate / 1_000_000
        if out_rate is not None:
            usd += total["output_tokens"] * out_rate / 1_000_000
        cost = {
            "estimated_usd": round(usd, 6),
            "input_rate_usd_per_mtok": in_rate,
            "output_rate_usd_per_mtok": out_rate,
            "note": "estimated",
        }
    return {
        "kind": "jev_usage",
        "schema_version": 1,
        **total,
        "by_question_set": by_set,
        "by_model": by_model,
        "cost": cost,
    }


def render_text(summary: Mapping[str, Any]) -> str:
    lines = ["Jev (TypeSafe AI) usage"]
    lines.append(
        "  calls: %d (measured %d, usage unavailable %d)"
        % (summary["calls"], summary["calls_measured"], summary["calls_unavailable"])
    )
    lines.append(
        "  tokens: input %d, output %d"
        % (summary["input_tokens"], summary["output_tokens"])
    )
    cost = summary.get("cost")
    if isinstance(cost, Mapping):
        lines.append("  cost: ~$%.6f (%s)" % (cost["estimated_usd"], cost["note"]))
    sets = summary.get("by_question_set") or {}
    if sets:
        lines.append("  by question set:")
        for name in sorted(sets, key=lambda k: -sets[k]["calls"]):
            row = sets[name]
            lines.append(
                "    %-32s calls %-5d in %-8d out %d"
                % (name, row["calls"], row["input_tokens"], row["output_tokens"])
            )
    return "\n".join(lines)


def main(argv: Optional[list[str]] = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--state-dir", default="")
    ap.add_argument("--file", default="")
    ap.add_argument("--plan-key", default="")
    ap.add_argument("--include-fixture", action="store_true")
    ap.add_argument("--format", choices=("text", "json"), default="text")
    ap.add_argument("--merge-json", action="store_true")
    ap.add_argument(
        "--omit-empty",
        action="store_true",
        help="print nothing (text) when there are no recorded calls",
    )
    args = ap.parse_args(argv)

    path = args.file or os.path.join(args.state_dir or state_dir(), "usage.jsonl")
    summary = aggregate(read_records(path), args.plan_key, args.include_fixture)

    if args.merge_json:
        raw = sys.stdin.read()
        try:
            base = json.loads(raw)
        except json.JSONDecodeError:
            sys.stdout.write(raw)
            return 0
        if isinstance(base, dict) and summary["calls"]:
            base["jev"] = summary
        json.dump(base, sys.stdout, indent=2)
        sys.stdout.write("\n")
        return 0

    if args.format == "json":
        json.dump(summary, sys.stdout, indent=2)
        sys.stdout.write("\n")
    elif summary["calls"]:
        print(render_text(summary))
    elif not args.omit_empty:
        print("Jev (TypeSafe AI) usage: no recorded calls")
    return 0


if __name__ == "__main__":
    sys.exit(main())
