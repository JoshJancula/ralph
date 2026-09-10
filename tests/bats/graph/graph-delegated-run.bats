#!/usr/bin/env bats

source "$BATS_TEST_DIRNAME/../helper/load-lib.bash"
source "$BATS_TEST_DIRNAME/../../../bundle/.ralph/bash-lib/plan-todo.sh"

GRAPH_SCHEMA="$BATS_TEST_DIRNAME/../../../bundle/.ralph/schemas/graph.schema.json"
VALIDATE_GRAPH_SCHEMA_SH="$BATS_TEST_DIRNAME/../../../bundle/.ralph/bash-lib/graph/validate-graph-schema.sh"
ARTIFACT_SCHEMA_PY="$BATS_TEST_DIRNAME/../../../bundle/.ralph/python/artifact_json_schema.py"
LEDGER="$BATS_TEST_DIRNAME/../../../bundle/.ralph/bash-lib/graph/graph-delegation-ledger.sh"

setup() {
  TMPD="$(mktemp -d)"
  WS="$TMPD/workspace"
  mkdir -p "$WS"
  source "$LEDGER"
  source "$BATS_TEST_DIRNAME/../../../bundle/.ralph/bash-lib/graph/graph-delegation-runner.sh"
  DID="delegated-run-0123456789abcdef01234567"
}

teardown() { rm -rf "$TMPD"; }

ledger_request() {
  local mode="${1:-read-only}"
  jq -cn --arg id "$DID" --arg mode "$mode" \
    '{delegatedRunId:$id,task:"inspect files",idempotencyKey:"key-1",runtime:"codex",role:"research",mode:$mode,artifactPaths:["src/**"]}'
}

start_ledger() { graph_delegation_ledger_start "$WS" "$DID" "$(ledger_request "${1:-read-only}")" >/dev/null; }

write_plan() {
  local path="$1" body="$2"
  cat >"$path" <<EOF
---
execution: graph
pipeline:
  stages:
    - id: parent
      runtime: codex
$body
---
EOF
}

graph_payload() { printf '%s\n' "$1" | tail -1; }

assert_invalid() {
  local tmpd="$1" body="$2" plan="$1/p.plan.md"
  write_plan "$plan" "$body"
  run plan_pipeline_graph_json "$plan"
  [ "$status" -ne 0 ]
}

@test "delegated-run default compiles the exact off policy and schema version" {
  local tmpd plan graph
  tmpd="$(mktemp -d)"; plan="$tmpd/p.plan.md"
  write_plan "$plan" ""
  run plan_pipeline_graph_json "$plan"
  [ "$status" -eq 0 ]
  graph="$(graph_payload "$output")"
  [ "$(jq -c '.nodes[0].stage.delegation' <<<"$graph")" = '{"delegatedRuns":{"mode":"off","runtimes":[],"roles":[],"maxRuns":0,"maxParallel":0}}' ]
  [ "$(jq -r '.schemaVersion' <<<"$graph")" = "2" ]
  printf '%s\n' "$graph" >"$tmpd/graph.json"
  run bash "$VALIDATE_GRAPH_SCHEMA_SH" "$tmpd/graph.json"
  [ "$status" -eq 0 ]
  run python3 "$ARTIFACT_SCHEMA_PY" validate-final-output --schema "$GRAPH_SCHEMA" --artifact "$tmpd/graph.json"
  [ "$status" -eq 0 ]
  rm -rf "$tmpd"
}

@test "delegated-run policy accepts every allowed key and enabled mode" {
  local tmpd plan graph
  tmpd="$(mktemp -d)"; plan="$tmpd/p.plan.md"
  write_plan "$plan" "$(printf '%s\n' \
    '      workspaceMode: snapshot' \
    '      delegation:' \
    '        delegatedRuns:' \
    '          mode: changeset' \
    '          runtimes: [claude, antigravity]' \
    '          roles: [research, code-review]' \
    '          maxRuns: 4' \
    '          maxParallel: 2')"
  run plan_pipeline_graph_json "$plan"
  [ "$status" -eq 0 ]
  graph="$(graph_payload "$output")"
  jq -e '.nodes[0].stage.delegation.delegatedRuns == {mode:"changeset",runtimes:["claude","antigravity"],roles:["research","code-review"],maxRuns:4,maxParallel:2}' <<<"$graph" >/dev/null
  rm -rf "$tmpd"
}

@test "delegated-run policy rejects forbidden and old-policy keys" {
  local tmpd body
  tmpd="$(mktemp -d)"
  body="$(printf '%s\n' '      delegation:' '        delegatedRuns:' '          mode: off' '          maxRuns: 1')"
  assert_invalid "$tmpd" "$body"
  body="$(printf '%s\n' '      delegation:' '        delegatedRuns:' '          mode: read-only' '          runtimes: [claude]' '          roles: [research]' '          maxRuns: 1' '          maxParallel: 1' '          extra: true')"
  assert_invalid "$tmpd" "$body"
  body="$(printf '%s\n' '      delegation:' '        maxChildren: 1')"
  assert_invalid "$tmpd" "$body"
  body="$(printf '%s\n' '      delegation:' '        crossRuntime:' '          mode: read-only')"
  assert_invalid "$tmpd" "$body"
  rm -rf "$tmpd"
}

@test "delegated-run policy enforces mode conditions and workspace isolation" {
  local tmpd body
  tmpd="$(mktemp -d)"
  body="$(printf '%s\n' '      delegation:' '        delegatedRuns:' '          mode: bogus')"
  assert_invalid "$tmpd" "$body"
  body="$(printf '%s\n' '      delegation:' '        delegatedRuns:' '          mode: read-only' '          runtimes: [claude]' '          maxRuns: 1')"
  assert_invalid "$tmpd" "$body"
  body="$(printf '%s\n' '      delegation:' '        delegatedRuns:' '          mode: changeset' '          runtimes: [claude]' '          roles: [research]' '          maxRuns: 1' '          maxParallel: 1')"
  assert_invalid "$tmpd" "$body"
  rm -rf "$tmpd"
}

@test "delegated-run policy enforces unique entries and numeric bounds" {
  local tmpd body
  tmpd="$(mktemp -d)"
  body="$(printf '%s\n' '      delegation:' '        delegatedRuns:' '          mode: read-only' '          runtimes: [claude, claude]' '          roles: [research]' '          maxRuns: 2' '          maxParallel: 1')"
  assert_invalid "$tmpd" "$body"
  body="$(printf '%s\n' '      delegation:' '        delegatedRuns:' '          mode: read-only' '          runtimes: [claude]' '          roles: [research, research]' '          maxRuns: 2' '          maxParallel: 1')"
  assert_invalid "$tmpd" "$body"
  body="$(printf '%s\n' '      delegation:' '        delegatedRuns:' '          mode: read-only' '          runtimes: [claude]' '          roles: [research]' '          maxRuns: 0' '          maxParallel: 1')"
  assert_invalid "$tmpd" "$body"
  body="$(printf '%s\n' '      delegation:' '        delegatedRuns:' '          mode: read-only' '          runtimes: [claude]' '          roles: [research]' '          maxRuns: 1' '          maxParallel: 2')"
  assert_invalid "$tmpd" "$body"
  rm -rf "$tmpd"
}

@test "delegated-run policy enforces supported runtime and role values" {
  local tmpd body
  tmpd="$(mktemp -d)"
  body="$(printf '%s\n' '      delegation:' '        delegatedRuns:' '          mode: read-only' '          runtimes: [not-a-runtime]' '          roles: [research]' '          maxRuns: 1' '          maxParallel: 1')"
  assert_invalid "$tmpd" "$body"
  body="$(printf '%s\n' '      delegation:' '        delegatedRuns:' '          mode: read-only' '          runtimes: [claude]' '          roles: [Research]' '          maxRuns: 1' '          maxParallel: 1')"
  assert_invalid "$tmpd" "$body"
  rm -rf "$tmpd"
}

@test "delegated-run schema rejects old policy and accepts the compiled default" {
  local tmpd plan graph old
  tmpd="$(mktemp -d)"; plan="$tmpd/p.plan.md"
  write_plan "$plan" ""
  graph="$(graph_payload "$(plan_pipeline_graph_json "$plan")")"
  printf '%s\n' "$graph" >"$tmpd/graph.json"
  run python3 "$ARTIFACT_SCHEMA_PY" validate-final-output --schema "$GRAPH_SCHEMA" --artifact "$tmpd/graph.json"
  [ "$status" -eq 0 ]
  old="$(jq '.schemaVersion=1 | .nodes[0].stage.delegation={maxChildren:1,crossRuntime:{mode:"off"}}' "$tmpd/graph.json")"
  printf '%s\n' "$old" >"$tmpd/old.json"
  run python3 "$ARTIFACT_SCHEMA_PY" validate-final-output --schema "$GRAPH_SCHEMA" --artifact "$tmpd/old.json"
  [ "$status" -ne 0 ]
  rm -rf "$tmpd"
}

@test "delegated-run ledger uses the flat state-root layout and rejects unsafe ids" {
  start_ledger
  dir="$(graph_delegation_ledger_dir "$WS" "$DID")"
  [ "$dir" = "$WS/.ralph-workspace/delegated-runs/$DID" ]
  [ -f "$dir/request.json" ]
  [ -f "$dir/status.json" ]
  [ -f "$dir/events.jsonl" ]
  [ -d "$dir/artifacts" ]
  [ ! -e "$dir/policy.json" ]
  [ ! -e "$dir/child.plan.md" ]
  [ ! -e "$dir/child-process.json" ]
  run graph_delegation_ledger_dir "$WS" "../escape"
  [ "$status" -ne 0 ]
  run graph_delegation_ledger_dir "$WS" "delegation-0123456789abcdef01234567"
  [ "$status" -ne 0 ]
}

@test "delegated-run ledger permits only the exact five states and legal transitions" {
  start_ledger
  [ "${GRAPH_DELEGATION_LEDGER_STATES[*]}" = "queued running succeeded failed cancelled" ]
  run graph_delegation_ledger_transition "$WS" "$DID" awaiting-ack
  [ "$status" -ne 0 ]
  graph_delegation_ledger_transition "$WS" "$DID" running >/dev/null
  graph_delegation_ledger_transition "$WS" "$DID" succeeded '' pass '{}' '{"answer":"ok"}' >/dev/null
  run graph_delegation_ledger_transition "$WS" "$DID" failed
  [ "$status" -ne 0 ]
  [ "$(jq -r '.status' "$(graph_delegation_ledger_status_file "$WS" "$DID")")" = succeeded ]
}

@test "delegated-run ledger state keeps result terminal-only and changeset mode-only" {
  start_ledger read-only
  dir="$(graph_delegation_ledger_dir "$WS" "$DID")"
  [ ! -e "$dir/result.json" ]
  [ ! -e "$dir/changeset.json" ]
  run graph_delegation_ledger_transition "$WS" "$DID" running '' '' '{}' '{"not":"terminal"}'
  [ "$status" -ne 0 ]
  run graph_delegation_ledger_write_changeset "$WS" "$DID" '{"changes":[]}'
  [ "$status" -ne 0 ]
  graph_delegation_ledger_transition "$WS" "$DID" running >/dev/null
  graph_delegation_ledger_transition "$WS" "$DID" failed '' fail '{}' '{"error":"no"}' >/dev/null
  [ -f "$dir/result.json" ]
  [ "$(jq -r '.result.error' "$dir/result.json")" = no ]

  DID="delegated-run-fedcba9876543210fedcba98"
  start_ledger changeset
  graph_delegation_ledger_write_changeset "$WS" "$DID" '{"changes":["src/a"]}' >/dev/null
  [ -f "$(graph_delegation_ledger_changeset_file "$WS" "$DID")" ]
  [ ! -e "$(graph_delegation_ledger_result_file "$WS" "$DID")" ]
}

@test "delegated-run events append without rewriting prior events" {
  start_ledger
  events="$(graph_delegation_ledger_events_file "$WS" "$DID")"
  before="$(wc -l <"$events" | tr -d ' ')"
  graph_delegation_ledger_append_event "$WS" "$DID" delegated-run-observed '{"source":"test"}'
  graph_delegation_ledger_transition "$WS" "$DID" running >/dev/null
  after="$(wc -l <"$events" | tr -d ' ')"
  [ "$before" -eq 1 ]
  [ "$after" -eq 3 ]
  [ "$(jq -r '.event' "$events" | head -n1)" = delegated-run-created ]
  [ "$(jq -r '.event' "$events" | tail -n1)" = delegated-run-state-changed ]
  jq -e 'select(.event == "delegated-run-observed") | .details.source == "test"' "$events" >/dev/null
}

@test "delegated-run ledger rejects old schema versions instead of dual-reading" {
  start_ledger
  status_file="$(graph_delegation_ledger_status_file "$WS" "$DID")"
  jq '.schemaVersion = 1' "$status_file" >"$TMPD/old-status.json"
  mv "$TMPD/old-status.json" "$status_file"
  run graph_delegation_ledger_read_status "$WS" "$DID"
  [ "$status" -ne 0 ]
  [[ "$output" == *"requires schemaVersion 2"* ]]
  run graph_delegation_ledger_transition "$WS" "$DID" running
  [ "$status" -ne 0 ]
}

runner_request() {
  local runtime="$1" role="${2:-}"
  jq -cn --arg id "$DID" --arg runtime "$runtime" --arg role "$role" \
    '{delegatedRunId:$id,task:"inspect files",idempotencyKey:"runner-key",runtime:$runtime,mode:"read-only",artifactPaths:[]} + (if $role == "" then {} else {role:$role} end)'
}

start_runner_request() {
  local request="$1"
  graph_delegation_ledger_start "$WS" "$DID" "$request" >/dev/null
}

write_runner_stub() {
  cat >"$RALPH_DELEGATION_RUN_PLAN" <<'STUB'
#!/usr/bin/env bash
set -u
plan=""
for ((i=1; i<=$#; i++)); do
  arg="${!i}"
  case "$arg" in
    --plan) i=$((i + 1)); plan="${!i}" ;;
    --agent-workspace) i=$((i + 1)); child_workspace="${!i}" ;;
  esac
done
model_flag=0
for arg in "$@"; do
  [[ "$arg" == "--model" ]] && model_flag=1
done
{
  printf 'argv=%q\n' "$*"
  printf 'runtime=%s\n' "$(printf '%s\n' "$@" | awk 'p{print; exit} $0 == "--runtime"{p=1}')"
  printf 'role=%s\n' "$(printf '%s\n' "$@" | awk 'p{print; exit} $0 == "--role"{p=1}')"
  printf 'model_flag=%s\n' "$model_flag"
  printf 'depth=%s\n' "${RALPH_GRAPH_DELEGATION_DEPTH:-}"
  printf 'model_scope=%s\n' "${RALPH_MODEL_SCOPE:-}"
  printf 'artifact_ns=%s\n' "${RALPH_ARTIFACT_NS:-}"
  printf 'agent_workspace=%s\n' "${child_workspace:-}"
} >"$RUNNER_RECORD"
result="$(awk '/^Required result artifact: /{sub(/^Required result artifact: /, ""); print; exit}' "$plan")"
mkdir -p "$(dirname "$result")"
printf '%s\n' '{"answer":"ok"}' >"$result"
sed -i.bak 's/- \[ \]/- [x]/' "$plan"
STUB
  chmod +x "$RALPH_DELEGATION_RUN_PLAN"
}

@test "delegated-run runner sends roleless requests to every runtime with saved/native model scope" {
  local runtime request
  RALPH_DELEGATION_RUN_PLAN="$TMPD/run-plan"
  export RALPH_DELEGATION_RUN_PLAN
  write_runner_stub
  for runtime in cursor claude codex opencode antigravity; do
    case "$runtime" in
      cursor) DID=delegated-run-000000000000000000000001 ;;
      claude) DID=delegated-run-000000000000000000000002 ;;
      codex) DID=delegated-run-000000000000000000000003 ;;
      opencode) DID=delegated-run-000000000000000000000004 ;;
      antigravity) DID=delegated-run-000000000000000000000005 ;;
    esac
    RUNNER_RECORD="$TMPD/${runtime}.record"
    export RUNNER_RECORD
    request="$(runner_request "$runtime")"
    start_runner_request "$request"
    run graph_delegation_child_run "$WS" delegated-ns run-1 parent "$DID" "$WS" "$WS/.ralph-workspace" "$WS" '[]'
    [ "$status" -eq 0 ]
    [ "$(awk -F= '$1 == "runtime"{print $2}' "$RUNNER_RECORD")" = "$runtime" ]
    [ "$(awk -F= '$1 == "role"{print $2}' "$RUNNER_RECORD")" = "" ]
    [ "$(awk -F= '$1 == "model_flag"{print $2}' "$RUNNER_RECORD")" = 0 ]
    [ "$(awk -F= '$1 == "depth"{print $2}' "$RUNNER_RECORD")" = 1 ]
    [ "$(awk -F= '$1 == "model_scope"{print $2}' "$RUNNER_RECORD")" = staged ]
    [ "$(awk -F= '$1 == "artifact_ns"{print $2}' "$RUNNER_RECORD")" = delegated-ns ]
  done
}

@test "delegated-run runner does not forward the policy role to the child runner" {
  # The delegated-run "role" is a delegatedRuns.roles policy allowlist label and
  # a ledger field; it never selected a child agent profile. run-plan rejects
  # --role with exit 2, so forwarding it made every roled delegated run fail
  # before doing any work. The permissive runner stub used here accepts --role,
  # which is why the old expectation looked green against a broken path.
  RALPH_DELEGATION_RUN_PLAN="$TMPD/run-plan"
  RUNNER_RECORD="$TMPD/role.record"
  export RALPH_DELEGATION_RUN_PLAN RUNNER_RECORD
  write_runner_stub
  request="$(runner_request claude research)"
  start_runner_request "$request"
  run graph_delegation_child_run "$WS" delegated-ns run-1 parent "$DID" "$WS" "$WS/.ralph-workspace" "$WS" '[]'
  [ "$status" -eq 0 ]
  [ -z "$(awk -F= '$1 == "role"{print $2}' "$RUNNER_RECORD")" ]
  [ "$(awk -F= '$1 == "model_flag"{print $2}' "$RUNNER_RECORD")" = 0 ]
}

@test "the real run-plan argument parser rejects --role" {
  # Pins the reason the role must not be forwarded, independent of the stub.
  run bash "$REPO_ROOT/bundle/.ralph/run-plan.sh" --runtime cursor --plan /dev/null --role research
  [ "$status" -eq 2 ]
  [[ "$output" == *"was removed"* ]]
}

@test "delegated-run runner rejects child depth greater than one before invocation" {
  RALPH_DELEGATION_RUN_PLAN="$TMPD/run-plan"
  RUNNER_RECORD="$TMPD/depth.record"
  export RALPH_DELEGATION_RUN_PLAN RUNNER_RECORD
  write_runner_stub
  request="$(runner_request codex)"
  request="$(jq '. + {depth:2}' <<<"$request")"
  start_runner_request "$request"
  run graph_delegation_child_run "$WS" delegated-ns run-1 parent "$DID" "$WS" "$WS/.ralph-workspace" "$WS" '[]'
  [ "$status" -ne 0 ]
  [ ! -e "$RUNNER_RECORD" ]
}

@test "delegated-run runner rejects a model in the validated request" {
  RALPH_DELEGATION_RUN_PLAN="$TMPD/run-plan"
  RUNNER_RECORD="$TMPD/model.record"
  export RALPH_DELEGATION_RUN_PLAN RUNNER_RECORD
  write_runner_stub
  request="$(runner_request codex)"
  request="$(jq '. + {model:"request-model"}' <<<"$request")"
  start_runner_request "$request"
  run graph_delegation_child_run "$WS" delegated-ns run-1 parent "$DID" "$WS" "$WS/.ralph-workspace" "$WS" '[]'
  [ "$status" -ne 0 ]
  [ ! -e "$RUNNER_RECORD" ]
}

# --- queue -------------------------------------------------------------------

queue_source() {
  if ! declare -F graph_delegation_queue_enqueue >/dev/null 2>&1; then
    source "$BATS_TEST_DIRNAME/../../../bundle/.ralph/bash-lib/graph/graph-delegation-queue.sh"
  fi
}

# queue_run <hex-suffix> <idempotency-key> [runtime]
queue_run() {
  local id="delegated-run-$1" key="$2" runtime="${3:-codex}" request
  request="$(jq -cn --arg id "$id" --arg key "$key" --arg rt "$runtime" \
    '{delegatedRunId:$id,task:"inspect files",idempotencyKey:$key,runtime:$rt,mode:"read-only",artifactPaths:[]}')"
  graph_delegation_ledger_start "$WS" "$id" "$request" >/dev/null || return 1
  printf '%s\n' "$id"
}

queue_policy() {
  jq -cn --argjson runs "$1" --argjson parallel "$2" '{maxRuns:$runs,maxParallel:$parallel}'
}

@test "delegated-run queue reuses one delegatedRunId for a duplicate idempotency key" {
  queue_source
  local first second found
  first="$(queue_run 1111111111111111111111aa dup-key)"
  second="$(queue_run 2222222222222222222222bb dup-key)"
  [ "$(graph_delegation_queue_enqueue "$WS" "$first" parent "$(queue_policy 3 2)")" = "$first" ]
  # The same record enqueued twice stays one entry and returns the same id.
  [ "$(graph_delegation_queue_enqueue "$WS" "$first" parent "$(queue_policy 3 2)")" = "$first" ]
  # A different record reusing the key is refused rather than minting a second run.
  run graph_delegation_queue_enqueue "$WS" "$second" parent "$(queue_policy 3 2)"
  [ "$status" -eq 4 ]
  found="$(graph_delegation_queue_find_idempotency "$WS" '' parent dup-key)"
  [ "$found" = "$first" ]
  [ "$(graph_delegation_queue_entries "$WS" | wc -l | tr -d ' ')" = "1" ]
}

@test "delegated-run queue enforces maxRuns on enqueue" {
  queue_source
  local a b c
  a="$(queue_run 3333333333333333333333aa key-a)"
  b="$(queue_run 4444444444444444444444bb key-b)"
  c="$(queue_run 5555555555555555555555cc key-c)"
  [ "$(graph_delegation_queue_enqueue "$WS" "$a" parent "$(queue_policy 2 1)")" = "$a" ]
  [ "$(graph_delegation_queue_enqueue "$WS" "$b" parent "$(queue_policy 2 1)")" = "$b" ]
  run graph_delegation_queue_enqueue "$WS" "$c" parent "$(queue_policy 2 1)"
  [ "$status" -eq 3 ]
  [ "$(graph_delegation_queue_count_parent "$WS" '' '' parent)" = "2" ]
}

@test "delegated-run queue enforces maxParallel and dequeues in queue order" {
  queue_source
  local a b admitted
  a="$(queue_run 6666666666666666666666aa key-a)"
  b="$(queue_run 7777777777777777777777bb key-b)"
  graph_delegation_queue_enqueue "$WS" "$a" parent "$(queue_policy 2 1)" >/dev/null
  graph_delegation_queue_enqueue "$WS" "$b" parent "$(queue_policy 2 1)" >/dev/null
  # Fair dequeue: the first enqueued record is admitted first.
  admitted="$(graph_delegation_queue_admit_one "$WS" 4 4)"
  [ "$(jq -r '.delegatedRunId' <<<"$admitted")" = "$a" ]
  [ "$(graph_delegation_ledger_read_status "$WS" "$a" | jq -r '.status')" = running ]
  # maxParallel of one blocks the second while the first is still running.
  run graph_delegation_queue_admit_one "$WS" 4 4
  [ "$status" -eq 2 ]
  graph_delegation_ledger_transition "$WS" "$a" succeeded '' pass '{}' '{"ok":true}' >/dev/null
  admitted="$(graph_delegation_queue_admit_one "$WS" 4 4)"
  [ "$(jq -r '.delegatedRunId' <<<"$admitted")" = "$b" ]
}

@test "delegated-run queue respects the global running capacity" {
  queue_source
  local a b
  a="$(queue_run 8888888888888888888888aa key-a)"
  b="$(queue_run 9999999999999999999999bb key-b)"
  graph_delegation_queue_enqueue "$WS" "$a" parent "$(queue_policy 2 2)" >/dev/null
  graph_delegation_queue_enqueue "$WS" "$b" parent "$(queue_policy 2 2)" >/dev/null
  graph_delegation_queue_admit_one "$WS" 1 4 >/dev/null
  run graph_delegation_queue_admit_one "$WS" 1 4
  [ "$status" -eq 2 ]
  # A per-runtime capacity of one blocks a second child on the same runtime.
  run graph_delegation_queue_admit_one "$WS" 4 1
  [ "$status" -eq 2 ]
}

@test "delegated-run queue cancels a parent's children without admitting them" {
  queue_source
  local a
  a="$(queue_run aaaaaaaaaaaaaaaaaaaaaa11 key-a)"
  graph_delegation_queue_enqueue "$WS" "$a" parent "$(queue_policy 2 2)" >/dev/null
  graph_delegation_queue_cancel_parent "$WS" '' '' parent 'parent cancelled'
  [ "$(graph_delegation_ledger_read_status "$WS" "$a" | jq -r '.status')" = cancelled ]
  run graph_delegation_queue_admit_one "$WS" 4 4
  [ "$status" -eq 2 ]
}

@test "delegated-run queue requeues a crashed running record without a second id" {
  queue_source
  local a entries
  a="$(queue_run bbbbbbbbbbbbbbbbbbbbbb22 key-a)"
  graph_delegation_queue_enqueue "$WS" "$a" parent "$(queue_policy 2 2)" >/dev/null
  graph_delegation_queue_admit_one "$WS" 4 4 >/dev/null
  [ "$(graph_delegation_ledger_read_status "$WS" "$a" | jq -r '.status')" = running ]
  graph_delegation_queue_requeue_crashed "$WS" "$a"
  [ "$(graph_delegation_ledger_read_status "$WS" "$a" | jq -r '.status')" = queued ]
  entries="$(graph_delegation_queue_entries "$WS" | wc -l | tr -d ' ')"
  [ "$entries" = "1" ]
  [ "$(graph_delegation_queue_entries "$WS" | jq -r '.delegatedRunId')" = "$a" ]
  # A record that is not running is not requeued.
  run graph_delegation_queue_requeue_crashed "$WS" "$a"
  [ "$status" -eq 2 ]
}

# --- isolation and admission -------------------------------------------------

@test "delegated-run admission rejects an unavailable runtime and unsafe same-runtime reuse" {
  run _graph_delegation_runner_admit_runtime nonexistent-runtime
  [ "$status" -eq 2 ]
  # Cursor rewrites project-root MCP config, so a cursor child under a cursor
  # parent has no proven overlay isolation.
  run _graph_delegation_runner_admit_runtime cursor cursor
  [ "$status" -eq 3 ]
  # Cross-runtime reuse of the same unsafe runtime is admitted normally.
  run _graph_delegation_runner_admit_runtime cursor codex
  [ "$status" -eq 0 ]
  run _graph_delegation_runner_admit_runtime codex codex
  [ "$status" -eq 0 ]
}

@test "delegated-run admission rejects same-runtime capacity exhaustion before launch" {
  RALPH_GRAPH_MAX_PARALLEL_PER_RUNTIME=1 run _graph_delegation_runner_admit_runtime codex codex
  [ "$status" -eq 4 ]
  RALPH_GRAPH_MAX_PARALLEL_PER_RUNTIME=2 RALPH_GRAPH_RUNTIME_ACTIVE_SLOTS=2 \
    run _graph_delegation_runner_admit_runtime codex codex
  [ "$status" -eq 4 ]
  RALPH_GRAPH_MAX_PARALLEL=1 run _graph_delegation_runner_admit_runtime codex claude
  [ "$status" -eq 4 ]
  RALPH_GRAPH_MAX_PARALLEL_PER_RUNTIME=2 RALPH_GRAPH_RUNTIME_ACTIVE_SLOTS=0 \
    run _graph_delegation_runner_admit_runtime codex codex
  [ "$status" -eq 0 ]
}

@test "delegated-run isolation rejects absolute, traversing, and symlink-escaping artifact paths" {
  local root outside
  mkdir -p "$TMPD/root/inside" "$TMPD/outside"
  # The validator compares resolved symlink targets against the root, so the
  # root itself must already be a real path (as the runner passes it).
  root="$(cd "$TMPD/root" && pwd -P)"
  outside="$(cd "$TMPD/outside" && pwd -P)"
  ln -s "$outside" "$root/escape"
  ln -s "inside" "$root/local"
  run _graph_delegation_runner_validate_relative_path "$root" "inside/result.json"
  [ "$status" -eq 0 ]
  run _graph_delegation_runner_validate_relative_path "$root" "local/result.json"
  [ "$status" -eq 0 ]
  run _graph_delegation_runner_validate_relative_path "$root" "escape/result.json"
  [ "$status" -ne 0 ]
  run _graph_delegation_runner_validate_relative_path "$root" "/abs/result.json"
  [ "$status" -ne 0 ]
  run _graph_delegation_runner_validate_relative_path "$root" "../result.json"
  [ "$status" -ne 0 ]
  run _graph_delegation_runner_validate_relative_path "$root" "inside//result.json"
  [ "$status" -ne 0 ]
  run _graph_delegation_runner_validate_relative_path "$root" ""
  [ "$status" -ne 0 ]
}

@test "delegated-run read-only never materializes a changeset workspace" {
  local plan mode
  start_ledger read-only
  plan="$(graph_delegation_child_materialize "$WS" delegated-ns run-1 parent "$DID" '[]' | cut -f1)"
  mode="$(sed -n 's/^workspaceMode: //p' "$plan")"
  [ "$mode" = snapshot ]
  grep -q "Do not delegate further." "$plan"
}

@test "delegated-run changeset honours an isolated worktree that read-only refuses" {
  local plan mode request
  # changeset may keep an explicitly requested worktree ...
  request="$(jq -c '. + {workspaceMode:"worktree"}' <<<"$(ledger_request changeset)")"
  graph_delegation_ledger_start "$WS" "$DID" "$request" >/dev/null
  plan="$(graph_delegation_child_materialize "$WS" delegated-ns run-1 parent "$DID" '[]' | cut -f1)"
  mode="$(sed -n 's/^workspaceMode: //p' "$plan")"
  [ "$mode" = worktree ]

  # ... while read-only is always forced back to a snapshot it cannot publish from.
  local ro_id="delegated-run-0123456789abcdef01234568"
  request="$(jq -c --arg id "$ro_id" '. + {delegatedRunId:$id,workspaceMode:"worktree"}' <<<"$(ledger_request read-only)")"
  graph_delegation_ledger_start "$WS" "$ro_id" "$request" >/dev/null
  plan="$(graph_delegation_child_materialize "$WS" delegated-ns run-1 parent "$ro_id" '[]' | cut -f1)"
  [ "$(sed -n 's/^workspaceMode: //p' "$plan")" = snapshot ]
}
