#!/usr/bin/env bats

source "$BATS_TEST_DIRNAME/helper/load-lib.bash"

@test "real-runtime acceptance harnesses refuse to run without their explicit flag" {
  local harness
  for harness in \
    "$REPO_ROOT/tests/acceptance/accept-cross-runtime-real-cli.sh" \
    "$REPO_ROOT/tests/acceptance/accept-parallel-implementation-real-cli.sh"; do
    run bash "$harness"
    [ "$status" -eq 2 ]
    [[ "$output" == *"--run-real-runtime-acceptance"* ]]
    [[ "$output" == *"can consume LLM credits"* ]]
  done
}

@test "the normal Bats suite does not discover local real-runtime smoke tests" {
  run bash "$REPO_ROOT/scripts/run-bats.sh" --list-suite
  [ "$status" -eq 0 ]
  [[ "$output" != *"tests/bats/local/"* ]]
}

@test "agent tool-access verification requires --live before it can invoke runtime CLIs" {
  run bash "$REPO_ROOT/scripts/verify-agent-tool-access.sh" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"--live"* ]]
  [[ "$output" == *"never invokes a runtime CLI"* ]]
}
