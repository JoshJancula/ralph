#!/usr/bin/env python3
"""Validate and normalize Ralph killswitch.json (schema version 2).

CLI:
  validate <file>   Exit 0 when valid; errors on stderr with source and JSON path.
  normalize <file>  Print deterministic canonical JSON on stdout.

No shell loading or source precedence lives here — file-level only.
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from typing import Any

SCHEMA_VERSION = 2

CANONICAL_KEYS = (
    "schema_version",
    "enabled",
    "dry_run",
    "banned_tools",
    "tool_denylist",
    "allowed_tools",
    "banned_paths",
    "allowed_paths",
    "allowed_commands",
    "allowed_patterns",
    "denied_argument_patterns",
    "custom_rules",
)

# Top-level scalar/list aliases: alias_key -> canonical_key
TOP_ALIASES: dict[str, str] = {
    "Enabled": "enabled",
    "dryRun": "dry_run",
    "bannedTools": "banned_tools",
    "toolDenylist": "tool_denylist",
    "allowedTools": "allowed_tools",
    "bannedPaths": "banned_paths",
    "allowedPaths": "allowed_paths",
    "allowedCommands": "allowed_commands",
    "allowedPatterns": "allowed_patterns",
    "deniedArgumentPatterns": "denied_argument_patterns",
    "customRules": "custom_rules",
}

STRING_LIST_KEYS = frozenset(
    {
        "banned_tools",
        "tool_denylist",
        "allowed_tools",
        "banned_paths",
        "allowed_paths",
        "allowed_commands",
        "allowed_patterns",
    }
)

DENIED_ARGUMENT_MODES = frozenset({"regex", "literal", "substring", "contains"})
CUSTOM_RULE_TARGETS = frozenset({"command"})


class KillswitchConfigError(Exception):
    """Config validation failure with JSON path and optional source path."""

    def __init__(self, message: str, json_path: str = "$", source: str = "") -> None:
        self.message = message
        self.json_path = json_path
        self.source = source
        super().__init__(self.format())

    def format(self) -> str:
        parts: list[str] = []
        if self.source:
            parts.append(self.source)
        parts.append(self.json_path)
        parts.append(self.message)
        return ": ".join(parts)


def _fail(path: str, message: str, source: str = "") -> None:
    raise KillswitchConfigError(message, json_path=path, source=source)


def _is_bool(value: Any) -> bool:
    return isinstance(value, bool)


def _is_int(value: Any) -> bool:
    return isinstance(value, int) and not isinstance(value, bool)


def _pointer(base: str, key: str | int) -> str:
    if isinstance(key, int):
        return f"{base}[{key}]"
    if base == "$":
        return f"$.{key}"
    return f"{base}.{key}"


def _load_raw(path: str) -> Any:
    try:
        with open(path, encoding="utf-8") as handle:
            raw = handle.read()
    except OSError as exc:
        raise KillswitchConfigError(
            f"unreadable file: {exc.strerror or exc}",
            json_path="$",
            source=path,
        ) from exc
    if not raw.strip():
        _fail("$", "file is empty", source=path)
    try:
        return json.loads(raw)
    except json.JSONDecodeError as exc:
        _fail("$", f"invalid JSON: {exc.msg}", source=path)


def _collect_tool_denylist_candidates(
    cfg: dict[str, Any], source: str
) -> list[tuple[str, Any]]:
    found: list[tuple[str, Any]] = []
    if "tool_denylist" in cfg:
        found.append(("$.tool_denylist", cfg["tool_denylist"]))
    if "toolDenylist" in cfg:
        found.append(("$.toolDenylist", cfg["toolDenylist"]))
    tools = cfg.get("tools")
    if "tools" in cfg:
        if not isinstance(tools, dict):
            _fail("$.tools", "must be an object", source=source)
        unknown = sorted(k for k in tools if k not in ("deny", "denylist"))
        if unknown:
            _fail(_pointer("$.tools", unknown[0]), "unknown key", source=source)
        if "deny" in tools:
            found.append(("$.tools.deny", tools["deny"]))
        if "denylist" in tools:
            found.append(("$.tools.denylist", tools["denylist"]))
    return found


def _collect_denied_argument_candidates(
    cfg: dict[str, Any], source: str
) -> list[tuple[str, Any]]:
    found: list[tuple[str, Any]] = []
    if "denied_argument_patterns" in cfg:
        found.append(("$.denied_argument_patterns", cfg["denied_argument_patterns"]))
    if "deniedArgumentPatterns" in cfg:
        found.append(("$.deniedArgumentPatterns", cfg["deniedArgumentPatterns"]))
    if "arguments" in cfg:
        arguments = cfg["arguments"]
        if not isinstance(arguments, dict):
            _fail("$.arguments", "must be an object", source=source)
        unknown = sorted(k for k in arguments if k != "denyPatterns")
        if unknown:
            _fail(_pointer("$.arguments", unknown[0]), "unknown key", source=source)
        if "denyPatterns" in arguments:
            found.append(("$.arguments.denyPatterns", arguments["denyPatterns"]))
    return found


def _resolve_scalar_or_list(
    cfg: dict[str, Any],
    canonical: str,
    source: str,
) -> tuple[str, Any] | None:
    """Return (json_path, raw_value) for a top-level field, or None if absent."""
    if canonical == "tool_denylist":
        present = _collect_tool_denylist_candidates(cfg, source)
    elif canonical == "denied_argument_patterns":
        present = _collect_denied_argument_candidates(cfg, source)
    else:
        present = []
        if canonical in cfg:
            present.append((_pointer("$", canonical), cfg[canonical]))
        for alias, target in TOP_ALIASES.items():
            if target != canonical:
                continue
            if alias in cfg:
                present.append((_pointer("$", alias), cfg[alias]))

    if len(present) > 1:
        paths = "+".join(p for p, _ in present)
        _fail(
            paths,
            f"duplicate alias for {canonical}",
            source=source,
        )
    if not present:
        return None
    return present[0]


def _validate_string_list(value: Any, path: str, source: str) -> list[str]:
    if not isinstance(value, list):
        _fail(path, "must be an array of strings", source=source)
    out: list[str] = []
    for index, item in enumerate(value):
        if not isinstance(item, str):
            _fail(_pointer(path, index), "must be a string", source=source)
        out.append(item)
    return out


def _validate_regex(pattern: str, path: str, source: str) -> None:
    try:
        re.compile(pattern)
    except re.error as exc:
        _fail(path, f"invalid regex: {exc}", source=source)


def _normalize_denied_argument_patterns(
    value: Any, path: str, source: str
) -> list[dict[str, Any]]:
    if not isinstance(value, list):
        _fail(path, "must be an array", source=source)
    out: list[dict[str, Any]] = []
    for index, item in enumerate(value):
        item_path = _pointer(path, index)
        if not isinstance(item, dict):
            _fail(item_path, "must be an object", source=source)
        unknown = sorted(
            k for k in item if k not in ("tool", "argument", "pattern", "mode")
        )
        if unknown:
            _fail(_pointer(item_path, unknown[0]), "unknown key", source=source)
        if "pattern" not in item:
            _fail(item_path, "missing required key pattern", source=source)
        pattern = item["pattern"]
        if not isinstance(pattern, str):
            _fail(_pointer(item_path, "pattern"), "must be a string", source=source)
        rule: dict[str, Any] = {}
        if "tool" in item:
            tool = item["tool"]
            if not isinstance(tool, str):
                _fail(_pointer(item_path, "tool"), "must be a string", source=source)
            rule["tool"] = tool
        if "argument" in item:
            argument = item["argument"]
            if not isinstance(argument, str):
                _fail(
                    _pointer(item_path, "argument"),
                    "must be a string",
                    source=source,
                )
            rule["argument"] = argument
        rule["pattern"] = pattern
        mode = item.get("mode", "regex")
        if not isinstance(mode, str):
            _fail(_pointer(item_path, "mode"), "must be a string", source=source)
        mode_norm = mode.strip().lower()
        if mode_norm not in DENIED_ARGUMENT_MODES:
            _fail(
                _pointer(item_path, "mode"),
                f"must be one of {sorted(DENIED_ARGUMENT_MODES)}",
                source=source,
            )
        rule["mode"] = mode_norm
        if mode_norm == "regex":
            _validate_regex(pattern, _pointer(item_path, "pattern"), source)
        out.append(rule)
    return out


def _normalize_custom_rules(value: Any, path: str, source: str) -> list[dict[str, Any]]:
    if not isinstance(value, list):
        _fail(path, "must be an array", source=source)
    out: list[dict[str, Any]] = []
    for index, item in enumerate(value):
        item_path = _pointer(path, index)
        if not isinstance(item, dict):
            _fail(item_path, "must be an object", source=source)
        unknown = sorted(
            k for k in item if k not in ("name", "match", "pattern", "target")
        )
        if unknown:
            _fail(_pointer(item_path, unknown[0]), "unknown key", source=source)
        if "name" not in item:
            _fail(item_path, "missing required key name", source=source)
        name = item["name"]
        if not isinstance(name, str):
            _fail(_pointer(item_path, "name"), "must be a string", source=source)
        has_match = "match" in item
        has_pattern = "pattern" in item
        if has_match and has_pattern:
            _fail(
                item_path,
                "must have exactly one of match or pattern",
                source=source,
            )
        if not has_match and not has_pattern:
            _fail(
                item_path,
                "must have exactly one of match or pattern",
                source=source,
            )
        rule: dict[str, Any] = {"name": name}
        if has_match:
            match = item["match"]
            if not isinstance(match, str):
                _fail(_pointer(item_path, "match"), "must be a string", source=source)
            rule["match"] = match
        else:
            pattern = item["pattern"]
            if not isinstance(pattern, str):
                _fail(
                    _pointer(item_path, "pattern"),
                    "must be a string",
                    source=source,
                )
            _validate_regex(pattern, _pointer(item_path, "pattern"), source)
            rule["pattern"] = pattern
        target = item.get("target", "command")
        if not isinstance(target, str):
            _fail(_pointer(item_path, "target"), "must be a string", source=source)
        if target not in CUSTOM_RULE_TARGETS:
            _fail(
                _pointer(item_path, "target"),
                "must be 'command'",
                source=source,
            )
        rule["target"] = target
        out.append(rule)
    return out


def normalize_config(data: Any, *, source: str = "") -> dict[str, Any]:
    """Validate raw config and return deterministic canonical dict."""
    if not isinstance(data, dict):
        _fail("$", "must be a JSON object", source=source)

    known_input_keys = set(CANONICAL_KEYS) | set(TOP_ALIASES) | {"tools", "arguments"}
    unknown = sorted(k for k in data if k not in known_input_keys)
    if unknown:
        _fail(_pointer("$", unknown[0]), "unknown key", source=source)

    # Reject nested alias containers when they collide with nothing else already
    # handled inside _resolve; still force tools/arguments type checks early.
    if "tools" in data and not isinstance(data["tools"], dict):
        _fail("$.tools", "must be an object", source=source)
    if "arguments" in data and not isinstance(data["arguments"], dict):
        _fail("$.arguments", "must be an object", source=source)

    out: dict[str, Any] = {}

    schema_hit = _resolve_scalar_or_list(data, "schema_version", source)
    if schema_hit is None:
        _fail("$.schema_version", "missing required key", source=source)
    schema_path, schema_version = schema_hit
    if not _is_int(schema_version):
        _fail(schema_path, "must be an integer", source=source)
    if schema_version != SCHEMA_VERSION:
        _fail(schema_path, f"must be {SCHEMA_VERSION}", source=source)
    out["schema_version"] = SCHEMA_VERSION

    enabled_hit = _resolve_scalar_or_list(data, "enabled", source)
    if enabled_hit is None:
        _fail("$.enabled", "missing required key", source=source)
    enabled_path, enabled = enabled_hit
    if not _is_bool(enabled):
        _fail(enabled_path, "must be a boolean", source=source)
    out["enabled"] = enabled

    dry_hit = _resolve_scalar_or_list(data, "dry_run", source)
    if dry_hit is None:
        _fail("$.dry_run", "missing required key", source=source)
    dry_path, dry_run = dry_hit
    if not _is_bool(dry_run):
        _fail(dry_path, "must be a boolean", source=source)
    out["dry_run"] = dry_run

    for key in STRING_LIST_KEYS:
        hit = _resolve_scalar_or_list(data, key, source)
        if hit is None:
            _fail(_pointer("$", key), "missing required key", source=source)
        path, raw = hit
        out[key] = _validate_string_list(raw, path, source)

    denied_hit = _resolve_scalar_or_list(data, "denied_argument_patterns", source)
    if denied_hit is None:
        _fail("$.denied_argument_patterns", "missing required key", source=source)
    denied_path, denied_raw = denied_hit
    out["denied_argument_patterns"] = _normalize_denied_argument_patterns(
        denied_raw, denied_path, source
    )

    custom_hit = _resolve_scalar_or_list(data, "custom_rules", source)
    if custom_hit is None:
        _fail("$.custom_rules", "missing required key", source=source)
    custom_path, custom_raw = custom_hit
    out["custom_rules"] = _normalize_custom_rules(custom_raw, custom_path, source)

    # Ensure stable key order matching CANONICAL_KEYS
    return {key: out[key] for key in CANONICAL_KEYS}


def dumps_normalized(config: dict[str, Any]) -> str:
    """Deterministic pretty JSON (2-space indent, trailing newline)."""
    return json.dumps(config, indent=2, ensure_ascii=False) + "\n"


def validate_file(path: str) -> dict[str, Any]:
    data = _load_raw(path)
    return normalize_config(data, source=path)


def normalize_file(path: str) -> str:
    return dumps_normalized(validate_file(path))


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="Validate or normalize Ralph killswitch.json (schema version 2)"
    )
    sub = parser.add_subparsers(dest="command", required=True)

    validate_cmd = sub.add_parser("validate", help="Validate a killswitch config file")
    validate_cmd.add_argument("file", help="Path to killswitch.json")

    normalize_cmd = sub.add_parser(
        "normalize", help="Print deterministic canonical JSON for a killswitch config"
    )
    normalize_cmd.add_argument("file", help="Path to killswitch.json")

    args = parser.parse_args(argv)
    try:
        if args.command == "validate":
            validate_file(args.file)
            return 0
        if args.command == "normalize":
            sys.stdout.write(normalize_file(args.file))
            return 0
    except KillswitchConfigError as exc:
        print(exc.format(), file=sys.stderr)
        return 1
    return 2


if __name__ == "__main__":
    raise SystemExit(main())
