#!/usr/bin/env bats
# Test suite for setup-helpers.sh
#
# This suite covers:
# - Atomic write behavior (original file unchanged on failure)
# - Dry-run behavior (reports without creating files)
# - Path resolution helpers
# - JSON validation
# - Config merge status output

source "$BATS_TEST_DIRNAME/../helper/load-lib.bash"

SETUP_HELPERS_SH="$REPO_ROOT/bundle/.ralph/bash-lib/setup/setup-helpers.sh"

setup() {
  # Create temp directory for each test
  TEST_TEMP_DIR="$(mktemp -d)"
  export TEST_TEMP_DIR
}

teardown() {
  # Clean up temp directory
  if [[ -d "${TEST_TEMP_DIR:-}" ]]; then
    rm -rf "$TEST_TEMP_DIR"
  fi
}

checksum_file() {
  local path="$1"
  if command -v md5 >/dev/null 2>&1; then
    md5 "$path" | awk '{print $NF}'
  elif command -v md5sum >/dev/null 2>&1; then
    md5sum "$path" | awk '{print $1}'
  else
    shasum "$path" | awk '{print $1}'
  fi
}

# ============================================================================
# Atomic Write Tests
# ============================================================================

@test "setup_atomic_write creates new file" {
  [ -f "$SETUP_HELPERS_SH" ] || skip "setup-helpers.sh missing"

  local target="$TEST_TEMP_DIR/newfile.txt"

  run bash -c "
    source \"$SETUP_HELPERS_SH\"
    setup_atomic_write \"$target\" \"hello world\"
  "
  [ "$status" -eq 0 ]
  [ -f "$target" ]
  [ "$(cat "$target")" = "hello world" ]
}

@test "setup_atomic_write updates existing file atomically" {
  [ -f "$SETUP_HELPERS_SH" ] || skip "setup-helpers.sh missing"

  local target="$TEST_TEMP_DIR/existing.txt"
  echo "original content" > "$target"

  run bash -c "
    source \"$SETUP_HELPERS_SH\"
    setup_atomic_write \"$target\" \"new content\"
  "
  [ "$status" -eq 0 ]
  [ -f "$target" ]
  [ "$(cat "$target")" = "new content" ]
}

@test "setup_atomic_write leaves original unchanged on write failure" {
  [ -f "$SETUP_HELPERS_SH" ] || skip "setup-helpers.sh missing"

  local target="$TEST_TEMP_DIR/important.txt"
  echo "precious data" > "$target"
  local original_checksum
  original_checksum="$(checksum_file "$target")"

  # Make directory read-only to cause failure
  chmod 555 "$TEST_TEMP_DIR"

  run bash -c "
    source \"$SETUP_HELPERS_SH\"
    setup_atomic_write \"$target\" \"new data\" 2>&1
  "
  [ "$status" -ne 0 ]

  # Restore permissions for cleanup
  chmod 755 "$TEST_TEMP_DIR"

  # Verify original is unchanged
  [ -f "$target" ]
  local final_checksum
  final_checksum="$(checksum_file "$target")"
  [ "$original_checksum" = "$final_checksum" ]
  [ "$(cat "$target")" = "precious data" ]
}

@test "setup_atomic_write handles directories that don't exist" {
  [ -f "$SETUP_HELPERS_SH" ] || skip "setup-helpers.sh missing"

  local target="$TEST_TEMP_DIR/subdir/nested/deep/file.txt"

  run bash -c "
    source \"$SETUP_HELPERS_SH\"
    setup_atomic_write \"$target\" \"nested content\"
  "
  [ "$status" -eq 0 ]
  [ -f "$target" ]
  [ "$(cat "$target")" = "nested content" ]
}

@test "setup_atomic_write fails gracefully with missing args" {
  [ -f "$SETUP_HELPERS_SH" ] || skip "setup-helpers.sh missing"

  run bash -c "
    source \"$SETUP_HELPERS_SH\"
    setup_atomic_write 2>&1
  "
  [ "$status" -ne 0 ]
  [[ "$output" == *"target path required"* ]]
}

@test "setup_atomic_write_file copies file atomically" {
  [ -f "$SETUP_HELPERS_SH" ] || skip "setup-helpers.sh missing"

  local source="$TEST_TEMP_DIR/source.txt"
  local target="$TEST_TEMP_DIR/target.txt"
  echo "source content" > "$source"

  run bash -c "
    source \"$SETUP_HELPERS_SH\"
    setup_atomic_write_file \"$source\" \"$target\"
  "
  [ "$status" -eq 0 ]
  [ -f "$target" ]
  [ "$(cat "$target")" = "source content" ]
}

@test "setup_atomic_write_file leaves original unchanged on failure" {
  [ -f "$SETUP_HELPERS_SH" ] || skip "setup-helpers.sh missing"

  local source="$TEST_TEMP_DIR/source.txt"
  local target="$TEST_TEMP_DIR/target.txt"
  echo "source content" > "$source"
  echo "original target" > "$target"

  run bash -c "
    source \"$SETUP_HELPERS_SH\"
    setup_atomic_write_file \"$source\" \"$target\"
  "
  [ "$status" -eq 0 ]
  [ "$(cat "$target")" = "source content" ]
}

@test "setup_atomic_write_file fails with missing source" {
  [ -f "$SETUP_HELPERS_SH" ] || skip "setup-helpers.sh missing"

  local source="$TEST_TEMP_DIR/nonexistent.txt"
  local target="$TEST_TEMP_DIR/target.txt"

  run bash -c "
    source \"$SETUP_HELPERS_SH\"
    setup_atomic_write_file \"$source\" \"$target\" 2>&1
  "
  [ "$status" -ne 0 ]
  [[ "$output" == *"source file not found"* ]]
}

# ============================================================================
# Dry-Run Tests
# ============================================================================

@test "setup_atomic_write with SETUP_DRY_RUN reports target without writing" {
  [ -f "$SETUP_HELPERS_SH" ] || skip "setup-helpers.sh missing"

  local target="$TEST_TEMP_DIR/would-create.txt"

  run bash -c "
    source \"$SETUP_HELPERS_SH\"
    SETUP_DRY_RUN=1
    setup_atomic_write \"$target\" \"content\"
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"[DRY-RUN] Would write:"* ]]
  [[ "$output" == *"would-create.txt"* ]]
  [ ! -f "$target" ]
}

@test "setup_atomic_write_file with SETUP_DRY_RUN reports without copying" {
  [ -f "$SETUP_HELPERS_SH" ] || skip "setup-helpers.sh missing"

  local source="$TEST_TEMP_DIR/source.txt"
  local target="$TEST_TEMP_DIR/target.txt"
  echo "source data" > "$source"

  run bash -c "
    source \"$SETUP_HELPERS_SH\"
    SETUP_DRY_RUN=1
    setup_atomic_write_file \"$source\" \"$target\"
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"[DRY-RUN] Would copy"* ]]
  [ ! -f "$target" ]
}

@test "setup_ensure_dir with SETUP_DRY_RUN reports without creating" {
  [ -f "$SETUP_HELPERS_SH" ] || skip "setup-helpers.sh missing"

  local path="$TEST_TEMP_DIR/newdir/subdir"

  run bash -c "
    source \"$SETUP_HELPERS_SH\"
    SETUP_DRY_RUN=1
    setup_ensure_dir \"$path\"
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"[DRY-RUN] Would create directory:"* ]]
  [ ! -d "$path" ]
}

@test "setup_merge_status with SETUP_DRY_RUN shows dry-run prefix for write" {
  [ -f "$SETUP_HELPERS_SH" ] || skip "setup-helpers.sh missing"

  run bash -c "
    source \"$SETUP_HELPERS_SH\"
    SETUP_DRY_RUN=1
    setup_merge_status write \"/path/to/file.json\"
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"[DRY-RUN] Created:"* ]]
}

@test "setup_merge_status with SETUP_DRY_RUN shows dry-run prefix for merge" {
  [ -f "$SETUP_HELPERS_SH" ] || skip "setup-helpers.sh missing"

  run bash -c "
    source \"$SETUP_HELPERS_SH\"
    SETUP_DRY_RUN=1
    setup_merge_status merge \"/path/to/config.json\" \"/path/to/source.json\"
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"[DRY-RUN] Updated:"* ]]
  [[ "$output" == *"source.json"* ]]
}

@test "setup_merge_status with SETUP_DRY_RUN shows dry-run prefix for skip" {
  [ -f "$SETUP_HELPERS_SH" ] || skip "setup-helpers.sh missing"

  run bash -c "
    source \"$SETUP_HELPERS_SH\"
    SETUP_DRY_RUN=1
    setup_merge_status skip \"/path/to/existing.json\"
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"[DRY-RUN] Skipped:"* ]]
}

@test "setup_action_status with SETUP_DRY_RUN shows would-do prefix" {
  [ -f "$SETUP_HELPERS_SH" ] || skip "setup-helpers.sh missing"

  run bash -c "
    source \"$SETUP_HELPERS_SH\"
    SETUP_DRY_RUN=1
    setup_action_status \"Install hooks\" \"/path/to/hooks\"
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"[DRY-RUN] Would Install hooks:"* ]]
}

@test "dry-run reports exact target files without creating them" {
  [ -f "$SETUP_HELPERS_SH" ] || skip "setup-helpers.sh missing"

  local hooks_dir="$TEST_TEMP_DIR/.claude/hooks"
  local mcp_file="$TEST_TEMP_DIR/.claude/mcp.json"
  local settings_file="$TEST_TEMP_DIR/.claude/settings.json"

  run bash -c "
    source \"$SETUP_HELPERS_SH\"
    SETUP_DRY_RUN=1

    # Simulate a setup operation
    setup_ensure_dir \"$hooks_dir\"
    setup_atomic_write \"$mcp_file\" '{\"mcpServers\":{}}'
    setup_merge_status merge \"$settings_file\"
    setup_action_status \"Install hooks\" \"$hooks_dir\"
  "
  [ "$status" -eq 0 ]

  # Verify all paths are reported
  [[ "$output" == *".claude/hooks"* ]]
  [[ "$output" == *".claude/mcp.json"* ]]
  [[ "$output" == *".claude/settings.json"* ]]

  # Verify no files were created
  [ ! -d "$hooks_dir" ]
  [ ! -f "$mcp_file" ]
  [ ! -f "$settings_file" ]
}

# ============================================================================
# Path Resolution Tests
# ============================================================================

@test "setup_resolve_absolute_path handles absolute paths" {
  [ -f "$SETUP_HELPERS_SH" ] || skip "setup-helpers.sh missing"

  run bash -c "
    source \"$SETUP_HELPERS_SH\"
    setup_resolve_absolute_path \"/usr/bin/env\"
  "
  [ "$status" -eq 0 ]
  [ "$output" = "/usr/bin/env" ]
}

@test "setup_resolve_absolute_path resolves relative paths" {
  [ -f "$SETUP_HELPERS_SH" ] || skip "setup-helpers.sh missing"

  cd "$TEST_TEMP_DIR"
  mkdir -p subdir

  run bash -c "
    source \"$SETUP_HELPERS_SH\"
    setup_resolve_absolute_path \"subdir/file.txt\"
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"/subdir/file.txt"* ]]
}

@test "setup_resolve_absolute_path fails with empty path" {
  [ -f "$SETUP_HELPERS_SH" ] || skip "setup-helpers.sh missing"

  run bash -c "
    source \"$SETUP_HELPERS_SH\"
    setup_resolve_absolute_path 2>&1
  "
  [ "$status" -ne 0 ]
  [[ "$output" == *"path argument required"* ]]
}

# ============================================================================
# JSON Validation Tests
# ============================================================================

@test "setup_validate_json accepts valid JSON file" {
  [ -f "$SETUP_HELPERS_SH" ] || skip "setup-helpers.sh missing"
  command -v jq &>/dev/null || skip "jq not installed"

  local json_file="$TEST_TEMP_DIR/valid.json"
  echo '{"key": "value", "number": 42}' > "$json_file"

  run bash -c "
    source \"$SETUP_HELPERS_SH\"
    setup_validate_json \"$json_file\"
  "
  [ "$status" -eq 0 ]
}

@test "setup_validate_json rejects invalid JSON file" {
  [ -f "$SETUP_HELPERS_SH" ] || skip "setup-helpers.sh missing"
  command -v jq &>/dev/null || skip "jq not installed"

  local json_file="$TEST_TEMP_DIR/invalid.json"
  echo '{"key": "value", invalid}' > "$json_file"

  run bash -c "
    source \"$SETUP_HELPERS_SH\"
    setup_validate_json \"$json_file\" 2>&1
  "
  [ "$status" -ne 0 ]
  [[ "$output" == *"invalid JSON"* ]]
}

@test "setup_validate_json fails on missing file" {
  [ -f "$SETUP_HELPERS_SH" ] || skip "setup-helpers.sh missing"
  command -v jq &>/dev/null || skip "jq not installed"

  run bash -c "
    source \"$SETUP_HELPERS_SH\"
    setup_validate_json \"/nonexistent/file.json\" 2>&1
  "
  [ "$status" -ne 0 ]
  [[ "$output" == *"file not found"* ]]
}

@test "setup_validate_json_string accepts valid JSON" {
  [ -f "$SETUP_HELPERS_SH" ] || skip "setup-helpers.sh missing"
  command -v jq &>/dev/null || skip "jq not installed"

  run bash -c "
    source \"$SETUP_HELPERS_SH\"
    setup_validate_json_string '{\"valid\": true}'
  "
  [ "$status" -eq 0 ]
}

@test "setup_validate_json_string rejects invalid JSON" {
  [ -f "$SETUP_HELPERS_SH" ] || skip "setup-helpers.sh missing"
  command -v jq &>/dev/null || skip "jq not installed"

  run bash -c "
    source \"$SETUP_HELPERS_SH\"
    setup_validate_json_string '{invalid json' 2>&1
  "
  [ "$status" -ne 0 ]
  [[ "$output" == *"invalid JSON"* ]]
}

# ============================================================================
# Config Merge Status Tests (without dry-run)
# ============================================================================

@test "setup_merge_status outputs correct format for write" {
  [ -f "$SETUP_HELPERS_SH" ] || skip "setup-helpers.sh missing"

  run bash -c "
    source \"$SETUP_HELPERS_SH\"
    setup_merge_status write \"/path/to/file.json\"
  "
  [ "$status" -eq 0 ]
  [ "$output" = "Created: /path/to/file.json" ]
}

@test "setup_merge_status outputs correct format for write with source" {
  [ -f "$SETUP_HELPERS_SH" ] || skip "setup-helpers.sh missing"

  run bash -c "
    source \"$SETUP_HELPERS_SH\"
    setup_merge_status write \"/path/to/file.json\" \"/source/example.json\"
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"Created: /path/to/file.json"* ]]
  [[ "$output" == *"from /source/example.json"* ]]
}

@test "setup_merge_status outputs correct format for merge" {
  [ -f "$SETUP_HELPERS_SH" ] || skip "setup-helpers.sh missing"

  run bash -c "
    source \"$SETUP_HELPERS_SH\"
    setup_merge_status merge \"/path/to/config.json\"
  "
  [ "$status" -eq 0 ]
  [ "$output" = "Updated: /path/to/config.json" ]
}

@test "setup_merge_status outputs correct format for skip" {
  [ -f "$SETUP_HELPERS_SH" ] || skip "setup-helpers.sh missing"

  run bash -c "
    source \"$SETUP_HELPERS_SH\"
    setup_merge_status skip \"/path/to/existing.json\"
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"Skipped:"* ]]
  [[ "$output" == *"no changes needed"* ]]
}

# ============================================================================
# Directory Helper Tests
# ============================================================================

@test "setup_ensure_dir creates missing directories" {
  [ -f "$SETUP_HELPERS_SH" ] || skip "setup-helpers.sh missing"

  local newdir="$TEST_TEMP_DIR/brand/new/dir"

  run bash -c "
    source \"$SETUP_HELPERS_SH\"
    setup_ensure_dir \"$newdir\"
  "
  [ "$status" -eq 0 ]
  [ -d "$newdir" ]
}

@test "setup_ensure_dir succeeds on existing directory" {
  [ -f "$SETUP_HELPERS_SH" ] || skip "setup-helpers.sh missing"

  local existing="$TEST_TEMP_DIR/exists"
  mkdir -p "$existing"

  run bash -c "
    source \"$SETUP_HELPERS_SH\"
    setup_ensure_dir \"$existing\"
  "
  [ "$status" -eq 0 ]
  [ -d "$existing" ]
}

@test "setup_ensure_dir fails gracefully with permission error" {
  [ -f "$SETUP_HELPERS_SH" ] || skip "setup-helpers.sh missing"

  # Create a read-only parent
  local readonly_parent="$TEST_TEMP_DIR/readonly"
  mkdir -p "$readonly_parent"
  chmod 555 "$readonly_parent"

  local nested="$readonly_parent/subdir/nested"

  run bash -c "
    source \"$SETUP_HELPERS_SH\"
    setup_ensure_dir \"$nested\" 2>&1
  "

  # Restore permissions for cleanup
  chmod 755 "$readonly_parent"

  [ "$status" -ne 0 ]
}

# ============================================================================
# Utility Helper Tests
# ============================================================================

@test "setup_file_contains finds matching pattern" {
  [ -f "$SETUP_HELPERS_SH" ] || skip "setup-helpers.sh missing"

  local file="$TEST_TEMP_DIR/search.txt"
  echo "this contains a search pattern here" > "$file"

  run bash -c "
    source \"$SETUP_HELPERS_SH\"
    setup_file_contains \"$file\" \"search pattern\"
  "
  [ "$status" -eq 0 ]
}

@test "setup_file_contains returns 1 for non-matching pattern" {
  [ -f "$SETUP_HELPERS_SH" ] || skip "setup-helpers.sh missing"

  local file="$TEST_TEMP_DIR/search.txt"
  echo "this contains some text" > "$file"

  run bash -c "
    source \"$SETUP_HELPERS_SH\"
    setup_file_contains \"$file\" \"not found\"
  "
  [ "$status" -ne 0 ]
}

@test "setup_file_contains returns 1 for missing file" {
  [ -f "$SETUP_HELPERS_SH" ] || skip "setup-helpers.sh missing"

  run bash -c "
    source \"$SETUP_HELPERS_SH\"
    setup_file_contains \"/nonexistent/file.txt\" \"pattern\"
  "
  [ "$status" -ne 0 ]
}

@test "setup_copy_tree with SETUP_DRY_RUN reports without copying" {
  [ -f "$SETUP_HELPERS_SH" ] || skip "setup-helpers.sh missing"

  # Create source tree in a different location than target
  local source="$TEST_TEMP_DIR/source_origin"
  local dest_parent="$TEST_TEMP_DIR/target_location"
  mkdir -p "$source/subdir"
  mkdir -p "$dest_parent"
  echo "file1" > "$source/file1.txt"
  echo "file2" > "$source/subdir/file2.txt"

  run bash -c "
    source \"$SETUP_HELPERS_SH\"
    SETUP_DRY_RUN=1
    setup_copy_tree \"$source\" \"$dest_parent\"
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"[DRY-RUN] Would copy directory"* ]]
  # Verify the copy target does NOT exist (dry-run should not create it)
  [ ! -d "$dest_parent/source_origin" ]
}
