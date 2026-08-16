#!/usr/bin/env python3
"""Best-effort pretty renderer for run-plan stream-json events."""

from __future__ import annotations

import difflib
import importlib.util
import json
import os
import re
import shutil
import textwrap
from typing import Any, Dict, List, Mapping, Optional, Sequence, Tuple

try:
    import pretty_result_store as _RESULT_STORE
except ImportError:
    _RESULT_STORE = None  # type: ignore[assignment]


def _load_demux_module() -> Any:
    path = os.path.join(os.path.dirname(__file__), "run-plan-cli-json-demux.py")
    spec = importlib.util.spec_from_file_location("run_plan_cli_json_demux", path)
    if spec is None or spec.loader is None:
        raise ImportError("unable to load run-plan-cli-json-demux.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


_DEMUX = _load_demux_module()
_normalize_tool_label = _DEMUX._normalize_tool_label
_codex_item_tool_name = _DEMUX._codex_item_tool_name
_extract_cursor_mcp_tool_name = _DEMUX._extract_cursor_mcp_tool_name
_pick_tool_label = _DEMUX._pick_tool_label
_tool_call_id = _DEMUX._tool_call_id

# Old/new pair keys across runtimes (claude snake_case, opencode camelCase).
_CHANGE_OLD_KEYS = ("old_string", "oldString")
_CHANGE_NEW_KEYS = ("new_string", "newString")
# Full-content keys for write-style tools.
_WRITE_CONTENT_KEYS = ("content", "file_text", "fileText", "new_source", "newSource", "streamContent")
_WRITE_TOOL_NAMES = frozenset(
    {
        "write",
        "write_file",
        "create_file",
        "notebookedit",
        "edit",
        "multiedit",
    }
)
# Direct reads already identify their source in the preceding tool-call line
# (for example, ``read(bundle/.ralph/...)``).  The pretty log should preserve
# its compact preview without adding a second result-store navigation UI for
# the same file.
_DIRECT_SOURCE_READ_TOOL_NAMES = frozenset(
    {
        "read",
        "read_file",
        "ralph_proxy_read",
        "resources/read",
    }
)
# Pre-rendered patch text keys (codex apply_patch and similar).
_PATCH_TEXT_KEYS = ("patch", "diff", "unified_diff", "unifiedDiff")
_CHANGE_BLOCK_MAX_LINES = 20

# Preview line budget for tool-result bodies.  Results whose total non-empty
# line count exceeds _RESULT_BODY_LARGE_THRESHOLD are treated as large
# payloads and rendered with the smaller _RESULT_BODY_LARGE_BUDGET so the TUI
# stays readable.  Set RALPH_PRETTY_RESULT_BODY_LINES to override the
# large-payload head budget (conservative default: 2 lines).  Results at or
# below the threshold use a standard 4-line budget.
_RESULT_BODY_NORMAL_BUDGET: int = 4
_RESULT_BODY_LARGE_THRESHOLD: int = 6
try:
    _RESULT_BODY_LARGE_BUDGET: int = max(1, int(os.environ.get("RALPH_PRETTY_RESULT_BODY_LINES", "2")))
except (ValueError, TypeError):
    _RESULT_BODY_LARGE_BUDGET = 2
try:
    _RESULT_BODY_LARGE_BYTE_THRESHOLD: int = max(
        512, int(os.environ.get("RALPH_PRETTY_RESULT_BODY_BYTES", "4096"))
    )
except (ValueError, TypeError):
    _RESULT_BODY_LARGE_BYTE_THRESHOLD = 4096

# Proxy envelopes embed the stored-result id; the full output lives under
# .ralph-workspace/tool-results/<ns>/results/<id>.txt.
_RESULT_ID_RE = re.compile(r'\\?"resultId\\?"\s*:\s*\\?"([A-Za-z0-9_-]{4,})\\?"')
_PROXY_ENVELOPE_ID_RE = re.compile(r"^[a-f0-9]{16}$")

# Agents print this marker on its own line when an invocation finishes.
_AGENT_DONE_MARKER = "AGENT_INVOCATION_COMPLETE"
# Agent-reported verification verdict. PASS renders green, FAIL renders red.
_VERIFICATION_RESULT_RE = re.compile(
    r"VERIFICATION(?:_RESULT| STATUS)[ \t]*:[ \t]*(?P<verdict>PASS|FAIL)",
    re.IGNORECASE,
)

# run-plan composes every TODO prompt with this preamble; some runtimes echo
# the full prompt (rules and all) back into the stream.
_PROMPT_ECHO_MARKER = "Complete exactly this TODO and nothing else:"
# Plain-line prompt echoes (OpenCode) stream one physical line at a time.
_PLAIN_PROMPT_CONTINUATION_PREFIXES = (
    "Complete exactly this TODO",
    "**TODO (line ",
    "**Plan file:**",
    "Rules:",
    "- ",
    "Artifact namespace:",
    "Use namespace-aware artifact paths",
    "## Agent Tool Access",
    "## Ralph Mode",
    "Ralph tooling is preflight-checked",
    "Ralph MCP ",
    "Native `",
    "Prefer ",
    "If ",
    "For ",
    "Do not ",
    "Open `",
    "When a proxy response",
    "Direct names",
    "MCP-qualified names",
)
_PRIMARY_ARG_KEYS: Dict[str, Tuple[str, ...]] = {
    "Bash": ("description", "command"),
    "Read": ("file_path",),
    "Edit": ("file_path",),
    "Write": ("file_path",),
    "MultiEdit": ("file_path",),
    "NotebookEdit": ("file_path",),
    "Grep": ("pattern",),
    "Glob": ("pattern",),
    "Task": ("description",),
    "WebFetch": ("url",),
    "WebSearch": ("query",),
}

# Keys that may nest the real tool input one level deeper (cursor wraps MCP
# args as tool_call.mcpToolCall.args.args; opencode keeps input under
# part.state.input).
_NESTED_INPUT_KEYS = ("args", "input", "arguments", "params", "state")

# Generic argument keys checked across runtimes when no per-tool mapping hits.
_GENERIC_ARG_KEYS = (
    "path",
    "file_path",
    "filePath",
    "command",
    "query",
    "pattern",
    "globPattern",
    "url",
    "description",
)

_BATCH_OPERATION_DISPLAY_LIMIT = 5

# Identifier/bookkeeping keys that must never be shown as a tool argument.
_ARG_METADATA_KEYS = frozenset(
    {
        "name",
        "toolname",
        "tool_name",
        "tool",
        "callid",
        "call_id",
        "toolcallid",
        "tool_call_id",
        "provideridentifier",
        "sessionid",
        "session_id",
        "messageid",
        "message_id",
        "model_call_id",
        "id",
        "type",
        "status",
        "subtype",
        "timestamp",
        "timestamp_ms",
    }
)


def _safe_str(value: Any) -> str:
    if value is None:
        return ""
    return str(value)


def _truncate(text: str, limit: int = 80) -> str:
    text = text.strip()
    if len(text) <= limit:
        return text
    return text[: max(0, limit - 3)].rstrip() + "..."


def _display_path(value: str) -> str:
    cwd = os.getcwd().rstrip(os.sep) + os.sep
    if value.startswith(cwd):
        return value[len(cwd):]
    return value


def _extract_text_fragments(value: Any) -> List[str]:
    if isinstance(value, str):
        return [value]
    if isinstance(value, list):
        out: List[str] = []
        for item in value:
            if isinstance(item, dict) and item.get("type") == "text":
                text = item.get("text")
                if isinstance(text, str):
                    out.append(text)
            elif isinstance(item, str):
                out.append(item)
        return out
    return []


def _is_natural_number(value: Any) -> bool:
    if isinstance(value, bool):
        return False
    if isinstance(value, int):
        return value >= 0
    if isinstance(value, float):
        return value >= 0 and value == int(value)
    return False


def _is_proxy_envelope(payload: Mapping[str, Any]) -> bool:
    """Match Ralph proxy truncated-result envelope schema (mcp-proxy-result.sh)."""
    result_id = payload.get("resultId")
    if not isinstance(result_id, str) or not _PROXY_ENVELOPE_ID_RE.match(result_id):
        return False
    if not isinstance(payload.get("truncated"), bool):
        return False
    if not isinstance(payload.get("preview"), str):
        return False
    if not _is_natural_number(payload.get("originalBytes")):
        return False
    if not _is_natural_number(payload.get("returnedBytes")):
        return False
    breakpoints = payload.get("breakpoints")
    if not isinstance(breakpoints, list):
        return False
    next_actions = payload.get("nextActions")
    if not isinstance(next_actions, list):
        return False
    return True


def _try_parse_proxy_envelope(payload: Any) -> Optional[Dict[str, Any]]:
    if isinstance(payload, Mapping) and _is_proxy_envelope(payload):
        return dict(payload)
    if isinstance(payload, str):
        stripped = payload.strip()
        if not stripped.startswith("{"):
            return None
        try:
            parsed = json.loads(stripped)
        except ValueError:
            return None
        if isinstance(parsed, Mapping) and _is_proxy_envelope(parsed):
            return dict(parsed)
    return None


def _envelope_store_ref(envelope: Mapping[str, Any]) -> str:
    """Minimal stored-result reference for overflow pointers (no preview body)."""
    result_id = envelope.get("resultId")
    if isinstance(result_id, str) and _PROXY_ENVELOPE_ID_RE.match(result_id):
        return json.dumps(
            {"resultId": result_id, "truncated": True},
            separators=(",", ":"),
        )
    return ""


def _normalize_payload_text(payload: Mapping[str, Any]) -> Optional[str]:
    for key in ("content", "output", "text", "message"):
        value = payload.get(key)
        if isinstance(value, str) and value.strip():
            return value
        if isinstance(value, list):
            fragments = _extract_text_fragments(value)
            if fragments:
                return "\n".join(fragment for fragment in fragments if fragment)
    return None


_CODEX_SHELL_ITEM_TYPES = frozenset({"command_execution", "shell_command", "exec"})
_SHELL_FAILURE_STATUSES = frozenset(
    {"failed", "error", "errored", "cancelled", "canceled", "timeout", "declined"}
)
_SHELL_ERROR_TEXT_KEYS = (
    "stderr",
    "aggregated_output",
    "stdout",
    "output",
    "content",
    "text",
    "message",
    "error",
)


def _first_nonempty_line(text: str) -> str:
    for line in text.splitlines():
        stripped = line.strip()
        if stripped:
            return stripped
    return text.strip()


def _shell_item_command(item: Mapping[str, Any]) -> str:
    return _safe_str(item.get("command") or item.get("argv") or "").strip()


def _shell_item_exit_code(item: Mapping[str, Any]) -> Optional[int]:
    for key in ("exit_code", "exitCode", "return_code", "returnCode"):
        value = item.get(key)
        if isinstance(value, bool):
            continue
        if isinstance(value, int):
            return value
        if isinstance(value, str) and value.strip().lstrip("-").isdigit():
            return int(value.strip())
    return None


def _is_codex_shell_item(item: Mapping[str, Any]) -> bool:
    item_type = _safe_str(item.get("type")).strip().lower()
    if item_type in _CODEX_SHELL_ITEM_TYPES:
        return True
    return _shell_item_command(item) != ""


def _shell_item_failed(item: Mapping[str, Any]) -> bool:
    if not _is_codex_shell_item(item):
        return False
    status = _safe_str(item.get("status")).strip().lower()
    if status in _SHELL_FAILURE_STATUSES:
        return True
    exit_code = _shell_item_exit_code(item)
    return exit_code is not None and exit_code != 0


def _shell_item_error_text(item: Mapping[str, Any]) -> str:
    command = _shell_item_command(item)
    for key in _SHELL_ERROR_TEXT_KEYS:
        value = item.get(key)
        if not isinstance(value, str) or not value.strip():
            continue
        first = _first_nonempty_line(value)
        if first and first != command:
            return first
    return ""


def _codex_shell_failure_line(item: Mapping[str, Any]) -> Optional[str]:
    if not _shell_item_failed(item):
        return None
    exit_code = _shell_item_exit_code(item)
    error_text = _shell_item_error_text(item)
    if exit_code is not None and error_text:
        return f"Error (exit {exit_code}): {_truncate(error_text, 160)}"
    if exit_code is not None:
        return f"Error (exit {exit_code})"
    if error_text:
        return f"Error: {_truncate(error_text, 160)}"
    command = _shell_item_command(item)
    if command:
        return f"command failed: {_truncate(command, 160)}"
    return "command failed"


def _flatten_first_string(mapping: Mapping[str, Any], skip_keys: frozenset = frozenset()) -> str:
    for key, value in mapping.items():
        if str(key).lower() in skip_keys:
            continue
        if isinstance(value, str) and value.strip():
            return value
        if isinstance(value, Mapping):
            nested = _flatten_first_string(value, skip_keys)
            if nested:
                return nested
    return ""


def _iter_input_candidates(tool_input: Mapping[str, Any]) -> List[Mapping[str, Any]]:
    """Breadth-first list of dicts that may hold the real tool arguments."""
    out: List[Mapping[str, Any]] = []
    queue: List[Tuple[Mapping[str, Any], int]] = [(tool_input, 0)]
    while queue:
        current, depth = queue.pop(0)
        out.append(current)
        if depth >= 3:
            continue
        for key in _NESTED_INPUT_KEYS:
            nested = current.get(key)
            if isinstance(nested, Mapping):
                queue.append((nested, depth + 1))
    return out


# --- syntax highlighting (homegrown, stdlib only) ----------------------------
#
# A deliberately lightweight, language-agnostic tokenizer. It exists to give the
# diff view visual life, not to be a correct lexer: each line is highlighted
# independently (diff hunks are fragments), so a block comment that spans lines
# may be mis-colored slightly. Tokens are wrapped with a "soft" foreground reset
# (\033[39m) instead of a full reset so the diff background survives underneath.

_NO_HIGHLIGHT = os.environ.get("RALPH_PLAN_PRETTY_NO_HIGHLIGHT") == "1"
_ANSI_ESCAPE_RE = re.compile(r"\033\[[0-9;]*m")
_HUNK_HEADER_RE = re.compile(r"^@@ -(\d+)(?:,\d+)? \+(\d+)(?:,\d+)? @@")
_ANTIGRAVITY_TOOL_CALL_RE = re.compile(r"^\*\s+([\w.]+)\(")

# Map file extension to a language key in _LANG_SPECS.
_LANG_BY_EXT: Dict[str, str] = {
    ".sh": "shell", ".bash": "shell", ".zsh": "shell",
    ".py": "python",
    ".js": "cjs", ".jsx": "cjs", ".ts": "cjs", ".tsx": "cjs",
    ".mjs": "cjs", ".cjs": "cjs",
    ".go": "go",
    ".java": "java",
    ".cs": "csharp",
    ".c": "c", ".h": "c",
    ".cc": "cpp", ".cpp": "cpp", ".cxx": "cpp", ".hpp": "cpp", ".hh": "cpp",
    ".swift": "swift",
    ".m": "objc", ".mm": "objc",
    ".json": "json",
    ".yaml": "yaml", ".yml": "yaml",
    ".md": "markdown", ".markdown": "markdown",
}

_C_BASE_KEYWORDS = frozenset({
    "if", "else", "for", "while", "do", "switch", "case", "default", "break",
    "continue", "return", "goto", "sizeof", "struct", "union", "enum", "typedef",
    "static", "const", "volatile", "extern", "void", "int", "char", "long",
    "short", "unsigned", "signed", "float", "double", "bool", "true", "false",
    "null", "nullptr",
})
_C_BASE_TYPES = frozenset({
    "int", "char", "long", "short", "float", "double", "bool", "void",
    "size_t", "uint8_t", "uint16_t", "uint32_t", "uint64_t", "int8_t",
    "int16_t", "int32_t", "int64_t",
})


def _lang_spec(
    keywords: frozenset,
    *,
    types: frozenset = frozenset(),
    line_comments: Tuple[str, ...] = ("//",),
    block: bool = True,
    strings: str = "\"'",
) -> Dict[str, Any]:
    return {
        "keywords": keywords,
        "types": types,
        "line_comments": line_comments,
        "block": block,
        "strings": strings,
    }


_LANG_SPECS: Dict[str, Dict[str, Any]] = {
    "shell": _lang_spec(
        frozenset({
            "if", "then", "else", "elif", "fi", "for", "while", "until", "do",
            "done", "case", "esac", "in", "function", "return", "local",
            "export", "readonly", "declare", "source", "set", "unset", "echo",
            "printf", "exit", "break", "continue", "shift", "trap",
        }),
        line_comments=("#",),
        block=False,
        strings="\"'`",
    ),
    "python": _lang_spec(
        frozenset({
            "def", "class", "return", "if", "elif", "else", "for", "while",
            "try", "except", "finally", "with", "as", "import", "from", "pass",
            "break", "continue", "raise", "yield", "lambda", "global", "nonlocal",
            "and", "or", "not", "in", "is", "None", "True", "False", "async",
            "await", "assert", "del",
        }),
        types=frozenset({"self", "cls", "int", "str", "float", "bool", "list",
                         "dict", "set", "tuple", "bytes", "object"}),
        line_comments=("#",),
        block=False,
        strings="\"'",
    ),
    "cjs": _lang_spec(
        frozenset({
            "const", "let", "var", "function", "return", "if", "else", "for",
            "while", "do", "switch", "case", "default", "break", "continue",
            "class", "extends", "new", "this", "super", "import", "export",
            "from", "as", "default", "try", "catch", "finally", "throw", "async",
            "await", "yield", "typeof", "instanceof", "in", "of", "delete",
            "void", "null", "undefined", "true", "false", "interface", "type",
            "enum", "implements", "public", "private", "protected", "readonly",
            "static", "abstract",
        }),
        types=frozenset({"string", "number", "boolean", "any", "unknown", "void",
                         "never", "object", "Promise", "Array"}),
        strings="\"'`",
    ),
    "go": _lang_spec(
        frozenset({
            "func", "package", "import", "var", "const", "type", "struct",
            "interface", "map", "chan", "go", "defer", "select", "return", "if",
            "else", "for", "range", "switch", "case", "default", "break",
            "continue", "fallthrough", "goto", "nil", "true", "false", "make",
            "new", "len", "cap", "append",
        }),
        types=_C_BASE_TYPES | frozenset({"string", "byte", "rune", "error",
                                         "uint", "uintptr", "complex64", "complex128"}),
        line_comments=("//",),
    ),
    "java": _lang_spec(
        _C_BASE_KEYWORDS | frozenset({
            "public", "private", "protected", "class", "interface", "extends",
            "implements", "import", "package", "new", "this", "super", "try",
            "catch", "finally", "throw", "throws", "final", "abstract",
            "synchronized", "instanceof", "native", "transient", "var",
        }),
        types=_C_BASE_TYPES | frozenset({"String", "Object", "Integer", "Boolean",
                                         "List", "Map", "Set"}),
    ),
    "csharp": _lang_spec(
        _C_BASE_KEYWORDS | frozenset({
            "public", "private", "protected", "internal", "class", "interface",
            "namespace", "using", "new", "this", "base", "try", "catch",
            "finally", "throw", "var", "string", "object", "async", "await",
            "foreach", "in", "is", "as", "get", "set", "override", "virtual",
            "abstract", "sealed", "readonly", "partial",
        }),
        types=_C_BASE_TYPES | frozenset({"string", "object", "var", "decimal",
                                         "string", "Task", "List", "Dictionary"}),
    ),
    "c": _lang_spec(_C_BASE_KEYWORDS, types=_C_BASE_TYPES, line_comments=("//",)),
    "cpp": _lang_spec(
        _C_BASE_KEYWORDS | frozenset({
            "class", "public", "private", "protected", "namespace", "using",
            "template", "typename", "new", "delete", "this", "try", "catch",
            "throw", "virtual", "override", "final", "operator", "friend",
            "constexpr", "auto", "nullptr", "explicit", "inline",
        }),
        types=_C_BASE_TYPES | frozenset({"string", "vector", "map", "auto",
                                         "wchar_t", "std"}),
        line_comments=("//",),
    ),
    "swift": _lang_spec(
        frozenset({
            "func", "var", "let", "class", "struct", "enum", "protocol",
            "extension", "import", "return", "if", "else", "guard", "for", "in",
            "while", "switch", "case", "default", "break", "continue", "do",
            "try", "catch", "throw", "throws", "defer", "self", "super", "init",
            "deinit", "nil", "true", "false", "public", "private", "internal",
            "fileprivate", "static", "final", "override", "weak", "lazy",
        }),
        types=frozenset({"Int", "String", "Double", "Float", "Bool", "Array",
                         "Dictionary", "Set", "Any", "Void", "Optional"}),
        line_comments=("//",),
    ),
    "objc": _lang_spec(
        _C_BASE_KEYWORDS | frozenset({
            "interface", "implementation", "protocol", "property", "synthesize",
            "end", "class", "selector", "import", "self", "super", "nil", "YES",
            "NO", "id", "instancetype", "strong", "weak", "nonatomic", "atomic",
            "copy", "assign", "readonly", "readwrite",
        }),
        types=_C_BASE_TYPES | frozenset({"id", "NSString", "NSArray",
                                         "NSDictionary", "instancetype", "BOOL"}),
        line_comments=("//",),
    ),
    "json": _lang_spec(
        frozenset({"true", "false", "null"}),
        line_comments=(),
        block=False,
        strings="\"",
    ),
    "yaml": _lang_spec(
        frozenset({"true", "false", "null", "yes", "no", "on", "off"}),
        line_comments=("#",),
        block=False,
        strings="\"'",
    ),
    "markdown": _lang_spec(
        frozenset(),
        line_comments=(),
        block=False,
        strings="`",
    ),
}

_NUMBER_PATTERN = r"\b0[xX][0-9a-fA-F]+\b|\b\d[\d_]*(?:\.\d+)?(?:[eE][+-]?\d+)?\b"
_IDENT_PATTERN = r"[A-Za-z_][A-Za-z0-9_]*"
_LANG_REGEX_CACHE: Dict[str, "re.Pattern[str]"] = {}
_SHELL_TOOL_NAMES = frozenset(
    {
        "bash",
        "shell",
        "command_execution",
        "ralph_proxy_shell",
    }
)


def _lang_regex(lang: str, spec: Mapping[str, Any]) -> "re.Pattern[str]":
    cached = _LANG_REGEX_CACHE.get(lang)
    if cached is not None:
        return cached
    parts: List[str] = []
    line_comments = spec.get("line_comments") or ()
    if line_comments:
        prefixes = "|".join(re.escape(p) for p in line_comments)
        parts.append(rf"(?P<lc>(?:{prefixes})[^\n]*)")
    if spec.get("block"):
        parts.append(r"(?P<bc>/\*.*?\*/|/\*.*)")
    quotes = spec.get("strings") or ""
    str_alts = []
    for quote in quotes:
        q = re.escape(quote)
        str_alts.append(rf"{q}(?:\\.|[^{q}\\])*{q}?")
    if str_alts:
        parts.append(rf"(?P<str>{'|'.join(str_alts)})")
    parts.append(rf"(?P<num>{_NUMBER_PATTERN})")
    parts.append(rf"(?P<ident>{_IDENT_PATTERN})")
    pattern = re.compile("|".join(parts), re.DOTALL)
    _LANG_REGEX_CACHE[lang] = pattern
    return pattern


def _lang_for_path(path: str) -> Optional[str]:
    if not path:
        return None
    _, ext = os.path.splitext(path)
    return _LANG_BY_EXT.get(ext.lower())


def _visible_len(text: str) -> int:
    """Length of a string ignoring ANSI SGR escape sequences."""
    return len(_ANSI_ESCAPE_RE.sub("", text))


def highlight_code_line(
    text: str, lang: Optional[str], palette: Optional[Mapping[str, str]]
) -> str:
    """Return text with syntax tokens wrapped in palette colors (soft fg reset)."""
    if _NO_HIGHLIGHT or not lang or not palette:
        return text
    reset = palette.get("reset") or ""
    if not reset:
        return text
    spec = _LANG_SPECS.get(lang)
    if spec is None:
        return text
    try:
        regex = _lang_regex(lang, spec)
        keywords = spec["keywords"]
        types = spec["types"]
        out: List[str] = []
        pos = 0
        for match in regex.finditer(text):
            start, end = match.span()
            if start > pos:
                out.append(text[pos:start])
            token = match.group()
            kind = match.lastgroup
            color = ""
            if kind == "lc" or kind == "bc":
                color = palette.get("comment", "")
            elif kind == "str":
                color = palette.get("str", "")
            elif kind == "num":
                color = palette.get("num", "")
            elif kind == "ident":
                if token in keywords:
                    color = palette.get("kw", "")
                elif token in types:
                    color = palette.get("type", "")
                else:
                    rest = text[end:]
                    if rest[:1] == "(" or (rest[:1].isspace() and rest.lstrip()[:1] == "("):
                        color = palette.get("func", "")
            if color:
                out.append(f"{color}{token}{reset}")
            else:
                out.append(token)
            pos = end
        if pos < len(text):
            out.append(text[pos:])
        return "".join(out)
    except (re.error, KeyError, IndexError):
        return text


def _looks_like_unified_diff(lines: Sequence[str]) -> bool:
    if not lines:
        return False
    markers = 0
    has_diff_header = False
    for line in lines:
        if line.startswith(("--- ", "+++ ", "@@ ", "@@")):
            has_diff_header = True
            markers += 1
        elif line.startswith(("+", "-")):
            markers += 1
    if markers < 2:
        return False
    # Plain text previews can legitimately start with "-" (for example markdown
    # bullets or YAML list items). Only treat short bodies as diff-like unless we
    # have explicit diff headers.
    if has_diff_header:
        return True
    return len(lines) <= 4


class PrettyRenderer:
    def __init__(
        self,
        mode: str,
        color: bool,
        ascii_only: bool,
        log_path: str,
        color_depth: Optional[int] = None,
    ) -> None:
        self.mode = (mode or "claude").strip().lower()
        self.color = bool(color)
        # color_depth: 0 = no color, 16 = basic ANSI, 256 = 256-color palette.
        # Falls back to 16 when color is on but capability was not detected.
        if color_depth is None:
            color_depth = 16 if self.color else 0
        if not self.color:
            color_depth = 0
        self.color_depth = int(color_depth)
        self.ascii_only = bool(ascii_only)
        self.log_path = log_path
        self.tool_uses: Dict[str, Tuple[str, Dict[str, Any]]] = {}
        self.tool_calls_total = 0
        self.turns_seen = 0
        on = self.color_depth > 0
        self.reset = "\033[0m" if on else ""
        # Soft foreground reset: clears color without dropping a diff background.
        self.softfg = "\033[39m" if on else ""
        self.dim = "\033[2m" if on else ""
        self.bold = "\033[1m" if on else ""
        self.green = self._c("32", "38;5;71")
        self.red = self._c("31", "38;5;167")
        self.cyan = self._c("36", "38;5;80")
        # Semantic tones for tool calls and links.
        self.path = self._c("36", "38;5;37")
        self.toolname = self._c("36", "38;5;81")
        self.arg = self._c("33", "38;5;179")
        self.linkdim = self._c("2", "38;5;244")
        # Diff line markers and backgrounds (backgrounds only at 256-color).
        self.add_fg = self._c("32", "38;5;114")
        self.del_fg = self._c("31", "38;5;174")
        self.bg_add = self._c("", "48;5;22")
        self.bg_del = self._c("", "48;5;52")
        # Syntax token colors (pure SGR colors so the soft fg reset clears them).
        self._syntax_palette = {
            "kw": self._c("35", "38;5;176"),
            "str": self._c("32", "38;5;150"),
            "num": self._c("33", "38;5;179"),
            "comment": self._c("90", "38;5;245"),
            "func": self._c("36", "38;5;81"),
            "type": self._c("33", "38;5;115"),
            "reset": self.softfg,
        }
        self.bullet = "*" if self.ascii_only else "●"
        self.branch = "-" if self.ascii_only else "└"
        self.vbar = "|" if self.ascii_only else "│"
        self.spinner = "~" if self.ascii_only else "⟳"
        self.rule = "-" if self.ascii_only else "─"
        self.width = self._detect_width()
        # Streaming text is buffered so partial fragments coalesce into full
        # lines instead of each delta getting its own bulleted row.
        self._text_buf = ""
        self._text_run_open = False
        self._seen_tool_call_ids: set = set()
        self._opencode_text_progress: Dict[str, str] = {}
        self._seen_plain_warnings: set = set()
        self._plain_prompt_lines: List[str] = []
        self._plain_prompt_collecting = False
        # Consecutive identical tool-call lines share a signature (name, arg)
        # and collapse to one row with (xN) when the run ends.
        self._pending_tool_sig: Optional[Tuple[str, str]] = None
        self._pending_tool_count = 0
    def _c(self, code16: str, code256: str) -> str:
        """Resolve a color to the active depth: 256-color, basic ANSI, or none."""
        if self.color_depth >= 256 and code256:
            return f"\033[{code256}m"
        if self.color_depth >= 16 and code16:
            return f"\033[{code16}m"
        return ""

    @staticmethod
    def _detect_width() -> int:
        try:
            cols = shutil.get_terminal_size((100, 24)).columns
        except (ValueError, OSError):
            cols = 100
        return max(40, min(cols, 120))

    def render_event(self, obj: Any) -> Optional[List[str]]:
        if not isinstance(obj, dict):
            return None
        if self.mode == "claude":
            return self._render_claude(obj)
        if self.mode == "cursor":
            return self._render_cursor(obj)
        if self.mode == "codex":
            return self._render_codex(obj)
        if self.mode == "opencode":
            return self._render_opencode(obj)
        return None

    def render_plain(self, line: str) -> Optional[List[str]]:
        """Render a non-JSON plain line for the TUI; return None to pass through raw."""
        # Rust tracing ERROR lines
        if re.search(r"^\d{4}-\d{2}-\d{2}T\S+\s+ERROR\b", line):
            truncated = _truncate(line, 160)
            if len(line) > len(truncated):
                truncated += f" (full text in {self.log_path})"
            return [f"{self.red}{truncated}{self.reset}"]
        # Rust tracing WARN lines
        if re.search(r"^\d{4}-\d{2}-\d{2}T\S+\s+WARN\b", line):
            return [f"{self.dim}{line}{self.reset}"]
        # Deduplicated warnings
        lower = line.lower()
        is_warning = lower.startswith("warning:")
        is_hook_notice = "--dangerously-bypass-hook-trust' is enabled" in line
        if is_warning or is_hook_notice:
            if line in self._seen_plain_warnings:
                return []
            self._seen_plain_warnings.add(line)
            return [f"{self.dim}{line}{self.reset}"]
        if self.mode == "antigravity":
            match = _ANTIGRAVITY_TOOL_CALL_RE.match(line)
            if match:
                name = match.group(1)
                open_idx = line.find("(")
                close_idx = line.rfind(")")
                arg = line[open_idx + 1 : close_idx] if 0 <= open_idx < close_idx else ""
                return self._queue_tool_line(name, arg.strip())
            return self._buffer_text(line)
        rendered_prompt = self._render_plain_prompt_echo_line(line)
        if rendered_prompt is not None:
            return rendered_prompt
        # Everything else plain (including multi-line stderr continuations)
        return [f"{self.dim}{line}{self.reset}"]

    def flush(self) -> List[str]:
        """Emit any buffered partial text and queued tool-call lines (call at end of stream)."""
        out = self._flush_plain_prompt_echo()
        out.extend(self._flush_text_only())
        out.extend(self._flush_pending_tool_line())
        return out

    def _flush_text_only(self) -> List[str]:
        rest, self._text_buf = self._text_buf, ""
        if not rest.strip():
            return []
        return self._emit_text_line(rest)

    # --- text handling -------------------------------------------------

    def _buffer_text(self, text: str) -> List[str]:
        """Accumulate streamed text; emit only completed lines."""
        self._text_buf += text
        out: List[str] = []
        while "\n" in self._text_buf:
            line, self._text_buf = self._text_buf.split("\n", 1)
            out.extend(self._emit_text_line(line))
        return out

    def _emit_text_line(self, line: str) -> List[str]:
        line = line.rstrip()
        if not line.strip():
            # Blank line: paragraph break, so the next line starts a new bullet.
            self._text_run_open = False
            return []
        out: List[str] = []
        if not self._text_run_open:
            out.extend(self._flush_pending_tool_line())
        wrapped = textwrap.wrap(
            line,
            width=max(20, self.width - 2),
            break_long_words=False,
            break_on_hyphens=False,
        ) or [line.strip()]
        verdict_match = _VERIFICATION_RESULT_RE.search(line)
        if verdict_match is not None:
            verdict_color = (
                self.green
                if verdict_match.group("verdict").upper() == "PASS"
                else self.red
            )
            for idx, piece in enumerate(wrapped):
                prefix = f"{self.bullet} " if idx == 0 else "  "
                out.append(f"{self.bold}{verdict_color}{prefix}{piece}{self.reset}")
            self._text_run_open = False
            return out
        for piece in wrapped:
            if _AGENT_DONE_MARKER in piece:
                out.append(f"{self.bold}{self.green}{self.bullet} {piece}{self.reset}")
                self._text_run_open = False
                continue
            if self._text_run_open:
                out.append(f"  {piece}")
            else:
                out.append(f"{self.cyan}{self.bullet}{self.reset} {piece}")
                self._text_run_open = True
        return out

    def _render_text_block(self, text: str) -> List[str]:
        """Render a complete (non-streamed) text block with its own bullet."""
        text = self._truncate_prompt_echo(text)
        out = self.flush()
        self._text_run_open = False
        if not text.endswith("\n"):
            text += "\n"
        out.extend(self._buffer_text(text))
        return out

    def _render_text_delta(self, text: str) -> List[str]:
        return self._buffer_text(self._truncate_prompt_echo(text))

    def _truncate_prompt_echo(self, text: str) -> str:
        """Collapse echoed run-plan prompt body to a pointer, preserving the TODO statement."""
        if _PROMPT_ECHO_MARKER not in text:
            return text
        head, _, rest = text.partition(_PROMPT_ECHO_MARKER)
        todo_line = ""
        for line in rest.splitlines():
            stripped = line.strip()
            if stripped.startswith("**TODO (line "):
                todo_line = stripped
                break
        note = self._prompt_omission_note(text)
        if todo_line:
            return head + todo_line + "\n" + note + "\n"
        return head + note + "\n"

    def _looks_like_plain_prompt_continuation(self, line: str) -> bool:
        stripped = line.strip()
        if not stripped:
            return True
        if _PROMPT_ECHO_MARKER in line:
            return True
        return any(stripped.startswith(prefix) for prefix in _PLAIN_PROMPT_CONTINUATION_PREFIXES)

    def _emit_collapsed_plain_prompt_echo(self, text: str) -> List[str]:
        collapsed = self._truncate_prompt_echo(text)
        out = self._break_text_run()
        if not collapsed.endswith("\n"):
            collapsed += "\n"
        out.extend(self._buffer_text(collapsed))
        return out

    def _flush_plain_prompt_echo(self) -> List[str]:
        if not self._plain_prompt_lines:
            self._plain_prompt_collecting = False
            return []
        text = "\n".join(self._plain_prompt_lines)
        self._plain_prompt_lines = []
        self._plain_prompt_collecting = False
        if _PROMPT_ECHO_MARKER not in text:
            return [f"{self.dim}{text}{self.reset}"]
        return self._emit_collapsed_plain_prompt_echo(text + "\n")

    def _render_plain_prompt_echo_line(self, line: str) -> Optional[List[str]]:
        """Collapse echoed run-plan prompts streamed as plain lines (OpenCode)."""
        if self._plain_prompt_collecting:
            if self._looks_like_plain_prompt_continuation(line):
                self._plain_prompt_lines.append(line)
                return []
            out = self._flush_plain_prompt_echo()
            out.extend(self.render_plain(line) or [line])
            return out

        if _PROMPT_ECHO_MARKER not in line:
            return None

        _, _, rest = line.partition(_PROMPT_ECHO_MARKER)
        if rest.strip():
            return self._emit_collapsed_plain_prompt_echo(line + ("\n" if not line.endswith("\n") else ""))

        self._plain_prompt_collecting = True
        self._plain_prompt_lines = [line]
        return []

    def _break_text_run(self, *, flush_pending_tool: bool = False) -> List[str]:
        """Flush buffered text before non-text output and reset the bullet run."""
        out = self._flush_text_only()
        if flush_pending_tool:
            out.extend(self._flush_pending_tool_line())
        self._text_run_open = False
        return out

    # --- claude --------------------------------------------------------

    def _render_claude(self, obj: Dict[str, Any]) -> Optional[List[str]]:
        typ = _safe_str(obj.get("type")).strip().lower()
        if typ == "system":
            return []
        if typ == "rate_limit_event":
            return []
        if typ == "assistant":
            self.turns_seen += 1
            return self._render_claude_assistant(obj)
        if typ == "user":
            return self._render_claude_user(obj)
        if typ == "result":
            return self._render_result(obj)
        return None

    def _render_claude_assistant(self, obj: Dict[str, Any]) -> Optional[List[str]]:
        message = obj.get("message")
        if isinstance(message, dict):
            content = message.get("content")
        else:
            content = obj.get("content")
        if isinstance(content, str):
            content = [{"type": "text", "text": content}]
        if not isinstance(content, list):
            return None
        lines: List[str] = []
        pending_text: List[str] = []

        def flush_pending_text() -> None:
            if not pending_text:
                return
            lines.extend(self._render_text_block("\n".join(pending_text)))
            pending_text.clear()

        for block in content:
            if isinstance(block, str):
                pending_text.append(block)
                continue
            if not isinstance(block, dict):
                continue
            block_type = _safe_str(block.get("type")).strip().lower()
            if block_type == "text":
                text = _safe_str(block.get("text"))
                if text:
                    pending_text.append(text)
                continue
            flush_pending_text()
            if block_type == "thinking":
                continue
            if block_type == "tool_use":
                lines.extend(self._render_tool_use(block))
        flush_pending_text()
        return lines or []

    def _render_claude_user(self, obj: Dict[str, Any]) -> Optional[List[str]]:
        message = obj.get("message")
        if isinstance(message, dict):
            content = message.get("content")
        else:
            content = obj.get("content")
        if isinstance(content, str):
            content = [{"type": "tool_result", "content": content, "is_error": obj.get("is_error")}]
        if not isinstance(content, list):
            return None
        lines: List[str] = []
        for block in content:
            if not isinstance(block, dict):
                continue
            if _safe_str(block.get("type")).strip().lower() != "tool_result":
                continue
            tool_name = ""
            for key in ("tool_use_id", "toolUseId"):
                tool_use_id = _safe_str(block.get(key)).strip()
                if tool_use_id:
                    tool_name = self.tool_uses.get(tool_use_id, ("", {}))[0]
                    break
            rendered = self._render_tool_result(block, tool_name=tool_name)
            if rendered:
                lines.extend(rendered)
        return lines or []

    # --- cursor ----------------------------------------------------------

    def _render_cursor(self, obj: Dict[str, Any]) -> Optional[List[str]]:
        typ = _safe_str(obj.get("type")).strip().lower()
        subtype = _safe_str(obj.get("subtype")).strip().lower()
        if typ == "thinking":
            return []
        if typ == "system":
            return []
        if typ == "interaction_query":
            # Internal approval handshake for a tool call that renders on its own.
            return []
        if typ == "result":
            return self._render_result(obj)
        if typ == "tool_call":
            tool_call = obj.get("tool_call")
            if isinstance(tool_call, dict):
                for tool_type, tool_data in tool_call.items():
                    if not isinstance(tool_data, dict):
                        continue
                    return self._render_cursor_tool_call(obj, subtype, tool_type, tool_data)
            return []
        return self._render_text_delta_event(obj)

    def _render_cursor_tool_call(
        self,
        obj: Dict[str, Any],
        subtype: str,
        tool_type: str,
        tool_data: Dict[str, Any],
    ) -> List[str]:
        label = tool_type
        if tool_type == "mcpToolCall":
            real_name = _extract_cursor_mcp_tool_name(tool_data)
            if real_name:
                label = real_name
        elif label.endswith("ToolCall") and len(label) > len("ToolCall"):
            # Cursor native keys: readToolCall -> read, webFetchToolCall -> webFetch.
            label = label[: -len("ToolCall")]
        normalized = _normalize_tool_label(label)
        call_id = _tool_call_id(obj) or _tool_call_id(tool_data)
        if subtype == "completed":
            # The started event already printed the bullet; only surface errors.
            return self._render_cursor_completion(tool_data, tool_name=normalized)
        if call_id:
            if call_id in self._seen_tool_call_ids:
                return []
            self._seen_tool_call_ids.add(call_id)
        out = self._break_text_run()
        self.tool_calls_total += 1
        self._emit_queued_tool_line(out, normalized, self._primary_arg(normalized, tool_data))
        change_lines = self._render_change_block(normalized, tool_data)
        if change_lines:
            self._commit_pending_tool_line(out)
        out.extend(change_lines)
        return out

    def _render_cursor_completion(
        self,
        tool_data: Dict[str, Any],
        *,
        tool_name: str = "",
    ) -> List[str]:
        result = tool_data.get("result")
        if not isinstance(result, dict):
            return []
        out: List[str] = []
        err = result.get("error") or result.get("failure") or result.get("rejected")
        if err is not None:
            if isinstance(err, str):
                message = err
            elif isinstance(err, Mapping):
                message = _flatten_first_string(err) or "tool call failed"
            else:
                message = str(err)
            out.extend(self._break_text_run())
            out.append(f"{self.red}{self.branch} Error: {_truncate(message, 160)}{self.reset}")
        out.extend(self._render_tool_output(result, tool_name=tool_name))
        return out

    # --- codex -----------------------------------------------------------

    def _render_codex(self, obj: Dict[str, Any]) -> Optional[List[str]]:
        typ = _safe_str(obj.get("type")).strip().lower()
        if typ.startswith("thread.") or typ.startswith("turn."):
            return []
        if typ in ("item.started",):
            return []
        if typ == "item.completed":
            item = obj.get("item")
            if isinstance(item, dict):
                label = _codex_item_tool_name(item)
                if label:
                    normalized = _normalize_tool_label(label)
                    out = self._break_text_run()
                    self.tool_calls_total += 1
                    self._emit_queued_tool_line(out, normalized, self._primary_arg(normalized, item))
                    change_lines = self._render_change_block(normalized, item)
                    if change_lines:
                        self._commit_pending_tool_line(out)
                    out.extend(change_lines)
                    shell_failure = _codex_shell_failure_line(item)
                    if shell_failure:
                        out.extend(self._break_text_run())
                        out.append(f"{self.red}{self.branch} {shell_failure}{self.reset}")
                    else:
                        out.extend(self._render_tool_output(item, tool_name=normalized))
                    error = item.get("error")
                    if isinstance(error, str) and error.strip():
                        out.append(f"{self.red}{self.branch} Error: {_truncate(error, 160)}{self.reset}")
                    return out
                item_type = _safe_str(item.get("type")).strip().lower()
                if item_type == "reasoning":
                    return []
                if item_type == "agent_message":
                    text = item.get("text")
                    if isinstance(text, str) and text.strip():
                        return self._render_text_block(text)
                    return []
                if item_type == "file_change":
                    out = self._break_text_run()
                    changes = item.get("changes")
                    if isinstance(changes, list):
                        for change in changes:
                            if isinstance(change, dict):
                                path = _safe_str(change.get("path") or change.get("file_path") or change.get("filePath"))
                                kind = _safe_str(change.get("kind") or change.get("type") or "update")
                                self._emit_queued_tool_line(out, "file_change", f"{kind} {path}")
                                self.tool_calls_total += 1
                    status = _safe_str(item.get("status"))
                    if status:
                        out.append(f"{self.dim}{self.branch} {status}{self.reset}")
                    return out
                if item_type == "error":
                    body = _safe_str(item.get("message") or item.get("error") or item.get("text") or "")
                    if body.strip():
                        out = self._break_text_run()
                        body_lines, stored = self._render_result_body(body, is_error=True)
                        out.extend(body_lines)
                        if stored is not None:
                            plan, result_id = stored
                            out.extend(
                                self._dual_view_link_lines(
                                    plan,
                                    result_id,
                                    include_full=not self._body_has_overflow_full_link(body_lines),
                                )
                            )
                        return out
                    return []
                if item_type == "web_search":
                    query = _safe_str(item.get("query") or item.get("search_query") or "")
                    out = self._break_text_run()
                    self._emit_queued_tool_line(out, "web_search", query)
                    self.tool_calls_total += 1
                    return out
                if item_type == "todo_list":
                    return []
                # Any other unhandled item type: single dim line so extract_text fallback
                # can no longer leak fragments to stdout.
                out = self._break_text_run()
                out.append(f"{self.dim}{self.branch} {item_type}{self.reset}")
                return out
        return self._render_text_delta_event(obj)

    # --- opencode ----------------------------------------------------------

    def _render_opencode(self, obj: Dict[str, Any]) -> Optional[List[str]]:
        typ = _safe_str(obj.get("type")).strip().lower()
        if typ == "system":
            return []
        if typ in {"step_start", "step_finish"} and not isinstance(obj.get("part"), dict):
            return []
        part = obj.get("part")
        if not isinstance(part, dict):
            properties = obj.get("properties")
            if isinstance(properties, dict) and isinstance(properties.get("part"), dict):
                part = properties["part"]
        if isinstance(part, dict):
            part_type = _safe_str(part.get("type")).strip().lower()
            if part_type == "tool":
                return self._render_opencode_tool_part(part)
            if part_type in ("step-start", "step-finish", "snapshot", "patch", "reasoning"):
                return []
            if part_type == "text":
                return self._render_opencode_text_part(part)
            return None
        return self._render_text_delta_event(obj)

    def _render_opencode_tool_part(self, part: Dict[str, Any]) -> List[str]:
        out: List[str] = []
        call_id = _tool_call_id(part)
        first_sighting = not (call_id and call_id in self._seen_tool_call_ids)
        if call_id:
            self._seen_tool_call_ids.add(call_id)
        if first_sighting:
            label = _normalize_tool_label(_pick_tool_label(part, fallback="tool"))
            out.extend(self._break_text_run())
            self.tool_calls_total += 1
            self._emit_queued_tool_line(out, label, self._primary_arg(label, part))
            change_lines = self._render_change_block(label, part)
            if change_lines:
                self._commit_pending_tool_line(out)
            out.extend(change_lines)
        state = part.get("state")
        if isinstance(state, dict):
            status = _safe_str(state.get("status")).strip().lower()
            error = state.get("error")
            if status == "error" and isinstance(error, str) and error.strip():
                out.extend(self._break_text_run())
                out.append(f"{self.red}{self.branch} Error: {_truncate(error, 160)}{self.reset}")
            output = state.get("output")
            payload: Any = output if output is not None else state
            out.extend(self._render_tool_output(payload, tool_name=label))
        return out

    def _render_opencode_text_part(self, part: Dict[str, Any]) -> List[str]:
        text = part.get("text")
        if not isinstance(text, str) or not text:
            return []
        # OpenCode text parts can repeat cumulatively per update; only render
        # the unseen suffix for a given part id.
        part_id = _safe_str(part.get("id"))
        previous = self._opencode_text_progress.get(part_id, "")
        delta = text[len(previous):] if text.startswith(previous) else text
        self._opencode_text_progress[part_id] = text
        if not delta:
            return []
        return self._render_text_delta(delta)

    # --- shared ------------------------------------------------------------

    def _render_tool_use(self, block: Dict[str, Any]) -> List[str]:
        name = _safe_str(block.get("name")).strip() or "tool_use"
        normalized = _normalize_tool_label(name)
        tool_input = block.get("input")
        if not isinstance(tool_input, dict):
            tool_input = {}
        call_id = _tool_call_id(block)
        if call_id:
            self.tool_uses[call_id] = (normalized, dict(tool_input))
        self.tool_calls_total += 1
        out = self._break_text_run()
        self._emit_queued_tool_line(out, normalized, self._primary_arg(normalized, tool_input))
        change_lines = self._render_change_block(normalized, tool_input)
        if change_lines:
            self._commit_pending_tool_line(out)
        out.extend(change_lines)
        return out

    def _render_tool_result(self, block: Dict[str, Any], *, tool_name: str = "") -> List[str]:
        fragments = _extract_text_fragments(block.get("content"))
        if not fragments:
            return []
        body = "\n".join(fragment for fragment in fragments if fragment)
        return self._render_tool_output(
            body,
            is_error=bool(block.get("is_error")),
            tool_name=tool_name,
        )

    def _render_tool_output(
        self,
        payload: Any,
        *,
        is_error: bool = False,
        tool_name: str = "",
    ) -> List[str]:
        preview = self._result_preview_text(payload)
        if not preview.strip():
            return []
        store_text = self._result_store_text(payload)
        link_source = store_text or preview
        envelope = _try_parse_proxy_envelope(payload)
        if envelope is None and isinstance(payload, str):
            envelope = _try_parse_proxy_envelope(payload)
        if envelope is not None:
            link_source = _envelope_store_ref(envelope)
        out = self._break_text_run(flush_pending_tool=True)
        direct_source_read = tool_name.lower() in _DIRECT_SOURCE_READ_TOOL_NAMES
        body_lines, overflow_stored = self._render_result_body(
            preview,
            is_error=is_error,
            store_text=store_text or None,
            store_overflow=not direct_source_read,
        )
        if direct_source_read:
            # The source path is already in the tool-call line.  Do not create
            # a duplicate raw/compacted result-store navigation trail merely
            # to support the TUI preview.
            return out + body_lines
        out.extend(body_lines)
        stored = None
        if _RESULT_STORE is not None:
            stored = _RESULT_STORE.extract_existing_result_ref(link_source)
        if stored is None:
            stored = overflow_stored
        if stored is None and _RESULT_STORE is not None:
            stored = _RESULT_STORE.resolve_or_store(link_source, tool_name=tool_name)
        if stored is not None:
            plan, result_id = stored
            out.extend(
                self._dual_view_link_lines(
                    plan,
                    result_id,
                    include_full=not self._body_has_overflow_full_link(body_lines),
                )
            )
        else:
            link = self._result_link_line(link_source)
            if link:
                out.append(link)
        return out

    def _prompt_omission_note(self, full_prompt: str) -> str:
        if _RESULT_STORE is None:
            return f"... (prompt rules omitted; full prompt in {self.log_path})"
        stored = _RESULT_STORE.resolve_or_store(full_prompt, tool_name="run_plan_pretty")
        if stored is None:
            return f"... (prompt rules omitted; full prompt in {self.log_path})"
        plan, result_id = stored
        return _RESULT_STORE.prompt_omission_pointer(plan, result_id)

    def _overflow_pointer(self, hidden: int, store_text: str) -> Tuple[str, Optional[Tuple[str, str]]]:
        if _RESULT_STORE is None:
            return f"... +{hidden} more lines (full output in {self.log_path})", None
        stored = _RESULT_STORE.resolve_or_store(store_text, tool_name="run_plan_pretty")
        if stored is None:
            return f"... +{hidden} more lines (full output in {self.log_path})", None
        plan, result_id = stored
        return _RESULT_STORE.overflow_pointer(hidden, plan, result_id), stored

    def _render_result_body(
        self,
        body: str,
        *,
        is_error: bool,
        store_text: Optional[str] = None,
        store_overflow: bool = True,
    ) -> Tuple[List[str], Optional[Tuple[str, str]]]:
        body_lines = body.splitlines() or [body]
        visible = [line.rstrip() for line in body_lines if line.rstrip()]
        if not visible:
            return [], None
        body_bytes = len(body.encode("utf-8"))
        budget = (
            _RESULT_BODY_LARGE_BUDGET
            if len(visible) > _RESULT_BODY_LARGE_THRESHOLD
            or body_bytes > _RESULT_BODY_LARGE_BYTE_THRESHOLD
            else _RESULT_BODY_NORMAL_BUDGET
        )
        shown = visible[:budget]
        if (
            len(visible) == 1
            and body_bytes > _RESULT_BODY_LARGE_BYTE_THRESHOLD
            and len(shown[0].encode("utf-8")) > _RESULT_BODY_LARGE_BYTE_THRESHOLD
        ):
            line = shown[0]
            encoded = line.encode("utf-8")
            shown = [encoded[:_RESULT_BODY_LARGE_BYTE_THRESHOLD].decode("utf-8", errors="ignore") + "..."]
        prefix_color = self.red if is_error else self.dim
        first_label = f"Error: {shown[0]}" if is_error else shown[0]
        out = [f"{prefix_color}{self.branch} {first_label}{self.reset}"]
        diff_body = _looks_like_unified_diff(visible)
        for line in shown[1:]:
            out.append(self._result_line(line, diff_body))
        hidden = len(visible) - len(shown)
        stored_ref: Optional[Tuple[str, str]] = None
        if hidden == 0 and body_bytes > _RESULT_BODY_LARGE_BYTE_THRESHOLD:
            if len(visible) > len(shown):
                hidden = len(visible) - len(shown)
            elif body_bytes > len(shown[0].encode("utf-8")):
                hidden = 1
        if hidden > 0:
            if store_overflow:
                full_text = store_text if store_text is not None else body
                pointer, stored_ref = self._overflow_pointer(hidden, full_text)
            else:
                pointer = f"... +{hidden} more lines (source path shown in read call)"
            out.append(f"{self.dim}{self.branch} {pointer}{self.reset}")
        return out, stored_ref

    def _result_store_text(self, payload: Any) -> str:
        envelope = _try_parse_proxy_envelope(payload)
        if envelope is not None:
            return _envelope_store_ref(envelope)
        if isinstance(payload, str):
            nested = _try_parse_proxy_envelope(payload)
            if nested is not None:
                return _envelope_store_ref(nested)
            return payload
        if isinstance(payload, Mapping):
            normalized = _normalize_payload_text(payload)
            if normalized is not None:
                return self._result_store_text(normalized)
            nested = payload.get("success")
            if isinstance(nested, Mapping):
                return self._result_store_text(nested)
            for key in ("content", "output", "text", "message", "preview"):
                value = payload.get(key)
                if isinstance(value, str) and value.strip():
                    return value
        try:
            return json.dumps(payload)
        except (TypeError, ValueError):
            return _safe_str(payload)

    def _result_preview_text(self, payload: Any) -> str:
        envelope = _try_parse_proxy_envelope(payload)
        if envelope is not None:
            return _safe_str(envelope.get("preview"))
        if isinstance(payload, Mapping):
            status_line = self._status_summary(payload)
            nested = payload.get("success")
            if isinstance(nested, Mapping):
                nested_payload: Any = nested
                normalized = _normalize_payload_text(nested)
                if normalized is not None:
                    nested_payload = normalized
                nested_text = self._result_preview_text(nested_payload)
                if status_line and nested_text:
                    nested_lines = nested_text.splitlines()
                    if nested_lines and nested_lines[0] == status_line:
                        return nested_text
                    return "\n".join([status_line] + nested_lines)
                return status_line or nested_text
            normalized = _normalize_payload_text(payload)
            if normalized is not None:
                preview_text = self._result_preview_text(normalized)
                if status_line and preview_text:
                    preview_lines = preview_text.splitlines()
                    if preview_lines and preview_lines[0] != status_line:
                        return "\n".join([status_line] + preview_lines)
                return status_line or preview_text
            preview_text = ""
            for key in ("preview", "content", "output", "text", "message", "summary"):
                value = payload.get(key)
                if isinstance(value, str) and value.strip():
                    preview_text = self._result_preview_text(value)
                    if preview_text:
                        break
            if not preview_text:
                matches = payload.get("matches")
                if isinstance(matches, list):
                    preview_text = self._summarize_list("match", matches)
                files = payload.get("files")
                if not preview_text and isinstance(files, list):
                    preview_text = self._summarize_list("file", files)
            if not preview_text and payload.get("jobId"):
                preview_text = f"job {_safe_str(payload.get('jobId'))}"
            if status_line and preview_text:
                preview_lines = preview_text.splitlines()
                if preview_lines and preview_lines[0] != status_line:
                    return "\n".join([status_line] + preview_lines)
            return status_line or preview_text
        if isinstance(payload, list):
            return self._summarize_list("item", payload)
        if isinstance(payload, str):
            stripped = payload.strip()
            if not stripped:
                return ""
            if stripped.startswith("{") or stripped.startswith("["):
                try:
                    parsed = json.loads(stripped)
                except ValueError:
                    if '"resultId"' in stripped and '"truncated"' in stripped:
                        return ""
                    heuristic = self._heuristic_shell_status_text(stripped)
                    if heuristic is not None:
                        return heuristic
                    return payload
                parsed_preview = self._result_preview_text(parsed)
                if parsed_preview:
                    return parsed_preview
                if isinstance(parsed, Mapping) and _is_proxy_envelope(parsed):
                    return _safe_str(parsed.get("preview"))
                if '"resultId"' in stripped:
                    return ""
            return payload
        return ""

    _STATUS_SUCCESS = frozenset({"completed", "succeeded", "success", "done"})
    _STATUS_FAILURE = frozenset(
        {"failed", "error", "errored", "cancelled", "canceled", "timeout"}
    )
    _STATUS_IN_PROGRESS = frozenset({"running", "pending", "queued", "in_progress"})

    def _colorize_status_word(self, label: str, status: str) -> str:
        if not self.color:
            return label
        if status in self._STATUS_SUCCESS:
            return f"{self.green}{label}{self.dim}"
        if status in self._STATUS_FAILURE:
            return f"{self.red}{label}{self.dim}"
        return label

    def _status_summary(self, payload: Mapping[str, Any]) -> str:
        status = _safe_str(payload.get("status")).strip().lower()
        if not status:
            return ""
        parts = []
        label = status.replace("_", " ")
        if status in self._STATUS_IN_PROGRESS:
            label = f"{self.spinner} {label}"
        else:
            label = self._colorize_status_word(label, status)
        parts.append(label)
        elapsed = payload.get("elapsedSeconds")
        if isinstance(elapsed, (int, float)) and elapsed >= 0:
            parts.append(f"{self._format_duration(int(elapsed) * 1000)} elapsed")
        combined = payload.get("combinedBytes")
        if isinstance(combined, (int, float)) and combined > 0:
            parts.append(f"{self._format_bytes(int(combined))} output")
        return ", ".join(parts)

    _SHELL_STATUS_FIELD_PATTERNS = {
        "jobId": re.compile(r'"jobId"\s*:\s*"([^"]*)'),
        "status": re.compile(r'"status"\s*:\s*"([^"]*)'),
        "elapsedSeconds": re.compile(r'"elapsedSeconds"\s*:\s*([0-9.]+)'),
        "combinedBytes": re.compile(r'"combinedBytes"\s*:\s*([0-9]+)'),
        "preview": re.compile(r'"preview"\s*:\s*"((?:[^"\\]|\\.)*)'),
    }

    def _heuristic_shell_status_text(self, stripped: str) -> Optional[str]:
        """Recover a compact status summary from a truncated/malformed shell-status payload.

        Transport truncation can cut a ralph_proxy_shell_status JSON preview mid-string;
        without this, the raw partial JSON line would otherwise be dumped into the TUI.
        """
        if '"jobId"' not in stripped and '"status"' not in stripped:
            return None
        fields: Dict[str, Any] = {}
        for key, pattern in self._SHELL_STATUS_FIELD_PATTERNS.items():
            match = pattern.search(stripped)
            if not match:
                continue
            raw = match.group(1)
            if key == "elapsedSeconds":
                try:
                    fields[key] = float(raw)
                except ValueError:
                    continue
            elif key == "combinedBytes":
                try:
                    fields[key] = int(raw)
                except ValueError:
                    continue
            elif key == "preview":
                try:
                    fields[key] = json.loads(f'"{raw}"')
                except ValueError:
                    fields[key] = raw
            else:
                fields[key] = raw
        if not fields.get("jobId") and not fields.get("status"):
            return None
        parts = []
        if fields.get("jobId"):
            parts.append(f"job {fields['jobId']}")
        status_line = self._status_summary(fields)
        if status_line:
            parts.append(status_line)
        lines = [" - ".join(parts)] if parts else []
        preview = fields.get("preview")
        if isinstance(preview, str) and preview.strip():
            lines.append(preview)
        return "\n".join(lines) if lines else None

    def _summarize_list(self, singular: str, items: Sequence[Any]) -> str:
        count = len(items)
        if count == 0:
            return f"0 {singular}es" if singular.endswith("ch") else f"0 {singular}s"
        string_items = [item for item in items if isinstance(item, str) and item.strip()]
        if string_items and count <= 3:
            return "\n".join(string_items[:3])
        noun = singular if count == 1 else f"{singular}es" if singular.endswith("ch") else f"{singular}s"
        return f"{count} {noun}"

    @staticmethod
    def _format_bytes(value: int) -> str:
        if value < 1024:
            return f"{value} B"
        units = ("KiB", "MiB", "GiB")
        size = float(value)
        for unit in units:
            size /= 1024.0
            if size < 1024.0 or unit == units[-1]:
                return f"{size:.1f} {unit}"
        return f"{value} B"

    def _render_change_block(self, tool_name: str, tool_input: Mapping[str, Any]) -> List[str]:
        """Render the edit/write content of a tool call as a unified diff block."""
        display = tool_name.split(".")[-1].lower()
        candidates = _iter_input_candidates(tool_input)
        path = self._first_arg_value(candidates, ("path", "file_path", "filePath"))
        lang = _lang_for_path(path)
        lines: List[str] = []
        for candidate in candidates:
            edits = candidate.get("edits")
            if isinstance(edits, list):
                for edit in edits:
                    if isinstance(edit, Mapping):
                        lines.extend(self._diff_pair_lines(edit, lang))
            lines.extend(self._diff_pair_lines(candidate, lang))
            if lines:
                break
        if not lines:
            for candidate in candidates:
                for key in _PATCH_TEXT_KEYS:
                    patch = candidate.get(key)
                    if isinstance(patch, str) and patch.strip():
                        lines.extend(self._colorize_patch_lines(patch, lang))
                        break
                if lines:
                    break
        if not lines and display in _WRITE_TOOL_NAMES:
            for candidate in candidates:
                write_path = self._first_arg_value([candidate], ("path", "file_path", "filePath"))
                write_lang = _lang_for_path(write_path) or lang
                for key in _WRITE_CONTENT_KEYS:
                    content = candidate.get(key)
                    if isinstance(content, str) and content.strip():
                        if write_path:
                            lines.extend(self._render_file_content_diff(write_path, content, write_lang))
                        else:
                            lines.extend(self._render_unified_diff_lines("", content, write_lang))
                        break
                if lines:
                    break
        return self._cap_change_lines(lines)

    def _diff_pair_lines(self, mapping: Mapping[str, Any], lang: Optional[str] = None) -> List[str]:
        old = self._first_arg_value([mapping], _CHANGE_OLD_KEYS)
        new = self._first_arg_value([mapping], _CHANGE_NEW_KEYS)
        if not old and not new:
            return []
        return self._render_unified_diff_lines(old, new, lang)

    def _render_unified_diff_lines(
        self, old: str, new: str, lang: Optional[str] = None
    ) -> List[str]:
        diff_lines = list(
            difflib.unified_diff(
                old.splitlines(),
                new.splitlines(),
                fromfile="before",
                tofile="after",
                n=2,
                lineterm="",
            )
        )
        if not diff_lines:
            return []
        if not self._diff_fancy_enabled():
            return self._legacy_unified_diff(diff_lines)
        return self._fancy_unified_diff(diff_lines, lang)

    def _diff_fancy_enabled(self) -> bool:
        """Gutter + background diff styling needs color and unicode box chars."""
        return self.color_depth > 0 and not self.ascii_only

    def _legacy_unified_diff(self, diff_lines: Sequence[str]) -> List[str]:
        out: List[str] = []
        for line in diff_lines:
            if line.startswith(("--- ", "+++ ")):
                continue
            if line.startswith("@@"):
                out.append(f"{self.dim}{self.branch} {line}{self.reset}")
                continue
            if line.startswith("+"):
                out.append(f"{self.green}+ {line[1:]}{self.reset}")
                continue
            if line.startswith("-"):
                out.append(f"{self.red}- {line[1:]}{self.reset}")
                continue
            if line.startswith(" "):
                out.append(f"{self.dim}{self.branch} {line[1:]}{self.reset}")
                continue
            out.append(f"{self.dim}{self.branch} {line}{self.reset}")
        return out

    def _fancy_unified_diff(
        self, diff_lines: Sequence[str], lang: Optional[str]
    ) -> List[str]:
        out: List[str] = []
        old_no = new_no = 0
        for line in diff_lines:
            if line.startswith(("--- ", "+++ ")):
                continue
            if line.startswith("@@"):
                match = _HUNK_HEADER_RE.match(line)
                if match:
                    old_no = int(match.group(1))
                    new_no = int(match.group(2))
                out.append(self._diff_hunk_header(line))
                continue
            if line.startswith("+"):
                out.append(self._diff_line_fancy("add", line[1:], new_no, lang))
                new_no += 1
                continue
            if line.startswith("-"):
                out.append(self._diff_line_fancy("del", line[1:], old_no, lang))
                old_no += 1
                continue
            content = line[1:] if line.startswith(" ") else line
            out.append(self._diff_line_fancy("ctx", content, new_no, lang))
            old_no += 1
            new_no += 1
        return out

    def _diff_hunk_header(self, line: str) -> str:
        return f"{self.dim}{self.branch} {line}{self.reset}"

    def _diff_line_fancy(
        self, kind: str, content: str, lineno: Optional[int], lang: Optional[str]
    ) -> str:
        gutter = f"{lineno:>4}" if lineno is not None else "    "
        highlighted = highlight_code_line(content, lang, self._syntax_palette)
        if kind == "ctx":
            return (
                f"{self.dim}{gutter}{self.reset} "
                f"{self.dim}{self.vbar}{self.reset} {highlighted}{self.reset}"
            )
        bg = self.bg_add if kind == "add" else self.bg_del
        fg = self.add_fg if kind == "add" else self.del_fg
        marker = "+" if kind == "add" else "-"
        body = f"{fg}{marker}{self.softfg} {highlighted}"
        if bg:
            # Pad the background to a solid block; +5 = gutter(4) + leading space.
            visible = 2 + len(content)
            pad = " " * max(0, (self.width - 5) - visible)
            return f"{self.dim}{gutter}{self.reset} {bg}{body}{pad}{self.reset}"
        return f"{self.dim}{gutter}{self.reset} {body}{self.reset}"

    def _render_file_content_diff(
        self, path: str, content: str, lang: Optional[str] = None
    ) -> List[str]:
        try:
            with open(path, "r", encoding="utf-8", errors="replace") as handle:
                old_content = handle.read()
        except OSError:
            old_content = ""
        if lang is None:
            lang = _lang_for_path(path)
        lines = self._render_unified_diff_lines(old_content, content, lang)
        if lines:
            return lines
        if self._diff_fancy_enabled():
            return [
                self._diff_line_fancy("add", line, None, lang)
                for line in content.splitlines()
            ]
        return [f"{self.green}+ {line}{self.reset}" for line in content.splitlines()]

    def _colorize_patch_lines(
        self, patch: str, lang: Optional[str] = None
    ) -> List[str]:
        fancy = self._diff_fancy_enabled()
        out: List[str] = []
        for line in patch.splitlines():
            if line.startswith("@@"):
                out.append(self._diff_hunk_header(line))
            elif line.startswith("+") and not line.startswith("+++"):
                out.append(
                    self._diff_line_fancy("add", line[1:], None, lang)
                    if fancy else f"{self.green}{line}{self.reset}"
                )
            elif line.startswith("-") and not line.startswith("---"):
                out.append(
                    self._diff_line_fancy("del", line[1:], None, lang)
                    if fancy else f"{self.red}{line}{self.reset}"
                )
            elif fancy:
                content = line[1:] if line.startswith(" ") else line
                out.append(self._diff_line_fancy("ctx", content, None, lang))
            else:
                out.append(f"{self.dim}{line}{self.reset}")
        return out

    def _cap_change_lines(self, lines: List[str]) -> List[str]:
        if len(lines) > _CHANGE_BLOCK_MAX_LINES:
            hidden = len(lines) - _CHANGE_BLOCK_MAX_LINES
            return lines[:_CHANGE_BLOCK_MAX_LINES] + [
                f"{self.dim}... +{hidden} more change lines{self.reset}"
            ]
        return lines

    def _body_has_overflow_full_link(self, body_lines: List[str]) -> bool:
        return any("more lines" in line and "full output:" in line for line in body_lines)

    def _dual_view_link_lines(
        self,
        plan: str,
        result_id: str,
        *,
        include_full: bool = True,
    ) -> List[str]:
        if _RESULT_STORE is None:
            return []
        out: List[str] = []
        out.append(
            (
                f"{self.linkdim}{self.branch} {_RESULT_STORE.compact_view_pointer(plan, result_id)}"
                f"{self.reset}"
            )
        )
        if include_full:
            out.append(
                f"{self.linkdim}{self.branch} {_RESULT_STORE.full_output_pointer(plan, result_id)}"
                f"{self.reset}"
            )
        return out

    def _result_link_line(self, text: str) -> Optional[str]:
        """Link to the stored full tool output when an envelope resultId is present."""
        stored = None
        if _RESULT_STORE is not None:
            stored = _RESULT_STORE.extract_existing_result_ref(text)
        if stored is not None:
            plan, result_id = stored
            return (
                f"{self.linkdim}{self.branch} {_RESULT_STORE.full_output_pointer(plan, result_id)}"
                f"{self.reset}"
            )
        match = _RESULT_ID_RE.search(text)
        if not match:
            return None
        namespace = (
            os.environ.get("RALPH_PLAN_KEY")
            or os.environ.get("RALPH_ARTIFACT_NS")
            or "default"
        )
        result_id = match.group(1)
        path = f".ralph-workspace/tool-results/{namespace}/results/{result_id}.txt"
        return (
            f"{self.linkdim}{self.branch} full output: {path}; "
            f"ralph_proxy_result_read resultId={result_id}{self.reset}"
        )

    def _render_result(self, obj: Dict[str, Any]) -> List[str]:
        out = self._break_text_run(flush_pending_tool=True)
        rule = f"{self.dim}{self.rule * 60}{self.reset}"
        turns = int(obj.get("num_turns") or self.turns_seen or 0)
        duration_ms = int(obj.get("duration_ms") or 0)
        parts = []
        if turns:
            parts.append(f"{turns} turns")
        parts.append(f"{self.tool_calls_total} tool calls")
        parts.append(self._format_duration(duration_ms))
        recap = "Done: " + ", ".join(parts)
        color = self.red if obj.get("is_error") else self.green
        out.extend([rule, f"{color}{recap}{self.reset}"])
        return out

    def _render_text_delta_event(self, obj: Dict[str, Any]) -> Optional[List[str]]:
        for key in ("text", "message", "output", "final", "content"):
            value = obj.get(key)
            if isinstance(value, str) and value.strip():
                return self._render_text_delta(value)
        message = obj.get("message")
        if isinstance(message, dict):
            fragments = _extract_text_fragments(message.get("content"))
            if fragments:
                out: List[str] = []
                for fragment in fragments:
                    out.extend(self._render_text_delta(fragment))
                return out
        return None

    def _tool_line(self, name: str, arg: str) -> str:
        rendered_name = f"{self.bold}{self.toolname}{name}{self.reset}"
        if arg:
            rendered_arg = self._render_tool_arg(name, arg)
            return f"{self.green}{self.bullet}{self.reset} {rendered_name}({rendered_arg})"
        return f"{self.green}{self.bullet}{self.reset} {rendered_name}"

    @staticmethod
    def _looks_like_path(arg: str) -> bool:
        if not arg or " " in arg.strip():
            return False
        return "/" in arg or "." in os.path.basename(arg)

    def _render_tool_arg(self, name: str, arg: str) -> str:
        if self._looks_like_shell_command(name):
            highlighted = highlight_code_line(arg, "shell", self._syntax_palette)
            if highlighted != arg:
                return highlighted
        # Path-like args read in teal; everything else in amber.
        arg_color = self.path if self._looks_like_path(arg) else self.arg
        return f"{arg_color}{arg}{self.reset}"

    @staticmethod
    def _looks_like_shell_command(name: str) -> bool:
        return name.split(".")[-1].lower() in _SHELL_TOOL_NAMES

    def _format_tool_line(self, name: str, arg: str, count: int = 1) -> str:
        line = self._tool_line(name, arg)
        if count > 1:
            return f"{line} {self.dim}(x{count}){self.reset}"
        return line

    def _flush_pending_tool_line(self) -> List[str]:
        if self._pending_tool_sig is None:
            return []
        name, arg = self._pending_tool_sig
        count = self._pending_tool_count
        self._pending_tool_sig = None
        self._pending_tool_count = 0
        return [self._format_tool_line(name, arg, count)]

    def _queue_tool_line(self, name: str, arg: str) -> List[str]:
        sig = (name, arg)
        if self._pending_tool_sig == sig:
            self._pending_tool_count += 1
            return []
        out = self._flush_pending_tool_line()
        self._pending_tool_sig = sig
        self._pending_tool_count = 1
        return out

    def _emit_queued_tool_line(self, out: List[str], name: str, arg: str) -> None:
        out.extend(self._queue_tool_line(name, arg))

    def _commit_pending_tool_line(self, out: List[str]) -> None:
        out.extend(self._flush_pending_tool_line())

    def _result_line(self, line: str, diff_body: bool) -> str:
        if diff_body and line.startswith("+"):
            return f"{self.green}{self.branch} {line}{self.reset}"
        if diff_body and line.startswith("-"):
            return f"{self.red}{self.branch} {line}{self.reset}"
        return f"{self.dim}{self.branch} {line}{self.reset}"

    def _primary_arg(self, tool_name: str, tool_input: Mapping[str, Any]) -> str:
        display = tool_name.split(".")[-1]
        candidates = _iter_input_candidates(tool_input)
        if display == "ralph_proxy_batch":
            summary = self._batch_operation_summary(candidates)
            if summary:
                return summary
        if display.startswith("ralph_proxy_"):
            value = self._first_arg_value(candidates, ("path", "file_path", "filePath", "query", "pattern", "command"))
            if value:
                return _truncate(_display_path(value))
        if display == "TodoWrite":
            for candidate in candidates:
                items = candidate.get("todos") or candidate.get("items")
                if isinstance(items, list):
                    return f"{len(items)} items"
                count = candidate.get("item_count")
                if count is not None:
                    return f"{count} items"
        keys = _PRIMARY_ARG_KEYS.get(display)
        if keys:
            value = self._first_arg_value(candidates, keys)
            if value:
                return _truncate(_display_path(value))
        value = self._first_arg_value(candidates, _GENERIC_ARG_KEYS)
        if value:
            return _truncate(_display_path(value))
        for candidate in candidates:
            fallback = _flatten_first_string(candidate, _ARG_METADATA_KEYS)
            if fallback:
                return _truncate(_display_path(fallback))
        return ""

    def _batch_operation_summary(self, candidates: Sequence[Mapping[str, Any]]) -> str:
        for candidate in candidates:
            operations = candidate.get("operations")
            if not isinstance(operations, list):
                continue
            names: List[str] = []
            for operation in operations:
                if not isinstance(operation, Mapping):
                    continue
                raw_tool = operation.get("tool")
                if isinstance(raw_tool, str) and raw_tool.strip():
                    names.append(_normalize_tool_label(raw_tool))
            if not names:
                return f"{len(operations)} operations"
            visible = names[:_BATCH_OPERATION_DISPLAY_LIMIT]
            hidden = max(0, len(names) - len(visible))
            summary = ", ".join(visible)
            if hidden:
                summary += f", +{hidden} more"
            return _truncate(summary, 120)
        return ""

    @staticmethod
    def _first_arg_value(candidates: Sequence[Mapping[str, Any]], keys: Sequence[str]) -> str:
        for candidate in candidates:
            for key in keys:
                value = candidate.get(key)
                if isinstance(value, str) and value.strip():
                    return value
        return ""

    def _format_duration(self, duration_ms: int) -> str:
        total_seconds = max(0, int(duration_ms / 1000))
        minutes, seconds = divmod(total_seconds, 60)
        hours, minutes = divmod(minutes, 60)
        if hours:
            return f"{hours}h {minutes}m {seconds}s"
        if minutes:
            return f"{minutes}m {seconds}s"
        return f"{seconds}s"
