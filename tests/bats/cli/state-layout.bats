#!/usr/bin/env bats
source "$BATS_TEST_DIRNAME/../helper/load-lib.bash"

CHECKER="$REPO_ROOT/scripts/check-state-layout.sh"
FIXTURE_GENERATOR="$REPO_ROOT/tests/fixtures/state-layout/generate-fixtures.sh"

setup() {
  fixture_root="$(mktemp -d)"
  bash "$FIXTURE_GENERATOR" "$fixture_root"
}

teardown() { rm -rf "$fixture_root"; }

@test "state layout checker reports v1 fixture ownership totals" {
  run bash "$CHECKER" --root "$fixture_root/v1"
  [ "$status" -eq 0 ]
  # plan-1 output.log + run-manifest, child-1 run-manifest => 3 plan-attempt files
  [[ "$output" == *$'\tplan attempt\tv1\t3\t'* ]]
  [[ "$output" == *$'unclassified\tunknown\tshared\t1\t8'* ]]
}

@test "state layout checker reports mixed v1 and v2 categories as JSON" {
  command -v jq >/dev/null 2>&1 || skip "jq unavailable"
  run bash "$CHECKER" --root "$fixture_root/mixed" --json
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '.categories[] | select(.category == "run-catalog-v2") | .fileCount')" = "1" ]
  # plan attempt output.log + child run-manifest
  [ "$(printf '%s' "$output" | jq -r '.categories[] | select(.category == "plan-attempt-v2") | .fileCount')" = "2" ]
  [ "$(printf '%s' "$output" | jq -r '.categories[] | select(.category == "unclassified") | .fileCount')" = "1" ]
}

@test "state layout checker does not follow directory symlinks" {
  run bash "$CHECKER" --root "$fixture_root/mixed" --json
  [ "$status" -eq 0 ]
  # catalog + 2 plan attempts + workflow + graph + indexes + tool-results + sessions + artifacts + odd
  [ "$(printf '%s' "$output" | jq '[.categories[].fileCount] | add')" = "10" ]
}

@test "state layout checker refuses a missing root argument" {
  run bash "$CHECKER"
  [ "$status" -eq 2 ]
  [[ "$output" == *"Usage: check-state-layout.sh --root <state-root> [--json]"* ]]
}
