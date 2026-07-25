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

  local agent_config="$agents_root/$agent_id/config.json"

  # Nothing to read from if neither a canonical frontmatter file nor a config.json exists.
  [[ -n "$agent_md" || -f "$agent_config" ]] || { echo '[]'; return 0; }

  local mcp_script
  mcp_script="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/python/agent-config-mcp.py"

  local available_names_json
  available_names_json="$(_read_runtime_mcp_config_server_names "$runtime" "$home" "$project_root")"

  export RALPH_AGENT_ID="$agent_id"
  export RALPH_RESOLVED_MCP_SERVERS_JSON="$available_names_json"

  local declared_lines=""
  # Capture stdout (machine-readable list). Any WARN lines from agent-config-mcp.py
  # go to stderr and are intentionally not captured here.
  #
  # ralph-native agents declare mcp_servers in the canonical frontmatter, while
  # dual-file (per-runtime) agents carry them in the generated config.json - the
  # native session .md rendered by sync-runtime-assets.sh does not include the
  # mcp_servers frontmatter. Prefer frontmatter, then fall back to config.json so
  # both agent layouts resolve identically.
  if [[ -n "$agent_md" ]]; then
    declared_lines="$(python3 "$mcp_script" --frontmatter "$agent_md" || true)"
  fi
  if [[ -z "$declared_lines" && -f "$agent_config" ]]; then
    declared_lines="$(python3 "$mcp_script" --config-servers "$agent_config" || true)"
  fi
  if [[ -z "$declared_lines" ]]; then
    echo '[]'
    return 0
  fi

  # Emit every declared entry, including references to servers that are not in the
  # ambient catalog. Availability and fail-closed handling of missing references is
  # owned by the runtime MCP resolver, which must see the full declared set to fail
  # the preflight when a referenced ambient server is absent.
  printf '%s\n' "$declared_lines" | jq -s '.'
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
