#!/usr/bin/env python3
"""Remove only recognized Ralph JSON/JSONC/TOML entries from runtime configs.

Exit 0: stdout is the rewritten config (at least one Ralph entry removed).
Exit 2: no recognized Ralph entry; stdout empty so the caller keeps bytes.
Exit 1: error.
"""
from __future__ import annotations

import json
import os
import re
import sys
from typing import NamedTuple


RESERVED_MCP_IDS = ("ralph",)


class Token(NamedTuple):
    kind: str
    start: int
    end: int
    value: str


def _fail(message: str) -> None:
    sys.stderr.write(message + "\n")
    raise SystemExit(1)


def _read_text(path: str) -> str:
    try:
        with open(path, encoding="utf-8") as fh:
            return fh.read()
    except FileNotFoundError:
        _fail(f"Error: config not found: {path}")
    except OSError as exc:
        _fail(f"Error: cannot read {path}: {exc}")
    return ""


def _strip_jsonc(text: str) -> str:
    out: list[str] = []
    i = 0
    n = len(text)
    in_string = False
    escape = False
    in_line_comment = False
    in_block_comment = False
    while i < n:
        ch = text[i]
        nxt = text[i + 1] if i + 1 < n else ""
        if in_line_comment:
            if ch == "\n":
                in_line_comment = False
                out.append(ch)
            i += 1
            continue
        if in_block_comment:
            if ch == "*" and nxt == "/":
                in_block_comment = False
                i += 2
            else:
                i += 1
            continue
        if in_string:
            out.append(ch)
            if escape:
                escape = False
            elif ch == "\\":
                escape = True
            elif ch == '"':
                in_string = False
            i += 1
            continue
        if ch == '"':
            in_string = True
            out.append(ch)
            i += 1
            continue
        if ch == "/" and nxt == "/":
            in_line_comment = True
            i += 2
            continue
        if ch == "/" and nxt == "*":
            in_block_comment = True
            i += 2
            continue
        out.append(ch)
        i += 1
    return "".join(out)


def _load_json_text(text: str, path: str) -> tuple[object, bool]:
    try:
        return json.loads(text), False
    except json.JSONDecodeError:
        pass
    try:
        return json.loads(_strip_jsonc(text)), True
    except json.JSONDecodeError as exc:
        _fail(f"Error: invalid JSON in {path}: {exc}")
    return {}, False


def _collect_commands(value: object, commands: set[str]) -> None:
    if isinstance(value, dict):
        command = value.get("command")
        if isinstance(command, str) and command:
            commands.add(command)
            commands.add(os.path.basename(command))
        for child in value.values():
            _collect_commands(child, commands)
    elif isinstance(value, list):
        for child in value:
            _collect_commands(child, commands)


def _is_ralph_command(command: object, reserved: set[str]) -> bool:
    if not isinstance(command, str) or not command:
        return False
    if command in reserved:
        return True
    base = os.path.basename(command)
    return base in reserved


def _is_ralph_hook_entry(value: object, reserved: set[str]) -> bool:
    if not isinstance(value, dict):
        return False
    return _is_ralph_command(value.get("command"), reserved)


def _remove_hooks(value: object, reserved: set[str]) -> bool:
    changed = False
    if isinstance(value, list):
        kept = []
        for entry in value:
            if _is_ralph_hook_entry(entry, reserved):
                changed = True
                continue
            if _remove_hooks(entry, reserved):
                changed = True
            if isinstance(entry, dict):
                inner = entry.get("hooks")
                if isinstance(inner, list) and not inner and "matcher" in entry:
                    changed = True
                    continue
            kept.append(entry)
        if len(kept) != len(value):
            changed = True
        value[:] = kept
    elif isinstance(value, dict):
        for child in value.values():
            if _remove_hooks(child, reserved):
                changed = True
    return changed


def _mcp_contains_reserved(data: object) -> bool:
    if not isinstance(data, dict):
        return False
    for key in ("mcpServers", "mcp"):
        servers = data.get(key)
        if isinstance(servers, dict):
            for name in RESERVED_MCP_IDS:
                if name in servers:
                    return True
    return False


def _remove_mcp(data: object) -> bool:
    if not isinstance(data, dict):
        return False
    changed = False
    for key in ("mcpServers", "mcp"):
        servers = data.get(key)
        if not isinstance(servers, dict):
            continue
        for name in RESERVED_MCP_IDS:
            if name in servers:
                del servers[name]
                changed = True
    return changed


def _hooks_template(bundle_root: str, runtime: str) -> str:
    if runtime == "claude":
        return os.path.join(bundle_root, ".claude", "settings.json")
    if runtime == "cursor":
        return os.path.join(bundle_root, ".cursor", "hooks.json")
    if runtime == "codex":
        return os.path.join(bundle_root, ".codex", "hooks.json")
    if runtime == "antigravity":
        return os.path.join(bundle_root, ".agents", "hooks.json")
    _fail(f"Error: JSON hook removal is not implemented for runtime {runtime}")
    return ""


def _tokenize_jsonc(text: str) -> list[Token]:
    tokens: list[Token] = []
    i = 0
    n = len(text)
    while i < n:
        ch = text[i]
        nxt = text[i + 1] if i + 1 < n else ""
        if ch in " \t\r\n":
            start = i
            i += 1
            while i < n and text[i] in " \t\r\n":
                i += 1
            tokens.append(Token("ws", start, i, text[start:i]))
            continue
        if ch == "/" and nxt == "/":
            start = i
            i += 2
            while i < n and text[i] != "\n":
                i += 1
            tokens.append(Token("comment", start, i, text[start:i]))
            continue
        if ch == "/" and nxt == "*":
            start = i
            i += 2
            while i < n - 1 and not (text[i] == "*" and text[i + 1] == "/"):
                i += 1
            i = min(n, i + 2)
            tokens.append(Token("comment", start, i, text[start:i]))
            continue
        if ch == '"':
            start = i
            i += 1
            escape = False
            while i < n:
                cur = text[i]
                if escape:
                    escape = False
                elif cur == "\\":
                    escape = True
                elif cur == '"':
                    i += 1
                    break
                i += 1
            tokens.append(Token("string", start, i, text[start:i]))
            continue
        if ch in "{}[]:,":
            tokens.append(Token("punct", i, i + 1, ch))
            i += 1
            continue
        if ch.isdigit() or ch == "-" or ch == ".":
            start = i
            i += 1
            while i < n and text[i] in "0123456789.eE+-":
                i += 1
            tokens.append(Token("number", start, i, text[start:i]))
            continue
        if ch.isalpha() or ch == "_":
            start = i
            i += 1
            while i < n and (text[i].isalnum() or text[i] == "_"):
                i += 1
            tokens.append(Token("ident", start, i, text[start:i]))
            continue
        tokens.append(Token("other", i, i + 1, ch))
        i += 1
    return tokens


def _next_sig(tokens: list[Token], index: int) -> int:
    while index < len(tokens) and tokens[index].kind in ("ws", "comment"):
        index += 1
    return index


def _decode_json_string(token: Token) -> str:
    try:
        value = json.loads(token.value)
    except json.JSONDecodeError:
        return token.value[1:-1]
    if isinstance(value, str):
        return value
    return token.value[1:-1]


def _skip_jsonc_value(tokens: list[Token], index: int) -> int:
    index = _next_sig(tokens, index)
    if index >= len(tokens):
        _fail("Error: unexpected end of JSONC value")
    tok = tokens[index]
    if tok.kind in ("string", "number", "ident"):
        return index + 1
    if tok.kind == "punct" and tok.value in ("{", "["):
        opener = tok.value
        closer = "}" if opener == "{" else "]"
        depth = 1
        index += 1
        while index < len(tokens) and depth:
            cur = tokens[index]
            if cur.kind == "punct":
                if cur.value == opener:
                    depth += 1
                elif cur.value == closer:
                    depth -= 1
            index += 1
        if depth:
            _fail("Error: unclosed JSONC value")
        return index
    _fail(f"Error: unexpected JSONC token {tok.value!r}")
    return index


def _jsonc_remove_reserved_mcp(text: str) -> str:
    tokens = _tokenize_jsonc(text)
    deletions: list[tuple[int, int]] = []
    i = 0
    stack: list[str] = []
    pending_name = ""

    def parent_is_mcp() -> bool:
        return bool(stack) and stack[-1] in ("mcp", "mcpServers")

    while i < len(tokens):
        i = _next_sig(tokens, i)
        if i >= len(tokens):
            break
        tok = tokens[i]
        if tok.kind == "punct" and tok.value == "{":
            stack.append(pending_name)
            pending_name = ""
            i += 1
            continue
        if tok.kind == "punct" and tok.value == "[":
            stack.append("[")
            pending_name = ""
            i += 1
            continue
        if tok.kind == "punct" and tok.value in ("}", "]"):
            if stack:
                stack.pop()
            pending_name = ""
            i += 1
            continue
        if tok.kind == "string":
            colon = _next_sig(tokens, i + 1)
            if (
                colon < len(tokens)
                and tokens[colon].kind == "punct"
                and tokens[colon].value == ":"
                and stack
                and stack[-1] != "["
            ):
                key = _decode_json_string(tok)
                value_start = colon + 1
                if parent_is_mcp() and key in RESERVED_MCP_IDS:
                    value_end = _skip_jsonc_value(tokens, value_start)
                    start = tok.start
                    end = tokens[value_end - 1].end
                    after = _next_sig(tokens, value_end)
                    if (
                        after < len(tokens)
                        and tokens[after].kind == "punct"
                        and tokens[after].value == ","
                    ):
                        end = tokens[after].end
                    else:
                        before = i - 1
                        while before >= 0 and tokens[before].kind in ("ws", "comment"):
                            before -= 1
                        if (
                            before >= 0
                            and tokens[before].kind == "punct"
                            and tokens[before].value == ","
                        ):
                            start = tokens[before].start
                    deletions.append((start, end))
                    i = value_end
                    continue
                sig = _next_sig(tokens, value_start)
                if (
                    sig < len(tokens)
                    and tokens[sig].kind == "punct"
                    and tokens[sig].value in ("{", "[")
                ):
                    pending_name = key
                    i = sig
                    continue
                i = _skip_jsonc_value(tokens, value_start)
                continue
        i += 1

    if not deletions:
        return text
    deletions.sort()
    out: list[str] = []
    cursor = 0
    for start, end in deletions:
        if start < cursor:
            continue
        out.append(text[cursor:start])
        cursor = end
    out.append(text[cursor:])
    return "".join(out)


def _dump_json(data: object) -> str:
    return json.dumps(data, indent=2) + "\n"


def _remove_mcp_text(text: str, path: str) -> tuple[bool, str]:
    data, is_jsonc = _load_json_text(text, path)
    if not _mcp_contains_reserved(data):
        return False, text
    if is_jsonc:
        rewritten = _jsonc_remove_reserved_mcp(text)
        if rewritten == text:
            _fail(f"Error: failed to surgically remove Ralph MCP entry from JSONC: {path}")
        parsed, _ = _load_json_text(rewritten, path)
        if _mcp_contains_reserved(parsed):
            _fail(f"Error: Ralph MCP entry remained after JSONC removal: {path}")
        return True, rewritten
    _remove_mcp(data)
    return True, _dump_json(data)


_TOML_RALPH_TABLE = re.compile(
    r"^\[mcp_servers\.ralph(?:\.[^\]]*)?\]\s*$"
)


def _toml_contains_ralph(text: str) -> bool:
    if not text.strip():
        return False
    try:
        import tomllib
    except ImportError:
        tomllib = None  # type: ignore[assignment]
    if tomllib is not None:
        try:
            data = tomllib.loads(text)
        except tomllib.TOMLDecodeError as exc:
            _fail(f"Error: invalid TOML: {exc}")
        servers = data.get("mcp_servers")
        return isinstance(servers, dict) and "ralph" in servers
    for line in text.splitlines():
        if _TOML_RALPH_TABLE.match(line.strip()):
            return True
    return False


def _remove_toml_ralph(text: str) -> tuple[bool, str]:
    if not _toml_contains_ralph(text):
        return False, text
    lines = text.splitlines(keepends=True)
    out: list[str] = []
    skipping = False
    changed = False
    for line in lines:
        stripped = line.strip()
        if stripped.startswith("[") and stripped.endswith("]"):
            if _TOML_RALPH_TABLE.match(stripped):
                skipping = True
                changed = True
                continue
            skipping = False
        if skipping:
            continue
        out.append(line)
    rewritten = "".join(out)
    if not changed:
        _fail("Error: failed to surgically remove Ralph MCP tables from Codex TOML")
    if _toml_contains_ralph(rewritten):
        _fail("Error: Ralph MCP entry remained after Codex TOML removal")
    return True, rewritten


def main(argv: list[str]) -> int:
    if len(argv) != 5:
        _fail("Usage: setup-remove-json.py <hooks|mcp> <path> <bundle-root> <runtime>")
    mode, path, bundle_root, runtime = argv[1:]
    text = _read_text(path)
    if mode == "mcp":
        if runtime == "codex":
            changed, rewritten = _remove_toml_ralph(text)
        else:
            changed, rewritten = _remove_mcp_text(text, path)
    elif mode == "hooks":
        data, is_jsonc = _load_json_text(text, path)
        template_path = _hooks_template(bundle_root, runtime)
        template, _ = _load_json_text(_read_text(template_path), template_path)
        reserved: set[str] = set()
        _collect_commands(template, reserved)
        if not reserved:
            _fail(f"Error: no reserved Ralph hook commands in {template_path}")
        changed = _remove_hooks(data, reserved)
        if not changed:
            return 2
        if is_jsonc:
            _fail(f"Error: JSONC hook removal is not implemented for runtime {runtime}")
        rewritten = _dump_json(data)
    else:
        _fail(f"Error: unknown removal mode: {mode}")

    if not changed:
        return 2
    sys.stdout.write(rewritten)
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
