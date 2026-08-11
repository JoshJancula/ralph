#!/usr/bin/env bash
# Frozen, backend-neutral source base for isolated graph runs.
#
# Snapshot capture is filesystem based and accepts stable dirty or non-Git
# sources. Worktree mode uses the same source base but additionally requires a
# clean Git worktree after Ralph-owned exclusions. RALPH_GRAPH_SECRET_EXCLUDES
# is a newline-delimited list of project-relative files or directories that
# must not enter the base. Documented cache directories are excluded by the
# capture helper: .cache, node_modules, __pycache__, .pytest_cache,
# .mypy_cache, .ruff_cache, .tox, .venv, and any .git directory.

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  echo "This file is meant to be sourced, not executed." >&2
  exit 1
fi

GRAPH_RUN_BASE_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GRAPH_RUN_BASE_RALPH_ROOT="$(cd "$GRAPH_RUN_BASE_SCRIPT_DIR/../.." && pwd)"
GRAPH_RUN_BASE_HELPER="$GRAPH_RUN_BASE_RALPH_ROOT/python/graph_source_snapshot.py"
GRAPH_RUN_BASE_TOOL_VERSION="graph-run-base-v1"

if ! declare -F ralph_atomic_write_json >/dev/null 2>&1; then
  # shellcheck source=../atomic-json.sh
  source "$GRAPH_RUN_BASE_SCRIPT_DIR/../atomic-json.sh"
fi

graph_run_base_real_dir() {
  local path="$1"
  [[ -n "$path" && -d "$path" ]] || return 1
  (cd "$path" 2>/dev/null && pwd -P)
}

# Resolve the three graph roots without conflating the invocation directory
# with the project or state root. The explicit run-plan environment wins.
graph_run_base_resolve_roots() {
  local invocation="${1:-$(pwd)}" project="" state="" agent="" cursor git_root
  invocation="$(graph_run_base_real_dir "$invocation")" || {
    echo "Error: graph invocation directory does not exist: ${1:-}" >&2
    return 1
  }
  if [[ -n "${RALPH_PROJECT_ROOT:-}" ]]; then
    project="$(graph_run_base_real_dir "$RALPH_PROJECT_ROOT")" || {
      echo "Error: RALPH_PROJECT_ROOT is not a directory: $RALPH_PROJECT_ROOT" >&2
      return 1
    }
  else
    cursor="$invocation"
    while [[ "$cursor" != "/" ]]; do
      if [[ -d "$cursor/.ralph" || -L "$cursor/.ralph" ]]; then
        project="$cursor"
        break
      fi
      cursor="$(dirname "$cursor")"
    done
    if [[ -z "$project" ]] && command -v git >/dev/null 2>&1; then
      git_root="$(git -C "$invocation" rev-parse --show-toplevel 2>/dev/null)" || git_root=""
      [[ -n "$git_root" ]] && project="$(graph_run_base_real_dir "$git_root")"
    fi
    [[ -n "$project" ]] || project="$invocation"
  fi
  agent="${RALPH_AGENT_WORKSPACE:-$invocation}"
  agent="$(graph_run_base_real_dir "$agent")" || {
    echo "Error: RALPH_AGENT_WORKSPACE is not a directory: $agent" >&2
    return 1
  }
  state="${RALPH_PLAN_WORKSPACE_ROOT:-$project/.ralph-workspace}"
  mkdir -p "$state" || {
    echo "Error: cannot create graph state root: $state" >&2
    return 1
  }
  state="$(graph_run_base_real_dir "$state")" || return 1
  jq -cn --arg project "$project" --arg state "$state" --arg agent "$agent" \
    '{projectRoot:$project,stateRoot:$state,agentWorkspace:$agent}'
}

# Print the unique workspace modes requested by a frozen graph. Omitted mode
# means shared so old graph plans do not auto-upgrade to isolation.
graph_run_base_modes_json() {
  local graph_json="$1"
  [[ -f "$graph_json" ]] || return 1
  jq -c '[.nodes[].stage.workspaceMode // "shared"] | unique' "$graph_json"
}

graph_run_base_sha256_file() {
  local path="$1"
  [[ -f "$path" ]] || return 1
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$path" | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$path" | awk '{print $1}'
  elif command -v openssl >/dev/null 2>&1; then
    openssl dgst -sha256 "$path" | awk '{print $NF}'
  else
    echo "Error: no sha256 tool available" >&2
    return 1
  fi
}

graph_run_base_git_metadata() {
  local project_root="$1" state_root="$2" exclude_file="$3" require_clean="$4"
  local git_root head branch tree index_file index_hash status_file status_json
  command -v git >/dev/null 2>&1 || {
    [[ "$require_clean" == 1 ]] && echo "Error: worktree mode requires Git" >&2
    [[ "$require_clean" == 1 ]] && return 1
    printf 'null\n'
    return 0
  }
  git_root="$(git -C "$project_root" rev-parse --show-toplevel 2>/dev/null)" || git_root=""
  if [[ -z "$git_root" ]]; then
    if [[ "$require_clean" == 1 ]]; then
      echo "Error: worktree mode requires a Git repository" >&2
      return 1
    fi
    printf 'null\n'
    return 0
  fi
  git_root="$(graph_run_base_real_dir "$git_root")" || return 1
  if [[ "$git_root" != "$project_root" ]]; then
    if [[ "$require_clean" == 1 ]]; then
      echo "Error: worktree mode requires the graph project root to equal the Git worktree root" >&2
      return 1
    fi
    printf 'null\n'
    return 0
  fi
  status_file="$(mktemp "${TMPDIR:-/tmp}/ralph-graph-git-status.XXXXXX")" || return 1
  if ! git -C "$project_root" status --porcelain=v1 -z --untracked-files=all --ignored=matching >"$status_file"; then
    rm -f "$status_file"
    echo "Error: failed to inspect Git worktree status" >&2
    return 1
  fi
  status_json="$(python3 "$GRAPH_RUN_BASE_HELPER" git-status \
    --source "$project_root" --state-root "$state_root" \
    --status-file "$status_file" --exclude-file "$exclude_file")" || {
      rm -f "$status_file"
      return 1
    }
  rm -f "$status_file"
  if [[ "$require_clean" == 1 && "$(printf '%s' "$status_json" | jq -r '.clean')" != true ]]; then
    echo "Error: worktree mode requires a clean tracked and untracked worktree after exclusions" >&2
    return 1
  fi
  head="$(git -C "$project_root" rev-parse --verify HEAD 2>/dev/null)" || head=""
  branch="$(git -C "$project_root" symbolic-ref --quiet --short HEAD 2>/dev/null)" || branch=""
  if [[ "$require_clean" == 1 && -z "$head" ]]; then
    echo "Error: worktree mode requires a Git HEAD" >&2
    return 1
  fi
  tree="$(git -C "$project_root" rev-parse --verify 'HEAD^{tree}' 2>/dev/null)" || tree=""
  # Hash the semantic index entries, not the index file bytes. Git may refresh
  # stat-cache bytes during a read-only status check even when staged content is
  # unchanged, which would create false caller-drift refusals after rollback.
  index_file="$(mktemp "${TMPDIR:-/tmp}/ralph-graph-git-index.XXXXXX")" || return 1
  if ! git -C "$project_root" ls-files --stage -z >"$index_file"; then
    rm -f "$index_file"
    echo "Error: failed to inspect Git index" >&2
    return 1
  fi
  index_hash="$(graph_run_base_sha256_file "$index_file")"
  rm -f "$index_file"
  jq -cn \
    --arg head "$head" \
    --arg branch "$branch" \
    --arg tree "$tree" \
    --arg index "$index_hash" \
    --arg status "$(printf '%s' "$status_json" | jq -r '.fingerprint')" \
    --argjson clean "$(printf '%s' "$status_json" | jq '.clean')" \
    '{head:($head | if length == 0 then null else . end),
      branch:($branch | if length == 0 then null else . end),
      treeHash:($tree | if length == 0 then null else . end),
      indexHash:($index | if length == 0 then null else . end),
      statusFingerprint:$status,
      clean:$clean}'
}

graph_run_base_update_run_json() {
  local run_file="$1" roots_json="$2" source_base_json="$3" base_json
  [[ -f "$run_file" ]] || {
    echo "Error: graph run ledger is missing run.json: $run_file" >&2
    return 1
  }
  base_json="$(jq -c . "$run_file" 2>/dev/null)" || return 1
  ralph_atomic_write_json "$run_file" \
    '(($base | fromjson) // {}) + {roots:$roots, sourceBase:$sourceBase}' \
    --arg base "$base_json" --argjson roots "$roots_json" \
    --argjson sourceBase "$source_base_json"
}

# graph_run_base_prepare <run-dir> <roots-json> <modes-json>
#
# Captures one immutable filesystem base whenever snapshot or worktree is
# requested. Shared-only graphs only record their roots and lack of isolation.
graph_run_base_prepare() {
  local run_dir="$1" roots_json="$2" modes_json="$3"
  local project_root state_root agent_workspace run_file base_dir source_dir manifest
  local exclude_file require_clean=0 capture_json git_json git_json_after verify_json
  local source_base ralph_version secret_excludes_json
  command -v jq >/dev/null 2>&1 || return 1
  command -v python3 >/dev/null 2>&1 || {
    echo "Error: python3 is required to capture an isolated graph run base" >&2
    return 1
  }
  printf '%s' "$modes_json" | jq -e '
    type == "array" and length > 0 and
    all(.[]; . == "shared" or . == "snapshot" or . == "worktree")
  ' >/dev/null || {
    echo "Error: invalid graph workspace mode set" >&2
    return 1
  }
  run_dir="$(graph_run_base_real_dir "$run_dir")" || {
    echo "Error: graph run directory does not exist: $run_dir" >&2
    return 1
  }
  project_root="$(graph_run_base_real_dir "$(printf '%s' "$roots_json" | jq -r '.projectRoot')")" || project_root=""
  state_root="$(graph_run_base_real_dir "$(printf '%s' "$roots_json" | jq -r '.stateRoot')")" || state_root=""
  agent_workspace="$(graph_run_base_real_dir "$(printf '%s' "$roots_json" | jq -r '.agentWorkspace')")" || agent_workspace=""
  [[ -n "$project_root" && -n "$state_root" && -n "$agent_workspace" ]] || {
    echo "Error: graph run roots must be existing directories" >&2
    return 1
  }
  roots_json="$(jq -cn --arg project "$project_root" --arg state "$state_root" \
    --arg agent "$agent_workspace" \
    '{projectRoot:$project,stateRoot:$state,agentWorkspace:$agent}')"
  run_file="$run_dir/run.json"
  ralph_version="$(graph_state_ralph_version)"

  if ! printf '%s' "$modes_json" | jq -e 'any(.[]; . == "snapshot" or . == "worktree")' >/dev/null; then
    source_base="$(jq -cn --argjson modes "$modes_json" \
      --arg tool "$GRAPH_RUN_BASE_TOOL_VERSION" --arg rv "$ralph_version" \
      '{schemaVersion:1,requestedModes:$modes,immutable:false,
        backendNeutral:false,filesystemIdentity:null,manifestPath:null,
        sourcePath:null,git:null,toolVersion:$tool,ralphVersion:$rv}')"
    graph_run_base_update_run_json "$run_file" "$roots_json" "$source_base"
    return
  fi

  exclude_file="$(mktemp "${TMPDIR:-/tmp}/ralph-graph-excludes.XXXXXX")" || return 1
  printf '%s\n' "${RALPH_GRAPH_SECRET_EXCLUDES:-}" >"$exclude_file"
  secret_excludes_json="$(awk '
    {
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", $0)
      if ($0 != "" && substr($0, 1, 1) != "#") print
    }
  ' "$exclude_file" | jq -Rsc 'split("\n") | map(select(length > 0))')"
  if printf '%s' "$modes_json" | jq -e 'any(.[]; . == "worktree")' >/dev/null; then
    require_clean=1
  fi
  git_json="$(graph_run_base_git_metadata "$project_root" "$state_root" "$exclude_file" "$require_clean")" || {
    rm -f "$exclude_file"
    return 1
  }

  base_dir="$run_dir/base"
  source_dir="$base_dir/source"
  manifest="$base_dir/manifest.json"
  if [[ -e "$base_dir" ]]; then
    rm -f "$exclude_file"
    echo "Error: graph run base already exists: $base_dir" >&2
    return 1
  fi
  mkdir -p "$base_dir" || {
    rm -f "$exclude_file"
    return 1
  }
  capture_json="$(python3 "$GRAPH_RUN_BASE_HELPER" capture \
    --source "$project_root" --state-root "$state_root" \
    --destination "$source_dir" --manifest "$manifest" \
    --exclude-file "$exclude_file" \
    --delay-ms "${RALPH_GRAPH_BASE_TEST_DELAY_MS:-0}" \
    --ready-file "${RALPH_GRAPH_BASE_TEST_READY_FILE:-}")" || {
      rm -f "$exclude_file"
      rm -rf "$base_dir"
      return 1
    }
  git_json_after="$(graph_run_base_git_metadata "$project_root" "$state_root" "$exclude_file" "$require_clean")" || {
    rm -f "$exclude_file"
    chmod -R u+w "$base_dir" 2>/dev/null || true
    rm -rf "$base_dir"
    return 1
  }
  verify_json="$(python3 "$GRAPH_RUN_BASE_HELPER" identity \
    --source "$project_root" --state-root "$state_root" \
    --exclude-file "$exclude_file")" || {
      rm -f "$exclude_file"
      chmod -R u+w "$base_dir" 2>/dev/null || true
      rm -rf "$base_dir"
      return 1
    }
  if [[ "$(printf '%s' "$git_json" | jq -cS .)" != "$(printf '%s' "$git_json_after" | jq -cS .)" \
    || "$(printf '%s' "$capture_json" | jq -r '.filesystemIdentity')" != "$(printf '%s' "$verify_json" | jq -r '.filesystemIdentity')" ]]; then
    rm -f "$exclude_file"
    chmod -R u+w "$base_dir" 2>/dev/null || true
    rm -rf "$base_dir"
    echo "Error: source or Git provenance changed while materializing frozen run base" >&2
    return 1
  fi
  rm -f "$exclude_file"
  chmod -R a-w "$source_dir" "$manifest" 2>/dev/null || {
    chmod -R u+w "$base_dir" 2>/dev/null || true
    rm -rf "$base_dir"
    echo "Error: failed to make graph run base read-only" >&2
    return 1
  }
  source_base="$(jq -cn \
    --argjson modes "$modes_json" \
    --arg identity "$(printf '%s' "$capture_json" | jq -r '.filesystemIdentity')" \
    --arg manifest "$manifest" \
    --arg source "$source_dir" \
    --argjson git "$git_json" \
    --argjson secretExcludes "$secret_excludes_json" \
    --arg tool "$GRAPH_RUN_BASE_TOOL_VERSION" \
    --arg rv "$ralph_version" \
    '{schemaVersion:1,requestedModes:$modes,immutable:true,
      backendNeutral:true,filesystemIdentity:$identity,
      manifestPath:$manifest,sourcePath:$source,git:$git,
      secretExcludes:$secretExcludes,
      toolVersion:$tool,ralphVersion:$rv}')"
  if ! graph_run_base_update_run_json "$run_file" "$roots_json" "$source_base"; then
    chmod -R u+w "$base_dir" 2>/dev/null || true
    rm -rf "$base_dir"
    return 1
  fi
}
