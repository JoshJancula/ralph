# shellcheck shell=bash
# Shared telemetry helpers for Claude native Bash hooks (JSONL audit logs).

ralph_hook_telemetry_enabled() {
  case "${RALPH_HOOK_TELEMETRY:-}" in
    0 | false | no | off) return 1 ;;
    1 | true | yes | on) return 0 ;;
  esac
  return 0
}

ralph_hook_windowing_telemetry_enabled() {
  ralph_hook_telemetry_enabled || return 1
  case "${RALPH_HOOK_WINDOWING_TELEMETRY:-}" in
    0 | false | no | off) return 1 ;;
    1 | true | yes | on) return 0 ;;
  esac
  return 0
}

ralph_hook_telemetry_sha256() {
  local text="${1-}"
  if command -v python3 >/dev/null 2>&1; then
    python3 -c 'import hashlib, sys; print(hashlib.sha256(sys.argv[1].encode("utf-8")).hexdigest())' "$text"
    return 0
  fi
  if command -v sha256sum >/dev/null 2>&1; then
    printf '%s' "$text" | sha256sum | awk '{print $1}'
    return 0
  fi
  if command -v shasum >/dev/null 2>&1; then
    printf '%s' "$text" | shasum -a 256 | awk '{print $1}'
    return 0
  fi
  if command -v openssl >/dev/null 2>&1; then
    printf '%s' "$text" | openssl dgst -sha256 | awk '{print $NF}'
    return 0
  fi
  printf ''
}

ralph_hook_telemetry_utf8_byte_count() {
  local text="${1-}"
  if command -v python3 >/dev/null 2>&1; then
    python3 -c 'import sys; print(len(sys.argv[1].encode("utf-8")))' "$text"
    return 0
  fi
  printf '%s' "$text" | wc -c | tr -d ' '
}

ralph_hook_telemetry_combine_streams() {
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

ralph_hook_telemetry_append_jsonl() {
  local log_path="${1:-}"
  local line="${2:-}"
  [[ -n "$log_path" && -n "$line" ]] || return 0
  ralph_hook_telemetry_enabled || return 0
  mkdir -p "$(dirname "$log_path")" 2>/dev/null || true
  printf '%s\n' "$line" >>"$log_path" 2>/dev/null || true
}

# Build one JSON object for bash output compaction telemetry.
# Args: workspace plan_key command compact_json original_stdout original_stderr
#       storage_path exit_code
ralph_hook_telemetry_compact_record_json() {
  local workspace="${1:-}" plan_key="${2:-}" command="${3:-}" compact_json="${4:-}"
  local original_stdout="${5-}" original_stderr="${6-}" storage_path="${7-}"
  local exit_code="${8:-0}"

  local original_combined compact_stdout compact_stderr compact_combined
  local original_bytes compacted_bytes command_hash compaction_skipped family
  local timestamp

  original_combined="$(ralph_hook_telemetry_combine_streams "$original_stdout" "$original_stderr")"
  original_bytes="$(ralph_hook_telemetry_utf8_byte_count "$original_combined")"
  command_hash="$(ralph_hook_telemetry_sha256 "$command")"

  compact_stdout="$(jq -r '.stdout // ""' <<<"$compact_json")"
  compact_stderr="$(jq -r '.stderr // ""' <<<"$compact_json")"
  compact_combined="$(ralph_hook_telemetry_combine_streams "$compact_stdout" "$compact_stderr")"
  compacted_bytes="$(ralph_hook_telemetry_utf8_byte_count "$compact_combined")"
  family="$(jq -r '.family // empty' <<<"$compact_json")"
  if [[ "$(jq -r '.status // ""' <<<"$compact_json")" == "compacted" ]]; then
    compaction_skipped="false"
  else
    compaction_skipped="true"
  fi

  timestamp="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  jq -nc \
    --arg timestamp "$timestamp" \
    --arg workspace "$workspace" \
    --arg planKey "$plan_key" \
    --arg commandHash "$command_hash" \
    --argjson originalBytes "$original_bytes" \
    --argjson compactedBytes "$compacted_bytes" \
    --arg storagePath "$storage_path" \
    --argjson compactionSkipped "$compaction_skipped" \
    --argjson exitCode "$exit_code" \
    --arg family "$family" \
    '{
      timestamp: $timestamp,
      workspace: $workspace,
      planKey: $planKey,
      commandHash: $commandHash,
      originalBytes: $originalBytes,
      compactedBytes: $compactedBytes,
      storagePath: (if $storagePath == "" then null else $storagePath end),
      compactionSkipped: $compactionSkipped,
      exitCode: $exitCode,
      family: (if $family == "" then null else $family end)
    }'
}

# Build one JSON object for bash command rewrite telemetry.
# rewrite_applied: true when the hook replaced tool_input; false for audit-only rows.
ralph_hook_telemetry_rewrite_record_json() {
  local workspace="${1:-}" plan_key="${2:-}" original_command="${3:-}"
  local rewritten_command="${4:-}" rule_id="${5:-}" rewrite_applied="${6:-true}"

  local timestamp original_hash rewritten_hash applied_json reason
  timestamp="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  original_hash="$(ralph_hook_telemetry_sha256 "$original_command")"
  rewritten_hash="$(ralph_hook_telemetry_sha256 "$rewritten_command")"
  if [[ "$rewrite_applied" == "1" || "$rewrite_applied" == "true" ]]; then
    applied_json="true"
  else
    applied_json="false"
  fi

  jq -nc \
    --arg timestamp "$timestamp" \
    --arg workspace "$workspace" \
    --arg planKey "$plan_key" \
    --arg command "$original_command" \
    --arg rewrittenCommand "$rewritten_command" \
    --arg originalCommandHash "$original_hash" \
    --arg rewrittenCommandHash "$rewritten_hash" \
    --arg ruleId "$rule_id" \
    --argjson rewriteApplied "$applied_json" \
    '{
      timestamp: $timestamp,
      workspace: $workspace,
      planKey: $planKey,
      command: $command,
      rewrittenCommand: $rewrittenCommand,
      originalCommandHash: $originalCommandHash,
      rewrittenCommandHash: $rewrittenCommandHash,
      reason: (if $ruleId == "" then null else $ruleId end),
      rewriteApplied: $rewriteApplied,
      ruleId: (if $ruleId == "" then null else $ruleId end)
    }'
}

ralph_hook_telemetry_append_compact_log() {
  local workspace="${1:-}" plan_key="${2:-}" command="${3:-}" compact_json="${4:-}"
  local original_stdout="${5-}" original_stderr="${6-}" storage_path="${7-}"
  local exit_code="${8:-0}" log_path="${9:-}"
  local line

  ralph_hook_telemetry_enabled || return 0

  if [[ -z "$log_path" ]]; then
    log_path="${RALPH_BASH_COMPACT_LOG:-}"
  fi
  [[ -n "$log_path" ]] || return 0
  line="$(ralph_hook_telemetry_compact_record_json \
    "$workspace" \
    "$plan_key" \
    "$command" \
    "$compact_json" \
    "$original_stdout" \
    "$original_stderr" \
    "$storage_path" \
    "$exit_code")"
  ralph_hook_telemetry_append_jsonl "$log_path" "$line"
}

# Build one JSON object for MCP/native result windowing (envelope) telemetry.
# Args: workspace plan_key tool_name original_bytes returned_bytes
#       original_tokens returned_tokens token_cap_triggered [result_id]
# The optional result_id ties this envelope record to any later readback
# records (see ralph_hook_telemetry_append_result_readback_log) so savings
# accounting can net out raw-view escalations for the same stored result.
ralph_hook_telemetry_windowing_record_json() {
  local workspace="${1:-}" plan_key="${2:-}" tool_name="${3:-}"
  local original_bytes="${4:-0}" returned_bytes="${5:-0}"
  local original_tokens="${6:-}" returned_tokens="${7:-}" token_cap_triggered="${8:-0}"
  local result_id="${9:-}"
  local timestamp token_cap_json

  timestamp="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  if [[ "$token_cap_triggered" == "1" ]]; then
    token_cap_json="true"
  else
    token_cap_json="false"
  fi

  jq -nc \
    --arg timestamp "$timestamp" \
    --arg workspace "$workspace" \
    --arg planKey "$plan_key" \
    --arg toolName "$tool_name" \
    --argjson originalBytes "$original_bytes" \
    --argjson returnedBytes "$returned_bytes" \
    --argjson tokenCapTriggered "$token_cap_json" \
    --arg originalTokens "$original_tokens" \
    --arg returnedTokens "$returned_tokens" \
    --arg resultId "$result_id" \
    '{
      timestamp: $timestamp,
      workspace: $workspace,
      planKey: $planKey,
      toolName: (if $toolName == "" then null else $toolName end),
      event: "envelope",
      originalBytes: $originalBytes,
      returnedBytes: $returnedBytes,
      tokenCapTriggered: $tokenCapTriggered
    }
    + (if $originalTokens != "" and ($originalTokens | test("^[0-9]+$")) then {originalTokens: ($originalTokens | tonumber)} else {} end)
    + (if $returnedTokens != "" and ($returnedTokens | test("^[0-9]+$")) then {returnedTokens: ($returnedTokens | tonumber)} else {} end)
    + (if $resultId != "" then {resultId: $resultId} else {} end)'
}

ralph_hook_telemetry_append_windowing_log() {
  local workspace="${1:-}" plan_key="${2:-}" tool_name="${3:-}"
  local original_bytes="${4:-0}" returned_bytes="${5:-0}"
  local original_tokens="${6:-}" returned_tokens="${7:-}" token_cap_triggered="${8:-0}"
  local result_id="${9:-}"
  local log_path="${RALPH_RESULT_WINDOWING_LOG:-}"
  local line

  ralph_hook_windowing_telemetry_enabled || return 0

  [[ -n "$log_path" ]] || return 0
  [[ "$original_bytes" =~ ^[0-9]+$ ]] || original_bytes=0
  [[ "$returned_bytes" =~ ^[0-9]+$ ]] || returned_bytes=0
  if [[ "$original_bytes" -le 0 ]]; then
    return 0
  fi
  if [[ "$returned_bytes" -ge "$original_bytes" ]]; then
    return 0
  fi
  line="$(ralph_hook_telemetry_windowing_record_json \
    "$workspace" \
    "$plan_key" \
    "$tool_name" \
    "$original_bytes" \
    "$returned_bytes" \
    "$original_tokens" \
    "$returned_tokens" \
    "$token_cap_triggered" \
    "$result_id")"
  ralph_hook_telemetry_append_jsonl "$log_path" "$line"
}

# Append a readback telemetry record for a raw/compacted escalation of a stored
# result (ralph_proxy_result_read / ralph_proxy_result_search). Unlike the
# envelope path, readbacks must always log -- they capture bytes the agent
# re-consumed after the compacted preview, so savings accounting can net them
# out per resultId. Args: workspace plan_key tool_name result_id view
#                         returned_bytes [returned_tokens] [reason]
# Optional reason values: search_followup, raw_exactness, verification,
# edit_followup, or any caller-defined tag. This lets follow-up analytics
# distinguish why a stored result was re-read.
ralph_hook_telemetry_append_result_readback_log() {
  local workspace="${1:-}" plan_key="${2:-}" tool_name="${3:-}"
  local result_id="${4:-}" view="${5:-}" returned_bytes="${6:-0}"
  local returned_tokens="${7:-}" reason="${8:-}"
  local log_path="${RALPH_RESULT_WINDOWING_LOG:-}"
  local timestamp line

  ralph_hook_windowing_telemetry_enabled || return 0

  [[ -n "$log_path" ]] || return 0
  [[ -n "$result_id" ]] || return 0
  [[ "$returned_bytes" =~ ^[0-9]+$ ]] || returned_bytes=0

  timestamp="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  line="$(jq -nc \
    --arg timestamp "$timestamp" \
    --arg workspace "$workspace" \
    --arg planKey "$plan_key" \
    --arg toolName "$tool_name" \
    --arg resultId "$result_id" \
    --arg view "$view" \
    --argjson returnedBytes "$returned_bytes" \
    --arg returnedTokens "$returned_tokens" \
    --arg reason "$reason" \
    '{
      timestamp: $timestamp,
      workspace: $workspace,
      planKey: $planKey,
      toolName: (if $toolName == "" then null else $toolName end),
      event: "readback",
      resultId: $resultId,
      view: (if $view == "" then "compacted" else $view end),
      returnedBytes: $returnedBytes
    }
    + (if $returnedTokens != "" and ($returnedTokens | test("^[0-9]+$")) then {returnedTokens: ($returnedTokens | tonumber)} else {} end)
    + (if $reason != "" then {reason: $reason} else {} end))'"
  ralph_hook_telemetry_append_jsonl "$log_path" "$line"
}

ralph_hook_telemetry_append_rewrite_log() {
  local workspace="${1:-}" plan_key="${2:-}" original_command="${3:-}"
  local rewritten_command="${4:-}" rule_id="${5:-}" rewrite_applied="${6:-true}"
  local log_path="${RALPH_BASH_REWRITE_LOG:-}"
  local line

  ralph_hook_telemetry_enabled || return 0

  [[ -n "$log_path" ]] || return 0
  line="$(ralph_hook_telemetry_rewrite_record_json \
    "$workspace" \
    "$plan_key" \
    "$original_command" \
    "$rewritten_command" \
    "$rule_id" \
    "$rewrite_applied")"
  ralph_hook_telemetry_append_jsonl "$log_path" "$line"
}
