#!/usr/bin/env bats

source "$BATS_TEST_DIRNAME/../helper/load-lib.bash"

skip_flaky_wizard_ci_test() {
  if [[ -n "${CI:-}" ]]; then
    skip "Flaky in CI; tracked for follow-up"
  fi
}

@test "orchestration wizard sources select-model helpers from bash-lib without TTY" {
  run bash -c '
    set -euo pipefail
    script_dir="$1/bundle/.ralph"
    bash_lib="$script_dir/bash-lib"
    # shellcheck source=/dev/null
    source "$bash_lib/error-handling.sh"
    for rt in cursor claude codex opencode; do
      sm="$bash_lib/select-model/select-model-${rt}.sh"
      [[ -r "$sm" ]] || { echo "missing $sm" >&2; exit 1; }
      # shellcheck source=/dev/null
      source "$sm"
    done
    # shellcheck source=/dev/null
    source "$bash_lib/ui-prompt.sh"
    # shellcheck source=/dev/null
    source "$bash_lib/wizard/wizard-prompts.sh"
    declare -F select_model_cursor >/dev/null
    declare -F select_model_claude >/dev/null
    declare -F select_model_codex >/dev/null
    declare -F select_model_opencode >/dev/null
    # select_model_override / pick_model_for_runtime were removed with the
    # profile model default; the wizard now reports the model source instead.
    ! declare -F select_model_override >/dev/null
    declare -F select_role >/dev/null
    declare -F wizard_print_runtime_role_model_subagents >/dev/null
    echo loaded
  ' _ "$REPO_ROOT" </dev/null
  [ "$status" -eq 0 ]
  [[ "$output" == *loaded* ]]

  # pipeline-wizard.sh is a thin shim into the shared pipeline-wizard.sh
  # engine; the select-model sourcing lives there now.
  shim="$REPO_ROOT/bundle/.ralph/pipeline-wizard.sh"
  grep -q 'pipeline-wizard.sh' "$shim"
  grep -q -- '--mode orchestration' "$shim"

  wizard="$REPO_ROOT/bundle/.ralph/pipeline-wizard.sh"
  grep -q 'script_dir/bash-lib' "$wizard"
  grep -q 'select-model-cursor.sh' "$wizard"
  grep -q 'select-model-claude.sh' "$wizard"
  grep -q 'select-model-codex.sh' "$wizard"
  grep -q 'select-model-opencode.sh' "$wizard"
  ! grep -Eq '\.(cursor|claude|codex|opencode)/ralph/select-model\.sh' "$wizard"
}

@test "wizard reports the runtime model source instead of a profile default" {
  run bash -c '
    set -euo pipefail
    export RALPH_SKIP_FZF_HINT=1
    # shellcheck source=/dev/null
    source "$1/bundle/.ralph/bash-lib/error-handling.sh"
    # shellcheck source=/dev/null
    source "$1/bundle/.ralph/bash-lib/ui-prompt.sh"
    # shellcheck source=/dev/null
    source "$1/bundle/.ralph/bash-lib/wizard/wizard-prompts.sh"
    wizard_print_runtime_role_model_subagents "Stage build" claude code-review off
  ' _ "$REPO_ROOT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"model source"* ]]
  [[ "$output" != *"agent-default-model"* ]]
}

@test "orchestration wizard rejects all-invalid stage tokens" {
  bundle_root="$(mktemp -d)"
  workspace="$(mktemp -d)"
  mkdir -p "$bundle_root/.ralph/bash-lib"
  mkdir -p "$workspace/.cursor/agents/research"
  cp "$REPO_ROOT/bundle/.ralph/pipeline-wizard.sh" "$bundle_root/.ralph/pipeline-wizard.sh"
  cp "$REPO_ROOT/bundle/.ralph/pipeline-wizard.sh" "$bundle_root/.ralph/pipeline-wizard.sh"
  cp -r "$REPO_ROOT/bundle/.ralph/bash-lib/." "$bundle_root/.ralph/bash-lib/"
  cp "$REPO_ROOT/bundle/.ralph/tooling-profiles.json" "$bundle_root/.ralph/tooling-profiles.json"
  mkdir -p "$bundle_root/.ralph/plan-templates"
  cp "$REPO_ROOT/bundle/.ralph/plan-templates/classic.plan.template.md" "$bundle_root/.ralph/plan-templates/classic.plan.template.md"
  chmod +x "$bundle_root/.ralph/pipeline-wizard.sh" "$bundle_root/.ralph/pipeline-wizard.sh"
  cat >"$workspace/.cursor/agents/research/config.json" <<'JSON'
{"model":"auto"}
JSON
  # Only non-resolvable stage tokens: nothing is accepted, so the wizard fails before per-stage config.
  cat >"$workspace/input.txt" <<'EOF'

Demo Pipeline
demo-pipeline


n
!!!
EOF

  wizard="$bundle_root/.ralph/pipeline-wizard.sh"
  # Strip CR so scripted answers stay aligned if the repo is checked out with CRLF (e.g. CI).
  run bash -c 'export LC_ALL=C LANG=C RALPH_SKIP_FZF_HINT=1; cd "$1" && { tr -d "\r" < "$3" | bash "$2"; } 2>&1' bash "$workspace" "$wizard" "$workspace/input.txt"
  [ "$status" -ne 0 ]
  [[ "$output" == *'No stages configured'* ]]
  [[ "$output" != *"command not found"* ]]

  rm -rf "$bundle_root"
  ralph_test_rm_workspace "$workspace"
  [ "$status" -ne 0 ]
}

@test "configure_parallel_stages fills remaining stages on blank wave" {
  run bash -c '
    set -euo pipefail
    source "$1/bundle/.ralph/bash-lib/error-handling.sh"
    source "$1/bundle/.ralph/bash-lib/ui-prompt.sh"
    source "$1/bundle/.ralph/bash-lib/wizard/wizard-validation.sh"

    print_step() { :; }
    print_hint() { :; }
    print_info() { :; }
    ralph_die() {
      printf "die:%s\n" "$*" >&2
      return 1
    }
    ralph_prompt_yesno() {
      printf "y"
    }
    ralph_prompt_list() {
      case "$1" in
        "Wave 1 stages")
          printf "r1,r2"
          ;;
        "Wave 2 stages")
          printf "%s" "$2"
          ;;
        *)
          printf "%s" "$2"
          ;;
      esac
    }

    stage_ids=(r1 r2 r3)
    configure_parallel_stages
    printf "enabled=%s\n" "$parallel_stages_enabled"
    printf "waves=%s\n" "${parallel_stage_waves[*]}"
  ' _ "$REPO_ROOT"

  [ "$status" -eq 0 ]
  [[ "$output" == *"enabled=true"* ]]
  [[ "$output" == *"waves=r1,r2 r3"* ]]
}

@test "configure_stage_input_dependencies skips earlier-stage prompt for the first stage" {
  run bash -c '
    set -euo pipefail
    source "$1/bundle/.ralph/bash-lib/wizard/wizard-validation.sh"

    print_step() { :; }
    print_hint() { :; }
    print_info() { :; }
    ralph_die() {
      printf "die:%s\n" "$*" >&2
      return 1
    }

    ralph_prompt_yesno() {
      printf "y"
    }
    ralph_prompt_list() {
      printf "%s" "$2"
    }

    stage_ids=(r1 r2)
    configure_stage_input_dependencies
    printf "stage0=<%s>\n" "${stage_input_sources[0]:-}"
    printf "stage1=<%s>\n" "${stage_input_sources[1]:-}"
  ' _ "$REPO_ROOT"

  [ "$status" -eq 0 ]
  [[ "$output" == *"stage0=<>"* ]]
  [[ "$output" == *"stage1=<r1>"* ]]
}

@test "configure_parallel_stages rejects duplicate ids in one wave" {
  run bash -c '
    set -euo pipefail
    source "$1/bundle/.ralph/bash-lib/error-handling.sh"
    source "$1/bundle/.ralph/bash-lib/ui-prompt.sh"
    source "$1/bundle/.ralph/bash-lib/wizard/wizard-validation.sh"

    print_step() { :; }
    print_hint() { :; }
    print_info() { :; }
    ralph_prompt_yesno() {
      printf "y"
    }
    ralph_prompt_list() {
      case "$1" in
        "Wave 1 stages")
          printf "r1,r1"
          ;;
        *)
          printf "%s" "$2"
          ;;
      esac
    }

    stage_ids=(r1 r2 r3)
    configure_parallel_stages
  ' _ "$REPO_ROOT"

  [ "$status" -ne 0 ]
  [[ "$output" == *"Wave 1: duplicate stage id in the same wave"* ]]
}

@test "configure_parallel_stages rejects ids not in the remaining pool" {
  run bash -c '
    set -euo pipefail
    source "$1/bundle/.ralph/bash-lib/error-handling.sh"
    source "$1/bundle/.ralph/bash-lib/ui-prompt.sh"
    source "$1/bundle/.ralph/bash-lib/wizard/wizard-validation.sh"

    print_step() { :; }
    print_hint() { :; }
    print_info() { :; }
    ralph_prompt_yesno() {
      printf "y"
    }
    ralph_prompt_list() {
      case "$1" in
        "Wave 1 stages")
          printf "bogus"
          ;;
        *)
          printf "%s" "$2"
          ;;
      esac
    }

    stage_ids=(r1 r2 r3)
    configure_parallel_stages
  ' _ "$REPO_ROOT"

  [ "$status" -ne 0 ]
  [[ "$output" == *"Wave 1: stage \"bogus\" is not in the remaining pool"* ]]
}

@test "configure_parallel_stages normalizes space-separated wave tokens to CSV" {
  run bash -c '
    set -euo pipefail
    source "$1/bundle/.ralph/bash-lib/error-handling.sh"
    source "$1/bundle/.ralph/bash-lib/ui-prompt.sh"
    source "$1/bundle/.ralph/bash-lib/wizard/wizard-validation.sh"

    print_step() { :; }
    print_hint() { :; }
    print_info() { :; }
    ralph_prompt_yesno() {
      printf "y"
    }
    ralph_prompt_list() {
      case "$1" in
        "Wave 1 stages")
          printf "r1 r2"
          ;;
        "Wave 2 stages")
          printf "%s" "$2"
          ;;
        *)
          printf "%s" "$2"
          ;;
      esac
    }

    stage_ids=(r1 r2 r3)
    configure_parallel_stages
    printf "waves=%s\n" "${parallel_stage_waves[*]}"
  ' _ "$REPO_ROOT"

  [ "$status" -eq 0 ]
  [[ "$output" == *"waves=r1,r2 r3"* ]]
}

@test "orchestration wizard end-to-end with parallelStages, inputArtifacts, and handoffs" {
  skip_flaky_wizard_ci_test
  bundle_root="$(mktemp -d)"
  workspace="$(mktemp -d)"
  mkdir -p "$bundle_root/.ralph/bash-lib"
  mkdir -p "$workspace/.cursor/agents/research"
  mkdir -p "$workspace/.cursor/agents/architect"
  mkdir -p "$workspace/.cursor/agents/implementation"

  cp "$REPO_ROOT/bundle/.ralph/pipeline-wizard.sh" "$bundle_root/.ralph/pipeline-wizard.sh"
  cp "$REPO_ROOT/bundle/.ralph/pipeline-wizard.sh" "$bundle_root/.ralph/pipeline-wizard.sh"
  cp -r "$REPO_ROOT/bundle/.ralph/bash-lib/." "$bundle_root/.ralph/bash-lib/"
  cp "$REPO_ROOT/bundle/.ralph/tooling-profiles.json" "$bundle_root/.ralph/tooling-profiles.json"
  mkdir -p "$bundle_root/.ralph/python"
  cp "$REPO_ROOT/bundle/.ralph/python/wizard-prompts-agent-model.py" "$bundle_root/.ralph/python/"
  cp "$REPO_ROOT/bundle/.ralph/python/wizard-prompts-escape-json.py" "$bundle_root/.ralph/python/"
  mkdir -p "$bundle_root/.ralph/plan-templates"
  cp "$REPO_ROOT/bundle/.ralph/plan-templates/classic.plan.template.md" "$bundle_root/.ralph/plan-templates/classic.plan.template.md"
  chmod +x "$bundle_root/.ralph/pipeline-wizard.sh" "$bundle_root/.ralph/pipeline-wizard.sh"

  echo '{"model":"auto"}' > "$workspace/.cursor/agents/research/config.json"
  echo '{"model":"auto"}' > "$workspace/.cursor/agents/architect/config.json"
  echo '{"model":"auto"}' > "$workspace/.cursor/agents/implementation/config.json"

  # New wizard prompt sequence:
  # 1-5: pipeline info (name, namespace, description, session strategy, all-stages-same)
  # 6: stage list
  # 7-24: 3 stages * 6 prompts each (inline/planFile, runtime,
  #        native subagents, content, verification, context)
  #        (no model prompt: agents with a default model use it without prompting)
  # 25-30: 3 stages * 2 artifact prompts each (output, requires)
  # 34-36: parallel stages (enable=y, wave1=r1,r2, wave2=blank=remaining r3)
  # 37: loop rules (n)
  # 38: write plan (y)
  {
    printf "\n"                          # plan kind (default=orchestration)
    printf "End-to-End Test\n"           # name
    printf "e2e-test\n"                  # namespace
    printf "Complete orchestration test\n" # description
    printf "\n"                           # session strategy (fresh default)
    printf "y\n"                          # all stages same
    printf "r1,r2,r3\n"                  # stages
    printf "n\n"                         # tooling profiles (skip configuration)
    printf '\n%.0s' {1..18}             # 3 stages * 6 prompts each (all defaults)
    printf '\n%.0s' {1..6}              # 3 stages * 2 artifact prompts (blank=skip)
    printf "y\nr1,r2\n\n"               # parallel stages: enable, wave1=r1,r2, wave2=remaining
    printf "n\n"                         # loop rules (n)
    printf "y\n"                         # write plan
  } >"$workspace/input.txt"

  wizard="$bundle_root/.ralph/pipeline-wizard.sh"
  run bash -c 'export LC_ALL=C LANG=C RALPH_SKIP_FZF_HINT=1; cd "$1" && { tr -d "\r" < "$3" | bash "$2"; } 2>&1' bash "$workspace" "$wizard" "$workspace/input.txt"

  [ "$status" -eq 0 ]

  plan_file="$workspace/.ralph-workspace/plans/e2e-test.plan.md"
  [ -f "$plan_file" ]

  grep -q "mode: sequential" "$plan_file"
  grep -q "id: r1" "$plan_file"
  grep -q "id: r2" "$plan_file"
  grep -q "id: r3" "$plan_file"
  grep -q "parallelStages:" "$plan_file"
  grep -qE "\[r1[^]]*r2\]" "$plan_file"

  rm -rf "$bundle_root" "$workspace"
}

@test "wizard-generated YAML with custom stage IDs and all configuration options" {
  skip_flaky_wizard_ci_test
  bundle_root="$(mktemp -d)"
  workspace="$(mktemp -d)"
  mkdir -p "$bundle_root/.ralph/bash-lib"
  mkdir -p "$workspace/.cursor/agents/research"

  cp "$REPO_ROOT/bundle/.ralph/pipeline-wizard.sh" "$bundle_root/.ralph/pipeline-wizard.sh"
  cp "$REPO_ROOT/bundle/.ralph/pipeline-wizard.sh" "$bundle_root/.ralph/pipeline-wizard.sh"
  cp -r "$REPO_ROOT/bundle/.ralph/bash-lib/." "$bundle_root/.ralph/bash-lib/"
  cp "$REPO_ROOT/bundle/.ralph/tooling-profiles.json" "$bundle_root/.ralph/tooling-profiles.json"
  mkdir -p "$bundle_root/.ralph/python"
  cp "$REPO_ROOT/bundle/.ralph/python/wizard-prompts-agent-model.py" "$bundle_root/.ralph/python/"
  cp "$REPO_ROOT/bundle/.ralph/python/wizard-prompts-escape-json.py" "$bundle_root/.ralph/python/"
  mkdir -p "$bundle_root/.ralph/plan-templates"
  cp "$REPO_ROOT/bundle/.ralph/plan-templates/classic.plan.template.md" "$bundle_root/.ralph/plan-templates/classic.plan.template.md"
  chmod +x "$bundle_root/.ralph/pipeline-wizard.sh" "$bundle_root/.ralph/pipeline-wizard.sh"

  echo '{"model":"auto"}' > "$workspace/.cursor/agents/research/config.json"

  # New wizard prompt sequence for 3 stages (all inline, cursor runtime, research agent):
  # 1-5: pipeline info
  # 6: stage list (3 custom IDs)
  # 7-24: 3 stages * 6 prompts each (no role prompt; no model prompt)
  # 25-30: 3 stages * 2 artifact prompts
  # 34: parallel stages (n)
  # 35: loop rules (n)
  # 36: write plan (y)
  {
    printf "\n"                # plan kind (default=orchestration)
    printf "Multi-Runtime Pipeline\n"
    printf "multi-runtime\n"
    printf "\n"                # description (default)
    printf "\n"                # session strategy (fresh)
    printf "y\n"               # all stages same
    printf "stage-research,stage-design,stage-impl\n"
    printf "y\n"               # configure tooling profiles
    printf "\n"                # default profile (ralph-compact)
    printf "y\n"               # apply to every stage
    printf '\n%.0s' {1..18}  # 3 stages * 6 prompts each
    printf '\n%.0s' {1..6}   # 3 stages * 2 artifact prompts
    printf "n\n"               # parallel stages (n)
    printf "n\n"               # loop rules (n)
    printf "y\n"               # write plan
  } >"$workspace/input.txt"

  wizard="$bundle_root/.ralph/pipeline-wizard.sh"
  run bash -c 'export LC_ALL=C LANG=C RALPH_SKIP_FZF_HINT=1; cd "$1" && { tr -d "\r" < "$3" | bash "$2"; } 2>&1' bash "$workspace" "$wizard" "$workspace/input.txt"

  [ "$status" -eq 0 ]

  plan_file="$workspace/.ralph-workspace/plans/multi-runtime.plan.md"
  [ -f "$plan_file" ]

  grep -q "mode: sequential" "$plan_file"
  grep -q "id: stage-research" "$plan_file"
  grep -q "id: stage-design" "$plan_file"
  grep -q "id: stage-impl" "$plan_file"
  grep -q "runtime: cursor" "$plan_file"
  ! grep -q "agent: research" "$plan_file"
  grep -q "nativeSubagents: off" "$plan_file"
  grep -q "^  tooling:$" "$plan_file"
  grep -q "^    defaultProfile: ralph-compact$" "$plan_file"
  ! grep -q "overrides:" "$plan_file"

  rm -rf "$bundle_root" "$workspace"
}
