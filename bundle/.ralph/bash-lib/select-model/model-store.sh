#!/usr/bin/env bash

if [[ -n "${RALPH_MODEL_STORE_LOADED:-}" ]]; then
  return
fi
RALPH_MODEL_STORE_LOADED=1

RALPH_MODEL_STORE_SCHEMA_VERSION=1

# Public interface:
#   ralph_model_store_config_dir -- resolve Ralph global config root.
#   ralph_model_store_path -- path to models.json under the config root.
#   ralph_model_store_defaults_json -- canonical empty store (compact JSON).
#   ralph_model_store_runtime_is_valid -- true when runtime is claude or codex.
#   ralph_model_store_read -- load and normalize models.json; print JSON on stdout.
#   ralph_model_store_write_json -- atomically write normalized JSON.
#   ralph_model_store_list -- print saved models for a runtime (one per line, oldest last).
#   ralph_model_store_default -- print the first saved model for a runtime, or nothing.
#   ralph_model_store_add -- prepend a model, deduplicating exact matches.
#   ralph_model_store_remove -- remove one exact model id from a runtime list.

ralph_model_store_config_dir() {
  if [[ -n "${RALPH_CONFIG_HOME:-}" ]]; then
    printf '%s\n' "${RALPH_CONFIG_HOME%/}"
    return 0
  fi

  local base="${XDG_CONFIG_HOME:-}"
  if [[ -z "$base" && -n "${HOME:-}" ]]; then
    base="$HOME/.config"
  fi
  if [[ -z "$base" ]]; then
    echo "Error: HOME, XDG_CONFIG_HOME, or RALPH_CONFIG_HOME must be set to locate Ralph config." >&2
    return 1
  fi
  printf '%s/ralph\n' "$base"
}

ralph_model_store_path() {
  printf '%s/models.json\n' "$(ralph_model_store_config_dir)"
}

ralph_model_store_runtime_is_valid() {
  case "${1:-}" in
    claude|codex) return 0 ;;
    *) return 1 ;;
  esac
}

ralph_model_store_defaults_json() {
  jq -nc --argjson schema_version "$RALPH_MODEL_STORE_SCHEMA_VERSION" '{
    schema_version: $schema_version,
    claude: [],
    codex: []
  }'
}

ralph_model_store_normalize_json() {
  local raw_json="${1:-}"
  local defaults
  defaults="$(ralph_model_store_defaults_json)"

  jq -nc --argjson defaults "$defaults" --argjson raw "$raw_json" '
    def string_array(value):
      if (value | type) == "array" then
        [value[] | select(type == "string" and length > 0)]
      else
        []
      end;
    {
      schema_version: $defaults.schema_version,
      claude: string_array($raw.claude),
      codex: string_array($raw.codex)
    }
  '
}

ralph_model_store_read() {
  command -v jq >/dev/null 2>&1 || return 1

  local path defaults raw
  defaults="$(ralph_model_store_defaults_json)"
  path="$(ralph_model_store_path)"

  if [[ ! -f "$path" ]]; then
    printf '%s' "$defaults"
    return 0
  fi

  raw="$(jq -c '.' "$path" 2>/dev/null)" || {
    printf '%s' "$defaults"
    return 0
  }

  ralph_model_store_normalize_json "$raw"
}

ralph_model_store_write_json() {
  local json="${1:-}"
  command -v jq >/dev/null 2>&1 || return 1
  [[ -n "$json" ]] || return 1

  local normalized path dir tmp
  normalized="$(ralph_model_store_normalize_json "$json")" || return 1
  path="$(ralph_model_store_path)"
  dir="$(ralph_model_store_config_dir)" || return 1
  mkdir -p "$dir" || return 1

  tmp="$(mktemp "$dir/.models.XXXXXX")" || return 1
  (
    umask 077
    jq '.' <<< "$normalized" >"$tmp"
  ) || {
    rm -f "$tmp"
    return 1
  }

  mv "$tmp" "$path"
}

ralph_model_store_list() {
  local runtime="${1:-}"
  ralph_model_store_runtime_is_valid "$runtime" || return 1
  ralph_model_store_read | jq -r --arg runtime "$runtime" '.[$runtime][]?'
}

ralph_model_store_default() {
  local runtime="${1:-}"
  ralph_model_store_runtime_is_valid "$runtime" || return 1
  ralph_model_store_read | jq -r --arg runtime "$runtime" '.[$runtime][0] // empty'
}

ralph_model_store__add_locked() {
  local runtime="$1"
  local model="$2"
  local current updated

  current="$(ralph_model_store_read)" || return 1
  updated="$(jq -c --arg runtime "$runtime" --arg model "$model" '
    .[$runtime] = ([$model] + (.[$runtime] | map(select(. != $model))))
  ' <<< "$current")" || return 1
  ralph_model_store_write_json "$updated"
}

ralph_model_store__remove_locked() {
  local runtime="$1"
  local model="$2"
  local current updated

  current="$(ralph_model_store_read)" || return 1
  updated="$(jq -c --arg runtime "$runtime" --arg model "$model" '
    .[$runtime] = (.[$runtime] | map(select(. != $model)))
  ' <<< "$current")" || return 1
  ralph_model_store_write_json "$updated"
}

ralph_model_store__with_lock() {
  local lock_file dir
  dir="$(ralph_model_store_config_dir)" || return 1
  mkdir -p "$dir" || return 1
  lock_file="$dir/.models.lock"

  if command -v flock >/dev/null 2>&1; then
    (
      flock -x 200 || exit 1
      "$@"
    ) 200>"$lock_file"
    return $?
  fi

  "$@"
}

ralph_model_store_add() {
  local runtime="${1:-}"
  local model="${2:-}"
  ralph_model_store_runtime_is_valid "$runtime" || return 1
  [[ -n "$model" ]] || return 1
  command -v jq >/dev/null 2>&1 || return 1

  ralph_model_store__with_lock ralph_model_store__add_locked "$runtime" "$model"
}

ralph_model_store_remove() {
  local runtime="${1:-}"
  local model="${2:-}"
  ralph_model_store_runtime_is_valid "$runtime" || return 1
  [[ -n "$model" ]] || return 1
  command -v jq >/dev/null 2>&1 || return 1

  ralph_model_store__with_lock ralph_model_store__remove_locked "$runtime" "$model"
}

export -f \
  ralph_model_store_config_dir \
  ralph_model_store_path \
  ralph_model_store_defaults_json \
  ralph_model_store_runtime_is_valid \
  ralph_model_store_normalize_json \
  ralph_model_store_read \
  ralph_model_store_write_json \
  ralph_model_store_list \
  ralph_model_store_default \
  ralph_model_store_add \
  ralph_model_store_remove \
  2>/dev/null || true
