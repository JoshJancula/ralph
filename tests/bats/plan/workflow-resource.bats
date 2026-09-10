#!/usr/bin/env bats

# Pure workflow resource resolver. Sourced-function level (cheapest that
# observes public resolve/list/scope/precedence contracts).
# Contracts: agents/rules/test-design.md, agents/rules/testing-workflow.md,
# .ralph-workspace/artifacts/ralph-first-class-workflows/contracts.md
# (Workflow ID and resolution / Ownership boundaries).

source "$BATS_TEST_DIRNAME/../helper/load-lib.bash"

setup_file() {
  WR_LIB="$REPO_ROOT/bundle/.ralph/bash-lib/workflow/workflow-resource.sh"
  export WR_LIB
}

setup() {
  # Fresh load each test so module globals reset.
  unset RALPH_WORKFLOW_RESOURCE_LOADED
  unset RALPH_DISABLE_GLOBAL_FALLBACK
  # shellcheck source=../../../bundle/.ralph/bash-lib/workflow/workflow-resource.sh
  source "$WR_LIB"

  WR_TMP="$(mktemp -d)"
  WR_PROJECT="$WR_TMP/project"
  WR_STATE="$WR_TMP/state"
  WR_HOME="$WR_TMP/ralph-home"
  WR_BUNDLE="$WR_TMP/bundle"
  mkdir -p \
    "$WR_PROJECT" \
    "$WR_STATE/workflows" \
    "$WR_HOME/workflows" \
    "$WR_BUNDLE/.ralph/workflows"
  workflow_resource_init "$WR_PROJECT" "$WR_STATE" "$WR_HOME" "$WR_BUNDLE"
}

teardown() {
  rm -rf "$WR_TMP"
}

write_wf() {
  local path="$1"
  local overview="${2:-overview text}"
  mkdir -p "$(dirname "$path")"
  printf '%s\n' '---' 'kind: workflow' "overview: $overview" '---' >"$path"
}

@test "id validation accepts lowercase-hyphen ids and rejects others" {
  workflow_resource_id_valid "bug-fix"
  workflow_resource_id_valid "a"
  workflow_resource_id_valid "feature-delivery-2"
  run workflow_resource_id_valid "Bug-Fix"
  [ "$status" -ne 0 ]
  run workflow_resource_id_valid "bad_id"
  [ "$status" -ne 0 ]
  run workflow_resource_id_valid "-leading"
  [ "$status" -ne 0 ]
  run workflow_resource_id_valid "trailing-"
  [ "$status" -ne 0 ]
  run workflow_resource_id_valid "has space"
  [ "$status" -ne 0 ]
  run workflow_resource_id_valid ""
  [ "$status" -ne 0 ]
}

@test "init stores absolute project state ralph-home and bundle roots" {
  [[ "$(workflow_resource_project_root)" == /* ]]
  [[ "$(workflow_resource_state_root)" == /* ]]
  [[ "$(workflow_resource_ralph_home)" == /* ]]
  [[ "$(workflow_resource_bundle_root)" == /* ]]
  [[ "$(workflow_resource_project_dir)" == "$(workflow_resource_state_root)/workflows" ]]
  [[ "$(workflow_resource_global_dir)" == "$(workflow_resource_ralph_home)/workflows" ]]
  [[ "$(workflow_resource_bundled_dir)" == "$(workflow_resource_bundle_root)/.ralph/workflows" ]]
}

@test "roots remain absolute after cwd change" {
  local project_before state_before home_before bundle_before
  project_before="$(workflow_resource_project_root)"
  state_before="$(workflow_resource_state_root)"
  home_before="$(workflow_resource_ralph_home)"
  bundle_before="$(workflow_resource_bundle_root)"

  cd "$WR_TMP"
  [[ "$(workflow_resource_project_root)" == "$project_before" ]]
  [[ "$(workflow_resource_state_root)" == "$state_before" ]]
  [[ "$(workflow_resource_ralph_home)" == "$home_before" ]]
  [[ "$(workflow_resource_bundle_root)" == "$bundle_before" ]]

  write_wf "$WR_STATE/workflows/alpha.workflow.md" "from project"
  run workflow_resource_resolve alpha
  [ "$status" -eq 0 ]
  [[ "$output" == $'project\t'"$(workflow_resource_project_dir)/alpha.workflow.md" ]]
}

@test "implicit resolve prefers project over global over bundled" {
  write_wf "$WR_BUNDLE/.ralph/workflows/shared.workflow.md" "bundled"
  write_wf "$WR_HOME/workflows/shared.workflow.md" "global"
  write_wf "$WR_STATE/workflows/shared.workflow.md" "project"

  run workflow_resource_resolve shared
  [ "$status" -eq 0 ]
  [[ "$output" == $'project\t'"$(workflow_resource_project_dir)/shared.workflow.md" ]]

  rm -f "$WR_STATE/workflows/shared.workflow.md"
  run workflow_resource_resolve shared
  [ "$status" -eq 0 ]
  [[ "$output" == $'global\t'"$(workflow_resource_global_dir)/shared.workflow.md" ]]

  rm -f "$WR_HOME/workflows/shared.workflow.md"
  run workflow_resource_resolve shared
  [ "$status" -eq 0 ]
  [[ "$output" == $'bundled\t'"$(workflow_resource_bundled_dir)/shared.workflow.md" ]]
}

@test "RALPH_DISABLE_GLOBAL_FALLBACK skips global on implicit lookup only" {
  write_wf "$WR_HOME/workflows/only-global.workflow.md" "global only"
  write_wf "$WR_BUNDLE/.ralph/workflows/only-global.workflow.md" "bundled shadow"

  RALPH_DISABLE_GLOBAL_FALLBACK=1
  run workflow_resource_resolve only-global
  [ "$status" -eq 0 ]
  [[ "$output" == $'bundled\t'"$(workflow_resource_bundled_dir)/only-global.workflow.md" ]]

  run workflow_resource_resolve only-global global
  [ "$status" -eq 0 ]
  [[ "$output" == $'global\t'"$(workflow_resource_global_dir)/only-global.workflow.md" ]]
}

@test "scoped lookup never falls through" {
  write_wf "$WR_HOME/workflows/scoped.workflow.md" "global"
  write_wf "$WR_BUNDLE/.ralph/workflows/scoped.workflow.md" "bundled"

  run workflow_resource_resolve scoped project
  [ "$status" -ne 0 ]

  run workflow_resource_resolve scoped global
  [ "$status" -eq 0 ]
  [[ "$output" == $'global\t'"$(workflow_resource_global_dir)/scoped.workflow.md" ]]

  run workflow_resource_resolve scoped bundled
  [ "$status" -eq 0 ]
  [[ "$output" == $'bundled\t'"$(workflow_resource_bundled_dir)/scoped.workflow.md" ]]
}

@test "invalid id is rejected before filesystem access" {
  run workflow_resource_resolve 'Bad_ID'
  [ "$status" -eq 2 ]
  [[ "$output" == *"invalid workflow id"* ]]

  run workflow_resource_resolve 'ok-id' 'not-a-scope'
  [ "$status" -eq 2 ]
  [[ "$output" == *"invalid workflow scope"* ]]
}

@test "source_kind classifies by stored roots" {
  write_wf "$WR_STATE/workflows/p.workflow.md"
  write_wf "$WR_HOME/workflows/g.workflow.md"
  write_wf "$WR_BUNDLE/.ralph/workflows/b.workflow.md"

  [[ "$(workflow_resource_source_kind "$WR_STATE/workflows/p.workflow.md")" == project ]]
  [[ "$(workflow_resource_source_kind "$WR_HOME/workflows/g.workflow.md")" == global ]]
  [[ "$(workflow_resource_source_kind "$WR_BUNDLE/.ralph/workflows/b.workflow.md")" == bundled ]]
}

@test "list_winning is sorted by id with winning source kind and absolute paths" {
  write_wf "$WR_BUNDLE/.ralph/workflows/zeta.workflow.md" "bundled zeta"
  write_wf "$WR_HOME/workflows/alpha.workflow.md" "global alpha"
  write_wf "$WR_STATE/workflows/alpha.workflow.md" "project alpha"
  write_wf "$WR_BUNDLE/.ralph/workflows/beta.workflow.md" "bundled beta"

  run workflow_resource_list_winning
  [ "$status" -eq 0 ]
  [[ "$(printf '%s\n' "$output" | wc -l | tr -d ' ')" == "3" ]]
  [[ "${lines[0]}" == $'alpha\tproject\t'"$(workflow_resource_project_dir)/alpha.workflow.md" ]]
  [[ "${lines[1]}" == $'beta\tbundled\t'"$(workflow_resource_bundled_dir)/beta.workflow.md" ]]
  [[ "${lines[2]}" == $'zeta\tbundled\t'"$(workflow_resource_bundled_dir)/zeta.workflow.md" ]]
  local path_field="${lines[0]##*$'\t'}"
  [[ "$path_field" == /* ]]
}

@test "list_winning skips global when fallback disabled" {
  write_wf "$WR_HOME/workflows/gamma.workflow.md" "global"
  write_wf "$WR_BUNDLE/.ralph/workflows/delta.workflow.md" "bundled"

  RALPH_DISABLE_GLOBAL_FALLBACK=1
  run workflow_resource_list_winning
  [ "$status" -eq 0 ]
  [[ "$output" != *"gamma"* ]]
  [[ "$output" == $'delta\tbundled\t'* ]]
}

@test "list_winning de-duplicates by physical path across symlink scopes" {
  write_wf "$WR_HOME/workflows/shared-phys.workflow.md" "canonical"
  ln -s "$WR_HOME/workflows/shared-phys.workflow.md" \
    "$WR_STATE/workflows/alias-name.workflow.md"

  run workflow_resource_list_winning
  [ "$status" -eq 0 ]
  # Project symlink is scanned first; global physical duplicate is skipped.
  [[ "$(printf '%s\n' "$output" | wc -l | tr -d ' ')" == "1" ]]
  [[ "${lines[0]}" == $'alias-name\tproject\t'* ]]
  [[ "$output" != *$'\tglobal\t'* ]]
}

@test "resolve returns absolute path for spaced roots" {
  unset RALPH_WORKFLOW_RESOURCE_LOADED
  source "$WR_LIB"
  local spaced="$WR_TMP/space root"
  local project="$spaced/project"
  local state="$spaced/state root"
  local home="$spaced/ralph home"
  local bundle="$spaced/bundle root"
  mkdir -p "$project" "$state/workflows" "$home/workflows" "$bundle/.ralph/workflows"
  write_wf "$state/workflows/spacey.workflow.md" "spaced"
  workflow_resource_init "$project" "$state" "$home" "$bundle"

  run workflow_resource_resolve spacey
  [ "$status" -eq 0 ]
  [[ "$output" == $'project\t'*"/spacey.workflow.md" ]]
  [[ "$output" == /* || "$output" == *$'\t'/* ]]
  local path="${output#*$'\t'}"
  [[ -f "$path" ]]
}

# Real-bundle discovery (shell resolver only). Python list/path coverage lives
# in tests/python/test_wizard_workflow_template.py.
@test "exact seven bundled workflow ids from real repo bundle" {
  unset RALPH_WORKFLOW_RESOURCE_LOADED
  source "$WR_LIB"
  local empty="$WR_TMP/empty-scopes"
  mkdir -p "$empty/project" "$empty/state/workflows" "$empty/home/workflows"
  workflow_resource_init "$empty/project" "$empty/state" "$empty/home" "$REPO_ROOT/bundle"

  run workflow_resource_list_winning
  [ "$status" -eq 0 ]
  [[ "$(printf '%s\n' "$output" | wc -l | tr -d ' ')" == "10" ]]
  [[ "${lines[0]}" == $'assessment\tbundled\t'* ]]
  [[ "${lines[1]}" == $'bug-fix\tbundled\t'* ]]
  [[ "${lines[2]}" == $'feature-delivery\tbundled\t'* ]]
  [[ "${lines[3]}" == $'human-verified-delivery\tbundled\t'* ]]
  [[ "${lines[4]}" == $'investigation\tbundled\t'* ]]
  [[ "${lines[5]}" == $'plan-delivery\tbundled\t'* ]]
  [[ "${lines[6]}" == $'refactor\tbundled\t'* ]]
  [[ "${lines[7]}" == $'release-gate\tbundled\t'* ]]
  [[ "${lines[8]}" == $'review-jury\tbundled\t'* ]]
  [[ "${lines[9]}" == $'triage\tbundled\t'* ]]
}

@test "canonical bundled path is under .ralph/workflows" {
  unset RALPH_WORKFLOW_RESOURCE_LOADED
  source "$WR_LIB"
  local empty="$WR_TMP/empty-scopes-canonical"
  mkdir -p "$empty/project" "$empty/state/workflows" "$empty/home/workflows"
  workflow_resource_init "$empty/project" "$empty/state" "$empty/home" "$REPO_ROOT/bundle"

  [[ "$(workflow_resource_bundled_dir)" == "$REPO_ROOT/bundle/.ralph/workflows" ]]
  run workflow_resource_resolve bug-fix bundled
  [ "$status" -eq 0 ]
  [[ "$output" == $'bundled\t'"$REPO_ROOT/bundle/.ralph/workflows/bug-fix.workflow.md" ]]
  [[ -f "${output#*$'\t'}" ]]
}

@test "old path workflow-templates is absent from bundle" {
  [[ ! -d "$REPO_ROOT/bundle/.ralph/workflow-templates" ]]
  [[ -d "$REPO_ROOT/bundle/.ralph/workflows" ]]
}
