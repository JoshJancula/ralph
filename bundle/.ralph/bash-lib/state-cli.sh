#!/usr/bin/env bash
_state_dir="${BASH_SOURCE[0]%/*}"; source "$_state_dir/help-render.sh"
if ! declare -F ralph_state_sessions_dir >/dev/null 2>&1; then
  # shellcheck source=state-paths.sh
  source "$_state_dir/state-paths.sh"
fi
ralph_state_root() { printf '%s\n' "${RALPH_PLAN_WORKSPACE_ROOT:-$PWD/.ralph-workspace}"; }
ralph_state_usage() { cat <<'EOF' | ralph_help_render
Usage: ralph state <status|runs|show|prune|reindex|orphans> [options]

  status              Per top-level directory: name, file count, disk size
  runs [--plan KEY]   List plan, workflow, and graph runs
  show <run-id>       Show one run with evidence markers
  prune [--apply] [--json] [--dry-run]
                      Preview (default) or apply retention-eligible cleanup
  reindex             Note about legacy summary synthesis
  orphans [--json]    Report paths the ownership map cannot classify
EOF
}

ralph_state_todo_hash() {
  local text="$1"
  if command -v python3 >/dev/null 2>&1; then
    python3 -c 'import hashlib,sys; print(hashlib.sha256(sys.argv[1].encode("utf-8")).hexdigest())' "$text"
  elif command -v shasum >/dev/null 2>&1; then
    printf '%s' "$text" | shasum -a 256 | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then
    printf '%s' "$text" | sha256sum | awk '{print $1}'
  else
    printf '%s' "$text"
  fi
}

ralph_state_plan_todo_hashes() {
  local plan_path="${1:-}"
  [[ -n "$plan_path" && -f "$plan_path" ]] || return 0
  local line body
  while IFS= read -r line || [[ -n "$line" ]]; do
    case "$line" in
      *'- [ ] '*|*'- [x] '*|*'- [X] '*)
        body="$(printf '%s' "$line" | sed -E 's/^[[:space:]]*- \[[xX[:space:]]\] //')"
        ralph_state_todo_hash "$body"
        ;;
    esac
  done <"$plan_path"
}

ralph_state_run_is_terminal() {
  case "${1:-}" in
    running|incomplete|unknown|'') return 1 ;;
    *) return 0 ;;
  esac
}

ralph_state_todo_sessions_dir() {
  local root="$1" plan_key="$2"
  printf '%s/todo-sessions\n' "$(ralph_state_sessions_dir "${root%/}" "$plan_key")"
}

ralph_state_resume_counts() {
  local root="$1" run_id="$2" plan_key="$3" plan_path="$4"
  local dir exact=0 degraded=0 mismatch=0 match=0
  dir="$(ralph_state_todo_sessions_dir "$root" "$plan_key")"
  local hashes="" h
  hashes="$(ralph_state_plan_todo_hashes "$plan_path" | tr '\n' ' ')"
  local f capture rec_run rec_hash
  [[ -d "$dir" ]] || { printf '0\t0\tunknown\n'; return 0; }
  for f in "$dir"/*.json; do
    [[ -f "$f" ]] || continue
    rec_run="$(jq -r '.identity.runId // empty' "$f" 2>/dev/null)" || continue
    [[ "$rec_run" == "$run_id" ]] || continue
    capture="$(jq -r '.capture // empty' "$f" 2>/dev/null)"
    rec_hash="$(jq -r '.identity.todoHash // empty' "$f" 2>/dev/null)"
    if [[ "$capture" == "exact" ]]; then
      exact=$((exact + 1))
    else
      degraded=$((degraded + 1))
    fi
    if [[ -z "$hashes" ]]; then
      continue
    fi
    if [[ -n "$rec_hash" && " $hashes " == *" $rec_hash "* ]]; then
      match=$((match + 1))
    else
      mismatch=$((mismatch + 1))
    fi
  done
  local hashes_match="unknown"
  if [[ -n "$hashes" ]]; then
    if [[ "$mismatch" -eq 0 ]]; then
      hashes_match="yes"
    else
      hashes_match="no"
    fi
  fi
  printf '%s\t%s\t%s\n' "$exact" "$degraded" "$hashes_match"
}

ralph_state_resume_reason() {
  local capture="$1" rec_hash="$2" hashes="$3"
  if [[ "$capture" != "exact" ]]; then
    printf '%s\n' "degraded-capture"
    return 0
  fi
  if [[ -n "$hashes" && -n "$rec_hash" && " $hashes " != *" $rec_hash "* ]]; then
    printf '%s\n' "mismatched-todo-hash"
    return 0
  fi
  printf '%s\n' "foreign-run-id"
}

# ralph_state_evidence_marker <absolute-path>
# missing | expired (dangling symlink) | ok. Never reads file contents.
ralph_state_evidence_marker() {
  local path="${1:-}"
  if [[ -z "$path" ]]; then
    printf 'missing\n'
    return 0
  fi
  if [[ -L "$path" && ! -e "$path" ]]; then
    printf 'expired\n'
    return 0
  fi
  if [[ ! -e "$path" ]]; then
    printf 'missing\n'
    return 0
  fi
  printf 'ok\n'
}

# ralph_state_evidence_line <label> <absolute-path>
ralph_state_evidence_line() {
  local label="$1" path="$2" marker
  marker="$(ralph_state_evidence_marker "$path")"
  printf '  %s: %s\n' "$label" "$marker"
}

# Print one runs TSV row. Columns stay substring-compatible with older tests
# (run id, key, status, exact=/degraded=/hashes_match=) while adding kind,
# parent, stage, and evidence markers.
ralph_state_print_run_row() {
  local run_id="$1" kind="$2" key="$3" status="$4" parent="$5" stage="$6"
  local exact="$7" degraded="$8" hashes="$9" evidence="${10}"
  [[ -n "$parent" ]] || parent="-"
  [[ -n "$stage" ]] || stage="-"
  [[ -n "$key" ]] || key="-"
  [[ -n "$status" ]] || status="unknown"
  [[ -n "$evidence" ]] || evidence="missing"
  printf '%s\t%s\t%s\t%s\tparent=%s\tstage=%s\texact=%s\tdegraded=%s\thashes_match=%s\tevidence=%s\n' \
    "$run_id" "$kind" "$key" "$status" "$parent" "$stage" "$exact" "$degraded" "$hashes" "$evidence"
}

# ralph_state_plan_row_from_manifest <root> <manifest> [filter-key] [parent-override] [stage-override]
ralph_state_plan_row_from_manifest() {
  local root="$1" manifest="$2" filter_key="${3:-}" parent_override="${4:-}" stage_override="${5:-}"
  local run_id plan_key status plan_path parent stage counts exact degraded hashes evidence
  run_id="$(jq -r '.run_id // empty' "$manifest" 2>/dev/null)" || return 0
  [[ -n "$run_id" ]] || return 0
  plan_key="$(jq -r '.plan_key // empty' "$manifest" 2>/dev/null)"
  status="$(jq -r '.status // empty' "$manifest" 2>/dev/null)"
  plan_path="$(jq -r '.plan_path // empty' "$manifest" 2>/dev/null)"
  parent="$(jq -r '.parent.workflow_run_id // .parent.graph_run_id // empty' "$manifest" 2>/dev/null)"
  stage="$(jq -r '.parent.stage_id // empty' "$manifest" 2>/dev/null)"
  [[ -z "$parent_override" ]] || parent="$parent_override"
  [[ -z "$stage_override" ]] || stage="$stage_override"
  if [[ -n "$filter_key" && "$plan_key" != "$filter_key" ]]; then
    return 0
  fi
  counts="$(ralph_state_resume_counts "$root" "$run_id" "$plan_key" "$plan_path")"
  exact="$(printf '%s' "$counts" | awk -F'\t' '{print $1}')"
  degraded="$(printf '%s' "$counts" | awk -F'\t' '{print $2}')"
  hashes="$(printf '%s' "$counts" | awk -F'\t' '{print $3}')"
  evidence="$(ralph_state_evidence_marker "$manifest")"
  ralph_state_print_run_row "$run_id" "plan" "$plan_key" "$status" "$parent" "$stage" \
    "$exact" "$degraded" "$hashes" "$evidence"
}

ralph_state_runs() {
  local root="$1" key="${2:-}"
  local outers children seen_outers seen_plans emitted_children
  outers="$(mktemp)"
  children="$(mktemp)"
  seen_outers="$(mktemp)"
  seen_plans="$(mktemp)"
  emitted_children="$(mktemp)"
  # shellcheck disable=SC2064
  trap 'rm -f "'"$outers"'" "'"$children"'" "'"$seen_outers"'" "'"$seen_plans"'" "'"$emitted_children"'"' RETURN

  local catalog run_id kind status ns_or_key parent stage evidence
  local manifest f wf_file graph_file

  # Layout-2 catalogs are the authoritative outer-run list when present.
  if [[ -d "$root/runs" ]]; then
    for catalog in "$root"/runs/*/run.json; do
      [[ -f "$catalog" ]] || continue
      [[ "$(jq -r '.layoutVersion // empty' "$catalog" 2>/dev/null)" == 2 ]] || continue
      run_id="$(jq -r '.runId // empty' "$catalog" 2>/dev/null)"
      [[ -n "$run_id" ]] || run_id="$(basename "$(dirname -- "$catalog")")"
      kind="$(jq -r '.runKind // "unknown"' "$catalog" 2>/dev/null)"
      status="$(jq -r '.status // "unknown"' "$catalog" 2>/dev/null)"
      ns_or_key="$(jq -r '.artifactNamespace // .inputs.planKey // empty' "$catalog" 2>/dev/null)"
      parent="$(jq -r 'if .parent == null then empty else (.parent.runId // empty) end' "$catalog" 2>/dev/null)"
      stage="$(jq -r 'if .parent == null then empty else (.parent.stageId // empty) end' "$catalog" 2>/dev/null)"
      evidence="$(ralph_state_evidence_marker "$catalog")"

      if [[ -n "$key" ]]; then
        case "$kind" in
          plan)
            [[ "$ns_or_key" == "$key" ]] || continue
            ;;
          workflow|graph)
            [[ -z "$ns_or_key" || "$ns_or_key" == "$key" ]] || {
              # Keep outer when a matching child plan attempt exists below.
              local keep=0 child_manifest
              for child_manifest in "$root/runs/$run_id"/stages/*/attempts/*/run-manifest.json; do
                [[ -f "$child_manifest" ]] || continue
                [[ "$(jq -r '.plan_key // empty' "$child_manifest" 2>/dev/null)" == "$key" ]] && keep=1 && break
              done
              [[ "$keep" -eq 1 ]] || continue
            }
            ;;
          *) continue ;;
        esac
      fi

      printf '%s\n' "$run_id" >>"$seen_outers"
      # Prefer plan-manifest resume counts for standalone layout-2 plan runs.
      local leaf_manifest="$root/runs/$run_id/stages/plan/attempts/$run_id/run-manifest.json"
      local leaf_row=""
      if [[ "$kind" == "plan" && -f "$leaf_manifest" ]]; then
        leaf_row="$(ralph_state_plan_row_from_manifest "$root" "$leaf_manifest" "$key")"
      fi
      if [[ -n "$leaf_row" ]]; then
        printf '%s\n' "$run_id" >>"$seen_plans"
        printf '%s\n' "$leaf_row" >>"$outers"
      else
        ralph_state_print_run_row "$run_id" "$kind" "${ns_or_key:--}" "$status" "${parent:--}" "${stage:--}" \
          "0" "0" "unknown" "$evidence" >>"$outers"
      fi

      # Child plan attempts under this outer run (attempt id != outer run id).
      local attempt_id child_row stage_from_path
      for manifest in "$root/runs/$run_id"/stages/*/attempts/*/run-manifest.json; do
        [[ -f "$manifest" ]] || continue
        attempt_id="$(jq -r '.run_id // empty' "$manifest" 2>/dev/null)"
        [[ -n "$attempt_id" ]] || attempt_id="$(basename "$(dirname -- "$manifest")")"
        [[ "$attempt_id" == "$run_id" ]] && continue
        stage_from_path="$(basename "$(dirname "$(dirname "$(dirname -- "$manifest")")")")"
        child_row="$(ralph_state_plan_row_from_manifest "$root" "$manifest" "$key" "$run_id" "$stage_from_path")"
        [[ -n "$child_row" ]] || continue
        printf '%s\n' "$attempt_id" >>"$seen_plans"
        printf '%s#%s\n' "$run_id" "$child_row" >>"$children"
      done
    done
  fi

  # Layout-1 plan manifests (and any layout-2 attempt not already emitted).
  while IFS= read -r -d '' manifest; do
    [[ -f "$manifest" ]] || continue
    run_id="$(jq -r '.run_id // empty' "$manifest" 2>/dev/null)"
    [[ -n "$run_id" ]] || continue
    if grep -qxF "$run_id" "$seen_plans" 2>/dev/null; then
      continue
    fi
    parent="$(jq -r '.parent.workflow_run_id // .parent.graph_run_id // empty' "$manifest" 2>/dev/null)"
    local row
    row="$(ralph_state_plan_row_from_manifest "$root" "$manifest" "$key")"
    [[ -n "$row" ]] || continue
    printf '%s\n' "$run_id" >>"$seen_plans"
    if [[ -n "$parent" ]]; then
      printf '%s#%s\n' "$parent" "$row" >>"$children"
      # Ensure a placeholder outer exists when the parent ledger is absent.
      if ! grep -qxF "$parent" "$seen_outers" 2>/dev/null; then
        printf '%s\n' "$parent" >>"$seen_outers"
        evidence="missing"
        wf_file="$root/workflow-runs/$parent/run.json"
        if [[ -f "$wf_file" ]]; then
          evidence="$(ralph_state_evidence_marker "$wf_file")"
          status="$(jq -r '.state // .status // "unknown"' "$wf_file" 2>/dev/null)"
          ns_or_key="$(jq -r '.workflowId // .artifactNamespace // empty' "$wf_file" 2>/dev/null)"
          ralph_state_print_run_row "$parent" "workflow" "${ns_or_key:--}" "$status" "-" "-" \
            "0" "0" "unknown" "$evidence" >>"$outers"
        else
          local found_graph=0
          for graph_file in "$root"/graph-runs/*/"$parent"/run.json; do
            [[ -f "$graph_file" ]] || continue
            found_graph=1
            evidence="$(ralph_state_evidence_marker "$graph_file")"
            status="$(jq -r '.status // "unknown"' "$graph_file" 2>/dev/null)"
            ns_or_key="$(basename "$(dirname "$(dirname -- "$graph_file")")")"
            ralph_state_print_run_row "$parent" "graph" "$ns_or_key" "$status" "-" "-" \
              "0" "0" "unknown" "$evidence" >>"$outers"
            break
          done
          if [[ "$found_graph" -eq 0 ]]; then
            ralph_state_print_run_row "$parent" "unknown" "-" "missing" "-" "-" \
              "0" "0" "unknown" "missing" >>"$outers"
          fi
        fi
      fi
    else
      printf '%s\n' "$run_id" >>"$seen_outers"
      printf '%s\n' "$row" >>"$outers"
    fi
  done < <(find "$root/logs" -path '*/runs/*/run-manifest.json' -type f -print0 2>/dev/null)

  # Layout-1 workflow registry entries not already covered by a catalog.
  if [[ -d "$root/workflow-runs" ]]; then
    for wf_file in "$root"/workflow-runs/*/run.json; do
      [[ -f "$wf_file" ]] || continue
      run_id="$(jq -r '.runId // empty' "$wf_file" 2>/dev/null)"
      [[ -n "$run_id" ]] || run_id="$(basename "$(dirname -- "$wf_file")")"
      if grep -qxF "$run_id" "$seen_outers" 2>/dev/null; then
        continue
      fi
      if [[ -n "$key" ]]; then
        ns_or_key="$(jq -r '.workflowId // .artifactNamespace // empty' "$wf_file" 2>/dev/null)"
        [[ "$ns_or_key" == "$key" ]] || continue
      fi
      status="$(jq -r '.state // .status // "unknown"' "$wf_file" 2>/dev/null)"
      ns_or_key="$(jq -r '.workflowId // .artifactNamespace // empty' "$wf_file" 2>/dev/null)"
      evidence="$(ralph_state_evidence_marker "$wf_file")"
      printf '%s\n' "$run_id" >>"$seen_outers"
      ralph_state_print_run_row "$run_id" "workflow" "${ns_or_key:--}" "$status" "-" "-" \
        "0" "0" "unknown" "$evidence" >>"$outers"
    done
  fi

  # Layout-1 graph ledgers not already covered by a catalog.
  if [[ -d "$root/graph-runs" ]]; then
    for graph_file in "$root"/graph-runs/*/*/run.json; do
      [[ -f "$graph_file" ]] || continue
      run_id="$(jq -r '.runId // empty' "$graph_file" 2>/dev/null)"
      [[ -n "$run_id" ]] || run_id="$(basename "$(dirname -- "$graph_file")")"
      if grep -qxF "$run_id" "$seen_outers" 2>/dev/null; then
        continue
      fi
      ns_or_key="$(basename "$(dirname "$(dirname -- "$graph_file")")")"
      if [[ -n "$key" && "$ns_or_key" != "$key" ]]; then
        continue
      fi
      status="$(jq -r '.status // "unknown"' "$graph_file" 2>/dev/null)"
      evidence="$(ralph_state_evidence_marker "$graph_file")"
      printf '%s\n' "$run_id" >>"$seen_outers"
      ralph_state_print_run_row "$run_id" "graph" "$ns_or_key" "$status" "-" "-" \
        "0" "0" "unknown" "$evidence" >>"$outers"
    done
  fi

  # Legacy flat plan-usage-summary.json rows (outside runs/).
  while IFS= read -r -d '' f; do
    [[ "$f" == */runs/* ]] && continue
    [[ -z "$key" || "$f" == *"/logs/$key/"* ]] || continue
    jq -r '[(.run_id // "legacy"),"legacy",(.plan_key // "legacy"),(.status // "legacy"),"parent=-","stage=-","exact=0","degraded=0","hashes_match=unknown","evidence=ok"] | @tsv' "$f" 2>/dev/null
  done < <(find "$root/logs" -mindepth 2 -maxdepth 2 -type f -name 'plan-usage-summary.json' -print0 2>/dev/null)

  # Emit outers with children grouped immediately beneath each parent.
  local outer_line parent_id child_line
  while IFS= read -r outer_line || [[ -n "$outer_line" ]]; do
    [[ -n "$outer_line" ]] || continue
    printf '%s\n' "$outer_line"
    parent_id="${outer_line%%$'\t'*}"
    while IFS='#' read -r _pid child_line || [[ -n "$child_line" ]]; do
      [[ -n "$_pid" ]] || continue
      [[ "$_pid" == "$parent_id" ]] || continue
      printf '%s\n' "$child_line"
      printf '%s#%s\n' "$_pid" "$child_line" >>"$emitted_children"
    done <"$children"
  done <"$outers"

  # Orphan children whose parent never appeared as an outer.
  while IFS='#' read -r parent_id child_line || [[ -n "$child_line" ]]; do
    [[ -n "$parent_id" ]] || continue
    if grep -qxF "$parent_id#$child_line" "$emitted_children" 2>/dev/null; then
      continue
    fi
    printf '%s\n' "$child_line"
  done <"$children"
}

ralph_state_show_todo_sessions() {
  local root="$1" run_id="$2" plan_key="$3" plan_path="$4"
  local hashes dir rec capture rec_hash session_id todo_id reason eligible
  hashes="$(ralph_state_plan_todo_hashes "$plan_path" | tr '\n' ' ')"
  dir="$(ralph_state_todo_sessions_dir "$root" "$plan_key")"
  printf 'todo_sessions:\n'
  [[ -d "$dir" ]] || { printf '  (none)\n'; return 0; }
  for rec in "$dir"/*.json; do
    [[ -f "$rec" ]] || continue
    [[ "$(jq -r '.identity.runId // empty' "$rec")" == "$run_id" ]] || continue
    capture="$(jq -r '.capture // empty' "$rec")"
    rec_hash="$(jq -r '.identity.todoHash // empty' "$rec")"
    session_id="$(jq -r '.session_id // empty' "$rec")"
    todo_id="$(jq -r '.identity.todoId // .manifest_key // empty' "$rec")"
    reason="$(ralph_state_resume_reason "$capture" "$rec_hash" "$hashes")"
    eligible="no"
    if [[ "$capture" == "exact" && "$reason" == "foreign-run-id" ]]; then
      eligible="yes"
    fi
    if [[ "$reason" == "mismatched-todo-hash" ]]; then
      printf '  %s\tsession=%s\tcapture=%s\teligible=%s\treason=mismatched-todo-hash (blocker)\n' \
        "$todo_id" "$session_id" "$capture" "$eligible"
    else
      printf '  %s\tsession=%s\tcapture=%s\teligible=%s\treason=%s\n' \
        "$todo_id" "$session_id" "$capture" "$eligible" "$reason"
    fi
  done
}

ralph_state_show_plan_manifest() {
  local root="$1" run_id="$2" manifest="$3"
  local plan_key plan_path
  cat "$manifest"
  printf '\n'
  printf 'evidence:\n'
  ralph_state_evidence_line "run-manifest" "$manifest"
  plan_key="$(jq -r '.plan_key // empty' "$manifest")"
  plan_path="$(jq -r '.plan_path // empty' "$manifest")"
  local artifacts_rel artifacts_abs parent stage attempt_dir
  artifacts_rel="$(jq -r '.paths.artifacts_dir // empty' "$manifest" 2>/dev/null)"
  if [[ -n "$artifacts_rel" ]]; then
    artifacts_abs="$root/$artifacts_rel"
    ralph_state_evidence_line "artifacts" "$artifacts_abs"
  else
    printf '  artifacts: missing\n'
  fi
  parent="$(jq -r '.parent.workflow_run_id // empty' "$manifest")"
  stage="$(jq -r '.parent.stage_id // empty' "$manifest")"
  if [[ -n "$parent" && -n "$stage" ]]; then
    attempt_dir="$(ralph_state_attempt_dir "$root" "$parent" "$stage" "$run_id" 2>/dev/null || true)"
    ralph_state_evidence_line "attempt-dir" "${attempt_dir:-}"
  fi
  printf '\n'
  ralph_state_show_todo_sessions "$root" "$run_id" "$plan_key" "$plan_path"
}

ralph_state_show_children() {
  local root="$1" outer_id="$2"
  local manifest attempt_id stage_id status evidence found=0 seen_children
  seen_children="$(mktemp)"
  printf 'children:\n'
  # Layout 2 attempts under the outer run.
  for manifest in "$root/runs/$outer_id"/stages/*/attempts/*/run-manifest.json; do
    [[ -f "$manifest" ]] || continue
    attempt_id="$(jq -r '.run_id // empty' "$manifest" 2>/dev/null)"
    [[ -n "$attempt_id" ]] || attempt_id="$(basename "$(dirname -- "$manifest")")"
    [[ "$attempt_id" == "$outer_id" ]] && continue
    # .../stages/<stage>/attempts/<attempt>/run-manifest.json
    stage_id="$(basename "$(dirname "$(dirname "$(dirname -- "$manifest")")")")"
    status="$(jq -r '.status // "unknown"' "$manifest" 2>/dev/null)"
    evidence="$(ralph_state_evidence_marker "$manifest")"
    printf '  %s\tstage=%s\tstatus=%s\tevidence=%s\n' "$attempt_id" "$stage_id" "$status" "$evidence"
    printf '%s\n' "$attempt_id" >>"$seen_children"
    found=1
  done
  # Layout 1 plan manifests that name this outer as parent.
  while IFS= read -r -d '' manifest; do
    [[ -f "$manifest" ]] || continue
    local p
    p="$(jq -r '.parent.workflow_run_id // .parent.graph_run_id // empty' "$manifest" 2>/dev/null)"
    [[ "$p" == "$outer_id" ]] || continue
    attempt_id="$(jq -r '.run_id // empty' "$manifest" 2>/dev/null)"
    [[ -n "$attempt_id" ]] || continue
    if grep -qxF "$attempt_id" "$seen_children" 2>/dev/null; then
      continue
    fi
    stage_id="$(jq -r '.parent.stage_id // "-"' "$manifest" 2>/dev/null)"
    status="$(jq -r '.status // "unknown"' "$manifest" 2>/dev/null)"
    evidence="$(ralph_state_evidence_marker "$manifest")"
    printf '  %s\tstage=%s\tstatus=%s\tevidence=%s\n' "$attempt_id" "$stage_id" "$status" "$evidence"
    found=1
  done < <(find "$root/logs" -path '*/runs/*/run-manifest.json' -type f -print0 2>/dev/null)
  rm -f "$seen_children"
  if [[ "$found" -eq 0 ]]; then
    printf '  (none)\n'
  fi
}

ralph_state_show() {
  local root="$1" run_id="$2"
  local catalog manifest wf_file graph_file engine_dir

  # Prefer layout-2 catalog when present.
  catalog="$root/runs/$run_id/run.json"
  if [[ -f "$catalog" ]] && [[ "$(jq -r '.layoutVersion // empty' "$catalog" 2>/dev/null)" == 2 ]]; then
    cat "$catalog"
    printf '\n'
    printf 'evidence:\n'
    ralph_state_evidence_line "catalog" "$catalog"
    local kind status ns inputs_dir
    kind="$(jq -r '.runKind // "unknown"' "$catalog" 2>/dev/null)"
    status="$(jq -r '.status // "unknown"' "$catalog" 2>/dev/null)"
    ns="$(jq -r '.artifactNamespace // empty' "$catalog" 2>/dev/null)"
    inputs_dir="$root/runs/$run_id/inputs"
    ralph_state_evidence_line "inputs" "$inputs_dir"
    if [[ -n "$ns" ]]; then
      ralph_state_evidence_line "artifacts/$ns" "$root/artifacts/$ns"
    else
      printf '  artifacts: missing\n'
    fi
    case "$kind" in
      workflow)
        engine_dir="$(ralph_state_engine_dir "$root" "$run_id" workflow 2>/dev/null || true)"
        if [[ -n "$engine_dir" ]]; then
          ralph_state_evidence_line "engine/workflow" "$engine_dir/run.json"
        else
          printf '  engine/workflow: missing\n'
        fi
        ;;
      graph)
        engine_dir="$(ralph_state_engine_dir "$root" "$run_id" graph 2>/dev/null || true)"
        if [[ -n "$engine_dir" ]]; then
          ralph_state_evidence_line "engine/graph" "$engine_dir/run.json"
        else
          printf '  engine/graph: missing\n'
        fi
        ;;
      plan)
        manifest="$root/runs/$run_id/stages/plan/attempts/$run_id/run-manifest.json"
        ralph_state_evidence_line "run-manifest" "$manifest"
        ;;
    esac
    # Stages from catalog with evidence for each attempt dir.
    printf '\nstages:\n'
    local stage_json stage_id attempt_id stage_status attempt_path
    if jq -e '.stages | length > 0' "$catalog" >/dev/null 2>&1; then
      while IFS=$'\t' read -r stage_id attempt_id stage_status; do
        [[ -n "$stage_id" ]] || continue
        attempt_path="$(ralph_state_attempt_dir "$root" "$run_id" "$stage_id" "$attempt_id" 2>/dev/null || true)"
        printf '  %s\tattempt=%s\tstatus=%s\tevidence=%s\n' \
          "$stage_id" "${attempt_id:-missing}" "${stage_status:-missing}" \
          "$(ralph_state_evidence_marker "${attempt_path:-}")"
      done < <(jq -r '.stages[] | [.stageId // "missing", (.attemptId // .latestAttemptId // "missing"), (.status // "missing")] | @tsv' "$catalog" 2>/dev/null)
    else
      printf '  (none)\n'
    fi
    printf '\n'
    ralph_state_show_children "$root" "$run_id"
    # Plan resume details when this catalog is a standalone plan.
    if [[ "$kind" == "plan" && -f "$manifest" ]]; then
      printf '\n'
      local plan_key plan_path
      plan_key="$(jq -r '.plan_key // empty' "$manifest")"
      plan_path="$(jq -r '.plan_path // empty' "$manifest")"
      ralph_state_show_todo_sessions "$root" "$run_id" "$plan_key" "$plan_path"
    fi
    return 0
  fi

  # Layout-1 / layout-2 plan manifest (attempt may live under an outer run).
  manifest="$(find "$root/logs" -path "*/runs/$run_id/run-manifest.json" -type f 2>/dev/null | head -n 1)"
  if [[ -z "$manifest" || ! -f "$manifest" ]]; then
    # Also search layout-2 attempt trees.
    manifest="$(find "$root/runs" -path "*/attempts/$run_id/run-manifest.json" -type f 2>/dev/null | head -n 1)"
  fi
  if [[ -n "$manifest" && -f "$manifest" ]]; then
    ralph_state_show_plan_manifest "$root" "$run_id" "$manifest"
    return 0
  fi

  # Layout-1 workflow registry.
  wf_file="$root/workflow-runs/$run_id/run.json"
  if [[ -f "$wf_file" ]]; then
    cat "$wf_file"
    printf '\n'
    printf 'evidence:\n'
    ralph_state_evidence_line "workflow-run" "$wf_file"
    printf '\n'
    ralph_state_show_children "$root" "$run_id"
    return 0
  fi

  # Layout-1 graph ledger.
  for graph_file in "$root"/graph-runs/*/"$run_id"/run.json; do
    [[ -f "$graph_file" ]] || continue
    cat "$graph_file"
    printf '\n'
    printf 'evidence:\n'
    ralph_state_evidence_line "graph-run" "$graph_file"
    ralph_state_evidence_line "graph.json" "$(dirname -- "$graph_file")/graph.json"
    printf '\n'
    ralph_state_show_children "$root" "$run_id"
    return 0
  done

  # Nothing found: still report explicit missing markers (never omit).
  printf 'run_id: %s\n' "$run_id"
  printf 'evidence:\n'
  printf '  catalog: missing\n'
  printf '  run-manifest: missing\n'
  printf '  workflow-run: missing\n'
  printf '  graph-run: missing\n'
  return 0
}

ralph_state_status() { local root="$1" d; [[ -d "$root" ]] || { echo 'state directory is empty'; return 0; }; for d in "$root"/*; do [[ -e "$d" ]] || continue; printf '%s\t%s files\t%s\n' "$(basename "$d")" "$(find "$d" -type f 2>/dev/null | wc -l | tr -d ' ')" "$(du -sh "$d" 2>/dev/null | awk '{print $1}')"; done; }

# --- Ownership map classify / orphans / prune ---------------------------------

# Known top-level names from the state ownership map (layout 1 and 2).
ralph_state_known_top_level() {
  case "$1" in
    runs|artifacts|plans|workflows|docs|security|cache|internal|logs|graph-runs|workflow-runs|orchestration-plans|delegated-runs|handoffs|manual-verification|sessions|runtime-config|processes|tool-results|repo-map|search-context|metrics|memory|command-profiles|setup-journal|hooks-config.jsonl|README.md|README.ralph.md) return 0 ;;
    *) return 1 ;;
  esac
}

# ralph_state_classify_relpath <relative-path>
# Mirrors scripts/check-state-layout.sh classify(); prints a category slug.
ralph_state_classify_relpath() {
  local path="$1"
  case "$path" in
    logs/*/runs/index.jsonl) printf 'run-index-v1\n' ;;
    logs/*/runs/*/*) printf 'plan-attempt-v1\n' ;;
    logs/*) printf 'legacy-log-v1\n' ;;
    graph-runs/*) printf 'graph-engine-v1\n' ;;
    workflow-runs/*) printf 'workflow-engine-v1\n' ;;
    orchestration-plans/*) printf 'sequential-engine-v1\n' ;;
    delegated-runs/*) printf 'delegation-v1\n' ;;
    handoffs/*) printf 'handoff-v1\n' ;;
    manual-verification/*) printf 'manual-verification-v1\n' ;;
    plans/*control*|plans/materialized/*) printf 'control-plan-v1\n' ;;
    runs/*/engine/graph/*|runs/*/engine/graph) printf 'graph-engine-v2\n' ;;
    runs/*/engine/workflow/*|runs/*/engine/workflow) printf 'workflow-engine-v2\n' ;;
    runs/*/engine/sequential/*|runs/*/engine/sequential) printf 'sequential-engine-v2\n' ;;
    runs/*/engine/delegation/*|runs/*/engine/delegation) printf 'delegation-v2\n' ;;
    runs/*/stages/*/controls/*) printf 'stage-control-v2\n' ;;
    runs/*/stages/*/attempts/*) printf 'plan-attempt-v2\n' ;;
    runs/*/inputs/*|runs/*/inputs) printf 'run-input-v2\n' ;;
    runs/*/run.json) printf 'run-catalog-v2\n' ;;
    runs/*) printf 'run-catalog-v2\n' ;;
    internal/*|sessions/*|runtime-config/*|processes/*|setup-journal/*|memory/*|command-profiles/*|hooks-config.jsonl) printf 'internal\n' ;;
    cache/*|tool-results/*|repo-map/*|search-context/*|metrics/*) printf 'cache\n' ;;
    artifacts/*) printf 'artifacts\n' ;;
    workflows/*|docs/*|security/*|plans/*) printf 'operator-data\n' ;;
    *) printf 'unclassified\n' ;;
  esac
}

ralph_state_bytes() {
  local path="$1" kb
  if [[ -f "$path" ]]; then
    wc -c <"$path" 2>/dev/null | tr -d '[:space:]'
    return 0
  fi
  if [[ -d "$path" ]]; then
    kb="$(du -sk "$path" 2>/dev/null | awk '{print $1 + 0}')"
    printf '%s\n' "$((kb * 1024))"
    return 0
  fi
  printf '0\n'
}

ralph_state_ensure_retention() {
  if declare -F ralph_retention_eligibility >/dev/null 2>&1; then
    return 0
  fi
  # shellcheck source=retention.sh
  source "$_state_dir/retention.sh"
}

# Receipt home: layout 2 -> internal/cleanup-receipts; layout 1 -> logs/cleanup-receipts.
ralph_state_cleanup_receipts_dir() {
  local root="$1" version
  version="$(ralph_state_layout_for_new_run 2>/dev/null || printf '2\n')"
  case "$version" in
    1) printf '%s/logs/cleanup-receipts\n' "${root%/}" ;;
    *) printf '%s/internal/cleanup-receipts\n' "${root%/}" ;;
  esac
}

# ralph_state_orphans <state-root> [--json]
# Read-only report of paths the ownership map cannot classify. Never deletes.
ralph_state_orphans() {
  local root="$1"; shift || true
  local json=0 entry name rel bytes total_bytes=0 count=0
  local -a paths=() reasons=() sizes=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --json) json=1 ;;
      -h|--help) ralph_state_usage; return 0 ;;
      *) echo "Error: orphans accepts only --json" >&2; return 2 ;;
    esac
    shift
  done
  [[ -d "$root" ]] || {
    if [[ "$json" -eq 1 ]]; then
      printf '{"orphans":[],"totalBytes":0}\n'
    else
      printf 'orphans: none\n'
    fi
    return 0
  }
  for entry in "$root"/* "$root"/.[!.]* "$root"/..?*; do
    [[ -e "$entry" || -L "$entry" ]] || continue
    name="$(basename -- "$entry")"
    [[ "$name" == "." || "$name" == ".." ]] && continue
    if ralph_state_known_top_level "$name"; then
      continue
    fi
    rel="$name"
    bytes="$(ralph_state_bytes "$entry")"
    paths+=("$rel")
    reasons+=("unclassified")
    sizes+=("$bytes")
    total_bytes=$((total_bytes + bytes))
    count=$((count + 1))
  done
  if [[ "$json" -eq 1 ]]; then
    if ! command -v jq >/dev/null 2>&1; then
      echo "Error: --json requires jq" >&2
      return 1
    fi
    local i payload='[]'
    for ((i = 0; i < count; i++)); do
      payload="$(jq -c --arg path "${paths[$i]}" --arg reason "${reasons[$i]}" --argjson bytes "${sizes[$i]}" \
        '. + [{path:$path,reason:$reason,bytes:$bytes}]' <<<"$payload")"
    done
    jq -nc --argjson orphans "$payload" --argjson total "$total_bytes" \
      '{orphans:$orphans,totalBytes:$total}'
    return 0
  fi
  if [[ "$count" -eq 0 ]]; then
    printf 'orphans: none\n'
    return 0
  fi
  local i
  for ((i = 0; i < count; i++)); do
    printf '%s\t%s\t%s bytes\n' "${paths[$i]}" "${reasons[$i]}" "${sizes[$i]}"
  done
  printf 'total\t%s paths\t%s bytes\n' "$count" "$total_bytes"
  printf 'note: unclassified paths are retained; never eligible for prune\n'
}

# Emit candidate lines: path<TAB>kind<TAB>reason<TAB>bytes<TAB>namespace
# Only paths that are currently eligible AND beyond retention limits.
ralph_state_prune_emit_dir_candidates() {
  local state_root="$1" parent="$2" kind="$3" max_count="$4" max_age_days="$5" namespace="${6:-}"
  local cutoff=0 kept=0 entry path reason bytes mtime
  [[ -d "$parent" ]] || return 0
  if [[ "$max_age_days" -gt 0 ]]; then
    cutoff="$(cleanup_plan_epoch_days_ago "$max_age_days")"
  fi
  while IFS= read -r entry; do
    path="$parent/$entry"
    [[ -d "$path" && ! -L "$path" ]] || continue
    reason="$(ralph_retention_eligibility "$state_root" "$kind" "$path" "$namespace" 2>/dev/null || true)"
    [[ -n "$reason" ]] || reason="unknown-owner"
    [[ "$reason" == "eligible" ]] || continue
    kept=$((kept + 1))
    mtime="$(cleanup_plan_file_mtime "$path")"
    if { [[ "$max_age_days" -gt 0 && "$mtime" -lt "$cutoff" ]] || [[ "$max_count" -gt 0 && "$kept" -gt "$max_count" ]]; }; then
      bytes="$(ralph_state_bytes "$path")"
      printf '%s\t%s\t%s\t%s\t%s\n' "$path" "$kind" "$reason" "$bytes" "$namespace"
    fi
  done < <(ls -t1 "$parent" 2>/dev/null || true)
}

ralph_state_prune_emit_file_candidates() {
  local state_root="$1" parent="$2" kind="$3" max_count="$4" max_age_days="$5" namespace="${6:-}"
  local cutoff=0 kept=0 entry path reason bytes mtime
  [[ -d "$parent" ]] || return 0
  if [[ "$max_age_days" -gt 0 ]]; then
    cutoff="$(cleanup_plan_epoch_days_ago "$max_age_days")"
  fi
  while IFS= read -r entry; do
    path="$parent/$entry"
    [[ -f "$path" && ! -L "$path" ]] || continue
    reason="$(ralph_retention_eligibility "$state_root" "$kind" "$path" "$namespace" 2>/dev/null || true)"
    [[ -n "$reason" ]] || reason="unknown-owner"
    [[ "$reason" == "eligible" ]] || continue
    kept=$((kept + 1))
    mtime="$(cleanup_plan_file_mtime "$path")"
    if { [[ "$max_age_days" -gt 0 && "$mtime" -lt "$cutoff" ]] || [[ "$max_count" -gt 0 && "$kept" -gt "$max_count" ]]; }; then
      bytes="$(ralph_state_bytes "$path")"
      printf '%s\t%s\t%s\t%s\t%s\n' "$path" "$kind" "$reason" "$bytes" "$namespace"
    fi
  done < <(ls -t1 "$parent" 2>/dev/null || true)
}

ralph_state_prune_emit_artifact_candidates() {
  local state_root="$1" artifacts_root="$2"
  local max_age max_bytes path namespace reason bytes mtime cutoff=0
  [[ -d "$artifacts_root" ]] || return 0
  max_age="$(ralph_retention_artifacts_age_days)"
  max_bytes="$(ralph_retention_artifacts_max_bytes)"
  if [[ "$max_age" -gt 0 ]]; then
    cutoff="$(cleanup_plan_epoch_days_ago "$max_age")"
  fi
  for path in "$artifacts_root"/*; do
    [[ -d "$path" && ! -L "$path" ]] || continue
    namespace="$(basename -- "$path")"
    reason="$(ralph_retention_eligibility "$state_root" artifact "$path" "$namespace" 2>/dev/null || true)"
    [[ -n "$reason" ]] || reason="unknown-owner"
    [[ "$reason" == "eligible" ]] || continue
    mtime="$(cleanup_plan_file_mtime "$path")"
    bytes="$(ralph_state_bytes "$path")"
    if { [[ "$max_age" -gt 0 && "$mtime" -lt "$cutoff" ]] || [[ "$max_bytes" -gt 0 && "$bytes" -gt "$max_bytes" ]]; }; then
      printf '%s\t%s\t%s\t%s\t%s\n' "$path" "artifact" "$reason" "$bytes" "$namespace"
    fi
  done
}

ralph_state_prune_emit_graph_candidates() {
  local state_root="$1"
  local max_age max_count cutoff=0 ns_dir run_id run_dir latest_run_id kept reason bytes mtime should_prune
  max_age="${RALPH_GRAPH_RUN_MAX_AGE_DAYS:-30}"
  max_count="${RALPH_GRAPH_RUN_MAX_COUNT:-10}"
  [[ "$max_age" =~ ^[0-9]+$ ]] || max_age=30
  [[ "$max_count" =~ ^[0-9]+$ ]] || max_count=10
  if [[ "$max_age" -gt 0 ]]; then
    cutoff="$(cleanup_plan_epoch_days_ago "$max_age")"
  fi
  # Layout 1: graph-runs/<ns>/<run-id>/
  for ns_dir in "$state_root"/graph-runs/*; do
    [[ -d "$ns_dir" ]] || continue
    latest_run_id=""
    if [[ -L "$ns_dir/latest" ]]; then
      latest_run_id="$(basename "$(readlink "$ns_dir/latest")")" || true
    fi
    kept=0
    while IFS= read -r run_id; do
      [[ "$run_id" == "latest" ]] && continue
      run_dir="$ns_dir/$run_id"
      [[ -d "$run_dir" && ! -L "$run_dir" ]] || continue
      [[ -z "$latest_run_id" || "$run_id" != "$latest_run_id" ]] || continue
      reason="$(ralph_retention_eligibility "$state_root" graph-run "$run_dir" "$(basename -- "$ns_dir")" 2>/dev/null || true)"
      [[ -n "$reason" ]] || reason="unknown-owner"
      [[ "$reason" == "eligible" ]] || continue
      should_prune=0
      mtime="$(cleanup_plan_file_mtime "$run_dir")"
      if [[ "$max_age" -gt 0 && "$mtime" -lt "$cutoff" ]]; then
        should_prune=1
      fi
      if [[ "$should_prune" -eq 0 && "$max_count" -gt 0 && "$kept" -ge "$max_count" ]]; then
        should_prune=1
      fi
      if [[ "$should_prune" -eq 1 ]]; then
        bytes="$(ralph_state_bytes "$run_dir")"
        printf '%s\t%s\t%s\t%s\t%s\n' "$run_dir" "graph-run" "$reason" "$bytes" "$(basename -- "$ns_dir")"
      else
        kept=$((kept + 1))
      fi
    done < <(ls -t1 "$ns_dir" 2>/dev/null || true)
  done
  # Layout-2 graph ledgers are pruned with their runs/<run-id>/ subtree.
}

# Collect all prune candidates for a state root (stdout TSV).
ralph_state_prune_collect() {
  local state_root="$1" runs journals
  ralph_state_ensure_retention
  # Plan attempts (layout 1 + 2)
  for runs in "$state_root"/logs/*/runs; do
    [[ -d "$runs" ]] || continue
    ralph_state_prune_emit_dir_candidates "$state_root" "$runs" plan-run \
      "$(ralph_retention_runs_count)" "$(ralph_retention_runs_age_days)"
  done
  # Layout-2 runs are pruned as whole runs/<run-id>/ subtrees (catalog,
  # attempts, and engine ledgers together), matching automatic retention.
  ralph_state_prune_emit_dir_candidates "$state_root" "$state_root/runs" run \
    "$(ralph_retention_runs_count)" "$(ralph_retention_runs_age_days)"
  # Journals (layout 1 + 2)
  for journals in "$state_root"/runtime-config/*/journals "$state_root"/internal/runtime-config/*/journals; do
    [[ -d "$journals" ]] || continue
    ralph_state_prune_emit_file_candidates "$state_root" "$journals" journal \
      "$(ralph_retention_journals_count)" "$(ralph_retention_journals_age_days)"
  done
  # Artifacts
  ralph_state_prune_emit_artifact_candidates "$state_root" "$state_root/artifacts"
  # Graph runs
  ralph_state_prune_emit_graph_candidates "$state_root"
}

ralph_state_prune_write_receipt() {
  local root="$1" receipt_dir stamp receipt removed_json skipped_json
  receipt_dir="$(ralph_state_cleanup_receipts_dir "$root")"
  mkdir -p "$receipt_dir" || return 1
  stamp="$(date -u +%Y%m%dT%H%M%SZ 2>/dev/null || date -u +%Y%m%dT%H%M%S)"
  receipt="$receipt_dir/${stamp}.json"
  # Avoid clobbering if two applies share the same second.
  if [[ -e "$receipt" ]]; then
    receipt="$receipt_dir/${stamp}-$$.json"
  fi
  removed_json="${2:-[]}"
  skipped_json="${3:-[]}"
  if command -v jq >/dev/null 2>&1; then
    jq -n \
      --arg created "$stamp" \
      --argjson removed "$removed_json" \
      --argjson skipped "$skipped_json" \
      '{schemaVersion:1,kind:"ralph_cleanup_receipt",createdAt:$created,removed:$removed,skipped:$skipped}' \
      >"$receipt" || return 1
  else
    printf '{"schemaVersion":1,"kind":"ralph_cleanup_receipt","createdAt":"%s","removed":%s,"skipped":%s}\n' \
      "$stamp" "$removed_json" "$skipped_json" >"$receipt" || return 1
  fi
  printf '%s\n' "$receipt"
}

# ralph_state_prune <state-root> [--apply] [--json] [--dry-run]
# Preview (default) lists eligible retention candidates. --apply removes only
# paths still eligible on re-check. Unknown/orphan paths are never candidates.
ralph_state_prune() {
  local root="$1"; shift || true
  local apply=0 json=0 path kind reason bytes namespace now_reason
  local total_bytes=0 count=0 removed_count=0 skipped_count=0 receipt=""
  local -a c_paths=() c_kinds=() c_reasons=() c_bytes=() c_ns=()
  local removed_json='[]' skipped_json='[]'

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --apply) apply=1 ;;
      --json) json=1 ;;
      --dry-run) apply=0 ;; # preview alias
      -h|--help) ralph_state_usage; return 0 ;;
      *) echo "Error: prune accepts --apply, --json, --dry-run" >&2; return 2 ;;
    esac
    shift
  done

  [[ -d "$root" ]] || {
    if [[ "$json" -eq 1 ]]; then
      printf '{"mode":"%s","candidates":[],"removed":[],"skipped":[],"totalBytes":0}\n' \
        "$([[ "$apply" -eq 1 ]] && echo apply || echo preview)"
    else
      printf 'prune: state directory is empty\n'
    fi
    return 0
  }

  ralph_state_ensure_retention

  local line
  while IFS=$'\t' read -r path kind reason bytes namespace; do
    [[ -n "$path" ]] || continue
    c_paths+=("$path")
    c_kinds+=("$kind")
    c_reasons+=("$reason")
    c_bytes+=("$bytes")
    c_ns+=("$namespace")
    total_bytes=$((total_bytes + bytes))
    count=$((count + 1))
  done < <(ralph_state_prune_collect "$root")

  if [[ "$apply" -eq 1 ]]; then
    local i
    for ((i = 0; i < count; i++)); do
      path="${c_paths[$i]}"
      kind="${c_kinds[$i]}"
      namespace="${c_ns[$i]}"
      bytes="${c_bytes[$i]}"
      # Re-evaluate immediately before removal.
      now_reason="$(ralph_retention_eligibility "$root" "$kind" "$path" "$namespace" 2>/dev/null || true)"
      [[ -n "$now_reason" ]] || now_reason="unknown-owner"
      if [[ "$now_reason" != "eligible" ]]; then
        skipped_count=$((skipped_count + 1))
        if command -v jq >/dev/null 2>&1; then
          skipped_json="$(jq -c --arg path "$path" --arg kind "$kind" --arg was "${c_reasons[$i]}" \
            --arg now "$now_reason" --argjson bytes "$bytes" \
            '. + [{path:$path,kind:$kind,previousReason:$was,reason:$now,bytes:$bytes}]' <<<"$skipped_json")"
        fi
        if [[ "$json" -eq 0 ]]; then
          printf 'skipped\t%s\t%s -> %s\n' "$path" "${c_reasons[$i]}" "$now_reason"
        fi
        continue
      fi
      if [[ -e "$path" || -L "$path" ]]; then
        rm -rf "$path" || {
          echo "Error: failed to remove $path" >&2
          return 1
        }
      fi
      removed_count=$((removed_count + 1))
      if command -v jq >/dev/null 2>&1; then
        removed_json="$(jq -c --arg path "$path" --arg kind "$kind" --argjson bytes "$bytes" \
          '. + [{path:$path,kind:$kind,bytes:$bytes,reason:"eligible"}]' <<<"$removed_json")"
      fi
      if [[ "$json" -eq 0 ]]; then
        printf 'removed\t%s\t%s bytes\n' "$path" "$bytes"
      fi
    done
    # Every --apply writes a receipt, including empty removed/skipped sets.
    receipt="$(ralph_state_prune_write_receipt "$root" "$removed_json" "$skipped_json")" || return 1
    if [[ "$json" -eq 0 ]]; then
      printf 'receipt\t%s\n' "$receipt"
      printf 'total\tremoved=%s\tskipped=%s\n' "$removed_count" "$skipped_count"
    fi
  else
    # Preview
    if [[ "$json" -eq 0 ]]; then
      local i
      for ((i = 0; i < count; i++)); do
        printf '%s\t%s\t%s\t%s bytes\n' "${c_paths[$i]}" "${c_kinds[$i]}" "${c_reasons[$i]}" "${c_bytes[$i]}"
      done
      printf 'total\t%s candidates\t%s bytes\n' "$count" "$total_bytes"
    fi
  fi

  if [[ "$json" -eq 1 ]]; then
    if ! command -v jq >/dev/null 2>&1; then
      echo "Error: --json requires jq" >&2
      return 1
    fi
    local mode candidates_json='[]' i
    if [[ "$apply" -eq 1 ]]; then mode=apply; else mode=preview; fi
    for ((i = 0; i < count; i++)); do
      candidates_json="$(jq -c --arg path "${c_paths[$i]}" --arg kind "${c_kinds[$i]}" \
        --arg reason "${c_reasons[$i]}" --argjson bytes "${c_bytes[$i]}" \
        '. + [{path:$path,kind:$kind,reason:$reason,bytes:$bytes}]' <<<"$candidates_json")"
    done
    jq -n \
      --arg mode "$mode" \
      --argjson candidates "$candidates_json" \
      --argjson removed "$removed_json" \
      --argjson skipped "$skipped_json" \
      --argjson total "$total_bytes" \
      --arg receipt "$receipt" \
      '{mode:$mode,candidates:$candidates,removed:$removed,skipped:$skipped,totalBytes:$total} + (if $receipt != "" then {receipt:$receipt} else {} end)'
  fi
  return 0
}

if [[ "${BASH_SOURCE[0]-}" == "$0" ]]; then
  cmd="${1:-status}"; shift || true; root="$(ralph_state_root)"
  case "$cmd" in
   status) ralph_state_status "$root";;
   runs) [[ "${1:-}" == "--plan" ]] && { ralph_state_runs "$root" "${2:-}"; } || ralph_state_runs "$root";;
   show) [[ -n "${1:-}" ]] || { ralph_state_usage >&2; exit 2; }; ralph_state_show "$root" "$1";;
   prune) ralph_state_prune "$root" "$@";;
   reindex) echo "state reindex: legacy manifests are synthesized on demand";;
   orphans) ralph_state_orphans "$root" "$@";;
   -h|--help|help) ralph_state_usage;;
   *) echo "Error: unknown state command: $cmd" >&2; exit 2;;
  esac
fi
