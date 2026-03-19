#!/usr/bin/env bats

# Integration tests for orchestration with root-level JSON files
# Tests that .ralph/orchestrator.sh can parse and execute from the repository root

setup() {
  export WORKSPACE="$(pwd)"
}

teardown() {
  # Clean up test logs
  rm -f "$WORKSPACE/.agents/logs/orchestrator-test-*.log" 2>/dev/null || true
  rm -f "$WORKSPACE/dashboard.orch.json" 2>/dev/null || true
}

