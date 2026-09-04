#!/usr/bin/env bats

# Interactive runtime/model resolution for `ralph workflow start`.
#
# A routing-neutral workflow source (no defaults: block, no stage runtime:)
# used to materialize a plan whose agent stages carried no runtime. That only
# failed at engine dispatch, after the run registry entry existed, as
# "engine-dispatch-failed". These cover the pre-registry resolution instead:
# fail-fast when non-interactive, prompt when attended, per-stage selection,
# and the optional write-back into the workflow source.

source "$BATS_TEST_DIRNAME/../helper/load-lib.bash"

setup() {
  unset RALPH_PROJECT_ROOT RALPH_PLAN_WORKSPACE_ROOT RALPH_AGENT_WORKSPACE
  WSR_TMP="$(mktemp -d)"
  WSR_TMP="$(cd "$WSR_TMP" && pwd -P)"
  WSR_HOME="$WSR_TMP/home"
  WSR_WORKSPACE="$WSR_TMP/workspace"
  WSR_SHIM="$WSR_TMP/ralph"
  mkdir -p "$WSR_HOME/bundle/.ralph" "$WSR_WORKSPACE/.ralph-workspace/workflows"
  cp -R "$REPO_ROOT/bundle/.ralph/." "$WSR_HOME/bundle/.ralph/"
  awk '/^  cat > "\$tmp" <<.SHIM.$/ { flag = 1; next } /^SHIM$/ { flag = 0 } flag { print }' \
    "$REPO_ROOT/install.sh" >"$WSR_SHIM"
  chmod +x "$WSR_SHIM"
  WSR_WF="$WSR_WORKSPACE/.ralph-workspace/workflows/neutral.workflow.md"
  write_neutral_wf "$WSR_WF"
}

teardown() { rm -rf "$WSR_TMP"; }

# A two-stage dependency workflow that pins no routing at all: the exact shape
# every bundled workflow ships with.
write_neutral_wf() {
  local path="$1"
  mkdir -p "$(dirname "$path")"
  printf '%s\n' \
    '---' \
    'name: neutral' \
    'overview: routing neutral workflow' \
    'kind: workflow' \
    'mode: dependency' \
    'pipeline:' \
    '  maxParallel: 1' \
    '  stages:' \
    '    - id: investigate' \
    '      instructions: |' \
    '        Investigate {{TASK}}.' \
    '    - id: implement' \
    '      dependsOn:' \
    '        - investigate' \
    '      instructions: |' \
    '        Implement {{TASK}}.' \
    'todos:' \
    '  - id: investigate-todo' \
    '    stage: investigate' \
    '    content: Investigate {{TASK}}.' \
    '    verification: Confirm the investigation notes exist.' \
    '    status: pending' \
    '  - id: implement-todo' \
    '    stage: implement' \
    '    content: Implement {{TASK}}.' \
    '    verification: Confirm the change is in place.' \
    '    status: pending' \
    '---' \
    '# neutral' >"$path"
}

# Replace the menu picker inside the sandboxed bundle so the CLI subprocess
# answers its own prompts. Choices are consumed one per menu call, read from
# the file named by RALPH_TEST_MENU_ANSWERS.
stub_menu_answers() {
  printf '%s\n' "$@" >"$WSR_TMP/menu-answers.txt"
  cat >>"$WSR_HOME/bundle/.ralph/bash-lib/interactive-select.sh" <<'STUB'

# Test stub appended by workflow-start-routing.bats.
ralph_menu_select() {
  local answers="${RALPH_TEST_MENU_ANSWERS:-}"
  [[ -z "$answers" ]] && return 1
  local cursor="$answers.cursor"
  local idx=0
  [[ -f "$cursor" ]] && idx="$(cat "$cursor")"
  idx=$((idx + 1))
  printf '%s' "$idx" >"$cursor"
  sed -n "${idx}p" "$answers"
}
STUB
}

# Same as ralph_wf_start, with leading args fed to stdin (save prompt, then the
# start confirmation) up to the "--" separator.
ralph_wf_start_tty() {
  local -a stdin_lines=()
  while [[ $# -gt 0 && "$1" != "--" ]]; do
    stdin_lines+=("$1")
    shift
  done
  shift || true
  printf '%s\n' "${stdin_lines[@]}" \
    | RALPH_WORKFLOW_START_ASSUME_TTY=1 ralph_wf_start "$@"
}

ralph_wf_start() {
  (cd "$WSR_WORKSPACE" && env -u RALPH_PROJECT_ROOT -u RALPH_PLAN_WORKSPACE_ROOT \
    RALPH_HOME="$WSR_HOME" \
    RALPH_WORKFLOW_START_ASSUME_TTY="${RALPH_WORKFLOW_START_ASSUME_TTY:-0}" \
    RALPH_WORKFLOW_START_ENGINE_STUB="$WSR_TMP/engine-stub.log" \
    WORKFLOW_ROUTING_AVAILABLE_RUNTIMES="claude codex" \
    WORKFLOW_ROUTING_DISCOVERED_MODELS=$'haiku\nsonnet\nopus\nfable' \
    RALPH_SKIP_FZF_HINT=1 \
    RALPH_TEST_MENU_ANSWERS="$WSR_TMP/menu-answers.txt" \
    bash "$WSR_SHIM" workflow start "$@")
}

# --- non-interactive fail-fast ---------------------------------------------

@test "start refuses a routing-neutral workflow with --yes and names the stages" {
  run ralph_wf_start neutral --task "do the thing" --yes
  [ "$status" -eq 2 ]
  [[ "$output" == *"pins no runtime"* ]]
  [[ "$output" == *"investigate"* && "$output" == *"implement"* ]]
  [[ "$output" == *"--runtime"* ]]
  [[ "$output" != *"engine-dispatch-failed"* ]]
}

@test "start creates no run when routing cannot be resolved" {
  run ralph_wf_start neutral --task "do the thing" --yes
  [ "$status" -eq 2 ]
  # The failure must land before workflow_state_create, so no registry entry
  # is left behind for the operator to clean up.
  run bash -c "ls -1 '$WSR_WORKSPACE/.ralph-workspace/workflow-runs' 2>/dev/null | wc -l"
  [ "${output// /}" = "0" ]
}

@test "an explicit --runtime keeps the non-interactive start working" {
  run ralph_wf_start neutral --task "do the thing" --runtime claude --model haiku --yes
  [ "$status" -eq 0 ]
  [[ "$output" != *"pins no runtime"* ]]
  [[ "$output" != *"engine-dispatch-failed"* ]]
}

# --- interactive resolution -------------------------------------------------

@test "start prompts and applies one runtime and model to every stage" {
  # Menus, in call order: runtime, model, apply-scope.
  stub_menu_answers "claude" "sonnet" "Use claude/sonnet for all 2 stage(s)"
  # stdin answers the save prompt (n) then the start confirmation (y).
  run ralph_wf_start_tty "n" "y" -- neutral --task "do the thing"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Resolved routing"* ]]
  [[ "$output" == *"all unresolved stages: runtime=claude model=sonnet"* ]]
  # One dispatch, and the materialized plan carries the routing on both stages.
  [ "$(wc -l <"$WSR_TMP/engine-stub.log")" -eq 1 ]
  local plan
  plan="$(cut -f3 <"$WSR_TMP/engine-stub.log")"
  [ "$(grep -c '^      runtime: claude$' "$plan")" -eq 2 ]
  [ "$(grep -c '^      model: sonnet$' "$plan")" -eq 2 ]
}

@test "start can route each stage separately" {
  # runtime, model, apply-scope, then runtime+model for the second stage.
  stub_menu_answers "claude" "haiku" "Choose a runtime and model per stage" \
    "claude" "opus"
  run ralph_wf_start_tty "n" "y" -- neutral --task "do the thing"
  [ "$status" -eq 0 ]
  [[ "$output" == *"investigate: runtime=claude model=haiku"* ]]
  [[ "$output" == *"implement: runtime=claude model=opus"* ]]
  local plan
  plan="$(cut -f3 <"$WSR_TMP/engine-stub.log")"
  grep -q '^      model: haiku$' "$plan"
  grep -q '^      model: opus$' "$plan"
}

@test "using the runtime default model routes the stages with a runtime only" {
  # "Use <runtime> default" is a legitimate answer: `agent:` is a removed field
  # on graph agent stages, so no stage ever requires a model, and the runtime
  # resolves its own at invoke time.
  stub_menu_answers "claude" "Use claude default" \
    "Use claude/default for all 2 stage(s)"
  run ralph_wf_start_tty "n" "y" -- neutral --task "do the thing"
  [ "$status" -eq 0 ]
  [[ "$output" == *"runtime=claude model=-"* ]]
  local plan
  plan="$(cut -f3 <"$WSR_TMP/engine-stub.log")"
  [ "$(grep -c '^      runtime: claude$' "$plan")" -eq 2 ]
  # No model key is invented for stages that took the runtime default.
  run grep -c '^      model: ' "$plan"
  [ "$status" -ne 0 ]
}

@test "the runtime default never re-asks for the runtime" {
  # Regression: an earlier build treated a skipped model as unacceptable and
  # restarted from the runtime menu, discarding the operator's runtime choice.
  stub_menu_answers "claude" "Use claude default" \
    "Use claude/default for all 2 stage(s)"
  run ralph_wf_start_tty "n" "y" -- neutral --task "do the thing"
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | grep -c 'routing for stage')" -eq 1 ]
}

@test "declining the save leaves the workflow source untouched" {
  local before
  before="$(cat "$WSR_WF")"
  stub_menu_answers "claude" "sonnet" "Use claude/sonnet for all 2 stage(s)"
  run ralph_wf_start_tty "n" "y" -- neutral --task "do the thing"
  [ "$status" -eq 0 ]
  [ "$(cat "$WSR_WF")" = "$before" ]
}

@test "accepting the save writes a defaults block back into the workflow" {
  stub_menu_answers "claude" "sonnet" "Use claude/sonnet for all 2 stage(s)"
  run ralph_wf_start_tty "y" "y" -- neutral --task "do the thing"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Saved routing into"* ]]
  grep -q '^defaults:$' "$WSR_WF"
  grep -q '^  runtime: claude$' "$WSR_WF"
  grep -q '^  model: sonnet$' "$WSR_WF"
  # The saved routing makes the workflow non-neutral, so a later --yes start
  # no longer needs a prompt at all.
  run ralph_wf_start neutral --task "again" --yes
  [ "$status" -eq 0 ]
  [[ "$output" != *"pins no runtime"* ]]
}

@test "accepting the save writes per-stage routing when chosen per stage" {
  stub_menu_answers "claude" "haiku" "Choose a runtime and model per stage" \
    "claude" "opus"
  run ralph_wf_start_tty "y" "y" -- neutral --task "do the thing"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Saved routing into"* ]]
  grep -q '^      model: haiku$' "$WSR_WF"
  grep -q '^      model: opus$' "$WSR_WF"
  # The written source must still validate as a workflow.
  run bash -c "source '$WSR_HOME/bundle/.ralph/bash-lib/plan-todo.sh' >/dev/null 2>&1; \
    plan_workflow_validate '$WSR_WF'"
  [ "$status" -eq 0 ]
}

@test "cancelling the runtime menu creates no run" {
  stub_menu_answers ""
  run ralph_wf_start_tty "n" "y" -- neutral --task "do the thing"
  [ "$status" -ne 0 ]
  [[ "$output" == *"cancelled"* ]]
  run bash -c "ls -1 '$WSR_WORKSPACE/.ralph-workspace/workflow-runs' 2>/dev/null | wc -l"
  [ "${output// /}" = "0" ]
}




