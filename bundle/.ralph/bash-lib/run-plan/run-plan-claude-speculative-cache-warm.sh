#!/usr/bin/env bash

if [[ -n "${RALPH_RUN_PLAN_CLAUDE_SPECULATIVE_CACHE_WARM_LOADED:-}" ]]; then
  return
fi
RALPH_RUN_PLAN_CLAUDE_SPECULATIVE_CACHE_WARM_LOADED=1

# Speculative Claude prompt-cache warming (backlog item 19).
#
# Capability probe: the installed Claude CLI must expose BOTH explicit cache
# breakpoint control (--cache-control) and bounded output control
# (--max-output-tokens). Claude Code 2.1.x-style surfaces without cache_control
# report unsupported and never issue a billable warm request.
#
# Opt-in only: RALPH_CLAUDE_SPECULATIVE_CACHE_WARM=1 (never enabled by default
# in this roadmap, including ralph/hybrid mode).

# Returns 0 when RALPH_CLAUDE_SPECULATIVE_CACHE_WARM=1; invalid values fail early.
ralph_claude_speculative_cache_warm_enabled() {
  local gate="${RALPH_CLAUDE_SPECULATIVE_CACHE_WARM:-0}"
  case "$gate" in
    0|false|no|off|"")
      return 1
      ;;
    1|true|yes|on)
      return 0
      ;;
    *)
      if declare -F ralph_run_plan_log >/dev/null 2>&1; then
        ralph_run_plan_log "RALPH_CLAUDE_SPECULATIVE_CACHE_WARM: invalid value '$gate' (use 0 or 1)"
      fi
      echo "RALPH_CLAUDE_SPECULATIVE_CACHE_WARM: invalid value '$gate' (use 0 or 1)" >&2
      return 2
      ;;
  esac
}

# Documented capability probe for safe speculative cache warming.
# Sets RALPH_CLAUDE_SPECULATIVE_CACHE_WARM_CAPABILITY to supported|unsupported.
# Prints a single status token on stdout: supported or unsupported[:reason].
run_plan_invoke_claude_cache_warm_capability_probe() {
  local cli_name="${1:-${CLAUDE_PLAN_CLI:-claude}}"
  local help_text=""

  RALPH_CLAUDE_SPECULATIVE_CACHE_WARM_CAPABILITY=unsupported
  export RALPH_CLAUDE_SPECULATIVE_CACHE_WARM_CAPABILITY

  if ! command -v "$cli_name" >/dev/null 2>&1; then
    printf '%s\n' "unsupported:cli-not-found"
    return 1
  fi

  help_text="$("$cli_name" --help 2>&1 || true)"
  if ! grep -q -- '--cache-control' <<<"$help_text"; then
    printf '%s\n' "unsupported:missing-cache-control"
    return 1
  fi
  if ! grep -q -- '--max-output-tokens' <<<"$help_text"; then
    printf '%s\n' "unsupported:missing-max-output-tokens"
    return 1
  fi

  RALPH_CLAUDE_SPECULATIVE_CACHE_WARM_CAPABILITY=supported
  export RALPH_CLAUDE_SPECULATIVE_CACHE_WARM_CAPABILITY
  printf '%s\n' "supported"
  return 0
}

_run_plan_invoke_claude_cache_warm_supported() {
  local cli_name="${1:-${CLAUDE_PLAN_CLI:-claude}}"
  local probe_result=""
  probe_result="$(run_plan_invoke_claude_cache_warm_capability_probe "$cli_name" 2>/dev/null || true)"
  [[ "$probe_result" == "supported" ]]
}

ralph_claude_speculative_cache_warm_sidecar_path() {
  local plan_key="${RALPH_PLAN_KEY:-${RALPH_ARTIFACT_NS:-}}"
  local state_root="${RALPH_PLAN_WORKSPACE_ROOT:-${WORKSPACE:-}/.ralph-workspace}"
  [[ -n "$plan_key" ]] || return 1
  printf '%s/sessions/%s/speculative-cache-warm.pid\n' "${state_root%/}" "$plan_key"
}

ralph_claude_speculative_cache_warm_log_path() {
  local plan_key="${RALPH_PLAN_KEY:-${RALPH_ARTIFACT_NS:-}}"
  local state_root="${RALPH_PLAN_WORKSPACE_ROOT:-${WORKSPACE:-}/.ralph-workspace}"
  [[ -n "$plan_key" ]] || return 1
  printf '%s/logs/%s/speculative-cache-warm-%s.log\n' "${state_root%/}" "$plan_key" "$(date +%s)"
}

ralph_claude_speculative_cache_warm_read_pid() {
  local sidecar="${RALPH_PLAN_SPECULATIVE_CACHE_WARM_PID_FILE:-}"
  local pid=""
  [[ -n "$sidecar" && -f "$sidecar" ]] || return 1
  pid="$(tr -d '[:space:]' <"$sidecar" 2>/dev/null || true)"
  [[ "$pid" =~ ^[0-9]+$ ]] || return 1
  printf '%s' "$pid"
}

ralph_claude_speculative_cache_warm_clear_sidecar() {
  rm -f "${RALPH_PLAN_SPECULATIVE_CACHE_WARM_PID_FILE:-}" 2>/dev/null || true
  rm -f "${RALPH_PLAN_SPECULATIVE_CACHE_WARM_LOG_FILE:-}" 2>/dev/null || true
}

# Kill a running warm job without recording usage (interrupt/teardown path).
ralph_claude_speculative_cache_warm_teardown() {
  local pid=""
  if pid="$(ralph_claude_speculative_cache_warm_read_pid 2>/dev/null)"; then
    if declare -F ralph_kill_tree_and_reap >/dev/null 2>&1; then
      ralph_kill_tree_and_reap "$pid"
    else
      kill -TERM "$pid" 2>/dev/null || true
      wait "$pid" 2>/dev/null || true
    fi
  fi
  ralph_claude_speculative_cache_warm_clear_sidecar
}

_ralph_claude_speculative_cache_warm_record_usage() {
  local started_at="$1"
  local ended_at="$2"
  local elapsed="$3"
  local log_file="${4:-}"
  local input_tokens=0 output_tokens=0 cache_create=0 cache_read=0

  if [[ -n "$log_file" && -f "$log_file" ]] && command -v python3 >/dev/null 2>&1; then
    read -r input_tokens output_tokens cache_create cache_read <<<"$(
      python3 -c '
import json, sys
path = sys.argv[1]
input_t = output_t = cache_create = cache_read = 0
try:
    with open(path, encoding="utf-8") as fh:
        for line in fh:
            line = line.strip()
            if not line:
                continue
            try:
                obj = json.loads(line)
            except json.JSONDecodeError:
                continue
            if not isinstance(obj, dict):
                continue
            usage = obj.get("usage")
            if isinstance(usage, dict):
                input_t = int(usage.get("input_tokens") or usage.get("uncached_input_tokens") or 0)
                output_t = int(usage.get("output_tokens") or 0)
                cache_create = int(usage.get("cache_creation_input_tokens") or 0)
                cache_read = int(usage.get("cache_read_input_tokens") or 0)
            if obj.get("type") == "result" and isinstance(obj.get("usage"), dict):
                break
except OSError:
    pass
print(input_t, output_t, cache_create, cache_read)
' "$log_file" 2>/dev/null || printf '0 0 0 0'
    )"
  fi

  if ! declare -F _ralph_append_invocation_usage_history >/dev/null 2>&1; then
    return 0
  fi

  local usage_path="${RALPH_PLAN_INVOCATION_USAGE_FILE:-}"
  [[ -n "$usage_path" ]] || return 0

  export RALPH_USAGE_INVOCATION_KIND=speculative_cache_warm
  _ralph_append_invocation_usage_history \
    "$usage_path" \
    "${ITERATION:-0}" \
    "${SELECTED_MODEL:-}" \
    "claude" \
    "$elapsed" \
    "$input_tokens" \
    "$output_tokens" \
    "$cache_create" \
    "$cache_read" \
    0 \
    0 \
    "$started_at" \
    "$ended_at" \
    "${RALPH_PLAN_KEY:-}" \
    "${RALPH_STAGE_ID:-}" \
    "speculative_cache_warm" \
    "${RALPH_SPECULATIVE_CACHE_WARM_TODO_LINE:-}" \
    "${RALPH_SPECULATIVE_CACHE_WARM_TODO_ORDINAL:-}" \
    0 \
    "speculative_cache_warm" \
    "${RALPH_SPECULATIVE_CACHE_WARM_FINGERPRINT:-}" \
    0 \
    0 \
    "${RALPH_PROMPT_STABLE_PREFIX_BYTES:-0}" \
    0 \
    0 \
    "" \
    0 \
    "" \
    0
  unset RALPH_USAGE_INVOCATION_KIND
}

# Start a bounded warm request during the post-verification idle window.
# No-op when disabled, unsupported, or stable prefix is empty.
ralph_claude_speculative_cache_warm_maybe_start() {
  local todo_line="${1:-}"
  local cli_name="${CLAUDE_PLAN_CLI:-claude}"

  RALPH_CLAUDE_SPECULATIVE_CACHE_WARM_STARTED=0
  export RALPH_CLAUDE_SPECULATIVE_CACHE_WARM_STARTED
  RALPH_CLAUDE_SPECULATIVE_CACHE_WARM_STARTED_AT=""
  export RALPH_CLAUDE_SPECULATIVE_CACHE_WARM_STARTED_AT

  [[ "${RUNTIME:-}" == "claude" ]] || return 0
  if ! ralph_claude_speculative_cache_warm_enabled; then
    return 0
  fi
  if ! _run_plan_invoke_claude_cache_warm_supported "$cli_name"; then
    if declare -F ralph_run_plan_log >/dev/null 2>&1; then
      ralph_run_plan_log "speculative cache warm: unsupported on ${cli_name} (capability probe)"
    else
      echo "speculative cache warm: unsupported on ${cli_name} (capability probe)" >&2
    fi
    return 0
  fi
  if [[ -z "${PROMPT_STATIC:-}" ]]; then
    if declare -F ralph_run_plan_log >/dev/null 2>&1; then
      ralph_run_plan_log "speculative cache warm: skipped (empty stable prefix)"
    fi
    return 0
  fi

  local sidecar log_file agent_ws warm_pid started_at fingerprint
  sidecar="$(ralph_claude_speculative_cache_warm_sidecar_path 2>/dev/null || true)"
  log_file="$(ralph_claude_speculative_cache_warm_log_path 2>/dev/null || true)"
  [[ -n "$sidecar" && -n "$log_file" ]] || return 0

  mkdir -p "$(dirname "$sidecar")" "$(dirname "$log_file")"
  export RALPH_PLAN_SPECULATIVE_CACHE_WARM_PID_FILE="$sidecar"
  export RALPH_PLAN_SPECULATIVE_CACHE_WARM_LOG_FILE="$log_file"
  export RALPH_SPECULATIVE_CACHE_WARM_TODO_LINE="$todo_line"
  export RALPH_SPECULATIVE_CACHE_WARM_TODO_ORDINAL="${RALPH_TODO_ORDINAL:-}"
  fingerprint="${RALPH_PROMPT_STABLE_PREFIX_FINGERPRINT:-}"
  if [[ -z "$fingerprint" ]] && declare -F ralph_run_plan_stable_prefix_fingerprint >/dev/null 2>&1; then
    fingerprint="$(ralph_run_plan_stable_prefix_fingerprint "$PROMPT_STATIC")"
  fi
  export RALPH_SPECULATIVE_CACHE_WARM_FINGERPRINT="$fingerprint"

  ralph_claude_speculative_cache_warm_teardown

  started_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  RALPH_CLAUDE_SPECULATIVE_CACHE_WARM_STARTED_AT="$started_at"
  export RALPH_CLAUDE_SPECULATIVE_CACHE_WARM_STARTED_AT
  RALPH_CLAUDE_SPECULATIVE_CACHE_WARM_START_EPOCH="$(date +%s)"
  export RALPH_CLAUDE_SPECULATIVE_CACHE_WARM_START_EPOCH

  agent_ws="${RALPH_AGENT_WORKSPACE:-${WORKSPACE:-$(pwd)}}"
  echo -e "${C_DIM:-}Starting speculative Claude cache warm (fingerprint=${fingerprint:-none}; max-output=1)${C_RST:-}" >&2
  if declare -F ralph_run_plan_log >/dev/null 2>&1; then
    ralph_run_plan_log "speculative cache warm: starting fingerprint=${fingerprint:-none} todo_line=${todo_line:-}"
  fi

  (
    cd "$agent_ws" || exit 1
    printf '%s' "." | ralph_process_scope_exec cache-warm claude "$cli_name" \
      --system-prompt "$PROMPT_STATIC" \
      --cache-control break \
      --max-output-tokens 1 \
      --output-format stream-json \
      >"$log_file" 2>&1
  ) &
  warm_pid=$!
  printf '%s\n' "$warm_pid" >"$sidecar"
  RALPH_CLAUDE_SPECULATIVE_CACHE_WARM_STARTED=1
  export RALPH_CLAUDE_SPECULATIVE_CACHE_WARM_STARTED
}

# Wait for or cancel the warm job and record auxiliary usage.
ralph_claude_speculative_cache_warm_finalize() {
  local pid="" started_at ended_at elapsed log_file
  [[ "${RALPH_CLAUDE_SPECULATIVE_CACHE_WARM_STARTED:-0}" == "1" ]] || return 0

  started_at="${RALPH_CLAUDE_SPECULATIVE_CACHE_WARM_STARTED_AT:-}"
  log_file="${RALPH_PLAN_SPECULATIVE_CACHE_WARM_LOG_FILE:-}"

  if pid="$(ralph_claude_speculative_cache_warm_read_pid 2>/dev/null)"; then
    if kill -0 "$pid" 2>/dev/null; then
      wait "$pid" 2>/dev/null || true
      if kill -0 "$pid" 2>/dev/null; then
        if declare -F ralph_kill_tree_and_reap >/dev/null 2>&1; then
          ralph_kill_tree_and_reap "$pid"
        else
          kill -TERM "$pid" 2>/dev/null || true
          wait "$pid" 2>/dev/null || true
        fi
      fi
    fi
  fi

  ended_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  if [[ "${RALPH_CLAUDE_SPECULATIVE_CACHE_WARM_START_EPOCH:-}" =~ ^[0-9]+$ ]]; then
    elapsed=$(( $(date +%s) - RALPH_CLAUDE_SPECULATIVE_CACHE_WARM_START_EPOCH ))
    [[ "$elapsed" -ge 0 ]] || elapsed=0
  else
    elapsed=0
  fi

  _ralph_claude_speculative_cache_warm_record_usage "$started_at" "$ended_at" "$elapsed" "$log_file"
  if declare -F ralph_run_plan_log >/dev/null 2>&1; then
    ralph_run_plan_log "speculative cache warm: finalized elapsed=${elapsed}s"
  fi
  ralph_claude_speculative_cache_warm_clear_sidecar
  RALPH_CLAUDE_SPECULATIVE_CACHE_WARM_STARTED=0
  export RALPH_CLAUDE_SPECULATIVE_CACHE_WARM_STARTED
}
