#!/usr/bin/env bash
# Fail-closed runtime capabilities used by graph admission and preflight.
#
# A runtime may use more than one same-runtime slot only when every Ralph-owned
# configuration overlay is invocation-local (or the runtime project root is
# independently isolated). Snapshot/worktree agent workspaces do not satisfy
# that proof.
#
# graph_runtime_capabilities returns one compact JSON object for:
#   workspaceEnforcement, liveApprovals, sessionContinuation,
#   usageReliability, provenSandboxBoundary
# plus the existing overlay/parallel-safety fields. Discovery is static and
# fail-closed. An optional help-only CLI probe may enable liveApprovals; it
# never starts a session or sends a prompt.

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  echo "This file is meant to be sourced, not executed." >&2
  exit 1
fi

if [[ -n "${GRAPH_RUNTIME_CAPABILITIES_LOADED:-}" ]]; then
  return 0
fi
GRAPH_RUNTIME_CAPABILITIES_LOADED=1

GRAPH_RUNTIME_CAPABILITIES_SCHEMA_VERSION=1
GRAPH_RUNTIME_CAPABILITIES_KNOWN='antigravity
claude
codex
cursor
opencode'

graph_runtime_same_runtime_parallel_safe() {
  case "${1:-}" in
    # These adapters pass Ralph-owned MCP/config additions through a unique
    # temporary file or per-invocation CLI overrides. Ambient user/project
    # configuration is read, never rewritten.
    claude|codex|opencode|antigravity) return 0 ;;
    # Cursor currently installs and restores <project>/.cursor/mcp.json.
    # Node agent-workspace isolation does not isolate that project-root file.
    cursor|*) return 1 ;;
  esac
}

graph_runtime_same_runtime_parallel_safe_json() {
  if graph_runtime_same_runtime_parallel_safe "$1"; then
    printf 'true\n'
  else
    printf 'false\n'
  fi
}

graph_runtime_overlay_isolation() {
  case "${1:-}" in
    claude) printf 'temporary-cli-config\n' ;;
    codex) printf 'temporary-cli-overrides\n' ;;
    opencode) printf 'temporary-env-config\n' ;;
    antigravity) printf 'temporary-env-config\n' ;;
    cursor) printf 'project-root-overlay-journal\n' ;;
    *) printf 'unproven\n' ;;
  esac
}

# graph_runtime_normalize_runtime <runtime>
graph_runtime_normalize_runtime() {
  local s="${1-}"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s" | tr '[:upper:]' '[:lower:]' | tr '_' '-'
}

# graph_runtime_is_known_runtime <normalized-runtime>
graph_runtime_is_known_runtime() {
  local runtime="$1" candidate
  [[ -n "$runtime" ]] || return 1
  while IFS= read -r candidate; do
    [[ "$candidate" == "$runtime" ]] && return 0
  done <<< "$GRAPH_RUNTIME_CAPABILITIES_KNOWN"
  return 1
}

# graph_runtime_cli_name <normalized-runtime>
# Default CLI binary name. Never invoked by this helper.
graph_runtime_cli_name() {
  case "${1:-}" in
    claude) printf '%s\n' "${CLAUDE_PLAN_CLI:-claude}" ;;
    cursor) printf '%s\n' "${CURSOR_PLAN_CLI:-cursor-agent}" ;;
    codex) printf '%s\n' "${CODEX_PLAN_CLI:-${CODEX_CLI:-codex}}" ;;
    opencode) printf '%s\n' "${OPENCODE_PLAN_CLI:-${OPENCODE_CLI:-opencode}}" ;;
    antigravity) printf '%s\n' "${ANTIGRAVITY_PLAN_CLI:-agy}" ;;
    *) printf '\n' ;;
  esac
}

# graph_runtime_workspace_enforcement <normalized-runtime>
# True when Ralph can bind the runtime to an agent workspace (cwd or flag).
graph_runtime_workspace_enforcement() {
  graph_runtime_is_known_runtime "$1"
}

# graph_runtime_session_continuation <normalized-runtime>
# True when the invoke adapter can resume the same CLI session.
graph_runtime_session_continuation() {
  graph_runtime_is_known_runtime "$1"
}

# graph_runtime_usage_reliability <normalized-runtime>
# Prints authoritative, estimated, or unavailable. Fail-closed to unavailable.
graph_runtime_usage_reliability() {
  case "${1:-}" in
    claude|cursor|codex) printf 'authoritative\n' ;;
    opencode|antigravity) printf 'estimated\n' ;;
    *) printf 'unavailable\n' ;;
  esac
}

# graph_runtime_proven_sandbox_boundary <normalized-runtime>
# True only when Ralph already proves a native runtime sandbox (Codex --sandbox).
# Snapshot/worktree isolation is supervisor-owned and does not count.
graph_runtime_proven_sandbox_boundary() {
  [[ "${1:-}" == "codex" ]]
}

# --- Native-subagent off deny capability ------------------------------------
#
# nativeSubagents=off requires a proven runtime deny boundary (argv or config).
# Prompt-only suppression is never a deny. Fail-closed: unknown or unproven
# runtimes report "unsupported" until a per-runtime TODO proves a mechanism.
#
# graph_runtime_native_subagents_off_deny <normalized-runtime>
# Prints a stable deny mechanism id, or "unsupported".
graph_runtime_native_subagents_off_deny() {
  case "${1:-}" in
    # Proven by enforce-claude-native-subagents-off: --disallowedTools Agent.
    claude) printf 'disallowedTools-Agent\n' ;;
    # Cursor CLI has no tested Task/subagent deny argv or config boundary.
    cursor) printf 'unsupported\n' ;;
    # Proven by enforce-codex-native-subagents-off: --config agents.enabled=false.
    codex) printf 'config-agents.enabled=false\n' ;;
    # OpenCode has no Ralph-proven Task/subagent deny argv or config boundary
    # for headless `opencode run` (permission.task / V2 subagent deny remain unproven).
    opencode) printf 'unsupported\n' ;;
    # Antigravity (agy) has no Ralph-proven Task/subagent deny argv or config
    # boundary for headless `--print` (prompt-only suppression is not a deny).
    antigravity) printf 'unsupported\n' ;;
    *) printf 'unsupported\n' ;;
  esac
}

# graph_runtime_native_subagents_off_supported <normalized-runtime>
# True only when nativeSubagents=off can be enforced with a proven deny.
graph_runtime_native_subagents_off_supported() {
  local deny
  deny="$(graph_runtime_native_subagents_off_deny "${1:-}")"
  [[ -n "$deny" && "$deny" != "unsupported" ]]
}

# _graph_runtime_capabilities_help_argv <normalized-runtime>
# Prints the help-only argv (one flag or subcommand per line). Never a prompt.
_graph_runtime_capabilities_help_argv() {
  case "${1:-}" in
    claude|cursor|antigravity)
      printf '%s\n' --help
      ;;
    codex)
      printf '%s\n' app-server --help
      ;;
    opencode)
      printf '%s\n' serve --help
      ;;
    *)
      return 1
      ;;
  esac
}

# _graph_runtime_capabilities_help_proves_live <normalized-runtime> <help-text>
_graph_runtime_capabilities_help_proves_live() {
  local runtime="$1" help_text="$2"
  case "$runtime" in
    claude|cursor|antigravity)
      [[ "$help_text" == *"--permission-prompt-tool"* || "$help_text" == *"permission-prompt-tool"* ]]
      ;;
    codex)
      [[ "$help_text" == *"app-server"* || "$help_text" == *"initialize"* || "$help_text" == *"JSON-RPC"* || "$help_text" == *"json-rpc"* || "$help_text" == *"jsonrpc"* ]]
      ;;
    opencode)
      [[ "$help_text" == *"serve"* || "$help_text" == *"hostname"* || "$help_text" == *"--port"* || "$help_text" == *"/event"* || "$help_text" == *"SSE"* || "$help_text" == *"event stream"* ]]
      ;;
    *)
      return 1
      ;;
  esac
}

# graph_runtime_capabilities_probe_live <normalized-runtime> [cli]
# Help-only. Never starts a session, never sends a prompt, never reads a model
# response. Missing CLI, failed help, or unproven help text stay unsupported.
graph_runtime_capabilities_probe_live() {
  local runtime="$1" cli="${2:-}"
  local help_text
  local -a help_args=()

  [[ -n "$cli" ]] || return 1
  command -v "$cli" >/dev/null 2>&1 || return 1

  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    help_args+=("$line")
  done < <(_graph_runtime_capabilities_help_argv "$runtime") || return 1
  [[ ${#help_args[@]} -gt 0 ]] || return 1

  if ! help_text="$("$cli" "${help_args[@]}" 2>/dev/null)"; then
    return 1
  fi
  _graph_runtime_capabilities_help_proves_live "$runtime" "$help_text"
}

# graph_runtime_capabilities [runtime] [cli]
#
# Static matrix (no CLI invocation unless [cli] is passed or
# GRAPH_RUNTIME_CAPABILITIES_PROBE=1):
#   known runtimes: workspaceEnforcement and sessionContinuation true
#   usageReliability: authoritative (claude/cursor/codex), estimated
#     (opencode/antigravity), unavailable otherwise
#   provenSandboxBoundary: true only for Codex
#   liveApprovals: false unless a help-only probe proves a live channel
#   nativeSubagentsOff / nativeSubagentsOffDeny: proven deny or unsupported
#     (orthogonal to the boolean supported/unsupported partition above)
#
# [cli] or GRAPH_RUNTIME_CAPABILITIES_PROBE=1 runs help-only detection.
# A model call is never made.
graph_runtime_capabilities() {
  local runtime cli probe_cli=""
  local workspace live session sandbox parallel
  local usage isolation probe_attempted
  local probe_env="${GRAPH_RUNTIME_CAPABILITIES_PROBE:-}"

  runtime="$(graph_runtime_normalize_runtime "${1-}")"
  cli="${2-}"

  workspace=false
  live=false
  session=false
  sandbox=false
  parallel=false
  usage="unavailable"
  isolation="unproven"
  probe_attempted=false

  if graph_runtime_is_known_runtime "$runtime"; then
    workspace=true
    session=true
    usage="$(graph_runtime_usage_reliability "$runtime")"
    isolation="$(graph_runtime_overlay_isolation "$runtime")"
    if graph_runtime_same_runtime_parallel_safe "$runtime"; then
      parallel=true
    fi
    if graph_runtime_proven_sandbox_boundary "$runtime"; then
      sandbox=true
    fi
  else
    usage="$(graph_runtime_usage_reliability "$runtime")"
    isolation="$(graph_runtime_overlay_isolation "$runtime")"
  fi

  if [[ -n "$cli" ]]; then
    probe_cli="$cli"
  elif [[ "$probe_env" == "1" || "$probe_env" == "true" || "$probe_env" == "yes" || "$probe_env" == "on" ]]; then
    probe_cli="$(graph_runtime_cli_name "$runtime")"
  fi

  if [[ -n "$probe_cli" ]] && graph_runtime_is_known_runtime "$runtime"; then
    probe_attempted=true
    if graph_runtime_capabilities_probe_live "$runtime" "$probe_cli"; then
      live=true
    fi
  fi

  if ! command -v jq >/dev/null 2>&1; then
    echo "Error: jq is required for graph_runtime_capabilities" >&2
    return 1
  fi

  local native_off_deny native_off_supported
  native_off_deny="$(graph_runtime_native_subagents_off_deny "$runtime")"
  native_off_supported=false
  if graph_runtime_native_subagents_off_supported "$runtime"; then
    native_off_supported=true
  fi

  jq -nc \
    --arg runtime "$runtime" \
    --argjson schema "$GRAPH_RUNTIME_CAPABILITIES_SCHEMA_VERSION" \
    --argjson workspace "$workspace" \
    --argjson live "$live" \
    --argjson session "$session" \
    --arg usage "$usage" \
    --argjson sandbox "$sandbox" \
    --argjson parallel "$parallel" \
    --arg isolation "$isolation" \
    --argjson probed "$probe_attempted" \
    --argjson nativeOff "$native_off_supported" \
    --arg nativeOffDeny "$native_off_deny" \
    '{
      schemaVersion: $schema,
      runtime: $runtime,
      workspaceEnforcement: $workspace,
      liveApprovals: $live,
      sessionContinuation: $session,
      usageReliability: $usage,
      provenSandboxBoundary: $sandbox,
      sameRuntimeParallelSafe: $parallel,
      overlayIsolation: $isolation,
      nativeSubagentsOff: $nativeOff,
      nativeSubagentsOffDeny: $nativeOffDeny,
      probe: {
        attempted: $probed,
        modelCall: false
      }
    }
    | . as $doc
    | ($doc + {
        supported: (
          []
          + (if $doc.workspaceEnforcement then ["workspaceEnforcement"] else [] end)
          + (if $doc.liveApprovals then ["liveApprovals"] else [] end)
          + (if $doc.sessionContinuation then ["sessionContinuation"] else [] end)
          + (if $doc.provenSandboxBoundary then ["provenSandboxBoundary"] else [] end)
        ),
        unsupported: (
          []
          + (if $doc.workspaceEnforcement then [] else ["workspaceEnforcement"] end)
          + (if $doc.liveApprovals then [] else ["liveApprovals"] end)
          + (if $doc.sessionContinuation then [] else ["sessionContinuation"] end)
          + (if $doc.provenSandboxBoundary then [] else ["provenSandboxBoundary"] end)
        )
      })'
}

# --- Tooling-profile delivery contract -------------------------------------
#
# Tooling profiles (bundle/.ralph/tooling-profiles.json) set a fixed set of
# env keys per named profile. Not every runtime can actually deliver every
# key: some are wired through the universal Ralph MCP `ralph_proxy_shell`
# compactor, some through a runtime-registered native post-tool hook, and one
# is process-local orchestration metadata that does not depend on the
# runtime at all. This section reports, per normalized runtime, whether each
# key is deliverable and why/why not. Discovery is static (no CLI probing)
# and fail-closed: an unknown runtime or an unproven delivery path reports
# unsupported with a stable reason code, never a guess.
#
# Identity/telemetry keys RALPH_TOOLING_PROFILE and
# RALPH_TOOLING_PROFILE_DEGRADED are always process-local metadata set by the
# runner itself; they are not part of this capability gate.

GRAPH_RUNTIME_TOOLING_PROFILE_KEYS='RALPH_MODE
RALPH_PROXY_SHELL_COMPACT
RALPH_COMPACT_GENERIC_FALLBACK
RALPH_COMPACT_GENERIC_THRESHOLD_BYTES
RALPH_NATIVE_RESULT_COMPACT'

# _graph_runtime_tooling_profile_universal_mcp_shell_supported <normalized-runtime>
# RALPH_PROXY_SHELL_COMPACT, RALPH_COMPACT_GENERIC_FALLBACK, and
# RALPH_COMPACT_GENERIC_THRESHOLD_BYTES all gate the shared shell-output
# compactor behind `ralph_proxy_shell`. Delivery matches the "Universal
# (MCP)" row of the shell output compaction runtime matrix in
# bundle/.ralph/docs/ENVIRONMENT.md (PLAN49 outcome): Claude, Cursor, Codex,
# OpenCode. Antigravity is not listed in that row, so it fails closed here
# rather than being inferred from the runtime name.
_graph_runtime_tooling_profile_universal_mcp_shell_supported() {
  case "${1:-}" in
    claude|cursor|codex|opencode) return 0 ;;
    *) return 1 ;;
  esac
}

# _graph_runtime_tooling_profile_native_result_compact_supported <normalized-runtime>
# RALPH_NATIVE_RESULT_COMPACT gates a runtime-registered native post-tool
# hook (bundle/.ralph/bash-lib/native-hook/post-tool-native-result-compact-hook.sh)
# that is wired into each runtime's own hooks.json/hooks config: Claude
# (native-result-compact.sh), Cursor, Codex, and Antigravity all register the
# hook directly. OpenCode's equivalent path is a headless plugin invocation
# whose out-of-session hook execution is unproven (matching the same
# unproven-headless caveat already documented for OpenCode's shell
# compaction layer), so it fails closed here.
_graph_runtime_tooling_profile_native_result_compact_supported() {
  case "${1:-}" in
    claude|cursor|codex|antigravity) return 0 ;;
    *) return 1 ;;
  esac
}

# _graph_runtime_tooling_profile_key_mechanism <normalized-runtime> <key>
# Prints "true|<mechanism>" when the runtime can deliver the key, or
# "false|<reason-code>" when it cannot. The reason code is always present,
# supported or not, so callers can surface it either way.
_graph_runtime_tooling_profile_key_mechanism() {
  local runtime="${1:-}" key="${2:-}"

  if ! graph_runtime_is_known_runtime "$runtime"; then
    printf 'false|unknown-runtime\n'
    return 0
  fi

  case "$key" in
    RALPH_MODE)
      # Process-local orchestration switch selected by the plan runner
      # before invoking any runtime CLI. Every known runtime is launched
      # through that same runner path, so this key is never runtime-gated.
      printf 'true|process-local-mode-switch\n'
      ;;
    RALPH_PROXY_SHELL_COMPACT|RALPH_COMPACT_GENERIC_FALLBACK|RALPH_COMPACT_GENERIC_THRESHOLD_BYTES)
      if _graph_runtime_tooling_profile_universal_mcp_shell_supported "$runtime"; then
        printf 'true|universal-mcp-proxy-shell-compactor\n'
      else
        printf 'false|not-in-plan49-universal-mcp-matrix\n'
      fi
      ;;
    RALPH_NATIVE_RESULT_COMPACT)
      if _graph_runtime_tooling_profile_native_result_compact_supported "$runtime"; then
        printf 'true|native-post-tool-result-hook-registered\n'
      else
        printf 'false|opencode-headless-hook-invocation-unproven\n'
      fi
      ;;
    *)
      printf 'false|unknown-tooling-profile-key\n'
      ;;
  esac
}

# graph_runtime_tooling_profile_capabilities [runtime]
#
# Static, fail-closed tooling-profile delivery contract for one normalized
# runtime. Reports, for every key in GRAPH_RUNTIME_TOOLING_PROFILE_KEYS,
# whether the runtime can deliver it plus a stable reason code, and rolls
# those up into supportedKeys/unsupportedKeys. Never invokes a CLI; the
# result is deterministic for a frozen graph.
graph_runtime_tooling_profile_capabilities() {
  local runtime
  runtime="$(graph_runtime_normalize_runtime "${1-}")"

  if ! command -v jq >/dev/null 2>&1; then
    echo "Error: jq is required for graph_runtime_tooling_profile_capabilities" >&2
    return 1
  fi

  local key entry supported reason
  local keys_json="{}"

  while IFS= read -r key; do
    [[ -n "$key" ]] || continue
    entry="$(_graph_runtime_tooling_profile_key_mechanism "$runtime" "$key")"
    supported="${entry%%|*}"
    reason="${entry#*|}"
    keys_json="$(jq -nc \
      --argjson doc "$keys_json" \
      --arg key "$key" \
      --argjson supported "$supported" \
      --arg reason "$reason" \
      '$doc + {($key): {supported: $supported, reason: $reason}}')"
  done <<< "$GRAPH_RUNTIME_TOOLING_PROFILE_KEYS"

  jq -nc \
    --arg runtime "$runtime" \
    --argjson schema "$GRAPH_RUNTIME_CAPABILITIES_SCHEMA_VERSION" \
    --argjson keys "$keys_json" \
    '{
      schemaVersion: $schema,
      runtime: $runtime,
      keys: $keys
    }
    | . + {
        supportedKeys: ([$keys | to_entries[] | select(.value.supported) | .key] | sort),
        unsupportedKeys: ([$keys | to_entries[] | select(.value.supported | not) | .key] | sort)
      }'
}

# graph_runtime_tooling_profile_key_is_supported <capabilities-json> <key>
graph_runtime_tooling_profile_key_is_supported() {
  local json="${1-}" key="${2-}"
  [[ -n "$json" && -n "$key" ]] || return 1
  printf '%s' "$json" | jq -e --arg k "$key" '.keys[$k].supported == true' >/dev/null 2>&1
}

# graph_runtime_capability_is_supported <capabilities-json> <name>
# <name> is workspaceEnforcement, liveApprovals, sessionContinuation,
# provenSandboxBoundary, nativeSubagentsOff, or
# usageReliability[:authoritative|:estimated|:unavailable].
graph_runtime_capability_is_supported() {
  local json="${1-}" name="${2-}"
  [[ -n "$json" && -n "$name" ]] || return 1
  printf '%s' "$json" | jq -e --arg n "$name" '
    if $n == "workspaceEnforcement" then .workspaceEnforcement == true
    elif $n == "liveApprovals" then .liveApprovals == true
    elif $n == "sessionContinuation" then .sessionContinuation == true
    elif $n == "provenSandboxBoundary" then .provenSandboxBoundary == true
    elif $n == "nativeSubagentsOff" then .nativeSubagentsOff == true
    elif $n == "usageReliability" then
      (.usageReliability == "authoritative" or .usageReliability == "estimated")
    elif ($n | startswith("usageReliability:")) then
      .usageReliability == ($n | sub("^usageReliability:"; ""))
    else
      false
    end
  ' >/dev/null 2>&1
}
