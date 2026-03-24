# Exit trap: optional interactive cleanup after run-plan (sourced from run-plan-core).
#
# Public interface:
#   prompt_cleanup_on_exit -- registered on EXIT; may run cleanup-plan.sh or print the command.

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
trap prompt_cleanup_on_exit EXIT
