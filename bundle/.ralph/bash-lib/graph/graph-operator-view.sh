#!/usr/bin/env bash
# Pure operator read model (G06-G08) for graph runs.
#
# graph_operator_view_build <workspace> <namespace> <run_id>
#   Read-only. Emits graph-operator-view/v1 JSON on stdout.
#
# graph_operator_view_format_text <view-json> [width]
#   Renders the default action-first status screen. Honors NO_COLOR and
#   COLUMNS when width is omitted.

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  echo "This file is meant to be sourced, not executed." >&2
  exit 1
fi

GRAPH_OPERATOR_VIEW_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if ! declare -F graph_state_run_file >/dev/null 2>&1; then
  # shellcheck source=./graph-state.sh
  source "$GRAPH_OPERATOR_VIEW_SCRIPT_DIR/graph-state.sh"
fi
if ! declare -F graph_heartbeat_classify_run >/dev/null 2>&1; then
  # shellcheck source=./graph-heartbeat.sh
  source "$GRAPH_OPERATOR_VIEW_SCRIPT_DIR/graph-heartbeat.sh"
fi
if ! declare -F graph_operator_request_read >/dev/null 2>&1; then
  # shellcheck source=./graph-operator-records.sh
  source "$GRAPH_OPERATOR_VIEW_SCRIPT_DIR/graph-operator-records.sh"
fi
if ! declare -F graph_preflight_command_text >/dev/null 2>&1; then
  # shellcheck source=./graph-preflight.sh
  source "$GRAPH_OPERATOR_VIEW_SCRIPT_DIR/graph-preflight.sh"
fi
if ! declare -F graph_failure_bound_summary >/dev/null 2>&1; then
  # shellcheck source=./graph-failure-classify.sh
  source "$GRAPH_OPERATOR_VIEW_SCRIPT_DIR/graph-failure-classify.sh"
fi

GRAPH_OPERATOR_VIEW_SCHEMA_VERSION=1

# _graph_operator_view_now_epoch
_graph_operator_view_now_epoch() {
  if [[ -n "${GRAPH_OPERATOR_VIEW_NOW_EPOCH:-}" && "${GRAPH_OPERATOR_VIEW_NOW_EPOCH}" =~ ^[0-9]+$ ]]; then
    printf '%s\n' "$GRAPH_OPERATOR_VIEW_NOW_EPOCH"
    return 0
  fi
  if [[ -n "${GRAPH_STATUS_NOW_EPOCH:-}" && "${GRAPH_STATUS_NOW_EPOCH}" =~ ^[0-9]+$ ]]; then
    printf '%s\n' "$GRAPH_STATUS_NOW_EPOCH"
    return 0
  fi
  date +%s
}

# _graph_operator_view_iso_to_epoch <iso>
_graph_operator_view_iso_to_epoch() {
  local ts="$1"
  [[ -n "$ts" ]] || return 1
  if date -d "$ts" +%s >/dev/null 2>&1; then
    date -d "$ts" +%s
    return 0
  fi
  if date -j -f "%Y-%m-%dT%H:%M:%SZ" "$ts" +%s >/dev/null 2>&1; then
    date -j -f "%Y-%m-%dT%H:%M:%SZ" "$ts" +%s
    return 0
  fi
  return 1
}

# _graph_operator_view_interval_seconds <started> <finished>
_graph_operator_view_interval_seconds() {
  local started="$1" finished="$2"
  [[ -n "$started" && -n "$finished" ]] || return 1
  local diff
  if [[ "${started:0:10}" == "${finished:0:10}" && "${started:11:8}" =~ ^[0-9:]+$ && "${finished:11:8}" =~ ^[0-9:]+$ ]]; then
    local sh sm ss fh fm fs
    sh="${started:11:2}"; sm="${started:14:2}"; ss="${started:17:2}"
    fh="${finished:11:2}"; fm="${finished:14:2}"; fs="${finished:17:2}"
    diff=$(( (10#$fh * 3600 + 10#$fm * 60 + 10#$fs) - (10#$sh * 3600 + 10#$sm * 60 + 10#$ss) ))
    [[ "$diff" -ge 0 ]] || diff=0
    printf '%s\n' "$diff"
    return 0
  fi
  local s f
  s="$(_graph_operator_view_iso_to_epoch "$started")" || return 1
  f="$(_graph_operator_view_iso_to_epoch "$finished")" || return 1
  diff=$(( f - s ))
  [[ "$diff" -ge 0 ]] || diff=0
  printf '%s\n' "$diff"
}

# _graph_operator_view_epoch_to_iso <epoch>
_graph_operator_view_epoch_to_iso() {
  local epoch="$1"
  [[ "$epoch" =~ ^[0-9]+$ ]] || return 1
  if date -u -d "@$epoch" +"%Y-%m-%dT%H:%M:%SZ" >/dev/null 2>&1; then
    date -u -d "@$epoch" +"%Y-%m-%dT%H:%M:%SZ"
    return 0
  fi
  if date -u -r "$epoch" +"%Y-%m-%dT%H:%M:%SZ" >/dev/null 2>&1; then
    date -u -r "$epoch" +"%Y-%m-%dT%H:%M:%SZ"
    return 0
  fi
  return 1
}

# _graph_operator_view_width
# Terminal width for wrapping. Defaults to 80.
_graph_operator_view_width() {
  local w="${1:-}"
  if [[ -z "$w" ]]; then
    w="${COLUMNS:-80}"
  fi
  if [[ ! "$w" =~ ^[0-9]+$ ]] || [[ "$w" -lt 40 ]]; then
    w=80
  fi
  printf '%s\n' "$w"
}

# _graph_operator_view_argv_json <arg>...
# Build a JSON array of argv tokens.
_graph_operator_view_argv_json() {
  local -a argv=("$@")
  local item
  for item in "${argv[@]}"; do
    printf '%s\n' "$item"
  done | jq -R . | jq -sc .
}

# _graph_operator_view_argv_text <arg>...
_graph_operator_view_argv_text() {
  local argv_json
  argv_json="$(_graph_operator_view_argv_json "$@")"
  graph_preflight_command_text "$argv_json"
}

# _graph_operator_view_action_json <label> <mutates> <effect> <arg>...
_graph_operator_view_action_json() {
  local label="$1" mutates="$2" effect="$3"
  shift 3
  local argv_json text
  argv_json="$(_graph_operator_view_argv_json "$@")"
  text="$(_graph_operator_view_argv_text "$@")"
  jq -nc \
    --arg label "$label" \
    --argjson commandArgv "$argv_json" \
    --arg commandText "$text" \
    --argjson mutates "$mutates" \
    --arg effect "$effect" \
    '{label: $label, commandArgv: $commandArgv, commandText: $commandText, mutates: $mutates, effect: $effect}'
}

# _graph_operator_view_bound_cause <text>
_graph_operator_view_bound_cause() {
  local text="${1:-}"
  [[ -n "$text" ]] || { printf '\n'; return 0; }
  if declare -F graph_failure_redact_text >/dev/null 2>&1; then
    text="$(graph_failure_redact_text "$text")"
    text="${text%$'\n'}"
  fi
  if declare -F graph_failure_bound_summary >/dev/null 2>&1; then
    text="$(GRAPH_FAILURE_SUMMARY_MAX="${GRAPH_OPERATOR_VIEW_CAUSE_MAX:-200}" graph_failure_bound_summary "$text")"
    text="${text%$'\n'}"
  fi
  printf '%s\n' "$text"
}

# _graph_operator_view_last_progress_line <run_dir> <agent_log_rel>
_graph_operator_view_last_progress_line() {
  local run_dir="$1" rel="${2:-}"
  local path line="" raw candidate
  [[ -n "$run_dir" && -n "$rel" ]] || return 0
  path="$(graph_logs_resolve "$run_dir" "$rel" 2>/dev/null)" || return 0
  [[ -f "$path" && ! -L "$path" ]] || return 0
  if declare -F _graph_schedule_live_progress_last_safe_line >/dev/null 2>&1; then
    line="$(_graph_schedule_live_progress_last_safe_line "$path")"
    [[ -n "$line" ]] && printf '%s\n' "$line"
    return 0
  fi
  while IFS= read -r raw || [[ -n "$raw" ]]; do
    [[ -n "${raw//[[:space:]]/}" ]] || continue
    case "$raw" in
      [+#|=]*) continue ;;
      ---*) continue ;;
    esac
    [[ "$raw" =~ ^[[:space:]]*\[[0-9]{4}- ]] && continue
    if declare -F _graph_schedule_live_progress_redact >/dev/null 2>&1; then
      candidate="$(_graph_schedule_live_progress_redact "$raw")"
    else
      candidate="$(_graph_operator_view_bound_cause "$raw")"
    fi
    candidate="${candidate%$'\n'}"
    [[ -n "$candidate" ]] && line="$candidate"
  done < <(tail -n 80 "$path" 2>/dev/null || true)
  line="${line%$'\n'}"
  [[ -n "$line" ]] && printf '%s\n' "$line"
}

# _graph_operator_view_unique_attempt_count <node_file>
_graph_operator_view_unique_attempt_count() {
  local node_file="$1"
  jq '[.attempts[]? | .attemptId // empty] | map(select(. != "")) | unique | length' \
    "$node_file" 2>/dev/null || printf '0\n'
}

# _graph_operator_view_latest_attempt <node_file>
_graph_operator_view_latest_attempt() {
  local node_file="$1"
  jq -c '
    reduce (.attempts // [])[] as $a ({};
      (($a.attemptId // "") | if . == "" then "_" else . end) as $id
      | .[$id] = ((.[$id] // {}) + $a)
    ) | [.[]] | sort_by(.startedAt // "") | .[-1] // {}
  ' "$node_file" 2>/dev/null || printf '{}\n'
}

# _graph_operator_view_failure_fields <latest_attempt_json>
# Prints TSV: classification, retryable, cause, offending_paths_json
_graph_operator_view_failure_fields() {
  local attempt="${1:-}"
  # Not "${1:-{}}": bash closes that expansion one brace early, so a provided
  # attempt record arrives with a stray trailing "}" and jq rejects it.
  [[ -n "$attempt" ]] || attempt='{}'
  printf '%s' "$attempt" | jq -r '
    (.stageOutcomeReport.failure // .failure // {}) as $f
    | [
        ($f.classification // ""),
        (if ($f.retryable == true or $f.retryable == "true") then "true"
         elif ($f.retryable == false or $f.retryable == "false") then "false"
         else "" end),
        ($f.summary // $f.cause // .reason // .outcome // ""),
        (($f.offendingPaths // []) | tojson)
      ] | @tsv
  ' 2>/dev/null || printf '\t\t\t[]\n'
}

# _graph_operator_view_request_for_node <run_dir> <node_file> <node_id>
_graph_operator_view_request_for_node() {
  local run_dir="$1" node_file="$2" node_id="$3"
  local rid req_json
  rid="$(jq -r '.operatorRequestId // .attempts[-1].operatorRequestId // empty' "$node_file" 2>/dev/null)" || rid=""
  if [[ -n "$rid" ]]; then
    req_json="$(graph_operator_request_read "$run_dir" "$rid" 2>/dev/null)" || req_json=""
    [[ -n "$req_json" ]] && { printf '%s\n' "$req_json"; return 0; }
  fi
  local req_dir f candidate
  req_dir="$(graph_logs_resolve "$run_dir" "operator/requests" 2>/dev/null)" || return 0
  [[ -d "$req_dir" ]] || return 0
  for f in "$req_dir"/*.json; do
    [[ -f "$f" && ! -L "$f" ]] || continue
    candidate="$(jq -c --arg id "$node_id" 'select(.nodeId == $id)' "$f" 2>/dev/null)" || continue
    [[ -n "$candidate" ]] || continue
    printf '%s\n' "$candidate"
    return 0
  done
}

# graph_operator_view_request_is_actionable <request-json>
# Returns 0 when an awaiting-operator row may offer a respond command.
graph_operator_view_request_is_actionable() {
  local request_json="${1:-}"
  local actionable="" classification="" request_id="" choices_count="" action="" resource=""
  [[ -n "$request_json" ]] || return 1
  actionable="$(printf '%s' "$request_json" | jq -r '.actionable // empty' 2>/dev/null)" || actionable=""
  if [[ "$actionable" == "false" ]]; then
    return 1
  fi
  request_id="$(printf '%s' "$request_json" | jq -r '.requestId // empty' 2>/dev/null)" || request_id=""
  [[ -n "$request_id" ]] || return 1
  classification="$(printf '%s' "$request_json" | jq -r '.classification // empty' 2>/dev/null)" || classification=""
  if [[ "$classification" == "unknown" ]]; then
    return 1
  fi
  action="$(printf '%s' "$request_json" | jq -r '.action // empty' 2>/dev/null)" || action=""
  resource="$(printf '%s' "$request_json" | jq -r '.resource // empty' 2>/dev/null)" || resource=""
  if [[ "$action" == "permission" && "$resource" == "permission" ]]; then
    return 1
  fi
  choices_count="$(printf '%s' "$request_json" | jq '[.choices[]?] | length' 2>/dev/null)" || choices_count=0
  [[ "$choices_count" -gt 0 ]] || return 1
  return 0
}

# _graph_operator_view_next_actions <state> <workspace> <namespace> <run_id> <plan_path> \
#   <node_id> <attempt_id> <request_json> <retryable> <offending_paths_json> <write_scopes_json>
_graph_operator_view_next_actions() {
  local state="$1" workspace="$2" namespace="$3" run_id="$4" plan_path="$5"
  local node_id="$6" attempt_id="$7" request_json="${8:-}" retryable="${9:-}" \
    offending_json="${10:-[]}" scopes_json="${11:-[]}"

  local actions_jsonl="" action scope_hint primary_choice

  case "$state" in
    awaiting-operator)
      local request_id
      request_id="$(printf '%s' "$request_json" | jq -r '.requestId // empty' 2>/dev/null)" || request_id=""
      [[ -n "$request_id" ]] || return 0
      if graph_operator_view_request_is_actionable "$request_json"; then
        primary_choice="$(printf '%s' "$request_json" | jq -r '.choices[0] // "allow-once"' 2>/dev/null)" || primary_choice="allow-once"
        action="$(_graph_operator_view_action_json \
          "Respond to permission request" false "answers the paused permission request for this node" \
          ralph workflow actions respond "$run_id" "$request_id" --decision "$primary_choice")"
      else
        action="$(_graph_operator_view_action_json \
          "Inspect pending permission request" false "shows the request details and currently safe decisions before responding" \
          ralph workflow actions list "$run_id")"
      fi
      actions_jsonl="$action"
      ;;
    needs-plan-repair)
      scope_hint="$(printf '%s' "$offending_json" | jq -r 'if length > 0 then .[0] else empty end' 2>/dev/null)" || scope_hint=""
      if [[ -z "$scope_hint" ]]; then
        scope_hint="$(printf '%s' "$scopes_json" | jq -r 'if length > 0 then .[0] else empty end' 2>/dev/null)" || scope_hint=""
      fi
      if [[ -n "$scope_hint" && -n "$plan_path" ]]; then
        action="$(_graph_operator_view_action_json \
          "Edit plan scope: $scope_hint" true "widens the named write scope in the plan file" \
          "$plan_path")"
        actions_jsonl="$action"
      fi
      if [[ -n "$plan_path" ]]; then
        action="$(_graph_operator_view_action_json \
          "Preview successor run (dry-run)" false "shows what a repaired successor run would reuse" \
          bash .ralph/graph-run.sh successor --from "$run_id" --namespace "$namespace" --plan "$plan_path" --dry-run)"
        [[ -n "$actions_jsonl" ]] && actions_jsonl="${actions_jsonl}"$'\n'"$action" || actions_jsonl="$action"
      fi
      ;;
    stale)
      action="$(_graph_operator_view_action_json \
        "Recover stale run" true "interrupts orphan attempts and resets eligible nodes" \
        ralph workflow recover "$run_id")"
      actions_jsonl="$action"
      ;;
    unknown)
      # Owner liveness is ambiguous; recover refuses until health is provable.
      ;;
    failed|cancelled)
      if [[ "$retryable" == "true" && -n "$plan_path" ]]; then
        action="$(_graph_operator_view_action_json \
          "Resume failed run" true "retries eligible failed nodes in this run" \
          ralph workflow resume "$run_id")"
        actions_jsonl="$action"
      else
        local -a logs_argv=(ralph workflow logs "$run_id" --stage "$node_id")
        local attempt_number=""
        if [[ "$attempt_id" =~ __([0-9]+)$ ]]; then
          attempt_number="${BASH_REMATCH[1]}"
        elif [[ "$attempt_id" =~ ^[0-9]+$ ]]; then
          attempt_number="$attempt_id"
        fi
        [[ -n "$attempt_number" ]] && logs_argv+=(--attempt "$attempt_number")
        action="$(_graph_operator_view_action_json \
          "Inspect failure log" false "shows the agent and supervisor transcript for this failed attempt" \
          "${logs_argv[@]}")"
        actions_jsonl="$action"
      fi
      ;;
    running)
      local -a follow_argv=(ralph workflow watch "$run_id")
      action="$(_graph_operator_view_action_json \
        "Follow agent log" false "streams live agent output for this node" \
        "${follow_argv[@]}")"
      actions_jsonl="$action"
      ;;
  esac

  if [[ -n "$actions_jsonl" ]]; then
    printf '%s\n' "$actions_jsonl" | jq -s .
  else
    printf '[]\n'
  fi
}

# _graph_operator_view_node_item <workspace> <namespace> <run_id> <run_dir> <graph_file> \
#   <node_id> <display_state> <owner_health> <run_status> <plan_path>
_graph_operator_view_node_item() {
  local workspace="$1" namespace="$2" run_id="$3" run_dir="$4" graph_file="$5"
  local node_id="$6" display_state="$7" owner_health="$8" run_status="$9" plan_path="${10:-}"

  local node_file ntype runtime model node_state attempt_json attempt_id attempt_num
  local started finished elapsed cause resources_json paths_json log_paths_json progress
  local request_json classification retryable failure_fields scopes_json

  node_file="$(graph_state_node_file "$workspace" "$namespace" "$run_id" "$node_id" 2>/dev/null)" || return 0
  [[ -f "$node_file" ]] || return 0

  ntype="$(jq -r --arg id "$node_id" '.nodes[] | select(.id == $id) | .type // "agent"' "$graph_file" 2>/dev/null)" || ntype="agent"
  runtime="$(jq -r --arg id "$node_id" '.nodes[] | select(.id == $id) | .stage.runtime // ""' "$graph_file" 2>/dev/null)" || runtime=""
  model="$(jq -r --arg id "$node_id" '.nodes[] | select(.id == $id) | .stage.model // ""' "$graph_file" 2>/dev/null)" || model=""
  node_state="$(jq -r '.status // "pending"' "$node_file" 2>/dev/null)" || node_state="pending"
  [[ -n "$display_state" ]] && node_state="$display_state"

  attempt_json="$(_graph_operator_view_latest_attempt "$node_file")"
  attempt_id="$(printf '%s' "$attempt_json" | jq -r '.attemptId // empty' 2>/dev/null)" || attempt_id=""
  attempt_num="$(_graph_operator_view_unique_attempt_count "$node_file")"
  started="$(printf '%s' "$attempt_json" | jq -r '.startedAt // empty' 2>/dev/null)" || started=""
  finished="$(printf '%s' "$attempt_json" | jq -r '.finishedAt // empty' 2>/dev/null)" || finished=""

  if [[ "$node_state" == "running" || "$node_state" == "retry-wait" ]]; then
    finished=""
  fi
  local now_iso
  if [[ -z "$finished" && -n "$started" ]]; then
    now_iso="$(_graph_operator_view_epoch_to_iso "$(_graph_operator_view_now_epoch)")" || now_iso=""
    elapsed="$(_graph_operator_view_interval_seconds "$started" "${finished:-$now_iso}")" 2>/dev/null || elapsed=0
  elif [[ -n "$started" && -n "$finished" ]]; then
    elapsed="$(_graph_operator_view_interval_seconds "$started" "$finished")" 2>/dev/null || elapsed=0
  else
    elapsed=0
  fi
  [[ "$elapsed" =~ ^[0-9]+$ ]] || elapsed=0

  failure_fields="$(_graph_operator_view_failure_fields "$attempt_json")"
  classification="" retryable="" cause="" paths_json='[]'
  IFS=$'\t' read -r classification retryable cause paths_json <<< "$failure_fields"
  [[ -n "$paths_json" ]] || paths_json='[]'
  printf '%s' "$paths_json" | jq -e . >/dev/null 2>&1 || paths_json='[]'
  cause="$(_graph_operator_view_bound_cause "$cause")"
  cause="${cause%$'\n'}"
  if [[ -z "$cause" || "$cause" == "null" ]]; then
    cause="$(_graph_operator_view_bound_cause "$(printf '%s' "$attempt_json" | jq -r '.reason // .outcome // ""' 2>/dev/null)")"
    cause="${cause%$'\n'}"
  fi

  scopes_json="$(jq -c '.writeScopes // .attempts[-1].writeScopes // []' "$node_file" 2>/dev/null)" || scopes_json='[]'

  request_json="$(_graph_operator_view_request_for_node "$run_dir" "$node_file" "$node_id")"
  if [[ "$node_state" == "awaiting-operator" && -n "$request_json" ]]; then
    local req_reason req_resource
    req_reason="$(printf '%s' "$request_json" | jq -r '.reason // empty' 2>/dev/null)" || req_reason=""
    req_resource="$(printf '%s' "$request_json" | jq -r '.resource // empty' 2>/dev/null)" || req_resource=""
    [[ -n "$req_reason" ]] && cause="$(_graph_operator_view_bound_cause "$req_reason")" && cause="${cause%$'\n'}"
    resources_json="$(printf '%s' "$request_json" | jq -c '[.resource // empty, .action // empty] | map(select(. != ""))' 2>/dev/null)" || resources_json='[]'
    [[ "$resources_json" != "[]" ]] || resources_json="$(jq -nc --arg r "$req_resource" 'if $r == "" then [] else [$r] end')"
    paths_json='[]'
  else
    resources_json='[]'
    [[ -n "$paths_json" && "$paths_json" != "[]" ]] || paths_json="$scopes_json"
  fi

  log_paths_json="$(printf '%s' "$attempt_json" | jq -c '.logPaths // {}' 2>/dev/null)" || log_paths_json='{}'
  progress="$(_graph_operator_view_last_progress_line "$run_dir" "$(printf '%s' "$log_paths_json" | jq -r '.agent // empty' 2>/dev/null)")"
  progress="${progress%$'\n'}"

  if [[ "$node_state" == "running" && "$owner_health" == "stale" && "$run_status" == "running" ]]; then
    node_state="stale"
  elif [[ "$node_state" == "running" && "$owner_health" == "unknown" && "$run_status" == "running" ]]; then
    node_state="unknown"
  fi

  if [[ "$retryable" != "true" && -n "$classification" ]]; then
    if declare -F graph_failure_retryable >/dev/null 2>&1; then
      retryable="$(graph_failure_retryable "$classification")"
      retryable="${retryable%$'\n'}"
    fi
  fi

  local actions_json
  actions_json="$(_graph_operator_view_next_actions \
    "$node_state" "$workspace" "$namespace" "$run_id" "$plan_path" \
    "$node_id" "$attempt_id" "$request_json" "$retryable" "$paths_json" "$scopes_json")"

  [[ -n "$paths_json" ]] || paths_json='[]'
  [[ -n "$resources_json" ]] || resources_json='[]'
  [[ -n "$scopes_json" ]] || scopes_json='[]'
  [[ -n "$log_paths_json" ]] || log_paths_json='{}'
  [[ -n "$actions_json" ]] || actions_json='[]'
  printf '%s' "$paths_json" | jq -e . >/dev/null 2>&1 || paths_json='[]'
  printf '%s' "$resources_json" | jq -e . >/dev/null 2>&1 || resources_json='[]'
  printf '%s' "$log_paths_json" | jq -e . >/dev/null 2>&1 || log_paths_json='{}'
  printf '%s' "$actions_json" | jq -e . >/dev/null 2>&1 || actions_json='[]'

  jq -nc \
    --arg nodeId "$node_id" \
    --arg type "$ntype" \
    --arg state "$node_state" \
    --arg runtime "${runtime:--}" \
    --arg model "${model:--}" \
    --argjson attempt "$attempt_num" \
    --argjson elapsedSeconds "$elapsed" \
    --arg cause "$cause" \
    --argjson resources "$resources_json" \
    --argjson offendingPaths "$paths_json" \
    --argjson logPaths "$log_paths_json" \
    --arg lastProgressLine "$progress" \
    --argjson nextActions "$actions_json" \
    '{
      nodeId: $nodeId,
      type: $type,
      state: $state,
      runtime: (if $runtime == "" or $runtime == "-" then null else $runtime end),
      model: (if $model == "" or $model == "-" then null else $model end),
      attempt: $attempt,
      elapsedSeconds: $elapsedSeconds,
      cause: (if $cause == "" then null else $cause end),
      resources: $resources,
      offendingPaths: $offendingPaths,
      logPaths: $logPaths,
      lastProgressLine: (if $lastProgressLine == "" then null else $lastProgressLine end),
      nextActions: $nextActions
    }'
}

# graph_operator_view_build <workspace> <namespace> <run_id>
graph_operator_view_build() {
  local workspace="$1" namespace="$2" run_id="$3"
  if [[ -z "$workspace" || -z "$namespace" || -z "$run_id" ]]; then
    echo "Error: graph_operator_view_build requires workspace, namespace, run_id" >&2
    return 1
  fi
  command -v jq >/dev/null 2>&1 || {
    echo "Error: jq is required for graph operator view" >&2
    return 1
  }

  local run_file graph_file nodes_dir run_dir
  run_file="$(graph_state_run_file "$workspace" "$namespace" "$run_id")" || return 1
  graph_file="$(graph_state_graph_file "$workspace" "$namespace" "$run_id")" || return 1
  nodes_dir="$(graph_state_nodes_dir "$workspace" "$namespace" "$run_id")" || return 1
  run_dir="$(dirname "$run_file")"

  local run_status started_at plan_path owner_health
  run_status="$(jq -r '.status // "unknown"' "$run_file")"
  started_at="$(jq -r '.startedAt // ""' "$run_file")"
  plan_path="$(jq -r '.planPath // ""' "$run_file")"
  owner_health="$(graph_heartbeat_classify_run "$workspace" "$namespace" "$run_id")" || owner_health="unknown"
  case "$run_status" in
    succeeded|failed|cancelled) owner_health="terminal" ;;
  esac

  local node_ids items_jsonl="" nid node_state item_json
  node_ids="$(jq -r '.nodes[].id // empty' "$graph_file" 2>/dev/null)"

  local n_succeeded=0 n_failed=0 n_cancelled=0 n_pending=0 n_blocked=0 n_running=0
  while IFS= read -r nid || [[ -n "$nid" ]]; do
    [[ -z "$nid" ]] && continue
    local node_file
    node_file="$(graph_state_node_file "$workspace" "$namespace" "$run_id" "$nid" 2>/dev/null)" || continue
    node_state="pending"
    if [[ -f "$node_file" ]]; then
      node_state="$(jq -r '.status // "pending"' "$node_file" 2>/dev/null)" || node_state="pending"
    fi
    case "$node_state" in
      succeeded) n_succeeded=$((n_succeeded + 1)) ;;
      failed) n_failed=$((n_failed + 1)) ;;
      cancelled) n_cancelled=$((n_cancelled + 1)) ;;
      blocked) n_blocked=$((n_blocked + 1)) ;;
      running|retry-wait) n_running=$((n_running + 1)) ;;
      pending|ready) n_pending=$((n_pending + 1)) ;;
    esac

    case "$node_state" in
      awaiting-operator|needs-plan-repair|failed|cancelled|blocked|running|retry-wait)
        item_json="$(_graph_operator_view_node_item \
          "$workspace" "$namespace" "$run_id" "$run_dir" "$graph_file" \
          "$nid" "$node_state" "$owner_health" "$run_status" "$plan_path")"
        [[ -n "$item_json" ]] || continue
        [[ -z "$items_jsonl" ]] && items_jsonl="$item_json" || items_jsonl="${items_jsonl}"$'\n'"$item_json"
        ;;
    esac
  done <<< "$node_ids"

  local stale_run_item="" unknown_run_item=""
  if [[ "$run_status" == "running" && "$owner_health" == "stale" ]]; then
    local stale_actions
    stale_actions="$(_graph_operator_view_next_actions \
      stale "$workspace" "$namespace" "$run_id" "$plan_path" "" "" "" "" "" "[]" "[]")"
    stale_run_item="$(jq -nc \
      --arg state "stale" \
      --arg cause "supervisor process is stale or missing" \
      --argjson nextActions "$stale_actions" \
      '{
        nodeId: null,
        type: "run",
        state: $state,
        runtime: null,
        model: null,
        attempt: 0,
        elapsedSeconds: 0,
        cause: $cause,
        resources: [],
        offendingPaths: [],
        logPaths: {},
        lastProgressLine: null,
        nextActions: $nextActions
      }')"
    [[ -z "$items_jsonl" ]] && items_jsonl="$stale_run_item" || items_jsonl="${stale_run_item}"$'\n'"$items_jsonl"
  elif [[ "$run_status" == "running" && "$owner_health" == "unknown" ]]; then
    unknown_run_item="$(jq -nc \
      --arg state "unknown" \
      --arg cause "supervisor liveness cannot be proved (owner health is unknown)" \
      '{
        nodeId: null,
        type: "run",
        state: $state,
        runtime: null,
        model: null,
        attempt: 0,
        elapsedSeconds: 0,
        cause: $cause,
        resources: [],
        offendingPaths: [],
        logPaths: {},
        lastProgressLine: null,
        nextActions: []
      }')"
    [[ -z "$items_jsonl" ]] && items_jsonl="$unknown_run_item" || items_jsonl="${unknown_run_item}"$'\n'"$items_jsonl"
  fi

  local all_items attention_json active_json next_actions_json
  if [[ -n "$items_jsonl" ]]; then
    all_items="$(printf '%s\n' "$items_jsonl" | jq -s .)"
  else
    all_items='[]'
  fi

  attention_json="$(printf '%s' "$all_items" | jq '
    def rank:
      if .state == "awaiting-operator" then 1
      elif .state == "needs-plan-repair" then 2
      elif .state == "stale" or .state == "unknown" then 3
      elif .state == "failed" or .state == "cancelled" then 4
      elif .state == "blocked" then 6
      else 99 end;
    [.[] | select(.state != "running")]
    | sort_by(rank, (.nodeId // ""))
  ')"

  active_json="$(printf '%s' "$all_items" | jq '[.[] | select(.state == "running")]')"

  next_actions_json="$(printf '%s' "$attention_json $active_json" | jq -s '
    (.[0] + .[1])
    | [.[].nextActions[]?]
    | unique_by(.commandText)
  ')"

  jq -nc \
    --arg schema "graph-operator-view/v1" \
    --argjson schemaVersion "$GRAPH_OPERATOR_VIEW_SCHEMA_VERSION" \
    --arg runId "$run_id" \
    --arg namespace "$namespace" \
    --arg status "$run_status" \
    --arg ownerHealth "$owner_health" \
    --arg startedAt "$started_at" \
    --arg planPath "$plan_path" \
    --argjson attention "$attention_json" \
    --argjson active "$active_json" \
    --argjson nextActions "$next_actions_json" \
    --argjson succeeded "$n_succeeded" \
    --argjson failed "$n_failed" \
    --argjson cancelled "$n_cancelled" \
    --argjson pending "$n_pending" \
    --argjson blocked "$n_blocked" \
    '{
      schema: $schema,
      schemaVersion: $schemaVersion,
      run: {
        runId: $runId,
        namespace: $namespace,
        status: $status,
        ownerHealth: $ownerHealth,
        planPath: $planPath,
        startedAt: $startedAt
      },
      attention: $attention,
      active: $active,
      completed: {succeeded: $succeeded, failed: $failed, cancelled: $cancelled},
      pending: {count: $pending, blocked: $blocked},
      nextActions: $nextActions
    }'
}

# _graph_operator_view_fmt_elapsed <seconds>
_graph_operator_view_fmt_elapsed() {
  local sec="${1:-0}"
  [[ "$sec" =~ ^[0-9]+$ ]] || sec=0
  local h m s
  h=$(( sec / 3600 )); m=$(( (sec % 3600) / 60 )); s=$(( sec % 60 ))
  printf '%02d:%02d:%02d' "$h" "$m" "$s"
}

# _graph_operator_view_print_wrapped <width> <indent> <prefix> <text>
_graph_operator_view_print_wrapped() {
  local width="$1" indent="$2" prefix="$3" text="$4"
  local usable line chunk
  usable=$((width - indent - ${#prefix}))
  [[ "$usable" -lt 20 ]] && usable=20
  line="$text"
  local first=1
  while [[ -n "$line" ]]; do
    if [[ "${#line}" -le "$usable" ]]; then
      if [[ "$first" -eq 1 ]]; then
        printf '%*s%s%s\n' "$indent" '' "$prefix" "$line"
      else
        printf '%*s%s\n' "$indent" '' "$line"
      fi
      break
    fi
    chunk="${line:0:$usable}"
    if [[ "$first" -eq 1 ]]; then
      printf '%*s%s%s\n' "$indent" '' "$prefix" "$chunk"
      first=0
    else
      printf '%*s%s\n' "$indent" '' "$chunk"
    fi
    line="${line:$usable}"
  done
}

# _graph_operator_view_print_item <width> <index> <item-json>
_graph_operator_view_print_item() {
  local width="$1" idx="$2" item="$3"
  local node_id state runtime model attempt elapsed cause resource log_path progress action
  node_id="$(printf '%s' "$item" | jq -r '.nodeId // "run"')"
  state="$(printf '%s' "$item" | jq -r '.state')"
  runtime="$(printf '%s' "$item" | jq -r '.runtime // ""')"
  model="$(printf '%s' "$item" | jq -r '.model // ""')"
  attempt="$(printf '%s' "$item" | jq -r '.attempt // 0')"
  elapsed="$(_graph_operator_view_fmt_elapsed "$(printf '%s' "$item" | jq -r '.elapsedSeconds // 0')")"
  cause="$(printf '%s' "$item" | jq -r '.cause // ""')"
  resource="$(printf '%s' "$item" | jq -r '
    if .state == "awaiting-operator" then
      [.resources[]?] | map(select(. != "")) | unique | join(", ")
    else
      [.offendingPaths[]?] | map(select(. != "")) | unique | join(", ")
    end
  ')"
  log_path="$(printf '%s' "$item" | jq -r '.logPaths.agent // .logPaths.runner // ""')"
  progress="$(printf '%s' "$item" | jq -r '.lastProgressLine // ""')"
  action="$(printf '%s' "$item" | jq -r '.nextActions[0].commandText // ""')"

  local headline=""
  if [[ "$node_id" == "run" || "$node_id" == "null" ]]; then
    headline="[$idx] run  $state"
  else
    headline="[$idx] $node_id"
    [[ -n "$runtime" && "$runtime" != "null" ]] && headline+="  $runtime"
    [[ "$attempt" != "0" ]] && headline+="  attempt $attempt"
    [[ -n "$elapsed" && "$elapsed" != "00:00:00" ]] && headline+="  $elapsed"
    headline+="  ($state)"
  fi
  printf '%s\n' "$headline"
  [[ -n "$cause" && "$cause" != "null" ]] && _graph_operator_view_print_wrapped "$width" 2 "  cause: " "$cause"
  [[ -n "$resource" ]] && printf '%*s%s%s\n' 2 '' "  resource: " "$resource"
  [[ -n "$log_path" && "$log_path" != "null" ]] && printf '%*s%s%s\n' 2 '' "  log: " "$log_path"
  [[ -n "$progress" && "$progress" != "null" ]] && _graph_operator_view_print_wrapped "$width" 2 "  progress: " "$progress"
  # Commands are data, not prose. Hard-wrapping can split a flag or join two
  # argv tokens when copied from a narrow terminal. Emit one logical line and
  # let the terminal perform visual wrapping without changing the bytes.
  [[ -n "$action" ]] && printf '%*s%s%s\n' 2 '' "  next: " "$action"
  printf '\n'
}

# graph_operator_view_item_for_node <view-json> <node-id>
# Prints the attention/active item for one node, or nothing.
graph_operator_view_item_for_node() {
  local view="${1:-}" node_id="$2"
  [[ -n "$view" && -n "$node_id" ]] || return 1
  printf '%s' "$view" | jq -c --arg id "$node_id" '
    (.attention + .active)
    | map(select(.nodeId == $id))
    | .[0] // empty
  ' 2>/dev/null
}

# graph_operator_view_format_logs_context <view-json> <node-id> [stream]
# Compact read-model header printed before a log stream (stderr).
graph_operator_view_format_logs_context() {
  local view="${1:-}" node_id="$2" stream="${3:-agent}"
  local item="" state="" cause="" progress="" action="" width
  [[ -n "$view" && -n "$node_id" ]] || return 1
  printf '%s' "$view" | jq -e . >/dev/null 2>&1 || return 1
  width="$(_graph_operator_view_width)"
  item="$(graph_operator_view_item_for_node "$view" "$node_id" 2>/dev/null || true)"
  if [[ -z "$item" || "$item" == "null" || "$item" == "{}" ]]; then
    printf '# graph logs  node=%s  stream=%s\n---\n' "$node_id" "$stream"
    return 0
  fi
  state="$(printf '%s' "$item" | jq -r '.state // ""')"
  cause="$(printf '%s' "$item" | jq -r '.cause // ""')"
  progress="$(printf '%s' "$item" | jq -r '.lastProgressLine // ""')"
  action="$(printf '%s' "$item" | jq -r '.nextActions[0].commandText // ""')"
  printf '# graph logs  node=%s  state=%s  stream=%s\n' "$node_id" "$state" "$stream"
  [[ -n "$cause" && "$cause" != "null" ]] && _graph_operator_view_print_wrapped "$width" 0 "  cause: " "$cause"
  [[ -n "$progress" && "$progress" != "null" ]] && _graph_operator_view_print_wrapped "$width" 0 "  progress: " "$progress"
  [[ -n "$action" ]] && _graph_operator_view_print_wrapped "$width" 0 "  next: " "$action"
  printf '%s\n' '---'
}

# graph_operator_view_format_attach_snapshot <view-json> [width]
# Same action-first screen as default status; attach and status share it.
graph_operator_view_format_attach_snapshot() {
  graph_operator_view_format_text "${1:-}" "${2:-}"
}

# graph_operator_view_format_text <view-json> [width]
graph_operator_view_format_text() {
  local view="${1:-}" width
  width="$(_graph_operator_view_width "${2:-}")"
  [[ -n "$view" ]] || return 1
  printf '%s' "$view" | jq -e . >/dev/null 2>&1 || return 1

  local run_id namespace run_status owner_health plan_path started_at
  run_id="$(printf '%s' "$view" | jq -r '.run.runId // ""')"
  namespace="$(printf '%s' "$view" | jq -r '.run.namespace // ""')"
  run_status="$(printf '%s' "$view" | jq -r '.run.status // ""')"
  owner_health="$(printf '%s' "$view" | jq -r '.run.ownerHealth // ""')"
  plan_path="$(printf '%s' "$view" | jq -r '.run.planPath // ""')"
  started_at="$(printf '%s' "$view" | jq -r '.run.startedAt // ""')"

  printf '# graph status  run=%s  namespace=%s  status=%s  owner-health=%s\n' \
    "$run_id" "$namespace" "$run_status" "$owner_health"
  [[ -n "$plan_path" && "$plan_path" != "null" ]] && printf '# plan: %s\n' "$plan_path"
  [[ -n "$started_at" && "$started_at" != "null" ]] && printf '# started: %s\n' "$started_at"
  printf '\n'

  local attention_count active_count idx item
  attention_count="$(printf '%s' "$view" | jq '.attention | length')"
  active_count="$(printf '%s' "$view" | jq '.active | length')"
  idx=0

  if [[ "$attention_count" -gt 0 ]]; then
    printf '== NEEDS ATTENTION ==\n\n'
    while IFS= read -r item; do
      [[ -z "$item" ]] && continue
      idx=$((idx + 1))
      _graph_operator_view_print_item "$width" "$idx" "$item"
    done < <(printf '%s' "$view" | jq -c '.attention[]')
  fi

  if [[ "$active_count" -gt 0 ]]; then
    printf '== ACTIVE ==\n\n'
    while IFS= read -r item; do
      [[ -z "$item" ]] && continue
      idx=$((idx + 1))
      _graph_operator_view_print_item "$width" "$idx" "$item"
    done < <(printf '%s' "$view" | jq -c '.active[]')
  fi

  local succ fail cancel pend blocked
  succ="$(printf '%s' "$view" | jq -r '.completed.succeeded // 0')"
  fail="$(printf '%s' "$view" | jq -r '.completed.failed // 0')"
  cancel="$(printf '%s' "$view" | jq -r '.completed.cancelled // 0')"
  pend="$(printf '%s' "$view" | jq -r '.pending.count // 0')"
  blocked="$(printf '%s' "$view" | jq -r '.pending.blocked // 0')"

  printf '== COMPLETION ==\n'
  printf '  succeeded: %s  failed: %s  cancelled: %s\n\n' "$succ" "$fail" "$cancel"

  printf '== PENDING ==\n'
  if [[ "$blocked" != "0" ]]; then
    printf '  untouched: %s pending (%s blocked); use --details for full node table\n' "$pend" "$blocked"
  else
    printf '  untouched: %s pending; use --details for full node table\n' "$pend"
  fi
}
