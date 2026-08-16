#!/usr/bin/env bats
# Graph actions CLI: list pending operator requests, record decisions, and
# list or revoke project approvals.

source "$BATS_TEST_DIRNAME/../helper/load-lib.bash"
source "$BATS_TEST_DIRNAME/../../../bundle/.ralph/bash-lib/graph/graph-state.sh"
source "$BATS_TEST_DIRNAME/../../../bundle/.ralph/bash-lib/graph/graph-operator-records.sh"
source "$BATS_TEST_DIRNAME/../../../bundle/.ralph/bash-lib/graph/graph-approval-policy.sh"

GRAPH_RUN_SH="$REPO_ROOT/bundle/.ralph/graph-run.sh"

setup() {
  TMPD="$(mktemp -d)"
  WORKSPACE="$TMPD/ws"
  mkdir -p "$WORKSPACE"
  NAMESPACE="op-ns"
  RUN_ID="run-001"
  GRAPH_JSON="$TMPD/graph.json"
  PLAN_FILE="$WORKSPACE/actions.plan.md"
  printf '# actions list fixture\n' >"$PLAN_FILE"
  jq -n '{
    schemaVersion: 1,
    ralphVersion: "test",
    name: "actions-list",
    namespace: "op-ns",
    maxParallel: 1,
    failurePolicy: "cancel",
    nodes: [
      {
        id: "impl",
        type: "agent",
        dependsOn: [],
        derivedFrom: "stage",
        stage: {
          id: "impl",
          runtime: "cursor",
          agent: "implementation",
          workspaceMode: "snapshot"
        }
      }
    ],
    edges: []
  }' >"$GRAPH_JSON"
  graph_state_init_run "$WORKSPACE" "$NAMESPACE" "$RUN_ID" "$PLAN_FILE" "$GRAPH_JSON" 1
  RUN_DIR="$(graph_state_run_dir "$WORKSPACE" "$NAMESPACE" "$RUN_ID")"
  export GRAPH_OPERATOR_NOW="2026-08-13T00:00:00Z"
  export GRAPH_OPERATOR_NONCE="aabbccddeeff00112233445566778899"
  export GRAPH_APPROVAL_NOW="2026-08-13T00:00:00Z"
}

teardown() {
  rm -rf "$TMPD"
  unset GRAPH_OPERATOR_NOW GRAPH_OPERATOR_NONCE GRAPH_APPROVAL_NOW 2>/dev/null || true
}

valid_request_json() {
  jq -nc \
    --arg requestId "${1:-req-001}" \
    --arg nodeId "${2:-impl}" \
    --arg runtime "${3:-cursor}" \
    --arg action "${4:-Bash}" \
    --arg resource "${5:-src/app.ts}" \
    --arg effect "${6:-write}" \
    --arg choices_json "${7:-}" \
    --arg namespace "$NAMESPACE" \
    --arg runId "$RUN_ID" \
    '
    {
      requestId: $requestId,
      nonce: "aabbccddeeff00112233445566778899",
      namespace: $namespace,
      runId: $runId,
      nodeId: $nodeId,
      attemptId: "impl-1",
      runtime: $runtime,
      sessionId: "sess-1",
      classification: "operator-permission",
      action: $action,
      resource: $resource,
      effect: $effect,
      reason: "needs write access to apply the patch",
      choices: (if $choices_json == "" then ["allow-once","allow-run","allow-always","deny"] else ($choices_json|fromjson) end),
      createdAt: "2026-08-13T00:00:00Z",
      expiresAt: "2026-08-13T01:00:00Z"
    }
    '
}

write_request() {
  graph_operator_request_write "$RUN_DIR" "$(valid_request_json "$@")"
}

mark_request_resolved() {
  local request_id="$1" path
  path="$(graph_operator_decision_path "$RUN_DIR" "$request_id")" || return 1
  mkdir -p "$(dirname "$path")"
  jq -nc --arg requestId "$request_id" '{requestId:$requestId,decision:"allow-once"}' >"$path"
}

seed_active_attempt() {
  local run_dir="${1:-$RUN_DIR}"
  local node_id="${2:-impl}"
  local attempt_id="${3:-impl-1}"
  local runtime="${4:-cursor}"
  mkdir -p "$run_dir/nodes"
  jq -nc \
    --arg nodeId "$node_id" \
    --arg attemptId "$attempt_id" \
    --arg runtime "$runtime" \
    '{
      schemaVersion: 2,
      nodeId: $nodeId,
      status: "awaiting-operator",
      lastAttemptId: $attemptId,
      attempts: [{attemptId:$attemptId,runtime:$runtime}]
    }' >"$run_dir/nodes/${node_id}.json"
}

respond_cmd() {
  bash "$GRAPH_RUN_SH" actions respond "$@" --workspace "$WORKSPACE"
}

approvals_cmd() {
  bash "$GRAPH_RUN_SH" actions approvals "$@" --workspace "$WORKSPACE"
}

grant_project_allow_always() {
  local state_root request_id runtime action resource effect
  state_root="$(graph_state_state_root "$WORKSPACE")"
  request_id="${1:-req-001}"
  runtime="${2:-cursor}"
  action="${3:-Bash}"
  resource="${4:-src/app.ts}"
  effect="${5:-write}"
  graph_approval_project_confirm_write "$state_root" "$WORKSPACE" \
    "$(jq -nc \
      --arg requestId "$request_id" \
      --arg runtime "$runtime" \
      --arg action "$action" \
      --arg resource "$resource" \
      --arg effect "$effect" \
      '{requestId:$requestId,runtime:$runtime,action:$action,resource:$resource,effect:$effect}')" >/dev/null
  graph_approval_project_rule_write "$state_root" "$WORKSPACE" \
    "$(jq -nc \
      --arg requestId "$request_id" \
      --arg runtime "$runtime" \
      --arg action "$action" \
      --arg resource "$resource" \
      --arg effect "$effect" \
      '{requestId:$requestId,runtime:$runtime,action:$action,resource:$resource,effect:$effect,decision:"allow-always"}')"
}

seed_runtime_global_homes() {
  HOME="$TMPD/home"
  export HOME
  mkdir -p "$HOME/.cursor" "$HOME/.claude" "$HOME/.codex" "$HOME/.opencode" "$HOME/.agents"
  printf 'keep\n' >"$HOME/.cursor/settings.json"
  printf 'keep\n' >"$HOME/.claude/settings.json"
  printf 'keep\n' >"$HOME/.codex/config.toml"
  printf 'keep\n' >"$HOME/.opencode/opencode.json"
  printf 'keep\n' >"$HOME/.agents/agents.md"
}

assert_runtime_global_untouched() {
  [ "$(cat "$HOME/.cursor/settings.json")" = "keep" ]
  [ "$(cat "$HOME/.claude/settings.json")" = "keep" ]
  [ "$(cat "$HOME/.codex/config.toml")" = "keep" ]
  [ "$(cat "$HOME/.opencode/opencode.json")" = "keep" ]
  [ "$(cat "$HOME/.agents/agents.md")" = "keep" ]
  [ "$(find "$HOME/.cursor" "$HOME/.claude" "$HOME/.codex" "$HOME/.opencode" "$HOME/.agents" -type f | wc -l | tr -d ' ')" = "5" ]
  [ ! -e "$WORKSPACE/.cursor" ]
  [ ! -e "$WORKSPACE/.claude" ]
  [ ! -e "$WORKSPACE/.codex" ]
  [ ! -e "$WORKSPACE/.opencode" ]
  [ ! -e "$WORKSPACE/.agents" ]
}

@test "actions cli list --help exits 0" {
  run bash "$GRAPH_RUN_SH" actions list --help
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -q 'actions list'
  printf '%s\n' "$output" | grep -q -- '--namespace'
  printf '%s\n' "$output" | grep -q -- '--run'
}

@test "actions cli list errors without --namespace" {
  run bash "$GRAPH_RUN_SH" actions list --run "$RUN_ID" --workspace "$WORKSPACE"
  [ "$status" -ne 0 ]
  printf '%s\n' "$output" | grep -q 'namespace'
}

@test "actions cli list errors without --run" {
  run bash "$GRAPH_RUN_SH" actions list --namespace "$NAMESPACE" --workspace "$WORKSPACE"
  [ "$status" -ne 0 ]
  printf '%s\n' "$output" | grep -q 'run'
}

@test "actions cli list prints pending request id node runtime action resource effect and choices" {
  write_request >/dev/null
  run bash "$GRAPH_RUN_SH" actions list \
    --namespace "$NAMESPACE" \
    --run "$RUN_ID" \
    --workspace "$WORKSPACE"
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -q 'req-001'
  printf '%s\n' "$output" | grep -q 'node=impl'
  printf '%s\n' "$output" | grep -q 'runtime=cursor'
  printf '%s\n' "$output" | grep -q 'action=Bash'
  printf '%s\n' "$output" | grep -q 'resource=src/app.ts'
  printf '%s\n' "$output" | grep -q 'effect=write'
  printf '%s\n' "$output" | grep -q 'allow-once'
  printf '%s\n' "$output" | grep -q 'allow-run'
  printf '%s\n' "$output" | grep -q 'allow-always'
  printf '%s\n' "$output" | grep -q 'deny'
}

@test "actions cli list --json prints pending request id node runtime action resource effect and choices" {
  write_request >/dev/null
  run bash "$GRAPH_RUN_SH" actions list \
    --namespace "$NAMESPACE" \
    --run "$RUN_ID" \
    --workspace "$WORKSPACE" \
    --json
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '.namespace')" = "$NAMESPACE" ]
  [ "$(printf '%s' "$output" | jq -r '.runId')" = "$RUN_ID" ]
  [ "$(printf '%s' "$output" | jq -r '.requests | length')" = "1" ]
  [ "$(printf '%s' "$output" | jq -r '.requests[0].requestId')" = "req-001" ]
  [ "$(printf '%s' "$output" | jq -r '.requests[0].nodeId')" = "impl" ]
  [ "$(printf '%s' "$output" | jq -r '.requests[0].runtime')" = "cursor" ]
  [ "$(printf '%s' "$output" | jq -r '.requests[0].action')" = "Bash" ]
  [ "$(printf '%s' "$output" | jq -r '.requests[0].resource')" = "src/app.ts" ]
  [ "$(printf '%s' "$output" | jq -r '.requests[0].effect')" = "write" ]
  [ "$(printf '%s' "$output" | jq -c '.requests[0].choices')" = '["allow-once","allow-run","allow-always","deny"]' ]
}

@test "actions cli list omits resolved requests and keeps other pending rows" {
  write_request req-001 >/dev/null
  write_request req-002 review claude Read docs/GRAPH.md read '["allow-once","deny"]' >/dev/null
  mark_request_resolved req-001

  run bash "$GRAPH_RUN_SH" actions list \
    --namespace "$NAMESPACE" \
    --run "$RUN_ID" \
    --workspace "$WORKSPACE" \
    --json
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '.requests | length')" = "1" ]
  [ "$(printf '%s' "$output" | jq -r '.requests[0].requestId')" = "req-002" ]
  [ "$(printf '%s' "$output" | jq -r '.requests[0].nodeId')" = "review" ]
  [ "$(printf '%s' "$output" | jq -r '.requests[0].runtime')" = "claude" ]
  [ "$(printf '%s' "$output" | jq -r '.requests[0].action')" = "Read" ]
  [ "$(printf '%s' "$output" | jq -r '.requests[0].resource')" = "docs/GRAPH.md" ]
  [ "$(printf '%s' "$output" | jq -r '.requests[0].effect')" = "read" ]
  [ "$(printf '%s' "$output" | jq -c '.requests[0].choices')" = '["allow-once","deny"]' ]
  [ "$(printf '%s' "$output" | jq -r '[.requests[].requestId] | index("req-001")')" = "null" ]
}

@test "actions cli list --run latest resolves the namespace latest symlink" {
  write_request >/dev/null
  run bash "$GRAPH_RUN_SH" actions list \
    --namespace "$NAMESPACE" \
    --run latest \
    --workspace "$WORKSPACE" \
    --json
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '.runId')" = "$RUN_ID" ]
  [ "$(printf '%s' "$output" | jq -r '.requests[0].requestId')" = "req-001" ]
}

@test "actions cli list reports no pending requests when the run has none" {
  run bash "$GRAPH_RUN_SH" actions list \
    --namespace "$NAMESPACE" \
    --run "$RUN_ID" \
    --workspace "$WORKSPACE"
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -q 'no pending requests'

  run bash "$GRAPH_RUN_SH" actions list \
    --namespace "$NAMESPACE" \
    --run "$RUN_ID" \
    --workspace "$WORKSPACE" \
    --json
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '.requests | length')" = "0" ]
}

@test "actions cli list rejects an unknown option" {
  run bash "$GRAPH_RUN_SH" actions list \
    --namespace "$NAMESPACE" \
    --run "$RUN_ID" \
    --workspace "$WORKSPACE" \
    --bogus
  [ "$status" -ne 0 ]
  printf '%s\n' "$output" | grep -q 'unknown option'
}

@test "actions cli respond --help exits 0" {
  run bash "$GRAPH_RUN_SH" actions respond --help
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -q 'actions respond'
  printf '%s\n' "$output" | grep -q -- '--decision'
  printf '%s\n' "$output" | grep -q -- '--confirm-rule'
}

@test "actions cli respond errors without --decision" {
  write_request >/dev/null
  seed_active_attempt
  run respond_cmd req-001 --namespace "$NAMESPACE" --run "$RUN_ID"
  [ "$status" -ne 0 ]
  printf '%s\n' "$output" | grep -q -- '--decision'
}

@test "actions cli respond errors without request-id" {
  run respond_cmd --decision allow-once --namespace "$NAMESPACE" --run "$RUN_ID"
  [ "$status" -ne 0 ]
  printf '%s\n' "$output" | grep -q 'request-id'
}

@test "actions cli respond rejects an unknown decision" {
  write_request >/dev/null
  seed_active_attempt
  run respond_cmd req-001 --decision yolo --namespace "$NAMESPACE" --run "$RUN_ID"
  [ "$status" -ne 0 ]
  printf '%s\n' "$output" | grep -q 'decision'
  [ ! -e "$RUN_DIR/operator/decisions/req-001.json" ]
}

@test "actions cli respond rejects an unsafe request id before filesystem access" {
  run respond_cmd '../escape' --decision allow-once --namespace "$NAMESPACE" --run "$RUN_ID"
  [ "$status" -ne 0 ]
  printf '%s\n' "$output" | grep -q 'request id'
  [ ! -e "$TMPD/escape.json" ]
  [ ! -e "$RUN_DIR/operator/decisions/../escape.json" ]
}

@test "actions cli respond writes allow-once and prints request identity" {
  write_request >/dev/null
  seed_active_attempt
  run respond_cmd req-001 --decision allow-once --namespace "$NAMESPACE" --run "$RUN_ID"
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -q 'req-001'
  printf '%s\n' "$output" | grep -q 'decision=allow-once'
  printf '%s\n' "$output" | grep -q 'node=impl'
  printf '%s\n' "$output" | grep -q 'runtime=cursor'
  printf '%s\n' "$output" | grep -q 'action=Bash'
  printf '%s\n' "$output" | grep -q 'resource=src/app.ts'
  printf '%s\n' "$output" | grep -q 'effect=write'
  [ -f "$RUN_DIR/operator/decisions/req-001.json" ]
  [ "$(jq -r '.decision' "$RUN_DIR/operator/decisions/req-001.json")" = "allow-once" ]
  [ "$(jq -r '.actorSource' "$RUN_DIR/operator/decisions/req-001.json")" = "cli" ]
}

@test "actions cli respond --json prints the written decision path" {
  write_request >/dev/null
  seed_active_attempt
  run respond_cmd req-001 --decision deny --namespace "$NAMESPACE" --run "$RUN_ID" --json
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '.requestId')" = "req-001" ]
  [ "$(printf '%s' "$output" | jq -r '.decision')" = "deny" ]
  [ "$(printf '%s' "$output" | jq -r '.runId')" = "$RUN_ID" ]
  [ "$(printf '%s' "$output" | jq -r '.namespace')" = "$NAMESPACE" ]
  [[ "$(printf '%s' "$output" | jq -r '.path')" == */operator/decisions/req-001.json ]]
  [ "$(jq -r '.decision' "$RUN_DIR/operator/decisions/req-001.json")" = "deny" ]
}

@test "actions cli respond writes allow-run through the policy module" {
  write_request >/dev/null
  seed_active_attempt
  run respond_cmd req-001 --decision allow-run --namespace "$NAMESPACE" --run "$RUN_ID" --json
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '.decision')" = "allow-run" ]
  [ -f "$RUN_DIR/operator/decisions/req-001.json" ]
  [ "$(jq -r '.decision' "$RUN_DIR/operator/decisions/req-001.json")" = "allow-run" ]
  [[ "$(printf '%s' "$output" | jq -r '.rulePath')" == */operator/policy/*.json ]]
  [ -f "$(printf '%s' "$output" | jq -r '.rulePath')" ]
  [ "$(jq -r '.decision' "$(printf '%s' "$output" | jq -r '.rulePath')")" = "allow-run" ]
}

@test "actions cli respond allow-always without confirmation stops safely" {
  write_request >/dev/null
  seed_active_attempt
  run respond_cmd req-001 --decision allow-always --namespace "$NAMESPACE" --run "$RUN_ID"
  [ "$status" -ne 0 ]
  printf '%s\n' "$output" | grep -q 'confirm-rule'
  printf '%s\n' "$output" | grep -q 'action=Bash'
  printf '%s\n' "$output" | grep -q 'resource=src/app.ts'
  printf '%s\n' "$output" | grep -q 'effect=write'
  [ ! -e "$RUN_DIR/operator/decisions/req-001.json" ]
  [ ! -e "$(graph_state_state_root "$WORKSPACE")/operator-policy/approvals.json" ]
}

@test "actions cli respond allow-always with --confirm-rule persists the project rule" {
  local rule_id state_root
  write_request >/dev/null
  seed_active_attempt
  rule_id="$(graph_approval_rule_id cursor Bash src/app.ts write)"
  run respond_cmd req-001 --decision allow-always \
    --namespace "$NAMESPACE" --run "$RUN_ID" \
    --confirm-rule "$rule_id" --json
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '.decision')" = "allow-always" ]
  [ -f "$RUN_DIR/operator/decisions/req-001.json" ]
  [ "$(jq -r '.decision' "$RUN_DIR/operator/decisions/req-001.json")" = "allow-always" ]
  state_root="$(graph_state_state_root "$WORKSPACE")"
  [ -f "$state_root/operator-policy/approvals.json" ]
  [[ "$(printf '%s' "$output" | jq -r '.confirmPath')" == */operator-policy/confirmations/*/*.json ]]
  [[ "$(printf '%s' "$output" | jq -r '.rulePath')" == */operator-policy/approvals.json ]]
}

@test "actions cli respond allow-always rejects a mismatched --confirm-rule" {
  write_request >/dev/null
  seed_active_attempt
  run respond_cmd req-001 --decision allow-always \
    --namespace "$NAMESPACE" --run "$RUN_ID" \
    --confirm-rule not-the-rule-id
  [ "$status" -ne 0 ]
  printf '%s\n' "$output" | grep -q 'confirm-rule'
  [ ! -e "$RUN_DIR/operator/decisions/req-001.json" ]
}

@test "actions cli respond resolves a unique request without selectors" {
  write_request >/dev/null
  seed_active_attempt
  run respond_cmd req-001 --decision allow-once
  [ "$status" -eq 0 ]
  [ "$(jq -r '.decision' "$RUN_DIR/operator/decisions/req-001.json")" = "allow-once" ]
}

@test "actions cli respond requires selectors when the request id is ambiguous" {
  local ns2="other-ns" run2="run-002" run_dir2 json
  write_request >/dev/null
  seed_active_attempt
  graph_state_init_run "$WORKSPACE" "$ns2" "$run2" "$PLAN_FILE" "$GRAPH_JSON" 1
  run_dir2="$(graph_state_run_dir "$WORKSPACE" "$ns2" "$run2")"
  json="$(NAMESPACE="$ns2" RUN_ID="$run2" valid_request_json)"
  graph_operator_request_write "$run_dir2" "$json" >/dev/null
  seed_active_attempt "$run_dir2"

  run respond_cmd req-001 --decision allow-once
  [ "$status" -ne 0 ]
  printf '%s\n' "$output" | grep -q 'ambiguous'
  printf '%s\n' "$output" | grep -q -- '--namespace'
  printf '%s\n' "$output" | grep -q -- '--run'
  [ ! -e "$RUN_DIR/operator/decisions/req-001.json" ]
  [ ! -e "$run_dir2/operator/decisions/req-001.json" ]

  run respond_cmd req-001 --decision allow-once --namespace "$NAMESPACE" --run "$RUN_ID"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.decision' "$RUN_DIR/operator/decisions/req-001.json")" = "allow-once" ]
  [ ! -e "$run_dir2/operator/decisions/req-001.json" ]
}

@test "actions cli respond --run latest resolves the namespace latest symlink" {
  write_request >/dev/null
  seed_active_attempt
  run respond_cmd req-001 --decision allow-once --namespace "$NAMESPACE" --run latest --json
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '.runId')" = "$RUN_ID" ]
  [ "$(jq -r '.decision' "$RUN_DIR/operator/decisions/req-001.json")" = "allow-once" ]
}

@test "actions cli respond identical replay is idempotent" {
  write_request >/dev/null
  seed_active_attempt
  run respond_cmd req-001 --decision allow-once --namespace "$NAMESPACE" --run "$RUN_ID"
  [ "$status" -eq 0 ]
  run respond_cmd req-001 --decision allow-once --namespace "$NAMESPACE" --run "$RUN_ID"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.decision' "$RUN_DIR/operator/decisions/req-001.json")" = "allow-once" ]
}

@test "actions cli respond rejects a conflicting already-resolved decision" {
  write_request >/dev/null
  seed_active_attempt
  run respond_cmd req-001 --decision allow-once --namespace "$NAMESPACE" --run "$RUN_ID"
  [ "$status" -eq 0 ]
  run respond_cmd req-001 --decision deny --namespace "$NAMESPACE" --run "$RUN_ID"
  [ "$status" -ne 0 ]
  printf '%s\n' "$output" | grep -Eq 'already resolved|conflicts'
  [ "$(jq -r '.decision' "$RUN_DIR/operator/decisions/req-001.json")" = "allow-once" ]
}

@test "actions cli respond rejects an unknown option" {
  run respond_cmd req-001 --decision allow-once --namespace "$NAMESPACE" --run "$RUN_ID" --bogus
  [ "$status" -ne 0 ]
  printf '%s\n' "$output" | grep -q 'unknown option'
}

@test "actions cli approvals --help exits 0" {
  run bash "$GRAPH_RUN_SH" actions approvals --help
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -q 'actions approvals list'
  printf '%s\n' "$output" | grep -q 'actions approvals revoke'
}

@test "actions cli approvals list --help exits 0" {
  run bash "$GRAPH_RUN_SH" actions approvals list --help
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -q 'actions approvals list'
  printf '%s\n' "$output" | grep -q -- '--workspace'
}

@test "actions cli approvals revoke --help exits 0" {
  run bash "$GRAPH_RUN_SH" actions approvals revoke --help
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -q 'actions approvals revoke'
  printf '%s\n' "$output" | grep -q -- '--runtime'
  printf '%s\n' "$output" | grep -q -- '--action'
  printf '%s\n' "$output" | grep -q -- '--resource'
  printf '%s\n' "$output" | grep -q -- '--effect'
}

@test "actions cli approvals errors without a subcommand" {
  run bash "$GRAPH_RUN_SH" actions approvals
  [ "$status" -ne 0 ]
  printf '%s\n' "$output" | grep -q 'subcommand'
}

@test "actions cli approvals list reports no project approvals when none exist" {
  run approvals_cmd list
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -q 'no project approvals'

  run approvals_cmd list --json
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '.approvals | length')" = "0" ]
}

@test "actions cli approvals list prints exact normalized scope and revocation state" {
  grant_project_allow_always >/dev/null
  run approvals_cmd list
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -q 'runtime=cursor'
  printf '%s\n' "$output" | grep -q 'action=Bash'
  printf '%s\n' "$output" | grep -q 'resource=src/app.ts'
  printf '%s\n' "$output" | grep -q 'effect=write'
  printf '%s\n' "$output" | grep -q 'decision=allow-always'
  printf '%s\n' "$output" | grep -q 'revoked=no'
  ! printf '%s\n' "$output" | grep -q 'revokedAt='
}

@test "actions cli approvals list --json prints exact normalized scope and revocation state" {
  local rule_id
  grant_project_allow_always >/dev/null
  rule_id="$(graph_approval_rule_id cursor Bash src/app.ts write)"
  run approvals_cmd list --json
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '.approvals | length')" = "1" ]
  [ "$(printf '%s' "$output" | jq -r '.approvals[0].ruleId')" = "$rule_id" ]
  [ "$(printf '%s' "$output" | jq -r '.approvals[0].runtime')" = "cursor" ]
  [ "$(printf '%s' "$output" | jq -r '.approvals[0].action')" = "Bash" ]
  [ "$(printf '%s' "$output" | jq -r '.approvals[0].resource')" = "src/app.ts" ]
  [ "$(printf '%s' "$output" | jq -r '.approvals[0].effect')" = "write" ]
  [ "$(printf '%s' "$output" | jq -r '.approvals[0].decision')" = "allow-always" ]
  [ "$(printf '%s' "$output" | jq -r '.approvals[0].scope')" = "project" ]
  [ "$(printf '%s' "$output" | jq -r '.approvals[0].revoked')" = "false" ]
  [ "$(printf '%s' "$output" | jq -r '.approvals[0].revokedAt')" = "null" ]
  [[ "$(printf '%s' "$output" | jq -r '.path')" == */operator-policy/approvals.json ]]
  [[ "$(printf '%s' "$output" | jq -r '.stateRoot')" == */.ralph-workspace ]]
}

@test "actions cli approvals list shows normalized scope for unnormalized stored inputs" {
  grant_project_allow_always req-001 cursor Bash './src//app.ts' WRITE >/dev/null
  run approvals_cmd list --json
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '.approvals[0].runtime')" = "cursor" ]
  [ "$(printf '%s' "$output" | jq -r '.approvals[0].action')" = "Bash" ]
  [ "$(printf '%s' "$output" | jq -r '.approvals[0].resource')" = "src/app.ts" ]
  [ "$(printf '%s' "$output" | jq -r '.approvals[0].effect')" = "write" ]
  [ "$(printf '%s' "$output" | jq -r '.approvals[0].revoked')" = "false" ]
}

@test "actions cli approvals list includes revoked rules with revokedAt" {
  grant_project_allow_always >/dev/null
  run approvals_cmd revoke --runtime cursor --action Bash --resource src/app.ts --effect write
  [ "$status" -eq 0 ]
  run approvals_cmd list --json
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '.approvals | length')" = "1" ]
  [ "$(printf '%s' "$output" | jq -r '.approvals[0].runtime')" = "cursor" ]
  [ "$(printf '%s' "$output" | jq -r '.approvals[0].action')" = "Bash" ]
  [ "$(printf '%s' "$output" | jq -r '.approvals[0].resource')" = "src/app.ts" ]
  [ "$(printf '%s' "$output" | jq -r '.approvals[0].effect')" = "write" ]
  [ "$(printf '%s' "$output" | jq -r '.approvals[0].revoked')" = "true" ]
  [ "$(printf '%s' "$output" | jq -r '.approvals[0].revokedAt')" = "2026-08-13T00:00:00Z" ]
}

@test "actions cli approvals revoke requires exact scope flags" {
  grant_project_allow_always >/dev/null
  run approvals_cmd revoke
  [ "$status" -ne 0 ]
  printf '%s\n' "$output" | grep -q -- '--runtime'
  printf '%s\n' "$output" | grep -q -- '--action'
  printf '%s\n' "$output" | grep -q -- '--resource'
  printf '%s\n' "$output" | grep -q -- '--effect'
  [ "$(graph_approval_project_rule_list "$(graph_state_state_root "$WORKSPACE")" "$WORKSPACE" | jq -r '.[0].revokedAt')" = "null" ]
}

@test "actions cli approvals revoke marks the exact rule and prints revocation state" {
  grant_project_allow_always >/dev/null
  grant_project_allow_always req-002 cursor Read docs/GRAPH.md read >/dev/null
  run approvals_cmd revoke --runtime cursor --action Bash --resource src/app.ts --effect write
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -q 'runtime=cursor'
  printf '%s\n' "$output" | grep -q 'action=Bash'
  printf '%s\n' "$output" | grep -q 'resource=src/app.ts'
  printf '%s\n' "$output" | grep -q 'effect=write'
  printf '%s\n' "$output" | grep -q 'revoked=yes'
  printf '%s\n' "$output" | grep -q 'revokedAt=2026-08-13T00:00:00Z'
  run approvals_cmd list --json
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '[.approvals[] | select(.resource=="src/app.ts")][0].revoked')" = "true" ]
  [ "$(printf '%s' "$output" | jq -r '[.approvals[] | select(.resource=="docs/GRAPH.md")][0].revoked')" = "false" ]
}

@test "actions cli approvals revoke --json prints normalized scope and revokedAt" {
  local rule_id
  grant_project_allow_always >/dev/null
  rule_id="$(graph_approval_rule_id cursor Bash src/app.ts write)"
  run approvals_cmd revoke --runtime cursor --action Bash --resource src/app.ts --effect write --json
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '.ruleId')" = "$rule_id" ]
  [ "$(printf '%s' "$output" | jq -r '.runtime')" = "cursor" ]
  [ "$(printf '%s' "$output" | jq -r '.action')" = "Bash" ]
  [ "$(printf '%s' "$output" | jq -r '.resource')" = "src/app.ts" ]
  [ "$(printf '%s' "$output" | jq -r '.effect')" = "write" ]
  [ "$(printf '%s' "$output" | jq -r '.revoked')" = "true" ]
  [ "$(printf '%s' "$output" | jq -r '.revokedAt')" = "2026-08-13T00:00:00Z" ]
  [[ "$(printf '%s' "$output" | jq -r '.path')" == */operator-policy/approvals.json ]]
}

@test "actions cli approvals revoke normalizes scope before matching" {
  grant_project_allow_always >/dev/null
  run approvals_cmd revoke --runtime Cursor --action Bash --resource './src//app.ts' --effect WRITE --json
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '.runtime')" = "cursor" ]
  [ "$(printf '%s' "$output" | jq -r '.action')" = "Bash" ]
  [ "$(printf '%s' "$output" | jq -r '.resource')" = "src/app.ts" ]
  [ "$(printf '%s' "$output" | jq -r '.effect')" = "write" ]
  [ "$(printf '%s' "$output" | jq -r '.revoked')" = "true" ]
  [ "$(printf '%s' "$output" | jq -r '.revokedAt')" = "2026-08-13T00:00:00Z" ]
}

@test "actions cli approvals revoke is idempotent" {
  grant_project_allow_always >/dev/null
  run approvals_cmd revoke --runtime cursor --action Bash --resource src/app.ts --effect write --json
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '.revokedAt')" = "2026-08-13T00:00:00Z" ]
  run approvals_cmd revoke --runtime cursor --action Bash --resource src/app.ts --effect write --json
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '.revokedAt')" = "2026-08-13T00:00:00Z" ]
  [ "$(graph_approval_project_rule_list "$(graph_state_state_root "$WORKSPACE")" "$WORKSPACE" | jq -r '.[0].revokedAt')" = "2026-08-13T00:00:00Z" ]
}

@test "actions cli approvals revoke rejects an unknown exact scope" {
  grant_project_allow_always >/dev/null
  run approvals_cmd revoke --runtime cursor --action Edit --resource src/app.ts --effect write
  [ "$status" -ne 0 ]
  printf '%s\n' "$output" | grep -q 'not found'
  [ "$(graph_approval_project_rule_list "$(graph_state_state_root "$WORKSPACE")" "$WORKSPACE" | jq -r '.[0].revokedAt')" = "null" ]
}

@test "actions cli approvals list and revoke never edit runtime-global configuration" {
  local store_path
  seed_runtime_global_homes
  grant_project_allow_always >/dev/null
  store_path="$(graph_approval_project_policy_path "$(graph_state_state_root "$WORKSPACE")")"
  run approvals_cmd list --json
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '.approvals[0].resource')" = "src/app.ts" ]
  [ "$(printf '%s' "$output" | jq -r '.path')" = "$store_path" ]
  assert_runtime_global_untouched
  run approvals_cmd revoke --runtime cursor --action Bash --resource src/app.ts --effect write --json
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '.revoked')" = "true" ]
  [ "$(printf '%s' "$output" | jq -r '.path')" = "$store_path" ]
  assert_runtime_global_untouched
  [ -f "$store_path" ]
  [[ "$store_path" == */operator-policy/approvals.json ]]
}

@test "actions cli approvals rejects an unknown option" {
  run approvals_cmd list --bogus
  [ "$status" -ne 0 ]
  printf '%s\n' "$output" | grep -q 'unknown option'
  run approvals_cmd revoke --runtime cursor --action Bash --resource src/app.ts --effect write --bogus
  [ "$status" -ne 0 ]
  printf '%s\n' "$output" | grep -q 'unknown option'
}
