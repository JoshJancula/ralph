#!/usr/bin/env python3
"""Helpers for ralph create workflow template discovery, seeding, and writes."""

from __future__ import annotations

import copy
import json
import sys
from pathlib import Path
from typing import Any


ALLOWED_MATERIALIZE_RUNTIMES = frozenset(
    {"cursor", "claude", "codex", "opencode", "antigravity"}
)
SUPERVISOR_STAGE_TYPES = frozenset(
    {"integrate", "join", "gate", "checkpoint", "router", "approval"}
)


def _fail(message: str) -> None:
    print(f"Error: {message}", file=sys.stderr)
    raise SystemExit(1)


class WorkflowMaterializeError(ValueError):
    """Invalid fallback routing inputs for workflow materialization."""


def _as_text(value: Any) -> str:
    if value is None:
        return ""
    if isinstance(value, bool):
        return "true" if value else "false"
    if isinstance(value, (int, float)):
        return str(value)
    return str(value).strip() if isinstance(value, str) else str(value).strip()


def _normalize_runtime(raw: str, field: str) -> str:
    text = _as_text(raw)
    if not text:
        return ""
    if text not in ALLOWED_MATERIALIZE_RUNTIMES:
        raise WorkflowMaterializeError(
            f"{field}: unsupported runtime {raw!r}; "
            "expected cursor|claude|codex|opencode|antigravity"
        )
    return text


def capture_run_entry_metadata(frontmatter: dict) -> dict:
    """Record workflow-only header fields before they are stripped on materialize.

    Callers (workflow start / run registry) consume this snapshot. The
    materialized plan itself must not retain kind/mode/engine/defaults/planInput.
    """
    mode = _as_text(frontmatter.get("mode", ""))
    execution = _as_text(frontmatter.get("execution", ""))
    defaults = frontmatter.get("defaults")
    defaults_out: dict[str, str] | None = None
    if isinstance(defaults, dict) and defaults:
        defaults_out = {
            key: _as_text(defaults.get(key, ""))
            for key in ("runtime", "model")
            if _as_text(defaults.get(key, ""))
        }
        if not defaults_out:
            defaults_out = None
    plan_input = None
    if frontmatter.get("_plan_input_present") or frontmatter.get("planInput"):
        raw = frontmatter.get("planInput")
        if isinstance(raw, dict):
            plan_input = {
                "stage": _as_text(raw.get("stage", "")),
                "required": bool(raw.get("required", False)),
            }
    return {
        "kind": "workflow",
        "mode": mode,
        "execution": execution,
        "defaults": defaults_out,
        "planInput": plan_input,
    }


def _stage_is_supervisor(stage: dict) -> bool:
    return _as_text(stage.get("type", "")) in SUPERVISOR_STAGE_TYPES


def _resolve_stage_runtime_model(
    stage: dict,
    *,
    fallback_runtime: str,
    fallback_model: str,
    workflow_runtime: str,
    workflow_model: str,
    provided_plan_runtime: str,
    provided_plan_model: str,
    plan_input_consumer: bool,
    override_runtime: str = "",
    override_model: str = "",
) -> tuple[str, str]:
    """Resolve concrete stage runtime/model for materialization (no TODO layer).

    Order: stage > per-stage override > invocation fallback >
    provided-plan (consumer only) > workflow.
    Empty fallback_model means skipped model (leave absent unless stage/workflow
    /provided supplies one that pairs with the effective runtime).
    """
    stage_runtime = _as_text(stage.get("runtime", ""))
    stage_model = _as_text(stage.get("model", ""))

    if not stage_runtime and override_runtime:
        # Per-stage interactive selection for this run. It fills an unresolved
        # stage only; an authored stage runtime still wins.
        return override_runtime, (stage_model or override_model)

    if stage_runtime:
        eff_rt = stage_runtime
        # Explicit stage runtime: keep stage model; do not inject unpaired fallback.
        if stage_model:
            return eff_rt, stage_model
        # Runtime-only stage: no model written (saved/native resolved at invoke).
        return eff_rt, ""

    # Unresolved stage runtime: apply fallback chain.
    if fallback_runtime:
        eff_rt = fallback_runtime
        eff_from = "invocation"
    elif plan_input_consumer and provided_plan_runtime:
        eff_rt = provided_plan_runtime
        eff_from = "provided-plan"
    elif workflow_runtime:
        eff_rt = workflow_runtime
        eff_from = "workflow"
    else:
        return "", stage_model  # still unresolved; caller may leave as-is

    if stage_model:
        return eff_rt, stage_model

    if fallback_model and fallback_runtime and fallback_runtime == eff_rt:
        return eff_rt, fallback_model
    if (
        plan_input_consumer
        and provided_plan_model
        and (not provided_plan_runtime or provided_plan_runtime == eff_rt)
    ):
        return eff_rt, provided_plan_model
    if workflow_model and workflow_runtime and workflow_runtime == eff_rt:
        return eff_rt, workflow_model
    # Skipped / native model: leave absent.
    _ = eff_from
    return eff_rt, ""


def apply_materialized_stage_routing(
    stages: list,
    *,
    fallback_runtime: str = "",
    fallback_model: str = "",
    workflow_runtime: str = "",
    workflow_model: str = "",
    provided_plan_runtime: str = "",
    provided_plan_model: str = "",
    plan_input_stage: str = "",
    stage_overrides: dict | None = None,
) -> list:
    """Deep-copy stages and materialize selected fallback into unresolved executables.

    Preserves explicit stage routing, planner/planFrom/instructions/approval nodes.
    Never writes provided-plan header into a non-consumer stage. Never mutates
    todos (callers must not pass todos into stage copies). Supervisors receive
    no runtime/model. Empty fallback_model leaves model absent on filled stages.
    """
    fb_rt = _normalize_runtime(fallback_runtime, "fallback_runtime")
    wf_rt = _normalize_runtime(workflow_runtime, "workflow_runtime")
    pp_rt = _normalize_runtime(provided_plan_runtime, "provided_plan_runtime")
    fb_model = _as_text(fallback_model)
    wf_model = _as_text(workflow_model)
    pp_model = _as_text(provided_plan_model)
    plan_input_id = _as_text(plan_input_stage)
    overrides = {}
    for ov_id, ov in (stage_overrides or {}).items():
        ov_rt = _normalize_runtime(_as_text(ov.get("runtime", "")), "stage_runtime.%s" % ov_id)
        ov_model = _as_text(ov.get("model", ""))
        if ov_model and not ov_rt:
            raise WorkflowMaterializeError(
                "stage_model.%s: requires paired stage_runtime.%s" % (ov_id, ov_id)
            )
        overrides[ov_id] = {"runtime": ov_rt, "model": ov_model}

    if fb_model and not fb_rt:
        raise WorkflowMaterializeError(
            "fallback_model: requires paired fallback_runtime"
        )
    if wf_model and not wf_rt:
        raise WorkflowMaterializeError(
            "workflow_model: requires paired workflow_runtime"
        )

    out: list = []
    for stage in stages:
        clone = copy.deepcopy(stage)
        if _stage_is_supervisor(clone):
            # Approval and other supervisors: never inject routing.
            out.append(clone)
            continue
        stage_type = _as_text(clone.get("type", ""))
        if stage_type == "consensus":
            # Voters keep authored explicit runtime/model; no stage-level fill.
            out.append(clone)
            continue
        stage_id = _as_text(clone.get("id", ""))
        is_consumer = bool(plan_input_id) and stage_id == plan_input_id
        eff_rt, eff_model = _resolve_stage_runtime_model(
            clone,
            fallback_runtime=fb_rt,
            fallback_model=fb_model,
            workflow_runtime=wf_rt,
            workflow_model=wf_model,
            provided_plan_runtime=pp_rt,
            provided_plan_model=pp_model,
            plan_input_consumer=is_consumer,
            override_runtime=_as_text(overrides.get(stage_id, {}).get("runtime", "")),
            override_model=_as_text(overrides.get(stage_id, {}).get("model", "")),
        )
        if eff_rt:
            clone["runtime"] = eff_rt
        if eff_model:
            clone["model"] = eff_model
        elif not _as_text(stage.get("model", "")):
            # Skipped model: never invent a model key on unresolved stages.
            clone.pop("model", None)
        out.append(clone)
    return out


def assert_todos_routing_untouched(before: list, after: list) -> None:
    """Refuse materialization that wrote runtime/model into TODO entries."""
    if len(before) != len(after):
        raise WorkflowMaterializeError("todo count changed during materialization")
    for left, right in zip(before, after):
        if _as_text(left.get("runtime", "")) != _as_text(right.get("runtime", "")):
            raise WorkflowMaterializeError(
                "workflow materialization must not write runtime into TODOs"
            )
        if _as_text(left.get("model", "")) != _as_text(right.get("model", "")):
            raise WorkflowMaterializeError(
                "workflow materialization must not write model into TODOs"
            )


def _extract_frontmatter(text: str) -> list[str]:
    lines = text.splitlines()
    if not lines or lines[0].strip() != "---":
        return []
    body: list[str] = []
    for line in lines[1:]:
        if line.strip() == "---":
            break
        body.append(line)
    return body


def _overview_from_frontmatter(fm_lines: list[str]) -> str:
    for line in fm_lines:
        if line.startswith("overview:"):
            return line.split(":", 1)[1].strip()
    return ""


def _split_key_value(text: str) -> tuple[str, str]:
    if ":" not in text:
        return text.strip(), ""
    key, raw = text.split(":", 1)
    return key.strip(), raw.lstrip()


def _parse_scalar(raw: str) -> str:
    value = raw.strip()
    if len(value) >= 2 and value[0] == value[-1] and value[0] in "\"'":
        return value[1:-1]
    return value


def _indent_of(line: str) -> int:
    return len(line) - len(line.lstrip(" "))


def _parse_stage_item(lines: list[str], start: int) -> tuple[str, list[str], int]:
    line = lines[start]
    stage_indent = _indent_of(line)
    stage_id = ""
    depends_on: list[str] = []
    idx = start
    while idx < len(lines):
        current = lines[idx]
        stripped = current.strip()
        if not stripped:
            idx += 1
            continue
        current_indent = _indent_of(current)
        if idx > start and current_indent <= stage_indent:
            break
        key, raw = _split_key_value(stripped.lstrip("- ").strip() if stripped.startswith("- ") else stripped)
        if key == "id":
            stage_id = _parse_scalar(raw)
        elif key == "dependsOn":
            if raw.startswith("["):
                inner = raw.strip()[1:-1]
                depends_on = [item.strip().strip("'\"") for item in inner.split(",") if item.strip()]
            else:
                idx += 1
                while idx < len(lines):
                    dep_line = lines[idx]
                    dep_stripped = dep_line.strip()
                    if not dep_stripped:
                        idx += 1
                        continue
                    if _indent_of(dep_line) <= current_indent:
                        idx -= 1
                        break
                    if dep_stripped.startswith("- "):
                        depends_on.append(_parse_scalar(dep_stripped[2:].strip()))
                    idx += 1
            break
        idx += 1
    return stage_id, depends_on, idx


def _parse_pipeline_seed(fm_lines: list[str]) -> dict:
    seed: dict = {
        "stageIds": [],
        "dependsOn": {},
        "tooling": {},
        "maxParallel": "",
        "maxReworkIterations": "",
        "publishMode": "",
        "mode": "",
        "engine": "",
    }
    section = ""
    in_overrides = False

    idx = 0
    while idx < len(fm_lines):
        line = fm_lines[idx]
        stripped = line.strip()
        if not stripped:
            idx += 1
            continue
        indent = _indent_of(line)
        key, raw = _split_key_value(stripped)

        if indent == 0:
            if key == "mode":
                seed["mode"] = _parse_scalar(raw)
            elif key == "engine":
                seed["engine"] = _parse_scalar(raw)
            elif key == "pipeline":
                section = "pipeline"
            elif key in {"todos", "isProject"}:
                break
            idx += 1
            continue

        if section == "pipeline" and indent == 2:
            in_overrides = False
            if key == "maxParallel":
                seed["maxParallel"] = _parse_scalar(raw)
            elif key == "maxReworkIterations":
                seed["maxReworkIterations"] = _parse_scalar(raw)
            elif key == "publishMode":
                seed["publishMode"] = _parse_scalar(raw)
            elif key == "tooling":
                section = "tooling"
            elif key == "stages":
                section = "stages"
            idx += 1
            continue

        if indent == 2 and key == "stages":
            section = "stages"
            in_overrides = False
            idx += 1
            continue

        if section == "tooling" and indent == 4:
            if key == "defaultProfile":
                seed["tooling"]["defaultProfile"] = _parse_scalar(raw)
            elif key == "overrides":
                in_overrides = True
                seed["tooling"].setdefault("overrides", {})
            idx += 1
            continue

        if section == "tooling" and in_overrides and indent == 6 and raw:
            seed["tooling"].setdefault("overrides", {})[key] = _parse_scalar(raw)
            idx += 1
            continue

        if section == "stages" and stripped.startswith("- ") and indent == 4:
            stage_id, depends_on, idx = _parse_stage_item(fm_lines, idx)
            if stage_id:
                seed["stageIds"].append(stage_id)
                seed["dependsOn"][stage_id] = depends_on
            continue

        idx += 1

    # Prefer public mode; map legacy engine when mode is absent.
    try:
        public_mode, _execution = resolve_workflow_mode(
            mode=seed.get("mode", ""), engine=seed.get("engine", "")
        )
        seed["mode"] = public_mode
    except WorkflowModeError:
        pass
    return seed


# Canonical relative directory under a .ralph root (install/discovery).
BUNDLED_WORKFLOWS_SUBDIR = "workflows"
LEGACY_WORKFLOWS_SUBDIR = "workflow-templates"

# Public authored mode <-> internal execution (orchestration|graph).
WORKFLOW_MODES = ("sequential", "dependency")
MODE_TO_EXECUTION = {
    "sequential": "orchestration",
    "dependency": "graph",
}
EXECUTION_TO_MODE = {
    "orchestration": "sequential",
    "graph": "dependency",
}


class WorkflowModeError(ValueError):
    """Invalid public mode / legacy engine combination for a workflow source."""


def mode_to_execution(mode: str) -> str:
    """Map public mode to internal execution. Raises WorkflowModeError if unknown."""
    key = (mode or "").strip()
    if key not in MODE_TO_EXECUTION:
        raise WorkflowModeError(
            f"invalid mode value {mode!r}; mode must be 'sequential' or 'dependency'"
        )
    return MODE_TO_EXECUTION[key]


def execution_to_mode(execution: str) -> str:
    """Map internal execution / legacy engine to public mode."""
    key = (execution or "").strip()
    if key not in EXECUTION_TO_MODE:
        raise WorkflowModeError(
            f"invalid engine value {execution!r}; "
            "engine must be 'graph' or 'orchestration'"
        )
    return EXECUTION_TO_MODE[key]


def resolve_workflow_mode(mode: str = "", engine: str = "") -> tuple[str, str]:
    """Resolve (public_mode, internal_execution) from authored mode or legacy engine.

    Mutual exclusion: both mode and engine is an error. Unknown mode/engine
    raise WorkflowModeError. Legacy engine-only returns the mapped mode; callers
    that warn on stderr do so separately.
    """
    mode_text = (mode or "").strip()
    engine_text = (engine or "").strip()
    if mode_text and engine_text:
        raise WorkflowModeError(
            "mode and engine must not both be set; use mode: sequential|dependency only"
        )
    if mode_text:
        return mode_text, mode_to_execution(mode_text)
    if engine_text:
        public = execution_to_mode(engine_text)
        return public, engine_text
    raise WorkflowModeError(
        "workflow files require 'mode: sequential' or 'mode: dependency'"
    )


def serialize_workflow_mode(mode: str) -> str:
    """Return a single frontmatter line for public mode; never emits engine."""
    resolved, _execution = resolve_workflow_mode(mode=mode)
    return f"mode: {resolved}"


def normalize_workflow_frontmatter_mode(fm_lines: list[str]) -> list[str]:
    """Rewrite authored workflow frontmatter to emit mode:, never engine:.

    Legacy engine: lines are mapped to mode and dropped. Existing mode is kept
    unless only engine was present. Both mode and engine together raise.
    """
    mode = ""
    engine = ""
    out: list[str] = []
    for line in fm_lines:
        stripped = line.strip()
        if not stripped or _indent_of(line) != 0:
            out.append(line)
            continue
        key, raw = _split_key_value(stripped)
        if key == "mode":
            mode = _parse_scalar(raw)
            continue
        if key == "engine":
            engine = _parse_scalar(raw)
            continue
        out.append(line)
    public_mode, _execution = resolve_workflow_mode(mode=mode, engine=engine)
    # Insert mode after kind when present, else at the top of frontmatter.
    insert_at = 0
    for idx, line in enumerate(out):
        if line.startswith("kind:"):
            insert_at = idx + 1
            break
    out.insert(insert_at, serialize_workflow_mode(public_mode))
    return out


def bundled_workflows_dir(ralph_root: str | Path) -> Path:
    """Return the canonical bundled workflows directory under a .ralph root."""
    return Path(ralph_root) / BUNDLED_WORKFLOWS_SUBDIR


def list_workflows(workflows_dir: str | Path) -> list[dict]:
    """Discover *.workflow.md entries under workflows_dir (sorted by path)."""
    root = Path(workflows_dir)
    entries: list[dict] = []
    if not root.is_dir():
        return entries
    for path in sorted(root.glob("*.workflow.md")):
        text = path.read_text(encoding="utf-8")
        overview = _overview_from_frontmatter(_extract_frontmatter(text))
        workflow_id = path.stem.replace(".workflow", "")
        mode = ""
        engine = ""
        for line in _extract_frontmatter(text):
            if _indent_of(line) != 0:
                continue
            key, raw = _split_key_value(line.strip())
            if key == "mode":
                mode = _parse_scalar(raw)
            elif key == "engine":
                engine = _parse_scalar(raw)
        try:
            public_mode, _execution = resolve_workflow_mode(mode=mode, engine=engine)
        except WorkflowModeError:
            public_mode = mode or ""
        entries.append(
            {
                "id": workflow_id,
                "overview": overview,
                "path": str(path),
                "mode": public_mode,
            }
        )
    return entries


def cmd_list(workflows_dir: str) -> None:
    for entry in list_workflows(workflows_dir):
        print(json.dumps(entry, separators=(",", ":")))


def cmd_seed(template_path: str) -> None:
    path = Path(template_path)
    if not path.is_file():
        _fail(f"template not found: {template_path}")
    text = path.read_text(encoding="utf-8")
    fm_lines = _extract_frontmatter(text)
    if not fm_lines:
        _fail(f"template missing frontmatter: {template_path}")
    seed = _parse_pipeline_seed(fm_lines)
    seed["id"] = path.stem.replace(".workflow", "")
    seed["overview"] = _overview_from_frontmatter(fm_lines)
    seed["path"] = str(path)
    print(json.dumps(seed, separators=(",", ":")))


def _replace_frontmatter_scalar(fm_lines: list[str], key: str, value: str) -> list[str]:
    replaced = False
    out: list[str] = []
    for line in fm_lines:
        if line.startswith(f"{key}:"):
            out.append(f"{key}: {value}")
            replaced = True
        else:
            out.append(line)
    if not replaced:
        out.insert(0, f"{key}: {value}")
    return out


def _patch_tooling(fm_lines: list[str], tooling: dict) -> list[str]:
    if not tooling.get("defaultProfile"):
        return fm_lines
    out: list[str] = []
    idx = 0
    while idx < len(fm_lines):
        line = fm_lines[idx]
        if line.strip() == "tooling:":
            out.append(line)
            out.append(f"    defaultProfile: {tooling['defaultProfile']}")
            overrides = tooling.get("overrides") or {}
            if overrides:
                out.append("    overrides:")
                for stage_id in sorted(overrides):
                    out.append(f"      {stage_id}: {overrides[stage_id]}")
            idx += 1
            while idx < len(fm_lines):
                next_line = fm_lines[idx]
                if next_line.startswith("  ") and not next_line.startswith("    "):
                    break
                if _indent_of(next_line) >= 2 and next_line.lstrip().split(":", 1)[0] in {
                    "defaultProfile",
                    "overrides",
                }:
                    idx += 1
                    continue
                if _indent_of(next_line) >= 4:
                    idx += 1
                    continue
                break
            continue
        out.append(line)
        idx += 1
    return out


def _patch_depends_on(fm_lines: list[str], depends_map: dict[str, list[str]]) -> list[str]:
    out: list[str] = []
    idx = 0
    while idx < len(fm_lines):
        line = fm_lines[idx]
        stripped = line.strip()
        if not stripped.startswith("- id:"):
            out.append(line)
            idx += 1
            continue

        stage_id = _parse_scalar(stripped.split(":", 1)[1])
        stage_indent = _indent_of(line)
        deps = depends_map.get(stage_id, None)
        out.append(line)
        idx += 1

        while idx < len(fm_lines):
            peek = fm_lines[idx]
            if not peek.strip():
                out.append(peek)
                idx += 1
                continue
            peek_indent = _indent_of(peek)
            if peek_indent <= stage_indent and peek.strip().startswith("- "):
                break
            if peek.lstrip().startswith("dependsOn:"):
                depends_indent = _indent_of(peek)
                idx += 1
                while idx < len(fm_lines):
                    dep_line = fm_lines[idx]
                    if not dep_line.strip():
                        idx += 1
                        continue
                    if _indent_of(dep_line) <= depends_indent:
                        break
                    idx += 1
                if deps:
                    out.append(" " * (stage_indent + 6) + "dependsOn:")
                    for dep in deps:
                        out.append(" " * (stage_indent + 8) + f"- {dep}")
                continue
            out.append(peek)
            idx += 1
    return out


def cmd_write(template_path: str, dest_path: str, name: str, overview: str, patch_json: str | None) -> None:
    path = Path(template_path)
    if not path.is_file():
        _fail(f"template not found: {template_path}")
    text = path.read_text(encoding="utf-8")
    lines = text.splitlines()
    if not lines or lines[0].strip() != "---":
        _fail(f"template missing frontmatter: {template_path}")

    closing = 0
    for i in range(1, len(lines)):
        if lines[i].strip() == "---":
            closing = i
            break
    if closing == 0:
        _fail(f"template frontmatter not closed: {template_path}")

    fm_lines = lines[1:closing]
    body_lines = lines[closing:]

    fm_lines = _replace_frontmatter_scalar(fm_lines, "name", name)
    fm_lines = _replace_frontmatter_scalar(fm_lines, "overview", overview)
    try:
        fm_lines = normalize_workflow_frontmatter_mode(fm_lines)
    except WorkflowModeError as exc:
        _fail(str(exc))

    if patch_json:
        patch = json.loads(patch_json)
        tooling = patch.get("tooling") or {}
        depends_on = patch.get("dependsOn") or {}
        if tooling:
            fm_lines = _patch_tooling(fm_lines, tooling)
        if depends_on:
            fm_lines = _patch_depends_on(fm_lines, depends_on)

    out_lines = ["---", *fm_lines, *body_lines]
    dest = Path(dest_path)
    dest.parent.mkdir(parents=True, exist_ok=True)
    dest.write_text("\n".join(out_lines) + "\n", encoding="utf-8")


def main(argv: list[str]) -> None:
    if len(argv) < 2:
        _fail("usage: wizard-workflow-template.py <list|seed|write> ...")
    mode = argv[1]
    if mode == "list":
        if len(argv) != 3:
            _fail("usage: wizard-workflow-template.py list <workflows_dir>")
        cmd_list(argv[2])
        return
    if mode == "seed":
        if len(argv) != 3:
            _fail("usage: wizard-workflow-template.py seed <template_path>")
        cmd_seed(argv[2])
        return
    if mode == "write":
        if len(argv) not in {6, 7}:
            _fail(
                "usage: wizard-workflow-template.py write "
                "<template_path> <dest_path> <name> <overview> [patch_json]"
            )
        patch_json = argv[6] if len(argv) == 7 else None
        cmd_write(argv[2], argv[3], argv[4], argv[5], patch_json)
        return
    _fail(f"unknown mode: {mode}")


if __name__ == "__main__":
    main(sys.argv)
