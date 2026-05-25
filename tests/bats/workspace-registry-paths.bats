#!/usr/bin/env bats

source "$BATS_TEST_DIRNAME/helper/load-lib.bash"

setup() {
  command -v python3 >/dev/null 2>&1 || skip "python3 unavailable"
  TEST_TMPDIR="$(mktemp -d)"
  REGISTRY_FILE="$TEST_TMPDIR/workspaces.json"
  REGISTRY_PY="$REPO_ROOT/bundle/.ralph/bash-lib/workspace-registry.py"
}

teardown() {
  rm -rf "$TEST_TMPDIR"
}

@test "paths prints existing deduped absolute paths" {
  local real_a real_b missing dup_of_a
  real_a="$TEST_TMPDIR/project-a"
  real_b="$TEST_TMPDIR/project-b"
  missing="$TEST_TMPDIR/does-not-exist"
  dup_of_a="$real_a"
  mkdir -p "$real_a" "$real_b"

  python3 - "$REGISTRY_FILE" "$real_a" "$real_b" "$missing" "$dup_of_a" <<'PY'
import json, os, sys
registry = sys.argv[1]
real_a, real_b, missing = sys.argv[2], sys.argv[3], sys.argv[4]
abs_a = os.path.abspath(real_a)
abs_b = os.path.abspath(real_b)
abs_missing = os.path.abspath(missing)
records = [
    {"path": abs_a, "lastSeen": "2026-01-01T00:00:00Z", "planKey": "p1", "runtime": "cursor"},
    {"path": abs_b, "lastSeen": "2026-01-02T00:00:00Z", "planKey": "p2", "runtime": "claude"},
    {"path": abs_missing, "lastSeen": "2026-01-03T00:00:00Z", "planKey": "p3", "runtime": "codex"},
    {"path": abs_a, "lastSeen": "2026-01-04T00:00:00Z", "planKey": "p4", "runtime": "opencode"},
    {"path": 42, "lastSeen": "2026-01-05T00:00:00Z", "planKey": "p5", "runtime": "cursor"},
    {},
]
with open(registry, "w", encoding="utf-8") as handle:
    json.dump(records, handle)
PY

  run python3 "$REGISTRY_PY" paths "$REGISTRY_FILE"

  [ "$status" -eq 0 ]
  local line_count
  line_count="$(printf '%s\n' "$output" | grep -c .)"
  [ "$line_count" -eq 2 ]

  local abs_a_expected abs_b_expected
  abs_a_expected="$(cd "$real_a" && pwd)"
  abs_b_expected="$(cd "$real_b" && pwd)"
  [[ "$output" == *"$abs_a_expected"* ]]
  [[ "$output" == *"$abs_b_expected"* ]]
  [[ "$output" != *"does-not-exist"* ]]
}

@test "paths returns nothing for empty registry" {
  printf '[]' > "$REGISTRY_FILE"

  run python3 "$REGISTRY_PY" paths "$REGISTRY_FILE"

  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "paths returns nothing when all directories are missing" {
  python3 - "$REGISTRY_FILE" <<'PY'
import json, os, sys
registry = sys.argv[1]
abs_missing = os.path.abspath("/tmp/surely-nonexistent-dir-xyz")
records = [
    {"path": abs_missing, "lastSeen": "2026-01-01T00:00:00Z", "planKey": "gone", "runtime": "cursor"},
]
with open(registry, "w", encoding="utf-8") as handle:
    json.dump(records, handle)
PY

  run python3 "$REGISTRY_PY" paths "$REGISTRY_FILE"

  [ "$status" -eq 0 ]
  [ -z "$output" ]
}