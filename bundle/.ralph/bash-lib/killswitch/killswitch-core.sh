#!/usr/bin/env bash

if [[ -n "${RALPH_KILLSWITCH_CORE_LOADED:-}" ]]; then
  return "${RALPH_KILLSWITCH_CORE_LOAD_STATUS:-0}"
fi

_KILLSWITCH_CORE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

source "$_KILLSWITCH_CORE_DIR/killswitch-config.sh"
source "$_KILLSWITCH_CORE_DIR/killswitch-validator.sh"
source "$_KILLSWITCH_CORE_DIR/killswitch-killer.sh"
source "$_KILLSWITCH_CORE_DIR/killswitch-evaluate.sh"

if [[ -z "${KILLSWITCH_RUNNER_PID+x}" ]]; then
  export KILLSWITCH_RUNNER_PID=$$
fi

# Fail closed: invalid/unreadable winning source returns nonzero before merge,
# export, or any runtime/MCP caller proceeds past sourcing this file.
if ! killswitch_load_config; then
  RALPH_KILLSWITCH_CORE_LOAD_STATUS=1
  RALPH_KILLSWITCH_CORE_LOADED=1
  return 1
fi

killswitch_merge_env_overrides
killswitch_export_config_env

RALPH_KILLSWITCH_CORE_LOAD_STATUS=0
RALPH_KILLSWITCH_CORE_LOADED=1
return 0
