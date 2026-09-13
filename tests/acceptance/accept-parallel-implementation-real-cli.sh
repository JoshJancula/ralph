#!/usr/bin/env bash
# Real-CLI graph acceptance for GRAPH-ENGINEERING-V2 line 30.
#
# This is deliberately an operator-facing acceptance harness, not a Bats test:
# it uses the installed Claude, Codex, and OpenCode CLIs. It creates a clean
# Git fixture, runs the production graph scheduler, kills the scheduler once,
# resumes it, and preserves the fixture/ledger location in its stdout log.
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: bash tests/acceptance/accept-parallel-implementation-real-cli.sh --run-real-runtime-acceptance

This acceptance harness invokes authenticated Claude, Codex, and OpenCode
runtime CLIs and can consume LLM credits. It is intentionally excluded from
the normal Bats suite and refuses to run without this exact opt-in flag.
EOF
}

if [[ "${1:-}" != "--run-real-runtime-acceptance" || "$#" -ne 1 ]]; then
  usage >&2
  exit 2
fi

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
GRAPH_RUN="$REPO_ROOT/bundle/.ralph/graph-run.sh"
FIXTURE_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/ralph-real-cli-accept.XXXXXX")"
PROJECT="$FIXTURE_ROOT/project"
STATE="$FIXTURE_ROOT/state"
NAMESPACE="real-cli-parallel-accept"

cleanup_children() {
  if [[ -n "${RUN_PID:-}" ]] && kill -0 "$RUN_PID" 2>/dev/null; then
    kill -KILL "$RUN_PID" 2>/dev/null || true
  fi
  # Graph nodes run in supervisor-owned sessions so they survive an abrupt
  # scheduler death.  On an early harness failure, terminate only process
  # groups recorded under this disposable fixture rather than leaking real
  # CLI children into the operator's session.
  local process_run scope status pgid
  if [[ -d "$STATE/processes/active" ]]; then
    while IFS= read -r process_run; do
      status="$(jq -r '.status // empty' "$process_run" 2>/dev/null || true)"
      [[ "$status" == running ]] || continue
      while IFS= read -r scope; do
        pgid="$(jq -r 'select(.status == "running") | .session_id // empty' "$scope" 2>/dev/null || true)"
        if [[ "$pgid" =~ ^[0-9]+$ && "$pgid" -gt 1 ]]; then
          kill -TERM -- "-$pgid" 2>/dev/null || true
        fi
      done < <(find "$(dirname "$process_run")/scopes" -type f -name '*.json' -print 2>/dev/null || true)
    done < <(find "$STATE/processes/active" -mindepth 2 -maxdepth 2 -type f -name run.json -print 2>/dev/null || true)
  fi
}
trap cleanup_children EXIT

for runtime in claude codex opencode; do
  command -v "$runtime" >/dev/null 2>&1 || {
    echo "required runtime is unavailable: $runtime" >&2
    exit 1
  }
done

mkdir -p "$PROJECT" "$STATE" "$PROJECT/src/alpha" "$PROJECT/src/beta" "$PROJECT/src/gamma" "$PROJECT/plans" "$PROJECT/scripts"
# Prebuilt metadata is part of the source base; the supervisor stays pinned to
# the repository tooling tree by the graph scheduler.
cp -R "$REPO_ROOT/.claude" "$PROJECT/.claude"
cp -R "$REPO_ROOT/.codex" "$PROJECT/.codex"
cp -R "$REPO_ROOT/.opencode" "$PROJECT/.opencode"

cat >"$PROJECT/scripts/verify-alpha.sh" <<'SCRIPT'
#!/usr/bin/env bash
set -euo pipefail
# Intentional runner-owned first-attempt failure. Keep the marker in Ralph's
# state root so verifier state survives retries without contaminating the
# node's write-scoped product changeset.
marker="__RALPH_ACCEPT_STATE__/alpha-runner-failed-once"
if [[ ! -f "$marker" ]]; then
  : >"$marker"
  echo 'controlled first-attempt failure from runner-owned verification' >&2
  exit 1
fi
test "$(cat src/alpha/one.txt)" = alpha-one
SCRIPT
sed "s|__RALPH_ACCEPT_STATE__|$STATE|g" "$PROJECT/scripts/verify-alpha.sh" >"$PROJECT/scripts/verify-alpha.sh.next"
mv "$PROJECT/scripts/verify-alpha.sh.next" "$PROJECT/scripts/verify-alpha.sh"
cat >"$PROJECT/scripts/verify-beta.sh" <<'SCRIPT'
#!/usr/bin/env bash
set -euo pipefail
test "$(cat src/beta/one.txt)" = beta-one
SCRIPT
cat >"$PROJECT/scripts/verify-gamma.sh" <<'SCRIPT'
#!/usr/bin/env bash
set -euo pipefail
test "$(cat src/gamma/one.txt)" = gamma-one
SCRIPT
cat >"$PROJECT/scripts/global-gate.sh" <<'SCRIPT'
#!/usr/bin/env bash
set -euo pipefail
# Resolve the scheduler-owned integration result rather than guessing a
# workspace key. On regate the newest manifest names the reintegration node.
integration_manifest="$(ls -t "${RALPH_PLAN_WORKSPACE_ROOT:?}/artifacts/real-cli-parallel-accept/integration/"*.json | head -1)"
integration="$(jq -r '.workspacePath' "$integration_manifest")"
for item in alpha/one.txt:alpha-one alpha/two.txt:alpha-two beta/one.txt:beta-one beta/two.txt:beta-two gamma/one.txt:gamma-one gamma/two.txt:gamma-two; do
  path="${item%%:*}"; expected="${item#*:}"
  test "$(cat "$integration/src/$path")" = "$expected"
done
if [[ ! -f "${RALPH_PLAN_WORKSPACE_ROOT}/global-gate-failed-once" ]]; then
  : >"${RALPH_PLAN_WORKSPACE_ROOT}/global-gate-failed-once"
  echo 'controlled changes-required result for repair epoch' >&2
  exit 1
fi
SCRIPT
chmod +x "$PROJECT/scripts/verify-alpha.sh" "$PROJECT/scripts/verify-beta.sh" "$PROJECT/scripts/verify-gamma.sh" "$PROJECT/scripts/global-gate.sh"

cat >"$PROJECT/plans/alpha.plan.md" <<'PLAN'
---
todos:
  - id: alpha-first
    content: |
      Use one Ralph-controlled read-only native research helper to inspect this fixture, then as the parent create only src/alpha/one.txt containing exactly alpha-one. The helper must not edit or complete this TODO; you remain responsible for the edit and completion.
    verify: bash scripts/verify-alpha.sh
    status: pending
  - id: alpha-second
    content: Create only src/alpha/two.txt containing exactly alpha-two.
    verify: test "$(cat src/alpha/two.txt)" = alpha-two
    status: pending
---
PLAN
cat >"$PROJECT/plans/beta.plan.md" <<'PLAN'
---
todos:
  - id: beta-first
    content: Create only src/beta/one.txt containing exactly beta-one.
    verify: bash scripts/verify-beta.sh
    status: pending
  - id: beta-second
    content: Create only src/beta/two.txt containing exactly beta-two.
    verify: test "$(cat src/beta/two.txt)" = beta-two
    status: pending
---
PLAN
cat >"$PROJECT/plans/gamma.plan.md" <<'PLAN'
---
todos:
  - id: gamma-first
    content: Create only src/gamma/one.txt containing exactly gamma-one.
    verify: bash scripts/verify-gamma.sh
    status: pending
  - id: gamma-second
    content: Create only src/gamma/two.txt containing exactly gamma-two.
    verify: test "$(cat src/gamma/two.txt)" = gamma-two
    status: pending
---
PLAN

cat >"$PROJECT/accept.plan.md" <<'PLAN'
---
name: real-cli-parallel-accept
namespace: real-cli-parallel-accept
execution: graph
pipeline:
  maxParallel: 4
  edgeDerivation: declared
  strictEdges: false
  failurePolicy: drain
  publishMode: manual
  verificationProfiles:
    - name: global
      steps:
        - name: all-three-integrated
          command: bash scripts/global-gate.sh
          timeout: 60
          continueOnFailure: false
          requiredArtifacts: []
  stages:
    - id: alpha
      runtime: claude
      model: claude-sonnet-4-6
      agent: implementation
      planFile: plans/alpha.plan.md
      workspaceMode: snapshot
      agentGitAccess: off
      writeScopes: [src/alpha/**]
      produces:
        - path: src/alpha/two.txt
      subagents: on
      delegation:
        maxChildren: 1
        native:
          mode: read-only
          allowedAgents: [research]
          maxParallel: 1
        crossRuntime:
          mode: off
    - id: beta
      runtime: codex
      model: gpt-5.6-terra
      agent: implementation
      planFile: plans/beta.plan.md
      workspaceMode: snapshot
      agentGitAccess: off
      writeScopes: [src/beta/**]
      produces:
        - path: src/beta/two.txt
    - id: gamma
      runtime: opencode
      model: ollama-cloud/kimi-k2.7-code
      agent: implementation
      planFile: plans/gamma.plan.md
      workspaceMode: snapshot
      agentGitAccess: off
      writeScopes: [src/gamma/**]
      produces:
        - path: src/gamma/two.txt
  repairRounds:
    id: repair
    rounds: 1
    dependsOn: [alpha, beta, gamma]
    integrate:
      workspaceMode: snapshot
    gate:
      profile: global
    diagnose:
      runtime: claude
      model: claude-sonnet-4-6
      agent: implementation
      content: Confirm the controlled global gate requested the one bounded repair epoch; do not edit files.
    lanes:
      - id: alpha
        runtime: claude
        model: claude-sonnet-4-6
        agent: implementation
        planFile: plans/alpha.plan.md
        workspaceMode: snapshot
        agentGitAccess: off
        writeScopes: [src/alpha/**]
        content: Recreate only src/alpha/one.txt as alpha-one and src/alpha/two.txt as alpha-two for the bounded repair epoch.
      - id: beta
        runtime: codex
        model: gpt-5.6-terra
        agent: implementation
        planFile: plans/beta.plan.md
        workspaceMode: snapshot
        agentGitAccess: off
        writeScopes: [src/beta/**]
        content: Recreate only src/beta/one.txt as beta-one and src/beta/two.txt as beta-two for the bounded repair epoch.
      - id: gamma
        runtime: opencode
        model: ollama-cloud/kimi-k2.7-code
        agent: implementation
        planFile: plans/gamma.plan.md
        workspaceMode: snapshot
        agentGitAccess: off
        writeScopes: [src/gamma/**]
        content: Recreate only src/gamma/one.txt as gamma-one and src/gamma/two.txt as gamma-two for the bounded repair epoch.
    reintegrate:
      workspaceMode: snapshot
todos: []
---
PLAN

git -C "$PROJECT" init -q
git -C "$PROJECT" add .
git -C "$PROJECT" -c user.name=Ralph -c user.email=ralph@example.invalid commit -qm fixture
CALLER_HEAD="$(git -C "$PROJECT" rev-parse HEAD)"
CALLER_STATUS="$(git -C "$PROJECT" status --porcelain=v1 --untracked-files=all)"

echo "fixture=$FIXTURE_ROOT"
echo "runtime_versions: $(claude --version | head -1) | $(codex --version 2>&1 | tail -1) | $(opencode --version | head -1)"
echo "starting production graph run"
(
  cd "$REPO_ROOT"
  # Do not inherit a launcher PID from the operator's outer runner.  Each
  # run-plan invocation must watch its direct orchestration parent so the
  # planned first-run kill is recoverable and the resumed scheduler is not
  # reaped by a stale launcher watchdog.
  env -u RALPH_AGENT_TOOL_ACCESS -u RALPH_NATIVE_HOOKS -u RALPH_LAUNCHER_PID RALPH_MODE=native \
  RALPH_PROJECT_ROOT="$PROJECT" RALPH_PLAN_WORKSPACE_ROOT="$STATE" RALPH_AGENT_WORKSPACE="$PROJECT" \
  RALPH_VERIFY_TRUST_AGENT_PASS=0 RALPH_AGENT_NATIVE_PASSTHROUGH=0 RALPH_CONFIG_HOME="$STATE/config" RALPH_WORKSPACES_FILE="$STATE/config/workspaces.json" RALPH_GRAPH_MAX_PARALLEL_PER_RUNTIME=2 RALPH_PLAN_NO_CAFFEINATE=1 \
  bash "$GRAPH_RUN" run "$PROJECT/accept.plan.md" --namespace "$NAMESPACE" --max-parallel 4
) >"$FIXTURE_ROOT/first-run.log" 2>&1 &
RUN_PID=$!

deadline=$((SECONDS + 300))
all_lanes_running=0
while [[ $SECONDS -lt $deadline ]]; do
  run_dir="$(find "$STATE/graph-runs/$NAMESPACE" -mindepth 1 -maxdepth 1 -type d -name 'run-*' -print 2>/dev/null | sort | tail -1 || true)"
  if [[ -n "$run_dir" ]] \
    && jq -e '.status == "running"' "$run_dir/nodes/alpha.json" >/dev/null 2>&1 \
    && jq -e '.status == "running"' "$run_dir/nodes/beta.json" >/dev/null 2>&1 \
    && jq -e '.status == "running"' "$run_dir/nodes/gamma.json" >/dev/null 2>&1; then
    all_lanes_running=1
    break
  fi
  sleep 1
done
if [[ "$all_lanes_running" -ne 1 ]]; then
  echo "all three lanes did not reach durable running state before the planned kill" >&2
  cat "$FIXTURE_ROOT/first-run.log" >&2
  exit 1
fi
if ! kill -0 "$RUN_PID" 2>/dev/null; then
  echo "graph scheduler exited before planned mid-lane kill" >&2
  cat "$FIXTURE_ROOT/first-run.log" >&2
  exit 1
fi
echo "killing scheduler pid=$RUN_PID while alpha is running"
kill -KILL "$RUN_PID"
wait "$RUN_PID" 2>/dev/null || true
unset RUN_PID

# The scheduler deliberately launches each node in an independent process
# group.  Let those already-running lanes finish and write their durable
# StageOutcomeReports before resuming; otherwise an immediate resume would
# correctly treat the report-less attempts as dead and dispatch duplicates.
run_id="$(basename "$run_dir")"
test -n "$run_id"
deadline=$((SECONDS + 1800))
while [[ $SECONDS -lt $deadline ]]; do
  reports_ready=1
  for lane in alpha beta gamma; do
    attempt_id="$(jq -r '.lastAttemptId // empty' "$run_dir/nodes/$lane.json")"
    report="$STATE/artifacts/$NAMESPACE/stage-outcomes/$attempt_id.json"
    if [[ -z "$attempt_id" || ! -s "$report" ]]; then
      reports_ready=0
      break
    fi
  done
  [[ "$reports_ready" -eq 1 ]] && break
  sleep 2
done
if [[ "${reports_ready:-0}" -ne 1 ]]; then
  echo "in-flight lanes did not emit durable reports after scheduler death" >&2
  exit 1
fi
for lane in alpha beta gamma; do
  attempt_id="$(jq -r '.lastAttemptId' "$run_dir/nodes/$lane.json")"
  jq -e '.outcome == "success"' "$STATE/artifacts/$NAMESPACE/stage-outcomes/$attempt_id.json" >/dev/null
done
echo "resuming run_id=$run_id"
(
  cd "$REPO_ROOT"
  env -u RALPH_AGENT_TOOL_ACCESS -u RALPH_NATIVE_HOOKS -u RALPH_LAUNCHER_PID RALPH_MODE=native \
  RALPH_PROJECT_ROOT="$PROJECT" RALPH_PLAN_WORKSPACE_ROOT="$STATE" RALPH_AGENT_WORKSPACE="$PROJECT" \
  RALPH_VERIFY_TRUST_AGENT_PASS=0 RALPH_AGENT_NATIVE_PASSTHROUGH=0 RALPH_CONFIG_HOME="$STATE/config" RALPH_WORKSPACES_FILE="$STATE/config/workspaces.json" RALPH_GRAPH_MAX_PARALLEL_PER_RUNTIME=2 RALPH_PLAN_NO_CAFFEINATE=1 \
  bash "$GRAPH_RUN" resume "$PROJECT/accept.plan.md" --namespace "$NAMESPACE" --run "$run_id"
) >"$FIXTURE_ROOT/resume.log" 2>&1

run_dir="$STATE/graph-runs/$NAMESPACE/$run_id"
test "$(jq -r .status "$run_dir/run.json")" = succeeded
test "$(jq '[.attempts[] | select(.attemptId | startswith("alpha__"))] | length' "$run_dir/nodes/alpha.json")" -eq 2
test "$(find "$run_dir/workspaces/nodes" -name .git -print | wc -l | tr -d ' ')" = 0
test "$(git -C "$PROJECT" rev-parse HEAD)" = "$CALLER_HEAD"
test "$(git -C "$PROJECT" status --porcelain=v1 --untracked-files=all)" = "$CALLER_STATUS"
# Single-stage usage capture must stay under the configured state/log root;
# a positional-argument regression once wrote stage indexes into the tooling
# checkout as files named 0, 1, and 2.
test ! -e "$REPO_ROOT/0"
test ! -e "$REPO_ROOT/1"
test ! -e "$REPO_ROOT/2"
for lane in alpha beta gamma; do
  jq -e --arg lane "$lane" '.nodeId == $lane and .workspaceMode == "snapshot" and (.writeScopes | length == 1)' "$run_dir/changesets/nodes/$lane.json" >/dev/null
done
test "$(jq -r .outcome "$STATE/artifacts/$NAMESPACE/gate/repair-gate/gate-result.json")" = passed
test "$(jq -r .publishMode "$run_dir/run.json")" = manual
test ! -d "$run_dir/nodes/alpha/delegations"

(
  cd "$REPO_ROOT"
  bats tests/bats/graph/graph-workspace-manager.bats --filter 'worktree creates detached parallel workspaces'
) >"$FIXTURE_ROOT/worktree-characterization.log" 2>&1

echo "acceptance passed"
echo "run_dir=$run_dir"
echo "first_run_log=$FIXTURE_ROOT/first-run.log"
echo "resume_log=$FIXTURE_ROOT/resume.log"
echo "worktree_characterization=$FIXTURE_ROOT/worktree-characterization.log"
