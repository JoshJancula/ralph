#!/usr/bin/env bash
# Artifact namespace helpers for run-plan (sourced from run-plan-core.sh).
#
# Ensures `.ralph-workspace/artifacts/<RALPH_ARTIFACT_NS>/` exists, exports
# RALPH_ARTIFACT_DIR for child CLIs, and prunes old `*.log` command captures
# so efficient-tool-usage redirects do not grow without bound.
#
# Env:
#   RALPH_ARTIFACT_LOG_RETENTION_COUNT -- max `*.log` files per namespace (default 100; 0 disables prune)

ralph_validate_artifact_namespace() {
  local ns="${1:-}"
  [[ -n "$ns" ]] || return 1
  # Single path segment only (no traversal).
  [[ "$ns" != *".."* ]] || return 1
  [[ "$ns" != */* ]] || return 1
  return 0
}

ralph_artifact_dir_path() {
  local root="${RALPH_PLAN_WORKSPACE_ROOT:?}"
  local ns="${RALPH_ARTIFACT_NS:?}"
  printf '%s/artifacts/%s' "$root" "$ns"
}

ralph_ensure_artifact_namespace() {
  local dir
  if ! ralph_validate_artifact_namespace "${RALPH_ARTIFACT_NS:-}"; then
    ralph_die "Error: invalid RALPH_ARTIFACT_NS (must be a single safe path segment)"
  fi
  dir="$(ralph_artifact_dir_path)"
  mkdir -p "$dir"
  export RALPH_ARTIFACT_DIR="$dir"
  ralph_run_plan_log "artifact directory ready: RALPH_ARTIFACT_DIR=$RALPH_ARTIFACT_DIR"
}

ralph_prune_artifact_command_logs() {
  local dir="${RALPH_ARTIFACT_DIR:-}"
  [[ -d "$dir" ]] || return 0

  local max_count="${RALPH_ARTIFACT_LOG_RETENTION_COUNT:-100}"
  case "$max_count" in
    ''|*[!0-9]*) max_count=100 ;;
  esac
  if [[ "$max_count" -eq 0 ]]; then
    ralph_run_plan_log "artifact log retention disabled (RALPH_ARTIFACT_LOG_RETENTION_COUNT=0)"
    return 0
  fi

  local -a logs=()
  local f
  shopt -s nullglob
  for f in "$dir"/*.log; do
    [[ -f "$f" ]] && logs+=("$f")
  done
  shopt -u nullglob

  local count="${#logs[@]}"
  if [[ "$count" -le "$max_count" ]]; then
    return 0
  fi

  local -a sorted=()
  local line path
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    path="${line#*$'\t'}"
    sorted+=("$path")
  done < <(
    for f in "${logs[@]}"; do
      local mtime="0"
      if mtime="$(stat -c %Y "$f" 2>/dev/null)"; then
        :
      elif mtime="$(stat -f %m "$f" 2>/dev/null)"; then
        :
      fi
      printf '%s\t%s\n' "$mtime" "$f"
    done | sort -n
  )

  local removed=0
  local to_remove=$(( count - max_count ))
  local i
  for ((i = 0; i < to_remove; i++)); do
    if rm -f "${sorted[$i]}"; then
      removed=$((removed + 1))
    fi
  done
  if [[ "$removed" -gt 0 ]]; then
    ralph_run_plan_log "artifact log retention: removed $removed of $count *.log file(s) (keeping newest $max_count)"
  fi
}

ralph_artifact_namespace_prompt_block() {
  if [[ -z "${RALPH_ARTIFACT_NS:-}" && -z "${RALPH_PLAN_KEY:-}" ]]; then
    return 0
  fi
  printf '%s' "Artifact namespace: RALPH_ARTIFACT_NS=${RALPH_ARTIFACT_NS:-}  RALPH_PLAN_KEY=${RALPH_PLAN_KEY:-}"
  if [[ -n "${RALPH_ARTIFACT_DIR:-}" ]]; then
    printf '%s' "
Command-output logs: redirect large shell output to ${RALPH_ARTIFACT_DIR}/<name>.log (see efficient-tool-usage rules)."
  fi
  printf '%s' "
Use namespace-aware artifact paths when writing handoff files."
}
