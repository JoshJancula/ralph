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
  [[ "$output" == *"Removed 2 registry entries; kept 1."* ]]

  run env RALPH_WORKSPACES_FILE="$REGISTRY_FILE" bash "$WORKSPACES_CLI" list

  [ "$status" -eq 0 ]
  [[ "$output" == *"$keep"* ]]
  [[ "$output" != *"$missing"* ]]
  [[ "$output" != *"$old"* ]]
}

@test "workspaces prune --dry-run reports entries without rewriting the registry" {
  local kept
  kept="$TEST_TMPDIR/kept"
  mkdir -p "$kept"
  python3 - "$REGISTRY_FILE" "$kept" "$TEST_TMPDIR/gone" <<'PY'
import json, sys
registry, kept, gone = sys.argv[1:]
records = [
    {"path": gone, "lastSeen": "2099-01-01T00:00:00Z", "planKey": "p", "runtime": "codex"},
    {"path": kept, "lastSeen": "2099-01-01T00:00:00Z", "planKey": "p", "runtime": "codex"},
]
json.dump(records, open(registry, "w"))
PY
  before="$(cat "$REGISTRY_FILE")"

  run env RALPH_WORKSPACES_FILE="$REGISTRY_FILE" bash "$WORKSPACES_CLI" prune --dry-run

  [ "$status" -eq 0 ]
  [[ "$output" == *"Would remove: $TEST_TMPDIR/gone (directory no longer exists)"* ]]
  [[ "$output" == *"No project files were touched."* ]]
  [ "$(cat "$REGISTRY_FILE")" = "$before" ]
}

@test "workspaces clean previews by default and deletes only with --yes" {
  command -v jq >/dev/null 2>&1 || skip "jq unavailable"
  local proj="$TEST_TMPDIR/proj"
  mkdir -p "$proj/.ralph-workspace/logs" "$proj/.ralph-workspace/plans"
  echo x >"$proj/.ralph-workspace/logs/old.log"
  touch -t 202001010000 "$proj/.ralph-workspace/logs/old.log"
  echo keep >"$proj/.ralph-workspace/plans/keep.md"
  touch -t 202001010000 "$proj/.ralph-workspace/plans/keep.md"

  run bash "$WORKSPACES_CLI" clean "$proj"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Would remove 1 file(s)"* ]]
  [ -f "$proj/.ralph-workspace/logs/old.log" ]

  run bash "$WORKSPACES_CLI" clean "$proj" --yes
  [ "$status" -eq 0 ]
  [ ! -e "$proj/.ralph-workspace/logs/old.log" ]
  [ -f "$proj/.ralph-workspace/plans/keep.md" ]
}

@test "workspaces clean --all refuses while a graph run is awaiting-ack" {
  command -v jq >/dev/null 2>&1 || skip "jq unavailable"
  local proj="$TEST_TMPDIR/proj"
  mkdir -p "$proj/.ralph-workspace/graph-runs/ns/r1"
  echo '{"status":"awaiting-ack"}' >"$proj/.ralph-workspace/graph-runs/ns/r1/run.json"

  run bash "$WORKSPACES_CLI" clean "$proj" --all --yes

  [ "$status" -eq 1 ]
  [[ "$output" == *"Refusing to delete"* ]]
  [ -d "$proj/.ralph-workspace" ]
}

@test "workspaces doctor reports then fixes a run whose owner died" {
  command -v jq >/dev/null 2>&1 || skip "jq unavailable"
  local proj="$TEST_TMPDIR/proj"
  mkdir -p "$proj/.ralph-workspace/graph-runs/ns/r1"
  echo '{"status":"running","supervisorPid":999999}' >"$proj/.ralph-workspace/graph-runs/ns/r1/run.json"

  run bash "$WORKSPACES_CLI" doctor "$proj"
  [ "$status" -eq 1 ]
  [[ "$output" == *"PROBLEM  graph run stuck as running"* ]]

  run bash "$WORKSPACES_CLI" doctor "$proj" --fix
  [ "$status" -eq 0 ]
  [ "$(jq -r .status "$proj/.ralph-workspace/graph-runs/ns/r1/run.json")" = "failed" ]
}

@test "workspaces status fails clearly outside a Ralph project" {
  run bash "$WORKSPACES_CLI" status "$TEST_TMPDIR"

  [ "$status" -eq 1 ]
  [[ "$output" == *"no .ralph-workspace directory"* ]]
}
