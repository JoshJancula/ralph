#!/usr/bin/env bats
# Builder-level coverage for the additive measurementVersion:2 windowing
# telemetry fields (PLAN15). Legacy originalBytes/returnedBytes semantics
# must remain byte-for-byte unchanged when callers do not supply v2 fields.

source "$BATS_TEST_DIRNAME/../helper/load-lib.bash"

setup() {
  source "$REPO_ROOT/bundle/.ralph/bash-lib/hook-telemetry.sh"
}

@test "legacy record (no v2 fields) has no measurementVersion key" {
  local record
  record="$(ralph_hook_telemetry_windowing_record_json \
    ws plankey Read 5000 1000 1250 250 1 abc1234567890123)"

  run jq -e '.measurementVersion' <<<"$record"
  [ "$status" -ne 0 ]

  run jq -r '.originalBytes, .returnedBytes, .toolName' <<<"$record"
  [ "$output" = $'5000\n1000\nRead' ]
}

@test "legacy record output is byte-for-byte identical whether or not empty v2 args are passed" {
  local out_no_v2 out_empty_v2
  out_no_v2="$(ralph_hook_telemetry_windowing_record_json ws plankey Read 5000 1000 1250 250 1 abc1234567890123)"
  out_empty_v2="$(ralph_hook_telemetry_windowing_record_json ws plankey Read 5000 1000 1250 250 1 abc1234567890123 "" "" "" "")"
  # The record stamps wall-clock time, so two builds can straddle a second
  # boundary. The contract under test is that empty v2 args change nothing
  # else, so compare with the timestamp normalized out.
  [ "$(jq -c 'del(.timestamp)' <<<"$out_no_v2")" = "$(jq -c 'del(.timestamp)' <<<"$out_empty_v2")" ]
  # Both still carry a timestamp, and neither gains a v2 key.
  [ "$(jq -r 'has("timestamp")' <<<"$out_no_v2")" = "true" ]
  [ "$(jq -r 'has("timestamp")' <<<"$out_empty_v2")" = "true" ]
  [ "$(jq -r 'has("measurementVersion")' <<<"$out_empty_v2")" = "false" ]
}

@test "complete-source v2 record includes all supplied fields as non-negative integers" {
  local v2 record
  v2="$(ralph_hook_telemetry_windowing_v2_fields_json 5000 1200 300 900 225 5000 false true "" "" "" "" python)"
  record="$(ralph_hook_telemetry_windowing_record_json \
    ws plankey Read 5000 900 1250 225 0 abc1234567890123 "" "" "" "$v2")"

  run jq -r '.measurementVersion' <<<"$record"
  [ "$output" = "2" ]

  run jq -e '.sourceCapped == false and .sourceComplete == true' <<<"$record"
  [ "$status" -eq 0 ]

  run jq -e '[.sourceCapturedBytes, .inlineCandidateBytes, .inlineCandidateTokens, .deliveredBytes, .deliveredTokens, .storedBytes] | all(type == "number" and . >= 0)' <<<"$record"
  [ "$status" -eq 0 ]

  run jq -r '.tokenEstimatorBackend' <<<"$record"
  [ "$output" = "python" ]
}

@test "source-capped v2 record includes cap reason and limits" {
  local v2 record
  v2="$(ralph_hook_telemetry_windowing_v2_fields_json 67000000 14081 3520 6668 1667 67000000 true false max_bytes 65536 100 4096 awk)"
  record="$(ralph_hook_telemetry_windowing_record_json \
    ws plankey Grep 67000000 6668 0 1667 1 def1234567890123 "" "" "" "$v2")"

  run jq -e '.sourceCapped == true and .sourceComplete == false' <<<"$record"
  [ "$status" -eq 0 ]

  run jq -r '.capReason' <<<"$record"
  [ "$output" = "max_bytes" ]

  run jq -e '[.capLimitBytes, .capLimitLines, .capLimitPerLineBytes] | all(type == "number" and . >= 0)' <<<"$record"
  [ "$status" -eq 0 ]
}

@test "zero-byte optional v2 fields are recorded as 0, not omitted" {
  local v2 record
  v2="$(ralph_hook_telemetry_windowing_v2_fields_json 0 0 0 0 0 0 false true "" "" "" "" "")"
  record="$(ralph_hook_telemetry_windowing_record_json \
    ws plankey Glob 0 0 "" "" 0 "" "" "" "" "$v2")"

  run jq -e '.sourceCapturedBytes == 0 and .inlineCandidateBytes == 0 and .storedBytes == 0' <<<"$record"
  [ "$status" -eq 0 ]
}

@test "omitted optional tokens (empty string args) are excluded, not coerced to 0" {
  local v2 record
  v2="$(ralph_hook_telemetry_windowing_v2_fields_json 5000 1200 "" 900 "" 5000 false true)"
  record="$(ralph_hook_telemetry_windowing_record_json \
    ws plankey Read 5000 900 "" "" 0 "" "" "" "" "$v2")"

  run jq -e 'has("inlineCandidateTokens") | not' <<<"$record"
  [ "$status" -eq 0 ]
  run jq -e 'has("deliveredTokens") | not' <<<"$record"
  [ "$status" -eq 0 ]
  run jq -e 'has("originalTokens") | not' <<<"$record"
  [ "$status" -eq 0 ]
}

@test "v2 fields builder omits negative/non-numeric values instead of coercing" {
  run ralph_hook_telemetry_windowing_v2_fields_json "-5" "abc" "" "" "" "" "maybe" "" "" "" "" "" ""
  [ "$status" -eq 0 ]
  [ "$output" = "{}" ]
}
