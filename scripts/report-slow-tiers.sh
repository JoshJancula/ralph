#!/usr/bin/env bash
# Record slow and acceptance tier Bats failures for operator review.
# Does not baseline those tiers; exits 0 whenever both runs finished.
set -uo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ns="${RALPH_ARTIFACT_NS:-workspace-order-and-workflow-foundations.plan}"
dir="$repo_root/.ralph-workspace/artifacts/$ns"
mkdir -p "$dir" || exit 1

slow_file="$dir/final-slow-failures.txt"
acceptance_file="$dir/final-acceptance-failures.txt"
slow_log="$dir/report-slow-tiers-slow.log"
acceptance_log="$dir/report-slow-tiers-acceptance.log"
handoff="$dir/handoff.md"

step_failed=0

bash "$repo_root/scripts/bats-regression-check.sh" --record "$slow_file" --tier slow \
  >"$slow_log" 2>&1
slow_exit=$?
echo "exit=$slow_exit log=$slow_log"
[[ -f "$slow_file" ]] || step_failed=1

bash "$repo_root/scripts/bats-regression-check.sh" --record "$acceptance_file" --tier acceptance \
  >"$acceptance_log" 2>&1
acceptance_exit=$?
echo "exit=$acceptance_exit log=$acceptance_log"
[[ -f "$acceptance_file" ]] || step_failed=1

{
  printf '\n## Slow and acceptance tier failures (not baselined; operator review)\n\n'
  printf '### Slow tier (`%s`)\n\n' "$slow_file"
  if [[ -s "$slow_file" ]]; then
    cat "$slow_file"
  else
    printf 'None\n'
  fi
  printf '\n### Acceptance tier (`%s`)\n\n' "$acceptance_file"
  if [[ -s "$acceptance_file" ]]; then
    cat "$acceptance_file"
  else
    printf 'None\n'
  fi
  printf '\nSlow exit code: %s\n' "$slow_exit"
  printf 'Acceptance exit code: %s\n' "$acceptance_exit"
  printf 'Slow log: %s\n' "$slow_log"
  printf 'Acceptance log: %s\n' "$acceptance_log"
} >>"$handoff"

if [[ "$step_failed" -ne 0 ]]; then
  exit 1
fi
exit 0
