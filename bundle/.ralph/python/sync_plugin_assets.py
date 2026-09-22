#!/usr/bin/env python3
"""Deterministic Ralph plugin asset generator (P06).

Reads closed-schema descriptors through plugin_inputs.py, renders adapter
trees, and either writes them atomically or reports drift in --check mode.
This module owns generation and replacement; plugin_inputs.py does not write.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import stat
import sys
import tempfile
from typing import Any

_HERE = os.path.dirname(os.path.abspath(__file__))
if _HERE not in sys.path:
    sys.path.insert(0, _HERE)

import plugin_inputs  # noqa: E402

MANIFEST_NAME = ".ralph-plugin-generated.json"
ALLOWED_TOKENS = frozenset(
    {
        "PLUGIN_ID",
        "PLUGIN_VERSION",
        "RUNTIME",
        "SHARED_BOOTSTRAP_REL",
        "SHARED_EXEC_REL",
    }
)
TOKEN_RE = re.compile(r"\{\{([A-Za-z0-9_]+)\}\}")
MARKER_TOOL = "scripts/sync-plugin-assets.sh"
TEMP_DIR_PREFIX = ".ralph-plugin-generating."
SHARED_BOOTSTRAP_NAME = "ralph-plugin-bootstrap.sh"
SHARED_EXEC_NAME = "ralph-plugin-exec.sh"


class SyncPluginError(Exception):
    """Raised when plugin generation cannot complete safely."""


def _fail(message: str) -> None:
    raise SyncPluginError(message)


def _read_text(path: str) -> str:
    try:
        with open(path, encoding="utf-8", newline="") as handle:
            return handle.read()
    except OSError as exc:
        _fail(f"cannot read {path}: {exc}")
    raise AssertionError("unreachable")


def _normalize_text(text: str) -> str:
    normalized = text.replace("\r\n", "\n").replace("\r", "\n")
    if not normalized.endswith("\n"):
        normalized += "\n"
    return normalized


def _posix_relpath(target: str, start: str) -> str:
    return os.path.relpath(target, start=start).replace(os.sep, "/")


def _file_mode(path: str) -> str:
    mode = stat.S_IMODE(os.stat(path).st_mode)
    return f"{mode:04o}"


def _is_json_path(rel_path: str) -> bool:
    return rel_path.endswith(".json")


def _looks_like_json(text: str) -> bool:
    stripped = text.lstrip()
    return stripped.startswith("{") or stripped.startswith("[")


def _marker_message(source_rel: str) -> str:
    return f"GENERATED from {source_rel} by {MARKER_TOOL} - edit the canonical file"


def _html_marker(source_rel: str) -> str:
    return f"<!-- {_marker_message(source_rel)} -->"


def _hash_marker(source_rel: str) -> str:
    return f"# {_marker_message(source_rel)}"


def _dump_json(value: Any) -> str:
    return json.dumps(value, indent=2, sort_keys=True, ensure_ascii=False) + "\n"


def _apply_text_marker(text: str, source_rel: str, dest_rel: str) -> str:
    body = text
    if dest_rel.endswith((".md", ".mdc", ".html")):
        marker = _html_marker(source_rel)
        if body.startswith(marker + "\n"):
            return body
        return marker + "\n" + body
    marker = _hash_marker(source_rel)
    if body.startswith("#!"):
        shebang, newline, rest = body.partition("\n")
        if not newline:
            return shebang + "\n" + marker + "\n"
        if rest.startswith(marker + "\n"):
            return body
        return shebang + "\n" + marker + "\n" + rest
    if body.startswith(marker + "\n"):
        return body
    return marker + "\n" + body


def _apply_json_marker(text: str, source_rel: str) -> str:
    try:
        data = json.loads(text)
    except json.JSONDecodeError as exc:
        _fail(f"generated JSON is invalid after substitution: {exc}")
    if isinstance(data, dict):
        data["_generated"] = _marker_message(source_rel)
    return _dump_json(data)


def _normalize_json(text: str) -> str:
    try:
        data = json.loads(text)
    except json.JSONDecodeError as exc:
        _fail(f"generated JSON is invalid after substitution: {exc}")
    return _dump_json(data)


def _substitute(text: str, mapping: dict[str, str], context: str) -> str:
    def replace(match: re.Match[str]) -> str:
        name = match.group(1)
        if name not in ALLOWED_TOKENS:
            _fail(f"{context}: unknown token {{{{{name}}}}}")
        if name not in mapping:
            _fail(f"{context}: unresolved token {{{{{name}}}}}")
        return mapping[name]

    rendered = TOKEN_RE.sub(replace, text)
    leftover = TOKEN_RE.search(rendered)
    if leftover:
        _fail(f"{context}: unresolved token {{{{{leftover.group(1)}}}}}")
    if "{{" in rendered:
        _fail(f"{context}: unresolved token remains after substitution")
    return rendered


def _token_mapping(
    plugin_id: str,
    plugin_version: str,
    runtime: str,
    dest_abs: str,
    bootstrap_abs: str | None,
    exec_abs: str | None,
) -> dict[str, str]:
    mapping = {
        "PLUGIN_ID": plugin_id,
        "PLUGIN_VERSION": plugin_version,
        "RUNTIME": runtime,
    }
    dest_dir = os.path.dirname(dest_abs)
    if bootstrap_abs is not None:
        mapping["SHARED_BOOTSTRAP_REL"] = _posix_relpath(bootstrap_abs, dest_dir)
    if exec_abs is not None:
        mapping["SHARED_EXEC_REL"] = _posix_relpath(exec_abs, dest_dir)
    return mapping


def _shared_destination(
    entries: list[dict[str, str]],
    filename: str,
) -> str | None:
    matches = [
        entry["destinationRealPath"]
        for entry in entries
        if os.path.basename(entry["destination"]) == filename
    ]
    if len(matches) > 1:
        _fail(f"multiple destinations named {filename}")
    if matches:
        return matches[0]
    return None


def _opencode_contract_package_candidates(repo_root: str, declaration: str) -> list[str]:
    return [
        os.path.join(repo_root, "bundle", ".opencode", "node_modules", declaration),
        os.path.join(repo_root, ".opencode", "node_modules", declaration),
        os.path.join(repo_root, "node_modules", declaration),
    ]


def _opencode_contract_package_json_candidates(repo_root: str) -> list[str]:
    return [
        os.path.join(repo_root, "bundle", ".opencode", "node_modules", "@opencode-ai", "plugin", "package.json"),
        os.path.join(repo_root, ".opencode", "node_modules", "@opencode-ai", "plugin", "package.json"),
        os.path.join(repo_root, "node_modules", "@opencode-ai", "plugin", "package.json"),
    ]


def _validate_opencode_contract(loaded: dict[str, Any], adapter: dict[str, Any]) -> None:
    contract = adapter.get("resolvedContract")
    if adapter.get("runtime") != "opencode" or not isinstance(contract, dict):
        return

    module_source = contract["moduleSource"]
    module_entries = [
        entry for entry in adapter["copies"]
        if entry["source"].replace(os.sep, "/") == module_source
    ]
    if len(module_entries) != 1:
        _fail(
            "adapters/opencode.json: contract moduleSource must identify exactly one copied module"
        )
    module_text = _read_text(module_entries[0]["sourceRealPath"])
    if not re.search(r"export\s+const\s+\w+\s*:\s*Plugin\b", module_text):
        _fail(
            "OpenCode contract mismatch: detected module export does not implement the pinned Plugin export"
        )
    for hook in contract["requiredHooks"]:
        if not re.search(rf"[\"']{re.escape(hook)}[\"']", module_text):
            _fail(
                f"OpenCode contract mismatch: required hook {hook} is missing from {module_source}"
            )

    declaration_candidates = _opencode_contract_package_candidates(
        loaded["repoRoot"], contract["typeDeclaration"]
    )
    declaration_path = next(
        (path for path in declaration_candidates if os.path.isfile(path) and not os.path.islink(path)),
        None,
    )
    if declaration_path is None:
        _fail(
            "OpenCode contract mismatch: pinned type declaration is unavailable; "
            f"expected {contract['typeDeclaration']} at a local OpenCode package path"
        )
    with open(declaration_path, "rb") as handle:
        detected_hash = hashlib.sha256(handle.read()).hexdigest()
    expected_hash = contract["typeDeclarationSha256"]
    if detected_hash != expected_hash:
        _fail(
            "OpenCode contract mismatch: type declaration SHA-256 "
            f"detected {detected_hash}, expected {expected_hash}"
        )

    package_candidates = _opencode_contract_package_json_candidates(loaded["repoRoot"])
    package_path = next(
        (path for path in package_candidates if os.path.isfile(path) and not os.path.islink(path)),
        None,
    )
    if package_path is None:
        _fail(
            "OpenCode contract mismatch: @opencode-ai/plugin package metadata is unavailable; "
            f"expected version {contract['pluginPackageVersion']}"
        )
    try:
        package = json.loads(_read_text(package_path))
    except json.JSONDecodeError as exc:
        _fail(f"OpenCode contract mismatch: invalid package metadata {package_path}: {exc}")
    detected_version = package.get("version")
    expected_version = contract["pluginPackageVersion"]
    if detected_version != expected_version:
        _fail(
            "OpenCode contract mismatch: @opencode-ai/plugin version "
            f"detected {detected_version!r}, expected {expected_version!r}"
        )


def _validate_antigravity_contract(loaded: dict[str, Any], adapter: dict[str, Any]) -> None:
    contract = adapter.get("resolvedContract")
    if adapter.get("runtime") != "antigravity" or not isinstance(contract, dict):
        return

    expected = {
        "configRoot": ".agents",
        "mcpFile": "mcp_config.json",
        "cli": "agy",
        "printFlag": "--print",
        "conversationFlag": "--conversation",
        "modelFlag": "--model",
        "modelsCommand": "agy models",
        "modelValuePolicy": "opaque-byte-preserved",
    }
    for field, expected_value in expected.items():
        detected = contract.get(field)
        if detected != expected_value:
            _fail(
                "Antigravity contract mismatch: "
                f"{field} detected {detected!r}, expected {expected_value!r}"
            )

    expected_commands = [
        "list",
        "import",
        "install",
        "uninstall",
        "enable",
        "disable",
        "validate",
        "link",
    ]
    if contract.get("pluginCommands") != expected_commands:
        _fail(
            "Antigravity contract mismatch: pluginCommands "
            f"detected {contract.get('pluginCommands')!r}, expected {expected_commands!r}"
        )

    mcp_entries = [
        entry for entry in adapter["templates"]
        if entry["destination"].replace(os.sep, "/") == contract["mcpFile"]
    ]
    if len(mcp_entries) != 1:
        _fail(
            "Antigravity adapter must render exactly one contract MCP file "
            f"at {contract['configRoot']}/{contract['mcpFile']}"
        )


def _assert_contained(path: str, root: str, context: str) -> str:
    root_real = os.path.realpath(root)
    prefix = root_real.rstrip(os.sep) + os.sep
    if os.path.lexists(path) and os.path.islink(path):
        _fail(f"{context}: symlink escape is not allowed: {path}")
    real = os.path.realpath(path) if os.path.lexists(path) else os.path.normpath(path)
    if real != root_real and not real.startswith(prefix):
        _fail(f"{context}: path escapes containment root: {path}")
    if os.path.normpath(path) != root_real and not os.path.normpath(path).startswith(prefix):
        _fail(f"{context}: path escapes containment root: {path}")
    return real


def _atomic_write(path: str, content: str, mode: str) -> None:
    directory = os.path.dirname(path)
    os.makedirs(directory, exist_ok=True)
    fd, tmp_path = tempfile.mkstemp(prefix=".ralph-plugin-", dir=directory, text=True)
    try:
        with os.fdopen(fd, "w", encoding="utf-8", newline="\n") as handle:
            handle.write(content)
        os.chmod(tmp_path, int(mode, 8))
        os.replace(tmp_path, path)
    except Exception:
        try:
            os.unlink(tmp_path)
        except OSError:
            pass
        raise


def _load_previous_manifest(adapter_dir: str) -> list[str]:
    path = os.path.join(adapter_dir, MANIFEST_NAME)
    if not os.path.isfile(path) or os.path.islink(path):
        return []
    try:
        data = json.loads(_read_text(path))
    except (OSError, json.JSONDecodeError, SyncPluginError):
        return []
    if not isinstance(data, dict):
        return []
    paths = data.get("generatedPaths")
    if not isinstance(paths, list):
        return []
    rels: list[str] = []
    for item in paths:
        if isinstance(item, str) and item.strip():
            rels.append(item.replace(os.sep, "/"))
    return rels


def _render_entry(
    entry: dict[str, str],
    *,
    template: bool,
    plugin_id: str,
    plugin_version: str,
    runtime: str,
    bootstrap_abs: str | None,
    exec_abs: str | None,
    adapter_dir: str,
    plugin_output_dir: str,
    context: str,
) -> tuple[str, str, str]:
    dest_abs = entry["destinationRealPath"]
    dest_rel = entry["destination"].replace(os.sep, "/")
    _assert_contained(dest_abs, adapter_dir, f"{context}.destination")
    _assert_contained(dest_abs, plugin_output_dir, f"{context}.destination")
    text = _read_text(entry["sourceRealPath"])
    if runtime == "claude":
        # Claude plugins are copied into a cache, so paths that are valid in
        # the repository's .claude tree must resolve from the installed
        # plugin root instead. Keep this adaptation in the renderer so the
        # canonical runtime-native files remain untouched.
        text = text.replace(
            ".claude/skills/", "${CLAUDE_PLUGIN_ROOT}/skills/"
        )
        text = text.replace("RALPH_PLUGIN_ROOT", "CLAUDE_PLUGIN_ROOT")
    elif runtime == "antigravity":
        # The native registry and metadata are generated from the bundled
        # runtime tree, but are installed beneath the project's .agents root.
        # Keep those references valid without mutating canonical assets or
        # changing opaque model values.
        text = text.replace("bundle/.ralph/agents/", ".agents/agents/")
        text = text.replace("bundle/.agents/", ".agents/")
    if template:
        mapping = _token_mapping(
            plugin_id,
            plugin_version,
            runtime,
            dest_abs,
            bootstrap_abs,
            exec_abs,
        )
        needed = {match.group(1) for match in TOKEN_RE.finditer(text)}
        for name in sorted(needed):
            if name not in ALLOWED_TOKENS:
                _fail(f"{context}: unknown token {{{{{name}}}}}")
            if name not in mapping:
                _fail(f"{context}: unresolved token {{{{{name}}}}}")
        text = _substitute(text, mapping, context)
    text = _normalize_text(text)
    source_rel = entry["source"].replace(os.sep, "/")
    if _is_json_path(dest_rel) or _looks_like_json(text):
        # Host-native JSON schemas may reject unknown provenance keys. Ralph's
        # own host manifest carries the inline marker; every other generated
        # path is already attributed by .ralph-plugin-generated.json.
        if dest_rel == "host-manifest.json":
            text = _apply_json_marker(text, source_rel)
        else:
            text = _normalize_json(text)
    else:
        text = _apply_text_marker(text, source_rel, dest_rel)
        text = _normalize_text(text)
    return dest_rel, text, entry["mode"]


def _render_adapter(
    loaded: dict[str, Any],
    adapter: dict[str, Any],
) -> dict[str, tuple[str, str]]:
    plugin = loaded["plugin"]
    plugin_version = _read_text(loaded["versionFileRealPath"]).strip()
    if not plugin_version:
        _fail("plugin version file is empty")
    runtime = adapter["runtime"]
    adapter_dir = adapter["outputDirectoryRealPath"]
    plugin_output_dir = loaded["outputRootRealPath"]
    _validate_opencode_contract(loaded, adapter)
    _validate_antigravity_contract(loaded, adapter)
    entries = list(adapter["copies"]) + list(adapter["templates"])
    bootstrap_abs = _shared_destination(entries, SHARED_BOOTSTRAP_NAME)
    exec_abs = _shared_destination(entries, SHARED_EXEC_NAME)
    rendered: dict[str, tuple[str, str]] = {}
    for index, entry in enumerate(adapter["copies"]):
        dest_rel, content, mode = _render_entry(
            entry,
            template=False,
            plugin_id=plugin["id"],
            plugin_version=plugin_version,
            runtime=runtime,
            bootstrap_abs=bootstrap_abs,
            exec_abs=exec_abs,
            adapter_dir=adapter_dir,
            plugin_output_dir=plugin_output_dir,
            context=f"adapters/{runtime}.json.copies[{index}]",
        )
        if dest_rel in rendered:
            _fail(f"duplicate generated destination: {dest_rel}")
        rendered[dest_rel] = (content, mode)
    for index, entry in enumerate(adapter["templates"]):
        dest_rel, content, mode = _render_entry(
            entry,
            template=True,
            plugin_id=plugin["id"],
            plugin_version=plugin_version,
            runtime=runtime,
            bootstrap_abs=bootstrap_abs,
            exec_abs=exec_abs,
            adapter_dir=adapter_dir,
            plugin_output_dir=plugin_output_dir,
            context=f"adapters/{runtime}.json.templates[{index}]",
        )
        if dest_rel in rendered:
            _fail(f"duplicate generated destination: {dest_rel}")
        rendered[dest_rel] = (content, mode)
    generated_paths = sorted(set(rendered.keys()) | {MANIFEST_NAME})
    source_descriptor = f"bundle/.ralph/plugin-inputs/adapters/{runtime}.json"
    manifest = {
        "generatedPaths": generated_paths,
        "pluginVersion": plugin_version,
        "schemaVersion": 1,
        "sourceDescriptor": source_descriptor,
    }
    rendered[MANIFEST_NAME] = (_dump_json(manifest), "0644")
    return rendered


def _existing_rel_paths(adapter_dir: str) -> list[str]:
    if not os.path.isdir(adapter_dir):
        return []
    found: list[str] = []
    for root, dirnames, filenames in os.walk(adapter_dir):
        dirnames[:] = [
            name
            for name in dirnames
            if not name.startswith(TEMP_DIR_PREFIX) and name != ".git"
        ]
        for name in filenames:
            abs_path = os.path.join(root, name)
            if os.path.islink(abs_path):
                continue
            rel = _posix_relpath(abs_path, adapter_dir)
            if rel.startswith(TEMP_DIR_PREFIX):
                continue
            found.append(rel)
    return sorted(found)


def _classify_drift(
    adapter_dir: str,
    output_rel_prefix: str,
    expected: dict[str, tuple[str, str]],
    previous_paths: list[str],
) -> list[str]:
    reports: list[str] = []
    existing = set(_existing_rel_paths(adapter_dir))
    expected_rels = set(expected.keys())
    for rel in sorted(expected_rels):
        abs_path = os.path.join(adapter_dir, rel.replace("/", os.sep))
        display = f"{output_rel_prefix}/{rel}"
        if rel not in existing:
            reports.append(f"added: {display}")
            continue
        current = _read_text(abs_path)
        content, mode = expected[rel]
        changed = current != content
        try:
            changed = changed or _file_mode(abs_path) != mode
        except OSError:
            changed = True
        if changed:
            reports.append(f"changed: {display}")
    extra = (existing | set(previous_paths)) - expected_rels
    for rel in sorted(extra):
        reports.append(f"removed: {output_rel_prefix}/{rel}")
    return reports


def _write_adapter(
    adapter_dir: str,
    plugin_output_dir: str,
    expected: dict[str, tuple[str, str]],
    previous_paths: list[str],
) -> None:
    os.makedirs(plugin_output_dir, exist_ok=True)
    parent = os.path.dirname(adapter_dir)
    os.makedirs(parent, exist_ok=True)
    tmp_dir = tempfile.mkdtemp(prefix=TEMP_DIR_PREFIX, dir=parent)
    try:
        _assert_contained(tmp_dir, plugin_output_dir, "temporary generation directory")
        for rel, (content, mode) in expected.items():
            dest = os.path.join(tmp_dir, rel.replace("/", os.sep))
            _assert_contained(dest, tmp_dir, rel)
            _atomic_write(dest, content, mode)
        for rel, (content, mode) in expected.items():
            dest = os.path.join(adapter_dir, rel.replace("/", os.sep))
            _assert_contained(dest, adapter_dir, rel)
            _assert_contained(dest, plugin_output_dir, rel)
            if os.path.isfile(dest) and not os.path.islink(dest):
                try:
                    if _read_text(dest) == content and _file_mode(dest) == mode:
                        continue
                except (OSError, SyncPluginError):
                    pass
            _atomic_write(dest, content, mode)
        for rel in previous_paths:
            if rel in expected:
                continue
            target = os.path.normpath(os.path.join(adapter_dir, rel.replace("/", os.sep)))
            _assert_contained(target, adapter_dir, f"manifest path {rel}")
            _assert_contained(target, plugin_output_dir, f"manifest path {rel}")
            if os.path.isfile(target) and not os.path.islink(target):
                os.remove(target)
        # Drop empty directories left behind by removed generated files (bottom-up).
        for root, dirnames, filenames in os.walk(adapter_dir, topdown=False):
            if os.path.realpath(root) == os.path.realpath(adapter_dir):
                continue
            try:
                _assert_contained(root, adapter_dir, "empty directory prune")
                _assert_contained(root, plugin_output_dir, "empty directory prune")
            except SyncPluginError:
                continue
            if not dirnames and not filenames:
                try:
                    os.rmdir(root)
                except OSError:
                    pass
    finally:
        for root, dirnames, filenames in os.walk(tmp_dir, topdown=False):
            for name in filenames:
                try:
                    os.unlink(os.path.join(root, name))
                except OSError:
                    pass
            for name in dirnames:
                try:
                    os.rmdir(os.path.join(root, name))
                except OSError:
                    pass
        try:
            os.rmdir(tmp_dir)
        except OSError:
            pass


def sync_plugin_assets(
    repo_root: str,
    *,
    check: bool = False,
    inputs_root: str | None = None,
) -> int:
    try:
        loaded = plugin_inputs.load_plugin_inputs(repo_root, inputs_root=inputs_root)
    except plugin_inputs.PluginInputError as exc:
        print(str(exc), file=sys.stderr)
        return 1
    reports: list[str] = []
    try:
        for adapter in loaded["adapters"]:
            expected = _render_adapter(loaded, adapter)
            adapter_dir = adapter["outputDirectoryRealPath"]
            previous = _load_previous_manifest(adapter_dir)
            prefix = adapter["outputDirectory"]
            adapter_reports = _classify_drift(adapter_dir, prefix, expected, previous)
            reports.extend(adapter_reports)
            if not check:
                _write_adapter(
                    adapter_dir,
                    loaded["outputRootRealPath"],
                    expected,
                    previous,
                )
    except SyncPluginError as exc:
        print(str(exc), file=sys.stderr)
        return 1
    if check:
        for line in reports:
            print(line)
        return 1 if reports else 0
    return 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="Generate Ralph host plugin packages from canonical plugin inputs."
    )
    parser.add_argument("--repo-root", required=True, help="Repository root used for containment")
    parser.add_argument(
        "--inputs-root",
        default=None,
        help="Optional plugin-inputs directory; defaults to bundle/.ralph/plugin-inputs",
    )
    parser.add_argument(
        "--check",
        action="store_true",
        help="Compare generated output without writing; exit nonzero on drift",
    )
    args = parser.parse_args(argv)
    return sync_plugin_assets(
        args.repo_root,
        check=args.check,
        inputs_root=args.inputs_root,
    )


if __name__ == "__main__":
    raise SystemExit(main())
