#!/usr/bin/env bats
# Installer ownership for bundled workflows (canonical .ralph/workflows/).
# Entry-point cases share one fixture; no agent runtime invocation.

source "$BATS_TEST_DIRNAME/../helper/load-lib.bash"
source "$RALPH_LIB_ROOT/install/install-ops.sh"

setup_file() {
  export WF_SHARED="$(mktemp -d "${TMPDIR:-/tmp}/ralph-wf-install.XXXXXX")"
  export WF_DISCOVERY_BUNDLE="$WF_SHARED/discovery-bundle"
  mkdir -p "$WF_DISCOVERY_BUNDLE/.ralph/workflows"

  local id
  for id in alpha beta gamma; do
    cat >"$WF_DISCOVERY_BUNDLE/.ralph/workflows/${id}.workflow.md" <<EOF
---
name: $id
overview: fixture $id
kind: workflow
mode: dependency
---
# $id
EOF
  done

  # Invalid: bad id / missing kind — must not be discovered.
  printf '%s\n' '---' 'name: bad' 'kind: workflow' '---' 'x' \
    >"$WF_DISCOVERY_BUNDLE/.ralph/workflows/Bad_ID.workflow.md"
  printf '%s\n' '---' 'name: nokind' 'mode: dependency' '---' 'x' \
    >"$WF_DISCOVERY_BUNDLE/.ralph/workflows/no-kind.workflow.md"
  printf '%s\n' 'not a workflow' >"$WF_DISCOVERY_BUNDLE/.ralph/workflows/readme.md"

  # Shared instruction fragments referenced by workflows as {{INCLUDE:<name>}}.
  mkdir -p "$WF_DISCOVERY_BUNDLE/.ralph/workflows/_fragments"
  printf '%s\n' 'shared scope guidance' \
    >"$WF_DISCOVERY_BUNDLE/.ralph/workflows/_fragments/scope-discipline.md"
  printf '%s\n' 'shared evaluator guidance' \
    >"$WF_DISCOVERY_BUNDLE/.ralph/workflows/_fragments/evaluator-contract.md"
}

teardown_file() {
  rm -rf "${WF_SHARED:-}"
}

setup() {
  install_ops_reset_state
  BUNDLE="$WF_DISCOVERY_BUNDLE"
  TARGET=""
  GLOBAL_INSTALL=0
  INSTALL_SHARED=1
}

_write_minimal_workflow() {
  local path="$1"
  local id="$2"
  mkdir -p "$(dirname -- "$path")"
  cat >"$path" <<EOF
---
name: $id
overview: user $id
kind: workflow
mode: dependency
---
# user $id
EOF
}

@test "dynamic discovery lists only validated bundled workflow files" {
  run install_ops_discover_bundled_workflow_files "$WF_DISCOVERY_BUNDLE"
  [ "$status" -eq 0 ]
  [[ "$output" == *"/alpha.workflow.md"* ]]
  [[ "$output" == *"/beta.workflow.md"* ]]
  [[ "$output" == *"/gamma.workflow.md"* ]]
  [[ "$output" != *"Bad_ID"* ]]
  [[ "$output" != *"no-kind"* ]]
  [[ "$output" != *"readme.md"* ]]
  [ "$(printf '%s\n' "$output" | grep -c '\.workflow\.md$' || true)" -eq 3 ]
}

@test "dynamic discovery picks up an added workflow without a hard-coded id list" {
  cat >"$WF_DISCOVERY_BUNDLE/.ralph/workflows/extra-probe.workflow.md" <<'EOF'
---
name: extra-probe
overview: dynamically added
kind: workflow
mode: dependency
---
# extra-probe
EOF
  run install_ops_discover_bundled_workflow_files "$WF_DISCOVERY_BUNDLE"
  [ "$status" -eq 0 ]
  [[ "$output" == *"/extra-probe.workflow.md"* ]]
  [ "$(printf '%s\n' "$output" | grep -c '\.workflow\.md$' || true)" -eq 4 ]
  rm -f "$WF_DISCOVERY_BUNDLE/.ralph/workflows/extra-probe.workflow.md"
}

@test "ownership sync installs discovered workflows under installer-owned ralph root only" {
  TARGET="$(mktemp -d "$WF_SHARED/target.XXXXXX")"
  GLOBAL_INSTALL=0
  INSTALL_SHARED=1
  DRY_RUN=0

  run install_ops_sync_bundled_workflows
  [ "$status" -eq 0 ]
  [ -f "$TARGET/.ralph/workflows/alpha.workflow.md" ]
  [ -f "$TARGET/.ralph/workflows/beta.workflow.md" ]
  [ -f "$TARGET/.ralph/workflows/gamma.workflow.md" ]
  [ ! -e "$TARGET/.ralph/workflows/Bad_ID.workflow.md" ]
  [ ! -e "$TARGET/.ralph/workflows/no-kind.workflow.md" ]
  cmp -s "$WF_DISCOVERY_BUNDLE/.ralph/workflows/alpha.workflow.md" \
    "$TARGET/.ralph/workflows/alpha.workflow.md"
}

@test "ownership sync never writes project state-root or RALPH_HOME workflows user dirs" {
  TARGET="$(mktemp -d "$WF_SHARED/target.XXXXXX")"
  local ralph_home state_dir
  ralph_home="$(mktemp -d "$WF_SHARED/home.XXXXXX")"
  state_dir="$TARGET/.ralph-workspace/workflows"
  mkdir -p "$ralph_home/workflows" "$state_dir"
  _write_minimal_workflow "$ralph_home/workflows/keep-global.workflow.md" keep-global
  _write_minimal_workflow "$state_dir/keep-project.workflow.md" keep-project
  local global_before project_before
  global_before="$(cksum "$ralph_home/workflows/keep-global.workflow.md")"
  project_before="$(cksum "$state_dir/keep-project.workflow.md")"

  export RALPH_HOME="$ralph_home"
  GLOBAL_INSTALL=0
  INSTALL_SHARED=1
  DRY_RUN=0
  install_ops_sync_bundled_workflows
  install_ops_remove_legacy_workflow_templates

  [ "$(cksum "$ralph_home/workflows/keep-global.workflow.md")" = "$global_before" ]
  [ "$(cksum "$state_dir/keep-project.workflow.md")" = "$project_before" ]
  [ ! -e "$ralph_home/workflows/alpha.workflow.md" ]
  [ ! -e "$state_dir/alpha.workflow.md" ]
}

@test "local install ownership places bundled workflows and migrates workflow-templates" {
  local target ralph_home
  target="$(mktemp -d "$WF_SHARED/local.XXXXXX")"
  ralph_home="$(mktemp -d "$WF_SHARED/rhome.XXXXXX")"
  mkdir -p "$target/.ralph/workflow-templates" \
    "$target/.ralph-workspace/workflows" \
    "$ralph_home/workflows"
  printf '%s\n' 'legacy-template' >"$target/.ralph/workflow-templates/old.workflow.md"
  _write_minimal_workflow "$target/.ralph-workspace/workflows/user-project.workflow.md" user-project
  _write_minimal_workflow "$ralph_home/workflows/user-global.workflow.md" user-global
  local project_before global_before
  project_before="$(cksum "$target/.ralph-workspace/workflows/user-project.workflow.md")"
  global_before="$(cksum "$ralph_home/workflows/user-global.workflow.md")"

  run env RALPH_HOME="$ralph_home" RALPH_USAGE_RISKS_ACKNOWLEDGED=1 \
    bash "$REPO_ROOT/install.sh" --shared --silent --yes --no-dashboard "$target"
  [ "$status" -eq 0 ]
  [ -d "$target/.ralph/workflows" ]
  [ -f "$target/.ralph/workflows/bug-fix.workflow.md" ]
  [ -f "$target/.ralph/workflows/feature-delivery.workflow.md" ]
  [ -f "$target/.ralph/workflows/investigation.workflow.md" ]
  [ -f "$target/.ralph/workflows/refactor.workflow.md" ]
  [ -f "$target/.ralph/workflows/release-gate.workflow.md" ]
  [ -f "$target/.ralph/workflows/plan-delivery.workflow.md" ]
  [ -f "$target/.ralph/workflows/human-verified-delivery.workflow.md" ]
  [ -f "$target/.ralph/workflows/assessment.workflow.md" ]
  [ -f "$target/.ralph/workflows/review-jury.workflow.md" ]
  [ -f "$target/.ralph/workflows/triage.workflow.md" ]
  [ "$(find "$target/.ralph/workflows" -maxdepth 1 -name '*.workflow.md' | wc -l | tr -d ' ')" = "10" ]
  [ ! -e "$target/.ralph/workflow-templates" ]
  cmp -s "$REPO_ROOT/bundle/.ralph/workflows/bug-fix.workflow.md" \
    "$target/.ralph/workflows/bug-fix.workflow.md"
  [ "$(cksum "$target/.ralph-workspace/workflows/user-project.workflow.md")" = "$project_before" ]
  [ "$(cksum "$ralph_home/workflows/user-global.workflow.md")" = "$global_before" ]
}

@test "update install overwrites installer-owned workflows byte-exact and preserves user files" {
  local target ralph_home
  target="$(mktemp -d "$WF_SHARED/update.XXXXXX")"
  ralph_home="$(mktemp -d "$WF_SHARED/rhome-u.XXXXXX")"
  mkdir -p "$ralph_home/workflows" "$target/.ralph-workspace/workflows"

  run env RALPH_HOME="$ralph_home" RALPH_USAGE_RISKS_ACKNOWLEDGED=1 \
    bash "$REPO_ROOT/install.sh" --shared --silent --yes --no-dashboard "$target"
  [ "$status" -eq 0 ]

  printf '%s\n' 'stale-installer-copy' >"$target/.ralph/workflows/bug-fix.workflow.md"
  _write_minimal_workflow "$ralph_home/workflows/user-global.workflow.md" user-global
  _write_minimal_workflow "$target/.ralph-workspace/workflows/user-project.workflow.md" user-project
  local global_before project_before
  global_before="$(cksum "$ralph_home/workflows/user-global.workflow.md")"
  project_before="$(cksum "$target/.ralph-workspace/workflows/user-project.workflow.md")"

  # --silent keeps unrelated conflicts; workflow sync must still force-update.
  run env RALPH_HOME="$ralph_home" RALPH_USAGE_RISKS_ACKNOWLEDGED=1 \
    bash "$REPO_ROOT/install.sh" --shared --silent --no-dashboard "$target"
  [ "$status" -eq 0 ]
  cmp -s "$REPO_ROOT/bundle/.ralph/workflows/bug-fix.workflow.md" \
    "$target/.ralph/workflows/bug-fix.workflow.md"
  [ "$(cksum "$ralph_home/workflows/user-global.workflow.md")" = "$global_before" ]
  [ "$(cksum "$target/.ralph-workspace/workflows/user-project.workflow.md")" = "$project_before" ]
}

@test "global install ownership uses bundle/.ralph/workflows and preserves RALPH_HOME/workflows" {
  local temp_home ralph_home xdg_config xdg_state
  temp_home="$(mktemp -d "$WF_SHARED/ghome.XXXXXX")"
  ralph_home="$temp_home/global ralph" # space in path
  xdg_config="$temp_home/config"
  xdg_state="$temp_home/state"
  mkdir -p "$ralph_home/workflows"
  _write_minimal_workflow "$ralph_home/workflows/user-global.workflow.md" user-global
  local global_before
  global_before="$(cksum "$ralph_home/workflows/user-global.workflow.md")"

  run env HOME="$temp_home" RALPH_HOME="$ralph_home" \
    XDG_CONFIG_HOME="$xdg_config" XDG_STATE_HOME="$xdg_state" \
    RALPH_USAGE_RISKS_ACKNOWLEDGED=1 \
    bash "$REPO_ROOT/install.sh" --global --silent --yes --no-dashboard
  [ "$status" -eq 0 ]
  [ -f "$ralph_home/bundle/.ralph/workflows/bug-fix.workflow.md" ]
  cmp -s "$REPO_ROOT/bundle/.ralph/workflows/bug-fix.workflow.md" \
    "$ralph_home/bundle/.ralph/workflows/bug-fix.workflow.md"
  [ "$(cksum "$ralph_home/workflows/user-global.workflow.md")" = "$global_before" ]
  [ ! -e "$ralph_home/workflows/bug-fix.workflow.md" ]
}

@test "uninstall removes installer-owned workflows and legacy templates but preserves user files" {
  local target ralph_home
  target="$(mktemp -d "$WF_SHARED/uninst.XXXXXX")"
  ralph_home="$(mktemp -d "$WF_SHARED/rhome-un.XXXXXX")"
  mkdir -p "$ralph_home/workflows" "$target/.ralph-workspace/workflows"

  run env RALPH_HOME="$ralph_home" RALPH_USAGE_RISKS_ACKNOWLEDGED=1 \
    bash "$REPO_ROOT/install.sh" --shared --silent --yes --no-dashboard "$target"
  [ "$status" -eq 0 ]
  mkdir -p "$target/.ralph/workflow-templates"
  printf '%s\n' 'legacy' >"$target/.ralph/workflow-templates/old.workflow.md"
  _write_minimal_workflow "$ralph_home/workflows/user-global.workflow.md" user-global
  _write_minimal_workflow "$target/.ralph-workspace/workflows/user-project.workflow.md" user-project
  local global_before project_before
  global_before="$(cksum "$ralph_home/workflows/user-global.workflow.md")"
  project_before="$(cksum "$target/.ralph-workspace/workflows/user-project.workflow.md")"

  run env RALPH_HOME="$ralph_home" RALPH_USAGE_RISKS_ACKNOWLEDGED=1 \
    bash "$REPO_ROOT/install.sh" --uninstall --shared --silent --no-dashboard "$target"
  [ "$status" -eq 0 ]
  [ ! -e "$target/.ralph/workflows/bug-fix.workflow.md" ]
  [ ! -e "$target/.ralph/workflow-templates/old.workflow.md" ]
  [ "$(cksum "$ralph_home/workflows/user-global.workflow.md")" = "$global_before" ]
  [ "$(cksum "$target/.ralph-workspace/workflows/user-project.workflow.md")" = "$project_before" ]
}

@test "dry-run install does not write workflows or remove legacy templates" {
  local target
  target="$(mktemp -d "$WF_SHARED/dry.XXXXXX")"
  mkdir -p "$target/.ralph/workflow-templates"
  printf '%s\n' 'legacy' >"$target/.ralph/workflow-templates/old.workflow.md"

  run env RALPH_USAGE_RISKS_ACKNOWLEDGED=1 \
    bash "$REPO_ROOT/install.sh" --shared -n --silent --no-dashboard "$target"
  [ "$status" -eq 0 ]
  [[ "$output" == *"workflows"* ]] || [[ "$output" == *".ralph"* ]]
  [ ! -d "$target/.ralph/workflows" ]
  [ -f "$target/.ralph/workflow-templates/old.workflow.md" ]
}

@test "preserve workflow install ownership with spaces in target and ralph home" {
  local target ralph_home spaced
  spaced="$WF_SHARED/with spaces"
  mkdir -p "$spaced"
  target="$(mktemp -d "$spaced/target.XXXXXX")"
  ralph_home="$(mktemp -d "$spaced/ralph-home.XXXXXX")"
  mkdir -p "$ralph_home/workflows" "$target/.ralph-workspace/workflows"
  _write_minimal_workflow "$ralph_home/workflows/user-global.workflow.md" user-global
  local global_before
  global_before="$(cksum "$ralph_home/workflows/user-global.workflow.md")"

  run env RALPH_HOME="$ralph_home" RALPH_USAGE_RISKS_ACKNOWLEDGED=1 \
    bash "$REPO_ROOT/install.sh" --shared --silent --yes --no-dashboard "$target"
  [ "$status" -eq 0 ]
  [ -f "$target/.ralph/workflows/release-gate.workflow.md" ]
  cmp -s "$REPO_ROOT/bundle/.ralph/workflows/release-gate.workflow.md" \
    "$target/.ralph/workflows/release-gate.workflow.md"
  [ "$(cksum "$ralph_home/workflows/user-global.workflow.md")" = "$global_before" ]
}

@test "ownership sync installs workflow instruction fragments alongside workflows" {
  # A bundled workflow that uses {{INCLUDE:<name>}} cannot be instantiated at all
  # when the fragments directory is missing, so the fragments must ship with it.
  TARGET="$(mktemp -d "$WF_SHARED/target.XXXXXX")"
  GLOBAL_INSTALL=0
  INSTALL_SHARED=1
  DRY_RUN=0

  run install_ops_sync_bundled_workflows
  [ "$status" -eq 0 ]
  [ -f "$TARGET/.ralph/workflows/_fragments/scope-discipline.md" ]
  [ -f "$TARGET/.ralph/workflows/_fragments/evaluator-contract.md" ]
  cmp -s "$WF_DISCOVERY_BUNDLE/.ralph/workflows/_fragments/scope-discipline.md" \
    "$TARGET/.ralph/workflows/_fragments/scope-discipline.md"
  # A non-fragment file in workflows/ is still not treated as a workflow.
  [ ! -e "$TARGET/.ralph/workflows/readme.md" ]
}

@test "dry-run install does not write workflow instruction fragments" {
  TARGET="$(mktemp -d "$WF_SHARED/target.XXXXXX")"
  GLOBAL_INSTALL=0
  INSTALL_SHARED=1
  DRY_RUN=1

  run install_ops_sync_bundled_workflows
  [ "$status" -eq 0 ]
  [ ! -e "$TARGET/.ralph/workflows/_fragments" ]
}

@test "every bundled workflow fragment referenced by a bundled workflow exists" {
  # Guards against a workflow referencing a fragment that was never authored.
  local wf_dir="$REPO_ROOT/bundle/.ralph/workflows"
  local name
  while IFS= read -r name; do
    [ -f "$wf_dir/_fragments/$name.md" ] || {
      echo "missing fragment: $name"
      false
    }
  done < <(grep -rhoE '\{\{INCLUDE:[a-z0-9-]+\}\}' "$wf_dir"/*.workflow.md \
    | sed -E 's/\{\{INCLUDE:(.*)\}\}/\1/' | sort -u)
}
