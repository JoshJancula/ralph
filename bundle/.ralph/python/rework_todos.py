#!/usr/bin/env python3
"""Synthesize rework TODOs from open blocking findings in a defect ledger.

Why this exists: a rework round used to receive an unchanged copy of the
original plan, whose TODOs were already complete, with the reviewer's feedback
appended as prose below the frontmatter. The runner instruction ("Complete
exactly this TODO and nothing else") therefore pointed the agent at the stale
original task and away from the fix. Rework rounds could not converge because
the required fix was never work the runner could see.

This helper turns each open blocking finding into a real, pending, verifiable
TODO in the looped-back stage's control plan.

Insertion is textual, not a YAML round-trip: the control plan carries authored
block scalars, ordering, and comments that a load/dump cycle would reformat.
Only the TODO list is touched.

Dependency-free (stdlib only).
"""

from __future__ import annotations

import argparse
import json
import os
import re
import sys

_MODULE_DIR = os.path.dirname(os.path.abspath(__file__))
if _MODULE_DIR not in sys.path:
    sys.path.insert(0, _MODULE_DIR)

import evaluator_contract as ec  # noqa: E402

TODO_ID_PREFIX = "rework-"
_ID_SAFE_RE = re.compile(r"[^A-Za-z0-9._-]+")


class ReworkSynthesisError(Exception):
    """Raised when the control plan cannot accept synthesized TODOs."""


def todo_id_for(finding_id: str) -> str:
    return f"{TODO_ID_PREFIX}{_ID_SAFE_RE.sub('-', finding_id)}"


def _fallback_verification(finding_id: str) -> str:
    # A finding with no reviewer-supplied command still needs a per-TODO
    # verification, but inventing a command would fabricate evidence. Assert the
    # reviewer closed it instead, which is checkable and honest.
    return (
        "python3 .ralph/python/rework_todos.py assert-closed "
        f"--ledger .ralph-workspace/artifacts/${{RALPH_ARTIFACT_NS}}/defect-ledger.json "
        f"--finding {finding_id}"
    )


def _todo_body(finding: dict) -> str:
    rounds_open = int(finding.get("roundsOpen", 1))
    lines = [f"Resolve reviewer finding {finding['id']}."]
    if rounds_open > 1:
        lines.append(
            f"This finding has been open for {rounds_open} rounds; previous "
            "attempts did not resolve it. Do not repeat the previous approach."
        )
    lines.append("")
    lines.append(f"Summary: {finding.get('summary', '').strip()}")
    evidence = str(finding.get("evidence", "")).strip()
    if evidence:
        lines.append(f"Evidence: {evidence}")
    required_fix = str(finding.get("requiredFix", "")).strip()
    if required_fix:
        lines.append(f"Required fix: {required_fix}")
    lines.append(
        "Make only the change this finding requires; do not bundle unrelated work."
    )
    return "\n".join(lines)


def _indent_block(text: str, indent: str) -> list[str]:
    return [f"{indent}{line}" if line.strip() else "" for line in text.split("\n")]


def _split_frontmatter(content: str) -> tuple[list[str], int, int] | None:
    """Return (lines, first_delim_idx, second_delim_idx) or None when absent."""
    lines = content.split("\n")
    if not lines or lines[0].strip() != "---":
        return None
    for idx in range(1, len(lines)):
        if lines[idx].strip() == "---":
            return lines, 0, idx
    return None


def _find_todos_block_end(lines: list[str], start: int, end: int) -> tuple[int, str] | None:
    """Locate the `todos:` key in the frontmatter and the line after its block.

    Returns (insert_index, item_indent) where item_indent is the indent of the
    existing `- ` entries.
    """
    todos_idx = None
    todos_indent = 0
    for idx in range(start + 1, end):
        stripped = lines[idx].lstrip()
        if stripped.startswith("todos:") and not lines[idx][0].isspace():
            todos_idx = idx
            todos_indent = 0
            break
    if todos_idx is None:
        return None

    item_indent = "  "
    last_content = todos_idx
    for idx in range(todos_idx + 1, end):
        line = lines[idx]
        if not line.strip():
            continue
        indent = len(line) - len(line.lstrip())
        if indent <= todos_indent:
            break
        if line.lstrip().startswith("- "):
            item_indent = " " * indent
        last_content = idx
    return last_content + 1, item_indent


def _existing_todo_ids(content: str) -> set[str]:
    ids = set()
    for match in re.finditer(r"^\s*(?:-\s+)?id:\s*(\S+)\s*$", content, re.MULTILINE):
        ids.add(match.group(1).strip("\"'"))
    for match in re.finditer(r"addressesFinding:\s*(\S+)", content):
        ids.add(todo_id_for(match.group(1).strip("\"'")))
    return ids


def _render_yaml_todo(finding: dict, item_indent: str) -> list[str]:
    field_indent = item_indent + "  "
    verification = str(finding.get("verification", "")).strip() or _fallback_verification(
        finding["id"]
    )
    out = [f"{item_indent}- id: {todo_id_for(finding['id'])}"]
    out.append(f"{field_indent}addressesFinding: {finding['id']}")
    out.append(f"{field_indent}content: |")
    out.extend(_indent_block(_todo_body(finding), field_indent + "  "))
    out.append(f"{field_indent}verification: |")
    out.extend(_indent_block(verification, field_indent + "  "))
    out.append(f"{field_indent}status: pending")
    return out


def _render_markdown_todo(finding: dict) -> list[str]:
    verification = str(finding.get("verification", "")).strip()
    body = _todo_body(finding).replace("\n", " ").strip()
    out = [f"- [ ] {body}"]
    if verification:
        out.append(f"      Verification: {verification}")
    return out


def sync_plan(plan_path: str, ledger_path: str) -> list[str]:
    """Append a TODO per open blocking finding. Returns the ids added."""
    if not os.path.isfile(plan_path):
        raise ReworkSynthesisError(f"control plan not found: {plan_path}")
    ledger = ec.load_ledger(ledger_path)
    findings = ec.open_blocking(ledger)
    if not findings:
        return []

    with open(plan_path, encoding="utf-8") as handle:
        content = handle.read()

    existing = _existing_todo_ids(content)
    pending = [f for f in findings if todo_id_for(f["id"]) not in existing]
    if not pending:
        return []

    split = _split_frontmatter(content)
    block = split and _find_todos_block_end(split[0], split[1], split[2])
    if block is not None:
        lines, insert_at = split[0], block[0]
        item_indent = block[1]
        rendered: list[str] = []
        for finding in pending:
            rendered.extend(_render_yaml_todo(finding, item_indent))
        lines[insert_at:insert_at] = rendered
        new_content = "\n".join(lines)
    else:
        # Classic checkbox plan: append at the end of the body.
        rendered = []
        for finding in pending:
            rendered.extend(_render_markdown_todo(finding))
        suffix = "" if content.endswith("\n") else "\n"
        new_content = content + suffix + "\n" + "\n".join(rendered) + "\n"

    tmp = f"{plan_path}.rework.{os.getpid()}"
    with open(tmp, "w", encoding="utf-8") as handle:
        handle.write(new_content)
    os.replace(tmp, plan_path)
    return [todo_id_for(f["id"]) for f in pending]


def assert_closed(ledger_path: str, finding_id: str) -> bool:
    ledger = ec.load_ledger(ledger_path)
    for entry in ledger.get("findings", []):
        if entry.get("id") == finding_id:
            return entry.get("disposition") != "open"
    # An id absent from the ledger cannot be asserted closed.
    return False


def unresolved_findings(ledger_path: str, plan_path: str) -> list[str]:
    """Open blocking findings whose synthesized TODO is not completed.

    This is the convergence check: it answers "did this rework round actually
    do the work the reviewer asked for" before the next review runs.
    """
    ledger = ec.load_ledger(ledger_path)
    open_ids = [entry["id"] for entry in ec.open_blocking(ledger)]
    if not open_ids:
        return []
    if not os.path.isfile(plan_path):
        return open_ids
    with open(plan_path, encoding="utf-8") as handle:
        content = handle.read()

    unresolved = []
    for finding_id in open_ids:
        todo_id = todo_id_for(finding_id)
        pattern = re.compile(
            r"^\s*-\s+id:\s*" + re.escape(todo_id) + r"\s*$(.*?)(?=^\s*-\s+id:|\Z)",
            re.MULTILINE | re.DOTALL,
        )
        match = pattern.search(content)
        if match is None or not re.search(r"^\s*status:\s*completed\s*$",
                                          match.group(1), re.MULTILINE):
            unresolved.append(finding_id)
    return unresolved


def _cmd_sync(args: argparse.Namespace) -> int:
    try:
        added = sync_plan(args.plan, args.ledger)
    except (ReworkSynthesisError, ec.EvaluatorContractError) as exc:
        print(str(exc), file=sys.stderr)
        return 1
    for todo_id in added:
        print(todo_id)
    return 0


def _cmd_assert_closed(args: argparse.Namespace) -> int:
    try:
        closed = assert_closed(args.ledger, args.finding)
    except ec.EvaluatorContractError as exc:
        print(str(exc), file=sys.stderr)
        return 1
    if closed:
        return 0
    print(
        f"finding {args.finding} is still open in the defect ledger; the reviewer "
        "has not accepted this fix",
        file=sys.stderr,
    )
    return 1


def _cmd_unresolved(args: argparse.Namespace) -> int:
    try:
        unresolved = unresolved_findings(args.ledger, args.plan)
    except ec.EvaluatorContractError as exc:
        print(str(exc), file=sys.stderr)
        return 1
    for finding_id in unresolved:
        print(finding_id)
    return 1 if unresolved and args.strict else 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Ralph rework TODO synthesis")
    sub = parser.add_subparsers(dest="command", required=True)

    sync = sub.add_parser("sync", help="Append a TODO per open blocking finding")
    sync.add_argument("--plan", required=True)
    sync.add_argument("--ledger", required=True)
    sync.set_defaults(func=_cmd_sync)

    closed = sub.add_parser("assert-closed", help="Exit 0 when a finding is dispositioned")
    closed.add_argument("--ledger", required=True)
    closed.add_argument("--finding", required=True)
    closed.set_defaults(func=_cmd_assert_closed)

    unresolved = sub.add_parser(
        "unresolved", help="List open blocking findings with no completed TODO"
    )
    unresolved.add_argument("--ledger", required=True)
    unresolved.add_argument("--plan", required=True)
    unresolved.add_argument("--strict", action="store_true")
    unresolved.set_defaults(func=_cmd_unresolved)

    args = parser.parse_args(argv)
    return args.func(args)


if __name__ == "__main__":
    raise SystemExit(main())
