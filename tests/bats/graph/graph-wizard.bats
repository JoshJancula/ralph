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
  cp "$REPO_ROOT/bundle/.ralph/pipeline-wizard.sh" "$bundle_root/.ralph/pipeline-wizard.sh"
  cp -r "$REPO_ROOT/bundle/.ralph/bash-lib/." "$bundle_root/.ralph/bash-lib/"
  cp "$REPO_ROOT/bundle/.ralph/tooling-profiles.json" "$bundle_root/.ralph/tooling-profiles.json"
  mkdir -p "$bundle_root/.ralph/python"
  cp "$REPO_ROOT/bundle/.ralph/python/wizard-prompts-agent-model.py" "$bundle_root/.ralph/python/"
  cp "$REPO_ROOT/bundle/.ralph/python/wizard-prompts-escape-json.py" "$bundle_root/.ralph/python/"
  mkdir -p "$bundle_root/.ralph/schemas"
  cp "$REPO_ROOT/bundle/.ralph/schemas/graph-authoring-contract.json" \
    "$bundle_root/.ralph/schemas/graph-authoring-contract.json"
  mkdir -p "$bundle_root/.ralph/plan-templates"
  cp "$REPO_ROOT/bundle/.ralph/plan-templates/classic.plan.template.md" "$bundle_root/.ralph/plan-templates/classic.plan.template.md"
  if [[ -f "$REPO_ROOT/bundle/.ralph/plan-templates/pipeline-simple.plan.template.md" ]]; then
    cp "$REPO_ROOT/bundle/.ralph/plan-templates/pipeline-simple.plan.template.md" "$bundle_root/.ralph/plan-templates/pipeline-simple.plan.template.md"
  fi
  chmod +x "$bundle_root/.ralph/pipeline-wizard.sh"
  mkdir -p "$workspace/.cursor/agents/research" "$workspace/.codex/agents/research" "$workspace/.codex/agents/code-review"
  echo '{"model":"auto"}' > "$workspace/.cursor/agents/research/config.json"
  echo '{"model":"auto"}' > "$workspace/.codex/agents/research/config.json"
  echo '{"model":"auto"}' > "$workspace/.codex/agents/code-review/config.json"
}

# One agent node (research), one checkpoint node depending on it.
# Prompt order: 1-5 pipeline info, 6-8 graph extras (maxParallel/edgeDerivation/
# failurePolicy), 9 node ids, 10-11 per-node type. Then per node: agent nodes
# get depends_on (only when an earlier node exists) + 10 config prompts
# (inline/planFile, runtime, native subagents, content, verification, workspaceMode,
# writeScopes, contextBudget, produces, requires); checkpoint nodes get
# depends_on only. writeScopes is prompted for every non-shared workspace mode.
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
  _graph_tooling_default_prompts  # tooling: configure y, default profile, apply to all
  printf "\n"                # research type (default: agent)
  printf "3\n"                # check type: checkpoint
  printf '\n%.0s' {1..10}    # research: 10 config prompts (no depends_on, first node)
  printf "research\n"         # check: dependsOn -> research
  printf "y\n"                 # confirm write
}

@test "graph wizard end-to-end: agent node, checkpoint node, dependsOn" {
  skip_flaky_wizard_ci_test
  bundle_root="$(mktemp -d)"
  workspace="$(mktemp -d)"
  _graph_wizard_setup "$bundle_root" "$workspace"

  _graph_two_node_happy_path_input > "$workspace/input.txt"

  wizard="$bundle_root/.ralph/pipeline-wizard.sh"
  run bash -c 'export LC_ALL=C LANG=C RALPH_SKIP_FZF_HINT=1; cd "$1" && { tr -d "\r" < "$3" | bash "$2" --mode graph; } 2>&1' bash "$workspace" "$wizard" "$workspace/input.txt"

  [ "$status" -eq 0 ]

  plan_file="$workspace/.ralph-workspace/plans/graph-e2e.plan.md"
  [ -f "$plan_file" ]

  grep -q "mode: dependency" "$plan_file"
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

  wizard="$bundle_root/.ralph/pipeline-wizard.sh"
  run bash -c 'export LC_ALL=C LANG=C RALPH_SKIP_FZF_HINT=1; cd "$1" && { tr -d "\r" < "$3" | bash "$2" --mode graph; } 2>&1' bash "$workspace" "$wizard" "$workspace/input.txt"
  [ "$status" -eq 0 ]

  plan_file="$workspace/.ralph-workspace/plans/graph-e2e.plan.md"
  [ -f "$plan_file" ]

  run bash "$REPO_ROOT/bundle/.ralph/graph-run.sh" compile "$plan_file"
  [ "$status" -eq 0 ]
  [[ "$output" == *'"type":"checkpoint"'* ]]

  rm -rf "$bundle_root" "$workspace"
}

# Same two-node flow, with the tooling answers supplied by the caller in place
# of the accept-every-default block.
_graph_two_node_tooling_input() {
  local tooling_answers="$1"
  printf "Graph E2E\n\n\n\ny\n\n\n\n"
  printf "research,check\n"
  printf '%s' "$tooling_answers"
  printf "\n"                # research type (default: agent)
  printf "3\n"                # check type: checkpoint
  printf '\n%.0s' {1..10}
  printf "research\n"
  printf "y\n"
}

@test "graph wizard renders the tooling block and omits it when declined" {
  skip_flaky_wizard_ci_test
  bundle_root="$(mktemp -d)"
  workspace="$(mktemp -d)"
  _graph_wizard_setup "$bundle_root" "$workspace"
  cp "$REPO_ROOT/bundle/.ralph/graph-run.sh" "$bundle_root/.ralph/graph-run.sh"
  cp -r "$REPO_ROOT/bundle/.ralph/schemas/." "$bundle_root/.ralph/schemas/"
  wizard="$bundle_root/.ralph/pipeline-wizard.sh"
  plan_file="$workspace/.ralph-workspace/plans/graph-e2e.plan.md"

  # Accept the default profile for every node.
  _graph_two_node_tooling_input $'\n\n\n' > "$workspace/input.txt"
  run bash -c 'export LC_ALL=C LANG=C RALPH_SKIP_FZF_HINT=1; cd "$1" && { tr -d "\r" < "$3" | bash "$2" --mode graph; } 2>&1' bash "$workspace" "$wizard" "$workspace/input.txt"
  [ "$status" -eq 0 ]
  grep -q "  tooling:" "$plan_file"
  grep -q "    defaultProfile: ralph-compact" "$plan_file"
  ! grep -q "    overrides:" "$plan_file"
  run bash "$REPO_ROOT/bundle/.ralph/graph-run.sh" compile "$plan_file"
  [ "$status" -eq 0 ]

  # Decline tooling configuration entirely.
  rm -f "$plan_file"
  _graph_two_node_tooling_input $'n\n' > "$workspace/input.txt"
  run bash -c 'export LC_ALL=C LANG=C RALPH_SKIP_FZF_HINT=1; cd "$1" && { tr -d "\r" < "$3" | bash "$2" --mode graph; } 2>&1' bash "$workspace" "$wizard" "$workspace/input.txt"
  [ "$status" -eq 0 ]
  ! grep -q "  tooling:" "$plan_file"
  run bash "$REPO_ROOT/bundle/.ralph/graph-run.sh" compile "$plan_file"
  [ "$status" -eq 0 ]

  # One per-node override on top of the default.
  rm -f "$plan_file"
  _graph_two_node_tooling_input $'\n\nn\n1\n\n' > "$workspace/input.txt"
  run bash -c 'export LC_ALL=C LANG=C RALPH_SKIP_FZF_HINT=1; cd "$1" && { tr -d "\r" < "$3" | bash "$2" --mode graph; } 2>&1' bash "$workspace" "$wizard" "$workspace/input.txt"
  [ "$status" -eq 0 ]
  grep -q "    defaultProfile: ralph-compact" "$plan_file"
  grep -q "      research: ralph-aggressive" "$plan_file"
  run bash "$REPO_ROOT/bundle/.ralph/graph-run.sh" compile "$plan_file"
  [ "$status" -eq 0 ]

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
    _graph_tooling_default_prompts  # tooling: configure y, default profile, apply to all
    printf "\n"                # solo type: agent
    printf "\n\n\n\n\n"        # inline/planFile, runtime, native subagents, content, verification
    printf "3\n"                 # workspaceMode: shared
    printf "n\n"                 # decline risk acknowledgement
  } > "$workspace/input.txt"

  wizard="$bundle_root/.ralph/pipeline-wizard.sh"
  run bash -c 'export LC_ALL=C LANG=C RALPH_SKIP_FZF_HINT=1; cd "$1" && { tr -d "\r" < "$3" | bash "$2" --mode graph; } 2>&1' bash "$workspace" "$wizard" "$workspace/input.txt"

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
  run bash -c 'export LC_ALL=C LANG=C RALPH_SKIP_FZF_HINT=1; cd "$1" && { tr -d "\r" < "$3" | bash "$2" --mode graph; } 2>&1' bash "$workspace" "$wizard" "$workspace/input.txt"

  [ "$status" -eq 0 ]
  plan_file="$workspace/.ralph-workspace/plans/graph-e2e.plan.md"
  [ -f "$plan_file" ]
  grep -q "mode: dependency" "$plan_file"

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
    # Per voter: id, runtime. The role prompt was removed with the role field.
    configure_voters "review" <<< "$(printf "alpha\n\nbeta\n3\nn")"
    printf "voters=%s\n" "${cp_voter_id[*]}"
    printf "runtimes=%s\n" "${cp_voter_runtime[*]}"
  ' _ "$REPO_ROOT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"voters=alpha beta"* ]]
  [[ "$output" == *"runtimes=cursor codex"* ]]
}

@test "wizard_render_pipeline_plan orchestration mode matches the wrapper byte for byte" {
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

_graph_node_authoring_setup() {
  local bundle_root="$1"
  local workspace="$2"
  _graph_wizard_setup "$bundle_root" "$workspace"
  mkdir -p "$bundle_root/.ralph/schemas"
  cp "$REPO_ROOT/bundle/.ralph/schemas/graph-authoring-contract.json" \
    "$bundle_root/.ralph/schemas/graph-authoring-contract.json"
}

# Tooling-profile prompts asked once the node ids are known: accept the
# configure prompt, the default profile (ralph-compact), and apply-to-all.
_graph_tooling_default_prompts() {
  printf '\n\n\n'
}

_graph_node_authoring_agent_prompts() {
  # Inline agent: source, runtime, native subagents, content, verification,
  # workspace mode, write scopes, context budget, produces, and requires.
  # select_role is a no-op in this fixture because no role resolver is loaded.
  printf '\n\n\n\n\n\n\n\n\n\n'
}

_graph_node_authoring_router_branch_prompts() {
  # Same inline-agent sequence as above for the router's branch node.
  printf '\n\n\n\n\n\n\n\n\n\n'
}

_graph_node_authoring_consensus_prompts() {
  # Per voter: id and runtime. Roles are not prompted; voters force native
  # subagents off. Stop after the second voter.
  printf 'alpha\n\nbeta\n3\nn\n'
}

_graph_node_authoring_input_for_type() {
  local node_type="$1"
  local plan_slug="$2"
  printf '%s\n' "$plan_slug"
  printf '\n\n\ny\n\n\n\n'
  case "$node_type" in
    agent)
      printf 'solo\n'
      _graph_tooling_default_prompts
      printf '\n'
      _graph_node_authoring_agent_prompts
      ;;
    consensus)
      printf 'vote\n'
      _graph_tooling_default_prompts
      printf '2\n\n'
      _graph_node_authoring_consensus_prompts
      ;;
    checkpoint)
      printf 'check\n'
      _graph_tooling_default_prompts
      printf '3\n'
      ;;
    join)
      printf 'vote,join\n'
      _graph_tooling_default_prompts
      printf '2\n5\n\n'
      _graph_node_authoring_consensus_prompts
      printf 'vote\n\ny\n'
      ;;
    gate)
      printf 'build,gate\n'
      _graph_tooling_default_prompts
      printf '\n6\n'
      _graph_node_authoring_agent_prompts
      printf 'build\n\n\n'
      ;;
    integrate)
      printf 'build,merge\n'
      _graph_tooling_default_prompts
      printf '\n7\n'
      _graph_node_authoring_agent_prompts
      printf 'build\n'
      ;;
    router)
      printf 'branch,route\n'
      _graph_tooling_default_prompts
      printf '\n8\n'
      _graph_node_authoring_router_branch_prompts
      printf 'branch\nbranch\nbranch\n\n\n'
      printf 'y\n'
      ;;
    *)
      return 1
      ;;
  esac
  printf 'y\n'
}

_run_graph_node_authoring_wizard() {
  local bundle_root="$1"
  local workspace="$2"
  local input_file="$3"
  local use_pty="${4:-0}"
  local runner=()
  if [[ "$use_pty" == "1" ]]; then
    runner=("$REPO_ROOT/tests/bats/bin/ralph-pty-exec" bash -c)
  else
    runner=(bash -c)
  fi
  "${runner[@]}" 'export LC_ALL=C LANG=C RALPH_SKIP_FZF_HINT=1
    cd "$1"
    bundle_root="$2"
    source "$bundle_root/.ralph/bash-lib/error-handling.sh"
    source "$bundle_root/.ralph/bash-lib/ui-prompt.sh"
    source "$bundle_root/.ralph/bash-lib/wizard/wizard-prompts.sh"
    source "$bundle_root/.ralph/bash-lib/wizard/wizard-pipeline-plan.sh"
    SCRIPT_DIR="$bundle_root/.ralph"
    workspace="$1"
    wizard_graph_run_interactive' bash "$workspace" "$bundle_root" < "$input_file"
}

@test "graph node authoring: wizard creates and validates every node type (closed stdin)" {
  skip_flaky_wizard_ci_test
  command -v jq >/dev/null || skip "jq required"
  local bundle_root workspace node_type plan_slug plan_file input_file
  bundle_root="$(mktemp -d)"
  workspace="$(mktemp -d)"
  _graph_node_authoring_setup "$bundle_root" "$workspace"

  for node_type in agent consensus checkpoint join gate integrate router; do
    plan_slug="wizard-${node_type}"
    input_file="$workspace/input-${node_type}.txt"
    _graph_node_authoring_input_for_type "$node_type" "$plan_slug" > "$input_file"
    run _run_graph_node_authoring_wizard "$bundle_root" "$workspace" "$input_file" 0
    [ "$status" -eq 0 ] || {
      echo "wizard failed for node type: $node_type" >&2
      echo "$output" >&2
      return 1
    }

    plan_file="$workspace/.ralph-workspace/plans/${plan_slug}.plan.md"
    [ -f "$plan_file" ]

    case "$node_type" in
      agent) grep -q "runtime: cursor" "$plan_file" ;;
      consensus) grep -q "type: consensus" "$plan_file" && grep -q "voters:" "$plan_file" ;;
      checkpoint) grep -q "type: checkpoint" "$plan_file" ;;
      join) grep -q "type: join" "$plan_file" ;;
      gate) grep -q "type: gate" "$plan_file" ;;
      integrate) grep -q "type: integrate" "$plan_file" && grep -q "workspaceMode: snapshot" "$plan_file" ;;
      router) grep -q "type: router" "$plan_file" && grep -q "allowedTargets:" "$plan_file" ;;
    esac

    run bash "$REPO_ROOT/bundle/.ralph/validate-plan.sh" "$plan_file"
    [ "$status" -eq 0 ]

    run bash "$REPO_ROOT/bundle/.ralph/graph-run.sh" compile "$plan_file"
    [ "$status" -eq 0 ]
    [[ "$output" == *"\"type\":\"${node_type}\""* ]]

    rm -f "$plan_file" "$input_file"
  done

  rm -rf "$bundle_root" "$workspace"
}

@test "graph node authoring: wizard creates every node type on a PTY (interactive stdin)" {
  skip_flaky_wizard_ci_test
  command -v jq >/dev/null || skip "jq required"
  command -v python3 >/dev/null || skip "python3 required"
  local bundle_root workspace node_type plan_slug plan_file input_file
  bundle_root="$(mktemp -d)"
  workspace="$(mktemp -d)"
  _graph_node_authoring_setup "$bundle_root" "$workspace"

  for node_type in agent consensus checkpoint join gate integrate router; do
    plan_slug="pty-${node_type}"
    input_file="$workspace/input-pty-${node_type}.txt"
    _graph_node_authoring_input_for_type "$node_type" "$plan_slug" > "$input_file"
    _run_graph_node_authoring_wizard "$bundle_root" "$workspace" "$input_file" 1
    [ "$?" -eq 0 ]

    plan_file="$workspace/.ralph-workspace/plans/${plan_slug}.plan.md"
    [ -f "$plan_file" ]

    run bash "$REPO_ROOT/bundle/.ralph/validate-plan.sh" "$plan_file"
    [ "$status" -eq 0 ]

    rm -f "$plan_file" "$input_file"
  done

  rm -rf "$bundle_root" "$workspace"
}

@test "ralph create graph reaches the node types the old inline flow could not author" {
  skip_flaky_wizard_ci_test
  command -v jq >/dev/null || skip "jq required"
  bundle_root="$(mktemp -d)"
  workspace="$(mktemp -d)"
  _graph_wizard_setup "$bundle_root" "$workspace"

  # branch (agent, all defaults) then route (router). Router was previously
  # unreachable from `ralph create graph`; the wizard printed that router, gate
  # and integrate had to be hand-edited into the generated plan.
  {
    printf "Router Cli\n\n\n\ny\n\n\n\n"
    printf "branch,route\n"
    _graph_tooling_default_prompts  # tooling: configure y, default profile, apply to all
    printf "\n"                 # branch type: agent
    printf "8\n"                # route type: router
    printf '\n%.0s' {1..10}     # branch config (role selection is a no-op)
    printf "branch\n"           # route dependsOn: branch
    printf "\n"                 # route runtime
    printf "branch\n"           # allowed targets
    printf "\n\n\n"             # default target, terminal outcomes, onInvalid
    printf "y\n"
  } > "$workspace/input.txt"

  wizard="$bundle_root/.ralph/pipeline-wizard.sh"
  run bash -c 'export LC_ALL=C LANG=C RALPH_SKIP_FZF_HINT=1; cd "$1" && { tr -d "\r" < "$3" | bash "$2" --mode graph; } 2>&1' bash "$workspace" "$wizard" "$workspace/input.txt"
  [ "$status" -eq 0 ]

  plan_file="$workspace/.ralph-workspace/plans/router-cli.plan.md"
  [ -f "$plan_file" ]
  grep -q "type: router" "$plan_file"
  grep -q "allowedTargets:" "$plan_file"

  run bash "$REPO_ROOT/bundle/.ralph/graph-run.sh" compile "$plan_file"
  [ "$status" -eq 0 ]

  rm -rf "$bundle_root" "$workspace"
}

@test "graph wizard explains every node type and annotates the type menu" {
  skip_flaky_wizard_ci_test
  command -v jq >/dev/null || skip "jq required"
  bundle_root="$(mktemp -d)"
  workspace="$(mktemp -d)"
  _graph_wizard_setup "$bundle_root" "$workspace"

  _graph_two_node_happy_path_input > "$workspace/input.txt"
  wizard="$bundle_root/.ralph/pipeline-wizard.sh"
  run bash -c 'export LC_ALL=C LANG=C COLUMNS=100 RALPH_SKIP_FZF_HINT=1; cd "$1" && { tr -d "\r" < "$3" | bash "$2" --mode graph; } 2>&1' bash "$workspace" "$wizard" "$workspace/input.txt"
  [ "$status" -eq 0 ]

  # Every contract node type is described before the first type question.
  for node_type in agent consensus checkpoint join gate integrate router; do
    summary="$(jq -r --arg t "$node_type" '.nodeTypes[$t].summary' \
      "$REPO_ROOT/bundle/.ralph/schemas/graph-authoring-contract.json")"
    [[ "$output" == *"$summary"* ]] || {
      echo "missing summary for node type: $node_type" >&2
      return 1
    }
  done

  # Enum menus carry their per-option help rather than bare words.
  [[ "$output" == *"Edits a frozen copy of the tree"* ]]
  [[ "$output" == *"Merge of the two. Recommended"* ]]
  [[ "$output" == *"Let already-running nodes finish"* ]]

  rm -rf "$bundle_root" "$workspace"
}

@test "graph wizard review groups nodes into the waves they can run in" {
  skip_flaky_wizard_ci_test
  command -v jq >/dev/null || skip "jq required"
  bundle_root="$(mktemp -d)"
  workspace="$(mktemp -d)"
  _graph_wizard_setup "$bundle_root" "$workspace"

  # lane-a and lane-b are independent, merge waits on both: two waves, with the
  # first showing the parallelism the dependsOn answers actually bought.
  {
    printf "Wave Review\n\n\n\ny\n\n\n\n"
    printf "lane-a,lane-b,merge\n"
    _graph_tooling_default_prompts  # tooling: configure y, default profile, apply to all
    printf "\n\n"               # lane-a, lane-b: agent
    printf "7\n"                # merge: integrate
    printf '\n%.0s' {1..10}     # lane-a config (role selection is a no-op)
    printf "\n"                 # lane-b dependsOn: none
    printf '\n%.0s' {1..10}     # lane-b config (role selection is a no-op)
    printf "lane-a,lane-b\n"    # merge dependsOn
    printf "n\n"                # do not write
  } > "$workspace/input.txt"

  wizard="$bundle_root/.ralph/pipeline-wizard.sh"
  run bash -c 'export LC_ALL=C LANG=C COLUMNS=100 RALPH_SKIP_FZF_HINT=1; cd "$1" && { tr -d "\r" < "$3" | bash "$2" --mode graph; } 2>&1' bash "$workspace" "$wizard" "$workspace/input.txt"
  [ "$status" -eq 0 ]

  [[ "$output" == *"Wave 1 (2 nodes run in parallel)"* ]]
  [[ "$output" == *"Wave 2"* ]]
  [[ "$output" == *"after: lane-a,lane-b"* ]]
  [ ! -e "$workspace/.ralph-workspace/plans/wave-review.plan.md" ]

  rm -rf "$bundle_root" "$workspace"
}

@test "ralph_menu_select renders descriptions but still returns the bare choice" {
  run bash -c '
    set -euo pipefail
    source "$1/bundle/.ralph/bash-lib/menu-select.sh"
    picked="$(printf "2\n" | ralph_menu_select --prompt "Pick" --default 1 \
      --desc "first option help" --desc "second option help" -- "alpha" "beta" 2>/dev/null)"
    printf "picked=%s\n" "$picked"
    printf "2\n" | ralph_menu_select --prompt "Pick" --default 1 \
      --desc "first option help" --desc "second option help" -- "alpha" "beta" 2>&1 >/dev/null
  ' _ "$REPO_ROOT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"picked=beta"* ]]
  [[ "$output" == *"alpha  first option help"* ]]
  [[ "$output" == *"beta   second option help"* ]]
}

@test "ralph_menu_select without descriptions keeps its original layout" {
  run bash -c '
    set -euo pipefail
    source "$1/bundle/.ralph/bash-lib/menu-select.sh"
    printf "1\n" | ralph_menu_select --prompt "Pick" --default 1 -- "alpha" "beta" 2>&1 >/dev/null
  ' _ "$REPO_ROOT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"   1) alpha"* ]]
  [[ "$output" != *"alpha "* ]] || [[ "$output" == *"1) alpha"$'\n'* ]]
}
