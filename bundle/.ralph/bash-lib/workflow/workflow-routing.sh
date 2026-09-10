#!/usr/bin/env bash
# Workflow runtime/model routing resolver and interactive fallback prompt.
#
# Resolves effective runtime and model for one workflow stage/TODO context and
# reports provenance. Pure resolve paths do not prompt, write files, or invoke
# runtime CLIs. Interactive fallback prompting lives in
# workflow_routing_prompt_unresolved_fallback (no materialization).
#
# Provenance enum: todo|stage|invocation|provided-plan|workflow|environment|saved|native
#
# Workflow runtime order (ordinary agent stages):
#   TODO > stage > invocation > [provided-plan if plan-input consumer] >
#   workflow default > RALPH_PLAN_RUNTIME (environment) > interactive selection
#
# Workflow model order:
#   TODO > stage > invocation > [provided-plan if consumer] > workflow default >
#   saved (claude/codex only) > native
#
# Pairing:
#   Invocation/workflow models apply only when their paired runtime equals the
#   effective runtime. Stage/TODO model-only inherits the effective runtime.
#   Stage/TODO runtime-only yields saved/native model and fresh_session=1.
#
# Voters require an explicit todo/stage runtime (no env/workflow fallthrough).
# Supervisors accept no runtime/model (empty result; refuse non-empty inputs).
# Provided-plan header values participate only when plan_input_consumer=1.

if [[ -n "${RALPH_WORKFLOW_ROUTING_LOADED:-}" ]]; then
  return 0
fi
RALPH_WORKFLOW_ROUTING_LOADED=1

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  echo "This file is meant to be sourced, not executed." >&2
  exit 1
fi

_workflow_routing_lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if ! declare -F ralph_normalize_runtime_name >/dev/null 2>&1; then
  # shellcheck source=/dev/null
  source "$_workflow_routing_lib_dir/../runtime-normalize.sh"
fi

# Optional saved-model lookup (claude/codex). Sourced lazily on first use.
_workflow_routing_ensure_model_store() {
  if declare -F ralph_model_store_default >/dev/null 2>&1; then
    return 0
  fi
  local store="$_workflow_routing_lib_dir/../select-model/model-store.sh"
  if [[ -r "$store" ]]; then
    # shellcheck source=/dev/null
    source "$store"
  fi
}

_workflow_routing_is_supervisor_kind() {
  case "${1:-}" in
    supervisor|approval|integrate|join|gate|checkpoint|router)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

_workflow_routing_is_voter_kind() {
  case "${1:-}" in
    voter|consensus-voter)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

_workflow_routing_normalize_optional_runtime() {
  local raw="${1:-}"
  if [[ -z "$raw" ]]; then
    printf '%s\n' ""
    return 0
  fi
  local normalized
  normalized="$(ralph_normalize_runtime_name "$raw")"
  if ! ralph_runtime_is_supported "$normalized"; then
    echo "Error: unsupported runtime: $raw" >&2
    return 1
  fi
  printf '%s\n' "$normalized"
}

_workflow_routing_saved_supported() {
  case "${1:-}" in
    claude|codex) return 0 ;;
    *) return 1 ;;
  esac
}

# Lookup saved default for runtime. Honors optional injection via
# WORKFLOW_ROUTING_SAVED_MODEL when WORKFLOW_ROUTING_SAVED_MODEL_SET=1.
_workflow_routing_lookup_saved_model() {
  local runtime="${1:-}"
  if [[ "${WORKFLOW_ROUTING_SAVED_MODEL_SET:-0}" == "1" ]]; then
    printf '%s\n' "${WORKFLOW_ROUTING_SAVED_MODEL:-}"
    return 0
  fi
  if ! _workflow_routing_saved_supported "$runtime"; then
    printf '%s\n' ""
    return 0
  fi
  _workflow_routing_ensure_model_store
  if declare -F ralph_model_store_default >/dev/null 2>&1; then
    ralph_model_store_default "$runtime" 2>/dev/null || true
    return 0
  fi
  printf '%s\n' ""
}

_workflow_routing_emit() {
  local runtime="${1:-}"
  local runtime_provenance="${2:-}"
  local model="${3:-}"
  local model_provenance="${4:-}"
  local unresolved="${5:-0}"
  local fresh_session="${6:-0}"

  printf 'runtime=%s\n' "$runtime"
  printf 'runtime_provenance=%s\n' "$runtime_provenance"
  printf 'model=%s\n' "$model"
  printf 'model_provenance=%s\n' "$model_provenance"
  printf 'unresolved=%s\n' "$unresolved"
  printf 'fresh_session=%s\n' "$fresh_session"
}

# Parse key=value args into the named associative-style locals via namerefs.
# Unknown keys are rejected. Empty values clear the field.
_workflow_routing_parse_args() {
  local -n _wr_out="$1"
  shift

  local arg key value
  for arg in "$@"; do
    case "$arg" in
      *=*)
        key="${arg%%=*}"
        value="${arg#*=}"
        ;;
      *)
        echo "Error: workflow_routing_resolve expects key=value arguments (got: $arg)" >&2
        return 2
        ;;
    esac
    case "$key" in
      kind|todo_runtime|todo_model|stage_runtime|stage_model|invocation_runtime|invocation_model|workflow_runtime|workflow_model|provided_plan_runtime|provided_plan_model|env_runtime|plan_input_consumer|saved_model)
        _wr_out["$key"]="$value"
        if [[ "$key" == "saved_model" ]]; then
          _wr_out["_saved_model_set"]=1
        fi
        ;;
      *)
        echo "Error: unknown workflow routing key: $key" >&2
        return 2
        ;;
    esac
  done
}

# Public: resolve effective runtime/model for one stage/TODO context.
#
# Usage:
#   workflow_routing_resolve kind=agent todo_runtime=... stage_model=... ...
#
# Output: key=value lines (runtime, runtime_provenance, model, model_provenance,
# unresolved, fresh_session). Exit 0 on success, 1 on contract refusal, 2 on
# bad arguments.
workflow_routing_resolve() {
  local -A args=(
    [kind]=agent
    [todo_runtime]=
    [todo_model]=
    [stage_runtime]=
    [stage_model]=
    [invocation_runtime]=
    [invocation_model]=
    [workflow_runtime]=
    [workflow_model]=
    [provided_plan_runtime]=
    [provided_plan_model]=
    [env_runtime]=
    [plan_input_consumer]=0
    [saved_model]=
    [_saved_model_set]=0
  )

  _workflow_routing_parse_args args "$@" || return $?

  local kind="${args[kind]:-agent}"
  local plan_input_consumer="${args[plan_input_consumer]:-0}"
  case "$plan_input_consumer" in
    0|1|true|false|yes|no) ;;
    *)
      echo "Error: plan_input_consumer must be 0 or 1" >&2
      return 2
      ;;
  esac
  case "$plan_input_consumer" in
    true|yes) plan_input_consumer=1 ;;
    false|no) plan_input_consumer=0 ;;
  esac

  local todo_runtime stage_runtime invocation_runtime workflow_runtime provided_plan_runtime env_runtime
  todo_runtime="$(_workflow_routing_normalize_optional_runtime "${args[todo_runtime]}")" || return 1
  stage_runtime="$(_workflow_routing_normalize_optional_runtime "${args[stage_runtime]}")" || return 1
  invocation_runtime="$(_workflow_routing_normalize_optional_runtime "${args[invocation_runtime]}")" || return 1
  workflow_runtime="$(_workflow_routing_normalize_optional_runtime "${args[workflow_runtime]}")" || return 1
  provided_plan_runtime="$(_workflow_routing_normalize_optional_runtime "${args[provided_plan_runtime]}")" || return 1
  env_runtime="$(_workflow_routing_normalize_optional_runtime "${args[env_runtime]}")" || return 1

  local todo_model="${args[todo_model]}"
  local stage_model="${args[stage_model]}"
  local invocation_model="${args[invocation_model]}"
  local workflow_model="${args[workflow_model]}"
  local provided_plan_model="${args[provided_plan_model]}"

  if [[ "${args[_saved_model_set]}" == "1" ]]; then
    WORKFLOW_ROUTING_SAVED_MODEL_SET=1
    WORKFLOW_ROUTING_SAVED_MODEL="${args[saved_model]}"
  else
    unset WORKFLOW_ROUTING_SAVED_MODEL_SET WORKFLOW_ROUTING_SAVED_MODEL
  fi

  # Supervisors: no runtime/model. Refuse if any routing input is present.
  if _workflow_routing_is_supervisor_kind "$kind"; then
    if [[ -n "$todo_runtime$todo_model$stage_runtime$stage_model$invocation_runtime$invocation_model$workflow_runtime$workflow_model$provided_plan_runtime$provided_plan_model$env_runtime" ]]; then
      echo "Error: supervisor kind '$kind' accepts no runtime or model" >&2
      return 1
    fi
    _workflow_routing_emit "" "" "" "" 0 0
    return 0
  fi

  # Voters: explicit todo/stage runtime only; no fallthrough to invocation/workflow/env.
  if _workflow_routing_is_voter_kind "$kind"; then
    local voter_rt="" voter_prov=""
    if [[ -n "$todo_runtime" ]]; then
      voter_rt="$todo_runtime"
      voter_prov="todo"
    elif [[ -n "$stage_runtime" ]]; then
      voter_rt="$stage_runtime"
      voter_prov="stage"
    else
      echo "Error: consensus voter requires an explicit runtime" >&2
      return 1
    fi
    _workflow_routing_resolve_model_for_runtime \
      "$voter_rt" "$voter_prov" \
      "$todo_model" "$stage_model" \
      "$invocation_runtime" "$invocation_model" \
      "$workflow_runtime" "$workflow_model" \
      "$provided_plan_runtime" "$provided_plan_model" \
      "$plan_input_consumer"
    return $?
  fi

  # Ordinary agent / executable stage.
  local eff_rt="" eff_prov=""
  if [[ -n "$todo_runtime" ]]; then
    eff_rt="$todo_runtime"
    eff_prov="todo"
  elif [[ -n "$stage_runtime" ]]; then
    eff_rt="$stage_runtime"
    eff_prov="stage"
  elif [[ -n "$invocation_runtime" ]]; then
    eff_rt="$invocation_runtime"
    eff_prov="invocation"
  elif [[ "$plan_input_consumer" == "1" && -n "$provided_plan_runtime" ]]; then
    eff_rt="$provided_plan_runtime"
    eff_prov="provided-plan"
  elif [[ -n "$workflow_runtime" ]]; then
    eff_rt="$workflow_runtime"
    eff_prov="workflow"
  elif [[ -n "$env_runtime" ]]; then
    eff_rt="$env_runtime"
    eff_prov="environment"
  else
    # Unresolved: caller may invoke workflow_routing_prompt_unresolved_fallback.
    _workflow_routing_emit "" "" "" "" 1 0
    return 0
  fi

  _workflow_routing_resolve_model_for_runtime \
    "$eff_rt" "$eff_prov" \
    "$todo_model" "$stage_model" \
    "$invocation_runtime" "$invocation_model" \
    "$workflow_runtime" "$workflow_model" \
    "$provided_plan_runtime" "$provided_plan_model" \
    "$plan_input_consumer"
}

# Resolve model given an already-chosen effective runtime + runtime provenance.
# Prints the standard emit lines. Uses caller-visible saved-model injection env.
_workflow_routing_resolve_model_for_runtime() {
  local eff_rt="$1"
  local eff_prov="$2"
  local todo_model="$3"
  local stage_model="$4"
  local invocation_runtime="$5"
  local invocation_model="$6"
  local workflow_runtime="$7"
  local workflow_model="$8"
  local provided_plan_runtime="$9"
  local provided_plan_model="${10}"
  local plan_input_consumer="${11}"

  local fresh_session=0
  if [[ "$eff_prov" == "todo" && -z "$todo_model" ]]; then
    fresh_session=1
  elif [[ "$eff_prov" == "stage" && -z "$stage_model" ]]; then
    fresh_session=1
  fi

  local model="" model_prov=""

  if [[ -n "$todo_model" ]]; then
    model="$todo_model"
    model_prov="todo"
  elif [[ -n "$stage_model" ]]; then
    model="$stage_model"
    model_prov="stage"
  elif [[ -n "$invocation_model" && -n "$invocation_runtime" && "$invocation_runtime" == "$eff_rt" ]]; then
    # Invocation model applies only with its paired effective runtime.
    model="$invocation_model"
    model_prov="invocation"
  elif [[ "$plan_input_consumer" == "1" && -n "$provided_plan_model" ]]; then
    # Provided-plan header: model-only inherits; paired model requires matching runtime.
    if [[ -z "$provided_plan_runtime" || "$provided_plan_runtime" == "$eff_rt" ]]; then
      model="$provided_plan_model"
      model_prov="provided-plan"
    fi
  fi

  if [[ -z "$model_prov" && -n "$workflow_model" && -n "$workflow_runtime" && "$workflow_runtime" == "$eff_rt" ]]; then
    model="$workflow_model"
    model_prov="workflow"
  fi

  if [[ -z "$model_prov" ]]; then
    if _workflow_routing_saved_supported "$eff_rt"; then
      local saved=""
      saved="$(_workflow_routing_lookup_saved_model "$eff_rt")"
      if [[ -n "$saved" ]]; then
        model="$saved"
        model_prov="saved"
      else
        model=""
        model_prov="native"
      fi
    else
      # cursor / opencode / antigravity: no saved-model store.
      model=""
      model_prov="native"
    fi
  fi

  _workflow_routing_emit "$eff_rt" "$eff_prov" "$model" "$model_prov" 0 "$fresh_session"
  return 0
}

# Convenience: load resolve output into prefixed shell variables.
# Example: workflow_routing_resolve_into WR kind=agent stage_runtime=claude
# sets WR_runtime, WR_runtime_provenance, WR_model, WR_model_provenance,
# WR_unresolved, WR_fresh_session.
workflow_routing_resolve_into() {
  local prefix="${1:-WR}"
  shift
  local line key value
  local out
  out="$(workflow_routing_resolve "$@")" || return $?
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ -n "$line" ]] || continue
    key="${line%%=*}"
    value="${line#*=}"
    printf -v "${prefix}_${key}" '%s' "$value"
  done <<<"$out"
  return 0
}

# --- Interactive unresolved fallback (runtime then optional model) ------------

_workflow_routing_ensure_interactive() {
  if declare -F ralph_menu_select >/dev/null 2>&1; then
    return 0
  fi
  local interactive="$_workflow_routing_lib_dir/../interactive-select.sh"
  if [[ -r "$interactive" ]]; then
    # shellcheck source=/dev/null
    source "$interactive"
  fi
  declare -F ralph_menu_select >/dev/null 2>&1
}

_workflow_routing_ensure_select_model() {
  # An inherited export -f of ralph_select_model_list_discovered does not bring
  # _CLAUDE_DEFAULT_MODELS. Re-source when either the function or the Claude
  # default catalog is missing so workflow discovery stays complete.
  if declare -F ralph_select_model_list_discovered >/dev/null 2>&1 \
    && [[ -n "${_CLAUDE_DEFAULT_MODELS+x}" ]]; then
    return 0
  fi
  local sm_dir="$_workflow_routing_lib_dir/../select-model"
  export RALPH_SHARED_RALPH_DIR="${RALPH_SHARED_RALPH_DIR:-$(cd "$_workflow_routing_lib_dir/../.." && pwd)}"
  local f
  for f in \
    "$sm_dir/model-store.sh" \
    "$sm_dir/select-model-common.sh" \
    "$sm_dir/select-model-cursor.sh" \
    "$sm_dir/select-model-claude.sh" \
    "$sm_dir/select-model-codex.sh" \
    "$sm_dir/select-model-opencode.sh" \
    "$sm_dir/select-model-antigravity.sh"
  do
    if [[ -r "$f" ]]; then
      # shellcheck source=/dev/null
      source "$f"
    fi
  done
  declare -F ralph_select_model_list_discovered >/dev/null 2>&1
}

_workflow_routing_init_colors() {
  if [[ -n "${NO_COLOR:-}" ]]; then
    C_R="" C_G="" C_Y="" C_B="" C_C="" C_BOLD="" C_DIM="" C_RST=""
    return 0
  fi
  if [[ -t 2 ]] || [[ "${WORKFLOW_ROUTING_FORCE_COLOR:-0}" == "1" ]]; then
    C_R=$'\033[31m'
    C_G=$'\033[32m'
    C_Y=$'\033[33m'
    C_B=$'\033[34m'
    C_C=$'\033[36m'
    C_BOLD=$'\033[1m'
    C_DIM=$'\033[2m'
    C_RST=$'\033[0m'
    return 0
  fi
  C_R="" C_G="" C_Y="" C_B="" C_C="" C_BOLD="" C_DIM="" C_RST=""
}

# True when a runtime's CLI is present on PATH (or known env override).
_workflow_routing_runtime_cli_available() {
  local runtime="${1:-}"
  case "$runtime" in
    cursor)
      if declare -F ralph_resolve_cursor_cli >/dev/null 2>&1; then
        ralph_resolve_cursor_cli >/dev/null 2>&1 && return 0
        return 1
      fi
      command -v cursor-agent >/dev/null 2>&1 && return 0
      command -v agent >/dev/null 2>&1 && return 0
      return 1
      ;;
    claude)
      local cli="${CLAUDE_PLAN_CLI:-claude}"
      command -v "$cli" >/dev/null 2>&1
      ;;
    codex)
      local cli="${CODEX_PLAN_CLI:-${CODEX_CLI:-codex}}"
      command -v "$cli" >/dev/null 2>&1
      ;;
    opencode)
      if declare -F ralph_resolve_opencode_cli >/dev/null 2>&1; then
        ralph_resolve_opencode_cli >/dev/null 2>&1 && return 0
        return 1
      fi
      local ocli="${OPENCODE_PLAN_CLI:-${OPENCODE_CLI:-opencode}}"
      command -v "$ocli" >/dev/null 2>&1
      ;;
    antigravity)
      if declare -F ralph_resolve_antigravity_cli >/dev/null 2>&1; then
        ralph_resolve_antigravity_cli >/dev/null 2>&1 && return 0
        return 1
      fi
      local acli="${ANTIGRAVITY_PLAN_CLI:-agy}"
      command -v "$acli" >/dev/null 2>&1
      ;;
    *)
      return 1
      ;;
  esac
}

# Print installed runtimes in canonical order (one per line).
# Override with WORKFLOW_ROUTING_AVAILABLE_RUNTIMES (space-separated) for tests.
workflow_routing_discover_available_runtimes() {
  local rt
  if [[ -n "${WORKFLOW_ROUTING_AVAILABLE_RUNTIMES+x}" ]]; then
    for rt in ${WORKFLOW_ROUTING_AVAILABLE_RUNTIMES:-}; do
      [[ -n "$rt" ]] && printf '%s\n' "$rt"
    done
    return 0
  fi
  for rt in cursor claude codex opencode antigravity; do
    if _workflow_routing_runtime_cli_available "$rt"; then
      printf '%s\n' "$rt"
    fi
  done
}

_workflow_routing_prompt_emit() {
  local runtime="${1:-}"
  local model="${2:-}"
  local model_skipped="${3:-0}"
  local cancelled="${4:-0}"
  printf 'runtime=%s\n' "$runtime"
  printf 'model=%s\n' "$model"
  printf 'model_skipped=%s\n' "$model_skipped"
  printf 'cancelled=%s\n' "$cancelled"
}

# Prompt for one fallback runtime then optional model when stages are unresolved.
# Does not materialize workflow files.
#
# Usage:
#   workflow_routing_prompt_unresolved_fallback [noninteractive=0|1]
#
# Output (stdout): runtime=, model=, model_skipped=, cancelled=
# Exit: 0 success, 1 noninteractive/error, 2 cancelled
#
# Exact prompts:
#   Select a runtime for unresolved workflow stages:
#   Use the runtime default model or select a model?
# Choices: Use <runtime> default, discovered models, Enter a model ID
workflow_routing_prompt_unresolved_fallback() {
  local noninteractive="${NON_INTERACTIVE_FLAG:-0}"
  local arg key value
  for arg in "$@"; do
    case "$arg" in
      *=*)
        key="${arg%%=*}"
        value="${arg#*=}"
        ;;
      *)
        echo "Error: workflow_routing_prompt_unresolved_fallback expects key=value (got: $arg)" >&2
        return 2
        ;;
    esac
    case "$key" in
      noninteractive) noninteractive="$value" ;;
      *)
        echo "Error: unknown workflow prompt key: $key" >&2
        return 2
        ;;
    esac
  done
  case "$noninteractive" in
    1|true|yes) noninteractive=1 ;;
    0|false|no|"") noninteractive=0 ;;
    *)
      echo "Error: noninteractive must be 0 or 1" >&2
      return 2
      ;;
  esac

  if [[ "$noninteractive" == "1" ]]; then
    echo "Error: unresolved workflow runtime requires --runtime when non-interactive." >&2
    return 1
  fi

  _workflow_routing_init_colors
  _workflow_routing_ensure_interactive || {
    echo "Error: interactive menu helpers unavailable for workflow runtime prompt." >&2
    return 1
  }

  local available=() rt
  while IFS= read -r rt || [[ -n "$rt" ]]; do
    [[ -n "$rt" ]] && available+=("$rt")
  done < <(workflow_routing_discover_available_runtimes)

  if [[ ${#available[@]} -eq 0 ]]; then
    echo "Error: no installed runtimes discovered for unresolved workflow stages; pass --runtime." >&2
    return 1
  fi

  echo "" >&2
  echo -e "${C_C:-}${C_BOLD:-}Select a runtime for unresolved workflow stages:${C_RST:-}" >&2

  local selected=""
  selected="$(
    RALPH_SKIP_FZF_HINT="${RALPH_SKIP_FZF_HINT:-1}" \
      ralph_menu_select --prompt "Select a runtime for unresolved workflow stages:" --default 1 -- "${available[@]}"
  )" || selected=""

  if [[ -z "$selected" ]]; then
    echo "Runtime selection cancelled; exiting without materialization." >&2
    _workflow_routing_prompt_emit "" "" 0 1
    return 2
  fi

  workflow_routing_prompt_model_for_runtime "$selected"
  return $?
}

# workflow_routing_prompt_model_for_runtime <runtime>
# Ask whether to keep the runtime's default model or pick one, for a runtime
# that is already decided. Emits the same runtime/model record as the full
# unresolved-routing prompt, so callers parse one shape either way. Split out
# of workflow_routing_prompt_unresolved_fallback so a start that pinned the
# runtime with --runtime can still be asked about the model.
workflow_routing_prompt_model_for_runtime() {
  local selected="${1:-}"
  if [[ -z "$selected" ]]; then
    echo "Error: workflow_routing_prompt_model_for_runtime requires a runtime" >&2
    return 2
  fi
  _workflow_routing_init_colors
  _workflow_routing_ensure_interactive || {
    echo "Error: interactive menu helpers unavailable for workflow model prompt." >&2
    return 1
  }
  local default_label="Use ${selected} default"
  local custom_label="Enter a model ID"
  local models=()
  local discovery_unavailable=0
  local model_line

  if [[ "${WORKFLOW_ROUTING_MODEL_DISCOVERY_UNAVAILABLE:-0}" == "1" ]]; then
    discovery_unavailable=1
  elif [[ -n "${WORKFLOW_ROUTING_DISCOVERED_MODELS+x}" ]]; then
    while IFS= read -r model_line || [[ -n "$model_line" ]]; do
      [[ -n "$model_line" ]] && models+=("$model_line")
    done <<<"${WORKFLOW_ROUTING_DISCOVERED_MODELS}"
  else
    _workflow_routing_ensure_select_model || true
    if declare -F ralph_select_model_list_discovered >/dev/null 2>&1; then
      local discovery_out="" discovery_ec=0
      discovery_out="$(ralph_select_model_list_discovered "$selected" 2>/dev/null)" || discovery_ec=$?
      if [[ "$discovery_ec" -ne 0 ]]; then
        discovery_unavailable=1
      else
        while IFS= read -r model_line || [[ -n "$model_line" ]]; do
          [[ -n "$model_line" ]] && models+=("$model_line")
        done <<<"$discovery_out"
      fi
    else
      discovery_unavailable=1
    fi
  fi

  if [[ "$discovery_unavailable" == "1" ]]; then
    echo -e "${C_Y:-}Warning: model discovery unavailable for ${selected}; using runtime default.${C_RST:-}" >&2
    _workflow_routing_prompt_emit "$selected" "" 1 0
    return 0
  fi

  echo "" >&2
  echo -e "${C_C:-}${C_BOLD:-}Use the runtime default model or select a model?${C_RST:-}" >&2

  local menu_choices=("$default_label")
  local m
  for m in "${models[@]+"${models[@]}"}"; do
    menu_choices+=("$m")
  done
  menu_choices+=("$custom_label")

  local model_selection=""
  model_selection="$(
    RALPH_SKIP_FZF_HINT="${RALPH_SKIP_FZF_HINT:-1}" \
      ralph_menu_select --prompt "Use the runtime default model or select a model?" --default 1 -- "${menu_choices[@]}"
  )" || model_selection=""

  if [[ -z "$model_selection" || "$model_selection" == "$default_label" ]]; then
    _workflow_routing_prompt_emit "$selected" "" 1 0
    return 0
  fi

  if [[ "$model_selection" == "$custom_label" ]]; then
    local custom_model=""
    if ! declare -F _select_model_read_rp >/dev/null 2>&1; then
      _workflow_routing_ensure_select_model || true
    fi
    if declare -F _select_model_read_rp >/dev/null 2>&1; then
      if ! _select_model_read_rp "Enter a model ID: " custom_model; then
        _workflow_routing_prompt_emit "$selected" "" 1 0
        return 0
      fi
    else
      if [[ -r /dev/tty ]]; then
        read -rp "Enter a model ID: " custom_model </dev/tty 2>/dev/null || custom_model=""
      else
        read -rp "Enter a model ID: " custom_model || custom_model=""
      fi
    fi
    custom_model="${custom_model#"${custom_model%%[![:space:]]*}"}"
    custom_model="${custom_model%"${custom_model##*[![:space:]]}"}"
    if [[ -z "$custom_model" ]]; then
      _workflow_routing_prompt_emit "$selected" "" 1 0
      return 0
    fi
    _workflow_routing_prompt_emit "$selected" "$custom_model" 0 0
    return 0
  fi

  # Discovered model string (Antigravity: keep byte-for-byte).
  _workflow_routing_prompt_emit "$selected" "$model_selection" 0 0
  return 0
}

# ---------------------------------------------------------------------------
# Supplied-plan routing order applied onto an orch stage (mutable only)
# ---------------------------------------------------------------------------

# workflow_routing_apply_provided_order_to_orch <orch_path> <stage_id> <source_plan_path>
#   [--stage-runtime RT] [--stage-model M] [--invocation-runtime RT]
#   [--invocation-model M] [--workflow-runtime RT] [--workflow-model M]
#
# Resolves the fixed supplied-plan routing order for a planInput consumer
# (TODO > stage > invocation > provided-plan header > workflow > saved > native)
# and writes effective runtime/model onto the orch stage only. Never mutates
# the frozen source, original plan, or non-consumer stages.
workflow_routing_apply_provided_order_to_orch() {
  local orch_path="" stage_id="" source_plan=""
  local stage_runtime="" stage_model="" invocation_runtime="" invocation_model=""
  local workflow_runtime="" workflow_model=""
  local header_runtime="" header_model="" resolved eff_rt eff_model tmp line

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --stage-runtime) stage_runtime="${2:-}"; shift 2 ;;
      --stage-model) stage_model="${2:-}"; shift 2 ;;
      --invocation-runtime) invocation_runtime="${2:-}"; shift 2 ;;
      --invocation-model) invocation_model="${2:-}"; shift 2 ;;
      --workflow-runtime) workflow_runtime="${2:-}"; shift 2 ;;
      --workflow-model) workflow_model="${2:-}"; shift 2 ;;
      --*)
        echo "Error: unknown workflow_routing_apply_provided_order_to_orch argument: $1" >&2
        return 1
        ;;
      *)
        if [[ -z "$orch_path" ]]; then
          orch_path="$1"
        elif [[ -z "$stage_id" ]]; then
          stage_id="$1"
        elif [[ -z "$source_plan" ]]; then
          source_plan="$1"
        else
          echo "Error: unexpected positional argument: $1" >&2
          return 1
        fi
        shift
        ;;
    esac
  done

  [[ -f "$orch_path" && -n "$stage_id" && -f "$source_plan" ]] || {
    echo "Error: workflow_routing_apply_provided_order_to_orch requires orch_path, stage_id, source_plan" >&2
    return 1
  }

  if ! declare -F plan_provided_input_fm_scalar >/dev/null 2>&1; then
    # shellcheck source=/dev/null
    source "$_workflow_routing_lib_dir/../plan-todo.sh"
  fi

  # Prefer orch stage pins when callers omit explicit stage overrides.
  if [[ -z "$stage_runtime" ]]; then
    stage_runtime="$(jq -r --arg id "$stage_id" '
      .stages[] | select(.id == $id) | .runtime // empty
    ' "$orch_path")"
  fi
  if [[ -z "$stage_model" ]]; then
    stage_model="$(jq -r --arg id "$stage_id" '
      .stages[] | select(.id == $id) | .model // empty
    ' "$orch_path")"
  fi

  header_runtime="$(plan_provided_input_fm_scalar "$source_plan" "runtime" 2>/dev/null || true)"
  header_model="$(plan_provided_input_fm_scalar "$source_plan" "model" 2>/dev/null || true)"

  resolved="$(
    workflow_routing_resolve \
      kind=agent \
      plan_input_consumer=1 \
      stage_runtime="$stage_runtime" \
      stage_model="$stage_model" \
      invocation_runtime="$invocation_runtime" \
      invocation_model="$invocation_model" \
      workflow_runtime="$workflow_runtime" \
      workflow_model="$workflow_model" \
      provided_plan_runtime="$header_runtime" \
      provided_plan_model="$header_model"
  )" || return 1

  eff_rt=""
  eff_model=""
  while IFS= read -r line; do
    case "$line" in
      runtime=*) eff_rt="${line#runtime=}" ;;
      model=*) eff_model="${line#model=}" ;;
    esac
  done <<<"$resolved"

  tmp="$(mktemp "$(dirname "$orch_path")/.orch-routing-XXXXXX")" || return 1
  if ! jq --arg id "$stage_id" --arg rt "$eff_rt" --arg model "$eff_model" '
      (.stages[] | select(.id == $id)) |= (
        if ($rt != "") then .runtime = $rt else del(.runtime) end
        | if ($model != "") then .model = $model else del(.model) end
      )
    ' "$orch_path" >"$tmp"; then
    rm -f "$tmp"
    echo "Error: failed to apply provided-plan routing order onto orch stage $stage_id" >&2
    return 1
  fi
  mv -f "$tmp" "$orch_path" || {
    rm -f "$tmp"
    return 1
  }
  return 0
}
