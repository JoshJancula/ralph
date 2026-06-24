#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bash-lib/error-handling.sh
source "$script_dir/bash-lib/error-handling.sh"

# shellcheck source=bash-lib/agent-config/parse-json.sh
source "$script_dir/bash-lib/agent-config/parse-json.sh"

# shellcheck source=bash-lib/agent-config/validate.sh
source "$script_dir/bash-lib/agent-config/validate.sh"

# shellcheck source=bash-lib/agent-config/skill-package.sh
source "$script_dir/bash-lib/agent-config/skill-package.sh"

# shellcheck source=bash-lib/agent-config/inline-rules.sh
source "$script_dir/bash-lib/agent-config/inline-rules.sh"

# shellcheck source=bash-lib/agent-config/cli.sh
source "$script_dir/bash-lib/agent-config/cli.sh"

# shellcheck source=bash-lib/agent-config/resolve-paths.sh
source "$script_dir/bash-lib/agent-config/resolve-paths.sh"

# shellcheck source=bash-lib/agent-config/artifacts.sh
source "$script_dir/bash-lib/agent-config/artifacts.sh"

# shellcheck source=bash-lib/agent-config/context-block.sh
source "$script_dir/bash-lib/agent-config/context-block.sh"

# shellcheck source=bash-lib/agent-config/downstream.sh
source "$script_dir/bash-lib/agent-config/downstream.sh"

# shellcheck source=bash-lib/json-cache.sh
source "$script_dir/bash-lib/json-cache.sh"

agent_config_json_query() {
  local cfg="$1"
  local cache_key="$2"
  shift 2
  local arg_count=$#
  [[ $arg_count -gt 0 ]] || return 1
  local jq_filter="${@: -1}"
  local jq_opts=()
  if (( arg_count > 1 )); then
    jq_opts=("${@:1:$((arg_count - 1))}")
  fi
  ralph_json_cache_query "$cfg" "$cache_key" "${jq_opts[@]}" "$jq_filter"
}

read_model() {
  local agents_root="$1" agent_id="$2"
  local cfg
  cfg="$(load_cfg_path "$agents_root" "$agent_id")"
  validate_config "$agents_root" "$agent_id" >/dev/null
  local model
  model="$(agent_config_json_query "$cfg" "model" -r '.model // ""' 2>/dev/null || echo "")"
  echo "$model"
}

read_reasoning_effort() {
  local agents_root="$1" agent_id="$2"
  local cfg
  cfg="$(load_cfg_path "$agents_root" "$agent_id")"
  validate_config "$agents_root" "$agent_id" >/dev/null
  local effort
  effort="$(agent_config_json_query "$cfg" "reasoning_effort" -r '.reasoning_effort // ""' 2>/dev/null || echo "")"
  echo "$effort"
}


cmd="${1:-}"
case "$cmd" in
  list)
    [[ $# -eq 2 ]] || usage
    list_agent_ids "$2"
    ;;
  validate)
    [[ $# -eq 4 ]] || usage
    validate_config "$2" "$3"
    ;;
  model)
    [[ $# -eq 3 ]] || usage
    read_model "$2" "$3"
    ;;
  reasoning-effort)
    [[ $# -eq 3 ]] || usage
    read_reasoning_effort "$2" "$3"
    ;;
  context)
    [[ $# -eq 4 ]] || usage
    context_block "$2" "$3" "$4"
    ;;
  required-artifacts)
    [[ $# -eq 3 ]] || usage
    required_artifacts "$2" "$3"
    ;;
  allowed-tools)
    [[ $# -eq 3 ]] || usage
    validate_config "$2" "$3" || exit 1
    read_allowed_tools "$2" "$3"
    ;;
  max-budget)
    [[ $# -eq 3 ]] || usage
    read_max_budget "$2" "$3"
    ;;
  mcp-proxy-policy)
    [[ $# -eq 3 ]] || usage
    read_mcp_proxy_policy "$2" "$3"
    ;;
  downstream-stages)
    [[ $# -ge 3 && $# -le 4 ]] || usage
    downstream_stages "$2" "$3" "${4:-}"
    ;;
  mcp-servers)
    [[ $# -eq 3 ]] || usage
    read_mcp_servers "$2" "$3"
    ;;
  validate-skill)
    [[ $# -eq 3 ]] || usage
    ralph_validate_skill_package "$2/$3" "$3"
    ;;
  *)
    usage
    ;;
esac
