#!/usr/bin/env bats

source "$BATS_TEST_DIRNAME/../helper/load-lib.bash"

ORCHESTRATOR_SH="$REPO_ROOT/bundle/.ralph/orchestrator.sh"
RALPH_DIR="$REPO_ROOT/bundle/.ralph"

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
  "description": "Orchestration MCP test agent $agent",
  "rules": [],
  "skills": [],
  "output_artifacts": [
    {
      "path": ".ralph-workspace/artifacts/{{ARTIFACT_NS}}/$agent.md",
      "required": true
    }
  ],
  "mcp_servers": $mcp_json
}
EOF
}

setup_orchestrator_mcp_workspace() {
  local workspace
  workspace="$(mktemp -d)"
  mkdir -p "$workspace/.ralph/bash-lib/orchestrator" "$workspace/.ralph-workspace/logs"
  cp "$RALPH_DIR/ralph-env-safety.sh" "$workspace/.ralph/"
  cp "$RALPH_DIR/bash-lib/error-handling.sh" "$workspace/.ralph/bash-lib/"
  cp -R "$RALPH_DIR/bash-lib/run-plan" "$workspace/.ralph/bash-lib/"
  cp "$RALPH_DIR/bash-lib/plan-todo.sh" "$workspace/.ralph/bash-lib/"
  cp "$RALPH_DIR/bash-lib/runtime-resolve.sh" "$workspace/.ralph/bash-lib/"
  cp "$RALPH_DIR/bash-lib/runtime-normalize.sh" "$workspace/.ralph/bash-lib/"
  cp -R "$RALPH_DIR/bash-lib/mcp" "$workspace/.ralph/bash-lib/"
  cp "$RALPH_DIR/bash-lib/artifacts.sh" "$workspace/.ralph/bash-lib/"
  cp "$RALPH_DIR/bash-lib/orchestrator/orchestrator-logging.sh" "$workspace/.ralph/bash-lib/orchestrator/"
  cp "$RALPH_DIR/bash-lib/orchestrator/orchestrator-lib.sh" "$workspace/.ralph/bash-lib/orchestrator/"
  cp "$RALPH_DIR/bash-lib/ralph-format-elapsed.sh" "$workspace/.ralph/bash-lib/"
  cp "$RALPH_DIR/bash-lib/orchestrator/orchestrator-verify.sh" "$workspace/.ralph/bash-lib/orchestrator/"
  cp "$RALPH_DIR/bash-lib/orchestrator/orchestrator-handoffs.sh" "$workspace/.ralph/bash-lib/orchestrator/"
  cp "$RALPH_DIR/bash-lib/orchestrator/orchestrator-stages.sh" "$workspace/.ralph/bash-lib/orchestrator/"
  cp -R "$RALPH_DIR/bash-lib/agent-config" "$workspace/.ralph/bash-lib/"
  cp -R "$RALPH_DIR/bash-lib/agent-source" "$workspace/.ralph/bash-lib/"
  cp -R "$RALPH_DIR/bash-lib/runtime-config" "$workspace/.ralph/bash-lib/"
  cp -R "$RALPH_DIR/python" "$workspace/.ralph/"
  cp "$RALPH_DIR/bash-lib/review-status.sh" "$workspace/.ralph/bash-lib/"
  cat <<STUB >"$workspace/.ralph/run-plan.sh"
#!/usr/bin/env bash
set -euo pipefail
bundle_ralph_dir="$RALPH_DIR"
agent=""
runtime=""
workspace=""
while ((\$# > 0)); do
  case "\$1" in
    --agent)
      agent="\${2:-}"
      shift 2
      ;;
    --runtime)
      runtime="\${2:-}"
      shift 2
      ;;
    --workspace)
      workspace="\${2:-}"
      shift 2
      ;;
    *)
      shift
      ;;
  esac
done
[[ -n "\$workspace" ]] || workspace="\${PWD}"
export WORKSPACE="\$workspace"
export RALPH_PROJECT_ROOT="\$workspace"
export SCRIPT_DIR="\$bundle_ralph_dir"
export AGENT_CONFIG_TOOL="\$bundle_ralph_dir/agent-config-tool.sh"
export PREBUILT_AGENT="\$agent"
export RUNTIME="\$runtime"
export AGENTS_ROOT_REL=".\${runtime}/agents"
export HOME="\${MCP_TEST_HOME:-\$HOME}"
export RALPH_RUNTIME_MCP_HOME="\${MCP_TEST_HOME:-\$HOME}"
unset RALPH_MODE RALPH_AGENT_TOOL_ACCESS
# shellcheck source=/dev/null
source "\$bundle_ralph_dir/bash-lib/run-plan/run-plan-routing.sh"
# shellcheck source=/dev/null
source "\$bundle_ralph_dir/bash-lib/runtime-config/runtime-config-mcp.sh"
ralph_run_plan_export_agent_mcp_overlay "\$workspace" "\$agent"
if ! ralph_runtime_config_mcp_resolve "\$runtime" "\$workspace" "\$agent" "\$workspace"; then
  echo "MCP overlay preflight failed for agent=\$agent runtime=\$runtime" >&2
  exit 1
fi
names="\$(jq -c '.mcp_effective_names // []' <<<"\${RALPH_RUNTIME_MCP_SUMMARY_JSON:-[]}")"
printf 'agent=%s runtime=%s names=%s\n' "\$agent" "\$runtime" "\$names" >>"\$workspace/.ralph-workspace/mcp-stage-capture.log"
exit 0
STUB
  chmod +x "$workspace/.ralph/run-plan.sh"
  printf '%s' "$workspace"
}

write_plan_file() {
  local workspace="$1"
  local plan_rel="$2"
  mkdir -p "$workspace/$(dirname "$plan_rel")"
  cat <<'PLAN' >"$workspace/$plan_rel"
# Plan
- [x] done
PLAN
}

write_artifact_file() {
  local workspace="$1"
  local artifact_rel="$2"
  mkdir -p "$workspace/$(dirname "$artifact_rel")"
  printf 'artifact for %s\n' "$(basename "$artifact_rel")" >"$workspace/$artifact_rel"
}

setup() {
  [ -f "$ORCHESTRATOR_SH" ] || skip "orchestrator missing"
  command -v python3 >/dev/null 2>&1 || skip "python3 unavailable"
  command -v jq >/dev/null 2>&1 || skip "jq required"
}

@test "orchestrator stages with different agents receive different MCP catalogs" {
  local workspace isolated_home orch_file capture_file
  workspace="$(setup_orchestrator_mcp_workspace)"
  capture_file="$workspace/.ralph-workspace/mcp-stage-capture.log"
  isolated_home="$workspace/home"
  mkdir -p "$isolated_home/.cursor"
  printf '%s\n' '{"mcpServers":{"shared":{"command":"shared-cmd"}}}' >"$isolated_home/.cursor/mcp.json"

  write_mcp_agent_fixture "$workspace" cursor agent-alpha stub-model \
    '[{"name":"alpha-srv","transport":"stdio","command":"alpha-cmd"}]'
  write_mcp_agent_fixture "$workspace" cursor agent-beta stub-model \
    '[{"name":"beta-srv","transport":"stdio","command":"beta-cmd"}]'

  orch_file="$workspace/agent-mcp.orch.json"
  cat <<'ORCH' >"$orch_file"
{
  "name": "bats agent mcp",
  "namespace": "agent-mcp",
  "stages": [
    {
      "id": "alpha-stage",
      "agent": "agent-alpha",
      "runtime": "cursor",
      "plan": "stages/alpha.plan.md",
      "sessionResume": false,
      "artifacts": [
        { "path": ".ralph-workspace/artifacts/agent-mcp/agent-alpha.md", "required": true }
      ]
    },
    {
      "id": "beta-stage",
      "agent": "agent-beta",
      "runtime": "cursor",
      "plan": "stages/beta.plan.md",
      "sessionResume": false,
      "artifacts": [
        { "path": ".ralph-workspace/artifacts/agent-mcp/agent-beta.md", "required": true }
      ]
    }
  ]
}
ORCH
  write_plan_file "$workspace" "stages/alpha.plan.md"
  write_plan_file "$workspace" "stages/beta.plan.md"
  write_artifact_file "$workspace" ".ralph-workspace/artifacts/agent-mcp/agent-alpha.md"
  write_artifact_file "$workspace" ".ralph-workspace/artifacts/agent-mcp/agent-beta.md"

  run env MCP_TEST_HOME="$isolated_home" \
    bash "$ORCHESTRATOR_SH" --orchestration "$orch_file" "$workspace" 2>&1
  [ "$status" -eq 0 ] || { echo "FAIL: $output"; rm -rf "$workspace"; return 1; }

  [ -s "$capture_file" ]
  grep -q 'agent=agent-alpha' "$capture_file"
  grep -q 'agent=agent-beta' "$capture_file"
  grep -q 'alpha-srv' "$capture_file"
  grep -q 'beta-srv' "$capture_file"

  rm -rf "$workspace"
}

@test "orchestrator stage fails before run-plan completes when agent MCP reference is missing" {
  local workspace isolated_home orch_file capture_file
  workspace="$(setup_orchestrator_mcp_workspace)"
  capture_file="$workspace/.ralph-workspace/mcp-stage-capture.log"
  isolated_home="$workspace/home"
  mkdir -p "$isolated_home/.cursor"
  printf '%s\n' '{"mcpServers":{"shared":{"command":"shared-cmd"}}}' >"$isolated_home/.cursor/mcp.json"

  write_mcp_agent_fixture "$workspace" cursor bad-agent stub-model \
    '["missing-ambient-server"]'

  orch_file="$workspace/bad-agent-mcp.orch.json"
  cat <<'ORCH' >"$orch_file"
{
  "name": "bats bad agent mcp",
  "namespace": "bad-agent-mcp",
  "stages": [
    {
      "id": "bad-stage",
      "agent": "bad-agent",
      "runtime": "cursor",
      "plan": "stages/bad.plan.md",
      "sessionResume": false,
      "artifacts": [
        { "path": ".ralph-workspace/artifacts/bad-agent-mcp/bad-agent.md", "required": true }
      ]
    }
  ]
}
ORCH
  write_plan_file "$workspace" "stages/bad.plan.md"
  write_artifact_file "$workspace" ".ralph-workspace/artifacts/bad-agent-mcp/bad-agent.md"

  run env MCP_TEST_HOME="$isolated_home" \
    bash "$ORCHESTRATOR_SH" --orchestration "$orch_file" "$workspace" 2>&1
  [ "$status" -ne 0 ]
  [[ "$output" == *"Orchestrator stopped: step 1 failed"* ]]
  [ ! -s "$capture_file" ]

  rm -rf "$workspace"
}
