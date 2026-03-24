#!/usr/bin/env bash

if [[ -n "${RALPH_ORCHESTRATOR_STAGES_LOADED:-}" ]]; then
  return
fi
RALPH_ORCHESTRATOR_STAGES_LOADED=1

ORCH_STAGE_INDEX_KEYS=()
ORCH_STAGE_INDEX_VALS=()
ORCH_STAGE_ITER_KEYS=()
ORCH_STAGE_ITER_VALS=()

# Public interface:
#   extract_review_status -- parse review markdown for status marker.
#   check_loop_condition -- emit proceed vs loop:<stage>:<iter> from stage JSON and review file.
#   orch_stage_index_map_*, orch_stage_iteration_map_* -- parallel key/value arrays for stage index and iteration.
# Module state: ORCH_STAGE_INDEX_KEYS/VALS, ORCH_STAGE_ITER_KEYS/VALS (mutated by map_set).

extract_review_status() {
  local review_file="$1"
  [[ ! -f "$review_file" ]] && return 1

  local status=""
  if grep -q "<!-- REVIEW_STATUS: START -->" "$review_file" 2>/dev/null; then
    status="$(sed -n '/<!-- REVIEW_STATUS: START -->/,/<!-- REVIEW_STATUS: END -->/p' "$review_file" | grep '^status:' | head -1 | cut -d: -f2 | tr -d ' ')" || true
  fi

  [[ -n "$status" ]] && echo "$status" && return 0
  return 1
}

check_loop_condition() {
  local stage_json="$1"
  local review_file="$2"

  local loop_back="$(echo "$stage_json" | jq -r '.loopControl.loopBackTo // empty' 2>/dev/null)" || loop_back=""
  [[ -z "$loop_back" ]] && echo "proceed" && return 0

  local status="$(extract_review_status "$review_file")" || status="unknown"
  local max_iter="$(echo "$stage_json" | jq -r '.loopControl.maxIterations // 3' 2>/dev/null)" || max_iter=3
  local current_iter="${STAGE_ITERATION:-1}"

  if [[ "$status" == "approved" ]]; then
    echo "proceed"
  elif (( current_iter < max_iter )); then
    echo "loop:$loop_back:$((current_iter + 1))"
  else
    echo "proceed"
  fi
}

orch_stage_index_map_set() {
  local key="$1" val="$2" i
  for ((i = 0; i < ${#ORCH_STAGE_INDEX_KEYS[@]}; i++)); do
    if [[ "${ORCH_STAGE_INDEX_KEYS[$i]}" == "$key" ]]; then
      ORCH_STAGE_INDEX_VALS[$i]="$val"
      return 0
    fi
  done
  ORCH_STAGE_INDEX_KEYS+=("$key")
  ORCH_STAGE_INDEX_VALS+=("$val")
}

orch_stage_index_map_get() {
  local key="$1" i
  for ((i = 0; i < ${#ORCH_STAGE_INDEX_KEYS[@]}; i++)); do
    if [[ "${ORCH_STAGE_INDEX_KEYS[$i]}" == "$key" ]]; then
      printf '%s\n' "${ORCH_STAGE_INDEX_VALS[$i]}"
      return 0
    fi
  done
  return 1
}

orch_stage_iteration_map_set() {
  local key="$1" val="$2" i
  for ((i = 0; i < ${#ORCH_STAGE_ITER_KEYS[@]}; i++)); do
    if [[ "${ORCH_STAGE_ITER_KEYS[$i]}" == "$key" ]]; then
      ORCH_STAGE_ITER_VALS[$i]="$val"
      return 0
    fi
  done
  ORCH_STAGE_ITER_KEYS+=("$key")
  ORCH_STAGE_ITER_VALS+=("$val")
}

orch_stage_iteration_map_get() {
  local key="$1" i
  for ((i = 0; i < ${#ORCH_STAGE_ITER_KEYS[@]}; i++)); do
    if [[ "${ORCH_STAGE_ITER_KEYS[$i]}" == "$key" ]]; then
      printf '%s\n' "${ORCH_STAGE_ITER_VALS[$i]}"
      return 0
    fi
  done
  printf '%s\n' "1"
}
