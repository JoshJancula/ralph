#!/usr/bin/env bats
# Track 1 Jev compaction fixtures (RALPH_JEV_COMPACT). Lives under
# tests/bats/compactor/ so `run-bats.sh --filter compactor` selects this suite.

source "$BATS_TEST_DIRNAME/../helper/load-lib.bash"
# shellcheck source=../helper/compactor-fixtures.bash
source "$BATS_TEST_DIRNAME/../helper/compactor-fixtures.bash"

setup() {
  unset RALPH_JEV_COMPACT RALPH_JEV JEV_TRANSPORT JEV_FIXTURE_DIR TYPESAFE_API_KEY RALPH_JEV_STATE_DIR \
    RALPH_COMPACT_GENERIC_FALLBACK RALPH_COMPACT_FAILURE 2>/dev/null || true
  JEV_TEST_HOME=""
}

teardown() {
  if [ -n "${JEV_TEST_HOME:-}" ] && [ -d "$JEV_TEST_HOME" ]; then
    rm -rf "$JEV_TEST_HOME"
  fi
  unset JEV_TEST_HOME
}

@test "jev ranked: unknown-family large output matches pinned fixture" {
  enable_jev_compact_fixture_env
  assert_compactor_fixture jev-ranked-success
  jq -e '.family == "jev_ranked" and .status == "compacted"' \
    <"$FIXTURE_ROOT/jev-ranked-success/result.json"
}

@test "jev ranked: preserve-line drop falls back to deterministic result" {
  enable_jev_compact_fixture_env
  assert_compactor_fixture jev-preserve-line-fallback
  jq -e '.family == "failure_aware" and .status == "compacted" and .family != "jev_ranked"' \
    <"$FIXTURE_ROOT/jev-preserve-line-fallback/result.json"
}

@test "jev ranked: tier disabled matches today byte-for-byte" {
  # setup() already clears RALPH_JEV_COMPACT; pin the disabled path.
  assert_compactor_fixture jev-tier-disabled
  jq -e '.status == "not compacted" and .compacted == false and .family == null' \
    <"$FIXTURE_ROOT/jev-tier-disabled/result.json"
  # Same input as jev-ranked-success; disabled path must keep the original bytes.
  cmp -s \
    "$FIXTURE_ROOT/jev-tier-disabled/stdout.txt" \
    "$FIXTURE_ROOT/jev-ranked-success/stdout.txt"
  jq -e --rawfile raw "$FIXTURE_ROOT/jev-tier-disabled/stdout.txt" \
    '.stdout == $raw' <"$FIXTURE_ROOT/jev-tier-disabled/result.json"
}

@test "jev ranked: transport error falls back with no stderr noise" {
  enable_jev_compact_fixture_env "$FIXTURE_ROOT/jev-transport-error"
  assert_compactor_fixture jev-transport-error
  jq -e '.family == "failure_aware" and .status == "compacted" and .stderr == ""' \
    <"$FIXTURE_ROOT/jev-transport-error/result.json"
}

@test "jev ranked: source-family git diff stays verbatim" {
  enable_jev_compact_fixture_env
  assert_compactor_fixture jev-source-git-diff
  assert_compactor_preserves_fixture jev-source-git-diff
  jq -e '.family == "git_diff" and .status == "not compacted"' \
    <"$FIXTURE_ROOT/jev-source-git-diff/result.json"
}

@test "jev ranked: over 255 surviving lines windows rather than truncating" {
  enable_jev_compact_fixture_env
  assert_compactor_fixture jev-windowing-over-255
  # Tail from beyond the 255-option ceiling must survive (truncation would drop it).
  jq -e '
    .family == "jev_ranked"
    and .status == "compacted"
    and (.stdout | test("seq=0299"))
  ' <"$FIXTURE_ROOT/jev-windowing-over-255/result.json"
}

@test "jev ranked: RALPH_JEV_COMPACT unset makes no transport call" {
  if ! command -v python3 >/dev/null 2>&1; then
    skip "python3 required for compactor tests"
  fi

  # Default-off promise: even with fixture transport and a key present, unset
  # RALPH_JEV_COMPACT must not dial the Jev client at all.
  run python3 - <<PY
import os
import sys
from pathlib import Path
from unittest import mock

repo = Path("$REPO_ROOT")
sys.path.insert(0, str(repo / "tests" / "python"))
sys.path.insert(0, str(repo / "bundle" / ".ralph" / "python"))
from ralph_script_loader import load_ralph_script

soc = load_ralph_script("shell-output-compact.py")
stdout = (repo / "tests/fixtures/compactors/jev-ranked-success/stdout.txt").read_text()
command = (repo / "tests/fixtures/compactors/jev-ranked-success/command.txt").read_text()

os.environ.pop("RALPH_JEV_COMPACT", None)
os.environ["RALPH_JEV"] = "1"
os.environ["JEV_TRANSPORT"] = "fixture"
os.environ["JEV_FIXTURE_DIR"] = str(repo / "tests/fixtures/jev")
os.environ["TYPESAFE_API_KEY"] = "test-key-for-fixture-transport"

with mock.patch.object(
    soc,
    "_jev_rank_surviving_lines",
    side_effect=AssertionError("Jev transport consulted while RALPH_JEV_COMPACT unset"),
):
    result = soc.compact_shell_output(command.strip(), stdout, "", 0)

if result.status != "not compacted" or result.stdout != stdout:
    raise SystemExit(
        f"expected passthrough, got family={result.family!r} status={result.status!r}"
    )
print("ok")
PY

  [ "$status" -eq 0 ]
  [[ "$output" == *"ok"* ]]
}
