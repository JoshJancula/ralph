#!/usr/bin/env bash
# Pure graph failure classifier.
#
# Maps a structured runner/supervisor report to one of the supported classes
# plus retryability, an operator action, and a bounded human summary.
# Structured fields always win. Bounded legacy text matching runs only when
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
# Maximum characters of free text scanned by the legacy fallback.
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
# Collapses whitespace and caps the legacy-scan window.
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

# graph_failure_match_legacy_text <text>
# Phrase matching for unstructured reports. Returns 1 when nothing matches.
graph_failure_match_legacy_text() {
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
  local structured_present=0 is_success="false" legacy_text=""

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
      class: ((.class // .classification // "") | tostring),
      kind: ((.kind // .category // .failureKind // .failureClass // "") | tostring),
      outcome: ((.outcome // "") | tostring),
      exitCode: (.exitCode // null),
      reason: ((.reason // "") | tostring),
      summary: ((.summary // .message // "") | tostring),
      component: ((.component // .completionComponent // "") | tostring),
      text: ((.text // .output // .stderr // .stdout // .error // .detail // "") | tostring),
      isSuccess: ((.success == true) or (.ok == true)),
      hasPermissionRequest: ((.permissionRequest | type) == "object"),
      hasOutOfScope: (
        ((.outOfScope // []) | length) +
        ((.undeclaredPaths // []) | length) +
        ((.mismatch // []) | length) > 0
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
    legacy_text="$(graph_failure_bound_text "${summary} ${reason} ${extra_text}")"
    if mapped="$(graph_failure_match_legacy_text "$legacy_text")"; then
      graph_failure_emit "$mapped" "${summary:-$reason}"
      return 0
    fi
  fi

  graph_failure_emit "unknown" "$summary"
  return 0
}
