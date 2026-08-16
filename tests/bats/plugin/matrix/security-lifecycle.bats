#!/usr/bin/env bats

source "$BATS_TEST_DIRNAME/../../helper/load-lib.bash"

SETUP_RUNTIME_SH="$REPO_ROOT/bundle/.ralph/setup-runtime.sh"
PLUGIN_ROOT="$REPO_ROOT/plugins/ralph-orchestrator"
KILLSWITCH_CORE="$REPO_ROOT/bundle/.ralph/bash-lib/killswitch/killswitch-core.sh"
KILLSWITCH_FIXTURE="$REPO_ROOT/tests/fixtures/plugin/matrix/security-lifecycle/killswitch.json"
RUNTIMES=(claude cursor codex opencode antigravity)

setup() {
  TEST_TMPDIR="$(mktemp -d)"
  PROJECT="$TEST_TMPDIR/project"
  FAKE_BIN="$TEST_TMPDIR/bin"
  RALPH_RECORD="$TEST_TMPDIR/ralph-invocations.log"
  RECORD="$TEST_TMPDIR/hook-record.jsonl"
  NODE_BIN="$(command -v node || true)"
  mkdir -p "$PROJECT" "$FAKE_BIN" "$PROJECT/.ralph-workspace"
  cp "$KILLSWITCH_FIXTURE" "$PROJECT/.ralph-workspace/killswitch.json"
  printf 'plan\n' >"$PROJECT/plan.md"
  write_fake_ralph
}

teardown() {
  rm -rf "$TEST_TMPDIR"
}

runtime_dir() {
  case "$1" in
    antigravity) printf '%s/.agents' "$PROJECT" ;;
    *) printf '%s/.%s' "$PROJECT" "$1" ;;
  esac
}

mcp_path() {
  case "$1" in
    claude) printf '%s/.mcp.json' "$PROJECT" ;;
    cursor) printf '%s/mcp.json' "$(runtime_dir cursor)" ;;
    codex) printf '%s/config.toml' "$(runtime_dir codex)" ;;
    opencode) printf '%s/opencode.json' "$PROJECT" ;;
    antigravity) printf '%s/mcp_config.json' "$(runtime_dir antigravity)" ;;
  esac
}

bundle_hook_dir() {
  case "$1" in
    antigravity) printf '%s/bundle/.agents/hooks' "$REPO_ROOT" ;;
    *) printf '%s/bundle/.%s/hooks' "$REPO_ROOT" "$1" ;;
  esac
}

owned_hook_target() {
  local runtime="$1"
  if [[ "$runtime" == "opencode" ]]; then
    printf '%s/plugins/ralph-runtime-hooks.ts' "$(runtime_dir opencode)"
  else
    printf '%s/hooks/%s' "$(runtime_dir "$runtime")" \
      "$(basename "$(find "$(bundle_hook_dir "$runtime")" -type f -print -quit)")"
  fi
}

write_fake_ralph() {
  cat >"$FAKE_BIN/ralph" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"$RALPH_RECORD"
exit 0
EOF
  chmod +x "$FAKE_BIN/ralph"
}

write_mixed_mcp() {
  local runtime="$1" path
  path="$(mcp_path "$runtime")"
  mkdir -p "$(dirname "$path")"
  case "$runtime" in
    claude|cursor|antigravity)
      cat >"$path" <<'EOF'
{
  "mcpServers": {
    "ralph": {"command": "bash"},
    "native": {"command": "stay"}
  },
  "nativeSetting": "preserve-me"
}
EOF
      ;;
    codex)
      cat >"$path" <<'EOF'
# preserve this comment
[other]
native = true

[mcp_servers.native]
command = "stay"

[mcp_servers.ralph]
command = "bash"
EOF
      ;;
    opencode)
      cat >"$path" <<'EOF'
{
  // preserve this comment
  "mcp": {
    "ralph": {"type": "local", "command": ["bash"]},
    "native": {"command": ["stay"]}
  },
  "nativeSetting": "preserve-me"
}
EOF
      ;;
  esac
}

write_invalid_mcp() {
  local runtime="$1" path
  path="$(mcp_path "$runtime")"
  mkdir -p "$(dirname "$path")"
  printf 'not valid configuration {{{\n' >"$path"
}

seed_owned_setup() {
  local runtime="$1" source target
  target="$(owned_hook_target "$runtime")"
  mkdir -p "$(dirname "$target")"
  if [[ "$runtime" == "opencode" ]]; then
    source="$REPO_ROOT/bundle/.opencode/plugins/ralph-runtime-hooks.ts"
  else
    source="$(bundle_hook_dir "$runtime")/$(basename "$target")"
  fi
  cp "$source" "$target"
}

remove_runtime() {
  local runtime="$1"
  bash "$SETUP_RUNTIME_SH" \
    --runtime "$runtime" \
    --runtime-dir "$(runtime_dir "$runtime")" \
    --yes --remove --mcp
}

remove_runtime_all() {
  local runtime="$1"
  bash "$SETUP_RUNTIME_SH" \
    --runtime "$runtime" \
    --runtime-dir "$(runtime_dir "$runtime")" \
    --yes --remove --all
}

assert_native_mcp_survives() {
  local runtime="$1" path
  path="$(mcp_path "$runtime")"
  case "$runtime" in
    codex)
      ! grep -q 'mcp_servers.ralph' "$path"
      grep -q 'mcp_servers.native' "$path"
      grep -q 'preserve this comment' "$path"
      ;;
    opencode)
      if grep -q '"ralph"' "$path"; then return 1; fi
      grep -q '"native"' "$path"
      grep -q 'preserve this comment' "$path"
      ;;
    *)
      if grep -q '"ralph"' "$path"; then return 1; fi
      grep -q '"native"' "$path"
      grep -q 'preserve-me' "$path"
      ;;
  esac
}

hook_payload() {
  local event="$1" tool="$2" command="$3"
  jq -nc --arg event "$event" --arg tool "$tool" --arg command "$command" \
    --arg cwd "$PROJECT" '{hook_event_name:$event,tool_name:$tool,cwd:$cwd,workspace_roots:[$cwd],tool_input:{command:$command}}'
}

hook_env() {
  env \
    PATH="$FAKE_BIN:$PATH" \
    WORKSPACE="$PROJECT" \
    CLAUDE_PROJECT_DIR="$PROJECT" \
    RALPH_HOME="$REPO_ROOT" \
    RALPH_PROJECT_ROOT="$PROJECT" \
    RALPH_AGENT_WORKSPACE="$PROJECT" \
    RALPH_PLAN_WORKSPACE_ROOT="$PROJECT/.ralph-workspace" \
    RALPH_PLAN_KEY="migration-killswitch-review" \
    RALPH_BASH_LIB_DIR="$REPO_ROOT/bundle/.ralph/bash-lib" \
    KILLSWITCH_RUNNER_PID="" \
    RALPH_KILLSWITCH_HOOK_RECORD="$RECORD" \
    RALPH_BASH_REWRITE=0 \
    RALPH_NATIVE_SHELL_WRAPPER=0 \
    "$@"
}

invoke_native_hook() {
  local runtime="$1" mode="$2" tool="$3" command="$4" hook payload
  case "$runtime" in
    claude)
      hook="$PLUGIN_ROOT/claude/hooks/rewrite-bash-command.sh"
      payload="$(hook_payload PreToolUse "$tool" "$command")"
      ;;
    codex)
      hook="$PLUGIN_ROOT/codex/hooks/pre-tool-bash-policy.sh"
      payload="$(hook_payload PreToolUse "$tool" "$command")"
      ;;
    cursor)
      hook="$PLUGIN_ROOT/cursor/hooks/pre-tool-shell-policy.sh"
      payload="$(hook_payload preToolUse "$tool" "$command")"
      ;;
    antigravity)
      hook="$PLUGIN_ROOT/antigravity/hooks/pre-tool-shell-policy.sh"
      payload="$(hook_payload preToolUse "$tool" "$command")"
      ;;
    opencode)
      hook_env RALPH_MODE="$mode" \
        RALPH_OPENCODE_HOOK=tool.execute.before \
        RALPH_OPENCODE_TOOL="$tool" \
        RALPH_OPENCODE_COMMAND="$command" \
        RALPH_OPENCODE_PLUGIN="$REPO_ROOT/bundle/.opencode/plugins/ralph-runtime-hooks.ts" \
        "$NODE_BIN" --experimental-strip-types --no-warnings - <<'NODE'
import { pathToFileURL } from "node:url";
const pluginPath = process.env.RALPH_OPENCODE_PLUGIN;
const plugin = await (await import(pathToFileURL(pluginPath).href)).RalphRuntimeHooks({ directory: process.env.WORKSPACE });
const output = { args: { command: process.env.RALPH_OPENCODE_COMMAND || "" } };
try { await plugin["tool.execute.before"]({ tool: process.env.RALPH_OPENCODE_TOOL || "", sessionID: "s1", callID: "c1" }, output); } catch (_) {}
NODE
      return $?
      ;;
  esac
  hook_env RALPH_MODE="$mode" bash "$hook" <<<"$payload"
}

core_decision() {
  local runtime="$1" tool="$2" arguments="$3"
  hook_env RALPH_MODE=native bash -c '
    source "$1"
    event="$(jq -nc --arg runtime "$2" --arg tool "$3" --arg arguments "$4" \
      "{schemaVersion:1,source:\"native-hook\",runtime:\$runtime,tool:\$tool,action:\"execute\",effect:\"write\",resource:\"\",arguments:\$arguments}")"
    killswitch_evaluate "$event"
  ' _ "$KILLSWITCH_CORE" "$runtime" "$tool" "$arguments"
}

@test "five adapters remove only legacy Ralph entries and preserve native configuration" {
  local runtime marker before
  for runtime in "${RUNTIMES[@]}"; do
    write_mixed_mcp "$runtime"
    marker="$(runtime_dir "$runtime")/native-settings.txt"
    mkdir -p "$(dirname "$marker")"
    printf 'native bytes\n\000\377\n' >"$marker"
    before="$(cksum "$marker")"

    run remove_runtime "$runtime"
    [ "$status" -eq 0 ]
    assert_native_mcp_survives "$runtime"
    [ "$(cksum "$marker")" = "$before" ]
  done
}

@test "five adapters restore byte-exact owned files when later removal fails" {
  local runtime target source
  for runtime in "${RUNTIMES[@]}"; do
    seed_owned_setup "$runtime"
    target="$(owned_hook_target "$runtime")"
    if [[ "$runtime" == "opencode" ]]; then
      source="$REPO_ROOT/bundle/.opencode/plugins/ralph-runtime-hooks.ts"
    else
      source="$(bundle_hook_dir "$runtime")/$(basename "$target")"
    fi
    write_invalid_mcp "$runtime"

    run remove_runtime_all "$runtime"
    if [ "$status" -eq 0 ]; then
      printf 'adapter=%s check=journal-restoration: removal unexpectedly succeeded\n%s\n' \
        "$runtime" "$output" >&2
      return 1
    fi
    [ -f "$target" ]
    cmp -s "$source" "$target"
  done
}

@test "all five adapters use the shared execution gate exactly once" {
  local runtime exec_path preview confirmation_id
  for runtime in "${RUNTIMES[@]}"; do
    exec_path="$PLUGIN_ROOT/$runtime/shared/ralph-plugin-exec.sh"
    [ -f "$exec_path" ]
    grep -q 'Shared plugin execution gate' "$exec_path"
    jq -e '.exec == "shared/ralph-plugin-exec.sh"' \
      "$PLUGIN_ROOT/$runtime/host-manifest.json" >/dev/null

    preview="$(bash "$exec_path" preview --kind plan --plan "$PROJECT/plan.md" \
      --workspace "$PROJECT" --workspace-root "$PROJECT/.ralph-workspace" \
      --agent-workspace "$PROJECT" --runtime "$runtime")"
    confirmation_id="$(printf '%s\n' "$preview" | awk -F': ' '/^confirmationId: / {print $2}')"
    [ -n "$confirmation_id" ]

    : >"$RALPH_RECORD"
    run env PATH="$FAKE_BIN:/usr/bin:/bin:/usr/sbin:/sbin" \
      python3 "$REPO_ROOT/tests/fixtures/plugin/pty-confirm.py" "$confirmation_id" \
      bash "$exec_path" execute --kind plan --plan "$PROJECT/plan.md" \
      --workspace "$PROJECT" --workspace-root "$PROJECT/.ralph-workspace" \
      --agent-workspace "$PROJECT" --runtime "$runtime" \
      --confirmation-id "$confirmation_id" --request "run the plan"
    [ "$status" -eq 0 ]
    [ "$(wc -l <"$RALPH_RECORD" | tr -d ' ')" -eq 1 ]
    grep -q '^run --plan ' "$RALPH_RECORD"
  done
}

@test "fatal and nonfatal killswitch decisions have parity across five adapters" {
  local runtime expected target_tool target_event
  for runtime in "${RUNTIMES[@]}"; do
    case "$runtime" in
      opencode) target_tool=bash; target_event=tool.execute.before ;;
      claude|codex) target_tool=Bash; target_event=PreToolUse ;;
      *) target_tool=Shell; target_event=preToolUse ;;
    esac

    expected="$(core_decision "$runtime" "$target_tool" 'echo blocked')"
    [ "$expected" = fatal ]
    rm -f "$PROJECT/.ralph-workspace/security/kill-switch.migration-killswitch-review.json"
    : >"$RECORD"
    run invoke_native_hook "$runtime" native "$target_tool" 'echo blocked'
    if [[ "$runtime" == opencode ]]; then
      if [ "$status" -ne 0 ]; then
        printf 'adapter=%s check=fatal-killswitch: status=%s\n%s\n' \
          "$runtime" "$status" "$output" >&2
        return 1
      fi
    else
      [ "$status" -eq 77 ]
    fi
    [ -f "$PROJECT/.ralph-workspace/security/kill-switch.migration-killswitch-review.json" ]
    jq -e --arg runtime "$runtime" --arg tool "$target_tool" \
      '.runtime == $runtime and .tool == $tool and .decision == "fatal" and .applied == true' "$RECORD"

    rm -f "$PROJECT/.ralph-workspace/security/kill-switch.migration-killswitch-review.json"
    : >"$RECORD"
    run invoke_native_hook "$runtime" native Grep 'read-only probe'
    [ "$status" -eq 0 ]
    [ ! -f "$PROJECT/.ralph-workspace/security/kill-switch.migration-killswitch-review.json" ]
    jq -e --arg runtime "$runtime" '.runtime == $runtime and .decision == "nudge" and .applied == false' "$RECORD"
  done
}
