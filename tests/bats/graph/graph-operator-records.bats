#!/usr/bin/env bats
# Create-once operator request records under <run-dir>/operator/requests/.

source "$BATS_TEST_DIRNAME/../helper/load-lib.bash"
source "$BATS_TEST_DIRNAME/../../../bundle/.ralph/bash-lib/graph/graph-operator-records.sh"

setup() {
  TMPD="$(mktemp -d)"
  RUN_DIR="$TMPD/run"
  mkdir -p "$RUN_DIR"
  export GRAPH_OPERATOR_NOW="2026-08-13T00:00:00Z"
  export GRAPH_OPERATOR_NONCE="aabbccddeeff00112233445566778899"
  unset GRAPH_OPERATOR_REASON_MAX 2>/dev/null || true
}

teardown() {
  rm -rf "$TMPD"
  unset GRAPH_OPERATOR_NOW GRAPH_OPERATOR_NONCE GRAPH_OPERATOR_REASON_MAX 2>/dev/null || true
}

valid_request_json() {
  jq -nc \
    --arg requestId "${1:-req-001}" \
    --arg effect "${2:-write}" \
    --arg choices_json "${3:-}" \
    '
    {
      requestId: $requestId,
      nonce: "aabbccddeeff00112233445566778899",
      namespace: "op-ns",
      runId: "run-001",
      nodeId: "impl",
      attemptId: "impl-1",
      runtime: "cursor",
      sessionId: "sess-1",
      classification: "operator-permission",
      action: "Bash",
      resource: "src/app.ts",
      effect: $effect,
      reason: "needs write access to apply the patch",
      choices: (if $choices_json == "" then ["allow-once","allow-run","allow-always","deny"] else ($choices_json|fromjson) end),
      createdAt: "2026-08-13T00:00:00Z",
      expiresAt: "2026-08-13T01:00:00Z"
    }
    '
}

@test "operator request record writes contained path with identity effect resource choices timestamps nonce and reason" {
  local json path
  json="$(valid_request_json)"
  run graph_operator_request_write "$RUN_DIR" "$json"
  [ "$status" -eq 0 ]
  path="$output"
  [[ "$path" == */operator/requests/req-001.json ]]
  [ -f "$path" ]
  [ ! -L "$path" ]

  [ "$(jq -r '.schemaVersion' "$path")" = "1" ]
  [ "$(jq -r '.requestId' "$path")" = "req-001" ]
  [ "$(jq -r '.nonce' "$path")" = "aabbccddeeff00112233445566778899" ]
  [ "$(jq -r '.namespace' "$path")" = "op-ns" ]
  [ "$(jq -r '.runId' "$path")" = "run-001" ]
  [ "$(jq -r '.nodeId' "$path")" = "impl" ]
  [ "$(jq -r '.attemptId' "$path")" = "impl-1" ]
  [ "$(jq -r '.runtime' "$path")" = "cursor" ]
  [ "$(jq -r '.sessionId' "$path")" = "sess-1" ]
  [ "$(jq -r '.classification' "$path")" = "operator-permission" ]
  [ "$(jq -r '.action' "$path")" = "Bash" ]
  [ "$(jq -r '.resource' "$path")" = "src/app.ts" ]
  [ "$(jq -r '.effect' "$path")" = "write" ]
  [ "$(jq -r '.reason' "$path")" = "needs write access to apply the patch" ]
  [ "$(jq -c '.choices' "$path")" = '["allow-once","allow-run","allow-always","deny"]' ]
  [ "$(jq -r '.createdAt' "$path")" = "2026-08-13T00:00:00Z" ]
  [ "$(jq -r '.expiresAt' "$path")" = "2026-08-13T01:00:00Z" ]

  run graph_operator_request_read "$RUN_DIR" "req-001"
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '.requestId')" = "req-001" ]
}

@test "operator request record create-once rejects a second write and leaves the original bytes" {
  local json path before after
  json="$(valid_request_json)"
  path="$(graph_operator_request_write "$RUN_DIR" "$json")"
  [ -f "$path" ]
  before="$(shasum "$path" | awk '{print $1}')"

  run graph_operator_request_write "$RUN_DIR" "$json"
  [ "$status" -ne 0 ]
  [[ "$output" == *"already exists"* ]]

  after="$(shasum "$path" | awk '{print $1}')"
  [ "$before" = "$after" ]
  [ "$(jq -r '.requestId' "$path")" = "req-001" ]
}

@test "operator request record rejects traversal in the request id" {
  local json
  json="$(valid_request_json '../escape')"
  run graph_operator_request_write "$RUN_DIR" "$json"
  [ "$status" -ne 0 ]
  [ ! -e "$TMPD/escape.json" ]
  [ ! -e "$RUN_DIR/operator/requests/../escape.json" ]

  json="$(valid_request_json 'foo/../bar')"
  run graph_operator_request_write "$RUN_DIR" "$json"
  [ "$status" -ne 0 ]

  json="$(valid_request_json '/tmp/evil')"
  run graph_operator_request_write "$RUN_DIR" "$json"
  [ "$status" -ne 0 ]
  [ ! -e /tmp/evil.json ]

  run graph_operator_request_path "$RUN_DIR" '..'
  [ "$status" -ne 0 ]
  run graph_operator_request_rel 'operator/requests/req-001'
  [ "$status" -ne 0 ]
}

@test "operator request record rejects symlink escape from the run-dir" {
  local json outside
  outside="$TMPD/outside"
  mkdir -p "$outside"
  ln -s "$outside" "$RUN_DIR/operator"
  json="$(valid_request_json)"
  run graph_operator_request_write "$RUN_DIR" "$json"
  [ "$status" -ne 0 ]
  [ ! -e "$outside/requests/req-001.json" ]
  [ ! -e "$outside/req-001.json" ]
}

@test "operator request record rejects a leaf symlink at the request path" {
  local json
  mkdir -p "$RUN_DIR/operator/requests"
  ln -s "$TMPD/stolen.json" "$RUN_DIR/operator/requests/req-001.json"
  printf 'secret\n' >"$TMPD/stolen.json"
  json="$(valid_request_json)"
  run graph_operator_request_write "$RUN_DIR" "$json"
  [ "$status" -ne 0 ]
  [ "$(cat "$TMPD/stolen.json")" = "secret" ]
}

@test "operator request record rejects malformed effect enum" {
  local json
  json="$(valid_request_json req-001 execute)"
  run graph_operator_request_write "$RUN_DIR" "$json"
  [ "$status" -ne 0 ]
  [[ "$output" == *"malformed operator request effect"* ]]
  [ ! -e "$RUN_DIR/operator/requests/req-001.json" ]

  json="$(valid_request_json req-read WRITE)"
  run graph_operator_request_write "$RUN_DIR" "$json"
  [ "$status" -ne 0 ]
}

@test "operator request record rejects malformed choice enum" {
  local json
  json="$(valid_request_json req-001 write '["allow-once","auto"]')"
  run graph_operator_request_write "$RUN_DIR" "$json"
  [ "$status" -ne 0 ]
  [[ "$output" == *"malformed operator request choice"* ]]
  [ ! -e "$RUN_DIR/operator/requests/req-001.json" ]

  json="$(valid_request_json req-yolo write '["yolo"]')"
  run graph_operator_request_write "$RUN_DIR" "$json"
  [ "$status" -ne 0 ]

  json="$(valid_request_json req-empty write '[]')"
  run graph_operator_request_write "$RUN_DIR" "$json"
  [ "$status" -ne 0 ]
}

@test "operator request record rejects malformed runtime and classification enums" {
  local json
  json="$(valid_request_json | jq -c '.runtime = "gpt"')"
  run graph_operator_request_write "$RUN_DIR" "$json"
  [ "$status" -ne 0 ]
  [[ "$output" == *"malformed operator request runtime"* ]]

  json="$(valid_request_json | jq -c '.classification = "PERMISSION"')"
  run graph_operator_request_write "$RUN_DIR" "$json"
  [ "$status" -ne 0 ]
  [[ "$output" == *"malformed operator request classification"* ]]
}

@test "operator request record bounds and redacts the reason field" {
  local json path long
  long="$(printf 'x%.0s' {1..400})"
  json="$(valid_request_json | jq -c --arg r "$long" '.reason = $r | .requestId = "req-bound"')"
  path="$(graph_operator_request_write "$RUN_DIR" "$json")"
  [ "$(jq -r '.reason | length' "$path")" -le 200 ]
  [[ "$(jq -r '.reason' "$path")" == *... ]]

  json="$(valid_request_json | jq -c '.reason = "token=sk-secretvalue123" | .requestId = "req-redact"')"
  path="$(graph_operator_request_write "$RUN_DIR" "$json")"
  [ "$(jq -r '.reason' "$path")" = "[REDACTED]" ]
}

@test "operator request record rejects malformed timestamps and missing identity" {
  local json
  json="$(valid_request_json | jq -c '.createdAt = "yesterday"')"
  run graph_operator_request_write "$RUN_DIR" "$json"
  [ "$status" -ne 0 ]
  [[ "$output" == *"malformed operator request createdAt"* ]]

  json="$(valid_request_json | jq -c '.expiresAt = "2026/08/13 01:00:00"')"
  run graph_operator_request_write "$RUN_DIR" "$json"
  [ "$status" -ne 0 ]
  [[ "$output" == *"malformed operator request expiry"* ]]

  json="$(valid_request_json | jq -c 'del(.runId)')"
  run graph_operator_request_write "$RUN_DIR" "$json"
  [ "$status" -ne 0 ]
}

@test "operator request record mints a nonce when omitted and keeps resource free of traversal" {
  local json path
  json="$(valid_request_json | jq -c 'del(.nonce)')"
  unset GRAPH_OPERATOR_NONCE
  path="$(graph_operator_request_write "$RUN_DIR" "$json")"
  [ "$(jq -r '.nonce | length' "$path")" -ge 16 ]
  [ "$(jq -r '.nonce' "$path")" != "null" ]

  json="$(valid_request_json req-trav | jq -c '.resource = "../secrets/id_rsa"')"
  run graph_operator_request_write "$RUN_DIR" "$json"
  [ "$status" -ne 0 ]
  [[ "$output" == *"resource may not contain"* ]]
}

seed_active_attempt() {
  local node_id="${1:-impl}"
  local attempt_id="${2:-impl-1}"
  local status="${3:-awaiting-operator}"
  local outcome="${4:-}"
  local last_attempt="${5:-$attempt_id}"
  local runtime="${6:-cursor}"
  mkdir -p "$RUN_DIR/nodes"
  jq -nc \
    --arg nodeId "$node_id" \
    --arg status "$status" \
    --arg attemptId "$attempt_id" \
    --arg lastAttemptId "$last_attempt" \
    --arg outcome "$outcome" \
    --arg runtime "$runtime" \
    '{
      schemaVersion: 3,
      nodeId: $nodeId,
      status: $status,
      lastAttemptId: (if $lastAttemptId == "" then null else $lastAttemptId end),
      attempts: [
        {
          attemptId: $attemptId,
          runtime: $runtime
        } + (if $outcome == "" then {} else {outcome: $outcome} end)
      ]
    }' >"$RUN_DIR/nodes/${node_id}.json"
}

valid_decision_json() {
  jq -nc \
    --arg requestId "${1:-req-001}" \
    --arg decision "${2:-allow-once}" \
    --arg nonce "${3:-aabbccddeeff00112233445566778899}" \
    --arg grant_json "${4:-}" \
    '
    {
      requestId: $requestId,
      nonce: $nonce,
      namespace: "op-ns",
      runId: "run-001",
      nodeId: "impl",
      attemptId: "impl-1",
      runtime: "cursor",
      decision: $decision,
      actorSource: "human",
      decidedAt: "2026-08-13T00:00:00Z"
    } + (if $grant_json == "" then {} else {granted: ($grant_json|fromjson)} end)
    '
}

write_valid_request() {
  local json
  json="${1:-$(valid_request_json)}"
  graph_operator_request_write "$RUN_DIR" "$json"
}

@test "operator decision record writes contained path with identity decision grant actor and timestamp" {
  local path
  write_valid_request >/dev/null
  seed_active_attempt

  run graph_operator_decision_write "$RUN_DIR" "$(valid_decision_json)"
  [ "$status" -eq 0 ]
  path="$output"
  [[ "$path" == */operator/decisions/req-001.json ]]
  [ -f "$path" ]
  [ ! -L "$path" ]

  [ "$(jq -r '.schemaVersion' "$path")" = "1" ]
  [ "$(jq -r '.requestId' "$path")" = "req-001" ]
  [ "$(jq -r '.nonce' "$path")" = "aabbccddeeff00112233445566778899" ]
  [ "$(jq -r '.namespace' "$path")" = "op-ns" ]
  [ "$(jq -r '.runId' "$path")" = "run-001" ]
  [ "$(jq -r '.nodeId' "$path")" = "impl" ]
  [ "$(jq -r '.attemptId' "$path")" = "impl-1" ]
  [ "$(jq -r '.runtime' "$path")" = "cursor" ]
  [ "$(jq -r '.decision' "$path")" = "allow-once" ]
  [ "$(jq -r '.granted.action' "$path")" = "Bash" ]
  [ "$(jq -r '.granted.resource' "$path")" = "src/app.ts" ]
  [ "$(jq -r '.granted.effect' "$path")" = "write" ]
  [ "$(jq -r '.actorSource' "$path")" = "human" ]
  [ "$(jq -r '.decidedAt' "$path")" = "2026-08-13T00:00:00Z" ]

  run graph_operator_decision_read "$RUN_DIR" "req-001"
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '.decision')" = "allow-once" ]
}

@test "operator decision record create-once replay of the identical decision is safe" {
  local path before after
  write_valid_request >/dev/null
  seed_active_attempt
  path="$(graph_operator_decision_write "$RUN_DIR" "$(valid_decision_json)")"
  [ -f "$path" ]
  before="$(shasum "$path" | awk '{print $1}')"

  run graph_operator_decision_write "$RUN_DIR" "$(valid_decision_json)"
  [ "$status" -eq 0 ]
  [ "$output" = "$path" ]

  after="$(shasum "$path" | awk '{print $1}')"
  [ "$before" = "$after" ]
  [ "$(jq -r '.decision' "$path")" = "allow-once" ]
}

@test "operator decision record rejects a conflicting decision and leaves the original bytes" {
  local path before after
  write_valid_request >/dev/null
  seed_active_attempt
  path="$(graph_operator_decision_write "$RUN_DIR" "$(valid_decision_json)")"
  before="$(shasum "$path" | awk '{print $1}')"

  run graph_operator_decision_write "$RUN_DIR" "$(valid_decision_json req-001 deny)"
  [ "$status" -ne 0 ]
  [[ "$output" == *"already resolved"* || "$output" == *"conflicts"* ]]

  after="$(shasum "$path" | awk '{print $1}')"
  [ "$before" = "$after" ]
  [ "$(jq -r '.decision' "$path")" = "allow-once" ]
}

@test "operator decision record rejects nonce mismatch" {
  write_valid_request >/dev/null
  seed_active_attempt
  run graph_operator_decision_write "$RUN_DIR" "$(valid_decision_json req-001 allow-once deadbeefdeadbeef)"
  [ "$status" -ne 0 ]
  [[ "$output" == *"nonce"* ]]
  [ ! -e "$RUN_DIR/operator/decisions/req-001.json" ]
}

@test "operator decision record rejects run node attempt or runtime identity mismatch" {
  write_valid_request >/dev/null
  seed_active_attempt

  run graph_operator_decision_write "$RUN_DIR" "$(valid_decision_json | jq -c '.runId = "run-other"')"
  [ "$status" -ne 0 ]
  [[ "$output" == *"identity"* ]]

  run graph_operator_decision_write "$RUN_DIR" "$(valid_decision_json | jq -c '.nodeId = "other"')"
  [ "$status" -ne 0 ]
  [[ "$output" == *"identity"* ]]

  run graph_operator_decision_write "$RUN_DIR" "$(valid_decision_json | jq -c '.attemptId = "impl-9"')"
  [ "$status" -ne 0 ]
  [[ "$output" == *"identity"* ]]

  run graph_operator_decision_write "$RUN_DIR" "$(valid_decision_json | jq -c '.runtime = "claude"')"
  [ "$status" -ne 0 ]
  [[ "$output" == *"runtime"* ]]
  [ ! -e "$RUN_DIR/operator/decisions/req-001.json" ]
}

@test "operator decision record rejects expired request" {
  write_valid_request >/dev/null
  seed_active_attempt
  GRAPH_OPERATOR_NOW="2026-08-13T02:00:00Z"
  run graph_operator_decision_write "$RUN_DIR" "$(valid_decision_json)"
  [ "$status" -ne 0 ]
  [[ "$output" == *"expired"* ]]
  [ ! -e "$RUN_DIR/operator/decisions/req-001.json" ]
}

@test "operator decision record rejects a choice that is not available" {
  write_valid_request "$(valid_request_json req-001 write '["allow-once","deny"]')" >/dev/null
  seed_active_attempt
  run graph_operator_decision_write "$RUN_DIR" "$(valid_decision_json req-001 allow-always)"
  [ "$status" -ne 0 ]
  [[ "$output" == *"available choice"* ]]
  [ ! -e "$RUN_DIR/operator/decisions/req-001.json" ]
}

@test "operator decision record rejects a broader grant and accepts an exact or narrower grant" {
  local path
  write_valid_request "$(valid_request_json req-001 write | jq -c '.resource = "src/**"')" >/dev/null
  seed_active_attempt

  run graph_operator_decision_write "$RUN_DIR" "$(valid_decision_json req-001 allow-once aabbccddeeff00112233445566778899 '{"action":"Bash","resource":"**","effect":"write"}')"
  [ "$status" -ne 0 ]
  [[ "$output" == *"broader"* ]]

  run graph_operator_decision_write "$RUN_DIR" "$(valid_decision_json req-001 allow-once aabbccddeeff00112233445566778899 '{"action":"Bash","resource":"src/app.ts","effect":"network"}')"
  [ "$status" -ne 0 ]
  [[ "$output" == *"broader"* ]]

  run graph_operator_decision_write "$RUN_DIR" "$(valid_decision_json req-001 allow-once aabbccddeeff00112233445566778899 '{"action":"Edit","resource":"src/app.ts","effect":"write"}')"
  [ "$status" -ne 0 ]
  [[ "$output" == *"action"* ]]

  path="$(graph_operator_decision_write "$RUN_DIR" "$(valid_decision_json req-001 allow-once aabbccddeeff00112233445566778899 '{"action":"Bash","resource":"src/app.ts","effect":"read"}')")"
  [ "$(jq -r '.granted.resource' "$path")" = "src/app.ts" ]
  [ "$(jq -r '.granted.effect' "$path")" = "read" ]
}

@test "operator decision record rejects a stale or inactive attempt" {
  write_valid_request >/dev/null

  seed_active_attempt impl impl-1 failed failed
  run graph_operator_decision_write "$RUN_DIR" "$(valid_decision_json)"
  [ "$status" -ne 0 ]
  [[ "$output" == *"not active"* ]]

  seed_active_attempt impl impl-1 awaiting-operator "" impl-2
  run graph_operator_decision_write "$RUN_DIR" "$(valid_decision_json)"
  [ "$status" -ne 0 ]
  [[ "$output" == *"stale"* ]]

  seed_active_attempt impl impl-1 succeeded succeeded
  run graph_operator_decision_write "$RUN_DIR" "$(valid_decision_json)"
  [ "$status" -ne 0 ]
  [[ "$output" == *"not active"* ]]

  rm -f "$RUN_DIR/nodes/impl.json"
  run graph_operator_decision_write "$RUN_DIR" "$(valid_decision_json)"
  [ "$status" -ne 0 ]
  [[ "$output" == *"active attempt"* || "$output" == *"node ledger"* ]]
  [ ! -e "$RUN_DIR/operator/decisions/req-001.json" ]
}

@test "operator decision record rejects traversal in the request id" {
  write_valid_request >/dev/null
  seed_active_attempt
  run graph_operator_decision_write "$RUN_DIR" "$(valid_decision_json '../escape')"
  [ "$status" -ne 0 ]
  [ ! -e "$TMPD/escape.json" ]
  [ ! -e "$RUN_DIR/operator/decisions/../escape.json" ]

  run graph_operator_decision_path "$RUN_DIR" '..'
  [ "$status" -ne 0 ]
  run graph_operator_decision_rel 'operator/decisions/req-001'
  [ "$status" -ne 0 ]
}

@test "operator decision record concurrent identical decisions yield one record" {
  local path1 path2
  write_valid_request >/dev/null
  seed_active_attempt
  graph_operator_decision_write "$RUN_DIR" "$(valid_decision_json)" >"$TMPD/d1.path" 2>"$TMPD/d1.err" &
  local pid1=$!
  graph_operator_decision_write "$RUN_DIR" "$(valid_decision_json)" >"$TMPD/d2.path" 2>"$TMPD/d2.err" &
  local pid2=$!
  wait $pid1
  local rc1=$?
  wait $pid2
  local rc2=$?
  [ "$rc1" -eq 0 ]
  [ "$rc2" -eq 0 ]
  path1="$(cat "$TMPD/d1.path")"
  path2="$(cat "$TMPD/d2.path")"
  [ "$path1" = "$path2" ]
  [ -f "$path1" ]
  [ "$(find "$RUN_DIR/operator/decisions" -name '*.json' | wc -l | tr -d ' ')" = "1" ]
  [ "$(jq -r '.decision' "$path1")" = "allow-once" ]
}

@test "operator decision record concurrent conflicting decisions keep one winner" {
  local winner
  write_valid_request >/dev/null
  seed_active_attempt
  (
    set +e
    graph_operator_decision_write "$RUN_DIR" "$(valid_decision_json req-001 allow-once)" >"$TMPD/c1.path" 2>"$TMPD/c1.err"
    echo $? >"$TMPD/c1.rc"
  ) &
  local pid1=$!
  (
    set +e
    graph_operator_decision_write "$RUN_DIR" "$(valid_decision_json req-001 deny)" >"$TMPD/c2.path" 2>"$TMPD/c2.err"
    echo $? >"$TMPD/c2.rc"
  ) &
  local pid2=$!
  wait $pid1 $pid2
  local rc1 rc2
  rc1="$(cat "$TMPD/c1.rc")"
  rc2="$(cat "$TMPD/c2.rc")"
  # Exactly one writer persists; the other is a conflict.
  if [[ "$rc1" -eq 0 && "$rc2" -ne 0 ]]; then
    winner="$(cat "$TMPD/c1.path")"
    [ "$(jq -r '.decision' "$winner")" = "allow-once" ]
  elif [[ "$rc2" -eq 0 && "$rc1" -ne 0 ]]; then
    winner="$(cat "$TMPD/c2.path")"
    [ "$(jq -r '.decision' "$winner")" = "deny" ]
  else
    echo "expected one success and one conflict, got rc1=$rc1 rc2=$rc2" >&2
    return 1
  fi
  [ "$(find "$RUN_DIR/operator/decisions" -name '*.json' | wc -l | tr -d ' ')" = "1" ]
}
