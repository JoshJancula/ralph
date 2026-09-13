#!/usr/bin/env bats
# Exact run-local allow-run and deny approval policy.

source "$BATS_TEST_DIRNAME/../helper/load-lib.bash"
source "$BATS_TEST_DIRNAME/../../../bundle/.ralph/bash-lib/graph/graph-approval-policy.sh"

setup() {
  TMPD="$(mktemp -d)"
  RUN_DIR="$TMPD/run"
  OTHER_RUN="$TMPD/other-run"
  STATE_ROOT="$TMPD/state"
  PROJECT_ROOT="$TMPD/project"
  mkdir -p "$RUN_DIR" "$OTHER_RUN"
  export GRAPH_APPROVAL_NOW="2026-08-13T00:00:00Z"
  export GRAPH_OPERATOR_NOW="2026-08-13T00:00:00Z"
}

teardown() {
  rm -rf "$TMPD"
  unset GRAPH_APPROVAL_NOW GRAPH_OPERATOR_NOW 2>/dev/null || true
}

rule_json() {
  jq -nc \
    --arg decision "${1:-allow-run}" \
    --arg runtime "${2:-cursor}" \
    --arg action "${3:-Bash}" \
    --arg resource "${4:-src/app.ts}" \
    --arg effect "${5:-write}" \
    --arg requestId "${6:-}" \
    '{
      decision:$decision,
      runtime:$runtime,
      action:$action,
      resource:$resource,
      effect:$effect
    } + (if $requestId == "" then {} else {requestId:$requestId} end)'
}

request_json() {
  jq -nc \
    --arg runtime "${1:-cursor}" \
    --arg action "${2:-Bash}" \
    --arg resource "${3:-src/app.ts}" \
    --arg effect "${4:-write}" \
    --arg requestId "${5:-}" \
    --arg managed "${6:-}" \
    --arg runtime_denial "${7:-}" \
    '{
      runtime:$runtime,
      action:$action,
      resource:$resource,
      effect:$effect
    }
    + (if $requestId == "" then {} else {requestId:$requestId} end)
    + (if $managed == "1" then {managedDenial:true} else {} end)
    + (if $runtime_denial == "1" then {runtimeDenial:true} else {} end)'
}

write_allow_once_decision() {
  local request_id="${1:-req-001}"
  mkdir -p "$RUN_DIR/operator/decisions"
  jq -nc \
    --arg requestId "$request_id" \
    '{
      schemaVersion:1,
      requestId:$requestId,
      decision:"allow-once",
      runtime:"cursor",
      granted:{action:"Bash",resource:"src/app.ts",effect:"write"}
    }' >"$RUN_DIR/operator/decisions/${request_id}.json"
}

@test "approval run policy writes exact normalized allow-run rule under the selected run" {
  local path listed
  run graph_approval_run_rule_write "$RUN_DIR" "$(rule_json allow-run cursor Bash './src//app.ts' WRITE req-001)"
  [ "$status" -eq 0 ]
  path="$output"
  [[ "$path" == */operator/policy/*.json ]]
  [ -f "$path" ]
  [ ! -L "$path" ]

  [ "$(jq -r '.schemaVersion' "$path")" = "1" ]
  [ "$(jq -r '.scope' "$path")" = "run" ]
  [ "$(jq -r '.decision' "$path")" = "allow-run" ]
  [ "$(jq -r '.runtime' "$path")" = "cursor" ]
  [ "$(jq -r '.action' "$path")" = "Bash" ]
  [ "$(jq -r '.resource' "$path")" = "src/app.ts" ]
  [ "$(jq -r '.effect' "$path")" = "write" ]
  [ "$(jq -r '.requestId' "$path")" = "req-001" ]
  [ "$(jq -r '.createdAt' "$path")" = "2026-08-13T00:00:00Z" ]

  run graph_approval_run_rule_read "$RUN_DIR" cursor Bash src/app.ts write
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '.decision')" = "allow-run" ]

  listed="$(graph_approval_run_rule_list "$RUN_DIR")"
  [ "$(printf '%s' "$listed" | jq 'length')" = "1" ]
  [ "$(printf '%s' "$listed" | jq -r '.[0].resource')" = "src/app.ts" ]
}

@test "approval run policy writes exact deny rule under the selected run" {
  local path
  path="$(graph_approval_run_rule_write "$RUN_DIR" "$(rule_json deny)")"
  [ -f "$path" ]
  [ "$(jq -r '.decision' "$path")" = "deny" ]
  [ "$(jq -r '.scope' "$path")" = "run" ]

  run graph_approval_resolve "$RUN_DIR" "$(request_json)"
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '.decision')" = "deny" ]
  [ "$(printf '%s' "$output" | jq -r '.source')" = "ralph-deny" ]
}

@test "approval run policy rejects allow-once allow-always and malformed rules" {
  run graph_approval_run_rule_write "$RUN_DIR" "$(rule_json allow-once)"
  [ "$status" -ne 0 ]
  [[ "$output" == *"allow-run or deny"* ]]
  [ "$(graph_approval_run_rule_list "$RUN_DIR")" = "[]" ]

  run graph_approval_run_rule_write "$RUN_DIR" "$(rule_json allow-always)"
  [ "$status" -ne 0 ]
  [ "$(graph_approval_run_rule_list "$RUN_DIR")" = "[]" ]

  run graph_approval_run_rule_write "$RUN_DIR" "$(rule_json allow-run cursor Bash '../etc/passwd' write)"
  [ "$status" -ne 0 ]
  [[ "$output" == *".."* ]]

  run graph_approval_run_rule_write "$RUN_DIR" "$(rule_json allow-run cursor Bash src/app.ts execute)"
  [ "$status" -ne 0 ]
  [[ "$output" == *"effect"* ]]

  run graph_approval_run_rule_write "$RUN_DIR" "$(rule_json allow-run unknown Bash src/app.ts write)"
  [ "$status" -ne 0 ]
  [[ "$output" == *"runtime"* ]]

  run graph_approval_run_rule_write "$RUN_DIR" '{"decision":"allow-run"}'
  [ "$status" -ne 0 ]
  [ ! -d "$RUN_DIR/operator/policy" ] || [ "$(graph_approval_run_rule_list "$RUN_DIR")" = "[]" ]
}

@test "approval run policy resolves allow-run only for the exact normalized rule" {
  graph_approval_run_rule_write "$RUN_DIR" "$(rule_json allow-run cursor Bash src/app.ts write)" >/dev/null

  run graph_approval_resolve "$RUN_DIR" "$(request_json cursor Bash './src/app.ts' write)"
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '.decision')" = "allow-run" ]
  [ "$(printf '%s' "$output" | jq -r '.source')" = "run-rule" ]
  [ "$(printf '%s' "$output" | jq -r '.matched.resource')" = "src/app.ts" ]

  run graph_approval_resolve "$RUN_DIR" "$(request_json cursor Bash src/other.ts write)"
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '.decision')" = "ask" ]
  [ "$(printf '%s' "$output" | jq -r '.source')" = "none" ]

  run graph_approval_resolve "$RUN_DIR" "$(request_json cursor Bash 'src/**' write)"
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '.decision')" = "ask" ]

  run graph_approval_resolve "$RUN_DIR" "$(request_json cursor Edit src/app.ts write)"
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '.decision')" = "ask" ]

  run graph_approval_resolve "$RUN_DIR" "$(request_json cursor Bash src/app.ts read)"
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '.decision')" = "ask" ]

  run graph_approval_resolve "$RUN_DIR" "$(request_json claude Bash src/app.ts write)"
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '.decision')" = "ask" ]
}

@test "approval run policy isolates rules to the selected run" {
  graph_approval_run_rule_write "$RUN_DIR" "$(rule_json allow-run)" >/dev/null
  graph_approval_run_rule_write "$OTHER_RUN" "$(rule_json deny)" >/dev/null

  run graph_approval_resolve "$RUN_DIR" "$(request_json)"
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '.decision')" = "allow-run" ]

  run graph_approval_resolve "$OTHER_RUN" "$(request_json)"
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '.decision')" = "deny" ]
  [ "$(printf '%s' "$output" | jq -r '.source')" = "ralph-deny" ]

  [ "$(graph_approval_run_rule_list "$RUN_DIR" | jq -r '.[0].decision')" = "allow-run" ]
  [ "$(graph_approval_run_rule_list "$OTHER_RUN" | jq -r '.[0].decision')" = "deny" ]
  [ ! -e "$TMPD/operator" ]
}

@test "approval run policy managed denial is supreme over allow-run and allow-once" {
  graph_approval_run_rule_write "$RUN_DIR" "$(rule_json allow-run)" >/dev/null
  write_allow_once_decision req-001

  run graph_approval_resolve "$RUN_DIR" "$(request_json cursor Bash src/app.ts write req-001 1)"
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '.decision')" = "deny" ]
  [ "$(printf '%s' "$output" | jq -r '.source')" = "managed-denial" ]
}

@test "approval run policy runtime denial is supreme over ralph allow-run" {
  graph_approval_run_rule_write "$RUN_DIR" "$(rule_json allow-run)" >/dev/null

  run graph_approval_resolve "$RUN_DIR" "$(request_json cursor Bash src/app.ts write '' '' 1)"
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '.decision')" = "deny" ]
  [ "$(printf '%s' "$output" | jq -r '.source')" = "runtime-denial" ]

  run graph_approval_resolve "$RUN_DIR" "$(request_json | jq -c '.denialSource = "runtime"')"
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '.source')" = "runtime-denial" ]
}

@test "approval run policy ralph deny precedes allow-once and exact run rule" {
  write_allow_once_decision req-001
  graph_approval_run_rule_write "$RUN_DIR" "$(rule_json deny)" >/dev/null

  run graph_approval_resolve "$RUN_DIR" "$(request_json cursor Bash src/app.ts write req-001)"
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '.decision')" = "deny" ]
  [ "$(printf '%s' "$output" | jq -r '.source')" = "ralph-deny" ]
}

@test "approval run policy allow-once precedes exact run rule" {
  graph_approval_run_rule_write "$RUN_DIR" "$(rule_json allow-run)" >/dev/null
  write_allow_once_decision req-001

  run graph_approval_resolve "$RUN_DIR" "$(request_json cursor Bash src/app.ts write req-001)"
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '.decision')" = "allow-once" ]
  [ "$(printf '%s' "$output" | jq -r '.source')" = "allow-once" ]

  run graph_approval_resolve "$RUN_DIR" "$(request_json cursor Bash src/app.ts write req-002)"
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '.decision')" = "allow-run" ]
  [ "$(printf '%s' "$output" | jq -r '.source')" = "run-rule" ]
}

@test "approval run policy resolution order asks when no run rule matches" {
  write_allow_once_decision req-001

  run graph_approval_resolve "$RUN_DIR" "$(request_json cursor Bash src/other.ts write req-002)"
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '.decision')" = "ask" ]
  [ "$(printf '%s' "$output" | jq -r '.source')" = "none" ]
  [ "$(printf '%s' "$output" | jq -r '.matched')" = "null" ]
}

@test "approval run policy identical writes are idempotent and conflicts keep the original deny" {
  local path before after
  path="$(graph_approval_run_rule_write "$RUN_DIR" "$(rule_json deny)")"
  before="$(shasum "$path" | awk '{print $1}')"

  run graph_approval_run_rule_write "$RUN_DIR" "$(rule_json deny cursor Bash src/app.ts write)"
  [ "$status" -eq 0 ]
  [ "$output" = "$path" ]
  after="$(shasum "$path" | awk '{print $1}')"
  [ "$before" = "$after" ]

  run graph_approval_run_rule_write "$RUN_DIR" "$(rule_json allow-run)"
  [ "$status" -ne 0 ]
  [[ "$output" == *"conflicts"* ]]
  after="$(shasum "$path" | awk '{print $1}')"
  [ "$before" = "$after" ]
  [ "$(jq -r '.decision' "$path")" = "deny" ]

  run graph_approval_resolve "$RUN_DIR" "$(request_json)"
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '.decision')" = "deny" ]
}

@test "approval run policy concurrent identical writes yield one rule" {
  graph_approval_run_rule_write "$RUN_DIR" "$(rule_json allow-run)" >"$TMPD/w1.path" 2>"$TMPD/w1.err" &
  local pid1=$!
  graph_approval_run_rule_write "$RUN_DIR" "$(rule_json allow-run)" >"$TMPD/w2.path" 2>"$TMPD/w2.err" &
  local pid2=$!
  wait $pid1
  local rc1=$?
  wait $pid2
  local rc2=$?
  [ "$rc1" -eq 0 ]
  [ "$rc2" -eq 0 ]
  [ "$(cat "$TMPD/w1.path")" = "$(cat "$TMPD/w2.path")" ]
  [ "$(find "$RUN_DIR/operator/policy" -name '*.json' | wc -l | tr -d ' ')" = "1" ]
  [ "$(jq -r '.decision' "$(cat "$TMPD/w1.path")")" = "allow-run" ]
}

@test "approval run policy concurrent conflicting writes keep one winner" {
  (
    set +e
    graph_approval_run_rule_write "$RUN_DIR" "$(rule_json allow-run)" >"$TMPD/c1.path" 2>"$TMPD/c1.err"
    echo $? >"$TMPD/c1.rc"
  ) &
  local pid1=$!
  (
    set +e
    graph_approval_run_rule_write "$RUN_DIR" "$(rule_json deny)" >"$TMPD/c2.path" 2>"$TMPD/c2.err"
    echo $? >"$TMPD/c2.rc"
  ) &
  local pid2=$!
  wait $pid1 $pid2
  local rc1 rc2 winner
  rc1="$(cat "$TMPD/c1.rc")"
  rc2="$(cat "$TMPD/c2.rc")"
  if [[ "$rc1" -eq 0 && "$rc2" -ne 0 ]]; then
    winner="$(cat "$TMPD/c1.path")"
    [ "$(jq -r '.decision' "$winner")" = "allow-run" ]
  elif [[ "$rc2" -eq 0 && "$rc1" -ne 0 ]]; then
    winner="$(cat "$TMPD/c2.path")"
    [ "$(jq -r '.decision' "$winner")" = "deny" ]
  else
    echo "expected one success and one conflict, got rc1=$rc1 rc2=$rc2" >&2
    return 1
  fi
  [ "$(find "$RUN_DIR/operator/policy" -name '*.json' | wc -l | tr -d ' ')" = "1" ]
}

@test "approval run policy never writes outside the selected run" {
  local path run_real
  path="$(graph_approval_run_rule_write "$RUN_DIR" "$(rule_json allow-run)")"
  run_real="$(cd "$RUN_DIR" && pwd -P)"
  [[ "$path" == "$run_real"/operator/policy/*.json ]]
  [ -f "$path" ]
  [ "$(find "$OTHER_RUN" -name '*.json' | wc -l | tr -d ' ')" = "0" ]
  [ "$(graph_approval_run_rule_list "$OTHER_RUN")" = "[]" ]
}

@test "approval run policy malformed exact rule fails closed instead of asking" {
  local rule_id abs
  rule_id="$(graph_approval_rule_id cursor Bash src/app.ts write)"
  mkdir -p "$RUN_DIR/operator/policy"
  abs="$RUN_DIR/operator/policy/${rule_id}.json"
  printf 'not-json\n' >"$abs"

  run graph_approval_resolve "$RUN_DIR" "$(request_json)"
  [ "$status" -ne 0 ]
  [[ "$output" != *'"decision":"ask"'* ]]
  [[ "$output" != *'"decision":"allow-run"'* ]]
}

write_run_roots() {
  local project_root="${1:-$PROJECT_ROOT}"
  local state_root="${2:-$STATE_ROOT}"
  jq -nc --arg project "$project_root" --arg state "$state_root" \
    '{roots:{projectRoot:$project,stateRoot:$state}}' >"$RUN_DIR/run.json"
}

confirm_json() {
  jq -nc \
    --arg requestId "${1:-req-001}" \
    --arg runtime "${2:-cursor}" \
    --arg action "${3:-Bash}" \
    --arg resource "${4:-src/app.ts}" \
    --arg effect "${5:-write}" \
    '{
      requestId:$requestId,
      runtime:$runtime,
      action:$action,
      resource:$resource,
      effect:$effect
    }'
}

project_rule_json() {
  jq -nc \
    --arg requestId "${1:-req-001}" \
    --arg runtime "${2:-cursor}" \
    --arg action "${3:-Bash}" \
    --arg resource "${4:-src/app.ts}" \
    --arg effect "${5:-write}" \
    --arg decision "${6:-allow-always}" \
    '{
      decision:$decision,
      requestId:$requestId,
      runtime:$runtime,
      action:$action,
      resource:$resource,
      effect:$effect
    }'
}

grant_project_allow_always() {
  local project_root="${1:-$PROJECT_ROOT}"
  local request_id="${2:-req-001}"
  local runtime="${3:-cursor}"
  local action="${4:-Bash}"
  local resource="${5:-src/app.ts}"
  local effect="${6:-write}"
  graph_approval_project_confirm_write "$STATE_ROOT" "$project_root" \
    "$(confirm_json "$request_id" "$runtime" "$action" "$resource" "$effect")" >/dev/null
  graph_approval_project_rule_write "$STATE_ROOT" "$project_root" \
    "$(project_rule_json "$request_id" "$runtime" "$action" "$resource" "$effect")"
}

@test "approval project policy writes allow-always under the state root keyed by canonical identity" {
  local path listed project_id canonical
  HOME="$TMPD/home"
  mkdir -p "$HOME" "$STATE_ROOT" "$PROJECT_ROOT"
  export HOME
  write_run_roots

  canonical="$(graph_approval_project_canonical_root "$PROJECT_ROOT")"
  project_id="$(graph_approval_project_identity "$PROJECT_ROOT")"
  [ -n "$project_id" ]
  [ "$canonical" = "$(cd "$PROJECT_ROOT" && pwd -P)" ]

  path="$(grant_project_allow_always)"
  [ -f "$path" ]
  [ ! -L "$path" ]
  [[ "$path" == */operator-policy/approvals.json ]]
  [ "$path" = "$(graph_approval_project_policy_path "$STATE_ROOT")" ]
  [ "$(jq -r --arg pid "$project_id" '.projects[$pid].projectRoot' "$path")" = "$canonical" ]
  [ "$(jq -r --arg pid "$project_id" '.projects[$pid].rules[0].scope' "$path")" = "project" ]
  [ "$(jq -r --arg pid "$project_id" '.projects[$pid].rules[0].decision' "$path")" = "allow-always" ]
  [ "$(jq -r --arg pid "$project_id" '.projects[$pid].rules[0].resource' "$path")" = "src/app.ts" ]
  [ "$(jq -r --arg pid "$project_id" '.projects[$pid].rules[0].revokedAt' "$path")" = "null" ]
  [ "$(jq -r --arg pid "$project_id" '.projects[$pid].rules[0].requestId' "$path")" = "req-001" ]

  listed="$(graph_approval_project_rule_list "$STATE_ROOT" "$PROJECT_ROOT")"
  [ "$(printf '%s' "$listed" | jq 'length')" = "1" ]
  [ "$(printf '%s' "$listed" | jq -r '.[0].decision')" = "allow-always" ]

  run graph_approval_resolve "$RUN_DIR" "$(request_json)"
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '.decision')" = "allow-always" ]
  [ "$(printf '%s' "$output" | jq -r '.source')" = "project-rule" ]
  [ "$(printf '%s' "$output" | jq -r '.matched.resource')" = "src/app.ts" ]
}

@test "approval project policy requires a second confirmation record tied to the original request" {
  HOME="$TMPD/home"
  mkdir -p "$HOME" "$STATE_ROOT" "$PROJECT_ROOT"
  export HOME
  write_run_roots

  run graph_approval_project_rule_write "$STATE_ROOT" "$PROJECT_ROOT" "$(project_rule_json)"
  [ "$status" -ne 0 ]
  [[ "$output" == *"second confirmation"* ]]
  [ ! -f "$STATE_ROOT/operator-policy/approvals.json" ]

  run graph_approval_project_confirm_write "$STATE_ROOT" "$PROJECT_ROOT" "$(confirm_json req-001)"
  [ "$status" -eq 0 ]
  [[ "$output" == */operator-policy/confirmations/*/*.json ]]
  [ -f "$output" ]
  [ "$(jq -r '.kind' "$output")" = "allow-always-confirmation" ]
  [ "$(jq -r '.requestId' "$output")" = "req-001" ]

  run graph_approval_resolve "$RUN_DIR" "$(request_json)"
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '.decision')" = "ask" ]

  run graph_approval_project_rule_write "$STATE_ROOT" "$PROJECT_ROOT" "$(project_rule_json req-002)"
  [ "$status" -ne 0 ]
  [[ "$output" == *"second confirmation"* ]]
  [ ! -f "$STATE_ROOT/operator-policy/approvals.json" ]

  run graph_approval_project_rule_write "$STATE_ROOT" "$PROJECT_ROOT" "$(project_rule_json req-001 cursor Bash src/other.ts write)"
  [ "$status" -ne 0 ]
  [[ "$output" == *"second confirmation"* ]]

  run graph_approval_project_rule_write "$STATE_ROOT" "$PROJECT_ROOT" "$(project_rule_json req-001)"
  [ "$status" -eq 0 ]
  [ -f "$STATE_ROOT/operator-policy/approvals.json" ]

  run graph_approval_resolve "$RUN_DIR" "$(request_json)"
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '.decision')" = "allow-always" ]
  [ "$(printf '%s' "$output" | jq -r '.source')" = "project-rule" ]
}

@test "approval project policy confirmation replay is idempotent and conflicts keep the original" {
  local path before after
  mkdir -p "$STATE_ROOT" "$PROJECT_ROOT"
  path="$(graph_approval_project_confirm_write "$STATE_ROOT" "$PROJECT_ROOT" "$(confirm_json req-001)")"
  before="$(shasum "$path" | awk '{print $1}')"

  run graph_approval_project_confirm_write "$STATE_ROOT" "$PROJECT_ROOT" "$(confirm_json req-001 cursor Bash './src/app.ts' WRITE)"
  [ "$status" -eq 0 ]
  [ "$output" = "$path" ]
  after="$(shasum "$path" | awk '{print $1}')"
  [ "$before" = "$after" ]

  run graph_approval_project_confirm_write "$STATE_ROOT" "$PROJECT_ROOT" "$(confirm_json req-001 cursor Edit src/app.ts write)"
  [ "$status" -ne 0 ]
  [[ "$output" == *"conflicts"* ]]
  after="$(shasum "$path" | awk '{print $1}')"
  [ "$before" = "$after" ]
}

@test "approval project policy isolates rules by canonical project identity" {
  local other_project other_run
  mkdir -p "$STATE_ROOT" "$PROJECT_ROOT"
  other_project="$TMPD/other-project"
  other_run="$TMPD/other-run"
  mkdir -p "$other_project" "$other_run"
  write_run_roots
  jq -nc --arg project "$other_project" --arg state "$STATE_ROOT" \
    '{roots:{projectRoot:$project,stateRoot:$state}}' >"$other_run/run.json"

  grant_project_allow_always "$PROJECT_ROOT" >/dev/null

  run graph_approval_resolve "$RUN_DIR" "$(request_json)"
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '.decision')" = "allow-always" ]

  run graph_approval_resolve "$other_run" "$(request_json)"
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '.decision')" = "ask" ]
  [ "$(printf '%s' "$output" | jq -r '.source')" = "none" ]

  [ "$(graph_approval_project_rule_list "$STATE_ROOT" "$other_project")" = "[]" ]
  [ "$(graph_approval_project_identity "$PROJECT_ROOT")" != "$(graph_approval_project_identity "$other_project")" ]
}

@test "approval project policy canonicalizes project identity across equivalent roots" {
  local linked
  mkdir -p "$STATE_ROOT" "$PROJECT_ROOT"
  linked="$TMPD/linked-project"
  ln -s "$PROJECT_ROOT" "$linked"
  write_run_roots "$linked"

  [ "$(graph_approval_project_identity "$linked")" = "$(graph_approval_project_identity "$PROJECT_ROOT")" ]
  grant_project_allow_always "$PROJECT_ROOT" >/dev/null

  run graph_approval_resolve "$RUN_DIR" "$(request_json)"
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '.decision')" = "allow-always" ]
}

@test "approval project policy revoke stops matching and records revocation metadata" {
  local listed
  mkdir -p "$STATE_ROOT" "$PROJECT_ROOT"
  write_run_roots
  grant_project_allow_always >/dev/null

  run graph_approval_project_rule_revoke "$STATE_ROOT" "$PROJECT_ROOT" cursor Bash src/app.ts write
  [ "$status" -eq 0 ]
  listed="$(graph_approval_project_rule_list "$STATE_ROOT" "$PROJECT_ROOT")"
  [ "$(printf '%s' "$listed" | jq 'length')" = "1" ]
  [ "$(printf '%s' "$listed" | jq -r '.[0].revokedAt')" = "2026-08-13T00:00:00Z" ]

  run graph_approval_resolve "$RUN_DIR" "$(request_json)"
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '.decision')" = "ask" ]
  [ "$(printf '%s' "$output" | jq -r '.source')" = "none" ]

  run graph_approval_project_rule_revoke "$STATE_ROOT" "$PROJECT_ROOT" cursor Bash src/app.ts write
  [ "$status" -eq 0 ]
  [ "$(graph_approval_project_rule_list "$STATE_ROOT" "$PROJECT_ROOT" | jq -r '.[0].revokedAt')" = "2026-08-13T00:00:00Z" ]
}

@test "approval project policy never edits runtime-global files" {
  local home_cursor home_claude home_codex home_opencode
  HOME="$TMPD/home"
  home_cursor="$HOME/.cursor"
  home_claude="$HOME/.claude"
  home_codex="$HOME/.codex"
  home_opencode="$HOME/.opencode"
  mkdir -p "$HOME" "$STATE_ROOT" "$PROJECT_ROOT" "$home_cursor" "$home_claude" "$home_codex" "$home_opencode"
  export HOME
  printf 'keep\n' >"$home_cursor/settings.json"
  printf 'keep\n' >"$home_claude/settings.json"
  printf 'keep\n' >"$home_codex/config.toml"
  printf 'keep\n' >"$home_opencode/opencode.json"
  write_run_roots

  grant_project_allow_always >/dev/null
  graph_approval_project_rule_revoke "$STATE_ROOT" "$PROJECT_ROOT" cursor Bash src/app.ts write >/dev/null

  [ "$(cat "$home_cursor/settings.json")" = "keep" ]
  [ "$(cat "$home_claude/settings.json")" = "keep" ]
  [ "$(cat "$home_codex/config.toml")" = "keep" ]
  [ "$(cat "$home_opencode/opencode.json")" = "keep" ]
  [ "$(find "$home_cursor" "$home_claude" "$home_codex" "$home_opencode" -type f | wc -l | tr -d ' ')" = "4" ]
  [ -f "$STATE_ROOT/operator-policy/approvals.json" ]
  [ ! -e "$PROJECT_ROOT/.cursor" ]
  [ ! -e "$PROJECT_ROOT/.claude" ]
}

@test "approval project policy managed denial is supreme over allow-always" {
  mkdir -p "$STATE_ROOT" "$PROJECT_ROOT"
  write_run_roots
  grant_project_allow_always >/dev/null

  run graph_approval_resolve "$RUN_DIR" "$(request_json cursor Bash src/app.ts write req-001 1)"
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '.decision')" = "deny" ]
  [ "$(printf '%s' "$output" | jq -r '.source')" = "managed-denial" ]
}

@test "approval project policy runtime denial is supreme over allow-always" {
  mkdir -p "$STATE_ROOT" "$PROJECT_ROOT"
  write_run_roots
  grant_project_allow_always >/dev/null

  run graph_approval_resolve "$RUN_DIR" "$(request_json cursor Bash src/app.ts write '' '' 1)"
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '.decision')" = "deny" ]
  [ "$(printf '%s' "$output" | jq -r '.source')" = "runtime-denial" ]
}

@test "approval project policy ralph deny and allow-run precede project allow-always" {
  mkdir -p "$STATE_ROOT" "$PROJECT_ROOT"
  write_run_roots
  grant_project_allow_always >/dev/null
  graph_approval_run_rule_write "$RUN_DIR" "$(rule_json deny)" >/dev/null

  run graph_approval_resolve "$RUN_DIR" "$(request_json)"
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '.decision')" = "deny" ]
  [ "$(printf '%s' "$output" | jq -r '.source')" = "ralph-deny" ]

  rm -f "$RUN_DIR/operator/policy/"*.json
  graph_approval_run_rule_write "$RUN_DIR" "$(rule_json allow-run)" >/dev/null
  run graph_approval_resolve "$RUN_DIR" "$(request_json)"
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '.decision')" = "allow-run" ]
  [ "$(printf '%s' "$output" | jq -r '.source')" = "run-rule" ]
}

@test "approval project policy resolves allow-always only for the exact normalized rule" {
  mkdir -p "$STATE_ROOT" "$PROJECT_ROOT"
  write_run_roots
  grant_project_allow_always >/dev/null

  run graph_approval_resolve "$RUN_DIR" "$(request_json cursor Bash './src/app.ts' write)"
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '.decision')" = "allow-always" ]

  run graph_approval_resolve "$RUN_DIR" "$(request_json cursor Bash src/other.ts write)"
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '.decision')" = "ask" ]

  run graph_approval_resolve "$RUN_DIR" "$(request_json cursor Edit src/app.ts write)"
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '.decision')" = "ask" ]

  run graph_approval_resolve "$RUN_DIR" "$(request_json claude Bash src/app.ts write)"
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '.decision')" = "ask" ]
}

@test "approval project policy identical writes are idempotent" {
  local path before after
  mkdir -p "$STATE_ROOT" "$PROJECT_ROOT"
  path="$(grant_project_allow_always)"
  before="$(shasum "$path" | awk '{print $1}')"

  run graph_approval_project_rule_write "$STATE_ROOT" "$PROJECT_ROOT" "$(project_rule_json)"
  [ "$status" -eq 0 ]
  [ "$output" = "$path" ]
  after="$(shasum "$path" | awk '{print $1}')"
  [ "$before" = "$after" ]
}

@test "approval project policy concurrent identical writes yield one rule" {
  mkdir -p "$STATE_ROOT" "$PROJECT_ROOT"
  graph_approval_project_confirm_write "$STATE_ROOT" "$PROJECT_ROOT" "$(confirm_json)" >/dev/null
  graph_approval_project_rule_write "$STATE_ROOT" "$PROJECT_ROOT" "$(project_rule_json)" >"$TMPD/pw1.path" 2>"$TMPD/pw1.err" &
  local pid1=$!
  graph_approval_project_rule_write "$STATE_ROOT" "$PROJECT_ROOT" "$(project_rule_json)" >"$TMPD/pw2.path" 2>"$TMPD/pw2.err" &
  local pid2=$!
  wait $pid1
  local rc1=$?
  wait $pid2
  local rc2=$?
  [ "$rc1" -eq 0 ]
  [ "$rc2" -eq 0 ]
  [ "$(cat "$TMPD/pw1.path")" = "$(cat "$TMPD/pw2.path")" ]
  [ "$(graph_approval_project_rule_list "$STATE_ROOT" "$PROJECT_ROOT" | jq 'length')" = "1" ]
}

@test "approval project policy malformed store fails closed instead of asking" {
  mkdir -p "$STATE_ROOT/operator-policy" "$PROJECT_ROOT"
  write_run_roots
  printf 'not-json\n' >"$STATE_ROOT/operator-policy/approvals.json"

  run graph_approval_resolve "$RUN_DIR" "$(request_json)"
  [ "$status" -ne 0 ]
  [[ "$output" != *'"decision":"ask"'* ]]
  [[ "$output" != *'"decision":"allow-always"'* ]]
}

@test "approval project policy rejects allow-run deny and writes outside the state root" {
  mkdir -p "$STATE_ROOT" "$PROJECT_ROOT"
  graph_approval_project_confirm_write "$STATE_ROOT" "$PROJECT_ROOT" "$(confirm_json)" >/dev/null

  run graph_approval_project_rule_write "$STATE_ROOT" "$PROJECT_ROOT" "$(project_rule_json req-001 cursor Bash src/app.ts write allow-run)"
  [ "$status" -ne 0 ]
  [[ "$output" == *"allow-always"* ]]
  [ ! -f "$STATE_ROOT/operator-policy/approvals.json" ]

  run graph_approval_project_rule_write "$STATE_ROOT" "$PROJECT_ROOT" "$(project_rule_json req-001 cursor Bash '../etc/passwd' write)"
  [ "$status" -ne 0 ]
  [[ "$output" == *".."* ]]
}
