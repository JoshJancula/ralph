#!/usr/bin/env bash
# Graph run event journal: ordered, append-only observability stream.
#
# Schema:
#   <run-dir>/events.jsonl
#
# Each line is a JSON object with:
#   schemaVersion: 1
#   sequence: monotonically increasing integer, unique within the run
#   timestamp: ISO-8601 UTC seconds precision
#   runId: the run id
#   event: one of the event types below
#   nodeId: optional node identifier (when event is node-scoped)
#   attemptId: optional attempt identifier (when event is attempt-scoped)
#   details: compact JSON object; must never contain full prompts or full tool
#            output. Reference ledger-relative log/artifact paths instead.
#
# Event types:
#   run-started            Run initialization
#   run-status-changed     Run-level status transition
#   node-ready             Node became ready for dispatch
#   node-spawn             Attempt started (node entered running)
#   node-running-update    Heartbeat/usage/log-metadata update
#   node-terminal          Attempt reached a terminal outcome
#   node-retry-wait        Node moved to retry-wait
#   node-awaiting-operator Operator decision required
#   node-needs-plan-repair Node contract needs plan edit
#   node-interrupted       Orphaned by supervisor death
#   node-recovered         Interrupted node reset to pending after recovery
#   node-cancelled         Node cancelled
#   node-skipped           Node skipped (router/conditional)
#   operator-request       Permission/checkpoint request created
#   operator-decision      Operator decision recorded
#   budget-warning         Budget/usage warning (estimated/unavailable)
#   budget-exhausted       Hard budget limit reached
#   recovery-start         Stale-run recovery started
#   recovery-finish        Stale-run recovery completed
#   integration-start      Integration node started
#   integration-complete   Integration node succeeded
#   integration-failed     Integration node failed
#   gate-start             Gate node started
#   gate-passed            Gate returned passed
#   gate-changes-required  Gate returned changes-required
#   gate-error             Gate returned error
#   publish-ready          Publish readiness check passed
#   publish-blocked        Publish readiness check failed
#
# All writes go through graph_events_append (which serializes through a single
# run-level lock file) so concurrent node children do not interleave JSON.
# Readers tolerate one truncated final line after a crash but reject malformed
# interior lines. The journal is observability only; the ledger remains
# authoritative scheduler state.

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  echo "This file is meant to be sourced, not executed." >&2
  exit 1
fi

GRAPH_EVENTS_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if ! declare -F graph_logs_resolve >/dev/null 2>&1; then
  # shellcheck source=./graph-logs.sh
  source "$GRAPH_EVENTS_SCRIPT_DIR/graph-logs.sh"
fi
if ! declare -F graph_state_now_iso >/dev/null 2>&1; then
  # shellcheck source=./graph-state.sh
  source "$GRAPH_EVENTS_SCRIPT_DIR/graph-state.sh"
fi

GRAPH_EVENTS_SCHEMA_VERSION=1
GRAPH_EVENTS_LOCK_SUFFIX=".lock"

# graph_events_rel
# Prints the run-relative path of the event journal.
graph_events_rel() {
  printf 'events.jsonl\n'
}

# graph_events_path <run-dir>
# Resolves and returns the absolute path to the events journal.
graph_events_path() {
  local run_dir="$1"
  local run_real
  run_real="$(graph_logs_real_dir "$run_dir")" || {
    echo "Error: graph events run-dir is not a directory: $run_dir" >&2
    return 1
  }
  printf '%s/%s\n' "$run_real" "$(graph_events_rel)"
}

# graph_events_lock_path <run-dir>
# Returns the absolute path to the lock used for serialized writes.
graph_events_lock_path() {
  local run_dir="$1" run_real
  run_real="$(graph_logs_real_dir "$run_dir")" || return 1
  printf '%s/%s%s\n' "$run_real" "$(graph_events_rel)" "$GRAPH_EVENTS_LOCK_SUFFIX"
}

# graph_events_next_sequence <run-dir>
# Reads the last valid JSON line from the journal and returns its sequence + 1.
# On a fresh journal returns 1. Ignores a single truncated final line.
graph_events_next_sequence() {
  local run_dir="$1" journal_path line_count last_line
  journal_path="$(graph_events_path "$run_dir" 2>/dev/null)" || { printf '1\n'; return 0; }
  [[ -f "$journal_path" ]] || { printf '1\n'; return 0; }
  line_count="$(wc -l <"$journal_path" 2>/dev/null | tr -d ' ')" || line_count=0
  if [[ "$line_count" -eq 0 ]]; then
    printf '1\n'
    return 0
  fi
  # Read the last line; if invalid, ignore one truncated tail line and use prior.
  last_line="$(tail -n 1 "$journal_path" 2>/dev/null)"
  if [[ -n "$last_line" ]] && printf '%s\n' "$last_line" | jq -e . >/dev/null 2>&1; then
    printf '%s\n' "$(( $(printf '%s\n' "$last_line" | jq -r '.sequence // 0') + 1 ))"
    return 0
  fi
  # Truncated tail: try the second-to-last line.
  if [[ "$line_count" -ge 2 ]]; then
    last_line="$(tail -n 2 "$journal_path" 2>/dev/null | head -n 1)"
    if printf '%s\n' "$last_line" | jq -e . >/dev/null 2>&1; then
      printf '%s\n' "$(( $(printf '%s\n' "$last_line" | jq -r '.sequence // 0') + 1 ))"
      return 0
    fi
  fi
  printf '1\n'
}

# graph_events_redact_details <details-json> [max-bytes]
# Rejects full prompts and full tool output by redacting credential-looking
# values and capping the serialized size. The event writer calls this before
# appending so a malformed/malicious details object cannot grow the journal
# without bound. Returns the compact JSON object.
graph_events_redact_details() {
  local details_json="$1" max_bytes="${2:-16384}"
  if [[ -z "$details_json" ]]; then
    printf '{}\n'
    return 0
  fi
  if ! printf '%s\n' "$details_json" | jq -e . >/dev/null 2>&1; then
    printf '{}\n'
    return 0
  fi
  # Redact credential-looking string values. Values under keys whose names
  # look like credentials are replaced with "[REDACTED]". Free string values
  # are also redacted when they contain credential keywords.
  local cred_keys_json
  cred_keys_json='["password","token","secret","api_key","api-key","private_key","private-key","bearer","authorization","credential","apikey","privatekey"]'
  details_json="$(printf '%s\n' "$details_json" | jq -c --argjson credKeys "$cred_keys_json" '
    def key_looks_credential($k):
      ($k | ascii_downcase) as $kl |
      ($credKeys | map(. as $c | select($kl | contains($c))) | length) > 0;
    def value_looks_credential:
      . as $v |
      ($v | ascii_downcase) as $vl |
      ($credKeys | map(. as $c | select($vl | contains($c))) | length) > 0;
    def redact:
      if type == "object" then
        with_entries(
          .key as $k |
          .value = (.value | if type == "string" and (key_looks_credential($k) or value_looks_credential) then "[REDACTED]" else . end)
        )
      elif type == "array" then
        map(redact)
      else
        .
      end;
    redact
  ' 2>/dev/null)" || details_json='{}'
  local serialized
  serialized="$(printf '%s' "$details_json" | jq -c . 2>/dev/null)" || serialized='{}'
  if [[ "${#serialized}" -gt "$max_bytes" ]]; then
    printf '{"_truncated":true,"_originalBytes":%d}' "${#serialized}"
    return 0
  fi
  printf '%s\n' "$details_json"
}

# graph_events_validate_event <event>
# Returns 0 when the event string is a recognized event type.
graph_events_validate_event() {
  local event="$1"
  case "$event" in
    run-started|run-status-changed|node-ready|node-spawn|node-running-update|node-terminal|node-retry-wait|node-awaiting-operator|node-needs-plan-repair|node-interrupted|node-recovered|node-cancelled|node-skipped|operator-request|operator-decision|budget-warning|budget-exhausted|recovery-start|recovery-finish|integration-start|integration-complete|integration-failed|gate-start|gate-passed|gate-changes-required|gate-error|publish-ready|publish-blocked|native-subagent-reservation|native-subagent-spawn|native-subagent-running-update|native-subagent-finished|native-subagent-cancelled|native-subagent-failed) return 0 ;;
    *) return 1 ;;
  esac
}

# graph_events_build_line <run-id> <sequence> <event> [node-id] [attempt-id] [details-json]
# Builds and validates one journal line. Prints the compact JSON object.
graph_events_build_line() {
  local run_id="$1" sequence="$2" event="$3" node_id="${4:-}" attempt_id="${5:-}" details_json="${6:-}"
  if [[ -z "$run_id" || -z "$sequence" || -z "$event" ]]; then
    echo "Error: graph_events_build_line requires run_id, sequence, and event" >&2
    return 1
  fi
  if ! [[ "$sequence" =~ ^[0-9]+$ ]]; then
    echo "Error: sequence must be a non-negative integer" >&2
    return 1
  fi
  if ! graph_events_validate_event "$event"; then
    echo "Error: unrecognized graph event type: $event" >&2
    return 1
  fi
  details_json="$(graph_events_redact_details "$details_json")"
  jq -cn \
    --argjson schemaVersion "$GRAPH_EVENTS_SCHEMA_VERSION" \
    --argjson sequence "$sequence" \
    --arg timestamp "$(graph_state_now_iso)" \
    --arg runId "$run_id" \
    --arg event "$event" \
    --arg nodeId "$node_id" \
    --arg attemptId "$attempt_id" \
    --argjson details "$details_json" \
    '{
       schemaVersion: $schemaVersion,
       sequence: $sequence,
       timestamp: $timestamp,
       runId: $runId,
       event: $event,
       nodeId: (if $nodeId == "" then null else $nodeId end),
       attemptId: (if $attemptId == "" then null else $attemptId end),
       details: $details
     }'
}

# graph_events_append <run-dir> <run-id> <event> [node-id] [attempt-id] [details-json]
# Serialized append of one event line. Uses a run-local lock file so multiple
# concurrent writers (node children, supervisor threads) cannot interleave JSON.
# Returns 0 on success, 1 on failure. Never creates a partial line.
graph_events_append() {
  local run_dir="$1" run_id="$2" event="$3" node_id="${4:-}" attempt_id="${5:-}" details_json="${6:-}"
  local journal_path lock_path sequence line parent_dir tmp_file
  if [[ -z "$run_dir" || -z "$run_id" || -z "$event" ]]; then
    echo "Error: graph_events_append requires run_dir, run_id, and event" >&2
    return 1
  fi
  journal_path="$(graph_events_path "$run_dir" 2>/dev/null)" || {
    echo "Error: cannot resolve events.jsonl path in $run_dir" >&2
    return 1
  }
  parent_dir="$(dirname "$journal_path")"
  if ! mkdir -p "$parent_dir"; then
    echo "Error: cannot create events journal directory: $parent_dir" >&2
    return 1
  fi
  lock_path="$(graph_events_lock_path "$run_dir")"

  # Validate the event early so we fail before touching the lock/journal.
  if ! graph_events_validate_event "$event"; then
    echo "Error: unrecognized graph event type: $event" >&2
    return 1
  fi

  # Serialize via a cross-platform file lock. Prefer flock(1) on Linux; on
  # macOS and other systems without flock, use python3 fcntl.lockf for an
  # exclusive lock. This prevents concurrent node children from interleaving
  # JSON lines and keeps sequence numbers monotonic.
  _graph_events_append_locked() {
    sequence="$(graph_events_next_sequence "$run_dir")"
    line="$(graph_events_build_line "$run_id" "$sequence" "$event" "$node_id" "$attempt_id" "$details_json")" || return 1
    printf '%s\n' "$line" >>"$journal_path"
  }

  if command -v flock >/dev/null 2>&1; then
    (
      flock 200 || exit 1
      # Ensure a truncated tail line does not swallow the next append.
      if [[ -f "$journal_path" && -s "$journal_path" ]]; then
        if [[ "$(tail -c 1 "$journal_path" | wc -l)" -eq 0 ]]; then
          printf '\n' >>"$journal_path" || { flock -u 200; exit 1; }
        fi
      fi
      _graph_events_append_locked || exit 1
    ) 200>"$lock_path" || {
      echo "Error: failed to acquire events journal lock" >&2
      return 1
    }
  elif command -v python3 >/dev/null 2>&1; then
    {
      { python3 - "$lock_path" "$journal_path" "$run_dir" "$run_id" "$event" "$node_id" "$attempt_id" "$details_json" <<'PYLOCK' 2>/dev/null || { echo "Error: failed to acquire events journal lock" >&2; return 1; }; }
import fcntl, json, os, sys
lock_path, journal_path, run_dir, run_id, event, node_id, attempt_id, details_json = sys.argv[1:9]
fd = os.open(lock_path, os.O_CREAT | os.O_RDWR)
try:
    fcntl.lockf(fd, fcntl.LOCK_EX)
    sequence = 1
    if os.path.exists(journal_path):
        with open(journal_path, 'r') as f:
            lines = f.read().splitlines()
        for candidate in reversed(lines):
            try:
                obj = json.loads(candidate)
                if isinstance(obj.get('sequence'), int):
                    sequence = obj['sequence'] + 1
                    break
            except Exception:
                pass
    timestamp = __import__('datetime').datetime.utcnow().strftime('%Y-%m-%dT%H:%M:%SZ')
    try:
        details = json.loads(details_json) if details_json else {}
    except Exception:
        details = {}
    # Credential redaction: values under credential-looking keys, and values
    # that contain credential keywords, are replaced with "[REDACTED]".
    import re
    _CRED_KEY_RE = re.compile(r'(?i)(password|token|secret|api[_-]?key|private[_-]?key|bearer|authorization|credential|apikey|privatekey)', re.I)
    _CRED_VALUE_RE = re.compile(r'(?i)(password|token|secret|api[_-]?key|private[_-]?key|bearer|authorization|credential)', re.I)
    def redact(o, key=''):
        if isinstance(o, dict):
            return {k: redact(v, k) for k, v in o.items()}
        if isinstance(o, list):
            return [redact(x, key) for x in o]
        if isinstance(o, str):
            if _CRED_KEY_RE.search(key) or _CRED_VALUE_RE.search(o):
                return '[REDACTED]'
        return o
    details = redact(details)
    serialized = json.dumps(details, separators=(',', ':'))
    if len(serialized) > 16384:
        details = {'_truncated': True, '_originalBytes': len(serialized)}
    line = json.dumps({
        'schemaVersion': 1,
        'sequence': sequence,
        'timestamp': timestamp,
        'runId': run_id,
        'event': event,
        'nodeId': node_id or None,
        'attemptId': attempt_id or None,
        'details': details
    }, separators=(',', ':'))
    # If the journal exists but does not end with a newline (truncated tail),
    # start a fresh line so this append is independent.
    if os.path.exists(journal_path):
        try:
            with open(journal_path, 'rb') as f:
                f.seek(0, os.SEEK_END)
                if f.tell() > 0:
                    f.seek(-1, os.SEEK_END)
                    ends_newline = f.read(1) == b'\n'
                else:
                    ends_newline = True
        except Exception:
            ends_newline = True
    else:
        ends_newline = True
    with open(journal_path, 'a') as f:
        if not ends_newline:
            f.write('\n')
        f.write(line + '\n')
finally:
    fcntl.lockf(fd, fcntl.LOCK_UN)
    os.close(fd)
PYLOCK
    }
  else
    # Last-resort spin-lock using mkdir, with a longer timeout and shorter
    # sleep to tolerate very high concurrency on systems without flock/python3.
    local mkdir_lock="$lock_path.mkdir"
    local lock_start="$(date +%s 2>/dev/null || echo 0)"
    while ! mkdir "$mkdir_lock" 2>/dev/null; do
      local now
      now="$(date +%s 2>/dev/null || echo "$lock_start")"
      if [[ "$(( now - lock_start ))" -gt 30 ]]; then
        echo "Error: timeout acquiring events journal lock" >&2
        return 1
      fi
      sleep 0.01 2>/dev/null || true
    done
    # Ensure a truncated tail line does not swallow the next append.
    if [[ -f "$journal_path" && -s "$journal_path" && "$(tail -c 1 "$journal_path" | wc -l)" -eq 0 ]]; then
      printf '\n' >>"$journal_path" || { rmdir "$mkdir_lock" 2>/dev/null || true; return 1; }
    fi
    _graph_events_append_locked || {
      rmdir "$mkdir_lock" 2>/dev/null || true
      return 1
    }
    rmdir "$mkdir_lock" 2>/dev/null || true
  fi
  return 0
}

# graph_events_read_lines <run-dir>
# Prints every valid journal line, one per line. A single truncated final line
# (no trailing newline) is ignored. Malformed interior lines and a malformed
# final line that is newline-terminated cause an error and return 1 so callers
# can detect corruption.
graph_events_read_lines() {
  local run_dir="$1" journal_path
  journal_path="$(graph_events_path "$run_dir" 2>/dev/null)" || return 1
  [[ -f "$journal_path" ]] || return 0
  local ends_newline=0
  [[ -s "$journal_path" && -z "$(tail -c 1 "$journal_path")" ]] && ends_newline=1

  local -a lines=()
  local line
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ -z "$line" ]] && continue
    lines+=("$line")
  done <"$journal_path"

  local total="${#lines[@]}"
  [[ "$total" -gt 0 ]] || return 0
  local i
  for (( i=0; i<total; i++ )); do
    line="${lines[$i]}"
    if printf '%s\n' "$line" | jq -e . >/dev/null 2>&1; then
      printf '%s\n' "$line"
    elif [[ "$i" -eq "$((total - 1))" && "$ends_newline" -eq 0 ]]; then
      # Truncated final line after crash: ignore.
      return 0
    else
      echo "Error: malformed interior event journal line $((i + 1)) in $journal_path" >&2
      return 1
    fi
  done
}

# graph_events_read_json <run-dir>
# Prints a compact JSON array of all valid event objects.
graph_events_read_json() {
  local run_dir="$1"
  graph_events_read_lines "$run_dir" 2>/dev/null | jq -sc '.'
}

# graph_events_max_sequence <run-dir>
# Prints the highest sequence number observed in valid lines, or 0 when empty.
graph_events_max_sequence() {
  local run_dir="$1"
  graph_events_read_lines "$run_dir" 2>/dev/null | jq -s 'map(.sequence) | max // 0'
}
