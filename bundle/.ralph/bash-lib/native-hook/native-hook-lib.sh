#!/usr/bin/env bash
# Shared helpers for native runtime hooks (Claude, Cursor, Codex, OpenCode).
# Hook scripts stay thin; shared truthy parsing, workspace/plan resolution,
# fail-open behavior, result-store footers, telemetry, and wrapper invocation.

if [[ -n "${RALPH_NATIVE_HOOK_LIB_LOADED:-}" ]]; then
  return 0 2>/dev/null || exit 0
fi
RALPH_NATIVE_HOOK_LIB_LOADED=1

_NATIVE_HOOK_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

ralph_native_hook_ralph_home() {
  if [[ -n "${RALPH_HOME:-}" ]]; then
    printf '%s\n' "$RALPH_HOME"
    return 0
  fi
  if [[ -n "${HOME:-}" ]]; then
    printf '%s/.ralph\n' "$HOME"
    return 0
  fi
  return 1
}

# The bash-lib directory this file was loaded from.
#
# A hook shipped inside a Ralph tree already knows where its siblings live: they
# sit next to the lib that is currently executing. Without this, a checkout or a
# project-local install with no global ~/.ralph resolves nothing and every hook
# silently no-ops. This is not the global fallback -- it is the tree the running
# code came from -- so it applies even under RALPH_DISABLE_GLOBAL_FALLBACK.
ralph_native_hook_self_bash_lib_dir() {
  local dir
  dir="$(dirname "$_NATIVE_HOOK_LIB_DIR")"
  [[ -d "$dir" ]] || return 1
  printf '%s\n' "$dir"
}

# Resolve a file under bash-lib. Prefers project-local .ralph, then $RALPH_HOME/bundle/.ralph.
# Args: workspace relative_path (e.g. compactors.sh or mcp-proxy/mcp-proxy-policy.sh)
ralph_native_hook_resolve_bash_lib() {
  local workspace="${1:-}" rel_path="${2:-}"
  local candidate ralph_home self_dir

  if [[ -n "$workspace" ]]; then
    candidate="$workspace/.ralph/bash-lib/$rel_path"
    if [[ -f "$candidate" ]]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  fi

  if self_dir="$(ralph_native_hook_self_bash_lib_dir 2>/dev/null)"; then
    candidate="$self_dir/$rel_path"
    if [[ -f "$candidate" ]]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  fi

  if [[ "${RALPH_DISABLE_GLOBAL_FALLBACK:-0}" == "1" ]]; then
    return 1
  fi

  ralph_home="$(ralph_native_hook_ralph_home 2>/dev/null || true)"
  candidate="${ralph_home}/bundle/.ralph/bash-lib/$rel_path"
  if [[ -n "$ralph_home" && -f "$candidate" ]]; then
    printf '%s\n' "$candidate"
    return 0
  fi

  return 1
}

# Resolve the bash-lib directory for a workspace.
ralph_native_hook_resolve_bash_lib_dir() {
  local workspace="${1:-}" ralph_home dir project_root

  if [[ -n "$workspace" && -d "$workspace/.ralph/bash-lib" ]]; then
    printf '%s\n' "$workspace/.ralph/bash-lib"
    return 0
  fi

  # The agent workspace can intentionally differ from the Ralph project root.
  # Native hooks still load their libraries from the project-local install.
  for project_root in "${RALPH_PROJECT_ROOT:-}" "${CLAUDE_PROJECT_DIR:-}"; do
    if [[ -n "$project_root" && -d "$project_root/.ralph/bash-lib" ]]; then
      printf '%s\n' "$project_root/.ralph/bash-lib"
      return 0
    fi
  done

  if dir="$(ralph_native_hook_self_bash_lib_dir 2>/dev/null)"; then
    printf '%s\n' "$dir"
    return 0
  fi

  if [[ "${RALPH_DISABLE_GLOBAL_FALLBACK:-0}" == "1" ]]; then
    return 1
  fi

  ralph_home="$(ralph_native_hook_ralph_home 2>/dev/null || true)"
  dir="${ralph_home}/bundle/.ralph/bash-lib"
  if [[ -n "$ralph_home" && -d "$dir" ]]; then
    printf '%s\n' "$dir"
    return 0
  fi

  return 1
}

# Resolve a script directly under .ralph (e.g. mcp-server.sh).
ralph_native_hook_resolve_ralph_script() {
  local workspace="${1:-}" script_name="${2:-}"
  local candidate ralph_home self_dir

  if [[ -n "$workspace" ]]; then
    candidate="$workspace/.ralph/$script_name"
    if [[ -f "$candidate" ]]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  fi

  if self_dir="$(ralph_native_hook_self_bash_lib_dir 2>/dev/null)"; then
    candidate="$(dirname "$self_dir")/$script_name"
    if [[ -f "$candidate" ]]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  fi

  if [[ "${RALPH_DISABLE_GLOBAL_FALLBACK:-0}" == "1" ]]; then
    return 1
  fi

  ralph_home="$(ralph_native_hook_ralph_home 2>/dev/null || true)"
  candidate="${ralph_home}/bundle/.ralph/$script_name"
  if [[ -n "$ralph_home" && -f "$candidate" ]]; then
    printf '%s\n' "$candidate"
    return 0
  fi

  return 1
}

ralph_native_hook_truthy() {
  case "${1:-}" in
    1 | true | yes | on) return 0 ;;
    *) return 1 ;;
  esac
}

ralph_native_hook_fail_open() {
  exit 0
}

# Args: optional default when RALPH_PLAN_KEY and RALPH_ARTIFACT_NS are unset.
ralph_native_hook_plan_key() {
  local default_key="${1:-bash-hook}"
  if [[ -n "${RALPH_PLAN_KEY:-}" ]]; then
    printf '%s\n' "$RALPH_PLAN_KEY"
    return 0
  fi
  if [[ -n "${RALPH_ARTIFACT_NS:-}" ]]; then
    printf '%s\n' "$RALPH_ARTIFACT_NS"
    return 0
  fi
  printf '%s\n' "$default_key"
}

# Prints a stable, non-sensitive reason code when the plan key was resolved
# from neither RALPH_PLAN_KEY nor RALPH_ARTIFACT_NS (i.e. a fallback/default
# key was used), or an empty string when either was explicitly set. Never
# fails; callers pass the result explicitly into telemetry builders instead
# of re-deriving it from a global at record-write time.
ralph_native_hook_plan_key_fallback_reason() {
  if [[ -n "${RALPH_PLAN_KEY:-}" ]]; then
    return 0
  fi
  if [[ -n "${RALPH_ARTIFACT_NS:-}" ]]; then
    return 0
  fi
  printf 'no_plan_key_or_artifact_ns_env\n'
}

# Resolve project/workspace root from env var or hook JSON payload.
# Args: env_dir_var input_json_var (name holding JSON string)
ralph_native_hook_project_dir() {
  local env_dir_var="${1:-}"
  local input_json_var="${2:-}"
  local env_dir input_json cwd

  if [[ -n "$env_dir_var" ]]; then
    env_dir="${!env_dir_var:-}"
    if [[ -n "$env_dir" ]]; then
      printf '%s\n' "$env_dir"
      return 0
    fi
  fi

  if [[ -n "$input_json_var" ]]; then
    # Not "${!input_json_var:-{}}": bash closes that expansion one brace
    # early, so a populated payload arrives with a stray trailing "}".
    input_json="${!input_json_var:-}"
    [[ -n "$input_json" ]] || input_json='{}'
    cwd="$(jq -r '.cwd // empty' <<<"$input_json")"
    if [[ -n "$cwd" ]]; then
      printf '%s\n' "$cwd"
      return 0
    fi
  fi

  return 1
}

ralph_native_hook_preview_max_bytes() {
  local cap="${RALPH_BASH_COMPACT_PREVIEW_MAX_BYTES:-4096}"
  if [[ "$cap" =~ ^[0-9]+$ ]] && [[ "$cap" -gt 0 ]]; then
    printf '%s\n' "$cap"
  else
    printf '4096\n'
  fi
}

ralph_native_hook_combine_streams() {
  local stdout="${1-}" stderr="${2-}"
  if [[ -n "$stderr" ]]; then
    if [[ -n "$stdout" ]]; then
      printf '%s\n%s' "$stdout" "$stderr"
    else
      printf '%s' "$stderr"
    fi
  else
    printf '%s' "$stdout"
  fi
}

ralph_native_hook_cap_stream_pair() {
  local -n _out_stdout="$1"
  local -n _out_stderr="$2"
  local preview_max="${3:-4096}"
  local remaining="$preview_max"

  if [[ "${#_out_stdout}" -gt "$remaining" ]]; then
    _out_stdout="${_out_stdout:0:remaining}"
    remaining=0
  else
    remaining=$((remaining - ${#_out_stdout}))
  fi
  if [[ "$remaining" -gt 0 && "${#_out_stderr}" -gt "$remaining" ]]; then
    _out_stderr="${_out_stderr:0:remaining}"
  fi
}

ralph_native_hook_original_storage_json() {
  local command="${1-}" stdout="${2-}" stderr="${3-}" exit_code="${4:-0}"
  jq -nc \
    --rawfile command <(printf '%s' "$command") \
    --rawfile stdout <(printf '%s' "$stdout") \
    --rawfile stderr <(printf '%s' "$stderr") \
    --argjson exitCode "$exit_code" \
    '{
      command: $command,
      stdout: $stdout,
      stderr: $stderr,
      exitCode: $exitCode
    }'
}

ralph_native_hook_store_original() {
  local workspace="${1:-}" plan_key="${2:-}" storage_text="${3:-}" store_tool="${4:-ralph_bash_compact}"
  local store_script result_id

  store_script="$(ralph_native_hook_resolve_bash_lib "$workspace" "mcp-proxy-result-store.sh" 2>/dev/null || true)"
  if [[ -z "$store_script" ]]; then
    store_script="$(ralph_native_hook_resolve_bash_lib "$workspace" "mcp-proxy/mcp-proxy-result-store.sh" 2>/dev/null || true)"
  fi
  if [[ -z "$store_script" || ! -f "$store_script" ]]; then
    return 1
  fi
  if [[ -z "${RALPH_MCP_PROXY_RESULT_STORE_LOADED:-}" ]]; then
    # shellcheck source=/dev/null
    source "$store_script"
    RALPH_MCP_PROXY_RESULT_STORE_LOADED=1
  fi
  result_id="$(ralph_mcp_proxy_result_store_write "$workspace" "$plan_key" "$storage_text" "$store_tool" 2>/dev/null || true)"
  [[ -n "$result_id" ]] || return 1
  printf '.ralph-workspace/tool-results/%s/results/%s\n' "$plan_key" "$result_id"
}

ralph_native_hook_bash_compact_footer() {
  local result_path="${1:-}"
  printf '[ralph: bash output compacted; original stored at %s; set RALPH_BASH_COMPACT=0 to disable]' "$result_path"
}

ralph_native_hook_append_footer_to_stream() {
  local stream="${1-}" footer="${2-}"
  if [[ -z "$footer" ]]; then
    printf '%s' "$stream"
    return 0
  fi
  if [[ -n "$stream" && "${stream: -1}" != $'\n' ]]; then
    stream="${stream}"$'\n'
  fi
  printf '%s%s' "$stream" "$footer"
}

ralph_native_hook_emit_claude_pre_tool_updated_input() {
  local updated_input_json="${1-}"
  jq -nc \
    --argjson updatedInput "$updated_input_json" \
    '{
      hookSpecificOutput: {
        hookEventName: "PreToolUse",
        updatedInput: $updatedInput
      }
    }'
}

ralph_native_hook_emit_claude_post_tool_updated_output() {
  local stdout="${1-}" stderr="${2-}" interrupted="${3:-false}" is_image="${4:-false}" footer="${5-}"
  local out_stdout
  out_stdout="$(ralph_native_hook_append_footer_to_stream "$stdout" "$footer")"
  jq -nc \
    --arg stdout "$out_stdout" \
    --arg stderr "$stderr" \
    --argjson interrupted "$interrupted" \
    --argjson isImage "$is_image" \
    '{
      hookSpecificOutput: {
        hookEventName: "PostToolUse",
        updatedToolOutput: {
          stdout: $stdout,
          stderr: $stderr,
          interrupted: $interrupted,
          isImage: $isImage
        }
      }
    }'
}

# Codex PostToolUse probe and future compaction hooks use the same JSON shape as Claude.
ralph_native_hook_emit_codex_post_tool_updated_output() {
  ralph_native_hook_emit_claude_post_tool_updated_output "$@"
}

ralph_native_hook_source_telemetry_lib() {
  local workspace="${1:-}"
  local telemetry_lib
  telemetry_lib="$(ralph_native_hook_resolve_bash_lib "$workspace" "hook-telemetry.sh" 2>/dev/null || true)"
  if [[ -z "$telemetry_lib" || ! -f "$telemetry_lib" ]]; then
    return 1
  fi
  if [[ -z "${RALPH_HOOK_TELEMETRY_LOADED:-}" ]]; then
    # shellcheck source=/dev/null
    source "$telemetry_lib"
    RALPH_HOOK_TELEMETRY_LOADED=1
  fi
  return 0
}

ralph_native_hook_append_rewrite_log() {
  local workspace="${1:-}" plan_key="${2:-}" original_command="${3:-}"
  local rewritten_command="${4:-}" rule_id="${5:-}"
  [[ -n "${RALPH_BASH_REWRITE_LOG:-}" ]] || return 0
  ralph_native_hook_source_telemetry_lib "$workspace" || return 0
  ralph_hook_telemetry_append_rewrite_log \
    "$workspace" \
    "$plan_key" \
    "$original_command" \
    "$rewritten_command" \
    "$rule_id" \
    true
}

ralph_native_hook_append_nudge_log() {
  local workspace="${1:-}" plan_key="${2:-}" original_tool="${3:-}"
  local nudge_message="${4:-}" rule_id="${5:-exploration-deny}"
  [[ -n "${RALPH_BASH_REWRITE_LOG:-}" ]] || return 0
  ralph_native_hook_source_telemetry_lib "$workspace" || return 0
  ralph_hook_telemetry_append_rewrite_log \
    "$workspace" \
    "$plan_key" \
    "$original_tool" \
    "$nudge_message" \
    "$rule_id" \
    false
}

ralph_native_hook_append_compact_log() {
  local workspace="${1:-}" plan_key="${2:-}" command="${3:-}" compact_json="${4:-}"
  local original_stdout="${5-}" original_stderr="${6-}" storage_path="${7-}"
  local exit_code="${8:-0}"
  local plan_key_fallback="${9:-}" plan_key_fallback_reason="${10:-}"
  local delivered_bytes="${11:-}" delivered_tokens="${12:-}"
  local duration_ms="${13:-}" fingerprint="${14:-}"
  [[ -n "${RALPH_BASH_COMPACT_LOG:-}" ]] || return 0
  ralph_native_hook_source_telemetry_lib "$workspace" || return 0
  ralph_hook_telemetry_append_compact_log \
    "$workspace" \
    "$plan_key" \
    "$command" \
    "$compact_json" \
    "$original_stdout" \
    "$original_stderr" \
    "${storage_path:-}" \
    "$exit_code" \
    "" \
    "$plan_key_fallback" \
    "$plan_key_fallback_reason" \
    "$delivered_bytes" \
    "$delivered_tokens" \
    "$duration_ms" \
    "$fingerprint"
}

# State root for repo-scoped stores (.ralph-workspace under the project, or override).
ralph_native_hook_state_root() {
  local workspace="${1:-}"
  if [[ -n "${RALPH_PLAN_WORKSPACE_ROOT:-}" ]]; then
    printf '%s\n' "${RALPH_PLAN_WORKSPACE_ROOT%/}"
    return 0
  fi
  if [[ -n "$workspace" ]]; then
    printf '%s/.ralph-workspace\n' "${workspace%/}"
    return 0
  fi
  return 1
}

# True when an operator-supplied killswitch.json exists (override >
# project state-root > $RALPH_HOME). Bundle default is excluded: native
# PreToolUse hooks use ralph_native_hook_killswitch_bundle_quick_allow for
# the stock bundle rules instead of paying killswitch-core on every call.
ralph_native_hook_killswitch_config_exists() {
  local workspace="${1:-}"
  local override_cfg ws_root ws_cfg global_cfg

  override_cfg="${RALPH_KILLSWITCH_OVERRIDE_FILE:-}"
  if [[ -n "$override_cfg" && -e "$override_cfg" ]]; then
    return 0
  fi

  if [[ -n "${RALPH_PLAN_WORKSPACE_ROOT:-}" ]]; then
    ws_root="${RALPH_PLAN_WORKSPACE_ROOT%/}"
  elif [[ -n "$workspace" ]]; then
    ws_root="${workspace%/}/.ralph-workspace"
  elif [[ -n "${WORKSPACE:-}" ]]; then
    ws_root="${WORKSPACE%/}/.ralph-workspace"
  else
    ws_root=""
  fi
  if [[ -n "$ws_root" ]]; then
    ws_cfg="${ws_root}/killswitch.json"
    if [[ -e "$ws_cfg" ]]; then
      return 0
    fi
  fi

  if [[ -n "${RALPH_HOME:-}" ]]; then
    global_cfg="${RALPH_HOME}/killswitch.json"
    if [[ -e "$global_cfg" ]]; then
      return 0
    fi
  fi

  return 1
}

# True when the Ralph bundle ships a killswitch.json (install default).
ralph_native_hook_killswitch_bundle_present() {
  local workspace="${1:-}"
  local lib_dir

  # Prefer the already-sourced native-hook lib dir (no resolve/cd on hot path).
  if [[ -n "${_NATIVE_HOOK_LIB_DIR:-}" && -e "${_NATIVE_HOOK_LIB_DIR}/../killswitch.json" ]]; then
    return 0
  fi

  lib_dir="$(ralph_native_hook_resolve_bash_lib_dir "$workspace" 2>/dev/null || true)"
  [[ -n "$lib_dir" && -e "${lib_dir}/../killswitch.json" ]]
}

# Cheap allow-check mirroring stock bundle custom_rules (no_sudo, no_rm_rf_root,
# no_force_push). Returns 0 when the command is clearly allowed; 1 when it may
# match and the caller should run full killswitch_evaluate.
ralph_native_hook_killswitch_bundle_quick_allow() {
  local command="${1-}"
  if [[ "$command" =~ ^sudo[[:space:]] ]]; then
    return 1
  fi
  case "$command" in
    *"rm -rf /"*|*"git push --force"*) return 1 ;;
  esac
  return 0
}

# True when command-profiles has at least one promoted (long_running) entry.
# A non-empty profiles.json of observations alone is not enough: auto-background
# only injects for long_running fingerprints, so skip python3 until one exists.
ralph_native_hook_command_profiles_registry_ready() {
  local workspace="${1:-}"
  local state_root profiles
  state_root="$(ralph_native_hook_state_root "$workspace" 2>/dev/null || true)"
  [[ -n "$state_root" ]] || return 1
  profiles="${state_root}/command-profiles/profiles.json"
  [[ -f "$profiles" && -s "$profiles" ]] || return 1
  # Cheap scan: avoid python3/jq on the PreToolUse hot path.
  grep -Eq '"long_running"[[:space:]]*:[[:space:]]*true' "$profiles"
}

# Decide whether a PreToolUse hook should source killswitch-core for this call.
# Returns 0 when full evaluation is required; 1 when the hook may skip.
# Args: workspace command
ralph_native_hook_killswitch_needs_full_evaluate() {
  local workspace="${1:-}" command="${2-}"

  if ralph_native_hook_killswitch_config_exists "$workspace"; then
    return 0
  fi
  if ralph_native_hook_killswitch_bundle_present "$workspace"; then
    if ralph_native_hook_killswitch_bundle_quick_allow "$command"; then
      return 1
    fi
    return 0
  fi
  return 1
}

# Compute a command fingerprint via command-fingerprint.sh. Prints digest or empty.
# Fail-open: never non-zero for missing python/libs.
ralph_native_hook_command_fingerprint() {
  local workspace="${1:-}" command="${2-}"
  local fp_lib digest=""
  fp_lib="$(ralph_native_hook_resolve_bash_lib "$workspace" "command-fingerprint.sh" 2>/dev/null || true)"
  if [[ -z "$fp_lib" || ! -f "$fp_lib" ]]; then
    return 0
  fi
  # shellcheck source=/dev/null
  source "$fp_lib"
  digest="$(ralph_command_fingerprint "$command" 2>/dev/null || true)"
  if [[ -n "$digest" && "$digest" != "null" ]]; then
    printf '%s\n' "$digest"
  fi
  return 0
}

# Pure observation into command_profiles store. Never fails the hook.
# Skips when: empty fingerprint, duration absent/invalid, python3 missing,
# or the command was already backgrounded.
ralph_native_hook_maybe_record_duration() {
  local workspace="${1:-}" command="${2-}" fingerprint="${3-}"
  local duration_ms="${4-}" backgrounded="${5:-false}"
  local state_root py_script lib_dir payload

  case "$backgrounded" in
    1 | true | yes | on) return 0 ;;
  esac
  [[ -n "$fingerprint" ]] || return 0
  [[ "$duration_ms" =~ ^[0-9]+$ ]] || return 0
  command -v python3 >/dev/null 2>&1 || return 0
  command -v jq >/dev/null 2>&1 || return 0

  state_root="$(ralph_native_hook_state_root "$workspace" 2>/dev/null || true)"
  [[ -n "$state_root" ]] || return 0

  lib_dir="$(ralph_native_hook_resolve_bash_lib_dir "$workspace" 2>/dev/null || true)"
  [[ -n "$lib_dir" ]] || return 0
  py_script="${lib_dir}/../python/command_profiles.py"
  [[ -f "$py_script" ]] || return 0

  payload="$(jq -nc \
    --arg state_root "$state_root" \
    --arg fingerprint "$fingerprint" \
    --arg command "$command" \
    --argjson duration_ms "$duration_ms" \
    '{state_root:$state_root,fingerprint:$fingerprint,command:$command,duration_ms:$duration_ms}' \
    2>/dev/null)" || return 0
  printf '%s\n' "$payload" | python3 "$py_script" record >/dev/null 2>&1 || true
  return 0
}

# Pre/post duration pairing for runtimes without a payload duration field.
# Fail-open: never alters hook exit status. Args: workspace command invocation_id
ralph_native_hook_mark_inflight() {
  local workspace="${1:-}" command="${2-}" invocation_id="${3-}"
  local state_root py_script lib_dir payload

  [[ -n "$command" ]] || return 0
  command -v python3 >/dev/null 2>&1 || return 0
  command -v jq >/dev/null 2>&1 || return 0

  state_root="$(ralph_native_hook_state_root "$workspace" 2>/dev/null || true)"
  [[ -n "$state_root" ]] || return 0

  lib_dir="$(ralph_native_hook_resolve_bash_lib_dir "$workspace" 2>/dev/null || true)"
  [[ -n "$lib_dir" ]] || return 0
  py_script="${lib_dir}/../python/command_profiles.py"
  [[ -f "$py_script" ]] || return 0

  payload="$(jq -nc \
    --arg state_root "$state_root" \
    --arg command "$command" \
    --arg invocation_id "$invocation_id" \
    '{state_root:$state_root,command:$command,invocation_id:$invocation_id}' \
    2>/dev/null)" || return 0
  printf '%s\n' "$payload" | python3 "$py_script" mark-start >/dev/null 2>&1 || true
  return 0
}

# Consume an inflight marker and record duration. Prefer invocation_id.
# Args: workspace command invocation_id
ralph_native_hook_complete_inflight() {
  local workspace="${1:-}" command="${2-}" invocation_id="${3-}"
  local state_root py_script lib_dir payload

  command -v python3 >/dev/null 2>&1 || return 0
  command -v jq >/dev/null 2>&1 || return 0

  state_root="$(ralph_native_hook_state_root "$workspace" 2>/dev/null || true)"
  [[ -n "$state_root" ]] || return 0

  lib_dir="$(ralph_native_hook_resolve_bash_lib_dir "$workspace" 2>/dev/null || true)"
  [[ -n "$lib_dir" ]] || return 0
  py_script="${lib_dir}/../python/command_profiles.py"
  [[ -f "$py_script" ]] || return 0

  payload="$(jq -nc \
    --arg state_root "$state_root" \
    --arg command "$command" \
    --arg invocation_id "$invocation_id" \
    '{state_root:$state_root,command:$command,invocation_id:$invocation_id}' \
    2>/dev/null)" || return 0
  printf '%s\n' "$payload" | python3 "$py_script" complete >/dev/null 2>&1 || true
  return 0
}

# True (exit 0) when command_profiles marks this fingerprint long_running and
# the command is not denylisted. Fail-open: missing deps/store/python => false.
# Args: workspace command fingerprint [run_in_background]
ralph_native_hook_injection_eligible() {
  local workspace="${1:-}" command="${2-}" fingerprint="${3-}"
  local run_in_background="${4:-false}"
  local state_root py_script lib_dir

  [[ -n "$fingerprint" ]] || return 1
  command -v python3 >/dev/null 2>&1 || return 1

  state_root="$(ralph_native_hook_state_root "$workspace" 2>/dev/null || true)"
  [[ -n "$state_root" ]] || return 1

  lib_dir="$(ralph_native_hook_resolve_bash_lib_dir "$workspace" 2>/dev/null || true)"
  [[ -n "$lib_dir" ]] || return 1
  py_script="${lib_dir}/../python/command_profiles.py"
  [[ -f "$py_script" ]] || return 1

  python3 - "$py_script" "$state_root" "$fingerprint" "$command" "$run_in_background" <<'PY' >/dev/null 2>&1
import sys
from pathlib import Path

py_script, state_root, fingerprint, command, run_in_background = sys.argv[1:6]
sys.path.insert(0, str(Path(py_script).resolve().parent))
from command_profiles import is_injection_eligible  # noqa: E402

ok = is_injection_eligible(
    Path(state_root),
    fingerprint,
    command,
    run_in_background=run_in_background,
)
sys.exit(0 if ok else 1)
PY
}

# Build a shell command that runs native-shell-wrapper.sh with env gates set.
# Prints one line suitable for tool_input.command replacement (Cursor T3+).
ralph_native_hook_build_wrapper_command() {
  local workspace="${1:-}" command="${2:-}" runtime="${3:-}" plan_key="${4:-}"
  local wrapper_script escaped_cmd escaped_workspace escaped_runtime escaped_plan
  wrapper_script="$(ralph_native_hook_resolve_bash_lib "$workspace" "native-hook/native-shell-wrapper.sh" 2>/dev/null || true)"

  [[ -n "$workspace" && -n "$command" && -n "$wrapper_script" && -f "$wrapper_script" ]] || return 1

  escaped_workspace="$(printf '%q' "$workspace")"
  escaped_cmd="$(printf '%q' "$command")"
  escaped_runtime="$(printf '%q' "${runtime:-}")"
  escaped_plan="$(printf '%q' "${plan_key:-$(ralph_native_hook_plan_key default)}")"

  printf 'RALPH_NATIVE_SHELL_WRAPPER=1 bash %s --workspace %s --command %s --runtime %s --plan-key %s' \
    "$(printf '%q' "$wrapper_script")" \
    "$escaped_workspace" \
    "$escaped_cmd" \
    "$escaped_runtime" \
    "$escaped_plan"
}
