# Resource-resolution helpers for the MCP server.

# Normalize a candidate path into a canonical absolute path.
# Args: $1 - raw path to canonicalize (may contain ~ or relative segments).
# Returns: 0 on success, 1 on failure.
canonicalize_path() {
  local raw="$1"
  local expanded="$raw"
  if [[ "$expanded" == "~" ]]; then
    expanded="$HOME"
  elif [[ "$expanded" == ~/* ]]; then
    expanded="$HOME/${expanded#~/}"
  fi
  local dir
  dir="$(cd "$(dirname "$expanded")" 2>/dev/null && pwd)" || return 1
  printf '%s/%s\n' "$dir" "$(basename "$expanded")"
}

# Append a directory to the allowlist if it is not already present.
# Args: $1 - absolute path to add to the allowlist.
# Returns: 0 on success, 1 on failure.
add_allowlist_root() {
  local root="$1"
  for existing in "${ALLOWLIST_ROOTS[@]-}"; do
    [[ "$existing" == "$root" ]] && return 0
  done
  ALLOWLIST_ROOTS+=("$root")
  return 0
}

# Expand RALPH_MCP_ALLOWLIST entries and ensure the workspace is allowlisted.
# Args: none.
# Returns: 0 on success, 1 when an allowlist entry is invalid.
build_allowlist() {
  local raw="${RALPH_MCP_ALLOWLIST:-}"
  if [[ -n "$raw" ]]; then
    local normalized
    normalized="$(printf '%s\n' "$raw" | tr ',;:' '\n')"
    local entry
    while IFS= read -r entry; do
      entry="${entry#"${entry%%[![:space:]]*}"}"
      entry="${entry%"${entry##*[![:space:]]}"}"
      if [[ -z "${entry//[[:space:]]/}" ]]; then
        continue
      fi
      local candidate="$entry"
      if [[ "$candidate" == ~* ]]; then
        :
      elif [[ "$candidate" != /* ]]; then
        candidate="$WORKSPACE_ROOT/$candidate"
      fi
      candidate="$(canonicalize_path "$candidate")" || fail "allowlist entry invalid: $entry"
      if [[ ! -d "$candidate" ]]; then
        fail "allowlist entry is not a directory: $candidate"
      fi
      add_allowlist_root "$candidate"
    done <<< "$normalized"
  fi
  add_allowlist_root "$WORKSPACE_ROOT"
}

# Determine whether a path lives under any allowlisted root.
# Args: $1 - absolute candidate path to validate.
# Returns: 0 when allowed, 1 otherwise.
workspace_allowed() {
  local candidate="$1"
  for root in "${ALLOWLIST_ROOTS[@]-}"; do
    if [[ "$root" == "/" ]]; then
      [[ "$candidate" == /* ]] && return 0
      continue
    fi
    if [[ "$candidate" == "$root" || "$candidate" == "$root/"* ]]; then
      return 0
    fi
  done
  return 1
}

# Check if the given path is within the configured workspace root prefix.
# Args: $1 - canonicalized path to test.
# Returns: 0 when the path lies inside the workspace, 1 otherwise.
is_subpath() {
  local candidate="$1"
  if [[ -z "$WORKSPACE_ROOT" ]]; then
    return 1
  fi
  if [[ "$WORKSPACE_ROOT" == "/" ]]; then
    [[ "$candidate" == /* ]]
    return
  fi
  [[ "$candidate" == "$WORKSPACE_ROOT" || "$candidate" == "$WORKSPACE_ROOT_PREFIX"* ]]
}

# Resolve a workspace reference into an allowlisted directory.
# Args: $1 - workspace path provided by the client.
# Returns: 0 on success with the path printed, non-zero for various errors.
resolve_workspace() {
  local value="$1"
  if [[ -z "$value" ]]; then
    return 1
  fi
  local candidate
  if [[ "$value" == /* ]]; then
    candidate="$value"
  else
    candidate="$WORKSPACE_ROOT/$value"
  fi
  local canonical
  canonical="$(canonicalize_path "$candidate")" || return 2
  if [[ ! -d "$canonical" ]]; then
    return 3
  fi
  if ! workspace_allowed "$canonical"; then
    return 4
  fi
  printf '%s\n' "$canonical"
}

readonly RALPH_MCP_AGENT_CATALOG_RESOURCE_URI="resource://ralph/agents"

generate_agent_catalog_markdown() {
  local workspace="${WORKSPACE_ROOT:-}"
  local runtimes=("cursor" "claude" "codex")
  local catalog="# Ralph agent catalog"
  catalog+="\n\n"
  if [[ -n "$workspace" ]]; then
    catalog+="Workspace root: \`$workspace\`"
  else
    catalog+="Workspace root: (unknown)"
  fi
  catalog+="\n"

  local has_any_agent=0
  for runtime in "${runtimes[@]}"; do
    local runtime_dir="$workspace/.${runtime}/agents"
    if [[ ! -d "$runtime_dir" ]]; then
      continue
    fi
    local section=""
    local agent_dir
    for agent_dir in "$runtime_dir"/*; do
      [[ -d "$agent_dir" ]] || continue
      local agent_id
      agent_id="$(basename "$agent_dir")"
      local config_path="$agent_dir/config.json"
      [[ -f "$config_path" ]] || continue
      local name
      name="$(jq -r '.name // ""' "$config_path")"
      local model
      model="$(jq -r '.model // ""' "$config_path")"
      local description
      description="$(jq -r '.description // ""' "$config_path")"
      [[ -z "$name" ]] && name="$agent_id"
      local relative_config=".${runtime}/agents/${agent_id}/config.json"

      section+="- **$name** (\`$relative_config\`)\n"
      if [[ -n "$model" ]]; then
        section+="  - model: \`$model\`\n"
      fi
      if [[ -n "$description" ]]; then
        section+="  - $description\n"
      fi
      section+="\n"
    done
    if [[ -z "$section" ]]; then
      continue
    fi
    local runtime_label="$(tr '[:lower:]' '[:upper:]' <<<"${runtime:0:1}")${runtime:1}"
    catalog+="\n## ${runtime_label} agents\n\n"
    catalog+="$section"
    has_any_agent=1
  done

  if [[ "$has_any_agent" -eq 0 ]]; then
    catalog+="\n*No agent configurations were found.*\n"
  fi

  printf '%s\n' "$catalog"
}

# Resolve a plan path inside the workspace while respecting allowlist rules.
# Args: $1 - workspace base; $2 - plan path argument.
# Returns: 0 on success with the resolved path, non-zero on failure.
resolve_plan_path() {
  local workspace="$1"
  local plan_value="$2"
  local candidate
  if [[ "$plan_value" == /* ]]; then
    candidate="$plan_value"
  else
    candidate="$workspace/$plan_value"
  fi
  local canonical
  canonical="$(canonicalize_path "$candidate")" || return 1
  if ! is_subpath "$canonical"; then
    return 2
  fi
  if ! workspace_allowed "$canonical"; then
    return 4
  fi
  printf '%s\n' "$canonical"
}

# Resolve an orchestration spec path under the workspace.
# Args: $1 - workspace base; $2 - orchestration file path.
# Returns: 0 on success with the resolved path, non-zero on failure.
resolve_orchestration_path() {
  local workspace="$1"
  local path_value="$2"
  local candidate
  if [[ "$path_value" == /* ]]; then
    candidate="$path_value"
  else
    candidate="$workspace/$path_value"
  fi
  local canonical
  canonical="$(canonicalize_path "$candidate")" || return 1
  if ! is_subpath "$canonical"; then
    return 2
  fi
  if ! workspace_allowed "$canonical"; then
    return 4
  fi
  if [[ ! -f "$canonical" ]]; then
    return 3
  fi
  printf '%s\n' "$canonical"
}
