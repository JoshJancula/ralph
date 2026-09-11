#!/usr/bin/env bats

source "$BATS_TEST_DIRNAME/helper/load-lib.bash"
source "$REPO_ROOT/bundle/.ralph/bash-lib/tooling-profile.sh"

EXPECTED_PROFILE_NAMES='raw
ralph-read-heavy
ralph-compact
ralph-aggressive'

@test "ralph_tooling_profile_names: prints exactly the four names" {
  run ralph_tooling_profile_names
  [ "$status" -eq 0 ]
  while IFS= read -r name; do
    [[ -n "$name" ]] || continue
    printf '%s\n' "$EXPECTED_PROFILE_NAMES" | grep -qxF "$name" \
      || fail "unexpected profile name '$name'"
  done <<< "$output"
  [ "$(printf '%s\n' "$output" | wc -l | tr -d ' ')" = "4" ]
  while IFS= read -r name; do
    [[ -n "$name" ]] || continue
    printf '%s\n' "$output" | grep -qxF "$name" \
      || fail "expected profile name '$name' missing from output"
  done <<< "$EXPECTED_PROFILE_NAMES"
}

@test "ralph_tooling_profile_validate: known profiles validate, unknown fails" {
  run ralph_tooling_profile_validate raw
  [ "$status" -eq 0 ]
  run ralph_tooling_profile_validate ralph-compact
  [ "$status" -eq 0 ]
  run ralph_tooling_profile_validate not-a-profile
  [ "$status" -ne 0 ]
  run ralph_tooling_profile_validate ""
  [ "$status" -ne 0 ]
}

@test "ralph_tooling_profile_env: ralph-compact for claude includes RALPH_MODE and threshold" {
  run ralph_tooling_profile_env ralph-compact claude
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -qxF "RALPH_MODE=ralph"
  printf '%s\n' "$output" | grep -qxF "RALPH_COMPACT_GENERIC_THRESHOLD_BYTES=16384"
  printf '%s\n' "$output" | grep -qxF "RALPH_TOOLING_PROFILE=ralph-compact"
  ! printf '%s\n' "$output" | grep -q '^RALPH_TOOLING_PROFILE_DEGRADED='
}

@test "ralph_tooling_profile_env: raw for claude includes RALPH_MODE=no" {
  run ralph_tooling_profile_env raw claude
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -qxF "RALPH_MODE=no"
  printf '%s\n' "$output" | grep -qxF "RALPH_TOOLING_PROFILE=raw"
}

@test "ralph_tooling_profile_env: unknown profile name exits 1 with a message" {
  run ralph_tooling_profile_env not-a-profile claude
  [ "$status" -eq 1 ]
  [[ "$output" == *"unknown tooling profile"* ]]
}

@test "ralph_tooling_profile_env: every invocation emits RALPH_TOOLING_PROFILE=" {
  for name in raw ralph-read-heavy ralph-compact ralph-aggressive; do
    for runtime in claude cursor codex opencode antigravity; do
      run ralph_tooling_profile_env "$name" "$runtime"
      [ "$status" -eq 0 ]
      printf '%s\n' "$output" | grep -qxF "RALPH_TOOLING_PROFILE=$name" \
        || fail "missing RALPH_TOOLING_PROFILE= for $name/$runtime"
    done
  done
}

# Table-driven degraded-key assertions, one row per runtime, derived directly
# from the static contract in graph-runtime-capabilities.sh:
#   claude/cursor/codex: all five keys supported, never degraded.
#   opencode: RALPH_NATIVE_RESULT_COMPACT unsupported (headless hook unproven).
#   antigravity: RALPH_PROXY_SHELL_COMPACT, RALPH_COMPACT_GENERIC_FALLBACK,
#     RALPH_COMPACT_GENERIC_THRESHOLD_BYTES unsupported (not in the universal
#     MCP proxy-shell matrix).
@test "ralph_tooling_profile_env: claude has no degraded keys for ralph-aggressive" {
  run ralph_tooling_profile_env ralph-aggressive claude
  [ "$status" -eq 0 ]
  ! printf '%s\n' "$output" | grep -q '^RALPH_TOOLING_PROFILE_DEGRADED='
}

@test "ralph_tooling_profile_env: cursor has no degraded keys for ralph-aggressive" {
  run ralph_tooling_profile_env ralph-aggressive cursor
  [ "$status" -eq 0 ]
  ! printf '%s\n' "$output" | grep -q '^RALPH_TOOLING_PROFILE_DEGRADED='
}

@test "ralph_tooling_profile_env: codex has no degraded keys for ralph-aggressive" {
  run ralph_tooling_profile_env ralph-aggressive codex
  [ "$status" -eq 0 ]
  ! printf '%s\n' "$output" | grep -q '^RALPH_TOOLING_PROFILE_DEGRADED='
}

@test "ralph_tooling_profile_env: opencode drops RALPH_NATIVE_RESULT_COMPACT for ralph-aggressive" {
  run ralph_tooling_profile_env ralph-aggressive opencode
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -qxF "RALPH_TOOLING_PROFILE_DEGRADED=RALPH_NATIVE_RESULT_COMPACT"
  ! printf '%s\n' "$output" | grep -q '^RALPH_NATIVE_RESULT_COMPACT='
}

@test "ralph_tooling_profile_env: antigravity drops the shell-compaction keys for ralph-aggressive" {
  run ralph_tooling_profile_env ralph-aggressive antigravity
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -qxF \
    "RALPH_TOOLING_PROFILE_DEGRADED=RALPH_COMPACT_GENERIC_FALLBACK,RALPH_COMPACT_GENERIC_THRESHOLD_BYTES,RALPH_PROXY_SHELL_COMPACT"
  ! printf '%s\n' "$output" | grep -q '^RALPH_PROXY_SHELL_COMPACT='
  ! printf '%s\n' "$output" | grep -q '^RALPH_COMPACT_GENERIC_FALLBACK='
  ! printf '%s\n' "$output" | grep -q '^RALPH_COMPACT_GENERIC_THRESHOLD_BYTES='
  printf '%s\n' "$output" | grep -qxF "RALPH_NATIVE_RESULT_COMPACT=1"
  printf '%s\n' "$output" | grep -qxF "RALPH_MODE=ralph"
}

# D4: named profiles control compaction channels, not exploration tool steering.
@test "tooling-profile descriptions say compaction channels not exploration steering" {
  local desc
  for name in raw ralph-read-heavy ralph-compact ralph-aggressive; do
    desc="$(jq -r --arg n "$name" '.profiles[$n].description' \
      "$REPO_ROOT/bundle/.ralph/tooling-profiles.json")"
    [[ "$desc" == *"Compaction channels only (not exploration steering)"* ]] \
      || fail "profile $name description missing compaction-channels wording"
    [[ "$desc" == *"native Read/Grep/Glob for exploration"* ]] \
      || fail "profile $name description missing native exploration wording"
    [[ "$desc" != *"primary path for read"* ]] \
      || fail "profile $name description still steers proxy as primary path for read"
  done
}
