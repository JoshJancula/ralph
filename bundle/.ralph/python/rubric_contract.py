#!/usr/bin/env python3
"""Rubric result contract parsing and feedback rendering for evaluator loopback."""

from __future__ import annotations

import argparse
import json
import os
import sys
from typing import Any

_MODULE_DIR = os.path.dirname(os.path.abspath(__file__))
_DEFAULT_SCHEMA = os.path.normpath(
    os.path.join(_MODULE_DIR, "..", "schemas", "rubric-result.schema.json")
)

try:
    import artifact_json_schema as _ajs
except ModuleNotFoundError:  # pragma: no cover
    sys.path.insert(0, _MODULE_DIR)
    import artifact_json_schema as _ajs


class RubricContractError(Exception):
    """Raised when a rubric result artifact violates the contract."""


def _read_text(path: str) -> str:
    try:
        with open(path, encoding="utf-8") as handle:
            return handle.read()
    except FileNotFoundError as exc:
        raise RubricContractError(f"rubric result artifact not found: {path}") from exc


def load_contract(artifact_path: str, schema_path: str | None = None) -> dict[str, Any]:
    """Validate a rubric-result artifact and return the parsed contract."""
    schema_file = schema_path or _DEFAULT_SCHEMA
    try:
        schema = _ajs.load_schema_document(schema_file)
        _ajs.assert_supported_schema(schema, "$")
    except (ValueError, _ajs.UnsupportedSchemaKeywordError) as exc:
        raise RubricContractError(f"rubric result schema invalid ({schema_file}): {exc}") from exc

    raw = _read_text(artifact_path)
    if not raw.strip():
        raise RubricContractError(f"rubric result artifact is empty: {artifact_path}")

    try:
        _ajs.validate_json_text(raw, schema)
    except _ajs.SchemaValidationError as exc:
        raise RubricContractError(
            f"rubric result artifact does not satisfy contract at {exc.json_path}: {exc}"
        ) from exc

    contract = json.loads(raw)
    status = contract["status"]
    feedback = contract["feedback"]
    criteria = contract["criteria"]

    non_empty = [entry for entry in feedback if isinstance(entry, str) and entry.strip()]
    if status == "changes-required" and not non_empty:
        raise RubricContractError(
            "rubric result status is changes-required but feedback has no non-empty entries"
        )

    if not criteria:
        raise RubricContractError("rubric result criteria must not be empty")

    return {"status": status, "feedback": feedback, "criteria": criteria}


def render_feedback_block(
    contract: dict[str, Any],
    source_stage: str,
    iteration: str,
    artifact_path: str,
) -> str:
    """Render rubric feedback into a delimited Markdown block for loopback."""
    feedback = [entry for entry in contract.get("feedback", []) if isinstance(entry, str)]
    criteria = contract.get("criteria", [])

    lines = []
    lines.append("<!-- RALPH_EVALUATOR_FEEDBACK: START -->")
    lines.append("## Rubric grader feedback (changes required)")
    lines.append("")
    lines.append(f"- Source stage: `{source_stage}`")
    lines.append(f"- Iteration: `{iteration}`")
    lines.append(f"- Rubric result artifact: `{artifact_path}`")
    lines.append("")
    lines.append(
        "Address every item below before resubmitting. Deterministic rubric failures "
        "cannot be waived by the model grader."
    )
    lines.append("")
    if criteria:
        lines.append("### Criterion results")
        lines.append("")
        for item in criteria:
            cid = item.get("id", "")
            satisfied = item.get("satisfied", False)
            notes = item.get("notes", "")
            verdict = "satisfied" if satisfied else "not satisfied"
            lines.append(f"- `{cid}`: {verdict}")
            if isinstance(notes, str) and notes.strip():
                lines.append(f"  - {notes.strip()}")
        lines.append("")
    for ordinal, entry in enumerate(feedback, start=1):
        lines.append(f"{ordinal}. Feedback item:")
        lines.append("```")
        lines.append(entry)
        lines.append("```")
    lines.append("<!-- RALPH_EVALUATOR_FEEDBACK: END -->")
    return "\n".join(lines) + "\n"


def _cmd_status(args: argparse.Namespace) -> int:
    try:
        contract = load_contract(args.artifact, args.schema or None)
    except RubricContractError as exc:
        print(str(exc), file=sys.stderr)
        return 1
    print(contract["status"])
    return 0


def _cmd_feedback_block(args: argparse.Namespace) -> int:
    try:
        contract = load_contract(args.artifact, args.schema or None)
    except RubricContractError as exc:
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
    parser = argparse.ArgumentParser(description="Ralph rubric result contract tools")
    sub = parser.add_subparsers(dest="command", required=True)

    status = sub.add_parser("status", help="Validate contract and print the status")
    status.add_argument("--artifact", required=True)
    status.add_argument("--schema", default="")
    status.set_defaults(func=_cmd_status)

    block = sub.add_parser("feedback-block", help="Render rubric feedback Markdown block")
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
