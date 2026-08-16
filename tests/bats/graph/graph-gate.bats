#!/usr/bin/env bats
# Tests for the gate node: model-free scheduler-owned verification gate.
#
# Coverage:
#   - test pass (all steps exit 0 -> outcome=passed)
#   - assertion failure (a step exits non-zero -> outcome=changes-required)
#   - command-not-found / non-allowlisted command -> outcome=error
#   - timeout -> outcome=error (per gate contract)
#   - signal: SIGTERM from timeout -> treated as timeout
#   - missing required artifact -> outcome=error
#   - large output compaction (full stdout redirected to artifact, not inline)
#   - flaky rerun policy (retry on matching exit code)
#   - concurrent read of live result (atomic write via mktemp+rename)
#   - no model invocation asserted (PATH strips all runtime CLIs)
#   - schema validation includes gate type

source "$BATS_TEST_DIRNAME/../helper/load-lib.bash"
source "$BATS_TEST_DIRNAME/../../../bundle/.ralph/bash-lib/graph/graph-state.sh"
source "$BATS_TEST_DIRNAME/../../../bundle/.ralph/bash-lib/graph/graph-gate.sh"
source "$BATS_TEST_DIRNAME/../../../bundle/.ralph/bash-lib/graph/graph-schedule.sh"

VALIDATE_SCHEMA="$REPO_ROOT/bundle/.ralph/bash-lib/graph/validate-graph-schema.sh"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# write_gate_graph <path> <namespace> <profile_name> [<steps_json>]
# Writes a minimal graph JSON with one gate node referencing <profile_name>.
write_gate_graph() {
  local out_path="$1" ns="$2" profile_name="$3"
  # Use explicit if-else for defaults to avoid bash ${var:-default} brace-
  # termination pitfalls when the default value itself contains } characters.
  local steps_json flaky_json
  if [[ -n "${4:-}" ]]; then
    steps_json="$4"
  else
    steps_json='[{"name":"check","command":"true","timeout":30,"continueOnFailure":false,"requiredArtifacts":[]}]'
  fi
  if [[ -n "${5:-}" ]]; then
    flaky_json="$5"
  else
    flaky_json='{"maxReruns":0,"matchExit":[]}'
  fi
  python3 - "$out_path" "$ns" "$profile_name" "$steps_json" "$flaky_json" <<'PY'
import json, sys
out_path, ns, profile_name, steps_raw, flaky_raw = sys.argv[1:]
steps = json.loads(steps_raw)
flaky = json.loads(flaky_raw)
doc = {
    "schemaVersion": 1,
    "ralphVersion": "1.0.0",
    "name": ns,
    "namespace": ns,
    "maxParallel": 2,
    "failurePolicy": "drain",
    "nodes": [
        {
            "id": "gate-1",
            "type": "gate",
            "dependsOn": [],
            "derivedFrom": "declared",
            "stage": {"id": "gate-1", "profile": profile_name},
        }
    ],
    "edges": [],
    "verificationProfiles": [
        {"name": profile_name, "steps": steps, "flakyRerunPolicy": flaky}
    ],
}
with open(out_path, "w", encoding="utf-8") as fh:
    json.dump(doc, fh)
PY
}

# setup_ledger <tmpd> <ns> <run_id> <graph_json>
# Writes a minimal run.json at the ledger run dir so _graph_schedule_handle_gate_node
# can read roots.stateRoot without the full graph_state_init_run chain.
setup_ledger() {
  local tmpd="$1" ns="$2" run_id="$3" graph_json="$4"
  local state_root run_dir
  state_root="$tmpd/state"
  run_dir="$state_root/graph-runs/$ns/$run_id"
  mkdir -p "$run_dir"
  jq -cn --arg state "$state_root" \
    '{roots:{stateRoot:$state}}' >"$run_dir/run.json"
  printf '%s\n' "$run_dir"
}

# setup_scheduler_globals <workspace> <ns> <run_id> <run_dir> <graph_json>
# Loads the graph index and sets scheduler globals needed by the gate handler.
setup_scheduler_globals() {
  local workspace="$1" ns="$2" run_id="$3" run_dir="$4" graph_json="$5"
  graph_schedule_load_index "$graph_json"
  GRAPH_SCHEDULE_WORKSPACE="$workspace"
  GRAPH_SCHEDULE_NAMESPACE="$ns"
  GRAPH_SCHEDULE_LEDGER_NAMESPACE="$ns"
  GRAPH_SCHEDULE_RUN_ID="$run_id"
  GRAPH_SCHEDULE_GRAPH_JSON="$graph_json"
  GRAPH_SCHEDULE_LEDGER_RUN_DIR="$run_dir"
}

# ---------------------------------------------------------------------------
# Allowlist unit tests
# ---------------------------------------------------------------------------

@test "graph_gate_is_allowed_executable accepts base allowlist entries" {
  graph_gate_is_allowed_executable bash
  graph_gate_is_allowed_executable python3
  graph_gate_is_allowed_executable jq
  graph_gate_is_allowed_executable make
  graph_gate_is_allowed_executable grep
}

@test "graph_gate_is_allowed_executable rejects unlisted executables" {
  run graph_gate_is_allowed_executable curl
  [ "$status" -ne 0 ]
  run graph_gate_is_allowed_executable rm
  [ "$status" -ne 0 ]
  run graph_gate_is_allowed_executable claude
  [ "$status" -ne 0 ]
}

@test "graph_gate_is_allowed_executable accepts extra allowed via env var" {
  run graph_gate_is_allowed_executable mycheck
  [ "$status" -ne 0 ]
  RALPH_GATE_EXTRA_ALLOWED="mycheck" graph_gate_is_allowed_executable mycheck
}

@test "graph_gate_is_allowed_executable strips path components before checking" {
  graph_gate_is_allowed_executable /usr/bin/bash
  graph_gate_is_allowed_executable /usr/local/bin/python3
  run graph_gate_is_allowed_executable /usr/bin/curl
  [ "$status" -ne 0 ]
}

@test "graph_gate_extract_executable returns first token of command string" {
  [ "$(graph_gate_extract_executable "bash -c 'echo hi'")" = "bash" ]
  [ "$(graph_gate_extract_executable "python3 test.py --flag")" = "python3" ]
  [ "$(graph_gate_extract_executable "  jq . file.json")" = "jq" ]
  [ "$(graph_gate_extract_executable "true")" = "true" ]
}

# ---------------------------------------------------------------------------
# graph_gate_run: passed outcome
# ---------------------------------------------------------------------------

@test "graph_gate_run returns 0 and writes passed result when all steps succeed" {
  command -v python3 >/dev/null || skip "python3 required"
  command -v jq >/dev/null || skip "jq required"
  local tmpd ns="gate-pass" run_id="gate-pass-run"
  tmpd="$(mktemp -d)"
  local graph_json="$tmpd/gate-pass.graph.json"
  local state_root="$tmpd/state"
  local result_path="$state_root/artifacts/$ns/gate/gate-1/gate-result.json"

  write_gate_graph "$graph_json" "$ns" "ci" \
    '[{"name":"step-a","command":"true","timeout":30,"continueOnFailure":false,"requiredArtifacts":[]},{"name":"step-b","command":"echo ok","timeout":30,"continueOnFailure":false,"requiredArtifacts":[]}]'

  run graph_gate_run "gate-1" "$graph_json" "$tmpd" "$state_root" "$ns"
  [ "$status" -eq 0 ]
  [ -f "$result_path" ]
  [ "$(jq -r '.outcome' "$result_path")" = "passed" ]
  [ "$(jq -r '.nodeId' "$result_path")" = "gate-1" ]
  [ "$(jq -r '.profileName' "$result_path")" = "ci" ]
  [ "$(jq '.steps | length' "$result_path")" -eq 2 ]
  [ "$(jq -r '.steps[0].outcome' "$result_path")" = "passed" ]
  [ "$(jq -r '.steps[1].outcome' "$result_path")" = "passed" ]
  [ "$(jq '.schemaVersion' "$result_path")" -eq 1 ]

  rm -rf "$tmpd"
}

# ---------------------------------------------------------------------------
# graph_gate_run: assertion failure -> changes-required
# ---------------------------------------------------------------------------

@test "graph_gate_run returns 2 and writes changes-required when a step fails" {
  command -v python3 >/dev/null || skip "python3 required"
  command -v jq >/dev/null || skip "jq required"
  local tmpd ns="gate-fail" run_id="gate-fail-run"
  tmpd="$(mktemp -d)"
  local graph_json="$tmpd/gate-fail.graph.json"
  local state_root="$tmpd/state"
  local result_path="$state_root/artifacts/$ns/gate/gate-1/gate-result.json"

  write_gate_graph "$graph_json" "$ns" "ci" \
    '[{"name":"failing-check","command":"bash -c \"exit 1\"","timeout":30,"continueOnFailure":false,"requiredArtifacts":[]}]'

  run graph_gate_run "gate-1" "$graph_json" "$tmpd" "$state_root" "$ns"
  [ "$status" -eq 2 ]
  [ -f "$result_path" ]
  [ "$(jq -r '.outcome' "$result_path")" = "changes-required" ]
  [ "$(jq -r '.steps[0].outcome' "$result_path")" = "failed" ]
  [ "$(jq '.steps[0].exitCode' "$result_path")" -eq 1 ]
  [ "$(jq '.steps[0].timedOut' "$result_path")" = "false" ]

  rm -rf "$tmpd"
}

@test "graph_gate_run continues after failure when continueOnFailure=true" {
  command -v python3 >/dev/null || skip "python3 required"
  command -v jq >/dev/null || skip "jq required"
  local tmpd ns="gate-continue" run_id="gate-continue-run"
  tmpd="$(mktemp -d)"
  local graph_json="$tmpd/gate-continue.graph.json"
  local state_root="$tmpd/state"
  local result_path="$state_root/artifacts/$ns/gate/gate-1/gate-result.json"

  write_gate_graph "$graph_json" "$ns" "ci" \
    '[{"name":"fail-step","command":"bash -c \"exit 1\"","timeout":30,"continueOnFailure":true,"requiredArtifacts":[]},{"name":"pass-step","command":"true","timeout":30,"continueOnFailure":false,"requiredArtifacts":[]}]'

  run graph_gate_run "gate-1" "$graph_json" "$tmpd" "$state_root" "$ns"
  [ "$status" -eq 2 ]
  [ "$(jq -r '.outcome' "$result_path")" = "changes-required" ]
  [ "$(jq -r '.steps[0].outcome' "$result_path")" = "failed" ]
  [ "$(jq -r '.steps[1].outcome' "$result_path")" = "passed" ]

  rm -rf "$tmpd"
}

@test "graph_gate_run marks remaining steps skipped when continueOnFailure=false" {
  command -v python3 >/dev/null || skip "python3 required"
  command -v jq >/dev/null || skip "jq required"
  local tmpd ns="gate-skip" run_id="gate-skip-run"
  tmpd="$(mktemp -d)"
  local graph_json="$tmpd/gate-skip.graph.json"
  local state_root="$tmpd/state"
  local result_path="$state_root/artifacts/$ns/gate/gate-1/gate-result.json"

  write_gate_graph "$graph_json" "$ns" "ci" \
    '[{"name":"fail-step","command":"bash -c \"exit 1\"","timeout":30,"continueOnFailure":false,"requiredArtifacts":[]},{"name":"skip-step","command":"true","timeout":30,"continueOnFailure":false,"requiredArtifacts":[]}]'

  run graph_gate_run "gate-1" "$graph_json" "$tmpd" "$state_root" "$ns"
  [ "$status" -eq 2 ]
  [ "$(jq -r '.steps[0].outcome' "$result_path")" = "failed" ]
  [ "$(jq -r '.steps[1].outcome' "$result_path")" = "skipped" ]

  rm -rf "$tmpd"
}

# ---------------------------------------------------------------------------
# graph_gate_run: non-allowlisted command -> error
# ---------------------------------------------------------------------------

@test "graph_gate_run returns 1 and writes error when command is not allowlisted" {
  command -v python3 >/dev/null || skip "python3 required"
  command -v jq >/dev/null || skip "jq required"
  local tmpd ns="gate-deny" run_id="gate-deny-run"
  tmpd="$(mktemp -d)"
  local graph_json="$tmpd/gate-deny.graph.json"
  local state_root="$tmpd/state"
  local result_path="$state_root/artifacts/$ns/gate/gate-1/gate-result.json"

  write_gate_graph "$graph_json" "$ns" "ci" \
    '[{"name":"bad-cmd","command":"curl http://example.com","timeout":30,"continueOnFailure":false,"requiredArtifacts":[]}]'

  run graph_gate_run "gate-1" "$graph_json" "$tmpd" "$state_root" "$ns"
  [ "$status" -eq 1 ]
  [ -f "$result_path" ]
  [ "$(jq -r '.outcome' "$result_path")" = "error" ]
  [[ "$(jq -r '.errorReason' "$result_path")" == *"non-allowlisted"* ]]
  [ "$(jq -r '.steps[0].outcome' "$result_path")" = "error" ]

  rm -rf "$tmpd"
}

# ---------------------------------------------------------------------------
# graph_gate_run: missing required artifact -> error
# ---------------------------------------------------------------------------

@test "graph_gate_run returns 1 and writes error when required artifact is absent" {
  command -v python3 >/dev/null || skip "python3 required"
  command -v jq >/dev/null || skip "jq required"
  local tmpd ns="gate-artifact" run_id="gate-artifact-run"
  tmpd="$(mktemp -d)"
  local graph_json="$tmpd/gate-artifact.graph.json"
  local state_root="$tmpd/state"
  local result_path="$state_root/artifacts/$ns/gate/gate-1/gate-result.json"

  write_gate_graph "$graph_json" "$ns" "ci" \
    '[{"name":"needs-file","command":"true","timeout":30,"continueOnFailure":false,"requiredArtifacts":["artifacts/missing/does-not-exist.json"]}]'

  run graph_gate_run "gate-1" "$graph_json" "$tmpd" "$state_root" "$ns"
  [ "$status" -eq 1 ]
  [ -f "$result_path" ]
  [ "$(jq -r '.outcome' "$result_path")" = "error" ]
  [[ "$(jq -r '.errorReason' "$result_path")" == *"missing-artifact"* ]]

  rm -rf "$tmpd"
}

@test "graph_gate_run passes when required artifact exists" {
  command -v python3 >/dev/null || skip "python3 required"
  command -v jq >/dev/null || skip "jq required"
  local tmpd ns="gate-artifact-ok" run_id="gate-artifact-ok-run"
  tmpd="$(mktemp -d)"
  local graph_json="$tmpd/gate-artifact-ok.graph.json"
  local state_root="$tmpd/state"
  local result_path="$state_root/artifacts/$ns/gate/gate-1/gate-result.json"

  # Place the required artifact before the run.
  mkdir -p "$state_root/artifacts/ns-shared"
  echo '{}' >"$state_root/artifacts/ns-shared/build.json"

  write_gate_graph "$graph_json" "$ns" "ci" \
    '[{"name":"needs-file","command":"true","timeout":30,"continueOnFailure":false,"requiredArtifacts":["artifacts/ns-shared/build.json"]}]'

  run graph_gate_run "gate-1" "$graph_json" "$tmpd" "$state_root" "$ns"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.outcome' "$result_path")" = "passed" ]

  rm -rf "$tmpd"
}

# ---------------------------------------------------------------------------
# graph_gate_run: large output compaction
# ---------------------------------------------------------------------------

@test "graph_gate_run stores full step output in artifact file not inline in result" {
  command -v python3 >/dev/null || skip "python3 required"
  command -v jq >/dev/null || skip "jq required"
  local tmpd ns="gate-large" run_id="gate-large-run"
  tmpd="$(mktemp -d)"
  local graph_json="$tmpd/gate-large.graph.json"
  local state_root="$tmpd/state"
  local result_path="$state_root/artifacts/$ns/gate/gate-1/gate-result.json"

  # Generate 200 lines of output (well above any inline summary threshold).
  # Use a pipeline without shell variable expansion to avoid bash double-
  # expansion issues when the command is stored in JSON and re-evaluated.
  write_gate_graph "$graph_json" "$ns" "ci" \
    '[{"name":"verbose-step","command":"bash -c \"seq 1 200 | sed s/^/line-/\"","timeout":30,"continueOnFailure":false,"requiredArtifacts":[]}]'

  run graph_gate_run "gate-1" "$graph_json" "$tmpd" "$state_root" "$ns"
  [ "$status" -eq 0 ]
  [ -f "$result_path" ]
  [ "$(jq -r '.outcome' "$result_path")" = "passed" ]

  # gate-result.json must not contain the full verbose output.
  local result_size
  result_size="$(wc -c <"$result_path")"
  # 200 lines * ~8 bytes each = ~1600 bytes; gate-result.json should be much smaller.
  [ "$result_size" -lt 2000 ]

  # The artifact log must exist and contain the full output.
  local artifact_rel artifact_abs
  artifact_rel="$(jq -r '.steps[0].artifactPath' "$result_path")"
  [ -n "$artifact_rel" ]
  artifact_abs="$state_root/$artifact_rel"
  [ -f "$artifact_abs" ]
  grep -q "line-100" "$artifact_abs"

  rm -rf "$tmpd"
}

# ---------------------------------------------------------------------------
# graph_gate_run: flaky rerun policy
# ---------------------------------------------------------------------------

@test "graph_gate_run retries step matching flakyRerunPolicy.matchExit" {
  command -v python3 >/dev/null || skip "python3 required"
  command -v jq >/dev/null || skip "jq required"
  local tmpd ns="gate-flaky" run_id="gate-flaky-run"
  tmpd="$(mktemp -d)"
  local graph_json="$tmpd/gate-flaky.graph.json"
  local state_root="$tmpd/state"
  local result_path="$state_root/artifacts/$ns/gate/gate-1/gate-result.json"
  local counter_file="$tmpd/counter.txt"
  printf '0' >"$counter_file"

  # Write a script that succeeds only on the second invocation (counter >= 2).
  local step_script="$tmpd/flaky-step.sh"
  cat >"$step_script" <<SCRIPT
#!/usr/bin/env bash
counter_file='$counter_file'
c=\$(cat "\$counter_file" 2>/dev/null || echo 0)
n=\$((c + 1))
printf '%d' "\$n" >"\$counter_file"
[ "\$n" -ge 2 ]
SCRIPT
  chmod +x "$step_script"

  write_gate_graph "$graph_json" "$ns" "ci" \
    "[{\"name\":\"flaky\",\"command\":\"bash $step_script\",\"timeout\":30,\"continueOnFailure\":false,\"requiredArtifacts\":[]}]" \
    '{"maxReruns":1,"matchExit":[1]}'

  run graph_gate_run "gate-1" "$graph_json" "$tmpd" "$state_root" "$ns"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.outcome' "$result_path")" = "passed" ]
  [ "$(jq '.steps[0].reruns' "$result_path")" -eq 1 ]

  rm -rf "$tmpd"
}

@test "graph_gate_run does not retry when exit code does not match matchExit" {
  command -v python3 >/dev/null || skip "python3 required"
  command -v jq >/dev/null || skip "jq required"
  local tmpd ns="gate-no-retry" run_id="gate-no-retry-run"
  tmpd="$(mktemp -d)"
  local graph_json="$tmpd/gate-no-retry.graph.json"
  local state_root="$tmpd/state"
  local result_path="$state_root/artifacts/$ns/gate/gate-1/gate-result.json"

  # Exit 2 does not match matchExit=[1].
  write_gate_graph "$graph_json" "$ns" "ci" \
    '[{"name":"non-flaky-fail","command":"bash -c \"exit 2\"","timeout":30,"continueOnFailure":false,"requiredArtifacts":[]}]' \
    '{"maxReruns":2,"matchExit":[1]}'

  run graph_gate_run "gate-1" "$graph_json" "$tmpd" "$state_root" "$ns"
  [ "$status" -eq 2 ]
  [ "$(jq -r '.outcome' "$result_path")" = "changes-required" ]
  [ "$(jq '.steps[0].reruns' "$result_path")" -eq 0 ]

  rm -rf "$tmpd"
}

# ---------------------------------------------------------------------------
# graph_gate_run: timeout -> error
# ---------------------------------------------------------------------------

@test "graph_gate_run returns 1 and writes error on step timeout" {
  command -v python3 >/dev/null || skip "python3 required"
  command -v jq >/dev/null || skip "jq required"
  local tmpd ns="gate-timeout" run_id="gate-timeout-run"
  tmpd="$(mktemp -d)"
  local graph_json="$tmpd/gate-timeout.graph.json"
  local state_root="$tmpd/state"
  local result_path="$state_root/artifacts/$ns/gate/gate-1/gate-result.json"

  # 1-second timeout on a step that sleeps 60 seconds.
  write_gate_graph "$graph_json" "$ns" "ci" \
    '[{"name":"slow-step","command":"bash -c \"sleep 60\"","timeout":1,"continueOnFailure":false,"requiredArtifacts":[]}]'

  run graph_gate_run "gate-1" "$graph_json" "$tmpd" "$state_root" "$ns"
  [ "$status" -eq 1 ]
  [ -f "$result_path" ]
  [ "$(jq -r '.outcome' "$result_path")" = "error" ]
  [[ "$(jq -r '.errorReason' "$result_path")" == timeout* ]]
  [ "$(jq '.steps[0].timedOut' "$result_path")" = "true" ]
  [ "$(jq -r '.steps[0].outcome' "$result_path")" = "error" ]

  rm -rf "$tmpd"
}

# ---------------------------------------------------------------------------
# graph_gate_run: concurrent read of live result (atomic write)
# ---------------------------------------------------------------------------

@test "gate-result.json is written atomically (no partial reads)" {
  command -v python3 >/dev/null || skip "python3 required"
  command -v jq >/dev/null || skip "jq required"
  local tmpd ns="gate-atomic" run_id="gate-atomic-run"
  tmpd="$(mktemp -d)"
  local graph_json="$tmpd/gate-atomic.graph.json"
  local state_root="$tmpd/state"
  local result_path="$state_root/artifacts/$ns/gate/gate-1/gate-result.json"

  write_gate_graph "$graph_json" "$ns" "ci" \
    '[{"name":"step-a","command":"true","timeout":30,"continueOnFailure":false,"requiredArtifacts":[]}]'

  # Start a concurrent reader that polls for the file.
  # If the file appears mid-write it will be invalid JSON.
  local reader_out="$tmpd/reader.out"
  (
    for i in $(seq 1 100); do
      if [[ -f "$result_path" ]]; then
        jq . "$result_path" >"$reader_out" 2>&1 && break
      fi
      sleep 0.01
    done
  ) &
  local reader_pid=$!

  graph_gate_run "gate-1" "$graph_json" "$tmpd" "$state_root" "$ns"
  local gate_rc=$?

  wait "$reader_pid" 2>/dev/null || true

  [ "$gate_rc" -eq 0 ]
  # The result must be valid JSON.
  jq . "$result_path" >/dev/null
  # If the reader captured the file, it must also be valid JSON.
  if [[ -s "$reader_out" ]]; then
    jq . "$reader_out" >/dev/null
  fi

  rm -rf "$tmpd"
}

# ---------------------------------------------------------------------------
# graph_gate_run: error cases for bad profile configuration
# ---------------------------------------------------------------------------

@test "graph_gate_run returns 1 when profile name not found in verificationProfiles" {
  command -v python3 >/dev/null || skip "python3 required"
  command -v jq >/dev/null || skip "jq required"
  local tmpd ns="gate-noprofile" run_id="gate-noprofile-run"
  tmpd="$(mktemp -d)"
  local graph_json="$tmpd/gate-noprofile.graph.json"
  local state_root="$tmpd/state"

  write_gate_graph "$graph_json" "$ns" "ci"
  # Overwrite the profile name in stage to reference a non-existent profile.
  jq '(.nodes[] | select(.id == "gate-1") | .stage.profile) = "nonexistent"' \
    "$graph_json" >"$graph_json.tmp" && mv "$graph_json.tmp" "$graph_json"

  run graph_gate_run "gate-1" "$graph_json" "$tmpd" "$state_root" "$ns"
  [ "$status" -eq 1 ]

  rm -rf "$tmpd"
}

@test "graph_gate_run returns 1 when node missing stage.profile" {
  command -v python3 >/dev/null || skip "python3 required"
  command -v jq >/dev/null || skip "jq required"
  local tmpd ns="gate-noprof-field" run_id="gate-noprof-field-run"
  tmpd="$(mktemp -d)"
  local graph_json="$tmpd/gate-noprof-field.graph.json"
  local state_root="$tmpd/state"

  write_gate_graph "$graph_json" "$ns" "ci"
  jq 'del(.nodes[] | select(.id == "gate-1") | .stage.profile)' \
    "$graph_json" >"$graph_json.tmp" && mv "$graph_json.tmp" "$graph_json"

  run graph_gate_run "gate-1" "$graph_json" "$tmpd" "$state_root" "$ns"
  [ "$status" -eq 1 ]

  rm -rf "$tmpd"
}

# ---------------------------------------------------------------------------
# No model invocation asserted
# ---------------------------------------------------------------------------

@test "graph_gate_run does not invoke any model runtime CLI" {
  command -v python3 >/dev/null || skip "python3 required"
  command -v jq >/dev/null || skip "jq required"
  local tmpd ns="gate-no-model" run_id="gate-no-model-run"
  tmpd="$(mktemp -d)"
  local graph_json="$tmpd/gate-no-model.graph.json"
  local state_root="$tmpd/state"
  local trap_dir="$tmpd/traps"
  mkdir -p "$trap_dir"

  write_gate_graph "$graph_json" "$ns" "ci" \
    '[{"name":"check","command":"true","timeout":30,"continueOnFailure":false,"requiredArtifacts":[]}]'

  # Install stub executables for all known model CLIs that record invocation.
  local sentinel="$tmpd/model-invoked.flag"
  for cli in claude cursor codex opencode antigravity agy; do
    local stub="$trap_dir/$cli"
    printf '#!/usr/bin/env bash\ntouch "%s"\nexit 0\n' "$sentinel" >"$stub"
    chmod +x "$stub"
  done

  # Prepend trap dir to PATH so stubs shadow any real CLIs.
  PATH="$trap_dir:$PATH" graph_gate_run "gate-1" "$graph_json" "$tmpd" "$state_root" "$ns"
  local gate_rc=$?

  [ "$gate_rc" -eq 0 ]
  # The sentinel must not exist.
  [ ! -f "$sentinel" ]

  rm -rf "$tmpd"
}

# ---------------------------------------------------------------------------
# _graph_schedule_handle_gate_node: scheduler integration
# ---------------------------------------------------------------------------

@test "_graph_schedule_handle_gate_node marks node succeeded when gate passes" {
  command -v python3 >/dev/null || skip "python3 required"
  command -v jq >/dev/null || skip "jq required"
  local tmpd ns="sched-gate-pass" run_id="sched-gate-pass-run"
  tmpd="$(mktemp -d)"
  local graph_json="$tmpd/sched-gate-pass.graph.json"
  local run_dir result_path

  write_gate_graph "$graph_json" "$ns" "ci" \
    '[{"name":"ok","command":"true","timeout":30,"continueOnFailure":false,"requiredArtifacts":[]}]'

  run_dir="$(setup_ledger "$tmpd" "$ns" "$run_id" "$graph_json")"
  setup_scheduler_globals "$tmpd" "$ns" "$run_id" "$run_dir" "$graph_json"

  _graph_schedule_handle_gate_node "gate-1"

  local state
  state="$(graph_schedule_node_state_by_id "gate-1")"
  [ "$state" = "succeeded" ]

  local state_root
  state_root="$(jq -r '.roots.stateRoot' "$run_dir/run.json")"
  result_path="$state_root/artifacts/$ns/gate/gate-1/gate-result.json"
  [ -f "$result_path" ]
  [ "$(jq -r '.outcome' "$result_path")" = "passed" ]

  rm -rf "$tmpd"
}

@test "_graph_schedule_handle_gate_node marks node failed when gate returns changes-required" {
  command -v python3 >/dev/null || skip "python3 required"
  command -v jq >/dev/null || skip "jq required"
  local tmpd ns="sched-gate-fail" run_id="sched-gate-fail-run"
  tmpd="$(mktemp -d)"
  local graph_json="$tmpd/sched-gate-fail.graph.json"
  local run_dir result_path

  write_gate_graph "$graph_json" "$ns" "ci" \
    '[{"name":"failing","command":"bash -c \"exit 1\"","timeout":30,"continueOnFailure":false,"requiredArtifacts":[]}]'

  run_dir="$(setup_ledger "$tmpd" "$ns" "$run_id" "$graph_json")"
  setup_scheduler_globals "$tmpd" "$ns" "$run_id" "$run_dir" "$graph_json"

  _graph_schedule_handle_gate_node "gate-1" || true

  local state
  state="$(graph_schedule_node_state_by_id "gate-1")"
  [ "$state" = "failed" ]

  local state_root
  state_root="$(jq -r '.roots.stateRoot' "$run_dir/run.json")"
  result_path="$state_root/artifacts/$ns/gate/gate-1/gate-result.json"
  [ -f "$result_path" ]
  [ "$(jq -r '.outcome' "$result_path")" = "changes-required" ]

  rm -rf "$tmpd"
}

@test "_graph_schedule_handle_gate_node fails with error when node not found" {
  command -v jq >/dev/null || skip "jq required"
  local tmpd ns="sched-gate-missing" run_id="sched-gate-missing-run"
  tmpd="$(mktemp -d)"
  local graph_json="$tmpd/sched-gate-missing.graph.json"

  # Write a graph without gate-missing node.
  write_gate_graph "$graph_json" "$ns" "ci"
  local run_dir
  run_dir="$(setup_ledger "$tmpd" "$ns" "$run_id" "$graph_json")"
  setup_scheduler_globals "$tmpd" "$ns" "$run_id" "$run_dir" "$graph_json"

  run _graph_schedule_handle_gate_node "gate-missing-node"
  [ "$status" -ne 0 ]

  rm -rf "$tmpd"
}

# ---------------------------------------------------------------------------
# Schema validation: gate type accepted
# ---------------------------------------------------------------------------

@test "validate-graph-schema.sh accepts gate node type" {
  command -v jq >/dev/null || skip "jq required"
  local tmpd ns="schema-gate" run_id="schema-gate-run"
  tmpd="$(mktemp -d)"
  local graph_json="$tmpd/schema-gate.graph.json"

  write_gate_graph "$graph_json" "$ns" "ci"

  run bash "$VALIDATE_SCHEMA" "$graph_json"
  [ "$status" -eq 0 ]

  rm -rf "$tmpd"
}

@test "validate-graph-schema.sh rejects unknown node type" {
  command -v jq >/dev/null || skip "jq required"
  local tmpd ns="schema-bad" run_id="schema-bad-run"
  tmpd="$(mktemp -d)"
  local graph_json="$tmpd/schema-bad.graph.json"

  write_gate_graph "$graph_json" "$ns" "ci"
  jq '(.nodes[] | select(.id == "gate-1") | .type) = "unknown-type"' \
    "$graph_json" >"$graph_json.tmp" && mv "$graph_json.tmp" "$graph_json"

  run bash "$VALIDATE_SCHEMA" "$graph_json"
  [ "$status" -ne 0 ]
  [[ "$output" == *"unknown node type"* ]]

  rm -rf "$tmpd"
}

@test "validate-graph-schema.sh accepts integrate node type" {
  command -v jq >/dev/null || skip "jq required"
  local tmpd
  tmpd="$(mktemp -d)"
  local graph_json="$tmpd/schema-integrate.graph.json"

  jq -n '{
    schemaVersion: 1,
    ralphVersion: "1.0.0",
    name: "schema-integrate",
    namespace: "schema-integrate",
    maxParallel: 2,
    failurePolicy: "drain",
    nodes: [
      {id: "merge", type: "integrate", dependsOn: [], derivedFrom: "declared", stage: {id: "merge"}}
    ],
    edges: []
  }' >"$graph_json"

  run bash "$VALIDATE_SCHEMA" "$graph_json"
  [ "$status" -eq 0 ]

  rm -rf "$tmpd"
}
