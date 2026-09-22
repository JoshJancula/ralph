#!/usr/bin/env bats
# Supervisor behaviour of the delegated-run child runner: an incomplete,
# unverified, or out-of-scope child never becomes a success, and a changeset
# child is scope-checked before it reaches the parent workspace.
#
# Ported from the pre-redesign graph-delegation-runner suite onto the
# delegatedRunId ledger contract.

source "$BATS_TEST_DIRNAME/../helper/load-lib.bash"
source "$REPO_ROOT/bundle/.ralph/bash-lib/graph/graph-delegation-runner.sh"

setup() {
  TMPD="$(mktemp -d)"; WS="$TMPD/ws"; PROJECT="$TMPD/project"; STATE="$TMPD/state"; AGENT="$TMPD/agent"
  mkdir -p "$WS" "$PROJECT/.ralph" "$STATE" "$AGENT"
  STUB="$TMPD/run-plan-stub.sh"; ARGV="$TMPD/argv"
  cat >"$STUB" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" >>"$RALPH_TEST_ARGV"
plan=""; agent_workspace=""; while [ "$#" -gt 0 ]; do
  [ "$1" = --plan ] && plan="$2"
  [ "$1" = --agent-workspace ] && agent_workspace="$2"
  shift
done
case "${RALPH_TEST_CHILD_MODE:-success}" in
  success|verify-fail|read-only-violation|changeset-success)
    sed -i.bak 's/^- \[ \]/- [x]/' "$plan"; rm -f "$plan.bak"
    path="$(sed -n 's|^Required result artifact: ||p' "$plan")"
    [[ "$path" == /* ]] || path="$agent_workspace/$path"
    mkdir -p "$(dirname "$path")"; printf result >"$path"
    [ "${RALPH_TEST_CHILD_MODE:-success}" = read-only-violation ] && printf bad >"$agent_workspace/forbidden.txt"
    if [ "${RALPH_TEST_CHILD_MODE:-success}" = changeset-success ]; then mkdir -p "$agent_workspace/src"; printf child >"$agent_workspace/src/child.txt"; fi
    ;;
esac
[ "${RALPH_TEST_CHILD_MODE:-success}" = verify-fail ] && exit 1
exit 0
EOF
  chmod +x "$STUB"
}
teardown() { rm -rf "$TMPD"; }

# start_child <task> [extra-request-json]
# Prints the delegatedRunId of a queued ledger record.
start_child() {
  local task="$1" extra="${2:-{\}}" id request
  id="$(graph_delegation_ledger_id run parent attempt "key-${BATS_TEST_NUMBER:-1}")"
  request="$(jq -cn --arg id "$id" --arg task "$task" --argjson extra "$extra" \
    '{delegatedRunId:$id,task:$task,idempotencyKey:"key-1",runtime:"codex",role:"research",mode:"read-only",artifactPaths:[]} + $extra')"
  graph_delegation_ledger_start "$WS" "$id" "$request" >/dev/null || return 1
  # The scheduler admits a run before the runner executes it; the runner only
  # transitions out of running.
  graph_delegation_ledger_transition "$WS" "$id" running scheduler >/dev/null || return 1
  printf '%s\n' "$id"
}

child_dir() { dirname "$(graph_delegation_ledger_request_file "$WS" "$1")"; }
child_plan() { printf '%s/.runner.plan.md\n' "$(child_dir "$1")"; }
child_status() { graph_delegation_ledger_read_status "$WS" "$1"; }
# The terminal handoff lives in the ledger's result.json, not inline in status.
child_result() { jq -c '.result' "$(child_dir "$1")/result.json"; }

run_child() {
  RALPH_DELEGATION_RUN_PLAN="$STUB" RALPH_TEST_ARGV="$ARGV" RALPH_TEST_PROJECT="$PROJECT" \
    graph_delegation_child_run "$WS" ns run parent "$1" "$PROJECT" "$STATE" "$AGENT" \
    '[{"name":"unit","verify":"test -f expected"}]'
}

@test "child omissions stay open and record structured failure" {
  did="$(start_child 'omit completion')"
  RALPH_TEST_CHILD_MODE=omit run run_child "$did"
  [ "$status" -ne 0 ]
  child_status "$did" | jq -e '.status == "failed" and .verificationOutcome == "fail"' >/dev/null
}

@test "missing required artifact stays open" {
  did="$(start_child 'missing artifact')"
  RALPH_TEST_CHILD_MODE=omit-artifact run run_child "$did"
  [ "$status" -ne 0 ]
  child_status "$did" | jq -e '.status == "failed"' >/dev/null
  # No terminal handoff is published for a child that produced no artifact.
  [ "$(child_result "$did")" = null ]
}

@test "verification failure reopens the delegated child" {
  did="$(start_child 'verification failure')"
  RALPH_TEST_CHILD_MODE=verify-fail run run_child "$did"
  [ "$status" -ne 0 ]
  child_status "$did" | jq -e '.status == "failed"' >/dev/null
}

@test "successful child records result and invokes run-plan with all roots" {
  did="$(start_child 'successful child')"
  RALPH_TEST_CHILD_MODE=success run_child "$did"
  child_status "$did" | jq -e '.status == "succeeded"' >/dev/null
  child_result "$did" | jq -e '.resultArtifact and .readOnlyVerified == true' >/dev/null
  args="$(tr '\n' ' ' <"$ARGV")"
  [[ "$args" == *"--plan $(child_plan "$did")"* ]]
  [[ "$args" == *"--workspace $PROJECT --workspace-root $STATE --agent-workspace $(child_dir "$did")/workspace"* ]]
  # The child never receives a model; run-plan owns model resolution.
  [[ "$args" != *"--model"* ]]
  # The durable handoff is state-root owned, and the model-writable copy is gone.
  result_path="$(child_result "$did" | jq -r '.resultArtifact')"
  [[ "$result_path" == "$(child_dir "$did")/artifacts/"* ]]
  [ -s "$result_path" ]
  [ ! -d "$(child_dir "$did")/workspace" ]
  # The plan is Ralph-owned scratch and does not outlive the child.
  [ ! -e "$(child_plan "$did")" ]
}

@test "exhausted child retries produce failure rather than false success" {
  did="$(start_child 'never completes')"
  RALPH_TEST_CHILD_MODE=omit RALPH_DELEGATION_GUTTER_ITERATIONS=1 run run_child "$did"
  [ "$status" -ne 0 ]
  child_status "$did" | jq -e '.status == "failed"' >/dev/null
  [ -f "$WS/.ralph-workspace/logs/delegated-child-runner.log" ]
}

@test "read-only child mutation is rejected by the supervisor" {
  did="$(start_child 'must remain read only')"
  RALPH_TEST_CHILD_MODE=read-only-violation run run_child "$did"
  [ "$status" -ne 0 ]
  child_status "$did" | jq -e '.status == "failed"' >/dev/null
  [ ! -e "$AGENT/forbidden.txt" ]
}

@test "changeset child is scope-checked and integrated into the parent workspace" {
  run_dir="$(graph_state_run_dir "$WS" ns run)"
  mkdir -p "$run_dir"
  printf '%s\n' '{"sourceBase":{"filesystemIdentity":"base-1"}}' >"$run_dir/run.json"
  did="$(start_child 'create a scoped child change' '{"mode":"changeset","writeScopes":["src/**"]}')"
  RALPH_TEST_CHILD_MODE=changeset-success run_child "$did"
  [ "$(cat "$AGENT/src/child.txt")" = child ]
  child_status "$did" | jq -e '.status == "succeeded"' >/dev/null
  result_json="$(child_result "$did")"
  jq -e '.integrated == true' <<<"$result_json" >/dev/null
  changeset="$(jq -r .changesetArtifact <<<"$result_json")"
  integration="$(jq -r .integrationResult <<<"$result_json")"
  jq -e '.kind == "graph-changeset" and .writeScopes == ["src/**"]' "$changeset" >/dev/null
  jq -e '.kind == "graph-integration" and .changeCount >= 1' "$integration" >/dev/null
}
