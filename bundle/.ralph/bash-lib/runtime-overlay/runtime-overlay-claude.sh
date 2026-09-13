#!/usr/bin/env bash
# Claude native hook overlay: detect, merge, and restore project .claude/settings.json hooks.

if [[ -n "${RALPH_RUNTIME_OVERLAY_CLAUDE_LOADED:-}" ]]; then
  return
fi
RALPH_RUNTIME_OVERLAY_CLAUDE_LOADED=1

_runtime_overlay_claude_lib_dir() {
  cd "$(dirname "${BASH_SOURCE[0]}")" && pwd
}

_runtime_overlay_claude_bundle_settings_path() {
  local lib_dir bundle_root
  lib_dir="$(_runtime_overlay_claude_lib_dir)"
  bundle_root="$(cd "$lib_dir/../../.." && pwd)"
  printf '%s/.claude/settings.json' "$bundle_root"
}

ralph_native_hooks_want_activation() {
  local mode="${RALPH_NATIVE_HOOKS:-}"
  case "$mode" in
    off) return 1 ;;
    on|auto) return 0 ;;
    *) return 1 ;;
  esac
}

runtime_overlay_claude_settings_candidates() {
  local workspace="${WORKSPACE:-}"
  if [[ -z "$workspace" ]]; then
    return 0
  fi
  printf '%s/.claude/settings.json\n' "$workspace"
  if [[ -d "$workspace/bundle/.claude" ]]; then
    printf '%s/bundle/.claude/settings.json\n' "$workspace"
  fi
}

runtime_overlay_claude_hooks_detected_in_file() {
  local settings_file="$1"
  if [[ ! -f "$settings_file" ]]; then
    return 1
  fi
  if ! command -v python3 &>/dev/null; then
    return 1
  fi
  python3 - "$settings_file" <<'PY'
import json, sys

path = sys.argv[1]
try:
    with open(path) as fh:
        data = json.load(fh)
except (OSError, json.JSONDecodeError):
    sys.exit(1)

hooks = data.get("hooks") or {}

def group_commands(event, matcher):
    out = []
    for group in hooks.get(event) or []:
        if group.get("matcher") != matcher:
            continue
        for entry in group.get("hooks") or []:
            cmd = entry.get("command") or ""
            if cmd:
                out.append(cmd)
    return out

def has_cmd(commands, needle):
    return any(needle in cmd or cmd.endswith(needle) for cmd in commands)

pre = hooks.get("PreToolUse") or []
post = hooks.get("PostToolUse") or []
_ = pre, post

env_cmds = group_commands("PreToolUse", "Read|Edit|MultiEdit|Glob|Grep|LS")
bash_pre = group_commands("PreToolUse", "Bash")
bash_post = group_commands("PostToolUse", "Bash")
exploration_post = group_commands("PostToolUse", "Read|Grep|Glob")
stop_cmds = []
for group in hooks.get("Stop") or []:
    for entry in group.get("hooks") or []:
        cmd = entry.get("command") or ""
        if cmd:
            stop_cmds.append(cmd)

if not has_cmd(env_cmds, "block-env-reads.sh"):
    sys.exit(1)
if not has_cmd(bash_pre, "rewrite-bash-command.sh"):
    sys.exit(1)
if not has_cmd(bash_post, "compact-bash-output.sh"):
    sys.exit(1)
if not (
    has_cmd(exploration_post, "native-result-compact.sh")
    or has_cmd(exploration_post, "compact-native-result-output.sh")
):
    sys.exit(1)
if not has_cmd(stop_cmds, "stop-continuation.sh"):
    sys.exit(1)
sys.exit(0)
PY
}

runtime_overlay_claude_preserve_durable_install() {
  local target="${1:-}"
  [[ -n "$target" ]] || return 1
  runtime_overlay_claude_hooks_detected_in_file "$target"
}

runtime_overlay_claude_find_installed_hooks() {
  local candidate
  while IFS= read -r candidate; do
    [[ -z "$candidate" ]] && continue
    if runtime_overlay_claude_hooks_detected_in_file "$candidate"; then
      printf '%s' "$candidate"
      return 0
    fi
  done < <(runtime_overlay_claude_settings_candidates)
  return 1
}

runtime_overlay_claude_hook_timeout() {
  local timeout="${RALPH_BG_HOOK_TIMEOUT:-5400}"
  [[ "$timeout" =~ ^[0-9]+$ ]] || timeout=5400
  printf '%s\n' "$timeout"
}

runtime_overlay_claude_merge_settings_file() {
  local target="$1"
  local template="$2"
  local include_stop="${3:-0}"
  local hook_timeout
  hook_timeout="$(runtime_overlay_claude_hook_timeout)"
  python3 - "$target" "$template" "$include_stop" "$hook_timeout" <<'PY'
import json, os, sys

target, template, include_stop_raw, hook_timeout_raw = sys.argv[1:]
include_stop = include_stop_raw == "1"
hook_timeout = int(hook_timeout_raw) if hook_timeout_raw.isdigit() else 5400

def load_json(path):
    if not os.path.isfile(path):
        return {}
    with open(path) as fh:
        return json.load(fh)

data = load_json(target)
with open(template) as fh:
    template_data = json.load(fh)

template_hooks = template_data.get("hooks") or {}
hooks = data.setdefault("hooks", {})

for event, groups in template_hooks.items():
    if event == "Stop" and not include_stop:
        continue
    hooks.setdefault(event, [])
    for tpl_group in groups:
        matcher = tpl_group.get("matcher")
        tpl_entries = tpl_group.get("hooks") or []
        existing = None
        for group in hooks[event]:
            if group.get("matcher") == matcher:
                existing = group
                break
        if existing is None:
            merged_group = json.loads(json.dumps(tpl_group))
            if event == "Stop":
                for entry in merged_group.get("hooks") or []:
                    entry["timeout"] = hook_timeout
            hooks[event].append(merged_group)
            continue
        existing.setdefault("hooks", [])
        existing_cmds = {
            (entry.get("command") or "")
            for entry in existing["hooks"]
        }
        for entry in tpl_entries:
            cmd = entry.get("command") or ""
            merged_entry = json.loads(json.dumps(entry))
            if event == "Stop":
                merged_entry["timeout"] = hook_timeout
            if cmd in existing_cmds:
                continue
            if any(cmd.endswith(os.path.basename(c)) for c in existing_cmds if c):
                continue
            existing["hooks"].append(merged_entry)

os.makedirs(os.path.dirname(target) or ".", exist_ok=True)
with open(target, "w") as fh:
    json.dump(data, fh, indent=2)
    fh.write("\n")
PY
}

runtime_overlay_claude_export_stop_hook_env() {
  local max_per_todo="${RALPH_BG_MAX_PER_TODO:-8}"
  [[ "$max_per_todo" =~ ^[0-9]+$ ]] || max_per_todo=8
  export CLAUDE_CODE_STOP_HOOK_BLOCK_CAP="$max_per_todo"
}

run_plan_invoke_claude_native_hooks_cleanup() {
  local target="${CLAUDE_PLAN_HOOKS_SETTINGS_TARGET:-}"
  if [[ -z "$target" ]]; then
    return 0
  fi
  if [[ "${CLAUDE_PLAN_HOOKS_SETTINGS_MUTATED:-0}" != "1" ]]; then
    unset CLAUDE_PLAN_HOOKS_SETTINGS_TARGET CLAUDE_PLAN_HOOKS_SETTINGS_BACKUP CLAUDE_PLAN_HOOKS_SETTINGS_MUTATED
    return 0
  fi
  if runtime_overlay_claude_preserve_durable_install "$target"; then
    if declare -F runtime_overlay_forget_recorded_file >/dev/null 2>&1; then
      runtime_overlay_forget_recorded_file "$target"
    fi
    unset CLAUDE_PLAN_HOOKS_SETTINGS_TARGET CLAUDE_PLAN_HOOKS_SETTINGS_BACKUP CLAUDE_PLAN_HOOKS_SETTINGS_MUTATED
    return 0
  fi
  if [[ -n "${CLAUDE_PLAN_HOOKS_SETTINGS_BACKUP:-}" && -f "$CLAUDE_PLAN_HOOKS_SETTINGS_BACKUP" ]]; then
    if [[ -s "$CLAUDE_PLAN_HOOKS_SETTINGS_BACKUP" ]]; then
      cp "$CLAUDE_PLAN_HOOKS_SETTINGS_BACKUP" "$target" 2>/dev/null || true
    else
      rm -f "$target" 2>/dev/null || true
    fi
  fi
  unset CLAUDE_PLAN_HOOKS_SETTINGS_TARGET CLAUDE_PLAN_HOOKS_SETTINGS_BACKUP CLAUDE_PLAN_HOOKS_SETTINGS_MUTATED
}

run_plan_invoke_claude_native_hooks_prepare() {
  local requested="${RALPH_NATIVE_HOOKS:-}"
  local tooling_profile="${RALPH_MODE:-}"

  if declare -F runtime_overlay_set_native_hooks_requested >/dev/null 2>&1; then
    runtime_overlay_set_native_hooks_requested "${requested:-unset}"
  fi
  if [[ -n "$tooling_profile" ]] && declare -F runtime_overlay_set_overlay_mode >/dev/null 2>&1; then
    runtime_overlay_set_overlay_mode "$tooling_profile"
  fi

  if [[ "${CLAUDE_PLAN_BARE:-0}" == "1" ]]; then
    local bare_reason="CLAUDE_PLAN_BARE=1 skips Claude project settings and native hooks per upstream --bare semantics"
    if declare -F runtime_overlay_set_native_hooks_effective >/dev/null 2>&1; then
      runtime_overlay_set_native_hooks_effective "false"
    fi
    if declare -F runtime_overlay_add_warning >/dev/null 2>&1; then
      runtime_overlay_add_warning "$bare_reason"
    fi
    if declare -F runtime_overlay_add_capability >/dev/null 2>&1; then
      runtime_overlay_add_capability "claude-hooks-skipped-bare"
    fi
    return 0
  fi

  if ! ralph_native_hooks_want_activation; then
    if declare -F runtime_overlay_set_native_hooks_effective >/dev/null 2>&1; then
      runtime_overlay_set_native_hooks_effective "false"
    fi
    return 0
  fi

  if ! command -v python3 &>/dev/null; then
    if declare -F runtime_overlay_add_warning >/dev/null 2>&1; then
      runtime_overlay_add_warning "python3 is required for Claude native hook overlay; skipping hook merge"
    fi
    if declare -F runtime_overlay_set_native_hooks_effective >/dev/null 2>&1; then
      runtime_overlay_set_native_hooks_effective "false"
    fi
    return 0
  fi

  local workspace="${WORKSPACE:-}"
  if [[ -z "$workspace" ]]; then
    if declare -F runtime_overlay_add_warning >/dev/null 2>&1; then
      runtime_overlay_add_warning "WORKSPACE is unset; cannot apply Claude native hook overlay"
    fi
    if declare -F runtime_overlay_set_native_hooks_effective >/dev/null 2>&1; then
      runtime_overlay_set_native_hooks_effective "false"
    fi
    return 0
  fi

  local installed_path=""
  if installed_path="$(runtime_overlay_claude_find_installed_hooks)"; then
    if declare -F runtime_overlay_set_native_hooks_configured >/dev/null 2>&1; then
      runtime_overlay_set_native_hooks_configured "true"
    fi
    if declare -F runtime_overlay_set_native_hooks_effective >/dev/null 2>&1; then
      runtime_overlay_set_native_hooks_effective "true"
    fi
    if declare -F runtime_overlay_set_native_hooks_reason >/dev/null 2>&1; then
      runtime_overlay_set_native_hooks_reason "headless_hooks_proven"
    fi
    if declare -F runtime_overlay_set_native_output_mutation_proven >/dev/null 2>&1; then
      runtime_overlay_set_native_output_mutation_proven "true"
    fi
    if declare -F runtime_overlay_set_native_shell_wrapper_enabled >/dev/null 2>&1; then
      runtime_overlay_set_native_shell_wrapper_enabled "false"
    fi
    if declare -F runtime_overlay_set_native_shell_wrapper_effective >/dev/null 2>&1; then
      runtime_overlay_set_native_shell_wrapper_effective "false"
    fi
    if declare -F runtime_overlay_set_native_shell_compaction_authoritative >/dev/null 2>&1; then
      runtime_overlay_set_native_shell_compaction_authoritative "true_post_tool_mutation"
    fi
    if declare -F runtime_overlay_set_fallback_path_active >/dev/null 2>&1; then
      runtime_overlay_set_fallback_path_active "false"
    fi
    if declare -F runtime_overlay_note_native_shell_hook_proven >/dev/null 2>&1; then
      runtime_overlay_note_native_shell_hook_proven
    fi
    if declare -F runtime_overlay_note_native_result_hook_proven >/dev/null 2>&1; then
      runtime_overlay_note_native_result_hook_proven
    fi
    if declare -F runtime_overlay_add_capability >/dev/null 2>&1; then
      runtime_overlay_add_capability "claude-hooks-detected"
    fi
    if declare -F runtime_overlay_log_decision >/dev/null 2>&1; then
      runtime_overlay_log_decision "claude_hooks_source" "$installed_path"
    fi
    # Durable installs still need the Stop-hook block-cap export when tier-1
    # continuation is selected; merge is skipped but the env must be present.
    if declare -F ralph_bg_tier_stop_hook_enabled >/dev/null 2>&1 && ralph_bg_tier_stop_hook_enabled; then
      runtime_overlay_claude_export_stop_hook_env
    fi
    return 0
  fi

  local target="$workspace/.claude/settings.json"
  local template
  template="$(_runtime_overlay_claude_bundle_settings_path)"
  local include_stop=0
  if declare -F ralph_bg_tier_stop_hook_enabled >/dev/null 2>&1 && ralph_bg_tier_stop_hook_enabled; then
    include_stop=1
    runtime_overlay_claude_export_stop_hook_env
  fi
  if [[ ! -f "$template" ]]; then
    if declare -F runtime_overlay_add_warning >/dev/null 2>&1; then
      runtime_overlay_add_warning "Ralph Claude hook template missing at $template"
    fi
    if declare -F runtime_overlay_set_native_hooks_effective >/dev/null 2>&1; then
      runtime_overlay_set_native_hooks_effective "false"
    fi
    return 0
  fi

  mkdir -p "$(dirname "$target")"
  local backup_path=""
  if declare -F runtime_overlay_record_original_file >/dev/null 2>&1; then
    runtime_overlay_record_original_file "$target" backup_path 1
  elif [[ -f "$target" ]]; then
    backup_path="$(mktemp "${TMPDIR:-/tmp}/ralph-claude-settings-backup-XXXXXX")"
    cp "$target" "$backup_path"
  else
    backup_path="$(mktemp "${TMPDIR:-/tmp}/ralph-claude-settings-backup-XXXXXX")"
    : >"$backup_path"
  fi

  if ! runtime_overlay_claude_merge_settings_file "$target" "$template" "$include_stop"; then
    if declare -F runtime_overlay_add_warning >/dev/null 2>&1; then
      runtime_overlay_add_warning "Failed to merge Claude hook settings into $target"
    fi
    if declare -F runtime_overlay_set_native_hooks_effective >/dev/null 2>&1; then
      runtime_overlay_set_native_hooks_effective "false"
    fi
    return 0
  fi

  CLAUDE_PLAN_HOOKS_SETTINGS_TARGET="$target"
  CLAUDE_PLAN_HOOKS_SETTINGS_BACKUP="$backup_path"
  CLAUDE_PLAN_HOOKS_SETTINGS_MUTATED=1
  export CLAUDE_PLAN_HOOKS_SETTINGS_TARGET CLAUDE_PLAN_HOOKS_SETTINGS_BACKUP CLAUDE_PLAN_HOOKS_SETTINGS_MUTATED

  if declare -F runtime_overlay_set_native_hooks_configured >/dev/null 2>&1; then
    runtime_overlay_set_native_hooks_configured "true"
  fi
  if declare -F runtime_overlay_set_native_hooks_effective >/dev/null 2>&1; then
    runtime_overlay_set_native_hooks_effective "true"
  fi
  if declare -F runtime_overlay_set_native_hooks_reason >/dev/null 2>&1; then
    runtime_overlay_set_native_hooks_reason "headless_hooks_proven"
  fi
  if declare -F runtime_overlay_set_native_output_mutation_proven >/dev/null 2>&1; then
    runtime_overlay_set_native_output_mutation_proven "true"
  fi
  if declare -F runtime_overlay_set_native_shell_wrapper_enabled >/dev/null 2>&1; then
    runtime_overlay_set_native_shell_wrapper_enabled "false"
  fi
  if declare -F runtime_overlay_set_native_shell_wrapper_effective >/dev/null 2>&1; then
    runtime_overlay_set_native_shell_wrapper_effective "false"
  fi
  if declare -F runtime_overlay_set_native_shell_compaction_authoritative >/dev/null 2>&1; then
    runtime_overlay_set_native_shell_compaction_authoritative "true_post_tool_mutation"
  fi
  if declare -F runtime_overlay_set_fallback_path_active >/dev/null 2>&1; then
    runtime_overlay_set_fallback_path_active "false"
  fi
  if declare -F runtime_overlay_note_native_shell_hook_proven >/dev/null 2>&1; then
    runtime_overlay_note_native_shell_hook_proven
  fi
  if declare -F runtime_overlay_note_native_result_hook_proven >/dev/null 2>&1; then
    runtime_overlay_note_native_result_hook_proven
  fi
  if declare -F runtime_overlay_add_capability >/dev/null 2>&1; then
    runtime_overlay_add_capability "claude-hooks-merged"
  fi
  if declare -F ralph_mcp_overlay_register_runtime_cleanup >/dev/null 2>&1; then
    ralph_mcp_overlay_register_runtime_cleanup run_plan_invoke_claude_native_hooks_cleanup
  fi
  return 0
}
