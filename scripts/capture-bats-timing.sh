#!/usr/bin/env bash
# Record Bats per-test and per-file timing, and audit the fast tier against its
# cost budget.
#
# This is an explicit maintenance / CI timing job. It is deliberately NOT part
# of an ordinary test run: timing the whole suite on every push would cost more
# than the budget it protects. Run it when the tier split needs re-deriving,
# then feed its report to scripts/update-bats-tiers.sh.
#
# Usage:
#   bash scripts/capture-bats-timing.sh -j 4
#   bash scripts/capture-bats-timing.sh --junit-in report.xml   # parse only
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=scripts/bats-suite-lib.sh
source "$SCRIPT_DIR/bats-suite-lib.sh"

TIMING_DIR="$REPO_ROOT/.ralph-workspace/logs/bats-timing"

# Cost budget. A single test at or above TEST_BUDGET, or a file whose tests sum
# to FILE_BUDGET or more, does not belong in the fast tier.
TEST_BUDGET_SECONDS=60
FILE_BUDGET_SECONDS=60
REPORT_TEST_FLOOR=10

# Bats -j N runs N files each running N tests, so the effective concurrency is
# N*N. -j 8 saturates a 10-core host badly enough to distort every timeout test
# in the suite (and has crashed one), which makes the captured numbers useless
# for a cost baseline. 4 is the sanctioned ceiling.
MAX_JOBS=4
JOBS=""
SETUP_FIXTURES=1
JUNIT_IN=""
BASELINE_DIR=""
FAIL_ON_VIOLATION=0

usage() {
  cat <<'EOF'
Usage: bash scripts/capture-bats-timing.sh [options]

Options:
  -j N, --jobs N        Parallel workers (default: min(4, CPUs); 4 is the max)
  --junit-in PATH       Parse an existing JUnit report instead of running Bats
  --baseline-dir DIR    Where to write bats-cost-baseline.{json,md}
                        (default: .ralph-workspace/artifacts/<ns>/)
  --fail-on-violation   Exit non-zero when the fast tier is over budget
  --no-setup-fixtures   Skip scripts/setup-test-fixtures.sh
  -h, --help            Show this help

Writes a per-run record under .ralph-workspace/logs/bats-timing/runs/<stamp>/
(with a `latest` symlink), plus the cost baseline report in --baseline-dir.

The audit result is always recorded (auditPassed in the JSON, PASS/FAIL in the
Markdown, violations on stderr). Capturing a baseline and enforcing it are
separate jobs: a capture has to be able to measure an over-budget tier in order
to report it, so the exit status only reflects the audit with
--fail-on-violation. The always-on enforcement point is `run-bats.sh --tier
fast`, which refuses an over-budget manifest on every ordinary run.
EOF
}

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
  [[ "$n" =~ ^[1-9][0-9]*$ ]] || n=1
  echo "$n"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h | --help) usage; exit 0 ;;
    -j | --jobs)
      [[ $# -ge 2 ]] || { echo "capture-bats-timing: -j/--jobs requires an argument" >&2; exit 1; }
      JOBS="$2"; shift 2 ;;
    --junit-in)
      [[ $# -ge 2 ]] || { echo "capture-bats-timing: --junit-in requires a path" >&2; exit 1; }
      JUNIT_IN="$2"; shift 2 ;;
    --baseline-dir)
      [[ $# -ge 2 ]] || { echo "capture-bats-timing: --baseline-dir requires a path" >&2; exit 1; }
      BASELINE_DIR="$2"; shift 2 ;;
    --fail-on-violation) FAIL_ON_VIOLATION=1; shift ;;
    --no-setup-fixtures) SETUP_FIXTURES=0; shift ;;
    *) echo "capture-bats-timing: unknown option: $1" >&2; usage >&2; exit 1 ;;
  esac
done

if [[ -z "$JOBS" ]]; then
  if has_parallel_runner; then
    cpus="$(detect_cpu_count)"
    JOBS=$(( cpus > MAX_JOBS ? MAX_JOBS : cpus ))
  else
    JOBS=1
  fi
fi
if [[ ! "$JOBS" =~ ^[1-9][0-9]*$ ]]; then
  echo "capture-bats-timing: -j must be a positive integer" >&2
  exit 1
fi
if [[ "$JOBS" -gt "$MAX_JOBS" ]]; then
  echo "capture-bats-timing: -j $JOBS exceeds the $MAX_JOBS-worker ceiling." >&2
  echo "  Bats -j N runs N*N concurrent tests; above $MAX_JOBS the timing this script" >&2
  echo "  exists to measure is dominated by host contention rather than test cost." >&2
  exit 1
fi

if [[ -z "$BASELINE_DIR" ]]; then
  ns="${RALPH_ARTIFACT_NS:-${RALPH_PLAN_KEY:-bats-cost-baseline}}"
  BASELINE_DIR="$REPO_ROOT/.ralph-workspace/artifacts/$ns"
fi
mkdir -p "$BASELINE_DIR"

cd "$REPO_ROOT"
export RALPH_USAGE_RISKS_ACKNOWLEDGED="${RALPH_USAGE_RISKS_ACKNOWLEDGED:-1}"

stamp="$(date -u +%Y%m%dT%H%M%SZ)"
run_dir="$TIMING_DIR/runs/$stamp"
mkdir -p "$run_dir"

elapsed=0
rc=0
if [[ -n "$JUNIT_IN" ]]; then
  [[ -f "$JUNIT_IN" ]] || { echo "capture-bats-timing: no such JUnit report: $JUNIT_IN" >&2; exit 1; }
  report="$JUNIT_IN"
else
  [[ "$SETUP_FIXTURES" -eq 1 ]] && bash scripts/setup-test-fixtures.sh
  junit_dir="$run_dir/junit"
  rm -rf "$junit_dir"; mkdir -p "$junit_dir"
  mapfile -t files < <(ralph_bats_suite_files "$REPO_ROOT")
  [[ ${#files[@]} -gt 0 ]] || { echo "capture-bats-timing: no test files found" >&2; exit 1; }
  echo "capture-bats-timing: running ${#files[@]} files with -j ${JOBS} ..." >&2
  start="$(date +%s)"
  set +e
  if [[ "$JOBS" -eq 1 ]] || ! has_parallel_runner; then
    bats --report-formatter junit -o "$junit_dir" "${files[@]}" >"$run_dir/run.log" 2>&1
  else
    bats -j "$JOBS" --no-parallelize-within-files \
      --report-formatter junit -o "$junit_dir" "${files[@]}" >"$run_dir/run.log" 2>&1
  fi
  rc=$?
  set -e
  elapsed=$(( $(date +%s) - start ))
  report="$junit_dir/report.xml"
fi

ralph_bats_tier_files "$REPO_ROOT" fast >"$run_dir/fast-files.txt" || true

python3 "$SCRIPT_DIR/bats-cost-report.py" \
  --junit "$report" \
  --repo-root "$REPO_ROOT" \
  --fast-files "$run_dir/fast-files.txt" \
  --out-json "$BASELINE_DIR/bats-cost-baseline.json" \
  --out-md "$BASELINE_DIR/bats-cost-baseline.md" \
  --run-json "$run_dir/summary.json" \
  --stamp "$stamp" \
  --wall-seconds "$elapsed" \
  --exit-code "$rc" \
  --test-budget "$TEST_BUDGET_SECONDS" \
  --file-budget "$FILE_BUDGET_SECONDS" \
  --report-floor "$REPORT_TEST_FLOOR" && audit_rc=0 || audit_rc=$?

ln -sfn "runs/$stamp" "$TIMING_DIR/latest"

echo "capture-bats-timing: wrote $BASELINE_DIR/bats-cost-baseline.json" >&2
echo "capture-bats-timing: wrote $BASELINE_DIR/bats-cost-baseline.md" >&2

if [[ "$audit_rc" -ne 0 ]]; then
  if [[ "$FAIL_ON_VIOLATION" -eq 1 ]]; then
    exit "$audit_rc"
  fi
  echo "capture-bats-timing: fast tier is over budget (recorded above)." >&2
  echo "  Re-run with --fail-on-violation to make that a non-zero exit." >&2
fi
exit 0
