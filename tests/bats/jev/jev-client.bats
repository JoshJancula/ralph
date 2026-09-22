#!/usr/bin/env bats
# Tests for bundle/.ralph/bash-lib/jev/jev-client.sh (+ jev-policy.sh).
#
# Isolation: per-test RALPH_JEV_STATE_DIR / RALPH_CONFIG_HOME under mktemp.
# Transport: JEV_TRANSPORT=fixture for offline replay, or a PATH-local curl stub
# that never reaches the network. RALPH_WAIT_SCALE=0 keeps retry backoff tiny.
#
# No sleeps beyond the scaled ralph_wait floor. Every test targets <1s.

source "$BATS_TEST_DIRNAME/../helper/load-lib.bash"

KEY_STORE_LIB="$REPO_ROOT/bundle/.ralph/bash-lib/jev/jev-key-store.sh"
CLIENT_LIB="$REPO_ROOT/bundle/.ralph/bash-lib/jev/jev-client.sh"
POLICY_LIB="$REPO_ROOT/bundle/.ralph/bash-lib/jev/jev-policy.sh"
REDACT_LIB="$REPO_ROOT/bundle/.ralph/bash-lib/jev/jev-redact.sh"
FIXTURE_SRC="$REPO_ROOT/tests/fixtures/jev"
REGISTRY="$REPO_ROOT/bundle/.ralph/jev/questions.registry.json"

JEVC_TEST_KEY="typesafe-jev-client-test-key-42"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

jevc_source_snippet() {
  # Source order: key-store -> client (pulls redact) -> policy.
  printf '%s' '
    source "'"$KEY_STORE_LIB"'"
    source "'"$CLIENT_LIB"'"
    source "'"$POLICY_LIB"'"
  '
}

jevc_write_curl_stub() {
  # Live-transport stub: never dials the network. Counts invocations and emits
  # JEVC_CURL_STATUS / JEVC_CURL_BODY into the -o path / -w status slot.
  # Consumes stdin so `printf | curl --data-binary @-` does not SIGPIPE under
  # pipefail (the live helper always pipes the request body).
  local bindir="$1"
  mkdir -p "$bindir"
  cat >"$bindir/curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
: "${JEVC_CURL_LOG:?}"
if [[ -n "${JEVC_CURL_REQUEST_CAPTURE:-}" ]]; then
  cat >"$JEVC_CURL_REQUEST_CAPTURE" || true
else
  cat >/dev/null || true
fi
printf '1\n' >>"$JEVC_CURL_LOG"
out=""
args=("$@")
i=0
while [[ $i -lt ${#args[@]} ]]; do
  if [[ "${args[$i]}" == "-o" ]]; then
    out="${args[$((i + 1))]:-}"
  fi
  i=$((i + 1))
done
status="${JEVC_CURL_STATUS:-500}"
body="{}"
if [[ -n "${JEVC_CURL_BODY:-}" ]]; then
  body="$JEVC_CURL_BODY"
fi
if [[ -n "$out" ]]; then
  printf '%s\n' "$body" >"$out"
fi
printf '%s' "$status"
exit 0
EOF
  chmod +x "$bindir/curl"
}

jevc_nocurl_path() {
  # PATH that has jq/bash/coreutils but deliberately omits curl.
  local bindir="$1"
  local cmd p
  mkdir -p "$bindir"
  for cmd in bash jq mktemp mkdir rm mv cat printf date tr awk sha256sum shasum openssl uname dirname basename head tail grep sed cut wc env sleep; do
    p="$(command -v "$cmd" 2>/dev/null || true)"
    if [[ -n "$p" && -x "$p" ]]; then
      ln -sfn "$p" "$bindir/$cmd"
    fi
  done
  printf '%s\n' "$bindir"
}

setup() {
  command -v jq >/dev/null || skip "jq required"
  [ -f "$CLIENT_LIB" ] || skip "jev-client.sh missing"
  [ -f "$KEY_STORE_LIB" ] || skip "jev-key-store.sh missing"
  [ -f "$POLICY_LIB" ] || skip "jev-policy.sh missing"

  export RALPH_WAIT_SCALE=0

  JEVC_HOME="$(mktemp -d "${TMPDIR:-/tmp}/ralph-jev-client.XXXXXX")"
  export JEVC_HOME
  export RALPH_CONFIG_HOME="$JEVC_HOME/config"
  export HOME="$JEVC_HOME/home"
  export RALPH_JEV_STATE_DIR="$JEVC_HOME/jev-state"
  export RALPH_JEV_REGISTRY="$REGISTRY"
  export RALPH_DIR="$REPO_ROOT/bundle/.ralph"
  export RALPH_PROJECT_ROOT="$JEVC_HOME/project"
  mkdir -p "$RALPH_CONFIG_HOME" "$HOME" "$RALPH_JEV_STATE_DIR" "$RALPH_PROJECT_ROOT"

  JEVC_BIN="$JEVC_HOME/bin"
  JEVC_CURL_LOG="$JEVC_HOME/curl-attempts.log"
  : >"$JEVC_CURL_LOG"
  export JEVC_CURL_LOG
  jevc_write_curl_stub "$JEVC_BIN"
  export PATH="$JEVC_BIN:$PATH"

  unset RALPH_JEV TYPESAFE_API_KEY RALPH_JEV_KEY_SOURCE RALPH_JEV_SHADOW
  unset JEV_TRANSPORT JEV_FIXTURE_DIR RALPH_JEV_MODEL
  export JEVC_CURL_STATUS=500
  export JEVC_CURL_BODY='{}'
}

teardown() {
  [ -n "${JEVC_HOME:-}" ] && rm -rf "$JEVC_HOME"
}

# ---------------------------------------------------------------------------
# 1. jev_available silent decline (four separate tests)
# ---------------------------------------------------------------------------

@test "jev_available returns 1 silent when RALPH_JEV unset" {
  run bash -c '
    '"$(jevc_source_snippet)"'
    unset RALPH_JEV
    export TYPESAFE_API_KEY="'"$JEVC_TEST_KEY"'"
    out="$(jev_available 2>&1)" && exit 11
    ec=$?
    [ "$ec" -eq 1 ] || exit 12
    [ -z "$out" ] || exit 13
  '
  [ "$status" -eq 0 ]
}

@test "jev_available returns 1 silent when key unset" {
  run bash -c '
    '"$(jevc_source_snippet)"'
    export RALPH_JEV=1
    unset TYPESAFE_API_KEY
    out="$(jev_available 2>&1)" && exit 11
    ec=$?
    [ "$ec" -eq 1 ] || exit 12
    [ -z "$out" ] || exit 13
  '
  [ "$status" -eq 0 ]
}

@test "jev_available returns 1 silent when curl absent" {
  local nocurl
  nocurl="$(jevc_nocurl_path "$JEVC_HOME/nocurl-bin")"
  run env PATH="$nocurl" bash -c '
    '"$(jevc_source_snippet)"'
    export RALPH_JEV=1
    export TYPESAFE_API_KEY="'"$JEVC_TEST_KEY"'"
    unset JEV_TRANSPORT
    command -v curl >/dev/null 2>&1 && exit 20
    out="$(jev_available 2>&1)" && exit 11
    ec=$?
    [ "$ec" -eq 1 ] || exit 12
    [ -z "$out" ] || exit 13
  '
  [ "$status" -eq 0 ]
}

@test "jev_available returns 1 silent when breaker open" {
  run bash -c '
    '"$(jevc_source_snippet)"'
    export RALPH_JEV=1
    export TYPESAFE_API_KEY="'"$JEVC_TEST_KEY"'"
    jev_breaker_open "test" >/dev/null
    out="$(jev_available 2>&1)" && exit 11
    ec=$?
    [ "$ec" -eq 1 ] || exit 12
    [ -z "$out" ] || exit 13
  '
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# 2. jev_unavailable_reason tokens (four separate tests)
# ---------------------------------------------------------------------------

@test "jev_unavailable_reason returns disabled when RALPH_JEV unset" {
  run bash -c '
    '"$(jevc_source_snippet)"'
    unset RALPH_JEV
    [ "$(jev_unavailable_reason)" = "disabled" ]
  '
  [ "$status" -eq 0 ]
}

@test "jev_unavailable_reason returns no-key when key unset" {
  run bash -c '
    '"$(jevc_source_snippet)"'
    export RALPH_JEV=1
    unset TYPESAFE_API_KEY
    [ "$(jev_unavailable_reason)" = "no-key" ]
  '
  [ "$status" -eq 0 ]
}

@test "jev_unavailable_reason returns no-curl when curl absent" {
  local nocurl
  nocurl="$(jevc_nocurl_path "$JEVC_HOME/nocurl-bin")"
  run env PATH="$nocurl" bash -c '
    '"$(jevc_source_snippet)"'
    export RALPH_JEV=1
    export TYPESAFE_API_KEY="'"$JEVC_TEST_KEY"'"
    unset JEV_TRANSPORT
    command -v curl >/dev/null 2>&1 && exit 20
    [ "$(jev_unavailable_reason)" = "no-curl" ]
  '
  [ "$status" -eq 0 ]
}

@test "jev_unavailable_reason returns breaker-open when breaker open" {
  run bash -c '
    '"$(jevc_source_snippet)"'
    export RALPH_JEV=1
    export TYPESAFE_API_KEY="'"$JEVC_TEST_KEY"'"
    jev_breaker_open "test" >/dev/null
    [ "$(jev_unavailable_reason)" = "breaker-open" ]
  '
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# 3-4. Fixture retry / no-retry taxonomy
# ---------------------------------------------------------------------------

@test "429 fixture retries then succeeds" {
  run bash -c '
    '"$(jevc_source_snippet)"'
    export RALPH_WAIT_SCALE=0
    export JEV_TRANSPORT=fixture
    export JEV_FIXTURE_DIR="'"$FIXTURE_SRC"'"
    export TYPESAFE_API_KEY="'"$JEVC_TEST_KEY"'"
    req='"'"'{"state":"x","model":"jev-latest","questions":{},"questionSetId":"retry-429-then-success"}'"'"'
    out="$(jev_post_systemone "$req")" || exit $?
    printf "%s" "$out" | jq -e ".answers.relevant_lines.confidence == 0.87" >/dev/null
    [ "$(jev_breaker_state)" = "closed" ]
  '
  [ "$status" -eq 0 ]
}

@test "401 fixture does not retry and opens the breaker immediately" {
  run bash -c '
    '"$(jevc_source_snippet)"'
    export RALPH_WAIT_SCALE=0
    export JEV_TRANSPORT=fixture
    export JEV_FIXTURE_DIR="'"$FIXTURE_SRC"'"
    export TYPESAFE_API_KEY="'"$JEVC_TEST_KEY"'"
    req='"'"'{"state":"x","model":"jev-latest","questions":{},"questionSetId":"error-401"}'"'"'
    out="$(jev_post_systemone "$req" 2>/dev/null)" && exit 11
    ec=$?
    [ "$ec" -eq 2 ] || exit 12
    [ -z "$out" ] || exit 13
    [ "$(jev_breaker_state)" = "open" ] || exit 14
  '
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# 5-6. Circuit breaker consecutive-failure policy
# ---------------------------------------------------------------------------

@test "two consecutive failures open the breaker; third call makes no HTTP attempt" {
  run bash -c '
    '"$(jevc_source_snippet)"'
    export RALPH_JEV=1
    export TYPESAFE_API_KEY="'"$JEVC_TEST_KEY"'"
    export JEVC_CURL_STATUS=500
    export JEVC_CURL_BODY="{}"
    unset JEV_TRANSPORT
    req='"'"'{"state":"x","model":"jev-latest","questions":{}}'"'"'

    jev_post_systemone "$req" >/dev/null 2>&1 && exit 11
    jev_post_systemone "$req" >/dev/null 2>&1 && exit 12
    [ "$(jev_breaker_state)" = "open" ] || exit 13
    attempts="$(wc -l < "'"$JEVC_CURL_LOG"'" | tr -d "[:space:]")"
    [ "$attempts" -eq 2 ] || exit 14

    # Caller contract: gate on jev_available so an open breaker never dials out.
    if jev_available; then
      jev_post_systemone "$req" >/dev/null 2>&1 || true
    fi
    attempts2="$(wc -l < "'"$JEVC_CURL_LOG"'" | tr -d "[:space:]")"
    [ "$attempts2" -eq 2 ] || exit 15
  '
  [ "$status" -eq 0 ]
}

@test "a success between two failures prevents the breaker opening" {
  run bash -c '
    '"$(jevc_source_snippet)"'
    export RALPH_JEV=1
    export TYPESAFE_API_KEY="'"$JEVC_TEST_KEY"'"
    unset JEV_TRANSPORT
    req='"'"'{"state":"x","model":"jev-latest","questions":{}}'"'"'
    ok_body="$1"

    export JEVC_CURL_STATUS=500 JEVC_CURL_BODY="{}"
    jev_post_systemone "$req" >/dev/null 2>&1 && exit 11

    export JEVC_CURL_STATUS=200 JEVC_CURL_BODY="$ok_body"
    jev_post_systemone "$req" >/dev/null || exit 12

    export JEVC_CURL_STATUS=500 JEVC_CURL_BODY="{}"
    jev_post_systemone "$req" >/dev/null 2>&1 && exit 13

    [ "$(jev_breaker_state)" = "closed" ] || exit 14
  ' _ '{"model":"jev-1.13.0","answers":{"q":{"confidence":0.9}},"usage":{"input_tokens":1,"output_tokens":1}}'
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# 7. Request shape (Section E)
# ---------------------------------------------------------------------------

@test "jev_build_request output matches the Section E request shape" {
  run bash -c '
    '"$(jevc_source_snippet)"'
    source "'"$REDACT_LIB"'"
    state=$(printf "say \"hi\"\nnext line\\with-backslash")
    q='"'"'{"q":{"type":"noul","instructions":"greeting?"}}'"'"'
    out="$(jev_build_request "$state" "$q")" || exit $?
    printf "%s" "$out" | jq -e "
      (keys | sort) == [\"model\",\"questions\",\"state\"]
      and .model == \"jev-latest\"
      and .questions.q.type == \"noul\"
      and (.state | contains(\"next line\"))
    " >/dev/null
  '
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# 8-9. Fixture transport hard guards
# ---------------------------------------------------------------------------

@test "JEV_TRANSPORT=fixture with a key present makes no live call" {
  run bash -c '
    '"$(jevc_source_snippet)"'
    export JEV_TRANSPORT=fixture
    export JEV_FIXTURE_DIR="'"$FIXTURE_SRC"'"
    export TYPESAFE_API_KEY="'"$JEVC_TEST_KEY"'"
    : >"'"$JEVC_CURL_LOG"'"
    req='"'"'{"state":"x","model":"jev-latest","questions":{},"questionSetId":"noul-success"}'"'"'
    out="$(jev_post_systemone "$req")" || exit $?
    printf "%s" "$out" | jq -e ".answers.has_failure.noul == 0.88" >/dev/null || exit 11
    # Curl stub must never have been invoked.
    [ ! -s "'"$JEVC_CURL_LOG"'" ] || exit 12
  '
  [ "$status" -eq 0 ]
}

@test "missing fixture returns 3 rather than falling through to the network" {
  run bash -c '
    '"$(jevc_source_snippet)"'
    export JEV_TRANSPORT=fixture
    export JEV_FIXTURE_DIR="'"$FIXTURE_SRC"'"
    export TYPESAFE_API_KEY="'"$JEVC_TEST_KEY"'"
    : >"'"$JEVC_CURL_LOG"'"
    req='"'"'{"state":"x","model":"jev-latest","questions":{},"questionSetId":"does-not-exist"}'"'"'
    out="$(jev_post_systemone "$req" 2>/dev/null)" && exit 11
    ec=$?
    [ "$ec" -eq 3 ] || exit 12
    [ -z "$out" ] || exit 13
    [ ! -s "'"$JEVC_CURL_LOG"'" ] || exit 14
  '
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# 10. Policy decide bands + unoffered option
# ---------------------------------------------------------------------------

@test "jev_policy_decide returns act gather fallback and unoffered fallback" {
  run bash -c '
    '"$(jevc_source_snippet)"'
    qsid="graph.failure-class"
    act_ans="$1"
    gather_ans="$2"
    fb_ans="$3"
    unoffered_ans="$4"

    act="$(jev_policy_decide "$qsid" "$act_ans")" || exit 11
    printf "%s" "$act" | jq -e ".decision == \"act\" and .reason == \"act\"" >/dev/null || exit 12

    gather="$(jev_policy_decide "$qsid" "$gather_ans")" || exit 13
    printf "%s" "$gather" | jq -e ".decision == \"gather\" and .reason == \"gather\"" >/dev/null || exit 14

    fb="$(jev_policy_decide "$qsid" "$fb_ans")" || exit 15
    printf "%s" "$fb" | jq -e ".decision == \"fallback\" and .reason == \"fallback\"" >/dev/null || exit 16

    unoffered="$(jev_policy_decide "$qsid" "$unoffered_ans")" || exit 17
    printf "%s" "$unoffered" | jq -e ".decision == \"fallback\" and .reason == \"option-not-offered\"" >/dev/null || exit 18
  ' _ \
    '{"failure_class":{"choice":"transient-runtime","confidence":0.9}}' \
    '{"failure_class":{"choice":"transient-runtime","confidence":0.7}}' \
    '{"failure_class":{"choice":"transient-runtime","confidence":0.4}}' \
    '{"failure_class":{"choice":"not-a-real-class","confidence":0.99}}'
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# 11. questionSetId is Ralph-internal and must never reach the wire
# ---------------------------------------------------------------------------

@test "questionSetId is stripped from the live request body" {
  # Regression: SystemOne rejects unknown top-level fields with HTTP 400, so a
  # request carrying Ralph's internal questionSetId failed every live call while
  # fixture replay (which keys off that field) stayed green.
  local capture="$BATS_TEST_TMPDIR/jev-wire-body.json"
  run bash -c '
    '"$(jevc_source_snippet)"'
    unset JEV_TRANSPORT
    export TYPESAFE_API_KEY="'"$JEVC_TEST_KEY"'"
    export JEVC_CURL_STATUS=200
    export JEVC_CURL_BODY='"'"'{"model":"jev-1.13.0","answers":{"has_failure":{"type":"noul","noul":0.5}},"usage":{"input_tokens":1,"output_tokens":1}}'"'"'
    export JEVC_CURL_REQUEST_CAPTURE="'"$capture"'"
    : >"'"$JEVC_CURL_LOG"'"
    req='"'"'{"state":"x","model":"jev-latest","questions":{"has_failure":{"type":"noul","instructions":"q"}},"questionSetId":"graph.failure-class"}'"'"'
    jev_post_systemone "$req" >/dev/null || exit 11
  '
  [ "$status" -eq 0 ]
  [ -s "$capture" ]
  jq -e 'has("questionSetId") | not' "$capture"
  jq -e '(keys | sort) == ["model","questions","state"]' "$capture"
}
