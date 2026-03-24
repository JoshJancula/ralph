#!/usr/bin/env bash
# Logging helpers shared by .ralph/orchestrator.sh.

# Timestamp helper for log entries.
ralph_orchestrator_timestamp() { date '+%Y-%m-%d %H:%M:%S'; }

# Appends messages to the orchestrator log and mirrors to stderr when verbose.
ralph_orchestrator_log() {
  echo "[$(ralph_orchestrator_timestamp)] $*" >> "$LOG_FILE"
  if [[ "${ORCHESTRATOR_VERBOSE:-0}" == "1" ]]; then
    echo "[$(ralph_orchestrator_timestamp)] $*" >&2
  fi
}
