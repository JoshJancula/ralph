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
