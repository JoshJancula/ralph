#!/usr/bin/env bats

# Pure workflow runtime/model routing resolver.
# Sourced-function level (cheapest that observes public precedence, pairing,
# provided-plan isolation, saved-model limits, voter/supervisor contracts).
# Contracts: agents/rules/test-design.md, agents/rules/testing-workflow.md,
# .ralph-workspace/artifacts/ralph-first-class-workflows/contracts.md
# (Workflow plan-run runtime/model order, pairing, supplied-plan routing).

source "$BATS_TEST_DIRNAME/../helper/load-lib.bash"

setup_file() {
  WR_LIB="$REPO_ROOT/bundle/.ralph/bash-lib/workflow/workflow-routing.sh"
  export WR_LIB
}

setup() {
  unset RALPH_WORKFLOW_ROUTING_LOADED
  unset WORKFLOW_ROUTING_SAVED_MODEL_SET WORKFLOW_ROUTING_SAVED_MODEL
  unset WORKFLOW_ROUTING_AVAILABLE_RUNTIMES WORKFLOW_ROUTING_DISCOVERED_MODELS
  unset WORKFLOW_ROUTING_MODEL_DISCOVERY_UNAVAILABLE WORKFLOW_ROUTING_FORCE_COLOR
  unset WR_runtime WR_runtime_provenance WR_model WR_model_provenance
  unset WR_unresolved WR_fresh_session
  unset WP_runtime WP_model WP_model_skipped WP_cancelled
  unset NO_COLOR RALPH_CONFIG_HOME
  # shellcheck source=../../../bundle/.ralph/bash-lib/workflow/workflow-routing.sh
  source "$WR_LIB"
}

resolve() {
  workflow_routing_resolve_into WR "$@"
}

@test "precedence: runtime order is todo > stage > invocation > workflow > environment" {
  # saved_model= isolates claude/codex from the operator model store.
  resolve \
    kind=agent \
    todo_runtime=cursor \
    stage_runtime=claude \
    invocation_runtime=codex \
    workflow_runtime=opencode \
    env_runtime=antigravity \
    saved_model=
  [[ "$WR_runtime" == "cursor" ]]
  [[ "$WR_runtime_provenance" == "todo" ]]

  resolve \
    kind=agent \
    stage_runtime=claude \
    invocation_runtime=codex \
    workflow_runtime=opencode \
    env_runtime=antigravity \
    saved_model=
  [[ "$WR_runtime" == "claude" ]]
  [[ "$WR_runtime_provenance" == "stage" ]]

  resolve \
    kind=agent \
    invocation_runtime=codex \
    workflow_runtime=opencode \
    env_runtime=antigravity \
    saved_model=
  [[ "$WR_runtime" == "codex" ]]
  [[ "$WR_runtime_provenance" == "invocation" ]]

  resolve \
    kind=agent \
    workflow_runtime=opencode \
    env_runtime=antigravity \
    saved_model=
  [[ "$WR_runtime" == "opencode" ]]
  [[ "$WR_runtime_provenance" == "workflow" ]]

  resolve \
    kind=agent \
    env_runtime=antigravity \
    saved_model=
  [[ "$WR_runtime" == "antigravity" ]]
  [[ "$WR_runtime_provenance" == "environment" ]]
}

@test "precedence: model order is todo > stage > invocation > workflow > saved > native" {
  resolve \
    kind=agent \
    workflow_runtime=claude \
    todo_model=todo-model \
    stage_model=stage-model \
    invocation_runtime=claude \
    invocation_model=inv-model \
    workflow_model=wf-model \
    saved_model=saved-model
  [[ "$WR_model" == "todo-model" ]]
  [[ "$WR_model_provenance" == "todo" ]]

  resolve \
    kind=agent \
    workflow_runtime=claude \
    stage_model=stage-model \
    invocation_runtime=claude \
    invocation_model=inv-model \
    workflow_model=wf-model \
    saved_model=saved-model
  [[ "$WR_model" == "stage-model" ]]
  [[ "$WR_model_provenance" == "stage" ]]

  resolve \
    kind=agent \
    invocation_runtime=claude \
    invocation_model=inv-model \
    workflow_runtime=claude \
    workflow_model=wf-model \
    saved_model=saved-model
  [[ "$WR_runtime" == "claude" ]]
  [[ "$WR_model" == "inv-model" ]]
  [[ "$WR_model_provenance" == "invocation" ]]

  resolve \
    kind=agent \
    workflow_runtime=claude \
    workflow_model=wf-model \
    saved_model=saved-model
  [[ "$WR_model" == "wf-model" ]]
  [[ "$WR_model_provenance" == "workflow" ]]

  resolve \
    kind=agent \
    workflow_runtime=claude \
    saved_model=saved-model
  [[ "$WR_model" == "saved-model" ]]
  [[ "$WR_model_provenance" == "saved" ]]
}

@test "pairing: invocation and workflow models apply only with paired effective runtime" {
  resolve \
    kind=agent \
    invocation_runtime=claude \
    invocation_model=inv-opus \
    workflow_runtime=claude \
    workflow_model=wf-sonnet \
    saved_model=
  [[ "$WR_runtime" == "claude" ]]
  [[ "$WR_model" == "inv-opus" ]]
  [[ "$WR_model_provenance" == "invocation" ]]

  # Workflow model paired with workflow runtime when invocation absent.
  resolve \
    kind=agent \
    workflow_runtime=claude \
    workflow_model=wf-sonnet \
    saved_model=
  [[ "$WR_model" == "wf-sonnet" ]]
  [[ "$WR_model_provenance" == "workflow" ]]

  # Unpaired invocation model (runtime empty) does not apply to workflow runtime.
  resolve \
    kind=agent \
    invocation_model=orphan-model \
    workflow_runtime=claude \
    workflow_model=wf-sonnet \
    saved_model=
  [[ "$WR_runtime" == "claude" ]]
  [[ "$WR_model" == "wf-sonnet" ]]
  [[ "$WR_model_provenance" == "workflow" ]]
}

@test "pairing: stage and todo model-only inherit effective runtime" {
  resolve \
    kind=agent \
    workflow_runtime=cursor \
    stage_model=stage-only-model
  [[ "$WR_runtime" == "cursor" ]]
  [[ "$WR_runtime_provenance" == "workflow" ]]
  [[ "$WR_model" == "stage-only-model" ]]
  [[ "$WR_model_provenance" == "stage" ]]
  [[ "$WR_fresh_session" == "0" ]]

  resolve \
    kind=agent \
    invocation_runtime=claude \
    todo_model=todo-only-model \
    saved_model=
  [[ "$WR_runtime" == "claude" ]]
  [[ "$WR_model" == "todo-only-model" ]]
  [[ "$WR_model_provenance" == "todo" ]]
}

@test "different runtime: runtime-only override drops unpaired invocation model and uses fresh session" {
  resolve \
    kind=agent \
    todo_runtime=cursor \
    invocation_runtime=claude \
    invocation_model=claude-opus \
    workflow_runtime=claude \
    workflow_model=claude-sonnet \
    saved_model=
  [[ "$WR_runtime" == "cursor" ]]
  [[ "$WR_runtime_provenance" == "todo" ]]
  [[ "$WR_model" == "" ]]
  [[ "$WR_model_provenance" == "native" ]]
  [[ "$WR_fresh_session" == "1" ]]

  resolve \
    kind=agent \
    stage_runtime=opencode \
    invocation_runtime=claude \
    invocation_model=claude-opus \
    saved_model=
  [[ "$WR_runtime" == "opencode" ]]
  [[ "$WR_runtime_provenance" == "stage" ]]
  [[ "$WR_model_provenance" == "native" ]]
  [[ "$WR_fresh_session" == "1" ]]
}

@test "different runtime: explicit todo runtime+model pair keeps model and does not force fresh_session" {
  resolve \
    kind=agent \
    todo_runtime=cursor \
    todo_model=cursor-model \
    invocation_runtime=claude \
    invocation_model=claude-opus
  [[ "$WR_runtime" == "cursor" ]]
  [[ "$WR_model" == "cursor-model" ]]
  [[ "$WR_model_provenance" == "todo" ]]
  [[ "$WR_fresh_session" == "0" ]]
}

@test "provided plan: header participates for plan-input consumer between invocation and workflow" {
  resolve \
    kind=agent \
    plan_input_consumer=1 \
    provided_plan_runtime=claude \
    provided_plan_model=plan-header-model \
    workflow_runtime=cursor \
    workflow_model=wf-model \
    saved_model=
  [[ "$WR_runtime" == "claude" ]]
  [[ "$WR_runtime_provenance" == "provided-plan" ]]
  [[ "$WR_model" == "plan-header-model" ]]
  [[ "$WR_model_provenance" == "provided-plan" ]]

  # Invocation still beats provided-plan.
  resolve \
    kind=agent \
    plan_input_consumer=1 \
    invocation_runtime=codex \
    invocation_model=inv-model \
    provided_plan_runtime=claude \
    provided_plan_model=plan-header-model \
    saved_model=
  [[ "$WR_runtime" == "codex" ]]
  [[ "$WR_runtime_provenance" == "invocation" ]]
  [[ "$WR_model" == "inv-model" ]]
  [[ "$WR_model_provenance" == "invocation" ]]
}

@test "provided plan: model-only header inherits effective runtime for consumer" {
  resolve \
    kind=agent \
    plan_input_consumer=1 \
    workflow_runtime=claude \
    provided_plan_model=plan-model-only \
    saved_model=saved-should-lose
  [[ "$WR_runtime" == "claude" ]]
  [[ "$WR_model" == "plan-model-only" ]]
  [[ "$WR_model_provenance" == "provided-plan" ]]
}

@test "no leakage: provided-plan header ignored for non-consumer stages such as QA or review" {
  resolve \
    kind=agent \
    plan_input_consumer=0 \
    provided_plan_runtime=claude \
    provided_plan_model=must-not-leak \
    workflow_runtime=cursor \
    workflow_model=review-model \
    saved_model=
  [[ "$WR_runtime" == "cursor" ]]
  [[ "$WR_runtime_provenance" == "workflow" ]]
  [[ "$WR_model" == "review-model" ]]
  [[ "$WR_model_provenance" == "workflow" ]]
  [[ "$WR_model" != "must-not-leak" ]]

  # Stage with empty workflow still must not pick up provided-plan when not consumer.
  resolve \
    kind=agent \
    plan_input_consumer=0 \
    provided_plan_runtime=claude \
    provided_plan_model=must-not-leak \
    env_runtime=opencode \
    saved_model=
  [[ "$WR_runtime" == "opencode" ]]
  [[ "$WR_runtime_provenance" == "environment" ]]
  [[ "$WR_model_provenance" == "native" ]]
  [[ "$WR_model" != "must-not-leak" ]]
}

@test "saved: claude and codex consult saved models; other runtimes stay native" {
  resolve \
    kind=agent \
    workflow_runtime=claude \
    saved_model=claude-saved
  [[ "$WR_model" == "claude-saved" ]]
  [[ "$WR_model_provenance" == "saved" ]]

  resolve \
    kind=agent \
    workflow_runtime=codex \
    saved_model=codex-saved
  [[ "$WR_model" == "codex-saved" ]]
  [[ "$WR_model_provenance" == "saved" ]]

  # Injected saved_model must not apply to cursor (saved-store limit).
  resolve \
    kind=agent \
    workflow_runtime=cursor \
    saved_model=should-ignore
  [[ "$WR_model" == "" ]]
  [[ "$WR_model_provenance" == "native" ]]

  resolve \
    kind=agent \
    workflow_runtime=opencode \
    saved_model=should-ignore
  [[ "$WR_model_provenance" == "native" ]]

  resolve \
    kind=agent \
    workflow_runtime=antigravity \
    saved_model=should-ignore
  [[ "$WR_model_provenance" == "native" ]]
}

@test "saved: empty saved store yields native provenance for claude" {
  resolve \
    kind=agent \
    workflow_runtime=claude \
    saved_model=
  [[ "$WR_model" == "" ]]
  [[ "$WR_model_provenance" == "native" ]]
}

@test "voter: explicit runtime retained; missing explicit runtime is refused" {
  resolve \
    kind=voter \
    stage_runtime=claude \
    stage_model=voter-model \
    workflow_runtime=cursor \
    workflow_model=wf-model \
    env_runtime=opencode \
    saved_model=
  [[ "$WR_runtime" == "claude" ]]
  [[ "$WR_runtime_provenance" == "stage" ]]
  [[ "$WR_model" == "voter-model" ]]
  [[ "$WR_model_provenance" == "stage" ]]

  # No fallthrough to workflow/env for voters.
  run workflow_routing_resolve \
    kind=voter \
    workflow_runtime=cursor \
    env_runtime=claude
  [ "$status" -eq 1 ]
  [[ "$output" == *"explicit runtime"* ]]
}

@test "supervisor: empty routing result; refuses runtime or model inputs" {
  resolve kind=supervisor
  [[ "$WR_runtime" == "" ]]
  [[ "$WR_runtime_provenance" == "" ]]
  [[ "$WR_model" == "" ]]
  [[ "$WR_model_provenance" == "" ]]
  [[ "$WR_unresolved" == "0" ]]

  resolve kind=approval
  [[ "$WR_runtime" == "" ]]
  [[ "$WR_model" == "" ]]

  resolve kind=integrate
  [[ "$WR_runtime" == "" ]]

  run workflow_routing_resolve kind=supervisor stage_runtime=claude
  [ "$status" -eq 1 ]
  [[ "$output" == *"accepts no runtime or model"* ]]

  run workflow_routing_resolve kind=gate invocation_model=x
  [ "$status" -eq 1 ]
}

@test "provenance: unresolved agent reports unresolved without inventing runtime" {
  resolve kind=agent
  [[ "$WR_runtime" == "" ]]
  [[ "$WR_unresolved" == "1" ]]
  [[ "$WR_model" == "" ]]
  [[ "$WR_model_provenance" == "" ]]
}

@test "provenance: enum values cover todo stage invocation provided-plan workflow environment saved native" {
  resolve kind=agent todo_runtime=claude todo_model=m
  [[ "$WR_runtime_provenance" == "todo" ]]
  [[ "$WR_model_provenance" == "todo" ]]

  resolve kind=agent stage_runtime=claude stage_model=m
  [[ "$WR_runtime_provenance" == "stage" ]]
  [[ "$WR_model_provenance" == "stage" ]]

  resolve kind=agent invocation_runtime=claude invocation_model=m
  [[ "$WR_runtime_provenance" == "invocation" ]]
  [[ "$WR_model_provenance" == "invocation" ]]

  resolve kind=agent plan_input_consumer=1 provided_plan_runtime=claude provided_plan_model=m
  [[ "$WR_runtime_provenance" == "provided-plan" ]]
  [[ "$WR_model_provenance" == "provided-plan" ]]

  resolve kind=agent workflow_runtime=claude workflow_model=m
  [[ "$WR_runtime_provenance" == "workflow" ]]
  [[ "$WR_model_provenance" == "workflow" ]]

  resolve kind=agent env_runtime=claude saved_model=
  [[ "$WR_runtime_provenance" == "environment" ]]
  [[ "$WR_model_provenance" == "native" ]]

  resolve kind=agent workflow_runtime=claude saved_model=from-store
  [[ "$WR_model_provenance" == "saved" ]]
}

# --- Interactive unresolved fallback prompt ---------------------------------

prompt_parse() {
  local line key value
  WP_runtime="" WP_model="" WP_model_skipped="" WP_cancelled=""
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ -n "$line" ]] || continue
    key="${line%%=*}"
    value="${line#*=}"
    case "$key" in
      runtime) WP_runtime="$value" ;;
      model) WP_model="$value" ;;
      model_skipped) WP_model_skipped="$value" ;;
      cancelled) WP_cancelled="$value" ;;
    esac
  done <<<"$1"
}

@test "prompt noninteractive unresolved runtime errors with --runtime guidance" {
  run workflow_routing_prompt_unresolved_fallback noninteractive=1
  [ "$status" -eq 1 ]
  [[ "$output" == *"--runtime"* ]]
  [[ "$output" == *"non-interactive"* ]]
}

@test "prompt cancel exits without materialization" {
  export WORKFLOW_ROUTING_AVAILABLE_RUNTIMES="cursor claude"
  export RALPH_SKIP_FZF_HINT=1
  ralph_menu_select() { return 1; }
  export -f ralph_menu_select
  run workflow_routing_prompt_unresolved_fallback noninteractive=0
  [ "$status" -eq 2 ]
  prompt_parse "$output"
  [[ "$WP_cancelled" == "1" ]]
  [[ "$WP_runtime" == "" ]]
  [[ "$output" == *"without materialization"* ]]
}

@test "prompt runtime default skips model (empty model)" {
  export WORKFLOW_ROUTING_AVAILABLE_RUNTIMES="cursor"
  export WORKFLOW_ROUTING_DISCOVERED_MODELS="model-a"$'\n'"model-b"
  export RALPH_SKIP_FZF_HINT=1
  export BATS_TEST_TMPDIR
  ralph_menu_select() {
    local call_file="${BATS_TEST_TMPDIR}/menu-call-count"
    local call=0
    [[ -f "$call_file" ]] && call="$(cat "$call_file")"
    call=$((call + 1))
    printf '%s' "$call" >"$call_file"
    if [[ "$call" -eq 1 ]]; then
      printf '%s' "cursor"
      return 0
    fi
    local -a choices=()
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --prompt|--default) shift 2 ;;
        --) shift; break ;;
        *) break ;;
      esac
    done
    choices=("$@")
    printf '%s\n' "${choices[@]}" >"${BATS_TEST_TMPDIR}/model-menu-choices.txt"
    printf '%s' "Use cursor default"
  }
  export -f ralph_menu_select
  run workflow_routing_prompt_unresolved_fallback
  [ "$status" -eq 0 ]
  prompt_parse "$output"
  [[ "$WP_runtime" == "cursor" ]]
  [[ "$WP_model" == "" ]]
  [[ "$WP_model_skipped" == "1" ]]
  [[ "$WP_cancelled" == "0" ]]
  grep -qx "Use cursor default" "${BATS_TEST_TMPDIR}/model-menu-choices.txt"
  grep -qx "model-a" "${BATS_TEST_TMPDIR}/model-menu-choices.txt"
  grep -qx "Enter a model ID" "${BATS_TEST_TMPDIR}/model-menu-choices.txt"
}

@test "prompt custom model writes explicit model id" {
  export WORKFLOW_ROUTING_AVAILABLE_RUNTIMES="claude"
  export WORKFLOW_ROUTING_DISCOVERED_MODELS=""
  export RALPH_SKIP_FZF_HINT=1
  export BATS_TEST_TMPDIR
  ralph_menu_select() {
    local call_file="${BATS_TEST_TMPDIR}/menu-call-count"
    local call=0
    [[ -f "$call_file" ]] && call="$(cat "$call_file")"
    call=$((call + 1))
    printf '%s' "$call" >"$call_file"
    if [[ "$call" -eq 1 ]]; then
      printf '%s' "claude"
      return 0
    fi
    printf '%s' "Enter a model ID"
  }
  _select_model_read_rp() {
    local _var="$2"
    printf -v "$_var" '%s' "custom-claude-id"
    return 0
  }
  export -f ralph_menu_select _select_model_read_rp
  run workflow_routing_prompt_unresolved_fallback
  [ "$status" -eq 0 ]
  prompt_parse "$output"
  [[ "$WP_runtime" == "claude" ]]
  [[ "$WP_model" == "custom-claude-id" ]]
  [[ "$WP_model_skipped" == "0" ]]
}

@test "prompt custom model empty value uses runtime default" {
  export WORKFLOW_ROUTING_AVAILABLE_RUNTIMES="codex"
  export WORKFLOW_ROUTING_DISCOVERED_MODELS="saved-one"
  export RALPH_SKIP_FZF_HINT=1
  export BATS_TEST_TMPDIR
  ralph_menu_select() {
    local call_file="${BATS_TEST_TMPDIR}/menu-call-count"
    local call=0
    [[ -f "$call_file" ]] && call="$(cat "$call_file")"
    call=$((call + 1))
    printf '%s' "$call" >"$call_file"
    if [[ "$call" -eq 1 ]]; then
      printf '%s' "codex"
      return 0
    fi
    printf '%s' "Enter a model ID"
  }
  _select_model_read_rp() {
    local _var="$2"
    printf -v "$_var" '%s' ""
    return 0
  }
  export -f ralph_menu_select _select_model_read_rp
  run workflow_routing_prompt_unresolved_fallback
  [ "$status" -eq 0 ]
  prompt_parse "$output"
  [[ "$WP_runtime" == "codex" ]]
  [[ "$WP_model" == "" ]]
  [[ "$WP_model_skipped" == "1" ]]
}

@test "prompt unavailable CLI model discovery warns and uses runtime default" {
  export WORKFLOW_ROUTING_AVAILABLE_RUNTIMES="cursor"
  export WORKFLOW_ROUTING_MODEL_DISCOVERY_UNAVAILABLE=1
  export RALPH_SKIP_FZF_HINT=1
  ralph_menu_select() { printf '%s' "cursor"; }
  export -f ralph_menu_select
  run workflow_routing_prompt_unresolved_fallback
  [ "$status" -eq 0 ]
  prompt_parse "$output"
  [[ "$WP_runtime" == "cursor" ]]
  [[ "$WP_model" == "" ]]
  [[ "$WP_model_skipped" == "1" ]]
  [[ "$output" == *"model discovery unavailable"* ]]
}

@test "prompt no saved model still offers runtime default and Enter a model ID" {
  # Stub empty discovery: when the discovery override is explicitly empty, the
  # menu still offers runtime default + custom entry (no aliases injected by the
  # stub path). Real Claude discovery is covered by the live-discovery tests below.
  export WORKFLOW_ROUTING_AVAILABLE_RUNTIMES="claude"
  export WORKFLOW_ROUTING_DISCOVERED_MODELS=""
  export RALPH_SKIP_FZF_HINT=1
  export BATS_TEST_TMPDIR
  ralph_menu_select() {
    local call_file="${BATS_TEST_TMPDIR}/menu-call-count"
    local call=0
    [[ -f "$call_file" ]] && call="$(cat "$call_file")"
    call=$((call + 1))
    printf '%s' "$call" >"$call_file"
    if [[ "$call" -eq 1 ]]; then
      printf '%s' "claude"
      return 0
    fi
    local -a choices=()
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --prompt|--default) shift 2 ;;
        --) shift; break ;;
        *) break ;;
      esac
    done
    choices=("$@")
    printf '%s\n' "${choices[@]}" >"${BATS_TEST_TMPDIR}/no-saved-choices.txt"
    printf '%s' "Use claude default"
  }
  export -f ralph_menu_select
  run workflow_routing_prompt_unresolved_fallback
  [ "$status" -eq 0 ]
  prompt_parse "$output"
  [[ "$WP_model_skipped" == "1" ]]
  local choice_count
  choice_count="$(wc -l <"${BATS_TEST_TMPDIR}/no-saved-choices.txt" | tr -d ' ')"
  [[ "$choice_count" == "2" ]]
  grep -qx "Use claude default" "${BATS_TEST_TMPDIR}/no-saved-choices.txt"
  grep -qx "Enter a model ID" "${BATS_TEST_TMPDIR}/no-saved-choices.txt"
}

@test "prompt live Claude discovery offers haiku sonnet opus fable on a fresh store" {
  # Leave WORKFLOW_ROUTING_DISCOVERED_MODELS unset so the prompt calls
  # ralph_select_model_list_discovered against an empty isolated store.
  unset WORKFLOW_ROUTING_DISCOVERED_MODELS
  export RALPH_CONFIG_HOME="${BATS_TEST_TMPDIR}/claude-fresh-config"
  mkdir -p "$RALPH_CONFIG_HOME"
  export RALPH_SKIP_FZF_HINT=1
  export BATS_TEST_TMPDIR
  # Preload select-model so ensure_select_model early-returns and does not
  # re-source interactive-select.sh over the menu stub below. Export the
  # Claude catalog so the bats `run` subshell inherits it with the function.
  _workflow_routing_ensure_select_model
  export _CLAUDE_DEFAULT_MODELS
  ralph_menu_select() {
    local -a choices=()
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --prompt|--default) shift 2 ;;
        --) shift; break ;;
        *) break ;;
      esac
    done
    choices=("$@")
    printf '%s\n' "${choices[@]}" >"${BATS_TEST_TMPDIR}/claude-fresh-choices.txt"
    printf '%s' "Use claude default"
  }
  export -f ralph_menu_select
  run workflow_routing_prompt_model_for_runtime claude
  [ "$status" -eq 0 ]
  prompt_parse "$output"
  [[ "$WP_runtime" == "claude" ]]
  [[ "$WP_model_skipped" == "1" ]]
  grep -qx "Use claude default" "${BATS_TEST_TMPDIR}/claude-fresh-choices.txt"
  grep -qx "haiku" "${BATS_TEST_TMPDIR}/claude-fresh-choices.txt"
  grep -qx "sonnet" "${BATS_TEST_TMPDIR}/claude-fresh-choices.txt"
  grep -qx "opus" "${BATS_TEST_TMPDIR}/claude-fresh-choices.txt"
  grep -qx "fable" "${BATS_TEST_TMPDIR}/claude-fresh-choices.txt"
  grep -qx "Enter a model ID" "${BATS_TEST_TMPDIR}/claude-fresh-choices.txt"
  [[ "$(grep -c '^haiku$' "${BATS_TEST_TMPDIR}/claude-fresh-choices.txt")" -eq 1 ]]
  [[ "$(wc -l <"${BATS_TEST_TMPDIR}/claude-fresh-choices.txt" | tr -d ' ')" == "6" ]]
}

@test "prompt live Claude discovery keeps dated saved id with all aliases once" {
  unset WORKFLOW_ROUTING_DISCOVERED_MODELS
  export RALPH_CONFIG_HOME="${BATS_TEST_TMPDIR}/claude-dated-config"
  mkdir -p "$RALPH_CONFIG_HOME"
  printf '%s\n' '{"claude":["claude-sonnet-4-6","claude-haiku-4-5","opus"]}' >"$RALPH_CONFIG_HOME/models.json"
  export RALPH_SKIP_FZF_HINT=1
  export BATS_TEST_TMPDIR
  _workflow_routing_ensure_select_model
  export _CLAUDE_DEFAULT_MODELS
  ralph_menu_select() {
    local -a choices=()
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --prompt|--default) shift 2 ;;
        --) shift; break ;;
        *) break ;;
      esac
    done
    choices=("$@")
    printf '%s\n' "${choices[@]}" >"${BATS_TEST_TMPDIR}/claude-dated-choices.txt"
    printf '%s' "Use claude default"
  }
  export -f ralph_menu_select
  run workflow_routing_prompt_model_for_runtime claude
  [ "$status" -eq 0 ]
  # Saved first, then missing aliases; opus appears once.
  local expected=$'Use claude default\nclaude-sonnet-4-6\nclaude-haiku-4-5\nopus\nhaiku\nsonnet\nfable\nEnter a model ID'
  [[ "$(cat "${BATS_TEST_TMPDIR}/claude-dated-choices.txt")" == "$expected" ]]
  [[ "$(grep -c '^opus$' "${BATS_TEST_TMPDIR}/claude-dated-choices.txt")" -eq 1 ]]
  [[ "$(grep -c '^claude-sonnet-4-6$' "${BATS_TEST_TMPDIR}/claude-dated-choices.txt")" -eq 1 ]]
  [[ "$(grep -c '^claude-haiku-4-5$' "${BATS_TEST_TMPDIR}/claude-dated-choices.txt")" -eq 1 ]]
}

@test "prompt live Codex discovery stays saved-store-only" {
  unset WORKFLOW_ROUTING_DISCOVERED_MODELS
  export RALPH_CONFIG_HOME="${BATS_TEST_TMPDIR}/codex-fresh-config"
  mkdir -p "$RALPH_CONFIG_HOME"
  export RALPH_SKIP_FZF_HINT=1
  export BATS_TEST_TMPDIR
  _workflow_routing_ensure_select_model
  export _CLAUDE_DEFAULT_MODELS
  ralph_menu_select() {
    local -a choices=()
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --prompt|--default) shift 2 ;;
        --) shift; break ;;
        *) break ;;
      esac
    done
    choices=("$@")
    printf '%s\n' "${choices[@]}" >"${BATS_TEST_TMPDIR}/codex-fresh-choices.txt"
    printf '%s' "Use codex default"
  }
  export -f ralph_menu_select
  run workflow_routing_prompt_model_for_runtime codex
  [ "$status" -eq 0 ]
  local expected=$'Use codex default\nEnter a model ID'
  [[ "$(cat "${BATS_TEST_TMPDIR}/codex-fresh-choices.txt")" == "$expected" ]]
  ! grep -qE '^(haiku|sonnet|opus|fable)$' "${BATS_TEST_TMPDIR}/codex-fresh-choices.txt"
}

@test "prompt Antigravity preserves discovered display text byte-for-byte" {
  export WORKFLOW_ROUTING_AVAILABLE_RUNTIMES="antigravity"
  export WORKFLOW_ROUTING_DISCOVERED_MODELS="Claude Sonnet 4.6 (thinking)"$'\n'"Gemini 3.1 Pro (high)"
  export RALPH_SKIP_FZF_HINT=1
  export BATS_TEST_TMPDIR
  ralph_menu_select() {
    local call_file="${BATS_TEST_TMPDIR}/menu-call-count"
    local call=0
    [[ -f "$call_file" ]] && call="$(cat "$call_file")"
    call=$((call + 1))
    printf '%s' "$call" >"$call_file"
    if [[ "$call" -eq 1 ]]; then
      printf '%s' "antigravity"
      return 0
    fi
    local -a choices=()
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --prompt|--default) shift 2 ;;
        --) shift; break ;;
        *) break ;;
      esac
    done
    choices=("$@")
    printf '%s\n' "${choices[@]}" >"${BATS_TEST_TMPDIR}/agy-choices.txt"
    printf '%s' "Claude Sonnet 4.6 (thinking)"
  }
  export -f ralph_menu_select
  run workflow_routing_prompt_unresolved_fallback
  [ "$status" -eq 0 ]
  prompt_parse "$output"
  [[ "$WP_runtime" == "antigravity" ]]
  [[ "$WP_model" == "Claude Sonnet 4.6 (thinking)" ]]
  grep -qx "Claude Sonnet 4.6 (thinking)" "${BATS_TEST_TMPDIR}/agy-choices.txt"
  grep -qx "Gemini 3.1 Pro (high)" "${BATS_TEST_TMPDIR}/agy-choices.txt"
}

@test "prompt TTY color enables ANSI escape sequences" {
  export WORKFLOW_ROUTING_FORCE_COLOR=1
  unset NO_COLOR
  _workflow_routing_init_colors
  [[ -n "$C_BOLD" ]]
  [[ "$C_BOLD" == *$'\033['* ]]
}

@test "prompt NO_COLOR disables ANSI escape sequences" {
  export NO_COLOR=1
  unset WORKFLOW_ROUTING_FORCE_COLOR
  _workflow_routing_init_colors
  [[ -z "$C_BOLD" ]]
  [[ -z "$C_C" ]]
  [[ -z "$C_RST" ]]
}

@test "prompt exact contract strings appear for runtime then model menus" {
  export WORKFLOW_ROUTING_AVAILABLE_RUNTIMES="opencode"
  export WORKFLOW_ROUTING_DISCOVERED_MODELS="opencode/gpt-5-nano"
  export RALPH_SKIP_FZF_HINT=1
  export BATS_TEST_TMPDIR
  ralph_menu_select() {
    local call_file="${BATS_TEST_TMPDIR}/menu-call-count"
    local call=0
    [[ -f "$call_file" ]] && call="$(cat "$call_file")"
    call=$((call + 1))
    printf '%s' "$call" >"$call_file"
    local prompt=""
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --prompt) prompt="$2"; shift 2 ;;
        --default) shift 2 ;;
        --) shift; break ;;
        *) break ;;
      esac
    done
    printf '%s\n' "$prompt" >>"${BATS_TEST_TMPDIR}/prompt-strings.txt"
    if [[ "$call" -eq 1 ]]; then
      printf '%s' "opencode"
    else
      printf '%s' "Use opencode default"
    fi
  }
  export -f ralph_menu_select
  run workflow_routing_prompt_unresolved_fallback
  [ "$status" -eq 0 ]
  grep -qx "Select a runtime for unresolved workflow stages:" "${BATS_TEST_TMPDIR}/prompt-strings.txt"
  grep -qx "Use the runtime default model or select a model?" "${BATS_TEST_TMPDIR}/prompt-strings.txt"
  [[ "$output" == *"Select a runtime for unresolved workflow stages:"* ]]
  [[ "$output" == *"Use the runtime default model or select a model?"* ]]
}
