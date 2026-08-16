#!/usr/bin/env bats

source "$BATS_TEST_DIRNAME/../helper/load-lib.bash"
source "$REPO_ROOT/bundle/.ralph/bash-lib/graph/graph-runtime-capabilities.sh"
source "$REPO_ROOT/bundle/.ralph/bash-lib/graph/graph-schedule.sh"

BOOLEAN_CAPABILITY_NAMES='workspaceEnforcement
liveApprovals
sessionContinuation
provenSandboxBoundary'

setup() {
  TMPD="$(mktemp -d)"
  BIN_DIR="$TMPD/bin"
  mkdir -p "$BIN_DIR"
  GRAPH_SCHEDULE_MAX_PARALLEL=3
  GRAPH_SCHEDULE_MAX_PARALLEL_PER_RUNTIME=3
  GRAPH_SCHEDULE_TOKEN_CAP=20
  _graph_schedule_reset_runtime_occupancy
  unset GRAPH_RUNTIME_CAPABILITIES_PROBE
}

teardown() { rm -rf "$TMPD"; }

assert_capability_fields() {
  local json="$1"
  [ "$(printf '%s' "$json" | jq -r '.schemaVersion')" = "1" ]
  [ "$(printf '%s' "$json" | jq -r '.workspaceEnforcement | type')" = "boolean" ]
  [ "$(printf '%s' "$json" | jq -r '.liveApprovals | type')" = "boolean" ]
  [ "$(printf '%s' "$json" | jq -r '.sessionContinuation | type')" = "boolean" ]
  [ "$(printf '%s' "$json" | jq -r '.usageReliability | type')" = "string" ]
  [ "$(printf '%s' "$json" | jq -r '.provenSandboxBoundary | type')" = "boolean" ]
  [ "$(printf '%s' "$json" | jq -r '.probe.modelCall')" = "false" ]
  [ "$(printf '%s' "$json" | jq -r '.supported | type')" = "array" ]
  [ "$(printf '%s' "$json" | jq -r '.unsupported | type')" = "array" ]
}

assert_usage_enum() {
  local value="$1"
  case "$value" in
    authoritative|estimated|unavailable) return 0 ;;
    *) return 1 ;;
  esac
}

assert_boolean_partitioned() {
  local json="$1" name in_supported in_unsupported
  while IFS= read -r name; do
    [[ -n "$name" ]] || continue
    in_supported="$(printf '%s' "$json" | jq -r --arg n "$name" '.supported | index($n) != null')"
    in_unsupported="$(printf '%s' "$json" | jq -r --arg n "$name" '.unsupported | index($n) != null')"
    [ "$in_supported" != "$in_unsupported" ]
  done <<< "$BOOLEAN_CAPABILITY_NAMES"
}

write_hostile_cli() {
  local path="$1" marker="$2"
  cat >"$path" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$@" >"$marker"
printf '%s\n' "model session must not start" >&2
exit 3
EOF
  chmod +x "$path"
}

write_help_stub() {
  local path="$1" runtime="$2" mode="${3:-empty-help}" marker="${4:-}"
  cat >"$path" <<EOF
#!/usr/bin/env bash
if [[ -n "$marker" ]]; then
  printf '%s\n' "\$@" >>"$marker"
fi
case "$runtime" in
  claude|cursor|antigravity)
    if [[ "\$1" == "--help" || "\$1" == "help" || "\$1" == "-h" ]]; then
      if [[ "$mode" == "supported" ]]; then
        printf '%s\n' "Usage: $runtime" "  --permission-prompt-tool <name>"
        exit 0
      fi
      printf '%s\n' "Usage: $runtime" "  --model"
      exit 0
    fi
    ;;
  codex)
    if [[ "\$1" == "app-server" && "\${2:-}" == "--help" ]]; then
      if [[ "$mode" == "supported" ]]; then
        printf '%s\n' "Usage: codex app-server" "Start the JSON-RPC app-server and wait for initialize."
        exit 0
      fi
      printf '%s\n' "ok"
      exit 0
    fi
    if [[ "\$1" == "app-server" ]]; then
      printf '%s\n' "app-server must not start during capability probe" >&2
      exit 3
    fi
    if [[ "\$1" == "--help" || "\$1" == "help" ]]; then
      printf '%s\n' "Usage: codex" "  exec" "  app-server"
      exit 0
    fi
    ;;
  opencode)
    if [[ "\$1" == "serve" && "\${2:-}" == "--help" ]]; then
      if [[ "$mode" == "supported" ]]; then
        printf '%s\n' "Usage: opencode serve" "  --port" "  /event SSE event stream"
        exit 0
      fi
      printf '%s\n' "ok"
      exit 0
    fi
    if [[ "\$1" == "serve" ]]; then
      printf '%s\n' "serve must not start during capability probe" >&2
      exit 3
    fi
    if [[ "\$1" == "--help" || "\$1" == "help" ]]; then
      printf '%s\n' "Usage: opencode" "  run" "  serve"
      exit 0
    fi
    ;;
esac
printf '%s\n' "model session must not start during capability probe" >&2
exit 3
EOF
  chmod +x "$path"
}

@test "runtime graph capabilities unknown runtime is fail-closed and machine-readable" {
  run graph_runtime_capabilities "not-a-runtime"
  [ "$status" -eq 0 ]
  assert_capability_fields "$output"
  [ "$(printf '%s' "$output" | jq -r '.runtime')" = "not-a-runtime" ]
  [ "$(printf '%s' "$output" | jq -r '.workspaceEnforcement')" = "false" ]
  [ "$(printf '%s' "$output" | jq -r '.liveApprovals')" = "false" ]
  [ "$(printf '%s' "$output" | jq -r '.sessionContinuation')" = "false" ]
  [ "$(printf '%s' "$output" | jq -r '.usageReliability')" = "unavailable" ]
  [ "$(printf '%s' "$output" | jq -r '.provenSandboxBoundary')" = "false" ]
  [ "$(printf '%s' "$output" | jq -r '.probe.attempted')" = "false" ]
  [ "$(printf '%s' "$output" | jq -r '.probe.modelCall')" = "false" ]
  assert_boolean_partitioned "$output"
  [ "$(printf '%s' "$output" | jq -r '.supported | length')" = "0" ]
  [ "$(printf '%s' "$output" | jq -r '.unsupported | length')" = "4" ]
  run graph_runtime_capability_is_supported "$output" sessionContinuation
  [ "$status" -ne 0 ]
}

@test "runtime graph capabilities empty runtime is explicit unsupported not guessed" {
  run graph_runtime_capabilities ""
  [ "$status" -eq 0 ]
  assert_capability_fields "$output"
  [ "$(printf '%s' "$output" | jq -r '.runtime')" = "" ]
  [ "$(printf '%s' "$output" | jq -r '.workspaceEnforcement')" = "false" ]
  [ "$(printf '%s' "$output" | jq -r '.sessionContinuation')" = "false" ]
  [ "$(printf '%s' "$output" | jq -r '.usageReliability')" = "unavailable" ]
  [ "$(printf '%s' "$output" | jq -r '.provenSandboxBoundary')" = "false" ]
  [ "$(printf '%s' "$output" | jq -r '.liveApprovals')" = "false" ]
}

@test "runtime graph capabilities known runtimes enumerate workspace live approvals session continuation usage reliability and sandbox" {
  local runtime json
  for runtime in claude Claude cursor CURSOR codex opencode antigravity; do
    json="$(graph_runtime_capabilities "$runtime")"
    assert_capability_fields "$json"
    assert_boolean_partitioned "$json"
    assert_usage_enum "$(printf '%s' "$json" | jq -r '.usageReliability')"
    [ "$(printf '%s' "$json" | jq -r '.workspaceEnforcement')" = "true" ]
    [ "$(printf '%s' "$json" | jq -r '.sessionContinuation')" = "true" ]
    [ "$(printf '%s' "$json" | jq -r '.liveApprovals')" = "false" ]
    [ "$(printf '%s' "$json" | jq -r '.probe.attempted')" = "false" ]
    [ "$(printf '%s' "$json" | jq -r '.probe.modelCall')" = "false" ]
    graph_runtime_capability_is_supported "$json" workspaceEnforcement
    graph_runtime_capability_is_supported "$json" sessionContinuation
    run graph_runtime_capability_is_supported "$json" liveApprovals
    [ "$status" -ne 0 ]
  done
}

@test "runtime graph capabilities reports static usage reliability without probing" {
  local json
  json="$(graph_runtime_capabilities claude)"
  [ "$(printf '%s' "$json" | jq -r '.usageReliability')" = "authoritative" ]
  graph_runtime_capability_is_supported "$json" usageReliability:authoritative

  json="$(graph_runtime_capabilities cursor)"
  [ "$(printf '%s' "$json" | jq -r '.usageReliability')" = "authoritative" ]

  json="$(graph_runtime_capabilities codex)"
  [ "$(printf '%s' "$json" | jq -r '.usageReliability')" = "authoritative" ]

  json="$(graph_runtime_capabilities opencode)"
  [ "$(printf '%s' "$json" | jq -r '.usageReliability')" = "estimated" ]
  graph_runtime_capability_is_supported "$json" usageReliability:estimated

  json="$(graph_runtime_capabilities antigravity)"
  [ "$(printf '%s' "$json" | jq -r '.usageReliability')" = "estimated" ]
}

@test "runtime graph capabilities only Codex has a proven sandbox boundary" {
  local json runtime
  json="$(graph_runtime_capabilities codex)"
  [ "$(printf '%s' "$json" | jq -r '.provenSandboxBoundary')" = "true" ]
  graph_runtime_capability_is_supported "$json" provenSandboxBoundary

  for runtime in claude cursor opencode antigravity unknown; do
    json="$(graph_runtime_capabilities "$runtime")"
    [ "$(printf '%s' "$json" | jq -r '.provenSandboxBoundary')" = "false" ]
    run graph_runtime_capability_is_supported "$json" provenSandboxBoundary
    [ "$status" -ne 0 ]
  done
}

@test "runtime graph capabilities default discovery does not invoke a cli" {
  local marker="$TMPD/cli-invoked"
  write_hostile_cli "$BIN_DIR/claude" "$marker"
  write_hostile_cli "$BIN_DIR/cursor-agent" "$marker"
  write_hostile_cli "$BIN_DIR/codex" "$marker"
  write_hostile_cli "$BIN_DIR/opencode" "$marker"
  write_hostile_cli "$BIN_DIR/agy" "$marker"
  PATH="$BIN_DIR:$PATH"

  local runtime json
  for runtime in claude cursor codex opencode antigravity; do
    json="$(graph_runtime_capabilities "$runtime")"
    assert_capability_fields "$json"
    [ "$(printf '%s' "$json" | jq -r '.liveApprovals')" = "false" ]
    [ "$(printf '%s' "$json" | jq -r '.probe.attempted')" = "false" ]
    [ "$(printf '%s' "$json" | jq -r '.probe.modelCall')" = "false" ]
  done
  [ ! -f "$marker" ]
}

@test "runtime graph capabilities help-only probe can enable live approvals" {
  local marker="$TMPD/probe-argv" json
  write_help_stub "$BIN_DIR/claude" claude supported "$marker"
  json="$(graph_runtime_capabilities claude "$BIN_DIR/claude")"
  assert_capability_fields "$json"
  [ "$(printf '%s' "$json" | jq -r '.liveApprovals')" = "true" ]
  [ "$(printf '%s' "$json" | jq -r '.probe.attempted')" = "true" ]
  [ "$(printf '%s' "$json" | jq -r '.probe.modelCall')" = "false" ]
  graph_runtime_capability_is_supported "$json" liveApprovals
  [ "$(cat "$marker")" = "--help" ]

  write_help_stub "$BIN_DIR/codex" codex supported "$marker"
  : >"$marker"
  json="$(graph_runtime_capabilities codex "$BIN_DIR/codex")"
  [ "$(printf '%s' "$json" | jq -r '.liveApprovals')" = "true" ]
  [ "$(cat "$marker")" = $'app-server\n--help' ]

  write_help_stub "$BIN_DIR/opencode" opencode supported "$marker"
  : >"$marker"
  json="$(graph_runtime_capabilities opencode "$BIN_DIR/opencode")"
  [ "$(printf '%s' "$json" | jq -r '.liveApprovals')" = "true" ]
  [ "$(cat "$marker")" = $'serve\n--help' ]
}

@test "runtime graph capabilities probe never starts a model session" {
  local marker="$TMPD/model-call" argv="$TMPD/argv" json
  write_help_stub "$BIN_DIR/claude" claude empty-help "$argv"
  json="$(graph_runtime_capabilities claude "$BIN_DIR/claude")"
  [ "$(printf '%s' "$json" | jq -r '.liveApprovals')" = "false" ]
  [ "$(printf '%s' "$json" | jq -r '.probe.attempted')" = "true" ]
  [ "$(printf '%s' "$json" | jq -r '.probe.modelCall')" = "false" ]
  [ "$(cat "$argv")" = "--help" ]

  write_hostile_cli "$BIN_DIR/cursor-agent" "$marker"
  json="$(graph_runtime_capabilities cursor "$BIN_DIR/cursor-agent")"
  [ "$(printf '%s' "$json" | jq -r '.liveApprovals')" = "false" ]
  [ "$(printf '%s' "$json" | jq -r '.probe.modelCall')" = "false" ]
  [ -f "$marker" ]
  [[ "$(cat "$marker")" == "--help" ]]

  write_help_stub "$BIN_DIR/codex" codex empty-help "$argv"
  : >"$argv"
  json="$(graph_runtime_capabilities codex "$BIN_DIR/codex")"
  [ "$(printf '%s' "$json" | jq -r '.liveApprovals')" = "false" ]
  [ "$(cat "$argv")" = $'app-server\n--help' ]
}

@test "runtime graph capabilities missing cli keeps live approvals unsupported" {
  local json
  json="$(graph_runtime_capabilities claude "$TMPD/missing-claude")"
  [ "$(printf '%s' "$json" | jq -r '.liveApprovals')" = "false" ]
  [ "$(printf '%s' "$json" | jq -r '.workspaceEnforcement')" = "true" ]
  [ "$(printf '%s' "$json" | jq -r '.sessionContinuation')" = "true" ]
  [ "$(printf '%s' "$json" | jq -r '.probe.attempted')" = "true" ]
  [ "$(printf '%s' "$json" | jq -r '.probe.modelCall')" = "false" ]
}

@test "capability matrix proves only invocation-local adapters parallel-safe" {
  local runtime
  for runtime in claude codex opencode antigravity; do
    graph_runtime_same_runtime_parallel_safe "$runtime"
    [[ "$(graph_runtime_overlay_isolation "$runtime")" == temporary-* ]]
  done
  run graph_runtime_same_runtime_parallel_safe cursor
  [ "$status" -ne 0 ]
  [ "$(graph_runtime_overlay_isolation cursor)" = "project-root-overlay-journal" ]
  run graph_runtime_same_runtime_parallel_safe unknown
  [ "$status" -ne 0 ]
}

@test "two and three same-runtime admissions respect adapter proof regardless of workspace mode" {
  local runtime mode i admitted
  for runtime in claude codex opencode antigravity cursor; do
    for mode in snapshot worktree; do
      # Workspace mode is intentionally not an input to capability admission.
      _graph_schedule_reset_runtime_occupancy
      admitted=0
      for i in 1 2 3; do
        if _graph_schedule_runtime_can_admit "$runtime" off 1; then
          _graph_schedule_runtime_reserve_slots "$runtime" 1 1
          admitted=$((admitted + 1))
        fi
      done
      if [[ "$runtime" == cursor ]]; then
        [ "$admitted" -eq 1 ]
      else
        [ "$admitted" -eq 3 ]
      fi
    done
  done
}

@test "structured admission record carries safety runtime and token decisions" {
  GRAPH_SCHEDULE_ADMISSION_LOG_FILE="$TMPD/admission.jsonl"
  : >"$GRAPH_SCHEDULE_ADMISSION_LOG_FILE"
  _graph_schedule_runtime_reserve_slots claude 1 1
  _graph_schedule_log_admission admitted graph-node n1 claude off 1 1 test
  _graph_schedule_log_admission denied graph-node n2 cursor off 1 1 runtime-or-token-cap

  jq -s -e 'any(.[]; .ownerId == "n1" and .sameRuntimeParallelSafe == true and .tokenUsed == 1 and .effectiveRuntimeCap == 3)' "$GRAPH_SCHEDULE_ADMISSION_LOG_FILE" >/dev/null
  jq -s -e 'any(.[]; .ownerId == "n2" and .sameRuntimeParallelSafe == false and .overlayIsolation == "project-root-overlay-journal" and .effectiveRuntimeCap == 1)' "$GRAPH_SCHEDULE_ADMISSION_LOG_FILE" >/dev/null
}

@test "native parent reserves declared runtime allowance in token budget" {
  GRAPH_SCHEDULE_MAX_PARALLEL_PER_RUNTIME=3
  GRAPH_SCHEDULE_TOKEN_CAP=3
  [ "$(_graph_schedule_slots_for_node claude on)" -eq 3 ]
  [ "$(_graph_schedule_slots_for_node claude on 1)" -eq 2 ]
  _graph_schedule_runtime_reserve_slots claude 3 3
  run _graph_schedule_runtime_can_admit codex off 1
  [ "$status" -ne 0 ]
  _graph_schedule_runtime_release_slots claude 3 3
  _graph_schedule_runtime_can_admit codex off 1
}

@test "native allowance preflight fails before dispatch when parent plus children cannot fit" {
  graph="$TMPD/native.graph.json"
  printf '%s\n' '{"nodes":[{"id":"parent","stage":{"runtime":"claude","subagents":"on","delegation":{"native":{"maxParallel":1}}}}]}' >"$graph"
  GRAPH_SCHEDULE_MAX_PARALLEL=1
  GRAPH_SCHEDULE_MAX_PARALLEL_PER_RUNTIME=1
  GRAPH_SCHEDULE_TOKEN_CAP=1
  run graph_schedule_native_budget_preflight "$graph"
  [ "$status" -ne 0 ]
  [[ "$output" == *"parent+native.maxParallel requires 2"* ]]

  GRAPH_SCHEDULE_MAX_PARALLEL=2
  GRAPH_SCHEDULE_MAX_PARALLEL_PER_RUNTIME=2
  GRAPH_SCHEDULE_TOKEN_CAP=2
  graph_schedule_native_budget_preflight "$graph"
}
