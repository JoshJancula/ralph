#!/usr/bin/env bash

if [[ -n "${RALPH_RUN_PLAN_MANIFEST_LOADED:-}" ]]; then
  return
fi
RALPH_RUN_PLAN_MANIFEST_LOADED=1

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  echo "This file is meant to be sourced, not executed." >&2
  exit 1
fi

ralph_run_plan_manifest_relative_path() {
  local state_root="${RALPH_PLAN_WORKSPACE_ROOT:-}" path="${1:-}"
  [[ -n "$state_root" && -n "$path" ]] || return 1
  state_root="${state_root%/}"
  case "$path" in
    "$state_root") printf '.' ;;
    "$state_root"/*) printf '%s' "${path#"$state_root"/}" ;;
    *) return 1 ;;
  esac
}

ralph_run_plan_write_manifest() {
  [[ -z "${RALPH_GRAPH_NODE_LOG_DIR:-}" ]] || return 0
  local state_root="${RALPH_PLAN_WORKSPACE_ROOT:-}" run_id="${RALPH_PROCESS_RUN_ID:-}"
  local plan_key="${RALPH_PLAN_KEY:-${RALPH_ARTIFACT_NS:-}}"
  [[ -n "$state_root" && -n "$run_id" && -n "$plan_key" ]] || return 0

  local runs_dir run_dir
  runs_dir="$state_root/logs/$plan_key/runs"
  run_dir="$runs_dir/$run_id"
  local manifest="$run_dir/run-manifest.json" tmp files='[]'
  mkdir -p "$run_dir" || return 1
  [[ -f "$manifest" ]] && return 0

  local log_dir_rel run_dir_rel session_dir_rel tool_results_dir_rel runtime_config_dir_rel artifacts_dir_rel process_run_dir_rel
  log_dir_rel="$(ralph_run_plan_manifest_relative_path "${RALPH_LOG_DIR:-$state_root/logs/$plan_key}")" || return 1
  run_dir_rel="$(ralph_run_plan_manifest_relative_path "$run_dir")" || return 1
  session_dir_rel="$(ralph_run_plan_manifest_relative_path "${RALPH_SESSION_DIR:-$state_root/sessions/$plan_key}")" || session_dir_rel=""
  tool_results_dir_rel="$(ralph_run_plan_manifest_relative_path "$state_root/tool-results/$plan_key")" || tool_results_dir_rel=""
  runtime_config_dir_rel="$(ralph_run_plan_manifest_relative_path "$state_root/runtime-config/$plan_key")" || runtime_config_dir_rel=""
  artifacts_dir_rel="$(ralph_run_plan_manifest_relative_path "$state_root/artifacts/${RALPH_ARTIFACT_NS:-$plan_key}")" || artifacts_dir_rel=""
  process_run_dir_rel="$(ralph_run_plan_manifest_relative_path "${RALPH_PROCESS_RUN_DIR:-}")" || process_run_dir_rel=""

  local path rel
  for path in "$RALPH_LOG_DIR/plan-usage-summary.json" "$RALPH_LOG_DIR/invocation-usage.json"; do
    [[ -f "$path" ]] || continue
    rel="$(ralph_run_plan_manifest_relative_path "$path")" || continue
    files="$(jq -c --arg path "$rel" --arg role usage --arg tier plan '. + [{path:$path,role:$role,tier:$tier}]' <<<"$files")"
  done

  tmp="$(mktemp "$run_dir/.run-manifest.XXXXXX")" || return 1
  jq -n \
    --arg run_id "$run_id" --arg plan_key "$plan_key" --arg artifact_ns "${RALPH_ARTIFACT_NS:-$plan_key}" \
    --arg plan_path "${PLAN_PATH:-}" --arg runtime "${RUNTIME:-}" --arg model "${SELECTED_MODEL:-}" \
    --arg status "${EXIT_STATUS:-incomplete}" --arg started_at "${_plan_started_at:-}" --arg ended_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --arg workflow_run_id "${RALPH_WORKFLOW_RUN_ID:-}" --arg graph_run_id "${RALPH_GRAPH_RUN_ID:-}" --arg graph_namespace "${RALPH_GRAPH_NAMESPACE:-}" --arg stage_id "${RALPH_STAGE_ID:-}" \
    --arg log_dir "$log_dir_rel" --arg run_dir "$run_dir_rel" --arg session_dir "$session_dir_rel" --arg tool_results_dir "$tool_results_dir_rel" --arg runtime_config_dir "$runtime_config_dir_rel" --arg artifacts_dir "$artifacts_dir_rel" --arg process_run_dir "$process_run_dir_rel" \
    --argjson iterations "${total_invocations:-0}" --argjson files "$files" \
    '{schema_version:1,kind:"ralph_run_manifest",run_kind:"plan",run_id:$run_id,plan_key:$plan_key,artifact_ns:$artifact_ns,plan_path:$plan_path,runtime:$runtime,model:$model,status:$status,started_at:$started_at,ended_at:$ended_at,iterations:$iterations,parent:{workflow_run_id:($workflow_run_id|if .=="" then null else . end),graph_run_id:($graph_run_id|if .=="" then null else . end),graph_namespace:($graph_namespace|if .=="" then null else . end),stage_id:($stage_id|if .=="" then null else . end)},paths:{log_dir:$log_dir,run_dir:$run_dir,session_dir:$session_dir,tool_results_dir:$tool_results_dir,runtime_config_dir:$runtime_config_dir,artifacts_dir:$artifacts_dir,process_run_dir:$process_run_dir},files:$files}' >"$tmp" || { rm -f "$tmp"; return 1; }
  mv -f "$tmp" "$manifest" || { rm -f "$tmp"; return 1; }
  jq -cn --arg run_id "$run_id" --arg path "$run_dir_rel/run-manifest.json" --arg status "${EXIT_STATUS:-incomplete}" '{run_id:$run_id,path:$path,status:$status}' >>"$runs_dir/index.jsonl"
}
