#!/usr/bin/env bats
# Standard-plan model precedence:
#   attended: CLI --model > TODO model: > interactive catalog picker > native
#   non-interactive: CLI --model > TODO model: > first saved > native
# Staged graph/orchestration: stage/voter model: > saved > native (no profile, no global --model).
# Profile-derived models and *_PLAN_MODEL env are not rungs.
# models.json is a selection catalog for attended runs, not an auto-pick of index 0.

source "$BATS_TEST_DIRNAME/../helper/load-lib.bash"
bats_require_minimum_version 1.5.0

MODEL_STORE_LIB="$REPO_ROOT/bundle/.ralph/bash-lib/select-model/model-store.sh"
SELECT_MODEL_COMMON="$REPO_ROOT/bundle/.ralph/bash-lib/select-model/select-model-common.sh"
MODELS_SH="$REPO_ROOT/bundle/.ralph/models.sh"
PLAN_TODO_LIB="$REPO_ROOT/bundle/.ralph/bash-lib/plan-todo.sh"
ORCHESTRATOR_SH="$REPO_ROOT/bundle/.ralph/orchestrator.sh"
GRAPH_RUN_SH="$REPO_ROOT/bundle/.ralph/graph-run.sh"

setup() {
  bats_skip_known_ci_flakes
  command -v jq >/dev/null || skip "jq required"
  TEST_TMPDIR="$(mktemp -d)"
  export RALPH_CONFIG_HOME="$TEST_TMPDIR/ralph-config"
  mkdir -p "$RALPH_CONFIG_HOME"
  unset PLAN_MODEL_CLI PLAN_TODO_MODEL PLAN_STAGE_MODEL RALPH_MODEL_SCOPE
  unset CLAUDE_PLAN_MODEL CODEX_PLAN_MODEL CURSOR_PLAN_MODEL
  unset OPENCODE_PLAN_MODEL ANTIGRAVITY_PLAN_MODEL
  unset NON_INTERACTIVE_FLAG
}

teardown() {
  [[ -n "${TEST_TMPDIR:-}" && -d "$TEST_TMPDIR" ]] && rm -rf "$TEST_TMPDIR"
}

@test "attended leaf: picker runs even when saved models exist" {
  [[ -r /dev/tty ]] || skip "requires readable /dev/tty"
  bash "$MODELS_SH" add codex saved-must-not-auto-apply
  bash "$MODELS_SH" add codex saved-second

  run env -i PATH="$PATH" HOME="$HOME" RALPH_CONFIG_HOME="$RALPH_CONFIG_HOME" bash --noprofile --norc -c '
    set -euo pipefail
    export RALPH_CONFIG_HOME="$1"
    # shellcheck source=/dev/null
    source "$2"
    # shellcheck source=/dev/null
    source "$3"
    unset PLAN_MODEL_CLI PLAN_TODO_MODEL CLAUDE_PLAN_MODEL CODEX_PLAN_MODEL CURSOR_PLAN_MODEL
    export NON_INTERACTIVE_FLAG=0
    _codex_select_model_interactive() { printf "%s\n" "picked-from-menu"; }
    ralph_resolve_claude_codex_plan_model codex ""
  ' _ "$RALPH_CONFIG_HOME" "$MODEL_STORE_LIB" "$SELECT_MODEL_COMMON"

  [ "$status" -eq 0 ]
  [ "$output" = "picked-from-menu" ]
}

@test "non-interactive: first saved model is fallback when no pin" {
  # add prepends, so the last add is index 0 / non-interactive fallback.
  bash "$MODELS_SH" add codex ni-saved-older
  bash "$MODELS_SH" add codex ni-saved-first

  run env -i PATH="$PATH" HOME="$HOME" RALPH_CONFIG_HOME="$RALPH_CONFIG_HOME" bash --noprofile --norc -c '
    set -euo pipefail
    export RALPH_CONFIG_HOME="$1"
    # shellcheck source=/dev/null
    source "$2"
    # shellcheck source=/dev/null
    source "$3"
    unset PLAN_MODEL_CLI PLAN_TODO_MODEL CLAUDE_PLAN_MODEL CODEX_PLAN_MODEL CURSOR_PLAN_MODEL
    export NON_INTERACTIVE_FLAG=1
    ralph_resolve_claude_codex_plan_model codex ""
  ' _ "$RALPH_CONFIG_HOME" "$MODEL_STORE_LIB" "$SELECT_MODEL_COMMON"

  [ "$status" -eq 0 ]
  [ "$output" = "ni-saved-first" ]
}

@test "standard model: CLI wins over TODO saved and profile" {
  bash "$MODELS_SH" add claude saved-should-lose

  run env -i PATH="$PATH" HOME="$HOME" RALPH_CONFIG_HOME="$RALPH_CONFIG_HOME" bash --noprofile --norc -c '
    set -euo pipefail
    export RALPH_CONFIG_HOME="$1"
    # shellcheck source=/dev/null
    source "$2"
    # shellcheck source=/dev/null
    source "$3"
    unset CLAUDE_PLAN_MODEL CURSOR_PLAN_MODEL
    export PLAN_MODEL_CLI=cli-model
    export PLAN_TODO_MODEL=todo-model
    export NON_INTERACTIVE_FLAG=1
    # Legacy profile arg must be ignored.
    ralph_resolve_claude_codex_plan_model claude profile-model
  ' _ "$RALPH_CONFIG_HOME" "$MODEL_STORE_LIB" "$SELECT_MODEL_COMMON"

  [ "$status" -eq 0 ]
  [ "$output" = "cli-model" ]
}

@test "standard model: TODO wins over saved when CLI unset" {
  bash "$MODELS_SH" add claude saved-should-lose

  run env -i PATH="$PATH" HOME="$HOME" RALPH_CONFIG_HOME="$RALPH_CONFIG_HOME" bash --noprofile --norc -c '
    set -euo pipefail
    export RALPH_CONFIG_HOME="$1"
    # shellcheck source=/dev/null
    source "$2"
    # shellcheck source=/dev/null
    source "$3"
    unset PLAN_MODEL_CLI CLAUDE_PLAN_MODEL CURSOR_PLAN_MODEL
    export PLAN_TODO_MODEL=todo-model
    export NON_INTERACTIVE_FLAG=1
    ralph_resolve_claude_codex_plan_model claude profile-model
  ' _ "$RALPH_CONFIG_HOME" "$MODEL_STORE_LIB" "$SELECT_MODEL_COMMON"

  [ "$status" -eq 0 ]
  [ "$output" = "todo-model" ]
}

@test "standard model: saved wins over native default" {
  bash "$MODELS_SH" add claude chain-saved

  run env -i PATH="$PATH" HOME="$HOME" RALPH_CONFIG_HOME="$RALPH_CONFIG_HOME" bash --noprofile --norc -c '
    set -euo pipefail
    export RALPH_CONFIG_HOME="$1"
    # shellcheck source=/dev/null
    source "$2"
    # shellcheck source=/dev/null
    source "$3"
    unset PLAN_MODEL_CLI PLAN_TODO_MODEL CLAUDE_PLAN_MODEL CURSOR_PLAN_MODEL
    export NON_INTERACTIVE_FLAG=1
    ralph_resolve_claude_codex_plan_model claude profile-model
  ' _ "$RALPH_CONFIG_HOME" "$MODEL_STORE_LIB" "$SELECT_MODEL_COMMON"

  [ "$status" -eq 0 ]
  [ "$output" = "chain-saved" ]
}

@test "standard model: native default is empty when CLI TODO and saved unset" {
  run env -i PATH="$PATH" HOME="$HOME" RALPH_CONFIG_HOME="$RALPH_CONFIG_HOME" bash --noprofile --norc -c '
    set -euo pipefail
    export RALPH_CONFIG_HOME="$1"
    # shellcheck source=/dev/null
    source "$2"
    # shellcheck source=/dev/null
    source "$3"
    unset PLAN_MODEL_CLI PLAN_TODO_MODEL CLAUDE_PLAN_MODEL CURSOR_PLAN_MODEL
    export NON_INTERACTIVE_FLAG=1
    out="$(ralph_resolve_claude_codex_plan_model claude profile-model)"
    ec=$?
    printf "ec=%s out=%s\n" "$ec" "$out"
  ' _ "$RALPH_CONFIG_HOME" "$MODEL_STORE_LIB" "$SELECT_MODEL_COMMON"

  [ "$status" -eq 0 ]
  [ "$output" = "ec=0 out=" ]
}

@test "standard model: profile and PLAN_MODEL env are not rungs" {
  run env -i PATH="$PATH" HOME="$HOME" RALPH_CONFIG_HOME="$RALPH_CONFIG_HOME" bash --noprofile --norc -c '
    set -euo pipefail
    export RALPH_CONFIG_HOME="$1"
    # shellcheck source=/dev/null
    source "$2"
    # shellcheck source=/dev/null
    source "$3"
    unset PLAN_MODEL_CLI PLAN_TODO_MODEL
    export CLAUDE_PLAN_MODEL=env-model
    export CURSOR_PLAN_MODEL=cursor-env-model
    export NON_INTERACTIVE_FLAG=1
    out="$(ralph_resolve_claude_codex_plan_model claude profile-model)"
    printf "out=%s\n" "$out"
  ' _ "$RALPH_CONFIG_HOME" "$MODEL_STORE_LIB" "$SELECT_MODEL_COMMON"

  [ "$status" -eq 0 ]
  [ "$output" = "out=" ]
}

@test "standard model: CLI wins over TODO in direct chain" {
  run bash --noprofile --norc -c '
    set -euo pipefail
    export RALPH_CONFIG_HOME="$1"
    # shellcheck source=/dev/null
    source "$2"
    # shellcheck source=/dev/null
    source "$3"
    _select_model_resolve_claude_codex_chain claude "cli-model" "todo-model" "1"
  ' _ "$RALPH_CONFIG_HOME" "$MODEL_STORE_LIB" "$SELECT_MODEL_COMMON"

  [ "$status" -eq 0 ]
  [ "$output" = "cli-model" ]
}

@test "standard model: antigravity native default is empty without CLI or TODO" {
  run bash --noprofile --norc -c '
    set -euo pipefail
    # shellcheck source=/dev/null
    source "$1"
    unset PLAN_MODEL_CLI PLAN_TODO_MODEL
    unset ANTIGRAVITY_PLAN_MODEL OPENCODE_PLAN_MODEL CURSOR_PLAN_MODEL
    export NON_INTERACTIVE_FLAG=1
    out="$(ralph_resolve_antigravity_plan_model profile-model)"
    printf "out=%s\n" "$out"
  ' _ "$SELECT_MODEL_COMMON"

  [ "$status" -eq 0 ]
  [ "$output" = "out=" ]
}

@test "standard model: antigravity CLI wins over TODO" {
  run bash --noprofile --norc -c '
    set -euo pipefail
    # shellcheck source=/dev/null
    source "$1"
    export PLAN_MODEL_CLI=agy-cli
    export PLAN_TODO_MODEL=agy-todo
    export NON_INTERACTIVE_FLAG=1
    ralph_resolve_antigravity_plan_model profile-model
  ' _ "$SELECT_MODEL_COMMON"

  [ "$status" -eq 0 ]
  [ "$output" = "agy-cli" ]
}

@test "stage model: stage wins over saved and profile" {
  bash "$MODELS_SH" add claude saved-should-lose

  run env -i PATH="$PATH" HOME="$HOME" RALPH_CONFIG_HOME="$RALPH_CONFIG_HOME" bash --noprofile --norc -c '
    set -euo pipefail
    export RALPH_CONFIG_HOME="$1"
    # shellcheck source=/dev/null
    source "$2"
    # shellcheck source=/dev/null
    source "$3"
    unset PLAN_MODEL_CLI PLAN_TODO_MODEL CLAUDE_PLAN_MODEL
    export PLAN_STAGE_MODEL=stage-model
    export NON_INTERACTIVE_FLAG=1
    # Profile arg is not a staged rung; PLAN_STAGE_MODEL wins over saved.
    ralph_resolve_staged_plan_model claude
  ' _ "$RALPH_CONFIG_HOME" "$MODEL_STORE_LIB" "$SELECT_MODEL_COMMON"

  [ "$status" -eq 0 ]
  [ "$output" = "stage-model" ]
}

@test "voter model: voter wins over saved" {
  bash "$MODELS_SH" add claude saved-should-lose

  run env -i PATH="$PATH" HOME="$HOME" RALPH_CONFIG_HOME="$RALPH_CONFIG_HOME" bash --noprofile --norc -c '
    set -euo pipefail
    export RALPH_CONFIG_HOME="$1"
    # shellcheck source=/dev/null
    source "$2"
    # shellcheck source=/dev/null
    source "$3"
    unset PLAN_MODEL_CLI PLAN_TODO_MODEL PLAN_STAGE_MODEL CLAUDE_PLAN_MODEL
    export NON_INTERACTIVE_FLAG=1
    # Consensus voter model is the same staged resolver with voter model as arg.
    ralph_resolve_staged_plan_model claude voter-model
  ' _ "$RALPH_CONFIG_HOME" "$MODEL_STORE_LIB" "$SELECT_MODEL_COMMON"

  [ "$status" -eq 0 ]
  [ "$output" = "voter-model" ]
}

@test "stage model: saved wins over native when stage unset" {
  bash "$MODELS_SH" add claude staged-saved

  run env -i PATH="$PATH" HOME="$HOME" RALPH_CONFIG_HOME="$RALPH_CONFIG_HOME" bash --noprofile --norc -c '
    set -euo pipefail
    export RALPH_CONFIG_HOME="$1"
    # shellcheck source=/dev/null
    source "$2"
    # shellcheck source=/dev/null
    source "$3"
    unset PLAN_MODEL_CLI PLAN_TODO_MODEL PLAN_STAGE_MODEL CLAUDE_PLAN_MODEL
    export NON_INTERACTIVE_FLAG=1
    ralph_resolve_staged_plan_model claude ""
  ' _ "$RALPH_CONFIG_HOME" "$MODEL_STORE_LIB" "$SELECT_MODEL_COMMON"

  [ "$status" -eq 0 ]
  [ "$output" = "staged-saved" ]
}

@test "stage model: native default is empty without stage or saved" {
  run env -i PATH="$PATH" HOME="$HOME" RALPH_CONFIG_HOME="$RALPH_CONFIG_HOME" bash --noprofile --norc -c '
    set -euo pipefail
    export RALPH_CONFIG_HOME="$1"
    # shellcheck source=/dev/null
    source "$2"
    # shellcheck source=/dev/null
    source "$3"
    unset PLAN_MODEL_CLI PLAN_TODO_MODEL PLAN_STAGE_MODEL CLAUDE_PLAN_MODEL
    export NON_INTERACTIVE_FLAG=1
    out="$(ralph_resolve_staged_plan_model claude "")"
    ec=$?
    printf "ec=%s out=%s\n" "$ec" "$out"
  ' _ "$RALPH_CONFIG_HOME" "$MODEL_STORE_LIB" "$SELECT_MODEL_COMMON"

  [ "$status" -eq 0 ]
  [ "$output" = "ec=0 out=" ]
}

@test "stage model: profile and PLAN_MODEL env are not rungs" {
  run env -i PATH="$PATH" HOME="$HOME" RALPH_CONFIG_HOME="$RALPH_CONFIG_HOME" bash --noprofile --norc -c '
    set -euo pipefail
    export RALPH_CONFIG_HOME="$1"
    # shellcheck source=/dev/null
    source "$2"
    # shellcheck source=/dev/null
    source "$3"
    unset PLAN_MODEL_CLI PLAN_TODO_MODEL PLAN_STAGE_MODEL
    export CLAUDE_PLAN_MODEL=env-model
    export CURSOR_PLAN_MODEL=cursor-env
    export NON_INTERACTIVE_FLAG=1
    out="$(ralph_resolve_staged_plan_model claude "")"
    printf "out=%s\n" "$out"
  ' _ "$RALPH_CONFIG_HOME" "$MODEL_STORE_LIB" "$SELECT_MODEL_COMMON"

  [ "$status" -eq 0 ]
  [ "$output" = "out=" ]
}

@test "workflow instantiation injects no model" {
  command -v python3 >/dev/null || skip "python3 required"
  # shellcheck source=/dev/null
  source "$PLAN_TODO_LIB"

  wf="$TEST_TMPDIR/wf.workflow.md"
  out="$TEST_TMPDIR/out.plan.md"
  printf '%s\n' \
    '---' \
    'name: no-model-wf' \
    'kind: workflow' \
    'engine: graph' \
    'pipeline:' \
    '  stages:' \
    '    - id: source' \
    '      runtime: cursor' \
    'todos:' \
    '  - id: source-work' \
    '    stage: source' \
    '    content: |' \
    '      Do: {{TASK}}' \
    '    status: pending' \
    '---' >"$wf"

  run plan_workflow_instantiate "$wf" "ship feature" "$out"
  [ "$status" -eq 0 ]
  [ -f "$out" ]
  # Instantiation must not invent a model field on stages or todos.
  ! grep -E '^[[:space:]]*model:' "$out"
}

@test "global model: orchestration rejects --model" {
  run bash "$ORCHESTRATOR_SH" --model gpt-x --orchestration "$TEST_TMPDIR/missing.orch.json"
  [ "$status" -ne 0 ]
  [[ "$output" == *"does not accept --model"* ]]
}

@test "global model: graph run rejects --model" {
  run bash "$GRAPH_RUN_SH" run "$TEST_TMPDIR/missing.plan.md" --model composer-2 --yes
  [ "$status" -ne 0 ]
  [[ "$output" == *"does not accept --model"* ]]
}
