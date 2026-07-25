#!/usr/bin/env python3
"""Write checkpoint.md, checkpoint.json, and invocation-context-ledger.jsonl under RALPH_SESSION_DIR.

Invoked by run-plan-checkpoint.sh after a TODO is marked complete in checkpoint session strategy.

Rollover (optional env, positive integers; invalid values use defaults):
  RALPH_CHECKPOINT_ROLLOVER_MAX_JSON_ENTRIES   default 200 -- keep newest completed-TODO records in checkpoint.json.
  RALPH_CHECKPOINT_ROLLOVER_MAX_MD_BYTES      default 65536 -- UTF-8 cap on checkpoint.md; oldest ## TODO sections dropped first.
  RALPH_CHECKPOINT_ROLLOVER_MAX_LEDGER_LINES  default 2000 -- tail cap on invocation-context-ledger.jsonl.

Output budgeting for checkpoint-fed JSON / markdown (full stream stays in plan-runner-*-output.log on disk):
  RALPH_AGENT_OUTPUT_MAX_BYTES       default 24000 -- UTF-8 tail cap when reading the invocation segment into the excerpt temp file.
  RALPH_AGENT_TOOL_EVENT_MAX_BYTES   default 16000 -- UTF-8 cap for serialized tool command labels in checkpoint summaries
    (each ledger command_label is summarized via command-output-summarize.py / ralph_summarize_command_output semantics, then tail-budgeted).
  RALPH_TOOL_RESULT_MAX_BYTES        default 32768 -- UTF-8 cap per entry in ledger tool_result_excerpts when copied into checkpoint_feed (head + tail with omitted marker).
  RALPH_CHECKPOINT_OUTPUT_SUMMARY_MAX_BYTES  default 4096 -- UTF-8 cap for the summarized invocation text stored in checkpoint.md / checkpoint_feed (not raw log tail).
  RALPH_CHECKPOINT_FEED_MAX_BYTES            default follows RALPH_PLAN_CHECKPOINT_MAX_BYTES (12000) -- UTF-8 cap on the combined checkpoint excerpt injected into prompts (see run-plan-checkpoint.sh).
  RALPH_CHECKPOINT_OUTPUT_FAIL_HEAD_BYTES    default 2048 -- UTF-8 cap for the first failure excerpt chunk.
  RALPH_CHECKPOINT_OUTPUT_FAIL_TAIL_BYTES    default 2048 -- UTF-8 cap for the last failure excerpt chunk.

Omitted record counts are written under checkpoint.json "rollover" (cumulative and last_write).

Argv (all strings except semantics noted):
 1 workspace_root
 2 session_dir (RALPH_SESSION_DIR)
 3 plan_path
 4 plan_key
 5 line_num
 6 todo_ordinal
 7 todo_hash
 8 iteration
 9 exit_code
10 direct_verification (0 or 1)
11 sentinel_present (0 or 1)
12 todo_text_file (path)
13 git_status_before_file (path)
14 git_status_after_file (path)
15 ledger_file (path, optional; empty string if none)
16 runtime_output_log_path (optional; full path to plan-runner output log)
17 invocation_output_excerpt_file (optional; raw tail from log, capped by RALPH_AGENT_OUTPUT_MAX_BYTES, then summarized for checkpoints)
18 verification_scope (optional: phase|todo|final)
19 verification_gate_name (optional)
20 verification_command (optional)
21 verification_declared (optional 1/0)
22 verification_deferred (optional 1/0)
23 verification_exit_code (optional)
24 verification_failed_command (optional)
25 declared_gate_results_json (optional; list of {gate_name, command, exit_code, elapsed_seconds, log_path})
26 record_kind (optional; empty or "declared_gate_tail" for post-invocation TODO-level gate batches)
"""

from __future__ import annotations

import importlib.util
import json
import os
import re
import sys
from datetime import datetime, timezone
from pathlib import Path


def _read_text(path: str) -> str:
    if not path or not os.path.isfile(path):
        return ""
    try:
        return Path(path).read_text(encoding="utf-8", errors="replace")
    except OSError:
        return ""


def _paths_from_git_status(text: str) -> list[str]:
    out: list[str] = []
    for raw in text.splitlines():
        line = raw.strip()
        if not line:
            continue
        parts = line.split(None, 1)
        if len(parts) < 2:
            continue
        pth = parts[1].strip()
        if " -> " in pth:
            pth = pth.split(" -> ", 1)[-1].strip()
        out.append(pth)
    return out


def _status_path_delta(before: str, after: str) -> list[str]:
    a = set(_paths_from_git_status(before))
    b = set(_paths_from_git_status(after))
    return sorted(a.symmetric_difference(b))


def _artifact_paths(paths: list[str]) -> list[str]:
    needle = ".ralph-workspace/artifacts"
    return [p for p in paths if needle in p.replace("\\", "/")]


def _load_ledger(path: str) -> dict:
    if not path or not os.path.isfile(path):
        return {}
    try:
        with open(path, encoding="utf-8") as fh:
            data = json.load(fh)
        return data if isinstance(data, dict) else {}
    except (OSError, json.JSONDecodeError):
        return {}


def _read_positive_int_env(key: str, default: int) -> int:
    raw = os.environ.get(key, "").strip()
    if not raw:
        return default
    try:
        v = int(raw)
        return v if v > 0 else default
    except ValueError:
        return default


def _split_checkpoint_md_sections(md: str) -> list[str]:
    """Split checkpoint.md on section headers (one completed-TODO record per section)."""
    md = md.replace("\r\n", "\n")
    if not md.strip():
        return []
    parts = re.split(r"(?m)^(?=## TODO line )", md)
    return [p for p in parts if p.strip()]


def _utf8_byte_len(s: str) -> int:
    return len(s.encode("utf-8"))


def _rollover_markdown_sections(
    existing_md: str,
    new_section: str,
    max_bytes: int,
) -> tuple[str, int]:
    """Keep newest sections first (drop oldest from the top) until total UTF-8 size <= max_bytes."""
    sections = _split_checkpoint_md_sections(existing_md)
    new_parts = _split_checkpoint_md_sections(new_section)
    combined = sections + new_parts
    if not combined:
        return "", 0
    omitted = 0
    total = sum(_utf8_byte_len(s) for s in combined)
    while total > max_bytes and len(combined) > 1:
        removed = combined.pop(0)
        total -= _utf8_byte_len(removed)
        omitted += 1
    return "".join(combined), omitted


def _rollover_json_entries(
    entries: list,
    max_entries: int,
) -> tuple[list, int]:
    """Keep the newest max_entries (tail)."""
    if not isinstance(entries, list):
        return [], 0
    if max_entries <= 0 or len(entries) <= max_entries:
        return list(entries), 0
    dropped = len(entries) - max_entries
    return entries[-max_entries:], dropped


def _rollover_jsonl_lines(
    path: Path,
    max_lines: int,
) -> int:
    """Trim jsonl to the last max_lines lines; return number of lines removed from the head."""
    if max_lines <= 0 or not path.is_file():
        return 0
    try:
        text = path.read_text(encoding="utf-8", errors="replace")
    except OSError:
        return 0
    lines = text.splitlines()
    if len(lines) <= max_lines:
        return 0
    dropped = len(lines) - max_lines
    kept = lines[-max_lines:]
    path.write_text("\n".join(kept) + ("\n" if kept else ""), encoding="utf-8")
    return dropped


def _merge_rollover_meta(
    doc: dict,
    *,
    json_dropped: int,
    md_sections_dropped: int,
    jsonl_dropped: int,
) -> None:
    prev = doc.get("rollover")
    prev = prev if isinstance(prev, dict) else {}
    cj = int(prev.get("json_entries_omitted_cumulative") or 0)
    cm = int(prev.get("markdown_sections_omitted_cumulative") or 0)
    cl = int(prev.get("jsonl_lines_omitted_cumulative") or 0)
    doc["rollover"] = {
        "json_entries_omitted_cumulative": cj + json_dropped,
        "markdown_sections_omitted_cumulative": cm + md_sections_dropped,
        "jsonl_lines_omitted_cumulative": cl + jsonl_dropped,
        "last_write": {
            "json_entries_dropped_this_write": json_dropped,
            "markdown_sections_dropped_this_write": md_sections_dropped,
            "jsonl_lines_dropped_this_write": jsonl_dropped,
        },
    }


_cos_mod = None  # cached summarize module, or False if import failed


def _get_command_output_summarize_mod():
    """Load command-output-summarize.py once; False means unavailable."""
    global _cos_mod
    if _cos_mod is False:
        return None
    if _cos_mod is not None:
        return _cos_mod
    path = Path(__file__).resolve().parent.parent / "python" / "command-output-summarize.py"
    if not path.is_file():
        _cos_mod = False
        return None
    spec = importlib.util.spec_from_file_location("_ralph_command_output_summarize", path)
    if spec is None or spec.loader is None:
        _cos_mod = False
        return None
    mod = importlib.util.module_from_spec(spec)
    try:
        spec.loader.exec_module(mod)
    except Exception:
        _cos_mod = False
        return None
    if not hasattr(mod, "summarize_for_pattern"):
        _cos_mod = False
        return None
    _cos_mod = mod
    return mod


_RE_INF_NPM_BUILD = re.compile(r"\bnpm\s+run\s+build\b", re.IGNORECASE)
_RE_INF_NPM_LINT = re.compile(r"\bnpm\s+run\s+lint\b", re.IGNORECASE)
_RE_INF_NPM_TEST = re.compile(r"\bnpm\s+test\b", re.IGNORECASE)


def _infer_summarize_pattern(label: str) -> str:
    if _RE_INF_NPM_BUILD.search(label):
        return "npm run build"
    if _RE_INF_NPM_LINT.search(label):
        return "npm run lint"
    if _RE_INF_NPM_TEST.search(label):
        return "npm test"
    return "command"


def _fallback_label_head_tail(label: str, head_n: int = 20, tail_n: int = 20) -> str:
    lines = label.splitlines()
    if not lines:
        return ""
    if len(lines) <= head_n + tail_n:
        return label
    head = lines[:head_n]
    tail = lines[-tail_n:]
    return "\n".join(head) + "\n...\n" + "\n".join(tail)


def _summarize_command_label_entry(label: str) -> str:
    """One checkpoint line per ledger command_label (same summarizer as ralph_summarize_command_output)."""
    s = str(label)
    if not s.strip():
        return ""
    mod = _get_command_output_summarize_mod()
    if mod is None:
        return _fallback_label_head_tail(s)
    try:
        raw = s.encode("utf-8", errors="replace")
        pat = _infer_summarize_pattern(s)
        obj = mod.summarize_for_pattern(pat, raw)
        return json.dumps(obj, ensure_ascii=False, separators=(",", ":"))
    except Exception:
        return _fallback_label_head_tail(s)


def _commands_tools(ledger: dict) -> dict:
    labels = ledger.get("command_labels")
    if not isinstance(labels, list):
        labels = []
    tc = ledger.get("tool_call_count", 0)
    try:
        tc = int(tc)
    except (TypeError, ValueError):
        tc = 0
    out: dict = {"command_labels": labels, "tool_call_count": tc}
    for key in (
        "raw_json_event_bytes",
        "assistant_text_bytes",
        "tool_event_bytes",
        "largest_json_event_bytes",
        "largest_tool_event_bytes",
    ):
        if key in ledger:
            try:
                out[key] = int(ledger[key])
            except (TypeError, ValueError):
                out[key] = ledger[key]
    return out


def _budget_utf8_tail_bytes(data: bytes, max_bytes: int) -> tuple[bytes, int, int]:
    """Return (tail_bytes, source_total_len, omitted_prefix_len)."""
    if max_bytes <= 0:
        return b"", 0, 0
    if not data:
        return b"", 0, 0
    total = len(data)
    if total <= max_bytes:
        return data, total, 0
    cut = data[-max_bytes:]
    return cut, total, total - max_bytes


def _utf8_head_bytes(text: str, max_bytes: int) -> str:
    if max_bytes <= 0 or not text:
        return ""
    raw = text.encode("utf-8")
    return raw[:max_bytes].decode("utf-8", errors="replace")


def _utf8_tail_bytes(text: str, max_bytes: int) -> str:
    if max_bytes <= 0 or not text:
        return ""
    raw = text.encode("utf-8")
    if len(raw) <= max_bytes:
        return text
    return raw[-max_bytes:].decode("utf-8", errors="replace")


def _truncate_utf8_bytes(text: str, max_bytes: int) -> str:
    if max_bytes <= 0:
        return ""
    raw = text.encode("utf-8")
    if len(raw) <= max_bytes:
        return text
    return raw[:max_bytes].decode("utf-8", errors="replace")


def _budget_tool_result_excerpt_utf8(data: bytes, max_bytes: int) -> tuple[str, int, int]:
    """Return (stored_text, source_total_utf8_bytes, omitted_middle_utf8_bytes).

    When data exceeds max_bytes, keep disjoint head and tail byte ranges with
    a --- omitted N bytes --- marker (same spirit as failure branches in
    _summarize_invocation_output_excerpt).
    """
    total = len(data)
    if max_bytes <= 0:
        return "", total, max(0, total)
    if total <= max_bytes:
        return data.decode("utf-8", errors="replace"), total, 0

    overhead = 72
    avail = max_bytes - overhead
    if avail < 64:
        avail = min(total, max(32, max_bytes - 40))
    fh = max(16, (avail * 3) // 5)
    ft = max(16, avail - fh - 24)
    head_b = b""
    tail_b = b""
    omitted = total
    marker_b = b""
    for _ in range(48):
        if fh + ft > total:
            fh = max(8, min(fh, total // 2))
            ft = max(8, min(ft, total - fh))
        head_b = data[:fh]
        tail_b = data[-ft:] if ft else b""
        omitted = total - len(head_b) - len(tail_b)
        if omitted < 0:
            omitted = 0
        marker_b = f"\n--- omitted {omitted} bytes ---\n".encode("utf-8")
        if len(head_b) + len(marker_b) + len(tail_b) <= max_bytes:
            break
        if fh >= ft and fh > 8:
            fh = max(8, fh - 24)
        elif ft > 8:
            ft = max(8, ft - 24)
        else:
            break

    out_b = head_b + marker_b + tail_b
    if len(out_b) > max_bytes:
        out_b = out_b[:max_bytes]
    stored = out_b.decode("utf-8", errors="replace")
    return stored, total, omitted


def _parse_tool_result_excerpt_entries(ledger: dict) -> list[tuple[str, str]]:
    """Return up to 200 (label, text) pairs from ledger['tool_result_excerpts']."""
    raw = ledger.get("tool_result_excerpts")
    if not isinstance(raw, list):
        return []
    out: list[tuple[str, str]] = []
    for item in raw[:200]:
        if isinstance(item, str):
            out.append(("", item))
            continue
        if isinstance(item, dict):
            text = item.get("excerpt")
            if text is None:
                text = item.get("text")
            if text is None:
                text = item.get("result")
            if not isinstance(text, str):
                text = str(text) if text is not None else ""
            lab = item.get("tool")
            if lab is None:
                lab = item.get("label")
            if lab is None:
                lab = item.get("name")
            lab_s = str(lab) if lab is not None else ""
            out.append((lab_s, text))
    return out


def _budget_tool_result_excerpts_for_feed(ledger: dict) -> list[dict]:
    cap = _read_positive_int_env("RALPH_TOOL_RESULT_MAX_BYTES", 32768)
    rows: list[dict] = []
    for label, text in _parse_tool_result_excerpt_entries(ledger):
        raw = (text or "").encode("utf-8", errors="replace")
        excerpt, src_len, omitted = _budget_tool_result_excerpt_utf8(raw, cap)
        row: dict = {
            "excerpt": excerpt,
            "source_utf8_bytes": src_len,
            "omitted_middle_utf8_bytes": omitted,
            "budget_max_utf8_bytes": cap,
        }
        if label.strip():
            row["label"] = label.strip()
        rows.append(row)
    return rows


def _summarize_invocation_output_excerpt(
    text: str,
    exit_code: int,
    summary_max: int,
    fail_head: int,
    fail_tail: int,
) -> str:
    """Turn raw captured log tail into a short checkpoint-safe summary (tests, builds, shell, search)."""
    trimmed = text.strip("\n") if text else ""
    if not trimmed:
        return "(empty)\n"

    tiny_inline = 480
    raw_len = len(trimmed.encode("utf-8"))
    if raw_len <= tiny_inline and summary_max >= raw_len:
        return trimmed if trimmed.endswith("\n") else trimmed + "\n"

    overhead = 420
    avail = max(160, summary_max - overhead)
    if exit_code != 0:
        fh = max(48, min(fail_head, (avail * 3) // 5))
        ft = max(48, min(fail_tail, avail - fh - 48))
        head = _utf8_head_bytes(trimmed, fh)
        tail = _utf8_tail_bytes(trimmed, ft)
        body = (
            f"Failure summary (exit {exit_code}): first and last UTF-8 excerpts from the captured segment "
            f"(~{raw_len} bytes before summarization). Full output stays in the log file only.\n"
            f"--- First excerpt ---\n{head}\n"
            f"--- Omitted middle ---\n"
            f"--- Last excerpt ---\n{tail}\n"
        )
    else:
        lines = trimmed.count("\n") + 1
        head_budget = max(80, min(320, summary_max - 200))
        head_snip = _utf8_head_bytes(trimmed, head_budget)
        body = (
            f"Success summary (exit 0): captured segment about {raw_len} UTF-8 bytes (~{lines} lines); "
            "full tests, builds, searches, and shell output are only in the log file.\n"
            f"Head preview:\n{head_snip}\n"
        )

    return _truncate_utf8_bytes(body, summary_max) + ("\n" if not body.endswith("\n") else "")


def _build_checkpoint_feed(
    ledger: dict,
    excerpt_path: str,
    output_log_path: str,
    exit_code: int,
) -> dict:
    out_max = _read_positive_int_env("RALPH_AGENT_OUTPUT_MAX_BYTES", 24000)
    tool_max = _read_positive_int_env("RALPH_AGENT_TOOL_EVENT_MAX_BYTES", 16000)
    summary_max = _read_positive_int_env("RALPH_CHECKPOINT_OUTPUT_SUMMARY_MAX_BYTES", 4096)
    fail_head = _read_positive_int_env("RALPH_CHECKPOINT_OUTPUT_FAIL_HEAD_BYTES", 2048)
    fail_tail = _read_positive_int_env("RALPH_CHECKPOINT_OUTPUT_FAIL_TAIL_BYTES", 2048)
    excerpt_raw_b = b""
    if excerpt_path and os.path.isfile(excerpt_path):
        try:
            excerpt_raw_b = Path(excerpt_path).read_bytes()
        except OSError:
            excerpt_raw_b = b""
    excerpt_b, src_len, omit_pre = _budget_utf8_tail_bytes(excerpt_raw_b, out_max)
    raw_tail_text = excerpt_b.decode("utf-8", errors="replace")
    summary_text = _summarize_invocation_output_excerpt(
        raw_tail_text,
        exit_code,
        summary_max,
        fail_head,
        fail_tail,
    )
    summary_b = summary_text.encode("utf-8")
    labels = ledger.get("command_labels")
    if not isinstance(labels, list):
        labels = []
    joined = "; ".join(str(x) for x in labels)
    joined_b = joined.encode("utf-8")
    lab_total = len(joined_b)
    summarized_chunks = [_summarize_command_label_entry(str(x)) for x in labels]
    inner = "\n".join(c for c in summarized_chunks if c)
    if not inner:
        inner = joined
    inner_b = inner.encode("utf-8")
    lab_b, _inner_src, lab_omit = _budget_utf8_tail_bytes(inner_b, tool_max)
    lab_text = lab_b.decode("utf-8", errors="replace")
    lm = _commands_tools(ledger)
    tool_result_rows = _budget_tool_result_excerpts_for_feed(ledger)
    if tool_result_rows:
        lm = {**lm, "tool_result_excerpts": tool_result_rows}
    return {
        "runtime_output_log_path": output_log_path or "",
        "runtime_exit_code": exit_code,
        "runtime_output_excerpt": summary_text,
        "runtime_output_excerpt_utf8_bytes": len(summary_b),
        "runtime_output_raw_tail_utf8_bytes": len(excerpt_b),
        "runtime_output_segment_utf8_bytes": src_len,
        "runtime_output_excerpt_omitted_prefix_bytes": omit_pre,
        "runtime_output_summary_max_bytes": summary_max,
        "tool_labels_text": lab_text,
        "tool_labels_budgeted_utf8_bytes": len(lab_b),
        "tool_labels_source_utf8_bytes": lab_total,
        "tool_labels_omitted_prefix_bytes": lab_omit,
        "tool_result_excerpt_budget_max_utf8_bytes": _read_positive_int_env(
            "RALPH_TOOL_RESULT_MAX_BYTES", 32768
        ),
        "ledger_metrics": lm,
    }


def _load_gate_results_json(path: str) -> list[dict]:
    if not path or not os.path.isfile(path):
        return []
    try:
        raw = json.loads(Path(path).read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError, TypeError):
        return []
    if isinstance(raw, list):
        return [x for x in raw if isinstance(x, dict)]
    return []


def _compact_declared_gate_run_summaries(runs: list[dict]) -> list[dict]:
    """Budget each gate log like invocation output (tail cap + summary cap)."""
    out_max = _read_positive_int_env("RALPH_AGENT_OUTPUT_MAX_BYTES", 24000)
    summary_max = _read_positive_int_env("RALPH_CHECKPOINT_OUTPUT_SUMMARY_MAX_BYTES", 4096)
    fail_head = _read_positive_int_env("RALPH_CHECKPOINT_OUTPUT_FAIL_HEAD_BYTES", 2048)
    fail_tail = _read_positive_int_env("RALPH_CHECKPOINT_OUTPUT_FAIL_TAIL_BYTES", 2048)
    out: list[dict] = []
    for r in runs:
        name = str(r.get("gate_name") or "")
        cmd = str(r.get("command") or "")
        try:
            g_exit = int(r.get("exit_code", 0))
        except (TypeError, ValueError):
            g_exit = 0
        try:
            elapsed = int(r.get("elapsed_seconds", 0))
        except (TypeError, ValueError):
            elapsed = 0
        log_path = str(r.get("log_path") or "")
        excerpt_raw_b = b""
        if log_path and os.path.isfile(log_path):
            try:
                excerpt_raw_b = Path(log_path).read_bytes()
            except OSError:
                excerpt_raw_b = b""
        excerpt_b, src_len, omit_pre = _budget_utf8_tail_bytes(excerpt_raw_b, out_max)
        raw_tail_text = excerpt_b.decode("utf-8", errors="replace")
        summary_text = _summarize_invocation_output_excerpt(
            raw_tail_text,
            g_exit,
            summary_max,
            fail_head,
            fail_tail,
        )
        summary_st = summary_text.strip()
        out.append(
            {
                "gate_name": name,
                "command": cmd,
                "exit_code": g_exit,
                "elapsed_seconds": elapsed,
                "log_path": log_path,
                "output_summary": summary_st,
                "output_raw_tail_utf8_bytes": len(excerpt_b),
                "output_summary_utf8_bytes": len(summary_st.encode("utf-8")),
                "output_segment_utf8_bytes": src_len,
                "output_tail_omitted_prefix_utf8_bytes": omit_pre,
            }
        )
    return out


def _append_declared_gate_run_markdown(md_lines: list[str], summaries: list[dict], *, max_summary_lines: int = 32) -> None:
    if not summaries:
        return
    md_lines.extend(["", "### Declared verification gate runs", ""])
    for g in summaries:
        gname = g.get("gate_name") or "(unnamed)"
        md_lines.append(f"- Gate `{gname}` exit={g.get('exit_code')} elapsed={g.get('elapsed_seconds')}s")
        lp = g.get("log_path") or ""
        if lp:
            md_lines.append(f"  - Log path: `{lp}`")
        cmd = str(g.get("command") or "")
        if cmd:
            md_lines.append(f"  - Command: `{cmd}`")
        summ = str(g.get("output_summary") or "").strip()
        if summ:
            su_lines = summ.splitlines() or ["(empty)"]
            for sl in su_lines[:max_summary_lines]:
                md_lines.append(f"    {sl}")
            if len(su_lines) > max_summary_lines:
                md_lines.append("    ...")


def main(argv: list[str]) -> int:
    if len(argv) < 15:
        print("run-plan-checkpoint-persist: missing argv", file=sys.stderr)
        return 2
    _workspace = argv[1]
    session_dir = Path(argv[2])
    plan_path = argv[3]
    plan_key = argv[4]
    line_num = int(argv[5])
    todo_ordinal = int(argv[6])
    todo_hash = argv[7]
    iteration = int(argv[8])
    exit_code = int(argv[9])
    direct_verification = argv[10] == "1"
    sentinel_present = argv[11] == "1"
    todo_text = _read_text(argv[12])
    git_before = _read_text(argv[13])
    git_after = _read_text(argv[14])
    ledger_path = argv[15] if len(argv) > 15 else ""
    output_log_path = argv[16] if len(argv) > 16 else ""
    excerpt_path = argv[17] if len(argv) > 17 else ""
    verification_scope = argv[18] if len(argv) > 18 else ""
    verification_gate_name = argv[19] if len(argv) > 19 else ""
    verification_command = argv[20] if len(argv) > 20 else ""
    verification_declared = argv[21] if len(argv) > 21 else ""
    verification_deferred = argv[22] if len(argv) > 22 else ""
    verification_exit_code = argv[23] if len(argv) > 23 else ""
    verification_failed_command = argv[24] if len(argv) > 24 else ""
    gate_results_path = argv[25] if len(argv) > 25 else ""
    record_kind = (argv[26] if len(argv) > 26 else "").strip()
    ledger = _load_ledger(ledger_path)

    session_dir.mkdir(parents=True, exist_ok=True)
    completed_at = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    paths_changed = _status_path_delta(git_before, git_after)
    artifacts = _artifact_paths(paths_changed)
    risks = os.environ.get("RALPH_CHECKPOINT_OPEN_RISKS", "").strip() or None

    summary = todo_text.strip()
    if len(summary) > 500:
        summary = summary[:497] + "..."

    gate_summaries = _compact_declared_gate_run_summaries(_load_gate_results_json(gate_results_path))

    feed = _build_checkpoint_feed(ledger, excerpt_path, output_log_path, exit_code)
    ct = _commands_tools(ledger)
    ct_compact = {**ct, "command_labels": []}

    jrecord = {
        "schema_version": 1,
        "kind": "invocation_context_ledger",
        "completed_at": completed_at,
        "plan_key": plan_key,
        "plan_path": plan_path,
        "workspace": _workspace,
        "todo": {
            "line": line_num,
            "ordinal": todo_ordinal,
            "hash": todo_hash,
            "summary": summary,
        },
        "git": {
            "status_before": git_before,
            "status_after": git_after,
            "paths_changed": paths_changed,
        },
        "commands_tools_observed": ct_compact,
        "checkpoint_feed": feed,
        "verification": {
            "exit_code": exit_code,
            "todo_marked_completed": True,
            "completion_sentinel_present": sentinel_present,
            "direct_verification": direct_verification,
        },
        "artifacts": artifacts,
        "open_risks": risks,
    }
    if verification_scope:
        jrecord["verification"].update(
            {
                "scope": verification_scope,
                "gate_name": verification_gate_name or None,
                "command": verification_command or None,
                "declared": verification_declared == "1",
                "deferred": verification_deferred == "1",
            }
        )
        if verification_exit_code:
            try:
                jrecord["verification"]["verification_exit_code"] = int(verification_exit_code)
            except ValueError:
                jrecord["verification"]["verification_exit_code"] = verification_exit_code
        if verification_failed_command:
            jrecord["verification"]["failed_command"] = verification_failed_command

    if gate_summaries:
        jrecord["verification"]["declared_gate_runs"] = gate_summaries
    if record_kind:
        jrecord["record_kind"] = record_kind

    jsonl_path = session_dir / "invocation-context-ledger.jsonl"
    max_ledger_lines = _read_positive_int_env("RALPH_CHECKPOINT_ROLLOVER_MAX_LEDGER_LINES", 2000)
    with open(jsonl_path, "a", encoding="utf-8") as jfh:
        jfh.write(json.dumps(jrecord, separators=(",", ":"), ensure_ascii=False) + "\n")
    jsonl_dropped = _rollover_jsonl_lines(jsonl_path, max_ledger_lines)

    entry_for_checkpoint = {
        "completed_at": completed_at,
        "todo_line": line_num,
        "todo_ordinal": todo_ordinal,
        "todo_hash": todo_hash,
        "iteration": iteration,
        "exit_code": exit_code,
        "direct_verification": direct_verification,
        "sentinel_present": sentinel_present,
        "paths_changed": paths_changed,
        "commands_tools_observed": ct_compact,
        "checkpoint_feed": feed,
        "verification": jrecord["verification"],
        "artifacts": artifacts,
        "open_risks": risks,
    }
    if record_kind:
        entry_for_checkpoint["record_kind"] = record_kind

    max_json_entries = _read_positive_int_env("RALPH_CHECKPOINT_ROLLOVER_MAX_JSON_ENTRIES", 200)
    max_md_bytes = _read_positive_int_env("RALPH_CHECKPOINT_ROLLOVER_MAX_MD_BYTES", 65536)

    cp_json = session_dir / "checkpoint.json"
    doc: dict = {
        "schema_version": 1,
        "kind": "ralph_checkpoint",
        "plan_key": plan_key,
        "plan_path": plan_path,
        "entries": [],
    }
    if cp_json.is_file():
        try:
            prev = json.loads(cp_json.read_text(encoding="utf-8"))
            if isinstance(prev, dict) and isinstance(prev.get("entries"), list):
                doc = prev
        except (OSError, json.JSONDecodeError):
            pass
    entries = doc.get("entries")
    if not isinstance(entries, list):
        entries = []
    entries.append(entry_for_checkpoint)
    rolled_entries, json_dropped = _rollover_json_entries(entries, max_json_entries)
    doc["entries"] = rolled_entries
    doc["plan_key"] = plan_key
    doc["plan_path"] = plan_path

    cp_md = session_dir / "checkpoint.md"
    cm = feed["ledger_metrics"]
    tool_result_cap = feed.get("tool_result_excerpt_budget_max_utf8_bytes") or _read_positive_int_env(
        "RALPH_TOOL_RESULT_MAX_BYTES", 32768
    )
    excerpt_lines = feed["runtime_output_excerpt"].splitlines() if feed["runtime_output_excerpt"] else []
    if not excerpt_lines:
        excerpt_lines = ["(empty)"]
    excerpt_indented = "\n".join(("    " + ln) for ln in excerpt_lines)
    log_disp = feed["runtime_output_log_path"] or "(not provided)"
    out_cap = _read_positive_int_env("RALPH_AGENT_OUTPUT_MAX_BYTES", 24000)
    tool_cap = _read_positive_int_env("RALPH_AGENT_TOOL_EVENT_MAX_BYTES", 16000)
    md_lines: list[str] = []
    if record_kind == "declared_gate_tail":
        md_lines = [
            f"## Declared verification gate batch (TODO line {line_num} ordinal {todo_ordinal}) {completed_at}",
            "",
            f"- Hash: `{todo_hash}`",
            f"- Iteration: {iteration}",
            f"- Direct verification: {direct_verification}",
            f"- Completion sentinel in output segment: {sentinel_present}",
            f"- Plan runner log: `{output_log_path or '(not provided)'}`",
            "",
            "### Paths changed (from git status before/after)",
            "",
        ]
        if paths_changed:
            md_lines.extend(f"- `{p}`" for p in paths_changed)
        else:
            md_lines.append("- (none detected)")
        if verification_scope:
            verification_exit_display = verification_exit_code if verification_exit_code else str(exit_code)
            verification_status = "passed" if str(verification_exit_display) == "0" else "failed"
            md_lines.extend(
                [
                    "",
                    "### Verification gate (aggregate)",
                    "",
                    f"- Scope: {verification_scope}",
                    f"- Gate: `{verification_gate_name}`" if verification_gate_name else "- Gate: (unspecified)",
                    f"- Command: `{verification_command}`" if verification_command else "- Command: (unspecified)",
                    f"- Declared: {verification_declared == '1'}",
                    f"- Deferred: {verification_deferred == '1'}",
                    f"- Exit code: {verification_exit_display}",
                    f"- Status: {verification_status}",
                ]
            )
            if verification_failed_command:
                md_lines.append(f"- Failed command: `{verification_failed_command}`")
        _append_declared_gate_run_markdown(md_lines, gate_summaries)
        if risks:
            md_lines.extend(["", "### Open risks", "", risks, ""])
        md_lines.extend(["", "### TODO summary", "", summary, ""])
    else:
        md_lines = [
            f"## TODO line {line_num} (ordinal {todo_ordinal}) completed {completed_at}",
            "",
            f"- Hash: `{todo_hash}`",
            f"- Iteration: {iteration}",
            f"- Exit code: {exit_code}",
            f"- Direct verification: {direct_verification}",
            f"- Completion sentinel in output segment: {sentinel_present}",
            "",
            "### Paths changed (from git status before/after)",
            "",
        ]
        if paths_changed:
            md_lines.extend(f"- `{p}`" for p in paths_changed)
        else:
            md_lines.append("- (none detected)")
        md_lines.extend(
            [
                "",
                "### Invocation output (summarized for checkpoint; full stream in log file only)",
                "",
                f"- Log path: `{log_disp}`",
                f"- Runtime exit code: {exit_code}",
                f"- Raw tail segment UTF-8 bytes (from log capture cap): {feed['runtime_output_raw_tail_utf8_bytes']}",
                f"- Checkpoint summary UTF-8 bytes: {feed['runtime_output_excerpt_utf8_bytes']}",
                f"- RALPH_CHECKPOINT_OUTPUT_SUMMARY_MAX_BYTES cap: {feed['runtime_output_summary_max_bytes']}",
                f"- Capture tail omitted prefix UTF-8 bytes: {feed['runtime_output_excerpt_omitted_prefix_bytes']}",
                f"- RALPH_AGENT_OUTPUT_MAX_BYTES capture cap: {out_cap}",
                "",
                excerpt_indented,
                "",
                "### Tool and ledger metrics (command labels budgeted)",
                "",
                f"- tool_call_count: {cm.get('tool_call_count', 0)}",
            ]
        )
        if verification_scope:
            verification_exit_display = verification_exit_code if verification_exit_code else str(exit_code)
            verification_status = "passed" if str(verification_exit_display) == "0" else "failed"
            md_lines.extend(
                [
                    "",
                    "### Verification gate",
                    "",
                    f"- Scope: {verification_scope}",
                    f"- Gate: `{verification_gate_name}`" if verification_gate_name else "- Gate: (unspecified)",
                    f"- Command: `{verification_command}`" if verification_command else "- Command: (unspecified)",
                    f"- Declared: {verification_declared == '1'}",
                    f"- Deferred: {verification_deferred == '1'}",
                    f"- Exit code: {verification_exit_display}",
                    f"- Status: {verification_status}",
                ]
            )
            if verification_failed_command:
                md_lines.append(f"- Failed command: `{verification_failed_command}`")
        _append_declared_gate_run_markdown(md_lines, gate_summaries)
        for k in (
            "raw_json_event_bytes",
            "assistant_text_bytes",
            "tool_event_bytes",
            "largest_json_event_bytes",
            "largest_tool_event_bytes",
        ):
            if k in cm:
                md_lines.append(f"- {k}: {cm[k]}")
        md_lines.extend(
            [
                f"- tool_labels (UTF-8 budget {tool_cap}): {feed['tool_labels_text']!r}",
                f"- tool_labels_source_utf8_bytes: {feed['tool_labels_source_utf8_bytes']}",
                f"- tool_labels_omitted_prefix_utf8_bytes: {feed['tool_labels_omitted_prefix_bytes']}",
                "",
            ]
        )
        tre = cm.get("tool_result_excerpts") if isinstance(cm, dict) else None
        if isinstance(tre, list) and tre:
            md_lines.extend(
                [
                    "### Tool result excerpts (budgeted; RALPH_TOOL_RESULT_MAX_BYTES)",
                    "",
                    f"- Per-excerpt UTF-8 cap: {tool_result_cap}",
                    "",
                ]
            )
            for idx, row in enumerate(tre):
                if not isinstance(row, dict):
                    continue
                label = row.get("label")
                src_b = row.get("source_utf8_bytes")
                omit_m = row.get("omitted_middle_utf8_bytes")
                ex = str(row.get("excerpt") or "")
                head = f"- [{idx}]"
                if isinstance(label, str) and label.strip():
                    head += f" tool={label.strip()!r}"
                md_lines.append(f"{head} source_utf8_bytes={src_b} omitted_middle_utf8_bytes={omit_m}")
                for ln in ex.splitlines() or ["(empty)"]:
                    md_lines.append(f"    {ln}")
            md_lines.append("")
        md_lines.extend(
            [
                "### Artifacts (paths under .ralph-workspace/artifacts if any)",
                "",
            ]
        )
        if artifacts:
            md_lines.extend(f"- `{p}`" for p in artifacts)
        else:
            md_lines.append("- (none detected)")
        if risks:
            md_lines.extend(["", "### Open risks", "", risks, ""])
        md_lines.extend(["", "### TODO summary", "", summary, ""])
    new_section = "\n".join(md_lines) + "\n"
    existing_md = _read_text(str(cp_md))
    combined_md, md_sections_dropped = _rollover_markdown_sections(existing_md, new_section, max_md_bytes)
    cp_md.write_text(combined_md, encoding="utf-8")

    _merge_rollover_meta(
        doc,
        json_dropped=json_dropped,
        md_sections_dropped=md_sections_dropped,
        jsonl_dropped=jsonl_dropped,
    )
    cp_json.write_text(json.dumps(doc, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")

    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
