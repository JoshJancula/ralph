# Exit trap: optional interactive cleanup after run-plan (sourced from run-plan-core).
#
# Public interface:
#   ralph_run_plan_process_teardown_on_exit -- kill agent tree and launcher watchdog
#   ralph_run_plan_exit_trap_handler -- EXIT trap: finalize usage, teardown, prompt_cleanup_on_exit
#   ralph_run_plan_interrupt_trap_handler -- INT/TERM trap: finalize usage, teardown, overlay cleanup
#   prompt_cleanup_on_exit -- may run cleanup-plan.sh or print the command

# Reap the background agent process tree and stop the launcher-death watchdog.
# Args: none
# Returns: 0
ralph_run_plan_process_teardown_on_exit() {
  if [[ "${RALPH_LAUNCHER_WATCHDOG_PID:-}" =~ ^[0-9]+$ ]]; then
    kill "$RALPH_LAUNCHER_WATCHDOG_PID" 2>/dev/null || true
    wait "$RALPH_LAUNCHER_WATCHDOG_PID" 2>/dev/null || true
  fi
  if [[ "${AGENT_PID:-}" =~ ^[0-9]+$ ]]; then
    # AGENT_PID is a process-group leader; kill the whole group first.
    if declare -F ralph_kill_process_group >/dev/null 2>&1; then
      ralph_kill_process_group "$AGENT_PID" 2
    else
      kill -TERM -"$AGENT_PID" 2>/dev/null || true
      sleep 0.5
      kill -KILL -"$AGENT_PID" 2>/dev/null || true
    fi
    sleep 0.2
    # Fall back to per-PID tree walk if any member escaped the group signal.
    if kill -0 "$AGENT_PID" 2>/dev/null; then
      if declare -F ralph_kill_tree_and_reap >/dev/null 2>&1; then
        ralph_kill_tree_and_reap "$AGENT_PID"
      elif declare -F ralph_kill_tree >/dev/null 2>&1; then
        ralph_kill_tree "$AGENT_PID"
        wait "$AGENT_PID" 2>/dev/null || true
      fi
    fi
  fi
  ralph_run_plan_async_shell_jobs_teardown
}

ralph_run_plan_async_shell_jobs_teardown() {
  local plan_key="${RALPH_PLAN_KEY:-${RALPH_ARTIFACT_NS:-}}"
  local root state_file pid status
  [[ -n "$plan_key" && -n "${WORKSPACE:-}" ]] || return 0
  [[ "$plan_key" =~ ^[A-Za-z0-9._-]+$ ]] || return 0
  root="$WORKSPACE/.ralph-workspace/tool-results/$plan_key/shell-jobs"
  [[ -d "$root" ]] || return 0
  while IFS= read -r state_file; do
    [[ -f "$state_file" ]] || continue
    status="$(jq -r '.status // empty' "$state_file" 2>/dev/null || true)"
    [[ "$status" == "running" ]] || continue
    pid="$(jq -r '.pid // empty' "$state_file" 2>/dev/null || true)"
    [[ "$pid" =~ ^[0-9]+$ ]] || continue
    if declare -F ralph_kill_tree_and_reap >/dev/null 2>&1; then
      ralph_kill_tree_and_reap "$pid"
    elif declare -F ralph_kill_tree >/dev/null 2>&1; then
      ralph_kill_tree "$pid"
    else
      kill -TERM "$pid" 2>/dev/null || true
      sleep 1
      kill -KILL "$pid" 2>/dev/null || true
    fi
    jq -c --arg endedAt "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '.status = "cancelled" | .endedAt = $endedAt' "$state_file" >"${state_file}.tmp" 2>/dev/null && mv "${state_file}.tmp" "$state_file"
  done < <(find "$root" -mindepth 2 -maxdepth 2 -name state.json -type f 2>/dev/null)
}

# Prompt the user for optional cleanup output when the runner exits.
# Args: none
# Returns: 0 after handling cleanup prompt, non-zero on error
prompt_cleanup_on_exit() {
  trap - EXIT
  [[ "${ALLOW_CLEANUP_PROMPT:-0}" == "1" ]] || return 0
  [[ "$NON_INTERACTIVE_FLAG" == "1" ]] && return 0
  echo ""
  if [[ "$EXIT_STATUS" == "complete" ]]; then
    echo -e "${C_DIM}All TODOs are complete. Logs and artifacts available at:${C_RST}"
    echo -e "  ${C_B}Logs directory:${C_RST} $RALPH_LOG_DIR"
    echo -e "  ${C_B}Output log:${C_RST} $OUTPUT_LOG"
    echo -e "  ${C_B}Plan log:${C_RST} $LOG_FILE"
    echo ""
    echo -e "${C_DIM}To clean up logs and temporary files, run:${C_RST}"
    echo -e "  ${C_C}.ralph/cleanup-plan.sh ${RALPH_ARTIFACT_NS:-<artifact-namespace>} ${WORKSPACE}${C_RST}"
    return 0
  fi
  if [[ -t 0 && -t 1 ]]; then
    local ans
    echo -e "${C_C}${C_BOLD}Cleanup${C_RST}" >&2
    printf '%s' "${C_Y}${C_BOLD}Run cleanup now?${C_RST}${C_DIM} [y/N]${C_RST}: " >&2
    read -r ans </dev/tty 2>/dev/null || ans=""
    ans="$(echo "$ans" | tr '[:upper:]' '[:lower:]')"
    if [[ "$ans" == "y" || "$ans" == "yes" ]]; then
      "$CLEANUP_SCRIPT" "${RALPH_ARTIFACT_NS:-}" "$WORKSPACE"
      return 0
    fi
  fi
  echo -e "${C_DIM}Cleanup command:${C_RST} ${C_C}.ralph/cleanup-plan.sh ${RALPH_ARTIFACT_NS:-<artifact-namespace>} ${WORKSPACE}${C_RST}"
}

ralph_run_plan_exit_trap_handler() {
  if declare -F _ralph_finalize_plan_usage_on_exit >/dev/null 2>&1; then
    _ralph_finalize_plan_usage_on_exit
  fi
  ralph_run_plan_process_teardown_on_exit
  prompt_cleanup_on_exit
}

ralph_run_plan_interrupt_trap_handler() {
  local signal="${1:-INT}"
  local exit_code=130

  case "$signal" in
    TERM) exit_code=143 ;;
    HUP) exit_code=129 ;;
  esac

  trap - EXIT INT TERM HUP
  ALLOW_CLEANUP_PROMPT=0
  EXIT_STATUS="interrupted"

  if declare -F _ralph_finalize_plan_usage_on_exit >/dev/null 2>&1; then
    _ralph_finalize_plan_usage_on_exit
  fi
  ralph_run_plan_process_teardown_on_exit
  if declare -F ralph_runtime_overlay_signal_trap_handler >/dev/null 2>&1; then
    ralph_runtime_overlay_signal_trap_handler
  fi
  exit "$exit_code"
}

trap ralph_run_plan_exit_trap_handler EXIT
trap 'ralph_run_plan_interrupt_trap_handler INT' INT
trap 'ralph_run_plan_interrupt_trap_handler TERM' TERM
