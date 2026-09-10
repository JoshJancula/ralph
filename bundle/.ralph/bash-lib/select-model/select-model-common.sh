#!/usr/bin/env bash

if [[ -z "${_SELECT_MODEL_DIR:-}" ]]; then
  _SELECT_MODEL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fi

_model_store_lib="${_SELECT_MODEL_DIR}/model-store.sh"
if [[ -r "$_model_store_lib" ]]; then
  # shellcheck source=/dev/null
  source "$_model_store_lib"
fi

# Built-in Claude model aliases. Claude Code resolves each to the latest model
# in that family, so the list stays correct without pinning dated model ids.
# Exact catalog (order matters for defaults-only preselect): haiku sonnet opus fable.
# Defined here (not in select-model-claude.sh) so consumers that source only the
# common lib -- notably ralph_select_model_list_discovered -- can see it.
if [[ -z "${_CLAUDE_DEFAULT_MODELS+x}" ]]; then
  _CLAUDE_DEFAULT_MODELS=("haiku" "sonnet" "opus" "fable")
fi
# Export so subprocesses that inherit ralph_select_model_list_discovered via
# export -f also see the Claude base catalog (bash arrays are not inherited
# with export -f alone).
export _CLAUDE_DEFAULT_MODELS

# Append each entry from the named defaults array that is not already present
# in the named menu/saved array. Used by the interactive Claude picker and by
# ralph_select_model_list_discovered so both paths share one merge rule:
# saved IDs first, then missing aliases exactly once. Codex never passes a
# Claude defaults array, so it stays saved-store-only.
_select_model_append_missing_defaults() {
  local -n _append_menu_ref="$1"
  local -n _append_defaults_ref="$2"
  local default_entry existing seen
  for default_entry in "${_append_defaults_ref[@]+"${_append_defaults_ref[@]}"}"; do
    [[ -z "$default_entry" ]] && continue
    seen=0
    for existing in "${_append_menu_ref[@]+"${_append_menu_ref[@]}"}"; do
      if [[ "$existing" == "$default_entry" ]]; then
        seen=1
        break
      fi
    done
    [[ "$seen" -eq 0 ]] && _append_menu_ref+=("$default_entry")
  done
}

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

# Saved-model catalog interactive picker for Claude/Codex.
# Menu order: saved models first (if any), then any supplied defaults that are
# not exact duplicates of a saved entry, then the custom-entry placeholder.
# When the menu is defaults-only, the supplied default index preselects.
# When saved models are present, index 1 (first saved entry) is preselected.
# When neither saved nor defaults exist: prompt directly for manual entry.
# Newly entered models may be saved for future use.
# $7 (optional): name of an array variable holding default menu choices.
# $8 (optional): 1-based index into that array to preselect when defaults-only.
_select_model_saved_runtime_interactive() {
  local runtime="$1"
  local header_title="$2"
  local header_hint="$3"
  local menu_prompt="$4"
  local manual_prompt="$5"
  local custom_placeholder="${6:-Enter custom model id}"
  local defaults_var="${7:-}"
  local defaults_default_index="${8:-1}"

  echo "" >&2
  echo -e "${C_C:-}${C_BOLD:-}${header_title}${C_RST:-}" >&2
  echo -e "${C_DIM:-}${header_hint}${C_RST:-}" >&2

  local saved=()
  _select_model_load_saved_models "$runtime" saved

  local menu_choices=("${saved[@]}")
  local default_index=1
  if [[ -n "$defaults_var" ]]; then
    local -n _defaults_ref="$defaults_var"
    if [[ ${#menu_choices[@]} -eq 0 ]]; then
      menu_choices=("${_defaults_ref[@]}")
      default_index="$defaults_default_index"
    else
      # Claude passes _CLAUDE_DEFAULT_MODELS here; Codex leaves defaults_var empty.
      _select_model_append_missing_defaults menu_choices _defaults_ref
    fi
  fi

  if [[ ${#menu_choices[@]} -eq 0 ]]; then
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
    selection="$(ralph_menu_select --prompt "$menu_prompt" --default "$default_index" -- "${menu_choices[@]}" "$custom_placeholder")"
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

# Standard-plan model resolution (Claude/Codex):
# CLI --model > TODO model: >
#   attended TTY: interactive picker (full saved-model catalog + custom entry)
#   non-interactive / no TTY: first saved model, else runtime-native default
# Profile-derived models and *_PLAN_MODEL env are not rungs.
# models.json is a selection catalog for attended runs -- never auto-applied
# from index 0 when a TTY is available. Native default: emit empty stdout
# (omit Ralph --model) so the runtime uses its own default.
_select_model_resolve_claude_codex_chain() {
  local runtime="$1" cli_model="$2" todo_model="$3" ni="${4:-0}"

  if [[ -n "$cli_model" ]]; then
    printf '%s\n' "$cli_model"
    return 0
  fi
  if [[ -n "$todo_model" ]]; then
    printf '%s\n' "$todo_model"
    return 0
  fi

  # Attended: always show the picker so the operator chooses from the saved
  # catalog (or enters a custom id). Do not silently take models.json[0].
  if [[ "$ni" != "1" && -r /dev/tty ]]; then
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
    [[ -n "$picked" ]] || return 0
    printf '%s\n' "$picked"
    return 0
  fi

  # Non-interactive / no TTY: first saved model, else native default (empty).
  local saved=""
  if declare -F ralph_model_store_default >/dev/null 2>&1; then
    saved="$(ralph_model_store_default "$runtime" 2>/dev/null || true)"
  fi
  if [[ -n "$saved" ]]; then
    printf '%s\n' "$saved"
  fi
  return 0
}

# Resolve Claude/Codex model for standard-plan runs.
# Precedence inputs: PLAN_MODEL_CLI (CLI --model), PLAN_TODO_MODEL (TODO model:).
# Legacy $2 was a profile/agent model and is ignored.
ralph_resolve_claude_codex_plan_model() {
  local runtime="$1"
  # Intentionally unused: was agent/profile model (not a standard-plan rung).
  local _legacy_agent_model="${2:-}"

  case "$runtime" in
    claude|codex) ;;
    *)
      echo "Error: ralph_resolve_claude_codex_plan_model requires runtime claude or codex." >&2
      return 1
      ;;
  esac

  _select_model_resolve_claude_codex_chain \
    "$runtime" \
    "${PLAN_MODEL_CLI:-}" \
    "${PLAN_TODO_MODEL:-}" \
    "${NON_INTERACTIVE_FLAG:-0}"
}

# True when non-interactive run-plan already has an explicit Claude/Codex model
# (CLI, TODO, or saved). Empty native default does not count as explicit.
ralph_claude_codex_non_interactive_model_resolved() {
  local runtime="$1"
  # Legacy $2 agent/profile model ignored.
  local _legacy_agent_model="${2:-}"

  case "$runtime" in
    claude|codex) ;;
    *) return 1 ;;
  esac

  local resolved=""
  resolved="$(
    _select_model_resolve_claude_codex_chain \
      "$runtime" \
      "${PLAN_MODEL_CLI:-}" \
      "${PLAN_TODO_MODEL:-}" \
      "1" 2>/dev/null || true
  )"
  [[ -n "$resolved" ]]
}

# Antigravity standard-plan resolution:
# CLI --model > TODO model: > runtime-native default (agy's own default).
# No saved-model store for antigravity. Profile/env are not rungs.
_select_model_resolve_antigravity_chain() {
  local cli_model="$1" todo_model="$2" ni="${3:-0}"

  if [[ -n "$cli_model" ]]; then
    printf '%s\n' "$cli_model"
    return 0
  fi
  if [[ -n "$todo_model" ]]; then
    printf '%s\n' "$todo_model"
    return 0
  fi

  # Native default: omit Ralph --model so agy uses its own default.
  if [[ "$ni" == "1" ]]; then
    return 0
  fi
  # Only prompt when we truly have an attended terminal. A non-tty stdin
  # (piped/background/caffeinate-wrapped run) must not reach the picker, which
  # would otherwise block on /dev/tty or crash interactive-select with an
  # unbound-variable read. Emit an empty model (exit 0) so the caller proceeds
  # and agy uses its own default, matching cursor/opencode batch behavior.
  if [[ ! -t 0 || ! -r /dev/tty ]]; then
    return 0
  fi

  local picked=""
  picked="$(_antigravity_select_model_interactive)"
  picked="$(tr -d '\r' <<<"${picked:-}")"
  [[ -n "$picked" ]] || return 0
  printf '%s\n' "$picked"
  return 0
}

# Resolve Antigravity model for standard-plan runs (PLAN_MODEL_CLI / PLAN_TODO_MODEL).
# Legacy $1 was a profile/agent model and is ignored.
ralph_resolve_antigravity_plan_model() {
  local _legacy_agent_model="${1:-}"
  _select_model_resolve_antigravity_chain \
    "${PLAN_MODEL_CLI:-}" \
    "${PLAN_TODO_MODEL:-}" \
    "${NON_INTERACTIVE_FLAG:-0}"
}

# True when non-interactive Antigravity has an explicit model (CLI or TODO).
# Empty native default (agy default) does not count as explicit.
ralph_antigravity_non_interactive_model_resolved() {
  local _legacy_agent_model="${1:-}"
  local resolved=""
  resolved="$(
    _select_model_resolve_antigravity_chain \
      "${PLAN_MODEL_CLI:-}" \
      "${PLAN_TODO_MODEL:-}" \
      "1" 2>/dev/null || true
  )"
  [[ -n "$resolved" ]]
}

# Staged graph/orchestration/workflow model resolution (Claude/Codex):
# stage/voter model: > saved-model default > runtime-native default.
# Global CLI --model, profile models, and *_PLAN_MODEL env are not rungs.
# PLAN_STAGE_MODEL carries the authored stage or voter model when set by the
# orchestrator / graph spawn path.
# An explicitly passed empty model pin must stay empty (runtime-only TODO switch)
# and must not fall back through ${1:-${PLAN_STAGE_MODEL:-}}.
ralph_resolve_staged_claude_codex_plan_model() {
  local runtime="$1"
  local stage_model
  if [[ $# -ge 2 ]]; then
    stage_model="$2"
  else
    stage_model="${PLAN_STAGE_MODEL:-}"
  fi

  case "$runtime" in
    claude|codex) ;;
    *)
      echo "Error: ralph_resolve_staged_claude_codex_plan_model requires runtime claude or codex." >&2
      return 1
      ;;
  esac

  # Empty CLI slot: staged runs reject global --model at the entrypoint.
  _select_model_resolve_claude_codex_chain \
    "$runtime" \
    "" \
    "$stage_model" \
    "${NON_INTERACTIVE_FLAG:-0}"
}

# Staged Antigravity: stage/voter model: > runtime-native default (no saved store).
ralph_resolve_staged_antigravity_plan_model() {
  local stage_model
  if [[ $# -ge 1 ]]; then
    stage_model="$1"
  else
    stage_model="${PLAN_STAGE_MODEL:-}"
  fi
  _select_model_resolve_antigravity_chain \
    "" \
    "$stage_model" \
    "${NON_INTERACTIVE_FLAG:-0}"
}

# Staged Cursor/OpenCode: stage/voter model: > runtime-native default (no saved store).
ralph_resolve_staged_cursor_opencode_plan_model() {
  local stage_model
  if [[ $# -ge 1 ]]; then
    stage_model="$1"
  else
    stage_model="${PLAN_STAGE_MODEL:-}"
  fi
  printf '%s\n' "$stage_model"
}

# Unified staged resolver for orchestration/graph stage and consensus voter models.
# Precedence: stage/voter model: > saved (claude/codex only) > native default.
# Profile fallback is intentionally absent.
# Explicit empty $2 means "no pin" (saved/native), not "fall back to PLAN_STAGE_MODEL".
ralph_resolve_staged_plan_model() {
  local runtime="$1"
  local stage_model
  if [[ $# -ge 2 ]]; then
    stage_model="$2"
  else
    stage_model="${PLAN_STAGE_MODEL:-}"
  fi

  case "$runtime" in
    claude|codex)
      ralph_resolve_staged_claude_codex_plan_model "$runtime" "$stage_model"
      ;;
    antigravity)
      ralph_resolve_staged_antigravity_plan_model "$stage_model"
      ;;
    cursor|opencode)
      ralph_resolve_staged_cursor_opencode_plan_model "$stage_model"
      ;;
    *)
      echo "Error: ralph_resolve_staged_plan_model unsupported runtime: $runtime" >&2
      return 1
      ;;
  esac
}

# Batch dispatch for select_model_* --batch.
# Standard precedence: PLAN_MODEL_CLI > PLAN_TODO_MODEL > saved (claude/codex) > native.
# Positional env_m/cfg args are ignored (legacy profile/env rungs removed).
_select_model_batch_dispatch() {
  local runtime="$1" env_var="$2"
  shift 2
  local ni="$1"
  local _legacy_env_m="${2:-}"
  local _legacy_cfg="${3:-}"

  case "$runtime" in
    claude|codex)
      _select_model_resolve_claude_codex_chain \
        "$runtime" \
        "${PLAN_MODEL_CLI:-}" \
        "${PLAN_TODO_MODEL:-}" \
        "$ni" || true
      return
      ;;
    antigravity)
      _select_model_resolve_antigravity_chain \
        "${PLAN_MODEL_CLI:-}" \
        "${PLAN_TODO_MODEL:-}" \
        "$ni" || true
      return
      ;;
  esac

  local resolved="${PLAN_MODEL_CLI:-}"
  [[ -z "$resolved" && -n "${PLAN_TODO_MODEL:-}" ]] && resolved="${PLAN_TODO_MODEL}"
  if [[ "$ni" == "1" ]]; then
    echo "${resolved}"
    return
  fi
  [[ -n "$resolved" ]] && { echo "$resolved"; return; }
  # Native default when unattended / no tty.
  [[ ! -r /dev/tty ]] && { echo ""; return; }

  case "$runtime" in
    cursor) _cursor_select_model_interactive ;;
    opencode) _opencode_select_model_interactive ;;
  esac
}

# List discovered model strings for a runtime (one per line). Does not prompt.
# Exit 0 when discovery ran (list may be empty). Exit 1 when the runtime CLI
# needed for discovery is unavailable. Claude/Codex use the saved-model store
# only (empty store is exit 0). Antigravity strings are preserved byte-for-byte.
ralph_select_model_list_discovered() {
  local runtime="${1:-}"
  case "$runtime" in
    cursor)
      if ! declare -F _cursor_detect_cli >/dev/null 2>&1 || ! declare -F _cursor_list_models >/dev/null 2>&1; then
        return 1
      fi
      _cursor_detect_cli
      if [[ -z "${RALPH_SM_CURSOR_CLI:-}" ]]; then
        return 1
      fi
      _cursor_list_models
      return 0
      ;;
    opencode)
      if ! declare -F _opencode_list_models_from_cli >/dev/null 2>&1; then
        return 1
      fi
      if ! command -v opencode >/dev/null 2>&1 && [[ -z "${OPENCODE_PLAN_CLI:-}${OPENCODE_CLI:-}" ]]; then
        return 1
      fi
      _opencode_list_models_from_cli
      return 0
      ;;
    antigravity)
      if ! declare -F _antigravity_detect_cli >/dev/null 2>&1 || ! declare -F _antigravity_list_models >/dev/null 2>&1; then
        return 1
      fi
      _antigravity_detect_cli
      if [[ -z "${RALPH_SM_ANTIGRAVITY_CLI:-}" ]]; then
        return 1
      fi
      _antigravity_list_models
      return 0
      ;;
    claude)
      # Saved models first, then missing built-in aliases (haiku sonnet opus
      # fable). Same merge helper as the direct Claude interactive picker.
      # Re-init when an export -f'd discovery function was inherited without the
      # accompanying array (subprocess / contaminated shell cases).
      if [[ -z "${_CLAUDE_DEFAULT_MODELS+x}" ]]; then
        _CLAUDE_DEFAULT_MODELS=("haiku" "sonnet" "opus" "fable")
      fi
      local merged=()
      _select_model_load_saved_models claude merged
      _select_model_append_missing_defaults merged _CLAUDE_DEFAULT_MODELS
      local entry
      for entry in "${merged[@]+"${merged[@]}"}"; do
        [[ -n "$entry" ]] && printf '%s\n' "$entry"
      done
      return 0
      ;;
    codex)
      # Saved-store only: never inject Claude aliases into Codex discovery.
      local saved=()
      _select_model_load_saved_models "$runtime" saved
      local entry
      for entry in "${saved[@]+"${saved[@]}"}"; do
        [[ -n "$entry" ]] && printf '%s\n' "$entry"
      done
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

export -f \
  _select_model_append_missing_defaults \
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
  ralph_resolve_staged_claude_codex_plan_model \
  ralph_resolve_staged_antigravity_plan_model \
  ralph_resolve_staged_cursor_opencode_plan_model \
  ralph_resolve_staged_plan_model \
  _select_model_batch_dispatch \
  ralph_select_model_list_discovered \
  2>/dev/null || true
