#!/usr/bin/env bash
# Real-CLI cross-runtime delegation, jury, and guarded-publish acceptance.
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: bash tests/acceptance/accept-cross-runtime-real-cli.sh --run-real-runtime-acceptance

This acceptance harness invokes authenticated Claude, Codex, OpenCode, and
Cursor runtime CLIs and can consume LLM credits. It is intentionally excluded
from the normal Bats suite and refuses to run without this exact opt-in flag.
EOF
}

if [[ "${1:-}" != "--run-real-runtime-acceptance" || "$#" -ne 1 ]]; then
  usage >&2
  exit 2
fi

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
GRAPH_RUN="$REPO_ROOT/bundle/.ralph/graph-run.sh"
FIXTURE_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/ralph-delegation-accept.XXXXXX")"
PROJECT="$FIXTURE_ROOT/project"
STATE="$FIXTURE_ROOT/state"
NAMESPACE="real-cli-delegation-accept"

cleanup_children() {
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

for runtime in claude codex opencode cursor-agent; do
  command -v "$runtime" >/dev/null 2>&1 || {
    echo "required runtime is unavailable: $runtime" >&2
    exit 1
  }
done

mkdir -p "$PROJECT/src/delegated" "$PROJECT/src/parent" "$PROJECT/scripts" "$STATE/config"
cp -R "$REPO_ROOT/.claude" "$PROJECT/.claude"
cp -R "$REPO_ROOT/.codex" "$PROJECT/.codex"
cp -R "$REPO_ROOT/.cursor" "$PROJECT/.cursor"
cp -R "$REPO_ROOT/.opencode" "$PROJECT/.opencode"

cat >"$PROJECT/README.md" <<'DOC'
# Delegation acceptance fixture

This repository exists only to prove the graph delegation contract.
DOC

cat >"$PROJECT/scripts/global-gate.sh" <<'SCRIPT'
#!/usr/bin/env bash
set -euo pipefail
integration_manifest="$(ls -t "${RALPH_PLAN_WORKSPACE_ROOT:?}/artifacts/real-cli-delegation-accept/integration/"*.json | head -1)"
integration="$(jq -r '.workspacePath' "$integration_manifest")"
test "$(cat "$integration/src/delegated/change.txt")" = child-change
test "$(cat "$integration/src/parent/done.txt")" = parent-done
SCRIPT
chmod +x "$PROJECT/scripts/global-gate.sh"

retry_marker="$STATE/child-verification-failed-once"
cat >"$PROJECT/accept.plan.md" <<PLAN
---
name: real-cli-delegation-accept
namespace: real-cli-delegation-accept
execution: graph
pipeline:
  maxParallel: 4
  edgeDerivation: declared
  strictEdges: false
  failurePolicy: drain
  publishMode: on-verified
  verificationProfiles:
    - name: child-retry
      steps:
        - name: fail-once
          command: 'if test -f "$retry_marker"; then exit 0; else : > "$retry_marker"; exit 1; fi'
          timeout: 30
          continueOnFailure: false
          requiredArtifacts: []
    - name: global
      steps:
        - name: integrated-parent-and-child
          command: bash scripts/global-gate.sh
          timeout: 60
          continueOnFailure: false
          requiredArtifacts: []
  stages:
    - id: parent
      runtime: claude
      model: claude-sonnet-4-6
      agent: implementation
      subagents: off
      workspaceMode: snapshot
      agentGitAccess: off
      writeScopes: [src/delegated/**, src/parent/**]
      produces:
        - path: src/delegated/change.txt
        - path: src/parent/done.txt
      delegation:
        maxChildren: 4
        native:
          mode: off
        crossRuntime:
          mode: changeset
          allowedRuntimes: [codex, opencode, cursor]
          allowedAgents: [implementation]
          maxParallel: 3
  repairRounds:
    id: delegation
    rounds: 1
    dependsOn: [parent]
    integrate:
      workspaceMode: snapshot
    gate:
      profile: global
    diagnose:
      runtime: claude
      model: claude-sonnet-4-6
      agent: implementation
      content: The acceptance gate is expected to pass. If reached, write the required implementation handoff describing the failure.
    lanes:
      - id: parent
        runtime: claude
        model: claude-sonnet-4-6
        agent: implementation
        workspaceMode: snapshot
        agentGitAccess: off
        writeScopes: [src/delegated/**, src/parent/**]
        content: Repair only the two declared acceptance files according to the gate result.
    reintegrate:
      workspaceMode: snapshot
todos:
  - id: parent-delegates
    stage: parent
    content: |
      Complete this exact brokered-child workflow using only the Ralph delegation MCP tools; never invoke a runtime CLI, ralph run, or ralph graph from Bash.

      1. Start these requests before waiting for any result:
         - idempotency key readonly-codex, runtime codex, agent implementation, access read-only, result kind json. Task: Read README.md without modifying product files. Write valid JSON describing that inspection to the exact Required result artifact path appended by Ralph. Do not delegate.
         - idempotency key readonly-opencode, runtime opencode, agent implementation, access read-only, verification profile child-retry, result kind json. Task: Use native read and file write or edit tools, not shell commands, to read README.md without modifying product files and write valid JSON describing that inspection to the exact Required result artifact path appended by Ralph. Do not delegate.
         - idempotency key replaceable-cursor, runtime cursor, agent implementation, access read-only, result kind json. Task: Read README.md and write a valid JSON result to the exact Required result artifact. Do not delegate.
      2. Repeat the readonly-codex start request byte-for-byte and confirm it returns the same delegation id. Query status for both read-only requests while they are outstanding.
      3. Cancel replaceable-cursor immediately and confirm its terminal cancelled status/result.
      4. Start idempotency key changeset-cursor, runtime cursor, agent implementation, access changeset, result kind json. Task: Use native file write or edit tools, not shell commands, to create only src/delegated/change.txt containing exactly child-change and to write a valid JSON result to the exact Required result artifact path appended by Ralph. Do not delegate.
      5. Wait in bounded calls for the two read-only children and the changeset child. Retrieve status and result for every successful child, then retrieve each result a second time to prove idempotent reads. Confirm the changeset child's file is present in this parent workspace.
      6. Only after all of that, create src/parent/done.txt containing exactly parent-done. The parent owns this TODO, its verification, and completion.
    verification: test "\$(cat src/delegated/change.txt)" = child-change && test "\$(cat src/parent/done.txt)" = parent-done
    status: pending
isProject: false
---
PLAN

git -C "$PROJECT" init -q
git -C "$PROJECT" add .
git -C "$PROJECT" -c user.name=Ralph -c user.email=ralph@example.invalid commit -qm fixture
CALLER_HEAD="$(git -C "$PROJECT" rev-parse HEAD)"
CALLER_STATUS="$(git -C "$PROJECT" status --porcelain=v1 --untracked-files=all)"

echo "fixture=$FIXTURE_ROOT"
echo "runtime_versions: $(claude --version | head -1) | $(codex --version 2>&1 | tail -1) | $(opencode --version | head -1) | $(cursor-agent --version 2>&1 | head -1)"
(
  cd "$REPO_ROOT"
  env -u RALPH_AGENT_TOOL_ACCESS -u RALPH_NATIVE_HOOKS -u RALPH_LAUNCHER_PID RALPH_MODE=hybrid \
    RALPH_PROJECT_ROOT="$PROJECT" RALPH_PLAN_WORKSPACE_ROOT="$STATE" RALPH_AGENT_WORKSPACE="$PROJECT" \
    RALPH_VERIFY_TRUST_AGENT_PASS=0 RALPH_AGENT_NATIVE_PASSTHROUGH=0 \
    RALPH_CONFIG_HOME="$STATE/config" RALPH_WORKSPACES_FILE="$STATE/config/workspaces.json" \
    CODEX_PLAN_MODEL=gpt-5.6-terra OPENCODE_PLAN_MODEL=ollama-cloud/kimi-k2.7-code \
    CURSOR_PLAN_MODEL=gpt-5.6-sol-high \
    RALPH_GRAPH_MAX_PARALLEL_PER_RUNTIME=1 RALPH_DELEGATION_GUTTER_ITERATIONS=4 RALPH_PLAN_NO_CAFFEINATE=1 \
    bash "$GRAPH_RUN" run "$PROJECT/accept.plan.md" --namespace "$NAMESPACE" --max-parallel 4
) >"$FIXTURE_ROOT/delegation-run.log" 2>&1

run_id="$(readlink "$STATE/graph-runs/$NAMESPACE/latest")"
run_dir="$STATE/graph-runs/$NAMESPACE/$run_id"
test "$(jq -r .status "$run_dir/run.json")" = succeeded
test "$(git -C "$PROJECT" rev-parse HEAD)" = "$CALLER_HEAD"
test "$(cat "$PROJECT/src/delegated/change.txt")" = child-change
test "$(cat "$PROJECT/src/parent/done.txt")" = parent-done
test "$(jq -r '.publish.status' "$run_dir/run.json")" = published
test ! -e "$PROJECT/accept.graph.json"
test ! -d "$PROJECT/.ralph-workspace"

delegation_root="$run_dir/nodes/parent/delegations"
test "$(find "$delegation_root" -mindepth 1 -maxdepth 1 -type d -name 'delegation-*' | wc -l | tr -d ' ')" = 4
test "$(find "$delegation_root" -mindepth 2 -maxdepth 2 -type d -name workspace | wc -l | tr -d ' ')" = 0
test "$(find "$delegation_root" -name .git -print | wc -l | tr -d ' ')" = 0

readonly_count=0
changeset_count=0
cancelled_count=0
for request in "$delegation_root"/delegation-*/request.json; do
  did="$(jq -r .delegationId "$request")"
  status_file="$(dirname "$request")/status.json"
  runtime="$(jq -r .runtime "$request")"
  agent="$(jq -r .agent "$request")"
  access="$(jq -r .accessMode "$request")"
  test "$agent" = implementation
  case "$(jq -r .status "$status_file")" in
    succeeded)
      test -s "$STATE/artifacts/$NAMESPACE/delegated/$did/result.json"
      if [[ "$access" == read-only ]]; then
        readonly_count=$((readonly_count + 1))
        test "$(jq -r '.finalResult.readOnlyVerified' "$status_file")" = true
      else
        changeset_count=$((changeset_count + 1))
        test "$runtime" = cursor
        test "$(jq -r '.finalResult.integrated' "$status_file")" = true
        test -s "$STATE/artifacts/$NAMESPACE/delegated/$did/changeset.json"
        test -s "$STATE/artifacts/$NAMESPACE/delegated/$did/integration.json"
      fi
      ;;
    cancelled) cancelled_count=$((cancelled_count + 1)) ;;
    *) echo "non-terminal delegation: $did" >&2; exit 1 ;;
  esac
done
test "$readonly_count" = 2
test "$changeset_count" = 1
test "$cancelled_count" = 1
test -f "$retry_marker"

# The OpenCode child must have been reopened after the runner-owned fail-once
# verification. Its generated child plan remains durable after workspace cleanup.
opencode_dir="$(for request in "$delegation_root"/delegation-*/request.json; do test "$(jq -r .runtime "$request")" = opencode && dirname "$request"; done)"
grep -q '^- \[x\]' "$opencode_dir/child.plan.md"
rg -q 'Post-verification result: FAILED' "$STATE/logs"

# Child scopes cannot create grandchildren, and no parent or child used a raw
# runtime invocation to bypass the broker.
for request in "$delegation_root"/delegation-*/request.json; do
  test "$(jq -r .depth "$request")" = 1
done
test "$(jq -r '.stage.subagents' "$run_dir/graph.json" | head -1)" = off
! rg -q 'ralph_(run_plan|graph_run|orchestrator_run)' "$delegation_root"/delegation-*/child.plan.md

# Run the repaired real cross-provider jury against the now-published diff.
cp "$REPO_ROOT/.ralph-workspace/plans/accept-fanout-jury.plan.md" "$FIXTURE_ROOT/jury.plan.md"
(
  cd "$REPO_ROOT"
  env -u RALPH_AGENT_TOOL_ACCESS -u RALPH_NATIVE_HOOKS -u RALPH_LAUNCHER_PID RALPH_MODE=native \
    RALPH_PROJECT_ROOT="$PROJECT" RALPH_PLAN_WORKSPACE_ROOT="$STATE" RALPH_AGENT_WORKSPACE="$PROJECT" \
    RALPH_VERIFY_TRUST_AGENT_PASS=0 RALPH_AGENT_NATIVE_PASSTHROUGH=0 \
    RALPH_CONFIG_HOME="$STATE/config" RALPH_WORKSPACES_FILE="$STATE/config/workspaces.json" \
    RALPH_PLAN_NO_CAFFEINATE=1 \
    bash "$GRAPH_RUN" run "$FIXTURE_ROOT/jury.plan.md" --namespace delegation-jury --max-parallel 3
) >"$FIXTURE_ROOT/jury-run.log" 2>&1

jury_id="$(readlink "$STATE/graph-runs/delegation-jury/latest")"
jury_dir="$STATE/graph-runs/delegation-jury/$jury_id"
test "$(jq -r .status "$jury_dir/run.json")" = succeeded
jq -e '[.nodes[] | select(.derivedFrom == "consensus-voter") | .stage.subagents] | length == 3 and all(. == "off")' "$jury_dir/graph.json" >/dev/null
test "$(find "$STATE/artifacts/delegation-jury" -type f -path '*reviews*' | wc -l | tr -d ' ')" -ge 3

echo "acceptance passed"
echo "run_dir=$run_dir"
echo "jury_run_dir=$jury_dir"
echo "delegation_log=$FIXTURE_ROOT/delegation-run.log"
echo "jury_log=$FIXTURE_ROOT/jury-run.log"
echo "caller_status_before=${CALLER_STATUS:-<clean>}"
echo "caller_status_after=$(git -C "$PROJECT" status --porcelain=v1 --untracked-files=all | tr '\n' ';')"
