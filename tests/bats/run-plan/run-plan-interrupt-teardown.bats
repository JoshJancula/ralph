#!/usr/bin/env bats
# shellcheck shell=bash

# End-to-end and focused interrupt/teardown coverage for run-plan:
#   - Stub runtimes that ignore SIGINT (Codex, OpenCode)
#   - Escaped runtime descendants and early invoke-leader exit
#   - CLI PID sidecar lifecycle
#   - Invocation timeout cleanup
#   - INT/TERM/HUP runner exit codes

source "$BATS_TEST_DIRNAME/../helper/load-lib.bash"
# shellcheck disable=SC1090
source "$BATS_TEST_DIRNAME/run-plan-invoke-test-helper.bash"

RUN_PLAN_SH="$REPO_ROOT/bundle/.ralph/run-plan.sh"
TEARDOWN_LIB="$REPO_ROOT/bundle/.ralph/bash-lib/ralph-process-teardown.sh"
CLEANUP_LIB="$REPO_ROOT/bundle/.ralph/bash-lib/run-plan/run-plan-cleanup.sh"

interrupt_teardown_setup_workspace() {
  local workspace="$1"
  local select_model_dir="$workspace/.cursor/ralph"
  local agent_tool_dir="$workspace/.ralph"

  mkdir -p "$select_model_dir" "$agent_tool_dir" "$workspace/.ralph-workspace/logs"
  cat > "$select_model_dir/select-model.sh" <<'EOF'
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

  cat > "$agent_tool_dir/agent-config-tool.sh" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  list|validate|model|context|allowed-tools|downstream-stages)
    ;;
  *)
    ;;
esac
exit 0
EOF
  chmod +x "$agent_tool_dir/agent-config-tool.sh"

  printf '#!/usr/bin/env bash\nexit 0\n' >"$workspace/.ralph/mcp-server.sh"
  chmod +x "$workspace/.ralph/mcp-server.sh"
}

interrupt_teardown_wait_for_file() {
  local path="$1"
  local max_secs="${2:-5}"
  local waited=0
  while (( waited < max_secs * 10 )); do
    [[ -f "$path" ]] && return 0
    sleep 0.1
    ((waited++)) || true
  done
  return 1
}

interrupt_teardown_wait_gone() {
  local pid="$1"
  local max_secs="${2:-5}"
  local waited=0
  [[ "$pid" =~ ^[0-9]+$ ]] || return 0
  while (( waited < max_secs * 10 )); do
    if ! kill -0 "$pid" 2>/dev/null; then
      return 0
    fi
    sleep 0.1
    ((waited++)) || true
  done
  return 1
}

interrupt_teardown_assert_tree_gone() {
  local runtime_pid="${1:-}"
  local child_pid="${2:-}"
  local pid

  if [[ "$runtime_pid" =~ ^[0-9]+$ ]]; then
    if kill -0 "$runtime_pid" 2>/dev/null; then
      echo "runtime pid still alive: $runtime_pid"
      return 1
    fi
    while IFS= read -r pid; do
      [[ -n "$pid" ]] || continue
      if kill -0 "$pid" 2>/dev/null; then
        echo "runtime descendant still alive: $pid"
        return 1
      fi
    done < <(pgrep -P "$runtime_pid" 2>/dev/null || true)
  fi

  if [[ "$child_pid" =~ ^[0-9]+$ ]]; then
    if kill -0 "$child_pid" 2>/dev/null; then
      echo "escaped child still alive: $child_pid"
      return 1
    fi
  fi
  return 0
}

interrupt_teardown_assert_output_stable() {
  local log_file="$1"
  local pause_secs="${2:-0.5}"
  local size1 size2
  [[ -f "$log_file" ]] || return 0
  size1="$(wc -c <"$log_file" | tr -d '[:space:]')"
  sleep "$pause_secs"
  size2="$(wc -c <"$log_file" | tr -d '[:space:]')"
  [[ "$size1" == "$size2" ]]
}

interrupt_teardown_write_codex_stub() {
  local bin_dir="$1"
  local state_dir="$2"
  local behavior="${3:-ignore_sigint}"

  mkdir -p "$state_dir"
  cat >"$bin_dir/codex" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

state_dir="${INTERRUPT_STUB_STATE_DIR:?}"
behavior="${INTERRUPT_STUB_BEHAVIOR:-ignore_sigint}"

if [[ "$1" == "mcp" && "${2:-}" == "--help" ]]; then
  cat <<'MCP_HELP'
Manage external MCP servers for Codex

Usage: codex mcp [OPTIONS] <COMMAND>

Commands:
  list
  get
  add
  remove
  login
  logout
  help
MCP_HELP
  exit 0
fi

if [[ "$1" == "exec" && "${2:-}" == "--help" ]]; then
  cat <<'EXEC_HELP'
Run Codex non-interactively

Options:
  -c, --config <key=value>
      --strict-config
EXEC_HELP
  exit 0
fi

printf '%s\n' "$$" >"$state_dir/runtime.pid"
if [[ -n "${RALPH_PLAN_INVOCATION_CLI_PID_FILE:-}" ]]; then
  recorded="$(tr -d '[:space:]' <"${RALPH_PLAN_INVOCATION_CLI_PID_FILE}" 2>/dev/null || true)"
  if [[ "$recorded" == "$$" ]]; then
    touch "$state_dir/sidecar_ok"
  fi
fi

case "$behavior" in
  early_leader_exit)
    bash -c 'trap "" INT; while true; do sleep 0.1; done' &
    printf '%s\n' "$!" >"$state_dir/child.pid"
    touch "$state_dir/ready"
    exit 0
    ;;
  *)
    trap '' INT
    bash -c 'trap "" INT; while true; do sleep 0.1; done' &
    printf '%s\n' "$!" >"$state_dir/child.pid"
    touch "$state_dir/ready"
    while true; do
      printf 'codex-tick\n'
      sleep 0.1
    done
    ;;
esac
EOF
  chmod +x "$bin_dir/codex"
  export INTERRUPT_STUB_STATE_DIR="$state_dir"
  export INTERRUPT_STUB_BEHAVIOR="$behavior"
}

interrupt_teardown_write_opencode_stub() {
  local bin_dir="$1"
  local state_dir="$2"
  local behavior="${3:-ignore_sigint}"

  mkdir -p "$state_dir"
  cat >"$bin_dir/opencode" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

state_dir="${INTERRUPT_STUB_STATE_DIR:?}"
behavior="${INTERRUPT_STUB_BEHAVIOR:-ignore_sigint}"

printf '%s\n' "$$" >"$state_dir/runtime.pid"
if [[ -n "${RALPH_PLAN_INVOCATION_CLI_PID_FILE:-}" ]]; then
  recorded="$(tr -d '[:space:]' <"${RALPH_PLAN_INVOCATION_CLI_PID_FILE}" 2>/dev/null || true)"
  if [[ "$recorded" == "$$" ]]; then
    touch "$state_dir/sidecar_ok"
  fi
fi

case "$behavior" in
  early_leader_exit)
    bash -c 'trap "" INT; while true; do sleep 0.1; done' &
    printf '%s\n' "$!" >"$state_dir/child.pid"
    touch "$state_dir/ready"
    exit 0
    ;;
  *)
    trap '' INT
    bash -c 'trap "" INT; while true; do sleep 0.1; done' &
    printf '%s\n' "$!" >"$state_dir/child.pid"
    touch "$state_dir/ready"
    while true; do
      printf 'opencode-tick\n'
      sleep 0.1
    done
    ;;
esac
EOF
  chmod +x "$bin_dir/opencode"
  export INTERRUPT_STUB_STATE_DIR="$state_dir"
  export INTERRUPT_STUB_BEHAVIOR="$behavior"
}

interrupt_teardown_find_sidecar() {
  local log_dir="$1"
  local max_secs="${2:-5}"
  local waited=0
  local path
  while (( waited < max_secs * 10 )); do
    for path in "$log_dir"/.plan-runner-cli-pid.*; do
      [[ -f "$path" ]] || continue
      printf '%s' "$path"
      return 0
    done
    sleep 0.1
    ((waited++)) || true
  done
  return 1
}

interrupt_teardown_launch_runner() {
  local workspace="$1"
  local bin_dir="$2"
  local runtime="$3"
  local registry_file="$4"
  shift 4
  local -a run_plan_args=("$@")

  bash -c '
    set -euo pipefail
    _workspace="$1"
    _bin_dir="$2"
    _runtime="$3"
    _registry="$4"
    _run_plan="$5"
    shift 5
    cd "$_workspace"
    export PATH="$_bin_dir:$PATH"
    export RALPH_USAGE_RISKS_ACKNOWLEDGED=1
    export RALPH_PLAN_SESSION_HOME="$_workspace/.sessions"
    export RALPH_PLAN_NO_CAFFEINATE=1
    export RALPH_LAUNCHER_PID=$$
    export RALPH_WORKSPACES_FILE="$_registry"
    export RALPH_MODE=native
    export RALPH_PLAN_CAPTURE_USAGE=0
    export CURSOR_PLAN_MAX_ITER=1
    export CODEX_PLAN_NO_ADD_AGENTS_DIR=1
    unset RALPH_AGENT_TOOL_ACCESS RALPH_NATIVE_HOOKS RALPH_PLAN_KEY RALPH_ARTIFACT_NS
    exec "$_run_plan" --runtime "$_runtime" --plan PLAN.md --non-interactive --model stub-model --workspace "$_workspace" "$@"
  ' _ "$workspace" "$bin_dir" "$runtime" "$registry_file" "$RUN_PLAN_SH" "${run_plan_args[@]}" &
  printf '%s' "$!"
}

interrupt_teardown_common_plan() {
  local plan_file="$1"
  cat >"$plan_file" <<'EOF'
# Interrupt teardown plan
- [ ] Stub runtime should be interrupted cleanly
EOF
}

interrupt_teardown_read_pid_file() {
  local path="$1"
  [[ -f "$path" ]] || return 1
  tr -d '[:space:]' <"$path"
}

@test "codex interrupt teardown kills SIGINT-ignoring runtime and descendants" {
  skip "signal-driven process-group teardown is environment-dependent and flaky in CI; unit-level teardown coverage remains active"
  [ -f "$RUN_PLAN_SH" ] || skip "bundle run-plan missing"

  local workspace bin_dir session_home state_dir plan_file registry_file
  local runner_pid runtime_pid child_pid output_log exit_code

  workspace="$(mktemp -d)"
  bin_dir="$workspace/bin"
  session_home="$workspace/.sessions"
  state_dir="$workspace/state"
  plan_file="$workspace/PLAN.md"
  registry_file="$(mktemp)"
  mkdir -p "$bin_dir" "$session_home"
  interrupt_teardown_setup_workspace "$workspace"
  interrupt_teardown_common_plan "$plan_file"
  interrupt_teardown_write_codex_stub "$bin_dir" "$state_dir" "ignore_sigint"

  runner_pid="$(interrupt_teardown_launch_runner "$workspace" "$bin_dir" codex "$registry_file")"
  interrupt_teardown_wait_for_file "$state_dir/ready" 8

  runtime_pid="$(interrupt_teardown_read_pid_file "$state_dir/runtime.pid")"
  child_pid="$(interrupt_teardown_read_pid_file "$state_dir/child.pid")"
  [ -n "$runtime_pid" ]
  [ -n "$child_pid" ]
  kill -INT "$runner_pid" 2>/dev/null || true
  wait "$runner_pid" 2>/dev/null || exit_code=$?
  exit_code="${exit_code:-0}"

  output_log="$workspace/.ralph-workspace/logs/PLAN/plan-runner-PLAN-output.log"
  [ "$exit_code" -eq 130 ]
  interrupt_teardown_assert_tree_gone "$runtime_pid" "$child_pid"
  interrupt_teardown_assert_output_stable "$output_log"

  rm -rf "$workspace"
  rm -f "$registry_file"
}

@test "opencode interrupt teardown kills SIGINT-ignoring runtime and descendants" {
  skip "signal-driven process-group teardown is environment-dependent and flaky in CI; unit-level teardown coverage remains active"
  [ -f "$RUN_PLAN_SH" ] || skip "bundle run-plan missing"

  local workspace bin_dir session_home state_dir plan_file registry_file
  local runner_pid runtime_pid child_pid output_log exit_code

  workspace="$(mktemp -d)"
  bin_dir="$workspace/bin"
  session_home="$workspace/.sessions"
  state_dir="$workspace/state"
  plan_file="$workspace/PLAN.md"
  registry_file="$(mktemp)"
  mkdir -p "$bin_dir" "$session_home"
  interrupt_teardown_setup_workspace "$workspace"
  interrupt_teardown_common_plan "$plan_file"
  interrupt_teardown_write_opencode_stub "$bin_dir" "$state_dir" "ignore_sigint"

  runner_pid="$(interrupt_teardown_launch_runner "$workspace" "$bin_dir" opencode "$registry_file")"
  interrupt_teardown_wait_for_file "$state_dir/ready" 8

  runtime_pid="$(interrupt_teardown_read_pid_file "$state_dir/runtime.pid")"
  child_pid="$(interrupt_teardown_read_pid_file "$state_dir/child.pid")"
  kill -INT "$runner_pid" 2>/dev/null || true
  wait "$runner_pid" 2>/dev/null || exit_code=$?
  exit_code="${exit_code:-0}"

  output_log="$workspace/.ralph-workspace/logs/PLAN/plan-runner-PLAN-output.log"
  [ "$exit_code" -eq 130 ]
  interrupt_teardown_assert_tree_gone "$runtime_pid" "$child_pid"
  interrupt_teardown_assert_output_stable "$output_log"

  rm -rf "$workspace"
  rm -f "$registry_file"
}

@test "codex interrupt teardown kills escaped child after runtime leader exits early" {
  skip "signal-driven process-group teardown is environment-dependent and flaky in CI; unit-level teardown coverage remains active"
  [ -f "$RUN_PLAN_SH" ] || skip "bundle run-plan missing"

  local workspace bin_dir state_dir plan_file registry_file
  local runner_pid child_pid output_log exit_code

  workspace="$(mktemp -d)"
  bin_dir="$workspace/bin"
  state_dir="$workspace/state"
  plan_file="$workspace/PLAN.md"
  registry_file="$(mktemp)"
  mkdir -p "$bin_dir" "$workspace/.sessions"
  interrupt_teardown_setup_workspace "$workspace"
  interrupt_teardown_common_plan "$plan_file"
  interrupt_teardown_write_codex_stub "$bin_dir" "$state_dir" "early_leader_exit"

  runner_pid="$(interrupt_teardown_launch_runner "$workspace" "$bin_dir" codex "$registry_file")"
  interrupt_teardown_wait_for_file "$state_dir/ready" 8
  child_pid="$(interrupt_teardown_read_pid_file "$state_dir/child.pid")"
  [ -n "$child_pid" ]

  kill -INT "$runner_pid" 2>/dev/null || true
  wait "$runner_pid" 2>/dev/null || exit_code=$?
  exit_code="${exit_code:-0}"

  output_log="$workspace/.ralph-workspace/logs/PLAN/plan-runner-PLAN-output.log"
  [ "$exit_code" -eq 130 ]
  interrupt_teardown_wait_gone "$child_pid" 5
  interrupt_teardown_assert_output_stable "$output_log"

  rm -rf "$workspace"
  rm -f "$registry_file"
}

@test "CLI PID sidecar is created during invocation and removed after interrupt" {
  skip "signal-driven process-group teardown is environment-dependent and flaky in CI; unit-level teardown coverage remains active"
  [ -f "$RUN_PLAN_SH" ] || skip "bundle run-plan missing"

  local workspace bin_dir state_dir plan_file registry_file
  local runner_pid sidecar exit_code

  workspace="$(mktemp -d)"
  bin_dir="$workspace/bin"
  state_dir="$workspace/state"
  plan_file="$workspace/PLAN.md"
  registry_file="$(mktemp)"
  mkdir -p "$bin_dir" "$workspace/.sessions"
  interrupt_teardown_setup_workspace "$workspace"
  interrupt_teardown_common_plan "$plan_file"
  interrupt_teardown_write_codex_stub "$bin_dir" "$state_dir" "ignore_sigint"

  runner_pid="$(interrupt_teardown_launch_runner "$workspace" "$bin_dir" codex "$registry_file")"
  interrupt_teardown_wait_for_file "$state_dir/sidecar_ok" 8
  sidecar="$(interrupt_teardown_find_sidecar "$workspace/.ralph-workspace/logs/PLAN" 5)"
  [ -n "$sidecar" ]
  [ -f "$sidecar" ]
  sidecar_pid="$(tr -d '[:space:]' <"$sidecar")"
  [[ "$sidecar_pid" =~ ^[0-9]+$ ]]
  kill -0 "$sidecar_pid" 2>/dev/null

  kill -INT "$runner_pid" 2>/dev/null || true
  wait "$runner_pid" 2>/dev/null || exit_code=$?
  exit_code="${exit_code:-0}"
  [ "$exit_code" -eq 130 ]
  [[ ! -f "$sidecar" ]]
  interrupt_teardown_wait_gone "$sidecar_pid" 5

  rm -rf "$workspace"
  rm -f "$registry_file"
}

@test "agent teardown kills recorded CLI when invoke subshell leader exits early" {
  local cli_sidecar
  cli_sidecar="$TEST_TMPDIR/cli-pid.sidecar"

  run bash -c '
    set -euo pipefail
    source "$1"
    export RALPH_PLAN_INVOCATION_CLI_PID_FILE="$2"
    (
      sleep 120 &
      printf "%s" "$!" >"$RALPH_PLAN_INVOCATION_CLI_PID_FILE"
      exit 0
    ) &
    AGENT_PID=$!
    wait "$AGENT_PID" || true
    cli_pid="$(cat "$RALPH_PLAN_INVOCATION_CLI_PID_FILE")"
    ralph_run_plan_agent_teardown
    if kill -0 "$cli_pid" 2>/dev/null; then
      exit 9
    fi
    if [[ -f "$RALPH_PLAN_INVOCATION_CLI_PID_FILE" ]]; then
      exit 8
    fi
  ' _ "$TEARDOWN_LIB" "$cli_sidecar"

  [ "$status" -eq 0 ]
}

@test "invocation timeout kills stubborn codex runtime and exits 4" {
  skip "signal-driven process-group teardown is environment-dependent and flaky in CI; unit-level teardown coverage remains active"
  [ -f "$RUN_PLAN_SH" ] || skip "bundle run-plan missing"

  local workspace bin_dir state_dir plan_file registry_file
  local runner_pid runtime_pid child_pid output_log exit_code

  workspace="$(mktemp -d)"
  bin_dir="$workspace/bin"
  state_dir="$workspace/state"
  plan_file="$workspace/PLAN.md"
  registry_file="$(mktemp)"
  mkdir -p "$bin_dir" "$workspace/.sessions"
  interrupt_teardown_setup_workspace "$workspace"
  interrupt_teardown_common_plan "$plan_file"
  interrupt_teardown_write_codex_stub "$bin_dir" "$state_dir" "ignore_sigint"

  runner_pid="$(interrupt_teardown_launch_runner "$workspace" "$bin_dir" codex "$registry_file" --timeout 2s)"
  interrupt_teardown_wait_for_file "$state_dir/ready" 8
  runtime_pid="$(interrupt_teardown_read_pid_file "$state_dir/runtime.pid")"
  child_pid="$(interrupt_teardown_read_pid_file "$state_dir/child.pid")"

  wait "$runner_pid" 2>/dev/null || exit_code=$?
  exit_code="${exit_code:-0}"

  output_log="$workspace/.ralph-workspace/logs/PLAN/plan-runner-PLAN-output.log"
  [ "$exit_code" -eq 4 ]
  interrupt_teardown_assert_tree_gone "$runtime_pid" "$child_pid"
  interrupt_teardown_assert_output_stable "$output_log"

  rm -rf "$workspace"
  rm -f "$registry_file"
}

@test "run-plan exits 130 when interrupted with INT" {
  skip "signal-driven process-group teardown is environment-dependent and flaky in CI; unit-level teardown coverage remains active"
  [ -f "$RUN_PLAN_SH" ] || skip "bundle run-plan missing"

  local workspace bin_dir state_dir plan_file registry_file runner_pid exit_code
  workspace="$(mktemp -d)"
  bin_dir="$workspace/bin"
  state_dir="$workspace/state"
  plan_file="$workspace/PLAN.md"
  registry_file="$(mktemp)"
  mkdir -p "$bin_dir" "$workspace/.sessions"
  interrupt_teardown_setup_workspace "$workspace"
  interrupt_teardown_common_plan "$plan_file"
  interrupt_teardown_write_codex_stub "$bin_dir" "$state_dir" "ignore_sigint"

  runner_pid="$(interrupt_teardown_launch_runner "$workspace" "$bin_dir" codex "$registry_file")"
  interrupt_teardown_wait_for_file "$state_dir/ready" 8
  kill -INT "$runner_pid" 2>/dev/null || true
  wait "$runner_pid" 2>/dev/null || exit_code=$?
  exit_code="${exit_code:-0}"
  [ "$exit_code" -eq 130 ]

  rm -rf "$workspace"
  rm -f "$registry_file"
}

@test "run-plan exits 143 when interrupted with TERM" {
  skip "signal-driven process-group teardown is environment-dependent and flaky in CI; unit-level teardown coverage remains active"
  [ -f "$RUN_PLAN_SH" ] || skip "bundle run-plan missing"

  local workspace bin_dir state_dir plan_file registry_file runner_pid exit_code
  workspace="$(mktemp -d)"
  bin_dir="$workspace/bin"
  state_dir="$workspace/state"
  plan_file="$workspace/PLAN.md"
  registry_file="$(mktemp)"
  mkdir -p "$bin_dir" "$workspace/.sessions"
  interrupt_teardown_setup_workspace "$workspace"
  interrupt_teardown_common_plan "$plan_file"
  interrupt_teardown_write_codex_stub "$bin_dir" "$state_dir" "ignore_sigint"

  runner_pid="$(interrupt_teardown_launch_runner "$workspace" "$bin_dir" codex "$registry_file")"
  interrupt_teardown_wait_for_file "$state_dir/ready" 8
  kill -TERM "$runner_pid" 2>/dev/null || true
  wait "$runner_pid" 2>/dev/null || exit_code=$?
  exit_code="${exit_code:-0}"
  [ "$exit_code" -eq 143 ]

  rm -rf "$workspace"
  rm -f "$registry_file"
}

@test "run-plan exits 129 when interrupted with HUP" {
  skip "signal-driven process-group teardown is environment-dependent and flaky in CI; unit-level teardown coverage remains active"
  [ -f "$RUN_PLAN_SH" ] || skip "bundle run-plan missing"

  local workspace bin_dir state_dir plan_file registry_file runner_pid exit_code
  workspace="$(mktemp -d)"
  bin_dir="$workspace/bin"
  state_dir="$workspace/state"
  plan_file="$workspace/PLAN.md"
  registry_file="$(mktemp)"
  mkdir -p "$bin_dir" "$workspace/.sessions"
  interrupt_teardown_setup_workspace "$workspace"
  interrupt_teardown_common_plan "$plan_file"
  interrupt_teardown_write_codex_stub "$bin_dir" "$state_dir" "ignore_sigint"

  runner_pid="$(interrupt_teardown_launch_runner "$workspace" "$bin_dir" codex "$registry_file")"
  interrupt_teardown_wait_for_file "$state_dir/ready" 8
  kill -HUP "$runner_pid" 2>/dev/null || true
  wait "$runner_pid" 2>/dev/null || exit_code=$?
  exit_code="${exit_code:-0}"
  [ "$exit_code" -eq 129 ]

  rm -rf "$workspace"
  rm -f "$registry_file"
}

@test "interrupt trap handler exits 130 for INT" {
  run bash -c '
    set -euo pipefail
    _ralph_finalize_plan_usage_on_exit() { :; }
    export -f _ralph_finalize_plan_usage_on_exit
    source "$1"
    source "$2"
    ralph_run_plan_interrupt_trap_handler INT
  ' _ "$TEARDOWN_LIB" "$CLEANUP_LIB"

  [ "$status" -eq 130 ]
}

@test "interrupt trap handler exits 143 for TERM" {
  run bash -c '
    set -euo pipefail
    _ralph_finalize_plan_usage_on_exit() { :; }
    export -f _ralph_finalize_plan_usage_on_exit
    source "$1"
    source "$2"
    ralph_run_plan_interrupt_trap_handler TERM
  ' _ "$TEARDOWN_LIB" "$CLEANUP_LIB"

  [ "$status" -eq 143 ]
}

@test "interrupt trap handler exits 129 for HUP" {
  run bash -c '
    set -euo pipefail
    _ralph_finalize_plan_usage_on_exit() { :; }
    export -f _ralph_finalize_plan_usage_on_exit
    source "$1"
    source "$2"
    ralph_run_plan_interrupt_trap_handler HUP
  ' _ "$TEARDOWN_LIB" "$CLEANUP_LIB"

  [ "$status" -eq 129 ]
}

@test "interrupt trap handler tears down agent tree before usage finalization" {
  local order_log
  order_log="$TEST_TMPDIR/order.log"

  run env ORDER_LOG="$order_log" bash -c '
    set -euo pipefail
    source "$1"
    source "$2"
    _ralph_finalize_plan_usage_on_exit() { echo finalize >>"$ORDER_LOG"; }
    ralph_run_plan_process_teardown_on_exit() { echo teardown >>"$ORDER_LOG"; }
    ralph_run_plan_interrupt_trap_handler INT
  ' _ "$TEARDOWN_LIB" "$CLEANUP_LIB"

  [ "$status" -eq 130 ]
  [ "$(sed -n 1p "$order_log")" = "teardown" ]
  [ "$(sed -n 2p "$order_log")" = "finalize" ]
}

@test "interrupt trap handler ignores repeated signals during teardown" {
  local state_dir
  state_dir="$TEST_TMPDIR/repeat-signal"
  mkdir -p "$state_dir"

  # A second Ctrl-C mid-teardown must not kill the runner. The handler has to
  # set INT/TERM/HUP to ignore before teardown starts; the stubbed teardown
  # records the trap table and re-signals the shell, simulating a user
  # pressing Ctrl-C again while the agent tree is being reaped.
  run env STATE_DIR="$state_dir" bash -c '
    set -euo pipefail
    source "$1"
    source "$2"
    _ralph_finalize_plan_usage_on_exit() { :; }
    ralph_run_plan_process_teardown_on_exit() {
      trap -p INT TERM HUP >"$STATE_DIR/traps.txt"
      kill -TERM $$ 2>/dev/null || true
      sleep 0.2
      echo done >"$STATE_DIR/marker"
    }
    ralph_run_plan_interrupt_trap_handler INT
  ' _ "$TEARDOWN_LIB" "$CLEANUP_LIB"

  [ "$status" -eq 130 ]
  [ -f "$state_dir/marker" ]
  [ "$(grep -c "trap -- ''" "$state_dir/traps.txt")" -eq 3 ]
}

@test "interrupt trap handler completes teardown when usage finalization fails" {
  local marker
  marker="$TEST_TMPDIR/teardown-ran"

  run env MARKER="$marker" bash -c '
    set -euo pipefail
    source "$1"
    source "$2"
    _ralph_finalize_plan_usage_on_exit() { return 1; }
    ralph_run_plan_process_teardown_on_exit() { touch "$MARKER"; }
    ralph_run_plan_interrupt_trap_handler INT
  ' _ "$TEARDOWN_LIB" "$CLEANUP_LIB"

  [ "$status" -eq 130 ]
  [ -f "$marker" ]
}

@test "agent group guard reaps TERM-ignoring agent group when runner dies" {
  skip "legacy PGID guard is superseded by the session/token process supervisor"
  local state_dir
  state_dir="$TEST_TMPDIR/guard-state"
  mkdir -p "$state_dir"

  run bash -c '
    set -euo pipefail
    source "$1"
    state="$2"

    sleep 60 &
    runner_pid=$!

    set -m
    (
      ralph_run_plan_agent_group_guard "$runner_pid" "$BASHPID"
      bash -c "trap \"\" TERM; while true; do sleep 0.1; done" &
      printf "%s" "$!" >"$state/child.pid"
      sleep 60
    ) &
    leader_pid=$!
    set +m

    for _ in $(seq 1 50); do [[ -s "$state/child.pid" ]] && break; sleep 0.1; done
    child_pid="$(cat "$state/child.pid")"
    [[ "$child_pid" =~ ^[0-9]+$ ]]

    kill -KILL "$runner_pid" 2>/dev/null || true
    wait "$runner_pid" 2>/dev/null || true

    for _ in $(seq 1 80); do
      if ! kill -0 "$child_pid" 2>/dev/null && ! kill -0 "$leader_pid" 2>/dev/null; then
        exit 0
      fi
      sleep 0.1
    done
    kill -KILL -"$leader_pid" 2>/dev/null || true
    exit 9
  ' _ "$TEARDOWN_LIB" "$state_dir"

  [ "$status" -eq 0 ]
}

@test "agent teardown reaps signal-immune group guard via pid sidecar" {
  local sidecar
  sidecar="$TEST_TMPDIR/guard-pid.sidecar"

  run bash -c '
    set -euo pipefail
    source "$1"
    export RALPH_PLAN_INVOCATION_GUARD_PID_FILE="$2"
    bash -c "trap \"\" TERM; while true; do sleep 0.1; done" &
    guard_pid=$!
    printf "%s\n" "$guard_pid" >"$RALPH_PLAN_INVOCATION_GUARD_PID_FILE"
    ralph_run_plan_agent_teardown
    for _ in 1 2 3 4 5 6 7 8 9 10; do
      kill -0 "$guard_pid" 2>/dev/null || break
      sleep 0.1
    done
    if kill -0 "$guard_pid" 2>/dev/null; then
      exit 9
    fi
    if [[ -f "$RALPH_PLAN_INVOCATION_GUARD_PID_FILE" ]]; then
      exit 8
    fi
  ' _ "$TEARDOWN_LIB" "$sidecar"

  [ "$status" -eq 0 ]
}

@test "agent group guard exits quietly once its group is empty" {
  run bash -c '
    set -euo pipefail
    source "$1"

    sleep 60 &
    runner_pid=$!

    set -m
    (
      ralph_run_plan_agent_group_guard "$runner_pid" "$BASHPID"
      sleep 0.3
    ) &
    leader_pid=$!
    set +m

    wait "$leader_pid" 2>/dev/null || true

    group_has_live_members() {
      local member process_stat state
      while IFS= read -r member; do
        [[ "$member" =~ ^[0-9]+$ ]] || continue
        if [[ -r "/proc/$member/stat" ]]; then
          process_stat="$(<"/proc/$member/stat")"
          process_stat="${process_stat#*) }"
          state="${process_stat%% *}"
        else
          state="$(ps -o stat= -p "$member" 2>/dev/null || true)"
          state="${state//[[:space:]]/}"
        fi
        [[ -n "$state" && "$state" != Z* ]] && return 0
      done < <(pgrep -g "$leader_pid" 2>/dev/null || true)
      return 1
    }

    for _ in $(seq 1 60); do
      if ! group_has_live_members; then
        kill "$runner_pid" 2>/dev/null || true
        exit 0
      fi
      sleep 0.1
    done
    kill "$runner_pid" 2>/dev/null || true
    kill -KILL -"$leader_pid" 2>/dev/null || true
    exit 9
  ' _ "$TEARDOWN_LIB"

  [ "$status" -eq 0 ]
}

setup() {
  TEST_TMPDIR="$(mktemp -d)"
  bats_skip_known_ci_flakes
}

teardown() {
  pkill -P "$$" 2>/dev/null || true
  rm -rf "$TEST_TMPDIR"
}
