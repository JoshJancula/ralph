#!/usr/bin/env bash

if [[ -n "${RALPH_KILLSWITCH_EVALUATE_LOADED:-}" ]]; then
  return
fi
RALPH_KILLSWITCH_EVALUATE_LOADED=1

KILLSWITCH_DECISION="allow"
KILLSWITCH_DECISION_CATEGORY=""
KILLSWITCH_DECISION_REASON=""
KILLSWITCH_DECISION_TOOL=""
KILLSWITCH_DECISION_ARGUMENTS=""
KILLSWITCH_DECISION_RESOURCE=""
KILLSWITCH_MATCHED_RULE=""
KILLSWITCH_CLASSIFY_ONLY=0

_killswitch_set_decision() {
  KILLSWITCH_DECISION="${1:-allow}"
  KILLSWITCH_DECISION_CATEGORY="${2:-}"
  KILLSWITCH_DECISION_REASON="${3:-}"
  KILLSWITCH_DECISION_TOOL="${4:-}"
  KILLSWITCH_DECISION_ARGUMENTS="${5:-}"
  KILLSWITCH_DECISION_RESOURCE="${6:-}"
  printf '%s\n' "$KILLSWITCH_DECISION"
}

# Parse a P10 tool event JSON object into newline fields:
# ok|invalid
# tool
# resource
# arguments
killswitch_parse_event() {
  local event_json="${1:-}"
  if command -v python3 &>/dev/null; then
    python3 - "$event_json" <<'PY'
import json, sys

raw = sys.argv[1]
try:
    event = json.loads(raw)
except Exception:
    print("invalid")
    sys.exit(0)
if not isinstance(event, dict):
    print("invalid")
    sys.exit(0)

tool = event.get("tool")
if tool is None:
    tool = event.get("toolName") or ""
resource = event.get("resource")
if resource is None:
    resource = event.get("path") or event.get("file") or ""
arguments = event.get("arguments")
if arguments is None:
    arguments = event.get("args") or ""
if isinstance(arguments, (dict, list)):
    arguments = json.dumps(arguments, separators=(",", ":"))
elif arguments is None:
    arguments = ""
else:
    arguments = str(arguments)

print("ok")
print(str(tool))
print(str(resource))
print(str(arguments).replace("\n", " "))
PY
    return 0
  fi

  if command -v jq &>/dev/null; then
    if ! jq -e 'type == "object"' >/dev/null 2>&1 <<< "$event_json"; then
      printf 'invalid\n'
      return 0
    fi
    printf 'ok\n'
    jq -r '.tool // .toolName // ""' <<< "$event_json"
    jq -r '.resource // .path // .file // ""' <<< "$event_json"
    jq -r 'if (.arguments | type) == "object" or (.arguments | type) == "array" then (.arguments | tostring) else ((.arguments // .args // "") | tostring) end' <<< "$event_json"
    return 0
  fi

  printf 'invalid\n'
  return 0
}

# Canonical policy evaluator. Prints allow, deny, or fatal.
# Never writes a sentinel and never calls killswitch_trigger.
# Refuses evaluation when config load did not succeed (fail closed).
# When KILLSWITCH_CLASSIFY_ONLY=1, behavior is identical (evaluate is already
# side-effect free); the flag documents classify-only callers such as
# ralph safety check and must never be paired with killswitch_apply_decision.
killswitch_evaluate() {
  local event_json="${1:-}"
  KILLSWITCH_MATCHED_RULE=""
  _killswitch_set_decision allow >/dev/null

  if [[ "${_KILLSWITCH_LOAD_OK:-0}" != "1" ]]; then
    KILLSWITCH_MATCHED_RULE="killswitch config not loaded"
    _killswitch_set_decision deny config "killswitch config not loaded" "" "" ""
    return 1
  fi

  if ! killswitch_is_enabled; then
    _killswitch_set_decision allow
    return 0
  fi

  local parsed status_line tool resource arguments
  parsed="$(killswitch_parse_event "$event_json")" || parsed="invalid"
  status_line="$(printf '%s\n' "$parsed" | sed -n '1p')"
  if [[ "$status_line" != "ok" ]]; then
    KILLSWITCH_MATCHED_RULE="invalid event"
    _killswitch_set_decision deny event "invalid event" "" "" ""
    return 0
  fi

  tool="$(printf '%s\n' "$parsed" | sed -n '2p')"
  resource="$(printf '%s\n' "$parsed" | sed -n '3p')"
  arguments="$(printf '%s\n' "$parsed" | sed -n '4p')"

  if [[ -n "$tool" ]] && killswitch_tool_is_denied "$tool"; then
    KILLSWITCH_MATCHED_RULE="tool denylist"
    _killswitch_set_decision fatal tool "tool denylist" "$tool" "$arguments" "$resource"
    return 0
  fi

  if [[ -n "$tool" ]] && killswitch_tool_is_banned "$tool"; then
    KILLSWITCH_MATCHED_RULE="banned tool"
    _killswitch_set_decision fatal tool "banned tool" "$tool" "$arguments" "$resource"
    return 0
  fi

  if killswitch_arguments_match_denied_pattern "$tool" "$arguments"; then
    KILLSWITCH_MATCHED_RULE="denied argument pattern"
    _killswitch_set_decision fatal argument "denied argument pattern" "$tool" "$arguments" "$resource"
    return 0
  fi

  if [[ -n "$resource" ]] && killswitch_path_is_banned "$resource"; then
    KILLSWITCH_MATCHED_RULE="banned path"
    _killswitch_set_decision fatal path "banned path" "$tool" "$arguments" "$resource"
    return 0
  fi

  if [[ -n "$arguments" ]] && killswitch_command_matches_rule "$arguments"; then
    KILLSWITCH_MATCHED_RULE="${KILLSWITCH_VIOLATION_RULE:-custom_rule}"
    _killswitch_set_decision fatal command "${KILLSWITCH_MATCHED_RULE}" "$tool" "$arguments" "$resource"
    return 0
  fi

  _killswitch_set_decision allow "" "" "$tool" "$arguments" "$resource"
}

# Classify-only: evaluate command text via the production evaluator without
# applying a decision (no sentinel, no process kill, no shell/runtime exec).
# Prints allow, deny, or fatal. Sets KILLSWITCH_CLASSIFY_ONLY=1 for the call.
killswitch_classify_command() {
  local command_text="${1-}"
  local event_json

  if ! command -v python3 >/dev/null 2>&1; then
    echo "killswitch: python3 is required for classify-only evaluation" >&2
    return 1
  fi

  # Pass command text only as a Python argv element / JSON string — never to a shell.
  event_json="$(
    python3 -c '
import json, sys
print(json.dumps({
    "schemaVersion": 1,
    "source": "safety-check",
    "runtime": "ralph",
    "tool": "",
    "action": "classify",
    "effect": "read",
    "resource": "",
    "arguments": sys.argv[1],
}, separators=(",", ":")))
' "$command_text"
  )" || return 1

  KILLSWITCH_CLASSIFY_ONLY=1
  killswitch_evaluate "$event_json"
}

# Apply a previously computed or freshly evaluated decision. Only fatal calls
# killswitch_trigger. Dry-run is honored inside the trigger (sentinel, no kill).
killswitch_apply_decision() {
  local decision="${1:-${KILLSWITCH_DECISION:-allow}}"
  if [[ "$decision" != "fatal" ]]; then
    return 0
  fi
  killswitch_trigger \
    "${KILLSWITCH_DECISION_TOOL:-unknown}" \
    "${KILLSWITCH_DECISION_CATEGORY:-policy}" \
    "${KILLSWITCH_DECISION_REASON:-violation}" \
    "${KILLSWITCH_DECISION_ARGUMENTS:-}"
}

killswitch_evaluate_and_apply() {
  killswitch_evaluate "${1:-}" >/dev/null
  killswitch_apply_decision "$KILLSWITCH_DECISION"
}
