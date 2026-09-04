# Agent/model selection helpers for run-plan.sh (sourced from run-plan-core).
# These functions are factored out to keep the main runner smaller.
#
# Public interface:
#   prompt_for_agent -- prints model id for the current RUNTIME (uses select_model_*).
#   prebuilt_agents_root -- classic runtime agents directory path (display/discovery only).
#   prompt_agent_source_mode -- no-op; profile selection was removed.
#
# Profile config helpers were removed. Stage guidance is inline workflow instructions;
# model selection uses CLI / TODO / saved / native precedence.

# Exit with a clear message when non-interactive Claude/Codex runs have no model.
ralph_run_plan_die_unresolved_claude_codex_model() {
  local runtime="$1"
  local env_name=""
  case "$runtime" in
    claude) env_name="CLAUDE_PLAN_MODEL" ;;
    codex) env_name="CODEX_PLAN_MODEL" ;;
    *) env_name="PLAN_MODEL" ;;
  esac
  ralph_run_plan_log "ERROR: non-interactive run requires --model, ${env_name}, or a saved default (ralph models add ${runtime} <id>)"
  echo -e "${C_R}${C_BOLD}Non-interactive mode requires a model for ${runtime}.${C_RST}" >&2
  echo -e "${C_DIM}Provide --model <id>, set ${env_name} (or CURSOR_PLAN_MODEL), or add a saved default via: ralph models add ${runtime} <id>${C_RST}" >&2
  exit 1
}

# True when early non-interactive preflight can proceed without prompting for a model.
ralph_run_plan_non_interactive_model_preflight_ok() {
  if [[ "${NON_INTERACTIVE_FLAG:-0}" != "1" ]]; then
    return 0
  fi
  if [[ -n "${PLAN_MODEL_CLI:-}" ]]; then
    return 0
  fi
  # Workflow/orchestration stages carry their authored model in
  # PLAN_STAGE_MODEL. Per-runtime *_PLAN_MODEL variables are deliberately not
  # populated for staged runs, so checking only CURSOR_PLAN_MODEL here rejects
  # a valid Cursor/OpenCode stage (for example model: auto) before the staged
  # resolver gets a chance to use it.
  if [[ "${RALPH_MODEL_SCOPE:-}" == "staged" ]]; then
    local staged_model=""
    staged_model="$(
      ralph_resolve_staged_plan_model \
        "${RUNTIME:-}" \
        "${PLAN_STAGE_MODEL:-}" 2>/dev/null
    )" || return 1
    case "${RUNTIME:-}" in
      cursor|opencode)
        # Both CLIs have an unattended runtime-native default. An authored
        # model such as Cursor's "auto" is accepted too, but is not required.
        return 0
        ;;
      *)
        [[ -n "$staged_model" ]]
        return
        ;;
    esac
  fi
  case "${RUNTIME:-}" in
    claude|codex)
      ralph_claude_codex_non_interactive_model_resolved "$RUNTIME" ""
      ;;
    antigravity)
      ralph_antigravity_non_interactive_model_resolved
      ;;
    *)
      [[ -n "${CURSOR_PLAN_MODEL:-}" ]]
      ;;
  esac
}

# Prompt for a runtime-specific model id and print it to stdout.
# Args: none
# Returns: 0 on success after printing the id, non-zero on error
prompt_for_agent() {
  local cfg="" em
  case "$RUNTIME" in
    cursor)
      tr -d '\r' <<<"$(select_model_cursor --batch "$NON_INTERACTIVE_FLAG" "${CURSOR_PLAN_MODEL:-}" "$cfg")"
      ;;
    claude|codex)
      ralph_resolve_claude_codex_plan_model "$RUNTIME" "$cfg"
      ;;
    opencode)
      em="${OPENCODE_PLAN_MODEL:-${CURSOR_PLAN_MODEL:-}}"
      tr -d '\r' <<<"$(select_model_opencode --batch "$NON_INTERACTIVE_FLAG" "$em" "$cfg")"
      ;;
    antigravity)
      ralph_resolve_antigravity_plan_model "$cfg"
      ;;
    *)
      echo "Error: unsupported runtime for model selection: $RUNTIME" >&2
      return 1
      ;;
  esac
}

# Classic runtime agents root (path only; profile config.json is not loaded).
prebuilt_agents_root() {
  if [[ -n "${AGENTS_ROOT:-}" && -d "${AGENTS_ROOT:-}" ]]; then
    echo "$AGENTS_ROOT"
  else
    echo "$1/$AGENTS_ROOT_REL"
  fi
}

# Profile agent listing was removed with the portable profile stack.
list_prebuilt_agent_ids() {
  return 0
}

# Profile agent validation was removed with the portable profile stack.
validate_prebuilt_agent_config() {
  echo "Error: prebuilt agent profiles were removed. Use inline workflow instructions (instructions: text)." >&2
  return 1
}

# Profile agent model reads were removed with the portable profile stack.
read_prebuilt_agent_model() {
  return 0
}

# Profile agent reasoning_effort reads were removed with the portable profile stack.
read_prebuilt_agent_reasoning_effort() {
  return 0
}

# Profile agent context blocks were removed with the portable profile stack.
format_prebuilt_agent_context_block() {
  echo "Error: prebuilt agent profiles were removed. Use inline workflow instructions (instructions: text)." >&2
  return 1
}

# Interactive prebuilt agent selection was removed.
prompt_select_prebuilt_agent() {
  echo "Error: --select-agent / prebuilt agent profiles were removed. Use inline workflow instructions (instructions: text)." >&2
  return 1
}

# Profile vs model menu was removed; model resolution proceeds without it.
prompt_agent_source_mode() {
  return 0
}
