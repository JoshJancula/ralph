#!/usr/bin/env bash
# Compare Python unit-test FAIL/ERROR lines against the known baseline set.
# Exits 1 only for failures not listed below; known baseline failures are allowed.
set -uo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ns="${RALPH_ARTIFACT_NS:-workspace-order-and-workflow-foundations.plan}"
dir="$repo_root/.ralph-workspace/artifacts/$ns"
log="$dir/python-regression-check.log"
mkdir -p "$dir" || exit 1

# Module + method pairs from the "Python unit tests" baseline failures.
baseline_pairs=(
  "test_retrieval_eval test_compare_to_baseline_passes_on_current_ranker"
  "test_retrieval_eval test_per_query_safety_top10_gate"
  "test_workspace_registry test_prune_nonexistent_workspaces"
  "test_workspace_registry test_prune_old_entries"
)

is_baselined() {
  local line="$1" pair module method
  for pair in "${baseline_pairs[@]}"; do
    module="${pair%% *}"
    method="${pair#* }"
    if [[ "$line" == *"$module"* && "$line" == *"$method"* ]]; then
      return 0
    fi
  done
  return 1
}

bash "$repo_root/scripts/run-python-unit-tests.sh" >"$log" 2>&1
run_exit=$?

failures_file="$dir/python-regression-failures.txt"
: >"$failures_file"
new_failures=0
while IFS= read -r line || [[ -n "$line" ]]; do
  case "$line" in
    FAIL:*|ERROR:*)
      if is_baselined "$line"; then
        continue
      fi
      printf '%s\n' "$line" >>"$failures_file"
      printf '%s\n' "$line" >&2
      new_failures=$((new_failures + 1))
      ;;
  esac
done <"$log"

if [[ "$new_failures" -gt 0 ]]; then
  echo "exit=1 new_failures=$new_failures log=$log"
  exit 1
fi
echo "exit=0 new_failures=0 python_exit=$run_exit log=$log"
exit 0
