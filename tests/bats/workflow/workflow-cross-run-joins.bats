#!/usr/bin/env bats

@test "dependency run records expose reciprocal join fields and compiled stage keys" {
  local repo
  repo="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"

  run bash -c '
    set -euo pipefail
    workflow="$1/bundle/.ralph/workflow-cli.sh"
    graph="$1/bundle/.ralph/bash-lib/graph/graph-state.sh"
    state="$1/bundle/.ralph/bash-lib/workflow/workflow-state.sh"
    grep -q "\.stageKeys = \$stageKeys" "$workflow"
    grep -q "tool-results/" "$workflow"
    grep -q "registryRunPath: \$registryRunPath" "$state"
    grep -q "kind:\"graph\"" "$graph"
    grep -q "namespace:\$namespace" "$graph"
  ' _ "$repo"

  [ "$status" -eq 0 ]
}
