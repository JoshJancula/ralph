#!/usr/bin/env bats

source "$BATS_TEST_DIRNAME/../helper/load-lib.bash"
source "$BATS_TEST_DIRNAME/../../../bundle/.ralph/bash-lib/plan-todo.sh"

setup() {
  TEST_TMPDIR="$(mktemp -d)"
  PLAN_FILE="$TEST_TMPDIR/PLAN.md"
  SESSION_DIR="$TEST_TMPDIR/session"
  mkdir -p "$SESSION_DIR"
}

teardown() {
  rm -rf "$TEST_TMPDIR"
}

require_python_yaml() {
  command -v python3 >/dev/null || skip "python3 is required for consolidation tests"
  python3 -c 'import yaml' >/dev/null 2>&1 || skip "PyYAML is required for merge tests"
}

consolidate_plan() {
  RALPH_SESSION_DIR="$SESSION_DIR" ralph_run_plan_consolidate_todos "$PLAN_FILE"
}

@test "default off does not modify the file" {
  cat >"$PLAN_FILE" <<'EOF'
# Plan
- [ ] Edit bundle/.ralph/bash-lib/plan-todo.sh to add consolidation logging
- [ ] Edit bundle/.ralph/bash-lib/plan-todo.sh to preserve headings
EOF
  cp "$PLAN_FILE" "$TEST_TMPDIR/original.md"

  run bash -c '
    set -euo pipefail
    source "$1"
    if [[ "${RALPH_PLAN_CONSOLIDATE:-0}" == "1" ]]; then
      RALPH_SESSION_DIR="$3" ralph_run_plan_consolidate_todos "$2"
    fi
  ' _ "$BATS_TEST_DIRNAME/../../../bundle/.ralph/bash-lib/plan-todo.sh" "$PLAN_FILE" "$SESSION_DIR"

  [ "$status" -eq 0 ]
  cmp "$TEST_TMPDIR/original.md" "$PLAN_FILE"
}

@test "mergeable adjacent todos collapse into one todo" {
  require_python_yaml
  cat >"$PLAN_FILE" <<'EOF'
# Plan
- [ ] Edit bundle/.ralph/bash-lib/plan-todo.sh to add consolidation logging
- [ ] Edit bundle/.ralph/bash-lib/plan-todo.sh to preserve headings
- [ ] Edit bundle/.ralph/bash-lib/plan-todo.sh to skip checked todos
- [ ] Update README.md to mention consolidation
EOF

  run consolidate_plan

  [ "$status" -eq 0 ]
  cat >"$TEST_TMPDIR/expected.md" <<'EOF'
# Plan
- [ ] Edit bundle/.ralph/bash-lib/plan-todo.sh: add consolidation logging; preserve headings; skip checked todos
- [ ] Update README.md to mention consolidation
EOF
  cmp "$TEST_TMPDIR/expected.md" "$PLAN_FILE"
}

@test "non-mergeable adjacent todos are left alone" {
  require_python_yaml
  cat >"$PLAN_FILE" <<'EOF'
# Plan
- [ ] Edit bundle/.ralph/bash-lib/plan-todo.sh to add consolidation logging
- [ ] Update bundle/.ralph/bash-lib/plan-todo.sh to preserve headings
- [ ] Edit bundle/.ralph/run-plan.sh to surface the flag
EOF
  cp "$PLAN_FILE" "$TEST_TMPDIR/original.md"

  run consolidate_plan

  [ "$status" -eq 0 ]
  cmp "$TEST_TMPDIR/original.md" "$PLAN_FILE"
}

@test "checked todos never merge with unchecked todos" {
  require_python_yaml
  cat >"$PLAN_FILE" <<'EOF'
# Plan
- [ ] Edit bundle/.ralph/bash-lib/plan-todo.sh to add consolidation logging
- [x] Edit bundle/.ralph/bash-lib/plan-todo.sh to preserve headings
- [ ] Edit bundle/.ralph/bash-lib/plan-todo.sh to skip checked todos
EOF
  cp "$PLAN_FILE" "$TEST_TMPDIR/original.md"

  run consolidate_plan

  [ "$status" -eq 0 ]
  cmp "$TEST_TMPDIR/original.md" "$PLAN_FILE"
}

@test "markdown consolidation does not merge across headings or blank lines" {
  require_python_yaml
  cat >"$PLAN_FILE" <<'EOF'
# Plan
- [ ] Edit bundle/.ralph/bash-lib/plan-todo.sh to add consolidation logging

- [ ] Edit bundle/.ralph/bash-lib/plan-todo.sh to preserve headings
## Later
- [ ] Edit bundle/.ralph/bash-lib/plan-todo.sh to skip checked todos
EOF
  cp "$PLAN_FILE" "$TEST_TMPDIR/original.md"

  run consolidate_plan

  [ "$status" -eq 0 ]
  cmp "$TEST_TMPDIR/original.md" "$PLAN_FILE"
}

@test "cursor frontmatter preserves body bytes outside the todo block" {
  require_python_yaml
  cat >"$PLAN_FILE" <<'EOF'
---
todos:
  - id: "1"
    content: "Edit bundle/.ralph/bash-lib/plan-todo.sh to add consolidation logging"
    status: pending
  - id: "2"
    content: "Edit bundle/.ralph/bash-lib/plan-todo.sh to preserve headings"
    status: pending
---
# Body

Keep this body unchanged.
- Not a checkbox todo in frontmatter.
EOF
  cat >"$TEST_TMPDIR/expected-body.md" <<'EOF'
# Body

Keep this body unchanged.
- Not a checkbox todo in frontmatter.
EOF

  run consolidate_plan

  [ "$status" -eq 0 ]
  awk 'BEGIN { markers=0 } /^---$/ { markers++; if (markers == 2) { next } } markers >= 2 { print }' "$PLAN_FILE" >"$TEST_TMPDIR/body.md"
  cmp "$TEST_TMPDIR/expected-body.md" "$TEST_TMPDIR/body.md"
  grep -Fq 'Edit bundle/.ralph/bash-lib/plan-todo.sh: add consolidation logging; preserve headings' "$PLAN_FILE"
}

@test "consolidation log is written" {
  require_python_yaml
  cat >"$PLAN_FILE" <<'EOF'
# Plan
- [ ] Edit bundle/.ralph/bash-lib/plan-todo.sh to add consolidation logging
- [ ] Edit bundle/.ralph/bash-lib/plan-todo.sh to preserve headings
EOF

  run consolidate_plan

  [ "$status" -eq 0 ]
  [ -s "$SESSION_DIR/consolidation-log.txt" ]
  grep -Fq "merged 1 group(s)" "$SESSION_DIR/consolidation-log.txt"
}

@test "PyYAML-missing path no-ops with a warning" {
  command -v python3 >/dev/null || skip "python3 is required for PyYAML warning test"
  cat >"$PLAN_FILE" <<'EOF'
# Plan
- [ ] Edit bundle/.ralph/bash-lib/plan-todo.sh to add consolidation logging
- [ ] Edit bundle/.ralph/bash-lib/plan-todo.sh to preserve headings
EOF
  cp "$PLAN_FILE" "$TEST_TMPDIR/original.md"
  mkdir -p "$TEST_TMPDIR/no-yaml"
  printf '%s\n' 'raise ImportError("blocked PyYAML for test")' >"$TEST_TMPDIR/no-yaml/yaml.py"

  run env PYTHONPATH="$TEST_TMPDIR/no-yaml" bash -c '
    set -euo pipefail
    source "$1"
    RALPH_SESSION_DIR="$3" ralph_run_plan_consolidate_todos "$2"
  ' _ "$BATS_TEST_DIRNAME/../../../bundle/.ralph/bash-lib/plan-todo.sh" "$PLAN_FILE" "$SESSION_DIR"

  [ "$status" -eq 0 ]
  [[ "$output" == *"Warning: todo consolidation requires PyYAML (missing); skipping"* ]]
  cmp "$TEST_TMPDIR/original.md" "$PLAN_FILE"
  grep -Fq "PyYAML not found, consolidation skipped" "$SESSION_DIR/consolidation-log.txt"
}
