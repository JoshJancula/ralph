#!/usr/bin/env bash
# Bounded, visible graph Bats runner (G21).
#
# Prints shard/file start, periodic elapsed progress, file completion, and the
# currently running file on timeout. A file exceeding its wall-clock budget is
# a failure: the runner names it, kills its process tree, and exits non-zero.
#
# Usage:
#   bash scripts/run-graph-bats.sh [options] [--] [bats arguments...]
#
# Examples:
#   bash scripts/run-graph-bats.sh
#   bash scripts/run-graph-bats.sh --shard core -j 4
#   bash scripts/run-graph-bats.sh --list-shards
#   bash scripts/run-graph-bats.sh --file-timeout 600 --progress-interval 10

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=bundle/.ralph/bash-lib/ralph-process-teardown.sh
source "$REPO_ROOT/bundle/.ralph/bash-lib/ralph-process-teardown.sh"

SHARDS_JSON="$REPO_ROOT/tests/bats/graph/shards.json"
BATS_BIN="$REPO_ROOT/bin/bats"

SETUP_FIXTURES=1
JOBS=""
JOBS_EXPLICIT=0
FILE_TIMEOUT=600
PROGRESS_INTERVAL=5
LIST_SHARDS=0
LIST_FILES=0
SELECTED_SHARDS=()
BATS_PASSTHRU=()

# Monitor pids of in-flight file runners (space-separated). EXIT trap reaps them.
GRAPH_BATS_MONITOR_PIDS=""
GRAPH_BATS_WORK_DIR=""

graph_bats_log() {
  printf 'graph-bats: %s\n' "$*" >&2
}

detect_cpu_count() {
  local n=1
  if command -v nproc &>/dev/null; then
    n="$(nproc)"
  elif [[ "$(uname -s 2>/dev/null || true)" == "Darwin" ]] && command -v sysctl &>/dev/null; then
    n="$(sysctl -n hw.ncpu 2>/dev/null || echo 1)"
  elif command -v getconf &>/dev/null; then
    n="$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 1)"
  fi
  if [[ ! "$n" =~ ^[1-9][0-9]*$ ]]; then
    n=1
  fi
  echo "$n"
}

default_parallel_jobs() {
  local cpus="$1"
  # Graph files are process-heavy integration suites. Eight files in flight
  # caused scheduler timing tests to stretch by 5-10x and produced false
  # timeouts on otherwise healthy files. Keep the default conservative;
  # callers may still opt into a higher value explicitly.
  if [[ "$cpus" -gt 4 ]]; then
    echo 4
  else
    echo "$cpus"
  fi
}

usage() {
  cat <<'EOF'
Usage: bash scripts/run-graph-bats.sh [options] [--] [bats arguments...]

Options:
  --shard NAME              Run one named shard (repeatable). Names: core,
                            operator, runtime-approval, isolation, acceptance.
  --list-shards             Print the five G21 shard names and exit
  --list-files              Print files for the selected shards and exit
  -j N, --jobs N            File-level parallelism within each shard
  --file-timeout SECS       Hard wall-clock limit for one Bats file
                            (default: 600). 0 disables. Bats may buffer a
                            healthy long test until it completes, so silence
                            alone is not treated as proof of a hang.
  --progress-interval SECS  Periodic elapsed progress (default: 5)
  --shards-json PATH        Override tests/bats/graph/shards.json
  --no-setup-fixtures       Skip scripts/setup-test-fixtures.sh
  -h, --help                Show this help

Healthy shards keep file-level -j parallelism. A hung file is named, its
process tree is killed, and the run fails. Do not hide hangs by increasing
timeouts without evidence of bounded progress.
EOF
}

graph_bats_shards_query() {
  local shards_json="$1"
  local query="$2"
  shift 2
  if command -v python3 >/dev/null 2>&1; then
    python3 - "$shards_json" "$query" "$@" <<'PY'
import json, sys
path, query = sys.argv[1], sys.argv[2]
args = sys.argv[3:]
with open(path) as handle:
    data = json.load(handle)
shards = data.get("shards") or []
if query == "names":
    for shard in shards:
        print(shard["name"])
elif query == "desc":
    name = args[0]
    for shard in shards:
        if shard.get("name") == name:
            print(shard.get("description", ""))
            break
elif query == "files":
    name = args[0]
    for shard in shards:
        if shard.get("name") == name:
            for item in shard.get("files") or []:
                print(item)
            break
elif query == "exclude":
    for item in data.get("exclude") or []:
        print(item)
elif query == "all-files":
    for shard in shards:
        for item in shard.get("files") or []:
            print(item)
else:
    sys.exit(2)
PY
    return
  fi
  if command -v jq >/dev/null 2>&1; then
    case "$query" in
      names) jq -r '.shards[].name' "$shards_json" ;;
      desc) jq -r --arg n "$1" '.shards[] | select(.name==$n) | .description' "$shards_json" ;;
      files) jq -r --arg n "$1" '.shards[] | select(.name==$n) | .files[]?' "$shards_json" ;;
      exclude) jq -r '.exclude[]?' "$shards_json" ;;
      all-files) jq -r '.shards[].files[]?' "$shards_json" ;;
      *) return 2 ;;
    esac
    return
  fi
  echo "run-graph-bats: python3 or jq is required to read shards.json" >&2
  return 1
}

graph_bats_discover_count() {
  local file="$1"
  local count
  count="$(grep -E -c '^[[:space:]]*@test[[:space:]]' "$file" 2>/dev/null || true)"
  if [[ ! "$count" =~ ^[0-9]+$ ]]; then
    count=0
  fi
  echo "$count"
}

graph_bats_tap_completed() {
  local file="$1"
  local count
  [[ -f "$file" ]] || { echo 0; return 0; }
  count="$(grep -E -c '^(ok|not ok) ' "$file" 2>/dev/null || true)"
  if [[ ! "$count" =~ ^[0-9]+$ ]]; then
    count=0
  fi
  echo "$count"
}

graph_bats_resolve_file() {
  local raw="$1"
  if [[ -f "$raw" ]]; then
    echo "$raw"
    return 0
  fi
  if [[ -f "$REPO_ROOT/$raw" ]]; then
    echo "$REPO_ROOT/$raw"
    return 0
  fi
  return 1
}

# Spawn bats in its own session, writing line-buffered TAP to $1.
# Writes the wrapper pid to $2. Must run in the current shell (not $())
# so the caller can wait(1) the child.
graph_bats_spawn_isolated() {
  local out="$1"
  local pid_file="$2"
  shift 2
  if command -v python3 >/dev/null 2>&1; then
    GRAPH_BATS_OUT="$out" python3 -c '
import os, sys, pty, subprocess

os.setsid()
out_path = os.environ["GRAPH_BATS_OUT"]
cmd = sys.argv[1:]
master, slave = pty.openpty()
proc = subprocess.Popen(
    cmd,
    stdin=subprocess.DEVNULL,
    stdout=slave,
    stderr=slave,
    close_fds=True,
)
os.close(slave)
rc = 1
try:
    with open(out_path, "w", buffering=1) as out:
        while True:
            try:
                data = os.read(master, 4096)
            except OSError:
                break
            if not data:
                break
            out.write(data.decode("utf-8", "replace"))
            out.flush()
    rc = proc.wait()
except Exception:
    try:
        rc = proc.wait()
    except Exception:
        rc = 1
try:
    os.close(master)
except OSError:
    pass
sys.exit(rc if isinstance(rc, int) else 1)
' "$@" &
  elif command -v setsid >/dev/null 2>&1; then
    setsid "$@" >"$out" 2>&1 &
  else
    "$@" >"$out" 2>&1 &
  fi
  printf '%s\n' "$!" >"$pid_file"
}

graph_bats_emit_new_output() {
  local file="$1"
  local offset_file="$2"
  local size offset
  [[ -f "$file" ]] || return 0
  size="$(wc -c <"$file" | tr -d '[:space:]')"
  [[ "$size" =~ ^[0-9]+$ ]] || return 0
  offset=0
  if [[ -f "$offset_file" ]]; then
    offset="$(tr -d '[:space:]' <"$offset_file")"
    [[ "$offset" =~ ^[0-9]+$ ]] || offset=0
  fi
  if [[ "$size" -gt "$offset" ]]; then
    tail -c +"$((offset + 1))" "$file"
    printf '%s\n' "$size" >"$offset_file"
  fi
}

graph_bats_kill_file_tree() {
  local pid="$1"
  [[ "$pid" =~ ^[0-9]+$ ]] || return 0
  ralph_kill_process_group "$pid" 1
  ralph_kill_tree "$pid"
  wait "$pid" 2>/dev/null || true
}

graph_bats_cleanup_monitors() {
  local pid
  for pid in $GRAPH_BATS_MONITOR_PIDS; do
    [[ "$pid" =~ ^[0-9]+$ ]] || continue
    if kill -0 "$pid" 2>/dev/null; then
      ralph_kill_tree "$pid"
      wait "$pid" 2>/dev/null || true
    fi
  done
  if [[ -n "$GRAPH_BATS_WORK_DIR" && -d "$GRAPH_BATS_WORK_DIR" ]]; then
    local child
    for child in "$GRAPH_BATS_WORK_DIR"/*.pid; do
      [[ -f "$child" ]] || continue
      pid="$(tr -d '[:space:]' <"$child")"
      graph_bats_kill_file_tree "$pid"
    done
  fi
}

graph_bats_run_file() {
  local shard="$1"
  local file="$2"
  local display="$3"
  local work="$4"
  local discovered elapsed start_ts pid rc completed
  local last_completed last_size last_progress_ts stalled size
  local out offset_file pid_file
  local safe

  safe="$(printf '%s' "$display" | tr '/ ' '__')"
  out="$work/${safe}.out"
  offset_file="$work/${safe}.offset"
  pid_file="$work/${safe}.pid"
  : >"$out"
  printf '0\n' >"$offset_file"

  discovered="$(graph_bats_discover_count "$file")"
  start_ts="$(date +%s)"
  graph_bats_log "FILE START shard=${shard} file=${display} discovered=${discovered} t=${start_ts} jobs=${JOBS}"

  graph_bats_spawn_isolated "$out" "$pid_file" \
    "$BATS_BIN" --formatter tap "$file" "${BATS_PASSTHRU[@]+"${BATS_PASSTHRU[@]}"}"
  pid="$(tr -d '[:space:]' <"$pid_file")"
  if [[ ! "$pid" =~ ^[0-9]+$ ]]; then
    graph_bats_log "FILE HUNG shard=${shard} file=${display} elapsed=0s completed=0/${discovered}"
    graph_bats_log "FILE CLEANUP shard=${shard} file=${display} killed-tree=1"
    return 124
  fi

  rc=0
  last_completed=0
  last_size=0
  last_progress_ts="$start_ts"
  while kill -0 "$pid" 2>/dev/null; do
    elapsed=$(($(date +%s) - start_ts))
    graph_bats_emit_new_output "$out" "$offset_file"
    completed="$(graph_bats_tap_completed "$out")"
    size=0
    if [[ -f "$out" ]]; then
      size="$(wc -c <"$out" | tr -d '[:space:]')"
      [[ "$size" =~ ^[0-9]+$ ]] || size=0
    fi
    if [[ "$completed" -gt "$last_completed" || "$size" -gt "$last_size" ]]; then
      last_completed="$completed"
      last_size="$size"
      last_progress_ts="$(date +%s)"
    fi
    stalled=$(($(date +%s) - last_progress_ts))
    # TAP output is buffered until a Bats test completes. Treating silence as
    # a hang killed healthy long-running vertical tests. Bound the whole file
    # by wall clock instead; periodic progress still reports TAP silence.
    if [[ "$FILE_TIMEOUT" -gt 0 && "$elapsed" -ge "$FILE_TIMEOUT" ]]; then
      graph_bats_log "FILE TIMEOUT shard=${shard} file=${display} elapsed=${elapsed}s stalled=${stalled}s completed=${completed}/${discovered}"
      graph_bats_kill_file_tree "$pid"
      rm -f "$pid_file"
      graph_bats_log "FILE CLEANUP shard=${shard} file=${display} killed-tree=1"
      return 124
    fi
    graph_bats_log "FILE PROGRESS shard=${shard} file=${display} elapsed=${elapsed}s stalled=${stalled}s completed=${completed}/${discovered} still-running"
    sleep "$PROGRESS_INTERVAL"
  done

  rc=0
  wait "$pid" 2>/dev/null || rc=$?
  rm -f "$pid_file"
  graph_bats_emit_new_output "$out" "$offset_file"
  elapsed=$(($(date +%s) - start_ts))
  completed="$(graph_bats_tap_completed "$out")"
  graph_bats_log "FILE DONE shard=${shard} file=${display} status=${rc} elapsed=${elapsed}s completed=${completed}/${discovered}"
  return "$rc"
}

graph_bats_live_count() {
  local pid live=0
  for pid in $1; do
    [[ "$pid" =~ ^[0-9]+$ ]] || continue
    if kill -0 "$pid" 2>/dev/null; then
      live=$((live + 1))
    fi
  done
  echo "$live"
}

graph_bats_reap_monitors() {
  local work="$1"
  local pid rc
  shift
  for pid in "$@"; do
    [[ "$pid" =~ ^[0-9]+$ ]] || continue
    [[ -f "$work/${pid}.reaped" ]] && continue
    if kill -0 "$pid" 2>/dev/null; then
      continue
    fi
    rc=0
    wait "$pid" 2>/dev/null || rc=$?
    printf '%s\n' "$rc" >"$work/${pid}.reaped"
    if [[ "$rc" -ne 0 ]]; then
      ANY_FAIL=1
      if [[ "$rc" -eq 124 ]]; then
        ANY_HUNG=1
      fi
    fi
  done
}

graph_bats_run_shard() {
  local shard="$1"
  shift
  local -a files=("$@")
  local file display resolved
  local -a existing=()
  local -a displays=()
  local work pid
  local -a monitor_pids=()

  for file in "${files[@]}"; do
    if resolved="$(graph_bats_resolve_file "$file")"; then
      existing+=("$resolved")
      if [[ "$file" == /* ]]; then
        displays+=("$file")
      else
        displays+=("$file")
      fi
    else
      graph_bats_log "SKIP missing ${file}"
    fi
  done

  graph_bats_log "SHARD START ${shard} files=${#existing[@]} jobs=${JOBS}"
  if [[ ${#existing[@]} -eq 0 ]]; then
    graph_bats_log "SHARD DONE ${shard} status=0 files=0"
    return 0
  fi

  work="$(mktemp -d "${GRAPH_BATS_WORK_DIR}/${shard}.XXXXXX")"
  if [[ "$JOBS" -le 1 ]]; then
    local i rc
    i=0
    while [[ "$i" -lt ${#existing[@]} ]]; do
      rc=0
      graph_bats_run_file "$shard" "${existing[$i]}" "${displays[$i]}" "$work" || rc=$?
      if [[ "$rc" -ne 0 ]]; then
        ANY_FAIL=1
        if [[ "$rc" -eq 124 ]]; then
          ANY_HUNG=1
        fi
      fi
      i=$((i + 1))
    done
    graph_bats_log "SHARD DONE ${shard} status=$([[ "${ANY_FAIL:-0}" -eq 0 ]] && echo 0 || echo 1) files=${#existing[@]}"
    return 0
  fi

  local i=0
  while [[ "$i" -lt ${#existing[@]} ]]; do
    while [[ "$(graph_bats_live_count "${monitor_pids[*]+"${monitor_pids[*]}"}")" -ge "$JOBS" ]]; do
      graph_bats_reap_monitors "$work" ${monitor_pids[@]+"${monitor_pids[@]}"}
      sleep 0.1
    done
    graph_bats_run_file "$shard" "${existing[$i]}" "${displays[$i]}" "$work" &
    pid=$!
    monitor_pids+=("$pid")
    GRAPH_BATS_MONITOR_PIDS="${GRAPH_BATS_MONITOR_PIDS} ${pid}"
    i=$((i + 1))
  done

  for pid in ${monitor_pids[@]+"${monitor_pids[@]}"}; do
    while kill -0 "$pid" 2>/dev/null; do
      sleep 0.1
    done
  done
  graph_bats_reap_monitors "$work" ${monitor_pids[@]+"${monitor_pids[@]}"}
  graph_bats_log "SHARD DONE ${shard} status=$([[ "${ANY_FAIL:-0}" -eq 0 ]] && echo 0 || echo 1) files=${#existing[@]}"
}

# A graph test file that is in neither a shard nor the exclude list is never
# executed by this runner. That used to be a warning, which meant four files --
# including the tooling-profile feature tests -- sat unrun and unnoticed. Treat
# it as a manifest error so new test files cannot silently escape the suite.
graph_bats_check_unassigned() {
  local assigned excluded rel f
  local -a unassigned=()
  assigned="$(graph_bats_shards_query "$SHARDS_JSON" all-files)"
  excluded="$(graph_bats_shards_query "$SHARDS_JSON" exclude)"
  while IFS= read -r f; do
    [[ -n "$f" ]] || continue
    rel="${f#"$REPO_ROOT"/}"
    if printf '%s\n' "$excluded" | grep -Fxq "$rel"; then
      continue
    fi
    if printf '%s\n' "$assigned" | grep -Fxq "$rel"; then
      continue
    fi
    unassigned+=("$rel")
  done < <(find "$REPO_ROOT/tests/bats/graph" -name '*.bats' -type f | LC_ALL=C sort)

  [[ ${#unassigned[@]} -eq 0 ]] && return 0

  for rel in "${unassigned[@]}"; do
    graph_bats_log "ERROR: unassigned file ${rel}"
  done
  graph_bats_log "ERROR: ${#unassigned[@]} graph test file(s) are in no shard and not excluded."
  graph_bats_log "       Add each to a shard in ${SHARDS_JSON#"$REPO_ROOT"/}, or to its \"exclude\" list."
  return 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h | --help)
      usage
      exit 0
      ;;
    --shard)
      if [[ $# -lt 2 ]]; then
        echo "run-graph-bats: --shard requires a name" >&2
        exit 1
      fi
      SELECTED_SHARDS+=("$2")
      shift 2
      ;;
    --list-shards)
      LIST_SHARDS=1
      shift
      ;;
    --list-files)
      LIST_FILES=1
      shift
      ;;
    -j | --jobs)
      if [[ $# -lt 2 ]]; then
        echo "run-graph-bats: -j/--jobs requires an argument" >&2
        exit 1
      fi
      JOBS="$2"
      JOBS_EXPLICIT=1
      shift 2
      ;;
    --file-timeout)
      if [[ $# -lt 2 ]]; then
        echo "run-graph-bats: --file-timeout requires seconds" >&2
        exit 1
      fi
      FILE_TIMEOUT="$2"
      shift 2
      ;;
    --progress-interval)
      if [[ $# -lt 2 ]]; then
        echo "run-graph-bats: --progress-interval requires seconds" >&2
        exit 1
      fi
      PROGRESS_INTERVAL="$2"
      shift 2
      ;;
    --shards-json)
      if [[ $# -lt 2 ]]; then
        echo "run-graph-bats: --shards-json requires a path" >&2
        exit 1
      fi
      SHARDS_JSON="$2"
      shift 2
      ;;
    --no-setup-fixtures)
      SETUP_FIXTURES=0
      shift
      ;;
    --)
      shift
      BATS_PASSTHRU+=("$@")
      break
      ;;
    -*)
      echo "run-graph-bats: unknown option: $1" >&2
      usage >&2
      exit 1
      ;;
    *)
      echo "run-graph-bats: unexpected argument: $1 (use --shard or --)" >&2
      usage >&2
      exit 1
      ;;
  esac
done

if [[ ! -f "$SHARDS_JSON" ]]; then
  echo "run-graph-bats: shards file not found: $SHARDS_JSON" >&2
  exit 1
fi

if [[ ! "$FILE_TIMEOUT" =~ ^[0-9]+$ ]]; then
  echo "run-graph-bats: --file-timeout must be a non-negative integer" >&2
  exit 1
fi
if [[ ! "$PROGRESS_INTERVAL" =~ ^[1-9][0-9]*$ ]]; then
  echo "run-graph-bats: --progress-interval must be a positive integer" >&2
  exit 1
fi

ALL_SHARD_NAMES="$(graph_bats_shards_query "$SHARDS_JSON" names)"
if [[ -z "$ALL_SHARD_NAMES" ]]; then
  echo "run-graph-bats: no shards found in $SHARDS_JSON" >&2
  exit 1
fi

if [[ ${#SELECTED_SHARDS[@]} -eq 0 ]]; then
  while IFS= read -r name; do
    [[ -n "$name" ]] || continue
    SELECTED_SHARDS+=("$name")
  done <<<"$ALL_SHARD_NAMES"
fi

for name in "${SELECTED_SHARDS[@]}"; do
  if ! printf '%s\n' "$ALL_SHARD_NAMES" | grep -Fxq "$name"; then
    echo "run-graph-bats: unknown shard: $name" >&2
    echo "known shards:" >&2
    printf '%s\n' "$ALL_SHARD_NAMES" >&2
    exit 1
  fi
done

# Validate the manifest before any early exit so that --list-shards and
# --list-files are usable as a cheap CI guard, not just the full run.
#
# Scope the check by content rather than by manifest path: any manifest that
# claims to cover tests/bats/graph must cover all of it, including a doctored
# copy under --shards-json. Fixture manifests built by the runner's own tests
# reference absolute temp-dir paths instead, so they are correctly skipped.
if grep -q 'tests/bats/graph/' "$SHARDS_JSON" 2>/dev/null; then
  graph_bats_check_unassigned || exit 1
fi

if [[ "$LIST_SHARDS" -eq 1 ]]; then
  printf '%s\n' "$ALL_SHARD_NAMES"
  exit 0
fi

if [[ "$LIST_FILES" -eq 1 ]]; then
  for name in "${SELECTED_SHARDS[@]}"; do
    while IFS= read -r file; do
      [[ -n "$file" ]] || continue
      if graph_bats_resolve_file "$file" >/dev/null; then
        printf '%s\n' "$file"
      fi
    done < <(graph_bats_shards_query "$SHARDS_JSON" files "$name")
  done
  exit 0
fi

if [[ -z "$JOBS" ]]; then
  JOBS="$(default_parallel_jobs "$(detect_cpu_count)")"
fi
if [[ ! "$JOBS" =~ ^[1-9][0-9]*$ ]]; then
  echo "run-graph-bats: -j/--jobs must be a positive integer" >&2
  exit 1
fi
: "${JOBS_EXPLICIT:=0}"

cd "$REPO_ROOT"

# Match run-bats.sh: inherited agent-shell exports must not leak into tests.
unset WORKSPACE OUTPUT_LOG LOG_FILE PROMPT_STATIC SESSION_ID_FILE SESSION_ID_FILE_LEGACY USAGE_FILE EXIT_CODE_FILE
unset RALPH_AGENT_TOOL_ACCESS RALPH_NATIVE_HOOKS RALPH_MCP_TOOLS_ENABLED RALPH_TOOL_ACCESS_FLAG_SET
unset RALPH_PLAN_SESSION_HOME RALPH_SESSION_DIR RALPH_PLAN_KEY RALPH_ARTIFACT_NS RALPH_PROJECT_ROOT RALPH_AGENT_WORKSPACE RALPH_PLAN_WORKSPACE_ROOT RALPH_RUNTIME_ROOT
unset RALPH_SHARED_RALPH_DIR RALPH_DIR RALPH_LAUNCHER_PID RALPH_BASH_COMPACT_LOG RALPH_BASH_REWRITE_LOG
unset RALPH_PROXY_SHELL_COMPACT_LOG RALPH_MCP_PREFLIGHT_PASSED RALPH_NATIVE_SHELL_WRAPPER RALPH_SKIP_MCP_PREFLIGHT
unset RALPH_PLAN_ALLOW_UNSAFE_RESUME RALPH_PLAN_CAFFEINATED RALPH_PLAN_CLI_RESUME RALPH_PLAN_CONTEXT_BUDGET
unset RALPH_PLAN_INVOCATION_TIMEOUT_RAW RALPH_RUN_PLAN_RESET_COMMAND_USED RALPH_PLAN_SESSION_STRATEGY
unset RALPH_PLAN_SESSION_STRATEGY_ENV_SPECIFIED RALPH_PROXY_SHELL_COMPACT RALPH_HUMAN_CONTEXT_MAX_BYTES_NO_RESUME
unset RALPH_MODE RALPH_PLAN_TODO_MAX_ITERATIONS RALPH_RUN_PLAN_RESUME_SESSION_ID RALPH_RUN_PLAN_NEW_SESSION_ID
unset RALPH_RUN_PLAN_RESUME_BARE RALPH_STRICT_PROXY RALPH_AGENT_TOOL_ACCESS_REQUIRE_PROXY RALPH_OPENCODE_SET_CACHE_KEY
unset RALPH_PROCESS_RUN_DIR RALPH_PROCESS_RUN_ID RALPH_PROCESS_RUN_TOKEN RALPH_PROCESS_GUARDIAN_PID
unset RALPH_PROCESS_RUN_OWNED RALPH_PROCESS_RUN_DEPTH RALPH_PROCESS_ATTACHED_PLAN RALPH_PROCESS_ALLOW_CHILD
unset RALPH_PROCESS_SCOPE_TOKEN RALPH_PROCESS_SUPERVISOR_LOADED RALPH_ALLOW_NESTED_RUNS

if [[ "$SETUP_FIXTURES" -eq 1 ]]; then
  bash "$REPO_ROOT/scripts/setup-test-fixtures.sh"
fi

GRAPH_BATS_WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/ralph-graph-bats.XXXXXX")"
trap 'graph_bats_cleanup_monitors; rm -rf "$GRAPH_BATS_WORK_DIR"' EXIT INT TERM

ANY_FAIL=0
ANY_HUNG=0

for name in "${SELECTED_SHARDS[@]}"; do
  desc="$(graph_bats_shards_query "$SHARDS_JSON" desc "$name")"
  graph_bats_log "SHARD ${name}: ${desc}"
  shard_files=()
  while IFS= read -r file; do
    [[ -n "$file" ]] || continue
    shard_files+=("$file")
  done < <(graph_bats_shards_query "$SHARDS_JSON" files "$name")
  if [[ ${#shard_files[@]} -eq 0 ]]; then
    graph_bats_log "SHARD START ${name} files=0 jobs=${JOBS}"
    graph_bats_log "SHARD DONE ${name} status=0 files=0"
    continue
  fi
  graph_bats_run_shard "$name" "${shard_files[@]}"
done

if [[ "$ANY_HUNG" -eq 1 ]]; then
  graph_bats_log "RUN FAILED hung-file-named=1 (do not hide hangs by increasing timeouts)"
  exit 124
fi
if [[ "$ANY_FAIL" -eq 1 ]]; then
  graph_bats_log "RUN FAILED"
  exit 1
fi
graph_bats_log "RUN OK"
exit 0
