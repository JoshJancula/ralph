#!/usr/bin/env python3
"""Closed-schema loader for Ralph plugin inputs.

Parses P03/P04 descriptors and P13/P14 contracts, then enforces source and
destination containment, symlink rejection, secret-pattern checks, and reserved
Ralph MCP protection. This module has no write operations.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
from typing import Any

PLUGIN_OUTPUT_ROOT = "plugins/ralph-orchestrator"
ALLOWED_RUNTIMES = ("antigravity", "claude", "codex", "cursor", "opencode")
CONTRACT_RUNTIMES = frozenset({"antigravity", "opencode"})
ALLOWED_MODES = frozenset({"0644", "0755"})
RESERVED_MCP_NAMES = frozenset({"ralph"})
MCP_COLLECTION_KEYS = frozenset({"mcpServers", "mcp_servers"})
ENV_REF_RE = re.compile(r"^\$\{[A-Z_][A-Z0-9_]*\}$")
SECRET_VALUE_RE = re.compile(
    r"(?i)(?<![A-Za-z0-9_-])(?:sk-[A-Za-z0-9_-]{8,}|AKIA[0-9A-Z]{8,}|"
    r"ghp_[A-Za-z0-9]{20,}|gho_[A-Za-z0-9]{20,}|xox[baprs]-[A-Za-z0-9-]{10,}|"
    r"Bearer\s+[A-Za-z0-9._~+/=-]{8,}|Basic\s+[A-Za-z0-9+/=]{8,})(?![A-Za-z0-9_-])"
)
CREDENTIAL_KEY_RE = re.compile(
    r"(?i)(^|.*[_-])(token|secret|password|api[_-]?key|apikey|auth|credential|bearer)([_-].*)?$|^key$"
)

PLUGIN_KEYS = (
    "schemaVersion",
    "id",
    "displayName",
    "versionFile",
    "outputRoot",
    "engine",
    "agents",
    "workflows",
    "contracts",
    "adapters",
)
ENGINE_KEYS = ("delivery", "command", "pluginApi")
ADAPTER_KEYS = (
    "schemaVersion",
    "runtime",
    "outputDirectory",
    "contract",
    "capabilities",
    "copies",
    "templates",
)
CAPABILITY_KEYS = (
    "nativeAgents",
    "nativeHooks",
    "mcp",
    "rules",
    "skills",
    "workflows",
)
ENTRY_KEYS = ("source", "destination", "mode")
OPENCODE_CONTRACT_KEYS = (
    "schemaVersion",
    "runtime",
    "cliVersion",
    "pluginPackageVersion",
    "moduleFormat",
    "pluginExport",
    "typeDeclaration",
    "typeDeclarationSha256",
    "requiredHooks",
    "moduleSource",
)
ANTIGRAVITY_CONTRACT_KEYS = (
    "schemaVersion",
    "runtime",
    "configRoot",
    "mcpFile",
    "cli",
    "printFlag",
    "conversationFlag",
    "modelFlag",
    "modelsCommand",
    "pluginCommands",
    "modelValuePolicy",
)
OPENCODE_REQUIRED_HOOKS = (
    "permission.ask",
    "tool.execute.before",
    "tool.execute.after",
)
ANTIGRAVITY_PLUGIN_COMMANDS = (
    "list",
    "import",
    "install",
    "uninstall",
    "enable",
    "disable",
    "validate",
    "link",
)


class PluginInputError(Exception):
    """Raised when plugin input descriptors fail closed-schema or security checks."""


def _fail(context: str, message: str) -> None:
    raise PluginInputError(f"{context}: {message}")


def _read_json(path: str, context: str) -> Any:
    try:
        with open(path, encoding="utf-8") as handle:
            return json.load(handle)
    except FileNotFoundError as exc:
        raise PluginInputError(f"{context}: file not found: {path}") from exc
    except OSError as exc:
        raise PluginInputError(f"{context}: cannot read {path}: {exc}") from exc
    except json.JSONDecodeError as exc:
        raise PluginInputError(f"{context}: invalid JSON in {path}: {exc}") from exc


def _require_object(value: Any, context: str) -> dict[str, Any]:
    if not isinstance(value, dict):
        _fail(context, "must be an object")
    return value


def _require_closed_keys(obj: dict[str, Any], keys: tuple[str, ...], context: str) -> None:
    expected = list(keys)
    actual = list(obj.keys())
    extra = [key for key in actual if key not in expected]
    missing = [key for key in expected if key not in obj]
    if extra:
        _fail(context, f"unknown keys: {', '.join(extra)}")
    if missing:
        _fail(context, f"missing keys: {', '.join(missing)}")


def _require_string(value: Any, context: str) -> str:
    if not isinstance(value, str) or not value.strip():
        _fail(context, "must be a non-empty string")
    return value


def _require_bool(value: Any, context: str) -> bool:
    if not isinstance(value, bool):
        _fail(context, "must be a boolean")
    return value


def _require_int(value: Any, context: str) -> int:
    if isinstance(value, bool) or not isinstance(value, int):
        _fail(context, "must be an integer")
    return value


def _require_string_list(value: Any, context: str) -> list[str]:
    if not isinstance(value, list) or not value:
        _fail(context, "must be a non-empty array of strings")
    items: list[str] = []
    for index, item in enumerate(value):
        if not isinstance(item, str) or not item.strip():
            _fail(context, f"[{index}] must be a non-empty string")
        items.append(item)
    return items


def _reject_traversal(rel_path: str, context: str) -> str:
    path = _require_string(rel_path, context)
    if os.path.isabs(path) or path.startswith("~") or path.startswith("\\"):
        _fail(context, f"absolute path is not allowed: {path}")
    if "\\" in path:
        _fail(context, f"path must use forward slashes: {path}")
    parts = [part for part in path.split("/") if part not in ("", ".")]
    if any(part == ".." for part in parts) or path.startswith("../") or "/../" in path:
        _fail(context, f"path traversal is not allowed: {path}")
    return path


def _contained_join(root: str, rel_path: str, context: str) -> str:
    rel = _reject_traversal(rel_path, context)
    root_real = os.path.realpath(root)
    joined = os.path.normpath(os.path.join(root_real, rel))
    prefix = root_real.rstrip(os.sep) + os.sep
    current = joined
    while True:
        if os.path.lexists(current) and os.path.islink(current):
            _fail(context, f"symlink escape is not allowed: {rel_path}")
        if current == root_real or current == os.path.dirname(current):
            break
        current = os.path.dirname(current)
    joined_real = os.path.realpath(joined)
    if joined_real != root_real and not joined_real.startswith(prefix):
        _fail(context, f"path escapes containment root: {rel_path}")
    if joined != root_real and not joined.startswith(prefix):
        _fail(context, f"path escapes containment root: {rel_path}")
    return joined_real


def _require_regular_file(path: str, repo_root: str, context: str) -> str:
    if os.path.islink(path):
        _fail(context, f"symlink escape is not allowed: {path}")
    if not os.path.isfile(path):
        _fail(context, f"source is not a regular file: {path}")
    repo_real = os.path.realpath(repo_root)
    real = os.path.realpath(path)
    prefix = repo_real.rstrip(os.sep) + os.sep
    if real != repo_real and not real.startswith(prefix):
        _fail(context, f"symlink escape is not allowed: {path}")
    if os.path.islink(path) or not os.path.isfile(path):
        _fail(context, f"source is not a regular non-symlink file: {path}")
    return real


def _relative_to_repo(repo_root: str, abs_path: str) -> str:
    repo_real = os.path.realpath(repo_root)
    prefix = repo_real.rstrip(os.sep) + os.sep
    real = os.path.realpath(abs_path)
    if real == repo_real:
        return "."
    if not real.startswith(prefix):
        raise PluginInputError(f"path is outside the repository: {abs_path}")
    return real[len(prefix) :].replace(os.sep, "/")


def _is_env_ref(value: str) -> bool:
    return bool(ENV_REF_RE.match(value))


def _reject_literal_credentials(value: Any, context: str) -> None:
    if isinstance(value, dict):
        for key, item in value.items():
            child = f"{context}.{key}"
            if isinstance(key, str) and CREDENTIAL_KEY_RE.search(key):
                if not isinstance(item, str) or not _is_env_ref(item):
                    _fail(child, "literal credentials are not allowed; use ${ENV_VAR}")
            _reject_literal_credentials(item, child)
        return
    if isinstance(value, list):
        for index, item in enumerate(value):
            _reject_literal_credentials(item, f"{context}[{index}]")
        return
    if isinstance(value, str):
        if _is_env_ref(value):
            return
        if SECRET_VALUE_RE.search(value):
            _fail(context, "literal credentials are not allowed")


def _reject_reserved_mcp(value: Any, context: str) -> None:
    if isinstance(value, dict):
        for key, item in value.items():
            child = f"{context}.{key}"
            if key in MCP_COLLECTION_KEYS:
                _reject_reserved_mcp_collection(item, child)
            _reject_reserved_mcp(item, child)
        return
    if isinstance(value, list):
        for index, item in enumerate(value):
            _reject_reserved_mcp(item, f"{context}[{index}]")


def _reject_reserved_mcp_collection(servers: Any, context: str) -> None:
    if isinstance(servers, dict):
        for name in servers:
            if isinstance(name, str) and name.strip() in RESERVED_MCP_NAMES:
                _fail(context, "reserved Ralph MCP redefinition is not allowed")
            _reject_reserved_mcp(servers[name], f"{context}.{name}")
        return
    if isinstance(servers, list):
        for index, entry in enumerate(servers):
            child = f"{context}[{index}]"
            if isinstance(entry, str) and entry.strip() in RESERVED_MCP_NAMES:
                _fail(child, "reserved Ralph MCP redefinition is not allowed")
            if isinstance(entry, dict):
                name = entry.get("name")
                if isinstance(name, str) and name.strip() in RESERVED_MCP_NAMES:
                    _fail(child, "reserved Ralph MCP redefinition is not allowed")
            _reject_reserved_mcp(entry, child)
        return
    _fail(context, "MCP collection must be an object or array")


def _scan_json_file(path: str, context: str) -> None:
    data = _read_json(path, context)
    _reject_literal_credentials(data, context)
    _reject_reserved_mcp(data, context)


def _scan_text_file(path: str, context: str) -> None:
    try:
        with open(path, encoding="utf-8") as handle:
            text = handle.read()
    except OSError as exc:
        _fail(context, f"cannot read {path}: {exc}")
    if SECRET_VALUE_RE.search(text):
        _fail(context, "literal credentials are not allowed")
    stripped = text.lstrip()
    if stripped.startswith("{") or stripped.startswith("["):
        try:
            data = json.loads(text)
        except json.JSONDecodeError:
            return
        _reject_literal_credentials(data, context)
        _reject_reserved_mcp(data, context)


def _validate_engine(engine: Any, context: str) -> dict[str, Any]:
    obj = _require_object(engine, context)
    _require_closed_keys(obj, ENGINE_KEYS, context)
    delivery = _require_string(obj["delivery"], f"{context}.delivery")
    if delivery != "external-cli":
        _fail(f"{context}.delivery", f"must be external-cli, got {delivery}")
    command = _require_string(obj["command"], f"{context}.command")
    if command != "ralph":
        _fail(f"{context}.command", f"must be ralph, got {command}")
    plugin_api = _require_int(obj["pluginApi"], f"{context}.pluginApi")
    if plugin_api < 1:
        _fail(f"{context}.pluginApi", "must be >= 1")
    return {"delivery": delivery, "command": command, "pluginApi": plugin_api}


def _validate_capabilities(value: Any, context: str) -> dict[str, bool]:
    obj = _require_object(value, context)
    _require_closed_keys(obj, CAPABILITY_KEYS, context)
    return {key: _require_bool(obj[key], f"{context}.{key}") for key in CAPABILITY_KEYS}


def _validate_entry(entry: Any, context: str) -> dict[str, str]:
    obj = _require_object(entry, context)
    _require_closed_keys(obj, ENTRY_KEYS, context)
    mode = _require_string(obj["mode"], f"{context}.mode")
    if mode not in ALLOWED_MODES:
        _fail(f"{context}.mode", f"must be one of {sorted(ALLOWED_MODES)}")
    return {
        "source": _require_string(obj["source"], f"{context}.source"),
        "destination": _require_string(obj["destination"], f"{context}.destination"),
        "mode": mode,
    }


def _validate_entries(value: Any, context: str) -> list[dict[str, str]]:
    if not isinstance(value, list) or not value:
        _fail(context, "must be a non-empty array")
    return [_validate_entry(item, f"{context}[{index}]") for index, item in enumerate(value)]


def _resolve_source(repo_root: str, rel_path: str, context: str) -> str:
    abs_path = _contained_join(repo_root, rel_path, context)
    return _require_regular_file(abs_path, repo_root, context)


def _resolve_destination(
    adapter_output_dir: str,
    plugin_output_dir: str,
    rel_path: str,
    context: str,
) -> str:
    dest = _contained_join(adapter_output_dir, rel_path, context)
    plugin_real = os.path.realpath(plugin_output_dir)
    prefix = plugin_real.rstrip(os.sep) + os.sep
    if dest != plugin_real and not dest.startswith(prefix):
        _fail(context, "output path is outside plugins/ralph-orchestrator")
    adapter_real = os.path.realpath(adapter_output_dir)
    adapter_prefix = adapter_real.rstrip(os.sep) + os.sep
    if dest != adapter_real and not dest.startswith(adapter_prefix):
        _fail(context, "destination escapes the adapter output directory")
    return dest


def _validate_opencode_contract(obj: dict[str, Any], context: str) -> dict[str, Any]:
    _require_closed_keys(obj, OPENCODE_CONTRACT_KEYS, context)
    if _require_int(obj["schemaVersion"], f"{context}.schemaVersion") != 1:
        _fail(f"{context}.schemaVersion", "must be 1")
    if _require_string(obj["runtime"], f"{context}.runtime") != "opencode":
        _fail(f"{context}.runtime", "must be opencode")
    hooks = _require_string_list(obj["requiredHooks"], f"{context}.requiredHooks")
    if tuple(hooks) != OPENCODE_REQUIRED_HOOKS:
        _fail(f"{context}.requiredHooks", "must match the frozen OpenCode hook keys")
    sha = _require_string(obj["typeDeclarationSha256"], f"{context}.typeDeclarationSha256")
    if not re.fullmatch(r"[0-9a-f]{64}", sha):
        _fail(f"{context}.typeDeclarationSha256", "must be a 64-character lowercase hex digest")
    return {
        "schemaVersion": 1,
        "runtime": "opencode",
        "cliVersion": _require_string(obj["cliVersion"], f"{context}.cliVersion"),
        "pluginPackageVersion": _require_string(
            obj["pluginPackageVersion"], f"{context}.pluginPackageVersion"
        ),
        "moduleFormat": _require_string(obj["moduleFormat"], f"{context}.moduleFormat"),
        "pluginExport": _require_string(obj["pluginExport"], f"{context}.pluginExport"),
        "typeDeclaration": _require_string(obj["typeDeclaration"], f"{context}.typeDeclaration"),
        "typeDeclarationSha256": sha,
        "requiredHooks": hooks,
        "moduleSource": _require_string(obj["moduleSource"], f"{context}.moduleSource"),
    }


def _validate_antigravity_contract(obj: dict[str, Any], context: str) -> dict[str, Any]:
    _require_closed_keys(obj, ANTIGRAVITY_CONTRACT_KEYS, context)
    if _require_int(obj["schemaVersion"], f"{context}.schemaVersion") != 1:
        _fail(f"{context}.schemaVersion", "must be 1")
    if _require_string(obj["runtime"], f"{context}.runtime") != "antigravity":
        _fail(f"{context}.runtime", "must be antigravity")
    commands = _require_string_list(obj["pluginCommands"], f"{context}.pluginCommands")
    if tuple(commands) != ANTIGRAVITY_PLUGIN_COMMANDS:
        _fail(f"{context}.pluginCommands", "must match the frozen Antigravity command list")
    policy = _require_string(obj["modelValuePolicy"], f"{context}.modelValuePolicy")
    if policy != "opaque-byte-preserved":
        _fail(f"{context}.modelValuePolicy", "must be opaque-byte-preserved")
    return {
        "schemaVersion": 1,
        "runtime": "antigravity",
        "configRoot": _require_string(obj["configRoot"], f"{context}.configRoot"),
        "mcpFile": _require_string(obj["mcpFile"], f"{context}.mcpFile"),
        "cli": _require_string(obj["cli"], f"{context}.cli"),
        "printFlag": _require_string(obj["printFlag"], f"{context}.printFlag"),
        "conversationFlag": _require_string(
            obj["conversationFlag"], f"{context}.conversationFlag"
        ),
        "modelFlag": _require_string(obj["modelFlag"], f"{context}.modelFlag"),
        "modelsCommand": _require_string(obj["modelsCommand"], f"{context}.modelsCommand"),
        "pluginCommands": commands,
        "modelValuePolicy": policy,
    }


def _load_contract(
    repo_root: str,
    rel_path: str,
    runtime: str,
    context: str,
) -> dict[str, Any]:
    abs_path = _resolve_source(repo_root, rel_path, context)
    obj = _require_object(_read_json(abs_path, context), context)
    _reject_literal_credentials(obj, context)
    _reject_reserved_mcp(obj, context)
    if runtime == "opencode":
        contract = _validate_opencode_contract(obj, context)
        _resolve_source(repo_root, contract["moduleSource"], f"{context}.moduleSource")
        return contract
    if runtime == "antigravity":
        return _validate_antigravity_contract(obj, context)
    _fail(context, f"unsupported contract runtime: {runtime}")
    raise AssertionError("unreachable")


def _load_plugin_descriptor(path: str, context: str) -> dict[str, Any]:
    obj = _require_object(_read_json(path, context), context)
    _require_closed_keys(obj, PLUGIN_KEYS, context)
    _reject_literal_credentials(obj, context)
    _reject_reserved_mcp(obj, context)
    if _require_int(obj["schemaVersion"], f"{context}.schemaVersion") != 1:
        _fail(f"{context}.schemaVersion", "must be 1")
    plugin_id = _require_string(obj["id"], f"{context}.id")
    if plugin_id != "ralph-orchestrator":
        _fail(f"{context}.id", "must be ralph-orchestrator")
    output_root = _reject_traversal(obj["outputRoot"], f"{context}.outputRoot")
    if output_root != PLUGIN_OUTPUT_ROOT:
        _fail(f"{context}.outputRoot", "output must stay inside plugins/ralph-orchestrator")
    adapters = _require_string_list(obj["adapters"], f"{context}.adapters")
    unknown = [name for name in adapters if name not in ALLOWED_RUNTIMES]
    if unknown:
        _fail(f"{context}.adapters", f"unsupported runtimes: {', '.join(unknown)}")
    if len(set(adapters)) != len(adapters):
        _fail(f"{context}.adapters", "duplicate runtime ids are not allowed")
    contracts_obj = _require_object(obj["contracts"], f"{context}.contracts")
    _require_closed_keys(contracts_obj, ("antigravity", "opencode"), f"{context}.contracts")
    return {
        "schemaVersion": 1,
        "id": plugin_id,
        "displayName": _require_string(obj["displayName"], f"{context}.displayName"),
        "versionFile": _reject_traversal(obj["versionFile"], f"{context}.versionFile"),
        "outputRoot": output_root,
        "engine": _validate_engine(obj["engine"], f"{context}.engine"),
        "agents": _require_string_list(obj["agents"], f"{context}.agents"),
        "workflows": _require_string_list(obj["workflows"], f"{context}.workflows"),
        "contracts": {
            "antigravity": _reject_traversal(
                contracts_obj["antigravity"], f"{context}.contracts.antigravity"
            ),
            "opencode": _reject_traversal(
                contracts_obj["opencode"], f"{context}.contracts.opencode"
            ),
        },
        "adapters": adapters,
    }


def _load_adapter_descriptor(
    repo_root: str,
    plugin_output_dir: str,
    path: str,
    expected_runtime: str,
    context: str,
) -> dict[str, Any]:
    obj = _require_object(_read_json(path, context), context)
    _require_closed_keys(obj, ADAPTER_KEYS, context)
    _reject_literal_credentials(obj, context)
    _reject_reserved_mcp(obj, context)
    if _require_int(obj["schemaVersion"], f"{context}.schemaVersion") != 1:
        _fail(f"{context}.schemaVersion", "must be 1")
    runtime = _require_string(obj["runtime"], f"{context}.runtime")
    if runtime != expected_runtime:
        _fail(f"{context}.runtime", f"must be {expected_runtime}")
    if runtime not in ALLOWED_RUNTIMES:
        _fail(f"{context}.runtime", f"unsupported runtime: {runtime}")
    output_directory = _reject_traversal(obj["outputDirectory"], f"{context}.outputDirectory")
    adapter_output_dir = _contained_join(
        repo_root, output_directory, f"{context}.outputDirectory"
    )
    plugin_real = os.path.realpath(plugin_output_dir)
    prefix = plugin_real.rstrip(os.sep) + os.sep
    if adapter_output_dir != plugin_real and not adapter_output_dir.startswith(prefix):
        _fail(f"{context}.outputDirectory", "output is outside plugins/ralph-orchestrator")
    expected_output = f"{PLUGIN_OUTPUT_ROOT}/{runtime}"
    if output_directory != expected_output:
        _fail(
            f"{context}.outputDirectory",
            f"must be {expected_output}",
        )
    contract_value = obj["contract"]
    copies = _validate_entries(obj["copies"], f"{context}.copies")
    templates = _validate_entries(obj["templates"], f"{context}.templates")
    resolved_copies: list[dict[str, str]] = []
    resolved_templates: list[dict[str, str]] = []
    for index, entry in enumerate(copies):
        source_abs = _resolve_source(repo_root, entry["source"], f"{context}.copies[{index}].source")
        dest_abs = _resolve_destination(
            adapter_output_dir,
            plugin_output_dir,
            entry["destination"],
            f"{context}.copies[{index}].destination",
        )
        source_rel = _relative_to_repo(repo_root, source_abs)
        if source_rel.startswith("bundle/.ralph/plugin-inputs/"):
            _scan_text_file(source_abs, f"{context}.copies[{index}].source")
        resolved_copies.append(
            {
                "source": entry["source"],
                "destination": entry["destination"],
                "mode": entry["mode"],
                "sourceRealPath": source_abs,
                "destinationRealPath": dest_abs,
            }
        )
    for index, entry in enumerate(templates):
        source_abs = _resolve_source(
            repo_root, entry["source"], f"{context}.templates[{index}].source"
        )
        dest_abs = _resolve_destination(
            adapter_output_dir,
            plugin_output_dir,
            entry["destination"],
            f"{context}.templates[{index}].destination",
        )
        _scan_text_file(source_abs, f"{context}.templates[{index}].source")
        resolved_templates.append(
            {
                "source": entry["source"],
                "destination": entry["destination"],
                "mode": entry["mode"],
                "sourceRealPath": source_abs,
                "destinationRealPath": dest_abs,
            }
        )
    contract: Any
    if runtime in CONTRACT_RUNTIMES:
        if not isinstance(contract_value, str):
            _fail(f"{context}.contract", f"must be the {runtime} contract path")
        contract = _reject_traversal(contract_value, f"{context}.contract")
        expected_contract = f"bundle/.ralph/plugin-inputs/contracts/{runtime}.json"
        if contract != expected_contract:
            _fail(f"{context}.contract", f"must be {expected_contract}")
    else:
        if contract_value is not None:
            _fail(f"{context}.contract", "must be null")
        contract = None
    return {
        "schemaVersion": 1,
        "runtime": runtime,
        "outputDirectory": output_directory,
        "outputDirectoryRealPath": adapter_output_dir,
        "contract": contract,
        "capabilities": _validate_capabilities(obj["capabilities"], f"{context}.capabilities"),
        "copies": resolved_copies,
        "templates": resolved_templates,
    }


def load_plugin_inputs(
    repo_root: str,
    inputs_root: str | None = None,
) -> dict[str, Any]:
    """Load and validate canonical plugin inputs. Performs no writes."""
    if not repo_root:
        raise PluginInputError("repo root is required")
    repo_real = os.path.realpath(repo_root)
    if not os.path.isdir(repo_real):
        raise PluginInputError(f"repo root is not a directory: {repo_root}")
    inputs = inputs_root or os.path.join(repo_real, "bundle", ".ralph", "plugin-inputs")
    inputs_real = os.path.realpath(inputs)
    plugin_path = os.path.join(inputs_real, "plugin.json")
    plugin = _load_plugin_descriptor(plugin_path, "plugin.json")
    plugin_output_dir = _contained_join(repo_real, plugin["outputRoot"], "plugin.json.outputRoot")
    version_abs = _resolve_source(repo_real, plugin["versionFile"], "plugin.json.versionFile")
    version_prefix = plugin_output_dir.rstrip(os.sep) + os.sep
    if version_abs != plugin_output_dir and not version_abs.startswith(version_prefix):
        _fail("plugin.json.versionFile", "output is outside plugins/ralph-orchestrator")
    contracts = {
        runtime: _load_contract(
            repo_real,
            plugin["contracts"][runtime],
            runtime,
            f"plugin.json.contracts.{runtime}",
        )
        for runtime in ("antigravity", "opencode")
    }
    adapters: list[dict[str, Any]] = []
    for runtime in plugin["adapters"]:
        adapter_path = os.path.join(inputs_real, "adapters", f"{runtime}.json")
        adapter = _load_adapter_descriptor(
            repo_real,
            plugin_output_dir,
            adapter_path,
            runtime,
            f"adapters/{runtime}.json",
        )
        if adapter["contract"] is not None:
            adapter["resolvedContract"] = contracts[runtime]
        adapters.append(adapter)
    return {
        "repoRoot": repo_real,
        "inputsRoot": inputs_real,
        "plugin": plugin,
        "versionFileRealPath": version_abs,
        "outputRootRealPath": plugin_output_dir,
        "contracts": contracts,
        "adapters": adapters,
    }


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="Validate Ralph plugin input descriptors without generating files."
    )
    parser.add_argument("--repo-root", required=True, help="Repository root used for containment")
    parser.add_argument(
        "--inputs-root",
        default=None,
        help="Optional plugin-inputs directory; defaults to bundle/.ralph/plugin-inputs",
    )
    args = parser.parse_args(argv)
    try:
        loaded = load_plugin_inputs(args.repo_root, inputs_root=args.inputs_root)
    except PluginInputError as exc:
        print(str(exc), file=sys.stderr)
        return 1
    json.dump(
        {
            "ok": True,
            "outputRoot": loaded["plugin"]["outputRoot"],
            "adapters": [adapter["runtime"] for adapter in loaded["adapters"]],
            "contracts": sorted(loaded["contracts"].keys()),
        },
        sys.stdout,
        indent=2,
        sort_keys=True,
    )
    sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
