#!/usr/bin/env bats

source "$BATS_TEST_DIRNAME/../helper/load-lib.bash"

@test "repo root runtime directories are not symlinks to bundle" {
  local rt
  for rt in claude codex cursor opencode; do
    [ -e "$REPO_ROOT/.$rt" ]
    [ ! -L "$REPO_ROOT/.$rt" ]
    [ -d "$REPO_ROOT/.$rt" ]
  done
}

@test "repo root runtime directories are separate from bundle directories" {
  local rt root_real bundle_real
  for rt in claude codex cursor opencode; do
    root_real="$(cd "$REPO_ROOT/.$rt" && pwd -P)"
    bundle_real="$(cd "$REPO_ROOT/bundle/.$rt" && pwd -P)"
    [ "$root_real" != "$bundle_real" ]
  done
}

@test "repo root claude hooks exist as real files" {
  [ -f "$REPO_ROOT/.claude/hooks/compact-bash-output.sh" ]
  [ -f "$REPO_ROOT/.claude/hooks/rewrite-bash-command.sh" ]
  [ ! -L "$REPO_ROOT/.claude/hooks/compact-bash-output.sh" ]
}
