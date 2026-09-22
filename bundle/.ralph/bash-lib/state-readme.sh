#!/usr/bin/env bash
# Managed state-root and per-run README generation.
#
# Regenerated at run admission, on status change, and at terminal status
# (via ralph_state_catalog_update). Never overwrites a README.md that lacks
# the managed marker; writes README.ralph.md instead. Links are state-root
# relative (or run-relative for per-run files). Never embeds lease contents,
# env values, or approval payloads.

if [[ -n "${RALPH_STATE_README_LOADED:-}" ]]; then return 0; fi
RALPH_STATE_README_LOADED=1

_RALPH_STATE_README_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=state-paths.sh
source "$_RALPH_STATE_README_DIR/state-paths.sh"

RALPH_STATE_README_MARKER='<!-- ralph-managed: do not edit; regenerated -->'

ralph_state_readme_error() { printf 'Error: %s\n' "$*" >&2; return 1; }

# ralph_state_readme_is_managed <path>
# True when the file is absent or its first line is the managed marker.
ralph_state_readme_is_managed() {
  local path="${1:-}" first
  [[ -n "$path" ]] || return 1
  [[ -f "$path" ]] || return 0
  IFS= read -r first <"$path" || return 1
  [[ "$first" == "$RALPH_STATE_README_MARKER" ]]
}

# ralph_state_readme_resolve_path <directory>
# Prefer README.md when writable under the marker rule; otherwise README.ralph.md.
ralph_state_readme_resolve_path() {
  local dir="${1:-}" candidate
  [[ -n "$dir" ]] || { ralph_state_readme_error "readme resolve requires a directory"; return 1; }
  candidate="${dir%/}/README.md"
  if ralph_state_readme_is_managed "$candidate"; then
    printf '%s\n' "$candidate"
    return 0
  fi
  printf '%s\n' "${dir%/}/README.ralph.md"
}

# ralph_state_readme_atomic_write <path>  (content on stdin)
ralph_state_readme_atomic_write() {
  local path="${1:-}" dir tmp
  [[ -n "$path" ]] || { ralph_state_readme_error "atomic write requires a path"; return 1; }
  dir="$(dirname -- "$path")"
  mkdir -p "$dir" || return 1
  tmp="$(mktemp "$dir/.readme-XXXXXX")" || return 1
  if ! cat >"$tmp"; then
    rm -f "$tmp"
    return 1
  fi
  if ! declare -F ralph_fsync_path >/dev/null 2>&1; then
    # shellcheck source=atomic-json.sh
    source "$_RALPH_STATE_README_DIR/atomic-json.sh" 2>/dev/null || true
  fi
  declare -F ralph_fsync_path >/dev/null 2>&1 && ralph_fsync_path "$tmp"
  if ! mv -f "$tmp" "$path"; then
    rm -f "$tmp"
    return 1
  fi
  declare -F ralph_fsync_path >/dev/null 2>&1 && ralph_fsync_path "$dir"
  return 0
}

# ralph_state_readme_rel_from_to <from-dir> <to-path>
# Both paths absolute or under the same root; prints a relative link path.
# Never emits an absolute path.
ralph_state_readme_rel_from_to() {
  local from to common up="" rest
  from="${1%/}"
  to="${2%/}"
  common="$from"
  [[ -n "$from" && -n "$to" ]] || return 1
  if [[ "$to" == "$from" ]]; then
    printf '.\n'
    return 0
  fi
  if [[ "$to" == "$from"/* ]]; then
    printf '%s\n' "${to#"$from"/}"
    return 0
  fi
  # Walk up from from until to is under common, counting ../ segments.
  while [[ "$to" != "$common" && "$to" != "$common"/* ]]; do
    up="../$up"
    common="$(dirname -- "$common")"
    [[ "$common" != / && "$common" != . ]] || {
      # Fallback: basename-only relative guess (should not happen inside one root).
      printf '%s\n' "$(basename -- "$to")"
      return 0
    }
  done
  if [[ "$to" == "$common" ]]; then
    printf '%s\n' "${up%/}"
  else
    rest="${to#"$common"/}"
    printf '%s%s\n' "$up" "$rest"
  fi
}

# ralph_state_readme_evidence_line <label> <absolute-path> <link-from-dir>
# Prints a markdown bullet. Missing paths render as "missing"; dangling
# symlinks as "expired". Never reads file contents.
ralph_state_readme_evidence_line() {
  local label="$1" abs="$2" from_dir="$3" rel
  if [[ -z "$abs" ]]; then
    printf -- '- %s: missing\n' "$label"
    return 0
  fi
  if [[ -L "$abs" && ! -e "$abs" ]]; then
    printf -- '- %s: expired\n' "$label"
    return 0
  fi
  if [[ ! -e "$abs" ]]; then
    printf -- '- %s: missing\n' "$label"
    return 0
  fi
  rel="$(ralph_state_readme_rel_from_to "$from_dir" "$abs")" || rel="$(basename -- "$abs")"
  # Refuse absolute links even if the helper misfires.
  [[ "$rel" != /* ]] || rel="$(basename -- "$abs")"
  printf -- '- %s: [%s](%s)\n' "$label" "$rel" "$rel"
}

# Ownership-map blurbs for layout-2 top-level directories (and common legacy).
_ralph_state_readme_dir_blurb() {
  case "$1" in
    runs) printf 'Outer plan, workflow, and graph runs (catalog + stages + engine)' ;;
    artifacts) printf 'Public artifact address contract (per namespace)' ;;
    plans) printf 'Operator-owned plans (durable)' ;;
    workflows) printf 'Operator-owned workflow definitions (durable)' ;;
    docs) printf 'Operator-owned docs (durable)' ;;
    security) printf 'Operator-owned security sentinels (durable)' ;;
    cache) printf 'Rebuildable cache (tool-results, indexes, repo-map, metrics)' ;;
    internal) printf 'Shared coordination (sessions, runtime-config, processes, memory)' ;;
    logs) printf 'Legacy layout-1 plan attempt logs' ;;
    graph-runs) printf 'Legacy layout-1 graph engine ledgers' ;;
    workflow-runs) printf 'Legacy layout-1 workflow registry runs' ;;
    orchestration-plans) printf 'Legacy layout-1 sequential engine state' ;;
    delegated-runs) printf 'Legacy layout-1 delegation ledgers' ;;
    handoffs) printf 'Legacy layout-1 stage handoffs' ;;
    manual-verification) printf 'Legacy layout-1 runner verify output' ;;
    sessions) printf 'Legacy layout-1 session resume state (now internal/sessions)' ;;
    runtime-config) printf 'Legacy layout-1 runtime config journals (now internal/runtime-config)' ;;
    processes) printf 'Legacy layout-1 process leases (now internal/processes)' ;;
    tool-results) printf 'Legacy layout-1 tool result cache (now cache/tool-results)' ;;
    memory) printf 'Legacy layout-1 plan memory (now internal/memory)' ;;
    *) printf 'Retained path (see ralph state orphans for unclassified)' ;;
  esac
}

# ralph_state_readme_list_recent_runs <state-root> [limit]
# Prints TSV: runId<TAB>status<TAB>readme-rel (newest first by updatedAt/createdAt).
ralph_state_readme_list_recent_runs() {
  local root="${1:-}" limit="${2:-20}" runs_dir catalog run_id status sort_key readme_name rel
  [[ -n "$root" ]] || return 1
  runs_dir="$(ralph_state_path_resolve "$root" "runs")" || return 1
  [[ -d "$runs_dir" ]] || return 0
  command -v jq >/dev/null 2>&1 || return 0

  local -a rows=()
  local entry
  for entry in "$runs_dir"/*/run.json; do
    [[ -f "$entry" ]] || continue
    run_id="$(jq -r '.runId // empty' "$entry" 2>/dev/null)" || continue
    [[ -n "$run_id" ]] || run_id="$(basename "$(dirname -- "$entry")")"
    status="$(jq -r '.status // "unknown"' "$entry" 2>/dev/null)"
    sort_key="$(jq -r '.updatedAt // .createdAt // ""' "$entry" 2>/dev/null)"
    readme_name="README.md"
    if [[ -f "$(dirname -- "$entry")/README.ralph.md" && ! -f "$(dirname -- "$entry")/README.md" ]]; then
      readme_name="README.ralph.md"
    elif [[ -f "$(dirname -- "$entry")/README.ralph.md" ]] && ! ralph_state_readme_is_managed "$(dirname -- "$entry")/README.md"; then
      readme_name="README.ralph.md"
    fi
    rel="runs/$run_id/$readme_name"
    rows+=("$sort_key	$run_id	$status	$rel")
  done

  if [[ ${#rows[@]} -eq 0 ]]; then
    return 0
  fi
  printf '%s\n' "${rows[@]}" | LC_ALL=C sort -r | head -n "$limit" | while IFS=$'\t' read -r _ rid st rpath; do
    printf '%s\t%s\t%s\n' "$rid" "$st" "$rpath"
  done
}

# ralph_state_readme_refresh_root <state-root>
ralph_state_readme_refresh_root() {
  local root="${1:-}" target out dir name blurb
  [[ -n "$root" ]] || { ralph_state_readme_error "root readme requires state root"; return 1; }
  mkdir -p "$root" || return 1
  target="$(ralph_state_readme_resolve_path "$root")" || return 1

  {
    printf '%s\n\n' "$RALPH_STATE_README_MARKER"
    printf '# Ralph state root\n\n'
    printf 'Navigation entry for this state root. Regenerated by Ralph; edit only if you accept losing changes on the next refresh (or keep a non-managed README.md and Ralph will write README.ralph.md instead).\n\n'
    printf '## Top-level directories\n\n'
    # Prefer known layout-2 names first, then any other present dirs.
    local -a known=(runs artifacts plans workflows docs security cache internal
      logs graph-runs workflow-runs orchestration-plans delegated-runs handoffs
      manual-verification sessions runtime-config processes tool-results memory)
    local -A seen=()
    for name in "${known[@]}"; do
      dir="$root/$name"
      [[ -d "$dir" && ! -L "$dir" ]] || continue
      seen["$name"]=1
      blurb="$(_ralph_state_readme_dir_blurb "$name")"
      printf -- '- [%s/](%s/): %s\n' "$name" "$name" "$blurb"
    done
    if [[ -d "$root" ]]; then
      local child base
      for child in "$root"/*/; do
        [[ -d "$child" ]] || continue
        [[ -L "${child%/}" ]] && continue
        base="$(basename -- "${child%/}")"
        [[ -n "${seen[$base]:-}" ]] && continue
        blurb="$(_ralph_state_readme_dir_blurb "$base")"
        printf -- '- [%s/](%s/): %s\n' "$base" "$base" "$blurb"
      done
    fi
    printf '\n## Recent runs\n\n'
    local have_runs=0 rid st rpath
    while IFS=$'\t' read -r rid st rpath; do
      [[ -n "$rid" ]] || continue
      have_runs=1
      printf -- '- [%s](%s) (%s)\n' "$rid" "$rpath" "$st"
    done < <(ralph_state_readme_list_recent_runs "$root" 20)
    if [[ "$have_runs" -eq 0 ]]; then
      printf 'No layout-2 runs recorded yet.\n'
    fi
  } | ralph_state_readme_atomic_write "$target"
}

# _ralph_state_readme_current_stage <catalog-json>
# Prints "stageId attemptId status" for the current (running) or latest stage.
_ralph_state_readme_current_stage() {
  local catalog="$1"
  printf '%s' "$catalog" | jq -r '
    (.stages // []) as $s
    | if ($s | length) == 0 then "missing\tmissing\tmissing"
      else
        ($s | map(select(.status == "running")) | .[0]) as $run
        | (if $run != null then $run else $s[-1] end)
        | [(.stageId // "missing"), (.attemptId // .latestAttemptId // "missing"), (.status // "missing")]
        | @tsv
      end
  ' 2>/dev/null
}

# ralph_state_readme_refresh_run <state-root> <run-id>
ralph_state_readme_refresh_run() {
  local root="${1:-}" run_id="${2:-}" run_dir catalog_file catalog target
  local task status stage_id attempt_id stage_status ns inputs_rel inputs_abs
  local engine_workflow engine_graph attempt_dir artifacts_abs
  local decisions_abs verify_dir failed_glob verdict_hit fail_hit root_readme_path
  [[ -n "$root" && -n "$run_id" ]] || { ralph_state_readme_error "run readme requires state root and run id"; return 1; }
  ralph_state_path_segment "$run_id" "run id" >/dev/null || return 1
  run_dir="$(ralph_state_run_dir "$root" "$run_id")" || return 1
  mkdir -p "$run_dir" || return 1
  catalog_file="$(ralph_state_run_catalog_file "$root" "$run_id")" || return 1
  if [[ -f "$catalog_file" ]] && command -v jq >/dev/null 2>&1; then
    catalog="$(jq -c . "$catalog_file" 2>/dev/null)" || catalog=""
  fi
  if [[ -z "${catalog:-}" ]]; then
    catalog="$(jq -cn --arg id "$run_id" '{runId:$id,status:"missing",task:null,stages:[],artifactNamespace:null,inputs:null}')"
  fi

  task="$(printf '%s' "$catalog" | jq -r 'if .task == null or .task == "" then "missing" else .task end' 2>/dev/null)"
  status="$(printf '%s' "$catalog" | jq -r '.status // "missing"' 2>/dev/null)"
  ns="$(printf '%s' "$catalog" | jq -r '.artifactNamespace // empty' 2>/dev/null)"
  IFS=$'\t' read -r stage_id attempt_id stage_status < <(_ralph_state_readme_current_stage "$catalog")

  target="$(ralph_state_readme_resolve_path "$run_dir")" || return 1
  root_readme_path="$(ralph_state_readme_resolve_path "$root")" || return 1

  # Evidence locations (paths only; never open payloads).
  if [[ -n "$ns" ]]; then
    artifacts_abs="$(ralph_state_path_resolve "$root" "artifacts/$ns" 2>/dev/null || true)"
  else
    artifacts_abs=""
  fi
  inputs_rel="$(printf '%s' "$catalog" | jq -r '
    if (.inputs | type) == "object" then
      (.inputs | to_entries | map(.value) | map(select(type == "string" and . != null and . != "")) | .[0] // empty)
    elif (.inputs | type) == "array" then
      (.inputs[0] // empty)
    elif (.inputs | type) == "string" then
      .inputs
    else empty end
  ' 2>/dev/null)"
  inputs_abs=""
  if [[ -n "$inputs_rel" && "$inputs_rel" != /* ]]; then
    if [[ -e "$run_dir/$inputs_rel" ]]; then
      inputs_abs="$run_dir/$inputs_rel"
    elif [[ -e "$root/$inputs_rel" ]]; then
      inputs_abs="$root/$inputs_rel"
    else
      inputs_abs="$run_dir/$inputs_rel"
    fi
  elif [[ -d "$run_dir/inputs" ]]; then
    inputs_abs="$run_dir/inputs"
  fi

  engine_workflow="$(ralph_state_engine_dir "$root" "$run_id" workflow 2>/dev/null || true)"
  engine_graph="$(ralph_state_engine_dir "$root" "$run_id" graph 2>/dev/null || true)"
  attempt_dir=""
  if [[ -n "$stage_id" && "$stage_id" != missing && -n "$attempt_id" && "$attempt_id" != missing ]]; then
    attempt_dir="$(ralph_state_attempt_dir "$root" "$run_id" "$stage_id" "$attempt_id" 2>/dev/null || true)"
  fi

  decisions_abs=""
  if [[ -n "$engine_workflow" && -d "$engine_workflow/actions/decisions" ]]; then
    decisions_abs="$engine_workflow/actions/decisions"
  elif [[ -d "$run_dir/engine/workflow/actions/decisions" ]]; then
    decisions_abs="$run_dir/engine/workflow/actions/decisions"
  fi

  verdict_hit=""
  if [[ -n "$artifacts_abs" ]]; then
    for verdict_hit in "$artifacts_abs"/qa-verdict.json "$artifacts_abs"/*verdict*.json; do
      [[ -e "$verdict_hit" ]] || continue
      break
    done
    [[ -e "${verdict_hit:-}" ]] || verdict_hit=""
  fi

  verify_dir=""
  if [[ -n "$attempt_dir" ]]; then
    verify_dir="$attempt_dir/manual-verification"
  fi
  failed_glob=""
  fail_hit=""
  if [[ -n "$attempt_dir" ]]; then
    for fail_hit in "$attempt_dir"/verify-*.log "$attempt_dir"/failed-check* "$attempt_dir"/manual-verification/*; do
      [[ -e "$fail_hit" ]] || continue
      case "$(basename -- "$fail_hit")" in
        *fail*|*verify*|*check*)
          failed_glob=1
          break
          ;;
      esac
      fail_hit=""
    done
    [[ -n "$failed_glob" ]] || fail_hit=""
  fi

  {
    printf '%s\n\n' "$RALPH_STATE_README_MARKER"
    printf '# Run %s\n\n' "$run_id"
    printf -- '- Task: %s\n' "$task"
    printf -- '- Status: %s\n' "$status"
    printf -- '- Current stage: %s\n' "$stage_id"
    printf -- '- Current attempt: %s\n' "$attempt_id"
    printf -- '- Stage status: %s\n' "${stage_status:-missing}"
    printf '\n## Inputs\n\n'
    ralph_state_readme_evidence_line "inputs" "${inputs_abs:-}" "$run_dir"

    printf '\n## Outputs\n\n'
    if [[ -n "$ns" ]]; then
      ralph_state_readme_evidence_line "artifacts/$ns" "${artifacts_abs:-}" "$run_dir"
    else
      printf -- '- artifacts namespace: missing\n'
    fi

    printf '\n## Decisions\n\n'
    ralph_state_readme_evidence_line "approvals (actions/decisions)" "${decisions_abs:-}" "$run_dir"
    if [[ -n "$verdict_hit" ]]; then
      ralph_state_readme_evidence_line "verdict $(basename -- "$verdict_hit")" "$verdict_hit" "$run_dir"
    else
      printf -- '- verdicts: missing\n'
    fi

    printf '\n## Verification\n\n'
    ralph_state_readme_evidence_line "manual-verification/" "${verify_dir:-}" "$run_dir"
    if [[ -n "$failed_glob" && -n "$fail_hit" ]]; then
      ralph_state_readme_evidence_line "failed check $(basename -- "$fail_hit")" "$fail_hit" "$run_dir"
    else
      printf -- '- failed check output: missing\n'
    fi

    printf '\n## Engine\n\n'
    ralph_state_readme_evidence_line "engine/workflow" "${engine_workflow:-}" "$run_dir"
    ralph_state_readme_evidence_line "engine/graph" "${engine_graph:-}" "$run_dir"
    if [[ -n "$attempt_dir" ]]; then
      ralph_state_readme_evidence_line "current attempt" "$attempt_dir" "$run_dir"
    else
      printf -- '- current attempt: missing\n'
    fi
    printf '\n[State root README](%s)\n' "$(ralph_state_readme_rel_from_to "$run_dir" "$root_readme_path")"
  } | ralph_state_readme_atomic_write "$target"
}

# ralph_state_readme_refresh <state-root> [run-id]
# Refresh the per-run README when a run id is given, then the state-root README.
# Failures here must not fail catalog writes; callers may ignore the status.
ralph_state_readme_refresh() {
  local root="${1:-}" run_id="${2:-}"
  [[ -n "$root" ]] || { ralph_state_readme_error "readme refresh requires state root"; return 1; }
  if [[ -n "$run_id" ]]; then
    ralph_state_readme_refresh_run "$root" "$run_id" || return 1
  fi
  ralph_state_readme_refresh_root "$root"
}
