#!/usr/bin/env bats
# Outer workflow-run registry run.json schema version 1.
# Validates fixtures with the shared artifact_json_schema validator only.

source "$BATS_TEST_DIRNAME/../helper/load-lib.bash"

SCHEMA="$REPO_ROOT/bundle/.ralph/schemas/workflow-run.schema.json"
ARTIFACT_SCHEMA_PY="$REPO_ROOT/bundle/.ralph/python/artifact_json_schema.py"

setup_file() {
  command -v python3 >/dev/null || skip "python3 required"
  [ -f "$SCHEMA" ]
  [ -f "$ARTIFACT_SCHEMA_PY" ]
}

setup() {
  TMPD="$(mktemp -d)"
}

teardown() {
  rm -rf "$TMPD"
}

validate_run_json() {
  local path="$1"
  python3 "$ARTIFACT_SCHEMA_PY" validate-final-output \
    --schema "$SCHEMA" \
    --artifact "$path"
}

write_json() {
  local path="$1"
  cat >"$path"
}

# Minimal Sequential task-entry run (inputPlan must be null).
sequential_task_json() {
  cat <<'EOF'
{
  "runId": "run-20260101T000000Z-0-aaaaaa",
  "workflowId": "bug-fix",
  "sourcePath": "/tmp/project/.ralph-workspace/workflows/bug-fix.workflow.md",
  "sourceKind": "project",
  "mode": "sequential",
  "entryKind": "task",
  "task": "Fix the flaky timeout",
  "taskProvenance": "explicit",
  "inputPath": "/tmp/project/.ralph-workspace/workflow-runs/run-20260101T000000Z-0-aaaaaa/input.orch.json",
  "inputPlan": null,
  "state": "queued",
  "createdAt": "2026-01-01T00:00:00Z",
  "updatedAt": "2026-01-01T00:00:00Z",
  "owner": null,
  "engine": {
    "kind": "orchestration",
    "statePath": "/tmp/project/.ralph-workspace/workflow-runs/run-20260101T000000Z-0-aaaaaa/engine",
    "namespace": null
  }
}
EOF
}

# Minimal Dependency task-entry run (inputPlan must be null).
dependency_task_json() {
  cat <<'EOF'
{
  "runId": "run-20260101T000001Z-0-bbbbbb",
  "workflowId": "feature-delivery",
  "sourcePath": "/tmp/project/.ralph-workspace/workflows/feature-delivery.workflow.md",
  "sourceKind": "project",
  "mode": "dependency",
  "entryKind": "task",
  "task": "Ship the new dashboard filter",
  "taskProvenance": "explicit",
  "inputPath": "/tmp/project/.ralph-workspace/workflow-runs/run-20260101T000001Z-0-bbbbbb/input.plan.md",
  "inputPlan": null,
  "state": "running",
  "createdAt": "2026-01-01T00:00:01Z",
  "updatedAt": "2026-01-01T00:00:02Z",
  "owner": {
    "pid": 4242,
    "hostname": "dev.host",
    "processStartId": "4242:1704067201",
    "heartbeatAt": "2026-01-01T00:00:02Z"
  },
  "engine": {
    "kind": "graph",
    "statePath": "/tmp/project/.ralph-workspace/graph-runs/feature-delivery/run-20260101T000001Z-0-bbbbbb",
    "namespace": "feature-delivery"
  }
}
EOF
}

# Complete provided-plan inputPlan object (plan entry only).
provided_input_plan_json() {
  cat <<'EOF'
{
  "originalPath": "/tmp/project/plans/feature.plan.md",
  "sourcePath": "/tmp/project/.ralph-workspace/workflow-runs/run-20260101T000002Z-0-cccccc/plans/input/source.plan.md",
  "manifestPath": "/tmp/project/.ralph-workspace/workflow-runs/run-20260101T000002Z-0-cccccc/plans/input/manifest.json",
  "sha256": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
  "format": "yaml",
  "totalTodos": 3,
  "completedTodos": 1,
  "openTodos": 2
}
EOF
}

# Minimal Sequential plan-entry run with complete inputPlan.
sequential_plan_json() {
  local input_plan
  input_plan="$(provided_input_plan_json)"
  cat <<EOF
{
  "runId": "run-20260101T000002Z-0-cccccc",
  "workflowId": "plan-delivery",
  "sourcePath": "/tmp/project/.ralph-workspace/workflows/plan-delivery.workflow.md",
  "sourceKind": "project",
  "mode": "sequential",
  "entryKind": "plan",
  "task": "Execute the supplied feature plan",
  "taskProvenance": "plan-overview",
  "inputPath": "/tmp/project/.ralph-workspace/workflow-runs/run-20260101T000002Z-0-cccccc/input.orch.json",
  "inputPlan": ${input_plan},
  "state": "queued",
  "createdAt": "2026-01-01T00:00:03Z",
  "updatedAt": "2026-01-01T00:00:03Z",
  "owner": null,
  "engine": {
    "kind": "orchestration",
    "statePath": "/tmp/project/.ralph-workspace/workflow-runs/run-20260101T000002Z-0-cccccc/engine",
    "namespace": null
  }
}
EOF
}

# Minimal Dependency plan-entry run with complete inputPlan.
dependency_plan_json() {
  local input_plan
  input_plan="$(provided_input_plan_json)"
  cat <<EOF
{
  "runId": "run-20260101T000003Z-0-dddddd",
  "workflowId": "plan-delivery",
  "sourcePath": "/home/user/.ralph/workflows/plan-delivery.workflow.md",
  "sourceKind": "global",
  "mode": "dependency",
  "entryKind": "plan",
  "task": "leaf-plan.md",
  "taskProvenance": "plan-filename",
  "inputPath": "/tmp/project/.ralph-workspace/workflow-runs/run-20260101T000003Z-0-dddddd/input.plan.md",
  "inputPlan": ${input_plan},
  "state": "waiting",
  "createdAt": "2026-01-01T00:00:04Z",
  "updatedAt": "2026-01-01T00:00:04Z",
  "owner": {
    "pid": null,
    "hostname": null,
    "processStartId": null,
    "heartbeatAt": null
  },
  "engine": {
    "kind": "graph",
    "statePath": "/tmp/project/.ralph-workspace/graph-runs/plan-delivery/run-20260101T000003Z-0-dddddd",
    "namespace": "plan-delivery"
  }
}
EOF
}

mutate_with_jq() {
  local src="$1" dest="$2"
  shift 2
  jq "$@" "$src" >"$dest"
}

@test "Sequential task entry with null inputPlan validates" {
  write_json "$TMPD/seq-task.json" < <(sequential_task_json)
  run validate_run_json "$TMPD/seq-task.json"
  [ "$status" -eq 0 ]
}

@test "Dependency task entry with null inputPlan validates" {
  write_json "$TMPD/dep-task.json" < <(dependency_task_json)
  run validate_run_json "$TMPD/dep-task.json"
  [ "$status" -eq 0 ]
}

@test "Sequential plan entry with complete inputPlan validates" {
  write_json "$TMPD/seq-plan.json" < <(sequential_plan_json)
  run validate_run_json "$TMPD/seq-plan.json"
  [ "$status" -eq 0 ]
}

@test "Dependency plan entry with complete inputPlan validates" {
  write_json "$TMPD/dep-plan.json" < <(dependency_plan_json)
  run validate_run_json "$TMPD/dep-plan.json"
  [ "$status" -eq 0 ]
}

@test "task provenance enums validate on task entry and plan entry" {
  write_json "$TMPD/base-task.json" < <(sequential_task_json)
  write_json "$TMPD/base-plan.json" < <(sequential_plan_json)

  local dest provenance
  for provenance in explicit workflow; do
    dest="$TMPD/task-prov-${provenance}.json"
    mutate_with_jq "$TMPD/base-task.json" "$dest" \
      --arg p "$provenance" '.taskProvenance = $p'
    run validate_run_json "$dest"
    [ "$status" -eq 0 ]
  done

  for provenance in explicit plan-overview plan-filename; do
    dest="$TMPD/plan-prov-${provenance}.json"
    mutate_with_jq "$TMPD/base-plan.json" "$dest" \
      --arg p "$provenance" '.taskProvenance = $p'
    run validate_run_json "$dest"
    [ "$status" -eq 0 ]
  done
}

@test "inputPlan null on task entry and complete object on plan entry validate" {
  write_json "$TMPD/task.json" < <(sequential_task_json)
  write_json "$TMPD/plan.json" < <(sequential_plan_json)

  run validate_run_json "$TMPD/task.json"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.inputPlan' "$TMPD/task.json")" = "null" ]

  run validate_run_json "$TMPD/plan.json"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.inputPlan|type' "$TMPD/plan.json")" = "object" ]
}

@test "invalid contracts are table-driven: missing type enum path conditional inputPlan" {
  write_json "$TMPD/base-task.json" < <(sequential_task_json)
  write_json "$TMPD/base-plan.json" < <(sequential_plan_json)

  # case_id | kind | jq filter | notes
  # missing: drop a required top-level field
  # type: wrong JSON type
  # enum: illegal enum member
  # path: relative path where absolute is required
  # conditional: plan entry with incomplete inputPlan object
  local -a cases=(
    "missing|task|del(.runId)"
    "type|task|.state = 1"
    "enum|task|.sourceKind = \"workspace\""
    "path|task|.sourcePath = \"relative/workflow.md\""
    "conditional|plan|.inputPlan = {\"format\":\"yaml\",\"totalTodos\":1,\"completedTodos\":0,\"openTodos\":1}"
  )

  local spec case_id kind filter src dest
  for spec in "${cases[@]}"; do
    IFS='|' read -r case_id kind filter <<<"$spec"
    if [ "$kind" = "task" ]; then
      src="$TMPD/base-task.json"
    else
      src="$TMPD/base-plan.json"
    fi
    dest="$TMPD/invalid-${case_id}.json"
    mutate_with_jq "$src" "$dest" "$filter"
    run validate_run_json "$dest"
    [ "$status" -ne 0 ]
  done
}
