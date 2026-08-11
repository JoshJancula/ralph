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
  local workspace="$1" ns="$2" run_id="$3" parent="$4" did="$5" pid="$6" pgid="${7:-$6}" file
  file="$(graph_delegation_ledger_process_file "$workspace" "$ns" "$run_id" "$parent" "$did")" || return 1
  ralph_atomic_write_json "$file" '{pid:$pid,pgid:$pgid,startedAt:$now}' \
    --argjson pid "$pid" --argjson pgid "$pgid" --arg now "$(graph_state_now_iso)"
}

graph_delegation_child_process_alive() {
  local workspace="$1" ns="$2" run_id="$3" parent="$4" did="$5" file pid
  file="$(graph_delegation_ledger_process_file "$workspace" "$ns" "$run_id" "$parent" "$did")" || return 1
  [[ -f "$file" ]] || return 1
  pid="$(jq -r '.pid // empty' "$file" 2>/dev/null)"
  [[ "$pid" =~ ^[0-9]+$ ]] && kill -0 "$pid" 2>/dev/null
}

# Cancelling a delegated child is intentionally scoped to the child session.
# It never signals the parent node's process group.
graph_delegation_child_cancel() {
  local workspace="$1" ns="$2" run_id="$3" parent="$4" did="$5" file pid pgid
  file="$(graph_delegation_ledger_process_file "$workspace" "$ns" "$run_id" "$parent" "$did")" || return 1
  if [[ -f "$file" ]]; then
    pid="$(jq -r '.pid // empty' "$file" 2>/dev/null)"; pgid="$(jq -r '.pgid // empty' "$file" 2>/dev/null)"
    if [[ "$pgid" =~ ^[0-9]+$ && "$pgid" -gt 1 ]]; then ralph_kill_process_group "$pgid" "${RALPH_PROCESS_TERM_GRACE_SECONDS:-5}" || true
    elif [[ "$pid" =~ ^[0-9]+$ ]]; then ralph_kill_tree "$pid" || true; fi
  fi
  graph_delegation_ledger_transition "$workspace" "$ns" "$run_id" "$parent" "$did" cancelled "" "" '{}' null 'cancelled by parent/scheduler' || return 1
  graph_delegation_runner_log "$workspace" "cancelled delegation=$did parent=$parent"
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
  local request plan dir task profile verify result_path result_abs mode
  request="$(graph_delegation_ledger_request_file "$workspace" "$ns" "$run_id" "$parent" "$did")"
  plan="$(graph_delegation_ledger_plan_file "$workspace" "$ns" "$run_id" "$parent" "$did")"
  [[ -f "$request" ]] || return 1
  task="$(jq -r '.task' "$request")"; mode="$(jq -r '.workspaceMode' "$request")"
  profile="$(jq -r '.verificationProfile // empty' "$request")"
  verify="$(_graph_delegation_runner_profile_verify "$profiles" "$profile")"
  [[ -z "$profile" || -n "$verify" ]] || { echo "unknown verification profile: $profile" >&2; return 1; }
  result_path="$(jq -r '.artifactPaths[0] // (".ralph-workspace/artifacts/" + $ns + "/delegated/" + $did + "/result.json")' --arg ns "$ns" --arg did "$did" "$request")"
  dir="$(dirname "$plan")"
  result_abs="$result_path"
  [[ "$result_abs" == /* ]] || result_abs="$dir/workspace/$result_abs"
  {
    printf '%s\n' '---'
    printf 'delegationId: %s\nparentNodeId: %s\nworkspaceMode: %s\nretryGutter: %s\n' "$did" "$parent" "$mode" "${RALPH_DELEGATION_GUTTER_ITERATIONS:-2}"
    [[ -n "$verify" ]] && printf 'verify: %s\n' "$verify"
    printf '%s\n' '---' '' "# Ralph-owned delegated child $did" '' "- [ ] $task" '' "Required result artifact: $result_abs" "Do not delegate further."
  } >"$plan" || return 1
  printf '%s\n' "$result_abs"
}

# graph_delegation_child_run <workspace> <namespace> <run> <parent> <id>
# <project-root> <state-root> <parent-agent-workspace> <profiles-json>
graph_delegation_child_run() {
  local workspace="$1" ns="$2" run_id="$3" parent="$4" did="$5" project_root="$6" state_root="$7" parent_agent_workspace="$8" profiles="${9:-[]}"
  local request plan status result_path result_abs child_workspace mode runtime agent model runner attempt rc=0
  local dir policy_file policy_mode scopes baseline after_baseline base_identity changeset integration conflict durable_dir durable_result final_result
  request="$(graph_delegation_ledger_request_file "$workspace" "$ns" "$run_id" "$parent" "$did")"; [[ -f "$request" ]] || return 1
  dir="$(dirname "$request")"
  policy_file="$(graph_delegation_ledger_policy_file "$workspace" "$ns" "$run_id" "$parent" "$did")"
  plan="$(graph_delegation_ledger_plan_file "$workspace" "$ns" "$run_id" "$parent" "$did")"
  result_path="$(graph_delegation_child_materialize "$workspace" "$ns" "$run_id" "$parent" "$did" "$profiles")" || { graph_delegation_ledger_transition "$workspace" "$ns" "$run_id" "$parent" "$did" failed materialize fail '{}' null 'child materialization failed'; return 1; }
  mode="$(jq -r '.workspaceMode' "$request")"; runtime="$(jq -r '.runtime' "$request")"; agent="$(jq -r '.agent' "$request")"; model="$(jq -r '.model // empty' "$request")"
  policy_mode="$(jq -r '.accessMode // empty' "$request" 2>/dev/null || true)"
  [[ -n "$policy_mode" ]] || policy_mode="$(jq -r '.policy.requestedAccess // .policy.crossRuntime.mode // "read-only"' "$policy_file" 2>/dev/null || echo read-only)"
  scopes="$(jq -c '.policy.parentWriteScopes // []' "$policy_file" 2>/dev/null || echo '[]')"
  child_workspace="$dir/workspace"
  if [[ -e "$child_workspace" ]]; then
    graph_delegation_child_workspace_remove "$dir" "$child_workspace" || return 1
  fi
  mkdir -p "$child_workspace" || return 1
  # Brokered children always run in a non-Git snapshot. The durable ledger and
  # result live outside this model-writable copy.
  (cd "$parent_agent_workspace" && tar --exclude='./.git' --exclude='./.ralph-workspace' -cf - .) \
    | (cd "$child_workspace" && tar -xf -) || return 1
  baseline="$dir/workspace-baseline.json"
  python3 "$_GRAPH_DELEGATION_RUNNER_DIR/../../python/graph_changeset.py" baseline \
    --workspace "$child_workspace" --output "$baseline" >/dev/null || return 1
  runner="${RALPH_DELEGATION_RUN_PLAN:-$project_root/.ralph/run-plan.sh}"
  attempt="child-${did}-$(date +%s)"
  graph_delegation_runner_log "$workspace" "invoke delegation=$did plan=$plan runtime=$runtime"
  # Layer 2+5: runtime tool removal and child environment.
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
    RALPH_GRAPH_DELEGATION_DEPTH=1 RALPH_GRAPH_CROSS_RUNTIME_DELEGATION=off RALPH_MCP_SCOPE=delegated-child RALPH_PLAN_KEY="delegated-${did}" RALPH_PLAN_CLI_RESUME=0 RALPH_PLAN_SESSION_STRATEGY=fresh RALPH_STAGE_SUBAGENTS=off RALPH_PLAN_SUBAGENTS=off RALPH_PLAN_TODO_MAX_ITERATIONS="${RALPH_DELEGATION_GUTTER_ITERATIONS:-2}" \
      "$runner" --runtime "$runtime" --plan "$plan" --workspace "$project_root" --workspace-root "$state_root" --agent-workspace "$child_workspace" ${model:+--model "$model"}
  ) || rc=$?
  status="$(grep -c '^- \[x\]' "$plan" 2>/dev/null || true)"
  result_abs="$result_path"
  [[ "$result_abs" == /* ]] || result_abs="$child_workspace/$result_abs"
  durable_dir="$state_root/artifacts/$ns/delegated/$did"
  durable_result="$durable_dir/result.json"
  mkdir -p "$durable_dir" || rc=1
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
          --node-id "$parent/$did" --attempt-id "$attempt" --workspace-mode snapshot \
          --base-identity "$base_identity" --write-scopes-json "$scopes" >/dev/null || rc=1
      fi
      if [[ "$rc" -eq 0 ]]; then
        python3 "$_GRAPH_DELEGATION_RUNNER_DIR/../../python/graph_integrate.py" \
          --workspace "$parent_agent_workspace" --output "$integration" --conflict-output "$conflict" \
          --node-id "$parent/$did" --base-identity "$base_identity" --manifest "$changeset" >/dev/null || rc=1
      fi
      final_result="$(jq -cn --arg result "$durable_result" --arg changeset "$changeset" --arg integration "$integration" \
        '{resultArtifact:$result,changesetArtifact:$changeset,integrationResult:$integration,integrated:true}')"
    else
      after_baseline="$dir/workspace-after.json"
      python3 "$_GRAPH_DELEGATION_RUNNER_DIR/../../python/graph_changeset.py" baseline \
        --workspace "$child_workspace" --output "$after_baseline" >/dev/null || rc=1
      if [[ "$rc" -eq 0 && "$(jq -r .filesystemIdentity "$baseline")" != "$(jq -r .filesystemIdentity "$after_baseline")" ]]; then
        rc=1
        graph_delegation_runner_log "$workspace" "read-only violation delegation=$did"
      fi
      final_result="$(jq -cn --arg result "$durable_result" '{resultArtifact:$result,readOnlyVerified:true}')"
    fi
  fi
  if [[ "$rc" -eq 0 && "$status" -gt 0 && -s "$durable_result" ]]; then
    graph_delegation_ledger_transition "$workspace" "$ns" "$run_id" "$parent" "$did" succeeded "$attempt" pass '{}' "$final_result"
    graph_delegation_runner_log "$workspace" "succeeded delegation=$did artifact=$durable_result"
    graph_delegation_child_workspace_remove "$dir" "$child_workspace" || true
    return 0
  fi
  graph_delegation_ledger_transition "$workspace" "$ns" "$run_id" "$parent" "$did" failed "$attempt" fail '{}' null "child incomplete, missing result artifact, verification failure, or retry exhaustion"
  graph_delegation_runner_log "$workspace" "failed delegation=$did rc=$rc completed=$status artifact=$result_path"
  return 1
}
