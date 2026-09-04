#!/usr/bin/env bats
# Stage-only graph artifact contracts (remove-graph-agent-artifact-fallback):
# roles never supply outputs, handoffs, provenance, or completion evidence.
# Compile/success paths use stage-declared produces/outputArtifacts only.
#
# Also covers G12 three-root routing: a required output declared as
# `.ralph-workspace/artifacts/{{ARTIFACT_NS}}/<path>` resolves to the
# supervisor state root, never the isolated agent workspace.

source "$BATS_TEST_DIRNAME/../helper/load-lib.bash"
source "$REPO_ROOT/bundle/.ralph/bash-lib/plan-todo.sh"
source "$REPO_ROOT/bundle/.ralph/bash-lib/graph/graph-composite-success.sh"

ORCHESTRATOR_SH="$BATS_TEST_DIRNAME/../../../bundle/.ralph/orchestrator.sh"
GRAPH_DISPATCH_SH="$BATS_TEST_DIRNAME/../../../bundle/.ralph/bash-lib/graph/graph-dispatch.sh"

setup() {
  unset RALPH_PROCESS_RUN_ID RALPH_PROCESS_RUN_DEPTH RALPH_PROCESS_MAX_NESTED_DEPTH
  unset RALPH_ARTIFACT_NS RALPH_PLAN_KEY RALPH_STAGE_ID
  TMPD="$(mktemp -d)"
  PROJECT="$TMPD/project"
  STATE="$TMPD/state"
  AGENTWS="$TMPD/agent-snapshot"
  mkdir -p "$PROJECT" "$STATE" "$AGENTWS/src"
  BIN_DIR="$TMPD/bin"
  mkdir -p "$BIN_DIR"
}

teardown() {
  chmod -R u+w "$TMPD" 2>/dev/null || true
  rm -rf "$TMPD"
}

# A fake runtime executable (G20-style: prints deterministic native output,
# records argv, writes only through its prompt contract). It writes the
# first "  - <path>" line from the prompt -- the exact resolved destination
# the prompt names -- proving the prompt told it the real, absolute,
# state-root path rather than leaving it to guess a workspace-relative one.
_gar_write_runtime_stub() {
  local write_artifact="${1:-1}"
  cat >"$BIN_DIR/cursor-agent" <<EOF
#!/usr/bin/env bash
set -euo pipefail
prompt="\${!#}"
printf '%s' "\$prompt" >"$TMPD/last-prompt.txt"
case "\$1" in
  --help)
    printf '%s\n' "Usage: cursor-agent" "  --permission-prompt-tool <name>"
    exit 0
    ;;
esac
if [[ "$write_artifact" == "1" ]]; then
  dest="\$(printf '%s' "\$prompt" | grep '^  - ' | head -1 | sed 's/^  - //' || true)"
  if [[ -n "\$dest" ]]; then
    mkdir -p "\$(dirname "\$dest")"
    echo "artifact content" > "\$dest"
  fi
fi
printf '%s\n' "TODO_COMPLETION: COMPLETE"
exit 0
EOF
  chmod +x "$BIN_DIR/cursor-agent"
}

_gar_write_stage_plan_and_orch() {
  local role_json="${1:-}"
  PLAN="$AGENTWS/stage.plan.md"
  cat >"$PLAN" <<'PLAN'
---
name: artifact-stage
overview: writes a required artifact
execution: standard
instructions: Execute one TODO at a time.

todos:
  - id: t1
    content: |
      write the output
    verification: |

    status: pending
isProject: false
---
PLAN

  ORCH_JSON="$TMPD/test.orch.json"
  if [[ -n "$role_json" ]]; then
    jq -n --arg plan "$PLAN" --argjson role "$role_json" \
      '{name: "art-ns", namespace: "art-ns", stages: [{id: "art", runtime: "cursor", plan: $plan, outputArtifacts: [{path: ".ralph-workspace/artifacts/{{ARTIFACT_NS}}/out.md", required: true}]}]}' \
      >"$ORCH_JSON"
  else
    jq -n --arg plan "$PLAN" \
      '{name: "art-ns", namespace: "art-ns", stages: [{id: "art", runtime: "cursor", plan: $plan, outputArtifacts: [{path: ".ralph-workspace/artifacts/{{ARTIFACT_NS}}/out.md", required: true}]}]}' \
      >"$ORCH_JSON"
  fi
}

_gar_write_role() {
  local role_id="$1"
  mkdir -p "$PROJECT/.ralph/roles"
  cat >"$PROJECT/.ralph/roles/${role_id}.md" <<'ROLE'
---
description: "instruction-only role for artifact routing tests"
---
## Instructions

Behavioral guidance only. Do not invent outputs.
ROLE
}

_gar_write_legacy_profile_output_artifacts() {
  local role_id="$1"
  local artifact_path="$2"
  mkdir -p "$AGENTWS/.cursor/agents/$role_id"
  cat >"$AGENTWS/.cursor/agents/$role_id/config.json" <<CFG
{
  "name": "$role_id",
  "model": "auto",
  "description": "legacy profile must not supply graph outputs",
  "rules": [],
  "skills": [],
  "output_artifacts": [
    {
      "path": "$artifact_path",
      "required": true
    }
  ]
}
CFG
}

_gar_run_orchestrator_for_stage() {
  local stage_id="$1"
  local namespace="$2"
  PATH="$BIN_DIR:$PATH" \
    CURSOR_PLAN_MODEL=auto \
    RALPH_ACTIVE_DIR="$BATS_TEST_DIRNAME/../../../bundle/.ralph" \
    RALPH_ALLOW_NESTED_RUNS=1 \
    RALPH_PLAN_CLI_RESUME=0 \
    RALPH_PLAN_AGENT_POLL_INTERVAL=0.1 \
    RALPH_PROJECT_ROOT="$PROJECT" \
    RALPH_AGENT_WORKSPACE="$AGENTWS" \
    RALPH_ARTIFACT_ROOT="$STATE/artifacts/$namespace" \
    bash "$ORCHESTRATOR_SH" --orchestration "$ORCH_JSON" --single-stage "$stage_id" \
    --run-id run1 --attempt-id attempt1 --workspace-root "$STATE" "$AGENTWS"
}

_gar_run_orchestrator_directly() {
  _gar_run_orchestrator_for_stage art art-ns
}

_gar_write_compile_plan() {
  local out_path="$1"
  local with_produces="${2:-0}"
  local produces_block=""
  if [[ "$with_produces" == "1" ]]; then
    produces_block="$(cat <<'P'
      produces:
        - path: .ralph-workspace/artifacts/{{ARTIFACT_NS}}/out.md
          required: true
P
)"
  fi
  cat >"$out_path" <<PLAN
---
name: compile-arts
overview: compile-time artifact authority
execution: graph
pipeline:
  stages:
    - id: writer
      runtime: cursor
${produces_block}
todos:
  - id: writer-1
    stage: writer
    content: write when stage declares produces
    status: pending
---
PLAN
}

_gar_composite_validate() {
  local graph="$1" report="$2" run_file="$3" plan="$4" state_root="$5" namespace="$6"
  local ws="$TMPD/cws"
  mkdir -p "$ws"
  graph_composite_success_validate "$report" "$graph" "$run_file" writer run writer__run__1 \
    "$ws" "$state_root" "$namespace" "$plan" ""
}

@test "compile: explicit stage produces become outputArtifacts; routing preserved" {
  command -v jq >/dev/null || skip "jq required"
  command -v python3 >/dev/null || skip "python3 required"
  local plan="$TMPD/explicit.plan.md"
  _gar_write_compile_plan "$plan" 1
  run plan_pipeline_graph_json "$plan"
  [ "$status" -eq 0 ]
  local node
  node="$(printf '%s' "$output" | jq -c '.nodes[] | select(.id == "writer")')"
  [ "$(printf '%s' "$node" | jq -r '.stage | has("role")')" = "false" ]
  [ "$(printf '%s' "$node" | jq -r '.stage.outputArtifacts | length')" -eq 1 ]
  [ "$(printf '%s' "$node" | jq -r '.stage.outputArtifacts[0].path')" = \
    ".ralph-workspace/artifacts/{{ARTIFACT_NS}}/out.md" ]
  # No role-invented extras beyond the stage produce.
  [ "$(printf '%s' "$node" | jq -r '.stage.outputArtifacts | map(.path) | unique | length')" -eq 1 ]
}

@test "compile: role with absent produces invents no outputArtifacts (removed fallback)" {
  command -v jq >/dev/null || skip "jq required"
  command -v python3 >/dev/null || skip "python3 required"
  local plan="$TMPD/absent.plan.md"
  _gar_write_compile_plan "$plan" 0
  run plan_pipeline_graph_json "$plan"
  [ "$status" -eq 0 ]
  local node
  node="$(printf '%s' "$output" | jq -c '.nodes[] | select(.id == "writer")')"
  [ "$(printf '%s' "$node" | jq -r '.stage | has("role")')" = "false" ]
  [ "$(printf '%s' "$node" | jq -r '(.stage.outputArtifacts // []) | length')" -eq 0 ]
  [ "$(printf '%s' "$node" | jq -r '(.stage.artifacts // []) | length')" -eq 0 ]
  [ "$(printf '%s' "$node" | jq -r 'has("stage") and (.stage | has("loopCheck") | not)')" = "true" ]
}

@test "success: explicit required artifact absent fails closed without role inventing paths" {
  command -v jq >/dev/null || skip "jq required"
  local graph="$TMPD/g.json" report="$TMPD/r.json" run_file="$TMPD/run.json" plan="$TMPD/p.md"
  printf '%s\n' '- [x] done' >"$plan"
  printf '%s\n' '{"sourceBase":{"filesystemIdentity":"base"},"workspaceManager":{"schemaVersion":1,"configSha":"abc"}}' >"$run_file"
  jq -n '{
    namespace: "ns",
    nodes: [{
      id: "writer",
      stage: {
        id: "writer",
        role: "implementation",
        outputArtifacts: [{path: "out.md", required: true}]
      }
    }],
    edges: [],
    verificationProfiles: []
  }' >"$graph"
  jq -n '{
    schemaVersion: 1,
    runId: "run",
    stageId: "writer",
    attemptId: "writer__run__1",
    outcome: "success",
    exitCode: 0,
    startedAt: "2026-01-01T00:00:00Z",
    finishedAt: "2026-01-01T00:00:01Z"
  }' >"$report"
  # Deliberately omit exchange/out.md -- and seed a legacy profile path that
  # must not satisfy the stage contract.
  mkdir -p "$STATE/artifacts/ns/exchange" "$AGENTWS/.cursor/agents/implementation"
  printf 'from-profile\n' >"$STATE/artifacts/ns/exchange/from-profile.md"
  cat >"$AGENTWS/.cursor/agents/implementation/config.json" <<'CFG'
{
  "name": "implementation",
  "model": "auto",
  "description": "legacy",
  "rules": [],
  "skills": [],
  "output_artifacts": [{"path": "from-profile.md", "required": true}]
}
CFG
  local rc=0
  _gar_composite_validate "$graph" "$report" "$run_file" "$plan" "$STATE" ns || rc=$?
  [ "$rc" -ne 0 ]
  [[ "${GRAPH_COMPOSITE_SUCCESS_REASON:-}" == required-artifact-missing:out.md ]]
}

@test "success: role-with-none and absent stage outputs succeed (removed fallback)" {
  command -v jq >/dev/null || skip "jq required"
  local graph="$TMPD/g.json" report="$TMPD/r.json" run_file="$TMPD/run.json" plan="$TMPD/p.md"
  printf '%s\n' '- [x] done' >"$plan"
  printf '%s\n' '{"sourceBase":{"filesystemIdentity":"base"}}' >"$run_file"
  jq -n '{
    namespace: "ns",
    nodes: [{
      id: "writer",
      stage: {id: "writer"}
    }],
    edges: [],
    verificationProfiles: []
  }' >"$graph"
  jq -n '{
    schemaVersion: 1,
    runId: "run",
    stageId: "writer",
    attemptId: "writer__run__1",
    outcome: "success",
    exitCode: 0,
    startedAt: "2026-01-01T00:00:00Z",
    finishedAt: "2026-01-01T00:00:01Z"
  }' >"$report"
  _gar_write_legacy_profile_output_artifacts research \
    ".ralph-workspace/artifacts/{{ARTIFACT_NS}}/from-profile.md"
  # Profile lists a required output that was never written. Stage declares none.
  run _gar_composite_validate "$graph" "$report" "$run_file" "$plan" "$STATE" ns
  [ "$status" -eq 0 ]
  [ -s "$STATE/artifacts/ns/composite-success/writer/writer__run__1.json" ]
}

@test "three distinct roots: successful completion writes exactly one artifact under the state root, none in the agent snapshot" {
  _gar_write_runtime_stub 1
  _gar_write_role implementation
  _gar_write_stage_plan_and_orch '"implementation"'

  run _gar_run_orchestrator_directly
  [ "$status" -eq 0 ]

  report="$STATE/artifacts/art-ns/stage-outcomes/attempt1.json"
  [ -f "$report" ]
  [ "$(jq -r '.schemaVersion' "$report")" = "2" ]
  [ "$(jq -r '.outcome' "$report")" = "success" ]
  [ "$(jq -r 'has("failure")' "$report")" = "false" ]

  local state_hits agent_hits
  state_hits="$(find "$STATE" -name "out.md" | wc -l | tr -d ' ')"
  agent_hits="$(find "$AGENTWS" -name "out.md" | wc -l | tr -d ' ')"
  [ "$state_hits" -eq 1 ]
  [ "$agent_hits" -eq 0 ]
  [ -f "$STATE/artifacts/art-ns/out.md" ]

  grep -q "Required output artifacts" "$TMPD/last-prompt.txt"
  grep -q "supervisor-owned outputs" "$TMPD/last-prompt.txt"
  grep -qF "$STATE/artifacts/art-ns/out.md" "$TMPD/last-prompt.txt"
}

@test "three distinct roots: a missing artifact resolves to the state root and carries G11 required-artifact-missing evidence" {
  _gar_write_runtime_stub 0
  _gar_write_stage_plan_and_orch ""

  run _gar_run_orchestrator_directly
  [ "$status" -ne 0 ]

  report="$STATE/artifacts/art-ns/stage-outcomes/attempt1.json"
  [ -f "$report" ]
  [ "$(jq -r '.schemaVersion' "$report")" = "2" ]
  [ "$(jq -r '.outcome' "$report")" = "failed" ]
  [ "$(jq -r '.failure.classification' "$report")" = "agent-correctable" ]
  [ "$(jq -r '.failure.cause' "$report")" = "required-artifact-missing" ]
  [ "$(jq -r '.failure.source' "$report")" = "orchestrator" ]
  [ "$(jq -r '.failure.missingArtifacts | length' "$report")" -eq 1 ]
  [[ "$(jq -r '.failure.missingArtifacts[0]' "$report")" == "$STATE/artifacts/art-ns/out.md" ]]

  [ "$(find "$AGENTWS" -name "out.md" | wc -l | tr -d ' ')" -eq 0 ]
}

@test "orchestrator: legacy profile output_artifacts are not required when stage declares none" {
  _gar_write_runtime_stub 1
  _gar_write_role research
  _gar_write_legacy_profile_output_artifacts research \
    ".ralph-workspace/artifacts/{{ARTIFACT_NS}}/from-profile.md"
  PLAN="$AGENTWS/stage.plan.md"
  cat >"$PLAN" <<'PLAN'
---
name: role-none
overview: no stage outputs
execution: standard
instructions: Execute one TODO at a time.
todos:
  - id: t1
    content: |
      no declared outputs
    verification: |

    status: pending
isProject: false
---
PLAN
  ORCH_JSON="$TMPD/role-none.orch.json"
  jq -n --arg plan "$PLAN" \
    '{name: "role-none", namespace: "role-none", stages: [{id: "research-step", runtime: "cursor", plan: $plan}]}' \
    >"$ORCH_JSON"

  run _gar_run_orchestrator_for_stage research-step role-none
  [ "$status" -eq 0 ]
  [ ! -f "$STATE/artifacts/role-none/from-profile.md" ]
  [ "$(jq -r '.outcome' "$STATE/artifacts/role-none/stage-outcomes/attempt1.json")" = "success" ]
}

@test "graph_dispatch_build_argv sets RALPH_ARTIFACT_ROOT and the other three G12 roots as an explicit env prefix" {
  source "$BATS_TEST_DIRNAME/../../../bundle/.ralph/bash-lib/error-handling.sh"
  source "$GRAPH_DISPATCH_SH"
  _gar_write_stage_plan_and_orch ""

  RALPH_PROJECT_ROOT="$PROJECT" RALPH_AGENT_WORKSPACE="$AGENTWS" \
    graph_dispatch_build_argv "$ORCH_JSON" art run1 attempt1 "$AGENTWS" "$STATE"

  local joined
  joined="${GRAPH_DISPATCH_ARGV[*]}"
  [[ "$joined" == *"RALPH_PROJECT_ROOT=${PROJECT}"* ]]
  [[ "$joined" == *"RALPH_PLAN_WORKSPACE_ROOT=${STATE}"* ]]
  [[ "$joined" == *"RALPH_AGENT_WORKSPACE=${AGENTWS}"* ]]
  [[ "$joined" == *"RALPH_ARTIFACT_ROOT=${STATE}/artifacts/art-ns"* ]]
}

@test "graph_dispatch_build_argv projects graph retry number for planner publication" {
  source "$BATS_TEST_DIRNAME/../../../bundle/.ralph/bash-lib/error-handling.sh"
  source "$GRAPH_DISPATCH_SH"
  _gar_write_stage_plan_and_orch ""

  export RALPH_WORKFLOW_REGISTRY_RUN="$TMPD/workflow-run"
  export RALPH_WORKFLOW_RUN_ID="run-20260901T000000Z-0-retry"
  mkdir -p "$RALPH_WORKFLOW_REGISTRY_RUN"

  RALPH_PROJECT_ROOT="$PROJECT" RALPH_AGENT_WORKSPACE="$AGENTWS" \
    graph_dispatch_build_argv \
      "$ORCH_JSON" art "$RALPH_WORKFLOW_RUN_ID" \
      "art__${RALPH_WORKFLOW_RUN_ID}__3" "$AGENTWS" "$STATE"

  printf '%s\n' "${GRAPH_DISPATCH_ARGV[@]}" \
    | grep -qxF 'RALPH_WORKFLOW_STAGE_ATTEMPT=3'
}
