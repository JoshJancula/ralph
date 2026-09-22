#!/usr/bin/env bash
# Record the current baseline without treating known failures as a failure to run.
set -uo pipefail

usage() {
  echo "Usage: record-baseline.sh [--force]" >&2
}

force=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --force) force=1 ;;
    -h|--help) usage; exit 0 ;;
    *) usage; exit 2 ;;
  esac
  shift
done

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ns="${RALPH_ARTIFACT_NS:-workspace-order-and-workflow-foundations.plan}"
dir="$repo_root/.ralph-workspace/artifacts/$ns"
baseline_bats="$dir/baseline-bats-failures.txt"
bats_log="$dir/bats-regression-check.log"
python_log="$dir/python-unit-tests.log"
dashboard_log="$dir/dashboard-tests.log"
baseline_report="$dir/baseline.md"
mkdir -p "$dir" || exit 1

step_failed=0

if [[ ! -f "$baseline_bats" || "$force" -eq 1 ]]; then
  bash "$repo_root/scripts/bats-regression-check.sh" --record "$baseline_bats" >"$bats_log" 2>&1
  bats_exit=$?
else
  bats_exit=0
fi
if [[ ! -f "$baseline_bats" ]]; then
  echo "record-baseline: Bats baseline was not created: $baseline_bats" >&2
  step_failed=1
fi
echo "exit=$bats_exit log=$bats_log"

bash "$repo_root/scripts/run-python-unit-tests.sh" >"$python_log" 2>&1
python_exit=$?
echo "exit=$python_exit log=$python_log"

npm --prefix "$repo_root/ralph-dashboard" test >"$dashboard_log" 2>&1
dashboard_exit=$?
echo "exit=$dashboard_exit log=$dashboard_log"

if ! command -v bash >/dev/null 2>&1 || ! command -v npm >/dev/null 2>&1; then
  step_failed=1
fi

{
  echo "# Baseline"
  echo
  echo "## Bats failures"
  if [[ -s "$baseline_bats" ]]; then cat "$baseline_bats"; else echo "None"; fi
  echo
  echo "## Python failures"
  if ! grep -E '^(FAIL:|ERROR:)' "$python_log"; then echo "None"; fi
  echo
  echo "## Dashboard failures"
  if ! grep -E '(^[[:space:]]*FAIL[[:space:]]|^[[:space:]]*[x×✕][[:space:]])' "$dashboard_log"; then echo "None"; fi
  echo
  echo "Bats exit code: $bats_exit"
  echo "Python exit code: $python_exit"
  echo "Dashboard exit code: $dashboard_exit"
  echo "Bats log: $bats_log"
  echo "Bats failures: $baseline_bats"
  echo "Python log: $python_log"
  echo "Dashboard log: $dashboard_log"
  echo "Fixture state totals: measured in define-state-ownership-and-layout"
} >"$baseline_report" || exit 1

if [[ "$step_failed" -ne 0 ]]; then
  exit 1
fi
exit 0
