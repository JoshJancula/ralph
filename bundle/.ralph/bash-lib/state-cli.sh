#!/usr/bin/env bash
_state_dir="${BASH_SOURCE[0]%/*}"; source "$_state_dir/help-render.sh"
ralph_state_root() { printf '%s\n' "${RALPH_PLAN_WORKSPACE_ROOT:-$PWD/.ralph-workspace}"; }
ralph_state_usage() { cat <<'EOF' | ralph_help_render
Usage: ralph state <status|runs|show|prune|reindex|orphans> [options]
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
  printf '%s/sessions/%s/todo-sessions\n' "${root%/}" "$plan_key"
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

ralph_state_runs() {
  local root="$1" key="${2:-}" f run_id plan_key status plan_path counts
  find "$root/logs" -path '*/runs/*/run-manifest.json' -type f 2>/dev/null | while IFS= read -r f; do
    [[ -z "$key" || "$f" == *"/logs/$key/"* ]] || continue
    run_id="$(jq -r '.run_id // empty' "$f")"
    plan_key="$(jq -r '.plan_key // empty' "$f")"
    status="$(jq -r '.status // empty' "$f")"
    plan_path="$(jq -r '.plan_path // empty' "$f")"
    counts="$(ralph_state_resume_counts "$root" "$run_id" "$plan_key" "$plan_path")"
    printf '%s\t%s\t%s\texact=%s\tdegraded=%s\thashes_match=%s\n' \
      "$run_id" "$plan_key" "$status" \
      "$(printf '%s' "$counts" | awk -F'\t' '{print $1}')" \
      "$(printf '%s' "$counts" | awk -F'\t' '{print $2}')" \
      "$(printf '%s' "$counts" | awk -F'\t' '{print $3}')"
  done
  find "$root/logs" -mindepth 2 -maxdepth 2 -type f -name 'plan-usage-summary.json' 2>/dev/null | while IFS= read -r f; do
    [[ "$f" == */runs/* ]] && continue
    [[ -z "$key" || "$f" == *"/logs/$key/"* ]] || continue
    jq -r '[(.run_id // "legacy"),(.plan_key // "legacy"),(.status // "legacy"),"exact=0","degraded=0","hashes_match=unknown"] | @tsv' "$f"
  done
}

ralph_state_show() {
  local root="$1" run_id="$2" f plan_key plan_path hashes dir rec capture rec_hash session_id todo_id reason eligible
  f="$(find "$root/logs" -path "*/runs/$run_id/run-manifest.json" -type f 2>/dev/null | head -n 1)"
  [[ -n "$f" && -f "$f" ]] || return 0
  cat "$f"
  printf '\n'
  plan_key="$(jq -r '.plan_key // empty' "$f")"
  plan_path="$(jq -r '.plan_path // empty' "$f")"
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

ralph_state_status() { local root="$1" d; [[ -d "$root" ]] || { echo 'state directory is empty'; return 0; }; for d in "$root"/*; do [[ -e "$d" ]] || continue; printf '%s\t%s files\t%s\n' "$(basename "$d")" "$(find "$d" -type f 2>/dev/null | wc -l | tr -d ' ')" "$(du -sh "$d" 2>/dev/null | awk '{print $1}')"; done; }

cmd="${1:-status}"; shift || true; root="$(ralph_state_root)"
case "$cmd" in
 status) ralph_state_status "$root";;
 runs) [[ "${1:-}" == "--plan" ]] && { ralph_state_runs "$root" "${2:-}"; } || ralph_state_runs "$root";;
 show) [[ -n "${1:-}" ]] || { ralph_state_usage >&2; exit 2; }; ralph_state_show "$root" "$1";;
 prune) echo "state prune dry-run: no state removed";;
 reindex) echo "state reindex: legacy manifests are synthesized on demand";;
 orphans) echo "orphan logs are reported only; none are auto-deleted";;
 -h|--help|help) ralph_state_usage;;
 *) echo "Error: unknown state command: $cmd" >&2; exit 2;;
esac
