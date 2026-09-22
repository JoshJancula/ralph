#!/usr/bin/env bash
# Refuse file paths whose final name matches .env* (same policy as .claude/hooks/block-env-reads.sh
# and AGENTS.md: agents and Ralph tooling must not read .env files).
#
# Carve-out: the Jev credential loader (bash-lib/jev/jev-key-store.sh) may extract exactly
# TYPESAFE_API_KEY from the workspace .env by parsing the file — never by sourcing or
# evaluating it. Agent reads of .env remain blocked by block-env-reads.sh; this library's
# ralph_assert_path_not_env_secret behavior is unchanged. Opt out with RALPH_JEV_ENV_FILE=0.

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
