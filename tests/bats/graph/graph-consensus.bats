#!/usr/bin/env bats

source "$BATS_TEST_DIRNAME/../helper/load-lib.bash"
source "$BATS_TEST_DIRNAME/../../../bundle/.ralph/bash-lib/plan-todo.sh"
export RALPH_RUN_PLAN_LIBRARY_ONLY=1
source "$BATS_TEST_DIRNAME/../../../bundle/.ralph/bash-lib/run-plan/run-plan-core.sh"
unset RALPH_RUN_PLAN_LIBRARY_ONLY
source "$BATS_TEST_DIRNAME/../../../bundle/.ralph/bash-lib/graph/graph-consensus.sh"

RALPH_DIR="$REPO_ROOT/bundle/.ralph"
STUB_RUN_PLAN="$BATS_TEST_DIRNAME/../../fixtures/orchestrator-single-stage/run-plan-stub.sh"

# Set up a scratch workspace with stubbed run-plan for adjudicator dispatch tests.
# Sets DISPATCH_WORKSPACE and exports env vars (do not invoke via command substitution).
setup_dispatch_workspace_for_consensus() {
  local tmpd="$1"
  DISPATCH_WORKSPACE="$tmpd/workspace"
  mkdir -p "$DISPATCH_WORKSPACE/.ralph" "$DISPATCH_WORKSPACE/.ralph-workspace"
  cp -R "$RALPH_DIR"/* "$DISPATCH_WORKSPACE/.ralph/"
  chmod +x "$DISPATCH_WORKSPACE/.ralph"/*.sh 2>/dev/null || true
  chmod +x "$DISPATCH_WORKSPACE/.ralph/bash-lib"/*/*.sh 2>/dev/null || true
  cp "$STUB_RUN_PLAN" "$DISPATCH_WORKSPACE/.ralph/run-plan.sh"
  chmod +x "$DISPATCH_WORKSPACE/.ralph/run-plan.sh"
  export GRAPH_DISPATCH_ORCHESTRATOR="$DISPATCH_WORKSPACE/.ralph/orchestrator.sh"
  export RALPH_ALLOW_NESTED_RUNS=1
  export ORCHESTRATOR_RUNNER_TO_CONSOLE=0
  export RALPH_MODE=no
  export RALPH_ARTIFACT_SCHEMA_VALIDATION=0
  export RALPH_ARTIFACT_PROVENANCE=0
  unset RALPH_ARTIFACT_NS 2>/dev/null || true
  unset RALPH_PLAN_KEY 2>/dev/null || true
}

VALIDATE_CONSENSUS_RESULT_SH="$BATS_TEST_DIRNAME/../../../scripts/validate-consensus-result.sh"

json_field() {
  printf '%s' "$1" | jq -r "$2"
}

json_payload() {
  printf '%s\n' "$1" | awk 'END{print}'
}

# --- expansion ---

@test "three-voter consensus node expands into exactly three synthetic voter stages with distinct runtimes" {
  tmpd="$(mktemp -d)"
  plan_file="$tmpd/graph-consensus.plan.md"
  cp "$BATS_TEST_DIRNAME/../../fixtures/graph/graph-consensus.plan.md" "$plan_file"

  run plan_pipeline_graph_json "$plan_file"
  [ "$status" -eq 0 ]
  payload="$(json_payload "$output")"

  voter_count="$(json_field "$payload" '.nodes | map(select(.type=="consensus-voter")) | length')"
  [ "$voter_count" = "3" ]

  runtimes="$(json_field "$payload" '.nodes | map(select(.type=="consensus-voter")) | map(.stage.runtime) | sort | join(",")')"
  [ "$runtimes" = "claude,codex,cursor" ]

  rm -rf "$tmpd"
}

@test "VOTER_ID token is substituted with the actual voter id in each voter stage outputArtifacts at compile time" {
  tmpd="$(mktemp -d)"
  plan_file="$tmpd/graph-consensus-voter-id.plan.md"
  cp "$BATS_TEST_DIRNAME/../../fixtures/graph/graph-consensus-voter-id.plan.md" "$plan_file"

  run plan_pipeline_graph_json "$plan_file"
  [ "$status" -eq 0 ]
  payload="$(json_payload "$output")"

  voter_count="$(json_field "$payload" '.nodes | map(select(.type=="consensus-voter")) | length')"
  [ "$voter_count" = "3" ]

  # No voter stage must carry the raw VOTER_ID token after compilation.
  paths_with_token="$(json_field "$payload" '.nodes | map(select(.type=="consensus-voter")) | map(.stage.outputArtifacts[]?.path | select(contains("{{VOTER_ID}}"))) | length')"
  [ "$paths_with_token" = "0" ]

  # Each voter must have its own distinct fully-substituted path.
  alpha_path="$(json_field "$payload" '.nodes[] | select(.id=="review:alpha") | .stage.outputArtifacts[0].path')"
  [ "$alpha_path" = "reviews/alpha/verdict.json" ]

  beta_path="$(json_field "$payload" '.nodes[] | select(.id=="review:beta") | .stage.outputArtifacts[0].path')"
  [ "$beta_path" = "reviews/beta/verdict.json" ]

  gamma_path="$(json_field "$payload" '.nodes[] | select(.id=="review:gamma") | .stage.outputArtifacts[0].path')"
  [ "$gamma_path" = "reviews/gamma/verdict.json" ]

  rm -rf "$tmpd"
}

@test "todo content authored against consensus stage id appears in every voter and barrier _inlineTodos" {
  tmpd="$(mktemp -d)"
  cat >"$tmpd/consensus-todos.plan.md" <<'EOF'
---
execution: graph
pipeline:
  stages:
    - id: review
      type: consensus
      voters:
        - id: alpha
          runtime: cursor
          agent: code-review
        - id: beta
          runtime: codex
          agent: code-review
todos:
  - id: review-1
    stage: review
    content: perform the actual review task
    status: pending
---
EOF

  run plan_pipeline_graph_json "$tmpd/consensus-todos.plan.md"
  [ "$status" -eq 0 ]
  payload="$(json_payload "$output")"

  # Every voter must have _inlineTodos populated from the parent consensus stage.
  alpha_todos="$(json_field "$payload" '.nodes[] | select(.id=="review:alpha") | .stage._inlineTodos | length')"
  [ "$alpha_todos" = "1" ]

  alpha_content="$(json_field "$payload" '.nodes[] | select(.id=="review:alpha") | .stage._inlineTodos[0].content')"
  [ "$alpha_content" = "perform the actual review task" ]

  beta_todos="$(json_field "$payload" '.nodes[] | select(.id=="review:beta") | .stage._inlineTodos | length')"
  [ "$beta_todos" = "1" ]

  # The barrier must also inherit the consensus stage todos.
  barrier_todos="$(json_field "$payload" '.nodes[] | select(.id=="review:barrier") | .stage._inlineTodos | length')"
  [ "$barrier_todos" = "1" ]

  barrier_content="$(json_field "$payload" '.nodes[] | select(.id=="review:barrier") | .stage._inlineTodos[0].content')"
  [ "$barrier_content" = "perform the actual review task" ]

  rm -rf "$tmpd"
}

# --- forced sessionStrategy ---

@test "sessionStrategy is forced to fresh on every voter even when the plan declares otherwise" {
  tmpd="$(mktemp -d)"
  cat >"$tmpd/override.plan.md" <<'EOF'
---
execution: graph
pipeline:
  stages:
    - id: review
      type: consensus
      sessionStrategy: resume
      voters:
        - id: alpha
          runtime: cursor
          agent: code-review
          sessionStrategy: reset
        - id: beta
          runtime: codex
          agent: code-review
todos:
  - id: review-1
    stage: review
    content: review
    status: pending
---
EOF

  run plan_pipeline_graph_json "$tmpd/override.plan.md"
  [ "$status" -eq 0 ]
  payload="$(json_payload "$output")"

  # All voter stages must have sessionStrategy=fresh regardless of what the
  # plan declared at stage or voter level.
  strats="$(json_field "$payload" '.nodes | map(select(.type=="consensus-voter")) | map(.stage.sessionStrategy) | unique | join(",")')"
  [ "$strats" = "fresh" ]

  rm -rf "$tmpd"
}

# --- forced subagents=off ---

@test "emitted voter stage carries resolved subagents off when voter omits the field" {
  tmpd="$(mktemp -d)"
  plan_file="$tmpd/graph-consensus.plan.md"
  cp "$BATS_TEST_DIRNAME/../../fixtures/graph/graph-consensus.plan.md" "$plan_file"

  run plan_pipeline_graph_json "$plan_file"
  [ "$status" -eq 0 ]
  payload="$(json_payload "$output")"

  subagents_vals="$(json_field "$payload" '.nodes | map(select(.type=="consensus-voter")) | map(.stage.subagents) | unique | join(",")')"
  [ "$subagents_vals" = "off" ]

  rm -rf "$tmpd"
}

# --- compile-time rejections ---

@test "single-voter consensus node is rejected at compile time" {
  tmpd="$(mktemp -d)"
  plan_file="$tmpd/graph-consensus-single-voter.plan.md"
  cp "$BATS_TEST_DIRNAME/../../fixtures/graph/graph-consensus-single-voter.plan.md" "$plan_file"

  run plan_pipeline_graph_json "$plan_file"
  [ "$status" -ne 0 ]
  [[ "$output" == *"at least two voters"* ]]

  rm -rf "$tmpd"
}

@test "consensus node with duplicate voter ids is rejected at compile time" {
  tmpd="$(mktemp -d)"
  plan_file="$tmpd/graph-consensus-duplicate-voter-ids.plan.md"
  cp "$BATS_TEST_DIRNAME/../../fixtures/graph/graph-consensus-duplicate-voter-ids.plan.md" "$plan_file"

  run plan_pipeline_graph_json "$plan_file"
  [ "$status" -ne 0 ]
  [[ "$output" == *"duplicate voter id"* ]]

  rm -rf "$tmpd"
}

@test "voter declaring subagents on is rejected with voter id and reason in the message" {
  tmpd="$(mktemp -d)"
  plan_file="$tmpd/graph-consensus-voter-subagents-on.plan.md"
  cp "$BATS_TEST_DIRNAME/../../fixtures/graph/graph-consensus-voter-subagents-on.plan.md" "$plan_file"

  run plan_pipeline_graph_json "$plan_file"
  [ "$status" -ne 0 ]
  # Message must name the voter id.
  [[ "$output" == *"alpha"* ]]
  # Message must state the reason (provenance / recorded).
  [[ "$output" == *"provenance"* ]]

  rm -rf "$tmpd"
}

@test "voter declaring subagents off compiles without error" {
  tmpd="$(mktemp -d)"
  plan_file="$tmpd/graph-consensus-voter-subagents-off.plan.md"
  cp "$BATS_TEST_DIRNAME/../../fixtures/graph/graph-consensus-voter-subagents-off.plan.md" "$plan_file"

  run plan_pipeline_graph_json "$plan_file"
  [ "$status" -eq 0 ]

  rm -rf "$tmpd"
}

@test "voter omitting subagents field compiles without error" {
  tmpd="$(mktemp -d)"
  plan_file="$tmpd/graph-consensus.plan.md"
  cp "$BATS_TEST_DIRNAME/../../fixtures/graph/graph-consensus.plan.md" "$plan_file"

  run plan_pipeline_graph_json "$plan_file"
  [ "$status" -eq 0 ]

  rm -rf "$tmpd"
}

# --- join/adjudicator not covered by voter restriction ---

@test "join node declaring subagents on is accepted (voter restriction does not apply)" {
  tmpd="$(mktemp -d)"
  plan_file="$tmpd/graph-consensus-join-subagents-on.plan.md"
  cp "$BATS_TEST_DIRNAME/../../fixtures/graph/graph-consensus-join-subagents-on.plan.md" "$plan_file"

  run plan_pipeline_graph_json "$plan_file"
  [ "$status" -eq 0 ]

  rm -rf "$tmpd"
}

# --- consensus-result schema validation ---

@test "valid three-voter consensus result validates against schema" {
  tmpd="$(mktemp -d)"
  cat >"$tmpd/valid.json" <<'EOF'
{
  "schemaVersion": 1,
  "nodeId": "review",
  "policy": "veto",
  "decision": "approved",
  "voters": [
    {"voterId": "review:alpha", "runtime": "cursor", "status": "approved", "confidence": 0.9},
    {"voterId": "review:beta",  "runtime": "claude", "status": "approved", "agent": "code-review", "model": "claude-haiku"},
    {"voterId": "review:gamma", "runtime": "codex",  "status": "approved", "artifact": "review.json", "feedback": "LGTM"}
  ],
  "agreement": 1.0
}
EOF
  run bash "$VALIDATE_CONSENSUS_RESULT_SH" "$tmpd/valid.json"
  [ "$status" -eq 0 ]
  rm -rf "$tmpd"
}

@test "consensus result missing schemaVersion is rejected" {
  tmpd="$(mktemp -d)"
  cat >"$tmpd/no-version.json" <<'EOF'
{
  "nodeId": "review",
  "policy": "veto",
  "decision": "approved",
  "voters": [{"voterId": "review:alpha", "runtime": "cursor", "status": "approved"}]
}
EOF
  run bash "$VALIDATE_CONSENSUS_RESULT_SH" "$tmpd/no-version.json"
  [ "$status" -ne 0 ]
  [[ "$output" == *"schemaVersion"* ]]
  rm -rf "$tmpd"
}

@test "consensus result missing nodeId is rejected" {
  tmpd="$(mktemp -d)"
  cat >"$tmpd/no-nodeid.json" <<'EOF'
{
  "schemaVersion": 1,
  "policy": "veto",
  "decision": "approved",
  "voters": [{"voterId": "review:alpha", "runtime": "cursor", "status": "approved"}]
}
EOF
  run bash "$VALIDATE_CONSENSUS_RESULT_SH" "$tmpd/no-nodeid.json"
  [ "$status" -ne 0 ]
  [[ "$output" == *"nodeId"* ]]
  rm -rf "$tmpd"
}

@test "consensus result missing policy is rejected" {
  tmpd="$(mktemp -d)"
  cat >"$tmpd/no-policy.json" <<'EOF'
{
  "schemaVersion": 1,
  "nodeId": "review",
  "decision": "approved",
  "voters": [{"voterId": "review:alpha", "runtime": "cursor", "status": "approved"}]
}
EOF
  run bash "$VALIDATE_CONSENSUS_RESULT_SH" "$tmpd/no-policy.json"
  [ "$status" -ne 0 ]
  [[ "$output" == *"policy"* ]]
  rm -rf "$tmpd"
}

@test "consensus result missing decision is rejected" {
  tmpd="$(mktemp -d)"
  cat >"$tmpd/no-decision.json" <<'EOF'
{
  "schemaVersion": 1,
  "nodeId": "review",
  "policy": "veto",
  "voters": [{"voterId": "review:alpha", "runtime": "cursor", "status": "approved"}]
}
EOF
  run bash "$VALIDATE_CONSENSUS_RESULT_SH" "$tmpd/no-decision.json"
  [ "$status" -ne 0 ]
  [[ "$output" == *"decision"* ]]
  rm -rf "$tmpd"
}

@test "consensus result missing voters is rejected" {
  tmpd="$(mktemp -d)"
  cat >"$tmpd/no-voters.json" <<'EOF'
{
  "schemaVersion": 1,
  "nodeId": "review",
  "policy": "veto",
  "decision": "approved"
}
EOF
  run bash "$VALIDATE_CONSENSUS_RESULT_SH" "$tmpd/no-voters.json"
  [ "$status" -ne 0 ]
  [[ "$output" == *"voters"* ]]
  rm -rf "$tmpd"
}

@test "consensus result with out-of-range confidence is rejected" {
  tmpd="$(mktemp -d)"
  cat >"$tmpd/bad-confidence.json" <<'EOF'
{
  "schemaVersion": 1,
  "nodeId": "review",
  "policy": "veto",
  "decision": "approved",
  "voters": [{"voterId": "review:alpha", "runtime": "cursor", "status": "approved", "confidence": 1.5}]
}
EOF
  run bash "$VALIDATE_CONSENSUS_RESULT_SH" "$tmpd/bad-confidence.json"
  [ "$status" -ne 0 ]
  [[ "$output" == *"confidence"* ]]
  rm -rf "$tmpd"
}

@test "consensus result with invalid decision enum value is rejected" {
  tmpd="$(mktemp -d)"
  cat >"$tmpd/bad-decision.json" <<'EOF'
{
  "schemaVersion": 1,
  "nodeId": "review",
  "policy": "veto",
  "decision": "rejected",
  "voters": [{"voterId": "review:alpha", "runtime": "cursor", "status": "approved"}]
}
EOF
  run bash "$VALIDATE_CONSENSUS_RESULT_SH" "$tmpd/bad-decision.json"
  [ "$status" -ne 0 ]
  [[ "$output" == *"decision"* ]]
  rm -rf "$tmpd"
}

@test "consensus result with invalid voter status enum value is rejected" {
  tmpd="$(mktemp -d)"
  cat >"$tmpd/bad-voter-status.json" <<'EOF'
{
  "schemaVersion": 1,
  "nodeId": "review",
  "policy": "veto",
  "decision": "approved",
  "voters": [{"voterId": "review:alpha", "runtime": "cursor", "status": "passed"}]
}
EOF
  run bash "$VALIDATE_CONSENSUS_RESULT_SH" "$tmpd/bad-voter-status.json"
  [ "$status" -ne 0 ]
  [[ "$output" == *"status"* ]]
  rm -rf "$tmpd"
}

# Helpers shared by the join aggregation tests below.
_make_voter_artifact() {
  local path="$1" status="$2"
  mkdir -p "$(dirname "$path")"
  printf '<!-- REVIEW_STATUS: START -->\nstatus: %s\n<!-- REVIEW_STATUS: END -->\n' \
    "$status" > "$path"
}

# _voters_json <tmpd> <spec>...
# Each spec is a pipe-separated triple:  "<voterId>|<runtime>|<status>"
# voterId may contain colons (e.g. "review:alpha"), so pipe is the separator.
_voters_json() {
  local tmpd="$1"; shift
  local result="["
  local sep=""
  while [[ $# -gt 0 ]]; do
    local spec="$1"; shift
    local vid rt st safe_name artifact
    # Split on the first two pipe characters.
    vid="${spec%%|*}"
    local rest="${spec#*|}"
    rt="${rest%%|*}"
    st="${rest#*|}"
    safe_name="$(printf '%s' "$vid" | sed 's/[^A-Za-z0-9._-]/_/g')"
    artifact="$tmpd/artifacts/${safe_name}.md"
    _make_voter_artifact "$artifact" "$st"
    result="${result}${sep}{\"voterId\":\"${vid}\",\"runtime\":\"${rt}\",\"artifact\":\"${artifact}\"}"
    sep=","
  done
  result="${result}]"
  printf '%s' "$result"
}

# --- join: veto policy ---

@test "veto policy: three approvals pass (decision=approved, ledger=succeeded)" {
  tmpd="$(mktemp -d)"
  workspace="$tmpd/ws"
  namespace="test-ns"
  run_id="run-1"
  node_id="review-join"

  vj="$(_voters_json "$tmpd" "review:alpha|cursor|approved" "review:beta|claude|approved" "review:gamma|codex|approved")"

  run graph_consensus_run_join "$workspace" "$namespace" "$run_id" "$node_id" "veto" "$vj"
  [ "$status" -eq 0 ]

  result_path="$(graph_consensus_result_path "$workspace" "$namespace" "$node_id")"
  [ -f "$result_path" ]
  decision="$(jq -r '.decision' "$result_path")"
  [ "$decision" = "approved" ]

  run bash "$VALIDATE_CONSENSUS_RESULT_SH" "$result_path"
  [ "$status" -eq 0 ]

  ledger_status="$(graph_state_node_status "$workspace" "$namespace" "$run_id" "$node_id")"
  [ "$ledger_status" = "succeeded" ]

  rm -rf "$tmpd"
}

@test "veto policy: one changes-required among three approvals blocks (decision=changes-required, ledger=failed)" {
  tmpd="$(mktemp -d)"
  workspace="$tmpd/ws"
  namespace="test-ns"
  run_id="run-1"
  node_id="review-join"

  vj="$(_voters_json "$tmpd" "review:alpha|cursor|approved" "review:beta|claude|changes-required" "review:gamma|codex|approved")"

  run graph_consensus_run_join "$workspace" "$namespace" "$run_id" "$node_id" "veto" "$vj"
  [ "$status" -ne 0 ]

  result_path="$(graph_consensus_result_path "$workspace" "$namespace" "$node_id")"
  [ -f "$result_path" ]
  decision="$(jq -r '.decision' "$result_path")"
  [ "$decision" = "changes-required" ]

  run bash "$VALIDATE_CONSENSUS_RESULT_SH" "$result_path"
  [ "$status" -eq 0 ]

  ledger_status="$(graph_state_node_status "$workspace" "$namespace" "$run_id" "$node_id")"
  [ "$ledger_status" = "failed" ]

  rm -rf "$tmpd"
}

@test "veto policy: dissent array names the blocking voter" {
  tmpd="$(mktemp -d)"
  workspace="$tmpd/ws"
  namespace="test-ns"
  run_id="run-1"
  node_id="review-join"

  vj="$(_voters_json "$tmpd" "review:alpha|cursor|approved" "review:beta|claude|changes-required" "review:gamma|codex|approved")"

  run graph_consensus_run_join "$workspace" "$namespace" "$run_id" "$node_id" "veto" "$vj"
  [ "$status" -ne 0 ]

  result_path="$(graph_consensus_result_path "$workspace" "$namespace" "$node_id")"
  dissent="$(jq -r '.dissent[]?' "$result_path")"
  [[ "$dissent" == *"review:beta"* ]]

  rm -rf "$tmpd"
}

# --- join: unanimous policy ---

@test "unanimous policy: all approve passes (decision=approved, ledger=succeeded)" {
  tmpd="$(mktemp -d)"
  workspace="$tmpd/ws"
  namespace="test-ns"
  run_id="run-1"
  node_id="review-join"

  vj="$(_voters_json "$tmpd" "review:alpha|cursor|approved" "review:beta|claude|approved")"

  run graph_consensus_run_join "$workspace" "$namespace" "$run_id" "$node_id" "unanimous" "$vj"
  [ "$status" -eq 0 ]

  result_path="$(graph_consensus_result_path "$workspace" "$namespace" "$node_id")"
  [ -f "$result_path" ]
  decision="$(jq -r '.decision' "$result_path")"
  [ "$decision" = "approved" ]

  run bash "$VALIDATE_CONSENSUS_RESULT_SH" "$result_path"
  [ "$status" -eq 0 ]

  ledger_status="$(graph_state_node_status "$workspace" "$namespace" "$run_id" "$node_id")"
  [ "$ledger_status" = "succeeded" ]

  rm -rf "$tmpd"
}

@test "unanimous policy: any dissent yields escalate (decision=escalate, ledger=failed)" {
  tmpd="$(mktemp -d)"
  workspace="$tmpd/ws"
  namespace="test-ns"
  run_id="run-1"
  node_id="review-join"

  vj="$(_voters_json "$tmpd" "review:alpha|cursor|approved" "review:beta|claude|changes-required" "review:gamma|codex|approved")"

  run graph_consensus_run_join "$workspace" "$namespace" "$run_id" "$node_id" "unanimous" "$vj"
  [ "$status" -ne 0 ]

  result_path="$(graph_consensus_result_path "$workspace" "$namespace" "$node_id")"
  [ -f "$result_path" ]
  decision="$(jq -r '.decision' "$result_path")"
  [ "$decision" = "escalate" ]

  run bash "$VALIDATE_CONSENSUS_RESULT_SH" "$result_path"
  [ "$status" -eq 0 ]

  ledger_status="$(graph_state_node_status "$workspace" "$namespace" "$run_id" "$node_id")"
  [ "$ledger_status" = "failed" ]

  rm -rf "$tmpd"
}

@test "unanimous policy: single dissent among three escalates (not changes-required)" {
  tmpd="$(mktemp -d)"
  workspace="$tmpd/ws"
  namespace="test-ns"
  run_id="run-1"
  node_id="review-join"

  vj="$(_voters_json "$tmpd" "review:alpha|cursor|changes-required" "review:beta|claude|approved" "review:gamma|codex|approved")"

  run graph_consensus_run_join "$workspace" "$namespace" "$run_id" "$node_id" "unanimous" "$vj"
  [ "$status" -ne 0 ]

  result_path="$(graph_consensus_result_path "$workspace" "$namespace" "$node_id")"
  decision="$(jq -r '.decision' "$result_path")"
  [ "$decision" = "escalate" ]

  rm -rf "$tmpd"
}

# --- schema validation across all cases ---

@test "consensus result written by veto pass validates against consensus-result.schema.json" {
  tmpd="$(mktemp -d)"
  workspace="$tmpd/ws"

  vj="$(_voters_json "$tmpd" "r-alpha|cursor|approved" "r-beta|claude|approved")"
  graph_consensus_run_join "$workspace" "ns" "rid" "join" "veto" "$vj"

  result_path="$(graph_consensus_result_path "$workspace" "ns" "join")"
  run bash "$VALIDATE_CONSENSUS_RESULT_SH" "$result_path"
  [ "$status" -eq 0 ]

  rm -rf "$tmpd"
}

@test "consensus result written by veto block validates against consensus-result.schema.json" {
  tmpd="$(mktemp -d)"
  workspace="$tmpd/ws"

  vj="$(_voters_json "$tmpd" "r-alpha|cursor|changes-required" "r-beta|claude|approved")"
  graph_consensus_run_join "$workspace" "ns" "rid" "join" "veto" "$vj" || true

  result_path="$(graph_consensus_result_path "$workspace" "ns" "join")"
  run bash "$VALIDATE_CONSENSUS_RESULT_SH" "$result_path"
  [ "$status" -eq 0 ]

  rm -rf "$tmpd"
}

@test "consensus result written by unanimous pass validates against consensus-result.schema.json" {
  tmpd="$(mktemp -d)"
  workspace="$tmpd/ws"

  vj="$(_voters_json "$tmpd" "r-alpha|cursor|approved" "r-beta|claude|approved")"
  graph_consensus_run_join "$workspace" "ns" "rid" "join" "unanimous" "$vj"

  result_path="$(graph_consensus_result_path "$workspace" "ns" "join")"
  run bash "$VALIDATE_CONSENSUS_RESULT_SH" "$result_path"
  [ "$status" -eq 0 ]

  rm -rf "$tmpd"
}

@test "consensus result written by unanimous escalate validates against consensus-result.schema.json" {
  tmpd="$(mktemp -d)"
  workspace="$tmpd/ws"

  vj="$(_voters_json "$tmpd" "r-alpha|cursor|approved" "r-beta|claude|changes-required")"
  graph_consensus_run_join "$workspace" "ns" "rid" "join" "unanimous" "$vj" || true

  result_path="$(graph_consensus_result_path "$workspace" "ns" "join")"
  run bash "$VALIDATE_CONSENSUS_RESULT_SH" "$result_path"
  [ "$status" -eq 0 ]

  rm -rf "$tmpd"
}

# --- ledger state in all cases ---

@test "join ledger entry reflects succeeded for veto-approved outcome" {
  tmpd="$(mktemp -d)"
  workspace="$tmpd/ws"

  vj="$(_voters_json "$tmpd" "r-alpha|cursor|approved" "r-beta|claude|approved")"
  graph_consensus_run_join "$workspace" "ns" "rid" "join" "veto" "$vj"

  node_state="$(graph_state_node_status "$workspace" "ns" "rid" "join")"
  [ "$node_state" = "succeeded" ]

  rm -rf "$tmpd"
}

@test "join ledger entry reflects failed for veto-blocked outcome" {
  tmpd="$(mktemp -d)"
  workspace="$tmpd/ws"

  vj="$(_voters_json "$tmpd" "r-alpha|cursor|changes-required" "r-beta|claude|approved")"
  graph_consensus_run_join "$workspace" "ns" "rid" "join" "veto" "$vj" || true

  node_state="$(graph_state_node_status "$workspace" "ns" "rid" "join")"
  [ "$node_state" = "failed" ]

  rm -rf "$tmpd"
}

@test "join ledger entry reflects failed for unanimous-escalate outcome" {
  tmpd="$(mktemp -d)"
  workspace="$tmpd/ws"

  vj="$(_voters_json "$tmpd" "r-alpha|cursor|changes-required" "r-beta|claude|approved")"
  graph_consensus_run_join "$workspace" "ns" "rid" "join" "unanimous" "$vj" || true

  node_state="$(graph_state_node_status "$workspace" "ns" "rid" "join")"
  [ "$node_state" = "failed" ]

  rm -rf "$tmpd"
}

# --- adjudicate policy ---

@test "adjudicate policy: unanimity short-circuits without dispatching (decision=approved)" {
  tmpd="$(mktemp -d)"
  workspace="$tmpd/ws"
  namespace="test-ns"
  run_id="run-1"
  node_id="review-join"

  vj="$(_voters_json "$tmpd" "r-alpha|cursor|approved" "r-beta|claude|approved")"

  # No GRAPH_DISPATCH_ORCHESTRATOR set: any dispatch attempt would fail
  # because there is no orchestrator to invoke.
  unset GRAPH_DISPATCH_ORCHESTRATOR 2>/dev/null || true

  run graph_consensus_run_join "$workspace" "$namespace" "$run_id" "$node_id" "adjudicate" "$vj"
  [ "$status" -eq 0 ]

  result_path="$(graph_consensus_result_path "$workspace" "$namespace" "$node_id")"
  [ -f "$result_path" ]
  decision="$(jq -r '.decision' "$result_path")"
  [ "$decision" = "approved" ]

  # No adjudicator artifact should exist (no dispatch happened).
  adj_artifact="$(graph_consensus_adjudicator_artifact_path "$workspace" "$namespace" "$node_id")"
  [ ! -f "$adj_artifact" ]

  ledger_status="$(graph_state_node_status "$workspace" "$namespace" "$run_id" "$node_id")"
  [ "$ledger_status" = "succeeded" ]

  rm -rf "$tmpd"
}

@test "adjudicate policy: on dissent dispatches adjudicator with full dissent packet" {
  tmpd="$(mktemp -d)"
  setup_dispatch_workspace_for_consensus "$tmpd"

  workspace="$DISPATCH_WORKSPACE"
  namespace="test-ns"
  run_id="run-1"
  node_id="review-join"

  vj="$(_voters_json "$tmpd" \
    "r-alpha|cursor|approved" \
    "r-beta|claude|changes-required" \
    "r-gamma|codex|approved")"

  # Pre-create the adjudicator verdict artifact with an approved verdict.
  # The stub run-plan does not invoke a real AI, so we pre-populate the
  # artifact that graph_consensus_run_join will read after dispatch.
  adj_artifact="$(graph_consensus_adjudicator_artifact_path "$workspace" "$namespace" "$node_id")"
  mkdir -p "$(dirname "$adj_artifact")"
  printf '<!-- REVIEW_STATUS: START -->\nstatus: approved\n<!-- REVIEW_STATUS: END -->\n' \
    > "$adj_artifact"

  export RUN_PLAN_STUB_EXIT_CODE=0
  export RALPH_RUN_PLAN_CAPTURE_FILE="$tmpd/adj-capture.json"
  unset RUN_PLAN_STUB_SLEEP_SECONDS RUN_PLAN_STUB_READY_FILE 2>/dev/null || true

  run graph_consensus_run_join "$workspace" "$namespace" "$run_id" "$node_id" "adjudicate" "$vj"
  [ "$status" -eq 0 ]

  # Capture file must exist: confirms the adjudicator was dispatched.
  [ -f "$RALPH_RUN_PLAN_CAPTURE_FILE" ]

  # The dissent packet JSON must have been written alongside the result.
  safe_id="$(printf '%s' "$node_id" | sed 's/[^A-Za-z0-9._-]/_/g')"
  packet_path="$(dirname "$adj_artifact")/${safe_id}-adjudicator-packet.json"
  [ -f "$packet_path" ]

  # Packet must contain the dissenting voter with full provenance.
  dissent_rt="$(jq -r '.dissentingVoters[0].runtime' "$packet_path")"
  [ "$dissent_rt" = "claude" ]

  # All three voters must appear in the packet.
  total_count="$(jq '.voters | length' "$packet_path")"
  [ "$total_count" = "3" ]

  rm -rf "$tmpd"
}

@test "adjudicate policy: adjudicator verdict determines final decision (changes-required)" {
  tmpd="$(mktemp -d)"
  setup_dispatch_workspace_for_consensus "$tmpd"

  workspace="$DISPATCH_WORKSPACE"
  namespace="test-ns"
  run_id="run-1"
  node_id="review-join"

  vj="$(_voters_json "$tmpd" \
    "r-alpha|cursor|approved" \
    "r-beta|claude|changes-required")"

  # Pre-populate adjudicator verdict with changes-required.
  adj_artifact="$(graph_consensus_adjudicator_artifact_path "$workspace" "$namespace" "$node_id")"
  mkdir -p "$(dirname "$adj_artifact")"
  printf '<!-- REVIEW_STATUS: START -->\nstatus: changes-required\n<!-- REVIEW_STATUS: END -->\n' \
    > "$adj_artifact"

  export RUN_PLAN_STUB_EXIT_CODE=0
  export RALPH_RUN_PLAN_CAPTURE_FILE="$tmpd/adj-capture2.json"
  unset RUN_PLAN_STUB_SLEEP_SECONDS RUN_PLAN_STUB_READY_FILE 2>/dev/null || true

  run graph_consensus_run_join "$workspace" "$namespace" "$run_id" "$node_id" "adjudicate" "$vj"
  [ "$status" -ne 0 ]

  result_path="$(graph_consensus_result_path "$workspace" "$namespace" "$node_id")"
  [ -f "$result_path" ]
  decision="$(jq -r '.decision' "$result_path")"
  [ "$decision" = "changes-required" ]

  ledger_status="$(graph_state_node_status "$workspace" "$namespace" "$run_id" "$node_id")"
  [ "$ledger_status" = "failed" ]

  rm -rf "$tmpd"
}

# --- quorum policy compile-time validation ---

@test "quorum without minRuntimes is rejected at compile time with correlated-error warning" {
  tmpd="$(mktemp -d)"
  cat >"$tmpd/quorum-no-minruntimes.plan.md" <<'EOF'
---
execution: graph
pipeline:
  stages:
    - id: review
      type: consensus
      policy: quorum
      quorum: 2
      voters:
        - id: alpha
          runtime: cursor
          agent: code-review
        - id: beta
          runtime: claude
          agent: code-review
        - id: gamma
          runtime: codex
          agent: code-review
todos:
  - id: review-1
    stage: review
    content: review
    status: pending
---
EOF

  run plan_pipeline_graph_json "$tmpd/quorum-no-minruntimes.plan.md"
  [ "$status" -ne 0 ]
  # The error must cite the missing minRuntimes requirement.
  [[ "$output" == *"minRuntimes"* ]]

  rm -rf "$tmpd"
}

@test "quorum with three same-runtime voters fails the distinct-provider requirement" {
  tmpd="$(mktemp -d)"
  cat >"$tmpd/quorum-same-runtime.plan.md" <<'EOF'
---
execution: graph
pipeline:
  stages:
    - id: review
      type: consensus
      policy: quorum
      quorum: 2
      minRuntimes: 2
      voters:
        - id: alpha
          runtime: claude
          agent: code-review
        - id: beta
          runtime: claude
          agent: code-review
        - id: gamma
          runtime: claude
          agent: code-review
todos:
  - id: review-1
    stage: review
    content: review
    status: pending
---
EOF

  run plan_pipeline_graph_json "$tmpd/quorum-same-runtime.plan.md"
  [ "$status" -ne 0 ]
  # Error must cite the distinct-provider failure.
  [[ "$output" == *"distinct runtime"* ]] || [[ "$output" == *"minRuntimes"* ]]

  rm -rf "$tmpd"
}

# --- helper for voter artifacts with confidence ---

# _make_voter_artifact_with_confidence <path> <status> <confidence>
# Like _make_voter_artifact but includes an optional confidence field.
_make_voter_artifact_with_confidence() {
  local path="$1" vstatus="$2" confidence="$3"
  mkdir -p "$(dirname "$path")"
  if [[ -n "$confidence" ]]; then
    printf '<!-- REVIEW_STATUS: START -->\nstatus: %s\nconfidence: %s\n<!-- REVIEW_STATUS: END -->\n' \
      "$vstatus" "$confidence" > "$path"
  else
    printf '<!-- REVIEW_STATUS: START -->\nstatus: %s\n<!-- REVIEW_STATUS: END -->\n' \
      "$vstatus" > "$path"
  fi
}

# _build_retry_graph_json <path> <voter_id> <runtime> <artifact>
# Writes a minimal .graph.json suitable for graph_dispatch_run_node to re-dispatch
# a single voter stage.  The stage uses _inlineTodos so no external plan file is needed.
# The stage must include an agent field because orchestrator_validate_stage_agent_plan
# requires both agent and plan to be non-empty.
_build_retry_graph_json() {
  local path="$1" voter_id="$2" runtime="$3" artifact="$4"
  mkdir -p "$(dirname "$path")"
  jq -n \
    --arg voter_id "$voter_id" \
    --arg runtime "$runtime" \
    --arg artifact "$artifact" \
    '{
      schemaVersion: 1,
      name: "retry-test",
      namespace: "test-ns",
      nodes: [{
        id: $voter_id,
        type: "consensus-voter",
        dependsOn: [],
        derivedFrom: [],
        stage: {
          id: $voter_id,
          runtime: $runtime,
          agent: "code-review",
          sessionStrategy: "fresh",
          subagents: "off",
          _inlineTodos: [{
            id: ($voter_id + "-task"),
            content: "Review the work and write your verdict.",
            verification: "Write a REVIEW_STATUS block.",
            status: "pending"
          }]
        }
      }],
      edges: []
    }' > "$path"
}

# --- onVoterError: fail (default) ---

@test "onVoterError default: voter with missing artifact is recorded status=error and join fails closed" {
  tmpd="$(mktemp -d)"
  workspace="$tmpd/ws"
  namespace="test-ns"
  run_id="run-1"
  node_id="review-join"

  local art_alpha="$tmpd/artifacts/alpha.md"
  local art_missing="$tmpd/artifacts/missing.md"
  _make_voter_artifact "$art_alpha" "approved"
  # art_missing is intentionally not created.

  local vj
  vj="$(printf '[{"voterId":"v-alpha","runtime":"cursor","artifact":"%s"},{"voterId":"v-beta","runtime":"claude","artifact":"%s"}]' \
    "$art_alpha" "$art_missing")"

  run graph_consensus_run_join "$workspace" "$namespace" "$run_id" "$node_id" "veto" "$vj"
  [ "$status" -ne 0 ]

  result_path="$(graph_consensus_result_path "$workspace" "$namespace" "$node_id")"
  [ -f "$result_path" ]

  # The errored voter must appear with status=error.
  error_voter_status="$(jq -r '.voters[] | select(.voterId == "v-beta") | .status' "$result_path")"
  [ "$error_voter_status" = "error" ]

  # The join fails closed (changes-required) regardless of the policy.
  decision="$(jq -r '.decision' "$result_path")"
  [ "$decision" = "changes-required" ]

  ledger_status="$(graph_state_node_status "$workspace" "$namespace" "$run_id" "$node_id")"
  [ "$ledger_status" = "failed" ]

  run bash "$VALIDATE_CONSENSUS_RESULT_SH" "$result_path"
  [ "$status" -eq 0 ]

  rm -rf "$tmpd"
}

@test "onVoterError fail: join fails closed even when all other voters approved" {
  tmpd="$(mktemp -d)"
  workspace="$tmpd/ws"
  namespace="test-ns"
  run_id="run-2"
  node_id="review-join"

  local art_alpha="$tmpd/artifacts/alpha.md"
  local art_beta="$tmpd/artifacts/beta.md"
  local art_missing="$tmpd/artifacts/missing.md"
  _make_voter_artifact "$art_alpha" "approved"
  _make_voter_artifact "$art_beta" "approved"

  local vj
  vj="$(printf '[{"voterId":"v-alpha","runtime":"cursor","artifact":"%s"},{"voterId":"v-beta","runtime":"claude","artifact":"%s"},{"voterId":"v-gamma","runtime":"codex","artifact":"%s"}]' \
    "$art_alpha" "$art_beta" "$art_missing")"

  run graph_consensus_run_join "$workspace" "$namespace" "$run_id" "$node_id" "veto" "$vj" '{"onVoterError":"fail"}'
  [ "$status" -ne 0 ]

  result_path="$(graph_consensus_result_path "$workspace" "$namespace" "$node_id")"
  decision="$(jq -r '.decision' "$result_path")"
  [ "$decision" = "changes-required" ]

  rm -rf "$tmpd"
}

# --- onVoterError: exclude ---

@test "onVoterError exclude: errored voter is dropped and remaining voters proceed under veto" {
  tmpd="$(mktemp -d)"
  workspace="$tmpd/ws"
  namespace="test-ns"
  run_id="run-1"
  node_id="review-join"

  local art_alpha="$tmpd/artifacts/alpha.md"
  local art_beta="$tmpd/artifacts/beta.md"
  local art_missing="$tmpd/artifacts/missing.md"
  _make_voter_artifact "$art_alpha" "approved"
  _make_voter_artifact "$art_beta" "approved"

  local vj
  vj="$(printf '[{"voterId":"v-alpha","runtime":"cursor","artifact":"%s"},{"voterId":"v-beta","runtime":"claude","artifact":"%s"},{"voterId":"v-gamma","runtime":"codex","artifact":"%s"}]' \
    "$art_alpha" "$art_beta" "$art_missing")"

  run graph_consensus_run_join "$workspace" "$namespace" "$run_id" "$node_id" "veto" "$vj" '{"onVoterError":"exclude"}'
  # Two remaining approved voters: veto passes.
  [ "$status" -eq 0 ]

  result_path="$(graph_consensus_result_path "$workspace" "$namespace" "$node_id")"
  [ -f "$result_path" ]
  decision="$(jq -r '.decision' "$result_path")"
  [ "$decision" = "approved" ]

  # The errored voter must still be recorded with status=error.
  error_voter_status="$(jq -r '.voters[] | select(.voterId == "v-gamma") | .status' "$result_path")"
  [ "$error_voter_status" = "error" ]

  run bash "$VALIDATE_CONSENSUS_RESULT_SH" "$result_path"
  [ "$status" -eq 0 ]

  rm -rf "$tmpd"
}

@test "onVoterError exclude: errored voter dropped, remaining dissent still blocks under veto" {
  tmpd="$(mktemp -d)"
  workspace="$tmpd/ws"
  namespace="test-ns"
  run_id="run-2"
  node_id="review-join"

  local art_alpha="$tmpd/artifacts/alpha.md"
  local art_beta="$tmpd/artifacts/beta.md"
  local art_missing="$tmpd/artifacts/missing.md"
  _make_voter_artifact "$art_alpha" "approved"
  _make_voter_artifact "$art_beta" "changes-required"

  local vj
  vj="$(printf '[{"voterId":"v-alpha","runtime":"cursor","artifact":"%s"},{"voterId":"v-beta","runtime":"claude","artifact":"%s"},{"voterId":"v-gamma","runtime":"codex","artifact":"%s"}]' \
    "$art_alpha" "$art_beta" "$art_missing")"

  run graph_consensus_run_join "$workspace" "$namespace" "$run_id" "$node_id" "veto" "$vj" '{"onVoterError":"exclude"}'
  # After excluding the errored voter: one approved, one changes-required -> veto blocks.
  [ "$status" -ne 0 ]

  result_path="$(graph_consensus_result_path "$workspace" "$namespace" "$node_id")"
  decision="$(jq -r '.decision' "$result_path")"
  [ "$decision" = "changes-required" ]

  rm -rf "$tmpd"
}

# --- onVoterError: retry ---

@test "onVoterError retry: re-dispatches voter exactly once and falls back to fail when still errored" {
  tmpd="$(mktemp -d)"
  setup_dispatch_workspace_for_consensus "$tmpd"

  workspace="$DISPATCH_WORKSPACE"
  namespace="test-ns"
  run_id="run-1"
  node_id="review-join"

  local art_alpha="$tmpd/artifacts/alpha.md"
  local art_missing="$tmpd/artifacts/beta-missing.md"
  _make_voter_artifact "$art_alpha" "approved"
  # art_missing is intentionally not created (stub won't create it either).

  local retry_graph_json="$tmpd/retry-voter.graph.json"
  _build_retry_graph_json "$retry_graph_json" "v-beta" "claude" "$art_missing"

  export RUN_PLAN_STUB_EXIT_CODE=0
  export RALPH_RUN_PLAN_CAPTURE_FILE="$tmpd/retry-capture.json"
  unset RUN_PLAN_STUB_SLEEP_SECONDS RUN_PLAN_STUB_READY_FILE 2>/dev/null || true

  local vj
  vj="$(printf '[{"voterId":"v-alpha","runtime":"cursor","artifact":"%s"},{"voterId":"v-beta","runtime":"claude","artifact":"%s","graphJsonPath":"%s"}]' \
    "$art_alpha" "$art_missing" "$retry_graph_json")"

  run graph_consensus_run_join "$workspace" "$namespace" "$run_id" "$node_id" "veto" "$vj" '{"onVoterError":"retry"}'
  # Stub does not create art_missing -> retry dispatch fails to produce artifact -> falls back to fail.
  [ "$status" -ne 0 ]

  # The retry dispatch must have happened: capture file confirms it.
  [ -f "$RALPH_RUN_PLAN_CAPTURE_FILE" ]

  result_path="$(graph_consensus_result_path "$workspace" "$namespace" "$node_id")"
  [ -f "$result_path" ]
  decision="$(jq -r '.decision' "$result_path")"
  [ "$decision" = "changes-required" ]

  error_voter_status="$(jq -r '.voters[] | select(.voterId == "v-beta") | .status' "$result_path")"
  [ "$error_voter_status" = "error" ]

  ledger_status="$(graph_state_node_status "$workspace" "$namespace" "$run_id" "$node_id")"
  [ "$ledger_status" = "failed" ]

  rm -rf "$tmpd"
}

@test "onVoterError retry: exactly one retry dispatch (no double retry)" {
  # Override graph_dispatch_run_node to count dispatch calls.  Calling without
  # run keeps the function override in scope of graph_consensus_run_join.
  tmpd="$(mktemp -d)"
  workspace="$tmpd/ws"
  namespace="test-ns"
  run_id="run-retry-count"
  node_id="review-join"

  local art_alpha="$tmpd/artifacts/alpha.md"
  local art_missing="$tmpd/artifacts/missing.md"
  _make_voter_artifact "$art_alpha" "approved"

  local retry_graph_json="$tmpd/retry.graph.json"
  _build_retry_graph_json "$retry_graph_json" "v-beta" "claude" "$art_missing"

  local dispatch_count=0

  # Override the dispatch function for this test to count invocations.
  graph_dispatch_run_node() {
    dispatch_count=$((dispatch_count + 1))
    return 1  # Simulate dispatch failure (no artifact created).
  }

  local vj
  vj="$(printf '[{"voterId":"v-alpha","runtime":"cursor","artifact":"%s"},{"voterId":"v-beta","runtime":"claude","artifact":"%s","graphJsonPath":"%s"}]' \
    "$art_alpha" "$art_missing" "$retry_graph_json")"

  local join_exit=0
  graph_consensus_run_join "$workspace" "$namespace" "$run_id" "$node_id" "veto" "$vj" '{"onVoterError":"retry"}' || join_exit=$?

  [ "$join_exit" -ne 0 ]
  # Exactly one retry dispatch (not zero, not two).
  [ "$dispatch_count" -eq 1 ]

  rm -rf "$tmpd"
}

@test "onVoterError retry: successful retry allows join to proceed when retry creates artifact" {
  tmpd="$(mktemp -d)"
  workspace="$tmpd/ws"
  namespace="test-ns"
  run_id="run-retry-success"
  node_id="review-join"

  local art_alpha="$tmpd/artifacts/alpha.md"
  local art_beta="$tmpd/artifacts/beta.md"
  _make_voter_artifact "$art_alpha" "approved"
  # art_beta starts missing; the override will create it with an approved verdict.

  local retry_graph_json="$tmpd/retry.graph.json"
  _build_retry_graph_json "$retry_graph_json" "v-beta" "claude" "$art_beta"

  local dispatch_count=0

  # Override graph_dispatch_run_node: on dispatch, create art_beta with approved verdict.
  graph_dispatch_run_node() {
    dispatch_count=$((dispatch_count + 1))
    _make_voter_artifact "$art_beta" "approved"
    return 0
  }

  local vj
  vj="$(printf '[{"voterId":"v-alpha","runtime":"cursor","artifact":"%s"},{"voterId":"v-beta","runtime":"claude","artifact":"%s","graphJsonPath":"%s"}]' \
    "$art_alpha" "$art_beta" "$retry_graph_json")"

  local join_exit=0
  graph_consensus_run_join "$workspace" "$namespace" "$run_id" "$node_id" "veto" "$vj" '{"onVoterError":"retry"}' || join_exit=$?

  # Retry created the artifact -> join proceeds -> both approved -> veto passes.
  [ "$join_exit" -eq 0 ]
  [ "$dispatch_count" -eq 1 ]

  result_path="$(graph_consensus_result_path "$workspace" "$namespace" "$node_id")"
  decision="$(jq -r '.decision' "$result_path")"
  [ "$decision" = "approved" ]

  rm -rf "$tmpd"
}

# --- confidence in consensus result ---

@test "confidence field is present in written consensus result when voter artifact includes it" {
  tmpd="$(mktemp -d)"
  workspace="$tmpd/ws"
  namespace="test-ns"
  run_id="run-1"
  node_id="review-join"

  local art_alpha="$tmpd/artifacts/alpha.md"
  local art_beta="$tmpd/artifacts/beta.md"
  _make_voter_artifact_with_confidence "$art_alpha" "approved" "0.9"
  _make_voter_artifact_with_confidence "$art_beta" "approved" "0.7"

  local vj
  vj="$(printf '[{"voterId":"v-alpha","runtime":"cursor","artifact":"%s"},{"voterId":"v-beta","runtime":"claude","artifact":"%s"}]' \
    "$art_alpha" "$art_beta")"

  run graph_consensus_run_join "$workspace" "$namespace" "$run_id" "$node_id" "veto" "$vj"
  [ "$status" -eq 0 ]

  result_path="$(graph_consensus_result_path "$workspace" "$namespace" "$node_id")"
  [ -f "$result_path" ]

  conf_alpha="$(jq -r '.voters[] | select(.voterId == "v-alpha") | .confidence' "$result_path")"
  conf_beta="$(jq -r '.voters[] | select(.voterId == "v-beta") | .confidence' "$result_path")"

  [ "$conf_alpha" = "0.9" ]
  [ "$conf_beta" = "0.7" ]

  run bash "$VALIDATE_CONSENSUS_RESULT_SH" "$result_path"
  [ "$status" -eq 0 ]

  rm -rf "$tmpd"
}

@test "confidence absent from voter artifact is allowed and field is omitted from result" {
  tmpd="$(mktemp -d)"
  workspace="$tmpd/ws"
  namespace="test-ns"
  run_id="run-1"
  node_id="review-join"

  local art_alpha="$tmpd/artifacts/alpha.md"
  local art_beta="$tmpd/artifacts/beta.md"
  # No confidence field in either artifact.
  _make_voter_artifact "$art_alpha" "approved"
  _make_voter_artifact "$art_beta" "approved"

  local vj
  vj="$(printf '[{"voterId":"v-alpha","runtime":"cursor","artifact":"%s"},{"voterId":"v-beta","runtime":"claude","artifact":"%s"}]' \
    "$art_alpha" "$art_beta")"

  run graph_consensus_run_join "$workspace" "$namespace" "$run_id" "$node_id" "veto" "$vj"
  [ "$status" -eq 0 ]

  result_path="$(graph_consensus_result_path "$workspace" "$namespace" "$node_id")"
  # confidence must not be present when the voter artifact did not include it.
  has_conf="$(jq '.voters[] | has("confidence")' "$result_path" | sort -u)"
  [ "$has_conf" = "false" ]

  run bash "$VALIDATE_CONSENSUS_RESULT_SH" "$result_path"
  [ "$status" -eq 0 ]

  rm -rf "$tmpd"
}

# --- adjudication dissent packet ordered by ascending confidence ---

@test "adjudication dissent packet orders dissenting voters by ascending confidence (lowest first)" {
  tmpd="$(mktemp -d)"
  setup_dispatch_workspace_for_consensus "$tmpd"

  workspace="$DISPATCH_WORKSPACE"
  namespace="test-ns"
  run_id="run-1"
  node_id="review-join"

  local art_alpha="$tmpd/artifacts/alpha.md"
  local art_beta="$tmpd/artifacts/beta.md"
  local art_gamma="$tmpd/artifacts/gamma.md"
  # Two dissenters with different confidences.
  _make_voter_artifact_with_confidence "$art_alpha" "approved"    "0.9"
  _make_voter_artifact_with_confidence "$art_beta"  "changes-required" "0.3"   # lower confidence
  _make_voter_artifact_with_confidence "$art_gamma" "changes-required" "0.7"   # higher confidence

  adj_artifact="$(graph_consensus_adjudicator_artifact_path "$workspace" "$namespace" "$node_id")"
  mkdir -p "$(dirname "$adj_artifact")"
  printf '<!-- REVIEW_STATUS: START -->\nstatus: approved\n<!-- REVIEW_STATUS: END -->\n' > "$adj_artifact"

  export RUN_PLAN_STUB_EXIT_CODE=0
  export RALPH_RUN_PLAN_CAPTURE_FILE="$tmpd/adj-capture.json"
  unset RUN_PLAN_STUB_SLEEP_SECONDS RUN_PLAN_STUB_READY_FILE 2>/dev/null || true

  local vj
  vj="$(printf '[{"voterId":"v-alpha","runtime":"cursor","artifact":"%s"},{"voterId":"v-beta","runtime":"claude","artifact":"%s"},{"voterId":"v-gamma","runtime":"codex","artifact":"%s"}]' \
    "$art_alpha" "$art_beta" "$art_gamma")"

  run graph_consensus_run_join "$workspace" "$namespace" "$run_id" "$node_id" "adjudicate" "$vj"
  [ "$status" -eq 0 ]

  # Read the written dissent packet and verify ordering.
  safe_id="$(printf '%s' "$node_id" | sed 's/[^A-Za-z0-9._-]/_/g')"
  packet_path="$(dirname "$adj_artifact")/${safe_id}-adjudicator-packet.json"
  [ -f "$packet_path" ]

  # First dissenting voter must have lower confidence than the second.
  conf_first="$(jq -r '.dissentingVoters[0].confidence' "$packet_path")"
  conf_second="$(jq -r '.dissentingVoters[1].confidence' "$packet_path")"

  # Ordering: conf_first (0.3) < conf_second (0.7).
  # Use jq for float comparison.
  ordered="$(jq -n --argjson a "$conf_first" --argjson b "$conf_second" '$a < $b')"
  [ "$ordered" = "true" ]

  # Lowest-confidence dissenter (v-beta, 0.3) must appear first.
  first_voter="$(jq -r '.dissentingVoters[0].voterId' "$packet_path")"
  [ "$first_voter" = "v-beta" ]

  rm -rf "$tmpd"
}

# --- confidence invariance: no decision changes across any policy ---

@test "inverting every voter confidence value changes no decision under veto policy" {
  tmpd="$(mktemp -d)"
  workspace="$tmpd/ws"
  namespace="test-ns"
  run_id="run-1"
  node_id="review-join"

  local art_alpha="$tmpd/artifacts/alpha.md"
  local art_beta="$tmpd/artifacts/beta.md"
  local art_gamma="$tmpd/artifacts/gamma.md"

  # Run 1: high confidence voters.
  _make_voter_artifact_with_confidence "$art_alpha" "approved"         "0.9"
  _make_voter_artifact_with_confidence "$art_beta"  "changes-required" "0.8"
  _make_voter_artifact_with_confidence "$art_gamma" "approved"         "0.7"

  local vj
  vj="$(printf '[{"voterId":"v-alpha","runtime":"cursor","artifact":"%s"},{"voterId":"v-beta","runtime":"claude","artifact":"%s"},{"voterId":"v-gamma","runtime":"codex","artifact":"%s"}]' \
    "$art_alpha" "$art_beta" "$art_gamma")"

  local exit1=0
  graph_consensus_run_join "$workspace" "$namespace" "run-high" "$node_id" "veto" "$vj" || exit1=$?

  result1="$(graph_consensus_result_path "$workspace" "$namespace" "$node_id")"
  decision1="$(jq -r '.decision' "$result1")"

  # Cleanup for the second run (different run_id clears the ledger path).
  # Run 2: inverted confidence voters (0.9->0.1, 0.8->0.2, 0.7->0.3).
  _make_voter_artifact_with_confidence "$art_alpha" "approved"         "0.1"
  _make_voter_artifact_with_confidence "$art_beta"  "changes-required" "0.2"
  _make_voter_artifact_with_confidence "$art_gamma" "approved"         "0.3"

  local workspace2="$tmpd/ws2"
  local exit2=0
  graph_consensus_run_join "$workspace2" "$namespace" "run-low" "$node_id" "veto" "$vj" || exit2=$?

  result2="$(graph_consensus_result_path "$workspace2" "$namespace" "$node_id")"
  decision2="$(jq -r '.decision' "$result2")"

  # Decisions must be identical regardless of confidence values.
  [ "$decision1" = "$decision2" ]
  [ "$exit1" -eq "$exit2" ]

  rm -rf "$tmpd"
}

@test "inverting every voter confidence value changes no decision under unanimous policy" {
  tmpd="$(mktemp -d)"
  namespace="test-ns"
  node_id="review-join"

  local art_alpha="$tmpd/artifacts/alpha.md"
  local art_beta="$tmpd/artifacts/beta.md"
  _make_voter_artifact_with_confidence "$art_alpha" "approved"         "0.95"
  _make_voter_artifact_with_confidence "$art_beta"  "changes-required" "0.85"

  local vj
  vj="$(printf '[{"voterId":"v-alpha","runtime":"cursor","artifact":"%s"},{"voterId":"v-beta","runtime":"claude","artifact":"%s"}]' \
    "$art_alpha" "$art_beta")"

  local ws1="$tmpd/ws1" ws2="$tmpd/ws2"
  local exit1=0 exit2=0

  graph_consensus_run_join "$ws1" "$namespace" "run-1" "$node_id" "unanimous" "$vj" || exit1=$?
  decision1="$(jq -r '.decision' "$(graph_consensus_result_path "$ws1" "$namespace" "$node_id")")"

  # Invert confidences.
  _make_voter_artifact_with_confidence "$art_alpha" "approved"         "0.05"
  _make_voter_artifact_with_confidence "$art_beta"  "changes-required" "0.15"

  graph_consensus_run_join "$ws2" "$namespace" "run-2" "$node_id" "unanimous" "$vj" || exit2=$?
  decision2="$(jq -r '.decision' "$(graph_consensus_result_path "$ws2" "$namespace" "$node_id")")"

  [ "$decision1" = "$decision2" ]
  [ "$exit1" -eq "$exit2" ]

  rm -rf "$tmpd"
}

@test "consensus artifact paths honor an external state root" {
  workspace="$BATS_TEST_TMPDIR/workspace"
  state_root="$BATS_TEST_TMPDIR/state"
  mkdir -p "$workspace" "$state_root"
  export RALPH_PLAN_WORKSPACE_ROOT="$state_root"

  [ "$(graph_consensus_result_path "$workspace" "jury" "review:barrier")" = \
    "$state_root/artifacts/jury/consensus/review_barrier.json" ]
  [ "$(graph_consensus_adjudicator_artifact_path "$workspace" "jury" "review:barrier")" = \
    "$state_root/artifacts/jury/consensus/review_barrier-adjudicator.md" ]
}
