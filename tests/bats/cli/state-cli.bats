#!/usr/bin/env bats
source "$BATS_TEST_DIRNAME/../helper/load-lib.bash"
STATE_CLI="$REPO_ROOT/bundle/.ralph/bash-lib/state-cli.sh"
@test "state status works on an empty workspace" { local d; d="$(mktemp -d)"; run bash -c 'cd "$1" && RALPH_PLAN_WORKSPACE_ROOT="$1/.ralph-workspace" bash "$2" status' _ "$d" "$STATE_CLI"; [ "$status" -eq 0 ]; }
@test "state prune dry-run does not delete files and runs list manifest plus legacy" { local d before after; d="$(mktemp -d)"; mkdir -p "$d/.ralph-workspace/logs/a/runs/r1" "$d/.ralph-workspace/logs/b"; printf '{"run_id":"r1","plan_key":"a","status":"done"}\n' >"$d/.ralph-workspace/logs/a/runs/r1/run-manifest.json"; printf '{"plan_key":"b"}\n' >"$d/.ralph-workspace/logs/b/plan-usage-summary.json"; before="$(find "$d" -type f | wc -l)"; run env RALPH_PLAN_WORKSPACE_ROOT="$d/.ralph-workspace" bash "$STATE_CLI" runs; [ "$status" -eq 0 ]; [[ "$output" == *r1* && "$output" == *legacy* ]]; run env RALPH_PLAN_WORKSPACE_ROOT="$d/.ralph-workspace" bash "$STATE_CLI" prune --dry-run; after="$(find "$d" -type f | wc -l)"; [ "$before" -eq "$after" ]; }
@test "state rejects unknown commands" { run bash "$STATE_CLI" nope; [ "$status" -ne 0 ]; }

@test "state runs reports exact and degraded resume counts" {
  command -v jq >/dev/null 2>&1 || skip "jq unavailable"
  local d plan_key="a" run_id="r1"
  d="$(mktemp -d)"
  mkdir -p "$d/.ralph-workspace/logs/$plan_key/runs/$run_id" "$d/.ralph-workspace/sessions/$plan_key/todo-sessions"
  printf '%s\n' "- [ ] Keep this todo" >"$d/plan.md"
  printf '%s\n' '{"run_id":"r1","plan_key":"a","status":"done","plan_path":"'"$d"'/plan.md"}' \
    >"$d/.ralph-workspace/logs/$plan_key/runs/$run_id/run-manifest.json"
  local keep_hash
  keep_hash="$(python3 -c 'import hashlib,sys; print(hashlib.sha256(sys.argv[1].encode("utf-8")).hexdigest())' "Keep this todo")"
  printf '%s\n' "{\"schema_version\":1,\"manifest_key\":\"keep\",\"state\":\"active\",\"runtime\":\"cursor\",\"session_id\":\"s1\",\"capture\":\"exact\",\"identity\":{\"runId\":\"r1\",\"todoId\":\"keep\",\"todoHash\":\"$keep_hash\"},\"created_at\":\"t\",\"updated_at\":\"t\"}" \
    >"$d/.ralph-workspace/sessions/$plan_key/todo-sessions/keep.json"
  printf '%s\n' '{"schema_version":1,"manifest_key":"deg","state":"active","runtime":"cursor","session_id":"s2","capture":"degraded","identity":{"runId":"r1","todoId":"deg","todoHash":"other"},"created_at":"t","updated_at":"t"}' \
    >"$d/.ralph-workspace/sessions/$plan_key/todo-sessions/deg.json"
  run env RALPH_PLAN_WORKSPACE_ROOT="$d/.ralph-workspace" bash "$STATE_CLI" runs --plan a
  [ "$status" -eq 0 ]
  [[ "$output" == *"exact=1"* ]]
  [[ "$output" == *"degraded=1"* ]]
  [[ "$output" == *"hashes_match=no"* ]]
  rm -rf "$d"
}

@test "state show reports mismatched-todo-hash when plan text changed" {
  command -v jq >/dev/null 2>&1 || skip "jq unavailable"
  local d plan_key="a" run_id="r1"
  d="$(mktemp -d)"
  mkdir -p "$d/.ralph-workspace/logs/$plan_key/runs/$run_id" "$d/.ralph-workspace/sessions/$plan_key/todo-sessions"
  printf '%s\n' "- [ ] New todo text" >"$d/plan.md"
  printf '%s\n' '{"run_id":"r1","plan_key":"a","status":"done","plan_path":"'"$d"'/plan.md"}' \
    >"$d/.ralph-workspace/logs/$plan_key/runs/$run_id/run-manifest.json"
  printf '%s\n' '{"schema_version":1,"manifest_key":"keep","state":"active","runtime":"cursor","session_id":"s1","capture":"exact","identity":{"runId":"r1","todoId":"keep","todoHash":"stale-hash"},"created_at":"t","updated_at":"t"}' \
    >"$d/.ralph-workspace/sessions/$plan_key/todo-sessions/keep.json"
  run env RALPH_PLAN_WORKSPACE_ROOT="$d/.ralph-workspace" bash "$STATE_CLI" show r1
  [ "$status" -eq 0 ]
  [[ "$output" == *"mismatched-todo-hash"* ]]
  rm -rf "$d"
}
