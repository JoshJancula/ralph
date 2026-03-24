#!/usr/bin/env bats

source "$BATS_TEST_DIRNAME/helper/load-lib.bash"

RUN_PLAN_SH="$REPO_ROOT/bundle/.ralph/run-plan.sh"
RUN_PLAN_CORE_FILE="$REPO_ROOT/.ralph/bash-lib/run-plan-core.sh"

@test "run-plan reexecs under caffeinate when running on macOS" {
  [ -f "$RUN_PLAN_SH" ] || skip "bundle run-plan missing"
  [[ "$(uname -s)" == "Darwin" ]] || skip "caffeinate guard only relevant on macOS"

  local stub_dir capture_file plan_file
  stub_dir="$(mktemp -d)"
  capture_file="$(mktemp)"
  plan_file="$(mktemp)"
  printf '%s\n' "- [ ] pending task" >"$plan_file"

  cat <<'CAFFEINATE' > "$stub_dir/caffeinate"
#!/usr/bin/env bash
set -euo pipefail
env > "$CAFFEINATE_CAPTURE"
printf '%s\n' "$@" >> "$CAFFEINATE_CAPTURE"
CAFFEINATE
  chmod +x "$stub_dir/caffeinate"

  run bash -c '
    set -euo pipefail
    PATH="$1"
    export PATH
    export CAFFEINATE_CAPTURE="$2"
    export RALPH_PLAN_NO_CAFFEINATE=0
    export RALPH_PLAN_CAFFEINATED=0
    export CURSOR_PLAN_CAFFEINATED=0
    export CLAUDE_PLAN_CAFFEINATED=0
    export CODEX_PLAN_CAFFEINATED=0
    CURSOR_PLAN_NO_COLOR=1
    CLAUDE_PLAN_NO_COLOR=1
    CODEX_PLAN_NO_COLOR=1
    export CURSOR_PLAN_NO_COLOR CLAUDE_PLAN_NO_COLOR CODEX_PLAN_NO_COLOR
    "$3" --runtime cursor --plan "$4"
  ' _ "$stub_dir:$PATH" "$capture_file" "$RUN_PLAN_SH" "$plan_file"

  [ "$status" -eq 0 ]
  env_output="$(<"$capture_file")"
  [[ "$env_output" == *"RALPH_PLAN_CAFFEINATED=1"* ]]
  [[ "$env_output" == *"CURSOR_PLAN_CAFFEINATED=1"* ]]
  [[ "$env_output" == *"CLAUDE_PLAN_CAFFEINATED=1"* ]]
  [[ "$env_output" == *"CODEX_PLAN_CAFFEINATED=1"* ]]
  [[ "$env_output" == *"/usr/bin/env"* ]]

  rm -rf "$stub_dir"
  rm -f "$capture_file"
  rm -f "$plan_file"
}

@test "ralph restart command hint exposes restart instructions" {
  [ -f "$RUN_PLAN_SH" ] || skip "bundle run-plan missing"

  local helper
  helper="$(mktemp)"
  sed -n '/^ralph_restart_command_hint()/,/^}/p' "$RUN_PLAN_CORE_FILE" > "$helper"

  run bash -c '
    set -euo pipefail
    unset RALPH_ORCH_FILE
    RALPH_RUN_PLAN_RELATIVE=".ralph/run-plan.sh --runtime cursor"
    PLAN_PATH="plan path.md"
    WORKSPACE="/tmp/workspace dir"
    PREBUILT_AGENT=""
    source "$1"
    printf "%s" "$(ralph_restart_command_hint)"
  ' _ "$helper"

  [ "$status" -eq 0 ]
  [ "$output" = ".ralph/run-plan.sh --runtime cursor --non-interactive --plan plan\\ path.md --agent agent --workspace /tmp/workspace\\ dir" ]

  run bash -c '
    set -euo pipefail
    RALPH_ORCH_FILE="/tmp/restart plan/orch.json"
    source "$1"
    printf "%s" "$(ralph_restart_command_hint)"
  ' _ "$helper"

  [ "$status" -eq 0 ]
  [ "$output" = ".ralph/orchestrator.sh --orchestration /tmp/restart\\ plan/orch.json" ]

  rm -f "$helper"
}
