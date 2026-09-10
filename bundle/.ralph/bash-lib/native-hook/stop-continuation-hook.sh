#!/usr/bin/env bash
# Runtime-neutral tier-1 Stop hook core: wait for an outstanding background job,
# emit a bounded continuation payload, and consume the job exactly once.
#
# stdin: hook payload JSON from the runtime adapter.
# stdout: neutral decision JSON (adapters serialize per runtime).
# exit 0: always (release turn or emit continuation decision).

set -uo pipefail

RALPH_BG_STOP_HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

ralph_bg_stop_hook_source_libs() {
  if [[ -z "${RALPH_BG_STOP_HOOK_LIBS_LOADED:-}" ]]; then
  # shellcheck source=../run-plan/run-plan-bg-job-state.sh
    source "$RALPH_BG_STOP_HOOK_DIR/../run-plan/run-plan-bg-job-state.sh"
    if ! declare -F ralph_native_shell_pid_running >/dev/null 2>&1; then
      # shellcheck source=native-shell-wrapper.sh
      source "$RALPH_BG_STOP_HOOK_DIR/native-shell-wrapper.sh"
    fi
    if ! declare -F ralph_wait >/dev/null 2>&1; then
      # shellcheck source=../ralph-wait.sh
      source "$RALPH_BG_STOP_HOOK_DIR/../ralph-wait.sh"
    fi
    if [[ -z "${RALPH_NATIVE_HOOK_LIB_LOADED:-}" ]]; then
      # shellcheck source=native-hook-lib.sh
      source "$RALPH_BG_STOP_HOOK_DIR/native-hook-lib.sh"
    fi
    RALPH_BG_STOP_HOOK_LIBS_LOADED=1
  fi
}

RALPH_BG_OUTPUT_MAX_BYTES="${RALPH_BG_OUTPUT_MAX_BYTES:-65536}"
RALPH_BG_JOB_TIMEOUT="${RALPH_BG_JOB_TIMEOUT:-3600}"
RALPH_BG_JOBS="${RALPH_BG_JOBS:-0}"
RALPH_BG_MAX_PER_TODO="${RALPH_BG_MAX_PER_TODO:-8}"

ralph_bg_stop_hook_debug() {
  local event="${1:-}" detail="${2:-}"
  [[ -n "${RALPH_CONTINUATION_DEBUG:-}" ]] || return 0
  printf '[ralph-bg-stop-hook] %s %s\n' "$event" "$detail" >&2
}

ralph_bg_stop_hook_emit_decision() {
  local decision="${1:-release}" release_reason="${2:-}" continuation_json="${3:-null}"
  jq -nc \
    --argjson version 1 \
    --arg decision "$decision" \
    --arg releaseReason "$release_reason" \
    --argjson continuation "$continuation_json" \
    '{
      version: $version,
      decision: $decision,
      releaseReason: (if $releaseReason == "" then null else $releaseReason end),
      continuation: $continuation
    }'
}

ralph_bg_stop_hook_release() {
  local reason="${1:-}"
  ralph_bg_stop_hook_debug "release" "${reason:-unspecified}"
  ralph_bg_stop_hook_emit_decision "release" "$reason" "null"
  exit 0
}

ralph_bg_stop_hook_require_context() {
  [[ -n "${RALPH_SESSION_DIR:-}" ]] || return 1
  [[ -n "${RALPH_PLAN_KEY:-}" ]] || return 1
  [[ -n "${RALPH_CURRENT_TODO_LINE:-}" && -n "${RALPH_CURRENT_TODO_ORDINAL:-}" && -n "${RALPH_CURRENT_TODO_HASH:-}" ]] || return 1
  command -v jq >/dev/null 2>&1 || return 1
  return 0
}

ralph_bg_stop_hook_attempt_storage_key() {
  local attempt_key="${1:-}"
  local digest
  attempt_key="$(jq -r '.' <<<"${attempt_key:-$(ralph_bg_job_attempt_key "$(ralph_bg_job_identity_json)")}")"
  if command -v python3 >/dev/null 2>&1; then
    digest="$(python3 - "$attempt_key" <<'PYTHON'
import hashlib
import sys
print(hashlib.sha256(sys.argv[1].encode("utf-8")).hexdigest()[:24])
PYTHON
)"
  else
    digest="$(printf '%s' "$attempt_key" | shasum -a 256 2>/dev/null | awk '{print substr($1,1,24)}')"
  fi
  [[ -n "$digest" ]] || digest="unknown"
  printf '%s\n' "$digest"
}

ralph_bg_stop_hook_guard_path() {
  local attempt_key="${1:-}"
  local key digest
  key="$(ralph_bg_stop_hook_attempt_storage_key "$attempt_key")"
  printf '%s/bg-stop-hook/%s.json\n' "$RALPH_SESSION_DIR" "$key"
}

ralph_bg_stop_hook_guard_read() {
  local attempt_key="${1:-}" path
  path="$(ralph_bg_stop_hook_guard_path "$attempt_key")" || return 1
  [[ -f "$path" ]] || {
    printf '%s\n' "0"
    return 0
  }
  jq -r '.continuation_count // 0' "$path" 2>/dev/null || printf '%s\n' "0"
}

ralph_bg_stop_hook_guard_increment() {
  local attempt_key="${1:-}" path count now_iso payload
  path="$(ralph_bg_stop_hook_guard_path "$attempt_key")" || return 1
  mkdir -p "$(dirname "$path")"
  count="$(ralph_bg_stop_hook_guard_read "$attempt_key")"
  [[ "$count" =~ ^[0-9]+$ ]] || count=0
  count=$((count + 1))
  now_iso="$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u)"
  payload="$(jq -nc --argjson continuation_count "$count" --arg updated_at "$now_iso" '{continuation_count:$continuation_count,updated_at:$updated_at}')"
  printf '%s\n' "$payload" >"${path}.tmp" && mv -f "${path}.tmp" "$path"
  printf '%s\n' "$count"
}

ralph_bg_stop_hook_runtime_guard_active() {
  local hook_input="${1:-}"
  local stop_active loop_count loop_limit

  stop_active="$(jq -r '.stop_hook_active // .hookSpecificOutput.stop_hook_active // false' <<<"$hook_input" 2>/dev/null || printf 'false')"
  case "$stop_active" in
    true | 1 | yes | on) return 0 ;;
  esac

  loop_count="$(jq -r '.loop_count // .hookSpecificOutput.loop_count // empty' <<<"$hook_input" 2>/dev/null || true)"
  loop_limit="$(jq -r '.loop_limit // .hookSpecificOutput.loop_limit // 5' <<<"$hook_input" 2>/dev/null || true)"
  if [[ "$loop_count" =~ ^[0-9]+$ && "$loop_limit" =~ ^[0-9]+$ ]]; then
    if (( loop_count >= loop_limit )); then
      return 0
    fi
  fi
  return 1
}

ralph_bg_stop_hook_command_summary() {
  local command="${1:-}" suffix prefix_len
  command="$(printf '%s' "$command" | tr '\n\r' ' ' | sed -E 's/[[:space:]]+/ /g')"
  command="$(printf '%s' "$command" | sed -E 's/(TOKEN|PASSWORD|SECRET|API_KEY|AUTH)=[^[:space:]]+/\1=[REDACTED]/gi')"
  if [[ ${#command} -gt 160 ]]; then
    if [[ "$command" == *"[REDACTED]"* ]]; then
      suffix="${command##* }"
      if [[ "$suffix" == *"[REDACTED]"* && ${#suffix} -lt 160 ]]; then
        prefix_len=$((160 - ${#suffix} - 4))
        (( prefix_len < 0 )) && prefix_len=0
        command="${command:0:$prefix_len}... $suffix"
      else
        command="${command:0:157}..."
      fi
    else
      command="${command:0:157}..."
    fi
  fi
  printf '%s' "$command"
}

ralph_bg_stop_hook_record_matches_attempt() {
  local record="${1:-}" attempt_key="${2:-}"
  local record_key
  record_key="$(ralph_bg_job_attempt_key "$(jq -c '.identity' <<<"$record")")"
  [[ "$record_key" == "$attempt_key" ]]
}

ralph_bg_stop_hook_find_job_for_attempt() {
  local attempt_key="${1:-$(ralph_bg_job_attempt_key "$(ralph_bg_job_identity_json)")}"
  local outstanding_id="" terminal_id="" record state job_id reason

  while IFS= read -r record; do
    [[ -n "$record" ]] || continue
    ralph_bg_stop_hook_record_matches_attempt "$record" "$attempt_key" || continue
    reason="$(ralph_bg_job_record_malformed_reason "$record")"
    if [[ -n "$reason" ]]; then
      continue
    fi
    reason="$(ralph_bg_job_identity_mismatch_reason "$record")"
    if [[ -n "$reason" ]]; then
      continue
    fi
    state="$(jq -r '.state // empty' <<<"$record")"
    job_id="$(jq -r '.job_id // empty' <<<"$record")"
    [[ -n "$job_id" ]] || continue
    case "$state" in
      "$RALPH_BG_JOB_STATE_REQUESTED" | "$RALPH_BG_JOB_STATE_LAUNCHED" | "$RALPH_BG_JOB_STATE_RUNNING")
        outstanding_id="$job_id"
        break
        ;;
      "$RALPH_BG_JOB_STATE_TERMINAL")
        [[ -z "$terminal_id" ]] && terminal_id="$job_id"
        ;;
    esac
  done < <(ralph_bg_job_list_records)

  if [[ -n "$outstanding_id" ]]; then
    printf '%s\n' "$outstanding_id"
    return 0
  fi
  if [[ -n "$terminal_id" ]]; then
    printf '%s\n' "$terminal_id"
    return 0
  fi
  return 1
}

ralph_bg_stop_hook_job_dir() {
  local job_id="${1:-}"
  ralph_bg_job_dir "$job_id"
}

ralph_bg_stop_hook_combine_output() {
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

ralph_bg_stop_hook_cap_text() {
  local text="${1-}" max_bytes="${2:-65536}"
  [[ "$max_bytes" =~ ^[0-9]+$ ]] || max_bytes=65536
  if [[ ${#text} -gt "$max_bytes" ]]; then
    text="${text:0:$max_bytes}"
  fi
  printf '%s' "$text"
}

ralph_bg_stop_hook_tail_bytes() {
  local file_path="${1:-}" max_bytes="${2:-4096}"
  [[ -f "$file_path" ]] || return 0
  [[ "$max_bytes" =~ ^[0-9]+$ && "$max_bytes" -gt 0 ]] || max_bytes=4096
  tail -c "$max_bytes" "$file_path" 2>/dev/null || true
}

ralph_bg_stop_hook_read_exit_code() {
  local job_dir="${1:-}" pid="${2:-}"
  local exit_code=""

  if [[ -f "$job_dir/exit_code" ]]; then
    exit_code="$(tr -d '[:space:]' <"$job_dir/exit_code" 2>/dev/null || true)"
    [[ "$exit_code" =~ ^-?[0-9]+$ ]] && {
      printf '%s\n' "$exit_code"
      return 0
    }
  fi

  if [[ "$pid" =~ ^[0-9]+$ && "$pid" -gt 0 ]]; then
    if ! ralph_native_shell_pid_running "$pid"; then
      if [[ ! -s "$job_dir/stderr" ]]; then
        printf '0\n'
        return 0
      fi
      printf '1\n'
      return 0
    fi
    set +e
    wait "$pid" 2>/dev/null
    exit_code=$?
    set -e
    if [[ "$exit_code" -eq 127 ]]; then
      if [[ ! -s "$job_dir/stderr" ]]; then
        printf '0\n'
        return 0
      fi
      printf '1\n'
      return 0
    fi
    if [[ "$exit_code" =~ ^-?[0-9]+$ ]]; then
      printf '%s\n' "$exit_code"
      return 0
    fi
  fi
  return 1
}

ralph_bg_stop_hook_terminal_status_for_exit() {
  local exit_code="${1:-}" timed_out="${2:-0}" cancelled="${3:-0}" owner_dead="${4:-0}"
  if [[ "$owner_dead" == "1" ]]; then
    printf '%s\n' "$RALPH_BG_JOB_TERMINAL_INTERRUPTED"
    return 0
  fi
  if [[ "$cancelled" == "1" ]]; then
    printf '%s\n' "$RALPH_BG_JOB_TERMINAL_CANCELLED"
    return 0
  fi
  if [[ "$timed_out" == "1" || "$exit_code" == "124" || "$exit_code" == "137" ]]; then
    printf '%s\n' "$RALPH_BG_JOB_TERMINAL_TIMED_OUT"
    return 0
  fi
  if [[ "$exit_code" =~ ^-?[0-9]+$ ]]; then
    if (( exit_code == 0 )); then
      printf '%s\n' "$RALPH_BG_JOB_TERMINAL_PASSED"
    else
      printf '%s\n' "$RALPH_BG_JOB_TERMINAL_FAILED"
    fi
    return 0
  fi
  printf '%s\n' "$RALPH_BG_JOB_TERMINAL_UNKNOWN"
}

ralph_bg_stop_hook_store_result() {
  local workspace="${1:-}" plan_key="${2:-}" combined="${3:-}" command_summary="${4:-}" status="${5:-}" exit_code="${6:-0}"
  local result_id="" result_path="" store_script metadata_json

  workspace="${workspace:-${RALPH_AGENT_WORKSPACE:-${RALPH_PROJECT_ROOT:-}}}"
  plan_key="${plan_key:-${RALPH_PLAN_KEY:-}}"
  [[ -n "$workspace" && -n "$plan_key" ]] || return 1

  store_script="$(ralph_native_hook_resolve_bash_lib "$workspace" "mcp-proxy/mcp-proxy-result-store.sh" 2>/dev/null || true)"
  [[ -n "$store_script" && -f "$store_script" ]] || return 1
  if [[ -z "${RALPH_MCP_PROXY_RESULT_STORE_LOADED:-}" ]]; then
    # shellcheck source=/dev/null
    source "$store_script"
    RALPH_MCP_PROXY_RESULT_STORE_LOADED=1
  fi

  metadata_json="$(jq -nc \
    --arg commandSummary "$command_summary" \
    --arg status "$status" \
    --argjson exitCode "${exit_code:-0}" \
    '{commandSummary:$commandSummary,status:$status,exitCode:$exitCode,storageLayout:"bg-job"}')"
  result_id="$(ralph_mcp_proxy_result_store_write "$workspace" "$plan_key" "$combined" "ralph_bg_job" "$metadata_json" 2>/dev/null || true)"
  [[ -n "$result_id" ]] || return 1
  result_path="$(ralph_mcp_proxy_result_store_resolve_result_path "$workspace" "$plan_key" "$result_id" 2>/dev/null || true)"
  jq -nc --arg resultId "$result_id" --arg resultPath "${result_path:-}" '{resultId:$resultId,resultPath:(if $resultPath == "" then null else $resultPath end)}'
}

ralph_bg_stop_hook_wait_for_process() {
  local job_id="${1:-}" record="${2:-}"
  local job_dir pid pgid isolated timeout_sec start_epoch now elapsed
  local negative_checks=0 job_start owner_pid owner_start

  job_dir="$(ralph_bg_stop_hook_job_dir "$job_id")" || return 1
  pid="$(jq -r '.job_pid // 0' <<<"$record")"
  pgid="$(jq -r '.job_pid // 0' <<<"$record")"
  isolated="$(jq -r '.isolated // false' <<<"$record")"
  job_start="$(jq -r '.job_process_start_id // empty' <<<"$record")"
  owner_pid="$(jq -r '.owner_pid // 0' <<<"$record")"
  owner_start="$(jq -r '.owner_process_start_id // empty' <<<"$record")"
  timeout_sec="$(jq -r '.timeout_seconds // 3600' <<<"$record")"
  [[ "$timeout_sec" =~ ^[0-9]+$ ]] || timeout_sec=3600

  start_epoch="$(date +%s)"
  created_at="$(jq -r '.created_at // empty' <<<"$record")"
  if [[ -n "$created_at" ]]; then
  if command -v python3 >/dev/null 2>&1; then
    start_epoch="$(python3 - "$created_at" <<'PYTHON'
import sys
from datetime import datetime, timezone
text = sys.argv[1]
for fmt in ("%Y-%m-%dT%H:%M:%SZ",):
    try:
        dt = datetime.strptime(text, fmt).replace(tzinfo=timezone.utc)
        print(int(dt.timestamp()))
        raise SystemExit(0)
    except ValueError:
        pass
print(int(datetime.now(tz=timezone.utc).timestamp()))
PYTHON
)"
  fi
  fi

  while :; do
    record="$(ralph_bg_job_read "$job_id" 2>/dev/null || true)"
    [[ -n "$record" ]] || break
    case "$(jq -r '.state' <<<"$record")" in
      "$RALPH_BG_JOB_STATE_TERMINAL")
        printf '%s\n' "$record"
        return 0
        ;;
      "$RALPH_BG_JOB_STATE_CONSUMED")
        printf '%s\n' "$record"
        return 0
        ;;
    esac

    now="$(date +%s)"
    elapsed=$((now - start_epoch))
    if (( elapsed >= timeout_sec )); then
      if [[ "$pid" =~ ^[0-9]+$ && "$pid" -gt 0 ]]; then
        if ralph_native_shell_pid_running "$pid" "$job_start"; then
          ralph_native_shell_terminate_spawned_job "$pid" "$pgid" "$isolated" 1 >/dev/null || true
        fi
      fi
      printf '%s\n' "timed_out"
      return 0
    fi

    if [[ "$owner_pid" =~ ^[0-9]+$ && "$owner_pid" -gt 0 ]]; then
      if ! ralph_native_shell_pid_running "$owner_pid" "$owner_start"; then
        if [[ "$pid" =~ ^[0-9]+$ && "$pid" -gt 0 ]]; then
          if ralph_native_shell_pid_running "$pid" "$job_start"; then
            ralph_native_shell_terminate_spawned_job "$pid" "$pgid" "$isolated" 1 >/dev/null || true
          fi
        fi
        printf '%s\n' "owner-dead"
        return 0
      fi
    fi

    if [[ "$pid" =~ ^[0-9]+$ && "$pid" -gt 0 ]]; then
      if ralph_native_shell_pid_running "$pid" "$job_start"; then
        negative_checks=0
      else
        negative_checks=$((negative_checks + 1))
        if (( negative_checks >= 2 )); then
          printf '%s\n' "exited"
          return 0
        fi
      fi
    else
      negative_checks=$((negative_checks + 1))
      if (( negative_checks >= 2 )); then
        printf '%s\n' "no-pid"
        return 0
      fi
    fi

    ralph_wait 0.1
  done

  printf '%s\n' "lost"
}

ralph_bg_stop_hook_finalize_job() {
  local job_id="${1:-}" wait_outcome="${2:-exited}"
  local record state job_dir stdout stderr combined preview max_bytes command command_summary
  local pid exit_code terminal_status elapsed start_epoch now_epoch result_json result_id result_path
  local workspace plan_key timed_out created_at

  record="$(ralph_bg_job_read "$job_id")" || return 1
  state="$(jq -r '.state' <<<"$record")"
  if [[ "$state" == "$RALPH_BG_JOB_STATE_CONSUMED" ]]; then
    return 1
  fi

  job_dir="$(ralph_bg_stop_hook_job_dir "$job_id")" || return 1
  command="$(jq -r '.command // ""' <<<"$record")"
  command_summary="$(ralph_bg_stop_hook_command_summary "$command")"
  pid="$(jq -r '.job_pid // 0' <<<"$record")"
  max_bytes="$RALPH_BG_OUTPUT_MAX_BYTES"
  [[ "$max_bytes" =~ ^[0-9]+$ ]] || max_bytes=65536

  start_epoch="$(date +%s)"
  created_at="$(jq -r '.created_at // empty' <<<"$record")"
  if [[ -n "$created_at" ]] && command -v python3 >/dev/null 2>&1; then
    start_epoch="$(python3 - "$created_at" <<'PYTHON'
import sys
from datetime import datetime, timezone
text = sys.argv[1]
try:
    dt = datetime.strptime(text, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc)
    print(int(dt.timestamp()))
except ValueError:
    print(int(datetime.now(tz=timezone.utc).timestamp()))
PYTHON
)"
  fi
  now_epoch="$(date +%s)"
  elapsed=$((now_epoch - start_epoch))
  (( elapsed < 0 )) && elapsed=0

  timed_out=0
  exit_code=""
  owner_dead=0
  if [[ "$state" == "$RALPH_BG_JOB_STATE_TERMINAL" ]]; then
    terminal_status="$(jq -r '.terminal_status // empty' <<<"$record")"
    if exit_code="$(ralph_bg_stop_hook_read_exit_code "$job_dir" "$pid")"; then
      :
    else
      exit_code=""
    fi
    if [[ "$terminal_status" == "$RALPH_BG_JOB_TERMINAL_TIMED_OUT" ]]; then
      timed_out=1
      [[ "$exit_code" =~ ^-?[0-9]+$ ]] || exit_code=124
    fi
  else
    if [[ "$wait_outcome" == "timed_out" ]]; then
      timed_out=1
      exit_code=124
    elif [[ "$wait_outcome" == "owner-dead" ]]; then
      owner_dead=1
      exit_code=130
    elif exit_code="$(ralph_bg_stop_hook_read_exit_code "$job_dir" "$pid")"; then
      :
    else
      exit_code=""
    fi
    terminal_status="$(ralph_bg_stop_hook_terminal_status_for_exit "${exit_code:-}" "$timed_out" 0 "$owner_dead")"
    if [[ "$state" == "$RALPH_BG_JOB_STATE_RUNNING" || "$state" == "$RALPH_BG_JOB_STATE_LAUNCHED" ]]; then
      ralph_bg_job_mark_terminal "$job_id" "$terminal_status" >/dev/null || true
      record="$(ralph_bg_job_read "$job_id")" || return 1
      state="$(jq -r '.state' <<<"$record")"
    fi
  fi

  [[ -n "$terminal_status" ]] || terminal_status="$RALPH_BG_JOB_TERMINAL_UNKNOWN"

  stdout="$(cat "$job_dir/stdout" 2>/dev/null || true)"
  stderr="$(cat "$job_dir/stderr" 2>/dev/null || true)"
  combined="$(ralph_bg_stop_hook_combine_output "$stdout" "$stderr")"
  preview="$(ralph_bg_stop_hook_cap_text "$(ralph_bg_stop_hook_tail_bytes "$job_dir/stdout" "$max_bytes")" "$max_bytes")"
  if [[ -z "$preview" ]]; then
    preview="$(ralph_bg_stop_hook_cap_text "$(ralph_bg_stop_hook_tail_bytes "$job_dir/stderr" "$max_bytes")" "$max_bytes")"
  fi

  workspace="${RALPH_AGENT_WORKSPACE:-${RALPH_PROJECT_ROOT:-}}"
  plan_key="${RALPH_PLAN_KEY:-}"
  result_id=""
  result_path=""
  if [[ -n "$combined" ]]; then
    result_json="$(ralph_bg_stop_hook_store_result "$workspace" "$plan_key" "$combined" "$command_summary" "$terminal_status" "${exit_code:-0}" 2>/dev/null || true)"
    if [[ -n "$result_json" ]]; then
      result_id="$(jq -r '.resultId // empty' <<<"$result_json")"
      result_path="$(jq -r '.resultPath // empty' <<<"$result_json")"
    fi
  fi

  jq -nc \
    --arg jobId "$job_id" \
    --arg commandSummary "$command_summary" \
    --arg status "$terminal_status" \
    --arg preview "$preview" \
    --arg resultId "$result_id" \
    --arg resultPath "$result_path" \
    --argjson elapsedSeconds "$elapsed" \
    --argjson exitCode "$(if [[ "$exit_code" =~ ^-?[0-9]+$ ]]; then printf '%s' "$exit_code"; else printf 'null'; fi)" \
    '{
      jobId: $jobId,
      commandSummary: $commandSummary,
      status: $status,
      exitCode: $exitCode,
      elapsedSeconds: $elapsedSeconds,
      resultId: (if $resultId == "" then null else $resultId end),
      resultPath: (if $resultPath == "" then null else $resultPath end),
      preview: $preview
    }'
}

ralph_bg_stop_hook_continue_with_payload() {
  local continuation_json="${1:-}"
  ralph_bg_stop_hook_debug "continue" "$(jq -r '.jobId // empty' <<<"$continuation_json")"
  ralph_bg_stop_hook_emit_decision "continue" "" "$continuation_json"
  exit 0
}

ralph_bg_stop_hook_main() {
  local hook_input="${1:-}"
  local attempt_key job_id record state wait_outcome continuation_json guard_count max_per_todo

  ralph_bg_stop_hook_source_libs

  if ! ralph_bg_stop_hook_require_context; then
    ralph_bg_stop_hook_release "missing-context"
  fi

  if [[ "$RALPH_BG_JOBS" == "0" ]]; then
    ralph_bg_stop_hook_release "bg-jobs-disabled"
  fi

  if ralph_bg_stop_hook_runtime_guard_active "$hook_input"; then
    ralph_bg_stop_hook_release "runtime-guard-active"
  fi

  attempt_key="$(ralph_bg_job_attempt_key "$(ralph_bg_job_identity_json)")"
  max_per_todo="$RALPH_BG_MAX_PER_TODO"
  [[ "$max_per_todo" =~ ^[0-9]+$ ]] || max_per_todo=8
  guard_count="$(ralph_bg_stop_hook_guard_read "$attempt_key")"
  [[ "$guard_count" =~ ^[0-9]+$ ]] || guard_count=0
  if (( guard_count >= max_per_todo )); then
    ralph_bg_stop_hook_release "continuation-cap"
  fi

  if ! job_id="$(ralph_bg_stop_hook_find_job_for_attempt "$attempt_key")"; then
    ralph_bg_stop_hook_release "no-outstanding-job"
  fi

  record="$(ralph_bg_job_read "$job_id" 1 2>/dev/null || ralph_bg_job_read "$job_id" 2>/dev/null || true)"
  if [[ -z "$record" ]]; then
    ralph_bg_stop_hook_release "job-unreadable"
  fi

  state="$(jq -r '.state' <<<"$record")"
  if [[ "$state" == "$RALPH_BG_JOB_STATE_CONSUMED" ]]; then
    ralph_bg_stop_hook_release "already-consumed"
  fi

  wait_outcome="ready"
  case "$state" in
    "$RALPH_BG_JOB_STATE_REQUESTED" | "$RALPH_BG_JOB_STATE_LAUNCHED" | "$RALPH_BG_JOB_STATE_RUNNING")
      wait_outcome="$(ralph_bg_stop_hook_wait_for_process "$job_id" "$record")"
      record="$(ralph_bg_job_read "$job_id" 1 2>/dev/null || ralph_bg_job_read "$job_id" 2>/dev/null || true)"
      state="$(jq -r '.state // empty' <<<"$record")"
      if [[ "$state" == "$RALPH_BG_JOB_STATE_CONSUMED" ]]; then
        ralph_bg_stop_hook_release "already-consumed"
      fi
      ;;
  esac

  continuation_json="$(ralph_bg_stop_hook_finalize_job "$job_id" "$wait_outcome")" || ralph_bg_stop_hook_release "finalize-failed"

  state="$(ralph_bg_job_read "$job_id" 1 2>/dev/null || ralph_bg_job_read "$job_id" 2>/dev/null || true)"
  state="$(jq -r '.state' <<<"$state")"
  if [[ "$state" == "$RALPH_BG_JOB_STATE_TERMINAL" ]]; then
    ralph_bg_job_consume "$job_id" >/dev/null || ralph_bg_stop_hook_release "consume-failed"
  elif [[ "$state" == "$RALPH_BG_JOB_STATE_CONSUMED" ]]; then
  :
  else
    ralph_bg_stop_hook_release "not-terminal"
  fi

  ralph_bg_stop_hook_guard_increment "$attempt_key" >/dev/null
  ralph_bg_stop_hook_continue_with_payload "$continuation_json"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  hook_input="$(cat)" || hook_input="{}"
  ralph_bg_stop_hook_main "$hook_input"
fi
