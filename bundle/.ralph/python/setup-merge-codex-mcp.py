#!/usr/bin/env python3
"""Merge Ralph MCP server config into a Codex config.toml file."""
import json
import os
import sys

try:
    import tomllib
except ImportError:
    sys.stderr.write(
        "Error: Python 3.11+ is required for Codex MCP TOML merge (tomllib)\n"
    )
    sys.exit(1)


def load_toml(path):
    if not path or path == "-":
        return {}
    if not os.path.isfile(path):
        return {}
    with open(path, "rb") as fh:
        return tomllib.load(fh)


def escape_string(value):
    return '"' + value.replace("\\", "\\\\").replace('"', '\\"') + '"'


def format_value(value):
    if isinstance(value, bool):
        return "true" if value else "false"
    if isinstance(value, int):
        return str(value)
    if isinstance(value, float):
        return str(value)
    if isinstance(value, str):
        return escape_string(value)
    if isinstance(value, list):
        inner = ", ".join(format_value(item) for item in value)
        return f"[{inner}]"
    raise TypeError(f"unsupported TOML value type: {type(value)!r}")


def emit_table(lines, prefix, table):
    scalars = {}
    nested = {}
    for key, value in table.items():
        if isinstance(value, dict):
            nested[key] = value
        else:
            scalars[key] = value

    if scalars or not nested:
        lines.append(f"[{prefix}]")
        for key in sorted(scalars.keys()):
            lines.append(f"{key} = {format_value(scalars[key])}")
        lines.append("")

    for key in sorted(nested.keys()):
        emit_table(lines, f"{prefix}.{key}", nested[key])


def write_toml(data, path):
    lines = []
    top_scalars = {}
    top_tables = {}
    for key, value in data.items():
        if isinstance(value, dict):
            top_tables[key] = value
        else:
            top_scalars[key] = value

    for key in sorted(top_scalars.keys()):
        lines.append(f"{key} = {format_value(top_scalars[key])}")
    if top_scalars and top_tables:
        lines.append("")

    for key in sorted(top_tables.keys()):
        emit_table(lines, key, top_tables[key])

    parent = os.path.dirname(path)
    if parent:
        os.makedirs(parent, exist_ok=True)
    with open(path, "w", encoding="utf-8") as fh:
        if lines:
            fh.write("\n".join(lines).rstrip() + "\n")


def merge_ralph_mcp(data, server_script, project_root):
    path_default = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
    mcp_servers = data.setdefault("mcp_servers", {})
    mcp_servers["ralph"] = {
        "command": "bash",
        "args": [server_script],
        "env": {
            "PATH": path_default,
            "RALPH_MCP_WORKSPACE": project_root,
            "RALPH_MODE": "hybrid",
        },
    }


def merge_additional_mcp_fragment(data, fragment_json):
    if not fragment_json:
        return

    try:
        fragment = json.loads(fragment_json)
    except json.JSONDecodeError as exc:
        sys.stderr.write(f"Error: invalid JSON in additional MCP fragment: {exc}\n")
        sys.exit(1)

    additional_servers = fragment.get("mcp_servers", {})
    if additional_servers is None:
        return
    if not isinstance(additional_servers, dict):
        sys.stderr.write("Error: additional MCP fragment must contain an mcp_servers table\n")
        sys.exit(1)

    mcp_servers = data.setdefault("mcp_servers", {})
    for name, entry in additional_servers.items():
        mcp_servers[name] = entry


def main():
    if len(sys.argv) not in (5, 6):
        sys.stderr.write(
            "Usage: setup-merge-codex-mcp.py <source_path|-> <output_path> "
            "<server_script> <project_root> [additional_mcp_fragment_json]\n"
        )
        sys.exit(1)

    source_path, output_path, server_script, project_root = sys.argv[1:5]
    additional_mcp_fragment_json = sys.argv[5] if len(sys.argv) == 6 else ""
    if not server_script or not project_root:
        sys.stderr.write("Error: server_script and project_root are required\n")
        sys.exit(1)

    try:
        data = load_toml(source_path)
    except tomllib.TOMLDecodeError as exc:
        label = source_path if source_path and source_path != "-" else "config"
        sys.stderr.write(f"Error: invalid TOML in {label}: {exc}\n")
        sys.exit(1)

    merge_ralph_mcp(data, server_script, project_root)
    merge_additional_mcp_fragment(data, additional_mcp_fragment_json)

    try:
        write_toml(data, output_path)
    except OSError as exc:
        sys.stderr.write(f"Error: failed to write merged Codex MCP config: {exc}\n")
        sys.exit(1)


if __name__ == "__main__":
    main()
