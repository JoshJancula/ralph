import importlib.util
import json
import os
import sys
from datetime import datetime, timezone
from typing import Mapping, Optional

from tool_call_classification import ACCOUNTING_KEYS

_overlay_fields_module = None


def _load_overlay_fields_module():
    global _overlay_fields_module
    if _overlay_fields_module is not None:
        return _overlay_fields_module
    helper = ""
    if len(sys.argv) > 33:
        helper = sys.argv[33].strip()
    if not helper or not os.path.isfile(helper):
        return None
    spec = importlib.util.spec_from_file_location("ralph_overlay_usage_fields", helper)
    if spec is None or spec.loader is None:
        return None
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    _overlay_fields_module = module
    return module


_PROXY_READ_TOOL_NAMES = {"ralph_proxy_read", "resources/read"}


def _parse_iso_timestamp(value: str) -> Optional[datetime]:
    text = (value or "").strip()
    if not text:
        return None
    if text.endswith("Z"):
        text = text[:-1] + "+00:00"
    try:
        return datetime.fromisoformat(text)
    except ValueError:
        return None


def _resolve_plan_key(plan_key: str) -> str:
    candidate = plan_key.strip()
    if candidate:
        return candidate
    for env_key in ("RALPH_PLAN_KEY", "RALPH_ARTIFACT_NS"):
        env_value = os.environ.get(env_key, "").strip()
        if env_value:
            return env_value
    return ""


def _env_truthy(text: str) -> bool:
    v = (text or "").strip().lower()
    return v in ("1", "true", "yes", "on")


def _collect_proxy_read_bytes(
    plan_key: str, started_at: str, ended_at: str
) -> Optional[int]:
    start = _parse_iso_timestamp(started_at)
    end = _parse_iso_timestamp(ended_at)
    if not start or not end:
        return None
    if end < start:
        start, end = end, start
    workspace_root = os.environ.get("RALPH_PLAN_WORKSPACE_ROOT", "").strip()
    plan_key = _resolve_plan_key(plan_key)
    if not workspace_root or not plan_key:
        return None
    index_path = os.path.join(
        workspace_root, "tool-results", plan_key, "index.jsonl"
    )
    if not os.path.isfile(index_path):
        return None
    total = 0
    matched = False
    try:
        with open(index_path, "r", encoding="utf-8") as fh:
            for line in fh:
                entry = line.strip()
                if not entry:
                    continue
                try:
                    doc = json.loads(entry)
                except json.JSONDecodeError:
                    continue
                tool = str(doc.get("tool") or "").strip()
                if tool not in _PROXY_READ_TOOL_NAMES:
                    continue
                stored_at = str(doc.get("storedAt") or "").strip()
                stored_dt = _parse_iso_timestamp(stored_at)
                if not stored_dt:
                    continue
                if stored_dt < start or stored_dt > end:
                    continue
                matched = True
                metadata = doc.get("metadata") or {}
                byte_count = None
                if isinstance(metadata, Mapping):
                    window = metadata.get("window")
                    if isinstance(window, Mapping):
                        byte_count = window.get("byteCount")
                if isinstance(byte_count, (int, float)):
                    total += int(byte_count)
                else:
                    raw_bytes = doc.get("bytes")
                    if isinstance(raw_bytes, (int, float)):
                        total += int(raw_bytes)
    except OSError:
        return None
    if not matched:
        return None
    return total

path = sys.argv[1]
iteration = int(sys.argv[2])
model = sys.argv[3]
runtime = sys.argv[4]
elapsed_seconds = int(sys.argv[5])
input_tokens = int(sys.argv[6])
output_tokens = int(sys.argv[7])
cache_creation_input_tokens = int(sys.argv[8])
cache_read_input_tokens = int(sys.argv[9])
max_turn_total_tokens = int(sys.argv[10])
try:
    cache_hit_ratio = float(sys.argv[11])
except (ValueError, IndexError):
    cache_hit_ratio = 0.0

opencode_cache_key_injected = False
if runtime == "opencode":
    opencode_cache_key_injected = _env_truthy(
        os.environ.get("RALPH_OPENCODE_PROMPT_CACHE_KEY_INJECTED", "")
    )
started_at = sys.argv[12] if len(sys.argv) > 12 else ""
ended_at = sys.argv[13] if len(sys.argv) > 13 else ""
plan_key = sys.argv[14] if len(sys.argv) > 14 else ""
stage_id = sys.argv[15] if len(sys.argv) > 15 else ""
session_strategy = sys.argv[16] if len(sys.argv) > 16 else ""
todo_line = sys.argv[17] if len(sys.argv) > 17 else ""
todo_ordinal = sys.argv[18] if len(sys.argv) > 18 else ""
todo_completed = sys.argv[19] if len(sys.argv) > 19 else ""
todo_class = sys.argv[20] if len(sys.argv) > 20 else ""
todo_hash = sys.argv[21] if len(sys.argv) > 21 else ""
validation_failed = sys.argv[22] if len(sys.argv) > 22 else ""
override_used = sys.argv[23] if len(sys.argv) > 23 else ""
prompt_bytes = sys.argv[24] if len(sys.argv) > 24 else "0"
todo_bytes = sys.argv[25] if len(sys.argv) > 25 else "0"
todo_continuation_lines = sys.argv[26] if len(sys.argv) > 26 else "0"
split_parent_id = sys.argv[27] if len(sys.argv) > 27 else ""
direct_verification = sys.argv[28] if len(sys.argv) > 28 else ""
rate_limit_status = sys.argv[29] if len(sys.argv) > 29 else ""
tool_turns = sys.argv[30] if len(sys.argv) > 30 else "0"
merge_path = sys.argv[31] if len(sys.argv) > 31 else ""
overlay_summary_path = sys.argv[32] if len(sys.argv) > 32 else ""
record = {
    "iteration": iteration,
    "model": model,
    "runtime": runtime,
    "session_strategy": session_strategy or "fresh",
    "elapsed_seconds": elapsed_seconds,
    "input_tokens": input_tokens,
    "output_tokens": output_tokens,
    "cache_creation_input_tokens": cache_creation_input_tokens,
    "cache_read_input_tokens": cache_read_input_tokens,
    "max_turn_total_tokens": max_turn_total_tokens,
    "cache_hit_ratio": round(cache_hit_ratio, 4),
    # Opencode-specific gate: provider stable cache-key injection, even when
    # cache_read_input_tokens=0 (unreported by provider).
    "opencode_cache_key_injected": opencode_cache_key_injected,
    }

for key in ACCOUNTING_KEYS:
    record[key] = 0

for key, value in (
    ("started_at", started_at),
    ("ended_at", ended_at),
    ("plan_key", plan_key),
    ("stage_id", stage_id),
    ("todo_line", todo_line),
    ("todo_ordinal", todo_ordinal),
):
    if value:
        if key in ("todo_line", "todo_ordinal"):
            try:
                record[key] = int(value)
            except ValueError:
                record[key] = value
        else:
            record[key] = value

if todo_completed:
    record["todo_completed"] = todo_completed == "1"
if todo_class:
    record["todo_risk_class"] = todo_class
if todo_hash:
    record["todo_hash"] = todo_hash
if validation_failed:
    record["todo_validation_failed"] = validation_failed == "1"
if override_used:
    record["completion_override_used"] = override_used == "1"
for key, value in (
    ("prompt_bytes", prompt_bytes),
    ("todo_bytes", todo_bytes),
    ("todo_continuation_lines", todo_continuation_lines),
    ("tool_turns", tool_turns),
):
    try:
        record[key] = int(value or 0)
    except ValueError:
        record[key] = 0

if merge_path.strip():
    try:
        mp = merge_path.strip()
        if os.path.isfile(mp):
            with open(mp, "r", encoding="utf-8") as mfh:
                mu = json.load(mfh)
            if isinstance(mu, dict):
                raw_tc = mu.get("tool_calls_total")
                if raw_tc is not None:
                    try:
                        record["tool_calls_total"] = int(raw_tc)
                    except (TypeError, ValueError):
                        record["tool_calls_total"] = 0
                bt = mu.get("tool_calls_by_tool")
                if isinstance(bt, dict):
                    record["tool_calls_by_tool"] = bt
                sq = mu.get("tool_calls_sequence")
                if isinstance(sq, list):
                    record["tool_calls_sequence"] = sq
                for counter_key in ACCOUNTING_KEYS:
                    counter_value = mu.get(counter_key)
                    if counter_value is not None:
                        try:
                            record[counter_key] = int(counter_value)
                        except (TypeError, ValueError):
                            record[counter_key] = 0
                if isinstance(bt, dict) and bt:
                    from tool_call_classification import classify_tool_calls

                    classified = classify_tool_calls(bt)
                    for counter_key in ACCOUNTING_KEYS:
                        record[counter_key] = classified.get(counter_key, 0)
    except Exception:
        pass
if split_parent_id:
    record["split_parent_id"] = split_parent_id
if direct_verification:
    record["direct_verification"] = direct_verification == "1"
if rate_limit_status:
    record["rate_limit_status"] = rate_limit_status

overlay_module = _load_overlay_fields_module()
if overlay_module is not None:
    overlay_module.merge_overlay_fields(record, overlay_summary_path.strip())
else:
    record.update(
        {
            "native_hooks_effective": False,
            "native_hook_events": 0,
            "hook_compactions": 0,
            "hook_rewrites": 0,
            "hook_original_bytes": 0,
            "hook_compacted_bytes": 0,
            "mcp_effective": False,
            "runtime_overlay_mode": "",
            "runtime_overlay_warnings": [],
        }
    )

proxy_bytes = _collect_proxy_read_bytes(plan_key, started_at, ended_at)
if proxy_bytes is not None:
    record["proxy_read_bytes"] = proxy_bytes

doc = {
    "schema_version": 1,
    "kind": "plan_invocation_usage_history",
    "updated_at": datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"),
    "invocations": [],
    }

if os.path.exists(path):
    try:
        with open(path, "r", encoding="utf-8") as fh:
            existing = json.load(fh)
        if isinstance(existing, dict) and isinstance(existing.get("invocations"), list):
            doc = existing
    except Exception:
        pass

doc["updated_at"] = datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")
inv = doc.setdefault("invocations", [])
inv.append(record)

tmp = f"{path}.tmp.{os.getpid()}"
with open(tmp, "w", encoding="utf-8") as fh:
    json.dump(doc, fh)
    fh.write("\n")
os.replace(tmp, path)
