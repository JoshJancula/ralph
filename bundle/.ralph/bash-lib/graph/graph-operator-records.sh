#!/usr/bin/env bash
# Durable operator request and decision records for graph-mode runs.
#
# Layout:
#   <run-dir>/operator/requests/<request-id>.json
#   <run-dir>/operator/decisions/<request-id>.json
#
# Writes are create-once and contained: request IDs cannot traverse out of
# the run directory, and an existing request file is never overwritten.
# A request stores identity, effect, resource, choices, timestamps, nonce,
# and a bounded reason. Malformed enums are rejected.
#
# A decision repeats the request identity tuple and stores the choice,
# exact-or-narrower granted rule, actor source, and decidedAt. Replays of
# the identical decision are safe; a conflicting decision fails.

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  echo "This file is meant to be sourced, not executed." >&2
  exit 1
fi

if [[ -n "${GRAPH_OPERATOR_RECORDS_LOADED:-}" ]]; then
  return 0
fi
GRAPH_OPERATOR_RECORDS_LOADED=1

GRAPH_OPERATOR_RECORDS_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if ! declare -F graph_logs_resolve >/dev/null 2>&1; then
  # shellcheck source=./graph-logs.sh
  source "$GRAPH_OPERATOR_RECORDS_SCRIPT_DIR/graph-logs.sh"
fi

GRAPH_OPERATOR_REQUEST_SCHEMA_VERSION=1
GRAPH_OPERATOR_DECISION_SCHEMA_VERSION=1
GRAPH_OPERATOR_REASON_MAX="${GRAPH_OPERATOR_REASON_MAX:-200}"

GRAPH_OPERATOR_EFFECTS='read
write
network'

GRAPH_OPERATOR_CHOICES='allow-once
allow-run
allow-always
deny'

GRAPH_OPERATOR_RUNTIMES='cursor
claude
codex
opencode
antigravity'

GRAPH_OPERATOR_CLASSIFICATIONS='transient-runtime
agent-correctable
operator-permission
plan-contract
terminal-configuration
integrity
cancelled
unknown'

GRAPH_OPERATOR_ACTOR_SOURCES='cli
tui
human
adapter
test'

# graph_operator_now_iso
# Current UTC timestamp. Honors GRAPH_OPERATOR_NOW for tests.
graph_operator_now_iso() {
  if [[ -n "${GRAPH_OPERATOR_NOW:-}" ]]; then
    printf '%s\n' "$GRAPH_OPERATOR_NOW"
    return 0
  fi
  date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date +%Y-%m-%dT%H:%M:%SZ
}

# graph_operator_is_iso_timestamp <value>
graph_operator_is_iso_timestamp() {
  local value="${1:-}"
  [[ "$value" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]]
}

# graph_operator_token_in_list <token> <newline-list>
graph_operator_token_in_list() {
  local token="$1" candidate
  [[ -n "$token" ]] || return 1
  while IFS= read -r candidate; do
    [[ "$candidate" == "$token" ]] && return 0
  done <<< "$2"
  return 1
}

# graph_operator_request_id_valid <request-id>
# Request IDs are a single filesystem-safe token. Reject empty values,
# path separators, traversal, and leading dots.
graph_operator_request_id_valid() {
  local raw="${1:-}"
  if [[ -z "$raw" || "$raw" == *$'\n'* || "$raw" == *$'\r'* ]]; then
    echo "Error: operator request id must be a non-empty single line" >&2
    return 1
  fi
  case "$raw" in
    /*|*\\*|*/*|*".."*|.|..|.*)
      echo "Error: operator request id contains a path component: $raw" >&2
      return 1
      ;;
  esac
  if [[ ! "$raw" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]; then
    echo "Error: operator request id is not a safe identifier: $raw" >&2
    return 1
  fi
  return 0
}

# graph_operator_mint_nonce
# Random nonce for request/decision pairing. Honors GRAPH_OPERATOR_NONCE.
graph_operator_mint_nonce() {
  local nonce=""
  if [[ -n "${GRAPH_OPERATOR_NONCE:-}" ]]; then
    printf '%s\n' "$GRAPH_OPERATOR_NONCE"
    return 0
  fi
  if command -v python3 >/dev/null 2>&1; then
    nonce="$(python3 -c 'import secrets; print(secrets.token_hex(16))' 2>/dev/null || true)"
  fi
  if [[ -z "$nonce" ]] && command -v openssl >/dev/null 2>&1; then
    nonce="$(openssl rand -hex 16 2>/dev/null || true)"
  fi
  if [[ -z "$nonce" && -r /dev/urandom ]]; then
    nonce="$(dd if=/dev/urandom bs=16 count=1 2>/dev/null | od -An -tx1 | tr -d ' \n')"
  fi
  if [[ -z "$nonce" || ! "$nonce" =~ ^[A-Fa-f0-9]{16,}$ ]]; then
    echo "Error: failed to mint an operator request nonce" >&2
    return 1
  fi
  printf '%s\n' "$nonce"
}

# graph_operator_nonce_valid <nonce>
graph_operator_nonce_valid() {
  local nonce="${1:-}"
  if [[ -z "$nonce" || "$nonce" == *$'\n'* || "$nonce" == *$'\r'* ]]; then
    echo "Error: operator request nonce must be a non-empty single line" >&2
    return 1
  fi
  case "$nonce" in
    /*|*\\*|*/*|*".."*)
      echo "Error: operator request nonce contains a path component" >&2
      return 1
      ;;
  esac
  if [[ "${#nonce}" -lt 8 || "${#nonce}" -gt 128 ]]; then
    echo "Error: operator request nonce length is out of bounds" >&2
    return 1
  fi
  return 0
}

# graph_operator_bound_reason <text>
# Redacts credential-looking text and caps length at GRAPH_OPERATOR_REASON_MAX.
graph_operator_bound_reason() {
  local text="${1:-}" max="${GRAPH_OPERATOR_REASON_MAX:-200}" ellipsis="..." keep
  if [[ ! "$max" =~ ^[0-9]+$ ]] || [[ "$max" -lt 1 ]]; then
    max=200
  fi
  text="$(printf '%s' "$text" | tr '\n\r\t' ' ' | tr -s ' ')"
  text="${text# }"
  text="${text% }"
  if command -v python3 >/dev/null 2>&1; then
    text="$(printf '%s' "$text" | python3 -c '
import re, sys
text = sys.stdin.read()
patterns = (
    re.compile(
        r"(?i)(?:password|passwd|secret|token|api[_-]?key|private[_-]?key|"
        r"bearer|authorization|credential)\s*[=:]\s*\S+"
    ),
    re.compile(
        r"(?i)(?<![A-Za-z0-9_-])(?:sk-[A-Za-z0-9_-]{8,}|AKIA[0-9A-Z]{8,}|"
        r"ghp_[A-Za-z0-9]{20,}|xox[baprs]-[A-Za-z0-9-]{10,})(?![A-Za-z0-9_-])"
    ),
)
for pat in patterns:
    text = pat.sub("[REDACTED]", text)
sys.stdout.write(text)
')"
  else
    text="$(printf '%s' "$text" | sed -E \
      -e 's/(password|passwd|secret|token|api[_-]?key|api_key|api-key|private[_-]?key|bearer|authorization|credential)[[:space:]]*[=:][[:space:]]*[^[:space:]]+/[REDACTED]/g' \
      -e 's/sk-[A-Za-z0-9_-]{8,}/[REDACTED]/g')"
  fi
  if [[ "${#text}" -le "$max" ]]; then
    printf '%s\n' "$text"
    return 0
  fi
  keep="$max"
  if [[ "$max" -gt "${#ellipsis}" ]]; then
    keep=$((max - ${#ellipsis}))
  fi
  printf '%s%s\n' "${text:0:$keep}" "$ellipsis"
}

# graph_operator_request_rel <request-id>
# Prints the run-relative path for a request record.
graph_operator_request_rel() {
  local request_id="$1"
  graph_operator_request_id_valid "$request_id" || return 1
  printf 'operator/requests/%s.json\n' "$request_id"
}

# graph_operator_request_path <run-dir> <request-id>
# Resolves the contained absolute path. The leaf may not exist yet.
graph_operator_request_path() {
  local run_dir="$1" request_id="$2" rel
  if [[ -z "$run_dir" || -z "$request_id" ]]; then
    echo "Error: graph_operator_request_path requires run-dir and request-id" >&2
    return 1
  fi
  rel="$(graph_operator_request_rel "$request_id")" || return 1
  graph_logs_resolve "$run_dir" "$rel"
}

# graph_operator_create_once_write <target-path> <json>
# Create the file only if it does not already exist. Concurrent writers
# racing the same path yield exactly one success.
graph_operator_create_once_write() {
  local target_path="$1" json="$2"
  local target_dir tmp_file py_ec=0
  if [[ -z "$target_path" || -z "$json" ]]; then
    echo "Error: graph_operator_create_once_write requires a path and JSON" >&2
    return 1
  fi
  if [[ -e "$target_path" || -L "$target_path" ]]; then
    echo "Error: operator record already exists: $target_path" >&2
    return 2
  fi
  target_dir="$(dirname "$target_path")"
  mkdir -p "$target_dir" || return 1
  tmp_file="$(mktemp "$target_dir/.operator-record-XXXXXX" 2>/dev/null)" || return 1
  if ! printf '%s\n' "$json" >"$tmp_file"; then
    rm -f "$tmp_file"
    return 1
  fi

  if command -v python3 >/dev/null 2>&1; then
    python3 - "$tmp_file" "$target_path" <<'PY'
import os, sys
src, dest = sys.argv[1], sys.argv[2]
with open(src, "rb") as fh:
    payload = fh.read()
if not payload.endswith(b"\n"):
    payload += b"\n"
try:
    fd = os.open(dest, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o644)
except FileExistsError:
    sys.exit(2)
except OSError:
    sys.exit(1)
try:
    os.write(fd, payload)
    os.fsync(fd)
finally:
    os.close(fd)
try:
    dir_fd = os.open(os.path.dirname(dest) or ".", os.O_RDONLY)
except OSError:
    sys.exit(0)
try:
    os.fsync(dir_fd)
finally:
    os.close(dir_fd)
PY
    py_ec=$?
    rm -f "$tmp_file"
    if [[ "$py_ec" -eq 0 ]]; then
      return 0
    fi
    if [[ "$py_ec" -eq 2 || -e "$target_path" ]]; then
      echo "Error: operator record already exists: $target_path" >&2
      return 2
    fi
    echo "Error: failed to create operator record: $target_path" >&2
    return 1
  fi

  if ln "$tmp_file" "$target_path" 2>/dev/null; then
    rm -f "$tmp_file"
    return 0
  fi
  rm -f "$tmp_file"
  echo "Error: operator record already exists: $target_path" >&2
  return 2
}

# graph_operator_load_json <json-or-path>
graph_operator_load_json() {
  local input="${1:-}"
  if [[ -z "$input" ]]; then
    echo "Error: operator record JSON is required" >&2
    return 1
  fi
  if [[ "$input" == \{* ]]; then
    printf '%s' "$input"
    return 0
  fi
  if [[ -f "$input" ]]; then
    cat -- "$input"
    return 0
  fi
  echo "Error: operator record input is not a JSON object or file" >&2
  return 1
}

# graph_operator_validate_choices_json <json-array>
# Prints the normalized unique choices array or fails.
graph_operator_validate_choices_json() {
  local choices_json="$1" item count
  if ! printf '%s' "$choices_json" | jq -e 'type == "array" and length > 0' >/dev/null 2>&1; then
    echo "Error: operator request choices must be a non-empty array" >&2
    return 1
  fi
  count="$(printf '%s' "$choices_json" | jq 'length')"
  local i=0
  while [[ "$i" -lt "$count" ]]; do
    item="$(printf '%s' "$choices_json" | jq -r --argjson i "$i" '.[$i] | tostring')"
    if ! graph_operator_token_in_list "$item" "$GRAPH_OPERATOR_CHOICES"; then
      echo "Error: malformed operator request choice: $item" >&2
      return 1
    fi
    i=$((i + 1))
  done
  printf '%s' "$choices_json" | jq -c '
    reduce .[] as $c ([]; if index($c) then . else . + [$c] end)
  '
}

# graph_operator_request_write <run-dir> <request-json-or-path>
# Validate and create-once persist a request under operator/requests/.
# Prints the contained absolute path on success.
graph_operator_request_write() {
  local run_dir="$1" input="${2:-}"
  local raw extracted request_id nonce namespace run_id node_id attempt_id
  local runtime session_id classification action resource effect reason
  local choices_json created_at expires_at schema_version patterns_json caps_json
  local rel abs parent_rel record

  if [[ -z "$run_dir" ]]; then
    echo "Error: graph_operator_request_write requires a run-dir" >&2
    return 1
  fi
  if [[ ! -d "$run_dir" ]]; then
    echo "Error: operator request run-dir is not a directory: $run_dir" >&2
    return 1
  fi
  command -v jq >/dev/null 2>&1 || {
    echo "Error: jq is required to write an operator request record" >&2
    return 1
  }

  raw="$(graph_operator_load_json "$input")" || return 1
  if ! printf '%s' "$raw" | jq -e 'type == "object"' >/dev/null 2>&1; then
    echo "Error: operator request must be a JSON object" >&2
    return 1
  fi

  extracted="$(printf '%s' "$raw" | jq -c '
    {
      schemaVersion: (.schemaVersion // 1),
      requestId: ((.requestId // .id // "") | tostring),
      nonce: ((.nonce // "") | tostring),
      namespace: ((.namespace // "") | tostring),
      runId: ((.runId // "") | tostring),
      nodeId: ((.nodeId // "") | tostring),
      attemptId: ((.attemptId // "") | tostring),
      runtime: ((.runtime // "") | tostring),
      sessionId: ((.sessionId // .sessionIdentity // .session.id // "") | tostring),
      classification: ((.classification // "") | tostring),
      action: ((.action // .tool // "") | tostring),
      resource: ((.resource // "") | tostring),
      effect: ((.effect // "") | tostring),
      reason: ((.reason // "") | tostring),
      proposedNativePatterns: (
        if (.proposedNativePatterns | type) == "array" then .proposedNativePatterns
        else [] end
      ),
      adapterCapabilities: (
        if (.adapterCapabilities | type) == "object" then .adapterCapabilities
        else {} end
      ),
      choices: (
        if (.choices | type) == "array" then .choices
        elif (.availableDecisions | type) == "array" then .availableDecisions
        else null end
      ),
      createdAt: ((.createdAt // "") | tostring),
      expiresAt: ((.expiresAt // .expiry // "") | tostring)
    }
  ' 2>/dev/null)" || extracted=""

  if [[ -z "$extracted" ]]; then
    echo "Error: operator request JSON could not be parsed" >&2
    return 1
  fi

  schema_version="$(printf '%s' "$extracted" | jq -r '.schemaVersion | tostring')"
  request_id="$(printf '%s' "$extracted" | jq -r '.requestId')"
  nonce="$(printf '%s' "$extracted" | jq -r '.nonce')"
  namespace="$(printf '%s' "$extracted" | jq -r '.namespace')"
  run_id="$(printf '%s' "$extracted" | jq -r '.runId')"
  node_id="$(printf '%s' "$extracted" | jq -r '.nodeId')"
  attempt_id="$(printf '%s' "$extracted" | jq -r '.attemptId')"
  runtime="$(printf '%s' "$extracted" | jq -r '.runtime')"
  session_id="$(printf '%s' "$extracted" | jq -r '.sessionId')"
  classification="$(printf '%s' "$extracted" | jq -r '.classification')"
  action="$(printf '%s' "$extracted" | jq -r '.action')"
  resource="$(printf '%s' "$extracted" | jq -r '.resource')"
  effect="$(printf '%s' "$extracted" | jq -r '.effect')"
  reason="$(printf '%s' "$extracted" | jq -r '.reason')"
  patterns_json="$(printf '%s' "$extracted" | jq -c '.proposedNativePatterns')"
  caps_json="$(printf '%s' "$extracted" | jq -c '.adapterCapabilities')"
  choices_json="$(printf '%s' "$extracted" | jq -c '.choices')"
  created_at="$(printf '%s' "$extracted" | jq -r '.createdAt')"
  expires_at="$(printf '%s' "$extracted" | jq -r '.expiresAt')"

  if [[ "$schema_version" != "$GRAPH_OPERATOR_REQUEST_SCHEMA_VERSION" ]]; then
    echo "Error: unsupported operator request schemaVersion: $schema_version" >&2
    return 1
  fi
  graph_operator_request_id_valid "$request_id" || return 1
  if [[ -z "$namespace" || -z "$run_id" || -z "$node_id" || -z "$attempt_id" ]]; then
    echo "Error: operator request identity requires namespace, runId, nodeId, and attemptId" >&2
    return 1
  fi
  if ! graph_operator_token_in_list "$runtime" "$GRAPH_OPERATOR_RUNTIMES"; then
    echo "Error: malformed operator request runtime: ${runtime:-<empty>}" >&2
    return 1
  fi
  if ! graph_operator_token_in_list "$classification" "$GRAPH_OPERATOR_CLASSIFICATIONS"; then
    echo "Error: malformed operator request classification: ${classification:-<empty>}" >&2
    return 1
  fi
  if [[ -z "$action" || "$action" == *$'\n'* ]]; then
    echo "Error: operator request action must be a non-empty single line" >&2
    return 1
  fi
  if [[ -z "$resource" || "$resource" == *$'\n'* ]]; then
    echo "Error: operator request resource must be a non-empty single line" >&2
    return 1
  fi
  if graph_logs_has_dotdot "$resource"; then
    echo "Error: operator request resource may not contain '..'" >&2
    return 1
  fi
  if ! graph_operator_token_in_list "$effect" "$GRAPH_OPERATOR_EFFECTS"; then
    echo "Error: malformed operator request effect: ${effect:-<empty>}" >&2
    return 1
  fi
  if [[ "$choices_json" == "null" ]]; then
    echo "Error: operator request choices are required" >&2
    return 1
  fi
  choices_json="$(graph_operator_validate_choices_json "$choices_json")" || return 1
  if [[ -z "$nonce" ]]; then
    nonce="$(graph_operator_mint_nonce)" || return 1
  fi
  graph_operator_nonce_valid "$nonce" || return 1
  if [[ -z "$created_at" ]]; then
    created_at="$(graph_operator_now_iso)"
  fi
  if ! graph_operator_is_iso_timestamp "$created_at"; then
    echo "Error: malformed operator request createdAt: ${created_at:-<empty>}" >&2
    return 1
  fi
  if [[ -z "$expires_at" ]]; then
    echo "Error: operator request expiry is required" >&2
    return 1
  fi
  if ! graph_operator_is_iso_timestamp "$expires_at"; then
    echo "Error: malformed operator request expiry: ${expires_at:-<empty>}" >&2
    return 1
  fi
  reason="$(graph_operator_bound_reason "$reason")"

  rel="$(graph_operator_request_rel "$request_id")" || return 1
  parent_rel="${rel%/*}"
  if ! graph_logs_prepare_parent "$run_dir" "$rel"; then
    echo "Error: operator request path is not contained in the run-dir" >&2
    return 1
  fi
  abs="$(graph_logs_resolve "$run_dir" "$rel")" || return 1
  if [[ -L "$abs" ]]; then
    echo "Error: refusing to write through an operator request symlink: $rel" >&2
    return 1
  fi
  if [[ "$abs" != *"/operator/requests/${request_id}.json" ]]; then
    echo "Error: operator request path escaped operator/requests/: $abs" >&2
    return 1
  fi

  record="$(jq -nc \
    --argjson schemaVersion "$GRAPH_OPERATOR_REQUEST_SCHEMA_VERSION" \
    --arg requestId "$request_id" \
    --arg nonce "$nonce" \
    --arg namespace "$namespace" \
    --arg runId "$run_id" \
    --arg nodeId "$node_id" \
    --arg attemptId "$attempt_id" \
    --arg runtime "$runtime" \
    --arg sessionId "$session_id" \
    --arg classification "$classification" \
    --arg action "$action" \
    --arg resource "$resource" \
    --arg effect "$effect" \
    --arg reason "$reason" \
    --argjson proposedNativePatterns "$patterns_json" \
    --argjson adapterCapabilities "$caps_json" \
    --argjson choices "$choices_json" \
    --arg createdAt "$created_at" \
    --arg expiresAt "$expires_at" \
    '{
      schemaVersion:$schemaVersion,
      requestId:$requestId,
      nonce:$nonce,
      namespace:$namespace,
      runId:$runId,
      nodeId:$nodeId,
      attemptId:$attemptId,
      runtime:$runtime,
      sessionId:$sessionId,
      classification:$classification,
      action:$action,
      resource:$resource,
      effect:$effect,
      reason:$reason,
      proposedNativePatterns:$proposedNativePatterns,
      adapterCapabilities:$adapterCapabilities,
      choices:$choices,
      createdAt:$createdAt,
      expiresAt:$expiresAt
    }')" || {
    echo "Error: failed to encode operator request record" >&2
    return 1
  }

  graph_operator_create_once_write "$abs" "$record" || return 1
  # Re-resolve after create so a swapped symlink cannot be reported as success.
  abs="$(graph_logs_resolve "$run_dir" "$rel")" || return 1
  if [[ -L "$abs" ]]; then
    echo "Error: operator request path became a symlink after write: $rel" >&2
    return 1
  fi
  printf '%s\n' "$abs"
}

# graph_operator_request_read <run-dir> <request-id>
# Prints the stored request JSON. Fails when missing or unreadable.
graph_operator_request_read() {
  local run_dir="$1" request_id="$2" abs
  abs="$(graph_operator_request_path "$run_dir" "$request_id")" || return 1
  if [[ ! -f "$abs" || -L "$abs" ]]; then
    echo "Error: operator request record not found: $request_id" >&2
    return 1
  fi
  if ! jq -e 'type == "object"' "$abs" >/dev/null 2>&1; then
    echo "Error: operator request record is not valid JSON: $abs" >&2
    return 1
  fi
  jq -c '.' "$abs"
}

# graph_operator_decision_rel <request-id>
# Prints the run-relative path for a decision record.
graph_operator_decision_rel() {
  local request_id="$1"
  graph_operator_request_id_valid "$request_id" || return 1
  printf 'operator/decisions/%s.json\n' "$request_id"
}

# graph_operator_decision_path <run-dir> <request-id>
# Resolves the contained absolute path. The leaf may not exist yet.
graph_operator_decision_path() {
  local run_dir="$1" request_id="$2" rel
  if [[ -z "$run_dir" || -z "$request_id" ]]; then
    echo "Error: graph_operator_decision_path requires run-dir and request-id" >&2
    return 1
  fi
  rel="$(graph_operator_decision_rel "$request_id")" || return 1
  graph_logs_resolve "$run_dir" "$rel"
}

# graph_operator_iso_expired <now> <expires-at>
# Returns 0 when now is strictly after expires-at. ISO-Z timestamps compare
# lexicographically in chronological order.
graph_operator_iso_expired() {
  local now="$1" expires_at="$2"
  [[ -n "$now" && -n "$expires_at" ]] || return 1
  [[ "$now" > "$expires_at" ]]
}

# graph_operator_effect_is_exact_or_narrower <requested> <granted>
# write->read is narrower. network is only exact. Broader or orthogonal fails.
graph_operator_effect_is_exact_or_narrower() {
  local requested="$1" granted="$2"
  if [[ "$granted" == "$requested" ]]; then
    return 0
  fi
  if [[ "$requested" == "write" && "$granted" == "read" ]]; then
    return 0
  fi
  return 1
}

# graph_operator_resource_is_exact_or_narrower <requested> <granted>
# Exact match always passes. A concrete path under a requested directory or
# trailing glob is narrower. A wildcard grant that is not identical is not
# narrower. Parent paths and expanded globs fail.
graph_operator_resource_is_exact_or_narrower() {
  local requested="$1" granted="$2" prefix
  if [[ -z "$requested" || -z "$granted" ]]; then
    return 1
  fi
  if [[ "$granted" == "$requested" ]]; then
    return 0
  fi
  if graph_logs_has_dotdot "$granted"; then
    return 1
  fi
  case "$granted" in
    *'*'*|*'?'*)
      return 1
      ;;
  esac
  if [[ "$requested" == *'/**' ]]; then
    prefix="${requested%'/**'}"
    [[ -n "$prefix" && ( "$granted" == "$prefix" || "$granted" == "$prefix"/* ) ]]
    return $?
  fi
  if [[ "$requested" == *'/*' ]]; then
    prefix="${requested%'/*'}"
    [[ -n "$prefix" && "$granted" == "$prefix"/* && "$granted" != "$prefix"/*/* ]]
    return $?
  fi
  if [[ "$requested" == */ ]]; then
    prefix="${requested%/}"
    [[ -n "$prefix" && "$granted" == "$prefix"/* ]]
    return $?
  fi
  return 1
}

# graph_operator_grant_is_exact_or_narrower <req-action> <req-resource> <req-effect> \
#   <grant-action> <grant-resource> <grant-effect>
graph_operator_grant_is_exact_or_narrower() {
  local req_action="$1" req_resource="$2" req_effect="$3"
  local grant_action="$4" grant_resource="$5" grant_effect="$6"
  if [[ "$grant_action" != "$req_action" ]]; then
    echo "Error: operator decision grant action must match the request action" >&2
    return 1
  fi
  if ! graph_operator_effect_is_exact_or_narrower "$req_effect" "$grant_effect"; then
    echo "Error: operator decision grant is broader than the requested effect" >&2
    return 1
  fi
  if ! graph_operator_resource_is_exact_or_narrower "$req_resource" "$grant_resource"; then
    echo "Error: operator decision grant is broader than the requested resource" >&2
    return 1
  fi
  return 0
}

# graph_operator_decision_fingerprint <decision-json>
# Stable identity+choice+grant fingerprint used for replay comparison.
graph_operator_decision_fingerprint() {
  local json="$1"
  printf '%s' "$json" | jq -c '{
    requestId: (.requestId // ""),
    nonce: (.nonce // ""),
    namespace: (.namespace // ""),
    runId: (.runId // ""),
    nodeId: (.nodeId // ""),
    attemptId: (.attemptId // ""),
    runtime: (.runtime // ""),
    decision: (.decision // ""),
    granted: (
      if (.granted | type) == "object" then
        {
          action: ((.granted.action // "") | tostring),
          resource: ((.granted.resource // "") | tostring),
          effect: ((.granted.effect // "") | tostring)
        }
      else null end
    )
  }'
}

# graph_operator_node_ledger_path <run-dir> <node-id>
graph_operator_node_ledger_path() {
  local run_dir="$1" node_id="$2" safe rel
  if [[ -z "$run_dir" || -z "$node_id" ]]; then
    echo "Error: graph_operator_node_ledger_path requires run-dir and node-id" >&2
    return 1
  fi
  if [[ "$node_id" == *$'\n'* || "$node_id" == *$'\r'* ]]; then
    echo "Error: operator decision nodeId must be a single line" >&2
    return 1
  fi
  safe="$(printf '%s' "$node_id" | sed 's/[^A-Za-z0-9._-]/_/g')"
  if [[ -z "$safe" || "$safe" == "." || "$safe" == ".." ]]; then
    echo "Error: operator decision nodeId is not a safe identifier: $node_id" >&2
    return 1
  fi
  rel="nodes/${safe}.json"
  graph_logs_resolve "$run_dir" "$rel"
}

# graph_operator_attempt_is_active <run-dir> <node-id> <attempt-id> [runtime]
# Fail-closed: a missing or unreadable node ledger cannot prove an active attempt.
# Active means the node is running or awaiting-operator, lastAttemptId matches
# (when set), the attempt exists, and the attempt is not terminal.
graph_operator_attempt_is_active() {
  local run_dir="$1" node_id="$2" attempt_id="$3" runtime="${4:-}"
  local node_file node_json status last_attempt outcome attempt_runtime

  node_file="$(graph_operator_node_ledger_path "$run_dir" "$node_id")" || return 1
  if [[ ! -f "$node_file" || -L "$node_file" ]]; then
    echo "Error: operator decision cannot prove an active attempt; node ledger not found for $node_id" >&2
    return 1
  fi
  if ! jq -e 'type == "object"' "$node_file" >/dev/null 2>&1; then
    echo "Error: operator decision node ledger is not valid JSON: $node_file" >&2
    return 1
  fi
  node_json="$(jq -c '.' "$node_file")"
  status="$(printf '%s' "$node_json" | jq -r '.status // empty')"
  case "$status" in
    running|awaiting-operator) ;;
    *)
      echo "Error: operator decision attempt is not active (node status: ${status:-<empty>})" >&2
      return 1
      ;;
  esac
  last_attempt="$(printf '%s' "$node_json" | jq -r '.lastAttemptId // empty')"
  if [[ -n "$last_attempt" && "$last_attempt" != "$attempt_id" ]]; then
    echo "Error: operator decision attempt is stale; lastAttemptId is $last_attempt" >&2
    return 1
  fi
  outcome="$(printf '%s' "$node_json" | jq -r --arg aid "$attempt_id" '
    (.attempts // [])[]? | select(.attemptId == $aid) | .outcome // empty
  ' | tail -n 1)"
  if ! printf '%s' "$node_json" | jq -e --arg aid "$attempt_id" '
    (.attempts // []) | map(.attemptId) | index($aid) != null
  ' >/dev/null 2>&1; then
    echo "Error: operator decision attempt $attempt_id was not found on node $node_id" >&2
    return 1
  fi
  case "$outcome" in
    ""|running|awaiting-operator) ;;
    *)
      echo "Error: operator decision attempt is not active (attempt outcome: $outcome)" >&2
      return 1
      ;;
  esac
  if [[ -n "$runtime" ]]; then
    attempt_runtime="$(printf '%s' "$node_json" | jq -r --arg aid "$attempt_id" '
      (.attempts // [])[]? | select(.attemptId == $aid) | .runtime // empty
    ' | tail -n 1)"
    if [[ -n "$attempt_runtime" && "$attempt_runtime" != "$runtime" ]]; then
      echo "Error: operator decision runtime does not match the active attempt" >&2
      return 1
    fi
  fi
  return 0
}

# graph_operator_decision_read <run-dir> <request-id>
# Prints the stored decision JSON. Fails when missing or unreadable.
graph_operator_decision_read() {
  local run_dir="$1" request_id="$2" abs
  abs="$(graph_operator_decision_path "$run_dir" "$request_id")" || return 1
  if [[ ! -f "$abs" || -L "$abs" ]]; then
    echo "Error: operator decision record not found: $request_id" >&2
    return 1
  fi
  if ! jq -e 'type == "object"' "$abs" >/dev/null 2>&1; then
    echo "Error: operator decision record is not valid JSON: $abs" >&2
    return 1
  fi
  jq -c '.' "$abs"
}

# graph_operator_decision_accept_existing <abs> <record>
# Replay-safe when the stored decision fingerprint matches. Conflicting
# stored decisions fail. Prints abs on success.
graph_operator_decision_accept_existing() {
  local abs="$1" record="$2" existing existing_fp new_fp
  if [[ -L "$abs" ]]; then
    echo "Error: refusing to read an operator decision symlink: $abs" >&2
    return 1
  fi
  if [[ ! -f "$abs" ]]; then
    echo "Error: operator decision record not found" >&2
    return 1
  fi
  if ! jq -e 'type == "object"' "$abs" >/dev/null 2>&1; then
    echo "Error: operator decision record is not valid JSON: $abs" >&2
    return 1
  fi
  existing="$(jq -c '.' "$abs")"
  existing_fp="$(graph_operator_decision_fingerprint "$existing")" || return 1
  new_fp="$(graph_operator_decision_fingerprint "$record")" || return 1
  if [[ "$existing_fp" == "$new_fp" ]]; then
    printf '%s\n' "$abs"
    return 0
  fi
  echo "Error: operator decision conflicts with an already resolved request" >&2
  return 1
}

# graph_operator_decision_write <run-dir> <decision-json-or-path>
# Validate and create-once persist a decision under operator/decisions/.
# Replays of the identical decision succeed without rewriting. Prints the
# contained absolute path on success.
graph_operator_decision_write() {
  local run_dir="$1" input="${2:-}"
  local raw extracted request_id nonce namespace run_id node_id attempt_id
  local runtime decision actor_source decided_at schema_version
  local grant_action grant_resource grant_effect granted_json
  local request_json req_nonce req_namespace req_run_id req_node_id
  local req_attempt_id req_runtime req_action req_resource req_effect
  local req_expires req_choices now rel abs parent_rel record write_ec

  if [[ -z "$run_dir" ]]; then
    echo "Error: graph_operator_decision_write requires a run-dir" >&2
    return 1
  fi
  if [[ ! -d "$run_dir" ]]; then
    echo "Error: operator decision run-dir is not a directory: $run_dir" >&2
    return 1
  fi
  command -v jq >/dev/null 2>&1 || {
    echo "Error: jq is required to write an operator decision record" >&2
    return 1
  }

  raw="$(graph_operator_load_json "$input")" || return 1
  if ! printf '%s' "$raw" | jq -e 'type == "object"' >/dev/null 2>&1; then
    echo "Error: operator decision must be a JSON object" >&2
    return 1
  fi

  extracted="$(printf '%s' "$raw" | jq -c '
    {
      schemaVersion: (.schemaVersion // 1),
      requestId: ((.requestId // .id // "") | tostring),
      nonce: ((.nonce // "") | tostring),
      namespace: ((.namespace // "") | tostring),
      runId: ((.runId // "") | tostring),
      nodeId: ((.nodeId // "") | tostring),
      attemptId: ((.attemptId // "") | tostring),
      runtime: ((.runtime // "") | tostring),
      decision: ((.decision // .choice // "") | tostring),
      actorSource: ((.actorSource // .actor // "human") | tostring),
      decidedAt: ((.decidedAt // "") | tostring),
      granted: (
        if (.granted | type) == "object" then .granted
        elif (.grantedRule | type) == "object" then .grantedRule
        elif (.grant | type) == "object" then .grant
        else null end
      )
    }
  ' 2>/dev/null)" || extracted=""

  if [[ -z "$extracted" ]]; then
    echo "Error: operator decision JSON could not be parsed" >&2
    return 1
  fi

  schema_version="$(printf '%s' "$extracted" | jq -r '.schemaVersion | tostring')"
  request_id="$(printf '%s' "$extracted" | jq -r '.requestId')"
  nonce="$(printf '%s' "$extracted" | jq -r '.nonce')"
  namespace="$(printf '%s' "$extracted" | jq -r '.namespace')"
  run_id="$(printf '%s' "$extracted" | jq -r '.runId')"
  node_id="$(printf '%s' "$extracted" | jq -r '.nodeId')"
  attempt_id="$(printf '%s' "$extracted" | jq -r '.attemptId')"
  runtime="$(printf '%s' "$extracted" | jq -r '.runtime')"
  decision="$(printf '%s' "$extracted" | jq -r '.decision')"
  actor_source="$(printf '%s' "$extracted" | jq -r '.actorSource')"
  decided_at="$(printf '%s' "$extracted" | jq -r '.decidedAt')"
  granted_json="$(printf '%s' "$extracted" | jq -c '.granted')"

  if [[ "$schema_version" != "$GRAPH_OPERATOR_DECISION_SCHEMA_VERSION" ]]; then
    echo "Error: unsupported operator decision schemaVersion: $schema_version" >&2
    return 1
  fi
  graph_operator_request_id_valid "$request_id" || return 1
  graph_operator_nonce_valid "$nonce" || return 1
  if ! graph_operator_token_in_list "$decision" "$GRAPH_OPERATOR_CHOICES"; then
    echo "Error: malformed operator decision choice: ${decision:-<empty>}" >&2
    return 1
  fi
  if ! graph_operator_token_in_list "$actor_source" "$GRAPH_OPERATOR_ACTOR_SOURCES"; then
    echo "Error: malformed operator decision actorSource: ${actor_source:-<empty>}" >&2
    return 1
  fi
  if [[ -z "$decided_at" ]]; then
    decided_at="$(graph_operator_now_iso)"
  fi
  if ! graph_operator_is_iso_timestamp "$decided_at"; then
    echo "Error: malformed operator decision decidedAt: ${decided_at:-<empty>}" >&2
    return 1
  fi

  request_json="$(graph_operator_request_read "$run_dir" "$request_id")" || return 1
  req_nonce="$(printf '%s' "$request_json" | jq -r '.nonce // empty')"
  req_namespace="$(printf '%s' "$request_json" | jq -r '.namespace // empty')"
  req_run_id="$(printf '%s' "$request_json" | jq -r '.runId // empty')"
  req_node_id="$(printf '%s' "$request_json" | jq -r '.nodeId // empty')"
  req_attempt_id="$(printf '%s' "$request_json" | jq -r '.attemptId // empty')"
  req_runtime="$(printf '%s' "$request_json" | jq -r '.runtime // empty')"
  req_action="$(printf '%s' "$request_json" | jq -r '.action // empty')"
  req_resource="$(printf '%s' "$request_json" | jq -r '.resource // empty')"
  req_effect="$(printf '%s' "$request_json" | jq -r '.effect // empty')"
  req_expires="$(printf '%s' "$request_json" | jq -r '.expiresAt // empty')"
  req_choices="$(printf '%s' "$request_json" | jq -c '.choices')"

  if [[ "$nonce" != "$req_nonce" ]]; then
    echo "Error: operator decision nonce does not match the request" >&2
    return 1
  fi
  [[ -n "$namespace" ]] || namespace="$req_namespace"
  [[ -n "$run_id" ]] || run_id="$req_run_id"
  [[ -n "$node_id" ]] || node_id="$req_node_id"
  [[ -n "$attempt_id" ]] || attempt_id="$req_attempt_id"
  [[ -n "$runtime" ]] || runtime="$req_runtime"
  if [[ "$namespace" != "$req_namespace" || "$run_id" != "$req_run_id" || \
        "$node_id" != "$req_node_id" || "$attempt_id" != "$req_attempt_id" ]]; then
    echo "Error: operator decision run/node/attempt identity does not match the request" >&2
    return 1
  fi
  if [[ "$runtime" != "$req_runtime" ]]; then
    echo "Error: operator decision runtime does not match the request" >&2
    return 1
  fi
  if ! graph_operator_token_in_list "$runtime" "$GRAPH_OPERATOR_RUNTIMES"; then
    echo "Error: malformed operator decision runtime: ${runtime:-<empty>}" >&2
    return 1
  fi

  now="$(graph_operator_now_iso)"
  if ! graph_operator_is_iso_timestamp "$req_expires"; then
    echo "Error: operator request expiry is missing or malformed" >&2
    return 1
  fi
  if graph_operator_iso_expired "$now" "$req_expires"; then
    echo "Error: operator request has expired" >&2
    return 1
  fi

  if ! printf '%s' "$req_choices" | jq -e --arg d "$decision" 'type == "array" and index($d) != null' >/dev/null 2>&1; then
    echo "Error: operator decision is not an available choice: $decision" >&2
    return 1
  fi

  if [[ "$decision" == "deny" ]]; then
    granted_json="null"
  else
    if [[ "$granted_json" == "null" ]]; then
      granted_json="$(jq -nc \
        --arg action "$req_action" \
        --arg resource "$req_resource" \
        --arg effect "$req_effect" \
        '{action:$action,resource:$resource,effect:$effect}')"
    fi
    grant_action="$(printf '%s' "$granted_json" | jq -r '.action // empty')"
    grant_resource="$(printf '%s' "$granted_json" | jq -r '.resource // empty')"
    grant_effect="$(printf '%s' "$granted_json" | jq -r '.effect // empty')"
    if [[ -z "$grant_action" || -z "$grant_resource" || -z "$grant_effect" ]]; then
      echo "Error: operator decision grant requires action, resource, and effect" >&2
      return 1
    fi
    if graph_logs_has_dotdot "$grant_resource"; then
      echo "Error: operator decision grant resource may not contain '..'" >&2
      return 1
    fi
    if ! graph_operator_token_in_list "$grant_effect" "$GRAPH_OPERATOR_EFFECTS"; then
      echo "Error: malformed operator decision grant effect: $grant_effect" >&2
      return 1
    fi
    graph_operator_grant_is_exact_or_narrower \
      "$req_action" "$req_resource" "$req_effect" \
      "$grant_action" "$grant_resource" "$grant_effect" || return 1
    granted_json="$(jq -nc \
      --arg action "$grant_action" \
      --arg resource "$grant_resource" \
      --arg effect "$grant_effect" \
      '{action:$action,resource:$resource,effect:$effect}')"
  fi

  graph_operator_attempt_is_active "$run_dir" "$node_id" "$attempt_id" "$runtime" || return 1

  rel="$(graph_operator_decision_rel "$request_id")" || return 1
  parent_rel="${rel%/*}"
  if ! graph_logs_prepare_parent "$run_dir" "$rel"; then
    echo "Error: operator decision path is not contained in the run-dir" >&2
    return 1
  fi
  abs="$(graph_logs_resolve "$run_dir" "$rel")" || return 1
  if [[ -L "$abs" ]]; then
    echo "Error: refusing to write through an operator decision symlink: $rel" >&2
    return 1
  fi
  if [[ "$abs" != *"/operator/decisions/${request_id}.json" ]]; then
    echo "Error: operator decision path escaped operator/decisions/: $abs" >&2
    return 1
  fi

  record="$(jq -nc \
    --argjson schemaVersion "$GRAPH_OPERATOR_DECISION_SCHEMA_VERSION" \
    --arg requestId "$request_id" \
    --arg nonce "$nonce" \
    --arg namespace "$namespace" \
    --arg runId "$run_id" \
    --arg nodeId "$node_id" \
    --arg attemptId "$attempt_id" \
    --arg runtime "$runtime" \
    --arg decision "$decision" \
    --argjson granted "$granted_json" \
    --arg actorSource "$actor_source" \
    --arg decidedAt "$decided_at" \
    '{
      schemaVersion:$schemaVersion,
      requestId:$requestId,
      nonce:$nonce,
      namespace:$namespace,
      runId:$runId,
      nodeId:$nodeId,
      attemptId:$attemptId,
      runtime:$runtime,
      decision:$decision,
      granted:$granted,
      actorSource:$actorSource,
      decidedAt:$decidedAt
    }')" || {
    echo "Error: failed to encode operator decision record" >&2
    return 1
  }

  if [[ -e "$abs" ]]; then
    graph_operator_decision_accept_existing "$abs" "$record" || return 1
    return 0
  fi

  write_ec=0
  graph_operator_create_once_write "$abs" "$record" || write_ec=$?
  if [[ "$write_ec" -eq 0 ]]; then
    abs="$(graph_logs_resolve "$run_dir" "$rel")" || return 1
    if [[ -L "$abs" ]]; then
      echo "Error: operator decision path became a symlink after write: $rel" >&2
      return 1
    fi
    printf '%s\n' "$abs"
    return 0
  fi
  if [[ "$write_ec" -eq 2 || -e "$abs" ]]; then
    graph_operator_decision_accept_existing "$abs" "$record" || return 1
    return 0
  fi
  return 1
}
