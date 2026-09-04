#!/usr/bin/env bash

if [[ -n "${RALPH_HUMAN_INTERACTION_HELPERS_LOADED:-}" ]]; then
  return
fi
RALPH_HUMAN_INTERACTION_HELPERS_LOADED=1

# Public interface:
#   ralph_optional_log -- forwards to orchestrator `log` when defined.
#   ralph_human_ack_tool_path -- resolves .ralph/orchestrator.sh for --human-ack.
#   ralph_forward_human_question_to_orchestrator -- invokes orchestrator with a question file.
#   ralph_forward_human_question_to_workflow_action -- workflow-run common action request.
#   ralph_record_interactive_reply, ralph_interactive_history_block -- TTY Q&A capture for prompts.
#   ralph_persist_human_exchange -- append exchange to human-replies.md when configured.
#   ralph_human_recovery_page -- compact graph permission-wait recovery page.
#   ralph_human_recovery_page_write -- write that page to a crash-recovery file.

# Holds the human exchanges captured during interactive runs.
TTY_HUMAN_HISTORY=""

ralph_optional_log() {
  if [[ "$(type -t log)" == "function" ]]; then
    log "$@"
  fi
}

ralph_human_ack_tool_path() {
  if [[ -n "${RALPH_HUMAN_ACK_TOOL:-}" ]]; then
    printf '%s' "$RALPH_HUMAN_ACK_TOOL"
    return 0
  fi
  if [[ -z "${RALPH_ORCH_FILE:-}" ]]; then
    return 1
  fi
  local ws="${WORKSPACE:-$(pwd)}"
  local candidate="$ws/.ralph/orchestrator.sh"
  if [[ -f "$candidate" ]]; then
    printf '%s' "$candidate"
    return 0
  fi
  return 1
}

# ralph_forward_human_question_to_workflow_action <question-file>
# For workflow-owned runs: create a common kind=input action request instead of
# the transient human-ack / pending-human bridge. Standalone plans cannot use this.
ralph_forward_human_question_to_workflow_action() {
  local question_file="${1:-}" question details="" nonce
  [[ -n "$question_file" && -f "$question_file" ]] || return 1
  if [[ -z "${RALPH_WORKFLOW_REGISTRY_RUN:-}" || ! -d "${RALPH_WORKFLOW_REGISTRY_RUN}" \
      || -z "${RALPH_WORKFLOW_RUN_ID:-}" \
      || -z "${RALPH_WORKFLOW_STAGE_ID:-}" \
      || -z "${RALPH_WORKFLOW_STAGE_ATTEMPT:-}" ]]; then
    return 1
  fi
  if ! declare -F workflow_action_stage_request_create >/dev/null 2>&1; then
    local lib
    lib="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/workflow/workflow-actions.sh"
    [[ -f "$lib" ]] || return 1
    # shellcheck source=/dev/null
    source "$lib"
  fi
  question="$(tr -d '\r' <"$question_file" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
  [[ -n "$question" ]] || return 1
  nonce="${RALPH_WORKFLOW_ACTION_NONCE:-}"
  if [[ -z "$nonce" && -n "${RALPH_WORKFLOW_ACTION_CAPABILITY:-}" && -f "${RALPH_WORKFLOW_ACTION_CAPABILITY}" ]]; then
    nonce="$(jq -r '.nonce // empty' "$RALPH_WORKFLOW_ACTION_CAPABILITY" 2>/dev/null || true)"
  fi
  [[ -n "$nonce" ]] || return 1
  workflow_action_stage_request_create \
    --registry-run "$RALPH_WORKFLOW_REGISTRY_RUN" \
    --run-id "$RALPH_WORKFLOW_RUN_ID" \
    --stage-id "$RALPH_WORKFLOW_STAGE_ID" \
    --attempt-id "$RALPH_WORKFLOW_STAGE_ATTEMPT" \
    --nonce "$nonce" \
    --question "$question" \
    --details "$details" >/dev/null || return 1
  ralph_optional_log "workflow action request created for operator input (nonce omitted from logs)"
  return 0
}

ralph_forward_human_question_to_orchestrator() {
  local question_file="$1"
  local plan_path="${2:-${PLAN_PATH:-}}"
  if [[ -z "$question_file" || ! -f "$question_file" ]]; then
    return 1
  fi
  # Workflow-owned ordinary stages use common action requests, not the legacy
  # transient human-ack bridge. Permission pauses still use the orchestrator path.
  if [[ "${RALPH_HUMAN_QUESTION_KIND:-}" != "permission" ]] \
    && declare -F ralph_forward_human_question_to_workflow_action >/dev/null 2>&1; then
    if ralph_forward_human_question_to_workflow_action "$question_file"; then
      return 0
    fi
  fi
  local tool
  tool="$(ralph_human_ack_tool_path)" || return 1
  local args=(--human-ack --human-ack-question-file "$question_file")
  [[ -n "$plan_path" ]] && args+=(--human-ack-plan "$plan_path")
  [[ -n "${WORKSPACE:-}" ]] && args+=(--human-ack-workspace "$WORKSPACE")
  local runner_env=()
  [[ -n "${RALPH_ORCH_FILE:-}" ]] && runner_env+=("RALPH_ORCH_FILE=${RALPH_ORCH_FILE}")
  [[ -n "${RALPH_PLAN_KEY:-}" ]] && runner_env+=("RALPH_PLAN_KEY=${RALPH_PLAN_KEY}")
  [[ -n "${RALPH_ARTIFACT_NS:-}" ]] && runner_env+=("RALPH_ARTIFACT_NS=${RALPH_ARTIFACT_NS}")
  local status
  set +e
  if ((${#runner_env[@]} > 0)); then
    if [[ -n "${LOG_FILE:-}" ]]; then
      env "${runner_env[@]}" bash "$tool" "${args[@]}" >>"$LOG_FILE" 2>&1
    else
      env "${runner_env[@]}" bash "$tool" "${args[@]}"
    fi
  else
    if [[ -n "${LOG_FILE:-}" ]]; then
      bash "$tool" "${args[@]}" >>"$LOG_FILE" 2>&1
    else
      bash "$tool" "${args[@]}"
    fi
  fi
  status=$?
  set -e
  if [[ $status -eq 0 ]]; then
    ralph_optional_log "human-ack bridge: question forwarded via $tool"
  else
    ralph_optional_log "human-ack bridge: tool $tool failed with exit $status"
  fi
  return $status
}

ralph_record_interactive_reply() {
  local question="$1"
  local answer="$2"
  local timestamp
  timestamp="$(date '+%Y-%m-%d %H:%M:%S')"
  TTY_HUMAN_HISTORY+=$'\n### '"$timestamp"$'\n**Agent asked:**\n'"$question"$'\n**Operator answered:**\n'"$answer"$'\n'
}

ralph_interactive_history_block() {
  if [[ -z "${TTY_HUMAN_HISTORY:-}" ]]; then
    return
  fi
  printf '## Human operator answers (interactive run)\n%s\n' "$TTY_HUMAN_HISTORY"
}

ralph_persist_human_exchange() {
  local question="$1"
  local answer="$2"
  local dir="${HUMAN_ARTIFACTS_DIR:-}"
  if [[ -z "$dir" ]]; then
    return 1
  fi
  mkdir -p "$dir"
  local timestamp
  timestamp="$(date '+%Y%m%d%H%M%S')"
  local artifact_file="$dir/human-exchange-${timestamp}.md"
  {
    echo "# Human exchange"
    echo ""
    echo "## Question"
    echo "$question"
    echo ""
    echo "## Answer"
    echo "$answer"
  } >"$artifact_file"
  printf '%s\n' "$artifact_file"
}

# Allowed graph permission decisions that may appear as copyable respond commands.
RALPH_HUMAN_RECOVERY_CHOICES='allow-once
allow-run
allow-always
deny'

# ralph_human_recovery_redact_text <text>
# Replaces credential-looking assignments and common token shapes with [REDACTED].
# Reuses graph_operator_bound_reason when that helper is already loaded.
ralph_human_recovery_redact_text() {
  local text="${1:-}"
  if declare -F graph_operator_bound_reason >/dev/null 2>&1; then
    graph_operator_bound_reason "$text"
    return 0
  fi
  text="$(printf '%s' "$text" | tr '\n\r\t' ' ' | tr -s ' ')"
  text="${text# }"
  text="${text% }"
  if command -v python3 >/dev/null 2>&1; then
    text="$(printf '%s' "$text" | python3 -c '
import re, sys
text = sys.stdin.read()
patterns = (
    re.compile(
        r"(?i)(?:password|passwd|secret|token|api[_-]?key|private[_-]?key|"
        r"bearer|authorization|credential)\s*[=:]\s*\S+"
    ),
    re.compile(
        r"(?i)(?<![A-Za-z0-9_-])(?:sk-[A-Za-z0-9_-]{8,}|AKIA[0-9A-Z]{8,}|"
        r"ghp_[A-Za-z0-9]{20,}|xox[baprs]-[A-Za-z0-9-]{10,})(?![A-Za-z0-9_-])"
    ),
)
for pat in patterns:
    text = pat.sub("[REDACTED]", text)
sys.stdout.write(text)
')"
  else
    text="$(printf '%s' "$text" | sed -E \
      -e 's/(password|passwd|secret|token|api[_-]?key|api_key|api-key|private[_-]?key|bearer|authorization|credential)[[:space:]]*[=:][[:space:]]*[^[:space:]]+/[REDACTED]/g' \
      -e 's/sk-[A-Za-z0-9_-]{8,}/[REDACTED]/g' \
      -e 's/AKIA[0-9A-Z]{8,}/[REDACTED]/g' \
      -e 's/ghp_[A-Za-z0-9]{20,}/[REDACTED]/g')"
  fi
  printf '%s\n' "$text"
}

# ralph_human_recovery_bound_text <text> [max]
ralph_human_recovery_bound_text() {
  local text="${1:-}" max="${2:-200}" ellipsis="..." keep
  if [[ ! "$max" =~ ^[0-9]+$ ]] || [[ "$max" -lt 1 ]]; then
    max=200
  fi
  text="$(printf '%s' "$text" | tr '\n\r\t' ' ' | tr -s ' ')"
  text="${text# }"
  text="${text% }"
  if [[ "${#text}" -le "$max" ]]; then
    printf '%s\n' "$text"
    return 0
  fi
  keep="$max"
  if [[ "$max" -gt "${#ellipsis}" ]]; then
    keep=$((max - ${#ellipsis}))
  fi
  printf '%s%s\n' "${text:0:$keep}" "$ellipsis"
}

# ralph_human_recovery_one_sentence <text>
# Collapse whitespace, take the first sentence, redact, and cap length.
ralph_human_recovery_one_sentence() {
  local text="${1:-}" max="${RALPH_HUMAN_RECOVERY_REASON_MAX:-${GRAPH_OPERATOR_REASON_MAX:-200}}"
  text="$(ralph_human_recovery_redact_text "$text")"
  text="$(printf '%s' "$text" | tr '\n\r\t' ' ' | tr -s ' ')"
  text="${text# }"
  text="${text% }"
  text="$(printf '%s' "$text" | sed -E 's/(^[^.!?]+[.!?]).*/\1/')"
  ralph_human_recovery_bound_text "$text" "$max"
}

# ralph_human_recovery_is_choice <token>
ralph_human_recovery_is_choice() {
  local token="${1:-}" candidate
  [[ -n "$token" ]] || return 1
  while IFS= read -r candidate; do
    [[ "$candidate" == "$token" ]] && return 0
  done <<< "$RALPH_HUMAN_RECOVERY_CHOICES"
  return 1
}

# ralph_human_recovery_load_request <json-or-path>
# Prints compact JSON for the allowlisted recovery fields only.
ralph_human_recovery_load_request() {
  local input="${1:-}" raw extracted
  if [[ -z "$input" ]]; then
    echo "Error: recovery page requires request JSON or a request file" >&2
    return 1
  fi
  if [[ -f "$input" ]]; then
    raw="$(cat -- "$input" 2>/dev/null || true)"
  else
    raw="$input"
  fi
  command -v jq >/dev/null 2>&1 || {
    echo "Error: jq is required to render a graph recovery page" >&2
    return 1
  }
  if ! printf '%s' "$raw" | jq -e 'type == "object"' >/dev/null 2>&1; then
    echo "Error: recovery page request must be a JSON object" >&2
    return 1
  fi
  extracted="$(printf '%s' "$raw" | jq -c '
    {
      requestId: ((.requestId // .id // "") | tostring),
      namespace: ((.namespace // "") | tostring),
      runId: ((.runId // "") | tostring),
      nodeId: ((.nodeId // "") | tostring),
      attemptId: ((.attemptId // "") | tostring),
      runtime: ((.runtime // "") | tostring),
      action: ((.action // .tool // "") | tostring),
      resource: ((.resource // "") | tostring),
      effect: ((.effect // "") | tostring),
      reason: ((.reason // "") | tostring),
      choices: (if (.choices | type) == "array" then .choices else [] end),
      state: ((.state // "") | tostring)
    }
  ' 2>/dev/null)" || extracted=""
  if [[ -z "$extracted" ]]; then
    echo "Error: recovery page request JSON could not be parsed" >&2
    return 1
  fi
  printf '%s\n' "$extracted"
}

# ralph_human_recovery_page <request-json-or-path> [state]
# Render a compact graph permission-wait page: identity, one-sentence reason,
# action/resource/effect, choices, state, and copyable respond commands.
# Extra request fields (prompt, transcript, usage, argv) are discarded.
ralph_human_recovery_page() {
  local input="${1:-}" state="${2:-}" extracted
  local request_id namespace run_id node_id attempt_id runtime
  local action resource effect reason choices_json
  local max marker keep page choice filtered_json
  local -a choices=()

  extracted="$(ralph_human_recovery_load_request "$input")" || return 1
  request_id="$(printf '%s' "$extracted" | jq -r '.requestId')"
  namespace="$(printf '%s' "$extracted" | jq -r '.namespace')"
  run_id="$(printf '%s' "$extracted" | jq -r '.runId')"
  node_id="$(printf '%s' "$extracted" | jq -r '.nodeId')"
  attempt_id="$(printf '%s' "$extracted" | jq -r '.attemptId')"
  runtime="$(printf '%s' "$extracted" | jq -r '.runtime')"
  action="$(printf '%s' "$extracted" | jq -r '.action')"
  resource="$(printf '%s' "$extracted" | jq -r '.resource')"
  effect="$(printf '%s' "$extracted" | jq -r '.effect')"
  reason="$(printf '%s' "$extracted" | jq -r '.reason')"
  choices_json="$(printf '%s' "$extracted" | jq -c '.choices')"
  if [[ -z "$state" ]]; then
    state="$(printf '%s' "$extracted" | jq -r '.state')"
  fi
  [[ -n "$state" ]] || state="awaiting-operator"

  request_id="$(ralph_human_recovery_bound_text "$request_id" 80)"
  namespace="$(ralph_human_recovery_bound_text "$namespace" 80)"
  run_id="$(ralph_human_recovery_bound_text "$run_id" 80)"
  node_id="$(ralph_human_recovery_bound_text "$node_id" 80)"
  attempt_id="$(ralph_human_recovery_bound_text "$attempt_id" 80)"
  runtime="$(ralph_human_recovery_bound_text "$runtime" 40)"
  if [[ -z "$request_id" || -z "$namespace" || -z "$run_id" || -z "$node_id" || -z "$attempt_id" ]]; then
    echo "Error: recovery page identity requires requestId, namespace, runId, nodeId, and attemptId" >&2
    return 1
  fi

  action="$(ralph_human_recovery_redact_text "$action")"
  action="$(ralph_human_recovery_bound_text "$action" 80)"
  resource="$(ralph_human_recovery_redact_text "$resource")"
  resource="$(ralph_human_recovery_bound_text "$resource" 200)"
  effect="$(ralph_human_recovery_bound_text "$effect" 40)"
  reason="$(ralph_human_recovery_one_sentence "$reason")"
  state="$(ralph_human_recovery_bound_text "$state" 40)"
  [[ -n "$action" ]] || action="permission"
  [[ -n "$resource" ]] || resource="$action"
  [[ -n "$reason" ]] || reason="operator permission required"
  case "$effect" in
    read|write|network) ;;
    *) effect="write" ;;
  esac

  if [[ "$choices_json" != "[]" ]]; then
    while IFS= read -r choice; do
      [[ -n "$choice" ]] || continue
      ralph_human_recovery_is_choice "$choice" || continue
      choices+=("$choice")
    done < <(printf '%s' "$choices_json" | jq -r '.[] | tostring')
  fi
  if [[ ${#choices[@]} -eq 0 ]]; then
    choices=(allow-once allow-run allow-always deny)
  fi
  filtered_json="$(printf '%s\n' "${choices[@]}" | jq -Rsc 'split("\n") | map(select(length > 0))')"

  page="$(
    printf '%s\n' "# Graph permission wait"
    printf '\n'
    printf '%s\n' "Identity"
    printf '  requestId: %s\n' "$request_id"
    printf '  namespace: %s\n' "$namespace"
    printf '  runId: %s\n' "$run_id"
    printf '  nodeId: %s\n' "$node_id"
    printf '  attemptId: %s\n' "$attempt_id"
    if [[ -n "$runtime" ]]; then
      printf '  runtime: %s\n' "$runtime"
    fi
    printf '\n'
    printf '%s\n' "Reason"
    printf '  %s\n' "$reason"
    printf '\n'
    printf '%s\n' "Action"
    printf '  action: %s\n' "$action"
    printf '  resource: %s\n' "$resource"
    printf '  effect: %s\n' "$effect"
    printf '\n'
    printf '%s\n' "Choices"
    printf '%s\n' "$filtered_json" | jq -r '.[] | "  " + .'
    printf '\n'
    printf '%s\n' "State"
    printf '  %s\n' "$state"
    printf '\n'
    printf '%s\n' "Respond"
    for choice in "${choices[@]}"; do
      printf '  ralph workflow actions respond %q %q --decision %q\n' \
        "$run_id" "$request_id" "$choice"
    done
  )"

  max="${RALPH_HUMAN_RECOVERY_PAGE_MAX:-4096}"
  if [[ ! "$max" =~ ^[0-9]+$ ]] || [[ "$max" -lt 1 ]]; then
    max=4096
  fi
  if [[ "${#page}" -gt "$max" ]]; then
    marker=$'\n[truncated]'
    keep=$((max - ${#marker}))
    if [[ "$keep" -lt 1 ]]; then
      page="${page:0:$max}"
    else
      page="${page:0:$keep}${marker}"
    fi
  fi
  printf '%s\n' "$page"
}

# ralph_human_recovery_page_write <out-path> <request-json-or-path> [state]
# Writes the compact recovery page to out-path and prints that path.
ralph_human_recovery_page_write() {
  local out_path="${1:-}" input="${2:-}" state="${3:-}" page
  if [[ -z "$out_path" || -z "$input" ]]; then
    echo "Error: ralph_human_recovery_page_write requires an output path and request JSON" >&2
    return 1
  fi
  page="$(ralph_human_recovery_page "$input" "$state")" || return 1
  mkdir -p "$(dirname "$out_path")"
  printf '%s\n' "$page" >"$out_path"
  printf '%s\n' "$out_path"
}
