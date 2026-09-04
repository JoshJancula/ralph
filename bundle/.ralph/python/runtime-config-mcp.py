#!/usr/bin/env python3
"""Resolve effective runtime MCP catalogs from native ambient sources and Ralph."""

from __future__ import annotations

import json
import os
import re
import sys
from copy import deepcopy
from pathlib import Path
from typing import Any

REDACTED = "***REDACTED***"
RESERVED_RALPH = "ralph"
ENV_REF_RE = re.compile(r"^\$\{[A-Z_][A-Z0-9_]*\}$")
ENV_REF_SUB_RE = re.compile(r"\$\{([A-Z_][A-Z0-9_]*)\}")

# Per-runtime ambient MCP sources in native precedence order (later overrides earlier).
RUNTIME_SOURCE_SPECS: dict[str, list[tuple[str, str]]] = {
    "cursor": [
        ("user", "{home}/.cursor/mcp.json"),
        ("project", "{project}/.cursor/mcp.json"),
    ],
    "claude": [
        ("user", "{home}/.claude.json"),
        ("user", "{home}/.claude/.mcp.json"),
        ("project", "{project}/.mcp.json"),
        ("local", "{project}/.claude/settings.local.json"),
    ],
    "codex": [
        ("user", "{home}/.codex/config.toml"),
        ("project", "{project}/.codex/config.toml"),
    ],
    "opencode": [
        ("user", "{xdg}/opencode/config.json"),
        ("user", "{xdg}/opencode/config.jsonc"),
        ("user", "{xdg}/opencode/opencode.json"),
        ("user", "{xdg}/opencode/opencode.jsonc"),
        ("project", "{project}/opencode.json"),
        ("project", "{project}/opencode.jsonc"),
        ("project", "{project}/.opencode/opencode.json"),
        ("project", "{project}/.opencode/opencode.jsonc"),
    ],
    "antigravity": [
        ("user", "{home}/.agents/mcp_config.json"),
        ("project", "{project}/.agents/mcp_config.json"),
    ],
}


class McpResolveError(Exception):
    def __init__(
        self,
        message: str,
        *,
        runtime: str = "",
        reason: str = "",
        server: str = "",
        env_var: str = "",
        searched_paths: list[str] | None = None,
    ) -> None:
        super().__init__(message)
        self.message = message
        self.reason = reason or message
        self.runtime = runtime
        self.server = server
        self.env_var = env_var
        self.searched_paths = searched_paths or []


def _expand_path(template: str, project: str, home: str, xdg: str) -> str:
    return (
        template.replace("{project}", project)
        .replace("{home}", home)
        .replace("{xdg}", xdg)
    )


def _load_json_file(path: str) -> dict[str, Any]:
    with open(path, encoding="utf-8") as fh:
        return json.load(fh)


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


def _load_jsonish_file(path: str) -> dict[str, Any]:
    text = Path(path).read_text(encoding="utf-8")
    try:
        return json.loads(text)
    except json.JSONDecodeError:
        cleaned = _strip_jsonc(text)
        return json.loads(cleaned)


def _load_toml_file(path: str) -> dict[str, Any]:
    try:
        import tomllib
    except ImportError as exc:
        raise McpResolveError(f"tomllib required to read Codex config: {path}") from exc
    with open(path, "rb") as fh:
        return tomllib.load(fh)


def _as_str_list(value: Any) -> list[str]:
    if value is None:
        return []
    if isinstance(value, list):
        return [str(v) for v in value if v is not None and str(v) != ""]
    if isinstance(value, str) and value.strip():
        return [value.strip()]
    return []


def _as_str_map(value: Any) -> dict[str, str]:
    if not isinstance(value, dict):
        return {}
    out: dict[str, str] = {}
    for key, val in value.items():
        if not isinstance(key, str) or not key.strip():
            continue
        if val is None:
            continue
        out[key] = str(val)
    return out


def _infer_transport(entry: dict[str, Any]) -> str:
    if isinstance(entry.get("url"), str) and entry["url"].strip():
        return "http"
    if isinstance(entry.get("type"), str) and entry["type"].strip().lower() in ("http", "remote", "sse"):
        return "http"
    return "stdio"


def _normalize_json_server(name: str, entry: dict[str, Any], origin: str, source_path: str) -> dict[str, Any]:
    transport = _infer_transport(entry)
    command = entry.get("command")
    if isinstance(command, list):
        args = [str(x) for x in command[1:]]
        command = str(command[0]) if command else ""
    else:
        args = _as_str_list(entry.get("args"))
        command = str(command).strip() if isinstance(command, str) else ""
    env = _as_str_map(entry.get("env") or entry.get("environment"))
    headers = _as_str_map(entry.get("headers"))
    url = str(entry.get("url") or "").strip()
    if transport == "http":
        if not url:
            raise McpResolveError(f"ambient MCP server '{name}' in {source_path} requires a url")
    else:
        if not command:
            raise McpResolveError(f"ambient MCP server '{name}' in {source_path} requires a command")
    return {
        "name": name,
        "transport": transport,
        "command": command,
        "args": args,
        "env": env,
        "headers": headers,
        "url": url,
        "origin": origin,
        "source_path": source_path,
        "layer": "ambient",
    }


def _extract_json_mcp_servers(data: dict[str, Any], origin: str, source_path: str) -> dict[str, dict[str, Any]]:
    servers = data.get("mcpServers")
    if servers is None and origin == "local":
        servers = data.get("mcp_servers")
    if not isinstance(servers, dict):
        return {}
    out: dict[str, dict[str, Any]] = {}
    for name, entry in servers.items():
        if not isinstance(name, str) or not name.strip():
            continue
        if name.strip() == RESERVED_RALPH:
            continue
        if not isinstance(entry, dict):
            raise McpResolveError(
                f"invalid MCP server entry for '{name}' in {source_path}",
                server=name,
            )
        out[name.strip()] = _normalize_json_server(name.strip(), entry, origin, source_path)
    return out


def _extract_opencode_mcp(data: dict[str, Any], origin: str, source_path: str) -> dict[str, dict[str, Any]]:
    mcp = data.get("mcp")
    if not isinstance(mcp, dict):
        return {}
    out: dict[str, dict[str, Any]] = {}
    for name, entry in mcp.items():
        if not isinstance(name, str) or not name.strip():
            continue
        if name.strip() == RESERVED_RALPH:
            continue
        if not isinstance(entry, dict):
            raise McpResolveError(
                f"invalid OpenCode MCP entry for '{name}' in {source_path}",
                server=name,
            )
        entry_type = str(entry.get("type") or "local").strip().lower()
        if entry_type in ("remote", "http", "sse"):
            url = str(entry.get("url") or "").strip()
            if not url:
                raise McpResolveError(
                    f"OpenCode MCP server '{name}' in {source_path} requires a url",
                    server=name,
                )
            out[name.strip()] = {
                "name": name.strip(),
                "transport": "http",
                "command": "",
                "args": [],
                "env": _as_str_map(entry.get("environment") or entry.get("env")),
                "headers": _as_str_map(entry.get("headers")),
                "url": url,
                "origin": origin,
                "source_path": source_path,
                "layer": "ambient",
            }
        else:
            command = entry.get("command")
            if isinstance(command, list) and command:
                cmd = str(command[0])
                args = [str(x) for x in command[1:]]
            else:
                cmd = str(command or "").strip()
                args = _as_str_list(entry.get("args"))
            if not cmd:
                raise McpResolveError(
                    f"OpenCode MCP server '{name}' in {source_path} requires a command",
                    server=name,
                )
            out[name.strip()] = {
                "name": name.strip(),
                "transport": "stdio",
                "command": cmd,
                "args": args,
                "env": _as_str_map(entry.get("environment") or entry.get("env")),
                "headers": {},
                "url": "",
                "origin": origin,
                "source_path": source_path,
                "layer": "ambient",
            }
    return out


def _extract_codex_mcp(data: dict[str, Any], origin: str, source_path: str) -> dict[str, dict[str, Any]]:
    servers = data.get("mcp_servers")
    if not isinstance(servers, dict):
        return {}
    out: dict[str, dict[str, Any]] = {}
    for name, entry in servers.items():
        if not isinstance(name, str) or not name.strip():
            continue
        if name.strip() == RESERVED_RALPH:
            continue
        if not isinstance(entry, dict):
            raise McpResolveError(
                f"invalid Codex MCP server entry for '{name}' in {source_path}",
                server=name,
            )
        url = str(entry.get("url") or "").strip()
        if url:
            out[name.strip()] = {
                "name": name.strip(),
                "transport": "http",
                "command": "",
                "args": [],
                "env": _as_str_map(entry.get("env")),
                "headers": _as_str_map(entry.get("headers")),
                "url": url,
                "origin": origin,
                "source_path": source_path,
                "layer": "ambient",
            }
        else:
            command = str(entry.get("command") or "").strip()
            args = _as_str_list(entry.get("args"))
            if not command:
                raise McpResolveError(
                    f"Codex MCP server '{name}' in {source_path} requires command or url",
                    server=name,
                )
            out[name.strip()] = {
                "name": name.strip(),
                "transport": "stdio",
                "command": command,
                "args": args,
                "env": _as_str_map(entry.get("env")),
                "headers": {},
                "url": "",
                "origin": origin,
                "source_path": source_path,
                "layer": "ambient",
            }
    return out


def _read_ambient_from_path(runtime: str, path: str, origin: str) -> dict[str, dict[str, Any]]:
    if not os.path.isfile(path):
        return {}
    try:
        if runtime == "codex":
            data = _load_toml_file(path)
            return _extract_codex_mcp(data, origin, path)
        if runtime == "opencode":
            data = _load_jsonish_file(path)
            return _extract_opencode_mcp(data, origin, path)
        data = _load_jsonish_file(path)
        return _extract_json_mcp_servers(data, origin, path)
    except json.JSONDecodeError as exc:
        raise McpResolveError(f"invalid JSON in ambient MCP config {path}: {exc}") from exc
    except McpResolveError:
        raise
    except Exception as exc:
        raise McpResolveError(f"failed to read ambient MCP config {path}: {exc}") from exc


def _merge_ambient(runtime: str, project_root: str, home: str, xdg: str) -> tuple[dict[str, dict[str, Any]], list[str]]:
    specs = RUNTIME_SOURCE_SPECS.get(runtime, [])
    catalog: dict[str, dict[str, Any]] = {}
    sources: list[str] = []
    seen_paths: set[str] = set()
    for origin, template in specs:
        path = os.path.abspath(_expand_path(template, project_root, home, xdg))
        label = f"{origin}:{path}"
        sources.append(label)
        if path in seen_paths:
            continue
        seen_paths.add(path)
        found = _read_ambient_from_path(runtime, path, origin)
        for name, entry in found.items():
            catalog[name] = entry
    return catalog, sources


def _ralph_server_definition(server_script: str, workspace: str, env_extra: dict[str, str] | None = None) -> dict[str, Any]:
    env = {
        "RALPH_MCP_WORKSPACE": workspace,
        "RALPH_MODE": os.environ.get("RALPH_MODE", "no"),
    }
    if env_extra:
        for key, value in env_extra.items():
            if key and value is not None:
                env[key] = value
    return {
        "name": RESERVED_RALPH,
        "transport": "stdio",
        "command": "bash",
        "args": [server_script],
        "env": env,
        "headers": {},
        "url": "",
        "origin": "ralph",
        "source_path": "",
        "layer": "ralph",
    }


def _resolve_env_value(value: str, server_name: str, field: str) -> str:
    if ENV_REF_RE.match(value):
        var = value[2:-1]
        resolved = os.environ.get(var)
        if resolved is None or resolved == "":
            raise McpResolveError(
                f"missing environment variable {var} for MCP server '{server_name}' {field}",
                server=server_name,
                env_var=var,
                reason="missing_env_var",
            )
        return resolved
    if "${" in value:
        def repl(match: re.Match[str]) -> str:
            var = match.group(1)
            resolved = os.environ.get(var)
            if resolved is None or resolved == "":
                raise McpResolveError(
                    f"missing environment variable {var} for MCP server '{server_name}' {field}",
                    server=server_name,
                    env_var=var,
                    reason="missing_env_var",
                )
            return resolved
        return ENV_REF_SUB_RE.sub(repl, value)
    return value


def _resolve_server_env(server: dict[str, Any]) -> dict[str, Any]:
    resolved = deepcopy(server)
    name = str(resolved.get("name") or "")
    env = _as_str_map(resolved.get("env"))
    resolved["env"] = {
        key: _resolve_env_value(val, name, f"env.{key}") for key, val in env.items()
    }
    headers = _as_str_map(resolved.get("headers"))
    resolved["headers"] = {
        key: _resolve_env_value(val, name, f"headers.{key}") for key, val in headers.items()
    }
    return resolved


def _redact_server(server: dict[str, Any]) -> dict[str, Any]:
    out = {
        "name": server.get("name"),
        "transport": server.get("transport"),
        "origin": server.get("origin"),
        "layer": server.get("layer"),
    }
    if server.get("command"):
        out["command"] = server.get("command")
    if server.get("args"):
        out["args"] = server.get("args")
    if server.get("url"):
        out["url"] = server.get("url")
    env = _as_str_map(server.get("env"))
    if env:
        out["env"] = {k: REDACTED for k in env}
    headers = _as_str_map(server.get("headers"))
    if headers:
        out["headers"] = {k: REDACTED for k in headers}
    return out


def _to_runtime_shape(runtime: str, catalog: dict[str, dict[str, Any]]) -> dict[str, Any]:
    if runtime in ("cursor", "claude", "antigravity"):
        servers: dict[str, Any] = {}
        for name, server in sorted(catalog.items()):
            if server["transport"] == "http":
                entry: dict[str, Any] = {
                    "url": server["url"],
                    "headers": deepcopy(server.get("headers") or {}),
                }
            else:
                entry = {
                    "command": server["command"],
                    "args": list(server.get("args") or []),
                    "env": deepcopy(server.get("env") or {}),
                }
            if runtime in ("cursor", "antigravity"):
                entry["type"] = "stdio" if server["transport"] == "stdio" else "http"
            servers[name] = entry
        return {"mcpServers": servers}
    if runtime == "opencode":
        mcp: dict[str, Any] = {}
        for name, server in sorted(catalog.items()):
            if server["transport"] == "http":
                mcp[name] = {
                    "type": "remote",
                    "url": server["url"],
                    "enabled": True,
                    "headers": deepcopy(server.get("headers") or {}),
                    "environment": deepcopy(server.get("env") or {}),
                }
            else:
                cmd = [server["command"], *list(server.get("args") or [])]
                mcp[name] = {
                    "type": "local",
                    "command": cmd,
                    "enabled": True,
                    "environment": deepcopy(server.get("env") or {}),
                }
        return {"mcp": mcp}
    if runtime == "codex":
        servers = {}
        for name, server in sorted(catalog.items()):
            if server["transport"] == "http":
                servers[name] = {
                    "url": server["url"],
                    "headers": deepcopy(server.get("headers") or {}),
                    "env": deepcopy(server.get("env") or {}),
                }
            else:
                servers[name] = {
                    "command": server["command"],
                    "args": list(server.get("args") or []),
                    "env": deepcopy(server.get("env") or {}),
                }
        return {"mcp_servers": servers}
    raise McpResolveError(f"unsupported runtime '{runtime}' for MCP overlay")


def _needs_ralph(ralph_mode: str, tool_access: str) -> bool:
    mode = (ralph_mode or "no").strip().lower()
    access = (tool_access or "").strip().lower()
    return mode in ("ralph", "hybrid") or access == "ralph"


def resolve_effective_mcp(request: dict[str, Any]) -> dict[str, Any]:
    runtime = str(request.get("runtime") or "").strip().lower()
    project_root = os.path.abspath(str(request.get("project_root") or ""))
    agent_entries = request.get("agent_mcp_servers")
    if agent_entries not in (None, [], ""):
        raise McpResolveError(
            "agent_mcp_servers / profile MCP layer is removed; "
            "native ambient MCP then Ralph's protected server. "
            "Use ralph migrate agents-to-roles",
            runtime=runtime,
            reason="removed_profile_mcp_layer",
        )
    if "ralph_mode" in request:
        ralph_mode = str(request.get("ralph_mode") or "no")
    else:
        ralph_mode = str(os.environ.get("RALPH_MODE", "no"))
    if "tool_access" in request:
        tool_access = str(request.get("tool_access") or "")
    else:
        tool_access = str(os.environ.get("RALPH_AGENT_TOOL_ACCESS", ""))
    server_script = str(request.get("ralph_server_script") or "").strip()
    workspace = str(request.get("workspace") or project_root).strip()
    home = str(request.get("home") or os.environ.get("RALPH_RUNTIME_MCP_HOME") or os.path.expanduser("~"))
    xdg = str(request.get("xdg_config_home") or os.environ.get("XDG_CONFIG_HOME") or f"{home}/.config")

    if runtime not in RUNTIME_SOURCE_SPECS:
        raise McpResolveError(f"unsupported runtime '{runtime}'", runtime=runtime)
    if not project_root:
        raise McpResolveError("project_root is required", runtime=runtime)

    ambient, sources = _merge_ambient(runtime, project_root, home, xdg)
    catalog = deepcopy(ambient)
    override_decisions: list[str] = []

    if _needs_ralph(ralph_mode, tool_access):
        if not server_script:
            raise McpResolveError(
                "ralph MCP server script path is required when Ralph mode is active",
                runtime=runtime,
                reason="missing_ralph_server_script",
                searched_paths=sources,
            )
        ralph_env_extra: dict[str, str] = {}
        # Telemetry log paths required for `ralph benchmark` savings tracking.
        for key in (
            "RALPH_AGENT_TOOL_ACCESS",
            "RALPH_AGENT_WORKSPACE",
            "RALPH_ARTIFACT_NS",
            "RALPH_BASH_COMPACT_LOG",
            "RALPH_BASH_REWRITE_LOG",
            "RALPH_HOOK_TELEMETRY",
            "RALPH_HOOK_WINDOWING_TELEMETRY",
            "RALPH_PLAN_KEY",
            "RALPH_PLAN_WORKSPACE_ROOT",
            "RALPH_PROJECT_ROOT",
            "RALPH_PROXY_SHELL_COMPACT",
            "RALPH_PROXY_SHELL_COMPACT_LOG",
            "RALPH_RESULT_WINDOWING_LOG",
        ):
            val = os.environ.get(key, "")
            if val:
                ralph_env_extra[key] = val
        ralph_def = _ralph_server_definition(server_script, workspace, ralph_env_extra)
        if RESERVED_RALPH in catalog:
            override_decisions.append("ralph:protected overlay replaces ambient entry")
        else:
            override_decisions.append("ralph:protected overlay applied")
        catalog[RESERVED_RALPH] = ralph_def

    resolved_catalog = {name: _resolve_server_env(server) for name, server in catalog.items()}
    runtime_shape = _to_runtime_shape(runtime, resolved_catalog)

    summary = {
        "mcp_config_sources": sources,
        "mcp_effective_names": sorted(resolved_catalog.keys()),
        "mcp_override_decisions": override_decisions,
        "mcp_failure_reason": "",
    }

    return {
        "ok": True,
        "runtime": runtime,
        "catalog_redacted": [_redact_server(server) for server in resolved_catalog.values()],
        "runtime_config": runtime_shape,
        "summary": summary,
        "searched_paths": sources,
    }


def _error_payload(exc: McpResolveError, runtime: str, searched: list[str]) -> dict[str, Any]:
    return {
        "ok": False,
        "runtime": exc.runtime or runtime,
        "error": {
            "reason": exc.reason,
            "server": exc.server,
            "env_var": exc.env_var,
            "message": str(exc),
            "searched_paths": exc.searched_paths or searched,
        },
        "summary": {
            "mcp_config_sources": searched,
            "mcp_effective_names": [],
            "mcp_override_decisions": [],
            "mcp_failure_reason": str(exc),
        },
    }


def cmd_resolve() -> None:
    try:
        request = json.load(sys.stdin)
    except json.JSONDecodeError as exc:
        print(json.dumps({"ok": False, "error": {"reason": "invalid_request", "message": str(exc)}}))
        sys.exit(1)
    runtime = str(request.get("runtime") or "")
    searched: list[str] = []
    try:
        project_root = os.path.abspath(str(request.get("project_root") or ""))
        home = str(request.get("home") or os.path.expanduser("~"))
        xdg = str(request.get("xdg_config_home") or os.environ.get("XDG_CONFIG_HOME") or f"{home}/.config")
        _, searched = _merge_ambient(runtime.strip().lower(), project_root, home, xdg)
        result = resolve_effective_mcp(request)
        print(json.dumps(result))
    except McpResolveError as exc:
        if not exc.searched_paths:
            exc.searched_paths = searched
        print(json.dumps(_error_payload(exc, runtime, searched)))
        sys.exit(1)


def main(argv: list[str]) -> None:
    if len(argv) < 1:
        sys.stderr.write("Usage: runtime-config-mcp.py resolve\n")
        sys.exit(2)
    if argv[0] == "resolve":
        cmd_resolve()
        return
    sys.stderr.write(f"unknown command: {argv[0]}\n")
    sys.exit(2)


if __name__ == "__main__":
    main(sys.argv[1:])
