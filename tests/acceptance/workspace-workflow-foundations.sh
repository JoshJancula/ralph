#!/usr/bin/env bash
# Seven acceptance journeys for workspace order and workflow foundations.
# Uses only Ralph CLI commands and library functions against mktemp fixture
# state roots. No agent runtimes and no workflow executions.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
NS="${RALPH_ARTIFACT_NS:-${RALPH_PLAN_KEY:-workspace-order-and-workflow-foundations.plan}}"
ARTIFACT_DIR="$REPO_ROOT/.ralph-workspace/artifacts/$NS"
HANDOFF="$ARTIFACT_DIR/handoff.md"
CHECKER="$REPO_ROOT/scripts/check-state-layout.sh"
FIXTURE_GENERATOR="$REPO_ROOT/tests/fixtures/state-layout/generate-fixtures.sh"
STATE_CLI="$REPO_ROOT/bundle/.ralph/bash-lib/state-cli.sh"
LIB="$REPO_ROOT/bundle/.ralph/bash-lib"

mkdir -p "$ARTIFACT_DIR"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/ralph-acceptance-foundations.XXXXXX")"
cleanup() {
  chmod -R u+w "$TMP" 2>/dev/null || true
  rm -rf "$TMP" 2>/dev/null || true
}
trap cleanup EXIT

# shellcheck source=../../bundle/.ralph/bash-lib/plan-todo.sh
source "$LIB/plan-todo.sh"
# shellcheck source=../../bundle/.ralph/bash-lib/state-paths.sh
source "$LIB/state-paths.sh"
# shellcheck source=../../bundle/.ralph/bash-lib/retention.sh
source "$LIB/retention.sh"
# shellcheck source=../../bundle/.ralph/bash-lib/workflow/workflow-operator-view.sh
source "$LIB/workflow/workflow-operator-view.sh"
# shellcheck source=../../bundle/.ralph/bash-lib/graph/graph-state.sh
source "$LIB/graph/graph-state.sh"
# shellcheck source=../../bundle/.ralph/bash-lib/graph/graph-run-base.sh
source "$LIB/graph/graph-run-base.sh"
# shellcheck source=../../bundle/.ralph/bash-lib/graph/graph-workspace-manager.sh
source "$LIB/graph/graph-workspace-manager.sh"
# shellcheck source=../../bundle/.ralph/bash-lib/graph/graph-changeset.sh
source "$LIB/graph/graph-changeset.sh"

REPORT="$TMP/report.md"
: >"$REPORT"
fail=0

section() { printf '\n## %s\n\n' "$1" >>"$REPORT"; }
note() { printf '%s\n' "$1" >>"$REPORT"; }

require() {
  local desc="$1"
  shift
  if "$@"; then
    note "PASS: $desc"
  else
    note "FAIL: $desc"
    fail=1
  fi
}

realpath_dir() {
  local path="$1"
  if [[ -d "$path" ]]; then
    (cd "$path" && pwd -P)
  elif [[ -e "$path" ]]; then
    local parent base
    parent="$(cd "$(dirname -- "$path")" && pwd -P)"
    base="$(basename -- "$path")"
    printf '%s/%s\n' "$parent" "$base"
  else
    printf '%s\n' "$path"
  fi
}

paths_equal() {
  [[ "$(realpath_dir "$1")" == "$(realpath_dir "$2")" ]]
}

json_file_count() {
  printf '%s' "$1" | jq -r '[.categories[].fileCount] | add // 0'
}

json_byte_count() {
  printf '%s' "$1" | jq -r '[.categories[].bytes] | add // 0'
}

compile_workflow() {
  local name="$1"
  local source_workflow="$2"
  local out="$TMP/${name}.plan.md"
  local graph="$TMP/${name}.graph.json"
  if [[ -f "$graph" ]]; then
    printf '%s\n' "$graph"
    return 0
  fi
  if grep -q '^planInput:' "$source_workflow"; then
    printf -- '- [ ] supplied\n' >"$TMP/${name}.src.plan.md"
    plan_workflow_instantiate_provided "$source_workflow" "acceptance task" "$out" \
      "provided_plan_path=$TMP/${name}.src.plan.md" \
      fallback_runtime=cursor fallback_model=auto >/dev/null
  else
    plan_workflow_instantiate "$source_workflow" "acceptance task" "$out" \
      fallback_runtime=cursor fallback_model=auto >/dev/null
  fi
  plan_pipeline_graph_json "$out" >"$graph"
  printf '%s\n' "$graph"
}

# ---------------------------------------------------------------------------
section "Acceptance journeys overview"
note "Fixture roots under: $TMP"
note "No agent runtimes; no workflow executions; compile + CLI + library only."

bash "$FIXTURE_GENERATOR" "$TMP/fixtures"
V1="$TMP/fixtures/v1"
MIXED="$TMP/fixtures/mixed"

# Prefetch compiles in the background so journeys 5-7 stay cheap.
(
  compile_workflow feature-delivery "$REPO_ROOT/bundle/.ralph/workflows/feature-delivery.workflow.md" >/dev/null
  compile_workflow bug-fix "$REPO_ROOT/bundle/.ralph/workflows/bug-fix.workflow.md" >/dev/null
  compile_workflow refactor "$REPO_ROOT/bundle/.ralph/workflows/refactor.workflow.md" >/dev/null
  compile_workflow plan-delivery "$REPO_ROOT/bundle/.ralph/workflows/plan-delivery.workflow.md" >/dev/null
  compile_workflow human-verified-delivery "$REPO_ROOT/bundle/.ralph/workflows/human-verified-delivery.workflow.md" >/dev/null
  compile_workflow small-feature "$REPO_ROOT/bundle/.ralph/workflows/small-feature-delivery.workflow.md" >/dev/null
  zero_wf="$TMP/feature-delivery.qa0.workflow.md"
  sed 's/maxQaRepairRounds: 1/maxQaRepairRounds: 0/' \
    "$REPO_ROOT/bundle/.ralph/workflows/feature-delivery.workflow.md" >"$zero_wf"
  compile_workflow feature-delivery-qa0 "$zero_wf" >/dev/null
) &
COMPILE_PID=$!

# ---------------------------------------------------------------------------
section "1. Filesystem entry point (task, current work, outputs, failed checks, logs)"

export RALPH_STATE_LAYOUT=2
mkdir -p "$TMP/nav/artifacts/demo" "$TMP/nav/runs"
printf 'shipped\n' >"$TMP/nav/artifacts/demo/handoff.md"
ralph_state_catalog_update "$TMP/nav" nav-run \
  '.runKind = "plan" | .status = "failed" | .task = "acceptance navigation" | .artifactNamespace = "demo" | .stages = [{stageId:"plan",attemptId:"nav-run",status:"failed"}]'
attempt_dir="$(ralph_state_attempt_dir "$TMP/nav" nav-run plan nav-run)"
mkdir -p "$attempt_dir/manual-verification"
printf 'check failed: sample\n' >"$attempt_dir/manual-verification/failed-check.log"
printf 'attempt log\n' >"$attempt_dir/output.log"
ralph_state_catalog_update "$TMP/nav" nav-run '.status = "failed"'

root_readme="$TMP/nav/README.md"
run_readme="$TMP/nav/runs/nav-run/README.md"
require "state-root README exists" test -f "$root_readme"
require "run README exists" test -f "$run_readme"
require "run README names the task" grep -Fq "Task: acceptance navigation" "$run_readme"
require "run README links artifacts" grep -Fq "artifacts/demo" "$run_readme"
require "run README surfaces failed check" grep -Fq "failed-check.log" "$run_readme"

runs_out="$(env RALPH_PLAN_WORKSPACE_ROOT="$TMP/nav" bash "$STATE_CLI" runs)"
require "ralph state runs lists nav-run" grep -Fq "nav-run" <<<"$runs_out"
show_out="$(env RALPH_PLAN_WORKSPACE_ROOT="$TMP/nav" bash "$STATE_CLI" show nav-run)"
require "ralph state show reports evidence" grep -Fq "evidence:" <<<"$show_out"

failure_rel="$(grep -E 'failed-check\.log|manual-verification/' "$run_readme" | head -n1 | sed -E 's/.*\]\(([^)]+)\).*/\1/' || true)"
if [[ -z "$failure_rel" ]]; then
  failure_rel="runs/nav-run/stages/plan/attempts/nav-run/manual-verification/failed-check.log"
fi
note "Path a user follows to reach failure output:"
note "1. Open state-root README.md -> runs/nav-run/README.md"
note "2. Under Verification, follow: $failure_rel"
note "3. Or: ralph state show nav-run (evidence markers), then open the attempt manual-verification/ tree"

# ---------------------------------------------------------------------------
section "2. Old and new runs coexist; layout recorded; external roots preserve contracts"

layout_v1="$(ralph_state_run_layout "$V1" plan-1 2>/dev/null || printf '1')"
layout_mixed="$(ralph_state_run_layout "$MIXED" run-2)"
require "v1 fixture resolves as layout 1" test "$layout_v1" = "1"
require "mixed catalog resolves as layout 2" test "$layout_mixed" = "2"

wf_v2="$(ralph_state_workflow_run_dir "$MIXED" run-2)"
require "layout-2 workflow engine path" \
  paths_equal "$wf_v2" "$MIXED/runs/run-2/engine/workflow"

export RALPH_STATE_LAYOUT=1
plan_v1="$(ralph_state_plan_attempt_dir "$V1" demo plan-1 plan plan-1)"
require "RALPH_STATE_LAYOUT=1 keeps pre-plan attempt path" \
  paths_equal "$plan_v1" "$V1/logs/demo/runs/plan-1"
unset RALPH_STATE_LAYOUT

external="$TMP/external state root"
mkdir -p "$external"
cp -R "$MIXED/." "$external/"
ext_wf="$(ralph_state_workflow_run_dir "$external" run-2)"
require "external state root preserves three-root contracts" \
  paths_equal "$ext_wf" "$external/runs/run-2/engine/workflow"

# ---------------------------------------------------------------------------
section "3. Cleanup preview explains removals; intermediate exits preserve outer evidence"

before_files="$(find "$V1" -type f | wc -l | tr -d ' ')"
prune_out="$(env RALPH_PLAN_WORKSPACE_ROOT="$V1" bash "$STATE_CLI" prune)"
after_files="$(find "$V1" -type f | wc -l | tr -d ' ')"
require "prune preview is read-only" test "$before_files" = "$after_files"
require "prune preview reports totals" grep -Fq "total" <<<"$prune_out"
orphans_out="$(env RALPH_PLAN_WORKSPACE_ROOT="$V1" bash "$STATE_CLI" orphans)"
require "orphans reports unclassified mystery" grep -Fq "mystery" <<<"$orphans_out"
require "orphans never eligible note" grep -Fq "never eligible" <<<"$orphans_out"

live="$TMP/live-evidence"
mkdir -p "$live/workflow-runs/live" "$live/graph-runs/shared/live" "$live/artifacts/shared"
jq -n '{state:"running",artifactNamespace:"shared",engine:{statePath:"'"$live"'/graph-runs/shared/live"}}' \
  >"$live/workflow-runs/live/run.json"
jq -n '{kind:"graph",status:"running",registryRunPath:"'"$live"'/workflow-runs/live"}' \
  >"$live/graph-runs/shared/live/run.json"
printf 'verdict\n' >"$live/artifacts/shared/qa-verdict.json"
elig="$(ralph_retention_eligibility "$live" artifact "$live/artifacts/shared" shared || true)"
require "live workflow artifacts are nonterminal-protected" \
  test "$elig" = "nonterminal-workflow-run"
require "outer evidence still present after eligibility check" \
  test -f "$live/artifacts/shared/qa-verdict.json"

# ---------------------------------------------------------------------------
section "4. Compacted terminal candidates: reconstruct identity; equivalent-fixture before/after"

comp="$TMP/compaction"
project="$comp/project"
state="$comp/state"
run_a="$state/graph-runs/compaction/run-a"
run_b="$state/graph-runs/compaction/run-b"
graph="$comp/graph.json"
mkdir -p "$project/src" "$state" "$project/.ralph"
jq -cn '{schemaVersion:1,retention:"prune",setupProfiles:{}}' >"$project/.ralph/graph-workspaces.json"
printf 'keep\n' >"$project/src/keep.txt"
printf 'delete-me\n' >"$project/src/delete.txt"
git init -q "$project"
git -C "$project" add .
git -C "$project" -c user.name=Ralph -c user.email=ralph@example.invalid commit -qm fixture
jq -cn \
  '{schemaVersion:1,ralphVersion:"test",name:"compaction",
    namespace:"compaction",maxParallel:1,failurePolicy:"drain",
    nodes:[{id:"build",type:"agent",dependsOn:[],derivedFrom:"stage",
      stage:{id:"build",runtime:"cursor",agent:"implementation",
             workspaceMode:"snapshot",writeScopes:["src/**","new.txt","link.txt","bulk/**"]}}],
    edges:[]}' >"$graph"
mkdir -p "$run_a"
jq -cn '{schemaVersion:1,kind:"graph",ralphVersion:"test",runId:"run-a",
         namespace:"compaction",status:"running"}' >"$run_a/run.json"
graph_run_base_prepare "$run_a" \
  "$(jq -cn --arg project "$project" --arg state "$state" --arg agent "$project" \
    '{projectRoot:$project,stateRoot:$state,agentWorkspace:$agent}')" \
  '["snapshot"]'
graph_workspace_prepare_run "$run_a" "$graph"
path_a="$(graph_workspace_prepare_node "$run_a" "$graph" build)"
graph_changeset_capture_baseline "$run_a" "$graph" build a1 "$path_a"
# Large payload only in the live workspace so cleanup shows clear before/after.
mkdir -p "$path_a/bulk"
i=0
while [[ $i -lt 16 ]]; do
  i=$((i + 1))
  python3 -c 'import sys; sys.stdout.buffer.write(b"x"*8192)' >"$path_a/bulk/file-$i.bin"
done
rm -f "$path_a/src/delete.txt"
chmod 755 "$path_a/src/keep.txt" 2>/dev/null || true
printf 'new file\n' >"$path_a/new.txt"
ln -sf new.txt "$path_a/link.txt"
printf 'edited keep\n' >"$path_a/src/keep.txt"
graph_changeset_capture_node "$run_a" "$graph" build a1 "$path_a" "$state"

mkdir -p "$run_b"
cp -a "$run_a"/. "$run_b"/
run_b="$(cd "$run_b" && pwd -P)"
key="$(graph_workspace_node_key build)"
path_b="$run_b/workspaces/nodes/$key"
jq --arg run run-b --arg source "$run_b/base/source" --arg manifest "$run_b/base/manifest.json" \
  '.runId = $run | .sourceBase.sourcePath = $source | .sourceBase.manifestPath = $manifest' \
  "$run_b/run.json" >"$run_b/run.tmp"
mv "$run_b/run.tmp" "$run_b/run.json"
jq --arg owner run-b --arg path "$path_b" \
  '.ownerRunId = $owner | .workspacePath = $path' \
  "$run_b/workspaces/metadata/$key.json" >"$run_b/workspaces/metadata/$key.json.tmp"
mv "$run_b/workspaces/metadata/$key.json.tmp" "$run_b/workspaces/metadata/$key.json"

before_json="$(bash "$CHECKER" --root "$state" --json)"
before_count="$(json_file_count "$before_json")"
before_bytes="$(json_byte_count "$before_json")"
note "equivalent-fixture before (check-state-layout.sh --json): files=$before_count bytes=$before_bytes"
note "before json: $before_json"

jq '.status = "succeeded"' "$run_a/run.json" >"$run_a/run.tmp"; mv "$run_a/run.tmp" "$run_a/run.json"
jq '.status = "succeeded"' "$run_b/run.json" >"$run_b/run.tmp"; mv "$run_b/run.tmp" "$run_b/run.json"
graph_workspace_cleanup_run "$run_a"
graph_workspace_cleanup_run "$run_b"

after_json="$(bash "$CHECKER" --root "$state" --json)"
after_count="$(json_file_count "$after_json")"
after_bytes="$(json_byte_count "$after_json")"
note "equivalent-fixture after (check-state-layout.sh --json): files=$after_count bytes=$after_bytes"
note "after json: $after_json"

require "reconstruction bundle present for run-a" \
  test -f "$run_a/workspaces/changesets/$key.reconstruction.json"
require "reconstruction bundle present for run-b" \
  test -f "$run_b/workspaces/changesets/$key.reconstruction.json"
require "workspace nodes removed after compaction" test ! -e "$path_a"
require "file count improved on repeated-run fixture" test "$after_count" -lt "$before_count"
require "byte count improved on repeated-run fixture" test "$after_bytes" -lt "$before_bytes"

recon_identity="$(jq -r '.workspaceIdentity // empty' "$run_a/workspaces/changesets/$key.reconstruction.json")"
require "reconstruction records a workspace identity" test -n "$recon_identity"

# ---------------------------------------------------------------------------
wait "$COMPILE_PID"

section "5. Full delivery workflows remain; review/QA bind candidates"

DELIVERY=(feature-delivery bug-fix refactor plan-delivery human-verified-delivery)
for name in "${DELIVERY[@]}"; do
  wf="$REPO_ROOT/bundle/.ralph/workflows/${name}.workflow.md"
  require "bundled workflow present: $name" test -f "$wf"
  g="$(compile_workflow "$name" "$wf")"
  require "$name review binds implement" \
    jq -e '([.nodes[] | select(.id == "review") | .stage.candidateFrom] | .[0] == "implement")' "$g" >/dev/null
  require "$name qa binds integrate" \
    jq -e '([.nodes[] | select(.id == "qa") | .stage.candidateFrom] | .[0] == "integrate")' "$g" >/dev/null
done

# ---------------------------------------------------------------------------
section "6. Bounded review/QA repair; logical stages; exhaustion edges"

fd_graph="$(compile_workflow feature-delivery "$REPO_ROOT/bundle/.ralph/workflows/feature-delivery.workflow.md")"
node_count="$(jq '.nodes | length' "$fd_graph")"
zero_graph="$(compile_workflow feature-delivery-qa0 "$TMP/feature-delivery.qa0.workflow.md")"
zero_count="$(jq '.nodes | length' "$zero_graph")"
added=$((node_count - zero_count))
expected=10
require "QA repair adds $expected nodes (got $added; total=$node_count zero=$zero_count)" \
  test "$added" -eq "$expected"
require "final QA round has no changes-required edge" \
  jq -e '([.edges[] | select(.from == "qa-q1" and .condition == "changes-required")] | length) == 0' "$fd_graph" >/dev/null

projected="$(workflow_operator_project_logical_stages "$(cat "$fd_graph")" '{}')"
require "logical stages project implement/review/qa" \
  jq -e '([.stages[].id] | index("implement") != null) and ([.stages[].id] | index("review") != null)' <<<"$projected" >/dev/null

# ---------------------------------------------------------------------------
section "7. Small-feature delivery uses fewer coordination stages"

small_graph="$(compile_workflow small-feature "$REPO_ROOT/bundle/.ralph/workflows/small-feature-delivery.workflow.md")"
feature_graph="$fd_graph"
small_authored="$(jq '[.nodes[] | select(.derivedFrom == "stage")] | length' "$small_graph")"
feature_authored="$(jq '[.nodes[] | select(.derivedFrom == "stage")] | length' "$feature_graph")"
small_nodes="$(jq '.nodes | length' "$small_graph")"
feature_nodes="$(jq '.nodes | length' "$feature_graph")"
note "compiled stage counts (authored derivedFrom=stage): small-feature-delivery=$small_authored feature-delivery=$feature_authored"
note "compiled node counts (full expanded graph): small-feature-delivery=$small_nodes feature-delivery=$feature_nodes"
require "small-feature has five authored stages" test "$small_authored" -eq 5
require "feature-delivery has more authored stages than small-feature" \
  test "$feature_authored" -gt "$small_authored"
require "small-feature expanded graph is smaller" test "$small_nodes" -lt "$feature_nodes"
require "evaluate binds implement with candidateFrom" \
  jq -e '([.nodes[] | select(.id == "evaluate") | .stage.candidateFrom] | .[0] == "implement")' "$small_graph" >/dev/null
require "verdict-gate is a model-free gate" \
  jq -e '([.nodes[] | select(.id == "verdict-gate" and .type == "gate")] | length) == 1' "$small_graph" >/dev/null

# ---------------------------------------------------------------------------
section "Summary"
if [[ "$fail" -eq 0 ]]; then
  note "All seven acceptance journeys passed."
else
  note "One or more acceptance checks failed (fail=$fail)."
fi

cp "$REPORT" "$HANDOFF"
note "Wrote report: $HANDOFF"
cat "$REPORT"

exit "$fail"
