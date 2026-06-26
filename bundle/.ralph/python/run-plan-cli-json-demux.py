#!/usr/bin/env python3
"""Read newline-delimited JSON from stdin; print human-readable text lines; write first session id to file.

Argv: <mode> <session_id_file> [<usage_file> [<output_log> [<pretty 0|1>]]]
mode: claude | cursor | codex | opencode
usage_file: optional path; written with JSON token usage summary at EOF
"""
import json
import os
import sys
from typing import Any, Dict, List, Optional, Tuple

sys.path.insert(0, os.path.dirname(__file__))

from tool_call_classification import classify_tool_calls
from tool_call_target_telemetry import (
    extract_tool_input,
    finalize_tool_target_telemetry,
    init_tool_target_telemetry,
    record_tool_target,
)

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


def _normalize_tool_label(label: str) -> str:
    """Normalize tool labels across runtimes to stable canonicals.

    Handles:
    - OpenCode double-prefixed: ralph_ralph_proxy_read -> ralph_proxy_read
    - MCP server namespace prefixes for Ralph tools: mcp__X__ralph_proxy_read -> ralph_proxy_read
    """
    normalized = label.strip()

    if not normalized:
        return normalized

    # Strip double ralph prefix (OpenCode artifact)
    # e.g., ralph_ralph_proxy_read -> ralph_proxy_read
    if normalized.startswith("ralph_ralph_"):
        normalized = "ralph_" + normalized[len("ralph_ralph_"):]

    # Strip leading mcp__<server>__ namespace prefix ONLY for Ralph tools
    # e.g., mcp__ralph__ralph_proxy_read -> ralph_proxy_read
    # but keep mcp__other__tool_name as-is for non-Ralph MCP tools
    if normalized.startswith("mcp__"):
        parts = normalized.split("__", 2)
        if len(parts) == 3:
            tool_name = parts[2]
            # Only denormalize if the tool is a Ralph tool
            if tool_name.startswith("ralph_"):
                normalized = tool_name

    return normalized


def _merge_tool_call(
    acc: Dict[str, Any],
    name: str,
    call_id: Optional[str] = None,
    tool_input: Optional[Dict[str, Any]] = None,
) -> None:
    if call_id:
        seen = acc.setdefault("_tool_call_ids_seen", set())
        if isinstance(seen, set):
            if call_id in seen:
                return
            seen.add(call_id)
    label = _normalize_tool_label((name or "unknown").strip() or "unknown")
    acc["tool_calls_total"] = int(acc.get("tool_calls_total", 0)) + 1
    by_tool = acc.setdefault("tool_calls_by_tool", {})
    if not isinstance(by_tool, dict):
        by_tool = {}
        acc["tool_calls_by_tool"] = by_tool
    by_tool[label] = int(by_tool.get(label, 0)) + 1
    seq = acc.setdefault("tool_calls_sequence", [])
    if isinstance(seq, list) and len(seq) < _TOOL_SEQUENCE_CAP:
        seq.append(label)
    record_tool_target(acc, label, tool_input)


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
        "mcp_tool_call",
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
            _merge_tool_call(
                acc,
                _pick_tool_label(obj, fallback="tool_use"),
                _tool_call_id(obj),
                extract_tool_input(obj),
            )
        for v in obj.values():
            _walk_claude_tool_uses(v, acc)
    elif isinstance(obj, list):
        for i in obj:
            _walk_claude_tool_uses(i, acc)


def _extract_cursor_mcp_tool_name(tool_data: Dict[str, Any]) -> Optional[str]:
    """Extract real tool name from Cursor MCP tool call data.

    Prefers tool_data.args.toolName, then tool_data.args.name, else None.
    """
    args = tool_data.get("args")
    if isinstance(args, dict):
        for key in ("toolName", "name"):
            v = args.get(key)
            if isinstance(v, str) and v.strip():
                return v.strip()
    return None


def _walk_cursor_tool_calls(obj: Any, acc: Dict[str, Any], *, _depth: int = 0) -> None:
    """Cursor stream-json: extract tool types from tool_call dict entries, with fallback to generic parsing."""
    if _depth > 24:
        return
    if isinstance(obj, dict):
        if obj.get("type") == "tool_call":
            tool_call = obj.get("tool_call")
            if isinstance(tool_call, dict) and any(isinstance(v, dict) for v in tool_call.values()):
                for tool_type_key, tool_data in tool_call.items():
                    if isinstance(tool_data, dict):
                        # For MCP tool calls, extract the real tool name from args
                        if tool_type_key == "mcpToolCall":
                            real_name = _extract_cursor_mcp_tool_name(tool_data)
                            if real_name:
                                _merge_tool_call(
                                    acc,
                                    real_name,
                                    _tool_call_id(tool_data) or _tool_call_id(obj),
                                    extract_tool_input(tool_data),
                                )
                            else:
                                _merge_tool_call(
                                    acc,
                                    tool_type_key,
                                    _tool_call_id(tool_data) or _tool_call_id(obj),
                                    extract_tool_input(tool_data),
                                )
                        else:
                            _merge_tool_call(
                                acc,
                                tool_type_key,
                                _tool_call_id(tool_data) or _tool_call_id(obj),
                                extract_tool_input(tool_data),
                            )
            else:
                _walk_generic_tool_calls(obj, acc, _depth=_depth)
                return
        else:
            _walk_generic_tool_calls(obj, acc, _depth=_depth)
            return
        for v in obj.values():
            if isinstance(v, (dict, list)):
                _walk_cursor_tool_calls(v, acc, _depth=_depth + 1)
    elif isinstance(obj, list):
        for i in obj:
            _walk_cursor_tool_calls(i, acc, _depth=_depth + 1)


def _walk_generic_tool_calls(obj: Any, acc: Dict[str, Any], *, _depth: int = 0) -> None:
    """Generic fallback: common stream tool call shapes, plus shallow recursion."""
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
                _merge_tool_call(
                    acc,
                    _pick_tool_label(entry, fallback="tool_call"),
                    _tool_call_id(entry),
                    extract_tool_input(entry),
                )

        for key in ("tool_call", "toolCall", "function_call", "functionCall"):
            entry = obj.get(key)
            if isinstance(entry, dict):
                _merge_tool_call(
                    acc,
                    _pick_tool_label(entry, fallback=key),
                    _tool_call_id(entry),
                    extract_tool_input(entry),
                )

        typ = str(obj.get("type") or "").strip()
        typ_l = typ.lower().replace("-", "_")
        if typ_l in {"tool_call", "tool_use", "function_call"}:
            _merge_tool_call(
                acc,
                _pick_tool_label(obj, fallback=typ),
                _tool_call_id(obj),
                extract_tool_input(obj),
            )

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
                    _merge_tool_call(
                        acc,
                        label,
                        _tool_call_id(item),
                        extract_tool_input(item),
                    )
        return
    if mode == "opencode":
        _walk_opencode_tool_parts(obj, acc)
        return
    if mode == "claude":
        _walk_claude_tool_uses(obj, acc)
        return
    if mode == "cursor":
        _walk_cursor_tool_calls(obj, acc)
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
            _merge_tool_call(
                acc,
                _pick_tool_label(obj, fallback="tool"),
                _tool_call_id(obj),
                extract_tool_input(obj),
            )
            return

        for k, v in obj.items():
            if k in {"part", "properties"}:
                continue
            if isinstance(v, (dict, list)):
                _walk_opencode_tool_parts(v, acc, _depth=_depth + 1)
    elif isinstance(obj, list):
        for item in obj:
            _walk_opencode_tool_parts(item, acc, _depth=_depth + 1)


def _coerce_nonneg_int(value: Any) -> int:
    try:
        out = int(value or 0)
    except (TypeError, ValueError):
        return 0
    return out if out > 0 else 0


def _opencode_cache_read_from_alternates(obj: Any, tokens: Any) -> int:
    """Find cached-prompt-token counts under alternate field names.

    OpenCode's primary shape is tokens.cache.read, but OpenAI-compatible
    passthrough providers (e.g. ollama-cloud) report cached prompt tokens under
    usage.prompt_tokens_details.cached_tokens (and a few flatter variants). When
    tokens.cache.read is absent or zero we look for those alternates so cache
    reads are not silently dropped. Returns 0 when nothing is found.
    """
    containers: list[Any] = [tokens, obj]
    if isinstance(obj, dict) and isinstance(obj.get("part"), dict):
        containers.append(obj["part"])
    candidates: list[Any] = []
    for container in containers:
        if not isinstance(container, dict):
            continue
        usage = container.get("usage")
        if isinstance(usage, dict):
            details = usage.get("prompt_tokens_details")
            if isinstance(details, dict):
                candidates.append(details.get("cached_tokens"))
            candidates.append(usage.get("cached_tokens"))
            candidates.append(usage.get("cache_read_input_tokens"))
        details = container.get("prompt_tokens_details")
        if isinstance(details, dict):
            candidates.append(details.get("cached_tokens"))
        candidates.append(container.get("cached_tokens"))
        candidates.append(container.get("cache_read_input_tokens"))
    for candidate in candidates:
        found = _coerce_nonneg_int(candidate)
        if found > 0:
            return found
    return 0


def _opencode_event_has_usage(obj: Any) -> bool:
    """True when an opencode event carries token/usage data worth capturing."""
    if not isinstance(obj, dict):
        return False
    if isinstance(obj.get("tokens"), dict) or isinstance(obj.get("usage"), dict):
        return True
    part = obj.get("part")
    if isinstance(part, dict) and (
        isinstance(part.get("tokens"), dict) or isinstance(part.get("usage"), dict)
    ):
        return True
    return False


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


def _env_truthy(value: Any) -> bool:
    """Best-effort boolean coercion for env-var-like values."""
    if value is None:
        return False
    if isinstance(value, bool):
        return value
    if isinstance(value, (int, float)):
        return value != 0
    if not isinstance(value, str):
        return bool(value)
    return value.strip().lower() in {"1", "true", "yes", "on"}


def _opencode_cache_key_injected_from_env() -> bool:
    """
    Gate for cache-estimate emission.

    Mirrors the usage-record gate field contract:
    prompt-cache-key-injected, with fallback to ambient-cache-settings.
    """
    prompt = os.environ.get("RALPH_OPENCODE_PROMPT_CACHE_KEY_INJECTED", "")
    ambient = os.environ.get("RALPH_OPENCODE_AMBIENT_CACHE_SETTINGS", "")
    return _env_truthy(prompt) or _env_truthy(ambient)


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
            cache_read = 0
            if isinstance(cache, dict):
                cache_read = int(cache.get("read") or 0)
                acc["cache_creation_input_tokens"] += int(cache.get("write") or 0)
                acc["opencode_cache_fields_seen"] = 1
            # OpenAI-compatible passthrough providers (ollama-cloud) report cached
            # prompt tokens under usage.prompt_tokens_details.cached_tokens rather
            # than tokens.cache.read. Fall back to those alternates so the cache
            # read is not dropped when the native field is absent or zero.
            if cache_read <= 0:
                alt_read = _opencode_cache_read_from_alternates(obj, tokens)
                if alt_read > 0:
                    cache_read = alt_read
                    acc["opencode_cache_fields_seen"] = 1
            acc["cache_read_input_tokens"] += cache_read

            # Track per-step/per-invocation data so we can emit a best-guess
            # cache read estimate when the provider never reports cache reads.
            #
            # This intentionally keys off the env gate; the later estimate logic
            # uses the shared helper and method label.
            inv_list = acc.setdefault("_opencode_cache_invocations", [])
            if isinstance(inv_list, list):
                inv_list.append(
                    {
                        "runtime": "opencode",
                        "input_tokens": int(tokens.get("input") or 0),
                        "cache_read_input_tokens": int(cache_read or 0),
                        "opencode_cache_key_injected": _opencode_cache_key_injected_from_env(),
                    }
                )
        return
    if mode == "claude":
        # Claude stream-json emits one usage block per assistant turn (each a per-request
        # delta, under message.usage) plus a final `result` event. Empirically the result
        # event reports cache_read/cache_creation cumulatively but input_tokens/output_tokens
        # for the FINAL turn only -- so trusting it undercounts input/output for multi-turn
        # invocations (e.g. a 166-turn TODO collapsing to input=10 even though tens of
        # thousands of tokens were written to cache). We therefore SUM the per-turn assistant
        # usage for all four fields, which is billing-accurate, and fall back to the result
        # event's usage only when no per-turn usage was observed (e.g. an interrupted stream).
        #
        # Only the actual terminal result event should be treated as fallback usage. Some
        # Claude event variants can include an unrelated top-level `result` payload on
        # non-terminal events; treating any event with a `result` key as terminal causes us
        # to discard valid per-turn assistant usage and leaves only a tiny final-turn usage
        # snapshot alongside a large cache write count.
        is_result_event = obj.get("type") == "result"

        usage = obj.get("usage")
        if not usage and isinstance(obj.get("message"), dict):
            usage = obj.get("message", {}).get("usage")
        # Some Claude variants put token fields at the top level of an event.
        if not isinstance(usage, dict) and ("input_tokens" in obj or "output_tokens" in obj):
            usage = obj
        if not isinstance(usage, dict):
            return

        tokens = {
            "input_tokens": int(usage.get("input_tokens") or 0),
            "output_tokens": int(usage.get("output_tokens") or 0),
            "cache_creation_input_tokens": int(usage.get("cache_creation_input_tokens") or 0),
            "cache_read_input_tokens": int(usage.get("cache_read_input_tokens") or 0),
        }
        if is_result_event:
            # Stash for fallback only; adding it would clobber/double-count the final turn
            # already captured via the per-turn assistant usage.
            acc["_claude_result_usage"] = tokens
        else:
            acc["tool_turns"] = int(acc.get("tool_turns", 0)) + 1
            acc["_claude_turn_usage_seen"] = True
            for key, value in tokens.items():
                acc[key] += value
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


def compute_cache_read_ratios(acc: Dict[str, Any]) -> Tuple[float, float]:
    """Return cache-read tokens per tool turn and per tool call."""
    cache_read = int(acc.get("cache_read_input_tokens") or 0)
    tool_turns = int(acc.get("tool_turns") or 0)
    tool_calls = int(acc.get("tool_calls_total") or 0)
    denom_turn = tool_turns if tool_turns > 0 else (tool_calls if tool_calls > 0 else 1)
    per_turn = cache_read / denom_turn if denom_turn else 0.0
    per_call = cache_read / tool_calls if tool_calls > 0 else 0.0
    return per_turn, per_call


def finalize_usage(acc: Dict[str, Any], mode: str) -> None:
    """Apply end-of-stream usage fixups that depend on the full event sequence."""
    if mode == "claude" and not acc.get("_claude_turn_usage_seen"):
        # No per-turn assistant usage was observed (e.g. a stream that only produced a
        # result event); fall back to whatever the result event reported.
        result_usage = acc.get("_claude_result_usage")
        if isinstance(result_usage, dict):
            for key, value in result_usage.items():
                acc[key] = int(value or 0)
    if mode == "opencode":
        # If the provider reported cache reads, we keep the measured field
        # and never imply cache savings.
        measured_cache_read = int(acc.get("cache_read_input_tokens") or 0)
        if measured_cache_read == 0 and _opencode_cache_key_injected_from_env():
            invocations = acc.get("_opencode_cache_invocations") or []
            try:
                from opencode_cache_estimate import estimate_opencode_cache_read
            except ImportError:
                estimate_opencode_cache_read = None  # type: ignore[assignment]
            if estimate_opencode_cache_read is not None and isinstance(invocations, list):
                result = estimate_opencode_cache_read(invocations)
                acc["cache_read_input_tokens_estimated"] = int(result.get("estimated") or 0)
                acc["cache_read_estimate_method"] = str(result.get("method") or "none")


def extract_text(obj: Any, mode: str) -> List[str]:
    out: List[str] = []
    if isinstance(obj, dict):
        # Codex item.completed: emit one meaningful plain line per item type
        # so raw JSON fragments never leak into the log / non-pretty output.
        if mode == "codex" and obj.get("type") == "item.completed":
            item = obj.get("item")
            if isinstance(item, dict):
                item_type = str(item.get("type") or "").strip().lower()
                if item_type == "agent_message":
                    text = item.get("text")
                    if isinstance(text, str) and text.strip():
                        out.append(text.strip())
                    return out
                if item_type == "reasoning":
                    return out
                if item_type == "file_change":
                    changes = item.get("changes")
                    status = str(item.get("status") or "completed").strip()
                    if isinstance(changes, list):
                        for change in changes:
                            if isinstance(change, dict):
                                path = str(change.get("path") or change.get("file_path") or change.get("filePath") or "").strip()
                                kind = str(change.get("kind") or change.get("type") or "update").strip()
                                out.append(f"file_change {kind} {path} ({status})")
                    if not out:
                        out.append(f"file_change ({status})")
                    return out
                if item_type == "error":
                    msg = str(item.get("message") or item.get("error") or item.get("text") or "error").strip()
                    status = str(item.get("status") or "failed").strip()
                    out.append(f"error {msg} ({status})")
                    return out
                if item_type == "web_search":
                    query = str(item.get("query") or item.get("search_query") or "").strip()
                    status = str(item.get("status") or "completed").strip()
                    out.append(f"web_search {query} ({status})")
                    return out
                if item_type == "todo_list":
                    return out
                if item_type == "command_execution":
                    cmd = str(item.get("command") or item.get("argv") or "").strip()
                    status = str(item.get("status") or "completed").strip()
                    out.append(f"command_execution {cmd} ({status})")
                    return out
                # Any other unhandled item type: single line so the generic
                # string-walk can no longer leak fragments.
                out.append(item_type)
                return out
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


def _write_lines(fd: Any, lines: List[str]) -> None:
    for line in lines:
        fd.write(line + "\n")


def _raw_output_log_path(compact_log_path: str) -> str:
    explicit_path = os.environ.get("RALPH_PLAN_RAW_OUTPUT_LOG_PATH", "").strip()
    if explicit_path:
        return explicit_path

    explicit_dir = os.environ.get("RALPH_PLAN_RAW_OUTPUT_DIR", "").strip()
    if explicit_dir:
        return os.path.join(explicit_dir, "plan-output-raw.log")

    return os.path.join(os.path.dirname(compact_log_path), "plan-output-raw.log")


def _note_completion_sentinel(lines: List[str], seen: bool) -> bool:
    if seen:
        return True
    try:
        from completion_sentinel import text_has_completion_sentinel
    except ImportError:
        return seen
    return text_has_completion_sentinel("\n".join(lines))


def _write_output_log(
    output_log: Any,
    log_renderer: Any,
    obj: Any,
    plain_lines: List[str],
) -> None:
    if log_renderer is not None:
        try:
            rendered = log_renderer.render_event(obj)
        except Exception:
            rendered = None
        _write_lines(output_log, rendered if rendered is not None else plain_lines)
    else:
        _write_lines(output_log, plain_lines)


def main() -> None:
    mode = sys.argv[1] if len(sys.argv) > 1 else "claude"
    path = sys.argv[2] if len(sys.argv) > 2 else ""
    usage_path = sys.argv[3] if len(sys.argv) > 3 else ""
    output_log_path = sys.argv[4] if len(sys.argv) > 4 else ""
    pretty = len(sys.argv) > 5 and sys.argv[5] == "1"
    sid: Optional[str] = None
    output_log = None
    raw_output_log = None
    renderer = None
    log_renderer = None
    stdout_broken = False
    completion_sentinel_seen = False
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
        "opencode_cache_fields_seen": 0,
        "cache_read_input_tokens_estimated": 0,
        "cache_read_estimate_method": "none",
        "_opencode_cache_invocations": [],
        "completion_sentinel_seen": False,
    }
    usage_acc.update(init_tool_target_telemetry())

    try:
        from run_plan_pretty import PrettyRenderer
    except ImportError:
        PrettyRenderer = None  # type: ignore[misc, assignment]

    if output_log_path:
        try:
            os.makedirs(os.path.dirname(output_log_path) or ".", exist_ok=True)
            output_log = open(output_log_path, "a", encoding="utf-8", buffering=1)
            if PrettyRenderer is not None:
                log_renderer = PrettyRenderer(
                    mode, color=False, ascii_only=True, log_path=output_log_path
                )
            if os.environ.get("RALPH_PLAN_RAW_OUTPUT_LOG", "0") == "1":
                raw_path = _raw_output_log_path(output_log_path)
                raw_output_log = open(raw_path, "a", encoding="utf-8", buffering=1)
        except OSError as exc:
            sys.stderr.write(
                f"warning: unable to open output log {output_log_path}: {exc}\n"
            )
            output_log = None
            raw_output_log = None
            log_renderer = None

    # Opt-in raw token/usage capture for opencode (e.g. ollama-cloud cache
    # debugging). Lets us distinguish "cache never hit" from "cache hit but not
    # reported" by recording exactly what the provider emits. Enabled with
    # RALPH_OPENCODE_CACHE_DEBUG=1; path from RALPH_OPENCODE_USAGE_DEBUG_LOG, else
    # alongside the output log.
    opencode_usage_log = None
    if mode == "opencode" and os.environ.get("RALPH_OPENCODE_CACHE_DEBUG", "0") == "1":
        debug_path = os.environ.get("RALPH_OPENCODE_USAGE_DEBUG_LOG", "")
        if not debug_path and output_log_path:
            debug_path = os.path.join(
                os.path.dirname(output_log_path) or ".", "opencode-usage-events.log"
            )
        if debug_path:
            try:
                os.makedirs(os.path.dirname(debug_path) or ".", exist_ok=True)
                opencode_usage_log = open(debug_path, "a", encoding="utf-8", buffering=1)
            except OSError as exc:
                sys.stderr.write(
                    f"warning: unable to open opencode usage debug log {debug_path}: {exc}\n"
                )
                opencode_usage_log = None

    if pretty and PrettyRenderer is not None:
        color = sys.stdout.isatty() and not os.environ.get("NO_COLOR")
        color_depth = 0
        if color:
            colorterm = os.environ.get("COLORTERM", "").lower()
            term = os.environ.get("TERM", "").lower()
            if "truecolor" in colorterm or "24bit" in colorterm or "256color" in colorterm:
                color_depth = 256
            elif "256color" in term:
                color_depth = 256
            else:
                color_depth = 16
        ascii_only = os.environ.get("RALPH_PLAN_PRETTY_ASCII") == "1"
        renderer = PrettyRenderer(
            mode,
            color=color,
            ascii_only=ascii_only,
            log_path=output_log_path or "",
            color_depth=color_depth,
        )

    def write_stdout(lines: List[str]) -> None:
        nonlocal stdout_broken
        if stdout_broken:
            return
        try:
            _write_lines(sys.stdout, lines)
        except BrokenPipeError:
            stdout_broken = True

    for raw in sys.stdin:
        line = raw.rstrip("\n")
        if not line.strip():
            continue
        if raw_output_log is not None:
            raw_output_log.write(raw)
        try:
            o = json.loads(line)
        except json.JSONDecodeError:
            plain_lines = [line]
            completion_sentinel_seen = _note_completion_sentinel(
                plain_lines, completion_sentinel_seen
            )
            if output_log is not None:
                if log_renderer is not None:
                    try:
                        log_rendered = log_renderer.render_plain(line)
                    except Exception:
                        log_rendered = None
                    _write_lines(
                        output_log,
                        log_rendered if log_rendered is not None else plain_lines,
                    )
                else:
                    _write_lines(output_log, plain_lines)
            if pretty and renderer is not None:
                try:
                    rendered = renderer.render_plain(line)
                except Exception:
                    rendered = None
                write_stdout(rendered if rendered is not None else plain_lines)
            else:
                write_stdout(plain_lines)
            continue
        if (
            mode in ("claude", "opencode")
            and isinstance(o, dict)
            and o.get("type") == "system"
            and o.get("subtype") == "init"
        ):
            # Claude/OpenCode emit a system/init envelope per print invocation.
            # Suppress this metadata line so resumed plan logs are less noisy.
            if sid is None and path:
                sid = session_id_from(o, mode)
            extract_usage(o, mode, usage_acc)
            extract_tool_calls(o, mode, usage_acc)
            continue
        if opencode_usage_log is not None and _opencode_event_has_usage(o):
            try:
                opencode_usage_log.write(line + "\n")
            except OSError:
                pass
        if sid is None and path:
            sid = session_id_from(o, mode)
        extract_usage(o, mode, usage_acc)
        extract_tool_calls(o, mode, usage_acc)
        texts = extract_text(o, mode)
        plain_lines = []
        if texts:
            for t in texts:
                t = t.strip()
                if t:
                    plain_lines.append(t)
        else:
            plain_lines = [line]
        try:
            from completion_sentinel import object_has_assistant_completion_sentinel
        except ImportError:
            object_has_assistant_completion_sentinel = None  # type: ignore[misc, assignment]
        if object_has_assistant_completion_sentinel is not None:
            if object_has_assistant_completion_sentinel(o, mode):
                completion_sentinel_seen = True
        elif plain_lines:
            completion_sentinel_seen = _note_completion_sentinel(
                plain_lines, completion_sentinel_seen
            )
        if output_log is not None:
            _write_output_log(output_log, log_renderer, o, plain_lines)
        if pretty and renderer is not None:
            try:
                rendered = renderer.render_event(o)
            except Exception:
                rendered = None
            write_stdout(rendered if rendered is not None else plain_lines)
        else:
            write_stdout(plain_lines)
    if pretty and renderer is not None:
        # Streamed text deltas without a trailing newline stay buffered in the
        # renderer; emit them before the stream closes.
        try:
            leftover = renderer.flush()
        except Exception:
            leftover = None
        if leftover:
            write_stdout(leftover)
    if log_renderer is not None:
        try:
            log_leftover = log_renderer.flush()
        except Exception:
            log_leftover = None
        if log_leftover and output_log is not None:
            _write_lines(output_log, log_leftover)
    if output_log is not None:
        output_log.close()
    if raw_output_log is not None:
        raw_output_log.close()
    if opencode_usage_log is not None:
        opencode_usage_log.close()
    if sid and path:
        try:
            os.makedirs(os.path.dirname(path) or ".", exist_ok=True)
            with open(path, "w", encoding="utf-8") as fh:
                fh.write(sid + "\n")
        except OSError:
            pass
    finalize_usage(usage_acc, mode)
    cache_read_per_turn, cache_read_per_call = compute_cache_read_ratios(usage_acc)
    usage_acc["cache_read_per_tool_turn"] = cache_read_per_turn
    usage_acc["cache_read_per_tool_call"] = cache_read_per_call
    finalize_tool_target_telemetry(usage_acc)
    usage_acc["completion_sentinel_seen"] = completion_sentinel_seen
    try:
        from usage_accounting import attach_auxiliary_metrics, enrich_record

        attach_auxiliary_metrics(
            usage_acc,
            plan_key=os.environ.get("RALPH_PLAN_KEY", "").strip()
            or os.environ.get("RALPH_ARTIFACT_NS", "").strip(),
        )
        enrich_record(usage_acc)
    except ImportError:
        pass
    if usage_path:
        try:
            os.makedirs(os.path.dirname(usage_path) or ".", exist_ok=True)
            usage_acc.update(classify_tool_calls(usage_acc.get("tool_calls_by_tool")))
            public_usage = {k: v for k, v in usage_acc.items() if not k.startswith("_")}
            with open(usage_path, "w", encoding="utf-8") as fh:
                json.dump(public_usage, fh)
                fh.write("\n")
        except OSError:
            pass


if __name__ == "__main__":
    main()
