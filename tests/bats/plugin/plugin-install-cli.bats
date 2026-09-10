#!/usr/bin/env bats
# Plugin lifecycle CLI entry-point tests.
# Invokes only plugin-cli.sh over prebuilt temp packages and stub adapters.
# Never runs installers, workflows, network, or real host CLIs.

source "$BATS_TEST_DIRNAME/../helper/load-lib.bash"

PLUGIN_CLI="$RALPH_LIB_ROOT/plugin/plugin-cli.sh"

setup_file() {
  export PI_SHARED="$(mktemp -d "${TMPDIR:-/tmp}/ralph-plugin-cli.XXXXXX")"
  export PI_STUBS="$PI_SHARED/stub-adapters"
  mkdir -p "$PI_STUBS"
  write_stub_adapters
}

teardown_file() {
  rm -rf "${PI_SHARED:-}"
}

setup() {
  unset RALPH_PLUGIN_COMMON_LOADED \
    RALPH_PLUGIN_ADAPTER_CLAUDE_LOADED \
    RALPH_PLUGIN_ADAPTER_CODEX_LOADED \
    RALPH_PLUGIN_ADAPTER_CURSOR_LOADED \
    RALPH_PLUGIN_ADAPTER_OPENCODE_LOADED \
    RALPH_PLUGIN_ADAPTER_ANTIGRAVITY_LOADED \
    RALPH_PLAN_WORKSPACE_ROOT \
    RALPH_PROJECT_ROOT
  TEST_HOME="$PI_SHARED/home-$BATS_TEST_NUMBER-$$"
  rm -rf "$TEST_HOME"
  mkdir -p "$TEST_HOME"
  export HOME="$TEST_HOME"
  export RALPH_HOME="$TEST_HOME/.ralph"
  mkdir -p "$RALPH_HOME/plugins/ralph-orchestrator"
  PROJECT_ROOT="$TEST_HOME/project"
  mkdir -p "$PROJECT_ROOT/.ralph-workspace"
  export RALPH_PROJECT_ROOT="$PROJECT_ROOT"
  # Isolate PATH from any real host plugin CLIs.
  STUB_BIN="$TEST_HOME/empty-bin"
  mkdir -p "$STUB_BIN"
  export PATH="$STUB_BIN:/usr/bin:/bin:/usr/sbin:/sbin"
  plant_minimal_packages
  export RALPH_PLUGIN_ADAPTER_DIR="$PI_STUBS"
  STUB_STATE="$RALPH_HOME/plugin-stub-state"
  mkdir -p "$STUB_STATE"
  export RALPH_PLUGIN_STUB_STATE="$STUB_STATE"
}

teardown() {
  rm -rf "${TEST_HOME:-}"
}

plant_minimal_packages() {
  local rt
  for rt in claude codex cursor opencode antigravity; do
    mkdir -p "$RALPH_HOME/plugins/ralph-orchestrator/$rt"
    cat >"$RALPH_HOME/plugins/ralph-orchestrator/$rt/.ralph-plugin-generated.json" <<EOF
{
  "schemaVersion": 1,
  "pluginVersion": "0.0.0-test",
  "sourceDescriptor": "tests/stub/$rt"
}
EOF
  done
}

write_stub_adapters() {
  cat >"$PI_STUBS/_stub-lib.sh" <<'EOF'
#!/usr/bin/env bash
stub_state_file() {
  printf '%s/%s.state\n' "${RALPH_PLUGIN_STUB_STATE:?}" "$1"
}
stub_get_state() {
  local f
  f="$(stub_state_file "$1")"
  if [[ -f "$f" ]]; then
    cat "$f"
  else
    printf 'absent\n'
  fi
}
stub_set_state() {
  mkdir -p "${RALPH_PLUGIN_STUB_STATE:?}"
  printf '%s\n' "$2" >"$(stub_state_file "$1")"
}
stub_journal() {
  printf '%s/plugin-installs/%s.json\n' "${RALPH_HOME:?}" "$1"
}
EOF

  write_user_stub_adapter() {
    local rt="$1"
    local loaded_var="$2"
    local fn_prefix="$3"
    cat >"$PI_STUBS/plugin-adapter-${rt}.sh" <<EOF
#!/usr/bin/env bash
set -euo pipefail
if [[ -n "\${${loaded_var}:-}" ]]; then
  return 0 2>/dev/null || exit 0
fi
${loaded_var}=1
# shellcheck source=/dev/null
source "\${RALPH_PLUGIN_ADAPTER_DIR}/_stub-lib.sh"

${fn_prefix}_package_root() {
  local override="\${1:-}"
  if [[ -n "\$override" ]]; then
    printf '%s\\n' "\$override"
    return 0
  fi
  plugin_common_package_root "$rt"
}

${fn_prefix}_preview() {
  printf 'preview: stub %s user-scope plugin install\\n' "$rt"
  plugin_common_preview_line stub-install "$rt"
}

${fn_prefix}_status() {
  stub_get_state "$rt"
}

${fn_prefix}_install() {
  local scope="\${2:-user}"
  local dry_run="\${3:-0}"
  scope="\$(plugin_common_require_scope "$rt" "\$scope")" || return \$?
  ${fn_prefix}_preview
  if [[ "\$dry_run" == "1" ]]; then
    printf 'dry-run: no host mutation\\n'
    return 0
  fi
  mkdir -p "\$RALPH_HOME/plugin-installs"
  printf '{"schemaVersion":1,"runtime":"%s","scope":"%s","packageVersion":"0.0.0-test","packageSource":"tests/stub/%s"}\\n' \\
    "$rt" "\$scope" "$rt" >"\$(stub_journal "$rt")"
  stub_set_state "$rt" current
  printf 'stub %s: installed\\n' "$rt"
}

${fn_prefix}_remove() {
  local scope="\${2:-user}"
  local dry_run="\${3:-0}"
  local state
  scope="\$(plugin_common_require_scope "$rt" "\$scope")" || return \$?
  printf 'preview: stub %s user-scope plugin remove\\n' "$rt"
  plugin_common_preview_line stub-remove "$rt"
  if [[ "\$dry_run" == "1" ]]; then
    printf 'dry-run: no host mutation\\n'
    return 0
  fi
  state="\$(stub_get_state "$rt")"
  case "\$state" in
    drifted)
      printf '%s plugin: refuse remove (drifted / journal mismatch)\\n' "$rt" >&2
      return 1
      ;;
    absent)
      rm -f "\$(stub_journal "$rt")"
      printf 'stub %s: already absent\\n' "$rt"
      return 0
      ;;
  esac
  rm -f "\$(stub_journal "$rt")"
  stub_set_state "$rt" absent
  printf 'stub %s: removed\\n' "$rt"
}
EOF
  }

  write_user_stub_adapter claude RALPH_PLUGIN_ADAPTER_CLAUDE_LOADED plugin_claude
  write_user_stub_adapter codex RALPH_PLUGIN_ADAPTER_CODEX_LOADED plugin_codex
  write_user_stub_adapter cursor RALPH_PLUGIN_ADAPTER_CURSOR_LOADED plugin_cursor
  write_user_stub_adapter antigravity RALPH_PLUGIN_ADAPTER_ANTIGRAVITY_LOADED plugin_antigravity

  cat >"$PI_STUBS/plugin-adapter-opencode.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ -n "${RALPH_PLUGIN_ADAPTER_OPENCODE_LOADED:-}" ]]; then
  return 0 2>/dev/null || exit 0
fi
RALPH_PLUGIN_ADAPTER_OPENCODE_LOADED=1
# shellcheck source=/dev/null
source "${RALPH_PLUGIN_ADAPTER_DIR}/_stub-lib.sh"
PLUGIN_OPENCODE_RUNTIME="opencode"

plugin_opencode_package_root() {
  local override="${1:-}"
  if [[ -n "$override" ]]; then
    printf '%s\n' "$override"
    return 0
  fi
  plugin_common_package_root opencode
}

plugin_opencode_preview() {
  local project_root="${2:-$PWD}"
  printf 'preview: stub OpenCode project-scope plugin install\n'
  plugin_common_preview_line stub-install opencode "$project_root"
}

plugin_opencode_status() {
  stub_get_state opencode
}

plugin_opencode_install() {
  local project_root="${2:-$PWD}"
  local scope="${3:-project}"
  local dry_run="${4:-0}"
  scope="$(plugin_common_require_scope opencode "$scope")" || return $?
  plugin_opencode_preview "" "$project_root" "$scope"
  if [[ "$dry_run" == "1" ]]; then
    printf 'dry-run: no host mutation\n'
    return 0
  fi
  local state_root="${project_root%/}/.ralph-workspace"
  mkdir -p "$state_root/plugin-installs"
  printf '{"schemaVersion":1,"runtime":"opencode","scope":"%s","packageVersion":"0.0.0-test","packageSource":"tests/stub/opencode"}\n' \
    "$scope" >"$state_root/plugin-installs/opencode.json"
  stub_set_state opencode current
  printf 'stub opencode: installed under %s\n' "$project_root"
}

plugin_opencode_remove() {
  local project_root="${2:-$PWD}"
  local scope="${3:-project}"
  local dry_run="${4:-0}"
  local state state_root
  scope="$(plugin_common_require_scope opencode "$scope")" || return $?
  state_root="${project_root%/}/.ralph-workspace"
  printf 'preview: stub OpenCode project-scope plugin remove\n'
  plugin_common_preview_line stub-remove opencode "$project_root"
  if [[ "$dry_run" == "1" ]]; then
    printf 'dry-run: no host mutation\n'
    return 0
  fi
  state="$(stub_get_state opencode)"
  case "$state" in
    drifted)
      printf 'opencode plugin: refuse remove (drifted / modified digests)\n' >&2
      return 1
      ;;
    absent)
      rm -f "$state_root/plugin-installs/opencode.json"
      printf 'stub opencode: already absent\n'
      return 0
      ;;
  esac
  rm -f "$state_root/plugin-installs/opencode.json"
  stub_set_state opencode absent
  printf 'stub opencode: removed\n'
}
EOF
}

# Readable from tests (mirrors stub state file).
stub_get_via_cli_state() {
  local f="$STUB_STATE/$1.state"
  if [[ -f "$f" ]]; then cat "$f"; else printf 'absent\n'; fi
}

run_plugin_cli() {
  (
    cd "$PROJECT_ROOT" || exit 1
    env \
      HOME="$HOME" \
      RALPH_HOME="$RALPH_HOME" \
      RALPH_PROJECT_ROOT="$PROJECT_ROOT" \
      RALPH_PLUGIN_ADAPTER_DIR="$PI_STUBS" \
      RALPH_PLUGIN_STUB_STATE="$STUB_STATE" \
      PATH="$PATH" \
      bash "$PLUGIN_CLI" "$@"
  )
}

# --- help / usage -----------------------------------------------------------

@test "plugin CLI help lists list status install remove and exit codes" {
  run run_plugin_cli --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"list"* ]]
  [[ "$output" == *"status"* ]]
  [[ "$output" == *"install"* ]]
  [[ "$output" == *"remove"* ]]
  [[ "$output" == *"Exit codes"* ]]
}

@test "plugin CLI unknown command exits 2" {
  run run_plugin_cli frobnicate
  [ "$status" -eq 2 ]
  [[ "$output" == *"unknown ralph plugin command"* ]]
}

# --- list -------------------------------------------------------------------

@test "plugin list shows package availability and state for all five runtimes" {
  run run_plugin_cli list
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -E '^claude[[:space:]]+user[[:space:]]+yes[[:space:]]+absent$'
  printf '%s\n' "$output" | grep -E '^codex[[:space:]]+user[[:space:]]+yes[[:space:]]+absent$'
  printf '%s\n' "$output" | grep -E '^cursor[[:space:]]+user[[:space:]]+yes[[:space:]]+absent$'
  printf '%s\n' "$output" | grep -E '^opencode[[:space:]]+project[[:space:]]+yes[[:space:]]+absent$'
  printf '%s\n' "$output" | grep -E '^antigravity[[:space:]]+user[[:space:]]+yes[[:space:]]+absent$'
}

@test "plugin list --json has schemaVersion 1 and five plugins" {
  run run_plugin_cli list --json
  [ "$status" -eq 0 ]
  printf '%s' "$output" | jq -e '
    .schemaVersion == 1
    and (.plugins | length) == 5
    and all(.plugins[]; .packageAvailable == true)
    and all(.plugins[]; .state == "absent")
  ' >/dev/null
}

@test "plugin list rejects --runtime with exit 2" {
  run run_plugin_cli list --runtime cursor
  [ "$status" -eq 2 ]
}

@test "plugin list reports package=no when packaged asset missing" {
  rm -rf "$RALPH_HOME/plugins/ralph-orchestrator/cursor"
  run run_plugin_cli list
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -E '^cursor[[:space:]]+user[[:space:]]+no[[:space:]]+'
}

# --- status -----------------------------------------------------------------

@test "plugin status requires --runtime and exits 2 without it" {
  run run_plugin_cli status
  [ "$status" -eq 2 ]
  [[ "$output" == *"--runtime is required"* ]]
}

@test "plugin status --runtime cursor prints human fields" {
  run run_plugin_cli status --runtime cursor
  [ "$status" -eq 0 ]
  [[ "$output" == *"runtime: cursor"* ]]
  [[ "$output" == *"scope: user"* ]]
  [[ "$output" == *"package: yes"* ]]
  [[ "$output" == *"state: absent"* ]]
}

@test "plugin status --json includes schemaVersion and state" {
  run run_plugin_cli status --runtime claude --json
  [ "$status" -eq 0 ]
  printf '%s' "$output" | jq -e '
    .schemaVersion == 1
    and .runtime == "claude"
    and .scope == "user"
    and .state == "absent"
    and .packageAvailable == true
  ' >/dev/null
}

@test "plugin status unsupported runtime exits 2" {
  run run_plugin_cli status --runtime gemini
  [ "$status" -eq 2 ]
  [[ "$output" == *"unsupported runtime"* ]]
}

@test "plugin status wrong scope exits 2" {
  run run_plugin_cli status --runtime claude --scope project
  [ "$status" -eq 2 ]
  [[ "$output" == *"not supported"* ]]
}

# --- install matrix / dry-run / confirmation --------------------------------

@test "plugin install requires --runtime and exits 2 without it" {
  run run_plugin_cli install --yes
  [ "$status" -eq 2 ]
  [[ "$output" == *"--runtime is required"* ]]
}

@test "plugin install wrong scope exits 2 before mutation" {
  run run_plugin_cli install --runtime cursor --scope project --yes
  [ "$status" -eq 2 ]
  [ ! -f "$RALPH_HOME/plugin-installs/cursor.json" ]
}

@test "plugin install --dry-run previews and never writes journal" {
  run run_plugin_cli install --runtime cursor --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"preview:"* ]]
  [[ "$output" == *"dry-run: no host mutation"* ]]
  [ ! -f "$RALPH_HOME/plugin-installs/cursor.json" ]
  [ "$(stub_get_via_cli_state cursor)" = "absent" ]
}

@test "plugin install non-TTY without --yes refuses with exit 1" {
  # bats stdin is not a TTY; omit --yes.
  run run_plugin_cli install --runtime cursor
  [ "$status" -eq 1 ]
  [[ "$output" == *"requires --yes"* ]]
  [ ! -f "$RALPH_HOME/plugin-installs/cursor.json" ]
}

@test "plugin install --yes mutates journal and reports current" {
  run run_plugin_cli install --runtime cursor --yes
  [ "$status" -eq 0 ]
  [[ "$output" == *"Confirmed non-interactively"* ]]
  [[ "$output" == *"stub cursor: installed"* ]]
  [ -f "$RALPH_HOME/plugin-installs/cursor.json" ]
  run run_plugin_cli status --runtime cursor
  [ "$status" -eq 0 ]
  [[ "$output" == *"state: current"* ]]
}

@test "plugin install missing package exits 1" {
  rm -rf "$RALPH_HOME/plugins/ralph-orchestrator/codex"
  run run_plugin_cli install --runtime codex --yes
  [ "$status" -eq 1 ]
  [[ "$output" == *"packaged asset missing"* ]]
}

@test "plugin install opencode --yes writes project journal" {
  run run_plugin_cli install --runtime opencode --workspace "$PROJECT_ROOT" --yes
  [ "$status" -eq 0 ]
  [ -f "$PROJECT_ROOT/.ralph-workspace/plugin-installs/opencode.json" ]
  [ ! -f "$RALPH_HOME/plugin-installs/opencode.json" ]
}

# --- remove / drift refusal -------------------------------------------------

@test "plugin remove --dry-run never clears journal" {
  run run_plugin_cli install --runtime cursor --yes
  [ "$status" -eq 0 ]
  run run_plugin_cli remove --runtime cursor --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"dry-run: no host mutation"* ]]
  [ -f "$RALPH_HOME/plugin-installs/cursor.json" ]
}

@test "plugin remove non-TTY without --yes refuses with exit 1" {
  run run_plugin_cli install --runtime cursor --yes
  [ "$status" -eq 0 ]
  run run_plugin_cli remove --runtime cursor
  [ "$status" -eq 1 ]
  [[ "$output" == *"requires --yes"* ]]
  [ -f "$RALPH_HOME/plugin-installs/cursor.json" ]
}

@test "plugin remove --yes clears journal when current" {
  run run_plugin_cli install --runtime cursor --yes
  [ "$status" -eq 0 ]
  run run_plugin_cli remove --runtime cursor --yes
  [ "$status" -eq 0 ]
  [ ! -f "$RALPH_HOME/plugin-installs/cursor.json" ]
  run run_plugin_cli status --runtime cursor
  [ "$status" -eq 0 ]
  [[ "$output" == *"state: absent"* ]]
}

@test "plugin remove refuses drifted state with exit 1" {
  printf 'drifted\n' >"$STUB_STATE/cursor.state"
  mkdir -p "$RALPH_HOME/plugin-installs"
  printf '{"schemaVersion":1,"runtime":"cursor"}\n' >"$RALPH_HOME/plugin-installs/cursor.json"
  run run_plugin_cli remove --runtime cursor --yes
  [ "$status" -eq 1 ]
  [[ "$output" == *"drifted"* ]]
  [ -f "$RALPH_HOME/plugin-installs/cursor.json" ]
}

@test "plugin remove wrong scope exits 2" {
  run run_plugin_cli remove --runtime antigravity --scope project --yes
  [ "$status" -eq 2 ]
}
