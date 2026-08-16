#!/usr/bin/env bash
# Read-only graph preflight report.
#
# Compares a frozen graph.json against host and runtime capabilities and
# emits pass/warn/fail findings for workspace mode, write scopes, approval
# support, model/auth availability, commands, and publish preconditions.
#
# This module never writes graph, ledger, workspace, or ambient config
# files. CLI probes are list/status/help only and never start a session or
# send a prompt.

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  echo "This file is meant to be sourced, not executed." >&2
  exit 1
fi

if [[ -n "${GRAPH_PREFLIGHT_LOADED:-}" ]]; then
  return 0
fi
GRAPH_PREFLIGHT_LOADED=1

GRAPH_PREFLIGHT_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GRAPH_PREFLIGHT_SCHEMA_VERSION=1

if ! declare -F graph_runtime_capabilities >/dev/null 2>&1; then
  # shellcheck source=./graph-runtime-capabilities.sh
  source "$GRAPH_PREFLIGHT_SCRIPT_DIR/graph-runtime-capabilities.sh"
fi
if ! declare -F graph_gate_is_allowed_executable >/dev/null 2>&1; then
  # shellcheck source=./graph-gate.sh
  source "$GRAPH_PREFLIGHT_SCRIPT_DIR/graph-gate.sh"
fi

GRAPH_PREFLIGHT_CATEGORIES='workspace-mode
write-scopes
approval
model-auth
commands
publish'

# graph_preflight_cmd_available <name>
# Honors GRAPH_PREFLIGHT_UNAVAILABLE (comma-separated) so tests can force a miss.
graph_preflight_cmd_available() {
  local name="${1:-}"
  [[ -n "$name" ]] || return 1
  case ",${GRAPH_PREFLIGHT_UNAVAILABLE:-}," in
    *",$name,"*) return 1 ;;
  esac
  command -v "$name" >/dev/null 2>&1
}

# graph_preflight_cli_override_var <normalized-runtime>
graph_preflight_cli_override_var() {
  local runtime="$1"
  case "$runtime" in
    claude) printf 'GRAPH_PREFLIGHT_CLI_CLAUDE\n' ;;
    cursor) printf 'GRAPH_PREFLIGHT_CLI_CURSOR\n' ;;
    codex) printf 'GRAPH_PREFLIGHT_CLI_CODEX\n' ;;
    opencode) printf 'GRAPH_PREFLIGHT_CLI_OPENCODE\n' ;;
    antigravity) printf 'GRAPH_PREFLIGHT_CLI_ANTIGRAVITY\n' ;;
    *) printf 'GRAPH_PREFLIGHT_CLI_%s\n' "$(printf '%s' "$runtime" | tr '[:lower:]-' '[:upper:]_')" ;;
  esac
}

# graph_preflight_resolve_cli <normalized-runtime>
# Prints the CLI path or name. Empty when unknown. Never invokes the CLI.
graph_preflight_resolve_cli() {
  local runtime="$1" var override
  var="$(graph_preflight_cli_override_var "$runtime")"
  override=""
  if [[ -n "$var" ]]; then
    override="${!var-}"
  fi
  if [[ -n "$override" ]]; then
    printf '%s\n' "$override"
    return 0
  fi
  graph_runtime_cli_name "$runtime"
}

# graph_preflight_cli_exists <cli>
graph_preflight_cli_exists() {
  local cli="${1:-}"
  [[ -n "$cli" ]] || return 1
  if [[ "$cli" == /* || "$cli" == ./* || "$cli" == ../* ]]; then
    [[ -x "$cli" ]]
    return
  fi
  graph_preflight_cmd_available "$cli"
}

# graph_preflight_auth_argv <normalized-runtime>
# Prints one flag/subcommand per line. Returns 1 when no auth probe exists.
graph_preflight_auth_argv() {
  case "${1:-}" in
    claude)
      printf '%s\n' auth status
      ;;
    codex)
      printf '%s\n' login status
      ;;
    *)
      return 1
      ;;
  esac
}

# graph_preflight_models_argv <normalized-runtime>
# Prints one flag/subcommand per line. Returns 1 when no list probe exists.
graph_preflight_models_argv() {
  case "${1:-}" in
    antigravity)
      printf '%s\n' models
      ;;
    cursor)
      printf '%s\n' --list-models
      ;;
    opencode)
      printf '%s\n' models
      ;;
    *)
      return 1
      ;;
  esac
}

# graph_preflight_auth_indicates_missing <text>
graph_preflight_auth_indicates_missing() {
  local text
  text="$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]')"
  [[ "$text" == *"not logged"* || "$text" == *"logged out"* || \
     "$text" == *"unauthenticated"* || "$text" == *"not authenticated"* || \
     "$text" == *"authentication required"* || "$text" == *"auth required"* || \
     "$text" == *"please log in"* || "$text" == *"please login"* ]]
}

# graph_preflight_run_probe <cli> <argv-lines>
# Runs a help/status/list probe. Never used for prompts. Prints stdout.
# Returns the CLI exit status.
graph_preflight_run_probe() {
  local cli="$1"
  local -a args=()
  local line
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    args+=("$line")
  done
  [[ ${#args[@]} -gt 0 ]] || return 1
  "$cli" "${args[@]}" 2>/dev/null
}

# graph_preflight_parse_model_list <normalized-runtime> <raw-text>
# Prints one catalog entry per line. Antigravity strings stay exact.
graph_preflight_parse_model_list() {
  local runtime="$1" raw="$2" line id
  case "$runtime" in
    antigravity)
      while IFS= read -r line || [[ -n "$line" ]]; do
        [[ -z "${line//[[:space:]]/}" ]] && continue
        printf '%s\n' "$line"
      done <<< "$raw"
      ;;
    cursor)
      while IFS= read -r line || [[ -n "$line" ]]; do
        [[ "$line" == Tip:* ]] && break
        [[ "$line" == *" - "* ]] || continue
        id="${line%% - *}"
        id="${id#"${id%%[![:space:]]*}"}"
        id="${id%"${id##*[![:space:]]}"}"
        [[ -n "$id" ]] && printf '%s\n' "$id"
      done <<< "$raw"
      ;;
    opencode)
      while IFS= read -r line || [[ -n "$line" ]]; do
        [[ "$line" =~ ^[a-zA-Z0-9/._:-]+$ ]] || continue
        printf '%s\n' "$line"
      done <<< "$raw"
      ;;
  esac
}

# graph_preflight_model_in_catalog <model> <catalog-text>
# Exact string match. Does not lowercase or remap identifiers.
graph_preflight_model_in_catalog() {
  local model="$1" line
  [[ -n "$model" ]] || return 1
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ "$line" == "$model" ]] && return 0
  done <<< "${2:-}"
  return 1
}

# graph_preflight_scope_unsafe <scope>
graph_preflight_scope_unsafe() {
  local scope="$1" rest first
  [[ -n "$scope" ]] || return 0
  [[ "$scope" == /* || "$scope" == *\\* || "$scope" == "." ]] && return 0
  rest="$scope"
  first="${rest%%/*}"
  case "$first" in
    ..|.git|.ralph|.ralph-workspace) return 0 ;;
  esac
  while [[ "$rest" == */* ]]; do
    rest="${rest#*/}"
    first="${rest%%/*}"
    [[ "$first" == ".." ]] && return 0
  done
  return 1
}

# graph_preflight_finding <id> <category> <status> <summary> [evidence] [repair] [nodeId] [runtime]
graph_preflight_finding() {
  local id="$1" category="$2" status="$3" summary="$4"
  local evidence="${5:-}" repair="${6:-}" node_id="${7:-}" runtime="${8:-}"
  jq -nc \
    --arg id "$id" \
    --arg category "$category" \
    --arg status "$status" \
    --arg summary "$summary" \
    --arg evidence "$evidence" \
    --arg repair "$repair" \
    --arg nodeId "$node_id" \
    --arg runtime "$runtime" \
    '{
      id: $id,
      category: $category,
      status: $status,
      summary: $summary,
      evidence: (if $evidence == "" then null else $evidence end),
      repair: (if $repair == "" then null else $repair end),
      nodeId: (if $nodeId == "" then null else $nodeId end),
      runtime: (if $runtime == "" then null else $runtime end)
    }'
}

graph_preflight_append() {
  local file="$1"
  shift
  graph_preflight_finding "$@" >>"$file"
}

# graph_preflight_worst <findings-jsonl-file>
graph_preflight_worst() {
  local file="$1"
  if [[ ! -s "$file" ]]; then
    printf 'pass\n'
    return 0
  fi
  jq -s -r '
    if any(.[]; .status == "fail") then "fail"
    elif any(.[]; .status == "warn") then "warn"
    else "pass"
    end
  ' "$file"
}

# graph_preflight_format_table <report-json>
# Concise table: check ID, status, evidence, repair.
graph_preflight_format_table() {
  local json="${1:-}"
  printf '%s\n' "$json" | jq -r '
    ["ID","STATUS","EVIDENCE","REPAIR"],
    (.findings[] | [
      .id,
      .status,
      (.evidence // .summary),
      (.repair // "-")
    ])
    | @tsv
  ' | awk -F'\t' '
    BEGIN {
      w[1]=24; w[2]=6; w[3]=40; w[4]=32
    }
    {
      for (i=1;i<=4;i++) {
        s=$i
        if (length(s) > w[i]) s=substr(s,1,w[i]-1) ">"
        printf "%-*s%s", w[i], s, (i==4 ? "\n" : "  ")
      }
    }
  '
}

_graph_preflight_check_workspace_node() {
  local findings="$1" node_id="$2" mode="$3" runtime="$4"
  local scopes_json="$5" ack="$6" git_access="$7" caps="$8"
  local sandbox project="${9:-}"

  case "$mode" in
    snapshot)
      if graph_preflight_cmd_available python3; then
        graph_preflight_append "$findings" "workspace-mode:${node_id}" workspace-mode pass \
          "snapshot isolation is available" "python3 present" "" "$node_id" "$runtime"
      else
        graph_preflight_append "$findings" "workspace-mode:${node_id}" workspace-mode fail \
          "snapshot mode requires python3" "python3 missing" \
          "install python3 before running this graph" "$node_id" "$runtime"
      fi
      ;;
    worktree)
      if ! graph_preflight_cmd_available git; then
        graph_preflight_append "$findings" "workspace-mode:${node_id}" workspace-mode fail \
          "worktree mode requires git" "git missing" \
          "install git or switch the node to workspaceMode: snapshot" "$node_id" "$runtime"
        return 0
      fi
      if [[ -z "$project" || ! -d "$project" ]]; then
        graph_preflight_append "$findings" "workspace-mode:${node_id}" workspace-mode fail \
          "worktree mode requires a project directory" "project root missing" \
          "pass the project root to preflight" "$node_id" "$runtime"
        return 0
      fi
      local git_root head porcelain
      git_root="$(git -C "$project" rev-parse --show-toplevel 2>/dev/null)" || git_root=""
      if [[ -z "$git_root" ]]; then
        graph_preflight_append "$findings" "workspace-mode:${node_id}" workspace-mode fail \
          "worktree mode requires a Git repository" "git rev-parse failed" \
          "git init in the project root or use workspaceMode: snapshot" "$node_id" "$runtime"
        return 0
      fi
      git_root="$(cd "$git_root" 2>/dev/null && pwd -P)"
      local project_real
      project_real="$(cd "$project" 2>/dev/null && pwd -P)"
      if [[ "$git_root" != "$project_real" ]]; then
        graph_preflight_append "$findings" "workspace-mode:${node_id}" workspace-mode fail \
          "worktree mode requires the project root to equal the Git worktree root" \
          "gitRoot=$git_root project=$project_real" \
          "run from the repository root" "$node_id" "$runtime"
        return 0
      fi
      porcelain="$(git -C "$project" status --porcelain=v1 --untracked-files=all 2>/dev/null)" || porcelain="error"
      if [[ "$porcelain" == "error" ]]; then
        graph_preflight_append "$findings" "workspace-mode:${node_id}" workspace-mode fail \
          "worktree mode could not inspect Git status" "git status failed" \
          "fix the Git repository and retry" "$node_id" "$runtime"
        return 0
      fi
      if [[ -n "$porcelain" ]]; then
        graph_preflight_append "$findings" "workspace-mode:${node_id}" workspace-mode fail \
          "worktree mode requires a clean Git worktree" "git status is dirty" \
          "commit or stash caller changes, then retry" "$node_id" "$runtime"
        return 0
      fi
      head="$(git -C "$project" rev-parse --verify HEAD 2>/dev/null)" || head=""
      if [[ -z "$head" ]]; then
        graph_preflight_append "$findings" "workspace-mode:${node_id}" workspace-mode fail \
          "worktree mode requires a Git HEAD" "HEAD missing" \
          "create an initial commit" "$node_id" "$runtime"
        return 0
      fi
      sandbox=false
      if [[ "${RALPH_GRAPH_GIT_SANDBOX_PROVEN:-}" == "1" ]]; then
        sandbox=true
      elif [[ -n "$caps" ]] && graph_runtime_capability_is_supported "$caps" provenSandboxBoundary; then
        sandbox=true
      fi
      if [[ "$scopes_json" != "[]" && "$scopes_json" != "null" && -n "$scopes_json" ]]; then
        if [[ "${git_access:-off}" == "off" && "$sandbox" != "true" ]]; then
          graph_preflight_append "$findings" "workspace-mode:${node_id}" workspace-mode fail \
            "mutating worktree requires a proved runtime sandbox boundary" \
            "provenSandboxBoundary=false RALPH_GRAPH_GIT_SANDBOX_PROVEN=${RALPH_GRAPH_GIT_SANDBOX_PROVEN:-}" \
            "use Codex, set RALPH_GRAPH_GIT_SANDBOX_PROVEN=1, or switch to snapshot" \
            "$node_id" "$runtime"
          return 0
        fi
      fi
      graph_preflight_append "$findings" "workspace-mode:${node_id}" workspace-mode pass \
        "worktree isolation preconditions are met" "clean git HEAD=$head" "" "$node_id" "$runtime"
      ;;
    shared|"")
      if [[ "$scopes_json" != "[]" && "$scopes_json" != "null" && -n "$scopes_json" ]]; then
        if [[ "$ack" == "true" ]]; then
          graph_preflight_append "$findings" "workspace-mode:${node_id}" workspace-mode warn \
            "shared mutation is acknowledged and is not isolated" \
            "acknowledgeSharedMutationRisk=true writeScopes=$scopes_json" \
            "prefer workspaceMode: snapshot" "$node_id" "$runtime"
        else
          graph_preflight_append "$findings" "workspace-mode:${node_id}" workspace-mode fail \
            "shared mutation requires acknowledgement" \
            "acknowledgeSharedMutationRisk=$ack writeScopes=$scopes_json" \
            "set parallelMutation: allow and acknowledgeSharedMutationRisk: true, or use snapshot" \
            "$node_id" "$runtime"
        fi
      else
        graph_preflight_append "$findings" "workspace-mode:${node_id}" workspace-mode pass \
          "shared workspace is acceptable for a non-mutating node" \
          "writeScopes=[]" "" "$node_id" "$runtime"
      fi
      ;;
    *)
      graph_preflight_append "$findings" "workspace-mode:${node_id}" workspace-mode fail \
        "unknown workspace mode" "workspaceMode=$mode" \
        "set workspaceMode to snapshot, worktree, or shared" "$node_id" "$runtime"
      ;;
  esac
}

_graph_preflight_check_write_scopes() {
  local findings="$1" node_id="$2" node_type="$3" mode="$4" runtime="$5"
  local scopes_json="$6" ack="$7" caps="$8"
  local scope nscopes enforce

  if [[ "$node_type" == "integrate" ]]; then
    if [[ "$scopes_json" != "[]" && "$scopes_json" != "null" && -n "$scopes_json" ]]; then
      graph_preflight_append "$findings" "write-scopes:${node_id}" write-scopes fail \
        "integrate nodes cannot declare agent writeScopes" "writeScopes=$scopes_json" \
        "remove writeScopes from the integrate node" "$node_id" "$runtime"
      return 0
    fi
    graph_preflight_append "$findings" "write-scopes:${node_id}" write-scopes pass \
      "integrate node has no agent writeScopes" "" "" "$node_id" "$runtime"
    return 0
  fi

  nscopes="$(printf '%s' "$scopes_json" | jq -r 'if type=="array" then length else 0 end' 2>/dev/null)" || nscopes=0
  if [[ "$nscopes" -eq 0 ]]; then
    graph_preflight_append "$findings" "write-scopes:${node_id}" write-scopes pass \
      "node has no writeScopes (read-only)" "writeScopes=[]" "" "$node_id" "$runtime"
    return 0
  fi

  while IFS= read -r scope; do
    [[ -n "$scope" ]] || continue
    if graph_preflight_scope_unsafe "$scope"; then
      graph_preflight_append "$findings" "write-scopes:${node_id}" write-scopes fail \
        "writeScopes contain an unsafe or control-path glob" "scope=$scope" \
        "use a project-relative glob that does not include .git, .ralph, or .ralph-workspace" \
        "$node_id" "$runtime"
      return 0
    fi
  done < <(printf '%s' "$scopes_json" | jq -r '.[]?')

  enforce=false
  if [[ -n "$caps" ]] && graph_runtime_capability_is_supported "$caps" workspaceEnforcement; then
    enforce=true
  fi
  if [[ "$enforce" != "true" ]]; then
    graph_preflight_append "$findings" "write-scopes:${node_id}" write-scopes fail \
      "runtime cannot enforce writeScopes" \
      "workspaceEnforcement=false runtime=$runtime" \
      "use a known runtime with workspace enforcement" "$node_id" "$runtime"
    return 0
  fi

  if [[ "$mode" == "shared" || -z "$mode" ]]; then
    if [[ "$ack" == "true" ]]; then
      graph_preflight_append "$findings" "write-scopes:${node_id}" write-scopes warn \
        "writeScopes on a shared workspace do not create isolation" \
        "writeScopes=$scopes_json" \
        "prefer workspaceMode: snapshot with the same writeScopes" "$node_id" "$runtime"
    else
      graph_preflight_append "$findings" "write-scopes:${node_id}" write-scopes fail \
        "shared writeScopes require acknowledgement" \
        "acknowledgeSharedMutationRisk=$ack" \
        "set acknowledgeSharedMutationRisk: true or use snapshot" "$node_id" "$runtime"
    fi
    return 0
  fi

  graph_preflight_append "$findings" "write-scopes:${node_id}" write-scopes pass \
    "writeScopes are project-relative and enforceable" \
    "writeScopes=$scopes_json workspaceEnforcement=true" "" "$node_id" "$runtime"
}

_graph_preflight_check_approval() {
  local findings="$1" runtime="$2" caps="$3"
  local live session
  if [[ -z "$runtime" ]]; then
    return 0
  fi
  live=false
  session=false
  if [[ -n "$caps" ]] && graph_runtime_capability_is_supported "$caps" liveApprovals; then
    live=true
  fi
  if [[ -n "$caps" ]] && graph_runtime_capability_is_supported "$caps" sessionContinuation; then
    session=true
  fi
  if [[ "$live" == "true" ]]; then
    graph_preflight_append "$findings" "approval:${runtime}" approval pass \
      "runtime supports live approval requests" "liveApprovals=true" "" "" "$runtime"
    return 0
  fi
  if [[ "$session" == "true" ]]; then
    graph_preflight_append "$findings" "approval:${runtime}" approval warn \
      "live approvals are unproven; overlay fallback remains available" \
      "liveApprovals=false sessionContinuation=true" \
      "upgrade the runtime CLI or accept the resumable overlay fallback" "" "$runtime"
    return 0
  fi
  graph_preflight_append "$findings" "approval:${runtime}" approval fail \
    "runtime has no live approvals and no session continuation" \
    "liveApprovals=false sessionContinuation=false" \
    "use a known graph runtime (claude, cursor, codex, opencode, antigravity)" "" "$runtime"
}

_graph_preflight_check_model_auth() {
  local findings="$1" node_id="$2" runtime="$3" model="$4" cli="$5"
  local auth_out models_out catalog probe_rc

  if [[ -z "$runtime" ]]; then
    return 0
  fi

  if ! graph_preflight_cli_exists "$cli"; then
    graph_preflight_append "$findings" "model-auth:${node_id}" model-auth fail \
      "runtime CLI is not available" "cli=${cli:-none}" \
      "install the ${runtime} CLI or set the runtime CLI override" "$node_id" "$runtime"
    return 0
  fi

  if graph_preflight_auth_argv "$runtime" >/dev/null; then
    auth_out=""
    probe_rc=0
    auth_out="$(graph_preflight_auth_argv "$runtime" | graph_preflight_run_probe "$cli")" || probe_rc=$?
    if [[ "$probe_rc" -ne 0 ]] || graph_preflight_auth_indicates_missing "$auth_out"; then
      graph_preflight_append "$findings" "model-auth:${node_id}" model-auth fail \
        "runtime authentication is missing" \
        "cli=$cli exit=$probe_rc" \
        "log in to ${runtime} with its documented auth command" "$node_id" "$runtime"
      return 0
    fi
  else
    graph_preflight_append "$findings" "model-auth:${node_id}:auth" model-auth warn \
      "runtime has no non-billable auth status command" \
      "cli=$cli authProbe=unsupported" \
      "confirm ${runtime} auth before the run" "$node_id" "$runtime"
  fi

  if [[ -z "$model" ]]; then
    graph_preflight_append "$findings" "model-auth:${node_id}" model-auth pass \
      "runtime CLI is present; model will use the runtime default" \
      "cli=$cli model=(runtime default)" "" "$node_id" "$runtime"
    return 0
  fi

  if ! graph_preflight_models_argv "$runtime" >/dev/null; then
    graph_preflight_append "$findings" "model-auth:${node_id}" model-auth warn \
      "declared model cannot be confirmed against a catalog" \
      "cli=$cli model=$model catalog=unavailable" \
      "confirm the model id with the ${runtime} CLI" "$node_id" "$runtime"
    return 0
  fi

  models_out=""
  probe_rc=0
  models_out="$(graph_preflight_models_argv "$runtime" | graph_preflight_run_probe "$cli")" || probe_rc=$?
  if [[ "$probe_rc" -ne 0 ]]; then
    graph_preflight_append "$findings" "model-auth:${node_id}" model-auth warn \
      "model catalog probe failed without a session" \
      "cli=$cli model=$model exit=$probe_rc" \
      "retry after ${runtime} is logged in" "$node_id" "$runtime"
    return 0
  fi
  catalog="$(graph_preflight_parse_model_list "$runtime" "$models_out")"
  if graph_preflight_model_in_catalog "$model" "$catalog"; then
    graph_preflight_append "$findings" "model-auth:${node_id}" model-auth pass \
      "declared model is present in the runtime catalog" \
      "model=$model" "" "$node_id" "$runtime"
    return 0
  fi
  graph_preflight_append "$findings" "model-auth:${node_id}" model-auth fail \
    "declared model is not in the runtime catalog" \
    "model=$model" \
    "$(if [[ "$runtime" == "antigravity" ]]; then printf 'run agy models and copy the exact display string'; else printf 'choose a model listed by the %s CLI' "$runtime"; fi)" \
    "$node_id" "$runtime"
}

_graph_preflight_check_host_commands() {
  local findings="$1" needs_python="$2" needs_git="$3"

  if graph_preflight_cmd_available jq; then
    graph_preflight_append "$findings" "commands:jq" commands pass \
      "jq is available" "jq present" ""
  else
    graph_preflight_append "$findings" "commands:jq" commands fail \
      "jq is required for graph preflight" "jq missing" "install jq"
  fi

  if [[ "$needs_python" == "1" ]]; then
    if graph_preflight_cmd_available python3; then
      graph_preflight_append "$findings" "commands:python3" commands pass \
        "python3 is available for isolated workspaces and publish" "python3 present" ""
    else
      graph_preflight_append "$findings" "commands:python3" commands fail \
        "python3 is required for snapshot, worktree, or on-verified publish" \
        "python3 missing" "install python3"
    fi
  fi

  if [[ "$needs_git" == "1" ]]; then
    if graph_preflight_cmd_available git; then
      graph_preflight_append "$findings" "commands:git" commands pass \
        "git is available for worktree isolation" "git present" ""
    else
      graph_preflight_append "$findings" "commands:git" commands fail \
        "git is required for worktree mode" "git missing" "install git"
    fi
  fi
}

_graph_preflight_check_gate_commands() {
  local findings="$1" graph="$2"
  local profile step_name cmd exe

  while IFS=$'\t' read -r profile step_name cmd || [[ -n "$profile" ]]; do
    [[ -n "$cmd" ]] || continue
    exe="$(graph_gate_extract_executable "$cmd")"
    if ! graph_gate_is_allowed_executable "$exe"; then
      graph_preflight_append "$findings" "commands:gate:${profile}:${step_name}" commands fail \
        "gate command is not in the allowlist" "command=$cmd exe=$exe" \
        "use an allowlisted executable or add it to RALPH_GATE_EXTRA_ALLOWED" "" ""
      continue
    fi
    if graph_preflight_cmd_available "$exe"; then
      graph_preflight_append "$findings" "commands:gate:${profile}:${step_name}" commands pass \
        "gate command is allowlisted and present" "command=$cmd" "" "" ""
    else
      graph_preflight_append "$findings" "commands:gate:${profile}:${step_name}" commands fail \
        "gate command executable is missing" "command=$cmd exe=$exe" \
        "install ${exe} or change the verification profile command" "" ""
    fi
  done < <(jq -r '
    (.verificationProfiles // [])[]
    | .name as $p
    | (.steps // [])[]
    | [$p, .name, .command] | @tsv
  ' "$graph")
}

_graph_preflight_check_publish() {
  local findings="$1" graph="$2"
  local mode has_integrate has_isolated

  mode="$(jq -r '.publishMode // "manual"' "$graph")"
  case "$mode" in
    manual)
      graph_preflight_append "$findings" "publish:mode" publish pass \
        "manual publish has no automatic publication preconditions" \
        "publishMode=manual" ""
      return 0
      ;;
    on-verified)
      ;;
    *)
      graph_preflight_append "$findings" "publish:mode" publish fail \
        "invalid publish mode" "publishMode=$mode" \
        "set publishMode to manual or on-verified"
      return 0
      ;;
  esac

  has_integrate="$(jq -r '[.nodes[] | select(.type == "integrate")] | length > 0' "$graph")"
  has_isolated="$(jq -r '[.nodes[] | (.stage.workspaceMode // "shared")] | any(. == "snapshot" or . == "worktree")' "$graph")"

  if [[ "$has_integrate" != "true" ]]; then
    graph_preflight_append "$findings" "publish:integrate" publish fail \
      "on-verified publishing requires an integrate node" \
      "publishMode=on-verified integrate=false" \
      "add a type: integrate node or set publishMode: manual"
  else
    graph_preflight_append "$findings" "publish:integrate" publish pass \
      "on-verified graph declares an integrate node" \
      "publishMode=on-verified" ""
  fi

  if [[ "$has_isolated" != "true" ]]; then
    graph_preflight_append "$findings" "publish:isolation" publish fail \
      "on-verified publishing requires an immutable snapshot or worktree base" \
      "requestedModes are shared-only" \
      "set workspaceMode: snapshot on at least one node, or use publishMode: manual"
  else
    graph_preflight_append "$findings" "publish:isolation" publish pass \
      "on-verified graph requests an isolated workspace base" \
      "snapshot or worktree is present" ""
  fi

  if graph_preflight_cmd_available python3; then
    graph_preflight_append "$findings" "publish:python3" publish pass \
      "python3 is available for publish identity and changeset capture" \
      "python3 present" ""
  else
    graph_preflight_append "$findings" "publish:python3" publish fail \
      "on-verified publishing requires python3" "python3 missing" "install python3"
  fi
}

# graph_preflight_report <graph-json> [project-root]
#
# Prints one JSON object. Returns 0 when the report is produced, 1 when the
# graph cannot be read. The report is the only output; the module writes no
# project or run files.
graph_preflight_report() {
  local graph="${1:-}" project="${2:-}"
  local findings caps_cache runtime node_id node_type mode model
  local scopes_json ack git_access cli caps
  local needs_python=0 needs_git=0
  local seen_runtimes=""
  local outcome findings_json

  if ! command -v jq >/dev/null 2>&1; then
    echo "Error: jq is required for graph_preflight_report" >&2
    return 1
  fi
  if [[ -z "$graph" || ! -f "$graph" ]]; then
    echo "Error: graph_preflight_report requires a frozen graph.json" >&2
    return 1
  fi
  if ! jq -e 'type == "object" and (.nodes | type == "array")' "$graph" >/dev/null 2>&1; then
    echo "Error: frozen graph is not a readable graph object: $graph" >&2
    return 1
  fi

  if [[ -n "$project" && -d "$project" ]]; then
    project="$(cd "$project" && pwd -P)"
  fi

  findings="$(mktemp "${TMPDIR:-/tmp}/ralph-graph-preflight.XXXXXX")" || return 1
  caps_cache="$(mktemp "${TMPDIR:-/tmp}/ralph-graph-preflight-caps.XXXXXX")" || {
    rm -f "$findings"
    return 1
  }
  printf '%s\n' '{}' >"$caps_cache"

  if jq -e '[.nodes[] | (.stage.workspaceMode // "shared")] | any(. == "snapshot" or . == "worktree")' "$graph" >/dev/null; then
    needs_python=1
  fi
  if jq -e '[.nodes[] | (.stage.workspaceMode // "shared")] | any(. == "worktree")' "$graph" >/dev/null; then
    needs_git=1
  fi
  if [[ "$(jq -r '.publishMode // "manual"' "$graph")" == "on-verified" ]]; then
    needs_python=1
  fi

  _graph_preflight_check_host_commands "$findings" "$needs_python" "$needs_git"
  _graph_preflight_check_gate_commands "$findings" "$graph"
  _graph_preflight_check_publish "$findings" "$graph"

  while IFS=$'\034' read -r node_id node_type runtime mode model scopes_json ack git_access || [[ -n "$node_id" ]]; do
    [[ -n "$node_id" ]] || continue
    runtime="$(graph_runtime_normalize_runtime "$runtime")"
    [[ -z "$mode" ]] && mode="shared"
    [[ -z "$scopes_json" ]] && scopes_json='[]'
    cli=""
    caps=""
    if [[ -n "$runtime" ]]; then
      cli="$(graph_preflight_resolve_cli "$runtime")"
      caps="$(jq -c --arg r "$runtime" '.[$r] // empty' "$caps_cache" 2>/dev/null || true)"
      if [[ -z "$caps" ]]; then
        if graph_preflight_cli_exists "$cli"; then
          caps="$(graph_runtime_capabilities "$runtime" "$cli")"
        else
          caps="$(graph_runtime_capabilities "$runtime")"
        fi
        jq --arg r "$runtime" --argjson caps "$caps" '. + {($r): $caps}' "$caps_cache" >"${caps_cache}.next" && \
          mv "${caps_cache}.next" "$caps_cache"
      fi
    fi

    _graph_preflight_check_workspace_node "$findings" "$node_id" "$mode" "$runtime" \
      "$scopes_json" "$ack" "$git_access" "$caps" "$project"
    _graph_preflight_check_write_scopes "$findings" "$node_id" "$node_type" "$mode" \
      "$runtime" "$scopes_json" "$ack" "$caps"

    if [[ -n "$runtime" ]]; then
      case " $seen_runtimes " in
        *" $runtime "*) ;;
        *)
          seen_runtimes="${seen_runtimes} ${runtime}"
          _graph_preflight_check_approval "$findings" "$runtime" "$caps"
          ;;
      esac
      _graph_preflight_check_model_auth "$findings" "$node_id" "$runtime" "$model" "$cli"
    fi
  done < <(jq -jr '
    .nodes[]
    | ([
        .id,
        (.type // "agent"),
        (.stage.runtime // ""),
        (.stage.workspaceMode // "shared"),
        (.stage.model // ""),
        ((.stage.writeScopes // []) | tostring),
        ((.stage.acknowledgeSharedMutationRisk // false) | tostring),
        (.stage.agentGitAccess // "")
      ] | map(tostring) | join("\u001c")) + "\n"
  ' "$graph")

  outcome="$(graph_preflight_worst "$findings")"
  if [[ -s "$findings" ]]; then
    findings_json="$(jq -s '.' "$findings")"
  else
    findings_json='[]'
  fi
  rm -f "$findings" "$caps_cache" "${caps_cache}.next"

  jq -nc \
    --argjson schema "$GRAPH_PREFLIGHT_SCHEMA_VERSION" \
    --arg outcome "$outcome" \
    --argjson findings "$findings_json" \
    '{
      schemaVersion: $schema,
      readOnly: true,
      outcome: $outcome,
      findings: $findings
    }'
}
