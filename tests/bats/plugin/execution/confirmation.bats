#!/usr/bin/env bats

source "$BATS_TEST_DIRNAME/../../helper/load-lib.bash"

EXEC="$REPO_ROOT/bundle/.ralph/plugin-inputs/shared/ralph-plugin-exec.sh"

setup() {
  TEST_TMPDIR="$(cd "$(mktemp -d)" && pwd)"
  FAKE_BIN="$TEST_TMPDIR/bin"
  FAKE_PROJECT="$TEST_TMPDIR/project"
  FAKE_STATE="$TEST_TMPDIR/state"
  FAKE_AGENT="$TEST_TMPDIR/agent"
  RALPH_RECORD="$TEST_TMPDIR/ralph-invocations.log"
  ORCH_RECORD="$TEST_TMPDIR/orchestrator-invocations.log"
  GRAPH_RECORD="$TEST_TMPDIR/graph-invocations.log"
  mkdir -p "$FAKE_BIN" "$FAKE_PROJECT" "$FAKE_STATE" "$FAKE_AGENT"
  write_invocation_traps
  printf '%s\n' '- [ ] demo' >"$FAKE_PROJECT/plan.md"
}

teardown() {
  rm -rf "$TEST_TMPDIR"
}

write_invocation_traps() {
  cat >"$FAKE_BIN/ralph" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"$RALPH_RECORD"
exit 0
EOF
  chmod +x "$FAKE_BIN/ralph"

  cat >"$FAKE_BIN/orchestrator.sh" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"$ORCH_RECORD"
printf '%s\n' "orchestrator must not be invoked; the exec gate is the sole path" >&2
exit 99
EOF
  chmod +x "$FAKE_BIN/orchestrator.sh"

  cat >"$FAKE_BIN/graph-run.sh" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"$GRAPH_RECORD"
printf '%s\n' "graph-run must not be invoked; the exec gate is the sole path" >&2
exit 99
EOF
  chmod +x "$FAKE_BIN/graph-run.sh"
}

exec_env() {
  env PATH="$FAKE_BIN:/usr/bin:/bin:/usr/sbin:/sbin" HOME="$TEST_TMPDIR/home" \
    /bin/bash "$EXEC" "$@"
}

json_from_output() {
  printf '%s\n' "$1" | awk '/^\{/{ line=$0 } END { print line }'
}

assert_zero_invocation() {
  [ ! -f "$RALPH_RECORD" ]
  [ ! -f "$ORCH_RECORD" ]
  [ ! -f "$GRAPH_RECORD" ]
}

assert_ralph_once() {
  [ -f "$RALPH_RECORD" ]
  local count
  count="$(wc -l <"$RALPH_RECORD" | tr -d ' ')"
  [ "$count" -eq 1 ]
  [ ! -f "$ORCH_RECORD" ]
  [ ! -f "$GRAPH_RECORD" ]
}

assert_gate_is_sole_executing_path() {
  local evals
  evals="$(grep -c 'eval "\$COMMAND"' "$EXEC")"
  [ "$evals" -eq 1 ]
  grep -q 'Sole executing path' "$EXEC"
  ! grep -Eq 'orchestrator\.sh|graph-run\.sh' "$EXEC"
}

preview_id() {
  local json
  json="$(json_from_output "$(exec_env preview \
    --kind plan \
    --plan "$FAKE_PROJECT/plan.md" \
    --runtime cursor \
    --model "composer-2" \
    --workspace "$FAKE_PROJECT" \
    --workspace-root "$FAKE_STATE" \
    --agent-workspace "$FAKE_AGENT")")"
  printf '%s\n' "$json" | jq -r '.confirmationId'
}

@test "consent matrix: non-interactive --yes is rejected and does not invoke Ralph" {
  assert_gate_is_sole_executing_path
  local id
  id="$(preview_id)"
  assert_zero_invocation
  run exec_env execute \
    --confirmation-id "$id" \
    --request "run this plan now" \
    --yes \
    --kind plan \
    --plan "$FAKE_PROJECT/plan.md" \
    --runtime cursor \
    --model "composer-2" \
    --workspace "$FAKE_PROJECT" \
    --workspace-root "$FAKE_STATE" \
    --agent-workspace "$FAKE_AGENT"
  [ "$status" -ne 0 ]
  [[ "$output" == *"unknown argument: --yes"* ]]
  assert_zero_invocation
}

@test "consent matrix: confirmation-id mismatch reprints preview and does not invoke" {
  local id
  id="$(preview_id)"
  run exec_env execute \
    --confirmation-id "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff" \
    --request "run this plan now" \
    --kind plan \
    --plan "$FAKE_PROJECT/plan.md" \
    --runtime cursor \
    --model "composer-2" \
    --workspace "$FAKE_PROJECT" \
    --workspace-root "$FAKE_STATE" \
    --agent-workspace "$FAKE_AGENT"
  [ "$status" -ne 0 ]
  [[ "$output" == *"confirmationId: $id"* ]]
  [[ "$output" == *"executionConsent: mismatch"* ]]
  [[ "$output" == *"confirmation id mismatch"* ]]
  assert_zero_invocation
}

@test "consent matrix: quoted, hypothetical, historical, and ambiguous requests do not invoke" {
  local id
  id="$(preview_id)"

  run exec_env execute \
    --confirmation-id "$id" \
    --request '"run this plan now"' \
    --kind plan \
    --plan "$FAKE_PROJECT/plan.md" \
    --runtime cursor \
    --model "composer-2" \
    --workspace "$FAKE_PROJECT" \
    --workspace-root "$FAKE_STATE" \
    --agent-workspace "$FAKE_AGENT"
  [ "$status" -ne 0 ]
  [[ "$output" == *"quoted"* ]]
  assert_zero_invocation

  run exec_env execute \
    --confirmation-id "$id" \
    --request "would you run this plan" \
    --kind plan \
    --plan "$FAKE_PROJECT/plan.md" \
    --runtime cursor \
    --model "composer-2" \
    --workspace "$FAKE_PROJECT" \
    --workspace-root "$FAKE_STATE" \
    --agent-workspace "$FAKE_AGENT"
  [ "$status" -ne 0 ]
  [[ "$output" == *"hypothetical"* ]]
  assert_zero_invocation

  run exec_env execute \
    --confirmation-id "$id" \
    --request "the previous run already ran this" \
    --kind plan \
    --plan "$FAKE_PROJECT/plan.md" \
    --runtime cursor \
    --model "composer-2" \
    --workspace "$FAKE_PROJECT" \
    --workspace-root "$FAKE_STATE" \
    --agent-workspace "$FAKE_AGENT"
  [ "$status" -ne 0 ]
  [[ "$output" == *"historical"* ]]
  assert_zero_invocation

  run exec_env execute \
    --confirmation-id "$id" \
    --request "ok maybe do it" \
    --kind plan \
    --plan "$FAKE_PROJECT/plan.md" \
    --runtime cursor \
    --model "composer-2" \
    --workspace "$FAKE_PROJECT" \
    --workspace-root "$FAKE_STATE" \
    --agent-workspace "$FAKE_AGENT"
  [ "$status" -ne 0 ]
  [[ "$output" == *"ambiguous"* ]]
  assert_zero_invocation
}

@test "consent matrix: declined, closed-stdin, and install-only consent do not invoke" {
  local id
  id="$(preview_id)"

  run bash -c 'printf "no\n" | "$@"' _ env PATH="$FAKE_BIN:/usr/bin:/bin:/usr/sbin:/sbin" \
    HOME="$TEST_TMPDIR/home" /bin/bash "$EXEC" execute \
    --confirmation-id "$id" \
    --request "run this plan now" \
    --kind plan \
    --plan "$FAKE_PROJECT/plan.md" \
    --runtime cursor \
    --model "composer-2" \
    --workspace "$FAKE_PROJECT" \
    --workspace-root "$FAKE_STATE" \
    --agent-workspace "$FAKE_AGENT"
  [ "$status" -ne 0 ]
  [[ "$output" == *"real terminal"* ]]
  assert_zero_invocation

  run bash -c 'exec < /dev/null; exec "$@"' _ env PATH="$FAKE_BIN:/usr/bin:/bin:/usr/sbin:/sbin" \
    HOME="$TEST_TMPDIR/home" /bin/bash "$EXEC" execute \
    --confirmation-id "$id" \
    --request "run this plan now" \
    --kind plan \
    --plan "$FAKE_PROJECT/plan.md" \
    --runtime cursor \
    --model "composer-2" \
    --workspace "$FAKE_PROJECT" \
    --workspace-root "$FAKE_STATE" \
    --agent-workspace "$FAKE_AGENT"
  [ "$status" -ne 0 ]
  [[ "$output" == *"real terminal"* ]] || [[ "$output" == *"operator terminal"* ]]
  assert_zero_invocation

  run exec_env execute \
    --confirmation-id "$id" \
    --request "install Ralph with ./install.sh --global" \
    --kind plan \
    --plan "$FAKE_PROJECT/plan.md" \
    --runtime cursor \
    --model "composer-2" \
    --workspace "$FAKE_PROJECT" \
    --workspace-root "$FAKE_STATE" \
    --agent-workspace "$FAKE_AGENT"
  [ "$status" -ne 0 ]
  [[ "$output" == *"installation consent does not authorize plan execution"* ]]
  assert_zero_invocation

  run bash -c 'exec < /dev/null; exec "$@"' _ env PATH="$FAKE_BIN:/usr/bin:/bin:/usr/sbin:/sbin" \
    HOME="$TEST_TMPDIR/home" /bin/bash "$EXEC" execute \
    --confirmation-id "$id" \
    --request "run this plan now" \
    --install-consent accepted \
    --kind plan \
    --plan "$FAKE_PROJECT/plan.md" \
    --runtime cursor \
    --model "composer-2" \
    --workspace "$FAKE_PROJECT" \
    --workspace-root "$FAKE_STATE" \
    --agent-workspace "$FAKE_AGENT"
  [ "$status" -ne 0 ]
  [[ "$output" == *"installation consent does not authorize plan execution"* ]]
  assert_zero_invocation
}

@test "consent matrix: typing the full confirmation id in a tty invokes Ralph once" {
  assert_gate_is_sole_executing_path
  local id recorded
  id="$(preview_id)"
  run env PATH="$FAKE_BIN:/usr/bin:/bin:/usr/sbin:/sbin" HOME="$TEST_TMPDIR/home" \
    python3 "$REPO_ROOT/tests/fixtures/plugin/pty-confirm.py" "$id" \
    /bin/bash "$EXEC" execute \
    --confirmation-id "$id" \
    --request "please execute this plan" \
    --kind plan \
    --plan "$FAKE_PROJECT/plan.md" \
    --runtime cursor \
    --model "composer-2" \
    --workspace "$FAKE_PROJECT" \
    --workspace-root "$FAKE_STATE" \
    --agent-workspace "$FAKE_AGENT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"executionConsent: accepted"* ]]
  assert_ralph_once
  recorded="$(cat "$RALPH_RECORD")"
  [[ "$recorded" == *"run --plan"* ]]
  [[ "$recorded" != *orchestrat* ]]
}
