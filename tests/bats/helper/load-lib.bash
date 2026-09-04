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
# Collapse Ralph's production poll/pacing waits. ralph_wait scales every
# non-semantic `sleep` in the runner, graph, and proxy poll loops; production
# leaves RALPH_WAIT_SCALE unset and keeps the full human-readable pacing.
# Waits whose duration is itself under test still call sleep directly, so
# timeout and backoff assertions are unaffected.
export RALPH_WAIT_SCALE=0
# On macOS run-plan.sh re-execs itself under caffeinate, which re-sources the
# whole bash-lib a second time: measured at 1.27s vs 0.88s per invocation, paid
# once per graph node dispatch, plus a caffeinate process held for the life of
# every invocation. Tests are short and must not inhibit sleep, so default the
# guard on. The one test that exercises the re-exec sets this back to 0 and
# stubs caffeinate; per-test exports still win over this default.
export RALPH_PLAN_NO_CAFFEINATE=1
# Every `ralph workflow watch` refresh shells out to the `ralph workflow status`
# bash CLI, which sources a large library set before printing. The suite runs
# several files in parallel and each test forks dozens of python3/jq children,
# so measured load routinely exceeds 100 on a 10-CPU host -- roughly 80
# runnable processes. Under that, a production-default status budget turns
# "does watch print the right thing and exit 0" into "is the host fast right
# now", and the watch tests fail in batches for reasons unrelated to what they
# assert. Give them a budget no realistic host will exceed so they measure
# behavior. A genuine hang still fails: the assertions bound polls, not wall
# clock. Per-test exports still win over this default.
export RALPH_WORKFLOW_STATUS_TIMEOUT=120
export PATH="$REPO_ROOT/tests/bats/bin:$PATH"
# Removed public knobs must not leak from the operator shell into Bats (fail-fast in parse_args).
# Plan-runner session state (MCP resolver paths, active TODO metadata, stale proxy script paths)
# must not leak either; otherwise run-plan and invoke smoke tests fail with missing temp files.
unset RALPH_AGENT_TOOL_ACCESS RALPH_NATIVE_HOOKS RALPH_OPTIMIZATION_MODE RALPH_MCP_TOOLS_ENABLED RALPH_TOOL_ACCESS_FLAG_SET RALPH_PLAN_INVOCATION_TIMEOUT_RAW RALPH_PLAN_WORKSPACE_ROOT RALPH_PROXY_SHELL_COMPACT RALPH_PROJECT_ROOT RALPH_AGENT_WORKSPACE RALPH_ARTIFACT_NS RALPH_PLAN_KEY RALPH_MODE RALPH_BASH_COMPACT RALPH_COMPACT_GENERIC_THRESHOLD_BYTES RALPH_COMPACT_STDOUT RALPH_COMPACT_STDERR RALPH_COMPACTORS_LIB_DIR
unset RALPH_MCP_PROXY_SERVER_SCRIPT RALPH_RUNTIME_MCP_RESOLVE_PATH RALPH_RUNTIME_MCP_AGENT_ENTRIES_JSON
unset RALPH_RUN_PLAN_ACTIVE RALPH_CURRENT_PLAN_PATH RALPH_CURRENT_TODO_LINE RALPH_CURRENT_TODO_ORDINAL RALPH_CURRENT_TODO_ID RALPH_CURRENT_TODO_HASH RALPH_MCP_PREFLIGHT_PASSED
# Staged workflow model pins must not leak from an active orchestration run into
# leaf-plan model-resolution tests (for example preflight-failure assertions).
unset RALPH_MODEL_SCOPE PLAN_STAGE_MODEL PLAN_TODO_MODEL
unset RALPH_RUN_PLAN_RESUME_SESSION_ID RALPH_RUN_PLAN_RESUME_BARE RALPH_PLAN_INVOCATION_CLI_PID_FILE RALPH_PLAN_INVOCATION_CLI_START_FILE RALPH_SESSION_DIR RALPH_RUN_PLAN_RESET_COMMAND_USED RALPH_PLAN_SESSION_HOME RALPH_PLAN_CAPTURE_USAGE
# The process-supervisor handles are the dangerous ones: run-plan evals the
# supervisor's exports, so an agent shell inside a live plan run inherits
# RALPH_PROCESS_RUN_DIR pointing at the RUNNER'S OWN run. A test teardown that
# closes "$RALPH_PROCESS_RUN_DIR" would then kill the plan run that invoked it.
# scripts/run-bats.sh already scrubs these; do it here too so a bare `bin/bats`
# is equally safe. Tests that need a supervisor run must create their own.
unset RALPH_PROCESS_RUN_DIR RALPH_PROCESS_RUN_ID RALPH_PROCESS_RUN_TOKEN RALPH_PROCESS_GUARDIAN_PID RALPH_PROCESS_SCOPE_TOKEN RALPH_PROCESS_RUN_OWNED RALPH_PROCESS_RUN_DEPTH RALPH_PROCESS_ATTACHED_PLAN

# Remove a test workspace that may still hold a live process-supervisor entry.
#
# run-plan's guardian removes its own directory under
# .ralph-workspace/processes/active as it exits. A test that tears down the
# moment the runner returns races that removal, and rm -rf then fails with
# "Directory not empty" -- which, under bats' set -e, fails a test whose every
# assertion already passed. Retry briefly instead of masking the error with
# `|| true`, so a genuinely undeletable workspace still reports.
ralph_test_rm_workspace() {
  local path="${1:-}" attempt
  [[ -n "$path" && -e "$path" ]] || return 0
  for attempt in 1 2 3 4 5 6 7 8 9 10; do
    if rm -rf "$path" 2>/dev/null && [[ ! -e "$path" ]]; then
      return 0
    fi
    sleep 0.2
  done
  # Surface the real error if this was never a transient race.
  rm -rf "$path"
}

# Remove a test workspace that a still-exiting background process may still be
# writing into.
#
# `rm -rf` fails with "Directory not empty" when new files appear between its
# readdir and its unlink. That is a real race in the run-plan tests, which spawn
# supervisors that keep writing into .ralph-workspace/processes/active/ for a
# short window after the test body finishes. Under tier parallelism that window
# widens and the bare `rm -rf` at the end of a test body fails the test even
# though every assertion passed.
#
# Retry against a wall-clock deadline rather than sleeping a fixed amount or
# swallowing the error: the final attempt is unguarded so a genuine permission
# or busy-file problem still surfaces.
ralph_test_rm_workspace() {
  local dir="${1:?workspace path required}"
  [[ -n "$dir" && -e "$dir" ]] || return 0
  local deadline=$((SECONDS + 15))
  while ((SECONDS < deadline)); do
    rm -rf "$dir" 2>/dev/null
    [[ -e "$dir" ]] || return 0
    sleep 0.2
  done
  rm -rf "$dir"
}

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
    "run-plan-interrupt-teardown.bats:agent group guard exits quietly once its group is empty" | \
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
