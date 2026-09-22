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

@test "agy print-mode run with the merged hooks.json shows the shell rewrite (opt-in)" {
  [ "${RALPH_RUN_REAL_AGY_SMOKE:-0}" = "1" ] || skip "set RALPH_RUN_REAL_AGY_SMOKE=1 to run the real agy smoke"
  command -v agy >/dev/null 2>&1 || skip "agy binary not found"

  local ws
  ws="$(mktemp -d)"
  mkdir -p "$ws/.agents"
  cp -R "$REPO_ROOT/bundle/.agents/hooks" "$ws/.agents/hooks"
  cp "$REPO_ROOT/bundle/.agents/hooks.json" "$ws/.agents/hooks.json"
  mkdir -p "$ws/.ralph-workspace"

  local model_args=()
  [ -z "${RALPH_AGY_SMOKE_MODEL:-}" ] || model_args=(--model "$RALPH_AGY_SMOKE_MODEL")
  run env \
    RALPH_HOME="$REPO_ROOT" \
    RALPH_MODE=native \
    RALPH_NATIVE_SHELL_WRAPPER=1 \
    RALPH_BASH_REWRITE=1 \
    RALPH_BASH_REWRITE_LOG="$ws/rewrite.jsonl" \
    bash -c 'cd "$1" && shift && agy --print "$@"' _ "$ws" "${model_args[@]}" \
    "Run the shell command: echo agy-smoke-ok. Reply with the word done."
  local ec=$status
  local seen=0
  [ -s "$ws/rewrite.jsonl" ] && seen=1
  [[ "$output" == *native-shell-wrapper* ]] && seen=1
  rm -rf "$ws"
  [ "$ec" -eq 0 ]
  [ "$seen" -eq 1 ]
}
