#!/usr/bin/env python3
"""Independent rubric-driven grading: deterministic checks and result merging."""

from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
import time
from dataclasses import dataclass
from typing import Any

_MODULE_DIR = os.path.dirname(os.path.abspath(__file__))
_DEFAULT_RUBRIC_SCHEMA = os.path.normpath(
    os.path.join(_MODULE_DIR, "..", "schemas", "rubric.schema.json")
)
_DEFAULT_RESULT_SCHEMA = os.path.normpath(
    os.path.join(_MODULE_DIR, "..", "schemas", "rubric-result.schema.json")
)

try:
    import artifact_json_schema as _ajs
    import artifact_provenance as _prov
    import rubric_contract as _rc
except ModuleNotFoundError:  # pragma: no cover
    sys.path.insert(0, _MODULE_DIR)
    import artifact_json_schema as _ajs
    import artifact_provenance as _prov
    import rubric_contract as _rc

DETERMINISTIC_TYPES = frozenset(
    {"file_exists", "json_pointer", "regex", "command", "citation"}
)


class RubricGraderError(Exception):
    """Raised when rubric loading or grading fails."""


@dataclass
class CriterionOutcome:
    criterion_id: str
    satisfied: bool
    notes: str
    deterministic: bool
    required: bool


def _read_json(path: str) -> Any:
    with open(path, encoding="utf-8") as handle:
        return json.load(handle)


def load_rubric(path: str, schema_path: str | None = None) -> dict[str, Any]:
    schema_file = schema_path or _DEFAULT_RUBRIC_SCHEMA
    try:
        schema = _ajs.load_schema_document(schema_file)
        _ajs.assert_supported_schema(schema, "$")
    except (ValueError, _ajs.UnsupportedSchemaKeywordError) as exc:
        raise RubricGraderError(f"rubric schema invalid ({schema_file}): {exc}") from exc

    try:
        with open(path, encoding="utf-8") as handle:
            raw = handle.read()
    except FileNotFoundError as exc:
        raise RubricGraderError(f"rubric file not found: {path}") from exc

    if not raw.strip():
        raise RubricGraderError(f"rubric file is empty: {path}")

    try:
        _ajs.validate_json_text(raw, schema)
    except _ajs.SchemaValidationError as exc:
        raise RubricGraderError(
            f"rubric does not satisfy schema at {exc.json_path}: {exc}"
        ) from exc

    rubric = json.loads(raw)
    _validate_check_payloads(rubric)
    return rubric


def _validate_check_payloads(rubric: dict[str, Any]) -> None:
    for item in rubric.get("criteria", []):
        check = item.get("check", {})
        ctype = check.get("type")
        cid = item.get("id", "")
        if ctype == "file_exists":
            if not check.get("path"):
                raise RubricGraderError(f"criterion {cid}: file_exists requires path")
        elif ctype == "json_pointer":
            if not check.get("path") or not check.get("pointer"):
                raise RubricGraderError(
                    f"criterion {cid}: json_pointer requires path and pointer"
                )
        elif ctype == "regex":
            if not check.get("path") or not check.get("pattern"):
                raise RubricGraderError(f"criterion {cid}: regex requires path and pattern")
        elif ctype == "command":
            if not check.get("command"):
                raise RubricGraderError(f"criterion {cid}: command requires command")
        elif ctype == "citation":
            if not check.get("ref"):
                raise RubricGraderError(f"criterion {cid}: citation requires ref")
        elif ctype == "model_judgment":
            if not check.get("prompt"):
                raise RubricGraderError(
                    f"criterion {cid}: model_judgment requires prompt"
                )
        else:
            raise RubricGraderError(f"criterion {cid}: unknown check type {ctype!r}")


def _resolve_path(
    workspace: str,
    rel_path: str,
    *,
    artifact_ns: str = "",
    plan_key: str = "",
    stage_id: str = "",
) -> str:
    expanded = _ajs.expand_artifact_tokens(
        rel_path,
        artifact_ns=artifact_ns,
        plan_key=plan_key,
        stage_id=stage_id,
    )
    return _ajs.resolve_project_path(workspace, expanded)


def _run_command_check(
    workspace: str,
    command: str,
    *,
    timeout_secs: int,
) -> tuple[bool, str]:
    if timeout_secs <= 0:
        timeout_secs = 300
    tmp = os.path.join(workspace, f".ralph-rubric-cmd-{os.getpid()}.out")
    try:
        proc = subprocess.Popen(
            ["bash", "-c", command],
            cwd=workspace,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            env={"HOME": os.environ.get("HOME", ""), "PATH": os.environ.get("PATH", "")},
        )
        waited = 0
        timed_out = False
        while proc.poll() is None:
            if waited >= timeout_secs:
                timed_out = True
                proc.kill()
                try:
                    proc.wait(timeout=1)
                except subprocess.TimeoutExpired:
                    pass
                break
            time.sleep(1)
            waited += 1
        output = proc.stdout.read().decode("utf-8", errors="replace") if proc.stdout else ""
        with open(tmp, "w", encoding="utf-8") as handle:
            handle.write(output)
        if timed_out:
            return False, f"command timed out after {timeout_secs}s (output compacted to {tmp})"
        if proc.returncode != 0:
            tail = output.strip().splitlines()[-5:]
            detail = "\n".join(tail) if tail else f"exit={proc.returncode}"
            return False, f"command failed (exit={proc.returncode}): {detail}"
        return True, "command succeeded"
    finally:
        if os.path.isfile(tmp):
            try:
                os.remove(tmp)
            except OSError:
                pass


def run_deterministic_check(
    criterion: dict[str, Any],
    workspace: str,
    *,
    artifact_ns: str = "",
    plan_key: str = "",
    stage_id: str = "",
    timeout_secs: int = 300,
) -> CriterionOutcome:
    cid = str(criterion.get("id", ""))
    required = bool(criterion.get("required", False))
    check = criterion.get("check", {})
    ctype = check.get("type")

    if ctype == "model_judgment":
        return CriterionOutcome(
            criterion_id=cid,
            satisfied=False,
            notes="pending model judgment",
            deterministic=False,
            required=required,
        )

    try:
        if ctype == "file_exists":
            abs_path = _resolve_path(
                workspace,
                str(check["path"]),
                artifact_ns=artifact_ns,
                plan_key=plan_key,
                stage_id=stage_id,
            )
            ok = os.path.isfile(abs_path) and os.path.getsize(abs_path) > 0
            return CriterionOutcome(
                criterion_id=cid,
                satisfied=ok,
                notes="file exists and is non-empty" if ok else f"missing or empty: {check['path']}",
                deterministic=True,
                required=required,
            )

        if ctype == "json_pointer":
            abs_path = _resolve_path(
                workspace,
                str(check["path"]),
                artifact_ns=artifact_ns,
                plan_key=plan_key,
                stage_id=stage_id,
            )
            document = _read_json(abs_path)
            pointer = str(check["pointer"])
            ok = _prov._json_pointer_exists(document, pointer)
            return CriterionOutcome(
                criterion_id=cid,
                satisfied=ok,
                notes=f"pointer {pointer} found" if ok else f"pointer {pointer} not found",
                deterministic=True,
                required=required,
            )

        if ctype == "regex":
            abs_path = _resolve_path(
                workspace,
                str(check["path"]),
                artifact_ns=artifact_ns,
                plan_key=plan_key,
                stage_id=stage_id,
            )
            with open(abs_path, encoding="utf-8") as handle:
                text = handle.read()
            flags = 0
            pattern = str(check["pattern"])
            if re.search(pattern, text, flags):
                return CriterionOutcome(
                    criterion_id=cid,
                    satisfied=True,
                    notes="pattern matched",
                    deterministic=True,
                    required=required,
                )
            return CriterionOutcome(
                criterion_id=cid,
                satisfied=False,
                notes=f"pattern not matched in {check['path']}",
                deterministic=True,
                required=required,
            )

        if ctype == "command":
            ok, note = _run_command_check(
                workspace,
                str(check["command"]),
                timeout_secs=timeout_secs,
            )
            return CriterionOutcome(
                criterion_id=cid,
                satisfied=ok,
                notes=note,
                deterministic=True,
                required=required,
            )

        if ctype == "citation":
            ref = str(check["ref"])
            excerpt = check.get("excerpt")
            if excerpt is not None:
                ref = f'{ref} "{excerpt}"'
            _prov.validate_artifact_citation(workspace, ref, location=cid)
            return CriterionOutcome(
                criterion_id=cid,
                satisfied=True,
                notes="citation validated",
                deterministic=True,
                required=required,
            )

        raise RubricGraderError(f"criterion {cid}: unsupported deterministic check {ctype!r}")
    except (_prov.ProvenanceError, RubricGraderError, ValueError, OSError, json.JSONDecodeError) as exc:
        return CriterionOutcome(
            criterion_id=cid,
            satisfied=False,
            notes=str(exc),
            deterministic=True,
            required=required,
        )


def run_deterministic_checks(
    rubric: dict[str, Any],
    workspace: str,
    *,
    artifact_ns: str = "",
    plan_key: str = "",
    stage_id: str = "",
    timeout_secs: int = 300,
) -> list[CriterionOutcome]:
    outcomes: list[CriterionOutcome] = []
    for criterion in rubric.get("criteria", []):
        outcomes.append(
            run_deterministic_check(
                criterion,
                workspace,
                artifact_ns=artifact_ns,
                plan_key=plan_key,
                stage_id=stage_id,
                timeout_secs=timeout_secs,
            )
        )
    return outcomes


def model_judgment_criteria(rubric: dict[str, Any]) -> list[dict[str, Any]]:
    return [
        item
        for item in rubric.get("criteria", [])
        if item.get("check", {}).get("type") == "model_judgment"
    ]


def outcomes_to_json(outcomes: list[CriterionOutcome]) -> list[dict[str, Any]]:
    return [
        {
            "id": item.criterion_id,
            "satisfied": item.satisfied,
            "notes": item.notes,
            "deterministic": item.deterministic,
            "required": item.required,
        }
        for item in outcomes
    ]


def build_model_judgment_prompt(
    rubric: dict[str, Any],
    deterministic_outcomes: list[CriterionOutcome],
    *,
    target_artifacts: list[str] | None = None,
    allowed_sources: list[str] | None = None,
) -> str:
    lines = [
        "You are an independent rubric grader. Judge only the criteria listed under "
        "'Model judgment criteria'. Deterministic checks have already been executed; "
        "do not override those results.",
        "",
        f"Rubric id: {rubric.get('id', '')}",
    ]
    if rubric.get("description"):
        lines.append(f"Rubric description: {rubric['description']}")
    lines.append("")
    if target_artifacts:
        lines.append("Target artifacts:")
        for path in target_artifacts:
            lines.append(f"- {path}")
        lines.append("")
    if allowed_sources:
        lines.append("Allowed source files/tools:")
        for path in allowed_sources:
            lines.append(f"- {path}")
        lines.append("")
    lines.append("Deterministic check results (read-only):")
    for item in deterministic_outcomes:
        if item.deterministic:
            verdict = "satisfied" if item.satisfied else "not satisfied"
            lines.append(f"- {item.criterion_id}: {verdict} ({item.notes})")
    lines.append("")
    lines.append("Model judgment criteria:")
    for criterion in model_judgment_criteria(rubric):
        check = criterion.get("check", {})
        lines.append(f"- {criterion.get('id')}: {criterion.get('description')}")
        lines.append(f"  prompt: {check.get('prompt')}")
    lines.append("")
    lines.append(
        "Write a single JSON object matching rubric-result.schema.json with keys "
        "status, criteria, and feedback. Include every rubric criterion id in "
        "criteria with satisfied and optional notes. Use status approved only when "
        "all required criteria are satisfied."
    )
    return "\n".join(lines) + "\n"


def merge_results(
    rubric: dict[str, Any],
    deterministic_outcomes: list[CriterionOutcome],
    model_result: dict[str, Any] | None,
) -> dict[str, Any]:
    by_id: dict[str, CriterionOutcome] = {
        item.criterion_id: item for item in deterministic_outcomes
    }
    model_by_id: dict[str, dict[str, Any]] = {}
    if model_result:
        for entry in model_result.get("criteria", []):
            if isinstance(entry, dict) and entry.get("id"):
                model_by_id[str(entry["id"])] = entry

    merged_criteria: list[dict[str, Any]] = []
    feedback: list[str] = list(model_result.get("feedback", [])) if model_result else []

    for criterion in rubric.get("criteria", []):
        cid = str(criterion.get("id", ""))
        required = bool(criterion.get("required", False))
        ctype = criterion.get("check", {}).get("type")
        det = by_id.get(cid)
        if det and det.deterministic:
            merged_criteria.append(
                {
                    "id": cid,
                    "satisfied": det.satisfied,
                    "notes": det.notes,
                }
            )
            if required and not det.satisfied:
                feedback.append(f"Required criterion {cid} failed: {det.notes}")
            continue
        model_entry = model_by_id.get(cid, {})
        satisfied = bool(model_entry.get("satisfied", False))
        notes = str(model_entry.get("notes", ""))
        merged_criteria.append({"id": cid, "satisfied": satisfied, **({"notes": notes} if notes else {})})
        if ctype == "model_judgment" and required and not satisfied:
            feedback.append(
                f"Required model judgment {cid} not satisfied"
                + (f": {notes}" if notes else "")
            )

    required_det_fail = any(
        item.required and item.deterministic and not item.satisfied
        for item in deterministic_outcomes
    )
    required_model_fail = any(
        bool(criterion.get("required", False))
        and not next(
            (entry["satisfied"] for entry in merged_criteria if entry["id"] == criterion.get("id")),
            False,
        )
        for criterion in rubric.get("criteria", [])
        if criterion.get("check", {}).get("type") == "model_judgment"
    )

    if required_det_fail or required_model_fail:
        status = "changes-required"
    else:
        status = "approved"

    # Deterministic required failures always force changes-required.
    if required_det_fail:
        status = "changes-required"

    if status == "changes-required":
        feedback = [entry for entry in feedback if isinstance(entry, str) and entry.strip()]
        if not feedback:
            feedback = [
                f"Required criterion {item.criterion_id} failed: {item.notes}"
                for item in deterministic_outcomes
                if item.required and item.deterministic and not item.satisfied
            ]
    else:
        feedback = []

    result = {"status": status, "criteria": merged_criteria, "feedback": feedback}
    schema = _ajs.load_schema_document(_DEFAULT_RESULT_SCHEMA)
    _ajs.assert_supported_schema(schema, "$")
    _ajs.validate_instance(result, schema, "$")
    return result


def write_result(path: str, result: dict[str, Any]) -> None:
    parent = os.path.dirname(path)
    if parent:
        os.makedirs(parent, exist_ok=True)
    with open(path, "w", encoding="utf-8") as handle:
        json.dump(result, handle, indent=2)
        handle.write("\n")


def _cmd_validate(args: argparse.Namespace) -> int:
    try:
        load_rubric(args.rubric, args.schema or None)
    except RubricGraderError as exc:
        print(str(exc), file=sys.stderr)
        return 1
    return 0


def _cmd_deterministic(args: argparse.Namespace) -> int:
    try:
        rubric = load_rubric(args.rubric, args.schema or None)
        outcomes = run_deterministic_checks(
            rubric,
            args.workspace,
            artifact_ns=args.artifact_ns,
            plan_key=args.plan_key,
            stage_id=args.stage_id,
            timeout_secs=int(args.timeout or 300),
        )
    except RubricGraderError as exc:
        print(str(exc), file=sys.stderr)
        return 1
    json.dump(outcomes_to_json(outcomes), sys.stdout, indent=2)
    sys.stdout.write("\n")
    return 0


def _cmd_merge(args: argparse.Namespace) -> int:
    try:
        rubric = load_rubric(args.rubric, args.schema or None)
        with open(args.deterministic, encoding="utf-8") as handle:
            det_raw = json.load(handle)
        det_outcomes = [
            CriterionOutcome(
                criterion_id=str(item["id"]),
                satisfied=bool(item["satisfied"]),
                notes=str(item.get("notes", "")),
                deterministic=bool(item.get("deterministic", True)),
                required=bool(item.get("required", False)),
            )
            for item in det_raw
        ]
        model_result = None
        if args.model_result:
            with open(args.model_result, encoding="utf-8") as handle:
                model_result = json.load(handle)
        result = merge_results(rubric, det_outcomes, model_result)
        if args.output:
            write_result(args.output, result)
        else:
            json.dump(result, sys.stdout, indent=2)
            sys.stdout.write("\n")
    except (RubricGraderError, json.JSONDecodeError, KeyError, _ajs.SchemaValidationError) as exc:
        print(str(exc), file=sys.stderr)
        return 1
    return 0


def _cmd_model_prompt(args: argparse.Namespace) -> int:
    try:
        rubric = load_rubric(args.rubric, args.schema or None)
        with open(args.deterministic, encoding="utf-8") as handle:
            det_raw = json.load(handle)
        det_outcomes = [
            CriterionOutcome(
                criterion_id=str(item["id"]),
                satisfied=bool(item["satisfied"]),
                notes=str(item.get("notes", "")),
                deterministic=bool(item.get("deterministic", True)),
                required=bool(item.get("required", False)),
            )
            for item in det_raw
        ]
        targets = [line for line in (args.targets or "").split("\n") if line.strip()]
        sources = [line for line in (args.sources or "").split("\n") if line.strip()]
        sys.stdout.write(
            build_model_judgment_prompt(
                rubric,
                det_outcomes,
                target_artifacts=targets or None,
                allowed_sources=sources or None,
            )
        )
    except (RubricGraderError, json.JSONDecodeError, KeyError) as exc:
        print(str(exc), file=sys.stderr)
        return 1
    return 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Ralph rubric grader tools")
    sub = parser.add_subparsers(dest="command", required=True)

    validate = sub.add_parser("validate", help="Validate a rubric file")
    validate.add_argument("--rubric", required=True)
    validate.add_argument("--schema", default="")
    validate.set_defaults(func=_cmd_validate)

    deterministic = sub.add_parser("deterministic", help="Run deterministic rubric checks")
    deterministic.add_argument("--rubric", required=True)
    deterministic.add_argument("--workspace", required=True)
    deterministic.add_argument("--schema", default="")
    deterministic.add_argument("--artifact-ns", default="")
    deterministic.add_argument("--plan-key", default="")
    deterministic.add_argument("--stage-id", default="")
    deterministic.add_argument("--timeout", default="300")
    deterministic.set_defaults(func=_cmd_deterministic)

    merge = sub.add_parser("merge", help="Merge deterministic and model rubric results")
    merge.add_argument("--rubric", required=True)
    merge.add_argument("--deterministic", required=True)
    merge.add_argument("--model-result", default="")
    merge.add_argument("--schema", default="")
    merge.add_argument("--output", default="")
    merge.set_defaults(func=_cmd_merge)

    prompt = sub.add_parser("model-prompt", help="Build model-judgment grader prompt")
    prompt.add_argument("--rubric", required=True)
    prompt.add_argument("--deterministic", required=True)
    prompt.add_argument("--schema", default="")
    prompt.add_argument("--targets", default="")
    prompt.add_argument("--sources", default="")
    prompt.set_defaults(func=_cmd_model_prompt)

    args = parser.parse_args(argv)
    return args.func(args)


if __name__ == "__main__":
    raise SystemExit(main())
