#!/usr/bin/env bats

source "$BATS_TEST_DIRNAME/helper/load-lib.bash"

@test "orchestration wizard runs its sanitize helper path end to end" {
  bundle_root="$(mktemp -d)"
  workspace="$(mktemp -d)"
  mkdir -p "$bundle_root/.ralph/bash-lib"
  mkdir -p "$workspace/.cursor/agents/research"
  cp "$REPO_ROOT/bundle/.ralph/orchestration-wizard.sh" "$bundle_root/.ralph/orchestration-wizard.sh"
  cp "$REPO_ROOT/bundle/.ralph/bash-lib/"*.sh "$bundle_root/.ralph/bash-lib/"
  cp "$REPO_ROOT/bundle/.ralph/plan.template" "$bundle_root/.ralph/plan.template"
  chmod +x "$bundle_root/.ralph/orchestration-wizard.sh"
  cat >"$workspace/.cursor/agents/research/config.json" <<'JSON'
{"model":"auto"}
JSON
  cat >"$workspace/input.txt" <<'EOF'
Demo Pipeline
demo-pipeline


n
!!!
EOF

  wizard="$bundle_root/.ralph/orchestration-wizard.sh"
  # Strip CR so scripted answers stay aligned if the repo is checked out with CRLF (e.g. CI).
  run bash -c 'export LC_ALL=C LANG=C; cd "$1" && tr -d "\r" < "$3" | bash "$2"' bash "$workspace" "$wizard" "$workspace/input.txt"
  [ "$status" -ne 0 ]
  [[ "$output" == *'sanitizes to empty; skip'* ]]
  [[ "$output" != *"command not found"* ]]

  rm -rf "$bundle_root"
  rm -rf "$workspace"
  [ "$status" -ne 0 ]
}

@test "configure_parallel_stages fills remaining stages on blank wave" {
  run bash -c '
    set -euo pipefail
    source "$1/bundle/.ralph/bash-lib/error-handling.sh"
    source "$1/bundle/.ralph/bash-lib/ui-prompt.sh"
    source "$1/bundle/.ralph/bash-lib/wizard-validation.sh"

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
    source "$1/bundle/.ralph/bash-lib/wizard-validation.sh"

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
    source "$1/bundle/.ralph/bash-lib/wizard-validation.sh"

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
    source "$1/bundle/.ralph/bash-lib/wizard-validation.sh"

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
    source "$1/bundle/.ralph/bash-lib/wizard-validation.sh"

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
  bundle_root="$(mktemp -d)"
  workspace="$(mktemp -d)"
  mkdir -p "$bundle_root/.ralph/bash-lib"
  mkdir -p "$workspace/.cursor/agents/research"
  mkdir -p "$workspace/.cursor/agents/architect"
  mkdir -p "$workspace/.cursor/agents/implementation"

  cp "$REPO_ROOT/bundle/.ralph/orchestration-wizard.sh" "$bundle_root/.ralph/orchestration-wizard.sh"
  cp "$REPO_ROOT/bundle/.ralph/bash-lib/"*.sh "$bundle_root/.ralph/bash-lib/"
  cp "$REPO_ROOT/bundle/.ralph/plan.template" "$bundle_root/.ralph/plan.template"
  chmod +x "$bundle_root/.ralph/orchestration-wizard.sh"

  echo '{"model":"auto"}' > "$workspace/.cursor/agents/research/config.json"
  echo '{"model":"auto"}' > "$workspace/.cursor/agents/architect/config.json"
  echo '{"model":"auto"}' > "$workspace/.cursor/agents/implementation/config.json"

  {
    printf "End-to-End Test\n"
    printf "e2e-test\n"
    printf "Complete orchestration test\n"
    printf "\n"
    printf "n\n"
    printf "r1,r2,r3\n"
    printf '\n%.0s' {1..18}
    printf "y\nr1,r2\n\n"
    printf "y\n\nr1\nr1,r2\n"
    printf "y\ny\n1\ny\n1\n"
    printf "y\n"
  } >"$workspace/input.txt"

  wizard="$bundle_root/.ralph/orchestration-wizard.sh"
  run bash -c 'export LC_ALL=C LANG=C; cd "$1" && tr -d "\r" < "$3" | bash "$2"' bash "$workspace" "$wizard" "$workspace/input.txt"

  [ "$status" -eq 0 ]

  orch_file="$workspace/.ralph-workspace/orchestration-plans/e2e-test/e2e-test.orch.json"
  [ -f "$orch_file" ]

  run jq empty "$orch_file"
  [ "$status" -eq 0 ]

  run jq -e '.name' "$orch_file"
  [ "$status" -eq 0 ]

  run jq -e '.stages | length == 3' "$orch_file"
  [ "$status" -eq 0 ]

  run jq -e '.parallelStages | length == 2' "$orch_file"
  [ "$status" -eq 0 ]

  run jq -r '.parallelStages[0]' "$orch_file"
  [ "$status" -eq 0 ]
  [[ "$output" == "r1,r2" ]]

  run jq -e '.stages[] | select(.inputArtifacts) | length > 0' "$orch_file"
  [ "$status" -eq 0 ]

  plan_dir="$workspace/.ralph-workspace/orchestration-plans/e2e-test"
  [ -f "$plan_dir/e2e-test-01-r1.plan.md" ]
  [ -f "$plan_dir/e2e-test-02-r2.plan.md" ]
  [ -f "$plan_dir/e2e-test-03-r3.plan.md" ]

  [ -d "$workspace/.ralph-workspace/artifacts/e2e-test" ]

  grep -q "## TODOs" "$plan_dir/e2e-test-01-r1.plan.md"
  grep -q '\- \[ \]' "$plan_dir/e2e-test-01-r1.plan.md"

  rm -rf "$bundle_root" "$workspace"
}

@test "wizard-generated JSON with custom stage IDs and all configuration options" {
  bundle_root="$(mktemp -d)"
  workspace="$(mktemp -d)"
  mkdir -p "$bundle_root/.ralph/bash-lib"
  mkdir -p "$workspace/.cursor/agents/research"
  mkdir -p "$workspace/.claude/agents/architect"
  mkdir -p "$workspace/.codex/agents/implementation"

  cp "$REPO_ROOT/bundle/.ralph/orchestration-wizard.sh" "$bundle_root/.ralph/orchestration-wizard.sh"
  cp "$REPO_ROOT/bundle/.ralph/bash-lib/"*.sh "$bundle_root/.ralph/bash-lib/"
  cp "$REPO_ROOT/bundle/.ralph/plan.template" "$bundle_root/.ralph/plan.template"
  chmod +x "$bundle_root/.ralph/orchestration-wizard.sh"

  echo '{"model":"auto"}' > "$workspace/.cursor/agents/research/config.json"
  echo '{"model":"auto"}' > "$workspace/.claude/agents/architect/config.json"
  echo '{"model":"auto"}' > "$workspace/.codex/agents/implementation/config.json"

  {
    printf "Multi-Runtime Pipeline\n"
    printf "multi-runtime\n"
    printf "\n"
    printf "\n"
    printf "n\n"
    printf "stage-research,stage-design,stage-impl\n"
    printf '\n%.0s' {1..18}
    printf "y\nstage-research,stage-design\n\n"
    printf "y\n\nstage-research\nstage-research,stage-design\n"
    printf "y\ny\n1\ny\n1\n"
    printf "y\n"
  } >"$workspace/input.txt"

  wizard="$bundle_root/.ralph/orchestration-wizard.sh"
  run bash -c 'export LC_ALL=C LANG=C; cd "$1" && tr -d "\r" < "$3" | bash "$2"' bash "$workspace" "$wizard" "$workspace/input.txt"

  [ "$status" -eq 0 ]

  orch_file="$workspace/.ralph-workspace/orchestration-plans/multi-runtime/multi-runtime.orch.json"
  [ -f "$orch_file" ]

  run jq -r '.stages[0].id' "$orch_file"
  [[ "$output" == "stage-research" ]]

  run jq -r '.stages[1].id' "$orch_file"
  [[ "$output" == "stage-design" ]]

  run jq -r '.stages[2].id' "$orch_file"
  [[ "$output" == "stage-impl" ]]

  run jq -r '.stages[0].runtime' "$orch_file"
  [[ "$output" == "cursor" ]]

  run jq -r '.stages[0].agent' "$orch_file"
  [[ "$output" == "research" ]]

  run jq -r '.stages[1].contextBudget' "$orch_file"
  [[ "$output" == "standard" ]]

  run jq -e '.stages[1].inputArtifacts | length > 0' "$orch_file"
  [ "$status" -eq 0 ]

  run jq -r '.stages[1].inputArtifacts[0].path' "$orch_file"
  [[ "$output" == *"stage-research"* ]]

  rm -rf "$bundle_root" "$workspace"
}
