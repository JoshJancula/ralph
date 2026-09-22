#!/usr/bin/env bats
# G04: the pure invocation preview builder and its paired text renderer in
# graph-preflight.sh. Snapshot the explanation output for the five required
# scenarios: good, missing-runtime, missing-model, unsafe shared mutation,
# and a narrow terminal (fixed-width truncation, not a real TTY query).

source "$BATS_TEST_DIRNAME/../helper/load-lib.bash"
source "$REPO_ROOT/bundle/.ralph/bash-lib/graph/graph-preflight.sh"

setup() {
  TMPD="$(mktemp -d)"
  BIN_DIR="$TMPD/bin"
  mkdir -p "$BIN_DIR"
  PROJECT="$TMPD/project"
  mkdir -p "$PROJECT/src"
  GRAPH="$TMPD/graph.json"
  PLAN="$TMPD/preflight-preview.plan.md"
  printf 'placeholder plan bytes\n' >"$PLAN"
  unset GRAPH_PREFLIGHT_UNAVAILABLE
  unset GRAPH_PREFLIGHT_CLI_CLAUDE GRAPH_PREFLIGHT_CLI_CURSOR
  unset GRAPH_PREFLIGHT_CLI_CODEX GRAPH_PREFLIGHT_CLI_OPENCODE
  unset GRAPH_PREFLIGHT_CLI_ANTIGRAVITY
  PATH="$BIN_DIR:$PATH"
}

teardown() {
  rm -rf "$TMPD"
}

write_graph() {
  local extra_file="$TMPD/extra.json"
  printf '%s\n' "$1" >"$extra_file"
  jq -n --slurpfile extra "$extra_file" '
    {
      schemaVersion: 1,
      ralphVersion: "test",
      name: "preflight-preview",
      namespace: "preflight-preview-ns",
      maxParallel: 2,
      failurePolicy: "drain",
      publishMode: "manual",
      nodes: [
        {
          id: "impl",
          type: "agent",
          dependsOn: [],
          derivedFrom: "stage",
          stage: {
            id: "impl",
            runtime: "claude",
            workspaceMode: "snapshot"
          }
        }
      ],
      edges: []
    } * $extra[0]
  ' >"$GRAPH"
}

write_cli_stub() {
  local path="$1" runtime="$2"
  cat >"$path" <<EOF
#!/bin/sh
case "\$1" in
  --help|help|-h)
    printf '%s\n' "Usage: $runtime" "  --permission-prompt-tool <name>"
    exit 0
    ;;
  auth)
    [ "\${2:-}" = "status" ] && { printf 'Logged in\n'; exit 0; }
    ;;
  login)
    [ "\${2:-}" = "status" ] && { printf 'Logged in\n'; exit 0; }
    ;;
  --list-models)
    printf '%s\n' "gpt-5 - flagship" "auto - default"
    exit 0
    ;;
esac
exit 3
EOF
  chmod +x "$path"
  case "$runtime" in
    claude) export GRAPH_PREFLIGHT_CLI_CLAUDE="$path" ;;
    cursor) export GRAPH_PREFLIGHT_CLI_CURSOR="$path" ;;
    codex) export GRAPH_PREFLIGHT_CLI_CODEX="$path" ;;
    opencode) export GRAPH_PREFLIGHT_CLI_OPENCODE="$path" ;;
    antigravity) export GRAPH_PREFLIGHT_CLI_ANTIGRAVITY="$path" ;;
  esac
}

build_preview() {
  graph_preflight_build_preview run interactive-cli "$PLAN" "$GRAPH" \
    "$PROJECT" "$TMPD/state" "$TMPD/agent"
}

@test "good scenario: preview identity is stable and the text explanation shows every required section" {
  write_cli_stub "$BIN_DIR/claude" claude
  write_graph '{}'

  preview="$(build_preview)"
  [ -n "$preview" ]
  [ "$(jq -r '.schemaVersion' <<<"$preview")" = "1" ]
  [ "$(jq -r '.operation' <<<"$preview")" = "run" ]
  [ "$(jq -r '.invocationMode' <<<"$preview")" = "interactive-cli" ]
  [ "$(jq -r '.namespace' <<<"$preview")" = "preflight-preview-ns" ]
  [ "$(jq -r '.maxParallel' <<<"$preview")" = "2" ]
  [ "$(jq -r '.failurePolicy' <<<"$preview")" = "drain" ]
  [ "$(jq -r '.publishMode' <<<"$preview")" = "manual" ]
  [ "$(jq -r '.nodes | length' <<<"$preview")" = "1" ]
  [ "$(jq -r '.roots.projectRoot' <<<"$preview")" = "$PROJECT" ]
  [ "$(jq -r '.roots.stateRoot' <<<"$preview")" = "$TMPD/state" ]
  [ "$(jq -r '.roots.agentWorkspace' <<<"$preview")" = "$TMPD/agent" ]

  # confirmationId excludes itself and is stable across identical rebuilds.
  without="$(jq -c 'del(.confirmationId)' <<<"$preview")"
  [ "$(graph_preflight_confirmation_id "$without")" = "$(jq -r '.confirmationId' <<<"$preview")" ]
  [ "$(build_preview | jq -r '.confirmationId')" = "$(jq -r '.confirmationId' <<<"$preview")" ]

  report="$(graph_preflight_report "$GRAPH" "$PROJECT")"
  [ "$(jq -r '.outcome' <<<"$report")" = "pass" ]

  run graph_preflight_format_preview_text "$preview" "$report"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Plan: $PLAN"* ]]
  [[ "$output" == *"Namespace: preflight-preview-ns"* ]]
  [[ "$output" == *"Operation: run (interactive-cli)"* ]]
  [[ "$output" == *"projectRoot:    $PROJECT"* ]]
  [[ "$output" == *"stateRoot:      $TMPD/state"* ]]
  [[ "$output" == *"agentWorkspace: $TMPD/agent"* ]]
  [[ "$output" == *"Nodes: 1"* ]]
  [[ "$output" == *"Parallelism: maxParallel=2 failurePolicy=drain"* ]]
  [[ "$output" == *"Publication: publishMode=manual"* ]]
  [[ "$output" == *"ID"*"RUNTIME"*"MODEL"*"WORKSPACE"* ]]
  # `role` was removed, and so was its preview column. Assert the removed
  # surface is absent rather than only that the current one is present.
  [[ "$output" != *"ROLE"* ]]
  [[ "$output" == *"impl"*"claude"*"snapshot"* ]]
  [[ "$output" == *"(none; all checks passed)"* ]]
}

@test "missing-runtime scenario: model-auth fails with a copyable, non-mutating install remedy" {
  # Force the resolved CLI to a path that can never exist, regardless of
  # what happens to be installed on the host running this test suite.
  export GRAPH_PREFLIGHT_CLI_CLAUDE="$TMPD/does-not-exist/claude"
  write_graph '{}'

  preview="$(build_preview)"
  report="$(graph_preflight_report "$GRAPH" "$PROJECT")"
  [ "$(jq -r '.outcome' <<<"$report")" = "fail" ]
  [ "$(jq -r '.findings[] | select(.id=="model-auth:impl") | .status' <<<"$report")" = "fail" ]

  run graph_preflight_format_preview_text "$preview" "$report"
  [ "$status" -eq 0 ]
  [[ "$output" == *"[FAIL] model-auth:impl"* ]]
  [[ "$output" == *"runtime CLI is not available"* ]]
  [[ "$output" == *"Remedy (non-mutating, copy/paste): install the claude CLI or set the runtime CLI override"* ]]
}

@test "missing-model scenario: declared model not in the runtime catalog fails with a copyable remedy" {
  write_cli_stub "$BIN_DIR/cursor" cursor
  write_graph '{"nodes":[{"id":"impl","type":"agent","dependsOn":[],"derivedFrom":"stage","stage":{"id":"impl","runtime":"cursor","model":"totally-not-a-real-model","workspaceMode":"snapshot"}}]}'

  preview="$(build_preview)"
  [ "$(jq -r '.nodes[0].model' <<<"$preview")" = "totally-not-a-real-model" ]

  report="$(graph_preflight_report "$GRAPH" "$PROJECT")"
  [ "$(jq -r '.findings[] | select(.id=="model-auth:impl") | .status' <<<"$report")" = "fail" ]

  run graph_preflight_format_preview_text "$preview" "$report"
  [ "$status" -eq 0 ]
  [[ "$output" == *"[FAIL] model-auth:impl"* ]]
  [[ "$output" == *"declared model is not in the runtime catalog"* ]]
  [[ "$output" == *"Remedy (non-mutating, copy/paste): choose a model listed by the cursor CLI"* ]]
}

@test "unsafe shared mutation scenario: workspace-mode fails with a copyable, non-mutating repair" {
  write_cli_stub "$BIN_DIR/claude" claude
  write_graph '{"nodes":[{"id":"impl","type":"agent","dependsOn":[],"derivedFrom":"stage","stage":{"id":"impl","runtime":"claude","workspaceMode":"shared","writeScopes":["src/**"]}}]}'

  preview="$(build_preview)"
  [ "$(jq -r '.nodes[0].workspaceMode' <<<"$preview")" = "shared" ]

  report="$(graph_preflight_report "$GRAPH" "$PROJECT")"
  [ "$(jq -r '.outcome' <<<"$report")" = "fail" ]
  [ "$(jq -r '.findings[] | select(.id=="workspace-mode:impl") | .status' <<<"$report")" = "fail" ]

  run graph_preflight_format_preview_text "$preview" "$report"
  [ "$status" -eq 0 ]
  [[ "$output" == *"[FAIL] workspace-mode:impl"* ]]
  [[ "$output" == *"shared mutation requires acknowledgement"* ]]
  [[ "$output" == *"Remedy (non-mutating, copy/paste): set parallelMutation: allow and acknowledgeSharedMutationRisk: true, or use snapshot"* ]]
  # The remedy is a plan edit, never a graph-run/graph-compile invocation.
  [[ "$output" != *"ralph graph run"* ]]
}

@test "narrow terminal scenario: fixed-width columns truncate a long id instead of wrapping or erroring" {
  write_cli_stub "$BIN_DIR/claude" claude
  local_long_id="implement-a-very-long-node-identifier-that-exceeds-the-fixed-column-width"
  write_graph "$(jq -nc --arg id "$local_long_id" '{nodes:[{id:$id,type:"agent",dependsOn:[],derivedFrom:"stage",stage:{id:$id,runtime:"claude",agent:"implementation-with-a-long-agent-name",model:"a-very-long-model-identifier-string-value",workspaceMode:"snapshot"}}]}')"

  preview="$(graph_preflight_build_preview run interactive-cli "$PLAN" "$GRAPH" "$PROJECT" "$TMPD/state" "$TMPD/agent")"
  report="$(graph_preflight_report "$GRAPH" "$PROJECT")"

  COLUMNS=20 run graph_preflight_format_preview_text "$preview" "$report"
  [ "$status" -eq 0 ]
  # The node table (bounded by fixed column widths, not COLUMNS) truncates
  # the long id with a ">" marker instead of wrapping or erroring; it never
  # queries the terminal, so a narrow terminal is handled the same way.
  table_row="$(printf '%s\n' "$output" | sed -n '/^ID/,/^$/p' | sed -n '2p')"
  [[ "$table_row" == *">"* ]]
  [[ "$table_row" != *"$local_long_id"* ]]
  # The findings section (not a fixed-width table) may still name the full
  # node id in a finding id such as workspace-mode:<id>; that is expected.
  # Non-table lines (roots, counts) are unaffected by table truncation.
  [[ "$output" == *"Nodes: 1"* ]]
}
