# Agent selection helpers for run-plan.sh (sourced from run-plan-core).
# These functions are factored out to keep the main runner smaller.
#
# Public interface:
#   prompt_for_agent -- prints model id for the current RUNTIME (uses select_model_*).
#   prebuilt_agents_root, list_prebuilt_agent_ids, validate_prebuilt_agent_config -- agent dir discovery/validation.
#   read_prebuilt_agent_model, format_prebuilt_agent_context_block -- model and context from config.json.
#   prompt_select_prebuilt_agent, prompt_agent_source_mode -- interactive agent picking and mode selection.
#
# Source resolution:
#   The five agent helpers (prebuilt_agents_root, list_prebuilt_agent_ids,
#   validate_prebuilt_agent_config, read_prebuilt_agent_model,
#   format_prebuilt_agent_context_block) now call
#   ralph_agent_resolve_source internally and dispatch non-classic sources
#   through the matching adapter.  The existing (ws, id) signatures are
#   preserved so run-plan-core.sh callers are untouched.

if [[ -z "${RALPH_RUN_PLAN_AGENT_SOURCE_LOADED:-}" ]]; then
  _ralph_agent_source_dir=""
  if [[ -n "${SCRIPT_DIR:-}" && -d "$SCRIPT_DIR/agent-source" ]]; then
    _ralph_agent_source_dir="$SCRIPT_DIR"
  elif [[ -n "${REPO_ROOT:-}" && -d "$REPO_ROOT/bundle/.ralph/bash-lib/agent-source" ]]; then
    _ralph_agent_source_dir="$REPO_ROOT/bundle/.ralph/bash-lib"
  elif [[ -n "${RALPH_LIB_ROOT:-}" && -d "$RALPH_LIB_ROOT/agent-source" ]]; then
    _ralph_agent_source_dir="$RALPH_LIB_ROOT"
  else
    _ralph_agent_source_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    if [[ ! -d "$_ralph_agent_source_dir/agent-source" ]]; then
      _ralph_agent_source_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
    fi
  fi
  # shellcheck source=/dev/null
  source "$_ralph_agent_source_dir/agent-source/resolve-source.sh"
  # shellcheck source=/dev/null
  source "$_ralph_agent_source_dir/agent-source/frontmatter.sh"
  # shellcheck source=/dev/null
  source "$_ralph_agent_source_dir/agent-source/adapters/adapter-classic-config.sh"
  # shellcheck source=/dev/null
  source "$_ralph_agent_source_dir/agent-source/adapters/adapter-ralph-md.sh"
  unset _ralph_agent_source_dir
  RALPH_RUN_PLAN_AGENT_SOURCE_LOADED=1
fi

# Resolve the agent source and produce a config.json path, routing non-classic
# sources through the matching adapter.  Returns the cache path on stdout.
# Args: $1 - workspace, $2 - agent id, $3 - runtime
# Uses RALPH_AGENT_SOURCE (set by --agent-source) and RALPH_AGENT_SOURCE_ORDER.
# Sets _RALPH_AGENT_RESOLVED_KIND in the calling scope for downstream branching.
_ralph_resolve_agent_to_config_json() {
  local ws="$1"
  local id="$2"
  local runtime="$3"

  local resolved_kind resolved_path
  local resolve_rc
  resolved_kind=""
  resolved_path=""
  resolve_rc=0
  local resolve_out
  resolve_out="$(ralph_agent_resolve_source "$id" "$runtime" "$ws")" || resolve_rc=$?
  if [[ $resolve_rc -ne 0 ]]; then
    return $resolve_rc
  fi
  resolved_kind="${resolve_out%%	*}"
  resolved_path="${resolve_out#*	}"

  _RALPH_AGENT_RESOLVED_KIND="$resolved_kind"

  if [[ -z "$resolved_kind" || -z "$resolved_path" ]]; then
    echo "Error: agent source resolution returned empty kind or path for '$id'" >&2
    return 1
  fi

  local cache_dir="$ws/.ralph-workspace/artifacts/${RALPH_ARTIFACT_NS:-${RALPH_PLAN_KEY:-agent}}/agent-cache"
  mkdir -p "$cache_dir"

  case "$resolved_kind" in
    classic-config)
      local classic_result
      classic_result="$(agent_adapter_classic_config_to_config_json "$id" "$runtime" "$ws" "$cache_dir")" || return $?
      printf '%s\n' "$classic_result"
      ;;
    ralph-md|ralph-install|ralph-workspace|native-md)
      local layer="bundle"
      if [[ "$resolved_kind" == "ralph-workspace" || "$resolved_kind" == "ralph-install" ]]; then
        if [[ "$resolved_path" == "$ws/.ralph/"* || "$resolved_path" == "$ws/.ralph-workspace/"* ]]; then
          layer="root"
        fi
      fi
      local md_result
      md_result="$(agent_adapter_ralph_md_to_config_json "$id" "$runtime" "$ws" "$cache_dir" "$layer" "")" || return $?
      printf '%s\n' "$md_result"
      ;;
    explicit)
      local ext="${resolved_path##*.}"
      if [[ "$ext" == "json" ]]; then
        printf '%s\n' "$resolved_path"
      else
        local md_result
        md_result="$(agent_adapter_ralph_md_to_config_json "$id" "$runtime" "$ws" "$cache_dir" "root" "$resolved_path")" || return $?
        printf '%s\n' "$md_result"
      fi
      ;;
    *)
      echo "Error: unsupported agent source kind '$resolved_kind' for '$id'" >&2
      return 1
      ;;
  esac
}

# Exit with a clear message when non-interactive Claude/Codex runs have no model.
ralph_run_plan_die_unresolved_claude_codex_model() {
  local runtime="$1"
  local env_name=""
  case "$runtime" in
    claude) env_name="CLAUDE_PLAN_MODEL" ;;
    codex) env_name="CODEX_PLAN_MODEL" ;;
    *) env_name="PLAN_MODEL" ;;
  esac
  ralph_run_plan_log "ERROR: non-interactive run requires --model, ${env_name}, a non-empty agent config model, or a saved default (ralph models add ${runtime} <id>)"
  echo -e "${C_R}${C_BOLD}Non-interactive mode requires a model for ${runtime}.${C_RST}" >&2
  echo -e "${C_DIM}Provide --model <id>, set ${env_name} (or CURSOR_PLAN_MODEL), use a prebuilt agent with a non-empty model, or add a saved default via: ralph models add ${runtime} <id>${C_RST}" >&2
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
  case "${RUNTIME:-}" in
    claude|codex)
      local agent_model=""
      if [[ -n "${PREBUILT_AGENT:-}" ]]; then
        agent_model="$(read_prebuilt_agent_model "$WORKSPACE" "$PREBUILT_AGENT" 2>/dev/null || true)"
      fi
      ralph_claude_codex_non_interactive_model_resolved "$RUNTIME" "$agent_model"
      ;;
    antigravity)
      if [[ -n "${PREBUILT_AGENT:-}" ]]; then
        return 0
      fi
      ralph_antigravity_non_interactive_model_resolved
      ;;
    *)
      if [[ -n "${PREBUILT_AGENT:-}" ]]; then
        return 0
      fi
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

# Prebuilt agents root (classic config.json directory).
# Returns the runtime agents root path.  Source-aware callers should prefer
# ralph_agent_resolve_source for specific agents; this function remains for
# listing, config-tool integration, and backward compatibility.
prebuilt_agents_root() {
  if [[ -n "${AGENTS_ROOT:-}" && -d "${AGENTS_ROOT:-}" ]]; then
    echo "$AGENTS_ROOT"
  else
    echo "$1/$AGENTS_ROOT_REL"
  fi
}

# List agent ids, merging classic config directories and ralph-md sources.
# Args: $1 - workspace root path
# Returns: 0 on success (outputs ids), non-zero if the agent tool is missing
#   and no ralph-md sources are found
list_prebuilt_agent_ids() {
  local ws="$1"
  local root
  root="$(prebuilt_agents_root "$ws")"
  local classic_ids=""
  local ralph_md_ids=""
  local combined=""
  local have_classic=0
  local have_ralph_md=0

  if [[ -f "$AGENT_CONFIG_TOOL" ]]; then
    classic_ids="$(bash "$AGENT_CONFIG_TOOL" list "$root" 2>/dev/null || true)"
    have_classic=1
  fi

  local ralph_ws_dir="$ws/.ralph-workspace/agents"
  local ralph_install_dir="$ws/.ralph/agents"
  # Avoid scanning the user's global bundle agents by default.
  # This keeps listing deterministic for unit tests and isolated workspaces.
  local ralph_bundle_dir=""
  if [[ -n "${RALPH_HOME:-}" ]]; then
    ralph_bundle_dir="${RALPH_HOME}/bundle/.ralph/agents"
  fi

  local agent_file="" base="" id=""
  local agent_dirs=("$ralph_ws_dir" "$ralph_install_dir")
  if [[ -n "$ralph_bundle_dir" ]]; then
    agent_dirs+=("$ralph_bundle_dir")
  fi
  for agent_dir in "${agent_dirs[@]}"; do
    if [[ -d "$agent_dir" ]]; then
      for agent_file in "$agent_dir"/*.md; do
        [[ -f "$agent_file" ]] || continue
        base="$(basename "$agent_file")"
        id="${base%.md}"
        if [[ -n "$id" ]]; then
          ralph_md_ids="${ralph_md_ids}${id}"$'\n'
          have_ralph_md=1
        fi
      done
    fi
  done

  local runtime_root=""
  if [[ -n "${RUNTIME:-}" ]]; then
    runtime_root="$(ralph_resolve_runtime_root "$RUNTIME" "$ws" 2>/dev/null)" || runtime_root=""
    if [[ -n "$runtime_root" && -d "$runtime_root/agents" ]]; then
      for agent_file in "$runtime_root/agents"/*.md; do
        [[ -f "$agent_file" ]] || continue
        base="$(basename "$agent_file")"
        id="${base%.md}"
        if [[ -n "$id" ]]; then
          ralph_md_ids="${ralph_md_ids}${id}"$'\n'
          have_ralph_md=1
        fi
      done
    fi
  fi

  if [[ "$have_ralph_md" -eq 1 ]]; then
    combined="${classic_ids:+$classic_ids$'\n'}${ralph_md_ids}"
  elif [[ "$have_classic" -eq 1 ]]; then
    combined="$classic_ids"
  else
    if [[ ! -f "$AGENT_CONFIG_TOOL" ]]; then
      echo "Error: shared agent tool missing: $AGENT_CONFIG_TOOL" >&2
    else
      echo "Error: no agent sources found for listing" >&2
    fi
    return 1
  fi

  printf '%s\n' "$combined" | sort -u | sed '/^$/d'
}

# Validate the resolved agent source (classic or non-classic).
# Args: $1 - workspace root path, $2 - agent id
# Returns: 0 on success, non-zero on validation failure
validate_prebuilt_agent_config() {
  local ws="$1"
  local id="$2"
  local runtime="${RUNTIME:-}"

  if [[ -z "$runtime" ]]; then
    local root
    root="$(prebuilt_agents_root "$ws")"
    if [[ ! -f "$AGENT_CONFIG_TOOL" ]]; then
      echo "Error: shared agent tool missing: $AGENT_CONFIG_TOOL" >&2
      return 1
    fi
    bash "$AGENT_CONFIG_TOOL" validate "$root" "$id" "$ws"
    return $?
  fi

  local resolved_kind resolved_path resolve_out resolve_rc
  resolve_out="$(ralph_agent_resolve_source "$id" "$runtime" "$ws")" || resolve_rc=$?
  if [[ "${resolve_rc:-0}" -ne 0 ]]; then
    echo "Error: agent source not found for '$id' (runtime=$runtime)" >&2
    return 1
  fi
  resolved_kind="${resolve_out%%	*}"
  resolved_path="${resolve_out#*	}"

  case "$resolved_kind" in
    classic-config)
      local root
      root="$(prebuilt_agents_root "$ws")"
      if [[ ! -f "$AGENT_CONFIG_TOOL" ]]; then
        echo "Error: shared agent tool missing: $AGENT_CONFIG_TOOL" >&2
        return 1
      fi
      bash "$AGENT_CONFIG_TOOL" validate "$root" "$id" "$ws"
      ;;
    ralph-md|ralph-install|ralph-workspace|native-md|explicit)
      if [[ ! -r "$resolved_path" ]]; then
        echo "Error: agent source not readable: $resolved_path" >&2
        return 1
      fi
      local cache_dir="$ws/.ralph-workspace/artifacts/${RALPH_ARTIFACT_NS:-${RALPH_PLAN_KEY:-agent}}/agent-cache"
      local layer="bundle"
      if [[ "$resolved_kind" == "ralph-workspace" || "$resolved_kind" == "ralph-install" ]]; then
        if [[ "$resolved_path" == "$ws/.ralph/"* || "$resolved_path" == "$ws/.ralph-workspace/"* ]]; then
          layer="root"
        fi
      fi
      local result
      result="$(agent_adapter_ralph_md_to_config_json "$id" "$runtime" "$ws" "$cache_dir" "$layer" "")" || {
        echo "Error: ralph-md validation failed for '$id'" >&2
        return 1
      }
      return 0
      ;;
    *)
      echo "Error: unsupported agent source kind '$resolved_kind' for '$id'" >&2
      return 1
      ;;
  esac
}

# Read the model id for a resolved agent (classic or non-classic source).
# Args: $1 - workspace root path, $2 - agent id
# Returns: 0 on success (writes model id), non-zero on error
read_prebuilt_agent_model() {
  local ws="$1"
  local id="$2"
  local runtime="${RUNTIME:-}"

  if [[ -z "$runtime" ]]; then
    local root
    root="$(prebuilt_agents_root "$ws")"
    if [[ ! -f "$AGENT_CONFIG_TOOL" ]]; then
      echo "Error: shared agent tool missing: $AGENT_CONFIG_TOOL" >&2
      return 1
    fi
    bash "$AGENT_CONFIG_TOOL" model "$root" "$id"
    return $?
  fi

  local resolve_out resolve_rc
  resolve_out="$(ralph_agent_resolve_source "$id" "$runtime" "$ws")" || resolve_rc=$?
  if [[ "${resolve_rc:-0}" -ne 0 ]]; then
    echo "Error: agent source not found for '$id'" >&2
    return 1
  fi
  local resolved_kind="${resolve_out%%	*}"
  local resolved_path="${resolve_out#*	}"

  case "$resolved_kind" in
    classic-config)
      local root
      root="$(prebuilt_agents_root "$ws")"
      if [[ ! -f "$AGENT_CONFIG_TOOL" ]]; then
        echo "Error: shared agent tool missing: $AGENT_CONFIG_TOOL" >&2
        return 1
      fi
      bash "$AGENT_CONFIG_TOOL" model "$root" "$id"
      ;;
    ralph-md|ralph-install|ralph-workspace|native-md|explicit)
      local ext="${resolved_path##*.}"
      if [[ "$ext" == "json" ]]; then
        if command -v jq &>/dev/null; then
          jq -r '.model // ""' "$resolved_path" 2>/dev/null || true
        else
          grep -o '"model"[[:space:]]*:[[:space:]]*"[^"]*"' "$resolved_path" 2>/dev/null | head -1 | sed 's/.*:[[:space:]]*"\(.*\)"/\1/' || true
        fi
      else
        agent_source_fm_model "$resolved_path" "$runtime"
      fi
      ;;
    *)
      echo "Error: unsupported agent source kind '$resolved_kind' for model read" >&2
      return 1
      ;;
  esac
}

# Read reasoning_effort for a resolved agent (classic or non-classic source).
read_prebuilt_agent_reasoning_effort() {
  local ws="$1"
  local id="$2"
  local runtime="${RUNTIME:-}"

  if [[ -z "$runtime" ]]; then
    local root
    root="$(prebuilt_agents_root "$ws")"
    if [[ ! -f "$AGENT_CONFIG_TOOL" ]]; then
      echo "Error: shared agent tool missing: $AGENT_CONFIG_TOOL" >&2
      return 1
    fi
    bash "$AGENT_CONFIG_TOOL" reasoning-effort "$root" "$id" 2>/dev/null || true
    return 0
  fi

  local resolve_out resolve_rc
  resolve_out="$(ralph_agent_resolve_source "$id" "$runtime" "$ws")" || resolve_rc=$?
  if [[ "${resolve_rc:-0}" -ne 0 ]]; then
    return 0
  fi
  local resolved_kind="${resolve_out%%	*}"
  local resolved_path="${resolve_out#*	}"

  case "$resolved_kind" in
    classic-config)
      local root
      root="$(prebuilt_agents_root "$ws")"
      if [[ ! -f "$AGENT_CONFIG_TOOL" ]]; then
        return 0
      fi
      bash "$AGENT_CONFIG_TOOL" reasoning-effort "$root" "$id" 2>/dev/null || true
      ;;
    ralph-md|ralph-install|ralph-workspace|native-md|explicit)
      local ext="${resolved_path##*.}"
      if [[ "$ext" == "json" ]]; then
        if command -v jq &>/dev/null; then
          jq -r '.reasoning_effort // ""' "$resolved_path" 2>/dev/null || true
        else
          grep -o '"reasoning_effort"[[:space:]]*:[[:space:]]*"[^"]*"' "$resolved_path" 2>/dev/null | head -1 | sed 's/.*:[[:space:]]*"\(.*\)"/\1/' || true
        fi
      else
        agent_source_fm_scalar "$resolved_path" "reasoning_effort"
      fi
      ;;
    *)
      return 0
      ;;
  esac
}

# Format the agent context block for CLI invocation (rules + skills).
# Resolves the agent source and routes through the matching adapter.
# Args: $1 - workspace root path, $2 - agent id
# Returns: 0 on success (writes context), non-zero on error
format_prebuilt_agent_context_block() {
  local ws="$1"
  local id="$2"
  local runtime="${RUNTIME:-}"

  if [[ -z "$runtime" ]]; then
    local root
    root="$(prebuilt_agents_root "$ws")"
    if [[ ! -f "$AGENT_CONFIG_TOOL" ]]; then
      echo "Error: shared agent tool missing: $AGENT_CONFIG_TOOL" >&2
      return 1
    fi
    bash "$AGENT_CONFIG_TOOL" context "$root" "$id" "$ws"
    return $?
  fi

  local resolve_out resolve_rc
  resolve_out="$(ralph_agent_resolve_source "$id" "$runtime" "$ws")" || resolve_rc=$?
  if [[ "${resolve_rc:-0}" -ne 0 ]]; then
    echo "Error: agent source not found for '$id'" >&2
    return 1
  fi
  local resolved_kind="${resolve_out%%	*}"
  local resolved_path="${resolve_out#*	}"

  local cache_dir="$ws/.ralph-workspace/artifacts/${RALPH_ARTIFACT_NS:-${RALPH_PLAN_KEY:-agent}}/agent-cache"

  case "$resolved_kind" in
    classic-config)
      local root
      root="$(prebuilt_agents_root "$ws")"
      if [[ ! -f "$AGENT_CONFIG_TOOL" ]]; then
        echo "Error: shared agent tool missing: $AGENT_CONFIG_TOOL" >&2
        return 1
      fi
      bash "$AGENT_CONFIG_TOOL" context "$root" "$id" "$ws"
      ;;
    ralph-md|ralph-install|ralph-workspace|native-md|explicit)
      mkdir -p "$cache_dir/$id"
      local layer="bundle"
      if [[ "$resolved_kind" == "ralph-workspace" || "$resolved_kind" == "ralph-install" ]]; then
        if [[ "$resolved_path" == "$ws/.ralph/"* || "$resolved_path" == "$ws/.ralph-workspace/"* ]]; then
          layer="root"
        fi
      fi
      local config_path
      if [[ "$resolved_kind" == "explicit" && "${resolved_path##*.}" == "json" ]]; then
        config_path="$resolved_path"
      else
        config_path="$(agent_adapter_ralph_md_to_config_json "$id" "$runtime" "$ws" "$cache_dir" "$layer" "")" || {
          echo "Error: ralph-md context generation failed for '$id'" >&2
          return 1
        }
      fi
      if [[ ! -f "$AGENT_CONFIG_TOOL" ]]; then
        echo "Error: shared agent tool missing: $AGENT_CONFIG_TOOL" >&2
        return 1
      fi
      if [[ ! -f "$cache_dir/$id/config.json" ]]; then
        ln -sf "$config_path" "$cache_dir/$id/config.json" 2>/dev/null || cp "$config_path" "$cache_dir/$id/config.json"
      fi
      bash "$AGENT_CONFIG_TOOL" context "$cache_dir" "$id" "$ws"
      ;;
    *)
      echo "Error: unsupported agent source kind '$resolved_kind' for context block" >&2
      return 1
      ;;
  esac
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
  read -r selection_idx 2>/dev/null || selection_idx="1"
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
  # Without an attached terminal, `read` below would block forever waiting for
  # input that never arrives (piped/headless/caffeinate-wrapped runs). Skip the
  # menu and let default agent/model resolution proceed, mirroring the TTY guard
  # in prompt_select_prebuilt_agent.
  if [[ ! -t 0 ]]; then
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
  read -r mode_choice 2>/dev/null || mode_choice="1"
  mode_choice="${mode_choice:-1}"
  case "$mode_choice" in
    1)
      INTERACTIVE_SELECT_AGENT_FLAG=1
      ;;
    2)
      INTERACTIVE_SELECT_MODEL_FLAG=1
      ;;
    *)
      echo -e "${C_Y}Invalid selection; defaulting to prebuilt agent.${C_RST}" >&2
      INTERACTIVE_SELECT_AGENT_FLAG=1
      ;;
  esac
}
