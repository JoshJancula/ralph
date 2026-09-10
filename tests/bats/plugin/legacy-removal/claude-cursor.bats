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
  printf '%s/.%s' "$PROJECT" "$1"
}

mcp_path() {
  case "$1" in
    claude) printf '%s/.mcp.json' "$PROJECT" ;;
    cursor) printf '%s/.cursor/mcp.json' "$PROJECT" ;;
  esac
}

hooks_config_path() {
  case "$1" in
    claude) printf '%s/.claude/settings.json' "$PROJECT" ;;
    cursor) printf '%s/.cursor/hooks.json' "$PROJECT" ;;
  esac
}

bundle_hooks_dir() {
  printf '%s/bundle/.%s/hooks' "$REPO_ROOT" "$1"
}

write_mixed_mcp() {
  local runtime="$1" path
  path="$(mcp_path "$runtime")"
  mkdir -p "$(dirname "$path")"
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
}

write_clean_mcp() {
  local runtime="$1" path
  path="$(mcp_path "$runtime")"
  mkdir -p "$(dirname "$path")"
  cat >"$path" <<'EOF'
{
  "mcpServers": {
    "ralph": {
      "command": "bash"
    }
  }
}
EOF
}

write_unrelated_mcp() {
  local runtime="$1" path
  path="$(mcp_path "$runtime")"
  mkdir -p "$(dirname "$path")"
  printf '{\n  "mcpServers": {\n    "native": {"command": "stay"}\n  }\n}\n' >"$path"
}

write_mixed_hooks_json() {
  local runtime="$1" path
  path="$(hooks_config_path "$runtime")"
  mkdir -p "$(dirname "$path")"
  case "$runtime" in
    claude)
      cat >"$path" <<'EOF'
{
  "permissions": {
    "allow": ["Bash"]
  },
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Read|Edit|MultiEdit|Glob|Grep|LS",
        "hooks": [
          {
            "type": "command",
            "command": ".claude/hooks/block-env-reads.sh"
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
    cursor)
      cat >"$path" <<'EOF'
{
  "version": 1,
  "hooks": {
    "preToolUse": [
      {
        "command": ".cursor/hooks/pre-tool-shell-policy.sh",
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
  source_dir="$(bundle_hooks_dir "$runtime")"
  mkdir -p "$dir/hooks"
  cp "$source_dir"/* "$dir/hooks/"
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

@test "clean MCP removal drops only the reserved ralph id for Claude and Cursor" {
  local runtime path
  for runtime in claude cursor; do
    write_clean_mcp "$runtime"
    mkdir -p "$(runtime_dir "$runtime")"
    path="$(mcp_path "$runtime")"
    run run_remove "$runtime" --remove --mcp
    [ "$status" -eq 0 ]
    ! grep -q '"ralph"' "$path"
  done
}

@test "mixed MCP removal preserves native entries and unrelated files byte-for-byte" {
  local runtime dir path
  for runtime in claude cursor; do
    dir="$(runtime_dir "$runtime")"
    mkdir -p "$dir"
    write_mixed_mcp "$runtime"
    printf 'unrelated native configuration\n' >"$dir/native.conf"
    cp "$dir/native.conf" "$dir/native.conf.bak"
    path="$(mcp_path "$runtime")"
    run run_remove "$runtime" --remove --mcp
    [ "$status" -eq 0 ]
    cmp -s "$dir/native.conf" "$dir/native.conf.bak"
    ! grep -q '"ralph"' "$path"
    grep -q '"native"' "$path"
    grep -q '"keep"' "$path"
  done
}

@test "MCP config with no Ralph entry is preserved byte-for-byte" {
  local runtime path before
  for runtime in claude cursor; do
    mkdir -p "$(runtime_dir "$runtime")"
    write_unrelated_mcp "$runtime"
    path="$(mcp_path "$runtime")"
    before="$(cksum "$path")"
    run run_remove "$runtime" --remove --mcp
    [ "$status" -eq 0 ]
    [ "$(cksum "$path")" = "$before" ]
  done
}

@test "clean hook script removal deletes byte-identical owned files for Claude and Cursor" {
  local runtime dir source_dir file
  for runtime in claude cursor; do
    dir="$(runtime_dir "$runtime")"
    source_dir="$(bundle_hooks_dir "$runtime")"
    install_owned_hooks "$runtime"
    run run_remove "$runtime" --remove --hooks
    [ "$status" -eq 0 ]
    for file in "$source_dir"/*; do
      [ ! -e "$dir/hooks/$(basename "$file")" ]
    done
  done
}

@test "mixed hook JSON keeps unrelated matchers and commands" {
  local runtime path
  for runtime in claude cursor; do
    mkdir -p "$(runtime_dir "$runtime")/hooks"
    write_mixed_hooks_json "$runtime"
    path="$(hooks_config_path "$runtime")"
    run run_remove "$runtime" --remove --hooks
    [ "$status" -eq 0 ]
    grep -q 'user-hook.sh' "$path"
    if [[ "$runtime" == claude ]]; then
      grep -q 'keep-me.sh' "$path"
      grep -q '"permissions"' "$path"
      ! grep -q 'block-env-reads.sh' "$path"
    else
      ! grep -q 'pre-tool-shell-policy.sh' "$path"
    fi
  done
}

@test "modified Ralph-owned hook file is refused and left in place" {
  local runtime dir target file
  for runtime in claude cursor; do
    dir="$(runtime_dir "$runtime")"
    install_owned_hooks "$runtime"
    target=""
    for file in "$dir/hooks"/*; do
      target="$file"
      break
    done
    [ -n "$target" ]
    printf '\nmodified\n' >>"$target"
    run run_remove "$runtime" --remove --hooks
    [ "$status" -ne 0 ]
    [[ "$output" == *"$target"* ]]
    [ -f "$target" ]
  done
}

@test "dry-run prints discovery and mutates neither Claude nor Cursor files" {
  local runtime dir path before_mcp before_native
  for runtime in claude cursor; do
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
    grep -q '"ralph"' "$path"
  done
}

@test "repeated MCP removal is a successful no-op for Claude and Cursor" {
  local runtime path
  for runtime in claude cursor; do
    mkdir -p "$(runtime_dir "$runtime")"
    write_mixed_mcp "$runtime"
    path="$(mcp_path "$runtime")"
    run run_remove "$runtime" --remove --mcp
    [ "$status" -eq 0 ]
    ! grep -q '"ralph"' "$path"
    run run_remove "$runtime" --remove --mcp
    [ "$status" -eq 0 ]
    ! grep -q '"ralph"' "$path"
    grep -q '"native"' "$path"
  done
}
