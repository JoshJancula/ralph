#!/usr/bin/env bash
# Jev (TypeSafe AI) optional HTTP client. Source only.
#
# RALPH_JEV defaults to off (unset / non-1). Unlike RALPH_BASH_COMPACT and
# RALPH_PROXY_SHELL_COMPACT, it is deliberately NOT enabled by any RALPH_MODE
# value. For contrast see ralph_apply_mode_compaction_defaults in
# bundle/.ralph/bash-lib/run-plan/run-plan-args.sh.
#
# SECTION C - EXIT CODE CONTRACT (uniform across every jev_ function)
#   0  success
#   1  declined / unavailable. NORMAL. Silent: no stdout, no stderr. Caller falls back.
#   2  transport, HTTP, or protocol error. Recorded to telemetry. Caller falls back.
#   3  input rejected before any network use, e.g. redaction failed or state too large.
# No jev_ function may ever return a non-zero code that propagates as a run failure.
#
# Jev is ALWAYS optional. Most users have no key and no network. Absence is the
# default, not an error path: no warning, no prompt, no failed run. No failure path
# in this library may ever fail a Ralph run.

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  echo "This file is meant to be sourced, not executed." >&2
  exit 1
fi

if [[ -n "${RALPH_JEV_CLIENT_LOADED:-}" ]]; then
  return 0
fi
RALPH_JEV_CLIENT_LOADED=1

_JEV_CLIENT_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if ! declare -F ralph_wait >/dev/null 2>&1; then
  # shellcheck source=../ralph-wait.sh
  source "$_JEV_CLIENT_LIB_DIR/../ralph-wait.sh"
fi

# ---------------------------------------------------------------------------
# Availability gate — the single question every Jev caller asks first.
# Safe under set -e when used as: if jev_available; then ...; fi
# ---------------------------------------------------------------------------

# Return 0 only when Jev is fully usable. Silent on every branch (no stdout/stderr).
jev_available() {
  [[ "${RALPH_JEV:-}" == "1" ]] || return 1

  # Resolve via the Section G chain; never inspect TYPESAFE_API_KEY directly.
  jev_key_resolve >/dev/null 2>&1 || return 1

  if [[ "${JEV_TRANSPORT:-}" != "fixture" ]]; then
    command -v curl >/dev/null 2>&1 || return 1
  fi

  local breaker_state
  breaker_state="$(jev_breaker_state 2>/dev/null || printf 'closed')"
  [[ "$breaker_state" == "closed" ]] || return 1

  return 0
}

# Print exactly one reason token (precedence order). Always exits 0.
# Tokens: ok | disabled | no-key | no-curl | breaker-open
jev_unavailable_reason() {
  if [[ "${RALPH_JEV:-}" != "1" ]]; then
    printf 'disabled\n'
    return 0
  fi

  if ! jev_key_resolve >/dev/null 2>&1; then
    printf 'no-key\n'
    return 0
  fi

  if [[ "${JEV_TRANSPORT:-}" != "fixture" ]] && ! command -v curl >/dev/null 2>&1; then
    printf 'no-curl\n'
    return 0
  fi

  local breaker_state
  breaker_state="$(jev_breaker_state 2>/dev/null || printf 'closed')"
  if [[ "$breaker_state" != "closed" ]]; then
    printf 'breaker-open\n'
    return 0
  fi

  printf 'ok\n'
  return 0
}

# ---------------------------------------------------------------------------
# Circuit breaker — file-persisted under RALPH_JEV_STATE_DIR (not a shell var).
# Compaction PostToolUse hooks are short-lived processes; each invocation is a
# brand-new shell, so an in-memory breaker would never trip where it matters.
#
# Policy:
#   - Two consecutive failures open the breaker for the remainder of the run.
#   - HTTP 401 / 422 open it immediately on the first occurrence.
#   - Success resets the consecutive counter (only while closed).
#   - Once open it stays open; jev_available then returns 1.
#   - Opening writes exactly one decision record (decision=fallback,
#     reason=breaker-open), then stays silent on subsequent calls.
# ---------------------------------------------------------------------------

# Resolve RALPH_JEV_STATE_DIR. Default: <state_root>/jev, where state_root is
# RALPH_PLAN_WORKSPACE_ROOT or $PWD/.ralph-workspace (same as ralph_state_root).
_jev_state_dir() {
  if [[ -n "${RALPH_JEV_STATE_DIR:-}" ]]; then
    printf '%s\n' "${RALPH_JEV_STATE_DIR%/}"
    return 0
  fi
  local state_root="${RALPH_PLAN_WORKSPACE_ROOT:-$PWD/.ralph-workspace}"
  printf '%s/jev\n' "${state_root%/}"
}

# Load "<state> <consecutive>" from the breaker file (defaults: closed 0).
_jev_breaker_load() {
  local dir file state consecutive
  dir="$(_jev_state_dir)" || { printf 'closed 0\n'; return 0; }
  file="${dir}/breaker"
  if [[ ! -f "$file" ]]; then
    printf 'closed 0\n'
    return 0
  fi
  read -r state consecutive <"$file" || true
  case "$state" in
    open|closed) ;;
    *) state="closed" ;;
  esac
  case "${consecutive:-}" in
    ''|*[!0-9]*) consecutive=0 ;;
  esac
  printf '%s %s\n' "$state" "$consecutive"
}

# Atomic write via temp file + mv (concurrent hook processes may race).
_jev_breaker_store() {
  local state="${1:-closed}"
  local consecutive="${2:-0}"
  local dir file tmp
  dir="$(_jev_state_dir)" || return 0
  mkdir -p "$dir" 2>/dev/null || return 0
  file="${dir}/breaker"
  tmp="${file}.tmp.$$"
  if ! printf '%s %s\n' "$state" "$consecutive" >"$tmp" 2>/dev/null; then
    rm -f "$tmp"
    return 0
  fi
  mv -f "$tmp" "$file" 2>/dev/null || rm -f "$tmp"
  return 0
}

# Emit the single open-transition decision record. Prefer jev_record_decision
# when present; otherwise append a minimal JSONL line under RALPH_JEV_STATE_DIR.
_jev_breaker_emit_open_decision() {
  local record dir ts
  if declare -F jev_record_decision >/dev/null 2>&1; then
    if command -v jq >/dev/null 2>&1; then
      record="$(jq -nc \
        '{decision:"fallback",reason:"breaker-open",breakerState:"open",fallbackUsed:true}' \
        2>/dev/null)" || record=""
    else
      record='{"decision":"fallback","reason":"breaker-open","breakerState":"open","fallbackUsed":true}'
    fi
    [[ -n "$record" ]] || return 0
    jev_record_decision "$record" >/dev/null 2>&1 || true
    return 0
  fi
  dir="$(_jev_state_dir)" || return 0
  mkdir -p "$dir" 2>/dev/null || true
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || printf '')"
  printf '{"timestamp":"%s","decision":"fallback","reason":"breaker-open","breakerState":"open","fallbackUsed":true}\n' "$ts" \
    >>"${dir}/decisions.jsonl" 2>/dev/null || true
}

# Print "closed" or "open". Always exits 0.
jev_breaker_state() {
  local state consecutive
  read -r state consecutive <<<"$(_jev_breaker_load)"
  printf '%s\n' "${state:-closed}"
  return 0
}

# Force-open the breaker. Writes one decision record on closed->open only.
# Args: <reason> (caller context; decision reason is always breaker-open).
jev_breaker_open() {
  local reason="${1:-}"
  local state consecutive
  : "${reason:=}"
  read -r state consecutive <<<"$(_jev_breaker_load)"
  if [[ "$state" == "open" ]]; then
    return 0
  fi
  _jev_breaker_store "open" "${consecutive:-0}"
  _jev_breaker_emit_open_decision
  return 0
}

# Record a failure. Opens after two consecutive failures, or immediately on
# http-401 / http-422. Silent once already open.
jev_breaker_record_failure() {
  local reason="${1:-}"
  local state consecutive
  read -r state consecutive <<<"$(_jev_breaker_load)"
  if [[ "$state" == "open" ]]; then
    return 0
  fi
  case "$reason" in
    http-401|http-422)
      jev_breaker_open "$reason"
      return 0
      ;;
  esac
  consecutive=$(( ${consecutive:-0} + 1 ))
  if [[ "$consecutive" -ge 2 ]]; then
    _jev_breaker_store "open" "$consecutive"
    _jev_breaker_emit_open_decision
    return 0
  fi
  _jev_breaker_store "closed" "$consecutive"
  return 0
}

# Reset the consecutive failure counter. Does not close an already-open breaker.
jev_breaker_record_success() {
  local state consecutive
  read -r state consecutive <<<"$(_jev_breaker_load)"
  if [[ "$state" == "open" ]]; then
    return 0
  fi
  _jev_breaker_store "closed" 0
  return 0
}

# ---------------------------------------------------------------------------
# Request builder — redact, size-gate, then jq-owned JSON assembly.
# ---------------------------------------------------------------------------

# Return 0 when state + longest question fit the documented 32k token budget;
# return 1 when they would exceed it.
#
# Ralph owns this arithmetic precisely because Jev is documented as unreliable at
# counting. The point is to window input rather than discover the limit as a 422.
# Heuristic: four bytes per token (deliberately conservative).
jev_estimate_request_size() {
  local state_text="${1:-}"
  local questions_json="${2:-}"
  local max_tokens=32000
  local bytes_per_token=4
  local budget_bytes=$((max_tokens * bytes_per_token))
  local state_bytes longest_q_bytes total

  # Byte length of state (printf avoids a trailing newline wc would count).
  state_bytes="$(printf '%s' "$state_text" | wc -c | tr -d '[:space:]')"
  case "$state_bytes" in
    ''|*[!0-9]*) return 1 ;;
  esac

  if ! command -v jq >/dev/null 2>&1; then
    return 1
  fi

  # Longest question = max compact JSON length among questions object values.
  longest_q_bytes="$(
    printf '%s' "$questions_json" | jq -r '
      if type != "object" then empty
      else ([.[] | tojson | length] | max // 0)
      end
    ' 2>/dev/null
  )" || return 1
  case "$longest_q_bytes" in
    ''|*[!0-9]*) return 1 ;;
  esac

  total=$((state_bytes + longest_q_bytes))
  if [ "$total" -gt "$budget_bytes" ]; then
    return 1
  fi
  return 0
}

# Build the SystemOne request body. Exit 0 with JSON on stdout, or 3 with empty stdout.
# Steps: redact -> size check -> jq assembly. Never emit unredacted or partial JSON.
jev_build_request() {
  local state_text="${1:-}"
  local questions_json="${2:-}"
  local redacted model state_tmp out

  if ! declare -F jev_redact_state >/dev/null 2>&1; then
    return 3
  fi
  if ! command -v jq >/dev/null 2>&1; then
    return 3
  fi

  # Fail closed: redaction failure must not fall back to raw text.
  if ! redacted="$(printf '%s' "$state_text" | jev_redact_state)"; then
    return 3
  fi

  if ! jev_estimate_request_size "$redacted" "$questions_json"; then
    return 3
  fi

  model="${RALPH_JEV_MODEL:-jev-latest}"

  state_tmp="$(mktemp "${TMPDIR:-/tmp}/jev-req-state.XXXXXX")" || return 3
  if ! printf '%s' "$redacted" >"$state_tmp"; then
    rm -f "$state_tmp"
    return 3
  fi

  # jq owns all quoting/escaping; never concatenate JSON in the shell.
  if ! out="$(
    jq -n \
      --rawfile state "$state_tmp" \
      --arg model "$model" \
      --argjson questions "$questions_json" \
      '{state: $state, model: $model, questions: $questions}' \
      2>/dev/null
  )"; then
    rm -f "$state_tmp"
    return 3
  fi
  rm -f "$state_tmp"

  printf '%s\n' "$out"
  return 0
}

# ---------------------------------------------------------------------------
# Live HTTP transport — first sanctioned outbound-internet call in bundle/.ralph.
#
# dashboard_mcp_get in mcp-server.sh is deliberately loopback-only: see
# dashboard_mcp_endpoint_url, which rejects any non-loopback host. This helper
# lives in its own library rather than relaxing that restriction.
# ---------------------------------------------------------------------------

# Silent wrappers for transport paths (never fail a Ralph run).
_jev_breaker_record_failure() {
  local reason="${1:-transport}"
  jev_breaker_record_failure "$reason" >/dev/null 2>&1 || true
}

_jev_breaker_open() {
  local reason="${1:-config}"
  jev_breaker_open "$reason" >/dev/null 2>&1 || true
}

_jev_breaker_record_success() {
  jev_breaker_record_success >/dev/null 2>&1 || true
}

# Terminal failure: empty stdout, record reason, return 2. Never fails a Ralph run.
_jev_post_fail() {
  local reason="${1:-transport}"
  local output_path="${2:-}"
  local cfg_file="${3:-}"
  rm -f "$output_path" "$cfg_file"
  _jev_breaker_record_failure "$reason"
  return 2
}

# ---------------------------------------------------------------------------
# Fixture transport (JEV_TRANSPORT=fixture) — offline replay, never curl.
#
# Filename convention (LOOKUP RULE):
#   1. If request JSON has a non-empty string .questionSetId matching
#      ^[A-Za-z0-9._-]+$, load:
#        $JEV_FIXTURE_DIR/<questionSetId>.json
#   2. Otherwise load:
#        $JEV_FIXTURE_DIR/sha256-<hex>.json
#      where <hex> is the lowercase sha256 of the exact request body bytes.
#   JEV_FIXTURE_DIR defaults to tests/fixtures/jev.
#
# File shapes:
#   - Bare Section A body (implies HTTP 200):
#       {"model":"jev-1.13.0","answers":{...},"usage":{...}}
#   - Single attempt with explicit status (status stripped before emit):
#       {"status":401,"model":"jev-1.13.0","answers":{...},"usage":{...}}
#   - Retry sequence (index = attempt_index from the post retry loop):
#       {"sequence":[{"status":429,...},{"status":200,...}],
#        "model":"...","answers":{...},"usage":{...}}
#     Top-level answers/usage mirror the successful step for static validation.
#     sequence[i] is selected by attempt_index (0-based); past the end uses the
#     last step.
#
# Missing fixture: stderr token "fixture-missing", exit 3. Never falls through
# to a live HTTP call — even when TYPESAFE_API_KEY is set.
# ---------------------------------------------------------------------------

_jev_fixture_dir() {
  printf '%s\n' "${JEV_FIXTURE_DIR:-tests/fixtures/jev}"
}

# Lowercase sha256 hex of stdin bytes. Prefer sha256sum, then shasum, then openssl.
_jev_sha256_hex() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum | awk '{print $1}'
    return 0
  fi
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 | awk '{print $1}'
    return 0
  fi
  if command -v openssl >/dev/null 2>&1; then
    openssl dgst -sha256 | awk '{print $NF}'
    return 0
  fi
  return 1
}

# Resolve fixture file path for a request JSON body. Prints path; exit 0 | 3.
_jev_fixture_path_for_request() {
  local request_json="${1:-}"
  local dir qsid hex
  dir="$(_jev_fixture_dir)"

  if ! command -v jq >/dev/null 2>&1; then
    return 3
  fi

  qsid="$(printf '%s' "$request_json" | jq -r 'if (.questionSetId | type) == "string" and (.questionSetId | length) > 0 then .questionSetId else empty end' 2>/dev/null || true)"
  if [[ -n "$qsid" ]]; then
    # Path-traversal guard: only slug characters.
    case "$qsid" in
      *[!A-Za-z0-9._-]*|'')
        printf 'fixture-missing\n' >&2
        return 3
        ;;
    esac
    printf '%s/%s.json\n' "$dir" "$qsid"
    return 0
  fi

  if ! hex="$(printf '%s' "$request_json" | _jev_sha256_hex)"; then
    printf 'fixture-missing\n' >&2
    return 3
  fi
  # Normalize to lowercase hex.
  hex="$(printf '%s' "$hex" | tr 'A-F' 'a-f')"
  case "$hex" in
    *[!0-9a-f]*|'')
      printf 'fixture-missing\n' >&2
      return 3
      ;;
  esac
  printf '%s/sha256-%s.json\n' "$dir" "$hex"
  return 0
}

# Replay a recorded fixture. Writes response body to output_path; prints HTTP
# status code on stdout.
#   jev_post_systemone_fixture <request_json> <output_path> [attempt_index]
# Exit 0 with a status (any class); exit 3 missing fixture; exit 2 other failure.
jev_post_systemone_fixture() {
  local request_json="${1:-}"
  local output_path="${2:-}"
  local attempt_index="${3:-0}"
  local fixture_path status body seq_len idx

  if [[ -z "$request_json" || -z "$output_path" ]]; then
    return 2
  fi
  if ! command -v jq >/dev/null 2>&1; then
    return 2
  fi
  case "$attempt_index" in
    ''|*[!0-9]*) attempt_index=0 ;;
  esac

  fixture_path=""
  if ! fixture_path="$(_jev_fixture_path_for_request "$request_json")"; then
    return 3
  fi
  if [[ ! -f "$fixture_path" ]]; then
    printf 'fixture-missing\n' >&2
    return 3
  fi

  # Sequence form: pick sequence[attempt_index], clamped to last element.
  if jq -e 'has("sequence") and (.sequence | type) == "array" and (.sequence | length) > 0' <"$fixture_path" >/dev/null 2>&1; then
    seq_len="$(jq -r '.sequence | length' <"$fixture_path" 2>/dev/null)" || return 2
    idx="$attempt_index"
    if [[ "$idx" -ge "$seq_len" ]]; then
      idx=$((seq_len - 1))
    fi
    status="$(jq -r --argjson i "$idx" '.sequence[$i].status // 200' <"$fixture_path" 2>/dev/null)" || return 2
    if ! body="$(jq -c --argjson i "$idx" '
      .sequence[$i]
      | del(.status, .sequence)
      | if has("body") then .body else . end
    ' <"$fixture_path" 2>/dev/null)"; then
      return 2
    fi
  else
    status="$(jq -r '.status // 200' <"$fixture_path" 2>/dev/null)" || return 2
    # Prefer nested .body when present; otherwise strip transport-only keys.
    if ! body="$(jq -c '
      if has("body") then .body
      else del(.status, .sequence)
      end
    ' <"$fixture_path" 2>/dev/null)"; then
      return 2
    fi
  fi

  status="${status//$'\r'/}"
  status="${status//$'\n'/}"
  case "$status" in
    ''|*[!0-9]*) return 2 ;;
  esac

  if ! printf '%s\n' "$body" >"$output_path"; then
    return 2
  fi
  printf '%s\n' "$status"
  return 0
}

# POST request_json to SystemOne. Exit 0 with full response JSON on stdout, or 2
# with empty stdout on any transport / HTTP / protocol failure. Exit 3 when the
# fixture transport cannot resolve a recorded response (reason: fixture-missing).
#
# Habits copied from dashboard_mcp_get: body lands in a mktemp file (never a large
# shell variable), curl writes status via %{http_code}, 2xx is required before
# trusting the body, and rm -f runs on every path.
#
# Error taxonomy (Section B / this TODO):
#   RETRY with ralph_wait exponential backoff, at most RALPH_JEV_MAX_RETRIES
#     (default 2) additional attempts: HTTP 429, HTTP 529.
#   DO NOT RETRY; open breaker immediately: HTTP 401, HTTP 422.
#   DO NOT RETRY beyond the same bound: connection / DNS / timeout failures.
#   Every terminal failure returns 2, emits nothing, and records via
#   jev_breaker_record_failure.
#
# When JEV_TRANSPORT=fixture this function NEVER invokes curl, even if
# TYPESAFE_API_KEY is set. Missing fixtures return 3 (fixture-missing).
# Append one per-call usage line to <state_dir>/usage.jsonl. Best-effort; never
# fails the caller. Mirrors python jev_client.record_usage (same fields).
# Only the successful call is recorded; retried 429/529 attempts are not.
_jev_record_usage() {
  local response_path="${1:-}"
  local request_json="${2:-}"
  local dir line ts
  [[ -f "$response_path" ]] || return 0
  command -v jq >/dev/null 2>&1 || return 0
  dir="$(_jev_state_dir)" || return 0
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || printf '')"
  line="$(
    jq -c -n \
      --slurpfile resp "$response_path" \
      --arg req "$request_json" \
      --arg ts "$ts" \
      --arg transport "${JEV_TRANSPORT:-https}" \
      --arg planKey "$(_jev_artifact_ns)" \
      '
      ($resp[0] // {}) as $r
      | (try ($req | fromjson | .questionSetId // "") catch "") as $qs
      | ($r.usage | if type == "object" then . else {} end) as $u
      | ($u.input_tokens | if type == "number" then (if . < 0 then 0 else floor end) else null end) as $in
      | ($u.output_tokens | if type == "number" then (if . < 0 then 0 else floor end) else null end) as $out
      | {
          timestamp: $ts,
          model: (if ($r.model | type) == "string" and $r.model != "jev-latest" then $r.model else "" end),
          questionSetId: ($qs | if type == "string" then . else "" end),
          input_tokens: ($in // 0),
          output_tokens: ($out // 0),
          usageSource: (if $in != null or $out != null then "measured" else "unavailable" end),
          transport: $transport,
          planKey: $planKey
        }
      ' 2>/dev/null
  )" || return 0
  [[ -n "$line" ]] || return 0
  _jev_append_jsonl "${dir}/usage.jsonl" "$line" || true
  return 0
}

jev_post_systemone() {
  local request_json="${1:-}"
  local endpoint timeout_ms timeout_secs key
  local output_path cfg_file="" status wire_json
  local use_fixture=0 max_retries retries_done backoff
  local attempt_ec fixture_ec

  if [[ -z "$request_json" ]]; then
    return 2
  fi
  if ! command -v jq >/dev/null 2>&1; then
    return 2
  fi

  # Fixture attempts still run through the taxonomy/retry loop below so a
  # 429-then-success sequence and a 401 no-retry path behave identically.
  # Hard guard: fixture mode never prepares curl / never reads a live key path.
  if [[ "${JEV_TRANSPORT:-https}" == "fixture" ]]; then
    use_fixture=1
  else
    if ! command -v curl >/dev/null 2>&1; then
      return 2
    fi
    if ! declare -F jev_key_resolve >/dev/null 2>&1; then
      return 2
    fi

    # Section G chain — never read TYPESAFE_API_KEY directly.
    if ! key="$(jev_key_resolve 2>/dev/null)" || [[ -z "$key" ]]; then
      return 2
    fi

    endpoint="${RALPH_JEV_ENDPOINT:-https://api.typesafe.ai/v1/systemone}"
    timeout_ms="${RALPH_JEV_TIMEOUT_MS:-4000}"
    case "$timeout_ms" in
      ''|*[!0-9]*) timeout_ms=4000 ;;
    esac
    timeout_secs=$(( (timeout_ms + 999) / 1000 ))
    if [[ "$timeout_secs" -lt 1 ]]; then
      timeout_secs=1
    fi

    cfg_file="$(mktemp "${TMPDIR:-/tmp}/ralph-jev-curlcfg.XXXXXX")" || return 2
    # Key never reaches the process argument list: curl --config file written 0600.
    if ! ( umask 077
           printf 'header = "Authorization: Bearer %s"\n' "$key" >"$cfg_file" ); then
      rm -f "$cfg_file"
      return 2
    fi
    # Drop the key from this shell as soon as the config file owns it.
    key=""
  fi

  max_retries="${RALPH_JEV_MAX_RETRIES:-2}"
  case "$max_retries" in
    ''|*[!0-9]*) max_retries=2 ;;
  esac
  retries_done=0

  output_path="$(mktemp "${TMPDIR:-/tmp}/ralph-jev-response.XXXXXX")" || {
    rm -f "$cfg_file"
    return 2
  }

  while true; do
    status=""
    : >"$output_path" 2>/dev/null || true

    if [[ "$use_fixture" -eq 1 ]]; then
      # Fixture contract:
      #   jev_post_systemone_fixture <request_json> <output_path> [attempt_index]
      #   stdout: HTTP status code; body written to output_path
      #   exit 0: produced a status (any class)
      #   exit 3: missing fixture (stderr: fixture-missing; no network, no breaker)
      #   exit 2: other fixture transport failure (bounded retry)
      # Double-check: fixture mode must never reach curl below.
      if [[ "${JEV_TRANSPORT:-}" != "fixture" ]]; then
        rm -f "$output_path" "$cfg_file"
        return 2
      fi
      fixture_ec=0
      status="$(jev_post_systemone_fixture "$request_json" "$output_path" "$retries_done")" || fixture_ec=$?
      if [[ "$fixture_ec" -eq 3 ]]; then
        rm -f "$output_path" "$cfg_file"
        return 3
      fi
      if [[ "$fixture_ec" -ne 0 ]]; then
        if [[ "$retries_done" -lt "$max_retries" ]]; then
          backoff=$((1 << retries_done))
          ralph_wait "$backoff"
          retries_done=$((retries_done + 1))
          continue
        fi
        _jev_post_fail "connection-failure" "$output_path" "$cfg_file"
        return 2
      fi
    else
      # Refuse live curl if transport flipped to fixture mid-call (belt and braces).
      if [[ "${JEV_TRANSPORT:-https}" == "fixture" ]]; then
        rm -f "$output_path" "$cfg_file"
        return 2
      fi
      # questionSetId is Ralph-internal routing metadata (fixture lookup, decision
      # records). SystemOne rejects unknown top-level fields with HTTP 400, so it
      # is stripped here - at the wire - rather than at each call site.
      wire_json="$(jq -c 'del(.questionSetId)' <<<"$request_json" 2>/dev/null)" || wire_json="$request_json"
      # Body via stdin (--data-binary @-); key via --config. Neither appears in argv.
      attempt_ec=0
      status="$(
        printf '%s' "$wire_json" | curl -sS --max-time "$timeout_secs" \
          --config "$cfg_file" \
          -X POST \
          -H 'Content-Type: application/json' \
          --data-binary @- \
          -o "$output_path" \
          -w '%{http_code}' \
          "$endpoint" 2>/dev/null
      )" || attempt_ec=$?

      if [[ "$attempt_ec" -ne 0 ]]; then
        # Connection / DNS / timeout: retry only within the bounded policy.
        if [[ "$retries_done" -lt "$max_retries" ]]; then
          backoff=$((1 << retries_done))
          ralph_wait "$backoff"
          retries_done=$((retries_done + 1))
          continue
        fi
        _jev_post_fail "connection-failure" "$output_path" "$cfg_file"
        return 2
      fi
    fi

    # Normalize status (fixtures may print a trailing newline; curl -w does not).
    status="${status//$'\r'/}"
    status="${status//$'\n'/}"

    case "$status" in
      401)
        # Invalid key: configuration error — no retry, open breaker immediately.
        rm -f "$output_path" "$cfg_file"
        _jev_breaker_open "http-401"
        _jev_breaker_record_failure "http-401"
        return 2
        ;;
      422)
        # Validation failed: configuration error — no retry, open breaker immediately.
        rm -f "$output_path" "$cfg_file"
        _jev_breaker_open "http-422"
        _jev_breaker_record_failure "http-422"
        return 2
        ;;
      429|529)
        # Rate limited / overloaded: bounded exponential backoff then retry.
        if [[ "$retries_done" -lt "$max_retries" ]]; then
          backoff=$((1 << retries_done))
          ralph_wait "$backoff"
          retries_done=$((retries_done + 1))
          continue
        fi
        _jev_post_fail "http-${status}" "$output_path" "$cfg_file"
        return 2
        ;;
    esac

    if [[ ! "$status" =~ ^2[0-9][0-9]$ ]]; then
      _jev_post_fail "http-${status:-unknown}" "$output_path" "$cfg_file"
      return 2
    fi

    if ! jq -e 'type == "object" and has("answers")' <"$output_path" >/dev/null 2>&1; then
      _jev_post_fail "protocol" "$output_path" "$cfg_file"
      return 2
    fi

    _jev_record_usage "$output_path" "$request_json"

    # Emit from the temp file; never hold the full body in a shell variable.
    cat "$output_path"
    rm -f "$output_path" "$cfg_file"
    _jev_breaker_record_success
    return 0
  done
}

# ---------------------------------------------------------------------------
# Decision telemetry — append-only decisions.jsonl + immutable response bodies.
#
# Field naming follows hook-telemetry.sh (camelCase: planKey, requestId, …).
# Appends use a single printf (PIPE_BUF-atomic on POSIX) so concurrent hook
# processes do not interleave lines. Response bodies use temp-file + mv.
#
# model MUST be the RESOLVED version from the response body (e.g. jev-1.13.0),
# never the jev-latest alias — aliases move and would make history unreplayable.
# ---------------------------------------------------------------------------

if ! declare -F jev_redact_secrets_inline >/dev/null 2>&1; then
  # shellcheck source=./jev-redact.sh
  source "$_JEV_CLIENT_LIB_DIR/jev-redact.sh"
fi

# Artifact namespace: RALPH_ARTIFACT_NS falling back to RALPH_PLAN_KEY (repo-wide).
_jev_artifact_ns() {
  printf '%s\n' "${RALPH_ARTIFACT_NS:-${RALPH_PLAN_KEY:-}}"
}

# Generate a request id (16 hex chars when hashing is available).
_jev_new_request_id() {
  local seed hex
  seed="$(date -u +%Y%m%d%H%M%S 2>/dev/null || printf 't')-$$-${RANDOM:-0}-${SECONDS:-0}"
  if hex="$(printf '%s' "$seed" | _jev_sha256_hex 2>/dev/null)"; then
    hex="$(printf '%s' "$hex" | tr 'A-F' 'a-f')"
    printf '%s\n' "${hex:0:16}"
    return 0
  fi
  printf 'r%s%05d\n' "$(date -u +%Y%m%d%H%M%S 2>/dev/null || printf '0')" "$$"
}

# Single-printf JSONL append (same convention as ralph_hook_telemetry_append_jsonl).
_jev_append_jsonl() {
  local path="${1:-}"
  local line="${2:-}"
  [[ -n "$path" && -n "$line" ]] || return 1
  mkdir -p "$(dirname "$path")" 2>/dev/null || return 1
  printf '%s\n' "$line" >>"$path" 2>/dev/null || return 1
}

# Immutable write via temp file + mv (survives concurrent hook processes).
_jev_write_atomic() {
  local path="${1:-}"
  local content="${2:-}"
  local dir tmp
  [[ -n "$path" ]] || return 1
  dir="$(dirname "$path")"
  mkdir -p "$dir" 2>/dev/null || return 1
  tmp="${path}.tmp.$$"
  if ! printf '%s\n' "$content" >"$tmp" 2>/dev/null; then
    rm -f "$tmp"
    return 1
  fi
  mv -f "$tmp" "$path" 2>/dev/null || {
    rm -f "$tmp"
    return 1
  }
  return 0
}

# True when model is a concrete resolved version (not empty, not jev-latest).
_jev_model_is_resolved() {
  local model="${1:-}"
  [[ -n "$model" && "$model" != "jev-latest" && "$model" != "null" ]]
}

# jev_record_decision <decision_record_json>
# Append exactly one redacted Section E decision line to
# <RALPH_JEV_STATE_DIR>/decisions.jsonl and store the response body under
# responses/<requestId>.json. Exit 0 on success; 3 if redaction/input fails.
# Silent on stdout. Never fails a Ralph run.
jev_record_decision() {
  local input_json="${1:-}"
  local dir log_path responses_dir request_id plan_key ts
  local raw_response resolved_model record_line redacted_line response_path
  local response_to_store

  [[ -n "$input_json" ]] || return 0
  if ! command -v jq >/dev/null 2>&1; then
    return 3
  fi
  if ! declare -F jev_redact_secrets_inline >/dev/null 2>&1; then
    return 3
  fi

  # Reject non-object input before any write.
  if ! printf '%s' "$input_json" | jq -e 'type == "object"' >/dev/null 2>&1; then
    return 3
  fi

  dir="$(_jev_state_dir)" || return 0
  plan_key="$(_jev_artifact_ns)"
  request_id="$(_jev_new_request_id)"
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || printf '')"

  # Prefer an embedded raw response (camelCase, hook-telemetry style); else
  # reconstruct {model,answers,usage} so audit replay still has a body.
  raw_response="$(
    printf '%s' "$input_json" | jq -c '
      if (.rawResponse | type) == "object" then .rawResponse
      elif (.responseBody | type) == "object" then .responseBody
      elif (.response | type) == "object" then .response
      else
        {
          model: (.model // ""),
          answers: (.answers // {}),
          usage: (.usage // {input_tokens: 0, output_tokens: 0})
        }
      end
    ' 2>/dev/null
  )" || raw_response=""

  # model MUST come from the resolved response-body version, never jev-latest.
  resolved_model="$(
    printf '%s' "$raw_response" | jq -r '
      if (.model | type) == "string" and (.model | length) > 0 and .model != "jev-latest"
      then .model else empty end
    ' 2>/dev/null
  )" || resolved_model=""
  if ! _jev_model_is_resolved "$resolved_model"; then
    resolved_model="$(
      printf '%s' "$input_json" | jq -r '
        if (.model | type) == "string" and (.model | length) > 0 and .model != "jev-latest"
        then .model else empty end
      ' 2>/dev/null
    )" || resolved_model=""
  fi
  if ! _jev_model_is_resolved "$resolved_model"; then
    resolved_model=""
  fi

  # Normalize to Section E keys; keep useful extras (e.g. reason) from input.
  # Strip raw-response carriers so secrets in echoed error strings do not linger.
  if ! record_line="$(
    printf '%s' "$input_json" | jq -c \
      --arg timestamp "$ts" \
      --arg model "$resolved_model" \
      --arg requestId "$request_id" \
      --arg planKey "$plan_key" \
      '
      del(.rawResponse, .responseBody, .response, .raw_response)
      | . as $in
      | {
          timestamp: (if ($in.timestamp | type) == "string" and ($in.timestamp | length) > 0
                      then $in.timestamp else $timestamp end),
          surface: ($in.surface // ""),
          questionSetId: ($in.questionSetId // ""),
          registryVersion: ($in.registryVersion // "1"),
          questionSetVersion: ($in.questionSetVersion // 1),
          model: $model,
          answers: (if ($in.answers | type) == "object" then $in.answers else {} end),
          decision: ($in.decision // "fallback"),
          chosen: (if ($in | has("chosen")) then $in.chosen else null end),
          confidence: (if ($in | has("confidence")) then $in.confidence else 0 end),
          # jq "//" treats false as missing — use has() for booleans.
          fallbackUsed: (if ($in | has("fallbackUsed")) then $in.fallbackUsed else true end),
          shadow: (if ($in | has("shadow")) then $in.shadow else false end),
          latencyMs: (if ($in | has("latencyMs")) then $in.latencyMs else 0 end),
          usage: (if ($in.usage | type) == "object"
                  then $in.usage
                  else {input_tokens: 0, output_tokens: 0} end),
          breakerState: ($in.breakerState // "closed"),
          transport: ($in.transport // "https"),
          requestId: $requestId,
          planKey: $planKey
        }
      + (if ($in.reason | type) == "string" then {reason: $in.reason} else {} end)
      '
  )"; then
    return 3
  fi
  [[ -n "$record_line" ]] || return 3

  # Fail closed: never write unredacted decision lines.
  if ! redacted_line="$(jev_redact_secrets_inline "$record_line")"; then
    return 3
  fi
  # Drop the trailing newline jev_redact_secrets_inline adds; append adds its own.
  redacted_line="${redacted_line%$'\n'}"
  [[ -n "$redacted_line" ]] || return 3

  # Store response body (also redacted) under responses/<requestId>.json.
  if [[ -n "$raw_response" ]]; then
    # Ensure stored body carries the resolved model, not jev-latest.
    response_to_store="$(
      printf '%s' "$raw_response" | jq -c --arg model "$resolved_model" '
        if $model != "" then .model = $model
        elif (.model // "") == "jev-latest" then .model = ""
        else . end
      ' 2>/dev/null
    )" || response_to_store="$raw_response"
    if ! response_to_store="$(jev_redact_secrets_inline "$response_to_store")"; then
      return 3
    fi
    response_to_store="${response_to_store%$'\n'}"
    responses_dir="${dir}/responses"
    response_path="${responses_dir}/${request_id}.json"
    _jev_write_atomic "$response_path" "$response_to_store" || true
  fi

  log_path="${dir}/decisions.jsonl"
  _jev_append_jsonl "$log_path" "$redacted_line" || return 0
  return 0
}
