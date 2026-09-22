#!/usr/bin/env bash
# Scalable waits for Ralph polling loops.
#
# Production code waits in whole seconds so a human watching a run sees calm,
# readable progress. Those same waits dominate the test suite: a no-op
# run-plan invocation spends most of its wall time asleep, and the suite makes
# hundreds of such invocations.
#
# ralph_wait <seconds> replaces a bare `sleep <seconds>` in any poll loop whose
# duration is not itself under test. RALPH_WAIT_SCALE multiplies the requested
# duration:
#
#   unset / 1  production behaviour, byte-for-byte the same wait
#   0.02       test suite: a 1s poll becomes 20ms
#   0          floored to RALPH_WAIT_MIN so a loop never spins hot
#
# Never use this for a wait the caller is actually measuring (timeout
# expiry, backoff assertions); call sleep directly there so the test keeps
# exercising the real duration.

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  echo "This file is meant to be sourced, not executed." >&2
  exit 1
fi
if [[ -n "${RALPH_WAIT_LOADED:-}" ]]; then return 0; fi
RALPH_WAIT_LOADED=1

# Floor for a scaled wait. Keeps a scaled poll loop yielding to the scheduler
# instead of burning a core.
: "${RALPH_WAIT_MIN:=0.01}"

ralph_wait() {
  local secs="${1:-1}"
  local scale="${RALPH_WAIT_SCALE:-1}"

  # Fast path: unscaled production wait, no extra process.
  if [[ -z "$scale" || "$scale" == "1" ]]; then
    sleep "$secs"
    return 0
  fi

  # Fast path for the fully-collapsed case the test suite uses: no awk process
  # per call, which would otherwise cost more than the wait it replaces.
  if [[ "$scale" == "0" || "$scale" == "0.0" ]]; then
    sleep "$RALPH_WAIT_MIN"
    return 0
  fi

  local effective
  effective="$(awk -v s="$secs" -v m="$scale" -v floor="$RALPH_WAIT_MIN" \
    'BEGIN { v = s * m; if (v < floor) v = floor; printf "%.4f", v }' 2>/dev/null)" || effective="$RALPH_WAIT_MIN"
  sleep "$effective"
}
