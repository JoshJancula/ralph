#!/usr/bin/env bats
# shellcheck shell=bash

source "$BATS_TEST_DIRNAME/../helper/load-lib.bash"
# shellcheck disable=SC1090
source "$BATS_TEST_DIRNAME/../run-plan/run-plan-invoke-test-helper.bash"

RUNTIME_OVERLAY_LIB="$REPO_ROOT/bundle/.ralph/bash-lib/runtime-overlay/runtime-overlay.sh"
OPENCODE_OVERLAY_LIB="$REPO_ROOT/bundle/.ralph/bash-lib/runtime-overlay/runtime-overlay-opencode.sh"

setup() {
  # shellcheck disable=SC1090
  source "$REPO_ROOT/bundle/.ralph/bash-lib/run-plan/run-plan-invoke-opencode.sh"
  run_plan_invoke_test_setup_common
  export RALPH_PLAN_KEY="opencode-hybrid-overlay"
  export RUNTIME="opencode"
  export RALPH_PLAN_WORKSPACE_ROOT="$WORKSPACE/.ralph-workspace"
  mkdir -p "$RALPH_PLAN_WORKSPACE_ROOT/runtime-config/$RALPH_PLAN_KEY"

  unset RALPH_RUNTIME_MCP_RESOLVE_PATH RALPH_RUNTIME_MCP_AGENT_ENTRIES_JSON
}

teardown() {
  run_plan_invoke_test_teardown_common
}

@test "hybrid native hooks stage plugin into agent workspace as ts" {
  local agent_ws="$WORKSPACE/nested-agent"
  mkdir -p "$agent_ws"
  export RALPH_AGENT_WORKSPACE="$agent_ws"
  export RALPH_MODE=hybrid

  # shellcheck disable=SC1090
  source "$RUNTIME_OVERLAY_LIB"
  runtime_overlay_init_state "$RUNTIME" "$RALPH_PLAN_KEY"
  # shellcheck disable=SC1090
  source "$OPENCODE_OVERLAY_LIB"

  ralph_run_plan_sync_mode_knobs
  run_plan_invoke_opencode_native_hooks_prepare

  local staged="$agent_ws/.opencode/plugins/ralph-runtime-hooks.ts"
  [ -f "$staged" ]
  [[ "$staged" == *.ts ]]
  [ ! -f "$WORKSPACE/.opencode/plugins/ralph-runtime-hooks.ts" ]

  run_plan_invoke_opencode_native_hooks_cleanup
  [ ! -f "$staged" ]
}

@test "hybrid overlay telemetry separates requested configured and effective" {
  command -v python3 >/dev/null || skip "python3 required"

  local agent_ws="$WORKSPACE/agent-overlay"
  mkdir -p "$agent_ws"
  export RALPH_AGENT_WORKSPACE="$agent_ws"
  export RALPH_MODE=hybrid

  # shellcheck disable=SC1090
  source "$RUNTIME_OVERLAY_LIB"
  runtime_overlay_init_state "$RUNTIME" "$RALPH_PLAN_KEY"
  # shellcheck disable=SC1090
  source "$OPENCODE_OVERLAY_LIB"

  ralph_run_plan_sync_mode_knobs
  run_plan_invoke_opencode_native_hooks_prepare
  run_plan_invoke_opencode_native_hooks_cleanup
  runtime_overlay_write_summary

  summary_file="$(runtime_overlay_summary_path)"
  [ -f "$summary_file" ]

  python3 - <<'PY' "$summary_file"
import json, sys

summary = json.load(open(sys.argv[1]))
assert summary["tool_access_mode"] == "hybrid", summary
assert summary["mcp_effective"] == "true", summary
assert summary["native_hooks_requested"] == "auto", summary
assert summary["native_hooks_configured"] is True, summary
assert summary["native_hooks_effective"] == "false", summary
assert summary["native_hooks_used_on_run"] is False, summary
assert summary["native_hooks_reason"] == "plugin_injected_unproven_headless", summary
assert summary["native_hooks_observed_effect"] == "configured_but_no_surface_observed", summary
assert "opencode-plugin-local-load" in summary["capabilities"], summary
assert "opencode-hybrid-native-and-ralph-mcp" in summary["capabilities"], summary
PY
}

@test "hybrid opencode invoke keeps Ralph MCP and does not deny native tools" {
  command -v jq >/dev/null || skip "jq required"

  local agent_ws="$WORKSPACE/agent-invoke"
  local record config_capture
  mkdir -p "$agent_ws"
  export RALPH_AGENT_WORKSPACE="$agent_ws"
  export RALPH_MODE=hybrid

  record="$TEST_TMPDIR/opencode.args"
  config_capture="$TEST_TMPDIR/opencode.config.json"
  cat <<EOF >"$BIN_DIR/opencode"
#!/usr/bin/env bash
printf '%s\n' "\$@" >>"$record"
if [[ -n "\${OPENCODE_CONFIG:-}" && -f "\$OPENCODE_CONFIG" ]]; then
  cp "\$OPENCODE_CONFIG" "$config_capture"
fi
exit 0
EOF
  chmod +x "$BIN_DIR/opencode"
  export OPENCODE_PLAN_CLI="$BIN_DIR/opencode"

  export PROMPT="opencode-hybrid-overlay-prompt"
  ralph_run_plan_invoke_opencode

  [ -s "$config_capture" ]
  jq -e '.mcp.ralph.enabled == true' "$config_capture" >/dev/null

  local denied=0
  for tool in read grep glob bash; do
    outcome="$(jq -r --arg tool "$tool" '.permission[$tool] // empty | if type == "string" then . elif type == "object" then (.[] | select(type == "string")) else empty end' "$config_capture" 2>/dev/null | head -n1 || true)"
    if [[ "$outcome" == "deny" ]]; then
      denied=1
    fi
  done
  [ "$denied" -eq 0 ]

  local staged="$agent_ws/.opencode/plugins/ralph-runtime-hooks.ts"
  [ ! -f "$staged" ]

  summary_file="$WORKSPACE/.ralph-workspace/runtime-config/$RALPH_PLAN_KEY/summary.json"
  if [ -f "$summary_file" ]; then
    jq -e '.tool_access_mode == "hybrid"' "$summary_file" >/dev/null
    jq -e '.native_hooks_configured == true and .native_hooks_effective == "false"' "$summary_file" >/dev/null
  fi

  [[ "$(cat "$record")" == *"opencode-hybrid-overlay-prompt"* ]]
  [[ "$(cat "$record")" == *"build"* ]]
}
