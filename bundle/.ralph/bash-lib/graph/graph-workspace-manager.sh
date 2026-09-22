#!/usr/bin/env bash
# Durable graph node workspaces with snapshot, worktree, and shared backends.
#
# Operator-authored configuration lives at:
#   <project-root>/.ralph/graph-workspaces.json
# It is frozen into run.json before node dispatch. Graph plans may name a
# setupProfile, but commands, include patterns, and ignored-path allowances
# are accepted only from that project configuration file.

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  echo "This file is meant to be sourced, not executed." >&2
  exit 1
fi

GRAPH_WORKSPACE_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GRAPH_WORKSPACE_RALPH_ROOT="$(cd "$GRAPH_WORKSPACE_SCRIPT_DIR/../.." && pwd)"
GRAPH_WORKSPACE_HELPER="$GRAPH_WORKSPACE_RALPH_ROOT/python/graph_source_snapshot.py"
GRAPH_WORKSPACE_INTEGRATE_HELPER="$GRAPH_WORKSPACE_RALPH_ROOT/python/graph_integrate.py"
GRAPH_WORKSPACE_SCHEMA_VERSION=1
# Set by _graph_workspace_archive_changeset: reconstruction | fallback
GRAPH_WORKSPACE_LAST_ARCHIVE_MODE=""

if ! declare -F ralph_atomic_write_json >/dev/null 2>&1; then
  # shellcheck source=../atomic-json.sh
  source "$GRAPH_WORKSPACE_SCRIPT_DIR/../atomic-json.sh"
fi
if ! declare -F graph_state_reconcile_run_owner_file >/dev/null 2>&1; then
  # shellcheck source=graph-state.sh
  source "$GRAPH_WORKSPACE_SCRIPT_DIR/graph-state.sh"
fi

graph_workspace_real_dir() {
  local path="$1"
  [[ -n "$path" && -d "$path" && ! -L "$path" ]] || return 1
  (cd "$path" 2>/dev/null && pwd -P)
}

graph_workspace_sha256_text() {
  local value="$1"
  if command -v sha256sum >/dev/null 2>&1; then
    printf '%s' "$value" | sha256sum | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    printf '%s' "$value" | shasum -a 256 | awk '{print $1}'
  elif command -v openssl >/dev/null 2>&1; then
    printf '%s' "$value" | openssl dgst -sha256 | awk '{print $NF}'
  else
    echo "Error: no sha256 tool available" >&2
    return 1
  fi
}

graph_workspace_node_key() {
  local node_id="$1" safe digest
  [[ -n "$node_id" && "$node_id" != *$'\n'* && "$node_id" != *$'\r'* ]] || {
    echo "Error: graph workspace node id must be a non-empty single line" >&2
    return 1
  }
  safe="$(printf '%s' "$node_id" | sed 's/[^A-Za-z0-9._-]/_/g')"
  safe="${safe:0:80}"
  [[ -n "$safe" && "$safe" != "." && "$safe" != ".." ]] || safe="node"
  digest="$(graph_workspace_sha256_text "$node_id")" || return 1
  printf '%s-%s\n' "$safe" "${digest:0:12}"
}

graph_workspace_config_path() {
  local project_root="$1"
  printf '%s/.ralph/graph-workspaces.json\n' "$project_root"
}

_graph_workspace_validate_config() {
  local config="$1"
  jq -e '
    type == "object" and
    ((keys - ["schemaVersion","retention","setupProfiles"]) | length == 0) and
    (.schemaVersion == 1) and
    ((.retention // "keep") == "keep" or (.retention // "keep") == "prune") and
    ((.setupProfiles // {}) | type == "object") and
    all((.setupProfiles // {}) | to_entries[];
      (.key | type == "string" and length > 0 and test("^[A-Za-z0-9._-]+$")) and
      (.value | type == "object") and
      ((.value | keys - ["commands","includePatterns","allowedIgnoredPaths"]) | length == 0) and
      ((.value.commands // []) | type == "array" and all(.[]; type == "string" and length > 0)) and
      ((.value.includePatterns // []) | type == "array" and all(.[]; type == "string" and length > 0)) and
      ((.value.allowedIgnoredPaths // []) | type == "array" and all(.[]; type == "string" and length > 0))
    )
  ' "$config" >/dev/null || {
    echo "Error: invalid graph workspace configuration: $config" >&2
    return 1
  }
}

# graph_workspace_prepare_run <run-dir> <graph-json>
# Freeze trusted project setup configuration into run.json. Existing frozen
# configuration is reused byte-for-byte on resume.
graph_workspace_prepare_run() {
  local run_dir="$1" graph_json="$2"
  local run_file run_json project_root config_path config_json config_sha retention
  [[ -f "$graph_json" ]] || {
    echo "Error: graph workspace manager requires graph.json" >&2
    return 1
  }
  run_dir="$(graph_workspace_real_dir "$run_dir")" || {
    echo "Error: graph workspace run directory must be an explicit real directory: $run_dir" >&2
    return 1
  }
  run_file="$run_dir/run.json"
  [[ -f "$run_file" ]] || {
    echo "Error: graph workspace manager requires run.json: $run_file" >&2
    return 1
  }
  if jq -e '.workspaceManager.schemaVersion == 1' "$run_file" >/dev/null 2>&1; then
    return 0
  fi
  run_json="$(jq -c . "$run_file")" || return 1
  project_root="$(printf '%s' "$run_json" | jq -r '.roots.projectRoot // empty')"
  project_root="$(graph_workspace_real_dir "$project_root")" || {
    echo "Error: run.json has no valid project root" >&2
    return 1
  }
  config_path="$(graph_workspace_config_path "$project_root")"
  if [[ -e "$config_path" && ( ! -f "$config_path" || -L "$config_path" ) ]]; then
    echo "Error: graph workspace configuration must be a regular non-symlink file: $config_path" >&2
    return 1
  fi
  if [[ -f "$config_path" ]]; then
    _graph_workspace_validate_config "$config_path" || return 1
    config_json="$(jq -cS . "$config_path")" || return 1
  else
    # New graph runs default to reclaiming isolated node copies. Existing run
    # ledgers retain their frozen workspaceManager block unchanged on resume.
    config_json='{"retention":"prune","schemaVersion":1,"setupProfiles":{}}'
    config_path=""
  fi
  if jq -e '
      [.nodes[].stage
       | keys[]
       | select(. == "setupCommands" or . == "includePatterns" or . == "allowedIgnoredPaths")]
      | length > 0
    ' "$graph_json" >/dev/null; then
    echo "Error: setup commands and include paths must come from project graph-workspaces.json, not graph stages" >&2
    return 1
  fi
  while IFS= read -r profile || [[ -n "$profile" ]]; do
    [[ -z "$profile" ]] && continue
    if ! printf '%s' "$config_json" | jq -e --arg name "$profile" '.setupProfiles | has($name)' >/dev/null; then
      echo "Error: graph stage references unknown operator setup profile: $profile" >&2
      return 1
    fi
  done < <(jq -r '.nodes[].stage.setupProfile // empty' "$graph_json")
  config_sha="$(graph_workspace_sha256_text "$config_json")" || return 1
  retention="$(printf '%s' "$config_json" | jq -r '.retention // "prune"')"
  ralph_atomic_write_json "$run_file" \
    '(($base | fromjson) // {}) + {
      workspaceManager: {
        schemaVersion: $sv,
        retention: $retention,
        configPath: (if $configPath == "" then null else $configPath end),
        configSha: $configSha,
        setupProfiles: $profiles
      }
    }' \
    --arg base "$run_json" \
    --argjson sv "$GRAPH_WORKSPACE_SCHEMA_VERSION" \
    --arg retention "$retention" \
    --arg configPath "$config_path" \
    --arg configSha "$config_sha" \
    --argjson profiles "$(printf '%s' "$config_json" | jq -c '.setupProfiles // {}')"
}

_graph_workspace_metadata_path() {
  local run_dir="$1" node_key="$2"
  printf '%s/workspaces/metadata/%s.json\n' "$run_dir" "$node_key"
}

_graph_workspace_expected_path() {
  local run_dir="$1" node_key="$2"
  printf '%s/workspaces/nodes/%s\n' "$run_dir" "$node_key"
}

_graph_workspace_validate_owned_roots() {
  local run_dir="$1" create="${2:-0}" workspace_root nodes_root metadata_root resolved
  workspace_root="$run_dir/workspaces"
  nodes_root="$workspace_root/nodes"
  metadata_root="$workspace_root/metadata"
  if [[ "$create" == 1 ]]; then
    mkdir -p "$nodes_root" "$metadata_root" || return 1
  fi
  for resolved in "$workspace_root" "$nodes_root" "$metadata_root"; do
    [[ -d "$resolved" && ! -L "$resolved" ]] || {
      echo "Error: graph workspace ownership directory is missing or unsafe: $resolved" >&2
      return 1
    }
    [[ "$(cd "$resolved" 2>/dev/null && pwd -P)" == "$resolved" ]] || {
      echo "Error: graph workspace ownership directory must not traverse symlinks: $resolved" >&2
      return 1
    }
  done
}

_graph_workspace_log() {
  local run_dir="$1"
  shift
  printf '[%s] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" \
    >>"$run_dir/workspaces/workspace-manager.log"
}

_graph_workspace_write_metadata() {
  local metadata="$1" run_id="$2" node_id="$3" mode="$4" path="$5" profile="$6" status="$7"
  ralph_atomic_write_json "$metadata" \
    '{schemaVersion:$sv,ownerRunId:$runId,nodeId:$nodeId,mode:$mode,
      workspacePath:$path,isolation:($mode != "shared"),
      setupProfile:(if $profile == "" then null else $profile end),
      status:$status,includesApplied:false,setupCompleted:0}' \
    --argjson sv "$GRAPH_WORKSPACE_SCHEMA_VERSION" \
    --arg runId "$run_id" --arg nodeId "$node_id" --arg mode "$mode" \
    --arg path "$path" --arg profile "$profile" --arg status "$status"
}

_graph_workspace_update_progress() {
  local metadata="$1" status="$2" includes="$3" completed="$4" base
  base="$(jq -c . "$metadata")" || return 1
  ralph_atomic_write_json "$metadata" \
    '($base | fromjson)
     | .status = $status
     | .includesApplied = $includes
     | .setupCompleted = $completed' \
    --arg base "$base" --arg status "$status" \
    --argjson includes "$includes" --argjson completed "$completed"
}

_graph_workspace_worktree_registered() {
  local project_root="$1" path="$2"
  git -C "$project_root" worktree list --porcelain 2>/dev/null |
    awk -v wanted="$path" '
      $1 == "worktree" { current = substr($0, 10) }
      current == wanted { found = 1 }
      END { exit(found ? 0 : 1) }
    '
}

_graph_workspace_journal_git() {
  local run_dir="$1" node_key="$2" action="$3" phase="$4" path="$5" head="$6"
  local journal_root journal_dir stamp entry
  run_dir="$(graph_workspace_real_dir "$run_dir")" || return 1
  journal_root="$run_dir/workspaces/git-journal"
  [[ ! -L "$journal_root" ]] || {
    echo "Error: graph workspace Git journal root must not be a symlink" >&2
    return 1
  }
  mkdir -p "$journal_root" || return 1
  [[ "$(cd "$journal_root" 2>/dev/null && pwd -P)" == "$journal_root" ]] || {
    echo "Error: graph workspace Git journal root must not traverse symlinks" >&2
    return 1
  }
  journal_dir="$journal_root/$node_key"
  mkdir -p "$journal_dir" || return 1
  [[ -d "$journal_dir" && ! -L "$journal_dir" ]] || return 1
  stamp="$(date -u +%Y%m%dT%H%M%SZ 2>/dev/null || date +%Y%m%dT%H%M%SZ)"
  entry="$journal_dir/${stamp}-$$-${RANDOM:-0}-${action}-${phase}.json"
  ralph_atomic_write_json "$entry" \
    '{schemaVersion:1,operation:$action,phase:$phase,workspacePath:$path,
      head:(if $head == "" then null else $head end),recordedAt:$at}' \
    --arg action "$action" --arg phase "$phase" --arg path "$path" \
    --arg head "$head" --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}

_graph_workspace_seal_snapshot_git_discovery() {
  local path="$1" discovered sealed
  command -v git >/dev/null 2>&1 || return 0
  [[ -d "$path" && ! -L "$path" ]] || return 1
  discovered="$(git -C "$path" rev-parse --absolute-git-dir 2>/dev/null)" || return 0
  [[ -n "$discovered" ]] || return 0
  # A local repository terminates parent discovery while keeping ordinary Git
  # probes usable for coding runtimes. It belongs only to the snapshot, never
  # to the caller's checkout.
  git init -q "$path" || {
    echo "Error: failed to seal snapshot Git discovery at $path" >&2
    return 1
  }
  sealed="$(git -C "$path" rev-parse --absolute-git-dir 2>/dev/null || true)"
  if [[ "$sealed" != "$path/.git" ]] || [[ "$(git -C "$path" rev-parse --show-toplevel 2>/dev/null || true)" != "$path" ]]; then
    echo "Error: snapshot workspace can still discover caller Git" >&2
    return 1
  fi
}

_graph_workspace_materialize_snapshot() {
  local source="$1" path="$2" temporary
  [[ -d "$source" && ! -L "$source" ]] || {
    echo "Error: frozen snapshot source is missing or unsafe: $source" >&2
    return 1
  }
  [[ ! -e "$path" && ! -L "$path" ]] || return 0
  temporary="${path}.creating.$$-${RANDOM:-0}"
  [[ ! -e "$temporary" && ! -L "$temporary" ]] || {
    echo "Error: snapshot temporary path already exists: $temporary" >&2
    return 1
  }
  mkdir "$temporary" || return 1
  # Prefer filesystem copy-on-write clones when the host supports them.  APFS
  # (the primary macOS operator environment) can clone the frozen source tree
  # without copying file contents; Linux implementations may expose the same
  # capability through cp --reflink.  Fall back to an ordinary recursive copy
  # on filesystems that reject the fast path.  The destination remains a real,
  # independently writable directory either way.
  if ! cp -cR "$source/." "$temporary/" 2>/dev/null; then
    rm -rf "$temporary"
    mkdir "$temporary" || return 1
    if ! cp --reflink=auto -R "$source/." "$temporary/" 2>/dev/null; then
      rm -rf "$temporary"
      mkdir "$temporary" || return 1
      if ! cp -R "$source/." "$temporary/"; then
        chmod -R u+w "$temporary" 2>/dev/null || true
        rm -rf "$temporary"
        return 1
      fi
    fi
  fi
  # Most source trees are already user-writable. Avoid a full recursive chmod
  # unless the snapshot actually contains a protected entry.
  if [[ -n "$(find "$temporary" ! -perm -u+w -print -quit 2>/dev/null)" ]]; then
    if ! chmod -R u+w "$temporary"; then
      rm -rf "$temporary"
      return 1
    fi
  fi
  if [[ -e "$temporary/.git" || -L "$temporary/.git" ]]; then
    rm -rf "$temporary"
    echo "Error: snapshot materialization unexpectedly contains Git metadata" >&2
    return 1
  fi
  _graph_workspace_seal_snapshot_git_discovery "$temporary" || {
    rm -rf "$temporary"
    return 1
  }
  mv "$temporary" "$path"
}

_graph_workspace_materialize_worktree() {
  local run_dir="$1" node_key="$2" project_root="$3" path="$4" head="$5"
  [[ -d "$project_root/.git" || -f "$project_root/.git" ]] || {
    echo "Error: worktree backend requires a Git repository" >&2
    return 1
  }
  [[ -n "$head" && "$head" != "null" ]] || {
    echo "Error: worktree backend requires frozen Git HEAD provenance" >&2
    return 1
  }
  if _graph_workspace_worktree_registered "$project_root" "$path"; then
    [[ -d "$path" && ! -L "$path" ]] || {
      echo "Error: registered graph worktree path is missing or unsafe: $path" >&2
      return 1
    }
  else
    if [[ -e "$path" || -L "$path" ]]; then
      [[ "$path" == "$run_dir/workspaces/nodes/"* ]] || {
        echo "Error: refusing to recover worktree outside owned node root: $path" >&2
        return 1
      }
      [[ ! -L "$path" ]] || {
        echo "Error: refusing symlink at owned worktree path: $path" >&2
        return 1
      }
      chmod -R u+w "$path" 2>/dev/null || true
      rm -rf "$path"
    fi
    _graph_workspace_journal_git "$run_dir" "$node_key" add started "$path" "$head" || return 1
    if ! git -C "$project_root" worktree add --detach "$path" "$head" >&2; then
      _graph_workspace_journal_git "$run_dir" "$node_key" add failed "$path" "$head" || true
      return 1
    fi
    _graph_workspace_journal_git "$run_dir" "$node_key" add completed "$path" "$head" || return 1
  fi
  [[ "$(git -C "$path" rev-parse HEAD 2>/dev/null)" == "$head" ]] || {
    echo "Error: graph worktree HEAD does not match frozen run base" >&2
    return 1
  }
  if git -C "$path" symbolic-ref -q HEAD >/dev/null 2>&1; then
    echo "Error: graph node worktree must remain detached" >&2
    return 1
  fi
}

_graph_workspace_apply_profile() {
  local run_file="$1" metadata="$2" project_root="$3" workspace_path="$4" profile_name="$5"
  local profile_json secret_json completed command_count command index includes run_dir
  run_dir="$(dirname "$run_file")"
  includes="$(jq -r '.includesApplied' "$metadata")"
  completed="$(jq -r '.setupCompleted' "$metadata")"
  [[ "$completed" =~ ^[0-9]+$ ]] || completed=0
  if [[ -z "$profile_name" ]]; then
    _graph_workspace_update_progress "$metadata" ready true 0
    return
  fi
  profile_json="$(jq -c --arg name "$profile_name" '.workspaceManager.setupProfiles[$name]' "$run_file")" || return 1
  [[ "$profile_json" != "null" ]] || {
    echo "Error: frozen setup profile is missing: $profile_name" >&2
    return 1
  }
  if [[ "$includes" != "true" ]]; then
    secret_json="$(jq -c '.sourceBase.secretExcludes // []' "$run_file")"
    if [[ "$workspace_path" != "$project_root" ]]; then
      python3 "$GRAPH_WORKSPACE_HELPER" copy-includes \
        --source "$project_root" \
        --destination "$workspace_path" \
        --profile-json "$profile_json" \
        --secret-excludes-json "$secret_json" >/dev/null || {
          _graph_workspace_update_progress "$metadata" setup-failed false "$completed" || true
          return 1
        }
    fi
    _graph_workspace_update_progress "$metadata" setup true "$completed" || return 1
  fi
  command_count="$(printf '%s' "$profile_json" | jq '.commands // [] | length')"
  index="$completed"
  while [[ "$index" -lt "$command_count" ]]; do
    command="$(printf '%s' "$profile_json" | jq -r --argjson i "$index" '.commands[$i]')"
    _graph_workspace_log "$run_dir" "setup profile=$profile_name command=$((index + 1)) phase=started"
    if ! (cd "$workspace_path" && bash -lc "$command") \
      >>"$run_dir/workspaces/workspace-manager.log" 2>&1; then
      _graph_workspace_update_progress "$metadata" setup-failed true "$index" || true
      _graph_workspace_log "$run_dir" "setup profile=$profile_name command=$((index + 1)) phase=failed"
      echo "Error: graph workspace setup profile $profile_name command $((index + 1)) failed" >&2
      return 1
    fi
    index=$((index + 1))
    _graph_workspace_update_progress "$metadata" setup true "$index" || return 1
    _graph_workspace_log "$run_dir" "setup profile=$profile_name command=$index phase=completed"
  done
  _graph_workspace_update_progress "$metadata" ready true "$index"
}

# graph_workspace_prepare_node <run-dir> <graph-json> <node-id>
# Prints the durable node workspace path.
graph_workspace_prepare_node() {
  local run_dir="$1" graph_json="$2" node_id="$3"
  local run_file run_id project_root agent_workspace mode profile node_key metadata
  local workspace_root path expected source head status existing_mode existing_node existing_path existing_profile candidate_from candidate_key candidate_node candidate_path candidate_safe
  run_dir="$(graph_workspace_real_dir "$run_dir")" || {
    echo "Error: invalid graph workspace run directory" >&2
    return 1
  }
  run_file="$run_dir/run.json"
  graph_workspace_prepare_run "$run_dir" "$graph_json" || return 1
  jq -e --arg id "$node_id" '.nodes[] | select(.id == $id)' "$graph_json" >/dev/null || {
    echo "Error: graph workspace requested for unknown node: $node_id" >&2
    return 1
  }
  run_id="$(jq -r '.runId' "$run_file")"
  project_root="$(graph_workspace_real_dir "$(jq -r '.roots.projectRoot' "$run_file")")" || {
    echo "Error: recorded graph project root is missing or unsafe" >&2
    return 1
  }
  agent_workspace="$(graph_workspace_real_dir "$(jq -r '.roots.agentWorkspace' "$run_file")")" || {
    echo "Error: recorded graph agent workspace is missing or unsafe" >&2
    return 1
  }
  mode="$(jq -r --arg id "$node_id" '.nodes[] | select(.id == $id) | .stage.workspaceMode // "shared"' "$graph_json")"
  candidate_from="$(jq -r --arg id "$node_id" '.nodes[] | select(.id == $id) | .stage.candidateFrom // empty' "$graph_json")"
  profile="$(jq -r --arg id "$node_id" '.nodes[] | select(.id == $id) | .stage.setupProfile // empty' "$graph_json")"
  case "$mode" in
    shared|snapshot|worktree) ;;
    *) echo "Error: invalid graph workspace mode for $node_id: $mode" >&2; return 1 ;;
  esac
  node_key="$(graph_workspace_node_key "$node_id")" || return 1
  workspace_root="$run_dir/workspaces"
  _graph_workspace_validate_owned_roots "$run_dir" 1 || return 1
  metadata="$(_graph_workspace_metadata_path "$run_dir" "$node_key")"
  expected="$(_graph_workspace_expected_path "$run_dir" "$node_key")"
  if [[ -n "$candidate_from" ]]; then
    candidate_key="$(graph_workspace_node_key "$candidate_from")" || return 1
    candidate_safe="$(printf '%s' "$candidate_from" | sed 's/[^A-Za-z0-9._-]/_/g')"
    candidate_node="$run_dir/nodes/$candidate_safe.json"
    [[ -f "$candidate_node" && "$(jq -r '.status // empty' "$candidate_node")" == "succeeded" ]] || {
      echo "Error: candidate-missing: $node_id requires succeeded candidate $candidate_from" >&2
      return 1
    }
    candidate_path="$(jq -r '.workspacePath // .attempts[-1].workspacePath // empty' "$candidate_node")"
    candidate_path="$(graph_workspace_real_dir "$candidate_path")" || {
      echo "Error: candidate-missing: workspace for $candidate_from is missing or unsafe" >&2
      return 1
    }
  fi
  if [[ "$mode" == "shared" && -z "$candidate_from" ]]; then
    path="$(graph_workspace_real_dir "$agent_workspace")" || {
      echo "Error: shared graph agent workspace is missing" >&2
      return 1
    }
  else
    path="$expected"
  fi
  if [[ -f "$metadata" && ! -L "$metadata" ]]; then
    existing_node="$(jq -r '.nodeId // empty' "$metadata")"
    existing_mode="$(jq -r '.mode // empty' "$metadata")"
    existing_path="$(jq -r '.workspacePath // empty' "$metadata")"
    existing_profile="$(jq -r '.setupProfile // empty' "$metadata")"
    [[ "$existing_node" == "$node_id" && "$existing_mode" == "$mode" \
      && "$existing_path" == "$path" && "$existing_profile" == "$profile" ]] || {
      echo "Error: graph workspace ownership metadata conflicts for node $node_id" >&2
      return 1
    }
  elif [[ -e "$metadata" || -L "$metadata" ]]; then
    echo "Error: graph workspace metadata path is unsafe: $metadata" >&2
    return 1
  else
    _graph_workspace_write_metadata "$metadata" "$run_id" "$node_id" "$mode" "$path" "$profile" creating || return 1
  fi
  status="$(jq -r '.status // empty' "$metadata")"
  if [[ "$status" == "ready" ]]; then
    [[ -d "$path" && ! -L "$path" ]] || {
      echo "Error: recorded graph node workspace is missing or unsafe: $path" >&2
      return 1
    }
    if [[ "$mode" == "worktree" ]] && ! _graph_workspace_worktree_registered "$project_root" "$path"; then
      echo "Error: recorded graph worktree is no longer registered: $path" >&2
      return 1
    fi
    printf '%s\n' "$path"
    return 0
  fi
  case "$mode" in
    shared)
      _graph_workspace_update_progress "$metadata" setup \
        "$(jq -r '.includesApplied' "$metadata")" "$(jq -r '.setupCompleted' "$metadata")" || return 1
      ;;
    snapshot)
      source="${candidate_path:-$(jq -r '.sourceBase.sourcePath // empty' "$run_file")}"
      source="$(graph_workspace_real_dir "$source")" || {
        echo "Error: recorded frozen snapshot source is missing or unsafe" >&2
        return 1
      }
      _graph_workspace_materialize_snapshot "$source" "$path" || return 1
      ;;
    worktree)
      head="$(jq -r '.sourceBase.git.head // empty' "$run_file")"
      _graph_workspace_materialize_worktree "$run_dir" "$node_key" "$project_root" "$path" "$head" || return 1
      if [[ "$(jq -r '.includesApplied' "$metadata")" != "true" ]]; then
        python3 "$GRAPH_WORKSPACE_HELPER" scrub-excludes \
          --destination "$path" \
          --secret-excludes-json "$(jq -c '.sourceBase.secretExcludes // []' "$run_file")" \
          >/dev/null || return 1
      fi
      ;;
  esac
  _graph_workspace_apply_profile "$run_file" "$metadata" "$project_root" "$path" "$profile" || return 1
  printf '%s\n' "$path"
}

_graph_workspace_filesystem_identity() {
  local workspace="$1" state_root="$2" exclude_file="$3"
  python3 "$GRAPH_WORKSPACE_HELPER" identity \
    --source "$workspace" --state-root "$state_root" --exclude-file "$exclude_file" |
    jq -r '.filesystemIdentity'
}

# _graph_workspace_retention_allows_release <run-dir>
# True when ralph_retention_eligibility reports no active or resumable owner.
_graph_workspace_retention_allows_release() {
  local run_dir="$1" run_file state_root namespace reason
  if ! declare -F ralph_retention_eligibility >/dev/null 2>&1; then
    # shellcheck source=../retention.sh
    source "$GRAPH_WORKSPACE_SCRIPT_DIR/../retention.sh"
  fi
  run_file="$run_dir/run.json"
  state_root="$(jq -r '.roots.stateRoot // empty' "$run_file")"
  [[ -n "$state_root" && -d "$state_root" ]] || return 1
  namespace="$(jq -r '.namespace // empty' "$run_file")"
  [[ -n "$namespace" ]] || namespace="$(basename "$(dirname "$run_dir")")"
  reason="$(ralph_retention_eligibility "$state_root" graph-run "$run_dir" "$namespace" 2>/dev/null)" || return 1
  [[ "$reason" == "eligible" ]]
}

# _graph_workspace_prove_reconstruction <run-dir> <node-key> <workspace-path> <node-id>
# Reconstructs base + changeset into a temp directory and compares filesystem
# identity to the live workspace. Prints a stable failure reason on stderr-free
# stdout when proof fails (caller captures it); returns 0 only on match.
_graph_workspace_prove_reconstruction() {
  local run_dir="$1" node_key="$2" path="$3" node_id="$4"
  local run_file manifest base_identity source_path state_root
  local exclude_file tmp integrate_out integrate_conflict
  local expected reconstructed manifest_base
  run_file="$run_dir/run.json"
  manifest="$run_dir/changesets/nodes/$node_key.json"
  [[ -f "$manifest" && ! -L "$manifest" ]] || {
    printf 'missing-changeset-manifest\n'
    return 1
  }
  base_identity="$(jq -r '.sourceBase.filesystemIdentity // empty' "$run_file")"
  source_path="$(jq -r '.sourceBase.sourcePath // empty' "$run_file")"
  state_root="$(jq -r '.roots.stateRoot // empty' "$run_file")"
  [[ -n "$base_identity" ]] || {
    printf 'missing-run-base-identity\n'
    return 1
  }
  [[ -n "$source_path" && -d "$source_path" && ! -L "$source_path" ]] || {
    printf 'missing-run-base-source\n'
    return 1
  }
  [[ -n "$state_root" && -d "$state_root" ]] || {
    printf 'missing-state-root\n'
    return 1
  }
  manifest_base="$(jq -r '.baseIdentity // empty' "$manifest")"
  [[ "$manifest_base" == "$base_identity" ]] || {
    printf 'changeset-base-mismatch\n'
    return 1
  }
  [[ -f "$GRAPH_WORKSPACE_INTEGRATE_HELPER" ]] || {
    printf 'missing-integrate-helper\n'
    return 1
  }
  exclude_file="$(mktemp "${TMPDIR:-/tmp}/ralph-compaction-excludes.XXXXXX")" || {
    printf 'exclude-temp-failed\n'
    return 1
  }
  jq -r '.sourceBase.secretExcludes[]? // empty' "$run_file" >"$exclude_file" || {
    rm -f "$exclude_file"
    printf 'exclude-write-failed\n'
    return 1
  }
  expected="$(_graph_workspace_filesystem_identity "$path" "$state_root" "$exclude_file")" || {
    rm -f "$exclude_file"
    printf 'workspace-identity-failed\n'
    return 1
  }
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/ralph-compaction-recon.XXXXXX")" || {
    rm -f "$exclude_file"
    printf 'recon-temp-failed\n'
    return 1
  }
  integrate_out="$(mktemp "${TMPDIR:-/tmp}/ralph-compaction-integrate.XXXXXX")" || {
    rm -f "$exclude_file"
    rm -rf "$tmp"
    printf 'integrate-temp-failed\n'
    return 1
  }
  integrate_conflict="$(mktemp "${TMPDIR:-/tmp}/ralph-compaction-conflict.XXXXXX")" || {
    rm -f "$exclude_file" "$integrate_out"
    rm -rf "$tmp"
    printf 'conflict-temp-failed\n'
    return 1
  }
  # Frozen base/ stays immutable for the dashboard diff viewer; reconstruct into
  # a disposable copy only.
  if ! cp -a "$source_path"/. "$tmp"/; then
    rm -f "$exclude_file" "$integrate_out" "$integrate_conflict"
    chmod -R u+w "$tmp" 2>/dev/null || true
    rm -rf "$tmp"
    printf 'base-copy-failed\n'
    return 1
  fi
  chmod -R u+w "$tmp" 2>/dev/null || true
  if ! python3 "$GRAPH_WORKSPACE_INTEGRATE_HELPER" \
    --workspace "$tmp" \
    --output "$integrate_out" \
    --conflict-output "$integrate_conflict" \
    --node-id "$node_id" \
    --base-identity "$base_identity" \
    --manifest "$manifest" >/dev/null; then
    rm -f "$exclude_file" "$integrate_out" "$integrate_conflict"
    chmod -R u+w "$tmp" 2>/dev/null || true
    rm -rf "$tmp"
    printf 'integrate-apply-failed\n'
    return 1
  fi
  reconstructed="$(_graph_workspace_filesystem_identity "$tmp" "$state_root" "$exclude_file")" || {
    rm -f "$exclude_file" "$integrate_out" "$integrate_conflict"
    chmod -R u+w "$tmp" 2>/dev/null || true
    rm -rf "$tmp"
    printf 'reconstructed-identity-failed\n'
    return 1
  }
  rm -f "$exclude_file" "$integrate_out" "$integrate_conflict"
  chmod -R u+w "$tmp" 2>/dev/null || true
  rm -rf "$tmp"
  if [[ "$reconstructed" != "$expected" ]]; then
    printf 'identity-mismatch\n'
    return 1
  fi
  printf '%s\n' "$expected"
  return 0
}

_graph_workspace_write_reconstruction_bundle() {
  local run_dir="$1" node_key="$2" node_id="$3" path="$4" workspace_identity="$5"
  local changeset_root destination run_file manifest base_identity source_path
  changeset_root="$run_dir/workspaces/changesets"
  destination="$changeset_root/$node_key.reconstruction.json"
  run_file="$run_dir/run.json"
  manifest="$run_dir/changesets/nodes/$node_key.json"
  base_identity="$(jq -r '.sourceBase.filesystemIdentity // empty' "$run_file")"
  source_path="$(jq -r '.sourceBase.sourcePath // empty' "$run_file")"
  [[ ! -L "$destination" ]] || return 1
  ralph_atomic_write_json "$destination" \
    '{
      schemaVersion: 1,
      kind: "graph-workspace-reconstruction",
      nodeId: $nodeId,
      nodeKey: $nodeKey,
      workspacePath: $workspace,
      baseIdentity: $baseIdentity,
      baseSourcePath: $baseSource,
      changesetManifest: $manifest,
      changesetBlobsDir: $blobs,
      workspaceIdentity: $identity,
      reconstructionVerified: true,
      archivedAt: $now
    }' \
    --arg nodeId "$node_id" \
    --arg nodeKey "$node_key" \
    --arg workspace "$path" \
    --arg baseIdentity "$base_identity" \
    --arg baseSource "$source_path" \
    --arg manifest "$manifest" \
    --arg blobs "$run_dir/changesets/nodes/blobs" \
    --arg identity "$workspace_identity" \
    --arg now "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" || return 1
  # Drop any prior full-tree archives once reconstruction is proved.
  rm -f "$changeset_root/$node_key.tar" "$changeset_root/$node_key.tar.gz" \
    "$changeset_root/$node_key.fallback.json"
}

_graph_workspace_write_fallback_archive() {
  local run_dir="$1" node_key="$2" path="$3" reason="$4"
  local changeset_root destination temporary reason_file
  changeset_root="$run_dir/workspaces/changesets"
  destination="$changeset_root/$node_key.tar.gz"
  temporary="${destination}.tmp.$$"
  reason_file="$changeset_root/$node_key.fallback.json"
  [[ ! -L "$destination" && ! -L "$reason_file" ]] || return 1
  rm -f "$temporary"
  tar -czf "$temporary" --exclude='./.git' -C "$path" . || {
    rm -f "$temporary"
    return 1
  }
  ralph_atomic_write_json "$reason_file" \
    '{
      schemaVersion: 1,
      kind: "graph-workspace-archive-fallback",
      nodeKey: $nodeKey,
      archive: $archive,
      reason: $reason,
      archivedAt: $now
    }' \
    --arg nodeKey "$node_key" \
    --arg archive "$destination" \
    --arg reason "$reason" \
    --arg now "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" || {
      rm -f "$temporary"
      return 1
    }
  mv "$temporary" "$destination" || {
    rm -f "$temporary"
    return 1
  }
  rm -f "$changeset_root/$node_key.tar" "$changeset_root/$node_key.reconstruction.json"
}

# _graph_workspace_archive_changeset <run-dir> <node-key> <path> <node-id>
# Prefer a reconstruction bundle (changeset + run-base identity) when applying
# the frozen base plus the captured changeset reproduces the workspace identity.
# Otherwise write a gzip-compressed tar and record the fallback reason.
# Sets GRAPH_WORKSPACE_LAST_ARCHIVE_MODE to reconstruction|fallback.
# Does not remove the workspace; the caller decides release.
_graph_workspace_archive_changeset() {
  local run_dir="$1" node_key="$2" path="$3" node_id="${4:-}"
  local changeset_root reconstruction fallback proof_identity reason
  GRAPH_WORKSPACE_LAST_ARCHIVE_MODE=""
  changeset_root="$run_dir/workspaces/changesets"
  [[ ! -L "$changeset_root" ]] || return 1
  mkdir -p "$changeset_root" || return 1
  [[ "$(cd "$changeset_root" 2>/dev/null && pwd -P)" == "$changeset_root" ]] || return 1
  reconstruction="$changeset_root/$node_key.reconstruction.json"
  fallback="$changeset_root/$node_key.tar.gz"
  if [[ ! -e "$path" ]]; then
    if [[ -f "$reconstruction" && ! -L "$reconstruction" ]]; then
      GRAPH_WORKSPACE_LAST_ARCHIVE_MODE=reconstruction
      return 0
    fi
    if [[ -f "$fallback" && ! -L "$fallback" ]]; then
      GRAPH_WORKSPACE_LAST_ARCHIVE_MODE=fallback
      return 0
    fi
    # Legacy uncompressed archives remain recoverable.
    if [[ -f "$changeset_root/$node_key.tar" && ! -L "$changeset_root/$node_key.tar" ]]; then
      GRAPH_WORKSPACE_LAST_ARCHIVE_MODE=fallback
      return 0
    fi
    return 1
  fi
  [[ -d "$path" && ! -L "$path" ]] || return 1
  reason="missing-node-id"
  if [[ -n "$node_id" ]]; then
    if proof_identity="$(_graph_workspace_prove_reconstruction "$run_dir" "$node_key" "$path" "$node_id")"; then
      _graph_workspace_write_reconstruction_bundle \
        "$run_dir" "$node_key" "$node_id" "$path" "$proof_identity" || return 1
      GRAPH_WORKSPACE_LAST_ARCHIVE_MODE=reconstruction
      return 0
    fi
    reason="${proof_identity:-reconstruction-unproved}"
  fi
  _graph_workspace_write_fallback_archive "$run_dir" "$node_key" "$path" "$reason" || return 1
  GRAPH_WORKSPACE_LAST_ARCHIVE_MODE=fallback
}

# graph_workspace_cleanup_run <run-dir>
# Cleanup is opt-in through retention=prune and only runs for terminal runs.
# Isolated workspaces are compacted (reconstruction bundle or gzip tar) before
# their exact owned path is removed. The run base/ directory is never compacted.
# Reconstruction-backed release also requires ralph_retention_eligibility.
graph_workspace_cleanup_run() {
  local run_dir="$1" run_file status retention run_id project_root metadata_dir list_file namespace_dir latest_dir
  local metadata node_id mode path owner node_key head release=0
  run_dir="$(graph_workspace_real_dir "$run_dir")" || return 1
  run_file="$run_dir/run.json"
  [[ -f "$run_file" ]] || return 1
  # The latest run remains the operator's immediate inspection target. This
  # guard is deliberately here, rather than only in retention, so every
  # finalization caller preserves it.
  namespace_dir="$(dirname "$run_dir")"
  if [[ -L "$namespace_dir/latest" ]]; then
    latest_dir="$(cd "$namespace_dir/latest" 2>/dev/null && pwd -P)" || latest_dir=""
    [[ "$latest_dir" == "$run_dir" ]] && return 0
  fi
  graph_state_reconcile_run_owner_file "$run_file" || true
  status="$(jq -r '.status // empty' "$run_file")"
  retention="$(jq -r '.workspaceManager.retention // "keep"' "$run_file")"
  [[ "$retention" == "prune" ]] || return 0
  case "$status" in
    succeeded|failed|cancelled) ;;
    *) echo "Error: graph workspace cleanup requires a terminal prunable run" >&2; return 1 ;;
  esac
  run_id="$(jq -r '.runId' "$run_file")"
  project_root="$(jq -r '.roots.projectRoot' "$run_file")"
  project_root="$(graph_workspace_real_dir "$project_root")" || return 1
  [[ ! -e "$run_dir/workspaces" ]] && return 0
  _graph_workspace_validate_owned_roots "$run_dir" 0 || return 1
  metadata_dir="$run_dir/workspaces/metadata"
  list_file="$(mktemp "${TMPDIR:-/tmp}/ralph-workspace-metadata.XXXXXX")" || return 1
  python3 - "$metadata_dir" >"$list_file" <<'PYLIST'
from pathlib import Path
import sys
root = Path(sys.argv[1])
for path in sorted(root.iterdir()):
    if path.is_file() and not path.is_symlink() and path.suffix == ".json":
        print(path)
PYLIST
  while IFS= read -r metadata || [[ -n "$metadata" ]]; do
    [[ -n "$metadata" ]] || continue
    owner="$(jq -r '.ownerRunId // empty' "$metadata")"
    mode="$(jq -r '.mode // empty' "$metadata")"
    path="$(jq -r '.workspacePath // empty' "$metadata")"
    node_id="$(jq -r '.nodeId // empty' "$metadata")"
    node_key="$(graph_workspace_node_key "$node_id")" || { rm -f "$list_file"; return 1; }
    [[ "$owner" == "$run_id" ]] || {
      rm -f "$list_file"
      echo "Error: refusing cleanup of workspace not owned by run $run_id" >&2
      return 1
    }
    [[ "$mode" != "shared" ]] || continue
    [[ "$path" == "$(_graph_workspace_expected_path "$run_dir" "$node_key")" ]] || {
      rm -f "$list_file"
      echo "Error: refusing cleanup outside exact owned node path: $path" >&2
      return 1
    }
    [[ ! -L "$path" ]] || {
      rm -f "$list_file"
      echo "Error: refusing cleanup of symlink workspace: $path" >&2
      return 1
    }
    _graph_workspace_archive_changeset "$run_dir" "$node_key" "$path" "$node_id" || {
      rm -f "$list_file"
      echo "Error: failed to record recoverable changeset for $node_id" >&2
      return 1
    }
    release=0
    case "$GRAPH_WORKSPACE_LAST_ARCHIVE_MODE" in
      fallback)
        release=1
        ;;
      reconstruction)
        if _graph_workspace_retention_allows_release "$run_dir"; then
          release=1
        fi
        ;;
      *)
        rm -f "$list_file"
        echo "Error: compaction produced no recoverable archive mode for $node_id" >&2
        return 1
        ;;
    esac
    if [[ "$release" -ne 1 ]]; then
      # Reconstruction proved, but an active/resumable owner still owns the
      # run: keep the materialized workspace for inspection/resume.
      continue
    fi
    if [[ "${RALPH_GRAPH_COMPACTION_TEST_INTERRUPT:-}" == "1" ]]; then
      rm -f "$list_file"
      echo "Error: simulated compaction interrupt before workspace release" >&2
      return 1
    fi
    if [[ "$mode" == "worktree" ]]; then
      head="$(jq -r '.sourceBase.git.head // empty' "$run_file")"
      if _graph_workspace_worktree_registered "$project_root" "$path"; then
        _graph_workspace_journal_git "$run_dir" "$node_key" remove started "$path" "$head" || {
          rm -f "$list_file"; return 1;
        }
        git -C "$project_root" worktree remove --force "$path" || {
          _graph_workspace_journal_git "$run_dir" "$node_key" remove failed "$path" "$head" || true
          rm -f "$list_file"
          return 1
        }
        _graph_workspace_journal_git "$run_dir" "$node_key" remove completed "$path" "$head" || {
          rm -f "$list_file"; return 1;
        }
      elif [[ -e "$path" ]]; then
        chmod -R u+w "$path" 2>/dev/null || true
        rm -rf "$path" || {
          rm -f "$list_file"
          return 1
        }
      fi
    elif [[ -e "$path" ]]; then
      chmod -R u+w "$path" 2>/dev/null || true
      rm -rf "$path" || {
        rm -f "$list_file"
        return 1
      }
    fi
    if [[ -e "$path" || -L "$path" ]]; then
      rm -f "$list_file"
      echo "Error: graph workspace cleanup did not remove owned path: $path" >&2
      return 1
    fi
    _graph_workspace_update_progress "$metadata" pruned true "$(jq -r '.setupCompleted // 0' "$metadata")" || {
      rm -f "$list_file"; return 1;
    }
  done <"$list_file"
  rm -f "$list_file"
}
