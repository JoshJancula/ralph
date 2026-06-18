#!/usr/bin/env bash
set -euo pipefail

ns="${RALPH_ARTIFACT_NS:-structured-pipeline-plans.plan}"
log=".ralph-workspace/artifacts/${ns}/run-plan-loopback.log"
mkdir -p "$(dirname "$log")"

bats tests/bats/run-plan/run-plan-loopback.bats >"$log" 2>&1
ec=$?
printf 'exit=%s log=%s\n' "$ec" "$log"
tail -n 20 "$log"
exit "$ec"
