#!/usr/bin/env bash
# Run-local and project-scoped approval policy for graph-mode permission
# requests.
#
# Run rules: exact normalized allow-run and deny records stored only under
# the selected run, at <run-dir>/operator/policy/<rule-id>.json.
#
# Project rules: exact normalized allow-always records stored only under
# the state root at <state-root>/operator-policy/approvals.json, keyed by
# canonical project identity. A second confirmation record is required
# before an allow-always rule becomes active. Revocation is recorded in
# place. These helpers never edit runtime-global files.
#
# Resolution order for a request:
#   1. explicit runtime or managed denial on the request
#   2. Ralph deny rule for the exact normalized key
#   3. allow-once decision for this request id
#   4. exact allow-run rule for the same key
#   5. exact active project allow-always for the same key
#   6. ask
#
# Matching is exact after normalization. A more-specific allow cannot
# weaken a deny for the same key: deny is checked first, and a conflicting
# write is rejected. Managed/runtime denial remains supreme.

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  echo "This file is meant to be sourced, not executed." >&2
  exit 1
fi

if [[ -n "${GRAPH_APPROVAL_POLICY_LOADED:-}" ]]; then
  return 0
fi
GRAPH_APPROVAL_POLICY_LOADED=1

GRAPH_APPROVAL_POLICY_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if ! declare -F graph_operator_create_once_write >/dev/null 2>&1; then
  # shellcheck source=./graph-operator-records.sh
  source "$GRAPH_APPROVAL_POLICY_SCRIPT_DIR/graph-operator-records.sh"
fi

if ! declare -F ralph_atomic_write_json >/dev/null 2>&1; then
  # shellcheck source=../atomic-json.sh
  source "$GRAPH_APPROVAL_POLICY_SCRIPT_DIR/../atomic-json.sh"
fi

GRAPH_APPROVAL_RULE_SCHEMA_VERSION=1
GRAPH_APPROVAL_RUN_DECISIONS='allow-run
deny'
GRAPH_APPROVAL_PROJECT_DECISIONS='allow-always'
GRAPH_APPROVAL_RUNTIME_GLOBAL_HOMES='.cursor
.claude
.codex
.opencode
.agents'

# graph_approval_now_iso
# Current UTC timestamp. Honors GRAPH_APPROVAL_NOW, then GRAPH_OPERATOR_NOW.
graph_approval_now_iso() {
  if [[ -n "${GRAPH_APPROVAL_NOW:-}" ]]; then
    printf '%s\n' "$GRAPH_APPROVAL_NOW"
    return 0
  fi
  graph_operator_now_iso
}

# graph_approval_trim <value>
graph_approval_trim() {
  local s="${1-}"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

# graph_approval_lowercase <value>
graph_approval_lowercase() {
  printf '%s' "${1-}" | tr '[:upper:]' '[:lower:]'
}

# graph_approval_normalize_resource <resource>
# Trim, strip leading ./, collapse duplicate slashes, drop a trailing slash
# (except "/"), and reject empty values, newlines, and '..' components.
graph_approval_normalize_resource() {
  local resource
  resource="$(graph_approval_trim "${1-}")"
  if [[ -z "$resource" || "$resource" == *$'\n'* || "$resource" == *$'\r'* ]]; then
    echo "Error: approval resource must be a non-empty single line" >&2
    return 1
  fi
  if graph_logs_has_dotdot "$resource"; then
    echo "Error: approval resource may not contain '..'" >&2
    return 1
  fi
  while [[ "$resource" == ./* ]]; do
    resource="${resource#./}"
  done
  while [[ "$resource" == *//* ]]; do
    resource="${resource//\/\//\/}"
  done
  if [[ "$resource" != "/" && "$resource" == */ ]]; then
    resource="${resource%/}"
  fi
  if [[ -z "$resource" ]]; then
    echo "Error: approval resource must be a non-empty single line" >&2
    return 1
  fi
  printf '%s\n' "$resource"
}

# graph_approval_normalize_rule <runtime> <action> <resource> <effect>
# Prints compact JSON {runtime,action,resource,effect} or fails.
graph_approval_normalize_rule() {
  local runtime action resource effect
  runtime="$(graph_approval_lowercase "$(graph_approval_trim "${1-}")")"
  action="$(graph_approval_trim "${2-}")"
  resource="$(graph_approval_normalize_resource "${3-}")" || return 1
  effect="$(graph_approval_lowercase "$(graph_approval_trim "${4-}")")"

  if ! graph_operator_token_in_list "$runtime" "$GRAPH_OPERATOR_RUNTIMES"; then
    echo "Error: malformed approval runtime: ${runtime:-<empty>}" >&2
    return 1
  fi
  if [[ -z "$action" || "$action" == *$'\n'* || "$action" == *$'\r'* ]]; then
    echo "Error: approval action must be a non-empty single line" >&2
    return 1
  fi
  if ! graph_operator_token_in_list "$effect" "$GRAPH_OPERATOR_EFFECTS"; then
    echo "Error: malformed approval effect: ${effect:-<empty>}" >&2
    return 1
  fi

  jq -nc \
    --arg runtime "$runtime" \
    --arg action "$action" \
    --arg resource "$resource" \
    --arg effect "$effect" \
    '{runtime:$runtime,action:$action,resource:$resource,effect:$effect}'
}

# graph_approval_rule_id <runtime> <action> <resource> <effect>
# Stable filesystem-safe id for the exact normalized key.
graph_approval_rule_id() {
  local runtime="$1" action="$2" resource="$3" effect="$4" digest=""
  if command -v shasum >/dev/null 2>&1; then
    digest="$(printf '%s\n' "$runtime" "$action" "$resource" "$effect" | shasum -a 256 2>/dev/null | awk '{print $1}')"
  elif command -v sha256sum >/dev/null 2>&1; then
    digest="$(printf '%s\n' "$runtime" "$action" "$resource" "$effect" | sha256sum 2>/dev/null | awk '{print $1}')"
  elif command -v openssl >/dev/null 2>&1; then
    digest="$(printf '%s\n' "$runtime" "$action" "$resource" "$effect" | openssl dgst -sha256 2>/dev/null | awk '{print $NF}')"
  elif command -v python3 >/dev/null 2>&1; then
    digest="$(printf '%s\n' "$runtime" "$action" "$resource" "$effect" | python3 -c 'import hashlib,sys; print(hashlib.sha256(sys.stdin.buffer.read()).hexdigest())' 2>/dev/null)"
  fi
  if [[ -z "$digest" || ! "$digest" =~ ^[a-f0-9]{32,}$ ]]; then
    echo "Error: failed to hash approval rule identity" >&2
    return 1
  fi
  printf '%s\n' "$digest"
}

# graph_approval_run_rule_rel <rule-id>
graph_approval_run_rule_rel() {
  local rule_id="$1"
  graph_operator_request_id_valid "$rule_id" || return 1
  printf 'operator/policy/%s.json\n' "$rule_id"
}

# graph_approval_run_rule_path <run-dir> <rule-id>
graph_approval_run_rule_path() {
  local run_dir="$1" rule_id="$2" rel
  if [[ -z "$run_dir" || -z "$rule_id" ]]; then
    echo "Error: graph_approval_run_rule_path requires run-dir and rule-id" >&2
    return 1
  fi
  rel="$(graph_approval_run_rule_rel "$rule_id")" || return 1
  graph_logs_resolve "$run_dir" "$rel"
}

# graph_approval_rule_fingerprint <rule-json>
graph_approval_rule_fingerprint() {
  local json="$1"
  printf '%s' "$json" | jq -c '{
    schemaVersion: (.schemaVersion // 1),
    decision: (.decision // ""),
    runtime: (.runtime // ""),
    action: (.action // ""),
    resource: (.resource // ""),
    effect: (.effect // "")
  }'
}

# graph_approval_run_rule_accept_existing <abs> <record>
# Replay-safe when the stored exact rule matches. Conflicting rules fail.
graph_approval_run_rule_accept_existing() {
  local abs="$1" record="$2" existing existing_fp new_fp
  if [[ -L "$abs" ]]; then
    echo "Error: refusing to read an approval rule symlink: $abs" >&2
    return 1
  fi
  if [[ ! -f "$abs" ]]; then
    echo "Error: approval run rule not found" >&2
    return 1
  fi
  if ! jq -e 'type == "object"' "$abs" >/dev/null 2>&1; then
    echo "Error: approval run rule is not valid JSON: $abs" >&2
    return 1
  fi
  existing="$(jq -c '.' "$abs")"
  existing_fp="$(graph_approval_rule_fingerprint "$existing")" || return 1
  new_fp="$(graph_approval_rule_fingerprint "$record")" || return 1
  if [[ "$existing_fp" == "$new_fp" ]]; then
    printf '%s\n' "$abs"
    return 0
  fi
  echo "Error: approval run rule conflicts with an existing exact rule" >&2
  return 1
}

# graph_approval_run_rule_write <run-dir> <rule-json-or-path>
# Validate and create-once persist an exact allow-run or deny rule under the
# selected run. Identical replays succeed without rewriting. Prints the
# contained absolute path on success.
graph_approval_run_rule_write() {
  local run_dir="$1" input="${2:-}"
  local raw extracted decision runtime action resource effect
  local request_id created_at schema_version normalized rule_id rel abs
  local record write_ec

  if [[ -z "$run_dir" ]]; then
    echo "Error: graph_approval_run_rule_write requires a run-dir" >&2
    return 1
  fi
  if [[ ! -d "$run_dir" ]]; then
    echo "Error: approval run-dir is not a directory: $run_dir" >&2
    return 1
  fi
  command -v jq >/dev/null 2>&1 || {
    echo "Error: jq is required to write an approval run rule" >&2
    return 1
  }

  raw="$(graph_operator_load_json "$input")" || return 1
  if ! printf '%s' "$raw" | jq -e 'type == "object"' >/dev/null 2>&1; then
    echo "Error: approval run rule must be a JSON object" >&2
    return 1
  fi

  extracted="$(printf '%s' "$raw" | jq -c '
    {
      schemaVersion: (.schemaVersion // 1),
      decision: ((.decision // .choice // "") | tostring),
      runtime: ((.runtime // "") | tostring),
      action: ((.action // "") | tostring),
      resource: ((.resource // .pattern // "") | tostring),
      effect: ((.effect // "") | tostring),
      requestId: ((.requestId // "") | tostring),
      createdAt: ((.createdAt // "") | tostring)
    }
  ' 2>/dev/null)" || extracted=""

  if [[ -z "$extracted" ]]; then
    echo "Error: approval run rule JSON could not be parsed" >&2
    return 1
  fi

  schema_version="$(printf '%s' "$extracted" | jq -r '.schemaVersion | tostring')"
  decision="$(printf '%s' "$extracted" | jq -r '.decision')"
  runtime="$(printf '%s' "$extracted" | jq -r '.runtime')"
  action="$(printf '%s' "$extracted" | jq -r '.action')"
  resource="$(printf '%s' "$extracted" | jq -r '.resource')"
  effect="$(printf '%s' "$extracted" | jq -r '.effect')"
  request_id="$(printf '%s' "$extracted" | jq -r '.requestId')"
  created_at="$(printf '%s' "$extracted" | jq -r '.createdAt')"

  if [[ "$schema_version" != "$GRAPH_APPROVAL_RULE_SCHEMA_VERSION" ]]; then
    echo "Error: unsupported approval rule schemaVersion: $schema_version" >&2
    return 1
  fi
  if ! graph_operator_token_in_list "$decision" "$GRAPH_APPROVAL_RUN_DECISIONS"; then
    echo "Error: approval run rule decision must be allow-run or deny: ${decision:-<empty>}" >&2
    return 1
  fi

  normalized="$(graph_approval_normalize_rule "$runtime" "$action" "$resource" "$effect")" || return 1
  runtime="$(printf '%s' "$normalized" | jq -r '.runtime')"
  action="$(printf '%s' "$normalized" | jq -r '.action')"
  resource="$(printf '%s' "$normalized" | jq -r '.resource')"
  effect="$(printf '%s' "$normalized" | jq -r '.effect')"

  if [[ -n "$request_id" ]]; then
    graph_operator_request_id_valid "$request_id" || return 1
  fi
  if [[ -z "$created_at" ]]; then
    created_at="$(graph_approval_now_iso)"
  fi
  if ! graph_operator_is_iso_timestamp "$created_at"; then
    echo "Error: malformed approval rule createdAt: ${created_at:-<empty>}" >&2
    return 1
  fi

  rule_id="$(graph_approval_rule_id "$runtime" "$action" "$resource" "$effect")" || return 1
  rel="$(graph_approval_run_rule_rel "$rule_id")" || return 1
  if ! graph_logs_prepare_parent "$run_dir" "$rel"; then
    echo "Error: approval rule path is not contained in the run-dir" >&2
    return 1
  fi
  abs="$(graph_logs_resolve "$run_dir" "$rel")" || return 1
  if [[ -L "$abs" ]]; then
    echo "Error: refusing to write through an approval rule symlink: $rel" >&2
    return 1
  fi
  if [[ "$abs" != *"/operator/policy/${rule_id}.json" ]]; then
    echo "Error: approval rule path escaped operator/policy/: $abs" >&2
    return 1
  fi

  record="$(jq -nc \
    --argjson schemaVersion "$GRAPH_APPROVAL_RULE_SCHEMA_VERSION" \
    --arg scope "run" \
    --arg decision "$decision" \
    --arg runtime "$runtime" \
    --arg action "$action" \
    --arg resource "$resource" \
    --arg effect "$effect" \
    --arg requestId "$request_id" \
    --arg createdAt "$created_at" \
    '{
      schemaVersion:$schemaVersion,
      scope:$scope,
      decision:$decision,
      runtime:$runtime,
      action:$action,
      resource:$resource,
      effect:$effect,
      createdAt:$createdAt
    } + (if $requestId == "" then {} else {requestId:$requestId} end)')" || {
    echo "Error: failed to encode approval run rule" >&2
    return 1
  }

  if [[ -e "$abs" ]]; then
    graph_approval_run_rule_accept_existing "$abs" "$record" || return 1
    return 0
  fi

  write_ec=0
  graph_operator_create_once_write "$abs" "$record" || write_ec=$?
  if [[ "$write_ec" -eq 0 ]]; then
    abs="$(graph_logs_resolve "$run_dir" "$rel")" || return 1
    if [[ -L "$abs" ]]; then
      echo "Error: approval rule path became a symlink after write: $rel" >&2
      return 1
    fi
    printf '%s\n' "$abs"
    return 0
  fi
  if [[ "$write_ec" -eq 2 || -e "$abs" ]]; then
    graph_approval_run_rule_accept_existing "$abs" "$record" || return 1
    return 0
  fi
  return 1
}

# graph_approval_run_rule_read <run-dir> <runtime> <action> <resource> <effect>
# Prints the exact stored rule JSON, or fails when absent/malformed.
graph_approval_run_rule_read() {
  local run_dir="$1" normalized rule_id abs
  if [[ -z "$run_dir" ]]; then
    echo "Error: graph_approval_run_rule_read requires a run-dir" >&2
    return 1
  fi
  normalized="$(graph_approval_normalize_rule "$2" "$3" "$4" "$5")" || return 1
  rule_id="$(graph_approval_rule_id \
    "$(printf '%s' "$normalized" | jq -r '.runtime')" \
    "$(printf '%s' "$normalized" | jq -r '.action')" \
    "$(printf '%s' "$normalized" | jq -r '.resource')" \
    "$(printf '%s' "$normalized" | jq -r '.effect')")" || return 1
  abs="$(graph_approval_run_rule_path "$run_dir" "$rule_id")" || return 1
  if [[ -L "$abs" ]]; then
    echo "Error: refusing to read an approval rule symlink: $abs" >&2
    return 1
  fi
  if [[ ! -f "$abs" ]]; then
    echo "Error: approval run rule not found" >&2
    return 1
  fi
  if ! jq -e 'type == "object"' "$abs" >/dev/null 2>&1; then
    echo "Error: approval run rule is not valid JSON: $abs" >&2
    return 1
  fi
  jq -c '.' "$abs"
}

# graph_approval_run_rule_list <run-dir>
# Prints a JSON array of stored run rules. A missing policy directory is [].
# A malformed rule file fails the list so deny cannot be skipped silently.
# Read-only: never creates operator/policy.
graph_approval_run_rule_list() {
  local run_dir="$1" abs dir
  if [[ -z "$run_dir" ]]; then
    echo "Error: graph_approval_run_rule_list requires a run-dir" >&2
    return 1
  fi
  if [[ ! -d "$run_dir" ]]; then
    echo "Error: approval run-dir is not a directory: $run_dir" >&2
    return 1
  fi
  abs="$(graph_logs_resolve "$run_dir" "operator/policy/x" 2>/dev/null)" || {
    printf '[]\n'
    return 0
  }
  dir="$(dirname "$abs")"
  if [[ ! -d "$dir" ]]; then
    printf '[]\n'
    return 0
  fi
  if [[ -L "$dir" ]]; then
    echo "Error: refusing to list approval rules through a symlink" >&2
    return 1
  fi

  local files=() file
  shopt -s nullglob
  files=("$dir"/*.json)
  shopt -u nullglob
  if [[ "${#files[@]}" -eq 0 ]]; then
    printf '[]\n'
    return 0
  fi
  for file in "${files[@]}"; do
    if [[ -L "$file" ]] || ! jq -e 'type == "object"' "$file" >/dev/null 2>&1; then
      echo "Error: malformed approval run rule: $file" >&2
      return 1
    fi
  done
  jq -cs 'sort_by(.runtime,.action,.resource,.effect,.decision)' "${files[@]}"
}

# graph_approval_explicit_denial_source <request-json>
# Prints "runtime" or "managed" when the request carries an explicit
# runtime/managed denial. Runtime is reported when both are present.
graph_approval_explicit_denial_source() {
  local json="$1" runtime_flag managed_flag source_token
  runtime_flag="$(printf '%s' "$json" | jq -r '
    def truthy: . == true or . == 1 or . == "true" or . == "1" or . == "yes";
    if ((.runtimeDenial | truthy) or (.runtimeDenied | truthy) or (.runtimeDeny | truthy))
      then "1" else "0" end
  ' 2>/dev/null)" || runtime_flag="0"
  managed_flag="$(printf '%s' "$json" | jq -r '
    def truthy: . == true or . == 1 or . == "true" or . == "1" or . == "yes";
    if ((.managedDenial | truthy) or (.managedDenied | truthy) or (.managedDeny | truthy))
      then "1" else "0" end
  ' 2>/dev/null)" || managed_flag="0"
  source_token="$(printf '%s' "$json" | jq -r \
    '(.denialSource // .explicitDenial // .denySource // "") | tostring' 2>/dev/null)" || source_token=""
  source_token="$(graph_approval_lowercase "$(graph_approval_trim "$source_token")")"

  if [[ "$runtime_flag" == "1" || "$source_token" == "runtime" || "$source_token" == "runtime-denial" ]]; then
    printf 'runtime\n'
    return 0
  fi
  if [[ "$managed_flag" == "1" || "$source_token" == "managed" || "$source_token" == "managed-denial" ]]; then
    printf 'managed\n'
    return 0
  fi
  return 1
}

# graph_approval_allow_once_matches <run-dir> <request-id>
# Returns 0 when this request id has an allow-once decision record.
graph_approval_allow_once_matches() {
  local run_dir="$1" request_id="$2" abs decision
  [[ -n "$request_id" ]] || return 1
  graph_operator_request_id_valid "$request_id" >/dev/null 2>&1 || return 1
  abs="$(graph_operator_decision_path "$run_dir" "$request_id" 2>/dev/null)" || return 1
  [[ -f "$abs" && ! -L "$abs" ]] || return 1
  if ! jq -e 'type == "object"' "$abs" >/dev/null 2>&1; then
    return 1
  fi
  decision="$(jq -r '.decision // empty' "$abs" 2>/dev/null)" || return 1
  [[ "$decision" == "allow-once" ]]
}

# graph_approval_emit_resolution <decision> <source> <matched-json-or-null>
graph_approval_emit_resolution() {
  local decision="$1" source="$2" matched="${3:-null}"
  jq -nc \
    --arg decision "$decision" \
    --arg source "$source" \
    --argjson matched "$matched" \
    '{decision:$decision,source:$source,matched:$matched}'
}

# graph_approval_run_rule_lookup <run-dir> <normalized-json>
# Exit 0: prints the stored exact rule.
# Exit 1: no rule for this key.
# Exit 2: the exact-key file exists but is unreadable or malformed.
graph_approval_run_rule_lookup() {
  local run_dir="$1" normalized="$2" rule_id abs
  rule_id="$(graph_approval_rule_id \
    "$(printf '%s' "$normalized" | jq -r '.runtime')" \
    "$(printf '%s' "$normalized" | jq -r '.action')" \
    "$(printf '%s' "$normalized" | jq -r '.resource')" \
    "$(printf '%s' "$normalized" | jq -r '.effect')")" || return 2
  abs="$(graph_approval_run_rule_path "$run_dir" "$rule_id")" || return 2
  if [[ -L "$abs" ]]; then
    echo "Error: refusing to read an approval rule symlink: $abs" >&2
    return 2
  fi
  if [[ ! -e "$abs" ]]; then
    return 1
  fi
  if [[ ! -f "$abs" ]] || ! jq -e 'type == "object"' "$abs" >/dev/null 2>&1; then
    echo "Error: approval run rule is not valid JSON: $abs" >&2
    return 2
  fi
  jq -c '.' "$abs"
}

# graph_approval_sha256_text <text>
# Stable hex digest used for project identity and confirmation ids.
graph_approval_sha256_text() {
  local digest=""
  if command -v shasum >/dev/null 2>&1; then
    digest="$(printf '%s' "${1-}" | shasum -a 256 2>/dev/null | awk '{print $1}')"
  elif command -v sha256sum >/dev/null 2>&1; then
    digest="$(printf '%s' "${1-}" | sha256sum 2>/dev/null | awk '{print $1}')"
  elif command -v openssl >/dev/null 2>&1; then
    digest="$(printf '%s' "${1-}" | openssl dgst -sha256 2>/dev/null | awk '{print $NF}')"
  elif command -v python3 >/dev/null 2>&1; then
    digest="$(printf '%s' "${1-}" | python3 -c 'import hashlib,sys; print(hashlib.sha256(sys.stdin.buffer.read()).hexdigest())' 2>/dev/null)"
  fi
  if [[ -z "$digest" || ! "$digest" =~ ^[a-f0-9]{32,}$ ]]; then
    echo "Error: failed to hash approval identity" >&2
    return 1
  fi
  printf '%s\n' "$digest"
}

# graph_approval_is_runtime_global_path <path>
# Returns 0 when path is a known runtime-global home directory.
graph_approval_is_runtime_global_path() {
  local path="$1" home_real="" candidate="" name
  [[ -n "$path" ]] || return 1
  home_real="$(graph_logs_real_dir "${HOME:-}" 2>/dev/null || true)"
  [[ -n "$home_real" ]] || return 1
  while IFS= read -r name; do
    [[ -n "$name" ]] || continue
    candidate="$home_real/$name"
    if [[ "$path" == "$candidate" || "$path" == "$candidate"/* ]]; then
      return 0
    fi
  done <<< "$GRAPH_APPROVAL_RUNTIME_GLOBAL_HOMES"
  return 1
}

# graph_approval_project_identity <project-root>
# Canonical project identity: sha256 of the physical project-root path.
graph_approval_project_identity() {
  local project_root="$1" real
  if [[ -z "$project_root" ]]; then
    echo "Error: graph_approval_project_identity requires a project-root" >&2
    return 1
  fi
  real="$(graph_logs_real_dir "$project_root")" || {
    echo "Error: approval project-root is not a directory: $project_root" >&2
    return 1
  }
  graph_approval_sha256_text "$real"
}

# graph_approval_project_canonical_root <project-root>
graph_approval_project_canonical_root() {
  local project_root="$1" real
  real="$(graph_logs_real_dir "$project_root")" || {
    echo "Error: approval project-root is not a directory: $project_root" >&2
    return 1
  }
  printf '%s\n' "$real"
}

# graph_approval_project_policy_rel
graph_approval_project_policy_rel() {
  printf 'operator-policy/approvals.json\n'
}

# graph_approval_project_policy_path <state-root>
graph_approval_project_policy_path() {
  local state_root="$1" rel abs
  if [[ -z "$state_root" ]]; then
    echo "Error: graph_approval_project_policy_path requires a state-root" >&2
    return 1
  fi
  if [[ ! -d "$state_root" ]]; then
    echo "Error: approval state-root is not a directory: $state_root" >&2
    return 1
  fi
  rel="$(graph_approval_project_policy_rel)"
  abs="$(graph_logs_resolve "$state_root" "$rel")" || return 1
  if graph_approval_is_runtime_global_path "$abs"; then
    echo "Error: approval policy refuses to write a runtime-global path: $abs" >&2
    return 1
  fi
  printf '%s\n' "$abs"
}

# graph_approval_project_confirm_rel <project-id> <confirm-id>
graph_approval_project_confirm_rel() {
  local project_id="$1" confirm_id="$2"
  graph_operator_request_id_valid "$project_id" || return 1
  graph_operator_request_id_valid "$confirm_id" || return 1
  printf 'operator-policy/confirmations/%s/%s.json\n' "$project_id" "$confirm_id"
}

# graph_approval_project_confirm_id <project-id> <request-id>
# One confirmation record per original request. A later confirmation for
# the same request with a different exact rule is a conflict.
graph_approval_project_confirm_id() {
  local project_id="$1" request_id="$2"
  graph_approval_sha256_text "$(printf '%s\n%s' "$project_id" "$request_id")"
}

# graph_approval_project_empty_store
graph_approval_project_empty_store() {
  printf '{"schemaVersion":1,"projects":{}}\n'
}

# graph_approval_project_store_read <abs>
# Prints the store JSON. Missing file is an empty store. Malformed is exit 2.
graph_approval_project_store_read() {
  local abs="$1"
  if [[ -z "$abs" ]]; then
    echo "Error: graph_approval_project_store_read requires a path" >&2
    return 1
  fi
  if [[ -L "$abs" ]]; then
    echo "Error: refusing to read a project approval symlink: $abs" >&2
    return 2
  fi
  if [[ ! -e "$abs" ]]; then
    graph_approval_project_empty_store
    return 0
  fi
  if [[ ! -f "$abs" ]] || ! jq -e '
    type == "object"
    and ((.schemaVersion // 1) | tostring) == "1"
    and ((.projects // {}) | type == "object")
  ' "$abs" >/dev/null 2>&1; then
    echo "Error: malformed project approval policy: $abs" >&2
    return 2
  fi
  jq -c '.' "$abs"
}

# graph_approval_project_lock_path <state-root>
graph_approval_project_lock_path() {
  local state_root="$1" abs
  abs="$(graph_logs_resolve "$state_root" "operator-policy/approvals.lock")" || return 1
  printf '%s\n' "$abs"
}

# graph_approval_project_with_lock <state-root> <callback>
# Serializes store mutations. Callback runs in the same shell.
graph_approval_project_with_lock() {
  local state_root="$1"
  local lock_path mkdir_lock
  lock_path="$(graph_approval_project_lock_path "$state_root")" || return 1
  mkdir -p "$(dirname "$lock_path")" || return 1

  if command -v flock >/dev/null 2>&1; then
    (
      flock 200 || exit 1
      graph_approval_project_locked_body
    ) 200>"$lock_path"
    return $?
  fi

  mkdir_lock="${lock_path}.mkdir"
  local started now
  started="$(date +%s 2>/dev/null || echo 0)"
  while ! mkdir "$mkdir_lock" 2>/dev/null; do
    now="$(date +%s 2>/dev/null || echo "$started")"
    if [[ "$((now - started))" -gt 30 ]]; then
      echo "Error: timeout acquiring project approval lock" >&2
      return 1
    fi
    sleep 0.01 2>/dev/null || true
  done
  graph_approval_project_locked_body
  local ec=$?
  rmdir "$mkdir_lock" 2>/dev/null || true
  return "$ec"
}

# graph_approval_project_confirm_write <state-root> <project-root> <confirm-json-or-path>
# Create-once confirmation for an allow-always grant. Identical replays are
# safe. Prints the contained confirmation path.
graph_approval_project_confirm_write() {
  local state_root="$1" project_root="$2" input="${3:-}"
  local raw extracted request_id runtime action resource effect created_at
  local normalized project_id confirm_id rel abs record write_ec

  if [[ -z "$state_root" || -z "$project_root" ]]; then
    echo "Error: graph_approval_project_confirm_write requires state-root and project-root" >&2
    return 1
  fi
  if [[ ! -d "$state_root" ]]; then
    echo "Error: approval state-root is not a directory: $state_root" >&2
    return 1
  fi
  command -v jq >/dev/null 2>&1 || {
    echo "Error: jq is required to write an approval confirmation" >&2
    return 1
  }

  project_id="$(graph_approval_project_identity "$project_root")" || return 1
  project_root="$(graph_approval_project_canonical_root "$project_root")" || return 1

  raw="$(graph_operator_load_json "$input")" || return 1
  if ! printf '%s' "$raw" | jq -e 'type == "object"' >/dev/null 2>&1; then
    echo "Error: approval confirmation must be a JSON object" >&2
    return 1
  fi

  extracted="$(printf '%s' "$raw" | jq -c '
    {
      requestId: ((.requestId // .id // "") | tostring),
      runtime: ((.runtime // "") | tostring),
      action: ((.action // "") | tostring),
      resource: ((.resource // .pattern // "") | tostring),
      effect: ((.effect // "") | tostring),
      createdAt: ((.createdAt // "") | tostring)
    }
  ' 2>/dev/null)" || extracted=""
  if [[ -z "$extracted" ]]; then
    echo "Error: approval confirmation JSON could not be parsed" >&2
    return 1
  fi

  request_id="$(printf '%s' "$extracted" | jq -r '.requestId')"
  runtime="$(printf '%s' "$extracted" | jq -r '.runtime')"
  action="$(printf '%s' "$extracted" | jq -r '.action')"
  resource="$(printf '%s' "$extracted" | jq -r '.resource')"
  effect="$(printf '%s' "$extracted" | jq -r '.effect')"
  created_at="$(printf '%s' "$extracted" | jq -r '.createdAt')"

  graph_operator_request_id_valid "$request_id" || return 1
  normalized="$(graph_approval_normalize_rule "$runtime" "$action" "$resource" "$effect")" || return 1
  runtime="$(printf '%s' "$normalized" | jq -r '.runtime')"
  action="$(printf '%s' "$normalized" | jq -r '.action')"
  resource="$(printf '%s' "$normalized" | jq -r '.resource')"
  effect="$(printf '%s' "$normalized" | jq -r '.effect')"

  if [[ -z "$created_at" ]]; then
    created_at="$(graph_approval_now_iso)"
  fi
  if ! graph_operator_is_iso_timestamp "$created_at"; then
    echo "Error: malformed approval confirmation createdAt: ${created_at:-<empty>}" >&2
    return 1
  fi

  confirm_id="$(graph_approval_project_confirm_id "$project_id" "$request_id")" || return 1
  rel="$(graph_approval_project_confirm_rel "$project_id" "$confirm_id")" || return 1
  if ! graph_logs_prepare_parent "$state_root" "$rel"; then
    echo "Error: approval confirmation path is not contained in the state-root" >&2
    return 1
  fi
  abs="$(graph_logs_resolve "$state_root" "$rel")" || return 1
  if [[ -L "$abs" ]]; then
    echo "Error: refusing to write through an approval confirmation symlink: $rel" >&2
    return 1
  fi
  if graph_approval_is_runtime_global_path "$abs"; then
    echo "Error: approval policy refuses to write a runtime-global path: $abs" >&2
    return 1
  fi

  record="$(jq -nc \
    --argjson schemaVersion "$GRAPH_APPROVAL_RULE_SCHEMA_VERSION" \
    --arg kind "allow-always-confirmation" \
    --arg projectId "$project_id" \
    --arg projectRoot "$project_root" \
    --arg requestId "$request_id" \
    --arg runtime "$runtime" \
    --arg action "$action" \
    --arg resource "$resource" \
    --arg effect "$effect" \
    --arg createdAt "$created_at" \
    '{
      schemaVersion:$schemaVersion,
      kind:$kind,
      projectId:$projectId,
      projectRoot:$projectRoot,
      requestId:$requestId,
      runtime:$runtime,
      action:$action,
      resource:$resource,
      effect:$effect,
      createdAt:$createdAt
    }')" || {
    echo "Error: failed to encode approval confirmation" >&2
    return 1
  }

  if [[ -e "$abs" ]]; then
    if [[ -L "$abs" ]] || ! jq -e 'type == "object"' "$abs" >/dev/null 2>&1; then
      echo "Error: approval confirmation is not valid JSON: $abs" >&2
      return 1
    fi
    if [[ "$(jq -c '{kind,projectId,requestId,runtime,action,resource,effect}' "$abs")" == \
          "$(printf '%s' "$record" | jq -c '{kind,projectId,requestId,runtime,action,resource,effect}')" ]]; then
      printf '%s\n' "$abs"
      return 0
    fi
    echo "Error: approval confirmation conflicts with an existing record" >&2
    return 1
  fi

  write_ec=0
  graph_operator_create_once_write "$abs" "$record" || write_ec=$?
  if [[ "$write_ec" -eq 0 ]]; then
    abs="$(graph_logs_resolve "$state_root" "$rel")" || return 1
    if [[ -L "$abs" ]]; then
      echo "Error: approval confirmation path became a symlink after write: $rel" >&2
      return 1
    fi
    printf '%s\n' "$abs"
    return 0
  fi
  if [[ "$write_ec" -eq 2 || -e "$abs" ]]; then
    if [[ "$(jq -c '{kind,projectId,requestId,runtime,action,resource,effect}' "$abs" 2>/dev/null)" == \
          "$(printf '%s' "$record" | jq -c '{kind,projectId,requestId,runtime,action,resource,effect}')" ]]; then
      printf '%s\n' "$abs"
      return 0
    fi
    echo "Error: approval confirmation conflicts with an existing record" >&2
    return 1
  fi
  return 1
}

# graph_approval_project_confirm_lookup <state-root> <project-id> <request-id> <normalized-json>
# Exit 0: prints confirmation JSON matching the exact rule.
# Exit 1: missing or exact-rule mismatch. Exit 2: malformed.
graph_approval_project_confirm_lookup() {
  local state_root="$1" project_id="$2" request_id="$3" normalized="$4"
  local confirm_id rel abs record
  confirm_id="$(graph_approval_project_confirm_id "$project_id" "$request_id")" || return 2
  rel="$(graph_approval_project_confirm_rel "$project_id" "$confirm_id")" || return 2
  abs="$(graph_logs_resolve "$state_root" "$rel")" || return 2
  if [[ -L "$abs" ]]; then
    echo "Error: refusing to read an approval confirmation symlink: $abs" >&2
    return 2
  fi
  if [[ ! -e "$abs" ]]; then
    return 1
  fi
  if [[ ! -f "$abs" ]] || ! jq -e 'type == "object" and .kind == "allow-always-confirmation"' "$abs" >/dev/null 2>&1; then
    echo "Error: malformed approval confirmation: $abs" >&2
    return 2
  fi
  record="$(jq -c '.' "$abs")"
  if [[ "$(printf '%s' "$record" | jq -c '{runtime,action,resource,effect}')" != \
        "$(printf '%s' "$normalized" | jq -c '{runtime,action,resource,effect}')" ]]; then
    return 1
  fi
  printf '%s\n' "$record"
}

# graph_approval_project_rule_active <rule-json>
graph_approval_project_rule_active() {
  local revoked
  revoked="$(printf '%s' "$1" | jq -r '.revokedAt // empty')"
  [[ -z "$revoked" ]]
}

# graph_approval_project_rule_key_match <rule-json> <normalized-json>
graph_approval_project_rule_key_match() {
  local rule="$1" normalized="$2"
  [[ "$(printf '%s' "$rule" | jq -c '{runtime,action,resource,effect}')" == \
     "$(printf '%s' "$normalized" | jq -c '{runtime,action,resource,effect}')" ]]
}

# graph_approval_project_rule_write <state-root> <project-root> <rule-json-or-path>
# Persist an exact allow-always rule after a matching confirmation record
# exists. Identical active replays are idempotent. Prints the store path.
graph_approval_project_rule_write() {
  local state_root="$1" project_root="$2" input="${3:-}"
  local raw extracted decision runtime action resource effect request_id created_at
  local normalized project_id confirm_json store_abs store_json record existing
  local confirm_ec=0 write_ec=0

  if [[ -z "$state_root" || -z "$project_root" ]]; then
    echo "Error: graph_approval_project_rule_write requires state-root and project-root" >&2
    return 1
  fi
  if [[ ! -d "$state_root" ]]; then
    echo "Error: approval state-root is not a directory: $state_root" >&2
    return 1
  fi
  command -v jq >/dev/null 2>&1 || {
    echo "Error: jq is required to write a project approval rule" >&2
    return 1
  }

  project_id="$(graph_approval_project_identity "$project_root")" || return 1
  project_root="$(graph_approval_project_canonical_root "$project_root")" || return 1

  raw="$(graph_operator_load_json "$input")" || return 1
  if ! printf '%s' "$raw" | jq -e 'type == "object"' >/dev/null 2>&1; then
    echo "Error: approval project rule must be a JSON object" >&2
    return 1
  fi

  extracted="$(printf '%s' "$raw" | jq -c '
    {
      schemaVersion: (.schemaVersion // 1),
      decision: ((.decision // .choice // "allow-always") | tostring),
      runtime: ((.runtime // "") | tostring),
      action: ((.action // "") | tostring),
      resource: ((.resource // .pattern // "") | tostring),
      effect: ((.effect // "") | tostring),
      requestId: ((.requestId // "") | tostring),
      createdAt: ((.createdAt // "") | tostring)
    }
  ' 2>/dev/null)" || extracted=""
  if [[ -z "$extracted" ]]; then
    echo "Error: approval project rule JSON could not be parsed" >&2
    return 1
  fi

  decision="$(printf '%s' "$extracted" | jq -r '.decision')"
  runtime="$(printf '%s' "$extracted" | jq -r '.runtime')"
  action="$(printf '%s' "$extracted" | jq -r '.action')"
  resource="$(printf '%s' "$extracted" | jq -r '.resource')"
  effect="$(printf '%s' "$extracted" | jq -r '.effect')"
  request_id="$(printf '%s' "$extracted" | jq -r '.requestId')"
  created_at="$(printf '%s' "$extracted" | jq -r '.createdAt')"

  if [[ "$(printf '%s' "$extracted" | jq -r '.schemaVersion | tostring')" != "$GRAPH_APPROVAL_RULE_SCHEMA_VERSION" ]]; then
    echo "Error: unsupported approval rule schemaVersion: $(printf '%s' "$extracted" | jq -r '.schemaVersion')" >&2
    return 1
  fi
  if ! graph_operator_token_in_list "$decision" "$GRAPH_APPROVAL_PROJECT_DECISIONS"; then
    echo "Error: approval project rule decision must be allow-always: ${decision:-<empty>}" >&2
    return 1
  fi
  graph_operator_request_id_valid "$request_id" || return 1
  normalized="$(graph_approval_normalize_rule "$runtime" "$action" "$resource" "$effect")" || return 1
  runtime="$(printf '%s' "$normalized" | jq -r '.runtime')"
  action="$(printf '%s' "$normalized" | jq -r '.action')"
  resource="$(printf '%s' "$normalized" | jq -r '.resource')"
  effect="$(printf '%s' "$normalized" | jq -r '.effect')"

  if [[ -z "$created_at" ]]; then
    created_at="$(graph_approval_now_iso)"
  fi
  if ! graph_operator_is_iso_timestamp "$created_at"; then
    echo "Error: malformed approval rule createdAt: ${created_at:-<empty>}" >&2
    return 1
  fi

  confirm_json="$(graph_approval_project_confirm_lookup "$state_root" "$project_id" "$request_id" "$normalized")" || confirm_ec=$?
  if [[ "$confirm_ec" -eq 2 ]]; then
    return 1
  fi
  if [[ "$confirm_ec" -ne 0 ]]; then
    echo "Error: allow-always requires a second confirmation record tied to the original request" >&2
    return 1
  fi
  if [[ "$(printf '%s' "$confirm_json" | jq -r '.requestId')" != "$request_id" ]]; then
    echo "Error: approval confirmation requestId does not match the original request" >&2
    return 1
  fi

  record="$(jq -nc \
    --argjson schemaVersion "$GRAPH_APPROVAL_RULE_SCHEMA_VERSION" \
    --arg scope "project" \
    --arg decision "$decision" \
    --arg projectId "$project_id" \
    --arg projectRoot "$project_root" \
    --arg runtime "$runtime" \
    --arg action "$action" \
    --arg resource "$resource" \
    --arg effect "$effect" \
    --arg requestId "$request_id" \
    --arg createdAt "$created_at" \
    '{
      schemaVersion:$schemaVersion,
      scope:$scope,
      decision:$decision,
      projectId:$projectId,
      projectRoot:$projectRoot,
      runtime:$runtime,
      action:$action,
      resource:$resource,
      effect:$effect,
      requestId:$requestId,
      createdAt:$createdAt,
      revokedAt:null
    }')" || {
    echo "Error: failed to encode approval project rule" >&2
    return 1
  }

  GRAPH_APPROVAL_PROJECT_LOCK_STATE_ROOT="$state_root"
  GRAPH_APPROVAL_PROJECT_LOCK_PROJECT_ID="$project_id"
  GRAPH_APPROVAL_PROJECT_LOCK_PROJECT_ROOT="$project_root"
  GRAPH_APPROVAL_PROJECT_LOCK_RECORD="$record"
  GRAPH_APPROVAL_PROJECT_LOCK_NORMALIZED="$normalized"
  GRAPH_APPROVAL_PROJECT_LOCK_OP="write"
  graph_approval_project_locked_body() {
    local store_abs store_json existing next
    store_abs="$(graph_approval_project_policy_path "$GRAPH_APPROVAL_PROJECT_LOCK_STATE_ROOT")" || return 1
    if ! graph_logs_prepare_parent "$GRAPH_APPROVAL_PROJECT_LOCK_STATE_ROOT" "$(graph_approval_project_policy_rel)"; then
      echo "Error: approval policy path is not contained in the state-root" >&2
      return 1
    fi
    store_json="$(graph_approval_project_store_read "$store_abs")" || return 1
    existing="$(printf '%s' "$store_json" | jq -c --arg pid "$GRAPH_APPROVAL_PROJECT_LOCK_PROJECT_ID" --argjson key "$GRAPH_APPROVAL_PROJECT_LOCK_NORMALIZED" '
      ((.projects[$pid].rules // [])[]? | select(
        .runtime == $key.runtime
        and .action == $key.action
        and .resource == $key.resource
        and .effect == $key.effect
      )) // empty
    ')"
    if [[ -n "$existing" ]]; then
      if graph_approval_project_rule_active "$existing" \
        && [[ "$(printf '%s' "$existing" | jq -c '{decision,runtime,action,resource,effect,requestId}')" == \
              "$(printf '%s' "$GRAPH_APPROVAL_PROJECT_LOCK_RECORD" | jq -c '{decision,runtime,action,resource,effect,requestId}')" ]]; then
        printf '%s\n' "$store_abs"
        return 0
      fi
      if graph_approval_project_rule_active "$existing"; then
        echo "Error: approval project rule conflicts with an existing exact rule" >&2
        return 1
      fi
    fi
    next="$(printf '%s' "$store_json" | jq -c \
      --arg pid "$GRAPH_APPROVAL_PROJECT_LOCK_PROJECT_ID" \
      --arg proot "$GRAPH_APPROVAL_PROJECT_LOCK_PROJECT_ROOT" \
      --argjson rule "$GRAPH_APPROVAL_PROJECT_LOCK_RECORD" \
      --argjson key "$GRAPH_APPROVAL_PROJECT_LOCK_NORMALIZED" '
      .schemaVersion = 1
      | .projects = (.projects // {})
      | .projects[$pid] = (
          (.projects[$pid] // {projectRoot:$proot,rules:[]})
          | .projectRoot = $proot
          | .rules = (
              ((.rules // []) | map(select(
                .runtime != $key.runtime
                or .action != $key.action
                or .resource != $key.resource
                or .effect != $key.effect
              ))) + [$rule]
            )
        )
    ')" || {
      echo "Error: failed to update project approval store" >&2
      return 1
    }
    if ! ralph_atomic_write_json "$store_abs" '$store' --argjson store "$next"; then
      echo "Error: failed to write project approval store" >&2
      return 1
    fi
    printf '%s\n' "$store_abs"
  }
  write_ec=0
  graph_approval_project_with_lock "$state_root" || write_ec=$?
  unset GRAPH_APPROVAL_PROJECT_LOCK_STATE_ROOT GRAPH_APPROVAL_PROJECT_LOCK_PROJECT_ID
  unset GRAPH_APPROVAL_PROJECT_LOCK_PROJECT_ROOT GRAPH_APPROVAL_PROJECT_LOCK_RECORD
  unset GRAPH_APPROVAL_PROJECT_LOCK_NORMALIZED GRAPH_APPROVAL_PROJECT_LOCK_OP
  unset -f graph_approval_project_locked_body 2>/dev/null || true
  return "$write_ec"
}

# graph_approval_project_rule_revoke <state-root> <project-root> <runtime> <action> <resource> <effect>
# Marks the exact project rule revoked. Repeating the same revoke is
# idempotent. Prints the store path.
graph_approval_project_rule_revoke() {
  local state_root="$1" project_root="$2"
  local normalized project_id write_ec=0

  if [[ -z "$state_root" || -z "$project_root" ]]; then
    echo "Error: graph_approval_project_rule_revoke requires state-root and project-root" >&2
    return 1
  fi
  project_id="$(graph_approval_project_identity "$project_root")" || return 1
  project_root="$(graph_approval_project_canonical_root "$project_root")" || return 1
  normalized="$(graph_approval_normalize_rule "$3" "$4" "$5" "$6")" || return 1

  GRAPH_APPROVAL_PROJECT_LOCK_STATE_ROOT="$state_root"
  GRAPH_APPROVAL_PROJECT_LOCK_PROJECT_ID="$project_id"
  GRAPH_APPROVAL_PROJECT_LOCK_NORMALIZED="$normalized"
  GRAPH_APPROVAL_PROJECT_LOCK_REVOKED_AT="$(graph_approval_now_iso)"
  GRAPH_APPROVAL_PROJECT_LOCK_OP="revoke"
  graph_approval_project_locked_body() {
    local store_abs store_json existing next
    store_abs="$(graph_approval_project_policy_path "$GRAPH_APPROVAL_PROJECT_LOCK_STATE_ROOT")" || return 1
    store_json="$(graph_approval_project_store_read "$store_abs")" || return 1
    existing="$(printf '%s' "$store_json" | jq -c --arg pid "$GRAPH_APPROVAL_PROJECT_LOCK_PROJECT_ID" --argjson key "$GRAPH_APPROVAL_PROJECT_LOCK_NORMALIZED" '
      ((.projects[$pid].rules // [])[]? | select(
        .runtime == $key.runtime
        and .action == $key.action
        and .resource == $key.resource
        and .effect == $key.effect
      )) // empty
    ')"
    if [[ -z "$existing" ]]; then
      echo "Error: approval project rule not found" >&2
      return 1
    fi
    if ! graph_approval_project_rule_active "$existing"; then
      printf '%s\n' "$store_abs"
      return 0
    fi
    next="$(printf '%s' "$store_json" | jq -c \
      --arg pid "$GRAPH_APPROVAL_PROJECT_LOCK_PROJECT_ID" \
      --arg revokedAt "$GRAPH_APPROVAL_PROJECT_LOCK_REVOKED_AT" \
      --argjson key "$GRAPH_APPROVAL_PROJECT_LOCK_NORMALIZED" '
      .projects[$pid].rules |= map(
        if .runtime == $key.runtime
           and .action == $key.action
           and .resource == $key.resource
           and .effect == $key.effect
           and ((.revokedAt // null) == null)
        then .revokedAt = $revokedAt
        else . end
      )
    ')" || {
      echo "Error: failed to revoke project approval rule" >&2
      return 1
    }
    if ! ralph_atomic_write_json "$store_abs" '$store' --argjson store "$next"; then
      echo "Error: failed to write project approval store" >&2
      return 1
    fi
    printf '%s\n' "$store_abs"
  }
  graph_approval_project_with_lock "$state_root" || write_ec=$?
  unset GRAPH_APPROVAL_PROJECT_LOCK_STATE_ROOT GRAPH_APPROVAL_PROJECT_LOCK_PROJECT_ID
  unset GRAPH_APPROVAL_PROJECT_LOCK_NORMALIZED GRAPH_APPROVAL_PROJECT_LOCK_REVOKED_AT
  unset GRAPH_APPROVAL_PROJECT_LOCK_OP
  unset -f graph_approval_project_locked_body 2>/dev/null || true
  return "$write_ec"
}

# graph_approval_project_rule_list <state-root> <project-root>
# Prints a JSON array of stored project rules, including revoked ones.
# Missing store or project is []. Malformed store fails closed.
graph_approval_project_rule_list() {
  local state_root="$1" project_root="$2" project_id store_abs store_json
  if [[ -z "$state_root" || -z "$project_root" ]]; then
    echo "Error: graph_approval_project_rule_list requires state-root and project-root" >&2
    return 1
  fi
  if [[ ! -d "$state_root" ]]; then
    echo "Error: approval state-root is not a directory: $state_root" >&2
    return 1
  fi
  project_id="$(graph_approval_project_identity "$project_root")" || return 1
  store_abs="$(graph_approval_project_policy_path "$state_root")" || return 1
  store_json="$(graph_approval_project_store_read "$store_abs")" || return 1
  printf '%s' "$store_json" | jq -c --arg pid "$project_id" '
    (.projects[$pid].rules // [])
    | sort_by(.runtime,.action,.resource,.effect,.decision)
  '
}

# graph_approval_project_rule_lookup <state-root> <project-root> <normalized-json>
# Exit 0: prints the active exact rule.
# Exit 1: no active rule.
# Exit 2: store is unreadable or malformed.
graph_approval_project_rule_lookup() {
  local state_root="$1" project_root="$2" normalized="$3"
  local project_id store_abs store_json rule
  project_id="$(graph_approval_project_identity "$project_root")" || return 2
  store_abs="$(graph_approval_project_policy_path "$state_root")" || return 2
  store_json="$(graph_approval_project_store_read "$store_abs")" || return $?
  rule="$(printf '%s' "$store_json" | jq -c --arg pid "$project_id" --argjson key "$normalized" '
    ((.projects[$pid].rules // [])[]? | select(
      .runtime == $key.runtime
      and .action == $key.action
      and .resource == $key.resource
      and .effect == $key.effect
      and ((.revokedAt // null) == null)
      and .decision == "allow-always"
    )) // empty
  ')"
  if [[ -z "$rule" ]]; then
    return 1
  fi
  printf '%s\n' "$rule"
}

# graph_approval_resolve_roots <run-dir> <request-json>
# Discover state-root and project-root from request fields, then run.json.
graph_approval_resolve_roots() {
  local run_dir="$1" raw="$2"
  local state_root project_root run_file
  state_root="$(printf '%s' "$raw" | jq -r '(.stateRoot // .roots.stateRoot // "") | tostring')"
  project_root="$(printf '%s' "$raw" | jq -r '(.projectRoot // .roots.projectRoot // "") | tostring')"
  run_file="$run_dir/run.json"
  if [[ -f "$run_file" && ! -L "$run_file" ]] && jq -e 'type == "object"' "$run_file" >/dev/null 2>&1; then
    if [[ -z "$state_root" || "$state_root" == "null" ]]; then
      state_root="$(jq -r '.roots.stateRoot // empty' "$run_file")"
    fi
    if [[ -z "$project_root" || "$project_root" == "null" ]]; then
      project_root="$(jq -r '.roots.projectRoot // empty' "$run_file")"
    fi
  fi
  jq -nc --arg stateRoot "${state_root:-}" --arg projectRoot "${project_root:-}" \
    '{stateRoot:$stateRoot,projectRoot:$projectRoot}'
}

# graph_approval_resolve <run-dir> <request-json-or-path>
# Resolve a permission request against run-local policy, then project policy.
graph_approval_resolve() {
  local run_dir="$1" input="${2:-}"
  local raw runtime action resource effect request_id
  local normalized matched denial_source rule_json rule_decision lookup_ec
  local roots_json state_root project_root

  if [[ -z "$run_dir" ]]; then
    echo "Error: graph_approval_resolve requires a run-dir" >&2
    return 1
  fi
  if [[ ! -d "$run_dir" ]]; then
    echo "Error: approval run-dir is not a directory: $run_dir" >&2
    return 1
  fi
  command -v jq >/dev/null 2>&1 || {
    echo "Error: jq is required to resolve approval policy" >&2
    return 1
  }

  raw="$(graph_operator_load_json "$input")" || return 1
  if ! printf '%s' "$raw" | jq -e 'type == "object"' >/dev/null 2>&1; then
    echo "Error: approval request must be a JSON object" >&2
    return 1
  fi

  runtime="$(printf '%s' "$raw" | jq -r '.runtime // empty')"
  action="$(printf '%s' "$raw" | jq -r '.action // empty')"
  resource="$(printf '%s' "$raw" | jq -r '(.resource // .pattern // "") | tostring')"
  effect="$(printf '%s' "$raw" | jq -r '.effect // empty')"
  request_id="$(printf '%s' "$raw" | jq -r '.requestId // .id // empty')"

  normalized="$(graph_approval_normalize_rule "$runtime" "$action" "$resource" "$effect")" || return 1
  matched="$normalized"

  if denial_source="$(graph_approval_explicit_denial_source "$raw")"; then
    graph_approval_emit_resolution "deny" "${denial_source}-denial" "$matched"
    return 0
  fi

  lookup_ec=0
  rule_json="$(graph_approval_run_rule_lookup "$run_dir" "$normalized")" || lookup_ec=$?
  if [[ "$lookup_ec" -eq 2 ]]; then
    return 1
  fi
  if [[ "$lookup_ec" -eq 0 ]]; then
    rule_decision="$(printf '%s' "$rule_json" | jq -r '.decision // empty')"
    if [[ "$rule_decision" == "deny" ]]; then
      graph_approval_emit_resolution "deny" "ralph-deny" "$matched"
      return 0
    fi
  fi

  if graph_approval_allow_once_matches "$run_dir" "$request_id"; then
    graph_approval_emit_resolution "allow-once" "allow-once" "$matched"
    return 0
  fi

  if [[ "${rule_decision:-}" == "allow-run" ]]; then
    graph_approval_emit_resolution "allow-run" "run-rule" "$matched"
    return 0
  fi

  roots_json="$(graph_approval_resolve_roots "$run_dir" "$raw")"
  state_root="$(printf '%s' "$roots_json" | jq -r '.stateRoot // empty')"
  project_root="$(printf '%s' "$roots_json" | jq -r '.projectRoot // empty')"
  if [[ -n "$state_root" && -n "$project_root" && -d "$state_root" && -d "$project_root" ]]; then
    lookup_ec=0
    rule_json="$(graph_approval_project_rule_lookup "$state_root" "$project_root" "$normalized")" || lookup_ec=$?
    if [[ "$lookup_ec" -eq 2 ]]; then
      return 1
    fi
    if [[ "$lookup_ec" -eq 0 ]]; then
      graph_approval_emit_resolution "allow-always" "project-rule" "$matched"
      return 0
    fi
  fi

  graph_approval_emit_resolution "ask" "none" "null"
}
