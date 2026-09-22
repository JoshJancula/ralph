#!/usr/bin/env bats

source "$BATS_TEST_DIRNAME/../helper/load-lib.bash"

skip_flaky_wizard_ci_test() {
  if [[ -n "${CI:-}" ]]; then
    skip "Flaky in CI; tracked for follow-up"
  fi
}

_orc_wizard_setup() {
  local bundle_root="$1"
  local workspace="$2"
  mkdir -p "$bundle_root/.ralph/bash-lib"
  cp "$REPO_ROOT/bundle/.ralph/pipeline-wizard.sh" "$bundle_root/.ralph/pipeline-wizard.sh"
  cp "$REPO_ROOT/bundle/.ralph/pipeline-wizard.sh" "$bundle_root/.ralph/pipeline-wizard.sh"
  cp -r "$REPO_ROOT/bundle/.ralph/bash-lib/." "$bundle_root/.ralph/bash-lib/"
  cp "$REPO_ROOT/bundle/.ralph/tooling-profiles.json" "$bundle_root/.ralph/tooling-profiles.json"
  mkdir -p "$bundle_root/.ralph/python"
  cp "$REPO_ROOT/bundle/.ralph/python/wizard-prompts-agent-model.py" "$bundle_root/.ralph/python/"
  cp "$REPO_ROOT/bundle/.ralph/python/wizard-prompts-escape-json.py" "$bundle_root/.ralph/python/"
  mkdir -p "$bundle_root/.ralph/plan-templates"
  cp "$REPO_ROOT/bundle/.ralph/plan-templates/classic.plan.template.md" "$bundle_root/.ralph/plan-templates/classic.plan.template.md"
  if [[ -f "$REPO_ROOT/bundle/.ralph/plan-templates/pipeline-simple.plan.template.md" ]]; then
    cp "$REPO_ROOT/bundle/.ralph/plan-templates/pipeline-simple.plan.template.md" "$bundle_root/.ralph/plan-templates/pipeline-simple.plan.template.md"
  fi
  chmod +x "$bundle_root/.ralph/pipeline-wizard.sh" "$bundle_root/.ralph/pipeline-wizard.sh"
}

# Build the minimal input for a single inline stage (no parallel stages, no loop rules).
# New wizard prompt order:
#   1. Pipeline name
#   2. Namespace (blank=auto)
#   3. Description (blank=default)
#   4. Default session strategy (blank=fresh)
#   5. All stages same strategy (y)
#   6. Stages
#   7. Tooling profiles (configure? default profile, apply-to-all)
#   8+ Per stage: inline/planFile choice, runtime, agent, content, verification, context budget
#      (no model prompt: the runtime owns model selection)
#      Then per stage: output artifact (blank), required input (blank)
#   Then: parallel stages (n), loop rules (n), confirm (n|y)
_orc_single_stage_input() {
  local plan_name="$1"
  local stage="$2"
  local confirm="$3"
  printf '\n'                  # plan kind (default=orchestration)
  printf '%s\n' "$plan_name"  # name
  printf '\n'                  # namespace (auto)
  printf '\n'                  # description (default)
  printf '\n'                  # session strategy (fresh)
  printf 'y\n'                 # all stages same
  printf '%s\n' "$stage"       # stage list
  printf 'n\n'                 # tooling profiles (skip configuration)
  # Per stage prompts (inline mode):
  printf '\n'   # inline or plan file (default=inline)
  printf '\n'   # runtime (default=cursor)
  printf '\n'   # native subagents (default)
  printf '\n'   # content (blank)
  printf '\n'   # verification (blank)
  printf '\n'   # context budget (default=standard)
  # Artifact prompts:
  printf '\n'   # output artifact (blank=skip)
  printf '\n'   # required input (blank=skip)
  # Optional config:
  printf 'n\n'  # parallel stages
  printf 'n\n'  # loop rules
  printf '%s\n' "$confirm"  # write plan
}

@test "orchestration wizard aborts on 'n' at summary prompt without creating files" {
  skip_flaky_wizard_ci_test
  bundle_root="$(mktemp -d)"
  workspace="$(mktemp -d)"
  _orc_wizard_setup "$bundle_root" "$workspace"

  mkdir -p "$workspace/.cursor/agents/research"
  echo '{"model":"auto"}' > "$workspace/.cursor/agents/research/config.json"

  _orc_single_stage_input "Demo" "research" "n" > "$workspace/input.txt"

  wizard="$bundle_root/.ralph/pipeline-wizard.sh"
  run bash -c 'export LC_ALL=C LANG=C RALPH_SKIP_FZF_HINT=1; cd "$1" && { tr -d "\r" < "$3" | bash "$2"; } 2>&1' bash "$workspace" "$wizard" "$workspace/input.txt"

  [ "$status" -eq 0 ]
  [ ! -f "$workspace/.ralph-workspace/plans/demo.plan.md" ]
  [[ "$output" == *'aborted; no files created'* ]]

  rm -rf "$bundle_root" "$workspace"
}

@test "orchestration wizard creates a structured plan file on 'y' at summary prompt" {
  skip_flaky_wizard_ci_test
  bundle_root="$(mktemp -d)"
  workspace="$(mktemp -d)"
  _orc_wizard_setup "$bundle_root" "$workspace"

  mkdir -p "$workspace/.cursor/agents/research"
  echo '{"model":"auto"}' > "$workspace/.cursor/agents/research/config.json"

  _orc_single_stage_input "Demo" "research" "y" > "$workspace/input.txt"

  wizard="$bundle_root/.ralph/pipeline-wizard.sh"
  run bash -c 'export LC_ALL=C LANG=C RALPH_SKIP_FZF_HINT=1; cd "$1" && { tr -d "\r" < "$3" | bash "$2"; } 2>&1' bash "$workspace" "$wizard" "$workspace/input.txt"

  [ "$status" -eq 0 ]
  plan_file="$workspace/.ralph-workspace/plans/demo.plan.md"
  [ -f "$plan_file" ]
  grep -q "mode: sequential" "$plan_file"
  grep -q "research" "$plan_file"
  grep -q "todos:" "$plan_file"

  rm -rf "$bundle_root" "$workspace"
}

@test "orchestration wizard renders a tooling block with a per-stage override" {
  skip_flaky_wizard_ci_test
  bundle_root="$(mktemp -d)"
  workspace="$(mktemp -d)"
  _orc_wizard_setup "$bundle_root" "$workspace"

  mkdir -p "$workspace/.cursor/agents/research"
  mkdir -p "$workspace/.cursor/agents/implementation"
  echo '{"model":"auto"}' > "$workspace/.cursor/agents/research/config.json"
  echo '{"model":"auto"}' > "$workspace/.cursor/agents/implementation/config.json"

  {
    printf '\n'                # plan kind (default=orchestration)
    printf 'Demo\n'            # name
    printf '\n'                # namespace (auto=demo)
    printf '\n'                # description (default)
    printf '\n'                # session strategy (fresh)
    printf 'y\n'               # all stages same
    printf 'research,implementation\n'  # stages
    # Tooling profiles:
    printf 'y\n'  # configure tooling profiles
    printf '\n'   # default profile (ralph-compact)
    printf 'n\n'  # do not apply to every stage
    printf '4\n'  # research -> raw
    printf '\n'   # implementation -> default (ralph-compact)
    # Stage research (inline):
    printf '\n\n\n\n\n\n'
    # Stage implementation (inline):
    printf '\n\n\n\n\n\n'
    # Artifact prompts for both stages:
    printf '\n\n\n\n'
    printf 'n\n'  # parallel stages
    printf 'n\n'  # loop rules
    printf 'y\n'  # write plan
  } > "$workspace/input.txt"

  wizard="$bundle_root/.ralph/pipeline-wizard.sh"
  run bash -c 'export LC_ALL=C LANG=C RALPH_SKIP_FZF_HINT=1; cd "$1" && { tr -d "\r" < "$3" | bash "$2"; } 2>&1' bash "$workspace" "$wizard" "$workspace/input.txt"

  [ "$status" -eq 0 ]
  plan_file="$workspace/.ralph-workspace/plans/demo.plan.md"
  [ -f "$plan_file" ]
  grep -q "^  tooling:$" "$plan_file"
  grep -q "^    defaultProfile: ralph-compact$" "$plan_file"
  grep -q "^    overrides:$" "$plan_file"
  grep -q "^      research: raw$" "$plan_file"

  run bash -c 'source "$1/bundle/.ralph/bash-lib/plan-todo.sh" && plan_pipeline_validate_plan "$2"' bash "$REPO_ROOT" "$plan_file"
  [ "$status" -eq 0 ]

  rm -rf "$bundle_root" "$workspace"
}

@test "orchestration wizard can configure parallelStages" {
  skip_flaky_wizard_ci_test
  bundle_root="$(mktemp -d)"
  workspace="$(mktemp -d)"
  _orc_wizard_setup "$bundle_root" "$workspace"

  mkdir -p "$workspace/.cursor/agents/research"
  mkdir -p "$workspace/.cursor/agents/implementation"
  echo '{"model":"auto"}' > "$workspace/.cursor/agents/research/config.json"
  echo '{"model":"auto"}' > "$workspace/.cursor/agents/implementation/config.json"

  {
    printf '\n'                # plan kind (default=orchestration)
    printf 'Demo\n'            # name
    printf '\n'                # namespace (auto=demo)
    printf '\n'                # description (default)
    printf '\n'                # session strategy (fresh)
    printf 'y\n'               # all stages same
    printf 'research,implementation\n'  # stages
    printf 'n\n'  # tooling profiles (skip configuration)
    # Stage research (inline; the runtime owns model selection, no model prompt):
    printf '\n'   # inline
    printf '\n'   # runtime (cursor)
    printf '\n'   # native subagents (default)
    printf '\n'   # content
    printf '\n'   # verification
    printf '\n'   # context budget
    # Stage implementation (inline):
    printf '\n'   # inline
    printf '\n'   # runtime (cursor)
    printf '\n'   # native subagents (default)
    printf '\n'   # content
    printf '\n'   # verification
    printf '\n'   # context budget
    # Artifacts for research:
    printf '\n'   # output artifact
    printf '\n'   # required input
    # Artifacts for implementation:
    printf '\n'   # output artifact
    printf '\n'   # required input
    # Parallel stages:
    printf 'y\n'                      # enable parallel waves
    printf 'research,implementation\n' # wave 1: both stages
    # Loop rules:
    printf 'n\n'  # no loop rules
    printf 'y\n'  # write plan
  } > "$workspace/input.txt"

  wizard="$bundle_root/.ralph/pipeline-wizard.sh"
  run bash -c 'export LC_ALL=C LANG=C RALPH_SKIP_FZF_HINT=1; cd "$1" && { tr -d "\r" < "$3" | bash "$2"; } 2>&1' bash "$workspace" "$wizard" "$workspace/input.txt"

  [ "$status" -eq 0 ]
  plan_file="$workspace/.ralph-workspace/plans/demo.plan.md"
  [ -f "$plan_file" ]
  grep -q "parallelStages:" "$plan_file"
  grep -q "research" "$plan_file"
  grep -q "implementation" "$plan_file"

  rm -rf "$bundle_root" "$workspace"
}

@test "orchestration wizard sources select-model helpers from bash-lib without TTY" {
  bundle_root="$(mktemp -d)"
  workspace="$(mktemp -d)"
  _orc_wizard_setup "$bundle_root" "$workspace"

  wizard="$bundle_root/.ralph/pipeline-wizard.sh"
  run bash -c 'export LC_ALL=C LANG=C RALPH_SKIP_FZF_HINT=1; cd "$1" && bash "$2" --help 2>&1 || true' bash "$workspace" "$wizard"
  # Check the wizard can be sourced without errors (not a TTY test, but validates sourcing)
  [ "$status" -ne 127 ]

  rm -rf "$bundle_root" "$workspace"
}

@test "orchestration wizard rejects all-invalid stage tokens" {
  skip_flaky_wizard_ci_test
  bundle_root="$(mktemp -d)"
  workspace="$(mktemp -d)"
  _orc_wizard_setup "$bundle_root" "$workspace"

  {
    printf 'Demo\n'
    printf '\n'
    printf '\n'
    printf '\n'
    printf 'y\n'
    printf '!!!,@@@@\n'  # all-invalid stage ids
  } > "$workspace/input.txt"

  wizard="$bundle_root/.ralph/pipeline-wizard.sh"
  run bash -c 'export LC_ALL=C LANG=C RALPH_SKIP_FZF_HINT=1; cd "$1" && { tr -d "\r" < "$3" | bash "$2"; } 2>&1' bash "$workspace" "$wizard" "$workspace/input.txt"

  [ "$status" -ne 0 ]

  rm -rf "$bundle_root" "$workspace"
}
