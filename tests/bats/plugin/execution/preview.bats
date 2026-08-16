#!/usr/bin/env bats

source "$BATS_TEST_DIRNAME/../../helper/load-lib.bash"

EXEC="$REPO_ROOT/bundle/.ralph/plugin-inputs/shared/ralph-plugin-exec.sh"

setup() {
  TEST_TMPDIR="$(cd "$(mktemp -d)" && pwd)"
  FAKE_BIN="$TEST_TMPDIR/bin"
  FAKE_PROJECT="$TEST_TMPDIR/project"
  FAKE_STATE="$TEST_TMPDIR/state"
  FAKE_AGENT="$TEST_TMPDIR/agent"
  RALPH_RECORD="$TEST_TMPDIR/ralph-invocations.log"
  ORCH_RECORD="$TEST_TMPDIR/orchestrator-invocations.log"
  GRAPH_RECORD="$TEST_TMPDIR/graph-invocations.log"
  mkdir -p "$FAKE_BIN" "$FAKE_PROJECT" "$FAKE_STATE" "$FAKE_AGENT"
  write_invocation_traps
  write_plan_fixtures
}

teardown() {
  rm -rf "$TEST_TMPDIR"
}

write_invocation_traps() {
  cat >"$FAKE_BIN/ralph" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"$RALPH_RECORD"
printf '%s\n' "ralph must not be invoked during preview: \$*" >&2
exit 99
EOF
  chmod +x "$FAKE_BIN/ralph"

  cat >"$FAKE_BIN/orchestrator.sh" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"$ORCH_RECORD"
printf '%s\n' "orchestrator must not be invoked during preview" >&2
exit 99
EOF
  chmod +x "$FAKE_BIN/orchestrator.sh"

  cat >"$FAKE_BIN/graph-run.sh" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"$GRAPH_RECORD"
printf '%s\n' "graph-run must not be invoked during preview" >&2
exit 99
EOF
  chmod +x "$FAKE_BIN/graph-run.sh"
}

write_plan_fixtures() {
  printf '%s\n' '- [ ] demo' >"$FAKE_PROJECT/plan.md"
  cat >"$FAKE_PROJECT/orch.plan.md" <<'EOF'
---
name: orch-demo
pipeline:
  - id: s1
    runtime: claude
    agent: architect
---
- [ ] stage
EOF
  cat >"$FAKE_PROJECT/graph.plan.md" <<'EOF'
---
name: graph-demo
execution: graph
pipeline:
  - id: n1
    runtime: cursor
    agent: implementation
---
- [ ] node
EOF
}

preview_env() {
  env PATH="$FAKE_BIN:/usr/bin:/bin:/usr/sbin:/sbin" HOME="$TEST_TMPDIR/home" \
    /bin/bash "$EXEC" "$@"
}

json_from_output() {
  printf '%s\n' "$1" | awk '/^\{/{ line=$0 } END { print line }'
}

text_from_output() {
  printf '%s\n' "$1" | awk '/^\{/{ exit } { print }'
}

assert_json_field() {
  local json=$1
  local field=$2
  local expected=$3
  local actual
  actual="$(printf '%s\n' "$json" | jq -r --arg f "$field" '.[$f] | tostring')"
  [ "$actual" = "$expected" ]
}

assert_preview_order() {
  local text=$1
  local labels
  labels="$(printf '%s\n' "$text" | awk -F: '{print $1}')"
  [ "$labels" = $'kind\nplanPath\nprojectRoot\nstateRoot\nagentRoot\nruntime\nagent\nmodel\ncommand\nconfirmationId' ]
}

assert_zero_invocation() {
  [ ! -f "$RALPH_RECORD" ]
  [ ! -f "$ORCH_RECORD" ]
  [ ! -f "$GRAPH_RECORD" ]
}

assert_confirmation_id() {
  local json=$1
  local expected actual payload
  payload="$(jq -r '
    [
      "schemaVersion=\(.schemaVersion)",
      "kind=\(.kind)",
      "planPath=\(.planPath)",
      "projectRoot=\(.projectRoot)",
      "stateRoot=\(.stateRoot)",
      "agentRoot=\(.agentRoot)",
      "runtime=\(.runtime)",
      "agent=\(.agent)",
      "model=\(.model)",
      "command=\(.command)"
    ] | join("\n") + "\n"
  ' <<<"$json")"
  if command -v sha256sum >/dev/null 2>&1; then
    expected=$(printf '%s' "$payload" | sha256sum | awk '{print $1}')
  else
    expected=$(printf '%s' "$payload" | shasum -a 256 | awk '{print $1}')
  fi
  actual=$(printf '%s\n' "$json" | jq -r '.confirmationId')
  [ "$actual" = "$expected" ]
  [[ "$actual" =~ ^[a-f0-9]{64}$ ]]
}

assert_unchanged_tree() {
  local before=$1
  local after
  after="$(find "$TEST_TMPDIR" -print | LC_ALL=C sort)"
  [ "$before" = "$after" ]
}

@test "preview plan resolves tuple, ordered text, confirmation id, and does not invoke" {
  local before json text
  before="$(find "$TEST_TMPDIR" -print | LC_ALL=C sort)"
  run preview_env preview \
    --kind plan \
    --plan "$FAKE_PROJECT/plan.md" \
    --runtime cursor \
    --agent implementation \
    --model "composer-2" \
    --workspace "$FAKE_PROJECT" \
    --workspace-root "$FAKE_STATE" \
    --agent-workspace "$FAKE_AGENT"
  [ "$status" -eq 0 ]
  text="$(text_from_output "$output")"
  json="$(json_from_output "$output")"
  assert_preview_order "$text"
  assert_json_field "$json" "kind" "plan"
  assert_json_field "$json" "planPath" "$FAKE_PROJECT/plan.md"
  assert_json_field "$json" "projectRoot" "$FAKE_PROJECT"
  assert_json_field "$json" "stateRoot" "$FAKE_STATE"
  assert_json_field "$json" "agentRoot" "$FAKE_AGENT"
  assert_json_field "$json" "runtime" "cursor"
  assert_json_field "$json" "agent" "implementation"
  assert_json_field "$json" "model" "composer-2"
  [[ "$output" == *"command: ralph run --plan '$FAKE_PROJECT/plan.md' --runtime 'cursor' --agent 'implementation' --model 'composer-2' --workspace '$FAKE_PROJECT' --workspace-root '$FAKE_STATE' --agent-workspace '$FAKE_AGENT'"* ]]
  assert_json_field "$json" "command" "ralph run --plan '$FAKE_PROJECT/plan.md' --runtime 'cursor' --agent 'implementation' --model 'composer-2' --workspace '$FAKE_PROJECT' --workspace-root '$FAKE_STATE' --agent-workspace '$FAKE_AGENT'"
  assert_confirmation_id "$json"
  assert_zero_invocation
  assert_unchanged_tree "$before"
}

@test "preview orchestration uses ralph run and does not invoke the orchestrator" {
  local json text
  run preview_env preview \
    --kind orchestration \
    --plan "$FAKE_PROJECT/orch.plan.md" \
    --runtime claude \
    --agent architect \
    --workspace "$FAKE_PROJECT" \
    --workspace-root "$FAKE_STATE" \
    --agent-workspace "$FAKE_AGENT"
  [ "$status" -eq 0 ]
  text="$(text_from_output "$output")"
  json="$(json_from_output "$output")"
  assert_preview_order "$text"
  assert_json_field "$json" "kind" "orchestration"
  assert_json_field "$json" "planPath" "$FAKE_PROJECT/orch.plan.md"
  [[ "$(printf '%s\n' "$json" | jq -r '.command')" == ralph\ run\ --plan\ * ]]
  [[ "$(printf '%s\n' "$json" | jq -r '.command')" != *orchestrat* ]]
  assert_confirmation_id "$json"
  assert_zero_invocation
}

@test "preview graph-run prints ralph graph run and does not start a graph" {
  local json text
  run preview_env preview \
    --kind graph-run \
    --plan "$FAKE_PROJECT/graph.plan.md" \
    --runtime opencode \
    --agent implementation \
    --model "kimi-k2.7-code" \
    --namespace plugin-preview \
    --workspace "$FAKE_PROJECT" \
    --workspace-root "$FAKE_STATE" \
    --agent-workspace "$FAKE_AGENT"
  [ "$status" -eq 0 ]
  text="$(text_from_output "$output")"
  json="$(json_from_output "$output")"
  assert_preview_order "$text"
  assert_json_field "$json" "kind" "graph-run"
  assert_json_field "$json" "runtime" "opencode"
  assert_json_field "$json" "agent" "implementation"
  assert_json_field "$json" "model" "kimi-k2.7-code"
  assert_json_field "$json" "command" "ralph graph run '$FAKE_PROJECT/graph.plan.md' --namespace 'plugin-preview' --workspace '$FAKE_PROJECT'"
  assert_confirmation_id "$json"
  assert_zero_invocation
}

@test "preview graph-resume prints ralph graph resume and does not resume" {
  local json text
  run preview_env preview \
    --kind graph-resume \
    --plan "$FAKE_PROJECT/graph.plan.md" \
    --namespace plugin-preview \
    --run latest \
    --workspace "$FAKE_PROJECT" \
    --workspace-root "$FAKE_STATE" \
    --agent-workspace "$FAKE_AGENT"
  [ "$status" -eq 0 ]
  text="$(text_from_output "$output")"
  json="$(json_from_output "$output")"
  assert_preview_order "$text"
  assert_json_field "$json" "kind" "graph-resume"
  assert_json_field "$json" "command" "ralph graph resume '$FAKE_PROJECT/graph.plan.md' --namespace 'plugin-preview' --run 'latest' --workspace '$FAKE_PROJECT'"
  assert_confirmation_id "$json"
  assert_zero_invocation
}
