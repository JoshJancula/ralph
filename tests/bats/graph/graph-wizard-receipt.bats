#!/usr/bin/env bats
# G02: the graph completion branch in wizard-pipeline-plan.sh prints a
# concise, pure-text receipt for success, cancellation, and validation
# failure. These functions never execute, compile, or run a graph -- they
# only print the commands an operator would run next.

source "$BATS_TEST_DIRNAME/../helper/load-lib.bash"

WIZARD_PIPELINE_PLAN_SH="$BATS_TEST_DIRNAME/../../../bundle/.ralph/bash-lib/wizard/wizard-pipeline-plan.sh"
ERROR_HANDLING_SH="$BATS_TEST_DIRNAME/../../../bundle/.ralph/bash-lib/error-handling.sh"

setup() {
  source "$ERROR_HANDLING_SH"
  source "$WIZARD_PIPELINE_PLAN_SH"
}

@test "successful graph creation receipt shows the exact four commands with the actual path" {
  run wizard_render_graph_creation_receipt "/tmp/PLAN1.graph.plan.md"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Created graph plan: /tmp/PLAN1.graph.plan.md"* ]]
  [[ "$output" == *"bash .ralph/validate-plan.sh /tmp/PLAN1.graph.plan.md"* ]]
  # The receipt now points at the public workflow verbs; ralph graph is removed.
  [[ "$output" == *"ralph workflow inspect --file /tmp/PLAN1.graph.plan.md --format mermaid"* ]]
  [[ "$output" == *"ralph workflow inspect --file /tmp/PLAN1.graph.plan.md"* ]]
  [[ "$output" == *"ralph workflow start --file /tmp/PLAN1.graph.plan.md"* ]]
  [[ "$output" != *"ralph graph "* ]]
}

@test "successful graph creation receipt explains only run mutates" {
  run wizard_render_graph_creation_receipt "/tmp/PLAN1.graph.plan.md"
  [ "$status" -eq 0 ]
  [[ "$output" == *"read-only: validate plan syntax"* ]]
  [[ "$output" == *"read-only: view the graph shape"* ]]
  [[ "$output" == *"read-only: capability report"* ]]
  [[ "$output" == *"MUTATING: creates a run-state ledger and may invoke a paid model"* ]]
  [[ "$output" == *"Only step 4 (run) mutates state or invokes a model; steps 1-3 are read-only."* ]]
}

@test "successful graph creation receipt shell-escapes a path containing spaces" {
  run wizard_render_graph_creation_receipt "/tmp/my plans/PLAN 1.graph.plan.md"
  [ "$status" -eq 0 ]
  # printf %q escapes the embedded spaces; the raw unescaped path with a
  # literal, unescaped space must never appear as a bare command argument.
  [[ "$output" == *'/tmp/my\ plans/PLAN\ 1.graph.plan.md'* ]]
  [[ "$output" != *"ralph graph run /tmp/my plans/PLAN 1.graph.plan.md"* ]]
}

@test "successful graph creation receipt is identical when stdout is not a TTY" {
  tty_output="$(wizard_render_graph_creation_receipt "/tmp/PLAN1.graph.plan.md")"
  piped_output="$(wizard_render_graph_creation_receipt "/tmp/PLAN1.graph.plan.md" | cat)"
  [ "$tty_output" = "$piped_output" ]
}

@test "cancellation receipt prints exactly the fixed no-command message" {
  run wizard_render_graph_cancellation_receipt
  [ "$status" -eq 0 ]
  [ "$output" = "No plan created; no command was run." ]
}

@test "cancellation receipt never names a plan path or a command" {
  run wizard_render_graph_cancellation_receipt
  [ "$status" -eq 0 ]
  [[ "$output" != *"ralph graph"* ]]
  [[ "$output" != *".plan.md"* ]]
}

@test "validation failure receipt prints only the failing command and remediation" {
  run wizard_render_graph_validation_failure_receipt \
    "bash .ralph/validate-plan.sh /tmp/PLAN1.graph.plan.md" \
    "Fix: node 'implement' has no dependsOn and is not the sole root; add dependsOn or mark it a root explicitly."
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "bash .ralph/validate-plan.sh /tmp/PLAN1.graph.plan.md" ]
  [ "${lines[1]}" = "Fix: node 'implement' has no dependsOn and is not the sole root; add dependsOn or mark it a root explicitly." ]
  # Only two lines: the failing command and its remediation, no mixed dump
  # of the other three (unrelated) commands from the success receipt.
  [ "${#lines[@]}" -eq 2 ]
  [[ "$output" != *"ralph graph render"* ]]
  [[ "$output" != *"ralph graph preflight"* ]]
  [[ "$output" != *"ralph graph run"* ]]
}

@test "none of the three receipt functions execute, compile, or run a graph" {
  fake_bin="$(mktemp -d)"
  for tripwire in ralph bash; do
    :
  done
  # A tripwire `ralph` shim that fails loudly if invoked; since the receipt
  # functions only printf command text, PATH must never resolve to this.
  cat > "$fake_bin/ralph" <<'EOF'
#!/usr/bin/env bash
echo "TRIPWIRE: ralph was executed with: $*" >&2
exit 99
EOF
  chmod +x "$fake_bin/ralph"

  PATH="$fake_bin:$PATH" run wizard_render_graph_creation_receipt "/tmp/PLAN1.graph.plan.md"
  [ "$status" -eq 0 ]
  [[ "$output" != *"TRIPWIRE"* ]]

  PATH="$fake_bin:$PATH" run wizard_render_graph_cancellation_receipt
  [ "$status" -eq 0 ]
  [[ "$output" != *"TRIPWIRE"* ]]

  PATH="$fake_bin:$PATH" run wizard_render_graph_validation_failure_receipt "bash .ralph/validate-plan.sh x" "fix it"
  [ "$status" -eq 0 ]
  [[ "$output" != *"TRIPWIRE"* ]]

  rm -rf "$fake_bin"
}
