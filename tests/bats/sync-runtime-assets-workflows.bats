#!/usr/bin/env bats
# Fast bundle/source drift checks for installer-owned bundled workflows.
# Does not invoke install.sh or agent runtimes; discovery mirrors install-ops.

source "$BATS_TEST_DIRNAME/helper/load-lib.bash"
source "$RALPH_LIB_ROOT/install/install-ops.sh"

CANONICAL_DIR="$REPO_ROOT/bundle/.ralph/workflows"
LEGACY_DIR="$REPO_ROOT/bundle/.ralph/workflow-templates"

setup() {
  install_ops_reset_state
  BUNDLE="$REPO_ROOT/bundle"
}

@test "preserve drift: canonical bundled workflows dir exists and legacy workflow-templates is absent" {
  [ -d "$CANONICAL_DIR" ]
  [ ! -e "$LEGACY_DIR" ]
}

@test "preserve drift: dynamic discovery matches every validated *.workflow.md on disk" {
  local discovered on_disk
  discovered="$(install_ops_discover_bundled_workflow_files "$REPO_ROOT/bundle" | sort)"
  on_disk="$(find "$CANONICAL_DIR" -maxdepth 1 -type f -name '*.workflow.md' -print | sort)"
  [ -n "$discovered" ]
  [ "$discovered" = "$on_disk" ]
  # Every discovered file must validate (kind + id); invalid files would diverge.
  local f
  while IFS= read -r f; do
    [[ -z "$f" ]] && continue
    install_ops_workflow_file_is_validated "$f"
  done <<<"$discovered"
}

@test "ownership drift: discovered paths stay under bundle/.ralph/workflows only" {
  local f
  while IFS= read -r f; do
    [[ -z "$f" ]] && continue
    [[ "$f" == "$CANONICAL_DIR/"* ]]
  done < <(install_ops_discover_bundled_workflow_files "$REPO_ROOT/bundle")
}

@test "preserve drift: installer-ops discovery has no hard-coded shipped workflow id list" {
  # Shipped ids must come from directory discovery, not a fixed array in install-ops.
  run grep -E 'bug-fix|feature-delivery|investigation|refactor|release-gate|plan-delivery|human-verified-delivery' \
    "$REPO_ROOT/bundle/.ralph/bash-lib/install/install-ops.sh"
  [ "$status" -ne 0 ]
  run install_ops_discover_bundled_workflow_files "$REPO_ROOT/bundle"
  [ "$status" -eq 0 ]
  [[ "$output" == *"/bug-fix.workflow.md"* ]]
  [[ "$output" == *"/feature-delivery.workflow.md"* ]]
}
