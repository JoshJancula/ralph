#!/usr/bin/env bash

if [[ -n "${RALPH_KILLSWITCH_VALIDATOR_LOADED:-}" ]]; then
  return
fi
RALPH_KILLSWITCH_VALIDATOR_LOADED=1

# Expand a leading ~/ to $HOME/ in a pattern string.
_killswitch_expand_tilde() {
  local pattern="$1"
  if [[ "$pattern" == "~/"* ]]; then
    printf '%s' "${HOME}/${pattern:2}"
  elif [[ "$pattern" == "~" ]]; then
    printf '%s' "$HOME"
  else
    printf '%s' "$pattern"
  fi
}

# Returns 0 if the given tool name matches any pattern in _KILLSWITCH_BANNED_TOOLS.
# Patterns support * glob matching via bash [[ == ]] (unquoted pattern).
killswitch_tool_is_banned() {
  local tool="$1"
  local pattern
  for pattern in "${_KILLSWITCH_ALLOWED_TOOLS[@]+"${_KILLSWITCH_ALLOWED_TOOLS[@]}"}"; do
    # shellcheck disable=SC2254
    if [[ "$tool" == $pattern ]]; then
      return 1
    fi
  done
  for pattern in "${_KILLSWITCH_BANNED_TOOLS[@]+"${_KILLSWITCH_BANNED_TOOLS[@]}"}"; do
    # shellcheck disable=SC2254
    if [[ "$tool" == $pattern ]]; then
      return 0
    fi
  done
  return 1
}

# Returns 0 if the given file path matches any pattern in _KILLSWITCH_BANNED_PATHS.
# Handles ~ expansion; patterns support * glob matching.
killswitch_path_is_banned() {
  local path="$1"
  local pattern expanded
  for pattern in "${_KILLSWITCH_ALLOWED_PATHS[@]+"${_KILLSWITCH_ALLOWED_PATHS[@]}"}"; do
    expanded="$(_killswitch_expand_tilde "$pattern")"
    # shellcheck disable=SC2254
    if [[ "$path" == $expanded ]]; then
      return 1
    fi
  done
  for pattern in "${_KILLSWITCH_BANNED_PATHS[@]+"${_KILLSWITCH_BANNED_PATHS[@]}"}"; do
    expanded="$(_killswitch_expand_tilde "$pattern")"
    # shellcheck disable=SC2254
    if [[ "$path" == $expanded ]]; then
      return 0
    fi
  done
  return 1
}

# Returns 0 if command_str matches any custom_rule (target=command) in _KILLSWITCH_CUSTOM_RULES_JSON
# or any pattern in _KILLSWITCH_BANNED_PATTERNS.
# Custom rules support plain substring matching (match field) or regex (pattern field).
# Sets KILLSWITCH_VIOLATION_RULE to the matching rule name on success.
killswitch_command_matches_rule() {
  local command_str="$1"
  KILLSWITCH_VIOLATION_RULE=""

  local command_allow
  for command_allow in "${_KILLSWITCH_ALLOWED_COMMANDS[@]+"${_KILLSWITCH_ALLOWED_COMMANDS[@]}"}"; do
    if [[ "$command_str" == *"$command_allow"* ]]; then
      return 1
    fi
  done

  local pat
  for pat in "${_KILLSWITCH_ALLOWED_PATTERNS[@]+"${_KILLSWITCH_ALLOWED_PATTERNS[@]}"}"; do
    if [[ "$command_str" =~ $pat ]]; then
      return 1
    fi
  done

  # Check env-supplied extra patterns with bash ERE.
  for pat in "${_KILLSWITCH_BANNED_PATTERNS[@]+"${_KILLSWITCH_BANNED_PATTERNS[@]}"}"; do
    if [[ "$command_str" =~ $pat ]]; then
      KILLSWITCH_VIOLATION_RULE="custom_pattern"
      return 0
    fi
  done

  # Check JSON custom_rules via python3 for correct regex semantics.
  local rules_json="${_KILLSWITCH_CUSTOM_RULES_JSON:-[]}"
  if [[ "$rules_json" == "[]" || -z "$rules_json" ]]; then
    return 1
  fi

  local matched_name
  matched_name="$(python3 - "$command_str" "$rules_json" 2>/dev/null <<'PY'
import json, re, sys

command = sys.argv[1]
try:
    rules = json.loads(sys.argv[2])
except Exception:
    sys.exit(1)

for rule in rules:
    if rule.get("target", "command") != "command":
        continue
    rule_name = rule.get("name", "custom_rule")
    # Plain substring match (match field) takes precedence
    if "match" in rule:
        if rule["match"] in command:
            print(rule_name)
            sys.exit(0)
    # Regex match (pattern field) as fallback
    elif "pattern" in rule:
        try:
            if re.search(rule["pattern"], command):
                print(rule_name)
                sys.exit(0)
        except re.error:
            continue

sys.exit(1)
PY
  )" || return 1

  KILLSWITCH_VIOLATION_RULE="$matched_name"
  return 0
}

# Takes a comma-separated list of tool names, returns 1 and sets KILLSWITCH_BLOCKED_TOOL
# if any tool matches the banned_tools list.
killswitch_validate_allowed_tools() {
  local tools_str="$1"
  KILLSWITCH_BLOCKED_TOOL=""

  local tool
  local -a tools_arr
  IFS=',' read -ra tools_arr <<< "$tools_str"

  for tool in "${tools_arr[@]}"; do
    # Strip leading/trailing whitespace.
    tool="${tool#"${tool%%[![:space:]]*}"}"
    tool="${tool%"${tool##*[![:space:]]}"}"
    [[ -z "$tool" ]] && continue
    if killswitch_tool_is_banned "$tool"; then
      KILLSWITCH_BLOCKED_TOOL="$tool"
      return 1
    fi
  done
  return 0
}

# Returns 0 if the given tool name matches any entry in toolDenylist.
# Used for unified policy enforcement across MCP and native paths.
killswitch_tool_is_denied() {
  local tool="$1"
  local denylist_json="${2:-${RALPH_KILLSWITCH_DENIED_TOOL_DENYLIST_JSON:-[]}}"
  local item

  if [[ -z "$tool" ]]; then
    return 1
  fi

  for item in "${_KILLSWITCH_TOOL_DENYLIST[@]+"${_KILLSWITCH_TOOL_DENYLIST[@]}"}"; do
    if [[ "$tool" == "$item" ]]; then
      return 0
    fi
  done

  if [[ -z "$denylist_json" || "$denylist_json" == "[]" ]]; then
    return 1
  fi

  if command -v python3 &>/dev/null; then
    python3 - "$tool" "$denylist_json" <<'PY' >/dev/null 2>&1
import json, sys
tool = sys.argv[1]
try:
    denylist = json.loads(sys.argv[2])
except Exception:
    sys.exit(1)
if isinstance(denylist, list) and tool in denylist:
    sys.exit(0)
sys.exit(1)
PY
    return $?
  fi

  if command -v jq &>/dev/null; then
    if jq -e --arg name "$tool" '. | index($name) != null' <<< "$denylist_json" >/dev/null 2>&1; then
      return 0
    fi
  fi
  return 1
}

# Returns 0 if the given arguments match any pattern in deniedArgumentPatterns.
# deniedArgumentPatterns is a JSON array of objects with tool, argument, pattern, mode fields.
# Used for unified policy enforcement across MCP and native paths.
killswitch_arguments_match_denied_pattern() {
  local tool="${1:-}"
  local arguments="${2:-}"
  local denied_patterns_json="${3:-${RALPH_KILLSWITCH_DENIED_ARGUMENT_PATTERNS_JSON:-[]}}"

  if [[ -z "$arguments" ]]; then
    return 1
  fi

  if [[ "$denied_patterns_json" == "[]" || -z "$denied_patterns_json" ]]; then
    return 1
  fi

  if command -v python3 &>/dev/null; then
    python3 - "$tool" "$arguments" "$denied_patterns_json" <<'PY' >/dev/null 2>&1
import json, re, sys

tool = sys.argv[1]
arguments = sys.argv[2]
try:
    patterns = json.loads(sys.argv[3])
except Exception:
    sys.exit(1)
if not isinstance(patterns, list):
    sys.exit(1)

for rule in patterns:
    if not isinstance(rule, dict):
        continue
    rule_tool = rule.get("tool")
    if rule_tool not in (None, "", tool):
        continue
    argument = rule.get("argument")
    haystack = arguments
    if argument is not None:
        extracted = None
        try:
            parsed = json.loads(arguments)
        except Exception:
            parsed = None
        if isinstance(parsed, dict) and str(argument) in parsed:
            value = parsed[str(argument)]
            if isinstance(value, (dict, list)):
                extracted = json.dumps(value, separators=(",", ":"))
            else:
                extracted = str(value)
        if extracted is None:
            marker = str(argument)
            if marker not in arguments:
                continue
            keyed = re.search(
                r'(?:^|[?&,\s{])' + re.escape(marker) + r'\s*[=:]\s*([^,\s}"\']+)',
                arguments,
            )
            if keyed:
                extracted = keyed.group(1)
            else:
                extracted = arguments
        haystack = extracted
    pattern = rule.get("pattern")
    if pattern is None:
        continue
    mode = str(rule.get("mode") or "regex").strip().lower()
    if mode in ("literal", "substring", "contains"):
        if str(pattern) in haystack:
            sys.exit(0)
        continue
    try:
        if re.search(str(pattern), haystack):
            sys.exit(0)
    except re.error:
        continue
sys.exit(1)
PY
    return $?
  fi

  if command -v jq &>/dev/null; then
    if jq -e --arg tool "$tool" --arg args "$arguments" '
      .[] |
      select(
        (.tool == null or .tool == $tool) and
        (
          ((.argument != null and $args | contains(.argument)) or (.argument == null)) and
          (.pattern != null)
        )
      ) |
      select(.pattern as $pat | $args | test($pat)) |
      .pattern? // empty
    ' <<< "$denied_patterns_json" >/dev/null 2>&1; then
      return 0
    fi
  fi
  return 1
}
