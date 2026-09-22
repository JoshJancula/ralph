#!/usr/bin/env bash
# Bounded, best-effort retention for derived Ralph state. Source only.

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  echo "This file is meant to be sourced, not executed." >&2
  exit 1
fi

RALPH_RETENTION_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if ! declare -F cleanup_plan_file_mtime >/dev/null 2>&1; then
  # shellcheck source=cleanup-plan.sh
  source "$RALPH_RETENTION_LIB_DIR/cleanup-plan.sh"
fi
if ! declare -F workflow_operator_is_terminal_state >/dev/null 2>&1; then
  # shellcheck source=workflow/workflow-operator-view.sh
  source "$RALPH_RETENTION_LIB_DIR/workflow/workflow-operator-view.sh"
fi

ralph_retention_nonneg() {
  local raw="${1:-}" fallback="${2:-0}"
  [[ "$raw" =~ ^[0-9]+$ ]] && printf '%s\n' "$raw" || printf '%s\n' "$fallback"
}

ralph_retention_runs_count() { ralph_retention_nonneg "${RALPH_RETENTION_LOG_RUNS_MAX_COUNT:-}" 10; }
ralph_retention_runs_age_days() { ralph_retention_nonneg "${RALPH_RETENTION_LOG_RUNS_MAX_AGE_DAYS:-}" 30; }
ralph_retention_artifacts_age_days() { ralph_retention_nonneg "${RALPH_RETENTION_ARTIFACTS_MAX_AGE_DAYS:-}" 90; }
ralph_retention_artifacts_max_bytes() { ralph_retention_nonneg "${RALPH_RETENTION_ARTIFACTS_MAX_BYTES:-}" 536870912; }
ralph_retention_journals_count() { ralph_retention_nonneg "${RALPH_RETENTION_JOURNALS_MAX_COUNT:-}" 20; }
ralph_retention_journals_age_days() { ralph_retention_nonneg "${RALPH_RETENTION_JOURNALS_MAX_AGE_DAYS:-}" 30; }

# Outer workflow registries live at workflow-runs/<id>/run.json under layout 1
# and runs/<id>/engine/workflow/run.json under layout 2.  Retention has to see
# both, because a state root can hold runs admitted under either layout.
ralph_retention_registry_run_files() {
  local state_root="$1"
  find "$state_root/workflow-runs" -mindepth 2 -maxdepth 2 -name run.json -type f 2>/dev/null
  find "$state_root/runs" -mindepth 4 -maxdepth 4 -path '*/engine/workflow/run.json' -type f 2>/dev/null
}

# Plan attempts live at logs/<key>/runs/<id>/ under layout 1 and at
# runs/<id>/stages/<stage>/attempts/<attempt>/ under layout 2.
ralph_retention_plan_attempt_dirs() {
  local state_root="$1"
  find "$state_root/logs" -mindepth 3 -maxdepth 3 -type d 2>/dev/null
  find "$state_root/runs" -mindepth 5 -maxdepth 5 -path '*/stages/*/attempts/*' -type d 2>/dev/null
}

ralph_retention_registry_run_file() {
  local state_root="$1" run_id="$2"
  if [[ -f "$state_root/runs/$run_id/engine/workflow/run.json" ]]; then
    printf '%s/runs/%s/engine/workflow/run.json\n' "$state_root" "$run_id"
  else
    printf '%s/workflow-runs/%s/run.json\n' "$state_root" "$run_id"
  fi
}

# ralph_retention_eligibility <state-root> <plan-run|artifact|journal|graph-run> <path> [namespace]
# Prints a stable reason.  A zero status is affirmative: the target is proven
# safe to prune.  Unknown or malformed ownership is deliberately retained.
ralph_retention_eligibility() {
  local state_root="$1" kind="$2" path="$3" namespace="${4:-}" file status parent graph registry workflow nested
  case "$kind" in
    plan-run)
      file="$path/run-manifest.json"
      [[ -f "$file" ]] || { printf 'unknown-owner\n'; return 1; }
      jq -e 'type == "object" and .kind == "ralph_run_manifest" and (.status | type == "string")' "$file" >/dev/null 2>&1 || { printf 'corrupt-metadata\n'; return 1; }
      status="$(jq -r '.status' "$file")"
      case "$status" in complete|failed|cancelled) ;; *) printf 'nonterminal-plan-run\n'; return 1 ;; esac
      parent="$(jq -r '.parent.workflow_run_id // .parent.graph_run_id // empty' "$file")"
      [[ -z "$parent" ]] || { printf 'workflow-owned\n'; return 1; }
      printf 'eligible\n'; return 0
      ;;
    journal)
      [[ -f "$path" ]] || { printf 'unknown-owner\n'; return 1; }
      jq -e 'type == "object"' "$path" >/dev/null 2>&1 || { printf 'corrupt-metadata\n'; return 1; }
      jq -e '[(.mutated_files // [])[] | select((.restored // false) != true)] | length == 0' "$path" >/dev/null 2>&1 || { printf 'unrestored-originals\n'; return 1; }
      printf 'eligible\n'; return 0
      ;;
    graph-run)
      file="$path/run.json"
      [[ -f "$file" ]] || { printf 'unknown-owner\n'; return 1; }
      # Graph runs written before the kind field existed carry only runId and
      # status; both shapes are real graph ledgers.
      jq -e 'type == "object" and (.status | type == "string")
             and (.kind == "graph" or ((has("kind") | not) and (.runId | type == "string")))' "$file" >/dev/null 2>&1 || { printf 'corrupt-metadata\n'; return 1; }
      status="$(jq -r '.status' "$file")"
      graph_state_run_status_is_terminal "$status" || { printf 'nonterminal-graph-run\n'; return 1; }
      [[ "$status" != "interrupted" && "$status" != "awaiting-operator" && "$status" != "awaiting-ack" ]] || { printf 'resumable-graph-run\n'; return 1; }
      registry="$(jq -r '.registryRunPath // empty' "$file")"
      if [[ -n "$registry" ]]; then
        [[ -f "$registry/run.json" ]] || { printf 'unknown-owner\n'; return 1; }
        jq -e 'type == "object" and (.state | type == "string")' "$registry/run.json" >/dev/null 2>&1 || { printf 'corrupt-metadata\n'; return 1; }
        workflow="$(jq -r '.state' "$registry/run.json")"
        workflow_operator_is_terminal_state "$workflow" || { printf 'nonterminal-workflow-run\n'; return 1; }
        [[ "$status" != "failed" ]] || { printf 'unpublished-failed-candidate\n'; return 1; }
      fi
      printf 'eligible\n'; return 0
      ;;
    artifact)
      [[ -n "$namespace" ]] || namespace="$(basename "$path")"
      # Every workflow claiming this shared namespace must be finished, and its
      # engine pointer must resolve to a safely terminal graph run.
      while IFS= read -r file; do
        jq -e 'type == "object"' "$file" >/dev/null 2>&1 || { printf 'corrupt-metadata\n'; return 1; }
        [[ "$(jq -r '.artifactNamespace // empty' "$file")" == "$namespace" ]] || continue
        workflow="$(jq -r '.state // empty' "$file")"
        workflow_operator_is_terminal_state "$workflow" || { printf 'nonterminal-workflow-run\n'; return 1; }
        graph="$(jq -r '.engine.statePath // empty' "$file")"
        [[ -n "$graph" ]] || { printf 'unknown-owner\n'; return 1; }
        nested="$(ralph_retention_eligibility "$state_root" graph-run "$graph" "$namespace")" || { printf '%s\n' "$nested"; return 1; }
      done < <(ralph_retention_registry_run_files "$state_root")
      # Leaf manifests are the other ownership pointer.  A manifest is written
      # at exit, so an unmanifested run under a same-named key is live/legacy
      # rather than evidence that the namespace is safe to remove.
      while IFS= read -r file; do
        if [[ ! -f "$file/run-manifest.json" ]]; then
          [[ "$(basename "$(dirname "$(dirname "$file")")")" == "$namespace" ]] && { printf 'unknown-owner\n'; return 1; }
          continue
        fi
        file="$file/run-manifest.json"
        jq -e 'type == "object" and .kind == "ralph_run_manifest" and (.artifact_ns | type == "string")' "$file" >/dev/null 2>&1 || { printf 'corrupt-metadata\n'; return 1; }
        [[ "$(jq -r '.artifact_ns' "$file")" == "$namespace" ]] || continue
        status="$(jq -r '.status // empty' "$file")"
        case "$status" in complete|failed|cancelled) ;; *) printf 'nonterminal-plan-run\n'; return 1 ;; esac
        parent="$(jq -r '.parent.workflow_run_id // empty' "$file")"
        if [[ -n "$parent" ]]; then
          registry="$(ralph_retention_registry_run_file "$state_root" "$parent")"
          [[ -f "$registry" ]] || { printf 'unknown-owner\n'; return 1; }
          workflow="$(jq -r '.state // empty' "$registry" 2>/dev/null)"
          workflow_operator_is_terminal_state "$workflow" || { printf 'nonterminal-workflow-run\n'; return 1; }
        fi
      done < <(ralph_retention_plan_attempt_dirs "$state_root")
      printf 'eligible\n'; return 0
      ;;
    run)
      # A layout-2 run directory (runs/<run-id>/) is one removable subtree:
      # its catalog, attempts, and engine ledgers go together.
      file="$path/run.json"
      [[ -f "$file" ]] || { printf 'unknown-owner\n'; return 1; }
      jq -e 'type == "object" and .layoutVersion == 2 and (.status | type == "string")' "$file" >/dev/null 2>&1 || { printf 'corrupt-metadata\n'; return 1; }
      nested="$(basename "$path")"
      if [[ "$nested" == "${RALPH_PROCESS_RUN_ID:-}" || "$nested" == "${RALPH_WORKFLOW_RUN_ID:-}" ]]; then
        printf 'nonterminal-plan-run\n'; return 1
      fi
      status="$(jq -r '.status' "$file")"
      case "$status" in
        complete|completed|failed|cancelled) ;;
        *)
          if ! workflow_operator_is_terminal_state "$status" 2>/dev/null && ! graph_state_run_status_is_terminal "$status" 2>/dev/null; then
            printf 'nonterminal-plan-run\n'; return 1
          fi
          ;;
      esac
      if [[ -f "$path/engine/workflow/run.json" ]]; then
        jq -e 'type == "object" and (.state | type == "string")' "$path/engine/workflow/run.json" >/dev/null 2>&1 || { printf 'corrupt-metadata\n'; return 1; }
        workflow="$(jq -r '.state' "$path/engine/workflow/run.json")"
        workflow_operator_is_terminal_state "$workflow" || { printf 'nonterminal-workflow-run\n'; return 1; }
      fi
      if [[ -f "$path/engine/graph/run.json" ]]; then
        nested="$(ralph_retention_eligibility "$state_root" graph-run "$path/engine/graph")" || { printf '%s\n' "$nested"; return 1; }
      fi
      printf 'eligible\n'; return 0
      ;;
    *) printf 'unknown-owner\n'; return 1 ;;
  esac
}

ralph_retention_run_is_nonterminal() {
  local state_root="$1" dir="$2"
  ! ralph_retention_eligibility "$state_root" plan-run "$dir" >/dev/null
}

ralph_retention_prune_dirs() {
  local root="$1" max_count="$2" max_age_days="$3" state_root="${4:-}" kind="${5:-plan-run}" kept=0 removed=0 cutoff entry mtime
  [[ -d "$root" ]] || { printf '0\n'; return 0; }
  cutoff="$(cleanup_plan_epoch_days_ago "$max_age_days")"
  while IFS= read -r entry; do
    [[ -d "$root/$entry" && ! -L "$root/$entry" ]] || continue
    ralph_retention_eligibility "$state_root" "$kind" "$root/$entry" >/dev/null || continue
    kept=$((kept + 1))
    mtime="$(cleanup_plan_file_mtime "$root/$entry")"
    if { [[ "$max_age_days" -gt 0 && "$mtime" -lt "$cutoff" ]] || [[ "$max_count" -gt 0 && "$kept" -gt "$max_count" ]]; }; then
      rm -rf "$root/$entry" && removed=$((removed + 1))
    fi
  done < <(ls -t1 "$root" 2>/dev/null || true)
  printf '%s\n' "$removed"
}

ralph_retention_prune_artifacts() {
  local root="$1" max_age_days="$2" max_bytes="$3" state_root="${4:-}" namespace="${5:-$(basename "$root")}" cutoff mtime bytes
  [[ -d "$root" && ! -L "$root" ]] || { printf '0\n'; return 0; }
  ralph_retention_eligibility "$state_root" artifact "$root" "$namespace" >/dev/null || { printf '0\n'; return 0; }
  cutoff="$(cleanup_plan_epoch_days_ago "$max_age_days")"
  mtime="$(cleanup_plan_file_mtime "$root")"
  bytes="$(( $(du -sk "$root" 2>/dev/null | awk '{print $1}' || echo 0) * 1024 ))"
  if { [[ "$max_age_days" -gt 0 && "$mtime" -lt "$cutoff" ]] || [[ "$max_bytes" -gt 0 && "$bytes" -gt "$max_bytes" ]]; }; then
    rm -rf "$root" || return 1
    printf '1\n'
  else
    printf '0\n'
  fi
}

ralph_retention_auto_prune() {
  local state_root="$1" key="$2" runs journals artifacts removed_runs removed_journals removed_artifacts
  local namespace="${3:-$key}"
  [[ "${RALPH_RETENTION_AUTO:-1}" == "0" ]] && { printf 'retention disabled (RALPH_RETENTION_AUTO=0)\n'; return 0; }
  runs="$state_root/logs/$key/runs"
  if declare -F ralph_state_runtime_config_dir >/dev/null 2>&1; then
    journals="$(ralph_state_runtime_config_dir "$state_root" "$key")/journals"
  else
    journals="$state_root/runtime-config/$key/journals"
  fi
  removed_runs="$(ralph_retention_prune_dirs "$runs" "$(ralph_retention_runs_count)" "$(ralph_retention_runs_age_days)" "$state_root" plan-run)"
  # Layout-2 runs (the default for new runs) live under runs/<run-id>/ and
  # are pruned as whole subtrees with the same count and age limits.
  removed_runs=$(( removed_runs + $(ralph_retention_prune_dirs "$state_root/runs" "$(ralph_retention_runs_count)" "$(ralph_retention_runs_age_days)" "$state_root" run) ))
  removed_journals="$(ralph_retention_prune_dirs "$journals" "$(ralph_retention_journals_count)" "$(ralph_retention_journals_age_days)" "$state_root" journal)"
  artifacts="$state_root/artifacts/$namespace"
  removed_artifacts="$(ralph_retention_prune_artifacts "$artifacts" "$(ralph_retention_artifacts_age_days)" "$(ralph_retention_artifacts_max_bytes)" "$state_root" "$namespace")"
  printf 'retention pruned %s run(s), %s journal(s), %s artifact namespace(s); disable with RALPH_RETENTION_AUTO=0\n' "$removed_runs" "$removed_journals" "$removed_artifacts"
}
