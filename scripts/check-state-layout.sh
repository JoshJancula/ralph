#!/usr/bin/env bash
# Report state-root ownership without changing the supplied root.
set -euo pipefail

usage() {
  echo "Usage: check-state-layout.sh --root <state-root> [--json]" >&2
}

root=""
json=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --root)
      [[ $# -ge 2 && -n "$2" ]] || { usage; exit 2; }
      root="$2"
      shift
      ;;
    --json) json=1 ;;
    -h|--help) usage; exit 0 ;;
    *) usage; exit 2 ;;
  esac
  shift
done

[[ -n "$root" ]] || { usage; exit 2; }
[[ -d "$root" ]] || { echo "check-state-layout.sh: root is not a directory: $root" >&2; exit 1; }

categories=(
  plan-attempt-v1 run-index-v1 legacy-log-v1 graph-engine-v1 workflow-engine-v1
  sequential-engine-v1 delegation-v1 handoff-v1 manual-verification-v1 control-plan-v1
  run-catalog-v2 run-input-v2 stage-control-v2 plan-attempt-v2 graph-engine-v2
  workflow-engine-v2 sequential-engine-v2 delegation-v2 internal cache operator-data artifacts unclassified
)
declare -A owner layout files bytes
for category in "${categories[@]}"; do files["$category"]=0; bytes["$category"]=0; done
owner=([plan-attempt-v1]="plan attempt" [run-index-v1]="derived index" [legacy-log-v1]="legacy" [graph-engine-v1]="graph run" [workflow-engine-v1]="workflow run" [sequential-engine-v1]="sequential run" [delegation-v1]="parent graph run" [handoff-v1]="stage attempt" [manual-verification-v1]="plan attempt" [control-plan-v1]="run" [run-catalog-v2]="run" [run-input-v2]="run" [stage-control-v2]="run" [plan-attempt-v2]="plan attempt" [graph-engine-v2]="graph run" [workflow-engine-v2]="workflow run" [sequential-engine-v2]="sequential run" [delegation-v2]="parent graph run" [internal]="shared coordination" [cache]="cache" [operator-data]="operator" [artifacts]="public contract" [unclassified]="unknown")
for category in "${categories[@]}"; do layout["$category"]="shared"; done
for category in plan-attempt-v1 run-index-v1 legacy-log-v1 graph-engine-v1 workflow-engine-v1 sequential-engine-v1 delegation-v1 handoff-v1 manual-verification-v1 control-plan-v1; do layout["$category"]="v1"; done
for category in run-catalog-v2 run-input-v2 stage-control-v2 plan-attempt-v2 graph-engine-v2 workflow-engine-v2 sequential-engine-v2 delegation-v2; do layout["$category"]="v2"; done

classify() {
  local path="$1"
  case "$path" in
    logs/*/runs/index.jsonl) echo run-index-v1 ;;
    logs/*/runs/*/*) echo plan-attempt-v1 ;;
    logs/*) echo legacy-log-v1 ;;
    graph-runs/*) echo graph-engine-v1 ;;
    workflow-runs/*) echo workflow-engine-v1 ;;
    orchestration-plans/*) echo sequential-engine-v1 ;;
    delegated-runs/*) echo delegation-v1 ;;
    handoffs/*) echo handoff-v1 ;;
    manual-verification/*) echo manual-verification-v1 ;;
    plans/*control*|plans/materialized/*) echo control-plan-v1 ;;
    runs/*/engine/graph/*) echo graph-engine-v2 ;;
    runs/*/engine/workflow/*) echo workflow-engine-v2 ;;
    runs/*/engine/sequential/*) echo sequential-engine-v2 ;;
    runs/*/engine/delegation/*) echo delegation-v2 ;;
    runs/*/stages/*/controls/*) echo stage-control-v2 ;;
    runs/*/stages/*/attempts/*) echo plan-attempt-v2 ;;
    runs/*/inputs/*) echo run-input-v2 ;;
    runs/*/run.json) echo run-catalog-v2 ;;
    internal/*|sessions/*|runtime-config/*|processes/*|setup-journal/*|memory/*|command-profiles/*|hooks-config.jsonl) echo internal ;;
    cache/*|tool-results/*|repo-map/*|search-context/*|metrics/*) echo cache ;;
    artifacts/*) echo artifacts ;;
    workflows/*|docs/*|security/*|plans/*) echo operator-data ;;
    *) echo unclassified ;;
  esac
}

# -P and -type f deliberately exclude symlink targets and symlink entries.
while IFS= read -r -d '' file; do
  rel="${file#"$root"/}"
  category="$(classify "$rel")"
  size="$(wc -c < "$file" | tr -d '[:space:]')"
  files["$category"]=$((files["$category"] + 1))
  bytes["$category"]=$((bytes["$category"] + size))
done < <(find -P "$root" -type f -print0)

if [[ "$json" -eq 1 ]]; then
  printf '{"categories":['
  separator=""
  for category in "${categories[@]}"; do
    printf '%s{"category":"%s","owner":"%s","layout":"%s","fileCount":%s,"bytes":%s}' "$separator" "$category" "${owner[$category]}" "${layout[$category]}" "${files[$category]}" "${bytes[$category]}"
    separator="," 
  done
  printf ']}\n'
else
  printf 'category\towner\tlayout\tfile count\tbytes\n'
  for category in "${categories[@]}"; do
    printf '%s\t%s\t%s\t%s\t%s\n' "$category" "${owner[$category]}" "${layout[$category]}" "${files[$category]}" "${bytes[$category]}"
  done
fi
