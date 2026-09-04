#!/usr/bin/env bats
# Covers TODO: inject the prior review's verdict feedback into each reworked
# node's plan at dispatch time (_graph_dispatch_inject_rework_feedback in
# bundle/.ralph/bash-lib/graph/graph-dispatch.sh).

source "$BATS_TEST_DIRNAME/../helper/load-lib.bash"
source "$BATS_TEST_DIRNAME/../../../bundle/.ralph/bash-lib/plan-todo.sh"
source "$BATS_TEST_DIRNAME/../../../bundle/.ralph/bash-lib/graph/graph-run-base.sh"
source "$BATS_TEST_DIRNAME/../../../bundle/.ralph/bash-lib/graph/graph-schedule.sh"

STUB_RUN_PLAN="$BATS_TEST_DIRNAME/../../fixtures/orchestrator-single-stage/run-plan-stub.sh"
RALPH_DIR_SRC="$REPO_ROOT/bundle/.ralph"

# The evaluator contract helper is resolved from RALPH_ACTIVE_DIR / RALPH_DIR /
# SCRIPT_DIR. Tests that build their own minimal workspace instead of calling
# setup_rework_dispatch_workspace still need it pointed at the real helpers.
setup() {
  export RALPH_DIR="$REPO_ROOT/.ralph"
}

json_payload() {
  printf '%s\n' "$1" | awk 'END{print}'
}

# Prepare a scratch workspace with a stubbed run-plan, plus a bundle/.ralph
# schema mirror so the graph-mode rework literal schema constant
# ("bundle/.ralph/schemas/evaluator-verdict.schema.json", project-root
# relative) resolves the same way it does in this repo's own self-hosted
# pipelines.
setup_rework_dispatch_workspace() {
  local tmpd="$1"
  DISPATCH_WORKSPACE="$tmpd/workspace"
  mkdir -p "$DISPATCH_WORKSPACE/.ralph" "$DISPATCH_WORKSPACE/.ralph-workspace"

  cp -R "$RALPH_DIR_SRC"/* "$DISPATCH_WORKSPACE/.ralph/"
  chmod +x "$DISPATCH_WORKSPACE/.ralph"/*.sh 2>/dev/null || true
  chmod +x "$DISPATCH_WORKSPACE/.ralph/bash-lib"/*/*.sh 2>/dev/null || true

  cp "$STUB_RUN_PLAN" "$DISPATCH_WORKSPACE/.ralph/run-plan.sh"
  chmod +x "$DISPATCH_WORKSPACE/.ralph/run-plan.sh"

  mkdir -p "$DISPATCH_WORKSPACE/bundle/.ralph/schemas"
  cp "$RALPH_DIR_SRC/schemas/evaluator-verdict.schema.json" \
    "$DISPATCH_WORKSPACE/bundle/.ralph/schemas/evaluator-verdict.schema.json"

  export GRAPH_DISPATCH_ORCHESTRATOR="$DISPATCH_WORKSPACE/.ralph/orchestrator.sh"
  export RALPH_ALLOW_NESTED_RUNS=1
  export ORCHESTRATOR_RUNNER_TO_CONSOLE=0
  export RALPH_MODE=no
  export RALPH_ARTIFACT_SCHEMA_VALIDATION=0
  export RALPH_ARTIFACT_PROVENANCE=0
  export RALPH_DIR="$REPO_ROOT/.ralph"
  export RALPH_PLAN_WORKSPACE_ROOT="$DISPATCH_WORKSPACE/.ralph-workspace"
  unset RALPH_ARTIFACT_NS 2>/dev/null || true
  unset RALPH_PLAN_KEY 2>/dev/null || true
}

write_rework_plan() {
  # $1 = destination plan path
  cat >"$1" <<'PLAN'
---
execution: graph
pipeline:
  stages:
    - id: implement
      runtime: cursor
      instructions: Implement the change end to end.
      produces:
        - path: shared/output.md
    - id: review
      runtime: cursor
      instructions: Review the change and return a verdict.
      dependsOn:
        - implement
      produces:
        - path: .ralph-workspace/artifacts/{{ARTIFACT_NS}}/review/verdict.json
          schema: bundle/.ralph/schemas/evaluator-verdict.schema.json
      loopBackTo: implement
      maxIterations: 1
      loopCheck:
        path: .ralph-workspace/artifacts/{{ARTIFACT_NS}}/review/verdict.json
        schema: bundle/.ralph/schemas/evaluator-verdict.schema.json
todos:
  - id: implement-1
    stage: implement
    content: implement the feature
    status: pending
  - id: review-1
    stage: review
    content: review the feature
    status: pending
---
PLAN
}

# Recomputes the exact rendered inline-plan path graph_dispatch_materialize_orch
# assigns a node id, matching its own plan_abs formula (index-based file name).
rework_node_plan_abs() {
  local graph_file="$1" workspace="$2" namespace="$3" node_id="$4"
  local idx
  idx="$(jq --arg id "$node_id" '[.nodes[].id] | index($id)' "$graph_file")"
  printf '%s/orchestration-plans/%s/%s\n' "$workspace" "$namespace" \
    "$(printf '%s-%02d-%s.plan.md' "$namespace" "$((idx + 1))" "$node_id")"
}

@test "rework target dispatch injects prior review verdict feedback into its rendered plan" {
  tmpd="$(mktemp -d)"
  setup_rework_dispatch_workspace "$tmpd"

  plan_file="$DISPATCH_WORKSPACE/rework.plan.md"
  write_rework_plan "$plan_file"

  graph_file="$tmpd/rework.graph.json"
  plan_pipeline_graph_json "$plan_file" >"$graph_file"

  namespace="$(jq -r '.namespace' "$graph_file")"
  state_root="$DISPATCH_WORKSPACE/.ralph-workspace"
  verdict_dir="$state_root/artifacts/$namespace/review"
  mkdir -p "$verdict_dir"
  printf '%s' '{"status":"changes-required","feedback":["fix the parser"]}' >"$verdict_dir/verdict.json"

  export RUN_PLAN_STUB_EXIT_CODE=0
  export RUN_PLAN_STUB_WRITE_ARTIFACTS="shared/output.md"
  unset RUN_PLAN_STUB_SLEEP_SECONDS RUN_PLAN_STUB_READY_FILE 2>/dev/null || true

  capture_dir="$tmpd/captures"
  mkdir -p "$capture_dir"
  export RALPH_RUN_PLAN_CAPTURE_FILE="$capture_dir/attempt-1.json"

  run graph_dispatch_run_node "$graph_file" "implement-r1" "run-A" "1" "$DISPATCH_WORKSPACE"
  [ "$status" -eq 0 ]
  [ -f "$capture_dir/attempt-1.json" ]

  plan_abs="$(rework_node_plan_abs "$graph_file" "$DISPATCH_WORKSPACE" "$namespace" "implement-r1")"
  [ -f "$plan_abs" ]
  grep -Fq -- "<!-- RALPH_EVALUATOR_FEEDBACK: START -->" "$plan_abs"
  grep -Fq -- "fix the parser" "$plan_abs"
  [ "$(grep -c -- '<!-- RALPH_EVALUATOR_FEEDBACK: START -->' "$plan_abs")" -eq 1 ]

  # A second dispatch re-renders a single block from the accumulated defect
  # ledger. New feedback is added; the earlier finding stays open because this
  # reviewer never dispositioned it. Dropping it here is what previously let a
  # defect survive the rework round meant to fix it.
  printf '%s' '{"status":"changes-required","feedback":["fix the lexer instead"]}' >"$verdict_dir/verdict.json"
  export RALPH_RUN_PLAN_CAPTURE_FILE="$capture_dir/attempt-2.json"
  run graph_dispatch_run_node "$graph_file" "implement-r1" "run-A" "2" "$DISPATCH_WORKSPACE"
  [ "$status" -eq 0 ]
  [ -f "$capture_dir/attempt-2.json" ]

  grep -Fq -- "fix the lexer instead" "$plan_abs"
  grep -Fq -- "fix the parser" "$plan_abs"
  [ "$(grep -c -- '<!-- RALPH_EVALUATOR_FEEDBACK: START -->' "$plan_abs")" -eq 1 ]
  [ -f "$verdict_dir/defect-ledger.json" ]
  [ "$(jq '[.findings[] | select(.disposition == "open")] | length' "$verdict_dir/defect-ledger.json")" -eq 2 ]

  # Dispatching an unrelated node (which also triggers materialization of
  # every not-yet-rendered inline plan in the graph) must not re-render or
  # overwrite implement-r1's plan.
  before_checksum="$(cksum <"$plan_abs")"
  export RALPH_RUN_PLAN_CAPTURE_FILE="$capture_dir/attempt-unrelated.json"
  run graph_dispatch_run_node "$graph_file" "implement" "run-A" "1" "$DISPATCH_WORKSPACE"
  [ "$status" -eq 0 ]
  after_checksum="$(cksum <"$plan_abs")"
  [ "$before_checksum" = "$after_checksum" ]

  unset RALPH_PLAN_WORKSPACE_ROOT
  rm -rf "$tmpd"
}

@test "authoritative dispatch of a rework node fails before model invocation when the required verdict is missing" {
  tmpd="$(mktemp -d)"
  setup_rework_dispatch_workspace "$tmpd"

  plan_file="$DISPATCH_WORKSPACE/rework.plan.md"
  write_rework_plan "$plan_file"

  graph_file="$tmpd/rework.graph.json"
  plan_pipeline_graph_json "$plan_file" >"$graph_file"

  # Deliberately do not seed the review verdict artifact.
  export RUN_PLAN_STUB_EXIT_CODE=0
  unset RUN_PLAN_STUB_WRITE_ARTIFACTS RUN_PLAN_STUB_SLEEP_SECONDS RUN_PLAN_STUB_READY_FILE 2>/dev/null || true

  capture_dir="$tmpd/captures"
  mkdir -p "$capture_dir"
  export RALPH_RUN_PLAN_CAPTURE_FILE="$capture_dir/attempt-1.json"

  run graph_dispatch_run_node "$graph_file" "implement-r1" "run-A" "1" "$DISPATCH_WORKSPACE"
  [ "$status" -ne 0 ]
  # The child (run-plan stub) must never have been invoked: no capture file.
  [ ! -f "$capture_dir/attempt-1.json" ]

  unset RALPH_PLAN_WORKSPACE_ROOT
  rm -rf "$tmpd"
}

# --- Dependency provided-plan rework: fresh control + feedback, source frozen ---

@test "provided-plan rework injects prior verdict into fresh control copy with original unchanged" {
  # shellcheck source=/dev/null
  source "$REPO_ROOT/bundle/.ralph/bash-lib/workflow/workflow-state.sh"
  # shellcheck source=/dev/null
  source "$REPO_ROOT/bundle/.ralph/bash-lib/graph/graph-compile.sh"
  # shellcheck source=/dev/null
  source "$REPO_ROOT/bundle/.ralph/bash-lib/graph/graph-dispatch.sh"

  tmpd="$(mktemp -d)"
  state_root="$tmpd/state"
  project="$tmpd/project"
  mkdir -p "$state_root" "$project/plans"

  cat >"$project/plans/feature.plan.md" <<'EOF'
# Feature plan

- [x] already done by operator
- [ ] implement the change
- [ ] verify the change
EOF
  original="$project/plans/feature.plan.md"
  before_orig="$(cksum "$original" | awk '{print $1" "$2}')"

  export WORKFLOW_STATE_SKIP_FSYNC=1
  export WORKFLOW_STATE_FIXED_NOW="2026-01-05T01:00:00Z"
  printf '{"pipeline":{"stages":[{"id":"implement"}]}}\n' >"$tmpd/input.orch.json"
  printf '%s\n' '---' 'kind: workflow' 'mode: dependency' '---' >"$tmpd/wf.md"

  run_id="$(
    workflow_state_create \
      --state-root "$state_root" \
      --source-path "$tmpd/wf.md" \
      --source-kind project \
      --mode dependency \
      --entry-kind plan \
      --task "Execute supplied plan" \
      --task-provenance plan-filename \
      --input-file "$tmpd/input.orch.json" \
      --workflow-id plan-delivery \
      --engine-namespace plan-delivery
  )"
  workflow_state_import_provided_plan \
    --state-root "$state_root" \
    --run-id "$run_id" \
    --plan "$original" \
    --project-root "$project" >/dev/null
  source_plan="$state_root/workflow-runs/$run_id/plans/input/source.plan.md"
  before_source="$(cksum "$source_plan" | awk '{print $1" "$2}')"

  # First consumer attempt control (simulates prior progress on implement).
  binding0="$(
    workflow_state_bind_provided_plan_control \
      --registry-run "$state_root/workflow-runs/$run_id" \
      --consumer-stage-id implement \
      --consumer-attempt 1
  )"
  control0="$(printf '%s' "$binding0" | jq -r '.controlPlanPath')"
  python3 - "$control0" <<'PY'
from pathlib import Path
import re, sys
p = Path(sys.argv[1])
text = p.read_text(encoding="utf-8")
text2, n = re.subn(r"- \[ \] implement the change", "- [x] implement the change", text, count=1)
assert n == 1
p.write_text(text2, encoding="utf-8")
PY

  graph_file="$tmpd/provided-rework.graph.json"
  cat >"$graph_file" <<'EOF'
{
  "schemaVersion": 1,
  "name": "pd",
  "namespace": "ns",
  "nodes": [
    {
      "id": "implement",
      "type": "agent",
      "dependsOn": [],
      "derivedFrom": "stage",
      "stage": {"id": "implement", "runtime": "cursor"}
    },
    {
      "id": "review",
      "type": "agent",
      "dependsOn": ["implement"],
      "derivedFrom": "stage",
      "stage": {
        "id": "review",
        "runtime": "cursor",
        "loopCheck": {
          "path": ".ralph-workspace/artifacts/{{ARTIFACT_NS}}/review/verdict.json",
          "schema": "bundle/.ralph/schemas/evaluator-verdict.schema.json"
        }
      }
    },
    {
      "id": "implement-r1",
      "type": "agent",
      "dependsOn": ["review"],
      "derivedFrom": "rework",
      "stage": {"id": "implement-r1", "runtime": "cursor"}
    }
  ],
  "edges": []
}
EOF
  graph_compile_freeze_provided_plan_bindings "$graph_file" "implement" >/dev/null

  # Rework clone: fresh control from frozen source (not sibling control0).
  binding_r="$(
    workflow_state_bind_provided_plan_control \
      --registry-run "$state_root/workflow-runs/$run_id" \
      --consumer-stage-id implement-r1 \
      --consumer-attempt 1 \
      --force-fresh
  )"
  control_r="$(printf '%s' "$binding_r" | jq -r '.controlPlanPath')"
  [ "$(printf '%s' "$binding_r" | jq -r '.planSourceKind')" = "provided" ]
  [ "$(printf '%s' "$binding_r" | jq -r '.createdControl')" = "true" ]
  [ "$(printf '%s' "$binding_r" | jq -r '.completedTodos')" = "1" ]
  grep -q '\- \[ \] implement the change' "$control_r"
  # Sibling implement control remains at its progressed state.
  grep -q '\- \[x\] implement the change' "$control0"

  orch="$tmpd/r1.orch.json"
  cat >"$orch" <<EOF
{
  "name": "pd",
  "namespace": "ns",
  "stages": [
    {"id": "implement-r1", "runtime": "cursor", "plan": "$control_r"}
  ]
}
EOF

  mkdir -p "$state_root/artifacts/ns/review"
  printf '%s' '{"status":"changes-required","feedback":["fix the provided-plan parser"]}' \
    >"$state_root/artifacts/ns/review/verdict.json"

  mkdir -p "$tmpd/workspace/bundle/.ralph/schemas"
  cp "$REPO_ROOT/bundle/.ralph/schemas/evaluator-verdict.schema.json" \
    "$tmpd/workspace/bundle/.ralph/schemas/evaluator-verdict.schema.json"

  run _graph_dispatch_inject_rework_feedback \
    "$graph_file" "implement-r1" "$tmpd/workspace" "ns" "$state_root" \
    "$tmpd/workspace" "$orch"
  [ "$status" -eq 0 ]
  grep -Fq -- "<!-- RALPH_EVALUATOR_FEEDBACK: START -->" "$control_r"
  grep -Fq -- "fix the provided-plan parser" "$control_r"
  ! grep -Fq -- "RALPH_EVALUATOR_FEEDBACK" "$source_plan"
  ! grep -Fq -- "RALPH_EVALUATOR_FEEDBACK" "$original"

  after_source="$(cksum "$source_plan" | awk '{print $1" "$2}')"
  after_orig="$(cksum "$original" | awk '{print $1" "$2}')"
  [ "$before_source" = "$after_source" ]
  [ "$before_orig" = "$after_orig" ]

  rm -rf "$tmpd"
}

# --- Generated planFrom rework: frozen planner, fresh control, prior verdict ---

write_planner_v2_artifact_for_rework() {
  local dest="$1"
  mkdir -p "$(dirname -- "$dest")"
  cat >"$dest" <<'EOF'
{
  "schemaVersion": 2,
  "name": "generated-rework-demo",
  "overview": "Implement the demo change from planner JSON",
  "rationale": "Fewest independently verifiable TODOs for the demo.",
  "todos": [
    {
      "id": "implement-core",
      "content": "Update owned files for the demo change.",
      "verification": "test -f README.md",
      "status": "pending"
    },
    {
      "id": "verify-tests",
      "content": "Run the narrow unit tests.",
      "verification": "true",
      "status": "pending"
    }
  ]
}
EOF
  printf '%s\n' "$dest"
}

setup_planfrom_rework_registry() {
  # Sets REGISTRY_RUN, SOURCE_PLAN, GRAPH_FILE for generated planFrom rework tests.
  local tmpd="$1"
  local state_root="$tmpd/state"
  local project="$tmpd/project"
  mkdir -p "$state_root" "$project"

  export WORKFLOW_STATE_SKIP_FSYNC=1
  export WORKFLOW_STATE_FIXED_NOW="2026-01-06T01:00:00Z"
  printf '{"pipeline":{"stages":[{"id":"implement"}]}}\n' >"$tmpd/input.orch.json"
  printf '%s\n' '---' 'kind: workflow' 'mode: dependency' '---' >"$tmpd/wf.md"

  local run_id
  run_id="$(
    workflow_state_create \
      --state-root "$state_root" \
      --source-path "$tmpd/wf.md" \
      --source-kind project \
      --mode dependency \
      --entry-kind task \
      --task "Execute generated plan with rework" \
      --task-provenance explicit \
      --input-file "$tmpd/input.orch.json" \
      --workflow-id bug-fix \
      --engine-namespace bug-fix
  )"
  REGISTRY_RUN="$state_root/workflow-runs/$run_id"
  local artifact
  artifact="$(write_planner_v2_artifact_for_rework "$tmpd/planner.json")"
  SOURCE_PLAN="$(
    workflow_state_materialize_generated_plan \
      --registry-run "$REGISTRY_RUN" \
      --planner-stage-id plan-implementation \
      --attempt 1 \
      --artifact "$artifact" \
      --max-todos 40 \
      --default-runtime cursor \
      --default-model auto
  )"

  GRAPH_FILE="$tmpd/planfrom-rework.graph.json"
  cat >"$GRAPH_FILE" <<'EOF'
{
  "schemaVersion": 1,
  "name": "pf",
  "namespace": "ns",
  "nodes": [
    {
      "id": "plan-implementation",
      "type": "agent",
      "dependsOn": [],
      "derivedFrom": "stage",
      "stage": {"id": "plan-implementation", "runtime": "cursor"}
    },
    {
      "id": "implement",
      "type": "agent",
      "dependsOn": ["plan-implementation"],
      "derivedFrom": "stage",
      "stage": {"id": "implement", "runtime": "cursor", "planFrom": "plan-implementation"},
      "planFromBinding": {"plannerStageId": "plan-implementation", "planSourceKind": "generated"}
    },
    {
      "id": "review",
      "type": "agent",
      "dependsOn": ["implement"],
      "derivedFrom": "stage",
      "stage": {
        "id": "review",
        "runtime": "cursor",
        "loopCheck": {
          "path": ".ralph-workspace/artifacts/{{ARTIFACT_NS}}/review/verdict.json",
          "schema": "bundle/.ralph/schemas/evaluator-verdict.schema.json"
        }
      }
    },
    {
      "id": "implement-r1",
      "type": "agent",
      "dependsOn": ["review"],
      "derivedFrom": "rework",
      "stage": {"id": "implement-r1", "runtime": "cursor", "planFrom": "plan-implementation"},
      "planFromBinding": {"plannerStageId": "plan-implementation", "planSourceKind": "generated"}
    }
  ],
  "edges": []
}
EOF
}

@test "plan-backed rework fresh control copy injects prior verdict without mutating source" {
  # shellcheck source=/dev/null
  source "$REPO_ROOT/bundle/.ralph/bash-lib/workflow/workflow-state.sh"
  # shellcheck source=/dev/null
  source "$REPO_ROOT/bundle/.ralph/bash-lib/graph/graph-dispatch.sh"

  tmpd="$(mktemp -d)"
  setup_planfrom_rework_registry "$tmpd"
  local before_source control0 control_r binding_r orch
  before_source="$(cksum "$SOURCE_PLAN" | awk '{print $1" "$2}')"

  # Original consumer progresses one TODO on its own control.
  binding0="$(
    workflow_state_bind_generated_plan_control \
      --registry-run "$REGISTRY_RUN" \
      --consumer-stage-id implement \
      --consumer-attempt 1 \
      --planner-stage-id plan-implementation \
      --planner-attempt 1
  )"
  control0="$(printf '%s' "$binding0" | jq -r '.controlPlanPath')"
  python3 - "$control0" <<'PY'
from pathlib import Path
import re, sys
p = Path(sys.argv[1])
text = p.read_text(encoding="utf-8")
text2, n = re.subn(
    r"(  - id: implement-core\n(?:.*\n)*?    status: )pending",
    r"\1completed",
    text,
    count=1,
)
assert n == 1
p.write_text(text2, encoding="utf-8")
PY

  # Rework clone: fresh control from same immutable source (all pending).
  binding_r="$(
    workflow_state_bind_generated_plan_control \
      --registry-run "$REGISTRY_RUN" \
      --consumer-stage-id implement-r1 \
      --consumer-attempt 1 \
      --planner-stage-id plan-implementation \
      --planner-attempt 1 \
      --force-fresh
  )"
  control_r="$(printf '%s' "$binding_r" | jq -r '.controlPlanPath')"
  [ "$(printf '%s' "$binding_r" | jq -r '.planSourceKind')" = "generated" ]
  [ "$(printf '%s' "$binding_r" | jq -r '.planSourceStageId')" = "plan-implementation" ]
  [ "$(printf '%s' "$binding_r" | jq -r '.createdControl')" = "true" ]
  [ "$(printf '%s' "$binding_r" | jq -r '.completedTodos')" = "0" ]
  [ "$(printf '%s' "$binding_r" | jq -r '.currentTodoId')" = "implement-core" ]
  grep -q 'status: pending' "$control_r"
  # Sibling original control remains progressed.
  grep -q 'status: completed' "$control0"
  [ "$control0" != "$control_r" ]

  orch="$tmpd/r1.orch.json"
  cat >"$orch" <<EOF
{
  "name": "pf",
  "namespace": "ns",
  "stages": [
    {"id": "implement-r1", "runtime": "cursor", "plan": "$control_r"}
  ]
}
EOF

  mkdir -p "$tmpd/state/artifacts/ns/review"
  printf '%s' '{"status":"changes-required","feedback":["fix the generated-plan parser"]}' \
    >"$tmpd/state/artifacts/ns/review/verdict.json"

  mkdir -p "$tmpd/workspace/bundle/.ralph/schemas"
  cp "$REPO_ROOT/bundle/.ralph/schemas/evaluator-verdict.schema.json" \
    "$tmpd/workspace/bundle/.ralph/schemas/evaluator-verdict.schema.json"

  run _graph_dispatch_inject_rework_feedback \
    "$GRAPH_FILE" "implement-r1" "$tmpd/workspace" "ns" "$tmpd/state" \
    "$tmpd/workspace" "$orch"
  [ "$status" -eq 0 ]
  grep -Fq -- "<!-- RALPH_EVALUATOR_FEEDBACK: START -->" "$control_r"
  grep -Fq -- "fix the generated-plan parser" "$control_r"
  ! grep -Fq -- "RALPH_EVALUATOR_FEEDBACK" "$SOURCE_PLAN"
  ! grep -Fq -- "RALPH_EVALUATOR_FEEDBACK" "$control0"

  after_source="$(cksum "$SOURCE_PLAN" | awk '{print $1" "$2}')"
  [ "$before_source" = "$after_source" ]
  [ ! -w "$SOURCE_PLAN" ]

  rm -rf "$tmpd"
}

@test "plan-backed rework isolated checkboxes prove original and sibling controls do not change" {
  # shellcheck source=/dev/null
  source "$REPO_ROOT/bundle/.ralph/bash-lib/workflow/workflow-state.sh"

  tmpd="$(mktemp -d)"
  setup_planfrom_rework_registry "$tmpd"

  binding0="$(
    workflow_state_bind_generated_plan_control \
      --registry-run "$REGISTRY_RUN" \
      --consumer-stage-id implement \
      --consumer-attempt 1 \
      --planner-stage-id plan-implementation \
      --planner-attempt 1
  )"
  control0="$(printf '%s' "$binding0" | jq -r '.controlPlanPath')"
  python3 - "$control0" <<'PY'
from pathlib import Path
import re, sys
p = Path(sys.argv[1])
text = p.read_text(encoding="utf-8")
text2, n = re.subn(
    r"(  - id: implement-core\n(?:.*\n)*?    status: )pending",
    r"\1completed",
    text,
    count=1,
)
assert n == 1
p.write_text(text2, encoding="utf-8")
PY
  before0="$(cksum "$control0" | awk '{print $1" "$2}')"

  binding_r1="$(
    workflow_state_bind_generated_plan_control \
      --registry-run "$REGISTRY_RUN" \
      --consumer-stage-id implement-r1 \
      --consumer-attempt 1 \
      --planner-stage-id plan-implementation \
      --planner-attempt 1 \
      --force-fresh
  )"
  control_r1="$(printf '%s' "$binding_r1" | jq -r '.controlPlanPath')"
  # Progress only the clone; original must stay byte-identical.
  python3 - "$control_r1" <<'PY'
from pathlib import Path
import re, sys
p = Path(sys.argv[1])
text = p.read_text(encoding="utf-8")
text2, n = re.subn(
    r"(  - id: verify-tests\n(?:.*\n)*?    status: )pending",
    r"\1completed",
    text,
    count=1,
)
assert n == 1
p.write_text(text2, encoding="utf-8")
PY

  after0="$(cksum "$control0" | awk '{print $1" "$2}')"
  [ "$before0" = "$after0" ]
  [ "$(workflow_state_plan_progress_json "$control0" | jq -r '.completedTodos')" = "1" ]
  [ "$(workflow_state_plan_progress_json "$control_r1" | jq -r '.completedTodos')" = "1" ]
  [ "$(workflow_state_plan_progress_json "$control0" | jq -r '.currentTodoId')" = "verify-tests" ]
  [ "$(workflow_state_plan_progress_json "$control_r1" | jq -r '.currentTodoId')" = "implement-core" ]

  rm -rf "$tmpd"
}

@test "plan-backed rework missing prior verdict fails closed before model invocation" {
  # shellcheck source=/dev/null
  source "$REPO_ROOT/bundle/.ralph/bash-lib/workflow/workflow-state.sh"
  # shellcheck source=/dev/null
  source "$REPO_ROOT/bundle/.ralph/bash-lib/graph/graph-dispatch.sh"

  tmpd="$(mktemp -d)"
  setup_planfrom_rework_registry "$tmpd"

  binding_r="$(
    workflow_state_bind_generated_plan_control \
      --registry-run "$REGISTRY_RUN" \
      --consumer-stage-id implement-r1 \
      --consumer-attempt 1 \
      --planner-stage-id plan-implementation \
      --planner-attempt 1 \
      --force-fresh
  )"
  control_r="$(printf '%s' "$binding_r" | jq -r '.controlPlanPath')"
  orch="$tmpd/r1.orch.json"
  cat >"$orch" <<EOF
{
  "name": "pf",
  "namespace": "ns",
  "stages": [
    {"id": "implement-r1", "runtime": "cursor", "plan": "$control_r"}
  ]
}
EOF

  mkdir -p "$tmpd/workspace/bundle/.ralph/schemas"
  cp "$REPO_ROOT/bundle/.ralph/schemas/evaluator-verdict.schema.json" \
    "$tmpd/workspace/bundle/.ralph/schemas/evaluator-verdict.schema.json"
  # Deliberately omit the review verdict artifact.

  run _graph_dispatch_inject_rework_feedback \
    "$GRAPH_FILE" "implement-r1" "$tmpd/workspace" "ns" "$tmpd/state" \
    "$tmpd/workspace" "$orch"
  [ "$status" -ne 0 ]
  [[ "$output" == *"verdict"* ]] || [[ "$output" == *"missing"* ]]

  rm -rf "$tmpd"
}

@test "plan-backed rework source hash failure blocks fresh control copy" {
  # shellcheck source=/dev/null
  source "$REPO_ROOT/bundle/.ralph/bash-lib/workflow/workflow-state.sh"

  tmpd="$(mktemp -d)"
  setup_planfrom_rework_registry "$tmpd"
  local manifest
  manifest="$REGISTRY_RUN/plans/plan-implementation/attempt-1.manifest.json"

  chmod u+w "$SOURCE_PLAN"
  printf '\n# tampered\n' >>"$SOURCE_PLAN"

  run workflow_state_bind_generated_plan_control \
    --registry-run "$REGISTRY_RUN" \
    --consumer-stage-id implement-r1 \
    --consumer-attempt 1 \
    --planner-stage-id plan-implementation \
    --planner-attempt 1 \
    --force-fresh
  [ "$status" -ne 0 ]
  [[ "$output" == *"hash"* ]] || [[ "$output" == *"stale"* ]] || [[ "$output" == *"mismatch"* ]]
  [ ! -e "$REGISTRY_RUN/plans/implement-r1/attempt-1/control.plan.md" ]

  run workflow_state_validate_generated_plan_evidence "$manifest" \
    --expect-planner-stage-id plan-implementation
  [ "$status" -ne 0 ]

  rm -rf "$tmpd"
}

@test "provided-plan regression rework remains accepted with frozen source" {
  # Regression fixture: provided-plan rework path stays accepted after
  # generated planFrom rework support lands.
  # shellcheck source=/dev/null
  source "$REPO_ROOT/bundle/.ralph/bash-lib/workflow/workflow-state.sh"
  # shellcheck source=/dev/null
  source "$REPO_ROOT/bundle/.ralph/bash-lib/graph/graph-compile.sh"
  # shellcheck source=/dev/null
  source "$REPO_ROOT/bundle/.ralph/bash-lib/graph/graph-dispatch.sh"

  tmpd="$(mktemp -d)"
  state_root="$tmpd/state"
  project="$tmpd/project"
  mkdir -p "$state_root" "$project/plans"

  cat >"$project/plans/feature.plan.md" <<'EOF'
# Feature plan

- [x] already done by operator
- [ ] implement the change
- [ ] verify the change
EOF
  original="$project/plans/feature.plan.md"

  export WORKFLOW_STATE_SKIP_FSYNC=1
  export WORKFLOW_STATE_FIXED_NOW="2026-01-07T01:00:00Z"
  printf '{"pipeline":{"stages":[{"id":"implement"}]}}\n' >"$tmpd/input.orch.json"
  printf '%s\n' '---' 'kind: workflow' 'mode: dependency' '---' >"$tmpd/wf.md"

  run_id="$(
    workflow_state_create \
      --state-root "$state_root" \
      --source-path "$tmpd/wf.md" \
      --source-kind project \
      --mode dependency \
      --entry-kind plan \
      --task "Execute supplied plan" \
      --task-provenance plan-filename \
      --input-file "$tmpd/input.orch.json" \
      --workflow-id plan-delivery \
      --engine-namespace plan-delivery
  )"
  workflow_state_import_provided_plan \
    --state-root "$state_root" \
    --run-id "$run_id" \
    --plan "$original" \
    --project-root "$project" >/dev/null
  source_plan="$state_root/workflow-runs/$run_id/plans/input/source.plan.md"
  before_source="$(cksum "$source_plan" | awk '{print $1" "$2}')"

  graph_file="$tmpd/provided-regression.graph.json"
  cat >"$graph_file" <<'EOF'
{
  "schemaVersion": 1,
  "name": "pd",
  "namespace": "ns",
  "nodes": [
    {
      "id": "implement",
      "type": "agent",
      "dependsOn": [],
      "derivedFrom": "stage",
      "stage": {"id": "implement", "runtime": "cursor"}
    },
    {
      "id": "review",
      "type": "agent",
      "dependsOn": ["implement"],
      "derivedFrom": "stage",
      "stage": {
        "id": "review",
        "runtime": "cursor",
        "loopCheck": {
          "path": ".ralph-workspace/artifacts/{{ARTIFACT_NS}}/review/verdict.json",
          "schema": "bundle/.ralph/schemas/evaluator-verdict.schema.json"
        }
      }
    },
    {
      "id": "implement-r1",
      "type": "agent",
      "dependsOn": ["review"],
      "derivedFrom": "rework",
      "stage": {"id": "implement-r1", "runtime": "cursor"}
    }
  ],
  "edges": []
}
EOF
  graph_compile_freeze_provided_plan_bindings "$graph_file" "implement" >/dev/null

  binding_r="$(
    workflow_state_bind_provided_plan_control \
      --registry-run "$state_root/workflow-runs/$run_id" \
      --consumer-stage-id implement-r1 \
      --consumer-attempt 1 \
      --force-fresh
  )"
  control_r="$(printf '%s' "$binding_r" | jq -r '.controlPlanPath')"
  [ "$(printf '%s' "$binding_r" | jq -r '.planSourceKind')" = "provided" ]
  [ "$(printf '%s' "$binding_r" | jq -r '.createdControl')" = "true" ]

  orch="$tmpd/r1.orch.json"
  cat >"$orch" <<EOF
{
  "name": "pd",
  "namespace": "ns",
  "stages": [
    {"id": "implement-r1", "runtime": "cursor", "plan": "$control_r"}
  ]
}
EOF

  mkdir -p "$state_root/artifacts/ns/review"
  printf '%s' '{"status":"changes-required","feedback":["regression: keep provided-plan rework"]}' \
    >"$state_root/artifacts/ns/review/verdict.json"
  mkdir -p "$tmpd/workspace/bundle/.ralph/schemas"
  cp "$REPO_ROOT/bundle/.ralph/schemas/evaluator-verdict.schema.json" \
    "$tmpd/workspace/bundle/.ralph/schemas/evaluator-verdict.schema.json"

  run _graph_dispatch_inject_rework_feedback \
    "$graph_file" "implement-r1" "$tmpd/workspace" "ns" "$state_root" \
    "$tmpd/workspace" "$orch"
  [ "$status" -eq 0 ]
  grep -Fq -- "regression: keep provided-plan rework" "$control_r"
  after_source="$(cksum "$source_plan" | awk '{print $1" "$2}')"
  [ "$before_source" = "$after_source" ]

  rm -rf "$tmpd"
}
