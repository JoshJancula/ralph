#!/usr/bin/env bash
#
# CLI-facing read helpers for agent-config-tool.sh (sourced by the tool entrypoint).
#
# Public interface:
#   read_allowed_tools -- prints Claude allowed_tools as a comma list (python3) or empty.
#   read_mcp_proxy_policy -- prints a configured default MCP proxy policy name or empty.
#   read_model -- prints model after validate_config.
#   usage -- stderr usage and exit 2.

read_allowed_tools() {
  local agents_root="$1" agent_id="$2"
  local cfg
  cfg="$(load_cfg_path "$agents_root" "$agent_id")"
  [[ -f "$cfg" ]] || return 1
  command -v python3 &>/dev/null || return 1
  python3 -c "
import json, sys
with open(sys.argv[1]) as f:
    c = json.load(f)
v = c.get('allowed_tools')
if isinstance(v, str) and v.strip():
    print(v.strip())
elif isinstance(v, list):
    parts = [x.strip() for x in v if isinstance(x, str) and x.strip()]
    if parts:
        print(','.join(parts))
" "$cfg" 2>/dev/null || true
}

read_max_budget() {
  local agents_root="$1" agent_id="$2"
  local cfg
  cfg="$(load_cfg_path "$agents_root" "$agent_id")"
  [[ -f "$cfg" ]] || return 1
  local b
  b="$(json_string_value "$cfg" "max_budget_usd")"
  [[ -n "$b" ]] && echo "$b"
}

read_mcp_proxy_policy() {
  local agents_root="$1" agent_id="$2"
  local cfg
  cfg="$(load_cfg_path "$agents_root" "$agent_id")"
  [[ -f "$cfg" ]] || return 1
  local p
  p="$(json_string_value "$cfg" "mcp_proxy_policy")"
  [[ -n "$p" ]] && echo "$p"
}

read_mcp_servers() {
  local agents_root="$1" agent_id="$2"
  local cfg
  cfg="$(load_cfg_path "$agents_root" "$agent_id")"
  [[ -f "$cfg" ]] || return 1
  command -v python3 &>/dev/null || return 1
  local mcp_script=""
  if [[ -n "${script_dir:-}" && -f "${script_dir}/python/agent-config-mcp.py" ]]; then
    mcp_script="${script_dir}/python/agent-config-mcp.py"
  else
    mcp_script="$(cd "$(dirname "${BASH_SOURCE[1]}")/../.." && pwd)/python/agent-config-mcp.py"
    [[ -f "$mcp_script" ]] || mcp_script="$(cd "$(dirname "${BASH_SOURCE[1]}")/../../.." && pwd)/python/agent-config-mcp.py"
  fi
  [[ -f "$mcp_script" ]] || return 1
  python3 "$mcp_script" --redact-config "$cfg" 2>/dev/null || true
}

read_model() {
  local agents_root="$1" agent_id="$2"
  local cfg
  cfg="$(load_cfg_path "$agents_root" "$agent_id")"
  validate_config "$agents_root" "$agent_id" >/dev/null
  local m
  m="$(json_string_value "$cfg" "model")"
  echo "$m"
}

_read_runtime_mcp_config_server_names() {
  local runtime="$1" home="$2" project_root="$3"
  local tmp
  tmp="$(mktemp "${TMPDIR:-/tmp}/ralph-mcp-names-XXXXXX")"

  case "$runtime" in
    cursor)
      for src in "$home/.cursor/mcp.json" "$project_root/.cursor/mcp.json"; do
        [[ -f "$src" ]] || continue
        jq -r '.mcpServers | keys[]?' "$src" 2>/dev/null >>"$tmp" || true
      done
      ;;
    claude)
      for src in \
        "$home/.claude.json" \
        "$home/.claude/.mcp.json" \
        "$project_root/.mcp.json" \
        "$project_root/.claude/settings.local.json"
      do
        [[ -f "$src" ]] || continue
        jq -r '.mcpServers | keys[]?' "$src" 2>/dev/null >>"$tmp" || true
      done
      ;;
    antigravity)
      for src in "$home/.agents/mcp_config.json" "$project_root/.agents/mcp_config.json"; do
        [[ -f "$src" ]] || continue
        jq -r '.mcpServers | keys[]?' "$src" 2>/dev/null >>"$tmp" || true
      done
      ;;
    *)
      # For runtimes without a straightforward JSON ambient catalog, default to empty.
      ;;
  esac

  if [[ ! -s "$tmp" ]]; then
    rm -f "$tmp" 2>/dev/null || true
    echo '[]'
    return 0
  fi

  # Turn newline-separated server names into a unique JSON array.
  local out
  out="$(jq -R -s '
    split("\n")
    | map(select(length>0))
    | unique
  ' "$tmp")"
  rm -f "$tmp" 2>/dev/null || true
  echo "$out"
}

read_mcp_servers() {
  local agents_root="$1" agent_id="$2"

  local runtime="${RUNTIME:-${RALPH_PLAN_RUNTIME:-}}"
  local home="${RALPH_RUNTIME_MCP_HOME:-${HOME:-}}"
  local project_root="${RALPH_PROJECT_ROOT:-${WORKSPACE:-$(pwd)}}"

  local agent_md=""
  for cand in \
    "$agents_root/$agent_id/$agent_id.md" \
    "$agents_root/$agent_id/$agent_id.mdc" \
    "$agents_root/$agent_id.md" \
    "$agents_root/$agent_id.mdc"
  do
    if [[ -f "$cand" ]]; then
      agent_md="$cand"
      break
    fi
  done

  [[ -n "$agent_md" ]] || { echo '[]'; return 0; }

  local mcp_script
  mcp_script="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/python/agent-config-mcp.py"

  local available_names_json
  available_names_json="$(_read_runtime_mcp_config_server_names "$runtime" "$home" "$project_root")"

  export RALPH_AGENT_ID="$agent_id"
  export RALPH_RESOLVED_MCP_SERVERS_JSON="$available_names_json"

  local declared_lines declared_array
  # Capture stdout (machine-readable list). Any WARN lines from agent-config-mcp.py
  # go to stderr and are intentionally not captured here.
  declared_lines="$(python3 "$mcp_script" --frontmatter "$agent_md" || true)"
  if [[ -z "$declared_lines" ]]; then
    echo '[]'
    return 0
  fi

  declared_array="$(printf '%s\n' "$declared_lines" | jq -s '.')"

  # Filter reference entries to only those present in the runtime ambient catalog.
  # Non-reference (custom definition) entries are passed through unchanged.
  jq --argjson available "$available_names_json" '
    [ .[] as $e
      | if (($e.reference? != true) or (($available | index($e.name)) != null))
        then $e
        else empty
        end
    ]
  ' <<<"$declared_array"
}

usage() {
  cat <<'EOF' >&2
Usage: agent-config-tool.sh list <agents_root>
       agent-config-tool.sh validate <agents_root> <agent_id> <workspace>
       agent-config-tool.sh model <agents_root> <agent_id>
       agent-config-tool.sh max-budget <agents_root> <agent_id>
       agent-config-tool.sh mcp-proxy-policy <agents_root> <agent_id>
       agent-config-tool.sh mcp-servers <agents_root> <agent_id>
       agent-config-tool.sh context <agents_root> <agent_id> <workspace>
       agent-config-tool.sh required-artifacts <agents_root> <agent_id>
       agent-config-tool.sh allowed-tools <agents_root> <agent_id>   # Claude --allowedTools line or empty
       agent-config-tool.sh validate-skill <skills_root> <skill_id>
       agent-config-tool.sh downstream-stages <orch_file> <current_stage_id> [artifact_ns]
EOF
  exit 2
}
