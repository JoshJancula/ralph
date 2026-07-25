#!/usr/bin/env bash
#
# Durable MCP setup for Claude, Cursor, Codex, OpenCode, and Antigravity runtimes.
#
# Public interface:
#   setup_mcp_for_runtime <runtime> <runtime_dir> <project_root>
#   setup_mcp_cursor <runtime_dir> <project_root>
#   setup_mcp_claude <runtime_dir> <project_root>
#   setup_mcp_codex <runtime_dir> <project_root>
#   setup_mcp_opencode <runtime_dir> <project_root>
#   setup_mcp_antigravity <runtime_dir> <project_root>
#   setup_mcp_build_mota_fragment <runtime> <project_root>

set -euo pipefail

if [[ -n "${RALPH_SETUP_MCP_LOADED:-}" ]]; then
  return 0
fi
RALPH_SETUP_MCP_LOADED=1

if ! declare -F ralph_normalize_runtime_name >/dev/null 2>&1; then
  # shellcheck source=/dev/null
  source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/bash-lib/runtime-normalize.sh"
fi

SETUP_MCP_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RALPH_SETUP_MCP_ROOT="$(cd "$SETUP_MCP_LIB_DIR/../.." && pwd)"

setup_mcp_python_script() {
  local script_name="$1"
  printf '%s/python/%s' "$RALPH_SETUP_MCP_ROOT" "$script_name"
}

setup_mcp_require_jq() {
  if ! command -v jq &>/dev/null; then
    printf 'Error: jq is required for durable MCP setup\n' >&2
    return 1
  fi
  return 0
}

setup_mcp_validate_existing_json() {
  local file="$1"
  local label="$2"

  if [[ ! -f "$file" ]]; then
    return 0
  fi

  if ! setup_validate_json "$file"; then
    printf 'Error: existing %s is invalid JSON: %s\n' "$label" "$file" >&2
    return 1
  fi

  return 0
}

setup_mcp_require_python3() {
  if ! command -v python3 &>/dev/null; then
    printf 'Error: python3 is required for durable Codex MCP setup\n' >&2
    return 1
  fi
  return 0
}

setup_mcp_validate_existing_toml() {
  local file="$1"
  local label="$2"
  local merge_script=""

  if [[ ! -f "$file" ]]; then
    return 0
  fi

  if ! setup_mcp_require_python3; then
    return 1
  fi

  merge_script="$(setup_mcp_python_script setup-merge-codex-mcp.py)"
  if [[ ! -f "$merge_script" ]]; then
    printf 'Error: Codex MCP merge script missing at %s\n' "$merge_script" >&2
    return 1
  fi

  if ! python3 -c 'import tomllib' 2>/dev/null; then
    printf 'Error: Python 3.11+ is required to validate Codex MCP config TOML\n' >&2
    return 1
  fi

  if ! python3 -c '
import sys
import tomllib
path = sys.argv[1]
with open(path, "rb") as fh:
    tomllib.load(fh)
' "$file" 2>/dev/null; then
    printf 'Error: existing %s is invalid TOML: %s\n' "$label" "$file" >&2
    return 1
  fi

  return 0
}

setup_mcp_build_env_json() {
  local project_root="$1"

  jq -n \
    --arg ws "$project_root" \
    '{
      RALPH_MCP_WORKSPACE: $ws,
      RALPH_MODE: "hybrid"
    }'
}

setup_mcp_build_ralph_fragment() {
  local runtime="$1"
  local project_root="$2"
  local server_script="$3"
  local env_json

  runtime="$(ralph_normalize_runtime_name "$runtime")"

  env_json="$(setup_mcp_build_env_json "$project_root")"

  case "$runtime" in
    cursor)
      jq -n \
        --arg cmd "bash" \
        --arg arg1 "$server_script" \
        --argjson env "$env_json" \
        '{
          mcpServers: {
            ralph: {
              type: "stdio",
              command: $cmd,
              args: [$arg1],
              env: $env
            }
          }
        }'
      ;;
    claude)
      jq -n \
        --arg cmd "bash" \
        --arg arg1 "$server_script" \
        --argjson env "$env_json" \
        '{
          mcpServers: {
            ralph: {
              command: $cmd,
              args: [$arg1],
              env: $env
            }
          }
        }'
      ;;
    opencode)
      jq -n \
        --arg arg1 "$server_script" \
        --argjson env "$env_json" \
        '{
          mcp: {
            ralph: {
              type: "local",
              command: ["bash", $arg1],
              enabled: true,
              environment: $env
            }
          }
        }'
      ;;
    antigravity)
      jq -n \
        --arg cmd "bash" \
        --arg arg1 "$server_script" \
        --argjson env "$env_json" \
        '{
          mcpServers: {
            ralph: {
              type: "stdio",
              command: $cmd,
              args: [$arg1],
              env: $env
            }
          }
        }'
      ;;
    *)
      printf 'Error: unsupported runtime %s for durable MCP setup\n' "$runtime" >&2
      return 1
      ;;
  esac
}

setup_mcp_build_mota_fragment() {
  local runtime="$1"
  local project_root="$2"
  local api_base_url="${MOTA_API_URL:-}"

  runtime="$(ralph_normalize_runtime_name "$runtime")"

  if ! command -v mota &>/dev/null; then
    printf 'Warning: mota command not found; skipping mota MCP server registration.\n' >&2
    printf '{}'
    return 0
  fi

  printf 'mota MCP server registered; export MOTA_ORG_MCP_KEY (or MOTA_BOT_TOKEN) in the environment that launches your coding agent.\n' >&2

  case "$runtime" in
    cursor|claude|antigravity)
      if [[ -n "$api_base_url" ]]; then
        jq -n \
          --arg api_base_url "$api_base_url" \
          '{
            mcpServers: {
              mota: (
                {
                  type: "stdio",
                  command: "mota",
                  args: ["mcp", "serve"]
                } + {env: {MOTA_API_URL: $api_base_url}}
              )
            }
          }'
      else
        jq -n \
          '{
            mcpServers: {
              mota: {
                type: "stdio",
                command: "mota",
                args: ["mcp", "serve"]
              }
            }
          }'
      fi
      ;;
    opencode)
      if [[ -n "$api_base_url" ]]; then
        jq -n \
          --arg api_base_url "$api_base_url" \
          '{
            mcp: {
              mota: (
                {
                  type: "local",
                  command: ["mota", "mcp", "serve"],
                  enabled: true
                } + {environment: {MOTA_API_URL: $api_base_url}}
              )
            }
          }'
      else
        jq -n \
          '{
            mcp: {
              mota: {
                type: "local",
                command: ["mota", "mcp", "serve"],
                enabled: true
              }
            }
          }'
      fi
      ;;
    codex)
      if [[ -n "$api_base_url" ]]; then
        jq -n \
          --arg api_base_url "$api_base_url" \
          '{
            mcp_servers: {
              mota: {
                command: "mota",
                args: ["mcp", "serve"],
                env: {MOTA_API_URL: $api_base_url}
              }
            }
          }'
      else
        jq -n \
          '{
            mcp_servers: {
              mota: {
                command: "mota",
                args: ["mcp", "serve"]
              }
            }
          }'
      fi
      ;;
    *)
      printf 'Error: unsupported runtime %s for durable MCP setup\n' "$runtime" >&2
      return 1
      ;;
  esac
}

setup_mcp_write_merged_config() {
  local target="$1"
  local fragment_json="$2"
  local label="$3"
  local tmpfile=""

  if [[ -n "${SETUP_DRY_RUN:-}" ]]; then
    setup_merge_status merge "$target"
    return 0
  fi

  tmpfile="$(mktemp "${TMPDIR:-/tmp}/ralph-setup-mcp-XXXXXX")"
  # shellcheck disable=SC2064
  trap "rm -f '$tmpfile'" RETURN

  if [[ -f "$target" ]]; then
    if ! jq --argjson ralph "$fragment_json" \
      '.mcpServers = ((.mcpServers // {}) + $ralph.mcpServers)' \
      "$target" >"$tmpfile" 2>/dev/null; then
      printf 'Error: failed to merge %s into %s\n' "$label" "$target" >&2
      return 1
    fi
  else
    printf '%s\n' "$fragment_json" >"$tmpfile"
  fi

  if ! setup_atomic_write_file "$tmpfile" "$target"; then
    return 1
  fi

  trap - RETURN
  rm -f "$tmpfile"
  return 0
}

setup_mcp_write_merged_opencode_config() {
  local target="$1"
  local fragment_json="$2"
  local label="$3"
  local tmpfile=""

  if [[ -n "${SETUP_DRY_RUN:-}" ]]; then
    setup_merge_status merge "$target"
    return 0
  fi

  tmpfile="$(mktemp "${TMPDIR:-/tmp}/ralph-setup-mcp-XXXXXX")"
  # shellcheck disable=SC2064
  trap "rm -f '$tmpfile'" RETURN

  if [[ -f "$target" ]]; then
    if ! jq --argjson ralph "$fragment_json" \
      '.mcp = ((.mcp // {}) + $ralph.mcp)' \
      "$target" >"$tmpfile" 2>/dev/null; then
      printf 'Error: failed to merge %s into %s\n' "$label" "$target" >&2
      return 1
    fi
  else
    printf '%s\n' "$fragment_json" >"$tmpfile"
  fi

  if ! setup_atomic_write_file "$tmpfile" "$target"; then
    return 1
  fi

  trap - RETURN
  rm -f "$tmpfile"
  return 0
}

setup_mcp_write_merged_codex_config() {
  local target="$1"
  local server_script="$2"
  local project_root="$3"
  local mota_fragment_json="${4:-}"
  local merge_script tmpfile source_arg=""

  if [[ -n "${SETUP_DRY_RUN:-}" ]]; then
    setup_merge_status merge "$target"
    return 0
  fi

  if ! setup_mcp_require_python3; then
    return 1
  fi

  merge_script="$(setup_mcp_python_script setup-merge-codex-mcp.py)"
  if [[ ! -f "$merge_script" ]]; then
    printf 'Error: Codex MCP merge script missing at %s\n' "$merge_script" >&2
    return 1
  fi

  tmpfile="$(mktemp "${TMPDIR:-/tmp}/ralph-setup-mcp-XXXXXX")"
  # shellcheck disable=SC2064
  trap "rm -f '$tmpfile'" RETURN

  if [[ -f "$target" ]]; then
    source_arg="$target"
  else
    source_arg="-"
  fi

  if [[ -n "$mota_fragment_json" ]]; then
    if ! python3 "$merge_script" "$source_arg" "$tmpfile" "$server_script" "$project_root" "$mota_fragment_json"; then
      rm -f "$tmpfile"
      return 1
    fi
  elif ! python3 "$merge_script" "$source_arg" "$tmpfile" "$server_script" "$project_root"; then
    rm -f "$tmpfile"
    return 1
  fi

  if ! setup_atomic_write_file "$tmpfile" "$target"; then
    return 1
  fi

  trap - RETURN
  rm -f "$tmpfile"
  return 0
}

setup_mcp_cursor() {
  local runtime_dir="$1"
  local project_root="$2"
  local target server_script fragment_json mota_fragment_json merged_fragment_json

  if ! setup_mcp_require_jq; then
    return 1
  fi

  target="$runtime_dir/mcp.json"

  if ! setup_mcp_validate_existing_json "$target" "Cursor MCP config"; then
    return 1
  fi

  if ! server_script="$(setup_resolve_mcp_server_path_for_project "$project_root")"; then
    return 1
  fi

  if ! fragment_json="$(setup_mcp_build_ralph_fragment cursor "$project_root" "$server_script")"; then
    return 1
  fi

  if ! mota_fragment_json="$(setup_mcp_build_mota_fragment cursor "$project_root")"; then
    return 1
  fi

  if ! merged_fragment_json="$(jq -n --argjson ralph "$fragment_json" --argjson mota "$mota_fragment_json" '{mcpServers: (($ralph.mcpServers // {}) + ($mota.mcpServers // {})) }')"; then
    printf 'Error: failed to combine cursor MCP fragments\n' >&2
    return 1
  fi

  setup_merge_status "Merge Cursor MCP config" "$target"
  setup_mcp_write_merged_config "$target" "$merged_fragment_json" "Cursor MCP config"
}

setup_mcp_claude() {
  local runtime_dir="$1"
  local project_root="$2"
  local target server_script fragment_json mota_fragment_json merged_fragment_json

  if ! setup_mcp_require_jq; then
    return 1
  fi

  target="$project_root/.mcp.json"

  if ! setup_mcp_validate_existing_json "$target" "Claude MCP config"; then
    return 1
  fi

  if ! server_script="$(setup_resolve_mcp_server_path_for_project "$project_root")"; then
    return 1
  fi

  if ! fragment_json="$(setup_mcp_build_ralph_fragment claude "$project_root" "$server_script")"; then
    return 1
  fi

  if ! mota_fragment_json="$(setup_mcp_build_mota_fragment claude "$project_root")"; then
    return 1
  fi

  if ! merged_fragment_json="$(jq -n --argjson ralph "$fragment_json" --argjson mota "$mota_fragment_json" '{mcpServers: (($ralph.mcpServers // {}) + ($mota.mcpServers // {})) }')"; then
    printf 'Error: failed to combine claude MCP fragments\n' >&2
    return 1
  fi

  setup_merge_status "Merge Claude MCP config" "$target"
  setup_mcp_write_merged_config "$target" "$merged_fragment_json" "Claude MCP config"
}

setup_mcp_codex() {
  local runtime_dir="$1"
  local project_root="$2"
  local target server_script mota_fragment_json

  target="$runtime_dir/config.toml"

  if ! setup_mcp_validate_existing_toml "$target" "Codex MCP config"; then
    return 1
  fi

  if ! server_script="$(setup_resolve_mcp_server_path_for_project "$project_root")"; then
    return 1
  fi

  if ! mota_fragment_json="$(setup_mcp_build_mota_fragment codex "$project_root")"; then
    return 1
  fi

  setup_merge_status "Merge Codex MCP config" "$target"
  setup_mcp_write_merged_codex_config "$target" "$server_script" "$project_root" "$mota_fragment_json"
}

setup_mcp_opencode() {
  local runtime_dir="$1"
  local project_root="$2"
  local target server_script fragment_json mota_fragment_json merged_fragment_json

  if ! setup_mcp_require_jq; then
    return 1
  fi

  target="$project_root/opencode.json"

  if ! setup_mcp_validate_existing_json "$target" "OpenCode MCP config"; then
    return 1
  fi

  if ! server_script="$(setup_resolve_mcp_server_path_for_project "$project_root")"; then
    return 1
  fi

  if ! fragment_json="$(setup_mcp_build_ralph_fragment opencode "$project_root" "$server_script")"; then
    return 1
  fi

  if ! mota_fragment_json="$(setup_mcp_build_mota_fragment opencode "$project_root")"; then
    return 1
  fi

  if ! merged_fragment_json="$(jq -n --argjson ralph "$fragment_json" --argjson mota "$mota_fragment_json" '{mcp: (($ralph.mcp // {}) + ($mota.mcp // {})) }')"; then
    printf 'Error: failed to combine opencode MCP fragments\n' >&2
    return 1
  fi

  setup_merge_status "Merge OpenCode MCP config" "$target"
  setup_mcp_write_merged_opencode_config "$target" "$merged_fragment_json" "OpenCode MCP config"
}

setup_mcp_antigravity() {
  local runtime_dir="$1"
  local project_root="$2"
  local target server_script fragment_json mota_fragment_json merged_fragment_json

  if ! setup_mcp_require_jq; then
    return 1
  fi

  # agy reads MCP servers from mcp_config.json (not mcp.json).
  target="$runtime_dir/mcp_config.json"

  if ! setup_mcp_validate_existing_json "$target" "Antigravity MCP config"; then
    return 1
  fi

  if ! server_script="$(setup_resolve_mcp_server_path_for_project "$project_root")"; then
    return 1
  fi

  if ! fragment_json="$(setup_mcp_build_ralph_fragment antigravity "$project_root" "$server_script")"; then
    return 1
  fi

  if ! mota_fragment_json="$(setup_mcp_build_mota_fragment antigravity "$project_root")"; then
    return 1
  fi

  if ! merged_fragment_json="$(jq -n --argjson ralph "$fragment_json" --argjson mota "$mota_fragment_json" '{mcpServers: (($ralph.mcpServers // {}) + ($mota.mcpServers // {})) }')"; then
    printf 'Error: failed to combine antigravity MCP fragments\n' >&2
    return 1
  fi

  setup_merge_status "Merge Antigravity MCP config" "$target"
  setup_mcp_write_merged_config "$target" "$merged_fragment_json" "Antigravity MCP config"
}

setup_mcp_for_runtime() {
  local runtime="$1"
  local runtime_dir="$2"
  local project_root="$3"

  runtime="$(ralph_normalize_runtime_name "$runtime")"

  case "$runtime" in
    cursor)
      setup_mcp_cursor "$runtime_dir" "$project_root"
      ;;
    claude)
      setup_mcp_claude "$runtime_dir" "$project_root"
      ;;
    codex)
      setup_mcp_codex "$runtime_dir" "$project_root"
      ;;
    opencode)
      setup_mcp_opencode "$runtime_dir" "$project_root"
      ;;
    antigravity)
      setup_mcp_antigravity "$runtime_dir" "$project_root"
      ;;
    *)
      printf 'Error: durable MCP setup is not implemented for runtime %s\n' "$runtime" >&2
      return 1
      ;;
  esac
}
