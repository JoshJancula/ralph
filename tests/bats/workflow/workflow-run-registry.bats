#!/usr/bin/env bats
# Outer workflow-run registry storage (workflow-state.sh).
# Sourced function tests only — no engine or runtime invocation.
# Contracts: agents/rules/test-design.md, agents/rules/testing-workflow.md,
# and .ralph-workspace/artifacts/ralph-first-class-workflows/contracts.md
# (Registry JSON fields and paths).

source "$BATS_TEST_DIRNAME/../helper/load-lib.bash"

STATE_LIB="$REPO_ROOT/bundle/.ralph/bash-lib/workflow/workflow-state.sh"

setup_file() {
  command -v jq >/dev/null || skip "jq required"
  [ -f "$STATE_LIB" ]
  # One shared state-root fixture for the file (paths may contain spaces).
  WSR_ROOT="$(mktemp -d "${BATS_TMPDIR:-/tmp}/wsr root.XXXXXX")"
  WSR_ROOT="$(cd "$WSR_ROOT" && pwd -P)"
  WSR_STATE="$WSR_ROOT/state root"
  mkdir -p "$WSR_STATE"
  WSR_INPUTS="$WSR_ROOT/inputs"
  mkdir -p "$WSR_INPUTS"
  printf '{"pipeline":{"stages":[{"id":"s1"}]}}\n' >"$WSR_INPUTS/sample.orch.json"
  printf '# plan\n- [ ] do thing\n' >"$WSR_INPUTS/sample.plan.md"
  printf '%s\n' '---' 'kind: workflow' 'mode: sequential' '---' >"$WSR_INPUTS/wf.md"
  export WSR_ROOT WSR_STATE WSR_INPUTS
}

teardown_file() {
  rm -rf "$WSR_ROOT"
}

setup() {
  unset RALPH_WORKFLOW_STATE_ROOT RALPH_PLAN_WORKSPACE_ROOT RALPH_GRAPH_STATE_ROOT
  unset WORKFLOW_STATE_FIXED_RUN_ID WORKFLOW_STATE_FIXED_NOW
  unset WORKFLOW_STATE_MINT_SEQUENCE_FILE WORKFLOW_STATE_OWNER_JSON
  unset GRAPH_STATE_FIXED_RUN_ID GRAPH_STATE_SUPERVISOR_PID
  unset GRAPH_STATE_OWNER_HOSTNAME GRAPH_STATE_OWNER_PROCESS_START_ID
  unset GRAPH_STATE_HEARTBEAT_AT
  unset WORKFLOW_STATE_IMPORT_HOOK_AFTER_COPY
  unset WORKFLOW_STATE_IMPORT_HOOK_AFTER_SOURCE_PUBLISH
  unset WORKFLOW_STATE_IMPORT_HOOK_BEFORE_MANIFEST
  unset WORKFLOW_STATE_IMPORT_HOOK_BEFORE_ATTACH
  unset WORKFLOW_STATE_IMPORT_ORIGINAL WORKFLOW_STATE_IMPORT_SOURCE_TMP
  unset WORKFLOW_STATE_IMPORT_SOURCE_DEST WORKFLOW_STATE_IMPORT_MANIFEST_TMP
  unset WORKFLOW_STATE_IMPORT_MANIFEST_DEST WORKFLOW_STATE_IMPORT_RUN_DIR
  unset WORKFLOW_STATE_IMPORT_RUN_ID WORKFLOW_STATE_IMPORT_STATE_ROOT
  unset WORKFLOW_STATE_GENPLAN_HOOK_AFTER_RENDER
  unset WORKFLOW_STATE_GENPLAN_HOOK_AFTER_PLAN_PUBLISH
  unset WORKFLOW_STATE_GENPLAN_HOOK_BEFORE_MANIFEST
  unset WORKFLOW_STATE_GENPLAN_REGISTRY_RUN WORKFLOW_STATE_GENPLAN_STAGE_ID
  unset WORKFLOW_STATE_GENPLAN_ATTEMPT WORKFLOW_STATE_GENPLAN_ARTIFACT
  unset WORKFLOW_STATE_GENPLAN_PLAN_TMP WORKFLOW_STATE_GENPLAN_PLAN_DEST
  unset WORKFLOW_STATE_GENPLAN_MANIFEST_TMP WORKFLOW_STATE_GENPLAN_MANIFEST_DEST
  export WORKFLOW_STATE_SKIP_FSYNC=1
  # shellcheck source=/dev/null
  source "$STATE_LIB"
  # Per-test scratch under the shared state root so create/list stay isolated
  # when tests share the fixture directory.
  WSR_CASE="$(mktemp -d "$WSR_STATE/case.XXXXXX")"
  WSR_CASE="$(cd "$WSR_CASE" && pwd -P)"
  export WSR_CASE
  # Last in setup(): teardown() in these files dereferences variables setup
  # creates, so skipping before they exist fails teardown under `set -u` and
  # bats drops the test with no TAP line at all instead of reporting a skip.
  bats_skip_known_ci_flakes
}

teardown() {
  rm -rf "$WSR_CASE"
}

wait_for_file() {
  local path="$1"
  local deadline=$(( $(date +%s) + 5 ))
  until [[ -e "$path" ]]; do
    [[ $(date +%s) -lt $deadline ]] || {
      echo "timed out waiting for $path" >&2
      return 1
    }
    sleep 0.05
  done
}

create_task_entry() {
  local state_root="${1:-$WSR_CASE}"
  shift || true
  workflow_state_create \
    --state-root "$state_root" \
    --source-path "$WSR_INPUTS/wf.md" \
    --source-kind project \
    --mode sequential \
    --entry-kind task \
    --task "Fix the flaky timeout" \
    --task-provenance explicit \
    --input-file "$WSR_INPUTS/sample.orch.json" \
    --workflow-id bug-fix \
    "$@"
}

# Plan-entry run with null inputPlan (import publishes plans/input/*).
create_plan_entry_for_import() {
  local state_root="${1:-$WSR_CASE}"
  shift || true
  workflow_state_create \
    --state-root "$state_root" \
    --source-path "$WSR_INPUTS/wf.md" \
    --source-kind project \
    --mode dependency \
    --entry-kind plan \
    --task "Execute the supplied feature plan" \
    --task-provenance plan-overview \
    --input-file "$WSR_INPUTS/sample.plan.md" \
    --workflow-id plan-delivery \
    --engine-namespace plan-delivery \
    "$@"
}

# Operator-owned leaf plan under the project root (allowed-root containment).
write_provided_leaf_plan() {
  local dest="${1:-$WSR_CASE/project/plans/feature.plan.md}"
  local body="${2:-}"
  mkdir -p "$(dirname -- "$dest")"
  if [[ -n "$body" ]]; then
    printf '%s' "$body" >"$dest"
  else
    cat >"$dest" <<'EOF'
# Feature plan

- [x] already done by operator
- [ ] implement the change
- [ ] verify the change
EOF
  fi
  printf '%s\n' "$dest"
}

sample_input_plan_json() {
  local run_placeholder="${1:-run-placeholder}"
  jq -cn \
    --arg original "$WSR_INPUTS/sample.plan.md" \
    --arg source "$WSR_CASE/workflow-runs/$run_placeholder/plans/input/source.plan.md" \
    --arg manifest "$WSR_CASE/workflow-runs/$run_placeholder/plans/input/manifest.json" \
    '{
      originalPath: $original,
      sourcePath: $source,
      manifestPath: $manifest,
      sha256: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
      format: "classic",
      totalTodos: 1,
      completedTodos: 0,
      openTodos: 1
    }'
}

# ---------------------------------------------------------------------------
# Root resolution / spaces / no cwd
# ---------------------------------------------------------------------------

@test "state root resolves overrides without cwd assumptions" {
  local outside other
  outside="$(mktemp -d)"
  other="$(mktemp -d "$outside/other space.XXXXXX")"
  other="$(cd "$other" && pwd -P)"

  (
    cd "$outside" || exit 1
    unset RALPH_WORKFLOW_STATE_ROOT RALPH_PLAN_WORKSPACE_ROOT
    root="$(workflow_state_state_root "$other")"
    [[ "$root" == "$other/.ralph-workspace" ]]
  )

  (
    cd "$outside" || exit 1
    export RALPH_PLAN_WORKSPACE_ROOT="$WSR_CASE"
    root="$(workflow_state_state_root "/does/not/matter")"
    [[ "$root" == "$WSR_CASE" ]]
  )

  (
    cd "$outside" || exit 1
    export RALPH_WORKFLOW_STATE_ROOT="$WSR_CASE"
    export RALPH_PLAN_WORKSPACE_ROOT="/ignored"
    root="$(workflow_state_state_root)"
    [[ "$root" == "$WSR_CASE" ]]
  )

  rm -rf "$outside"
}

@test "create task entry under state root with spaces and immutable input copy" {
  local run_id input_path
  export WORKFLOW_STATE_FIXED_NOW="2026-01-01T00:00:00Z"
  run_id="$(create_task_entry "$WSR_CASE")"
  [[ "$run_id" == run-* ]]

  input_path="$(workflow_state_read_input_path "$WSR_CASE" "$run_id")"
  [[ "$input_path" == "$WSR_CASE/workflow-runs/$run_id/input.orch.json" ]]
  [[ -f "$input_path" ]]
  [[ ! -w "$input_path" ]] || chmod a-w "$input_path"
  cmp -s "$WSR_INPUTS/sample.orch.json" "$input_path"

  run workflow_state_read "$WSR_CASE" "$run_id"
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '.entryKind')" = "task" ]
  [ "$(printf '%s' "$output" | jq -r '.inputPlan')" = "null" ]
  [ "$(printf '%s' "$output" | jq -r '.createdAt')" = "2026-01-01T00:00:00Z" ]
  [ "$(printf '%s' "$output" | jq -r '.engine.kind')" = "orchestration" ]
}

@test "plan metadata create stores nullable inputPlan without publishing source" {
  local run_id meta plans_dir
  meta="$(sample_input_plan_json "pending")"
  export WORKFLOW_STATE_FIXED_NOW="2026-01-01T00:00:10Z"
  run_id="$(
    workflow_state_create \
      --state-root "$WSR_CASE" \
      --source-path "$WSR_INPUTS/wf.md" \
      --source-kind project \
      --mode dependency \
      --entry-kind plan \
      --task "Execute the supplied feature plan" \
      --task-provenance plan-overview \
      --input-file "$WSR_INPUTS/sample.plan.md" \
      --workflow-id plan-delivery \
      --input-plan-json "$meta" \
      --engine-namespace plan-delivery
  )"

  run workflow_state_read "$WSR_CASE" "$run_id"
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '.entryKind')" = "plan" ]
  [ "$(printf '%s' "$output" | jq -r '.inputPlan.format')" = "classic" ]
  [ "$(printf '%s' "$output" | jq -r '.inputPlan.sha256')" = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" ]
  [ "$(printf '%s' "$output" | jq -r '.engine.kind')" = "graph" ]
  [ "$(printf '%s' "$output" | jq -r '.engine.namespace')" = "plan-delivery" ]

  plans_dir="$WSR_CASE/workflow-runs/$run_id/plans"
  [ ! -e "$plans_dir/input/source.plan.md" ]
  [ ! -e "$plans_dir/input/manifest.json" ]
  cmp -s "$WSR_INPUTS/sample.plan.md" "$(workflow_state_read_input_path "$WSR_CASE" "$run_id")"
}

@test "create collision retry remints when run directory already exists" {
  local seq run_id
  seq="$(mktemp)"
  printf '%s\n' "run-20260101T000000Z-0-collide" "run-20260101T000000Z-0-okpath" >"$seq"
  export WORKFLOW_STATE_MINT_SEQUENCE_FILE="$seq"
  mkdir -p "$WSR_CASE/workflow-runs/run-20260101T000000Z-0-collide"

  run_id="$(create_task_entry "$WSR_CASE")"
  [ "$run_id" = "run-20260101T000000Z-0-okpath" ]
  [ -f "$WSR_CASE/workflow-runs/$run_id/run.json" ]
  rm -f "$seq"
}

@test "read and update refresh owner timestamps without rewriting immutable input" {
  local run_id input_path before after lock_path
  export WORKFLOW_STATE_FIXED_NOW="2026-01-01T00:00:20Z"
  export WORKFLOW_STATE_OWNER_JSON='{"pid":4242,"hostname":"dev.host","processStartId":"4242:1","heartbeatAt":"2026-01-01T00:00:20Z"}'
  run_id="$(create_task_entry "$WSR_CASE" --owner-json "$WORKFLOW_STATE_OWNER_JSON")"
  input_path="$(workflow_state_read_input_path "$WSR_CASE" "$run_id")"
  before="$(cksum "$input_path" | awk '{print $1" "$2}')"

  export WORKFLOW_STATE_FIXED_NOW="2026-01-01T00:00:30Z"
  workflow_state_update "$WSR_CASE" "$run_id" '
    .state = "running"
    | .owner = {"pid":4242,"hostname":"dev.host","processStartId":"4242:1","heartbeatAt":"2026-01-01T00:00:30Z"}
  '

  run workflow_state_read "$WSR_CASE" "$run_id"
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '.state')" = "running" ]
  [ "$(printf '%s' "$output" | jq -r '.updatedAt')" = "2026-01-01T00:00:30Z" ]
  [ "$(printf '%s' "$output" | jq -r '.owner.heartbeatAt')" = "2026-01-01T00:00:30Z" ]
  [ "$(printf '%s' "$output" | jq -r '.createdAt')" = "2026-01-01T00:00:20Z" ]

  after="$(cksum "$input_path" | awk '{print $1" "$2}')"
  [ "$before" = "$after" ]

  # Update lock must be released.
  lock_path="$(workflow_state_update_lock_path "$WSR_CASE" "$run_id")"
  [ ! -e "$lock_path" ]
}

@test "list newest runs supports state root filters and read-only operations" {
  local a b c listed
  export WORKFLOW_STATE_FIXED_NOW="2026-01-01T00:00:40Z"
  a="$(create_task_entry "$WSR_CASE" --workflow-id bug-fix)"
  export WORKFLOW_STATE_FIXED_NOW="2026-01-01T00:00:41Z"
  b="$(
    workflow_state_create \
      --state-root "$WSR_CASE" \
      --source-path "$WSR_INPUTS/wf.md" \
      --source-kind project \
      --mode dependency \
      --entry-kind task \
      --task "Ship filter" \
      --task-provenance explicit \
      --input-file "$WSR_INPUTS/sample.plan.md" \
      --workflow-id feature-delivery
  )"
  export WORKFLOW_STATE_FIXED_NOW="2026-01-01T00:00:42Z"
  c="$(create_task_entry "$WSR_CASE" --workflow-id bug-fix)"
  workflow_state_update "$WSR_CASE" "$c" '.state = "failed"'

  # Read-only list from an unrelated cwd.
  listed="$(
    cd /tmp && workflow_state_list "$WSR_CASE" --workflow bug-fix --json
  )"
  [ "$(printf '%s' "$listed" | jq -r 'length')" = "2" ]
  [ "$(printf '%s' "$listed" | jq -r '.[0].runId')" = "$c" ]
  [ "$(printf '%s' "$listed" | jq -r '.[0].state')" = "failed" ]
  [ "$(printf '%s' "$listed" | jq -r '.[1].runId')" = "$a" ]

  listed="$(workflow_state_list "$WSR_CASE" --state failed --json)"
  [ "$(printf '%s' "$listed" | jq -r '.[0].runId')" = "$c" ]
  [ "$(printf '%s' "$listed" | jq 'map(.runId) | index("'"$b"'")')" = "null" ]

  # Original inputs untouched by list/read.
  cmp -s "$WSR_INPUTS/sample.orch.json" "$(workflow_state_read_input_path "$WSR_CASE" "$a")"
}

@test "concurrent create uses create lock with deterministic barriers" {
  local barrier go ready1 ready2 out1 out2 id1 id2
  barrier="$(mktemp -d "$WSR_CASE/barrier.XXXXXX")"
  go="$barrier/go"
  ready1="$barrier/ready1"
  ready2="$barrier/ready2"
  out1="$barrier/out1"
  out2="$barrier/out2"

  (
    # shellcheck source=/dev/null
    source "$STATE_LIB"
    touch "$ready1"
    wait_for_file "$go"
    create_task_entry "$WSR_CASE" --task "concurrent A" >"$out1"
  ) &
  (
    # shellcheck source=/dev/null
    source "$STATE_LIB"
    touch "$ready2"
    wait_for_file "$go"
    create_task_entry "$WSR_CASE" --task "concurrent B" >"$out2"
  ) &

  wait_for_file "$ready1"
  wait_for_file "$ready2"
  touch "$go"
  wait

  id1="$(tr -d '[:space:]' <"$out1")"
  id2="$(tr -d '[:space:]' <"$out2")"
  [[ "$id1" == run-* ]]
  [[ "$id2" == run-* ]]
  [ "$id1" != "$id2" ]
  [ -f "$WSR_CASE/workflow-runs/$id1/run.json" ]
  [ -f "$WSR_CASE/workflow-runs/$id2/run.json" ]
  [ ! -e "$(workflow_state_create_lock_path "$WSR_CASE")" ]
}

@test "corrupt and missing entry errors are distinct" {
  local run_id run_file
  run_id="$(create_task_entry "$WSR_CASE")"
  run_file="$(workflow_state_run_file "$WSR_CASE" "$run_id")"

  run workflow_state_read "$WSR_CASE" "run-does-not-exist"
  [ "$status" -ne 0 ]
  [[ "$output" == *"missing run entry"* ]]

  printf '{not-json' >"$run_file"
  run workflow_state_read "$WSR_CASE" "$run_id"
  [ "$status" -ne 0 ]
  [[ "$output" == *"corrupt run entry"* ]]

  printf '{"runId":"x"}\n' >"$run_file"
  run workflow_state_validate_run_json "$run_file"
  [ "$status" -ne 0 ]
  [[ "$output" == *"corrupt run entry"* ]]
}

@test "symlink escape outside state root is refused" {
  local outside escape_link run_id
  outside="$(mktemp -d)"
  outside="$(cd "$outside" && pwd -P)"
  mkdir -p "$WSR_CASE/workflow-runs"
  ln -s "$outside" "$WSR_CASE/workflow-runs/escape-link"

  run workflow_state_resolve_under_state_root "$WSR_CASE" "workflow-runs/escape-link/secret"
  [ "$status" -ne 0 ]
  [[ "$output" == *"escapes the state root via symlink"* ]]

  run_id="$(create_task_entry "$WSR_CASE")"
  # Replace run.json with a symlink pointing outside.
  rm -f "$WSR_CASE/workflow-runs/$run_id/run.json"
  ln -s "$outside/evil.json" "$WSR_CASE/workflow-runs/$run_id/run.json"
  printf '{"runId":"evil"}\n' >"$outside/evil.json"
  run workflow_state_read "$WSR_CASE" "$run_id"
  [ "$status" -ne 0 ]

  rm -rf "$outside"
}

@test "update refuses immutable field changes and task plan metadata mismatch" {
  local run_id
  run_id="$(create_task_entry "$WSR_CASE")"

  run workflow_state_update "$WSR_CASE" "$run_id" '.runId = "mutated"'
  [ "$status" -ne 0 ]
  [[ "$output" == *"immutable"* ]]

  run workflow_state_create \
    --state-root "$WSR_CASE" \
    --source-path "$WSR_INPUTS/wf.md" \
    --source-kind project \
    --mode sequential \
    --entry-kind task \
    --task "bad" \
    --task-provenance explicit \
    --input-file "$WSR_INPUTS/sample.orch.json" \
    --input-plan-json "$(sample_input_plan_json)"
  [ "$status" -ne 0 ]
  [[ "$output" == *"null inputPlan"* ]]
}

# ---------------------------------------------------------------------------
# Provided-plan import (source.plan.md + manifest.json + run.json attach)
# ---------------------------------------------------------------------------

@test "provided plan import is byte exact and attaches inputPlan metadata" {
  local run_id plan_path source_path before after manifest sha
  mkdir -p "$WSR_CASE/project"
  plan_path="$(write_provided_leaf_plan "$WSR_CASE/project/plans/feature.plan.md")"
  before="$(cksum "$plan_path" | awk '{print $1" "$2}')"
  export WORKFLOW_STATE_FIXED_NOW="2026-01-01T01:00:00Z"
  run_id="$(create_plan_entry_for_import "$WSR_CASE")"

  run workflow_state_import_provided_plan \
    --state-root "$WSR_CASE" \
    --run-id "$run_id" \
    --plan "$plan_path" \
    --project-root "$WSR_CASE/project" \
    --explicit-task "Ship the provided feature"
  [ "$status" -eq 0 ]
  source_path="$output"
  [[ "$source_path" == "$WSR_CASE/workflow-runs/$run_id/plans/input/source.plan.md" ]]
  cmp -s "$plan_path" "$source_path"
  after="$(cksum "$plan_path" | awk '{print $1" "$2}')"
  [ "$before" = "$after" ]

  manifest="$WSR_CASE/workflow-runs/$run_id/plans/input/manifest.json"
  [ -f "$manifest" ]
  [ "$(jq -r '.schemaVersion,.sourceKind,.copiedPath,.taskProvenance,.createdAt' "$manifest" | paste -sd, -)" = \
    "1,provided,$source_path,explicit,2026-01-01T01:00:00Z" ]
  sha="$(jq -r '.copiedSha256' "$manifest")"
  [ "$(jq -r '.originalSha256' "$manifest")" = "$sha" ]
  [ "$(jq -r '.totalTodos,.completedTodos,.openTodos' "$manifest" | paste -sd, -)" = "3,1,2" ]

  run workflow_state_read "$WSR_CASE" "$run_id"
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '.inputPlan.sourcePath')" = "$source_path" ]
  [ "$(printf '%s' "$output" | jq -r '.inputPlan.manifestPath')" = "$manifest" ]
  [ "$(printf '%s' "$output" | jq -r '.inputPlan.sha256')" = "$sha" ]
  [ "$(printf '%s' "$output" | jq -r '.inputPlan.format')" = "classic" ]
  [ "$(printf '%s' "$output" | jq -r '.inputPlan.openTodos')" = "2" ]
}

@test "manifest last publishes after source and second import is refused" {
  local run_id plan_path order_log source_path manifest
  mkdir -p "$WSR_CASE/project"
  plan_path="$(write_provided_leaf_plan)"
  order_log="$WSR_CASE/order.log"
  : >"$order_log"
  export WORKFLOW_STATE_FIXED_NOW="2026-01-01T01:00:10Z"
  run_id="$(create_plan_entry_for_import "$WSR_CASE")"

  export WORKFLOW_STATE_IMPORT_HOOK_AFTER_SOURCE_PUBLISH='
    printf "source\n" >>"'"$order_log"'"
    [[ -f "$WORKFLOW_STATE_IMPORT_SOURCE_DEST" ]]
    [[ ! -e "$WORKFLOW_STATE_IMPORT_MANIFEST_DEST" ]]
  '
  export WORKFLOW_STATE_IMPORT_HOOK_BEFORE_MANIFEST='
    printf "before-manifest\n" >>"'"$order_log"'"
    [[ -f "$WORKFLOW_STATE_IMPORT_SOURCE_DEST" ]]
    [[ ! -e "$WORKFLOW_STATE_IMPORT_MANIFEST_DEST" ]]
  '

  run workflow_state_import_provided_plan \
    --state-root "$WSR_CASE" \
    --run-id "$run_id" \
    --plan "$plan_path" \
    --project-root "$WSR_CASE/project"
  [ "$status" -eq 0 ]
  source_path="$WSR_CASE/workflow-runs/$run_id/plans/input/source.plan.md"
  manifest="$WSR_CASE/workflow-runs/$run_id/plans/input/manifest.json"
  [ -f "$source_path" ]
  [ -f "$manifest" ]
  [ "$(cat "$order_log")" = $'source\nbefore-manifest' ]

  run workflow_state_import_provided_plan \
    --state-root "$WSR_CASE" \
    --run-id "$run_id" \
    --plan "$plan_path" \
    --project-root "$WSR_CASE/project"
  [ "$status" -ne 0 ]
  [[ "$output" == *"second import"* ]]
}

@test "hash race during copy refuses and leaves original unchanged destination empty" {
  local run_id plan_path before after input_dir
  mkdir -p "$WSR_CASE/project"
  plan_path="$(write_provided_leaf_plan)"
  before="$(cksum "$plan_path" | awk '{print $1" "$2}')"
  run_id="$(create_plan_entry_for_import "$WSR_CASE")"
  input_dir="$WSR_CASE/workflow-runs/$run_id/plans/input"

  export WORKFLOW_STATE_IMPORT_HOOK_AFTER_COPY='
    printf "\n- [ ] mutated mid-copy\n" >>"$WORKFLOW_STATE_IMPORT_ORIGINAL"
  '

  run workflow_state_import_provided_plan \
    --state-root "$WSR_CASE" \
    --run-id "$run_id" \
    --plan "$plan_path" \
    --project-root "$WSR_CASE/project"
  [ "$status" -ne 0 ]
  [[ "$output" == *"hash race"* || "$output" == *"does not match"* ]]
  [ ! -e "$input_dir/source.plan.md" ]
  [ ! -e "$input_dir/manifest.json" ]
  # Temps cleaned; only the test hook mutated the original.
  after="$(cksum "$plan_path" | awk '{print $1" "$2}')"
  [ "$before" != "$after" ]
  [[ "$(cat "$plan_path")" == *"mutated mid-copy"* ]]
  # No lingering temp files under plans/input.
  [ "$(find "$input_dir" -maxdepth 1 -type f 2>/dev/null | wc -l | tr -d ' ')" = "0" ] || \
    [ ! -d "$input_dir" ]
}

@test "collision refuses overwrite of existing source or manifest" {
  local run_id plan_path input_dir
  mkdir -p "$WSR_CASE/project"
  plan_path="$(write_provided_leaf_plan)"
  run_id="$(create_plan_entry_for_import "$WSR_CASE")"
  input_dir="$WSR_CASE/workflow-runs/$run_id/plans/input"
  mkdir -p "$input_dir"
  printf 'preexisting\n' >"$input_dir/source.plan.md"

  run workflow_state_import_provided_plan \
    --state-root "$WSR_CASE" \
    --run-id "$run_id" \
    --plan "$plan_path" \
    --project-root "$WSR_CASE/project"
  [ "$status" -ne 0 ]
  [[ "$output" == *"collision"* ]]
  [ "$(cat "$input_dir/source.plan.md")" = "preexisting" ]
  [ ! -e "$input_dir/manifest.json" ]

  rm -f "$input_dir/source.plan.md"
  printf '{}\n' >"$input_dir/manifest.json"
  run workflow_state_import_provided_plan \
    --state-root "$WSR_CASE" \
    --run-id "$run_id" \
    --plan "$plan_path" \
    --project-root "$WSR_CASE/project"
  [ "$status" -ne 0 ]
  [[ "$output" == *"collision"* ]]
  [ "$(cat "$input_dir/manifest.json")" = "{}" ]
  [ ! -e "$input_dir/source.plan.md" ]
}

@test "symlink plans input path is refused for provided plan import" {
  local run_id plan_path outside
  mkdir -p "$WSR_CASE/project"
  plan_path="$(write_provided_leaf_plan)"
  run_id="$(create_plan_entry_for_import "$WSR_CASE")"
  outside="$(mktemp -d)"
  outside="$(cd "$outside" && pwd -P)"
  mkdir -p "$WSR_CASE/workflow-runs/$run_id/plans"
  ln -s "$outside" "$WSR_CASE/workflow-runs/$run_id/plans/input"

  run workflow_state_import_provided_plan \
    --state-root "$WSR_CASE" \
    --run-id "$run_id" \
    --plan "$plan_path" \
    --project-root "$WSR_CASE/project"
  [ "$status" -ne 0 ]
  [[ "$output" == *"symlink"* ]]
  [ ! -e "$outside/source.plan.md" ]
  [ ! -e "$outside/manifest.json" ]
  rm -rf "$outside"
}

@test "zero TODO and zero open provided plans are refused" {
  local run_id empty_plan done_plan
  mkdir -p "$WSR_CASE/project/plans"
  empty_plan="$WSR_CASE/project/plans/empty.plan.md"
  done_plan="$WSR_CASE/project/plans/done.plan.md"
  printf '# empty\n\nno todos here\n' >"$empty_plan"
  printf '# done\n\n- [x] already finished\n' >"$done_plan"
  run_id="$(create_plan_entry_for_import "$WSR_CASE")"

  run workflow_state_import_provided_plan \
    --state-root "$WSR_CASE" \
    --run-id "$run_id" \
    --plan "$empty_plan" \
    --project-root "$WSR_CASE/project"
  [ "$status" -ne 0 ]
  [[ "$output" == *"no TODOs"* ]]

  run workflow_state_import_provided_plan \
    --state-root "$WSR_CASE" \
    --run-id "$run_id" \
    --plan "$done_plan" \
    --project-root "$WSR_CASE/project"
  [ "$status" -ne 0 ]
  [[ "$output" == *"no pending TODOs"* ]]
  [ ! -e "$WSR_CASE/workflow-runs/$run_id/plans/input/source.plan.md" ]
  [ ! -e "$WSR_CASE/workflow-runs/$run_id/plans/input/manifest.json" ]
}

@test "original unchanged on successful import and task entry is refused" {
  local run_id plan_path before after task_id
  mkdir -p "$WSR_CASE/project"
  plan_path="$(write_provided_leaf_plan)"
  before="$(cksum "$plan_path" | awk '{print $1" "$2}')"
  run_id="$(create_plan_entry_for_import "$WSR_CASE")"

  run workflow_state_import_provided_plan \
    --state-root "$WSR_CASE" \
    --run-id "$run_id" \
    --plan "$plan_path" \
    --project-root "$WSR_CASE/project"
  [ "$status" -eq 0 ]
  after="$(cksum "$plan_path" | awk '{print $1" "$2}')"
  [ "$before" = "$after" ]
  cmp -s "$plan_path" "$WSR_CASE/workflow-runs/$run_id/plans/input/source.plan.md"

  task_id="$(create_task_entry "$WSR_CASE")"
  run workflow_state_import_provided_plan \
    --state-root "$WSR_CASE" \
    --run-id "$task_id" \
    --plan "$plan_path" \
    --project-root "$WSR_CASE/project"
  [ "$status" -ne 0 ]
  [[ "$output" == *"plan-entry"* || "$output" == *"entryKind=task"* ]]
}

@test "partial cleanup rolls back source when before-manifest hook fails" {
  local run_id plan_path input_dir
  mkdir -p "$WSR_CASE/project"
  plan_path="$(write_provided_leaf_plan)"
  run_id="$(create_plan_entry_for_import "$WSR_CASE")"
  input_dir="$WSR_CASE/workflow-runs/$run_id/plans/input"

  export WORKFLOW_STATE_IMPORT_HOOK_BEFORE_MANIFEST='return 1'

  run workflow_state_import_provided_plan \
    --state-root "$WSR_CASE" \
    --run-id "$run_id" \
    --plan "$plan_path" \
    --project-root "$WSR_CASE/project"
  [ "$status" -ne 0 ]
  [[ "$output" == *"before-manifest"* ]]
  [ ! -e "$input_dir/source.plan.md" ]
  [ ! -e "$input_dir/manifest.json" ]
  # No partial temps left behind.
  if [[ -d "$input_dir" ]]; then
    [ "$(find "$input_dir" -maxdepth 1 \( -type f -o -type l \) 2>/dev/null | wc -l | tr -d ' ')" = "0" ]
  fi
  [ "$(workflow_state_read "$WSR_CASE" "$run_id" | jq -c '.inputPlan')" = "null" ]
}

# ---------------------------------------------------------------------------
# Generated-plan materialization (attempt-N plan.md + manifest.json)
# ---------------------------------------------------------------------------

write_planner_v2_artifact() {
  local dest="${1:-$WSR_CASE/artifacts/planner.json}"
  mkdir -p "$(dirname -- "$dest")"
  cat >"$dest" <<'EOF'
{
  "schemaVersion": 2,
  "name": "generated-demo",
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
      "status": "pending",
      "model": "gpt-5"
    }
  ]
}
EOF
  printf '%s\n' "$dest"
}

materialize_generated_plan() {
  local run_id="$1"
  local artifact="$2"
  shift 2
  workflow_state_materialize_generated_plan \
    --registry-run "$WSR_CASE/workflow-runs/$run_id" \
    --planner-stage-id plan-implementation \
    --attempt 1 \
    --artifact "$artifact" \
    --max-todos 40 \
    --default-runtime cursor \
    "$@"
}

@test "generated plan materializes attempt plan and manifest with frozen defaults" {
  local run_id artifact plan_path manifest sha before after
  artifact="$(write_planner_v2_artifact)"
  before="$(cksum "$artifact" | awk '{print $1" "$2}')"
  export WORKFLOW_STATE_FIXED_NOW="2026-01-02T03:04:05Z"
  run_id="$(create_task_entry "$WSR_CASE")"

  run materialize_generated_plan "$run_id" "$artifact" --default-model auto
  [ "$status" -eq 0 ]
  plan_path="$output"
  [[ "$plan_path" == "$WSR_CASE/workflow-runs/$run_id/plans/plan-implementation/attempt-1.plan.md" ]]
  [ -f "$plan_path" ]
  grep -q 'runtime: cursor' "$plan_path"
  grep -q 'model: auto' "$plan_path"
  grep -q 'sessionStrategy: fresh' "$plan_path"
  grep -q 'model: gpt-5' "$plan_path"
  run grep -E '^role:' "$plan_path"
  [ "$status" -ne 0 ]

  after="$(cksum "$artifact" | awk '{print $1" "$2}')"
  [ "$before" = "$after" ]

  manifest="$WSR_CASE/workflow-runs/$run_id/plans/plan-implementation/attempt-1.manifest.json"
  [ -f "$manifest" ]
  [ "$(jq -r '.schemaVersion,.producerStageId,.producerAttempt,.todoCount,.createdAt' "$manifest" | paste -sd, -)" = \
    "1,plan-implementation,1,2,2026-01-02T03:04:05Z" ]
  [ "$(jq -r '.sourceArtifact' "$manifest")" = "$artifact" ]
  [ "$(jq -r '.planPath' "$manifest")" = "$plan_path" ]
  sha="$(jq -r '.planSha256' "$manifest")"
  [[ "$sha" =~ ^[a-f0-9]{64}$ ]]
  if command -v sha256sum >/dev/null 2>&1; then
    [ "$(sha256sum "$plan_path" | awk '{print $1}')" = "$sha" ]
  else
    [ "$(shasum -a 256 "$plan_path" | awk '{print $1}')" = "$sha" ]
  fi
  # Immutable: plan and manifest are non-writable.
  [ ! -w "$plan_path" ]
  [ ! -w "$manifest" ]
}

@test "generated plan manifest publishes last and attempt overwrite is refused" {
  local run_id artifact order_log plan_path manifest
  artifact="$(write_planner_v2_artifact)"
  order_log="$WSR_CASE/genplan-order.log"
  : >"$order_log"
  export WORKFLOW_STATE_FIXED_NOW="2026-01-02T03:04:10Z"
  run_id="$(create_task_entry "$WSR_CASE")"

  export WORKFLOW_STATE_GENPLAN_HOOK_AFTER_PLAN_PUBLISH='
    printf "plan\n" >>"'"$order_log"'"
    [[ -f "$WORKFLOW_STATE_GENPLAN_PLAN_DEST" ]]
    [[ ! -e "$WORKFLOW_STATE_GENPLAN_MANIFEST_DEST" ]]
  '
  export WORKFLOW_STATE_GENPLAN_HOOK_BEFORE_MANIFEST='
    printf "before-manifest\n" >>"'"$order_log"'"
    [[ -f "$WORKFLOW_STATE_GENPLAN_PLAN_DEST" ]]
    [[ ! -e "$WORKFLOW_STATE_GENPLAN_MANIFEST_DEST" ]]
  '

  run materialize_generated_plan "$run_id" "$artifact"
  [ "$status" -eq 0 ]
  plan_path="$WSR_CASE/workflow-runs/$run_id/plans/plan-implementation/attempt-1.plan.md"
  manifest="$WSR_CASE/workflow-runs/$run_id/plans/plan-implementation/attempt-1.manifest.json"
  [ -f "$plan_path" ]
  [ -f "$manifest" ]
  [ "$(cat "$order_log")" = $'plan\nbefore-manifest' ]

  run materialize_generated_plan "$run_id" "$artifact"
  [ "$status" -ne 0 ]
  [[ "$output" == *"overwrite"* || "$output" == *"collision"* ]]
}

@test "invalid planner artifact and count overflow leave no partial attempt files" {
  local run_id bad overflow stage_dir
  run_id="$(create_task_entry "$WSR_CASE")"
  stage_dir="$WSR_CASE/workflow-runs/$run_id/plans/plan-implementation"
  mkdir -p "$WSR_CASE/artifacts"
  bad="$WSR_CASE/artifacts/bad.json"
  printf '{not-json\n' >"$bad"

  run materialize_generated_plan "$run_id" "$bad"
  [ "$status" -ne 0 ]
  [[ "$output" == *"corrupt"* || "$output" == *"invalid planner"* ]]
  [ ! -e "$stage_dir/attempt-1.plan.md" ]
  [ ! -e "$stage_dir/attempt-1.manifest.json" ]

  overflow="$WSR_CASE/artifacts/overflow.json"
  jq -n \
    --argjson todos "$(jq -n '[range(1;4) | {id:("todo-"+tostring),content:("Work "+tostring),verification:"true",status:"pending"}]')" \
    '{
      schemaVersion: 2,
      name: "overflow",
      overview: "too many",
      rationale: "overflow case",
      todos: $todos
    }' >"$overflow"

  run workflow_state_materialize_generated_plan \
    --registry-run "$WSR_CASE/workflow-runs/$run_id" \
    --planner-stage-id plan-implementation \
    --attempt 2 \
    --artifact "$overflow" \
    --max-todos 2 \
    --default-runtime cursor
  [ "$status" -ne 0 ]
  [[ "$output" == *"overflow"* || "$output" == *"maxTodos"* || "$output" == *"invalid planner"* ]]
  [ ! -e "$stage_dir/attempt-2.plan.md" ]
  [ ! -e "$stage_dir/attempt-2.manifest.json" ]
}

@test "generated plan refuses unsupported default runtime and missing attempt" {
  local run_id artifact
  artifact="$(write_planner_v2_artifact)"
  run_id="$(create_task_entry "$WSR_CASE")"

  run workflow_state_materialize_generated_plan \
    --registry-run "$WSR_CASE/workflow-runs/$run_id" \
    --planner-stage-id plan-implementation \
    --attempt 1 \
    --artifact "$artifact" \
    --max-todos 40 \
    --default-runtime not-a-runtime
  [ "$status" -ne 0 ]
  [[ "$output" == *"unsupported default runtime"* ]]

  run workflow_state_materialize_generated_plan \
    --registry-run "$WSR_CASE/workflow-runs/$run_id" \
    --planner-stage-id plan-implementation \
    --attempt 0 \
    --artifact "$artifact" \
    --max-todos 40 \
    --default-runtime cursor
  [ "$status" -ne 0 ]
  [[ "$output" == *"positive integer"* ]]
}

@test "generated plan symlink stage escape is refused" {
  local run_id artifact outside
  artifact="$(write_planner_v2_artifact)"
  run_id="$(create_task_entry "$WSR_CASE")"
  outside="$(mktemp -d)"
  outside="$(cd "$outside" && pwd -P)"
  mkdir -p "$WSR_CASE/workflow-runs/$run_id/plans"
  ln -s "$outside" "$WSR_CASE/workflow-runs/$run_id/plans/plan-implementation"

  run materialize_generated_plan "$run_id" "$artifact"
  [ "$status" -ne 0 ]
  [[ "$output" == *"symlink"* ]]
  [ ! -e "$outside/attempt-1.plan.md" ]
  [ ! -e "$outside/attempt-1.manifest.json" ]
  rm -rf "$outside"
}

@test "atomic generated plan rollback when before-manifest hook fails" {
  local run_id artifact stage_dir
  artifact="$(write_planner_v2_artifact)"
  run_id="$(create_task_entry "$WSR_CASE")"
  stage_dir="$WSR_CASE/workflow-runs/$run_id/plans/plan-implementation"
  export WORKFLOW_STATE_GENPLAN_HOOK_BEFORE_MANIFEST='return 1'

  run materialize_generated_plan "$run_id" "$artifact"
  [ "$status" -ne 0 ]
  [[ "$output" == *"before-manifest"* ]]
  [ ! -e "$stage_dir/attempt-1.plan.md" ]
  [ ! -e "$stage_dir/attempt-1.manifest.json" ]
  if [[ -d "$stage_dir" ]]; then
    [ "$(find "$stage_dir" -maxdepth 1 \( -type f -o -type l \) 2>/dev/null | wc -l | tr -d ' ')" = "0" ]
  fi
}

@test "immutable generated plan keeps routing-neutral planner JSON separate" {
  local run_id artifact plan_path
  artifact="$(write_planner_v2_artifact)"
  run_id="$(create_task_entry "$WSR_CASE")"

  run materialize_generated_plan "$run_id" "$artifact" --default-model auto
  [ "$status" -eq 0 ]
  plan_path="$output"
  # Model JSON stays routing-neutral (no frozen runtime/model at top level).
  [ "$(jq -r 'has("runtime"),has("model"),has("sessionStrategy")' "$artifact" | paste -sd, -)" = "false,false,false" ]
  # Run-routed plan carries frozen defaults.
  grep -q 'runtime: cursor' "$plan_path"
  grep -q 'model: auto' "$plan_path"
  grep -q 'sessionStrategy: fresh' "$plan_path"
}

# ---------------------------------------------------------------------------
# Dependency adapter: common run ID, graph pointer, no ledger duplication
# ---------------------------------------------------------------------------

DEP_LIB="$REPO_ROOT/bundle/.ralph/bash-lib/workflow/workflow-engine-dependency.sh"

@test "Dependency adapter preserves skipped as a distinct public stage state" {
  # shellcheck source=/dev/null
  source "$DEP_LIB"

  run workflow_dep_map_node_state skipped
  [ "$status" -eq 0 ]
  [ "$output" = "skipped" ]
}

write_minimal_graph_json() {
  local path="$1"
  jq -n '{
    schemaVersion: 1,
    namespace: "dep-adapter",
    maxParallel: 2,
    tooling: { defaultProfile: null },
    nodes: [
      {
        id: "implement",
        type: "agent",
        dependsOn: [],
        derivedFrom: "stage",
        stage: { id: "implement", runtime: "cursor", toolingProfile: null }
      },
      {
        id: "approve-plan",
        type: "approval",
        dependsOn: ["implement"],
        derivedFrom: "stage",
        stage: { id: "approve-plan" }
      }
    ],
    edges: [{ from: "implement", to: "approve-plan" }]
  }' >"$path"
}

@test "Dependency adapter starts graph with same run ID and absolute graph pointer" {
  # shellcheck source=/dev/null
  source "$DEP_LIB"
  local run_id graph_json plan_path graph_dir projected pointer

  export WORKFLOW_STATE_FIXED_NOW="2026-01-01T01:00:00Z"
  export WORKFLOW_STATE_FIXED_RUN_ID="run-20260101T010000Z-0-depad"
  run_id="$(
    workflow_state_create \
      --state-root "$WSR_CASE" \
      --source-path "$WSR_INPUTS/wf.md" \
      --source-kind project \
      --mode dependency \
      --entry-kind task \
      --task "Adapter start" \
      --task-provenance explicit \
      --input-file "$WSR_INPUTS/sample.plan.md" \
      --workflow-id feature-delivery \
      --engine-namespace dep-adapter
  )"
  [ "$run_id" = "run-20260101T010000Z-0-depad" ]

  graph_json="$WSR_CASE/graph.json"
  plan_path="$WSR_CASE/adapter.plan.md"
  write_minimal_graph_json "$graph_json"
  printf '# plan\n- [ ] work\n' >"$plan_path"

  graph_dir="$(
    workflow_dep_start_engine \
      --state-root "$WSR_CASE" \
      --run-id "$run_id" \
      --workspace "$WSR_CASE" \
      --plan-path "$plan_path" \
      --graph-json "$graph_json" \
      --namespace dep-adapter
  )"
  [ -d "$graph_dir" ]
  [ "$(basename "$graph_dir")" = "$run_id" ]
  [ -f "$graph_dir/run.json" ]
  [ "$(jq -r '.runId' "$graph_dir/run.json")" = "$run_id" ]

  pointer="$(workflow_dep_resolve_pointer "$WSR_CASE" "$run_id")"
  [ "$(printf '%s' "$pointer" | jq -r '.kind')" = "graph" ]
  [ "$(printf '%s' "$pointer" | jq -r '.namespace')" = "dep-adapter" ]
  [ "$(printf '%s' "$pointer" | jq -r '.statePath')" = "$graph_dir" ]
  case "$(printf '%s' "$pointer" | jq -r '.statePath')" in
    /*) ;;
    *) false ;;
  esac

  # Outer run.json engine pointer matches the graph ledger absolute path.
  run workflow_state_read "$WSR_CASE" "$run_id"
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '.engine.statePath')" = "$graph_dir" ]
  [ "$(printf '%s' "$output" | jq -r '.runId')" = "$run_id" ]
  [ "$(printf '%s' "$output" | jq -r '.state')" = "running" ]

  # Graph ledger records absolute outer registry pointer.
  local registry_ptr expected_registry
  registry_ptr="$(jq -r '.registryRunPath' "$graph_dir/run.json")"
  expected_registry="$(cd "$WSR_CASE/workflow-runs/$run_id" && pwd -P)"
  [ "$registry_ptr" = "$expected_registry" ]

  projected="$(workflow_dep_project_run "$WSR_CASE" dep-adapter "$run_id")"
  [ "$(printf '%s' "$projected" | jq -r '.runId')" = "$run_id" ]
  [ "$(printf '%s' "$projected" | jq -r '.state')" = "running" ]
}

@test "Dependency adapter graph pointer projection includes plan progress and approval action" {
  # shellcheck source=/dev/null
  source "$DEP_LIB"
  local run_id graph_json plan_path graph_dir stages stage_impl stage_appr
  local outer snapshot batch_snapshot legacy_stages legacy_observation extra shim real_jq jq_count node_read_count

  export WORKFLOW_STATE_FIXED_NOW="2026-01-01T01:10:00Z"
  export WORKFLOW_STATE_FIXED_RUN_ID="run-20260101T011000Z-0-proj"
  run_id="$(
    workflow_state_create \
      --state-root "$WSR_CASE" \
      --source-path "$WSR_INPUTS/wf.md" \
      --source-kind project \
      --mode dependency \
      --entry-kind task \
      --task "Projection" \
      --task-provenance explicit \
      --input-file "$WSR_INPUTS/sample.plan.md" \
      --workflow-id feature-delivery \
      --engine-namespace dep-adapter
  )"

  graph_json="$WSR_CASE/graph.json"
  plan_path="$WSR_CASE/adapter.plan.md"
  write_minimal_graph_json "$graph_json"
  printf '# plan\n- [ ] work\n' >"$plan_path"
  graph_dir="$(
    workflow_dep_start_engine \
      --state-root "$WSR_CASE" \
      --run-id "$run_id" \
      --workspace "$WSR_CASE" \
      --plan-path "$plan_path" \
      --graph-json "$graph_json" \
      --namespace dep-adapter
  )"

  # Simulate plan-backed progress + approval blocker on the graph node ledger
  # (no second copy under the registry run).
  export RALPH_GRAPH_STATE_ROOT="$WSR_CASE"
  export RALPH_PLAN_WORKSPACE_ROOT="$WSR_CASE"
  local control="/tmp/control-$run_id.plan.md" sourcep="/tmp/source-$run_id.plan.md"
  printf 'x\n' >"$control"
  printf 'y\n' >"$sourcep"
  graph_state_write_node "$WSR_CASE" dep-adapter "$run_id" implement running \
    "implement__${run_id}__1" \
    '{"startedAt":"2026-01-01T01:10:01Z"}' \
    "$(jq -cn \
      --arg plan "$control" \
      --arg source "$sourcep" \
      --arg control "$control" \
      '{
        planPath:$plan,
        planRunId:"plan-run-1",
        planSourceKind:"generated",
        planSourceStageId:"plan-implementation",
        originalPlanPath:null,
        sourcePlanPath:$source,
        controlPlanPath:$control,
        currentTodoId:"do-work",
        completedTodos:1,
        totalTodos:3,
        artifacts:[]
      }')"

  graph_state_write_node "$WSR_CASE" dep-adapter "$run_id" approve-plan running \
    "approve-plan__${run_id}__1" \
    '{"startedAt":"2026-01-01T01:10:02Z"}' '{}'
  graph_state_write_node "$WSR_CASE" dep-adapter "$run_id" approve-plan awaiting-operator \
    "approve-plan__${run_id}__1" \
    '{"operatorRequestId":"appr-001"}' \
    "$(jq -cn \
      --arg rid "$run_id" \
      '{
        blocker: {
          kind: "approval",
          requestId: "appr-001",
          reasonCode: "human-approval",
          retryable: false,
          changesTarget: "implement",
          action: {
            label: "List outstanding actions",
            argv: ["ralph","workflow","actions","list",$rid]
          }
        }
      }')"

  stages="$(workflow_dep_project_stages "$WSR_CASE" dep-adapter "$run_id")"
  [ "$(printf '%s' "$stages" | jq 'length')" = "2" ]
  stage_impl="$(printf '%s' "$stages" | jq -c '.[] | select(.id=="implement")')"
  stage_appr="$(printf '%s' "$stages" | jq -c '.[] | select(.id=="approve-plan")')"

  [ "$(printf '%s' "$stage_impl" | jq -r '.state')" = "running" ]
  [ "$(printf '%s' "$stage_impl" | jq -r '.planSourceKind')" = "generated" ]
  [ "$(printf '%s' "$stage_impl" | jq -r '.planSourceStageId')" = "plan-implementation" ]
  [ "$(printf '%s' "$stage_impl" | jq -r '.dependencies | length')" = "0" ]
  [ "$(printf '%s' "$stage_impl" | jq -r '.sourcePlanPath')" = "$sourcep" ]
  [ "$(printf '%s' "$stage_impl" | jq -r '.controlPlanPath')" = "$control" ]
  [ "$(printf '%s' "$stage_impl" | jq -r '.currentTodoId')" = "do-work" ]
  [ "$(printf '%s' "$stage_impl" | jq -r '.completedTodos')" = "1" ]
  [ "$(printf '%s' "$stage_impl" | jq -r '.totalTodos')" = "3" ]

  [ "$(printf '%s' "$stage_appr" | jq -r '.state')" = "waiting" ]
  [ "$(printf '%s' "$stage_appr" | jq -r '.dependencies[0].stageId')" = "implement" ]
  [ "$(printf '%s' "$stage_appr" | jq -r '.dependencies[0].condition')" = "null" ]
  [ "$(printf '%s' "$stage_appr" | jq -r '.planSourceKind')" = "null" ]
  [ "$(printf '%s' "$stage_appr" | jq -r '.completedTodos')" = "0" ]
  [ "$(printf '%s' "$stage_appr" | jq -r '.blocker.kind')" = "approval" ]
  [ "$(printf '%s' "$stage_appr" | jq -r '.blocker.requestId')" = "appr-001" ]
  [ "$(printf '%s' "$stage_appr" | jq -r '.blocker.action.argv[4]')" = "$run_id" ]

  # The public status path obtains stages and diagnosis input from one batched
  # snapshot.  Its normalized values must remain byte-for-byte equivalent to
  # the retained small projectors used by internal callers.
  outer="$(workflow_state_read "$WSR_CASE" "$run_id")"
  snapshot="$(workflow_dep_project_snapshot "$WSR_CASE" dep-adapter "$run_id" "$outer")"
  legacy_stages="$(workflow_dep_project_stages "$WSR_CASE" dep-adapter "$run_id")"
  legacy_observation="$(workflow_dep_build_observation "$WSR_CASE" "$run_id")"
  printf '%s' "$snapshot" | jq -e \
    --argjson stages "$legacy_stages" \
    --argjson observation "$legacy_observation" \
    '.stages == $stages and .observation == $observation' >/dev/null

  # Recover real declared artifacts even when the graph node ledger omitted
  # its optional artifacts cache.
  mkdir -p "$WSR_CASE/artifacts/dep-adapter"
  printf 'result\n' >"$WSR_CASE/artifacts/dep-adapter/result.md"
  jq '(.nodes[] | select(.id == "implement") | .stage.outputArtifacts) = [
        {path: ".ralph-workspace/artifacts/{{ARTIFACT_NS}}/result.md", required: true}
      ]' "$graph_dir/graph.json" >"$graph_dir/graph.json.tmp"
  mv -f "$graph_dir/graph.json.tmp" "$graph_dir/graph.json"
  snapshot="$(workflow_dep_project_snapshot "$WSR_CASE" dep-adapter "$run_id" "$outer")"
  [ "$(printf '%s' "$snapshot" | jq -r '.stages[] | select(.id=="implement") | .artifacts[0]')" \
    = "$WSR_CASE/artifacts/dep-adapter/result.md" ]

  # A 12-node frozen graph verifies that the combined projector retains graph
  # order without spawning a jq process per node ledger.
  jq '.nodes += [range(3; 13) | {
    id: ("batch-" + tostring), type: "agent", dependsOn: [],
    derivedFrom: "stage", stage: {id: ("batch-" + tostring), runtime: "cursor"}
  }]' "$graph_dir/graph.json" >"$graph_dir/graph.json.tmp"
  mv -f "$graph_dir/graph.json.tmp" "$graph_dir/graph.json"
  for extra in {3..12}; do
    printf '{"schemaVersion":3,"nodeId":"batch-%s","status":"pending","attempts":[]}\n' "$extra" \
      >"$graph_dir/nodes/batch-$extra.json"
  done
  real_jq="$(command -v jq)"
  shim="$WSR_CASE/jq-count-bin"
  jq_count="$WSR_CASE/jq-count.log"
  node_read_count="$WSR_CASE/node-read-count.log"
  mkdir -p "$shim"
  printf '%s\n' '#!/usr/bin/env bash' \
    'printf x >> "$JQ_COUNT_FILE"' \
    'exec "$REAL_JQ" "$@"' >"$shim/jq"
  chmod +x "$shim/jq"
  : >"$jq_count"
  : >"$node_read_count"
  export REAL_JQ="$real_jq" JQ_COUNT_FILE="$jq_count" NODE_READ_COUNT="$node_read_count"
  # The batched projector slurps node ledgers directly once; it must not fall
  # back to the legacy per-node graph_state_read_node helper.
  graph_state_read_node() { printf x >>"$NODE_READ_COUNT"; return 1; }
  PATH="$shim:$PATH"
  batch_snapshot="$(workflow_dep_project_snapshot "$WSR_CASE" dep-adapter "$run_id" "$outer")"
  PATH="${PATH#"$shim:"}"
  [ "$(wc -c <"$jq_count" | tr -d ' ')" -le 3 ]
  [ ! -s "$node_read_count" ]
  printf '%s' "$batch_snapshot" | jq -e '
    .stages | map(.id) == ["implement", "approve-plan"] +
      [range(3; 13) | "batch-" + tostring]
  ' >/dev/null

  # No duplicate Sequential-style engine ledger under the registry run.
  [ ! -e "$WSR_CASE/workflow-runs/$run_id/engine" ]
  [ -f "$graph_dir/nodes/implement.json" ]
  [ ! -e "$WSR_CASE/workflow-runs/$run_id/nodes" ]
}

@test "Dependency adapter refuses duplicate graph ledger for the same run ID" {
  # shellcheck source=/dev/null
  source "$DEP_LIB"
  local run_id graph_json plan_path

  export WORKFLOW_STATE_FIXED_NOW="2026-01-01T01:20:00Z"
  export WORKFLOW_STATE_FIXED_RUN_ID="run-20260101T012000Z-0-nodup"
  run_id="$(
    workflow_state_create \
      --state-root "$WSR_CASE" \
      --source-path "$WSR_INPUTS/wf.md" \
      --source-kind project \
      --mode dependency \
      --entry-kind task \
      --task "No duplicate" \
      --task-provenance explicit \
      --input-file "$WSR_INPUTS/sample.plan.md" \
      --workflow-id feature-delivery \
      --engine-namespace dep-adapter
  )"

  graph_json="$WSR_CASE/graph.json"
  plan_path="$WSR_CASE/adapter.plan.md"
  write_minimal_graph_json "$graph_json"
  printf '# plan\n- [ ] work\n' >"$plan_path"

  workflow_dep_start_engine \
    --state-root "$WSR_CASE" \
    --run-id "$run_id" \
    --workspace "$WSR_CASE" \
    --plan-path "$plan_path" \
    --graph-json "$graph_json" \
    --namespace dep-adapter >/dev/null

  run workflow_dep_start_engine \
    --state-root "$WSR_CASE" \
    --run-id "$run_id" \
    --workspace "$WSR_CASE" \
    --plan-path "$plan_path" \
    --graph-json "$graph_json" \
    --namespace dep-adapter
  [ "$status" -ne 0 ]
  [[ "$output" == *"duplicate"* ]]
  [ ! -e "$WSR_CASE/workflow-runs/$run_id/engine" ]
}

# --- Dependency planFrom control copy / source hash / progress / resume ---

DISPATCH_LIB="$REPO_ROOT/bundle/.ralph/bash-lib/graph/graph-dispatch.sh"

@test "Dependency planFrom control copy binds validated source without mutating it" {
  # shellcheck source=/dev/null
  source "$DEP_LIB"
  # shellcheck source=/dev/null
  source "$DISPATCH_LIB"
  local run_id artifact source_plan binding control before after

  artifact="$(write_planner_v2_artifact)"
  export WORKFLOW_STATE_FIXED_NOW="2026-01-03T04:05:06Z"
  run_id="$(create_task_entry "$WSR_CASE")"
  source_plan="$(materialize_generated_plan "$run_id" "$artifact" --default-model auto)"
  before="$(cksum "$source_plan" | awk '{print $1" "$2}')"

  run workflow_state_bind_generated_plan_control \
    --registry-run "$WSR_CASE/workflow-runs/$run_id" \
    --consumer-stage-id implement \
    --consumer-attempt 1 \
    --planner-stage-id plan-implementation \
    --planner-attempt 1 \
    --plan-run-id "implement__${run_id}__1"
  [ "$status" -eq 0 ]
  binding="$output"
  control="$(printf '%s' "$binding" | jq -r '.controlPlanPath')"
  [[ "$control" == "$WSR_CASE/workflow-runs/$run_id/plans/implement/attempt-1/control.plan.md" ]]
  [ -f "$control" ]
  [ "$(printf '%s' "$binding" | jq -r '.planSourceKind')" = "generated" ]
  [ "$(printf '%s' "$binding" | jq -r '.planSourceStageId')" = "plan-implementation" ]
  [ "$(printf '%s' "$binding" | jq -r '.sourcePlanPath')" = "$source_plan" ]
  [ "$(printf '%s' "$binding" | jq -r '.createdControl')" = "true" ]
  [ "$(printf '%s' "$binding" | jq -r '.totalTodos')" = "2" ]
  [ "$(printf '%s' "$binding" | jq -r '.completedTodos')" = "0" ]
  [ "$(printf '%s' "$binding" | jq -r '.currentTodoId')" = "implement-core" ]

  after="$(cksum "$source_plan" | awk '{print $1" "$2}')"
  [ "$before" = "$after" ]
  [ ! -w "$source_plan" ]
  [ -w "$control" ]
}

@test "source hash mismatch and missing manifest block before control copy" {
  local run_id artifact source_plan manifest

  artifact="$(write_planner_v2_artifact)"
  export WORKFLOW_STATE_FIXED_NOW="2026-01-03T04:06:06Z"
  run_id="$(create_task_entry "$WSR_CASE")"
  source_plan="$(materialize_generated_plan "$run_id" "$artifact")"
  manifest="$WSR_CASE/workflow-runs/$run_id/plans/plan-implementation/attempt-1.manifest.json"

  run workflow_state_bind_generated_plan_control \
    --registry-run "$WSR_CASE/workflow-runs/$run_id" \
    --consumer-stage-id implement \
    --consumer-attempt 1 \
    --planner-stage-id plan-implementation \
    --planner-attempt 99
  [ "$status" -ne 0 ]
  [[ "$output" == *"missing generated-plan manifest"* ]]
  [ ! -e "$WSR_CASE/workflow-runs/$run_id/plans/implement/attempt-1/control.plan.md" ]

  # Stale hash: mutate source bytes after materialize (chmod first).
  chmod u+w "$source_plan"
  printf '\n# tampered\n' >>"$source_plan"
  run workflow_state_validate_generated_plan_evidence "$manifest" \
    --expect-planner-stage-id plan-implementation
  [ "$status" -ne 0 ]
  [[ "$output" == *"hash mismatch"* ]] || [[ "$output" == *"stale"* ]]
}

@test "same-plan resume reuses control copy and plan progress advances" {
  # shellcheck source=/dev/null
  source "$DEP_LIB"
  local run_id artifact source_plan binding1 binding2 control progress

  artifact="$(write_planner_v2_artifact)"
  export WORKFLOW_STATE_FIXED_NOW="2026-01-03T04:07:06Z"
  run_id="$(create_task_entry "$WSR_CASE")"
  source_plan="$(materialize_generated_plan "$run_id" "$artifact")"

  binding1="$(
    workflow_state_bind_generated_plan_control \
      --registry-run "$WSR_CASE/workflow-runs/$run_id" \
      --consumer-stage-id implement \
      --consumer-attempt 1 \
      --planner-stage-id plan-implementation \
      --planner-attempt 1
  )"
  control="$(printf '%s' "$binding1" | jq -r '.controlPlanPath')"

  # Simulate one completed TODO on the mutable control copy only.
  python3 - "$control" <<'PY'
import re
import sys
from pathlib import Path
p = Path(sys.argv[1])
text = p.read_text(encoding="utf-8")
text2, n = re.subn(
    r"(  - id: implement-core\n(?:.*\n)*?    status: )pending",
    r"\1completed",
    text,
    count=1,
)
assert n == 1, "failed to mark implement-core completed"
p.write_text(text2, encoding="utf-8")
PY

  binding2="$(
    workflow_state_bind_generated_plan_control \
      --registry-run "$WSR_CASE/workflow-runs/$run_id" \
      --consumer-stage-id implement \
      --consumer-attempt 1 \
      --planner-stage-id plan-implementation \
      --planner-attempt 1
  )"
  [ "$(printf '%s' "$binding2" | jq -r '.controlPlanPath')" = "$control" ]
  [ "$(printf '%s' "$binding2" | jq -r '.createdControl')" = "false" ]
  [ "$(printf '%s' "$binding2" | jq -r '.completedTodos')" = "1" ]
  [ "$(printf '%s' "$binding2" | jq -r '.currentTodoId')" = "verify-tests" ]

  progress="$(workflow_state_plan_progress_json "$control")"
  [ "$(printf '%s' "$progress" | jq -r '.completedTodos')" = "1" ]
  [ "$(printf '%s' "$progress" | jq -r '.totalTodos')" = "2" ]

  # Source plan/manifest unchanged (still all pending in immutable source).
  grep -q 'status: pending' "$source_plan"
  [ ! -w "$source_plan" ]
}

@test "Dependency planFrom dispatch projects control plan onto stub orchestrator argv" {
  # shellcheck source=/dev/null
  source "$DISPATCH_LIB"
  local run_id artifact binding orch graph_json control argv_joined

  artifact="$(write_planner_v2_artifact)"
  export WORKFLOW_STATE_FIXED_NOW="2026-01-03T04:08:06Z"
  run_id="$(create_task_entry "$WSR_CASE")"
  materialize_generated_plan "$run_id" "$artifact" >/dev/null

  graph_json="$WSR_CASE/planfrom.graph.json"
  orch="$WSR_CASE/planfrom.orch.json"
  cat >"$graph_json" <<'EOF'
{
  "name": "pf",
  "namespace": "pf",
  "nodes": [
    {
      "id": "implement",
      "type": "agent",
      "dependsOn": ["plan-implementation"],
      "derivedFrom": "stage",
      "planFromBinding": {
        "plannerStageId": "plan-implementation",
        "planSourceKind": "generated"
      },
      "stage": {
        "id": "implement",
        "runtime": "cursor",
        "model": "auto",
        "sessionStrategy": "fresh",
        "planFrom": "plan-implementation"
      }
    }
  ],
  "edges": []
}
EOF
  cat >"$orch" <<'EOF'
{
  "name": "pf",
  "namespace": "pf",
  "stages": [
    {
      "id": "implement",
      "runtime": "cursor",
      "model": "auto",
      "sessionStrategy": "fresh",
      "planFrom": "plan-implementation"
    }
  ]
}
EOF

  export GRAPH_DISPATCH_ORCHESTRATOR="$WSR_CASE/orch-stub.sh"
  printf '#!/bin/bash\nexit 0\n' >"$GRAPH_DISPATCH_ORCHESTRATOR"
  chmod +x "$GRAPH_DISPATCH_ORCHESTRATOR"

  binding="$(
    graph_dispatch_bind_planfrom_control \
      --graph-json "$graph_json" \
      --node-id implement \
      --orch-path "$orch" \
      --registry-run "$WSR_CASE/workflow-runs/$run_id" \
      --attempt-number 1 \
      --planner-attempt 1 \
      --plan-run-id "implement__test__1"
  )"
  control="$(printf '%s' "$binding" | jq -r '.controlPlanPath')"
  [ "$(jq -r '.stages[0].plan' "$orch")" = "$control" ]
  [ "$(jq -r '.stages[0] | has("planFrom")' "$orch")" = "false" ]
  [ "$(jq -r '.stages[0].sessionStrategy' "$orch")" = "fresh" ]
  [ "$(jq -r '.stages[0].runtime' "$orch")" = "cursor" ]
  [ "$(jq -r '.stages[0].model' "$orch")" = "auto" ]

  graph_dispatch_build_argv "$orch" implement "$run_id" "implement__${run_id}__1" "$WSR_CASE" "$WSR_CASE"
  argv_joined="${GRAPH_DISPATCH_ARGV[*]}"
  [[ "$argv_joined" == *"--single-stage implement"* ]]
  [[ "$argv_joined" == *"--orchestration $orch"* ]]
}

# --- Dependency provided plan (planInput) control copy / routing / reset ---

ROUTING_LIB="$REPO_ROOT/bundle/.ralph/bash-lib/workflow/workflow-routing.sh"

import_provided_for_case() {
  local run_id="$1"
  local plan_body="${2:-}"
  local plan_path source_path
  mkdir -p "$WSR_CASE/project/plans"
  if [[ -n "$plan_body" ]]; then
    plan_path="$(write_provided_leaf_plan "$WSR_CASE/project/plans/feature.plan.md" "$plan_body")"
  else
    plan_path="$(write_provided_leaf_plan "$WSR_CASE/project/plans/feature.plan.md")"
  fi
  workflow_state_import_provided_plan \
    --state-root "$WSR_CASE" \
    --run-id "$run_id" \
    --plan "$plan_path" \
    --project-root "$WSR_CASE/project" >/dev/null
  source_path="$WSR_CASE/workflow-runs/$run_id/plans/input/source.plan.md"
  printf '%s\n' "$source_path"
}

@test "Dependency provided plan control copy binds with source kind provided and null stage id" {
  # shellcheck source=/dev/null
  source "$DISPATCH_LIB"
  local run_id source_plan binding control before after original

  export WORKFLOW_STATE_FIXED_NOW="2026-01-04T01:00:00Z"
  run_id="$(create_plan_entry_for_import "$WSR_CASE")"
  source_plan="$(import_provided_for_case "$run_id")"
  original="$(jq -r '.originalPath' "$WSR_CASE/workflow-runs/$run_id/plans/input/manifest.json")"
  before="$(cksum "$source_plan" | awk '{print $1" "$2}')"
  before_orig="$(cksum "$original" | awk '{print $1" "$2}')"

  run workflow_state_bind_provided_plan_control \
    --registry-run "$WSR_CASE/workflow-runs/$run_id" \
    --consumer-stage-id implement \
    --consumer-attempt 1 \
    --plan-run-id "implement__${run_id}__1"
  [ "$status" -eq 0 ]
  binding="$output"
  control="$(printf '%s' "$binding" | jq -r '.controlPlanPath')"
  [[ "$control" == "$WSR_CASE/workflow-runs/$run_id/plans/implement/attempt-1/control.plan.md" ]]
  [ -f "$control" ]
  [ "$(printf '%s' "$binding" | jq -r '.planSourceKind')" = "provided" ]
  [ "$(printf '%s' "$binding" | jq -r '.planSourceStageId')" = "null" ]
  [ "$(printf '%s' "$binding" | jq -r '.sourcePlanPath')" = "$source_plan" ]
  [ "$(printf '%s' "$binding" | jq -r '.originalPlanPath')" = "$original" ]
  [ "$(printf '%s' "$binding" | jq -r '.createdControl')" = "true" ]
  [ "$(printf '%s' "$binding" | jq -r '.totalTodos')" = "3" ]
  [ "$(printf '%s' "$binding" | jq -r '.completedTodos')" = "1" ]
  [ "$(printf '%s' "$binding" | jq -r '.currentTodoId')" = "todo-2" ]

  after="$(cksum "$source_plan" | awk '{print $1" "$2}')"
  after_orig="$(cksum "$original" | awk '{print $1" "$2}')"
  [ "$before" = "$after" ]
  [ "$before_orig" = "$after_orig" ]
  [ ! -w "$source_plan" ]
  [ -w "$control" ]
}

@test "invalid input missing or corrupt provided plan blocks before control copy" {
  local run_id

  export WORKFLOW_STATE_FIXED_NOW="2026-01-04T01:01:00Z"
  run_id="$(create_plan_entry_for_import "$WSR_CASE")"

  run workflow_state_bind_provided_plan_control \
    --registry-run "$WSR_CASE/workflow-runs/$run_id" \
    --consumer-stage-id implement \
    --consumer-attempt 1
  [ "$status" -ne 0 ]
  [[ "$output" == *"invalid input"* ]] || [[ "$output" == *"missing"* ]]
  [ ! -e "$WSR_CASE/workflow-runs/$run_id/plans/implement/attempt-1/control.plan.md" ]

  import_provided_for_case "$run_id" >/dev/null
  chmod u+w "$WSR_CASE/workflow-runs/$run_id/plans/input/source.plan.md"
  printf '\n# corrupted\n' >>"$WSR_CASE/workflow-runs/$run_id/plans/input/source.plan.md"
  run workflow_state_validate_provided_plan_evidence \
    --registry-run "$WSR_CASE/workflow-runs/$run_id"
  [ "$status" -ne 0 ]
  [[ "$output" == *"invalid input"* ]]
  [ ! -e "$WSR_CASE/workflow-runs/$run_id/plans/implement/attempt-1/control.plan.md" ]
}

@test "same-plan resume reuses provided control copy and consumer reset force-fresh" {
  local run_id source_plan binding1 binding2 binding3 control1 control3 before after

  export WORKFLOW_STATE_FIXED_NOW="2026-01-04T01:02:00Z"
  run_id="$(create_plan_entry_for_import "$WSR_CASE")"
  source_plan="$(import_provided_for_case "$run_id")"
  before="$(cksum "$source_plan" | awk '{print $1" "$2}')"

  binding1="$(
    workflow_state_bind_provided_plan_control \
      --registry-run "$WSR_CASE/workflow-runs/$run_id" \
      --consumer-stage-id implement \
      --consumer-attempt 1
  )"
  control1="$(printf '%s' "$binding1" | jq -r '.controlPlanPath')"

  # Advance mutable control only.
  python3 - "$control1" <<'PY'
from pathlib import Path
import re, sys
p = Path(sys.argv[1])
text = p.read_text(encoding="utf-8")
text2, n = re.subn(r"- \[ \] implement the change", "- [x] implement the change", text, count=1)
assert n == 1
p.write_text(text2, encoding="utf-8")
PY

  binding2="$(
    workflow_state_bind_provided_plan_control \
      --registry-run "$WSR_CASE/workflow-runs/$run_id" \
      --consumer-stage-id implement \
      --consumer-attempt 1
  )"
  [ "$(printf '%s' "$binding2" | jq -r '.controlPlanPath')" = "$control1" ]
  [ "$(printf '%s' "$binding2" | jq -r '.createdControl')" = "false" ]
  [ "$(printf '%s' "$binding2" | jq -r '.completedTodos')" = "2" ]

  binding3="$(
    workflow_state_bind_provided_plan_control \
      --registry-run "$WSR_CASE/workflow-runs/$run_id" \
      --consumer-stage-id implement \
      --consumer-attempt 1 \
      --force-fresh
  )"
  control3="$(printf '%s' "$binding3" | jq -r '.controlPlanPath')"
  [ "$control3" = "$control1" ]
  [ "$(printf '%s' "$binding3" | jq -r '.createdControl')" = "true" ]
  [ "$(printf '%s' "$binding3" | jq -r '.completedTodos')" = "1" ]
  grep -q '\- \[ \] implement the change' "$control3"

  after="$(cksum "$source_plan" | awk '{print $1" "$2}')"
  [ "$before" = "$after" ]
  [ ! -w "$source_plan" ]
}

@test "Dependency provided plan routing order prefers stage over provided-plan header" {
  # shellcheck source=/dev/null
  source "$ROUTING_LIB"
  # shellcheck source=/dev/null
  source "$DISPATCH_LIB"
  local run_id source_plan orch binding

  export WORKFLOW_STATE_FIXED_NOW="2026-01-04T01:03:00Z"
  run_id="$(create_plan_entry_for_import "$WSR_CASE")"
  source_plan="$(import_provided_for_case "$run_id" "$(cat <<'EOF'
---
name: Provided Feature
overview: Ship it
runtime: claude
model: plan-header-model
todos:
  - id: one
    content: Do one
    verification: Check one
    status: pending
  - id: two
    content: Do two
    verification: Check two
    status: pending
---
EOF
)")"

  orch="$WSR_CASE/provided.orch.json"
  cat >"$orch" <<'EOF'
{
  "name": "pd",
  "namespace": "pd",
  "stages": [
    {
      "id": "implement",
      "runtime": "cursor",
      "model": "stage-model",
      "sessionStrategy": "fresh"
    }
  ]
}
EOF

  binding="$(
    workflow_state_bind_provided_plan_control \
      --registry-run "$WSR_CASE/workflow-runs/$run_id" \
      --consumer-stage-id implement \
      --consumer-attempt 1
  )"
  graph_dispatch_apply_provided_to_orch "$orch" implement \
    "$(printf '%s' "$binding" | jq -r '.controlPlanPath')"
  graph_dispatch_apply_provided_routing_order "$orch" implement "$source_plan"
  [ "$(jq -r '.stages[0].runtime' "$orch")" = "cursor" ]
  [ "$(jq -r '.stages[0].model' "$orch")" = "stage-model" ]

  # Clear stage pins so provided-plan header participates.
  jq '(.stages[0] |= (del(.runtime) | del(.model)))' "$orch" >"$orch.tmp" && mv "$orch.tmp" "$orch"
  graph_dispatch_apply_provided_routing_order "$orch" implement "$source_plan"
  [ "$(jq -r '.stages[0].runtime' "$orch")" = "claude" ]
  [ "$(jq -r '.stages[0].model' "$orch")" = "plan-header-model" ]
}

@test "Dependency provided plan dispatch projects control plan onto stub orchestrator argv" {
  # shellcheck source=/dev/null
  source "$DISPATCH_LIB"
  local run_id binding orch graph_json control argv_joined

  export WORKFLOW_STATE_FIXED_NOW="2026-01-04T01:04:00Z"
  run_id="$(create_plan_entry_for_import "$WSR_CASE")"
  import_provided_for_case "$run_id" >/dev/null

  graph_json="$WSR_CASE/provided.graph.json"
  orch="$WSR_CASE/provided-dispatch.orch.json"
  cat >"$graph_json" <<'EOF'
{
  "name": "pd",
  "namespace": "pd",
  "nodes": [
    {
      "id": "implement",
      "type": "agent",
      "dependsOn": [],
      "derivedFrom": "stage",
      "planInputBinding": {
        "planSourceKind": "provided",
        "planSourceStageId": null
      },
      "stage": {
        "id": "implement",
        "runtime": "cursor",
        "model": "auto",
        "sessionStrategy": "fresh"
      }
    }
  ],
  "edges": []
}
EOF
  cat >"$orch" <<'EOF'
{
  "name": "pd",
  "namespace": "pd",
  "stages": [
    {
      "id": "implement",
      "runtime": "cursor",
      "model": "auto",
      "sessionStrategy": "fresh"
    }
  ]
}
EOF

  export GRAPH_DISPATCH_ORCHESTRATOR="$WSR_CASE/orch-stub.sh"
  printf '#!/bin/bash\nexit 0\n' >"$GRAPH_DISPATCH_ORCHESTRATOR"
  chmod +x "$GRAPH_DISPATCH_ORCHESTRATOR"

  binding="$(
    graph_dispatch_bind_provided_plan_control \
      --graph-json "$graph_json" \
      --node-id implement \
      --orch-path "$orch" \
      --registry-run "$WSR_CASE/workflow-runs/$run_id" \
      --attempt-number 1 \
      --plan-run-id "implement__test__1"
  )"
  control="$(printf '%s' "$binding" | jq -r '.controlPlanPath')"
  [ "$(jq -r '.stages[0].plan' "$orch")" = "$control" ]
  [ "$(jq -r '.stages[0].sessionStrategy' "$orch")" = "fresh" ]
  [ "$(printf '%s' "$binding" | jq -r '.planSourceKind')" = "provided" ]
  [ "$(printf '%s' "$binding" | jq -r '.planSourceStageId')" = "null" ]

  graph_dispatch_build_argv "$orch" implement "$run_id" "implement__${run_id}__1" "$WSR_CASE" "$WSR_CASE"
  argv_joined="${GRAPH_DISPATCH_ARGV[*]}"
  [[ "$argv_joined" == *"--single-stage implement"* ]]
  [[ "$argv_joined" == *"--orchestration $orch"* ]]
}
