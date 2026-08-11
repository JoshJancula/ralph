# shellcheck shell=bash
#
# Shared runtime overlay lifecycle helpers for Ralph plan runs. These helpers are
# responsible for creating per-plan overlay state, tracking generated/mutated files,
# capturing original files for restoration, registering cleanup callbacks, logging
# overlay decisions, and producing a JSON summary for dashboard/metrics ingestion.

RUNTIME_OVERLAY_STATE_DIR=""
RUNTIME_OVERLAY_ORIGINALS_DIR=""
RUNTIME_OVERLAY_SUMMARY_RUNTIME=""
RUNTIME_OVERLAY_SUMMARY_PLAN_KEY=""
RUNTIME_OVERLAY_SUMMARY_TOOL_ACCESS_MODE=""
RUNTIME_OVERLAY_SUMMARY_NATIVE_HOOKS_REQUESTED=""
RUNTIME_OVERLAY_SUMMARY_NATIVE_HOOKS_CONFIGURED=""
RUNTIME_OVERLAY_SUMMARY_NATIVE_HOOK_EVENTS=""
RUNTIME_OVERLAY_SUMMARY_NATIVE_HOOKS_OBSERVED_EFFECT=""
RUNTIME_OVERLAY_SUMMARY_NATIVE_HOOKS_OBSERVED_REASON=""
RUNTIME_OVERLAY_SUMMARY_NATIVE_HOOKS_EFFECTIVE=""
RUNTIME_OVERLAY_SUMMARY_NATIVE_HOOKS_REASON=""
RUNTIME_OVERLAY_SUMMARY_NATIVE_HOOKS_USED_ON_RUN=""
RUNTIME_OVERLAY_SUMMARY_NATIVE_OUTPUT_MUTATION_PROVEN=""
RUNTIME_OVERLAY_SUMMARY_NATIVE_SHELL_WRAPPER_ENABLED=""
RUNTIME_OVERLAY_SUMMARY_NATIVE_SHELL_WRAPPER_EFFECTIVE=""
RUNTIME_OVERLAY_SUMMARY_NATIVE_SHELL_WRAPPER_REASON=""
RUNTIME_OVERLAY_SUMMARY_NATIVE_SHELL_COMPACTION_AUTHORITATIVE=""
RUNTIME_OVERLAY_SUMMARY_FALLBACK_PATH_ACTIVE=""
RUNTIME_OVERLAY_SUMMARY_MCP_EFFECTIVE=""
RUNTIME_OVERLAY_SUMMARY_MCP_CONFIG_SOURCES=""
RUNTIME_OVERLAY_SUMMARY_MCP_EFFECTIVE_NAMES=""
RUNTIME_OVERLAY_SUMMARY_MCP_OVERRIDE_DECISIONS=""
RUNTIME_OVERLAY_SUMMARY_MCP_FAILURE_REASON=""
RUNTIME_OVERLAY_SUMMARY_PROXY_SHELL_COMPACT_EFFECTIVE=""
RUNTIME_OVERLAY_SUMMARY_CACHE_KEY_INJECTED=""
RUNTIME_OVERLAY_SUMMARY_CACHE_KEY_INJECTED_PROVIDER_ID=""
RUNTIME_OVERLAY_SUMMARY_OVERLAY_MODE=""
RUNTIME_OVERLAY_GENERATED_FILES=()
RUNTIME_OVERLAY_MUTATED_FILES=()
RUNTIME_OVERLAY_WARNINGS=()
RUNTIME_OVERLAY_CAPABILITIES=()
RUNTIME_OVERLAY_NATIVE_OPTIMIZATION_PROVEN_CHANNELS=()
RUNTIME_OVERLAY_FALLBACK_CHANNELS_ACTIVE=()
RUNTIME_OVERLAY_EXTERNAL_TEMP_FILES=()
RUNTIME_OVERLAY_CLEANUP_CMDS=()
RUNTIME_OVERLAY_JOURNAL_DIR=""
RUNTIME_OVERLAY_JOURNAL_FILE=""

runtime_overlay_die() {
  local message="$1"
  local code="${2:-1}"
  if declare -F ralph_die >/dev/null; then
    ralph_die "$message" "$code"
  fi
  printf '%s\n' "$message" >&2
  exit "$code"
}

runtime_overlay_log() {
  local message="$1"
  if declare -F ralph_run_plan_log >/dev/null; then
    ralph_run_plan_log "$message"
  else
    printf '%s\n' "$message" >&2
  fi
}

_runtime_overlay_workspace_root() {
  local root="${RALPH_PLAN_WORKSPACE_ROOT:-${WORKSPACE:-}}"
  if [[ -z "$root" ]]; then
    root="$PWD"
  fi
  if [[ -d "$root" ]]; then
    root="$(cd "$root" && pwd)"
  else
    local parent
    parent="$(dirname "$root")"
    if [[ -d "$parent" ]]; then
      root="$(cd "$parent" && printf '%s/%s' "$PWD" "$(basename "$root")")"
    else
      root="$(cd "$PWD" && pwd)"
    fi
  fi
  printf '%s' "$root"
}

# Project tree root for overlay path bounds (.cursor, .claude, etc.). Distinct from
# RALPH_PLAN_WORKSPACE_ROOT, which scopes logs and runtime-config under .ralph-workspace/.
_runtime_overlay_project_root() {
  local root="${RALPH_PROJECT_ROOT:-${WORKSPACE:-}}"
  if [[ -z "$root" ]]; then
    root="$(_runtime_overlay_workspace_root)"
  fi
  if [[ -d "$root" ]]; then
    root="$(cd "$root" && pwd)"
  else
    local parent
    parent="$(dirname "$root")"
    if [[ -d "$parent" ]]; then
      root="$(cd "$parent" && printf '%s/%s' "$PWD" "$(basename "$root")")"
    else
      root="$(cd "$PWD" && pwd)"
    fi
  fi
  printf '%s' "$root"
}

_runtime_overlay_state_root() {
  local plan_key="${1:-${RALPH_PLAN_KEY:-${RUNTIME_OVERLAY_SUMMARY_PLAN_KEY:-}}}"
  if [[ -z "$plan_key" ]]; then
    runtime_overlay_die "Runtime overlay requires RALPH_PLAN_KEY to establish state."
  fi
  local state_root
  if [[ -n "${RALPH_PLAN_WORKSPACE_ROOT:-}" ]]; then
    state_root="$(_runtime_overlay_workspace_root)"
  else
    state_root="$(_runtime_overlay_project_root)/.ralph-workspace"
  fi
  printf '%s/runtime-config/%s' "$state_root" "$plan_key"
}

_runtime_overlay_abs_path() {
  local target="$1"
  if [[ -z "$target" ]]; then
    runtime_overlay_die "Runtime overlay path cannot be empty."
  fi
  python3 - "$target" <<'PY'
import os, sys
print(os.path.abspath(sys.argv[1]))
PY
}

_runtime_overlay_require_workspace_bound() {
  local target="$1"
  local workspace_root
  workspace_root="$(_runtime_overlay_mutation_root_for_target "$target" 2>/dev/null || true)"
  if [[ -z "$workspace_root" ]]; then
    runtime_overlay_die "Overlay mutation rejected: $target is outside the project and agent workspaces."
  fi
}

# Runtime-native config normally belongs to the project root, while a graph
# snapshot may also need a temporary runtime plugin/package overlay inside the
# isolated agent workspace. Resolve the narrowest authorized root for a target
# without treating the state root as mutable project space.
_runtime_overlay_mutation_root_for_target() {
  local target="$1"
  local project_root agent_root candidate
  project_root="$(_runtime_overlay_project_root)"
  agent_root="${RALPH_AGENT_WORKSPACE:-}"
  for candidate in "$project_root" "$agent_root"; do
    [[ -n "$candidate" ]] || continue
    if [[ -d "$candidate" ]]; then
      candidate="$(cd "$candidate" && pwd)"
    fi
    if python3 - "$candidate" "$target" <<'PY'
import os, sys
workspace = os.path.abspath(sys.argv[1])
target = os.path.abspath(sys.argv[2])
if workspace == "" or target == "":
    sys.exit(1)
common = os.path.commonpath([workspace, target])
if common != workspace and target != workspace:
    sys.exit(2)
PY
    then
      printf '%s' "$candidate"
      return 0
    fi
  done
  return 1
}

_runtime_overlay_journal_path() {
  if [[ -n "$RUNTIME_OVERLAY_JOURNAL_FILE" ]]; then
    printf '%s' "$RUNTIME_OVERLAY_JOURNAL_FILE"
  fi
}

runtime_overlay_journal_init() {
  local runtime="$1"
  local plan_key="$2"
  local timestamp
  local pid
  local workspace_root

  if [[ -z "$plan_key" ]]; then
    runtime_overlay_die "Runtime overlay journal requires a plan key."
  fi
  timestamp="$(date +%s)"
  pid="$$"
  workspace_root="$(_runtime_overlay_project_root)"
  RUNTIME_OVERLAY_JOURNAL_DIR="$RUNTIME_OVERLAY_STATE_DIR/journals"
  mkdir -p "$RUNTIME_OVERLAY_JOURNAL_DIR"
  RUNTIME_OVERLAY_JOURNAL_FILE="$RUNTIME_OVERLAY_JOURNAL_DIR/journal-${plan_key}-${pid}-${timestamp}.json"
  if ! command -v python3 &>/dev/null; then
    runtime_overlay_die "Python3 is required to initialize the runtime overlay journal."
  fi
  python3 - "$RUNTIME_OVERLAY_JOURNAL_FILE" "$pid" "$timestamp" "$plan_key" "$runtime" "$workspace_root" <<'PY'
import json, sys

path, pid, start_time, plan_key, runtime, workspace = sys.argv[1:]
data = {
    "pid": int(pid),
    "start_time": int(start_time),
    "runtime": runtime,
    "plan_key": plan_key,
    "workspace_root": workspace,
    "cleanup_status": "pending",
    "cleanup_time": None,
    "generated_files": [],
    "mutated_files": []
}
with open(path, "w") as fh:
    json.dump(data, fh, indent=2)
PY
}

_runtime_overlay_journal_append_entry() {
  local field="$1"
  local entry_json="$2"

  local journal_file
  journal_file="$(_runtime_overlay_journal_path)"
  if [[ -z "$journal_file" ]]; then
    return 0
  fi
  if ! command -v python3 &>/dev/null; then
    runtime_overlay_die "Python3 is required to update the runtime overlay journal."
  fi

  python3 - "$journal_file" "$field" "$entry_json" <<'PY'
import json, sys

path = sys.argv[1]
field = sys.argv[2]
entry_json = sys.argv[3]
entry = json.loads(entry_json)
with open(path) as fh:
    data = json.load(fh)
data.setdefault(field, []).append(entry)
with open(path, "w") as fh:
    json.dump(data, fh, indent=2)
PY
}

runtime_overlay_journal_add_generated_file() {
  local path="$1"
  if [[ -z "$path" ]]; then
    return 0
  fi
  local entry
  entry="$(python3 - "$path" <<'PY'
import json, sys
print(json.dumps({"path": sys.argv[1], "cleaned": False}))
PY
)"
  _runtime_overlay_journal_append_entry "generated_files" "$entry"
}

runtime_overlay_journal_add_mutated_file() {
  local target="$1"
  local backup="$2"
  if [[ -z "$target" ]]; then
    return 0
  fi
  local entry
  entry="$(python3 - "$target" "$backup" <<'PY'
import json, sys
print(json.dumps({"path": sys.argv[1], "backup": sys.argv[2], "restored": False}))
PY
)"
  _runtime_overlay_journal_append_entry "mutated_files" "$entry"
}

runtime_overlay_journal_mark_cleaned() {
  local journal_file
  journal_file="$(_runtime_overlay_journal_path)"
  if [[ -z "$journal_file" ]]; then
    return 0
  fi
  if ! command -v python3 &>/dev/null; then
    runtime_overlay_die "Python3 is required to mark the runtime overlay journal as cleaned."
  fi
  local cleanup_ts
  cleanup_ts="$(date +%s)"
  python3 - "$journal_file" "$cleanup_ts" <<'PY'
import json, sys, time

path, cleanup_ts = sys.argv[1:]
cleanup_time = int(cleanup_ts) if cleanup_ts.isdigit() else int(time.time())
data = json.load(open(path))
for entry in data.get("generated_files", []):
    entry["cleaned"] = True
for entry in data.get("mutated_files", []):
    entry["restored"] = True
data["cleanup_status"] = "cleaned"
data["cleanup_time"] = cleanup_time
with open(path, "w") as fh:
    json.dump(data, fh, indent=2)
PY
}

runtime_overlay_threshold_seconds() {
  local raw="${RALPH_RUNTIME_OVERLAY_STALE_THRESHOLD_SECONDS:-${RALPH_RUNTIME_OVERLAY_STALE_THRESHOLD:-3600}}"
  if [[ -z "$raw" ]]; then
    printf '3600'
    return
  fi
  if [[ "$raw" =~ ^([0-9]+)$ ]]; then
    printf '%s' "$raw"
    return
  fi
  if [[ "$raw" =~ ^([0-9]+)(s|m|h)$ ]]; then
    local value="${BASH_REMATCH[1]}"
    case "${BASH_REMATCH[2]}" in
      s) printf '%s' "$value" ;;
      m) printf '%s' "$((value * 60))" ;;
      h) printf '%s' "$((value * 3600))" ;;
    esac
    return
  fi
  printf '3600'
}

runtime_overlay_restore_stale_runs() {
  local workspace_root="${1:-$(_runtime_overlay_workspace_root)}"
  local plan_filter_arg="${2:-}"
  local threshold_seconds="${3:-$(runtime_overlay_threshold_seconds)}"
  local recovered_status="${4:-cleaned}"
  local runtime_filter="${5:-}"
  if [[ "$plan_filter_arg" == "--all" || "$plan_filter_arg" == "all" ]]; then
    plan_filter_arg=""
  fi
  if [[ -z "$workspace_root" || ! -d "$workspace_root" ]]; then
    printf 'Runtime overlay restore skipped: workspace %s not found.\n' "$workspace_root" >&2
    return 1
  fi
  if ! command -v python3 &>/dev/null; then
    printf 'runtime_overlay_restore_stale_runs requires python3\n' >&2
    return 1
  fi
  python3 - "$workspace_root" "$plan_filter_arg" "$threshold_seconds" "$recovered_status" "$runtime_filter" <<'PY'
import json, os, shutil, sys, time

workspace_root = sys.argv[1]
plan_filter_arg = sys.argv[2]
threshold_seconds = int(sys.argv[3]) if sys.argv[3].isdigit() else 3600
recovered_status = sys.argv[4] or "cleaned"
runtime_filter = sys.argv[5] or None
plan_filter = None if not plan_filter_arg else plan_filter_arg
runtime_config_root = os.path.join(workspace_root, ".ralph-workspace", "runtime-config")
if not os.path.isdir(runtime_config_root):
    sys.exit(0)
now = int(time.time())
messages = []
had_errors = False

def _load_json(path):
    try:
        with open(path) as fh:
            return json.load(fh)
    except (OSError, json.JSONDecodeError):
        return None

def _commands_for_matcher(data, event, matcher):
    hooks = (data or {}).get("hooks") or {}
    out = []
    for group in hooks.get(event) or []:
        if group.get("matcher") != matcher:
            continue
        for entry in group.get("hooks") or []:
            cmd = entry.get("command") or ""
            if cmd:
                out.append(cmd)
    return out

def _has_cmd(commands, needle):
    return any(needle in cmd or cmd.endswith(needle) for cmd in commands)

def _claude_hooks_detected(path):
    data = _load_json(path)
    if not isinstance(data, dict):
        return False
    env_cmds = _commands_for_matcher(data, "PreToolUse", "Read|Edit|MultiEdit|Glob|Grep|LS")
    bash_pre = _commands_for_matcher(data, "PreToolUse", "Bash")
    bash_post = _commands_for_matcher(data, "PostToolUse", "Bash")
    exploration_post = _commands_for_matcher(data, "PostToolUse", "Read|Grep|Glob")
    return (
        _has_cmd(env_cmds, "block-env-reads.sh")
        and _has_cmd(bash_pre, "rewrite-bash-command.sh")
        and _has_cmd(bash_post, "compact-bash-output.sh")
        and (
            _has_cmd(exploration_post, "native-result-compact.sh")
            or _has_cmd(exploration_post, "compact-native-result-output.sh")
        )
    )

def _cursor_hooks_detected(path):
    data = _load_json(path)
    if not isinstance(data, dict):
        return False
    required = {
        "pre-tool-shell-policy.sh",
        "post-tool-shell-telemetry.sh",
        "post-tool-native-result-compact.sh",
        "post-tool-mcp-compact.sh",
        "after-shell-telemetry.sh",
    }
    found = set()
    hooks = data.get("hooks") or {}
    for event in ("preToolUse", "postToolUse", "afterShellExecution"):
        for entry in hooks.get(event) or []:
            cmd = entry.get("command") or ""
            base = os.path.basename(cmd)
            if base in required:
                found.add(base)
    return found == required

def _preserve_mutated_target(target):
    if target.endswith("/.claude/settings.json"):
        return _claude_hooks_detected(target)
    if target.endswith("/.cursor/hooks.json"):
        return _cursor_hooks_detected(target)
    return False

def _preserve_generated_target(path):
    if "/.cursor/hooks/" not in path:
        return False
    base = os.path.basename(path)
    required = {
        "pre-tool-shell-policy.sh",
        "post-tool-shell-telemetry.sh",
        "post-tool-native-result-compact.sh",
        "post-tool-mcp-compact.sh",
        "after-shell-telemetry.sh",
    }
    if base not in required:
        return False
    hooks_json = os.path.join(os.path.dirname(os.path.dirname(path)), "hooks.json")
    return _cursor_hooks_detected(hooks_json)

for plan_dir in sorted(os.listdir(runtime_config_root)):
    plan_path = os.path.join(runtime_config_root, plan_dir)
    if not os.path.isdir(plan_path):
        continue
    journal_dir = os.path.join(plan_path, "journals")
    if not os.path.isdir(journal_dir):
        continue
    for journal_file in sorted(os.listdir(journal_dir)):
        journal_path = os.path.join(journal_dir, journal_file)
        if not os.path.isfile(journal_path):
            continue
        if not journal_file.endswith(".json"):
            continue
        try:
            with open(journal_path) as fh:
                data = json.load(fh)
        except (json.JSONDecodeError, FileNotFoundError):
            messages.append(f"Skipping invalid overlay journal: {journal_path}")
            continue
        journal_plan = data.get("plan_key") or plan_dir
        if plan_filter and journal_plan != plan_filter:
            continue
        if runtime_filter and data.get("runtime") != runtime_filter:
            continue
        if data.get("cleanup_status") in ("cleaned", "recovered_after_interruption"):
            continue
        pid = data.get("pid", 0)
        start_time = data.get("start_time", 0)
        pid_alive = True
        if isinstance(pid, int) and pid > 0:
            if pid == os.getpid():
                pid_alive = False
            else:
                try:
                    os.kill(pid, 0)
                except PermissionError:
                    pid_alive = True
                except ProcessLookupError:
                    pid_alive = False
        need_restore = (not pid_alive) or (threshold_seconds >= 0 and start_time and (start_time + threshold_seconds) <= now)
        if not need_restore:
            continue
        success = True
        for entry in data.get("mutated_files", []):
            target = entry.get("path")
            backup = entry.get("backup")
            if not target:
                continue
            if _preserve_mutated_target(target):
                entry["preserved"] = True
                continue
            try:
                if backup and os.path.isfile(backup):
                    dirpath = os.path.dirname(target)
                    if dirpath:
                        os.makedirs(dirpath, exist_ok=True)
                    shutil.copy2(backup, target)
                    os.remove(backup)
                else:
                    if os.path.exists(target):
                        os.remove(target)
                entry["restored"] = True
            except Exception as exc:
                success = False
                messages.append(f"Error restoring {target} from {backup}: {exc}")
                had_errors = True
        for entry in data.get("generated_files", []):
            path = entry.get("path")
            if not path:
                continue
            if _preserve_generated_target(path):
                entry["preserved"] = True
                continue
            try:
                if os.path.exists(path):
                    os.remove(path)
                entry["cleaned"] = True
            except Exception as exc:
                success = False
                messages.append(f"Error removing generated overlay file {path}: {exc}")
                had_errors = True
        if success:
            data["cleanup_status"] = recovered_status
            data["cleanup_time"] = now
            if recovered_status == "cleaned":
                messages.append(f"Restored stale runtime overlay for plan {journal_plan} (journal {journal_file})")
            else:
                data["recovered_after_interruption"] = True
                data["recovered_time"] = now
                messages.append(f"Recovered stale runtime overlay after interruption for plan {journal_plan} runtime {data.get('runtime','')} (journal {journal_file})")
        else:
            had_errors = True
            messages.append(f"Runtime overlay restore incomplete for {journal_path}")
        with open(journal_path, "w") as fh:
            json.dump(data, fh, indent=2)
print("\n".join(messages))
if had_errors:
    sys.exit(1)
PY
}

runtime_overlay_state_dir() {
  if [[ -n "$RUNTIME_OVERLAY_STATE_DIR" ]]; then
    printf '%s' "$RUNTIME_OVERLAY_STATE_DIR"
    return 0
  fi
  runtime_overlay_die "Runtime overlay state is not initialized."
}

runtime_overlay_summary_path() {
  local state_dir
  state_dir="$(runtime_overlay_state_dir)"
  printf '%s/summary.json' "$state_dir"
}

runtime_overlay_per_runtime_summary_path() {
  local runtime="${1:-${RUNTIME_OVERLAY_SUMMARY_RUNTIME:-}}"
  local state_dir
  state_dir="$(runtime_overlay_state_dir)"
  if [[ -z "$runtime" ]]; then
    runtime_overlay_die "Runtime overlay per-runtime summary requires a runtime name."
  fi
  printf '%s/summaries/%s.json' "$state_dir" "$runtime"
}

runtime_overlay_init_state() {
  local runtime="${1:-${RUNTIME:-}}"
  local plan_key="${2:-${RALPH_PLAN_KEY:-}}"
  if [[ -z "$plan_key" ]]; then
    runtime_overlay_die "Runtime overlay must be initialized with a plan key."
  fi
  RUNTIME_OVERLAY_SUMMARY_RUNTIME="${runtime}"
  RUNTIME_OVERLAY_SUMMARY_PLAN_KEY="$plan_key"
  RUNTIME_OVERLAY_SUMMARY_TOOL_ACCESS_MODE=""
  RUNTIME_OVERLAY_SUMMARY_NATIVE_HOOKS_REQUESTED=""
  RUNTIME_OVERLAY_SUMMARY_NATIVE_HOOKS_CONFIGURED=""
  RUNTIME_OVERLAY_SUMMARY_NATIVE_HOOK_EVENTS=""
  RUNTIME_OVERLAY_SUMMARY_NATIVE_HOOKS_OBSERVED_EFFECT=""
  RUNTIME_OVERLAY_SUMMARY_NATIVE_HOOKS_OBSERVED_REASON=""
  RUNTIME_OVERLAY_SUMMARY_NATIVE_HOOKS_EFFECTIVE=""
  RUNTIME_OVERLAY_SUMMARY_NATIVE_HOOKS_REASON=""
  RUNTIME_OVERLAY_SUMMARY_NATIVE_HOOKS_USED_ON_RUN=""
  RUNTIME_OVERLAY_SUMMARY_NATIVE_OUTPUT_MUTATION_PROVEN=""
  RUNTIME_OVERLAY_SUMMARY_NATIVE_SHELL_WRAPPER_ENABLED=""
  RUNTIME_OVERLAY_SUMMARY_NATIVE_SHELL_WRAPPER_EFFECTIVE=""
  RUNTIME_OVERLAY_SUMMARY_NATIVE_SHELL_WRAPPER_REASON=""
  RUNTIME_OVERLAY_SUMMARY_NATIVE_SHELL_COMPACTION_AUTHORITATIVE=""
  RUNTIME_OVERLAY_SUMMARY_FALLBACK_PATH_ACTIVE=""
  RUNTIME_OVERLAY_SUMMARY_MCP_EFFECTIVE=""
  RUNTIME_OVERLAY_SUMMARY_MCP_CONFIG_SOURCES=""
  RUNTIME_OVERLAY_SUMMARY_MCP_EFFECTIVE_NAMES=""
  RUNTIME_OVERLAY_SUMMARY_MCP_OVERRIDE_DECISIONS=""
  RUNTIME_OVERLAY_SUMMARY_MCP_FAILURE_REASON=""
  RUNTIME_OVERLAY_SUMMARY_PROXY_SHELL_COMPACT_EFFECTIVE=""
  RUNTIME_OVERLAY_SUMMARY_OVERLAY_MODE=""
  RUNTIME_OVERLAY_GENERATED_FILES=()
  RUNTIME_OVERLAY_MUTATED_FILES=()
  RUNTIME_OVERLAY_WARNINGS=()
  RUNTIME_OVERLAY_CAPABILITIES=()
  RUNTIME_OVERLAY_NATIVE_OPTIMIZATION_PROVEN_CHANNELS=()
  RUNTIME_OVERLAY_FALLBACK_CHANNELS_ACTIVE=()
  RUNTIME_OVERLAY_EXTERNAL_TEMP_FILES=()
  RUNTIME_OVERLAY_CLEANUP_CMDS=()
  if [[ -n "${RALPH_AGENT_TOOL_ACCESS:-}" ]]; then
    RUNTIME_OVERLAY_SUMMARY_TOOL_ACCESS_MODE="$RALPH_AGENT_TOOL_ACCESS"
  fi
  RUNTIME_OVERLAY_STATE_DIR="$(_runtime_overlay_state_root "$plan_key")"
  mkdir -p "$RUNTIME_OVERLAY_STATE_DIR"
  RUNTIME_OVERLAY_ORIGINALS_DIR="$RUNTIME_OVERLAY_STATE_DIR/originals"
  mkdir -p "$RUNTIME_OVERLAY_ORIGINALS_DIR"
  export RALPH_BASH_COMPACT_LOG="$RUNTIME_OVERLAY_STATE_DIR/bash-compact.jsonl"
  export RALPH_PROXY_SHELL_COMPACT_LOG="$RUNTIME_OVERLAY_STATE_DIR/proxy-shell-compact.jsonl"
  export RALPH_RESULT_WINDOWING_LOG="$RUNTIME_OVERLAY_STATE_DIR/result-windowing.jsonl"
  export RALPH_BASH_REWRITE_LOG="$RUNTIME_OVERLAY_STATE_DIR/bash-rewrite.jsonl"
  runtime_overlay_journal_init "$runtime" "$plan_key"
}

runtime_overlay_log_decision() {
  local key="$1"
  local value="$2"
  runtime_overlay_log "Runtime overlay decision: ${key}=${value} plan_key=${RUNTIME_OVERLAY_SUMMARY_PLAN_KEY}"
}

runtime_overlay_set_tool_access_mode() {
  RUNTIME_OVERLAY_SUMMARY_TOOL_ACCESS_MODE="$1"
  runtime_overlay_log_decision "tool_access_mode" "$1"
}

runtime_overlay_set_native_hooks_requested() {
  RUNTIME_OVERLAY_SUMMARY_NATIVE_HOOKS_REQUESTED="$1"
  runtime_overlay_log_decision "native_hooks_requested" "$1"
}

runtime_overlay_set_native_hooks_effective() {
  RUNTIME_OVERLAY_SUMMARY_NATIVE_HOOKS_EFFECTIVE="$1"
  runtime_overlay_log_decision "native_hooks_effective" "$1"
}

  runtime_overlay_set_native_hooks_reason() {
  RUNTIME_OVERLAY_SUMMARY_NATIVE_HOOKS_REASON="$1"
  runtime_overlay_log_decision "native_hooks_reason" "$1"
}

runtime_overlay_set_native_hooks_used_on_run() {
  RUNTIME_OVERLAY_SUMMARY_NATIVE_HOOKS_USED_ON_RUN="$1"
  runtime_overlay_log_decision "native_hooks_used_on_run" "$1"
}

runtime_overlay_set_native_hooks_configured() {
  RUNTIME_OVERLAY_SUMMARY_NATIVE_HOOKS_CONFIGURED="$1"
  runtime_overlay_log_decision "native_hooks_configured" "$1"
}

runtime_overlay_set_native_hook_events() {
  RUNTIME_OVERLAY_SUMMARY_NATIVE_HOOK_EVENTS="$1"
  runtime_overlay_log_decision "native_hook_events" "$1"
}

runtime_overlay_set_native_hooks_observed_effect() {
  RUNTIME_OVERLAY_SUMMARY_NATIVE_HOOKS_OBSERVED_EFFECT="$1"
  runtime_overlay_log_decision "native_hooks_observed_effect" "$1"
}

runtime_overlay_set_native_hooks_observed_reason() {
  RUNTIME_OVERLAY_SUMMARY_NATIVE_HOOKS_OBSERVED_REASON="$1"
  runtime_overlay_log_decision "native_hooks_observed_reason" "$1"
}

runtime_overlay_set_native_output_mutation_proven() {
  RUNTIME_OVERLAY_SUMMARY_NATIVE_OUTPUT_MUTATION_PROVEN="$1"
  runtime_overlay_log_decision "native_output_mutation_proven" "$1"
}

runtime_overlay_set_native_shell_wrapper_enabled() {
  RUNTIME_OVERLAY_SUMMARY_NATIVE_SHELL_WRAPPER_ENABLED="$1"
  runtime_overlay_log_decision "native_shell_wrapper_enabled" "$1"
}

runtime_overlay_set_native_shell_wrapper_effective() {
  RUNTIME_OVERLAY_SUMMARY_NATIVE_SHELL_WRAPPER_EFFECTIVE="$1"
  runtime_overlay_log_decision "native_shell_wrapper_effective" "$1"
}

runtime_overlay_set_native_shell_wrapper_reason() {
  RUNTIME_OVERLAY_SUMMARY_NATIVE_SHELL_WRAPPER_REASON="$1"
  runtime_overlay_log_decision "native_shell_wrapper_reason" "$1"
}

runtime_overlay_set_native_shell_compaction_authoritative() {
  RUNTIME_OVERLAY_SUMMARY_NATIVE_SHELL_COMPACTION_AUTHORITATIVE="$1"
  runtime_overlay_log_decision "native_shell_compaction_authoritative" "$1"
}

runtime_overlay_set_fallback_path_active() {
  RUNTIME_OVERLAY_SUMMARY_FALLBACK_PATH_ACTIVE="$1"
  runtime_overlay_log_decision "fallback_path_active" "$1"
}

runtime_overlay_add_proven_channel() {
  local channel="$1"
  local existing=""
  [[ -z "$channel" ]] && return 0
  for existing in "${RUNTIME_OVERLAY_NATIVE_OPTIMIZATION_PROVEN_CHANNELS[@]-}"; do
    [[ "$existing" == "$channel" ]] && return 0
  done
  RUNTIME_OVERLAY_NATIVE_OPTIMIZATION_PROVEN_CHANNELS+=("$channel")
  runtime_overlay_log_decision "proven_channel" "$channel"
}

runtime_overlay_add_fallback_channel() {
  local channel="$1"
  local existing=""
  [[ -z "$channel" ]] && return 0
  for existing in "${RUNTIME_OVERLAY_FALLBACK_CHANNELS_ACTIVE[@]-}"; do
    [[ "$existing" == "$channel" ]] && return 0
  done
  RUNTIME_OVERLAY_FALLBACK_CHANNELS_ACTIVE+=("$channel")
  runtime_overlay_log_decision "fallback_channel" "$channel"
}

runtime_overlay_note_native_shell_hook_proven() {
  runtime_overlay_add_proven_channel "native_shell_hook"
}

runtime_overlay_note_native_result_hook_measured_only() {
  runtime_overlay_add_fallback_channel "native_result_hook"
}

runtime_overlay_note_native_result_hook_proven() {
  runtime_overlay_add_proven_channel "native_result_hook"
}

runtime_overlay_note_mcp_proxy_channels_proven() {
  runtime_overlay_add_proven_channel "proxy_shell"
  runtime_overlay_add_proven_channel "native_result_mcp_fallback"
}

# When native output mutation is unproven, MCP proxy compaction is the documented fallback.
runtime_overlay_note_mcp_compaction_fallback_authoritative() {
  local active="false"
  local tool_access="${RALPH_AGENT_TOOL_ACCESS:-native}"
  case "$tool_access" in
    ralph|hybrid)
      case "${RALPH_PROXY_SHELL_COMPACT:-}" in
        1 | true | yes | on) active="true" ;;
      esac
      ;;
  esac
  if [[ "$active" != "true" ]] && [[ "${RALPH_MODE:-}" == "hybrid" ]]; then
    case "${RALPH_PROXY_SHELL_COMPACT:-1}" in
      1 | true | yes | on) active="true" ;;
    esac
  fi
  if [[ "$active" == "true" ]]; then
    runtime_overlay_note_mcp_proxy_channels_proven
  fi
  if declare -F runtime_overlay_set_fallback_path_active >/dev/null 2>&1; then
    runtime_overlay_set_fallback_path_active "$active"
  fi
}

runtime_overlay_set_mcp_effective() {
  RUNTIME_OVERLAY_SUMMARY_MCP_EFFECTIVE="$1"
  runtime_overlay_log_decision "mcp_effective" "$1"
}

runtime_overlay_set_mcp_config_sources() {
  RUNTIME_OVERLAY_SUMMARY_MCP_CONFIG_SOURCES="$1"
  runtime_overlay_log_decision "mcp_config_sources" "$(printf '%s' "$1" | paste -sd',' -)"
}

runtime_overlay_set_mcp_effective_names() {
  RUNTIME_OVERLAY_SUMMARY_MCP_EFFECTIVE_NAMES="$1"
  runtime_overlay_log_decision "mcp_effective_names" "$(printf '%s' "$1" | paste -sd',' -)"
}

runtime_overlay_set_mcp_override_decisions() {
  RUNTIME_OVERLAY_SUMMARY_MCP_OVERRIDE_DECISIONS="$1"
}

runtime_overlay_set_mcp_failure_reason() {
  RUNTIME_OVERLAY_SUMMARY_MCP_FAILURE_REASON="$1"
  if [[ -n "$1" ]]; then
    runtime_overlay_log_decision "mcp_failure_reason" "$1"
  fi
}

runtime_overlay_set_proxy_shell_compact_effective() {
  RUNTIME_OVERLAY_SUMMARY_PROXY_SHELL_COMPACT_EFFECTIVE="$1"
  runtime_overlay_log_decision "proxy_shell_compact_effective" "$1"
}

runtime_overlay_set_overlay_mode() {
  RUNTIME_OVERLAY_SUMMARY_OVERLAY_MODE="$1"
  runtime_overlay_log_decision "overlay_mode" "$1"
}

runtime_overlay_add_capability() {
  local cap="$1"
  RUNTIME_OVERLAY_CAPABILITIES+=("$cap")
}

runtime_overlay_add_warning() {
  local warning="$1"
  RUNTIME_OVERLAY_WARNINGS+=("$warning")
}

runtime_overlay_register_cleanup() {
  local cleanup_cmd="$*"
  RUNTIME_OVERLAY_CLEANUP_CMDS+=("$cleanup_cmd")
}

runtime_overlay_run_cleanup() {
  local cleanup_cmd
  local idx
  for ((idx=${#RUNTIME_OVERLAY_CLEANUP_CMDS[@]}-1; idx>=0; idx--)); do
    cleanup_cmd="${RUNTIME_OVERLAY_CLEANUP_CMDS[idx]}"
    if [[ -z "$cleanup_cmd" ]]; then
      continue
    fi
    if ! bash -c "$cleanup_cmd"; then
      runtime_overlay_add_warning "Cleanup command failed: $cleanup_cmd"
    fi
  done
}

runtime_overlay_record_generated_file() {
  local target="$1"
  if [[ -z "$target" ]]; then
    runtime_overlay_die "Runtime overlay generated file path cannot be empty."
  fi
  local abs
  abs="$(_runtime_overlay_abs_path "$target")"
  _runtime_overlay_require_workspace_bound "$abs"
  RUNTIME_OVERLAY_GENERATED_FILES+=("$abs")
  runtime_overlay_journal_add_generated_file "$abs"
  runtime_overlay_log_decision "generated_file" "$abs"
}

runtime_overlay_record_original_file() {
  local target="$1"
  local backup_var="${2:-}"
  local skip_missing_warning="${3:-0}"
  if [[ -z "$target" ]]; then
    runtime_overlay_die "Runtime overlay original file path cannot be empty."
  fi
  local abs
  abs="$(_runtime_overlay_abs_path "$target")"
  local mutation_root
  mutation_root="$(_runtime_overlay_mutation_root_for_target "$abs" 2>/dev/null || true)"
  if [[ -z "$mutation_root" ]]; then
    runtime_overlay_die "Overlay mutation rejected: $abs is outside the project and agent workspaces."
  fi
  RUNTIME_OVERLAY_MUTATED_FILES+=("$abs")
  local rel
  rel="$(python3 - "$mutation_root" "$abs" <<'PY'
import os, sys
workspace = os.path.abspath(sys.argv[1])
target = os.path.abspath(sys.argv[2])
print(os.path.relpath(target, workspace))
PY
)"
  if [[ "$mutation_root" != "$(_runtime_overlay_project_root)" ]]; then
    rel="agent-workspace/$rel"
  fi
  local backup="$RUNTIME_OVERLAY_ORIGINALS_DIR/$rel"
  mkdir -p "$(dirname "$backup")"
  runtime_overlay_journal_add_mutated_file "$abs" "$backup"
  if [[ -f "$abs" ]]; then
    cp "$abs" "$backup"
  else
    if [[ "$skip_missing_warning" != "1" ]]; then
      runtime_overlay_add_warning "Original file missing when recording: $abs"
    fi
    printf '' > "$backup"
  fi
  runtime_overlay_log_decision "mutated_file" "$abs"
  if [[ -n "$backup_var" ]]; then
    printf -v "$backup_var" '%s' "$backup"
  fi
}

runtime_overlay_record_external_temp_file() {
  local path="$1"
  if [[ -z "$path" ]]; then
    runtime_overlay_die "External temp file path cannot be empty."
  fi
  local abs
  abs="$(_runtime_overlay_abs_path "$path")"
  RUNTIME_OVERLAY_EXTERNAL_TEMP_FILES+=("$abs")
  RUNTIME_OVERLAY_GENERATED_FILES+=("$abs")
  runtime_overlay_journal_add_generated_file "$abs"
  runtime_overlay_log_decision "external_temp_file" "$abs"
  runtime_overlay_register_cleanup "rm -f \"$abs\""
}

runtime_overlay_write_summary() {
  local summary_file
  local write_script
  local overlay_fields_py
  summary_file="$(runtime_overlay_summary_path)"
  mkdir -p "$(dirname "$summary_file")"
  export RUNTIME_OVERLAY_SUMMARY_RUNTIME_VALUE="${RUNTIME_OVERLAY_SUMMARY_RUNTIME:-}"
  export RUNTIME_OVERLAY_SUMMARY_PLAN_KEY_VALUE="${RUNTIME_OVERLAY_SUMMARY_PLAN_KEY:-}"
  export RUNTIME_OVERLAY_SUMMARY_TOOL_ACCESS_MODE_VALUE="${RUNTIME_OVERLAY_SUMMARY_TOOL_ACCESS_MODE:-}"
  export RUNTIME_OVERLAY_SUMMARY_NATIVE_HOOKS_REQUESTED_VALUE="${RUNTIME_OVERLAY_SUMMARY_NATIVE_HOOKS_REQUESTED:-}"
  export RUNTIME_OVERLAY_SUMMARY_NATIVE_HOOKS_CONFIGURED_VALUE="${RUNTIME_OVERLAY_SUMMARY_NATIVE_HOOKS_CONFIGURED:-}"
  export RUNTIME_OVERLAY_SUMMARY_NATIVE_HOOK_EVENTS_VALUE="${RUNTIME_OVERLAY_SUMMARY_NATIVE_HOOK_EVENTS:-}"
  export RUNTIME_OVERLAY_SUMMARY_NATIVE_HOOKS_OBSERVED_EFFECT_VALUE="${RUNTIME_OVERLAY_SUMMARY_NATIVE_HOOKS_OBSERVED_EFFECT:-}"
  export RUNTIME_OVERLAY_SUMMARY_NATIVE_HOOKS_OBSERVED_REASON_VALUE="${RUNTIME_OVERLAY_SUMMARY_NATIVE_HOOKS_OBSERVED_REASON:-}"
  export RUNTIME_OVERLAY_SUMMARY_NATIVE_HOOKS_EFFECTIVE_VALUE="${RUNTIME_OVERLAY_SUMMARY_NATIVE_HOOKS_EFFECTIVE:-}"
  export RUNTIME_OVERLAY_SUMMARY_NATIVE_HOOKS_REASON_VALUE="${RUNTIME_OVERLAY_SUMMARY_NATIVE_HOOKS_REASON:-}"
  export RUNTIME_OVERLAY_SUMMARY_NATIVE_HOOKS_USED_ON_RUN_VALUE="${RUNTIME_OVERLAY_SUMMARY_NATIVE_HOOKS_USED_ON_RUN:-}"
  export RUNTIME_OVERLAY_SUMMARY_NATIVE_OUTPUT_MUTATION_PROVEN_VALUE="${RUNTIME_OVERLAY_SUMMARY_NATIVE_OUTPUT_MUTATION_PROVEN:-}"
  export RUNTIME_OVERLAY_SUMMARY_NATIVE_SHELL_WRAPPER_ENABLED_VALUE="${RUNTIME_OVERLAY_SUMMARY_NATIVE_SHELL_WRAPPER_ENABLED:-}"
  export RUNTIME_OVERLAY_SUMMARY_NATIVE_SHELL_WRAPPER_EFFECTIVE_VALUE="${RUNTIME_OVERLAY_SUMMARY_NATIVE_SHELL_WRAPPER_EFFECTIVE:-}"
  export RUNTIME_OVERLAY_SUMMARY_NATIVE_SHELL_WRAPPER_REASON_VALUE="${RUNTIME_OVERLAY_SUMMARY_NATIVE_SHELL_WRAPPER_REASON:-}"
  export RUNTIME_OVERLAY_SUMMARY_NATIVE_SHELL_COMPACTION_AUTHORITATIVE_VALUE="${RUNTIME_OVERLAY_SUMMARY_NATIVE_SHELL_COMPACTION_AUTHORITATIVE:-}"
  export RUNTIME_OVERLAY_SUMMARY_FALLBACK_PATH_ACTIVE_VALUE="${RUNTIME_OVERLAY_SUMMARY_FALLBACK_PATH_ACTIVE:-}"
  export RUNTIME_OVERLAY_SUMMARY_MCP_EFFECTIVE_VALUE="${RUNTIME_OVERLAY_SUMMARY_MCP_EFFECTIVE:-}"
  export RUNTIME_OVERLAY_SUMMARY_MCP_CONFIG_SOURCES_VALUE="${RUNTIME_OVERLAY_SUMMARY_MCP_CONFIG_SOURCES:-}"
  export RUNTIME_OVERLAY_SUMMARY_MCP_EFFECTIVE_NAMES_VALUE="${RUNTIME_OVERLAY_SUMMARY_MCP_EFFECTIVE_NAMES:-}"
  export RUNTIME_OVERLAY_SUMMARY_MCP_OVERRIDE_DECISIONS_VALUE="${RUNTIME_OVERLAY_SUMMARY_MCP_OVERRIDE_DECISIONS:-}"
  export RUNTIME_OVERLAY_SUMMARY_MCP_FAILURE_REASON_VALUE="${RUNTIME_OVERLAY_SUMMARY_MCP_FAILURE_REASON:-}"
  export RUNTIME_OVERLAY_SUMMARY_MCP_PREFLIGHT_OUTCOME_VALUE="${RALPH_MCP_PREFLIGHT_OUTCOME:-${RUNTIME_OVERLAY_SUMMARY_MCP_PREFLIGHT_OUTCOME:-}}"
  export RUNTIME_OVERLAY_SUMMARY_MCP_TOOL_NAMESPACE_VALUE="${RALPH_MCP_TOOL_NAMESPACE:-${RUNTIME_OVERLAY_SUMMARY_MCP_TOOL_NAMESPACE:-}}"
  export RUNTIME_OVERLAY_SUMMARY_PROXY_SHELL_COMPACT_EFFECTIVE_VALUE="${RUNTIME_OVERLAY_SUMMARY_PROXY_SHELL_COMPACT_EFFECTIVE:-}"
  export RUNTIME_OVERLAY_SUMMARY_CACHE_KEY_INJECTED_VALUE="${RALPH_OPENCODE_CACHE_KEY_INJECTED:-${RUNTIME_OVERLAY_SUMMARY_CACHE_KEY_INJECTED:-}}"
  export RUNTIME_OVERLAY_SUMMARY_CACHE_KEY_INJECTED_PROVIDER_ID_VALUE="${RALPH_OPENCODE_CACHE_KEY_PROVIDER_ID:-${RUNTIME_OVERLAY_SUMMARY_CACHE_KEY_INJECTED_PROVIDER_ID:-}}"
  export RUNTIME_OVERLAY_SUMMARY_OVERLAY_MODE_VALUE="${RUNTIME_OVERLAY_SUMMARY_OVERLAY_MODE:-}"
  export RUNTIME_OVERLAY_ARRAY_GENERATED_FILES="$(printf '%s\n' "${RUNTIME_OVERLAY_GENERATED_FILES[@]-}")"
  export RUNTIME_OVERLAY_ARRAY_MUTATED_FILES="$(printf '%s\n' "${RUNTIME_OVERLAY_MUTATED_FILES[@]-}")"
  export RUNTIME_OVERLAY_ARRAY_WARNINGS="$(printf '%s\n' "${RUNTIME_OVERLAY_WARNINGS[@]-}")"
  export RUNTIME_OVERLAY_ARRAY_CAPABILITIES="$(printf '%s\n' "${RUNTIME_OVERLAY_CAPABILITIES[@]-}")"
  export RUNTIME_OVERLAY_ARRAY_PROVEN_CHANNELS="$(printf '%s\n' "${RUNTIME_OVERLAY_NATIVE_OPTIMIZATION_PROVEN_CHANNELS[@]-}")"
  export RUNTIME_OVERLAY_ARRAY_FALLBACK_CHANNELS="$(printf '%s\n' "${RUNTIME_OVERLAY_FALLBACK_CHANNELS_ACTIVE[@]-}")"
  export RUNTIME_OVERLAY_STATE_DIR_VALUE="${RUNTIME_OVERLAY_STATE_DIR:-}"
  export RUNTIME_OVERLAY_SUMMARY_UPDATED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  write_script="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/python/runtime-overlay-write-summary.py"
  overlay_fields_py="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/python/ralph_overlay_usage_fields.py"
  if ! command -v python3 &>/dev/null; then
    runtime_overlay_die "Python3 is required to write the runtime overlay summary."
  fi
  python3 "$write_script" "$summary_file" "$overlay_fields_py"
}
