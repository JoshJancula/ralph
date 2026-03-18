#!/usr/bin/env bash
# Codex runtime: shared model selection for new-agent and run-plan.

_codex_read_rp() {
  local prompt="$1"
  local _d="$2"
  if [[ -r /dev/tty ]]; then
    read -rp "$prompt" "$_d" </dev/tty 2>/dev/null || return 1
  else
    read -rp "$prompt" "$_d" || return 1
  fi
}

_codex_list_models_from_api() {
  (
    set +e
    set +o pipefail
    local auth="${HOME}/.codex/auth.json"
    [[ -r "$auth" ]] || exit 0
    local token=""
    if command -v jq >/dev/null 2>&1; then
      token=$(jq -r '.access_token // empty' "$auth" 2>/dev/null)
    elif command -v python3 >/dev/null 2>&1; then
      token=$(python3 -c "import json,sys; print(json.load(open(sys.argv[1])).get('access_token') or '')" "$auth" 2>/dev/null)
    else
      exit 0
    fi
    [[ -n "$token" && "$token" != "null" ]] || exit 0
    command -v curl >/dev/null 2>&1 || exit 0
    local body
    body=$(curl -sS --max-time 30 "https://api.openai.com/v1/models" \
      -H "Authorization: Bearer ${token}" 2>/dev/null) || exit 0
    if command -v jq >/dev/null 2>&1; then
      echo "$body" | jq -r '.data[]?.id | select(type == "string" and test("gpt"; "i"))' 2>/dev/null | sort -u
    elif command -v python3 >/dev/null 2>&1; then
      echo "$body" | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
    seen = set()
    for x in d.get("data") or []:
        i = x.get("id") or ""
        if "gpt" in i.lower():
            seen.add(i)
    print("\n".join(sorted(seen)))
except Exception:
    pass
' 2>/dev/null
    fi
  ) 2>/dev/null || true
}

_codex_select_model_interactive() {
  echo "" >&2
  echo "--- Codex (.codex/agents) ---" >&2
  local models=() m
  models+=("auto")
  while IFS= read -r m || [[ -n "$m" ]]; do
    [[ -z "$m" || "$m" == "auto" ]] && continue
    models+=("$m")
  done < <(_codex_list_models_from_api)

  if [[ ${#models[@]} -le 1 ]]; then
    models=("auto" "gpt-5.1-codex-mini" "gpt-5.1-turbo" "gpt-5" "gpt-4o")
  fi

  local default_index=1 i
  for ((i = 0; i < ${#models[@]}; i++)); do
    if [[ "${models[$i]}" == "auto" ]]; then
      default_index=$((i + 1))
      break
    fi
  done

  local custom_index=$(( ${#models[@]} + 1 ))
  echo "Model for Codex CLI agent (from API when logged into Codex CLI, else defaults):" >&2
  for ((i = 0; i < ${#models[@]}; i++)); do
    if [[ $((i + 1)) -eq "$default_index" ]]; then
      echo "  $((i + 1))) ${models[$i]} (default)" >&2
    else
      echo "  $((i + 1))) ${models[$i]}" >&2
    fi
  done
  echo "  $custom_index) Enter custom model id" >&2

  local choice custom_model
  while true; do
    if ! _codex_read_rp "Select model [$default_index]: " choice; then
      echo ""; return 0
    fi
    choice="${choice:-$default_index}"
    if [[ "$choice" =~ ^[0-9]+$ ]] && ((choice >= 1 && choice <= ${#models[@]})); then
      echo "${models[$((choice - 1))]}"; return 0
    fi
    if [[ "$choice" == "$custom_index" ]]; then
      if ! _codex_read_rp "Enter custom model id: " custom_model; then
        echo ""; return 0
      fi
      if [[ -z "$custom_model" ]]; then
        echo "Model cannot be empty." >&2
      else
        echo "$custom_model"; return 0
      fi
    else
      echo "Invalid selection." >&2
    fi
  done
}

select_model_codex() {
  if [[ "${1:-}" == "--interactive" ]]; then
    _codex_select_model_interactive
    return
  fi
  if [[ "${1:-}" == "--no-interactive" ]]; then
    shift
    echo "${CODEX_PLAN_MODEL:-${CURSOR_PLAN_MODEL:-${1:-}}}"
    return
  fi
  if [[ "${1:-}" == "--batch" ]]; then
    shift
    local ni="$1" env_m="$2" cfg="$3"
    local resolved="${env_m}"
    [[ -z "$resolved" && -n "${CURSOR_PLAN_MODEL:-}" ]] && resolved="${CURSOR_PLAN_MODEL}"
    if [[ "$ni" == "1" ]]; then
      echo "${resolved:-$cfg}"
      return
    fi
    [[ -n "$resolved" ]] && { echo "$resolved"; return; }
    [[ ! -r /dev/tty ]] && { echo "$cfg"; return; }
    _codex_select_model_interactive
    return
  fi
  local em="${CODEX_PLAN_MODEL:-${CURSOR_PLAN_MODEL:-}}"
  select_model_codex --batch 0 "$em" ""
}

export -f select_model_codex _codex_select_model_interactive _codex_list_models_from_api _codex_read_rp 2>/dev/null || true
