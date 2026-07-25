#!/usr/bin/env python3
"""Evaluator verdict contract parsing and verbatim feedback rendering.

The canonical evaluator artifact is:

    {"status": "approved|changes-required", "feedback": ["string", ...]}

Rules beyond the JSON schema:
  * feedback is required (enforced by the schema).
  * feedback may be empty only when status is approved.
  * changes-required requires at least one non-empty feedback entry.

This module is dependency-free (stdlib only) and reuses the artifact JSON
schema subset validator so the contract stays a single source of truth.

Feedback is rendered into a clearly delimited Markdown block that is safe to
inject into a downstream prompt or plan handoff: byte content is preserved, but
Markdown fence breakouts are prevented by choosing a fence longer than any
backtick run in the feedback, and control characters that could corrupt the
block are rejected before rendering. Rendered output is only ever written to a
file; it is never passed through a shell, so command substitution and shell
interpolation cannot occur on the feedback bytes.
"""

from __future__ import annotations

import argparse
import json
import os
import sys
from typing import Any

_MODULE_DIR = os.path.dirname(os.path.abspath(__file__))
_DEFAULT_SCHEMA = os.path.normpath(
    os.path.join(_MODULE_DIR, "..", "schemas", "evaluator-verdict.schema.json")
)

try:
    import artifact_json_schema as _ajs
except ModuleNotFoundError:  # pragma: no cover - import shim for direct execution
    sys.path.insert(0, _MODULE_DIR)
    import artifact_json_schema as _ajs


class EvaluatorContractError(Exception):
    """Raised when an evaluator artifact violates the contract."""


def _read_text(path: str) -> str:
    try:
        with open(path, encoding="utf-8") as handle:
            return handle.read()
    except FileNotFoundError as exc:
        raise EvaluatorContractError(f"evaluator artifact not found: {path}") from exc


def load_contract(artifact_path: str, schema_path: str | None = None) -> dict[str, Any]:
    """Validate an evaluator artifact and return {"status", "feedback"}.

    Raises EvaluatorContractError on any contract violation.
    """
    schema_file = schema_path or _DEFAULT_SCHEMA
    try:
        schema = _ajs.load_schema_document(schema_file)
        _ajs.assert_supported_schema(schema, "$")
    except (ValueError, _ajs.UnsupportedSchemaKeywordError) as exc:
        raise EvaluatorContractError(f"evaluator schema invalid ({schema_file}): {exc}") from exc

    raw = _read_text(artifact_path)
    if not raw.strip():
        raise EvaluatorContractError(f"evaluator artifact is empty: {artifact_path}")

    try:
        _ajs.validate_json_text(raw, schema)
    except _ajs.SchemaValidationError as exc:
        raise EvaluatorContractError(
            f"evaluator artifact does not satisfy contract at {exc.json_path}: {exc}"
        ) from exc

    contract = json.loads(raw)
    status = contract["status"]
    feedback = contract["feedback"]

    non_empty = [entry for entry in feedback if isinstance(entry, str) and entry.strip()]
    if status == "changes-required" and not non_empty:
        raise EvaluatorContractError(
            "evaluator status is changes-required but feedback has no non-empty entries"
        )

    return {"status": status, "feedback": feedback}


def _reject_control_chars(feedback: list[str]) -> None:
    for index, entry in enumerate(feedback):
        for char in entry:
            # Allow tab and newline; reject other C0 controls that could corrupt
            # the delimited block or terminal rendering.
            if ord(char) < 0x20 and char not in ("\t", "\n"):
                raise EvaluatorContractError(
                    f"feedback entry {index} contains an unsupported control character "
                    f"(0x{ord(char):02x})"
                )


def _fence_for(feedback: list[str]) -> str:
    longest_run = 0
    for entry in feedback:
        run = 0
        for char in entry:
            if char == "`":
                run += 1
                longest_run = max(longest_run, run)
            else:
                run = 0
    return "`" * max(3, longest_run + 1)


def render_feedback_block(
    contract: dict[str, Any],
    source_stage: str,
    iteration: str,
    artifact_path: str,
) -> str:
    """Render verbatim, ordered feedback into a delimited Markdown block."""
    feedback = [entry for entry in contract.get("feedback", []) if isinstance(entry, str)]
    _reject_control_chars(feedback)
    fence = _fence_for(feedback)

    lines = []
    lines.append("<!-- RALPH_EVALUATOR_FEEDBACK: START -->")
    lines.append("## Reviewer feedback (changes required)")
    lines.append("")
    lines.append(f"- Source stage: `{source_stage}`")
    lines.append(f"- Iteration: `{iteration}`")
    lines.append(f"- Evaluator artifact: `{artifact_path}`")
    lines.append("")
    lines.append(
        "Address every item below before resubmitting. The text is the reviewer's "
        "verbatim feedback; do not reinterpret it."
    )
    lines.append("")
    for ordinal, entry in enumerate(feedback, start=1):
        lines.append(f"{ordinal}. Feedback item:")
        lines.append(fence)
        # Preserve bytes exactly. Multi-line entries are kept intact inside the fence.
        lines.append(entry)
        lines.append(fence)
    lines.append("<!-- RALPH_EVALUATOR_FEEDBACK: END -->")
    return "\n".join(lines) + "\n"


def _cmd_status(args: argparse.Namespace) -> int:
    try:
        contract = load_contract(args.artifact, args.schema or None)
    except EvaluatorContractError as exc:
        print(str(exc), file=sys.stderr)
        return 1
    print(contract["status"])
    return 0


def _cmd_feedback_block(args: argparse.Namespace) -> int:
    try:
        contract = load_contract(args.artifact, args.schema or None)
    except EvaluatorContractError as exc:
        print(str(exc), file=sys.stderr)
        return 1
    sys.stdout.write(
        render_feedback_block(
            contract,
            source_stage=args.source_stage,
            iteration=args.iteration,
            artifact_path=args.artifact_path or args.artifact,
        )
    )
    return 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Ralph evaluator verdict contract tools")
    sub = parser.add_subparsers(dest="command", required=True)

    status = sub.add_parser("status", help="Validate contract and print the status")
    status.add_argument("--artifact", required=True)
    status.add_argument("--schema", default="")
    status.set_defaults(func=_cmd_status)

    block = sub.add_parser("feedback-block", help="Render verbatim feedback Markdown block")
    block.add_argument("--artifact", required=True)
    block.add_argument("--schema", default="")
    block.add_argument("--source-stage", default="")
    block.add_argument("--iteration", default="")
    block.add_argument("--artifact-path", default="")
    block.set_defaults(func=_cmd_feedback_block)

    args = parser.parse_args(argv)
    return args.func(args)


if __name__ == "__main__":
    raise SystemExit(main())
