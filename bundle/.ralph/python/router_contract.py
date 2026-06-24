#!/usr/bin/env python3
"""Router decision contract parsing and orchestration reachability validation."""

from __future__ import annotations

import argparse
import json
import os
import sys
from typing import Any

_MODULE_DIR = os.path.dirname(os.path.abspath(__file__))
_DEFAULT_SCHEMA = os.path.normpath(
    os.path.join(_MODULE_DIR, "..", "schemas", "router-decision.schema.json")
)

try:
    import artifact_json_schema as _ajs
except ModuleNotFoundError:  # pragma: no cover
    sys.path.insert(0, _MODULE_DIR)
    import artifact_json_schema as _ajs


class RouterContractError(Exception):
    """Raised when a router artifact or orchestration config is invalid."""


def _read_text(path: str) -> str:
    try:
        with open(path, encoding="utf-8") as handle:
            return handle.read()
    except FileNotFoundError as exc:
        raise RouterContractError(f"router artifact not found: {path}") from exc


def load_decision(artifact_path: str, schema_path: str | None = None) -> dict[str, Any]:
    schema_file = schema_path or _DEFAULT_SCHEMA
    try:
        schema = _ajs.load_schema_document(schema_file)
        _ajs.assert_supported_schema(schema, "$")
    except (ValueError, _ajs.UnsupportedSchemaKeywordError) as exc:
        raise RouterContractError(f"router schema invalid ({schema_file}): {exc}") from exc

    raw = _read_text(artifact_path)
    if not raw.strip():
        raise RouterContractError(f"router artifact is empty: {artifact_path}")

    try:
        _ajs.validate_json_text(raw, schema)
    except _ajs.SchemaValidationError as exc:
        raise RouterContractError(
            f"router artifact does not satisfy contract at {exc.json_path}: {exc}"
        ) from exc

    return json.loads(raw)


def _stage_ids(orchestration: dict[str, Any]) -> list[str]:
    return [str(stage.get("id") or "") for stage in orchestration.get("stages") or []]


def _parallel_waves(orchestration: dict[str, Any]) -> list[list[str]]:
    waves: list[list[str]] = []
    for wave in orchestration.get("parallelStages") or []:
        if not isinstance(wave, str):
            continue
        parts = [part.strip() for part in wave.split(",") if part.strip()]
        if parts:
            waves.append(parts)
    return waves


def _wave_for_stage(stage_id: str, waves: list[list[str]]) -> list[str] | None:
    for wave in waves:
        if stage_id in wave:
            return wave
    return None


def _router_config(stage: dict[str, Any]) -> dict[str, Any] | None:
    router = stage.get("router")
    if router in (None, False, ""):
        return None
    if not isinstance(router, dict):
        raise RouterContractError("router: must be an object")
    return router


def validate_router_config(stage: dict[str, Any], stage_id: str, stage_index: int, all_ids: list[str]) -> None:
    router = _router_config(stage)
    if router is None:
        return

    prefix = f"stage {stage_id!r} router"
    allowed = router.get("allowedTargets")
    if not isinstance(allowed, list) or not allowed:
        raise RouterContractError(f"{prefix}: allowedTargets must be a non-empty array")
    if any(not isinstance(item, str) or not item.strip() for item in allowed):
        raise RouterContractError(f"{prefix}: allowedTargets entries must be non-empty strings")

    terminal = router.get("terminalOutcomes") or []
    if terminal not in (None, []):
        if not isinstance(terminal, list):
            raise RouterContractError(f"{prefix}: terminalOutcomes must be an array")
        if any(not isinstance(item, str) or not item.strip() for item in terminal):
            raise RouterContractError(f"{prefix}: terminalOutcomes entries must be non-empty strings")

    default_target = router.get("defaultTarget")
    if not isinstance(default_target, str) or not default_target.strip():
        raise RouterContractError(f"{prefix}: defaultTarget must be a non-empty string")

    on_invalid = router.get("onInvalid", "fail")
    if on_invalid not in ("fail", "default"):
        raise RouterContractError(f"{prefix}: onInvalid must be fail or default")

    valid_targets = set(allowed) | set(terminal or [])
    if default_target not in valid_targets:
        raise RouterContractError(f"{prefix}: defaultTarget must appear in allowedTargets or terminalOutcomes")

    overlap = set(allowed) & set(terminal or [])
    if overlap:
        raise RouterContractError(f"{prefix}: allowedTargets and terminalOutcomes must not overlap")

    for target in allowed:
        if target not in all_ids:
            raise RouterContractError(f"{prefix}: unknown stage target {target!r}")
        target_index = all_ids.index(target)
        if target_index <= stage_index:
            raise RouterContractError(
                f"{prefix}: target {target!r} must be a later declared stage (backward routing forbidden)"
            )


def validate_orchestration(orchestration: dict[str, Any]) -> None:
    stages = orchestration.get("stages") or []
    if not isinstance(stages, list):
        raise RouterContractError("stages must be an array")

    all_ids = _stage_ids(orchestration)
    waves = _parallel_waves(orchestration)

    for index, stage in enumerate(stages):
        if not isinstance(stage, dict):
            continue
        stage_id = str(stage.get("id") or "")
        validate_router_config(stage, stage_id, index, all_ids)

        router = _router_config(stage)
        if router is None:
            continue

        for target in router.get("allowedTargets") or []:
            wave = _wave_for_stage(str(target), waves)
            if wave and wave[0] != str(target):
                raise RouterContractError(
                    f"stage {stage_id!r} router: target {target!r} cannot route into the middle of parallel wave {wave!r}"
                )


def resolve_runtime_target(
    decision: dict[str, Any],
    router: dict[str, Any],
    *,
    stage_index: int,
    all_ids: list[str],
    waves: list[list[str]],
) -> tuple[str, str]:
    """Return (resolved_target, resolution_kind) where kind is stage|terminal|default."""
    raw_target = str(decision.get("target") or "").strip()
    allowed = [str(item) for item in router.get("allowedTargets") or []]
    terminal = [str(item) for item in router.get("terminalOutcomes") or []]
    default_target = str(router.get("defaultTarget") or "")
    on_invalid = str(router.get("onInvalid") or "fail")

    def invalid(reason: str) -> tuple[str, str]:
        if on_invalid == "default":
            if default_target in terminal:
                return default_target, "default-terminal"
            return default_target, "default-stage"
        raise RouterContractError(reason)

    if not raw_target:
        return invalid("router decision target is empty")

    if raw_target in terminal:
        return raw_target, "terminal"

    if raw_target not in allowed:
        return invalid(f"router target {raw_target!r} is not in allowedTargets")

    if raw_target not in all_ids:
        return invalid(f"router target {raw_target!r} is not a declared stage id")

    target_index = all_ids.index(raw_target)
    if target_index <= stage_index:
        return invalid(f"router target {raw_target!r} would route backward")

    wave = _wave_for_stage(raw_target, waves)
    if wave and wave[0] != raw_target:
        return invalid(
            f"router target {raw_target!r} would route into the middle of parallel wave {wave!r}"
        )

    return raw_target, "stage"


def render_router_prompt_block(
    *,
    allowed_targets: list[str],
    terminal_outcomes: list[str],
    schema_path: str,
) -> str:
    targets = ", ".join(repr(item) for item in allowed_targets)
    terminals = ", ".join(repr(item) for item in terminal_outcomes) or "(none)"
    return (
        "## Router stage\n\n"
        "Write exactly one JSON object to the declared router artifact path.\n"
        "Do not wrap the JSON in markdown fences.\n\n"
        "Required shape:\n"
        '{"target":"<stage-id-or-terminal-outcome>","reason":"short string","confidence":0.0}\n\n'
        f"- allowedTargets: [{targets}]\n"
        f"- terminalOutcomes: [{terminals}]\n"
        f"- contract schema: {schema_path}\n"
        "- target must be one of the allowed stage ids or terminal outcomes.\n"
        "- confidence must be between 0.0 and 1.0 inclusive.\n"
    )


def _load_json(path: str) -> dict[str, Any]:
    with open(path, encoding="utf-8") as handle:
        data = json.load(handle)
    if not isinstance(data, dict):
        raise RouterContractError(f"expected JSON object in {path}")
    return data


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Ralph router contract tools")
    sub = parser.add_subparsers(dest="command", required=True)

    validate_orch = sub.add_parser("validate-orchestration", help="Validate router reachability")
    validate_orch.add_argument("--orchestration", required=True)

    parse_cmd = sub.add_parser("parse-decision", help="Parse and validate a router artifact")
    parse_cmd.add_argument("--artifact", required=True)
    parse_cmd.add_argument("--schema", default="")

    resolve_cmd = sub.add_parser("resolve-target", help="Resolve a router decision at runtime")
    resolve_cmd.add_argument("--artifact", required=True)
    resolve_cmd.add_argument("--router-json", required=True)
    resolve_cmd.add_argument("--stage-index", type=int, required=True)
    resolve_cmd.add_argument("--stage-ids-json", required=True)
    resolve_cmd.add_argument("--parallel-waves-json", default="[]")
    resolve_cmd.add_argument("--schema", default="")

    prompt_cmd = sub.add_parser("prompt-block", help="Render router prompt instructions")
    prompt_cmd.add_argument("--router-json", required=True)
    prompt_cmd.add_argument("--schema", default=_DEFAULT_SCHEMA)

    args = parser.parse_args(argv)

    try:
        if args.command == "validate-orchestration":
            validate_orchestration(_load_json(args.orchestration))
            return 0

        if args.command == "parse-decision":
            schema = args.schema or None
            decision = load_decision(args.artifact, schema)
            print(json.dumps(decision, sort_keys=True))
            return 0

        if args.command == "resolve-target":
            schema = args.schema or None
            decision = load_decision(args.artifact, schema)
            router = json.loads(args.router_json)
            all_ids = json.loads(args.stage_ids_json)
            waves = json.loads(args.parallel_waves_json)
            target, kind = resolve_runtime_target(
                decision,
                router,
                stage_index=args.stage_index,
                all_ids=all_ids,
                waves=waves,
            )
            print(json.dumps({"target": target, "kind": kind}, sort_keys=True))
            return 0

        if args.command == "prompt-block":
            router = json.loads(args.router_json)
            block = render_router_prompt_block(
                allowed_targets=[str(item) for item in router.get("allowedTargets") or []],
                terminal_outcomes=[str(item) for item in router.get("terminalOutcomes") or []],
                schema_path=args.schema,
            )
            sys.stdout.write(block)
            return 0
    except RouterContractError as exc:
        print(str(exc), file=sys.stderr)
        return 1

    return 1


if __name__ == "__main__":
    raise SystemExit(main())
