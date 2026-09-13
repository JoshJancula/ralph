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
    printf '%s' "$text" \
      | python3 -c 'import hashlib, sys; print(hashlib.sha256(sys.stdin.buffer.read()).hexdigest())'
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
    printf '%s' "$text" | python3 -c 'import sys; print(len(sys.stdin.buffer.read()))'
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
  local plan_key_fallback="${9:-}" plan_key_fallback_reason="${10:-}"
  local delivered_bytes="${11:-}" delivered_tokens="${12:-}"
  local duration_ms="${13:-}" fingerprint="${14:-}"

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
    --arg planKeyFallback "$plan_key_fallback" \
    --arg planKeyFallbackReason "$plan_key_fallback_reason" \
    --arg deliveredBytes "$delivered_bytes" \
    --arg deliveredTokens "$delivered_tokens" \
    --arg durationMs "$duration_ms" \
    --arg fingerprint "$fingerprint" \
    '
    def is_nat($v): ($v != "") and ($v | test("^[0-9]+$"));
    {
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
    }
    + (if $planKeyFallback == "true" or $planKeyFallback == "false"
       then {planKeyFallback: ($planKeyFallback == "true")}
       else {} end)
    + (if $planKeyFallback == "true" and $planKeyFallbackReason != ""
       then {planKeyFallbackReason: $planKeyFallbackReason}
       else {} end)
    + (if is_nat($deliveredBytes) or is_nat($deliveredTokens) then {measurementVersion: 2} else {} end)
    + (if is_nat($deliveredBytes) then {deliveredBytes: ($deliveredBytes | tonumber)} else {} end)
    + (if is_nat($deliveredTokens) then {deliveredTokens: ($deliveredTokens | tonumber)} else {} end)
    + (if is_nat($durationMs) then {durationMs: ($durationMs | tonumber)} else {} end)
    + (if $fingerprint != "" then {fingerprint: $fingerprint} else {} end)'
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
  local plan_key_fallback="${10:-}" plan_key_fallback_reason="${11:-}"
  local delivered_bytes="${12:-}" delivered_tokens="${13:-}"
  local duration_ms="${14:-}" fingerprint="${15:-}"
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
    "$exit_code" \
    "$plan_key_fallback" \
    "$plan_key_fallback_reason" \
    "$delivered_bytes" \
    "$delivered_tokens" \
    "$duration_ms" \
    "$fingerprint")"
  ralph_hook_telemetry_append_jsonl "$log_path" "$line"
}

ralph_hook_telemetry_windowing_runtime() {
  local runtime="${RALPH_PLAN_RUNTIME:-${RALPH_NATIVE_SHELL_CLI_RUNTIME:-${RUNTIME:-}}}"
  printf '%s\n' "$runtime"
}

ralph_hook_telemetry_windowing_channel_for_tool() {
  local tool_name="${1:-}"
  case "$tool_name" in
    ralph_proxy_read) printf 'proxy_read_windowing\n' ;;
    ralph_proxy_grep | ralph_proxy_search) printf 'proxy_search_windowing\n' ;;
    *) printf '%s\n' "" ;;
  esac
}

ralph_hook_telemetry_windowing_resolve_channel() {
  local tool_name="${1:-}"
  local channel="${RALPH_RESULT_WINDOWING_CHANNEL:-}"
  if [[ -n "$channel" ]]; then
    printf '%s\n' "$channel"
    return 0
  fi
  channel="$(ralph_hook_telemetry_windowing_channel_for_tool "$tool_name")"
  printf '%s\n' "$channel"
}

ralph_hook_telemetry_windowing_resolve_tool_name() {
  local tool_name="${1:-}"
  if [[ -n "${RALPH_RESULT_WINDOWING_SURFACED_TOOL_NAME:-}" ]]; then
    printf '%s\n' "$RALPH_RESULT_WINDOWING_SURFACED_TOOL_NAME"
    return 0
  fi
  printf '%s\n' "$tool_name"
}

ralph_hook_telemetry_windowing_envelope_channels_init() {
  if [[ -z "${_RALPH_WINDOWING_ENVELOPE_CHANNELS_INIT:-}" ]]; then
    declare -gA _RALPH_WINDOWING_ENVELOPE_CHANNELS=()
    _RALPH_WINDOWING_ENVELOPE_CHANNELS_INIT=1
  fi
}

ralph_hook_telemetry_remember_envelope_channel() {
  local result_id="${1:-}" channel="${2:-}"
  [[ -n "$result_id" && -n "$channel" ]] || return 0
  ralph_hook_telemetry_windowing_envelope_channels_init
  _RALPH_WINDOWING_ENVELOPE_CHANNELS["$result_id"]="$channel"
}

ralph_hook_telemetry_log_lines_reversed() {
  local log_path="${1:-}"
  [[ -n "$log_path" && -f "$log_path" ]] || return 1
  if tail -r "$log_path" 2>/dev/null; then
    return 0
  fi
  tac "$log_path" 2>/dev/null
}

ralph_hook_telemetry_lookup_envelope_channel() {
  local result_id="${1:-}" log_path="${2:-${RALPH_RESULT_WINDOWING_LOG:-}}"
  local line channel=""
  [[ -n "$result_id" ]] || return 1
  ralph_hook_telemetry_windowing_envelope_channels_init
  channel="${_RALPH_WINDOWING_ENVELOPE_CHANNELS[$result_id]:-}"
  if [[ -n "$channel" ]]; then
    printf '%s\n' "$channel"
    return 0
  fi
  [[ -n "$log_path" && -f "$log_path" ]] || return 1
  while IFS= read -r line; do
    channel="$(jq -r --arg rid "$result_id" '
      select((.event // "") == "envelope" and (.resultId // "") == $rid)
      | .channel // empty
    ' <<<"$line" 2>/dev/null || true)"
    if [[ -n "$channel" ]]; then
      ralph_hook_telemetry_remember_envelope_channel "$result_id" "$channel"
      printf '%s\n' "$channel"
      return 0
    fi
  done < <(ralph_hook_telemetry_log_lines_reversed "$log_path" 2>/dev/null || true)
  return 1
}

# Build one JSON object for MCP/native result windowing (envelope) telemetry.
# Args: workspace plan_key tool_name original_bytes returned_bytes
#       original_tokens returned_tokens token_cap_triggered [result_id]
#       [runtime] [channel] [normalized_tool_name]
# The optional result_id ties this envelope record to any later readback
# records (see ralph_hook_telemetry_append_result_readback_log) so savings
# accounting can net out raw-view escalations for the same stored result.

# Builds the additive measurementVersion:2 fields object for
# ralph_hook_telemetry_windowing_record_json. All inputs are optional; only
# supplied (non-empty) fields are included, and every numeric field must be a
# non-negative integer or it is omitted rather than coerced. Returns "{}"
# when nothing was supplied, which keeps legacy records byte-for-byte
# unchanged (no measurementVersion key is added by the caller in that case).
#
# Args (all optional, pass "" to skip): sourceCapturedBytes inlineCandidateBytes
# inlineCandidateTokens deliveredBytes deliveredTokens storedBytes sourceCapped
# sourceComplete capReason capLimitBytes capLimitLines capLimitPerLineBytes
# tokenEstimatorBackend
ralph_hook_telemetry_windowing_v2_fields_json() {
  local source_captured_bytes="${1:-}" inline_candidate_bytes="${2:-}" inline_candidate_tokens="${3:-}"
  local delivered_bytes="${4:-}" delivered_tokens="${5:-}" stored_bytes="${6:-}"
  local source_capped="${7:-}" source_complete="${8:-}" cap_reason="${9:-}"
  local cap_limit_bytes="${10:-}" cap_limit_lines="${11:-}" cap_limit_per_line_bytes="${12:-}"
  local token_estimator_backend="${13:-}"

  jq -nc \
    --arg sourceCapturedBytes "$source_captured_bytes" \
    --arg inlineCandidateBytes "$inline_candidate_bytes" \
    --arg inlineCandidateTokens "$inline_candidate_tokens" \
    --arg deliveredBytes "$delivered_bytes" \
    --arg deliveredTokens "$delivered_tokens" \
    --arg storedBytes "$stored_bytes" \
    --arg sourceCapped "$source_capped" \
    --arg sourceComplete "$source_complete" \
    --arg capReason "$cap_reason" \
    --arg capLimitBytes "$cap_limit_bytes" \
    --arg capLimitLines "$cap_limit_lines" \
    --arg capLimitPerLineBytes "$cap_limit_per_line_bytes" \
    --arg tokenEstimatorBackend "$token_estimator_backend" \
    'def is_nat($v): ($v != "") and ($v | test("^[0-9]+$"));
     def is_bool($v): ($v == "true") or ($v == "false");
     {}
     + (if is_nat($sourceCapturedBytes) then {sourceCapturedBytes: ($sourceCapturedBytes | tonumber)} else {} end)
     + (if is_nat($inlineCandidateBytes) then {inlineCandidateBytes: ($inlineCandidateBytes | tonumber)} else {} end)
     + (if is_nat($inlineCandidateTokens) then {inlineCandidateTokens: ($inlineCandidateTokens | tonumber)} else {} end)
     + (if is_nat($deliveredBytes) then {deliveredBytes: ($deliveredBytes | tonumber)} else {} end)
     + (if is_nat($deliveredTokens) then {deliveredTokens: ($deliveredTokens | tonumber)} else {} end)
     + (if is_nat($storedBytes) then {storedBytes: ($storedBytes | tonumber)} else {} end)
     + (if is_bool($sourceCapped) then {sourceCapped: ($sourceCapped == "true")} else {} end)
     + (if is_bool($sourceComplete) then {sourceComplete: ($sourceComplete == "true")} else {} end)
     + (if $capReason != "" then {capReason: $capReason} else {} end)
     + (if is_nat($capLimitBytes) then {capLimitBytes: ($capLimitBytes | tonumber)} else {} end)
     + (if is_nat($capLimitLines) then {capLimitLines: ($capLimitLines | tonumber)} else {} end)
     + (if is_nat($capLimitPerLineBytes) then {capLimitPerLineBytes: ($capLimitPerLineBytes | tonumber)} else {} end)
     + (if $tokenEstimatorBackend != "" then {tokenEstimatorBackend: $tokenEstimatorBackend} else {} end)'
}

ralph_hook_telemetry_windowing_record_json() {
  local workspace="${1:-}" plan_key="${2:-}" tool_name="${3:-}"
  local original_bytes="${4:-0}" returned_bytes="${5:-0}"
  local original_tokens="${6:-}" returned_tokens="${7:-}" token_cap_triggered="${8:-0}"
  local result_id="${9:-}"
  local runtime="${10:-}" channel="${11:-}" normalized_tool_name="${12:-}"
  local v2_fields_json="${13:-}"
  [[ -n "$v2_fields_json" ]] || v2_fields_json='{}'
  local plan_key_fallback="${14:-}" plan_key_fallback_reason="${15:-}"
  local timestamp token_cap_json surfaced_tool_name

  surfaced_tool_name="$(ralph_hook_telemetry_windowing_resolve_tool_name "$tool_name")"
  if [[ -z "$runtime" ]]; then
    runtime="$(ralph_hook_telemetry_windowing_runtime)"
  fi
  if [[ -z "$channel" ]]; then
    channel="$(ralph_hook_telemetry_windowing_resolve_channel "$tool_name")"
  fi
  if [[ -z "$normalized_tool_name" ]]; then
    normalized_tool_name="${RALPH_RESULT_WINDOWING_NORMALIZED_TOOL_NAME:-}"
  fi

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
    --arg toolName "$surfaced_tool_name" \
    --argjson originalBytes "$original_bytes" \
    --argjson returnedBytes "$returned_bytes" \
    --argjson tokenCapTriggered "$token_cap_json" \
    --arg originalTokens "$original_tokens" \
    --arg returnedTokens "$returned_tokens" \
    --arg resultId "$result_id" \
    --arg runtime "$runtime" \
    --arg channel "$channel" \
    --arg normalizedToolName "$normalized_tool_name" \
    --argjson v2Fields "$v2_fields_json" \
    --arg planKeyFallback "$plan_key_fallback" \
    --arg planKeyFallbackReason "$plan_key_fallback_reason" \
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
    + (if $resultId != "" then {resultId: $resultId} else {} end)
    + (if $runtime != "" then {runtime: $runtime} else {} end)
    + (if $channel != "" then {channel: $channel} else {} end)
    + (if $normalizedToolName != "" then {normalizedToolName: $normalizedToolName} else {} end)
    + (if ($v2Fields | length) > 0 then {measurementVersion: 2} + $v2Fields else {} end)
    + (if $planKeyFallback == "true" or $planKeyFallback == "false"
       then {planKeyFallback: ($planKeyFallback == "true")}
       else {} end)
    + (if $planKeyFallback == "true" and $planKeyFallbackReason != ""
       then {planKeyFallbackReason: $planKeyFallbackReason}
       else {} end)'
}

ralph_hook_telemetry_append_windowing_log() {
  local workspace="${1:-}" plan_key="${2:-}" tool_name="${3:-}"
  local original_bytes="${4:-0}" returned_bytes="${5:-0}"
  local original_tokens="${6:-}" returned_tokens="${7:-}" token_cap_triggered="${8:-0}"
  local result_id="${9:-}"
  local v2_fields_json="${10:-${RALPH_RESULT_WINDOWING_V2_FIELDS_JSON:-}}"
  local plan_key_fallback="${11:-${RALPH_RESULT_WINDOWING_PLAN_KEY_FALLBACK:-}}"
  local plan_key_fallback_reason="${12:-${RALPH_RESULT_WINDOWING_PLAN_KEY_FALLBACK_REASON:-}}"
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
    "$result_id" \
    "" "" "" \
    "$v2_fields_json" \
    "$plan_key_fallback" \
    "$plan_key_fallback_reason")"
  if [[ -n "$result_id" ]]; then
    local recorded_channel
    recorded_channel="$(jq -r '.channel // empty' <<<"$line" 2>/dev/null || true)"
    if [[ -n "$recorded_channel" ]]; then
      ralph_hook_telemetry_remember_envelope_channel "$result_id" "$recorded_channel"
    fi
  fi
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

  local runtime channel source_result_channel
  runtime="$(ralph_hook_telemetry_windowing_runtime)"
  channel="stored_result_readback"
  source_result_channel="$(ralph_hook_telemetry_lookup_envelope_channel "$result_id" "$log_path" 2>/dev/null || true)"

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
    --arg runtime "$runtime" \
    --arg channel "$channel" \
    --arg sourceResultChannel "$source_result_channel" \
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
    + (if $reason != "" then {reason: $reason} else {} end)
    + (if $runtime != "" then {runtime: $runtime} else {} end)
    + (if $channel != "" then {channel: $channel} else {} end)
    + (if $sourceResultChannel != "" then {sourceResultChannel: $sourceResultChannel} else {} end)')"
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
