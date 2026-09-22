#!/usr/bin/env bash
#
# Antigravity model selection helper.
#
# Contract: Ralph lists available models via `agy models`. Each line from
# that command is "<slug><whitespace><Display Name>" (for example
# "claude-sonnet-4-6	Claude Sonnet 4.6 (Thinking)"). The picker shows the
# full line so the operator can read the human-readable name, but only the
# first whitespace-delimited token (the slug) is ever passed to
# `agy --model`. Passing the whole line fails: agy rejects a --model value
# that still has the display name and whitespace embedded in it.

_SELECT_MODEL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INTERACTIVE_LIB="${RALPH_SHARED_RALPH_DIR:-$_SELECT_MODEL_DIR/../../.ralph}/bash-lib/interactive-select.sh"
if [[ -r "$INTERACTIVE_LIB" ]]; then
  source "$INTERACTIVE_LIB"
fi

_select_model_common="${_SELECT_MODEL_DIR}/select-model-common.sh"
if [[ -r "$_select_model_common" ]]; then
  source "$_select_model_common"
fi

_antigravity_detect_cli() {
  if [[ -n "${RALPH_SM_ANTIGRAVITY_CLI:-}" ]]; then
    return 0
  fi
  if [[ -n "${ANTIGRAVITY_CLI:-}" ]]; then
    RALPH_SM_ANTIGRAVITY_CLI="$ANTIGRAVITY_CLI"
    return 0
  fi
  if command -v agy >/dev/null 2>&1; then
    RALPH_SM_ANTIGRAVITY_CLI="agy"
  else
    RALPH_SM_ANTIGRAVITY_CLI=""
  fi
}

_antigravity_list_models() {
  _antigravity_detect_cli
  if [[ -z "$RALPH_SM_ANTIGRAVITY_CLI" ]]; then
    return 0
  fi
  (
    set +e
    set +o pipefail
    "$RALPH_SM_ANTIGRAVITY_CLI" models 2>/dev/null
  ) 2>/dev/null | while IFS= read -r line || [[ -n "$line" ]]; do
    # Preserve the exact display string returned by `agy models`. Drop only
    # lines that are empty or contain only whitespace; never normalize, sort,
    # or filter the model identifiers.
    [[ -z "${line//[[:space:]]/}" ]] && continue
    printf '%s\n' "$line"
  done || true
}

_antigravity_select_model_interactive() {
  echo "" >&2
  echo -e "${C_C:-}${C_BOLD:-}--- Antigravity (.agents/agents.md + Ralph metadata) ---${C_RST:-}" >&2
  echo -e "${C_DIM:-}Pick a model for the Antigravity CLI (from agy models when available).${C_RST:-}" >&2
  # model_slugs[i] is the actual --model value; model_labels[i] is what the
  # menu displays (slug + human-readable name). They stay index-aligned.
  local model_slugs=() model_labels=() m slug
  model_slugs+=("auto")
  model_labels+=("auto")
  while IFS= read -r m || [[ -n "$m" ]]; do
    [[ -z "$m" || "$m" == "auto" ]] && continue
    slug="${m%%[[:space:]]*}"
    [[ -z "$slug" ]] && continue
    model_slugs+=("$slug")
    model_labels+=("$m")
  done <<<"$(_antigravity_list_models)"

  if [[ ${#model_slugs[@]} -le 1 ]]; then
    model_slugs=("auto" "antigravity/default")
    model_labels=("auto" "antigravity/default")
  fi

  local default_index=1 i
  for ((i = 0; i < ${#model_labels[@]}; i++)); do
    if [[ "${model_labels[$i]}" == "auto" ]]; then
      default_index=$((i + 1))
      break
    fi
  done

  local placeholder="Enter custom model id"
  local selection custom_model
  while true; do
    selection="$(ralph_menu_select --prompt "Model for Antigravity CLI agent (from agy models when available)" --default "$default_index" -- "${model_labels[@]}" "$placeholder")"
    if [[ -z "$selection" ]]; then
      echo ""
      return 0
    fi
    if [[ "$selection" == "$placeholder" ]]; then
      if ! _select_model_read_rp "Enter custom model id: " custom_model; then
        echo ""
        return 0
      fi
      if [[ -z "$custom_model" ]]; then
        echo -e "${C_R:-}Model cannot be empty.${C_RST:-}" >&2
        continue
      fi
      echo "$custom_model"
      return 0
    fi
    # Map the chosen label back to its slug. Labels are not guaranteed
    # unique in pathological input, so take the first match.
    for ((i = 0; i < ${#model_labels[@]}; i++)); do
      if [[ "${model_labels[$i]}" == "$selection" ]]; then
        echo "${model_slugs[$i]}"
        return 0
      fi
    done
    # Should not happen (selection always comes from model_labels), but
    # fail safe by echoing the slug portion of whatever was picked rather
    # than passing the raw display string through to --model.
    echo "${selection%%[[:space:]]*}"
    return 0
  done
}

select_model_antigravity() {
  if [[ "${1:-}" == "--interactive" ]]; then
    _antigravity_select_model_interactive
    return
  fi
  if [[ "${1:-}" == "--no-interactive" ]]; then
    shift
    echo "${ANTIGRAVITY_PLAN_MODEL:-${OPENCODE_PLAN_MODEL:-${CURSOR_PLAN_MODEL:-${1:-}}}}"
    return 0
  fi
  if [[ "${1:-}" == "--batch" ]]; then
    shift
    _select_model_batch_dispatch antigravity ANTIGRAVITY_PLAN_MODEL "$@"
    return 0
  fi
  local em="${ANTIGRAVITY_PLAN_MODEL:-${OPENCODE_PLAN_MODEL:-${CURSOR_PLAN_MODEL:-}}}"
  select_model_antigravity --batch 0 "$em" ""
}

export -f select_model_antigravity _antigravity_select_model_interactive _antigravity_list_models _antigravity_detect_cli 2>/dev/null || true
