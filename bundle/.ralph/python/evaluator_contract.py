#!/usr/bin/env python3
"""Evaluator verdict contract parsing and verbatim feedback rendering.

The canonical evaluator artifact is:

    {"status": "approved|changes-required",
     "findings": [{"id", "severity", "summary", "evidence?", "requiredFix?",
                   "verification?", "disposition?", "priorFindingId?"}, ...]}

The legacy shape {"status": ..., "feedback": ["string", ...]} remains accepted
and is normalized into findings so a single downstream code path serves both.

Rules beyond the JSON schema:
  * changes-required requires at least one finding or one non-empty feedback
    entry; approved may carry neither.
  * finding ids must be unique within a verdict.
  * a blocking finding must carry a requiredFix so rework has actionable work.

Findings accumulate across rework rounds in a defect ledger (see
merge_verdict_into_ledger) so round N+1 sees every still-open finding, not only
the most recent verdict. A verdict cannot move to approved while a blocking
finding is still open and undispositioned.

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
import hashlib
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
    feedback = contract.get("feedback", [])
    findings = normalize_findings(contract)

    non_empty = [entry for entry in feedback if isinstance(entry, str) and entry.strip()]
    if status == "changes-required" and not non_empty and not findings:
        raise EvaluatorContractError(
            "evaluator status is changes-required but carries no findings and no "
            "non-empty feedback entries"
        )

    return {"status": status, "feedback": feedback, "findings": findings}


LEDGER_SCHEMA_VERSION = 1

# A finding synthesized from a legacy feedback[] entry gets a content-derived id.
# Positional ids (L1, L2) would be unstable identities: unrelated feedback that
# happened to land at the same index in a later round would be merged into one
# finding, and re-ordered feedback would look like new findings.
LEGACY_FINDING_ID_PREFIX = "L"


def _legacy_finding_id(text: str) -> str:
    digest = hashlib.sha256(text.encode("utf-8")).hexdigest()[:12]
    return f"{LEGACY_FINDING_ID_PREFIX}{digest}"


def normalize_findings(contract: dict[str, Any]) -> list[dict[str, Any]]:
    """Return the verdict's findings, synthesizing them from legacy feedback[].

    Legacy entries become blocking findings: the old contract had no severity,
    and treating unclassified reviewer text as advisory would silently weaken
    every pre-existing workflow.
    """
    raw_findings = contract.get("findings")
    if raw_findings:
        findings = []
        seen: set[str] = set()
        for index, entry in enumerate(raw_findings):
            finding_id = entry["id"]
            if finding_id in seen:
                raise EvaluatorContractError(
                    f"finding {index} repeats id {finding_id!r}; ids must be unique "
                    "within a verdict"
                )
            seen.add(finding_id)
            normalized = dict(entry)
            normalized.setdefault("disposition", "open")
            if (
                normalized["severity"] == "blocking"
                and normalized["disposition"] == "open"
                and not str(normalized.get("requiredFix", "")).strip()
            ):
                raise EvaluatorContractError(
                    f"finding {finding_id!r} is blocking and open but has no "
                    "requiredFix; rework cannot derive work from it"
                )
            findings.append(normalized)
        return findings

    findings = []
    seen_legacy: set[str] = set()
    for entry in contract.get("feedback", []):
        if not isinstance(entry, str) or not entry.strip():
            continue
        legacy_id = _legacy_finding_id(entry)
        if legacy_id in seen_legacy:
            # Verbatim-duplicate feedback entries are one finding.
            continue
        seen_legacy.add(legacy_id)
        findings.append(
            {
                "id": legacy_id,
                "severity": "blocking",
                "summary": entry,
                "requiredFix": entry,
                "disposition": "open",
            }
        )
    return findings


def verdict_digest(contract: dict[str, Any]) -> str:
    """Stable digest of a verdict's decision content, for merge idempotency."""
    payload = {
        "status": contract.get("status"),
        "findings": [
            {
                key: entry.get(key)
                for key in ("id", "severity", "summary", "evidence", "requiredFix",
                            "verification", "disposition", "priorFindingId")
                if key in entry
            }
            for entry in contract.get("findings", [])
        ],
    }
    encoded = json.dumps(payload, sort_keys=True, separators=(",", ":"))
    return hashlib.sha256(encoded.encode("utf-8")).hexdigest()[:16]


def _empty_ledger() -> dict[str, Any]:
    return {"schemaVersion": LEDGER_SCHEMA_VERSION, "findings": [], "rounds": []}


def load_ledger(path: str) -> dict[str, Any]:
    """Read a defect ledger, returning an empty ledger when absent."""
    if not path or not os.path.exists(path):
        return _empty_ledger()
    try:
        with open(path, encoding="utf-8") as handle:
            raw = handle.read()
    except OSError as exc:
        raise EvaluatorContractError(f"cannot read defect ledger {path}: {exc}") from exc
    if not raw.strip():
        return _empty_ledger()
    try:
        ledger = json.loads(raw)
    except ValueError as exc:
        raise EvaluatorContractError(f"defect ledger {path} is not valid JSON: {exc}") from exc
    if not isinstance(ledger, dict) or not isinstance(ledger.get("findings"), list):
        raise EvaluatorContractError(f"defect ledger {path} is malformed")
    ledger.setdefault("schemaVersion", LEDGER_SCHEMA_VERSION)
    ledger.setdefault("rounds", [])
    return ledger


def open_blocking(ledger: dict[str, Any]) -> list[dict[str, Any]]:
    """Findings that still block approval."""
    return [
        entry
        for entry in ledger.get("findings", [])
        if entry.get("severity") == "blocking" and entry.get("disposition") == "open"
    ]


def merge_verdict_into_ledger(
    ledger: dict[str, Any],
    contract: dict[str, Any],
    iteration: int,
    source_stage: str,
) -> dict[str, Any]:
    """Fold one verdict into the accumulated ledger and return the new ledger.

    Carry-forward is the point: a finding the latest reviewer failed to restate
    stays open, so a defect cannot be lost between rounds. Ageing is tracked so
    a repeatedly-unfixed finding can be escalated rather than silently burning
    the final rework iteration.
    """
    # Idempotent per (iteration, sourceStage, verdict content): dispatch can
    # legitimately re-run for the same rework round on retry or resume, and a
    # second merge of the same verdict would inflate roundsOpen and trip the
    # escalation threshold spuriously. A re-review that produced genuinely
    # different findings has a different digest and is merged normally.
    digest = verdict_digest(contract)
    for round_entry in ledger.get("rounds", []):
        if (
            round_entry.get("iteration") == iteration
            and round_entry.get("sourceStage") == source_stage
            and round_entry.get("verdictDigest") == digest
        ):
            return dict(ledger)

    merged = {
        "schemaVersion": LEDGER_SCHEMA_VERSION,
        "findings": [dict(entry) for entry in ledger.get("findings", [])],
        "rounds": list(ledger.get("rounds", [])),
    }
    by_id = {entry["id"]: entry for entry in merged["findings"]}

    status = contract["status"]
    incoming = contract.get("findings", [])
    # Resolved ledger ids, not incoming ids: a finding re-raised under a new id
    # via priorFindingId must not also be counted as unmentioned below.
    seen_ids: list[str] = []

    for entry in incoming:
        target_id = entry.get("priorFindingId") or entry["id"]
        existing = by_id.get(target_id)
        if existing is None and entry["id"] in by_id:
            existing = by_id[entry["id"]]
        seen_ids.append(existing["id"] if existing is not None else entry["id"])
        if existing is None:
            record = dict(entry)
            record["firstSeenIteration"] = iteration
            record["lastSeenIteration"] = iteration
            record["roundsOpen"] = 1 if record.get("disposition", "open") == "open" else 0
            record["sourceStage"] = source_stage
            merged["findings"].append(record)
            by_id[record["id"]] = record
            continue
        # Re-raised: refresh the reviewer-authored fields, keep the ledger history.
        for field in ("severity", "summary", "evidence", "requiredFix", "verification"):
            if field in entry:
                existing[field] = entry[field]
        existing["disposition"] = entry.get("disposition", "open")
        existing["lastSeenIteration"] = iteration
        existing["sourceStage"] = source_stage
        if existing["disposition"] == "open":
            existing["roundsOpen"] = int(existing.get("roundsOpen", 0)) + 1

    # Findings the latest verdict did not mention.
    for entry in merged["findings"]:
        if entry["id"] in seen_ids:
            continue
        if entry.get("disposition") != "open":
            continue
        if entry.get("severity") == "advisory":
            # Advisory items auto-close when a later reviewer stops raising them;
            # holding them open forever would make convergence impossible.
            entry["disposition"] = "wontfix"
            entry["closedBy"] = "unraised-advisory"
            continue
        entry["roundsOpen"] = int(entry.get("roundsOpen", 0)) + 1
        entry["carriedForward"] = True

    if status == "approved":
        still_open = open_blocking(merged)
        if still_open:
            ids = ", ".join(sorted(entry["id"] for entry in still_open))
            raise EvaluatorContractError(
                f"verdict is approved but blocking findings remain open: {ids}. "
                "Re-state each one with disposition fixed or wontfix before approving."
            )

    merged["rounds"].append(
        {
            "iteration": iteration,
            "sourceStage": source_stage,
            "status": status,
            "findingIds": seen_ids,
            "verdictDigest": digest,
        }
    )
    return merged


def write_ledger(path: str, ledger: dict[str, Any]) -> None:
    directory = os.path.dirname(os.path.abspath(path))
    if directory:
        os.makedirs(directory, exist_ok=True)
    tmp = f"{path}.tmp.{os.getpid()}"
    with open(tmp, "w", encoding="utf-8") as handle:
        json.dump(ledger, handle, indent=2, sort_keys=True)
        handle.write("\n")
    os.replace(tmp, path)


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


def render_ledger_feedback_block(
    ledger: dict[str, Any],
    source_stage: str,
    iteration: str,
    artifact_path: str,
) -> str:
    """Render every still-open finding, with age, as the rework brief.

    This replaces "latest verdict only" rendering: the downstream implementer
    must see the full open set, including items this round's reviewer did not
    restate, or a defect silently survives the loop.
    """
    findings = [
        entry
        for entry in ledger.get("findings", [])
        if entry.get("disposition") == "open"
    ]
    blocking = [entry for entry in findings if entry.get("severity") == "blocking"]
    advisory = [entry for entry in findings if entry.get("severity") != "blocking"]

    texts = []
    for entry in findings:
        for field in ("summary", "evidence", "requiredFix", "verification"):
            value = entry.get(field)
            if isinstance(value, str):
                texts.append(value)
    _reject_control_chars(texts)
    fence = _fence_for(texts)

    lines = []
    lines.append("<!-- RALPH_EVALUATOR_FEEDBACK: START -->")
    lines.append("## Reviewer feedback (changes required)")
    lines.append("")
    lines.append(f"- Source stage: `{source_stage}`")
    lines.append(f"- Iteration: `{iteration}`")
    lines.append(f"- Evaluator artifact: `{artifact_path}`")
    lines.append(f"- Open blocking findings: `{len(blocking)}`")
    lines.append("")
    lines.append(
        "Every open finding below must be resolved before this stage can be "
        "approved. Findings carry across rework rounds: an item the most recent "
        "reviewer did not restate is still open. The text is verbatim reviewer "
        "output; do not reinterpret it."
    )
    lines.append("")

    def _emit(entry: dict[str, Any], ordinal: int) -> None:
        rounds_open = int(entry.get("roundsOpen", 1))
        header = f"{ordinal}. Finding `{entry['id']}` ({entry.get('severity', 'blocking')})"
        if rounds_open > 1:
            header += (
                f" -- OPEN FOR {rounds_open} ROUNDS. Previous attempts did not "
                "resolve this. Do not repeat the previous approach."
            )
        lines.append(header)
        lines.append("")
        lines.append("   Summary:")
        lines.append(fence)
        lines.append(str(entry.get("summary", "")))
        lines.append(fence)
        for label, field in (
            ("Evidence", "evidence"),
            ("Required fix", "requiredFix"),
            ("Verification", "verification"),
        ):
            value = entry.get(field)
            if isinstance(value, str) and value.strip():
                lines.append(f"   {label}:")
                lines.append(fence)
                lines.append(value)
                lines.append(fence)
        lines.append("")

    ordinal = 0
    for entry in blocking:
        ordinal += 1
        _emit(entry, ordinal)
    for entry in advisory:
        ordinal += 1
        _emit(entry, ordinal)

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


def _cmd_require_approved(args: argparse.Namespace) -> int:
    """Exit non-zero unless the verdict approves.

    Gates decide on exit codes, so a stage whose verdict must gate the run needs
    a command that fails on changes-required rather than one that merely prints
    the status.
    """
    try:
        contract = load_contract(args.artifact, args.schema or None)
    except EvaluatorContractError as exc:
        print(str(exc), file=sys.stderr)
        return 1
    if contract["status"] == "approved":
        return 0
    findings = [f for f in contract.get("findings", []) if f.get("disposition", "open") == "open"]
    print(
        f"{args.artifact}: status is {contract['status']} with "
        f"{len(findings)} open finding(s); not approved",
        file=sys.stderr,
    )
    for finding in findings:
        print(f"  - [{finding.get('severity','blocking')}] {finding['id']}: "
              f"{finding.get('summary','')}", file=sys.stderr)
    return 2


def _cmd_ledger_merge(args: argparse.Namespace) -> int:
    try:
        contract = load_contract(args.artifact, args.schema or None)
        ledger = load_ledger(args.ledger)
        merged = merge_verdict_into_ledger(
            ledger,
            contract,
            iteration=int(args.iteration),
            source_stage=args.source_stage,
        )
        write_ledger(args.ledger, merged)
    except EvaluatorContractError as exc:
        print(str(exc), file=sys.stderr)
        return 1
    except ValueError as exc:
        print(f"invalid iteration {args.iteration!r}: {exc}", file=sys.stderr)
        return 1
    print(len(open_blocking(merged)))
    return 0


def _cmd_ledger_block(args: argparse.Namespace) -> int:
    try:
        ledger = load_ledger(args.ledger)
    except EvaluatorContractError as exc:
        print(str(exc), file=sys.stderr)
        return 1
    sys.stdout.write(
        render_ledger_feedback_block(
            ledger,
            source_stage=args.source_stage,
            iteration=args.iteration,
            artifact_path=args.artifact_path,
        )
    )
    return 0


def _cmd_ledger_stalled(args: argparse.Namespace) -> int:
    """Print blocking findings that have stayed open for at least N rounds.

    A finding that survives repeated rework rounds is not going to be fixed by
    running the same loop again; surfacing it lets the run stop with a precise
    reason instead of silently consuming its remaining iterations.
    """
    try:
        ledger = load_ledger(args.ledger)
        threshold = int(args.min_rounds)
    except EvaluatorContractError as exc:
        print(str(exc), file=sys.stderr)
        return 1
    except ValueError:
        print(f"invalid --min-rounds {args.min_rounds!r}", file=sys.stderr)
        return 1
    for entry in open_blocking(ledger):
        if int(entry.get("roundsOpen", 0)) >= threshold:
            print(f"{entry['id']}\t{entry.get('roundsOpen', 0)}")
    return 0


def _cmd_ledger_open(args: argparse.Namespace) -> int:
    """Print open blocking findings as JSON lines for deterministic TODO synthesis."""
    try:
        ledger = load_ledger(args.ledger)
    except EvaluatorContractError as exc:
        print(str(exc), file=sys.stderr)
        return 1
    for entry in open_blocking(ledger):
        print(json.dumps(entry, sort_keys=True))
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

    approved = sub.add_parser(
        "require-approved", help="Exit 0 only when the verdict status is approved"
    )
    approved.add_argument("--artifact", required=True)
    approved.add_argument("--schema", default="")
    approved.set_defaults(func=_cmd_require_approved)

    merge = sub.add_parser("ledger-merge", help="Fold a verdict into the defect ledger")
    merge.add_argument("--ledger", required=True)
    merge.add_argument("--artifact", required=True)
    merge.add_argument("--schema", default="")
    merge.add_argument("--iteration", default="1")
    merge.add_argument("--source-stage", default="")
    merge.set_defaults(func=_cmd_ledger_merge)

    lblock = sub.add_parser("ledger-block", help="Render all open findings as a rework brief")
    lblock.add_argument("--ledger", required=True)
    lblock.add_argument("--source-stage", default="")
    lblock.add_argument("--iteration", default="")
    lblock.add_argument("--artifact-path", default="")
    lblock.set_defaults(func=_cmd_ledger_block)

    lopen = sub.add_parser("ledger-open", help="Print open blocking findings as JSON lines")
    lopen.add_argument("--ledger", required=True)
    lopen.set_defaults(func=_cmd_ledger_open)

    lstall = sub.add_parser(
        "ledger-stalled", help="Print blocking findings open for at least N rounds"
    )
    lstall.add_argument("--ledger", required=True)
    lstall.add_argument("--min-rounds", default="3")
    lstall.set_defaults(func=_cmd_ledger_stalled)

    args = parser.parse_args(argv)
    return args.func(args)


if __name__ == "__main__":
    raise SystemExit(main())
