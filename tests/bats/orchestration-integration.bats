#!/usr/bin/env bats

# Integration tests for orchestration with subdirectory structure
# Tests that .ralph/orchestrator.sh can parse and execute with new paths

setup() {
  export WORKSPACE="$(pwd)"
}

teardown() {
  # Clean up test logs
  rm -f "$WORKSPACE/.agents/logs/orchestrator-test-*.log" 2>/dev/null || true
}

