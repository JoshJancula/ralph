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
