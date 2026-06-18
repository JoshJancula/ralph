#!/usr/bin/env bash
# shellcheck shell=bash
## Cached named shell helper for run-plan re-exec.
## Safe to source repeatedly; returns empty on non-Darwin or any cache failure.

if [[ -n "${RALPH_NAMED_SHELL_LOADED:-}" ]]; then
  # shellcheck disable=SC2317
  return 0 2>/dev/null || exit 0
fi
RALPH_NAMED_SHELL_LOADED=1

_RALPH_NAMED_SHELL_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

ralph_named_shell_path() {
  local cache_home cache_dir cache_path stamp_path source_bash source_stat source_size source_mtime
  local stamp_source stamp_size stamp_mtime validation_status

  if [[ "$(uname -s 2>/dev/null)" != "Darwin" ]]; then
    printf ''
    return 0
  fi

  source_bash="$(command -v bash 2>/dev/null)" || source_bash=""
  if [[ -z "$source_bash" ]]; then
    printf ''
    return 0
  fi

  cache_home="${XDG_CACHE_HOME:-$HOME/.cache}"
  cache_dir="$cache_home/ralph/bin"
  cache_path="$cache_dir/ralph-run-plan"
  stamp_path="$cache_dir/ralph-run-plan.stamp"

  if [[ -x "$cache_path" && -f "$stamp_path" ]]; then
    if exec 3<"$stamp_path"; then
      if IFS= read -r stamp_source <&3 && IFS= read -r stamp_size <&3 && IFS= read -r stamp_mtime <&3; then
        source_stat="$(stat -f '%z %m' "$source_bash" 2>/dev/null)"
          IFS=' ' read -r source_size source_mtime <<EOF
$source_stat
EOF
          if [[ "$stamp_source" == "$source_bash" && "$stamp_size" == "$source_size" && "$stamp_mtime" == "$source_mtime" ]]; then
            if "$cache_path" -c 'exit 7' >/dev/null 2>&1; then
              validation_status=0
            else
              validation_status=$?
            fi
            exec 3<&-
            if [[ "$validation_status" -eq 7 ]]; then
              printf '%s\n' "$cache_path"
              return 0
            fi
          fi
      fi
      exec 3<&-
    fi
  fi

  mkdir -p "$cache_dir" || {
    printf ''
    return 0
  }

  if ! cp "$(command -v bash)" "$cache_path"; then
    rm -f "$cache_path"
    printf ''
    return 0
  fi

  if command -v codesign >/dev/null 2>&1; then
    codesign --remove-signature "$cache_path" >/dev/null 2>&1 || true
    codesign -s - -f "$cache_path" >/dev/null 2>&1 || true
  fi

  if "$cache_path" -c 'exit 7' >/dev/null 2>&1; then
    validation_status=0
  else
    validation_status=$?
  fi
  if [[ "$validation_status" -ne 7 ]]; then
    rm -f "$cache_path" "$stamp_path"
    printf ''
    return 0
  fi

  source_stat="$(stat -f '%z %m' "$source_bash" 2>/dev/null)"
  IFS=' ' read -r source_size source_mtime <<EOF
$source_stat
EOF
  {
    printf '%s\n' "$source_bash"
    printf '%s\n' "$source_size"
    printf '%s\n' "$source_mtime"
  } >"$stamp_path" || {
    rm -f "$cache_path" "$stamp_path"
    printf ''
    return 0
  }

  printf '%s\n' "$cache_path"
}
