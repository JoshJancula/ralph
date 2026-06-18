#!/usr/bin/env bash

if [[ -n "${RALPH_REVIEW_STATUS_LIB_LOADED:-}" ]]; then
  return
fi
RALPH_REVIEW_STATUS_LIB_LOADED=1

if [[ "${BASH_SOURCE[0]}" = "$0" ]]; then
  echo "This file is meant to be sourced, not executed." >&2
  exit 1
fi

ralph_extract_review_status() {
  local path="$1"

  if [[ ! -f "$path" ]]; then
    printf 'missing_file\n'
    return 1
  fi

  local start_marker="<!-- REVIEW_STATUS: START -->"
  local end_marker="<!-- REVIEW_STATUS: END -->"
  local status_line=""

  status_line=$(sed -n "/$start_marker/,/$end_marker/p" "$path" | grep "^status:" || true)

  if [[ -z "$status_line" ]]; then
    printf 'missing_status\n'
    return 1
  fi

  local status_value
  status_value=$(printf '%s' "$status_line" | sed 's/^status:[[:space:]]*//' | tr -d ' ')

  case "$status_value" in
    approved|changes-required)
      printf '%s\n' "$status_value"
      return 0
      ;;
    *)
      printf 'invalid\n'
      return 1
      ;;
  esac
}
