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
