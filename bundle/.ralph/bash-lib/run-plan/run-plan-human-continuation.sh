#!/usr/bin/env bash
# Tier-2 human-answer continuation records (consume-once).
#
# Human answers always cross invocations. Persist a bounded continuation record
# under $RALPH_SESSION_DIR/continuations/ and resolve todo-continue on the next
# invocation via the per-TODO session manifest, regardless of background tier or
# cross-TODO session strategy.

if [[ -n "${RALPH_HUMAN_CONTINUATION_LOADED:-}" ]]; then
  return 0 2>/dev/null || exit 0
fi
RALPH_HUMAN_CONTINUATION_LOADED=1

_ralph_human_continuation_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
unset _ralph_human_continuation_dir

ralph_human_continuation_require_session_dir() {
  [[ -n "${RALPH_SESSION_DIR:-}" ]] || {
    printf '%s\n' "Error: RALPH_SESSION_DIR is required for human-answer continuation" >&2
    return 1
  }
  command -v jq >/dev/null 2>&1 || {
    printf '%s\n' "Error: jq is required for human-answer continuation" >&2
    return 1
  }
}

ralph_human_continuation_root() {
  ralph_human_continuation_require_session_dir || return 1
  printf '%s/continuations\n' "$RALPH_SESSION_DIR"
}

ralph_human_continuation_record_path() {
  local request_id="${1:-}"
  local root
  [[ -n "$request_id" && "$request_id" != *"/"* && "$request_id" != *".."* ]] || return 1
  root="$(ralph_human_continuation_root)" || return 1
  printf '%s/%s.json\n' "$root" "$request_id"
}

ralph_human_continuation_consumed_marker_path() {
  local request_id="${1:-}" record_path
  record_path="$(ralph_human_continuation_record_path "$request_id")" || return 1
  printf '%s.consumed\n' "$record_path"
}

ralph_human_continuation_request_id_for_attempt() {
  local attempt_key="${1:-}"
  local hash=""
  [[ -n "$attempt_key" ]] || return 1
  if command -v shasum >/dev/null 2>&1; then
    hash="$(printf '%s' "$attempt_key" | shasum -a 256 | awk '{print $1}' | head -c 16)"
  elif command -v sha256sum >/dev/null 2>&1; then
    hash="$(printf '%s' "$attempt_key" | sha256sum | awk '{print $1}' | head -c 16)"
  else
    hash="$(printf '%s' "$attempt_key" | tr -c '[:alnum:]' '-' | head -c 16)"
  fi
  printf 'human-answer-%s\n' "$hash"
}

ralph_human_continuation_find_active_manifest_identity() {
  local dir record_path record state found count
  declare -F ralph_session_todo_manifest_dir >/dev/null 2>&1 || return 1
  dir="$(ralph_session_todo_manifest_dir 2>/dev/null)" || return 1
  [[ -d "$dir" ]] || return 1
  found=""
  count=0
  for record_path in "$dir"/*.json; do
    [[ -f "$record_path" ]] || continue
    record="$(jq -c '.' "$record_path" 2>/dev/null)" || continue
    state="$(jq -r '.state // empty' <<<"$record")"
    [[ "$state" == "active" ]] || continue
    found="$(jq -c '.identity // empty' <<<"$record")"
    [[ -n "$found" && "$found" != "null" ]] || continue
    count=$((count + 1))
  done
  [[ "$count" -eq 1 && -n "$found" ]] || return 1
  printf '%s\n' "$found"
}

ralph_human_continuation_resolve_identity() {
  local identity todo_line request_file
  if [[ -n "${RALPH_CURRENT_TODO_LINE:-}" ]] && declare -F ralph_session_todo_identity_json >/dev/null 2>&1; then
    ralph_session_todo_identity_json
    return 0
  fi
  request_file="${HUMAN_REQUEST_FILE:-${RALPH_SESSION_DIR:-}/human-request.json}"
  if [[ -f "$request_file" ]]; then
    # ralph_write_human_request_artifact nests the TODO as .todo.line; older
    # records and the operator-response template use a flat .todo_line.
    todo_line="$(jq -r '(.todo.line // .todo_line) // empty' "$request_file" 2>/dev/null || true)"
    if [[ -n "$todo_line" && "$todo_line" != "0" && "$todo_line" != "null" ]]; then
      identity="$(ralph_session_todo_identity_json 2>/dev/null || true)"
      # Not "${identity:-{}}": bash closes that expansion one brace early, so a
      # real identity record arrives with a stray trailing "}" and jq rejects it.
      [[ -n "$identity" ]] || identity='{}'
      identity="$(jq -c --arg todoLine "$todo_line" '.todoLine = $todoLine' <<<"$identity")"
      printf '%s\n' "$identity"
      return 0
    fi
  fi
  if identity="$(ralph_human_continuation_find_active_manifest_identity 2>/dev/null)"; then
    printf '%s\n' "$identity"
    return 0
  fi
  if declare -F ralph_session_todo_identity_json >/dev/null 2>&1; then
    ralph_session_todo_identity_json
    return 0
  fi
  return 1
}

ralph_human_continuation_persist() {
  local route="${1:-generic}"
  local permission_decision="${2:-}"
  local identity attempt_key request_id path marker now_iso record

  ralph_human_continuation_require_session_dir || return 1
  identity="$(ralph_human_continuation_resolve_identity)" || return 1
  declare -F ralph_session_todo_attempt_key >/dev/null 2>&1 || return 1
  attempt_key="$(ralph_session_todo_attempt_key "$identity")"
  request_id="$(ralph_human_continuation_request_id_for_attempt "$attempt_key")" || return 1
  path="$(ralph_human_continuation_record_path "$request_id")" || return 1
  marker="$(ralph_human_continuation_consumed_marker_path "$request_id")" || return 1
  [[ ! -f "$path" ]] || return 1
  [[ ! -f "$marker" ]] || return 1

  now_iso="$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u)"
  record="$(jq -nc \
    --argjson schema_version 1 \
    --arg kind "human-answer" \
    --arg request_id "$request_id" \
    --arg tier "invocation" \
    --arg reason "human-answer" \
    --arg route "$route" \
    --arg permission_decision "$permission_decision" \
    --arg attempt_key "$attempt_key" \
    --argjson identity "$identity" \
    --arg created_at "$now_iso" \
    '{
      schema_version: $schema_version,
      kind: $kind,
      request_id: $request_id,
      tier: $tier,
      reason: $reason,
      route: $route,
      permission_decision: (if $permission_decision == "" then null else $permission_decision end),
      attempt_key: $attempt_key,
      identity: $identity,
      consumed: false,
      created_at: $created_at,
      consumed_at: null
    }')"

  mkdir -p "$(dirname "$path")"
  umask 077
  printf '%s\n' "$record" >"${path}.tmp" && mv -f "${path}.tmp" "$path"
  chmod 600 "$path" 2>/dev/null || true
  jq -c '.' <<<"$record"
}

ralph_human_continuation_find_pending() {
  local root attempt_key current_key record_path record consumed marker
  ralph_human_continuation_require_session_dir || return 1
  declare -F ralph_session_todo_attempt_key >/dev/null 2>&1 || return 1
  root="$(ralph_human_continuation_root)" || return 1
  [[ -d "$root" ]] || return 1
  current_key="$(ralph_session_todo_attempt_key "$(ralph_session_todo_identity_json)")"
  for record_path in "$root"/human-answer-*.json; do
    [[ -f "$record_path" ]] || continue
    record="$(jq -c '.' "$record_path" 2>/dev/null)" || continue
    [[ "$(jq -r '.kind // empty' <<<"$record")" == "human-answer" ]] || continue
    [[ "$(jq -r '.consumed // false' <<<"$record")" == "false" ]] || continue
    attempt_key="$(jq -r '.attempt_key // empty' <<<"$record")"
    [[ -n "$attempt_key" && "$attempt_key" == "$current_key" ]] || continue
    marker="$(ralph_human_continuation_consumed_marker_path "$(jq -r '.request_id // empty' <<<"$record")")"
    [[ ! -f "$marker" ]] || continue
    jq -c '.' <<<"$record"
    return 0
  done
  return 1
}

ralph_human_continuation_mark_consumed() {
  local request_id="${1:-}" path marker now_iso
  [[ -n "$request_id" ]] || return 1
  path="$(ralph_human_continuation_record_path "$request_id")" || return 1
  marker="$(ralph_human_continuation_consumed_marker_path "$request_id")" || return 1
  [[ -f "$path" ]] || return 1
  [[ ! -f "$marker" ]] || return 1
  now_iso="$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u)"
  jq -c --arg consumed_at "$now_iso" '.consumed = true | .consumed_at = $consumed_at' "$path" >"${path}.tmp" \
    && mv -f "${path}.tmp" "$path"
  printf '%s\n' "$now_iso" >"${marker}.tmp" && mv -f "${marker}.tmp" "$marker"
}

# Returns 0 when a pending human-answer continuation was consumed for this TODO.
ralph_human_continuation_try_apply() {
  local record request_id route
  record="$(ralph_human_continuation_find_pending 2>/dev/null || true)"
  [[ -n "$record" ]] || return 1
  request_id="$(jq -r '.request_id // empty' <<<"$record")"
  [[ -n "$request_id" ]] || return 1
  ralph_human_continuation_mark_consumed "$request_id" || return 1
  # The prompt builder tells a resumed agent why its previous turn stopped.
  route="$(jq -r '.route // empty' <<<"$record")"
  if [[ "$route" == "permission" ]]; then
    export RALPH_CONTINUATION_ROUTE="permission"
  else
    unset RALPH_CONTINUATION_ROUTE 2>/dev/null || true
  fi
  RALPH_PLAN_INVOCATION_REASON="${RALPH_TODO_INVOCATION_REASON_CONTINUE:-todo-continue}"
  export RALPH_PLAN_INVOCATION_REASON
  export RALPH_USAGE_CONTINUATION_REASON="human-answer"
  export RALPH_USAGE_SESSION_CONTINUITY="resumed"
  if declare -F ralph_run_plan_log >/dev/null 2>&1; then
    ralph_run_plan_log "tier2 human-answer continuation: consumed record ${request_id}; scheduling todo-continue invocation"
  fi
  return 0
}
