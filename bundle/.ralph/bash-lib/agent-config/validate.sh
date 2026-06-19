#!/usr/bin/env bash
#
# Agent config validation (sourced by agent-config-tool.sh).
#
# Public interface:
#   is_env_secret_basename, rel_path_targets_env_secret -- block .env* rule/artifact targets.
#   valid_agent_name -- agent id naming rules.
#   validate_config -- full config.json checks; exits non-zero via composite ok flag.

MAX_DESCRIPTION_WARN=2000

module_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bash-lib/agent-config/parse-json.sh
source "$module_dir/parse-json.sh"

is_env_secret_basename() {
  local name="$1"
  [[ -n "$name" && "${name#".env"}" != "$name" ]]
}

rel_path_targets_env_secret() {
  local s="$1"
  s="${s//\\//}"
  s="${s%/}"
  [[ -z "$s" ]] && return 1
  local base="${s##*/}"
  is_env_secret_basename "$base"
}

valid_agent_name() {
  local n="$1"
  [[ -n "$n" ]] || return 1
  [[ "$n" =~ ^[a-z0-9]+$ || "$n" =~ ^[a-z0-9][a-z0-9-]*[a-z0-9]$ ]]
}

validate_config() {
  local agents_root="$1" agent_id="$2"
  local cfg
  cfg="$(load_cfg_path "$agents_root" "$agent_id")"
  [[ -f "$cfg" ]] || { echo "config not found: $cfg" >&2; return 1; }

  local ok=1
  local key
  for key in name model description rules skills; do
    grep -Eq "^[[:space:]]*\"$key\"[[:space:]]*:" "$cfg" || { echo "missing required key: $key" >&2; ok=0; }
  done

  local name model desc
  name="$(json_string_value "$cfg" "name")"
  model="$(json_string_value "$cfg" "model")"
  desc="$(json_string_value "$cfg" "description")"

  valid_agent_name "$name" || { echo "name must match schema (lowercase, digits, hyphens; see agents README)" >&2; ok=0; }
  [[ "$name" == "$agent_id" ]] || { echo "name \"$name\" must match directory name \"$agent_id\"" >&2; ok=0; }
  [[ -n "$desc" ]] || { echo "description must be a non-empty string" >&2; ok=0; }
  if (( ${#desc} > MAX_DESCRIPTION_WARN )); then
    echo "warning: description length ${#desc} exceeds recommended $MAX_DESCRIPTION_WARN" >&2
  fi

  local rules skills arts
  rules="$(array_block "$cfg" "rules" || true)"
  skills="$(array_block "$cfg" "skills" || true)"
  [[ -n "$rules" ]] || { echo "rules must be an array" >&2; ok=0; }
  [[ -n "$skills" ]] || { echo "skills must be an array" >&2; ok=0; }

  while IFS= read -r line; do
    [[ "$line" =~ ^[[:space:]]*\"([^\"]+)\"[[:space:]]*,?[[:space:]]*$ ]] || continue
    rel="${BASH_REMATCH[1]}"
    rel_path_targets_env_secret "$rel" && { echo "rules entry must not reference a .env* path (blocked for security)" >&2; ok=0; }
  done <<< "$rules"

  while IFS= read -r line; do
    [[ "$line" =~ ^[[:space:]]*\"([^\"]+)\"[[:space:]]*,?[[:space:]]*$ ]] || continue
    rel="${BASH_REMATCH[1]}"
    rel_path_targets_env_secret "$rel" && { echo "skills entry must not reference a .env* path (blocked for security)" >&2; ok=0; }
  done <<< "$skills"

  if grep -Eq "^[[:space:]]*\"output_artifacts\"[[:space:]]*:" "$cfg"; then
    arts="$(array_block "$cfg" "output_artifacts" || true)"
    [[ -n "$arts" ]] || { echo "output_artifacts must be an array when present" >&2; ok=0; }
    while IFS= read -r line; do
      [[ "$line" =~ \"path\"[[:space:]]*:[[:space:]]*\"([^\"]+)\" ]] || continue
      rel="${BASH_REMATCH[1]}"
      rel_path_targets_env_secret "$rel" && { echo "output_artifacts path must not be .env* (blocked)" >&2; ok=0; }
    done <<< "${arts:-}"
  fi

  if grep -Eq '^[[:space:]]*"mcp_proxy_policy"[[:space:]]*:' "$cfg"; then
    local proxy_policy
    proxy_policy="$(json_string_value "$cfg" "mcp_proxy_policy")"
    [[ -n "$proxy_policy" ]] || { echo "mcp_proxy_policy must be a non-empty string" >&2; ok=0; }
  fi

  if grep -q '"allowed_tools"' "$cfg" 2>/dev/null; then
    if command -v python3 &>/dev/null; then
      python3 -c "
import json, sys
p = sys.argv[1]
with open(p) as f:
    c = json.load(f)
if 'allowed_tools' not in c:
    sys.exit(0)
v = c['allowed_tools']
if isinstance(v, str) and v.strip():
    sys.exit(0)
if isinstance(v, list) and v and all(isinstance(x, str) and x.strip() for x in v):
    sys.exit(0)
sys.exit(1)
" "$cfg" 2>/dev/null || { echo "allowed_tools must be a non-empty string or a non-empty array of non-empty strings (see agents README)" >&2; ok=0; }
    else
      echo "allowed_tools in config requires python3 for validation" >&2
      ok=0
    fi
  fi

  if grep -q '"mcp_servers"' "$cfg" 2>/dev/null; then
    if command -v python3 &>/dev/null; then
      local mcp_script=""
      if [[ -n "${script_dir:-}" && -f "${script_dir}/python/agent-config-mcp.py" ]]; then
        mcp_script="${script_dir}/python/agent-config-mcp.py"
      else
        mcp_script="$(cd "$(dirname "${BASH_SOURCE[1]}")/../.." && pwd)/python/agent-config-mcp.py"
        [[ -f "$mcp_script" ]] || mcp_script="$(cd "$(dirname "${BASH_SOURCE[1]}")/../../.." && pwd)/python/agent-config-mcp.py"
      fi
      [[ -f "$mcp_script" ]] || { echo "mcp_servers validation requires agent-config-mcp.py" >&2; ok=0; }
      if [[ -f "$mcp_script" ]]; then
        python3 "$mcp_script" --validate-config "$cfg" 2>/dev/null || { echo "mcp_servers validation failed" >&2; ok=0; }
      fi
    else
      echo "mcp_servers in config requires python3 for validation" >&2
      ok=0
    fi
  fi

  [[ "$ok" == "1" ]]
}
