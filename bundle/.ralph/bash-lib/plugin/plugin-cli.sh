#!/usr/bin/env bash
# Ralph host-plugin lifecycle CLI: list | status | install | remove.
#
# Packaged assets live at $RALPH_HOME/plugins/ralph-orchestrator/<runtime>/.
# This CLI is the only host-install path; Ralph install never host-installs.
#
# Exit codes (shared Ralph contract):
#   0  successful read / dry-run / mutation
#   1  validation / refusal / runtime failure / cancelled or non-TTY confirm
#   2  usage error (unknown verb/flag/runtime, bad/missing --runtime/--scope)
set -euo pipefail

_plugin_cli_dir="${BASH_SOURCE[0]%/*}"
[[ "$_plugin_cli_dir" == "${BASH_SOURCE[0]}" ]] && _plugin_cli_dir="."

# shellcheck source=../help-render.sh
source "$_plugin_cli_dir/../help-render.sh"

# Optional test override: load adapters from an alternate directory of stub
# scripts that export the same plugin_<runtime>_* entry points. Common helpers
# always come from the real lib dir beside this CLI.
_plugin_adapter_dir="${RALPH_PLUGIN_ADAPTER_DIR:-$_plugin_cli_dir}"

# shellcheck source=plugin-common.sh
source "$_plugin_cli_dir/plugin-common.sh"
# shellcheck source=plugin-adapter-claude.sh
source "${_plugin_adapter_dir}/plugin-adapter-claude.sh"
# shellcheck source=plugin-adapter-codex.sh
source "${_plugin_adapter_dir}/plugin-adapter-codex.sh"
# shellcheck source=plugin-adapter-cursor.sh
source "${_plugin_adapter_dir}/plugin-adapter-cursor.sh"
# shellcheck source=plugin-adapter-opencode.sh
source "${_plugin_adapter_dir}/plugin-adapter-opencode.sh"
# shellcheck source=plugin-adapter-antigravity.sh
source "${_plugin_adapter_dir}/plugin-adapter-antigravity.sh"

PLUGIN_CLI_RUNTIMES=(claude codex cursor opencode antigravity)

plugin_cli_usage() {
  cat <<'USAGE' | ralph_help_render
Usage: ralph plugin <command> [options]

Host-install lifecycle for packaged Ralph orchestrator plugins.
Generated packages live under $RALPH_HOME/plugins/ralph-orchestrator/<runtime>/.
Ralph install copies those packages but never installs them into a host.

Commands:
  list                Show package availability and state for all five runtimes
  status              Show state for one runtime (requires --runtime)
  install             Preview, confirm, and host-install (requires --runtime)
  remove              Preview, confirm, and host-remove (requires --runtime)

Options:
  --runtime <name>    claude|codex|cursor|opencode|antigravity
                      Required for status|install|remove. Ignored by list
                      (list always covers all five).
  --scope <scope>     Sole supported scope for the runtime (default when omitted).
                      Claude/Codex/Cursor/Antigravity: user.
                      OpenCode: project. Any other scope exits 2.
  --workspace <path>  Project root for OpenCode project-scope installs
                      (default: current directory).
  --json              Machine-readable status/list output
  --dry-run           Print preview only; never mutate host or journal
  --yes               Confirm non-interactively (required when stdin is not a TTY)
  -h, --help          Show this help

Exit codes:
  0  successful read, dry-run, or mutation
  1  validation/refusal/runtime failure, drift refuse, cancelled/non-TTY confirm
  2  usage error (unknown command/flag/runtime, missing --runtime, bad scope)

Examples:
  ralph plugin list
  ralph plugin status --runtime cursor --json
  ralph plugin install --runtime claude --yes
  ralph plugin install --runtime opencode --workspace /path/to/project --dry-run
  ralph plugin remove --runtime cursor --yes
USAGE
}

plugin_cli_require_runtime() {
  local runtime="${1:-}"
  case "$runtime" in
    claude | codex | cursor | opencode | antigravity) return 0 ;;
    "")
      printf 'plugin: --runtime is required for this command\n' >&2
      return 2
      ;;
    *)
      printf 'plugin: unsupported runtime %s (expected claude|codex|cursor|opencode|antigravity)\n' \
        "$runtime" >&2
      return 2
      ;;
  esac
}

plugin_cli_package_available() {
  local runtime="${1:-}"
  local root
  root="$(plugin_common_package_root "$runtime")" || return 1
  [[ -d "$root" && -f "$root/.ralph-plugin-generated.json" ]]
}

plugin_cli_package_root_or_empty() {
  local runtime="${1:-}"
  local root
  root="$(plugin_common_package_root "$runtime")" || {
    printf '\n'
    return 0
  }
  if [[ -d "$root" ]]; then
    printf '%s\n' "$root"
  else
    printf '\n'
  fi
}

plugin_cli_package_meta_fields() {
  # Prints version<TAB>source or empty tabs when unavailable.
  local runtime="${1:-}"
  local root meta
  root="$(plugin_cli_package_root_or_empty "$runtime")"
  if [[ -z "$root" ]] || ! meta="$(plugin_common_package_meta "$root" 2>/dev/null)"; then
    printf '\t\n'
    return 0
  fi
  printf '%s\n' "$meta"
}

# Confirm a mutating action. --yes wins; TTY requires typing "yes"; non-TTY
# without --yes refuses before any host/journal mutation.
plugin_cli_confirm_mutation() {
  local yes_flag="${1:-0}"
  local action_word="${2:-proceed}"

  if [[ "$yes_flag" == "1" ]]; then
    printf 'Confirmed non-interactively (--yes); proceeding.\n'
    return 0
  fi
  if [[ -t 0 ]]; then
    local answer=""
    printf '\nType "yes" to %s, or anything else (including EOF) to cancel: ' "$action_word"
    if ! IFS= read -r answer; then
      answer=""
    fi
    if [[ "$answer" != "yes" ]]; then
      printf 'Cancelled; no host plugin mutation.\n'
      return 1
    fi
    return 0
  fi
  printf 'Error: non-interactive ralph plugin mutation requires --yes\n' >&2
  return 1
}

plugin_cli_resolve_scope() {
  local runtime="${1:-}"
  local scope="${2:-}"
  plugin_common_require_scope "$runtime" "$scope"
}

plugin_cli_status_state() {
  local runtime="${1:-}"
  local scope="${2:-}"
  local workspace="${3:-$PWD}"
  case "$runtime" in
    claude) plugin_claude_status "" "$scope" ;;
    codex) plugin_codex_status "" "$scope" ;;
    cursor) plugin_cursor_status "" "$scope" ;;
    opencode) plugin_opencode_status "" "$workspace" "$scope" ;;
    antigravity) plugin_antigravity_status "" "$scope" ;;
    *) return 2 ;;
  esac
}

plugin_cli_preview_install() {
  local runtime="${1:-}"
  local scope="${2:-}"
  local workspace="${3:-$PWD}"
  local yes_flag="${4:-0}"
  case "$runtime" in
    claude) plugin_claude_preview "" "$scope" "$yes_flag" ;;
    codex) plugin_codex_preview "" "$scope" ;;
    cursor) plugin_cursor_preview "" "$scope" ;;
    opencode) plugin_opencode_preview "" "$workspace" "$scope" ;;
    antigravity) plugin_antigravity_preview "" "$scope" ;;
    *) return 2 ;;
  esac
}

plugin_cli_preview_remove() {
  local runtime="${1:-}"
  local scope="${2:-}"
  local workspace="${3:-$PWD}"
  # Adapters fold remove preview into remove(dry_run=1).
  case "$runtime" in
    claude) plugin_claude_remove "" "$scope" 1 ;;
    codex) plugin_codex_remove "" "$scope" 1 ;;
    cursor) plugin_cursor_remove "" "$scope" 1 ;;
    opencode) plugin_opencode_remove "" "$workspace" "$scope" 1 ;;
    antigravity) plugin_antigravity_remove "" "$scope" 1 ;;
    *) return 2 ;;
  esac
}

plugin_cli_do_install() {
  local runtime="${1:-}"
  local scope="${2:-}"
  local workspace="${3:-$PWD}"
  local dry_run="${4:-0}"
  local yes_flag="${5:-0}"
  case "$runtime" in
    claude) plugin_claude_install "" "$scope" "$dry_run" "$yes_flag" ;;
    codex) plugin_codex_install "" "$scope" "$dry_run" ;;
    cursor) plugin_cursor_install "" "$scope" "$dry_run" ;;
    opencode) plugin_opencode_install "" "$workspace" "$scope" "$dry_run" ;;
    antigravity) plugin_antigravity_install "" "$scope" "$dry_run" ;;
    *) return 2 ;;
  esac
}

plugin_cli_do_remove() {
  local runtime="${1:-}"
  local scope="${2:-}"
  local workspace="${3:-$PWD}"
  local dry_run="${4:-0}"
  case "$runtime" in
    claude) plugin_claude_remove "" "$scope" "$dry_run" ;;
    codex) plugin_codex_remove "" "$scope" "$dry_run" ;;
    cursor) plugin_cursor_remove "" "$scope" "$dry_run" ;;
    opencode) plugin_opencode_remove "" "$workspace" "$scope" "$dry_run" ;;
    antigravity) plugin_antigravity_remove "" "$scope" "$dry_run" ;;
    *) return 2 ;;
  esac
}

plugin_cli_row_json() {
  local runtime="$1" scope="$2" state="$3" available="$4"
  local root version source meta
  root="$(plugin_cli_package_root_or_empty "$runtime")"
  meta="$(plugin_cli_package_meta_fields "$runtime")"
  version="${meta%%$'\t'*}"
  source="${meta#*$'\t'}"
  if command -v jq >/dev/null 2>&1; then
    jq -n \
      --arg runtime "$runtime" \
      --arg scope "$scope" \
      --arg state "$state" \
      --argjson packageAvailable "$available" \
      --arg packageRoot "$root" \
      --arg packageVersion "$version" \
      --arg packageSource "$source" \
      '{
        runtime: $runtime,
        scope: $scope,
        state: $state,
        packageAvailable: $packageAvailable,
        packageRoot: (if $packageRoot == "" then null else $packageRoot end),
        packageVersion: (if $packageVersion == "" then null else $packageVersion end),
        packageSource: (if $packageSource == "" then null else $packageSource end)
      }'
    return 0
  fi
  python3 - "$runtime" "$scope" "$state" "$available" "$root" "$version" "$source" <<'PY'
import json, sys
runtime, scope, state, available, root, version, source = sys.argv[1:8]
print(json.dumps({
    "runtime": runtime,
    "scope": scope,
    "state": state,
    "packageAvailable": available == "true",
    "packageRoot": root or None,
    "packageVersion": version or None,
    "packageSource": source or None,
}, separators=(",", ":")))
PY
}

plugin_cli_cmd_list() {
  local as_json="${1:-0}"
  local workspace="${2:-$PWD}"
  local runtime scope state available avail_json
  local rows_json="[]"

  if [[ "$as_json" != "1" ]]; then
    printf '%s\t%s\t%s\t%s\n' "runtime" "scope" "package" "state"
  fi

  for runtime in "${PLUGIN_CLI_RUNTIMES[@]}"; do
    scope="$(plugin_common_default_scope "$runtime")"
    if plugin_cli_package_available "$runtime"; then
      available="yes"
      avail_json="true"
    else
      available="no"
      avail_json="false"
    fi
    state="$(plugin_cli_status_state "$runtime" "$scope" "$workspace")"
    if [[ "$as_json" == "1" ]]; then
      if command -v jq >/dev/null 2>&1; then
        rows_json="$(jq -c --argjson row "$(plugin_cli_row_json "$runtime" "$scope" "$state" "$avail_json")" \
          '. + [$row]' <<<"$rows_json")"
      else
        # Accumulate via python when jq is absent.
        rows_json="$(python3 - "$rows_json" "$(plugin_cli_row_json "$runtime" "$scope" "$state" "$avail_json")" <<'PY'
import json, sys
rows = json.loads(sys.argv[1])
rows.append(json.loads(sys.argv[2]))
print(json.dumps(rows, separators=(",", ":")))
PY
)"
      fi
    else
      printf '%s\t%s\t%s\t%s\n' "$runtime" "$scope" "$available" "$state"
    fi
  done

  if [[ "$as_json" == "1" ]]; then
    if command -v jq >/dev/null 2>&1; then
      jq -n --argjson plugins "$rows_json" '{schemaVersion:1, plugins:$plugins}'
    else
      python3 - "$rows_json" <<'PY'
import json, sys
print(json.dumps({"schemaVersion": 1, "plugins": json.loads(sys.argv[1])}, separators=(",", ":")))
PY
    fi
  fi
}

plugin_cli_cmd_status() {
  local runtime="${1:-}"
  local scope="${2:-}"
  local workspace="${3:-$PWD}"
  local as_json="${4:-0}"
  local state available avail_json

  plugin_cli_require_runtime "$runtime" || return $?
  scope="$(plugin_cli_resolve_scope "$runtime" "$scope")" || return $?
  state="$(plugin_cli_status_state "$runtime" "$scope" "$workspace")"
  if plugin_cli_package_available "$runtime"; then
    available="yes"
    avail_json="true"
  else
    available="no"
    avail_json="false"
  fi

  if [[ "$as_json" == "1" ]]; then
    if command -v jq >/dev/null 2>&1; then
      jq -n --argjson row "$(plugin_cli_row_json "$runtime" "$scope" "$state" "$avail_json")" \
        '$row + {schemaVersion:1}'
    else
      python3 - "$(plugin_cli_row_json "$runtime" "$scope" "$state" "$avail_json")" <<'PY'
import json, sys
row = json.loads(sys.argv[1])
row["schemaVersion"] = 1
print(json.dumps(row, separators=(",", ":")))
PY
    fi
    return 0
  fi

  printf 'runtime: %s\n' "$runtime"
  printf 'scope: %s\n' "$scope"
  printf 'package: %s\n' "$available"
  printf 'state: %s\n' "$state"
  local root
  root="$(plugin_cli_package_root_or_empty "$runtime")"
  [[ -n "$root" ]] && printf 'packageRoot: %s\n' "$root"
}

plugin_cli_cmd_install() {
  local runtime="${1:-}"
  local scope="${2:-}"
  local workspace="${3:-$PWD}"
  local dry_run="${4:-0}"
  local yes_flag="${5:-0}"

  plugin_cli_require_runtime "$runtime" || return $?
  scope="$(plugin_cli_resolve_scope "$runtime" "$scope")" || return $?

  if ! plugin_cli_package_available "$runtime"; then
    printf 'plugin: packaged asset missing for %s under %s\n' \
      "$runtime" "$(plugin_common_package_root "$runtime")" >&2
    return 1
  fi

  if [[ "$dry_run" == "1" ]]; then
    plugin_cli_do_install "$runtime" "$scope" "$workspace" 1 "$yes_flag"
    return $?
  fi

  # Preview is mandatory before confirmation.
  plugin_cli_preview_install "$runtime" "$scope" "$workspace" "$yes_flag" || return 1
  plugin_cli_confirm_mutation "$yes_flag" "install the ${runtime} host plugin" || return 1
  plugin_cli_do_install "$runtime" "$scope" "$workspace" 0 "$yes_flag"
}

plugin_cli_cmd_remove() {
  local runtime="${1:-}"
  local scope="${2:-}"
  local workspace="${3:-$PWD}"
  local dry_run="${4:-0}"
  local yes_flag="${5:-0}"
  local state

  plugin_cli_require_runtime "$runtime" || return $?
  scope="$(plugin_cli_resolve_scope "$runtime" "$scope")" || return $?

  # Drift / unverifiable refusal happens inside adapters; surface early for clarity.
  state="$(plugin_cli_status_state "$runtime" "$scope" "$workspace")"
  if [[ "$dry_run" != "1" && "$state" == "drifted" ]]; then
    printf 'plugin: refuse remove for %s (state=drifted); repair host or journal first\n' \
      "$runtime" >&2
    return 1
  fi

  if [[ "$dry_run" == "1" ]]; then
    plugin_cli_do_remove "$runtime" "$scope" "$workspace" 1
    return $?
  fi

  plugin_cli_preview_remove "$runtime" "$scope" "$workspace" || return 1
  plugin_cli_confirm_mutation "$yes_flag" "remove the ${runtime} host plugin" || return 1
  plugin_cli_do_remove "$runtime" "$scope" "$workspace" 0
}

# --- argv -------------------------------------------------------------------

cmd="${1:-}"
if [[ -z "$cmd" || "$cmd" == "-h" || "$cmd" == "--help" || "$cmd" == "help" ]]; then
  plugin_cli_usage
  [[ -z "$cmd" ]] && exit 1 || exit 0
fi
shift

runtime=""
scope=""
workspace="${RALPH_PROJECT_ROOT:-$PWD}"
as_json=0
dry_run=0
yes_flag=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --runtime)
      [[ -n "${2:-}" ]] || {
        printf 'Error: --runtime requires a value\n' >&2
        exit 2
      }
      runtime="$2"
      shift 2
      ;;
    --scope)
      [[ -n "${2:-}" ]] || {
        printf 'Error: --scope requires a value\n' >&2
        exit 2
      }
      scope="$2"
      shift 2
      ;;
    --workspace)
      [[ -n "${2:-}" ]] || {
        printf 'Error: --workspace requires a path\n' >&2
        exit 2
      }
      if [[ ! -d "$2" ]]; then
        printf 'Error: workspace is not a directory: %s\n' "$2" >&2
        exit 1
      fi
      workspace="$(cd "$2" && pwd)"
      shift 2
      ;;
    --json)
      as_json=1
      shift
      ;;
    --dry-run)
      dry_run=1
      shift
      ;;
    --yes | -y)
      yes_flag=1
      shift
      ;;
    -h | --help)
      plugin_cli_usage
      exit 0
      ;;
    *)
      printf 'Error: unknown plugin argument: %s\n' "$1" >&2
      plugin_cli_usage >&2
      exit 2
      ;;
  esac
done

case "$cmd" in
  list)
    if [[ -n "$runtime" ]]; then
      printf 'Error: list does not accept --runtime (always covers all five)\n' >&2
      exit 2
    fi
    if [[ -n "$scope" ]]; then
      printf 'Error: list does not accept --scope\n' >&2
      exit 2
    fi
    if [[ "$dry_run" == "1" || "$yes_flag" == "1" ]]; then
      printf 'Error: list does not accept --dry-run or --yes\n' >&2
      exit 2
    fi
    plugin_cli_cmd_list "$as_json" "$workspace"
    ;;
  status)
    if [[ "$dry_run" == "1" || "$yes_flag" == "1" ]]; then
      printf 'Error: status does not accept --dry-run or --yes\n' >&2
      exit 2
    fi
    plugin_cli_cmd_status "$runtime" "$scope" "$workspace" "$as_json"
    ;;
  install)
    if [[ "$as_json" == "1" ]]; then
      printf 'Error: install does not accept --json\n' >&2
      exit 2
    fi
    plugin_cli_cmd_install "$runtime" "$scope" "$workspace" "$dry_run" "$yes_flag"
    ;;
  remove)
    if [[ "$as_json" == "1" ]]; then
      printf 'Error: remove does not accept --json\n' >&2
      exit 2
    fi
    plugin_cli_cmd_remove "$runtime" "$scope" "$workspace" "$dry_run" "$yes_flag"
    ;;
  *)
    printf 'Error: unknown ralph plugin command: %s\n' "$cmd" >&2
    plugin_cli_usage >&2
    exit 2
    ;;
esac
