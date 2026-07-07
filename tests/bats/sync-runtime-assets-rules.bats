#!/usr/bin/env bats

source "$BATS_TEST_DIRNAME/helper/load-lib.bash"

setup() {
  bats_skip_known_ci_flakes
  _tmp="$(mktemp -d)"
}

teardown() {
  rm -rf "${_tmp:-}"
}

_source_sync_lib() {
  export SCRIPT_DIR="$REPO_ROOT/scripts"
  # shellcheck disable=SC1090
  eval "$(sed '/^sync_assets_main "\$@"/d' "$REPO_ROOT/scripts/sync-runtime-assets.sh")"
  # Point the renderer at the temp fixture dir instead of the real repo.
  REPO_ROOT="$_tmp"
}

_write_always_on_rule() {
  cat >"$_tmp/rule.md" <<'EOF'
---
name: no-emoji
description: Do not use emojis in comments, logs, or code
globs: ["**/*"]
alwaysApply: true
---

# No emojis

Body content.
EOF
}

_write_scoped_rule() {
  cat >"$_tmp/rule.md" <<'EOF'
---
name: bash-style
description: Shell scripts must use set -euo pipefail
globs: ["**/*.sh", "**/*.bats"]
alwaysApply: false
---

# Bash style

Body content.
EOF
}

@test "claude always-apply rule omits paths and drops cursor keys" {
  _source_sync_lib
  _write_always_on_rule
  run sync_assets_render_rule_for_runtime claude "rule.md"
  [ "$status" -eq 0 ]
  [[ "$output" == *"name: no-emoji"* ]]
  [[ "$output" == *"description: Do not use emojis"* ]]
  [[ "$output" != *"paths:"* ]]
  [[ "$output" != *"globs:"* ]]
  [[ "$output" != *"alwaysApply:"* ]]
  [[ "$output" == *"GENERATED from rule.md"* ]]
  [[ "$output" == *"# No emojis"* ]]
}

@test "claude scoped rule emits paths block and drops cursor keys" {
  _source_sync_lib
  _write_scoped_rule
  run sync_assets_render_rule_for_runtime claude "rule.md"
  [ "$status" -eq 0 ]
  [[ "$output" == *"paths:"* ]]
  [[ "$output" == *'- "**/*.sh"'* ]]
  [[ "$output" == *'- "**/*.bats"'* ]]
  [[ "$output" != *"alwaysApply:"* ]]
  [[ "$output" != *'globs:'* ]]
}

@test "antigravity always-apply rule uses trigger always_on" {
  _source_sync_lib
  _write_always_on_rule
  run sync_assets_render_rule_for_runtime antigravity "rule.md"
  [ "$status" -eq 0 ]
  [[ "$output" == *"trigger: always_on"* ]]
  [[ "$output" != *"paths:"* ]]
  [[ "$output" != *"alwaysApply:"* ]]
}

@test "antigravity scoped rule uses trigger glob with globs block" {
  _source_sync_lib
  _write_scoped_rule
  run sync_assets_render_rule_for_runtime antigravity "rule.md"
  [ "$status" -eq 0 ]
  [[ "$output" == *"trigger: glob"* ]]
  [[ "$output" == *"globs:"* ]]
  [[ "$output" == *'- "**/*.sh"'* ]]
  [[ "$output" != *"alwaysApply:"* ]]
}

@test "cursor rule keeps verbatim globs and alwaysApply" {
  _source_sync_lib
  _write_scoped_rule
  run sync_assets_render_rule_for_runtime cursor "rule.md"
  [ "$status" -eq 0 ]
  [[ "$output" == *'globs: ["**/*.sh", "**/*.bats"]'* ]]
  [[ "$output" == *"alwaysApply: false"* ]]
  [[ "$output" != *"paths:"* ]]
  [[ "$output" != *"trigger:"* ]]
}

@test "codex and opencode rules stay verbatim (Ralph-internal schema)" {
  _source_sync_lib
  _write_scoped_rule
  for runtime in codex opencode; do
    run sync_assets_render_rule_for_runtime "$runtime" "rule.md"
    [ "$status" -eq 0 ]
    [[ "$output" == *'globs: ["**/*.sh", "**/*.bats"]'* ]]
    [[ "$output" == *"alwaysApply: false"* ]]
    [[ "$output" != *"trigger:"* ]]
  done
}
