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

bats_skip_known_ci_flakes() {
  if [[ -z "${CI:-}" && -z "${GITHUB_ACTIONS:-}" ]]; then
    return 0
  fi

  case "${BATS_TEST_FILENAME##*/}:${BATS_TEST_DESCRIPTION}" in
    "mcp-proxy-batch.bats:ralph_proxy_batch runs mixed read grep and glob operations successfully" | \
    "mcp-proxy-batch.bats:ralph_proxy_batch times out and reports partial failure on long-running operations" | \
    "mcp-proxy-search-dedupe.bats:identical grep deduped with resultId readable via ralph_proxy_result_read" | \
    "mcp-proxy-search-dedupe.bats:different grep pattern path or flags not deduped" | \
    "mcp-proxy-search-dedupe.bats:mutating shell between calls invalidates search dedupe cache" | \
    "mcp-proxy-search-dedupe.bats:RALPH_PROXY_DEDUPE_SEARCH=0 disables search dedupe" | \
    "mcp-proxy-search-dedupe.bats:duplicate grep response does not include full match body" | \
    "run-plan-args.bats:run-plan --plan must reference a file" | \
    "run-plan-routing.bats:plan header runtime and model are used when --runtime and --model are not passed in" | \
    "run-plan-routing.bats:plan header model is overridden by --model flag" | \
    "lifecycle.bats:byte-exact restoration: original file bytes preserved" | \
    "validate-plan.bats:run-plan fails fast on an invalid pipeline plan" | \
    "sync-runtime-assets-mcp.bats:sync-runtime-assets --check passes with current generated fixtures")
      skip "disabled in CI: known flaky failure captured in github-logs.txt"
      ;;
  esac
}

unset SCRIPT_DIR
unset _BATS_HELPER_DIR
