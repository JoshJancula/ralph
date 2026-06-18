#!/usr/bin/env bash

if [[ -n "${RALPH_ARTIFACTS_LIB_LOADED:-}" ]]; then
  return
fi
RALPH_ARTIFACTS_LIB_LOADED=1

# Public interface:
#   trim, parse_artifact_csv -- string and CSV parsing for artifact lists.
#   expand_artifact_tokens, resolve_artifact_path_template -- shared path token expansion.
#   artifact_paths_append_unique -- dedupe resolved artifact paths in EXPECTED_ARTIFACT_PATHS.

trim() {
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

parse_artifact_csv() {
  EXPECTED_ARTIFACT_PATHS=()
  local csv="$1"
  [[ -z "$csv" ]] && return 0
  local IFS=,
  local piece
  for piece in $csv; do
    piece="$(trim "$piece")"
    [[ -n "$piece" ]] && EXPECTED_ARTIFACT_PATHS+=("$piece")
  done
}

# expand_artifact_tokens() replaces the templated tokens in artifact paths.
#  * {{ARTIFACT_NS}} resolves from RALPH_ARTIFACT_NS, with ORCH_BASENAME as the legacy fallback.
#  * {{PLAN_KEY}} resolves from RALPH_PLAN_KEY when set, otherwise falls back to the artifact namespace.
#  * {{STAGE_ID}} resolves from RALPH_STAGE_ID, which is expected to be sanitized before export.
expand_artifact_tokens() {
  local p="$1"
  local ns="${RALPH_ARTIFACT_NS:-${ORCH_BASENAME:-}}"
  local stage_id="${RALPH_STAGE_ID:-}"
  local plan_key
  if [[ -n "${RALPH_PLAN_KEY:-}" ]]; then
    plan_key="${RALPH_PLAN_KEY}"
  else
    plan_key="$ns"
  fi
  p="${p//\{\{ARTIFACT_NS\}\}/$ns}"
  p="${p//\{\{PLAN_KEY\}\}/$plan_key}"
  p="${p//\{\{STAGE_ID\}\}/$stage_id}"
  printf '%s' "$p"
}

resolve_artifact_path_template() {
  expand_artifact_tokens "$1"
}

artifact_paths_append_unique() {
  local new
  new="$(expand_artifact_tokens "$1")"
  local ex
  if ((${#EXPECTED_ARTIFACT_PATHS[@]} > 0)); then
    for ex in "${EXPECTED_ARTIFACT_PATHS[@]}"; do
      [[ "$ex" == "$new" ]] && return 0
    done
  fi
  EXPECTED_ARTIFACT_PATHS+=("$new")
}
