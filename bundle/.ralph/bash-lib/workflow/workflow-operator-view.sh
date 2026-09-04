#!/usr/bin/env bash
# Read-only workflow run status for `ralph workflow status` and `ralph workflow watch`.
#
# Loads outer registry metadata, projects engine stages from Dependency or
# Sequential ledgers, normalizes blockers through workflow-diagnose.sh, and
# renders one safe next action. Never mutates, adopts, recovers, or persists
# normalized outer state.

if [[ -n "${RALPH_WORKFLOW_OPERATOR_VIEW_LOADED:-}" ]]; then
  return 0 2>/dev/null || true
fi
RALPH_WORKFLOW_OPERATOR_VIEW_LOADED=1

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  echo "This file is meant to be sourced, not executed." >&2
  exit 1
fi

_WORKFLOW_OPVIEW_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_WORKFLOW_OPVIEW_PYTHON_DIR="$(cd "$_WORKFLOW_OPVIEW_SCRIPT_DIR/../../python" && pwd)"

if ! declare -F workflow_state_read >/dev/null 2>&1; then
  # shellcheck source=./workflow-state.sh
  source "$_WORKFLOW_OPVIEW_SCRIPT_DIR/workflow-state.sh"
fi

if ! declare -F workflow_diagnose_dependency >/dev/null 2>&1; then
  # shellcheck source=./workflow-diagnose.sh
  source "$_WORKFLOW_OPVIEW_SCRIPT_DIR/workflow-diagnose.sh"
fi

if ! declare -F workflow_dep_project_stages >/dev/null 2>&1; then
  # shellcheck source=./workflow-engine-dependency.sh
  source "$_WORKFLOW_OPVIEW_SCRIPT_DIR/workflow-engine-dependency.sh"
fi

if ! declare -F workflow_seq_project_stages >/dev/null 2>&1; then
  # shellcheck source=./workflow-engine-sequential.sh
  source "$_WORKFLOW_OPVIEW_SCRIPT_DIR/workflow-engine-sequential.sh"
fi

if ! declare -F workflow_action_request_display_state >/dev/null 2>&1; then
  # shellcheck source=./workflow-actions.sh
  source "$_WORKFLOW_OPVIEW_SCRIPT_DIR/workflow-actions.sh"
fi

# workflow_operator_view_next_action_text <nextAction-json|null>
workflow_operator_view_next_action_text() {
  local raw="${1:-null}"
  if [[ -z "$raw" || "$raw" == "null" ]]; then
    return 0
  fi
  printf '%s' "$raw" | jq -r '
    if . == null then ""
    elif (.argv | type) == "array" then (.argv | join(" "))
    else (.label // "")
    end
  '
}

# workflow_operator_view_run_summary <outer-run-json>
# Compact run object for status JSON (includes inputPlan when present).
workflow_operator_view_run_summary() {
  local outer="${1:-}"
  printf '%s' "$outer" | jq -c '{
    runId,
    workflowId,
    mode,
    entryKind,
    task,
    taskProvenance,
    sourcePath,
    sourceKind,
    state,
    inputPath,
    inputPlan: (.inputPlan // null),
    createdAt,
    updatedAt
  }'
}

# _workflow_operator_view_seq_approval_fields <orch-path> <stage-id>
_workflow_operator_view_seq_approval_fields() {
  local orch_path="$1" stage_id="$2"
  [[ -f "$orch_path" ]] || return 1
  jq -c --arg id "$stage_id" '
    (.stages // [])[]
    | select(.id == $id)
    | {
        question: (.question // ""),
        changesTarget: (.changesTarget // "")
      }
  ' "$orch_path" 2>/dev/null
}

# _workflow_operator_view_dep_approval_fields <graph-path> <node-id>
_workflow_operator_view_dep_approval_fields() {
  local graph_path="$1" node_id="$2"
  workflow_dep_approval_stage_fields "$graph_path" "$node_id" 2>/dev/null || return 1
}

# _workflow_operator_view_enrich_stage <registry-run> <stage-json> <mode> <defs-path>
# Adds approval display fields; plan-backed stages pass through unchanged.
_workflow_operator_view_enrich_stage() {
  local registry_run="$1" stage_json="$2" mode="$3" defs_path="${4:-}"
  local stage_id blocker request_id kind approval_fields request_json state_label
  local plan_source_kind is_approval=0 request_question=""

  stage_id="$(printf '%s' "$stage_json" | jq -r '.id // empty')"
  blocker="$(printf '%s' "$stage_json" | jq -c '.blocker // null')"
  request_id="$(printf '%s' "$blocker" | jq -r '.requestId // empty')"
  kind="$(printf '%s' "$blocker" | jq -r '.kind // empty')"
  plan_source_kind="$(printf '%s' "$stage_json" | jq -r '.planSourceKind // empty')"

  approval_fields="null"
  if [[ -n "$defs_path" && -f "$defs_path" && -n "$stage_id" ]]; then
    case "$mode" in
      dependency)
        approval_fields="$(_workflow_operator_view_dep_approval_fields "$defs_path" "$stage_id" 2>/dev/null || true)"
        ;;
      sequential)
        approval_fields="$(_workflow_operator_view_seq_approval_fields "$defs_path" "$stage_id" 2>/dev/null || true)"
        ;;
    esac
    [[ -n "$approval_fields" ]] || approval_fields="null"
  fi
  if [[ "$kind" == "approval" ]]; then
    is_approval=1
  elif [[ -n "$approval_fields" && "$approval_fields" != "null" ]]; then
    if [[ -n "$(printf '%s' "$approval_fields" | jq -r '.question // empty')" ]]; then
      is_approval=1
    fi
  fi

  if [[ "$is_approval" -eq 1 ]]; then
    request_json="null"
    state_label="none"
    if [[ -n "$request_id" ]]; then
      state_label="$(workflow_action_request_display_state "$registry_run" "$request_id" 2>/dev/null || echo none)"
      request_json="$(workflow_action_request_read "$registry_run" "$request_id" 2>/dev/null || echo null)"
    fi
    jq -cn \
      --argjson base "$stage_json" \
      --argjson approval "$approval_fields" \
      --argjson request "$request_json" \
      --arg requestState "$state_label" \
      --arg requestId "$request_id" \
      '($base
        | .planPath = null
        | .planRunId = null
        | .planSourceKind = null
        | .planSourceStageId = null
        | .originalPlanPath = null
        | .sourcePlanPath = null
        | .controlPlanPath = null
        | .currentTodoId = null
        | .completedTodos = 0
        | .totalTodos = 0
      ) + {
        stageKind: "approval",
        approval: (
          if $approval != null then $approval
          elif ($request | type) == "object" then {
            question: ($request.question // ""),
            changesTarget: ($request.changesTarget // "")
          }
          else {question: "", changesTarget: ""}
          end
        ),
        requestId: (if $requestId == "" then null else $requestId end),
        requestState: (if $requestState == "none" then null else $requestState end),
        evidence: (
          if ($request | type) == "object" then ($request.evidence // [])
          else []
          end
        )
      }'
    return 0
  fi

  # Input questions are operator-facing public status data.  Read the
  # create-once request record rather than exposing an engine-specific ledger,
  # then apply the same display redaction used by watch event records.
  if [[ "$kind" == "input" && -n "$request_id" ]]; then
    request_json="$(workflow_action_request_read "$registry_run" "$request_id" 2>/dev/null || echo null)"
    request_question="$(printf '%s' "$request_json" | jq -r '.question // empty' 2>/dev/null || true)"
    if [[ -n "$request_question" ]]; then
      request_question="$(workflow_action_redact_for_display "$request_question" 2>/dev/null || printf '[REDACTED]')"
    fi
    state_label="$(workflow_action_request_display_state "$registry_run" "$request_id" 2>/dev/null || echo none)"
    jq -cn \
      --argjson base "$stage_json" \
      --arg question "$request_question" \
      --arg requestState "$state_label" \
      '($base
        + {stageKind: "executable"}
        + {requestQuestion: (if $question == "" then null else $question end)}
        + {requestState: (if $requestState == "none" then null else $requestState end)})'
    return 0
  fi

  if [[ -n "$plan_source_kind" ]]; then
    printf '%s' "$stage_json" | jq -c '. + {stageKind: "plan-backed"}'
    return 0
  fi

  printf '%s' "$stage_json" | jq -c '. + {stageKind: "executable"}'
}

# _workflow_operator_view_defs_path <state-root> <run-id> <mode> <outer-json>
_workflow_operator_view_defs_path() {
  local state_root="$1" run_id="$2" mode="$3" outer="$4"
  local registry_run engine_path namespace input_path graph_path

  registry_run="$(workflow_state_run_dir "$state_root" "$run_id" 2>/dev/null || true)"
  case "$mode" in
    dependency)
      namespace="$(printf '%s' "$outer" | jq -r '.engine.namespace // empty')"
      if [[ -n "$namespace" ]]; then
        graph_path="$(graph_state_graph_file "$state_root" "$namespace" "$run_id" 2>/dev/null || true)"
        if [[ -n "$graph_path" && -f "$graph_path" ]]; then
          printf '%s\n' "$graph_path"
          return 0
        fi
      fi
      if [[ -n "$registry_run" && -f "$registry_run/engine-graph.json" ]]; then
        printf '%s\n' "$registry_run/engine-graph.json"
        return 0
      fi
      ;;
    sequential)
      input_path="$(printf '%s' "$outer" | jq -r '.inputPath // empty')"
      if [[ -n "$input_path" && -f "$input_path" ]]; then
        printf '%s\n' "$input_path"
        return 0
      fi
      if [[ -n "$registry_run" && -f "$registry_run/input.orch.json" ]]; then
        printf '%s\n' "$registry_run/input.orch.json"
        return 0
      fi
      ;;
  esac
  return 1
}

# workflow_operator_view_load <state-root> <run-id>
# Prints status JSON: {schemaVersion,run,stages,diagnosis,nextAction}
workflow_operator_view_load() {
  local state_root="${1:-}" run_id="${2:-}"
  local outer registry_run mode engine stages_json observation diagnosis next_action
  local verdict_path feedback_json
  local defs_path enriched='[]' stage line needs_dynamic_enrichment=0

  [[ -n "$state_root" && -n "$run_id" ]] || {
    echo "Error: workflow_operator_view_load requires state-root and run-id" >&2
    return 1
  }
  command -v jq >/dev/null 2>&1 || {
    echo "Error: jq is required for workflow status" >&2
    return 1
  }

  if ! outer="$(workflow_state_read "$state_root" "$run_id" 2>/dev/null)"; then
    echo "Error: workflow run not found: $run_id" >&2
    return 1
  fi

  registry_run="$(workflow_state_run_dir "$state_root" "$run_id")" || return 1
  mode="$(printf '%s' "$outer" | jq -r '.mode // empty')"
  defs_path="$(_workflow_operator_view_defs_path "$state_root" "$run_id" "$mode" "$outer" 2>/dev/null || true)"

  case "$mode" in
    dependency)
      engine="dependency"
      namespace="$(printf '%s' "$outer" | jq -r '.engine.namespace // empty')"
      if [[ -n "$namespace" ]] && [[ -d "$(workflow_dep_engine_state_path "$state_root" "$namespace" "$run_id" 2>/dev/null || true)" ]]; then
        local dependency_snapshot
        dependency_snapshot="$(workflow_dep_project_snapshot "$state_root" "$namespace" "$run_id" "$outer")" || dependency_snapshot='{}'
        stages_json="$(printf '%s' "$dependency_snapshot" | jq -c '.stages // []')"
        observation="$(printf '%s' "$dependency_snapshot" | jq -c '.observation // {}')"
        # Diagnosis needs the public dependency and artifact projection for
        # actionable terminal-review exhaustion. Keep the engine snapshot's
        # retained observation contract unchanged and join those fields here in
        # one jq pass from the already-loaded stage rows.
        observation="$(jq -cn \
          --argjson observation "$observation" \
          --argjson stages "$stages_json" '
            (reduce $stages[] as $stage ({}; .[$stage.id] = $stage)) as $byId
            | $observation
            | .nodes = [(.nodes // [])[] as $node
                | $node + {
                    dependencies: ($byId[$node.id].dependencies // []),
                    artifacts: ($byId[$node.id].artifacts // [])
                  }]
          ')" || return 1
      else
        stages_json='[]'
        observation="$(jq -cn \
          --arg runId "$run_id" \
          --arg runStatus "$(printf '%s' "$outer" | jq -r '.state // "queued"')" \
          '{runId:$runId, runStatus:$runStatus, ownerClass:"none", nodes:[]}')"
      fi
      diagnosis="$(workflow_diagnose_dependency "$registry_run" "$observation")" || return 1
      ;;
    sequential)
      engine="sequential"
      if workflow_seq_engine_active "$registry_run" 2>/dev/null; then
        local sequential_snapshot
        sequential_snapshot="$(workflow_seq_project_snapshot "$state_root" "$run_id")" || sequential_snapshot='{}'
        stages_json="$(printf '%s' "$sequential_snapshot" | jq -c '.stages // []')"
        observation="$(printf '%s' "$sequential_snapshot" | jq -c '.observation // {}')"
      else
        stages_json='[]'
        observation="$(jq -cn \
          --arg runId "$run_id" \
          --arg runStatus "$(printf '%s' "$outer" | jq -r '.state // "queued"')" \
          '{runId:$runId, runStatus:$runStatus, ownerClass:"none", nodes:[]}')"
      fi
      diagnosis="$(workflow_diagnose_sequential "$registry_run" "$observation")" || return 1
      ;;
    *)
      echo "Error: unsupported workflow mode for status: ${mode:-?}" >&2
      return 1
      ;;
  esac

  # A terminal review verdict is the most useful explanation of exhausted
  # rework. It is already a supervisor-validated artifact; copy its bounded
  # feedback strings into diagnosis evidence so every renderer (TTY, plain,
  # JSON) can explain the concrete findings without reading engine internals.
  if [[ "$(printf '%s' "$diagnosis" | jq -r '.reasonCode // empty')" == "loop-exhausted" ]]; then
    verdict_path="$(printf '%s' "$stages_json" | jq -r \
      --arg id "$(printf '%s' "$diagnosis" | jq -r '.stageId // empty')" \
      '.[]? | select(.id == $id) | .artifacts[0] // empty')"
    if [[ -n "$verdict_path" && -f "$verdict_path" && ! -L "$verdict_path" ]]; then
      feedback_json="$(jq -c '[.feedback[]? | select(type == "string" and length > 0)]' \
        "$verdict_path" 2>/dev/null || true)"
      if [[ -n "$feedback_json" && "$feedback_json" != "[]" ]]; then
        diagnosis="$(printf '%s' "$diagnosis" | jq -c --argjson feedback "$feedback_json" '
          .evidence = ((.evidence // [])
            + ($feedback | map("requested change: " + .))
            | unique)
        ')"
      fi
    fi
  fi

  # Most workflow stages need only the plan-backed/executable label. Do that
  # projection in one jq pass. The older per-stage path remains for approval
  # and input stages because those must join create-once operator records.
  if printf '%s' "$stages_json" | jq -e '
      any(.[]?; ((.blocker.kind // "") == "approval" or (.blocker.kind // "") == "input"))
    ' >/dev/null 2>&1; then
    needs_dynamic_enrichment=1
  elif [[ -n "$defs_path" && -f "$defs_path" ]]; then
    case "$mode" in
      dependency)
        jq -e 'any(.nodes[]?; ((.type // "") == "approval" or (.stage.type // "") == "approval"))' \
          "$defs_path" >/dev/null 2>&1 && needs_dynamic_enrichment=1
        ;;
      sequential)
        jq -e 'any(.stages[]?; ((.type // "") == "approval"))' \
          "$defs_path" >/dev/null 2>&1 && needs_dynamic_enrichment=1
        ;;
    esac
  fi

  if [[ "$needs_dynamic_enrichment" -eq 0 ]]; then
    enriched="$(printf '%s' "$stages_json" | jq -c '
      map(. + {stageKind: (if (.planSourceKind // "") != "" then "plan-backed" else "executable" end)})
    ')"
  else
    enriched='[]'
    while IFS= read -r line || [[ -n "$line" ]]; do
      [[ -n "$line" ]] || continue
      enriched="$(jq -cn \
        --argjson arr "$enriched" \
        --argjson item "$(_workflow_operator_view_enrich_stage "$registry_run" "$line" "$mode" "$defs_path")" \
        '$arr + [$item]')"
    done < <(printf '%s' "$stages_json" | jq -c '.[]?')
  fi

  next_action="$(printf '%s' "$diagnosis" | jq -c '.nextAction // null')"
  jq -cn \
    --argjson run "$(workflow_operator_view_run_summary "$outer")" \
    --argjson stages "$enriched" \
    --argjson diagnosis "$diagnosis" \
    --argjson nextAction "$next_action" \
    '{
      schemaVersion: 1,
      run: $run,
      stages: $stages,
      diagnosis: $diagnosis,
      nextAction: $nextAction
    }'
}

# ---------------------------------------------------------------------------
# Standardized operator presentation (outcome-first, one action, no namespace)
# ---------------------------------------------------------------------------

WORKFLOW_OPERATOR_COLOR_READY="${WORKFLOW_OPERATOR_COLOR_READY:-0}"

# workflow_operator_color_enabled
# Honors NO_COLOR, RALPH_WORKFLOW_NO_COLOR, and TTY (stdout). Tests may set
# WORKFLOW_OPERATOR_FORCE_COLOR=1 with a pseudo-TTY.
workflow_operator_color_enabled() {
  if [[ "${WORKFLOW_OPERATOR_FORCE_COLOR:-0}" == "1" ]]; then
    return 0
  fi
  [[ -t 1 && "${NO_COLOR+x}" != x && "${RALPH_WORKFLOW_NO_COLOR:-0}" != "1" ]]
}

workflow_operator_color_init() {
  [[ "$WORKFLOW_OPERATOR_COLOR_READY" == "1" ]] && return 0
  if workflow_operator_color_enabled; then
    WORKFLOW_OP_Y=$'\033[33m'
    WORKFLOW_OP_G=$'\033[32m'
    WORKFLOW_OP_C=$'\033[36m'
    WORKFLOW_OP_BOLD=$'\033[1m'
    WORKFLOW_OP_DIM=$'\033[2m'
    WORKFLOW_OP_RST=$'\033[0m'
  else
    WORKFLOW_OP_Y="" WORKFLOW_OP_G="" WORKFLOW_OP_C=""
    WORKFLOW_OP_BOLD="" WORKFLOW_OP_DIM="" WORKFLOW_OP_RST=""
  fi
  WORKFLOW_OPERATOR_COLOR_READY=1
}

# workflow_operator_print <stream> <label> <value> [emphasis=0]
workflow_operator_print() {
  local stream="$1" label="$2" value="$3" emphasis="${4:-0}"
  workflow_operator_color_init
  if [[ "$emphasis" == "1" && -n "$WORKFLOW_OP_BOLD" ]]; then
    if [[ "$stream" == "stderr" ]]; then
      printf '%b%s:%b %s\n' "$WORKFLOW_OP_BOLD" "$label" "$WORKFLOW_OP_RST" "$value" >&2
    else
      printf '%b%s:%b %s\n' "$WORKFLOW_OP_BOLD" "$label" "$WORKFLOW_OP_RST" "$value"
    fi
    return 0
  fi
  if [[ "$stream" == "stderr" ]]; then
    printf '%s: %s\n' "$label" "$value" >&2
  else
    printf '%s: %s\n' "$label" "$value"
  fi
}

# _workflow_operator_stage_by_id <status-json> <stage-id>
_workflow_operator_stage_by_id() {
  local status="$1" stage_id="$2"
  printf '%s' "$status" | jq -c --arg id "$stage_id" '.stages[]? | select(.id == $id)' 2>/dev/null
}

# _workflow_operator_primary_stage <status-json>
_workflow_operator_primary_stage() {
  local status="$1" stage_id stage_json
  stage_id="$(printf '%s' "$status" | jq -r '.diagnosis.stageId // empty')"
  if [[ -n "$stage_id" ]]; then
    stage_json="$(_workflow_operator_stage_by_id "$status" "$stage_id")"
    [[ -n "$stage_json" ]] && { printf '%s' "$stage_json"; return 0; }
  fi
  printf '%s' "$status" | jq -c '
    [.stages[]? | select(.state == "running" or .state == "waiting" or .state == "blocked" or .state == "stale")]
    | .[0] // empty
  ' 2>/dev/null
}

# _workflow_operator_request_question <stage-json>
_workflow_operator_request_question() {
  local stage_json="$1"
  printf '%s' "$stage_json" | jq -r '.approval.question // .question // empty' 2>/dev/null
}

# _workflow_operator_respond_argv <run-id> <request-id> <kind>
_workflow_operator_respond_argv() {
  local run_id="$1" request_id="$2" kind="$3"
  case "$kind" in
    input) printf 'ralph workflow actions respond %s %s --decision answer --message "<your answer>" --yes' "$run_id" "$request_id" ;;
    approval) printf 'ralph workflow actions respond %s %s --decision approve --yes' "$run_id" "$request_id" ;;
    *) printf 'ralph workflow actions respond %s %s --decision <choice> --yes' "$run_id" "$request_id" ;;
  esac
}

# _workflow_operator_print_plan_paths <stage-json>
_workflow_operator_print_plan_paths() {
  local stage_json="$1"
  local original source control kind producer
  kind="$(printf '%s' "$stage_json" | jq -r '.planSourceKind // empty')"
  producer="$(printf '%s' "$stage_json" | jq -r '.planSourceStageId // empty')"
  original="$(printf '%s' "$stage_json" | jq -r '.originalPlanPath // empty')"
  source="$(printf '%s' "$stage_json" | jq -r '.sourcePlanPath // empty')"
  control="$(printf '%s' "$stage_json" | jq -r '.controlPlanPath // empty')"
  [[ -n "$kind" && "$kind" != "null" ]] && workflow_operator_print stdout "Plan source" "$kind"
  if [[ -n "$producer" && "$producer" != "null" ]]; then
    workflow_operator_print stdout "Plan producer" "$producer"
  elif [[ -n "$kind" && "$kind" != "null" ]]; then
    workflow_operator_print stdout "Plan producer" "null"
  fi
  [[ -n "$original" && "$original" != "null" ]] && workflow_operator_print stdout "Original plan" "$original"
  [[ -n "$source" && "$source" != "null" ]] && workflow_operator_print stdout "Supplied source" "$source"
  [[ -n "$control" && "$control" != "null" ]] && workflow_operator_print stdout "Control plan" "$control"
}

# _workflow_operator_print_handoff <status-json>
_workflow_operator_print_handoff() {
  local status="$1" implement review
  implement="$(printf '%s' "$status" | jq -c '.stages[]? | select(.id == "implement" and .state == "succeeded")' 2>/dev/null)"
  [[ -n "$implement" ]] || return 0
  review="$(printf '%s' "$status" | jq -c '.stages[]? | select(.id == "review")' 2>/dev/null)"
  if [[ -n "$review" ]]; then
    workflow_operator_print stdout "Handoff" "independent review/QA at stage review"
    return 0
  fi
  review="$(printf '%s' "$status" | jq -c '.stages[]? | select(.id == "qa")' 2>/dev/null)"
  [[ -n "$review" ]] && workflow_operator_print stdout "Handoff" "independent QA at stage qa"
}

# _workflow_operator_print_terminal_hold <status-json>
_workflow_operator_print_terminal_hold() {
  local status="$1" wf stage_json stage_id reason
  wf="$(printf '%s' "$status" | jq -r '.run.workflowId // empty')"
  [[ "$wf" == "human-verified-delivery" ]] || return 0
  stage_id="$(printf '%s' "$status" | jq -r '.diagnosis.stageId // empty')"
  reason="$(printf '%s' "$status" | jq -r '.diagnosis.reasonCode // empty')"
  if [[ "$stage_id" == "approve-result" && "$reason" == "human-approval" ]]; then
    workflow_operator_print stdout "Terminal hold" "human-verified success held until result approval at stage approve-result"
    return 0
  fi
  stage_json="$(printf '%s' "$status" | jq -c '.stages[]? | select(.id == "approve-result")' 2>/dev/null)"
  [[ -n "$stage_json" ]] || return 0
  if [[ "$(printf '%s' "$stage_json" | jq -r '.state // empty')" == "waiting" ]]; then
    workflow_operator_print stdout "Terminal hold" "human-verified success held until result approval at stage approve-result"
  fi
}

# workflow_operator_render_status_python <status-json>
# Finite renderer from the shared Python model/theme. Prints to stdout.
workflow_operator_render_status_python() {
  local status="${1:-}"
  local -a py_args=(status)
  command -v python3 >/dev/null 2>&1 || return 1
  [[ -f "$_WORKFLOW_OPVIEW_PYTHON_DIR/workflow_static.py" ]] || return 1
  if [[ -n "${COLUMNS:-}" ]]; then
    py_args+=(--width "$COLUMNS")
  fi
  if [[ "${WORKFLOW_OPERATOR_FORCE_COLOR:-0}" == "1" ]]; then
    py_args+=(--force-color)
    if [[ -n "${WORKFLOW_OPERATOR_COLOR_DEPTH:-}" ]]; then
      py_args+=(--depth "$WORKFLOW_OPERATOR_COLOR_DEPTH")
    fi
  fi
  printf '%s' "$status" | python3 "$_WORKFLOW_OPVIEW_PYTHON_DIR/workflow_static.py" "${py_args[@]}"
}

# workflow_operator_render_status <status-json> [stream=stdout]
# Outcome-first status screen shared by status, watch, and lifecycle previews.
workflow_operator_render_status() {
  local status="${1:-}" stream="${2:-stdout}"
  local rendered=""

  command -v jq >/dev/null 2>&1 || return 1
  [[ -n "$status" ]] || return 1
  printf '%s' "$status" | jq -e 'type == "object"' >/dev/null 2>&1 || return 1

  if rendered="$(workflow_operator_render_status_python "$status" 2>/dev/null)" \
    && [[ -n "$rendered" ]]; then
    if [[ "$stream" == "stderr" ]]; then
      printf '%s\n' "$rendered" >&2
    else
      printf '%s\n' "$rendered"
    fi
    return 0
  fi

  # Fallback when Python is unavailable: keep a concise bash renderer.
  local run_id wf mode entry task prov run_state reason summary stage_id
  local stage_json next_text request_id request_kind retryable verdict verdict_shell reset_target
  local code_stage_json code_stage workspace_mode workspace_path workspace_available changeset changed_count base_revision
  run_id="$(printf '%s' "$status" | jq -r '.run.runId // ""')"
  wf="$(printf '%s' "$status" | jq -r '.run.workflowId // "-"')"
  mode="$(printf '%s' "$status" | jq -r '.run.mode // ""')"
  entry="$(printf '%s' "$status" | jq -r '.run.entryKind // ""')"
  task="$(printf '%s' "$status" | jq -r '.run.task // ""')"
  prov="$(printf '%s' "$status" | jq -r '.run.taskProvenance // ""')"
  run_state="$(printf '%s' "$status" | jq -r '
    if (["succeeded", "failed", "cancelled"] | index(.run.state)) != null
    then .run.state
    else (.diagnosis.state // .run.state // "")
    end')"
  reason="$(printf '%s' "$status" | jq -r '.diagnosis.reasonCode // "none"')"
  summary="$(printf '%s' "$status" | jq -r '.diagnosis.summary // ""')"
  stage_id="$(printf '%s' "$status" | jq -r '.diagnosis.stageId // empty')"
  retryable="$(printf '%s' "$status" | jq -r '.diagnosis.retryable // false')"
  request_kind="$(printf '%s' "$status" | jq -r '.diagnosis.requestKind // empty')"
  request_id="$(printf '%s' "$status" | jq -r '.diagnosis.requestId // empty')"
  stage_json="$(_workflow_operator_primary_stage "$status")"
  workflow_operator_color_init
  workflow_operator_print "$stream" "Outcome" "$run_state ($reason)" 1
  [[ -n "$summary" && "$summary" != "null" ]] && workflow_operator_print "$stream" "Reason" "$summary"
  if [[ -n "$stage_json" && "$stage_json" != "null" && "$stage_json" != "{}" ]]; then
    stage_id="$(printf '%s' "$stage_json" | jq -r '.id // empty')"
    workflow_operator_print "$stream" "Stage" "$stage_id [$(printf '%s' "$stage_json" | jq -r '.state // "?"')]"
    if [[ "$reason" == "loop-exhausted" ]]; then
      verdict="$(printf '%s' "$stage_json" | jq -r '.artifacts[0] // empty')"
      if [[ -n "$verdict" ]]; then
        verdict_shell="$(printf '%s' "$verdict" | jq -Rr @sh)"
        workflow_operator_print "$stream" "Review verdict" "$verdict"
        workflow_operator_print "$stream" "Requested changes" "jq -r '.feedback[]' $verdict_shell"
      fi
    fi
  elif [[ -n "$stage_id" ]]; then
    workflow_operator_print "$stream" "Stage" "$stage_id"
  fi
  next_text="$(workflow_operator_view_next_action_text "$(printf '%s' "$status" | jq -c '.nextAction // null')")"
  if [[ -n "$next_text" ]]; then
    workflow_operator_print "$stream" "Action" "$next_text" 1
  else
    workflow_operator_print "$stream" "Action" "none required"
  fi
  if [[ "$reason" == "loop-exhausted" ]]; then
    reset_target="$(printf '%s' "$status" | jq -r '
      (.nextAction.argv // []) as $argv
      | ($argv | index("--stage")) as $index
      | if $index == null then "" else ($argv[$index + 1] // "") end
    ')"
    if [[ -n "$reset_target" ]]; then
      workflow_operator_print "$stream" "Retry behavior" \
        "reset $reset_target; its next fresh attempt receives $stage_id's final review feedback"
      workflow_operator_print "$stream" "Preview retry" \
        "ralph workflow reset $run_id --stage $reset_target --dry-run"
      workflow_operator_print "$stream" "Continue run" "ralph workflow resume $run_id"
    fi
  fi
  if [[ "$run_state" == "failed" ]]; then
    workflow_operator_print "$stream" "Finish task" \
      "retry this run from the repair stage or generate a handoff report" 1
    code_stage_json=""
    if [[ -n "$reset_target" ]]; then
      code_stage_json="$(printf '%s' "$status" | jq -c --arg id "$reset_target" \
        '.stages[]? | select(.id == $id)' 2>/dev/null)"
    fi
    if [[ -z "$code_stage_json" ]]; then
      code_stage_json="$(printf '%s' "$status" | jq -c \
        '[.stages[]? | select((.workspacePath // "") != "" or (.changesetManifest // "") != "" or ((.changedFiles // []) | length > 0))] | last // empty' \
        2>/dev/null)"
    fi
    if [[ -n "$code_stage_json" && "$code_stage_json" != "null" ]]; then
      code_stage="$(printf '%s' "$code_stage_json" | jq -r '.id // empty')"
      workspace_mode="$(printf '%s' "$code_stage_json" | jq -r '.workspaceMode // empty')"
      workspace_path="$(printf '%s' "$code_stage_json" | jq -r '.workspacePath // empty')"
      workspace_available="$(printf '%s' "$code_stage_json" | jq -r '.workspaceAvailable // false')"
      changeset="$(printf '%s' "$code_stage_json" | jq -r '.changesetManifest // empty')"
      changed_count="$(printf '%s' "$code_stage_json" | jq -r '(.changedFiles // []) | length')"
      base_revision="$(printf '%s' "$code_stage_json" | jq -r '.baseRevision // empty')"
      workflow_operator_print "$stream" "Code stage" "$code_stage"
      [[ -n "$workspace_mode" ]] && workflow_operator_print "$stream" "Workspace" \
        "$workspace_mode ($([[ "$workspace_available" == "true" ]] && printf available || printf 'not available'))"
      [[ -n "$workspace_mode" ]] && workflow_operator_print "$stream" "Git worktree" \
        "$([[ "$workspace_mode" == "worktree" ]] && printf yes || printf no)"
      [[ -n "$workspace_path" ]] && workflow_operator_print "$stream" "Agent workspace" "$workspace_path"
      if [[ -n "$workspace_path" && "$workspace_available" == "true" ]]; then
        workflow_operator_print "$stream" "Open code" "cd $(printf '%s' "$workspace_path" | jq -Rr @sh)"
      fi
      [[ -n "$base_revision" ]] && workflow_operator_print "$stream" "Base revision" "$base_revision"
      [[ -n "$changeset" ]] && workflow_operator_print "$stream" "Changeset" "$changeset"
      [[ "$changed_count" =~ ^[1-9][0-9]*$ ]] && workflow_operator_print "$stream" "Changed files" "$changed_count"
    else
      workflow_operator_print "$stream" "Code location" "not recorded"
    fi
    workflow_operator_print "$stream" "Handoff report" "ralph workflow handoff $run_id"
  fi
  workflow_operator_print "$stream" "Run" "$run_id  Workflow: $wf  Mode: $mode  Entry: $entry ($prov)"
  [[ -n "$task" && "$task" != "null" ]] && workflow_operator_print "$stream" "Task" "$task"
  if [[ "$request_kind" == "input" && "$retryable" == "true" ]]; then
    workflow_operator_print "$stream" "Resume" "ralph workflow resume $run_id"
  fi
  workflow_operator_print "$stream" "Status" "ralph workflow status $run_id"
}

# workflow_operator_render_start <record-json> [stream=stdout]
# record: {runId, workflowId, mode, entryKind, taskProvenance, task, state}
workflow_operator_render_start() {
  local record="${1:-}" stream="${2:-stdout}"
  local run_id wf mode entry prov task state
  [[ -n "$record" ]] || return 1
  run_id="$(printf '%s' "$record" | jq -r '.runId // empty')"
  wf="$(printf '%s' "$record" | jq -r '.workflowId // "-"')"
  mode="$(printf '%s' "$record" | jq -r '.mode // ""')"
  entry="$(printf '%s' "$record" | jq -r '.entryKind // ""')"
  prov="$(printf '%s' "$record" | jq -r '.taskProvenance // ""')"
  task="$(printf '%s' "$record" | jq -r '.task // ""')"
  state="$(printf '%s' "$record" | jq -r '.state // "running"')"
  workflow_operator_color_init
  workflow_operator_print "$stream" "Outcome" "${state:-running} (workflow started)" 1
  if [[ "$stream" == "stderr" ]]; then
    printf 'Run: %s  Workflow: %s  Mode: %s  Entry: %s (%s)\n' "$run_id" "$wf" "$mode" "$entry" "$prov" >&2
    [[ -n "$task" ]] && printf 'Task: %s\n' "$task" >&2
  else
    printf 'Run: %s  Workflow: %s  Mode: %s  Entry: %s (%s)\n' "$run_id" "$wf" "$mode" "$entry" "$prov"
    [[ -n "$task" ]] && printf 'Task: %s\n' "$task"
  fi
  workflow_operator_print "$stream" "Status" "ralph workflow status $run_id"
  workflow_operator_print "$stream" "Logs" "ralph workflow logs $run_id"
  workflow_operator_print "$stream" "Action" "ralph workflow watch $run_id" 1
}

# workflow_operator_render_lifecycle <verb> <record-json> [status-json] [stream=stderr]
# verb: reset|recovered|cancelled|failed|succeeded
workflow_operator_render_lifecycle() {
  local verb="${1:-}" record="${2:-}" status_json="${3:-}" stream="${4:-stderr}"
  local run_id outcome state reason next_text
  [[ -n "$verb" && -n "$record" ]] || return 1
  run_id="$(printf '%s' "$record" | jq -r '.runId // .run.runId // empty')"
  if [[ -n "$status_json" && "$status_json" != "null" && "$status_json" != "{}" ]]; then
    workflow_operator_render_status "$status_json" "$stream"
    return 0
  fi
  state="$(printf '%s' "$record" | jq -r '.state // .outcome // .runState // ""')"
  reason="$(printf '%s' "$record" | jq -r '.reasonCode // "none"')"
  outcome="${state:-$verb}"
  workflow_operator_print "$stream" "Outcome" "$outcome ($reason)" 1
  workflow_operator_print "$stream" "Run" "$run_id"
  next_text="$(workflow_operator_view_next_action_text "$(printf '%s' "$record" | jq -c '.nextAction // null')")"
  workflow_operator_print "$stream" "Status" "ralph workflow status $run_id"
  workflow_operator_print "$stream" "Logs" "ralph workflow logs $run_id"
  if [[ -n "$next_text" ]]; then
    workflow_operator_print "$stream" "Action" "$next_text" 1
  else
    workflow_operator_print "$stream" "Action" "none required"
  fi
}

# workflow_operator_view_format_text <status-json>
workflow_operator_view_format_text() {
  workflow_operator_render_status "${1:-}" stdout
}

# workflow_operator_render_plain_status <status-json>
# Uses the shared Python read model for the noninteractive renderer.  It is
# deliberately separate from the legacy static formatter while the public
# status command is migrated, so status JSON remains the single input contract.
workflow_operator_render_plain_status() {
  local status_json="${1:-}"
  command -v python3 >/dev/null 2>&1 || return 1
  [[ -n "$status_json" ]] || return 1
  printf '%s' "$status_json" | python3 "$_WORKFLOW_OPVIEW_PYTHON_DIR/workflow_plain.py" status
}

# ---------------------------------------------------------------------------
# Watch and logs (read-only; public stage/attempt/stream selectors)
# ---------------------------------------------------------------------------

if ! declare -F ralph_wait >/dev/null 2>&1; then
  # shellcheck source=../ralph-wait.sh
  source "$_WORKFLOW_OPVIEW_SCRIPT_DIR/../ralph-wait.sh"
fi

if ! declare -F graph_logs_print_file >/dev/null 2>&1; then
  # shellcheck source=../graph/graph-logs.sh
  source "$_WORKFLOW_OPVIEW_SCRIPT_DIR/../graph/graph-logs.sh"
fi

# workflow_operator_is_terminal_state <public-state>
workflow_operator_is_terminal_state() {
  case "${1:-}" in
    succeeded|failed|cancelled) return 0 ;;
    *) return 1 ;;
  esac
}

# workflow_operator_redact_log_line <line>
workflow_operator_redact_log_line() {
  local line="${1:-}" max="${WORKFLOW_OPERATOR_LOG_LINE_MAX:-500}"
  # Log/event text is untrusted presentation data.  Removing control bytes
  # keeps the plain watch safe for terminals, CI logs, and screen readers.
  line="${line//$'\033'/}"
  line="${line//$'\r'/ }"
  line="${line//$'\n'/ }"
  line="${line//$'\t'/ }"
  if declare -F graph_operator_text_looks_like_credential >/dev/null 2>&1; then
    if graph_operator_text_looks_like_credential "$line"; then
      printf '[REDACTED]\n'
      return 0
    fi
  fi
  if [[ "${#line}" -gt "$max" ]]; then
    line="${line:0:$max}...[truncated]"
  fi
  printf '%s\n' "$line"
}

# workflow_operator_format_engine_event_line <public-event-json>
workflow_operator_format_engine_event_line() {
  local event="${1:-}" ts stage attempt name new_state details
  ts="$(printf '%s' "$event" | jq -r '.timestamp // ""')"
  stage="$(printf '%s' "$event" | jq -r '.stageId // .nodeId // "-"')"
  attempt="$(printf '%s' "$event" | jq -r '.attemptId // .attempt // empty')"
  name="$(printf '%s' "$event" | jq -r '.event // ""')"
  new_state="$(printf '%s' "$event" | jq -r '.newState // ""')"
  details="$(printf '%s' "$event" | jq -r '.details // {}')"
  if declare -F graph_events_redact_details >/dev/null 2>&1; then
    details="$(graph_events_redact_details "$details")"
  fi
  if [[ -n "$attempt" && "$attempt" != "null" ]]; then
    printf '%s stage=%s attempt=%s event=%s newState=%s\n' \
      "$ts" "$stage" "$attempt" "$name" "$new_state"
  else
    printf '%s stage=%s event=%s newState=%s\n' \
      "$ts" "$stage" "$name" "$new_state"
  fi
}

# _workflow_operator_context_from_status <state-root> <status-json>
# Prints: mode<TAB>registry_run<TAB>engine_dir<TAB>namespace
_workflow_operator_context_from_status() {
  local state_root="$1" status="$2"
  local run_id mode registry_run engine_dir namespace=""
  run_id="$(printf '%s' "$status" | jq -r '.run.runId // empty')"
  mode="$(printf '%s' "$status" | jq -r '.run.mode // empty')"
  registry_run="$(workflow_state_run_dir "$state_root" "$run_id" 2>/dev/null || true)"
  case "$mode" in
    dependency)
      namespace="$(workflow_state_read "$state_root" "$run_id" 2>/dev/null \
        | jq -r '.engine.namespace // empty' || true)"
      engine_dir="$(workflow_dep_engine_state_path "$state_root" "$namespace" "$run_id" 2>/dev/null || true)"
      ;;
    sequential)
      engine_dir="$(workflow_seq_engine_dir "$registry_run" 2>/dev/null || true)"
      ;;
    *)
      engine_dir=""
      ;;
  esac
  printf '%s\t%s\t%s\t%s\n' "$mode" "$registry_run" "${engine_dir:-}" "${namespace:-}"
}

# workflow_operator_collect_event_lines <state-root> <run-id> <mode> <registry-run> <engine-dir> <namespace>
# Prints sorted display lines for engine + action events on stdout.
workflow_operator_collect_event_lines() {
  local state_root="$1" run_id="$2" mode="$3" registry_run="$4" engine_dir="$5" namespace="$6"
  local line public action_rows merged_row display_line

  while IFS= read -r merged_row || [[ -n "$merged_row" ]]; do
    [[ -n "$merged_row" ]] || continue
    if [[ "$(printf '%s' "$merged_row" | jq -r '.source // empty' 2>/dev/null || true)" == "action" ]]; then
      display_line="$(workflow_action_format_event_line "$merged_row" 2>/dev/null || true)"
    else
      display_line="$(workflow_operator_format_engine_event_line "$merged_row" 2>/dev/null || true)"
    fi
    [[ -n "$display_line" ]] && workflow_operator_redact_log_line "$display_line"
  done < <(workflow_operator_merged_events_json "$state_root" "$run_id" "$mode" "$registry_run" "$engine_dir" "$namespace" \
    | jq -c '.[]?')
}

# workflow_operator_merged_events_json <state-root> <run-id> <mode> <registry-run> <engine-dir> <namespace>
workflow_operator_merged_events_json() {
  local state_root="$1" run_id="$2" mode="$3" registry_run="$4" engine_dir="$5" namespace="$6"
  local line engine_rows='[]' action_rows='[]' public

  action_rows="$(workflow_action_synthetic_event_records "$registry_run" 2>/dev/null || printf '[]')"

  case "$mode" in
    dependency)
      while IFS= read -r line || [[ -n "$line" ]]; do
        [[ -n "$line" ]] || continue
        public="$(workflow_dep_project_event "$line" 2>/dev/null || true)"
        [[ -n "$public" ]] || continue
        engine_rows="$(jq -nc --argjson arr "$engine_rows" --argjson item "$public" '$arr + [$item]')"
      done < <(workflow_dep_read_event_lines "$engine_dir" 2>/dev/null || true)
      ;;
    sequential)
      while IFS= read -r line || [[ -n "$line" ]]; do
        [[ -n "$line" ]] || continue
        engine_rows="$(jq -nc --argjson arr "$engine_rows" --argjson item "$line" '$arr + [$item]')"
      done < <(workflow_seq_read_event_lines "$registry_run" 2>/dev/null || true)
      ;;
  esac

  jq -nc --argjson engine "$engine_rows" --argjson action "$action_rows" \
    '($engine + $action) | sort_by(.timestamp, .sequence // 0, .requestId // "", .event // "")'
}

# workflow_operator_follow_interval
workflow_operator_follow_interval() {
  local raw="${RALPH_WORKFLOW_FOLLOW_INTERVAL:-${RALPH_GRAPH_FOLLOW_INTERVAL:-1}}"
  case "$raw" in
    ''|0|0.0) printf '1\n' ;;
    *) printf '%s\n' "$raw" ;;
  esac
}

# workflow_operator_follow_sleep
workflow_operator_follow_sleep() {
  ralph_wait "$(workflow_operator_follow_interval)"
}

# workflow_operator_follow_file_size <path>
workflow_operator_follow_file_size() {
  local path="$1" size=""
  [[ -n "$path" && -f "$path" ]] || return 1
  size="$(stat -c '%s' "$path" 2>/dev/null || stat -f '%z' "$path" 2>/dev/null || true)"
  [[ "$size" =~ ^[0-9]+$ ]] || return 1
  printf '%s\n' "$size"
}

# workflow_operator_follow_emit_lines <path>
# Print newly appended lines from a text file; redact each line.
workflow_operator_follow_emit_lines() {
  local path="$1" size="" new_bytes
  [[ -n "$path" && -f "$path" && ! -L "$path" ]] || return 0
  size="$(workflow_operator_follow_file_size "$path" 2>/dev/null || true)"
  [[ "$size" =~ ^[0-9]+$ ]] || return 0
  if [[ "${WORKFLOW_OP_FOLLOW_OFFSET:-0}" -gt "$size" ]]; then
    WORKFLOW_OP_FOLLOW_OFFSET=0
  fi
  if [[ "$size" -le "${WORKFLOW_OP_FOLLOW_OFFSET:-0}" ]]; then
    WORKFLOW_OP_FOLLOW_OFFSET="$size"
    return 0
  fi
  new_bytes=$((size - WORKFLOW_OP_FOLLOW_OFFSET))
  tail -c "$new_bytes" "$path" 2>/dev/null | while IFS= read -r line || [[ -n "$line" ]]; do
    workflow_operator_redact_log_line "$line"
  done
  WORKFLOW_OP_FOLLOW_OFFSET="$size"
}

# workflow_operator_events_snapshot_file <registry-run>
# Temp snapshot for follow diffing; never stored under the registry run tree.
workflow_operator_events_snapshot_file() {
  local registry_run="$1"
  printf '%s/ralph-workflow-watch-%s-%s.snapshot\n' \
    "${TMPDIR:-/tmp}" "$(basename "$registry_run")" "$$"
}

# workflow_operator_watch_on_signal
workflow_operator_watch_on_signal() {
  WORKFLOW_OP_FOLLOW_INTERRUPTED=1
  rm -f "${WORKFLOW_OP_WATCH_SNAPSHOT:-}" 2>/dev/null || true
}

# workflow_operator_is_watch_idle_state <public-state>
# Terminal outcomes and persisted waits both end a public watch session.
workflow_operator_is_watch_idle_state() {
  # queued/running still advance on their own. stale is deliberately not idle:
  # the supervisor is gone but the run is recoverable, so `ralph workflow
  # recover` from another terminal revives it under this viewer. Everything
  # else -- succeeded, failed, cancelled, waiting, and blocked, the one the
  # previous allow-list missed -- has no supervisor behind it and no recovery
  # path, so polling only reprints the same frame forever. A deny-list on
  # purpose: a diagnosis state added later should stop and show the operator
  # rather than hang the viewer.
  case "${1:-}" in
    queued|running|stale) return 1 ;;
    "") return 1 ;;
    *) return 0 ;;
  esac
}

# workflow_operator_viewer_script
workflow_operator_viewer_script() {
  printf '%s\n' "$_WORKFLOW_OPVIEW_PYTHON_DIR/workflow_viewer.py"
}

# workflow_operator_viewer_ralph_front
workflow_operator_viewer_ralph_front() {
  printf '%s\n' "$(cd "$_WORKFLOW_OPVIEW_SCRIPT_DIR/../.." && pwd)/workflow-ralph-front.sh"
}

# workflow_operator_watch_python <run-id> <plain 0|1>
# Route through the engine-neutral Python viewer. Returns 127 when python3 or
# the viewer module is unavailable so the bash fallback can stream instead.
workflow_operator_watch_python() {
  local run_id="$1" plain="${2:-0}"
  local viewer front
  command -v python3 >/dev/null 2>&1 || return 127
  viewer="$(workflow_operator_viewer_script)"
  front="$(workflow_operator_viewer_ralph_front)"
  [[ -f "$viewer" && -f "$front" ]] || return 127
  local -a argv=(python3 "$viewer" --run-id "$run_id" --command "$front")
  [[ "$plain" == "1" ]] && argv+=(--plain)
  "${argv[@]}"
}

# workflow_operator_watch_bash_fallback <state-root> <run-id>
# Last-resort streaming status when python3 itself is missing. Read-only.
workflow_operator_watch_bash_fallback() {
  local state_root="$1" run_id="$2"
  local status_json run_state frame last_frame="" polls=0
  local max_polls="${RALPH_WORKFLOW_FOLLOW_MAX_POLLS:-}"

  echo "workflow watch: falling back to concise streaming status (python unavailable)" >&2
  if ! status_json="$(workflow_operator_view_load "$state_root" "$run_id")"; then
    return 1
  fi
  run_state="$(printf '%s' "$status_json" | jq -r '.diagnosis.state // .run.state // empty')"
  frame="$(workflow_operator_render_plain_status "$status_json" 2>/dev/null || true)"
  if [[ -z "$frame" ]]; then
    workflow_operator_view_format_text "$status_json"
  else
    printf '%s\n' "$frame"
  fi
  last_frame="$frame"
  if workflow_operator_is_watch_idle_state "$run_state"; then
    return 0
  fi

  WORKFLOW_OP_FOLLOW_INTERRUPTED=0
  trap 'workflow_operator_watch_on_signal' INT TERM
  while [[ "${WORKFLOW_OP_FOLLOW_INTERRUPTED:-0}" -eq 0 ]]; do
    if ! status_json="$(workflow_operator_view_load "$state_root" "$run_id" 2>/dev/null)"; then
      break
    fi
    run_state="$(printf '%s' "$status_json" | jq -r '.diagnosis.state // .run.state // empty')"
    frame="$(workflow_operator_render_plain_status "$status_json" 2>/dev/null || true)"
    if [[ -n "$frame" && "$frame" != "$last_frame" ]]; then
      printf '%s\n' "$frame"
      last_frame="$frame"
    fi
    if workflow_operator_is_watch_idle_state "$run_state"; then
      break
    fi
    polls=$((polls + 1))
    if [[ -n "$max_polls" && "$max_polls" =~ ^[1-9][0-9]*$ && "$polls" -ge "$max_polls" ]]; then
      break
    fi
    workflow_operator_follow_sleep
  done
  trap - INT TERM
  if [[ "${WORKFLOW_OP_FOLLOW_INTERRUPTED:-0}" -eq 1 ]]; then
    return 130
  fi
  return 0
}

# workflow_operator_watch <state-root> <run-id> [plain 0|1]
# Read-only public viewer. Prefers the Python workflow viewer; falls back to
# bash streaming when python3 is absent. Never mutates registry or engine state.
workflow_operator_watch() {
  local state_root="$1" run_id="$2" plain="${3:-0}"
  local rc=0

  # Resolve identity cheaply so missing IDs fail before the viewer process starts.
  if ! workflow_state_read "$state_root" "$run_id" >/dev/null 2>&1; then
    echo "Error: workflow run not found: $run_id" >&2
    return 1
  fi

  if workflow_operator_watch_python "$run_id" "$plain"; then
    return 0
  else
    rc=$?
  fi
  # 127 = python/viewer unavailable; any other code is the viewer's own exit.
  if [[ "$rc" -ne 127 ]]; then
    return "$rc"
  fi
  workflow_operator_watch_bash_fallback "$state_root" "$run_id"
}

# workflow_operator_resolve_logs_target <status-json> <stage-id> <attempt-n>
# Prints: stage_id<TAB>attempt_n on success.
workflow_operator_resolve_logs_target() {
  local status="$1" stage_id="${2:-}" attempt_n="${3:-}"
  local resolved_stage resolved_attempt stage_json

  if [[ -z "$stage_id" ]]; then
    stage_id="$(printf '%s' "$status" | jq -r '.diagnosis.stageId // empty')"
    if [[ -z "$stage_id" ]]; then
      stage_id="$(printf '%s' "$status" | jq -r '
        [.stages[]? | select(.state == "running" or .state == "waiting") | .id] | .[0] // empty
      ')"
    fi
  fi
  if [[ -z "$stage_id" ]]; then
    echo "Error: workflow logs requires --stage <id> when no active stage is evident" >&2
    return 1
  fi

  stage_json="$(printf '%s' "$status" | jq -c --arg id "$stage_id" '.stages[]? | select(.id == $id)' 2>/dev/null || true)"
  if [[ -z "$stage_json" ]]; then
    echo "Error: workflow logs unknown stage: $stage_id" >&2
    return 1
  fi

  if [[ -z "$attempt_n" ]]; then
    attempt_n="$(printf '%s' "$stage_json" | jq -r '.attempt // 1')"
  fi
  if ! [[ "$attempt_n" =~ ^[0-9]+$ ]]; then
    echo "Error: workflow logs --attempt must be a non-negative integer" >&2
    return 1
  fi
  printf '%s\t%s\n' "$stage_id" "$attempt_n"
}

# workflow_operator_stage_is_active <stage-json>
workflow_operator_stage_is_active() {
  local stage_json="$1" state=""
  state="$(printf '%s' "$stage_json" | jq -r '.state // empty')"
  case "$state" in
    running|waiting|queued|blocked|stale) return 0 ;;
    *) return 1 ;;
  esac
}

# workflow_operator_stage_is_running <stage-json>
workflow_operator_stage_is_running() {
  [[ "$(printf '%s' "$1" | jq -r '.state // empty')" == "running" ]]
}

# workflow_operator_logs_print_paths <paths-file> [tail-n]
workflow_operator_logs_print_paths() {
  local paths_file="$1" tail_n="${2:-}" path line
  [[ -f "$paths_file" ]] || return 1
  while IFS= read -r path || [[ -n "$path" ]]; do
    [[ -n "$path" && -f "$path" && ! -L "$path" ]] || continue
    if [[ -n "$tail_n" && "$tail_n" =~ ^[1-9][0-9]*$ ]]; then
      tail -n "$tail_n" "$path" | while IFS= read -r line || [[ -n "$line" ]]; do
        workflow_operator_redact_log_line "$line"
      done
    else
      while IFS= read -r line || [[ -n "$line" ]]; do
        workflow_operator_redact_log_line "$line"
      done <"$path"
    fi
  done <"$paths_file"
}

# workflow_operator_logs <state-root> <run-id> [options...]
# Options: --stage --attempt --stream --tail --follow --no-follow
workflow_operator_logs() {
  local state_root="$1" run_id="$2"
  shift 2
  local stage_id="" attempt_n="" stream="agent" tail_n="${RALPH_WORKFLOW_LOG_TAIL_LINES:-80}"
  local follow=0 follow_explicit=0 arg

  while [[ $# -gt 0 ]]; do
    arg="$1"
    case "$arg" in
      --stage) stage_id="${2:-}"; shift 2 ;;
      --attempt) attempt_n="${2:-}"; shift 2 ;;
      --stream) stream="${2:-}"; shift 2 ;;
      --tail) tail_n="${2:-}"; shift 2 ;;
      --follow) follow=1; follow_explicit=1; shift ;;
      --no-follow) follow=0; follow_explicit=1; shift ;;
      *)
        echo "Error: unknown option for workflow logs: $arg" >&2
        return 2
        ;;
    esac
  done

  workflow_logs_validate_public_stream "$stream" || return 2

  _WORKFLOW_OPVIEW_STATE_ROOT="$state_root"
  local status_json mode registry_run engine_dir namespace
  local resolved_stage resolved_attempt stage_json stage_state paths_tmp paths_found=0
  local node_json run_dir polls=0
  # graph_state_* accepts a project/workspace argument and otherwise derives
  # <workspace>/.ralph-workspace. Here state_root is already the exact durable
  # root, so bind it explicitly or a standalone `workflow logs` process (which
  # has no inherited root env) looks under <state-root>/.ralph-workspace.
  local RALPH_GRAPH_STATE_ROOT="$state_root"

  if ! status_json="$(workflow_operator_view_load "$state_root" "$run_id")"; then
    return 1
  fi

  IFS=$'\t' read -r resolved_stage resolved_attempt \
    < <(workflow_operator_resolve_logs_target "$status_json" "$stage_id" "$attempt_n") || return 1

  stage_json="$(printf '%s' "$status_json" | jq -c --arg id "$resolved_stage" '.stages[]? | select(.id == $id)')"
  stage_state="$(printf '%s' "$stage_json" | jq -r '.state // empty')"
  IFS=$'\t' read -r mode registry_run engine_dir namespace \
    < <(_workflow_operator_context_from_status "$state_root" "$status_json")

  paths_tmp="$(mktemp "${TMPDIR:-/tmp}/wf-logs.XXXXXX")" || return 1
  # shellcheck disable=SC2064
  trap "rm -f '$paths_tmp'" RETURN

  case "$mode" in
    dependency)
      run_dir="$(workflow_dep_engine_state_path "$state_root" "$namespace" "$run_id")" || return 1
      node_json="$(graph_state_read_node "$state_root" "$namespace" "$run_id" "$resolved_stage")" || {
        echo "Error: workflow logs could not read stage '$resolved_stage'" >&2
        return 1
      }
      while IFS= read -r path || [[ -n "$path" ]]; do
        [[ -n "$path" ]] || continue
        printf '%s\n' "$path" >>"$paths_tmp"
        paths_found=1
      done < <(workflow_dep_stage_log_select "$run_dir" "$resolved_stage" "$node_json" "$resolved_attempt" "$stream" 2>/dev/null || true)
      ;;
    sequential)
      while IFS= read -r path || [[ -n "$path" ]]; do
        [[ -n "$path" ]] || continue
        printf '%s\n' "$path" >>"$paths_tmp"
        paths_found=1
      done < <(workflow_seq_stage_log_select "$registry_run" "$resolved_stage" "$resolved_attempt" "$stream" 2>/dev/null || true)
      ;;
    *)
      echo "Error: unsupported workflow mode for logs: ${mode:-?}" >&2
      return 1
      ;;
  esac

  printf '# workflow logs  run=%s  stage=%s  attempt=%s  stream=%s\n' \
    "$run_id" "$resolved_stage" "$resolved_attempt" "$stream" >&2

  if [[ "$paths_found" -eq 0 ]]; then
    if workflow_operator_stage_is_active "$stage_json"; then
      echo "workflow log not found for stream '$stream' (stage is still active)" >&2
      if [[ "$follow" -eq 0 && "$follow_explicit" -eq 0 ]]; then
        return 0
      fi
    else
      echo "Error: workflow log not found for stream '$stream'" >&2
      return 1
    fi
  fi

  if [[ "$follow" -eq 0 && "$follow_explicit" -eq 0 ]] && workflow_operator_stage_is_running "$stage_json"; then
    follow=1
  fi

  if [[ "$follow" -eq 0 ]]; then
    workflow_operator_logs_print_paths "$paths_tmp" "$tail_n"
    return 0
  fi

  if [[ "$paths_found" -eq 1 ]] && ! workflow_operator_stage_is_active "$stage_json"; then
    workflow_operator_logs_print_paths "$paths_tmp" "$tail_n"
    return 0
  fi

  WORKFLOW_OP_FOLLOW_INTERRUPTED=0
  WORKFLOW_OP_FOLLOW_OFFSET=0
  trap 'WORKFLOW_OP_FOLLOW_INTERRUPTED=1' INT TERM

  workflow_operator_logs_print_paths "$paths_tmp" "$tail_n"
  while [[ "${WORKFLOW_OP_FOLLOW_INTERRUPTED:-0}" -eq 0 ]]; do
    : >"$paths_tmp"
    paths_found=0
    case "$mode" in
      dependency)
        node_json="$(graph_state_read_node "$state_root" "$namespace" "$run_id" "$resolved_stage" 2>/dev/null || true)"
        while IFS= read -r path || [[ -n "$path" ]]; do
          [[ -n "$path" ]] || continue
          printf '%s\n' "$path" >>"$paths_tmp"
          paths_found=1
        done < <(workflow_dep_stage_log_select "$run_dir" "$resolved_stage" "$node_json" "$resolved_attempt" "$stream" 2>/dev/null || true)
        ;;
      sequential)
        while IFS= read -r path || [[ -n "$path" ]]; do
          [[ -n "$path" ]] || continue
          printf '%s\n' "$path" >>"$paths_tmp"
          paths_found=1
        done < <(workflow_seq_stage_log_select "$registry_run" "$resolved_stage" "$resolved_attempt" "$stream" 2>/dev/null || true)
        ;;
    esac
    if [[ "$paths_found" -eq 1 ]]; then
      while IFS= read -r path || [[ -n "$path" ]]; do
        [[ -n "$path" && -f "$path" ]] || continue
        workflow_operator_follow_emit_lines "$path"
      done <"$paths_tmp"
    fi
    if ! status_json="$(workflow_operator_view_load "$state_root" "$run_id" 2>/dev/null)"; then
      break
    fi
    stage_json="$(printf '%s' "$status_json" | jq -c --arg id "$resolved_stage" '.stages[]? | select(.id == $id)')"
    if ! workflow_operator_stage_is_active "$stage_json"; then
      break
    fi
    polls=$((polls + 1))
    if [[ -n "${RALPH_WORKFLOW_FOLLOW_MAX_POLLS:-}" && "${RALPH_WORKFLOW_FOLLOW_MAX_POLLS}" =~ ^[1-9][0-9]*$ \
      && "$polls" -ge "${RALPH_WORKFLOW_FOLLOW_MAX_POLLS}" ]]; then
      break
    fi
    workflow_operator_follow_sleep
  done

  trap - INT TERM
  if [[ "${WORKFLOW_OP_FOLLOW_INTERRUPTED:-0}" -eq 1 ]]; then
    return 130
  fi
  return 0
}

# Format a reset plan JSON for operator preview (stderr-friendly text).
workflow_reset_preview_text() {
  local plan_json="${1:-}"
  printf '%s' "$plan_json" | jq -r '
    "Operation: reset",
    "Run: \(.runId // "")",
    (if .mode then "Mode: \(.mode)" else empty end),
    (if .selectAll then "Selection: all executable/planner stages" else "Selection: \(.stageId // "")" end),
    "Archive: \(.archivePath // "")",
    (if .humanFeedback then
      "Human feedback: \(.humanFeedback.requestId // "") -> \(.humanFeedback.changesTarget // "")"
      + (if (.humanFeedback.message // "") != "" then " (\(.humanFeedback.message))" else "" end)
     else empty end),
    (if .evaluatorFeedback then
      "Review feedback: \(.evaluatorFeedback.sourceStageId) -> \(.evaluatorFeedback.targetStageId)",
      "Verdict: \(.evaluatorFeedback.artifactPath)",
      "Effect: the target next attempt receives this final changes-required verdict"
     else empty end),
    "Invalidated requests: \((.invalidatedRequests // []) | length)",
    "",
    "Stages:",
    (.stages // [] | map(
      "  \(.stageId)\t\(.priorState // "?")\t\(.action // "?")"
      + (if .planAction then " plan=\(.planAction)" else "" end)
      + (if .role then " role=\(.role)" else "" end)
      + (if .nextAttempt then " nextAttempt=\(.nextAttempt)" else "" end)
    ) | .[])
  '
}

# Format a recover plan JSON for operator preview (stderr-friendly text).
# Optional second argument is status JSON with diagnosis/nextAction.
workflow_recover_preview_text() {
  local plan_json="${1:-}" status_json="${2:-}"
  local diagnosis_block=""
  if [[ -n "$status_json" ]] && printf '%s' "$status_json" | jq -e 'type == "object"' >/dev/null 2>&1; then
    diagnosis_block="$(printf '%s' "$status_json" | jq -r '
      "",
      "Diagnosis:",
      "  state=\(.diagnosis.state // "?") reason=\(.diagnosis.reasonCode // "none")",
      (if (.diagnosis.summary // "") != "" then "  summary=\(.diagnosis.summary)" else empty end),
      (if (.diagnosis.stageId // "") != "" then "  stage=\(.diagnosis.stageId)" else empty end),
      (if .diagnosis.retryable == true then "  retryable=true"
       elif .diagnosis.retryable == false then "  retryable=false"
       else empty end)
    ' 2>/dev/null || true)"
  fi
  printf '%s' "$plan_json" | jq -r '
    "Operation: recover",
    "Run: \(.runId // "")",
    (if .mode then "Mode: \(.mode)" else empty end),
    "Outcome: \(.outcome // "?")",
    (if .ownerClass then "Owner class: \(.ownerClass)" else empty end),
    (if .runState then "Run state: \(.runState)"
     elif .engineState then "Engine state: \(.engineState)"
     elif .graphStatus then "Graph status: \(.graphStatus)"
     else empty end),
    (if .mutated == false then "Mutation: none (preview or unchanged)"
     elif .mutated == true then "Mutation: yes"
     elif .dryRun == true then "Mutation: none (dry-run)"
     else empty end),
    (if (.outstanding.requestId // null) != null then
      "Outstanding action: \(.outstanding.kind // "?") \(.outstanding.requestId)"
     else "Outstanding action: none" end),
    (if (.retryableStages // []) | length > 0 then
      "Retryable stages: \([.retryableStages[].stageId] | join(", "))"
     elif .wouldMarkStale != null then
      "Would mark stale: \(.wouldMarkStale)"
     else empty end),
    (if .nextAction != null and (.nextAction.argv | type) == "array" then
      "Next action: \(.nextAction.argv | join(" "))"
     else empty end),
    (if .preserves then "Preserves: \(.preserves | join(", "))" else empty end),
    (if .note then "Note: \(.note)" else empty end)
  '
  if [[ -n "$diagnosis_block" ]]; then
    printf '%s\n' "$diagnosis_block"
  fi
}

# Format a cancel plan JSON for operator preview (stderr-friendly text).
# Optional second argument is status JSON with diagnosis/action state.
workflow_cancel_preview_text() {
  local plan_json="${1:-}" status_json="${2:-}"
  local diagnosis_block=""
  if [[ -n "$status_json" ]] && printf '%s' "$status_json" | jq -e 'type == "object"' >/dev/null 2>&1; then
    diagnosis_block="$(printf '%s' "$status_json" | jq -r '
      "",
      "Diagnosis:",
      "  state=\(.diagnosis.state // "?") reason=\(.diagnosis.reasonCode // "none")",
      (if (.diagnosis.summary // "") != "" then "  summary=\(.diagnosis.summary)" else empty end)
    ' 2>/dev/null || true)"
  fi
  printf '%s' "$plan_json" | jq -r '
    "Operation: cancel",
    "Run: \(.runId // "")",
    (if .mode then "Mode: \(.mode)" else empty end),
    "Outcome: \(.outcome // "?")",
    (if .ownerClass then "Owner class: \(.ownerClass)" else empty end),
    (if .liveProof then "Live proof: \(.liveProof)" else empty end),
    (if .runState then "Run state: \(.runState)"
     elif .engineState then "Engine state: \(.engineState)"
     elif .graphStatus then "Graph status: \(.graphStatus)"
     else empty end),
    (if .mutated == false then "Mutation: none (preview)"
     elif .mutated == true then "Mutation: yes -> cancelled"
     elif .dryRun == true then "Mutation: none (dry-run)"
     else empty end),
    (if (.outstanding.requestId // null) != null then
      "Outstanding action: \(.outstanding.kind // "?") \(.outstanding.requestId) (will cancel without deletion)"
     else "Outstanding action: none" end),
    (if .cancelIntentPath then "Cancel intent: \(.cancelIntentPath)" else empty end),
    "Terminal state: cancelled",
    "Preserves: immutable input, definitions, logs, attempts, artifacts, requests/decisions, audit history"
  '
  if [[ -n "$diagnosis_block" ]]; then
    printf '%s\n' "$diagnosis_block"
  fi
}
