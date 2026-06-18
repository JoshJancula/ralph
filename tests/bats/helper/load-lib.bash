#!/usr/bin/env bash
set -euo pipefail

_BATS_HELPER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$_BATS_HELPER_DIR/../../.." && pwd)"
export REPO_ROOT
RALPH_LIB_ROOT="$REPO_ROOT/.ralph/bash-lib"
export RALPH_LIB_ROOT
export RALPH_USAGE_RISKS_ACKNOWLEDGED=1
# Avoid interactive CLI session resume prompts when run-plan is invoked from Bats (TTY + blocking read).
export RALPH_PLAN_CLI_RESUME=0
# Fast poll interval for agent monitoring in tests (overrides 1s production default).
export RALPH_PLAN_AGENT_POLL_INTERVAL=0.1
export PATH="$REPO_ROOT/tests/bats/bin:$PATH"
# Removed public knobs must not leak from the operator shell into Bats (fail-fast in parse_args).
unset RALPH_AGENT_TOOL_ACCESS RALPH_NATIVE_HOOKS RALPH_OPTIMIZATION_MODE RALPH_MCP_TOOLS_ENABLED RALPH_TOOL_ACCESS_FLAG_SET RALPH_PLAN_INVOCATION_TIMEOUT_RAW RALPH_PLAN_WORKSPACE_ROOT RALPH_PROXY_SHELL_COMPACT RALPH_PROJECT_ROOT RALPH_AGENT_WORKSPACE RALPH_ARTIFACT_NS RALPH_PLAN_KEY RALPH_MODE RALPH_BASH_COMPACT RALPH_COMPACT_GENERIC_THRESHOLD_BYTES RALPH_COMPACT_STDOUT RALPH_COMPACT_STDERR RALPH_COMPACTORS_LIB_DIR

unset SCRIPT_DIR
unset _BATS_HELPER_DIR
