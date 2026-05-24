#!/usr/bin/env python3
"""Read newline-delimited JSON from stdin; print human-readable text lines; write first session id to file.

Argv: <mode> <session_id_file> [<usage_file>]
mode: claude | cursor | codex | opencode
usage_file: optional path; written with JSON token usage summary at EOF
"""
import json
import os
import sys
from typing import Any, Dict, List, Optional

_TOOL_SEQUENCE_CAP = 50000

# Codex NDJSON: chat-like item types on item.completed (not tool invocations).
_CODEX_CHAT_ITEM_TYPES = frozenset(
    {
        "agent_message",
        "user_message",
        "system_message",
        "reasoning",
        "thread_summary",
        "summary",
    }
)


def _tool_call_id(item: Dict[str, Any]) -> Optional[str]:
    for key in ("callID", "callId", "call_id", "tool_call_id", "toolCallId", "id"):
        v = item.get(key)
        if isinstance(v, (str, int)) and str(v).strip():
            return str(v).strip()
    return None


def _merge_tool_call(acc: Dict[str, Any], name: str, call_id: Optional[str] = None) -> None:
    if call_id:
        seen = acc.setdefault("_tool_call_ids_seen", set())
        if isinstance(seen, set):
            if call_id in seen:
                return
            seen.add(call_id)
    label = (name or "unknown").strip() or "unknown"
    acc["tool_calls_total"] = int(acc.get("tool_calls_total", 0)) + 1
    by_tool = acc.setdefault("tool_calls_by_tool", {})
    if not isinstance(by_tool, dict):
        by_tool = {}
        acc["tool_calls_by_tool"] = by_tool
    by_tool[label] = int(by_tool.get(label, 0)) + 1
    seq = acc.setdefault("tool_calls_sequence", [])
    if isinstance(seq, list) and len(seq) < _TOOL_SEQUENCE_CAP:
        seq.append(label)


def _codex_item_tool_name(item: Dict[str, Any]) -> Optional[str]:
    """If item is a tool invocation, return a display name; else None."""
    itype = str(item.get("type") or "").strip()
    il = itype.lower()
    if il in _CODEX_CHAT_ITEM_TYPES:
        return None
    if il in (
        "tool_use",
        "function_call",
        "custom_tool",
        "command_execution",
        "shell_command",
        "exec",
        "mcp_tool",
        "mcp_tool_use",
    ):
        return _pick_tool_label(item, fallback=itype)
    tu = item.get("tool_use")
    if isinstance(tu, dict):
        return _pick_tool_label(tu, fallback="tool_use")
    fc = item.get("function_call")
    if isinstance(fc, dict):
        return _pick_tool_label(fc, fallback="function_call")
    if item.get("command") is not None or item.get("argv") is not None:
        return "shell"
    return None


def _pick_tool_label(item: Dict[str, Any], fallback: str) -> str:
    for key in ("name", "tool_name", "toolName", "tool"):
        v = item.get(key)
        if isinstance(v, str) and v.strip():
            return v.strip()
    fn = item.get("function")
    if isinstance(fn, dict):
        v = fn.get("name")
        if isinstance(v, str) and v.strip():
            return v.strip()
    return (fallback or "unknown").strip() or "unknown"


def _walk_claude_tool_uses(obj: Any, acc: Dict[str, Any]) -> None:
    if isinstance(obj, dict):
        if obj.get("type") == "tool_use":
            _merge_tool_call(acc, _pick_tool_label(obj, fallback="tool_use"), _tool_call_id(obj))
        for v in obj.values():
            _walk_claude_tool_uses(v, acc)
    elif isinstance(obj, list):
        for i in obj:
            _walk_claude_tool_uses(i, acc)


def _walk_generic_tool_calls(obj: Any, acc: Dict[str, Any], *, _depth: int = 0) -> None:
    """Cursor / unknown JSON: common stream tool call shapes, plus shallow recursion."""
    if _depth > 24:
        return
    if isinstance(obj, dict):
        tc = obj.get("tool_calls")
        if not isinstance(tc, list):
            tc = obj.get("toolCalls")
        if isinstance(tc, list):
            for entry in tc:
                if not isinstance(entry, dict):
                    continue
                _merge_tool_call(acc, _pick_tool_label(entry, fallback="tool_call"), _tool_call_id(entry))

        for key in ("tool_call", "toolCall", "function_call", "functionCall"):
            entry = obj.get(key)
            if isinstance(entry, dict):
                _merge_tool_call(acc, _pick_tool_label(entry, fallback=key), _tool_call_id(entry))

        typ = str(obj.get("type") or "").strip()
        typ_l = typ.lower().replace("-", "_")
        if typ_l in {"tool_call", "tool_use", "function_call"}:
            _merge_tool_call(acc, _pick_tool_label(obj, fallback=typ), _tool_call_id(obj))

        for k, v in obj.items():
            if k in {"tool_calls", "toolCalls", "tool_call", "toolCall", "function_call", "functionCall"}:
                continue
            _walk_generic_tool_calls(v, acc, _depth=_depth + 1)
    elif isinstance(obj, list):
        for i in obj:
            _walk_generic_tool_calls(i, acc, _depth=_depth + 1)


def extract_tool_calls(obj: Any, mode: str, acc: Dict[str, Any]) -> None:
    """Count tool invocations and optional per-tool breakdown (best-effort per runtime)."""
    if not isinstance(obj, dict):
        return
    if mode == "codex":
        if obj.get("type") == "item.completed":
            item = obj.get("item")
            if isinstance(item, dict):
                label = _codex_item_tool_name(item)
                if label:
                    _merge_tool_call(acc, label, _tool_call_id(item))
        return
    if mode == "opencode":
        _walk_opencode_tool_parts(obj, acc)
        return
    if mode == "claude":
        _walk_claude_tool_uses(obj, acc)
        return
    _walk_generic_tool_calls(obj, acc)


def _walk_opencode_tool_parts(obj: Any, acc: Dict[str, Any], *, _depth: int = 0) -> None:
    if _depth > 24:
        return
    if isinstance(obj, dict):
        part = obj.get("part")
        if isinstance(part, dict):
            _walk_opencode_tool_parts(part, acc, _depth=_depth + 1)

        props = obj.get("properties")
        if isinstance(props, dict):
            _walk_opencode_tool_parts(props, acc, _depth=_depth + 1)

        typ = str(obj.get("type") or "").strip().lower()
        if typ in {"tool", "tool_call", "tool-call"}:
            _merge_tool_call(acc, _pick_tool_label(obj, fallback="tool"), _tool_call_id(obj))
            return

        for k, v in obj.items():
            if k in {"part", "properties"}:
                continue
            if isinstance(v, (dict, list)):
                _walk_opencode_tool_parts(v, acc, _depth=_depth + 1)
    elif isinstance(obj, list):
        for item in obj:
            _walk_opencode_tool_parts(item, acc, _depth=_depth + 1)


def _apply_codex_usage_snapshot(usage: Dict[str, Any], acc: Dict[str, Any], include_max: bool = True) -> None:
    """Apply a Codex usage snapshot (overwrite semantics)."""
    raw_input = int(usage.get("input_tokens") or 0)
    cached = int(usage.get("cached_input_tokens") or 0)
    reasoning = int(usage.get("reasoning_output_tokens") or 0)
    output = int(usage.get("output_tokens") or 0) + reasoning

    # input_tokens in Codex includes cached tokens; split cached read out.
    acc["input_tokens"] = max(raw_input - cached, 0)
    acc["cache_read_input_tokens"] = cached
    acc["output_tokens"] = output
    # Codex does not currently emit cache creation as a separate field.
    acc["cache_creation_input_tokens"] = 0

    if include_max:
        # Older/newer event variants may omit total_tokens; derive when absent.
        total_tokens = usage.get("total_tokens")
        if total_tokens is None:
            total_tokens = raw_input + output
        total_tokens = int(total_tokens or 0)
        if total_tokens > acc.get("max_turn_total_tokens", 0):
            acc["max_turn_total_tokens"] = total_tokens


def session_id_from(obj: Any, mode: str) -> Optional[str]:
    if isinstance(obj, dict):
        if mode == "claude":
            for k, v in obj.items():
                if k == "session_id" and isinstance(v, str) and v.strip():
                    return v.strip()
                n = session_id_from(v, mode)
                if n:
                    return n
        elif mode == "cursor":
            for k, v in obj.items():
                kl = k.lower()
                if kl in {"session_id", "chat_id", "thread_id"} and isinstance(v, str) and v.strip():
                    return v.strip()
                n = session_id_from(v, mode)
                if n:
                    return n
        elif mode == "opencode":
            for k in ("session_id", "sessionId", "sessionID", "chat_id"):
                v = obj.get(k)
                if isinstance(v, (str, int)) and str(v).strip():
                    return str(v).strip()
            for k in ("thread_id", "threadId"):
                v = obj.get(k)
                if isinstance(v, (str, int)) and str(v).strip():
                    return str(v).strip()
            for k in ("payload", "result", "data"):
                if k in obj:
                    n = session_id_from(obj.get(k), mode)
                    if n:
                        return n
        else:
            for k in ("session_id", "sessionId", "sessionID", "chat_id", "id"):
                v = obj.get(k)
                if isinstance(v, (str, int)) and str(v).strip():
                    return str(v).strip()
            for k in ("thread_id", "threadId"):
                v = obj.get(k)
                if isinstance(v, (str, int)) and str(v).strip():
                    return str(v).strip()
            for k in ("payload", "part", "result", "data"):
                if k in obj:
                    n = session_id_from(obj.get(k), mode)
                    if n:
                        return n
    elif isinstance(obj, list):
        for i in obj:
            n = session_id_from(i, mode)
            if n:
                return n
    return None


def extract_usage(obj: Any, mode: str, acc: Dict[str, Any]) -> None:
    """Accumulate token usage fields from a JSON event into acc."""
    if not isinstance(obj, dict):
        return
    if mode == "codex":
        # Codex emits repeated token_count events. Each carries:
        #   payload.info.total_token_usage  -- running cumulative (OVERWRITE, not sum)
        #   payload.info.last_token_usage   -- this turn only (track max)
        # Newer Codex CLIs emit turn-completion usage snapshots at:
        #   turn.completed.usage
        # We must NOT recurse generically here to avoid double-counting usage payloads.
        payload = obj.get("payload")
        if isinstance(payload, dict) and payload.get("type") == "token_count":
            info = payload.get("info")
            if isinstance(info, dict):
                total = info.get("total_token_usage")
                if isinstance(total, dict):
                    _apply_codex_usage_snapshot(total, acc, include_max=False)
                last = info.get("last_token_usage")
                if isinstance(last, dict):
                    last_total = int(last.get("total_tokens") or 0)
                    if last_total > acc.get("max_turn_total_tokens", 0):
                        acc["max_turn_total_tokens"] = last_total

        event_type = obj.get("type")
        if event_type in {"turn.completed", "turn_completed", "step_finish"}:
            acc["tool_turns"] = int(acc.get("tool_turns", 0)) + 1
        if event_type in {"turn.completed", "turn_completed", "result"}:
            usage = obj.get("usage")
            if isinstance(usage, dict):
                _apply_codex_usage_snapshot(usage, acc)

        if event_type == "step_finish":
            part = obj.get("part")
            if isinstance(part, dict):
                tokens = part.get("tokens")
                if isinstance(tokens, dict):
                    raw_input = int(tokens.get("input") or 0)
                    output = int(tokens.get("output") or 0) + int(tokens.get("reasoning") or 0)
                    cache = tokens.get("cache")
                    cache_read = 0
                    cache_create = 0
                    if isinstance(cache, dict):
                        cache_read = int(cache.get("read") or 0)
                        cache_create = int(cache.get("write") or 0)
                    # step_finish is a snapshot in some Codex/OpenCode variants; keep overwrite semantics.
                    acc["input_tokens"] = max(raw_input - cache_read, 0)
                    acc["output_tokens"] = output
                    acc["cache_read_input_tokens"] = cache_read
                    acc["cache_creation_input_tokens"] = cache_create
                    step_total = int(tokens.get("total") or 0)
                    if step_total > acc.get("max_turn_total_tokens", 0):
                        acc["max_turn_total_tokens"] = step_total
        return
    if mode == "opencode":
        # Implementation note -- OpenCode token event semantics (evidence from
        # .ralph-workspace/logs/PLAN4/plan-runner-PLAN4-output.log):
        #
        # Event excerpt (step_finish, invocation 1, step 1):
        #   {"type":"step_finish","timestamp":1776367151513,"part":{"tokens":{
        #     "total":18765,"input":18644,"output":121,"reasoning":0,
        #     "cache":{"read":0,"write":0}}}}
        #
        # Event excerpt (step_finish, invocation 1, step 2):
        #   {"type":"step_finish","timestamp":1776367153750,"part":{"tokens":{
        #     "total":20023,"input":19962,"output":61,"reasoning":0,
        #     "cache":{"read":0,"write":0}}}}
        #
        # Interpretation: tokens.input/output/reasoning/cache are per-step DELTAS,
        # not cumulative snapshots. Evidence:
        #   (a) Step-2 input=19962 is NOT step-1 input + step-2 delta (would be
        #       ~38606 if cumulative); it is ~18K because it is independent.
        #   (b) A later invocation resets: its first step shows input=18609, far
        #       below the ~30118 total of invocation 1's last step.
        #   (c) total == input + output + reasoning always holds (18765 = 18644+121+0),
        #       confirming each event reports only its own turn.
        # Therefore the correct accumulation model is SUM across events (not
        # overwrite or max), which matches the current implementation below.
        #
        # OpenCode emits step-level events. The token counts live in a top-level
        # "tokens" dict (or nested inside "part") and use field names:
        #   tokens.input, tokens.output, tokens.reasoning,
        #   tokens.cache.read, tokens.cache.write
        # These are per-step so we SUM across events.
        tokens = obj.get("tokens")
        if not isinstance(tokens, dict):
            # Also check inside "part" for step_finish events.
            part = obj.get("part")
            if isinstance(part, dict):
                tokens = part.get("tokens")
        if isinstance(tokens, dict):
            acc["tool_turns"] = int(acc.get("tool_turns", 0)) + 1
            acc["input_tokens"] += int(tokens.get("input") or 0)
            acc["output_tokens"] += int(tokens.get("output") or 0) + int(tokens.get("reasoning") or 0)
            cache = tokens.get("cache")
            if isinstance(cache, dict):
                acc["cache_read_input_tokens"] += int(cache.get("read") or 0)
                acc["cache_creation_input_tokens"] += int(cache.get("write") or 0)
        return
    if mode == "claude":
        # Claude stream-json usage appears in usage blocks (top-level and/or under message).
        # To avoid double-counting, we track if we've seen a result event and prefer
        # its cumulative usage over summing per-assistant deltas.
        is_result_event = obj.get("type") == "result" or "result" in obj
        if is_result_event:
            acc["_claude_result_seen"] = True
        
        usage = obj.get("usage")
        if not usage and isinstance(obj.get("message"), dict):
            usage = obj.get("message", {}).get("usage")
        if isinstance(usage, dict):
            acc["tool_turns"] = int(acc.get("tool_turns", 0)) + 1
            if acc.get("_claude_result_seen") and is_result_event:
                # Replace with result event's cumulative usage
                acc["input_tokens"] = int(usage.get("input_tokens") or 0)
                acc["output_tokens"] = int(usage.get("output_tokens") or 0)
                acc["cache_creation_input_tokens"] = int(usage.get("cache_creation_input_tokens") or 0)
                acc["cache_read_input_tokens"] = int(usage.get("cache_read_input_tokens") or 0)
            else:
                # Sum as before
                acc["input_tokens"] += int(usage.get("input_tokens") or 0)
                acc["output_tokens"] += int(usage.get("output_tokens") or 0)
                acc["cache_creation_input_tokens"] += int(usage.get("cache_creation_input_tokens") or 0)
                acc["cache_read_input_tokens"] += int(usage.get("cache_read_input_tokens") or 0)
        # Also check top-level usage fields, but guard against re-adding result usage
        if not acc.get("_claude_result_seen") and ("input_tokens" in obj or "output_tokens" in obj):
            acc["input_tokens"] += int(obj.get("input_tokens") or 0)
            acc["output_tokens"] += int(obj.get("output_tokens") or 0)
            acc["cache_creation_input_tokens"] += int(obj.get("cache_creation_input_tokens") or 0)
            acc["cache_read_input_tokens"] += int(obj.get("cache_read_input_tokens") or 0)
        return
    # Generic: look for common token field names across runtimes (cursor, etc.)
    for in_key in ("input_tokens", "inputTokens", "prompt_tokens", "promptTokens"):
        if in_key in obj:
            acc["input_tokens"] += int(obj[in_key] or 0)
            break
    for out_key in ("output_tokens", "outputTokens", "completion_tokens", "completionTokens"):
        if out_key in obj:
            acc["output_tokens"] += int(obj[out_key] or 0)
            break
    # Some runtimes nest usage under "usage" or "tokenUsage" with different key casing.
    usage = obj.get("usage") or obj.get("tokenUsage") or obj.get("token_usage")
    if isinstance(usage, dict):
        for in_key in ("input_tokens", "inputTokens", "prompt_tokens", "promptTokens"):
            if in_key in usage:
                acc["input_tokens"] += int(usage.get(in_key) or 0)
                break
        for out_key in ("output_tokens", "outputTokens", "completion_tokens", "completionTokens"):
            if out_key in usage:
                acc["output_tokens"] += int(usage.get(out_key) or 0)
                break
        for cc_key in ("cache_creation_input_tokens", "cacheCreationInputTokens", "cacheWriteTokens"):
            if cc_key in usage:
                acc["cache_creation_input_tokens"] += int(usage.get(cc_key) or 0)
                break
        for cr_key in ("cache_read_input_tokens", "cacheReadInputTokens", "cacheReadTokens"):
            if cr_key in usage:
                acc["cache_read_input_tokens"] += int(usage.get(cr_key) or 0)
                break
    # Recurse into nested dicts for usage sub-objects, but avoid double-counting
    # when we already processed a dedicated usage object above.
    for v in obj.values():
        if isinstance(v, dict) and v is not usage:
            extract_usage(v, mode, acc)


def extract_text(obj: Any, mode: str) -> List[str]:
    out: List[str] = []
    if isinstance(obj, dict):
        for k, v in obj.items():
            kl = k.lower()
            if kl in {"text", "content", "message", "output", "final"} and isinstance(v, str):
                out.append(v)
            out.extend(extract_text(v, mode))
    elif isinstance(obj, list):
        for i in obj:
            out.extend(extract_text(i, mode))
    elif isinstance(obj, str) and mode == "codex":
        out.append(obj)
    return out


def main() -> None:
    mode = sys.argv[1] if len(sys.argv) > 1 else "claude"
    path = sys.argv[2] if len(sys.argv) > 2 else ""
    usage_path = sys.argv[3] if len(sys.argv) > 3 else ""
    sid: Optional[str] = None
    usage_acc: Dict[str, Any] = {
        "input_tokens": 0,
        "output_tokens": 0,
        "cache_creation_input_tokens": 0,
        "cache_read_input_tokens": 0,
        "max_turn_total_tokens": 0,
        "tool_turns": 0,
        "tool_calls_total": 0,
        "tool_calls_by_tool": {},
        "tool_calls_sequence": [],
    }
    for raw in sys.stdin:
        line = raw.rstrip("\n")
        if not line.strip():
            continue
        try:
            o = json.loads(line)
        except json.JSONDecodeError:
            print(line)
            continue
        if (
            mode == "claude"
            and isinstance(o, dict)
            and o.get("type") == "system"
            and o.get("subtype") == "init"
        ):
            # Claude emits a system/init envelope per print invocation.
            # Suppress this metadata line so resumed plan logs are less noisy.
            if sid is None and path:
                sid = session_id_from(o, mode)
            extract_usage(o, mode, usage_acc)
            extract_tool_calls(o, mode, usage_acc)
            continue
        if sid is None and path:
            sid = session_id_from(o, mode)
        extract_usage(o, mode, usage_acc)
        extract_tool_calls(o, mode, usage_acc)
        texts = extract_text(o, mode)
        if texts:
            for t in texts:
                t = t.strip()
                if t:
                    print(t)
        else:
            print(line)
    if sid and path:
        try:
            os.makedirs(os.path.dirname(path) or ".", exist_ok=True)
            with open(path, "w", encoding="utf-8") as fh:
                fh.write(sid + "\n")
        except OSError:
            pass
    if usage_path:
        try:
            os.makedirs(os.path.dirname(usage_path) or ".", exist_ok=True)
            public_usage = {k: v for k, v in usage_acc.items() if not k.startswith("_")}
            with open(usage_path, "w", encoding="utf-8") as fh:
                json.dump(public_usage, fh)
                fh.write("\n")
        except OSError:
            pass


if __name__ == "__main__":
    main()
