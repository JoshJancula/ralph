#!/usr/bin/env python3
"""Line-filter DSL for simple shell compaction rules without custom Python functions."""

from __future__ import annotations

import json
import re
from dataclasses import dataclass, field
from typing import Any, Callable


@dataclass(frozen=True)
class DslLineFilterRule:
    """A single line-filter rule from the DSL."""

    rule_id: str
    command_matcher: str | list[str]
    strip_ansi: bool = False
    remove_lines: list[str] = field(default_factory=list)
    keep_lines: list[str] = field(default_factory=list)
    replacements: list[dict[str, str]] = field(default_factory=list)
    head: int | None = None
    tail: int | None = None
    max_lines: int | None = None
    output_header: str | None = None
    on_empty: str = "passthrough"
    only_on_exit_code: int | None = None
    skip_on_exit_code: int | None = None

    def should_apply(self, exit_status: int) -> bool:
        """Check if this rule should apply based on exit status conditions.

        Returns True if:
        - No exit-status conditions are set (backward compatible), OR
        - only_on_exit_code is set and exit_status matches, OR
        - skip_on_exit_code is set and exit_status does NOT match
        """
        if self.only_on_exit_code is not None:
            return exit_status == self.only_on_exit_code
        if self.skip_on_exit_code is not None:
            return exit_status != self.skip_on_exit_code
        return True

    def validate(self) -> list[str]:
        """Return list of validation errors, or empty list if valid."""
        errors = []

        if not self.rule_id:
            errors.append("rule_id must not be empty")

        if isinstance(self.command_matcher, str):
            if not self.command_matcher.strip():
                errors.append("command_matcher must not be empty string")
        elif isinstance(self.command_matcher, list):
            if not self.command_matcher:
                errors.append("command_matcher list must not be empty")
            for item in self.command_matcher:
                if not isinstance(item, str):
                    errors.append(f"command_matcher list items must be strings, got {type(item).__name__}")
        else:
            errors.append(
                f"command_matcher must be string or list of strings, got {type(self.command_matcher).__name__}"
            )

        for pattern in self.remove_lines:
            try:
                re.compile(pattern)
            except re.error as exc:
                errors.append(f"remove_lines pattern invalid: {pattern} - {exc}")

        for pattern in self.keep_lines:
            try:
                re.compile(pattern)
            except re.error as exc:
                errors.append(f"keep_lines pattern invalid: {pattern} - {exc}")

        for repl in self.replacements:
            if not isinstance(repl, dict):
                errors.append(f"replacements items must be dicts, got {type(repl).__name__}")
                continue
            if "pattern" not in repl:
                errors.append("replacements item missing required 'pattern' field")
                continue
            if "replacement" not in repl:
                errors.append("replacements item missing required 'replacement' field")
                continue
            try:
                re.compile(repl["pattern"])
            except re.error as exc:
                errors.append(f"replacements pattern invalid: {repl['pattern']} - {exc}")

        if self.head is not None and not isinstance(self.head, int):
            errors.append(f"head must be int or null, got {type(self.head).__name__}")
        if self.head is not None and self.head < 0:
            errors.append("head must be non-negative")

        if self.tail is not None and not isinstance(self.tail, int):
            errors.append(f"tail must be int or null, got {type(self.tail).__name__}")
        if self.tail is not None and self.tail < 0:
            errors.append("tail must be non-negative")

        if self.max_lines is not None and not isinstance(self.max_lines, int):
            errors.append(f"max_lines must be int or null, got {type(self.max_lines).__name__}")
        if self.max_lines is not None and self.max_lines < 0:
            errors.append("max_lines must be non-negative")

        if self.on_empty not in ("passthrough", "empty", "header"):
            errors.append(f"on_empty must be one of 'passthrough', 'empty', 'header', got '{self.on_empty}'")

        if self.only_on_exit_code is not None and not isinstance(self.only_on_exit_code, int):
            errors.append(f"only_on_exit_code must be int or null, got {type(self.only_on_exit_code).__name__}")

        if self.skip_on_exit_code is not None and not isinstance(self.skip_on_exit_code, int):
            errors.append(f"skip_on_exit_code must be int or null, got {type(self.skip_on_exit_code).__name__}")

        if self.only_on_exit_code is not None and self.skip_on_exit_code is not None:
            errors.append("only_on_exit_code and skip_on_exit_code cannot both be set")

        return errors


def load_dsl_rules(rules_json: str) -> tuple[list[DslLineFilterRule], list[str]]:
    """Load and validate DSL rules from JSON text.

    Returns (rules, errors). If any rules fail validation, that rule is skipped
    and the error is added to the errors list.
    """
    errors: list[str] = []
    rules: list[DslLineFilterRule] = []

    try:
        data = json.loads(rules_json)
    except json.JSONDecodeError as exc:
        return [], [f"JSON parse error: {exc}"]

    if not isinstance(data, dict):
        return [], ["Root must be a JSON object"]

    rules_list = data.get("rules", [])
    if not isinstance(rules_list, list):
        return [], ["'rules' field must be a list"]

    for index, rule_data in enumerate(rules_list):
        if not isinstance(rule_data, dict):
            errors.append(f"Rule {index}: must be an object, got {type(rule_data).__name__}")
            continue

        try:
            rule = _parse_rule_dict(rule_data)
        except ValueError as exc:
            errors.append(f"Rule {index}: {exc}")
            continue

        validation_errors = rule.validate()
        if validation_errors:
            for error in validation_errors:
                errors.append(f"Rule {index} ({rule.rule_id}): {error}")
            continue

        rules.append(rule)

    return rules, errors


def _parse_rule_dict(data: dict[str, Any]) -> DslLineFilterRule:
    """Parse a single rule dict into a DslLineFilterRule."""
    rule_id = data.get("rule_id")
    if not rule_id:
        raise ValueError("Missing required field 'rule_id'")
    if not isinstance(rule_id, str):
        raise ValueError(f"'rule_id' must be string, got {type(rule_id).__name__}")

    command_matcher = data.get("command_matcher")
    if command_matcher is None:
        raise ValueError("Missing required field 'command_matcher'")

    if isinstance(command_matcher, str):
        pass
    elif isinstance(command_matcher, list):
        if not all(isinstance(item, str) for item in command_matcher):
            raise ValueError("'command_matcher' list items must all be strings")
    else:
        raise ValueError(
            f"'command_matcher' must be string or list, got {type(command_matcher).__name__}"
        )

    strip_ansi = data.get("strip_ansi", False)
    if not isinstance(strip_ansi, bool):
        raise ValueError(f"'strip_ansi' must be boolean, got {type(strip_ansi).__name__}")

    remove_lines = data.get("remove_lines", [])
    if not isinstance(remove_lines, list):
        raise ValueError(f"'remove_lines' must be list, got {type(remove_lines).__name__}")
    if not all(isinstance(item, str) for item in remove_lines):
        raise ValueError("'remove_lines' items must all be strings")

    keep_lines = data.get("keep_lines", [])
    if not isinstance(keep_lines, list):
        raise ValueError(f"'keep_lines' must be list, got {type(keep_lines).__name__}")
    if not all(isinstance(item, str) for item in keep_lines):
        raise ValueError("'keep_lines' items must all be strings")

    replacements = data.get("replacements", [])
    if not isinstance(replacements, list):
        raise ValueError(f"'replacements' must be list, got {type(replacements).__name__}")

    head = data.get("head")
    if head is not None and not isinstance(head, int):
        raise ValueError(f"'head' must be int or null, got {type(head).__name__}")

    tail = data.get("tail")
    if tail is not None and not isinstance(tail, int):
        raise ValueError(f"'tail' must be int or null, got {type(tail).__name__}")

    max_lines = data.get("max_lines")
    if max_lines is not None and not isinstance(max_lines, int):
        raise ValueError(f"'max_lines' must be int or null, got {type(max_lines).__name__}")

    output_header = data.get("output_header")
    if output_header is not None and not isinstance(output_header, str):
        raise ValueError(f"'output_header' must be string or null, got {type(output_header).__name__}")

    on_empty = data.get("on_empty", "passthrough")
    if not isinstance(on_empty, str):
        raise ValueError(f"'on_empty' must be string, got {type(on_empty).__name__}")

    only_on_exit_code = data.get("only_on_exit_code")
    if only_on_exit_code is not None and not isinstance(only_on_exit_code, int):
        raise ValueError(f"'only_on_exit_code' must be int or null, got {type(only_on_exit_code).__name__}")

    skip_on_exit_code = data.get("skip_on_exit_code")
    if skip_on_exit_code is not None and not isinstance(skip_on_exit_code, int):
        raise ValueError(f"'skip_on_exit_code' must be int or null, got {type(skip_on_exit_code).__name__}")

    unknown_fields = set(data.keys()) - {
        "rule_id",
        "command_matcher",
        "strip_ansi",
        "remove_lines",
        "keep_lines",
        "replacements",
        "head",
        "tail",
        "max_lines",
        "output_header",
        "on_empty",
        "only_on_exit_code",
        "skip_on_exit_code",
    }
    if unknown_fields:
        raise ValueError(f"Unknown fields: {sorted(unknown_fields)}")

    return DslLineFilterRule(
        rule_id=rule_id,
        command_matcher=command_matcher,
        strip_ansi=strip_ansi,
        remove_lines=remove_lines,
        keep_lines=keep_lines,
        replacements=replacements,
        head=head,
        tail=tail,
        max_lines=max_lines,
        output_header=output_header,
        on_empty=on_empty,
        only_on_exit_code=only_on_exit_code,
        skip_on_exit_code=skip_on_exit_code,
    )


def compile_rule_matcher(command_matcher: str | list[str]) -> Callable[[str], bool]:
    """Compile a command_matcher into a classifier function."""
    if isinstance(command_matcher, str):
        matcher_str = command_matcher
        def match_string(command: str) -> bool:
            return _match_command_string(command, matcher_str)
        return match_string
    else:
        matcher_list = command_matcher
        def match_list(command: str) -> bool:
            return any(_match_command_string(command, m) for m in matcher_list)
        return match_list


def _match_command_string(command: str, matcher: str) -> bool:
    """Match a command against a matcher string.

    Supports:
    - Exact command name: "ls" matches "ls", "/bin/ls", etc.
    - Command prefix: "npm " (with trailing space) matches "npm test", "npm install", etc.
    - Regex: matcher starting with "/" and ending with "/" is treated as regex, e.g., "/^git .*status$/"
    """
    if not command or not matcher:
        return False

    command = command.strip()
    prefix_matcher = matcher.endswith(" ")
    matcher = matcher.strip()

    if not command or not matcher:
        return False

    if matcher.startswith("/") and matcher.endswith("/"):
        pattern = matcher[1:-1]
        try:
            return bool(re.search(pattern, command))
        except re.error:
            return False

    tokens = command.split()
    if not tokens:
        return False

    cmd_name = tokens[0].rstrip("/").split("/")[-1]

    if prefix_matcher:
        prefix_tokens = matcher.split()
        if len(tokens) <= len(prefix_tokens):
            return False
        for i, prefix_token in enumerate(prefix_tokens):
            if tokens[i] != prefix_token:
                return False
        return True

    return cmd_name == matcher or cmd_name == matcher.split("/")[-1]


def apply_line_filter_rule(rule: DslLineFilterRule, text: str, exit_status: int = 0) -> str:
    """Apply a single line-filter rule to text and return result.

    Args:
        rule: The line-filter rule to apply.
        text: The text to filter.
        exit_status: The exit status of the command (default 0). Used for exit-status-aware
                     filtering via only_on_exit_code and skip_on_exit_code fields.

    Returns:
        Filtered text, or original text if rule does not apply or result is empty per on_empty.
    """
    if not rule.should_apply(exit_status):
        return text

    lines = text.split("\n") if text else []

    if rule.strip_ansi:
        lines = [_strip_ansi(line) for line in lines]

    if rule.keep_lines:
        keep_patterns = [re.compile(p) for p in rule.keep_lines]
        filtered = [line for line in lines if any(p.search(line) for p in keep_patterns)]
        lines = filtered

    if rule.remove_lines:
        remove_patterns = [re.compile(p) for p in rule.remove_lines]
        filtered = [line for line in lines if not any(p.search(line) for p in remove_patterns)]
        lines = filtered

    for repl_spec in rule.replacements:
        pattern = repl_spec.get("pattern", "")
        replacement = repl_spec.get("replacement", "")
        try:
            compiled_pattern = re.compile(pattern)
            lines = [compiled_pattern.sub(replacement, line) for line in lines]
        except re.error:
            pass

    if rule.head is not None:
        lines = lines[: rule.head]

    if rule.tail is not None:
        lines = lines[-rule.tail:] if rule.tail > 0 else []

    if rule.max_lines is not None:
        lines = lines[: rule.max_lines]

    result_lines = []
    if rule.output_header:
        result_lines.append(rule.output_header)

    result_lines.extend(lines)
    result = "\n".join(result_lines)

    if not result.strip():
        if rule.on_empty == "passthrough":
            return text
        elif rule.on_empty == "empty":
            return ""
        elif rule.on_empty == "header":
            return rule.output_header or ""

    return result


def _strip_ansi(text: str) -> str:
    """Remove ANSI color/formatting codes from text."""
    return re.sub(r"\x1b\[[0-9;]*m", "", text)
