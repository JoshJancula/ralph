#!/usr/bin/env bash
set -euo pipefail
# Behavioral fixture for bundle/.ralph/orchestrator.sh --single-stage mode.
# Verifies that a single stage runs through the per-stage function, writes a
# StageOutcomeReport (schemaVersion 1) atomically, propagates the exit code,
# skips every other stage, and records failed/cancelled reports on failure and
# signal. Uses a stub run-plan.sh and a scratch workspace; never invokes a real
# AI CLI.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RALPH_DIR="$ROOT/bundle/.ralph"
FIXTURE_DIR="$ROOT/tests/fixtures/orchestrator-single-stage"

fail() {
  printf 'orchestrator-single-stage: %s\n' "$1" >&2
  exit 1
}

command -v jq >/dev/null 2>&1 || fail "jq is required for this test"
command -v python3 >/dev/null 2>&1 || fail "python3 is required for this test"

# Keep the artifact namespace deterministic regardless of the invoking runner.
unset RALPH_ARTIFACT_NS 2>/dev/null || true
unset RALPH_PLAN_KEY 2>/dev/null || true

tmpdir="$(mktemp -d "${TMPDIR:-/tmp}/ralph-orch-single-XXXXXX")"
trap 'rm -rf "$tmpdir"' EXIT

workspace="$tmpdir/workspace"
mkdir -p "$workspace/.ralph" "$workspace/.ralph-workspace"

cp -R "$RALPH_DIR"/* "$workspace/.ralph/"
chmod +x "$workspace/.ralph"/*.sh
chmod +x "$workspace/.ralph/bash-lib"/*/*.sh 2>/dev/null || true

cp "$FIXTURE_DIR/run-plan-stub.sh" "$workspace/.ralph/run-plan.sh"
chmod +x "$workspace/.ralph/run-plan.sh"

mkdir -p "$workspace/.ralph/agents/research"
cp "$FIXTURE_DIR/agents/research/config.json" "$workspace/.ralph/agents/research/config.json"

ns="PLAN18-single-stage"
orch_dir="$workspace/.ralph-workspace/orchestration-plans/$ns"
mkdir -p "$orch_dir"
orch_file="$orch_dir/$ns.orch.json"
cat > "$orch_file" <<ORCH
{
  "name": "$ns",
  "namespace": "$ns",
  "description": "Single-stage behavioral fixture",
  "stages": [
    {
      "id": "stage1",
      "agent": "research",
      "runtime": "cursor",
      "model": "fixture-cursor-model",
      "plan": ".ralph-workspace/orchestration-plans/$ns/$ns-01-stage1.plan.md",
      "sessionStrategy": "fresh",
      "artifacts": [
        { "path": ".ralph-workspace/artifacts/$ns/stage1.md", "required": true }
      ]
    },
    {
      "id": "stage2",
      "agent": "research",
      "runtime": "cursor",
      "model": "fixture-cursor-model",
      "plan": ".ralph-workspace/orchestration-plans/$ns/$ns-02-stage2.plan.md",
      "sessionStrategy": "fresh",
      "artifacts": [
        { "path": ".ralph-workspace/artifacts/$ns/stage2.md", "required": true }
      ]
    }
  ]
}
ORCH

mkdir -p "$workspace/.ralph-workspace/artifacts/$ns"
printf '# Stage 1\n' > "$orch_dir/$ns-01-stage1.plan.md"
printf '# Stage 2\n' > "$orch_dir/$ns-02-stage2.plan.md"

capture_dir="$tmpdir/captures"
mkdir -p "$capture_dir"

export ORCHESTRATOR_RUNNER_TO_CONSOLE=0
export RALPH_MODE=no
export RALPH_ARTIFACT_SCHEMA_VALIDATION=0
export RALPH_ARTIFACT_PROVENANCE=0

report_path() {
  local attempt="$1"
  printf '%s/.ralph-workspace/artifacts/%s/stage-outcomes/%s.json' "$workspace" "$ns" "$attempt"
}

run_single_stage() {
  # args: stageId runId attemptId ; env vars configure the stub. Echoes rc.
  local stage_id="$1" run_id="$2" attempt_id="$3"
  local rc=0
  "$workspace/.ralph/orchestrator.sh" \
    --orchestration "$orch_file" \
    --single-stage "$stage_id" --run-id "$run_id" --attempt-id "$attempt_id" \
    "$workspace" >"$tmpdir/out-$attempt_id.log" 2>"$tmpdir/err-$attempt_id.log" || rc=$?
  printf '%s' "$rc"
}

assert_no_temp_reports() {
  local dir="$workspace/.ralph-workspace/artifacts/$ns/stage-outcomes"
  [[ -d "$dir" ]] || return 0
  if ls "$dir"/.stage-outcome-* >/dev/null 2>&1; then
    fail "leftover temp report files in $dir (atomic rename not honored)"
  fi
}

# ---------------------------------------------------------------------------
# 1. Success: stage1 runs, exit 0, report outcome=success exitCode=0.
#    stage2 must NOT run (no stage2 artifact, no stage2 capture).
# ---------------------------------------------------------------------------
rm -f "$workspace/.ralph-workspace/artifacts/$ns/stage1.md" "$workspace/.ralph-workspace/artifacts/$ns/stage2.md"
export RALPH_RUN_PLAN_CAPTURE_FILE="$capture_dir/success.json"
export RUN_PLAN_STUB_EXIT_CODE=0
export RUN_PLAN_STUB_WRITE_ARTIFACTS=".ralph-workspace/artifacts/$ns/stage1.md"
unset RUN_PLAN_STUB_SLEEP_SECONDS RUN_PLAN_STUB_READY_FILE 2>/dev/null || true
rc="$(run_single_stage stage1 run-A attempt-1)"
[[ "$rc" -eq 0 ]] || { cat "$tmpdir/err-attempt-1.log" >&2; fail "success run should exit 0, got $rc"; }
[[ -f "$(report_path attempt-1)" ]] || fail "success report missing"
[[ -f "$capture_dir/success.json" ]] || fail "stage1 stub capture missing"
[[ ! -f "$workspace/.ralph-workspace/artifacts/$ns/stage2.md" ]] || fail "stage2 must not run in single-stage mode"
assert_no_temp_reports
python3 - "$(report_path attempt-1)" "$capture_dir/success.json" <<'PY'
import json, sys
report = json.load(open(sys.argv[1]))
assert report["schemaVersion"] == 1, report
assert report["runId"] == "run-A", report
assert report["stageId"] == "stage1", report
assert report["attemptId"] == "attempt-1", report
assert report["outcome"] == "success", report
assert report["exitCode"] == 0, report
assert isinstance(report["startedAt"], str) and report["startedAt"], report
assert isinstance(report["finishedAt"], str) and report["finishedAt"], report
assert report["finishedAt"] >= report["startedAt"], report
cap = json.load(open(sys.argv[2]))
assert cap["env"].get("RALPH_STAGE_ID") == "stage1", cap["env"]
print("success + no-other-stage + atomic report OK")
PY

# ---------------------------------------------------------------------------
# 2. Runner failure: stub exits 7 -> orchestrator exits 7, report failed/7.
# ---------------------------------------------------------------------------
rm -f "$workspace/.ralph-workspace/artifacts/$ns/stage1.md"
export RALPH_RUN_PLAN_CAPTURE_FILE="$capture_dir/fail.json"
export RUN_PLAN_STUB_EXIT_CODE=7
export RUN_PLAN_STUB_WRITE_ARTIFACTS=""
rc="$(run_single_stage stage1 run-B attempt-2)"
[[ "$rc" -eq 7 ]] || { cat "$tmpdir/err-attempt-2.log" >&2; fail "runner failure should exit 7, got $rc"; }
[[ -f "$(report_path attempt-2)" ]] || fail "runner failure report missing"
assert_no_temp_reports
python3 - "$(report_path attempt-2)" <<'PY'
import json, sys
r = json.load(open(sys.argv[1]))
assert r["outcome"] == "failed", r
assert r["exitCode"] == 7, r
assert r["attemptId"] == "attempt-2", r
print("runner failure report OK")
PY

# ---------------------------------------------------------------------------
# 3. Missing required artifact: stub exits 0 but writes nothing -> exit 1,
#    report failed/1.
# ---------------------------------------------------------------------------
rm -f "$workspace/.ralph-workspace/artifacts/$ns/stage1.md"
export RALPH_RUN_PLAN_CAPTURE_FILE="$capture_dir/missing.json"
export RUN_PLAN_STUB_EXIT_CODE=0
export RUN_PLAN_STUB_WRITE_ARTIFACTS=""
rc="$(run_single_stage stage1 run-C attempt-3)"
[[ "$rc" -eq 1 ]] || { cat "$tmpdir/err-attempt-3.log" >&2; fail "missing artifact should exit 1, got $rc"; }
[[ -f "$(report_path attempt-3)" ]] || fail "missing artifact report missing"
assert_no_temp_reports
python3 - "$(report_path attempt-3)" <<'PY'
import json, sys
r = json.load(open(sys.argv[1]))
assert r["outcome"] == "failed", r
assert r["exitCode"] == 1, r
print("missing artifact report OK")
PY

# ---------------------------------------------------------------------------
# 4. Unknown stage id -> exit 1, report failed with a reason.
# ---------------------------------------------------------------------------
export RALPH_RUN_PLAN_CAPTURE_FILE="$capture_dir/unknown.json"
export RUN_PLAN_STUB_EXIT_CODE=0
export RUN_PLAN_STUB_WRITE_ARTIFACTS=""
rc="$(run_single_stage does-not-exist run-D attempt-4)"
[[ "$rc" -eq 1 ]] || { cat "$tmpdir/err-attempt-4.log" >&2; fail "unknown stage should exit 1, got $rc"; }
[[ ! -f "$capture_dir/unknown.json" ]] || fail "unknown stage must not invoke the runner"
[[ -f "$(report_path attempt-4)" ]] || fail "unknown stage report missing"
python3 - "$(report_path attempt-4)" <<'PY'
import json, sys
r = json.load(open(sys.argv[1]))
assert r["outcome"] == "failed", r
assert r["exitCode"] == 1, r
assert r.get("reason"), r
assert "does-not-exist" in r["reason"], r
print("unknown stage report OK")
PY

# ---------------------------------------------------------------------------
# 5. Signal: stub sleeps; deliver SIGTERM mid-run -> non-zero exit and a
#    cancelled report.
# ---------------------------------------------------------------------------
rm -f "$workspace/.ralph-workspace/artifacts/$ns/stage1.md"
ready_file="$tmpdir/stub-ready"
rm -f "$ready_file"
export RALPH_RUN_PLAN_CAPTURE_FILE="$capture_dir/signal.json"
export RUN_PLAN_STUB_EXIT_CODE=0
export RUN_PLAN_STUB_WRITE_ARTIFACTS=".ralph-workspace/artifacts/$ns/stage1.md"
export RUN_PLAN_STUB_SLEEP_SECONDS=30
export RUN_PLAN_STUB_READY_FILE="$ready_file"
"$workspace/.ralph/orchestrator.sh" \
  --orchestration "$orch_file" \
  --single-stage stage1 --run-id run-E --attempt-id attempt-5 \
  "$workspace" >"$tmpdir/out-attempt-5.log" 2>"$tmpdir/err-attempt-5.log" &
orch_pid=$!
# Wait until the stub signals readiness (runner is now "running").
for _ in $(seq 1 100); do
  [[ -f "$ready_file" ]] && break
  sleep 0.1
done
[[ -f "$ready_file" ]] || fail "stub never became ready for signal test"
kill -TERM "$orch_pid" 2>/dev/null || true
sig_rc=0
wait "$orch_pid" || sig_rc=$?
unset RUN_PLAN_STUB_SLEEP_SECONDS RUN_PLAN_STUB_READY_FILE
[[ "$sig_rc" -ne 0 ]] || fail "signal run should exit non-zero, got $sig_rc"
# Give the EXIT trap a brief moment; the report should already be present.
for _ in $(seq 1 50); do
  [[ -f "$(report_path attempt-5)" ]] && break
  sleep 0.1
done
[[ -f "$(report_path attempt-5)" ]] || fail "cancelled report missing after signal"
assert_no_temp_reports
python3 - "$(report_path attempt-5)" <<'PY'
import json, sys
r = json.load(open(sys.argv[1]))
assert r["outcome"] == "cancelled", r
assert r["exitCode"] != 0, r
assert r["attemptId"] == "attempt-5", r
print("signal (cancelled) report OK")
PY

printf 'orchestrator-single-stage test passed\n'
