#!/usr/bin/env bash
# Cursor native hook overlay: workspace .cursor/hooks.json merge and restore; MCP merge is separate.
#
# Headless contract pinned 2026-06-04 on cursor-agent 2026.06.03-0bbb28e (see PLAN48 matrix and
# .ralph-workspace/artifacts/PLAN48/cursor-hook-spike/spike-notes.md): preToolUse/postToolUse/
# afterShellExecution fire for Shell; updated_input.command is agent-visible; updated_tool_output
# for Shell is not agent-visible on the tested build.

if [[ -n "${RALPH_RUNTIME_OVERLAY_CURSOR_LOADED:-}" ]]; then
  return
fi
RALPH_RUNTIME_OVERLAY_CURSOR_LOADED=1

_runtime_overlay_cursor_lib_dir() {
  cd "$(dirname "${BASH_SOURCE[0]}")" && pwd
}

_runtime_overlay_cursor_bundle_root() {
  local lib_dir
  lib_dir="$(_runtime_overlay_cursor_lib_dir)"
  cd "$lib_dir/../../.." && pwd
}

_runtime_overlay_cursor_template_hooks_json() {
  local bundle_root
  bundle_root="$(_runtime_overlay_cursor_bundle_root)"
  printf '%s/.cursor/hooks.json' "$bundle_root"
}

_runtime_overlay_cursor_hooks_source_dir() {
  local bundle_root
  bundle_root="$(_runtime_overlay_cursor_bundle_root)"
  printf '%s/.cursor/hooks' "$bundle_root"
}

_runtime_overlay_cursor_ralph_hook_script_names() {
  printf '%s\n' pre-tool-shell-policy.sh post-tool-shell-telemetry.sh post-tool-native-result-compact.sh post-tool-mcp-compact.sh after-shell-telemetry.sh
}

ralph_cursor_optimization_mode_enables_mcp_proxy_compaction() {
  case "${RALPH_OPTIMIZATION_MODE:-}" in
    bounded|governed) return 0 ;;
    *) return 1 ;;
  esac
}

ralph_native_hooks_want_activation() {
  local mode="${RALPH_NATIVE_HOOKS:-}"
  case "$mode" in
    off) return 1 ;;
    on|auto) return 0 ;;
    *) return 1 ;;
  esac
}

ralph_cursor_proxy_shell_compact_effective() {
  case "${RALPH_PROXY_SHELL_COMPACT:-}" in
    1|true|yes|on) return 0 ;;
    *) return 1 ;;
  esac
}

ralph_cursor_native_shell_wrapper_want() {
  case "${RALPH_NATIVE_SHELL_WRAPPER:-}" in
    0 | false | no | off) return 1 ;;
    *) return 0 ;;
  esac
}

ralph_cursor_apply_native_shell_hook_env_defaults() {
  if ! ralph_native_hooks_want_activation; then
    return 0
  fi
  if ! ralph_cursor_native_shell_wrapper_want; then
    return 0
  fi
  RALPH_NATIVE_SHELL_WRAPPER=1
  export RALPH_NATIVE_SHELL_WRAPPER
  RALPH_BASH_REWRITE=1
  export RALPH_BASH_REWRITE
}

ralph_cursor_apply_mcp_optimization_defaults() {
  if [[ "${RALPH_AGENT_TOOL_ACCESS:-native}" != "ralph" ]]; then
    if declare -F runtime_overlay_set_proxy_shell_compact_effective >/dev/null 2>&1; then
      runtime_overlay_set_proxy_shell_compact_effective "false"
    fi
    return 0
  fi

  # Direct overlay prepares often run without RALPH_MODE, so preserve the
  # native helper path when mode is known and otherwise derive the same default
  # compaction behavior from the already-selected overlay knobs.
  if [[ -n "${RALPH_MODE:-}" ]] && declare -F ralph_apply_shell_compact_defaults >/dev/null 2>&1; then
    ralph_apply_shell_compact_defaults || true
  elif [[ -z "${RALPH_PROXY_SHELL_COMPACT:-}" ]] \
    && { ralph_cursor_optimization_mode_enables_mcp_proxy_compaction \
      || [[ "${RALPH_NATIVE_HOOKS:-}" != "off" ]]; }; then
    RALPH_PROXY_SHELL_COMPACT=1
    export RALPH_PROXY_SHELL_COMPACT
  fi

  if ralph_cursor_proxy_shell_compact_effective; then
    if declare -F runtime_overlay_set_proxy_shell_compact_effective >/dev/null 2>&1; then
      runtime_overlay_set_proxy_shell_compact_effective "true"
    fi
    if declare -F runtime_overlay_add_capability >/dev/null 2>&1; then
      runtime_overlay_add_capability "cursor-mcp-proxy-shell-compact"
    fi
  elif declare -F runtime_overlay_set_proxy_shell_compact_effective >/dev/null 2>&1; then
    runtime_overlay_set_proxy_shell_compact_effective "false"
  fi

  if ralph_cursor_optimization_mode_enables_mcp_proxy_compaction; then
    if declare -F runtime_overlay_add_capability >/dev/null 2>&1; then
      runtime_overlay_add_capability "cursor-mcp-optimization"
    fi
  fi

  return 0
}

runtime_overlay_cursor_hooks_detected_in_file() {
  local hooks_file="$1"
  if [[ ! -f "$hooks_file" ]]; then
    return 1
  fi
  if ! command -v python3 &>/dev/null; then
    return 1
  fi
  python3 - "$hooks_file" <<'PY'
import json, os, sys

path = sys.argv[1]
required = {
    "pre-tool-shell-policy.sh",
    "post-tool-shell-telemetry.sh",
    "post-tool-native-result-compact.sh",
    "post-tool-mcp-compact.sh",
    "after-shell-telemetry.sh",
}

try:
    with open(path) as fh:
        data = json.load(fh)
except (OSError, json.JSONDecodeError):
    sys.exit(1)

hooks = data.get("hooks") or {}
found = set()

def scan_entries(entries):
    for entry in entries or []:
        cmd = entry.get("command") or ""
        base = os.path.basename(cmd)
        if base in required:
            found.add(base)

for event in ("preToolUse", "postToolUse", "afterShellExecution"):
    scan_entries(hooks.get(event))

if found == required:
    sys.exit(0)
sys.exit(1)
PY
}

runtime_overlay_cursor_preserve_durable_install() {
  local hooks_file="${1:-}"
  [[ -n "$hooks_file" ]] || return 1
  runtime_overlay_cursor_hooks_detected_in_file "$hooks_file"
}

runtime_overlay_cursor_merge_hooks_file() {
  local target="$1"
  local template="$2"
  python3 - "$target" "$template" <<'PY'
import copy
import json
import os
import sys

target, template = sys.argv[1:]

RALPH_BASES = {
    "pre-tool-shell-policy.sh",
    "post-tool-shell-telemetry.sh",
    "post-tool-mcp-compact.sh",
    "after-shell-telemetry.sh",
}


def load_json(path):
    if not os.path.isfile(path):
        return {}
    with open(path) as fh:
        return json.load(fh)


def entry_command(entry):
    return entry.get("command") or ""


def entry_basename(entry):
    return os.path.basename(entry_command(entry))


def merge_entries(existing, template_entries):
    existing_cmds = {entry_command(e) for e in existing}
    existing_bases = {entry_basename(e) for e in existing if entry_basename(e)}
    for entry in template_entries:
        cmd = entry_command(entry)
        base = entry_basename(entry)
        if cmd in existing_cmds:
            continue
        if base in existing_bases:
            continue
        if any(cmd.endswith(b) for b in existing_bases if b):
            continue
        existing.append(copy.deepcopy(entry))
        existing_cmds.add(cmd)
        if base:
            existing_bases.add(base)


data = load_json(target)
with open(template) as fh:
    template_data = json.load(fh)

data.setdefault("version", template_data.get("version", 1))
template_hooks = template_data.get("hooks") or {}
hooks = data.setdefault("hooks", {})

for event, template_entries in template_hooks.items():
    hooks.setdefault(event, [])
    merge_entries(hooks[event], template_entries)

os.makedirs(os.path.dirname(target) or ".", exist_ok=True)
with open(target, "w") as fh:
    json.dump(data, fh, indent=2)
    fh.write("\n")
PY
}

run_plan_invoke_cursor_hooks_scripts_prepare() {
  local workspace="$1"
  local source_dir target_dir script backup_path=""
  source_dir="$(_runtime_overlay_cursor_hooks_source_dir)"
  target_dir="$workspace/.cursor/hooks"
  mkdir -p "$target_dir"

  while IFS= read -r script; do
    [[ -z "$script" ]] && continue
    if [[ ! -f "$source_dir/$script" ]]; then
      echo "Error: Ralph Cursor hook script missing: $source_dir/$script" >&2
      return 1
    fi
    backup_path=""
    if [[ -f "$target_dir/$script" ]]; then
      if declare -F runtime_overlay_record_original_file >/dev/null 2>&1; then
        runtime_overlay_record_original_file "$target_dir/$script" backup_path 1
      else
        backup_path="$(mktemp "${TMPDIR:-/tmp}/ralph-cursor-hook-script-backup-XXXXXX")"
        cp "$target_dir/$script" "$backup_path"
      fi
    else
      if declare -F ralph_mcp_overlay_record_workspace_mutation >/dev/null 2>&1; then
        ralph_mcp_overlay_record_workspace_mutation "$target_dir/$script" 0
      fi
    fi
    CURSOR_PLAN_HOOKS_SCRIPT_TARGETS+=("$target_dir/$script")
    CURSOR_PLAN_HOOKS_SCRIPT_BACKUPS+=("$backup_path")
    if ! cp "$source_dir/$script" "$target_dir/$script"; then
      echo "Error: failed to install Cursor hook script $target_dir/$script" >&2
      return 1
    fi
    chmod +x "$target_dir/$script" 2>/dev/null || true
  done < <(_runtime_overlay_cursor_ralph_hook_script_names)
  return 0
}

run_plan_invoke_cursor_hooks_config_cleanup() {
  local target="${CURSOR_PLAN_HOOKS_CONFIG_TARGET:-}"
  local idx backup script_target

  if [[ -n "$target" ]] && runtime_overlay_cursor_preserve_durable_install "$target"; then
    unset CURSOR_PLAN_HOOKS_CONFIG_TARGET
    unset CURSOR_PLAN_HOOKS_CONFIG_BACKUP
    unset CURSOR_PLAN_HOOKS_CONFIG_HAD_FILE
    unset CURSOR_PLAN_NATIVE_HOOKS_ACTIVE
    CURSOR_PLAN_HOOKS_SCRIPT_TARGETS=()
    CURSOR_PLAN_HOOKS_SCRIPT_BACKUPS=()
    return 0
  fi

  if [[ -n "$target" ]]; then
    if [[ "${CURSOR_PLAN_HOOKS_CONFIG_HAD_FILE:-0}" == "1" ]]; then
      if [[ -n "${CURSOR_PLAN_HOOKS_CONFIG_BACKUP:-}" && -f "$CURSOR_PLAN_HOOKS_CONFIG_BACKUP" ]]; then
        cp "$CURSOR_PLAN_HOOKS_CONFIG_BACKUP" "$target" 2>/dev/null || true
        if ! ralph_mcp_overlay_lifecycle_available; then
          rm -f "$CURSOR_PLAN_HOOKS_CONFIG_BACKUP" 2>/dev/null || true
        fi
      fi
    else
      rm -f "$target" 2>/dev/null || true
    fi
  fi

  if [[ "${CURSOR_PLAN_HOOKS_SCRIPT_TARGETS+set}" == "set" && "${#CURSOR_PLAN_HOOKS_SCRIPT_TARGETS[@]}" -gt 0 ]]; then
    for ((idx = 0; idx < ${#CURSOR_PLAN_HOOKS_SCRIPT_TARGETS[@]}; idx++)); do
      script_target="${CURSOR_PLAN_HOOKS_SCRIPT_TARGETS[idx]}"
      backup="${CURSOR_PLAN_HOOKS_SCRIPT_BACKUPS[idx]:-}"
      if [[ -n "$backup" && -f "$backup" ]]; then
        if [[ -s "$backup" ]]; then
          cp "$backup" "$script_target" 2>/dev/null || true
        else
          rm -f "$script_target" 2>/dev/null || true
        fi
      else
        rm -f "$script_target" 2>/dev/null || true
      fi
    done
  fi

  unset CURSOR_PLAN_HOOKS_CONFIG_TARGET
  unset CURSOR_PLAN_HOOKS_CONFIG_BACKUP
  unset CURSOR_PLAN_HOOKS_CONFIG_HAD_FILE
  unset CURSOR_PLAN_NATIVE_HOOKS_ACTIVE
  CURSOR_PLAN_HOOKS_SCRIPT_TARGETS=()
  CURSOR_PLAN_HOOKS_SCRIPT_BACKUPS=()
}

run_plan_invoke_cursor_hooks_config_prepare() {
  local workspace="${WORKSPACE:-}"
  local target had_file=0 template backup_path=""

  if [[ -z "$workspace" ]]; then
    echo "Error: WORKSPACE is required for Cursor native hook overlay." >&2
    return 1
  fi

  template="$(_runtime_overlay_cursor_template_hooks_json)"
  if [[ ! -f "$template" ]]; then
    echo "Error: Ralph Cursor hooks template missing at $template" >&2
    return 1
  fi

  target="$workspace/.cursor/hooks.json"
  mkdir -p "$(dirname "$target")"

  if [[ -f "$target" ]]; then
    had_file=1
    if ! command -v jq &>/dev/null; then
      echo "Error: jq is required to validate an existing Cursor hooks config." >&2
      return 1
    fi
    if ! jq empty "$target" >/dev/null 2>&1; then
      echo "Error: existing Cursor hooks config is invalid JSON: $target" >&2
      return 1
    fi
    if ralph_mcp_overlay_lifecycle_available; then
      runtime_overlay_record_original_file "$target" backup_path
      CURSOR_PLAN_HOOKS_CONFIG_BACKUP="$backup_path"
    else
      CURSOR_PLAN_HOOKS_CONFIG_BACKUP="$(mktemp "${TMPDIR:-/tmp}/ralph-cursor-hooks-backup-XXXXXX")"
      cp "$target" "$CURSOR_PLAN_HOOKS_CONFIG_BACKUP"
    fi
  fi

  if ! runtime_overlay_cursor_merge_hooks_file "$target" "$template"; then
    echo "Error: failed to merge Ralph Cursor hooks into $target" >&2
    return 1
  fi

  CURSOR_PLAN_HOOKS_SCRIPT_TARGETS=()
  CURSOR_PLAN_HOOKS_SCRIPT_BACKUPS=()
  export CURSOR_PLAN_HOOKS_SCRIPT_TARGETS CURSOR_PLAN_HOOKS_SCRIPT_BACKUPS
  if ! run_plan_invoke_cursor_hooks_scripts_prepare "$workspace"; then
    return 1
  fi

  if [[ "$had_file" != "1" ]] && declare -F ralph_mcp_overlay_record_workspace_mutation >/dev/null 2>&1; then
    ralph_mcp_overlay_record_workspace_mutation "$target" 0
  fi

  CURSOR_PLAN_HOOKS_CONFIG_TARGET="$target"
  CURSOR_PLAN_HOOKS_CONFIG_HAD_FILE="$had_file"
  CURSOR_PLAN_NATIVE_HOOKS_ACTIVE=1
  export CURSOR_PLAN_HOOKS_CONFIG_TARGET CURSOR_PLAN_HOOKS_CONFIG_HAD_FILE CURSOR_PLAN_NATIVE_HOOKS_ACTIVE
  [[ -n "${CURSOR_PLAN_HOOKS_CONFIG_BACKUP:-}" ]] && export CURSOR_PLAN_HOOKS_CONFIG_BACKUP

  ralph_mcp_overlay_register_runtime_cleanup run_plan_invoke_cursor_hooks_config_cleanup
  return 0
}

run_plan_invoke_cursor_native_hooks_cleanup() {
  run_plan_invoke_cursor_hooks_config_cleanup
}

ralph_cursor_record_active_native_hooks_summary() {
  local hooks_capability="$1"
  local headless_proof_note="$2"
  local output_mutation_note="$3"
  local mcp_hook_note="$4"
  local wrapper_note="$5"
  local native_result_note="${6:-}"

  ralph_cursor_apply_native_shell_hook_env_defaults

  if declare -F runtime_overlay_set_native_hooks_effective >/dev/null 2>&1; then
    runtime_overlay_set_native_hooks_effective "true"
  fi
  if declare -F runtime_overlay_set_native_hooks_reason >/dev/null 2>&1; then
    runtime_overlay_set_native_hooks_reason "headless_hooks_proven"
  fi
  if declare -F runtime_overlay_set_native_hooks_configured >/dev/null 2>&1; then
    runtime_overlay_set_native_hooks_configured "true"
  fi
  if declare -F runtime_overlay_set_native_output_mutation_proven >/dev/null 2>&1; then
    runtime_overlay_set_native_output_mutation_proven "false"
  fi
  if ralph_cursor_native_shell_wrapper_want; then
    if declare -F runtime_overlay_set_native_shell_wrapper_enabled >/dev/null 2>&1; then
      runtime_overlay_set_native_shell_wrapper_enabled "true"
    fi
    if declare -F runtime_overlay_set_native_shell_wrapper_effective >/dev/null 2>&1; then
      runtime_overlay_set_native_shell_wrapper_effective "true"
    fi
    if declare -F runtime_overlay_set_native_shell_wrapper_reason >/dev/null 2>&1; then
      runtime_overlay_set_native_shell_wrapper_reason "preToolUse_wrapper_rewrite"
    fi
    if declare -F runtime_overlay_set_native_shell_compaction_authoritative >/dev/null 2>&1; then
      runtime_overlay_set_native_shell_compaction_authoritative "wrapper_based_native_shell_compaction"
    fi
    if declare -F runtime_overlay_note_native_shell_hook_proven >/dev/null 2>&1; then
      runtime_overlay_note_native_shell_hook_proven
    fi
  else
    if declare -F runtime_overlay_set_native_shell_wrapper_enabled >/dev/null 2>&1; then
      runtime_overlay_set_native_shell_wrapper_enabled "false"
    fi
    if declare -F runtime_overlay_set_native_shell_wrapper_effective >/dev/null 2>&1; then
      runtime_overlay_set_native_shell_wrapper_effective "false"
    fi
  fi
  if declare -F runtime_overlay_set_fallback_path_active >/dev/null 2>&1; then
    runtime_overlay_set_fallback_path_active "false"
  fi
  if ralph_cursor_proxy_shell_compact_effective \
    && [[ "${RALPH_AGENT_TOOL_ACCESS:-native}" == "ralph" ]] \
    && declare -F runtime_overlay_add_proven_channel >/dev/null 2>&1; then
    runtime_overlay_add_proven_channel "proxy_shell"
  fi
  if declare -F runtime_overlay_note_native_result_hook_measured_only >/dev/null 2>&1; then
    runtime_overlay_note_native_result_hook_measured_only
  fi
  if declare -F runtime_overlay_add_capability >/dev/null 2>&1; then
    runtime_overlay_add_capability "$hooks_capability"
    runtime_overlay_add_capability "cursor-mcp-hook-compact"
    runtime_overlay_add_capability "cursor-native-result-hook-compact"
    if ralph_cursor_native_shell_wrapper_want; then
      runtime_overlay_add_capability "cursor-native-shell-wrapper-compact"
    fi
  fi
  if declare -F runtime_overlay_add_warning >/dev/null 2>&1; then
    runtime_overlay_add_warning "$headless_proof_note"
    runtime_overlay_add_warning "$output_mutation_note"
    runtime_overlay_add_warning "$mcp_hook_note"
    if [[ -n "$native_result_note" ]]; then
      runtime_overlay_add_warning "$native_result_note"
    fi
    if ralph_cursor_native_shell_wrapper_want; then
      runtime_overlay_add_warning "$wrapper_note"
    fi
  fi
}

run_plan_invoke_cursor_native_hooks_prepare() {
  local requested="${RALPH_NATIVE_HOOKS:-}"
  local overlay_mode="${RALPH_OPTIMIZATION_MODE:-}"
  local headless_proof_note output_mutation_note mcp_hook_note native_result_note mcp_optimization_note wrapper_note
  headless_proof_note="Cursor native hooks on cursor-agent 2026.06.03-0bbb28e (2026-06-04): workspace .cursor/hooks.json with --workspace and --trust; preToolUse Shell input rewrite is agent-visible; postToolUse updated_mcp_tool_output is agent-visible for Ralph MCP tools on the tested headless build."
  output_mutation_note="RALPH_BASH_COMPACT is ignored for Cursor native Shell hooks: postToolUse updated_tool_output does not change agent-visible Shell output on the tested headless build."
  wrapper_note="Native Shell compaction is authoritative via preToolUse wrapper rewrite (native-shell-wrapper.sh) when RALPH_NATIVE_SHELL_WRAPPER is enabled; set RALPH_NATIVE_SHELL_WRAPPER=0 to opt out."
  mcp_hook_note="Ralph MCP proxy tools may be compacted via postToolUse updated_mcp_tool_output when RALPH_PROXY_SHELL_COMPACT=1 (or RALPH_CURSOR_MCP_HOOK_COMPACT=1); full originals remain in .ralph-workspace/tool-results/<plan-key>/."
  native_result_note="Native Read/Grep/Glob/SemanticSearch may be compacted via postToolUse updated_tool_output when RALPH_BASH_COMPACT=1 or RALPH_PROXY_SHELL_COMPACT=1 (shared envelope/store path; no proxy allowlist or timeout guards). Agent visibility of native updated_tool_output is unproven on the tested Cursor build."
  mcp_optimization_note="Cursor optimization uses Ralph MCP proxy tools; bounded and governed modes enable ralph_proxy_shell compaction by default unless RALPH_PROXY_SHELL_COMPACT=0."

  if declare -F runtime_overlay_set_native_hooks_requested >/dev/null 2>&1; then
    runtime_overlay_set_native_hooks_requested "${requested:-unset}"
  fi
  if [[ -n "$overlay_mode" ]] && declare -F runtime_overlay_set_overlay_mode >/dev/null 2>&1; then
    runtime_overlay_set_overlay_mode "$overlay_mode"
  fi

  ralph_cursor_apply_mcp_optimization_defaults

  if ! ralph_native_hooks_want_activation; then
    if declare -F runtime_overlay_set_native_hooks_effective >/dev/null 2>&1; then
      runtime_overlay_set_native_hooks_effective "false"
    fi
    return 0
  fi

  case "${RALPH_BASH_COMPACT:-}" in
    1 | true | yes | on)
      if declare -F runtime_overlay_add_warning >/dev/null 2>&1; then
        runtime_overlay_add_warning "$output_mutation_note"
      fi
      ;;
  esac

  local workspace="${WORKSPACE:-}"
  if [[ -z "$workspace" ]]; then
    if declare -F runtime_overlay_add_warning >/dev/null 2>&1; then
      runtime_overlay_add_warning "WORKSPACE is unset; cannot apply Cursor native hook overlay"
    fi
    if declare -F runtime_overlay_set_native_hooks_effective >/dev/null 2>&1; then
      runtime_overlay_set_native_hooks_effective "false"
    fi
    return 0
  fi

  local hooks_file="$workspace/.cursor/hooks.json"
  if runtime_overlay_cursor_hooks_detected_in_file "$hooks_file"; then
    ralph_cursor_record_active_native_hooks_summary \
      "cursor-hooks-detected" \
      "$headless_proof_note" \
      "$output_mutation_note" \
      "$mcp_hook_note" \
      "$wrapper_note" \
      "$native_result_note"
    return 0
  fi

  if ! command -v python3 &>/dev/null; then
    if declare -F runtime_overlay_add_warning >/dev/null 2>&1; then
      runtime_overlay_add_warning "python3 is required for Cursor native hook overlay; skipping hook merge"
    fi
    if declare -F runtime_overlay_set_native_hooks_effective >/dev/null 2>&1; then
      runtime_overlay_set_native_hooks_effective "false"
    fi
    return 0
  fi

  if [[ -f "$hooks_file" ]] && ! command -v jq &>/dev/null; then
    if declare -F runtime_overlay_add_warning >/dev/null 2>&1; then
      runtime_overlay_add_warning "jq is required to validate an existing Cursor hooks config; skipping hook merge"
    fi
    if declare -F runtime_overlay_set_native_hooks_effective >/dev/null 2>&1; then
      runtime_overlay_set_native_hooks_effective "false"
    fi
    return 0
  fi

  if ! run_plan_invoke_cursor_hooks_config_prepare; then
    if declare -F runtime_overlay_add_warning >/dev/null 2>&1; then
      runtime_overlay_add_warning "Failed to merge Ralph Cursor hooks into $hooks_file"
    fi
    if declare -F runtime_overlay_set_native_hooks_effective >/dev/null 2>&1; then
      runtime_overlay_set_native_hooks_effective "false"
    fi
    return 0
  fi

  ralph_cursor_record_active_native_hooks_summary \
    "cursor-hooks-merged" \
    "$headless_proof_note" \
    "$output_mutation_note" \
    "$mcp_hook_note" \
    "$wrapper_note" \
    "$native_result_note"

  if [[ "${RALPH_AGENT_TOOL_ACCESS:-native}" == "ralph" ]] \
    && ralph_cursor_optimization_mode_enables_mcp_proxy_compaction; then
    if declare -F runtime_overlay_add_warning >/dev/null 2>&1; then
      runtime_overlay_add_warning "$mcp_optimization_note"
    fi
  fi

  return 0
}
