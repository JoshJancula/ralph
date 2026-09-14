#!/usr/bin/env bats

source "$BATS_TEST_DIRNAME/../helper/load-lib.bash"
source "$BATS_TEST_DIRNAME/../../../bundle/.ralph/bash-lib/plan-todo.sh"
export RALPH_RUN_PLAN_LIBRARY_ONLY=1
source "$BATS_TEST_DIRNAME/../../../bundle/.ralph/bash-lib/run-plan/run-plan-core.sh"
unset RALPH_RUN_PLAN_LIBRARY_ONLY

json_field() {
  # Bats merges stderr warnings into $output; take the final JSON payload line.
  printf '%s\n' "$1" | awk 'END{print}' | jq -r "$2"
}

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
  expected=$'2|- [ ] In `ui/src/app/components/admin-panel/admin-panel.component.html`, find the tab navigation section.\n  1. Change the label of the `automation` tab button from `Hub` to `Automation`.\n  2. Remove the entire `<button>` element for `agents`.'
  [ "$result" = "$expected" ]
  rm "$plan_file"
}

@test "get_next_todo returns the checkbox line even when a blank separator follows" {
  plan_file="$(mktemp)"
  cat <<'EOF' > "$plan_file"
# intro
- [ ] first todo

- [ ] second todo
EOF
  result="$(get_next_todo "$plan_file")"
  [ "$result" = "2|- [ ] first todo" ]
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

@test "plan_detect_format recognizes yaml frontmatter" {
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
  [ "$(plan_detect_format "$plan_file")" = "yaml" ]
  rm "$plan_file"
}

@test "plan_detect_format normalizes RALPH_PLAN_FORMAT cursor alias to yaml" {
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
  [ "$(RALPH_PLAN_FORMAT=yaml plan_detect_format "$plan_file")" = "yaml" ]
  [ "$(RALPH_PLAN_FORMAT=cursor plan_detect_format "$plan_file")" = "yaml" ]
  rm "$plan_file"
}

@test "plan_format_display maps yaml and cursor aliases to yaml" {
  [ "$(plan_format_display yaml)" = "yaml" ]
  [ "$(plan_format_display cursor)" = "yaml" ]
  [ "$(plan_format_display default)" = "default" ]
  [ "$(plan_format_display)" = "default" ]
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
  [ "$output" = "1|one|do thing" ]
  rm "$plan_file"
}

@test "get_next_todo cursor frontmatter preserves item-line block scalar content" {
  plan_file="$(mktemp)"
  cat <<'EOF' > "$plan_file"
---
todos:
  - id: one
    content: |
      first line
      - nested bullet
      second line
    status: pending
---
# heading
EOF
  run get_next_todo "$plan_file"
  [ "$status" -eq 0 ]
  [ "$output" = $'1|one|first line\n- nested bullet\nsecond line' ]
  rm "$plan_file"
}

@test "get_next_todo cursor frontmatter skips completed status synonyms" {
  plan_file="$(mktemp)"
  cat <<'EOF' > "$plan_file"
---
todos:
  - id: one
    content: done item
    status: completed
  - id: two
    content: skipped item
    status: done
  - id: three
    content: uppercase item
    status: COMPLETED
  - id: four
    content: next item
    status: pending
---
# heading
EOF
  result="$(get_next_todo "$plan_file")"
  [ "$result" = "4|four|next item" ]
  [ "$(count_todos "$plan_file")" = "3 4" ]
  rm "$plan_file"
}

@test "plan_cursor_frontmatter_op get_verification returns verification text for matching id" {
  plan_file="$(mktemp)"
  cat <<'EOF' > "$plan_file"
---
todos:
  - id: one
    content: do thing
    verification: run bats tests/bats/plan/plan-todo.bats
    status: pending
---
# heading
EOF
  [ "$(plan_cursor_frontmatter_op "$plan_file" get_verification "one")" = "run bats tests/bats/plan/plan-todo.bats" ]
  run plan_cursor_frontmatter_op "$plan_file" get_verification "missing"
  [ "$status" -ne 0 ]
  rm "$plan_file"
}

@test "plan_cursor_frontmatter_op get_verify returns strict verify text for matching id" {
  plan_file="$(mktemp)"
  cat <<'EOF' > "$plan_file"
---
todos:
  - id: one
    content: do thing
    verify: bash scripts/run-bats.sh
    status: pending
---
# heading
EOF
  [ "$(plan_cursor_frontmatter_op "$plan_file" get_verify "one")" = "bash scripts/run-bats.sh" ]
  run plan_cursor_frontmatter_op "$plan_file" get_verify "missing"
  [ "$status" -ne 0 ]
  rm "$plan_file"
}

@test "plan_cursor_frontmatter_op get_verification preserves block scalar text" {
  plan_file="$(mktemp)"
  cat <<'EOF' > "$plan_file"
---
todos:
  - id: one
    content: do thing
    verification: |
      bash -n bundle/.ralph/bash-lib/plan-todo.sh
      bats tests/bats/plan/plan-todo.bats
    status: pending
---
# heading
EOF
  [ "$(
    plan_cursor_frontmatter_op "$plan_file" get_verification "one"
  )" = $'bash -n bundle/.ralph/bash-lib/plan-todo.sh\nbats tests/bats/plan/plan-todo.bats' ]
  rm "$plan_file"
}

@test "plan_cursor_frontmatter_op get_verify preserves block scalar text" {
  plan_file="$(mktemp)"
  cat <<'EOF' > "$plan_file"
---
todos:
  - id: one
    content: do thing
    verify: |
      bash scripts/run-bats.sh
      bats tests/bats/plan/plan-todo.bats
    status: pending
---
# heading
EOF
  [ "$(
    plan_cursor_frontmatter_op "$plan_file" get_verify "one"
  )" = $'bash scripts/run-bats.sh\nbats tests/bats/plan/plan-todo.bats' ]
  rm "$plan_file"
}

@test "plan_cursor_frontmatter_op set_status preserves verification lines" {
  plan_file="$(mktemp)"
  cat <<'EOF' > "$plan_file"
---
todos:
  - id: one
    content: do thing
    verification: run bats tests/bats/plan/plan-todo.bats
    status: pending
  - id: two
    content: next thing
    verification: inspect generated output
    status: pending
---
# heading
EOF
  plan_cursor_frontmatter_op "$plan_file" set_status "one" "completed"
  [ "$(plan_cursor_frontmatter_op "$plan_file" get_verification "one")" = "run bats tests/bats/plan/plan-todo.bats" ]
  [ "$(plan_cursor_frontmatter_op "$plan_file" get_verification "two")" = "inspect generated output" ]
  [ "$(grep -c '^    verification:' "$plan_file")" -eq 2 ]
  [ "$(grep -c '^    status: completed$' "$plan_file")" -eq 1 ]
  [ "$(grep -c '^    status: pending$' "$plan_file")" -eq 1 ]
  rm "$plan_file"
}

@test "plan_cursor_frontmatter_op set_status marks the matching id when content is duplicated" {
  plan_file="$(mktemp)"
  cat <<'EOF' > "$plan_file"
---
todos:
  - id: alpha
    content: duplicate task
    status: pending
  - id: beta
    content: duplicate task
    status: pending
---
# heading
  EOF
  plan_cursor_frontmatter_op "$plan_file" set_status "beta" "completed"
  [ "$(grep -c '^    status: completed$' "$plan_file")" -eq 1 ]
  [ "$(grep -n '^  - id: beta$' "$plan_file" | cut -d: -f1)" = "6" ]
  rm "$plan_file"
}

@test "plan_cursor_frontmatter_op set_status falls back to ordinal when ids are absent" {
  plan_file="$(mktemp)"
  cat <<'EOF' > "$plan_file"
---
todos:
  - content: one
    status: pending
  - content: two
    status: pending
---
# heading
  EOF
  plan_cursor_frontmatter_op "$plan_file" set_status "2" "completed"
  [ "$(grep -c '^    status: completed$' "$plan_file")" -eq 1 ]
  [ "$(grep -n '^    status: completed$' "$plan_file" | cut -d: -f1)" = "6" ]
  rm "$plan_file"
}

@test "plan_cursor_frontmatter_op set_status rejects unknown and duplicate ids without changing the file" {
  plan_file="$(mktemp)"
  cat <<'EOF' > "$plan_file"
---
todos:
  - id: alpha
    content: one
    status: pending
  - id: beta
    content: two
    status: pending
---
# heading
EOF
  original_hash="$(sha256sum "$plan_file" | awk '{print $1}')"
  run plan_cursor_frontmatter_op "$plan_file" set_status "missing" "completed"
  [ "$status" -ne 0 ]
  [ "$(sha256sum "$plan_file" | awk '{print $1}')" = "$original_hash" ]
  cat <<'EOF' > "$plan_file"
---
todos:
  - id: alpha
    content: one
    status: pending
  - id: alpha
    content: two
    status: pending
---
# heading
EOF
  original_hash="$(sha256sum "$plan_file" | awk '{print $1}')"
  run plan_cursor_frontmatter_op "$plan_file" set_status "alpha" "completed"
  [ "$status" -ne 0 ]
  [ "$(sha256sum "$plan_file" | awk '{print $1}')" = "$original_hash" ]
  rm "$plan_file"
}

@test "plan_cursor_frontmatter_op set_status stays byte-stable across repeated rewrites" {
  plan_file="$(mktemp)"
  original_file="$(mktemp)"
  cat <<'EOF' > "$plan_file"
---
name: sample
todos:
  - id: one
    content: do thing
    status: pending
  - id: two
    content: next thing
    status: pending
---
# heading
EOF
  cp "$plan_file" "$original_file"
  plan_cursor_frontmatter_op "$plan_file" set_status "one" "completed"
  plan_cursor_frontmatter_op "$plan_file" set_status "one" "completed"
  run diff -u "$original_file" "$plan_file"
  [ "$status" -eq 1 ]
  [[ "$output" == *"    status: completed"* ]]
  [[ "$output" != *$'\n\n'* ]]
  [ "$(head -3 "$plan_file")" = $'---\nname: sample\ntodos:' ]
  rm "$plan_file" "$original_file"
}

@test "run_plan_mark_and_confirm advances three todos for default and cursor plans" {
  export RALPH_RUN_PLAN_LIBRARY_ONLY=1
  source "$BATS_TEST_DIRNAME/../../../bundle/.ralph/bash-lib/run-plan/run-plan-core.sh"
  unset RALPH_RUN_PLAN_LIBRARY_ONLY

  for format in default cursor; do
    plan_file="$(mktemp)"
    if [[ "$format" == "default" ]]; then
      cat <<'EOF' > "$plan_file"
- [ ] alpha
- [ ] beta
- [ ] gamma
EOF
    else
      cat <<'EOF' > "$plan_file"
---
todos:
  - id: alpha
    content: alpha
    status: pending
  - id: beta
    content: beta
    status: pending
  - id: gamma
    content: gamma
    status: pending
---
# heading
EOF
    fi

    run get_next_todo "$plan_file"
    [ "$status" -eq 0 ]
    if [[ "$format" == "default" ]]; then
      first_field="${output%%|*}"
      target="$first_field"
    else
      first_field="${output%%|*}"
      rest="${output#*|}"
      todo_id="${rest%%|*}"
      target="${todo_id:-$first_field}"
    fi
    if run_plan_mark_and_confirm "$plan_file" "$format" "$target" "$first_field"; then
      mark_status=0
    else
      mark_status=$?
    fi
    [ "$mark_status" -eq 0 ]

    run get_next_todo "$plan_file"
    [ "$status" -eq 0 ]
    if [[ "$format" == "default" ]]; then
      first_field="${output%%|*}"
      target="$first_field"
    else
      first_field="${output%%|*}"
      rest="${output#*|}"
      todo_id="${rest%%|*}"
      target="${todo_id:-$first_field}"
    fi
    if run_plan_mark_and_confirm "$plan_file" "$format" "$target" "$first_field"; then
      mark_status=0
    else
      mark_status=$?
    fi
    [ "$mark_status" -eq 0 ]

    run get_next_todo "$plan_file"
    [ "$status" -eq 0 ]
    if [[ "$format" == "default" ]]; then
      first_field="${output%%|*}"
      target="$first_field"
    else
      first_field="${output%%|*}"
      rest="${output#*|}"
      todo_id="${rest%%|*}"
      target="${todo_id:-$first_field}"
    fi
    if run_plan_mark_and_confirm "$plan_file" "$format" "$target" "$first_field"; then
      mark_status=0
    else
      mark_status=$?
    fi
    [ "$mark_status" -eq 0 ]

    run get_next_todo "$plan_file"
    [ "$status" -ne 0 ]
    rm "$plan_file"
  done
}

@test "run_plan_mark_and_confirm reports integrity failure when the same todo remains open" {
  export RALPH_RUN_PLAN_LIBRARY_ONLY=1
  source "$BATS_TEST_DIRNAME/../../../bundle/.ralph/bash-lib/run-plan/run-plan-core.sh"
  unset RALPH_RUN_PLAN_LIBRARY_ONLY

  plan_file="$(mktemp)"
  cat <<'EOF' > "$plan_file"
---
todos:
  - id: one
    content: do thing
---
# heading
EOF
  run get_next_todo "$plan_file"
  [ "$status" -eq 0 ]
  first_field="${output%%|*}"
  rest="${output#*|}"
  todo_id="${rest%%|*}"
  if run_plan_mark_and_confirm "$plan_file" "cursor" "$todo_id" "$first_field"; then
    mark_status=0
  else
    mark_status=$?
  fi
  [ "$mark_status" -eq 5 ]
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

@test "plan_todo_extract_verification_commands only emits strict Verify commands" {
  result="$(plan_todo_extract_verification_commands $'Verification: run npm test && npm run lint with `git status --short`\nVerify: npm test')"
  [ "$result" = "npm test" ]
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
  plan_reopen_todo_cursor "$plan_file" "one"
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

@test "get_next_todo structured plan never returns bare | pipe character for block scalar content" {
  plan_file="$(mktemp)"
  cat <<'EOF' > "$plan_file"
---
todos:
  - id: test-multiline
    content: |
      This is a multiline todo body
      with multiple lines of important text
      that should all be returned together
    status: pending
---
# heading
EOF
  run get_next_todo "$plan_file"
  [ "$status" -eq 0 ]
  output_content="${output#*|*|}"
  [ -n "$output_content" ]
  [ "$output_content" != "|" ]
  [ "$output_content" != "" ]
  [[ ! "$output_content" =~ ^\|$ ]]
  [[ "$output_content" == *"This is a multiline"* ]]
  [[ "$output_content" == *"multiple lines"* ]]
  rm "$plan_file"
}

@test "get_next_todo structured plan returns full block scalar content with all lines intact" {
  plan_file="$(mktemp)"
  cat <<'EOF' > "$plan_file"
---
todos:
  - id: complex-todo
    content: |
      Line one: setup
      Line two: execute
      Line three: verify
    status: pending
---
# heading
EOF
  run get_next_todo "$plan_file"
  [ "$status" -eq 0 ]
  expected=$'1|complex-todo|Line one: setup\nLine two: execute\nLine three: verify'
  [ "$output" = "$expected" ]
  rm "$plan_file"
}

@test "get_next_todo structured plan with empty lines in block scalar preserves them" {
  plan_file="$(mktemp)"
  cat <<'EOF' > "$plan_file"
---
todos:
  - id: with-blank-lines
    content: |
      First paragraph line

      Second paragraph line
    status: pending
---
# heading
EOF
  run get_next_todo "$plan_file"
  [ "$status" -eq 0 ]
  output_content="${output#*|*|}"
  [[ "$output_content" == *"First paragraph"* ]]
  [[ "$output_content" == *"Second paragraph"* ]]
  [ -n "$output_content" ]
  [ "$output_content" != "|" ]
  rm "$plan_file"
}

@test "plan_pipeline_todo_metadata_json and effective metadata inherit stage defaults and merge artifacts" {
  plan_file="$(mktemp)"
  cat <<'EOF' > "$plan_file"
---
execution: orchestration
pipeline:
  stages:
    - id: review
      runtime: codex
      model: gpt-5
      sessionStrategy: resume
      contextBudget: lean
      requires:
        - path: shared/input.md
      produces:
        - path: shared/output.md
  parallelStages:
    - [review]
todos:
  - id: review-1
    stage: review
    content: |
      Review the change.
    verification: confirm outputs
    status: pending
    requires:
      - path: todo/input.md
    produces:
      - path: todo/output.md
---
EOF

  run plan_pipeline_todo_metadata_json "$plan_file" review-1
  [ "$status" -eq 0 ]
  [ "$(json_field "$output" '.todoId')" = "review-1" ]
  [ "$(json_field "$output" '.stage')" = "review" ]
  [ "$(json_field "$output" '.runtime')" = "" ]
  [ "$(json_field "$output" '.sessionStrategy')" = "" ]
  [ "$(json_field "$output" '.requires | length')" = "1" ]
  [ "$(json_field "$output" '.requires[0].path')" = "todo/input.md" ]
  [ "$(json_field "$output" '.produces[0].path')" = "todo/output.md" ]

  run plan_pipeline_effective_metadata_json "$plan_file" review-1
  [ "$status" -eq 0 ]
  [ "$(json_field "$output" '.runtime')" = "codex" ]
  [ "$(json_field "$output" '.model')" = "gpt-5" ]
  [ "$(json_field "$output" '.sessionStrategy')" = "resume" ]
  [ "$(json_field "$output" '.contextBudget')" = "lean" ]
  [ "$(json_field "$output" '.requires | length')" = "2" ]
  [ "$(json_field "$output" '.requires[0].path')" = "shared/input.md" ]
  [ "$(json_field "$output" '.requires[1].path')" = "todo/input.md" ]
  [ "$(json_field "$output" '.produces | length')" = "2" ]
  [ "$(json_field "$output" '.produces[0].path')" = "shared/output.md" ]
  [ "$(json_field "$output" '.produces[1].path')" = "todo/output.md" ]
  rm "$plan_file"
}

@test "plan pipeline parallel metadata accepts array-of-arrays stage waves" {
  plan_file="$(mktemp)"
  cat <<'EOF' > "$plan_file"
---
execution: orchestration
pipeline:
  stages:
    - id: research
      runtime: cursor
    - id: review
      runtime: codex
    - id: qa
      runtime: claude
  parallelStages:
    - [research, review]
    - [qa]
todos:
  - id: research-1
    stage: research
    content: Research the change.
    verification: confirm notes
    status: pending
---
EOF

  run plan_pipeline_todo_metadata_json "$plan_file" research-1
  [ "$status" -eq 0 ]
  [ "$(json_field "$output" '.todoId')" = "research-1" ]

  run plan_pipeline_effective_metadata_json "$plan_file" research-1
  [ "$status" -eq 0 ]
  [ "$(json_field "$output" '.runtime')" = "cursor" ]
  rm "$plan_file"
}

@test "plan_pipeline_effective_metadata_json de-duplicates artifacts with required true winning" {
  plan_file="$(mktemp)"
  cat <<'EOF' > "$plan_file"
---
execution: orchestration
pipeline:
  stages:
    - id: review
      runtime: codex
      produces:
        - path: shared/output.md
          required: false
todos:
  - id: review-1
    stage: review
    content: review the change
    verification: confirm outputs
    status: pending
    produces:
      - path: shared/output.md
        required: true
---
EOF

  run plan_pipeline_effective_metadata_json "$plan_file" review-1
  [ "$status" -eq 0 ]
  [ "$(json_field "$output" '.produces | length')" = "1" ]
  [ "$(json_field "$output" '.produces[0].path')" = "shared/output.md" ]
  [ "$(json_field "$output" '.produces[0].required')" = "true" ]
  rm "$plan_file"
}

@test "plan_pipeline_effective_metadata_json accepts a staged TODO overriding only model" {
  plan_file="$(mktemp)"
  cat <<'EOF' > "$plan_file"
---
execution: orchestration
pipeline:
  stages:
    - id: review
      runtime: claude
todos:
  - id: review-1
    stage: review
    model: gpt-5
    content: review the change
    verification: confirm outputs
    status: pending
---
EOF

  run plan_pipeline_effective_metadata_json "$plan_file" review-1
  [ "$status" -eq 0 ]
  [ "$(json_field "$output" '.runtime')" = "claude" ]
  [ "$(json_field "$output" '.model')" = "gpt-5" ]
  rm "$plan_file"
}

@test "plan_pipeline_effective_metadata_json accepts a staged TODO overriding only runtime" {
  plan_file="$(mktemp)"
  cat <<'EOF' > "$plan_file"
---
execution: orchestration
pipeline:
  stages:
    - id: review
      runtime: claude
todos:
  - id: review-1
    stage: review
    runtime: codex
    content: review the change
    verification: confirm outputs
    status: pending
---
EOF

  run plan_pipeline_effective_metadata_json "$plan_file" review-1
  [ "$status" -eq 0 ]
  [ "$(json_field "$output" '.runtime')" = "codex" ]
  rm "$plan_file"
}

@test "staged TODO overriding only runtime drops the baseline stage model" {
  plan_file="$(mktemp)"
  cat <<'EOF' > "$plan_file"
---
execution: orchestration
pipeline:
  stages:
    - id: review
      runtime: claude
      model: claude-4
todos:
  - id: review-1
    stage: review
    runtime: codex
    content: review the change
    verification: confirm outputs
    status: pending
---
EOF

  run plan_pipeline_effective_metadata_json "$plan_file" review-1
  [ "$status" -eq 0 ]
  [ "$(json_field "$output" '.runtime')" = "codex" ]
  [ "$(json_field "$output" '.model')" = "" ]
  rm "$plan_file"
}

@test "next TODO after a runtime-only switch sees baseline restore of runtime and model" {
  plan_file="$(mktemp)"
  cat <<'EOF' > "$plan_file"
---
execution: orchestration
pipeline:
  stages:
    - id: review
      runtime: claude
      model: claude-4
todos:
  - id: review-1
    stage: review
    runtime: codex
    content: review the change on codex
    verification: confirm outputs
    status: pending
  - id: review-2
    stage: review
    content: review the change on the baseline runtime
    verification: confirm outputs
    status: pending
---
EOF

  run plan_pipeline_effective_metadata_json "$plan_file" review-2
  [ "$status" -eq 0 ]
  [ "$(json_field "$output" '.runtime')" = "claude" ]
  [ "$(json_field "$output" '.model')" = "claude-4" ]
  rm "$plan_file"
}

@test "generated-plan TODO overriding only runtime drops the baseline header model" {
  plan_file="$(mktemp)"
  cat <<'EOFPLAN' > "$plan_file"
---
name: generated-runtime-switch
overview: Runtime-only TODO in a generated leaf plan
runtime: cursor
model: auto
sessionStrategy: fresh
todos:
  - id: switch-runtime
    runtime: claude
    content: Switch runtime only; the header model must not carry across.
    verification: true
    status: pending
---
EOFPLAN

  run plan_pipeline_validate_plan "$plan_file"
  [ "$status" -eq 0 ]
  run plan_pipeline_effective_metadata_json "$plan_file" switch-runtime
  [ "$status" -eq 0 ]
  [ "$(json_field "$output" '.runtime')" = "claude" ]
  [ "$(json_field "$output" '.model')" = "" ]
  rm "$plan_file"
}

@test "staged TODO overriding only runtime requires a fresh session" {
  plan_file="$(mktemp)"
  cat <<'EOF' > "$plan_file"
---
execution: orchestration
pipeline:
  stages:
    - id: review
      runtime: claude
      sessionStrategy: resume
todos:
  - id: review-1
    stage: review
    runtime: codex
    content: review the change
    verification: confirm outputs
    status: pending
---
EOF

  run plan_pipeline_validate_plan "$plan_file"
  [ "$status" -ne 0 ]
  [[ "$output" == *"sessionStrategy: fresh"* ]]
  rm "$plan_file"
}

@test "staged TODO overriding only runtime passes with an explicit fresh session" {
  plan_file="$(mktemp)"
  cat <<'EOF' > "$plan_file"
---
execution: orchestration
pipeline:
  stages:
    - id: review
      runtime: claude
      sessionStrategy: resume
todos:
  - id: review-1
    stage: review
    runtime: codex
    sessionStrategy: fresh
    content: review the change
    verification: confirm outputs
    status: pending
---
EOF

  run plan_pipeline_validate_plan "$plan_file"
  [ "$status" -eq 0 ]
  run plan_pipeline_effective_metadata_json "$plan_file" review-1
  [ "$status" -eq 0 ]
  [ "$(json_field "$output" '.runtime')" = "codex" ]
  [ "$(json_field "$output" '.sessionStrategy')" = "fresh" ]
  rm "$plan_file"
}

# --- mode: as the uniform public key (plans, not just workflows) -----------
# AGENTS.md: authored frontmatter uses mode: sequential|dependency; a plain
# plan (no kind: workflow) also accepts mode: standard, mapping 1:1 to the
# internal execution: standard|orchestration|graph. execution: itself remains
# a permanently accepted legacy alias (never removed, never documented as
# current syntax).

@test "plan mode: dependency validates the same as legacy execution: graph" {
  plan_file="$(mktemp)"
  cat <<'EOF' > "$plan_file"
---
name: mode-dependency-plan
overview: A plain plan authored with mode instead of execution
mode: dependency
instructions: Execute one TODO at a time.
pipeline:
  stages:
    - id: research
      runtime: cursor
todos:
  - id: research-1
    stage: research
    content: look into it
    verification: confirm outputs
    status: pending
---
EOF
  run plan_pipeline_validate_plan "$plan_file"
  [ "$status" -eq 0 ]
  rm "$plan_file"
}

@test "plan mode: sequential validates the same as legacy execution: orchestration" {
  plan_file="$(mktemp)"
  cat <<'EOF' > "$plan_file"
---
name: mode-sequential-plan
overview: A plain plan authored with mode instead of execution
mode: sequential
pipeline:
  stages:
    - id: review
      runtime: claude
todos:
  - id: review-1
    stage: review
    content: review the change
    verification: confirm outputs
    status: pending
---
EOF
  run plan_pipeline_validate_plan "$plan_file"
  [ "$status" -eq 0 ]
  rm "$plan_file"
}

@test "plan mode: standard validates a flat TODO queue with no pipeline" {
  plan_file="$(mktemp)"
  cat <<'EOF' > "$plan_file"
---
name: mode-standard-plan
overview: A plain single-agent plan authored with mode instead of execution
mode: standard
todos:
  - id: task-1
    content: do a thing
    verification: confirm it worked
    status: pending
---
EOF
  run plan_pipeline_validate_plan "$plan_file"
  [ "$status" -eq 0 ]
  rm "$plan_file"
}

@test "plan mode: standard is rejected on a workflow (kind: workflow is always multi-stage)" {
  plan_file="$(mktemp)"
  cat <<'EOF' > "$plan_file"
---
name: bad-workflow-mode
kind: workflow
mode: standard
overview: invalid combination
pipeline:
  stages:
    - id: only
      runtime: cursor
---
EOF
  run plan_pipeline_validate_plan "$plan_file"
  [ "$status" -ne 0 ]
  [[ "$output" == *"invalid mode value"* ]]
  rm "$plan_file"
}

@test "plan mode and execution together are rejected" {
  plan_file="$(mktemp)"
  cat <<'EOF' > "$plan_file"
---
name: mode-and-execution
overview: mutually exclusive keys
mode: dependency
execution: graph
pipeline:
  stages:
    - id: only
      runtime: cursor
---
EOF
  run plan_pipeline_validate_plan "$plan_file"
  [ "$status" -ne 0 ]
  [[ "$output" == *"mode and execution must not both be set"* ]]
  rm "$plan_file"
}

@test "plan engine: is refused as a workflow-only legacy key" {
  plan_file="$(mktemp)"
  cat <<'EOF' > "$plan_file"
---
name: plan-with-engine
overview: engine: never applied to plans
engine: graph
pipeline:
  stages:
    - id: only
      runtime: cursor
---
EOF
  run plan_pipeline_validate_plan "$plan_file"
  [ "$status" -ne 0 ]
  [[ "$output" == *"engine: is a workflow-only legacy key"* ]]
  rm "$plan_file"
}

@test "unstaged TODO overriding only runtime requires a fresh session at the plan header" {
  plan_file="$(mktemp)"
  cat <<'EOFPLAN' > "$plan_file"
---
name: header-resume-switch
overview: Plan header resume session with a runtime-only TODO switch
runtime: cursor
sessionStrategy: resume
todos:
  - id: switch-runtime
    runtime: claude
    content: Switch runtime only under a resume plan header.
    verification: true
    status: pending
---
EOFPLAN

  run plan_pipeline_validate_plan "$plan_file"
  [ "$status" -ne 0 ]
  [[ "$output" == *"sessionStrategy: fresh"* ]]
  rm "$plan_file"
}

@test "TODO overriding only runtime rejects an invalid runtime" {
  plan_file="$(mktemp)"
  cat <<'EOFPLAN' > "$plan_file"
---
name: invalid-runtime-only
overview: Runtime-only TODO with an unsupported runtime
runtime: cursor
todos:
  - id: switch-runtime
    runtime: not-a-runtime
    content: Switch to an unsupported runtime.
    verification: true
    status: pending
---
EOFPLAN

  run plan_pipeline_validate_plan "$plan_file"
  [ "$status" -ne 0 ]
  [[ "$output" == *"invalid runtime"* ]]
  rm "$plan_file"
}

@test "plan_pipeline_effective_metadata_json rejects an unstaged TODO with routing but no runtime" {
  plan_file="$(mktemp)"
  cat <<'EOF' > "$plan_file"
---
execution: orchestration
todos:
  - id: review-1
    model: gpt-5
    content: review the change
    verification: confirm outputs
    status: pending
---
EOF

  run plan_pipeline_effective_metadata_json "$plan_file" review-1
  [ "$status" -ne 0 ]
  rm "$plan_file"
}

@test "plan_pipeline_effective_metadata_json rejects invalid pipeline stage runtime values" {
  plan_file="$(mktemp)"
  cat <<'EOF' > "$plan_file"
---
execution: orchestration
pipeline:
  stages:
    - id: review
      runtime: not-a-runtime
todos:
  - id: review-1
    stage: review
    content: review the change
    verification: confirm outputs
    status: pending
---
EOF

  run plan_pipeline_effective_metadata_json "$plan_file" review-1
  [ "$status" -ne 0 ]
  rm "$plan_file"
}

@test "plan_pipeline_effective_metadata_json rejects invalid pipeline stage ids" {
  plan_file="$(mktemp)"
  cat <<'EOF' > "$plan_file"
---
execution: orchestration
pipeline:
  stages:
    - id: Review
      runtime: codex
todos:
  - id: review-1
    stage: Review
    content: review the change
    verification: confirm outputs
    status: pending
---
EOF

  run plan_pipeline_effective_metadata_json "$plan_file" review-1
  [ "$status" -ne 0 ]
  rm "$plan_file"
}

@test "plan_pipeline_effective_metadata_json rejects invalid pipeline stage routing" {
  plan_file="$(mktemp)"
  cat <<'EOF' > "$plan_file"
---
execution: orchestration
pipeline:
  stages:
    - id: review
      runtime: not-a-runtime
todos:
  - id: review-1
    stage: review
    content: review the change
    verification: confirm outputs
    status: pending
---
EOF

  run plan_pipeline_effective_metadata_json "$plan_file" review-1
  [ "$status" -ne 0 ]
  rm "$plan_file"
}

@test "plan_pipeline_effective_metadata_json parses loopCheck metadata" {
  plan_file="$(mktemp)"
  cat <<'EOF' > "$plan_file"
---
execution: orchestration
pipeline:
  stages:
    - id: review
      runtime: codex
      loopBackTo: review
      maxIterations: 1
      loopCheck:
        path: review-status.md
      produces:
        - path: review-status.md
          required: true
todos:
  - id: review-1
    stage: review
    content: review the change
    verification: confirm outputs
    status: pending
---
EOF

  run plan_pipeline_effective_metadata_json "$plan_file" review-1
  [ "$status" -eq 0 ]
  [ "$(json_field "$output" '.loopCheck.path')" = "review-status.md" ]
  rm "$plan_file"
}

@test "plan_pipeline helpers keep standard (and backward-compat simple) execution plans working" {
  plan_file="$(mktemp)"
  cat <<'EOF' > "$plan_file"
---
execution: standard
todos:
  - id: simple-1
    content: |
      Do the thing.
    verification: confirm the thing
    status: pending
---
EOF

  run get_next_todo "$plan_file"
  [ "$status" -eq 0 ]
  [ "$output" = $'1|simple-1|Do the thing.' ]

  run plan_pipeline_todo_metadata_json "$plan_file" simple-1
  [ "$status" -eq 0 ]
  [ "$(json_field "$output" '.stage')" = "" ]
  [ "$(json_field "$output" '.runtime')" = "" ]
  [ "$(json_field "$output" '.requires | length')" = "0" ]
  [ "$(json_field "$output" '.produces | length')" = "0" ]

  run plan_pipeline_effective_metadata_json "$plan_file" simple-1
  [ "$status" -eq 0 ]
  [ "$(json_field "$output" '.loopCheck')" = "{}" ]
  [ "$(json_field "$output" '.maxIterations')" = "" ]
  rm "$plan_file"
}

@test "plan_pipeline_effective_metadata_json includes planFile from stage definition" {
  plan_file="$(mktemp)"
  cat <<'EOF' > "$plan_file"
---
execution: orchestration
pipeline:
  stages:
    - id: review
      planFile: .ralph-workspace/plans/review-stage.plan.md
todos:
  - id: review-1
    stage: review
    content: run nested plan
    status: pending
---
EOF

  run plan_pipeline_effective_metadata_json "$plan_file" review-1
  [ "$status" -eq 0 ]
  [ "$(json_field "$output" '.planFile')" = ".ralph-workspace/plans/review-stage.plan.md" ]
  [ "$(json_field "$output" '.stage')" = "review" ]
  rm "$plan_file"
}

@test "plan_structured metadata wrappers work for standard pipeline plans" {
  plan_file="$(mktemp)"
  cat <<'EOF' > "$plan_file"
---
execution: standard
todos:
  - id: simple-2
    content: write the summary
    verification: check the summary
    status: pending
---
EOF

  run plan_structured_todo_metadata_json "$plan_file" simple-2
  [ "$status" -eq 0 ]
  [ "$(json_field "$output" '.todoId')" = "simple-2" ]
  [ "$(json_field "$output" '.content')" = "write the summary" ]

  run plan_structured_effective_metadata_json "$plan_file" simple-2
  [ "$status" -eq 0 ]
  [ "$(json_field "$output" '.todoId')" = "simple-2" ]
  [ "$(json_field "$output" '.loopCheck')" = "{}" ]
  rm "$plan_file"
}

@test "plan_pipeline_orch_json emits the .orch.json stage shape" {
  tmpd="$(mktemp -d)"
  plan_file="$tmpd/orc-demo.plan.md"
  cat <<'EOF' > "$plan_file"
---
name: Demo Orchestration
execution: orchestration
pipeline:
  stages:
    - id: research
      runtime: cursor
      produces:
        - path: .ralph-workspace/artifacts/{{ARTIFACT_NS}}/research.md
          required: true
    - id: review
      runtime: codex
      requires:
        - path: .ralph-workspace/artifacts/{{ARTIFACT_NS}}/research.md
          required: true
      planFile: .ralph-workspace/plans/review-stage.plan.md
todos:
  - id: research-1
    stage: research
    content: Do research.
    verification: Confirm research.md exists.
    status: pending
---
EOF

  run plan_pipeline_orch_json "$plan_file"
  [ "$status" -eq 0 ]
  [ "$(json_field "$output" '.name')" = "Demo Orchestration" ]
  [ "$(json_field "$output" '.namespace')" = "orc-demo" ]
  [ "$(json_field "$output" '.stages | length')" = "2" ]
  # produces maps to both outputArtifacts and artifacts (required preserved)
  [ "$(json_field "$output" '.stages[0].outputArtifacts[0].path')" = ".ralph-workspace/artifacts/{{ARTIFACT_NS}}/research.md" ]
  [ "$(json_field "$output" '.stages[0].artifacts[0].required')" = "true" ]
  # inline stage carries _inlineTodos for the runner to materialize
  [ "$(json_field "$output" '.stages[0]._inlineTodos[0].content')" = "Do research." ]
  # requires maps to inputArtifacts; planFile maps to plan
  [ "$(json_field "$output" '.stages[1].inputArtifacts[0].path')" = ".ralph-workspace/artifacts/{{ARTIFACT_NS}}/research.md" ]
  [ "$(json_field "$output" '.stages[1].plan')" = ".ralph-workspace/plans/review-stage.plan.md" ]
  rm -rf "$tmpd"
}

@test "plan_pipeline_orch_json preserves router and grader metadata" {
  tmpd="$(mktemp -d)"
  plan_file="$tmpd/router-grader.plan.md"
  cat <<'EOF' > "$plan_file"
---
execution: orchestration
pipeline:
  stages:
    - id: route
      runtime: cursor
      router:
        allowedTargets:
          - review
          - publish
        terminalOutcomes:
          - done
        defaultTarget: review
        onInvalid: default
    - id: review
      runtime: codex
      grader: true
      rubric: |
        Score the response against the rubric.
        Return a short summary.
todos:
  - id: route-1
    stage: route
    content: route the work
    status: pending
  - id: review-1
    stage: review
    content: review the work
    status: pending
---
EOF

  run plan_pipeline_orch_json "$plan_file"
  [ "$status" -eq 0 ]
  [ "$(json_field "$output" '.stages[0].router.allowedTargets[0]')" = "review" ]
  [ "$(json_field "$output" '.stages[0].router.allowedTargets[1]')" = "publish" ]
  [ "$(json_field "$output" '.stages[0].router.terminalOutcomes[0]')" = "done" ]
  [ "$(json_field "$output" '.stages[0].router.defaultTarget')" = "review" ]
  [ "$(json_field "$output" '.stages[0].router.onInvalid')" = "default" ]
  [ "$(json_field "$output" '.stages[1].grader')" = "true" ]
  [ "$(json_field "$output" '.stages[1].rubric')" = $'Score the response against the rubric.\nReturn a short summary.' ]
  rm -rf "$tmpd"
}

@test "plan_pipeline_orch_json preserves graph stage fields" {
  tmpd="$(mktemp -d)"
  plan_file="$tmpd/graph-stage.plan.md"
  cat <<'EOF' > "$plan_file"
---
execution: graph
pipeline:
  maxParallel: 3
  edgeDerivation: artifacts
  failurePolicy: cancel
  stages:
    - id: consensus
      type: consensus
      policy: majority
      onVoterError: fail
      verdictSchema: .ralph-workspace/schemas/verdict.json
      quorum: 2
      minRuntimes: 3
      voters:
        - id: voter-a
          runtime: cursor
          model: gpt-5
          sessionStrategy: fresh
          contextBudget: lean
        - id: voter-b
          runtime: codex
          model: gpt-5
          sessionStrategy: resume
          contextBudget: standard
        - id: voter-c
          runtime: claude
          model: claude-4
          sessionStrategy: reset
          contextBudget: full
    - id: agent-stage
      type: agent
      runtime: cursor
      dependsOn: [consensus]
todos:
  - id: consensus-1
    stage: consensus
    content: run consensus
    status: pending
  - id: agent-1
    stage: agent-stage
    content: run agent stage
    status: pending
---
EOF

  run plan_pipeline_orch_json "$plan_file"
  [ "$status" -eq 0 ]
  [ "$(json_field "$output" '.stages[0].type')" = "consensus" ]
  [ "$(json_field "$output" '.stages[0].policy')" = "majority" ]
  [ "$(json_field "$output" '.stages[0].onVoterError')" = "fail" ]
  [ "$(json_field "$output" '.stages[0].verdictSchema')" = ".ralph-workspace/schemas/verdict.json" ]
  [ "$(json_field "$output" '.stages[0].quorum')" = "2" ]
  [ "$(json_field "$output" '.stages[0].minRuntimes')" = "3" ]
  [ "$(json_field "$output" '.stages[0].voters | length')" = "3" ]
  [ "$(json_field "$output" '.stages[0].voters[0].id')" = "voter-a" ]
  [ "$(json_field "$output" '.stages[0].voters[1].runtime')" = "codex" ]
  [ "$(json_field "$output" '.stages[0].voters[2].contextBudget')" = "full" ]
  [ "$(json_field "$output" '.stages[1].type')" = "agent" ]
  [ "$(json_field "$output" '.maxParallel')" = "3" ]
  [ "$(json_field "$output" '.edgeDerivation')" = "artifacts" ]
  [ "$(json_field "$output" '.failurePolicy')" = "cancel" ]
  rm -rf "$tmpd"
}

@test "plan_pipeline_orch_json builds artifact producer and precondition maps for graph plans" {
  tmpd="$(mktemp -d)"
  plan_file="$tmpd/graph-edges.plan.md"
  cp "$REPO_ROOT/tests/fixtures/graph/graph-edges.plan.md" "$plan_file"

  run plan_pipeline_orch_json "$plan_file"
  [ "$status" -eq 0 ]
  [ "$(json_field "$output" '.artifactProducers["shared/input.md"]')" = "source" ]
  [ "$(json_field "$output" '.artifactProducers["shared/output.md"]')" = "transform" ]
  [ "$(json_field "$output" '.graphEdges | length')" = "2" ]
  [ "$(json_field "$output" '.graphEdges[0].from')" = "source" ]
  [ "$(json_field "$output" '.graphEdges[0].to')" = "transform" ]
  [ "$(json_field "$output" '.graphEdges[0].reasons | length')" = "2" ]
  [ "$(json_field "$output" '.graphEdges[0].reasons[0]')" = "declared" ]
  [ "$(json_field "$output" '.graphEdges[0].reasons[1]')" = "artifact:shared/input.md" ]
  [ "$(json_field "$output" '.graphEdges[1].from')" = "transform" ]
  [ "$(json_field "$output" '.graphEdges[1].to')" = "sink" ]
  [ "$(json_field "$output" '.graphEdges[1].reasons | length')" = "2" ]
  [ "$(json_field "$output" '.graphEdges[1].reasons[0]')" = "declared" ]
  [ "$(json_field "$output" '.graphEdges[1].reasons[1]')" = "artifact:shared/output.md" ]
  rm -rf "$tmpd"
}

@test "plan_pipeline_orch_json rejects duplicate artifact producers" {
  tmpd="$(mktemp -d)"
  plan_file="$tmpd/graph-duplicate-producer.plan.md"
  cp "$REPO_ROOT/tests/fixtures/graph/graph-duplicate-producer.plan.md" "$plan_file"

  run plan_pipeline_orch_json "$plan_file"
  [ "$status" -ne 0 ]
  [[ "$output" == *"shared/output.md"* ]]
  [[ "$output" == *"left"* ]]
  [[ "$output" == *"right"* ]]
  rm -rf "$tmpd"
}

@test "plan_pipeline_orch_json emits declared and derived edges with a single merged entry" {
  tmpd="$(mktemp -d)"
  plan_file="$tmpd/graph-declared-derived.plan.md"
  cp "$REPO_ROOT/tests/fixtures/graph/graph-declared-derived.plan.md" "$plan_file"

  run plan_pipeline_orch_json "$plan_file"
  [ "$status" -eq 0 ]
  [ "$(json_field "$output" '.graphEdges | length')" = "1" ]
  [ "$(json_field "$output" '.graphEdges[0].from')" = "source" ]
  [ "$(json_field "$output" '.graphEdges[0].to')" = "consumer" ]
  [ "$(json_field "$output" '.graphEdges[0].reasons | length')" = "2" ]
  [ "$(json_field "$output" '.graphEdges[0].reasons[0]')" = "declared" ]
  [ "$(json_field "$output" '.graphEdges[0].reasons[1]')" = "artifact:shared/output.md" ]
  rm -rf "$tmpd"
}

@test "plan_pipeline_orch_json detects dependency cycles in traversal order" {
  tmpd="$(mktemp -d)"
  plan_file="$tmpd/graph-cycle.plan.md"
  cp "$REPO_ROOT/tests/fixtures/graph/graph-cycle.plan.md" "$plan_file"

  run plan_pipeline_orch_json "$plan_file"
  [ "$status" -ne 0 ]
  [[ "$output" == *"cycle detected"* ]]
  [[ "$output" == *"a -> b -> c -> a"* ]]
  rm -rf "$tmpd"
}

@test "plan_pipeline_orch_json records unproduced requires entries as external preconditions" {
  tmpd="$(mktemp -d)"
  plan_file="$tmpd/graph-unproduced-requires.plan.md"
  cp "$REPO_ROOT/tests/fixtures/graph/graph-unproduced-requires.plan.md" "$plan_file"

  run plan_pipeline_orch_json "$plan_file"
  [ "$status" -eq 0 ]
  [ "$(json_field "$output" '.externalPreconditions | length')" = "1" ]
  [ "$(json_field "$output" '.externalPreconditions[0].path')" = "external/input.md" ]
  [ "$(json_field "$output" '.externalPreconditions[0].consumer')" = "consumer" ]
  rm -rf "$tmpd"
}

@test "plan_pipeline_orch_json allows VOTER_ID-templated consensus producers" {
  tmpd="$(mktemp -d)"
  plan_file="$tmpd/graph-consensus-voter.plan.md"
  cat <<'EOF' > "$plan_file"
---
execution: graph
pipeline:
  stages:
    - id: consensus
      type: consensus
      runtime: cursor
      voters:
        - id: voter-a
          runtime: cursor
          model: gpt-5
          sessionStrategy: fresh
          contextBudget: lean
        - id: voter-b
          runtime: cursor
          model: gpt-5
          sessionStrategy: fresh
          contextBudget: lean
      produces:
        - path: votes/{{VOTER_ID}}/summary.md
todos:
  - id: consensus-1
    stage: consensus
    content: run the consensus node
    status: pending
---
EOF

  run plan_pipeline_orch_json "$plan_file"
  [ "$status" -eq 0 ]
  [ "$(json_field "$output" '.artifactProducers["votes/voter-a/summary.md"]')" = "consensus:voter-a" ]
  [ "$(json_field "$output" '.artifactProducers["votes/voter-b/summary.md"]')" = "consensus:voter-b" ]
  rm -rf "$tmpd"
}

@test "plan_pipeline_orch_json rejects invalid graph stage type values" {
  tmpd="$(mktemp -d)"
  plan_file="$tmpd/graph-type-invalid.plan.md"
  cat <<'EOF' > "$plan_file"
---
execution: graph
pipeline:
  stages:
    - id: consensus
      type: not-a-type
      runtime: cursor
todos:
  - id: consensus-1
    stage: consensus
    content: run consensus
    status: pending
---
EOF

  run plan_pipeline_orch_json "$plan_file"
  [ "$status" -ne 0 ]
  [[ "$output" == *"unknown stage field"* || "$output" == *"invalid"* ]]
  rm -rf "$tmpd"
}

@test "plan_pipeline_orch_json rejects invalid edgeDerivation values" {
  tmpd="$(mktemp -d)"
  plan_file="$tmpd/graph-edge-invalid.plan.md"
  cat <<'EOF' > "$plan_file"
---
execution: graph
pipeline:
  edgeDerivation: unsupported
  stages:
    - id: consensus
      runtime: cursor
todos:
  - id: consensus-1
    stage: consensus
    content: run consensus
    status: pending
---
EOF

  run plan_pipeline_orch_json "$plan_file"
  [ "$status" -ne 0 ]
  [[ "$output" == *"edgeDerivation"* ]]
  rm -rf "$tmpd"
}

@test "plan_pipeline_orch_json rejects invalid failurePolicy values" {
  tmpd="$(mktemp -d)"
  plan_file="$tmpd/graph-failure-invalid.plan.md"
  cat <<'EOF' > "$plan_file"
---
execution: graph
pipeline:
  failurePolicy: pause
  stages:
    - id: consensus
      runtime: cursor
todos:
  - id: consensus-1
    stage: consensus
    content: run consensus
    status: pending
---
EOF

  run plan_pipeline_orch_json "$plan_file"
  [ "$status" -ne 0 ]
  [[ "$output" == *"failurePolicy"* ]]
  rm -rf "$tmpd"
}

@test "plan_pipeline_orch_json rejects misspelled graph pipeline fields in strict mode" {
  tmpd="$(mktemp -d)"
  plan_file="$tmpd/graph-strict-pipeline.plan.md"
  cat <<'EOF' > "$plan_file"
---
execution: graph
pipeline:
  maxParalel: 2
  edgeDerivaton: both
  failurePolcy: drain
  stages:
    - id: consensus
      runtime: cursor
todos:
  - id: consensus-1
    stage: consensus
    content: run consensus
    status: pending
---
EOF

  run plan_pipeline_orch_json "$plan_file"
  [ "$status" -ne 0 ]
  [[ "$output" == *"maxParalel"* ]]
  rm -rf "$tmpd"
}

@test "plan_pipeline_orch_json rejects misspelled graph stage and voter fields in strict mode" {
  tmpd="$(mktemp -d)"
  plan_file="$tmpd/graph-strict-stage.plan.md"
  cat <<'EOF' > "$plan_file"
---
execution: graph
pipeline:
  stages:
    - id: consensus
      runtime: cursor
      typ: consensus
      depnedsOn: [other]
      voters:
        - id: voter-a
          runtime: cursor
          model: gpt-5
          sessionStrategy: fresh
          contextBudget: lean
          extra: nope
todos:
  - id: consensus-1
    stage: consensus
    content: run consensus
    status: pending
---
EOF

  run plan_pipeline_orch_json "$plan_file"
  [ "$status" -ne 0 ]
  [[ "$output" == *"typ"* ]]
  rm -rf "$tmpd"
}

@test "plan_pipeline_orch_json rejects invalid router targets" {
  tmpd="$(mktemp -d)"
  plan_file="$tmpd/router-invalid.plan.md"
  cat <<'EOF' > "$plan_file"
---
execution: orchestration
pipeline:
  stages:
    - id: route
      runtime: cursor
      router:
        allowedTargets:
          - review
        defaultTarget: publish
todos:
  - id: route-1
    stage: route
    content: route the work
    status: pending
---
EOF

  run plan_pipeline_orch_json "$plan_file"
  [ "$status" -ne 0 ]
  [[ "$output" == *"router.defaultTarget"* ]]
  rm -rf "$tmpd"
}

@test "plan_pipeline_orch_json rejects grader stages that do not use fresh sessions" {
  tmpd="$(mktemp -d)"
  plan_file="$tmpd/grader-session-strategy.plan.md"
  cat <<'EOF' > "$plan_file"
---
execution: orchestration
pipeline:
  stages:
    - id: review
      runtime: codex
      grader: true
      rubric: Evaluate the result.
      sessionStrategy: resume
todos:
  - id: review-1
    stage: review
    content: review the work
    status: pending
---
EOF

  run plan_pipeline_orch_json "$plan_file"
  [ "$status" -ne 0 ]
  [[ "$output" == *"grader stages require fresh"* ]]
  rm -rf "$tmpd"
}

@test "plan_pipeline_orch_json nests loopBackTo/maxIterations under loopControl" {
  tmpd="$(mktemp -d)"
  plan_file="$tmpd/loop-demo.plan.md"
  cat <<'EOF' > "$plan_file"
---
execution: orchestration
pipeline:
  stages:
    - id: build
      runtime: cursor
      produces:
        - path: .ralph-workspace/artifacts/{{ARTIFACT_NS}}/build-check.md
          required: true
      loopBackTo: build
      maxIterations: 3
      loopCheck:
        path: .ralph-workspace/artifacts/{{ARTIFACT_NS}}/build-check.md
todos:
  - id: build-1
    stage: build
    content: build it
    status: pending
---
EOF

  run plan_pipeline_orch_json "$plan_file"
  [ "$status" -eq 0 ]
  [ "$(json_field "$output" '.stages[0].loopControl.loopBackTo')" = "build" ]
  [ "$(json_field "$output" '.stages[0].loopControl.maxIterations')" = "3" ]
  rm -rf "$tmpd"
}

@test "parse_string_list handles inline flow form" {
  tmpd="$(mktemp -d)"
  plan_file="$tmpd/string-list-inline.plan.md"
  cat <<'EOF' > "$plan_file"
---
execution: orchestration
pipeline:
  stages:
    - id: compile
      runtime: cursor
      dependsOn: [prepare, setup]
      produces:
        - path: .ralph-workspace/artifacts/{{ARTIFACT_NS}}/compile.md
          required: true
todos:
  - id: compile-1
    stage: compile
    content: compile
    status: pending
---
EOF

  run plan_pipeline_orch_json "$plan_file"
  [ "$status" -eq 0 ]
  [ "$(json_field "$output" '.stages[0].dependsOn | length')" = "2" ]
  [ "$(json_field "$output" '.stages[0].dependsOn[0]')" = "prepare" ]
  [ "$(json_field "$output" '.stages[0].dependsOn[1]')" = "setup" ]
  rm -rf "$tmpd"
}

@test "parse_string_list handles block form" {
  tmpd="$(mktemp -d)"
  plan_file="$tmpd/string-list-block.plan.md"
  cat <<'EOF' > "$plan_file"
---
execution: orchestration
pipeline:
  stages:
    - id: compile
      runtime: cursor
      dependsOn:
        - prepare
        - setup
      produces:
        - path: .ralph-workspace/artifacts/{{ARTIFACT_NS}}/compile.md
          required: true
todos:
  - id: compile-1
    stage: compile
    content: compile
    status: pending
---
EOF

  run plan_pipeline_orch_json "$plan_file"
  [ "$status" -eq 0 ]
  [ "$(json_field "$output" '.stages[0].dependsOn | length')" = "2" ]
  [ "$(json_field "$output" '.stages[0].dependsOn[0]')" = "prepare" ]
  [ "$(json_field "$output" '.stages[0].dependsOn[1]')" = "setup" ]
  rm -rf "$tmpd"
}

@test "parse_string_list handles empty list" {
  tmpd="$(mktemp -d)"
  plan_file="$tmpd/string-list-empty.plan.md"
  cat <<'EOF' > "$plan_file"
---
execution: orchestration
pipeline:
  stages:
    - id: compile
      runtime: cursor
      dependsOn: []
      produces:
        - path: .ralph-workspace/artifacts/{{ARTIFACT_NS}}/compile.md
          required: true
todos:
  - id: compile-1
    stage: compile
    content: compile
    status: pending
---
EOF

  run plan_pipeline_orch_json "$plan_file"
  [ "$status" -eq 0 ]
  [ "$(json_field "$output" '.stages[0].dependsOn | length')" = "0" ]
  rm -rf "$tmpd"
}

@test "parse_string_list handles single-element inline list" {
  tmpd="$(mktemp -d)"
  plan_file="$tmpd/string-list-single.plan.md"
  cat <<'EOF' > "$plan_file"
---
execution: orchestration
pipeline:
  stages:
    - id: compile
      runtime: cursor
      dependsOn: [prepare]
      produces:
        - path: .ralph-workspace/artifacts/{{ARTIFACT_NS}}/compile.md
          required: true
todos:
  - id: compile-1
    stage: compile
    content: compile
    status: pending
---
EOF

  run plan_pipeline_orch_json "$plan_file"
  [ "$status" -eq 0 ]
  [ "$(json_field "$output" '.stages[0].dependsOn | length')" = "1" ]
  [ "$(json_field "$output" '.stages[0].dependsOn[0]')" = "prepare" ]
  rm -rf "$tmpd"
}

@test "parse_string_list strips YAML quotes from writeScopes globs" {
  tmpd="$(mktemp -d)"
  plan_file="$tmpd/write-scopes-quoted.plan.md"
  cat <<'EOF' > "$plan_file"
---
execution: graph
pipeline:
  maxParallel: 1
  publishMode: manual
  stages:
    - id: implementation
      runtime: cursor
      workspaceMode: shared
      writeScopes:
        - "**"
      agentGitAccess: off
      acknowledgeSharedMutationRisk: true
      parallelMutation: allow
      produces:
        - path: .ralph-workspace/artifacts/{{ARTIFACT_NS}}/implementation-handoff.md
          required: true
todos:
  - id: implementation-1
    stage: implementation
    content: implement
    status: pending
    verification: handoff exists
---
EOF

  run plan_pipeline_graph_json "$plan_file"
  [ "$status" -eq 0 ]
  [ "$(json_field "$output" '.nodes[] | select(.id == "implementation") | .stage.writeScopes[0]')" = "**" ]
  rm -rf "$tmpd"
}

@test "parse_string_list fails on unbalanced bracket inline list" {
  tmpd="$(mktemp -d)"
  plan_file="$tmpd/string-list-unbalanced.plan.md"
  cat <<'EOF' > "$plan_file"
---
execution: orchestration
pipeline:
  stages:
    - id: compile
      runtime: cursor
      dependsOn: [prepare
      produces:
        - path: .ralph-workspace/artifacts/{{ARTIFACT_NS}}/compile.md
          required: true
todos:
  - id: compile-1
    stage: compile
    content: compile
    status: pending
---
EOF

  run plan_pipeline_orch_json "$plan_file"
  [ "$status" -ne 0 ]
  [[ "$output" == *"unbalanced brackets"* ]]
  rm -rf "$tmpd"
}

@test "unknown frontmatter keys fail in strict orchestration mode" {
  tmpd="$(mktemp -d)"
  plan_file="$tmpd/strict-keys.plan.md"
  cat <<'EOF' > "$plan_file"
---
execution: orchestration
pipeline:
  stages:
    - id: review
      runtime: codex
      boguS: true
todos:
  - id: review-1
    stage: review
    content: review the change
    status: pending
---
EOF

  run plan_pipeline_orch_json "$plan_file"
  [ "$status" -ne 0 ]
  [[ "$output" == *"boguS"* ]]
  [[ "$output" == *"review"* ]]
  [[ "$output" == *"unknown stage field"* ]]
  rm -rf "$tmpd"
}

@test "unknown frontmatter keys stay lenient when strict mode is disabled" {
  tmpd="$(mktemp -d)"
  plan_file="$tmpd/lenient-keys.plan.md"
  cat <<'EOF' > "$plan_file"
---
execution: orchestration
pipeline:
  stages:
    - id: review
      runtime: codex
      boguS: true
todos:
  - id: review-1
    stage: review
    content: review the change
    status: pending
---
EOF

  export RALPH_PLAN_STRICT_KEYS=0
  run plan_pipeline_orch_json "$plan_file"
  [ "$status" -eq 0 ]
  unset RALPH_PLAN_STRICT_KEYS
  rm -rf "$tmpd"
}

@test "existing fixture plans still parse with stray keys when strict mode is disabled" {
  tmpd="$(mktemp -d)"
  plan_file="$tmpd/orch-json-characterization.plan.md"
  cp "$BATS_TEST_DIRNAME/../../../tests/fixtures/orchestration/orch-json-characterization.plan.md" "$plan_file"
  python3 - <<'PY' "$plan_file"
import pathlib, sys
path = pathlib.Path(sys.argv[1])
text = path.read_text()
text = text.replace("    status: pending\n---\n", "    status: pending\n    strayKey: true\n---\n", 1)
path.write_text(text)
PY

  export RALPH_PLAN_STRICT_KEYS=0
  run plan_pipeline_orch_json "$plan_file"
  [ "$status" -eq 0 ]
  unset RALPH_PLAN_STRICT_KEYS
  rm -rf "$tmpd"
}

@test "plan_pipeline nativeSubagents accepts off and inherit and defaults graph stages per runtime" {
  for value in inherit off; do
    plan_file="$(mktemp)"
    cat > "$plan_file" <<EOF
---
execution: graph
pipeline:
  stages:
    - id: review
      runtime: cursor
      nativeSubagents: ${value}
todos:
  - id: review-1
    stage: review
    content: review the change
    status: pending
---
EOF
    run plan_pipeline_effective_metadata_json "$plan_file" review-1
    [ "$status" -eq 0 ]
    [ "$(json_field "$output" '.nativeSubagents')" = "$value" ]
    [ "$(json_field "$output" 'has("subagents")')" = "false" ]
    run plan_pipeline_orch_json "$plan_file"
    [ "$status" -eq 0 ]
    [ "$(json_field "$output" '.stages[0].nativeSubagents')" = "$value" ]
    rm "$plan_file"
  done

  # Graph agent stages default to off where off can be enforced, and to
  # inherit on a runtime with no proven deny boundary.
  plan_file="$(mktemp)"
  cat <<'EOF' > "$plan_file"
---
execution: graph
pipeline:
  stages:
    - id: review
      runtime: codex
todos:
  - id: review-1
    stage: review
    content: review the change
    status: pending
---
EOF
  run plan_pipeline_effective_metadata_json "$plan_file" review-1
  [ "$status" -eq 0 ]
  [ "$(json_field "$output" '.nativeSubagents')" = "off" ]
  run plan_pipeline_orch_json "$plan_file"
  [ "$status" -eq 0 ]
  [ "$(json_field "$output" '.stages[0].nativeSubagents')" = "off" ]
  [ "$(json_field "$output" '.stages[0] | has("subagents")')" = "false" ]
  rm "$plan_file"

  plan_file="$(mktemp)"
  cat <<'EOF' > "$plan_file"
---
execution: graph
pipeline:
  stages:
    - id: review
      runtime: cursor
todos:
  - id: review-1
    stage: review
    content: review the change
    status: pending
---
EOF
  run plan_pipeline_effective_metadata_json "$plan_file" review-1
  [ "$status" -eq 0 ]
  [ "$(json_field "$output" '.nativeSubagents')" = "inherit" ]
  rm "$plan_file"
}

@test "plan_pipeline nativeSubagents rejects invalid values including the removed on" {
  plan_file="$(mktemp)"
  cat <<'EOF' > "$plan_file"
---
execution: graph
pipeline:
  stages:
    - id: review
      runtime: cursor
      nativeSubagents: maybe
todos:
  - id: review-1
    stage: review
    content: review the change
    status: pending
---
EOF
  run plan_pipeline_effective_metadata_json "$plan_file" review-1
  [ "$status" -ne 0 ]
  [[ "$output" == *"nativeSubagents"* ]]
  rm "$plan_file"

  # "on" was removed along with Ralph-owned native children.
  plan_file="$(mktemp)"
  cat <<'EOF' > "$plan_file"
---
execution: graph
pipeline:
  stages:
    - id: review
      runtime: cursor
      nativeSubagents: on
todos:
  - id: review-1
    stage: review
    content: review the change
    status: pending
---
EOF
  run plan_pipeline_effective_metadata_json "$plan_file" review-1
  [ "$status" -ne 0 ]
  rm "$plan_file"
}

@test "plan_pipeline nativeSubagents resolves todo over stage" {
  plan_file="$(mktemp)"
  cat <<'EOF' > "$plan_file"
---
execution: graph
pipeline:
  stages:
    - id: review
      runtime: cursor
      nativeSubagents: off
todos:
  - id: review-1
    stage: review
    nativeSubagents: inherit
    content: review the change
    status: pending
---
EOF
  run plan_pipeline_todo_metadata_json "$plan_file" review-1
  [ "$status" -eq 0 ]
  [ "$(json_field "$output" '.nativeSubagents')" = "inherit" ]
  run plan_pipeline_effective_metadata_json "$plan_file" review-1
  [ "$status" -eq 0 ]
  [ "$(json_field "$output" '.nativeSubagents')" = "inherit" ]
  run plan_pipeline_orch_json "$plan_file"
  [ "$status" -eq 0 ]
  [ "$(json_field "$output" '.stages[0].nativeSubagents')" = "off" ]
  rm "$plan_file"
}

@test "plan_pipeline rejects misspelled subagents under strict mode" {
  tmpd="$(mktemp -d)"
  plan_file="$tmpd/subagents-misspelled.plan.md"
  cat <<'EOF' > "$plan_file"
---
execution: graph
pipeline:
  stages:
    - id: review
      runtime: cursor
      subagent: on
todos:
  - id: review-1
    stage: review
    content: review the change
    status: pending
---
EOF
  run plan_pipeline_orch_json "$plan_file"
  [ "$status" -ne 0 ]
  [[ "$output" == *"subagent"* ]]
  rm -rf "$tmpd"
}

@test "plan omitting nativeSubagents keeps orch stage byte-identical and graph stage matches orch" {
  tmpd="$(mktemp -d)"
  plan_file="$tmpd/graph-edges.plan.md"
  cp "$BATS_TEST_DIRNAME/../../fixtures/graph/graph-edges.plan.md" "$plan_file"

  run plan_pipeline_orch_json "$plan_file"
  [ "$status" -eq 0 ]
  orch_payload="$(printf '%s\n' "$output" | awk 'END{print}')"
  [ "$(json_field "$orch_payload" '[.stages[] | has("subagents")] | any')" = "false" ]
  expected_stage="$(printf '%s' "$orch_payload" | jq -cS '.stages[] | select(.id=="source")')"

  run plan_pipeline_graph_json "$plan_file"
  [ "$status" -eq 0 ]
  graph_payload="$(printf '%s\n' "$output" | awk 'END{print}')"
  # Graph compilation adds its frozen delegation policy; the shared
  # orchestration projection remains byte-identical once that graph-only
  # field is excluded.
  actual_stage="$(printf '%s' "$graph_payload" | jq -cS '.nodes[] | select(.id=="source") | .stage | del(.delegation)')"
  [ "$actual_stage" = "$expected_stage" ]

  # Explicit inherit must appear in both emitters identically (shared build_orch_stage).
  plan_file="$tmpd/with-native-subagents.plan.md"
  cat <<'EOF' > "$plan_file"
---
execution: graph
pipeline:
  stages:
    - id: source
      runtime: cursor
      nativeSubagents: inherit
      produces:
        - path: .ralph-workspace/artifacts/{{ARTIFACT_NS}}/source.md
todos:
  - id: source-1
    stage: source
    content: produce source
    status: pending
---
EOF
  run plan_pipeline_orch_json "$plan_file"
  [ "$status" -eq 0 ]
  orch_payload="$(printf '%s\n' "$output" | awk 'END{print}')"
  expected_stage="$(printf '%s' "$orch_payload" | jq -cS '.stages[] | select(.id=="source")')"
  [ "$(json_field "$expected_stage" '.nativeSubagents')" = "inherit" ]

  run plan_pipeline_graph_json "$plan_file"
  [ "$status" -eq 0 ]
  graph_payload="$(printf '%s\n' "$output" | awk 'END{print}')"
  actual_stage="$(printf '%s' "$graph_payload" | jq -cS '.nodes[] | select(.id=="source") | .stage | del(.delegation)')"
  [ "$actual_stage" = "$expected_stage" ]
  rm -rf "$tmpd"
}

@test "removed role field: rejects standard TODO role naming inline workflow instructions" {
  plan_file="$(mktemp)"
  cat <<'PLAN' > "$plan_file"
---
todos:
  - id: t1
    runtime: cursor
    role: research
    content: Do the work.
    status: pending
---
PLAN
  run plan_pipeline_validate_plan "$plan_file"
  [ "$status" -ne 0 ]
  [[ "$output" == *"role"* ]]
  [[ "$output" == *"inline workflow instructions"* ]]
  rm "$plan_file"
}

@test "removed role field: rejects stage role naming inline workflow instructions" {
  plan_file="$(mktemp)"
  cat <<'PLAN' > "$plan_file"
---
execution: orchestration
pipeline:
  stages:
    - id: research
      runtime: cursor
      role: research
todos:
  - id: research-1
    stage: research
    content: Investigate.
    status: pending
---
PLAN
  run plan_pipeline_validate_plan "$plan_file"
  [ "$status" -ne 0 ]
  [[ "$output" == *"role"* ]]
  [[ "$output" == *"inline workflow instructions"* ]]
  rm "$plan_file"
}

@test "removed role field: rejects voter role naming inline workflow instructions" {
  plan_file="$(mktemp)"
  cat <<'PLAN' > "$plan_file"
---
execution: graph
pipeline:
  stages:
    - id: implement
      runtime: cursor
      produces:
        - path: .ralph-workspace/artifacts/{{ARTIFACT_NS}}/out.md
          required: true
    - id: review
      type: consensus
      dependsOn:
        - implement
      policy: majority
      quorum: 2
      minRuntimes: 2
      voters:
        - id: a
          runtime: cursor
          role: research
        - id: b
          runtime: claude
      produces:
        - path: .ralph-workspace/artifacts/{{ARTIFACT_NS}}/{{VOTER_ID}}-verdict.json
          required: true
todos:
  - id: implement-1
    stage: implement
    content: Implement.
    status: pending
---
PLAN
  run plan_pipeline_validate_plan "$plan_file"
  [ "$status" -ne 0 ]
  [[ "$output" == *"role"* ]]
  [[ "$output" == *"inline workflow instructions"* ]]
  rm "$plan_file"
}

@test "removed role field: rejects repair diagnose role naming inline workflow instructions" {
  plan_file="$(mktemp)"
  cat <<'PLAN' > "$plan_file"
---
kind: workflow
engine: graph
pipeline:
  stages:
    - id: research
      runtime: cursor
  repairRounds:
    id: epoch
    rounds: 1
    dependsOn:
      - research
    integrate: {}
    gate:
      profile: unit
    diagnose:
      runtime: cursor
      role: research
    reintegrate: {}
    lanes:
      - id: lane-a
        runtime: cursor
        content: Fix the failing scope
  verificationProfiles:
    - name: unit
      steps:
        - name: noop
          command: true
todos:
  - id: research-1
    stage: research
    content: Investigate {{TASK}}
    status: pending
---
PLAN
  run plan_workflow_validate "$plan_file"
  [ "$status" -ne 0 ]
  [[ "$output" == *"role"* ]]
  [[ "$output" == *"inline workflow instructions"* ]]
  rm "$plan_file"
}

@test "removed role field: compiled projection omits role and keeps type agent" {
  plan_file="$(mktemp)"
  cat <<'PLAN' > "$plan_file"
---
execution: graph
pipeline:
  stages:
    - id: research
      type: agent
      runtime: cursor
      nativeSubagents: off
      instructions: Stay focused on evidence.
      produces:
        - path: .ralph-workspace/artifacts/{{ARTIFACT_NS}}/notes.md
          required: true
todos:
  - id: research-1
    stage: research
    content: Investigate.
    status: pending
---
PLAN
  run plan_pipeline_graph_json "$plan_file"
  [ "$status" -eq 0 ]
  graph_payload="$(printf '%s\n' "$output" | awk 'END{print}')"
  node="$(printf '%s' "$graph_payload" | jq -c '.nodes[] | select(.id=="research")')"
  [ "$(printf '%s' "$node" | jq -r '.type')" = "agent" ]
  [ "$(printf '%s' "$node" | jq -r '.stage | has("role")')" = "false" ]
  [ "$(printf '%s' "$node" | jq -r '.stage.nativeSubagents')" = "off" ]
  [ "$(printf '%s' "$node" | jq -r '.stage.instructions')" = "Stay focused on evidence." ]
  rm "$plan_file"
}

@test "removed role field: effective metadata omits role key" {
  plan_file="$(mktemp)"
  cat <<'PLAN' > "$plan_file"
---
execution: orchestration
pipeline:
  stages:
    - id: review
      runtime: codex
      model: gpt-5
todos:
  - id: review-1
    stage: review
    content: Review the change.
    status: pending
---
PLAN
  run plan_pipeline_effective_metadata_json "$plan_file" review-1
  [ "$status" -eq 0 ]
  [ "$(json_field "$output" 'has("role")')" = "false" ]
  [ "$(json_field "$output" '.runtime')" = "codex" ]
  rm "$plan_file"
}

# Generated Ralph plan leaf validation: plan header runtime + model-only TODOs
# (define-generated-ralph-plan-contract)

@test "plan default runtime accepts a model-only generated TODO" {
  plan_file="$(mktemp)"
  cat <<'EOFPLAN' > "$plan_file"
---
name: generated-demo
overview: Generated leaf plan
execution: standard
runtime: cursor
model: auto
sessionStrategy: fresh
instructions: |
  Execute exactly one TODO per iteration.
todos:
  - id: implement-core
    content: Update owned files.
    verification: test -f README.md
    status: pending
  - id: model-only-todo
    model: gpt-5
    content: Use plan default runtime with an explicit model.
    verification: true
    status: pending
---
EOFPLAN

  run plan_pipeline_validate_plan "$plan_file"
  [ "$status" -eq 0 ]
  run plan_pipeline_effective_metadata_json "$plan_file" model-only-todo
  [ "$status" -eq 0 ]
  [ "$(json_field "$output" '.runtime')" = "cursor" ]
  [ "$(json_field "$output" '.model')" = "gpt-5" ]
  rm "$plan_file"
}

@test "model-only generated TODO inherits plan default runtime" {
  plan_file="$(mktemp)"
  cat <<'EOFPLAN' > "$plan_file"
---
name: generated-inherit
overview: Model-only inherits header runtime
runtime: claude
todos:
  - id: model-only-generated-todo
    model: claude-4
    content: Inherit effective runtime from plan frontmatter.
    verification: true
    status: pending
---
EOFPLAN

  run plan_pipeline_validate_plan "$plan_file"
  [ "$status" -eq 0 ]
  run plan_pipeline_effective_metadata_json "$plan_file" model-only-generated-todo
  [ "$status" -eq 0 ]
  [ "$(json_field "$output" '.runtime')" = "claude" ]
  [ "$(json_field "$output" '.model')" = "claude-4" ]
  rm "$plan_file"
}

@test "missing effective runtime rejects model-only TODO without plan default runtime" {
  plan_file="$(mktemp)"
  cat <<'EOFPLAN' > "$plan_file"
---
name: missing-runtime
overview: No plan or TODO runtime
todos:
  - id: model-only-orphan
    model: gpt-5
    content: Model override without any effective runtime.
    verification: true
    status: pending
---
EOFPLAN

  run plan_pipeline_validate_plan "$plan_file"
  [ "$status" -ne 0 ]
  [[ "$output" == *"effective runtime"* ]] || [[ "$output" == *"runtime"* ]]
  rm "$plan_file"
}
