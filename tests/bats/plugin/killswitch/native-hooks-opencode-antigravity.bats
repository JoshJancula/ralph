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
  "tool_denylist": ["Bash", "Shell", "bash", "command_execution"],
  "allowed_tools": [],
  "banned_paths": [],
  "allowed_paths": [],
  "allowed_commands": [],
  "allowed_patterns": [],
  "denied_argument_patterns": [],
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

AGY_FIXTURES="$REPO_ROOT/tests/bats/fixtures/antigravity-hooks"

agy_payload() {
  local fixture="${1:-pretool-run-command.json}"
  local command="${2:-}"
  jq -c --arg ws "$WS" --arg cmd "$command" '
    .workspacePaths = [$ws]
    | if $cmd != "" then .toolCall.args.CommandLine = $cmd else . end
  ' "$AGY_FIXTURES/$fixture"
}

agy_run_hook() {
  local mode="${1:-native}"
  local overrides="${2:-}"
  local payload="${3:-}"
  run bash -c "$(hook_env "$mode") $overrides bash '$ANTIGRAVITY_HOOK'" <<<"$payload"
}

agy_deny_denylist() {
  jq '.tool_denylist += ["run_command"]' "$WS/.ralph-workspace/killswitch.json" >"$WS/ks.tmp"
  mv "$WS/ks.tmp" "$WS/.ralph-workspace/killswitch.json"
}

@test "antigravity killswitch fatal yields a deny decision and writes sentinel" {
  agy_deny_denylist
  agy_run_hook native "" "$(agy_payload pretool-run-command.json "echo hi")"
  [ "$status" -eq 0 ]
  jq -e '.decision == "deny" and (.reason | length > 0)' <<<"$output"
  [ -f "$(sentinel_path)" ]
  jq -e '.runtime == "antigravity" and .decision == "fatal" and .applied == true' "$RECORD"
}

@test "antigravity killswitch deny is skipped when ralph mode is off" {
  agy_deny_denylist
  agy_run_hook no "" "$(agy_payload pretool-run-command.json "echo hi")"
  [ "$status" -eq 0 ]
  [ "$output" = '{"decision":"allow"}' ]
  [ ! -f "$(sentinel_path)" ]
  jq -e '.runtime == "antigravity" and .decision == "skip" and .applied == false' "$RECORD"
}

@test "antigravity wrapper gate rewrites run_command into overwrite.CommandLine and logs it" {
  agy_run_hook native "RALPH_NATIVE_SHELL_WRAPPER=1 RALPH_BASH_REWRITE=1 RALPH_BASH_REWRITE_LOG=$WS/rewrite.jsonl" \
    "$(agy_payload pretool-run-command.json "pytest tests")"
  [ "$status" -eq 0 ]
  jq -e '.decision == "allow" and (.overwrite.CommandLine | contains("native-shell-wrapper"))' <<<"$output"
  [ -s "$WS/rewrite.jsonl" ]
}

@test "antigravity fail-open cases all print an allow decision" {
  local cases=(
    "native||"
    "native||not json at all"
    "native||{}"
    "native|RALPH_NATIVE_SHELL_WRAPPER=0 RALPH_BASH_REWRITE=0|$(agy_payload pretool-run-command.json "npm test")"
    "native|RALPH_NATIVE_SHELL_WRAPPER=1|$(agy_payload pretool-view-file.json)"
    "native|RALPH_NATIVE_SHELL_WRAPPER=1|$(jq -c '.workspacePaths = []' "$AGY_FIXTURES/pretool-run-command.json")"
    "native|RALPH_NATIVE_SHELL_WRAPPER=1|$(agy_payload pretool-run-command.json "npm test" | jq -c '.toolCall.args.CommandLine = ""')"
    "native|RALPH_NATIVE_SHELL_WRAPPER=1|$(agy_payload pretool-run-command.json "npm test" | jq -c '.workspacePaths = ["/nonexistent-agy-ws"]')"
  )
  local c mode overrides payload
  for c in "${cases[@]}"; do
    mode="${c%%|*}"
    c="${c#*|}"
    overrides="${c%%|*}"
    payload="${c#*|}"
    agy_run_hook "$mode" "$overrides" "$payload"
    [ "$status" -eq 0 ]
    [ "$output" = '{"decision":"allow"}' ]
  done
}

@test "nudge does not write a sentinel for opencode or antigravity" {
  local payload
  payload="$(agy_payload pretool-view-file.json)"

  run invoke_opencode_hook "tool.execute.before" "grep" ""
  [ "$status" -eq 0 ]
  [ ! -f "$(sentinel_path)" ]
  jq -e '.runtime == "opencode" and .decision == "nudge" and .applied == false' "$RECORD"

  : >"$RECORD"
  agy_run_hook native "" "$payload"
  [ "$status" -eq 0 ]
  [ "$output" = '{"decision":"allow"}' ]
  [ ! -f "$(sentinel_path)" ]
  jq -e '.runtime == "antigravity" and .decision == "nudge" and .applied == false' "$RECORD"
}
