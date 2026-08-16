#!/usr/bin/env bash
# Run the Ralph Bats suite (fixtures + bats -T via bin/bats).
#
# Usage:
#   bash scripts/run-bats.sh [options] [--] [bats arguments...]
#
# Examples:
#   bash scripts/run-bats.sh
#   bash scripts/run-bats.sh tests/bats/mcp/mcp-setup.bats
#   bash scripts/run-bats.sh -j 4 tests/bats/agent-config-tool.bats
#   bash scripts/run-bats.sh -- --filter "ralph_run_plan"
#   bash scripts/run-bats.sh --list-suite

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
BATS_BIN="$REPO_ROOT/bin/bats"
# shellcheck source=scripts/bats-suite-lib.sh
source "$SCRIPT_DIR/bats-suite-lib.sh"

SETUP_FIXTURES=1
JOBS=""
JOBS_EXPLICIT=0
LIST_SUITE=0
BATS_ARGS=()
USER_PATHS=0

has_parallel_runner() {
  command -v parallel &>/dev/null || command -v rush &>/dev/null
}

detect_cpu_count() {
  local n=1
  if command -v nproc &>/dev/null; then
    n="$(nproc)"
  elif [[ "$(uname -s 2>/dev/null || true)" == "Darwin" ]] && command -v sysctl &>/dev/null; then
    n="$(sysctl -n hw.ncpu 2>/dev/null || echo 1)"
  elif command -v getconf &>/dev/null; then
    n="$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 1)"
  fi
  if [[ ! "$n" =~ ^[1-9][0-9]*$ ]]; then
    n=1
  fi
  echo "$n"
}

default_parallel_jobs() {
  local cpus="$1"
  if [[ "$cpus" -gt 8 ]]; then
    echo 8
  else
    echo "$cpus"
  fi
}

# Count the .bats files the run will execute, expanding directory arguments.
# Flags and their values are skipped; only path-shaped arguments are counted.
bats_target_file_count() {
  local arg count=0
  for arg in "$@"; do
    [[ "$arg" == -* ]] && continue
    if [[ -d "$arg" ]]; then
      count=$((count + $(find "$arg" -name '*.bats' -type f | wc -l)))
    elif [[ "$arg" == *.bats ]]; then
      count=$((count + 1))
    fi
  done
  echo "$count"
}

# Bats does not recursively expand directory operands in every execution mode.
# In particular, a directory passed with file-parallel execution can produce a
# successful `1..0` run. Expand directories ourselves so the files counted by
# bats_target_file_count are exactly the files handed to Bats.
expand_bats_directory_args() {
  local arg file
  local -a expanded=()
  for arg in "${BATS_ARGS[@]}"; do
    if [[ -d "$arg" ]]; then
      while IFS= read -r file; do
        [[ -n "$file" ]] && expanded+=("$file")
      done < <(find "$arg" -name '*.bats' -type f | LC_ALL=C sort)
    else
      expanded+=("$arg")
    fi
  done
  BATS_ARGS=("${expanded[@]}")
}

# bats -j N does not cap total concurrency: bats-exec-suite runs N files under
# GNU parallel and passes -j N down to each bats-exec-file, which runs N tests
# of its own. With N files in flight that is N*N concurrent tests -- `-j 8`
# over 13 files peaked at ~64 tests on a 10-core box, driving load past 100,
# stretching individual graph tests to 2-5 minutes, and producing spurious
# timing failures in graph-resilience/-operator-schedule/-recovery that all
# pass under a bounded run. Parallelizing across files only keeps total
# concurrency at N. A single-file run still parallelizes within the file,
# which is the only way to use -j there.
bats_parallel_flags() {
  local jobs="$1"
  shift
  [[ "$jobs" -gt 1 ]] || return 0
  [[ "$(bats_target_file_count "$@")" -gt 1 ]] || return 0
  local arg
  for arg in "$@"; do
    case "$arg" in
      --no-parallelize-within-files | --no-parallelize-across-files) return 0 ;;
    esac
  done
  echo "--no-parallelize-within-files"
}

usage() {
  cat <<'EOF'
Usage: bash scripts/run-bats.sh [options] [--] [bats arguments...]

Options:
  -j N, --jobs N        Run up to N tests in parallel. Requires GNU parallel or
                        rush on PATH. When omitted and a parallel runner is
                        available, defaults to min(8, available CPUs).
  --list-suite          Print the test file paths for the suite and exit.
  --no-setup-fixtures   Skip scripts/setup-test-fixtures.sh
  -h, --help            Show this help

When no test paths are given, runs all tests/bats/**/*.bats except tests/bats/local/.
EOF
}

populate_suite_paths() {
  local -a paths=()
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    paths+=("$line")
  done < <(ralph_bats_suite_files "$REPO_ROOT")
  if [[ ${#paths[@]} -eq 0 ]]; then
    echo "run-bats: no test files found" >&2
    return 1
  fi
  BATS_ARGS=("${paths[@]}")
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h | --help)
      usage
      exit 0
      ;;
    -j | --jobs)
      if [[ $# -lt 2 ]]; then
        echo "run-bats: -j/--jobs requires an argument" >&2
        exit 1
      fi
      JOBS="$2"
      JOBS_EXPLICIT=1
      shift 2
      ;;
    --suite)
      echo "run-bats: --suite is no longer supported; the extended tier was removed" >&2
      exit 1
      ;;
    --list-suite)
      LIST_SUITE=1
      shift
      ;;
    --no-setup-fixtures)
      SETUP_FIXTURES=0
      shift
      ;;
    --)
      shift
      BATS_ARGS+=("$@")
      USER_PATHS=1
      break
      ;;
    -*)
      echo "run-bats: unknown option: $1" >&2
      usage >&2
      exit 1
      ;;
    *)
      BATS_ARGS+=("$@")
      USER_PATHS=1
      break
      ;;
  esac
done

if [[ "$LIST_SUITE" -eq 1 ]]; then
  if [[ "$USER_PATHS" -eq 1 ]]; then
    printf '%s\n' "${BATS_ARGS[@]}"
  else
    ralph_bats_suite_files "$REPO_ROOT"
  fi
  exit 0
fi

if [[ "$USER_PATHS" -eq 0 ]]; then
  populate_suite_paths
fi

expand_bats_directory_args
if [[ ${#BATS_ARGS[@]} -eq 0 ]]; then
  echo "run-bats: no test files found for the requested paths" >&2
  exit 1
fi

if [[ ! -x "$BATS_BIN" ]]; then
  echo "run-bats: missing executable $BATS_BIN" >&2
  exit 127
fi

cd "$REPO_ROOT"

# Start the suite from a clean Ralph runtime state so inherited agent-shell
# exports do not leak into test subprocesses.
unset WORKSPACE OUTPUT_LOG LOG_FILE PROMPT_STATIC SESSION_ID_FILE SESSION_ID_FILE_LEGACY USAGE_FILE EXIT_CODE_FILE
unset RALPH_AGENT_TOOL_ACCESS RALPH_NATIVE_HOOKS RALPH_OPTIMIZATION_MODE RALPH_MCP_TOOLS_ENABLED RALPH_TOOL_ACCESS_FLAG_SET
unset RALPH_PLAN_SESSION_HOME RALPH_SESSION_DIR RALPH_PLAN_KEY RALPH_ARTIFACT_NS RALPH_PROJECT_ROOT RALPH_AGENT_WORKSPACE RALPH_PLAN_WORKSPACE_ROOT RALPH_RUNTIME_ROOT
unset RALPH_SHARED_RALPH_DIR RALPH_DIR RALPH_LAUNCHER_PID RALPH_BASH_COMPACT_LOG RALPH_BASH_REWRITE_LOG
unset RALPH_PROXY_SHELL_COMPACT_LOG RALPH_MCP_PREFLIGHT_PASSED RALPH_NATIVE_SHELL_WRAPPER RALPH_SKIP_MCP_PREFLIGHT
unset RALPH_PLAN_ALLOW_UNSAFE_RESUME RALPH_PLAN_CAFFEINATED RALPH_PLAN_CLI_RESUME RALPH_PLAN_CONTEXT_BUDGET
unset RALPH_PLAN_INVOCATION_TIMEOUT_RAW RALPH_RUN_PLAN_RESET_COMMAND_USED RALPH_PLAN_SESSION_STRATEGY
unset RALPH_PLAN_SESSION_STRATEGY_ENV_SPECIFIED RALPH_PROXY_SHELL_COMPACT RALPH_HUMAN_CONTEXT_MAX_BYTES_NO_RESUME
unset RALPH_MODE RALPH_PLAN_TODO_MAX_ITERATIONS RALPH_RUN_PLAN_RESUME_SESSION_ID RALPH_RUN_PLAN_NEW_SESSION_ID
unset RALPH_RUN_PLAN_RESUME_BARE RALPH_STRICT_PROXY RALPH_AGENT_TOOL_ACCESS_REQUIRE_PROXY RALPH_OPENCODE_SET_CACHE_KEY
unset CURSOR_PLAN_CAFFEINATED CURSOR_PLAN_MODEL CURSOR_PLAN_VERBOSE CURSOR_PLAN_NO_COLOR CURSOR_PLAN_MAX_ITER
unset CURSOR_PLAN_GUTTER_ITER CURSOR_PLAN_PROGRESS_INTERVAL CURSOR_PLAN_NO_CAFFEINATE CURSOR_PLAN_DISABLE_HUMAN_PROMPT
unset CURSOR_PLAN_NO_OPEN CURSOR_PLAN_LOG CURSOR_PLAN_OUTPUT_LOG
unset CLAUDE_PLAN_CAFFEINATED CLAUDE_PLAN_CLI CLAUDE_PLAN_MODEL CLAUDE_PLAN_VERBOSE CLAUDE_PLAN_NO_COLOR CLAUDE_PLAN_MAX_ITER
unset CLAUDE_PLAN_GUTTER_ITER CLAUDE_PLAN_PROGRESS_INTERVAL CLAUDE_PLAN_NO_CAFFEINATE CLAUDE_PLAN_DISABLE_HUMAN_PROMPT
unset CLAUDE_PLAN_NO_OPEN CLAUDE_PLAN_LOG CLAUDE_PLAN_OUTPUT_LOG CLAUDE_PLAN_BARE CLAUDE_PLAN_MINIMAL CLAUDE_PLAN_MINIMAL_TOOLS
unset CLAUDE_PLAN_MINIMAL_DISABLE_MCP CLAUDE_PLAN_PERMISSION_MODE
unset CODEX_PLAN_CAFFEINATED CODEX_PLAN_CLI CODEX_PLAN_MODEL CODEX_PLAN_VERBOSE CODEX_PLAN_NO_COLOR CODEX_PLAN_MAX_ITER
unset CODEX_PLAN_GUTTER_ITER CODEX_PLAN_PROGRESS_INTERVAL CODEX_PLAN_NO_CAFFEINATE CODEX_PLAN_DISABLE_HUMAN_PROMPT
unset CODEX_PLAN_NO_OPEN CODEX_PLAN_LOG CODEX_PLAN_OUTPUT_LOG CODEX_PLAN_SANDBOX CODEX_PLAN_MCP_TOOLS_APPROVAL_MODE
unset CODEX_PLAN_DANGEROUSLY_BYPASS_APPROVALS_AND_SANDBOX CODEX_CI CODEX_MANAGED_BY_NPM
unset OPENCODE_PLAN_CAFFEINATED OPENCODE_PLAN_CLI OPENCODE_PLAN_MODEL OPENCODE_PLAN_VERBOSE OPENCODE_PLAN_NO_COLOR
unset OPENCODE_PLAN_MAX_ITER OPENCODE_PLAN_GUTTER_ITER OPENCODE_PLAN_PROGRESS_INTERVAL OPENCODE_PLAN_NO_CAFFEINATE
unset OPENCODE_PLAN_DISABLE_HUMAN_PROMPT OPENCODE_PLAN_NO_OPEN OPENCODE_PLAN_LOG OPENCODE_PLAN_OUTPUT_LOG

if [[ "$SETUP_FIXTURES" -eq 1 ]]; then
  bash scripts/setup-test-fixtures.sh
fi

export RALPH_USAGE_RISKS_ACKNOWLEDGED="${RALPH_USAGE_RISKS_ACKNOWLEDGED:-1}"

if [[ -z "$JOBS" ]] && has_parallel_runner; then
  JOBS="$(default_parallel_jobs "$(detect_cpu_count)")"
fi

if [[ -n "$JOBS" ]]; then
  if ! has_parallel_runner; then
    if [[ "$JOBS_EXPLICIT" -eq 1 ]]; then
      cat >&2 <<'EOF'
run-bats: -j/--jobs specified but neither GNU parallel nor rush is on PATH.
Install with: brew install parallel (macOS) or apt install parallel (Linux)
Falling back to serial execution.
EOF
    fi
    exec "$BATS_BIN" "${BATS_ARGS[@]}"
  fi
  PARALLEL_FLAGS=()
  while IFS= read -r flag; do
    [[ -n "$flag" ]] || continue
    PARALLEL_FLAGS+=("$flag")
  done < <(bats_parallel_flags "$JOBS" "${BATS_ARGS[@]}")
  exec "$BATS_BIN" -j "$JOBS" "${PARALLEL_FLAGS[@]+"${PARALLEL_FLAGS[@]}"}" "${BATS_ARGS[@]}"
fi

exec "$BATS_BIN" "${BATS_ARGS[@]}"
