#!/usr/bin/env bash

if [[ -n "${RALPH_KILLSWITCH_CONFIG_LOADED:-}" ]]; then
  return
fi
RALPH_KILLSWITCH_CONFIG_LOADED=1

# Directory of this file's parent (.ralph dir); used as final fallback for killswitch.json.
_KILLSWITCH_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Internal state populated by killswitch_load_config.
_KILLSWITCH_ENABLED="true"
_KILLSWITCH_DRY_RUN="false"
_KILLSWITCH_BANNED_TOOLS=()
_KILLSWITCH_BANNED_PATHS=()
_KILLSWITCH_BANNED_PATTERNS=()
_KILLSWITCH_ALLOWED_TOOLS=()
_KILLSWITCH_ALLOWED_PATHS=()
_KILLSWITCH_ALLOWED_COMMANDS=()
_KILLSWITCH_ALLOWED_PATTERNS=()
_KILLSWITCH_TOOL_DENYLIST=()
_KILLSWITCH_DENIED_ARGUMENT_PATTERNS_JSON="[]"
_KILLSWITCH_CUSTOM_RULES_JSON="[]"

# Load killswitch config from the first found location:
#   $WORKSPACE/.ralph-workspace/killswitch.json -> $RALPH_HOME/killswitch.json -> $SCRIPT_DIR/killswitch.json
killswitch_load_config() {
  local config_file=""

  if [[ -n "${RALPH_KILLSWITCH_OVERRIDE_FILE:-}" && -f "${RALPH_KILLSWITCH_OVERRIDE_FILE}" ]]; then
    config_file="${RALPH_KILLSWITCH_OVERRIDE_FILE}"
  elif [[ -n "${WORKSPACE:-}" && -f "$WORKSPACE/.ralph-workspace/killswitch.json" ]]; then
    config_file="$WORKSPACE/.ralph-workspace/killswitch.json"
  elif [[ -n "${RALPH_HOME:-}" && -f "${RALPH_HOME}/killswitch.json" ]]; then
    config_file="${RALPH_HOME}/killswitch.json"
  elif [[ -f "${SCRIPT_DIR:-$_KILLSWITCH_SCRIPT_DIR}/killswitch.json" ]]; then
    config_file="${SCRIPT_DIR:-$_KILLSWITCH_SCRIPT_DIR}/killswitch.json"
  fi

  if [[ -z "$config_file" ]]; then
    return 0
  fi

  local raw_output
  raw_output="$(python3 - "$config_file" 2>/dev/null <<'PY'
import json, sys

try:
    with open(sys.argv[1]) as fh:
        cfg = json.load(fh)
except Exception:
    sys.exit(0)

if not isinstance(cfg, dict):
    sys.exit(0)

def as_bool(value, default=False):
    if isinstance(value, bool):
        return value
    if value is None:
        return default
    if isinstance(value, (int, float)):
        return bool(value)
    if isinstance(value, str):
        lowered = value.strip().lower()
        if lowered in ("1", "true", "yes", "on"):
            return True
        if lowered in ("0", "false", "no", "off", ""):
            return False
    return default

def as_string_list(*candidates):
    out = []
    seen = set()
    for candidate in candidates:
        if not isinstance(candidate, list):
            continue
        for item in candidate:
            if not isinstance(item, str):
                continue
            if item in seen:
                continue
            seen.add(item)
            out.append(item)
    return out

def first_list(*candidates):
    merged = []
    for candidate in candidates:
        if isinstance(candidate, list):
            merged.extend(candidate)
    return merged

tools_obj = cfg.get("tools") if isinstance(cfg.get("tools"), dict) else {}
arguments_obj = cfg.get("arguments") if isinstance(cfg.get("arguments"), dict) else {}

enabled = as_bool(cfg.get("enabled", cfg.get("Enabled", True)), True)
dry_run = as_bool(cfg.get("dry_run", cfg.get("dryRun", False)), False)

banned_tools = as_string_list(cfg.get("banned_tools"), cfg.get("bannedTools"))
tool_denylist = as_string_list(
    cfg.get("tool_denylist"),
    cfg.get("toolDenylist"),
    tools_obj.get("denylist"),
    tools_obj.get("deny"),
)
banned_paths = as_string_list(cfg.get("banned_paths"), cfg.get("bannedPaths"))
allowed_tools = as_string_list(cfg.get("allowed_tools"), cfg.get("allowedTools"))
allowed_paths = as_string_list(cfg.get("allowed_paths"), cfg.get("allowedPaths"))
allowed_commands = as_string_list(cfg.get("allowed_commands"), cfg.get("allowedCommands"))
allowed_patterns = as_string_list(cfg.get("allowed_patterns"), cfg.get("allowedPatterns"))
denied_patterns = first_list(
    cfg.get("denied_argument_patterns"),
    cfg.get("deniedArgumentPatterns"),
    arguments_obj.get("denyPatterns"),
)
if not isinstance(denied_patterns, list):
    denied_patterns = []
custom_rules = cfg.get("custom_rules", cfg.get("customRules", []))
if not isinstance(custom_rules, list):
    custom_rules = []

print("SECTION:enabled")
print("true" if enabled else "false")
print("SECTION:dry_run")
print("true" if dry_run else "false")
print("SECTION:banned_tools")
for item in banned_tools:
    print(item)
print("SECTION:tool_denylist")
for item in tool_denylist:
    print(item)
print("SECTION:banned_paths")
for item in banned_paths:
    print(item)
print("SECTION:allowed_tools")
for item in allowed_tools:
    print(item)
print("SECTION:allowed_paths")
for item in allowed_paths:
    print(item)
print("SECTION:allowed_commands")
for item in allowed_commands:
    print(item)
print("SECTION:allowed_patterns")
for item in allowed_patterns:
    print(item)
print("SECTION:denied_argument_patterns_json")
print(json.dumps(denied_patterns))
print("SECTION:custom_rules_json")
print(json.dumps(custom_rules))
PY
  )" || return 0

  _KILLSWITCH_BANNED_TOOLS=()
  _KILLSWITCH_BANNED_PATHS=()
  _KILLSWITCH_ALLOWED_TOOLS=()
  _KILLSWITCH_ALLOWED_PATHS=()
  _KILLSWITCH_ALLOWED_COMMANDS=()
  _KILLSWITCH_ALLOWED_PATTERNS=()
  _KILLSWITCH_TOOL_DENYLIST=()
  _KILLSWITCH_DENIED_ARGUMENT_PATTERNS_JSON="[]"

  local section=""
  while IFS= read -r line; do
    if [[ "$line" == SECTION:* ]]; then
      section="${line#SECTION:}"
      continue
    fi
    case "$section" in
      enabled)                          _KILLSWITCH_ENABLED="$line" ;;
      dry_run)                          _KILLSWITCH_DRY_RUN="$line" ;;
      banned_tools)                     _KILLSWITCH_BANNED_TOOLS+=("$line") ;;
      tool_denylist)                    _KILLSWITCH_TOOL_DENYLIST+=("$line") ;;
      banned_paths)                     _KILLSWITCH_BANNED_PATHS+=("$line") ;;
      allowed_tools)                    _KILLSWITCH_ALLOWED_TOOLS+=("$line") ;;
      allowed_paths)                    _KILLSWITCH_ALLOWED_PATHS+=("$line") ;;
      allowed_commands)                 _KILLSWITCH_ALLOWED_COMMANDS+=("$line") ;;
      allowed_patterns)                 _KILLSWITCH_ALLOWED_PATTERNS+=("$line") ;;
      denied_argument_patterns_json)    _KILLSWITCH_DENIED_ARGUMENT_PATTERNS_JSON="$line" ;;
      custom_rules_json)                _KILLSWITCH_CUSTOM_RULES_JSON="$line" ;;
    esac
  done <<< "$raw_output"
}

# Append comma-separated env override values to the in-memory config arrays.
killswitch_merge_env_overrides() {
  local extra

  if [[ -n "${RALPH_BANNED_TOOLS:-}" ]]; then
    IFS=',' read -ra extra <<< "$RALPH_BANNED_TOOLS"
    _KILLSWITCH_BANNED_TOOLS+=("${extra[@]}")
  fi

  if [[ -n "${RALPH_BANNED_PATHS:-}" ]]; then
    IFS=',' read -ra extra <<< "$RALPH_BANNED_PATHS"
    _KILLSWITCH_BANNED_PATHS+=("${extra[@]}")
  fi

  if [[ -n "${RALPH_BANNED_PATTERNS:-}" ]]; then
    IFS=',' read -ra extra <<< "$RALPH_BANNED_PATTERNS"
    _KILLSWITCH_BANNED_PATTERNS+=("${extra[@]}")
  fi

  if [[ -n "${RALPH_ALLOWED_TOOLS:-}" ]]; then
    IFS=',' read -ra extra <<< "$RALPH_ALLOWED_TOOLS"
    _KILLSWITCH_ALLOWED_TOOLS+=("${extra[@]}")
  fi

  if [[ -n "${RALPH_ALLOWED_PATHS:-}" ]]; then
    IFS=',' read -ra extra <<< "$RALPH_ALLOWED_PATHS"
    _KILLSWITCH_ALLOWED_PATHS+=("${extra[@]}")
  fi

  if [[ -n "${RALPH_ALLOWED_COMMANDS:-}" ]]; then
    IFS=',' read -ra extra <<< "$RALPH_ALLOWED_COMMANDS"
    _KILLSWITCH_ALLOWED_COMMANDS+=("${extra[@]}")
  fi

  if [[ -n "${RALPH_ALLOWED_PATTERNS:-}" ]]; then
    IFS=',' read -ra extra <<< "$RALPH_ALLOWED_PATTERNS"
    _KILLSWITCH_ALLOWED_PATTERNS+=("${extra[@]}")
  fi

  if [[ -n "${RALPH_MCP_TOOL_DENYLIST:-}" ]]; then
    IFS=',' read -ra extra <<< "$RALPH_MCP_TOOL_DENYLIST"
    _KILLSWITCH_TOOL_DENYLIST+=("${extra[@]}")
  fi
}

# Returns 0 if the killswitch is active (enabled in config and not disabled via env).
killswitch_is_enabled() {
  [[ "${RALPH_KILLSWITCH_DISABLED:-0}" == "1" ]] && return 1
  [[ "$_KILLSWITCH_ENABLED" == "true" ]] && return 0
  return 1
}

# Export config state as RALPH_KILLSWITCH_* env vars for Python subprocesses.
killswitch_export_config_env() {
  if [[ "$_KILLSWITCH_ENABLED" == "true" ]]; then
    export RALPH_KILLSWITCH_ENABLED="1"
  else
    export RALPH_KILLSWITCH_ENABLED="0"
  fi

  if [[ "$_KILLSWITCH_DRY_RUN" == "true" ]]; then
    export RALPH_KILLSWITCH_DRY_RUN="1"
  else
    export RALPH_KILLSWITCH_DRY_RUN="0"
  fi

  local banned_tools
  local banned_paths
  local banned_patterns
  local allowed_tools
  local allowed_paths
  local allowed_commands
  local allowed_patterns
  local tool_denylist
  banned_tools="$(IFS=','; printf '%s' "${_KILLSWITCH_BANNED_TOOLS[*]:-}")"
  banned_paths="$(IFS=','; printf '%s' "${_KILLSWITCH_BANNED_PATHS[*]:-}")"
  banned_patterns="$(IFS=','; printf '%s' "${_KILLSWITCH_BANNED_PATTERNS[*]:-}")"
  allowed_tools="$(IFS=','; printf '%s' "${_KILLSWITCH_ALLOWED_TOOLS[*]:-}")"
  allowed_paths="$(IFS=','; printf '%s' "${_KILLSWITCH_ALLOWED_PATHS[*]:-}")"
  allowed_commands="$(IFS=','; printf '%s' "${_KILLSWITCH_ALLOWED_COMMANDS[*]:-}")"
  allowed_patterns="$(IFS=','; printf '%s' "${_KILLSWITCH_ALLOWED_PATTERNS[*]:-}")"
  tool_denylist="$(IFS=','; printf '%s' "${_KILLSWITCH_TOOL_DENYLIST[*]:-}")"

  export RALPH_KILLSWITCH_BANNED_TOOLS="$banned_tools"
  export RALPH_KILLSWITCH_BANNED_PATHS="$banned_paths"
  export RALPH_KILLSWITCH_BANNED_PATTERNS="$banned_patterns"
  export RALPH_KILLSWITCH_ALLOWED_TOOLS="$allowed_tools"
  export RALPH_KILLSWITCH_ALLOWED_PATHS="$allowed_paths"
  export RALPH_KILLSWITCH_ALLOWED_COMMANDS="$allowed_commands"
  export RALPH_KILLSWITCH_ALLOWED_PATTERNS="$allowed_patterns"
  export RALPH_KILLSWITCH_TOOL_DENYLIST="$tool_denylist"
  export RALPH_KILLSWITCH_DENIED_ARGUMENT_PATTERNS_JSON="$_KILLSWITCH_DENIED_ARGUMENT_PATTERNS_JSON"
  export RALPH_KILLSWITCH_CUSTOM_RULES_JSON="$_KILLSWITCH_CUSTOM_RULES_JSON"
  export RALPH_KILLSWITCH_RUNNER_PID="${RALPH_KILLSWITCH_RUNNER_PID:-$$}"

  killswitch_export_tool_denylist_json_for_policy
}

# Export tool_denylist from killswitch config as a JSON array for policy merging.
# This is used by mcp-proxy-policy to combine killswitch.json denylists with proxy policy denylists.
killswitch_export_tool_denylist_json_for_policy() {
  local tool_denylist_json="[]"
  local joined
  joined="$(IFS=','; printf '%s' "${_KILLSWITCH_TOOL_DENYLIST[*]:-}")"

  if command -v python3 &>/dev/null; then
    tool_denylist_json="$(python3 -c 'import json,sys; print(json.dumps([p for p in sys.argv[1].split(",") if p]))' "$joined" 2>/dev/null || printf '%s' '[]')"
  elif [[ ${#_KILLSWITCH_TOOL_DENYLIST[@]} -gt 0 ]] && command -v jq &>/dev/null; then
    tool_denylist_json="$(jq -n --arg tools "$joined" '
      $tools | split(",") | map(select(length > 0))
    ')" || tool_denylist_json="[]"
  fi

  export RALPH_KILLSWITCH_DENIED_TOOL_DENYLIST_JSON="$tool_denylist_json"
}
