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

print("SECTION:enabled")
print("true" if cfg.get("enabled", True) else "false")
print("SECTION:dry_run")
print("true" if cfg.get("dry_run", False) else "false")
print("SECTION:banned_tools")
for item in cfg.get("banned_tools", []):
    print(item)
print("SECTION:banned_paths")
for item in cfg.get("banned_paths", []):
    print(item)
print("SECTION:allowed_tools")
for item in cfg.get("allowed_tools", []):
    print(item)
print("SECTION:allowed_paths")
for item in cfg.get("allowed_paths", []):
    print(item)
print("SECTION:allowed_commands")
for item in cfg.get("allowed_commands", []):
    print(item)
print("SECTION:allowed_patterns")
for item in cfg.get("allowed_patterns", []):
    print(item)
print("SECTION:custom_rules_json")
print(json.dumps(cfg.get("custom_rules", [])))
PY
  )" || return 0

  _KILLSWITCH_BANNED_TOOLS=()
  _KILLSWITCH_BANNED_PATHS=()
  _KILLSWITCH_ALLOWED_TOOLS=()
  _KILLSWITCH_ALLOWED_PATHS=()
  _KILLSWITCH_ALLOWED_COMMANDS=()
  _KILLSWITCH_ALLOWED_PATTERNS=()

  local section=""
  while IFS= read -r line; do
    if [[ "$line" == SECTION:* ]]; then
      section="${line#SECTION:}"
      continue
    fi
    case "$section" in
      enabled)           _KILLSWITCH_ENABLED="$line" ;;
      dry_run)           _KILLSWITCH_DRY_RUN="$line" ;;
      banned_tools)      _KILLSWITCH_BANNED_TOOLS+=("$line") ;;
      banned_paths)      _KILLSWITCH_BANNED_PATHS+=("$line") ;;
      allowed_tools)     _KILLSWITCH_ALLOWED_TOOLS+=("$line") ;;
      allowed_paths)     _KILLSWITCH_ALLOWED_PATHS+=("$line") ;;
      allowed_commands)  _KILLSWITCH_ALLOWED_COMMANDS+=("$line") ;;
      allowed_patterns)  _KILLSWITCH_ALLOWED_PATTERNS+=("$line") ;;
      custom_rules_json) _KILLSWITCH_CUSTOM_RULES_JSON="$line" ;;
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
  banned_tools="$(IFS=','; printf '%s' "${_KILLSWITCH_BANNED_TOOLS[*]:-}")"
  banned_paths="$(IFS=','; printf '%s' "${_KILLSWITCH_BANNED_PATHS[*]:-}")"
  banned_patterns="$(IFS=','; printf '%s' "${_KILLSWITCH_BANNED_PATTERNS[*]:-}")"
  allowed_tools="$(IFS=','; printf '%s' "${_KILLSWITCH_ALLOWED_TOOLS[*]:-}")"
  allowed_paths="$(IFS=','; printf '%s' "${_KILLSWITCH_ALLOWED_PATHS[*]:-}")"
  allowed_commands="$(IFS=','; printf '%s' "${_KILLSWITCH_ALLOWED_COMMANDS[*]:-}")"
  allowed_patterns="$(IFS=','; printf '%s' "${_KILLSWITCH_ALLOWED_PATTERNS[*]:-}")"

  export RALPH_KILLSWITCH_BANNED_TOOLS="$banned_tools"
  export RALPH_KILLSWITCH_BANNED_PATHS="$banned_paths"
  export RALPH_KILLSWITCH_BANNED_PATTERNS="$banned_patterns"
  export RALPH_KILLSWITCH_ALLOWED_TOOLS="$allowed_tools"
  export RALPH_KILLSWITCH_ALLOWED_PATHS="$allowed_paths"
  export RALPH_KILLSWITCH_ALLOWED_COMMANDS="$allowed_commands"
  export RALPH_KILLSWITCH_ALLOWED_PATTERNS="$allowed_patterns"
  export RALPH_KILLSWITCH_CUSTOM_RULES_JSON="$_KILLSWITCH_CUSTOM_RULES_JSON"
  export RALPH_KILLSWITCH_RUNNER_PID="${RALPH_KILLSWITCH_RUNNER_PID:-$$}"
}
