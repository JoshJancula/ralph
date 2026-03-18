#!/usr/bin/env bash
# Refuse file paths whose final name matches .env* (same policy as .claude/hooks/block-env-reads.sh
# and AGENTS.md: agents and Ralph tooling must not read .env files).

ralph_basename_is_env_secret() {
  local base="$1"
  [[ -n "$base" && "$base" == .env* ]]
}

# Usage: ralph_assert_path_not_env_secret "Plan file" "$PLAN_PATH"
ralph_assert_path_not_env_secret() {
  local label="$1"
  local path="$2"
  local base
  base="$(basename "$path")"
  if ralph_basename_is_env_secret "$base"; then
    echo "Ralph safety: $label must not reference a .env* file path (blocked). Reading .env files is not permitted." >&2
    exit 1
  fi
}
