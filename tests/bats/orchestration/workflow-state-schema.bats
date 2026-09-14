#!/usr/bin/env bats
# Sequential engine run/stage/event durable JSON schemas (version 1).
# Validates fixtures with artifact_json_schema.py only — no orchestrator.
# Cross-field and completedTodos<=totalTodos rules that the Ralph schema
# subset cannot express (no if/then) are checked by the same validate
# helpers immediately after the schema gate.
# Contracts: agents/rules/test-design.md, agents/rules/testing-workflow.md,
# and .ralph-workspace/artifacts/ralph-first-class-workflows/contracts.md
# (Sequential engine/run.json, stages/<id>.json, events.jsonl).

source "$BATS_TEST_DIRNAME/../helper/load-lib.bash"

RUN_SCHEMA="$REPO_ROOT/bundle/.ralph/schemas/workflow-sequential-run.schema.json"
STAGE_SCHEMA="$REPO_ROOT/bundle/.ralph/schemas/workflow-sequential-stage.schema.json"
EVENT_SCHEMA="$REPO_ROOT/bundle/.ralph/schemas/workflow-sequential-event.schema.json"
ARTIFACT_SCHEMA_PY="$REPO_ROOT/bundle/.ralph/python/artifact_json_schema.py"

setup_file() {
  command -v python3 >/dev/null || skip "python3 required"
  command -v jq >/dev/null || skip "jq required"
  [ -f "$RUN_SCHEMA" ]
  [ -f "$STAGE_SCHEMA" ]
  [ -f "$EVENT_SCHEMA" ]
  [ -f "$ARTIFACT_SCHEMA_PY" ]
}

setup() {
  TMPD="$(mktemp -d)"
}

teardown() {
  rm -rf "$TMPD"
}

write_json() {
  local path="$1"
  cat >"$path"
}

validate_schema_only() {
  local schema="$1" path="$2"
  python3 "$ARTIFACT_SCHEMA_PY" validate-final-output \
    --schema "$schema" \
    --artifact "$path"
}

# Schema gate plus durable Sequential stage cross-field contracts.
validate_stage_json() {
  local path="$1"
  validate_schema_only "$STAGE_SCHEMA" "$path" || return $?
  python3 - "$path" <<'PY'
import json, sys
path = sys.argv[1]
with open(path, encoding="utf-8") as fh:
    d = json.load(fh)

def fail(msg: str) -> None:
    print(msg, file=sys.stderr)
    raise SystemExit(1)

completed = d.get("completedTodos")
total = d.get("totalTodos")
if not isinstance(completed, int) or not isinstance(total, int):
    fail("completedTodos and totalTodos must be integers")
if completed < 0 or total < 0:
    fail("completedTodos and totalTodos must be nonnegative")
if completed > total:
    fail("completedTodos must be <= totalTodos")

kind = d.get("planSourceKind")
producer = d.get("planSourceStageId")
original = d.get("originalPlanPath")
source = d.get("sourcePlanPath")
control = d.get("controlPlanPath")
plan_path = d.get("planPath")
plan_run = d.get("planRunId")

def is_abs(p):
    return isinstance(p, str) and p.startswith("/")

if kind is None:
    for key, val in (
        ("planSourceStageId", producer),
        ("originalPlanPath", original),
        ("sourcePlanPath", source),
        ("controlPlanPath", control),
        ("planPath", plan_path),
        ("planRunId", plan_run),
        ("currentTodoId", d.get("currentTodoId")),
    ):
        if val is not None:
            fail(f"non-plan-backed stage requires null {key}")
    if completed != 0 or total != 0:
        fail("non-plan-backed stage requires zero completedTodos and totalTodos")
elif kind == "generated":
    if not isinstance(producer, str) or not producer:
        fail("generated planSourceKind requires non-null planSourceStageId producer")
    if original is not None:
        fail("generated planSourceKind requires null originalPlanPath")
    if not is_abs(source):
        fail("generated planSourceKind requires absolute sourcePlanPath")
    if not is_abs(control):
        fail("generated planSourceKind requires absolute controlPlanPath")
    if not is_abs(plan_path):
        fail("generated planSourceKind requires absolute planPath")
    if not isinstance(plan_run, str) or not plan_run:
        fail("generated planSourceKind requires non-null planRunId")
elif kind == "provided":
    if producer is not None:
        fail("provided planSourceKind requires null planSourceStageId")
    if not is_abs(original):
        fail("provided planSourceKind requires absolute originalPlanPath")
    if not is_abs(source):
        fail("provided planSourceKind requires absolute sourcePlanPath")
    if not is_abs(control):
        fail("provided planSourceKind requires absolute controlPlanPath")
    if not is_abs(plan_path):
        fail("provided planSourceKind requires absolute planPath")
    if not isinstance(plan_run, str) or not plan_run:
        fail("provided planSourceKind requires non-null planRunId")
else:
    fail(f"invalid planSourceKind: {kind!r}")

blocker = d.get("blocker")
if blocker is not None:
    if not isinstance(blocker, dict):
        fail("blocker must be object or null")
    for key in ("kind", "requestId", "reasonCode", "retryable", "changesTarget", "action"):
        if key not in blocker:
            fail(f"blocker missing {key}")
    if blocker.get("kind") not in ("approval", "input"):
        fail("blocker.kind must be approval or input")
    if not isinstance(blocker.get("requestId"), str) or not blocker["requestId"]:
        fail("blocker.requestId must be non-empty")
PY
}

validate_run_json() {
  validate_schema_only "$RUN_SCHEMA" "$1"
}

validate_event_json() {
  validate_schema_only "$EVENT_SCHEMA" "$1"
}

# Validate each JSONL row independently against the event schema.
validate_events_jsonl() {
  local path="$1"
  local line i=0
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ -z "$line" ]] && continue
    i=$((i + 1))
    printf '%s\n' "$line" >"$TMPD/event-row-$i.json"
    validate_event_json "$TMPD/event-row-$i.json" || return $?
  done <"$path"
  [[ "$i" -gt 0 ]] || {
    echo "events JSONL had no rows" >&2
    return 1
  }
}

mutate_with_jq() {
  local src="$1" dest="$2"
  shift 2
  jq "$@" "$src" >"$dest"
}

# --- complete positive fixtures ---------------------------------------------

engine_run_json() {
  cat <<'EOF'
{
  "inputSha256": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
  "state": "running",
  "currentStageIds": ["implement"],
  "loopIterations": 0,
  "completedWaves": 1,
  "owner": {
    "pid": 4242,
    "hostname": "dev.host",
    "processStartId": "4242:1704067201",
    "heartbeatAt": "2026-01-01T00:00:02Z"
  },
  "createdAt": "2026-01-01T00:00:00Z",
  "updatedAt": "2026-01-01T00:00:02Z"
}
EOF
}

# Non-plan-backed ordinary/inline stage (null plan-source/control; zero counts).
stage_inline_json() {
  cat <<'EOF'
{
  "id": "investigate",
  "index": 0,
  "state": "succeeded",
  "attempt": 1,
  "planPath": null,
  "planRunId": null,
  "planSourceKind": null,
  "planSourceStageId": null,
  "originalPlanPath": null,
  "sourcePlanPath": null,
  "controlPlanPath": null,
  "currentTodoId": null,
  "wave": 0,
  "terminalResult": "succeeded",
  "blocker": null,
  "completedTodos": 0,
  "totalTodos": 0,
  "artifacts": [
    ".ralph-workspace/artifacts/ns/investigation.md"
  ],
  "createdAt": "2026-01-01T00:00:00Z",
  "updatedAt": "2026-01-01T00:01:00Z"
}
EOF
}

# Generated planFrom consumer stage.
stage_generated_json() {
  cat <<'EOF'
{
  "id": "implement",
  "index": 2,
  "state": "running",
  "attempt": 1,
  "planPath": "/tmp/project/.ralph-workspace/workflow-runs/run-1/plans/implement/control.plan.md",
  "planRunId": "plan-run-implement-1",
  "planSourceKind": "generated",
  "planSourceStageId": "plan-implementation",
  "originalPlanPath": null,
  "sourcePlanPath": "/tmp/project/.ralph-workspace/workflow-runs/run-1/plans/plan-implementation/attempt-1.plan.md",
  "controlPlanPath": "/tmp/project/.ralph-workspace/workflow-runs/run-1/plans/implement/control.plan.md",
  "currentTodoId": "fix-timeout",
  "wave": null,
  "terminalResult": null,
  "blocker": null,
  "completedTodos": 1,
  "totalTodos": 4,
  "artifacts": [],
  "createdAt": "2026-01-01T00:02:00Z",
  "updatedAt": "2026-01-01T00:03:00Z"
}
EOF
}

# Provided planInput consumer stage.
stage_provided_json() {
  cat <<'EOF'
{
  "id": "implement",
  "index": 0,
  "state": "running",
  "attempt": 1,
  "planPath": "/tmp/project/.ralph-workspace/workflow-runs/run-2/plans/implement/control.plan.md",
  "planRunId": "plan-run-provided-1",
  "planSourceKind": "provided",
  "planSourceStageId": null,
  "originalPlanPath": "/tmp/project/plans/feature.plan.md",
  "sourcePlanPath": "/tmp/project/.ralph-workspace/workflow-runs/run-2/plans/input/source.plan.md",
  "controlPlanPath": "/tmp/project/.ralph-workspace/workflow-runs/run-2/plans/implement/control.plan.md",
  "currentTodoId": "add-filter",
  "wave": null,
  "terminalResult": null,
  "blocker": null,
  "completedTodos": 0,
  "totalTodos": 3,
  "artifacts": [],
  "createdAt": "2026-01-01T00:04:00Z",
  "updatedAt": "2026-01-01T00:04:30Z"
}
EOF
}

# Approval supervisor stage with blocker/action references.
stage_approval_json() {
  cat <<'EOF'
{
  "id": "approve-plan",
  "index": 1,
  "state": "waiting",
  "attempt": 1,
  "planPath": null,
  "planRunId": null,
  "planSourceKind": null,
  "planSourceStageId": null,
  "originalPlanPath": null,
  "sourcePlanPath": null,
  "controlPlanPath": null,
  "currentTodoId": null,
  "wave": null,
  "terminalResult": null,
  "blocker": {
    "kind": "approval",
    "requestId": "appr-001",
    "reasonCode": "human-approval",
    "retryable": false,
    "changesTarget": "plan-implementation",
    "action": {
      "label": "List outstanding actions",
      "argv": ["ralph", "workflow", "actions", "list", "run-1"]
    }
  },
  "completedTodos": 0,
  "totalTodos": 0,
  "artifacts": [],
  "createdAt": "2026-01-01T00:05:00Z",
  "updatedAt": "2026-01-01T00:05:00Z"
}
EOF
}

event_row_json() {
  jq -nc '{
    schemaVersion: 1,
    sequence: 0,
    timestamp: "2026-01-01T00:00:00Z",
    runId: "run-20260101T000000Z-0-aaaaaa",
    stageId: null,
    event: "run-created",
    priorState: null,
    newState: "queued",
    details: {}
  }'
}

event_stage_row_json() {
  jq -nc '{
    schemaVersion: 1,
    sequence: 3,
    timestamp: "2026-01-01T00:05:00Z",
    runId: "run-20260101T000000Z-0-aaaaaa",
    stageId: "approve-plan",
    event: "stage-state-changed",
    priorState: "running",
    newState: "waiting",
    details: {
      requestId: "appr-001",
      reasonCode: "human-approval"
    }
  }'
}

# --- positive tests ---------------------------------------------------------

@test "Sequential engine run.json validates" {
  write_json "$TMPD/run.json" < <(engine_run_json)
  run validate_run_json "$TMPD/run.json"
  [ "$status" -eq 0 ]
}

@test "inline non-plan-backed stage validates" {
  write_json "$TMPD/inline.json" < <(stage_inline_json)
  run validate_stage_json "$TMPD/inline.json"
  [ "$status" -eq 0 ]
}

@test "generated planFrom stage validates" {
  write_json "$TMPD/generated.json" < <(stage_generated_json)
  run validate_stage_json "$TMPD/generated.json"
  [ "$status" -eq 0 ]
}

@test "provided planInput stage validates" {
  write_json "$TMPD/provided.json" < <(stage_provided_json)
  run validate_stage_json "$TMPD/provided.json"
  [ "$status" -eq 0 ]
}

@test "approval stage with blocker action references validates" {
  write_json "$TMPD/approval.json" < <(stage_approval_json)
  run validate_stage_json "$TMPD/approval.json"
  [ "$status" -eq 0 ]
}

@test "event JSONL rows validate one at a time" {
  {
    event_row_json
    event_stage_row_json
  } >"$TMPD/events.jsonl"
  run validate_events_jsonl "$TMPD/events.jsonl"
  [ "$status" -eq 0 ]
}

# --- table-driven negatives (one per durable contract) ----------------------

@test "invalid contracts are table-driven: unknown type enum path counter crossField completedOrder missing" {
  write_json "$TMPD/base-run.json" < <(engine_run_json)
  write_json "$TMPD/base-inline.json" < <(stage_inline_json)
  write_json "$TMPD/base-generated.json" < <(stage_generated_json)
  write_json "$TMPD/base-provided.json" < <(stage_provided_json)
  write_json "$TMPD/base-approval.json" < <(stage_approval_json)
  write_json "$TMPD/base-event.json" < <(event_row_json)

  # case_id | target | jq filter
  # unknown: additionalProperties false
  # type: wrong JSON type
  # enum: illegal enum member
  # path: relative path where absolute is required when non-null
  # counter: negative attempt/index/sequence/loop
  # crossField: source-kind/path/producer mismatch
  # completedOrder: completedTodos > totalTodos
  # missing: drop a required field
  local -a cases=(
    "unknown|run|.extra = true"
    "type|run|.state = 1"
    "enum|run|.state = \"paused\""
    "path|generated|.sourcePlanPath = \"relative/source.plan.md\""
    "counter|run|.loopIterations = -1"
    "crossField|generated|.planSourceStageId = null"
    "completedOrder|generated|.completedTodos = 9 | .totalTodos = 2"
    "missing|event|del(.sequence)"
    "pathProvided|provided|.originalPlanPath = \"plans/feature.plan.md\""
    "crossFieldProvided|provided|.planSourceStageId = \"planner\""
    "crossFieldInline|inline|.planSourceKind = null | .sourcePlanPath = \"/tmp/x.plan.md\""
    "counterStage|inline|.index = -1"
    "counterEvent|event|.sequence = -1"
    "counterAttempt|inline|.attempt = -1"
    "unknownStage|approval|.unexpected = 1"
    "unknownEvent|event|.unexpected = 1"
    "approvalBlocker|approval|del(.blocker.requestId)"
  )

  local spec case_id target filter src dest
  for spec in "${cases[@]}"; do
    IFS='|' read -r case_id target filter <<<"$spec"
    case "$target" in
      run) src="$TMPD/base-run.json" ;;
      inline) src="$TMPD/base-inline.json" ;;
      generated) src="$TMPD/base-generated.json" ;;
      provided) src="$TMPD/base-provided.json" ;;
      approval) src="$TMPD/base-approval.json" ;;
      event) src="$TMPD/base-event.json" ;;
      *) echo "unknown target $target" >&2; return 1 ;;
    esac
    dest="$TMPD/invalid-${case_id}.json"
    mutate_with_jq "$src" "$dest" "$filter"
    case "$target" in
      run)
        run validate_run_json "$dest"
        ;;
      event)
        run validate_event_json "$dest"
        ;;
      *)
        run validate_stage_json "$dest"
        ;;
    esac
    [ "$status" -ne 0 ]
  done
}
