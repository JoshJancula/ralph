#!/usr/bin/env python3
"""Ralph stdlib JSON Schema subset validator for orchestration artifact contracts."""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
from typing import Any

SUPPORTED_KEYWORDS = frozenset(
    {
        "type",
        "properties",
        "required",
        "items",
        "enum",
        "minItems",
        "maxItems",
        "minLength",
        "maxLength",
        "minimum",
        "maximum",
        "pattern",
        "additionalProperties",
    }
)

TYPE_NAMES = frozenset(
    {"object", "array", "string", "number", "integer", "boolean", "null"}
)

ARTIFACT_TOKEN_RE = re.compile(r"\{\{([^{}]+)\}\}")
ABSOLUTE_PATH_RE = re.compile(r"(^/|^~|^[A-Za-z]:[\\/]|^\\\\)")
PARENT_TRAVERSAL_RE = re.compile(r"(^|/)\.\.(/|$)")
ALLOWED_TOKENS = frozenset({"ARTIFACT_NS", "PLAN_KEY", "STAGE_ID"})

ARTIFACT_LIST_FIELDS = ("artifacts", "outputArtifacts", "inputArtifacts")


class SchemaValidationError(Exception):
    def __init__(self, message: str, json_path: str = "$") -> None:
        super().__init__(message)
        self.json_path = json_path
        self.message = message


class UnsupportedSchemaKeywordError(Exception):
    def __init__(self, keyword: str, schema_path: str = "$") -> None:
        super().__init__(f"unsupported schema keyword: {keyword}")
        self.keyword = keyword
        self.schema_path = schema_path


def _fail(message: str) -> None:
    print(message, file=sys.stderr)
    raise SystemExit(1)


def expand_artifact_tokens(
    path: str,
    *,
    artifact_ns: str = "",
    plan_key: str = "",
    stage_id: str = "",
) -> str:
    plan_key = plan_key or artifact_ns
    return (
        path.replace("{{ARTIFACT_NS}}", artifact_ns)
        .replace("{{PLAN_KEY}}", plan_key)
        .replace("{{STAGE_ID}}", stage_id)
    )


def validate_portable_path(context: str, path: str) -> None:
    if not path:
        raise ValueError(f"{context}: path must not be empty")
    for token in ARTIFACT_TOKEN_RE.findall(path):
        if token not in ALLOWED_TOKENS:
            raise ValueError(f"{context}: unsupported token {{{{{token}}}}}")
    if ABSOLUTE_PATH_RE.search(path):
        raise ValueError(f"{context}: absolute paths are not portable")
    if PARENT_TRAVERSAL_RE.search(path):
        raise ValueError(f"{context}: parent traversal is not portable")
    base = os.path.basename(path)
    if base.startswith(".env"):
        raise ValueError(f"{context}: .env-like paths are not permitted")


def resolve_project_path(workspace: str, rel_path: str) -> str:
    workspace_abs = os.path.abspath(workspace)
    candidate = os.path.abspath(os.path.join(workspace_abs, rel_path))
    workspace_prefix = workspace_abs if workspace_abs.endswith(os.sep) else workspace_abs + os.sep
    if candidate != workspace_abs and not candidate.startswith(workspace_prefix):
        raise ValueError(f"path resolves outside project root: {rel_path}")
    return candidate


def load_schema_document(schema_path: str) -> dict[str, Any]:
    with open(schema_path, encoding="utf-8") as handle:
        raw = handle.read()
    if not raw.strip():
        raise ValueError("schema file is empty")
    try:
        document = json.loads(raw)
    except json.JSONDecodeError as exc:
        raise ValueError(f"schema file is not valid JSON: {exc}") from exc
    if not isinstance(document, dict):
        raise ValueError("schema file must contain a JSON object")
    return document


def _schema_pointer(base: str, suffix: str) -> str:
    if suffix:
        return f"{base}{suffix}"
    return base


def assert_supported_schema(schema: Any, schema_path: str = "$") -> None:
    if not isinstance(schema, dict):
        raise UnsupportedSchemaKeywordError("non-object schema", schema_path)
    for key, value in schema.items():
        if key not in SUPPORTED_KEYWORDS:
            raise UnsupportedSchemaKeywordError(key, _schema_pointer(schema_path, f"/{key}"))
        if key == "type":
            if isinstance(value, str):
                if value not in TYPE_NAMES:
                    raise SchemaValidationError(f"unsupported type value: {value}", schema_path)
            elif isinstance(value, list):
                if not value or not all(isinstance(item, str) and item in TYPE_NAMES for item in value):
                    raise SchemaValidationError("invalid type array", schema_path)
            else:
                raise SchemaValidationError("type must be a string or array of strings", schema_path)
        elif key == "properties" and not isinstance(value, dict):
            raise SchemaValidationError("properties must be an object", schema_path)
        elif key == "required":
            if not isinstance(value, list) or not all(isinstance(item, str) for item in value):
                raise SchemaValidationError("required must be an array of strings", schema_path)
        elif key == "items" and not isinstance(value, dict):
            raise SchemaValidationError("items must be an object", schema_path)
        elif key == "enum":
            if not isinstance(value, list) or len(value) == 0:
                raise SchemaValidationError("enum must be a non-empty array", schema_path)
        elif key in {"minItems", "maxItems"}:
            if not isinstance(value, int) or isinstance(value, bool):
                raise SchemaValidationError(f"{key} must be an integer", schema_path)
        elif key in {"minLength", "maxLength"}:
            if not isinstance(value, int) or isinstance(value, bool) or value < 0:
                raise SchemaValidationError(f"{key} must be a non-negative integer", schema_path)
        elif key in {"minimum", "maximum"}:
            if not isinstance(value, (int, float)) or isinstance(value, bool):
                raise SchemaValidationError(f"{key} must be a number", schema_path)
        elif key == "pattern":
            if not isinstance(value, str):
                raise SchemaValidationError("pattern must be a string", schema_path)
            try:
                re.compile(value)
            except re.error as exc:
                raise SchemaValidationError(f"invalid pattern: {exc}", schema_path) from exc
        elif key == "additionalProperties" and not isinstance(value, (bool, dict)):
            raise SchemaValidationError(
                "additionalProperties must be a boolean or schema", schema_path
            )

    if "properties" in schema and isinstance(schema["properties"], dict):
        for prop_name, prop_schema in schema["properties"].items():
            assert_supported_schema(
                prop_schema,
                _schema_pointer(schema_path, f"/properties/{prop_name}"),
            )
    if "items" in schema and isinstance(schema["items"], dict):
        assert_supported_schema(schema["items"], _schema_pointer(schema_path, "/items"))
    if isinstance(schema.get("additionalProperties"), dict):
        assert_supported_schema(
            schema["additionalProperties"],
            _schema_pointer(schema_path, "/additionalProperties"),
        )


def _instance_matches_type(instance: Any, type_name: str) -> bool:
    if type_name == "null":
        return instance is None
    if type_name == "boolean":
        return isinstance(instance, bool)
    if type_name == "integer":
        return isinstance(instance, int) and not isinstance(instance, bool)
    if type_name == "number":
        return (isinstance(instance, int) and not isinstance(instance, bool)) or isinstance(
            instance, float
        )
    if type_name == "string":
        return isinstance(instance, str)
    if type_name == "array":
        return isinstance(instance, list)
    if type_name == "object":
        return isinstance(instance, dict)
    return False


def _allowed_types(schema: dict[str, Any]) -> list[str] | None:
    type_value = schema.get("type")
    if type_value is None:
        return None
    if isinstance(type_value, str):
        return [type_value]
    return list(type_value)


def validate_instance(instance: Any, schema: dict[str, Any], json_path: str = "$") -> None:
    assert_supported_schema(schema, json_path)

    allowed = _allowed_types(schema)
    if allowed is not None and not any(_instance_matches_type(instance, name) for name in allowed):
        expected = "|".join(allowed)
        raise SchemaValidationError(f"expected type {expected}", json_path)

    if "enum" in schema and instance not in schema["enum"]:
        raise SchemaValidationError("value is not in enum", json_path)

    if isinstance(instance, (int, float)) and not isinstance(instance, bool):
        if "minimum" in schema and instance < schema["minimum"]:
            raise SchemaValidationError("value is below minimum", json_path)
        if "maximum" in schema and instance > schema["maximum"]:
            raise SchemaValidationError("value is above maximum", json_path)

    if isinstance(instance, str):
        if "minLength" in schema and len(instance) < schema["minLength"]:
            raise SchemaValidationError("string is too short", json_path)
        if "maxLength" in schema and len(instance) > schema["maxLength"]:
            raise SchemaValidationError("string is too long", json_path)
        if "pattern" in schema and re.fullmatch(schema["pattern"], instance) is None:
            raise SchemaValidationError("value does not match pattern", json_path)

    if isinstance(instance, list):
        if "minItems" in schema and len(instance) < schema["minItems"]:
            raise SchemaValidationError("array has too few items", json_path)
        if "maxItems" in schema and len(instance) > schema["maxItems"]:
            raise SchemaValidationError("array has too many items", json_path)
        if "items" in schema:
            item_schema = schema["items"]
            for index, item in enumerate(instance):
                validate_instance(item, item_schema, f"{json_path}/{index}")

    if isinstance(instance, dict):
        required = schema.get("required", [])
        for key in required:
            if key not in instance:
                raise SchemaValidationError(f"missing required property {key!r}", json_path)

        properties = schema.get("properties", {})
        additional = schema.get("additionalProperties", True)
        for key, value in instance.items():
            child_path = f"{json_path}/{key}"
            if key in properties:
                validate_instance(value, properties[key], child_path)
            elif additional is False:
                raise SchemaValidationError(f"additional property not allowed: {key!r}", child_path)
            elif isinstance(additional, dict):
                validate_instance(value, additional, child_path)


def validate_json_text(instance_text: str, schema: dict[str, Any]) -> None:
    try:
        instance = json.loads(instance_text)
    except json.JSONDecodeError as exc:
        raise SchemaValidationError(f"artifact is not valid JSON: {exc}", "$") from exc
    validate_instance(instance, schema, "$")


def extract_json_object_text(text: str) -> str:
    """Extract a JSON object from agent output text."""
    import re

    blocks = re.findall(r"```(?:json)?\s*\n([\s\S]*?)\n```", text, flags=re.IGNORECASE)
    for block in reversed(blocks):
        candidate = block.strip()
        if not candidate:
            continue
        try:
            parsed = json.loads(candidate)
        except json.JSONDecodeError:
            continue
        if isinstance(parsed, dict):
            return candidate

    start = text.rfind("{")
    decoder = json.JSONDecoder()
    while start >= 0:
        try:
            parsed, end = decoder.raw_decode(text, start)
        except json.JSONDecodeError:
            start = text.rfind("{", 0, start)
            continue
        if isinstance(parsed, dict):
            return text[start:end]
        start = text.rfind("{", 0, start)

    raise ValueError("no JSON object found in agent output")


def validate_final_output(
    schema_path: str,
    *,
    text: str = "",
    artifact_paths: list[str] | None = None,
) -> None:
    schema = load_schema_document(schema_path)
    assert_supported_schema(schema, "$")
    artifact_paths = artifact_paths or []
    errors: list[str] = []

    for artifact_path in artifact_paths:
        if not artifact_path:
            continue
        try:
            with open(artifact_path, encoding="utf-8") as handle:
                artifact_text = handle.read()
            if not artifact_text.strip():
                errors.append(f"artifact is empty: {artifact_path}")
                continue
            validate_json_text(artifact_text, schema)
            return
        except (OSError, ValueError, SchemaValidationError, UnsupportedSchemaKeywordError) as exc:
            errors.append(f"{artifact_path}: {exc}")

    if text.strip():
        try:
            extracted = extract_json_object_text(text)
            validate_json_text(extracted, schema)
            return
        except (ValueError, SchemaValidationError, UnsupportedSchemaKeywordError) as exc:
            errors.append(f"agent output: {exc}")

    if errors:
        raise ValueError("; ".join(errors))
    raise ValueError("no structured final output found to validate")


def resolve_schema_file(
    workspace: str,
    schema_path: str,
    *,
    artifact_ns: str = "",
    plan_key: str = "",
    stage_id: str = "",
) -> str:
    validate_portable_path("schema path", schema_path)
    expanded = expand_artifact_tokens(
        schema_path,
        artifact_ns=artifact_ns,
        plan_key=plan_key,
        stage_id=stage_id,
    )
    return resolve_project_path(workspace, expanded)


def iter_orchestration_final_output_schema_entries(
    orchestration: dict[str, Any],
) -> list[tuple[str, str]]:
    entries: list[tuple[str, str]] = []
    for stage in orchestration.get("stages", []):
        if not isinstance(stage, dict):
            continue
        stage_id = str(stage.get("id", "") or "")
        schema = stage.get("finalOutputSchema")
        if schema is None:
            continue
        if not isinstance(schema, str) or not schema.strip():
            raise ValueError(
                f"stage {stage_id or '?'} finalOutputSchema: must be a non-empty string"
            )
        entries.append((stage_id, schema))
    return entries


def iter_orchestration_schema_entries(
    orchestration: dict[str, Any],
) -> list[tuple[str, str, str, str]]:
    entries: list[tuple[str, str, str, str]] = []
    for stage in orchestration.get("stages", []):
        if not isinstance(stage, dict):
            continue
        stage_id = str(stage.get("id", "") or "")
        for field in ARTIFACT_LIST_FIELDS:
            for index, item in enumerate(stage.get(field, []) or []):
                if not isinstance(item, dict):
                    continue
                schema = item.get("schema")
                if schema is None:
                    continue
                if not isinstance(schema, str) or not schema.strip():
                    raise ValueError(
                        f"stage {stage_id or '?'} {field}[{index}].schema: must be a non-empty string"
                    )
                path = str(item.get("path", "") or "")
                entries.append((stage_id, field, path, schema))
    return entries


def validate_orchestration_schema_paths(
    workspace: str,
    orchestration: dict[str, Any],
    *,
    artifact_ns: str = "",
    plan_key: str = "",
) -> None:
    plan_key = plan_key or artifact_ns
    for stage_id, field, _artifact_path, schema_path in iter_orchestration_schema_entries(
        orchestration
    ):
        context = f"stage {stage_id} {field} schema"
        try:
            validate_portable_path(context, schema_path)
            resolved = resolve_schema_file(
                workspace,
                schema_path,
                artifact_ns=artifact_ns,
                plan_key=plan_key,
                stage_id=stage_id,
            )
        except ValueError as exc:
            raise ValueError(f"{context}: {exc}") from exc
        if not os.path.isfile(resolved):
            raise ValueError(f"{context}: schema file not found: {schema_path}")
        load_schema_document(resolved)

    for stage_id, schema_path in iter_orchestration_final_output_schema_entries(orchestration):
        context = f"stage {stage_id} finalOutputSchema"
        try:
            validate_portable_path(context, schema_path)
            resolved = resolve_schema_file(
                workspace,
                schema_path,
                artifact_ns=artifact_ns,
                plan_key=plan_key,
                stage_id=stage_id,
            )
        except ValueError as exc:
            raise ValueError(f"{context}: {exc}") from exc
        if not os.path.isfile(resolved):
            raise ValueError(f"{context}: schema file not found: {schema_path}")
        load_schema_document(resolved)


def collect_produced_schema_entries(stage: dict[str, Any]) -> list[dict[str, str]]:
    produced: list[dict[str, str]] = []
    seen: set[str] = set()
    for field in ("artifacts", "outputArtifacts"):
        for item in stage.get(field, []) or []:
            if not isinstance(item, dict):
                continue
            schema = item.get("schema")
            if schema is None:
                continue
            path = str(item.get("path", "") or "")
            if not path:
                continue
            key = f"{field}:{path}"
            if key in seen:
                continue
            seen.add(key)
            produced.append(
                {
                    "artifact_path": path,
                    "schema_path": str(schema),
                }
            )
    return produced


def verify_stage_artifact_schemas(
    workspace: str,
    stage: dict[str, Any],
    *,
    stage_id: str,
    artifact_ns: str = "",
    plan_key: str = "",
) -> None:
    plan_key = plan_key or artifact_ns
    for entry in collect_produced_schema_entries(stage):
        artifact_rel = expand_artifact_tokens(
            entry["artifact_path"],
            artifact_ns=artifact_ns,
            plan_key=plan_key,
            stage_id=stage_id,
        )
        schema_rel = entry["schema_path"]
        schema_abs = resolve_schema_file(
            workspace,
            schema_rel,
            artifact_ns=artifact_ns,
            plan_key=plan_key,
            stage_id=stage_id,
        )
        artifact_abs = resolve_project_path(workspace, artifact_rel)
        if not os.path.isfile(artifact_abs):
            raise ValueError(
                f"stage={stage_id} artifact={artifact_rel} schema={schema_rel}: artifact file missing"
            )
        if os.path.getsize(artifact_abs) == 0:
            raise ValueError(
                f"stage={stage_id} artifact={artifact_rel} schema={schema_rel}: artifact file is empty"
            )
        schema_doc = load_schema_document(schema_abs)
        with open(artifact_abs, encoding="utf-8") as handle:
            artifact_text = handle.read()
        try:
            validate_json_text(artifact_text, schema_doc)
        except SchemaValidationError as exc:
            raise ValueError(
                "stage={stage} artifact={artifact} schema={schema} location={location}: {message}".format(
                    stage=stage_id,
                    artifact=artifact_rel,
                    schema=schema_rel,
                    location=exc.json_path,
                    message=exc.message,
                )
            ) from exc
        except UnsupportedSchemaKeywordError as exc:
            raise ValueError(
                "stage={stage} artifact={artifact} schema={schema} location={location}: {message}".format(
                    stage=stage_id,
                    artifact=artifact_rel,
                    schema=schema_rel,
                    location=exc.schema_path,
                    message=str(exc),
                )
            ) from exc


def artifact_name_from_path(path: str) -> str:
    """Derive the agent-facing artifact handle from its path.

    The filename stem, minus a trailing ".schema"-style suffix chain, e.g.
    ".ralph-workspace/artifacts/ns/trade-intents.json" -> "trade-intents".
    """
    base = os.path.basename(path)
    stem = base.split(".", 1)[0] if "." in base else base
    return stem


def resolve_artifact_abs_path(rel_path: str, *, workspace: str, state_root: str) -> str:
    """Absolute location of a workspace-relative artifact path.

    Mirrors verify_step_artifacts: paths under .ralph-workspace/ resolve against
    the plan state root when one is configured, everything else against the
    workspace. Resolution happens here, once, because the orchestrator and the
    MCP server disagree about what RALPH_PLAN_WORKSPACE_ROOT means -- the
    contract carries the answer so neither has to guess.
    """
    if os.path.isabs(rel_path):
        return rel_path
    if state_root and rel_path.startswith(".ralph-workspace/"):
        return os.path.join(state_root.rstrip("/"), rel_path[len(".ralph-workspace/"):])
    return os.path.join(workspace.rstrip("/"), rel_path)


def _contract_entry(
    item: dict[str, Any],
    *,
    artifact_ns: str,
    plan_key: str,
    stage_id: str,
    workspace: str = "",
    state_root: str = "",
) -> dict[str, Any] | None:
    raw_path = str(item.get("path", "") or "")
    if not raw_path:
        return None
    expanded = expand_artifact_tokens(
        raw_path,
        artifact_ns=artifact_ns,
        plan_key=plan_key,
        stage_id=stage_id,
    )
    name = str(item.get("name", "") or "") or artifact_name_from_path(expanded)
    entry: dict[str, Any] = {
        "name": name,
        "path": expanded,
        "required": bool(item.get("required", True)),
        "format": "json" if expanded.endswith(".json") else "text",
    }
    schema = str(item.get("schema", "") or "")
    if schema:
        entry["schema"] = schema
    if workspace:
        entry["resolvedPath"] = resolve_artifact_abs_path(
            expanded, workspace=workspace, state_root=state_root
        )
    return entry


def build_stage_contract(
    stage: dict[str, Any],
    *,
    stage_id: str,
    artifact_ns: str = "",
    plan_key: str = "",
    workspace: str = "",
    state_root: str = "",
) -> dict[str, Any]:
    """Build the agent-facing artifact contract for one stage.

    Paths are emitted already expanded, so no {{TOKEN}} ever reaches an
    agent-facing surface. Names must be unique within each direction; a
    collision is a workflow-authoring error and is reported as such, since the
    agent addresses artifacts by name alone.
    """
    plan_key = plan_key or artifact_ns

    def collect(fields: tuple[str, ...], direction: str) -> list[dict[str, Any]]:
        entries: list[dict[str, Any]] = []
        seen_paths: set[str] = set()
        seen_names: dict[str, str] = {}
        for field in fields:
            for item in stage.get(field, []) or []:
                if not isinstance(item, dict):
                    continue
                entry = _contract_entry(
                    item,
                    artifact_ns=artifact_ns,
                    plan_key=plan_key,
                    stage_id=stage_id,
                    workspace=workspace,
                    state_root=state_root,
                )
                if entry is None or entry["path"] in seen_paths:
                    continue
                prior = seen_names.get(entry["name"])
                if prior is not None and prior != entry["path"]:
                    raise ValueError(
                        f"stage {stage_id} {direction}: duplicate artifact name "
                        f"{entry['name']!r} for {prior} and {entry['path']}; "
                        f"add an explicit `name:` to one of them"
                    )
                seen_paths.add(entry["path"])
                seen_names[entry["name"]] = entry["path"]
                entries.append(entry)
        return entries

    return {
        "stageId": stage_id,
        "artifactNs": artifact_ns,
        "produces": collect(("artifacts", "outputArtifacts"), "produces"),
        "requires": collect(("inputArtifacts",), "requires"),
    }


def validate_artifact_text(artifact_text: str, schema_abs: str) -> None:
    """Validate candidate artifact text against a schema document on disk.

    Raises ValueError with a location-tagged message. Used by the MCP artifact
    write path to reject bad content *before* it reaches the artifact
    directory, and by the validate-artifact CLI subcommand.
    """
    if not artifact_text.strip():
        raise ValueError("artifact content is empty")
    schema_doc = load_schema_document(schema_abs)
    try:
        assert_supported_schema(schema_doc, "$")
        validate_json_text(artifact_text, schema_doc)
    except SchemaValidationError as exc:
        raise ValueError(f"location={exc.json_path}: {exc.message}") from exc
    except UnsupportedSchemaKeywordError as exc:
        raise ValueError(f"location={exc.schema_path}: {exc}") from exc


def _cmd_validate_orch_paths(args: argparse.Namespace) -> int:
    with open(args.orchestration, encoding="utf-8") as handle:
        orchestration = json.load(handle)
    artifact_ns = args.artifact_ns
    if not artifact_ns:
        artifact_ns = str(orchestration.get("namespace", "") or "")
    plan_key = args.plan_key or artifact_ns
    try:
        validate_orchestration_schema_paths(
            args.workspace,
            orchestration,
            artifact_ns=artifact_ns,
            plan_key=plan_key,
        )
    except ValueError as exc:
        print(f"Orchestration schema validation failed: {exc}", file=sys.stderr)
        return 1
    return 0


def _cmd_verify_stage(args: argparse.Namespace) -> int:
    stage = json.loads(args.stage_json)
    stage_id = args.stage_id or str(stage.get("id", "") or "")
    artifact_ns = args.artifact_ns
    plan_key = args.plan_key or artifact_ns
    try:
        verify_stage_artifact_schemas(
            args.workspace,
            stage,
            stage_id=stage_id,
            artifact_ns=artifact_ns,
            plan_key=plan_key,
        )
    except ValueError as exc:
        print(str(exc), file=sys.stderr)
        return 1
    return 0


def _cmd_validate_final_output(args: argparse.Namespace) -> int:
    artifact_paths = list(args.artifact or [])
    try:
        validate_final_output(
            args.schema,
            text=args.text or "",
            artifact_paths=artifact_paths,
        )
    except ValueError as exc:
        print(str(exc), file=sys.stderr)
        return 1
    return 0


def _cmd_validate_artifact(args: argparse.Namespace) -> int:
    try:
        if args.file == "-":
            artifact_text = sys.stdin.read()
        else:
            with open(args.file, encoding="utf-8") as handle:
                artifact_text = handle.read()
    except OSError as exc:
        print(f"cannot read artifact: {exc}", file=sys.stderr)
        return 1
    try:
        validate_artifact_text(artifact_text, args.schema)
    except (OSError, ValueError) as exc:
        print(str(exc), file=sys.stderr)
        return 1
    return 0


def _cmd_stage_contract(args: argparse.Namespace) -> int:
    try:
        stage = json.loads(args.stage_json)
    except json.JSONDecodeError as exc:
        print(f"stage JSON is not valid: {exc}", file=sys.stderr)
        return 1
    stage_id = args.stage_id or str(stage.get("id", "") or "")
    plan_key = args.plan_key or args.artifact_ns
    try:
        contract = build_stage_contract(
            stage,
            stage_id=stage_id,
            artifact_ns=args.artifact_ns,
            plan_key=plan_key,
            workspace=args.workspace,
            state_root=args.state_root,
        )
    except ValueError as exc:
        print(str(exc), file=sys.stderr)
        return 1
    payload = json.dumps(contract, indent=2, sort_keys=False) + "\n"
    if args.out and args.out != "-":
        out_dir = os.path.dirname(args.out)
        if out_dir:
            os.makedirs(out_dir, exist_ok=True)
        with open(args.out, "w", encoding="utf-8") as handle:
            handle.write(payload)
    else:
        sys.stdout.write(payload)
    return 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Ralph artifact JSON schema tools")
    subparsers = parser.add_subparsers(dest="command", required=True)

    orch_paths = subparsers.add_parser(
        "validate-orch-paths",
        help="Validate schema path safety and existence for an orchestration file",
    )
    orch_paths.add_argument("--workspace", required=True)
    orch_paths.add_argument("--orchestration", required=True)
    orch_paths.add_argument("--artifact-ns", default="")
    orch_paths.add_argument("--plan-key", default="")
    orch_paths.set_defaults(func=_cmd_validate_orch_paths)

    verify_stage = subparsers.add_parser(
        "verify-stage",
        help="Validate produced artifacts for one orchestration stage",
    )
    verify_stage.add_argument("--workspace", required=True)
    verify_stage.add_argument("--stage-json", required=True)
    verify_stage.add_argument("--stage-id", default="")
    verify_stage.add_argument("--artifact-ns", default="")
    verify_stage.add_argument("--plan-key", default="")
    verify_stage.set_defaults(func=_cmd_verify_stage)

    validate_final = subparsers.add_parser(
        "validate-final-output",
        help="Validate structured final output from agent text and/or JSON artifacts",
    )
    validate_final.add_argument("--schema", required=True)
    validate_final.add_argument("--text", default="")
    validate_final.add_argument("--artifact", action="append", default=[])
    validate_final.set_defaults(func=_cmd_validate_final_output)

    validate_artifact = subparsers.add_parser(
        "validate-artifact",
        help="Validate one JSON artifact (file or stdin) against a schema",
    )
    validate_artifact.add_argument("--schema", required=True)
    validate_artifact.add_argument(
        "--file",
        required=True,
        help='Artifact file path, or "-" to read candidate content from stdin.',
    )
    validate_artifact.set_defaults(func=_cmd_validate_artifact)

    stage_contract = subparsers.add_parser(
        "stage-contract",
        help="Emit the agent-facing artifact contract for one orchestration stage",
    )
    stage_contract.add_argument("--stage-json", required=True)
    stage_contract.add_argument("--stage-id", default="")
    stage_contract.add_argument("--artifact-ns", default="")
    stage_contract.add_argument("--plan-key", default="")
    stage_contract.add_argument(
        "--workspace",
        default="",
        help="Workspace root; when given, each entry carries a resolvedPath.",
    )
    stage_contract.add_argument(
        "--state-root",
        default="",
        help="Absolute path that .ralph-workspace/ resolves to, when not <workspace>/.ralph-workspace.",
    )
    stage_contract.add_argument(
        "--out",
        default="-",
        help='Destination file, or "-" for stdout.',
    )
    stage_contract.set_defaults(func=_cmd_stage_contract)

    args = parser.parse_args(argv)
    return int(args.func(args))


if __name__ == "__main__":
    raise SystemExit(main())
