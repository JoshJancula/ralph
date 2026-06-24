#!/usr/bin/env bats

source "$BATS_TEST_DIRNAME/../helper/load-lib.bash"

RUN_PLAN_SH="$REPO_ROOT/bundle/.ralph/run-plan.sh"
ROUTING_LIB="$REPO_ROOT/bundle/.ralph/bash-lib/run-plan/run-plan-routing.sh"
AGENT_CONFIG_TOOL="$REPO_ROOT/bundle/.ralph/agent-config-tool.sh"

write_mcp_agent_fixture() {
  local workspace="$1"
  local runtime="$2"
  local agent="$3"
  local model="$4"
  local mcp_json="$5"

  mkdir -p "$workspace/.$runtime/agents/$agent"
  cat >"$workspace/.$runtime/agents/$agent/config.json" <<EOF
{
  "name": "$agent",
  "model": "$model",
  "description": "MCP integration test agent $agent",
  "rules": [],
  "skills": [],
  "output_artifacts": [],
  "mcp_servers": $mcp_json
}
EOF
}

write_select_model_stub() {
  local workspace="$1"
  local select_model_dir="$workspace/.cursor/ralph"
  mkdir -p "$select_model_dir"
  cat <<'EOF' >"$select_model_dir/select-model.sh"
#!/usr/bin/env bash
select_model_cursor() {
  if [[ "$1" == "--batch" ]]; then
    shift
  fi
  printf '%s\n' "stub-model"
}
export -f select_model_cursor >/dev/null 2>&1 || true
EOF
  chmod +x "$select_model_dir/select-model.sh"
}

write_mcp_capture_cursor_stub() {
  local bin_dir="$1"
  local capture_file="$2"
  local plan_file="$3"
  local workspace="$4"

  cat >"$bin_dir/cursor-agent" <<EOF
#!/usr/bin/env bash
set -euo pipefail
if [[ -f "$workspace/.cursor/mcp.json" ]]; then
  printf 'MCP:%s\n' "\$(cat "$workspace/.cursor/mcp.json")" >>"$capture_file"
else
  printf 'MCP:{}\n' >>"$capture_file"
fi
python3 - "$plan_file" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text()
if "status: open" in text:
    path.write_text(text.replace("status: open", "status: completed", 1))
elif "- [ ]" in text:
    path.write_text(text.replace("- [ ]", "- [x]", 1))
PY
printf '%s\n' "AGENT_INVOCATION_COMPLETE"
exit 0
EOF
  chmod +x "$bin_dir/cursor-agent"
}

setup() {
  [ -f "$RUN_PLAN_SH" ] || skip "bundle run-plan missing"
  [ -f "$ROUTING_LIB" ] || skip "routing helper missing"
  [ -f "$AGENT_CONFIG_TOOL" ] || skip "agent-config-tool missing"
  command -v python3 >/dev/null 2>&1 || skip "python3 unavailable"
  command -v jq >/dev/null 2>&1 || skip "jq required"
}

@test "export_agent_mcp_overlay switches normalized entries per selected agent" {
  local workspace
  workspace="$(mktemp -d)"

  write_mcp_agent_fixture "$workspace" cursor agent-alpha stub-model \
    '[{"name":"alpha-srv","transport":"stdio","command":"alpha-cmd"}]'
  write_mcp_agent_fixture "$workspace" cursor agent-beta stub-model \
    '[{"name":"beta-srv","transport":"stdio","command":"beta-cmd"}]'

  run bash -c '
    set -euo pipefail
    export WORKSPACE="$1"
    export SCRIPT_DIR="$2"
    export AGENT_CONFIG_TOOL="$2/agent-config-tool.sh"
    export RUNTIME=cursor
    export AGENTS_ROOT_REL=".cursor/agents"
  # shellcheck source=/dev/null
    source "$3"
    ralph_run_plan_export_agent_mcp_overlay "$WORKSPACE" agent-alpha
    printf "alpha=%s\n" "${RALPH_RUNTIME_MCP_AGENT_ENTRIES_JSON:-}"
    ralph_run_plan_export_agent_mcp_overlay "$WORKSPACE" agent-beta
    printf "beta=%s\n" "${RALPH_RUNTIME_MCP_AGENT_ENTRIES_JSON:-}"
    unset RALPH_RUNTIME_MCP_AGENT_ENTRIES_JSON
    ralph_run_plan_export_agent_mcp_overlay "$WORKSPACE" agent-alpha
    printf "alpha2=%s\n" "${RALPH_RUNTIME_MCP_AGENT_ENTRIES_JSON:-}"
  ' _ "$workspace" "$REPO_ROOT/bundle/.ralph" "$ROUTING_LIB"

  [ "$status" -eq 0 ]
  grep -q 'alpha=' <<<"$output"
  grep -q 'beta=' <<<"$output"
  grep -q 'alpha-srv' <<<"$output"
  grep -q 'beta-srv' <<<"$output"
  grep -q 'alpha2=' <<<"$output"

  rm -rf "$workspace"
}

@test "yaml plan routing gives each todo the selected agent MCP catalog" {
  local workspace bin_dir session_home plan_file capture_file registry_file isolated_home
  workspace="$(mktemp -d)"
  bin_dir="$workspace/bin"
  session_home="$workspace/.sessions"
  isolated_home="$workspace/home"
  capture_file="$workspace/mcp-capture.log"
  registry_file="$(mktemp)"
  mkdir -p "$bin_dir" "$session_home" "$isolated_home/.cursor"

  write_select_model_stub "$workspace"
  write_mcp_agent_fixture "$workspace" cursor agent-alpha stub-model \
    '[{"name":"alpha-srv","transport":"stdio","command":"alpha-cmd"}]'
  write_mcp_agent_fixture "$workspace" cursor agent-beta stub-model \
    '[{"name":"beta-srv","transport":"stdio","command":"beta-cmd"}]'
  printf '%s\n' '{"mcpServers":{"shared":{"command":"shared-cmd"}}}' >"$workspace/.cursor/mcp.json"

  plan_file="$workspace/PLAN.md"
  cat >"$plan_file" <<'EOF'
---
execution: orchestration
pipeline:
  stages:
    - id: alpha
      runtime: cursor
      agent: agent-alpha
      model: stub-model
      sessionStrategy: fresh
    - id: beta
      runtime: cursor
      agent: agent-beta
      model: stub-model
      sessionStrategy: fresh
todos:
  - id: first
    stage: alpha
    runtime: cursor
    agent: agent-alpha
    model: stub-model
    status: open
    content: Alpha MCP todo
  - id: second
    stage: beta
    runtime: cursor
    agent: agent-beta
    model: stub-model
    status: open
    content: Beta MCP todo
---
EOF

  write_mcp_capture_cursor_stub "$bin_dir" "$capture_file" "$plan_file" "$workspace"

  run bash -c '
    set -euo pipefail
    cd "$1"
    export PATH="$2:$PATH"
    export HOME="$3"
    export RALPH_RUNTIME_MCP_HOME="$3"
    export RALPH_USAGE_RISKS_ACKNOWLEDGED=1
    export RALPH_PLAN_SESSION_HOME="$4"
    export RALPH_PLAN_NO_CAFFEINATE=1
    export RALPH_LAUNCHER_PID=$$
    export RALPH_WORKSPACES_FILE="$6"
    export CURSOR_PLAN_MODEL="stub-model"
    export CURSOR_PLAN_MAX_ITER=2
    unset RALPH_AGENT_TOOL_ACCESS RALPH_NATIVE_HOOKS RALPH_MODE
    "$5" --runtime cursor --plan PLAN.md --agent agent-alpha --non-interactive --model stub-model --workspace "$1"
  ' _ "$workspace" "$bin_dir" "$isolated_home" "$session_home" "$RUN_PLAN_SH" "$registry_file"

  [ "$status" -eq 0 ]
  [ -s "$capture_file" ]
  grep -q 'alpha-srv' "$capture_file"
  grep -q 'beta-srv' "$capture_file"
  ! grep -q 'alpha-srv.*beta-srv' "$capture_file"

  rm -f "$registry_file"
  rm -rf "$workspace"
}

@test "plan run fails MCP preflight before cursor-agent when agent reference is missing" {
  local workspace bin_dir session_home plan_file cursor_record registry_file isolated_home
  workspace="$(mktemp -d)"
  bin_dir="$workspace/bin"
  session_home="$workspace/.sessions"
  isolated_home="$workspace/home"
  cursor_record="$workspace/cursor.args"
  registry_file="$(mktemp)"
  mkdir -p "$bin_dir" "$session_home" "$isolated_home/.cursor"

  write_select_model_stub "$workspace"
  write_mcp_agent_fixture "$workspace" cursor bad-agent stub-model \
    '["missing-ambient-server"]'
  printf '%s\n' '{"mcpServers":{"shared":{"command":"shared-cmd"}}}' >"$workspace/.cursor/mcp.json"

  plan_file="$workspace/PLAN.md"
  cat <<'EOF' >"$plan_file"
# Missing MCP reference
- [ ] should fail before CLI
EOF

  cat <<'EOF' >"$bin_dir/cursor-agent"
#!/usr/bin/env bash
printf '%s\n' "$@" >>"$cursor_record"
printf '%s\n' "AGENT_INVOCATION_COMPLETE"
exit 0
EOF
  chmod +x "$bin_dir/cursor-agent"

  run bash -c '
    set -euo pipefail
    cd "$1"
    export PATH="$2:$PATH"
    export HOME="$3"
    export RALPH_RUNTIME_MCP_HOME="$3"
    export RALPH_USAGE_RISKS_ACKNOWLEDGED=1
    export RALPH_PLAN_SESSION_HOME="$4"
    export RALPH_PLAN_NO_CAFFEINATE=1
    export RALPH_LAUNCHER_PID=$$
    export RALPH_WORKSPACES_FILE="$6"
    export CURSOR_PLAN_MODEL="stub-model"
    export CURSOR_PLAN_MAX_ITER=1
    unset RALPH_AGENT_TOOL_ACCESS RALPH_NATIVE_HOOKS RALPH_MODE
    "$5" --runtime cursor --plan PLAN.md --agent bad-agent --non-interactive --model stub-model --workspace "$1"
  ' _ "$workspace" "$bin_dir" "$isolated_home" "$session_home" "$RUN_PLAN_SH" "$registry_file"

  [ "$status" -ne 0 ]
  [[ "$output" == *"MCP overlay preflight failed"* ]]
  [ ! -s "$cursor_record" ]

  rm -f "$registry_file"
  rm -rf "$workspace"
}

@test "native mode does not advertise plan memory tools in compact catalog" {
  local tools_lib="$REPO_ROOT/bundle/.ralph/bash-lib/mcp-proxy/mcp-proxy-tools.sh"
  local policy_lib="$REPO_ROOT/bundle/.ralph/bash-lib/mcp-proxy/mcp-proxy-policy.sh"

  run env \
    RALPH_MODE=native \
    RALPH_MCP_PROXY_POLICY_OWNED_TOOLS_ENABLED=1 \
    RALPH_MCP_PROXY_OWNED_TOOLS_FORCE=1 \
    RALPH_MCP_PROXY_RUNTIME=claude \
    bash -c '
    source "$1"
    source "$2"
    tools="$(ralph_mcp_proxy_owned_tools_json)"
    printf "%s\n" "$tools" | jq -e "map(.name) | index(\"ralph_proxy_memory_list\") == null"
  ' _ "$policy_lib" "$tools_lib"

  [ "$status" -eq 0 ]
}
