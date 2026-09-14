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
  cat >"$FAKE_PROJECT/feature.workflow.md" <<'EOF'
---
name: feature-delivery
kind: workflow
mode: dependency
---
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
  [ "$labels" = $'kind\nplanPath\nprojectRoot\nstateRoot\nagentRoot\nruntime\nmodel\nmodel source\nnative subagents\ntask\ninputPlan\nrunId\ncommand\nconfirmationId' ]
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
      "model=\(.model)",
      "modelSource=\(.modelSource)",
      "nativeSubagents=\(.nativeSubagents)",
      "task=\(.task)",
      "inputPlan=\(.inputPlan)",
      "runId=\(.runId)",
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
  assert_json_field "$json" "model" "composer-2"
  assert_json_field "$json" "modelSource" "explicit override"
  assert_json_field "$json" "nativeSubagents" "inherit"
  [[ "$output" == *"command: ralph run --plan '$FAKE_PROJECT/plan.md' --runtime 'cursor' --model 'composer-2' --workspace '$FAKE_PROJECT' --workspace-root '$FAKE_STATE' --agent-workspace '$FAKE_AGENT'"* ]]
  assert_json_field "$json" "command" "ralph run --plan '$FAKE_PROJECT/plan.md' --runtime 'cursor' --model 'composer-2' --workspace '$FAKE_PROJECT' --workspace-root '$FAKE_STATE' --agent-workspace '$FAKE_AGENT'"
  assert_confirmation_id "$json"
  assert_zero_invocation
  assert_unchanged_tree "$before"
}

@test "preview workflow-start prints ralph workflow start --file and does not invoke engines" {
  local json text
  run preview_env preview \
    --kind workflow-start \
    --plan "$FAKE_PROJECT/feature.workflow.md" \
    --task "ship feature" \
    --input-plan "$FAKE_PROJECT/plan.md" \
    --runtime claude \
    --workspace "$FAKE_PROJECT" \
    --workspace-root "$FAKE_STATE" \
    --agent-workspace "$FAKE_AGENT"
  [ "$status" -eq 0 ]
  text="$(text_from_output "$output")"
  json="$(json_from_output "$output")"
  assert_preview_order "$text"
  assert_json_field "$json" "kind" "workflow-start"
  assert_json_field "$json" "planPath" "$FAKE_PROJECT/feature.workflow.md"
  assert_json_field "$json" "task" "ship feature"
  assert_json_field "$json" "inputPlan" "$FAKE_PROJECT/plan.md"
  [[ "$(printf '%s\n' "$json" | jq -r '.command')" == ralph\ workflow\ start\ --file\ * ]]
  [[ "$(printf '%s\n' "$json" | jq -r '.command')" == *"--plan '$FAKE_PROJECT/plan.md'"* ]]
  [[ "$(printf '%s\n' "$json" | jq -r '.command')" != *orchestrat* ]]
  [[ "$(printf '%s\n' "$json" | jq -r '.command')" != *'ralph graph'* ]]
  assert_confirmation_id "$json"
  assert_zero_invocation
}

@test "preview workflow-resume prints ralph workflow resume and does not resume" {
  local json text
  run preview_env preview \
    --kind workflow-resume \
    --run run-20260101T000000Z-demo-abcdef \
    --workspace "$FAKE_PROJECT" \
    --workspace-root "$FAKE_STATE" \
    --agent-workspace "$FAKE_AGENT"
  [ "$status" -eq 0 ]
  text="$(text_from_output "$output")"
  json="$(json_from_output "$output")"
  assert_preview_order "$text"
  assert_json_field "$json" "kind" "workflow-resume"
  assert_json_field "$json" "runId" "run-20260101T000000Z-demo-abcdef"
  assert_json_field "$json" "command" "ralph workflow resume 'run-20260101T000000Z-demo-abcdef' --workspace '$FAKE_PROJECT'"
  assert_confirmation_id "$json"
  assert_zero_invocation
}

@test "preview rejects removed orchestration and graph kinds" {
  run preview_env preview \
    --kind orchestration \
    --plan "$FAKE_PROJECT/plan.md" \
    --workspace "$FAKE_PROJECT"
  [ "$status" -ne 0 ]
  [[ "$output" == *"unknown kind"* ]]

  run preview_env preview \
    --kind graph-run \
    --plan "$FAKE_PROJECT/plan.md" \
    --workspace "$FAKE_PROJECT"
  [ "$status" -ne 0 ]
  [[ "$output" == *"unknown kind"* ]]
}

@test "preview rejects removed --role" {
  run preview_env preview \
    --kind plan \
    --plan "$FAKE_PROJECT/plan.md" \
    --role implementation \
    --workspace "$FAKE_PROJECT"
  [ "$status" -ne 0 ]
  [[ "$output" == *"--role was removed"* ]]
}
