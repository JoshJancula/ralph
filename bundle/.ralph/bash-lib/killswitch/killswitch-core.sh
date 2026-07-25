#!/usr/bin/env bash

if [[ -n "${RALPH_KILLSWITCH_CORE_LOADED:-}" ]]; then
  return
fi
RALPH_KILLSWITCH_CORE_LOADED=1

_KILLSWITCH_CORE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

source "$_KILLSWITCH_CORE_DIR/killswitch-config.sh"
source "$_KILLSWITCH_CORE_DIR/killswitch-validator.sh"
source "$_KILLSWITCH_CORE_DIR/killswitch-killer.sh"

export KILLSWITCH_RUNNER_PID=$$

killswitch_load_config
killswitch_merge_env_overrides
killswitch_export_config_env
