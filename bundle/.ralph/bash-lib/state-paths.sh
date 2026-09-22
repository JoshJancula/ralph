#!/usr/bin/env bash
# State-layout path resolution shared by readers and writers.
#
# Layout 1 keeps the historical per-category roots (logs/<key>/runs/<id>,
# workflow-runs/<id>, graph-runs/<ns>/<id>).  Layout 2 groups every run-owned
# category under runs/<run-id>/ so one run is one removable subtree:
#
#   runs/<run-id>/run.json                                  run catalog
#   runs/<run-id>/stages/<stage-id>/attempts/<attempt-id>/  plan attempts
#   runs/<run-id>/stages/<stage-id>/controls/               control plans
#   runs/<run-id>/engine/{workflow,graph,sequential,delegation}/
#
# A recorded catalog always wins over the current environment default, so a
# run admitted under layout 1 stays layout 1 across resume.

if [[ -n "${RALPH_STATE_PATHS_LOADED:-}" ]]; then return 0; fi
RALPH_STATE_PATHS_LOADED=1

ralph_state_paths_error() { printf 'Error: %s\n' "$*" >&2; return 1; }

# ralph_state_path_segment <value> <label>
# Rejects anything that could escape one directory level.
ralph_state_path_segment() {
  local value="${1:-}" label="${2:-segment}"
  [[ -n "$value" && "$value" != */* && "$value" != *'\'* && "$value" != *".."* && "$value" != . ]] \
    || { ralph_state_paths_error "invalid $label: $value"; return 1; }
  printf '%s\n' "$value"
}

# ralph_state_path_resolve <state-root> <relative-path>
# Refuses traversal and symlink escapes; the target itself need not exist.
ralph_state_path_resolve() {
  local root="${1:-}" rel="${2:-}" root_real current part rest next real
  [[ -n "$root" && -n "$rel" && "$rel" != /* ]] || { ralph_state_paths_error "state path requires a root and relative path"; return 1; }
  [[ "/$rel/" != *"/../"* && "$rel" != .. && "$rel" != ../* && "$rel" != */.. ]] || { ralph_state_paths_error "state path may not contain '..': $rel"; return 1; }
  # Writers resolve paths before the state root exists (a fresh workspace's
  # first run creates it). Nothing under a missing root can be a symlink, so
  # the traversal check above is the whole containment check in that case.
  if [[ ! -e "$root" ]]; then
    printf '%s/%s\n' "${root%/}" "$rel"
    return 0
  fi
  [[ -d "$root" ]] || { ralph_state_paths_error "cannot access state root: $root"; return 1; }
  root_real="$(cd "$root" && pwd -P)" || return 1
  current="$root_real"; rest="$rel"
  while [[ -n "$rest" ]]; do
    part="${rest%%/*}"
    if [[ "$rest" == */* ]]; then rest="${rest#*/}"; else rest=""; fi
    [[ "$part" != . && -n "$part" ]] || continue
    next="$current/$part"
    if [[ -L "$next" ]]; then
      real="$(cd "$(dirname "$next")" && cd "$(readlink "$next")" 2>/dev/null && pwd -P)" || { ralph_state_paths_error "state path has unreadable symlink: $rel"; return 1; }
      [[ "$real" == "$root_real" || "$real" == "$root_real"/* ]] || { ralph_state_paths_error "state path escapes root via symlink: $rel"; return 1; }
      current="$real"
    else
      current="$next"
    fi
  done
  [[ "$current" == "$root_real" || "$current" == "$root_real"/* ]] || { ralph_state_paths_error "state path escapes root: $rel"; return 1; }
  # Containment is proved on physical paths above; return the path under the
  # caller's own root spelling so layout-1 paths stay byte-identical to the
  # pre-resolver literals (macOS /var vs /private/var, symlinked roots).
  printf '%s/%s\n' "${root%/}" "$rel"
}

# ralph_state_layout_for_new_run
# The layout a run admitted right now would be recorded with.  Only an empty
# value, 1, or 2 are accepted; anything else is an operator error.
ralph_state_layout_for_new_run() {
  case "${RALPH_STATE_LAYOUT:-}" in
    '' | 2) printf '2\n' ;;
    1) printf '1\n' ;;
    *) ralph_state_paths_error "invalid RALPH_STATE_LAYOUT: ${RALPH_STATE_LAYOUT}"; return 1 ;;
  esac
}

# ralph_state_run_layout <state-root> <run-id>
# The layout recorded in the run catalog, ignoring the environment entirely.
# A run with no catalog reads as layout 1.
ralph_state_run_layout() {
  local root="${1:-}" run_id="${2:-}" catalog
  [[ -n "$root" ]] || { ralph_state_paths_error "run layout requires state root"; return 1; }
  ralph_state_path_segment "$run_id" "run id" >/dev/null || return 1
  if [[ -d "$root" ]]; then
    catalog="$(ralph_state_path_resolve "$root" "runs/$run_id/run.json")" || return 1
    if [[ -f "$catalog" ]] && command -v jq >/dev/null 2>&1 \
      && [[ "$(jq -r '.layoutVersion // empty' "$catalog" 2>/dev/null)" == 2 ]]; then
      printf '2\n'; return 0
    fi
  fi
  printf '1\n'
}

# ralph_state_layout_version <state-root> [run-id]
# Compatibility entry point: catalog layout for a known run, otherwise the
# layout a new run would use.
ralph_state_layout_version() {
  local root="${1:-}" run_id="${2:-}"
  [[ -n "$root" ]] || { ralph_state_paths_error "layout version requires state root"; return 1; }
  if [[ -n "$run_id" ]]; then
    ralph_state_run_layout "$root" "$run_id"
    return $?
  fi
  ralph_state_layout_for_new_run
}

# _ralph_state_effective_layout <state-root> <run-id> [legacy-marker-relpath]
# Catalog first, then an existing layout-1 artifact, then the new-run default.
_ralph_state_effective_layout() {
  local root="$1" run_id="$2" legacy_rel="${3:-}" recorded legacy
  recorded="$(ralph_state_run_layout "$root" "$run_id")" || return 1
  if [[ "$recorded" == 2 ]]; then printf '2\n'; return 0; fi
  if [[ -n "$legacy_rel" && -d "$root" ]]; then
    legacy="$(ralph_state_path_resolve "$root" "$legacy_rel")" || return 1
    if [[ -e "$legacy" ]]; then printf '1\n'; return 0; fi
  fi
  ralph_state_layout_for_new_run
}

# ralph_state_run_dir <state-root> <run-id>
# The layout-2 run root.  Layout 1 has no equivalent, so it is an error there.
ralph_state_run_dir() {
  local root="${1:-}" run_id="${2:-}"
  ralph_state_path_segment "$run_id" "run id" >/dev/null || return 1
  ralph_state_path_resolve "$root" "runs/$run_id"
}

# ralph_state_run_catalog_file <state-root> <run-id>
ralph_state_run_catalog_file() {
  local dir
  dir="$(ralph_state_run_dir "$@")" || return 1
  printf '%s/run.json\n' "$dir"
}

# ralph_state_attempt_dir <state-root> <run-id> <stage-id> <attempt-id>
ralph_state_attempt_dir() {
  local root="${1:-}" run_id="${2:-}" stage_id="${3:-plan}" attempt_id="${4:-}"
  [[ -n "$attempt_id" ]] || attempt_id="$run_id"
  ralph_state_path_segment "$run_id" "run id" >/dev/null || return 1
  ralph_state_path_segment "$stage_id" "stage id" >/dev/null || return 1
  ralph_state_path_segment "$attempt_id" "attempt id" >/dev/null || return 1
  ralph_state_path_resolve "$root" "runs/$run_id/stages/$stage_id/attempts/$attempt_id"
}

# ralph_state_stage_controls_dir <state-root> <run-id> <stage-id>
ralph_state_stage_controls_dir() {
  local root="${1:-}" run_id="${2:-}" stage_id="${3:-plan}"
  ralph_state_path_segment "$run_id" "run id" >/dev/null || return 1
  ralph_state_path_segment "$stage_id" "stage id" >/dev/null || return 1
  ralph_state_path_resolve "$root" "runs/$run_id/stages/$stage_id/controls"
}

# ralph_state_attempt_handoffs_dir <state-root> <run-id> <stage-id> <attempt-id>
ralph_state_attempt_handoffs_dir() {
  local dir
  dir="$(ralph_state_attempt_dir "$@")" || return 1
  printf '%s/handoffs\n' "$dir"
}

# ralph_state_attempt_manual_verification_dir <state-root> <run-id> <stage-id> <attempt-id>
ralph_state_attempt_manual_verification_dir() {
  local dir
  dir="$(ralph_state_attempt_dir "$@")" || return 1
  printf '%s/manual-verification\n' "$dir"
}

# ralph_state_engine_dir <state-root> <run-id> <kind>
# kind is one of workflow, graph, sequential, delegation.
ralph_state_engine_dir() {
  local root="${1:-}" run_id="${2:-}" kind="${3:-}"
  ralph_state_path_segment "$run_id" "run id" >/dev/null || return 1
  case "$kind" in
    workflow|graph|sequential|delegation) ;;
    *) ralph_state_paths_error "invalid engine kind: $kind"; return 1 ;;
  esac
  ralph_state_path_resolve "$root" "runs/$run_id/engine/$kind"
}

# ralph_state_shared_dir <state-root> <category>
# Categories that are not owned by a single run.  The layout-2 grouping into
# internal/ and cache/ is resolver-visible; writers move over separately.
ralph_state_shared_dir() {
  local root="${1:-}" category="${2:-}" version
  ralph_state_path_segment "$category" "state category" >/dev/null || return 1
  version="$(ralph_state_layout_for_new_run)" || return 1
  case "$category:$version" in
    sessions:2|runtime-config:2|processes:2|memory:2|command-profiles:2|setup-journal:2) ralph_state_path_resolve "$root" "internal/$category" ;;
    tool-results:2|repo-map:2|search-context:2|metrics:2) ralph_state_path_resolve "$root" "cache/$category" ;;
    *) ralph_state_path_resolve "$root" "$category" ;;
  esac
}

# ralph_state_sessions_home <state-root> [plan-key]
# Parent of per-plan session dirs. When plan-key is set and only the layout-1
# path already holds that plan's sessions, keep resolving there so resume never
# forks or loses a session. Otherwise use ralph_state_shared_dir (internal/
# under layout 2).
ralph_state_sessions_home() {
  local root="${1:-}" plan_key="${2:-}" shared legacy
  [[ -n "$root" ]] || { ralph_state_paths_error "sessions home requires state root"; return 1; }
  shared="$(ralph_state_shared_dir "$root" sessions)" || return 1
  if [[ -n "$plan_key" ]]; then
    ralph_state_path_segment "$plan_key" "plan key" >/dev/null || return 1
    legacy="$(ralph_state_path_resolve "$root" "sessions")" || return 1
    if [[ "$legacy" != "$shared" && -d "$legacy/$plan_key" && ! -d "$shared/$plan_key" ]]; then
      printf '%s\n' "$legacy"
      return 0
    fi
  fi
  printf '%s\n' "$shared"
}

# ralph_state_sessions_dir <state-root> <plan-key>
ralph_state_sessions_dir() {
  local root="${1:-}" plan_key="${2:-}" home
  [[ -n "$plan_key" ]] || { ralph_state_paths_error "sessions dir requires plan key"; return 1; }
  home="$(ralph_state_sessions_home "$root" "$plan_key")" || return 1
  printf '%s/%s\n' "$home" "$plan_key"
}

# ralph_state_runtime_config_dir <state-root> <plan-key>
# Per-plan overlay journal home. Sticky to layout-1 when that plan already has
# journals/originals there so restore never loses a layout-1 original.
ralph_state_runtime_config_dir() {
  local root="${1:-}" plan_key="${2:-}" shared legacy
  [[ -n "$root" ]] || { ralph_state_paths_error "runtime-config dir requires state root"; return 1; }
  [[ -n "$plan_key" ]] || { ralph_state_paths_error "runtime-config dir requires plan key"; return 1; }
  ralph_state_path_segment "$plan_key" "plan key" >/dev/null || return 1
  shared="$(ralph_state_shared_dir "$root" runtime-config)" || return 1
  legacy="$(ralph_state_path_resolve "$root" "runtime-config")" || return 1
  if [[ "$legacy" != "$shared" && -d "$legacy/$plan_key" && ! -d "$shared/$plan_key" ]]; then
    printf '%s/%s\n' "$legacy" "$plan_key"
    return 0
  fi
  printf '%s/%s\n' "$shared" "$plan_key"
}

# ralph_state_hooks_config_path <state-root>
# hooks-config.jsonl lives beside runtime-config under layout 1 and inside
# internal/runtime-config/ under layout 2. Prefer the shared write root; fall
# back to the legacy top-level file when only that exists.
ralph_state_hooks_config_path() {
  local root="${1:-}" shared legacy candidate
  [[ -n "$root" ]] || { ralph_state_paths_error "hooks-config path requires state root"; return 1; }
  shared="$(ralph_state_shared_dir "$root" runtime-config)" || return 1
  candidate="$shared/hooks-config.jsonl"
  legacy="$(ralph_state_path_resolve "$root" "hooks-config.jsonl")" || return 1
  if [[ ! -f "$candidate" && -f "$legacy" ]]; then
    printf '%s\n' "$legacy"
    return 0
  fi
  printf '%s\n' "$candidate"
}

# ralph_state_workflow_run_dir <state-root> <run-id>
# The workflow registry directory (run.json, immutable input, actions).
ralph_state_workflow_run_dir() {
  local root="${1:-}" run_id="${2:-}" version
  ralph_state_path_segment "$run_id" "run id" >/dev/null || return 1
  version="$(_ralph_state_effective_layout "$root" "$run_id" "workflow-runs/$run_id/run.json")" || return 1
  if [[ "$version" == 2 ]]; then
    ralph_state_engine_dir "$root" "$run_id" workflow
  else
    ralph_state_path_resolve "$root" "workflow-runs/$run_id"
  fi
}

# ralph_state_graph_run_dir <state-root> <namespace> <run-id>
ralph_state_graph_run_dir() {
  local root="${1:-}" namespace="${2:-}" run_id="${3:-}" version
  ralph_state_path_segment "$namespace" "graph namespace" >/dev/null || return 1
  ralph_state_path_segment "$run_id" "run id" >/dev/null || return 1
  version="$(_ralph_state_effective_layout "$root" "$run_id" "graph-runs/$namespace/$run_id/run.json")" || return 1
  if [[ "$version" == 2 ]]; then
    ralph_state_engine_dir "$root" "$run_id" graph
  else
    ralph_state_path_resolve "$root" "graph-runs/$namespace/$run_id"
  fi
}

# ralph_state_sequential_run_dir <state-root> <run-id> <legacy-dir>
# Layout 1 kept the Sequential engine state beside the registry entry.
ralph_state_sequential_run_dir() {
  local root="${1:-}" run_id="${2:-}" legacy_dir="${3:-}" version
  ralph_state_path_segment "$run_id" "run id" >/dev/null || return 1
  version="$(_ralph_state_effective_layout "$root" "$run_id" "workflow-runs/$run_id/run.json")" || return 1
  if [[ "$version" == 2 ]]; then
    ralph_state_engine_dir "$root" "$run_id" sequential
  else
    printf '%s\n' "$legacy_dir"
  fi
}

# ralph_state_delegation_root <state-root> <parent-run-id>
# Layout 1: top-level delegated-runs/. Layout 2: runs/<parent>/engine/delegation/.
# Follows the parent run's recorded layout (catalog, then a layout-1 graph
# ledger under graph-runs/*/<parent>, then the new-run default).
ralph_state_delegation_root() {
  local root="${1:-}" parent_run_id="${2:-}" version= match=
  ralph_state_path_segment "$parent_run_id" "run id" >/dev/null || return 1
  version="$(ralph_state_run_layout "$root" "$parent_run_id")" || return 1
  if [[ "$version" == 2 ]]; then
    ralph_state_engine_dir "$root" "$parent_run_id" delegation
    return $?
  fi
  if [[ -d "$root" ]]; then
    for match in "$root"/graph-runs/*/"$parent_run_id"; do
      if [[ -e "$match" ]]; then
        ralph_state_path_resolve "$root" "delegated-runs"
        return $?
      fi
    done
  fi
  version="$(ralph_state_layout_for_new_run)" || return 1
  if [[ "$version" == 2 ]]; then
    ralph_state_engine_dir "$root" "$parent_run_id" delegation
  else
    ralph_state_path_resolve "$root" "delegated-runs"
  fi
}

# ralph_state_delegation_dir <state-root> <parent-run-id> <delegated-run-id>
ralph_state_delegation_dir() {
  local root="${1:-}" parent_run_id="${2:-}" delegated_id="${3:-}" base
  ralph_state_path_segment "$delegated_id" "delegated run id" >/dev/null || return 1
  base="$(ralph_state_delegation_root "$root" "$parent_run_id")" || return 1
  printf '%s/%s\n' "$base" "$delegated_id"
}

# ---------------------------------------------------------------------------
# Run catalog (layout 2 only)
# ---------------------------------------------------------------------------
#
# runs/<run-id>/run.json is a thin index over the run-owned subtree.  It never
# duplicates engine or registry state: it records identity, kind, parentage,
# status, and where the detail lives so a reader can route without knowing
# which engine produced the run.

ralph_state_now_iso() { date -u +%Y-%m-%dT%H:%M:%SZ; }

_ralph_state_require_atomic_json() {
  declare -F ralph_atomic_write_json >/dev/null 2>&1 && return 0
  local dir
  dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || return 1
  # shellcheck source=atomic-json.sh
  source "$dir/atomic-json.sh"
}

# _ralph_state_catalog_lock_path <run-dir>
_ralph_state_catalog_lock_path() {
  printf '%s/.catalog.lock\n' "${1%/}"
}

# Directory mkdir lock around catalog read-modify-write. Concurrent stage
# recorders must not lose siblings; the atomic rename alone only protects the
# final bytes of one writer.
_ralph_state_catalog_acquire_lock() {
  local lock_path="${1:-}" parent deadline now
  [[ -n "$lock_path" ]] || return 1
  parent="$(dirname -- "$lock_path")"
  mkdir -p "$parent" || return 1
  deadline=$(( $(date +%s) + ${RALPH_STATE_CATALOG_LOCK_TIMEOUT_SECS:-30} ))
  while true; do
    if mkdir "$lock_path" 2>/dev/null; then
      return 0
    fi
    now="$(date +%s)"
    if [[ "$now" -ge "$deadline" ]]; then
      # Force-remove a leftover lock from a killed writer, then one final try.
      rmdir "$lock_path" 2>/dev/null || rm -rf "$lock_path" 2>/dev/null || true
      mkdir "$lock_path" 2>/dev/null && return 0
      ralph_state_paths_error "timeout acquiring catalog lock: $lock_path"
      return 1
    fi
    sleep 0.05 2>/dev/null || sleep 1
  done
}

_ralph_state_catalog_release_lock() {
  local lock_path="${1:-}"
  [[ -n "$lock_path" ]] || return 0
  rmdir "$lock_path" 2>/dev/null || rm -rf "$lock_path" 2>/dev/null || true
}

# ralph_state_catalog_update <state-root> <run-id> <jq-filter> [jq args...]
# Merges the filter into the existing catalog, seeding one when absent. Holds a
# per-run catalog lock across the read-modify-write so concurrent stage entries
# both land; the write itself remains an atomic rename.
ralph_state_catalog_update() {
  local root="${1:-}" run_id="${2:-}" filter="${3:-}"
  [[ -n "$root" && -n "$run_id" && -n "$filter" ]] || { ralph_state_paths_error "catalog update requires state root, run id, and a jq filter"; return 1; }
  shift 3
  command -v jq >/dev/null 2>&1 || { ralph_state_paths_error "jq is required to write a run catalog"; return 1; }
  _ralph_state_require_atomic_json || return 1

  local dir file now base lock_path rc=0
  mkdir -p "$root" || return 1
  dir="$(ralph_state_run_dir "$root" "$run_id")" || return 1
  mkdir -p "$dir" || return 1
  lock_path="$(_ralph_state_catalog_lock_path "$dir")"
  _ralph_state_catalog_acquire_lock "$lock_path" || return 1
  file="$dir/run.json"
  now="$(ralph_state_now_iso)"
  if [[ -f "$file" && ! -L "$file" ]]; then
    base="$(jq -c . "$file" 2>/dev/null)" || {
      _ralph_state_catalog_release_lock "$lock_path"
      ralph_state_paths_error "corrupt run catalog: $file"
      return 1
    }
  fi
  if [[ -z "${base:-}" ]]; then
    base="$(jq -cn --arg runId "$run_id" --arg now "$now" '{
      kind: "ralph_run_catalog",
      layoutVersion: 2,
      runKind: null,
      runId: $runId,
      parent: null,
      status: "running",
      createdAt: $now,
      updatedAt: $now,
      endedAt: null,
      artifactNamespace: null,
      task: null,
      inputs: null,
      engine: null,
      stages: []
    }')" || {
      _ralph_state_catalog_release_lock "$lock_path"
      return 1
    }
  fi
  ralph_atomic_write_json "$file" \
    "\$__base | ($filter) | .kind = \"ralph_run_catalog\" | .layoutVersion = 2 | .runId = \$__runId | .updatedAt = \$__now" \
    --argjson __base "$base" --arg __runId "$run_id" --arg __now "$now" "$@" || rc=$?
  _ralph_state_catalog_release_lock "$lock_path"
  # Admission, status change, and terminal status all flow through this writer.
  # Managed READMEs are best-effort navigation; never fail the catalog update.
  if [[ "$rc" -eq 0 ]]; then
    if ! declare -F ralph_state_readme_refresh >/dev/null 2>&1; then
      # shellcheck source=state-readme.sh
      source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/state-readme.sh" 2>/dev/null || true
    fi
    if declare -F ralph_state_readme_refresh >/dev/null 2>&1; then
      ralph_state_readme_refresh "$root" "$run_id" || true
    fi
  fi
  return "$rc"
}

# ralph_state_catalog_record_stage <state-root> <run-id> <stage-id> <attempt-id> [status]
# The catalog keeps exactly one stages[] entry per stage (bounded by the
# number of stages); a new attempt replaces the stage's entry and becomes its
# latestAttemptId. Older attempts stay on disk under stages/<id>/attempts/.
ralph_state_catalog_record_stage() {
  local root="${1:-}" run_id="${2:-}" stage_id="${3:-}" attempt_id="${4:-}" status="${5:-running}"
  ralph_state_path_segment "$stage_id" "stage id" >/dev/null || return 1
  ralph_state_path_segment "$attempt_id" "attempt id" >/dev/null || return 1
  ralph_state_catalog_update "$root" "$run_id" \
    '.stages = (((.stages // []) | map(select(.stageId != $stageId)))
       + [{stageId: $stageId, latestAttemptId: $attemptId, status: $stageStatus,
           path: ("stages/" + $stageId + "/attempts/" + $attemptId)}])' \
    --arg stageId "$stage_id" --arg attemptId "$attempt_id" --arg stageStatus "$status"
}

# ralph_state_plan_attempt_dir <state-root> <plan-key> <run-id> [stage-id] [attempt-id]
ralph_state_plan_attempt_dir() {
  local root="${1:-}" plan_key="${2:-}" run_id="${3:-}" stage_id="${4:-plan}" attempt_id="${5:-}" version
  ralph_state_path_segment "$run_id" "run id" >/dev/null || return 1
  [[ -n "$attempt_id" ]] || attempt_id="$run_id"
  version="$(_ralph_state_effective_layout "$root" "$run_id" "logs/$plan_key/runs/$run_id")" || return 1
  if [[ "$version" == 2 ]]; then
    ralph_state_attempt_dir "$root" "$run_id" "$stage_id" "$attempt_id"
  else
    ralph_state_path_resolve "$root" "logs/$plan_key/runs/$run_id"
  fi
}
