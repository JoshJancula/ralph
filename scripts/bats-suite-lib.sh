#!/usr/bin/env bash
# Bats suite file discovery for scripts/run-bats.sh

# Emit repo-relative paths (tests/bats/...), one per line.
# Recurses into all subdirs via find; excludes tests/bats/local/ (operator-only).
ralph_bats_suite_files() {
  local repo_root="${1:?repo root required}"
  local f rel
  while IFS= read -r f; do
    rel="${f#"$repo_root"/}"
    printf '%s\n' "$rel"
  done < <(find "$repo_root/tests/bats" -name "*.bats" -not -path "*/local/*" -type f | sort)
}
