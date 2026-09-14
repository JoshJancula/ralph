#!/usr/bin/env bash
# Scheduler-side executor for brokered graph children.  MCP only creates the
# ledger entry; this module is the sole path that turns one into a plan run.

if [ "${BASH_SOURCE[0]}" = "$0" ]; then echo "This file is meant to be sourced, not executed." >&2; exit 1; fi
if [[ -n "${GRAPH_DELEGATION_RUNNER_LOADED:-}" ]]; then return 0; fi
GRAPH_DELEGATION_RUNNER_LOADED=1
_GRAPH_DELEGATION_RUNNER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if ! declare -F graph_delegation_ledger_read_status >/dev/null 2>&1; then source "$_GRAPH_DELEGATION_RUNNER_DIR/graph-delegation-ledger.sh"; fi
if ! declare -F ralph_kill_process_group >/dev/null 2>&1; then source "$_GRAPH_DELEGATION_RUNNER_DIR/../ralph-process-teardown.sh"; fi
if ! declare -F graph_depth_policy_log_denial >/dev/null 2>&1; then source "$_GRAPH_DELEGATION_RUNNER_DIR/graph-depth-policy.sh"; fi
if ! declare -F graph_runtime_is_known_runtime >/dev/null 2>&1; then source "$_GRAPH_DELEGATION_RUNNER_DIR/graph-runtime-capabilities.sh"; fi

graph_delegation_runner_log() {
  local workspace="$1"; shift
  local state_root path
  state_root="$(graph_state_state_root "$workspace")" || return 0
  path="$state_root/logs/delegated-child-runner.log"
  mkdir -p "$(dirname "$path")" 2>/dev/null || true
  printf '[%s] delegated-child-runner: %s\n' "$(graph_state_now_iso)" "$*" >>"$path" 2>/dev/null || true
}

graph_delegation_child_workspace_remove() {
  local owner="$1" path="$2" owner_real path_real
  [[ -d "$owner" && ! -L "$owner" && -d "$path" && ! -L "$path" ]] || return 1
  owner_real="$(cd "$owner" && pwd -P)" || return 1
  path_real="$(cd "$path" && pwd -P)" || return 1
  [[ "$path_real" == "$owner_real/workspace" ]] || return 1
  chmod -R u+w "$path_real" 2>/dev/null || true
  rm -rf "$path_real"
}

# The required child result is a supervisor handoff, not a product mutation.
# Copy it into durable state, then remove only that exact workspace file before
# read-only identity comparison or scoped changeset capture. Empty directories
# created solely for the result are pruned without crossing the workspace root.
graph_delegation_child_extract_result() {
  local child_workspace="$1" result_abs="$2" durable_result="$3"
  local workspace_real result_parent parent_real
  workspace_real="$(cd "$child_workspace" && pwd -P)" || return 1
  result_parent="$(dirname "$result_abs")"
  parent_real="$(cd "$result_parent" 2>/dev/null && pwd -P)" || return 1
  [[ "$parent_real" == "$workspace_real" || "$parent_real" == "$workspace_real/"* ]] || return 1
  [[ -f "$result_abs" || -L "$result_abs" ]] || return 1
  mkdir -p "$(dirname "$durable_result")" || return 1
  cp -p "$result_abs" "$durable_result" || return 1
  rm -f "$result_abs" || return 1
  while [[ "$result_parent" != "$child_workspace" && "$result_parent" != "$workspace_real" ]]; do
    rmdir "$result_parent" 2>/dev/null || break
    result_parent="$(dirname "$result_parent")"
  done
}

graph_delegation_child_record_process() {
  local workspace="$1" did pid pgid status_file base
  if [[ "$#" -ge 7 ]]; then did="$5"; pid="$6"; pgid="${7:-$6}"; else did="$2"; pid="$3"; pgid="${4:-$3}"; fi
  status_file="$(graph_delegation_ledger_status_file "$workspace" "$did")" || return 1
  base="$(graph_delegation_ledger_read_status "$workspace" "$did")" || return 1
  ralph_atomic_write_json "$status_file" '($base|fromjson) + {runner:{pid:$pid,pgid:$pgid,startedAt:$now}}' \
    --arg base "$base" --argjson pid "$pid" --argjson pgid "$pgid" --arg now "$(graph_state_now_iso)"
}

graph_delegation_child_process_alive() {
  local workspace="$1" did pid
  [[ "$#" -ge 5 ]] && did="$5" || did="$2"
  pid="$(graph_delegation_ledger_read_status "$workspace" "$did" 2>/dev/null | jq -r '.runner.pid // empty')"
  [[ "$pid" =~ ^[0-9]+$ ]] && kill -0 "$pid" 2>/dev/null
}

# Cancelling a delegated child is intentionally scoped to the child session.
# It never signals the parent node's process group.
graph_delegation_child_cancel() {
  local workspace="$1" did reason="${3:-cancelled by parent/scheduler}" pid pgid state
  [[ "$#" -ge 5 ]] && did="$5" || did="$2"
  state="$(graph_delegation_ledger_read_status "$workspace" "$did" 2>/dev/null | jq -r '.status // empty')" || return 1
  [[ "$state" == queued || "$state" == running ]] || return 0
  pid="$(graph_delegation_ledger_read_status "$workspace" "$did" 2>/dev/null | jq -r '.runner.pid // empty')"
  pgid="$(graph_delegation_ledger_read_status "$workspace" "$did" 2>/dev/null | jq -r '.runner.pgid // empty')"
  if [[ "$pgid" =~ ^[0-9]+$ && "$pgid" -gt 1 ]]; then ralph_kill_process_group "$pgid" "${RALPH_PROCESS_TERM_GRACE_SECONDS:-5}" || true
  elif [[ "$pid" =~ ^[0-9]+$ ]]; then ralph_kill_tree "$pid" || true; fi
  graph_delegation_ledger_transition "$workspace" "$did" cancelled "" "" '{}' null "$reason" || return 1
  graph_delegation_runner_log "$workspace" "cancelled delegation=$did reason=$reason"
}

# A profile is selected by name from the frozen graph, never accepted as a
# command from the parent. Profiles are {name,verify} objects.
_graph_delegation_runner_profile_verify() {
  local profiles="$1" name="$2"
  [[ -n "$name" ]] || { printf '\n'; return 0; }
  jq -r --arg n "$name" '
    .[] | select(.name == $n) |
    .verify // ((.steps // []) | map("(" + .command + ")") | join(" && ")) // empty
  ' <<<"$profiles" | head -1
}

graph_delegation_child_materialize() {
  local workspace="$1" ns="$2" run_id="$3" parent="$4" did="$5" profiles="$6"
  local request plan dir task profile verify result_path result_abs mode artifact_ns
  request="$(graph_delegation_ledger_request_file "$workspace" "$did")"
  dir="$(dirname "$request")"
  plan="$dir/.runner.plan.md"
  [[ -f "$request" ]] || return 1
  if [[ -s "$plan" ]]; then
    result_path="$(sed -n 's|^Required result artifact: ||p' "$plan" | head -1)"
    [[ -n "$result_path" ]] || return 1
    printf '%s\t%s\n' "$plan" "$result_path"
    return 0
  fi
  task="$(jq -r '.task' "$request")"
  mode="$(jq -r '.workspaceMode // (if .mode == "snapshot" or .mode == "worktree" then .mode else "snapshot" end)' "$request")"
  [[ "$(jq -r '.accessMode // (if .mode == "changeset" then "changeset" else "read-only" end)' "$request" 2>/dev/null)" == changeset ]] || mode="snapshot"
  artifact_ns="${ns:-delegated-$did}"
  profile="$(jq -r '.verificationProfile // empty' "$request")"
  verify="$(_graph_delegation_runner_profile_verify "$profiles" "$profile")"
  [[ -z "$profile" || -n "$verify" ]] || { echo "unknown verification profile: $profile" >&2; return 1; }
  result_path="$(jq -r '.artifactPaths[0] // (".ralph-workspace/artifacts/" + $ns + "/delegated/" + $did + "/result.json")' --arg ns "$artifact_ns" --arg did "$did" "$request")"
  result_abs="$result_path"
  [[ "$result_abs" == /* ]] || result_abs="$dir/workspace/$result_abs"
  {
    printf '%s\n' '---'
    printf 'delegatedRunId: %s\nparentNodeId: %s\nworkspaceMode: %s\nretryGutter: %s\n' "$did" "$parent" "$mode" "${RALPH_DELEGATION_GUTTER_ITERATIONS:-2}"
    [[ -n "$verify" ]] && printf 'verify: %s\n' "$verify"
    printf '%s\n' '---' '' "# Ralph-owned delegated child $did" '' "- [ ] $task" '' "Required result artifact: $result_abs" "Do not delegate further."
  } >"$plan" || return 1
  printf '%s\t%s\n' "$plan" "$result_abs"
}

# Delegated requests are validated before a child process is admitted.  The
# ledger has already authenticated the record and its schema version; this
# check is the runner's fail-closed boundary for execution-only fields.
_graph_delegation_runner_validate_request() {
  local request="$1" did="$2"
  jq -e --arg did "$did" '
    type == "object" and
    .delegatedRunId == $did and
    (.task | type == "string" and length > 0) and
    (.runtime as $r |
      ($r | type == "string") and
      (["cursor", "claude", "codex", "opencode", "antigravity"] | index($r) != null)) and
    ((.role? == null) or (.role | type == "string" and test("^[a-z0-9]+(-[a-z0-9]+)*$"))) and
    ((.depth? == null) or (.depth | type == "number" and . == 1)) and
    (has("model") | not) and
    (has("agent") | not)
  ' "$request" >/dev/null 2>&1
}

_graph_delegation_runner_reject() {
  local workspace="$1" did="$2" reason="$3" state
  state="$(graph_delegation_ledger_read_status "$workspace" "$did" 2>/dev/null | jq -r '.status // empty')"
  if [[ "$state" == queued || "$state" == running ]]; then
    graph_delegation_ledger_transition "$workspace" "$did" failed preflight fail '{}' null "$reason" >/dev/null 2>&1 || true
  fi
  graph_delegation_runner_log "$workspace" "rejected delegation=$did reason=$reason"
  printf 'Error: delegated run %s: %s\n' "$did" "$reason" >&2
  return 1
}

_graph_delegation_runner_validate_relative_path() {
  local root="$1" value="$2" current part resolved
  [[ -d "$root" && ! -L "$root" ]] || return 1
  [[ "$value" != /* && "$value" != *'\\'* && "$value" != */ && "$value" != *//* ]] || return 1
  [[ "$value" != .. && "$value" != ../* && "$value" != */.. && "$value" != */../* ]] || return 1
  current="$root"
  while IFS= read -r -d '/' part; do
    [[ -n "$part" ]] || return 1
    current="$current/$part"
    if [[ -L "$current" ]]; then
      resolved="$(realpath "$current" 2>/dev/null || true)"
      [[ -n "$resolved" && ( "$resolved" == "$root" || "$resolved" == "$root/"* ) ]] || return 1
    fi
  done < <(printf '%s/' "$value")
}

_graph_delegation_runner_validate_artifact_paths() {
  local root="$1" request="$2" path result_path
  result_path="$(jq -r '.artifactPaths[0] // empty' "$request" 2>/dev/null)"
  while IFS= read -r path; do
    [[ -n "$path" ]] || continue
    _graph_delegation_runner_validate_relative_path "$root" "$path" || return 1
  done < <(jq -r '.artifactPaths // [] | .[]' "$request" 2>/dev/null)
  [[ -z "$result_path" ]] || _graph_delegation_runner_validate_relative_path "$root" "$result_path"
}

_graph_delegation_runner_admit_runtime() {
  local runtime="$1" parent_runtime="${2:-}" cap active global_cap global_active
  graph_runtime_is_known_runtime "$runtime" || return 2
  if [[ -n "$parent_runtime" && "$parent_runtime" == "$runtime" ]]; then
    graph_runtime_same_runtime_parallel_safe "$runtime" || return 3
  fi
  # The scheduler normally owns the capacity reservation.  Direct runner
  # callers may provide the same active-slot evidence explicitly; a parent
  # already consumes one slot, so a cap of one cannot admit this child.
  cap="${RALPH_GRAPH_MAX_PARALLEL_PER_RUNTIME:-}"
  active="${RALPH_GRAPH_RUNTIME_ACTIVE_SLOTS:-${RALPH_GRAPH_ACTIVE_RUNTIME_SLOTS:-}}"
  if [[ -n "$parent_runtime" && "$parent_runtime" == "$runtime" && -n "$cap" && "$cap" =~ ^[0-9]+$ && "$cap" -lt 2 ]]; then
    return 4
  fi
  if [[ -n "$parent_runtime" && "$parent_runtime" == "$runtime" && -n "$cap" && "$cap" =~ ^[0-9]+$ && -n "$active" && "$active" =~ ^[0-9]+$ ]]; then
    (( active + 1 <= cap )) 2>/dev/null || return 4
  fi
  global_cap="${RALPH_GRAPH_MAX_PARALLEL:-}"
  global_active="${RALPH_GRAPH_ACTIVE_SLOTS:-}"
  if [[ -n "$parent_runtime" && -n "$global_cap" && "$global_cap" =~ ^[0-9]+$ && "$global_cap" -lt 2 ]]; then
    return 4
  fi
  if [[ -n "$parent_runtime" && -n "$global_cap" && "$global_cap" =~ ^[0-9]+$ && -n "$global_active" && "$global_active" =~ ^[0-9]+$ ]]; then
    (( global_active + 1 <= global_cap )) 2>/dev/null || return 4
  fi
  return 0
}

# graph_delegation_child_run <workspace> <namespace> <run> <parent> <id>
# <project-root> <state-root> <parent-agent-workspace> <profiles-json>
graph_delegation_child_run() {
  local workspace="$1" ns="$2" run_id="$3" parent="$4" did="$5" project_root="$6" state_root="$7" parent_agent_workspace="$8" profiles="${9:-[]}"
  local request plan status result_path result_abs child_workspace mode runtime runner attempt rc=0
  local dir policy_mode scopes baseline after_baseline base_identity changeset integration conflict durable_dir durable_result final_result declared_artifacts='[]' current_state parent_runtime
  request="$(graph_delegation_ledger_request_file "$workspace" "$did")"; [[ -f "$request" ]] || return 1
  _graph_delegation_runner_validate_request "$request" "$did" || {
    _graph_delegation_runner_reject "$workspace" "$did" "invalid validated request"
    return $?
  }
  dir="$(dirname "$request")"
  mode="$(jq -r '.workspaceMode // (if .mode == "snapshot" or .mode == "worktree" then .mode else "snapshot" end)' "$request")"
  runtime="$(jq -r '.runtime // empty' "$request")"
  policy_mode="$(jq -r '.accessMode // (if .mode == "changeset" then "changeset" else "read-only" end)' "$request" 2>/dev/null || true)"
  case "$policy_mode" in
    read-only) mode="snapshot" ;;
    changeset)
      [[ "$mode" == snapshot || "$mode" == worktree ]] || {
        _graph_delegation_runner_reject "$workspace" "$did" "changeset requires snapshot or worktree workspace"
        return $?
      }
      ;;
    *)
      _graph_delegation_runner_reject "$workspace" "$did" "unsupported access mode: $policy_mode"
      return $?
      ;;
  esac
  parent_runtime="${RALPH_GRAPH_NODE_RUNTIME:-${RALPH_GRAPH_DELEGATION_PARENT_RUNTIME:-}}"
  _graph_delegation_runner_admit_runtime "$runtime" "$parent_runtime"
  case "$?" in
    0) ;;
    2) _graph_delegation_runner_reject "$workspace" "$did" "runtime is unavailable"; return $? ;;
    3) _graph_delegation_runner_reject "$workspace" "$did" "unsafe same-runtime overlay/config isolation"; return $? ;;
    4) _graph_delegation_runner_reject "$workspace" "$did" "runtime capacity exhausted"; return $? ;;
    *) _graph_delegation_runner_reject "$workspace" "$did" "runtime admission failed"; return $? ;;
  esac
  [[ -d "$parent_agent_workspace" && ! -L "$parent_agent_workspace" ]] || {
    _graph_delegation_runner_reject "$workspace" "$did" "parent workspace is unavailable or escapes through a symlink"
    return $?
  }
  _graph_delegation_runner_validate_artifact_paths "$parent_agent_workspace" "$request" || {
    _graph_delegation_runner_reject "$workspace" "$did" "artifact path escapes the child workspace"
    return $?
  }
  _graph_delegation_child_interrupted() {
    graph_delegation_ledger_transition "$workspace" "$did" cancelled "$attempt" cancel '{}' null 'child interrupted' >/dev/null 2>&1 || true
    rc=130
  }
  trap _graph_delegation_child_interrupted TERM INT HUP
  local materialized=""
  materialized="$(graph_delegation_child_materialize "$workspace" "$ns" "$run_id" "$parent" "$did" "$profiles")" || {
    graph_delegation_ledger_transition "$workspace" "$did" failed materialize fail '{}' null 'child materialization failed' 2>/dev/null || true
    return 1
  }
  IFS=$'\t' read -r plan result_path <<<"$materialized"
  scopes="$(jq -c '.writeScopes // .scopes // []' "$request" 2>/dev/null || printf '[]')"
  child_workspace="$dir/workspace"
  if [[ -e "$child_workspace" || -L "$child_workspace" ]]; then
    [[ -d "$child_workspace" && ! -L "$child_workspace" ]] || {
      _graph_delegation_runner_reject "$workspace" "$did" "child workspace is a symlink escape"
      return $?
    }
  else
    mkdir -p "$child_workspace" || return 1
  fi
  # Brokered children always run in a non-Git snapshot. The durable ledger and
  # result live outside this model-writable copy.
  (cd "$parent_agent_workspace" && tar --exclude='./.git' --exclude='./.ralph-workspace' -cf - .) \
    | (cd "$child_workspace" && tar -xf -) || return 1
  baseline="$dir/workspace-baseline.json"
  python3 "$_GRAPH_DELEGATION_RUNNER_DIR/../../python/graph_changeset.py" baseline \
    --workspace "$child_workspace" --output "$baseline" >/dev/null || {
      _graph_delegation_runner_reject "$workspace" "$did" "workspace contains a symlink escape"
      return $?
    }
  runner="${RALPH_DELEGATION_RUN_PLAN:-$project_root/.ralph/run-plan.sh}"
  attempt="child-${did}-$(date +%s)"
  graph_delegation_runner_log "$workspace" "invoke delegation=$did plan=$plan runtime=$runtime"
  # Layer 2+5: runtime tool removal and child environment.  Model resolution
  # belongs to run-plan: staged scope selects saved Claude/Codex models and
  # otherwise leaves the native runtime default in charge.  The request never
  # supplies a model and this invocation never appends --model.
  # RALPH_MCP_SCOPE=delegated-child removes spawn tools from the MCP catalog.
  # RALPH_GRAPH_DELEGATION_DEPTH=1 blocks any nested delegation attempt at the handler.
  # RALPH_STAGE_SUBAGENTS=off prevents the orchestrator from loading native subagent support.
  # RALPH_GRAPH_CROSS_RUNTIME_DELEGATION=off is a belt-and-suspenders block on cross-runtime calls.
  (
    unset RALPH_GRAPH_NAMESPACE RALPH_GRAPH_RUN_ID RALPH_GRAPH_NODE_ID RALPH_GRAPH_ATTEMPT_ID \
      RALPH_GRAPH_NODE_POLICY RALPH_GRAPH_NODE_RUNTIME RALPH_GRAPH_CHANGESET_BASELINE \
      RALPH_GRAPH_CHANGESET_HELPER RALPH_GRAPH_WRITE_SCOPES_JSON RALPH_GRAPH_WORKSPACE_MODE \
      RALPH_GRAPH_BASE_IDENTITY RALPH_PROCESS_RUN_DIR RALPH_PROCESS_RUN_ID RALPH_PROCESS_RUN_TOKEN \
      RALPH_PROCESS_GUARDIAN_PID RALPH_PROCESS_RUN_OWNED RALPH_PROCESS_RUN_DEPTH 2>/dev/null || true
    unset PLAN_MODEL_CLI PLAN_TODO_MODEL PLAN_STAGE_MODEL \
      CLAUDE_PLAN_MODEL CODEX_PLAN_MODEL CURSOR_PLAN_MODEL \
      OPENCODE_PLAN_MODEL ANTIGRAVITY_PLAN_MODEL 2>/dev/null || true
    export RALPH_GRAPH_DELEGATION_DEPTH=1
    export RALPH_MODEL_SCOPE=staged
    export RALPH_ARTIFACT_NS="${ns:-delegated-$did}"
    export RALPH_GRAPH_CROSS_RUNTIME_DELEGATION=off
    export RALPH_MCP_SCOPE=delegated-child
    export RALPH_PLAN_KEY="delegated-${did}"
    export RALPH_PLAN_CLI_RESUME=0 RALPH_PLAN_SESSION_STRATEGY=fresh
    export RALPH_STAGE_SUBAGENTS=off RALPH_PLAN_SUBAGENTS=off
    export RALPH_PLAN_TODO_MAX_ITERATIONS="${RALPH_DELEGATION_GUTTER_ITERATIONS:-2}"
    local -a child_argv=("$runner" --runtime "$runtime" --plan "$plan" \
      --workspace "$project_root" --workspace-root "$state_root" \
      --agent-workspace "$child_workspace")
    # The delegated-run "role" is a policy allowlist label (delegatedRuns.roles)
    # and a ledger observability field -- it never selected a child agent
    # profile. run-plan rejects --role with exit 2, so forwarding it here made
    # every roled delegated run fail before doing any work.
    "${child_argv[@]}"
  ) || rc=$?
  trap - TERM INT HUP
  current_state="$(graph_delegation_ledger_read_status "$workspace" "$did" 2>/dev/null | jq -r '.status // empty')"
  if [[ "$current_state" == cancelled ]]; then
    graph_delegation_child_workspace_remove "$dir" "$child_workspace" || true
    rm -f "$plan"
    return 130
  fi
  status="$(grep -c '^- \[x\]' "$plan" 2>/dev/null || true)"
  result_abs="$result_path"
  [[ "$result_abs" == /* ]] || result_abs="$child_workspace/$result_abs"
  # The ledger owns the child handoff. result.json remains the terminal ledger
  # record; model-produced artifacts live below its declared artifacts/ dir.
  durable_dir="$dir"
  durable_result="$durable_dir/artifacts/result.json"
  mkdir -p "$durable_dir" || rc=1
  # Copy every declared handoff before extracting the primary result. The
  # copies are immutable, state-root-owned evidence used by completion/restart.
  while IFS= read -r declared_path; do
    [[ -n "$declared_path" && "$declared_path" != /* && "$declared_path" != *..* && "$declared_path" != *//* ]] || { rc=1; break; }
    local declared_abs="$child_workspace/$declared_path" declared_dst="$durable_dir/artifacts/$declared_path"
    [[ -f "$declared_abs" && -s "$declared_abs" && ! -L "$declared_abs" ]] || { rc=1; break; }
    mkdir -p "$(dirname "$declared_dst")" && cp -p "$declared_abs" "$declared_dst" || { rc=1; break; }
    declared_artifacts="$(jq -c --arg d "$declared_path" --arg a "$declared_dst" '. + [{declaredPath:$d,artifactPath:$a}]' <<<"$declared_artifacts")"
  done < <(jq -r '.artifactPaths // [] | .[]' "$request" 2>/dev/null)
  if [[ "$rc" -eq 0 && "$status" -gt 0 && -s "$result_abs" ]]; then
    graph_delegation_child_extract_result "$child_workspace" "$result_abs" "$durable_result" || rc=1
  fi
  if [[ "$rc" -eq 0 && "$status" -gt 0 && -s "$durable_result" ]]; then
    if [[ "$policy_mode" == changeset ]]; then
      [[ "$(jq 'length' <<<"$scopes" 2>/dev/null || echo 0)" -gt 0 ]] || rc=1
      base_identity="$(jq -r '.sourceBase.filesystemIdentity // .sourceBase.git.treeHash // empty' "$(graph_state_run_file "$workspace" "$ns" "$run_id")" 2>/dev/null || true)"
      changeset="$durable_dir/changeset.json"
      integration="$durable_dir/integration.json"
      conflict="$durable_dir/integration-conflict.json"
      [[ -n "$base_identity" ]] || rc=1
      if [[ "$rc" -eq 0 ]]; then
        python3 "$_GRAPH_DELEGATION_RUNNER_DIR/../../python/graph_changeset.py" capture \
          --workspace "$child_workspace" --baseline "$baseline" --output "$changeset" \
          --node-id "$parent/$did" --attempt-id "$attempt" --workspace-mode "$mode" \
          --base-identity "$base_identity" --write-scopes-json "$scopes" >/dev/null || rc=1
      fi
      if [[ "$rc" -eq 0 ]]; then
        jq -e --arg mode "$mode" --arg base "$base_identity" \
          '.schemaVersion == 1 and .kind == "graph-changeset" and .workspaceMode == $mode and .baseIdentity == $base and (.writeScopes | type == "array" and length > 0) and .laneVerification.status == "passed" and .laneVerification.concurrentInterferenceDetected == false' \
          "$changeset" >/dev/null 2>&1 || rc=1
      fi
      if [[ "$rc" -eq 0 ]]; then
        python3 "$_GRAPH_DELEGATION_RUNNER_DIR/../../python/graph_integrate.py" \
          --workspace "$parent_agent_workspace" --output "$integration" --conflict-output "$conflict" \
          --node-id "$parent/$did" --base-identity "$base_identity" --manifest "$changeset" >/dev/null || rc=1
      fi
      final_result="$(jq -cn --arg result "$durable_result" --arg changeset "$changeset" --arg integration "$integration" --argjson declared "$declared_artifacts" \
        '{resultArtifact:$result,declaredArtifacts:$declared,changesetArtifact:$changeset,integrationResult:$integration,integrated:true}')"
    else
      after_baseline="$dir/workspace-after.json"
      python3 "$_GRAPH_DELEGATION_RUNNER_DIR/../../python/graph_changeset.py" baseline \
        --workspace "$child_workspace" --output "$after_baseline" >/dev/null || rc=1
      if [[ "$rc" -eq 0 && "$(jq -r .filesystemIdentity "$baseline")" != "$(jq -r .filesystemIdentity "$after_baseline")" ]]; then
        rc=1
        graph_delegation_runner_log "$workspace" "read-only violation delegation=$did"
      fi
      final_result="$(jq -cn --arg result "$durable_result" --argjson declared "$declared_artifacts" '{resultArtifact:$result,declaredArtifacts:$declared,readOnlyVerified:true}')"
    fi
  fi
  if [[ "$rc" -eq 0 && "$status" -gt 0 && -s "$durable_result" ]]; then
    graph_delegation_ledger_transition "$workspace" "$did" succeeded "$attempt" pass '{}' "$final_result"
    graph_delegation_runner_log "$workspace" "succeeded delegation=$did artifact=$durable_result"
    graph_delegation_child_workspace_remove "$dir" "$child_workspace" || true
    rm -f "$plan"
    return 0
  fi
  [[ "$current_state" == queued || "$current_state" == running ]] && graph_delegation_ledger_transition "$workspace" "$did" failed "$attempt" fail '{}' null "child incomplete, missing result artifact, verification failure, or retry exhaustion"
  graph_delegation_runner_log "$workspace" "failed delegation=$did rc=$rc completed=$status artifact=$result_path"
  rm -f "$plan"
  return 1
}
