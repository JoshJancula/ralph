#!/usr/bin/env bash

if [[ -n "${RALPH_KILLSWITCH_CONFIG_LOADED:-}" ]]; then
  return 0
fi
RALPH_KILLSWITCH_CONFIG_LOADED=1

# .ralph directory that owns killswitch.json and python/killswitch_config.py.
_KILLSWITCH_RALPH_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
_KILLSWITCH_NORMALIZER="${_KILLSWITCH_RALPH_DIR}/python/killswitch_config.py"

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
_KILLSWITCH_CONFIG_SOURCE="none"
_KILLSWITCH_CONFIG_PATH=""
_KILLSWITCH_LOAD_OK=0

# Resolve project state-root for killswitch.json (may be empty).
_killswitch_state_root() {
  if [[ -n "${RALPH_PLAN_WORKSPACE_ROOT:-}" ]]; then
    printf '%s\n' "${RALPH_PLAN_WORKSPACE_ROOT%/}"
    return 0
  fi
  if [[ -n "${WORKSPACE:-}" ]]; then
    printf '%s\n' "${WORKSPACE%/}/.ralph-workspace"
    return 0
  fi
  printf '\n'
}

# Print "source_kind\tpath" for the first existing candidate, or "none\t".
# Precedence: override > project state-root > $RALPH_HOME > bundle default.
# Missing optional paths are skipped; existence selects a winner (validated later).
killswitch_resolve_config_source() {
  local override_cfg ws_root ws_cfg global_cfg bundle_cfg

  override_cfg="${RALPH_KILLSWITCH_OVERRIDE_FILE:-}"
  if [[ -n "$override_cfg" && -e "$override_cfg" ]]; then
    printf 'override\t%s\n' "$override_cfg"
    return 0
  fi

  ws_root="$(_killswitch_state_root)"
  if [[ -n "$ws_root" ]]; then
    ws_cfg="${ws_root}/killswitch.json"
    if [[ -e "$ws_cfg" ]]; then
      printf 'project\t%s\n' "$ws_cfg"
      return 0
    fi
  fi

  if [[ -n "${RALPH_HOME:-}" ]]; then
    global_cfg="${RALPH_HOME}/killswitch.json"
    if [[ -e "$global_cfg" ]]; then
      printf 'global\t%s\n' "$global_cfg"
      return 0
    fi
  fi

  bundle_cfg="${SCRIPT_DIR:-$_KILLSWITCH_RALPH_DIR}/killswitch.json"
  if [[ -e "$bundle_cfg" ]]; then
    printf 'bundle\t%s\n' "$bundle_cfg"
    return 0
  fi

  printf 'none\t\n'
}

# Apply normalized canonical JSON into internal arrays.
# Prefer jq (hook hot path); fall back to python3 when jq is unavailable.
_killswitch_apply_normalized_json() {
  local normalized="${1:-}"
  local raw_output line section

  _KILLSWITCH_BANNED_TOOLS=()
  _KILLSWITCH_BANNED_PATHS=()
  _KILLSWITCH_ALLOWED_TOOLS=()
  _KILLSWITCH_ALLOWED_PATHS=()
  _KILLSWITCH_ALLOWED_COMMANDS=()
  _KILLSWITCH_ALLOWED_PATTERNS=()
  _KILLSWITCH_TOOL_DENYLIST=()
  _KILLSWITCH_DENIED_ARGUMENT_PATTERNS_JSON="[]"
  _KILLSWITCH_CUSTOM_RULES_JSON="[]"

  if command -v jq >/dev/null 2>&1; then
    if ! jq -e 'type == "object"' >/dev/null 2>&1 <<<"$normalized"; then
      return 1
    fi
    _KILLSWITCH_ENABLED="$(jq -r 'if .enabled == false then "false" else "true" end' <<<"$normalized")"
    _KILLSWITCH_DRY_RUN="$(jq -r 'if .dry_run == true then "true" else "false" end' <<<"$normalized")"
    _KILLSWITCH_DENIED_ARGUMENT_PATTERNS_JSON="$(jq -c '(.denied_argument_patterns // [])' <<<"$normalized")"
    _KILLSWITCH_CUSTOM_RULES_JSON="$(jq -c '(.custom_rules // [])' <<<"$normalized")"
    while IFS= read -r line; do
      [[ -n "$line" ]] && _KILLSWITCH_BANNED_TOOLS+=("$line")
    done < <(jq -r '(.banned_tools // [])[]?' <<<"$normalized")
    while IFS= read -r line; do
      [[ -n "$line" ]] && _KILLSWITCH_TOOL_DENYLIST+=("$line")
    done < <(jq -r '(.tool_denylist // [])[]?' <<<"$normalized")
    while IFS= read -r line; do
      [[ -n "$line" ]] && _KILLSWITCH_BANNED_PATHS+=("$line")
    done < <(jq -r '(.banned_paths // [])[]?' <<<"$normalized")
    while IFS= read -r line; do
      [[ -n "$line" ]] && _KILLSWITCH_ALLOWED_TOOLS+=("$line")
    done < <(jq -r '(.allowed_tools // [])[]?' <<<"$normalized")
    while IFS= read -r line; do
      [[ -n "$line" ]] && _KILLSWITCH_ALLOWED_PATHS+=("$line")
    done < <(jq -r '(.allowed_paths // [])[]?' <<<"$normalized")
    while IFS= read -r line; do
      [[ -n "$line" ]] && _KILLSWITCH_ALLOWED_COMMANDS+=("$line")
    done < <(jq -r '(.allowed_commands // [])[]?' <<<"$normalized")
    while IFS= read -r line; do
      [[ -n "$line" ]] && _KILLSWITCH_ALLOWED_PATTERNS+=("$line")
    done < <(jq -r '(.allowed_patterns // [])[]?' <<<"$normalized")
    return 0
  fi

  raw_output="$(printf '%s' "$normalized" | python3 -c '
import json, sys

cfg = json.load(sys.stdin)
if not isinstance(cfg, dict):
    raise SystemExit("normalized config must be an object")

def emit(section, lines):
    print("SECTION:" + section)
    for line in lines:
        print(line)

emit("enabled", ["true" if cfg.get("enabled") else "false"])
emit("dry_run", ["true" if cfg.get("dry_run") else "false"])
emit("banned_tools", list(cfg.get("banned_tools") or []))
emit("tool_denylist", list(cfg.get("tool_denylist") or []))
emit("banned_paths", list(cfg.get("banned_paths") or []))
emit("allowed_tools", list(cfg.get("allowed_tools") or []))
emit("allowed_paths", list(cfg.get("allowed_paths") or []))
emit("allowed_commands", list(cfg.get("allowed_commands") or []))
emit("allowed_patterns", list(cfg.get("allowed_patterns") or []))
emit("denied_argument_patterns_json", [json.dumps(cfg.get("denied_argument_patterns") or [])])
emit("custom_rules_json", [json.dumps(cfg.get("custom_rules") or [])])
' 2>/dev/null)" || return 1

  section=""
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

# Validate+normalize a config file via the shared normalizer. Prints canonical JSON.
# Nonzero on invalid/unreadable; errors go to stderr with source and JSON path.
# Fast path: already-canonical schema_version 2 objects skip the python3 normalizer.
killswitch_normalize_config_file() {
  local config_file="${1:-}"
  if [[ -z "$config_file" ]]; then
    echo "killswitch: missing config path" >&2
    return 1
  fi
  if [[ ! -e "$config_file" ]]; then
    echo "${config_file}: \$: unreadable file: No such file or directory" >&2
    return 1
  fi
  if command -v jq >/dev/null 2>&1; then
    if jq -e '
      type == "object"
      and .schema_version == 2
      and ((keys - ["schema_version","enabled","dry_run","banned_tools","tool_denylist","allowed_tools","banned_paths","allowed_paths","allowed_commands","allowed_patterns","denied_argument_patterns","custom_rules"]) | length == 0)
      and ((.enabled | type) == "boolean" or (.enabled | not))
      and ((.dry_run | type) == "boolean" or (.dry_run | not))
      and ((.banned_tools | type) == "array" or (.banned_tools | not))
      and ((.tool_denylist | type) == "array" or (.tool_denylist | not))
      and ((.custom_rules | type) == "array" or (.custom_rules | not))
      and ((.denied_argument_patterns | type) == "array" or (.denied_argument_patterns | not))
    ' "$config_file" >/dev/null 2>&1; then
      jq '{
        schema_version: 2,
        enabled: (if .enabled == null then true else .enabled end),
        dry_run: (.dry_run // false),
        banned_tools: (.banned_tools // []),
        tool_denylist: (.tool_denylist // []),
        allowed_tools: (.allowed_tools // []),
        banned_paths: (.banned_paths // []),
        allowed_paths: (.allowed_paths // []),
        allowed_commands: (.allowed_commands // []),
        allowed_patterns: (.allowed_patterns // []),
        denied_argument_patterns: (.denied_argument_patterns // []),
        custom_rules: (.custom_rules // [])
      }' "$config_file"
      return 0
    fi
  fi
  if ! command -v python3 >/dev/null 2>&1; then
    echo "killswitch: python3 is required to validate killswitch config" >&2
    return 1
  fi
  if [[ ! -f "$_KILLSWITCH_NORMALIZER" ]]; then
    echo "killswitch: shared normalizer not found: $_KILLSWITCH_NORMALIZER" >&2
    return 1
  fi
  python3 "$_KILLSWITCH_NORMALIZER" normalize "$config_file"
}

# Load killswitch config from the winning source.
# Returns nonzero when the winning configured source is invalid or unreadable
# (fail closed; does not fall through to a lower-precedence file).
# Missing optional sources fall through by fixed precedence. No file => defaults.
killswitch_load_config() {
  local source_kind config_file normalized
  _KILLSWITCH_LOAD_OK=0
  _KILLSWITCH_CONFIG_SOURCE="none"
  _KILLSWITCH_CONFIG_PATH=""

  IFS=$'\t' read -r source_kind config_file <<< "$(killswitch_resolve_config_source)"

  if [[ "$source_kind" == "none" || -z "$config_file" ]]; then
    _KILLSWITCH_LOAD_OK=1
    return 0
  fi

  _KILLSWITCH_CONFIG_SOURCE="$source_kind"
  _KILLSWITCH_CONFIG_PATH="$config_file"

  if ! normalized="$(killswitch_normalize_config_file "$config_file")"; then
    _KILLSWITCH_LOAD_OK=0
    return 1
  fi

  if ! _killswitch_apply_normalized_json "$normalized"; then
    echo "killswitch: failed to apply normalized config from $config_file" >&2
    _KILLSWITCH_LOAD_OK=0
    return 1
  fi

  _KILLSWITCH_LOAD_OK=1
  return 0
}

# Winning source kind: override|project|global|bundle|none
killswitch_config_source() {
  printf '%s\n' "${_KILLSWITCH_CONFIG_SOURCE:-none}"
}

# Absolute path of the winning config file (empty when none).
killswitch_config_path() {
  printf '%s\n' "${_KILLSWITCH_CONFIG_PATH:-}"
}

# Returns 0 when the last load succeeded (including defaults / no file).
killswitch_config_load_ok() {
  [[ "${_KILLSWITCH_LOAD_OK:-0}" == "1" ]]
}

# Append comma-separated env override values to the in-memory config arrays.
# Call only after a successful killswitch_load_config.
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
  export RALPH_KILLSWITCH_CONFIG_SOURCE="${_KILLSWITCH_CONFIG_SOURCE:-none}"
  export RALPH_KILLSWITCH_CONFIG_PATH="${_KILLSWITCH_CONFIG_PATH:-}"
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
