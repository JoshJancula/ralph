#!/usr/bin/env bats
source "$BATS_TEST_DIRNAME/../helper/load-lib.bash"
STATE_CLI="$REPO_ROOT/bundle/.ralph/bash-lib/state-cli.sh"
FIXTURE_GENERATOR="$REPO_ROOT/tests/fixtures/state-layout/generate-fixtures.sh"

setup() {
  fixture_root="$(mktemp -d)"
  bash "$FIXTURE_GENERATOR" "$fixture_root"
}

teardown() { rm -rf "$fixture_root"; }

@test "state status works on an empty workspace" {
  local d
  d="$(mktemp -d)"
  run bash -c 'cd "$1" && RALPH_PLAN_WORKSPACE_ROOT="$1/.ralph-workspace" bash "$2" status' _ "$d" "$STATE_CLI"
  [ "$status" -eq 0 ]
  rm -rf "$d"
}

@test "state prune dry-run does not delete files and runs list manifest plus legacy" {
  local d before after
  d="$(mktemp -d)"
  mkdir -p "$d/.ralph-workspace/logs/a/runs/r1" "$d/.ralph-workspace/logs/b"
  printf '{"run_id":"r1","plan_key":"a","status":"done"}\n' >"$d/.ralph-workspace/logs/a/runs/r1/run-manifest.json"
  printf '{"plan_key":"b"}\n' >"$d/.ralph-workspace/logs/b/plan-usage-summary.json"
  before="$(find "$d" -type f | wc -l)"
  run env RALPH_PLAN_WORKSPACE_ROOT="$d/.ralph-workspace" bash "$STATE_CLI" runs
  [ "$status" -eq 0 ]
  [[ "$output" == *r1* && "$output" == *legacy* ]]
  run env RALPH_PLAN_WORKSPACE_ROOT="$d/.ralph-workspace" bash "$STATE_CLI" prune --dry-run
  [ "$status" -eq 0 ]
  after="$(find "$d" -type f | wc -l)"
  [ "$before" -eq "$after" ]
  rm -rf "$d"
}

@test "state orphans reports unclassified paths on v1 fixture and is read-only" {
  local before after
  before="$(find "$fixture_root/v1" -type f | wc -l | tr -d ' ')"
  run env RALPH_PLAN_WORKSPACE_ROOT="$fixture_root/v1" bash "$STATE_CLI" orphans
  [ "$status" -eq 0 ]
  [[ "$output" == *$'\tmystery\t'* || "$output" == *"mystery"$'\t'* ]]
  [[ "$output" == *"unclassified"* ]]
  [[ "$output" == *"never eligible"* ]]
  after="$(find "$fixture_root/v1" -type f | wc -l | tr -d ' ')"
  [ "$before" -eq "$after" ]
}

@test "state orphans reports unclassified paths on mixed fixture" {
  run env RALPH_PLAN_WORKSPACE_ROOT="$fixture_root/mixed" bash "$STATE_CLI" orphans
  [ "$status" -eq 0 ]
  [[ "$output" == *"odd"$'\t'* ]]
  [[ "$output" == *"unclassified"* ]]
}

@test "state orphans --json lists unclassified paths" {
  command -v jq >/dev/null 2>&1 || skip "jq unavailable"
  run env RALPH_PLAN_WORKSPACE_ROOT="$fixture_root/v1" bash "$STATE_CLI" orphans --json
  [ "$status" -eq 0 ]
  [[ "$(printf '%s' "$output" | jq -r '.orphans[] | select(.path=="mystery") | .reason')" == "unclassified" ]]
}

@test "state prune preview on fixture roots is read-only and never lists orphans" {
  local before after
  before="$(find "$fixture_root" -type f | wc -l | tr -d ' ')"
  run env RALPH_PLAN_WORKSPACE_ROOT="$fixture_root/v1" bash "$STATE_CLI" prune
  [ "$status" -eq 0 ]
  [[ "$output" == *"total"* ]]
  [[ "$output" != *"mystery"* ]]
  run env RALPH_PLAN_WORKSPACE_ROOT="$fixture_root/mixed" bash "$STATE_CLI" prune
  [ "$status" -eq 0 ]
  [[ "$output" != *"odd"* ]]
  after="$(find "$fixture_root" -type f | wc -l | tr -d ' ')"
  [ "$before" -eq "$after" ]
}

@test "state prune preview lists eligible aged plan-run with reason and bytes" {
  command -v jq >/dev/null 2>&1 || skip "jq unavailable"
  local root="$fixture_root/v1" run_dir
  run_dir="$root/logs/demo/runs/old-eligible"
  mkdir -p "$run_dir"
  printf '{"kind":"ralph_run_manifest","status":"complete","run_id":"old-eligible","plan_key":"demo"}\n' \
    >"$run_dir/run-manifest.json"
  printf 'payload\n' >"$run_dir/output.log"
  touch -t 202001010000 "$run_dir"
  run env \
    RALPH_PLAN_WORKSPACE_ROOT="$root" \
    RALPH_RETENTION_LOG_RUNS_MAX_AGE_DAYS=1 \
    RALPH_RETENTION_LOG_RUNS_MAX_COUNT=100 \
    bash "$STATE_CLI" prune
  [ "$status" -eq 0 ]
  [[ "$output" == *"old-eligible"* ]]
  [[ "$output" == *"plan-run"* ]]
  [[ "$output" == *"eligible"* ]]
  [[ "$output" == *"bytes"* ]]
  [[ "$output" == *"total"* ]]
}

@test "state prune --json preview includes candidates and totalBytes" {
  command -v jq >/dev/null 2>&1 || skip "jq unavailable"
  local root="$fixture_root/v1" run_dir
  run_dir="$root/logs/demo/runs/old-json"
  mkdir -p "$run_dir"
  printf '{"kind":"ralph_run_manifest","status":"complete","run_id":"old-json","plan_key":"demo"}\n' \
    >"$run_dir/run-manifest.json"
  touch -t 202001010000 "$run_dir"
  run env \
    RALPH_PLAN_WORKSPACE_ROOT="$root" \
    RALPH_RETENTION_LOG_RUNS_MAX_AGE_DAYS=1 \
    RALPH_RETENTION_LOG_RUNS_MAX_COUNT=100 \
    bash "$STATE_CLI" prune --json
  [ "$status" -eq 0 ]
  [[ "$(printf '%s' "$output" | jq -r '.mode')" == "preview" ]]
  [[ "$(printf '%s' "$output" | jq -r '[.candidates[].path] | map(select(contains("old-json"))) | length')" -ge 1 ]]
  [[ "$(printf '%s' "$output" | jq -r '.candidates[] | select(.path|contains("old-json")) | .reason')" == "eligible" ]]
}

@test "state prune --apply removes eligible path and writes layout-1 receipt" {
  command -v jq >/dev/null 2>&1 || skip "jq unavailable"
  local root="$fixture_root/v1" run_dir receipt
  run_dir="$root/logs/demo/runs/apply-keep"
  mkdir -p "$run_dir"
  printf '{"kind":"ralph_run_manifest","status":"complete","run_id":"apply-keep","plan_key":"demo"}\n' \
    >"$run_dir/run-manifest.json"
  touch -t 202001010000 "$run_dir"
  run env \
    RALPH_PLAN_WORKSPACE_ROOT="$root" \
    RALPH_STATE_LAYOUT=1 \
    RALPH_RETENTION_LOG_RUNS_MAX_AGE_DAYS=1 \
    RALPH_RETENTION_LOG_RUNS_MAX_COUNT=100 \
    bash "$STATE_CLI" prune --apply --json
  [ "$status" -eq 0 ]
  [ ! -d "$run_dir" ]
  [[ "$(printf '%s' "$output" | jq -r '.mode')" == "apply" ]]
  [[ "$(printf '%s' "$output" | jq -r '[.removed[].path] | map(select(contains("apply-keep"))) | length')" -ge 1 ]]
  receipt="$(printf '%s' "$output" | jq -r '.receipt // empty')"
  [ -n "$receipt" ]
  [[ "$receipt" == *"/logs/cleanup-receipts/"* ]]
  [ -f "$receipt" ]
  [[ "$(jq -r '.kind' "$receipt")" == "ralph_cleanup_receipt" ]]
  [[ "$(jq -r '.removed | length' "$receipt")" -ge 1 ]]
}

@test "state prune --apply writes layout-2 receipt under internal/cleanup-receipts" {
  command -v jq >/dev/null 2>&1 || skip "jq unavailable"
  local root="$fixture_root/mixed" run_dir receipt
  # Layout-2 runs are pruned as whole runs/<run-id>/ subtrees.
  run_dir="$root/runs/old-l2"
  mkdir -p "$run_dir/stages/plan/attempts/old-l2"
  printf '{"kind":"ralph_run_catalog","layoutVersion":2,"runKind":"plan","runId":"old-l2","status":"complete"}\n' \
    >"$run_dir/run.json"
  printf '{"kind":"ralph_run_manifest","status":"complete","run_id":"old-l2","plan_key":"demo"}\n' \
    >"$run_dir/stages/plan/attempts/old-l2/run-manifest.json"
  touch -t 202001010000 "$run_dir"
  run env \
    RALPH_PLAN_WORKSPACE_ROOT="$root" \
    RALPH_STATE_LAYOUT=2 \
    RALPH_RETENTION_LOG_RUNS_MAX_AGE_DAYS=1 \
    RALPH_RETENTION_LOG_RUNS_MAX_COUNT=100 \
    bash "$STATE_CLI" prune --apply --json
  [ "$status" -eq 0 ]
  [ ! -d "$run_dir" ]
  [[ "$(printf '%s' "$output" | jq -r '.mode')" == "apply" ]]
  receipt="$(printf '%s' "$output" | jq -r '.receipt // empty')"
  [ -n "$receipt" ]
  [[ "$receipt" == *"/internal/cleanup-receipts/"* ]]
  [ -f "$receipt" ]
  [[ "$(jq -r '.removed[] | select(.path|contains("old-l2")) | .kind' "$receipt")" == "run" ]]
}

@test "state prune --apply reports skipped when eligibility changes before removal" {
  command -v jq >/dev/null 2>&1 || skip "jq unavailable"
  local root="$fixture_root/v1" flip_dir
  flip_dir="$root/logs/demo/runs/skip-flip"
  mkdir -p "$flip_dir"
  printf '{"kind":"ralph_run_manifest","status":"complete","run_id":"skip-flip","plan_key":"demo"}\n' \
    >"$flip_dir/run-manifest.json"
  touch -t 202001010000 "$flip_dir"
  run env \
    RALPH_PLAN_WORKSPACE_ROOT="$root" \
    RALPH_STATE_LAYOUT=1 \
    RALPH_RETENTION_LOG_RUNS_MAX_AGE_DAYS=1 \
    RALPH_RETENTION_LOG_RUNS_MAX_COUNT=100 \
    bash -c '
      set -euo pipefail
      STATE_CLI="$1"; root="$2"; flip="$3"
      # shellcheck disable=SC1090
      source "$STATE_CLI"
      ralph_state_ensure_retention
      eval "ralph_retention_eligibility_orig() $(declare -f ralph_retention_eligibility | tail -n +2)"
      # Collect runs in a process-substitution subshell; use a file counter so
      # the apply re-check sees the prior eligible sightings.
      call_file="$(mktemp)"
      printf "0\n" >"$call_file"
      ralph_retention_eligibility() {
        local out n
        out="$(ralph_retention_eligibility_orig "$@" || true)"
        if [[ "${3:-}" == "$flip" && "$out" == "eligible" ]]; then
          n="$(cat "$call_file")"
          n=$((n + 1))
          printf "%s\n" "$n" >"$call_file"
          if [[ "$n" -ge 2 ]]; then
            printf "{\"kind\":\"ralph_run_manifest\",\"status\":\"running\",\"run_id\":\"skip-flip\",\"plan_key\":\"demo\"}\n" \
              >"$flip/run-manifest.json"
            out="$(ralph_retention_eligibility_orig "$@" || true)"
          fi
        fi
        printf "%s\n" "$out"
        [[ "$out" == "eligible" ]]
      }
      ralph_state_prune "$root" --apply --json
      rm -f "$call_file"
    ' _ "$STATE_CLI" "$root" "$flip_dir"
  [ "$status" -eq 0 ]
  [ -d "$flip_dir" ]
  [[ "$(printf '%s' "$output" | jq -r '.skipped | length')" -ge 1 ]]
  [[ "$(printf '%s' "$output" | jq -r '.skipped[0].previousReason')" == "eligible" ]]
  [[ "$(printf '%s' "$output" | jq -r '.skipped[0].reason')" == "nonterminal-plan-run" ]]
  [[ "$(printf '%s' "$output" | jq -r '.removed | length')" -eq 0 ]]
  local receipt
  receipt="$(printf '%s' "$output" | jq -r '.receipt')"
  [[ "$receipt" == *"/logs/cleanup-receipts/"* ]]
  [[ "$(jq -r '.skipped | length' "$receipt")" -ge 1 ]]
}

@test "state rejects unknown commands" {
  run bash "$STATE_CLI" nope
  [ "$status" -ne 0 ]
}

@test "state runs reports exact and degraded resume counts" {
  command -v jq >/dev/null 2>&1 || skip "jq unavailable"
  local d plan_key="a" run_id="r1"
  d="$(mktemp -d)"
  mkdir -p "$d/.ralph-workspace/logs/$plan_key/runs/$run_id" "$d/.ralph-workspace/sessions/$plan_key/todo-sessions"
  printf '%s\n' "- [ ] Keep this todo" >"$d/plan.md"
  printf '%s\n' '{"run_id":"r1","plan_key":"a","status":"done","plan_path":"'"$d"'/plan.md"}' \
    >"$d/.ralph-workspace/logs/$plan_key/runs/$run_id/run-manifest.json"
  local keep_hash
  keep_hash="$(python3 -c 'import hashlib,sys; print(hashlib.sha256(sys.argv[1].encode("utf-8")).hexdigest())' "Keep this todo")"
  printf '%s\n' "{\"schema_version\":1,\"manifest_key\":\"keep\",\"state\":\"active\",\"runtime\":\"cursor\",\"session_id\":\"s1\",\"capture\":\"exact\",\"identity\":{\"runId\":\"r1\",\"todoId\":\"keep\",\"todoHash\":\"$keep_hash\"},\"created_at\":\"t\",\"updated_at\":\"t\"}" \
    >"$d/.ralph-workspace/sessions/$plan_key/todo-sessions/keep.json"
  printf '%s\n' '{"schema_version":1,"manifest_key":"deg","state":"active","runtime":"cursor","session_id":"s2","capture":"degraded","identity":{"runId":"r1","todoId":"deg","todoHash":"other"},"created_at":"t","updated_at":"t"}' \
    >"$d/.ralph-workspace/sessions/$plan_key/todo-sessions/deg.json"
  run env RALPH_PLAN_WORKSPACE_ROOT="$d/.ralph-workspace" bash "$STATE_CLI" runs --plan a
  [ "$status" -eq 0 ]
  [[ "$output" == *"exact=1"* ]]
  [[ "$output" == *"degraded=1"* ]]
  [[ "$output" == *"hashes_match=no"* ]]
  rm -rf "$d"
}

@test "state show reports mismatched-todo-hash when plan text changed" {
  command -v jq >/dev/null 2>&1 || skip "jq unavailable"
  local d plan_key="a" run_id="r1"
  d="$(mktemp -d)"
  mkdir -p "$d/.ralph-workspace/logs/$plan_key/runs/$run_id" "$d/.ralph-workspace/sessions/$plan_key/todo-sessions"
  printf '%s\n' "- [ ] New todo text" >"$d/plan.md"
  printf '%s\n' '{"run_id":"r1","plan_key":"a","status":"done","plan_path":"'"$d"'/plan.md"}' \
    >"$d/.ralph-workspace/logs/$plan_key/runs/$run_id/run-manifest.json"
  printf '%s\n' '{"schema_version":1,"manifest_key":"keep","state":"active","runtime":"cursor","session_id":"s1","capture":"exact","identity":{"runId":"r1","todoId":"keep","todoHash":"stale-hash"},"created_at":"t","updated_at":"t"}' \
    >"$d/.ralph-workspace/sessions/$plan_key/todo-sessions/keep.json"
  run env RALPH_PLAN_WORKSPACE_ROOT="$d/.ralph-workspace" bash "$STATE_CLI" show r1
  [ "$status" -eq 0 ]
  [[ "$output" == *"mismatched-todo-hash"* ]]
  rm -rf "$d"
}

@test "state runs lists plan workflow and graph from v1 fixture with children grouped" {
  command -v jq >/dev/null 2>&1 || skip "jq unavailable"
  run env RALPH_PLAN_WORKSPACE_ROOT="$fixture_root/v1" bash "$STATE_CLI" runs
  [ "$status" -eq 0 ]
  [[ "$output" == *$'\twf-1\tworkflow\t'* ]] || [[ "$output" == *"wf-1"$'\t'"workflow"$'\t'* ]]
  [[ "$output" == *"graph-1"$'\t'"graph"$'\t'* ]]
  [[ "$output" == *"plan-1"$'\t'"plan"$'\t'* ]]
  [[ "$output" == *"child-1"$'\t'"plan"$'\t'* ]]
  [[ "$output" == *"parent=wf-1"* ]]
  [[ "$output" == *"legacy"* ]]
  # Child appears after its outer workflow row.
  local wf_line child_line
  wf_line="$(printf '%s\n' "$output" | grep -n $'^wf-1\t' | head -n1 | cut -d: -f1)"
  child_line="$(printf '%s\n' "$output" | grep -n $'^child-1\t' | head -n1 | cut -d: -f1)"
  [ -n "$wf_line" ] && [ -n "$child_line" ]
  [ "$child_line" -gt "$wf_line" ]
}

@test "state runs lists layout-2 workflow with child attempt under outer run" {
  command -v jq >/dev/null 2>&1 || skip "jq unavailable"
  run env RALPH_PLAN_WORKSPACE_ROOT="$fixture_root/mixed" bash "$STATE_CLI" runs
  [ "$status" -eq 0 ]
  [[ "$output" == *"run-2"$'\t'"workflow"$'\t'* ]]
  [[ "$output" == *"child-2"$'\t'"plan"$'\t'* ]]
  [[ "$output" == *"parent=run-2"* ]]
  [[ "$output" == *"evidence=ok"* ]]
  local outer_line child_line
  outer_line="$(printf '%s\n' "$output" | grep -n $'^run-2\t' | head -n1 | cut -d: -f1)"
  child_line="$(printf '%s\n' "$output" | grep -n $'^child-2\t' | head -n1 | cut -d: -f1)"
  [ -n "$outer_line" ] && [ -n "$child_line" ]
  [ "$child_line" -gt "$outer_line" ]
}

@test "state show on layout-2 workflow groups children and marks missing evidence" {
  command -v jq >/dev/null 2>&1 || skip "jq unavailable"
  run env RALPH_PLAN_WORKSPACE_ROOT="$fixture_root/mixed" bash "$STATE_CLI" show run-2
  [ "$status" -eq 0 ]
  [[ "$output" == *"layoutVersion"* ]]
  [[ "$output" == *"evidence:"* ]]
  [[ "$output" == *"catalog: ok"* ]]
  [[ "$output" == *"children:"* ]]
  [[ "$output" == *"child-2"* ]]
  [[ "$output" == *"stage=build"* ]]
  # inputs/ exists but is empty dir — present as ok; gone namespace would be missing
  [[ "$output" == *": missing"* || "$output" == *"inputs: ok"* ]]
}

@test "state show on unknown run id prints explicit missing markers" {
  run env RALPH_PLAN_WORKSPACE_ROOT="$fixture_root/v1" bash "$STATE_CLI" show does-not-exist
  [ "$status" -eq 0 ]
  [[ "$output" == *"catalog: missing"* ]]
  [[ "$output" == *"run-manifest: missing"* ]]
  [[ "$output" == *"workflow-run: missing"* ]]
  [[ "$output" == *"graph-run: missing"* ]]
}

@test "state show reports expired for dangling evidence symlink" {
  command -v jq >/dev/null 2>&1 || skip "jq unavailable"
  # Point artifacts_dir at the dangling symlink so show surfaces expired.
  local manifest="$fixture_root/mixed/runs/run-2/stages/build/attempts/child-2/run-manifest.json"
  jq '.paths.artifacts_dir = "runs/run-2/stages/build/attempts/child-2/expired-link"' \
    "$manifest" >"$manifest.tmp"
  mv "$manifest.tmp" "$manifest"
  run env RALPH_PLAN_WORKSPACE_ROOT="$fixture_root/mixed" bash "$STATE_CLI" show child-2
  [ "$status" -eq 0 ]
  [[ "$output" == *"artifacts: expired"* ]]
}

@test "state runs and show are read-only against fixture roots" {
  local before after
  before="$(find "$fixture_root" -type f | wc -l | tr -d ' ')"
  run env RALPH_PLAN_WORKSPACE_ROOT="$fixture_root/v1" bash "$STATE_CLI" runs
  [ "$status" -eq 0 ]
  run env RALPH_PLAN_WORKSPACE_ROOT="$fixture_root/mixed" bash "$STATE_CLI" show run-2
  [ "$status" -eq 0 ]
  after="$(find "$fixture_root" -type f | wc -l | tr -d ' ')"
  [ "$before" -eq "$after" ]
}
