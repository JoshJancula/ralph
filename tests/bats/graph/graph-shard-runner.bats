#!/usr/bin/env bats
# G21: bounded graph test runner. One hanging fake test and one multi-test
# discovery fixture prove start/progress, hung-file naming, cleanup, and
# that healthy shards keep file-level parallelism.
#
# The discovery fixture's test count and the runner's --file-timeout are
# deliberately far apart. A single --file-timeout has to serve two opposite
# roles here: the healthy file must finish well inside it, and the hung file
# must exceed it. At 73 tests (~9s) against a 15s timeout the healthy file had
# only ~1.7x of headroom, so under tier parallelism it tripped FILE TIMEOUT and
# never printed FILE DONE. The count is a fixture parameter, not a contract --
# what is pinned is that the reported discovery count matches the file exactly.

source "$BATS_TEST_DIRNAME/../helper/load-lib.bash"

RUNNER="$REPO_ROOT/scripts/run-graph-bats.sh"
SHARDS_JSON="$BATS_TEST_DIRNAME/shards.json"

setup_file() {
  export BATS_NO_PARALLELIZE_WITHIN_FILE=true
}

setup() {
  FX="$(mktemp -d)"
  HANG_NAME="zzz-hang-forever-$$.bats"
  # Kept in one place so the fixture, the shard manifest and the assertions can
  # never drift apart.
  DISCOVER_COUNT=12
}

teardown() {
  if [[ -n "${FX:-}" && -d "${FX:-}" ]]; then
    pkill -9 -f "$HANG_NAME" 2>/dev/null || true
    rm -rf "$FX"
  fi
}

write_discover_fixture() {
  local dest="$1"
  local count="$2"
  local i=1
  printf '%s\n' '#!/usr/bin/env bats' >"$dest"
  while [[ "$i" -le "$count" ]]; do
    printf '%s\n' "@test \"disc-${i}\" { true; }" >>"$dest"
    i=$((i + 1))
  done
}

write_sleep_file() {
  local dest="$1"
  local label="$2"
  cat >"$dest" <<EOF
#!/usr/bin/env bats
@test "${label}" {
  [ -z "\${RALPH_PROCESS_RUN_ID:-}" ]
  [ -z "\${RALPH_PROCESS_RUN_DIR:-}" ]
  [ -z "\${RALPH_ALLOW_NESTED_RUNS:-}" ]
  sleep 1
}
EOF
}

write_hang_file() {
  local dest="$1"
  cat >"$dest" <<EOF
#!/usr/bin/env bats
@test "hang forever" {
  trap '' TERM INT HUP
  while true; do sleep 1; done
}
EOF
}

write_fixture_shards() {
  local dest="$1"
  cat >"$dest" <<EOF
{
  "schemaVersion": 1,
  "exclude": [],
  "shards": [
    {
      "name": "core",
      "description": "compile, state, events, scheduler, failure classification",
      "files": ["$FX/discover.bats"]
    },
    {
      "name": "operator",
      "description": "status, actions, logs, attach, TUI, recovery",
      "files": ["$FX/slow-a.bats", "$FX/slow-b.bats"]
    },
    {
      "name": "runtime-approval",
      "description": "adapter and approval continuation tests",
      "files": []
    },
    {
      "name": "isolation",
      "description": "roots, workspaces, changesets, integration, publication",
      "files": ["$FX/$HANG_NAME"]
    },
    {
      "name": "acceptance",
      "description": "vertical journeys and canaries",
      "files": []
    }
  ]
}
EOF
}

@test "G21 shards.json names the five stable shards and excludes the runner test" {
  run bash "$RUNNER" --list-shards
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | grep -c .)" -eq 5 ]
  [[ "$output" == *$'\n'* || "$output" == *"core"* ]]
  printf '%s\n' "$output" | grep -Fxq "core"
  printf '%s\n' "$output" | grep -Fxq "operator"
  printf '%s\n' "$output" | grep -Fxq "runtime-approval"
  printf '%s\n' "$output" | grep -Fxq "isolation"
  printf '%s\n' "$output" | grep -Fxq "acceptance"

  run bash "$RUNNER" --list-files
  [ "$status" -eq 0 ]
  [[ "$output" == *"tests/bats/graph/graph-compile.bats"* ]]
  [[ "$output" != *"graph-shard-runner.bats"* ]]
  [[ -f "$SHARDS_JSON" ]]
}

@test "runner reports exact discovery count, names a hung file, cleans up, and keeps healthy-shard parallelism" {
  write_discover_fixture "$FX/discover.bats" "$DISCOVER_COUNT"
  write_sleep_file "$FX/slow-a.bats" "slow-a"
  write_sleep_file "$FX/slow-b.bats" "slow-b"
  write_hang_file "$FX/$HANG_NAME"
  write_fixture_shards "$FX/shards.json"

  run env \
    RALPH_PROCESS_RUN_ID=outer-run \
    RALPH_PROCESS_RUN_DIR="$FX/outer-run" \
    RALPH_ALLOW_NESTED_RUNS=1 \
    bash "$RUNNER" \
    --no-setup-fixtures \
    --shards-json "$FX/shards.json" \
    --shard core \
    --shard operator \
    --shard isolation \
    -j 2 \
    --file-timeout 20 \
    --progress-interval 1

  [ "$status" -eq 124 ]

  # Discovery reports the file's exact test count, and prompt start/progress.
  [[ "$output" == *"FILE START shard=core file=${FX}/discover.bats discovered=${DISCOVER_COUNT}"* ]]
  [[ "$output" == *"1..${DISCOVER_COUNT}"* ]]
  [[ "$output" == *"FILE DONE shard=core file=${FX}/discover.bats"* ]]

  # Hung file is named; cleanup is reported; leftover processes are gone
  [[ "$output" == *"FILE TIMEOUT"* ]]
  [[ "$output" == *"$HANG_NAME"* ]]
  [[ "$output" == *"FILE CLEANUP"* ]]
  [[ "$output" == *"killed-tree=1"* ]]
  leftover="$(pgrep -f "$HANG_NAME" 2>/dev/null || true)"
  [ -z "$leftover" ]

  # Healthy operator shard retained -j 2: both files start before either finishes
  op_starts="$(printf '%s\n' "$output" | grep -n "FILE START shard=operator" || true)"
  op_dones="$(printf '%s\n' "$output" | grep -n "FILE DONE shard=operator" || true)"
  [ -n "$op_starts" ]
  [ -n "$op_dones" ]
  first_op_done_line="$(printf '%s\n' "$op_dones" | head -n 1 | cut -d: -f1)"
  second_op_start_line="$(printf '%s\n' "$op_starts" | tail -n 1 | cut -d: -f1)"
  [ "$second_op_start_line" -lt "$first_op_done_line" ]
  [[ "$output" == *"SHARD START operator files=2 jobs=2"* ]]
}

# --- Shard manifest completeness -------------------------------------------
#
# An unassigned graph test file is never executed by this runner. That was a
# warning for a long time, and four files -- including the tooling-profile
# feature tests -- sat unrun behind it. These tests pin it as a hard error.

@test "shard manifest assigns every graph test file" {
  run bash "$RUNNER" --list-files
  [ "$status" -eq 0 ]
  [[ "$output" != *"unassigned file"* ]]

  local f rel
  while IFS= read -r f; do
    rel="${f#"$REPO_ROOT"/}"
    # Excluded files are intentionally absent from --list-files output.
    if grep -Fq "\"$rel\"" "$SHARDS_JSON"; then
      continue
    fi
    echo "graph test file is in no shard and not excluded: $rel" >&2
    return 1
  done < <(find "$REPO_ROOT/tests/bats/graph" -name '*.bats' -type f | LC_ALL=C sort)
}

@test "an unassigned graph test file fails the runner instead of being skipped" {
  local manifest="$FX/dropped-shards.json"
  # Drop one file from its shard while leaving it on disk: exactly the shape of
  # a new test file nobody added to the manifest.
  local dropped="tests/bats/graph/graph-compile.bats"
  grep -v "\"$dropped\"" "$SHARDS_JSON" | sed 's/,\([[:space:]]*\]\)/\1/' >"$manifest"
  # Guard against the fixture silently becoming a no-op.
  ! grep -Fq "\"$dropped\"" "$manifest"

  run bash "$RUNNER" --shards-json "$manifest" --list-files
  [ "$status" -ne 0 ]
  [[ "$output" == *"ERROR: unassigned file $dropped"* ]]
  [[ "$output" == *"in no shard and not excluded"* ]]
  # It must fail before executing anything.
  [[ "$output" != *"FILE START"* ]]
}
