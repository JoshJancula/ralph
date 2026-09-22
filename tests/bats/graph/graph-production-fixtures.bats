#!/usr/bin/env bats
# Validates the sanitized graph-production-failure fixture set: schema shape,
# relative paths, stable IDs, and redaction of operator/secret data.
#
# This is input-truth validation only. It does not assert any runtime
# behavior of graph-status, graph-changeset, or graph-state; later TODOs in
# the graph-production-hardening plan add those assertions against the same
# fixtures.

source "$BATS_TEST_DIRNAME/../helper/load-lib.bash"

FIXTURE_DIR="$BATS_TEST_DIRNAME/../../fixtures/graph-production-failure"

# Forbidden literal substrings: operator home paths, shell-expandable home,
# and the historical production run this fixture set was derived from. The
# fixtures must stand on their own as synthetic data, never point back at a
# real run directory.
FORBIDDEN_LITERALS=(
  "/Users/"
  "\$HOME"
  "Bnsvuc"
  "ralph-plugin-beta-graph"
  "run-20260812T020611Z"
)

# Credential-like patterns (case-insensitive), checked with grep -E.
CREDENTIAL_PATTERN='(api[_-]?key|secret[_-]?key|password|passwd|-----BEGIN [A-Z ]*PRIVATE KEY-----|AKIA[0-9A-Z]{16}|ghp_[0-9A-Za-z]{20,}|sk-[0-9A-Za-z]{16,})'

# Maximum length for any single string leaf value. Fixtures must carry only
# compact evidence (IDs, short reasons, short paths) -- never a full task
# prompt or transcript excerpt.
MAX_STRING_LEN=200

fixture_files() {
  find "$FIXTURE_DIR" -maxdepth 1 -type f -name '*.json' | sort
}

@test "fixture directory exists and contains fixture files" {
  [ -d "$FIXTURE_DIR" ]
  local count
  count="$(fixture_files | wc -l | tr -d ' ')"
  [ "$count" -gt 0 ]
}

@test "every fixture is well-formed JSON with required top-level schema fields" {
  local f
  while IFS= read -r f; do
    run jq -e '.' "$f"
    [ "$status" -eq 0 ]

    run jq -e '.schemaVersion == 1' "$f"
    [ "$status" -eq 0 ]

    run jq -e '.case | type == "string" and length > 0' "$f"
    [ "$status" -eq 0 ]

    run jq -e '.description | type == "string" and length > 0' "$f"
    [ "$status" -eq 0 ]

    run jq -e '.fixture | type == "object"' "$f"
    [ "$status" -eq 0 ]
  done < <(fixture_files)
}

@test "fixture case field matches its filename stem" {
  local f base stem case_value
  while IFS= read -r f; do
    base="$(basename "$f")"
    stem="${base%.json}"
    case_value="$(jq -r '.case' "$f")"
    [ "$case_value" = "$stem" ]
  done < <(fixture_files)
}

@test "expected fixture cases are all present" {
  local expected=(
    "duplicate-run-node-attempt-collision"
    "attempt-running-then-terminal-transition"
    "stale-run-recorded-running"
    "empty-concurrency-reduction-metadata"
    "allowed-nested-file-new-ancestor-directories"
    "undeclared-changed-leaf"
    "exit-4-permission-request"
    "clean-completion-then-denied-nonessential-diagnostic"
    "usage-reliable-and-missing-records"
    "graph-contract-write-scope-mismatch"
  )
  local id
  for id in "${expected[@]}"; do
    [ -f "$FIXTURE_DIR/$id.json" ]
  done
}

@test "no fixture contains an absolute path, home expansion, or historical run reference" {
  local f literal
  while IFS= read -r f; do
    for literal in "${FORBIDDEN_LITERALS[@]}"; do
      run grep -F -- "$literal" "$f"
      [ "$status" -ne 0 ]
    done
  done < <(fixture_files)
}

@test "no fixture contains credential-like values" {
  local f
  while IFS= read -r f; do
    run grep -E -i -- "$CREDENTIAL_PATTERN" "$f"
    [ "$status" -ne 0 ]
  done < <(fixture_files)
}

@test "no fixture contains a full task prompt or oversized string evidence" {
  local f longest
  while IFS= read -r f; do
    # Collect the length of the longest string leaf value anywhere in the
    # document; a full task prompt or transcript excerpt would greatly
    # exceed the compact-evidence budget.
    longest="$(jq '[.. | strings | length] | max // 0' "$f")"
    [ "$longest" -le "$MAX_STRING_LEN" ]
  done < <(fixture_files)
}

@test "every fixture file stays within a compact evidence size budget" {
  local f size
  while IFS= read -r f; do
    size="$(wc -c <"$f" | tr -d ' ')"
    [ "$size" -le 2048 ]
  done < <(fixture_files)
}

@test "any path-shaped string field in a fixture is relative and non-traversing" {
  local f paths_json path
  while IFS= read -r f; do
    # Any string leaf that looks like a path (contains a "/") must not be
    # absolute and must not contain a ".." traversal segment.
    paths_json="$(jq -c '[.. | strings | select(contains("/"))]' "$f")"
    while IFS= read -r path; do
      [ -z "$path" ] && continue
      case "$path" in
        /*)
          echo "absolute path in $f: $path" >&2
          return 1
          ;;
      esac
      case "$path" in
        *..*)
          echo "traversal segment in $f: $path" >&2
          return 1
          ;;
      esac
    done < <(printf '%s\n' "$paths_json" | jq -r '.[]')
  done < <(fixture_files)
}

@test "run, node, and attempt identifiers are stable and well-formed" {
  local f ids id
  while IFS= read -r f; do
    ids="$(jq -r '[.. | objects | (.runId?, .nodeId?, .attemptId?)] | map(select(. != null)) | .[]' "$f" 2>/dev/null || true)"
    [ -n "$ids" ]
    while IFS= read -r id; do
      [ -z "$id" ] && continue
      case "$id" in
        node-fixture-*__run-fixture-*__[0-9]*)
          ;;
        run-fixture-*)
          ;;
        node-fixture-*)
          ;;
        *)
          echo "unexpected identifier shape in $f: $id" >&2
          return 1
          ;;
      esac
    done <<<"$ids"
  done < <(fixture_files)
}

@test "attemptId values encode nodeId, runId, and a numeric attempt suffix" {
  local f attempt_ids attempt_id node_id run_id
  while IFS= read -r f; do
    attempt_ids="$(jq -r '[.. | strings | select(test("__.*__[0-9]+$"))] | .[]' "$f")"
    [ -z "$attempt_ids" ] && continue
    node_id="$(jq -r '.fixture.nodeId // empty' "$f")"
    run_id="$(jq -r '.fixture.runId // empty' "$f")"
    while IFS= read -r attempt_id; do
      [ -z "$attempt_id" ] && continue
      if [ -n "$node_id" ]; then
        case "$attempt_id" in
          "$node_id"__*) ;;
          *)
            echo "attemptId $attempt_id does not start with nodeId $node_id in $f" >&2
            return 1
            ;;
        esac
      fi
      if [ -n "$run_id" ]; then
        case "$attempt_id" in
          *"$run_id"*) ;;
          *)
            echo "attemptId $attempt_id does not reference runId $run_id in $f" >&2
            return 1
            ;;
        esac
      fi
    done <<<"$attempt_ids"
  done < <(fixture_files)
}

@test "duplicate-run-node-attempt-collision fixture shares one nodeId across two distinct runIds" {
  local f="$FIXTURE_DIR/duplicate-run-node-attempt-collision.json"
  [ "$(jq -r '.fixture.runs | length' "$f")" -eq 2 ]
  [ "$(jq -r '.fixture.runs[0].runId' "$f")" != "$(jq -r '.fixture.runs[1].runId' "$f")" ]
  [ "$(jq -r '.fixture.runs[0].attemptNumber' "$f")" -eq "$(jq -r '.fixture.runs[1].attemptNumber' "$f")" ]
  [ "$(jq -r '.fixture.runs[0].attemptId | split("__")[0]' "$f")" = "$(jq -r '.fixture.nodeId' "$f")" ]
  [ "$(jq -r '.fixture.runs[1].attemptId | split("__")[0]' "$f")" = "$(jq -r '.fixture.nodeId' "$f")" ]
}

@test "attempt-running-then-terminal-transition fixture keeps one attemptId across two events" {
  local f="$FIXTURE_DIR/attempt-running-then-terminal-transition.json"
  [ "$(jq -r '.fixture.events | length' "$f")" -eq 2 ]
  [ "$(jq -r '.fixture.events[0].attemptId' "$f")" = "$(jq -r '.fixture.events[1].attemptId' "$f")" ]
  [ "$(jq -r '.fixture.events[0].status' "$f")" = "running" ]
  [ "$(jq -r '.fixture.events[1].status' "$f")" = "succeeded" ]
}

@test "stale-run-recorded-running fixture reports running status with an expired heartbeat" {
  local f="$FIXTURE_DIR/stale-run-recorded-running.json"
  [ "$(jq -r '.fixture.status' "$f")" = "running" ]
  [ "$(jq -r '.fixture.heartbeatAt' "$f")" != "$(jq -r '.fixture.observedAt' "$f")" ]
}

@test "empty-concurrency-reduction-metadata fixture has an empty concurrencyReductions object" {
  local f="$FIXTURE_DIR/empty-concurrency-reduction-metadata.json"
  run jq -e '.fixture.concurrencyReductions == {}' "$f"
  [ "$status" -eq 0 ]
}

@test "allowed-nested-file-new-ancestor-directories fixture keeps changed leaves inside writeScopes" {
  local f="$FIXTURE_DIR/allowed-nested-file-new-ancestor-directories.json"
  [ "$(jq -r '.fixture.changedPaths | length' "$f")" -eq 1 ]
  [ "$(jq -r '.fixture.newAncestorDirectories | length' "$f")" -ge 1 ]
  case "$(jq -r '.fixture.changedPaths[0]' "$f")" in
    src/feature/*) ;;
    *) return 1 ;;
  esac
}

@test "undeclared-changed-leaf fixture reports a real out-of-scope leaf" {
  local f="$FIXTURE_DIR/undeclared-changed-leaf.json"
  [ "$(jq -r '.fixture.outOfScope | length' "$f")" -ge 1 ]
  [ "$(jq -r '.fixture.outOfScope[0]' "$f")" = "$(jq -r '.fixture.changedPaths[0]' "$f")" ]
}

@test "exit-4-permission-request fixture carries exit code 4 and a pending decision" {
  local f="$FIXTURE_DIR/exit-4-permission-request.json"
  [ "$(jq -r '.fixture.exitCode' "$f")" -eq 4 ]
  [ "$(jq -r '.fixture.permissionRequest.decision' "$f")" = "pending" ]
}

@test "clean-completion-then-denied-nonessential-diagnostic fixture keeps completion terminal" {
  local f="$FIXTURE_DIR/clean-completion-then-denied-nonessential-diagnostic.json"
  [ "$(jq -r '.fixture.events[0].event' "$f")" = "node-succeeded" ]
  [ "$(jq -r '.fixture.events[1].essential' "$f")" = "false" ]
  [ "$(jq -r '.fixture.events[1].decision' "$f")" = "deny" ]
}

@test "usage-reliable-and-missing-records fixture has one reliable and one missing usage record" {
  local f="$FIXTURE_DIR/usage-reliable-and-missing-records.json"
  [ "$(jq -r '.fixture.attempts[0].usageReliable' "$f")" = "true" ]
  [ "$(jq -r '.fixture.attempts[1].usageReliable' "$f")" = "false" ]
  [ "$(jq -r '.fixture.attempts[1].usage' "$f")" = "null" ]
}

@test "graph-contract-write-scope-mismatch fixture identifies the offending write" {
  local f="$FIXTURE_DIR/graph-contract-write-scope-mismatch.json"
  [ "$(jq -r '.fixture.mismatch | length' "$f")" -eq 1 ]
  [ "$(jq -r '.fixture.mismatch[0]' "$f")" = "config/unscoped.json" ]
}

@test "production topology uses the matching optional role" {
  local plan="$BATS_TEST_TMPDIR/production-topology.plan.md"
  run python3 "$BATS_TEST_DIRNAME/../../fixtures/graph/build_production_topology.py" "$plan"
  [ "$status" -eq 0 ]
  [ "$(grep -c '^      role: implementation$' "$plan")" -eq 27 ]
  ! grep -Eq '^      agent:' "$plan"
}

@test "production topology adds no model pins" {
  local plan="$BATS_TEST_TMPDIR/production-topology.plan.md"
  run python3 "$BATS_TEST_DIRNAME/../../fixtures/graph/build_production_topology.py" "$plan"
  [ "$status" -eq 0 ]
  ! grep -Eq '^[[:space:]]+model:' "$plan"
}
