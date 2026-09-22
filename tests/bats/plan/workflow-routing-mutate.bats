#!/usr/bin/env bats

# Scoped noninteractive routing mutation (CLI + mutate helper).

source "$BATS_TEST_DIRNAME/../helper/load-lib.bash"
source "$BATS_TEST_DIRNAME/../../../bundle/.ralph/bash-lib/plan-todo.sh"

setup() {
  unset RALPH_PROJECT_ROOT RALPH_PLAN_WORKSPACE_ROOT
  WRM_TMP="$(mktemp -d)"
  WRM_TMP="$(cd "$WRM_TMP" && pwd -P)"
  WRM_HOME="$WRM_TMP/home"
  WRM_WORKSPACE="$WRM_TMP/workspace"
  WRM_WORKSPACE_B="$WRM_TMP/workspace-b"
  WRM_SHIM="$WRM_TMP/ralph"
  mkdir -p \
    "$WRM_HOME/bundle/.ralph" \
    "$WRM_HOME/workflows" \
    "$WRM_WORKSPACE/.ralph-workspace/workflows" \
    "$WRM_WORKSPACE_B/.ralph-workspace/workflows"
  cp -R "$REPO_ROOT/bundle/.ralph/." "$WRM_HOME/bundle/.ralph/"
  awk '/^  cat > "\$tmp" <<.SHIM.$/ { flag = 1; next } /^SHIM$/ { flag = 0 } flag { print }' \
    "$REPO_ROOT/install.sh" >"$WRM_SHIM"
  chmod +x "$WRM_SHIM"
  cp "$REPO_ROOT/bundle/.ralph/workflows/assessment.workflow.md" \
    "$WRM_HOME/workflows/assessment.workflow.md"
}

teardown() { rm -rf "$WRM_TMP"; }

ralph_wf() {
  local wd="$1"
  shift
  (cd "$wd" && env -u RALPH_PROJECT_ROOT -u RALPH_PLAN_WORKSPACE_ROOT \
    RALPH_HOME="$WRM_HOME" bash "$WRM_SHIM" workflow "$@")
}

sha256_file() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 -- "$1" | awk '{print $1}'
  else
    sha256sum -- "$1" | awk '{print $1}'
  fi
}

strip_routing_lines() {
  grep -Ev '^(defaults:|[[:space:]]+runtime:|[[:space:]]+model:)' "$1" || true
}

@test "routing set updates global defaults and stage routing on assessment" {
  local path="$WRM_HOME/workflows/assessment.workflow.md"
  local before="$WRM_TMP/before.txt"
  local sha
  cp -f -- "$path" "$before"
  sha="$(sha256_file "$path")"

  run ralph_wf "$WRM_WORKSPACE" routing set assessment --global --sha256 "$sha" \
    --default-runtime claude --default-model sonnet \
    --stage inspect=cursor,composer
  [ "$status" -eq 0 ]
  [ -n "$output" ]
  grep -qx 'defaults:' "$path"
  grep -qx '  runtime: claude' "$path"
  grep -qx '  model: sonnet' "$path"
  grep -qx '      runtime: cursor' "$path"
  grep -qx '      model: composer' "$path"
  run plan_workflow_validate "$path"
  [ "$status" -eq 0 ]
  [ "$(strip_routing_lines "$before")" = "$(strip_routing_lines "$path")" ]
}

@test "routing set refuses supervisor stage updates" {
  local path="$WRM_HOME/workflows/assessment.workflow.md"
  local sha
  sha="$(sha256_file "$path")"
  run ralph_wf "$WRM_WORKSPACE" routing set assessment --global --sha256 "$sha" \
    --stage assessment-gate=claude,sonnet
  [ "$status" -ne 0 ]
  [[ "$output" == *"does not accept runtime"* ]]
}

@test "routing set detects stale sha256" {
  local path="$WRM_HOME/workflows/assessment.workflow.md"
  run ralph_wf "$WRM_WORKSPACE" routing set assessment --global --sha256 deadbeef \
    --default-runtime claude
  [ "$status" -ne 0 ]
  [[ "$output" == *"sha256 conflict"* ]]
}

@test "routing set refuses bundled scope" {
  run ralph_wf "$WRM_WORKSPACE" routing set assessment --bundled --sha256 "$(sha256_file "$WRM_HOME/workflows/assessment.workflow.md")" \
    --default-runtime claude
  [ "$status" -eq 2 ]
}

@test "global routing is visible from two project roots" {
  local path="$WRM_HOME/workflows/assessment.workflow.md"
  local sha
  sha="$(sha256_file "$path")"
  run ralph_wf "$WRM_WORKSPACE" routing set assessment --global --sha256 "$sha" \
    --default-runtime codex --default-model gpt-5
  [ "$status" -eq 0 ]

  run ralph_wf "$WRM_WORKSPACE" inspect assessment --format json
  [ "$status" -eq 0 ]
  [[ "$output" == *'"workflowRuntime": "codex"'* ]]

  run ralph_wf "$WRM_WORKSPACE_B" inspect assessment --format json
  [ "$status" -eq 0 ]
  [[ "$output" == *'"workflowRuntime": "codex"'* ]]
}
