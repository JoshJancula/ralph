#!/usr/bin/env bats

source "$BATS_TEST_DIRNAME/helper/load-lib.bash"

@test "scripts/setup-test-fixtures.sh populates a temp workspace" {
  workspace="$(mktemp -d)"
  pushd "$workspace" >/dev/null

  run bash "$REPO_ROOT/scripts/setup-test-fixtures.sh"
  [ "$status" -eq 0 ]

  [ -f dashboard.orch.json ]
  [[ "$(cat dashboard.orch.json)" == *"\"name\": \"dashboard-three-runtime\""* ]]

  [ -d .ralph-workspace/artifacts/dashboard ]
  [ -f .ralph-workspace/artifacts/dashboard/research.md ]
  [[ "$(cat .ralph-workspace/artifacts/dashboard/research.md)" == *"Research Output"* ]]
  [[ "$(cat .ralph-workspace/artifacts/dashboard/implementation-handoff.md)" == *"Implementation Handoff"* ]]
  [[ "$(cat .ralph-workspace/artifacts/dashboard/code-review.md)" == *"Code Review Output"* ]]

  popd >/dev/null
  rm -rf "$workspace"
}
