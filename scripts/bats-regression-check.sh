#!/usr/bin/env bash
# Record or compare Bats failures without making an existing failure a regression.
set -uo pipefail

usage() {
  echo "Usage: bats-regression-check.sh (--record <file> | --baseline <file>) [--tier <tier> | <bats files...>]" >&2
}

mode=""
baseline=""
selection=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --record|--baseline)
      [[ -z "$mode" && $# -ge 2 ]] || { usage; exit 2; }
      mode="$1"
      baseline="$2"
      shift 2
      ;;
    --tier)
      [[ $# -ge 2 && ${#selection[@]} -eq 0 ]] || { usage; exit 2; }
      selection=(--tier "$2")
      shift 2
      ;;
    -*)
      usage
      exit 2
      ;;
    *)
      [[ ${#selection[@]} -eq 0 ]] || { usage; exit 2; }
      selection=("$@")
      break
      ;;
  esac
done

[[ -n "$mode" ]] || { usage; exit 2; }
if [[ "$mode" == "--baseline" && ! -f "$baseline" ]]; then
  echo "bats-regression-check: missing baseline file: $baseline" >&2
  exit 2
fi

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ns="${RALPH_ARTIFACT_NS:-workspace-order-and-workflow-foundations.plan}"
utc="$(date -u +%Y%m%dT%H%M%SZ)"
junit_dir="$repo_root/.ralph-workspace/artifacts/$ns/bats-junit/$utc"
mkdir -p "$junit_dir"
log="$junit_dir.log"

if [[ ${#selection[@]} -eq 0 || "${selection[0]}" == "--tier" ]]; then
  suite_files=()
  while IFS= read -r suite_file; do
    [[ -n "$suite_file" ]] && suite_files+=("$suite_file")
  done < <(bash "$repo_root/scripts/run-bats.sh" "${selection[@]}" --list-suite)
else
  suite_files=("${selection[@]}")
fi

# Bats requires report flags before file operands.  run-bats accepts both after
# its delimiter, so resolve a tier first and preserve the requested selection.
command=(bash "$repo_root/scripts/run-bats.sh" -- --report-formatter junit -o "$junit_dir" "${suite_files[@]}")
"${command[@]}" >"$log" 2>&1
run_exit=$?

report="$junit_dir/report.xml"
failures="$junit_dir/failures.txt"
if [[ -f "$report" ]]; then
  awk '
    BEGIN { RS="<testcase"; ORS="" }
    NR > 1 && ($0 ~ /<failure[ >]/ || $0 ~ /<error[ >]/) {
      name=""; class=""
      if (match($0, /[[:space:]]name="[^"]*"/)) {
        name=substr($0, RSTART, RLENGTH)
        sub(/^[^"]*"/, "", name); sub(/"$/, "", name)
      }
      if (match($0, /classname="[^"]*"/)) {
        class=substr($0, RSTART, RLENGTH)
        sub(/^[^"]*"/, "", class); sub(/"$/, "", class)
      }
      if (index(class, root "/") == 1) class=substr(class, length(root) + 2)
      if (name != "" && class != "") print class "::" name "\n"
    }
  ' root="$repo_root" "$report" | LC_ALL=C sort -u >"$failures"
else
  : >"$failures"
fi

executed=0
if [[ -f "$report" ]]; then
  executed="$(awk 'BEGIN { RS="<testcase" } NR > 1 { count++ } END { print count+0 }' "$report")"
fi

if [[ "$mode" == "--record" ]]; then
  # An empty baseline is indistinguishable from a clean suite, so refuse to
  # record one when the run produced no report or executed no tests.
  if [[ ! -f "$report" || "$executed" -eq 0 ]]; then
    echo "bats-regression-check: no tests executed; baseline not recorded (see $log)" >&2
    echo "exit=1 new_failures=0 log=$log"
    exit 1
  fi
  mkdir -p "$(dirname "$baseline")"
  cp "$failures" "$baseline"
  echo "exit=$run_exit new_failures=0 log=$log"
  exit 0
fi

if [[ "$executed" -eq 0 ]]; then
  echo "bats-regression-check: zero tests executed" >&2
  echo "exit=1 new_failures=0 log=$log"
  exit 1
fi

new_failures=0
while IFS= read -r failure; do
  [[ -n "$failure" ]] || continue
  if ! grep -Fqx -- "$failure" "$baseline"; then
    echo "$failure" >&2
    new_failures=$((new_failures + 1))
  fi
done <"$failures"

if [[ "$new_failures" -gt 0 ]]; then
  echo "exit=1 new_failures=$new_failures log=$log"
  exit 1
fi
echo "exit=0 new_failures=0 log=$log"
exit 0
