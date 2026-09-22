#!/usr/bin/env bats
# Jev usage tracking: the transport writes usage.jsonl on every successful call
# and "ralph jev usage" / "ralph usage" report it. Offline only: fixture
# transport, no live API call.

source "$BATS_TEST_DIRNAME/../helper/load-lib.bash"

JEV_CLI="$REPO_ROOT/bundle/.ralph/jev.sh"
USAGE_REPORT="$REPO_ROOT/bundle/.ralph/usage-report.sh"
REQ='{"questionSetId":"noul-success","state":"x","questions":{"has_failure":{"type":"noul"}}}'

setup() {
  JEVU_TMP="$(mktemp -d "${BATS_TEST_TMPDIR:-/tmp}/ralph-jev-usage.XXXXXX")"
  export HOME="$JEVU_TMP/home"
  export RALPH_CONFIG_HOME="$JEVU_TMP/config"
  export RALPH_JEV_STATE_DIR="$JEVU_TMP/state"
  export RALPH_JEV_ENV_FILE=0
  export JEV_TRANSPORT=fixture
  export JEV_FIXTURE_DIR="$REPO_ROOT/tests/fixtures/jev"
  export RALPH_PLAN_KEY=jev-usage-test
  mkdir -p "$HOME" "$RALPH_CONFIG_HOME" "$RALPH_JEV_STATE_DIR"
  unset RALPH_JEV RALPH_ARTIFACT_NS TYPESAFE_API_KEY
}

teardown() {
  rm -rf "$JEVU_TMP"
}

@test "bash transport records measured usage from the response" {
  run bash -c 'source "$1"; jev_post_systemone "$2" >/dev/null' _ \
    "$REPO_ROOT/bundle/.ralph/bash-lib/jev/jev-client.sh" "$REQ"
  [ "$status" -eq 0 ]
  run jq -e '
    .input_tokens == 96 and .output_tokens == 12
    and .usageSource == "measured" and .model == "jev-1.13.0"
    and .questionSetId == "noul-success" and .planKey == "jev-usage-test"
  ' "$RALPH_JEV_STATE_DIR/usage.jsonl"
  [ "$status" -eq 0 ]
}

@test "python transport records the same fields as the bash transport" {
  bash -c 'source "$1"; jev_post_systemone "$2" >/dev/null' _ \
    "$REPO_ROOT/bundle/.ralph/bash-lib/jev/jev-client.sh" "$REQ"
  python3 - "$REPO_ROOT" "$REQ" <<'PY'
import json, sys
sys.path.insert(0, sys.argv[1] + "/bundle/.ralph/python")
import jev_client
resp, code = jev_client.post_systemone(json.loads(sys.argv[2]))
assert code == 0 and resp is not None
PY
  run jq -s -e '
    length == 2
    and (.[0] | del(.timestamp)) == (.[1] | del(.timestamp))
  ' "$RALPH_JEV_STATE_DIR/usage.jsonl"
  [ "$status" -eq 0 ]
}

@test "a failed call records no usage" {
  run bash -c 'source "$1"; jev_post_systemone "$2" >/dev/null' _ \
    "$REPO_ROOT/bundle/.ralph/bash-lib/jev/jev-client.sh" \
    '{"questionSetId":"error-401","state":"x","questions":{}}'
  [ "$status" -ne 0 ]
  [ ! -s "$RALPH_JEV_STATE_DIR/usage.jsonl" ]
}

@test "ralph jev usage ignores fixture calls by default and counts them on request" {
  bash -c 'source "$1"; jev_post_systemone "$2" >/dev/null' _ \
    "$REPO_ROOT/bundle/.ralph/bash-lib/jev/jev-client.sh" "$REQ"
  run bash "$JEV_CLI" usage
  [ "$status" -eq 0 ]
  [[ "$output" == *"no recorded calls"* ]]

  run bash "$JEV_CLI" usage --include-fixture --format json
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | jq -e '.calls == 1 and .input_tokens == 96 and .output_tokens == 12'
}

@test "ralph usage omits the Jev block when Jev was never used" {
  ws="$JEVU_TMP/ws"
  mkdir -p "$ws/.ralph-workspace/logs"
  rm -rf "$RALPH_JEV_STATE_DIR"
  run bash "$USAGE_REPORT" --workspace "$ws"
  [ "$status" -eq 0 ]
  [[ "$output" != *"Jev (TypeSafe AI)"* ]]
}

@test "ralph usage shows a Jev block and a jev json key when calls were recorded" {
  ws="$JEVU_TMP/ws"
  mkdir -p "$ws/.ralph-workspace/logs"
  printf '%s\n' \
    '{"timestamp":"t","model":"jev-1.13.0","questionSetId":"graph.router-confidence","input_tokens":296,"output_tokens":20,"usageSource":"measured","transport":"https","planKey":"p"}' \
    >"$RALPH_JEV_STATE_DIR/usage.jsonl"

  run bash "$USAGE_REPORT" --workspace "$ws"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Jev (TypeSafe AI) usage"* ]]
  [[ "$output" == *"input 296, output 20"* ]]

  run bash "$USAGE_REPORT" --workspace "$ws" --format json
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | jq -e '.jev.calls == 1 and .jev.input_tokens == 296'
}

# Runs the real _ralph_write_plan_usage_summary against a minimal history and
# prints the resulting plan-usage-summary.json path.
_jevu_write_plan_summary() {
  local logdir="$1" snippet="$JEVU_TMP/summary.fn.sh" script="$JEVU_TMP/summary.sh"
  local core="$REPO_ROOT/bundle/.ralph/bash-lib/run-plan/run-plan-core.sh"
  sed -n '/^run_plan_num_or_zero() {/,/^}$/p' "$core" >"$snippet"
  sed -n '/^_ralph_write_plan_usage_summary() {/,/^}$/p' "$core" >>"$snippet"
  cat <<EOF2 >"$script"
#!/usr/bin/env bash
set -euo pipefail
source "${REPO_ROOT}/bundle/.ralph/bash-lib/ralph-format-elapsed.sh"
SCRIPT_DIR="${REPO_ROOT}/bundle/.ralph"
EOF2
  cat <<'EOF2' >>"$script"
source "$1"
ralph_run_plan_log() { :; }
C_DIM=""; C_RST=""
SELECTED_MODEL="claude-sonnet-4-6"; RUNTIME="claude"
PLAN_PATH="PLANJ.md"; RALPH_PLAN_KEY="PLANJ"; RALPH_ARTIFACT_NS="PLANJ"
RALPH_LOG_DIR="$2"
mkdir -p "$RALPH_LOG_DIR"
cat >"$RALPH_LOG_DIR/invocation-usage.json" <<'JSON'
{"schema_version":1,"kind":"plan_invocation_usage_history","invocations":[
 {"iteration":1,"model":"claude-sonnet-4-6","runtime":"claude","elapsed_seconds":3,
  "input_tokens":100,"output_tokens":20,"cache_creation_input_tokens":0,
  "cache_read_input_tokens":10,"max_turn_total_tokens":400,
  "started_at":"2026-04-17T00:00:00Z","ended_at":"2026-04-17T00:00:03Z"}]}
JSON
total_invocations=1
_plan_start_ts="$(( $(date +%s) - 1 ))"
_plan_started_at="2026-04-17T00:00:00Z"
_total_input_tokens=100; _total_output_tokens=20
_total_cache_creation_tokens=0; _total_cache_read_tokens=10; _total_max_turn_tokens=400
_ralph_write_plan_usage_summary 1 1
EOF2
  chmod +x "$script"
  NO_COLOR=1 "$script" "$snippet" "$logdir" >/dev/null 2>&1
}

@test "plan-usage-summary carries a jev object for this plan and leaves runtime buckets alone" {
  printf '%s\n' \
    '{"timestamp":"t","model":"jev-1.13.0","questionSetId":"graph.router-confidence","input_tokens":296,"output_tokens":20,"usageSource":"measured","transport":"https","planKey":"PLANJ"}' \
    '{"timestamp":"t","model":"jev-1.13.0","questionSetId":"graph.router-confidence","input_tokens":900,"output_tokens":90,"usageSource":"measured","transport":"https","planKey":"OTHER"}' \
    >"$RALPH_JEV_STATE_DIR/usage.jsonl"
  run _jevu_write_plan_summary "$JEVU_TMP/logs"
  [ "$status" -eq 0 ]
  run jq -e '
    .jev.calls == 1 and .jev.input_tokens == 296 and .jev.output_tokens == 20
    and .input_tokens == 100 and .output_tokens == 20
    and (.model_breakdown | length == 1)
  ' "$JEVU_TMP/logs/plan-usage-summary.json"
  [ "$status" -eq 0 ]
}

@test "plan-usage-summary has no jev key when Jev made no calls for the plan" {
  run _jevu_write_plan_summary "$JEVU_TMP/logs"
  [ "$status" -eq 0 ]
  run jq -e 'has("jev") | not' "$JEVU_TMP/logs/plan-usage-summary.json"
  [ "$status" -eq 0 ]
}
