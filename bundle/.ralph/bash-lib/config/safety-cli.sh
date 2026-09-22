#!/usr/bin/env bash
set -euo pipefail

_safety_cli_dir="${BASH_SOURCE[0]%/*}"
[[ "$_safety_cli_dir" == "${BASH_SOURCE[0]}" ]] && _safety_cli_dir="."
# shellcheck source=../help-render.sh
source "$_safety_cli_dir/../help-render.sh"
# shellcheck source=../killswitch/killswitch-config.sh
source "$_safety_cli_dir/../killswitch/killswitch-config.sh"

RALPH_HOME="${RALPH_HOME:-${HOME:-}/.ralph}"

SAFETY_OLD_ROUTE_MSG='Use: ralph safety <status|validate|check|init|edit>'

safety_cli_usage() {
  cat <<'USAGE' | ralph_help_render
Usage: ralph safety <command> [options]

Inspect and validate Ralph safety (killswitch) configuration.
Source precedence: override file > project state-root killswitch.json >
$RALPH_HOME/killswitch.json > bundle default.

Commands:
  status              Show effective config, source, precedence, env, counts
  validate            Validate a config file without mutation
  check               Classify a command text (see: ralph safety check --help)
  init                Create a project or global config file
  edit                Edit a project or global config file

Options (status):
  --json              Emit stable machine-readable JSON
  --workspace <path>  Project root (default: current directory)

Options (validate):
  --project           Validate <state-root>/killswitch.json
  --global            Validate $RALPH_HOME/killswitch.json
  --file <path>       Validate an explicit file path
  --workspace <path>  Project root for --project (default: current directory)

Options (check):
  --command <text>    Command text to classify (required; exactly once)
  --json              Emit stable machine-readable JSON
  --workspace <path>  Project root (default: current directory)

Options (init):
  --project           Create <state-root>/killswitch.json (default)
  --global            Create $RALPH_HOME/killswitch.json
  --yes               Confirm non-interactively (required without a TTY)
  --workspace <path>  Project root for --project (default: current directory)

Options (edit):
  --project           Edit <state-root>/killswitch.json (default)
  --global            Edit $RALPH_HOME/killswitch.json
  --yes               Confirm non-interactively (required without a TTY)
  --workspace <path>  Project root for --project (default: current directory)

Examples:
  ralph safety status
  ralph safety status --json
  ralph safety validate --project
  ralph safety validate --global
  ralph safety validate --file ./killswitch.json
  ralph safety check --command 'sudo ls'
  ralph safety check --command 'echo ok' --json
  ralph safety init --project --yes
  ralph safety init --global --yes
  ralph safety edit --project
  ralph safety edit --global

Reads and cancelled previews never create files or directories.
check never executes command text. init has no --force shortcut.
USAGE
}

safety_cli_init_usage() {
  cat <<'USAGE' | ralph_help_render
Usage: ralph safety init [--project|--global] [--yes] [--workspace <path>]

Create a project or global safety config from the normalized bundle default.
Prints the absolute target and source scope, shows a preview, then confirms
before any mutation. An existing target requires replacement confirmation.
Non-TTY mutation requires --yes. There is no --force shortcut.

Options:
  --project           Target <state-root>/killswitch.json (default)
  --global            Target $RALPH_HOME/killswitch.json
  --yes               Confirm without a prompt (required when stdin is not a TTY)
  --workspace <path>  Project root for --project (default: current directory)

Cancelled previews and reads do not create directories.
USAGE
}

safety_cli_edit_usage() {
  cat <<'USAGE' | ralph_help_render
Usage: ralph safety edit [--project|--global] [--yes] [--workspace <path>]

Edit a project or global safety config with $VISUAL, then $EDITOR, then vi.
Uses a same-directory temp copy, shared pre/post validation, atomic rename,
signal cleanup, symlink/race refusal, and byte-exact original preservation
on any failure. Non-TTY mutation requires --yes.

Options:
  --project           Target <state-root>/killswitch.json (default)
  --global            Target $RALPH_HOME/killswitch.json
  --yes               Confirm without a prompt (required when stdin is not a TTY)
  --workspace <path>  Project root for --project (default: current directory)

The target must already exist (run ralph safety init first). Symlink targets
are refused.
USAGE
}

safety_cli_check_usage() {
  cat <<'USAGE' | ralph_help_render
Usage: ralph safety check --command <text> [--json] [--workspace <path>]

Classify command text against the effective safety config using the production
evaluator in classify-only mode. The text is never passed to a shell or runtime.

Options:
  --command <text>    Command text to classify (required; exactly once)
  --json              Emit {schemaVersion,outcome,source,matchedRule,precedence,dryRun}
  --workspace <path>  Project root (default: current directory)

Exit codes:
  0  Classification succeeded (allow or deny)
  1  Invalid configured source or evaluator failure
  2  Usage error (missing/duplicate --command, unknown flag)

Human output reports allow/deny, winning source, matched rule, precedence, and
dry-run effect. matchedRule is JSON null when no rule matches.
USAGE
}

safety_cli_workspace_root() {
  local workspace="${1:-}"
  if [[ -z "$workspace" ]]; then
    workspace="$PWD"
  fi
  if [[ ! -d "$workspace" ]]; then
    echo "Error: workspace is not a directory: $workspace" >&2
    return 1
  fi
  cd "$workspace" && pwd
}

safety_cli_project_config() {
  local workspace="$1"
  local state_root
  if [[ -n "${RALPH_PLAN_WORKSPACE_ROOT:-}" ]]; then
    state_root="${RALPH_PLAN_WORKSPACE_ROOT%/}"
  else
    state_root="${workspace%/}/.ralph-workspace"
  fi
  printf '%s/killswitch.json\n' "$state_root"
}

safety_cli_global_config() {
  printf '%s/killswitch.json\n' "$RALPH_HOME"
}

safety_cli_bundle_config() {
  printf '%s/killswitch.json\n' "${_KILLSWITCH_RALPH_DIR}"
}

# Print JSON array of precedence rows: source, path, present, selected.
safety_cli_precedence_json() {
  local workspace="$1"
  local selected_source="$2"
  local override_cfg project_cfg global_cfg bundle_cfg
  local override_present=false project_present=false global_present=false bundle_present=false
  local override_path="" project_path global_path bundle_path

  override_cfg="${RALPH_KILLSWITCH_OVERRIDE_FILE:-}"
  if [[ -n "$override_cfg" ]]; then
    override_path="$override_cfg"
    [[ -e "$override_cfg" ]] && override_present=true
  fi

  project_path="$(safety_cli_project_config "$workspace")"
  [[ -e "$project_path" ]] && project_present=true

  global_path="$(safety_cli_global_config)"
  [[ -e "$global_path" ]] && global_present=true

  bundle_path="$(safety_cli_bundle_config)"
  [[ -e "$bundle_path" ]] && bundle_present=true

  python3 - "$selected_source" \
    "$override_path" "$override_present" \
    "$project_path" "$project_present" \
    "$global_path" "$global_present" \
    "$bundle_path" "$bundle_present" <<'PY'
import json, sys

selected = sys.argv[1]
rows = []
specs = [
    ("override", sys.argv[2] or None, sys.argv[3] == "true"),
    ("project", sys.argv[4] or None, sys.argv[5] == "true"),
    ("global", sys.argv[6] or None, sys.argv[7] == "true"),
    ("bundle", sys.argv[8] or None, sys.argv[9] == "true"),
]
for source, path, present in specs:
    rows.append({
        "source": source,
        "path": path,
        "present": present,
        "selected": source == selected and present,
    })
# When selected is none, no row is selected.
if selected == "none":
    for row in rows:
        row["selected"] = False
print(json.dumps(rows, separators=(",", ":")))
PY
}

safety_cli_env_overrides_json() {
  python3 - <<'PY'
import json, os

def val(name):
    if name not in os.environ:
        return None
    return os.environ[name]

out = {
    "RALPH_KILLSWITCH_DISABLED": val("RALPH_KILLSWITCH_DISABLED"),
    "RALPH_KILLSWITCH_OVERRIDE_FILE": val("RALPH_KILLSWITCH_OVERRIDE_FILE"),
    "RALPH_BANNED_TOOLS": val("RALPH_BANNED_TOOLS"),
    "RALPH_BANNED_PATHS": val("RALPH_BANNED_PATHS"),
    "RALPH_BANNED_PATTERNS": val("RALPH_BANNED_PATTERNS"),
    "RALPH_ALLOWED_TOOLS": val("RALPH_ALLOWED_TOOLS"),
    "RALPH_ALLOWED_PATHS": val("RALPH_ALLOWED_PATHS"),
    "RALPH_ALLOWED_COMMANDS": val("RALPH_ALLOWED_COMMANDS"),
    "RALPH_ALLOWED_PATTERNS": val("RALPH_ALLOWED_PATTERNS"),
    "RALPH_MCP_TOOL_DENYLIST": val("RALPH_MCP_TOOL_DENYLIST"),
}
print(json.dumps(out, separators=(",", ":")))
PY
}

safety_cli_counts_json() {
  python3 -c '
import json, sys
print(json.dumps({
  "bannedTools": int(sys.argv[1]),
  "toolDenylist": int(sys.argv[2]),
  "allowedTools": int(sys.argv[3]),
  "bannedPaths": int(sys.argv[4]),
  "allowedPaths": int(sys.argv[5]),
  "allowedCommands": int(sys.argv[6]),
  "allowedPatterns": int(sys.argv[7]),
  "deniedArgumentPatterns": int(sys.argv[8]),
  "customRules": int(sys.argv[9]),
}, separators=(",", ":")))
' \
    "${#_KILLSWITCH_BANNED_TOOLS[@]}" \
    "${#_KILLSWITCH_TOOL_DENYLIST[@]}" \
    "${#_KILLSWITCH_ALLOWED_TOOLS[@]}" \
    "${#_KILLSWITCH_BANNED_PATHS[@]}" \
    "${#_KILLSWITCH_ALLOWED_PATHS[@]}" \
    "${#_KILLSWITCH_ALLOWED_COMMANDS[@]}" \
    "${#_KILLSWITCH_ALLOWED_PATTERNS[@]}" \
    "$(python3 -c 'import json,sys; print(len(json.loads(sys.argv[1])))' "${_KILLSWITCH_DENIED_ARGUMENT_PATTERNS_JSON:-[]}")" \
    "$(python3 -c 'import json,sys; print(len(json.loads(sys.argv[1])))' "${_KILLSWITCH_CUSTOM_RULES_JSON:-[]}")"
}

safety_cli_warnings_json() {
  local source_kind="$1"
  local enabled_effective="$2"
  local dry_run_effective="$3"
  python3 - "$source_kind" "$enabled_effective" "$dry_run_effective" \
    "${RALPH_KILLSWITCH_DISABLED:-}" \
    "${RALPH_KILLSWITCH_OVERRIDE_FILE:-}" <<'PY'
import json, sys

source, enabled, dry_run, disabled_env, override = sys.argv[1:6]
warnings = []
if disabled_env == "1":
    warnings.append("RALPH_KILLSWITCH_DISABLED=1 overrides config enabled to false")
if enabled == "false":
    warnings.append("Safety evaluation is disabled")
if dry_run == "true":
    warnings.append("Dry-run mode: violations are classified without killing the runner")
if source == "bundle":
    warnings.append("Using bundle default; project and global configs are absent")
elif source == "global":
    warnings.append("Using global config; project config is absent")
elif source == "none":
    warnings.append("No safety config file found; built-in defaults apply")
if override and source == "override":
    warnings.append("RALPH_KILLSWITCH_OVERRIDE_FILE is selecting the winning source")
print(json.dumps(warnings, separators=(",", ":")))
PY
}

safety_cli_prepare_env() {
  local workspace="$1"
  export WORKSPACE="$workspace"
  export RALPH_HOME
  export RALPH_PROJECT_ROOT="${RALPH_PROJECT_ROOT:-$workspace}"
  if [[ -z "${RALPH_PLAN_WORKSPACE_ROOT:-}" ]]; then
    export RALPH_PLAN_WORKSPACE_ROOT="${workspace}/.ralph-workspace"
  fi
  unset RALPH_KILLSWITCH_CONFIG_LOADED || true
}

safety_cli_effective_enabled() {
  if [[ "${RALPH_KILLSWITCH_DISABLED:-0}" == "1" ]]; then
    printf 'false\n'
    return 0
  fi
  if [[ "${_KILLSWITCH_ENABLED:-true}" == "true" ]]; then
    printf 'true\n'
  else
    printf 'false\n'
  fi
}

safety_cli_status() {
  local workspace="$1"
  local as_json="${2:-0}"

  if ! command -v python3 >/dev/null 2>&1; then
    echo "Error: python3 is required for ralph safety status" >&2
    return 1
  fi

  safety_cli_prepare_env "$workspace"

  if ! killswitch_load_config; then
    echo "Error: safety config failed validation (fail closed)" >&2
    echo "  source: $(killswitch_config_source)" >&2
    echo "  path: $(killswitch_config_path)" >&2
    return 1
  fi

  # Merge env after validation so status reports effective counts.
  killswitch_merge_env_overrides

  local source_kind path enabled dry_run
  source_kind="$(killswitch_config_source)"
  path="$(killswitch_config_path)"
  enabled="$(safety_cli_effective_enabled)"
  dry_run="${_KILLSWITCH_DRY_RUN:-false}"

  local precedence_json env_json counts_json warnings_json
  precedence_json="$(safety_cli_precedence_json "$workspace" "$source_kind")"
  env_json="$(safety_cli_env_overrides_json)"
  counts_json="$(safety_cli_counts_json)"
  warnings_json="$(safety_cli_warnings_json "$source_kind" "$enabled" "$dry_run")"

  if [[ "$as_json" -eq 1 ]]; then
    python3 - "$enabled" "$dry_run" "$source_kind" "$path" \
      "$precedence_json" "$env_json" "$counts_json" "$warnings_json" <<'PY'
import json, sys

enabled = sys.argv[1] == "true"
dry_run = sys.argv[2] == "true"
source = sys.argv[3]
path = sys.argv[4] or None
payload = {
    "schemaVersion": 1,
    "enabled": enabled,
    "dryRun": dry_run,
    "source": source,
    "path": path,
    "precedence": json.loads(sys.argv[5]),
    "environmentOverrides": json.loads(sys.argv[6]),
    "counts": json.loads(sys.argv[7]),
    "warnings": json.loads(sys.argv[8]),
}
print(json.dumps(payload, separators=(",", ":"), sort_keys=False))
PY
    return 0
  fi

  echo "Safety configuration"
  echo
  echo "Effective:"
  echo "  enabled: $enabled"
  echo "  dryRun:  $dry_run"
  echo
  if [[ "$source_kind" == "none" ]]; then
    echo "Winning source: none"
    echo "  path: (none)"
  else
    echo "Winning source: $source_kind"
    echo "  path: $path"
  fi
  echo
  echo "Precedence (first present wins):"
  python3 -c '
import json,sys
for row in json.loads(sys.argv[1]):
    mark = "*" if row.get("selected") else " "
    present = "present" if row.get("present") else "absent"
    path = row.get("path") or "(unset)"
    print("  %s %s: %s  %s" % (mark, row["source"], present, path))
' "$precedence_json"
  echo
  echo "Environment overrides:"
  python3 -c '
import json,sys
env = json.loads(sys.argv[1])
any_set = False
for key in env:
    val = env[key]
    if val is None:
        continue
    any_set = True
    print(f"  {key}={val}")
if not any_set:
    print("  (none)")
' "$env_json"
  echo
  echo "Counts:"
  python3 -c '
import json,sys
counts = json.loads(sys.argv[1])
for key in ("bannedTools","toolDenylist","allowedTools","bannedPaths","allowedPaths","allowedCommands","allowedPatterns","deniedArgumentPatterns","customRules"):
    print(f"  {key}: {counts[key]}")
' "$counts_json"
  echo
  echo "Warnings:"
  python3 -c '
import json,sys
warnings = json.loads(sys.argv[1])
if not warnings:
    print("  (none)")
else:
    for w in warnings:
        print(f"  - {w}")
' "$warnings_json"
}

safety_cli_validate() {
  local workspace="$1"
  shift

  local mode=""
  local file_path=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --project)
        [[ -z "$mode" ]] || { echo "Error: validate accepts only one of --project, --global, --file" >&2; return 2; }
        mode="project"
        shift
        ;;
      --global)
        [[ -z "$mode" ]] || { echo "Error: validate accepts only one of --project, --global, --file" >&2; return 2; }
        mode="global"
        shift
        ;;
      --file)
        [[ -z "$mode" ]] || { echo "Error: validate accepts only one of --project, --global, --file" >&2; return 2; }
        [[ -n "${2:-}" ]] || { echo "Error: --file requires a path" >&2; return 2; }
        mode="file"
        file_path="$2"
        shift 2
        ;;
      --workspace)
        [[ -n "${2:-}" ]] || { echo "Error: --workspace requires a path" >&2; return 2; }
        workspace="$(safety_cli_workspace_root "$2")" || return 1
        shift 2
        ;;
      -h|--help)
        safety_cli_usage
        return 0
        ;;
      *)
        echo "Error: unknown validate option: $1" >&2
        return 2
        ;;
    esac
  done

  if [[ -z "$mode" ]]; then
    # Default: validate the winning configured source without creating files.
    safety_cli_prepare_env "$workspace"
    local source_kind config_path
    IFS=$'\t' read -r source_kind config_path <<< "$(killswitch_resolve_config_source)"
    if [[ "$source_kind" == "none" || -z "$config_path" ]]; then
      echo "No safety config file present; nothing to validate (defaults apply)."
      return 0
    fi
    mode="file"
    file_path="$config_path"
  elif [[ "$mode" == "project" ]]; then
    file_path="$(safety_cli_project_config "$workspace")"
  elif [[ "$mode" == "global" ]]; then
    file_path="$(safety_cli_global_config)"
  fi

  if [[ ! -e "$file_path" ]]; then
    echo "Error: safety config not found: $file_path" >&2
    echo "Reads never create files; run ralph safety init to create one." >&2
    return 1
  fi

  if ! killswitch_normalize_config_file "$file_path" >/dev/null; then
    return 1
  fi
  echo "Valid: $file_path"
  return 0
}

safety_cli_check() {
  local workspace="$1"
  local as_json="${2:-0}"
  shift 2

  local command_text=""
  local command_set=0

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --command)
        [[ "$command_set" -eq 0 ]] || {
          echo "Error: --command specified more than once" >&2
          return 2
        }
        [[ -n "${2+x}" && $# -ge 2 ]] || {
          echo "Error: --command requires a value" >&2
          return 2
        }
        command_text="$2"
        command_set=1
        shift 2
        ;;
      --command=*)
        [[ "$command_set" -eq 0 ]] || {
          echo "Error: --command specified more than once" >&2
          return 2
        }
        command_text="${1#--command=}"
        [[ -n "$command_text" ]] || {
          echo "Error: --command requires a value" >&2
          return 2
        }
        command_set=1
        shift
        ;;
      --json)
        as_json=1
        shift
        ;;
      --workspace)
        [[ -n "${2:-}" ]] || {
          echo "Error: --workspace requires a path" >&2
          return 2
        }
        workspace="$(safety_cli_workspace_root "$2")" || return 1
        shift 2
        ;;
      -h|--help)
        safety_cli_check_usage
        return 0
        ;;
      *)
        echo "Error: unknown check option: $1" >&2
        return 2
        ;;
    esac
  done

  if [[ "$command_set" -ne 1 ]]; then
    echo "Error: --command is required" >&2
    echo "Usage: ralph safety check --command <text> [--json]" >&2
    return 2
  fi

  if ! command -v python3 >/dev/null 2>&1; then
    echo "Error: python3 is required for ralph safety check" >&2
    return 1
  fi

  # shellcheck source=../killswitch/killswitch-validator.sh
  source "$_safety_cli_dir/../killswitch/killswitch-validator.sh"
  # shellcheck source=../killswitch/killswitch-evaluate.sh
  source "$_safety_cli_dir/../killswitch/killswitch-evaluate.sh"

  safety_cli_prepare_env "$workspace"

  if ! killswitch_load_config; then
    echo "Error: safety config failed validation (fail closed)" >&2
    echo "  source: $(killswitch_config_source)" >&2
    echo "  path: $(killswitch_config_path)" >&2
    return 1
  fi
  killswitch_merge_env_overrides

  local decision decision_file classify_rc=0
  decision_file="$(mktemp "${TMPDIR:-/tmp}/ralph-safety-check.XXXXXX")" || {
    echo "Error: safety evaluator failure (temp file)" >&2
    return 1
  }
  # Run classify in this shell (not command substitution) so KILLSWITCH_* globals survive.
  killswitch_classify_command "$command_text" >"$decision_file" || classify_rc=$?
  decision="$(cat "$decision_file" 2>/dev/null || true)"
  rm -f "$decision_file"
  if [[ "$classify_rc" -ne 0 ]]; then
    echo "Error: safety evaluator failure" >&2
    return 1
  fi

  local outcome="allow"
  local matched_rule=""
  case "$decision" in
    allow)
      outcome="allow"
      matched_rule=""
      ;;
    deny|fatal)
      outcome="deny"
      matched_rule="${KILLSWITCH_MATCHED_RULE:-${KILLSWITCH_DECISION_REASON:-}}"
      ;;
    *)
      echo "Error: safety evaluator failure (unexpected decision: ${decision:-empty})" >&2
      return 1
      ;;
  esac

  local source_kind path dry_run precedence_json
  source_kind="$(killswitch_config_source)"
  path="$(killswitch_config_path)"
  dry_run="${_KILLSWITCH_DRY_RUN:-false}"
  precedence_json="$(safety_cli_precedence_json "$workspace" "$source_kind")"

  if [[ "$as_json" -eq 1 ]]; then
    python3 - "$outcome" "$source_kind" "$matched_rule" "$precedence_json" "$dry_run" <<'PY'
import json, sys

outcome, source, matched_rule, precedence_raw, dry_run = sys.argv[1:6]
payload = {
    "schemaVersion": 1,
    "outcome": outcome,
    "source": source,
    "matchedRule": matched_rule if matched_rule else None,
    "precedence": json.loads(precedence_raw),
    "dryRun": dry_run == "true",
}
print(json.dumps(payload, separators=(",", ":"), sort_keys=False))
PY
    return 0
  fi

  echo "Safety check"
  echo
  echo "Outcome: $outcome"
  if [[ -n "$matched_rule" ]]; then
    echo "Matched rule: $matched_rule"
  else
    echo "Matched rule: (none)"
  fi
  echo
  if [[ "$source_kind" == "none" ]]; then
    echo "Winning source: none"
    echo "  path: (none)"
  else
    echo "Winning source: $source_kind"
    echo "  path: $path"
  fi
  echo
  echo "Precedence (first present wins):"
  python3 -c '
import json,sys
for row in json.loads(sys.argv[1]):
    mark = "*" if row.get("selected") else " "
    present = "present" if row.get("present") else "absent"
    path = row.get("path") or "(unset)"
    print("  %s %s: %s  %s" % (mark, row["source"], present, path))
' "$precedence_json"
  echo
  echo "Dry-run: $dry_run"
  if [[ "$outcome" == "allow" ]]; then
    echo "  effect: command would be allowed (no killswitch action)"
  elif [[ "$dry_run" == "true" ]]; then
    echo "  effect: violation classified only; runner would not be killed"
  else
    echo "  effect: violation would activate killswitch (sentinel + kill runner)"
  fi
}

# --- init / edit: atomic mutation helpers ------------------------------------

safety_cli_select_editor() {
  if [[ -n "${VISUAL:-}" ]]; then
    printf '%s\n' "$VISUAL"
  elif [[ -n "${EDITOR:-}" ]]; then
    printf '%s\n' "$EDITOR"
  elif command -v nano >/dev/null 2>&1; then
    # nano over vi as the unset-env default: modal editors are the #1 way
    # operators get stuck unable to save/exit. Falls back to vi only where
    # nano genuinely is not installed (minimal/CI containers).
    printf 'nano\n'
  else
    printf 'vi\n'
  fi
}

# Tell the operator how to save and exit before the editor takes over the
# terminal. vi/vim/nvim's modal :wq is the classic trap for anyone who isn't
# already a vi user; other editors get a generic reminder for the same reason.
safety_cli_editor_hint() {
  local editor="$1" base
  base="$(basename -- "${editor%% *}")"
  case "$base" in
    vi|vim|nvim)
      printf 'Opening %s to edit the safety config.\n' "$editor" >&2
      printf '  Save and exit: press Esc, then type :wq and press Enter.\n' >&2
      printf '  Discard changes instead: press Esc, then type :q! and press Enter.\n' >&2
      ;;
    nano)
      printf 'Opening %s to edit the safety config.\n' "$editor" >&2
      printf '  Save and exit: press Ctrl+O, then Enter, then Ctrl+X.\n' >&2
      printf '  Discard changes instead: press Ctrl+X, then answer N when asked to save.\n' >&2
      ;;
    *)
      printf 'Opening %s to edit the safety config. Save and close it to continue.\n' "$editor" >&2
      ;;
  esac
}

safety_cli_file_fingerprint() {
  local path="$1"
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 -- "$path" 2>/dev/null | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then
    sha256sum -- "$path" 2>/dev/null | awk '{print $1}'
  else
    printf '%s-%s\n' "$(wc -c <"$path" | tr -d ' ')" "$(cksum <"$path" | awk '{print $1}')"
  fi
}

# Absolute path without creating parents. Existing parents are resolved via pwd.
safety_cli_abs_path() {
  local path="${1:-}"
  local parent base abs_parent
  [[ -n "$path" ]] || return 1
  if [[ "$path" != /* ]]; then
    path="$(pwd)/$path"
  fi
  parent="$(dirname -- "$path")"
  base="$(basename -- "$path")"
  if [[ -d "$parent" ]]; then
    abs_parent="$(cd -- "$parent" && pwd)" || return 1
    printf '%s/%s\n' "$abs_parent" "$base"
  else
    printf '%s\n' "$path"
  fi
}

# Confirm a mutating action. --yes wins; TTY requires typing "yes"; non-TTY
# without --yes refuses before any mkdir/write.
safety_cli_confirm_mutation() {
  local yes_flag="${1:-0}"
  local action_word="${2:-proceed}"

  if [[ "$yes_flag" -eq 1 ]]; then
    echo "Confirmed non-interactively (--yes); proceeding."
    return 0
  fi
  if [[ -t 0 ]]; then
    local answer=""
    printf '\nType "yes" to %s, or anything else (including EOF) to cancel: ' "$action_word"
    if ! IFS= read -r answer; then
      answer=""
    fi
    if [[ "$answer" != "yes" ]]; then
      echo "Cancelled; no files were written."
      return 1
    fi
    return 0
  fi
  echo "Error: non-interactive ralph safety mutation requires --yes" >&2
  return 1
}

safety_cli_parse_scope_flags() {
  # Sets SAFETY_CLI_SCOPE (project|global), SAFETY_CLI_YES (0|1),
  # and optional SAFETY_CLI_WORKSPACE_OVERRIDE. Rejects --force and dual scope.
  SAFETY_CLI_SCOPE=""
  SAFETY_CLI_YES=0
  SAFETY_CLI_WORKSPACE_OVERRIDE=""
  local arg
  while [[ $# -gt 0 ]]; do
    arg="$1"
    case "$arg" in
      --project|--global)
        if [[ -n "$SAFETY_CLI_SCOPE" ]]; then
          echo "Error: use only one of --project, --global" >&2
          return 2
        fi
        SAFETY_CLI_SCOPE="${arg#--}"
        shift
        ;;
      --yes|-y)
        SAFETY_CLI_YES=1
        shift
        ;;
      --force)
        echo "Error: --force is not supported; confirm replacement interactively or with --yes" >&2
        return 2
        ;;
      --workspace)
        [[ -n "${2:-}" ]] || {
          echo "Error: --workspace requires a path" >&2
          return 2
        }
        SAFETY_CLI_WORKSPACE_OVERRIDE="$2"
        shift 2
        ;;
      -h|--help)
        return 64
        ;;
      --*)
        echo "Error: unknown option: $arg" >&2
        return 2
        ;;
      *)
        echo "Error: unexpected argument: $arg" >&2
        return 2
        ;;
    esac
  done
  if [[ -z "$SAFETY_CLI_SCOPE" ]]; then
    SAFETY_CLI_SCOPE="project"
  fi
  return 0
}

safety_cli_resolve_mutable_target() {
  local workspace="$1"
  local scope="$2"
  case "$scope" in
    project)
      safety_cli_abs_path "$(safety_cli_project_config "$workspace")"
      ;;
    global)
      safety_cli_abs_path "$(safety_cli_global_config)"
      ;;
    *)
      echo "Error: unsupported safety scope: $scope" >&2
      return 2
      ;;
  esac
}

# Trap-friendly edit/init temp state.
SAFETY_CLI_MUT_TMP=""
SAFETY_CLI_MUT_BACKUP=""
SAFETY_CLI_MUT_TARGET=""
SAFETY_CLI_MUT_HAD_ORIGINAL=0
SAFETY_CLI_MUT_DONE=0
SAFETY_CLI_MUT_KEEP_TARGET=0

safety_cli_mut_cleanup() {
  local ec="${1:-1}"
  if [[ "$SAFETY_CLI_MUT_DONE" -eq 1 ]]; then
    rm -f -- "${SAFETY_CLI_MUT_BACKUP:-}" 2>/dev/null || true
    SAFETY_CLI_MUT_TMP=""
    SAFETY_CLI_MUT_BACKUP=""
    return 0
  fi
  if [[ "$SAFETY_CLI_MUT_KEEP_TARGET" -eq 1 ]]; then
    rm -f -- "${SAFETY_CLI_MUT_TMP:-}" "${SAFETY_CLI_MUT_BACKUP:-}" 2>/dev/null || true
    SAFETY_CLI_MUT_TMP=""
    SAFETY_CLI_MUT_BACKUP=""
    return "$ec"
  fi
  if [[ "$SAFETY_CLI_MUT_HAD_ORIGINAL" -eq 1 && -n "${SAFETY_CLI_MUT_BACKUP:-}" && -f "$SAFETY_CLI_MUT_BACKUP" ]]; then
    if [[ -n "${SAFETY_CLI_MUT_TARGET:-}" ]]; then
      cp -f -- "$SAFETY_CLI_MUT_BACKUP" "$SAFETY_CLI_MUT_TARGET" 2>/dev/null || true
    fi
  elif [[ "$SAFETY_CLI_MUT_HAD_ORIGINAL" -eq 0 && -n "${SAFETY_CLI_MUT_TARGET:-}" && -e "${SAFETY_CLI_MUT_TARGET:-}" ]]; then
    # Incomplete create: remove partial target only when we owned the create.
    rm -f -- "$SAFETY_CLI_MUT_TARGET" 2>/dev/null || true
  fi
  rm -f -- "${SAFETY_CLI_MUT_TMP:-}" "${SAFETY_CLI_MUT_BACKUP:-}" 2>/dev/null || true
  SAFETY_CLI_MUT_TMP=""
  SAFETY_CLI_MUT_BACKUP=""
  return "$ec"
}

safety_cli_mut_on_signal() {
  safety_cli_mut_cleanup 1
  exit 1
}

safety_cli_init() {
  local workspace="$1"
  shift

  local parse_rc=0
  safety_cli_parse_scope_flags "$@" || parse_rc=$?
  if [[ "$parse_rc" -eq 64 ]]; then
    safety_cli_init_usage
    return 0
  fi
  [[ "$parse_rc" -eq 0 ]] || return "$parse_rc"

  if [[ -n "${SAFETY_CLI_WORKSPACE_OVERRIDE:-}" ]]; then
    workspace="$(safety_cli_workspace_root "$SAFETY_CLI_WORKSPACE_OVERRIDE")" || return 1
  fi

  if ! command -v python3 >/dev/null 2>&1; then
    echo "Error: python3 is required for ralph safety init" >&2
    return 1
  fi

  local scope="$SAFETY_CLI_SCOPE"
  local yes_flag="$SAFETY_CLI_YES"
  local target target_dir bundle_cfg normalized
  local exists=0 action_word="create"

  target="$(safety_cli_resolve_mutable_target "$workspace" "$scope")" || return $?
  target_dir="$(dirname -- "$target")"
  bundle_cfg="$(safety_cli_bundle_config)"

  if [[ ! -f "$bundle_cfg" ]]; then
    echo "Error: bundle default safety config not found: $bundle_cfg" >&2
    return 1
  fi
  if ! normalized="$(killswitch_normalize_config_file "$bundle_cfg")"; then
    echo "Error: bundle default safety config failed validation" >&2
    return 1
  fi

  if [[ -L "$target" ]]; then
    echo "Error: refusing to init through a symlink: $target" >&2
    return 1
  fi
  if [[ -e "$target" ]]; then
    exists=1
    action_word="replace"
  fi

  echo "Safety init"
  echo "  scope:  $scope"
  echo "  target: $target"
  if [[ "$exists" -eq 1 ]]; then
    echo "  note:   target already exists; confirmation replaces it with the normalized bundle default"
  else
    echo "  note:   target does not exist; confirmation creates it"
  fi
  echo
  echo "Preview (normalized bundle default):"
  printf '%s' "$normalized"
  echo

  if ! safety_cli_confirm_mutation "$yes_flag" "$action_word"; then
    return 1
  fi

  # Create parent only after confirmation so cancelled previews leave no dirs.
  mkdir -p -- "$target_dir" || {
    echo "Error: cannot create directory: $target_dir" >&2
    return 1
  }
  if [[ ! -w "$target_dir" ]]; then
    echo "Error: directory is not writable: $target_dir" >&2
    return 1
  fi

  # Re-check race/symlink after confirmation before publish.
  if [[ -L "$target" ]]; then
    echo "Error: refusing to init through a symlink: $target" >&2
    return 1
  fi
  if [[ "$exists" -eq 0 && -e "$target" ]]; then
    echo "Error: safety target appeared during init (race); refusing to overwrite" >&2
    return 1
  fi

  SAFETY_CLI_MUT_TARGET="$target"
  SAFETY_CLI_MUT_HAD_ORIGINAL="$exists"
  SAFETY_CLI_MUT_DONE=0
  SAFETY_CLI_MUT_KEEP_TARGET=0
  SAFETY_CLI_MUT_TMP="$(mktemp "$target_dir/.safety-init-XXXXXX")" || {
    echo "Error: failed to create init temp file in $target_dir" >&2
    return 1
  }
  if [[ "$exists" -eq 1 ]]; then
    SAFETY_CLI_MUT_BACKUP="$(mktemp "$target_dir/.safety-init-bak-XXXXXX")" || {
      rm -f -- "$SAFETY_CLI_MUT_TMP"
      echo "Error: failed to create init backup in $target_dir" >&2
      return 1
    }
    cp -f -- "$target" "$SAFETY_CLI_MUT_BACKUP" || {
      safety_cli_mut_cleanup 1
      echo "Error: failed to back up existing safety config: $target" >&2
      return 1
    }
  fi

  trap 'safety_cli_mut_on_signal' INT TERM HUP
  trap 'safety_cli_mut_cleanup $?' EXIT

  printf '%s' "$normalized" >"$SAFETY_CLI_MUT_TMP" || {
    echo "Error: failed to write init temp file" >&2
    safety_cli_mut_cleanup 1
    trap - INT TERM HUP EXIT
    return 1
  }
  if ! killswitch_normalize_config_file "$SAFETY_CLI_MUT_TMP" >/dev/null; then
    echo "Error: init content failed validation; original preserved" >&2
    safety_cli_mut_cleanup 1
    trap - INT TERM HUP EXIT
    return 1
  fi

  if [[ -L "$target" ]]; then
    echo "Error: refusing to init through a symlink: $target" >&2
    SAFETY_CLI_MUT_KEEP_TARGET=1
    safety_cli_mut_cleanup 1
    trap - INT TERM HUP EXIT
    return 1
  fi
  if [[ "$exists" -eq 0 && -e "$target" ]]; then
    echo "Error: safety target appeared during init (race); refusing to overwrite" >&2
    SAFETY_CLI_MUT_KEEP_TARGET=1
    safety_cli_mut_cleanup 1
    trap - INT TERM HUP EXIT
    return 1
  fi

  if ! mv -f -- "$SAFETY_CLI_MUT_TMP" "$target"; then
    echo "Error: failed to publish safety config to $target" >&2
    safety_cli_mut_cleanup 1
    trap - INT TERM HUP EXIT
    return 1
  fi
  SAFETY_CLI_MUT_TMP=""
  SAFETY_CLI_MUT_DONE=1
  rm -f -- "${SAFETY_CLI_MUT_BACKUP:-}" 2>/dev/null || true
  SAFETY_CLI_MUT_BACKUP=""
  trap - INT TERM HUP EXIT

  if [[ "$exists" -eq 1 ]]; then
    printf 'Replaced %s safety config: %s\n' "$scope" "$target"
  else
    printf 'Created %s safety config: %s\n' "$scope" "$target"
  fi
  return 0
}

safety_cli_edit() {
  local workspace="$1"
  shift

  local parse_rc=0
  safety_cli_parse_scope_flags "$@" || parse_rc=$?
  if [[ "$parse_rc" -eq 64 ]]; then
    safety_cli_edit_usage
    return 0
  fi
  [[ "$parse_rc" -eq 0 ]] || return "$parse_rc"

  if [[ -n "${SAFETY_CLI_WORKSPACE_OVERRIDE:-}" ]]; then
    workspace="$(safety_cli_workspace_root "$SAFETY_CLI_WORKSPACE_OVERRIDE")" || return 1
  fi

  if ! command -v python3 >/dev/null 2>&1; then
    echo "Error: python3 is required for ralph safety edit" >&2
    return 1
  fi

  local scope="$SAFETY_CLI_SCOPE"
  local yes_flag="$SAFETY_CLI_YES"
  local target target_dir editor pre_fp=""

  target="$(safety_cli_resolve_mutable_target "$workspace" "$scope")" || return $?
  target_dir="$(dirname -- "$target")"

  echo "Safety edit"
  echo "  scope:  $scope"
  echo "  target: $target"
  echo

  if [[ -L "$target" ]]; then
    echo "Error: refusing to edit through a symlink: $target" >&2
    return 1
  fi
  if [[ ! -f "$target" ]]; then
    echo "Error: safety config not found: $target" >&2
    echo "Run: ralph safety init --${scope}" >&2
    return 1
  fi

  if ! killswitch_normalize_config_file "$target" >/dev/null; then
    echo "Error: safety config failed validation before edit: $target" >&2
    return 1
  fi

  if ! safety_cli_confirm_mutation "$yes_flag" "edit"; then
    return 1
  fi

  # Parent already exists (target file present); still refuse unwritable dirs.
  if [[ ! -w "$target_dir" ]]; then
    echo "Error: directory is not writable: $target_dir" >&2
    return 1
  fi

  SAFETY_CLI_MUT_TARGET="$target"
  SAFETY_CLI_MUT_HAD_ORIGINAL=1
  SAFETY_CLI_MUT_DONE=0
  SAFETY_CLI_MUT_KEEP_TARGET=0
  SAFETY_CLI_MUT_TMP="$(mktemp "$target_dir/.safety-edit-XXXXXX")" || {
    echo "Error: failed to create edit temp file in $target_dir" >&2
    return 1
  }
  SAFETY_CLI_MUT_BACKUP="$(mktemp "$target_dir/.safety-edit-bak-XXXXXX")" || {
    rm -f -- "$SAFETY_CLI_MUT_TMP"
    echo "Error: failed to create edit backup in $target_dir" >&2
    return 1
  }
  cp -f -- "$target" "$SAFETY_CLI_MUT_BACKUP" || {
    safety_cli_mut_cleanup 1
    echo "Error: failed to back up original safety config: $target" >&2
    return 1
  }
  pre_fp="$(safety_cli_file_fingerprint "$target")" || pre_fp=""
  cp -f -- "$target" "$SAFETY_CLI_MUT_TMP" || {
    safety_cli_mut_cleanup 1
    echo "Error: failed to seed edit buffer from $target" >&2
    return 1
  }

  trap 'safety_cli_mut_on_signal' INT TERM HUP
  trap 'safety_cli_mut_cleanup $?' EXIT

  editor="$(safety_cli_select_editor)"
  safety_cli_editor_hint "$editor"
  if ! "$editor" "$SAFETY_CLI_MUT_TMP"; then
    echo "Error: editor failed: $editor" >&2
    safety_cli_mut_cleanup 1
    trap - INT TERM HUP EXIT
    return 1
  fi

  if ! killswitch_normalize_config_file "$SAFETY_CLI_MUT_TMP" >/dev/null; then
    echo "Error: edited safety config failed validation; original preserved" >&2
    safety_cli_mut_cleanup 1
    trap - INT TERM HUP EXIT
    return 1
  fi

  if [[ -L "$target" ]]; then
    echo "Error: refusing to edit through a symlink: $target" >&2
    SAFETY_CLI_MUT_KEEP_TARGET=1
    safety_cli_mut_cleanup 1
    trap - INT TERM HUP EXIT
    return 1
  fi
  if [[ ! -f "$target" ]]; then
    echo "Error: safety target changed during edit (removed); refusing to write" >&2
    SAFETY_CLI_MUT_KEEP_TARGET=1
    safety_cli_mut_cleanup 1
    trap - INT TERM HUP EXIT
    return 1
  fi
  local now_fp
  now_fp="$(safety_cli_file_fingerprint "$target")" || now_fp=""
  if [[ -n "$pre_fp" && -n "$now_fp" && "$pre_fp" != "$now_fp" ]]; then
    echo "Error: safety target changed during edit (race); refusing to overwrite" >&2
    SAFETY_CLI_MUT_KEEP_TARGET=1
    safety_cli_mut_cleanup 1
    trap - INT TERM HUP EXIT
    return 1
  fi

  # Write normalized bytes so the published file is canonical.
  local normalized
  if ! normalized="$(killswitch_normalize_config_file "$SAFETY_CLI_MUT_TMP")"; then
    echo "Error: edited safety config failed validation; original preserved" >&2
    safety_cli_mut_cleanup 1
    trap - INT TERM HUP EXIT
    return 1
  fi
  printf '%s' "$normalized" >"$SAFETY_CLI_MUT_TMP" || {
    echo "Error: failed to write normalized edit buffer" >&2
    safety_cli_mut_cleanup 1
    trap - INT TERM HUP EXIT
    return 1
  }

  if ! mv -f -- "$SAFETY_CLI_MUT_TMP" "$target"; then
    echo "Error: failed to publish edited safety config to $target" >&2
    safety_cli_mut_cleanup 1
    trap - INT TERM HUP EXIT
    return 1
  fi
  SAFETY_CLI_MUT_TMP=""
  SAFETY_CLI_MUT_DONE=1
  rm -f -- "${SAFETY_CLI_MUT_BACKUP:-}" 2>/dev/null || true
  SAFETY_CLI_MUT_BACKUP=""
  trap - INT TERM HUP EXIT

  printf 'Edited %s safety config: %s\n' "$scope" "$target"
  return 0
}

cmd="${1:-}"
if [[ -z "$cmd" || "$cmd" == "-h" || "$cmd" == "--help" || "$cmd" == "help" ]]; then
  safety_cli_usage
  [[ -z "$cmd" ]] && exit 1 || exit 0
fi
shift

workspace="$PWD"
as_json=0
passthrough=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --workspace)
      [[ -n "${2:-}" ]] || { echo "Error: --workspace requires a path" >&2; exit 2; }
      workspace="$(safety_cli_workspace_root "$2")" || exit 1
      shift 2
      ;;
    --json)
      as_json=1
      shift
      ;;
    *)
      passthrough+=("$1")
      shift
      ;;
  esac
done

case "$cmd" in
  status)
    if [[ ${#passthrough[@]} -gt 0 ]]; then
      echo "Error: status does not accept extra arguments: ${passthrough[*]}" >&2
      exit 2
    fi
    safety_cli_status "$workspace" "$as_json"
    ;;
  validate)
    if [[ "$as_json" -eq 1 ]]; then
      echo "Error: validate does not accept --json" >&2
      exit 2
    fi
    safety_cli_validate "$workspace" "${passthrough[@]}"
    ;;
  check)
    safety_cli_check "$workspace" "$as_json" "${passthrough[@]}"
    ;;
  init)
    if [[ "$as_json" -eq 1 ]]; then
      echo "Error: init does not accept --json" >&2
      exit 2
    fi
    safety_cli_init "$workspace" "${passthrough[@]}"
    ;;
  edit)
    if [[ "$as_json" -eq 1 ]]; then
      echo "Error: edit does not accept --json" >&2
      exit 2
    fi
    safety_cli_edit "$workspace" "${passthrough[@]}"
    ;;
  *)
    echo "Error: unknown ralph safety command: $cmd" >&2
    safety_cli_usage >&2
    exit 2
    ;;
esac
