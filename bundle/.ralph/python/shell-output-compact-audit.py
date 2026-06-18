#!/usr/bin/env python3
"""Read-only audit mode for estimating shell output compression savings.

Scans historical tool-result blobs and session transcripts without modifying
source files. Classifies compressible outputs and estimates potential savings.
Non-blocking: all errors are logged but do not cause exit code failure.
"""

from __future__ import annotations

import argparse
import json
import os
import sys
from dataclasses import dataclass, asdict
from pathlib import Path
from typing import Any, Iterator, Optional

try:
    from shell_output_compact import (
        classify_command,
        detect_output_shape,
        compact_shell_output,
        CompactResult,
    )
except ImportError:
    # Fallback: import from same directory
    import importlib.util

    spec = importlib.util.spec_from_file_location(
        "shell_output_compact",
        os.path.join(os.path.dirname(__file__), "shell-output-compact.py"),
    )
    shell_output_compact = importlib.util.module_from_spec(spec)
    sys.modules["shell_output_compact"] = shell_output_compact
    spec.loader.exec_module(shell_output_compact)
    classify_command = shell_output_compact.classify_command
    detect_output_shape = shell_output_compact.detect_output_shape
    compact_shell_output = shell_output_compact.compact_shell_output
    CompactResult = shell_output_compact.CompactResult


@dataclass(frozen=True)
class SavingsRecord:
    """Potential savings from a compressible output."""

    original_bytes: int
    estimated_compacted_bytes: int
    savings_bytes: int
    savings_percent: float
    family_id: Optional[str]
    classification_method: str  # "command" or "shape"
    source_path: str
    source_type: str  # "session_transcript", "log_file", etc.
    example_command: str
    example_original_preview: str
    example_compacted_preview: str

    def to_dict(self) -> dict[str, Any]:
        return asdict(self)


@dataclass(frozen=True)
class AuditResult:
    """Results from an audit run."""

    workspace_path: str
    plan_key: str
    scanned_files: int
    scanned_bytes: int
    total_potential_savings_bytes: int
    total_potential_savings_percent: float
    records: list[SavingsRecord]
    errors: list[str]
    timestamp: str

    def to_dict(self) -> dict[str, Any]:
        return {
            "workspace_path": self.workspace_path,
            "plan_key": self.plan_key,
            "scanned_files": self.scanned_files,
            "scanned_bytes": self.scanned_bytes,
            "total_potential_savings_bytes": self.total_potential_savings_bytes,
            "total_potential_savings_percent": self.total_potential_savings_percent,
            "records": [r.to_dict() for r in self.records],
            "errors": self.errors,
            "timestamp": self.timestamp,
        }


_RALPH_AUDIT_FILE_SUFFIXES = (".json", ".jsonl", ".txt")


def _ralph_audit_is_scannable_file(path: Path) -> bool:
    if path.name.startswith("."):
        return False
    if not path.is_file():
        return False
    return path.suffix.lower() in _RALPH_AUDIT_FILE_SUFFIXES


def _ralph_audit_read_file(path: Path) -> Optional[tuple[str, bytes]]:
    try:
        return str(path), path.read_bytes()
    except OSError:
        return None


def _ralph_audit_scan_directory(
    root: Path,
    *,
    source_type: str,
    recursive: bool = False,
) -> list[tuple[str, bytes, str]]:
    """Scan a Ralph-owned directory for readable audit candidates."""
    candidates: list[tuple[str, bytes, str]] = []
    if not root.exists() or not root.is_dir():
        return candidates

    try:
        paths: Iterator[Path]
        if recursive:
            paths = (
                item
                for item in root.rglob("*")
                if _ralph_audit_is_scannable_file(item)
            )
        else:
            paths = (
                item
                for item in root.iterdir()
                if _ralph_audit_is_scannable_file(item)
            )
        for item in paths:
            loaded = _ralph_audit_read_file(item)
            if loaded is not None:
                file_path, file_bytes = loaded
                candidates.append((file_path, file_bytes, source_type))
    except OSError:
        pass

    return candidates


def _ralph_audit_scan_locations(
    ralph_workspace: Path,
    plan_key: str,
) -> list[tuple[str, bytes, str]]:
    """Return Ralph-owned session, log, and stored tool-result files for a plan key."""
    candidates: list[tuple[str, bytes, str]] = []

    session_dir = ralph_workspace / "sessions" / plan_key
    candidates.extend(
        _ralph_audit_scan_directory(session_dir, source_type="session_file")
    )

    log_dir = ralph_workspace / "logs" / plan_key
    candidates.extend(
        _ralph_audit_scan_directory(
            log_dir,
            source_type="log_file",
            recursive=True,
        )
    )

    tool_results_dir = ralph_workspace / "tool-results" / plan_key / "results"
    candidates.extend(
        _ralph_audit_scan_directory(
            tool_results_dir,
            source_type="stored_tool_result",
        )
    )

    return candidates


def _parse_tool_result_object(
    data: dict[str, Any],
) -> Optional[tuple[str, str, str, int]]:
    if not (
        "stdout" in data
        or "stderr" in data
        or "command" in data
    ):
        return None

    cmd = str(data.get("command", ""))
    stdout = str(data.get("stdout", ""))
    stderr = str(data.get("stderr", ""))
    exit_raw = data.get("exit_status", data.get("exitCode"))
    if exit_raw is None:
        exit_status = 0
    else:
        try:
            exit_status = int(exit_raw)
        except (TypeError, ValueError):
            exit_status = 0
    return cmd, stdout, stderr, exit_status


def _try_extract_tool_results(
    file_path: str,
    file_bytes: bytes,
    errors: list[str],
    *,
    max_errors: int,
) -> list[tuple[str, str, str, int]]:
    """Try to extract tool result records from a file.

    Returns list of (command, stdout, stderr, exit_status) tuples.
    Handles JSON, JSONL, and stored tool-result blobs. Malformed JSON is skipped
    without aborting the file scan.
    """
    results: list[tuple[str, str, str, int]] = []

    try:
        text = file_bytes.decode("utf-8", errors="ignore")
    except Exception:
        return results

    def _append_error(message: str) -> None:
        if len(errors) < max_errors:
            errors.append(message)

    # Try parsing as a single JSON object (stored tool results, one-shot logs).
    try:
        data = json.loads(text)
        if isinstance(data, dict):
            parsed = _parse_tool_result_object(data)
            if parsed is not None:
                results.append(parsed)
        return results
    except (json.JSONDecodeError, ValueError):
        pass

    # JSONL: one JSON object per line; skip malformed lines.
    for line_no, line in enumerate(text.splitlines(), start=1):
        stripped = line.strip()
        if not stripped or stripped.startswith("#"):
            continue
        try:
            data = json.loads(stripped)
        except (json.JSONDecodeError, ValueError):
            _append_error(
                f"Malformed JSON in {file_path} line {line_no}; skipping line"
            )
            continue
        if not isinstance(data, dict):
            continue
        parsed = _parse_tool_result_object(data)
        if parsed is not None:
            results.append(parsed)

    return results


def _estimate_compression(
    command: str,
    stdout: str,
    stderr: str,
    exit_status: int,
) -> Optional[tuple[int, int, str, str, str]]:
    """Estimate compression savings for a tool result.

    Returns (original_bytes, compacted_bytes, family_id, compacted_stdout, compacted_stderr)
    or None if not compressible.
    """
    try:
        combined = (stdout + "\n" + stderr if stderr else stdout).encode("utf-8")
        original_bytes = len(combined)

        if original_bytes == 0:
            return None

        # Try to compact
        try:
            result = compact_shell_output(command, stdout, stderr, exit_status)
            if not result.compacted:
                return None

            compacted_combined = (result.stdout + "\n" + result.stderr if result.stderr else result.stdout).encode("utf-8")
            compacted_bytes = len(compacted_combined)

            # Only count as savings if we actually reduced size
            if compacted_bytes >= original_bytes:
                return None

            return (
                original_bytes,
                compacted_bytes,
                result.family or "unknown",
                result.stdout,
                result.stderr,
            )
        except Exception:
            return None
    except Exception:
        return None


def _classify_output(
    command: str,
    stdout: str,
    stderr: str,
) -> tuple[Optional[str], str]:
    """Classify an output and determine classification method.

    Returns (family_id, classification_method) where classification_method
    is either "command" or "shape".
    """
    combined = stdout + "\n" + stderr if stderr else stdout

    # Try command-based classification first
    family_id = classify_command(command)
    if family_id:
        return family_id, "command"

    # Try shape detection
    family_id = detect_output_shape(combined)
    if family_id:
        return family_id, "shape"

    return None, "none"


def _process_audit_candidate(
    file_path: str,
    file_bytes: bytes,
    source_type: str,
    records: list[SavingsRecord],
    errors: list[str],
    *,
    max_errors: int,
) -> None:
    tool_results = _try_extract_tool_results(
        file_path,
        file_bytes,
        errors,
        max_errors=max_errors,
    )
    for cmd, stdout, stderr, exit_status in tool_results:
        if len(errors) >= max_errors:
            return

        try:
            est = _estimate_compression(cmd, stdout, stderr, exit_status)
            if est is None:
                continue

            (
                orig_bytes,
                compact_bytes,
                _compact_family,
                compact_stdout,
                compact_stderr,
            ) = est
            savings = orig_bytes - compact_bytes
            if savings <= 0:
                continue

            savings_pct = (savings / orig_bytes * 100 if orig_bytes > 0 else 0.0)
            family_id, method = _classify_output(cmd, stdout, stderr)
            if not family_id:
                family_id = _compact_family

            orig_preview = (stdout + stderr)[:200].replace("\n", " | ")
            compact_preview = (compact_stdout + compact_stderr)[:200].replace(
                "\n", " | "
            )

            records.append(
                SavingsRecord(
                    original_bytes=orig_bytes,
                    estimated_compacted_bytes=compact_bytes,
                    savings_bytes=savings,
                    savings_percent=savings_pct,
                    family_id=family_id,
                    classification_method=method,
                    source_path=file_path,
                    source_type=source_type,
                    example_command=cmd[:100],
                    example_original_preview=orig_preview,
                    example_compacted_preview=compact_preview,
                )
            )
        except Exception as exc:
            if len(errors) < max_errors:
                errors.append(
                    f"Error estimating compression for {file_path}: {exc}"
                )


def audit_workspace(
    workspace_path: str,
    plan_key: str,
    max_errors: int = 100,
) -> AuditResult:
    """Run compression audit on workspace session/log data.

    Args:
        workspace_path: Root path containing .ralph-workspace
        plan_key: Plan identifier (e.g., PLAN42)
        max_errors: Maximum errors to collect before stopping

    Returns:
        AuditResult with findings and any errors encountered
    """
    from datetime import datetime, timezone

    workspace = Path(workspace_path)
    errors: list[str] = []
    records: list[SavingsRecord] = []
    total_scanned_files = 0
    total_scanned_bytes = 0

    # Determine workspace root
    ralph_workspace = workspace / ".ralph-workspace"
    if not ralph_workspace.exists():
        errors.append(
            f"Workspace root .ralph-workspace not found at {workspace}"
        )
        return AuditResult(
            workspace_path=workspace_path,
            plan_key=plan_key,
            scanned_files=0,
            scanned_bytes=0,
            total_potential_savings_bytes=0,
            total_potential_savings_percent=0.0,
            records=[],
            errors=errors,
            timestamp=datetime.now(timezone.utc).isoformat(),
        )

    try:
        candidates = _ralph_audit_scan_locations(ralph_workspace, plan_key)
        for file_path, file_bytes, source_type in candidates:
            if len(errors) >= max_errors:
                break
            total_scanned_files += 1
            total_scanned_bytes += len(file_bytes)
            try:
                _process_audit_candidate(
                    file_path,
                    file_bytes,
                    source_type,
                    records,
                    errors,
                    max_errors=max_errors,
                )
            except Exception as exc:
                if len(errors) < max_errors:
                    errors.append(
                        f"Error processing audit candidate {file_path}: {exc}"
                    )
    except Exception as exc:
        if len(errors) < max_errors:
            errors.append(f"Error scanning Ralph-owned audit locations: {exc}")

    # Aggregate results
    total_savings_bytes = sum(r.savings_bytes for r in records)
    total_savings_pct = (
        (total_savings_bytes / total_scanned_bytes * 100)
        if total_scanned_bytes > 0
        else 0.0
    )

    return AuditResult(
        workspace_path=workspace_path,
        plan_key=plan_key,
        scanned_files=total_scanned_files,
        scanned_bytes=total_scanned_bytes,
        total_potential_savings_bytes=total_savings_bytes,
        total_potential_savings_percent=total_savings_pct,
        records=records,
        errors=errors,
        timestamp=datetime.now(timezone.utc).isoformat(),
    )


def main(argv: list[str] | None = None) -> int:
    """Main entry point for audit mode.

    Always returns 0 (non-blocking) regardless of errors.
    """
    args_list = argv if argv is not None else sys.argv[1:]

    parser = argparse.ArgumentParser(
        description="Estimate shell output compression savings from historical data"
    )
    parser.add_argument(
        "--workspace",
        required=True,
        help="Workspace root path (contains .ralph-workspace/)",
    )
    parser.add_argument(
        "--plan-key",
        required=True,
        help="Plan identifier (e.g., PLAN42)",
    )
    parser.add_argument(
        "--output",
        required=False,
        help="Path to write audit results JSON (stdout if not provided)",
    )

    try:
        parsed = parser.parse_args(args_list)
    except SystemExit as e:
        # Non-blocking: log error and return success
        if e.code != 0:
            print(
                "Error parsing arguments; audit mode is non-blocking",
                file=sys.stderr,
            )
        return 0

    try:
        result = audit_workspace(
            workspace_path=parsed.workspace,
            plan_key=parsed.plan_key,
        )

        output_dict = result.to_dict()
        output_json = json.dumps(output_dict, indent=2, ensure_ascii=False)

        if parsed.output:
            try:
                output_path = Path(parsed.output)
                output_path.parent.mkdir(parents=True, exist_ok=True)
                output_path.write_text(output_json)
            except Exception as e:
                # Non-blocking: write to stdout instead
                print(output_json)
        else:
            print(output_json)

        return 0
    except Exception as e:
        # Non-blocking: log error and return success
        print(f"Audit error (non-blocking): {e}", file=sys.stderr)
        return 0


if __name__ == "__main__":
    raise SystemExit(main())
