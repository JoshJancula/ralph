#!/usr/bin/env bash
#
# CLI-facing read helpers for agent-config-tool.sh (sourced by the tool entrypoint).
#
# Public interface:
#   read_allowed_tools -- prints Claude allowed_tools as a comma list (python3) or empty.
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

read_model() {
  local agents_root="$1" agent_id="$2"
  local cfg
  cfg="$(load_cfg_path "$agents_root" "$agent_id")"
  validate_config "$agents_root" "$agent_id" >/dev/null
  local m
  m="$(json_string_value "$cfg" "model")"
  [[ -n "$m" ]] || { echo "model missing" >&2; return 1; }
  echo "$m"
}

usage() {
  cat <<'EOF' >&2
Usage: agent-config-tool.sh list <agents_root>
       agent-config-tool.sh validate <agents_root> <agent_id> <workspace>
       agent-config-tool.sh model <agents_root> <agent_id>
       agent-config-tool.sh context <agents_root> <agent_id> <workspace>
       agent-config-tool.sh required-artifacts <agents_root> <agent_id>
       agent-config-tool.sh allowed-tools <agents_root> <agent_id>   # Claude --allowedTools line or empty
       agent-config-tool.sh downstream-stages <orch_file> <current_stage_id> [artifact_ns]
EOF
  exit 2
}
