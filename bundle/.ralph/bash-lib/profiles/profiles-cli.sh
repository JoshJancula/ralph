#!/usr/bin/env bash
# Public CLI for learned command-duration profiles (ralph profiles).
set -euo pipefail

_profiles_cli_dir="${BASH_SOURCE[0]%/*}"
[[ "$_profiles_cli_dir" == "${BASH_SOURCE[0]}" ]] && _profiles_cli_dir="."
# shellcheck source=../help-render.sh
source "$_profiles_cli_dir/../help-render.sh"

RALPH_HOME="${RALPH_HOME:-${HOME:-}/.ralph}"
PROFILES_PY="${_profiles_cli_dir}/../../python/command_profiles.py"

profiles_cli_usage() {
  cat <<'USAGE' | ralph_help_render
Usage: ralph profiles <command> [args]

Inspect and correct learned shell-command duration profiles under
.ralph-workspace/command-profiles/profiles.json. Recording is automatic from
runtime hooks; this CLI makes entries visible and removable so a wrong
promotion is never an invisible trap.

Commands:
  list                         Print learned commands sorted by median duration
                               (descending). Columns: median_s, observation
                               count, long-running, denylisted, fingerprint,
                               redacted command.
  show <fingerprint-prefix>    Print the full record for a unique fingerprint
                               prefix (retained durations and promotion
                               history).
  reset [<fingerprint-prefix>] Clear one entry by unique fingerprint prefix, or
                               with no argument clear the whole store after an
                               explicit confirmation prompt. Non-interactive
                               full-store reset requires --yes.

Options:
  --workspace <path>       Project root (default: current directory).
  --workspace-root <path>  State root containing command-profiles/ (default:
                           <workspace>/.ralph-workspace).
  --yes                    Confirm a full-store reset non-interactively
                           (required when stdin is not a TTY).

Examples:
  ralph profiles list
  ralph profiles show abcdef12
  ralph profiles reset abcdef12
  ralph profiles reset --yes

Requires python3. Exit 0 on success, 1 on lookup/mutation failure, 2 on usage.
USAGE
}

profiles_cli_require_python() {
  if ! command -v python3 >/dev/null 2>&1; then
    echo "Error: ralph profiles requires Python 3." >&2
    return 2
  fi
  if [[ ! -f "$PROFILES_PY" ]]; then
    echo "Error: command_profiles.py not found: $PROFILES_PY" >&2
    return 1
  fi
}

profiles_cli_resolve_workspace() {
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

profiles_cli_state_root() {
  local workspace="$1"
  local override="${2:-}"
  if [[ -n "$override" ]]; then
    printf '%s\n' "${override%/}"
    return 0
  fi
  if [[ -n "${RALPH_PLAN_WORKSPACE_ROOT:-}" ]]; then
    printf '%s\n' "${RALPH_PLAN_WORKSPACE_ROOT%/}"
    return 0
  fi
  printf '%s/.ralph-workspace\n' "${workspace%/}"
}

# Confirm a full-store reset. --yes wins; TTY requires typing "yes"; non-TTY
# without --yes refuses before any write.
profiles_cli_confirm_reset_all() {
  local yes_flag="${1:-0}"

  if [[ "$yes_flag" -eq 1 ]]; then
    echo "Confirmed non-interactively (--yes); clearing all command profiles."
    return 0
  fi
  if [[ -t 0 ]]; then
    local answer=""
    printf '\nType "yes" to clear ALL learned command profiles, or anything else (including EOF) to cancel: '
    if ! IFS= read -r answer; then
      answer=""
    fi
    if [[ "$answer" != "yes" ]]; then
      echo "Cancelled; no profiles were changed."
      return 1
    fi
    return 0
  fi
  echo "Error: non-interactive ralph profiles reset (whole store) requires --yes" >&2
  return 1
}

profiles_cli_run_py() {
  profiles_cli_require_python || return $?
  python3 "$PROFILES_PY" "$@"
}

profiles_cli_main() {
  local sub="${1:-}"
  if [[ -z "$sub" || "$sub" == "-h" || "$sub" == "--help" ]]; then
    profiles_cli_usage
    [[ -z "$sub" ]] && return 1 || return 0
  fi
  shift

  local workspace=""
  local workspace_root=""
  local yes_flag=0
  local positionals=()

  while [[ $# -gt 0 ]]; do
    case "$1" in
      -h|--help)
        profiles_cli_usage
        return 0
        ;;
      --workspace)
        [[ -n "${2:-}" ]] || {
          echo "Error: --workspace requires a path" >&2
          return 2
        }
        workspace="$2"
        shift 2
        ;;
      --workspace-root)
        [[ -n "${2:-}" ]] || {
          echo "Error: --workspace-root requires a path" >&2
          return 2
        }
        workspace_root="$2"
        shift 2
        ;;
      --yes|-y)
        yes_flag=1
        shift
        ;;
      --)
        shift
        while [[ $# -gt 0 ]]; do
          positionals+=("$1")
          shift
        done
        ;;
      --*)
        echo "Error: unknown option: $1" >&2
        profiles_cli_usage >&2
        return 2
        ;;
      *)
        positionals+=("$1")
        shift
        ;;
    esac
  done

  local resolved_workspace state_root
  resolved_workspace="$(profiles_cli_resolve_workspace "$workspace")" || return 1
  state_root="$(profiles_cli_state_root "$resolved_workspace" "$workspace_root")"

  case "$sub" in
    list)
      if [[ ${#positionals[@]} -ne 0 ]]; then
        echo "Error: ralph profiles list takes no positional arguments" >&2
        return 2
      fi
      profiles_cli_run_py list "$state_root"
      ;;
    show)
      if [[ ${#positionals[@]} -ne 1 ]]; then
        echo "Error: ralph profiles show requires exactly one fingerprint-prefix" >&2
        return 2
      fi
      profiles_cli_run_py show "$state_root" "${positionals[0]}"
      ;;
    reset)
      if [[ ${#positionals[@]} -gt 1 ]]; then
        echo "Error: ralph profiles reset accepts at most one fingerprint-prefix" >&2
        return 2
      fi
      if [[ ${#positionals[@]} -eq 0 ]]; then
        profiles_cli_confirm_reset_all "$yes_flag" || return 1
        profiles_cli_run_py reset "$state_root"
      else
        profiles_cli_run_py reset "$state_root" "${positionals[0]}"
      fi
      ;;
    *)
      echo "Error: unknown ralph profiles subcommand: $sub" >&2
      profiles_cli_usage >&2
      return 2
      ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  profiles_cli_main "$@"
fi
