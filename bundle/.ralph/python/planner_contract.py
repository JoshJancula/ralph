#!/usr/bin/env python3
"""Authored planner-output (v2) validation and deterministic plan rendering.

Public CLI exposes pure validate/render helpers only. It never chooses a
workflow-run registry path or mutates run state.

Legacy classic dynamic-planner artifacts (rationale/items/verification) keep a
clearly internal read-only parser for orchestration compatibility. That path
never emits role fields into new workflow serialization.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import subprocess
import sys
from datetime import datetime, timezone
from typing import Any

_MODULE_DIR = os.path.dirname(os.path.abspath(__file__))
_DEFAULT_SCHEMA = os.path.normpath(
    os.path.join(_MODULE_DIR, "..", "schemas", "planner-output.schema.json")
)
_DEFAULT_MANIFEST_SCHEMA = os.path.normpath(
    os.path.join(_MODULE_DIR, "..", "schemas", "workflow-plan-manifest.schema.json")
)
_DEFAULT_VALIDATE_PLAN = os.path.normpath(
    os.path.join(_MODULE_DIR, "..", "validate-plan.sh")
)

try:
    import artifact_json_schema as _ajs
except ModuleNotFoundError:  # pragma: no cover
    sys.path.insert(0, _MODULE_DIR)
    import artifact_json_schema as _ajs

HARD_MAX_TODOS = 200
DEFAULT_MAX_TODOS = 100
VALID_RUNTIMES = frozenset({"cursor", "claude", "codex", "opencode", "antigravity"})
TODO_ID_RE = re.compile(r"^[a-z0-9]+(-[a-z0-9]+)*$")
STAGE_ID_RE = TODO_ID_RE
UTC_TS_RE = re.compile(r"^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$")
SHA256_RE = re.compile(r"^[a-f0-9]{64}$")

FIXED_FRESH_SESSION_INSTRUCTIONS = (
    "Execute exactly one TODO per Ralph iteration, in listed order. "
    "Reread repository instructions and named upstream artifacts before editing. "
    "Inspect current diffs before editing; preserve unrelated work. "
    "Do not invent product decisions. "
    "Run the TODO verification. "
    "Complete only that TODO."
)

OPERATOR_INPUT_PROTOCOL_BODY = (
    "Continue autonomously through ordinary implementation choices supported by repository evidence.\n"
    "When a missing product decision, unavailable credential configuration, external fact, or "
    "mutually exclusive requirement makes safe progress impossible:\n"
    "1. Call `ralph workflow actions request --question <text> [--details <text>]`\n"
    "2. Stop without completing the TODO and do not guess.\n"
    "Credential questions must ask the operator to configure a named environment or native secret "
    "source and reply when ready; never request the secret value.\n"
    "Standalone plans cannot create workflow requests; this protocol applies only under an active "
    "workflow-owned stage with supervisor-issued identity."
)

OPERATOR_INPUT_PROTOCOL_BLOCK = (
    "<!-- OPERATOR_INPUT: START -->\n"
    f"{OPERATOR_INPUT_PROTOCOL_BODY}\n"
    "<!-- OPERATOR_INPUT: END -->"
)

def operator_input_protocol_block() -> str:
    """Delimited OPERATOR_INPUT protocol rendered into generated plan instructions."""
    return OPERATOR_INPUT_PROTOCOL_BLOCK


# Keys forbidden on authored planner JSON (session owned by rendered plan).
FORBIDDEN_TOP_LEVEL_EXTRA = frozenset({"sessionStrategy"})


class PlannerContractError(Exception):
    """Raised when a planner artifact, config, or manifest is invalid."""


def _read_text(path: str) -> str:
    try:
        with open(path, encoding="utf-8") as handle:
            return handle.read()
    except FileNotFoundError as exc:
        raise PlannerContractError(f"planner artifact not found: {path}") from exc


def _load_json(path: str) -> dict[str, Any]:
    with open(path, encoding="utf-8") as handle:
        data = json.load(handle)
    if not isinstance(data, dict):
        raise PlannerContractError(f"expected JSON object in {path}")
    return data


def _yaml_scalar(value: str) -> str:
    text = str(value)
    if text == "":
        return '""'
    if any(ch in text for ch in (":", "#", "{", "}", "[", "]", ",", "&", "*", "!", "|", ">", "%", "@", "`")):
        return json.dumps(text)
    if text.strip() != text or text.lower() in {"true", "false", "null", "yes", "no"}:
        return json.dumps(text)
    if text[:1] in {"'", '"'} or text[:1].isdigit() or text.startswith("- "):
        return json.dumps(text)
    return text


def _yaml_block(key: str, value: str, indent: int = 0) -> list[str]:
    prefix = " " * indent
    lines = str(value).splitlines() or [""]
    if len(lines) == 1 and "\n" not in value and len(value) < 80:
        return [f"{prefix}{key}: {_yaml_scalar(value)}"]
    out = [f"{prefix}{key}: |"]
    for line in lines:
        out.append(f"{prefix}  {line}")
    return out


def validate_planner_config(planner: dict[str, Any] | None, *, stage_id: str = "") -> dict[str, Any]:
    """Validate authored planner config: only outputMode=plan-file and maxTodos."""
    prefix = f"stage {stage_id!r} planner" if stage_id else "planner"
    if planner in (None, False, ""):
        raise PlannerContractError(f"{prefix}: missing planner config")
    if not isinstance(planner, dict):
        raise PlannerContractError(f"{prefix}: must be an object")

    removed = sorted(
        set(planner)
        & {
            "allowedRoles",
            "allowedRuntimes",
            "allowedModels",
            "maxStages",
            "defaultRole",
            "defaultRuntime",
            "defaultModel",
        }
    )
    if removed:
        raise PlannerContractError(
            f"{prefix}: {', '.join(removed)} was removed. "
            "Use planner: {outputMode: plan-file, maxTodos: <n>} for a generated Ralph plan"
        )

    unknown = [key for key in planner if key not in {"outputMode", "maxTodos"}]
    if unknown:
        raise PlannerContractError(
            f"{prefix}: unknown field {unknown[0]!r}; only outputMode and maxTodos are permitted"
        )

    output_mode = str(planner.get("outputMode") or "").strip()
    if output_mode == "stages":
        raise PlannerContractError(
            f"{prefix}: outputMode stages was removed. "
            "Use planner: {outputMode: plan-file, maxTodos: <n>} for a generated Ralph plan"
        )
    if output_mode != "plan-file":
        raise PlannerContractError(f"{prefix}: outputMode must be plan-file")

    if "maxTodos" in planner:
        max_todos = planner.get("maxTodos")
        if not isinstance(max_todos, int) or isinstance(max_todos, bool):
            raise PlannerContractError(f"{prefix}: maxTodos must be an integer between 1 and {HARD_MAX_TODOS}")
        if max_todos < 1 or max_todos > HARD_MAX_TODOS:
            raise PlannerContractError(f"{prefix}: maxTodos must be an integer between 1 and {HARD_MAX_TODOS}")
    else:
        max_todos = DEFAULT_MAX_TODOS

    return {"outputMode": "plan-file", "maxTodos": max_todos}


def validate_orchestration(orchestration: dict[str, Any]) -> None:
    """Validate authored planner configs inside an orchestration JSON object."""
    stages = orchestration.get("stages") or []
    if not isinstance(stages, list):
        raise PlannerContractError("stages must be an array")
    for stage in stages:
        if not isinstance(stage, dict):
            continue
        planner = stage.get("planner")
        if planner in (None, False, ""):
            continue
        stage_id = str(stage.get("id") or "")
        validate_planner_config(planner if isinstance(planner, dict) else None, stage_id=stage_id)


def load_output(artifact_path: str, schema_path: str | None = None) -> dict[str, Any]:
    """Load and schema-validate a planner-output v2 artifact."""
    schema_file = schema_path or _DEFAULT_SCHEMA
    try:
        schema = _ajs.load_schema_document(schema_file)
        _ajs.assert_supported_schema(schema, "$")
    except (ValueError, _ajs.UnsupportedSchemaKeywordError) as exc:
        raise PlannerContractError(f"planner schema invalid ({schema_file}): {exc}") from exc

    raw = _read_text(artifact_path)
    if not raw.strip():
        raise PlannerContractError(f"planner artifact is empty: {artifact_path}")

    try:
        _ajs.validate_json_text(raw, schema)
    except _ajs.SchemaValidationError as exc:
        raise PlannerContractError(
            f"planner artifact does not satisfy contract at {exc.json_path}: {exc}"
        ) from exc

    data = json.loads(raw)
    if not isinstance(data, dict):
        raise PlannerContractError(f"expected JSON object in {artifact_path}")
    return data


def validate_output(
    output: dict[str, Any],
    *,
    max_todos: int = DEFAULT_MAX_TODOS,
) -> None:
    """Semantic validation for planner-output schema version 2."""
    if not isinstance(output, dict):
        raise PlannerContractError("planner output must be an object")

    unknown = [key for key in output if key not in {"schemaVersion", "name", "overview", "rationale", "todos"}]
    for key in unknown:
        if key in FORBIDDEN_TOP_LEVEL_EXTRA or key == "sessionStrategy":
            raise PlannerContractError(
                "planner output sessionStrategy is not permitted; "
                "the rendered plan owns the fixed fresh session strategy"
            )
        raise PlannerContractError(f"planner output unknown key {key!r}")

    if output.get("schemaVersion") != 2:
        raise PlannerContractError("planner output schemaVersion must be 2")

    for field in ("name", "overview", "rationale"):
        value = output.get(field)
        if not isinstance(value, str) or not value.strip():
            raise PlannerContractError(f"planner output {field} must be non-empty text")

    if not isinstance(max_todos, int) or isinstance(max_todos, bool):
        raise PlannerContractError(f"maxTodos must be an integer between 1 and {HARD_MAX_TODOS}")
    if max_todos < 1 or max_todos > HARD_MAX_TODOS:
        raise PlannerContractError(f"maxTodos must be an integer between 1 and {HARD_MAX_TODOS}")

    todos = output.get("todos")
    if not isinstance(todos, list) or not todos:
        raise PlannerContractError("planner output todos must be a non-empty array")
    if len(todos) > max_todos:
        raise PlannerContractError(
            f"planner output has {len(todos)} todos; configured maxTodos is {max_todos}"
        )
    if len(todos) > HARD_MAX_TODOS:
        raise PlannerContractError(f"planner output exceeds hard maximum {HARD_MAX_TODOS}")

    seen_ids: set[str] = set()
    for index, todo in enumerate(todos):
        prefix = f"todos[{index}]"
        if not isinstance(todo, dict):
            raise PlannerContractError(f"{prefix} must be an object")
        todo_unknown = [
            key for key in todo if key not in {"id", "content", "verification", "status", "runtime", "model"}
        ]
        if todo_unknown:
            if "sessionStrategy" in todo_unknown:
                raise PlannerContractError(
                    f"{prefix} sessionStrategy is not permitted; "
                    "the rendered plan owns the fixed fresh session strategy"
                )
            raise PlannerContractError(f"{prefix} unknown key {todo_unknown[0]!r}")

        todo_id = str(todo.get("id") or "").strip()
        if not TODO_ID_RE.match(todo_id):
            raise PlannerContractError(f"{prefix} id must be lowercase-hyphen kebab id")
        if todo_id in seen_ids:
            raise PlannerContractError(f"duplicate planner todo id: {todo_id}")
        seen_ids.add(todo_id)

        for field in ("content", "verification"):
            value = todo.get(field)
            if not isinstance(value, str) or not value.strip():
                raise PlannerContractError(f"{prefix} {field} must be non-empty text")

        status = todo.get("status")
        if status != "pending":
            raise PlannerContractError(f"{prefix} status must be pending")

        runtime = todo.get("runtime")
        model = todo.get("model")
        if runtime is not None:
            if not isinstance(runtime, str) or runtime not in VALID_RUNTIMES:
                raise PlannerContractError(f"{prefix} runtime must be one of {sorted(VALID_RUNTIMES)}")
        if model is not None:
            if not isinstance(model, str) or not model.strip():
                raise PlannerContractError(f"{prefix} model must be non-empty text when present")
        # model-only / runtime-only / paired are all valid at planner JSON layer.
        # Effective runtime for model-only is supplied by render defaults.


def parse_legacy_planner_artifact(data: dict[str, Any]) -> dict[str, Any]:
    """Internal read-only parser for classic dynamic-planner artifacts.

    Accepts the historical {rationale, items[], verification} shape used by
    RALPH_DYNAMIC_PLANNER orchestration tests. Never emits role fields and must
    not enter new workflow serialization.
    """
    if not isinstance(data, dict):
        raise PlannerContractError("legacy planner artifact must be an object")
    if data.get("schemaVersion") == 2 or "todos" in data:
        raise PlannerContractError("legacy parser does not accept planner-output v2")

    rationale = data.get("rationale")
    if not isinstance(rationale, str):
        raise PlannerContractError("legacy planner rationale must be a string")
    verification = data.get("verification")
    if not isinstance(verification, str) or not verification.strip():
        raise PlannerContractError("legacy planner verification must be non-empty text")
    items = data.get("items")
    if not isinstance(items, list) or not items:
        raise PlannerContractError("legacy planner items must be a non-empty array")

    parsed_items: list[dict[str, str]] = []
    seen: set[str] = set()
    for index, item in enumerate(items):
        if not isinstance(item, dict):
            raise PlannerContractError(f"legacy items[{index}] must be an object")
        item_id = str(item.get("id") or "").strip()
        if not STAGE_ID_RE.match(item_id.replace("_", "-")) and not re.match(
            r"^[a-z0-9_]+(-[a-z0-9_]+)*$", item_id
        ):
            raise PlannerContractError(f"legacy items[{index}] invalid id {item_id!r}")
        if item_id in seen:
            raise PlannerContractError(f"legacy duplicate item id: {item_id}")
        seen.add(item_id)
        content = item.get("content")
        if not isinstance(content, str) or not content.strip():
            raise PlannerContractError(f"legacy items[{index}] content must be non-empty")
        # Intentionally drop role/model/runtime from the returned view so callers
        # cannot serialize roles into new workflow paths via this parser.
        parsed_items.append({"id": item_id, "content": content.strip()})

    return {
        "rationale": rationale,
        "items": parsed_items,
        "verification": verification.strip(),
        "artifactRelationships": data.get("artifactRelationships") or [],
    }


def render_plan_markdown(
    output: dict[str, Any],
    *,
    default_runtime: str,
    default_model: str = "",
) -> str:
    """Render a deterministic YAML-frontmatter Ralph plan from planner-output v2."""
    validate_output(output)
    runtime = str(default_runtime or "").strip()
    if runtime not in VALID_RUNTIMES:
        raise PlannerContractError(
            f"default runtime must be one of {sorted(VALID_RUNTIMES)} (got {runtime!r})"
        )
    model = str(default_model or "").strip()

    lines: list[str] = [
        "---",
        f"name: {_yaml_scalar(str(output['name']).strip())}",
        f"overview: {_yaml_scalar(str(output['overview']).strip())}",
        "execution: standard",
        f"runtime: {runtime}",
    ]
    if model:
        lines.append(f"model: {_yaml_scalar(model)}")
    lines.append("sessionStrategy: fresh")
    instructions = (
        f"{FIXED_FRESH_SESSION_INSTRUCTIONS}\n\n{OPERATOR_INPUT_PROTOCOL_BLOCK}"
    )
    lines.extend(_yaml_block("instructions", instructions))
    lines.append("todos:")

    for todo in output["todos"]:
        lines.append(f"  - id: {todo['id']}")
        todo_runtime = str(todo.get("runtime") or "").strip()
        todo_model = str(todo.get("model") or "").strip()
        if todo_runtime:
            lines.append(f"    runtime: {todo_runtime}")
        if todo_model:
            lines.append(f"    model: {_yaml_scalar(todo_model)}")
        lines.extend(_yaml_block("content", str(todo["content"]).strip(), indent=4))
        lines.extend(_yaml_block("verification", str(todo["verification"]).strip(), indent=4))
        lines.append("    status: pending")

    lines.append("---")
    lines.append("")
    rationale = str(output.get("rationale") or "").strip()
    if rationale:
        lines.append(rationale)
        lines.append("")
    return "\n".join(lines)


def render_and_validate_plan(
    output: dict[str, Any],
    *,
    default_runtime: str,
    default_model: str = "",
    output_path: str,
    validate_plan_sh: str | None = None,
    max_todos: int = DEFAULT_MAX_TODOS,
) -> str:
    """Render planner JSON to output_path and run validate-plan.sh. Pure aside from that path."""
    validate_output(output, max_todos=max_todos)
    text = render_plan_markdown(
        output,
        default_runtime=default_runtime,
        default_model=default_model,
    )
    abs_out = os.path.abspath(output_path)
    parent = os.path.dirname(abs_out) or "."
    if not os.path.isdir(parent):
        raise PlannerContractError(f"output directory does not exist: {parent}")
    with open(abs_out, "w", encoding="utf-8") as handle:
        handle.write(text)

    validator = validate_plan_sh or _DEFAULT_VALIDATE_PLAN
    if not os.path.isfile(validator):
        raise PlannerContractError(f"validate-plan.sh not found: {validator}")
    completed = subprocess.run(
        ["bash", validator, abs_out],
        check=False,
        capture_output=True,
        text=True,
    )
    if completed.returncode != 0:
        detail = (completed.stderr or completed.stdout or "").strip()
        raise PlannerContractError(
            f"validate-plan.sh failed for {abs_out}"
            + (f": {detail}" if detail else "")
        )
    return text


def sha256_file(path: str) -> str:
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def utc_now() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def build_manifest(
    *,
    producer_stage_id: str,
    producer_attempt: int,
    source_artifact: str,
    plan_path: str,
    todo_count: int | None = None,
    plan_sha256: str | None = None,
    created_at: str | None = None,
) -> dict[str, Any]:
    """Pure builder for generated-plan manifest version 1 (no registry writes)."""
    stage_id = str(producer_stage_id or "").strip()
    if not STAGE_ID_RE.match(stage_id):
        raise PlannerContractError(f"producerStageId must be lowercase-hyphen: {stage_id!r}")
    if not isinstance(producer_attempt, int) or isinstance(producer_attempt, bool) or producer_attempt < 1:
        raise PlannerContractError("producerAttempt must be an integer >= 1")

    source_abs = os.path.abspath(source_artifact)
    plan_abs = os.path.abspath(plan_path)
    if not source_abs.startswith("/"):
        raise PlannerContractError("sourceArtifact must be an absolute path")
    if not plan_abs.startswith("/"):
        raise PlannerContractError("planPath must be an absolute path")

    if todo_count is None:
        if not os.path.isfile(plan_abs):
            raise PlannerContractError(f"plan path not found for todo count: {plan_abs}")
        # Count YAML todo ids; caller may pass an explicit count instead.
        todo_count = sum(
            1
            for line in _read_text(plan_abs).splitlines()
            if re.match(r"^  - id: ", line)
        )
    if not isinstance(todo_count, int) or isinstance(todo_count, bool) or todo_count < 1:
        raise PlannerContractError("todoCount must be an integer >= 1")
    if todo_count > HARD_MAX_TODOS:
        raise PlannerContractError(f"todoCount cannot exceed hard maximum {HARD_MAX_TODOS}")

    digest = plan_sha256 or sha256_file(plan_abs)
    if not SHA256_RE.match(digest):
        raise PlannerContractError("planSha256 must be a 64-char lowercase hex digest")

    timestamp = created_at or utc_now()
    if not UTC_TS_RE.match(timestamp):
        raise PlannerContractError("createdAt must be UTC YYYY-MM-DDTHH:MM:SSZ")

    return {
        "schemaVersion": 1,
        "producerStageId": stage_id,
        "producerAttempt": producer_attempt,
        "sourceArtifact": source_abs,
        "planPath": plan_abs,
        "planSha256": digest,
        "todoCount": todo_count,
        "createdAt": timestamp,
    }


def validate_manifest(
    manifest: dict[str, Any],
    *,
    schema_path: str | None = None,
) -> None:
    schema_file = schema_path or _DEFAULT_MANIFEST_SCHEMA
    try:
        schema = _ajs.load_schema_document(schema_file)
        _ajs.assert_supported_schema(schema, "$")
        _ajs.validate_json_text(json.dumps(manifest), schema)
    except (ValueError, _ajs.UnsupportedSchemaKeywordError, _ajs.SchemaValidationError) as exc:
        raise PlannerContractError(f"plan manifest invalid: {exc}") from exc

    if manifest.get("schemaVersion") != 1:
        raise PlannerContractError("plan manifest schemaVersion must be 1")


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Ralph planner-output v2 contract tools")
    sub = parser.add_subparsers(dest="command", required=True)

    validate_orch = sub.add_parser(
        "validate-orchestration",
        help="Validate authored planner stage configs (plan-file only)",
    )
    validate_orch.add_argument("--orchestration", required=True)

    validate_cmd = sub.add_parser("validate-output", help="Validate a planner-output v2 artifact")
    validate_cmd.add_argument("--artifact", required=True)
    validate_cmd.add_argument("--max-todos", type=int, default=DEFAULT_MAX_TODOS)
    validate_cmd.add_argument("--schema", default="")

    render_cmd = sub.add_parser(
        "render-plan",
        help="Render planner-output v2 to a YAML plan and run validate-plan.sh",
    )
    render_cmd.add_argument("--artifact", required=True)
    render_cmd.add_argument("--default-runtime", required=True)
    render_cmd.add_argument("--default-model", default="")
    render_cmd.add_argument("--output", required=True)
    render_cmd.add_argument("--max-todos", type=int, default=DEFAULT_MAX_TODOS)
    render_cmd.add_argument("--schema", default="")
    render_cmd.add_argument("--validate-plan", default=_DEFAULT_VALIDATE_PLAN)

    manifest_cmd = sub.add_parser("validate-manifest", help="Validate a generated-plan manifest")
    manifest_cmd.add_argument("--manifest", required=True)
    manifest_cmd.add_argument("--schema", default="")

    build_cmd = sub.add_parser("build-manifest", help="Build a pure generated-plan manifest JSON")
    build_cmd.add_argument("--producer-stage-id", required=True)
    build_cmd.add_argument("--producer-attempt", type=int, required=True)
    build_cmd.add_argument("--source-artifact", required=True)
    build_cmd.add_argument("--plan-path", required=True)
    build_cmd.add_argument("--todo-count", type=int, default=0)
    build_cmd.add_argument("--plan-sha256", default="")
    build_cmd.add_argument("--created-at", default="")

    legacy_cmd = sub.add_parser(
        "parse-legacy-output",
        help="Internal read-only parse of classic dynamic-planner artifacts",
    )
    legacy_cmd.add_argument("--artifact", required=True)

    args = parser.parse_args(argv)

    try:
        if args.command == "validate-orchestration":
            validate_orchestration(_load_json(args.orchestration))
            return 0

        if args.command == "validate-output":
            schema = args.schema or None
            output = load_output(args.artifact, schema)
            validate_output(output, max_todos=args.max_todos)
            print(json.dumps(output, sort_keys=True))
            return 0

        if args.command == "render-plan":
            schema = args.schema or None
            output = load_output(args.artifact, schema)
            render_and_validate_plan(
                output,
                default_runtime=args.default_runtime,
                default_model=args.default_model,
                output_path=args.output,
                validate_plan_sh=args.validate_plan,
                max_todos=args.max_todos,
            )
            print(os.path.abspath(args.output))
            return 0

        if args.command == "validate-manifest":
            manifest = _load_json(args.manifest)
            validate_manifest(manifest, schema_path=args.schema or None)
            print(json.dumps(manifest, sort_keys=True))
            return 0

        if args.command == "build-manifest":
            manifest = build_manifest(
                producer_stage_id=args.producer_stage_id,
                producer_attempt=args.producer_attempt,
                source_artifact=args.source_artifact,
                plan_path=args.plan_path,
                todo_count=args.todo_count or None,
                plan_sha256=args.plan_sha256 or None,
                created_at=args.created_at or None,
            )
            validate_manifest(manifest)
            print(json.dumps(manifest, sort_keys=True))
            return 0

        if args.command == "parse-legacy-output":
            raw = _load_json(args.artifact)
            parsed = parse_legacy_planner_artifact(raw)
            print(json.dumps(parsed, sort_keys=True))
            return 0
    except PlannerContractError as exc:
        print(str(exc), file=sys.stderr)
        return 1

    return 1


if __name__ == "__main__":
    raise SystemExit(main())
