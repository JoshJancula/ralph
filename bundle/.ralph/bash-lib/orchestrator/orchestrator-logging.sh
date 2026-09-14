#!/usr/bin/env bash
# Logging helpers shared by .ralph/orchestrator.sh.
#
# Public interface:
#   ralph_orchestrator_timestamp -- ISO-style local timestamp string.
#   ralph_orchestrator_log -- append to LOG_FILE; mirror to stderr when ORCHESTRATOR_VERBOSE=1.

# Timestamp helper for log entries.
ralph_orchestrator_timestamp() { date '+%Y-%m-%d %H:%M:%S'; }

# Appends messages to the orchestrator log and mirrors to stderr when verbose.
ralph_orchestrator_log() {
  echo "[$(ralph_orchestrator_timestamp)] $*" >> "$LOG_FILE"
  if [[ "${ORCHESTRATOR_VERBOSE:-0}" == "1" ]]; then
    echo "[$(ralph_orchestrator_timestamp)] $*" >&2
  fi
}

# ralph_orchestrator_supervisor_log_rel
# Relative path under a Sequential engine directory for supervisor output.
ralph_orchestrator_supervisor_log_rel() {
  printf 'logs/supervisor.log\n'
}

# ralph_orchestrator_stage_log_rel <stage-id> <attempt-n> <kind>
# kind is agent or runner (supervisor stream maps to runner).
ralph_orchestrator_stage_log_rel() {
  local stage_id="$1" attempt="$2" kind="${3:-agent}"
  case "$kind" in
    agent|runner) ;;
    *)
      echo "Error: orchestrator stage log kind must be agent or runner" >&2
      return 1
      ;;
  esac
  printf 'logs/stages/%s/attempt-%s/%s.log\n' "$stage_id" "$attempt" "$kind"
}
