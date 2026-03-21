#!/usr/bin/env bats

source "$BATS_TEST_DIRNAME/helper/load-lib.bash"
source "$BATS_TEST_DIRNAME/../../bundle/.ralph/bash-lib/plan-todo.sh"

@test "plan_normalize_path resolves relative to workspace" {
  workspace="/tmp/ralph-ws"
  result="$(plan_normalize_path docs/plan.md "$workspace")"
  [ "$result" = "$workspace/docs/plan.md" ]
}

@test "plan_normalize_path expands tilde paths" {
  old_home="$HOME"
  export HOME="/tmp/ralph-home"
  result="$(plan_normalize_path "~/plan.md" "")"
  [ "$result" = "/tmp/ralph-home/plan.md" ]
  export HOME="$old_home"
}

@test "plan_log_basename strips extension and sanitizes" {
  result="$(plan_log_basename "docs/my plan.md")"
  [ "$result" = "my_plan" ]
}

@test "get_next_todo returns first unchecked entry" {
  plan_file="$(mktemp)"
  cat <<'EOF' > "$plan_file"
- [x] done
- [ ] first
- [ ] second
EOF
  result="$(get_next_todo "$plan_file")"
  [ "$result" = "2|- [ ] first" ]
  rm "$plan_file"
}

@test "get_next_todo ignores hyphen empty-bracket lines (not task syntax)" {
  plan_file="$(mktemp)"
  cat <<'EOF' > "$plan_file"
- [x] done
- [] empty-array note in prose
EOF
  run get_next_todo "$plan_file"
  [ "$status" -ne 0 ]
  rm "$plan_file"
}

@test "plan_open_todo_body strips open checkbox prefix" {
  [ "$(plan_open_todo_body '- [ ] do thing')" = "do thing" ]
}

@test "get_next_todo fails when no unchecked entries" {
  plan_file="$(mktemp)"
  cat <<'EOF' > "$plan_file"
- [x] done
- [x] done too
EOF
  run get_next_todo "$plan_file"
  [ "$status" -ne 0 ]
  rm "$plan_file"
}

@test "count_todos reports done and total" {
  plan_file="$(mktemp)"
  cat <<'EOF' > "$plan_file"
- [ ] todo
- [x] done
- [x] another
- [ ] final
EOF
  result="$(count_todos "$plan_file")"
  [ "$result" = "2 4" ]
  rm "$plan_file"
}

@test "count_todos does not count hyphen empty-bracket lines" {
  plan_file="$(mktemp)"
  cat <<'EOF' > "$plan_file"
- [x] done
- [] not a task
EOF
  result="$(count_todos "$plan_file")"
  [ "$result" = "1 1" ]
  rm "$plan_file"
}
