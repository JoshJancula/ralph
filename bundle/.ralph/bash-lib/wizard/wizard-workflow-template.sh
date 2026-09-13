#!/usr/bin/env bash
# SDLC workflow template discovery and seeding for `ralph create workflow`.
#
# Public interface:
#   wizard_workflow_templates_dir
#   wizard_workflow_template_select_menu
#   wizard_workflow_template_load
#   wizard_workflow_template_stage_default_csv
#   wizard_workflow_template_max_parallel_default
#   wizard_workflow_template_configure_dependencies
#   wizard_workflow_template_write_dest
#   wizard_workflow_resolve_create_dest
#   wizard_workflow_emit_defaults_plan_input_yaml
#   wizard_workflow_atomic_validate_and_rename

wizard_workflow_templates_dir() {
  # Canonical bundled workflows live under .ralph/workflows/ (not workflow-templates/).
  printf '%s/workflows' "${SCRIPT_DIR:?SCRIPT_DIR must be set}"
}

_wizard_workflow_template_py() {
  printf '%s/python/wizard-workflow-template.py' "${SCRIPT_DIR:?SCRIPT_DIR must be set}"
}

wizard_workflow_template_clear() {
  wizard_workflow_template_choice=""
  wizard_workflow_template_source=""
  wizard_workflow_template_seed_json=""
  wizard_workflow_template_stage_ids_csv=""
}

wizard_workflow_template_select_menu() {
  local templates_dir py menu_args=() choices=() default_idx=1 entry id overview
  wizard_workflow_template_clear

  templates_dir="$(wizard_workflow_templates_dir)"
  py="$(_wizard_workflow_template_py)"
  if [[ ! -d "$templates_dir" ]]; then
    ralph_die "workflow templates directory not found: $templates_dir"
  fi
  if ! command -v python3 >/dev/null 2>&1; then
    ralph_die "python3 is required for workflow template discovery"
  fi
  if [[ ! -f "$py" ]]; then
    ralph_die "workflow template helper not found: $py"
  fi

  while IFS= read -r entry; do
    [[ -n "$entry" ]] || continue
    id="$(printf '%s' "$entry" | python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])')"
    overview="$(printf '%s' "$entry" | python3 -c 'import json,sys; print(json.load(sys.stdin)["overview"])')"
    choices+=("$id")
    menu_args+=(--desc "$overview")
  done < <(python3 "$py" list "$templates_dir")

  if [[ ${#choices[@]} -eq 0 ]]; then
    ralph_die "no workflow templates found under $templates_dir"
  fi

  choices+=("custom")
  menu_args+=(--desc "Build stages from scratch.")

  wizard_workflow_template_choice="$(ralph_menu_select --prompt "Start from which template?" \
    --default "$default_idx" "${menu_args[@]}" -- "${choices[@]}")" \
    || ralph_die "template selection required"
}

wizard_workflow_template_load() {
  local choice="$1" py
  wizard_workflow_template_source=""
  wizard_workflow_template_seed_json=""
  wizard_workflow_template_stage_ids_csv=""

  [[ -n "$choice" && "$choice" != "custom" ]] || return 0

  py="$(_wizard_workflow_template_py)"
  wizard_workflow_template_source="$(wizard_workflow_templates_dir)/${choice}.workflow.md"
  [[ -f "$wizard_workflow_template_source" ]] || ralph_die "workflow template not found: $wizard_workflow_template_source"

  wizard_workflow_template_seed_json="$(mktemp "${TMPDIR:-/tmp}/ralph-workflow-template-seed.XXXXXX")"
  python3 "$py" seed "$wizard_workflow_template_source" >"$wizard_workflow_template_seed_json"
  wizard_workflow_template_stage_ids_csv="$(python3 -c 'import json,sys; print(",".join(json.load(open(sys.argv[1]))["stageIds"]))' \
    "$wizard_workflow_template_seed_json")"
}

wizard_workflow_template_depends_default_csv() {
  local stage_id="$1" deps=""
  [[ -n "${wizard_workflow_template_seed_json:-}" && -n "$stage_id" ]] || return 0
  deps="$(python3 - "$wizard_workflow_template_seed_json" "$stage_id" <<'PY'
import json, sys
data = json.load(open(sys.argv[1], encoding="utf-8"))
deps = (data.get("dependsOn") or {}).get(sys.argv[2], [])
print(",".join(deps))
PY
)"
  printf '%s' "$deps"
}

wizard_workflow_template_stage_default_csv() {
  printf '%s' "${wizard_workflow_template_stage_ids_csv:-}"
}

wizard_workflow_template_max_parallel_default() {
  local value=""
  [[ -n "${wizard_workflow_template_seed_json:-}" ]] || { printf '3'; return 0; }
  value="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["maxParallel"])' \
    "$wizard_workflow_template_seed_json" 2>/dev/null || true)"
  if [[ -n "$value" ]]; then
    printf '%s' "$value"
  else
    printf '3'
  fi
}

wizard_workflow_template_configure_dependencies() {
  local stage_id known_csv earlier_ids idx=0
  cp_stage_depends_on=()
  for stage_id in "${selected_stage_ids[@]}"; do
    known_csv=""
    if (( idx > 0 )); then
      earlier_ids=("${selected_stage_ids[@]:0:$idx}")
      known_csv="$(IFS=','; printf '%s' "${earlier_ids[*]}")"
    fi
    cp_stage_depends_on+=("$(select_depends_on "$stage_id" "$known_csv")")
    idx=$((idx + 1))
  done
}

wizard_workflow_template_patch_json() {
  WIZ_PATCH_DEFAULT_PROFILE="${wizard_tooling_default_profile:-}" \
  WIZ_PATCH_OVERRIDES="${wizard_tooling_overrides[*]:-}" \
  WIZ_PATCH_DEPENDS="$( {
      local i
      for i in "${!selected_stage_ids[@]}"; do
        printf '%s\t%s\n' "${selected_stage_ids[$i]}" "${cp_stage_depends_on[$i]:-}"
      done
    } )" \
  python3 - <<'PY'
import json, os
default_profile = os.environ.get("WIZ_PATCH_DEFAULT_PROFILE", "")
overrides_raw = os.environ.get("WIZ_PATCH_OVERRIDES", "")
overrides = {}
for item in overrides_raw.split():
    if "=" in item:
        stage, profile = item.split("=", 1)
        overrides[stage] = profile
tooling = {}
if default_profile:
    tooling["defaultProfile"] = default_profile
if overrides:
    tooling["overrides"] = overrides
depends = {}
for line in os.environ.get("WIZ_PATCH_DEPENDS", "").splitlines():
    if not line.strip():
        continue
    stage_id, deps = line.split("\t", 1)
    depends[stage_id] = [item for item in deps.split(",") if item]
print(json.dumps({"tooling": tooling, "dependsOn": depends}, separators=(",", ":")))
PY
}

wizard_workflow_template_write_dest() {
  local dest="$1" name="$2" overview="$3" py patch_json=""
  [[ -n "${wizard_workflow_template_source:-}" && -f "$wizard_workflow_template_source" ]] \
    || ralph_die "workflow template write requires a loaded template source"

  py="$(_wizard_workflow_template_py)"
  patch_json="$(wizard_workflow_template_patch_json)"
  if [[ -n "${wizard_workflow_template_seed_json:-}" && -f "$wizard_workflow_template_seed_json" ]]; then
    if python3 - "$wizard_workflow_template_seed_json" "$patch_json" <<'PY'
import json, sys
seed = json.load(open(sys.argv[1], encoding="utf-8"))
patch = json.loads(sys.argv[2])
seed_tooling = seed.get("tooling") or {}
patch_tooling = patch.get("tooling") or {}
seed_depends = seed.get("dependsOn") or {}
patch_depends = patch.get("dependsOn") or {}
if patch_tooling == seed_tooling and patch_depends == seed_depends:
    raise SystemExit(0)
raise SystemExit(1)
PY
    then
      patch_json=""
    fi
  fi

  if [[ -n "$patch_json" ]]; then
    python3 "$py" write "$wizard_workflow_template_source" "$dest" "$name" "$overview" "$patch_json"
  else
    python3 "$py" write "$wizard_workflow_template_source" "$dest" "$name" "$overview"
  fi
}

# wizard_workflow_resolve_create_dest <workflow_id> [workspace]
# Resolve create target from --global / RALPH_CREATE_WORKFLOW_GLOBAL.
# Prints: scope<TAB>plans_dir<TAB>dest_path
# Project default: <state-root>/workflows/<id>.workflow.md
# Global: ${RALPH_HOME:-$HOME/.ralph}/workflows/<id>.workflow.md
wizard_workflow_resolve_create_dest() {
  local workflow_id="${1:?wizard_workflow_resolve_create_dest requires workflow id}"
  local workspace="${2:-${workspace:-$(pwd)}}"
  local state_root ralph_home plans_dir scope dest

  if [[ "${RALPH_CREATE_WORKFLOW_GLOBAL:-0}" == "1" ]]; then
    ralph_home="${RALPH_HOME:-${HOME:-}/.ralph}"
    plans_dir="${ralph_home}/workflows"
    scope="global"
  else
    state_root="${RALPH_PLAN_WORKSPACE_ROOT:-${workspace}/.ralph-workspace}"
    plans_dir="${state_root}/workflows"
    scope="project"
  fi
  dest="${plans_dir}/${workflow_id}.workflow.md"
  printf '%s\t%s\t%s' "$scope" "$plans_dir" "$dest"
}

# wizard_workflow_emit_defaults_plan_input_yaml
# Emit top-level defaults: / planInput: blocks from cp_* vars (stdout).
wizard_workflow_emit_defaults_plan_input_yaml() {
  if [[ -n "${cp_defaults_runtime:-}" ]]; then
    printf 'defaults:\n'
    printf '  runtime: %s\n' "$cp_defaults_runtime"
    if [[ -n "${cp_defaults_model:-}" ]]; then
      printf '  model: %s\n' "$cp_defaults_model"
    fi
  fi
  if [[ -n "${cp_plan_input_stage:-}" ]]; then
    printf 'planInput:\n'
    printf '  stage: %s\n' "$cp_plan_input_stage"
    if [[ "${cp_plan_input_required:-}" == "true" ]]; then
      printf '  required: true\n'
    fi
  fi
}

# wizard_workflow_atomic_validate_and_rename <dest> <render_fn> [render_args...]
# Render to a same-directory temporary file, validate, refuse if dest exists,
# then atomically rename into place.
wizard_workflow_atomic_validate_and_rename() {
  local dest="${1:?wizard_workflow_atomic_validate_and_rename requires dest}"
  shift
  local render_fn="${1:?wizard_workflow_atomic_validate_and_rename requires render function}"
  shift
  local plans_dir tmp_dest base

  plans_dir="$(dirname -- "$dest")"
  base="$(basename -- "$dest")"
  mkdir -p "$plans_dir"

  if [[ -e "$dest" ]]; then
    ralph_die "workflow already exists: $dest"
  fi

  tmp_dest="$(mktemp "${plans_dir}/.${base}.XXXXXX")"
  if ! "$render_fn" "$@" >"$tmp_dest"; then
    rm -f "$tmp_dest"
    ralph_die "workflow render failed before write"
  fi

  # shellcheck source=bash-lib/plan-todo.sh
  source "${SCRIPT_DIR}/bash-lib/plan-todo.sh"
  if ! plan_workflow_validate "$tmp_dest"; then
    rm -f "$tmp_dest"
    ralph_die "workflow validation failed before write: $tmp_dest"
  fi

  if [[ -e "$dest" ]]; then
    rm -f "$tmp_dest"
    ralph_die "workflow already exists: $dest"
  fi

  mv "$tmp_dest" "$dest"
}
