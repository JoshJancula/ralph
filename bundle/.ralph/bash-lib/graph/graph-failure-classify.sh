#!/usr/bin/env bash
# Pure graph failure classifier.
#
# Maps a structured runner/supervisor report to one of the supported classes
# plus retryability, an operator action, and a bounded human summary.
# Structured fields always win. Bounded text matching runs only when
# those classifying fields are absent. A successful report is never reclassified
# as a failure because its text contains words such as permission, denied, or
# error. Summaries are redacted for credential-looking text and length-capped.
#
# Supported classifications:
#   transient-runtime, agent-correctable, operator-permission, plan-contract,
#   terminal-configuration, integrity, cancelled, unknown
#
# Output is one compact JSON object:
#   {classification, retryable, operatorAction, summary}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  echo "This file is meant to be sourced, not executed." >&2
  exit 1
fi

if [[ -n "${GRAPH_FAILURE_CLASSIFY_LOADED:-}" ]]; then
  return 0
fi
GRAPH_FAILURE_CLASSIFY_LOADED=1

# Maximum summary length in characters. Tests may override.
GRAPH_FAILURE_SUMMARY_MAX="${GRAPH_FAILURE_SUMMARY_MAX:-200}"
# Maximum characters of free text scanned by the text fallback.
GRAPH_FAILURE_TEXT_MAX="${GRAPH_FAILURE_TEXT_MAX:-2048}"

GRAPH_FAILURE_KNOWN_CLASSES='transient-runtime
agent-correctable
operator-permission
plan-contract
terminal-configuration
integrity
cancelled
unknown'

# graph_failure_normalize_token <value>
# Lowercase and map underscores to hyphens for structured token compares.
graph_failure_normalize_token() {
  printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]' | tr '_' '-'
}

# graph_failure_is_known_class <class>
graph_failure_is_known_class() {
  local class="$1" candidate
  [[ -n "$class" ]] || return 1
  while IFS= read -r candidate; do
    [[ "$candidate" == "$class" ]] && return 0
  done <<< "$GRAPH_FAILURE_KNOWN_CLASSES"
  return 1
}

# graph_failure_map_kind <token>
# Maps a structured kind/category/reason token onto a known class.
# Returns 1 when the token is not a recognized structured value.
graph_failure_map_kind() {
  local token
  token="$(graph_failure_normalize_token "$1")"
  [[ -n "$token" ]] || return 1
  case "$token" in
    transient-runtime|transient|network|provider|session|session-interrupt|timeout|timed-out|rate-limit|ratelimit)
      printf 'transient-runtime\n'
      ;;
    agent-correctable|verification|verification-failed|artifact|missing-artifact|required-artifact-missing|correctable-scope|correctable|internal-plan-incomplete|artifact-publish-failed|changeset-verification-failed|composite-success-failed)
      printf 'agent-correctable\n'
      ;;
    operator-permission|permission|permission-request|approval|approval-rejected)
      printf 'operator-permission\n'
      ;;
    plan-contract|undeclared-path|undeclared|undeclared-changed-leaf|write-scope-mismatch|graph-contract|graph-contract-write-scope-mismatch)
      printf 'plan-contract\n'
      ;;
    terminal-configuration|configuration|auth|invalid-auth|authentication|model|invalid-model|schema|invalid-schema|workspace-policy-not-frozen)
      printf 'terminal-configuration\n'
      ;;
    integrity|sandbox|sandbox-violation|control-path|control-paths|symlink-escape|unsafe-symlink)
      printf 'integrity\n'
      ;;
    cancelled|canceled|interrupt|interrupted|signal)
      printf 'cancelled\n'
      ;;
    unknown)
      printf 'unknown\n'
      ;;
    *)
      return 1
      ;;
  esac
}

# graph_failure_retryable <class>
graph_failure_retryable() {
  case "$1" in
    transient-runtime|agent-correctable) printf 'true\n' ;;
    *) printf 'false\n' ;;
  esac
}

# graph_failure_operator_action <class>
graph_failure_operator_action() {
  case "$1" in
    operator-permission) printf 'await-operator\n' ;;
    plan-contract) printf 'repair-plan\n' ;;
    terminal-configuration) printf 'fix-configuration\n' ;;
    unknown) printf 'inspect\n' ;;
    *) printf 'none\n' ;;
  esac
}

# graph_failure_default_summary <class>
graph_failure_default_summary() {
  case "$1" in
    transient-runtime) printf 'transient runtime interruption\n' ;;
    agent-correctable) printf 'agent-correctable completion failure\n' ;;
    operator-permission) printf 'operator permission required\n' ;;
    plan-contract) printf 'plan contract violation\n' ;;
    terminal-configuration) printf 'terminal configuration error\n' ;;
    integrity) printf 'integrity or sandbox violation\n' ;;
    cancelled) printf 'cancelled\n' ;;
    *) printf 'unclassified failure\n' ;;
  esac
}

# graph_failure_bound_summary <text>
# Truncates to GRAPH_FAILURE_SUMMARY_MAX characters, appending "..." when cut.
graph_failure_bound_summary() {
  local text="${1:-}" max="${GRAPH_FAILURE_SUMMARY_MAX:-200}" ellipsis="..." keep
  if [[ ! "$max" =~ ^[0-9]+$ ]] || [[ "$max" -lt 1 ]]; then
    max=200
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

# graph_failure_bound_text <text>
# Collapses whitespace and caps the text-scan window.
graph_failure_bound_text() {
  local text="${1:-}" max="${GRAPH_FAILURE_TEXT_MAX:-2048}"
  if [[ ! "$max" =~ ^[0-9]+$ ]] || [[ "$max" -lt 1 ]]; then
    max=2048
  fi
  text="$(printf '%s' "$text" | tr '\n\r\t' ' ' | tr -s ' ')"
  text="${text# }"
  text="${text% }"
  if [[ "${#text}" -le "$max" ]]; then
    printf '%s\n' "$text"
    return 0
  fi
  printf '%s\n' "${text:0:$max}"
}

# graph_failure_redact_text <text>
# Replaces credential-looking assignments and common token shapes with [REDACTED].
graph_failure_redact_text() {
  local text="${1:-}"
  if [[ -z "$text" ]]; then
    printf '\n'
    return 0
  fi
  if command -v python3 >/dev/null 2>&1; then
    printf '%s' "$text" | python3 -c '
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
'
    printf '\n'
    return 0
  fi
  printf '%s\n' "$text" | sed -E \
    -e 's/(password|passwd|secret|token|api[_-]?key|api_key|api-key|private[_-]?key|bearer|authorization|credential)[[:space:]]*[=:][[:space:]]*[^[:space:]]+/[REDACTED]/g' \
    -e 's/sk-[A-Za-z0-9_-]{8,}/[REDACTED]/g' \
    -e 's/AKIA[0-9A-Z]{8,}/[REDACTED]/g' \
    -e 's/ghp_[A-Za-z0-9]{20,}/[REDACTED]/g'
}

# graph_failure_is_success_outcome <token>
graph_failure_is_success_outcome() {
  local token
  token="$(graph_failure_normalize_token "$1")"
  case "$token" in
    succeeded|success|successful|passed|ok|completed) return 0 ;;
    *) return 1 ;;
  esac
}

# graph_failure_match_text <text>
# Phrase matching for unstructured reports. Returns 1 when nothing matches.
graph_failure_match_text() {
  local text
  text="$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]')"
  [[ -n "$text" ]] || return 1

  case "$text" in
    *'permission denied'*|*'permission request'*|*'not permitted'*|*'access denied'*|*'requires approval'*|*'approval required'*|*'awaiting permission'*)
      printf 'operator-permission\n'
      return 0
      ;;
  esac
  case "$text" in
    *'sandbox violation'*|*'symlink escape'*|*'unsafe symlink'*|*'control path'*)
      printf 'integrity\n'
      return 0
      ;;
  esac
  case "$text" in
    *'undeclared path'*|*'undeclared-path'*|*'write scope'*|*'write-scope'*|*'out of scope'*|*'graph contract'*)
      printf 'plan-contract\n'
      return 0
      ;;
  esac
  case "$text" in
    *'authentication_error'*|*'authentication error'*|*'invalid auth'*|*'invalid model'*|*'invalid schema'*|*'not authenticated'*)
      printf 'terminal-configuration\n'
      return 0
      ;;
  esac
  # A runtime that cannot bring up its required MCP servers never starts a
  # session, so the node dies before the agent runs a single turn. Retrying the
  # same node with the same configuration fails identically, which makes this
  # configuration rather than transient -- and it must be matched before the
  # transient block below, whose "connection" phrases would otherwise claim the
  # handshake text and advertise a pointless retry.
  case "$text" in
    *'mcp servers failed to initialize'*|*'failed to initialize session'*|\
    *'handshaking with mcp server'*|*'mcp server failed'*)
      printf 'terminal-configuration\n'
      return 0
      ;;
  esac
  case "$text" in
    *'verification failed'*|*'artifact missing'*|*'missing artifact'*|*'required artifact'*|*'changeset verification'*)
      printf 'agent-correctable\n'
      return 0
      ;;
  esac
  case "$text" in
    *'connection reset'*|*econnreset*|*econnrefused*|*'timed out'*|*timeout*|*'rate limit'*|*'too many requests'*|*'temporarily unavailable'*|*'socket hang'*)
      printf 'transient-runtime\n'
      return 0
      ;;
  esac
  case "$text" in
    *cancelled*|*canceled*|*interrupted*|*'received signal'*)
      printf 'cancelled\n'
      return 0
      ;;
  esac
  return 1
}

# graph_failure_reason_token <reason>
# Returns the structured token from a reason field: the full value when it is
# already a known token, otherwise the prefix before ":" or "=".
graph_failure_reason_token() {
  local reason="${1:-}" prefix
  [[ -n "$reason" ]] || return 1
  if graph_failure_map_kind "$reason" >/dev/null; then
    printf '%s\n' "$reason"
    return 0
  fi
  prefix="${reason%%:*}"
  prefix="${prefix%%=*}"
  [[ -n "$prefix" ]] || return 1
  printf '%s\n' "$prefix"
}

# graph_failure_emit <class> <summary>
graph_failure_emit() {
  local class="$1" summary="$2" retryable action
  if ! graph_failure_is_known_class "$class"; then
    class="unknown"
  fi
  retryable="$(graph_failure_retryable "$class")"
  action="$(graph_failure_operator_action "$class")"
  if [[ -z "$summary" ]]; then
    summary="$(graph_failure_default_summary "$class")"
  fi
  summary="$(graph_failure_redact_text "$summary")"
  summary="$(graph_failure_bound_summary "$summary")"
  jq -nc \
    --arg classification "$class" \
    --argjson retryable "$retryable" \
    --arg operatorAction "$action" \
    --arg summary "$summary" \
    '{classification:$classification,retryable:$retryable,operatorAction:$operatorAction,summary:$summary}'
}

# graph_failure_classify <report-json-or-path>
# Pure classifier. Accepts a JSON object string or a file containing one.
# Always prints a classification object; unparseable input is unknown.
graph_failure_classify() {
  local input="${1:-}" report="" extracted class="" kind="" outcome="" exit_code=""
  local reason="" summary="" component="" mapped="" reason_token="" extra_text=""
  local structured_present=0 is_success="false" fallback_text=""

  if [[ "$input" == \{* || "$input" == \[* ]]; then
    report="$input"
  elif [[ -n "$input" && -f "$input" ]]; then
    report="$(cat -- "$input" 2>/dev/null || true)"
  else
    report="$input"
  fi

  if [[ -z "$report" ]]; then
    graph_failure_emit "unknown" "empty report"
    return 0
  fi
  if ! command -v jq >/dev/null 2>&1; then
    graph_failure_emit "unknown" "jq is required to classify a structured report"
    return 0
  fi
  if ! printf '%s' "$report" | jq -e 'type == "object"' >/dev/null 2>&1; then
    graph_failure_emit "unknown" "unparseable structured report"
    return 0
  fi

  extracted="$(printf '%s' "$report" | jq -c '
    {
      class: ((.class // .classification // .failure.classification // "") | tostring),
      kind: ((.kind // .category // .failureKind // .failureClass // .failure.cause // "") | tostring),
      outcome: ((.outcome // "") | tostring),
      exitCode: (.exitCode // null),
      reason: ((.reason // .failure.cause // "") | tostring),
      summary: ((.summary // .message // .failure.summary // "") | tostring),
      component: ((.component // .completionComponent // .failure.cause // "") | tostring),
      text: ((.text // .output // .stderr // .stdout // .error // .detail // "") | tostring),
      isSuccess: ((.success == true) or (.ok == true)),
      hasPermissionRequest: (
        ((.permissionRequest | type) == "object") or
        ((.failure.permissionRequest | type) == "object")
      ),
      hasOutOfScope: (
        ((.outOfScope // []) | length) +
        ((.undeclaredPaths // []) | length) +
        ((.mismatch // []) | length) +
        ((.failure.offendingPaths // []) | length) > 0
      ),
      hasControlPaths: (((.controlPaths // []) | length) > 0),
      sandboxViolation: (
        (.sandboxViolation == true) or
        (.integrityViolation == true)
      )
    }
  ' 2>/dev/null)" || extracted=""

  if [[ -z "$extracted" ]]; then
    graph_failure_emit "unknown" "unparseable structured report"
    return 0
  fi

  class="$(printf '%s' "$extracted" | jq -r '.class')"
  kind="$(printf '%s' "$extracted" | jq -r '.kind')"
  outcome="$(printf '%s' "$extracted" | jq -r '.outcome')"
  exit_code="$(printf '%s' "$extracted" | jq -r '.exitCode | if . == null then "" else tostring end')"
  reason="$(printf '%s' "$extracted" | jq -r '.reason')"
  summary="$(printf '%s' "$extracted" | jq -r '.summary')"
  component="$(printf '%s' "$extracted" | jq -r '.component')"
  extra_text="$(printf '%s' "$extracted" | jq -r '.text')"
  is_success="$(printf '%s' "$extracted" | jq -r '.isSuccess')"

  if [[ -n "$class" || -n "$kind" || -n "$component" ]]; then
    structured_present=1
  fi
  if [[ "$(printf '%s' "$extracted" | jq -r '.hasPermissionRequest')" == "true" ]] || \
     [[ "$(printf '%s' "$extracted" | jq -r '.hasOutOfScope')" == "true" ]] || \
     [[ "$(printf '%s' "$extracted" | jq -r '.hasControlPaths')" == "true" ]] || \
     [[ "$(printf '%s' "$extracted" | jq -r '.sandboxViolation')" == "true" ]]; then
    structured_present=1
  fi

  class="$(graph_failure_normalize_token "$class")"
  if graph_failure_is_known_class "$class"; then
    graph_failure_emit "$class" "$summary"
    return 0
  fi
  class=""

  if mapped="$(graph_failure_map_kind "$kind")"; then
    graph_failure_emit "$mapped" "$summary"
    return 0
  fi

  outcome="$(graph_failure_normalize_token "$outcome")"
  if [[ "$outcome" == "cancelled" || "$outcome" == "canceled" ]]; then
    graph_failure_emit "cancelled" "$summary"
    return 0
  fi

  if [[ "$exit_code" == "4" ]] || [[ "$(printf '%s' "$extracted" | jq -r '.hasPermissionRequest')" == "true" ]]; then
    graph_failure_emit "operator-permission" "$summary"
    return 0
  fi

  if mapped="$(graph_failure_map_kind "$component")"; then
    graph_failure_emit "$mapped" "$summary"
    return 0
  fi

  if [[ "$(printf '%s' "$extracted" | jq -r '.hasControlPaths')" == "true" ]] || \
     [[ "$(printf '%s' "$extracted" | jq -r '.sandboxViolation')" == "true" ]]; then
    graph_failure_emit "integrity" "$summary"
    return 0
  fi

  if [[ "$(printf '%s' "$extracted" | jq -r '.hasOutOfScope')" == "true" ]]; then
    graph_failure_emit "plan-contract" "$summary"
    return 0
  fi

  if reason_token="$(graph_failure_reason_token "$reason")" && mapped="$(graph_failure_map_kind "$reason_token")"; then
    graph_failure_emit "$mapped" "${summary:-$reason}"
    return 0
  fi

  if graph_failure_is_success_outcome "$outcome" || [[ "$is_success" == "true" ]] || \
     { [[ "$exit_code" == "0" ]] && [[ "$outcome" != "failed" && "$outcome" != "error" && "$outcome" != "failure" ]]; }; then
    graph_failure_emit "unknown" "${summary:-successful report}"
    return 0
  fi

  if [[ "$structured_present" -eq 0 ]]; then
    fallback_text="$(graph_failure_bound_text "${summary} ${reason} ${extra_text}")"
    if mapped="$(graph_failure_match_text "$fallback_text")"; then
      graph_failure_emit "$mapped" "${summary:-$reason}"
      return 0
    fi
  fi

  graph_failure_emit "unknown" "$summary"
  return 0
}

# ---------------------------------------------------------------------------
# G10/G11: StageOutcomeReport `failure` object normalizer.
#
# graph_failure_classify_v2 is a second, independent pure entry point. It
# does not replace graph_failure_classify (the {classification,retryable,
# operatorAction,summary} envelope consumed by the scheduler);
# it builds the exact G10 `failure` object -- classification, cause,
# source, summary, retryable, operatorAction, missingArtifacts,
# offendingPaths, verification, and the optional timeout/permissionRequest
# sub-objects -- following the fixed G11 evidence precedence. Structured
# evidence always wins over text fallback; a generic "unknown" classification
# is used only when no evidence at all is present.
#
# Evidence input schema (every field optional; absent means "no evidence
# at this tier"):
#   {
#     "timeoutMarker": {"owner": "run-plan", "seconds": 30, "signal": "TERM"},
#     "cancelMarker": {"owner": "scheduler", "signal": "INT", "operator": false},
#     "nativePermission": {"tool": "bash", "action": "execute",
#       "resource": "npm test", "effect": "write", "proved": true},
#     "offendingPaths": ["src/outside-scope.txt"],
#     "integrityViolation": false,
#     "missingArtifacts": [".ralph-workspace/artifacts/ns/out.md"],
#     "kind": "...", "class": "...", "component": "...",
#     "exitCode": 1,
#     "verification": "unknown",
#     "reason": "...", "summary": "...", "text": "...",
#     "source": "run-plan"
#   }
#
# Precedence (G11), evaluated in this exact order:
#   1. timeoutMarker or cancelMarker (scheduler/run-plan-owned);
#   2. nativePermission with proved:true and a complete actionable identity
#      (tool, action, resource, effect all non-empty) -- exit code 4 or 143
#      alone, or an unproved permission object, never reaches this tier;
#   3. offendingPaths/integrityViolation (changeset verifier evidence);
#   4. missingArtifacts (orchestrator required-artifact evidence);
#   5. kind/class/component (other structured runtime/run-plan evidence,
#      reusing the token map);
#   6. exitCode mapping (124 -> timeout-shaped; 130/143 alone -> generic
#      signal exit with cause unknown -- proved supervisor-signal requires
#      a cancelMarker; any other value never invents a classification);
#   6b. runner-owned timeout wording in the transcript (run-plan marker
#      lines) outranks later permission-shaped diagnostics;
#   7. bounded text, only when no structured evidence at all was
#      present (tiers 1-6 all empty);
#   8. unknown.
#
# Output: one compact JSON `failure` object (the G10 shape). Never called
# for a successful outcome; callers gate this on outcome != success.
graph_failure_v2_cause_for_class() {
  case "$1" in
    transient-runtime) printf 'invocation-timeout\n' ;;
    operator-permission) printf 'native-permission\n' ;;
    plan-contract) printf 'write-scope\n' ;;
    agent-correctable) printf 'required-artifact-missing\n' ;;
    terminal-configuration) printf 'configuration\n' ;;
    integrity) printf 'integrity\n' ;;
    cancelled) printf 'supervisor-signal\n' ;;
    *) printf 'unknown\n' ;;
  esac
}

graph_failure_v2_emit() {
  local class="$1" cause="$2" source="$3" summary="$4"
  local missing_json="$5" offending_json="$6" verification="$7"
  local timeout_json="$8" permission_json="$9"
  local retryable action

  if ! graph_failure_is_known_class "$class"; then
    class="unknown"
  fi
  if [[ -z "$cause" ]]; then
    cause="$(graph_failure_v2_cause_for_class "$class")"
  fi
  if [[ -z "$source" ]]; then
    source="scheduler"
  fi
  case "$source" in
    runtime-adapter | run-plan | orchestrator | changeset | scheduler) ;;
    *) source="scheduler" ;;
  esac
  retryable="$(graph_failure_retryable "$class")"
  action="$(graph_failure_operator_action "$class")"
  if [[ -z "$summary" ]]; then
    summary="$(graph_failure_default_summary "$class")"
  fi
  summary="$(graph_failure_redact_text "$summary")"
  summary="$(graph_failure_bound_summary "$summary")"
  [[ -n "$missing_json" ]] || missing_json='[]'
  [[ -n "$offending_json" ]] || offending_json='[]'
  [[ -n "$verification" ]] || verification="unknown"

  jq -nc \
    --arg classification "$class" \
    --arg cause "$cause" \
    --arg source "$source" \
    --arg summary "$summary" \
    --argjson retryable "$retryable" \
    --arg operatorAction "$action" \
    --argjson missingArtifacts "$missing_json" \
    --argjson offendingPaths "$offending_json" \
    --arg verification "$verification" \
    --argjson timeoutObj "${timeout_json:-null}" \
    --argjson permissionObj "${permission_json:-null}" \
    '{
      classification: $classification,
      cause: $cause,
      source: $source,
      summary: $summary,
      retryable: $retryable,
      operatorAction: $operatorAction,
      missingArtifacts: $missingArtifacts,
      offendingPaths: $offendingPaths,
      verification: $verification
    }
    + (if $timeoutObj == null then {} else {timeout: $timeoutObj} end)
    + (if $permissionObj == null then {} else {permissionRequest: $permissionObj} end)'
}

graph_failure_classify_v2() {
  local input="${1:-}" evidence=""
  local timeout_marker="" cancel_marker="" native_permission=""
  local offending_json="" integrity_violation="false" missing_json=""
  local kind="" class="" component="" exit_code="" verification=""
  local reason="" summary="" extra_text="" caller_source=""

  if [[ "$input" == \{* ]]; then
    evidence="$input"
  elif [[ -n "$input" && -f "$input" ]]; then
    evidence="$(cat -- "$input" 2>/dev/null || true)"
  else
    evidence="$input"
  fi

  if [[ -z "$evidence" ]] || ! command -v jq >/dev/null 2>&1 \
    || ! printf '%s' "$evidence" | jq -e 'type == "object"' >/dev/null 2>&1; then
    graph_failure_v2_emit "unknown" "unknown" "scheduler" "no evidence was supplied" '[]' '[]' "unknown" "" ""
    return 0
  fi

  timeout_marker="$(printf '%s' "$evidence" | jq -c '.timeoutMarker // empty' 2>/dev/null)"
  cancel_marker="$(printf '%s' "$evidence" | jq -c '.cancelMarker // empty' 2>/dev/null)"
  native_permission="$(printf '%s' "$evidence" | jq -c '.nativePermission // empty' 2>/dev/null)"
  offending_json="$(printf '%s' "$evidence" | jq -c '.offendingPaths // []' 2>/dev/null)"
  integrity_violation="$(printf '%s' "$evidence" | jq -r '.integrityViolation == true' 2>/dev/null)"
  missing_json="$(printf '%s' "$evidence" | jq -c '.missingArtifacts // []' 2>/dev/null)"
  kind="$(printf '%s' "$evidence" | jq -r '.kind // .class // .component // "" | tostring' 2>/dev/null)"
  class="$(printf '%s' "$evidence" | jq -r '.class // "" | tostring' 2>/dev/null)"
  component="$(printf '%s' "$evidence" | jq -r '.component // "" | tostring' 2>/dev/null)"
  exit_code="$(printf '%s' "$evidence" | jq -r '.exitCode | if . == null then "" else tostring end' 2>/dev/null)"
  verification="$(printf '%s' "$evidence" | jq -r '.verification // "" | tostring' 2>/dev/null)"
  reason="$(printf '%s' "$evidence" | jq -r '.reason // "" | tostring' 2>/dev/null)"
  summary="$(printf '%s' "$evidence" | jq -r '.summary // "" | tostring' 2>/dev/null)"
  extra_text="$(printf '%s' "$evidence" | jq -r '.text // "" | tostring' 2>/dev/null)"
  caller_source="$(printf '%s' "$evidence" | jq -r '.source // "" | tostring' 2>/dev/null)"

  # Tier 1: scheduler/run-plan-owned timeout or cancellation marker.
  if [[ -n "$timeout_marker" && "$timeout_marker" != "null" ]]; then
    local owner seconds signal timeout_json
    owner="$(printf '%s' "$timeout_marker" | jq -r '.owner // "run-plan"')"
    seconds="$(printf '%s' "$timeout_marker" | jq -r '.seconds // empty')"
    signal="$(printf '%s' "$timeout_marker" | jq -r '.signal // empty')"
    timeout_json="$(jq -nc --arg owner "$owner" \
      --argjson seconds "${seconds:-null}" \
      --arg signal "${signal:-}" \
      '{owner: $owner} + (if $seconds == null then {} else {seconds: $seconds} end) + (if $signal == "" then {} else {signal: $signal} end)')"
    graph_failure_v2_emit "transient-runtime" "invocation-timeout" "${caller_source:-$owner}" \
      "${summary:-invocation exceeded its bounded timeout}" "$missing_json" "$offending_json" "$verification" "$timeout_json" ""
    return 0
  fi
  if [[ -n "$cancel_marker" && "$cancel_marker" != "null" ]]; then
    local cancel_owner cancel_operator cancel_cause
    cancel_owner="$(printf '%s' "$cancel_marker" | jq -r '.owner // "scheduler"')"
    cancel_operator="$(printf '%s' "$cancel_marker" | jq -r '.operator == true')"
    cancel_cause="supervisor-signal"
    [[ "$cancel_operator" == "true" ]] && cancel_cause="operator-cancel"
    graph_failure_v2_emit "cancelled" "$cancel_cause" "${caller_source:-$cancel_owner}" \
      "${summary:-run was cancelled}" "$missing_json" "$offending_json" "$verification" "" ""
    return 0
  fi

  # Tier 2: proved native permission event with a complete actionable
  # identity. An exit code alone, or a permission object missing proof or
  # any identity field, never reaches this tier.
  if [[ -n "$native_permission" && "$native_permission" != "null" ]]; then
    local proved tool paction resource effect
    proved="$(printf '%s' "$native_permission" | jq -r '.proved == true')"
    tool="$(printf '%s' "$native_permission" | jq -r '.tool // ""')"
    paction="$(printf '%s' "$native_permission" | jq -r '.action // ""')"
    resource="$(printf '%s' "$native_permission" | jq -r '.resource // ""')"
    effect="$(printf '%s' "$native_permission" | jq -r '.effect // ""')"
    if [[ "$proved" == "true" && -n "$tool" && -n "$paction" && -n "$resource" && -n "$effect" ]]; then
      graph_failure_v2_emit "operator-permission" "native-permission" "${caller_source:-runtime-adapter}" \
        "${summary:-operator permission required}" "$missing_json" "$offending_json" "$verification" "" "$native_permission"
      return 0
    fi
  fi

  # Tier 3: changeset verifier scope/integrity evidence.
  if [[ "$integrity_violation" == "true" ]]; then
    graph_failure_v2_emit "integrity" "integrity" "${caller_source:-changeset}" \
      "${summary:-integrity or sandbox violation}" "$missing_json" "$offending_json" "$verification" "" ""
    return 0
  fi
  if [[ "$(printf '%s' "$offending_json" | jq 'length' 2>/dev/null)" -gt 0 ]]; then
    graph_failure_v2_emit "plan-contract" "write-scope" "${caller_source:-changeset}" \
      "${summary:-write outside the declared scope}" "$missing_json" "$offending_json" "$verification" "" ""
    return 0
  fi

  # Tier 4: orchestrator required-artifact evidence.
  if [[ "$(printf '%s' "$missing_json" | jq 'length' 2>/dev/null)" -gt 0 ]]; then
    graph_failure_v2_emit "agent-correctable" "required-artifact-missing" "${caller_source:-orchestrator}" \
      "${summary:-a required artifact was not produced}" "$missing_json" "$offending_json" "$verification" "" ""
    return 0
  fi

  # Tier 5: other structured runtime/run-plan evidence, reusing the
  # token map (kind, falling back to class, falling back to component).
  local mapped=""
  if mapped="$(graph_failure_map_kind "$kind")"; then
    graph_failure_v2_emit "$mapped" "" "${caller_source:-run-plan}" "$summary" "$missing_json" "$offending_json" "$verification" "" ""
    return 0
  fi

  # Tier 6: exit code mapping.
  #   124 -> timeout-shaped (timeout(1)-style kill)
  #   130/143 alone -> generic signal exit (cancelled/unknown). A proved
  #   supervisor-signal or operator-cancel requires a cancelMarker at tier 1;
  #   bare 143 must stay distinct from that proved cause and must never
  #   invent a permissionRequest (G11).
  # Any other exit code alone never invents a classification.
  case "$exit_code" in
    124)
      graph_failure_v2_emit "transient-runtime" "invocation-timeout" "${caller_source:-run-plan}" \
        "${summary:-invocation exceeded its bounded timeout (exit 124)}" "$missing_json" "$offending_json" "$verification" "" ""
      return 0
      ;;
    130 | 143)
      graph_failure_v2_emit "cancelled" "unknown" "${caller_source:-scheduler}" \
        "${summary:-generic signal exit ($exit_code) without a cancel marker}" "$missing_json" "$offending_json" "$verification" "" ""
      return 0
      ;;
  esac

  # Runner-owned timeout wording written by run-plan before exit 4. Checked
  # before generic phrase matching so a later "permission denied"
  # diagnostic in the same segment cannot override the timeout (G11).
  local timeout_probe
  timeout_probe="$(printf '%s' "${summary} ${reason} ${extra_text}" | tr '[:upper:]' '[:lower:]')"
  case "$timeout_probe" in
    *'invocation terminated due to timeout'*|*'invocation timeout exceeded'*|*'invocation stuck: timeout'*)
      graph_failure_v2_emit "transient-runtime" "invocation-timeout" "${caller_source:-run-plan}" \
        "${summary:-invocation exceeded its bounded timeout}" "$missing_json" "$offending_json" "$verification" "" ""
      return 0
      ;;
  esac

  # Tier 7: bounded text, only when every structured tier above was
  # empty. Signal/timeout exits (124/130/143) never become operator-permission
  # from transcript wording alone (G11: exit 143 alone never creates a
  # permission request). Exit 4 remains eligible for text permission
  # matching because it is the historical permission exit; runner-owned
  # timeout wording is already handled above.
  local fallback_text mapped_fallback
  fallback_text="$(graph_failure_bound_text "${summary} ${reason} ${extra_text}")"
  if mapped_fallback="$(graph_failure_match_text "$fallback_text")"; then
    if [[ "$mapped_fallback" == "operator-permission" ]] && \
       [[ "$exit_code" == "124" || "$exit_code" == "130" || "$exit_code" == "143" ]]; then
      :
    else
      graph_failure_v2_emit "$mapped_fallback" "" "${caller_source:-run-plan}" "${summary:-$reason}" "$missing_json" "$offending_json" "$verification" "" ""
      return 0
    fi
  fi

  # Tier 8: unknown. Reached only when no evidence at any tier applied.
  graph_failure_v2_emit "unknown" "unknown" "${caller_source:-scheduler}" "${summary:-$reason}" "$missing_json" "$offending_json" "$verification" "" ""
  return 0
}
