#!/usr/bin/env bats

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

start_child() {
  local policy="${POLICY:-}"
  [[ -n "$policy" ]] || policy='{"maxChildren":1}'
  graph_delegation_ledger_start "$WS" ns run parent attempt key "$1" "$policy" codex research '' 1 snapshot '[]' ''
}
run_child() {
  RALPH_DELEGATION_RUN_PLAN="$STUB" RALPH_TEST_ARGV="$ARGV" RALPH_TEST_PROJECT="$PROJECT" graph_delegation_child_run "$WS" ns run parent "$1" "$PROJECT" "$STATE" "$AGENT" '[{"name":"unit","verify":"test -f expected"}]'
}

@test "child omissions stay open and record structured failure" {
  did="$(start_child 'omit completion')"
  RALPH_TEST_CHILD_MODE=omit run run_child "$did"
  [ "$status" -ne 0 ]
  graph_delegation_ledger_read_status "$WS" ns run parent "$did" | jq -e '.status == "failed" and .verificationOutcome == "fail"' >/dev/null
}

@test "missing required artifact stays open" {
  did="$(start_child 'missing artifact')"
  RALPH_TEST_CHILD_MODE=omit-artifact run run_child "$did"
  [ "$status" -ne 0 ]
  grep -q '^- \[ \]' "$(graph_delegation_ledger_plan_file "$WS" ns run parent "$did")"
}

@test "verification failure reopens the delegated child" {
  did="$(start_child 'verification failure')"
  RALPH_TEST_CHILD_MODE=verify-fail run run_child "$did"
  [ "$status" -ne 0 ]
  graph_delegation_ledger_read_status "$WS" ns run parent "$did" | jq -e '.status == "failed"' >/dev/null
}

@test "successful child records result and invokes run-plan with all roots" {
  did="$(start_child 'successful child')"
  RALPH_TEST_CHILD_MODE=success run_child "$did"
  graph_delegation_ledger_read_status "$WS" ns run parent "$did" | jq -e '.status == "succeeded" and .finalResult.resultArtifact' >/dev/null
  args="$(tr '\n' ' ' <"$ARGV")"
  [[ "$args" == *"--plan $(graph_delegation_ledger_plan_file "$WS" ns run parent "$did")"* ]]
  [[ "$args" == *"--workspace $PROJECT --workspace-root $STATE --agent-workspace $(dirname "$(graph_delegation_ledger_plan_file "$WS" ns run parent "$did")")/workspace"* ]]
  result_path="$(sed -n 's|^Required result artifact: ||p' "$(graph_delegation_ledger_plan_file "$WS" ns run parent "$did")")"
  [[ "$result_path" == "$(dirname "$(graph_delegation_ledger_plan_file "$WS" ns run parent "$did")")/workspace/"* ]]
  [ ! -d "$(dirname "$(graph_delegation_ledger_plan_file "$WS" ns run parent "$did")")/workspace" ]
}

@test "exhausted child retries produce failure rather than false success" {
  did="$(start_child 'never completes')"
  RALPH_TEST_CHILD_MODE=omit RALPH_DELEGATION_GUTTER_ITERATIONS=1 run run_child "$did"
  [ "$status" -ne 0 ]
  graph_delegation_ledger_read_status "$WS" ns run parent "$did" | jq -e '.status == "failed" and (.attempts | length) >= 1' >/dev/null
  [ -f "$WS/.ralph-workspace/logs/delegated-child-runner.log" ]
}

@test "read-only child mutation is rejected by the supervisor" {
  did="$(start_child 'must remain read only')"
  RALPH_TEST_CHILD_MODE=read-only-violation run run_child "$did"
  [ "$status" -ne 0 ]
  graph_delegation_ledger_read_status "$WS" ns run parent "$did" | jq -e '.status == "failed"' >/dev/null
  [ ! -e "$AGENT/forbidden.txt" ]
}

@test "changeset child is scope-checked and integrated into the parent workspace" {
  POLICY='{"maxChildren":1,"parentWriteScopes":["src/**"],"crossRuntime":{"mode":"changeset"}}'
  run_dir="$(graph_state_run_dir "$WS" ns run)"
  mkdir -p "$run_dir"
  printf '%s\n' '{"sourceBase":{"filesystemIdentity":"base-1"}}' >"$run_dir/run.json"
  did="$(start_child 'create a scoped child change')"
  RALPH_TEST_CHILD_MODE=changeset-success run_child "$did"
  [ "$(cat "$AGENT/src/child.txt")" = child ]
  status_json="$(graph_delegation_ledger_read_status "$WS" ns run parent "$did")"
  jq -e '.status == "succeeded" and .finalResult.integrated == true' <<<"$status_json" >/dev/null
  changeset="$(jq -r .finalResult.changesetArtifact <<<"$status_json")"
  integration="$(jq -r .finalResult.integrationResult <<<"$status_json")"
  jq -e '.kind == "graph-changeset" and .writeScopes == ["src/**"]' "$changeset" >/dev/null
  jq -e '.kind == "graph-integration" and .changeCount >= 1' "$integration" >/dev/null
}
