#!/usr/bin/env python3
"""Pure shell-output compactors for common command families (no I/O)."""

from __future__ import annotations

import importlib.util
import json
import os
import re
import sys
from collections import defaultdict
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Callable, Iterable

sys.path.insert(0, str(Path(__file__).resolve().parent))

from shell_command_registry import (
    CLASSIFIER_GIT_STATUS,
    CLASSIFIER_PYTEST,
    CLASSIFIER_TSC,
    FAMILY_BATS,
    FAMILY_DOCKER_LOGS,
    FAMILY_DOCKER_PS,
    FAMILY_ESLINT,
    FAMILY_FIND,
    FAMILY_GH_PR_LIST,
    FAMILY_GH_PR_VIEW,
    FAMILY_GIT_DIFF,
    FAMILY_GIT_LOG,
    FAMILY_GIT_SHOW,
    FAMILY_GIT_STATUS,
    FAMILY_GREP,
    FAMILY_KUBECTL,
    FAMILY_LS,
    FAMILY_NPM_TEST,
    FAMILY_PYTEST,
    FAMILY_SHELLCHECK,
    FAMILY_TREE,
    FAMILY_TSC,
    FAMILY_VITEST,
    classify_registry_family,
    classifier_for_family,
    should_bail,
)

# Compactor-only families (not in the shared rewrite registry).
FAMILY_CARGO_TEST = "cargo_test"
FAMILY_GO_TEST = "go_test"
FAMILY_GENERIC_LARGE = "generic_large"

_GENERIC_LARGE_MIN_BYTES = 4096
_GENERIC_LARGE_MIN_LINES = 80
_GENERIC_LARGE_HEAD_LINES = 30
_GENERIC_LARGE_TAIL_LINES = 5

# Size-triggered fallback when no family rule matches (RALPH_COMPACT_GENERIC_THRESHOLD_BYTES).
_GENERIC_FALLBACK_DEFAULT_THRESHOLD_BYTES = 8192
_GENERIC_FALLBACK_MAX_ERROR_LINES = 40
_GENERIC_FALLBACK_ERROR_RE = re.compile(r"error|fail|fatal|exception|not ok", re.IGNORECASE)

# Failure-aware compaction for non-zero exits (RALPH_COMPACT_FAILURE; default on).
FAMILY_FAILURE_AWARE = "failure_aware"
_FAILURE_AWARE_MIN_BYTES = 512
_FAILURE_AWARE_HEAD_LINES = 20
_FAILURE_AWARE_TAIL_LINES = 8
_FAILURE_AWARE_MAX_PRESERVE_LINES = 60


@dataclass(frozen=True)
class _GenericPatternClass:
    class_id: str
    label: str
    pattern: re.Pattern[str]
    min_run: int = 3


_GENERIC_PATTERN_CLASSES: tuple[_GenericPatternClass, ...] = (
    _GenericPatternClass(
        "progress",
        "progress/spinner",
        re.compile(
            r"(?:^\s*[\|\\/\-]\s*$"
            r"|^\[[#=>.\s\-]+\]"
            r"|^\.\.\.\s*\d+%"
            r"|^(?:Downloading|Downloaded|Extracting|Resolving deltas|Building|"
            r"Compiling|Linking|Running \.\.\.|Remoting work)\b)",
            re.IGNORECASE,
        ),
    ),
    _GenericPatternClass(
        "dependency",
        "dependency-resolution",
        re.compile(
            r"^(?:Collecting |Installing collected packages|"
            r"Requirement already satisfied|Looking in indexes|  Downloading|  Installing|"
            r"Using cached |Get:\d+ |Reading database|Unpacking |Preparing to unpack|"
            r"Selecting previously unselected|Fetched \d+ |Downloading from|"
            r"> Task :|mvn (?:\[INFO\]|\[WARNING\])|gradle |CMake Dep|"
            r"Scanning dependencies of target|\[\d+/\d+\] Building|"
            r"MSBUILD : warning )",
            re.IGNORECASE,
        ),
    ),
    _GenericPatternClass(
        "warning",
        "compiler warning",
        re.compile(
            r"^\s*(?:warning|warn|\[warn\]|\[warning\]|caution)\b",
            re.IGNORECASE,
        ),
        min_run=5,
    ),
    _GenericPatternClass(
        "test_pass",
        "passing test line",
        re.compile(
            r"^(?:PASSED\s|passed\b|test result: ok\b|"
            r"^\s*ok\s+\S+\s+[\d.]+s|^\s*--- PASS:)",
            re.IGNORECASE,
        ),
        min_run=4,
    ),
    _GenericPatternClass(
        "stack_frame",
        "stack trace frame",
        re.compile(
            r"^(?:\s+at |\s+File \".*\", line |\s+in |\s+#\d+ |\s+\^+|Caused by:|"
            r"Traceback \(most recent call last\))",
            re.IGNORECASE,
        ),
        min_run=3,
    ),
)

_GENERIC_PRESERVE_RE = re.compile(
    r"error|fail|fatal|exception|not ok|FAILED|BUILD FAILED|ERROR:|panic!|"
    r"assertion failed|Test Run Failed|BUILD SUCCESS|tests? failed|"
    r"===+.*===+|SUMMARY|Successfully installed|Exit code|"
    r"Tests run:|FAIL\s+\[|FAIL\s+\S",
    re.IGNORECASE,
)

_GENERIC_SUMMARY_RE = re.compile(
    r"(?:^(?:FAILED|ERROR|SUMMARY|BUILD|Tests run:|Test Run |"
    r"=\s*\d+\s+(?:passed|failed)|Successfully |"
    r"\d+ tests? (?:passed|failed)|FAIL\s|ok\s+\S+\s+[\d.]+s|"
    r"Total time:|Finished at:))",
    re.IGNORECASE,
)

_BATS_OK_RE = re.compile(r"^ok\s+\d+\s+")
_BATS_NOT_OK_RE = re.compile(r"^not ok\s+\d+\s+")
_BATS_PLAN_RE = re.compile(r"^1\.\.\d+\s*$")
_GIT_STATUS_SHORT_RE = re.compile(r"^[MADRCU?! ]{2} \S")
_GIT_DIFF_STAT_FILE_RE = re.compile(r"^\s+(.+?)\s+\|\s+(\d+)\s+([+-]+)\s*$")
_GIT_DIFF_GIT_RE = re.compile(r"^diff --git ")
_GIT_DIFF_HUNK_RE = re.compile(r"^@@\s")
_GREP_RG_FILE_RE = re.compile(r"^(.+?)(?::(\d+))?:(.+)$")

# Test/build command patterns
_PYTEST_PASSED_RE = re.compile(r"^=+\s+(\d+)\s+passed")
_PYTEST_FAILED_RE = re.compile(r"^=+\s+(\d+)\s+failed")
_PYTEST_ERROR_RE = re.compile(r"^=+\s+(\d+)\s+error")
_PYTEST_SKIPPED_RE = re.compile(r"^=+\s+(\d+)\s+skipped")
_PYTEST_TEST_RE = re.compile(r"^(FAILED|PASSED|ERROR|SKIPPED)\s+(.+?)\s+-\s+")
_VITEST_PASSED_RE = re.compile(r"^✓.*\d+\s+passed")
_VITEST_FAILED_RE = re.compile(r"^✕.*\d+\s+failed")
_JEST_PASSED_RE = re.compile(r"^(PASS|FAIL)\s+")
_TSC_ERROR_RE = re.compile(r"^(.+?)\(\d+,\d+\):\s+error\s+TS\d+:")
_GO_TEST_PASS_RE = re.compile(r"^ok\s+")
_GO_TEST_FAIL_RE = re.compile(r"^FAIL\s+")
_CARGO_TEST_PASS_RE = re.compile(r"^test\s+.+\s+\.\.\.\s+ok$")
_CARGO_TEST_FAIL_RE = re.compile(r"^test\s+.+\s+\.\.\.\s+FAILED$")

# Operational and listing command patterns
_LS_LONG_FORMAT_RE = re.compile(r"^[-drwxlstSugT.@+]+\s+")
_TREE_LINE_RE = re.compile(r"^[|\\`\-\s]*[|`\\]")
_DOCKER_PS_HEADER_RE = re.compile(r"^CONTAINER ID\s+IMAGE\s+")
_DOCKER_LOGS_TIMESTAMP_RE = re.compile(r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}")
_KUBECTL_RESOURCE_LINE_RE = re.compile(r"^[a-zA-Z0-9\-_.]+\s+")
_GH_PR_FIELD_RE = re.compile(r"^[a-zA-Z]+:\s+")

CommandClassifier = Callable[[str], bool]
CompactorFn = Callable[[str, str, str, int], tuple[str, str, bool]]
ShapeDetector = Callable[[str], bool]


@dataclass(frozen=True)
class CompactorFamily:
    family_id: str
    classifier: CommandClassifier
    compactor: CompactorFn
    safety_metadata: dict[str, object] = field(default_factory=dict)


@dataclass(frozen=True)
class CompactResult:
    stdout: str
    stderr: str
    compacted: bool
    stdout_compacted: bool
    stderr_compacted: bool
    family: str | None
    status: str
    exit_status: int = 0

    def to_dict(self) -> dict[str, object]:
        return {
            "stdout": self.stdout,
            "stderr": self.stderr,
            "compacted": self.compacted,
            "stdout_compacted": self.stdout_compacted,
            "stderr_compacted": self.stderr_compacted,
            "family": self.family,
            "status": self.status,
            "exit_status": self.exit_status,
        }


def compact_shell_output(
    command: str,
    stdout: str,
    stderr: str,
    exit_status: int,
) -> CompactResult:
    """
    Dispatch to a family compactor or pass output through unchanged.

    Primary path: command-based classification.
    Fallback path: shape detection when command is unknown/incomplete.
    Size-triggered generic compaction when no family rule matches and combined
    output exceeds RALPH_COMPACT_GENERIC_THRESHOLD_BYTES.
    Failure-aware compaction on non-zero exit when family rules decline or
    output is below the generic threshold (RALPH_COMPACT_FAILURE=0 opts out).
    """
    stdout = stdout if stdout is not None else ""
    stderr = stderr if stderr is not None else ""
    combined_original = _join_streams(stdout, stderr)
    if _has_binary(stdout) or _has_binary(stderr):
        return _not_compacted(command, stdout, stderr, exit_status)

    family_id = classify_command(command)
    if family_id is None and _command_allows_shape_fallback(command):
        family_id = detect_output_shape(combined_original)

    family_entry = _FAMILY_MAP.get(family_id) if family_id is not None else None
    if family_entry is None:
        generic_result = _generic_size_fallback(
            command, stdout, stderr, exit_status, combined_original
        )
        if generic_result.status == "compacted" or exit_status == 0:
            return generic_result
        failure_result = _failure_aware_fallback(
            command, stdout, stderr, exit_status, combined_original
        )
        if failure_result.status == "compacted":
            return failure_result
        return generic_result

    out_stdout, out_stderr, did = family_entry.compactor(
        command, stdout, stderr, exit_status
    )
    if not did:
        return _finish_with_failure_fallback(
            command, stdout, stderr, exit_status, combined_original
        )
    combined_candidate = _join_streams(out_stdout, out_stderr)
    if not _safety_gate_passes(family_entry, combined_original, combined_candidate):
        return _not_compacted(command, stdout, stderr, exit_status)

    stdout_compacted = out_stdout != stdout
    stderr_compacted = out_stderr != stderr
    return CompactResult(
        stdout=out_stdout,
        stderr=out_stderr,
        compacted=stdout_compacted or stderr_compacted,
        stdout_compacted=stdout_compacted,
        stderr_compacted=stderr_compacted,
        family=family_entry.family_id,
        status="compacted",
        exit_status=exit_status,
    )


def _classifier_cargo_test(command: str) -> bool:
    tokens = (command or "").strip().lower().split()
    return len(tokens) >= 2 and tokens[0] == "cargo" and tokens[1] == "test"


def _classifier_go_test(command: str) -> bool:
    tokens = (command or "").strip().lower().split()
    return len(tokens) >= 2 and tokens[0] == "go" and tokens[1] == "test"


def _unwrap_native_shell_wrapper_command(command: str) -> str:
    cmd = (command or "").strip()
    if not cmd:
        return cmd
    match = re.search(
        r"native-shell-wrapper\.sh\b.*\b--command\s+(['\"])(.+?)\1",
        cmd,
        re.DOTALL,
    )
    if match:
        return match.group(2)
    return cmd


def classify_command(command: str) -> str | None:
    """Return a compactor family id for a simple command, or None."""
    cmd = _unwrap_native_shell_wrapper_command(command)
    if not cmd:
        return None
    family = classify_registry_family(cmd)
    if family is not None:
        return family
    if should_bail(cmd):
        return None
    core_entries = [
        entry
        for entry in _FAMILY_REGISTRY
        if not entry.family_id.startswith("dsl:")
    ]
    dsl_entries = [
        entry for entry in _FAMILY_REGISTRY if entry.family_id.startswith("dsl:")
    ]
    for entry in core_entries + dsl_entries:
        if entry.classifier(cmd):
            return entry.family_id
    return None


def _command_allows_shape_fallback(command: str) -> bool:
    """Shape detection applies only when the command string is empty or unknown."""
    cmd = (command or "").strip()
    if not cmd:
        return True
    if should_bail(cmd):
        return False
    return classify_command(command) is None


def _detect_shape_git_diff(text: str) -> bool:
    """Detect git diff output: diff --git, @@, or stat lines."""
    lines = text.splitlines()
    if not lines:
        return False
    has_diff_header = any(_GIT_DIFF_GIT_RE.match(line) for line in lines)
    has_hunks = any(_GIT_DIFF_HUNK_RE.match(line) for line in lines)
    has_stat = any(_GIT_DIFF_STAT_FILE_RE.match(line) for line in lines)
    return has_diff_header or has_hunks or has_stat


def _detect_shape_git_status(text: str) -> bool:
    """Detect git status output: ## branch header or status short format."""
    lines = text.splitlines()
    if not lines:
        return False
    if any(_GIT_DIFF_GIT_RE.match(line) or _GIT_DIFF_HUNK_RE.match(line) for line in lines):
        return False
    has_branch = any(line.startswith("## ") for line in lines)
    has_status = any(_GIT_STATUS_SHORT_RE.match(line) for line in lines)
    return has_branch or has_status


def _detect_shape_grep_style(text: str) -> bool:
    """Detect grep-style output: file:line:content pattern."""
    lines = text.splitlines()
    if len(lines) < 3:
        return False
    matching_lines = sum(1 for line in lines if _GREP_RG_FILE_RE.match(line))
    return matching_lines >= len(lines) * 0.7


def _detect_shape_path_list(text: str) -> bool:
    """Detect path list output: lines starting with ./ or / or common path prefixes."""
    lines = [line.strip() for line in text.splitlines() if line.strip()]
    if len(lines) < 5:
        return False
    path_like = sum(
        1
        for line in lines
        if line.startswith("./") or line.startswith("/") or "/" in line
    )
    return path_like >= len(lines) * 0.8


def _detect_shape_tree_glyph(text: str) -> bool:
    """Detect tree output: lines with tree glyphs like |, `, -, \\."""
    lines = text.splitlines()
    if len(lines) < 5:
        return False
    tree_like = sum(1 for line in lines if _TREE_LINE_RE.match(line))
    return tree_like >= len(lines) * 0.5


def _detect_shape_ls_long_format(text: str) -> bool:
    """Detect ls -la output: lines with permission rows like drwxr-xr-x."""
    lines = text.splitlines()
    if len(lines) < 5:
        return False
    ls_like = sum(1 for line in lines if _LS_LONG_FORMAT_RE.match(line))
    return ls_like >= len(lines) * 0.6


def _detect_shape_numbered_dump(text: str) -> bool:
    """Detect numbered output: lines like '123 some content' or '[456] label'."""
    lines = text.splitlines()
    if len(lines) < 5:
        return False
    numbered = sum(
        1
        for line in lines
        if re.match(r"^\s*\d+[\s:\)\]\.]\s+", line) or re.match(r"^\[\d+\]\s+", line)
    )
    return numbered >= len(lines) * 0.6


def _detect_shape_repeated_logs(text: str) -> bool:
    """Detect repeated log lines: many identical or near-identical lines."""
    lines = [line.strip() for line in text.splitlines() if line.strip()]
    if len(lines) < 10:
        return False
    line_counts: dict[str, int] = defaultdict(int)
    for line in lines:
        line_counts[line] += 1
    max_count = max(line_counts.values()) if line_counts else 0
    return max_count >= 3 and max_count > len(line_counts) * 0.2


def _detect_shape_generic_large_text(text: str) -> bool:
    """Detect large plain-text output suitable for head/tail truncation."""
    if not text.strip():
        return False
    byte_len = len(text.encode("utf-8"))
    if byte_len < _GENERIC_LARGE_MIN_BYTES:
        return False
    non_empty_lines = [line for line in text.splitlines() if line.strip()]
    return len(non_empty_lines) >= _GENERIC_LARGE_MIN_LINES


def detect_output_shape(text: str) -> str | None:
    """
    Detect output shape when command is unknown or unavailable.
    Returns family_id if a shape is strongly detected, None otherwise.
    This is a fallback; command-based classification is primary.
    """
    if not text or not text.strip():
        return None
    if _has_binary(text):
        return None

    structural: list[tuple[str, ShapeDetector]] = [
        (FAMILY_GIT_DIFF, _detect_shape_git_diff),
        (FAMILY_GIT_STATUS, _detect_shape_git_status),
        (FAMILY_GREP, _detect_shape_grep_style),
        (FAMILY_TREE, _detect_shape_tree_glyph),
        (FAMILY_LS, _detect_shape_ls_long_format),
        (FAMILY_FIND, _detect_shape_path_list),
        (FAMILY_DOCKER_LOGS, _detect_shape_repeated_logs),
    ]
    generic: list[tuple[str, ShapeDetector]] = [
        (FAMILY_GENERIC_LARGE, _detect_shape_numbered_dump),
        (FAMILY_GENERIC_LARGE, _detect_shape_generic_large_text),
    ]

    structural_matches = [family_id for family_id, detector in structural if detector(text)]
    structural_unique = list(dict.fromkeys(structural_matches))
    if len(structural_unique) > 1:
        return None
    if len(structural_unique) == 1:
        return structural_unique[0]

    generic_matches = [family_id for family_id, detector in generic if detector(text)]
    generic_unique = list(dict.fromkeys(generic_matches))
    if len(generic_unique) == 1:
        return generic_unique[0]
    return None


def _has_binary(text: str) -> bool:
    return "\x00" in text


def _not_compacted(
    command: str,
    stdout: str,
    stderr: str,
    exit_status: int,
) -> CompactResult:
    _ = command
    return CompactResult(
        stdout=stdout,
        stderr=stderr,
        compacted=False,
        stdout_compacted=False,
        stderr_compacted=False,
        family=None,
        status="not compacted",
        exit_status=exit_status,
    )


def _generic_fallback_threshold_bytes() -> int:
    """Threshold for the size-triggered generic fallback.

    Reads RALPH_COMPACT_GENERIC_THRESHOLD_BYTES; non-integer or negative
    values fall back to the default.
    """
    raw = os.environ.get("RALPH_COMPACT_GENERIC_THRESHOLD_BYTES", "").strip()
    if not raw:
        return _GENERIC_FALLBACK_DEFAULT_THRESHOLD_BYTES
    try:
        value = int(raw)
    except ValueError:
        return _GENERIC_FALLBACK_DEFAULT_THRESHOLD_BYTES
    if value < 0:
        return _GENERIC_FALLBACK_DEFAULT_THRESHOLD_BYTES
    return value


def _generic_size_fallback(
    command: str,
    stdout: str,
    stderr: str,
    exit_status: int,
    combined_original: str,
) -> CompactResult:
    """Size-triggered fallback for oversized output with no matching family.

    Emits head + tail plus error/failure lines extracted from the elided
    middle region, reporting family "generic_large" and status "compacted"
    so telemetry and the stored-output footer behave like any other family.
    """
    original_bytes = len(combined_original.encode("utf-8"))
    if original_bytes <= _generic_fallback_threshold_bytes():
        return _not_compacted(command, stdout, stderr, exit_status)

    body = _format_generic_large_output(command, combined_original, exit_status)
    if body is None:
        return _not_compacted(command, stdout, stderr, exit_status)

    out_stdout, out_stderr = (body, "") if stdout.strip() else ("", body)
    candidate_combined = _join_streams(out_stdout, out_stderr)
    if not _safety_gate_passes(
        _FAMILY_MAP.get(FAMILY_GENERIC_LARGE), combined_original, candidate_combined
    ):
        return _not_compacted(command, stdout, stderr, exit_status)
    # Pure size reduction is the only goal here; never grow the output
    # (the gate's small-output allowance does not apply to this path).
    if len(candidate_combined.encode("utf-8")) >= original_bytes:
        return _not_compacted(command, stdout, stderr, exit_status)

    stdout_compacted = out_stdout != stdout
    stderr_compacted = out_stderr != stderr
    return CompactResult(
        stdout=out_stdout,
        stderr=out_stderr,
        compacted=stdout_compacted or stderr_compacted,
        stdout_compacted=stdout_compacted,
        stderr_compacted=stderr_compacted,
        family=FAMILY_GENERIC_LARGE,
        status="compacted",
        exit_status=exit_status,
    )


def _failure_compaction_enabled() -> bool:
    """Return False when RALPH_COMPACT_FAILURE opts out (0/false/no/off)."""
    raw = os.environ.get("RALPH_COMPACT_FAILURE", "1").strip().lower()
    return raw not in ("0", "false", "no", "off")


def _collect_preserve_lines(lines: list[str]) -> list[str]:
    return [line for line in lines if _should_preserve_generic_line(line)]


def _failure_aware_summary_prefix(
    command: str,
    text: str,
    exit_status: int,
    original_line_count: int,
    omitted_stats: dict[str, int],
) -> str:
    label = command.strip() or "(unknown command)"
    summary = (
        f"failure output (exit {exit_status}): {original_line_count} line(s), "
        f"{len(text.encode('utf-8'))} byte(s) for: {label}"
    )
    if omitted_stats:
        omission_parts = [
            f"{count} {_pattern_class_label(class_id)}"
            for class_id, count in sorted(omitted_stats.items())
        ]
        summary += f" (collapsed: {', '.join(omission_parts)})"
    return summary


def _format_failure_aware_output(
    command: str,
    text: str,
    exit_status: int,
) -> str | None:
    lines = text.splitlines()
    if not lines:
        return None

    preserve_lines = _collect_preserve_lines(lines)
    collapsed_lines, omitted_stats = _collapse_generic_pattern_runs(lines)
    if not preserve_lines and not omitted_stats:
        return None

    working_lines = collapsed_lines
    max_kept = _FAILURE_AWARE_HEAD_LINES + _FAILURE_AWARE_TAIL_LINES

    if len(working_lines) <= max_kept:
        if not omitted_stats and working_lines == lines:
            return None
        summary = _failure_aware_summary_prefix(
            command, text, exit_status, len(lines), omitted_stats
        )
        return summary + "\n" + "\n".join(working_lines)

    head = working_lines[:_FAILURE_AWARE_HEAD_LINES]
    tail = working_lines[len(working_lines) - _FAILURE_AWARE_TAIL_LINES :]
    middle = working_lines[
        _FAILURE_AWARE_HEAD_LINES : len(working_lines) - _FAILURE_AWARE_TAIL_LINES
    ]
    important_lines = [line for line in middle if _should_preserve_generic_line(line)]
    extra_important_count = max(
        0, len(important_lines) - _FAILURE_AWARE_MAX_PRESERVE_LINES
    )
    important_lines = important_lines[:_FAILURE_AWARE_MAX_PRESERVE_LINES]

    summary = _failure_aware_summary_prefix(
        command, text, exit_status, len(lines), omitted_stats
    )
    body_lines = [summary]
    body_lines.extend(head)
    if middle:
        body_lines.append(f"... ({len(middle)} line(s) omitted) ...")
    if important_lines:
        body_lines.append("error/assertion line(s) from omitted region:")
        body_lines.extend(important_lines)
        if extra_important_count:
            body_lines.append(
                f"... ({extra_important_count} more matching line(s) omitted) ..."
            )
    body_lines.extend(tail)
    return "\n".join(body_lines)


def _failure_aware_fallback(
    command: str,
    stdout: str,
    stderr: str,
    exit_status: int,
    combined_original: str,
) -> CompactResult:
    """Conservative compaction for failed commands with noisy output."""
    if exit_status == 0 or not _failure_compaction_enabled():
        return _not_compacted(command, stdout, stderr, exit_status)

    original_bytes = len(combined_original.encode("utf-8"))
    if original_bytes <= _FAILURE_AWARE_MIN_BYTES:
        return _not_compacted(command, stdout, stderr, exit_status)

    preserve_lines = _collect_preserve_lines(combined_original.splitlines())
    body = _format_failure_aware_output(command, combined_original, exit_status)
    if body is None:
        return _not_compacted(command, stdout, stderr, exit_status)

    if preserve_lines:
        missing = [line for line in preserve_lines if line not in body]
        if missing:
            return _not_compacted(command, stdout, stderr, exit_status)

    candidate_bytes = len(body.encode("utf-8"))
    if candidate_bytes >= original_bytes:
        return _not_compacted(command, stdout, stderr, exit_status)

    failure_entry = _FAMILY_MAP.get(FAMILY_FAILURE_AWARE)
    if failure_entry is not None and not _safety_gate_passes(
        failure_entry, combined_original, body
    ):
        return _not_compacted(command, stdout, stderr, exit_status)

    out_stdout, out_stderr = (body, "") if stdout.strip() else ("", body)
    stdout_compacted = out_stdout != stdout
    stderr_compacted = out_stderr != stderr
    return CompactResult(
        stdout=out_stdout,
        stderr=out_stderr,
        compacted=stdout_compacted or stderr_compacted,
        stdout_compacted=stdout_compacted,
        stderr_compacted=stderr_compacted,
        family=FAMILY_FAILURE_AWARE,
        status="compacted",
        exit_status=exit_status,
    )


def _finish_with_failure_fallback(
    command: str,
    stdout: str,
    stderr: str,
    exit_status: int,
    combined_original: str,
) -> CompactResult:
    if exit_status != 0:
        failure_result = _failure_aware_fallback(
            command, stdout, stderr, exit_status, combined_original
        )
        if failure_result.status == "compacted":
            return failure_result
    return _not_compacted(command, stdout, stderr, exit_status)


def _compact_bats(
    command: str,
    stdout: str,
    stderr: str,
    exit_status: int,
) -> tuple[str, str, bool]:
    combined = _join_streams(stdout, stderr)
    if not combined.strip():
        return stdout, stderr, False

    lines = combined.splitlines()
    failures = _extract_bats_failures(lines)
    if failures or exit_status != 0:
        if not failures and exit_status != 0:
            return stdout, stderr, False
        body = _format_bats_failure_output(command, lines, failures, exit_status)
        return body, "", True

    ok_count = sum(1 for line in lines if _BATS_OK_RE.match(line))
    plan = next((line for line in lines if _BATS_PLAN_RE.match(line)), None)
    total = None
    if plan:
        try:
            total = int(plan.split("..", 1)[1])
        except (IndexError, ValueError):
            total = None
    count = total if total is not None else ok_count
    summary = f"bats: {count} test(s) passed (exit {exit_status})"
    if plan:
        summary = f"{plan}\n{summary}"
    return summary, "", True


def _extract_bats_failures(lines: list[str]) -> list[list[str]]:
    blocks: list[list[str]] = []
    index = 0
    while index < len(lines):
        line = lines[index]
        if _BATS_NOT_OK_RE.match(line):
            block = [line]
            index += 1
            while index < len(lines):
                nxt = lines[index]
                if _BATS_OK_RE.match(nxt) or _BATS_NOT_OK_RE.match(nxt):
                    break
                if _BATS_PLAN_RE.match(nxt):
                    break
                block.append(nxt)
                index += 1
            blocks.append(block)
            continue
        index += 1
    return blocks


def _format_bats_failure_output(
    command: str,
    lines: list[str],
    failures: list[list[str]],
    exit_status: int,
) -> str:
    plan = next((line for line in lines if _BATS_PLAN_RE.match(line)), None)
    ok_count = sum(1 for line in lines if _BATS_OK_RE.match(line))
    parts = [f"bats failures (exit {exit_status}) for: {command.strip()}"]
    if plan:
        parts.append(plan)
    if ok_count:
        parts.append(f"({ok_count} passing test(s) omitted)")
    for block in failures:
        parts.extend(block)
    return "\n".join(parts)


_GIT_STATUS_PORCELAIN_V2_RE = re.compile(
    r"^[12u?!] "
)


def _parse_git_status_long_format(
    lines: list[str],
) -> tuple[str, "dict[str, int]", "list[str]"]:
    """Parse long-format or porcelain=v2 git status output into (branch, counts, paths)."""
    branch = ""
    counts: dict[str, int] = defaultdict(int)
    paths: list[str] = []

    # Detect porcelain=v2 format by looking for "# branch." header lines
    is_porcelain_v2 = any(line.startswith("# branch.") for line in lines)
    if is_porcelain_v2:
        return _parse_git_status_porcelain_v2(lines)

    # Parse long format
    section: str | None = None
    _STAGED_KEYWORD_CODES = {
        "new file:": ("A ", "added"),
        "modified:": ("M ", "modified"),
        "deleted:": ("D ", "deleted"),
        "renamed:": ("R ", "modified"),
        "copied:": ("C ", "modified"),
        "both modified:": ("U ", "modified"),
    }
    _UNSTAGED_KEYWORD_CODES = {
        "modified:": (" M", "modified"),
        "deleted:": (" D", "deleted"),
        "renamed:": (" R", "modified"),
    }
    for line in lines:
        if line.startswith("On branch "):
            branch = line[len("On branch "):].strip()
            continue
        stripped = line.strip()
        if stripped == "Changes to be committed:":
            section = "staged"
            continue
        if stripped == "Changes not staged for commit:":
            section = "unstaged"
            continue
        if stripped == "Untracked files:":
            section = "untracked"
            continue
        if stripped in (
            "Changes staged for commit:",
            "All conflicts fixed but you are still merging.",
        ):
            section = "staged"
            continue
        if not line.startswith("\t"):
            continue
        entry = line[1:]
        if section == "untracked":
            if entry.startswith("("):
                continue
            paths.append(f"?? {entry}")
            counts["untracked"] += 1
        elif section == "staged":
            for kw, (code, label) in _STAGED_KEYWORD_CODES.items():
                if entry.startswith(kw):
                    path = entry[len(kw):].lstrip()
                    paths.append(f"{code} {path}")
                    counts[label] += 1
                    break
        elif section == "unstaged":
            for kw, (code, label) in _UNSTAGED_KEYWORD_CODES.items():
                if entry.startswith(kw):
                    path = entry[len(kw):].lstrip()
                    paths.append(f"{code} {path}")
                    counts[label] += 1
                    break
    return branch, counts, paths


def _parse_git_status_porcelain_v2(
    lines: list[str],
) -> tuple[str, "dict[str, int]", "list[str]"]:
    """Parse git status --porcelain=v2 --branch output."""
    branch = ""
    counts: dict[str, int] = defaultdict(int)
    paths: list[str] = []
    _XY_LABEL = {
        "M": "modified", "A": "added", "D": "deleted",
        "R": "modified", "C": "modified", "U": "modified",
    }
    for line in lines:
        if line.startswith("# branch.head "):
            branch = line[len("# branch.head "):].strip()
            continue
        if line.startswith("? "):
            path = line[2:]
            paths.append(f"?? {path}")
            counts["untracked"] += 1
            continue
        if line.startswith("! "):
            path = line[2:]
            paths.append(f"!! {path}")
            counts["ignored"] += 1
            continue
        # Ordinary changed: "1 XY N... hash hash hash path"
        if line.startswith("1 ") and len(line) > 2:
            parts = line.split(" ", 9)
            if len(parts) >= 9:
                xy = parts[1]
                path = parts[8] if len(parts) > 8 else ""
                code = xy[:2] if len(xy) >= 2 else "??"
                label = _XY_LABEL.get(xy[0] if xy[0] != "." else (xy[1] if len(xy) > 1 else "?"), "modified")
                paths.append(f"{code} {path}")
                counts[label] += 1
            continue
        # Renamed/copied: "2 XY N... hash hash hash score path\torig"
        if line.startswith("2 ") and len(line) > 2:
            parts = line.split(" ", 9)
            if len(parts) >= 9:
                xy = parts[1]
                path_part = parts[8] if len(parts) > 8 else ""
                path = path_part.split("\t")[0]
                code = xy[:2] if len(xy) >= 2 else "??"
                paths.append(f"{code} {path}")
                counts["modified"] += 1
            continue
        # Unmerged: "u XY ..."
        if line.startswith("u ") and len(line) > 2:
            parts = line.split(" ", 10)
            if len(parts) >= 10:
                path = parts[9] if len(parts) > 9 else ""
                paths.append(f"UU {path}")
                counts["modified"] += 1
    return branch, counts, paths


def _compact_git_status(
    command: str,
    stdout: str,
    stderr: str,
    exit_status: int,
) -> tuple[str, str, bool]:
    text = stdout if stdout.strip() else stderr
    if not text.strip():
        return stdout, stderr, False
    lines = text.splitlines()
    branch = ""
    counts: dict[str, int] = defaultdict(int)
    paths: list[str] = []
    for line in lines:
        if line.startswith("## "):
            branch = line[3:].strip()
            continue
        if _GIT_STATUS_SHORT_RE.match(line):
            code = line[:2]
            path = line[3:].strip()
            paths.append(f"{code} {path}")
            key = _git_status_code_label(code)
            counts[key] += 1
    if not paths and not branch:
        branch, counts, paths = _parse_git_status_long_format(lines)
    if not paths and not branch:
        return stdout, stderr, False
    header_bits = [f"git status (exit {exit_status})"]
    if branch:
        header_bits.append(f"branch {branch}")
    if counts:
        header_bits.append(
            "; ".join(f"{count} {label}" for label, count in sorted(counts.items()))
        )
    header = ": ".join(header_bits)
    max_paths = 40
    shown = paths[:max_paths]
    tail = f"\n... and {len(paths) - max_paths} more path(s)" if len(paths) > max_paths else ""
    body = header + "\n" + "\n".join(shown) + tail
    if stdout.strip():
        return body, stderr, True
    return stdout, body, True


def _git_status_code_label(code: str) -> str:
    labels = []
    mapping = {
        "M": "modified",
        "A": "added",
        "D": "deleted",
        "R": "renamed",
        "C": "copied",
        "U": "updated",
        "?": "untracked",
        "!": "ignored",
    }
    for char in code:
        if char.strip() and char in mapping:
            labels.append(mapping[char])
    return labels[0] if len(labels) == 1 else "changed"


def _compact_git_diff(
    command: str,
    stdout: str,
    stderr: str,
    exit_status: int,
) -> tuple[str, str, bool]:
    if _git_diff_wants_patch(command):
        return stdout, stderr, False
    text = stdout if stdout.strip() else stderr
    if not text.strip():
        return stdout, stderr, False
    lines = text.splitlines()
    if not any(_GIT_DIFF_GIT_RE.match(line) or _GIT_DIFF_STAT_FILE_RE.match(line) for line in lines):
        return stdout, stderr, False
    if any(_GIT_DIFF_HUNK_RE.match(line) for line in lines):
        stat_lines = [line for line in lines if _GIT_DIFF_STAT_FILE_RE.match(line)]
        summary = _git_diff_summary_line(command, stat_lines, exit_status, lines)
        if stat_lines:
            return summary + "\n" + "\n".join(stat_lines), "", True
        files = _git_diff_files_from_headers(lines)
        if files:
            body = summary + "\n" + "\n".join(f" {path}" for path in files)
            return body, "", True
        return stdout, stderr, False
    stat_lines = [line for line in lines if _GIT_DIFF_STAT_FILE_RE.match(line)]
    if stat_lines or lines[0].startswith(" "):
        summary = _git_diff_summary_line(command, stat_lines, exit_status, lines)
        return summary + "\n" + "\n".join(stat_lines or lines), "", True
    return stdout, stderr, False


def _git_diff_wants_patch(command: str) -> bool:
    lower = command.lower()
    patch_flags = (
        " -p",
        " --patch",
        " -u",
        " --unified",
        " --word-diff",
        " --word-diff-regex",
        " --color=always",
        " --no-color",
    )
    return any(flag in lower for flag in patch_flags) or re.search(
        r"(?:^|\s)-[a-zA-Z]*p[a-zA-Z]*(?:\s|$)", lower
    )


def _git_diff_files_from_headers(lines: Iterable[str]) -> list[str]:
    files: list[str] = []
    for line in lines:
        match = _GIT_DIFF_GIT_RE.match(line)
        if not match:
            continue
        parts = line.split()
        if len(parts) >= 4:
            files.append(parts[3][2:] if parts[3].startswith("b/") else parts[3])
    return files


def _git_diff_summary_line(
    command: str,
    stat_lines: list[str],
    exit_status: int,
    lines: list[str],
) -> str:
    file_count = len(stat_lines) or sum(1 for line in lines if _GIT_DIFF_GIT_RE.match(line))
    insertions = 0
    deletions = 0
    for line in stat_lines:
        plus = line.count("+") - line.count("+++")
        minus = line.count("-") - line.count("---")
        insertions += max(plus, 0)
        deletions += max(minus, 0)
    summary = f"git diff (exit {exit_status}): {file_count} file(s) changed"
    if insertions or deletions:
        summary += f", {insertions} insertion(s)(+), {deletions} deletion(s)(-)"
    summary += f" for: {command.strip()}"
    return summary


def _compact_grep(
    command: str,
    stdout: str,
    stderr: str,
    exit_status: int,
) -> tuple[str, str, bool]:
    text = stdout if stdout.strip() else stderr
    if not text.strip():
        return stdout, stderr, False
    lines = text.splitlines()
    by_file: dict[str, list[str]] = defaultdict(list)
    unparsed: list[str] = []
    for line in lines:
        if not line.strip():
            continue
        match = _GREP_RG_FILE_RE.match(line)
        if match:
            path, lineno, _content = match.groups()
            by_file[path].append(lineno or "?")
        else:
            unparsed.append(line)
    if not by_file:
        return stdout, stderr, False
    prefix = _common_path_prefix(list(by_file.keys()))
    total = sum(len(items) for items in by_file.values())
    header = (
        f"{_grep_tool_name(command)} (exit {exit_status}): "
        f"{total} match(es) in {len(by_file)} file(s)"
    )
    parts = [header]
    max_files = 30
    max_sample = 3
    for index, (path, nums) in enumerate(sorted(by_file.items(), key=lambda item: item[0])):
        if index >= max_files:
            parts.append(f"... and {len(by_file) - max_files} more file(s)")
            break
        display = path[len(prefix) :] if prefix and path.startswith(prefix) else path
        sample = ", ".join(nums[:max_sample])
        extra = ""
        if len(nums) > max_sample:
            extra = f", +{len(nums) - max_sample} more"
        parts.append(f"  {display}: {len(nums)} match(es) (lines {sample}{extra})")
    if unparsed:
        parts.append(f"({len(unparsed)} non-matching line(s) preserved below)")
        parts.extend(unparsed[:10])
    return "\n".join(parts), "", True


def _grep_tool_name(command: str) -> str:
    token = (command.strip().split() or ["grep"])[0]
    return token.rsplit("/", 1)[-1]


def _compact_find(
    command: str,
    stdout: str,
    stderr: str,
    exit_status: int,
) -> tuple[str, str, bool]:
    text = stdout if stdout.strip() else stderr
    if not text.strip():
        return stdout, stderr, False
    lines = [line for line in text.splitlines() if line.strip()]
    if len(lines) < 8:
        return stdout, stderr, False
    by_dir: dict[str, int] = defaultdict(int)
    for line in lines:
        path = line.rstrip("/")
        if "/" in path:
            directory = path.rsplit("/", 1)[0] + "/"
        else:
            directory = "./"
        by_dir[directory] += 1
    header = (
        f"find (exit {exit_status}): {len(lines)} path(s) in "
        f"{len(by_dir)} director(ies) for: {command.strip()}"
    )
    parts = [header]
    max_dirs = 25
    for index, (directory, count) in enumerate(sorted(by_dir.items(), key=lambda item: (-item[1], item[0]))):
        if index >= max_dirs:
            parts.append(f"... and {len(by_dir) - max_dirs} more director(ies)")
            break
        parts.append(f"  {directory}: {count} path(s)")
    return "\n".join(parts), "", True


def _compact_npm_test(
    command: str,
    stdout: str,
    stderr: str,
    exit_status: int,
) -> tuple[str, str, bool]:
    text = stdout if stdout.strip() else stderr
    if not text.strip():
        return stdout, stderr, False
    lines = text.splitlines()

    failed_lines = []
    passed_count = 0
    failed_count = 0

    for line in lines:
        if re.search(r"(\d+)\s+passed", line):
            try:
                passed_count = int(re.search(r"(\d+)\s+passed", line).group(1))
            except (AttributeError, ValueError):
                pass
        if re.search(r"(\d+)\s+failed", line):
            try:
                failed_count = int(re.search(r"(\d+)\s+failed", line).group(1))
            except (AttributeError, ValueError):
                pass
        if "FAIL" in line and (".test.js" in line or ".test.ts" in line):
            failed_lines.append(line)

    if exit_status != 0 and (failed_count > 0 or failed_lines):
        parts = [f"npm test failures (exit {exit_status}) for: {command.strip()}"]
        if passed_count > 0:
            parts.append(f"({passed_count} test(s) passing omitted)")
        parts.extend(failed_lines)
        output = "\n".join([p for p in parts if p.strip()])
        return output, "", True

    if exit_status == 0 and passed_count > 0:
        summary = f"npm test: {passed_count} test(s) passed (exit {exit_status})"
        return summary, "", True

    return stdout, stderr, False


def _compact_vitest(
    command: str,
    stdout: str,
    stderr: str,
    exit_status: int,
) -> tuple[str, str, bool]:
    text = stdout if stdout.strip() else stderr
    if not text.strip():
        return stdout, stderr, False
    lines = text.splitlines()

    failed_tests = []
    passed_count = 0
    failed_count = 0

    for line in lines:
        if re.search(r"passed", line.lower()):
            try:
                passed_count = int(re.search(r"(\d+)\s+passed", line).group(1))
            except (AttributeError, ValueError):
                pass
        elif re.search(r"failed", line.lower()):
            try:
                failed_count = int(re.search(r"(\d+)\s+failed", line).group(1))
            except (AttributeError, ValueError):
                pass
            failed_tests.append(line)

    if exit_status != 0 and (failed_count > 0 or failed_tests):
        parts = [f"vitest failures (exit {exit_status}) for: {command.strip()}"]
        if passed_count > 0:
            parts.append(f"({passed_count} test(s) passing omitted)")
        parts.extend(failed_tests)
        output = "\n".join([p for p in parts if p.strip()])
        return output, "", True

    if exit_status == 0 and passed_count > 0:
        summary = f"vitest: {passed_count} test(s) passed (exit {exit_status})"
        return summary, "", True

    return stdout, stderr, False


def _compact_tsc(
    command: str,
    stdout: str,
    stderr: str,
    exit_status: int,
) -> tuple[str, str, bool]:
    text = stdout if stdout.strip() else stderr
    if not text.strip():
        return stdout, stderr, False
    lines = text.splitlines()

    error_lines = []
    error_count = 0
    for line in lines:
        if "error TS" in line:
            error_lines.append(line)
            error_count += 1

    if exit_status != 0 and error_lines:
        parts = [f"tsc errors (exit {exit_status}) for: {command.strip()}"]
        parts.extend(error_lines[:20])
        if len(error_lines) > 20:
            parts.append(f"... and {len(error_lines) - 20} more error(s)")
        output = "\n".join(parts)
        return output, "", True

    if exit_status == 0 and not error_lines:
        summary = f"tsc: compilation successful (exit {exit_status})"
        return summary, "", True

    return stdout, stderr, False


def _compact_eslint(
    command: str,
    stdout: str,
    stderr: str,
    exit_status: int,
) -> tuple[str, str, bool]:
    text = stdout if stdout.strip() else stderr
    if not text.strip():
        return stdout, stderr, False
    lines = text.splitlines()

    error_lines = []
    warning_lines = []
    error_count = 0
    warning_count = 0

    for line in lines:
        if "error" in line.lower() and not line.strip().startswith("warning"):
            error_lines.append(line)
            if re.search(r"(\d+)\s+error", line):
                try:
                    error_count = int(re.search(r"(\d+)\s+error", line).group(1))
                except (AttributeError, ValueError):
                    pass
        elif "warning" in line.lower():
            warning_lines.append(line)
            if re.search(r"(\d+)\s+warning", line):
                try:
                    warning_count = int(re.search(r"(\d+)\s+warning", line).group(1))
                except (AttributeError, ValueError):
                    pass

    if exit_status != 0 and (error_lines or error_count > 0):
        parts = [f"eslint errors (exit {exit_status}) for: {command.strip()}"]
        if warning_count > 0:
            parts.append(f"({warning_count} warning(s) omitted)")
        parts.extend([l for l in error_lines if l.strip()])
        output = "\n".join(parts)
        return output, "", True

    if exit_status == 0 and not error_lines:
        summary = f"eslint: no errors (exit {exit_status})"
        if warning_count > 0:
            summary = f"eslint: no errors, {warning_count} warning(s) (exit {exit_status})"
        return summary, "", True

    return stdout, stderr, False


def _compact_pytest(
    command: str,
    stdout: str,
    stderr: str,
    exit_status: int,
) -> tuple[str, str, bool]:
    text = stdout if stdout.strip() else stderr
    if not text.strip():
        return stdout, stderr, False
    lines = text.splitlines()

    failed_tests = []
    passed_count = 0
    failed_count = 0
    error_count = 0

    for line in lines:
        if _PYTEST_PASSED_RE.search(line):
            try:
                passed_count = int(_PYTEST_PASSED_RE.search(line).group(1))
            except (AttributeError, ValueError):
                pass
        elif _PYTEST_FAILED_RE.search(line):
            try:
                failed_count = int(_PYTEST_FAILED_RE.search(line).group(1))
            except (AttributeError, ValueError):
                pass
        elif _PYTEST_ERROR_RE.search(line):
            try:
                error_count = int(_PYTEST_ERROR_RE.search(line).group(1))
            except (AttributeError, ValueError):
                pass
        elif _PYTEST_TEST_RE.search(line) and ("FAILED" in line or "ERROR" in line):
            failed_tests.append(line)

    if exit_status != 0 and (failed_count > 0 or error_count > 0 or failed_tests):
        parts = [f"pytest failures (exit {exit_status}) for: {command.strip()}"]
        if passed_count > 0:
            parts.append(f"({passed_count} test(s) passing omitted)")
        parts.extend(failed_tests[:30])
        if len(failed_tests) > 30:
            parts.append(f"... and {len(failed_tests) - 30} more failed test(s)")
        output = "\n".join([p for p in parts if p.strip()])
        return output, "", True

    if exit_status == 0 and passed_count > 0:
        summary = f"pytest: {passed_count} test(s) passed (exit {exit_status})"
        return summary, "", True

    return stdout, stderr, False


def _compact_cargo_test(
    command: str,
    stdout: str,
    stderr: str,
    exit_status: int,
) -> tuple[str, str, bool]:
    text = stdout if stdout.strip() else stderr
    if not text.strip():
        return stdout, stderr, False
    lines = text.splitlines()

    failed_tests = []
    test_lines = []
    passed_count = 0
    failed_count = 0

    for line in lines:
        if _CARGO_TEST_PASS_RE.search(line):
            test_lines.append(line)
            passed_count += 1
        elif _CARGO_TEST_FAIL_RE.search(line):
            failed_tests.append(line)
            failed_count += 1

    if exit_status != 0 and (failed_count > 0 or failed_tests):
        parts = [f"cargo test failures (exit {exit_status}) for: {command.strip()}"]
        if passed_count > 0:
            parts.append(f"({passed_count} test(s) passing omitted)")
        parts.extend(failed_tests)
        output = "\n".join([p for p in parts if p.strip()])
        return output, "", True

    if exit_status == 0 and passed_count > 0:
        summary = f"cargo test: {passed_count} test(s) passed (exit {exit_status})"
        return summary, "", True

    return stdout, stderr, False


def _compact_go_test(
    command: str,
    stdout: str,
    stderr: str,
    exit_status: int,
) -> tuple[str, str, bool]:
    text = stdout if stdout.strip() else stderr
    if not text.strip():
        return stdout, stderr, False
    lines = text.splitlines()

    test_lines = []
    passed_count = 0
    failed_count = 0

    for line in lines:
        if line.startswith("ok"):
            test_lines.append(line)
            passed_count += 1
        elif line.startswith("FAIL"):
            test_lines.append(line)
            failed_count += 1

    if exit_status != 0 and (failed_count > 0 or any("FAIL" in l for l in lines)):
        parts = [f"go test failures (exit {exit_status}) for: {command.strip()}"]
        if passed_count > 0:
            parts.append(f"({passed_count} test(s) passing omitted)")
        parts.extend([l for l in test_lines if "FAIL" in l])
        output = "\n".join([p for p in parts if p.strip()])
        return output, "", True

    if exit_status == 0 and passed_count > 0:
        summary = f"go test: {passed_count} test(s) passed (exit {exit_status})"
        return summary, "", True

    return stdout, stderr, False


def _compact_ls(
    command: str,
    stdout: str,
    stderr: str,
    exit_status: int,
) -> tuple[str, str, bool]:
    text = stdout if stdout.strip() else stderr
    if not text.strip():
        return stdout, stderr, False
    lines = [line for line in text.splitlines() if line.strip()]
    if len(lines) < 15:
        return stdout, stderr, False

    file_count = len(lines)
    by_type: dict[str, int] = {"file": 0, "dir": 0, "link": 0, "other": 0}
    total_size = 0

    for line in lines:
        if _LS_LONG_FORMAT_RE.match(line):
            parts = line.split()
            if len(parts) >= 5:
                try:
                    size = int(parts[4])
                    total_size += size
                except (IndexError, ValueError):
                    pass
            if line.startswith("d"):
                by_type["dir"] += 1
            elif line.startswith("l"):
                by_type["link"] += 1
            elif line.startswith("-"):
                by_type["file"] += 1
            else:
                by_type["other"] += 1
        else:
            by_type["file"] += 1

    summary_parts = [f"ls (exit {exit_status}): {file_count} item(s)"]
    type_parts = []
    if by_type["file"] > 0:
        type_parts.append(f"{by_type['file']} file(s)")
    if by_type["dir"] > 0:
        type_parts.append(f"{by_type['dir']} dir(s)")
    if by_type["link"] > 0:
        type_parts.append(f"{by_type['link']} link(s)")
    if type_parts:
        summary_parts.append(", ".join(type_parts))
    if total_size > 0:
        size_mb = total_size / (1024 * 1024)
        summary_parts.append(f"{size_mb:.1f}MB")

    summary = " - ".join(summary_parts)
    max_shown = 30
    shown_lines = lines[:max_shown]
    tail = f"\n... and {len(lines) - max_shown} more item(s)" if len(lines) > max_shown else ""
    output = summary + "\n" + "\n".join(shown_lines) + tail
    if stdout.strip():
        return output, stderr, True
    return stdout, output, True


def _compact_tree(
    command: str,
    stdout: str,
    stderr: str,
    exit_status: int,
) -> tuple[str, str, bool]:
    text = stdout if stdout.strip() else stderr
    if not text.strip():
        return stdout, stderr, False
    lines = [line for line in text.splitlines() if line.strip()]
    if len(lines) < 20:
        return stdout, stderr, False

    total_items = len(lines)
    depth_counts: dict[int, int] = defaultdict(int)
    file_count = 0
    dir_count = 0

    for line in lines:
        leading = len(line) - len(line.lstrip())
        depth = leading // 2
        depth_counts[depth] += 1

        if line.rstrip().endswith("/"):
            dir_count += 1
        else:
            file_count += 1

    max_depth = max(depth_counts.keys()) if depth_counts else 0
    summary = (
        f"tree (exit {exit_status}): {total_items} item(s), "
        f"max depth {max_depth}, "
        f"{dir_count} dir(s), {file_count} file(s)"
    )

    max_shown = 50
    shown_lines = lines[:max_shown]
    tail = f"\n... and {len(lines) - max_shown} more item(s)" if len(lines) > max_shown else ""
    output = summary + "\n" + "\n".join(shown_lines) + tail
    if stdout.strip():
        return output, stderr, True
    return stdout, output, True


def _compact_docker_ps(
    command: str,
    stdout: str,
    stderr: str,
    exit_status: int,
) -> tuple[str, str, bool]:
    text = stdout if stdout.strip() else stderr
    if not text.strip():
        return stdout, stderr, False
    lines = [line for line in text.splitlines() if line.strip()]
    if len(lines) < 5:
        return stdout, stderr, False

    container_count = len(lines) - 1
    running_count = 0
    status_counts: dict[str, int] = defaultdict(int)

    for i, line in enumerate(lines):
        if i == 0:
            continue
        parts = line.split()
        if len(parts) > 4:
            status = parts[4].lower()
            status_counts[status] += 1
            if "up" in status:
                running_count += 1

    summary_parts = [f"docker ps (exit {exit_status}): {container_count} container(s)"]
    if running_count > 0:
        summary_parts.append(f"{running_count} running")
    for status, count in sorted(status_counts.items()):
        summary_parts.append(f"{count} {status}")

    summary = ", ".join(summary_parts)
    max_shown = 20
    header = lines[0] if lines else ""
    shown_lines = [header] + lines[1:max_shown]
    tail = f"\n... and {len(lines) - max_shown} more" if len(lines) > max_shown else ""
    output = summary + "\n" + "\n".join(shown_lines) + tail
    if stdout.strip():
        return output, stderr, True
    return stdout, output, True


def _compact_docker_logs(
    command: str,
    stdout: str,
    stderr: str,
    exit_status: int,
) -> tuple[str, str, bool]:
    text = stdout if stdout.strip() else stderr
    if not text.strip():
        return stdout, stderr, False
    lines = [line for line in text.splitlines() if line.strip()]
    if len(lines) < 20:
        return stdout, stderr, False

    total_lines = len(lines)
    repeated_lines: dict[str, int] = defaultdict(int)
    error_count = 0
    warning_count = 0

    for line in lines:
        repeated_lines[line] += 1
        if "error" in line.lower():
            error_count += 1
        elif "warn" in line.lower():
            warning_count += 1

    unique_count = len(repeated_lines)
    most_common = sorted(repeated_lines.items(), key=lambda x: -x[1])[:3]

    summary_parts = [f"docker logs (exit {exit_status}): {total_lines} line(s)"]
    if unique_count < total_lines:
        summary_parts.append(f"{unique_count} unique")
    if error_count > 0:
        summary_parts.append(f"{error_count} error(s)")
    if warning_count > 0:
        summary_parts.append(f"{warning_count} warning(s)")

    summary = ", ".join(summary_parts)
    parts = [summary]

    if most_common:
        parts.append("Most repeated:")
        for line, count in most_common:
            if count > 1:
                parts.append(f"  ({count}x) {line[:100]}")
            else:
                parts.append(f"  {line[:100]}")

    max_shown = 30
    shown_lines = lines[:max_shown]
    parts.extend(shown_lines)

    if len(lines) > max_shown:
        parts.append(f"... and {total_lines - max_shown} more line(s)")

    output = "\n".join(parts)
    if stdout.strip():
        return output, stderr, True
    return stdout, output, True


def _compact_kubectl(
    command: str,
    stdout: str,
    stderr: str,
    exit_status: int,
) -> tuple[str, str, bool]:
    text = stdout if stdout.strip() else stderr
    if not text.strip():
        return stdout, stderr, False
    lines = [line for line in text.splitlines() if line.strip()]
    if len(lines) < 10:
        return stdout, stderr, False

    resource_count = len(lines) - 1
    status_counts: dict[str, int] = defaultdict(int)
    namespaces: set[str] = set()

    for i, line in enumerate(lines):
        if i == 0:
            continue
        parts = line.split()
        if len(parts) > 2:
            status = parts[-1].lower() if parts[-1] else "unknown"
            status_counts[status] += 1
            if len(parts) > 1:
                namespace = parts[1] if "namespace" not in line.lower() else "default"
                namespaces.add(namespace)

    summary_parts = [f"kubectl (exit {exit_status}): {resource_count} resource(s)"]
    if namespaces:
        summary_parts.append(f"{len(namespaces)} namespace(s)")
    for status, count in sorted(status_counts.items()):
        summary_parts.append(f"{count} {status}")

    summary = ", ".join(summary_parts)
    max_shown = 25
    header = lines[0] if lines else ""
    shown_lines = [header] + lines[1:max_shown]
    tail = f"\n... and {len(lines) - max_shown} more" if len(lines) > max_shown else ""
    output = summary + "\n" + "\n".join(shown_lines) + tail
    if stdout.strip():
        return output, stderr, True
    return stdout, output, True


def _compact_gh_pr_view(
    command: str,
    stdout: str,
    stderr: str,
    exit_status: int,
) -> tuple[str, str, bool]:
    text = stdout if stdout.strip() else stderr
    if not text.strip():
        return stdout, stderr, False
    lines = text.splitlines()

    pr_number = None
    title = None
    state = None
    author = None
    url = None

    for line in lines:
        if line.startswith("title:"):
            title = line[6:].strip()
        elif line.startswith("state:"):
            state = line[6:].strip()
        elif line.startswith("author:"):
            author = line[7:].strip()
        elif line.startswith("url:"):
            url = line[4:].strip()
        elif "PR" in line and line[0].isdigit():
            try:
                pr_number = int(line.split()[0])
            except (ValueError, IndexError):
                pass

    if not (title or state or author):
        return stdout, stderr, False

    summary_parts = [f"gh pr view (exit {exit_status})"]
    if pr_number:
        summary_parts.append(f"PR#{pr_number}")
    if title:
        summary_parts.append(f'"{title}"')
    if state:
        summary_parts.append(f"[{state}]")
    if author:
        summary_parts.append(f"by {author}")
    if url:
        summary_parts.append(f"{url}")

    summary = " ".join(summary_parts)
    max_lines = 15
    shown_lines = lines[:max_lines]
    tail = f"\n... and {len(lines) - max_lines} more line(s)" if len(lines) > max_lines else ""
    output = summary + "\n" + "\n".join(shown_lines) + tail
    if stdout.strip():
        return output, stderr, True
    return stdout, output, True


def _compact_gh_pr_list(
    command: str,
    stdout: str,
    stderr: str,
    exit_status: int,
) -> tuple[str, str, bool]:
    text = stdout if stdout.strip() else stderr
    if not text.strip():
        return stdout, stderr, False
    lines = [line for line in text.splitlines() if line.strip()]
    if len(lines) < 5:
        return stdout, stderr, False

    pr_count = len(lines) - 1
    state_counts: dict[str, int] = defaultdict(int)
    draft_count = 0

    for i, line in enumerate(lines):
        if i == 0:
            continue
        if "DRAFT" in line.upper():
            draft_count += 1
        if "OPEN" in line.upper():
            state_counts["open"] += 1
        elif "CLOSED" in line.upper():
            state_counts["closed"] += 1
        elif "MERGED" in line.upper():
            state_counts["merged"] += 1

    summary_parts = [f"gh pr list (exit {exit_status}): {pr_count} PR(s)"]
    if draft_count > 0:
        summary_parts.append(f"{draft_count} draft(s)")
    for state, count in sorted(state_counts.items()):
        summary_parts.append(f"{count} {state}")

    summary = ", ".join(summary_parts)
    max_shown = 20
    header = lines[0] if lines else ""
    shown_lines = [header] + lines[1:max_shown]
    tail = f"\n... and {len(lines) - max_shown} more" if len(lines) > max_shown else ""
    output = summary + "\n" + "\n".join(shown_lines) + tail
    if stdout.strip():
        return output, stderr, True
    return stdout, output, True


def _classifier_never(_command: str) -> bool:
    return False


def _compact_generic_large(
    command: str,
    stdout: str,
    stderr: str,
    exit_status: int,
) -> tuple[str, str, bool]:
    text = stdout if stdout.strip() else stderr
    if not text.strip():
        return stdout, stderr, False
    if len(text.encode("utf-8")) <= _generic_fallback_threshold_bytes():
        return stdout, stderr, False
    body = _format_generic_large_output(command, text, exit_status)
    if body is None:
        return stdout, stderr, False
    if stdout.strip():
        return body, stderr, True
    return stdout, body, True


def _pattern_class_min_run(class_id: str) -> int:
    for entry in _GENERIC_PATTERN_CLASSES:
        if entry.class_id == class_id:
            return entry.min_run
    return 3


def _pattern_class_label(class_id: str) -> str:
    for entry in _GENERIC_PATTERN_CLASSES:
        if entry.class_id == class_id:
            return entry.label
    return class_id


def _classify_generic_pattern_line(line: str) -> str | None:
    for entry in _GENERIC_PATTERN_CLASSES:
        if entry.pattern.search(line):
            return entry.class_id
    return None


def _should_preserve_generic_line(line: str) -> bool:
    return bool(
        _GENERIC_PRESERVE_RE.search(line)
        or _GENERIC_SUMMARY_RE.search(line)
        or _GENERIC_FALLBACK_ERROR_RE.search(line)
    )


def _collapse_generic_pattern_runs(
    lines: list[str],
) -> tuple[list[str], dict[str, int]]:
    """Collapse consecutive runs of shared cross-ecosystem pattern classes."""
    result: list[str] = []
    omitted_by_class: dict[str, int] = defaultdict(int)
    index = 0
    while index < len(lines):
        line = lines[index]
        if _should_preserve_generic_line(line):
            result.append(line)
            index += 1
            continue

        class_id = _classify_generic_pattern_line(line)
        if class_id is None:
            result.append(line)
            index += 1
            continue

        run_start = index
        while index < len(lines):
            current = lines[index]
            if _should_preserve_generic_line(current):
                break
            current_class = _classify_generic_pattern_line(current)
            if current_class != class_id:
                break
            index += 1

        run_len = index - run_start
        min_run = _pattern_class_min_run(class_id)
        label = _pattern_class_label(class_id)
        if run_len < min_run:
            result.extend(lines[run_start:index])
            continue

        if class_id == "stack_frame":
            keep_frames = min(2, run_len)
            result.extend(lines[run_start : run_start + keep_frames])
            omitted = run_len - keep_frames
            if omitted > 0:
                result.append(f"... ({omitted} {label} line(s) omitted) ...")
                omitted_by_class[class_id] += omitted
            continue

        result.append(f"... ({run_len} {label} line(s) omitted) ...")
        omitted_by_class[class_id] += run_len

    return result, dict(omitted_by_class)


def _generic_summary_prefix(
    command: str,
    text: str,
    exit_status: int,
    original_line_count: int,
    omitted_stats: dict[str, int],
) -> str:
    label = command.strip() or "(unknown command)"
    summary = (
        f"output (exit {exit_status}): {original_line_count} line(s), "
        f"{len(text.encode('utf-8'))} byte(s) for: {label}"
    )
    if omitted_stats:
        omission_parts = [
            f"{count} {_pattern_class_label(class_id)}"
            for class_id, count in sorted(omitted_stats.items())
        ]
        summary += f" (collapsed: {', '.join(omission_parts)})"
    return summary


def _format_generic_large_output(
    command: str,
    text: str,
    exit_status: int,
) -> str | None:
    lines = text.splitlines()
    max_kept = _GENERIC_LARGE_HEAD_LINES + _GENERIC_LARGE_TAIL_LINES
    if len(lines) <= max_kept:
        return None

    collapsed_lines, omitted_stats = _collapse_generic_pattern_runs(lines)
    working_lines = collapsed_lines

    if len(working_lines) <= max_kept and not omitted_stats:
        return None

    if len(working_lines) <= max_kept:
        summary = _generic_summary_prefix(
            command, text, exit_status, len(lines), omitted_stats
        )
        return summary + "\n" + "\n".join(working_lines)

    head = working_lines[:_GENERIC_LARGE_HEAD_LINES]
    tail = working_lines[len(working_lines) - _GENERIC_LARGE_TAIL_LINES :]
    middle = working_lines[
        _GENERIC_LARGE_HEAD_LINES : len(working_lines) - _GENERIC_LARGE_TAIL_LINES
    ]
    important_lines = [line for line in middle if _should_preserve_generic_line(line)]
    extra_important_count = max(
        0, len(important_lines) - _GENERIC_FALLBACK_MAX_ERROR_LINES
    )
    important_lines = important_lines[:_GENERIC_FALLBACK_MAX_ERROR_LINES]

    summary = _generic_summary_prefix(
        command, text, exit_status, len(lines), omitted_stats
    )
    body_lines = [summary]
    body_lines.extend(head)
    if middle:
        body_lines.append(f"... ({len(middle)} line(s) omitted) ...")
    if important_lines:
        body_lines.append("important line(s) extracted from omitted region:")
        body_lines.extend(important_lines)
        if extra_important_count:
            body_lines.append(
                f"... ({extra_important_count} more matching line(s) omitted) ..."
            )
    body_lines.extend(tail)
    return "\n".join(body_lines)


def _common_path_prefix(paths: list[str]) -> str:
    if not paths:
        return ""
    parts_list = [path.split("/") for path in paths]
    common: list[str] = []
    for segment_group in zip(*parts_list):
        if len(set(segment_group)) == 1:
            common.append(segment_group[0])
        else:
            break
    if not common:
        return ""
    prefix = "/".join(common)
    if "/" in prefix and not prefix.endswith("/"):
        prefix += "/"
    return prefix


def _join_streams(stdout: str, stderr: str) -> str:
    if stdout and stderr:
        return stdout.rstrip("\n") + "\n" + stderr
    return stdout or stderr


def _compactor_dsl_rules_module() -> Any:
    module_name = "compactor_dsl_rules"
    cached = sys.modules.get(module_name)
    if cached is not None:
        return cached
    module_path = Path(__file__).with_name("compactor-dsl-rules.py")
    spec = importlib.util.spec_from_file_location(module_name, module_path)
    if spec is None or spec.loader is None:
        raise ImportError(f"Cannot load compactor DSL rules from {module_path}")
    module = importlib.util.module_from_spec(spec)
    sys.modules[module_name] = module
    spec.loader.exec_module(module)
    return module


def _dsl_compactor_for_rule(rule: Any) -> CompactorFn:
    dsl = _compactor_dsl_rules_module()

    def compactor(
        command: str, stdout: str, stderr: str, exit_status: int
    ) -> tuple[str, str, bool]:
        text = stdout if stdout.strip() else stderr
        if not text.strip():
            return stdout, stderr, False
        filtered = dsl.apply_line_filter_rule(rule, text)
        if filtered == text:
            return stdout, stderr, False
        if stdout.strip():
            return filtered, stderr, True
        return stdout, filtered, True

    return compactor


def _load_builtin_dsl_families() -> list[CompactorFamily]:
    rules_path = Path(__file__).parent.parent / "bash-lib" / "compactor-dsl-builtin-rules.json"
    if not rules_path.is_file():
        return []
    dsl = _compactor_dsl_rules_module()
    rules, errors = dsl.load_dsl_rules(rules_path.read_text(encoding="utf-8"))
    if errors:
        return []
    families: list[CompactorFamily] = []
    for rule in rules:
        families.append(
            CompactorFamily(
                family_id=f"dsl:{rule.rule_id}",
                classifier=dsl.compile_rule_matcher(rule.command_matcher),
                compactor=_dsl_compactor_for_rule(rule),
                safety_metadata={"safe": True, "phase": "dsl"},
            )
        )
    return families


def _safety_gate_passes(
    entry: CompactorFamily | None, original_combined: str, candidate_combined: str
) -> bool:
    if entry is None:
        return False
    if not entry.safety_metadata.get("safe", True):
        return False
    if not candidate_combined:
        return False
    if _has_binary(candidate_combined):
        return False
    original_bytes = len(original_combined.encode("utf-8"))
    candidate_bytes = len(candidate_combined.encode("utf-8"))
    # Allow compaction for small outputs where semantic grouping is still valuable
    # even if the header overhead makes candidate_bytes equal or slightly larger.
    if original_bytes <= 320:
        return True
    return candidate_bytes < original_bytes


_CORE_FAMILY_REGISTRY: list[CompactorFamily] = [
    CompactorFamily(
        family_id=FAMILY_BATS,
        classifier=classifier_for_family(FAMILY_BATS),
        compactor=_compact_bats,
        safety_metadata={"safe": True, "phase": "phase2"},
    ),
    CompactorFamily(
        family_id=FAMILY_GIT_STATUS,
        classifier=CLASSIFIER_GIT_STATUS,
        compactor=_compact_git_status,
        safety_metadata={"safe": True, "phase": "phase2"},
    ),
    CompactorFamily(
        family_id=FAMILY_GIT_DIFF,
        classifier=classifier_for_family(FAMILY_GIT_DIFF),
        compactor=_compact_git_diff,
        safety_metadata={"safe": True, "phase": "phase2"},
    ),
    CompactorFamily(
        family_id=FAMILY_GIT_SHOW,
        classifier=classifier_for_family(FAMILY_GIT_SHOW),
        compactor=_compact_git_diff,
        safety_metadata={"safe": True, "phase": "phase2"},
    ),
    CompactorFamily(
        family_id=FAMILY_GIT_LOG,
        classifier=classifier_for_family(FAMILY_GIT_LOG),
        compactor=_compact_generic_large,
        safety_metadata={"safe": True, "phase": "phase2"},
    ),
    CompactorFamily(
        family_id=FAMILY_GREP,
        classifier=classifier_for_family(FAMILY_GREP),
        compactor=_compact_grep,
        safety_metadata={"safe": True, "phase": "phase2"},
    ),
    CompactorFamily(
        family_id=FAMILY_FIND,
        classifier=classifier_for_family(FAMILY_FIND),
        compactor=_compact_find,
        safety_metadata={"safe": True, "phase": "phase2"},
    ),
    CompactorFamily(
        family_id=FAMILY_NPM_TEST,
        classifier=classifier_for_family(FAMILY_NPM_TEST),
        compactor=_compact_npm_test,
        safety_metadata={"safe": True, "phase": "phase3"},
    ),
    CompactorFamily(
        family_id=FAMILY_VITEST,
        classifier=classifier_for_family(FAMILY_VITEST),
        compactor=_compact_vitest,
        safety_metadata={"safe": True, "phase": "phase3"},
    ),
    CompactorFamily(
        family_id=FAMILY_TSC,
        classifier=CLASSIFIER_TSC,
        compactor=_compact_tsc,
        safety_metadata={"safe": True, "phase": "phase3"},
    ),
    CompactorFamily(
        family_id=FAMILY_ESLINT,
        classifier=classifier_for_family(FAMILY_ESLINT),
        compactor=_compact_eslint,
        safety_metadata={"safe": True, "phase": "phase3"},
    ),
    CompactorFamily(
        family_id=FAMILY_PYTEST,
        classifier=CLASSIFIER_PYTEST,
        compactor=_compact_pytest,
        safety_metadata={"safe": True, "phase": "phase3"},
    ),
    CompactorFamily(
        family_id=FAMILY_SHELLCHECK,
        classifier=classifier_for_family(FAMILY_SHELLCHECK),
        compactor=_compact_generic_large,
        safety_metadata={"safe": True, "phase": "phase3"},
    ),
    CompactorFamily(
        family_id=FAMILY_CARGO_TEST,
        classifier=_classifier_cargo_test,
        compactor=_compact_cargo_test,
        safety_metadata={"safe": True, "phase": "phase3"},
    ),
    CompactorFamily(
        family_id=FAMILY_GO_TEST,
        classifier=_classifier_go_test,
        compactor=_compact_go_test,
        safety_metadata={"safe": True, "phase": "phase3"},
    ),
    CompactorFamily(
        family_id=FAMILY_LS,
        classifier=classifier_for_family(FAMILY_LS),
        compactor=_compact_ls,
        safety_metadata={"safe": True, "phase": "phase4"},
    ),
    CompactorFamily(
        family_id=FAMILY_TREE,
        classifier=classifier_for_family(FAMILY_TREE),
        compactor=_compact_tree,
        safety_metadata={"safe": True, "phase": "phase4"},
    ),
    CompactorFamily(
        family_id=FAMILY_DOCKER_PS,
        classifier=classifier_for_family(FAMILY_DOCKER_PS),
        compactor=_compact_docker_ps,
        safety_metadata={"safe": True, "phase": "phase4"},
    ),
    CompactorFamily(
        family_id=FAMILY_DOCKER_LOGS,
        classifier=classifier_for_family(FAMILY_DOCKER_LOGS),
        compactor=_compact_docker_logs,
        safety_metadata={"safe": True, "phase": "phase4"},
    ),
    CompactorFamily(
        family_id=FAMILY_KUBECTL,
        classifier=classifier_for_family(FAMILY_KUBECTL),
        compactor=_compact_kubectl,
        safety_metadata={"safe": True, "phase": "phase4"},
    ),
    CompactorFamily(
        family_id=FAMILY_GH_PR_VIEW,
        classifier=classifier_for_family(FAMILY_GH_PR_VIEW),
        compactor=_compact_gh_pr_view,
        safety_metadata={"safe": True, "phase": "phase4"},
    ),
    CompactorFamily(
        family_id=FAMILY_GH_PR_LIST,
        classifier=classifier_for_family(FAMILY_GH_PR_LIST),
        compactor=_compact_gh_pr_list,
        safety_metadata={"safe": True, "phase": "phase4"},
    ),
    CompactorFamily(
        family_id=FAMILY_GENERIC_LARGE,
        classifier=_classifier_never,
        compactor=_compact_generic_large,
        safety_metadata={"safe": True, "phase": "shape_fallback"},
    ),
    CompactorFamily(
        family_id=FAMILY_FAILURE_AWARE,
        classifier=_classifier_never,
        compactor=_compact_generic_large,
        safety_metadata={"safe": True, "phase": "failure_fallback"},
    ),
]

_FAMILY_REGISTRY: list[CompactorFamily] = _load_builtin_dsl_families() + _CORE_FAMILY_REGISTRY

_FAMILY_MAP: dict[str, CompactorFamily] = {
    entry.family_id: entry for entry in _FAMILY_REGISTRY
}


def _compact_cli(payload: dict[str, object]) -> int:
    command = str(payload.get("command") or "")
    stdout = str(payload.get("stdout") or "")
    stderr = str(payload.get("stderr") or "")
    try:
        exit_status = int(payload.get("exit_status") or 0)
    except (TypeError, ValueError):
        exit_status = 0
    result = compact_shell_output(command, stdout, stderr, exit_status)
    sys.stdout.write(json.dumps(result.to_dict(), ensure_ascii=False))
    sys.stdout.write("\n")
    return 0


def main(argv: list[str] | None = None) -> int:
    args = argv if argv is not None else sys.argv[1:]
    if args != ["compact"]:
        print("Usage: shell-output-compact.py compact  (read JSON object on stdin)", file=sys.stderr)
        return 2
    try:
        payload = json.load(sys.stdin)
    except json.JSONDecodeError as exc:
        print(f"Invalid JSON input: {exc}", file=sys.stderr)
        return 2
    if not isinstance(payload, dict):
        print("Expected a JSON object on stdin", file=sys.stderr)
        return 2
    return _compact_cli(payload)


if __name__ == "__main__":
    raise SystemExit(main())
