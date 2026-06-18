#!/usr/bin/env bats

source "$BATS_TEST_DIRNAME/../helper/load-lib.bash"

LIB_FILE="$REPO_ROOT/bundle/.ralph/bash-lib/run-plan/run-plan-opencode-cache-warning.sh"
FIXTURE_DIR="$REPO_ROOT/tests/fixtures/opencode-cache-warning"

@test "opencode cache warning does not trigger for a single large-input invocation" {
  [ -x "$(command -v python3)" ] || skip "python3 required"

  run bash -c '
    set -euo pipefail
    source "$1"
    ralph_opencode_cache_warning_should_warn "$2"
  ' _ "$LIB_FILE" "$FIXTURE_DIR/single-invocation-large-input.json"

  [ "$status" -ne 0 ]
}

@test "opencode cache warning triggers after repeated zero-cache large-input invocations" {
  [ -x "$(command -v python3)" ] || skip "python3 required"

  run bash -c '
    set -euo pipefail
    source "$1"
    stats="$(ralph_opencode_cache_warning_should_warn "$2")"
    printf "%s\n" "$stats"
  ' _ "$LIB_FILE" "$FIXTURE_DIR/two-invocations-zero-cache-large-input.json"

  [ "$status" -eq 0 ]
  [[ "$output" == *11000* ]]
}

@test "opencode cache warning does not trigger when average input stays below threshold" {
  [ -x "$(command -v python3)" ] || skip "python3 required"

  run bash -c '
    set -euo pipefail
    source "$1"
    ralph_opencode_cache_warning_should_warn "$2"
  ' _ "$LIB_FILE" "$FIXTURE_DIR/two-invocations-small-input.json"

  [ "$status" -ne 0 ]
}

@test "opencode cache warning emit logs once with provider/model guidance" {
  [ -x "$(command -v python3)" ] || skip "python3 required"

  run bash -c '
    set -euo pipefail
    source "$1"
    unset RALPH_OPENCODE_AMBIENT_CACHE_SETTINGS
    _ralph_opencode_cache_warn_emitted=0
    ralph_opencode_cache_warning_maybe_emit "$2" "anthropic/claude-sonnet-4" "$2" 0 0
    ralph_opencode_cache_warning_maybe_emit "$2" "anthropic/claude-sonnet-4" "$2" 0 0
  ' _ "$LIB_FILE" "$FIXTURE_DIR/two-invocations-zero-cache-large-input.json"

  [ "$status" -eq 0 ]
  [[ "$output" == *"may not support caching"* ]]
  warning_count="$(printf "%s\n" "$output" | grep -c "may not support caching" || true)"
  [ "$warning_count" -eq 1 ]
}

@test "opencode cache warning emits cache-estimated-unreported note when estimate is available" {
  [ -x "$(command -v python3)" ] || skip "python3 required"

  run bash -c '
    set -euo pipefail
    source "$1"
    unset RALPH_OPENCODE_AMBIENT_CACHE_SETTINGS
    _ralph_opencode_cache_warn_emitted=0
    # final_cache_settings=1 means cache settings are present; should produce a note when cache fields were not reported.
    ralph_opencode_cache_warning_maybe_emit "$2" "anthropic/claude-sonnet-4" "$2" 0 1
  ' _ "$LIB_FILE" "$FIXTURE_DIR/two-invocations-zero-cache-large-input-key-injected.json"

  [ "$status" -eq 0 ]
  [[ "$output" == *"Note:"* ]]
  [[ "$output" == *"best-guess indicates about 10000 cached-token input tokens read"* ]]
}

@test "opencode cache warning keeps old cache-enabled-not-reported note when estimate is unavailable" {
  [ -x "$(command -v python3)" ] || skip "python3 required"

  run bash -c '
    set -euo pipefail
    source "$1"
    unset RALPH_OPENCODE_AMBIENT_CACHE_SETTINGS
    _ralph_opencode_cache_warn_emitted=0
    # No key injected on invocations => estimate helper returns estimated=0 => fall back to old note wording.
    ralph_opencode_cache_warning_maybe_emit "$2" "anthropic/claude-sonnet-4" "$2" 0 1
  ' _ "$LIB_FILE" "$FIXTURE_DIR/two-invocations-zero-cache-large-input.json"

  [ "$status" -eq 0 ]
  [[ "$output" == *"Ollama Cloud does not yet report cached-token counts."* ]]
  [[ "$output" != *"best-guess indicates about"* ]]
}
