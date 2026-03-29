# Agent selection helpers for run-plan.sh (sourced from run-plan-core).
# These functions are factored out to keep the main runner smaller.
#
# Public interface:
#   prompt_for_agent -- prints model id for the current RUNTIME (uses select_model_*).
#   prebuilt_agents_root, list_prebuilt_agent_ids, validate_prebuilt_agent_config -- agent dir discovery/validation.
#   read_prebuilt_agent_model, format_prebuilt_agent_context_block -- model and context from config.json.
#   prompt_select_prebuilt_agent, prompt_agent_source_mode -- interactive agent picking and mode selection.

# Prompt for a runtime-specific model id and print it to stdout.
# Args: none
# Returns: 0 on success after printing the id, non-zero on error
prompt_for_agent() {
  local cfg="" em
  case "$RUNTIME" in
    cursor)
      tr -d '\r' <<<"$(select_model_cursor --batch "$NON_INTERACTIVE_FLAG" "${CURSOR_PLAN_MODEL:-}" "$cfg")"
      ;;
    claude)
      em="${CLAUDE_PLAN_MODEL:-${CURSOR_PLAN_MODEL:-}}"
      tr -d '\r' <<<"$(select_model_claude --batch "$NON_INTERACTIVE_FLAG" "$em" "$cfg")"
      ;;
    codex)
      em="${CODEX_PLAN_MODEL:-${CURSOR_PLAN_MODEL:-}}"
      tr -d '\r' <<<"$(select_model_codex --batch "$NON_INTERACTIVE_FLAG" "$em" "$cfg")"
      ;;
    opencode)
      em="${OPENCODE_PLAN_MODEL:-${CURSOR_PLAN_MODEL:-}}"
      tr -d '\r' <<<"$(select_model_opencode --batch "$NON_INTERACTIVE_FLAG" "$em" "$cfg")"
      ;;
    *)
      echo "Error: unsupported runtime for model selection: $RUNTIME" >&2
      return 1
      ;;
  esac
}

# Prebuilt agents live under WORKSPACE/.cursor/agents (or the runtime equivalent)
prebuilt_agents_root() {
  echo "$1/$AGENTS_ROOT_REL"
}

# List agent ids via agent-config-tool (enumerates agent directories with config.json)
# Args: $1 - workspace root path
# Returns: 0 on success (outputs ids), non-zero if the agent tool is missing
list_prebuilt_agent_ids() {
  local ws="$1"
  local root
  root="$(prebuilt_agents_root "$ws")"
  if [[ ! -f "$AGENT_CONFIG_TOOL" ]]; then
    echo "Error: shared agent tool missing: $AGENT_CONFIG_TOOL" >&2
    return 1
  fi
  bash "$AGENT_CONFIG_TOOL" list "$root" 2>/dev/null || true
}

# Validate config.json for a prebuilt agent id using agent-config-tool.
# Args: $1 - workspace root path, $2 - agent id
# Returns: 0 on success, non-zero on validation failure
validate_prebuilt_agent_config() {
  local ws="$1"
  local id="$2"
  local root
  root="$(prebuilt_agents_root "$ws")"
  bash "$AGENT_CONFIG_TOOL" validate "$root" "$id" "$ws"
}

# Read the model id declared in a validated prebuilt agent config.
# Args: $1 - workspace root path, $2 - agent id
# Returns: 0 on success (writes model id), non-zero on error
read_prebuilt_agent_model() {
  local ws="$1"
  local id="$2"
  local root
  root="$(prebuilt_agents_root "$ws")"
  bash "$AGENT_CONFIG_TOOL" model "$root" "$id"
}

# Format the prebuilt agent context block for CLI invocation (rules + skills).
# Args: $1 - workspace root path, $2 - agent id
# Returns: 0 on success (writes context), non-zero on error
format_prebuilt_agent_context_block() {
  local ws="$1"
  local id="$2"
  local root
  root="$(prebuilt_agents_root "$ws")"
  bash "$AGENT_CONFIG_TOOL" context "$root" "$id" "$ws"
}

# Interactive selection of a prebuilt agent id; prints selection on stdout.
# Args: $1 - workspace root path
# Returns: 0 after printing the selection, non-zero on error
prompt_select_prebuilt_agent() {
  local ws="$1"
  local list
  list="$(list_prebuilt_agent_ids "$ws")"
  if [[ -z "$list" ]]; then
    echo "Error: no prebuilt agents under $(prebuilt_agents_root "$ws")." >&2
    return 1
  fi
  if [[ ! -t 0 ]]; then
    echo "Error: --select-agent requires an interactive terminal. Use --agent <name> instead." >&2
    return 1
  fi
  if command -v fzf &>/dev/null; then
    local selected
    selected="$(printf '%s\n' "$list" | fzf --no-sort --height=20 --prompt="Prebuilt agent: " --header="Discovered under $AGENTS_ROOT_REL/" 2>/dev/null)" || true
    if [[ -z "$selected" ]]; then
      echo "Error: no prebuilt agent selected." >&2
      return 1
    fi
    echo "$selected"
    return 0
  fi
  echo "" >&2
  echo -e "${C_C}${C_BOLD}Prebuilt agents${C_RST} ${C_DIM}(${AGENTS_ROOT_REL})${C_RST}" >&2
  echo "" >&2
  local n=1
  local line
  local -a ids=()
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    ids+=("$line")
    local m
    m="$(read_prebuilt_agent_model "$ws" "$line" 2>/dev/null)" || m="?"
    printf "  ${C_G}%2d)${C_RST} %s  ${C_DIM}(model: %s)${C_RST}\n" "$n" "$line" "${m:-?}" >&2
    n=$((n + 1))
  done <<< "$list"
  echo "" >&2
  local selection_idx
  printf '%s' "${C_Y}${C_BOLD}Selection${C_RST}${C_DIM} [1]${C_RST}: " >&2
  read -r selection_idx </dev/tty 2>/dev/null || selection_idx="1"
  selection_idx="${selection_idx:-1}"
  if ! [[ "$selection_idx" =~ ^[0-9]+$ ]] || [[ "$selection_idx" -lt 1 ]] || [[ "$selection_idx" -gt ${#ids[@]} ]]; then
    echo "Error: invalid selection." >&2
    return 1
  fi
  printf '%s' "${ids[$((selection_idx - 1))]}"
}

# Decide whether to prompt for a prebuilt agent or a direct model selection.
# Args: $1 - workspace root path
# Returns: 0 on success, non-zero when prompt selection fails (rare)
prompt_agent_source_mode() {
  local ws="$1"
  local list
  list="$(list_prebuilt_agent_ids "$ws")"
  if [[ -z "$list" ]]; then
    return 0
  fi
  if [[ "$NON_INTERACTIVE_FLAG" == "1" ]]; then
    return 0
  fi
  if [[ -n "$PREBUILT_AGENT" || "$INTERACTIVE_SELECT_AGENT_FLAG" == "1" ]]; then
    return 0
  fi
  # Direct model from CLI: skip "prebuilt vs model" menu (--select-agent returns above first).
  if [[ -n "${PLAN_MODEL_CLI:-}" ]]; then
    return 0
  fi

  echo "" >&2
  echo -e "${C_C}${C_BOLD}Agent setup${C_RST}" >&2
  echo -e "${C_DIM}Prebuilt agents under ${AGENTS_ROOT_REL}${C_RST}" >&2
  echo "" >&2
  echo -e "  ${C_G}1)${C_RST} Use a prebuilt agent ${C_DIM}(recommended)${C_RST}" >&2
  echo -e "  ${C_G}2)${C_RST} Select a model directly" >&2
  echo "" >&2

  local mode_choice
  printf '%s' "${C_Y}${C_BOLD}Selection${C_RST}${C_DIM} [1]${C_RST}: " >&2
  read -r mode_choice </dev/tty 2>/dev/null || mode_choice="1"
  mode_choice="${mode_choice:-1}"
  case "$mode_choice" in
    1)
      INTERACTIVE_SELECT_AGENT_FLAG=1
      ;;
    2)
      ;;
    *)
      echo -e "${C_Y}Invalid selection; defaulting to prebuilt agent.${C_RST}" >&2
      INTERACTIVE_SELECT_AGENT_FLAG=1
      ;;
  esac
}
