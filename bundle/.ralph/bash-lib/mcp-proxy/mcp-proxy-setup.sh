#!/usr/bin/env bash
# Shared helpers for proxy-mode runtime setup.
#
# Public interface:
#   ralph_mcp_proxy_server_script_path <workspace>
#     -- Print the resolved path to the Ralph MCP server script.
#   ralph_mcp_proxy_generate_config <runtime> <output_path> <workspace> [<server_script>]
#     -- Generate a runtime-specific ephemeral MCP config JSON.
#   ralph_mcp_proxy_cleanup_config <path>
#     -- Remove the ephemeral config file.
#   ralph_mcp_proxy_preflight [<server_script>] <workspace>
#     -- Spawn Ralph MCP server, send initialize + tools/list, verify handshake.
#        Prints "OK" on success; prints actionable failure text to stderr and returns 1 on failure.
#   ralph_mcp_proxy_runner_preflight <runtime> <workspace> <config_path>
#     -- Config generation plus Ralph MCP preflight before model execution.
#        Sets RALPH_MCP_PROXY_FAILED_STEP on failure; prints failure detail to stderr and returns 1.
#   ralph_mcp_proxy_print_remediation <runtime> <plan_path> <workspace> <failed_step> <detail> [runner flags...]
#     -- Operator-facing remediation with exact rerun examples (Ralph tools fixed or --no-ralph-tools).
#   ralph_mcp_proxy_start_background_server <server_script> <workspace> <pidfile> <logfile>
#     -- Launch Ralph MCP server in background using a FIFO so it stays alive.
#   ralph_mcp_proxy_stop_background_server <pidfile>
#     -- Stop a background server started by start_background_server.

if [[ -n "${RALPH_MCP_PROXY_SETUP_LOADED:-}" ]]; then
  return
fi
RALPH_MCP_PROXY_SETUP_LOADED=1

# Override to force a specific server script path.
RALPH_MCP_PROXY_SERVER_SCRIPT="${RALPH_MCP_PROXY_SERVER_SCRIPT:-}"

ralph_mcp_proxy_server_script_path() {
  local workspace="${1:-}"
  if [[ -n "${RALPH_MCP_PROXY_SERVER_SCRIPT:-}" ]]; then
    printf '%s\n' "$RALPH_MCP_PROXY_SERVER_SCRIPT"
    return 0
  fi
  if [[ -n "$workspace" && -f "$workspace/.ralph/mcp-server.sh" ]]; then
    printf '%s\n' "$workspace/.ralph/mcp-server.sh"
    return 0
  fi
  local script_dir
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/.."
  if [[ -f "$script_dir/mcp-server.sh" ]]; then
    printf '%s\n' "$script_dir/mcp-server.sh"
    return 0
  fi
  return 1
}

ralph_mcp_proxy_generate_config() {
  local runtime="${1:-}"
  local output_path="${2:-}"
  local workspace="${3:-}"
  local server_script="${4:-}"

  if [[ -z "$runtime" ]]; then
    echo "Error: runtime is required for ephemeral MCP config generation." >&2
    return 1
  fi
  if [[ -z "$output_path" ]]; then
    echo "Error: output path is required for ephemeral MCP config generation." >&2
    return 1
  fi
  if [[ -z "$workspace" ]]; then
    echo "Error: workspace is required for ephemeral MCP config generation." >&2
    return 1
  fi
  if [[ -z "$server_script" ]]; then
    if ! server_script="$(ralph_mcp_proxy_server_script_path "$workspace")"; then
      echo "Error: could not find Ralph MCP server script ($workspace/.ralph/mcp-server.sh). Set RALPH_MCP_PROXY_SERVER_SCRIPT or ensure the workspace has .ralph/mcp-server.sh." >&2
      return 1
    fi
  fi

  local config_dir
  config_dir="$(dirname "$output_path")"
  if [[ -e "$config_dir" && ! -d "$config_dir" ]]; then
    echo "Error: ephemeral config directory path exists but is not a directory: $config_dir" >&2
    return 1
  fi
  if ! mkdir -p "$config_dir" 2>/dev/null; then
    echo "Error: cannot create ephemeral config directory $config_dir" >&2
    return 1
  fi

  if ! command -v jq &>/dev/null; then
    echo "Error: jq is required for ephemeral MCP config generation." >&2
    return 1
  fi

  case "$runtime" in
    claude|cursor|codex)
      if ! jq -n \
        --arg cmd "bash" \
        --arg arg1 "$server_script" \
        --arg ws "$workspace" \
        '{
          mcpServers: {
            ralph: {
              command: $cmd,
              args: [$arg1],
              env: {
                RALPH_MCP_WORKSPACE: $ws
              }
            }
          }
        }' > "$output_path" 2>/dev/null; then
        echo "Error: failed to write ephemeral MCP config to $output_path" >&2
        return 1
      fi
      ;;
    opencode)
      # OpenCode uses a different config schema with "mcp" as top-level key and "command" as array
      if ! jq -n \
        --arg arg1 "$server_script" \
        --arg ws "$workspace" \
        '{
          mcp: {
            ralph: {
              type: "local",
              command: ["bash", $arg1],
              env: {
                RALPH_MCP_WORKSPACE: $ws
              }
            }
          }
        }' > "$output_path" 2>/dev/null; then
        echo "Error: failed to write ephemeral MCP config to $output_path" >&2
        return 1
      fi
      ;;
    *)
      echo "Error: unsupported runtime '$runtime' for ephemeral MCP config generation." >&2
      return 1
      ;;
  esac

  printf '%s\n' "$output_path"
  return 0
}

ralph_mcp_proxy_cleanup_config() {
  local path="${1:-}"
  if [[ -z "$path" ]]; then
    return 0
  fi
  if [[ -f "$path" ]]; then
    rm -f "$path" 2>/dev/null || true
  fi
}

ralph_mcp_proxy_preflight() {
  local server_script="${1:-}"
  local workspace="${2:-}"

  # Allow calling with one arg (workspace) or two (server_script workspace).
  if [[ -z "$workspace" && -n "$server_script" ]]; then
    workspace="$server_script"
    server_script=""
  fi

  if [[ -z "$workspace" ]]; then
    echo "Error: workspace is required for MCP proxy preflight." >&2
    return 1
  fi
  if [[ -z "$server_script" ]]; then
    if ! server_script="$(ralph_mcp_proxy_server_script_path "$workspace")"; then
      echo "Error: could not find Ralph MCP server script for preflight. Set RALPH_MCP_PROXY_SERVER_SCRIPT or ensure the workspace has .ralph/mcp-server.sh." >&2
      return 1
    fi
  fi
  if [[ ! -f "$server_script" ]]; then
    echo "Error: Ralph MCP server script not found: $server_script" >&2
    return 1
  fi

  local tmpdir
  tmpdir="$(mktemp -d)"
  local stdout_file="$tmpdir/stdout"
  local stderr_file="$tmpdir/stderr"

  local payload
  payload='{"jsonrpc":"2.0","id":1,"method":"initialize"}
{"jsonrpc":"2.0","id":2,"method":"tools/list"}
{"jsonrpc":"2.0","id":3,"method":"exit"}'

  local exit_code=0
  env RALPH_MCP_WORKSPACE="$workspace" bash "$server_script" > "$stdout_file" 2> "$stderr_file" <<< "$payload" || exit_code=$?

  if [[ "$exit_code" -ne 0 ]]; then
    rm -rf "$tmpdir"
    echo "Error: Ralph MCP server process exited with code $exit_code. Ensure jq is installed and the workspace is valid." >&2
    return 1
  fi

  if ! grep -q '"capabilities"' "$stdout_file" 2>/dev/null; then
    rm -rf "$tmpdir"
    echo "Error: MCP preflight initialize response missing capabilities. Server output did not contain expected handshake result." >&2
    return 1
  fi

  if ! grep -q '"tools"' "$stdout_file" 2>/dev/null; then
    rm -rf "$tmpdir"
    echo "Error: MCP preflight tools/list response missing tools array. Server may not have started correctly." >&2
    return 1
  fi

  # Parse tool names from tools/list response and detect the Claude-side namespace.
  # The server exposes tools as `ralph_proxy_*`; the Claude CLI prepends `mcp__<name>__`
  # where <name> is the server registration name ("ralph" in the generated MCP config).
  # Cache the namespace once per session so downstream code (allowedTools, prompts,
  # live preflight) can use it without re-running the handshake.
  if command -v python3 >/dev/null 2>&1 && command -v jq >/dev/null 2>&1; then
    local detected_tools detected_namespace
    detected_tools="$(python3 - "$stdout_file" <<'PY' 2>/dev/null
import sys, json
names = []
with open(sys.argv[1]) as fh:
    for line in fh:
        line = line.strip()
        if not line:
            continue
        try:
            d = json.loads(line)
            if isinstance(d.get("result"), dict) and isinstance(d["result"].get("tools"), list):
                names = [t.get("name", "") for t in d["result"]["tools"] if t.get("name", "")]
        except Exception:
            pass
print("\n".join(names))
PY
    )"
    # The server config always registers the server as "ralph", so the Claude-side
    # namespace is deterministically "mcp__ralph__". Prefer it when the tools list
    # contains at least one ralph_proxy_* tool; fall back to the direct name otherwise.
    if printf '%s\n' "$detected_tools" | grep -q "^ralph_proxy_"; then
      detected_namespace="mcp__ralph__"
    else
      detected_namespace=""
    fi
    export RALPH_MCP_TOOL_NAMESPACE="${detected_namespace}"
    export RALPH_MCP_DETECTED_TOOL_NAMES="${detected_tools}"
  fi

  rm -rf "$tmpdir"
  echo "OK"
  return 0
}

ralph_mcp_proxy_start_background_server() {
  local server_script="${1:-}"
  local workspace="${2:-}"
  local pidfile="${3:-}"
  local logfile="${4:-}"

  if [[ -z "$server_script" || -z "$workspace" || -z "$pidfile" || -z "$logfile" ]]; then
    echo "Error: server_script, workspace, pidfile, and logfile are required for background server start." >&2
    return 1
  fi

  local tmpdir
  tmpdir="$(mktemp -d)"
  local stdin_fifo="$tmpdir/stdin.fifo"
  if ! mkfifo "$stdin_fifo" 2>/dev/null; then
    echo "Error: cannot create stdin fifo for background MCP server." >&2
    rm -rf "$tmpdir"
    return 1
  fi

  # Start server reading from fifo (blocks until writer opens).
  env RALPH_MCP_WORKSPACE="$workspace" bash "$server_script" < "$stdin_fifo" > "$logfile" 2> "${logfile}.err" &
  local server_pid=$!

  # Start a sleeper process that keeps the write end open so the server does not see EOF.
  ( exec 3> "$stdin_fifo"; while true; do sleep 3600; done ) &
  local sleeper_pid=$!

  # Ensure pidfile directory exists.
  local pidfile_dir
  pidfile_dir="$(dirname "$pidfile")"
  mkdir -p "$pidfile_dir" 2>/dev/null || true

  printf '%s\n%s\n%s\n' "$server_pid" "$sleeper_pid" "$tmpdir" > "$pidfile"
  return 0
}

ralph_mcp_proxy_stop_background_server() {
  local pidfile="${1:-}"
  if [[ -z "$pidfile" || ! -f "$pidfile" ]]; then
    return 0
  fi

  local server_pid sleeper_pid tmpdir
  server_pid="$(sed -n '1p' "$pidfile")"
  sleeper_pid="$(sed -n '2p' "$pidfile")"
  tmpdir="$(sed -n '3p' "$pidfile")"

  kill "$sleeper_pid" 2>/dev/null || true
  kill "$server_pid" 2>/dev/null || true
  wait "$server_pid" 2>/dev/null || true
  rm -rf "$tmpdir"
  rm -f "$pidfile"
}

ralph_mcp_proxy_runner_preflight() {
  local runtime="${1:-}"
  local workspace="${2:-}"
  local config_path="${3:-}"
  local err=""
  local proxy_script=""

  export RALPH_MCP_PROXY_FAILED_STEP=""

  if [[ -z "$runtime" || -z "$workspace" || -z "$config_path" ]]; then
    RALPH_MCP_PROXY_FAILED_STEP="proxy_preflight_setup"
    echo "Error: runtime, workspace, and config_path are required for MCP proxy runner preflight." >&2
    return 1
  fi

  if ! err="$(ralph_mcp_proxy_generate_config "$runtime" "$config_path" "$workspace" 2>&1 >/dev/null)"; then
    RALPH_MCP_PROXY_FAILED_STEP="ephemeral_config_generation"
    printf '%s\n' "$err" >&2
    return 1
  fi

  if ! err="$(ralph_mcp_proxy_preflight "$workspace" 2>&1 >/dev/null)"; then
    RALPH_MCP_PROXY_FAILED_STEP="ralph_mcp_preflight"
    printf '%s\n' "$err" >&2
    return 1
  fi

  return 0
}

ralph_mcp_proxy_build_rerun_cmd() {
  local runtime="${1:-}"
  local plan_path="${2:-}"
  local workspace="${3:-}"
  local proxy_mode="${4:-legacy}"
  local non_interactive="${5:-0}"
  local plan_model="${6:-}"

  local cmd=".ralph/run-plan.sh --runtime $(printf '%q' "$runtime") --plan $(printf '%q' "$plan_path") --workspace $(printf '%q' "$workspace")"

  case "$proxy_mode" in
    proxy)
      cmd+=" --ralph-tools"
      ;;
    legacy)
      cmd+=" --no-ralph-tools"
      ;;
  esac

  if [[ "$non_interactive" == "1" ]]; then
    cmd+=" --non-interactive"
  fi
  if [[ -n "$plan_model" ]]; then
    cmd+=" --model $(printf '%q' "$plan_model")"
  fi

  printf '%s\n' "$cmd"
}

ralph_mcp_proxy_print_remediation() {
  local runtime="${1:-}"
  local plan_path="${2:-}"
  local workspace="${3:-}"
  local failed_step="${4:-unknown}"
  local detail="${5:-}"
  local non_interactive="${6:-0}"
  local plan_model="${7:-}"
  local retry_cmd disable_cmd

  retry_cmd="$(ralph_mcp_proxy_build_rerun_cmd "$runtime" "$plan_path" "$workspace" proxy "$non_interactive" "$plan_model")"
  disable_cmd="$(ralph_mcp_proxy_build_rerun_cmd "$runtime" "$plan_path" "$workspace" legacy "$non_interactive" "$plan_model")"

  echo "Ralph MCP tools preflight failed before model execution." >&2
  echo "  Runtime: ${runtime:-unknown}" >&2
  echo "  MCP mode: Ralph tools" >&2
  echo "  Failed step: ${failed_step}" >&2
  if [[ -n "$detail" ]]; then
    echo "  Detail: ${detail}" >&2
  fi
  echo "  Retry with Ralph tools after fixing connectivity:" >&2
  echo "    ${retry_cmd}" >&2
  echo "  Or disable Ralph tools:" >&2
  echo "    ${disable_cmd}" >&2
}

# Aliases without "proxy" prefix for consolidated naming
ralph_mcp_server_script_path() { ralph_mcp_proxy_server_script_path "$@"; }
ralph_mcp_generate_config() { ralph_mcp_proxy_generate_config "$@"; }
ralph_mcp_cleanup_config() { ralph_mcp_proxy_cleanup_config "$@"; }
ralph_mcp_preflight() { ralph_mcp_proxy_preflight "$@"; }
