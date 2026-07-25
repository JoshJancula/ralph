#!/usr/bin/env python3
"""Safe local reduction of stored MCP proxy results (stdlib only)."""

from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import subprocess
import sys
from typing import Any

DEFAULT_TIMEOUT_SEC = 5
DEFAULT_MAX_OUTPUT_BYTES = 16384
DEFAULT_MAX_OUTPUT_LINES = 500
DEFAULT_MAX_INPUT_BYTES = 52_428_800

JQ_DENY_RE = re.compile(
    r"(?:\b(?:system|exec|input|inputs|debug|import|modulemeta)\b|@(?:include|file)|\bENV\b)",
    re.IGNORECASE,
)

AWK_DENY_RES = [
    re.compile(r"\bsystem\s*\(", re.IGNORECASE),
    re.compile(r"\bgetline\b", re.IGNORECASE),
    re.compile(r">>"),
    re.compile(r"(?<![=-])>(?![=-])"),
    re.compile(r"<"),
    re.compile(r"\|"),
    re.compile(r"\bFILENAME\b"),
    re.compile(r"\bARGV\b"),
    re.compile(r"/dev/"),
    re.compile(r"@include", re.IGNORECASE),
    re.compile(r"\bexec\b", re.IGNORECASE),
    re.compile(r"\bpopen\b", re.IGNORECASE),
    re.compile(r"\bcmd\b", re.IGNORECASE),
]


class ReduceError(Exception):
    pass


def result_reduce_enabled(*, explicit: str | None = None, ralph_mode: str | None = None) -> bool:
    value = explicit if explicit is not None else (os.environ.get("RALPH_RESULT_REDUCE") or "").strip()
    if value:
        normalized = value.lower()
        if normalized in {"1", "true", "yes", "on"}:
            return True
        if normalized in {"0", "false", "no", "off"}:
            return False
        raise ValueError(f"RALPH_RESULT_REDUCE: invalid value '{value}' (use 0 or 1)")
    mode = (ralph_mode if ralph_mode is not None else os.environ.get("RALPH_MODE", "no")).lower()
    return mode in {"ralph", "hybrid"}


def _positive_int(value: Any, default: int) -> int:
    try:
        parsed = int(value)
    except (TypeError, ValueError):
        return default
    return parsed if parsed > 0 else default


def limits_from_request(request: dict[str, Any]) -> dict[str, int]:
    raw = request.get("limits") or {}
    env_input = os.environ.get("RALPH_RESULT_REDUCE_MAX_INPUT_BYTES", "").strip()
    default_input = int(env_input) if env_input.isdigit() and int(env_input) > 0 else DEFAULT_MAX_INPUT_BYTES
    return {
        "timeoutSeconds": _positive_int(raw.get("timeoutSeconds"), DEFAULT_TIMEOUT_SEC),
        "maxOutputBytes": _positive_int(raw.get("maxOutputBytes"), DEFAULT_MAX_OUTPUT_BYTES),
        "maxOutputLines": _positive_int(raw.get("maxOutputLines"), DEFAULT_MAX_OUTPUT_LINES),
        "maxInputBytes": _positive_int(raw.get("maxInputBytes"), default_input),
    }


def validate_input_path(path: str) -> None:
    if not path or not os.path.isfile(path):
        raise ReduceError("stored result input file not found")
    real = os.path.realpath(path)
    if ".." in path.split(os.sep):
        raise ReduceError("input path traversal blocked")
    if not os.path.isfile(real):
        raise ReduceError("stored result input file not found")


def read_bounded_text(path: str, max_bytes: int) -> str:
    validate_input_path(path)
    size = os.path.getsize(path)
    if size > max_bytes:
        raise ReduceError(f"stored result exceeds max input bytes ({size} > {max_bytes})")
    with open(path, "rb") as fh:
        data = fh.read(max_bytes + 1)
    if len(data) > max_bytes:
        raise ReduceError(f"stored result exceeds max input bytes ({len(data)} > {max_bytes})")
    return data.decode("utf-8", errors="replace")


def validate_jq_expression(expression: str) -> None:
    if not expression or not expression.strip():
        raise ReduceError("jq expression is required")
    if JQ_DENY_RE.search(expression):
        raise ReduceError("jq expression contains disallowed constructs")


def validate_awk_program(expression: str) -> None:
    if not expression or not expression.strip():
        raise ReduceError("awk program is required")
    for pattern in AWK_DENY_RES:
        if pattern.search(expression):
            raise ReduceError("awk program contains disallowed constructs")


def validate_grep_pattern(expression: str) -> None:
    if not expression:
        raise ReduceError("grep pattern is required")
    if "\n" in expression:
        raise ReduceError("grep multiline patterns are not supported")


def build_grep_argv(expression: str, grep_opts: dict[str, Any]) -> list[str]:
    validate_grep_pattern(expression)
    argv = ["grep"]
    if grep_opts.get("ignoreCase"):
        argv.append("-i")
    if grep_opts.get("invertMatch"):
        argv.append("-v")
    if grep_opts.get("lineNumber"):
        argv.append("-n")
    if grep_opts.get("wordMatch"):
        argv.append("-w")
    if grep_opts.get("fixedStrings"):
        argv.append("-F")
    max_count = grep_opts.get("maxCount")
    if max_count is not None:
        count = _positive_int(max_count, 0)
        if count > 0:
            argv.extend(["-m", str(count)])
    argv.append("--")
    argv.append(expression)
    return argv


def _apply_output_limits(text: str, max_bytes: int, max_lines: int) -> tuple[str, bool]:
    truncated = False
    lines = text.splitlines(keepends=True)
    if max_lines > 0 and len(lines) > max_lines:
        lines = lines[:max_lines]
        truncated = True
    text = "".join(lines)
    encoded = text.encode("utf-8")
    if max_bytes > 0 and len(encoded) > max_bytes:
        text = encoded[:max_bytes].decode("utf-8", errors="ignore")
        truncated = True
    return text, truncated


def _run_subprocess(argv: list[str], input_text: str, timeout_sec: int) -> str:
    if not argv or not argv[0] or shutil.which(argv[0]) is None:
        raise ReduceError(f"reducer command not available: {argv[0] if argv else 'unknown'}")
    try:
        completed = subprocess.run(
            argv,
            input=input_text,
            capture_output=True,
            text=True,
            timeout=timeout_sec,
            check=False,
        )
    except subprocess.TimeoutExpired as exc:
        raise ReduceError(f"reduction timed out after {timeout_sec}s") from exc
    if completed.returncode not in (0, 1):
        detail = (completed.stderr or completed.stdout or "").strip()
        if len(detail) > 200:
            detail = detail[:200] + "..."
        raise ReduceError(detail or f"reducer failed with exit code {completed.returncode}")
    return completed.stdout


def reduce_text(request: dict[str, Any]) -> dict[str, Any]:
    reducer = str(request.get("reducer") or "").strip().lower()
    expression = str(request.get("expression") or "")
    grep_opts = request.get("grep") or {}
    if not isinstance(grep_opts, dict):
        grep_opts = {}
    limits = limits_from_request(request)
    input_path = str(request.get("inputPath") or "")
    input_text = read_bounded_text(input_path, limits["maxInputBytes"])

    if reducer == "jq":
        validate_jq_expression(expression)
        if shutil.which("jq") is None:
            raise ReduceError("jq is not available")
        output = _run_subprocess(["jq", "-r", expression], input_text, limits["timeoutSeconds"])
    elif reducer == "grep":
        argv = build_grep_argv(expression, grep_opts)
        output = _run_subprocess(argv, input_text, limits["timeoutSeconds"])
    elif reducer == "awk":
        validate_awk_program(expression)
        if shutil.which("awk") is None:
            raise ReduceError("awk is not available")
        output = _run_subprocess(["awk", expression], input_text, limits["timeoutSeconds"])
    else:
        raise ReduceError("reducer must be jq, grep, or awk")

    output, truncated = _apply_output_limits(
        output,
        limits["maxOutputBytes"],
        limits["maxOutputLines"],
    )
    return {
        "output": output,
        "truncated": truncated,
        "reducer": reducer,
        "originalInputBytes": len(input_text.encode("utf-8")),
        "returnedBytes": len(output.encode("utf-8")),
    }


def main() -> int:
    parser = argparse.ArgumentParser(description="Reduce a stored MCP proxy result safely.")
    parser.add_argument("--request", help="JSON request (default: stdin)")
    args = parser.parse_args()
    raw = args.request if args.request is not None else sys.stdin.read()
    try:
        request = json.loads(raw or "{}")
        if not isinstance(request, dict):
            raise ReduceError("request must be a JSON object")
        result = reduce_text(request)
        print(json.dumps({"ok": True, **result}, ensure_ascii=False))
        return 0
    except (ReduceError, ValueError) as exc:
        print(json.dumps({"ok": False, "error": str(exc)}, ensure_ascii=False))
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
