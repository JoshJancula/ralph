#!/usr/bin/env python3
"""Validate and redact agent mcp_servers declarations.

Used by the canonical frontmatter parser and agent-config-tool.sh.
Parses only the constrained mcp_servers schema with no external dependencies.
"""

from __future__ import annotations

import json
import os
import re
import sys
from pathlib import Path

REDACTED = "***REDACTED***"
RESERVED_NAMES = {"ralph"}
ALLOWED_TRANSPORTS = {"stdio", "http"}
CREDENTIAL_KEY_RE = re.compile(r"(?i)(token|secret|key|password|api_key|apikey|auth|credential|bearer)")
ENV_REF_RE = re.compile(r"^\$\{[A-Z_][A-Z0-9_]*\}$")
SECRET_VALUE_RE = re.compile(r"(?i)(sk-|Bearer\s+|Basic\s+|ghp_|gho_|key-)")


def _fail(message: str) -> None:
    print(message, file=sys.stderr)
    sys.exit(1)


def _env_json_string_array(var_name: str) -> list[str] | None:
    raw = os.environ.get(var_name)
    if not raw:
        return None
    try:
        data = json.loads(raw)
    except json.JSONDecodeError:
        return None
    if not isinstance(data, list):
        return None
    out: list[str] = []
    for item in data:
        if isinstance(item, str) and item.strip():
            out.append(item.strip())
    return out


def _warn_unresolved_mcp_servers(normalized: list[dict[str, object]]) -> None:
    """
    Optional WARN behavior driven by env vars.

    The caller (bash read_mcp_servers) sets:
      - RALPH_AGENT_ID: agent identifier to print in WARN
      - RALPH_RESOLVED_MCP_SERVERS_JSON: JSON array of configured MCP server names
    """
    agent_id = os.environ.get("RALPH_AGENT_ID") or os.environ.get("AGENT_ID") or ""
    available = _env_json_string_array("RALPH_RESOLVED_MCP_SERVERS_JSON")
    if not agent_id or available is None:
        return
    available_set = set(available)
    for entry in normalized:
        name = entry.get("name")
        if not isinstance(name, str) or not name.strip():
            continue
        if entry.get("reference") is True and name not in available_set:
            print(
                f"WARN: agent {agent_id} declares mcp server '{name}' but it is not configured",
                file=sys.stderr,
            )


def _unquote(value: str) -> str:
    value = value.strip()
    if len(value) >= 2 and value[0] == '"' and value[-1] == '"':
        value = value[1:-1]
        value = value.replace('\\"', '"').replace('\\\\', '\\')
    elif len(value) >= 2 and value[0] == "'" and value[-1] == "'":
        value = value[1:-1]
    return value


def _parse_inline_array(value: str) -> list[str]:
    value = value.strip()
    if not (value.startswith('[') and value.endswith(']')):
        raise ValueError(f"invalid inline array: {value}")
    inner = value[1:-1]
    if not inner.strip():
        return []
    items: list[str] = []
    current = []
    in_quote = None
    for ch in inner:
        if ch in ('"', "'"):
            if in_quote is None:
                in_quote = ch
            elif in_quote == ch:
                in_quote = None
            current.append(ch)
        elif ch == ',' and in_quote is None:
            items.append(_unquote(''.join(current)))
            current = []
        else:
            current.append(ch)
    if current or inner.strip().endswith(','):
        items.append(_unquote(''.join(current)))
    return items


def _parse_inline_map(value: str) -> dict[str, str]:
    value = value.strip()
    if not (value.startswith('{') and value.endswith('}')):
        raise ValueError(f"invalid inline map: {value}")
    inner = value[1:-1]
    if not inner.strip():
        return {}
    result: dict[str, str] = {}
    current = []
    in_quote = None
    key: str | None = None
    for ch in inner:
        if ch in ('"', "'"):
            if in_quote is None:
                in_quote = ch
            elif in_quote == ch:
                in_quote = None
            current.append(ch)
        elif ch == ':' and in_quote is None and key is None:
            key = _unquote(''.join(current)).strip()
            current = []
        elif ch == ',' and in_quote is None:
            if key is None:
                raise ValueError(f"invalid inline map: {value}")
            result[key] = _unquote(''.join(current)).strip()
            key = None
            current = []
        else:
            current.append(ch)
    if key is not None:
        result[key] = _unquote(''.join(current)).strip()
    return result


def _parse_key_value(content: str) -> tuple[str, str | None] | None:
    content = content.rstrip()
    m = re.match(r'^([A-Za-z0-9_\-]+):\s*(.*)$', content)
    if not m:
        return None
    key = m.group(1)
    value = m.group(2).strip()
    if not value:
        return key, None
    return key, _unquote(value)


def _extract_frontmatter(text: str) -> list[str]:
    lines = text.splitlines()
    if not lines or lines[0].strip() != '---':
        return []
    end = None
    for i in range(1, len(lines)):
        if lines[i].strip() == '---':
            end = i
            break
    if end is None:
        return []
    return lines[1:end]


def _parse_mcp_frontmatter(fm_lines: list[str]) -> list[dict | str]:
    start = None
    for idx, line in enumerate(fm_lines):
        if re.match(r'^( *)mcp_servers:\s*$', line):
            start = idx
            break
    if start is None:
        return []
    return _parse_mcp_list(fm_lines, start + 1)


def _line_indent(line: str) -> tuple[int, str]:
    stripped = line.rstrip()
    if not stripped:
        return -1, ''
    indent = len(stripped) - len(stripped.lstrip())
    return indent, stripped


def _parse_mcp_list(lines: list[str], start: int) -> list[dict | str]:
    items: list[dict | str] = []
    i = start
    n = len(lines)
    list_indent: int | None = None
    while i < n:
        indent, stripped = _line_indent(lines[i])
        if indent < 0:
            i += 1
            continue
        if list_indent is None:
            if stripped.lstrip().startswith('- '):
                list_indent = indent
            else:
                i += 1
                continue
        if indent < list_indent:
            break
        if indent > list_indent:
            i += 1
            continue
        content = stripped.lstrip()[2:].strip()
        if not content:
            i += 1
            continue
        kv = _parse_key_value(content)
        if kv:
            key, value = kv
            obj: dict[str, object] = {key: value}
            obj, i = _parse_object_fields(lines, i, list_indent, obj)
            items.append(obj)
        else:
            items.append(_unquote(content))
            i += 1
    return items


def _parse_object_fields(lines: list[str], idx: int, list_indent: int, obj: dict[str, object]) -> tuple[dict[str, object], int]:
    i = idx + 1
    n = len(lines)
    field_indent: int | None = None
    while i < n:
        indent, stripped = _line_indent(lines[i])
        if indent < 0:
            i += 1
            continue
        if indent <= list_indent:
            break
        if field_indent is None:
            field_indent = indent
        if indent < field_indent:
            break
        if indent > field_indent:
            i += 1
            continue
        content = stripped[field_indent:]
        kv = _parse_key_value(content)
        if not kv:
            i += 1
            continue
        key, value = kv
        if value is None and key in ('args', 'env', 'headers'):
            nested, i = _parse_nested_block(lines, i, field_indent, key)
            obj[key] = nested
        elif value is not None:
            obj[key] = _coerce_inline_value(key, value)
            i += 1
        else:
            i += 1
    return obj, i


def _coerce_inline_value(key: str, value: object) -> object:
    if value is None:
        return value
    if isinstance(value, str):
        v = value.strip()
        if v.startswith('['):
            try:
                return _parse_inline_array(v)
            except ValueError:
                pass
        if v.startswith('{'):
            try:
                return _parse_inline_map(v)
            except ValueError:
                pass
    return value


def _parse_nested_block(lines: list[str], idx: int, field_indent: int, key: str) -> tuple[object, int]:
    i = idx + 1
    n = len(lines)
    child_indent: int | None = None
    if key == 'args':
        items: list[str] = []
        while i < n:
            indent, stripped = _line_indent(lines[i])
            if indent < 0:
                i += 1
                continue
            if indent <= field_indent:
                break
            if child_indent is None:
                if stripped.lstrip().startswith('- '):
                    child_indent = indent
                else:
                    break
            if indent < child_indent:
                break
            if indent == child_indent and stripped.lstrip().startswith('- '):
                items.append(_unquote(stripped.lstrip()[2:].strip()))
                i += 1
            else:
                break
        return items, i
    else:
        result: dict[str, str] = {}
        while i < n:
            indent, stripped = _line_indent(lines[i])
            if indent < 0:
                i += 1
                continue
            if indent <= field_indent:
                break
            if child_indent is None:
                child_indent = indent
            if indent < child_indent:
                break
            if indent > child_indent:
                i += 1
                continue
            content = stripped[child_indent:]
            kv = _parse_key_value(content)
            if kv:
                k, v = kv
                result[k] = v if v is not None else ''
                i += 1
            else:
                break
        return result, i


def _is_literal_secret(value: str) -> bool:
    if not value or ENV_REF_RE.match(value):
        return False
    if SECRET_VALUE_RE.search(value):
        return True
    if re.match(r'^[A-Za-z0-9_\-]{24,}$', value):
        return True
    if re.match(r'^[A-Za-z0-9+/=]{24,}$', value):
        return True
    return False


def _check_env_ref(context: str, value: str) -> None:
    if '${' in value or (value.startswith('$') and not value.startswith('${')):
        if not ENV_REF_RE.match(value):
            raise ValueError(f"malformed environment reference in mcp_servers {context}: {value}")


def _check_dotenv_ref(context: str, value: str) -> None:
    if '.env' in value:
        raise ValueError(f"mcp_servers {context} must not reference .env* files: {value}")


def _validate_mcp_servers(data: object) -> list[dict[str, object]]:
    if not isinstance(data, list):
        raise ValueError("mcp_servers must be an array")
    names: set[str] = set()
    normalized: list[dict[str, object]] = []
    for entry in data:
        if isinstance(entry, str):
            name = entry.strip()
            if not name:
                raise ValueError("mcp_servers string reference cannot be empty")
            if name in RESERVED_NAMES:
                raise ValueError(f"mcp_servers name '{name}' is reserved")
            if name in names:
                raise ValueError(f"duplicate mcp_servers name: {name}")
            names.add(name)
            normalized.append({"name": name, "reference": True})
            continue
        if not isinstance(entry, dict):
            raise ValueError("mcp_servers entries must be strings or objects")
        name_value = entry.get("name")
        if not isinstance(name_value, str) or not name_value.strip():
            raise ValueError("mcp_servers object must have a non-empty string name")
        name = name_value.strip()
        if name in RESERVED_NAMES:
            raise ValueError(f"mcp_servers name '{name}' is reserved")
        if name in names:
            raise ValueError(f"duplicate mcp_servers name: {name}")
        names.add(name)
        if entry.get("reference") is True:
            allowed_fields = {"name", "reference"}
            extra = sorted(set(entry.keys()) - allowed_fields)
            if extra:
                raise ValueError(f"unsupported field(s) {extra} for mcp_servers reference '{name}'")
            normalized.append({"name": name, "reference": True})
            continue
        transport = entry.get("transport")
        if not isinstance(transport, str) or transport not in ALLOWED_TRANSPORTS:
            raise ValueError(
                f"unsupported transport '{transport}' for mcp_servers entry '{name}'; "
                f"must be one of {sorted(ALLOWED_TRANSPORTS)}"
            )
        allowed_fields = {"name", "transport"}
        if transport == "stdio":
            allowed_fields |= {"command", "args", "env"}
        else:
            allowed_fields |= {"url", "headers"}
        extra = sorted(set(entry.keys()) - allowed_fields)
        if extra:
            raise ValueError(f"unsupported field(s) {extra} for mcp_servers entry '{name}'")
        if transport == "stdio":
            command = entry.get("command")
            if not isinstance(command, str) or not command.strip():
                raise ValueError(f"mcp_servers stdio entry '{name}' requires a non-empty command")
            _check_dotenv_ref(f"command '{name}'", command)
            args = entry.get("args")
            if args is not None:
                if not isinstance(args, list):
                    raise ValueError(f"mcp_servers args for '{name}' must be an array")
                for idx, a in enumerate(args):
                    if not isinstance(a, str):
                        raise ValueError(f"mcp_servers args[{idx}] for '{name}' must be a string")
                    if a == '':
                        raise ValueError(f"mcp_servers args[{idx}] for '{name}' cannot be empty")
                    _check_dotenv_ref(f"args[{idx}] '{name}'", a)
            env = entry.get("env")
            if env is not None:
                if not isinstance(env, dict):
                    raise ValueError(f"mcp_servers env for '{name}' must be an object")
                for k, v in env.items():
                    if not isinstance(k, str) or not k.strip():
                        raise ValueError(f"mcp_servers env key for '{name}' must be a non-empty string")
                    if k.startswith('.') and k.lower().startswith('.env'):
                        raise ValueError(f"mcp_servers env key for '{name}' must not reference .env* files: {k}")
                    if '.env' in k:
                        raise ValueError(f"mcp_servers env key for '{name}' must not reference .env* files: {k}")
                    if not isinstance(v, str):
                        raise ValueError(f"mcp_servers env value for '{name}.{k}' must be a string")
                    if v == '':
                        raise ValueError(f"mcp_servers env value for '{name}.{k}' cannot be empty")
                    _check_env_ref(f"env '{name}.{k}'", v)
                    _check_dotenv_ref(f"env '{name}.{k}'", v)
                    if CREDENTIAL_KEY_RE.search(k) and not ENV_REF_RE.match(v):
                        raise ValueError(
                            f"mcp_servers env value for '{name}.{k}' appears to be a literal credential; "
                            f"use ${{ENV_VAR}} references only"
                        )
        else:  # http
            url = entry.get("url")
            if not isinstance(url, str) or not url.strip():
                raise ValueError(f"mcp_servers http entry '{name}' requires a non-empty url")
            if url.startswith('file://') or '.env' in url:
                raise ValueError(f"mcp_servers http url for '{name}' must not reference local files or .env")
            headers = entry.get("headers")
            if headers is not None:
                if not isinstance(headers, dict):
                    raise ValueError(f"mcp_servers headers for '{name}' must be an object")
                for k, v in headers.items():
                    if not isinstance(k, str) or not k.strip():
                        raise ValueError(f"mcp_servers header key for '{name}' must be a non-empty string")
                    if '.env' in k:
                        raise ValueError(f"mcp_servers header key for '{name}' must not reference .env* files: {k}")
                    if not isinstance(v, str):
                        raise ValueError(f"mcp_servers header value for '{name}.{k}' must be a string")
                    if v == '':
                        raise ValueError(f"mcp_servers header value for '{name}.{k}' cannot be empty")
                    _check_env_ref(f"header '{name}.{k}'", v)
                    _check_dotenv_ref(f"header '{name}.{k}'", v)
                    if CREDENTIAL_KEY_RE.search(k) and not ENV_REF_RE.match(v):
                        raise ValueError(
                            f"mcp_servers header value for '{name}.{k}' appears to be a literal credential; "
                            f"use ${{ENV_VAR}} references only"
                        )
        normalized.append({"name": name, "transport": transport, **entry})
    return normalized


def _redact_mcp_servers(data: list[dict[str, object]]) -> list[dict[str, object]]:
    out: list[dict[str, object]] = []
    for entry in data:
        redacted = dict(entry)
        env = redacted.get("env")
        if isinstance(env, dict):
            redacted["env"] = {k: REDACTED for k in env}
        headers = redacted.get("headers")
        if isinstance(headers, dict):
            redacted["headers"] = {k: REDACTED for k in headers}
        out.append(redacted)
    return out


def _load_config_json(path: str) -> dict:
    with open(path, encoding='utf-8') as fh:
        return json.load(fh)


def _load_frontmatter(path: str) -> list[dict | str]:
    text = Path(path).read_text(encoding='utf-8')
    fm = _extract_frontmatter(text)
    return _parse_mcp_frontmatter(fm)


def cmd_validate_config(path: str) -> None:
    data = _load_config_json(path)
    if "mcp_servers" not in data:
        return
    try:
        _validate_mcp_servers(data["mcp_servers"])
    except ValueError as e:
        _fail(str(e))


def cmd_redact_config(path: str) -> None:
    data = _load_config_json(path)
    if "mcp_servers" not in data:
        print(json.dumps([]))
        return
    normalized = _validate_mcp_servers(data["mcp_servers"])
    _warn_unresolved_mcp_servers(normalized)
    print(json.dumps(_redact_mcp_servers(normalized), indent=2))


def cmd_frontmatter(path: str) -> None:
    items = _load_frontmatter(path)
    if not items:
        return
    try:
        normalized = _validate_mcp_servers(items)
    except ValueError as e:
        _fail(str(e))
    _warn_unresolved_mcp_servers(normalized)
    for entry in normalized:
        print(json.dumps(entry, separators=(',', ':')))


def main(argv: list[str]) -> None:
    if len(argv) < 2:
        _fail("Usage: agent-config-mcp.py {--validate-config|--redact-config|--frontmatter} <path>")
    cmd = argv[0]
    path = argv[1]
    if cmd == '--validate-config':
        cmd_validate_config(path)
    elif cmd == '--redact-config':
        cmd_redact_config(path)
    elif cmd == '--frontmatter':
        cmd_frontmatter(path)
    else:
        _fail(f"unknown command: {cmd}")


if __name__ == '__main__':
    main(sys.argv[1:])
