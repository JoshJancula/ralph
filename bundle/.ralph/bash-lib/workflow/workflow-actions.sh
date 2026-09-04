#!/usr/bin/env bash
# Common workflow action request, decision, and consumption records.
#
# Layout under a registry run directory:
#   actions/requests/<request-id>.json
#   actions/decisions/<request-id>.json
#   actions/consumed/<request-id>.json
#   actions/injections/<request-id>.md  (answered-input prompt staging; create-once)
#   actions/capabilities/   (ephemeral; never written by this module)
#
# Version-1 kinds: permission | approval | input
# Identity tuple: runId + stageId + attemptId (plus runtime/nonce for permission).
# Containment, create-once writes, nonce mint/validate, and request-id safety
# wrap graph-operator-records.sh primitives. Graph permission records under
# operator/ remain the internal graph compatibility surface.

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  echo "This file is meant to be sourced, not executed." >&2
  exit 1
fi

if [[ -n "${RALPH_WORKFLOW_ACTIONS_LOADED:-}" ]]; then
  return 0
fi
RALPH_WORKFLOW_ACTIONS_LOADED=1

_WORKFLOW_ACTIONS_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if ! declare -F graph_operator_create_once_write >/dev/null 2>&1; then
  # shellcheck source=../graph/graph-operator-records.sh
  source "$_WORKFLOW_ACTIONS_SCRIPT_DIR/../graph/graph-operator-records.sh"
fi

# shellcheck source=./workflow-action-continuation.sh
source "$_WORKFLOW_ACTIONS_SCRIPT_DIR/workflow-action-continuation.sh"

WORKFLOW_ACTION_SCHEMA_VERSION=1
WORKFLOW_ACTION_TEXT_MAX="${WORKFLOW_ACTION_TEXT_MAX:-2000}"
WORKFLOW_ACTION_SCHEMA_PATH="${WORKFLOW_ACTION_SCHEMA_PATH:-$_WORKFLOW_ACTIONS_SCRIPT_DIR/../../schemas/workflow-action.schema.json}"
WORKFLOW_ACTION_ARTIFACT_SCHEMA_PY="${WORKFLOW_ACTION_ARTIFACT_SCHEMA_PY:-$_WORKFLOW_ACTIONS_SCRIPT_DIR/../../python/artifact_json_schema.py}"

WORKFLOW_ACTION_KINDS='permission
approval
input'

WORKFLOW_ACTION_PERMISSION_CHOICES='allow-once
allow-run
allow-always
deny'

WORKFLOW_ACTION_APPROVAL_CHOICES='approve
request-changes
cancel'

WORKFLOW_ACTION_INPUT_CHOICES='answer
cancel'

WORKFLOW_ACTION_ACTOR_SOURCES='cli
tui
human
adapter
test'

WORKFLOW_ACTION_CONSUMERS='resume
reset
stage
test'

WORKFLOW_ACTION_CREDENTIAL_GUIDANCE='configure a named environment or native secret source and reply when ready; do not embed secret literals'

# workflow_action_now_iso
# Honors WORKFLOW_ACTION_NOW, then GRAPH_OPERATOR_NOW, then UTC clock.
workflow_action_now_iso() {
  if [[ -n "${WORKFLOW_ACTION_NOW:-}" ]]; then
    printf '%s\n' "$WORKFLOW_ACTION_NOW"
    return 0
  fi
  graph_operator_now_iso
}

# workflow_action_schema_extract <record-type>
# Prints the named sub-schema (request|decision|consumed) as JSON.
workflow_action_schema_extract() {
  local record_type="${1:-}"
  local schema_path="${WORKFLOW_ACTION_SCHEMA_PATH}"
  case "$record_type" in
    request|decision|consumed) ;;
    *)
      echo "Error: workflow action schema record type must be request|decision|consumed" >&2
      return 1
      ;;
  esac
  if [[ ! -f "$schema_path" ]]; then
    echo "Error: workflow action schema not found: $schema_path" >&2
    return 1
  fi
  command -v jq >/dev/null 2>&1 || {
    echo "Error: jq is required to load the workflow action schema" >&2
    return 1
  }
  if ! jq -e --arg k "$record_type" '.[$k] | type == "object"' "$schema_path" >/dev/null 2>&1; then
    echo "Error: workflow action schema missing $record_type object" >&2
    return 1
  fi
  jq -c --arg k "$record_type" '.[$k]' "$schema_path"
}

# workflow_action_validate_against_schema <record-type> <json-or-path>
workflow_action_validate_against_schema() {
  local record_type="$1" input="${2:-}"
  local raw schema_json tmp_schema tmp_artifact py
  command -v python3 >/dev/null 2>&1 || {
    echo "Error: python3 is required to validate workflow action records" >&2
    return 1
  }
  py="${WORKFLOW_ACTION_ARTIFACT_SCHEMA_PY}"
  if [[ ! -f "$py" ]]; then
    echo "Error: artifact schema validator not found: $py" >&2
    return 1
  fi
  raw="$(graph_operator_load_json "$input")" || return 1
  schema_json="$(workflow_action_schema_extract "$record_type")" || return 1
  tmp_schema="$(mktemp)" || return 1
  tmp_artifact="$(mktemp)" || {
    rm -f "$tmp_schema"
    return 1
  }
  printf '%s\n' "$schema_json" >"$tmp_schema"
  printf '%s\n' "$raw" >"$tmp_artifact"
  if ! python3 "$py" validate-final-output --schema "$tmp_schema" --artifact "$tmp_artifact" 2>/dev/null; then
    rm -f "$tmp_schema" "$tmp_artifact"
    echo "Error: workflow action $record_type failed schema validation" >&2
    return 1
  fi
  rm -f "$tmp_schema" "$tmp_artifact"
  return 0
}

# workflow_action_choices_for_kind <kind>
workflow_action_choices_for_kind() {
  case "${1:-}" in
    permission) printf '%s\n' "$WORKFLOW_ACTION_PERMISSION_CHOICES" ;;
    approval) printf '%s\n' "$WORKFLOW_ACTION_APPROVAL_CHOICES" ;;
    input) printf '%s\n' "$WORKFLOW_ACTION_INPUT_CHOICES" ;;
    *)
      echo "Error: unknown workflow action kind: ${1:-<empty>}" >&2
      return 1
      ;;
  esac
}

# workflow_action_decision_requires_message <kind> <decision>
workflow_action_decision_requires_message() {
  local kind="${1:-}" decision="${2:-}"
  case "$kind:$decision" in
    approval:request-changes|input:answer) return 0 ;;
    *) return 1 ;;
  esac
}

# workflow_action_reject_credentials <field> <text>
# Fail closed on credential-looking literals. Display redaction is not enough.
workflow_action_reject_credentials() {
  local field="${1:-field}" text="${2:-}"
  if graph_operator_text_looks_like_credential "$text"; then
    echo "Error: credential-looking value rejected in ${field}; ${WORKFLOW_ACTION_CREDENTIAL_GUIDANCE}" >&2
    return 1
  fi
  return 0
}

# workflow_action_bound_text <field> <text> [allow-empty=0]
# Normalize whitespace, reject credentials, enforce WORKFLOW_ACTION_TEXT_MAX.
# Prints the bounded text. Empty is refused unless allow-empty=1.
# Optional display redaction via graph_operator_bound_reason is defense in depth
# only; credential literals are already rejected above.
workflow_action_bound_text() {
  local field="${1:-field}" text="${2:-}" allow_empty="${3:-0}" max="${WORKFLOW_ACTION_TEXT_MAX:-2000}"
  local prev_max redacted
  if [[ ! "$max" =~ ^[0-9]+$ ]] || [[ "$max" -lt 1 ]]; then
    max=2000
  fi
  text="$(printf '%s' "$text" | tr '\n\r\t' ' ' | tr -s ' ')"
  text="${text# }"
  text="${text% }"
  if [[ -z "$text" ]]; then
    if [[ "$allow_empty" == "1" ]]; then
      printf '\n'
      return 0
    fi
    echo "Error: workflow action ${field} must be non-empty" >&2
    return 1
  fi
  workflow_action_reject_credentials "$field" "$text" || return 1
  if [[ "${#text}" -gt "$max" ]]; then
    echo "Error: workflow action ${field} exceeds max length ${max}" >&2
    return 1
  fi
  prev_max="${GRAPH_OPERATOR_REASON_MAX:-}"
  GRAPH_OPERATOR_REASON_MAX="$max"
  redacted="$(graph_operator_bound_reason "$text")"
  if [[ -n "$prev_max" ]]; then
    GRAPH_OPERATOR_REASON_MAX="$prev_max"
  else
    unset GRAPH_OPERATOR_REASON_MAX
  fi
  printf '%s\n' "$redacted"
}

# workflow_action_validate_choices <kind> <choices-json>
workflow_action_validate_choices() {
  local kind="$1" choices_json="$2" expected item count i
  expected="$(workflow_action_choices_for_kind "$kind")" || return 1
  if ! printf '%s' "$choices_json" | jq -e 'type == "array" and length > 0' >/dev/null 2>&1; then
    echo "Error: workflow action choices must be a non-empty array" >&2
    return 1
  fi
  count="$(printf '%s' "$choices_json" | jq 'length')"
  i=0
  while [[ "$i" -lt "$count" ]]; do
    item="$(printf '%s' "$choices_json" | jq -r --argjson i "$i" '.[$i] | tostring')"
    if ! graph_operator_token_in_list "$item" "$expected"; then
      echo "Error: malformed workflow action choice for kind ${kind}: $item" >&2
      return 1
    fi
    i=$((i + 1))
  done
  # Exact set required (order may vary); reject missing required choices.
  while IFS= read -r item; do
    [[ -n "$item" ]] || continue
    if ! printf '%s' "$choices_json" | jq -e --arg c "$item" 'index($c) != null' >/dev/null 2>&1; then
      echo "Error: workflow action choices for kind ${kind} missing required choice: $item" >&2
      return 1
    fi
  done <<< "$expected"
  # Canonical order for stable fingerprints.
  case "$kind" in
    permission) printf '%s' '["allow-once","allow-run","allow-always","deny"]' ;;
    approval) printf '%s' '["approve","request-changes","cancel"]' ;;
    input) printf '%s' '["answer","cancel"]' ;;
  esac
}

# workflow_action_request_rel <request-id>
workflow_action_request_rel() {
  local request_id="$1"
  graph_operator_request_id_valid "$request_id" || return 1
  printf 'actions/requests/%s.json\n' "$request_id"
}

# workflow_action_decision_rel <request-id>
workflow_action_decision_rel() {
  local request_id="$1"
  graph_operator_request_id_valid "$request_id" || return 1
  printf 'actions/decisions/%s.json\n' "$request_id"
}

# workflow_action_consumed_rel <request-id>
workflow_action_consumed_rel() {
  local request_id="$1"
  graph_operator_request_id_valid "$request_id" || return 1
  printf 'actions/consumed/%s.json\n' "$request_id"
}

# workflow_action_resolve_path <registry-run> <rel>
workflow_action_resolve_path() {
  local run_dir="$1" rel="$2"
  if [[ -z "$run_dir" || -z "$rel" ]]; then
    echo "Error: workflow_action_resolve_path requires registry-run and relative path" >&2
    return 1
  fi
  graph_logs_resolve "$run_dir" "$rel"
}

# workflow_action_request_path <registry-run> <request-id>
workflow_action_request_path() {
  local run_dir="$1" request_id="$2" rel
  rel="$(workflow_action_request_rel "$request_id")" || return 1
  workflow_action_resolve_path "$run_dir" "$rel"
}

# workflow_action_decision_path <registry-run> <request-id>
workflow_action_decision_path() {
  local run_dir="$1" request_id="$2" rel
  rel="$(workflow_action_decision_rel "$request_id")" || return 1
  workflow_action_resolve_path "$run_dir" "$rel"
}

# workflow_action_consumed_path <registry-run> <request-id>
workflow_action_consumed_path() {
  local run_dir="$1" request_id="$2" rel
  rel="$(workflow_action_consumed_rel "$request_id")" || return 1
  workflow_action_resolve_path "$run_dir" "$rel"
}

# workflow_action_prepare_write <registry-run> <rel> <expected-suffix>
# Ensures parent dirs, refuses symlink leaves, confirms containment suffix.
workflow_action_prepare_write() {
  local run_dir="$1" rel="$2" expected_suffix="$3" abs
  if ! graph_logs_prepare_parent "$run_dir" "$rel"; then
    echo "Error: workflow action path is not contained in the registry run" >&2
    return 1
  fi
  abs="$(graph_logs_resolve "$run_dir" "$rel")" || return 1
  if [[ -L "$abs" ]]; then
    echo "Error: refusing to write through a workflow action symlink: $rel" >&2
    return 1
  fi
  if [[ "$abs" != *"/$expected_suffix" ]]; then
    echo "Error: workflow action path escaped expected suffix ${expected_suffix}: $abs" >&2
    return 1
  fi
  printf '%s\n' "$abs"
}

# workflow_action_redact_for_display <text>
# Defense-in-depth display helper; never used to authorize storing secrets.
workflow_action_redact_for_display() {
  local text="${1:-}" prev_max
  prev_max="${GRAPH_OPERATOR_REASON_MAX:-}"
  GRAPH_OPERATOR_REASON_MAX="${WORKFLOW_ACTION_TEXT_MAX:-2000}"
  graph_operator_bound_reason "$text"
  if [[ -n "$prev_max" ]]; then
    GRAPH_OPERATOR_REASON_MAX="$prev_max"
  else
    unset GRAPH_OPERATOR_REASON_MAX
  fi
}

# workflow_action_request_write <registry-run> <request-json-or-path>
# Create-once persist a common action request. Prints absolute path.
workflow_action_request_write() {
  local run_dir="$1" input="${2:-}"
  local raw extracted kind request_id run_id stage_id attempt_id choices_json
  local question details evidence_json changes_target created_at expires_at
  local nonce runtime namespace action resource effect classification session_id
  local schema_version rel abs record default_choices
  local ev_count ev_i ev_path ev_sha

  if [[ -z "$run_dir" ]]; then
    echo "Error: workflow_action_request_write requires a registry-run directory" >&2
    return 1
  fi
  if [[ ! -d "$run_dir" ]]; then
    echo "Error: workflow action registry-run is not a directory: $run_dir" >&2
    return 1
  fi
  command -v jq >/dev/null 2>&1 || {
    echo "Error: jq is required to write a workflow action request" >&2
    return 1
  }

  raw="$(graph_operator_load_json "$input")" || return 1
  if ! printf '%s' "$raw" | jq -e 'type == "object"' >/dev/null 2>&1; then
    echo "Error: workflow action request must be a JSON object" >&2
    return 1
  fi
  if printf '%s' "$raw" | jq -e 'keys_unsorted | map(select(startswith("_"))) | length > 0' >/dev/null 2>&1; then
    :
  fi

  extracted="$(printf '%s' "$raw" | jq -c '
    {
      schemaVersion: (.schemaVersion // 1),
      requestId: ((.requestId // .id // "") | tostring),
      kind: ((.kind // "") | tostring),
      runId: ((.runId // "") | tostring),
      stageId: ((.stageId // .nodeId // "") | tostring),
      attemptId: ((.attemptId // "") | tostring),
      choices: (if (.choices | type) == "array" then .choices else null end),
      question: ((.question // .reason // "") | tostring),
      details: (if (.details | type) == "null" then null
                elif (.details | type) == "string" then .details
                elif (.details // null) == null then null
                else (.details | tostring) end),
      evidence: (if (.evidence | type) == "array" then .evidence else [] end),
      changesTarget: (if (.changesTarget // null) == null then null else (.changesTarget | tostring) end),
      createdAt: ((.createdAt // "") | tostring),
      expiresAt: (if (.expiresAt // .expiry // null) == null then null else ((.expiresAt // .expiry) | tostring) end),
      nonce: (if (.nonce // null) == null then null else (.nonce | tostring) end),
      runtime: (if (.runtime // null) == null then null else (.runtime | tostring) end),
      namespace: (if (.namespace // null) == null then null else (.namespace | tostring) end),
      action: (if (.action // .tool // null) == null then null else ((.action // .tool) | tostring) end),
      resource: (if (.resource // null) == null then null else (.resource | tostring) end),
      effect: (if (.effect // null) == null then null else (.effect | tostring) end),
      classification: (if (.classification // null) == null then null else (.classification | tostring) end),
      sessionId: (if (.sessionId // null) == null then null else (.sessionId | tostring) end)
    }
  ' 2>/dev/null)" || extracted=""

  if [[ -z "$extracted" ]]; then
    echo "Error: workflow action request JSON could not be parsed" >&2
    return 1
  fi

  schema_version="$(printf '%s' "$extracted" | jq -r '.schemaVersion | tostring')"
  request_id="$(printf '%s' "$extracted" | jq -r '.requestId')"
  kind="$(printf '%s' "$extracted" | jq -r '.kind')"
  run_id="$(printf '%s' "$extracted" | jq -r '.runId')"
  stage_id="$(printf '%s' "$extracted" | jq -r '.stageId')"
  attempt_id="$(printf '%s' "$extracted" | jq -r '.attemptId')"
  choices_json="$(printf '%s' "$extracted" | jq -c '.choices')"
  question="$(printf '%s' "$extracted" | jq -r '.question')"
  details="$(printf '%s' "$extracted" | jq -r 'if .details == null then empty else .details end')"
  evidence_json="$(printf '%s' "$extracted" | jq -c '.evidence')"
  changes_target="$(printf '%s' "$extracted" | jq -r 'if .changesTarget == null then empty else .changesTarget end')"
  created_at="$(printf '%s' "$extracted" | jq -r '.createdAt')"
  expires_at="$(printf '%s' "$extracted" | jq -r 'if .expiresAt == null then empty else .expiresAt end')"
  nonce="$(printf '%s' "$extracted" | jq -r 'if .nonce == null then empty else .nonce end')"
  runtime="$(printf '%s' "$extracted" | jq -r 'if .runtime == null then empty else .runtime end')"
  namespace="$(printf '%s' "$extracted" | jq -r 'if .namespace == null then empty else .namespace end')"
  action="$(printf '%s' "$extracted" | jq -r 'if .action == null then empty else .action end')"
  resource="$(printf '%s' "$extracted" | jq -r 'if .resource == null then empty else .resource end')"
  effect="$(printf '%s' "$extracted" | jq -r 'if .effect == null then empty else .effect end')"
  classification="$(printf '%s' "$extracted" | jq -r 'if .classification == null then empty else .classification end')"
  session_id="$(printf '%s' "$extracted" | jq -r 'if .sessionId == null then empty else .sessionId end')"

  if [[ "$schema_version" != "$WORKFLOW_ACTION_SCHEMA_VERSION" ]]; then
    echo "Error: unsupported workflow action request schemaVersion: $schema_version" >&2
    return 1
  fi
  if ! graph_operator_token_in_list "$kind" "$WORKFLOW_ACTION_KINDS"; then
    echo "Error: malformed workflow action kind: ${kind:-<empty>}" >&2
    return 1
  fi
  graph_operator_request_id_valid "$request_id" || return 1
  if [[ -z "$run_id" || -z "$stage_id" || -z "$attempt_id" ]]; then
    echo "Error: workflow action identity requires runId, stageId, and attemptId" >&2
    return 1
  fi
  if [[ "$choices_json" == "null" ]]; then
    default_choices="$(workflow_action_choices_for_kind "$kind" | jq -R . | jq -s -c '.')"
    choices_json="$default_choices"
  fi
  choices_json="$(workflow_action_validate_choices "$kind" "$choices_json")" || return 1

  if [[ -z "$created_at" ]]; then
    created_at="$(workflow_action_now_iso)"
  fi
  if ! graph_operator_is_iso_timestamp "$created_at"; then
    echo "Error: malformed workflow action request createdAt: ${created_at:-<empty>}" >&2
    return 1
  fi

  case "$kind" in
    permission)
      if [[ -z "$action" || -z "$resource" || -z "$effect" || -z "$runtime" ]]; then
        echo "Error: permission request requires action, resource, effect, and runtime" >&2
        return 1
      fi
      if graph_logs_has_dotdot "$resource"; then
        echo "Error: permission request resource may not contain '..'" >&2
        return 1
      fi
      if ! graph_operator_token_in_list "$effect" "$GRAPH_OPERATOR_EFFECTS"; then
        echo "Error: malformed permission request effect: $effect" >&2
        return 1
      fi
      if ! graph_operator_token_in_list "$runtime" "$GRAPH_OPERATOR_RUNTIMES"; then
        echo "Error: malformed permission request runtime: $runtime" >&2
        return 1
      fi
      if [[ -z "$nonce" ]]; then
        nonce="$(graph_operator_mint_nonce)" || return 1
      fi
      graph_operator_nonce_valid "$nonce" || return 1
      if [[ -z "$expires_at" ]]; then
        echo "Error: permission request expiry is required" >&2
        return 1
      fi
      if ! graph_operator_is_iso_timestamp "$expires_at"; then
        echo "Error: malformed permission request expiry: $expires_at" >&2
        return 1
      fi
      question="$(workflow_action_bound_text "question" "$question" 1)" || return 1
      if [[ -z "$question" ]]; then
        question="permission request"
      else
        # Re-check after bound (already rejected credentials).
        :
      fi
      details=""
      evidence_json='[]'
      changes_target=""
      ;;
    approval)
      question="$(workflow_action_bound_text "question" "$question")" || return 1
      if [[ -z "$changes_target" ]]; then
        echo "Error: approval request requires changesTarget" >&2
        return 1
      fi
      if graph_logs_has_dotdot "$changes_target"; then
        echo "Error: approval changesTarget may not contain '..'" >&2
        return 1
      fi
      if ! printf '%s' "$evidence_json" | jq -e 'type == "array"' >/dev/null 2>&1; then
        echo "Error: approval request evidence must be an array" >&2
        return 1
      fi
      # Bound evidence paths; reject traversal and credentials in path strings.
      evidence_json="$(printf '%s' "$evidence_json" | jq -c '
        map(
          if type == "object" then
            {
              path: ((.path // "") | tostring),
              sha256: (if (.sha256 // null) == null then null else (.sha256 | tostring) end)
            }
          elif type == "string" then
            {path: ., sha256: null}
          else
            empty
          end
        )
      ')" || {
        echo "Error: approval evidence could not be normalized" >&2
        return 1
      }
      ev_count="$(printf '%s' "$evidence_json" | jq 'length')"
      ev_i=0
      while [[ "$ev_i" -lt "$ev_count" ]]; do
        ev_path="$(printf '%s' "$evidence_json" | jq -r --argjson i "$ev_i" '.[$i].path')"
        ev_sha="$(printf '%s' "$evidence_json" | jq -r --argjson i "$ev_i" 'if .[$i].sha256 == null then empty else .[$i].sha256 end')"
        if [[ -z "$ev_path" ]]; then
          echo "Error: approval evidence path must be non-empty" >&2
          return 1
        fi
        if graph_logs_has_dotdot "$ev_path"; then
          echo "Error: approval evidence path may not contain '..'" >&2
          return 1
        fi
        workflow_action_reject_credentials "evidence.path" "$ev_path" || return 1
        if [[ -n "$ev_sha" && ! "$ev_sha" =~ ^[a-f0-9]{64}$ ]]; then
          echo "Error: approval evidence sha256 must be 64 lowercase hex chars" >&2
          return 1
        fi
        ev_i=$((ev_i + 1))
      done
      details=""
      nonce=""
      runtime=""
      namespace=""
      action=""
      resource=""
      effect=""
      classification=""
      session_id=""
      expires_at=""
      ;;
    input)
      question="$(workflow_action_bound_text "question" "$question")" || return 1
      if [[ -n "$details" ]]; then
        details="$(workflow_action_bound_text "details" "$details")" || return 1
      else
        details=""
      fi
      # Input capability nonce is attempt-bound and must never be persisted.
      if [[ -n "$nonce" ]]; then
        echo "Error: input request must not persist a nonce in request JSON" >&2
        return 1
      fi
      evidence_json='[]'
      changes_target=""
      runtime=""
      namespace=""
      action=""
      resource=""
      effect=""
      classification=""
      session_id=""
      expires_at=""
      ;;
  esac

  # Build record with only applicable keys (no unknown keys).
  case "$kind" in
    permission)
      record="$(jq -nc \
        --argjson schemaVersion "$WORKFLOW_ACTION_SCHEMA_VERSION" \
        --arg requestId "$request_id" \
        --arg kind "$kind" \
        --arg runId "$run_id" \
        --arg stageId "$stage_id" \
        --arg attemptId "$attempt_id" \
        --argjson choices "$choices_json" \
        --arg createdAt "$created_at" \
        --arg question "$question" \
        --arg expiresAt "$expires_at" \
        --arg nonce "$nonce" \
        --arg runtime "$runtime" \
        --arg namespace "${namespace}" \
        --arg action "$action" \
        --arg resource "$resource" \
        --arg effect "$effect" \
        --arg classification "${classification}" \
        --arg sessionId "${session_id}" \
        '{
          schemaVersion:$schemaVersion,
          requestId:$requestId,
          kind:$kind,
          runId:$runId,
          stageId:$stageId,
          attemptId:$attemptId,
          choices:$choices,
          createdAt:$createdAt,
          question:$question,
          expiresAt:$expiresAt,
          nonce:$nonce,
          runtime:$runtime,
          action:$action,
          resource:$resource,
          effect:$effect
        }
        + (if $namespace == "" then {} else {namespace:$namespace} end)
        + (if $classification == "" then {} else {classification:$classification} end)
        + (if $sessionId == "" then {} else {sessionId:$sessionId} end)
      ')" || {
        echo "Error: failed to encode permission request record" >&2
        return 1
      }
      ;;
    approval)
      record="$(jq -nc \
        --argjson schemaVersion "$WORKFLOW_ACTION_SCHEMA_VERSION" \
        --arg requestId "$request_id" \
        --arg kind "$kind" \
        --arg runId "$run_id" \
        --arg stageId "$stage_id" \
        --arg attemptId "$attempt_id" \
        --argjson choices "$choices_json" \
        --arg createdAt "$created_at" \
        --arg question "$question" \
        --argjson evidence "$evidence_json" \
        --arg changesTarget "$changes_target" \
        '{
          schemaVersion:$schemaVersion,
          requestId:$requestId,
          kind:$kind,
          runId:$runId,
          stageId:$stageId,
          attemptId:$attemptId,
          choices:$choices,
          createdAt:$createdAt,
          question:$question,
          evidence:$evidence,
          changesTarget:$changesTarget
        }')" || {
        echo "Error: failed to encode approval request record" >&2
        return 1
      }
      ;;
    input)
      local continuation_identity=""
      if continuation_identity="$(printf '%s' "$raw" | jq -c '.continuationIdentity // empty' 2>/dev/null)"; then
        :
      fi
      if [[ -z "$continuation_identity" || "$continuation_identity" == "null" ]]; then
        if declare -F workflow_action_continuation_build >/dev/null 2>&1; then
          continuation_identity="$(workflow_action_continuation_build 2>/dev/null || true)"
        fi
      fi
      if [[ -n "$details" ]]; then
        record="$(jq -nc \
          --argjson schemaVersion "$WORKFLOW_ACTION_SCHEMA_VERSION" \
          --arg requestId "$request_id" \
          --arg kind "$kind" \
          --arg runId "$run_id" \
          --arg stageId "$stage_id" \
          --arg attemptId "$attempt_id" \
          --argjson choices "$choices_json" \
          --arg createdAt "$created_at" \
          --arg question "$question" \
          --arg details "$details" \
          --argjson continuationIdentity "${continuation_identity:-null}" \
          '{
            schemaVersion:$schemaVersion,
            requestId:$requestId,
            kind:$kind,
            runId:$runId,
            stageId:$stageId,
            attemptId:$attemptId,
            choices:$choices,
            createdAt:$createdAt,
            question:$question,
            details:$details
          } + (if $continuationIdentity == null then {} else {continuationIdentity:$continuationIdentity} end)')" || {
          echo "Error: failed to encode input request record" >&2
          return 1
        }
      else
        record="$(jq -nc \
          --argjson schemaVersion "$WORKFLOW_ACTION_SCHEMA_VERSION" \
          --arg requestId "$request_id" \
          --arg kind "$kind" \
          --arg runId "$run_id" \
          --arg stageId "$stage_id" \
          --arg attemptId "$attempt_id" \
          --argjson choices "$choices_json" \
          --arg createdAt "$created_at" \
          --arg question "$question" \
          --argjson continuationIdentity "${continuation_identity:-null}" \
          '{
            schemaVersion:$schemaVersion,
            requestId:$requestId,
            kind:$kind,
            runId:$runId,
            stageId:$stageId,
            attemptId:$attemptId,
            choices:$choices,
            createdAt:$createdAt,
            question:$question,
            details:null
          } + (if $continuationIdentity == null then {} else {continuationIdentity:$continuationIdentity} end)')" || {
          echo "Error: failed to encode input request record" >&2
          return 1
        }
      fi
      if [[ -n "$continuation_identity" && "$continuation_identity" != "null" ]] \
        && declare -F workflow_action_continuation_persist >/dev/null 2>&1; then
        workflow_action_continuation_persist "$continuation_identity" "operator-input-request" >/dev/null 2>&1 || true
      fi
      ;;
  esac

  # Shape is enforced by kind-specific construction above; schema validation is
  # available via workflow_action_validate_against_schema for callers/tests.

  rel="$(workflow_action_request_rel "$request_id")" || return 1
  abs="$(workflow_action_prepare_write "$run_dir" "$rel" "actions/requests/${request_id}.json")" || return 1
  graph_operator_create_once_write "$abs" "$record" || return 1
  abs="$(graph_logs_resolve "$run_dir" "$rel")" || return 1
  if [[ -L "$abs" ]]; then
    echo "Error: workflow action request path became a symlink after write: $rel" >&2
    return 1
  fi
  printf '%s\n' "$abs"
}

# workflow_action_request_read <registry-run> <request-id>
workflow_action_request_read() {
  local run_dir="$1" request_id="$2" abs
  abs="$(workflow_action_request_path "$run_dir" "$request_id")" || return 1
  if [[ ! -f "$abs" || -L "$abs" ]]; then
    echo "Error: workflow action request not found: $request_id" >&2
    return 1
  fi
  if ! jq -e 'type == "object"' "$abs" >/dev/null 2>&1; then
    echo "Error: workflow action request is not valid JSON: $abs" >&2
    return 1
  fi
  jq -c '.' "$abs"
}

# workflow_action_decision_fingerprint <decision-json>
workflow_action_decision_fingerprint() {
  local json="$1"
  printf '%s' "$json" | jq -c '{
    requestId: (.requestId // ""),
    kind: (.kind // ""),
    runId: (.runId // ""),
    stageId: (.stageId // ""),
    attemptId: (.attemptId // ""),
    decision: (.decision // ""),
    message: (.message // null),
    nonce: (.nonce // null),
    runtime: (.runtime // null),
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

# workflow_action_decision_accept_existing <abs> <record>
workflow_action_decision_accept_existing() {
  local abs="$1" record="$2" existing existing_fp new_fp
  if [[ -L "$abs" ]]; then
    echo "Error: refusing to read a workflow action decision symlink: $abs" >&2
    return 1
  fi
  if [[ ! -f "$abs" ]]; then
    echo "Error: workflow action decision record not found" >&2
    return 1
  fi
  existing="$(jq -c '.' "$abs")"
  existing_fp="$(workflow_action_decision_fingerprint "$existing")" || return 1
  new_fp="$(workflow_action_decision_fingerprint "$record")" || return 1
  if [[ "$existing_fp" == "$new_fp" ]]; then
    printf '%s\n' "$abs"
    return 0
  fi
  echo "Error: workflow action decision conflicts with an already resolved request" >&2
  return 1
}

# workflow_action_decision_write <registry-run> <decision-json-or-path>
# Create-once persist; identical replay succeeds; conflicting decision fails.
workflow_action_decision_write() {
  local run_dir="$1" input="${2:-}"
  local raw extracted request_id kind run_id stage_id attempt_id decision
  local message actor_source decided_at nonce runtime granted_json schema_version
  local request_json req_kind req_run req_stage req_attempt req_choices req_nonce
  local req_runtime req_action req_resource req_effect req_expires
  local grant_action grant_resource grant_effect
  local rel abs record write_ec now

  if [[ -z "$run_dir" || ! -d "$run_dir" ]]; then
    echo "Error: workflow_action_decision_write requires a registry-run directory" >&2
    return 1
  fi
  command -v jq >/dev/null 2>&1 || {
    echo "Error: jq is required to write a workflow action decision" >&2
    return 1
  }

  raw="$(graph_operator_load_json "$input")" || return 1
  extracted="$(printf '%s' "$raw" | jq -c '
    {
      schemaVersion: (.schemaVersion // 1),
      requestId: ((.requestId // .id // "") | tostring),
      kind: ((.kind // "") | tostring),
      runId: ((.runId // "") | tostring),
      stageId: ((.stageId // .nodeId // "") | tostring),
      attemptId: ((.attemptId // "") | tostring),
      decision: ((.decision // .choice // "") | tostring),
      message: (if (.message // null) == null then null
               elif (.message | type) == "string" then .message
               else (.message | tostring) end),
      actorSource: ((.actorSource // .actor // "human") | tostring),
      decidedAt: ((.decidedAt // "") | tostring),
      nonce: (if (.nonce // null) == null then null else (.nonce | tostring) end),
      runtime: (if (.runtime // null) == null then null else (.runtime | tostring) end),
      granted: (
        if (.granted | type) == "object" then .granted
        elif (.grantedRule | type) == "object" then .grantedRule
        elif (.grant | type) == "object" then .grant
        else null end
      )
    }
  ' 2>/dev/null)" || extracted=""

  if [[ -z "$extracted" ]]; then
    echo "Error: workflow action decision JSON could not be parsed" >&2
    return 1
  fi

  schema_version="$(printf '%s' "$extracted" | jq -r '.schemaVersion | tostring')"
  request_id="$(printf '%s' "$extracted" | jq -r '.requestId')"
  kind="$(printf '%s' "$extracted" | jq -r '.kind')"
  run_id="$(printf '%s' "$extracted" | jq -r '.runId')"
  stage_id="$(printf '%s' "$extracted" | jq -r '.stageId')"
  attempt_id="$(printf '%s' "$extracted" | jq -r '.attemptId')"
  decision="$(printf '%s' "$extracted" | jq -r '.decision')"
  message="$(printf '%s' "$extracted" | jq -r 'if .message == null then empty else .message end')"
  actor_source="$(printf '%s' "$extracted" | jq -r '.actorSource')"
  decided_at="$(printf '%s' "$extracted" | jq -r '.decidedAt')"
  nonce="$(printf '%s' "$extracted" | jq -r 'if .nonce == null then empty else .nonce end')"
  runtime="$(printf '%s' "$extracted" | jq -r 'if .runtime == null then empty else .runtime end')"
  granted_json="$(printf '%s' "$extracted" | jq -c '.granted')"

  if [[ "$schema_version" != "$WORKFLOW_ACTION_SCHEMA_VERSION" ]]; then
    echo "Error: unsupported workflow action decision schemaVersion: $schema_version" >&2
    return 1
  fi
  graph_operator_request_id_valid "$request_id" || return 1
  if ! graph_operator_token_in_list "$actor_source" "$WORKFLOW_ACTION_ACTOR_SOURCES"; then
    echo "Error: malformed workflow action actorSource: ${actor_source:-<empty>}" >&2
    return 1
  fi
  if [[ -z "$decided_at" ]]; then
    decided_at="$(workflow_action_now_iso)"
  fi
  if ! graph_operator_is_iso_timestamp "$decided_at"; then
    echo "Error: malformed workflow action decidedAt: ${decided_at:-<empty>}" >&2
    return 1
  fi

  request_json="$(workflow_action_request_read "$run_dir" "$request_id")" || return 1
  req_kind="$(printf '%s' "$request_json" | jq -r '.kind // empty')"
  req_run="$(printf '%s' "$request_json" | jq -r '.runId // empty')"
  req_stage="$(printf '%s' "$request_json" | jq -r '.stageId // empty')"
  req_attempt="$(printf '%s' "$request_json" | jq -r '.attemptId // empty')"
  req_choices="$(printf '%s' "$request_json" | jq -c '.choices')"
  req_nonce="$(printf '%s' "$request_json" | jq -r '.nonce // empty')"
  req_runtime="$(printf '%s' "$request_json" | jq -r '.runtime // empty')"
  req_action="$(printf '%s' "$request_json" | jq -r '.action // empty')"
  req_resource="$(printf '%s' "$request_json" | jq -r '.resource // empty')"
  req_effect="$(printf '%s' "$request_json" | jq -r '.effect // empty')"
  req_expires="$(printf '%s' "$request_json" | jq -r '.expiresAt // empty')"

  [[ -n "$kind" ]] || kind="$req_kind"
  [[ -n "$run_id" ]] || run_id="$req_run"
  [[ -n "$stage_id" ]] || stage_id="$req_stage"
  [[ -n "$attempt_id" ]] || attempt_id="$req_attempt"

  if [[ "$kind" != "$req_kind" ]]; then
    echo "Error: workflow action decision kind does not match the request" >&2
    return 1
  fi
  if [[ "$run_id" != "$req_run" || "$stage_id" != "$req_stage" || "$attempt_id" != "$req_attempt" ]]; then
    echo "Error: workflow action decision identity does not match the request" >&2
    return 1
  fi
  if ! graph_operator_token_in_list "$decision" "$(workflow_action_choices_for_kind "$kind")"; then
    echo "Error: malformed workflow action decision choice: ${decision:-<empty>}" >&2
    return 1
  fi
  if ! printf '%s' "$req_choices" | jq -e --arg d "$decision" 'type == "array" and index($d) != null' >/dev/null 2>&1; then
    echo "Error: workflow action decision is not an available choice: $decision" >&2
    return 1
  fi

  if workflow_action_decision_requires_message "$kind" "$decision"; then
    message="$(workflow_action_bound_text "message" "$message")" || return 1
  else
    if [[ -n "$message" ]]; then
      message="$(workflow_action_bound_text "message" "$message")" || return 1
    else
      message=""
    fi
  fi

  case "$kind" in
    permission)
      if [[ -z "$nonce" ]]; then
        echo "Error: permission decision requires nonce" >&2
        return 1
      fi
      graph_operator_nonce_valid "$nonce" || return 1
      if [[ "$nonce" != "$req_nonce" ]]; then
        echo "Error: permission decision nonce does not match the request" >&2
        return 1
      fi
      [[ -n "$runtime" ]] || runtime="$req_runtime"
      if [[ "$runtime" != "$req_runtime" ]]; then
        echo "Error: permission decision runtime does not match the request" >&2
        return 1
      fi
      now="$(workflow_action_now_iso)"
      if [[ -n "$req_expires" ]] && graph_operator_iso_expired "$now" "$req_expires"; then
        echo "Error: permission request has expired" >&2
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
          echo "Error: permission decision grant requires action, resource, and effect" >&2
          return 1
        fi
        if graph_logs_has_dotdot "$grant_resource"; then
          echo "Error: permission decision grant resource may not contain '..'" >&2
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
      record="$(jq -nc \
        --argjson schemaVersion "$WORKFLOW_ACTION_SCHEMA_VERSION" \
        --arg requestId "$request_id" \
        --arg kind "$kind" \
        --arg runId "$run_id" \
        --arg stageId "$stage_id" \
        --arg attemptId "$attempt_id" \
        --arg decision "$decision" \
        --arg actorSource "$actor_source" \
        --arg decidedAt "$decided_at" \
        --arg nonce "$nonce" \
        --arg runtime "$runtime" \
        --argjson granted "$granted_json" \
        --arg message "$message" \
        '{
          schemaVersion:$schemaVersion,
          requestId:$requestId,
          kind:$kind,
          runId:$runId,
          stageId:$stageId,
          attemptId:$attemptId,
          decision:$decision,
          actorSource:$actorSource,
          decidedAt:$decidedAt,
          nonce:$nonce,
          runtime:$runtime,
          granted:$granted
        } + (if $message == "" then {message:null} else {message:$message} end)
      ')" || {
        echo "Error: failed to encode permission decision record" >&2
        return 1
      }
      ;;
    approval|input)
      if [[ -n "$nonce" ]]; then
        echo "Error: ${kind} decision must not persist a nonce" >&2
        return 1
      fi
      record="$(jq -nc \
        --argjson schemaVersion "$WORKFLOW_ACTION_SCHEMA_VERSION" \
        --arg requestId "$request_id" \
        --arg kind "$kind" \
        --arg runId "$run_id" \
        --arg stageId "$stage_id" \
        --arg attemptId "$attempt_id" \
        --arg decision "$decision" \
        --arg actorSource "$actor_source" \
        --arg decidedAt "$decided_at" \
        --arg message "$message" \
        '{
          schemaVersion:$schemaVersion,
          requestId:$requestId,
          kind:$kind,
          runId:$runId,
          stageId:$stageId,
          attemptId:$attemptId,
          decision:$decision,
          actorSource:$actorSource,
          decidedAt:$decidedAt
        } + (if $message == "" then {message:null} else {message:$message} end)
      ')" || {
        echo "Error: failed to encode ${kind} decision record" >&2
        return 1
      }
      if declare -F workflow_action_continuation_copy_from_request >/dev/null 2>&1; then
        record="$(workflow_action_continuation_copy_from_request "$run_dir" "$request_id" "$record")"
      fi
      ;;
  esac

  rel="$(workflow_action_decision_rel "$request_id")" || return 1
  abs="$(workflow_action_prepare_write "$run_dir" "$rel" "actions/decisions/${request_id}.json")" || return 1

  if [[ -e "$abs" ]]; then
    workflow_action_decision_accept_existing "$abs" "$record" || return 1
    return 0
  fi

  write_ec=0
  graph_operator_create_once_write "$abs" "$record" || write_ec=$?
  if [[ "$write_ec" -eq 0 ]]; then
    abs="$(graph_logs_resolve "$run_dir" "$rel")" || return 1
    if [[ -L "$abs" ]]; then
      echo "Error: workflow action decision path became a symlink after write: $rel" >&2
      return 1
    fi
    printf '%s\n' "$abs"
    return 0
  fi
  if [[ "$write_ec" -eq 2 || -e "$abs" ]]; then
    workflow_action_decision_accept_existing "$abs" "$record" || return 1
    return 0
  fi
  return 1
}

# workflow_action_decision_read <registry-run> <request-id>
workflow_action_decision_read() {
  local run_dir="$1" request_id="$2" abs
  abs="$(workflow_action_decision_path "$run_dir" "$request_id")" || return 1
  if [[ ! -f "$abs" || -L "$abs" ]]; then
    echo "Error: workflow action decision not found: $request_id" >&2
    return 1
  fi
  jq -c '.' "$abs"
}

# workflow_action_consume_once <registry-run> <request-id> [consumer]
# Create-once consumption record after a decision exists. Prints absolute path.
workflow_action_consume_once() {
  local run_dir="$1" request_id="$2" consumer="${3:-resume}"
  local decision_json kind run_id stage_id attempt_id decision decided_at
  local consumed_at rel abs record write_ec

  if [[ -z "$run_dir" || ! -d "$run_dir" ]]; then
    echo "Error: workflow_action_consume_once requires a registry-run directory" >&2
    return 1
  fi
  if ! graph_operator_token_in_list "$consumer" "$WORKFLOW_ACTION_CONSUMERS"; then
    echo "Error: malformed workflow action consumer: ${consumer:-<empty>}" >&2
    return 1
  fi

  decision_json="$(workflow_action_decision_read "$run_dir" "$request_id")" || return 1
  kind="$(printf '%s' "$decision_json" | jq -r '.kind')"
  run_id="$(printf '%s' "$decision_json" | jq -r '.runId')"
  stage_id="$(printf '%s' "$decision_json" | jq -r '.stageId')"
  attempt_id="$(printf '%s' "$decision_json" | jq -r '.attemptId')"
  decision="$(printf '%s' "$decision_json" | jq -r '.decision')"
  consumed_at="$(workflow_action_now_iso)"

  record="$(jq -nc \
    --argjson schemaVersion "$WORKFLOW_ACTION_SCHEMA_VERSION" \
    --arg requestId "$request_id" \
    --arg kind "$kind" \
    --arg runId "$run_id" \
    --arg stageId "$stage_id" \
    --arg attemptId "$attempt_id" \
    --arg decision "$decision" \
    --arg consumedAt "$consumed_at" \
    --arg consumer "$consumer" \
    '{
      schemaVersion:$schemaVersion,
      requestId:$requestId,
      kind:$kind,
      runId:$runId,
      stageId:$stageId,
      attemptId:$attemptId,
      decision:$decision,
      consumedAt:$consumedAt,
      consumer:$consumer
    }')" || {
    echo "Error: failed to encode consumption record" >&2
    return 1
  }
  if declare -F workflow_action_continuation_copy_from_request >/dev/null 2>&1; then
    record="$(workflow_action_continuation_copy_from_request "$run_dir" "$request_id" "$record")"
  fi

  rel="$(workflow_action_consumed_rel "$request_id")" || return 1
  abs="$(workflow_action_prepare_write "$run_dir" "$rel" "actions/consumed/${request_id}.json")" || return 1

  if [[ -e "$abs" ]]; then
    echo "Error: workflow action already consumed: $request_id" >&2
    return 2
  fi

  write_ec=0
  graph_operator_create_once_write "$abs" "$record" || write_ec=$?
  if [[ "$write_ec" -eq 0 ]]; then
    abs="$(graph_logs_resolve "$run_dir" "$rel")" || return 1
    if [[ -L "$abs" ]]; then
      echo "Error: workflow action consumed path became a symlink after write: $rel" >&2
      return 1
    fi
    printf '%s\n' "$abs"
    return 0
  fi
  if [[ "$write_ec" -eq 2 || -e "$abs" ]]; then
    echo "Error: workflow action already consumed: $request_id" >&2
    return 2
  fi
  return 1
}

# workflow_action_consumed_read <registry-run> <request-id>
workflow_action_consumed_read() {
  local run_dir="$1" request_id="$2" abs
  abs="$(workflow_action_consumed_path "$run_dir" "$request_id")" || return 1
  if [[ ! -f "$abs" || -L "$abs" ]]; then
    echo "Error: workflow action consumption not found: $request_id" >&2
    return 1
  fi
  jq -c '.' "$abs"
}

# workflow_action_injection_rel <request-id>
workflow_action_injection_rel() {
  local request_id="${1:-}"
  graph_operator_request_id_valid "$request_id" || return 1
  printf 'actions/injections/%s.md\n' "$request_id"
}

# workflow_action_injection_path <registry-run> <request-id>
workflow_action_injection_path() {
  local run_dir="${1:-}" request_id="${2:-}" rel
  rel="$(workflow_action_injection_rel "$request_id")" || return 1
  graph_logs_resolve "$run_dir" "$rel"
}

# workflow_action_stage_input_injection <registry-run> <request-id>
#   [--todo-id <id>] [--control-plan <path>]
#
# After an answered input decision is verified, stage one delimited injection
# for the same TODO's next fresh invocation. Create-once: a second stage for
# the same request-id fails. Prints the absolute injection path.
# Does not consume the decision (callers consume separately / beforehand).
workflow_action_stage_input_injection() {
  local run_dir="" request_id="" todo_id="" control_plan=""
  local req decision message stage_id attempt_id run_id kind
  local rel abs body fence write_ec

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --todo-id) todo_id="${2:-}"; shift 2 ;;
      --control-plan) control_plan="${2:-}"; shift 2 ;;
      --)
        shift
        break
        ;;
      -*)
        echo "Error: unknown workflow_action_stage_input_injection argument: $1" >&2
        return 1
        ;;
      *)
        if [[ -z "$run_dir" ]]; then
          run_dir="$1"
        elif [[ -z "$request_id" ]]; then
          request_id="$1"
        else
          echo "Error: unexpected argument: $1" >&2
          return 1
        fi
        shift
        ;;
    esac
  done

  [[ -n "$run_dir" && -d "$run_dir" && -n "$request_id" ]] || {
    echo "Error: workflow_action_stage_input_injection requires registry-run and request-id" >&2
    return 1
  }
  command -v jq >/dev/null 2>&1 || return 1

  req="$(workflow_action_request_read "$run_dir" "$request_id")" || return 1
  kind="$(printf '%s' "$req" | jq -r '.kind // empty')"
  [[ "$kind" == "input" ]] || {
    echo "Error: input injection requires kind=input (got ${kind:-empty})" >&2
    return 1
  }
  local continuation_json runtime_bound _continuation_payload
  continuation_json="$(workflow_action_continuation_from_record "$req")"
  if [[ -n "$continuation_json" && "$continuation_json" != "null" ]] \
    && declare -F workflow_action_continuation_matches_current >/dev/null 2>&1; then
    if ! workflow_action_continuation_matches_current "$continuation_json"; then
      echo "Error: input injection continuationIdentity does not match current attempt" >&2
      return 1
    fi
  fi
  _continuation_payload="${continuation_json:-}"
  [[ -n "$_continuation_payload" ]] || _continuation_payload='{}'
  runtime_bound="$(jq -r '.runtime // empty' <<<"$_continuation_payload")"
  [[ -n "$runtime_bound" && "$runtime_bound" != "null" ]] || runtime_bound=""
  decision="$(workflow_action_decision_read "$run_dir" "$request_id")" || return 1
  [[ "$(printf '%s' "$decision" | jq -r '.decision // empty')" == "answer" ]] || {
    echo "Error: input injection requires an answer decision" >&2
    return 1
  }

  message="$(printf '%s' "$decision" | jq -r '.message // empty')"
  run_id="$(printf '%s' "$decision" | jq -r '.runId // empty')"
  stage_id="$(printf '%s' "$decision" | jq -r '.stageId // empty')"
  attempt_id="$(printf '%s' "$decision" | jq -r '.attemptId // empty')"
  question="$(printf '%s' "$req" | jq -r '.question // empty')"
  [[ -n "$message" ]] || {
    echo "Error: answered input has empty message" >&2
    return 1
  }

  # Fence longer than any backtick run in the message (same idea as evaluator feedback).
  fence='```'
  while printf '%s' "$message" | grep -Fq "$fence"; do
    fence="${fence}\`"
  done

  # Delimited OPERATOR_INPUT_RESPONSE for the same TODO's next fresh invocation.
  # Never includes capability nonce content.
  body="$(printf '%s\n' \
    "<!-- OPERATOR_INPUT_RESPONSE: START -->" \
    "requestId: ${request_id}" \
    "runId: ${run_id}" \
    "stageId: ${stage_id}" \
    "attemptId: ${attempt_id}" \
    "todoId: ${todo_id:-$(jq -r '.todoId // empty' <<<"$_continuation_payload")}" \
    "controlPlanPath: ${control_plan:-$(jq -r '.controlPlanPath // empty' <<<"$_continuation_payload")}" \
    "runtime: ${runtime_bound}" \
    "question: ${question}" \
    "answer:" \
    "${fence}" \
    "${message}" \
    "${fence}" \
    "<!-- OPERATOR_INPUT_RESPONSE: END -->")"

  rel="$(workflow_action_injection_rel "$request_id")" || return 1
  abs="$(workflow_action_prepare_write "$run_dir" "$rel" "actions/injections/${request_id}.md")" || return 1

  if [[ -e "$abs" ]]; then
    echo "Error: workflow action injection already staged: $request_id" >&2
    return 2
  fi

  write_ec=0
  # Create-once via temp + rename under the prepared absolute path.
  {
    umask 077
    printf '%s\n' "$body" >"${abs}.tmp" || write_ec=1
    if [[ "$write_ec" -eq 0 ]]; then
      if ! mv -n "${abs}.tmp" "$abs" 2>/dev/null; then
        if [[ -e "$abs" ]]; then
          rm -f "${abs}.tmp"
          write_ec=2
        else
          mv "${abs}.tmp" "$abs" || write_ec=1
        fi
      fi
    fi
  }
  if [[ "$write_ec" -eq 0 && -f "$abs" && ! -L "$abs" ]]; then
    printf '%s\n' "$abs"
    return 0
  fi
  rm -f "${abs}.tmp" 2>/dev/null || true
  if [[ "$write_ec" -eq 2 || -e "$abs" ]]; then
    echo "Error: workflow action injection already staged: $request_id" >&2
    return 2
  fi
  echo "Error: failed to stage input injection for $request_id" >&2
  return 1
}

# workflow_action_stage_human_feedback <registry-run> <request-id>
#   [--target-stage <id>] [--target-attempt <n>]
#
# After an approval request-changes decision, stage one delimited injection that
# binds the immutable operator message to the changesTarget's next fresh
# attempt. Does not edit any source plan. Create-once. Prints the absolute
# injection path. Does not consume the decision (callers consume with
# consumer=reset separately).
workflow_action_stage_human_feedback() {
  local run_dir="" request_id="" target_stage="" target_attempt=""
  local req decision message stage_id attempt_id run_id kind choice changes_target
  local rel abs body fence write_ec

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --target-stage) target_stage="${2:-}"; shift 2 ;;
      --target-attempt) target_attempt="${2:-}"; shift 2 ;;
      --)
        shift
        break
        ;;
      -*)
        echo "Error: unknown workflow_action_stage_human_feedback argument: $1" >&2
        return 1
        ;;
      *)
        if [[ -z "$run_dir" ]]; then
          run_dir="$1"
        elif [[ -z "$request_id" ]]; then
          request_id="$1"
        else
          echo "Error: unexpected argument: $1" >&2
          return 1
        fi
        shift
        ;;
    esac
  done

  [[ -n "$run_dir" && -d "$run_dir" && -n "$request_id" ]] || {
    echo "Error: workflow_action_stage_human_feedback requires registry-run and request-id" >&2
    return 1
  }
  command -v jq >/dev/null 2>&1 || return 1

  req="$(workflow_action_request_read "$run_dir" "$request_id")" || return 1
  kind="$(printf '%s' "$req" | jq -r '.kind // empty')"
  [[ "$kind" == "approval" ]] || {
    echo "Error: human feedback staging requires kind=approval (got ${kind:-empty})" >&2
    return 1
  }
  changes_target="$(printf '%s' "$req" | jq -r '.changesTarget // empty')"
  [[ -n "$changes_target" ]] || {
    echo "Error: approval request missing changesTarget" >&2
    return 1
  }
  if [[ -n "$target_stage" && "$target_stage" != "$changes_target" ]]; then
    echo "Error: human feedback target stage mismatch: expected $changes_target got $target_stage" >&2
    return 1
  fi
  target_stage="$changes_target"

  decision="$(workflow_action_decision_read "$run_dir" "$request_id")" || return 1
  choice="$(printf '%s' "$decision" | jq -r '.decision // empty')"
  [[ "$choice" == "request-changes" ]] || {
    echo "Error: human feedback requires a request-changes decision" >&2
    return 1
  }

  message="$(printf '%s' "$decision" | jq -r '.message // empty')"
  run_id="$(printf '%s' "$decision" | jq -r '.runId // empty')"
  stage_id="$(printf '%s' "$decision" | jq -r '.stageId // empty')"
  attempt_id="$(printf '%s' "$decision" | jq -r '.attemptId // empty')"
  [[ -n "$message" ]] || {
    echo "Error: request-changes decision has empty message" >&2
    return 1
  }

  fence='```'
  while printf '%s' "$message" | grep -Fq "$fence"; do
    fence="${fence}\`"
  done

  body="$(printf '%s\n' \
    "<!-- OPERATOR_HUMAN_FEEDBACK: START -->" \
    "requestId: ${request_id}" \
    "runId: ${run_id}" \
    "approvalStageId: ${stage_id}" \
    "approvalAttemptId: ${attempt_id}" \
    "changesTarget: ${target_stage}" \
    "targetAttempt: ${target_attempt:-}" \
    "message:" \
    "${fence}" \
    "${message}" \
    "${fence}" \
    "<!-- OPERATOR_HUMAN_FEEDBACK: END -->")"

  rel="$(workflow_action_injection_rel "$request_id")" || return 1
  abs="$(workflow_action_prepare_write "$run_dir" "$rel" "actions/injections/${request_id}.md")" || return 1

  if [[ -e "$abs" ]]; then
    echo "Error: workflow action injection already staged: $request_id" >&2
    return 2
  fi

  write_ec=0
  {
    umask 077
    printf '%s\n' "$body" >"${abs}.tmp" || write_ec=1
    if [[ "$write_ec" -eq 0 ]]; then
      if ! mv -n "${abs}.tmp" "$abs" 2>/dev/null; then
        if [[ -e "$abs" ]]; then
          rm -f "${abs}.tmp"
          write_ec=2
        else
          mv "${abs}.tmp" "$abs" || write_ec=1
        fi
      fi
    fi
  }
  if [[ "$write_ec" -eq 0 && -f "$abs" && ! -L "$abs" ]]; then
    printf '%s\n' "$abs"
    return 0
  fi
  rm -f "${abs}.tmp" 2>/dev/null || true
  if [[ "$write_ec" -eq 2 || -e "$abs" ]]; then
    echo "Error: workflow action injection already staged: $request_id" >&2
    return 2
  fi
  echo "Error: failed to stage human feedback for $request_id" >&2
  return 1
}

# workflow_action_find_changes_requested_for_target <registry-run> <changes-target>
# Prints compact JSON for the first unconsumed request-changes approval whose
# changesTarget matches, or empty when none. Does not mutate.
workflow_action_find_changes_requested_for_target() {
  local run_dir="${1:-}" target="${2:-}"
  local requests_dir path req decision request_id class
  [[ -n "$run_dir" && -d "$run_dir" && -n "$target" ]] || {
    echo "Error: workflow_action_find_changes_requested_for_target requires registry-run and changes-target" >&2
    return 1
  }
  command -v jq >/dev/null 2>&1 || return 1
  requests_dir="$run_dir/actions/requests"
  [[ -d "$requests_dir" ]] || return 0
  for path in "$requests_dir"/*.json; do
    [[ -f "$path" && ! -L "$path" ]] || continue
    req="$(jq -c . "$path" 2>/dev/null)" || continue
    [[ "$(printf '%s' "$req" | jq -r '.kind // empty')" == "approval" ]] || continue
    [[ "$(printf '%s' "$req" | jq -r '.changesTarget // empty')" == "$target" ]] || continue
    request_id="$(printf '%s' "$req" | jq -r '.requestId // empty')"
    [[ -n "$request_id" ]] || continue
    class="$(workflow_action_classify_for_resume "$run_dir" "$request_id" 2>/dev/null || printf 'invalid')"
    [[ "$class" == "changes-requested" ]] || continue
    decision="$(workflow_action_decision_read "$run_dir" "$request_id" 2>/dev/null || true)"
    jq -cn \
      --argjson req "$req" \
      --argjson decision "${decision:-null}" \
      --arg requestId "$request_id" \
      --arg message "$(printf '%s' "$decision" | jq -r '.message // empty')" \
      '{
        requestId: $requestId,
        changesTarget: $req.changesTarget,
        approvalStageId: $req.stageId,
        message: $message,
        request: $req,
        decision: $decision
      }'
    return 0
  done
  return 0
}

# workflow_reset_collect_inference_targets <registry-run> <observation-json>
# Prints a JSON array of unique reset-target stage ids inferred from human
# changes-requested blockers. Does not mutate.
workflow_reset_collect_inference_targets() {
  local registry_run="${1:-}" observation="${2:-}"
  [[ -n "$registry_run" && -n "$observation" ]] || {
    echo "Error: workflow_reset_collect_inference_targets requires registry-run and observation-json" >&2
    return 1
  }
  command -v jq >/dev/null 2>&1 || return 1
  printf '%s' "$observation" | jq -c '
    [.nodes[]?
      | select(
          (.reasonCode // "") == "human-changes-requested"
          or ((.blocker.reasonCode // "") == "human-changes-requested")
        )
      | (.changesTarget // .blocker.changesTarget // empty)
      | select(. != "")
    ] | unique
  '
}

# workflow_reset_infer_stage_id <registry-run> <observation-json> [--interactive]
# Resolves the sole human changesTarget when unambiguous. Prints the stage id on
# stdout. Exit 2 when multiple candidates require --stage; exit 1 when none.
workflow_reset_infer_stage_id() {
  local registry_run="${1:-}" observation="${2:-}" interactive=0
  local targets_json count target choice

  shift 2 || true
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --interactive) interactive=1; shift ;;
      *)
        echo "Error: unknown workflow_reset_infer_stage_id argument: $1" >&2
        return 2
        ;;
    esac
  done

  targets_json="$(workflow_reset_collect_inference_targets "$registry_run" "$observation" 2>/dev/null || printf '[]')"
  count="$(printf '%s' "$targets_json" | jq -r 'length')"

  if [[ "$count" -eq 1 ]]; then
    printf '%s' "$targets_json" | jq -r '.[0]'
    return 0
  fi

  if [[ "$count" -gt 1 ]]; then
    if [[ "$interactive" -eq 1 && -t 0 ]]; then
      if declare -F ralph_menu_select >/dev/null 2>&1; then
        local -a menu=()
        while IFS= read -r target || [[ -n "$target" ]]; do
          [[ -n "$target" ]] || continue
          menu+=("$target")
        done < <(printf '%s' "$targets_json" | jq -r '.[]')
        choice="$(ralph_menu_select --prompt "Select reset target stage:" --default 1 -- "${menu[@]}")" || return 2
        printf '%s\n' "$choice"
        return 0
      fi
    fi
    echo "Error: multiple reset targets; specify --stage <id>" >&2
    return 2
  fi

  # Sole actionable blocker: one blocked stage whose blocker recommends reset.
  targets_json="$(printf '%s' "$observation" | jq -c '
    [.nodes[]?
      | select(
          (.state // "") == "blocked"
          and ((.blocker.action.argv // []) | index("reset") != null)
        )
      | (.blocker.changesTarget // .changesTarget // .id // empty)
      | select(. != "")
    ] | unique
  ')"
  count="$(printf '%s' "$targets_json" | jq -r 'length')"
  if [[ "$count" -eq 1 ]]; then
    printf '%s' "$targets_json" | jq -r '.[0]'
    return 0
  fi
  if [[ "$count" -gt 1 ]]; then
    echo "Error: multiple reset targets; specify --stage <id>" >&2
    return 2
  fi

  echo "Error: reset requires --stage <id> or --all" >&2
  return 1
}

# workflow_action_classify_for_resume <registry-run> <request-id>
# Classifies a common action for Sequential/Dependency resume.
# Prints exactly one token:
#   missing | unresolved | ready-input | ready-approval | changes-requested |
#   cancelled | denied | already-consumed | invalid
workflow_action_classify_for_resume() {
  local run_dir="${1:-}" request_id="${2:-}"
  local req decision consumed kind choice

  if [[ -z "$run_dir" || -z "$request_id" ]]; then
    echo "Error: workflow_action_classify_for_resume requires registry-run and request-id" >&2
    return 1
  fi
  command -v jq >/dev/null 2>&1 || return 1

  if ! req="$(workflow_action_request_read "$run_dir" "$request_id" 2>/dev/null)"; then
    printf 'missing\n'
    return 0
  fi
  kind="$(printf '%s' "$req" | jq -r '.kind // empty')"

  if consumed="$(workflow_action_consumed_read "$run_dir" "$request_id" 2>/dev/null)"; then
    if [[ -n "$consumed" && "$consumed" != "null" ]]; then
      printf 'already-consumed\n'
      return 0
    fi
  fi

  if ! decision="$(workflow_action_decision_read "$run_dir" "$request_id" 2>/dev/null)"; then
    printf 'unresolved\n'
    return 0
  fi
  choice="$(printf '%s' "$decision" | jq -r '.decision // .choice // empty')"

  case "$kind:$choice" in
    input:answer) printf 'ready-input\n' ;;
    approval:approve) printf 'ready-approval\n' ;;
    approval:request-changes) printf 'changes-requested\n' ;;
    *:cancel) printf 'cancelled\n' ;;
    permission:deny) printf 'denied\n' ;;
    permission:allow-once|permission:allow-run|permission:allow-always)
      # Permission grants are Dependency-only; Sequential resume refuses them.
      printf 'invalid\n'
      ;;
    *)
      printf 'invalid\n'
      ;;
  esac
  return 0
}

# workflow_action_waiting_resume_class <registry-run> <blocker-json>
# Maps a stage blocker (+ common action records) to a resume class for waiting:
#   clean-interruption | answered-input | approved-gate | unresolved-action |
#   changes-requested | refuse
workflow_action_waiting_resume_class() {
  local run_dir="${1:-}" blocker_json="${2:-}"
  local kind request_id reason retryable class

  if [[ -z "$run_dir" ]]; then
    echo "Error: workflow_action_waiting_resume_class requires registry-run" >&2
    return 1
  fi
  command -v jq >/dev/null 2>&1 || return 1

  if [[ -z "$blocker_json" || "$blocker_json" == "null" ]]; then
    # Waiting with no blocker is treated as a clean supervisor interruption.
    printf 'clean-interruption\n'
    return 0
  fi
  if ! printf '%s' "$blocker_json" | jq -e 'type == "object"' >/dev/null 2>&1; then
    printf 'refuse\n'
    return 0
  fi

  kind="$(printf '%s' "$blocker_json" | jq -r '.kind // empty')"
  request_id="$(printf '%s' "$blocker_json" | jq -r '.requestId // empty')"
  reason="$(printf '%s' "$blocker_json" | jq -r '.reasonCode // empty')"
  retryable="$(printf '%s' "$blocker_json" | jq -r '.retryable // false')"

  # Changes-requested is never resume-retryable (requires exact reset).
  if [[ "$reason" == "human-changes-requested" ]]; then
    printf 'changes-requested\n'
    return 0
  fi

  if [[ -n "$request_id" ]]; then
    class="$(workflow_action_classify_for_resume "$run_dir" "$request_id")" || class="invalid"
    case "$class" in
      ready-input)
        printf 'answered-input\n'
        return 0
        ;;
      ready-approval)
        printf 'approved-gate\n'
        return 0
        ;;
      changes-requested)
        printf 'changes-requested\n'
        return 0
        ;;
      unresolved)
        printf 'unresolved-action\n'
        return 0
        ;;
      already-consumed)
        # Consumed but still waiting is inconsistent; refuse rather than re-consume.
        printf 'refuse\n'
        return 0
        ;;
      cancelled|denied|missing|invalid)
        printf 'refuse\n'
        return 0
        ;;
    esac
  fi

  # Clean interruption: retryable waiting with no outstanding action.
  if [[ "$retryable" == "true" ]] && [[ "$reason" == "none" || "$reason" == "operator-request" || -z "$request_id" ]]; then
    printf 'clean-interruption\n'
    return 0
  fi

  # Outstanding non-retryable input/approval without a decision path above.
  if [[ "$kind" == "input" || "$kind" == "approval" || "$kind" == "permission" ]]; then
    if [[ "$retryable" != "true" ]]; then
      printf 'unresolved-action\n'
      return 0
    fi
  fi

  printf 'refuse\n'
  return 0
}

# workflow_action_revoke_attempt_capability <registry-run> <run-id> <stage-id> <attempt-id>
# Capabilities are deliberately ephemeral. Remove only capability records whose
# durable identity belongs to the interrupted attempt; requests, decisions, and
# consumption records are never touched.
workflow_action_revoke_attempt_capability() {
  local run_dir="${1:-}" run_id="${2:-}" stage_id="${3:-}" attempt_id="${4:-}"
  local capabilities_dir path identity

  [[ -n "$run_dir" && -d "$run_dir" && -n "$run_id" && -n "$stage_id" && -n "$attempt_id" ]] || {
    echo "Error: workflow_action_revoke_attempt_capability requires registry-run run-id stage-id attempt-id" >&2
    return 1
  }
  capabilities_dir="$run_dir/actions/capabilities"
  [[ -d "$capabilities_dir" && ! -L "$capabilities_dir" ]] || return 0
  shopt -s nullglob
  for path in "$capabilities_dir"/*; do
    [[ -f "$path" && ! -L "$path" ]] || continue
    identity="$(jq -c --arg run "$run_id" --arg stage "$stage_id" --arg attempt "$attempt_id" \
      'select(.runId == $run and .stageId == $stage and .attemptId == $attempt)' \
      "$path" 2>/dev/null || true)"
    if [[ -n "$identity" ]]; then
      rm -f -- "$path" || return 1
    fi
  done
  return 0
}

# workflow_action_revoke_residual_capabilities <registry-run> <run-id>
# Removes every ephemeral capability record for <run-id>. Request, decision,
# and consumption records are never touched. Used by recover/cancel after a
# supervisor is proven gone or an operator cancel is accepted.
workflow_action_revoke_residual_capabilities() {
  local run_dir="${1:-}" run_id="${2:-}"
  local capabilities_dir path

  [[ -n "$run_dir" && -d "$run_dir" && -n "$run_id" ]] || {
    echo "Error: workflow_action_revoke_residual_capabilities requires registry-run and run-id" >&2
    return 1
  }
  capabilities_dir="$run_dir/actions/capabilities"
  [[ -d "$capabilities_dir" && ! -L "$capabilities_dir" ]] || return 0
  shopt -s nullglob
  for path in "$capabilities_dir"/*; do
    [[ -f "$path" && ! -L "$path" ]] || continue
    if jq -e --arg run "$run_id" '.runId == $run' "$path" >/dev/null 2>&1; then
      rm -f -- "$path" || return 1
    fi
  done
  shopt -u nullglob
  return 0
}

# workflow_action_first_outstanding <registry-run> <run-id>
# Prints compact JSON for the first unresolved input/approval request, or
# {"requestId":null} when none are outstanding. Never mutates records.
workflow_action_first_outstanding() {
  local run_dir="${1:-}" run_id="${2:-}"
  local requests_dir path request request_id kind stage attempt decision

  [[ -n "$run_dir" && -d "$run_dir" && -n "$run_id" ]] || {
    echo "Error: workflow_action_first_outstanding requires registry-run and run-id" >&2
    return 1
  }
  requests_dir="$run_dir/actions/requests"
  if [[ ! -d "$requests_dir" || -L "$requests_dir" ]]; then
    jq -cn '{requestId:null}'
    return 0
  fi
  shopt -s nullglob
  for path in "$requests_dir"/*.json; do
    [[ -f "$path" && ! -L "$path" ]] || continue
    request="$(jq -c . "$path" 2>/dev/null || true)"
    [[ -n "$request" ]] || continue
    [[ "$(printf '%s' "$request" | jq -r '.runId // empty')" == "$run_id" ]] || continue
    kind="$(printf '%s' "$request" | jq -r '.kind // empty')"
    case "$kind" in input|approval) ;; *) continue ;; esac
    request_id="$(printf '%s' "$request" | jq -r '.requestId // empty')"
    [[ -n "$request_id" ]] || continue
    decision="$(workflow_action_decision_read "$run_dir" "$request_id" 2>/dev/null || true)"
    [[ -z "$decision" ]] || continue
    stage="$(printf '%s' "$request" | jq -r '.stageId // empty')"
    attempt="$(printf '%s' "$request" | jq -r '.attemptId // empty')"
    shopt -u nullglob
    jq -cn       --arg requestId "$request_id"       --arg kind "$kind"       --arg stageId "$stage"       --arg attemptId "$attempt"       '{requestId:$requestId,kind:$kind,stageId:$stageId,attemptId:$attemptId}'
    return 0
  done
  shopt -u nullglob
  jq -cn '{requestId:null}'
  return 0
}

# workflow_action_cancel_outstanding <registry-run> <run-id> [stage-id] [attempt-id]
# Durably cancels unresolved input/approval requests without deleting any
# request, decision, or consumption record. Existing decisions win races.
workflow_action_cancel_outstanding() {
  local run_dir="${1:-}" run_id="${2:-}" stage_filter="${3:-}" attempt_filter="${4:-}"
  local requests_dir path request request_id kind stage attempt decision

  [[ -n "$run_dir" && -d "$run_dir" && -n "$run_id" ]] || {
    echo "Error: workflow_action_cancel_outstanding requires registry-run and run-id" >&2
    return 1
  }
  requests_dir="$run_dir/actions/requests"
  [[ -d "$requests_dir" && ! -L "$requests_dir" ]] || return 0
  shopt -s nullglob
  for path in "$requests_dir"/*.json; do
    [[ -f "$path" && ! -L "$path" ]] || continue
    request="$(jq -c . "$path" 2>/dev/null || true)"
    [[ -n "$request" ]] || continue
    request_id="$(printf '%s' "$request" | jq -r '.requestId // empty')"
    kind="$(printf '%s' "$request" | jq -r '.kind // empty')"
    stage="$(printf '%s' "$request" | jq -r '.stageId // empty')"
    attempt="$(printf '%s' "$request" | jq -r '.attemptId // empty')"
    [[ "$(printf '%s' "$request" | jq -r '.runId // empty')" == "$run_id" ]] || continue
    [[ -z "$stage_filter" || "$stage" == "$stage_filter" ]] || continue
    [[ -z "$attempt_filter" || "$attempt" == "$attempt_filter" ]] || continue
    case "$kind" in input|approval) ;; *) continue ;; esac
    decision="$(workflow_action_decision_read "$run_dir" "$request_id" 2>/dev/null || true)"
    [[ -z "$decision" ]] || continue
    workflow_action_decision_write "$run_dir" "$(jq -cn \
      --arg requestId "$request_id" --arg kind "$kind" --arg runId "$run_id" \
      --arg stageId "$stage" --arg attemptId "$attempt" \
      --arg decidedAt "$(workflow_action_now_iso)" \
      '{requestId:$requestId,kind:$kind,runId:$runId,stageId:$stageId,attemptId:$attemptId,decision:"cancel",actorSource:"adapter",decidedAt:$decidedAt}')" \
      >/dev/null || return 1
  done
  return 0
}

# workflow_action_request_display_state <registry-run> <request-id>
# Prints: outstanding | answered | consumed | missing
workflow_action_request_display_state() {
  local run_dir="${1:-}" request_id="${2:-}"
  [[ -n "$run_dir" && -n "$request_id" ]] || {
    echo "missing"
    return 1
  }
  if workflow_action_consumed_read "$run_dir" "$request_id" >/dev/null 2>&1; then
    printf 'consumed\n'
    return 0
  fi
  if workflow_action_decision_read "$run_dir" "$request_id" >/dev/null 2>&1; then
    printf 'answered\n'
    return 0
  fi
  if workflow_action_request_read "$run_dir" "$request_id" >/dev/null 2>&1; then
    printf 'outstanding\n'
    return 0
  fi
  printf 'missing\n'
  return 1
}

# workflow_action_list <registry-run>
# Normalized JSON array of common action records with decision/consumed state.
workflow_action_list() {
  local run_dir="$1" requests_dir id path req decision consumed entry
  local rows='[]'

  if [[ -z "$run_dir" || ! -d "$run_dir" ]]; then
    echo "Error: workflow_action_list requires a registry-run directory" >&2
    return 1
  fi
  command -v jq >/dev/null 2>&1 || {
    echo "Error: jq is required to list workflow actions" >&2
    return 1
  }

  requests_dir="$(graph_logs_resolve "$run_dir" "actions/requests" 2>/dev/null || true)"
  if [[ -z "$requests_dir" || ! -d "$requests_dir" || -L "$requests_dir" ]]; then
    printf '%s\n' '[]'
    return 0
  fi

  shopt -s nullglob
  for path in "$requests_dir"/*.json; do
    [[ -f "$path" && ! -L "$path" ]] || continue
    id="$(basename "$path" .json)"
    graph_operator_request_id_valid "$id" 2>/dev/null || continue
    req="$(jq -c '.' "$path" 2>/dev/null)" || continue
    if ! decision="$(workflow_action_decision_read "$run_dir" "$id" 2>/dev/null)"; then
      decision="null"
    fi
    if ! consumed="$(workflow_action_consumed_read "$run_dir" "$id" 2>/dev/null)"; then
      consumed="null"
    fi
    entry="$(jq -nc \
      --argjson request "$req" \
      --argjson decision "$decision" \
      --argjson consumed "$consumed" \
      '{
        requestId: $request.requestId,
        kind: $request.kind,
        runId: $request.runId,
        stageId: $request.stageId,
        attemptId: $request.attemptId,
        question: ($request.question // null),
        choices: $request.choices,
        createdAt: $request.createdAt,
        decision: $decision,
        consumed: $consumed
      }')"
    rows="$(jq -nc --argjson rows "$rows" --argjson entry "$entry" '$rows + [$entry]')"
  done
  shopt -u nullglob

  printf '%s\n' "$rows" | jq -c 'sort_by(.createdAt, .requestId)'
}

# workflow_action_synthetic_event_records <registry-run>
# Normalized action request/decision rows for workflow watch (read-only).
workflow_action_synthetic_event_records() {
  local run_dir="$1" requests_dir path req decision consumed kind
  local rows='[]' ts stage attempt request_id question message decision_val
  local redacted_q redacted_m

  [[ -n "$run_dir" && -d "$run_dir" ]] || {
    printf '[]\n'
    return 0
  }
  command -v jq >/dev/null 2>&1 || return 1

  requests_dir="$(graph_logs_resolve "$run_dir" "actions/requests" 2>/dev/null || true)"
  [[ -n "$requests_dir" && -d "$requests_dir" && ! -L "$requests_dir" ]] || {
    printf '[]\n'
    return 0
  }

  shopt -s nullglob
  for path in "$requests_dir"/*.json; do
    [[ -f "$path" && ! -L "$path" ]] || continue
    req="$(jq -c '.' "$path" 2>/dev/null)" || continue
    kind="$(printf '%s' "$req" | jq -r '.kind // empty')"
    case "$kind" in approval|input) ;; *) continue ;; esac
    request_id="$(printf '%s' "$req" | jq -r '.requestId // empty')"
    stage="$(printf '%s' "$req" | jq -r '.stageId // empty')"
    attempt="$(printf '%s' "$req" | jq -r '.attemptId // empty')"
    ts="$(printf '%s' "$req" | jq -r '.createdAt // empty')"
    question="$(printf '%s' "$req" | jq -r '.question // ""')"
    redacted_q="$(workflow_action_redact_for_display "$question" 2>/dev/null || printf '[REDACTED]')"
    rows="$(jq -nc \
      --argjson rows "$rows" \
      --arg ts "$ts" \
      --arg stage "$stage" \
      --arg attempt "$attempt" \
      --arg requestId "$request_id" \
      --arg kind "$kind" \
      --arg question "$redacted_q" \
      '($rows + [{
        schemaVersion: 1,
        source: "action",
        timestamp: $ts,
        stageId: $stage,
        attemptId: $attempt,
        event: "action-request",
        kind: $kind,
        requestId: $requestId,
        question: $question
      }])')"
    decision=""
    if decision="$(workflow_action_decision_read "$run_dir" "$request_id" 2>/dev/null)"; then
      decision_val="$(printf '%s' "$decision" | jq -r '.decision // empty')"
      message="$(printf '%s' "$decision" | jq -r '.message // ""')"
      ts="$(printf '%s' "$decision" | jq -r '.decidedAt // .createdAt // empty')"
      redacted_m="$(workflow_action_redact_for_display "$message" 2>/dev/null || printf '')"
      rows="$(jq -nc \
        --argjson rows "$rows" \
        --arg ts "$ts" \
        --arg stage "$stage" \
        --arg attempt "$attempt" \
        --arg requestId "$request_id" \
        --arg kind "$kind" \
        --arg decision "$decision_val" \
        --arg message "$redacted_m" \
        '($rows + [{
          schemaVersion: 1,
          source: "action",
          timestamp: $ts,
          stageId: $stage,
          attemptId: $attempt,
          event: "action-decision",
          kind: $kind,
          requestId: $requestId,
          decision: $decision,
          message: (if $message == "" then null else $message end)
        }])')"
    fi
  done
  shopt -u nullglob
  printf '%s\n' "$rows" | jq -c 'sort_by(.timestamp, .requestId, .event)'
}

# workflow_action_format_event_line <event-json>
# Bounded single-line display for watch output. Never prints secrets/raw paths.
workflow_action_format_event_line() {
  local event="${1:-}"
  local ts stage attempt name kind request_id question decision message
  ts="$(printf '%s' "$event" | jq -r '.timestamp // ""')"
  stage="$(printf '%s' "$event" | jq -r '.stageId // "-"')"
  attempt="$(printf '%s' "$event" | jq -r '.attemptId // .attempt // empty')"
  name="$(printf '%s' "$event" | jq -r '.event // ""')"
  kind="$(printf '%s' "$event" | jq -r '.kind // empty')"
  request_id="$(printf '%s' "$event" | jq -r '.requestId // empty')"
  question="$(printf '%s' "$event" | jq -r '.question // empty')"
  decision="$(printf '%s' "$event" | jq -r '.decision // empty')"
  message="$(printf '%s' "$event" | jq -r '.message // empty')"
  case "$name" in
    action-request)
      printf '%s stage=%s attempt=%s event=action-request kind=%s requestId=%s question=%s\n' \
        "$ts" "$stage" "${attempt:--}" "$kind" "$request_id" "$(printf '%q' "$question")"
      ;;
    action-decision)
      if [[ -n "$message" && "$message" != "null" ]]; then
        printf '%s stage=%s attempt=%s event=action-decision kind=%s requestId=%s decision=%s message=%s\n' \
          "$ts" "$stage" "${attempt:--}" "$kind" "$request_id" "$decision" "$(printf '%q' "$message")"
      else
        printf '%s stage=%s attempt=%s event=action-decision kind=%s requestId=%s decision=%s\n' \
          "$ts" "$stage" "${attempt:--}" "$kind" "$request_id" "$decision"
      fi
      ;;
    *)
      return 1
      ;;
  esac
}

# workflow_action_sha256_file <path>
# Prints lowercase hex sha256 of a regular file. Fails closed on missing/symlink.
workflow_action_sha256_file() {
  local path="${1:-}"
  if [[ -z "$path" || ! -f "$path" || -L "$path" ]]; then
    echo "Error: workflow action evidence file missing or is a symlink: ${path:-<empty>}" >&2
    return 1
  fi
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$path" | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$path" | awk '{print $1}'
  elif command -v openssl >/dev/null 2>&1; then
    openssl dgst -sha256 "$path" | awk '{print $NF}'
  else
    echo "Error: no sha256 tool available for approval evidence" >&2
    return 1
  fi
}

# workflow_action_resolve_artifact_path <workspace> <namespace> <declared-path>
# Resolves {{ARTIFACT_NS}} / relative .ralph-workspace paths under workspace.
workflow_action_resolve_artifact_path() {
  local workspace="${1:-}" namespace="${2:-}" declared="${3:-}"
  local resolved
  [[ -n "$workspace" && -n "$declared" ]] || {
    echo "Error: workflow_action_resolve_artifact_path requires workspace and path" >&2
    return 1
  }
  if graph_logs_has_dotdot "$declared"; then
    echo "Error: approval evidence path may not contain '..'" >&2
    return 1
  fi
  resolved="$declared"
  if [[ -n "$namespace" ]]; then
    resolved="${resolved//\{\{ARTIFACT_NS\}\}/$namespace}"
    resolved="${resolved//\{\{PLAN_KEY\}\}/$namespace}"
  fi
  case "$resolved" in
    /*)
      printf '%s\n' "$resolved"
      ;;
    ./*)
      printf '%s/%s\n' "${workspace%/}" "${resolved#./}"
      ;;
    *)
      printf '%s/%s\n' "${workspace%/}" "$resolved"
      ;;
  esac
}

# workflow_action_freeze_evidence <workspace> <namespace> <paths-json>
# paths-json is an array of path strings or {path,required?} objects.
# Prints [{path, sha256}, ...] with absolute paths and current hashes.
# Missing required paths fail closed.
workflow_action_freeze_evidence() {
  local workspace="${1:-}" namespace="${2:-}" paths_json="${3:-[]}"
  local count i declared required abs sha out='[]' item

  [[ -n "$workspace" ]] || {
    echo "Error: workflow_action_freeze_evidence requires workspace" >&2
    return 1
  }
  command -v jq >/dev/null 2>&1 || return 1
  if ! printf '%s' "$paths_json" | jq -e 'type == "array"' >/dev/null 2>&1; then
    echo "Error: approval evidence paths must be a JSON array" >&2
    return 1
  fi

  count="$(printf '%s' "$paths_json" | jq 'length')"
  i=0
  while [[ "$i" -lt "$count" ]]; do
    item="$(printf '%s' "$paths_json" | jq -c --argjson i "$i" '.[$i]')"
    if printf '%s' "$item" | jq -e 'type == "string"' >/dev/null 2>&1; then
      declared="$(printf '%s' "$item" | jq -r '.')"
      required=1
    else
      declared="$(printf '%s' "$item" | jq -r '.path // empty')"
      required="$(printf '%s' "$item" | jq -r 'if (.required // true) == false then 0 else 1 end')"
    fi
    if [[ -z "$declared" ]]; then
      echo "Error: approval evidence path must be non-empty" >&2
      return 1
    fi
    abs="$(workflow_action_resolve_artifact_path "$workspace" "$namespace" "$declared")" || return 1
    if [[ ! -f "$abs" || -L "$abs" ]]; then
      if [[ "$required" -eq 1 ]]; then
        echo "Error: approval evidence missing: $abs" >&2
        return 1
      fi
      i=$((i + 1))
      continue
    fi
    sha="$(workflow_action_sha256_file "$abs")" || return 1
    out="$(jq -cn --argjson out "$out" --arg path "$abs" --arg sha "$sha" \
      '$out + [{path:$path, sha256:$sha}]')" || return 1
    i=$((i + 1))
  done
  if [[ "$(printf '%s' "$out" | jq 'length')" -lt 1 ]]; then
    echo "Error: approval evidence list is empty after freeze" >&2
    return 1
  fi
  printf '%s\n' "$out"
}

# workflow_action_verify_evidence <evidence-json>
# Fail closed when any frozen path is missing, a symlink, or hash-mutated.
workflow_action_verify_evidence() {
  local evidence_json="${1:-}"
  local count i path expected actual

  command -v jq >/dev/null 2>&1 || return 1
  if ! printf '%s' "$evidence_json" | jq -e 'type == "array" and length > 0' >/dev/null 2>&1; then
    echo "Error: approval evidence must be a non-empty array" >&2
    return 1
  fi
  count="$(printf '%s' "$evidence_json" | jq 'length')"
  i=0
  while [[ "$i" -lt "$count" ]]; do
    path="$(printf '%s' "$evidence_json" | jq -r --argjson i "$i" '.[$i].path // empty')"
    expected="$(printf '%s' "$evidence_json" | jq -r --argjson i "$i" '.[$i].sha256 // empty')"
    if [[ -z "$path" || -z "$expected" ]]; then
      echo "Error: approval evidence entry missing path or sha256" >&2
      return 1
    fi
    if [[ ! "$expected" =~ ^[a-f0-9]{64}$ ]]; then
      echo "Error: approval evidence sha256 must be 64 lowercase hex chars" >&2
      return 1
    fi
    actual="$(workflow_action_sha256_file "$path")" || return 1
    if [[ "$actual" != "$expected" ]]; then
      echo "Error: approval evidence mutated or mismatched: $path" >&2
      return 1
    fi
    i=$((i + 1))
  done
  return 0
}

# workflow_action_approval_request_id <run-id> <stage-id> <attempt-id>
# Stable filesystem-safe request id for one approval activation.
workflow_action_approval_request_id() {
  local run_id="${1:-}" stage_id="${2:-}" attempt_id="${3:-}"
  local raw
  [[ -n "$run_id" && -n "$stage_id" && -n "$attempt_id" ]] || {
    echo "Error: workflow_action_approval_request_id requires run-id stage-id attempt-id" >&2
    return 1
  }
  raw="appr-${stage_id}-${attempt_id}"
  raw="$(printf '%s' "$raw" | tr -c 'A-Za-z0-9._-' '-' | sed 's/-\+/-/g; s/^-//; s/-$//')"
  [[ -n "$raw" ]] || raw="appr-approval"
  graph_operator_request_id_valid "$raw" 2>/dev/null || {
    # Fall back to a hashed id when stage/attempt characters collapse badly.
    if command -v sha256sum >/dev/null 2>&1; then
      raw="appr-$(printf '%s' "$run_id:$stage_id:$attempt_id" | sha256sum | awk '{print substr($1,1,24)}')"
    else
      raw="appr-$(printf '%s' "$run_id:$stage_id:$attempt_id" | shasum -a 256 | awk '{print substr($1,1,24)}')"
    fi
  }
  printf '%s\n' "$raw"
}

# workflow_action_approval_blocker_json
#   --request-id ... --run-id ... --reason-code ... --retryable true|false
#   --changes-target ... [--mode list|reset]
# Builds the durable stage/node blocker object for approval waiting/blocked.
workflow_action_approval_blocker_json() {
  local request_id="" run_id="" reason_code="human-approval" retryable="false"
  local changes_target="" mode="list" label argv_json

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --request-id) request_id="${2:-}"; shift 2 ;;
      --run-id) run_id="${2:-}"; shift 2 ;;
      --reason-code) reason_code="${2:-}"; shift 2 ;;
      --retryable) retryable="${2:-}"; shift 2 ;;
      --changes-target) changes_target="${2:-}"; shift 2 ;;
      --mode) mode="${2:-}"; shift 2 ;;
      *)
        echo "Error: unknown workflow_action_approval_blocker_json argument: $1" >&2
        return 1
        ;;
    esac
  done
  [[ -n "$request_id" && -n "$run_id" ]] || {
    echo "Error: workflow_action_approval_blocker_json requires --request-id and --run-id" >&2
    return 1
  }
  case "$retryable" in true|false) ;; *)
    echo "Error: retryable must be true or false" >&2
    return 1
    ;;
  esac
  case "$mode" in
    list)
      label="List actions"
      argv_json="$(jq -cn --arg rid "$run_id" '["ralph","workflow","actions","list",$rid]')"
      ;;
    reset)
      [[ -n "$changes_target" ]] || {
        echo "Error: reset mode requires --changes-target" >&2
        return 1
      }
      label="Reset changes target"
      argv_json="$(jq -cn --arg rid "$run_id" --arg stage "$changes_target" \
        '["ralph","workflow","reset",$rid,"--stage",$stage]')"
      ;;
    *)
      echo "Error: unknown approval blocker mode: $mode" >&2
      return 1
      ;;
  esac
  jq -cn \
    --arg requestId "$request_id" \
    --arg reasonCode "$reason_code" \
    --argjson retryable "$retryable" \
    --arg changesTarget "${changes_target}" \
    --arg label "$label" \
    --argjson argv "$argv_json" \
    '{
      kind: "approval",
      requestId: $requestId,
      reasonCode: $reasonCode,
      retryable: $retryable,
      changesTarget: (if $changesTarget == "" then null else $changesTarget end),
      action: {label: $label, argv: $argv}
    }'
}

# ---------------------------------------------------------------------------
# Public operator-action surface (list / respond / stage request / approvals)
# ---------------------------------------------------------------------------

# workflow_action_capability_rel <stage-id> <attempt-id>
workflow_action_capability_rel() {
  local stage_id="${1:-}" attempt_id="${2:-}" safe
  [[ -n "$stage_id" && -n "$attempt_id" ]] || {
    echo "Error: workflow_action_capability_rel requires stage-id and attempt-id" >&2
    return 1
  }
  safe="$(printf '%s-%s' "$stage_id" "$attempt_id" | tr -c 'A-Za-z0-9._-' '-' | sed 's/-\+/-/g; s/^-//; s/-$//')"
  [[ -n "$safe" ]] || safe="capability"
  printf 'actions/capabilities/%s.json\n' "$safe"
}

# workflow_action_capability_path <registry-run> <stage-id> <attempt-id>
workflow_action_capability_path() {
  local run_dir="${1:-}" stage_id="${2:-}" attempt_id="${3:-}" rel
  rel="$(workflow_action_capability_rel "$stage_id" "$attempt_id")" || return 1
  workflow_action_resolve_path "$run_dir" "$rel"
}

# workflow_action_capability_write <registry-run> <run-id> <stage-id> <attempt-id> [nonce]
# Create-once ephemeral capability. Prints absolute path. Never prints nonce.
workflow_action_capability_write() {
  local run_dir="${1:-}" run_id="${2:-}" stage_id="${3:-}" attempt_id="${4:-}" nonce="${5:-}"
  local rel abs record created_at

  [[ -n "$run_dir" && -d "$run_dir" && -n "$run_id" && -n "$stage_id" && -n "$attempt_id" ]] || {
    echo "Error: workflow_action_capability_write requires registry-run run-id stage-id attempt-id" >&2
    return 1
  }
  if [[ -z "$nonce" ]]; then
    nonce="$(graph_operator_mint_nonce)" || return 1
  fi
  graph_operator_nonce_valid "$nonce" || return 1
  created_at="$(workflow_action_now_iso)"
  record="$(jq -nc \
    --arg runId "$run_id" \
    --arg stageId "$stage_id" \
    --arg attemptId "$attempt_id" \
    --arg nonce "$nonce" \
    --arg createdAt "$created_at" \
    '{runId:$runId,stageId:$stageId,attemptId:$attemptId,nonce:$nonce,createdAt:$createdAt}')" || return 1
  rel="$(workflow_action_capability_rel "$stage_id" "$attempt_id")" || return 1
  abs="$(workflow_action_prepare_write "$run_dir" "$rel" "actions/capabilities/$(basename "$rel")")" || return 1
  graph_operator_create_once_write "$abs" "$record" || return 1
  printf '%s\n' "$abs"
}

# workflow_action_capability_validate <registry-run> <run-id> <stage-id> <attempt-id> <nonce>
# Validates an active attempt-bound capability without printing the nonce.
workflow_action_capability_validate() {
  local run_dir="${1:-}" run_id="${2:-}" stage_id="${3:-}" attempt_id="${4:-}" nonce="${5:-}"
  local abs raw

  [[ -n "$run_dir" && -n "$run_id" && -n "$stage_id" && -n "$attempt_id" && -n "$nonce" ]] || {
    echo "Error: workflow action request requires supervisor-issued run/stage/attempt identity and capability nonce" >&2
    return 1
  }
  graph_operator_nonce_valid "$nonce" || {
    echo "Error: workflow action capability nonce is malformed" >&2
    return 1
  }
  abs="$(workflow_action_capability_path "$run_dir" "$stage_id" "$attempt_id")" || return 1
  if [[ ! -f "$abs" || -L "$abs" ]]; then
    echo "Error: workflow action capability is missing or stale for stage ${stage_id} attempt ${attempt_id}" >&2
    return 1
  fi
  raw="$(jq -c '.' "$abs" 2>/dev/null)" || {
    echo "Error: workflow action capability record is unreadable" >&2
    return 1
  }
  if ! printf '%s' "$raw" | jq -e \
    --arg run "$run_id" --arg stage "$stage_id" --arg attempt "$attempt_id" --arg nonce "$nonce" \
    '.runId == $run and .stageId == $stage and .attemptId == $attempt and .nonce == $nonce' \
    >/dev/null 2>&1; then
    echo "Error: workflow action capability does not match the active run/stage/attempt identity" >&2
    return 1
  fi
  return 0
}

# workflow_action_normalize_row <request-json> [decision-json|null] [consumed-json|null] [source]
# Builds one public list row. Never includes namespace or capability nonce.
workflow_action_normalize_row() {
  local req="${1:-}" decision="${2:-null}" consumed="${3:-null}" source="${4:-common}"
  printf '%s' "$req" | jq -c \
    --argjson decision "$decision" \
    --argjson consumed "$consumed" \
    --arg source "$source" \
    '{
      requestId: (.requestId // .id // ""),
      kind: (.kind // "permission"),
      runId: (.runId // ""),
      stageId: (.stageId // .nodeId // ""),
      attemptId: (.attemptId // ""),
      question: (.question // .reason // null),
      choices: (if (.choices | type) == "array" then .choices else [] end),
      createdAt: (.createdAt // null),
      action: (.action // null),
      resource: (.resource // null),
      effect: (.effect // null),
      runtime: (.runtime // null),
      changesTarget: (.changesTarget // null),
      evidence: (if (.evidence | type) == "array" then .evidence else null end),
      details: (.details // null),
      decision: $decision,
      consumed: $consumed,
      source: $source,
      status: (
        if ($consumed != null) then "consumed"
        elif ($decision != null) then "answered"
        else "outstanding"
        end
      )
    } | with_entries(select(.value != null))'
}

# workflow_action_adapt_graph_permission_rows <graph-run-dir> <run-id>
# Adapts native graph operator/requests into normalized permission rows.
# Omits namespace. Skips records that already exist as common permission rows
# when the caller merges later.
workflow_action_adapt_graph_permission_rows() {
  local graph_run_dir="${1:-}" run_id="${2:-}"
  local req_dir path request_id req decision entry rows='[]'

  [[ -n "$graph_run_dir" && -d "$graph_run_dir" ]] || {
    printf '[]\n'
    return 0
  }
  command -v jq >/dev/null 2>&1 || return 1
  if ! declare -F graph_operator_request_read >/dev/null 2>&1; then
    # shellcheck source=../graph/graph-operator-records.sh
    source "$_WORKFLOW_ACTIONS_SCRIPT_DIR/../graph/graph-operator-records.sh"
  fi

  req_dir="$(graph_logs_resolve "$graph_run_dir" "operator/requests" 2>/dev/null || true)"
  [[ -n "$req_dir" && -d "$req_dir" && ! -L "$req_dir" ]] || {
    printf '[]\n'
    return 0
  }

  shopt -s nullglob
  for path in "$req_dir"/*.json; do
    [[ -f "$path" && ! -L "$path" ]] || continue
    request_id="$(basename "$path" .json)"
    graph_operator_request_id_valid "$request_id" 2>/dev/null || continue
    req="$(graph_operator_request_read "$graph_run_dir" "$request_id" 2>/dev/null)" || continue
    # Force permission kind and common run id; drop namespace.
    req="$(printf '%s' "$req" | jq -c --arg runId "$run_id" --arg rid "$request_id" '
      . + {
        kind: "permission",
        requestId: (.requestId // $rid),
        runId: (if (.runId // "") == "" then $runId else .runId end),
        stageId: (.stageId // .nodeId // ""),
        attemptId: (
          if (.attemptId // "") != "" then .attemptId
          else ((.nodeId // "permission") | tostring) + "-1"
          end
        )
      } | del(.namespace)
    ')"
    decision="null"
    if declare -F graph_operator_decision_read >/dev/null 2>&1; then
      if decision="$(graph_operator_decision_read "$graph_run_dir" "$request_id" 2>/dev/null)"; then
        :
      else
        decision="null"
      fi
    fi
    entry="$(workflow_action_normalize_row "$req" "$decision" "null" "graph-permission")" || continue
    rows="$(jq -nc --argjson rows "$rows" --argjson entry "$entry" '$rows + [$entry]')"
  done
  shopt -u nullglob
  printf '%s\n' "$rows"
}

# workflow_action_list_public <registry-run> <run-id> [mode] [graph-run-dir]
# Normalized request-kind-aware JSON array. Dependency merges adapted graph
# permission records; Sequential lists common records only. Never exposes
# namespace or capability nonce.
workflow_action_list_public() {
  local run_dir="${1:-}" run_id="${2:-}" mode="${3:-}" graph_run_dir="${4:-}"
  local common adapted merged ids

  [[ -n "$run_dir" && -d "$run_dir" && -n "$run_id" ]] || {
    echo "Error: workflow_action_list_public requires registry-run and run-id" >&2
    return 1
  }
  command -v jq >/dev/null 2>&1 || return 1

  common="$(workflow_action_list "$run_dir")" || return 1
  # Re-normalize common rows with status/source and strip any accidental namespace.
  common="$(printf '%s' "$common" | jq -c '
    map(
      . + {source: (.source // "common")}
      | del(.namespace)
      | . + {
          status: (
            if (.consumed != null) then "consumed"
            elif (.decision != null) then "answered"
            else "outstanding"
            end
          )
        }
    )
  ')"

  adapted='[]'
  if [[ "$mode" == "dependency" && -n "$graph_run_dir" && -d "$graph_run_dir" ]]; then
    adapted="$(workflow_action_adapt_graph_permission_rows "$graph_run_dir" "$run_id")" || adapted='[]'
    ids="$(printf '%s' "$common" | jq -c '[.[].requestId]')"
    adapted="$(printf '%s' "$adapted" | jq -c --argjson ids "$ids" '
      map(select(.requestId as $rid | ($ids | index($rid)) == null))
    ')"
  fi

  merged="$(jq -nc --argjson common "$common" --argjson adapted "$adapted" \
    '$common + $adapted | sort_by(.createdAt // "", .requestId)')"
  printf '%s\n' "$merged"
}

# workflow_action_input_request_id <run-id> <stage-id> <attempt-id>
workflow_action_input_request_id() {
  local run_id="${1:-}" stage_id="${2:-}" attempt_id="${3:-}" raw
  [[ -n "$run_id" && -n "$stage_id" && -n "$attempt_id" ]] || {
    echo "Error: workflow_action_input_request_id requires run-id stage-id attempt-id" >&2
    return 1
  }
  raw="inp-${stage_id}-${attempt_id}"
  raw="$(printf '%s' "$raw" | tr -c 'A-Za-z0-9._-' '-' | sed 's/-\+/-/g; s/^-//; s/-$//')"
  [[ -n "$raw" ]] || raw="inp-input"
  if ! graph_operator_request_id_valid "$raw" 2>/dev/null; then
    if command -v sha256sum >/dev/null 2>&1; then
      raw="inp-$(printf '%s' "$run_id:$stage_id:$attempt_id" | sha256sum | awk '{print substr($1,1,24)}')"
    else
      raw="inp-$(printf '%s' "$run_id:$stage_id:$attempt_id" | shasum -a 256 | awk '{print substr($1,1,24)}')"
    fi
  fi
  printf '%s\n' "$raw"
}

# workflow_action_count_outstanding_input <registry-run> <run-id> <stage-id> <attempt-id>
workflow_action_count_outstanding_input() {
  local run_dir="${1:-}" run_id="${2:-}" stage_id="${3:-}" attempt_id="${4:-}"
  local requests_dir path req request_id decision count=0
  requests_dir="$run_dir/actions/requests"
  [[ -d "$requests_dir" && ! -L "$requests_dir" ]] || {
    printf '0\n'
    return 0
  }
  shopt -s nullglob
  for path in "$requests_dir"/*.json; do
    [[ -f "$path" && ! -L "$path" ]] || continue
    req="$(jq -c . "$path" 2>/dev/null)" || continue
    [[ "$(printf '%s' "$req" | jq -r '.kind // empty')" == "input" ]] || continue
    [[ "$(printf '%s' "$req" | jq -r '.runId // empty')" == "$run_id" ]] || continue
    [[ "$(printf '%s' "$req" | jq -r '.stageId // empty')" == "$stage_id" ]] || continue
    [[ "$(printf '%s' "$req" | jq -r '.attemptId // empty')" == "$attempt_id" ]] || continue
    request_id="$(printf '%s' "$req" | jq -r '.requestId // empty')"
    [[ -n "$request_id" ]] || continue
    decision="$(workflow_action_decision_read "$run_dir" "$request_id" 2>/dev/null || true)"
    [[ -z "$decision" ]] || continue
    count=$((count + 1))
  done
  shopt -u nullglob
  printf '%s\n' "$count"
}

# workflow_action_stage_request_create
#   --registry-run --run-id --stage-id --attempt-id --nonce
#   --question <text> [--details <text>]
# Stage-only OPERATOR_INPUT request. Never records or prints the nonce.
# Refuses when identity/capability is missing, stale, spoofed, or when an
# outstanding input already exists for the attempt.
workflow_action_stage_request_create() {
  local registry_run="" run_id="" stage_id="" attempt_id="" nonce="" question="" details=""
  local control_plan="" todo_id="" runtime=""
  local request_id record path outstanding continuation_identity

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --registry-run) registry_run="${2:-}"; shift 2 ;;
      --run-id) run_id="${2:-}"; shift 2 ;;
      --stage-id) stage_id="${2:-}"; shift 2 ;;
      --attempt-id) attempt_id="${2:-}"; shift 2 ;;
      --nonce) nonce="${2:-}"; shift 2 ;;
      --question) question="${2:-}"; shift 2 ;;
      --details) details="${2:-}"; shift 2 ;;
      --control-plan) control_plan="${2:-}"; shift 2 ;;
      --todo-id) todo_id="${2:-}"; shift 2 ;;
      --runtime) runtime="${2:-}"; shift 2 ;;
      *)
        echo "Error: unknown workflow_action_stage_request_create argument: $1" >&2
        return 1
        ;;
    esac
  done

  [[ -n "$registry_run" && -d "$registry_run" && -n "$run_id" && -n "$stage_id" && -n "$attempt_id" ]] || {
    echo "Error: workflow actions request refuses standalone or incomplete identity (requires active workflow run/stage/attempt)" >&2
    return 1
  }
  [[ -n "$nonce" ]] || {
    echo "Error: workflow actions request requires an active attempt-bound capability nonce" >&2
    return 1
  }
  [[ -n "$question" ]] || {
    echo "Error: workflow actions request requires --question <text>" >&2
    return 1
  }

  workflow_action_capability_validate "$registry_run" "$run_id" "$stage_id" "$attempt_id" "$nonce" || return 1

  outstanding="$(workflow_action_count_outstanding_input "$registry_run" "$run_id" "$stage_id" "$attempt_id")"
  if [[ "$outstanding" -ge 1 ]]; then
    echo "Error: at most one outstanding input request is allowed per attempt" >&2
    return 1
  fi

  request_id="$(workflow_action_input_request_id "$run_id" "$stage_id" "$attempt_id")" || return 1
  continuation_identity=""
  if declare -F workflow_action_continuation_build >/dev/null 2>&1; then
    continuation_identity="$(workflow_action_continuation_build \
      --control-plan "$control_plan" --todo-id "$todo_id" --runtime "$runtime" 2>/dev/null || true)"
  fi
  record="$(jq -nc \
    --arg requestId "$request_id" \
    --arg runId "$run_id" \
    --arg stageId "$stage_id" \
    --arg attemptId "$attempt_id" \
    --arg question "$question" \
    --arg details "$details" \
    --arg createdAt "$(workflow_action_now_iso)" \
    --argjson continuationIdentity "${continuation_identity:-null}" \
    '{
      requestId: $requestId,
      kind: "input",
      runId: $runId,
      stageId: $stageId,
      attemptId: $attemptId,
      choices: ["answer","cancel"],
      createdAt: $createdAt,
      question: $question
    } + (if $details == "" then {details:null} else {details:$details} end)
      + (if $continuationIdentity == null then {} else {continuationIdentity:$continuationIdentity} end)')" || return 1

  # Bound/credential rejection happens inside request_write; nonce must stay out.
  path="$(workflow_action_request_write "$registry_run" "$record")" || return 1
  if jq -e 'has("nonce")' "$path" >/dev/null 2>&1; then
    echo "Error: input request must not persist a nonce" >&2
    return 1
  fi
  printf '%s\n' "$request_id"
}

# workflow_action_respond_next_action <kind> <decision> <run-id> [changes-target]
# Prints a single next-action guidance line for stdout after a successful respond.
workflow_action_respond_next_action() {
  local kind="${1:-}" decision="${2:-}" run_id="${3:-}" changes_target="${4:-}"
  case "$kind:$decision" in
    approval:approve|input:answer|permission:allow-once|permission:allow-run|permission:allow-always|permission:deny)
      printf 'Next: ralph workflow resume %s\n' "$run_id"
      ;;
    approval:request-changes)
      printf 'Next: ralph workflow reset %s --stage %s\n' "$run_id" "$changes_target"
      ;;
    approval:cancel|input:cancel)
      printf 'Next: none (run cancelled)\n'
      ;;
    *)
      printf 'Next: ralph workflow actions list %s\n' "$run_id"
      ;;
  esac
}

# workflow_action_respond_persist
#   --registry-run --run-id --request-id --decision [--message] [--actor-source]
#   [--graph-run-dir] [--mode] [--state-root]
# Resolves the exact common request, validates decision/message against kind,
# persists once, and prints JSON outcome with nextAction fields.
workflow_action_respond_persist() {
  local registry_run="" run_id="" request_id="" decision="" message="" actor_source="cli"
  local graph_run_dir="" mode="" state_root=""
  local req kind choices changes_target decision_json decision_path next_label next_argv
  local outcome_json grant_fields=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --registry-run) registry_run="${2:-}"; shift 2 ;;
      --run-id) run_id="${2:-}"; shift 2 ;;
      --request-id) request_id="${2:-}"; shift 2 ;;
      --decision) decision="${2:-}"; shift 2 ;;
      --message) message="${2:-}"; shift 2 ;;
      --actor-source) actor_source="${2:-}"; shift 2 ;;
      --graph-run-dir) graph_run_dir="${2:-}"; shift 2 ;;
      --mode) mode="${2:-}"; shift 2 ;;
      --state-root) state_root="${2:-}"; shift 2 ;;
      *)
        echo "Error: unknown workflow_action_respond_persist argument: $1" >&2
        return 1
        ;;
    esac
  done

  [[ -n "$registry_run" && -d "$registry_run" && -n "$run_id" && -n "$request_id" && -n "$decision" ]] || {
    echo "Error: workflow_action_respond_persist requires registry-run run-id request-id decision" >&2
    return 1
  }
  graph_operator_request_id_valid "$request_id" || return 1

  if req="$(workflow_action_request_read "$registry_run" "$request_id" 2>/dev/null)"; then
    kind="$(printf '%s' "$req" | jq -r '.kind // empty')"
    [[ "$(printf '%s' "$req" | jq -r '.runId // empty')" == "$run_id" ]] || {
      echo "Error: request $request_id does not belong to run $run_id" >&2
      return 1
    }
    changes_target="$(printf '%s' "$req" | jq -r '.changesTarget // empty')"
    decision_json="$(jq -nc \
      --arg requestId "$request_id" \
      --arg kind "$kind" \
      --arg runId "$run_id" \
      --arg stageId "$(printf '%s' "$req" | jq -r '.stageId // empty')" \
      --arg attemptId "$(printf '%s' "$req" | jq -r '.attemptId // empty')" \
      --arg decision "$decision" \
      --arg message "$message" \
      --arg actorSource "$actor_source" \
      --arg decidedAt "$(workflow_action_now_iso)" \
      --arg nonce "$(printf '%s' "$req" | jq -r '.nonce // empty')" \
      --arg runtime "$(printf '%s' "$req" | jq -r '.runtime // empty')" \
      '{
        requestId:$requestId, kind:$kind, runId:$runId, stageId:$stageId,
        attemptId:$attemptId, decision:$decision, actorSource:$actorSource,
        decidedAt:$decidedAt
      }
      + (if $message == "" then {message:null} else {message:$message} end)
      + (if $kind == "permission" then {nonce:$nonce, runtime:$runtime} else {} end)')"
    decision_path="$(workflow_action_decision_write "$registry_run" "$decision_json")" || return 1
  elif [[ "$mode" == "dependency" && -n "$graph_run_dir" && -d "$graph_run_dir" ]] \
    && declare -F graph_operator_request_read >/dev/null 2>&1 \
    && req="$(graph_operator_request_read "$graph_run_dir" "$request_id" 2>/dev/null)"; then
    kind="permission"
    choices="$(printf '%s' "$req" | jq -c '.choices // ["allow-once","allow-run","allow-always","deny"]')"
    if ! printf '%s' "$choices" | jq -e --arg d "$decision" 'index($d) != null' >/dev/null 2>&1; then
      echo "Error: malformed workflow action decision choice: $decision" >&2
      return 1
    fi
    decision_json="$(jq -nc \
      --arg requestId "$request_id" \
      --arg nonce "$(printf '%s' "$req" | jq -r '.nonce // empty')" \
      --arg decision "$decision" \
      --arg actorSource "$actor_source" \
      '{requestId:$requestId,nonce:$nonce,decision:$decision,actorSource:$actorSource}')"
    decision_path="$(graph_operator_decision_write "$graph_run_dir" "$decision_json")" || return 1
    if [[ "$decision" == "allow-run" || "$decision" == "allow-always" ]]; then
      if ! declare -F graph_approval_run_rule_write >/dev/null 2>&1; then
        # shellcheck source=../graph/graph-approval-policy.sh
        source "$_WORKFLOW_ACTIONS_SCRIPT_DIR/../graph/graph-approval-policy.sh"
      fi
      if [[ "$decision" == "allow-run" ]]; then
        graph_approval_run_rule_write "$graph_run_dir" "$(jq -nc \
          --arg requestId "$request_id" \
          --arg runtime "$(printf '%s' "$req" | jq -r '.runtime // empty')" \
          --arg action "$(printf '%s' "$req" | jq -r '.action // empty')" \
          --arg resource "$(printf '%s' "$req" | jq -r '.resource // empty')" \
          --arg effect "$(printf '%s' "$req" | jq -r '.effect // empty')" \
          --arg decision "allow-run" \
          '{requestId:$requestId,runtime:$runtime,action:$action,resource:$resource,effect:$effect,decision:$decision}')" >/dev/null || true
      fi
    fi
  else
    echo "Error: workflow action request not found for common run ID $run_id: $request_id" >&2
    return 1
  fi

  case "$kind:$decision" in
    approval:request-changes)
      [[ -n "$message" ]] || {
        echo "Error: request-changes requires a non-empty --message" >&2
        return 1
      }
      if [[ "$mode" == "sequential" ]] && declare -F workflow_seq_approval_apply_decision >/dev/null 2>&1; then
        workflow_seq_approval_apply_decision \
          --registry-run "$registry_run" --request-id "$request_id" --run-id "$run_id" \
          ${state_root:+--state-root "$state_root"} >/dev/null || true
      elif [[ "$mode" == "dependency" ]] && declare -F workflow_dep_approval_apply_decision >/dev/null 2>&1; then
        workflow_dep_approval_apply_decision \
          --registry-run "$registry_run" --request-id "$request_id" --run-id "$run_id" \
          ${state_root:+--state-root "$state_root"} >/dev/null || true
      elif [[ -n "$state_root" ]] && declare -F workflow_state_clear_owner_and_set_state >/dev/null 2>&1; then
        workflow_state_clear_owner_and_set_state "$state_root" "$run_id" blocked || true
      fi
      next_label="Reset changes target"
      next_argv="$(jq -cn --arg rid "$run_id" --arg stage "$changes_target" \
        '["ralph","workflow","reset",$rid,"--stage",$stage]')"
      ;;
    approval:cancel|input:cancel)
      if [[ -n "$state_root" ]] && declare -F workflow_state_record_cancel_intent >/dev/null 2>&1; then
        workflow_state_record_cancel_intent "$registry_run" "$(jq -nc \
          --arg rid "$request_id" --arg runId "$run_id" --arg choice "$decision" \
          '{requestId:$rid,runId:$runId,decision:$choice,source:"actions-respond"}')" >/dev/null || true
        workflow_state_clear_owner_and_set_state "$state_root" "$run_id" cancelled || true
      fi
      next_label="none"
      next_argv='[]'
      ;;
    approval:approve|input:answer|permission:*)
      if [[ "$kind" == "input" && "$decision" == "answer" && -n "$state_root" ]] \
        && declare -F workflow_state_clear_owner_and_set_state >/dev/null 2>&1; then
        # Answered input becomes retryable waiting; resume is the next action.
        workflow_state_clear_owner_and_set_state "$state_root" "$run_id" waiting || true
      fi
      next_label="Resume workflow run"
      next_argv="$(jq -cn --arg rid "$run_id" '["ralph","workflow","resume",$rid]')"
      ;;
    *)
      next_label="List actions"
      next_argv="$(jq -cn --arg rid "$run_id" '["ralph","workflow","actions","list",$rid]')"
      ;;
  esac

  outcome_json="$(jq -nc \
    --arg runId "$run_id" \
    --arg requestId "$request_id" \
    --arg kind "$kind" \
    --arg decision "$decision" \
    --arg path "$decision_path" \
    --arg label "$next_label" \
    --argjson argv "$next_argv" \
    --arg changesTarget "${changes_target}" \
    '{
      schemaVersion: 1,
      runId: $runId,
      requestId: $requestId,
      kind: $kind,
      decision: $decision,
      path: $path,
      nextAction: (if $label == "none" then null else {label:$label, argv:$argv} end),
      changesTarget: (if $changesTarget == "" then null else $changesTarget end)
    }')"
  printf '%s\n' "$outcome_json"
}

# ---------------------------------------------------------------------------
# OPERATOR_INPUT protocol + attempt capability binding for ordinary stages
# ---------------------------------------------------------------------------

# workflow_action_operator_input_protocol_body
# Plain protocol guidance (no delimiters, no nonce). Shared by prompts and
# generated-plan instructions.
workflow_action_operator_input_protocol_body() {
  cat <<'EOF'
Continue autonomously through ordinary implementation choices supported by repository evidence.
When a missing product decision, unavailable credential configuration, external fact, or mutually exclusive requirement makes safe progress impossible:
1. Call `ralph workflow actions request --question <text> [--details <text>]`
2. Stop without completing the TODO and do not guess.
Credential questions must ask the operator to configure a named environment or native secret source and reply when ready; never request the secret value.
Standalone plans cannot create workflow requests; this protocol applies only under an active workflow-owned stage with supervisor-issued identity.
EOF
}

# workflow_action_operator_input_protocol_block
# One delimited OPERATOR_INPUT block for prompts/generated plans. Never includes nonce.
workflow_action_operator_input_protocol_block() {
  printf '%s\n' "<!-- OPERATOR_INPUT: START -->"
  workflow_action_operator_input_protocol_body
  printf '%s\n' "<!-- OPERATOR_INPUT: END -->"
}

# workflow_action_operator_input_response_block <registry-run> <request-id>
# Reads a staged injection (or builds from request+decision) and prints the
# delimited OPERATOR_INPUT_RESPONSE block. Never includes nonce.
workflow_action_operator_input_response_block() {
  local run_dir="${1:-}" request_id="${2:-}" inj
  [[ -n "$run_dir" && -n "$request_id" ]] || {
    echo "Error: workflow_action_operator_input_response_block requires registry-run and request-id" >&2
    return 1
  }
  inj="$(workflow_action_injection_path "$run_dir" "$request_id" 2>/dev/null || true)"
  if [[ -n "$inj" && -f "$inj" && ! -L "$inj" ]]; then
    cat -- "$inj"
    return 0
  fi
  # Fall back to staging then reading (create-once).
  inj="$(workflow_action_stage_input_injection "$run_dir" "$request_id")" || return 1
  cat -- "$inj"
}

# workflow_action_count_answered_unconsumed_input <registry-run> <run-id> <stage-id> <attempt-id>
# Counts kind=input requests for this attempt that have an answer decision but
# no consumption record yet.
workflow_action_count_answered_unconsumed_input() {
  local run_dir="${1:-}" run_id="${2:-}" stage_id="${3:-}" attempt_id="${4:-}"
  local requests_dir path req request_id decision consumed count=0
  requests_dir="$run_dir/actions/requests"
  [[ -d "$requests_dir" && ! -L "$requests_dir" ]] || {
    printf '0\n'
    return 0
  }
  shopt -s nullglob
  for path in "$requests_dir"/*.json; do
    [[ -f "$path" && ! -L "$path" ]] || continue
    req="$(jq -c . "$path" 2>/dev/null)" || continue
    [[ "$(printf '%s' "$req" | jq -r '.kind // empty')" == "input" ]] || continue
    [[ "$(printf '%s' "$req" | jq -r '.runId // empty')" == "$run_id" ]] || continue
    [[ "$(printf '%s' "$req" | jq -r '.stageId // empty')" == "$stage_id" ]] || continue
    [[ "$(printf '%s' "$req" | jq -r '.attemptId // empty')" == "$attempt_id" ]] || continue
    request_id="$(printf '%s' "$req" | jq -r '.requestId // empty')"
    [[ -n "$request_id" ]] || continue
    decision="$(workflow_action_decision_read "$run_dir" "$request_id" 2>/dev/null || true)"
    [[ -n "$decision" ]] || continue
    [[ "$(printf '%s' "$decision" | jq -r '.decision // empty')" == "answer" ]] || continue
    consumed="$(workflow_action_consumed_read "$run_dir" "$request_id" 2>/dev/null || true)"
    [[ -z "$consumed" ]] || continue
    count=$((count + 1))
  done
  shopt -u nullglob
  printf '%s\n' "$count"
}

# workflow_action_attempt_blocks_success <registry-run> <run-id> <stage-id> <attempt-id>
# Returns 0 when outstanding or answered-unconsumed input exists (success must
# be refused). Returns 1 when success is allowed.
workflow_action_attempt_blocks_success() {
  local run_dir="${1:-}" run_id="${2:-}" stage_id="${3:-}" attempt_id="${4:-}"
  local outstanding unconsumed
  outstanding="$(workflow_action_count_outstanding_input "$run_dir" "$run_id" "$stage_id" "$attempt_id")"
  unconsumed="$(workflow_action_count_answered_unconsumed_input "$run_dir" "$run_id" "$stage_id" "$attempt_id")"
  if [[ "${outstanding:-0}" -ge 1 || "${unconsumed:-0}" -ge 1 ]]; then
    return 0
  fi
  return 1
}

# workflow_action_input_blocker_json
#   --request-id ... --run-id ... [--retryable true|false]
# Durable blocker for outstanding operator input (non-retryable by default).
workflow_action_input_blocker_json() {
  local request_id="" run_id="" retryable="false" label argv_json
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --request-id) request_id="${2:-}"; shift 2 ;;
      --run-id) run_id="${2:-}"; shift 2 ;;
      --retryable) retryable="${2:-}"; shift 2 ;;
      *)
        echo "Error: unknown workflow_action_input_blocker_json argument: $1" >&2
        return 1
        ;;
    esac
  done
  [[ -n "$request_id" && -n "$run_id" ]] || {
    echo "Error: workflow_action_input_blocker_json requires --request-id and --run-id" >&2
    return 1
  }
  case "$retryable" in true|false) ;; *)
    echo "Error: retryable must be true or false" >&2
    return 1
    ;;
  esac
  label="List actions"
  argv_json="$(jq -cn --arg rid "$run_id" '["ralph","workflow","actions","list",$rid]')"
  jq -nc \
    --arg requestId "$request_id" \
    --arg runId "$run_id" \
    --argjson retryable "$retryable" \
    --arg label "$label" \
    --argjson argv "$argv_json" \
    '{
      kind: "input",
      requestId: $requestId,
      reasonCode: "operator-input",
      retryable: $retryable,
      changesTarget: null,
      action: {label: $label, argv: $argv}
    }'
}

# workflow_action_prepare_attempt_capability_env
#   --registry-run --run-id --stage-id --attempt-id
# Creates a contained attempt-bound capability (or reuses the active path),
# exports identity + capability path + nonce into the current shell environment
# for the CLI request path, and prints only the capability path.
# Never prints the nonce to stdout/stderr.
workflow_action_prepare_attempt_capability_env() {
  local registry_run="" run_id="" stage_id="" attempt_id="" path nonce
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --registry-run) registry_run="${2:-}"; shift 2 ;;
      --run-id) run_id="${2:-}"; shift 2 ;;
      --stage-id) stage_id="${2:-}"; shift 2 ;;
      --attempt-id) attempt_id="${2:-}"; shift 2 ;;
      *)
        echo "Error: unknown workflow_action_prepare_attempt_capability_env argument: $1" >&2
        return 1
        ;;
    esac
  done
  [[ -n "$registry_run" && -d "$registry_run" && -n "$run_id" && -n "$stage_id" && -n "$attempt_id" ]] || {
    echo "Error: workflow_action_prepare_attempt_capability_env requires registry-run run-id stage-id attempt-id" >&2
    return 1
  }

  path="$(workflow_action_capability_path "$registry_run" "$stage_id" "$attempt_id" 2>/dev/null || true)"
  if [[ -z "$path" || ! -f "$path" || -L "$path" ]]; then
    path="$(workflow_action_capability_write "$registry_run" "$run_id" "$stage_id" "$attempt_id")" || return 1
  fi
  nonce="$(jq -r '.nonce // empty' "$path" 2>/dev/null || true)"
  if [[ -z "$nonce" ]]; then
    echo "Error: workflow action capability is missing a nonce" >&2
    return 1
  fi

  export RALPH_WORKFLOW_REGISTRY_RUN="$registry_run"
  export RALPH_WORKFLOW_RUN_ID="$run_id"
  export RALPH_WORKFLOW_STAGE_ID="$stage_id"
  export RALPH_WORKFLOW_STAGE_ATTEMPT="$attempt_id"
  export RALPH_WORKFLOW_ACTION_CAPABILITY="$path"
  # Nonce stays in process env for the request CLI only; never log/print it.
  export RALPH_WORKFLOW_ACTION_NONCE="$nonce"

  printf '%s\n' "$path"
}

# workflow_action_clear_attempt_capability_env
# Unsets exported capability/identity env vars without printing nonce.
workflow_action_clear_attempt_capability_env() {
  unset RALPH_WORKFLOW_ACTION_CAPABILITY RALPH_WORKFLOW_ACTION_NONCE 2>/dev/null || true
}

# workflow_action_find_pending_input_request_id <registry-run> <run-id> <stage-id> <attempt-id>
# Prints the first outstanding or answered-unconsumed input request id for the
# attempt, or empty when none.
workflow_action_find_pending_input_request_id() {
  local run_dir="${1:-}" run_id="${2:-}" stage_id="${3:-}" attempt_id="${4:-}"
  local requests_dir path req request_id decision consumed
  requests_dir="$run_dir/actions/requests"
  [[ -d "$requests_dir" && ! -L "$requests_dir" ]] || return 0
  shopt -s nullglob
  for path in "$requests_dir"/*.json; do
    [[ -f "$path" && ! -L "$path" ]] || continue
    req="$(jq -c . "$path" 2>/dev/null)" || continue
    [[ "$(printf '%s' "$req" | jq -r '.kind // empty')" == "input" ]] || continue
    [[ "$(printf '%s' "$req" | jq -r '.runId // empty')" == "$run_id" ]] || continue
    [[ "$(printf '%s' "$req" | jq -r '.stageId // empty')" == "$stage_id" ]] || continue
    [[ "$(printf '%s' "$req" | jq -r '.attemptId // empty')" == "$attempt_id" ]] || continue
    request_id="$(printf '%s' "$req" | jq -r '.requestId // empty')"
    [[ -n "$request_id" ]] || continue
    decision="$(workflow_action_decision_read "$run_dir" "$request_id" 2>/dev/null || true)"
    if [[ -z "$decision" ]]; then
      shopt -u nullglob
      printf '%s\n' "$request_id"
      return 0
    fi
    if [[ "$(printf '%s' "$decision" | jq -r '.decision // empty')" == "answer" ]]; then
      consumed="$(workflow_action_consumed_read "$run_dir" "$request_id" 2>/dev/null || true)"
      if [[ -z "$consumed" ]]; then
        shopt -u nullglob
        printf '%s\n' "$request_id"
        return 0
      fi
    fi
  done
  shopt -u nullglob
  return 0
}

# ralph_workflow_active_for_operator_input
# True when supervisor-issued workflow identity is present (not standalone).
ralph_workflow_active_for_operator_input() {
  [[ -n "${RALPH_WORKFLOW_REGISTRY_RUN:-}" && -d "${RALPH_WORKFLOW_REGISTRY_RUN}" \
    && -n "${RALPH_WORKFLOW_RUN_ID:-}" \
    && -n "${RALPH_WORKFLOW_STAGE_ID:-}" \
    && -n "${RALPH_WORKFLOW_STAGE_ATTEMPT:-}" ]]
}

