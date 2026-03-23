#!/usr/bin/env bash
printf 'orchestrator running with %s\n' "$*"
if [[ "${ORCHESTRATOR_DRY_RUN:-}" == "1" ]]; then
  printf 'dry run mode\n'
fi
