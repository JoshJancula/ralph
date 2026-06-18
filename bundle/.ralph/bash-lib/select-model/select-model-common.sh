#!/usr/bin/env bash

if [[ -z "${_SELECT_MODEL_DIR:-}" ]]; then
  _SELECT_MODEL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fi

_model_store_lib="${_SELECT_MODEL_DIR}/model-store.sh"
if [[ -r "$_model_store_lib" ]]; then
  # shellcheck source=/dev/null
  source "$_model_store_lib"
fi

_select_model_read_rp() {
  local prompt="$1"
  local _d="$2"
  if [[ -r /dev/tty ]]; then
    read -rp "$prompt" "$_d" </dev/tty 2>/dev/null || return 1
  else
    read -rp "$prompt" "$_d" || return 1
  fi
}

_select_model_load_saved_models() {
  local runtime="$1"
  local -n _out_models="$2"
  _out_models=()
  command -v jq >/dev/null 2>&1 || return 0
  declare -F ralph_model_store_list >/dev/null 2>&1 || return 0

  local model
  while IFS= read -r model || [[ -n "$model" ]]; do
    [[ -n "$model" ]] && _out_models+=("$model")
  done < <(ralph_model_store_list "$runtime" 2>/dev/null)
}

_select_model_is_saved() {
  local runtime="$1"
  local model="$2"
  local saved=()
  _select_model_load_saved_models "$runtime" saved
  local entry
  for entry in "${saved[@]}"; do
    [[ "$entry" == "$model" ]] && return 0
  done
  return 1
}

_select_model_offer_save() {
  local runtime="$1"
  local model="$2"
  command -v jq >/dev/null 2>&1 || return 0
  declare -F ralph_model_store_add >/dev/null 2>&1 || return 0
  [[ -n "$model" ]] || return 0
  _select_model_is_saved "$runtime" "$model" && return 0

  local choice
  choice="$(ralph_menu_select --prompt "Save \"$model\" for future use?" --default 2 -- "yes" "no")" || return 0
  if [[ "$choice" == "yes" ]]; then
    ralph_model_store_add "$runtime" "$model" >/dev/null 2>&1 || true
  fi
}

_select_model_read_manual_id() {
  local prompt="$1"
  local _out_var="$2"
  local value=""
  if ! _select_model_read_rp "$prompt" value; then
    printf -v "$_out_var" '%s' ""
    return 1
  fi
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf -v "$_out_var" '%s' "$value"
  return 0
}

# Saved-model-driven interactive picker for Claude/Codex.
# When saved models exist: menu of saved ids plus custom entry.
# When none exist: prompt directly for manual entry.
# Newly entered models may be saved for future use.
_select_model_saved_runtime_interactive() {
  local runtime="$1"
  local header_title="$2"
  local header_hint="$3"
  local menu_prompt="$4"
  local manual_prompt="$5"
  local custom_placeholder="${6:-Enter custom model id}"

  echo "" >&2
  echo -e "${C_C:-}${C_BOLD:-}${header_title}${C_RST:-}" >&2
  echo -e "${C_DIM:-}${header_hint}${C_RST:-}" >&2

  local saved=()
  _select_model_load_saved_models "$runtime" saved

  if [[ ${#saved[@]} -eq 0 ]]; then
    local custom_model=""
    while true; do
      if ! _select_model_read_manual_id "$manual_prompt" custom_model; then
        echo ""
        return 0
      fi
      if [[ -z "$custom_model" ]]; then
        echo -e "${C_R:-}Model cannot be empty.${C_RST:-}" >&2
        continue
      fi
      _select_model_offer_save "$runtime" "$custom_model"
      echo "$custom_model"
      return 0
    done
  fi

  local selection custom_model
  while true; do
    selection="$(ralph_menu_select --prompt "$menu_prompt" --default 1 -- "${saved[@]}" "$custom_placeholder")"
    if [[ -z "$selection" ]]; then
      echo ""
      return 0
    fi
    if [[ "$selection" == "$custom_placeholder" ]]; then
      if ! _select_model_read_manual_id "$manual_prompt" custom_model; then
        echo ""
        return 0
      fi
      if [[ -z "$custom_model" ]]; then
        echo -e "${C_R:-}Model cannot be empty.${C_RST:-}" >&2
        continue
      fi
      _select_model_offer_save "$runtime" "$custom_model"
      echo "$custom_model"
      return 0
    fi
    echo "$selection"
    return 0
  done
}

# Claude/Codex run-plan resolution (no Cursor/OpenCode):
# cli_model, runtime env, agent config when non-empty, saved-model default, interactive prompt.
_select_model_resolve_claude_codex_chain() {
  local runtime="$1" cli_model="$2" env_m="$3" agent_model="$4" ni="$5"

  if [[ -n "$cli_model" ]]; then
    printf '%s\n' "$cli_model"
    return 0
  fi

  local resolved="${env_m}"
  [[ -z "$resolved" && -n "${CURSOR_PLAN_MODEL:-}" ]] && resolved="${CURSOR_PLAN_MODEL}"
  if [[ -n "$resolved" ]]; then
    printf '%s\n' "$resolved"
    return 0
  fi
  if [[ -n "$agent_model" ]]; then
    printf '%s\n' "$agent_model"
    return 0
  fi

  local saved=""
  if declare -F ralph_model_store_default >/dev/null 2>&1; then
    saved="$(ralph_model_store_default "$runtime" 2>/dev/null || true)"
  fi
  if [[ -n "$saved" ]]; then
    printf '%s\n' "$saved"
    return 0
  fi

  if [[ "$ni" == "1" ]]; then
    return 1
  fi
  if [[ ! -r /dev/tty ]]; then
    return 1
  fi

  local picked=""
  case "$runtime" in
    claude) picked="$(_claude_select_model_interactive)" ;;
    codex) picked="$(_codex_select_model_interactive)" ;;
    *)
      echo "Error: unsupported runtime for Claude/Codex model resolution: $runtime" >&2
      return 1
      ;;
  esac
  picked="$(tr -d '\r' <<<"${picked:-}")"
  [[ -n "$picked" ]] || return 1
  printf '%s\n' "$picked"
  return 0
}

# Resolve Claude/Codex model for run-plan (includes PLAN_MODEL_CLI when set).
ralph_resolve_claude_codex_plan_model() {
  local runtime="$1"
  local agent_model="${2:-}"
  local env_m=""

  case "$runtime" in
    claude) env_m="${CLAUDE_PLAN_MODEL:-}" ;;
    codex) env_m="${CODEX_PLAN_MODEL:-}" ;;
    *)
      echo "Error: ralph_resolve_claude_codex_plan_model requires runtime claude or codex." >&2
      return 1
      ;;
  esac

  _select_model_resolve_claude_codex_chain \
    "$runtime" \
    "${PLAN_MODEL_CLI:-}" \
    "$env_m" \
    "$agent_model" \
    "${NON_INTERACTIVE_FLAG:-0}"
}

# True when non-interactive run-plan already has a resolvable Claude/Codex model.
ralph_claude_codex_non_interactive_model_resolved() {
  local runtime="$1"
  local agent_model="${2:-}"
  local env_m=""

  case "$runtime" in
    claude) env_m="${CLAUDE_PLAN_MODEL:-}" ;;
    codex) env_m="${CODEX_PLAN_MODEL:-}" ;;
    *) return 1 ;;
  esac

  local resolved=""
  resolved="$(
    _select_model_resolve_claude_codex_chain \
      "$runtime" \
      "${PLAN_MODEL_CLI:-}" \
      "$env_m" \
      "$agent_model" \
      "1" 2>/dev/null || true
  )"
  [[ -n "$resolved" ]]
}

# Antigravity run-plan resolution chain.
# Precedence: explicit --model (PLAN_MODEL_CLI), ANTIGRAVITY_PLAN_MODEL,
# OPENCODE_PLAN_MODEL, CURSOR_PLAN_MODEL, prebuilt agent config model,
# interactive picker (non-interactive only when /dev/tty is readable).
_select_model_resolve_antigravity_chain() {
  local cli_model="$1" env_m="$2" agent_model="$3" ni="$4"

  if [[ -n "$cli_model" ]]; then
    printf '%s\n' "$cli_model"
    return 0
  fi

  local resolved="${env_m}"
  [[ -z "$resolved" && -n "${OPENCODE_PLAN_MODEL:-}" ]] && resolved="${OPENCODE_PLAN_MODEL}"
  [[ -z "$resolved" && -n "${CURSOR_PLAN_MODEL:-}" ]] && resolved="${CURSOR_PLAN_MODEL}"
  if [[ -n "$resolved" ]]; then
    printf '%s\n' "$resolved"
    return 0
  fi
  if [[ -n "$agent_model" ]]; then
    printf '%s\n' "$agent_model"
    return 0
  fi

  if [[ "$ni" == "1" ]]; then
    return 1
  fi
  if [[ ! -r /dev/tty ]]; then
    return 1
  fi

  local picked=""
  picked="$(_antigravity_select_model_interactive)"
  picked="$(tr -d '\r' <<<"${picked:-}")"
  [[ -n "$picked" ]] || return 1
  printf '%s\n' "$picked"
  return 0
}

# Resolve Antigravity model for run-plan (includes PLAN_MODEL_CLI when set).
ralph_resolve_antigravity_plan_model() {
  local agent_model="${1:-}"
  _select_model_resolve_antigravity_chain \
    "${PLAN_MODEL_CLI:-}" \
    "${ANTIGRAVITY_PLAN_MODEL:-}" \
    "$agent_model" \
    "${NON_INTERACTIVE_FLAG:-0}"
}

# True when non-interactive run-plan already has a resolvable Antigravity model.
ralph_antigravity_non_interactive_model_resolved() {
  local agent_model="${1:-}"
  local resolved=""
  resolved="$(
    _select_model_resolve_antigravity_chain \
      "${PLAN_MODEL_CLI:-}" \
      "${ANTIGRAVITY_PLAN_MODEL:-}" \
      "$agent_model" \
      "1" 2>/dev/null || true
  )"
  [[ -n "$resolved" ]]
}

_select_model_batch_dispatch() {
  local runtime="$1" env_var="$2"
  shift 2
  local ni="$1" env_m="$2" cfg="$3"

  case "$runtime" in
    claude|codex)
      _select_model_resolve_claude_codex_chain "$runtime" "" "$env_m" "$cfg" "$ni" || true
      return
      ;;
    antigravity)
      _select_model_resolve_antigravity_chain "" "$env_m" "$cfg" "$ni" || true
      return
      ;;
  esac

  local resolved="${env_m}"
  [[ -z "$resolved" && -n "${CURSOR_PLAN_MODEL:-}" ]] && resolved="${CURSOR_PLAN_MODEL}"
  if [[ "$ni" == "1" ]]; then
    echo "${resolved:-$cfg}"
    return
  fi
  [[ -n "$resolved" ]] && { echo "$resolved"; return; }
  [[ ! -r /dev/tty ]] && { echo "$cfg"; return; }

  case "$runtime" in
    cursor) _cursor_select_model_interactive ;;
    opencode) _opencode_select_model_interactive ;;
  esac
}

export -f \
  _select_model_read_rp \
  _select_model_load_saved_models \
  _select_model_is_saved \
  _select_model_offer_save \
  _select_model_read_manual_id \
  _select_model_saved_runtime_interactive \
  _select_model_resolve_claude_codex_chain \
  ralph_resolve_claude_codex_plan_model \
  ralph_claude_codex_non_interactive_model_resolved \
  _select_model_resolve_antigravity_chain \
  ralph_resolve_antigravity_plan_model \
  ralph_antigravity_non_interactive_model_resolved \
  _select_model_batch_dispatch \
  2>/dev/null || true
