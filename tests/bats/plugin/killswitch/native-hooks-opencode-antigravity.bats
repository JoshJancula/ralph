#!/usr/bin/env bats

source "$BATS_TEST_DIRNAME/../../helper/load-lib.bash"

KILLSWITCH_CORE="$REPO_ROOT/bundle/.ralph/bash-lib/killswitch/killswitch-core.sh"
OPENCODE_PLUGIN="$REPO_ROOT/bundle/.opencode/plugins/ralph-runtime-hooks.ts"
ANTIGRAVITY_HOOK="$REPO_ROOT/bundle/.agents/hooks/pre-tool-shell-policy.sh"
BASH_LIB_DIR="$REPO_ROOT/bundle/.ralph/bash-lib"

setup() {
  WS="$(mktemp -d)"
  RECORD="$WS/hook-record.jsonl"
  mkdir -p "$WS/.ralph-workspace"
  cat >"$WS/.ralph-workspace/killswitch.json" <<'EOF'
{
  "schema_version": 2,
  "enabled": true,
  "dry_run": true,
  "banned_tools": [],
  "toolDenylist": ["Bash", "Shell", "bash", "command_execution"],
  "deniedArgumentPatterns": [],
  "banned_paths": [],
  "custom_rules": []
}
EOF
}

teardown() {
  rm -rf "$WS"
}

hook_env() {
  local mode="${1:-native}"
  printf '%s' \
    "WORKSPACE=$WS " \
    "RALPH_HOME=$REPO_ROOT " \
    "RALPH_PROJECT_ROOT=$WS " \
    "RALPH_AGENT_WORKSPACE=$WS " \
    "RALPH_PLAN_WORKSPACE_ROOT=$WS/.ralph-workspace " \
    "RALPH_PLAN_KEY=ks-hooks-secondary " \
    "RALPH_MODE=$mode " \
    "RALPH_BASH_LIB_DIR=$BASH_LIB_DIR " \
    "KILLSWITCH_RUNNER_PID= " \
    "RALPH_KILLSWITCH_HOOK_RECORD=$RECORD " \
    "RALPH_BASH_REWRITE=0 " \
    "RALPH_NATIVE_SHELL_WRAPPER=0 "
}

pretool_json() {
  local event="${1:-}"
  local tool="${2:-}"
  local command="${3:-}"
  jq -nc \
    --arg event "$event" \
    --arg tool "$tool" \
    --arg command "$command" \
    --arg cwd "$WS" \
    '{
      hook_event_name: $event,
      tool_name: $tool,
      cwd: $cwd,
      workspace_roots: [$cwd],
      tool_input: {command: $command}
    }'
}

read_nudge_json() {
  local event="${1:-}"
  local tool="${2:-}"
  jq -nc \
    --arg event "$event" \
    --arg tool "$tool" \
    --arg cwd "$WS" \
    '{
      hook_event_name: $event,
      tool_name: $tool,
      cwd: $cwd,
      workspace_roots: [$cwd],
      tool_input: {path: "README.md"}
    }'
}

core_decision() {
  local runtime="${1:-}"
  local tool="${2:-}"
  local arguments="${3:-}"
  (
    export WORKSPACE="$WS"
    export RALPH_HOME="$REPO_ROOT"
    export RALPH_PROJECT_ROOT="$WS"
    export RALPH_AGENT_WORKSPACE="$WS"
    export RALPH_PLAN_WORKSPACE_ROOT="$WS/.ralph-workspace"
    export RALPH_PLAN_KEY="ks-hooks-secondary"
    export KILLSWITCH_RUNNER_PID=""
    source "$KILLSWITCH_CORE"
    local event_json
    event_json="$(jq -nc \
      --argjson schemaVersion 1 \
      --arg source "native-hook" \
      --arg runtime "$runtime" \
      --arg tool "$tool" \
      --arg action "execute" \
      --arg effect "write" \
      --arg resource "" \
      --arg arguments "$arguments" \
      '{schemaVersion:$schemaVersion,source:$source,runtime:$runtime,tool:$tool,action:$action,effect:$effect,resource:$resource,arguments:$arguments}')"
    killswitch_evaluate "$event_json"
  )
}

sentinel_path() {
  printf '%s/.ralph-workspace/security/kill-switch.ks-hooks-secondary.json' "$WS"
}

invoke_opencode_hook() {
  local hook="${1:-tool.execute.before}"
  local tool="${2:-bash}"
  local command="${3:-echo hi}"
  local extra="${4:-}"
  env $extra $(hook_env "${RALPH_MODE:-native}") \
    RALPH_OPENCODE_HOOK="$hook" \
    RALPH_OPENCODE_TOOL="$tool" \
    RALPH_OPENCODE_COMMAND="$command" \
    RALPH_OPENCODE_PLUGIN="$OPENCODE_PLUGIN" \
    node --experimental-strip-types --no-warnings - <<'NODE'
import { pathToFileURL } from "node:url";

const pluginPath = process.env.RALPH_OPENCODE_PLUGIN;
const hookName = process.env.RALPH_OPENCODE_HOOK || "tool.execute.before";
const tool = process.env.RALPH_OPENCODE_TOOL || "bash";
const command = process.env.RALPH_OPENCODE_COMMAND || "";
const workspace = process.env.WORKSPACE || process.cwd();
const mod = await import(pathToFileURL(pluginPath).href);
const plugin = await mod.RalphRuntimeHooks({ directory: workspace });
if (hookName === "permission.ask") {
  const output = { status: "ask" };
  await plugin["permission.ask"](
    {
      id: "perm-1",
      type: tool,
      sessionID: "s1",
      messageID: "m1",
      title: command || tool,
      metadata: { command },
      time: { created: Date.now() },
    },
    output,
  );
  process.stdout.write(`${JSON.stringify(output)}\n`);
  process.exit(0);
}
const output = { args: { command } };
try {
  await plugin["tool.execute.before"](
    { tool, sessionID: "s1", callID: "c1" },
    output,
  );
} catch {
  process.exit(0);
}
process.exit(0);
NODE
}

@test "opencode plugin exports permission.ask without a second plugin module" {
  grep -q '"permission.ask"' "$OPENCODE_PLUGIN"
  grep -q '"tool.execute.before"' "$OPENCODE_PLUGIN"
  grep -q '"tool.execute.after"' "$OPENCODE_PLUGIN"
  [ -f "$REPO_ROOT/bundle/.opencode/plugins/ralph-runtime-hooks.ts" ]
  [ ! -f "$REPO_ROOT/bundle/.opencode/plugins/ralph-killswitch-plugin.ts" ]
}

@test "opencode fatal denylist matches core evaluator and writes sentinel" {
  local expected
  expected="$(core_decision opencode bash "echo hi")"
  [ "$expected" = "fatal" ]

  run invoke_opencode_hook "tool.execute.before" "bash" "echo hi"
  [ "$status" -eq 0 ]
  [ -f "$(sentinel_path)" ]
  jq -e '.tool == "bash" and .reason == "tool denylist"' "$(sentinel_path)"
  jq -e '.runtime == "opencode" and .decision == "fatal" and .applied == true' "$RECORD"
}

@test "opencode permission.ask denies fatal tools without a competing plugin" {
  run invoke_opencode_hook "permission.ask" "bash" "echo hi"
  [ "$status" -eq 0 ]
  jq -e '.status == "deny"' <<<"$output"
  [ -f "$(sentinel_path)" ]
  jq -e '.runtime == "opencode" and .decision == "fatal" and .applied == true' "$RECORD"
}

@test "antigravity fatal denylist matches core evaluator and writes sentinel" {
  local payload expected
  payload="$(pretool_json preToolUse Shell "echo hi")"
  expected="$(core_decision antigravity Shell "echo hi")"
  [ "$expected" = "fatal" ]

  run bash -c "$(hook_env native) bash '$ANTIGRAVITY_HOOK'" <<<"$payload"
  [ "$status" -eq 77 ]
  [ -f "$(sentinel_path)" ]
  jq -e '.tool == "Shell" and .reason == "tool denylist"' "$(sentinel_path)"
  jq -e '.runtime == "antigravity" and .decision == "fatal" and .applied == true' "$RECORD"
}

@test "ralph-mode-off does not write a sentinel for opencode or antigravity" {
  local payload
  payload="$(pretool_json preToolUse Shell "echo hi")"

  RALPH_MODE=no run invoke_opencode_hook "tool.execute.before" "bash" "echo hi"
  [ "$status" -eq 0 ]
  [ ! -f "$(sentinel_path)" ]
  jq -e '.runtime == "opencode" and .decision == "skip" and .applied == false' "$RECORD"

  : >"$RECORD"
  run bash -c "$(hook_env no) bash '$ANTIGRAVITY_HOOK'" <<<"$payload"
  [ "$status" -eq 0 ]
  [ ! -f "$(sentinel_path)" ]
  jq -e '.runtime == "antigravity" and .decision == "skip" and .applied == false' "$RECORD"
}

@test "nudge does not write a sentinel for opencode or antigravity" {
  local payload
  payload="$(read_nudge_json preToolUse Grep)"

  run invoke_opencode_hook "tool.execute.before" "grep" ""
  [ "$status" -eq 0 ]
  [ ! -f "$(sentinel_path)" ]
  jq -e '.runtime == "opencode" and .decision == "nudge" and .applied == false' "$RECORD"

  : >"$RECORD"
  run bash -c "$(hook_env native) bash '$ANTIGRAVITY_HOOK'" <<<"$payload"
  [ "$status" -eq 0 ]
  [ ! -f "$(sentinel_path)" ]
  jq -e '.runtime == "antigravity" and .decision == "nudge" and .applied == false' "$RECORD"
}
