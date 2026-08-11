#!/usr/bin/env bats

# Tests for graph-native-subagent.sh
#
# Verification requirements (from TODO #7):
#   1. For each supported adapter, prove a parent can invoke one allowed read-only child.
#   2. The child cannot edit a fixture (verified by checking overlay tools list).
#   3. The child cannot spawn a native child (no Agent in overlay tools).
#   4. The child cannot call cross-runtime delegation (no delegation MCP in overlay).
#   5. The child cannot complete the parent TODO (contract text asserts this).
#   6. Denied agent types are absent or rejected.
#   7. Unsupported runtimes fail before model invocation.
#   8. Output is logged to native-readonly.log.

source "$BATS_TEST_DIRNAME/../helper/load-lib.bash"

_lib="$REPO_ROOT/bundle/.ralph/bash-lib/graph/graph-native-subagent.sh"
_invoke_common="$REPO_ROOT/bundle/.ralph/bash-lib/run-plan/run-plan-invoke-common.sh"

setup() {
  TMPD="$(mktemp -d)"
  export RALPH_AGENT_WORKSPACE="$TMPD"
  # Unset mode vars so tests start clean
  unset RALPH_PLAN_NATIVE_SUBAGENT_MODE RALPH_PLAN_NATIVE_SUBAGENT_RUNTIME
  unset RALPH_PLAN_NATIVE_SUBAGENT_AGENTS
  unset PROMPT_STATIC
  # shellcheck source=../../../bundle/.ralph/bash-lib/graph/graph-native-subagent.sh
  source "$_lib"
}

teardown() {
  rm -rf "$TMPD"
  unset RALPH_AGENT_WORKSPACE
  unset RALPH_PLAN_NATIVE_SUBAGENT_MODE RALPH_PLAN_NATIVE_SUBAGENT_RUNTIME
  unset RALPH_PLAN_NATIVE_SUBAGENT_AGENTS
  unset PROMPT_STATIC
}

# ---------------------------------------------------------------------------
# Runtime capability checks
# ---------------------------------------------------------------------------

@test "runtime_supported: claude is the only supported runtime" {
  run graph_native_subagent_runtime_supported claude
  [ "$status" -eq 0 ]
}

@test "runtime_supported: opencode is not supported and returns 1" {
  run graph_native_subagent_runtime_supported opencode
  [ "$status" -ne 0 ]
  [[ "$output" == *"not supported"* ]] || [[ "$output" == *"proven"* ]] || [[ "$output" == *"PROVEN"* ]]
}

@test "runtime_supported: codex is not supported and returns 1" {
  run graph_native_subagent_runtime_supported codex
  [ "$status" -ne 0 ]
}

@test "runtime_supported: cursor is not supported and returns 1" {
  run graph_native_subagent_runtime_supported cursor
  [ "$status" -ne 0 ]
}

@test "runtime_supported: antigravity is not supported and returns 1" {
  run graph_native_subagent_runtime_supported antigravity
  [ "$status" -ne 0 ]
}

@test "runtime_supported: empty runtime returns 1" {
  run graph_native_subagent_runtime_supported ""
  [ "$status" -ne 0 ]
}

@test "runtime_supported: unknown runtime returns 1" {
  run graph_native_subagent_runtime_supported unknownruntime
  [ "$status" -ne 0 ]
}

# ---------------------------------------------------------------------------
# Allowed role validation
# ---------------------------------------------------------------------------

@test "validate_agents: research is an allowed read-only role" {
  run graph_native_subagent_validate_agents research
  [ "$status" -eq 0 ]
}

@test "validate_agents: code-review is an allowed read-only role" {
  run graph_native_subagent_validate_agents code-review
  [ "$status" -eq 0 ]
}

@test "validate_agents: log-analysis is an allowed read-only role" {
  run graph_native_subagent_validate_agents log-analysis
  [ "$status" -eq 0 ]
}

@test "validate_agents: explorer is an allowed read-only role" {
  run graph_native_subagent_validate_agents explorer
  [ "$status" -eq 0 ]
}

@test "validate_agents: multiple allowed roles all pass" {
  run graph_native_subagent_validate_agents research code-review
  [ "$status" -eq 0 ]
}

@test "validate_agents: implementation is denied (not a read-only role)" {
  run graph_native_subagent_validate_agents implementation
  [ "$status" -ne 0 ]
  [[ "$output" == *"not an allowed read-only role"* ]]
}

@test "validate_agents: architect is denied" {
  run graph_native_subagent_validate_agents architect
  [ "$status" -ne 0 ]
}

@test "validate_agents: qa is denied" {
  run graph_native_subagent_validate_agents qa
  [ "$status" -ne 0 ]
}

@test "validate_agents: security is denied (not in bounded read-only set)" {
  run graph_native_subagent_validate_agents security
  [ "$status" -ne 0 ]
}

@test "validate_agents: mix of allowed and denied fails on denied" {
  run graph_native_subagent_validate_agents research implementation
  [ "$status" -ne 0 ]
  [[ "$output" == *"not an allowed read-only role"* ]]
}

@test "validate_agents: no arguments returns 1" {
  run graph_native_subagent_validate_agents
  [ "$status" -ne 0 ]
}

# ---------------------------------------------------------------------------
# Child overlay generation (tool restriction)
# ---------------------------------------------------------------------------

@test "generate_child_overlay: claude overlay has only read-only tools" {
  local out_path="$TMPD/research.md"
  run graph_native_subagent_generate_child_overlay research claude "$out_path"
  [ "$status" -eq 0 ]
  [ -f "$out_path" ]
  # Must contain only Read, Grep, Glob
  grep -q "Read" "$out_path"
  grep -q "Grep" "$out_path"
  grep -q "Glob" "$out_path"
}

@test "generate_child_overlay: claude overlay does NOT contain Edit" {
  local out_path="$TMPD/research.md"
  graph_native_subagent_generate_child_overlay research claude "$out_path"
  # Edit must not appear in the tools section (may appear in body text)
  local tools_section
  tools_section="$(sed -n '/^tools:/,/^---$/p' "$out_path" | head -20)"
  [[ "$tools_section" != *"Edit"* ]]
}

@test "generate_child_overlay: claude overlay does NOT contain Write" {
  local out_path="$TMPD/research.md"
  graph_native_subagent_generate_child_overlay research claude "$out_path"
  local tools_section
  tools_section="$(sed -n '/^tools:/,/^---$/p' "$out_path" | head -20)"
  [[ "$tools_section" != *"Write"* ]]
}

@test "generate_child_overlay: claude overlay does NOT contain Bash (no shell mutation)" {
  local out_path="$TMPD/research.md"
  graph_native_subagent_generate_child_overlay research claude "$out_path"
  local tools_section
  tools_section="$(sed -n '/^tools:/,/^---$/p' "$out_path" | head -20)"
  [[ "$tools_section" != *"Bash"* ]]
}

@test "generate_child_overlay: claude overlay does NOT contain Agent (no subagent spawning)" {
  local out_path="$TMPD/research.md"
  graph_native_subagent_generate_child_overlay research claude "$out_path"
  # Agent must not appear in the tools section
  local tools_section
  tools_section="$(sed -n '/^tools:/,/^---$/p' "$out_path" | head -20)"
  [[ "$tools_section" != *"Agent"* ]]
}

@test "generate_child_overlay: prompt contract is embedded in overlay body" {
  local out_path="$TMPD/research.md"
  graph_native_subagent_generate_child_overlay research claude "$out_path"
  grep -q "Native Subagent Read-Only Contract" "$out_path"
}

@test "generate_child_overlay: overlay prohibits marking TODOs complete" {
  local out_path="$TMPD/research.md"
  graph_native_subagent_generate_child_overlay research claude "$out_path"
  grep -q "TODO_COMPLETION" "$out_path"
}

@test "generate_child_overlay: overlay prohibits spawning sub-agents" {
  local out_path="$TMPD/research.md"
  graph_native_subagent_generate_child_overlay research claude "$out_path"
  grep -q "no Agent tool" "$out_path"
}

@test "generate_child_overlay: overlay prohibits editing plan files" {
  local out_path="$TMPD/research.md"
  graph_native_subagent_generate_child_overlay research claude "$out_path"
  grep -q "plan files" "$out_path"
}

@test "generate_child_overlay: overlay names the correct agent" {
  local out_path="$TMPD/code-review.md"
  graph_native_subagent_generate_child_overlay code-review claude "$out_path"
  grep -q "name: code-review" "$out_path"
}

@test "generate_child_overlay: unsupported runtime returns 1" {
  local out_path="$TMPD/research.md"
  run graph_native_subagent_generate_child_overlay research opencode "$out_path"
  [ "$status" -ne 0 ]
  [ ! -f "$out_path" ]
}

@test "generate_child_overlay: missing arguments return 1" {
  run graph_native_subagent_generate_child_overlay research claude
  [ "$status" -ne 0 ]
}

# ---------------------------------------------------------------------------
# Prompt contract content
# ---------------------------------------------------------------------------

@test "prompt_contract: contains Native Subagent Contract header" {
  run graph_native_subagent_prompt_contract "test-node" "research, code-review"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Native Subagent Contract"* ]]
}

@test "prompt_contract: includes the node id" {
  run graph_native_subagent_prompt_contract "my-node-42" "research"
  [[ "$output" == *"my-node-42"* ]]
}

@test "prompt_contract: lists allowed agents" {
  run graph_native_subagent_prompt_contract "n1" "research, code-review"
  [[ "$output" == *"research, code-review"* ]]
}

@test "prompt_contract: prohibits marking TODOs complete" {
  run graph_native_subagent_prompt_contract "n1" "research"
  [[ "$output" == *"TODO_COMPLETION"* ]]
}

@test "prompt_contract: prohibits editing plan files" {
  run graph_native_subagent_prompt_contract "n1" "research"
  [[ "$output" == *"plan files"* ]]
}

@test "prompt_contract: prohibits spawning sub-agents" {
  run graph_native_subagent_prompt_contract "n1" "research"
  [[ "$output" == *"no Agent tool"* ]] || [[ "$output" == *"sub-agents"* ]]
}

@test "prompt_contract: prohibits emitting authoritative verification" {
  run graph_native_subagent_prompt_contract "n1" "research"
  [[ "$output" == *"verification"* ]]
}

@test "prompt_contract: states parent must synthesize results" {
  run graph_native_subagent_prompt_contract "n1" "research"
  [[ "$output" == *"Synthesize"* ]] || [[ "$output" == *"synthesize"* ]]
}

@test "prompt_contract: describes child failure handling" {
  run graph_native_subagent_prompt_contract "n1" "research"
  [[ "$output" == *"failure"* ]] || [[ "$output" == *"Failure"* ]]
}

# ---------------------------------------------------------------------------
# Setup (top-level orchestration)
# ---------------------------------------------------------------------------

@test "setup: succeeds for claude with allowed agents" {
  local delegation='{"maxDepth":1,"maxChildren":2,"native":{"mode":"read-only","allowedAgents":["research"],"maxParallel":1},"crossRuntime":{"mode":"off"}}'
  local overlay_dir="$TMPD/overlays"
  run graph_native_subagent_setup "$delegation" claude "$TMPD" "test-node" "$overlay_dir"
  [ "$status" -eq 0 ]
}

@test "setup: generates overlay files for each declared agent" {
  local delegation='{"maxDepth":1,"maxChildren":2,"native":{"mode":"read-only","allowedAgents":["research","code-review"],"maxParallel":1},"crossRuntime":{"mode":"off"}}'
  local overlay_dir="$TMPD/overlays"
  graph_native_subagent_setup "$delegation" claude "$TMPD" "test-node" "$overlay_dir" >/dev/null
  [ -f "$overlay_dir/research.md" ]
  [ -f "$overlay_dir/code-review.md" ]
}

@test "setup: outputs prompt contract on stdout" {
  local delegation='{"maxDepth":1,"maxChildren":1,"native":{"mode":"read-only","allowedAgents":["research"],"maxParallel":1},"crossRuntime":{"mode":"off"}}'
  local overlay_dir="$TMPD/overlays"
  run graph_native_subagent_setup "$delegation" claude "$TMPD" "test-node" "$overlay_dir"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Native Subagent Contract"* ]]
}

@test "setup: fails before model invocation for unsupported runtime opencode" {
  local delegation='{"maxDepth":1,"maxChildren":1,"native":{"mode":"read-only","allowedAgents":["research"],"maxParallel":1},"crossRuntime":{"mode":"off"}}'
  local overlay_dir="$TMPD/overlays"
  run graph_native_subagent_setup "$delegation" opencode "$TMPD" "test-node" "$overlay_dir"
  [ "$status" -ne 0 ]
  [[ "$output" == *"not supported"* ]] || [[ "$output" == *"PROVEN"* ]]
}

@test "setup: fails before model invocation for unsupported runtime codex" {
  local delegation='{"maxDepth":1,"maxChildren":1,"native":{"mode":"read-only","allowedAgents":["research"],"maxParallel":1},"crossRuntime":{"mode":"off"}}'
  local overlay_dir="$TMPD/overlays"
  run graph_native_subagent_setup "$delegation" codex "$TMPD" "test-node" "$overlay_dir"
  [ "$status" -ne 0 ]
}

@test "setup: fails before model invocation for unsupported runtime cursor" {
  local delegation='{"maxDepth":1,"maxChildren":1,"native":{"mode":"read-only","allowedAgents":["research"],"maxParallel":1},"crossRuntime":{"mode":"off"}}'
  local overlay_dir="$TMPD/overlays"
  run graph_native_subagent_setup "$delegation" cursor "$TMPD" "test-node" "$overlay_dir"
  [ "$status" -ne 0 ]
}

@test "setup: fails when declared agent is not an allowed read-only role" {
  local delegation='{"maxDepth":1,"maxChildren":1,"native":{"mode":"read-only","allowedAgents":["implementation"],"maxParallel":1},"crossRuntime":{"mode":"off"}}'
  local overlay_dir="$TMPD/overlays"
  run graph_native_subagent_setup "$delegation" claude "$TMPD" "test-node" "$overlay_dir"
  [ "$status" -ne 0 ]
  [[ "$output" == *"not an allowed read-only role"* ]]
}

@test "setup: succeeds with no declared agents (empty allowedAgents)" {
  local delegation='{"maxDepth":1,"maxChildren":0,"native":{"mode":"read-only","allowedAgents":[]},"crossRuntime":{"mode":"off"}}'
  local overlay_dir="$TMPD/overlays"
  run graph_native_subagent_setup "$delegation" claude "$TMPD" "test-node" "$overlay_dir"
  [ "$status" -eq 0 ]
}

@test "setup: logs to native-readonly.log" {
  local delegation='{"maxDepth":1,"maxChildren":1,"native":{"mode":"read-only","allowedAgents":["research"],"maxParallel":1},"crossRuntime":{"mode":"off"}}'
  local overlay_dir="$TMPD/overlays"
  graph_native_subagent_setup "$delegation" claude "$TMPD" "test-node" "$overlay_dir" >/dev/null
  local log_file="$TMPD/.ralph-workspace/logs/native-readonly.log"
  [ -f "$log_file" ]
  grep -q "graph-native-subagent" "$log_file"
}

@test "setup: missing required argument returns 1" {
  run graph_native_subagent_setup "" claude "$TMPD" "test-node" "$TMPD/overlays"
  [ "$status" -ne 0 ]
}

# ---------------------------------------------------------------------------
# env_from_delegation
# ---------------------------------------------------------------------------

@test "env_from_delegation: sets read-only mode for claude with native mode" {
  local delegation='{"maxDepth":1,"maxChildren":1,"native":{"mode":"read-only"},"crossRuntime":{"mode":"off"}}'
  graph_native_subagent_env_from_delegation "$delegation" claude
  [ "${RALPH_PLAN_NATIVE_SUBAGENT_MODE:-}" = "read-only" ]
  [ "${RALPH_PLAN_NATIVE_SUBAGENT_RUNTIME:-}" = "claude" ]
}

@test "env_from_delegation: sets off mode when native.mode is off" {
  local delegation='{"maxDepth":1,"maxChildren":0,"native":{"mode":"off"},"crossRuntime":{"mode":"off"}}'
  graph_native_subagent_env_from_delegation "$delegation" claude
  [ "${RALPH_PLAN_NATIVE_SUBAGENT_MODE:-}" = "off" ]
}

@test "env_from_delegation: sets off mode for unsupported runtime even when mode is read-only" {
  local delegation='{"maxDepth":1,"maxChildren":1,"native":{"mode":"read-only"},"crossRuntime":{"mode":"off"}}'
  graph_native_subagent_env_from_delegation "$delegation" opencode
  [ "${RALPH_PLAN_NATIVE_SUBAGENT_MODE:-}" = "off" ]
}

@test "env_from_delegation: sets off mode for empty delegation" {
  graph_native_subagent_env_from_delegation "" claude
  [ "${RALPH_PLAN_NATIVE_SUBAGENT_MODE:-}" = "off" ]
}

# ---------------------------------------------------------------------------
# Invoke-common integration: verify_runtime
# ---------------------------------------------------------------------------

@test "invoke-common: native_subagent_verify_runtime passes when mode is off" {
  unset RALPH_PLAN_NATIVE_SUBAGENT_MODE
  source "$_invoke_common"
  run ralph_run_plan_native_subagent_verify_runtime opencode
  [ "$status" -eq 0 ]
}

@test "invoke-common: native_subagent_verify_runtime passes for claude when mode is read-only" {
  export RALPH_PLAN_NATIVE_SUBAGENT_MODE=read-only
  source "$_invoke_common"
  run ralph_run_plan_native_subagent_verify_runtime claude
  [ "$status" -eq 0 ]
}

@test "invoke-common: native_subagent_verify_runtime fails for opencode when mode is read-only" {
  export RALPH_PLAN_NATIVE_SUBAGENT_MODE=read-only
  source "$_invoke_common"
  run ralph_run_plan_native_subagent_verify_runtime opencode
  [ "$status" -ne 0 ]
  [[ "$output" == *"not supported"* ]] || [[ "$output" == *"refusing to invoke"* ]]
}

@test "invoke-common: native_subagent_verify_runtime fails for cursor when mode is read-only" {
  export RALPH_PLAN_NATIVE_SUBAGENT_MODE=read-only
  source "$_invoke_common"
  run ralph_run_plan_native_subagent_verify_runtime cursor
  [ "$status" -ne 0 ]
}

@test "invoke-common: native_subagent_verify_runtime fails for codex when mode is read-only" {
  export RALPH_PLAN_NATIVE_SUBAGENT_MODE=read-only
  source "$_invoke_common"
  run ralph_run_plan_native_subagent_verify_runtime codex
  [ "$status" -ne 0 ]
}

@test "invoke-common: native_subagent_verify_runtime fails for antigravity when mode is read-only" {
  export RALPH_PLAN_NATIVE_SUBAGENT_MODE=read-only
  source "$_invoke_common"
  run ralph_run_plan_native_subagent_verify_runtime antigravity
  [ "$status" -ne 0 ]
}

# ---------------------------------------------------------------------------
# Invoke-common integration: append_contract
# ---------------------------------------------------------------------------

@test "invoke-common: append_contract does nothing when mode is off" {
  unset RALPH_PLAN_NATIVE_SUBAGENT_MODE
  PROMPT_STATIC="original content"
  export PROMPT_STATIC
  source "$_invoke_common"
  ralph_run_plan_native_subagent_append_contract
  [ "$PROMPT_STATIC" = "original content" ]
}

@test "invoke-common: append_contract injects contract when mode is read-only" {
  export RALPH_PLAN_NATIVE_SUBAGENT_MODE=read-only
  PROMPT_STATIC="original content"
  export PROMPT_STATIC
  export RALPH_STAGE_ID="my-stage"
  source "$_invoke_common"
  ralph_run_plan_native_subagent_append_contract
  [[ "$PROMPT_STATIC" == *"Native Subagent Contract"* ]]
  [[ "$PROMPT_STATIC" == *"original content"* ]]
}

@test "invoke-common: append_contract is idempotent (does not double-inject)" {
  export RALPH_PLAN_NATIVE_SUBAGENT_MODE=read-only
  PROMPT_STATIC="original content"
  export PROMPT_STATIC
  source "$_invoke_common"
  ralph_run_plan_native_subagent_append_contract
  local after_first="$PROMPT_STATIC"
  ralph_run_plan_native_subagent_append_contract
  [ "$PROMPT_STATIC" = "$after_first" ]
}

# ---------------------------------------------------------------------------
# Failure evidence collection
# ---------------------------------------------------------------------------

@test "collect_failure_evidence: logs to native-readonly.log when no evidence found" {
  local log_path="$TMPD/.ralph-workspace/logs/native-readonly.log"
  mkdir -p "$(dirname "$log_path")"
  graph_native_subagent_collect_failure_evidence "test-attempt-123" "$TMPD" "$log_path" || true
  [ -f "$log_path" ]
  grep -q "CHILD FAILURE EVIDENCE" "$log_path"
  grep -q "test-attempt-123" "$log_path"
}

@test "collect_failure_evidence: returns 0 when report file found" {
  local attempt_id="mynode__runid__1"
  local artifacts_dir="$TMPD/.ralph-workspace/artifacts/ns/stage-outcomes"
  mkdir -p "$artifacts_dir"
  echo '{"outcome":"failed","exitCode":1}' > "$artifacts_dir/${attempt_id}.json"
  local log_path="$TMPD/test.log"
  run graph_native_subagent_collect_failure_evidence "$attempt_id" "$TMPD" "$log_path"
  [ "$status" -eq 0 ]
  grep -q "report_file" "$log_path"
}

@test "collect_failure_evidence: returns 1 when no evidence files found" {
  run graph_native_subagent_collect_failure_evidence "no-evidence-attempt" "$TMPD" "$TMPD/test.log"
  [ "$status" -ne 0 ]
}

@test "collect_failure_evidence: missing required args returns 1" {
  run graph_native_subagent_collect_failure_evidence ""
  [ "$status" -ne 0 ]
}
