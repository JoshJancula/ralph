#!/usr/bin/env bash

if [[ -n "${RALPH_RUN_PLAN_LAUNCH_LOADED:-}" ]]; then
  return
fi
RALPH_RUN_PLAN_LAUNCH_LOADED=1

# Public interface:
#   ralph_launch_failure_kind -- classify launch-path failures before the TODO retry loop.
#     Returns one of: missing_exit_code_file, aborted_streaming, aborted_tools.
#     Returns non-zero when the invocation had a clean exit sidecar and no launch abort markers.

ralph_launch_failure_kind() {
  local exit_code_file_present="${1:-0}"
  local output_segment="${2:-}"

  if printf '%s' "$output_segment" | grep -Eiq 'aborted_(streaming|tools)'; then
    if printf '%s' "$output_segment" | grep -Eiq 'aborted_streaming'; then
      printf '%s\n' "aborted_streaming"
      return 0
    fi
    printf '%s\n' "aborted_tools"
    return 0
  fi

  if [[ "$exit_code_file_present" != "1" ]]; then
    printf '%s\n' "missing_exit_code_file"
    return 0
  fi

  return 1
}
