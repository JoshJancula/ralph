#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bash-lib/help-render.sh
source "$script_dir/bash-lib/help-render.sh"
# shellcheck source=bash-lib/jev/jev-key-store.sh
source "$script_dir/bash-lib/jev/jev-key-store.sh"
# The client library is scaffold-only today; doctor guards each call with
# declare -F so it keeps reporting honest state as later TODOs land.
# shellcheck source=bash-lib/jev/jev-client.sh
source "$script_dir/bash-lib/jev/jev-client.sh"

jev_cli_usage() {
  cat <<'USAGE' | ralph_help_render
Usage: jev.sh <command> [args]
       jev.sh -h|--help

Manage the optional Jev (TypeSafe AI) adapter and its API key. Jev is off by
default and no RALPH_MODE value enables it. It cannot generate text; it only
answers registered narrow questions.

Commands:
  key set                  Store the API key. Prompts on a TTY with echo
                           disabled, or reads the key from stdin when piped.
                           Prefers the OS keychain and falls back to a 0600
                           plaintext file with a warning. The key is NEVER
                           accepted as a command-line argument.
    --command <cmd>        Store a credential command whose stdout is the key,
                           instead of a secret.
  key status               Print resolved source, location, and whether the
                           key is currently resolvable. Never prints the key.
  key clear                Remove every stored key backend. Confirms on a TTY
                           first.
  key test                 Make ONE minimal live request to verify the key.
                           Prints pass or fail plus the HTTP status class only.
                           Never prints the key. Explicitly user-invoked.
  mcp start                Run the Jev MCP server over stdio. Defaults the
                           workspace to the current directory and enables the
                           Jev surfaces for this process only.
  mcp status               Report whether the Jev MCP server would register,
                           and which question sets and tools it exposes.
  mcp config               Print the ralph-jev server entry for an MCP client
                           config. The API key is never emitted.
    --merge <file>         Write the entry into an existing config file
                           (for example .mcp.json) instead of printing it.
  usage                    Summarize recorded Jev API usage (calls, input and
                           output tokens, estimated cost) from usage.jsonl in
                           the Jev state directory.
    --format text|json     Output format (default text).
    --plan-key <key>       Only count calls made under one plan.
    --include-fixture      Also count offline fixture-transport calls.
  doctor                   Report RALPH_JEV state, key source, curl presence,
                           registry validity, breaker state, and whether the
                           MCP server would register.

Environment:
  RALPH_JEV              "1" enables Jev (default unset)
  RALPH_CONFIG_HOME       Override Ralph global config directory
  RALPH_JEV_ENDPOINT      Default https://api.typesafe.ai/v1/systemone
  RALPH_JEV_TIMEOUT_MS    Default 4000
  RALPH_JEV_MCP           "1" registers the ralph-jev MCP server
  RALPH_MCP_WORKSPACE     Workspace the MCP server answers for

Examples:
  printf '%s\n' "$KEY" | ralph jev key set
  ralph jev key set --command 'security find-generic-password -s my-service -w'
  ralph jev key status
  ralph jev doctor
  ralph jev mcp status
  ralph jev mcp config --merge .mcp.json
USAGE
}

jev_cli_require_jq() {
  if ! command -v jq >/dev/null 2>&1; then
    echo "Error: jq is required for the Jev CLI." >&2
    exit 2
  fi
}

jev_cli_key_set() {
  local mode="secret"
  local command_string=""
  local key=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      -h|--help)
        jev_cli_usage
        exit 0
        ;;
      --command)
        if [[ -z "${2:-}" ]]; then
          echo "Error: --command requires a command string." >&2
          exit 2
        fi
        mode="command"
        command_string="$2"
        shift 2
        ;;
      -*)
        echo "Error: unknown option for ralph jev key set: $1" >&2
        exit 2
        ;;
      *)
        # A positional here would be the key itself. It would land in the
        # process list and the user's shell history, so refuse it and point
        # at stdin or the hidden interactive prompt.
        echo "Error: never pass the key as a command-line argument." >&2
        echo "It would be visible in the process list and your shell history." >&2
        echo "Pipe the key via stdin or run 'ralph jev key set' interactively for a hidden prompt." >&2
        exit 2
        ;;
    esac
  done

  if [[ "$mode" == "command" ]]; then
    jev_key_set_command "$command_string"
    echo "Stored credential command. Run 'ralph jev key status' to confirm the new source."
    return 0
  fi

  if [[ -t 0 ]]; then
    printf 'Enter Jev (TypeSafe AI) key: ' >&2
    if ! read -r -s key </dev/tty; then
      printf '\nError: no key entered.\n' >&2
      exit 1
    fi
    printf '\n' >&2
  else
    key="$(cat)"
    key="${key%$'\n'}"
  fi

  if [[ -z "$key" ]]; then
    echo "Error: empty key." >&2
    exit 1
  fi

  if printf '%s\n' "$key" | jev_key_set_keychain 2>/dev/null; then
    echo "Stored the key in the OS keychain (service $JEV_KEYCHAIN_SERVICE)."
  else
    if ! printf '%s\n' "$key" | jev_key_set_file 2>/dev/null; then
      echo "Error: failed to store the key in any backend." >&2
      exit 1
    fi
    echo "Warning: no keychain backend was available, so the key is stored as PLAINTEXT on disk." >&2
    echo "Warning: plaintext key location: $(jev_key_store_file_path) (mode 600)." >&2
    echo "Prefer 'ralph jev key set --command <cmd>' or a keychain-backed machine." >&2
  fi
}

jev_cli_key_status() {
  if [[ $# -gt 0 ]]; then
    echo "Error: key status takes no arguments." >&2
    exit 2
  fi

  jev_key_status

  local resolved=""
  if resolved="$(jev_key_resolve 2>/dev/null)" && [[ -n "$resolved" ]]; then
    echo "resolvable: yes"
  else
    echo "resolvable: no"
  fi
}

jev_cli_key_clear() {
  if [[ $# -gt 0 ]]; then
    echo "Error: key clear takes no arguments." >&2
    exit 2
  fi

  if [[ -t 0 ]]; then
    local confirm=""
    printf 'Remove every stored Jev key backend? (y/N) '
    if ! read -r confirm </dev/tty; then
      printf '\nCancelled.\n' >&2
      exit 1
    fi
    if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
      echo "Cancelled." >&2
      exit 1
    fi
  fi

  jev_key_clear
  echo "Cleared every stored Jev key backend."
}

jev_cli_key_test() {
  if [[ $# -gt 0 ]]; then
    echo "Error: key test takes no arguments." >&2
    exit 2
  fi

  local key=""
  if ! key="$(jev_key_resolve 2>/dev/null)" || [[ -z "$key" ]]; then
    echo "fail (no key resolvable)"
    exit 1
  fi

  local endpoint="${RALPH_JEV_ENDPOINT:-https://api.typesafe.ai/v1/systemone}"
  local timeout_ms="${RALPH_JEV_TIMEOUT_MS:-4000}"
  case "$timeout_ms" in
    ''|*[!0-9]*) timeout_ms=4000 ;;
  esac
  local timeout_secs=$(( (timeout_ms + 999) / 1000 ))
  if [[ "$timeout_secs" -lt 1 ]]; then
    timeout_secs=1
  fi

  local body_file cfg_file out_file
  body_file="$(mktemp "${TMPDIR:-/tmp}/ralph-jev-keytest-body.XXXXXX")"
  cfg_file="$(mktemp "${TMPDIR:-/tmp}/ralph-jev-keytest-cfg.XXXXXX")"
  out_file="$(mktemp "${TMPDIR:-/tmp}/ralph-jev-keytest-out.XXXXXX")"

  if ! jq -nc --arg model "${RALPH_JEV_MODEL:-jev-latest}" \
      '{state: "ralph jev key test", model: $model,
        questions: {ok: {type: "noul", instructions: "Is this API key valid?"}}}' \
      >"$body_file"; then
    rm -f "$body_file" "$cfg_file" "$out_file"
    echo "Error: failed to build the test request." >&2
    exit 1
  fi

  # The key never reaches the process argument list: it travels through a
  # curl --config file written 0600 and removed on every path below.
  if ! ( umask 077
         printf 'header = "Authorization: Bearer %s"\n' "$key" >"$cfg_file" ); then
    rm -f "$body_file" "$cfg_file" "$out_file"
    echo "Error: failed to prepare the test request." >&2
    exit 1
  fi

  local http_code="000"
  http_code="$(curl -sS --max-time "$timeout_secs" --config "$cfg_file" \
    -X POST -H 'Content-Type: application/json' \
    --data-binary @"$body_file" -o "$out_file" -w '%{http_code}' \
    "$endpoint" 2>/dev/null)" || http_code="000"

  rm -f "$body_file" "$cfg_file" "$out_file"

  case "$http_code" in
    2*) echo "pass (HTTP 2xx)"; exit 0 ;;
    3*) echo "fail (HTTP 3xx)"; exit 1 ;;
    4*) echo "fail (HTTP 4xx)"; exit 1 ;;
    5*) echo "fail (HTTP 5xx)"; exit 1 ;;
    *) echo "fail (network error)"; exit 1 ;;
  esac
}

jev_cli_doctor() {
  if [[ $# -gt 0 ]]; then
    echo "Error: doctor takes no arguments." >&2
    exit 2
  fi

  if [[ -z "${RALPH_JEV:-}" ]]; then
    echo "ralph-jev: unset (Jev disabled; set RALPH_JEV=1 to enable)"
  elif [[ "${RALPH_JEV}" == "1" ]]; then
    echo "ralph-jev: 1 (enabled)"
  else
    echo "ralph-jev: '${RALPH_JEV}' (invalid; Jev requires RALPH_JEV=1)"
  fi

  jev_key_status

  local resolved=""
  local key_ok=0
  if resolved="$(jev_key_resolve 2>/dev/null)" && [[ -n "$resolved" ]]; then
    key_ok=1
    echo "key-resolvable: yes"
  else
    echo "key-resolvable: no"
  fi

  if command -v curl >/dev/null 2>&1; then
    echo "curl: present"
  elif [[ "${JEV_TRANSPORT:-https}" == "fixture" ]]; then
    echo "curl: absent (fixture transport active; curl not required)"
  else
    echo "curl: absent (required for live calls)"
  fi

  local registry="${RALPH_JEV_REGISTRY:-$script_dir/jev/questions.registry.json}"
  if [[ ! -f "$registry" ]]; then
    echo "registry: missing ($registry)"
  elif jq -e '.registryVersion == "1" and (.questionSets | type == "object") and (.questionSets | length >= 1)' \
      "$registry" >/dev/null 2>&1; then
    echo "registry: valid ($(jq -r '.questionSets | length' "$registry") question sets)"
  else
    echo "registry: invalid ($registry)"
  fi

  if declare -F jev_breaker_state >/dev/null 2>&1; then
    echo "breaker: $(jev_breaker_state 2>/dev/null || echo unknown)"
  else
    echo "breaker: unknown (jev-client.sh does not implement the breaker in this build)"
  fi

  local mcp_script
  mcp_script="$(jev_cli_mcp_server_script)"
  echo "mcp-server: ${mcp_script:-not found}"
  if [[ "${RALPH_JEV:-}" != "1" ]]; then
    echo "mcp-register: no (RALPH_JEV is not 1)"
  elif [[ "${RALPH_JEV_MCP:-}" != "1" ]]; then
    echo "mcp-register: no (RALPH_JEV_MCP is not 1)"
  elif [[ "$key_ok" -ne 1 ]]; then
    echo "mcp-register: no (no resolvable key)"
  elif [[ -z "$mcp_script" ]]; then
    echo "mcp-register: no (jev-mcp-server.sh not found)"
  else
    echo "mcp-register: yes (RALPH_JEV=1, RALPH_JEV_MCP=1, key resolvable, server present)"
  fi
}

# Resolve the Jev MCP server script. Empty stdout when this build has none.
jev_cli_mcp_server_script() {
  if [[ -n "${RALPH_JEV_MCP_SERVER_SCRIPT:-}" && -f "${RALPH_JEV_MCP_SERVER_SCRIPT}" ]]; then
    printf '%s\n' "$RALPH_JEV_MCP_SERVER_SCRIPT"
    return 0
  fi
  if [[ -f "$script_dir/jev-mcp-server.sh" ]]; then
    printf '%s\n' "$script_dir/jev-mcp-server.sh"
    return 0
  fi
  return 1
}

# ralph jev mcp start -- run the Jev MCP server over stdio.
# Mirrors "ralph mcp start": defaults the workspace to the current directory and
# turns the Jev surfaces on for this process only. Explicit invocation is itself
# the opt-in, so RALPH_JEV / RALPH_JEV_MCP default to 1 here rather than off.
jev_cli_mcp_start() {
  local mcp_script
  if ! mcp_script="$(jev_cli_mcp_server_script)"; then
    echo "Error: jev-mcp-server.sh not found. Set RALPH_JEV_MCP_SERVER_SCRIPT." >&2
    exit 2
  fi
  export RALPH_MCP_WORKSPACE="${RALPH_MCP_WORKSPACE:-$PWD}"
  export RALPH_JEV="${RALPH_JEV:-1}"
  export RALPH_JEV_MCP="${RALPH_JEV_MCP:-1}"
  exec bash "$mcp_script" "$@"
}

# ralph jev mcp status -- would it register, and what does it expose?
jev_cli_mcp_status() {
  local mcp_script registry
  mcp_script="$(jev_cli_mcp_server_script)" || mcp_script=""
  echo "server: ${mcp_script:-not found}"
  echo "workspace: ${RALPH_MCP_WORKSPACE:-$PWD}"
  echo "RALPH_JEV: ${RALPH_JEV:-unset}"
  echo "RALPH_JEV_MCP: ${RALPH_JEV_MCP:-unset}"
  if [[ -n "${RALPH_JEV_MCP_DISABLE_REASON:-}" ]]; then
    echo "disabled-reason: $RALPH_JEV_MCP_DISABLE_REASON"
  fi
  if declare -F jev_key_resolve >/dev/null 2>&1 && jev_key_resolve >/dev/null 2>&1; then
    echo "key-resolvable: yes"
  else
    echo "key-resolvable: no"
  fi
  if declare -F jev_breaker_state >/dev/null 2>&1; then
    echo "breaker: $(jev_breaker_state 2>/dev/null || echo unknown)"
  fi
  registry="${RALPH_JEV_REGISTRY:-$script_dir/jev/questions.registry.json}"
  if [[ -f "$registry" ]]; then
    echo "question-sets: $(jq -r '.questionSets | keys | join(", ")' "$registry" 2>/dev/null || echo unknown)"
  fi
  if [[ -n "$mcp_script" ]]; then
    echo "tools: $(
      printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{}}' \
        | bash "$mcp_script" 2>/dev/null \
        | jq -r 'select(.id == 1) | .result.tools | map(.name) | join(", ")' 2>/dev/null \
        || echo unknown
    )"
  fi
}

# ralph jev mcp config -- print the server entry to add to an MCP client config.
# Emits only the "ralph-jev" object by default; --merge <file> writes it into an
# existing config. The API key is never emitted: the server resolves it itself.
jev_cli_mcp_config() {
  local mcp_script workspace entry merge_target=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --merge)
        merge_target="${2:-}"
        if [[ -z "$merge_target" ]]; then
          echo "Error: --merge requires a config file path." >&2
          exit 2
        fi
        shift 2
        ;;
      *)
        echo "Error: unknown ralph jev mcp config option: $1" >&2
        exit 2
        ;;
    esac
  done

  if ! mcp_script="$(jev_cli_mcp_server_script)"; then
    echo "Error: jev-mcp-server.sh not found. Set RALPH_JEV_MCP_SERVER_SCRIPT." >&2
    exit 2
  fi
  workspace="${RALPH_MCP_WORKSPACE:-$PWD}"
  entry="$(jq -n --arg script "$mcp_script" --arg ws "$workspace" '{
    "ralph-jev": {
      command: "bash",
      args: [$script],
      env: {
        RALPH_MCP_WORKSPACE: $ws,
        RALPH_JEV: "1",
        RALPH_JEV_MCP: "1"
      }
    }
  }')"

  if [[ -z "$merge_target" ]]; then
    jq -n --argjson entry "$entry" '{mcpServers: $entry}'
    return 0
  fi

  if [[ ! -f "$merge_target" ]]; then
    echo "Error: config file not found: $merge_target" >&2
    exit 2
  fi
  local tmp
  tmp="$(mktemp "${TMPDIR:-/tmp}/ralph-jev-mcp-config.XXXXXX")" || exit 2
  if ! jq --argjson entry "$entry" '.mcpServers = ((.mcpServers // {}) + $entry)' \
      "$merge_target" >"$tmp" 2>/dev/null; then
    rm -f "$tmp"
    echo "Error: could not merge into $merge_target (is it valid JSON?)" >&2
    exit 2
  fi
  cat "$tmp" >"$merge_target"
  rm -f "$tmp"
  echo "Registered ralph-jev in $merge_target"
}

cmd="${1:-}"
if [[ -z "$cmd" || "$cmd" == "-h" || "$cmd" == "--help" ]]; then
  jev_cli_usage
  [[ -z "$cmd" ]] && exit 2 || exit 0
fi
shift || true

jev_cli_require_jq

case "$cmd" in
  key)
    sub="${1:-}"
    if [[ -z "$sub" || "$sub" == "-h" || "$sub" == "--help" ]]; then
      jev_cli_usage
      [[ -z "$sub" ]] && exit 2 || exit 0
    fi
    shift
    case "$sub" in
      set)
        jev_cli_key_set "$@"
        ;;
      status)
        jev_cli_key_status "$@"
        ;;
      clear)
        jev_cli_key_clear "$@"
        ;;
      test)
        jev_cli_key_test "$@"
        ;;
      *)
        echo "Error: unknown ralph jev key subcommand: $sub" >&2
        jev_cli_usage >&2
        exit 2
        ;;
    esac
    ;;
  mcp)
    sub="${1:-}"
    if [[ -z "$sub" || "$sub" == "-h" || "$sub" == "--help" ]]; then
      jev_cli_usage
      [[ -z "$sub" ]] && exit 2 || exit 0
    fi
    shift
    case "$sub" in
      start)
        jev_cli_mcp_start "$@"
        ;;
      status)
        jev_cli_mcp_status "$@"
        ;;
      config)
        jev_cli_mcp_config "$@"
        ;;
      *)
        echo "Error: unknown ralph jev mcp subcommand: $sub" >&2
        jev_cli_usage >&2
        exit 2
        ;;
    esac
    ;;
  usage)
    if ! command -v python3 >/dev/null 2>&1; then
      echo "Error: python3 not found on PATH" >&2
      exit 1
    fi
    exec python3 "$script_dir/python/jev_usage.py" "$@"
    ;;
  doctor)
    jev_cli_doctor "$@"
    ;;
  *)
    echo "Error: unknown ralph jev command: $cmd" >&2
    jev_cli_usage >&2
    exit 2
    ;;
esac