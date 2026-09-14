#!/usr/bin/env bats
# `ralph workflow inspect` argv, exit, output, and no-mutation contracts.
#
# These cases invoke the workflow CLI only. They use tiny fixtures, never run an
# engine or a runtime, and assert that inspect creates no registry entry, control
# plan, compile cache, log, or agent workspace.

source "$BATS_TEST_DIRNAME/../helper/load-lib.bash"

CLI="$REPO_ROOT/bundle/.ralph/workflow-cli.sh"

# `! cmd` is exempt from set -e, so a bare negation can never fail a bats test.
refute_cmd() {
  if "$@"; then
    echo "refute_cmd: expected failure but command succeeded: $*" >&2
    return 1
  fi
  return 0
}

refute_start_flag() {
  case "$1" in
    *"$2"*)
      echo "refute_start_flag: usage unexpectedly advertises $2" >&2
      return 1
      ;;
  esac
  return 0
}

setup_file() {
  command -v python3 >/dev/null || skip "python3 required"
  [ -f "$CLI" ]
}

setup() {
  TMPD="$(mktemp -d)"
  PROJECT="$TMPD/project"
  STATE="$PROJECT/.ralph-workspace"
  mkdir -p "$STATE/plans" "$STATE/workflows"
}

teardown() {
  [ -n "${TMPD:-}" ] && rm -rf "$TMPD"
}

inspect() {
  run env RALPH_PROJECT_ROOT="$PROJECT" RALPH_PLAN_WORKSPACE_ROOT="$STATE" \
    RALPH_HOME="$TMPD/home" bash "$CLI" inspect "$@"
}

# A dependency workflow that generates a plan, executes it, gates it, and
# integrates it. Small enough to assert on exactly.
write_dependency_workflow() {
  cat >"$1" <<'EOF'
---
name: dep-demo
overview: Dependency demo workflow
kind: workflow
mode: dependency
pipeline:
  maxReworkIterations: 2
  publishMode: on-verified
  stages:
    - id: plan-implementation
      instructions: |
        Plan {{TASK}}.
      planner:
        outputMode: plan-file
        maxTodos: 40
      produces:
        - path: .ralph-workspace/artifacts/{{ARTIFACT_NS}}/impl-plan.json
          required: true
          schema: bundle/.ralph/schemas/planner-output.schema.json
    - id: approve-plan
      type: approval
      question: Approve the plan?
      changesTarget: plan-implementation
      dependsOn:
        - plan-implementation
      requires:
        - path: .ralph-workspace/artifacts/{{ARTIFACT_NS}}/impl-plan.json
          required: true
          schema: bundle/.ralph/schemas/planner-output.schema.json
    - id: implement
      instructions: |
        Implement {{TASK}}.
      dependsOn:
        - approve-plan
        - plan-implementation
      requires:
        - path: .ralph-workspace/artifacts/{{ARTIFACT_NS}}/impl-plan.json
          required: true
      planFrom: plan-implementation
      workspaceMode: snapshot
      writeScopes: ["**"]
      agentGitAccess: off
      produces:
        - path: .ralph-workspace/artifacts/{{ARTIFACT_NS}}/implementation-handoff.md
          required: true
    - id: review
      instructions: |
        Review {{TASK}}.
      dependsOn:
        - implement
      requires:
        - path: .ralph-workspace/artifacts/{{ARTIFACT_NS}}/implementation-handoff.md
          required: true
      produces:
        - path: .ralph-workspace/artifacts/{{ARTIFACT_NS}}/{{STAGE_ID}}-verdict.json
          required: true
          schema: bundle/.ralph/schemas/evaluator-verdict.schema.json
      loopBackTo: implement
      loopCheck:
        path: .ralph-workspace/artifacts/{{ARTIFACT_NS}}/{{STAGE_ID}}-verdict.json
        schema: bundle/.ralph/schemas/evaluator-verdict.schema.json
      onExhausted: fail
    - id: integrate
      type: integrate
      workspaceMode: snapshot
      dependsOn:
        - review-approved
todos:
  - id: plan-work
    stage: plan-implementation
    content: |
      Plan {{TASK}}.
    verification: Confirm .ralph-workspace/artifacts/{{ARTIFACT_NS}}/impl-plan.json exists.
    status: pending
  - id: review-work
    stage: review
    content: |
      Review {{TASK}}.
    verification: Confirm .ralph-workspace/artifacts/{{ARTIFACT_NS}}/review-verdict.json exists.
    status: pending
---
EOF
}

write_sequential_workflow() {
  cat >"$1" <<'EOF'
---
name: seq-demo
overview: Sequential demo workflow
kind: workflow
mode: sequential
pipeline:
  stages:
    - id: research
      instructions: |
        Research {{TASK}}.
      produces:
        - path: .ralph-workspace/artifacts/{{ARTIFACT_NS}}/research.md
          required: true
    - id: build
      instructions: |
        Build {{TASK}}.
      dependsOn:
        - research
      requires:
        - path: .ralph-workspace/artifacts/{{ARTIFACT_NS}}/research.md
          required: true
      produces:
        - path: .ralph-workspace/artifacts/{{ARTIFACT_NS}}/build.md
          required: true
todos:
  - id: research-1
    stage: research
    content: |
      Research {{TASK}}.
    verification: Confirm .ralph-workspace/artifacts/{{ARTIFACT_NS}}/research.md exists.
    status: pending
  - id: build-1
    stage: build
    content: |
      Build {{TASK}}.
    verification: Confirm .ralph-workspace/artifacts/{{ARTIFACT_NS}}/build.md exists.
    status: pending
---
EOF
}

write_required_plan_input_workflow() {
  cat >"$1" <<'EOF'
---
name: provided-demo
overview: Supplied-plan demo workflow
kind: workflow
mode: dependency
planInput:
  stage: implement
  required: true
pipeline:
  stages:
    - id: implement
      instructions: |
        Execute the supplied plan {{INPUT_PLAN}} for {{TASK}}.
      produces:
        - path: .ralph-workspace/artifacts/{{ARTIFACT_NS}}/implementation-handoff.md
          required: true
todos: []
---
EOF
}

write_leaf_plan() {
  cat >"$1" <<'EOF'
# Leaf plan

- [ ] Do the first thing
- [x] Already done
EOF
}

# --- argv contracts ---------------------------------------------------------

@test "inspect requires an id or --file" {
  inspect
  [ "$status" -eq 2 ]
  [[ "$output" == *"requires <id> or --file"* ]]
}

@test "inspect rejects id and --file together" {
  write_dependency_workflow "$TMPD/dep.workflow.md"
  inspect dep-demo --file "$TMPD/dep.workflow.md"
  [ "$status" -eq 2 ]
  [[ "$output" == *"mutually exclusive"* ]]
}

@test "inspect rejects unknown options and duplicate flags" {
  write_dependency_workflow "$TMPD/dep.workflow.md"
  inspect --file "$TMPD/dep.workflow.md" --bogus
  [ "$status" -eq 2 ]
  [[ "$output" == *"unknown inspect option"* ]]

  inspect --file "$TMPD/dep.workflow.md" --file "$TMPD/dep.workflow.md"
  [ "$status" -eq 2 ]
  [[ "$output" == *"duplicate --file"* ]]

  inspect --file "$TMPD/dep.workflow.md" --format
  [ "$status" -eq 2 ]
  [[ "$output" == *"--format requires a value"* ]]
}

@test "inspect formats are limited to text json mermaid dot" {
  write_dependency_workflow "$TMPD/dep.workflow.md"
  inspect --file "$TMPD/dep.workflow.md" --format yaml
  [ "$status" -eq 2 ]
  [[ "$output" == *"text, json, mermaid, or dot"* ]]

  local fmt
  for fmt in text json mermaid dot; do
    inspect --file "$TMPD/dep.workflow.md" --format "$fmt"
    [ "$status" -eq 0 ]
    [ -n "$output" ]
  done
}

@test "inspect rejects a non-workflow --file and a missing file" {
  printf '# not a workflow\n' >"$TMPD/plain.md"
  inspect --file "$TMPD/plain.md"
  [ "$status" -eq 1 ]
  [[ "$output" == *"kind: workflow"* ]]

  inspect --file "$TMPD/absent.workflow.md"
  [ "$status" -eq 1 ]
  [[ "$output" == *"not found"* ]]
}

# --- Dependency reporting ---------------------------------------------------

@test "inspect Dependency reports waves derived nodes and plan handoff edges" {
  write_dependency_workflow "$TMPD/dep.workflow.md"
  inspect --file "$TMPD/dep.workflow.md"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Mode:     dependency (graph engine)"* ]]
  [[ "$output" == *"Runnable waves"* ]]
  # review-approved is compiler-derived, not authored.
  [[ "$output" == *"review-approved [join(derived)]"* ]]
  # The summary distinguishes generating from executing a Ralph plan.
  [[ "$output" == *"plan-implementation: generates a Ralph plan"* ]]
  [[ "$output" == *"executes the generated plan from plan-implementation TODO by TODO"* ]]
  [[ "$output" == *"no authored TODOs: the whole plan is the work"* ]]
  [[ "$output" == *"handoff plan-implementation -> implement (ceiling 40 TODOs)"* ]]
}

@test "inspect Dependency reports approval questions changes targets and evidence" {
  write_dependency_workflow "$TMPD/dep.workflow.md"
  inspect --file "$TMPD/dep.workflow.md"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Approval gates (1)"* ]]
  [[ "$output" == *"question:      Approve the plan?"* ]]
  [[ "$output" == *"changesTarget: plan-implementation"* ]]
  [[ "$output" == *"evidence:      .ralph-workspace/artifacts/{{ARTIFACT_NS}}/impl-plan.json"* ]]
}

@test "inspect Dependency JSON carries the full model" {
  write_dependency_workflow "$TMPD/dep.workflow.md"
  inspect --file "$TMPD/dep.workflow.md" --format json
  [ "$status" -eq 0 ]
  printf '%s' "$output" | python3 -c '
import json, sys
d = json.load(sys.stdin)
assert d["mode"] == "dependency", d["mode"]
assert d["engineFamily"] == "graph"
assert d["routing"]["neutral"] is True
assert [n["id"] for n in d["derivedNodes"]] == ["review-approved"]
assert d["planStages"]["generate"] == ["plan-implementation"]
assert d["planStages"]["execute"] == ["implement"]
edge = d["planFromEdges"][0]
assert edge == {"from": "plan-implementation", "to": "implement", "maxTodos": "40", "direct": True}, edge
assert d["approvals"][0]["changesTarget"] == "plan-implementation"
assert d["cycles"] == []
assert d["runState"]["runId"] is None
assert d["runState"]["registryPath"] is None
assert d["runState"]["controlPlanPath"] is None
'
}

@test "inspect Dependency mermaid and dot draw dependency plan-handoff and approval edges" {
  write_dependency_workflow "$TMPD/dep.workflow.md"
  inspect --file "$TMPD/dep.workflow.md" --format mermaid
  [ "$status" -eq 0 ]
  [[ "$output" == *"flowchart TD"* ]]
  [[ "$output" == *"plan_implementation --> implement"* ]]
  [[ "$output" == *'plan_implementation -.->|"plan handoff"| implement'* ]]
  [[ "$output" == *'approve_plan -.->|"request-changes"| plan_implementation'* ]]
  [[ "$output" == *"review --> review_approved"* ]]

  inspect --file "$TMPD/dep.workflow.md" --format dot
  [ "$status" -eq 0 ]
  [[ "$output" == *'digraph "dep-demo" {'* ]]
  [[ "$output" == *'"plan-implementation" -> "implement" [style=dashed,label="plan handoff"];'* ]]
  [[ "$output" == *'shape=hexagon'* ]]
}

# --- Sequential reporting ---------------------------------------------------

@test "inspect Sequential reports authored order and renders it" {
  write_sequential_workflow "$TMPD/seq.workflow.md"
  inspect --file "$TMPD/seq.workflow.md"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Mode:     sequential (orchestration engine)"* ]]
  [[ "$output" == *"Authored order"* ]]
  [[ "$output" != *"Runnable waves"* ]]
  [[ "$output" == *"1. research [agent]"* ]]
  [[ "$output" == *"2. build [agent]"* ]]
  [[ "$output" == *"none; every stage runs its authored TODOs"* ]]

  inspect --file "$TMPD/seq.workflow.md" --format mermaid
  [ "$status" -eq 0 ]
  [[ "$output" == *"research --> build"* ]]

  inspect --file "$TMPD/seq.workflow.md" --format json
  [ "$status" -eq 0 ]
  printf '%s' "$output" | python3 -c '
import json, sys
d = json.load(sys.stdin)
assert d["mode"] == "sequential"
assert d["engineFamily"] == "orchestration"
assert d["schedule"]["kind"] == "authored-order"
assert d["authoredOrder"] == ["research", "build"]
'
}

# --- provided plan ----------------------------------------------------------

@test "inspect reports provided plan requiredness and how to supply one" {
  write_required_plan_input_workflow "$TMPD/provided.workflow.md"
  inspect --file "$TMPD/provided.workflow.md"
  [ "$status" -eq 0 ]
  [[ "$output" == *"accepted by stage: implement"* ]]
  [[ "$output" == *"requiredness:      required"* ]]
  [[ "$output" == *"refuses a task-only start"* ]]
  [[ "$output" == *"--plan <leaf-plan>"* ]]
}

@test "inspect provided plan previews provenance source hash and TODO counts" {
  write_required_plan_input_workflow "$TMPD/provided.workflow.md"
  write_leaf_plan "$STATE/plans/supplied.plan.md"
  local before
  before="$(find "$STATE" -type f | sort)"

  inspect --file "$TMPD/provided.workflow.md" --plan "$STATE/plans/supplied.plan.md"
  [ "$status" -eq 0 ]
  [[ "$output" == *"entry kind:      plan"* ]]
  [[ "$output" == *"format:          leaf"* ]]
  [[ "$output" == *"TODOs:           2 total, 1 open"* ]]
  [[ "$output" == *"task provenance: plan-filename"* ]]
  [[ "$output" == *"never copied by inspect"* ]]
  # A real sha256 of the source, not a placeholder.
  [[ "$output" =~ source\ sha256:\ +[0-9a-f]{64} ]]
  # The supplied source is untouched and nothing new was written.
  [ "$(find "$STATE" -type f | sort)" = "$before" ]
}

@test "inspect provided plan is refused by a workflow without planInput" {
  write_dependency_workflow "$TMPD/dep.workflow.md"
  write_leaf_plan "$STATE/plans/supplied.plan.md"
  inspect --file "$TMPD/dep.workflow.md" --plan "$STATE/plans/supplied.plan.md"
  [ "$status" -eq 1 ]
  [[ "$output" == *"does not declare planInput"* ]]
}

@test "inspect provided plan rejects a workflow definition and an empty plan" {
  write_required_plan_input_workflow "$TMPD/provided.workflow.md"
  write_dependency_workflow "$STATE/plans/not-a-leaf.plan.md"
  inspect --file "$TMPD/provided.workflow.md" --plan "$STATE/plans/not-a-leaf.plan.md"
  [ "$status" -eq 1 ]
  [[ "$output" == *"unsupported plan for --plan (workflow)"* ]]

  printf '# empty\n' >"$STATE/plans/empty.plan.md"
  inspect --file "$TMPD/provided.workflow.md" --plan "$STATE/plans/empty.plan.md"
  [ "$status" -eq 1 ]
  [[ "$output" == *"no TODOs"* ]]
}

@test "inspect provided plan outside the allowed roots is refused" {
  write_required_plan_input_workflow "$TMPD/provided.workflow.md"
  write_leaf_plan "$TMPD/outside.plan.md"
  inspect --file "$TMPD/provided.workflow.md" --plan "$TMPD/outside.plan.md"
  [ "$status" -eq 1 ]
  [[ "$output" == *"must be under the project root"* ]]
}

# --- no mutation ------------------------------------------------------------

@test "inspect makes no mutation: no registry cache log or workspace" {
  write_dependency_workflow "$TMPD/dep.workflow.md"
  local wf_before state_before
  wf_before="$(cksum <"$TMPD/dep.workflow.md")"
  state_before="$(find "$STATE" | sort)"

  local fmt
  for fmt in text json mermaid dot; do
    inspect --file "$TMPD/dep.workflow.md" --format "$fmt"
    [ "$status" -eq 0 ]
  done

  # The workflow source is byte-identical.
  [ "$(cksum <"$TMPD/dep.workflow.md")" = "$wf_before" ]
  # No new state-root entries at all.
  [ "$(find "$STATE" | sort)" = "$state_before" ]
  # None of the run-time artifacts exist.
  [ ! -e "$STATE/runs" ]
  [ ! -e "$STATE/workflow-runs" ]
  [ ! -e "$STATE/cache" ]
  [ ! -e "$STATE/logs" ]
  [ ! -e "$STATE/agent-workspace" ]
  [ ! -e "$TMPD/home" ]
}

@test "inspect text output states that no run exists yet" {
  write_dependency_workflow "$TMPD/dep.workflow.md"
  inspect --file "$TMPD/dep.workflow.md"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Run state"* ]]
  [[ "$output" == *"no run id, registry entry, or control plan exists until"* ]]
  [[ "$output" == *"inspect is read-only"* ]]
}

@test "inspect reports routing provenance without pinning a runtime" {
  write_dependency_workflow "$TMPD/dep.workflow.md"
  inspect --file "$TMPD/dep.workflow.md"
  [ "$status" -eq 0 ]
  [[ "$output" == *"runtime/model: unpinned"* ]]

  # A pinned stage is reported as provenance, not silently resolved.
  python3 - "$TMPD/dep.workflow.md" <<'PY'
import sys
from pathlib import Path
p = Path(sys.argv[1])
t = p.read_text()
p.write_text(t.replace(
    "    - id: review\n      instructions: |\n",
    "    - id: review\n      runtime: cursor\n      instructions: |\n",
))
PY
  inspect --file "$TMPD/dep.workflow.md"
  [ "$status" -eq 0 ]
  [[ "$output" == *"stage review pinned runtime=cursor"* ]]
}

@test "inspect resolves a project workflow by id and reports its scope" {
  write_dependency_workflow "$STATE/workflows/dep-demo.workflow.md"
  inspect dep-demo
  [ "$status" -eq 0 ]
  [[ "$output" == *"Scope:    project"* ]]
  [[ "$output" == *"Workflow: dep-demo"* ]]

  inspect dep-demo --bundled
  [ "$status" -eq 1 ]
  [[ "$output" == *"not found in bundled"* ]]

  inspect no-such-workflow
  [ "$status" -eq 1 ]
  [[ "$output" == *"not found"* ]]
}

@test "inspect rejects an invalid workflow before reporting anything" {
  cat >"$TMPD/bad.workflow.md" <<'EOF'
---
name: bad-demo
kind: workflow
mode: dependency
pipeline:
  stages:
    - id: implement
      planFrom: no-such-planner
      produces:
        - path: .ralph-workspace/artifacts/{{ARTIFACT_NS}}/implementation-handoff.md
          required: true
todos: []
---
EOF
  inspect --file "$TMPD/bad.workflow.md"
  [ "$status" -eq 1 ]
  [[ "$output" != *"Runnable waves"* ]]
}

# --- start: dispatch contracts ----------------------------------------------
#
# Every start case stubs the engine through RALPH_WORKFLOW_START_ENGINE_STUB, so
# no graph-run, orchestrator, or runtime is ever launched. Import and registry
# writes are real, which is what makes the ordering assertions meaningful.

ENGINE_TUPLE=""

start_wf() {
  ENGINE_TUPLE="$TMPD/engine-tuple.txt"
  run env RALPH_PROJECT_ROOT="$PROJECT" RALPH_PLAN_WORKSPACE_ROOT="$STATE" \
    RALPH_HOME="$TMPD/home" RALPH_WORKFLOW_START_ENGINE_STUB="$ENGINE_TUPLE" \
    bash "$CLI" start "$@"
}

runs_root() {
  printf '%s/workflow-runs\n' "$STATE"
}

only_run_dir() {
  find "$(runs_root)" -maxdepth 1 -mindepth 1 -type d 2>/dev/null | head -1
}

@test "start with a workflow file dispatches task entry and prints the run ID" {
  write_dependency_workflow "$TMPD/dep.workflow.md"
  start_wf --file "$TMPD/dep.workflow.md" --task "Do the work" --runtime cursor --yes
  [ "$status" -eq 0 ]
  # Standardized operator output: outcome first, then run identity and the
  # status/logs commands, then exactly one action.
  [[ "$output" == *"Outcome: running (workflow started)"* ]]
  [[ "$output" == *"Run: run-"* ]]
  [[ "$output" == *"Mode: dependency"* ]]
  [[ "$output" == *"Status: ralph workflow status run-"* ]]
  [[ "$output" == *"Logs: ralph workflow logs run-"* ]]
  [[ "$output" == *"Action: ralph workflow watch run-"* ]]
  # The engine was reached exactly once, in dependency mode, with no plan input.
  [ "$(wc -l <"$ENGINE_TUPLE" | tr -d ' ')" -eq 1 ]
  [[ "$(cut -f1 <"$ENGINE_TUPLE")" == "dependency" ]]
  [[ "$(cut -f4 <"$ENGINE_TUPLE")" == "-" ]]
  # Registry entry and immutable materialized input exist.
  local run_dir
  run_dir="$(only_run_dir)"
  [ -f "$run_dir/run.json" ]
  [ -f "$run_dir/input.plan.md" ]
}

@test "start summary shows plan handoffs and approval boundaries before creating a run" {
  write_dependency_workflow "$TMPD/dep.workflow.md"
  start_wf --file "$TMPD/dep.workflow.md" --task "Do the work" --runtime cursor --yes
  [ "$status" -eq 0 ]
  [[ "$output" == *"plan-implementation: generates a Ralph plan"* ]]
  [[ "$output" == *"handoff plan-implementation -> implement"* ]]
  [[ "$output" == *"Approval gates (1)"* ]]
  [[ "$output" == *"changesTarget: plan-implementation"* ]]
  [[ "$output" == *"no run exists yet"* ]]
}

@test "start confirmation requires --yes when noninteractive" {
  write_dependency_workflow "$TMPD/dep.workflow.md"
  run env RALPH_PROJECT_ROOT="$PROJECT" RALPH_PLAN_WORKSPACE_ROOT="$STATE" \
    RALPH_HOME="$TMPD/home" RALPH_WORKFLOW_START_ENGINE_STUB="$TMPD/never.txt" \
    bash "$CLI" start --file "$TMPD/dep.workflow.md" --task "Do the work" \
    --runtime cursor </dev/null
  [ "$status" -eq 1 ]
  [[ "$output" == *"requires --yes to confirm noninteractively"* ]]
  # Nothing was created and the engine was never reached.
  [ ! -e "$TMPD/never.txt" ]
  [ -z "$(only_run_dir)" ]
}

@test "start by project id resolves the project workflow" {
  write_dependency_workflow "$STATE/workflows/dep-demo.workflow.md"
  start_wf dep-demo --task "Do the work" --runtime cursor --yes
  [ "$status" -eq 0 ]
  [[ "$output" == *"Scope:    project"* ]]
  [[ "$output" == *"Run: run-"* ]]
  local run_dir
  run_dir="$(only_run_dir)"
  [ "$(python3 -c '
import json, sys
print(json.load(open(sys.argv[1]))["sourceKind"])' "$run_dir/run.json")" = "project" ]
}

@test "start by global id resolves the global workflow" {
  mkdir -p "$TMPD/home/workflows"
  write_dependency_workflow "$TMPD/home/workflows/dep-demo.workflow.md"
  start_wf dep-demo --task "Do the work" --runtime cursor --yes
  [ "$status" -eq 0 ]
  [[ "$output" == *"Scope:    global"* ]]
  local run_dir
  run_dir="$(only_run_dir)"
  [ "$(python3 -c '
import json, sys
print(json.load(open(sys.argv[1]))["sourceKind"])' "$run_dir/run.json")" = "global" ]
}

@test "start by bundled id resolves the bundled workflow" {
  mkdir -p "$TMPD/home/bundle/.ralph/workflows"
  write_dependency_workflow "$TMPD/home/bundle/.ralph/workflows/dep-demo.workflow.md"
  start_wf dep-demo --task "Do the work" --runtime cursor --yes
  [ "$status" -eq 0 ]
  [[ "$output" == *"Scope:    bundled"* ]]
  local run_dir
  run_dir="$(only_run_dir)"
  [ "$(python3 -c '
import json, sys
print(json.load(open(sys.argv[1]))["sourceKind"])' "$run_dir/run.json")" = "bundled" ]
}

@test "start provided plan imports the manifest before the engine sees the run" {
  write_required_plan_input_workflow "$TMPD/provided.workflow.md"
  write_leaf_plan "$STATE/plans/supplied.plan.md"
  start_wf --file "$TMPD/provided.workflow.md" \
    --plan "$STATE/plans/supplied.plan.md" --runtime cursor --yes
  [ "$status" -eq 0 ]

  local run_dir
  run_dir="$(only_run_dir)"
  # Import ordering: immutable source and manifest both exist, and the engine
  # tuple names the designated consumer stage.
  [ -f "$run_dir/plans/input/source.plan.md" ]
  [ -f "$run_dir/plans/input/manifest.json" ]
  [[ "$(cut -f4 <"$ENGINE_TUPLE")" == "implement" ]]
  # The manifest was published no later than the engine dispatch record.
  [ ! "$run_dir/plans/input/manifest.json" -nt "$ENGINE_TUPLE" ]
  # The operator original is untouched.
  run diff "$STATE/plans/supplied.plan.md" "$run_dir/plans/input/source.plan.md"
  [ "$status" -eq 0 ]
}

@test "start provided plan shows total completed and open counts with the prechecked warning" {
  write_required_plan_input_workflow "$TMPD/provided.workflow.md"
  write_leaf_plan "$STATE/plans/supplied.plan.md"
  start_wf --file "$TMPD/provided.workflow.md" \
    --plan "$STATE/plans/supplied.plan.md" --runtime cursor --yes
  [ "$status" -eq 0 ]
  [[ "$output" == *"Supplied plan TODOs"* ]]
  [[ "$output" == *"total:     2"* ]]
  [[ "$output" == *"completed: 1"* ]]
  [[ "$output" == *"open:      1"* ]]
  [[ "$output" == *"WARNING: 1 TODO(s) are already checked"* ]]
  [[ "$output" == *"will not rerun or reverify them"* ]]
}

@test "start dispatch failure preserves an auditable failed run with no control plan" {
  write_required_plan_input_workflow "$TMPD/provided.workflow.md"
  write_leaf_plan "$STATE/plans/supplied.plan.md"
  # An unwritable stub path makes the engine dispatch step fail for real, after
  # the registry entry exists and after the input manifest is published.
  run env RALPH_PROJECT_ROOT="$PROJECT" RALPH_PLAN_WORKSPACE_ROOT="$STATE" \
    RALPH_HOME="$TMPD/home" \
    RALPH_WORKFLOW_START_ENGINE_STUB="$TMPD/no-such-dir/tuple.txt" \
    bash "$CLI" start --file "$TMPD/provided.workflow.md" \
    --plan "$STATE/plans/supplied.plan.md" --runtime cursor --yes
  [ "$status" -eq 1 ]
  [[ "$output" == *"engine-dispatch-failed"* ]]
  [[ "$output" == *"preserved as failed"* ]]

  local run_dir
  run_dir="$(only_run_dir)"
  [ -n "$run_dir" ]
  # The run is auditable: run.json survives in the failed state.
  [ -f "$run_dir/run.json" ]
  [ "$(python3 -c '
import json, sys
print(json.load(open(sys.argv[1]))["state"])' "$run_dir/run.json")" = "failed" ]
  # The import completed before dispatch, so the manifest is whole, not partial.
  [ -f "$run_dir/plans/input/source.plan.md" ]
  [ -f "$run_dir/plans/input/manifest.json" ]
  # No control plan was ever created.
  refute_cmd test -e "$run_dir/plans/input/control.plan.md"
  # The operator original is untouched.
  run diff "$STATE/plans/supplied.plan.md" "$run_dir/plans/input/source.plan.md"
  [ "$status" -eq 0 ]
}

@test "start legacy orchestration file runs without a workflow wrapper" {
  cat >"$TMPD/legacy.orch.json" <<'EOF'
{
  "name": "legacy-demo",
  "namespace": "legacy-demo",
  "stages": [
    {"id": "build", "runtime": "cursor", "planFile": "legacy.plan.md"}
  ],
  "parallelStages": []
}
EOF
  start_wf --file "$TMPD/legacy.orch.json" --task "Legacy work" --yes
  [ "$status" -eq 0 ]
  [[ "$output" == *"Legacy sequential source"* ]]
  [[ "$output" == *"Run: run-"* ]]
  [[ "$(cut -f1 <"$ENGINE_TUPLE")" == "sequential" ]]
  local run_dir
  run_dir="$(only_run_dir)"
  [ "$(python3 -c '
import json, sys
print(json.load(open(sys.argv[1]))["sourceKind"])' "$run_dir/run.json")" = "legacy-orchestration" ]
}

@test "start legacy orchestration file refuses a provided plan" {
  printf '%s\n' '{"name":"legacy-demo","namespace":"legacy-demo","stages":[],"parallelStages":[]}' \
    >"$TMPD/legacy.orch.json"
  write_leaf_plan "$STATE/plans/supplied.plan.md"
  start_wf --file "$TMPD/legacy.orch.json" --plan "$STATE/plans/supplied.plan.md" --yes
  [ "$status" -eq 1 ]
  [[ "$output" == *"does not declare planInput"* ]]
  [ -z "$(only_run_dir)" ]
}

@test "start runs in the foreground and offers no detach flag" {
  write_dependency_workflow "$TMPD/dep.workflow.md"
  run env RALPH_PROJECT_ROOT="$PROJECT" RALPH_PLAN_WORKSPACE_ROOT="$STATE" \
    RALPH_HOME="$TMPD/home" bash "$CLI" start --help
  [ "$status" -eq 0 ]
  refute_start_flag "$output" "--background"
  refute_start_flag "$output" "--detach"

  start_wf --file "$TMPD/dep.workflow.md" --task "Do the work" --runtime cursor \
    --background --yes
  [ "$status" -eq 2 ]
}

@test "start does not mutate the workflow source or the supplied plan" {
  write_required_plan_input_workflow "$TMPD/provided.workflow.md"
  write_leaf_plan "$STATE/plans/supplied.plan.md"
  local wf_before plan_before
  wf_before="$(cksum <"$TMPD/provided.workflow.md")"
  plan_before="$(cksum <"$STATE/plans/supplied.plan.md")"

  start_wf --file "$TMPD/provided.workflow.md" \
    --plan "$STATE/plans/supplied.plan.md" --runtime cursor --yes
  [ "$status" -eq 0 ]
  [ "$(cksum <"$TMPD/provided.workflow.md")" = "$wf_before" ]
  [ "$(cksum <"$STATE/plans/supplied.plan.md")" = "$plan_before" ]
}

@test "inspect reports the addressable id when a copied workflow keeps the original frontmatter name" {
  # Copying a bundled workflow to a new filename is the ordinary way to author
  # your own, and it leaves the original `name:` in the frontmatter. `list`,
  # `path`, and the run registry all identify the copy by its filename, so
  # inspect must too -- it used to print the frontmatter name, including in a
  # "start with:" command that would have run the *original* workflow.
  write_dependency_workflow "$STATE/workflows/my-copy.workflow.md"

  inspect my-copy
  [ "$status" -eq 0 ]
  [[ "$output" == *"Workflow: my-copy"* ]]
  [[ "$output" != *"Workflow: dep-demo"* ]]
  [[ "$output" == *"frontmatter name is dep-demo; this workflow is addressed as my-copy"* ]]
}

@test "inspect leaves the header alone when filename and frontmatter name agree" {
  write_dependency_workflow "$STATE/workflows/dep-demo.workflow.md"

  inspect dep-demo
  [ "$status" -eq 0 ]
  [[ "$output" == *"Workflow: dep-demo"* ]]
  [[ "$output" != *"frontmatter name is"* ]]
}

@test "inspect --file has no addressable id and falls back to the frontmatter name" {
  write_dependency_workflow "$TMPD/dep.workflow.md"

  inspect --file "$TMPD/dep.workflow.md"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Workflow: dep-demo"* ]]
  [[ "$output" != *"frontmatter name is"* ]]
}

# A --task argument arriving with embedded newlines means the caller's shell
# expanded a backtick, $(...), or a variable inside a double-quoted argument and
# substituted command output into the request. Ralph only ever sees the expanded
# string, so it must refuse rather than instantiate a plan around the corruption.
@test "start rejects inline --task text containing an embedded newline" {
  write_dependency_workflow "$TMPD/dep.workflow.md"
  start_wf --file "$TMPD/dep.workflow.md" \
    --task "fix the $(printf 'opus\nsonnet\nclaude-haiku-4-5') command" \
    --runtime cursor --yes
  [ "$status" -eq 2 ]
  [[ "$output" == *"--task text contains an embedded newline"* ]]
  [[ "$output" == *"expanded a backtick"* ]]
  # The corrupted text is echoed back so the operator can see what Ralph got.
  [[ "$output" == *"| fix the opus"* ]]
  [[ "$output" == *"single-quote the text"* ]]
  # Refusal happens before any run is created and before the engine is reached.
  [ ! -e "$ENGINE_TUPLE" ]
  [ ! -d "$(runs_root)" ]
}

@test "start rejects inline --task text containing a control character" {
  write_dependency_workflow "$TMPD/dep.workflow.md"
  start_wf --file "$TMPD/dep.workflow.md" \
    --task "fix the $(printf 'a\001b') command" --runtime cursor --yes
  [ "$status" -eq 2 ]
  [[ "$output" == *"--task text contains an embedded control character"* ]]
  [ ! -e "$ENGINE_TUPLE" ]
}

@test "start accepts inline --task text containing a tab" {
  write_dependency_workflow "$TMPD/dep.workflow.md"
  start_wf --file "$TMPD/dep.workflow.md" \
    --task "$(printf 'fix the\tmodels command')" --runtime cursor --yes
  [ "$status" -eq 0 ]
  [[ "$output" == *"Outcome: running (workflow started)"* ]]
}

@test "start accepts literal backticks in single-quoted --task text" {
  write_dependency_workflow "$TMPD/dep.workflow.md"
  start_wf --file "$TMPD/dep.workflow.md" \
    --task 'fix the `ralph models list claude` command' --runtime cursor --yes
  [ "$status" -eq 0 ]
  [[ "$output" == *"Outcome: running (workflow started)"* ]]
  # The backticks survive into the materialized input verbatim.
  grep -Fq 'ralph models list claude' "$(only_run_dir)/input.plan.md"
}
