#!/usr/bin/env bash

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
