#!/usr/bin/env bash
# Shared native shell execution, compaction, and result storage.
# Used by ralph_proxy_shell (MCP) and native runtime hooks (pre-tool wrapper).
#
# Gate: RALPH_NATIVE_SHELL_WRAPPER=1|true|yes|on enables wrapper CLI compaction.
# Fail-open: setup or storage failures print raw command output and preserve exit codes.

if [[ -n "${RALPH_NATIVE_SHELL_WRAPPER_LIB_LOADED:-}" ]]; then
  return 0 2>/dev/null || exit 0
fi
RALPH_NATIVE_SHELL_WRAPPER_LIB_LOADED=1

_NATIVE_SHELL_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ -z "${RALPH_COMPACTORS_LOADED:-}" ]]; then
  export RALPH_COMPACTORS_LIB_DIR="${RALPH_COMPACTORS_LIB_DIR:-$_NATIVE_SHELL_LIB_DIR/../}"
  # shellcheck source=/dev/null
  source "$_NATIVE_SHELL_LIB_DIR/../compactors.sh"
  RALPH_COMPACTORS_LOADED=1
fi
if [[ -z "${RALPH_HOOK_TELEMETRY_LOADED:-}" ]]; then
  # shellcheck source=/dev/null
  source "$_NATIVE_SHELL_LIB_DIR/../hook-telemetry.sh"
  RALPH_HOOK_TELEMETRY_LOADED=1
fi
if [[ -z "${RALPH_PROCESS_TEARDOWN_LOADED:-}" ]]; then
  # shellcheck source=/dev/null
  source "$_NATIVE_SHELL_LIB_DIR/../ralph-process-teardown.sh"
fi
if [[ -z "${RALPH_MCP_PROXY_RESULT_STORE_LOADED:-}" ]]; then
  # shellcheck source=/dev/null
  source "$_NATIVE_SHELL_LIB_DIR/../mcp-proxy/mcp-proxy-result-store.sh"
  RALPH_MCP_PROXY_RESULT_STORE_LOADED=1
fi
if [[ -z "${RALPH_TOKEN_ESTIMATE_LOADED:-}" ]]; then
  # shellcheck source=/dev/null
  source "$_NATIVE_SHELL_LIB_DIR/../token-estimate.sh" 2>/dev/null || true
fi

ralph_native_shell_wrapper_truthy() {
  case "${1:-}" in
    1 | true | yes | on) return 0 ;;
    *) return 1 ;;
  esac
}

ralph_native_shell_wrapper_enabled() {
  ralph_native_shell_wrapper_truthy "${RALPH_NATIVE_SHELL_WRAPPER:-}"
}

ralph_native_shell_plan_key() {
  if [[ -n "${RALPH_PLAN_KEY:-}" ]]; then
    printf '%s\n' "$RALPH_PLAN_KEY"
  elif [[ -n "${RALPH_ARTIFACT_NS:-}" ]]; then
    printf '%s\n' "$RALPH_ARTIFACT_NS"
  else
    printf 'default\n'
  fi
}

# Stable, non-sensitive reason code when ralph_native_shell_plan_key fell
# back to "default", or empty when a key was explicitly provided.
ralph_native_shell_plan_key_fallback_reason() {
  if [[ -n "${RALPH_PLAN_KEY:-}" ]]; then
    return 0
  fi
  if [[ -n "${RALPH_ARTIFACT_NS:-}" ]]; then
    return 0
  fi
  printf 'no_plan_key_or_artifact_ns_env\n'
}

ralph_native_shell_wrapper_libs_ready() {
  command -v jq >/dev/null 2>&1 || return 1
  [[ -f "$_NATIVE_SHELL_LIB_DIR/../compactors.sh" ]] || return 1
  [[ -f "$_NATIVE_SHELL_LIB_DIR/../mcp-proxy/mcp-proxy-result-store.sh" ]] || return 1
  command -v python3 >/dev/null 2>&1 || return 1
  return 0
}

ralph_native_shell_byte_cap_for_tool() {
  local tool="${1:-ralph_proxy_shell}"
  if declare -F ralph_mcp_proxy_result_byte_cap_for_tool >/dev/null 2>&1; then
    ralph_mcp_proxy_result_byte_cap_for_tool "$tool"
    return 0
  fi
  printf '0\n'
}

ralph_mcp_proxy_shell_combine_streams() {
  local stdout="${1-}" stderr="${2-}"
  if [[ -n "$stderr" ]]; then
    if [[ -n "$stdout" ]]; then
      printf '%s\n%s' "$stdout" "$stderr"
    else
      printf '%s' "$stderr"
    fi
  else
    printf '%s' "$stdout"
  fi
}

ralph_mcp_proxy_shell_original_storage_text() {
  local command="${1-}" stdout="${2-}" stderr="${3-}" exit_code="${4:-0}"
  jq -nc \
    --arg command "$command" \
    --arg stdout "$stdout" \
    --arg stderr "$stderr" \
    --argjson exitCode "$exit_code" \
    '{
      command: $command,
      stdout: $stdout,
      stderr: $stderr,
      exitCode: $exitCode
    }'
}

ralph_mcp_proxy_shell_compact_result_path_display() {
  local plan_key="${1-}" result_id="${2-}"
  printf '.ralph-workspace/tool-results/%s/results/%s' "$plan_key" "$result_id"
}

ralph_mcp_proxy_shell_compact_envelope_build_json() {
  local command="${1-}" exit_code="${2:-0}" preview="${3-}"
  local original_bytes="${4:-0}" returned_bytes="${5:-0}"
  local result_id="${6-}" result_path="${7-}"
  local stdout_compacted="${8:-false}" stderr_compacted="${9:-false}" compacted_flag="${10:-0}"
  local original_tokens="${11:-}" returned_tokens="${12:-}"
  local compacted_json="false"
  if [[ "$compacted_flag" == "1" || "$compacted_flag" == "true" ]]; then
    compacted_json="true"
  fi

  local include_tokens="false"
  if [[ "$original_tokens" =~ ^[0-9]+$ ]] && [[ "$returned_tokens" =~ ^[0-9]+$ ]]; then
    include_tokens="true"
  fi

  jq -nc \
    --arg command "$command" \
    --argjson exitCode "$exit_code" \
    --arg preview "$preview" \
    --argjson originalBytes "$original_bytes" \
    --argjson returnedBytes "$returned_bytes" \
    --arg resultId "$result_id" \
    --arg resultPath "$result_path" \
    --argjson stdoutCompacted "$stdout_compacted" \
    --argjson stderrCompacted "$stderr_compacted" \
    --argjson compacted "$compacted_json" \
    --arg includeTokens "$include_tokens" \
    --argjson originalTokens "${original_tokens:-0}" \
    --argjson returnedTokens "${returned_tokens:-0}" \
    '{
      shellCompact: true,
      command: $command,
      exitCode: $exitCode,
      preview: $preview,
      originalBytes: $originalBytes,
      returnedBytes: $returnedBytes,
      resultId: $resultId,
      resultPath: $resultPath,
      stdoutCompacted: $stdoutCompacted,
      stderrCompacted: $stderrCompacted,
      compacted: $compacted
    }
    | if $includeTokens == "true" then
        . + {originalTokens: $originalTokens, returnedTokens: $returnedTokens}
      else
        .
      end'
}

ralph_native_shell_plain_footer() {
  local result_path="${1:-}"
  printf '[ralph: shell output compacted; original stored at %s; set RALPH_NATIVE_SHELL_WRAPPER=0 to disable]' "$result_path"
}

ralph_native_shell_append_footer() {
  local preview="${1-}" footer="${2-}"
  if [[ -z "$footer" ]]; then
    printf '%s' "$preview"
    return 0
  fi
  if [[ -n "$preview" && "${preview: -1}" != $'\n' ]]; then
    preview="${preview}"$'\n'
  fi
  printf '%s%s' "$preview" "$footer"
}

# Execute a shell command once in workspace; prints JSON with stdout, stderr, exitCode.
ralph_native_shell_launch_process_group() {
  local workspace="${1:-}" command="${2:-}" shell_exe="${3:-bash}" stdout_path="${4:-}" stderr_path="${5:-}"
  local pid="" pgid="" sid="" isolated="false" launch_mode="plain"

  if command -v setsid >/dev/null 2>&1; then
    setsid "$shell_exe" -c 'cd "$1" || exit 1; exec "$2" -c "$3"' _ "$workspace" "$shell_exe" "$command" >"$stdout_path" 2>"$stderr_path" &
    pid=$!
    isolated="true"
    launch_mode="setsid"
  elif command -v python3 >/dev/null 2>&1; then
    python3 -c 'import os, sys; os.chdir(sys.argv[1]); os.setsid(); os.execvp(sys.argv[2], [sys.argv[2], "-c", sys.argv[3]])' "$workspace" "$shell_exe" "$command" >"$stdout_path" 2>"$stderr_path" &
    pid=$!
    isolated="true"
    launch_mode="python-setsid"
  else
    "$shell_exe" -c 'cd "$1" || exit 1; exec "$2" -c "$3"' _ "$workspace" "$shell_exe" "$command" >"$stdout_path" 2>"$stderr_path" &
    pid=$!
  fi

  if [[ "$pid" =~ ^[0-9]+$ ]]; then
    if [[ "$isolated" == "true" ]]; then
      # setsid()/os.setsid() runs in the child after fork, so reading the
      # pgid immediately can race it and capture the launcher's own process
      # group. A later timeout group-kill on that pgid would take down this
      # process (and, inside the MCP server, the stdio transport with it).
      # Poll briefly until the child detaches into its own group.
      local _launch_self_pgid _launch_waited=0
      _launch_self_pgid="$(ps -o pgid= -p $$ 2>/dev/null | tr -d ' ' || true)"
      while (( _launch_waited < 40 )); do
        pgid="$(ps -o pgid= -p "$pid" 2>/dev/null | tr -d ' ' || true)"
        [[ -n "$pgid" ]] || break
        [[ -z "$_launch_self_pgid" || "$pgid" != "$_launch_self_pgid" ]] && break
        sleep 0.05
        ((_launch_waited++)) || true
      done
      if [[ -n "$pgid" && -n "$_launch_self_pgid" && "$pgid" == "$_launch_self_pgid" ]]; then
        # Never treat a job that shares our process group as isolated;
        # terminate must use the pid tree, not a group kill.
        isolated="false"
      fi
    else
      pgid="$(ps -o pgid= -p "$pid" 2>/dev/null | tr -d ' ' || true)"
    fi
    sid="$(ps -o sess= -p "$pid" 2>/dev/null | tr -d ' ' || true)"
  fi
  [[ "$pgid" =~ ^[0-9]+$ ]] || pgid="$pid"
  [[ "$sid" =~ ^[0-9]+$ ]] || sid="$pgid"

  RALPH_NATIVE_SHELL_LAUNCH_PID="$pid"
  RALPH_NATIVE_SHELL_LAUNCH_PGID="$pgid"
  RALPH_NATIVE_SHELL_LAUNCH_SID="$sid"
  RALPH_NATIVE_SHELL_LAUNCH_ISOLATED="$isolated"
  RALPH_NATIVE_SHELL_LAUNCH_MODE="$launch_mode"
}

ralph_native_shell_launch_process_group_json() {
  ralph_native_shell_launch_process_group "$@"
  jq -nc \
    --argjson pid "${RALPH_NATIVE_SHELL_LAUNCH_PID:-0}" \
    --argjson pgid "${RALPH_NATIVE_SHELL_LAUNCH_PGID:-0}" \
    --argjson sid "${RALPH_NATIVE_SHELL_LAUNCH_SID:-0}" \
    --argjson isolated "$([[ "${RALPH_NATIVE_SHELL_LAUNCH_ISOLATED:-false}" == "true" ]] && printf true || printf false)" \
    --arg launchMode "${RALPH_NATIVE_SHELL_LAUNCH_MODE:-plain}" \
    '{pid:$pid,pgid:$pgid,sid:$sid,isolatedProcessGroup:$isolated,launchMode:$launchMode}'
}

ralph_native_shell_terminate_spawned_job() {
  local pid="${1:-}" pgid="${2:-}" isolated="${3:-false}" max_wait="${4:-1}"
  local escalated=0

  # Last-line guard against the setsid race: re-read the job's live pgid and
  # refuse to group-kill our own process group. Killing it would terminate
  # this process too -- inside the MCP server that means the stdio transport
  # dies and the client drops every ralph tool mid-session.
  if [[ "$isolated" == "true" || "$isolated" == "1" ]]; then
    local _term_self_pgid _term_live_pgid
    _term_self_pgid="$(ps -o pgid= -p $$ 2>/dev/null | tr -d ' ' || true)"
    _term_live_pgid="$(ps -o pgid= -p "$pid" 2>/dev/null | tr -d ' ' || true)"
    [[ -n "$_term_live_pgid" ]] && pgid="$_term_live_pgid"
    if [[ -n "$_term_self_pgid" && "$pgid" == "$_term_self_pgid" ]]; then
      isolated="false"
    fi
  fi

  if [[ "$isolated" == "true" || "$isolated" == "1" ]]; then
    if [[ "$pgid" =~ ^[0-9]+$ ]]; then
      kill -TERM -"$pgid" 2>/dev/null || true
      local waited=0
      while (( waited < max_wait * 10 )) && kill -0 -"$pgid" 2>/dev/null; do
        sleep 0.1
        ((waited++)) || true
      done
      if kill -0 -"$pgid" 2>/dev/null; then
        escalated=1
        kill -KILL -"$pgid" 2>/dev/null || true
      fi
    fi
  elif [[ "$pid" =~ ^[0-9]+$ ]]; then
    ralph_kill_tree "$pid"
    escalated=1
  fi

  printf '%s\n' "$escalated"
}

ralph_native_shell_pid_running() {
  local pid="${1:-}"
  local stat=""
  [[ "$pid" =~ ^[0-9]+$ ]] || return 1
  kill -0 "$pid" 2>/dev/null || return 1
  stat="$(ps -o stat= -p "$pid" 2>/dev/null | tr -d ' ' || true)"
  [[ -n "$stat" ]] || return 0
  [[ "$stat" == Z* ]] && return 1
  return 0
}

ralph_native_shell_execute_command_json() {
  local workspace="${1:-}" command="${2:-}" shell_exe="${3:-bash}" timeout_sec="${4:-}"
  local pid pgid sid isolated launch_mode timed_out=0 kill_escalated=0
  local start_epoch now

  if [[ -z "$workspace" || -z "$command" ]]; then
    return 1
  fi
  if [[ -z "$timeout_sec" ]]; then
    timeout_sec="${RALPH_MCP_PROXY_POLICY_OWNED_SHELL_TIMEOUT:-10}"
  fi
  if [[ ! "$timeout_sec" =~ ^[0-9]+$ ]]; then
    timeout_sec=10
  fi

  local tmp_out tmp_err stdout stderr exit_code
  tmp_out="$(mktemp)"
  tmp_err="$(mktemp)"
  ralph_native_shell_launch_process_group "$workspace" "$command" "$shell_exe" "$tmp_out" "$tmp_err"
  pid="${RALPH_NATIVE_SHELL_LAUNCH_PID:-0}"
  pgid="${RALPH_NATIVE_SHELL_LAUNCH_PGID:-0}"
  sid="${RALPH_NATIVE_SHELL_LAUNCH_SID:-0}"
  isolated="${RALPH_NATIVE_SHELL_LAUNCH_ISOLATED:-false}"
  launch_mode="${RALPH_NATIVE_SHELL_LAUNCH_MODE:-plain}"

  start_epoch="$(date +%s)"
  while ralph_native_shell_pid_running "$pid"; do
    now="$(date +%s)"
    if (( now - start_epoch >= timeout_sec )); then
      timed_out=1
      kill_escalated="$(ralph_native_shell_terminate_spawned_job "$pid" "$pgid" "$isolated" 1)"
      break
    fi
    sleep 0.1
  done

  set +e
  wait "$pid" 2>/dev/null
  exit_code=$?
  set -e
  if (( timed_out == 1 )); then
    exit_code=124
  fi
  stdout="$(<"$tmp_out")"
  stderr="$(<"$tmp_err")"
  rm -f "$tmp_out" "$tmp_err"

  jq -nc \
    --arg stdout "$stdout" \
    --arg stderr "$stderr" \
    --argjson exitCode "$exit_code" \
    --argjson pid "${pid:-0}" \
    --argjson pgid "${pgid:-0}" \
    --argjson sid "${sid:-0}" \
    --arg launchMode "$launch_mode" \
    --argjson isolatedProcessGroup "$([[ "$isolated" == "true" ]] && printf true || printf false)" \
    --argjson timedOut "$([[ "$timed_out" -eq 1 ]] && printf true || printf false)" \
    --argjson killEscalated "$([[ "$kill_escalated" -eq 1 ]] && printf true || printf false)" \
    '{stdout: $stdout, stderr: $stderr, exitCode: $exitCode, pid:$pid, pgid:$pgid, sid:$sid, launchMode:$launchMode, isolatedProcessGroup:$isolatedProcessGroup, timedOut:$timedOut, killEscalated:$killEscalated}'
}

# Shared compaction pipeline after command execution.
# Prints one JSON object describing preview, storage, and compaction metadata.
ralph_native_shell_compact_pipeline_json() {
  local workspace="${1:-}" command="${2:-}" stdout="${3-}" stderr="${4-}" exit_code="${5:-0}"
  local max_shell_bytes="${6:-}" store_tool="${7:-ralph_proxy_shell}"

  local compact_json compact_stdout compact_stderr stdout_compacted stderr_compacted
  local compacted_applied preview_text storage_text raw_combined
  local original_bytes returned_bytes plan_key result_id result_path store_needed=0 byte_cap

  export RALPH_COMPACT_STDOUT="$stdout"
  export RALPH_COMPACT_STDERR="$stderr"
  compact_json="$(ralph_compact_shell_output "$command" "$exit_code")"
  compact_stdout="$(jq -r '.stdout // ""' <<<"$compact_json")"
  compact_stderr="$(jq -r '.stderr // ""' <<<"$compact_json")"
  stdout_compacted="$(jq -r '.stdout_compacted // false' <<<"$compact_json")"
  stderr_compacted="$(jq -r '.stderr_compacted // false' <<<"$compact_json")"
  if ralph_compact_shell_output_applied "$compact_json"; then
    compacted_applied=1
  else
    compacted_applied=0
  fi

  preview_text="$(ralph_mcp_proxy_shell_combine_streams "$compact_stdout" "$compact_stderr")"
  raw_combined="$(ralph_mcp_proxy_shell_combine_streams "$stdout" "$stderr")"
  if [[ "$compacted_applied" -eq 1 ]]; then
    store_needed=1
  fi
  if [[ "$exit_code" -ne 0 ]]; then
    store_needed=1
  fi

  if [[ "$max_shell_bytes" =~ ^[0-9]+$ ]] && [[ "$max_shell_bytes" -gt 0 ]] && [[ "${#preview_text}" -gt "$max_shell_bytes" ]]; then
    preview_text="${preview_text:0:max_shell_bytes}"
  fi
  byte_cap="$(ralph_native_shell_byte_cap_for_tool "$store_tool")"
  token_cap=""
  if declare -F ralph_mcp_proxy_result_token_cap_for_tool >/dev/null 2>&1; then
    token_cap="$(ralph_mcp_proxy_result_token_cap_for_tool "$store_tool")"
  fi
  if declare -F ralph_mcp_proxy_result_apply_preview_caps >/dev/null 2>&1; then
    ralph_mcp_proxy_result_apply_preview_caps "$preview_text" "$byte_cap" "$token_cap"
    preview_text="$RALPH_MCP_PROXY_RESULT_CAP_PREVIEW"
  elif [[ "$byte_cap" =~ ^[0-9]+$ ]] && [[ "$byte_cap" -gt 0 ]] && [[ "${#preview_text}" -gt "$byte_cap" ]]; then
    preview_text="${preview_text:0:byte_cap}"
  fi
  returned_bytes=${#preview_text}

  result_id=""
  result_path=""
  original_bytes=0
  if [[ "$store_needed" -eq 1 ]]; then
    storage_text="$(ralph_mcp_proxy_shell_original_storage_text "$command" "$stdout" "$stderr" "$exit_code")"
    original_bytes=${#storage_text}
    plan_key="$(ralph_native_shell_plan_key)"
    local plan_key_fallback_reason plan_key_fallback
    plan_key_fallback_reason="$(ralph_native_shell_plan_key_fallback_reason)"
    if [[ -n "$plan_key_fallback_reason" ]]; then
      plan_key_fallback="true"
    else
      plan_key_fallback="false"
    fi
    result_id="$(ralph_mcp_proxy_result_store_write \
      "$workspace" \
      "$plan_key" \
      "$storage_text" \
      "$store_tool" \
      '{"storageLayout":"full"}' \
      2>/dev/null || true)"
    if [[ -n "$result_id" ]]; then
      local compact_log="${RALPH_BASH_COMPACT_LOG:-}"
      if [[ "$store_tool" == "ralph_proxy_shell" && -n "${RALPH_PROXY_SHELL_COMPACT_LOG:-}" ]]; then
        compact_log="$RALPH_PROXY_SHELL_COMPACT_LOG"
      fi
      result_path="$(ralph_mcp_proxy_shell_compact_result_path_display "$plan_key" "$result_id")"
      ralph_hook_telemetry_append_compact_log \
        "$workspace" \
        "$plan_key" \
        "$command" \
        "$compact_json" \
        "$stdout" \
        "$stderr" \
        "$result_path" \
        "$exit_code" \
        "$compact_log" \
        "$plan_key_fallback" \
        "$plan_key_fallback_reason"
    else
      local compact_log="${RALPH_BASH_COMPACT_LOG:-}"
      if [[ "$store_tool" == "ralph_proxy_shell" && -n "${RALPH_PROXY_SHELL_COMPACT_LOG:-}" ]]; then
        compact_log="$RALPH_PROXY_SHELL_COMPACT_LOG"
      fi
      if [[ -n "$compact_log" ]]; then
        ralph_hook_telemetry_append_compact_log \
          "$workspace" \
          "$plan_key" \
          "$command" \
          "$compact_json" \
          "$stdout" \
          "$stderr" \
          "" \
          "$exit_code" \
          "$compact_log" \
          "$plan_key_fallback" \
          "$plan_key_fallback_reason"
      fi
    fi
  fi

  local original_tokens="" returned_tokens="" include_tokens="false"
  if declare -F ralph_mcp_proxy_result_estimate_tokens >/dev/null 2>&1; then
    if [[ "$original_bytes" -gt 0 ]]; then
      original_tokens="$(ralph_mcp_proxy_result_estimate_tokens "$storage_text" 2>/dev/null || true)"
    elif [[ -n "$raw_combined" ]]; then
      original_tokens="$(ralph_mcp_proxy_result_estimate_tokens "$raw_combined" 2>/dev/null || true)"
    fi
    returned_tokens="$(ralph_mcp_proxy_result_estimate_tokens "$preview_text" 2>/dev/null || true)"
  elif declare -F ralph_token_estimate_text >/dev/null 2>&1; then
    if [[ "$original_bytes" -gt 0 ]]; then
      original_tokens="$(ralph_token_estimate_text "$storage_text" 2>/dev/null || true)"
    elif [[ -n "$raw_combined" ]]; then
      original_tokens="$(ralph_token_estimate_text "$raw_combined" 2>/dev/null || true)"
    fi
    returned_tokens="$(ralph_token_estimate_text "$preview_text" 2>/dev/null || true)"
  fi
  if [[ "$original_tokens" =~ ^[0-9]+$ ]] && [[ "$returned_tokens" =~ ^[0-9]+$ ]]; then
    include_tokens="true"
  fi

  if declare -F ralph_hook_telemetry_append_windowing_log >/dev/null 2>&1 \
    && [[ -n "$result_id" ]] \
    && [[ "$original_bytes" -gt 0 ]] \
    && [[ "$returned_bytes" -lt "$original_bytes" ]]; then
    RALPH_RESULT_WINDOWING_CHANNEL="native_shell_hook"
    RALPH_RESULT_WINDOWING_SURFACED_TOOL_NAME="bash"
    RALPH_RESULT_WINDOWING_NORMALIZED_TOOL_NAME="$store_tool"
    export RALPH_RESULT_WINDOWING_CHANNEL RALPH_RESULT_WINDOWING_SURFACED_TOOL_NAME RALPH_RESULT_WINDOWING_NORMALIZED_TOOL_NAME
    ralph_hook_telemetry_append_windowing_log \
      "$workspace" \
      "$plan_key" \
      "bash" \
      "$original_bytes" \
      "$returned_bytes" \
      "$original_tokens" \
      "$returned_tokens" \
      0 \
      "$result_id" \
      "" \
      "${plan_key_fallback:-}" \
      "${plan_key_fallback_reason:-}"
    unset RALPH_RESULT_WINDOWING_CHANNEL RALPH_RESULT_WINDOWING_SURFACED_TOOL_NAME RALPH_RESULT_WINDOWING_NORMALIZED_TOOL_NAME
  fi

  jq -nc \
    --arg command "$command" \
    --argjson exitCode "$exit_code" \
    --arg preview "$preview_text" \
    --arg rawCombined "$raw_combined" \
    --argjson storeNeeded "$store_needed" \
    --argjson compactedApplied "$compacted_applied" \
    --argjson originalBytes "$original_bytes" \
    --argjson returnedBytes "$returned_bytes" \
    --arg resultId "$result_id" \
    --arg resultPath "$result_path" \
    --argjson stdoutCompacted "$stdout_compacted" \
    --argjson stderrCompacted "$stderr_compacted" \
    --arg compactJson "$compact_json" \
    --arg includeTokens "$include_tokens" \
    --argjson originalTokens "${original_tokens:-0}" \
    --argjson returnedTokens "${returned_tokens:-0}" \
    '{
      command: $command,
      exitCode: $exitCode,
      preview: $preview,
      rawCombined: $rawCombined,
      storeNeeded: $storeNeeded,
      compactedApplied: $compactedApplied,
      originalBytes: $originalBytes,
      returnedBytes: $returnedBytes,
      resultId: $resultId,
      resultPath: $resultPath,
      stdoutCompacted: $stdoutCompacted,
      stderrCompacted: $stderrCompacted,
      compactJson: $compactJson
    }
    | if $includeTokens == "true" then
        . + {originalTokens: $originalTokens, returnedTokens: $returnedTokens}
      else
        .
      end'
}

ralph_native_shell_wrapper_parse_args() {
  RALPH_NATIVE_SHELL_CLI_WORKSPACE="${RALPH_NATIVE_SHELL_CLI_WORKSPACE:-${RALPH_MCP_WORKSPACE:-}}"
  RALPH_NATIVE_SHELL_CLI_COMMAND="${RALPH_NATIVE_SHELL_CLI_COMMAND:-}"
  RALPH_NATIVE_SHELL_CLI_RUNTIME="${RALPH_NATIVE_SHELL_CLI_RUNTIME:-}"
  RALPH_NATIVE_SHELL_CLI_SHELL_EXE="${RALPH_NATIVE_SHELL_CLI_SHELL_EXE:-bash}"
  RALPH_NATIVE_SHELL_CLI_TIMEOUT="${RALPH_NATIVE_SHELL_CLI_TIMEOUT:-}"

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --workspace)
        RALPH_NATIVE_SHELL_CLI_WORKSPACE="${2:-}"
        shift 2
        ;;
      --command)
        RALPH_NATIVE_SHELL_CLI_COMMAND="${2:-}"
        shift 2
        ;;
      --runtime)
        RALPH_NATIVE_SHELL_CLI_RUNTIME="${2:-}"
        shift 2
        ;;
      --plan-key)
        RALPH_PLAN_KEY="${2:-}"
        shift 2
        ;;
      --shell-exe)
        RALPH_NATIVE_SHELL_CLI_SHELL_EXE="${2:-bash}"
        shift 2
        ;;
      --timeout)
        RALPH_NATIVE_SHELL_CLI_TIMEOUT="${2:-}"
        shift 2
        ;;
      -h | --help)
        cat <<'EOF'
Usage: native-shell-wrapper.sh --workspace PATH --command CMD [options]

Options:
  --workspace PATH   Project/workspace root (required)
  --command CMD      Shell command to execute (required)
  --runtime NAME     Runtime label for telemetry (optional)
  --plan-key KEY     Plan key for tool-result storage (default: RALPH_PLAN_KEY or default)
  --shell-exe PATH   Shell executable (default: bash)
  --timeout SEC      Command timeout seconds (default: 10)
EOF
        return 2
        ;;
      *)
        return 1
        ;;
    esac
  done

  [[ -n "$RALPH_NATIVE_SHELL_CLI_WORKSPACE" && -n "$RALPH_NATIVE_SHELL_CLI_COMMAND" ]]
}

# Run command with optional compaction; preserves exit code on stdout path.
ralph_native_shell_wrapper_run() {
  local workspace="${RALPH_NATIVE_SHELL_CLI_WORKSPACE:-}"
  local command="${RALPH_NATIVE_SHELL_CLI_COMMAND:-}"
  local shell_exe="${RALPH_NATIVE_SHELL_CLI_SHELL_EXE:-bash}"
  local timeout_sec="${RALPH_NATIVE_SHELL_CLI_TIMEOUT:-}"
  local max_shell_bytes="${RALPH_NATIVE_SHELL_MAX_BYTES:-32768}"
  local exec_json outcome_json preview raw exit_code store_needed result_path

  if ! ralph_native_shell_wrapper_enabled; then
    exec_json="$(ralph_native_shell_execute_command_json "$workspace" "$command" "$shell_exe" "$timeout_sec")" || return 127
    printf '%s' "$(ralph_mcp_proxy_shell_combine_streams "$(jq -r '.stdout // ""' <<<"$exec_json")" "$(jq -r '.stderr // ""' <<<"$exec_json")")"
    exit "$(jq -r '.exitCode // 0' <<<"$exec_json")"
  fi

  if ! ralph_native_shell_wrapper_libs_ready; then
    exec_json="$(ralph_native_shell_execute_command_json "$workspace" "$command" "$shell_exe" "$timeout_sec")" || return 127
    printf '%s' "$(ralph_mcp_proxy_shell_combine_streams "$(jq -r '.stdout // ""' <<<"$exec_json")" "$(jq -r '.stderr // ""' <<<"$exec_json")")"
    exit "$(jq -r '.exitCode // 0' <<<"$exec_json")"
  fi

  exec_json="$(ralph_native_shell_execute_command_json "$workspace" "$command" "$shell_exe" "$timeout_sec")" || return 127
  exit_code="$(jq -r '.exitCode // 0' <<<"$exec_json")"
  outcome_json="$(ralph_native_shell_compact_pipeline_json \
    "$workspace" \
    "$command" \
    "$(jq -r '.stdout // ""' <<<"$exec_json")" \
    "$(jq -r '.stderr // ""' <<<"$exec_json")" \
    "$exit_code" \
    "$max_shell_bytes" \
    "ralph_proxy_shell")"

  preview="$(jq -r '.preview // ""' <<<"$outcome_json")"
  raw="$(jq -r '.rawCombined // ""' <<<"$outcome_json")"
  store_needed="$(jq -r '.storeNeeded // false' <<<"$outcome_json")"
  result_path="$(jq -r '.resultPath // ""' <<<"$outcome_json")"
  compacted_applied="$(jq -r '.compactedApplied // false' <<<"$outcome_json")"

  if [[ "$store_needed" == "true" || "$store_needed" == "1" ]]; then
    if [[ -z "$result_path" ]]; then
      printf '%s' "$raw"
      exit "$exit_code"
    fi
    if [[ "$compacted_applied" == "true" || "$compacted_applied" == "1" ]]; then
      ralph_native_shell_append_footer "$preview" "$(ralph_native_shell_plain_footer "$result_path")"
    else
      ralph_native_shell_append_footer "$raw" "$(ralph_native_shell_plain_footer "$result_path")"
    fi
    exit "$exit_code"
  fi

  printf '%s' "$raw"
  exit "$exit_code"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  set -euo pipefail
  ralph_native_shell_wrapper_parse_args "$@" || {
    echo "native-shell-wrapper: missing --workspace or --command" >&2
    exit 2
  }
  ralph_native_shell_wrapper_run
fi
