#!/usr/bin/env bats
# Fixture-contract test for tests/fixtures/native-hook/*.json.
# Confirms committed live-capture fixtures are well-formed, provenance-backed,
# and expose the tool-specific output path each fixture claims to demonstrate.
# Runs entirely offline against static JSON; never invokes claude or the network.

source "$BATS_TEST_DIRNAME/../helper/load-lib.bash"

FIXTURE_DIR="$REPO_ROOT/tests/fixtures/native-hook"
PROVENANCE="$FIXTURE_DIR/provenance.json"

setup() {
  _tmp="$(mktemp -d)"
}

teardown() {
  rm -rf "$_tmp"
}

# Checks common PostToolUse envelope fields plus the tool-specific text path
# declared in provenance for $2 (fixture basename). Returns non-zero on any
# contract violation instead of asserting inline, so callers can test both
# the real fixture dir and deliberately broken temp fixtures.
_native_hook_fixture_contract_check() {
  local fixture_dir="$1" name="$2" provenance="$3"
  local f="$fixture_dir/$name"

  [[ -f "$f" ]] || return 1
  jq -e . "$f" >/dev/null 2>&1 || return 1

  jq -e '.hook_event_name == "PostToolUse"' "$f" >/dev/null 2>&1 || return 1
  jq -e '.tool_name | length > 0' "$f" >/dev/null 2>&1 || return 1
  jq -e '.session_id | length > 0' "$f" >/dev/null 2>&1 || return 1
  jq -e '.tool_input | type == "object"' "$f" >/dev/null 2>&1 || return 1
  jq -e '.tool_response' "$f" >/dev/null 2>&1 || return 1

  [[ -f "$provenance" ]] || return 1
  jq -e --arg n "$name" '.fixtures[$n]' "$provenance" >/dev/null 2>&1 || return 1

  local tool observed_path
  tool="$(jq -r '.tool_name' "$f")"
  observed_path="$(jq -r --arg n "$name" '.fixtures[$n].observedTextPath // ""' "$provenance")"

  case "$tool" in
    Read)
      jq -e '(.tool_response.file.content // "") | length > 0' "$f" >/dev/null 2>&1 || return 1
      ;;
    Bash)
      jq -e '.tool_response | has("stdout") and has("stderr")' "$f" >/dev/null 2>&1 || return 1
      ;;
    Grep)
      if [[ "$observed_path" == *".tool_response.content"* ]]; then
        jq -e '(.tool_response.content // "") | length > 0' "$f" >/dev/null 2>&1 || return 1
      fi
      ;;
  esac
  return 0
}

@test "native-hook fixture dir is non-empty" {
  run bash -c "ls '$FIXTURE_DIR'/*.json 2>/dev/null | wc -l"
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | tr -d ' ')" -ge 5 ]
}

@test "provenance.json parses and declares required top-level fields" {
  run jq -e '.cliVersion and .observationDate and .sanitization and .fixtures' "$PROVENANCE"
  [ "$status" -eq 0 ]
}

@test "every fixture file has a provenance entry" {
  for f in "$FIXTURE_DIR"/*.json; do
    local name
    name="$(basename "$f")"
    [[ "$name" == "provenance.json" ]] && continue
    run jq -e --arg n "$name" '.fixtures[$n]' "$PROVENANCE"
    [ "$status" -eq 0 ]
  done
}

@test "every provenance entry has a matching fixture file" {
  local names
  names="$(jq -r '.fixtures | keys[]' "$PROVENANCE")"
  while IFS= read -r name; do
    [[ -z "$name" ]] && continue
    [[ -f "$FIXTURE_DIR/$name" ]]
  done <<<"$names"
}

@test "read.json satisfies the fixture contract" {
  _native_hook_fixture_contract_check "$FIXTURE_DIR" "read.json" "$PROVENANCE"
}

@test "grep-content.json satisfies the fixture contract" {
  _native_hook_fixture_contract_check "$FIXTURE_DIR" "grep-content.json" "$PROVENANCE"
}

@test "grep-files-with-matches.json satisfies the fixture contract" {
  _native_hook_fixture_contract_check "$FIXTURE_DIR" "grep-files-with-matches.json" "$PROVENANCE"
}

@test "glob.json satisfies the fixture contract" {
  _native_hook_fixture_contract_check "$FIXTURE_DIR" "glob.json" "$PROVENANCE"
}

@test "bash.json satisfies the fixture contract" {
  _native_hook_fixture_contract_check "$FIXTURE_DIR" "bash.json" "$PROVENANCE"
}

@test "malformed fixture fails the contract check" {
  printf 'not json' > "$_tmp/broken.json"
  cp "$PROVENANCE" "$_tmp/provenance.json"
  jq --arg n "broken.json" '.fixtures[$n] = {tool: "Read", observedTextPath: ".tool_response.file.content"}' \
    "$_tmp/provenance.json" > "$_tmp/provenance.json.tmp"
  mv "$_tmp/provenance.json.tmp" "$_tmp/provenance.json"

  run _native_hook_fixture_contract_check "$_tmp" "broken.json" "$_tmp/provenance.json"
  [ "$status" -ne 0 ]
}

@test "unproven fixture (no provenance entry) fails the contract check" {
  cp "$FIXTURE_DIR/read.json" "$_tmp/unproven.json"
  printf '{"cliVersion":"x","observationDate":"x","sanitization":"x","fixtures":{}}' > "$_tmp/provenance.json"

  run _native_hook_fixture_contract_check "$_tmp" "unproven.json" "$_tmp/provenance.json"
  [ "$status" -ne 0 ]
}

@test "fixture-contract checks pass with no claude/curl/wget binary on PATH" {
  # Proves the contract check has no hidden dependency on the CLI or network:
  # stub PATH down to only what jq/bash/coreutils need, remove any claude,
  # curl, or wget binary, and confirm the same checks still succeed offline.
  local stub_bin
  stub_bin="$_tmp/stubbed-path"
  mkdir -p "$stub_bin"
  for tool in jq bash cat mkdir rm ls basename dirname mktemp tr wc; do
    local real
    real="$(type -P "$tool" 2>/dev/null)" || continue
    ln -sf "$real" "$stub_bin/$tool"
  done

  [[ ! -e "$stub_bin/claude" && ! -e "$stub_bin/curl" && ! -e "$stub_bin/wget" ]]

  PATH="$stub_bin" run _native_hook_fixture_contract_check "$FIXTURE_DIR" "read.json" "$PROVENANCE"
  [ "$status" -eq 0 ]
}
