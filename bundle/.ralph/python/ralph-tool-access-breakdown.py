import json
import os
import re
import sys
from tool_call_classification import classify_tool_calls
from tool_call_target_telemetry import optimization_hint_line

ANSI_RE = re.compile(r"\x1b\[[0-9;]*m")


def visible_len(text):
    return len(ANSI_RE.sub("", text))


def coerce_bool(value):
    if isinstance(value, bool):
        return value
    if value is None:
        return False
    text = str(value).strip().lower()
    return text in ("1", "true", "yes", "on")


def coerce_int(value):
    if value in (None, ""):
        return 0
    try:
        return int(value)
    except (TypeError, ValueError):
        try:
            return int(float(value))
        except (TypeError, ValueError):
            return 0


def edit_adjacent_native_read_budget(native_write):
    """Native reads at or below this count are treated as edit-adjacent when shell/search are absent."""
    return max(2, native_write)


path = sys.argv[1]
with open(path, encoding="utf-8") as fh:
    data = json.load(fh)
counts = classify_tool_calls(data.get("tool_calls_by_tool"))
proxy = counts["ralph_proxy_calls"]
other_mcp = counts["other_mcp_calls"]
compat_native_read = counts["native_read_compatibility_calls"]
native_read_like = counts["native_read_like_calls"]
native_read = counts["native_file_read_calls"]
native_search = counts["native_search_calls"]
native_shell = counts["native_shell_calls"]
native_write = counts["native_write_like_calls"]

hook_compactions = coerce_int(data.get("hook_compactions"))
hook_original_bytes = coerce_int(data.get("hook_original_bytes"))
proxy_shell_compactions = coerce_int(data.get("proxy_shell_compactions"))
proxy_shell_original_bytes = coerce_int(data.get("proxy_shell_original_bytes"))
native_hooks_used_on_run = coerce_bool(data.get("native_hooks_used_on_run"))
native_hooks_effective = coerce_bool(data.get("native_hooks_effective"))
mcp_effective = coerce_bool(data.get("mcp_effective"))

native_exploration = native_read + native_search + native_shell
hook_compacted = hook_compactions > 0 and hook_original_bytes > 0
proxy_compacted = proxy_shell_compactions > 0 and proxy_shell_original_bytes > 0
compaction_proven = hook_compacted or proxy_compacted

if os.environ.get("RALPH_AGENT_TOOL_ACCESS", "") == "ralph":
    if os.environ.get("RALPH_AGENT_TOOL_ACCESS_REQUIRE_PROXY", "") in ("1", "true", "yes"):
        if native_exploration > 0:
            print(
                "ERROR: ralph mode requires ralph_proxy_* tools for reads/search/shell exploration"
            )
            sys.exit(1)
    else:
        if proxy == 0 and native_exploration > 0:
            if compaction_proven:
                print(
                    "NOTE: ralph mode active; agent used only native tools but output was compacted (hook or proxy compaction proven)"
                )
            else:
                print(
                    "WARNING: ralph mode active but agent used only native read/search/shell tools without proven compaction; prefer ralph_proxy_* for exploration"
                )
        elif proxy > 0 and native_exploration > 0:
            if native_shell > 0 and compaction_proven:
                print(
                    "NOTE: ralph mode active; agent used mixed native and proxy tools, and native shell output was compacted"
                )
            elif (
                native_read > 0
                and native_shell == 0
                and native_search == 0
                and native_read <= edit_adjacent_native_read_budget(native_write)
            ):
                print(
                    "NOTE: ralph mode active; agent used native reads near edits (edit-adjacent native read/write flow is acceptable)"
                )
            else:
                print(
                    "WARNING: ralph mode active but agent used mixed native and proxy tools without compaction; prefer ralph_proxy_* exclusively for exploration"
                )

hint = optimization_hint_line(data)
if hint:
    print(hint)
