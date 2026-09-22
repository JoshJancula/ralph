#!/usr/bin/env bats
# Tests for bundle/.ralph/bash-lib/jev/jev-key-store.sh (Section G chain).
#
# Isolation rules honored by every test:
#   - RALPH_CONFIG_HOME points at a per-test mktemp dir, so no test ever
#     touches the developer's real Ralph config or models.json.
#   - The real OS keychain is never invoked: stub `security` and
#     `secret-tool` binaries are placed first on PATH.
#   - No test makes a live API call.
#
# Cost notes: every jev_key_source / jev_key_resolve call forks jq several
# times, so tests assert the winning source via the RALPH_JEV_KEY_SOURCE
# export that jev_key_resolve sets in-process (stdout redirection does not
# fork a subshell for function calls) instead of paying for a second
# jev_key_source invocation.

source "$BATS_TEST_DIRNAME/../helper/load-lib.bash"

KEY_STORE_LIB="$REPO_ROOT/bundle/.ralph/bash-lib/jev/jev-key-store.sh"
REDACT_LIB="$REPO_ROOT/bundle/.ralph/bash-lib/jev/jev-redact.sh"
CLIENT_LIB="$REPO_ROOT/bundle/.ralph/bash-lib/jev/jev-client.sh"

JEVS_TEST_KEY="typesafe-key-store-test-987xyz"

# ---------------------------------------------------------------------------
# Stub keychain: flat-file backing store behind security/secret-tool CLIs.
# ---------------------------------------------------------------------------

jevs_stub_keychain_dir() {
  printf '%s/keychain-stub-bin' "${JEVS_HOME:?}"
}

jevs_keychain_store_path() {
  printf '%s/keychain-stub-store' "${JEVS_HOME:?}"
}

jevs_write_keychain_stubs() {
  local bindir store
  bindir="$(jevs_stub_keychain_dir)"
  store="$(jevs_keychain_store_path)"
  mkdir -p "$bindir"
  : >"$store"

  cat >"$bindir/security" <<'EOF'
#!/usr/bin/env bash
# Minimal macOS `security` stub for Jev tests. Backing store path comes from
# the environment so the stub stays independent of argv and cwd. Pure-bash
# store access keeps fork count low so tests stay under one second.
set -euo pipefail
store="${JEVS_KEYCHAIN_STORE:?}"
service="" account="" value="" op=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    find-generic-password|delete-generic-password|add-generic-password) op="$1"; shift ;;
    -s) service="$2"; shift 2 ;;
    -a) account="$2"; shift 2 ;;
    -w)
      if [[ "$op" == "add-generic-password" ]]; then
        value="$2"; shift 2
      else
        # find-generic-password -w is a bare flag (print password only).
        shift
      fi
      ;;
    *) shift ;;
  esac
done
prefix="${service}|${account}|"
case "$op" in
  find-generic-password)
    while IFS= read -r line; do
      if [[ "$line" == "$prefix"* ]]; then
        printf '%s\n' "${line#"$prefix"}"
        exit 0
      fi
    done <"$store"
    exit 44
    ;;
  delete-generic-password)
    tmp="${store}.tmp"
    : >"$tmp"
    while IFS= read -r line; do
      [[ "$line" == "$prefix"* ]] || printf '%s\n' "$line" >>"$tmp"
    done <"$store"
    mv "$tmp" "$store"
    exit 0
    ;;
  add-generic-password)
    tmp="${store}.tmp"
    : >"$tmp"
    while IFS= read -r line; do
      [[ "$line" == "$prefix"* ]] || printf '%s\n' "$line" >>"$tmp"
    done <"$store"
    printf '%s%s\n' "$prefix" "$value" >>"$tmp"
    mv "$tmp" "$store"
    exit 0
    ;;
  *)
    exit 1
    ;;
esac
EOF
  chmod +x "$bindir/security"

  cat >"$bindir/secret-tool" <<'EOF'
#!/usr/bin/env bash
# Minimal Linux `secret-tool` stub for Jev tests.
set -euo pipefail
store="${JEVS_KEYCHAIN_STORE:?}"
op="${1:-}"; shift || true
service="" account=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --label=*) shift ;;
    service) service="$2"; shift 2 ;;
    account) account="$2"; shift 2 ;;
    *) shift ;;
  esac
done
prefix="${service}|${account}|"
case "$op" in
  lookup)
    while IFS= read -r line; do
      if [[ "$line" == "$prefix"* ]]; then
        printf '%s\n' "${line#"$prefix"}"
        exit 0
      fi
    done <"$store"
    exit 0
    ;;
  store)
    value="$(cat)"
    tmp="${store}.tmp"
    : >"$tmp"
    while IFS= read -r line; do
      [[ "$line" == "$prefix"* ]] || printf '%s\n' "$line" >>"$tmp"
    done <"$store"
    printf '%s%s\n' "$prefix" "$value" >>"$tmp"
    mv "$tmp" "$store"
    exit 0
    ;;
  clear)
    tmp="${store}.tmp"
    : >"$tmp"
    while IFS= read -r line; do
      [[ "$line" == "$prefix"* ]] || printf '%s\n' "$line" >>"$tmp"
    done <"$store"
    mv "$tmp" "$store"
    exit 0
    ;;
  *)
    exit 1
    ;;
esac
EOF
  chmod +x "$bindir/secret-tool"

  export JEVS_KEYCHAIN_STORE="$store"
  export PATH="$bindir:$PATH"
}

# Resolve the key in the child shell, capturing value and source in one call.
jevs_resolve_snippet() {
  printf '%s' '
    jev_key_resolve >"$1/resolved.txt" || jev_key_resolve_rc=$?
    [ "${jev_key_resolve_rc:-0}" -eq "$2" ] || exit 10
  '
}

setup() {
  command -v jq >/dev/null || skip "jq required"
  [ -f "$KEY_STORE_LIB" ] || skip "jev-key-store.sh missing"

  JEVS_HOME="$(mktemp -d "${TMPDIR:-/tmp}/ralph-jev-key-store.XXXXXX")"
  export JEVS_HOME
  export RALPH_CONFIG_HOME="$JEVS_HOME/config"
  export HOME="$JEVS_HOME/home"
  mkdir -p "$RALPH_CONFIG_HOME" "$HOME"

  unset TYPESAFE_API_KEY RALPH_JEV RALPH_JEV_KEY_SOURCE RALPH_JEV_ENV_FILE

  # Deterministic workspace root for .env-backend tests, independent of cwd.
  JEVS_WORKSPACE="$JEVS_HOME/project"
  export RALPH_PROJECT_ROOT="$JEVS_WORKSPACE"
  mkdir -p "$JEVS_WORKSPACE"

  jevs_write_keychain_stubs
}

teardown() {
  [ -n "${JEVS_HOME:-}" ] && rm -rf "$JEVS_HOME"
}

# ---------------------------------------------------------------------------
# 1. Each backend resolves in isolation and reports the right source token.
# ---------------------------------------------------------------------------

@test "env backend resolves in isolation and jev_key_source prints env" {
  run bash -c '
    source "$1"
    export TYPESAFE_API_KEY="$2"
    jev_key_resolve >"$3/resolved.txt" || exit 1
    [ "$(cat "$3/resolved.txt")" = "$2" ] || exit 1
    [ "$RALPH_JEV_KEY_SOURCE" = "env" ]
  ' _ "$KEY_STORE_LIB" "$JEVS_TEST_KEY" "$JEVS_HOME"
  [ "$status" -eq 0 ]
}

@test "env-file backend resolves in isolation and jev_key_source prints env-file" {
  printf 'TYPESAFE_API_KEY=%s\n' "$JEVS_TEST_KEY" >"$JEVS_WORKSPACE/.env"
  run bash -c '
    source "$1"
    jev_key_resolve >"$3/resolved.txt" || exit 1
    [ "$(cat "$3/resolved.txt")" = "$2" ] || exit 1
    [ "$RALPH_JEV_KEY_SOURCE" = "env-file" ]
  ' _ "$KEY_STORE_LIB" "$JEVS_TEST_KEY" "$JEVS_HOME"
  [ "$status" -eq 0 ]
}

@test "command backend resolves in isolation and jev_key_source prints command" {
  run bash -c '
    source "$1"
    jev_key_set_command "printf %s \"$2\"" >/dev/null 2>&1 || exit 1
    jev_key_resolve >"$3/resolved.txt" || exit 1
    [ "$(cat "$3/resolved.txt")" = "$2" ] || exit 1
    [ "$RALPH_JEV_KEY_SOURCE" = "command" ]
  ' _ "$KEY_STORE_LIB" "$JEVS_TEST_KEY" "$JEVS_HOME"
  [ "$status" -eq 0 ]
}

@test "keychain backend resolves in isolation and jev_key_source prints keychain" {
  # Set path (stdin into the keychain) is exercised by the set_keychain
  # acceptance tests; here populate the stub store directly and assert
  # resolve + source, which is this test's contract.
  run bash -c '
    source "$1"
    printf "ralph.jev|TYPESAFE_API_KEY|%s\n" "$2" >>"$3"
    jev_key_store_write_json "{\"keychain\":true}" || exit 1
    jev_key_resolve >"$4/resolved.txt" || exit 1
    [ "$(cat "$4/resolved.txt")" = "$2" ] || exit 1
    [ "$RALPH_JEV_KEY_SOURCE" = "keychain" ]
  ' _ "$KEY_STORE_LIB" "$JEVS_TEST_KEY" "$(jevs_keychain_store_path)" "$JEVS_HOME"
  [ "$status" -eq 0 ]
}

@test "set_keychain reads the key from stdin and stores it" {
  run bash -c '
    source "$1"
    printf "%s\n" "$2" | jev_key_set_keychain >/dev/null 2>&1 || exit 1
    [ -s "$3" ] || exit 1
    grep -qF -- "$2" "$3"
  ' _ "$KEY_STORE_LIB" "$JEVS_TEST_KEY" "$(jevs_keychain_store_path)"
  [ "$status" -eq 0 ]
}

@test "file backend resolves in isolation and jev_key_source prints file" {
  run bash -c '
    source "$1"
    printf "%s\n" "$2" | jev_key_set_file >/dev/null 2>&1 || exit 1
    jev_key_resolve >"$3/resolved.txt" || exit 1
    [ "$(cat "$3/resolved.txt")" = "$2" ] || exit 1
    [ "$RALPH_JEV_KEY_SOURCE" = "file" ]
  ' _ "$KEY_STORE_LIB" "$JEVS_TEST_KEY" "$JEVS_HOME"
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# 2. Precedence: env beats env-file beats command beats keychain beats file.
#    The required env-over-file and env-file-over-file pairs are asserted
#    directly; the remaining transitions are each asserted directly too, so
#    the full order is covered without one expensive test.
# ---------------------------------------------------------------------------

@test "precedence: env beats file" {
  run bash -c '
    source "$1"
    printf "%s\n" file-key-value | jev_key_set_file >/dev/null 2>&1 || exit 1
    export TYPESAFE_API_KEY="$2"
    jev_key_resolve >"$3/resolved.txt" || exit 1
    [ "$(cat "$3/resolved.txt")" = "$2" ] || exit 1
    [ "$RALPH_JEV_KEY_SOURCE" = "env" ]
  ' _ "$KEY_STORE_LIB" "$JEVS_TEST_KEY" "$JEVS_HOME"
  [ "$status" -eq 0 ]
}

@test "precedence: env-file beats file" {
  printf 'TYPESAFE_API_KEY=%s\n' "$JEVS_TEST_KEY" >"$JEVS_WORKSPACE/.env"
  run bash -c '
    source "$1"
    printf "%s\n" file-key-value | jev_key_set_file >/dev/null 2>&1 || exit 1
    jev_key_resolve >"$3/resolved.txt" || exit 1
    [ "$(cat "$3/resolved.txt")" = "$2" ] || exit 1
    [ "$RALPH_JEV_KEY_SOURCE" = "env-file" ]
  ' _ "$KEY_STORE_LIB" "$JEVS_TEST_KEY" "$JEVS_HOME"
  [ "$status" -eq 0 ]
}

@test "precedence: env beats env-file" {
  printf 'TYPESAFE_API_KEY=env-file-key\n' >"$JEVS_WORKSPACE/.env"
  run bash -c '
    source "$1"
    export TYPESAFE_API_KEY="env-key-value"
    jev_key_resolve >"$3/resolved.txt" || exit 1
    [ "$(cat "$3/resolved.txt")" = "env-key-value" ] || exit 1
    [ "$RALPH_JEV_KEY_SOURCE" = "env" ]
  ' _ "$KEY_STORE_LIB" "" "$JEVS_HOME"
  [ "$status" -eq 0 ]
}

@test "precedence: env-file beats command" {
  printf 'TYPESAFE_API_KEY=%s\n' "$JEVS_TEST_KEY" >"$JEVS_WORKSPACE/.env"
  run bash -c '
    source "$1"
    jev_key_set_command "printf %s cmd-key-value" >/dev/null 2>&1 || exit 1
    jev_key_resolve >"$3/resolved.txt" || exit 1
    [ "$(cat "$3/resolved.txt")" = "$2" ] || exit 1
    [ "$RALPH_JEV_KEY_SOURCE" = "env-file" ]
  ' _ "$KEY_STORE_LIB" "$JEVS_TEST_KEY" "$JEVS_HOME"
  [ "$status" -eq 0 ]
}

@test "precedence: command beats keychain" {
  run bash -c '
    source "$1"
    # Populate the keychain stub store directly; the set path is covered by
    # the isolation tests. One config write enables both backends.
    printf "ralph.jev|TYPESAFE_API_KEY|%s\n" "kc-key-value" >>"$2"
    jev_key_store_write_json "{\"command\":\"printf %s cmd-key-value\",\"keychain\":true}" || exit 1
    jev_key_resolve >"$3/resolved.txt" || exit 1
    [ "$(cat "$3/resolved.txt")" = "cmd-key-value" ] || exit 1
    [ "$RALPH_JEV_KEY_SOURCE" = "command" ]
  ' _ "$KEY_STORE_LIB" "$(jevs_keychain_store_path)" "$JEVS_HOME"
  [ "$status" -eq 0 ]
}

@test "precedence: keychain beats file" {
  run bash -c '
    source "$1"
    printf "ralph.jev|TYPESAFE_API_KEY|%s\n" "kc-key-value" >>"$2"
    printf "%s\n" "file-key-value" >"$4/jev-api-key"
    jev_key_store_write_json "{\"keychain\":true,\"file\":true}" || exit 1
    jev_key_resolve >"$3/resolved.txt" || exit 1
    [ "$(cat "$3/resolved.txt")" = "kc-key-value" ] || exit 1
    [ "$RALPH_JEV_KEY_SOURCE" = "keychain" ]
  ' _ "$KEY_STORE_LIB" "$(jevs_keychain_store_path)" "$JEVS_HOME" "$RALPH_CONFIG_HOME"
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# 3. RALPH_JEV_ENV_FILE=0 skips the .env backend.
# ---------------------------------------------------------------------------

@test "RALPH_JEV_ENV_FILE=0 skips the env-file backend" {
  printf 'TYPESAFE_API_KEY=%s\n' "$JEVS_TEST_KEY" >"$JEVS_WORKSPACE/.env"
  run bash -c '
    source "$1"
    export RALPH_JEV_ENV_FILE=0
    jev_key_resolve >"$2/resolved.txt" && exit 1
    [ "$RALPH_JEV_KEY_SOURCE" = "none" ]
  ' _ "$KEY_STORE_LIB" "$JEVS_HOME"
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# 4. THE ISOLATION TEST: parsing .env imports ONLY TYPESAFE_API_KEY.
# ---------------------------------------------------------------------------

@test "isolation: .env with a second secret yields only the Jev key" {
  printf 'TYPESAFE_API_KEY=%s\nOTHER_DB_PASSWORD=super-secret-db-value\n' "$JEVS_TEST_KEY" \
    >"$JEVS_WORKSPACE/.env"
  run bash -c '
    source "$1"
    jev_key_resolve >"$3/resolved.txt" || exit 1
    [ "$(cat "$3/resolved.txt")" = "$2" ] || exit 1
    # Parsing (not sourcing) must not import anything into the environment.
    [ -z "${OTHER_DB_PASSWORD:-}" ] || exit 1
    printenv OTHER_DB_PASSWORD >/dev/null 2>&1 && exit 1
    printenv TYPESAFE_API_KEY >/dev/null 2>&1 && exit 1
    exit 0
  ' _ "$KEY_STORE_LIB" "$JEVS_TEST_KEY" "$JEVS_HOME"
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# 5. THE NO-EXECUTION TEST: .env content is never evaluated.
# ---------------------------------------------------------------------------

@test "no-execution: .env command substitution does not run" {
  local sentinel="$JEVS_HOME/noexec-sentinel"
  printf 'TYPESAFE_API_KEY="$(touch %q)"\n' "$sentinel" >"$JEVS_WORKSPACE/.env"
  run bash -c '
    source "$1"
    jev_key_resolve >/dev/null 2>&1 || true
    exit 0
  ' _ "$KEY_STORE_LIB"
  [ "$status" -eq 0 ]
  [ ! -e "$sentinel" ]
}

# ---------------------------------------------------------------------------
# 6. Only <workspace>/.env is read: .env.local and a parent-directory .env
#    are both ignored.
# ---------------------------------------------------------------------------

@test "path discipline: .env.local and parent-directory .env are ignored" {
  local parent="$JEVS_HOME/parent"
  local sub="$parent/sub"
  mkdir -p "$sub"
  printf 'TYPESAFE_API_KEY=parent-dir-key\n' >"$parent/.env"
  printf 'TYPESAFE_API_KEY=env-local-key\n' >"$sub/.env.local"
  # Workspace root is the subdirectory: neither candidate file is <root>/.env,
  # so nothing resolves.
  run env RALPH_PROJECT_ROOT="$sub" bash -c '
    source "$1"
    jev_key_resolve >/dev/null 2>&1 && exit 1
    [ "$RALPH_JEV_KEY_SOURCE" = "none" ]
  ' _ "$KEY_STORE_LIB"
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# 7. The stored plaintext file is mode 600.
# ---------------------------------------------------------------------------

@test "stored file backend is mode 600" {
  bash -c '
    source "$1"
    printf "%s\n" "$2" | jev_key_set_file >/dev/null 2>&1
  ' _ "$KEY_STORE_LIB" "$JEVS_TEST_KEY"
  local key_path mode
  key_path="$RALPH_CONFIG_HOME/jev-api-key"
  [ -f "$key_path" ]
  # GNU coreutils first: BSD stat -f prints a filesystem block before
  # failing, so the substitution concatenates that with the fallback answer.
  mode="$(stat -c '%a' "$key_path" 2>/dev/null || stat -f '%OLp' "$key_path")"
  [ "$mode" = "600" ]
}

# ---------------------------------------------------------------------------
# 8. jev_key_status never prints the key for any backend.
#    The command backend intentionally prints the stored command string, so
#    the stored command must not contain the key (that is the whole point of
#    the command backend: it stores a command, not a secret).
# ---------------------------------------------------------------------------

@test "jev_key_status never prints the key: env, env-file, command" {
  local out_dir="$JEVS_HOME/status-out"
  mkdir -p "$out_dir"
  printf 'TYPESAFE_API_KEY=%s\n' "$JEVS_TEST_KEY" >"$JEVS_WORKSPACE/.env"
  run bash -c '
    source "$1"
    export TYPESAFE_API_KEY="$2"
    jev_key_status >"$3/env-status.txt" || exit 1
    unset TYPESAFE_API_KEY
    jev_key_status >"$3/envfile-status.txt" || exit 1
    rm -f "$4/.env"
    jev_key_set_command "printf %s cmd-key-material" >/dev/null 2>&1 || exit 1
    jev_key_status >"$3/cmd-status.txt" || exit 1
    exit 0
  ' _ "$KEY_STORE_LIB" "$JEVS_TEST_KEY" "$out_dir" "$JEVS_WORKSPACE"
  [ "$status" -eq 0 ]
  local f
  for f in "$out_dir"/*-status.txt; do
    [ -f "$f" ] || continue
    if grep -qF -- "$JEVS_TEST_KEY" "$f"; then
      echo "jev_key_status leaked the key in: $f" >&2
      return 1
    fi
  done
}

@test "jev_key_status never prints the key: keychain backend" {
  local out_dir="$JEVS_HOME/status-out"
  mkdir -p "$out_dir"
  run bash -c '
    source "$1"
    printf "ralph.jev|TYPESAFE_API_KEY|%s\n" "$2" >>"$3"
    _jev_key_store_write_secure "$5/jev-credentials.json" "{\"schema_version\":1,\"command\":\"\",\"keychain\":true,\"file\":false}" || exit 1
    jev_key_status >"$4/keychain-status.txt" || exit 1
    exit 0
  ' _ "$KEY_STORE_LIB" "$JEVS_TEST_KEY" "$(jevs_keychain_store_path)" "$out_dir" \
    "$RALPH_CONFIG_HOME"
  [ "$status" -eq 0 ]
  if grep -qF -- "$JEVS_TEST_KEY" "$out_dir/keychain-status.txt"; then
    echo "jev_key_status leaked the key in: $out_dir/keychain-status.txt" >&2
    return 1
  fi
}

@test "jev_key_status never prints the key: file backend" {
  local out_dir="$JEVS_HOME/status-out"
  mkdir -p "$out_dir"
  run bash -c '
    source "$1"
    printf "%s\n" "$2" >"$4/jev-api-key"
    _jev_key_store_write_secure "$4/jev-credentials.json" "{\"schema_version\":1,\"command\":\"\",\"keychain\":false,\"file\":true}" || exit 1
    jev_key_status >"$3/file-status.txt" || exit 1
    exit 0
  ' _ "$KEY_STORE_LIB" "$JEVS_TEST_KEY" "$out_dir" "$RALPH_CONFIG_HOME"
  [ "$status" -eq 0 ]
  if grep -qF -- "$JEVS_TEST_KEY" "$out_dir/file-status.txt"; then
    echo "jev_key_status leaked the key in: $out_dir/file-status.txt" >&2
    return 1
  fi
}

# ---------------------------------------------------------------------------
# 9. jev_key_clear removes every backend and status returns to none.
# ---------------------------------------------------------------------------

@test "jev_key_clear removes every backend" {
  run bash -c '
    source "$1"
    # Populate every backend (set paths covered by isolation tests).
    printf "ralph.jev|TYPESAFE_API_KEY|%s\n" "$2" >>"$3"
    printf "%s\n" "$2" >"$5/jev-api-key"
    jev_key_store_write_json "{\"command\":\"printf %s cmd-key\",\"keychain\":true,\"file\":true}" || exit 1
    jev_key_clear || exit 1
    [ "$RALPH_JEV_KEY_SOURCE" = "none" ] || exit 1
    # The stub store is emptied by delete; the plaintext key file is gone.
    [ -s "$3" ] && exit 1
    [ ! -f "$5/jev-api-key" ] || exit 1
    exit 0
  ' _ "$KEY_STORE_LIB" "$JEVS_TEST_KEY" "$(jevs_keychain_store_path)" "$JEVS_HOME" \
    "$RALPH_CONFIG_HOME"
  [ "$status" -eq 0 ]
}

@test "jev_key_status reports source none after clear" {
  run bash -c '
    source "$1"
    printf "%s\n" "$2" >"$4/jev-api-key"
    _jev_key_store_write_secure "$4/jev-credentials.json" "{\"schema_version\":1,\"command\":\"\",\"keychain\":false,\"file\":true}" || exit 1
    jev_key_clear >/dev/null 2>&1 || exit 1
    jev_key_status >"$3/status.txt" || exit 1
    printf "%s\n" "$(cat "$3/status.txt")" | grep -q "^source: none$" || exit 1
    exit 0
  ' _ "$KEY_STORE_LIB" "$JEVS_TEST_KEY" "$JEVS_HOME" "$RALPH_CONFIG_HOME"
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# 10. No key resolvable: jev_available returns 1 and jev_unavailable_reason
#     prints no-key. Forward-compatible: the availability gate lands in a
#     later TODO, so skip while the client library has not implemented it.
# ---------------------------------------------------------------------------

@test "no key resolvable: jev_available returns 1 and reason is no-key" {
  if ! bash -c '
    source "$1" 2>/dev/null || exit 1
    type jev_available >/dev/null 2>&1
  ' _ "$CLIENT_LIB"; then
    skip "availability gate not implemented yet (later TODO)"
  fi
  RALPH_JEV=1 run bash -c '
    source "$1"
    source "$2"
    jev_available && exit 1
    [ "$(jev_unavailable_reason)" = "no-key" ]
  ' _ "$KEY_STORE_LIB" "$CLIENT_LIB"
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# Redaction contract: a resolved key fed through jev_redact_state does not
# survive into the payload.
# ---------------------------------------------------------------------------

@test "redaction: resolved key does not survive jev_redact_state" {
  [ -f "$REDACT_LIB" ] || skip "jev-redact.sh missing"
  printf 'TYPESAFE_API_KEY=%s\n' "$JEVS_TEST_KEY" >"$JEVS_WORKSPACE/.env"
  run bash -c '
    source "$1"
    source "$2"
    jev_key_resolve >"$4/resolved.txt" || exit 1
    key="$(cat "$4/resolved.txt")"
    [ "$key" = "$3" ] || exit 1
    # The live caller holds the resolved key in TYPESAFE_API_KEY while
    # building the request; redaction must remove it from state.
    export TYPESAFE_API_KEY="$key"
    printf "state contains %s inside\n" "$key" | jev_redact_state >"$4/redacted.txt" || exit 1
    grep -qF -- "$key" "$4/redacted.txt" && exit 1
    grep -q "\[REDACTED\]" "$4/redacted.txt" || exit 1
    exit 0
  ' _ "$KEY_STORE_LIB" "$REDACT_LIB" "$JEVS_TEST_KEY" "$JEVS_HOME"
  [ "$status" -eq 0 ]
}

@test "redaction: file-backend resolved key is redacted when held by the caller" {
  [ -f "$REDACT_LIB" ] || skip "jev-redact.sh missing"
  run bash -c '
    source "$1"
    source "$2"
    printf "%s\n" "$3" >"$5/jev-api-key"
    jev_key_store_write_json "{\"file\":true}" || exit 1
    jev_key_resolve >"$4/resolved.txt" || exit 1
    key="$(cat "$4/resolved.txt")"
    [ "$key" = "$3" ] || exit 1
    export TYPESAFE_API_KEY="$key"
    printf "header %s tail\n" "$key" | jev_redact_state >"$4/redacted2.txt" || exit 1
    grep -qF -- "$key" "$4/redacted2.txt" && exit 1
    exit 0
  ' _ "$KEY_STORE_LIB" "$REDACT_LIB" "$JEVS_TEST_KEY" "$JEVS_HOME" "$RALPH_CONFIG_HOME"
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# Additional hard requirements from the same contract.
# ---------------------------------------------------------------------------

@test "set_command rejects an empty command string" {
  run bash -c '
    source "$1"
    jev_key_set_command "" >/dev/null 2>&1 && exit 1
    exit 0
  ' _ "$KEY_STORE_LIB"
  [ "$status" -eq 0 ]
}

@test "set_keychain and set_file reject a key passed as an argument" {
  run bash -c '
    source "$1"
    jev_key_set_keychain "$2" >/dev/null 2>&1 && exit 1
    jev_key_set_file "$2" >/dev/null 2>&1 && exit 1
    exit 0
  ' _ "$KEY_STORE_LIB" "$JEVS_TEST_KEY"
  [ "$status" -eq 0 ]
}

@test "set_keychain and set_file reject an empty stdin key" {
  run bash -c '
    source "$1"
    printf "" | jev_key_set_keychain >/dev/null 2>&1 && exit 1
    printf "" | jev_key_set_file >/dev/null 2>&1 && exit 1
    exit 0
  ' _ "$KEY_STORE_LIB"
  [ "$status" -eq 0 ]
}

@test "command backend failure does not fall through to a later backend" {
  run bash -c '
    source "$1"
    printf "%s\n" file-key-value >"$4/jev-api-key"
    jev_key_store_write_json "{\"command\":\"exit 7\",\"file\":true}" || exit 1
    jev_key_resolve >/dev/null 2>&1 && exit 1
    [ "$RALPH_JEV_KEY_SOURCE" = "command" ]
  ' _ "$KEY_STORE_LIB" "" "$(jevs_keychain_store_path)" "$RALPH_CONFIG_HOME"
  [ "$status" -eq 0 ]
}

@test "keychain backend failure does not fall through to the file backend" {
  run bash -c '
    source "$1"
    # Configure keychain and file, then make the keychain read fail by
    # emptying the stub store. The file backend must NOT be used.
    printf "ralph.jev|TYPESAFE_API_KEY|%s\n" "kc-key-value" >>"$2"
    printf "%s\n" file-key-value >"$4/jev-api-key"
    jev_key_store_write_json "{\"keychain\":true,\"file\":true}" || exit 1
    : >"$2"
    jev_key_resolve >/dev/null 2>&1 && exit 1
    [ "$RALPH_JEV_KEY_SOURCE" = "keychain" ]
  ' _ "$KEY_STORE_LIB" "$(jevs_keychain_store_path)" "$JEVS_HOME" "$RALPH_CONFIG_HOME"
  [ "$status" -eq 0 ]
}