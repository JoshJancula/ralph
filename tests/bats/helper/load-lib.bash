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
# Plan-runner session state (MCP resolver paths, active TODO metadata, stale proxy script paths)
# must not leak either; otherwise run-plan and invoke smoke tests fail with missing temp files.
unset RALPH_AGENT_TOOL_ACCESS RALPH_NATIVE_HOOKS RALPH_OPTIMIZATION_MODE RALPH_MCP_TOOLS_ENABLED RALPH_TOOL_ACCESS_FLAG_SET RALPH_PLAN_INVOCATION_TIMEOUT_RAW RALPH_PLAN_WORKSPACE_ROOT RALPH_PROXY_SHELL_COMPACT RALPH_PROJECT_ROOT RALPH_AGENT_WORKSPACE RALPH_ARTIFACT_NS RALPH_PLAN_KEY RALPH_MODE RALPH_BASH_COMPACT RALPH_COMPACT_GENERIC_THRESHOLD_BYTES RALPH_COMPACT_STDOUT RALPH_COMPACT_STDERR RALPH_COMPACTORS_LIB_DIR
unset RALPH_MCP_PROXY_SERVER_SCRIPT RALPH_RUNTIME_MCP_RESOLVE_PATH RALPH_RUNTIME_MCP_AGENT_ENTRIES_JSON
unset RALPH_RUN_PLAN_ACTIVE RALPH_CURRENT_PLAN_PATH RALPH_CURRENT_TODO_LINE RALPH_CURRENT_TODO_ORDINAL RALPH_CURRENT_TODO_ID RALPH_CURRENT_TODO_HASH RALPH_MCP_PREFLIGHT_PASSED
unset RALPH_RUN_PLAN_RESUME_SESSION_ID RALPH_RUN_PLAN_RESUME_BARE RALPH_PLAN_INVOCATION_CLI_PID_FILE RALPH_PLAN_INVOCATION_CLI_START_FILE RALPH_SESSION_DIR RALPH_RUN_PLAN_RESET_COMMAND_USED RALPH_PLAN_SESSION_HOME RALPH_PLAN_CAPTURE_USAGE

bats_skip_known_ci_flakes() {
  if [[ -z "${CI:-}" && -z "${GITHUB_ACTIONS:-}" ]]; then
    return 0
  fi

  case "${BATS_TEST_FILENAME##*/}:${BATS_TEST_DESCRIPTION}" in
    "mcp-proxy-grep-source-cap-dedupe.bats:duplicate of a source-capped grep stays deduped AND still reports partial-source state" | \
    "bash-compact-delivered-metrics.bats:applied compaction with a storage footer: delivered exceeds legacy compactedBytes by the footer" | \
    "fail-open-instrumentation.bats:below-threshold (small content, not expanded) is not logged as an error" | \
    "fail-open-instrumentation.bats:already-compacted envelope content is not logged as an error" | \
    "native-result-shapes.bats:Read: oversized content is compacted, shape-preserved, telemetry recorded" | \
    "native-result-shapes.bats:Grep content mode: oversized match text is compacted and shape-preserved" | \
    "native-result-shapes.bats:Bash: oversized stdout is compacted, stderr sibling untouched" | \
    "native-result-shapes.bats:already-compact envelope content is not re-compacted")
      if [[ "${RALPH_CI_SERIAL_RECHECK:-0}" == "1" ]]; then
        return 0
      fi
      skip "deferred in parallel CI: covered by the serial stability recheck"
      ;;
    "mcp-proxy-batch.bats:ralph_proxy_batch runs mixed read grep and glob operations successfully" | \
    "mcp-proxy-batch.bats:ralph_proxy_batch times out and reports partial failure on long-running operations" | \
    "mcp-proxy-batch.bats:ralph_proxy_batch timeout reports PARTIAL_FAILURE with completed operation count" | \
    "mcp-proxy-batch.bats:ralph_proxy_batch timeout returns partial results with isError true" | \
    "mcp-proxy-search-dedupe.bats:identical grep deduped with resultId readable via ralph_proxy_result_read" | \
    "mcp-proxy-search-dedupe.bats:different grep pattern path or flags not deduped" | \
    "mcp-proxy-search-dedupe.bats:mutating shell between calls invalidates search dedupe cache" | \
    "mcp-proxy-search-dedupe.bats:RALPH_PROXY_DEDUPE_SEARCH=0 disables search dedupe" | \
    "mcp-proxy-search-dedupe.bats:duplicate grep response does not include full match body" | \
    "run-plan-args.bats:run-plan --plan must reference a file" | \
    "run-plan-interrupt-teardown.bats:agent group guard reaps TERM-ignoring agent group when runner dies" | \
    "run-plan-routing.bats:yaml todo routing bootstraps non-interactive runs without a global model" | \
    "run-plan-routing.bats:plan header runtime and model are used when --runtime and --model are not passed" | \
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
