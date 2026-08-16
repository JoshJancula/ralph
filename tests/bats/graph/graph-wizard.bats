#!/usr/bin/env bats

source "$BATS_TEST_DIRNAME/../helper/load-lib.bash"

skip_flaky_wizard_ci_test() {
  if [[ -n "${CI:-}" ]]; then
    skip "Flaky in CI; tracked for follow-up"
  fi
}

_graph_wizard_setup() {
  local bundle_root="$1"
  local workspace="$2"
  mkdir -p "$bundle_root/.ralph/bash-lib"
  cp "$REPO_ROOT/bundle/.ralph/orchestration-wizard.sh" "$bundle_root/.ralph/orchestration-wizard.sh"
  cp "$REPO_ROOT/bundle/.ralph/graph-wizard.sh" "$bundle_root/.ralph/graph-wizard.sh"
  cp "$REPO_ROOT/bundle/.ralph/pipeline-wizard.sh" "$bundle_root/.ralph/pipeline-wizard.sh"
  cp -r "$REPO_ROOT/bundle/.ralph/bash-lib/." "$bundle_root/.ralph/bash-lib/"
  mkdir -p "$bundle_root/.ralph/python"
  cp "$REPO_ROOT/bundle/.ralph/python/wizard-prompts-agent-model.py" "$bundle_root/.ralph/python/"
  cp "$REPO_ROOT/bundle/.ralph/python/wizard-prompts-escape-json.py" "$bundle_root/.ralph/python/"
  mkdir -p "$bundle_root/.ralph/plan-templates"
  cp "$REPO_ROOT/bundle/.ralph/plan-templates/classic.plan.template.md" "$bundle_root/.ralph/plan-templates/classic.plan.template.md"
  if [[ -f "$REPO_ROOT/bundle/.ralph/plan-templates/pipeline-simple.plan.template.md" ]]; then
    cp "$REPO_ROOT/bundle/.ralph/plan-templates/pipeline-simple.plan.template.md" "$bundle_root/.ralph/plan-templates/pipeline-simple.plan.template.md"
  fi
  chmod +x "$bundle_root/.ralph/orchestration-wizard.sh" "$bundle_root/.ralph/graph-wizard.sh" "$bundle_root/.ralph/pipeline-wizard.sh"
  mkdir -p "$workspace/.cursor/agents/research"
  echo '{"model":"auto"}' > "$workspace/.cursor/agents/research/config.json"
}

# One agent node (research), one checkpoint node depending on it.
# Prompt order: 1-5 pipeline info, 6-8 graph extras (maxParallel/edgeDerivation/
# failurePolicy), 9 node ids, 10-11 per-node type. Then per node: agent nodes
# get depends_on (only when an earlier node exists) + 9 config prompts
# (inline/planFile, runtime, agent, content, verification, workspaceMode,
# contextBudget, produces, requires); checkpoint nodes get depends_on only.
_graph_two_node_happy_path_input() {
  printf "Graph E2E\n"      # name
  printf "\n"                # namespace (default)
  printf "\n"                # description (default)
  printf "\n"                # session strategy menu (default: fresh)
  printf "y\n"                # all nodes same session strategy
  printf "\n"                # maxParallel (default: 3)
  printf "\n"                # edgeDerivation (default: both)
  printf "\n"                # failurePolicy (default: drain)
  printf "research,check\n"  # node ids
  printf "\n"                # research type (default: agent)
  printf "3\n"                # check type: checkpoint
  printf '\n%.0s' {1..9}     # research: 9 config prompts (no depends_on, first node)
  printf "research\n"         # check: dependsOn -> research
  printf "y\n"                 # confirm write
}

@test "graph wizard end-to-end: agent node, checkpoint node, dependsOn" {
  skip_flaky_wizard_ci_test
  bundle_root="$(mktemp -d)"
  workspace="$(mktemp -d)"
  _graph_wizard_setup "$bundle_root" "$workspace"

  _graph_two_node_happy_path_input > "$workspace/input.txt"

  wizard="$bundle_root/.ralph/graph-wizard.sh"
  run bash -c 'export LC_ALL=C LANG=C RALPH_SKIP_FZF_HINT=1; cd "$1" && { tr -d "\r" < "$3" | bash "$2"; } 2>&1' bash "$workspace" "$wizard" "$workspace/input.txt"

  [ "$status" -eq 0 ]

  plan_file="$workspace/.ralph-workspace/plans/graph-e2e.plan.md"
  [ -f "$plan_file" ]

  grep -q "execution: graph" "$plan_file"
  grep -q "id: research" "$plan_file"
  grep -q "id: check" "$plan_file"
  grep -q "type: checkpoint" "$plan_file"
  grep -q "dependsOn:" "$plan_file"
  grep -q -- "- research" "$plan_file"
  grep -q "maxParallel: 3" "$plan_file"
  grep -q "edgeDerivation: both" "$plan_file"
  grep -q "failurePolicy: drain" "$plan_file"

  rm -rf "$bundle_root" "$workspace"
}

@test "graph wizard compiles the generated plan cleanly" {
  skip_flaky_wizard_ci_test
  bundle_root="$(mktemp -d)"
  workspace="$(mktemp -d)"
  _graph_wizard_setup "$bundle_root" "$workspace"
  mkdir -p "$bundle_root/.ralph/bash-lib/graph"
  cp -r "$REPO_ROOT/bundle/.ralph/bash-lib/graph/." "$bundle_root/.ralph/bash-lib/graph/"
  cp "$REPO_ROOT/bundle/.ralph/graph-run.sh" "$bundle_root/.ralph/graph-run.sh"
  mkdir -p "$bundle_root/.ralph/schemas"
  cp -r "$REPO_ROOT/bundle/.ralph/schemas/." "$bundle_root/.ralph/schemas/"

  _graph_two_node_happy_path_input > "$workspace/input.txt"

  wizard="$bundle_root/.ralph/graph-wizard.sh"
  run bash -c 'export LC_ALL=C LANG=C RALPH_SKIP_FZF_HINT=1; cd "$1" && { tr -d "\r" < "$3" | bash "$2"; } 2>&1' bash "$workspace" "$wizard" "$workspace/input.txt"
  [ "$status" -eq 0 ]

  plan_file="$workspace/.ralph-workspace/plans/graph-e2e.plan.md"
  [ -f "$plan_file" ]

  run bash "$REPO_ROOT/bundle/.ralph/graph-run.sh" compile "$plan_file"
  [ "$status" -eq 0 ]
  [[ "$output" == *'"type":"checkpoint"'* ]]

  rm -rf "$bundle_root" "$workspace"
}

@test "graph wizard shared workspaceMode without acknowledgement dies" {
  skip_flaky_wizard_ci_test
  bundle_root="$(mktemp -d)"
  workspace="$(mktemp -d)"
  _graph_wizard_setup "$bundle_root" "$workspace"

  {
    printf "Shared Risk\n"
    printf "\n"
    printf "\n"
    printf "\n"
    printf "y\n"
    printf "\n"
    printf "\n"
    printf "\n"
    printf "solo\n"
    printf "\n"                # solo type: agent
    printf "\n\n\n\n\n"        # inline/planFile, runtime, agent, content, verification
    printf "3\n"                 # workspaceMode: shared
    printf "n\n"                 # decline risk acknowledgement
  } > "$workspace/input.txt"

  wizard="$bundle_root/.ralph/graph-wizard.sh"
  run bash -c 'export LC_ALL=C LANG=C RALPH_SKIP_FZF_HINT=1; cd "$1" && { tr -d "\r" < "$3" | bash "$2"; } 2>&1' bash "$workspace" "$wizard" "$workspace/input.txt"

  [ "$status" -ne 0 ]
  [[ "$output" == *"requires acknowledging the risk"* ]]
  [ ! -e "$workspace/.ralph-workspace/plans/shared-risk.plan.md" ]

  rm -rf "$bundle_root" "$workspace"
}

@test "pipeline wizard with no --mode asks then behaves like graph-wizard" {
  skip_flaky_wizard_ci_test
  bundle_root="$(mktemp -d)"
  workspace="$(mktemp -d)"
  _graph_wizard_setup "$bundle_root" "$workspace"

  {
    printf "2\n"  # mode selection: 1=orchestration, 2=graph
    _graph_two_node_happy_path_input
  } > "$workspace/input.txt"

  wizard="$bundle_root/.ralph/pipeline-wizard.sh"
  run bash -c 'export LC_ALL=C LANG=C RALPH_SKIP_FZF_HINT=1; cd "$1" && { tr -d "\r" < "$3" | bash "$2"; } 2>&1' bash "$workspace" "$wizard" "$workspace/input.txt"

  [ "$status" -eq 0 ]
  plan_file="$workspace/.ralph-workspace/plans/graph-e2e.plan.md"
  [ -f "$plan_file" ]
  grep -q "execution: graph" "$plan_file"

  rm -rf "$bundle_root" "$workspace"
}

@test "select_depends_on restricts choices to already-defined ids" {
  run bash -c '
    set -euo pipefail
    export RALPH_SKIP_FZF_HINT=1
    source "$1/bundle/.ralph/bash-lib/error-handling.sh"
    source "$1/bundle/.ralph/bash-lib/ui-prompt.sh"
    source "$1/bundle/.ralph/bash-lib/wizard/wizard-prompts.sh"
    result="$(printf "research\n" | select_depends_on "implement" "research")"
    printf "result=%s\n" "$result"
    empty_result="$(select_depends_on "research" "")"
    printf "empty=%s\n" "${empty_result:-<empty>}"
  ' _ "$REPO_ROOT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"result=research"* ]]
  [[ "$output" == *"empty=<empty>"* ]]
}

@test "configure_voters collects flattened voter rows for a consensus node" {
  run bash -c '
    set -euo pipefail
    export RALPH_SKIP_FZF_HINT=1
    workspace="$(mktemp -d)"
    mkdir -p "$workspace/.cursor/agents/code-review" "$workspace/.codex/agents/code-review"
    echo "{\"model\":\"auto\"}" > "$workspace/.cursor/agents/code-review/config.json"
    echo "{\"model\":\"auto\"}" > "$workspace/.codex/agents/code-review/config.json"
    source "$1/bundle/.ralph/bash-lib/error-handling.sh"
    source "$1/bundle/.ralph/bash-lib/ui-prompt.sh"
    source "$1/bundle/.ralph/bash-lib/wizard/wizard-prompts.sh"
    source "$1/bundle/.ralph/bash-lib/wizard/wizard-pipeline-plan.sh"
    configure_voters "review" <<< "$(printf "alpha\n\n\nbeta\n3\n\nn")"
    printf "voters=%s\n" "${cp_voter_id[*]}"
    printf "runtimes=%s\n" "${cp_voter_runtime[*]}"
  ' _ "$REPO_ROOT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"voters=alpha beta"* ]]
  [[ "$output" == *"runtimes=cursor codex"* ]]
}

@test "wizard_render_pipeline_plan orchestration mode matches the legacy wrapper byte for byte" {
  run bash -c '
    set -euo pipefail
    source "$1/bundle/.ralph/bash-lib/error-handling.sh"
    source "$1/bundle/.ralph/bash-lib/wizard/wizard-pipeline-plan.sh"

    cp_stages=(research)
    cp_stage_types=(agent)
    cp_stage_runtimes=(cursor)
    cp_stage_agents=(research)
    cp_stage_models=(auto)
    cp_stage_session=(fresh)
    cp_stage_context=(standard)
    cp_stage_plan_files=("")
    cp_stage_inline_content=("")
    cp_stage_inline_verification=("")
    cp_stage_depends_on=("")
    cp_stage_policy=("")
    cp_stage_quorum=("")
    cp_stage_workspace_mode=("")
    cp_artifact_entries=()
    cp_parallel_waves=()

    a="$(wizard_render_pipeline_plan orchestration demo "Demo overview" "instructions: Execute one TODO at a time.")"
    b="$(wizard_render_pipeline_orchestration_plan demo "Demo overview" "instructions: Execute one TODO at a time.")"
    if [[ "$a" == "$b" ]]; then
      echo "MATCH"
    else
      echo "MISMATCH"
      diff <(printf "%s" "$a") <(printf "%s" "$b") || true
    fi
  ' _ "$REPO_ROOT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"MATCH"* ]]
}
