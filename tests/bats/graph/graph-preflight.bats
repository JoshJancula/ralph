#!/usr/bin/env bats
# Read-only frozen-graph preflight report.

source "$BATS_TEST_DIRNAME/../helper/load-lib.bash"
source "$REPO_ROOT/bundle/.ralph/bash-lib/graph/graph-preflight.sh"

GRAPH_RUN_SH="$REPO_ROOT/bundle/.ralph/graph-run.sh"

setup() {
  TMPD="$(mktemp -d)"
  BIN_DIR="$TMPD/bin"
  mkdir -p "$BIN_DIR"
  PROJECT="$TMPD/project"
  mkdir -p "$PROJECT/src" "$PROJECT/.ralph" "$PROJECT/.ralph-workspace"
  printf 'base\n' >"$PROJECT/src/app.txt"
  GRAPH="$TMPD/graph.json"
  PLAN="$PROJECT/preflight.plan.md"
  DISPATCH_MARKER="$TMPD/dispatch.marker"
  unset GRAPH_PREFLIGHT_UNAVAILABLE
  unset GRAPH_PREFLIGHT_CLI_CLAUDE GRAPH_PREFLIGHT_CLI_CURSOR
  unset GRAPH_PREFLIGHT_CLI_CODEX GRAPH_PREFLIGHT_CLI_OPENCODE
  unset GRAPH_PREFLIGHT_CLI_ANTIGRAVITY
  unset GRAPH_RUNTIME_CAPABILITIES_PROBE
  unset RALPH_GRAPH_GIT_SANDBOX_PROVEN
  unset CLAUDE_PLAN_CLI CURSOR_PLAN_CLI CODEX_PLAN_CLI OPENCODE_PLAN_CLI ANTIGRAVITY_PLAN_CLI
  unset GRAPH_DISPATCH_ORCHESTRATOR RALPH_ALLOW_NESTED_RUNS
  PATH="$BIN_DIR:$PATH"
}

teardown() {
  rm -rf "$TMPD"
}

write_graph() {
  local extra_file="$TMPD/extra.json"
  if [[ $# -gt 0 ]]; then
    printf '%s\n' "$1" >"$extra_file"
  else
    printf '%s\n' '{}' >"$extra_file"
  fi
  jq -n --slurpfile extra "$extra_file" '
    {
      schemaVersion: 1,
      ralphVersion: "test",
      name: "preflight",
      namespace: "preflight",
      maxParallel: 2,
      failurePolicy: "drain",
      nodes: [
        {
          id: "impl",
          type: "agent",
          dependsOn: [],
          derivedFrom: "stage",
          stage: {
            id: "impl",
            runtime: "claude",
            agent: "implementation",
            workspaceMode: "snapshot"
          }
        }
      ],
      edges: []
    } * $extra[0]
  ' >"$GRAPH"
}

write_cli_stub() {
  local path="$1" runtime="$2" mode="${3:-ok}" marker="${4:-}"
  cat >"$path" <<EOF
#!/usr/bin/env bash
if [[ -n "$marker" ]]; then
  printf '%s\n' "\$@" >>"$marker"
fi
case "\$1" in
  --help|help|-h)
    printf '%s\n' "Usage: $runtime" "  --permission-prompt-tool <name>" "  --model"
    exit 0
    ;;
  auth)
    if [[ "\${2:-}" == "status" ]]; then
      if [[ "$mode" == "no-auth" ]]; then
        printf '%s\n' "not logged in"
        exit 1
      fi
      printf '%s\n' "Logged in"
      exit 0
    fi
    ;;
  login)
    if [[ "\${2:-}" == "status" ]]; then
      if [[ "$mode" == "no-auth" ]]; then
        printf '%s\n' "not logged in"
        exit 1
      fi
      printf '%s\n' "Logged in"
      exit 0
    fi
    ;;
  models)
    if [[ "$mode" == "empty-models" ]]; then
      printf '%s\n' ""
      exit 0
    fi
    printf '%s\n' "Gemini 3 Pro" "Claude Opus 4.6"
    exit 0
    ;;
  --list-models)
    printf '%s\n' "gpt-5 - flagship" "auto - default"
    exit 0
    ;;
  app-server)
    if [[ "\${2:-}" == "--help" ]]; then
      printf '%s\n' "Usage: codex app-server" "Start the JSON-RPC app-server and wait for initialize."
      exit 0
    fi
    printf '%s\n' "app-server must not start during preflight" >&2
    exit 3
    ;;
  serve)
    if [[ "\${2:-}" == "--help" ]]; then
      printf '%s\n' "Usage: opencode serve" "  --port" "  /event SSE event stream"
      exit 0
    fi
    printf '%s\n' "serve must not start during preflight" >&2
    exit 3
    ;;
esac
printf '%s\n' "model session must not start during preflight" >&2
exit 3
EOF
  chmod +x "$path"
}

finding_status() {
  local json="$1" id="$2"
  printf '%s' "$json" | jq -r --arg id "$id" '.findings[] | select(.id == $id) | .status' | head -n 1
}

finding_category_has() {
  local json="$1" category="$2" status="$3"
  printf '%s' "$json" | jq -e --arg c "$category" --arg s "$status" \
    'any(.findings[]; .category == $c and .status == $s)' >/dev/null
}

init_git_project() {
  git init -q "$PROJECT"
  git -C "$PROJECT" add .
  git -C "$PROJECT" -c user.name=Ralph -c user.email=ralph@example.invalid \
    commit -qm fixture
}

write_plan() {
  cat >"$PLAN" <<'PLAN'
---
name: preflight-cli
namespace: preflight-cli
execution: graph
pipeline:
  stages:
    - id: impl
      runtime: claude
      agent: implementation
      workspaceMode: snapshot
todos:
  - id: impl-1
    stage: impl
    content: do the work
    status: pending
---
PLAN
}

write_plan_shared_ack() {
  cat >"$PLAN" <<'PLAN'
---
name: preflight-cli
namespace: preflight-cli
execution: graph
pipeline:
  stages:
    - id: impl
      runtime: claude
      agent: implementation
      workspaceMode: shared
      writeScopes:
        - src/**
      parallelMutation: allow
      acknowledgeSharedMutationRisk: true
todos:
  - id: impl-1
    stage: impl
    content: do the work
    status: pending
---
PLAN
}

json_last() {
  printf '%s\n' "$1" | awk 'END { print }'
}

preflight_cmd() {
  bash "$GRAPH_RUN_SH" preflight "$@" --workspace "$PROJECT"
}

run_cmd() {
  bash "$GRAPH_RUN_SH" run "$@" --workspace "$PROJECT"
}

write_dispatch_stub() {
  cat >"$TMPD/orchestrator-stub.sh" <<EOF
#!/usr/bin/env bash
printf 'dispatched %s\n' "\$*" >>"$DISPATCH_MARKER"
echo "orchestrator stub must not start a model session" >&2
exit 3
EOF
  chmod +x "$TMPD/orchestrator-stub.sh"
  export GRAPH_DISPATCH_ORCHESTRATOR="$TMPD/orchestrator-stub.sh"
}

@test "preflight report snapshot workspace mode passes when python3 is available" {
  write_cli_stub "$BIN_DIR/claude" claude ok
  write_graph
  run graph_preflight_report "$GRAPH" "$PROJECT"
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '.readOnly')" = "true" ]
  [ "$(printf '%s' "$output" | jq -r '.schemaVersion')" = "1" ]
  [ "$(finding_status "$output" "workspace-mode:impl")" = "pass" ]
  finding_category_has "$output" workspace-mode pass
}

@test "preflight report worktree fails without git or a clean repository" {
  write_graph '{"nodes":[{"id":"impl","type":"agent","dependsOn":[],"derivedFrom":"stage","stage":{"id":"impl","runtime":"codex","agent":"implementation","workspaceMode":"worktree","writeScopes":["src/**"],"agentGitAccess":"off"}}]}'
  export GRAPH_PREFLIGHT_UNAVAILABLE=git
  write_cli_stub "$BIN_DIR/codex" codex ok
  run graph_preflight_report "$GRAPH" "$PROJECT"
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '.outcome')" = "fail" ]
  [ "$(finding_status "$output" "workspace-mode:impl")" = "fail" ]
  [[ "$(printf '%s' "$output" | jq -r '.findings[] | select(.id=="workspace-mode:impl") | .summary')" == *"git"* ]]

  unset GRAPH_PREFLIGHT_UNAVAILABLE
  export RALPH_GRAPH_GIT_SANDBOX_PROVEN=1
  run graph_preflight_report "$GRAPH" "$PROJECT"
  [ "$status" -eq 0 ]
  [ "$(finding_status "$output" "workspace-mode:impl")" = "fail" ]
  [[ "$(printf '%s' "$output" | jq -r '.findings[] | select(.id=="workspace-mode:impl") | .summary')" == *"Git repository"* ]]

  init_git_project
  printf 'dirty\n' >"$PROJECT/src/app.txt"
  run graph_preflight_report "$GRAPH" "$PROJECT"
  [ "$status" -eq 0 ]
  [ "$(finding_status "$output" "workspace-mode:impl")" = "fail" ]
  [[ "$(printf '%s' "$output" | jq -r '.findings[] | select(.id=="workspace-mode:impl") | .summary')" == *"clean"* ]]
}

@test "preflight report shared mutation without acknowledgement fails and with acknowledgement warns" {
  write_cli_stub "$BIN_DIR/claude" claude ok
  write_graph '{"nodes":[{"id":"impl","type":"agent","dependsOn":[],"derivedFrom":"stage","stage":{"id":"impl","runtime":"claude","agent":"implementation","workspaceMode":"shared","writeScopes":["src/**"]}}]}'
  run graph_preflight_report "$GRAPH" "$PROJECT"
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '.outcome')" = "fail" ]
  [ "$(finding_status "$output" "workspace-mode:impl")" = "fail" ]
  finding_category_has "$output" workspace-mode fail

  write_graph '{"nodes":[{"id":"impl","type":"agent","dependsOn":[],"derivedFrom":"stage","stage":{"id":"impl","runtime":"claude","agent":"implementation","workspaceMode":"shared","writeScopes":["src/**"],"parallelMutation":"allow","acknowledgeSharedMutationRisk":true}}]}'
  run graph_preflight_report "$GRAPH" "$PROJECT"
  [ "$status" -eq 0 ]
  [ "$(finding_status "$output" "workspace-mode:impl")" = "warn" ]
  finding_category_has "$output" workspace-mode warn
}

@test "preflight report write scopes fail when the runtime cannot enforce them" {
  write_graph '{"nodes":[{"id":"impl","type":"agent","dependsOn":[],"derivedFrom":"stage","stage":{"id":"impl","runtime":"not-a-runtime","agent":"implementation","workspaceMode":"snapshot","writeScopes":["src/**"]}}]}'
  run graph_preflight_report "$GRAPH" "$PROJECT"
  [ "$status" -eq 0 ]
  [ "$(finding_status "$output" "write-scopes:impl")" = "fail" ]
  finding_category_has "$output" write-scopes fail
  [[ "$(printf '%s' "$output" | jq -r '.findings[] | select(.id=="write-scopes:impl") | .summary')" == *"enforce"* ]]
}

@test "preflight report write scopes pass for an isolated mutating node and reject control-path globs" {
  write_cli_stub "$BIN_DIR/claude" claude ok
  write_graph '{"nodes":[{"id":"impl","type":"agent","dependsOn":[],"derivedFrom":"stage","stage":{"id":"impl","runtime":"claude","agent":"implementation","workspaceMode":"snapshot","writeScopes":["src/**"]}}]}'
  run graph_preflight_report "$GRAPH" "$PROJECT"
  [ "$status" -eq 0 ]
  [ "$(finding_status "$output" "write-scopes:impl")" = "pass" ]
  finding_category_has "$output" write-scopes pass

  write_graph '{"nodes":[{"id":"impl","type":"agent","dependsOn":[],"derivedFrom":"stage","stage":{"id":"impl","runtime":"claude","agent":"implementation","workspaceMode":"snapshot","writeScopes":[".ralph/**"]}}]}'
  run graph_preflight_report "$GRAPH" "$PROJECT"
  [ "$status" -eq 0 ]
  [ "$(finding_status "$output" "write-scopes:impl")" = "fail" ]
  [[ "$(printf '%s' "$output" | jq -r '.findings[] | select(.id=="write-scopes:impl") | .summary')" == *"control-path"* ]]
}

@test "preflight report approval support warns when live approvals are unproven and fails for an unknown runtime" {
  write_cli_stub "$BIN_DIR/claude" claude ok
  write_graph
  export GRAPH_PREFLIGHT_CLI_CLAUDE="$TMPD/missing-claude"
  run graph_preflight_report "$GRAPH" "$PROJECT"
  [ "$status" -eq 0 ]
  [ "$(finding_status "$output" "approval:claude")" = "warn" ]
  finding_category_has "$output" approval warn

  unset GRAPH_PREFLIGHT_CLI_CLAUDE
  run graph_preflight_report "$GRAPH" "$PROJECT"
  [ "$status" -eq 0 ]
  [ "$(finding_status "$output" "approval:claude")" = "pass" ]
  finding_category_has "$output" approval pass

  write_graph '{"nodes":[{"id":"impl","type":"agent","dependsOn":[],"derivedFrom":"stage","stage":{"id":"impl","runtime":"unknown-runtime","agent":"implementation","workspaceMode":"snapshot"}}]}'
  run graph_preflight_report "$GRAPH" "$PROJECT"
  [ "$status" -eq 0 ]
  [ "$(finding_status "$output" "approval:unknown-runtime")" = "fail" ]
  finding_category_has "$output" approval fail
}

@test "preflight report model auth fails when the runtime cli is missing" {
  write_graph
  export GRAPH_PREFLIGHT_CLI_CLAUDE="$TMPD/missing-claude"
  run graph_preflight_report "$GRAPH" "$PROJECT"
  [ "$status" -eq 0 ]
  [ "$(finding_status "$output" "model-auth:impl")" = "fail" ]
  finding_category_has "$output" model-auth fail
  [[ "$(printf '%s' "$output" | jq -r '.findings[] | select(.id=="model-auth:impl") | .summary')" == *"CLI is not available"* ]]
}

@test "preflight report model auth fails on missing auth and on a retired model" {
  write_cli_stub "$BIN_DIR/claude" claude no-auth
  write_graph
  run graph_preflight_report "$GRAPH" "$PROJECT"
  [ "$status" -eq 0 ]
  [ "$(finding_status "$output" "model-auth:impl")" = "fail" ]
  [[ "$(printf '%s' "$output" | jq -r '.findings[] | select(.id=="model-auth:impl") | .summary')" == *"authentication is missing"* ]]

  write_cli_stub "$BIN_DIR/agy" antigravity empty-models
  write_graph '{"nodes":[{"id":"impl","type":"agent","dependsOn":[],"derivedFrom":"stage","stage":{"id":"impl","runtime":"antigravity","agent":"implementation","workspaceMode":"snapshot","model":"Gemini 3 Pro"}}]}'
  run graph_preflight_report "$GRAPH" "$PROJECT"
  [ "$status" -eq 0 ]
  [ "$(finding_status "$output" "model-auth:impl")" = "fail" ]
  [[ "$(printf '%s' "$output" | jq -r '.findings[] | select(.id=="model-auth:impl") | .summary')" == *"not in the runtime catalog"* ]]
}

@test "preflight report model auth preserves exact Antigravity model strings" {
  write_cli_stub "$BIN_DIR/agy" antigravity ok
  write_graph '{"nodes":[{"id":"impl","type":"agent","dependsOn":[],"derivedFrom":"stage","stage":{"id":"impl","runtime":"antigravity","agent":"implementation","workspaceMode":"snapshot","model":"Gemini 3 Pro"}}]}'
  run graph_preflight_report "$GRAPH" "$PROJECT"
  [ "$status" -eq 0 ]
  [ "$(finding_status "$output" "model-auth:impl")" = "pass" ]
  [ "$(printf '%s' "$output" | jq -r '.findings[] | select(.id=="model-auth:impl") | .evidence')" = "model=Gemini 3 Pro" ]

  write_graph '{"nodes":[{"id":"impl","type":"agent","dependsOn":[],"derivedFrom":"stage","stage":{"id":"impl","runtime":"antigravity","agent":"implementation","workspaceMode":"snapshot","model":"gemini-3-pro"}}]}'
  run graph_preflight_report "$GRAPH" "$PROJECT"
  [ "$status" -eq 0 ]
  [ "$(finding_status "$output" "model-auth:impl")" = "fail" ]
  [[ "$(printf '%s' "$output" | jq -r '.findings[] | select(.id=="model-auth:impl") | .repair')" == *"exact display string"* ]]
}

@test "preflight report commands fail for a missing or non-allowlisted gate executable" {
  write_cli_stub "$BIN_DIR/claude" claude ok
  export RALPH_GATE_EXTRA_ALLOWED="definitely-not-on-path-xyz"
  write_graph "$(cat <<'JSON'
{
  "verificationProfiles": [
    {"name":"fast","steps":[{"name":"unit","command":"definitely-not-on-path-xyz test"}]}
  ],
  "nodes":[{"id":"g1","type":"gate","dependsOn":[],"derivedFrom":"stage","stage":{"id":"g1","type":"gate","profile":"fast"}}]
}
JSON
)"
  run graph_preflight_report "$GRAPH" "$PROJECT"
  [ "$status" -eq 0 ]
  [ "$(finding_status "$output" "commands:gate:fast:unit")" = "fail" ]
  finding_category_has "$output" commands fail
  [[ "$(printf '%s' "$output" | jq -r '.findings[] | select(.id=="commands:gate:fast:unit") | .summary')" == *"missing"* ]]
  unset RALPH_GATE_EXTRA_ALLOWED

  write_graph "$(cat <<'JSON'
{
  "verificationProfiles": [
    {"name":"fast","steps":[{"name":"unit","command":"curl https://example.invalid"}]}
  ],
  "nodes":[{"id":"g1","type":"gate","dependsOn":[],"derivedFrom":"stage","stage":{"id":"g1","type":"gate","profile":"fast"}}]
}
JSON
)"
  run graph_preflight_report "$GRAPH" "$PROJECT"
  [ "$status" -eq 0 ]
  [ "$(finding_status "$output" "commands:gate:fast:unit")" = "fail" ]
  [[ "$(printf '%s' "$output" | jq -r '.findings[] | select(.id=="commands:gate:fast:unit") | .summary')" == *"allowlist"* ]]
}

@test "preflight report commands pass for an allowlisted present executable" {
  write_cli_stub "$BIN_DIR/claude" claude ok
  write_graph "$(cat <<'JSON'
{
  "verificationProfiles": [
    {"name":"fast","steps":[{"name":"ok","command":"true"}]}
  ],
  "nodes":[
    {"id":"impl","type":"agent","dependsOn":[],"derivedFrom":"stage","stage":{"id":"impl","runtime":"claude","agent":"implementation","workspaceMode":"snapshot"}},
    {"id":"g1","type":"gate","dependsOn":["impl"],"derivedFrom":"stage","stage":{"id":"g1","type":"gate","profile":"fast"}}
  ],
  "edges":[{"from":"impl","to":"g1","reasons":["declared"]}]
}
JSON
)"
  run graph_preflight_report "$GRAPH" "$PROJECT"
  [ "$status" -eq 0 ]
  [ "$(finding_status "$output" "commands:gate:fast:ok")" = "pass" ]
  [ "$(finding_status "$output" "commands:jq")" = "pass" ]
  finding_category_has "$output" commands pass
}

@test "preflight report publish preconditions pass for manual and fail on-verified without isolation or integrate" {
  write_cli_stub "$BIN_DIR/claude" claude ok
  write_graph
  run graph_preflight_report "$GRAPH" "$PROJECT"
  [ "$status" -eq 0 ]
  [ "$(finding_status "$output" "publish:mode")" = "pass" ]
  finding_category_has "$output" publish pass

  write_graph '{"publishMode":"on-verified"}'
  run graph_preflight_report "$GRAPH" "$PROJECT"
  [ "$status" -eq 0 ]
  [ "$(finding_status "$output" "publish:integrate")" = "fail" ]
  finding_category_has "$output" publish fail

  write_graph '{"publishMode":"on-verified","nodes":[{"id":"impl","type":"agent","dependsOn":[],"derivedFrom":"stage","stage":{"id":"impl","runtime":"claude","agent":"implementation","workspaceMode":"shared"}},{"id":"integrate","type":"integrate","dependsOn":["impl"],"derivedFrom":"stage","stage":{"id":"integrate","type":"integrate","workspaceMode":"shared"}}]}'
  run graph_preflight_report "$GRAPH" "$PROJECT"
  [ "$status" -eq 0 ]
  [ "$(finding_status "$output" "publish:isolation")" = "fail" ]
}

@test "preflight report is read-only and never starts a model session" {
  local marker="$TMPD/argv" before after ambient
  write_cli_stub "$BIN_DIR/claude" claude ok "$marker"
  write_graph '{"nodes":[{"id":"impl","type":"agent","dependsOn":[],"derivedFrom":"stage","stage":{"id":"impl","runtime":"claude","agent":"implementation","workspaceMode":"snapshot","writeScopes":["src/**"]}}]}'
  ambient="$PROJECT/.cursor/mcp.json"
  mkdir -p "$PROJECT/.cursor"
  printf '{}\n' >"$ambient"
  before="$(shasum "$GRAPH" "$ambient" | shasum | awk '{print $1}')"
  run graph_preflight_report "$GRAPH" "$PROJECT"
  [ "$status" -eq 0 ]
  after="$(shasum "$GRAPH" "$ambient" | shasum | awk '{print $1}')"
  [ "$before" = "$after" ]
  [ "$(printf '%s' "$output" | jq -r '.readOnly')" = "true" ]
  [ -f "$marker" ]
  while IFS= read -r line; do
    [[ "$line" == "--help" || "$line" == "auth status" || "$line" == "auth" || "$line" == "status" ]]
  done <"$marker"
  ! grep -q "model session must not start" "$marker"
}

@test "preflight report overall outcome is fail when any finding fails and warn when only warnings exist" {
  write_cli_stub "$BIN_DIR/claude" claude ok
  write_graph '{"nodes":[{"id":"impl","type":"agent","dependsOn":[],"derivedFrom":"stage","stage":{"id":"impl","runtime":"claude","agent":"implementation","workspaceMode":"shared","writeScopes":["src/**"],"parallelMutation":"allow","acknowledgeSharedMutationRisk":true}}]}'
  run graph_preflight_report "$GRAPH" "$PROJECT"
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '.outcome')" = "warn" ]
  finding_category_has "$output" workspace-mode warn

  write_graph '{"nodes":[{"id":"impl","type":"agent","dependsOn":[],"derivedFrom":"stage","stage":{"id":"impl","runtime":"not-a-runtime","agent":"implementation","workspaceMode":"snapshot","writeScopes":["src/**"]}}]}'
  run graph_preflight_report "$GRAPH" "$PROJECT"
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '.outcome')" = "fail" ]
}

@test "preflight cli --help exits 0 and documents --json" {
  run bash "$GRAPH_RUN_SH" preflight --help
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -q -- 'preflight'
  printf '%s\n' "$output" | grep -q -- '--json'
  run bash "$GRAPH_RUN_SH" --help
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -q -- 'preflight'
  printf '%s\n' "$output" | grep -q -- '--json'
}

@test "preflight cli errors without a plan path" {
  run preflight_cmd --json
  [ "$status" -ne 0 ]
  printf '%s\n' "$output" | grep -q 'plan path'
}

@test "preflight cli --json prints the same report object as the module" {
  write_cli_stub "$BIN_DIR/claude" claude ok
  write_plan
  run preflight_cmd --json "$PLAN"
  [ "$status" -eq 0 ]
  local report
  report="$(json_last "$output")"
  [ "$(printf '%s' "$report" | jq -r '.readOnly')" = "true" ]
  [ "$(printf '%s' "$report" | jq -r '.schemaVersion')" = "1" ]
  [ "$(printf '%s' "$report" | jq -r '.outcome')" = "pass" ]
  [ "$(finding_status "$report" "workspace-mode:impl")" = "pass" ]
  [ ! -e "${PLAN}.graph.json" ]
  [ ! -e "$PROJECT/.ralph-workspace/graph-runs" ]
}

@test "preflight cli --json fails when the runtime cli is missing" {
  write_plan
  export GRAPH_PREFLIGHT_CLI_CLAUDE="$TMPD/missing-claude"
  run preflight_cmd --json "$PLAN"
  [ "$status" -ne 0 ]
  local report
  report="$(json_last "$output")"
  [ "$(printf '%s' "$report" | jq -r '.outcome')" = "fail" ]
  [ "$(finding_status "$report" "model-auth:impl")" = "fail" ]
  [ ! -e "$PROJECT/.ralph-workspace/graph-runs" ]
}

@test "preflight cli --json warns when shared mutation is already acknowledged" {
  write_cli_stub "$BIN_DIR/claude" claude ok
  write_plan_shared_ack
  run preflight_cmd --json "$PLAN"
  [ "$status" -eq 0 ]
  local report
  report="$(json_last "$output")"
  [ "$(printf '%s' "$report" | jq -r '.outcome')" = "warn" ]
  [ "$(finding_status "$report" "workspace-mode:impl")" = "warn" ]
}

@test "preflight cli run stops on hard failure before model invocation" {
  local marker="$TMPD/argv"
  write_cli_stub "$BIN_DIR/claude" claude ok "$marker"
  write_plan
  write_dispatch_stub
  export GRAPH_PREFLIGHT_CLI_CLAUDE="$TMPD/missing-claude"
  run run_cmd "$PLAN"
  [ "$status" -ne 0 ]
  printf '%s\n' "$output" | grep -q 'preflight failed'
  printf '%s\n' "$output" | grep -q 'model-auth'
  [ ! -e "$PROJECT/.ralph-workspace/graph-runs" ]
  [ ! -f "$DISPATCH_MARKER" ]
  if [[ -f "$marker" ]]; then
    ! grep -q "model session must not start" "$marker"
    ! grep -q "dispatched" "$marker"
  fi
}

@test "preflight cli run proceeds when warnings have acknowledgements" {
  local marker="$TMPD/argv"
  write_cli_stub "$BIN_DIR/claude" claude ok "$marker"
  write_plan_shared_ack
  write_dispatch_stub
  export RALPH_ALLOW_NESTED_RUNS=1
  run run_cmd "$PLAN"
  [ "$status" -ne 0 ]
  ! printf '%s\n' "$output" | grep -q 'preflight failed'
  [ -d "$PROJECT/.ralph-workspace/graph-runs/preflight-cli" ]
  local run_count
  run_count="$(find "$PROJECT/.ralph-workspace/graph-runs/preflight-cli" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ')"
  [ "$run_count" -ge 1 ]
}
