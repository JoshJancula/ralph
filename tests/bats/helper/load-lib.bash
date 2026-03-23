#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
export REPO_ROOT
RALPH_LIB_ROOT="$REPO_ROOT/.ralph/bash-lib"
export RALPH_LIB_ROOT
export RALPH_USAGE_RISKS_ACKNOWLEDGED=1
# Avoid interactive CLI session resume prompts when run-plan is invoked from Bats (TTY + blocking read).
export RALPH_PLAN_CLI_RESUME=0
export PATH="$REPO_ROOT/tests/bats/bin:$PATH"
