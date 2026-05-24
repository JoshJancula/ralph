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

@test "get_next_todo skips comments and blank lines before the first open entry" {
  plan_file="$(mktemp)"
  cat <<'EOF' > "$plan_file"
# introduction
- [x] done already

# more context
- [ ] first open
- [ ] second
EOF
  result="$(get_next_todo "$plan_file")"
  [ "$result" = "5|- [ ] first open" ]
  rm "$plan_file"
}

@test "get_next_todo includes indented continuation lines in the todo block" {
  plan_file="$(mktemp)"
  cat <<'EOF' > "$plan_file"
# intro
- [ ] In `ui/src/app/components/admin-panel/admin-panel.component.html`, find the tab navigation section.
  1. Change the label of the `automation` tab button from `Hub` to `Automation`.
  2. Remove the entire `<button>` element for `agents`.
- [ ] next todo
EOF
  result="$(get_next_todo "$plan_file")"
  expected=$'4|- [ ] In `ui/src/app/components/admin-panel/admin-panel.component.html`, find the tab navigation section.\n  1. Change the label of the `automation` tab button from `Hub` to `Automation`.\n  2. Remove the entire `<button>` element for `agents`.'
  [ "$result" = "$expected" ]
  rm "$plan_file"
}

@test "plan_open_todo_body strips open checkbox prefix" {
  [ "$(plan_open_todo_body '- [ ] do thing')" = "do thing" ]
}

@test "plan_open_todo_body keeps inline text and trims whitespace" {
  result="$(plan_open_todo_body '  - [ ]  update docs  # inline note  ')"
  [ "$result" = "update docs  # inline note" ]
}

@test "plan_todo_has_continuation_lines detects multiline todo blocks" {
  plan_todo_has_continuation_lines $'top line\n  second line'
  run plan_todo_has_continuation_lines 'single line only'
  [ "$status" -ne 0 ]
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

@test "plan_todo_ordinal_at_line is 1-based file order through line" {
  plan_file="$(mktemp)"
  cat <<'EOF' > "$plan_file"
intro
- [x] first
- [x] second
- [ ] third
- [ ] fourth
EOF
  [ "$(plan_todo_ordinal_at_line "$plan_file" 4)" = "3" ]
  [ "$(plan_todo_ordinal_at_line "$plan_file" 2)" = "1" ]
  rm "$plan_file"
}

@test "plan_todo_ordinal_for_next uses get_next first field for cursor (YAML ordinal not file line)" {
  plan_file="$(mktemp)"
  cat <<'EOF' > "$plan_file"
---
todos:
  - content: done
    status: completed
  - content: current
    status: pending
---
# many body lines so file line 3 is not third checklist item
line2
line3
line4
line5
EOF
  [ "$(plan_todo_ordinal_at_line "$plan_file" 3)" = "0" ]
  [ "$(plan_todo_ordinal_for_next "$plan_file" "cursor" "2")" = "2" ]
  rm "$plan_file"
}

@test "plan_todo_ordinal_for_next matches ordinal-at-line for default markdown" {
  plan_file="$(mktemp)"
  cat <<'EOF' > "$plan_file"
intro
- [x] first
- [ ] second
EOF
  want="$(plan_todo_ordinal_at_line "$plan_file" 3)"
  [ "$(plan_todo_ordinal_for_next "$plan_file" "default" "3")" = "$want" ]
  rm "$plan_file"
}

@test "plan_todo_implies_operator_dialog matches ask the user" {
  plan_todo_implies_operator_dialog "Ask the user if they want to run tests."
  plan_todo_implies_operator_dialog "ask the user for approval"
  run plan_todo_implies_operator_dialog "Tell the user to have a nice day."
  [ "$status" -ne 0 ]
}

@test "plan_detect_format recognizes cursor frontmatter" {
  plan_file="$(mktemp)"
  cat <<'EOF' > "$plan_file"
---
todos:
  - id: one
    content: do thing
    status: pending
---
# heading
EOF
  [ "$(plan_detect_format "$plan_file")" = "cursor" ]
  rm "$plan_file"
}

@test "get_next_todo cursor frontmatter returns exit 0 when a todo is pending" {
  plan_file="$(mktemp)"
  cat <<'EOF' > "$plan_file"
---
todos:
  - id: one
    content: do thing
    status: pending
---
# heading
EOF
  run get_next_todo "$plan_file"
  [ "$status" -eq 0 ]
  [ "$output" = "1|do thing" ]
  rm "$plan_file"
}

@test "plan_todo_risk_classify covers the major gate types" {
  [ "$(plan_todo_risk_classify 'Please ask the user for approval.')" = "manual_gate" ]
  [ "$(plan_todo_risk_classify 'Verification: run npm test && npm run lint')" = "verification_gate" ]
  [ "$(plan_todo_risk_classify 'Delete the migration after release.')" = "destructive_gate" ]
  [ "$(plan_todo_risk_classify 'Add implementation coverage for the helper.')" = "implementation_gate" ]
  [ "$(plan_todo_risk_classify 'Document the rollout procedure.')" = "normal" ]
}

@test "plan_todo_risk_classify does not treat file path references as verification commands" {
  [ "$(plan_todo_risk_classify 'In `ui/src/app/components/admin-panel/admin-panel.component.html`, change the button label.')" = "implementation_gate" ]
}

@test "plan_todo_risk_classify treats explicit edit instructions as implementation work" {
  [ "$(plan_todo_risk_classify 'In `ui/src/app/components/admin-panel/admin-panel.component.html`, make these exact changes.')" = "implementation_gate" ]
}

@test "plan_todo_extract_verification_commands finds command evidence candidates" {
  result="$(plan_todo_extract_verification_commands 'Verification: run npm test && npm run lint with `git status --short`')"
  [[ "$result" == *"run npm test && npm run lint"* ]]
  [[ "$result" == *"git status --short"* ]]
}

@test "plan_todo_autonomous_evidence_present recognizes verified test output" {
  plan_todo_autonomous_evidence_present "VERIFIED: playwright test passed with exit 0"
  plan_todo_autonomous_evidence_present "unit tests passed"
  [ "$(plan_todo_autonomous_evidence_present 'assistant summarized a plan without evidence')" = "0" ]
}

@test "plan_todo_hash is stable for the same content" {
  first="$(plan_todo_hash 'sample todo text')"
  second="$(plan_todo_hash 'sample todo text')"
  [ "$first" = "$second" ]
}

@test "plan_reopen_todo_at_line turns [x] into [ ] on that line" {
  plan_file="$(mktemp)"
  cat <<'EOF' > "$plan_file"
- [x] done
- [x] reopen me
- [ ] next
EOF
  plan_reopen_todo_at_line "$plan_file" 2
  line2="$(sed -n '2p' "$plan_file")"
  [[ "$line2" == "- [ ] reopen me" ]]
  rm "$plan_file"
}

@test "plan_reopen_todo_cursor returns a pending cursor todo to pending" {
  plan_file="$(mktemp)"
  cat <<'EOF' > "$plan_file"
---
todos:
  - id: one
    content: do thing
    status: completed
---
# heading
EOF
  plan_reopen_todo_cursor "$plan_file" "do thing"
  [ "$(grep -c '^    status: pending$' "$plan_file")" -eq 1 ]
  rm "$plan_file"
}

@test "plan_reopen_todo_at_line fails when the specified line is not closed" {
  plan_file="$(mktemp)"
  cat <<'EOF' > "$plan_file"
- [ ] still open
- [x] done
EOF
  run plan_reopen_todo_at_line "$plan_file" 1
  [ "$status" -ne 0 ]
  [ "$(sed -n '1p' "$plan_file")" = "- [ ] still open" ]
  [ "$(sed -n '2p' "$plan_file")" = "- [x] done" ]
  rm "$plan_file"
}
