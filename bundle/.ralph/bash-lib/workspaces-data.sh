#!/usr/bin/env bash
# Commands that inspect and reclaim a project's .ralph-workspace directory:
#   ralph workspaces status | clean | doctor
# Sourced by workspaces-cli.sh. Needs only bash, find, du, and jq.

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  echo "This file is meant to be sourced, not executed." >&2
  exit 1
fi

_WORKSPACES_DATA_DIR="${BASH_SOURCE[0]%/*}"
[[ "$_WORKSPACES_DATA_DIR" == "${BASH_SOURCE[0]}" ]] && _WORKSPACES_DATA_DIR="."
# shellcheck source=cleanup-plan.sh
source "$_WORKSPACES_DATA_DIR/cleanup-plan.sh"
# shellcheck source=runtime-overlay/runtime-overlay.sh
source "$_WORKSPACES_DATA_DIR/runtime-overlay/runtime-overlay.sh"

# Directories whose files are safe to age out: diagnostics and caches only.
# Plans, artifacts, handoffs, and graph state are never touched by age alone.
# Layout 2 keeps disposable caches under cache/; keep legacy top-level names too.
_WS_AGEABLE_DIRS=(
  logs tool-results search-context sessions repo-map metrics
  cache/tool-results cache/search-context cache/repo-map cache/metrics
  internal/sessions
)

ws_data_human_kb() {
  awk -v kb="${1:-0}" 'BEGIN {
    if (kb >= 1048576) printf "%.1f GB", kb / 1048576
    else if (kb >= 1024) printf "%.1f MB", kb / 1024
    else printf "%d KB", kb
  }'
}

ws_data_dir_kb() {
  du -sk "$1" 2>/dev/null | awk '{print $1 + 0}'
}

# ws_data_resolve <path-or-empty> -> prints the project root holding .ralph-workspace
ws_data_resolve() {
  local root="${1:-$PWD}"
  root="$(cd "$root" 2>/dev/null && pwd)" || {
    echo "Error: not a directory: ${1:-$PWD}" >&2
    return 1
  }
  if [[ ! -d "$root/.ralph-workspace" ]]; then
    echo "Error: no .ralph-workspace directory in $root" >&2
    echo "Run from a Ralph project, or pass the project path." >&2
    return 1
  fi
  printf '%s\n' "$root"
}

# ws_data_pid_alive <pid>
ws_data_pid_alive() {
  [[ "${1:-}" =~ ^[1-9][0-9]*$ ]] || return 1
  kill -0 "$1" 2>/dev/null
}

# ws_data_live_runs <root> -> prints one line per live plan process or graph run
ws_data_live_runs() {
  local root="$1" f pid status state_root processes_roots
  state_root="$root/.ralph-workspace"
  processes_roots=("$state_root/processes/active" "$state_root/internal/processes/active")
  for processes_root in "${processes_roots[@]}"; do
    for f in "$processes_root"/*/run.json; do
      [[ -f "$f" ]] || continue
      status="$(jq -r '.status // empty' "$f" 2>/dev/null)" || continue
      [[ "$status" == "running" ]] || continue
      pid="$(jq -r '.owner_pid // empty' "$f" 2>/dev/null)"
      ws_data_pid_alive "$pid" && printf 'plan process %s (pid %s)\n' "$(basename "$(dirname "$f")")" "$pid"
    done
  done
  for f in "$root"/.ralph-workspace/graph-runs/*/*/run.json \
           "$root"/.ralph-workspace/runs/*/engine/graph/run.json; do
    [[ -f "$f" ]] || continue
    status="$(jq -r '.status // empty' "$f" 2>/dev/null)" || continue
    case "$status" in
      succeeded|failed|cancelled) continue ;;
    esac
    pid="$(jq -r '.supervisorPid // empty' "$f" 2>/dev/null)"
    if ws_data_pid_alive "$pid" || [[ "$status" == "awaiting-ack" ]]; then
      if [[ "$f" == */runs/*/engine/graph/run.json ]]; then
        printf 'graph run %s (%s)\n' "$(basename "$(dirname "$(dirname "$(dirname "$f")")")")" "$status"
      else
        printf 'graph run %s/%s (%s)\n' "$(basename "$(dirname "$(dirname "$f")")")" "$(basename "$(dirname "$f")")" "$status"
      fi
    fi
  done
}

# ws_data_stale_graph_runs <root> -> prints run.json paths that claim to run but have a dead owner
ws_data_stale_graph_runs() {
  local root="$1" f status pid
  for f in "$root"/.ralph-workspace/graph-runs/*/*/run.json \
           "$root"/.ralph-workspace/runs/*/engine/graph/run.json; do
    [[ -f "$f" ]] || continue
    status="$(jq -r '.status // empty' "$f" 2>/dev/null)" || continue
    case "$status" in
      running|starting|queued)
        pid="$(jq -r '.supervisorPid // empty' "$f" 2>/dev/null)"
        [[ "$pid" =~ ^[1-9][0-9]*$ ]] && ! ws_data_pid_alive "$pid" && printf '%s\n' "$f"
        ;;
    esac
  done
}

# ws_data_stale_process_records <root> -> prints run.json paths marked running with a dead owner
ws_data_stale_process_records() {
  local root="$1" f status pid
  for f in "$root"/.ralph-workspace/processes/active/*/run.json \
           "$root"/.ralph-workspace/internal/processes/active/*/run.json; do
    [[ -f "$f" ]] || continue
    status="$(jq -r '.status // empty' "$f" 2>/dev/null)" || continue
    [[ "$status" == "running" ]] || continue
    pid="$(jq -r '.owner_pid // empty' "$f" 2>/dev/null)"
    ws_data_pid_alive "$pid" || printf '%s\n' "$f"
  done
}

ws_data_status_usage() {
  cat <<'USAGE'
Usage: ralph workspaces status [path]

Show how much disk .ralph-workspace uses in a project, split by subdirectory,
and how many graph runs are finished, running, or stuck. Read-only.
[path] defaults to the current directory.
USAGE
}

ws_data_status() {
  case "${1:-}" in -h|--help) ws_data_status_usage; return 0 ;; esac
  [[ $# -le 1 ]] || { echo "Error: status takes at most one path." >&2; return 2; }
  local root ws entry kb total
  root="$(ws_data_resolve "${1:-}")" || return 1
  ws="$root/.ralph-workspace"
  printf 'Workspace: %s\n\n' "$ws"
  total="$(ws_data_dir_kb "$ws")"
  for entry in "$ws"/*/ "$ws"/.[!.]*/; do
    [[ -d "$entry" ]] || continue
    printf '%s\t%s\n' "$(ws_data_dir_kb "$entry")" "$(basename "$entry")"
  done | sort -rn | while IFS=$'\t' read -r kb name; do
    printf '  %-12s %s/\n' "$(ws_data_human_kb "$kb")" "$name"
  done
  printf '  %-12s total\n\n' "$(ws_data_human_kb "$total")"

  local terminal=0 active=0 f status
  for f in "$ws"/graph-runs/*/*/run.json "$ws"/runs/*/engine/graph/run.json; do
    [[ -f "$f" ]] || continue
    status="$(jq -r '.status // empty' "$f" 2>/dev/null)"
    case "$status" in
      succeeded|failed|cancelled) terminal=$((terminal + 1)) ;;
      *) active=$((active + 1)) ;;
    esac
  done
  local stale
  stale="$(ws_data_stale_graph_runs "$root" | wc -l | tr -d ' ')"
  printf 'Graph runs: %s finished, %s not finished (%s stuck with a dead owner)\n' "$terminal" "$active" "$stale"
  printf '\nNext: ralph workspaces doctor   (find problems)\n'
  printf '      ralph workspaces clean    (preview what can be reclaimed)\n'
}

ws_data_doctor_usage() {
  cat <<'USAGE'
Usage: ralph workspaces doctor [path] [--fix]

Check a project's .ralph-workspace for problems:
  - graph runs stuck as "running" whose owner process died
  - process records stuck as "running" whose owner process died
  - stale runtime config overlays left by interrupted runs
  - the project missing from the global workspace registry

Without --fix this is read-only. --fix repairs the stuck runs and overlays
(it marks dead graph runs failed with reason owner-lost); it never deletes data.
Use `ralph workspaces clean` to reclaim disk space.
Exit status is 1 when problems were found and not fixed.
USAGE
}

ws_data_doctor() {
  local fix=0 path_arg=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -h|--help) ws_data_doctor_usage; return 0 ;;
      --fix) fix=1 ;;
      -*) echo "Error: unknown option for doctor: $1" >&2; return 2 ;;
      *)
        [[ -z "$path_arg" ]] || { echo "Error: doctor takes at most one path." >&2; return 2; }
        path_arg="$1"
        ;;
    esac
    shift
  done

  local root f problems=0 fixed=0
  root="$(ws_data_resolve "$path_arg")" || return 1
  printf 'Checking %s/.ralph-workspace\n\n' "$root"

  local stale_runs
  stale_runs="$(ws_data_stale_graph_runs "$root")"
  if [[ -n "$stale_runs" ]]; then
    while IFS= read -r f; do
      if [[ "$fix" -eq 1 ]] && graph_state_reconcile_run_owner_file "$f"; then
        printf '  FIXED    graph run marked failed (owner-lost): %s\n' "${f#"$root"/}"
        fixed=$((fixed + 1))
      else
        printf '  PROBLEM  graph run stuck as running, owner is dead: %s\n' "${f#"$root"/}"
        problems=$((problems + 1))
      fi
    done <<<"$stale_runs"
  fi

  local stale_procs
  stale_procs="$(ws_data_stale_process_records "$root")"
  if [[ -n "$stale_procs" ]]; then
    while IFS= read -r f; do
      if [[ "$fix" -eq 1 ]] && jq '.status = "stopped" | .termination_reason = "owner-lost"' "$f" >"$f.tmp.$$" 2>/dev/null && mv "$f.tmp.$$" "$f"; then
        printf '  FIXED    process record marked stopped: %s\n' "${f#"$root"/}"
        fixed=$((fixed + 1))
      else
        rm -f "$f.tmp.$$"
        printf '  PROBLEM  process record stuck as running, owner is dead: %s\n' "${f#"$root"/}"
        problems=$((problems + 1))
      fi
    done <<<"$stale_procs"
  fi

  if { [[ -d "$root/.ralph-workspace/runtime-config" ]] || [[ -d "$root/.ralph-workspace/internal/runtime-config" ]]; } \
    && declare -F runtime_overlay_restore_stale_runs >/dev/null 2>&1; then
    local overlay_out
    if [[ "$fix" -eq 1 ]]; then
      overlay_out="$(runtime_overlay_restore_stale_runs "$root" "" 2>&1)" || overlay_out=""
      if [[ -n "$overlay_out" ]]; then
        printf '  FIXED    runtime overlays restored:\n%s\n' "$(printf '%s\n' "$overlay_out" | sed 's/^/             /')"
        fixed=$((fixed + 1))
      fi
    fi
  fi

  local live
  live="$(ws_data_live_runs "$root")"
  if [[ -n "$live" ]]; then
    printf '  INFO     active work right now (clean --all will refuse):\n%s\n' "$(printf '%s\n' "$live" | sed 's/^/             /')"
  fi

  local registry_file="${RALPH_WORKSPACES_FILE:-}"
  if [[ -z "$registry_file" ]]; then
    registry_file="${XDG_CONFIG_HOME:-${HOME:-}/.config}/ralph/workspaces.json"
  fi
  if [[ -f "$registry_file" ]] && ! grep -qF "\"$root\"" "$registry_file" 2>/dev/null; then
    printf '  INFO     this project is not in the workspace registry (%s); run a plan or `ralph workspaces add %s`\n' "$registry_file" "$root"
  fi

  local total_kb
  total_kb="$(ws_data_dir_kb "$root/.ralph-workspace")"
  printf '  INFO     .ralph-workspace uses %s (see `ralph workspaces status`)\n' "$(ws_data_human_kb "$total_kb")"

  printf '\n'
  if [[ "$problems" -eq 0 ]]; then
    if [[ "$fixed" -gt 0 ]]; then
      printf 'Fixed %s problem(s).\n' "$fixed"
    else
      printf 'No problems found.\n'
    fi
    return 0
  fi
  printf '%s problem(s) found. Re-run with --fix to repair them.\n' "$problems"
  return 1
}

ws_data_clean_usage() {
  cat <<'USAGE'
Usage: ralph workspaces clean [path] [options]

Reclaim disk space in a project's .ralph-workspace. Preview only by default;
nothing is deleted until you pass --yes.

What it removes:
  - finished graph runs beyond the retention limits (never the "latest" run,
    never a run that is still running or waiting on you)
  - old graph base snapshots (these back the dashboard diff viewer)
  - old files under logs/, tool-results/, search-context/, repo-map/, metrics/,
    their cache/ counterparts, sessions/, and internal/sessions/
It never removes plans, artifacts, handoffs, or active runs.

Options:
  --older-than DAYS   Age cutoff for runs and files (default 30)
  --keep N            Keep at most N finished graph runs per namespace (default 10)
  --all               Delete the entire .ralph-workspace instead (refuses while
                      any run is active). Loses all history, logs, and plans
                      stored there.
  --yes               Actually delete. Without it, only report.

Examples:
  ralph workspaces clean                    preview the default cleanup
  ralph workspaces clean --yes              do it
  ralph workspaces clean --older-than 7 --yes
  ralph workspaces clean --all --yes        wipe the workspace
USAGE
}

ws_data_clean() {
  local yes=0 all=0 days=30 keep=10 path_arg=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -h|--help) ws_data_clean_usage; return 0 ;;
      --yes|-y) yes=1 ;;
      --all) all=1 ;;
      --older-than)
        [[ "${2:-}" =~ ^[0-9]+$ ]] || { echo "Error: --older-than needs a non-negative integer (days)." >&2; return 2; }
        days="$2"; shift
        ;;
      --keep)
        [[ "${2:-}" =~ ^[0-9]+$ ]] || { echo "Error: --keep needs a non-negative integer." >&2; return 2; }
        keep="$2"; shift
        ;;
      -*) echo "Error: unknown option for clean: $1" >&2; return 2 ;;
      *)
        [[ -z "$path_arg" ]] || { echo "Error: clean takes at most one path." >&2; return 2; }
        path_arg="$1"
        ;;
    esac
    shift
  done

  local root ws before_kb
  root="$(ws_data_resolve "$path_arg")" || return 1
  ws="$root/.ralph-workspace"
  before_kb="$(ws_data_dir_kb "$ws")"

  if [[ "$all" -eq 1 ]]; then
    local live
    live="$(ws_data_live_runs "$root")"
    if [[ -n "$live" ]]; then
      echo "Refusing to delete $ws: work is still active:" >&2
      printf '%s\n' "$live" | sed 's/^/  /' >&2
      echo "Stop it first (or run \`ralph workspaces doctor\`)." >&2
      return 1
    fi
    if [[ "$yes" -ne 1 ]]; then
      printf 'Would delete all of %s (%s). Re-run with --yes to confirm.\n' "$ws" "$(ws_data_human_kb "$before_kb")"
      return 0
    fi
    rm -rf "$ws"
    printf 'Deleted %s (freed about %s).\n' "$ws" "$(ws_data_human_kb "$before_kb")"
    return 0
  fi

  local mode="Would remove"
  if [[ "$yes" -eq 1 ]]; then
    mode="Removed"
    export RALPH_CLEANUP_DRY_RUN=0
  else
    export RALPH_CLEANUP_DRY_RUN=1
    printf 'Preview only. Nothing is deleted without --yes.\n\n'
  fi
  export RALPH_GRAPH_RUN_MAX_AGE_DAYS="$days" RALPH_GRAPH_RUN_MAX_COUNT="$keep"

  local ns_dir ns count
  for ns_dir in "$ws"/graph-runs/*/; do
    [[ -d "$ns_dir" ]] || continue
    ns="$(basename "$ns_dir")"
    cleanup_plan_prune_graph_runs "$root" "$ns"
  done

  local dir f file_count=0 file_kb=0 kb
  for dir in "${_WS_AGEABLE_DIRS[@]}"; do
    [[ -d "$ws/$dir" ]] || continue
    count=0
    kb=0
    while IFS= read -r f; do
      count=$((count + 1))
      kb=$((kb + $(du -sk "$f" 2>/dev/null | awk '{print $1 + 0}')))
      [[ "$yes" -eq 1 ]] && rm -f "$f"
    done < <(find "$ws/$dir" -type f -mtime +"$days" 2>/dev/null)
    if [[ "$count" -gt 0 ]]; then
      printf '%s %s file(s) older than %s day(s) from %s/ (%s)\n' "$mode" "$count" "$days" "$dir" "$(ws_data_human_kb "$kb")"
      file_count=$((file_count + count))
      file_kb=$((file_kb + kb))
      [[ "$yes" -eq 1 ]] && find "$ws/$dir" -mindepth 1 -type d -empty -delete 2>/dev/null
    fi
  done

  printf '\n'
  if [[ "$yes" -eq 1 ]]; then
    local after_kb
    after_kb="$(ws_data_dir_kb "$ws")"
    printf 'Done. %s -> %s.\n' "$(ws_data_human_kb "$before_kb")" "$(ws_data_human_kb "$after_kb")"
  else
    printf 'Workspace is %s now. Re-run with --yes to apply.\n' "$(ws_data_human_kb "$before_kb")"
    local stale
    stale="$(ws_data_stale_graph_runs "$root" | wc -l | tr -d ' ')"
    if [[ "$stale" -gt 0 ]]; then
      printf 'Note: %s graph run(s) are stuck as "running" with a dead owner and are skipped;\n' "$stale"
      printf 'run `ralph workspaces doctor --fix` first so they become eligible.\n'
    fi
  fi
}
