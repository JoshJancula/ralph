#!/usr/bin/env bats

source "$BATS_TEST_DIRNAME/../../helper/load-lib.bash"

SETUP_RUNTIME_SH="$REPO_ROOT/bundle/.ralph/setup-runtime.sh"

setup() {
  TEST_TMPDIR="$(mktemp -d)"
  PROJECT="$TEST_TMPDIR/project"
  mkdir -p "$PROJECT"
}

teardown() {
  rm -rf "$TEST_TMPDIR"
}

runtime_dir() {
  case "$1" in
    antigravity) printf '%s/.agents' "$PROJECT" ;;
    *) printf '%s/.%s' "$PROJECT" "$1" ;;
  esac
}

mcp_path() {
  case "$1" in
    codex) printf '%s/config.toml' "$(runtime_dir "$1")" ;;
    opencode) printf '%s/opencode.json' "$PROJECT" ;;
    antigravity) printf '%s/mcp_config.json' "$(runtime_dir "$1")" ;;
  esac
}

hooks_config_path() {
  case "$1" in
    codex|antigravity) printf '%s/hooks.json' "$(runtime_dir "$1")" ;;
  esac
}

bundle_hooks_dir() {
  case "$1" in
    antigravity) printf '%s/bundle/.agents/hooks' "$REPO_ROOT" ;;
    *) printf '%s/bundle/.%s/hooks' "$REPO_ROOT" "$1" ;;
  esac
}

opencode_plugin_source() {
  printf '%s/bundle/.opencode/plugins/ralph-runtime-hooks.ts' "$REPO_ROOT"
}

write_mixed_mcp() {
  local runtime="$1" path
  path="$(mcp_path "$runtime")"
  mkdir -p "$(dirname "$path")"
  case "$runtime" in
    codex)
      cat >"$path" <<'EOF'
# keep this comment
[other]
keep = true

[mcp_servers.native]
command = "stay"

[mcp_servers.ralph]
command = "bash"
args = ["ignored"]

[mcp_servers.ralph.env]
RALPH_MODE = "hybrid"
EOF
      ;;
    opencode)
      cat >"$path" <<'EOF'
{
  // keep this comment
  "mcp": {
    "ralph": {
      "type": "local",
      "command": ["bash"]
    },
    "native": {
      "command": ["stay"]
    }
  },
  "other": {
    "keep": true
  }
}
EOF
      ;;
    antigravity)
      cat >"$path" <<'EOF'
{
  "mcpServers": {
    "ralph": {
      "command": "bash"
    },
    "native": {
      "command": "native"
    }
  },
  "other": {
    "keep": true
  }
}
EOF
      ;;
  esac
}

write_clean_mcp() {
  local runtime="$1" path
  path="$(mcp_path "$runtime")"
  mkdir -p "$(dirname "$path")"
  case "$runtime" in
    codex)
      cat >"$path" <<'EOF'
[mcp_servers.ralph]
command = "bash"
EOF
      ;;
    opencode)
      cat >"$path" <<'EOF'
{
  "mcp": {
    "ralph": {
      "type": "local",
      "command": ["bash"]
    }
  }
}
EOF
      ;;
    antigravity)
      cat >"$path" <<'EOF'
{
  "mcpServers": {
    "ralph": {
      "command": "bash"
    }
  }
}
EOF
      ;;
  esac
}

write_unrelated_mcp() {
  local runtime="$1" path
  path="$(mcp_path "$runtime")"
  mkdir -p "$(dirname "$path")"
  case "$runtime" in
    codex)
      printf '# stay\n[mcp_servers.native]\ncommand = "stay"\n' >"$path"
      ;;
    opencode)
      printf '{\n  // stay\n  "mcp": {\n    "native": {"command": ["stay"]}\n  }\n}\n' >"$path"
      ;;
    antigravity)
      printf '{\n  "mcpServers": {\n    "native": {"command": "stay"}\n  }\n}\n' >"$path"
      ;;
  esac
}

write_mixed_hooks_json() {
  local runtime="$1" path
  path="$(hooks_config_path "$runtime")"
  mkdir -p "$(dirname "$path")"
  case "$runtime" in
    codex)
      cat >"$path" <<'EOF'
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Bash",
        "hooks": [
          {
            "type": "command",
            "command": ".codex/hooks/pre-tool-bash-policy.sh"
          },
          {
            "type": "command",
            "command": "user-hook.sh"
          }
        ]
      },
      {
        "matcher": "UserTool",
        "hooks": [
          {
            "type": "command",
            "command": "keep-me.sh"
          }
        ]
      }
    ]
  }
}
EOF
      ;;
    antigravity)
      cat >"$path" <<'EOF'
{
  "version": 1,
  "hooks": {
    "preToolUse": [
      {
        "command": ".agents/hooks/pre-tool-shell-policy.sh",
        "matcher": "Shell"
      },
      {
        "command": "user-hook.sh",
        "matcher": "Shell"
      }
    ]
  }
}
EOF
      ;;
  esac
}

install_owned_hooks() {
  local runtime="$1" dir source_dir
  dir="$(runtime_dir "$runtime")"
  case "$runtime" in
    opencode)
      mkdir -p "$dir/plugins"
      cp "$(opencode_plugin_source)" "$dir/plugins/ralph-runtime-hooks.ts"
      ;;
    *)
      source_dir="$(bundle_hooks_dir "$runtime")"
      mkdir -p "$dir/hooks"
      cp "$source_dir"/* "$dir/hooks/"
      ;;
  esac
}

run_remove() {
  local runtime="$1"
  shift
  bash "$SETUP_RUNTIME_SH" \
    --runtime "$runtime" \
    --runtime-dir "$(runtime_dir "$runtime")" \
    --yes \
    "$@"
}

@test "clean MCP removal drops only the reserved ralph id for Codex, OpenCode, and Antigravity" {
  local runtime path
  for runtime in codex opencode antigravity; do
    write_clean_mcp "$runtime"
    mkdir -p "$(runtime_dir "$runtime")"
    path="$(mcp_path "$runtime")"
    run run_remove "$runtime" --remove --mcp
    [ "$status" -eq 0 ]
    ! grep -q 'ralph' "$path"
  done
}

@test "mixed MCP removal preserves native entries, comments, and unrelated files" {
  local runtime dir path
  for runtime in codex opencode antigravity; do
    dir="$(runtime_dir "$runtime")"
    mkdir -p "$dir"
    write_mixed_mcp "$runtime"
    printf 'unrelated native configuration\n' >"$dir/native.conf"
    cp "$dir/native.conf" "$dir/native.conf.bak"
    path="$(mcp_path "$runtime")"
    run run_remove "$runtime" --remove --mcp
    [ "$status" -eq 0 ]
    cmp -s "$dir/native.conf" "$dir/native.conf.bak"
    ! grep -Eq 'mcp_servers\.ralph|"ralph"' "$path"
    grep -q 'native' "$path"
    grep -q 'keep' "$path"
    if [[ "$runtime" == opencode || "$runtime" == codex ]]; then
      grep -q 'keep this comment' "$path"
    fi
  done
}

@test "MCP config with no Ralph entry is preserved byte-for-byte including JSONC" {
  local runtime path before
  for runtime in codex opencode antigravity; do
    mkdir -p "$(runtime_dir "$runtime")"
    write_unrelated_mcp "$runtime"
    path="$(mcp_path "$runtime")"
    before="$(cksum "$path")"
    run run_remove "$runtime" --remove --mcp
    [ "$status" -eq 0 ]
    [ "$(cksum "$path")" = "$before" ]
  done
}

@test "OpenCode JSONC sibling keeps comments while dropping ralph" {
  local path="$PROJECT/opencode.jsonc"
  mkdir -p "$(runtime_dir opencode)"
  cat >"$path" <<'EOF'
{
  /* header comment */
  "mcp": {
    "ralph": { "type": "local" },
    "native": { "command": ["stay"] }
  }
}
EOF
  run run_remove opencode --remove --mcp
  [ "$status" -eq 0 ]
  grep -q 'header comment' "$path"
  grep -q 'native' "$path"
  ! grep -q '"ralph"' "$path"
}

@test "clean owned hook removal deletes byte-identical files for all three runtimes" {
  local runtime dir source_dir file plugin
  for runtime in codex opencode antigravity; do
    dir="$(runtime_dir "$runtime")"
    install_owned_hooks "$runtime"
    run run_remove "$runtime" --remove --hooks
    [ "$status" -eq 0 ]
    if [[ "$runtime" == opencode ]]; then
      plugin="$dir/plugins/ralph-runtime-hooks.ts"
      [ ! -e "$plugin" ]
    else
      source_dir="$(bundle_hooks_dir "$runtime")"
      for file in "$source_dir"/*; do
        [ ! -e "$dir/hooks/$(basename "$file")" ]
      done
    fi
  done
}

@test "mixed hook JSON keeps unrelated matchers and commands" {
  local runtime path
  for runtime in codex antigravity; do
    mkdir -p "$(runtime_dir "$runtime")/hooks"
    write_mixed_hooks_json "$runtime"
    path="$(hooks_config_path "$runtime")"
    run run_remove "$runtime" --remove --hooks
    [ "$status" -eq 0 ]
    grep -q 'user-hook.sh' "$path"
    if [[ "$runtime" == codex ]]; then
      grep -q 'keep-me.sh' "$path"
      ! grep -q 'pre-tool-bash-policy.sh' "$path"
    else
      ! grep -q 'pre-tool-shell-policy.sh' "$path"
    fi
  done
}

@test "modified Ralph-owned hook file is refused and left in place" {
  local runtime dir target file
  for runtime in codex opencode antigravity; do
    dir="$(runtime_dir "$runtime")"
    install_owned_hooks "$runtime"
    if [[ "$runtime" == opencode ]]; then
      target="$dir/plugins/ralph-runtime-hooks.ts"
    else
      target=""
      for file in "$dir/hooks"/*; do
        target="$file"
        break
      done
    fi
    [ -n "$target" ]
    printf '\nmodified\n' >>"$target"
    run run_remove "$runtime" --remove --hooks
    [ "$status" -ne 0 ]
    [[ "$output" == *"$target"* ]]
    [ -f "$target" ]
  done
}

@test "dry-run prints discovery and mutates neither files nor journal" {
  local runtime dir path before_mcp before_native
  for runtime in codex opencode antigravity; do
    dir="$(runtime_dir "$runtime")"
    mkdir -p "$dir"
    write_mixed_mcp "$runtime"
    printf 'stay\n' >"$dir/native.conf"
    path="$(mcp_path "$runtime")"
    before_mcp="$(cksum "$path")"
    before_native="$(cksum "$dir/native.conf")"
    run run_remove "$runtime" --remove --mcp --dry-run
    [ "$status" -eq 0 ]
    [[ "$output" == *"DRY-RUN"* ]]
    [[ "$output" == *"does not create a setup journal"* ]]
    [ "$(cksum "$path")" = "$before_mcp" ]
    [ "$(cksum "$dir/native.conf")" = "$before_native" ]
    [ ! -d "$PROJECT/.ralph-workspace/setup-journal" ]
    grep -q 'ralph' "$path"
  done
}

@test "repeated MCP removal is a successful no-op for all three runtimes" {
  local runtime path
  for runtime in codex opencode antigravity; do
    mkdir -p "$(runtime_dir "$runtime")"
    write_mixed_mcp "$runtime"
    path="$(mcp_path "$runtime")"
    run run_remove "$runtime" --remove --mcp
    [ "$status" -eq 0 ]
    ! grep -Eq 'mcp_servers\.ralph|"ralph"' "$path"
    run run_remove "$runtime" --remove --mcp
    [ "$status" -eq 0 ]
    ! grep -Eq 'mcp_servers\.ralph|"ralph"' "$path"
    grep -q 'native' "$path"
  done
}

@test "failed later MCP removal restores journaled hook mutations" {
  local runtime dir plugin source_dir file restored
  for runtime in codex opencode antigravity; do
    dir="$(runtime_dir "$runtime")"
    install_owned_hooks "$runtime"
    mkdir -p "$dir"
    printf 'not-valid-config {{{\n' >"$(mcp_path "$runtime")"
    run run_remove "$runtime" --remove --all
    [ "$status" -ne 0 ]
    if [[ "$runtime" == opencode ]]; then
      plugin="$dir/plugins/ralph-runtime-hooks.ts"
      [ -f "$plugin" ]
      cmp -s "$(opencode_plugin_source)" "$plugin"
    else
      source_dir="$(bundle_hooks_dir "$runtime")"
      for file in "$source_dir"/*; do
        restored="$dir/hooks/$(basename "$file")"
        [ -f "$restored" ]
        cmp -s "$file" "$restored"
      done
    fi
  done
}
