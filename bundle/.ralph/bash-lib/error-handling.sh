#!/usr/bin/env bash
#
# Minimal stderr helpers for Ralph shell scripts.
#
# Public interface:
#   ralph_error -- print message and exit 1.
#   ralph_warn -- print message to stderr (no exit).
#   ralph_die -- print message and exit with optional code (default 1).

ralph_error() {
  printf '%s\n' "$1" >&2
  exit 1
}

ralph_warn() {
  printf '%s\n' "$1" >&2
}

ralph_die() {
  local msg="$1"
  local code="${2:-1}"
  printf '%s\n' "$msg" >&2
  exit "$code"
}
