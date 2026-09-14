# shellcheck shell=bash
# Command fingerprint for duration learning.
# Dispatches to bundle/.ralph/python/command_fingerprint.py when python3 is
# present. When python3 is absent, prints nothing and exits 0 so callers
# degrade to recording nothing rather than failing (dependency rule).

ralph_command_fingerprint_script_dir() {
  local src="${BASH_SOURCE[0]}"
  while [[ -L "$src" ]]; do
    local link_dir
    link_dir="$(cd "$(dirname "$src")" && pwd)"
    src="$(readlink "$src")"
    [[ "$src" != /* ]] && src="$link_dir/$src"
  done
  cd "$(dirname "$src")" && pwd
}

ralph_command_fingerprint_py() {
  local lib_dir
  lib_dir="$(ralph_command_fingerprint_script_dir)"
  printf '%s/../python/command_fingerprint.py\n' "$lib_dir"
}

# Usage: ralph_command_fingerprint <command>
# Prints the sha256 hex digest on stdout, or empty when not fingerprintable
# or when python3 is unavailable.
ralph_command_fingerprint() {
  local command="${1-}"
  local py_script payload digest

  if ! command -v python3 >/dev/null 2>&1; then
    return 0
  fi
  if ! command -v jq >/dev/null 2>&1; then
    return 0
  fi

  py_script="$(ralph_command_fingerprint_py)"
  [[ -f "$py_script" ]] || return 0

  payload="$(jq -n --arg command "$command" '{command: $command}')" || return 0
  digest="$(
    printf '%s\n' "$payload" | python3 "$py_script" fingerprint 2>/dev/null \
      | jq -r '.fingerprint // empty'
  )" || true
  if [[ -n "$digest" && "$digest" != "null" ]]; then
    printf '%s\n' "$digest"
  fi
  return 0
}
