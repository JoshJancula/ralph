#!/usr/bin/env bats

source "$BATS_TEST_DIRNAME/helper/load-lib.bash"

SCRIPT="$REPO_ROOT/bundle/.ralph/split-plan.sh"
HELPER="$REPO_ROOT/bundle/.ralph/bash-lib/plan-split.py"

setup() {
  TEST_TMPDIR="$(mktemp -d)"
  PLAN_FILE="$TEST_TMPDIR/PLAN.md"
}

teardown() {
  rm -rf "$TEST_TMPDIR"
}

@test "preflight classifies a normal single-goal TODO as ok" {
  command -v python3 >/dev/null || skip "python3 required"
  cat >"$PLAN_FILE" <<'EOF'
# Plan
- [ ] Update bundle/.ralph/run-plan.sh to document the split mode flag
EOF

  run python3 "$HELPER" split --plan "$PLAN_FILE" --json

  [ "$status" -eq 0 ]
  [[ "$output" == *'"status": "ok"'* ]]
}

@test "preflight classifies a large continuation block as too_broad" {
  command -v python3 >/dev/null || skip "python3 required"
  cat >"$PLAN_FILE" <<'EOF'
# Plan
- [ ] Implement the dashboard metrics update
  - Update ralph-dashboard/src/server/dashboard-api.ts
  - Update ralph-dashboard/src/app/components/usage-hub/usage-hub.component.ts
  - Update ralph-dashboard/src/app/components/plan-hub/plan-hub.component.ts
  - Update ralph-dashboard/tests/dashboard-api-metrics.test.ts
  - Update tests/bats/run-plan-invocation-usage.bats
  - Update README.md
  - Verification: npm test
EOF

  run env RALPH_PLAN_MAX_TODO_CONTINUATION_LINES=3 python3 "$HELPER" split --plan "$PLAN_FILE" --json

  [ "$status" -eq 0 ]
  [[ "$output" == *'"status": "too_broad"'* ]]
}

@test "adjacent tiny TODOs are not split further" {
  command -v python3 >/dev/null || skip "python3 required"
  cat >"$PLAN_FILE" <<'EOF'
# Plan
- [ ] Run `npm test`
- [ ] Run `npm run build`
EOF
  cp "$PLAN_FILE" "$TEST_TMPDIR/original.md"

  run bash "$SCRIPT" --plan "$PLAN_FILE" --out "$TEST_TMPDIR/out.md"

  [ "$status" -eq 0 ]
  cmp "$PLAN_FILE" "$TEST_TMPDIR/original.md"
  cmp "$PLAN_FILE" "$TEST_TMPDIR/out.md"
}

@test "command-only verification TODO is verification_only" {
  command -v python3 >/dev/null || skip "python3 required"
  cat >"$PLAN_FILE" <<'EOF'
# Plan
- [ ] Run `bats tests/bats/plan-split.bats`
EOF

  run python3 "$HELPER" split --plan "$PLAN_FILE" --json

  [ "$status" -eq 0 ]
  [[ "$output" == *'"status": "verification_only"'* ]]
}

@test "split-plan preview does not mutate the plan" {
  command -v python3 >/dev/null || skip "python3 required"
  cat >"$PLAN_FILE" <<'EOF'
# Plan
- [ ] Implement grouped edits
  - Update a.ts
  - Update b.ts
  - Update c.ts
  - Update d.ts
  - Verification: npm test
EOF
  cp "$PLAN_FILE" "$TEST_TMPDIR/original.md"

  run env RALPH_PLAN_MAX_TODO_CONTINUATION_LINES=2 bash "$SCRIPT" --plan "$PLAN_FILE"

  [ "$status" -eq 0 ]
  cmp "$PLAN_FILE" "$TEST_TMPDIR/original.md"
  [[ "$output" == *"Ralph split parent: line-2"* ]]
}

@test "split-plan output writes parent trace metadata" {
  command -v python3 >/dev/null || skip "python3 required"
  cat >"$PLAN_FILE" <<'EOF'
# Plan
- [ ] Implement grouped edits
  - Update a.ts
  - Update b.ts
  - Update c.ts
  - Update d.ts
  - Verification: npm test
EOF

  run env RALPH_PLAN_MAX_TODO_CONTINUATION_LINES=2 bash "$SCRIPT" --plan "$PLAN_FILE" --out "$TEST_TMPDIR/out.md"

  [ "$status" -eq 0 ]
  grep -q "Ralph split parent: line-2" "$TEST_TMPDIR/out.md"
  grep -q "Verification: npm test" "$TEST_TMPDIR/out.md"
}

@test "split-plan in-place preserves checked TODOs and headings" {
  command -v python3 >/dev/null || skip "python3 required"
  cat >"$PLAN_FILE" <<'EOF'
# Plan
- [x] Already done
## Work
- [ ] Implement grouped edits
  - Update a.ts
  - Update b.ts
  - Update c.ts
  - Update d.ts
  - Verification: npm test
EOF

  run env RALPH_PLAN_MAX_TODO_CONTINUATION_LINES=2 bash "$SCRIPT" --plan "$PLAN_FILE" --in-place

  [ "$status" -eq 0 ]
  grep -Fq -- "- [x] Already done" "$PLAN_FILE"
  grep -q "## Work" "$PLAN_FILE"
  grep -q "Ralph split parent: line-4" "$PLAN_FILE"
}
