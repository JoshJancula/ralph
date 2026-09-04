#!/usr/bin/env bats
# Normalized diagnosis of a stalled workflow run.
#
# Every case calls the pure diagnosis function against hand-written ledger and
# action-record fixtures with a stubbed liveness predicate. No graph, process,
# runner, or polling loop is ever started, and nothing on disk is mutated.

source "$BATS_TEST_DIRNAME/../helper/load-lib.bash"

setup_file() {
  command -v jq >/dev/null || skip "jq required"
  command -v python3 >/dev/null || skip "python3 required"
}

setup() {
  TMPD="$(mktemp -d)"
  RUN_DIR="$TMPD/run"
  mkdir -p "$RUN_DIR/actions/requests" "$RUN_DIR/actions/decisions" \
    "$RUN_DIR/actions/consumed"
  # shellcheck source=../../../bundle/.ralph/bash-lib/graph/graph-operator-records.sh
  source "$REPO_ROOT/bundle/.ralph/bash-lib/graph/graph-operator-records.sh"
  # shellcheck source=../../../bundle/.ralph/bash-lib/workflow/workflow-actions.sh
  source "$REPO_ROOT/bundle/.ralph/bash-lib/workflow/workflow-actions.sh"
  unset RALPH_WORKFLOW_DIAGNOSE_LOADED
  # shellcheck source=../../../bundle/.ralph/bash-lib/workflow/workflow-diagnose.sh
  source "$REPO_ROOT/bundle/.ralph/bash-lib/workflow/workflow-diagnose.sh"
}

teardown() {
  [ -n "${TMPD:-}" ] && rm -rf "$TMPD"
}

# --- fixtures ---------------------------------------------------------------

write_request() {
  local request_id="$1" kind="$2" stage_id="${3:-implement}"
  jq -cn --arg id "$request_id" --arg kind "$kind" --arg stage "$stage_id" \
    '{requestId: $id, kind: $kind, stageId: $stage, runId: "run-fixture",
      question: "fixture question", createdAt: "2026-01-01T00:00:00Z"}' \
    >"$RUN_DIR/actions/requests/$request_id.json"
}

write_decision() {
  local request_id="$1" kind="$2" choice="$3"
  jq -cn --arg id "$request_id" --arg kind "$kind" --arg choice "$choice" \
    '{requestId: $id, kind: $kind, decision: $choice, runId: "run-fixture",
      decidedAt: "2026-01-01T00:01:00Z"}' \
    >"$RUN_DIR/actions/decisions/$request_id.json"
}

write_consumed() {
  local request_id="$1"
  jq -cn --arg id "$request_id" \
    '{requestId: $id, consumedAt: "2026-01-01T00:02:00Z"}' \
    >"$RUN_DIR/actions/consumed/$request_id.json"
}

# Observation builder: a ledger fixture as the diagnosis function sees it.
observation() {
  python3 - "$@" <<'PY'
import json, sys
out = {"runId": "run-fixture", "runStatus": "waiting"}
for arg in sys.argv[1:]:
    key, _, raw = arg.partition("=")
    out[key] = json.loads(raw)
print(json.dumps(out))
PY
}

diagnose() {
  run workflow_diagnose_dependency "$RUN_DIR" "$1"
}

field() {
  printf '%s' "$1" | jq -r "$2"
}

# --- structured shape -------------------------------------------------------

@test "Dependency diagnosis returns the structured object with every field" {
  diagnose "$(observation 'runStatus="waiting"')"
  [ "$status" -eq 0 ]
  printf '%s' "$output" | jq -e '
    has("state") and has("reasonCode") and has("summary") and has("stageId")
    and has("requestKind") and has("requestId") and has("evidence")
    and has("retryable") and has("nextAction")
    and (.evidence | type == "array")
    and (.retryable | type == "boolean")
    and ((.nextAction == null) or ((.nextAction.argv | type) == "array"))
  ' >/dev/null
}

@test "Dependency diagnosis never mutates the run directory" {
  write_request req-1 approval approve-plan
  local before
  before="$(find "$RUN_DIR" -type f | sort | xargs cksum | cksum)"
  diagnose "$(observation \
    'nodes=[{"id":"approve-plan","state":"waiting","blocker":{"kind":"approval","requestId":"req-1","retryable":false}}]')"
  [ "$status" -eq 0 ]
  [ "$(find "$RUN_DIR" -type f | sort | xargs cksum | cksum)" = "$before" ]
}

# --- clean interruption -----------------------------------------------------

@test "Dependency clean operator interruption is retryable waiting with resume" {
  diagnose "$(observation 'runStatus="waiting"')"
  [ "$status" -eq 0 ]
  [ "$(field "$output" '.state')" = "waiting" ]
  [ "$(field "$output" '.reasonCode')" = "operator-request" ]
  [ "$(field "$output" '.retryable')" = "true" ]
  [ "$(field "$output" '.nextAction.argv | join(" ")')" = "ralph workflow resume run-fixture" ]
}

# --- operator input ---------------------------------------------------------

@test "Dependency outstanding operator input is nonretryable waiting with the actions list" {
  write_request req-input input implement
  diagnose "$(observation \
    'nodes=[{"id":"implement","state":"waiting","blocker":{"kind":"input","requestId":"req-input","retryable":false}}]')"
  [ "$status" -eq 0 ]
  [ "$(field "$output" '.state')" = "waiting" ]
  [ "$(field "$output" '.reasonCode')" = "operator-input" ]
  [ "$(field "$output" '.retryable')" = "false" ]
  [ "$(field "$output" '.stageId')" = "implement" ]
  [ "$(field "$output" '.requestKind')" = "input" ]
  [ "$(field "$output" '.requestId')" = "req-input" ]
  [ "$(field "$output" '.nextAction.argv | join(" ")')" = "ralph workflow actions list run-fixture" ]
}

@test "Dependency answered input is retryable waiting with resume" {
  write_request req-input input implement
  write_decision req-input input answer
  diagnose "$(observation \
    'nodes=[{"id":"implement","state":"waiting","blocker":{"kind":"input","requestId":"req-input","retryable":false}}]')"
  [ "$status" -eq 0 ]
  [ "$(field "$output" '.state')" = "waiting" ]
  [ "$(field "$output" '.reasonCode')" = "operator-input" ]
  [ "$(field "$output" '.retryable')" = "true" ]
  [ "$(field "$output" '.nextAction.argv | join(" ")')" = "ralph workflow resume run-fixture" ]
}

# --- human approval ---------------------------------------------------------

@test "Dependency outstanding human approval is nonretryable waiting" {
  write_request req-gate approval approve-plan
  diagnose "$(observation \
    'nodes=[{"id":"approve-plan","state":"waiting","blocker":{"kind":"approval","requestId":"req-gate","retryable":false}}]')"
  [ "$status" -eq 0 ]
  [ "$(field "$output" '.state')" = "waiting" ]
  [ "$(field "$output" '.reasonCode')" = "human-approval" ]
  [ "$(field "$output" '.retryable')" = "false" ]
  [ "$(field "$output" '.nextAction.argv | join(" ")')" = "ralph workflow actions list run-fixture" ]
}

@test "Dependency approved gate is retryable waiting with resume" {
  write_request req-gate approval approve-plan
  write_decision req-gate approval approve
  diagnose "$(observation \
    'nodes=[{"id":"approve-plan","state":"waiting","blocker":{"kind":"approval","requestId":"req-gate","retryable":false}}]')"
  [ "$status" -eq 0 ]
  [ "$(field "$output" '.state')" = "waiting" ]
  [ "$(field "$output" '.reasonCode')" = "human-approval" ]
  [ "$(field "$output" '.retryable')" = "true" ]
  [ "$(field "$output" '.nextAction.argv | join(" ")')" = "ralph workflow resume run-fixture" ]
}

# --- changes requested ------------------------------------------------------

@test "Dependency human changes requested is blocked with the exact reset target" {
  write_request req-gate approval approve-plan
  write_decision req-gate approval request-changes
  diagnose "$(observation \
    'nodes=[{"id":"approve-plan","state":"blocked","changesTarget":"plan-implementation","blocker":{"kind":"approval","requestId":"req-gate","retryable":false}}]')"
  [ "$status" -eq 0 ]
  [ "$(field "$output" '.state')" = "blocked" ]
  [ "$(field "$output" '.reasonCode')" = "human-changes-requested" ]
  [ "$(field "$output" '.retryable')" = "false" ]
  [ "$(field "$output" '.nextAction.argv | join(" ")')" = "ralph workflow reset run-fixture --stage plan-implementation" ]
}

@test "Dependency changes requested outranks a live owner and a pending stage" {
  diagnose "$(observation 'ownerClass="healthy"' 'runStatus="running"' \
    'nodes=[{"id":"qa","state":"pending","unmetDependencies":["integrate"]},{"id":"approve-result","reasonCode":"human-changes-requested","changesTarget":"plan-implementation"}]')"
  [ "$status" -eq 0 ]
  [ "$(field "$output" '.reasonCode')" = "human-changes-requested" ]
  [ "$(field "$output" '.stageId')" = "approve-result" ]
}

# --- native permission requests ---------------------------------------------

@test "Dependency permission request is a nonretryable waiting operator request" {
  write_request req-perm permission implement
  diagnose "$(observation \
    'nodes=[{"id":"implement","state":"waiting","blocker":{"kind":"permission","requestId":"req-perm","retryable":false}}]')"
  [ "$status" -eq 0 ]
  [ "$(field "$output" '.state')" = "waiting" ]
  [ "$(field "$output" '.reasonCode')" = "operator-request" ]
  [ "$(field "$output" '.retryable')" = "false" ]
  [ "$(field "$output" '.requestKind')" = "permission" ]
  [ "$(field "$output" '.nextAction.argv | join(" ")')" = "ralph workflow actions list run-fixture" ]
}

@test "Dependency consumed request that is still waiting refuses resume" {
  write_request req-input input implement
  write_decision req-input input answer
  write_consumed req-input
  diagnose "$(observation \
    'nodes=[{"id":"implement","state":"waiting","blocker":{"kind":"input","requestId":"req-input","retryable":false}}]')"
  [ "$status" -eq 0 ]
  [ "$(field "$output" '.state')" = "blocked" ]
  [ "$(field "$output" '.reasonCode')" = "stage-failed" ]
  [ "$(field "$output" '.retryable')" = "false" ]
  [ "$(field "$output" '.nextAction')" = "null" ]
}

# --- prerequisites and artifacts --------------------------------------------

@test "Dependency unmet prerequisite is blocked with the dependency named" {
  diagnose "$(observation 'runStatus="blocked"' \
    'nodes=[{"id":"qa","state":"pending","unmetDependencies":["plan-qa"]}]')"
  [ "$status" -eq 0 ]
  [ "$(field "$output" '.state')" = "blocked" ]
  [ "$(field "$output" '.reasonCode')" = "unmet-dependency" ]
  [ "$(field "$output" '.stageId')" = "qa" ]
  printf '%s' "$output" | jq -e '.evidence | index("unmet dependency plan-qa")' >/dev/null
}

@test "Dependency failed prerequisite outranks an unmet dependency" {
  diagnose "$(observation 'runStatus="blocked"' \
    'nodes=[{"id":"integrate","state":"blocked","unmetDependencies":["review-approved"],"failedPrerequisites":["review"]}]')"
  [ "$status" -eq 0 ]
  [ "$(field "$output" '.reasonCode')" = "failed-prerequisite" ]
  printf '%s' "$output" | jq -e '.evidence | index("failed prerequisite review")' >/dev/null
}

@test "Dependency missing artifact is blocked with the path named" {
  diagnose "$(observation 'runStatus="blocked"' \
    'nodes=[{"id":"review","state":"blocked","missingArtifacts":[".ralph-workspace/artifacts/ns/implementation-handoff.md"]}]')"
  [ "$status" -eq 0 ]
  [ "$(field "$output" '.reasonCode')" = "missing-artifact" ]
  printf '%s' "$output" | jq -e '
    .evidence | index("missing artifact .ralph-workspace/artifacts/ns/implementation-handoff.md")
  ' >/dev/null
}

@test "Dependency invalid artifact outranks a missing artifact" {
  diagnose "$(observation 'runStatus="blocked"' \
    'nodes=[{"id":"review","state":"blocked","missingArtifacts":["a.md"],"invalidArtifacts":["review-verdict.json"]}]')"
  [ "$status" -eq 0 ]
  [ "$(field "$output" '.reasonCode')" = "invalid-artifact" ]
}

# --- exhausted rework -------------------------------------------------------

@test "Dependency exhausted rework loop is blocked and not retryable" {
  diagnose "$(observation 'runStatus="blocked"' \
    'nodes=[{"id":"review","state":"blocked","loop":{"iterations":2,"max":2}}]')"
  [ "$status" -eq 0 ]
  [ "$(field "$output" '.state')" = "blocked" ]
  [ "$(field "$output" '.reasonCode')" = "loop-exhausted" ]
  [ "$(field "$output" '.retryable')" = "false" ]
  [ "$(field "$output" '.nextAction')" = "null" ]
  printf '%s' "$output" | jq -e '.evidence | index("iteration 2 of 2")' >/dev/null
}

@test "Dependency final review exhaustion names the verdict and repair reset" {
  diagnose "$(observation 'runStatus="failed"' \
    'nodes=[{"id":"review-r2","state":"failed","reasonCode":"review-changes-required-no-edge","dependencies":[{"stageId":"implement-r2","condition":null}],"artifacts":["/tmp/review-r2-verdict.json"]},{"id":"qa","state":"blocked","failedPrerequisites":["review-r2"]}]')"
  [ "$status" -eq 0 ]
  [ "$(field "$output" '.state')" = "blocked" ]
  [ "$(field "$output" '.reasonCode')" = "loop-exhausted" ]
  [ "$(field "$output" '.stageId')" = "review-r2" ]
  [[ "$(field "$output" '.summary')" == *"integration and verification did not run"* ]]
  [ "$(field "$output" '.nextAction.argv | join(" ")')" = \
    "ralph workflow reset run-fixture --stage implement-r2" ]
  printf '%s' "$output" | jq -e '
    .evidence | index("final review verdict /tmp/review-r2-verdict.json")
  ' >/dev/null
}

@test "Dependency rework under its ceiling is not reported as exhausted" {
  diagnose "$(observation 'runStatus="waiting"' \
    'nodes=[{"id":"review","state":"waiting","loop":{"iterations":1,"max":2}}]')"
  [ "$status" -eq 0 ]
  [ "$(field "$output" '.reasonCode')" != "loop-exhausted" ]
}

# --- cycle ------------------------------------------------------------------

@test "Dependency explicit cycle is blocked with no next action" {
  diagnose "$(observation 'runStatus="blocked"' 'cycle=["implement","review"]')"
  [ "$status" -eq 0 ]
  [ "$(field "$output" '.state')" = "blocked" ]
  [ "$(field "$output" '.reasonCode')" = "cycle" ]
  [ "$(field "$output" '.retryable')" = "false" ]
  [ "$(field "$output" '.nextAction')" = "null" ]
  printf '%s' "$output" | jq -e '.evidence | index("cycle member implement")' >/dev/null
}

@test "Dependency cycle outranks every other cause" {
  write_request req-gate approval approve-plan
  diagnose "$(observation 'runStatus="blocked"' 'cycle=["a","b"]' \
    'nodes=[{"id":"approve-plan","state":"waiting","blocker":{"kind":"approval","requestId":"req-gate"}}]')"
  [ "$status" -eq 0 ]
  [ "$(field "$output" '.reasonCode')" = "cycle" ]
}

# --- owner liveness ---------------------------------------------------------

@test "Dependency stale owner is recoverable" {
  diagnose "$(observation 'ownerClass="stale"' 'runStatus="running"' \
    'heartbeatAt="2026-01-01T00:00:00Z"')"
  [ "$status" -eq 0 ]
  [ "$(field "$output" '.state')" = "stale" ]
  [ "$(field "$output" '.reasonCode')" = "stale-owner" ]
  [ "$(field "$output" '.retryable')" = "true" ]
  [ "$(field "$output" '.nextAction.argv | join(" ")')" = "ralph workflow recover run-fixture" ]
}

@test "Dependency live owner reports progress rather than a blocker" {
  diagnose "$(observation 'ownerClass="healthy"' 'runStatus="running"' 'ownerPid=4242')"
  [ "$status" -eq 0 ]
  [ "$(field "$output" '.state')" = "running" ]
  [ "$(field "$output" '.reasonCode')" = "live-owner" ]
  [ "$(field "$output" '.nextAction')" = "null" ]
  printf '%s' "$output" | jq -e '.evidence | index("owner pid 4242")' >/dev/null
}

@test "Dependency liveness predicate is overridable for stub-driven diagnosis" {
  workflow_diagnose_owner_class() { printf 'stale'; }
  diagnose "$(observation 'runStatus="running"')"
  [ "$status" -eq 0 ]
  [ "$(field "$output" '.reasonCode')" = "stale-owner" ]
}

# --- cancelled --------------------------------------------------------------

@test "Dependency cancelled run is terminal with no next action" {
  diagnose "$(observation 'runStatus="cancelled"')"
  [ "$status" -eq 0 ]
  [ "$(field "$output" '.state')" = "cancelled" ]
  [ "$(field "$output" '.reasonCode')" = "cancelled" ]
  [ "$(field "$output" '.retryable')" = "false" ]
}

@test "Dependency plain stage failure falls back to stage-failed" {
  diagnose "$(observation 'runStatus="blocked"' 'nodes=[{"id":"implement","state":"failed"}]')"
  [ "$status" -eq 0 ]
  [ "$(field "$output" '.reasonCode')" = "stage-failed" ]
  [ "$(field "$output" '.stageId')" = "implement" ]
}

@test "Dependency every emitted reason code is a declared public code" {
  local observations=(
    'runStatus="waiting"'
    'runStatus="cancelled"'
    'runStatus="blocked"|cycle=["a"]'
    'runStatus="blocked"|nodes=[{"id":"a","state":"failed"}]'
    'ownerClass="stale"|runStatus="running"'
    'ownerClass="healthy"|runStatus="running"'
  )
  local spec obs code
  for spec in "${observations[@]}"; do
    IFS='|' read -r -a parts <<<"$spec"
    obs="$(observation "${parts[@]}")"
    diagnose "$obs"
    [ "$status" -eq 0 ]
    code="$(field "$output" '.reasonCode')"
    printf '%s\n' "${WORKFLOW_DIAGNOSE_REASON_CODES[@]}" | grep -qx "$code"
    printf '%s\n' "${WORKFLOW_DIAGNOSE_STATES[@]}" | grep -qx "$(field "$output" '.state')"
  done
}

# --- Sequential -------------------------------------------------------------
#
# Sequential stalls for the same operator-visible reasons as Dependency, with two
# differences: waves can fail as a unit, and a native permission request cannot
# occur at all. Every case below uses minimal stored-state fixtures; no
# orchestration is replayed.

diagnose_seq() {
  run workflow_diagnose_sequential "$RUN_DIR" "$1"
}

@test "Sequential clean operator interruption is retryable waiting with resume" {
  diagnose_seq "$(observation 'runStatus="waiting"')"
  [ "$status" -eq 0 ]
  [ "$(field "$output" '.state')" = "waiting" ]
  [ "$(field "$output" '.reasonCode')" = "operator-request" ]
  [ "$(field "$output" '.retryable')" = "true" ]
  [ "$(field "$output" '.nextAction.argv | join(" ")')" = "ralph workflow resume run-fixture" ]
}

@test "Sequential outstanding operator input requires the actions list" {
  write_request req-input input build
  diagnose_seq "$(observation \
    'nodes=[{"id":"build","state":"waiting","blocker":{"kind":"input","requestId":"req-input","retryable":false}}]')"
  [ "$status" -eq 0 ]
  [ "$(field "$output" '.reasonCode')" = "operator-input" ]
  [ "$(field "$output" '.retryable')" = "false" ]
  [ "$(field "$output" '.nextAction.argv | join(" ")')" = "ralph workflow actions list run-fixture" ]
}

@test "Sequential answered input is retryable waiting with resume" {
  write_request req-input input build
  write_decision req-input input answer
  diagnose_seq "$(observation \
    'nodes=[{"id":"build","state":"waiting","blocker":{"kind":"input","requestId":"req-input","retryable":false}}]')"
  [ "$status" -eq 0 ]
  [ "$(field "$output" '.reasonCode')" = "operator-input" ]
  [ "$(field "$output" '.retryable')" = "true" ]
  [ "$(field "$output" '.nextAction.argv | join(" ")')" = "ralph workflow resume run-fixture" ]
}

@test "Sequential human approval outstanding then approved flips retryability" {
  write_request req-gate approval approve-plan
  diagnose_seq "$(observation \
    'nodes=[{"id":"approve-plan","state":"waiting","blocker":{"kind":"approval","requestId":"req-gate","retryable":false}}]')"
  [ "$status" -eq 0 ]
  [ "$(field "$output" '.reasonCode')" = "human-approval" ]
  [ "$(field "$output" '.retryable')" = "false" ]

  write_decision req-gate approval approve
  diagnose_seq "$(observation \
    'nodes=[{"id":"approve-plan","state":"waiting","blocker":{"kind":"approval","requestId":"req-gate","retryable":false}}]')"
  [ "$status" -eq 0 ]
  [ "$(field "$output" '.reasonCode')" = "human-approval" ]
  [ "$(field "$output" '.retryable')" = "true" ]
  [ "$(field "$output" '.nextAction.argv | join(" ")')" = "ralph workflow resume run-fixture" ]
}

@test "Sequential changes requested is blocked with the exact reset target" {
  write_request req-gate approval approve-plan
  write_decision req-gate approval request-changes
  diagnose_seq "$(observation \
    'nodes=[{"id":"approve-plan","state":"blocked","changesTarget":"plan-implementation","blocker":{"kind":"approval","requestId":"req-gate","retryable":false}}]')"
  [ "$status" -eq 0 ]
  [ "$(field "$output" '.state')" = "blocked" ]
  [ "$(field "$output" '.reasonCode')" = "human-changes-requested" ]
  [ "$(field "$output" '.nextAction.argv | join(" ")')" = "ralph workflow reset run-fixture --stage plan-implementation" ]
}

@test "Sequential native permission request is impossible and reported as inconsistent" {
  write_request req-perm permission build
  diagnose_seq "$(observation \
    'nodes=[{"id":"build","state":"waiting","blocker":{"kind":"permission","requestId":"req-perm","retryable":false}}]')"
  [ "$status" -eq 0 ]
  [ "$(field "$output" '.state')" = "blocked" ]
  [ "$(field "$output" '.reasonCode')" = "stage-failed" ]
  [ "$(field "$output" '.retryable')" = "false" ]
  [[ "$(field "$output" '.summary')" == *"cannot occur on the sequential engine"* ]]
  [ "$(field "$output" '.nextAction')" = "null" ]
}

@test "Sequential missing stage artifact names the path" {
  diagnose_seq "$(observation 'runStatus="blocked"' \
    'nodes=[{"id":"qa","state":"blocked","missingArtifacts":[".ralph-workspace/artifacts/ns/qa-handoff.md"]}]')"
  [ "$status" -eq 0 ]
  [ "$(field "$output" '.reasonCode')" = "missing-artifact" ]
  [ "$(field "$output" '.stageId')" = "qa" ]
  printf '%s' "$output" | jq -e '
    .evidence | index("missing artifact .ralph-workspace/artifacts/ns/qa-handoff.md")
  ' >/dev/null
}

@test "Sequential failed prior stage blocks the next one" {
  diagnose_seq "$(observation 'runStatus="blocked"' \
    'nodes=[{"id":"qa","state":"pending","failedPrerequisites":["implement"]}]')"
  [ "$status" -eq 0 ]
  [ "$(field "$output" '.reasonCode')" = "failed-prerequisite" ]
  printf '%s' "$output" | jq -e '.evidence | index("failed prerequisite implement")' >/dev/null
}

@test "Sequential exhausted loop is blocked and not retryable" {
  diagnose_seq "$(observation 'runStatus="blocked"' \
    'nodes=[{"id":"review","state":"blocked","loop":{"iterations":3,"max":3}}]')"
  [ "$status" -eq 0 ]
  [ "$(field "$output" '.reasonCode')" = "loop-exhausted" ]
  [ "$(field "$output" '.retryable')" = "false" ]
  printf '%s' "$output" | jq -e '.evidence | index("iteration 3 of 3")' >/dev/null
}

@test "Sequential parallel wave failure names the wave and its failed member" {
  diagnose_seq "$(observation 'runStatus="blocked"' \
    'nodes=[{"id":"package","state":"blocked","wave":2,"waveFailures":["sign"]}]')"
  [ "$status" -eq 0 ]
  [ "$(field "$output" '.state')" = "blocked" ]
  [ "$(field "$output" '.reasonCode')" = "stage-failed" ]
  [ "$(field "$output" '.stageId')" = "package" ]
  [[ "$(field "$output" '.summary')" == *"wave 2"* ]]
  printf '%s' "$output" | jq -e '.evidence | index("failed in wave 2: sign")' >/dev/null
}

@test "Sequential live lock reports the owning supervisor rather than a blocker" {
  diagnose_seq "$(observation 'ownerClass="healthy"' 'runStatus="running"' 'ownerPid=99')"
  [ "$status" -eq 0 ]
  [ "$(field "$output" '.state')" = "running" ]
  [ "$(field "$output" '.reasonCode')" = "live-owner" ]
  [ "$(field "$output" '.nextAction')" = "null" ]
}

@test "Sequential dead owner is recoverable" {
  diagnose_seq "$(observation 'ownerClass="stale"' 'runStatus="running"')"
  [ "$status" -eq 0 ]
  [ "$(field "$output" '.state')" = "stale" ]
  [ "$(field "$output" '.reasonCode')" = "stale-owner" ]
  [ "$(field "$output" '.retryable')" = "true" ]
  [ "$(field "$output" '.nextAction.argv | join(" ")')" = "ralph workflow recover run-fixture" ]
}

@test "Sequential diagnosis never mutates the run directory" {
  write_request req-gate approval approve-plan
  local before
  before="$(find "$RUN_DIR" -type f | sort | xargs cksum | cksum)"
  diagnose_seq "$(observation \
    'nodes=[{"id":"approve-plan","state":"waiting","blocker":{"kind":"approval","requestId":"req-gate"}}]')"
  [ "$status" -eq 0 ]
  [ "$(find "$RUN_DIR" -type f | sort | xargs cksum | cksum)" = "$before" ]
}

# --- normalized outer state persistence -------------------------------------

@test "Sequential deadlock persists normalized outer state instead of leaving running" {
  # shellcheck source=../../../bundle/.ralph/bash-lib/workflow/workflow-state.sh
  source "$REPO_ROOT/bundle/.ralph/bash-lib/workflow/workflow-state.sh"
  local state_root="$TMPD/state"
  local run_id="run-20260101T000000Z-0-aaaaaa"
  local run_dir="$state_root/workflow-runs/$run_id"
  mkdir -p "$run_dir"
  printf 'plan\n' >"$run_dir/input.plan.md"
  jq -n --arg id "$run_id" --arg input "$run_dir/input.plan.md" \
    '{runId: $id, state: "running", mode: "sequential", entryKind: "task",
      sourceKind: "project", sourcePath: "/tmp/x.workflow.md", task: "t",
      taskProvenance: "explicit", inputPath: $input,
      createdAt: "2026-01-01T00:00:00Z", updatedAt: "2026-01-01T00:00:00Z"}' \
    >"$run_dir/run.json"

  local diagnosis
  diagnosis="$(workflow_diagnose_sequential "$RUN_DIR" \
    "$(observation 'runStatus="blocked"' \
      'nodes=[{"id":"qa","state":"blocked","missingArtifacts":["qa-handoff.md"]}]')")"
  [ "$(field "$diagnosis" '.state')" = "blocked" ]

  run workflow_diagnose_persist_outer_state "$state_root" "$run_id" "$diagnosis"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.state' "$run_dir/run.json")" = "blocked" ]

  # Idempotent: persisting the same normalized state again is a no-op success.
  run workflow_diagnose_persist_outer_state "$state_root" "$run_id" "$diagnosis"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.state' "$run_dir/run.json")" = "blocked" ]
}

@test "Sequential still-progressing diagnosis leaves outer state untouched" {
  # shellcheck source=../../../bundle/.ralph/bash-lib/workflow/workflow-state.sh
  source "$REPO_ROOT/bundle/.ralph/bash-lib/workflow/workflow-state.sh"
  local state_root="$TMPD/state2"
  local run_id="run-20260101T000000Z-0-bbbbbb"
  local run_dir="$state_root/workflow-runs/$run_id"
  mkdir -p "$run_dir"
  printf 'plan\n' >"$run_dir/input.plan.md"
  jq -n --arg id "$run_id" --arg input "$run_dir/input.plan.md" \
    '{runId: $id, state: "running", mode: "sequential", entryKind: "task",
      sourceKind: "project", sourcePath: "/tmp/x.workflow.md", task: "t",
      taskProvenance: "explicit", inputPath: $input,
      createdAt: "2026-01-01T00:00:00Z", updatedAt: "2026-01-01T00:00:00Z"}' \
    >"$run_dir/run.json"

  local diagnosis
  diagnosis="$(workflow_diagnose_sequential "$RUN_DIR" \
    "$(observation 'ownerClass="healthy"' 'runStatus="running"')")"
  [ "$(field "$diagnosis" '.state')" = "running" ]
  run workflow_diagnose_persist_outer_state "$state_root" "$run_id" "$diagnosis"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.state' "$run_dir/run.json")" = "running" ]
}

# --- regression -------------------------------------------------------------

@test "Sequential support is a regression-free addition for Dependency runs" {
  # The permission branch is the only engine-specific difference; Dependency must
  # still treat it as an answerable outstanding request.
  write_request req-perm permission implement
  local obs
  obs="$(observation \
    'nodes=[{"id":"implement","state":"waiting","blocker":{"kind":"permission","requestId":"req-perm","retryable":false}}]')"

  run workflow_diagnose_dependency "$RUN_DIR" "$obs"
  [ "$status" -eq 0 ]
  [ "$(field "$output" '.reasonCode')" = "operator-request" ]
  [ "$(field "$output" '.nextAction.argv | join(" ")')" = "ralph workflow actions list run-fixture" ]

  run workflow_diagnose_sequential "$RUN_DIR" "$obs"
  [ "$status" -eq 0 ]
  [ "$(field "$output" '.reasonCode')" = "stage-failed" ]

  # Every other cause is identical across the two engines.
  local spec
  for spec in 'runStatus="waiting"' 'runStatus="cancelled"' \
    'runStatus="blocked"|cycle=["a"]' \
    'runStatus="blocked"|nodes=[{"id":"a","state":"failed"}]' \
    'ownerClass="stale"|runStatus="running"'; do
    IFS='|' read -r -a parts <<<"$spec"
    obs="$(observation "${parts[@]}")"
    [ "$(workflow_diagnose_dependency "$RUN_DIR" "$obs")" = \
      "$(workflow_diagnose_sequential "$RUN_DIR" "$obs")" ]
  done
}
