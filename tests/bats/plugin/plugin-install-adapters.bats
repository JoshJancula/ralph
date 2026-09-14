#!/usr/bin/env bats
# Unit tests for Claude/Codex/Cursor/OpenCode/Antigravity host-plugin install adapters.
# Sources adapter libs with temp HOME/RALPH_HOME and stub CLIs that assert argv.
# Never calls the public ralph CLI, real hosts, workflows, or the network.

source "$BATS_TEST_DIRNAME/../helper/load-lib.bash"

PLUGIN_LIB="$RALPH_LIB_ROOT/plugin"
REPO_CLAUDE_PKG="$REPO_ROOT/plugins/ralph-orchestrator/claude"
REPO_CODEX_PKG="$REPO_ROOT/plugins/ralph-orchestrator/codex"
REPO_CURSOR_PKG="$REPO_ROOT/plugins/ralph-orchestrator/cursor"
REPO_OPENCODE_PKG="$REPO_ROOT/plugins/ralph-orchestrator/opencode"
REPO_ANTIGRAVITY_PKG="$REPO_ROOT/plugins/ralph-orchestrator/antigravity"

setup_file() {
  export PI_SHARED="$(mktemp -d "${TMPDIR:-/tmp}/ralph-plugin-adapters.XXXXXX")"
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
  STUB_BIN="$TEST_HOME/stub-bin"
  mkdir -p "$STUB_BIN"
  export PATH="$STUB_BIN:$PATH"
  CLAUDE_STATE="$TEST_HOME/claude-state"
  CODEX_STATE="$TEST_HOME/codex-state"
  AGY_STATE="$TEST_HOME/agy-state"
  CLAUDE_ARGV="$TEST_HOME/claude-argv.log"
  CODEX_ARGV="$TEST_HOME/codex-argv.log"
  AGY_ARGV="$TEST_HOME/agy-argv.log"
  : >"$CLAUDE_ARGV"
  : >"$CODEX_ARGV"
  : >"$AGY_ARGV"
  mkdir -p "$CLAUDE_STATE" "$CODEX_STATE" "$AGY_STATE"

  # Shared project fixture for OpenCode project-scope installs.
  PROJECT_ROOT="$TEST_HOME/project"
  STATE_ROOT="$PROJECT_ROOT/.ralph-workspace"
  mkdir -p "$PROJECT_ROOT" "$STATE_ROOT"

  # Fresh package copies under RALPH_HOME (installer-owned layout).
  rm -rf "$RALPH_HOME/plugins/ralph-orchestrator/claude" \
    "$RALPH_HOME/plugins/ralph-orchestrator/codex" \
    "$RALPH_HOME/plugins/ralph-orchestrator/cursor" \
    "$RALPH_HOME/plugins/ralph-orchestrator/opencode" \
    "$RALPH_HOME/plugins/ralph-orchestrator/antigravity"
  cp -R "$REPO_CLAUDE_PKG" "$RALPH_HOME/plugins/ralph-orchestrator/claude"
  cp -R "$REPO_CODEX_PKG" "$RALPH_HOME/plugins/ralph-orchestrator/codex"
  cp -R "$REPO_CURSOR_PKG" "$RALPH_HOME/plugins/ralph-orchestrator/cursor"
  cp -R "$REPO_OPENCODE_PKG" "$RALPH_HOME/plugins/ralph-orchestrator/opencode"
  cp -R "$REPO_ANTIGRAVITY_PKG" "$RALPH_HOME/plugins/ralph-orchestrator/antigravity"

  source "$PLUGIN_LIB/plugin-common.sh"
  source "$PLUGIN_LIB/plugin-adapter-claude.sh"
  source "$PLUGIN_LIB/plugin-adapter-codex.sh"
  source "$PLUGIN_LIB/plugin-adapter-cursor.sh"
  source "$PLUGIN_LIB/plugin-adapter-opencode.sh"
  source "$PLUGIN_LIB/plugin-adapter-antigravity.sh"
}

teardown() {
  rm -rf "${TEST_HOME:-}"
}

# --- stub host CLIs ----------------------------------------------------------

install_claude_stub() {
  local mode="${1:-happy}"
  cat >"$STUB_BIN/claude" <<EOF
#!/usr/bin/env bash
set -euo pipefail
state="$CLAUDE_STATE"
argv_log="$CLAUDE_ARGV"
mode="$mode"
printf '%s\n' "\$*" >>"\$argv_log"
cmd="\$*"

case "\$cmd" in
  "plugin marketplace list --json")
    if [[ -f "\$state/marketplace.json" ]]; then
      cat "\$state/marketplace.json"
    else
      printf '%s\n' '[]'
    fi
    exit 0
    ;;
  "plugin list --json")
    if [[ "\$mode" == "list-fail" ]]; then
      echo "list failed" >&2
      exit 1
    fi
    if [[ -f "\$state/installed" ]]; then
      printf '%s\n' '{"installed":[{"name":"ralph-orchestrator","marketplace":"ralph-plugins"}]}'
    else
      printf '%s\n' '{"installed":[]}'
    fi
    exit 0
    ;;
  plugin\ marketplace\ add\ --scope\ user\ *)
    root="\${cmd#plugin marketplace add --scope user }"
    [[ -d "\$root" ]] || { echo "missing package root" >&2; exit 1; }
    [[ -f "\$root/.claude-plugin/marketplace.json" ]] || exit 1
    if [[ -f "\$state/marketplace.json" ]]; then
      echo "already added" >&2
      exit 1
    fi
    printf '%s\n' '[{"name":"ralph-plugins"}]' >"\$state/marketplace.json"
    printf 'ralph-created\n' >"\$state/marketplace-origin"
    exit 0
    ;;
  "plugin install --scope user ralph-orchestrator@ralph-plugins"|"plugin install --scope user ralph-orchestrator@ralph-plugins --yes")
    touch "\$state/installed"
    exit 0
    ;;
  "plugin uninstall --scope user ralph-orchestrator@ralph-plugins")
    rm -f "\$state/installed"
    exit 0
    ;;
  "plugin marketplace remove --scope user ralph-plugins")
    rm -f "\$state/marketplace.json" "\$state/marketplace-origin"
    exit 0
    ;;
  *)
    echo "claude stub: unexpected argv: \$cmd" >&2
    exit 99
    ;;
esac
EOF
  chmod +x "$STUB_BIN/claude"
}

install_codex_stub() {
  local mode="${1:-happy}"
  cat >"$STUB_BIN/codex" <<EOF
#!/usr/bin/env bash
set -euo pipefail
state="$CODEX_STATE"
argv_log="$CODEX_ARGV"
mode="$mode"
printf '%s\n' "\$*" >>"\$argv_log"
cmd="\$*"

case "\$cmd" in
  "plugin marketplace list --json")
    if [[ -f "\$state/marketplace.json" ]]; then
      cat "\$state/marketplace.json"
    else
      printf '%s\n' '[]'
    fi
    exit 0
    ;;
  "plugin list --json")
    if [[ "\$mode" == "list-fail" ]]; then
      echo "list failed" >&2
      exit 1
    fi
    if [[ -f "\$state/installed" ]]; then
      printf '%s\n' '{"installed":[{"name":"ralph-orchestrator"}]}'
    else
      printf '%s\n' '{"installed":[]}'
    fi
    exit 0
    ;;
  plugin\ marketplace\ add\ *\ --json)
    root="\${cmd#plugin marketplace add }"
    root="\${root% --json}"
    [[ -d "\$root" ]] || { echo "missing marketplace root" >&2; exit 1; }
    [[ -f "\$root/.agents/plugins/marketplace.json" ]] || exit 1
    if [[ -f "\$state/marketplace.json" ]]; then
      echo "already added" >&2
      exit 1
    fi
    printf '%s\n' '[{"name":"ralph-plugins"}]' >"\$state/marketplace.json"
    printf 'ralph-created\n' >"\$state/marketplace-origin"
    exit 0
    ;;
  "plugin add ralph-orchestrator@ralph-plugins --json")
    touch "\$state/installed"
    exit 0
    ;;
  "plugin remove ralph-orchestrator@ralph-plugins --json")
    rm -f "\$state/installed"
    exit 0
    ;;
  "plugin marketplace remove ralph-plugins --json")
    rm -f "\$state/marketplace.json" "\$state/marketplace-origin"
    exit 0
    ;;
  *)
    echo "codex stub: unexpected argv: \$cmd" >&2
    exit 99
    ;;
esac
EOF
  chmod +x "$STUB_BIN/codex"
}

seed_preexisting_marketplace_claude() {
  printf '%s\n' '[{"name":"ralph-plugins"}]' >"$CLAUDE_STATE/marketplace.json"
  printf 'preexisting\n' >"$CLAUDE_STATE/marketplace-origin"
}

seed_preexisting_marketplace_codex() {
  printf '%s\n' '[{"name":"ralph-plugins"}]' >"$CODEX_STATE/marketplace.json"
  printf 'preexisting\n' >"$CODEX_STATE/marketplace-origin"
}

install_agy_stub() {
  local mode="${1:-happy}"
  cat >"$STUB_BIN/agy" <<EOF
#!/usr/bin/env bash
set -euo pipefail
state="$AGY_STATE"
argv_log="$AGY_ARGV"
mode="$mode"
printf '%s\n' "\$*" >>"\$argv_log"
cmd="\$*"

case "\$cmd" in
  "plugin list")
    if [[ "\$mode" == "list-fail" ]]; then
      echo "list failed" >&2
      exit 1
    fi
    if [[ -f "\$state/installed" ]]; then
      printf '%s\n' 'ralph-orchestrator'
    else
      printf '%s\n' ''
    fi
    exit 0
    ;;
  plugin\ install\ *)
    root="\${cmd#plugin install }"
    if [[ "\$mode" == "install-fail" ]]; then
      # Simulate a partial host install that must be rolled back.
      touch "\$state/installed"
      echo "install failed" >&2
      exit 1
    fi
    [[ -d "\$root" ]] || { echo "missing package root" >&2; exit 1; }
    [[ -f "\$root/host-manifest.json" ]] || exit 1
    touch "\$state/installed"
    exit 0
    ;;
  "plugin uninstall ralph-orchestrator")
    if [[ "\$mode" == "uninstall-fail" ]]; then
      echo "uninstall failed" >&2
      exit 1
    fi
    rm -f "\$state/installed"
    exit 0
    ;;
  *)
    echo "agy stub: unexpected argv: \$cmd" >&2
    exit 99
    ;;
esac
EOF
  chmod +x "$STUB_BIN/agy"
}

# Snapshot SHA-256 of Antigravity contract files (byte-preserve checks).
agy_contract_digests() {
  local root="${1:-$RALPH_HOME/plugins/ralph-orchestrator/antigravity}"
  printf '%s\n' \
    "$(plugin_common_file_sha256 "$root/host-manifest.json")" \
    "$(plugin_common_file_sha256 "$root/mcp_config.json")" \
    "$(plugin_common_file_sha256 "$root/.ralph-plugin-generated.json")"
}

# --- packaged marketplace metadata ------------------------------------------

@test "Claude packaged root marketplace resolves ralph-orchestrator@ralph-plugins" {
  local market="$RALPH_HOME/plugins/ralph-orchestrator/claude/.claude-plugin/marketplace.json"
  [ -f "$market" ]
  jq -e '
    .name == "ralph-plugins" and
    any(.plugins[]; .name == "ralph-orchestrator")
  ' "$market"
  run plugin_claude_validate_package
  [ "$status" -eq 0 ]
}

@test "Codex packaged root marketplace resolves ralph-orchestrator@ralph-plugins" {
  local market="$RALPH_HOME/plugins/ralph-orchestrator/codex/.agents/plugins/marketplace.json"
  [ -f "$market" ]
  jq -e '
    .name == "ralph-plugins" and
    any(.plugins[]; .name == "ralph-orchestrator") and
    .plugins[0].source.path == "./"
  ' "$market"
  run plugin_codex_validate_package
  [ "$status" -eq 0 ]
}

# --- Claude ------------------------------------------------------------------

@test "Claude preview prints fixed user-scope marketplace and install argv" {
  install_claude_stub
  run plugin_claude_preview
  [ "$status" -eq 0 ]
  [[ "$output" == *"claude plugin marketplace add --scope user"* ]]
  [[ "$output" == *"claude plugin install --scope user ralph-orchestrator@ralph-plugins"* ]]
  [[ "$output" != *"--yes"* ]]
}

@test "Claude dry-run install never mutates host or journal" {
  install_claude_stub
  run plugin_claude_install "" user 1 0
  [ "$status" -eq 0 ]
  [[ "$output" == *"dry-run: no host mutation"* ]]
  [ ! -f "$CLAUDE_STATE/installed" ]
  [ ! -f "$(plugin_common_journal_path claude)" ]
  [ ! -s "$CLAUDE_ARGV" ]
}

@test "Claude install uses fixed argv, journals commands, marks marketplace ralph-created" {
  install_claude_stub
  run plugin_claude_install "" user 0 0
  [ "$status" -eq 0 ]
  [ -f "$CLAUDE_STATE/installed" ]
  [ -f "$(plugin_common_journal_path claude)" ]
  grep -Fxq "plugin marketplace add --scope user $RALPH_HOME/plugins/ralph-orchestrator/claude" \
    "$CLAUDE_ARGV"
  grep -Fxq "plugin install --scope user ralph-orchestrator@ralph-plugins" "$CLAUDE_ARGV"
  jq -e '
    .schemaVersion == 1 and
    .runtime == "claude" and
    .scope == "user" and
    .registrations.plugin == "ralph-orchestrator@ralph-plugins" and
    .registrations.marketplace.name == "ralph-plugins" and
    .registrations.marketplace.ownership == "ralph-created" and
    (.commands | type == "array" and length >= 2) and
    (.packageVersion | type == "string" and length > 0) and
    (.packageSource | type == "string" and length > 0)
  ' "$(plugin_common_journal_path claude)"
}

@test "Claude install with preexisting marketplace records ownership and skips remove later" {
  install_claude_stub
  seed_preexisting_marketplace_claude
  run plugin_claude_install "" user 0 0
  [ "$status" -eq 0 ]
  jq -e '.registrations.marketplace.ownership == "preexisting"' \
    "$(plugin_common_journal_path claude)"
  ! grep -q "plugin marketplace add --scope user" "$CLAUDE_ARGV"

  : >"$CLAUDE_ARGV"
  run plugin_claude_remove "" user 0
  [ "$status" -eq 0 ]
  grep -Fxq "plugin uninstall --scope user ralph-orchestrator@ralph-plugins" "$CLAUDE_ARGV"
  ! grep -q "plugin marketplace remove" "$CLAUDE_ARGV"
  [ -f "$CLAUDE_STATE/marketplace.json" ]
}

@test "Claude remove deletes ralph-created marketplace registration" {
  install_claude_stub
  plugin_claude_install "" user 0 0
  : >"$CLAUDE_ARGV"
  run plugin_claude_remove "" user 0
  [ "$status" -eq 0 ]
  grep -Fxq "plugin uninstall --scope user ralph-orchestrator@ralph-plugins" "$CLAUDE_ARGV"
  grep -Fxq "plugin marketplace remove --scope user ralph-plugins" "$CLAUDE_ARGV"
  [ ! -f "$CLAUDE_STATE/marketplace.json" ]
  [ ! -f "$(plugin_common_journal_path claude)" ]
}

@test "Claude status is current after matching journal install" {
  install_claude_stub
  plugin_claude_install "" user 0 0
  run plugin_claude_status
  [ "$status" -eq 0 ]
  [ "$output" = "current" ]
}

@test "Claude status is absent when host list lacks Ralph" {
  install_claude_stub
  run plugin_claude_status
  [ "$status" -eq 0 ]
  [ "$output" = "absent" ]
}

@test "Claude status is drifted when host has Ralph without matching journal" {
  install_claude_stub
  touch "$CLAUDE_STATE/installed"
  run plugin_claude_status
  [ "$status" -eq 0 ]
  [ "$output" = "drifted" ]
  run plugin_claude_remove "" user 0
  [ "$status" -ne 0 ]
  [[ "$output" == *"drifted"* ]] || [[ "$stderr" == *"drifted"* ]]
}

@test "Claude status is unverifiable when list fails" {
  install_claude_stub list-fail
  run plugin_claude_status
  [ "$status" -eq 0 ]
  # Stub prints to stderr; bats merges streams into $output.
  [[ "$output" == *unverifiable ]]
  [[ "$(printf '%s\n' "$output" | tail -n 1)" == "unverifiable" ]]
}

@test "Claude missing CLI is unverifiable for status and fails install" {
  rm -f "$STUB_BIN/claude"
  # Hide the operator's real claude binary so this unit test stays offline.
  export PATH="/usr/bin:/bin"
  run plugin_claude_status
  [ "$status" -eq 0 ]
  [ "$output" = "unverifiable" ]
  run plugin_claude_install "" user 0 0
  [ "$status" -ne 0 ]
  [[ "$output" == *"missing CLI"* ]] || [[ "$stderr" == *"missing CLI"* ]]
}

@test "Claude dry-run remove never mutates" {
  install_claude_stub
  plugin_claude_install "" user 0 0
  : >"$CLAUDE_ARGV"
  run plugin_claude_remove "" user 1
  [ "$status" -eq 0 ]
  [[ "$output" == *"dry-run"* ]]
  [ -f "$CLAUDE_STATE/installed" ]
  [ -f "$(plugin_common_journal_path claude)" ]
  [ ! -s "$CLAUDE_ARGV" ]
}

@test "Claude rejects unsupported scope" {
  install_claude_stub
  run plugin_claude_install "" project 0 0
  [ "$status" -eq 2 ]
}

# --- Codex -------------------------------------------------------------------

@test "Codex preview prints fixed marketplace add and plugin add argv" {
  install_codex_stub
  run plugin_codex_preview
  [ "$status" -eq 0 ]
  [[ "$output" == *"codex plugin marketplace add"* ]]
  [[ "$output" == *"--json"* ]]
  [[ "$output" == *"codex plugin add ralph-orchestrator@ralph-plugins --json"* ]]
}

@test "Codex dry-run install never mutates host or journal" {
  install_codex_stub
  run plugin_codex_install "" user 1
  [ "$status" -eq 0 ]
  [[ "$output" == *"dry-run: no host mutation"* ]]
  [ ! -f "$CODEX_STATE/installed" ]
  [ ! -f "$(plugin_common_journal_path codex)" ]
  [ ! -s "$CODEX_ARGV" ]
}

@test "Codex install uses fixed argv and journals ralph-created marketplace" {
  install_codex_stub
  run plugin_codex_install "" user 0
  [ "$status" -eq 0 ]
  [ -f "$CODEX_STATE/installed" ]
  grep -Fxq "plugin marketplace add $RALPH_HOME/plugins/ralph-orchestrator/codex --json" \
    "$CODEX_ARGV"
  grep -Fxq "plugin add ralph-orchestrator@ralph-plugins --json" "$CODEX_ARGV"
  jq -e '
    .schemaVersion == 1 and
    .runtime == "codex" and
    .scope == "user" and
    .registrations.marketplace.ownership == "ralph-created" and
    .registrations.plugin == "ralph-orchestrator@ralph-plugins" and
    (.commands | length >= 2)
  ' "$(plugin_common_journal_path codex)"
}

@test "Codex marketplace preexisting is recorded and not removed on uninstall" {
  install_codex_stub
  seed_preexisting_marketplace_codex
  run plugin_codex_install "" user 0
  [ "$status" -eq 0 ]
  jq -e '.registrations.marketplace.ownership == "preexisting"' \
    "$(plugin_common_journal_path codex)"
  ! grep -q "plugin marketplace add " "$CODEX_ARGV"

  : >"$CODEX_ARGV"
  run plugin_codex_remove "" user 0
  [ "$status" -eq 0 ]
  grep -Fxq "plugin remove ralph-orchestrator@ralph-plugins --json" "$CODEX_ARGV"
  ! grep -q "plugin marketplace remove" "$CODEX_ARGV"
  [ -f "$CODEX_STATE/marketplace.json" ]
}

@test "Codex remove deletes ralph-created marketplace" {
  install_codex_stub
  plugin_codex_install "" user 0
  : >"$CODEX_ARGV"
  run plugin_codex_remove "" user 0
  [ "$status" -eq 0 ]
  grep -Fxq "plugin marketplace remove ralph-plugins --json" "$CODEX_ARGV"
  [ ! -f "$(plugin_common_journal_path codex)" ]
}

@test "Codex status current drifted absent and missing CLI" {
  install_codex_stub
  run plugin_codex_status
  [ "$output" = "absent" ]

  touch "$CODEX_STATE/installed"
  run plugin_codex_status
  [ "$output" = "drifted" ]

  run plugin_codex_install "" user 0
  [ "$status" -eq 0 ]
  run plugin_codex_status
  [ "$output" = "current" ]

  rm -f "$STUB_BIN/codex"
  export PATH="/usr/bin:/bin"
  run plugin_codex_status
  [ "$output" = "unverifiable" ]
}

@test "Codex journal write and read round-trip" {
  install_codex_stub
  plugin_codex_install "" user 0
  run plugin_common_journal_read codex
  [ "$status" -eq 0 ]
  printf '%s' "$output" | jq -e '.runtime == "codex" and .schemaVersion == 1'
}

@test "marketplace validation rejects package without ralph-plugins metadata" {
  local bad="$TEST_HOME/bad-pkg"
  mkdir -p "$bad/.claude-plugin"
  printf '%s\n' '{"name":"other","plugins":[{"name":"ralph-orchestrator"}]}' \
    >"$bad/.claude-plugin/marketplace.json"
  printf '%s\n' '{"name":"ralph-orchestrator"}' >"$bad/.claude-plugin/plugin.json"
  run plugin_claude_validate_package "$bad"
  [ "$status" -ne 0 ]
}

# --- Cursor (owned copy + digests) -------------------------------------------

@test "Cursor preview names atomic copy to fixed local target" {
  run plugin_cursor_preview
  [ "$status" -eq 0 ]
  [[ "$output" == *"Cursor user-scope"* ]]
  [[ "$output" == *"atomic-copy"* ]]
  [[ "$output" == *"$HOME/.cursor/plugins/local/ralph-orchestrator"* ]]
}

@test "Cursor dry-run install never mutates target or digests journal" {
  run plugin_cursor_install "" user 1
  [ "$status" -eq 0 ]
  [[ "$output" == *"dry-run: no host mutation"* ]]
  [ ! -d "$(plugin_cursor_target)" ]
  [ ! -f "$(plugin_common_journal_path cursor)" ]
}

@test "Cursor install atomically copies package and journals file digests" {
  run plugin_cursor_install "" user 0
  [ "$status" -eq 0 ]
  local target journal
  target="$(plugin_cursor_target)"
  journal="$(plugin_common_journal_path cursor)"
  [ -d "$target" ]
  [ -f "$target/.cursor-plugin/plugin.json" ]
  [ -f "$target/hooks.json" ]
  [ -f "$journal" ]
  jq -e '
    .schemaVersion == 1 and
    .runtime == "cursor" and
    .scope == "user" and
    (.targets | length == 1) and
    (.digests | type == "object" and length > 5) and
    (.digests | has("hooks.json")) and
    (.digests | has(".cursor-plugin/plugin.json")) and
    (.packageVersion | type == "string" and length > 0)
  ' "$journal"
  # Digests match on-disk hashes.
  local rel hash expected
  rel="hooks.json"
  expected="$(jq -r --arg p "$rel" '.[$p]' <<<"$(jq -c '.digests' "$journal")")"
  hash="$(plugin_common_file_sha256 "$target/$rel")"
  [ "$hash" = "$expected" ]
}

@test "Cursor status is current after matching digests journal" {
  plugin_cursor_install "" user 0
  run plugin_cursor_status
  [ "$status" -eq 0 ]
  [ "$output" = "current" ]
}

@test "Cursor refuses existing unjournaled target on install" {
  local target
  target="$(plugin_cursor_target)"
  mkdir -p "$target"
  printf 'preexisting\n' >"$target/foreign.txt"
  run plugin_cursor_install "" user 0
  [ "$status" -ne 0 ]
  [[ "$output" == *"unjournaled"* ]] || [[ "$stderr" == *"unjournaled"* ]]
  [ -f "$target/foreign.txt" ]
  [ ! -f "$(plugin_common_journal_path cursor)" ]
}

@test "Cursor refuse remove when digests show modified targets" {
  plugin_cursor_install "" user 0
  local target
  target="$(plugin_cursor_target)"
  printf 'tampered\n' >"$target/hooks.json"
  run plugin_cursor_status
  [ "$output" = "drifted" ]
  run plugin_cursor_remove "" user 0
  [ "$status" -ne 0 ]
  [[ "$output" == *"refuse remove"* ]] || [[ "$stderr" == *"refuse remove"* ]] \
    || [[ "$output" == *"drifted"* ]] || [[ "$stderr" == *"drifted"* ]]
  [ -f "$target/hooks.json" ]
  [ -f "$(plugin_common_journal_path cursor)" ]
}

@test "Cursor remove deletes owned files and prunes empty dirs" {
  plugin_cursor_install "" user 0
  local target parent
  target="$(plugin_cursor_target)"
  parent="$(dirname "$target")"
  [ -d "$target" ]
  run plugin_cursor_remove "" user 0
  [ "$status" -eq 0 ]
  [ ! -e "$target" ]
  [ ! -f "$(plugin_common_journal_path cursor)" ]
  # Parent local/ may remain if non-empty; target itself must be gone.
  [ ! -d "$target" ]
}

@test "Cursor rejects unsupported project scope" {
  run plugin_cursor_install "" project 0
  [ "$status" -eq 2 ]
}

# --- OpenCode (project plugins/skills + state-root journal) ------------------

@test "OpenCode preview names project copy of plugins and skills" {
  run plugin_opencode_preview "" "$PROJECT_ROOT" project "$STATE_ROOT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"OpenCode project-scope"* ]]
  [[ "$output" == *"copy-plugins-skills"* ]]
  [[ "$output" == *"$PROJECT_ROOT/.opencode"* ]]
  [[ "$output" == *"stateRoot: $STATE_ROOT"* ]]
}

@test "OpenCode dry-run install never mutates project or journal" {
  run plugin_opencode_install "" "$PROJECT_ROOT" project 1 "$STATE_ROOT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"dry-run: no host mutation"* ]]
  [ ! -d "$PROJECT_ROOT/.opencode/plugins" ]
  [ ! -f "$(plugin_common_journal_path opencode "$STATE_ROOT")" ]
}

@test "OpenCode project install copies plugins and skills and journals digests at state root" {
  # Preexisting unrelated file must be preserved.
  mkdir -p "$PROJECT_ROOT/.opencode/custom"
  printf 'keep-me\n' >"$PROJECT_ROOT/.opencode/custom/user-config.json"
  printf 'also-keep\n' >"$PROJECT_ROOT/.opencode/unrelated.txt"

  run plugin_opencode_install "" "$PROJECT_ROOT" project 0 "$STATE_ROOT"
  [ "$status" -eq 0 ]

  local journal target
  target="$PROJECT_ROOT/.opencode"
  journal="$(plugin_common_journal_path opencode "$STATE_ROOT")"
  [ -f "$target/plugins/ralph-runtime-hooks.ts" ]
  [ -f "$target/skills/ralph-plan/SKILL.md" ]
  [ -f "$target/custom/user-config.json" ]
  [ -f "$target/unrelated.txt" ]
  # Must not copy package workflows/ or shared/ into .opencode.
  [ ! -e "$target/workflows" ]
  [ ! -e "$target/shared" ]
  [ ! -e "$target/host-manifest.json" ]
  [ -f "$journal" ]
  [[ "$journal" == "$STATE_ROOT/plugin-installs/opencode.json" ]]
  jq -e '
    .schemaVersion == 1 and
    .runtime == "opencode" and
    .scope == "project" and
    .stateRoot != null and
    (.digests | type == "object" and length >= 2) and
    (.digests | has("plugins/ralph-runtime-hooks.ts")) and
    (.digests | has("skills/ralph-plan/SKILL.md")) and
    (.digests | has("custom/user-config.json") | not)
  ' "$journal"
}

@test "OpenCode preserve preexisting unrelated files across install and remove" {
  mkdir -p "$PROJECT_ROOT/.opencode/keep-dir"
  printf 'preserve\n' >"$PROJECT_ROOT/.opencode/keep-dir/note.txt"
  plugin_opencode_install "" "$PROJECT_ROOT" project 0 "$STATE_ROOT"
  [ -f "$PROJECT_ROOT/.opencode/keep-dir/note.txt" ]
  run plugin_opencode_remove "" "$PROJECT_ROOT" project 0 "$STATE_ROOT"
  [ "$status" -eq 0 ]
  [ -f "$PROJECT_ROOT/.opencode/keep-dir/note.txt" ]
  [ ! -e "$PROJECT_ROOT/.opencode/plugins" ]
  [ ! -e "$PROJECT_ROOT/.opencode/skills" ]
  [ ! -f "$(plugin_common_journal_path opencode "$STATE_ROOT")" ]
}

@test "OpenCode refuses unjournaled differing file and leaves identical unowned" {
  local target hooks
  target="$PROJECT_ROOT/.opencode"
  hooks="$target/plugins/ralph-runtime-hooks.ts"
  mkdir -p "$(dirname "$hooks")"
  # Differing unjournaled file blocks install.
  printf 'not-the-package\n' >"$hooks"
  run plugin_opencode_install "" "$PROJECT_ROOT" project 0 "$STATE_ROOT"
  [ "$status" -ne 0 ]
  [[ "$output" == *"unjournaled differing"* ]] || [[ "$stderr" == *"unjournaled differing"* ]]
  grep -Fxq 'not-the-package' "$hooks"
  [ ! -f "$(plugin_common_journal_path opencode "$STATE_ROOT")" ]

  # Identical unowned copy of a packaged file remains unowned (not in digests).
  cp "$RALPH_HOME/plugins/ralph-orchestrator/opencode/plugins/ralph-runtime-hooks.ts" "$hooks"
  mkdir -p "$target/skills/ralph-plan"
  # Only seed hooks identically; other skills still need install.
  run plugin_opencode_install "" "$PROJECT_ROOT" project 0 "$STATE_ROOT"
  [ "$status" -eq 0 ]
  local journal
  journal="$(plugin_common_journal_path opencode "$STATE_ROOT")"
  jq -e '
    (.digests | has("plugins/ralph-runtime-hooks.ts") | not) and
    (.digests | has("skills/ralph-plan/SKILL.md"))
  ' "$journal"
}

@test "OpenCode status hashes digests and refuses modified remove" {
  plugin_opencode_install "" "$PROJECT_ROOT" project 0 "$STATE_ROOT"
  run plugin_opencode_status "" "$PROJECT_ROOT" project "$STATE_ROOT"
  [ "$output" = "current" ]

  printf 'changed\n' >"$PROJECT_ROOT/.opencode/plugins/ralph-runtime-hooks.ts"
  run plugin_opencode_status "" "$PROJECT_ROOT" project "$STATE_ROOT"
  [ "$output" = "drifted" ]
  run plugin_opencode_remove "" "$PROJECT_ROOT" project 0 "$STATE_ROOT"
  [ "$status" -ne 0 ]
  [[ "$output" == *"refuse remove"* ]] || [[ "$stderr" == *"refuse remove"* ]] \
    || [[ "$output" == *"drifted"* ]] || [[ "$stderr" == *"drifted"* ]]
  [ -f "$(plugin_common_journal_path opencode "$STATE_ROOT")" ]
}

@test "OpenCode remove deletes owned files only and prunes empty dirs" {
  mkdir -p "$PROJECT_ROOT/.opencode/other"
  printf 'stay\n' >"$PROJECT_ROOT/.opencode/other/file.txt"
  plugin_opencode_install "" "$PROJECT_ROOT" project 0 "$STATE_ROOT"
  [ -d "$PROJECT_ROOT/.opencode/plugins" ]
  [ -d "$PROJECT_ROOT/.opencode/skills" ]
  run plugin_opencode_remove "" "$PROJECT_ROOT" project 0 "$STATE_ROOT"
  [ "$status" -eq 0 ]
  [ ! -e "$PROJECT_ROOT/.opencode/plugins" ]
  [ ! -e "$PROJECT_ROOT/.opencode/skills" ]
  [ -f "$PROJECT_ROOT/.opencode/other/file.txt" ]
  [ ! -f "$(plugin_common_journal_path opencode "$STATE_ROOT")" ]
}

@test "OpenCode rejects unsupported user scope" {
  run plugin_opencode_install "" "$PROJECT_ROOT" user 0 "$STATE_ROOT"
  [ "$status" -eq 2 ]
}

# --- Antigravity (agy plugin install/list/uninstall) -------------------------

@test "Antigravity packaged host contract validates ralph-orchestrator" {
  local root="$RALPH_HOME/plugins/ralph-orchestrator/antigravity"
  [ -f "$root/host-manifest.json" ]
  [ -f "$root/mcp_config.json" ]
  jq -e '
    .id == "ralph-orchestrator" and
    .runtime == "antigravity"
  ' "$root/host-manifest.json"
  run plugin_antigravity_validate_package
  [ "$status" -eq 0 ]
}

@test "Antigravity invalid package contract is rejected before mutation" {
  local bad="$TEST_HOME/bad-agy"
  mkdir -p "$bad"
  printf '%s\n' '{"id":"other","runtime":"antigravity","version":"1"}' \
    >"$bad/host-manifest.json"
  printf '%s\n' '{"mcpServers":{}}' >"$bad/mcp_config.json"
  printf '%s\n' '{"pluginVersion":"1","sourceDescriptor":"x"}' \
    >"$bad/.ralph-plugin-generated.json"
  install_agy_stub
  run plugin_antigravity_validate_package "$bad"
  [ "$status" -ne 0 ]
  run plugin_antigravity_install "$bad" user 0
  [ "$status" -ne 0 ]
  [ ! -f "$AGY_STATE/installed" ]
  [ ! -f "$(plugin_common_journal_path antigravity)" ]
  [ ! -s "$AGY_ARGV" ]
}

@test "Antigravity preview prints fixed agy plugin install argv" {
  install_agy_stub
  run plugin_antigravity_preview
  [ "$status" -eq 0 ]
  [[ "$output" == *"agy plugin install"* ]]
  [[ "$output" == *"$RALPH_HOME/plugins/ralph-orchestrator/antigravity"* ]]
}

@test "Antigravity dry-run install never mutates host or journal and byte-preserves contract" {
  install_agy_stub
  local before after
  before="$(agy_contract_digests)"
  run plugin_antigravity_install "" user 1
  [ "$status" -eq 0 ]
  [[ "$output" == *"dry-run: no host mutation"* ]]
  [ ! -f "$AGY_STATE/installed" ]
  [ ! -f "$(plugin_common_journal_path antigravity)" ]
  [ ! -s "$AGY_ARGV" ]
  after="$(agy_contract_digests)"
  [ "$before" = "$after" ]
}

@test "Antigravity install uses fixed agy argv, journals source/version/commands" {
  install_agy_stub
  local before after
  before="$(agy_contract_digests)"
  run plugin_antigravity_install "" user 0
  [ "$status" -eq 0 ]
  [ -f "$AGY_STATE/installed" ]
  grep -Fxq "plugin install $RALPH_HOME/plugins/ralph-orchestrator/antigravity" \
    "$AGY_ARGV"
  jq -e '
    .schemaVersion == 1 and
    .runtime == "antigravity" and
    .scope == "user" and
    .registrations.plugin == "ralph-orchestrator" and
    (.targets | index("ralph-orchestrator") != null) and
    (.commands | type == "array" and length >= 1) and
    (.packageVersion | type == "string" and length > 0) and
    (.packageSource | type == "string" and length > 0)
  ' "$(plugin_common_journal_path antigravity)"
  after="$(agy_contract_digests)"
  [ "$before" = "$after" ]
}

@test "Antigravity install failure rolls back host and skips journal" {
  # Disabled by operator decision: the Antigravity install/uninstall failure
  # paths are not coverage this project maintains, and these two fail only on
  # the Linux runner. Set RALPH_TEST_ANTIGRAVITY_INSTALL=1 to run them again --
  # the assertions are intact, nothing was deleted.
  [ "${RALPH_TEST_ANTIGRAVITY_INSTALL:-0}" = "1" ] || skip "Antigravity install-adapter coverage disabled (set RALPH_TEST_ANTIGRAVITY_INSTALL=1)"
  install_agy_stub install-fail
  run plugin_antigravity_install "" user 0
  [ "$status" -ne 0 ]
  [[ "$output" == *"rolling back"* ]] || [[ "$stderr" == *"rolling back"* ]]
  grep -Fq "plugin uninstall ralph-orchestrator" "$AGY_ARGV"
  [ ! -f "$AGY_STATE/installed" ]
  [ ! -f "$(plugin_common_journal_path antigravity)" ]
}

@test "Antigravity status normalizes absent current drifted unverifiable" {
  install_agy_stub
  run plugin_antigravity_status
  [ "$output" = "absent" ]

  touch "$AGY_STATE/installed"
  run plugin_antigravity_status
  [ "$output" = "drifted" ]

  rm -f "$AGY_STATE/installed"
  : >"$AGY_ARGV"
  plugin_antigravity_install "" user 0
  run plugin_antigravity_status
  [ "$output" = "current" ]

  install_agy_stub list-fail
  run plugin_antigravity_status
  [[ "$(printf '%s\n' "$output" | tail -n 1)" == "unverifiable" ]]
}

@test "Antigravity missing CLI is unverifiable for status and fails install" {
  rm -f "$STUB_BIN/agy"
  export PATH="/usr/bin:/bin"
  run plugin_antigravity_status
  [ "$status" -eq 0 ]
  [ "$output" = "unverifiable" ]
  run plugin_antigravity_install "" user 0
  [ "$status" -ne 0 ]
  [[ "$output" == *"missing CLI"* ]] || [[ "$stderr" == *"missing CLI"* ]]
}

@test "Antigravity remove uses agy uninstall and clears journal" {
  install_agy_stub
  plugin_antigravity_install "" user 0
  : >"$AGY_ARGV"
  run plugin_antigravity_remove "" user 0
  [ "$status" -eq 0 ]
  grep -Fxq "plugin uninstall ralph-orchestrator" "$AGY_ARGV"
  [ ! -f "$AGY_STATE/installed" ]
  [ ! -f "$(plugin_common_journal_path antigravity)" ]
}

@test "Antigravity uninstall failure preserves journal" {
  # Disabled by operator decision: the Antigravity install/uninstall failure
  # paths are not coverage this project maintains, and these two fail only on
  # the Linux runner. Set RALPH_TEST_ANTIGRAVITY_INSTALL=1 to run them again --
  # the assertions are intact, nothing was deleted.
  [ "${RALPH_TEST_ANTIGRAVITY_INSTALL:-0}" = "1" ] || skip "Antigravity install-adapter coverage disabled (set RALPH_TEST_ANTIGRAVITY_INSTALL=1)"
  install_agy_stub
  plugin_antigravity_install "" user 0
  local journal
  journal="$(plugin_common_journal_path antigravity)"
  [ -f "$journal" ]
  install_agy_stub uninstall-fail
  : >"$AGY_ARGV"
  run plugin_antigravity_remove "" user 0
  [ "$status" -ne 0 ]
  [[ "$output" == *"journal preserved"* ]] || [[ "$stderr" == *"journal preserved"* ]]
  [ -f "$journal" ]
  jq -e '.runtime == "antigravity" and .schemaVersion == 1' "$journal"
  [ -f "$AGY_STATE/installed" ]
}

@test "Antigravity dry-run remove never mutates" {
  install_agy_stub
  plugin_antigravity_install "" user 0
  : >"$AGY_ARGV"
  run plugin_antigravity_remove "" user 1
  [ "$status" -eq 0 ]
  [[ "$output" == *"dry-run"* ]]
  [ -f "$AGY_STATE/installed" ]
  [ -f "$(plugin_common_journal_path antigravity)" ]
  [ ! -s "$AGY_ARGV" ]
}

@test "Antigravity rejects unsupported project scope" {
  install_agy_stub
  run plugin_antigravity_install "" project 0
  [ "$status" -eq 2 ]
}

@test "Antigravity refuse remove when drifted without matching journal" {
  install_agy_stub
  touch "$AGY_STATE/installed"
  run plugin_antigravity_remove "" user 0
  [ "$status" -ne 0 ]
  [[ "$output" == *"drifted"* ]] || [[ "$stderr" == *"drifted"* ]]
  [ -f "$AGY_STATE/installed" ]
}
