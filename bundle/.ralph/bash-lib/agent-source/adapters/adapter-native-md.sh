#!/usr/bin/env bash
#
# Native runtime .md adapter -- reads native runtime agent frontmatter
# (model, description, tools -> allowed_tools, skills), captures the markdown
# body as instruction_body, and sets native_passthrough_name=<name>.
#
# Public interface:
#   agent_adapter_native_md_resolve <name> <runtime> <workspace>
#     Prints "native-md<TAB><path>" and exits 0.
#     The path is the native runtime agent .md file discovered via runtime root.
#
#   agent_adapter_native_md_to_native_passthrough <name> <runtime> <workspace>
#     Parses the native .md frontmatter and outputs shell variable assignments:
#       native_passthrough_name=<name>
#       native_passthrough_model=<model>
#       native_passthrough_allowed_tools=<csv>
#       native_passthrough_description=<description>
#       native_passthrough_instruction_body=<body>
#     Prints the assignments and exits 0.

if [[ -n "${RALPH_ADAPTER_NATIVE_MD_LOADED:-}" ]]; then
  return 0
fi
RALPH_ADAPTER_NATIVE_MD_LOADED=1

_adapters_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=/dev/null
source "$_adapters_dir/../../runtime-normalize.sh"
# shellcheck source=/dev/null
source "$_adapters_dir/../../runtime-resolve.sh"
# shellcheck source=/dev/null
source "$_adapters_dir/../frontmatter.sh"

agent_adapter_native_md_resolve() {
  local name="${1:-}"
  local runtime="${2:-}"
  local workspace="${3:-}"

  if [[ -z "$name" || -z "$runtime" || -z "$workspace" ]]; then
    echo "Error: name, runtime, and workspace are required" >&2
    return 2
  fi

  local runtime_root
  runtime_root="$(ralph_resolve_runtime_root "$runtime" "$workspace" 2>/dev/null)" || runtime_root=""

  if [[ -n "$runtime_root" && -r "$runtime_root/agents/$name.md" ]]; then
    printf 'native-md\t%s\n' "$runtime_root/agents/$name.md"
    return 0
  fi

  echo "Error: native-md not found for '$name' (runtime=$runtime)" >&2
  return 1
}

agent_adapter_native_md_to_native_passthrough() {
  local name="${1:-}"
  local runtime="${2:-}"
  local workspace="${3:-}"

  if [[ -z "$name" || -z "$runtime" || -z "$workspace" ]]; then
    echo "Error: name, runtime, and workspace are required" >&2
    return 2
  fi

  local runtime_root
  runtime_root="$(ralph_resolve_runtime_root "$runtime" "$workspace" 2>/dev/null)" || runtime_root=""

  if [[ -z "$runtime_root" ]]; then
    echo "Error: could not resolve runtime root for '$runtime'" >&2
    return 1
  fi

  local src="$runtime_root/agents/$name.md"

  if [[ ! -r "$src" ]]; then
    echo "Error: native agent .md not found: $src" >&2
    return 1
  fi

  # Parse frontmatter fields
  local model description tools_list instruction_body
  model="$(agent_source_fm_scalar "$src" "model")"
  description="$(agent_source_fm_scalar "$src" "description")"
  tools_list="$(agent_source_fm_list "$src" "tools")"
  instruction_body="$(agent_source_fm_body "$src")"

  # Convert tools list to CSV for allowed_tools
  local allowed_tools_csv=""
  if [[ -n "$tools_list" ]]; then
    allowed_tools_csv="$(printf '%s\n' "$tools_list" | paste -sd ',' - | sed 's/,/, /g')"
  fi

  # Output shell variable assignments
  printf 'native_passthrough_name=%s\n' "$(agent_source_json_string "$name")"
  printf 'native_passthrough_model=%s\n' "$(agent_source_json_string "$model")"
  printf 'native_passthrough_allowed_tools=%s\n' "$(agent_source_json_string "$allowed_tools_csv")"
  printf 'native_passthrough_description=%s\n' "$(agent_source_json_string "$description")"
  # Escape instruction body for shell assignment
  local escaped_body
  escaped_body="$(printf '%s' "$instruction_body" | sed 's/\\/\\\\/g' | sed "s/'/'\\\\''/g")"
  printf 'native_passthrough_instruction_body=%s\n' "'$escaped_body'"

  return 0
}

# Generate a normalized config.json from a native runtime agent .md.
# This preserves the runtime's native model/description/tools, carries
# mcp_servers from frontmatter into the normalized config.json shape, and
# captures the instruction body.  It is used by `ralph agent show` when the
# selected source is native-md and native passthrough is not in play.
agent_adapter_native_md_to_config_json() {
  local name="${1:-}"
  local runtime="${2:-}"
  local workspace="${3:-}"
  local cache_dir="${4:-}"

  if [[ -z "$name" || -z "$runtime" || -z "$workspace" || -z "$cache_dir" ]]; then
    echo "Error: name, runtime, workspace, and cache_dir are required" >&2
    return 2
  fi

  runtime="$(ralph_normalize_runtime_name "$runtime")"

  local runtime_root
  runtime_root="$(ralph_resolve_runtime_root "$runtime" "$workspace" 2>/dev/null)" || runtime_root=""

  if [[ -z "$runtime_root" ]]; then
    echo "Error: could not resolve runtime root for '$runtime'" >&2
    return 1
  fi

  local src="$runtime_root/agents/$name.md"

  if [[ ! -r "$src" ]]; then
    echo "Error: native agent .md not found: $src" >&2
    return 1
  fi

  local model description tools_list instruction_body skills_list mcp_servers
  model="$(agent_source_fm_scalar "$src" "model")"
  description="$(agent_source_fm_scalar "$src" "description")"
  tools_list="$(agent_source_fm_list "$src" "tools")"
  skills_list="$(agent_source_fm_list "$src" "skills")"
  instruction_body="$(agent_source_fm_body "$src")"
  mcp_servers="$(agent_source_fm_mcp_servers "$src" 2>/dev/null || true)"

  local allowed_tools_csv=""
  if [[ -n "$tools_list" ]]; then
    allowed_tools_csv="$(printf '%s\n' "$tools_list" | paste -sd ',' - | sed 's/,/, /g')"
  fi

  local dest
  mkdir -p "$cache_dir"
  dest="$cache_dir/$name.config.json"

  {
    printf '{\n'
    printf '  "name": %s,\n' "$(agent_source_json_string "$name")"
    printf '  "model": %s,\n' "$(agent_source_json_string "$model")"
    printf '  "description": %s,\n' "$(agent_source_json_string "$description")"
    printf '  "rules": [],\n'
    printf '  "skills": [\n'
    local first=1 skill
    while IFS= read -r skill; do
      [[ -n "$skill" ]] || continue
      if [[ "$first" -eq 0 ]]; then
        printf ',\n'
      fi
      printf '    %s' "$(agent_source_json_string "$skill")"
      first=0
    done <<< "$skills_list"
    printf '\n  ]'
    if [[ -n "$allowed_tools_csv" ]]; then
      printf ',\n  "allowed_tools": %s' "$(agent_source_json_string "$allowed_tools_csv")"
    fi
    if [[ -n "$mcp_servers" ]]; then
      printf ',\n  "mcp_servers": [\n'
      first=1
      local entry
      while IFS= read -r entry; do
        [[ -n "$entry" ]] || continue
        if [[ "$first" -eq 0 ]]; then
          printf ',\n'
        fi
        printf '    %s' "$entry"
        first=0
      done <<< "$mcp_servers"
      printf '\n  ]'
    fi
    printf ',\n  "instruction_body": %s\n' "$(agent_source_json_string "$instruction_body")"
    printf '}\n'
  } > "$dest"

  printf '%s\n' "$dest"
}
