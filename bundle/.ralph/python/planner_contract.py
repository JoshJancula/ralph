#!/usr/bin/env python3
"""Bounded dynamic decomposition planner contract parsing and materialization."""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
from typing import Any

_MODULE_DIR = os.path.dirname(os.path.abspath(__file__))
_DEFAULT_SCHEMA = os.path.normpath(
    os.path.join(_MODULE_DIR, "..", "schemas", "planner-output.schema.json")
)

try:
    import artifact_json_schema as _ajs
except ModuleNotFoundError:  # pragma: no cover
    sys.path.insert(0, _MODULE_DIR)
    import artifact_json_schema as _ajs

HARD_MAX_TODOS = 30
HARD_MAX_STAGES = 12
DEFAULT_MAX_TODOS = 15
DEFAULT_MAX_STAGES = 6

VALID_RUNTIMES = frozenset({"cursor", "claude", "codex", "opencode", "antigravity"})
DEFAULT_AGENTS = frozenset(
    {"research", "architect", "implementation", "code-review", "qa", "security"}
)
STAGE_ID_RE = re.compile(r"^[a-z0-9_]+(-[a-z0-9_]+)*$")
GENERATED_SEGMENT = "/generated/"
OPERATOR_PLAN_ROOT = ".ralph-workspace/orchestration-plans/"


class PlannerContractError(Exception):
    """Raised when a planner artifact or orchestration config is invalid."""


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


def _env_int(name: str, default: int, *, minimum: int = 1, maximum: int) -> int:
    raw = os.environ.get(name, "")
    if not raw:
        return default
    try:
        value = int(raw)
    except ValueError as exc:
        raise PlannerContractError(f"{name}: invalid integer {raw!r}") from exc
    if value < minimum:
        raise PlannerContractError(f"{name}: must be >= {minimum}")
    if value > maximum:
        raise PlannerContractError(f"{name}: cannot exceed hard maximum {maximum}")
    return value


def effective_hard_max(kind: str) -> int:
    if kind == "todos":
        return _env_int("RALPH_PLANNER_HARD_MAX_TODOS", HARD_MAX_TODOS, maximum=HARD_MAX_TODOS)
    return _env_int("RALPH_PLANNER_HARD_MAX_STAGES", HARD_MAX_STAGES, maximum=HARD_MAX_STAGES)


def _planner_config(stage: dict[str, Any]) -> dict[str, Any] | None:
    planner = stage.get("planner")
    if planner in (None, False, ""):
        return None
    if not isinstance(planner, dict):
        raise PlannerContractError("planner: must be an object")
    return planner


def _non_empty_string_list(value: Any, field: str) -> list[str]:
    if not isinstance(value, list) or not value:
        raise PlannerContractError(f"planner.{field} must be a non-empty array")
    out: list[str] = []
    for item in value:
        if not isinstance(item, str) or not item.strip():
            raise PlannerContractError(f"planner.{field} entries must be non-empty strings")
        out.append(item.strip())
    return out


def validate_planner_config(stage: dict[str, Any], stage_id: str) -> dict[str, Any]:
    planner = _planner_config(stage)
    if planner is None:
        raise PlannerContractError(f"stage {stage_id!r}: missing planner config")

    prefix = f"stage {stage_id!r} planner"
    output_mode = planner.get("outputMode")
    if output_mode not in ("plan-file", "stages"):
        raise PlannerContractError(f"{prefix}: outputMode must be plan-file or stages")

    hard_todos = effective_hard_max("todos")
    hard_stages = effective_hard_max("stages")

    max_todos = planner.get("maxTodos", DEFAULT_MAX_TODOS)
    max_stages = planner.get("maxStages", DEFAULT_MAX_STAGES)
    for field, value, hard in (
        ("maxTodos", max_todos, hard_todos),
        ("maxStages", max_stages, hard_stages),
    ):
        if not isinstance(value, int) or isinstance(value, bool):
            raise PlannerContractError(f"{prefix}: {field} must be a positive integer")
        if value < 1:
            raise PlannerContractError(f"{prefix}: {field} must be >= 1")
        if value > hard:
            raise PlannerContractError(f"{prefix}: {field} cannot exceed hard maximum {hard}")

    allowed_runtimes = _non_empty_string_list(planner.get("allowedRuntimes"), "allowedRuntimes")
    allowed_agents = _non_empty_string_list(planner.get("allowedAgents"), "allowedAgents")
    allowed_models = _non_empty_string_list(planner.get("allowedModels"), "allowedModels")

    unknown_runtimes = sorted(set(allowed_runtimes) - VALID_RUNTIMES)
    if unknown_runtimes:
        raise PlannerContractError(f"{prefix}: unknown allowedRuntimes: {unknown_runtimes}")

    return {
        "outputMode": output_mode,
        "maxTodos": max_todos,
        "maxStages": max_stages,
        "allowedRuntimes": allowed_runtimes,
        "allowedAgents": allowed_agents,
        "allowedModels": allowed_models,
    }


def validate_orchestration(orchestration: dict[str, Any]) -> None:
    stages = orchestration.get("stages") or []
    if not isinstance(stages, list):
        raise PlannerContractError("stages must be an array")

    for stage in stages:
        if not isinstance(stage, dict):
            continue
        if _planner_config(stage) is not None:
            stage_id = str(stage.get("id") or "")
            validate_planner_config(stage, stage_id)


def load_output(artifact_path: str, schema_path: str | None = None) -> dict[str, Any]:
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

    return json.loads(raw)


def _validate_stage_id(stage_id: str, *, context: str) -> None:
    if not STAGE_ID_RE.match(stage_id):
        raise PlannerContractError(f"{context}: invalid id {stage_id!r}")


def _validate_portable_path(path: str, *, context: str) -> None:
    try:
        _ajs.validate_portable_path(context, path)
    except ValueError as exc:
        raise PlannerContractError(str(exc)) from exc


def _generated_plan_dir(plan_key: str) -> str:
    safe_key = plan_key.strip().strip("/")
    if not safe_key:
        raise PlannerContractError("plan key must not be empty")
    _validate_portable_path(safe_key, context="plan key")
    return f"{OPERATOR_PLAN_ROOT}{safe_key}/generated"


def _assert_write_allowed(target_rel: str, *, plan_key: str) -> str:
    _validate_portable_path(target_rel, context="generated output path")
    generated_prefix = _generated_plan_dir(plan_key)
    normalized = target_rel.replace("\\", "/")
    if GENERATED_SEGMENT not in f"/{normalized.lstrip('/')}":
        raise PlannerContractError(
            f"generated output must live under {generated_prefix}: {target_rel}"
        )
    if ".." in normalized.split("/"):
        raise PlannerContractError(f"path traversal is not permitted: {target_rel}")
    return normalized


def validate_output(
    output: dict[str, Any],
    planner: dict[str, Any],
    *,
    known_agents: set[str] | None = None,
    planner_stage_id: str = "",
) -> None:
    items = output.get("items") or []
    if not isinstance(items, list) or not items:
        raise PlannerContractError("planner output items must be a non-empty array")

    output_mode = planner["outputMode"]
    limit = planner["maxStages"] if output_mode == "stages" else planner["maxTodos"]
    hard = effective_hard_max("stages" if output_mode == "stages" else "todos")
    if len(items) > limit:
        raise PlannerContractError(
            f"planner output has {len(items)} items; limit is {limit} for outputMode {output_mode}"
        )
    if len(items) > hard:
        raise PlannerContractError(f"planner output exceeds hard maximum {hard}")

    allowed_runtimes = set(planner["allowedRuntimes"])
    allowed_agents = set(planner["allowedAgents"])
    allowed_models = set(planner["allowedModels"])
    agent_pool = set(known_agents or ()) | DEFAULT_AGENTS

    seen_ids: set[str] = set()
    for index, item in enumerate(items):
        if not isinstance(item, dict):
            raise PlannerContractError(f"planner item[{index}] must be an object")
        item_id = str(item.get("id") or "").strip()
        _validate_stage_id(item_id, context=f"planner item[{index}]")
        if item_id in seen_ids:
            raise PlannerContractError(f"duplicate planner item id: {item_id}")
        seen_ids.add(item_id)

        content = item.get("content")
        if not isinstance(content, str) or not content.strip():
            raise PlannerContractError(f"planner item[{index}] content must be a non-empty string")

        runtime = str(item.get("runtime") or planner.get("defaultRuntime") or "").strip()
        agent = str(item.get("agent") or planner.get("defaultAgent") or "").strip()
        model = str(item.get("model") or "").strip()

        if output_mode == "stages":
            if not runtime:
                raise PlannerContractError(f"planner item[{index}] runtime is required for stages output")
            if not agent:
                raise PlannerContractError(f"planner item[{index}] agent is required for stages output")
            if runtime not in allowed_runtimes:
                raise PlannerContractError(
                    f"planner item[{index}] runtime {runtime!r} is not in allowedRuntimes"
                )
            if agent not in allowed_agents:
                raise PlannerContractError(
                    f"planner item[{index}] agent {agent!r} is not in allowedAgents"
                )
            if agent not in agent_pool:
                raise PlannerContractError(f"planner item[{index}] unknown agent {agent!r}")
            if model and model not in allowed_models:
                raise PlannerContractError(
                    f"planner item[{index}] model {model!r} is not in allowedModels"
                )

    for index, rel in enumerate(output.get("artifactRelationships") or []):
        if not isinstance(rel, dict):
            raise PlannerContractError(f"artifactRelationships[{index}] must be an object")
        for key in ("from", "to"):
            path = str(rel.get(key) or "").strip()
            if not path:
                raise PlannerContractError(f"artifactRelationships[{index}].{key} must be non-empty")
            _validate_portable_path(path, context=f"artifactRelationships[{index}].{key}")

    verification = output.get("verification")
    if not isinstance(verification, str) or not verification.strip():
        raise PlannerContractError("planner output verification must be a non-empty string")

    if planner_stage_id and planner_stage_id in seen_ids:
        raise PlannerContractError("planner output cannot include the planner stage id")


def _render_plan_markdown(output: dict[str, Any], *, title: str) -> str:
    lines = [
        "---",
        f"name: {title}",
        "overview: Generated by Ralph planner stage",
        "---",
        "",
        f"# {title}",
        "",
        output.get("rationale", "").strip(),
        "",
    ]
    for item in output["items"]:
        lines.append(f"- [ ] {str(item.get('content') or '').strip()}")
    verification = str(output.get("verification") or "").strip()
    if verification:
        lines.extend(["", f"verification: |", f"  {verification}"])
    return "\n".join(lines).rstrip() + "\n"


def _build_stage_json(
    item: dict[str, Any],
    *,
    plan_rel: str,
    planner: dict[str, Any],
    namespace: str,
) -> dict[str, Any]:
    stage: dict[str, Any] = {
        "id": str(item["id"]),
        "runtime": str(item["runtime"]),
        "agent": str(item["agent"]),
        "plan": plan_rel,
        "sessionStrategy": "fresh",
        "sessionResume": False,
        "artifacts": [
            {
                "path": f".ralph-workspace/artifacts/{{{{ARTIFACT_NS}}}}/{item['id']}.md",
                "required": True,
            }
        ],
    }
    model = str(item.get("model") or "").strip()
    if model:
        stage["model"] = model
    _ = namespace  # reserved for future artifact namespace hints
    _ = planner
    return stage


def materialize_output(
    output: dict[str, Any],
    planner: dict[str, Any],
    *,
    workspace: str,
    plan_key: str,
    planner_stage_id: str,
    namespace: str = "",
    dry_run: bool = False,
    known_agents: set[str] | None = None,
) -> dict[str, Any]:
    validate_output(
        output,
        planner,
        known_agents=known_agents,
        planner_stage_id=planner_stage_id,
    )

    generated_dir = _generated_plan_dir(plan_key)
    output_mode = planner["outputMode"]
    manifest: dict[str, Any] = {
        "outputMode": output_mode,
        "planKey": plan_key,
        "generatedDir": generated_dir,
        "rationale": output.get("rationale", ""),
        "verification": output.get("verification", ""),
        "artifactRelationships": output.get("artifactRelationships") or [],
        "items": [],
        "stages": [],
        "files": [],
    }

    workspace_abs = os.path.abspath(workspace)

    if output_mode == "plan-file":
        plan_name = f"{planner_stage_id}-decomposition.plan.md"
        plan_rel = f"{generated_dir}/{plan_name}"
        _assert_write_allowed(plan_rel, plan_key=plan_key)
        plan_abs = _ajs.resolve_project_path(workspace_abs, plan_rel)
        if os.path.exists(plan_abs) and not dry_run:
            raise PlannerContractError(
                f"refusing to overwrite existing generated plan: {plan_rel}"
            )
        content = _render_plan_markdown(output, title=f"{planner_stage_id} decomposition")
        manifest["files"].append({"path": plan_rel, "kind": "plan-file"})
        manifest["planFile"] = plan_rel
        if not dry_run:
            os.makedirs(os.path.dirname(plan_abs), exist_ok=True)
            with open(plan_abs, "x", encoding="utf-8") as handle:
                handle.write(content)
        for item in output["items"]:
            manifest["items"].append({"id": item["id"], "content": item.get("content", "")})
        return manifest

    stages: list[dict[str, Any]] = []
    for item in output["items"]:
        plan_name = f"{item['id']}.plan.md"
        plan_rel = f"{generated_dir}/{plan_name}"
        _assert_write_allowed(plan_rel, plan_key=plan_key)
        plan_abs = _ajs.resolve_project_path(workspace_abs, plan_rel)
        if os.path.exists(plan_abs) and not dry_run:
            raise PlannerContractError(
                f"refusing to overwrite existing generated plan: {plan_rel}"
            )
        stage_plan = _render_plan_markdown(
            {
                "rationale": output.get("rationale", ""),
                "items": [item],
                "verification": output.get("verification", ""),
            },
            title=str(item["id"]),
        )
        stage = _build_stage_json(
            item,
            plan_rel=plan_rel,
            planner=planner,
            namespace=namespace,
        )
        if stage.get("planner"):
            raise PlannerContractError("recursive planner stages are forbidden")
        if stage.get("parallelStages"):
            raise PlannerContractError("nested parallel waves are not supported")
        stages.append(stage)
        manifest["files"].append({"path": plan_rel, "kind": "stage-plan", "stageId": item["id"]})
        if not dry_run:
            os.makedirs(os.path.dirname(plan_abs), exist_ok=True)
            with open(plan_abs, "x", encoding="utf-8") as handle:
                handle.write(stage_plan)
        manifest["items"].append(
            {
                "id": item["id"],
                "runtime": item.get("runtime"),
                "agent": item.get("agent"),
                "model": item.get("model", ""),
            }
        )

    manifest["stages"] = stages
    return manifest


def render_planner_prompt_block(
    *,
    planner: dict[str, Any],
    schema_path: str,
    plan_key: str,
) -> str:
    generated_dir = _generated_plan_dir(plan_key)
    return (
        "## Planner stage\n\n"
        "Write exactly one JSON object to the declared planner artifact path.\n"
        "Do not wrap the JSON in markdown fences.\n\n"
        "Required shape:\n"
        '{"rationale":"...","items":[{"id":"worker-1","content":"...","runtime":"cursor","agent":"implementation"}],"artifactRelationships":[],"verification":"..."}\n\n'
        f"- outputMode: {planner['outputMode']}\n"
        f"- maxTodos: {planner['maxTodos']}\n"
        f"- maxStages: {planner['maxStages']}\n"
        f"- allowedRuntimes: {json.dumps(planner['allowedRuntimes'])}\n"
        f"- allowedAgents: {json.dumps(planner['allowedAgents'])}\n"
        f"- allowedModels: {json.dumps(planner['allowedModels'])}\n"
        f"- generated output directory: {generated_dir}\n"
        f"- contract schema: {schema_path}\n"
        "- item ids must be lowercase-hyphen stage ids.\n"
        "- do not emit planner stages, parallel waves, or paths outside the generated directory.\n"
    )


def format_dry_run_summary(manifest: dict[str, Any]) -> str:
    lines = [
        "Planner decomposition:",
        f"  outputMode: {manifest.get('outputMode')}",
        f"  items: {len(manifest.get('items') or [])}",
    ]
    if manifest.get("planFile"):
        lines.append(f"  planFile: {manifest['planFile']}")
    for item in manifest.get("items") or []:
        if manifest.get("outputMode") == "stages":
            lines.append(
                "  - {id}: runtime={runtime} agent={agent} model={model}".format(
                    id=item.get("id"),
                    runtime=item.get("runtime"),
                    agent=item.get("agent"),
                    model=item.get("model") or "(default)",
                )
            )
        else:
            lines.append(f"  - {item.get('id')}: {item.get('content', '')[:80]}")
    verification = str(manifest.get("verification") or "").strip()
    if verification:
        lines.append(f"  verification: {verification[:120]}")
    return "\n".join(lines)


def discover_agents(workspace: str) -> set[str]:
    agents: set[str] = set(DEFAULT_AGENTS)
    for root_name in (".ralph/agents", ".cursor/agents", ".claude/agents"):
        root = os.path.join(workspace, root_name)
        if not os.path.isdir(root):
            continue
        for entry in os.listdir(root):
            if entry.startswith("."):
                continue
            path = os.path.join(root, entry)
            if os.path.isfile(path) and entry.endswith(".md"):
                agents.add(entry[:-3])
            elif os.path.isdir(path):
                agents.add(entry)
    return agents


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Ralph planner contract tools")
    sub = parser.add_subparsers(dest="command", required=True)

    validate_orch = sub.add_parser("validate-orchestration", help="Validate planner stage config")
    validate_orch.add_argument("--orchestration", required=True)

    parse_cmd = sub.add_parser("parse-output", help="Parse and validate a planner artifact")
    parse_cmd.add_argument("--artifact", required=True)
    parse_cmd.add_argument("--planner-json", required=True)
    parse_cmd.add_argument("--planner-stage-id", default="")
    parse_cmd.add_argument("--workspace", default="")
    parse_cmd.add_argument("--schema", default="")

    apply_cmd = sub.add_parser("apply-output", help="Validate and materialize planner output")
    apply_cmd.add_argument("--artifact", required=True)
    apply_cmd.add_argument("--planner-json", required=True)
    apply_cmd.add_argument("--workspace", required=True)
    apply_cmd.add_argument("--plan-key", required=True)
    apply_cmd.add_argument("--planner-stage-id", required=True)
    apply_cmd.add_argument("--namespace", default="")
    apply_cmd.add_argument("--dry-run", action="store_true")
    apply_cmd.add_argument("--schema", default="")

    prompt_cmd = sub.add_parser("prompt-block", help="Render planner prompt instructions")
    prompt_cmd.add_argument("--planner-json", required=True)
    prompt_cmd.add_argument("--plan-key", required=True)
    prompt_cmd.add_argument("--schema", default=_DEFAULT_SCHEMA)

    args = parser.parse_args(argv)

    try:
        if args.command == "validate-orchestration":
            validate_orchestration(_load_json(args.orchestration))
            return 0

        planner = json.loads(args.planner_json)

        if args.command == "parse-output":
            schema = args.schema or None
            output = load_output(args.artifact, schema)
            known = discover_agents(args.workspace) if args.workspace else None
            validate_output(
                output,
                planner,
                known_agents=known,
                planner_stage_id=args.planner_stage_id,
            )
            print(json.dumps(output, sort_keys=True))
            return 0

        if args.command == "apply-output":
            schema = args.schema or None
            output = load_output(args.artifact, schema)
            known = discover_agents(args.workspace)
            manifest = materialize_output(
                output,
                planner,
                workspace=args.workspace,
                plan_key=args.plan_key,
                planner_stage_id=args.planner_stage_id,
                namespace=args.namespace,
                dry_run=args.dry_run,
                known_agents=known,
            )
            print(json.dumps(manifest, sort_keys=True))
            return 0

        if args.command == "prompt-block":
            block = render_planner_prompt_block(
                planner=planner,
                schema_path=args.schema,
                plan_key=args.plan_key,
            )
            sys.stdout.write(block)
            return 0
    except PlannerContractError as exc:
        print(str(exc), file=sys.stderr)
        return 1

    return 1


if __name__ == "__main__":
    raise SystemExit(main())
