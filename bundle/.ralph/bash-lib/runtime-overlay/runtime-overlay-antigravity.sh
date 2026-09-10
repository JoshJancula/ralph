#!/usr/bin/env bash
# Antigravity native hook overlay: workspace .agents/hooks.json merge and restore.

if [[ -n "${RALPH_RUNTIME_OVERLAY_ANTIGRAVITY_LOADED:-}" ]]; then
  return
fi
RALPH_RUNTIME_OVERLAY_ANTIGRAVITY_LOADED=1

_runtime_overlay_antigravity_lib_dir() {
  cd "$(dirname "${BASH_SOURCE[0]}")" && pwd
}

_runtime_overlay_antigravity_bundle_root() {
  local lib_dir
  lib_dir="$(_runtime_overlay_antigravity_lib_dir)"
  cd "$lib_dir/../../.." && pwd
}

_runtime_overlay_antigravity_template_hooks_json() {
  local bundle_root
  bundle_root="$(_runtime_overlay_antigravity_bundle_root)"
  printf '%s/.agents/hooks.json' "$bundle_root"
}

_runtime_overlay_antigravity_hooks_source_dir() {
  local bundle_root
  bundle_root="$(_runtime_overlay_antigravity_bundle_root)"
  printf '%s/.agents/hooks' "$bundle_root"
}

_runtime_overlay_antigravity_ralph_hook_script_names() {
  printf '%s\n' pre-tool-shell-policy.sh pre-tool-proxy-read-handoff.sh pre-tool-exploration-policy.sh post-tool-shell-telemetry.sh post-tool-native-result-compact.sh post-tool-mcp-compact.sh after-shell-telemetry.sh stop-continuation.sh
}

ralph_native_hooks_want_activation() {
  local mode="${RALPH_NATIVE_HOOKS:-}"
  case "$mode" in
    off) return 1 ;;
    on|auto) return 0 ;;
    *) return 1 ;;
  esac
}

runtime_overlay_antigravity_hooks_detected_in_file() {
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
    "stop-continuation.sh",
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
        for nested in entry.get("hooks") or []:
            nested_cmd = nested.get("command") or ""
            nested_base = os.path.basename(nested_cmd)
            if nested_base in required:
                found.add(nested_base)

for event in ("preToolUse", "postToolUse", "afterShellExecution", "Stop"):
    scan_entries(hooks.get(event))

if found == required:
    sys.exit(0)
sys.exit(1)
PY
}

runtime_overlay_antigravity_preserve_durable_install() {
  local hooks_file="${1:-}"
  [[ -n "$hooks_file" ]] || return 1
  runtime_overlay_antigravity_hooks_detected_in_file "$hooks_file"
}

runtime_overlay_antigravity_hook_timeout() {
  local timeout="${RALPH_BG_HOOK_TIMEOUT:-5400}"
  [[ "$timeout" =~ ^[0-9]+$ ]] || timeout=5400
  printf '%s\n' "$timeout"
}

runtime_overlay_antigravity_merge_hooks_file() {
  local target="$1"
  local template="$2"
  local include_stop="${3:-0}"
  local hook_timeout
  hook_timeout="$(runtime_overlay_antigravity_hook_timeout)"
  python3 - "$target" "$template" "$include_stop" "$hook_timeout" <<'PY'
import copy
import json
import os
import sys

target, template, include_stop_raw, hook_timeout_raw = sys.argv[1:]
include_stop = include_stop_raw == "1"
hook_timeout = int(hook_timeout_raw) if hook_timeout_raw.isdigit() else 5400

RALPH_BASES = {
    "pre-tool-shell-policy.sh",
    "post-tool-shell-telemetry.sh",
    "post-tool-mcp-compact.sh",
    "after-shell-telemetry.sh",
    "stop-continuation.sh",
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


def merge_entries(existing, template_entries, event):
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
        merged = copy.deepcopy(entry)
        if event == "Stop":
            merged["timeout"] = hook_timeout
        existing.append(merged)
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
    if event == "Stop" and not include_stop:
        continue
    hooks.setdefault(event, [])
    merge_entries(hooks[event], template_entries, event)

if not include_stop:
    hooks.pop("Stop", None)

os.makedirs(os.path.dirname(target) or ".", exist_ok=True)
with open(target, "w") as fh:
    json.dump(data, fh, indent=2)
    fh.write("\n")
PY
}

run_plan_invoke_antigravity_hooks_scripts_prepare() {
  local workspace="$1"
  local source_dir target_dir script backup_path=""
  source_dir="$(_runtime_overlay_antigravity_hooks_source_dir)"
  target_dir="$workspace/.agents/hooks"
  mkdir -p "$target_dir"

  while IFS= read -r script; do
    [[ -z "$script" ]] && continue
    if [[ ! -f "$source_dir/$script" ]]; then
      echo "Error: Ralph Antigravity hook script missing: $source_dir/$script" >&2
      return 1
    fi
    backup_path=""
    if [[ -f "$target_dir/$script" ]]; then
      if declare -F runtime_overlay_record_original_file >/dev/null 2>&1; then
        runtime_overlay_record_original_file "$target_dir/$script" backup_path 1
      else
        backup_path="$(mktemp "${TMPDIR:-/tmp}/ralph-antigravity-hook-script-backup-XXXXXX")"
        cp "$target_dir/$script" "$backup_path"
      fi
    else
      if declare -F ralph_mcp_overlay_record_workspace_mutation >/dev/null 2>&1; then
        ralph_mcp_overlay_record_workspace_mutation "$target_dir/$script" 0
      fi
    fi
    ANTIGRAVITY_PLAN_HOOKS_SCRIPT_TARGETS+=("$target_dir/$script")
    ANTIGRAVITY_PLAN_HOOKS_SCRIPT_BACKUPS+=("$backup_path")
    if ! cp "$source_dir/$script" "$target_dir/$script"; then
      echo "Error: failed to install Antigravity hook script $target_dir/$script" >&2
      return 1
    fi
    chmod +x "$target_dir/$script" 2>/dev/null || true
  done < <(_runtime_overlay_antigravity_ralph_hook_script_names)
  return 0
}

run_plan_invoke_antigravity_hooks_config_cleanup() {
  local target="${ANTIGRAVITY_PLAN_HOOKS_CONFIG_TARGET:-}"
  local idx backup script_target

  if [[ -n "$target" ]] && runtime_overlay_antigravity_preserve_durable_install "$target"; then
    if declare -F runtime_overlay_forget_recorded_file >/dev/null 2>&1; then
      runtime_overlay_forget_recorded_file "$target"
      if [[ "${ANTIGRAVITY_PLAN_HOOKS_SCRIPT_TARGETS+set}" == "set" && "${#ANTIGRAVITY_PLAN_HOOKS_SCRIPT_TARGETS[@]}" -gt 0 ]]; then
        for ((idx = 0; idx < ${#ANTIGRAVITY_PLAN_HOOKS_SCRIPT_TARGETS[@]}; idx++)); do
          runtime_overlay_forget_recorded_file "${ANTIGRAVITY_PLAN_HOOKS_SCRIPT_TARGETS[idx]}"
        done
      fi
    fi
    unset ANTIGRAVITY_PLAN_HOOKS_CONFIG_TARGET
    unset ANTIGRAVITY_PLAN_HOOKS_CONFIG_BACKUP
    unset ANTIGRAVITY_PLAN_HOOKS_CONFIG_HAD_FILE
    unset ANTIGRAVITY_PLAN_NATIVE_HOOKS_ACTIVE
    ANTIGRAVITY_PLAN_HOOKS_SCRIPT_TARGETS=()
    ANTIGRAVITY_PLAN_HOOKS_SCRIPT_BACKUPS=()
    return 0
  fi

  if [[ -n "$target" ]]; then
    if [[ "${ANTIGRAVITY_PLAN_HOOKS_CONFIG_HAD_FILE:-0}" == "1" ]]; then
      if [[ -n "${ANTIGRAVITY_PLAN_HOOKS_CONFIG_BACKUP:-}" && -f "$ANTIGRAVITY_PLAN_HOOKS_CONFIG_BACKUP" ]]; then
        cp "$ANTIGRAVITY_PLAN_HOOKS_CONFIG_BACKUP" "$target" 2>/dev/null || true
        if ! ralph_mcp_overlay_lifecycle_available; then
          rm -f "$ANTIGRAVITY_PLAN_HOOKS_CONFIG_BACKUP" 2>/dev/null || true
        fi
      fi
    else
      rm -f "$target" 2>/dev/null || true
    fi
  fi

  if [[ "${ANTIGRAVITY_PLAN_HOOKS_SCRIPT_TARGETS+set}" == "set" && "${#ANTIGRAVITY_PLAN_HOOKS_SCRIPT_TARGETS[@]}" -gt 0 ]]; then
    for ((idx = 0; idx < ${#ANTIGRAVITY_PLAN_HOOKS_SCRIPT_TARGETS[@]}; idx++)); do
      script_target="${ANTIGRAVITY_PLAN_HOOKS_SCRIPT_TARGETS[idx]}"
      backup="${ANTIGRAVITY_PLAN_HOOKS_SCRIPT_BACKUPS[idx]:-}"
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

  unset ANTIGRAVITY_PLAN_HOOKS_CONFIG_TARGET
  unset ANTIGRAVITY_PLAN_HOOKS_CONFIG_BACKUP
  unset ANTIGRAVITY_PLAN_HOOKS_CONFIG_HAD_FILE
  unset ANTIGRAVITY_PLAN_NATIVE_HOOKS_ACTIVE
  ANTIGRAVITY_PLAN_HOOKS_SCRIPT_TARGETS=()
  ANTIGRAVITY_PLAN_HOOKS_SCRIPT_BACKUPS=()
}

run_plan_invoke_antigravity_hooks_config_prepare() {
  local workspace="${WORKSPACE:-}"
  local target had_file=0 template backup_path="" include_stop=0

  if [[ -z "$workspace" ]]; then
    echo "Error: WORKSPACE is required for Antigravity native hook overlay." >&2
    return 1
  fi

  template="$(_runtime_overlay_antigravity_template_hooks_json)"
  if [[ ! -f "$template" ]]; then
    echo "Error: Ralph Antigravity hooks template missing at $template" >&2
    return 1
  fi

  target="$workspace/.agents/hooks.json"
  mkdir -p "$(dirname "$target")"

  if [[ -f "$target" ]]; then
    had_file=1
    if ! command -v jq &>/dev/null; then
      echo "Error: jq is required to validate an existing Antigravity hooks config." >&2
      return 1
    fi
    if ! jq empty "$target" >/dev/null 2>&1; then
      echo "Error: existing Antigravity hooks config is invalid JSON: $target" >&2
      return 1
    fi
    if ralph_mcp_overlay_lifecycle_available; then
      runtime_overlay_record_original_file "$target" backup_path
      ANTIGRAVITY_PLAN_HOOKS_CONFIG_BACKUP="$backup_path"
    else
      ANTIGRAVITY_PLAN_HOOKS_CONFIG_BACKUP="$(mktemp "${TMPDIR:-/tmp}/ralph-antigravity-hooks-backup-XXXXXX")"
      cp "$target" "$ANTIGRAVITY_PLAN_HOOKS_CONFIG_BACKUP"
    fi
  fi

  if declare -F ralph_bg_tier_stop_hook_enabled >/dev/null 2>&1 && ralph_bg_tier_stop_hook_enabled; then
    include_stop=1
  fi

  if ! runtime_overlay_antigravity_merge_hooks_file "$target" "$template" "$include_stop"; then
    echo "Error: failed to merge Ralph Antigravity hooks into $target" >&2
    return 1
  fi

  ANTIGRAVITY_PLAN_HOOKS_SCRIPT_TARGETS=()
  ANTIGRAVITY_PLAN_HOOKS_SCRIPT_BACKUPS=()
  export ANTIGRAVITY_PLAN_HOOKS_SCRIPT_TARGETS ANTIGRAVITY_PLAN_HOOKS_SCRIPT_BACKUPS
  if ! run_plan_invoke_antigravity_hooks_scripts_prepare "$workspace"; then
    return 1
  fi

  if [[ "$had_file" != "1" ]] && declare -F ralph_mcp_overlay_record_workspace_mutation >/dev/null 2>&1; then
    ralph_mcp_overlay_record_workspace_mutation "$target" 0
  fi

  ANTIGRAVITY_PLAN_HOOKS_CONFIG_TARGET="$target"
  ANTIGRAVITY_PLAN_HOOKS_CONFIG_HAD_FILE="$had_file"
  ANTIGRAVITY_PLAN_NATIVE_HOOKS_ACTIVE=1
  export ANTIGRAVITY_PLAN_HOOKS_CONFIG_TARGET ANTIGRAVITY_PLAN_HOOKS_CONFIG_HAD_FILE ANTIGRAVITY_PLAN_NATIVE_HOOKS_ACTIVE
  [[ -n "${ANTIGRAVITY_PLAN_HOOKS_CONFIG_BACKUP:-}" ]] && export ANTIGRAVITY_PLAN_HOOKS_CONFIG_BACKUP

  ralph_mcp_overlay_register_runtime_cleanup run_plan_invoke_antigravity_hooks_config_cleanup
  return 0
}

run_plan_invoke_antigravity_native_hooks_cleanup() {
  run_plan_invoke_antigravity_hooks_config_cleanup
}

ralph_antigravity_record_active_native_hooks_summary() {
  local hooks_capability="$1"
  local headless_proof_note="$2"

  if declare -F runtime_overlay_set_native_hooks_effective >/dev/null 2>&1; then
    runtime_overlay_set_native_hooks_effective "true"
  fi
  if declare -F runtime_overlay_set_native_hooks_reason >/dev/null 2>&1; then
    runtime_overlay_set_native_hooks_reason "headless_hooks_proven"
  fi
  if declare -F runtime_overlay_set_native_hooks_configured >/dev/null 2>&1; then
    runtime_overlay_set_native_hooks_configured "true"
  fi
  if declare -F runtime_overlay_set_fallback_path_active >/dev/null 2>&1; then
    runtime_overlay_set_fallback_path_active "false"
  fi
  if declare -F runtime_overlay_add_capability >/dev/null 2>&1; then
    runtime_overlay_add_capability "$hooks_capability"
  fi
  if declare -F runtime_overlay_add_warning >/dev/null 2>&1; then
    runtime_overlay_add_warning "$headless_proof_note"
  fi
}

run_plan_invoke_antigravity_native_hooks_prepare() {
  local requested="${RALPH_NATIVE_HOOKS:-}"
  local tooling_profile="${RALPH_MODE:-}"
  local headless_proof_note

  headless_proof_note="Antigravity native hooks: workspace .agents/hooks.json; Stop emits decision:continue with reason; default hook timeout is 30s and must be overridden via RALPH_BG_HOOK_TIMEOUT; loop protection relies on RALPH_BG_MAX_PER_TODO in stop-continuation-hook.sh."

  if declare -F runtime_overlay_set_native_hooks_requested >/dev/null 2>&1; then
    runtime_overlay_set_native_hooks_requested "${requested:-unset}"
  fi
  if [[ -n "$tooling_profile" ]] && declare -F runtime_overlay_set_overlay_mode >/dev/null 2>&1; then
    runtime_overlay_set_overlay_mode "$tooling_profile"
  fi

  if ! ralph_native_hooks_want_activation; then
    if declare -F runtime_overlay_set_native_hooks_effective >/dev/null 2>&1; then
      runtime_overlay_set_native_hooks_effective "false"
    fi
    return 0
  fi

  local workspace="${WORKSPACE:-}"
  if [[ -z "$workspace" ]]; then
    if declare -F runtime_overlay_add_warning >/dev/null 2>&1; then
      runtime_overlay_add_warning "WORKSPACE is unset; cannot apply Antigravity native hook overlay"
    fi
    if declare -F runtime_overlay_set_native_hooks_effective >/dev/null 2>&1; then
      runtime_overlay_set_native_hooks_effective "false"
    fi
    return 0
  fi

  local hooks_file="$workspace/.agents/hooks.json"
  if runtime_overlay_antigravity_hooks_detected_in_file "$hooks_file"; then
    ralph_antigravity_record_active_native_hooks_summary "antigravity-hooks-detected" "$headless_proof_note"
    return 0
  fi

  if ! command -v python3 &>/dev/null; then
    if declare -F runtime_overlay_add_warning >/dev/null 2>&1; then
      runtime_overlay_add_warning "python3 is required for Antigravity native hook overlay; skipping hook merge"
    fi
    if declare -F runtime_overlay_set_native_hooks_effective >/dev/null 2>&1; then
      runtime_overlay_set_native_hooks_effective "false"
    fi
    return 0
  fi

  if [[ -f "$hooks_file" ]] && ! command -v jq &>/dev/null; then
    if declare -F runtime_overlay_add_warning >/dev/null 2>&1; then
      runtime_overlay_add_warning "jq is required to validate an existing Antigravity hooks config; skipping hook merge"
    fi
    if declare -F runtime_overlay_set_native_hooks_effective >/dev/null 2>&1; then
      runtime_overlay_set_native_hooks_effective "false"
    fi
    return 0
  fi

  if ! run_plan_invoke_antigravity_hooks_config_prepare; then
    if declare -F runtime_overlay_add_warning >/dev/null 2>&1; then
      runtime_overlay_add_warning "Failed to merge Ralph Antigravity hooks into $hooks_file"
    fi
    if declare -F runtime_overlay_set_native_hooks_effective >/dev/null 2>&1; then
      runtime_overlay_set_native_hooks_effective "false"
    fi
    return 0
  fi

  ralph_antigravity_record_active_native_hooks_summary "antigravity-hooks-merged" "$headless_proof_note"
  return 0
}
