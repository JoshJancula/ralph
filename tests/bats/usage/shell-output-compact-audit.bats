#!/usr/bin/env bats

source "$BATS_TEST_DIRNAME/../helper/load-lib.bash"

setup() {
  export TMPDIR="$BATS_TEST_TMPDIR"
  TEST_WORKSPACE="$TMPDIR/test-workspace"
  mkdir -p "$TEST_WORKSPACE/.ralph-workspace/sessions/TESTPLAN"
  mkdir -p "$TEST_WORKSPACE/.ralph-workspace/logs/TESTPLAN"
  AUDIT_SCRIPT="$REPO_ROOT/bundle/.ralph/python/shell-output-compact-audit.py"
}

teardown() {
  if [[ -d "$TEST_WORKSPACE" ]]; then
    rm -rf "$TEST_WORKSPACE"
  fi
}

@test "audit mode reports potential savings from large tool-result blobs" {
  command -v python3 >/dev/null || skip "python3 required"
  command -v jq >/dev/null || skip "jq required"

  # Create a session file with a large uncompressed output
  session_file="$TEST_WORKSPACE/.ralph-workspace/sessions/TESTPLAN/tool-results.jsonl"
  cat > "$session_file" <<'EOF'
{"command": "bats", "stdout": "1..10\nok 1 test\nok 2 test\nok 3 test\nok 4 test\nok 5 test\nok 6 test\nok 7 test\nok 8 test\nok 9 test\nok 10 test\n", "stderr": "", "exit_status": 0}
EOF

  # Run audit
  output="$(python3 "$AUDIT_SCRIPT" \
    --workspace "$TEST_WORKSPACE" \
    --plan-key TESTPLAN 2>&1)"

  # Verify audit found savings
  printf '%s\n' "$output" | jq -e '
    .total_potential_savings_bytes > 0 and
    .scanned_files >= 1 and
    (.records | length) > 0 and
    .records[0].family_id == "bats"
  ' || {
    echo "Audit output:"
    echo "$output" | jq .
    return 1
  }
}

@test "audit mode handles missing session/log directories gracefully" {
  command -v python3 >/dev/null || skip "python3 required"
  command -v jq >/dev/null || skip "jq required"

  # Remove the directories
  rm -rf "$TEST_WORKSPACE/.ralph-workspace/sessions/TESTPLAN"
  rm -rf "$TEST_WORKSPACE/.ralph-workspace/logs/TESTPLAN"

  output="$(python3 "$AUDIT_SCRIPT" \
    --workspace "$TEST_WORKSPACE" \
    --plan-key TESTPLAN 2>&1)"

  # Should still succeed and report zero findings
  printf '%s\n' "$output" | jq -e '
    .scanned_files == 0 and
    (.records | length) == 0
  '
}

@test "audit mode leaves source files byte-for-byte unchanged" {
  command -v python3 >/dev/null || skip "python3 required"

  session_file="$TEST_WORKSPACE/.ralph-workspace/sessions/TESTPLAN/tool-results.jsonl"
  cat > "$session_file" <<'EOF'
{"command": "bats", "stdout": "1..5\nok 1 test\nok 2 test\nok 3 test\nok 4 test\nok 5 test\n", "stderr": "", "exit_status": 0}
EOF

  # Record original checksum
  original_md5="$(md5sum "$session_file" | awk '{print $1}')"

  # Run audit
  python3 "$AUDIT_SCRIPT" \
    --workspace "$TEST_WORKSPACE" \
    --plan-key TESTPLAN >/dev/null 2>&1

  # Verify file unchanged
  new_md5="$(md5sum "$session_file" | awk '{print $1}')"
  [[ "$original_md5" == "$new_md5" ]]
}

@test "audit mode handles malformed JSON gracefully" {
  command -v python3 >/dev/null || skip "python3 required"
  command -v jq >/dev/null || skip "jq required"

  # Create a file with mixed valid and invalid JSON
  session_file="$TEST_WORKSPACE/.ralph-workspace/sessions/TESTPLAN/mixed.jsonl"
  cat > "$session_file" <<'EOF'
{"command": "bats", "stdout": "1..10\nok 1 test\nok 2 test\nok 3 test\nok 4 test\nok 5 test\nok 6 test\nok 7 test\nok 8 test\nok 9 test\nok 10 test\n", "stderr": "", "exit_status": 0}
this is not json
{"command": "bats", "stdout": "1..5\nok 1 test\nok 2 test\nok 3 test\nok 4 test\nok 5 test\n", "stderr": "", "exit_status": 0}
EOF

  output="$(python3 "$AUDIT_SCRIPT" \
    --workspace "$TEST_WORKSPACE" \
    --plan-key TESTPLAN 2>&1)"

  # Should process valid records and report results
  printf '%s\n' "$output" | jq -e '
    (.records | length) > 0
  '
}

@test "audit mode detects shape-based compression opportunities" {
  command -v python3 >/dev/null || skip "python3 required"
  command -v jq >/dev/null || skip "jq required"

  # Create a log file with git diff-like output
  log_file="$TEST_WORKSPACE/.ralph-workspace/logs/TESTPLAN/git.jsonl"
  git_diff_output=$(cat <<'EOF'
diff --git a/file.txt b/file.txt
index 123456..abcdef 100644
--- a/file.txt
+++ b/file.txt
@@ -1,10 +1,10 @@
-old line 1
-old line 2
-old line 3
-old line 4
-old line 5
+new line 1
+new line 2
+new line 3
+new line 4
+new line 5
EOF
)

  jq -n \
    --arg stdout "$git_diff_output" \
    '{command: "", stdout: $stdout, stderr: "", exit_status: 0}' \
    > "$log_file"

  output="$(python3 "$AUDIT_SCRIPT" \
    --workspace "$TEST_WORKSPACE" \
    --plan-key TESTPLAN 2>&1)"

  # Should find compression opportunities even without command
  printf '%s\n' "$output" | jq -e '
    (.records | length) > 0
  ' || {
    echo "Audit output:"
    echo "$output" | jq .
    return 1
  }
}

@test "audit mode skips very small outputs" {
  command -v python3 >/dev/null || skip "python3 required"
  command -v jq >/dev/null || skip "jq required"

  # Create files with tiny outputs
  session_file="$TEST_WORKSPACE/.ralph-workspace/sessions/TESTPLAN/tiny.jsonl"
  cat > "$session_file" <<'EOF'
{"command": "echo hi", "stdout": "hi\n", "stderr": "", "exit_status": 0}
EOF

  output="$(python3 "$AUDIT_SCRIPT" \
    --workspace "$TEST_WORKSPACE" \
    --plan-key TESTPLAN 2>&1)"

  # Should report zero savings for tiny outputs
  printf '%s\n' "$output" | jq -e '
    .total_potential_savings_bytes == 0
  '
}

@test "audit mode outputs to file when --output is provided" {
  command -v python3 >/dev/null || skip "python3 required"
  command -v jq >/dev/null || skip "jq required"

  session_file="$TEST_WORKSPACE/.ralph-workspace/sessions/TESTPLAN/tool-results.jsonl"
  cat > "$session_file" <<'EOF'
{"command": "bats", "stdout": "1..10\nok 1 test\nok 2 test\nok 3 test\nok 4 test\nok 5 test\nok 6 test\nok 7 test\nok 8 test\nok 9 test\nok 10 test\n", "stderr": "", "exit_status": 0}
EOF

  output_file="$TMPDIR/audit-result.json"
  python3 "$AUDIT_SCRIPT" \
    --workspace "$TEST_WORKSPACE" \
    --plan-key TESTPLAN \
    --output "$output_file" >/dev/null 2>&1

  # Verify output file was created
  [[ -f "$output_file" ]]

  # Verify it contains valid JSON with results
  jq -e '.total_potential_savings_bytes > 0' "$output_file"
}

@test "audit mode returns 0 exit code even on errors (non-blocking)" {
  command -v python3 >/dev/null || skip "python3 required"

  # Run with non-existent workspace
  python3 "$AUDIT_SCRIPT" \
    --workspace "/nonexistent/workspace" \
    --plan-key TESTPLAN >/dev/null 2>&1

  # Should still return success
  [[ $? -eq 0 ]]
}

@test "audit mode includes classification method in records" {
  command -v python3 >/dev/null || skip "python3 required"
  command -v jq >/dev/null || skip "jq required"

  # Command-based classification
  session_file="$TEST_WORKSPACE/.ralph-workspace/sessions/TESTPLAN/cmd-classified.jsonl"
  cat > "$session_file" <<'EOF'
{"command": "bats", "stdout": "1..10\nok 1\nok 2\nok 3\nok 4\nok 5\nok 6\nok 7\nok 8\nok 9\nok 10\n", "stderr": "", "exit_status": 0}
EOF

  output="$(python3 "$AUDIT_SCRIPT" \
    --workspace "$TEST_WORKSPACE" \
    --plan-key TESTPLAN 2>&1)"

  printf '%s\n' "$output" | jq -e '
    .records[0].classification_method == "command"
  '
}

@test "audit mode preserves example previews without mutation" {
  command -v python3 >/dev/null || skip "python3 required"
  command -v jq >/dev/null || skip "jq required"

  session_file="$TEST_WORKSPACE/.ralph-workspace/sessions/TESTPLAN/examples.jsonl"
  test_stdout="1..3\nok 1 first test\nok 2 second test\nok 3 third test\n"
  cat > "$session_file" <<EOF
{"command": "bats test.bats", "stdout": "$test_stdout", "stderr": "", "exit_status": 0}
EOF

  output="$(python3 "$AUDIT_SCRIPT" \
    --workspace "$TEST_WORKSPACE" \
    --plan-key TESTPLAN 2>&1)"

  # Verify previews are present and contain example data
  printf '%s\n' "$output" | jq -e '
    (.records[0].example_command | length) > 0 and
    (.records[0].example_original_preview | length) > 0 and
    (.records[0].example_compacted_preview | length) > 0
  ' || {
    echo "Audit output:"
    echo "$output" | jq .
    return 1
  }
}

@test "audit mode aggregates savings across multiple files" {
  command -v python3 >/dev/null || skip "python3 required"
  command -v jq >/dev/null || skip "jq required"

  # Create multiple session files with compressible outputs
  session_file1="$TEST_WORKSPACE/.ralph-workspace/sessions/TESTPLAN/file1.jsonl"
  cat > "$session_file1" <<'EOF'
{"command": "bats", "stdout": "1..10\nok 1\nok 2\nok 3\nok 4\nok 5\nok 6\nok 7\nok 8\nok 9\nok 10\n", "stderr": "", "exit_status": 0}
EOF

  session_file2="$TEST_WORKSPACE/.ralph-workspace/sessions/TESTPLAN/file2.jsonl"
  cat > "$session_file2" <<'EOF'
{"command": "bats", "stdout": "1..5\nok 1 test\nok 2 test\nok 3 test\nok 4 test\nok 5 test\n", "stderr": "", "exit_status": 0}
EOF

  output="$(python3 "$AUDIT_SCRIPT" \
    --workspace "$TEST_WORKSPACE" \
    --plan-key TESTPLAN 2>&1)"

  # Verify multiple files were scanned
  printf '%s\n' "$output" | jq -e '
    .scanned_files >= 2 and
    (.records | length) >= 2
  '
}

@test "audit mode reports timestamp in UTC" {
  command -v python3 >/dev/null || skip "python3 required"
  command -v jq >/dev/null || skip "jq required"

  output="$(python3 "$AUDIT_SCRIPT" \
    --workspace "$TEST_WORKSPACE" \
    --plan-key TESTPLAN 2>&1)"

  # Verify timestamp is present and looks like ISO format
  printf '%s\n' "$output" | jq -e '
    (.timestamp | test("^\\d{4}-\\d{2}-\\d{2}T"))
  '
}
