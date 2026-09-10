#!/usr/bin/env bats
# shellcheck shell=bash

source "$BATS_TEST_DIRNAME/../helper/load-lib.bash"
# shellcheck disable=SC1090
source "$BATS_TEST_DIRNAME/run-plan-invoke-test-helper.bash"

COMMON_LIB="$REPO_ROOT/bundle/.ralph/bash-lib/run-plan/run-plan-invoke-common.sh"
CLAUDE_LIB="$REPO_ROOT/bundle/.ralph/bash-lib/run-plan/run-plan-invoke-claude.sh"
CURSOR_LIB="$REPO_ROOT/bundle/.ralph/bash-lib/run-plan/run-plan-invoke-cursor.sh"
CODEX_LIB="$REPO_ROOT/bundle/.ralph/bash-lib/run-plan/run-plan-invoke-codex.sh"
OPENCODE_LIB="$REPO_ROOT/bundle/.ralph/bash-lib/run-plan/run-plan-invoke-opencode.sh"
ANTIGRAVITY_LIB="$REPO_ROOT/bundle/.ralph/bash-lib/run-plan/run-plan-invoke-antigravity.sh"

setup_runtime_invoke_test() {
  local invoke_lib="$1"
  # shellcheck disable=SC1090
  source "$invoke_lib"
  run_plan_invoke_test_setup_common
  run_plan_invoke_test_setup_pid_sidecar
}

teardown_runtime_invoke_test() {
  run_plan_invoke_test_teardown_common
}

@test "invoke common PID recording helper writes CLI PID to sidecar" {
  local tmpdir pid_file
  tmpdir="$(mktemp -d)"
  pid_file="$tmpdir/cli.pid"

  run bash -c '
    set -euo pipefail
    source "$1"
    RALPH_PLAN_INVOCATION_CLI_PID_FILE="$2"
    run_plan_invoke_common_record_cli_pid 12345
    if [[ -f "$2" ]]; then
      cat "$2"
    fi
  ' _ "$COMMON_LIB" "$pid_file"

  [ "$status" -eq 0 ]
  [ "$output" = "12345" ]

  rm -rf "$tmpdir"
}

@test "invoke common PID recording helper is safe when sidecar env not set" {
  run bash -c '
    set -euo pipefail
    source "$1"
    run_plan_invoke_common_record_cli_pid 12345
    echo "no error"
  ' _ "$COMMON_LIB"

  [ "$status" -eq 0 ]
  [[ "$output" == *"no error"* ]]
}

@test "PID recording helper correctly records multiple PIDs sequentially" {
  local tmpdir pid_file
  tmpdir="$(mktemp -d)"
  pid_file="$tmpdir/cli.pid"

  run bash -c '
    set -euo pipefail
    source "$1"
    RALPH_PLAN_INVOCATION_CLI_PID_FILE="$2"

    run_plan_invoke_common_record_cli_pid 111
    read -r pid1 < "$2"

    run_plan_invoke_common_record_cli_pid 222
    read -r pid2 < "$2"

    echo "First: $pid1"
    echo "Second: $pid2"
  ' _ "$COMMON_LIB" "$pid_file"

  [ "$status" -eq 0 ]
  [[ "$output" == *"First: 111"* ]]
  [[ "$output" == *"Second: 222"* ]]

  rm -rf "$tmpdir"
}

@test "shell syntax validation of invoke-common helper" {
  bash -n "$COMMON_LIB" || return 1
}

@test "shell syntax validation of claude invoke helper" {
  bash -n "$CLAUDE_LIB" || return 1
}

@test "shell syntax validation of cursor invoke helper" {
  bash -n "$CURSOR_LIB" || return 1
}

@test "shell syntax validation of codex invoke helper" {
  bash -n "$CODEX_LIB" || return 1
}

@test "shell syntax validation of opencode invoke helper" {
  bash -n "$OPENCODE_LIB" || return 1
}

@test "shell syntax validation of antigravity invoke helper" {
  bash -n "$ANTIGRAVITY_LIB" || return 1
}

@test "invoke helpers background runtime commands instead of using exec" {
  local tmpdir pid_file
  tmpdir="$(mktemp -d)"
  pid_file="$tmpdir/cli.pid"

  run bash -c '
    set -euo pipefail
    source "$1"

    RALPH_PLAN_INVOCATION_CLI_PID_FILE="$2"
    export RALPH_PLAN_INVOCATION_CLI_PID_FILE

    run_plan_invoke_common_record_cli_pid 999
    [[ -f "$2" ]] && cat "$2" || echo "NO_FILE"
  ' _ "$COMMON_LIB" "$pid_file"

  [ "$status" -eq 0 ]
  [ "$output" = "999" ]

  rm -rf "$tmpdir"
}

@test "claude launcher records live CLI PID, preserves exit status, and pipes stdin" {
  local record pid_marker stdin_capture
  setup_runtime_invoke_test "$CLAUDE_LIB"
  record="$TEST_TMPDIR/claude.args"
  pid_marker="$TEST_TMPDIR/claude.pid-marker"
  stdin_capture="$TEST_TMPDIR/claude.stdin"
  run_plan_invoke_test_write_live_pid_stub "claude" "$record" "$pid_marker" 42 "$stdin_capture"

  export PROMPT="claude-runtime-prompt"
  export RALPH_MODE=native

  ralph_run_plan_invoke_claude

  [ "$(cat "$EXIT_CODE_FILE")" = "42" ]
  [ "$(cat "$pid_marker")" = "live_pid_ok" ]
  [ "$(cat "$stdin_capture")" = "claude-runtime-prompt" ]

  teardown_runtime_invoke_test
}

@test "cursor launcher records live CLI PID and preserves exit status" {
  local record pid_marker
  setup_runtime_invoke_test "$CURSOR_LIB"
  record="$TEST_TMPDIR/cursor.args"
  pid_marker="$TEST_TMPDIR/cursor.pid-marker"
  run_plan_invoke_test_write_live_pid_stub "cursor-agent" "$record" "$pid_marker" 17

  export PROMPT="cursor-runtime-prompt"
  export RALPH_MODE=native

  ralph_run_plan_invoke_cursor

  [ "$(cat "$EXIT_CODE_FILE")" = "17" ]
  [ "$(cat "$pid_marker")" = "live_pid_ok" ]
  [[ "$(cat "$record")" == *"cursor-runtime-prompt"* ]]

  teardown_runtime_invoke_test
}

@test "codex launcher records live CLI PID, preserves exit status, and uses agent workspace cwd" {
  local record pid_marker agent_ws
  setup_runtime_invoke_test "$CODEX_LIB"
  agent_ws="$WORKSPACE/nested-agent"
  mkdir -p "$agent_ws"
  export RALPH_AGENT_WORKSPACE="$agent_ws"
  record="$TEST_TMPDIR/codex.args"
  pid_marker="$TEST_TMPDIR/codex.pid-marker"
  run_plan_invoke_test_write_live_pid_codex_stub "$record" "$pid_marker" 23

  export PROMPT="codex-runtime-prompt"
  export RALPH_MODE=native
  export CODEX_PLAN_NO_ADD_AGENTS_DIR=1

  ralph_run_plan_invoke_codex

  [ "$(cat "$EXIT_CODE_FILE")" = "23" ]
  [ "$(cat "$pid_marker")" = "live_pid_ok" ]
  [[ "$(cat "$record")" == *"exec"* ]]
  [[ "$(cat "$record")" == *"codex-runtime-prompt"* ]]
  [[ "$(cat "$record")" == *"cwd=$agent_ws"* ]]

  teardown_runtime_invoke_test
}

@test "opencode launcher records live CLI PID, preserves exit status, and uses agent workspace cwd" {
  local record pid_marker agent_ws
  setup_runtime_invoke_test "$OPENCODE_LIB"
  agent_ws="$WORKSPACE/nested-agent"
  mkdir -p "$agent_ws"
  export RALPH_AGENT_WORKSPACE="$agent_ws"

  record="$TEST_TMPDIR/opencode.args"
  pid_marker="$TEST_TMPDIR/opencode.pid-marker"
  run_plan_invoke_test_write_live_pid_stub "opencode" "$record" "$pid_marker" 31 "" \
    "printf 'cwd=%s\n' \"\$(pwd)\" >>\"$record\""

  export PROMPT="opencode-runtime-prompt"
  export RALPH_MODE=native

  ralph_run_plan_invoke_opencode

  [ "$(cat "$EXIT_CODE_FILE")" = "31" ]
  [ "$(cat "$pid_marker")" = "live_pid_ok" ]
  [[ "$(cat "$record")" == *"opencode-runtime-prompt"* ]]
  [[ "$(cat "$record")" == *"cwd=$agent_ws"* ]]

  teardown_runtime_invoke_test
}

@test "antigravity launcher records live CLI PID and preserves exit status" {
  local record pid_marker
  setup_runtime_invoke_test "$ANTIGRAVITY_LIB"
  record="$TEST_TMPDIR/agy.args"
  pid_marker="$TEST_TMPDIR/agy.pid-marker"
  run_plan_invoke_test_write_live_pid_stub "agy" "$record" "$pid_marker" 9

  export PROMPT="antigravity-runtime-prompt"
  export RALPH_MODE=native

  ralph_run_plan_invoke_antigravity

  [ "$(cat "$EXIT_CODE_FILE")" = "9" ]
  [ "$(cat "$pid_marker")" = "live_pid_ok" ]
  [[ "$(cat "$record")" == *"--print"* ]]
  [[ "$(cat "$record")" == *"antigravity-runtime-prompt"* ]]

  teardown_runtime_invoke_test
}

@test "run_plan_invoke_common_execute reports runtime exit status not tee status" {
  local tmpdir output_log exit_code_file
  tmpdir="$(mktemp -d)"
  output_log="$tmpdir/output.log"
  exit_code_file="$tmpdir/exit-code"

  run bash -c '
    set -euo pipefail
    source "$1"
    export OUTPUT_LOG="$2"
    export EXIT_CODE_FILE="$3"
    : >"$OUTPUT_LOG"
    export RALPH_PLAN_CLI_RESUME=0
    export RALPH_PLAN_CAPTURE_USAGE=0

    failing_runner() {
      exit 55
    }

    run_plan_invoke_common_execute failing_runner cursor ""
    cat "$EXIT_CODE_FILE"
  ' _ "$COMMON_LIB" "$output_log" "$exit_code_file"

  [ "$status" -eq 0 ]
  [ "$output" = "55" ]

  rm -rf "$tmpdir"
}

REASONING_LIB="$REPO_ROOT/bundle/.ralph/bash-lib/run-plan/run-plan-reasoning-effort.sh"

@test "reasoning effort precedence is deterministic" {
  run bash -c '
    set -euo pipefail
    source "$1"
    export PLAN_REASONING_EFFORT_CLI=""
    export CLAUDE_PLAN_REASONING_EFFORT=""
    resolved="$(ralph_resolve_reasoning_effort claude high)"
    [[ "$resolved" == "high" ]]
    export CLAUDE_PLAN_REASONING_EFFORT="low"
    resolved="$(ralph_resolve_reasoning_effort claude high)"
    [[ "$resolved" == "low" ]]
    export PLAN_REASONING_EFFORT_CLI="max"
    resolved="$(ralph_resolve_reasoning_effort claude high)"
    [[ "$resolved" == "max" ]]
    unset CLAUDE_PLAN_REASONING_EFFORT PLAN_REASONING_EFFORT_CLI
    resolved="$(ralph_resolve_reasoning_effort claude "")"
    [[ "$resolved" == "inherit" ]]
    echo ok
  ' _ "$REASONING_LIB"
  [ "$status" -eq 0 ]
  [[ "$output" == *"ok"* ]]
}

@test "claude invoke appends --effort when capability detected" {
  local record pid_marker
  setup_runtime_invoke_test "$CLAUDE_LIB"
  record="$TEST_TMPDIR/claude.args"
  pid_marker="$TEST_TMPDIR/claude.pid-marker"
  cat >"$BIN_DIR/claude" <<EOF
#!/usr/bin/env bash
if [[ "\${1:-}" == "--help" ]]; then
  echo '  --effort <level>  Effort level (low, medium, high, xhigh, max)'
  exit 0
fi
printf '%s\n' "\$@" >>"$record"
exit 0
EOF
  chmod +x "$BIN_DIR/claude"
  export CLAUDE_PLAN_CLI=claude
  export PROMPT="claude-effort-prompt"
  export RALPH_MODE=ralph
  export RALPH_REASONING_EFFORT=1
  export SELECTED_REASONING_EFFORT=high

  ralph_run_plan_invoke_claude

  [[ "$(cat "$record")" == *"--effort"* ]]
  [[ "$(cat "$record")" == *"high"* ]]
  [ "${RALPH_PLAN_REASONING_EFFORT_APPLIED:-}" = "high" ]

  teardown_runtime_invoke_test
}

@test "cursor invoke does not invent reasoning-effort flags" {
  local record pid_marker
  setup_runtime_invoke_test "$CURSOR_LIB"
  record="$TEST_TMPDIR/cursor.args"
  pid_marker="$TEST_TMPDIR/cursor.pid-marker"
  run_plan_invoke_test_write_live_pid_stub "cursor-agent" "$record" "$pid_marker" 0

  export PROMPT="cursor-effort-prompt"
  export RALPH_MODE=ralph
  export RALPH_REASONING_EFFORT=1
  export SELECTED_REASONING_EFFORT=high

  ralph_run_plan_invoke_cursor

  [[ "$(cat "$record")" != *"--effort"* ]]
  [[ "$(cat "$record")" != *"--reasoning-effort"* ]]
  [ "${RALPH_PLAN_REASONING_EFFORT_APPLIED:-inherit}" = "inherit" ]

  teardown_runtime_invoke_test
}

STRUCTURED_LIB="$REPO_ROOT/bundle/.ralph/bash-lib/run-plan/run-plan-structured-output.sh"

@test "claude invoke appends --json-schema with compact schema when capability detected" {
  local record pid_marker schema_file
  setup_runtime_invoke_test "$CLAUDE_LIB"
  record="$TEST_TMPDIR/claude.args"
  pid_marker="$TEST_TMPDIR/claude.pid-marker"
  schema_file="$WORKSPACE/schemas/verdict.schema.json"
  mkdir -p "$WORKSPACE/schemas"
  printf '%s\n' '{"type":"object","required":["status"],"properties":{"status":{"type":"string"}}}' >"$schema_file"
  cat >"$BIN_DIR/claude" <<EOF
#!/usr/bin/env bash
if [[ "\${1:-}" == "--help" ]]; then
  echo '  --json-schema <schema>  Constrain final response to JSON schema'
  exit 0
fi
printf '%s\n' "\$@" >>"$record"
exit 0
EOF
  chmod +x "$BIN_DIR/claude"
  export CLAUDE_PLAN_CLI=claude
  export PROMPT="claude-schema-prompt"
  export RALPH_MODE=ralph
  export RALPH_FINAL_OUTPUT_SCHEMA=1
  export RALPH_STRUCTURED_OUTPUT_SCHEMA="schemas/verdict.schema.json"

  ralph_run_plan_invoke_claude

  [[ "$(cat "$record")" == *"--json-schema"* ]]
  [[ "$(cat "$record")" == *'"type":"object"'* ]]
  [ "${RALPH_STRUCTURED_OUTPUT_CLI_APPLIED:-}" = "claude-json-schema" ]

  teardown_runtime_invoke_test
}

@test "codex invoke appends --output-schema when capability detected" {
  local record pid_marker schema_file
  setup_runtime_invoke_test "$CODEX_LIB"
  record="$TEST_TMPDIR/codex.args"
  pid_marker="$TEST_TMPDIR/codex.pid-marker"
  schema_file="$WORKSPACE/schemas/verdict.schema.json"
  mkdir -p "$WORKSPACE/schemas"
  printf '%s\n' '{"type":"object"}' >"$schema_file"
  run_plan_invoke_test_write_live_pid_codex_stub "$record" "$pid_marker" 0
  cat >"$BIN_DIR/codex" <<EOF
#!/usr/bin/env bash
if [[ "\${1:-}" == "--help" ]]; then
  echo '  --output-schema <path>  JSON schema file for structured output'
  exit 0
fi
if [[ "\$1" == "mcp" && "\${2:-}" == "--help" ]]; then
  echo 'Commands: add remove'
  exit 0
fi
if [[ "\$1" == "exec" && "\${2:-}" == "--help" ]]; then
  echo '  --config <key=value>  --strict-config'
  exit 0
fi
printf '%s\n' "\$@" >>"$record"
printf 'cwd=%s\n' "\$(pwd)" >>"$record"
if [[ -n "\${RALPH_PLAN_INVOCATION_CLI_PID_FILE:-}" ]]; then
  recorded="\$(cat "\$RALPH_PLAN_INVOCATION_CLI_PID_FILE" 2>/dev/null || true)"
  if [[ "\$recorded" == "\$\$" ]] && kill -0 "\$\$" 2>/dev/null; then
    echo live_pid_ok >"$pid_marker"
  fi
fi
exit 0
EOF
  chmod +x "$BIN_DIR/codex"
  export CODEX_PLAN_CLI=codex
  export PROMPT="codex-schema-prompt"
  export RALPH_MODE=native
  export RALPH_FINAL_OUTPUT_SCHEMA=1
  export RALPH_STRUCTURED_OUTPUT_SCHEMA="schemas/verdict.schema.json"
  export CODEX_PLAN_NO_ADD_AGENTS_DIR=1

  ralph_run_plan_invoke_codex

  [[ "$(cat "$record")" == *"--output-schema"* ]]
  [[ "$(cat "$record")" == *"schemas/verdict.schema.json"* ]]
  [ "${RALPH_STRUCTURED_OUTPUT_CLI_APPLIED:-}" = "codex-output-schema" ]

  teardown_runtime_invoke_test
}

@test "cursor invoke does not invent structured-output CLI flags" {
  local record pid_marker
  setup_runtime_invoke_test "$CURSOR_LIB"
  record="$TEST_TMPDIR/cursor.args"
  pid_marker="$TEST_TMPDIR/cursor.pid-marker"
  run_plan_invoke_test_write_live_pid_stub "cursor-agent" "$record" "$pid_marker" 0
  mkdir -p "$WORKSPACE/schemas"
  printf '%s\n' '{"type":"object"}' >"$WORKSPACE/schemas/verdict.schema.json"

  export PROMPT="cursor-schema-prompt"
  export RALPH_MODE=ralph
  export RALPH_FINAL_OUTPUT_SCHEMA=1
  export RALPH_STRUCTURED_OUTPUT_SCHEMA="schemas/verdict.schema.json"

  ralph_run_plan_invoke_cursor

  [[ "$(cat "$record")" != *"--json-schema"* ]]
  [[ "$(cat "$record")" != *"--output-schema"* ]]
  [ "${RALPH_STRUCTURED_OUTPUT_CLI_APPLIED:-none}" = "none" ]

  teardown_runtime_invoke_test
}

@test "structured output prompt contract is built when runtime lacks CLI support" {
  local prompt_ws
  prompt_ws="$(mktemp -d)"
  run bash -c '
    set -euo pipefail
    source "$1"
    export WORKSPACE="$2"
    export RALPH_PROJECT_ROOT="$2"
    export RALPH_MODE=ralph
    export RALPH_FINAL_OUTPUT_SCHEMA=1
    export RALPH_STRUCTURED_OUTPUT_SCHEMA="schemas/verdict.schema.json"
    mkdir -p "$WORKSPACE/schemas"
    printf "%s\n" "{\"type\":\"object\"}" >"$WORKSPACE/schemas/verdict.schema.json"
    block="$(run_plan_structured_output_build_prompt_block)"
    [[ "$block" == *"Structured final output (JSON only)"* ]]
    [[ "$block" == *"\"type\":\"object\""* ]]
    echo ok
  ' _ "$STRUCTURED_LIB" "$prompt_ws"
  [ "$status" -eq 0 ]
  [[ "$output" == *"ok"* ]]
  rm -rf "$prompt_ws"
}

@test "orch_resolve_final_output_schema infers router and grader defaults" {
  run bash -c '
    set -euo pipefail
    source "$1"
    router_stage="{\"id\":\"route\",\"router\":{\"allowedTargets\":[\"a\"],\"defaultTarget\":\"a\"}}"
    grader_stage="{\"id\":\"grade\",\"grader\":true,\"rubric\":\"rubrics/r.json\"}"
    [[ "$(orch_resolve_final_output_schema "$router_stage")" == *"router-decision.schema.json" ]]
    [[ "$(orch_resolve_final_output_schema "$grader_stage")" == *"rubric-result.schema.json" ]]
    echo ok
  ' _ "$STRUCTURED_LIB"
  [ "$status" -eq 0 ]
  [[ "$output" == *"ok"* ]]
}
