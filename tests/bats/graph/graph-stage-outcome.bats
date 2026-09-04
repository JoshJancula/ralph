#!/usr/bin/env bats
# G10/G11: StageOutcomeReport outcome-envelope tests.
#
# Unit-level: graph_failure_classify_v2 (the pure G10/G11 normalizer) for
# each of the six required evidence categories: artifact, scope, timeout,
# permission, cancellation, and unknown exits.
#
# Vertical: the real orchestrator.sh binary, invoked as a subprocess in
# --single-stage mode, writing an actual on-disk StageOutcomeReport through
# the real orch_single_stage_write_report / orch_exit_trap code path (never
# a stub), for the unknown-exit and cancellation categories.

source "$BATS_TEST_DIRNAME/../helper/load-lib.bash"
source "$BATS_TEST_DIRNAME/../../../bundle/.ralph/bash-lib/graph/graph-failure-classify.sh"

ORCHESTRATOR_SH="$BATS_TEST_DIRNAME/../../../bundle/.ralph/orchestrator.sh"

# ---------------------------------------------------------------------------
# Unit tests: graph_failure_classify_v2 (pure).
# ---------------------------------------------------------------------------

@test "normalizer classifies artifact evidence as agent-correctable/required-artifact-missing" {
  run graph_failure_classify_v2 '{"missingArtifacts":[".ralph-workspace/artifacts/ns/out.md"]}'
  [ "$status" -eq 0 ]
  [ "$(jq -r '.classification' <<<"$output")" = "agent-correctable" ]
  [ "$(jq -r '.cause' <<<"$output")" = "required-artifact-missing" ]
  [ "$(jq -r '.source' <<<"$output")" = "orchestrator" ]
  [ "$(jq -c '.missingArtifacts' <<<"$output")" = '[".ralph-workspace/artifacts/ns/out.md"]' ]
  [ "$(jq -r '.retryable' <<<"$output")" = "true" ]
}

@test "normalizer classifies scope evidence as plan-contract/write-scope" {
  run graph_failure_classify_v2 '{"offendingPaths":["src/outside-scope.txt"]}'
  [ "$status" -eq 0 ]
  [ "$(jq -r '.classification' <<<"$output")" = "plan-contract" ]
  [ "$(jq -r '.cause' <<<"$output")" = "write-scope" ]
  [ "$(jq -r '.source' <<<"$output")" = "changeset" ]
  [ "$(jq -c '.offendingPaths' <<<"$output")" = '["src/outside-scope.txt"]' ]
  [ "$(jq -r '.operatorAction' <<<"$output")" = "repair-plan" ]
}

@test "normalizer keeps supervisor write-scope rejection in plan-contract" {
  run graph_failure_classify_v2 \
    '{"exitCode":1,"reason":"ERROR: graph write-scope verification failed before TODO completion: build-1; docs/invalid.txt"}'
  [ "$status" -eq 0 ]
  [ "$(jq -r '.classification' <<<"$output")" = "plan-contract" ]
  [ "$(jq -r '.cause' <<<"$output")" = "write-scope" ]
  [[ "$(jq -r '.summary' <<<"$output")" == *"docs/invalid.txt"* ]]
}

@test "normalizer classifies timeout marker and preserves owner seconds and signal" {
  run graph_failure_classify_v2 '{"timeoutMarker":{"owner":"run-plan","seconds":30,"signal":"TERM"}}'
  [ "$status" -eq 0 ]
  [ "$(jq -r '.classification' <<<"$output")" = "transient-runtime" ]
  [ "$(jq -r '.cause' <<<"$output")" = "invocation-timeout" ]
  [ "$(jq -r '.source' <<<"$output")" = "run-plan" ]
  [ "$(jq -r '.timeout.owner' <<<"$output")" = "run-plan" ]
  [ "$(jq -r '.timeout.seconds' <<<"$output")" = "30" ]
  [ "$(jq -r '.timeout.signal' <<<"$output")" = "TERM" ]
  [ "$(jq -r '.retryable' <<<"$output")" = "true" ]
}

@test "normalizer classifies a proved native permission event and carries the request" {
  run graph_failure_classify_v2 '{"nativePermission":{"tool":"bash","action":"execute","resource":"npm test","effect":"write","proved":true}}'
  [ "$status" -eq 0 ]
  [ "$(jq -r '.classification' <<<"$output")" = "operator-permission" ]
  [ "$(jq -r '.cause' <<<"$output")" = "native-permission" ]
  [ "$(jq -r '.source' <<<"$output")" = "runtime-adapter" ]
  [ "$(jq -r '.permissionRequest.tool' <<<"$output")" = "bash" ]
  [ "$(jq -r '.permissionRequest.resource' <<<"$output")" = "npm test" ]
  [ "$(jq -r '.operatorAction' <<<"$output")" = "await-operator" ]
}

@test "normalizer does not create a permission request from exit code 4 alone" {
  run graph_failure_classify_v2 '{"exitCode":4,"nativePermission":{"tool":"","action":"","resource":"","effect":"","proved":false}}'
  [ "$status" -eq 0 ]
  [ "$(jq -r '.classification' <<<"$output")" != "operator-permission" ]
  [ "$(jq -r '.classification' <<<"$output")" = "unknown" ]

  run graph_failure_classify_v2 '{"exitCode":143}'
  [ "$status" -eq 0 ]
  # 143 alone maps to the supervisor-signal exit-code tier (G11 tier 6), not
  # to permission -- exit code 4 or 143 alone never creates a permission
  # request.
  [ "$(jq -r '.classification' <<<"$output")" != "operator-permission" ]
}

@test "normalizer distinguishes operator cancellation from a supervisor signal" {
  run graph_failure_classify_v2 '{"cancelMarker":{"owner":"scheduler","signal":"INT"}}'
  [ "$status" -eq 0 ]
  [ "$(jq -r '.classification' <<<"$output")" = "cancelled" ]
  [ "$(jq -r '.cause' <<<"$output")" = "supervisor-signal" ]

  run graph_failure_classify_v2 '{"cancelMarker":{"owner":"scheduler","operator":true}}'
  [ "$status" -eq 0 ]
  [ "$(jq -r '.classification' <<<"$output")" = "cancelled" ]
  [ "$(jq -r '.cause' <<<"$output")" = "operator-cancel" ]
  [ "$(jq -r '.retryable' <<<"$output")" = "false" ]
}

@test "normalizer classifies absent evidence as unknown" {
  run graph_failure_classify_v2 '{}'
  [ "$status" -eq 0 ]
  [ "$(jq -r '.classification' <<<"$output")" = "unknown" ]
  [ "$(jq -r '.cause' <<<"$output")" = "unknown" ]
  [ "$(jq -r '.missingArtifacts | length' <<<"$output")" -eq 0 ]
  [ "$(jq -r '.offendingPaths | length' <<<"$output")" -eq 0 ]
  [ "$(jq -r '.verification' <<<"$output")" = "unknown" ]

  # An empty/unrecognized exit code alone (no tier 1-5 evidence, no text
  # text match) also lands on unknown rather than inventing a class.
  run graph_failure_classify_v2 '{"exitCode":7,"reason":"agent process exited"}'
  [ "$status" -eq 0 ]
  [ "$(jq -r '.classification' <<<"$output")" = "unknown" ]
}

# ---------------------------------------------------------------------------
# Vertical scenario: the real orchestrator.sh subprocess.
# ---------------------------------------------------------------------------

_gse_write_stage_fixture() {
  TMPD="$(mktemp -d)"
  WS="$TMPD/workspace"
  mkdir -p "$WS/.ralph-workspace" "$WS/src"
  ORCH_JSON="$TMPD/test.orch.json"
}

_gse_run_orchestrator() {
  # Positional: $@ passed straight to orchestrator.sh.
  RALPH_ACTIVE_DIR="$BATS_TEST_DIRNAME/../../../bundle/.ralph" \
    RALPH_ALLOW_NESTED_RUNS=1 \
    RALPH_PLAN_CLI_RESUME=0 \
    RALPH_PLAN_AGENT_POLL_INTERVAL=0.1 \
    bash "$ORCHESTRATOR_SH" "$@"
}

@test "vertical scenario writes an unknown StageOutcomeReport for an unknown stage" {
  _gse_write_stage_fixture
  echo '{"stages":[]}' >"$ORCH_JSON"

  run _gse_run_orchestrator --orchestration "$ORCH_JSON" --single-stage nope \
    --run-id run1 --attempt-id attempt1 --workspace-root "$WS/.ralph-workspace" "$WS"
  [ "$status" -ne 0 ]

  report="$WS/.ralph-workspace/artifacts/test.orch/stage-outcomes/attempt1.json"
  [ -f "$report" ]
  [ "$(jq -r '.schemaVersion' "$report")" = "2" ]
  [ "$(jq -r '.outcome' "$report")" = "failed" ]
  [ "$(jq -r '.exitCode' "$report")" = "1" ]
  [ "$(jq -r '.reason' "$report")" = "unknown stage id: nope" ]
  [ "$(jq -r '.failure.classification' "$report")" = "unknown" ]
  [ "$(jq -r '.failure.cause' "$report")" = "unknown" ]
  [ "$(jq -r '.failure.summary' "$report")" = "unknown stage id: nope" ]

  chmod -R u+w "$TMPD" 2>/dev/null || true
  rm -rf "$TMPD"
}

@test "vertical scenario records SIGTERM as cancelled by the supervisor" {
  _gse_write_stage_fixture

  bin="$TMPD/bin"
  mkdir -p "$bin"
  cat >"$bin/cursor-agent" <<'CLI'
#!/usr/bin/env bash
case "$1" in
  --help)
    printf '%s\n' "Usage: cursor-agent" "  --permission-prompt-tool <name>"
    exit 0
    ;;
esac
sleep 20
echo "TODO_COMPLETION: COMPLETE"
exit 0
CLI
  chmod +x "$bin/cursor-agent"

  mkdir -p "$WS/.cursor/agents/alpha"
  # Pretty-printed (one key per line): the agent-config validator greps for
  # each required key anchored at line start; compact single-line JSON
  # fails validation even though it is syntactically valid.
  cat >"$WS/.cursor/agents/alpha/config.json" <<'CONFIG'
{
  "name": "alpha",
  "model": "auto",
  "description": "cancellation vertical scenario agent",
  "rules": [],
  "skills": []
}
CONFIG

  plan="$WS/stage.plan.md"
  cat >"$plan" <<'PLAN'
---
name: cancel-stage
overview: slow stage
execution: standard
instructions: Execute one TODO at a time.

todos:
  - id: t1
    content: |
      do a slow thing
    verification: |

    status: pending
isProject: false
---
PLAN

  jq -n --arg plan "$plan" '{stages: [{id: "slow", runtime: "cursor", plan: $plan}]}' >"$ORCH_JSON"

  (
    PATH="$bin:$PATH" \
      RALPH_ACTIVE_DIR="$BATS_TEST_DIRNAME/../../../bundle/.ralph" \
      RALPH_ALLOW_NESTED_RUNS=1 \
      RALPH_PLAN_CLI_RESUME=0 \
      RALPH_PLAN_AGENT_POLL_INTERVAL=0.1 \
      CURSOR_PLAN_MODEL=auto \
      bash "$ORCHESTRATOR_SH" --orchestration "$ORCH_JSON" --single-stage slow \
      --run-id run1 --attempt-id attempt1 --workspace-root "$WS/.ralph-workspace" "$WS" \
      >"$TMPD/orch.log" 2>&1 &
    echo $! >"$TMPD/orch.pid"
  )

  # Wait for the stub runtime to actually be running before signalling: a fixed
  # sleep raced supervisor startup and TERMed before the stage began, so no
  # outcome report was ever written.
  # These deadlines guard against a wedge (a stage that never starts, a report
  # never written), not against slowness. 30s did not survive the suite: files
  # run in parallel and each forks dozens of children, so orchestrator plus
  # run-plan startup alone can exceed it -- a neighbouring state-write test was
  # measured at 33s in the same run. A wedge still fails, because it never
  # satisfies the condition at all.
  local deadline
  deadline=$(( $(date +%s) + 120 ))
  until pgrep -f "$bin/cursor-agent" >/dev/null 2>&1; do
    [[ $(date +%s) -lt $deadline ]] || {
      echo "timed out waiting for the stub runtime to start" >&2
      cat "$TMPD/orch.log" >&2 2>/dev/null || true
      return 1
    }
    sleep 0.05
  done

  orch_pid="$(cat "$TMPD/orch.pid")"
  kill -TERM "$orch_pid" 2>/dev/null || true

  report="$WS/.ralph-workspace/artifacts/test.orch/stage-outcomes/attempt1.json"
  deadline=$(( $(date +%s) + 120 ))
  until [[ -f "$report" ]]; do
    [[ $(date +%s) -lt $deadline ]] || {
      echo "timed out waiting for $report" >&2
      cat "$TMPD/orch.log" >&2 2>/dev/null || true
      break
    }
    sleep 0.05
  done
  pkill -9 -f "$bin/cursor-agent" 2>/dev/null || true

  [ -f "$report" ]
  [ "$(jq -r '.schemaVersion' "$report")" = "2" ]
  [ "$(jq -r '.outcome' "$report")" = "cancelled" ]
  [ "$(jq -r '.exitCode' "$report")" = "143" ]
  [ "$(jq -r '.reason' "$report")" = "received signal TERM" ]
  [ "$(jq -r '.failure.classification' "$report")" = "cancelled" ]
  [ "$(jq -r '.failure.cause' "$report")" = "supervisor-signal" ]
  [ "$(jq -r '.failure.source' "$report")" = "orchestrator" ]
  [ "$(jq -r '.failure.retryable' "$report")" = "false" ]

  chmod -R u+w "$TMPD" 2>/dev/null || true
  rm -rf "$TMPD"
}
