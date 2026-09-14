#!/usr/bin/env bats

# Workflow instantiation: workflow + task -> materialized plan -> engine compile.
# Task text is data. It is substituted exactly once, before compilation, and is
# never passed through a shell interpolation.

source "$BATS_TEST_DIRNAME/../helper/load-lib.bash"
source "$BATS_TEST_DIRNAME/../../../bundle/.ralph/bash-lib/plan-todo.sh"

BUNDLED_WORKFLOWS="$REPO_ROOT/bundle/.ralph/workflows"

# Optional outputs from the six old profile lists that must not be invented by
# instruction-only stages or copied into bundled workflows when unused downstream.
OLD_PROFILE_OPTIONAL_PATHS=(
  ".ralph-workspace/artifacts/{{ARTIFACT_NS}}/architecture.md"
  ".ralph-workspace/artifacts/{{ARTIFACT_NS}}/research.md"
  ".ralph-workspace/handoffs/{{ARTIFACT_NS}}/architect-to-implementation.md"
  ".ralph-workspace/handoffs/{{ARTIFACT_NS}}/implementation-to-qa.md"
  ".ralph-workspace/handoffs/{{ARTIFACT_NS}}/code-review-to-implementation.md"
  ".ralph-workspace/handoffs/{{ARTIFACT_NS}}/qa-to-implementation.md"
  ".ralph-workspace/handoffs/{{ARTIFACT_NS}}/security-to-implementation.md"
  ".ralph-workspace/artifacts/{{ARTIFACT_NS}}/code-review.md"
)

# `! cmd` is exempt from set -e, so a bare `! grep ...` can never fail a bats
# test: every such assertion silently passes. refute_cmd runs the command and
# fails loudly when it unexpectedly succeeds.
refute_cmd() {
  if "$@"; then
    echo "refute_cmd: expected failure but command succeeded: $*" >&2
    return 1
  fi
  return 0
}

# Materialization substitutes {{TASK}} in TODO content only; stage instructions
# intentionally carry the token through to the materialized plan and are
# resolved when the stage prompt is built. Assert the guarantee the materializer
# actually enforces: no unresolved token survives in the todos block.
assert_task_resolved_in_todos() {
  local plan="$1"
  refute_cmd awk '/^todos:/{t=1} t && /\{\{TASK\}\}/{found=1} END{exit found?0:1}' "$plan"
}

# Source-level producer check (bundled workflows are intentionally runtime-neutral;
# missing ordinary-stage runtime is valid on workflow sources once defaults schema lands).
assert_bundled_requires_have_one_producer() {
  local wf="$1"
  python3 - "$wf" <<'PY'
import re, sys
from pathlib import Path
text = Path(sys.argv[1]).read_text()
# Restrict to pipeline stages block before todos.
m = re.search(r"(?ms)^pipeline:\n(.*?)(?=^todos:\n|\Z)", text)
if not m:
    raise SystemExit("missing pipeline")
body = m.group(1)
producers = {}
requires = []
stage_id = None
section = None  # produces|requires|other
for line in body.splitlines():
    sm = re.match(r"^    - id:\s*(\S+)\s*$", line)
    if sm:
        stage_id = sm.group(1)
        section = None
        continue
    if re.match(r"^      (produces|requires):\s*$", line):
        section = line.strip().rstrip(":")
        continue
    if re.match(r"^      \S", line) and not line.startswith("        "):
        section = None
        continue
    pm = re.match(r"^        - path:\s*(.+?)\s*$", line)
    if pm and stage_id and section in {"produces", "requires"}:
        path = pm.group(1)
        if section == "produces":
            producers.setdefault(path, []).append(stage_id)
        else:
            requires.append((stage_id, path))
dups = {p: ids for p, ids in producers.items() if len(ids) > 1}
if dups:
    raise SystemExit(f"duplicate producers: {dups}")
missing = [(sid, p) for sid, p in requires if p not in producers]
if missing:
    raise SystemExit(f"requires without producer: {missing}")
print("ok")
PY
}

setup() {
  TMPD="$(mktemp -d)"
  TASK="$(printf '%s\n' 'Add "compaction profiles" & a $VAR with `backticks`' '---' 'second line')"
}

teardown() {
  rm -rf "$TMPD"
}

@test "Sequential mode materializes orchestration internal execution" {
  write_workflow_mode "$TMPD/wf.md" sequential
  run plan_workflow_validate "$TMPD/wf.md"
  [ "$status" -eq 0 ]

  run plan_workflow_instantiate "$TMPD/wf.md" "$TASK" "$TMPD/out.plan.md"
  [ "$status" -eq 0 ]
  grep -qx 'execution: orchestration' "$TMPD/out.plan.md"
  run grep -Ec '^(kind|mode|engine):' "$TMPD/out.plan.md"
  [ "$status" -ne 0 ]

  run plan_pipeline_orch_json "$TMPD/out.plan.md"
  [ "$status" -eq 0 ]
}

@test "Dependency mode materializes graph internal execution" {
  write_workflow_mode "$TMPD/wf.md" dependency
  run plan_workflow_validate "$TMPD/wf.md"
  [ "$status" -eq 0 ]

  run plan_workflow_instantiate "$TMPD/wf.md" "$TASK" "$TMPD/out.plan.md"
  [ "$status" -eq 0 ]
  grep -qx 'execution: graph' "$TMPD/out.plan.md"
  run grep -Ec '^(kind|mode|engine):' "$TMPD/out.plan.md"
  [ "$status" -ne 0 ]

  run plan_pipeline_graph_json "$TMPD/out.plan.md"
  [ "$status" -eq 0 ]
}

@test "legacy engine maps with warning and materializes internal execution" {
  write_workflow "$TMPD/wf.md" graph
  run plan_workflow_validate "$TMPD/wf.md"
  [ "$status" -eq 0 ]
  [[ "$output" == *"legacy engine: graph"* ]]
  [[ "$output" == *"mode: dependency"* ]]

  run plan_workflow_instantiate "$TMPD/wf.md" "$TASK" "$TMPD/out.plan.md"
  [ "$status" -eq 0 ]
  [[ "$output" == *"legacy engine: graph"* ]]
  grep -qx 'execution: graph' "$TMPD/out.plan.md"
  refute_cmd grep -E '^(mode|engine):' "$TMPD/out.plan.md"
}

@test "both mode and engine is rejected" {
  printf '%s\n' \
    '---' \
    'name: both-mode-engine' \
    'kind: workflow' \
    'mode: dependency' \
    'engine: graph' \
    'pipeline:' \
    '  stages:' \
    '    - id: source' \
    '      runtime: cursor' \
    'todos:' \
    '  - id: source-work' \
    '    stage: source' \
    '    content: |' \
    '      Investigate:' \
    '      {{TASK}}' \
    '    status: pending' \
    '---' >"$TMPD/both.md"

  run plan_workflow_validate "$TMPD/both.md"
  [ "$status" -ne 0 ]
  [[ "$output" == *"mode and engine"* ]]
}

@test "unknown mode is rejected before internal execution" {
  printf '%s\n' \
    '---' \
    'name: bad-mode' \
    'kind: workflow' \
    'mode: pipeline' \
    'pipeline:' \
    '  stages:' \
    '    - id: source' \
    '      runtime: cursor' \
    'todos:' \
    '  - id: source-work' \
    '    stage: source' \
    '    content: |' \
    '      Investigate:' \
    '      {{TASK}}' \
    '    status: pending' \
    '---' >"$TMPD/bad-mode.md"

  run plan_workflow_validate "$TMPD/bad-mode.md"
  [ "$status" -ne 0 ]
  [[ "$output" == *"mode"* ]]
  [[ "$output" == *"sequential"* ]] || [[ "$output" == *"dependency"* ]]
}

write_workflow_mode() {
  local path="$1" mode="$2"
  printf '%s\n' \
    '---' \
    'name: demo-workflow' \
    'kind: workflow' \
    "mode: $mode" \
    'pipeline:' \
    '  stages:' \
    '    - id: source' \
    '      runtime: cursor' \
    'todos:' \
    '  - id: source-work' \
    '    stage: source' \
    '    content: |' \
    '      Investigate:' \
    '      {{TASK}}' \
    '    status: pending' \
    '---' >"$path"
}

write_workflow() {
  local path="$1" engine="$2"
  printf '%s\n' \
    '---' \
    'name: demo-workflow' \
    'kind: workflow' \
    "engine: $engine" \
    'pipeline:' \
    '  stages:' \
    '    - id: source' \
    '      runtime: cursor' \
    'todos:' \
    '  - id: source-work' \
    '    stage: source' \
    '    content: |' \
    '      Investigate:' \
    '      {{TASK}}' \
    '    status: pending' \
    '---' >"$path"
}

@test "workflow defaults accept runtime and paired model" {
  cat >"$TMPD/wf.md" <<'EOF'
---
name: demo-workflow
kind: workflow
mode: dependency
defaults:
  runtime: cursor
  model: auto
pipeline:
  stages:
    - id: source
todos:
  - id: source-work
    stage: source
    content: |
      Investigate:
      {{TASK}}
    status: pending
---
EOF
  run plan_workflow_validate "$TMPD/wf.md"
  [ "$status" -eq 0 ]

  run plan_workflow_instantiate "$TMPD/wf.md" "$TASK" "$TMPD/out.plan.md"
  [ "$status" -eq 0 ]
  # Materialized plans must not retain workflow-only defaults.
  refute_cmd grep -E '^defaults:' "$TMPD/out.plan.md"
  # Defaults fill unresolved stages during materialization.
  grep -qx '      runtime: cursor' "$TMPD/out.plan.md"
  grep -qx '      model: auto' "$TMPD/out.plan.md"
}

@test "default model requires runtime" {
  cat >"$TMPD/wf.md" <<'EOF'
---
name: demo-workflow
kind: workflow
mode: dependency
defaults:
  model: auto
pipeline:
  stages:
    - id: source
      runtime: cursor
todos:
  - id: source-work
    stage: source
    content: |
      Investigate:
      {{TASK}}
    status: pending
---
EOF
  run plan_workflow_validate "$TMPD/wf.md"
  [ "$status" -ne 0 ]
  [[ "$output" == *"defaults.model"* ]]
  [[ "$output" == *"defaults.runtime"* ]]
}

@test "stage model only pairs with later effective runtime on workflow sources" {
  cat >"$TMPD/wf.md" <<'EOF'
---
name: demo-workflow
kind: workflow
mode: dependency
pipeline:
  stages:
    - id: source
      model: auto
todos:
  - id: source-work
    stage: source
    content: |
      Investigate:
      {{TASK}}
    status: pending
---
EOF
  run plan_workflow_validate "$TMPD/wf.md"
  [ "$status" -eq 0 ]
}

@test "missing stage runtime is allowed on ordinary workflow stages" {
  cat >"$TMPD/wf.md" <<'EOF'
---
name: demo-workflow
kind: workflow
mode: dependency
pipeline:
  stages:
    - id: source
todos:
  - id: source-work
    stage: source
    content: |
      Investigate:
      {{TASK}}
    status: pending
---
EOF
  run plan_workflow_validate "$TMPD/wf.md"
  [ "$status" -eq 0 ]

  run plan_workflow_instantiate "$TMPD/wf.md" "$TASK" "$TMPD/out.plan.md"
  [ "$status" -eq 0 ]
}

@test "concrete runtime remains required on materialized plans" {
  cat >"$TMPD/plan.md" <<'EOF'
---
name: concrete-plan
execution: graph
pipeline:
  stages:
    - id: source
todos:
  - id: source-work
    stage: source
    content: Investigate
    status: pending
---
EOF
  run plan_pipeline_validate_plan "$TMPD/plan.md"
  [ "$status" -ne 0 ]
  [[ "$output" == *"missing runtime"* ]]

  cat >"$TMPD/model-only.md" <<'EOF'
---
name: concrete-plan
execution: graph
pipeline:
  stages:
    - id: source
      model: auto
todos:
  - id: source-work
    stage: source
    content: Investigate
    status: pending
---
EOF
  run plan_pipeline_validate_plan "$TMPD/model-only.md"
  [ "$status" -ne 0 ]
  [[ "$output" == *"missing runtime"* ]] || [[ "$output" == *"effective runtime"* ]]
}

@test "unknown defaults fields and non-workflow defaults are rejected" {
  cat >"$TMPD/wf.md" <<'EOF'
---
name: demo-workflow
kind: workflow
mode: dependency
defaults:
  runtime: cursor
  agent: research
pipeline:
  stages:
    - id: source
todos:
  - id: source-work
    stage: source
    content: |
      Investigate:
      {{TASK}}
    status: pending
---
EOF
  run plan_workflow_validate "$TMPD/wf.md"
  [ "$status" -ne 0 ]
  [[ "$output" == *"unknown"* ]]
  [[ "$output" == *"defaults"* ]]

  cat >"$TMPD/plan.md" <<'EOF'
---
name: concrete-plan
execution: graph
defaults:
  runtime: cursor
pipeline:
  stages:
    - id: source
      runtime: cursor
todos:
  - id: source-work
    stage: source
    content: Investigate
    status: pending
---
EOF
  run plan_pipeline_validate_plan "$TMPD/plan.md"
  [ "$status" -ne 0 ]
  [[ "$output" == *"defaults"* ]]
  [[ "$output" == *"workflow"* ]]
}

@test "workflow instantiation materializes a graph plan with the task verbatim" {
  write_workflow "$TMPD/wf.md" graph
  run plan_workflow_instantiate "$TMPD/wf.md" "$TASK" "$TMPD/out.plan.md"
  [ "$status" -eq 0 ]

  run grep -c '{{TASK}}' "$TMPD/out.plan.md"
  [ "$status" -ne 0 ]
  run grep -Ec '^(kind|engine):' "$TMPD/out.plan.md"
  [ "$status" -ne 0 ]
  grep -qx 'execution: graph' "$TMPD/out.plan.md"
  grep -qx '      Add "compaction profiles" & a $VAR with `backticks`' "$TMPD/out.plan.md"
  grep -qx '      ---' "$TMPD/out.plan.md"

  run plan_pipeline_graph_json "$TMPD/out.plan.md"
  [ "$status" -eq 0 ]
  printf '%s' "$output" | jq -e --arg task "$TASK" '
    .nodes[0].stage._inlineTodos[0].content == "Investigate:\n" + $task
  ' >/dev/null
}

@test "workflow instantiation materializes an orchestration plan with the task verbatim" {
  write_workflow "$TMPD/wf.md" orchestration
  run plan_workflow_instantiate "$TMPD/wf.md" "$TASK" "$TMPD/out.plan.md"
  [ "$status" -eq 0 ]
  grep -qx 'execution: orchestration' "$TMPD/out.plan.md"

  run plan_pipeline_orch_json "$TMPD/out.plan.md"
  [ "$status" -eq 0 ]
  [[ "$output" != *'{{TASK}}'* ]]
  printf '%s' "$output" | jq -e --arg task "$TASK" '
    [.. | strings] | any(contains($task))
  ' >/dev/null
}

@test "workflow instantiation rejects a missing or blank task and names the workflow" {
  write_workflow "$TMPD/wf.md" graph

  run plan_workflow_instantiate "$TMPD/wf.md" "" "$TMPD/missing.plan.md"
  [ "$status" -ne 0 ]
  [[ "$output" == *"wf.md"* ]]
  [ ! -e "$TMPD/missing.plan.md" ]

  run plan_workflow_instantiate "$TMPD/wf.md" "   " "$TMPD/blank.plan.md"
  [ "$status" -ne 0 ]
  [[ "$output" == *"wf.md"* ]]
  [ ! -e "$TMPD/blank.plan.md" ]
}

@test "workflow instantiation refuses to overwrite an existing output plan" {
  write_workflow "$TMPD/wf.md" graph
  printf 'SENTINEL\n' >"$TMPD/out.plan.md"

  run plan_workflow_instantiate "$TMPD/wf.md" "$TASK" "$TMPD/out.plan.md"
  [ "$status" -ne 0 ]
  [ "$(cat "$TMPD/out.plan.md")" = "SENTINEL" ]
}

@test "bundled workflows: every requires path has one explicit producer" {
  local wf
  for wf in "$BUNDLED_WORKFLOWS"/*.workflow.md; do
    run assert_bundled_requires_have_one_producer "$wf"
    [ "$status" -eq 0 ]
    [[ "$output" == *"ok"* ]]
  done
}

@test "bundled mode is dependency with no engine field" {
  local wf
  [ "$(find "$BUNDLED_WORKFLOWS" -maxdepth 1 -name '*.workflow.md' | wc -l | tr -d ' ')" = "10" ]
  for wf in "$BUNDLED_WORKFLOWS"/*.workflow.md; do
    grep -qx 'mode: dependency' "$wf"
    refute_cmd grep -E '^engine:' "$wf"
  done
}

@test "bundled workflows are runtime neutral without top-level defaults" {
  local wf
  for wf in "$BUNDLED_WORKFLOWS"/*.workflow.md; do
    # No top-level defaults block (workflow-default runtime/model).
    refute_cmd grep -E '^defaults:' "$wf"
    # No ordinary executable-stage runtime or model pins (6-space stage fields).
    refute_cmd grep -E '^[[:space:]]{6}runtime:' "$wf"
    refute_cmd grep -E '^[[:space:]]{6}model:' "$wf"
    # No residual role/agent pins on stages.
    refute_cmd grep -E '^[[:space:]]+role:' "$wf"
    refute_cmd grep -E '^[[:space:]]+agent:' "$wf"
  done
}

@test "voter routing keeps explicit consensus voter runtimes and models" {
  # Bundled SDLC workflows have no consensus voters today. Conversion policy still
  # requires voter runtime/model pins to remain when consensus is authored.
  cat >"$TMPD/voter-routing.workflow.md" <<'EOF'
---
name: voter-routing
kind: workflow
mode: dependency
pipeline:
  stages:
    - id: jury
      type: consensus
      policy: majority
      quorum: 2
      minRuntimes: 2
      voters:
        - id: cursor-voter
          runtime: cursor
          model: auto
          instructions: Vote with repository evidence only.
        - id: claude-voter
          runtime: claude
          model: sonnet
          instructions: Vote with repository evidence only.
todos:
  - id: jury-work
    stage: jury
    content: |
      Consensus review:
      {{TASK}}
    status: pending
---
EOF

  run plan_workflow_validate "$TMPD/voter-routing.workflow.md"
  [ "$status" -eq 0 ]

  run plan_workflow_instantiate "$TMPD/voter-routing.workflow.md" "$TASK" "$TMPD/voter-routing.plan.md"
  [ "$status" -eq 0 ]
  grep -qx 'execution: graph' "$TMPD/voter-routing.plan.md"

  # Source retains explicit voter runtime/model pins (not stripped by conversion policy).
  grep -q '^          runtime: cursor$' "$TMPD/voter-routing.workflow.md"
  grep -q '^          runtime: claude$' "$TMPD/voter-routing.workflow.md"
  grep -q '^          model: auto$' "$TMPD/voter-routing.workflow.md"
  grep -q '^          model: sonnet$' "$TMPD/voter-routing.workflow.md"

  # Keep validator quorum warnings off the JSON payload used for assertions.
  graph_json="$(plan_pipeline_graph_json "$TMPD/voter-routing.plan.md" 2>/dev/null)"
  [ -n "$graph_json" ]
  printf '%s' "$graph_json" | jq -e '
    ([.nodes[] | select(.type == "consensus-voter")] | length) == 2
    and ([.nodes[] | select(.id == "jury:cursor-voter" and .stage.runtime == "cursor" and .stage.model == "auto")] | length) == 1
    and ([.nodes[] | select(.id == "jury:claude-voter" and .stage.runtime == "claude" and .stage.model == "sonnet")] | length) == 1
  ' >/dev/null
}

@test "bundled workflow instructions preserved on every executable stage" {
  local wf name
  for wf in "$BUNDLED_WORKFLOWS"/*.workflow.md; do
    name="$(basename "$wf" .workflow.md)"
    case "$name" in
      bug-fix)
        [ "$(grep -c '^      instructions:' "$wf")" -eq 6 ]
        grep -Fq 'Investigate the defect described by {{TASK}}.' "$wf"
        grep -Fq 'Execute the generated implementation plan for {{TASK}}' "$wf"
        grep -Fq 'Review the candidate for {{TASK}} without mutation.' "$wf"
        grep -Fq 'Execute the generated QA plan for {{TASK}}' "$wf"
        ;;
      feature-delivery)
        [ "$(grep -c '^      instructions:' "$wf")" -eq 6 ]
        grep -Fq 'Clarify acceptance criteria and non-goals' "$wf"
        grep -Fq 'design the feature without inventing unanswered product choices' "$wf"
        grep -Fq 'Execute the entire generated implementation plan for {{TASK}}' "$wf"
        grep -Fq 'Review the candidate snapshot for {{TASK}} without mutation.' "$wf"
        grep -Fq 'create the smallest independent QA plan justified by the task and evidence.' "$wf"
        grep -Fq 'Execute the entire generated QA plan for {{TASK}}' "$wf"
        ;;
      investigation)
        [ "$(grep -c '^      instructions:' "$wf")" -eq 2 ]
        grep -Fq 'Investigate {{TASK}} read-only.' "$wf"
        grep -Fq 'runnable next-step Ralph plan' "$wf"
        ;;
      refactor)
        [ "$(grep -c '^      instructions:' "$wf")" -eq 6 ]
        grep -q '^      type: integrate$' "$wf"
        # Supervisor integrate must not carry instructions.
        refute_cmd awk '/^    - id: integrate$/{p=1;next} p && /^    - id:/{exit} p && /^      instructions:/{found=1} END{exit found?0:1}' "$wf"
        grep -Fq 'Characterize the current behavior of the code targeted by {{TASK}}' "$wf"
        grep -Fq 'safe migration slices' "$wf"
        grep -Fq 'Execute the entire generated refactor plan for {{TASK}} TODO by TODO' "$wf"
        grep -Fq 'Review the candidate snapshot for {{TASK}} without mutation.' "$wf"
        grep -Fq 'create the smallest independent QA plan justified by the task and' "$wf"
        grep -Fq 'Execute the entire generated QA plan for {{TASK}} TODO by TODO' "$wf"
        ;;
      human-verified-delivery)
        [ "$(grep -c '^      instructions:' "$wf")" -eq 6 ]
        grep -Fq 'Investigate {{TASK}} as a bounded requirements and repository study.' "$wf"
        grep -Fq 'The operator reviews this plan at the next gate' "$wf"
        grep -Fq 'The operator has already' "$wf"
        grep -Fq 'Review the candidate snapshot for {{TASK}} without mutation.' "$wf"
        grep -Fq 'The operator accepts these results at the final gate' "$wf"
        grep -Fq 'Execute the entire generated QA plan for {{TASK}} TODO by TODO' "$wf"
        # Every bounded agent instruction references the common operator input protocol.
        [ "$(grep -c 'run `ralph workflow actions request --question <text> \[--details <text>\]`' "$wf")" -eq 6 ]
        ;;
      plan-delivery)
        [ "$(grep -c '^      instructions:' "$wf")" -eq 4 ]
        grep -Fq 'Execute the entire supplied plan {{INPUT_PLAN}} for {{TASK}} TODO by TODO' "$wf"
        grep -Fq 'Review the candidate snapshot for {{TASK}} without mutation.' "$wf"
        grep -Fq 'create the smallest independent QA plan justified by the supplied plan' "$wf"
        grep -Fq 'Execute the entire generated QA plan for {{TASK}} TODO by TODO' "$wf"
        ;;
      release-gate)
        [ "$(grep -c '^      instructions:' "$wf")" -eq 5 ]
        grep -Fq 'Inspect the release candidate for {{TASK}} read-only.' "$wf"
        grep -Fq 'plan the release' "$wf"
        grep -Fq 'Execute the entire generated verification plan for {{TASK}} TODO by TODO' "$wf"
        grep -Fq 'independently of any verification conclusion' "$wf"
        grep -Fq 'Decide the release for {{TASK}}' "$wf"
        ;;
      assessment)
        [ "$(grep -c '^      instructions:' "$wf")" -eq 6 ]
        grep -Fq 'Establish the shared baseline for assessing {{TASK}} read-only.' "$wf"
        grep -Fq 'Assess {{TASK}} for correctness only, read-only' "$wf"
        grep -Fq 'Assess {{TASK}} for security only, read-only' "$wf"
        grep -Fq 'Assess {{TASK}} for performance and resource behavior only, read-only' "$wf"
        grep -Fq 'Assess {{TASK}} for compatibility and operability only, read-only' "$wf"
        grep -Fq 'Synthesize the four independent assessments of {{TASK}}' "$wf"
        ;;
      review-jury)
        [ "$(grep -c '^      instructions:' "$wf")" -eq 2 ]
        [ "$(grep -c '^          instructions:' "$wf")" -eq 3 ]
        grep -Fq 'Prepare a neutral review packet for {{TASK}} read-only.' "$wf"
        grep -Fq 'Review {{TASK}} independently and read-only' "$wf"
        grep -Fq 'Write the operator-facing review report for {{TASK}}' "$wf"
        ;;
      triage)
        [ "$(grep -c '^      instructions:' "$wf")" -eq 4 ]
        grep -Fq 'Classify {{TASK}} read-only so the run can route' "$wf"
        grep -Fq 'Scope {{TASK}} read-only for the shallow route' "$wf"
        grep -Fq 'Investigate {{TASK}} read-only for the deep route' "$wf"
        grep -Fq 'Turn the triage findings for {{TASK}} into an executable recommendation.' "$wf"
        ;;
      *)
        false
        ;;
    esac
  done
}

@test "bundled workflow topology preserved outside mode and runtime conversion" {
  local wf name
  for wf in "$BUNDLED_WORKFLOWS"/*.workflow.md; do
    name="$(basename "$wf" .workflow.md)"
    grep -qx 'mode: dependency' "$wf"
    case "$name" in
      bug-fix)
        grep -q '^  maxParallel: 1$' "$wf"
        grep -q '^  maxReworkIterations: 2$' "$wf"
        grep -q '^  publishMode: on-verified$' "$wf"
        grep -q '^      loopBackTo: implement$' "$wf"
        grep -q '^      onExhausted: fail$' "$wf"
        grep -q '^      workspaceMode: snapshot$' "$wf"
        grep -q '^      agentGitAccess: off$' "$wf"
        grep -q 'verification: Confirm .ralph-workspace/artifacts/{{ARTIFACT_NS}}/investigation.md exists and is non-empty.' "$wf"
        grep -q 'path: .ralph-workspace/artifacts/{{ARTIFACT_NS}}/bug-fix-plan.json' "$wf"
        grep -q 'path: .ralph-workspace/artifacts/{{ARTIFACT_NS}}/bug-fix-qa-plan.json' "$wf"
        # Stage id order preserved.
        awk '
          /^  stages:/{s=1; next}
          s && /^    - id: /{print $3}
          s && /^todos:/{exit}
        ' "$wf" | tr '\n' ' ' | grep -Eq '^investigate plan-implementation implement review integrate plan-qa qa qa-gate ?$'
        ;;
      feature-delivery)
        grep -q '^  maxParallel: 1$' "$wf"
        grep -q '^  maxReworkIterations: 2$' "$wf"
        grep -q '^  publishMode: on-verified$' "$wf"
        grep -q '^      workspaceMode: snapshot$' "$wf"
        grep -q '^      agentGitAccess: off$' "$wf"
        grep -q '^      planFrom: plan-implementation$' "$wf"
        grep -q '^      planFrom: plan-qa$' "$wf"
        awk '
          /^  stages:/{s=1; next}
          s && /^    - id: /{print $3}
          s && /^todos:/{exit}
        ' "$wf" | tr '\n' ' ' | grep -Eq '^investigate plan-implementation implement review integrate plan-qa qa qa-gate ?$'
        refute_cmd grep -q '^    - id: review-approved$' "$wf"
        ;;
      investigation)
        grep -q 'path: .ralph-workspace/artifacts/{{ARTIFACT_NS}}/investigation.md' "$wf"
        grep -q 'path: .ralph-workspace/artifacts/{{ARTIFACT_NS}}/recommended-plan.json' "$wf"
        refute_cmd grep -q 'workspaceMode:' "$wf"
        awk '
          /^  stages:/{s=1; next}
          s && /^    - id: /{print $3}
          s && /^todos:/{exit}
        ' "$wf" | tr '\n' ' ' | grep -Eq '^investigate recommend-plan ?$'
        ;;
      refactor)
        grep -q '^      type: integrate$' "$wf"
        grep -q '^      loopBackTo: implement$' "$wf"
        grep -q '^      onExhausted: fail$' "$wf"
        grep -q '^  maxReworkIterations: 2$' "$wf"
        grep -q '^  publishMode: on-verified$' "$wf"
        grep -q '^      planFrom: plan-implementation$' "$wf"
        grep -q '^      planFrom: plan-qa$' "$wf"
        awk '
          /^  stages:/{s=1; next}
          s && /^    - id: /{print $3}
          s && /^todos:/{exit}
        ' "$wf" | tr '\n' ' ' | grep -Eq '^characterize plan-implementation implement review integrate plan-qa qa qa-gate ?$'
        refute_cmd grep -q '^    - id: review-approved$' "$wf"
        ;;
      human-verified-delivery)
        grep -q '^  maxParallel: 1$' "$wf"
        grep -q '^  maxReworkIterations: 2$' "$wf"
        grep -q '^  publishMode: on-verified$' "$wf"
        grep -q '^      type: approval$' "$wf"
        grep -q '^      changesTarget: plan-implementation$' "$wf"
        grep -q '^      planFrom: plan-implementation$' "$wf"
        grep -q '^      planFrom: plan-qa$' "$wf"
        awk '
          /^  stages:/{s=1; next}
          s && /^    - id: /{print $3}
          s && /^todos:/{exit}
        ' "$wf" | tr '\n' ' ' | grep -Eq '^investigate plan-implementation approve-plan implement review integrate plan-qa qa qa-gate approve-result ?$'
        refute_cmd grep -q '^    - id: review-approved$' "$wf"
        ;;
      plan-delivery)
        grep -q '^planInput:$' "$wf"
        grep -q '^  stage: implement$' "$wf"
        grep -q '^  required: true$' "$wf"
        grep -q '^  maxReworkIterations: 2$' "$wf"
        grep -q '^  publishMode: on-verified$' "$wf"
        grep -q '^      loopBackTo: implement$' "$wf"
        grep -q '^      planFrom: plan-qa$' "$wf"
        awk '
          /^  stages:/{s=1; next}
          s && /^    - id: /{print $3}
          s && /^todos:/{exit}
        ' "$wf" | tr '\n' ' ' | grep -Eq '^implement review integrate plan-qa qa qa-gate ?$'
        refute_cmd grep -q '^    - id: review-approved$' "$wf"
        ;;
      release-gate)
        grep -q '^      planFrom: plan-verification$' "$wf"
        refute_cmd grep -q 'workspaceMode:' "$wf"
        refute_cmd grep -q 'publishMode:' "$wf"
        awk '
          /^  stages:/{s=1; next}
          s && /^    - id: /{print $3}
          s && /^todos:/{exit}
        ' "$wf" | tr '\n' ' ' | grep -Eq '^inspect-candidate plan-verification verify security release-decision release-gate-decision ?$'
        ;;
      assessment)
        grep -q '^  maxParallel: 4$' "$wf"
        grep -q '^  publishMode: manual$' "$wf"
        grep -q '^      type: gate$' "$wf"
        grep -q '^      profile: assessment-verdict$' "$wf"
        refute_cmd grep -q 'workspaceMode:' "$wf"
        refute_cmd grep -q 'planFrom:' "$wf"
        awk '
          /^  stages:/{s=1; next}
          s && /^    - id: /{print $3}
          s && /^todos:/{exit}
        ' "$wf" | tr '\n' ' ' | grep -Eq '^inspect assess-correctness assess-security assess-performance assess-compatibility synthesize assessment-gate ?$'
        ;;
      review-jury)
        grep -q '^  maxParallel: 3$' "$wf"
        grep -q '^  publishMode: manual$' "$wf"
        grep -q '^      type: consensus$' "$wf"
        grep -q '^      type: join$' "$wf"
        grep -q '^      policy: quorum$' "$wf"
        grep -q '^      quorum: 2$' "$wf"
        grep -q '^      minRuntimes: 3$' "$wf"
        # Cross-provider voters are the point; voter runtime pins must survive.
        grep -q '^          runtime: claude$' "$wf"
        grep -q '^          runtime: codex$' "$wf"
        grep -q '^          runtime: cursor$' "$wf"
        refute_cmd grep -q 'workspaceMode:' "$wf"
        awk '
          /^  stages:/{s=1; next}
          s && /^    - id: /{print $3}
          s && /^todos:/{exit}
        ' "$wf" | tr '\n' ' ' | grep -Eq '^prepare-review jury jury-decision report review-gate ?$'
        ;;
      triage)
        grep -q '^  maxParallel: 2$' "$wf"
        grep -q '^  publishMode: manual$' "$wf"
        grep -q '^      router:$' "$wf"
        grep -q '^        defaultTarget: deep-investigation$' "$wf"
        grep -q '^        onInvalid: default$' "$wf"
        grep -q 'path: .ralph-workspace/artifacts/{{ARTIFACT_NS}}/triage-plan.json' "$wf"
        refute_cmd grep -q 'workspaceMode:' "$wf"
        awk '
          /^  stages:/{s=1; next}
          s && /^    - id: /{print $3}
          s && /^todos:/{exit}
        ' "$wf" | tr '\n' ' ' | grep -Eq '^classify scope-request deep-investigation recommend ?$'
        ;;
      *)
        false
        ;;
    esac
  done
}

@test "bundled workflows: stages do not copy unused optional profile artifacts" {
  local wf
  for wf in "$BUNDLED_WORKFLOWS"/*.workflow.md; do
    # Handoff paths from old profiles are optional and unused by downstream
    # requires in bundled workflows; they must not appear as produces.
    refute_cmd grep -E 'handoffs/\{\{ARTIFACT_NS\}\}/' "$wf"
    # code-review.md was the old profile required review file; gates use
    # {{STAGE_ID}}-verdict.json instead when a loopCheck is present.
    if grep -q 'loopCheck:' "$wf"; then
      refute_cmd grep -F 'path: .ralph-workspace/artifacts/{{ARTIFACT_NS}}/code-review.md' "$wf"
    fi
  done
}

@test "instruction only stages invent none of the old profile artifact list" {
  cat >"$TMPD/instruction-only.workflow.md" <<'EOF'
---
name: instruction-only-artifacts
kind: workflow
mode: dependency
pipeline:
  stages:
    - id: research
      runtime: cursor
      instructions: Research only; invent no profile artifacts.
    - id: architecture
      runtime: claude
      instructions: Architecture only; invent no profile artifacts.
      dependsOn:
        - research
    - id: implementation
      runtime: cursor
      instructions: Implementation only; invent no profile artifacts.
      dependsOn:
        - architecture
    - id: code-review
      runtime: codex
      instructions: Code-review only; invent no profile artifacts.
      dependsOn:
        - implementation
    - id: qa
      runtime: cursor
      instructions: QA only; invent no profile artifacts.
      dependsOn:
        - code-review
    - id: security
      runtime: cursor
      instructions: Security only; invent no profile artifacts.
      dependsOn:
        - qa
todos:
  - id: research-1
    stage: research
    content: |
      Instruction-only research for:
      {{TASK}}
    status: pending
  - id: architecture-1
    stage: architecture
    content: |
      Instruction-only architecture for:
      {{TASK}}
    status: pending
  - id: implementation-1
    stage: implementation
    content: |
      Instruction-only implementation for:
      {{TASK}}
    status: pending
  - id: code-review-1
    stage: code-review
    content: |
      Instruction-only code-review for:
      {{TASK}}
    status: pending
  - id: qa-1
    stage: qa
    content: |
      Instruction-only qa for:
      {{TASK}}
    status: pending
  - id: security-1
    stage: security
    content: |
      Instruction-only security for:
      {{TASK}}
    status: pending
---
EOF

  run plan_workflow_instantiate "$TMPD/instruction-only.workflow.md" "no invented outputs" "$TMPD/instruction-only.plan.md"
  [ "$status" -eq 0 ]

  run plan_pipeline_orch_json "$TMPD/instruction-only.plan.md"
  [ "$status" -eq 0 ]

  # No stage declares produces, so the producer map must be empty: instructions
  # never invent research.md / architecture.md / handoffs / etc.
  printf '%s' "$output" | jq -e '
    ((.artifactProducers // {}) | length) == 0
    and
    ([.stages[] | ((.outputArtifacts // []) + (.artifacts // [])) | length] | add // 0) == 0
  ' >/dev/null

  local optional
  for optional in "${OLD_PROFILE_OPTIONAL_PATHS[@]}"; do
    printf '%s' "$output" | jq -e --arg p "$optional" '
      (.artifactProducers // {}) | has($p) | not
    ' >/dev/null
  done

  # Required old-profile paths are also absent when stages invent none.
  printf '%s' "$output" | jq -e '
    (.artifactProducers // {}) as $p
    | (
        $p | has(".ralph-workspace/artifacts/{{ARTIFACT_NS}}/research.md")
        or has(".ralph-workspace/artifacts/{{ARTIFACT_NS}}/architecture.md")
        or has(".ralph-workspace/artifacts/{{ARTIFACT_NS}}/implementation-handoff.md")
        or has(".ralph-workspace/artifacts/{{ARTIFACT_NS}}/code-review.md")
        or has(".ralph-workspace/artifacts/{{ARTIFACT_NS}}/qa-handoff.md")
        or has(".ralph-workspace/artifacts/{{ARTIFACT_NS}}/security.md")
      ) | not
  ' >/dev/null
}

@test "planner config accepts plan-file with default and bounded maxTodos" {
  cat >"$TMPD/wf.md" <<'EOF'
---
name: demo-workflow
kind: workflow
mode: dependency
pipeline:
  stages:
    - id: plan-implementation
      planner:
        outputMode: plan-file
      produces:
        - path: .ralph-workspace/artifacts/{{ARTIFACT_NS}}/impl-plan.json
          schema: bundle/.ralph/schemas/planner-output.schema.json
          required: true
todos:
  - id: plan-work
    stage: plan-implementation
    content: |
      Plan:
      {{TASK}}
    status: pending
---
EOF
  run plan_workflow_validate "$TMPD/wf.md"
  [ "$status" -eq 0 ]
}

@test "planner config max 200 is the hard ceiling" {
  cat >"$TMPD/wf.md" <<'EOF'
---
name: demo-workflow
kind: workflow
mode: dependency
pipeline:
  stages:
    - id: plan-implementation
      planner:
        outputMode: plan-file
        maxTodos: 201
      produces:
        - path: .ralph-workspace/artifacts/{{ARTIFACT_NS}}/impl-plan.json
          schema: bundle/.ralph/schemas/planner-output.schema.json
          required: true
todos:
  - id: plan-work
    stage: plan-implementation
    content: |
      Plan work for:
      {{TASK}}
    status: pending
---
EOF
  run plan_workflow_validate "$TMPD/wf.md"
  [ "$status" -ne 0 ]
  [[ "$output" == *"maxTodos"* ]]
  [[ "$output" == *"200"* ]]
}

@test "planFrom accepts a single consumer of a direct dependency planner" {
  cat >"$TMPD/wf.md" <<'EOF'
---
name: demo-workflow
kind: workflow
mode: dependency
pipeline:
  stages:
    - id: plan-implementation
      planner:
        outputMode: plan-file
        maxTodos: 40
      produces:
        - path: .ralph-workspace/artifacts/{{ARTIFACT_NS}}/impl-plan.json
          schema: bundle/.ralph/schemas/planner-output.schema.json
          required: true
    - id: implement
      planFrom: plan-implementation
      dependsOn:
        - plan-implementation
      produces:
        - path: .ralph-workspace/artifacts/{{ARTIFACT_NS}}/implementation-handoff.md
          required: true
todos:
  - id: plan-work
    stage: plan-implementation
    content: |
      Plan work for:
      {{TASK}}
    status: pending
---
EOF
  run plan_workflow_validate "$TMPD/wf.md"
  [ "$status" -eq 0 ]
}

@test "recommended plan allows a planner with zero planFrom consumers" {
  cat >"$TMPD/wf.md" <<'EOF'
---
name: demo-workflow
kind: workflow
mode: dependency
pipeline:
  stages:
    - id: recommend-plan
      planner:
        outputMode: plan-file
        maxTodos: 100
      produces:
        - path: .ralph-workspace/artifacts/{{ARTIFACT_NS}}/recommended-plan.json
          schema: bundle/.ralph/schemas/planner-output.schema.json
          required: true
todos:
  - id: recommend-work
    stage: recommend-plan
    content: |
      Recommend next steps for:
      {{TASK}}
    status: pending
---
EOF
  run plan_workflow_validate "$TMPD/wf.md"
  [ "$status" -eq 0 ]
}

@test "planFrom requires a direct dependency planner" {
  cat >"$TMPD/wf.md" <<'EOF'
---
name: demo-workflow
kind: workflow
mode: dependency
pipeline:
  stages:
    - id: plan-implementation
      planner:
        outputMode: plan-file
      produces:
        - path: .ralph-workspace/artifacts/{{ARTIFACT_NS}}/impl-plan.json
          schema: bundle/.ralph/schemas/planner-output.schema.json
          required: true
    - id: implement
      planFrom: plan-implementation
      produces:
        - path: .ralph-workspace/artifacts/{{ARTIFACT_NS}}/implementation-handoff.md
          required: true
todos:
  - id: plan-work
    stage: plan-implementation
    content: |
      Plan:
      {{TASK}}
    status: pending
---
EOF
  run plan_workflow_validate "$TMPD/wf.md"
  [ "$status" -ne 0 ]
  [[ "$output" == *"planFrom"* ]]
  [[ "$output" == *"direct"* ]] || [[ "$output" == *"dependsOn"* ]]
}

@test "single consumer is required when multiple planFrom stages share a planner" {
  cat >"$TMPD/wf.md" <<'EOF'
---
name: demo-workflow
kind: workflow
mode: dependency
pipeline:
  stages:
    - id: plan-implementation
      planner:
        outputMode: plan-file
      produces:
        - path: .ralph-workspace/artifacts/{{ARTIFACT_NS}}/impl-plan.json
          schema: bundle/.ralph/schemas/planner-output.schema.json
          required: true
    - id: implement-a
      planFrom: plan-implementation
      dependsOn:
        - plan-implementation
    - id: implement-b
      planFrom: plan-implementation
      dependsOn:
        - plan-implementation
todos:
  - id: plan-work
    stage: plan-implementation
    content: |
      Plan:
      {{TASK}}
    status: pending
---
EOF
  run plan_workflow_validate "$TMPD/wf.md"
  [ "$status" -ne 0 ]
  [[ "$output" == *"planFrom"* ]] || [[ "$output" == *"consumer"* ]]
}

@test "unique planner artifact is required on planner stages" {
  cat >"$TMPD/wf.md" <<'EOF'
---
name: demo-workflow
kind: workflow
mode: dependency
pipeline:
  stages:
    - id: plan-implementation
      planner:
        outputMode: plan-file
      produces:
        - path: .ralph-workspace/artifacts/{{ARTIFACT_NS}}/notes.md
          required: true
todos:
  - id: plan-work
    stage: plan-implementation
    content: |
      Plan:
      {{TASK}}
    status: pending
---
EOF
  run plan_workflow_validate "$TMPD/wf.md"
  [ "$status" -ne 0 ]
  [[ "$output" == *"planner"* ]]
  [[ "$output" == *"planner-output.schema.json"* ]] || [[ "$output" == *".json"* ]]
}

@test "mutual exclusion rejects planFrom with planFile" {
  cat >"$TMPD/wf.md" <<'EOF'
---
name: demo-workflow
kind: workflow
mode: dependency
pipeline:
  stages:
    - id: plan-implementation
      planner:
        outputMode: plan-file
      produces:
        - path: .ralph-workspace/artifacts/{{ARTIFACT_NS}}/impl-plan.json
          schema: bundle/.ralph/schemas/planner-output.schema.json
          required: true
    - id: implement
      planFrom: plan-implementation
      planFile: .ralph-workspace/plans/other.plan.md
      dependsOn:
        - plan-implementation
todos:
  - id: plan-work
    stage: plan-implementation
    content: |
      Plan:
      {{TASK}}
    status: pending
---
EOF
  run plan_workflow_validate "$TMPD/wf.md"
  [ "$status" -ne 0 ]
  [[ "$output" == *"planFrom"* ]]
  [[ "$output" == *"planFile"* ]] || [[ "$output" == *"mutually exclusive"* ]]
}

@test "prohibited node types cannot declare planner or planFrom" {
  cat >"$TMPD/wf.md" <<'EOF'
---
name: demo-workflow
kind: workflow
mode: dependency
pipeline:
  stages:
    - id: integrate-node
      type: integrate
      workspaceMode: snapshot
      planner:
        outputMode: plan-file
      produces:
        - path: .ralph-workspace/artifacts/{{ARTIFACT_NS}}/impl-plan.json
          schema: bundle/.ralph/schemas/planner-output.schema.json
          required: true
todos:
  - id: noop
    stage: integrate-node
    content: |
      noop
      {{TASK}}
    status: pending
---
EOF
  run plan_workflow_validate "$TMPD/wf.md"
  [ "$status" -ne 0 ]
  [[ "$output" == *"planner"* ]]
  [[ "$output" == *"integrate"* ]]
}

# --- materialized routing / instructions / atomic write (routing TODO) --------

@test "materialized routing fills unresolved stages from fallback_runtime" {
  cat >"$TMPD/wf.md" <<'EOF'
---
name: routing-fill
kind: workflow
mode: dependency
pipeline:
  stages:
    - id: research
      instructions: Keep research read-only.
    - id: plan-implementation
      planner:
        outputMode: plan-file
        maxTodos: 20
      produces:
        - path: .ralph-workspace/artifacts/{{ARTIFACT_NS}}/impl-plan.json
          schema: bundle/.ralph/schemas/planner-output.schema.json
          required: true
      dependsOn:
        - research
    - id: implement
      planFrom: plan-implementation
      dependsOn:
        - plan-implementation
      produces:
        - path: .ralph-workspace/artifacts/{{ARTIFACT_NS}}/implementation-handoff.md
          required: true
todos:
  - id: research-1
    stage: research
    content: Investigate {{TASK}}
    status: pending
  - id: plan-1
    stage: plan-implementation
    content: Plan {{TASK}}
    status: pending
---
EOF
  run plan_workflow_instantiate "$TMPD/wf.md" "fix login" "$TMPD/out.plan.md" \
    fallback_runtime=claude metadata_out="$TMPD/meta.json"
  [ "$status" -eq 0 ]
  grep -qx 'execution: graph' "$TMPD/out.plan.md"
  refute_cmd grep -E '^(kind|mode|defaults|planInput):' "$TMPD/out.plan.md"
  # Planner and planFrom consumer inherit the same fallback.
  awk '/^    - id: research$/{p=1;next} p && /^    - id:/{exit} p && /^      runtime:/{print}' "$TMPD/out.plan.md" \
    | grep -qx '      runtime: claude'
  awk '/^    - id: plan-implementation$/{p=1;next} p && /^    - id:/{exit} p && /^      runtime:/{print}' "$TMPD/out.plan.md" \
    | grep -qx '      runtime: claude'
  awk '/^    - id: implement$/{p=1;next} p && /^    - id:/{exit} p && /^      runtime:/{print}' "$TMPD/out.plan.md" \
    | grep -qx '      runtime: claude'
  grep -Fq 'Keep research read-only.' "$TMPD/out.plan.md"
  grep -Fq 'planFrom: plan-implementation' "$TMPD/out.plan.md"
  grep -Fq 'planner:' "$TMPD/out.plan.md"
  # Skipped model: no model keys invented.
  refute_cmd grep -E '^[[:space:]]+model:' "$TMPD/out.plan.md"
  # TODOs must not gain routing.
  refute_cmd awk '/^todos:/{p=1} p && /^[[:space:]]+runtime:/{found=1} END{exit found?0:1}' "$TMPD/out.plan.md"
  [ -s "$TMPD/meta.json" ]
  python3 -c 'import json,sys; m=json.load(open(sys.argv[1])); assert m["mode"]=="dependency"; assert m["execution"]=="graph"' "$TMPD/meta.json"
  run plan_pipeline_validate_plan "$TMPD/out.plan.md"
  [ "$status" -eq 0 ]
}

@test "materialized routing instructions preserved with explicit override" {
  cat >"$TMPD/wf.md" <<'EOF'
---
name: explicit-override
kind: workflow
mode: sequential
defaults:
  runtime: cursor
  model: auto
pipeline:
  stages:
    - id: research
      instructions: Research guidance stays.
    - id: implement
      runtime: claude
      model: sonnet
      instructions: Implement with override.
      dependsOn:
        - research
todos:
  - id: research-1
    stage: research
    content: Research {{TASK}}
    status: pending
  - id: implement-1
    stage: implement
    content: Implement {{TASK}}
    status: pending
---
EOF
  run plan_workflow_instantiate "$TMPD/wf.md" "ship" "$TMPD/out.plan.md" \
    fallback_runtime=codex fallback_model=gpt-x
  [ "$status" -eq 0 ]
  grep -qx 'execution: orchestration' "$TMPD/out.plan.md"
  refute_cmd grep -E '^defaults:' "$TMPD/out.plan.md"
  # Unresolved research gets invocation fallback (wins over workflow defaults).
  awk '/^    - id: research$/{p=1;next} p && /^    - id:/{exit} p && /^      runtime:/{print}' "$TMPD/out.plan.md" \
    | grep -qx '      runtime: codex'
  awk '/^    - id: research$/{p=1;next} p && /^    - id:/{exit} p && /^      model:/{print}' "$TMPD/out.plan.md" \
    | grep -qx '      model: gpt-x'
  # Explicit stage override preserved.
  awk '/^    - id: implement$/{p=1;next} p && /^    - id:/{exit} p && /^      runtime:/{print}' "$TMPD/out.plan.md" \
    | grep -qx '      runtime: claude'
  awk '/^    - id: implement$/{p=1;next} p && /^    - id:/{exit} p && /^      model:/{print}' "$TMPD/out.plan.md" \
    | grep -qx '      model: sonnet'
  grep -Fq 'Research guidance stays.' "$TMPD/out.plan.md"
  grep -Fq 'Implement with override.' "$TMPD/out.plan.md"
}

@test "different runtime stage override drops unpaired fallback model" {
  cat >"$TMPD/wf.md" <<'EOF'
---
name: different-runtime
kind: workflow
mode: dependency
pipeline:
  stages:
    - id: research
    - id: review
      runtime: cursor
      dependsOn:
        - research
todos:
  - id: research-1
    stage: research
    content: Research {{TASK}}
    status: pending
  - id: review-1
    stage: review
    content: Review {{TASK}}
    status: pending
---
EOF
  run plan_workflow_instantiate "$TMPD/wf.md" "task" "$TMPD/out.plan.md" \
    fallback_runtime=claude fallback_model=opus
  [ "$status" -eq 0 ]
  awk '/^    - id: research$/{p=1;next} p && /^    - id:/{exit} p && /^      runtime:/{print}' "$TMPD/out.plan.md" \
    | grep -qx '      runtime: claude'
  awk '/^    - id: research$/{p=1;next} p && /^    - id:/{exit} p && /^      model:/{print}' "$TMPD/out.plan.md" \
    | grep -qx '      model: opus'
  awk '/^    - id: review$/{p=1;next} p && /^    - id:/{exit} p && /^      runtime:/{print}' "$TMPD/out.plan.md" \
    | grep -qx '      runtime: cursor'
  # Explicit different runtime must not inherit unpaired fallback model.
  refute_cmd awk '/^    - id: review$/{p=1;next} p && /^    - id:/{exit} p && /^      model:/{found=1} END{exit found?0:1}' "$TMPD/out.plan.md"
}

@test "provided plan header applies only to designated planInput consumer" {
  cat >"$TMPD/wf.md" <<'EOF'
---
name: provided-plan-routing
kind: workflow
mode: dependency
planInput:
  stage: implement
pipeline:
  stages:
    - id: plan-implementation
      planner:
        outputMode: plan-file
      produces:
        - path: .ralph-workspace/artifacts/{{ARTIFACT_NS}}/impl-plan.json
          schema: bundle/.ralph/schemas/planner-output.schema.json
          required: true
    - id: implement
      planFrom: plan-implementation
      dependsOn:
        - plan-implementation
      produces:
        - path: .ralph-workspace/artifacts/{{ARTIFACT_NS}}/implementation-handoff.md
          required: true
    - id: qa
      dependsOn:
        - implement
todos:
  - id: plan-1
    stage: plan-implementation
    content: Plan {{TASK}}
    status: pending
  - id: qa-1
    stage: qa
    content: QA {{TASK}}
    status: pending
---
EOF
  # Byte-identical supplied plan fixture must remain untouched.
  cat >"$TMPD/supplied.plan.md" <<'EOF'
---
name: supplied
overview: Operator leaf plan
runtime: antigravity
model: agy-1
todos:
  - id: t1
    content: do work
    status: pending
---
EOF
  cp "$TMPD/supplied.plan.md" "$TMPD/supplied.plan.md.bak"
  run plan_workflow_instantiate "$TMPD/wf.md" "ship" "$TMPD/out.plan.md" \
    fallback_runtime=cursor \
    provided_plan_runtime=antigravity provided_plan_model=agy-1
  [ "$status" -eq 0 ]
  refute_cmd grep -E '^planInput:' "$TMPD/out.plan.md"
  # Consumer gets provided-plan header (between invocation and workflow; no stage pin).
  # Invocation fallback_runtime=cursor wins for all unresolved including consumer.
  awk '/^    - id: implement$/{p=1;next} p && /^    - id:/{exit} p && /^      runtime:/{print}' "$TMPD/out.plan.md" \
    | grep -qx '      runtime: cursor'
  awk '/^    - id: qa$/{p=1;next} p && /^    - id:/{exit} p && /^      runtime:/{print}' "$TMPD/out.plan.md" \
    | grep -qx '      runtime: cursor'
  # Without invocation, provided-plan would fill only the consumer — cover that path.
  rm -f "$TMPD/out2.plan.md"
  run plan_workflow_instantiate "$TMPD/wf.md" "ship" "$TMPD/out2.plan.md" \
    provided_plan_runtime=antigravity provided_plan_model=agy-1
  [ "$status" -eq 0 ]
  awk '/^    - id: implement$/{p=1;next} p && /^    - id:/{exit} p && /^      runtime:/{print}' "$TMPD/out2.plan.md" \
    | grep -qx '      runtime: antigravity'
  awk '/^    - id: implement$/{p=1;next} p && /^    - id:/{exit} p && /^      model:/{print}' "$TMPD/out2.plan.md" \
    | grep -qx '      model: agy-1'
  # Non-consumer qa must not receive provided-plan header.
  refute_cmd awk '/^    - id: qa$/{p=1;next} p && /^    - id:/{exit} p && /^      runtime: antigravity/{found=1} END{exit found?0:1}' "$TMPD/out2.plan.md"
  refute_cmd awk '/^    - id: qa$/{p=1;next} p && /^    - id:/{exit} p && /^      model: agy-1/{found=1} END{exit found?0:1}' "$TMPD/out2.plan.md"
  refute_cmd awk '/^    - id: plan-implementation$/{p=1;next} p && /^    - id:/{exit} p && /^      runtime: antigravity/{found=1} END{exit found?0:1}' "$TMPD/out2.plan.md"
  cmp -s "$TMPD/supplied.plan.md" "$TMPD/supplied.plan.md.bak"
}

@test "approval nodes stay routing-free after materialization" {
  cat >"$TMPD/wf.md" <<'EOF'
---
name: approval-routing
kind: workflow
mode: dependency
pipeline:
  stages:
    - id: plan-implementation
      planner:
        outputMode: plan-file
        maxTodos: 20
      produces:
        - path: .ralph-workspace/artifacts/{{ARTIFACT_NS}}/impl-plan.json
          schema: bundle/.ralph/schemas/planner-output.schema.json
          required: true
    - id: approve-plan
      type: approval
      question: Approve the concrete implementation plan?
      changesTarget: plan-implementation
      dependsOn:
        - plan-implementation
      requires:
        - path: .ralph-workspace/artifacts/{{ARTIFACT_NS}}/impl-plan.json
          schema: bundle/.ralph/schemas/planner-output.schema.json
          required: true
    - id: implement
      planFrom: plan-implementation
      dependsOn:
        - approve-plan
        - plan-implementation
      produces:
        - path: .ralph-workspace/artifacts/{{ARTIFACT_NS}}/implementation-handoff.md
          required: true
todos:
  - id: plan-work
    stage: plan-implementation
    content: Plan {{TASK}}
    status: pending
---
EOF
  run plan_workflow_instantiate "$TMPD/wf.md" "ship" "$TMPD/out.plan.md" fallback_runtime=cursor
  [ "$status" -eq 0 ]
  grep -Fq 'type: approval' "$TMPD/out.plan.md"
  grep -Fq 'question: Approve the concrete implementation plan?' "$TMPD/out.plan.md"
  refute_cmd awk '/^    - id: approve-plan$/{p=1;next} p && /^    - id:/{exit} p && /^      runtime:/{found=1} END{exit found?0:1}' "$TMPD/out.plan.md"
  refute_cmd awk '/^    - id: approve-plan$/{p=1;next} p && /^    - id:/{exit} p && /^      model:/{found=1} END{exit found?0:1}' "$TMPD/out.plan.md"
  awk '/^    - id: implement$/{p=1;next} p && /^    - id:/{exit} p && /^      runtime:/{print}' "$TMPD/out.plan.md" \
    | grep -qx '      runtime: cursor'
}

@test "skipped model leaves model absent on filled stages" {
  cat >"$TMPD/wf.md" <<'EOF'
---
name: skipped-model
kind: workflow
mode: dependency
pipeline:
  stages:
    - id: research
todos:
  - id: research-1
    stage: research
    content: Research {{TASK}}
    status: pending
---
EOF
  run plan_workflow_instantiate "$TMPD/wf.md" "task" "$TMPD/out.plan.md" fallback_runtime=opencode
  [ "$status" -eq 0 ]
  grep -qx '      runtime: opencode' "$TMPD/out.plan.md"
  refute_cmd grep -E '^[[:space:]]+model:' "$TMPD/out.plan.md"
}

@test "source unchanged and atomic write refuse overwrite" {
  cat >"$TMPD/wf.md" <<'EOF'
---
name: atomic-source
kind: workflow
mode: dependency
pipeline:
  stages:
    - id: research
      runtime: cursor
      instructions: Do not mutate source.
todos:
  - id: research-1
    stage: research
    content: Research {{TASK}}
    status: pending
---
EOF
  cp "$TMPD/wf.md" "$TMPD/wf.md.bak"
  run plan_workflow_instantiate "$TMPD/wf.md" "task" "$TMPD/out.plan.md"
  [ "$status" -eq 0 ]
  cmp -s "$TMPD/wf.md" "$TMPD/wf.md.bak"
  grep -Fq 'Do not mutate source.' "$TMPD/out.plan.md"
  run plan_workflow_instantiate "$TMPD/wf.md" "task" "$TMPD/out.plan.md"
  [ "$status" -ne 0 ]
  [[ "$output" == *"refusing to overwrite"* ]]
  cmp -s "$TMPD/wf.md" "$TMPD/wf.md.bak"
}

@test "bug-fix SDLC structural and materialization case" {
  local wf="$BUNDLED_WORKFLOWS/bug-fix.workflow.md"
  [ -f "$wf" ]
  grep -qx 'mode: dependency' "$wf"
  refute_cmd grep -E '^(engine|defaults):' "$wf"
  refute_cmd grep -E '^[[:space:]]+(runtime|model|role|agent):' "$wf"
  awk '
    /^  stages:/{s=1; next}
    s && /^    - id: /{print $3}
    s && /^todos:/{exit}
  ' "$wf" | tr '\n' ' ' \
    | grep -Eq '^investigate plan-implementation implement review integrate plan-qa qa qa-gate ?$'
  refute_cmd grep -E '^    - id: review-approved$' "$wf"
}

@test "bug-fix artifacts and plan-backed rework case" {
  local wf="$BUNDLED_WORKFLOWS/bug-fix.workflow.md"
  grep -q '^      planFrom: plan-implementation$' "$wf"
  grep -q '^      planFrom: plan-qa$' "$wf"
  grep -q '^      loopBackTo: implement$' "$wf"
  grep -q '^        outputMode: plan-file$' "$wf"
  [ "$(grep -c '^        outputMode: plan-file$' "$wf")" -eq 2 ]
  [ "$(grep -c '^        maxTodos: 40$' "$wf")" -eq 2 ]
  for artifact in investigation.md bug-fix-plan.json implementation-handoff.md \
    "{{STAGE_ID}}-verdict.json" bug-fix-qa-plan.json qa-handoff.md; do
    grep -q ".ralph-workspace/artifacts/{{ARTIFACT_NS}}/$artifact" "$wf"
  done
  refute_cmd awk '/^    - id: implement$/{p=1;next} p && /^    - id:/{exit} p && /^      - id:/{found=1} END{exit found?0:1}' "$wf"
  refute_cmd awk '/^    - id: qa$/{p=1;next} p && /^    - id:/{exit} p && /^      - id:/{found=1} END{exit found?0:1}' "$wf"
}

@test "routing neutral reusable task materialization" {
  local wf="$BUNDLED_WORKFLOWS/bug-fix.workflow.md"
  local out="$TMPD/bug-fix.plan.md"
  run plan_workflow_validate "$wf"
  [ "$status" -eq 0 ]
  run plan_workflow_instantiate "$wf" "Fix {{literal}} behavior" "$out" fallback_runtime=cursor
  [ "$status" -eq 0 ]
  assert_task_resolved_in_todos "$out"
  refute_cmd grep -E '^(kind|mode|engine|defaults):' "$out"
  run plan_pipeline_graph_json "$out"
  [ "$status" -eq 0 ]
  printf '%s' "$output" | jq -e '
    ([.nodes[] | select(.id == "investigate") ] | length) == 1
    and ([.nodes[] | select(.id == "review-approved" and .type == "join")] | length) == 1
    and ([.nodes[] | select(.id == "implement") | .stage.planFrom] | .[0]) == "plan-implementation"
    and ([.nodes[] | select(.id == "qa") | .stage.planFrom] | .[0]) == "plan-qa"
  ' >/dev/null
  grep -Fq 'Fix {{literal}} behavior' "$out"
  grep -Fq 'bug-fix-plan.json' "$out"
  grep -Fq 'bug-fix-qa-plan.json' "$out"
}

@test "one TODO is allowed for atomic implementation and QA plans" {
  local wf="$BUNDLED_WORKFLOWS/bug-fix.workflow.md"
  # 4 authored stage todos plus the qa-gate todo.
  [ "$(awk '/^todos:/{p=1;next} p && /^  - id:/{count++} END{print count+0}' "$wf")" -eq 5 ]
  refute_cmd grep -E '^    stage: (implement|qa)$' "$wf"
  grep -Fq 'smallest independently verifiable implementation plan' "$wf"
  grep -Fq 'smallest independent QA plan' "$wf"
}

@test "human-verified delivery SDLC has the exact two-gate topology" {
  local wf="$BUNDLED_WORKFLOWS/human-verified-delivery.workflow.md"
  [ -f "$wf" ]
  grep -qx 'name: human-verified-delivery' "$wf"
  grep -qx 'mode: dependency' "$wf"
  refute_cmd grep -E '^(engine|defaults):' "$wf"
  refute_cmd grep -E '^[[:space:]]+(runtime|model|role|agent):' "$wf"
  awk '
    /^  stages:/{s=1; next}
    s && /^    - id: /{print $3}
    s && /^todos:/{exit}
  ' "$wf" | tr '\n' ' ' | grep -Eq '^investigate plan-implementation approve-plan implement review integrate plan-qa qa qa-gate approve-result ?$'
  refute_cmd grep -q '^    - id: review-approved$' "$wf"
  [ "$(grep -c '^      type: approval$' "$wf")" -eq 2 ]
  # Neither gate carries agent, routing, or mutation fields.
  refute_cmd awk '/^    - id: approve-plan$/{p=1;next} p && /^    - id:/{exit} p && /^      (instructions|runtime|model|role|agent|planner|planFrom|planFile|workspaceMode|writeScopes|agentGitAccess|produces):/{found=1} END{exit found?0:1}' "$wf"
  refute_cmd awk '/^    - id: approve-result$/{p=1;next} p && /^    - id:/{exit} p && /^      (instructions|runtime|model|role|agent|planner|planFrom|planFile|workspaceMode|writeScopes|agentGitAccess|produces):/{found=1} END{exit found?0:1}' "$wf"
}

@test "human-verified approve plan gate holds before any code change" {
  local wf="$BUNDLED_WORKFLOWS/human-verified-delivery.workflow.md"
  # Exact dependsOn: [plan-implementation].
  awk '/^    - id: approve-plan$/{p=1;next} p && /^    - id:/{exit}
       p && /^      dependsOn:$/{d=1;next} d && /^      [a-zA-Z]/{d=0}
       d && /^        - /{sub(/^        - /,""); print}' "$wf" \
    | tr '\n' ' ' | grep -Eq '^plan-implementation ?$'
  awk '/^    - id: approve-plan$/{p=1;next} p && /^    - id:/{exit} p && /^      changesTarget: plan-implementation$/{found=1} END{exit found?0:1}' "$wf"
  awk '/^    - id: approve-plan$/{p=1;next} p && /^    - id:/{exit} p && /^      question: /{found=1} END{exit found?0:1}' "$wf"
  # It reviews the investigation and the generated planner JSON.
  awk '/^    - id: approve-plan$/{p=1;next} p && /^    - id:/{exit} p && /human-verified-investigation.md/{found=1} END{exit found?0:1}' "$wf"
  awk '/^    - id: approve-plan$/{p=1;next} p && /^    - id:/{exit} p && /human-verified-plan.json/{found=1} END{exit found?0:1}' "$wf"
  # Implementation cannot start before the gate.
  awk '/^    - id: implement$/{p=1;next} p && /^    - id:/{exit} p && /^        - approve-plan$/{found=1} END{exit found?0:1}' "$wf"
}

@test "human-verified approve result gate is the terminal hold" {
  local wf="$BUNDLED_WORKFLOWS/human-verified-delivery.workflow.md"
  # Exact dependsOn: [qa-gate, integrate, review-approved]. The human approves
  # after the automated QA verdict gate has passed, not concurrently with it.
  awk '/^    - id: approve-result$/{p=1;next} p && /^    - id:/{exit}
       p && /^      dependsOn:$/{d=1;next} d && /^      [a-zA-Z]/{d=0}
       d && /^        - /{sub(/^        - /,""); print}' "$wf" \
    | tr '\n' ' ' | grep -Eq '^qa-gate integrate review-approved ?$'
  # Same changes target, so requested changes regenerate the plan and rerun the closure.
  awk '/^    - id: approve-result$/{p=1;next} p && /^    - id:/{exit} p && /^      changesTarget: plan-implementation$/{found=1} END{exit found?0:1}' "$wf"
  # Frozen evidence: investigation, both handoffs, and the review verdict.
  local artifact
  for artifact in human-verified-investigation.md human-verified-implementation-handoff.md \
    human-verified-qa-handoff.md review-verdict.json; do
    awk -v a="$artifact" '/^    - id: approve-result$/{p=1;next} p && /^    - id:/{exit} p && index($0, a){found=1} END{exit found?0:1}' "$wf"
  done
  # Nothing depends on the terminal gate.
  refute_cmd grep -q '^        - approve-result$' "$wf"
}

@test "human-verified plan-backed implementation and independent QA match feature delivery" {
  local wf="$BUNDLED_WORKFLOWS/human-verified-delivery.workflow.md"
  [ "$(grep -c '^        outputMode: plan-file$' "$wf")" -eq 2 ]
  [ "$(grep -c '^        maxTodos: 200$' "$wf")" -eq 2 ]
  grep -q '^      planFrom: plan-implementation$' "$wf"
  grep -q '^      planFrom: plan-qa$' "$wf"
  refute_cmd grep -E '^    stage: (implement|qa)$' "$wf"
  [ "$(grep -c '^      writeScopes: \["\*\*"\]$' "$wf")" -eq 1 ]
  grep -q '^      agentGitAccess: off$' "$wf"
  grep -q '^      loopBackTo: implement$' "$wf"
  grep -q '^      onExhausted: fail$' "$wf"
  awk '/^    - id: plan-qa$/{p=1;next} p && /^    - id:/{exit} p && /^        - integrate$/{found=1} END{exit found?0:1}' "$wf"
  # Distinct human-verified artifact names, not the feature-delivery ones.
  refute_cmd grep -F 'artifacts/{{ARTIFACT_NS}}/feature-investigation.md' "$wf"
  refute_cmd grep -F 'artifacts/{{ARTIFACT_NS}}/feature-delivery-plan.json' "$wf"
  refute_cmd grep -F 'artifacts/{{ARTIFACT_NS}}/feature-qa-plan.json' "$wf"
}

@test "human-verified delivery is routing neutral and reusable task materializes" {
  local wf="$BUNDLED_WORKFLOWS/human-verified-delivery.workflow.md"
  local out="$TMPD/human-verified.plan.md"
  run plan_workflow_validate "$wf"
  [ "$status" -eq 0 ]
  run plan_workflow_instantiate "$wf" 'Ship {{literal}} & "$HOME" feature' "$out" fallback_runtime=cursor
  [ "$status" -eq 0 ]
  assert_task_resolved_in_todos "$out"
  refute_cmd grep -E '^(kind|mode|engine|defaults):' "$out"
  grep -Fq 'Ship {{literal}} & "$HOME" feature' "$out"
  assert_bundled_requires_have_one_producer "$wf"
  run plan_pipeline_graph_json "$out"
  [ "$status" -eq 0 ]
  printf '%s' "$output" | jq -e '
    ([.nodes[] | select(.type == "approval")] | length) == 2
    and ([.nodes[] | select(.id == "review-approved" and .type == "join")] | length) == 1
    and ([.nodes[] | select(.id == "integrate" and .type == "integrate")] | length) == 1
    and ([.nodes[] | select(.type == "approval") | .stage.changesTarget] | unique) == ["plan-implementation"]
    and ([.nodes[] | select(.id == "approve-result") | .stage.dependsOn] | .[0]) == ["qa-gate", "integrate", "review-approved"]
  ' >/dev/null
}

@test "plan-delivery SDLC has the exact supplied-plan topology" {
  local wf="$BUNDLED_WORKFLOWS/plan-delivery.workflow.md"
  [ -f "$wf" ]
  grep -qx 'name: plan-delivery' "$wf"
  grep -qx 'mode: dependency' "$wf"
  grep -qx 'planInput:' "$wf"
  grep -qx '  stage: implement' "$wf"
  grep -qx '  required: true' "$wf"
  grep -qx '  maxReworkIterations: 2' "$wf"
  grep -qx '  publishMode: on-verified' "$wf"
  refute_cmd grep -E '^(engine|defaults):' "$wf"
  refute_cmd grep -E '^[[:space:]]+(runtime|model|role|agent):' "$wf"
  awk '
    /^  stages:/{s=1; next}
    s && /^    - id: /{print $3}
    s && /^todos:/{exit}
  ' "$wf" | tr '\n' ' ' | grep -Eq '^implement review integrate plan-qa qa qa-gate ?$'
  refute_cmd grep -q '^    - id: review-approved$' "$wf"
  # No research or planning prelude and no synthetic investigation artifact.
  refute_cmd grep -q '^    - id: investigate$' "$wf"
  refute_cmd grep -q '^    - id: plan-implementation$' "$wf"
  refute_cmd grep -F 'artifacts/{{ARTIFACT_NS}}/investigation.md' "$wf"
  refute_cmd grep -F 'artifacts/{{ARTIFACT_NS}}/feature-investigation.md' "$wf"
}

@test "plan-delivery required plan input refuses a task-only start" {
  local wf="$BUNDLED_WORKFLOWS/plan-delivery.workflow.md"
  local out="$TMPD/plan-delivery-task-only.plan.md"
  run plan_workflow_validate "$wf"
  [ "$status" -eq 0 ]
  run plan_workflow_instantiate "$wf" 'Deliver {{literal}} & "$HOME" plan' "$out" fallback_runtime=cursor
  [ "$status" -ne 0 ]
  [[ "$output" == *"INPUT_PLAN"* ]] || [[ "$output" == *"planInput"* ]]
  [ ! -e "$out" ]
}

@test "plan-delivery provided implement binds the supplied source and owns no plan of its own" {
  local wf="$BUNDLED_WORKFLOWS/plan-delivery.workflow.md"
  # The consumer takes the supplied plan, never a generated or static one.
  refute_cmd awk '/^    - id: implement$/{p=1;next} p && /^    - id:/{exit} p && /^      (planner|planFrom|planFile):/{found=1} END{exit found?0:1}' "$wf"
  # ... and owns no authored TODO.
  refute_cmd grep -E '^    stage: implement$' "$wf"
  # Snapshot isolation with the only write scope in the workflow.
  [ "$(grep -c '^      writeScopes: \["\*\*"\]$' "$wf")" -eq 1 ]
  grep -q '^      agentGitAccess: off$' "$wf"
  awk '/^    - id: implement$/{p=1;next} p && /^    - id:/{exit} p && /^      workspaceMode: snapshot$/{found=1} END{exit found?0:1}' "$wf"
  # The handoff records the supplied source binding.
  grep -Fq 'supplied source path and hash' "$wf"
  grep -Fq 'control copy path' "$wf"
  grep -Fq 'completed and total TODO counts' "$wf"
}

@test "plan-delivery provided rework and integration stay supervisor owned" {
  local wf="$BUNDLED_WORKFLOWS/plan-delivery.workflow.md"
  grep -q '^      loopBackTo: implement$' "$wf"
  grep -q '^      onExhausted: fail$' "$wf"
  awk '/^    - id: review$/{p=1;next} p && /^    - id:/{exit} p && /schema: bundle\/.ralph\/schemas\/evaluator-verdict.schema.json/{found=1} END{exit found?0:1}' "$wf"
  grep -Fq 'fresh control copy of the same' "$wf"
  awk '/^    - id: integrate$/{p=1;next} p && /^    - id:/{exit} p && /^      type: integrate$/{found=1} END{exit found?0:1}' "$wf"
  awk '/^    - id: integrate$/{p=1;next} p && /^    - id:/{exit} p && /^        - review-approved$/{found=1} END{exit found?0:1}' "$wf"
  refute_cmd awk '/^    - id: integrate$/{p=1;next} p && /^    - id:/{exit} p && /^      (instructions|runtime|model|role|agent|writeScopes):/{found=1} END{exit found?0:1}' "$wf"
}

@test "plan-delivery independent QA is generated after integration" {
  local wf="$BUNDLED_WORKFLOWS/plan-delivery.workflow.md"
  awk '/^    - id: plan-qa$/{p=1;next} p && /^    - id:/{exit} p && /^        - integrate$/{found=1} END{exit found?0:1}' "$wf"
  grep -q '^        outputMode: plan-file$' "$wf"
  grep -q '^        maxTodos: 200$' "$wf"
  grep -q ".ralph-workspace/artifacts/{{ARTIFACT_NS}}/plan-delivery-qa-plan.json" "$wf"
  grep -q '^      planFrom: plan-qa$' "$wf"
  refute_cmd grep -E '^    stage: qa$' "$wf"
  grep -q ".ralph-workspace/artifacts/{{ARTIFACT_NS}}/qa-handoff.md" "$wf"
}

@test "plan-delivery INPUT_PLAN and routing neutrality hold on the source" {
  local wf="$BUNDLED_WORKFLOWS/plan-delivery.workflow.md"
  # Every executable stage instruction is driven by the task and the supplied plan.
  [ "$(grep -c '{{INPUT_PLAN}}' "$wf")" -ge 6 ]
  [ "$(grep -c '{{TASK}}' "$wf")" -ge 6 ]
  assert_bundled_requires_have_one_producer "$wf"
}

@test "release-gate SDLC has the exact branch and join topology" {
  local wf="$BUNDLED_WORKFLOWS/release-gate.workflow.md"
  [ -f "$wf" ]
  grep -qx 'name: release-gate' "$wf"
  grep -qx 'mode: dependency' "$wf"
  refute_cmd grep -E '^(engine|defaults):' "$wf"
  refute_cmd grep -E '^[[:space:]]+(runtime|model|role|agent):' "$wf"
  awk '
    /^  stages:/{s=1; next}
    s && /^    - id: /{print $3}
    s && /^todos:/{exit}
  ' "$wf" | tr '\n' ' ' | grep -Eq '^inspect-candidate plan-verification verify security release-decision release-gate-decision ?$'
  # security branches off inspect-candidate, not off verify.
  awk '/^    - id: security$/{p=1;next} p && /^    - id:/{exit} p && /^        - inspect-candidate$/{found=1} END{exit found?0:1}' "$wf"
  refute_cmd awk '/^    - id: security$/{p=1;next} p && /^    - id:/{exit} p && /^        - verify$/{found=1} END{exit found?0:1}' "$wf"
  # release-decision joins both lanes.
  awk '/^    - id: release-decision$/{p=1;next} p && /^    - id:/{exit} p && /^        - verify$/{found=1} END{exit found?0:1}' "$wf"
  awk '/^    - id: release-decision$/{p=1;next} p && /^    - id:/{exit} p && /^        - security$/{found=1} END{exit found?0:1}' "$wf"
}

@test "release-gate verification plan is generated and consumed read only" {
  local wf="$BUNDLED_WORKFLOWS/release-gate.workflow.md"
  local artifact
  for artifact in candidate.md release-verification-plan.json verification-handoff.md \
    security.md release-verdict.json; do
    grep -q ".ralph-workspace/artifacts/{{ARTIFACT_NS}}/$artifact" "$wf"
  done
  grep -q '^        outputMode: plan-file$' "$wf"
  grep -q '^        maxTodos: 100$' "$wf"
  grep -q '^      planFrom: plan-verification$' "$wf"
  # verify owns no authored TODO: its work comes from the generated plan.
  refute_cmd grep -E '^    stage: verify$' "$wf"
  # No stage may mutate, integrate, or publish.
  refute_cmd grep -q 'workspaceMode:' "$wf"
  refute_cmd grep -q 'writeScopes:' "$wf"
  refute_cmd grep -q 'agentGitAccess:' "$wf"
  refute_cmd grep -q 'type: integrate' "$wf"
  refute_cmd grep -q 'publishMode:' "$wf"
}

@test "release-gate keeps independent security evidence and release verdict semantics" {
  local wf="$BUNDLED_WORKFLOWS/release-gate.workflow.md"
  # Security assessment is independent of the verification conclusion.
  grep -Fq 'independently of any verification conclusion' "$wf"
  grep -Fq 'blocking or nonblocking disposition' "$wf"
  # Verdict is schema-bound with explicit approval semantics.
  awk '/^    - id: release-decision$/{p=1;next} p && /^    - id:/{exit} p && /schema: bundle\/.ralph\/schemas\/evaluator-verdict.schema.json/{found=1} END{exit found?0:1}' "$wf"
  grep -Fq 'approved only when every required check passes and no blocking security' "$wf"
  grep -Fq 'changes-required' "$wf"
  # Old role-named stages are gone.
  refute_cmd grep -q '^    - id: qa$' "$wf"
  refute_cmd grep -F 'artifacts/{{ARTIFACT_NS}}/qa-handoff.md' "$wf"
}

@test "release-gate SDLC is routing neutral and reusable task materializes" {
  local wf="$BUNDLED_WORKFLOWS/release-gate.workflow.md"
  local out="$TMPD/release-gate.plan.md"
  run plan_workflow_validate "$wf"
  [ "$status" -eq 0 ]
  run plan_workflow_instantiate "$wf" 'Ship {{literal}} & "$HOME" release' "$out" fallback_runtime=cursor
  [ "$status" -eq 0 ]
  assert_task_resolved_in_todos "$out"
  refute_cmd grep -E '^(kind|mode|engine|defaults):' "$out"
  grep -Fq 'Ship {{literal}} & "$HOME" release' "$out"
  assert_bundled_requires_have_one_producer "$wf"
  run plan_pipeline_graph_json "$out"
  [ "$status" -eq 0 ]
  printf '%s' "$output" | jq -e '
    ([.nodes[] | select(.type == "integrate")] | length) == 0
    and ([.nodes[] | select(.id == "verify") | .stage.planFrom] | .[0]) == "plan-verification"
    and ([.nodes[] | select(.id == "release-decision") | .stage.dependsOn] | .[0] | sort) == ["security", "verify"]
  ' >/dev/null
}

@test "investigation SDLC is read only with no execution or integration lane" {
  local wf="$BUNDLED_WORKFLOWS/investigation.workflow.md"
  [ -f "$wf" ]
  grep -qx 'name: investigation' "$wf"
  grep -qx 'mode: dependency' "$wf"
  refute_cmd grep -E '^(engine|defaults):' "$wf"
  refute_cmd grep -E '^[[:space:]]+(runtime|model|role|agent):' "$wf"
  awk '
    /^  stages:/{s=1; next}
    s && /^    - id: /{print $3}
    s && /^todos:/{exit}
  ' "$wf" | tr '\n' ' ' | grep -Eq '^investigate recommend-plan ?$'
  # No mutation, integration, or publication lane exists at all.
  refute_cmd grep -q 'workspaceMode:' "$wf"
  refute_cmd grep -q 'writeScopes:' "$wf"
  refute_cmd grep -q 'agentGitAccess:' "$wf"
  refute_cmd grep -q 'type: integrate' "$wf"
  refute_cmd grep -q 'publishMode:' "$wf"
  refute_cmd grep -q 'loopBackTo:' "$wf"
}

@test "investigation artifacts include synthesis and the recommended plan" {
  local wf="$BUNDLED_WORKFLOWS/investigation.workflow.md"
  local artifact
  for artifact in investigation.md investigation-synthesis.md recommended-plan.json; do
    grep -q ".ralph-workspace/artifacts/{{ARTIFACT_NS}}/$artifact" "$wf"
  done
  grep -q '^        outputMode: plan-file$' "$wf"
  grep -q '^        maxTodos: 100$' "$wf"
  # Exactly one planner JSON, and it is the unique planner artifact.
  [ "$(grep -c 'schema: bundle/.ralph/schemas/planner-output.schema.json' "$wf")" -eq 1 ]
  # Old role-named stage artifacts are gone.
  refute_cmd grep -F 'artifacts/{{ARTIFACT_NS}}/research.md' "$wf"
  refute_cmd grep -F 'artifacts/{{ARTIFACT_NS}}/architecture.md' "$wf"
  # Both stages are bounded and task-driven; no task-specific checklist in source.
  [ "$(grep -c '{{TASK}}' "$wf")" -ge 4 ]
}

@test "investigation declares no plan consumer and keeps the source plan immutable" {
  local wf="$BUNDLED_WORKFLOWS/investigation.workflow.md"
  local out="$TMPD/investigation.plan.md"
  # The recommended plan is never executed by this workflow.
  refute_cmd grep -q 'planFrom:' "$wf"
  refute_cmd grep -q 'planFile:' "$wf"
  run plan_workflow_instantiate "$wf" 'Explain {{literal}} & "$HOME" behavior' "$out" fallback_runtime=cursor
  [ "$status" -eq 0 ]
  run plan_pipeline_graph_json "$out"
  [ "$status" -eq 0 ]
  printf '%s' "$output" | jq -e '
    ([.nodes[] | select(.stage.planFrom != null)] | length) == 0
    and ([.nodes[] | select(.type == "integrate")] | length) == 0
    and ([.nodes[] | select(.id == "recommend-plan") | .stage.planner.outputMode] | .[0]) == "plan-file"
    and ([.nodes[] | .id] | index("recommend-plan")) != null
  ' >/dev/null
}

@test "investigation SDLC is routing neutral and reusable task materializes" {
  local wf="$BUNDLED_WORKFLOWS/investigation.workflow.md"
  local out="$TMPD/investigation-routing.plan.md"
  run plan_workflow_validate "$wf"
  [ "$status" -eq 0 ]
  run plan_workflow_instantiate "$wf" 'Explain {{literal}} & "$HOME" behavior' "$out" fallback_runtime=cursor
  [ "$status" -eq 0 ]
  assert_task_resolved_in_todos "$out"
  refute_cmd grep -E '^(kind|mode|engine|defaults):' "$out"
  grep -Fq 'Explain {{literal}} & "$HOME" behavior' "$out"
  assert_bundled_requires_have_one_producer "$wf"
}

@test "refactor SDLC has the exact reusable topology" {
  local wf="$BUNDLED_WORKFLOWS/refactor.workflow.md"
  [ -f "$wf" ]
  grep -qx 'name: refactor' "$wf"
  grep -qx 'mode: dependency' "$wf"
  grep -qx '  maxReworkIterations: 2' "$wf"
  grep -qx '  publishMode: on-verified' "$wf"
  refute_cmd grep -E '^(engine|defaults):' "$wf"
  refute_cmd grep -E '^[[:space:]]+(runtime|model|role|agent):' "$wf"
  awk '
    /^  stages:/{s=1; next}
    s && /^    - id: /{print $3}
    s && /^todos:/{exit}
  ' "$wf" | tr '\n' ' ' | grep -Eq '^characterize plan-implementation implement review integrate plan-qa qa qa-gate ?$'
  # review-approved is compiler-derived, never authored.
  refute_cmd grep -q '^    - id: review-approved$' "$wf"
  # characterize is read-only: no mutation scope or Git access anywhere but implement.
  refute_cmd awk '/^    - id: characterize$/{p=1;next} p && /^    - id:/{exit} p && /^      (writeScopes|planFrom|planner):/{found=1} END{exit found?0:1}' "$wf"
}

@test "refactor artifacts and plan-backed rework stay planFrom driven" {
  local wf="$BUNDLED_WORKFLOWS/refactor.workflow.md"
  local artifact
  for artifact in characterization.md refactor-plan.json implementation-handoff.md \
    "{{STAGE_ID}}-verdict.json" refactor-qa-plan.json qa-handoff.md; do
    grep -q ".ralph-workspace/artifacts/{{ARTIFACT_NS}}/$artifact" "$wf"
  done
  grep -q '^      loopBackTo: implement$' "$wf"
  grep -q '^      onExhausted: fail$' "$wf"
  [ "$(grep -c '^        outputMode: plan-file$' "$wf")" -eq 2 ]
  [ "$(grep -c '^        maxTodos: 200$' "$wf")" -eq 2 ]
  grep -q '^      planFrom: plan-implementation$' "$wf"
  grep -q '^      planFrom: plan-qa$' "$wf"
  # Plan-backed consumers own no authored TODO.
  refute_cmd grep -E '^    stage: (implement|qa)$' "$wf"
  # Old role-named stages and their artifacts are gone.
  refute_cmd grep -q '^    - id: code-review$' "$wf"
  refute_cmd grep -F 'artifacts/{{ARTIFACT_NS}}/architecture.md' "$wf"
  refute_cmd grep -F 'artifacts/{{ARTIFACT_NS}}/research.md' "$wf"
}

@test "refactor snapshot integration keeps mutation on the supervisor" {
  local wf="$BUNDLED_WORKFLOWS/refactor.workflow.md"
  # Only implement declares a write scope.
  [ "$(grep -c '^      writeScopes: \["\*\*"\]$' "$wf")" -eq 1 ]
  # Implementation and review are snapshot isolated with Git access off.
  [ "$(grep -c '^      agentGitAccess: off$' "$wf")" -eq 2 ]
  awk '/^    - id: implement$/{p=1;next} p && /^    - id:/{exit} p && /^      workspaceMode: snapshot$/{found=1} END{exit found?0:1}' "$wf"
  awk '/^    - id: review$/{p=1;next} p && /^    - id:/{exit} p && /^      workspaceMode: snapshot$/{found=1} END{exit found?0:1}' "$wf"
  # Supervisor integrate depends on review-approved and carries no agent fields.
  awk '/^    - id: integrate$/{p=1;next} p && /^    - id:/{exit} p && /^      type: integrate$/{found=1} END{exit found?0:1}' "$wf"
  awk '/^    - id: integrate$/{p=1;next} p && /^    - id:/{exit} p && /^        - review-approved$/{found=1} END{exit found?0:1}' "$wf"
  refute_cmd awk '/^    - id: integrate$/{p=1;next} p && /^    - id:/{exit} p && /^      (instructions|runtime|model|role|agent|writeScopes):/{found=1} END{exit found?0:1}' "$wf"
}

@test "refactor SDLC is routing neutral and reusable task materializes" {
  local wf="$BUNDLED_WORKFLOWS/refactor.workflow.md"
  local out="$TMPD/refactor.plan.md"
  run plan_workflow_validate "$wf"
  [ "$status" -eq 0 ]
  run plan_workflow_instantiate "$wf" 'Split {{literal}} & "$HOME" module' "$out" fallback_runtime=cursor
  [ "$status" -eq 0 ]
  assert_task_resolved_in_todos "$out"
  refute_cmd grep -E '^(kind|mode|engine|defaults):' "$out"
  grep -Fq 'Split {{literal}} & "$HOME" module' "$out"
  run plan_pipeline_graph_json "$out"
  [ "$status" -eq 0 ]
  printf '%s' "$output" | jq -e '
    ([.nodes[] | select(.id == "review-approved" and .type == "join")] | length) == 1
    and ([.nodes[] | select(.id == "integrate" and .type == "integrate")] | length) == 1
    and ([.nodes[] | select(.id == "implement") | .stage.planFrom] | .[0]) == "plan-implementation"
    and ([.nodes[] | select(.id == "qa") | .stage.planFrom] | .[0]) == "plan-qa"
  ' >/dev/null
}

@test "refactor planner and consumer routing stay direct" {
  local wf="$BUNDLED_WORKFLOWS/refactor.workflow.md"
  assert_bundled_requires_have_one_producer "$wf"
}

@test "feature-delivery SDLC has the exact reusable topology" {
  local wf="$BUNDLED_WORKFLOWS/feature-delivery.workflow.md"
  [ -f "$wf" ]
  grep -qx 'name: feature-delivery' "$wf"
  grep -qx 'mode: dependency' "$wf"
  grep -qx '  maxParallel: 1' "$wf"
  grep -qx '  maxReworkIterations: 2' "$wf"
  grep -qx '  publishMode: on-verified' "$wf"
  refute_cmd grep -E '^(engine|defaults):' "$wf"
  refute_cmd grep -E '^[[:space:]]+(runtime|model|role|agent):' "$wf"
  awk '
    /^  stages:/{s=1; next}
    s && /^    - id: /{print $3}
    s && /^todos:/{exit}
  ' "$wf" | tr '\n' ' ' | grep -Eq '^investigate plan-implementation implement review integrate plan-qa qa qa-gate ?$'
  refute_cmd grep -q '^    - id: review-approved$' "$wf"
  grep -q '^      type: integrate$' "$wf"
  refute_cmd awk '/^    - id: integrate$/{p=1;next} p && /^    - id:/{exit} p && /^      (instructions|runtime|model|role|agent):/{found=1} END{exit found?0:1}' "$wf"
}

@test "feature-delivery SDLC declares feature artifacts and plan-backed rework" {
  local wf="$BUNDLED_WORKFLOWS/feature-delivery.workflow.md"
  local artifact
  for artifact in feature-investigation.md feature-delivery-plan.json \
    implementation-handoff.md "{{STAGE_ID}}-verdict.json" feature-qa-plan.json \
    qa-handoff.md; do
    grep -q ".ralph-workspace/artifacts/{{ARTIFACT_NS}}/$artifact" "$wf"
  done
  grep -q '^      loopBackTo: implement$' "$wf"
  grep -q '^      onExhausted: fail$' "$wf"
  [ "$(grep -c '^        outputMode: plan-file$' "$wf")" -eq 2 ]
  [ "$(grep -c '^        maxTodos: 200$' "$wf")" -eq 2 ]
  grep -q '^      planFrom: plan-implementation$' "$wf"
  grep -q '^      planFrom: plan-qa$' "$wf"
  refute_cmd awk '/^    - id: implement$/{p=1;next} p && /^    - id:/{exit} p && /^      - id:/{found=1} END{exit found?0:1}' "$wf"
  refute_cmd awk '/^    - id: qa$/{p=1;next} p && /^    - id:/{exit} p && /^      - id:/{found=1} END{exit found?0:1}' "$wf"
}

@test "feature-delivery SDLC is routing neutral and reusable task materializes" {
  local wf="$BUNDLED_WORKFLOWS/feature-delivery.workflow.md"
  local out="$TMPD/feature-delivery.plan.md"
  run plan_workflow_validate "$wf"
  [ "$status" -eq 0 ]
  run plan_workflow_instantiate "$wf" 'Ship {{literal}} & "$HOME" behavior' "$out" fallback_runtime=cursor
  [ "$status" -eq 0 ]
  assert_task_resolved_in_todos "$out"
  refute_cmd grep -E '^(kind|mode|engine|defaults):' "$out"
  grep -Fq 'Ship {{literal}} & "$HOME" behavior' "$out"
  run plan_pipeline_graph_json "$out"
  [ "$status" -eq 0 ]
  printf '%s' "$output" | jq -e '
    ([.nodes[] | select(.id == "review-approved" and .type == "join")] | length) == 1
    and ([.nodes[] | select(.id == "integrate" and .type == "integrate")] | length) == 1
    and ([.nodes[] | select(.id == "implement") | .stage.planFrom] | .[0]) == "plan-implementation"
    and ([.nodes[] | select(.id == "qa") | .stage.planFrom] | .[0]) == "plan-qa"
  ' >/dev/null
}

@test "feature-delivery implement and qa consume generated plans of 76 TODOs" {
  local wf="$BUNDLED_WORKFLOWS/feature-delivery.workflow.md"
  # implement and qa own no authored TODOs: their work arrives from the planner.
  refute_cmd grep -E '^    stage: (implement|qa)$' "$wf"
  grep -q '^      planFrom: plan-implementation$' "$wf"
  grep -q '^      planFrom: plan-qa$' "$wf"
  python3 - "$REPO_ROOT" <<'PY'
import re, sys
from pathlib import Path

repo = Path(sys.argv[1])
sys.path.insert(0, str(repo / "bundle/.ralph/python"))
import planner_contract as pc


def output(name, todos):
    return {
        "schemaVersion": 2,
        "name": name,
        "overview": "Generated %s plan" % name,
        "rationale": "Fewest independently verifiable TODOs.",
        "todos": todos,
    }


implementation = output(
    "feature-delivery-implementation",
    [
        {
            "id": "implementation-slice-%02d" % i,
            "content": "Implement independently verifiable slice %d." % i,
            "verification": "test -f slice-%02d.ok" % i,
            "status": "pending",
        }
        for i in range(1, 77)
    ],
)
text = pc.render_plan_markdown(implementation, default_runtime="cursor", default_model="auto")
ids = re.findall(r"(?m)^  - id: ([a-z0-9-]+)$", text)
assert len(ids) == 76, len(ids)
assert ids == [todo["id"] for todo in implementation["todos"]]
assert "padding" not in text.lower()
assert "truncated" not in text.lower()
assert "slice-76.ok" in text

qa = output(
    "feature-delivery-qa",
    [
        {
            "id": "acceptance-check",
            "content": "Run the independent acceptance check using the implementation handoff.",
            "verification": "test -s .ralph-workspace/artifacts/ns/implementation-handoff.md",
            "status": "pending",
        }
    ],
)
qa_text = pc.render_plan_markdown(qa, default_runtime="cursor", default_model="auto")
assert len(re.findall(r"(?m)^  - id: ", qa_text)) == 1
assert "implementation-handoff.md" in qa_text
PY
}

@test "feature-delivery planner and consumer routing stay direct" {
  local wf="$BUNDLED_WORKFLOWS/feature-delivery.workflow.md"
  grep -q '^      dependsOn:$' "$wf"
  grep -A2 -q '^    - id: plan-implementation$' "$wf"
  grep -A3 -q '^    - id: implement$' "$wf"
  grep -A3 -q '^    - id: plan-qa$' "$wf"
  grep -A3 -q '^    - id: qa$' "$wf"
  assert_bundled_requires_have_one_producer "$wf"
}

# --- per-stage invocation routing overrides ---------------------------------
#
# `ralph workflow start` lets an operator pick a runtime and model per stage
# without editing the workflow source. Those picks arrive as
# stage_runtime.<id>= / stage_model.<id>= instantiate options.

write_two_stage_neutral_wf() {
  local path="$1"
  printf '%s\n' \
    '---' \
    'name: demo-workflow' \
    'kind: workflow' \
    'mode: dependency' \
    'pipeline:' \
    '  stages:' \
    '    - id: first' \
    '    - id: second' \
    '      dependsOn:' \
    '        - first' \
    'todos:' \
    '  - id: first-work' \
    '    stage: first' \
    '    content: Investigate {{TASK}}' \
    '    status: pending' \
    '  - id: second-work' \
    '    stage: second' \
    '    content: Implement {{TASK}}' \
    '    status: pending' \
    '---' >"$path"
}

@test "per-stage overrides route each stage independently" {
  write_two_stage_neutral_wf "$TMPD/wf.md"

  run plan_workflow_instantiate "$TMPD/wf.md" "$TASK" "$TMPD/out.plan.md" \
    "stage_runtime.first=claude" "stage_model.first=haiku" \
    "stage_runtime.second=codex" "stage_model.second=gpt-5"
  [ "$status" -eq 0 ]
  grep -qx '      runtime: claude' "$TMPD/out.plan.md"
  grep -qx '      model: haiku' "$TMPD/out.plan.md"
  grep -qx '      runtime: codex' "$TMPD/out.plan.md"
  grep -qx '      model: gpt-5' "$TMPD/out.plan.md"
  # A fully routed plan compiles for the dependency engine.
  run plan_pipeline_graph_json "$TMPD/out.plan.md"
  [ "$status" -eq 0 ]
}

@test "an authored stage runtime beats a per-stage override" {
  write_two_stage_neutral_wf "$TMPD/wf.md"
  # Pin the first stage in the source.
  perl -0pi -e 's/^    - id: first\n/    - id: first\n      runtime: cursor\n      model: auto\n/m' \
    "$TMPD/wf.md"

  run plan_workflow_instantiate "$TMPD/wf.md" "$TASK" "$TMPD/out.plan.md" \
    "stage_runtime.first=claude" "stage_model.first=haiku" \
    "stage_runtime.second=claude" "stage_model.second=opus"
  [ "$status" -eq 0 ]
  grep -qx '      runtime: cursor' "$TMPD/out.plan.md"
  grep -qx '      model: auto' "$TMPD/out.plan.md"
  refute_cmd grep -qx '      model: haiku' "$TMPD/out.plan.md"
}

@test "per-stage overrides fill only the stages they name" {
  write_two_stage_neutral_wf "$TMPD/wf.md"

  # The unnamed stage stays unresolved, so the concrete re-validation is skipped
  # and the caller is responsible for resolving it.
  run plan_workflow_instantiate "$TMPD/wf.md" "$TASK" "$TMPD/out.plan.md" \
    "stage_runtime.first=claude" "stage_model.first=haiku"
  [ "$status" -eq 0 ]
  [ "$(grep -c '^      runtime: ' "$TMPD/out.plan.md")" -eq 1 ]
}

@test "a per-stage model without its runtime is rejected" {
  write_two_stage_neutral_wf "$TMPD/wf.md"

  run plan_workflow_instantiate "$TMPD/wf.md" "$TASK" "$TMPD/out.plan.md" \
    "stage_model.first=haiku"
  [ "$status" -ne 0 ]
  [[ "$output" == *"requires paired stage_runtime.first"* ]]
}

@test "a per-stage override with an unknown runtime is rejected" {
  write_two_stage_neutral_wf "$TMPD/wf.md"

  run plan_workflow_instantiate "$TMPD/wf.md" "$TASK" "$TMPD/out.plan.md" \
    "stage_runtime.first=nope"
  [ "$status" -ne 0 ]
  [[ "$output" == *"unsupported runtime"* ]]
}

@test "an override key without a stage id is rejected" {
  write_two_stage_neutral_wf "$TMPD/wf.md"

  run plan_workflow_instantiate "$TMPD/wf.md" "$TASK" "$TMPD/out.plan.md" \
    "stage_runtime.=claude"
  [ "$status" -ne 0 ]
  [[ "$output" == *"requires a stage id"* ]]
}

# --- Shared instruction fragments ({{INCLUDE:<name>}}) ---------------------
#
# Stage guidance that applies across workflows (scope discipline, the evaluator
# contract, planning budgets) lives in one fragment instead of being restated
# per workflow, which is how the copies previously drifted.

write_fragment_workflow() {
  local out="$1" fragment="$2"
  cat >"$out" <<EOF
---
name: frag-case
kind: workflow
mode: dependency
pipeline:
  stages:
    - id: implement
      instructions: |
        Do the work for {{TASK}}.
        {{INCLUDE:${fragment}}}
      produces:
        - path: .ralph-workspace/artifacts/{{ARTIFACT_NS}}/out.md
          required: true
todos:
  - id: t1
    stage: implement
    content: Work on {{TASK}}.
    verification: test -f .ralph-workspace/artifacts/{{ARTIFACT_NS}}/out.md
    status: pending
---
EOF
}

@test "workflow instantiate expands an instruction fragment at the block indent" {
  command -v python3 >/dev/null || skip "python3 required"
  local tmp; tmp="$(mktemp -d)"
  write_fragment_workflow "$tmp/f.workflow.md" "scope-discipline"

  run plan_workflow_instantiate "$tmp/f.workflow.md" "fix the widget" "$tmp/out.plan.md"
  [ "$status" -eq 0 ]
  grep -Fq "smallest defensible change" "$tmp/out.plan.md"
  # No token survives materialization.
  run grep -Fq "{{INCLUDE:" "$tmp/out.plan.md"
  [ "$status" -ne 0 ]
  # Fragment lines keep the block scalar's indent, so the YAML shape is intact.
  grep -Eq '^        Make the smallest defensible change' "$tmp/out.plan.md"
  rm -rf "$tmp"
}

@test "workflow instantiate rejects an unknown instruction fragment" {
  command -v python3 >/dev/null || skip "python3 required"
  local tmp; tmp="$(mktemp -d)"
  write_fragment_workflow "$tmp/f.workflow.md" "no-such-fragment"

  run plan_workflow_instantiate "$tmp/f.workflow.md" "task" "$tmp/out.plan.md"
  [ "$status" -ne 0 ]
  [[ "$output" == *"unknown instruction fragment"* ]]
  [ ! -f "$tmp/out.plan.md" ]
  rm -rf "$tmp"
}

@test "workflow instantiate refuses a fragment name that escapes the fragments directory" {
  command -v python3 >/dev/null || skip "python3 required"
  local tmp; tmp="$(mktemp -d)"
  # The token grammar only admits a bare slug, so a traversal attempt is not a
  # fragment reference at all and must survive as an unresolved token.
  write_fragment_workflow "$tmp/f.workflow.md" "x"
  sed -i.bak 's|{{INCLUDE:x}}|{{INCLUDE:../../../etc/passwd}}|' "$tmp/f.workflow.md"

  run plan_workflow_instantiate "$tmp/f.workflow.md" "task" "$tmp/out.plan.md"
  [ "$status" -ne 0 ]
  [ ! -f "$tmp/out.plan.md" ]
  rm -rf "$tmp"
}

@test "every bundled workflow instantiates with all fragments resolved" {
  command -v python3 >/dev/null || skip "python3 required"
  local tmp; tmp="$(mktemp -d)"
  local wf name out
  for wf in "$BUNDLED_WORKFLOWS"/*.workflow.md; do
    name="$(basename "$wf" .workflow.md)"
    out="$tmp/$name.plan.md"
    if grep -q '^planInput:' "$wf"; then
      printf -- '- [ ] supplied\n' >"$tmp/$name.src.plan.md"
      run plan_workflow_instantiate_provided "$wf" "task text" "$out" \
        "provided_plan_path=$tmp/$name.src.plan.md"
    else
      run plan_workflow_instantiate "$wf" "task text" "$out"
    fi
    [ "$status" -eq 0 ] || { echo "instantiate failed for $name: $output"; false; }
    run grep -Fq "{{INCLUDE:" "$out"
    [ "$status" -ne 0 ] || { echo "unresolved fragment token in $name"; false; }
  done
  rm -rf "$tmp"
}

@test "the evaluator-contract fragment states the ledger disposition rule" {
  # The rework loop depends on reviewers dispositioning prior findings; if this
  # guidance is dropped the accumulating ledger blocks approval forever.
  local frag="$REPO_ROOT/bundle/.ralph/workflows/_fragments/evaluator-contract.md"
  [ -f "$frag" ]
  grep -Fq "disposition" "$frag"
  grep -Fq "stays open" "$frag"
  grep -Fq "verification" "$frag"
}

# --- QA / decision verdict gates -------------------------------------------
#
# Before these gates, `integrate` published on review approval and the QA stage
# ran afterwards producing only prose that nothing consumed: a QA run reporting
# FAIL on every check still exited 0. The gate makes the verdict decide the run.

@test "every delivery workflow gates on a machine-readable verdict" {
  command -v python3 >/dev/null || skip "python3 required"
  command -v jq >/dev/null || skip "jq required"
  local tmp; tmp="$(mktemp -d)"
  local wf name out graph gates
  for name in bug-fix feature-delivery refactor human-verified-delivery plan-delivery; do
    wf="$BUNDLED_WORKFLOWS/$name.workflow.md"
    out="$tmp/$name.plan.md"
    if grep -q '^planInput:' "$wf"; then
      printf -- '- [ ] supplied\n' >"$tmp/$name.src.plan.md"
      run plan_workflow_instantiate_provided "$wf" "task" "$out" \
        "provided_plan_path=$tmp/$name.src.plan.md" fallback_runtime=cursor fallback_model=auto
    else
      run plan_workflow_instantiate "$wf" "task" "$out" fallback_runtime=cursor fallback_model=auto
    fi
    [ "$status" -eq 0 ] || { echo "instantiate failed for $name: $output"; false; }

    graph="$tmp/$name.graph.json"
    run bash -c "source '$REPO_ROOT/bundle/.ralph/bash-lib/plan-todo.sh'; plan_pipeline_graph_json '$out'"
    [ "$status" -eq 0 ] || { echo "compile failed for $name: $output"; false; }
    printf '%s' "$output" >"$graph"

    gates="$(jq -r '[.nodes[] | select(.type == "gate") | .id] | join(",")' "$graph")"
    [ "$gates" = "qa-gate" ] || { echo "$name gates: $gates"; false; }
    [ "$(jq -r '.nodes[] | select(.id == "qa-gate") | .stage.profile' "$graph")" = "qa-verdict" ]
    jq -e '.verificationProfiles[] | select(.name == "qa-verdict")' "$graph" >/dev/null
  done
  rm -rf "$tmp"
}

@test "release-gate makes its release decision determine the run outcome" {
  command -v python3 >/dev/null || skip "python3 required"
  command -v jq >/dev/null || skip "jq required"
  local tmp; tmp="$(mktemp -d)"
  run plan_workflow_instantiate "$BUNDLED_WORKFLOWS/release-gate.workflow.md" \
    "cut a release" "$tmp/o.plan.md" fallback_runtime=cursor fallback_model=auto
  [ "$status" -eq 0 ]
  run bash -c "source '$REPO_ROOT/bundle/.ralph/bash-lib/plan-todo.sh'; plan_pipeline_graph_json '$tmp/o.plan.md'"
  [ "$status" -eq 0 ]
  printf '%s' "$output" >"$tmp/g.json"
  [ "$(jq -r '[.nodes[] | select(.type == "gate") | .id] | join(",")' "$tmp/g.json")" = "release-gate-decision" ]
  rm -rf "$tmp"
}

@test "read-only workflows declare no verdict gate" {
  command -v python3 >/dev/null || skip "python3 required"
  command -v jq >/dev/null || skip "jq required"
  local tmp; tmp="$(mktemp -d)"
  run plan_workflow_instantiate "$BUNDLED_WORKFLOWS/investigation.workflow.md" \
    "look into it" "$tmp/o.plan.md" fallback_runtime=cursor fallback_model=auto
  [ "$status" -eq 0 ]
  run bash -c "source '$REPO_ROOT/bundle/.ralph/bash-lib/plan-todo.sh'; plan_pipeline_graph_json '$tmp/o.plan.md'"
  [ "$status" -eq 0 ]
  printf '%s' "$output" >"$tmp/g.json"
  [ "$(jq -r '[.nodes[] | select(.type == "gate")] | length' "$tmp/g.json")" -eq 0 ]
  rm -rf "$tmp"
}

@test "a materialized verificationProfile round-trips back through the parser" {
  # The serializer emits profile keys in dict order, so "steps" can precede
  # "name". Requiring name-first made any workflow declaring a profile fail to
  # compile after instantiation.
  command -v python3 >/dev/null || skip "python3 required"
  local tmp; tmp="$(mktemp -d)"
  cat >"$tmp/rt.plan.md" <<'EOF'
---
execution: graph
pipeline:
  verificationProfiles:
    - steps:
        - name: check
          command: true
          timeout: 30
      name: late-name
  stages:
    - id: work
      runtime: cursor
      produces:
        - path: shared/out.md
          required: true
    - id: g
      type: gate
      profile: late-name
      dependsOn:
        - work
todos:
  - id: work-1
    stage: work
    content: do it
    verification: test -f shared/out.md
    status: pending
  - id: g-1
    stage: g
    content: run the gate
    verification: Confirm the gate outcome records passed or changes-required.
    status: pending
---
EOF
  run bash -c "source '$REPO_ROOT/bundle/.ralph/bash-lib/plan-todo.sh'; plan_pipeline_graph_json '$tmp/rt.plan.md'"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *"late-name"* ]]
  rm -rf "$tmp"
}
