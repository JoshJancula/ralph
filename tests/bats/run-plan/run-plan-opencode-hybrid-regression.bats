#!/usr/bin/env bats
# shellcheck shell=bash
# PLAN54-style regression: OpenCode hybrid keeps native and Ralph tools while
# MCP-proxy compaction windowed native exploration output and records telemetry.

source "$BATS_TEST_DIRNAME/../helper/load-lib.bash"
# shellcheck disable=SC1090
source "$BATS_TEST_DIRNAME/run-plan-invoke-test-helper.bash"

RUNTIME_OVERLAY_LIB="$REPO_ROOT/bundle/.ralph/bash-lib/runtime-overlay/runtime-overlay.sh"
OPENCODE_OVERLAY_LIB="$REPO_ROOT/bundle/.ralph/bash-lib/runtime-overlay/runtime-overlay-opencode.sh"
FIXTURE_DIR="$REPO_ROOT/tests/fixtures/opencode-hybrid-regression"
FIXTURE_PATH="$FIXTURE_DIR/plan54-tool-stream.jsonl"
HYBRID_PY_TEST="$REPO_ROOT/tests/python/test_opencode_hybrid_regression.py"

setup() {
  # shellcheck disable=SC1090
  source "$REPO_ROOT/bundle/.ralph/bash-lib/run-plan/run-plan-invoke-opencode.sh"
  run_plan_invoke_test_setup_common
  export RALPH_PLAN_KEY="plan54-hybrid-regression"
  export RALPH_ARTIFACT_NS="plan54-hybrid-regression"
  export RUNTIME="opencode"
  export RALPH_PLAN_WORKSPACE_ROOT="$WORKSPACE/.ralph-workspace"
  mkdir -p "$RALPH_PLAN_WORKSPACE_ROOT/runtime-config/$RALPH_PLAN_KEY"

  unset RALPH_RUNTIME_MCP_RESOLVE_PATH RALPH_RUNTIME_MCP_AGENT_ENTRIES_JSON
}

teardown() {
  run_plan_invoke_test_teardown_common
}

@test "hybrid overlay defaults to mcp_proxy_compaction without revalidation artifact" {
  local agent_ws="$WORKSPACE/agent-compaction"
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
assert summary["native_shell_compaction_authoritative"] == "mcp_proxy_compaction", summary
assert summary["native_hooks_effective"] == "false", summary
assert "opencode-hybrid-native-and-ralph-mcp" in summary["capabilities"], summary
PY
}

@test "hybrid invoke keeps Ralph MCP and native exploration tools available" {
  command -v jq >/dev/null || skip "jq required"

  local agent_ws="$WORKSPACE/agent-dual-tools"
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

  export PROMPT="plan54-hybrid-regression-prompt"
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
}

@test "plan54 hybrid regression fixture exists and python suite passes" {
  command -v python3 >/dev/null || skip "python3 required"
  [ -f "$HYBRID_PY_TEST" ]

  run bash "$REPO_ROOT/scripts/run-python-unit-tests.sh" -k opencode_hybrid
  [ "$status" -eq 0 ]

  [ -s "$FIXTURE_PATH" ]
  local line_count
  line_count="$(wc -l <"$FIXTURE_PATH" | tr -d ' ')"
  [ "$line_count" -ge 40 ]
}

@test "plan54 fixture demux classifies native and ralph proxy tools" {
  command -v python3 >/dev/null || skip "python3 required"
  [ -f "$FIXTURE_PATH" ]

  local demux usage_file
  demux="$REPO_ROOT/bundle/.ralph/python/run-plan-cli-json-demux.py"
  usage_file="$TEST_TMPDIR/plan54.usage.json"

  run python3 - "$demux" "$usage_file" "$FIXTURE_PATH" <<'PY'
import json, subprocess, sys

demux = sys.argv[1]
usage_file = sys.argv[2]
fixture = sys.argv[3]

with open(fixture, encoding="utf-8") as fh:
    stdin_data = fh.read().encode()

proc = subprocess.run([sys.executable, demux, "opencode", "", usage_file], input=stdin_data, capture_output=True)
assert proc.returncode == 0, proc.stderr.decode()

with open(usage_file) as fh:
    usage = json.load(fh)

assert usage["tool_calls_total"] >= 40, usage
assert usage["native_read_compatibility_calls"] == 20, usage
assert usage["native_search_calls"] == 14, usage
assert usage["native_shell_calls"] == 5, usage
assert usage["ralph_proxy_calls"] == 5, usage
assert usage["repeated_read_extra_calls"] >= 7, usage
assert usage["cache_read_input_tokens"] == 1260150, usage
print("plan54 hybrid demux assertions passed")
PY

  [ "$status" -eq 0 ]
  [[ "$output" == *"plan54 hybrid demux assertions passed"* ]]
}
