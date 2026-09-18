#!/usr/bin/env bats
# Public ralph doctor: host/runtime table, soft optional-tool rows, hard jq gate.
# Auth probes stay hermetic via GRAPH_PREFLIGHT_CLI_* stubs (no live services).

source "$BATS_TEST_DIRNAME/../helper/load-lib.bash"

DOCTOR_CLI="$REPO_ROOT/bundle/.ralph/bash-lib/preflight/doctor-cli.sh"

setup() {
  TMPD="$(mktemp -d)"
  BIN_DIR="$TMPD/bin"
  mkdir -p "$BIN_DIR"
  unset GRAPH_PREFLIGHT_UNAVAILABLE
  unset GRAPH_PREFLIGHT_CLI_CLAUDE GRAPH_PREFLIGHT_CLI_CURSOR
  unset GRAPH_PREFLIGHT_CLI_CODEX GRAPH_PREFLIGHT_CLI_OPENCODE
  unset GRAPH_PREFLIGHT_CLI_ANTIGRAVITY
  unset CLAUDE_PLAN_CLI CURSOR_PLAN_CLI CODEX_PLAN_CLI OPENCODE_PLAN_CLI ANTIGRAVITY_PLAN_CLI
  PATH="$BIN_DIR:$PATH"
}

teardown() {
  rm -rf "$TMPD"
}

# write_cli_stub <path> <runtime> [mode]
# Same seam as graph-preflight.bats: list/status/help only; never starts a session.
write_cli_stub() {
  local path="$1" runtime="$2" mode="${3:-ok}"
  cat >"$path" <<EOF
#!/usr/bin/env bash
case "\$1" in
  --help|help|-h)
    printf '%s\n' "Usage: $runtime"
    exit 0
    ;;
  auth)
    if [[ "\${2:-}" == "status" ]]; then
      if [[ "$mode" == "no-auth" ]]; then
        printf '%s\n' "not logged in"
        exit 1
      fi
      printf '%s\n' "Logged in"
      exit 0
    fi
    ;;
  login)
    if [[ "\${2:-}" == "status" ]]; then
      if [[ "$mode" == "no-auth" ]]; then
        printf '%s\n' "not logged in"
        exit 1
      fi
      printf '%s\n' "Logged in"
      exit 0
    fi
    ;;
  models|--list-models)
    printf '%s\n' "stub-model"
    exit 0
    ;;
esac
printf '%s\n' "model session must not start during doctor" >&2
exit 3
EOF
  chmod +x "$path"
}

install_runtime_stubs() {
  local auth_mode="${1:-ok}"
  write_cli_stub "$BIN_DIR/claude" claude "$auth_mode"
  write_cli_stub "$BIN_DIR/cursor-agent" cursor ok
  write_cli_stub "$BIN_DIR/codex" codex "$auth_mode"
  write_cli_stub "$BIN_DIR/opencode" opencode ok
  write_cli_stub "$BIN_DIR/agy" antigravity ok
  export GRAPH_PREFLIGHT_CLI_CLAUDE="$BIN_DIR/claude"
  export GRAPH_PREFLIGHT_CLI_CURSOR="$BIN_DIR/cursor-agent"
  export GRAPH_PREFLIGHT_CLI_CODEX="$BIN_DIR/codex"
  export GRAPH_PREFLIGHT_CLI_OPENCODE="$BIN_DIR/opencode"
  export GRAPH_PREFLIGHT_CLI_ANTIGRAVITY="$BIN_DIR/agy"
}

run_doctor() {
  env PATH="$PATH" \
    GRAPH_PREFLIGHT_UNAVAILABLE="${GRAPH_PREFLIGHT_UNAVAILABLE-}" \
    GRAPH_PREFLIGHT_CLI_CLAUDE="${GRAPH_PREFLIGHT_CLI_CLAUDE-}" \
    GRAPH_PREFLIGHT_CLI_CURSOR="${GRAPH_PREFLIGHT_CLI_CURSOR-}" \
    GRAPH_PREFLIGHT_CLI_CODEX="${GRAPH_PREFLIGHT_CLI_CODEX-}" \
    GRAPH_PREFLIGHT_CLI_OPENCODE="${GRAPH_PREFLIGHT_CLI_OPENCODE-}" \
    GRAPH_PREFLIGHT_CLI_ANTIGRAVITY="${GRAPH_PREFLIGHT_CLI_ANTIGRAVITY-}" \
    bash "$DOCTOR_CLI" "$@"
}

assert_row() {
  local id="$1" status="$2"
  printf '%s\n' "$output" | grep -E "^${id}[[:space:]]+${status}[[:space:]]" >/dev/null
}

assert_id_present() {
  local id="$1"
  printf '%s\n' "$output" | grep -E "^${id}[[:space:]]" >/dev/null
}

# Minimal --version stubs so optional host rows are deterministic pass when absent
# on the real PATH (macOS often lacks timeout/flock/setsid).
install_optional_tool_stubs() {
  local cmd
  for cmd in python3 rg ctags timeout flock setsid sha256sum; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
      cat >"$BIN_DIR/$cmd" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "stub-version 0"
exit 0
EOF
      chmod +x "$BIN_DIR/$cmd"
    fi
  done
}

@test "doctor renders normal host and runtime table via format_table with stubbed auth" {
  install_optional_tool_stubs
  install_runtime_stubs ok

  run run_doctor
  [ "$status" -eq 0 ]
  [[ "$output" == *"Ralph doctor (read-only)"* ]]
  [[ "$output" == *"ID"* && "$output" == *"STATUS"* && "$output" == *"EVIDENCE"* && "$output" == *"REPAIR"* ]]

  assert_row "host:bash" pass
  assert_row "host:jq" pass
  assert_row "host:python3" pass
  assert_row "host:rg" pass
  assert_row "host:ctags" pass
  assert_row "host:timeout" pass
  assert_row "host:flock" pass
  assert_row "host:setsid" pass
  assert_row "host:sha256" pass

  assert_row "runtime:claude" pass
  assert_row "runtime:codex" pass
  assert_row "runtime:cursor" pass
  assert_row "runtime:opencode" pass
  assert_row "runtime:antigravity" pass

  assert_id_present "runtime:cursor:auth"
  assert_id_present "runtime:opencode:auth"
  assert_id_present "runtime:antigravity:auth"
  [[ "$output" != *"model session must not start"* ]]
}

@test "doctor optional-tool degradation warns without failing the command" {
  install_runtime_stubs ok
  export GRAPH_PREFLIGHT_UNAVAILABLE=python3,rg,ctags,timeout,flock,setsid,sha256sum,shasum

  run run_doctor
  [ "$status" -eq 0 ]
  [[ "$output" == *"Ralph doctor (read-only)"* ]]

  assert_row "host:bash" pass
  assert_row "host:jq" pass
  assert_row "host:python3" warn
  assert_row "host:rg" warn
  assert_row "host:ctags" warn
  assert_row "host:timeout" warn
  assert_row "host:flock" warn
  assert_row "host:setsid" warn
  assert_row "host:sha256" warn

  [[ "$output" == *"python3 missing"* ]]
  [[ "$output" == *"rg missing"* ]]
  [[ "$output" == *"ctags missing"* ]]
  [[ "$output" == *"sha256sum/shasum missing"* || "$output" == *"neither sha256sum nor shasum"* ]]
}

@test "doctor missing-jq is a hard command failure" {
  install_runtime_stubs ok
  local bash_bin bash_dir reduced_path
  bash_bin="$(command -v bash)"
  bash_dir="$(dirname "$bash_bin")"
  # Keep bash resolvable; exclude every PATH entry that provides jq.
  reduced_path="$BIN_DIR:$bash_dir"
  case ":$bash_dir:" in
    *:/bin:*|*:/usr/bin:*) ;;
    *)
      reduced_path="$reduced_path:/bin:/usr/bin"
      ;;
  esac
  # If jq still resolves (e.g. /usr/bin/jq), force the shared preflight miss seam.
  if env PATH="$reduced_path" bash -c 'command -v jq >/dev/null 2>&1'; then
    export GRAPH_PREFLIGHT_UNAVAILABLE=jq
  fi
  run env PATH="$reduced_path" \
    GRAPH_PREFLIGHT_UNAVAILABLE="${GRAPH_PREFLIGHT_UNAVAILABLE-}" \
    bash "$DOCTOR_CLI"
  [ "$status" -eq 1 ]
  [[ "$output" == *"ralph doctor requires jq"* ]]
  [[ "$output" != *"Ralph doctor (read-only)"* ]]
}

@test "doctor auth fail uses stubbed preflight seam without contacting real services" {
  install_runtime_stubs no-auth

  run run_doctor
  [ "$status" -eq 0 ]
  assert_row "runtime:claude" fail
  assert_row "runtime:codex" fail
  # Repair column (table shows evidence first; summary is not always printed).
  [[ "$output" == *"log in to claude"* ]]
  [[ "$output" == *"log in to codex"* ]]
  [[ "$output" != *"model session must not start"* ]]
}
