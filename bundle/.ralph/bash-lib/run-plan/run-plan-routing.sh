#!/usr/bin/env bash

if [[ -n "${RALPH_RUN_PLAN_ROUTING_LOADED:-}" ]]; then
  return
fi
RALPH_RUN_PLAN_ROUTING_LOADED=1

_run_plan_routing_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if ! declare -F plan_pipeline_has_metadata >/dev/null 2>&1 || \
   ! declare -F plan_pipeline_any_todo_has_routing >/dev/null 2>&1; then
  # shellcheck source=/dev/null
  source "$_run_plan_routing_dir/../plan-todo.sh"
fi
if ! declare -F ralph_resolve_runtime_root >/dev/null 2>&1; then
  # shellcheck source=/dev/null
  source "$_run_plan_routing_dir/../runtime-resolve.sh"
fi
if ! declare -F ralph_session_effective_strategy >/dev/null 2>&1; then
  # shellcheck source=/dev/null
  source "$_run_plan_routing_dir/run-plan-session.sh"
fi
if ! declare -F prebuilt_agents_root >/dev/null 2>&1; then
  # shellcheck source=/dev/null
  source "$_run_plan_routing_dir/run-plan-agent.sh"
fi

unset _run_plan_routing_dir

ralph_run_plan_routing_set_runtime_context() {
  local runtime="${1:-${RUNTIME:-}}"
  local workspace="${2:-${WORKSPACE:-}}"
  local script_dir="${3:-${SCRIPT_DIR:-}}"

  if [[ -z "$runtime" ]]; then
    echo "Error: runtime is required for routing context resolution." >&2
    return 1
  fi

  RUNTIME="$runtime"
  RUNTIME_ROOT="$(ralph_resolve_runtime_root "$runtime" "$workspace")" || return 1
  export RALPH_RUNTIME_ROOT="$RUNTIME_ROOT"
  AGENTS_ROOT_REL=".${runtime}/agents"
  AGENTS_ROOT="$RUNTIME_ROOT/agents"

  SELECT_MODEL_SCRIPT="$(ralph_select_model_script "$runtime" "$workspace" "$script_dir")" || return 1
  # shellcheck source=/dev/null
  source "$SELECT_MODEL_SCRIPT"

  return 0
}

ralph_run_plan_routing_set_session_context() {
  local runtime="${1:-${RUNTIME:-}}"
  if [[ -z "${RALPH_SESSION_DIR:-}" ]]; then
    return 0
  fi
  if [[ -z "$runtime" ]]; then
    return 1
  fi

  SESSION_ID_FILE="$RALPH_SESSION_DIR/session-id.${runtime}.txt"
  SESSION_ID_FILE_LEGACY="$RALPH_SESSION_DIR/session-id.txt"
  export SESSION_ID_FILE
  export SESSION_ID_FILE_LEGACY
}

ralph_run_plan_routing_ensure_runtime_cli() {
  case "${RUNTIME:-}" in
    cursor)
      ralph_ensure_cursor_cli
      RALPH_INVOKED_CLI="$CURSOR_CLI"
      ;;
    claude)
      ralph_ensure_claude_cli
      RALPH_INVOKED_CLI="$CLAUDE_CLI"
      ;;
    codex)
      ralph_ensure_codex_cli
      RALPH_INVOKED_CLI="$CODEX_CLI"
      ;;
    opencode)
      ralph_ensure_opencode_cli
      RALPH_INVOKED_CLI="$OPENCODE_CLI"
      ;;
    antigravity)
      ralph_ensure_antigravity_cli
      RALPH_INVOKED_CLI="$ANTIGRAVITY_CLI"
      ;;
    *)
      echo "Error: unsupported runtime for CLI resolution: ${RUNTIME:-}" >&2
      return 1
      ;;
  esac
  export RALPH_INVOKED_CLI
}

ralph_run_plan_routing_resolve_current_context() {
  local runtime="${RUNTIME:-}"
  local workspace="${WORKSPACE:-}"
  local agent_root
  local agent_model=""
  local runtime_env_model=""

  if [[ -z "$runtime" ]]; then
    echo "Error: runtime is required for context resolution." >&2
    return 1
  fi

  if ! ralph_run_plan_routing_set_runtime_context "$runtime" "$workspace" "$SCRIPT_DIR"; then
    return 1
  fi

  PREBUILT_AGENT_CONTEXT=""
  CLAUDE_TOOLS_FROM_AGENT=""
  RALPH_AGENT_MAX_BUDGET=""

  if [[ -n "${PREBUILT_AGENT:-}" ]]; then
    if [[ ! -f "$AGENT_CONFIG_TOOL" ]]; then
      echo -e "${C_R}agent-config-tool.sh is required for prebuilt agent validation and context.${C_RST}" >&2
      ralph_run_plan_log "ERROR: missing $AGENT_CONFIG_TOOL for agent $PREBUILT_AGENT"
      return 1
    fi
    agent_root="$(prebuilt_agents_root "$workspace")"
    ralph_run_plan_log "agent discovery ($runtime): root=$agent_root ids=[$(list_prebuilt_agent_ids "$workspace" | paste -sd', ' -)]"
    if ! validate_prebuilt_agent_config "$workspace" "$PREBUILT_AGENT"; then
      echo -e "${C_R}Invalid agent config for '${PREBUILT_AGENT}'.${C_RST} See .cursor/agents/README.md" >&2
      ralph_run_plan_log "ERROR: validate failed for agent $PREBUILT_AGENT"
      return 1
    fi
    agent_model="$(read_prebuilt_agent_model "$workspace" "$PREBUILT_AGENT")" || {
      echo -e "${C_R}Could not read model for prebuilt agent${C_RST} $PREBUILT_AGENT" >&2
      ralph_run_plan_log "ERROR: model read failed for $PREBUILT_AGENT"
      return 1
    }

    case "$runtime" in
      claude|codex)
        SELECTED_MODEL="$(ralph_resolve_claude_codex_plan_model "$runtime" "$agent_model")" || {
          ralph_run_plan_die_unresolved_claude_codex_model "$runtime"
        }
        if [[ -n "${PLAN_MODEL_CLI:-}" ]]; then
          ralph_run_plan_log "using CLI --model: $SELECTED_MODEL (agent=$PREBUILT_AGENT)"
        elif { [[ "$runtime" == "claude" && -n "${CLAUDE_PLAN_MODEL:-}" ]] \
          || [[ "$runtime" == "codex" && -n "${CODEX_PLAN_MODEL:-}" ]] \
          || [[ -n "${CURSOR_PLAN_MODEL:-}" ]]; }; then
          ralph_run_plan_log "runtime env model: $SELECTED_MODEL (agent=$PREBUILT_AGENT)"
        elif [[ -n "$agent_model" ]]; then
          ralph_run_plan_log "prebuilt agent config model: $SELECTED_MODEL (agent=$PREBUILT_AGENT)"
        else
          ralph_run_plan_log "saved-model default: $SELECTED_MODEL (agent=$PREBUILT_AGENT)"
        fi
        ;;
      *)
        SELECTED_MODEL="$agent_model"
        runtime_env_model=""
        case "$runtime" in
          cursor) runtime_env_model="${CURSOR_PLAN_MODEL:-}" ;;
          opencode) runtime_env_model="${OPENCODE_PLAN_MODEL:-${CURSOR_PLAN_MODEL:-}}" ;;
          antigravity) SELECTED_MODEL="$(ralph_resolve_antigravity_plan_model "$agent_model")" || true ;;
        esac
        if [[ "$runtime" != "antigravity" && -n "$runtime_env_model" ]]; then
          SELECTED_MODEL="$runtime_env_model"
          ralph_run_plan_log "runtime env model override: $SELECTED_MODEL (agent=$PREBUILT_AGENT)"
        fi
        if [[ -n "${PLAN_MODEL_CLI:-}" ]]; then
          SELECTED_MODEL="$PLAN_MODEL_CLI"
          ralph_run_plan_log "CLI --model overrides prebuilt agent default model (agent=$PREBUILT_AGENT)"
        fi
        ;;
    esac

    if [[ "$runtime" == "claude" ]]; then
      PREBUILT_AGENT_CONTEXT="$(RALPH_COMPACT_CONTEXT=0 format_prebuilt_agent_context_block "$workspace" "$PREBUILT_AGENT")" || {
        echo -e "${C_R}Could not build run context for agent${C_RST} $PREBUILT_AGENT" >&2
        ralph_run_plan_log "ERROR: context build failed for $PREBUILT_AGENT"
        return 1
      }
      agent_root="$(prebuilt_agents_root "$workspace")"
      CLAUDE_TOOLS_FROM_AGENT="$(bash "$AGENT_CONFIG_TOOL" allowed-tools "$agent_root" "$PREBUILT_AGENT" 2>/dev/null || true)"
      [[ -n "$CLAUDE_TOOLS_FROM_AGENT" ]] && ralph_run_plan_log "allowed_tools from agent config: $CLAUDE_TOOLS_FROM_AGENT"
      RALPH_AGENT_MAX_BUDGET="$(bash "$AGENT_CONFIG_TOOL" max-budget "$agent_root" "$PREBUILT_AGENT" 2>/dev/null || true)"
      export RALPH_AGENT_MAX_BUDGET
      [[ -n "$RALPH_AGENT_MAX_BUDGET" ]] && ralph_run_plan_log "max_budget_usd from agent config: $RALPH_AGENT_MAX_BUDGET"
    else
      PREBUILT_AGENT_CONTEXT="$(RALPH_COMPACT_CONTEXT=1 format_prebuilt_agent_context_block "$workspace" "$PREBUILT_AGENT")" || {
        echo -e "${C_R}Could not build run context for agent${C_RST} $PREBUILT_AGENT" >&2
        ralph_run_plan_log "ERROR: context build failed for $PREBUILT_AGENT"
        return 1
      }
      CLAUDE_TOOLS_FROM_AGENT=""
    fi
    ralph_run_plan_log "prebuilt agent id=$PREBUILT_AGENT model=$SELECTED_MODEL (config validated)"
  elif [[ "$runtime" == "claude" || "$runtime" == "codex" ]]; then
    if [[ "${INTERACTIVE_SELECT_MODEL_FLAG:-0}" == "1" ]]; then
      case "$runtime" in
        claude) SELECTED_MODEL="$(_claude_select_model_interactive)" ;;
        codex) SELECTED_MODEL="$(_codex_select_model_interactive)" ;;
      esac
      SELECTED_MODEL="$(tr -d '\r' <<<"${SELECTED_MODEL:-}")"
      [[ -n "$SELECTED_MODEL" ]] || ralph_run_plan_die_unresolved_claude_codex_model "$runtime"
      ralph_run_plan_log "interactive model selection: $SELECTED_MODEL"
    else
      SELECTED_MODEL="$(ralph_resolve_claude_codex_plan_model "$runtime" "")" || {
        ralph_run_plan_die_unresolved_claude_codex_model "$runtime"
      }
      ralph_run_plan_log "using model: $SELECTED_MODEL"
    fi
  elif [[ -n "${PLAN_MODEL_CLI:-}" ]]; then
    SELECTED_MODEL="$PLAN_MODEL_CLI"
    ralph_run_plan_log "using CLI --model: $SELECTED_MODEL"
  else
    SELECTED_MODEL="$(prompt_for_agent)"
    if [[ -n "$SELECTED_MODEL" ]]; then
      ralph_run_plan_log "using model: $SELECTED_MODEL"
    fi
  fi

  ralph_run_plan_routing_ensure_runtime_cli
  return 0
}

ralph_run_plan_routing_capture_baseline() {
  _RALPH_RP_BASE_RUNTIME="${RUNTIME:-}"
  _RALPH_RP_BASE_RUNTIME_ROOT="${RUNTIME_ROOT:-}"
  _RALPH_RP_BASE_RALPH_RUNTIME_ROOT="${RALPH_RUNTIME_ROOT:-}"
  _RALPH_RP_BASE_AGENTS_ROOT_REL="${AGENTS_ROOT_REL:-}"
  _RALPH_RP_BASE_AGENTS_ROOT="${AGENTS_ROOT:-}"
  _RALPH_RP_BASE_SELECT_MODEL_SCRIPT="${SELECT_MODEL_SCRIPT:-}"
  _RALPH_RP_BASE_PREBUILT_AGENT="${PREBUILT_AGENT:-}"
  _RALPH_RP_BASE_PLAN_MODEL_CLI="${PLAN_MODEL_CLI:-}"
  _RALPH_RP_BASE_SELECTED_MODEL="${SELECTED_MODEL:-}"
  _RALPH_RP_BASE_PREBUILT_AGENT_CONTEXT="${PREBUILT_AGENT_CONTEXT:-}"
  _RALPH_RP_BASE_CLAUDE_TOOLS_FROM_AGENT="${CLAUDE_TOOLS_FROM_AGENT:-}"
  _RALPH_RP_BASE_RALPH_AGENT_MAX_BUDGET="${RALPH_AGENT_MAX_BUDGET:-}"
  _RALPH_RP_BASE_SESSION_ID_FILE="${SESSION_ID_FILE:-}"
  _RALPH_RP_BASE_SESSION_ID_FILE_LEGACY="${SESSION_ID_FILE_LEGACY:-}"
  _RALPH_RP_BASE_RALPH_PLAN_SESSION_STRATEGY="${RALPH_PLAN_SESSION_STRATEGY:-}"
  _RALPH_RP_BASE_RALPH_PLAN_CONTEXT_BUDGET="${RALPH_PLAN_CONTEXT_BUDGET:-}"
  _RALPH_RP_BASE_RALPH_PLAN_FILE_PATH="${RALPH_PLAN_FILE_PATH:-}"
  _RALPH_RP_BASE_RALPH_PLAN_CLI_RESUME="${RALPH_PLAN_CLI_RESUME:-}"
  _RALPH_RP_BASE_RALPH_INVOKED_CLI="${RALPH_INVOKED_CLI:-}"
  _RALPH_RP_BASE_CLAUDE_CLI="${CLAUDE_CLI:-}"
  _RALPH_RP_BASE_CURSOR_CLI="${CURSOR_CLI:-}"
  _RALPH_RP_BASE_CODEX_CLI="${CODEX_CLI:-}"
  _RALPH_RP_BASE_OPENCODE_CLI="${OPENCODE_CLI:-}"
  _RALPH_RP_BASE_ANTIGRAVITY_CLI="${ANTIGRAVITY_CLI:-}"
  _RALPH_RP_BASE_ANTIGRAVITY_PLAN_MODEL="${ANTIGRAVITY_PLAN_MODEL:-}"
  _RALPH_RP_BASE_ANTIGRAVITY_PLAN_MAX_ITER="${ANTIGRAVITY_PLAN_MAX_ITER:-}"
  _RALPH_RP_BASE_ANTIGRAVITY_PLAN_GUTTER_ITER="${ANTIGRAVITY_PLAN_GUTTER_ITER:-}"
  _RALPH_RP_BASE_RALPH_PLAN_COMPACT_COMMAND_ANTIGRAVITY="${RALPH_PLAN_COMPACT_COMMAND_ANTIGRAVITY:-}"
  _RALPH_RP_BASE_CAPTURED=1
}

ralph_run_plan_routing_restore_baseline() {
  if [[ "${_RALPH_RP_BASE_CAPTURED:-0}" != "1" ]]; then
    return 0
  fi

  RUNTIME="${_RALPH_RP_BASE_RUNTIME:-}"
  RUNTIME_ROOT="${_RALPH_RP_BASE_RUNTIME_ROOT:-}"
  RALPH_RUNTIME_ROOT="${_RALPH_RP_BASE_RALPH_RUNTIME_ROOT:-}"
  AGENTS_ROOT_REL="${_RALPH_RP_BASE_AGENTS_ROOT_REL:-}"
  AGENTS_ROOT="${_RALPH_RP_BASE_AGENTS_ROOT:-}"
  SELECT_MODEL_SCRIPT="${_RALPH_RP_BASE_SELECT_MODEL_SCRIPT:-}"
  PREBUILT_AGENT="${_RALPH_RP_BASE_PREBUILT_AGENT:-}"
  PLAN_MODEL_CLI="${_RALPH_RP_BASE_PLAN_MODEL_CLI:-}"
  SELECTED_MODEL="${_RALPH_RP_BASE_SELECTED_MODEL:-}"
  PREBUILT_AGENT_CONTEXT="${_RALPH_RP_BASE_PREBUILT_AGENT_CONTEXT:-}"
  CLAUDE_TOOLS_FROM_AGENT="${_RALPH_RP_BASE_CLAUDE_TOOLS_FROM_AGENT:-}"
  RALPH_AGENT_MAX_BUDGET="${_RALPH_RP_BASE_RALPH_AGENT_MAX_BUDGET:-}"
  SESSION_ID_FILE="${_RALPH_RP_BASE_SESSION_ID_FILE:-}"
  SESSION_ID_FILE_LEGACY="${_RALPH_RP_BASE_SESSION_ID_FILE_LEGACY:-}"
  RALPH_PLAN_SESSION_STRATEGY="${_RALPH_RP_BASE_RALPH_PLAN_SESSION_STRATEGY:-}"
  RALPH_PLAN_CONTEXT_BUDGET="${_RALPH_RP_BASE_RALPH_PLAN_CONTEXT_BUDGET:-}"
  RALPH_PLAN_FILE_PATH="${_RALPH_RP_BASE_RALPH_PLAN_FILE_PATH:-}"
  RALPH_PLAN_CLI_RESUME="${_RALPH_RP_BASE_RALPH_PLAN_CLI_RESUME:-}"
  RALPH_INVOKED_CLI="${_RALPH_RP_BASE_RALPH_INVOKED_CLI:-}"
  CLAUDE_CLI="${_RALPH_RP_BASE_CLAUDE_CLI:-}"
  CURSOR_CLI="${_RALPH_RP_BASE_CURSOR_CLI:-}"
  CODEX_CLI="${_RALPH_RP_BASE_CODEX_CLI:-}"
  OPENCODE_CLI="${_RALPH_RP_BASE_OPENCODE_CLI:-}"
  ANTIGRAVITY_CLI="${_RALPH_RP_BASE_ANTIGRAVITY_CLI:-}"
  ANTIGRAVITY_PLAN_MODEL="${_RALPH_RP_BASE_ANTIGRAVITY_PLAN_MODEL:-}"
  ANTIGRAVITY_PLAN_MAX_ITER="${_RALPH_RP_BASE_ANTIGRAVITY_PLAN_MAX_ITER:-}"
  ANTIGRAVITY_PLAN_GUTTER_ITER="${_RALPH_RP_BASE_ANTIGRAVITY_PLAN_GUTTER_ITER:-}"
  RALPH_PLAN_COMPACT_COMMAND_ANTIGRAVITY="${_RALPH_RP_BASE_RALPH_PLAN_COMPACT_COMMAND_ANTIGRAVITY:-}"
  export RALPH_RUNTIME_ROOT SESSION_ID_FILE SESSION_ID_FILE_LEGACY RALPH_PLAN_SESSION_STRATEGY
  export RALPH_PLAN_CONTEXT_BUDGET RALPH_PLAN_CLI_RESUME RALPH_INVOKED_CLI
  export CLAUDE_CLI CURSOR_CLI CODEX_CLI OPENCODE_CLI ANTIGRAVITY_CLI
  export ANTIGRAVITY_PLAN_MODEL ANTIGRAVITY_PLAN_MAX_ITER ANTIGRAVITY_PLAN_GUTTER_ITER RALPH_PLAN_COMPACT_COMMAND_ANTIGRAVITY
}

ralph_run_plan_routing_effective_metadata_fields() {
  local plan_path="$1"
  local todo_target="$2"
  local raw_json
  raw_json="$(plan_pipeline_effective_metadata_json "$plan_path" "$todo_target")" || return 1
  python3 - "$raw_json" <<'PY'
import json
import sys

data = json.loads(sys.argv[1])
fields = [
    data.get("stage", "") or "",
    data.get("runtime", "") or "",
    data.get("agent", "") or "",
    data.get("model", "") or "",
    data.get("sessionStrategy", "") or "",
    data.get("contextBudget", "") or "",
    data.get("planFile", "") or "",
]
# Use a non-whitespace delimiter so Bash preserves empty middle fields.
print("\x1f".join(fields))
PY
}

ralph_run_plan_routing_apply_effective_todo_context() {
  local plan_path="$1"
  local plan_format="$2"
  local line_num="$3"
  local todo_target="$4"
  local todo_id="${5:-}"
  local eff_stage=""
  local eff_runtime=""
  local eff_agent=""
  local eff_model=""
  local eff_session_strategy=""
  local eff_context_budget=""
  local eff_plan_file=""

  ralph_run_plan_routing_restore_baseline

  if ! plan_format_is_yaml "$plan_format"; then
    return 0
  fi
  if ! plan_pipeline_has_metadata "$plan_path" \
     && ! plan_pipeline_any_todo_has_routing "$plan_path"; then
    return 0
  fi

  if ! IFS=$'\x1f' read -r eff_stage eff_runtime eff_agent eff_model eff_session_strategy eff_context_budget eff_plan_file <<< "$(
    ralph_run_plan_routing_effective_metadata_fields "$plan_path" "$todo_target"
  )"; then
    return 1
  fi

  if ! plan_pipeline_has_metadata "$plan_path"; then
    local flat_session="${eff_session_strategy:-${RALPH_PLAN_SESSION_STRATEGY:-}}"
    if [[ "$flat_session" != "fresh" ]]; then
      ralph_run_plan_log "TODO routing: flat-plan runtime/model override skipped (sessionStrategy=${flat_session:-unset}; requires fresh)"
      return 0
    fi
  fi

  if [[ -n "$eff_stage" ]]; then
    RALPH_STAGE_ID="$eff_stage"
    export RALPH_STAGE_ID
  fi
  if [[ -n "$eff_runtime" ]]; then
    RUNTIME="$eff_runtime"
  fi
  if [[ -n "$eff_agent" ]]; then
    PREBUILT_AGENT="$eff_agent"
  fi
  if [[ -n "$eff_model" ]]; then
    PLAN_MODEL_CLI="$eff_model"
  fi
  if [[ -n "$eff_session_strategy" ]]; then
    RALPH_PLAN_SESSION_STRATEGY="$eff_session_strategy"
  fi
  if [[ -n "$eff_context_budget" ]]; then
    RALPH_PLAN_CONTEXT_BUDGET="$eff_context_budget"
  fi
  RALPH_PLAN_FILE_PATH="$eff_plan_file"
  export RALPH_PLAN_FILE_PATH

  if ! ralph_run_plan_routing_resolve_current_context; then
    return 1
  fi
  if ! ralph_run_plan_routing_set_session_context "$RUNTIME"; then
    return 1
  fi

  if [[ "${_RALPH_RP_BASE_CAPTURED:-0}" == "1" && "$RUNTIME" != "${_RALPH_RP_BASE_RUNTIME:-}" ]]; then
    if [[ "${RALPH_AGENT_TOOL_ACCESS:-native}" == "ralph" ]]; then
      ralph_run_plan_opencode_strict_proxy_preflight || return 1
      ralph_run_plan_mcp_preflight_or_exit || return 1
    fi
  fi

  ralph_run_plan_log "TODO routing: line=$line_num id=${todo_id:-$todo_target} runtime=${RUNTIME:-} agent=${PREBUILT_AGENT:-} model=${SELECTED_MODEL:-} sessionStrategy=${RALPH_PLAN_SESSION_STRATEGY:-} contextBudget=${RALPH_PLAN_CONTEXT_BUDGET:-} planFile=${RALPH_PLAN_FILE_PATH:-}"
  return 0
}
