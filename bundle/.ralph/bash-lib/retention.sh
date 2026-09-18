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

ralph_retention_run_is_nonterminal() {
  local dir="$1" status
  [[ -f "$dir/run-manifest.json" ]] || return 1
  status="$(jq -r '.status // empty' "$dir/run-manifest.json" 2>/dev/null)"
  [[ "$status" == "running" || "$status" == "interrupted" || "$status" == "awaiting-ack" ]]
}

ralph_retention_prune_dirs() {
  local root="$1" max_count="$2" max_age_days="$3" kept=0 removed=0 cutoff entry mtime
  [[ -d "$root" ]] || { printf '0\n'; return 0; }
  cutoff="$(cleanup_plan_epoch_days_ago "$max_age_days")"
  while IFS= read -r entry; do
    [[ -d "$root/$entry" && ! -L "$root/$entry" ]] || continue
    ralph_retention_run_is_nonterminal "$root/$entry" && continue
    kept=$((kept + 1))
    mtime="$(cleanup_plan_file_mtime "$root/$entry")"
    if { [[ "$max_age_days" -gt 0 && "$mtime" -lt "$cutoff" ]] || [[ "$max_count" -gt 0 && "$kept" -gt "$max_count" ]]; }; then
      rm -rf "$root/$entry" && removed=$((removed + 1))
    fi
  done < <(ls -t1 "$root" 2>/dev/null || true)
  printf '%s\n' "$removed"
}

ralph_retention_prune_artifacts() {
  local root="$1" max_age_days="$2" max_bytes="$3" cutoff mtime bytes
  [[ -d "$root" && ! -L "$root" ]] || { printf '0\n'; return 0; }
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
  local state_root="$1" key="$2" namespace="${3:-$key}" runs journals artifacts removed_runs removed_journals removed_artifacts
  [[ "${RALPH_RETENTION_AUTO:-1}" == "0" ]] && { printf 'retention disabled (RALPH_RETENTION_AUTO=0)\n'; return 0; }
  runs="$state_root/logs/$key/runs"
  journals="$state_root/runtime-config/$key/journals"
  removed_runs="$(ralph_retention_prune_dirs "$runs" "$(ralph_retention_runs_count)" "$(ralph_retention_runs_age_days)")"
  removed_journals="$(ralph_retention_prune_dirs "$journals" "$(ralph_retention_journals_count)" "$(ralph_retention_journals_age_days)")"
  artifacts="$state_root/artifacts/$namespace"
  removed_artifacts="$(ralph_retention_prune_artifacts "$artifacts" "$(ralph_retention_artifacts_age_days)" "$(ralph_retention_artifacts_max_bytes)")"
  printf 'retention pruned %s run(s), %s journal(s), %s artifact namespace(s); disable with RALPH_RETENTION_AUTO=0\n' "$removed_runs" "$removed_journals" "$removed_artifacts"
}
