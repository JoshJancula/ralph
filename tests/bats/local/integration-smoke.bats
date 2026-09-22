#!/usr/bin/env bats

# These specs invoke installed provider CLIs. They are excluded from the normal
# Bats suite and still require an explicit opt-in when run directly.
setup() {
  if [[ "${RALPH_RUN_REAL_RUNTIME_SMOKES:-0}" != "1" ]]; then
    skip "set RALPH_RUN_REAL_RUNTIME_SMOKES=1 to run real runtime smoke tests"
  fi
}

trim() {
  local value="$*"
  # Trim leading whitespace.
  value="${value#"${value%%[![:space:]]*}"}"
  # Trim trailing whitespace.
  value="${value%"${value##*[![:space:]]}"}"
  printf '%s' "$value"
}

parse_csv() {
  local csv="$1"
  local output_name="$2"
  eval "$output_name=()"
  [ -z "$csv" ] && return

  local escaped
  IFS=',' read -ra escaped <<< "$csv"
  for value in "${escaped[@]}"; do
    value="$(trim "$value")"
    if [ -n "$value" ]; then
      eval "$output_name+=(\"$value\")"
    fi
  done
}

contains() {
  local target="$1"
  shift
  local candidate
  for candidate in "$@"; do
    [[ "$candidate" == "$target" ]] && return 0
  done
  return 1
}

load_enabled_runtimes() {
  local include_runtimes=()
  local exclude_runtimes=()
  parse_csv "$RALPH_E2E_RUNTIMES" include_runtimes
  parse_csv "$RALPH_E2E_SKIP" exclude_runtimes

  if [ ${#include_runtimes[@]} -eq 0 ]; then
    include_runtimes=(cursor claude codex)
  fi

  enabled_runtimes=()
  local runtime
  for runtime in "${include_runtimes[@]}"; do
    if ! contains "$runtime" "${exclude_runtimes[@]}"; then
      enabled_runtimes+=("$runtime")
    fi
  done
}

require_runtime() {
  local runtime="$1"
  if ! contains "$runtime" "${enabled_runtimes[@]}"; then
    skip "Runtime '$runtime' is not enabled"
  fi
}

find_cursor_cli() {
  local candidate
  for candidate in cursor-agent agent; do
    if command -v "$candidate" >/dev/null 2>&1; then
      printf '%s' "$candidate"
      return 0
    fi
  done
  return 1
}

run_cursor_smoke() {
  local cursor_cli
  if ! cursor_cli="$(find_cursor_cli)"; then
    fail "Neither 'cursor-agent' nor 'agent' is on PATH"
  fi

  run "$cursor_cli" --version
  [ "$status" -eq 0 ]
}

run_claude_smoke() {
  run claude read-only smoke
  [ "$status" -eq 0 ]
}

run_codex_smoke() {
  run codex --help
  [ "$status" -eq 0 ]
}

load_enabled_runtimes  # include list via RALPH_E2E_RUNTIMES, then subtract RALPH_E2E_SKIP runtimes

@test "Cursor CLI is on PATH and runs cleanly" {
  require_runtime cursor
  run_cursor_smoke
}

@test "Claude CLI is on PATH and has a harmless entrypoint" {
  require_runtime claude
  run_claude_smoke
}

@test "Codex CLI is on PATH and has a harmless entrypoint" {
  require_runtime codex
  run_codex_smoke
}

@test "Codex MCP config workspaces can include Ralph servers" {
  require_runtime codex

  local workspace codex_bin codex_bin_dir config_dir
  workspace="$(pwd)"
  codex_bin="$(command -v codex)"
  [ -n "$codex_bin" ] || fail "codex binary not found"
  codex_bin_dir="$(dirname "$codex_bin")"
  config_dir="$BATS_TEST_TMPDIR/codex-ralph-mcp"
  mkdir -p "$config_dir"

  cat <<EOF >"$config_dir/config.toml"
[mcp_servers.ralph]
command = "bash"
args = ["$workspace/.ralph/mcp-server.sh"]

[mcp_servers.ralph.env]
PATH = "$codex_bin_dir:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
RALPH_MCP_WORKSPACE = "$workspace"
EOF

  run env "PATH=$codex_bin_dir:$PATH" "CODEX_HOME=$config_dir" codex mcp list

  [ "$status" -eq 0 ]
  [[ "$output" == *"ralph"* ]]
}
