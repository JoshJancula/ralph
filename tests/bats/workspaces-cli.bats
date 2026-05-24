#!/usr/bin/env bats

source "$BATS_TEST_DIRNAME/helper/load-lib.bash"

setup() {
  command -v python3 >/dev/null 2>&1 || skip "python3 unavailable"
  TEST_TMPDIR="$(mktemp -d)"
  REGISTRY_FILE="$TEST_TMPDIR/workspaces.json"
  WORKSPACES_CLI="$REPO_ROOT/bundle/.ralph/bash-lib/workspaces-cli.sh"
}

teardown() {
  rm -rf "$TEST_TMPDIR"
}

@test "workspaces list handles an empty registry" {
  run env RALPH_WORKSPACES_FILE="$REGISTRY_FILE" bash "$WORKSPACES_CLI" list

  [ "$status" -eq 0 ]
  [ "$output" = "No workspaces registered." ]
}

@test "workspaces add registers a real workspace" {
  local workspace
  workspace="$TEST_TMPDIR/project"
  mkdir -p "$workspace"

  run env RALPH_WORKSPACES_FILE="$REGISTRY_FILE" bash "$WORKSPACES_CLI" add "$workspace"

  [ "$status" -eq 0 ]
  [[ "$output" == "Added workspace: $workspace" ]]

  run env RALPH_WORKSPACES_FILE="$REGISTRY_FILE" bash "$WORKSPACES_CLI" list

  [ "$status" -eq 0 ]
  [[ "$output" == *"PATH"* ]]
  [[ "$output" == *"$workspace"* ]]
  [[ "$output" == *"manual"* ]]
}

@test "workspaces list prints most recent entries first" {
  local older newer
  older="$TEST_TMPDIR/older"
  newer="$TEST_TMPDIR/newer"
  mkdir -p "$older" "$newer"
  python3 - "$REGISTRY_FILE" "$older" "$newer" <<'PY'
import json, sys
registry, older, newer = sys.argv[1:]
records = [
    {"path": older, "lastSeen": "2026-01-01T00:00:00Z", "planKey": "older-plan", "runtime": "cursor"},
    {"path": newer, "lastSeen": "2026-02-01T00:00:00Z", "planKey": "newer-plan", "runtime": "codex"},
]
with open(registry, "w", encoding="utf-8") as handle:
    json.dump(records, handle)
PY

  run env RALPH_WORKSPACES_FILE="$REGISTRY_FILE" bash "$WORKSPACES_CLI" list

  [ "$status" -eq 0 ]
  newer_line="$(printf '%s\n' "$output" | grep -nF "$newer" | cut -d: -f1)"
  older_line="$(printf '%s\n' "$output" | grep -nF "$older" | cut -d: -f1)"
  [ "$newer_line" -lt "$older_line" ]
}

@test "workspaces prune removes missing and stale entries" {
  local keep missing old
  keep="$TEST_TMPDIR/keep"
  missing="$TEST_TMPDIR/missing"
  old="$TEST_TMPDIR/old"
  mkdir -p "$keep" "$old"
  python3 - "$REGISTRY_FILE" "$keep" "$missing" "$old" <<'PY'
import json, sys
from datetime import datetime, timedelta, timezone
registry, keep, missing, old = sys.argv[1:]
now = datetime.now(timezone.utc)
records = [
    {"path": keep, "lastSeen": now.isoformat(timespec="seconds").replace("+00:00", "Z"), "planKey": "keep", "runtime": "cursor"},
    {"path": missing, "lastSeen": now.isoformat(timespec="seconds").replace("+00:00", "Z"), "planKey": "missing", "runtime": "claude"},
    {"path": old, "lastSeen": (now - timedelta(days=90)).isoformat(timespec="seconds").replace("+00:00", "Z"), "planKey": "old", "runtime": "codex"},
]
with open(registry, "w", encoding="utf-8") as handle:
    json.dump(records, handle)
PY

  run env RALPH_WORKSPACES_FILE="$REGISTRY_FILE" RALPH_WORKSPACE_PRUNE_DAYS=60 bash "$WORKSPACES_CLI" prune

  [ "$status" -eq 0 ]
  [[ "$output" == "Pruned 2 workspace(s); kept 1." ]]

  run env RALPH_WORKSPACES_FILE="$REGISTRY_FILE" bash "$WORKSPACES_CLI" list

  [ "$status" -eq 0 ]
  [[ "$output" == *"$keep"* ]]
  [[ "$output" != *"$missing"* ]]
  [[ "$output" != *"$old"* ]]
}
