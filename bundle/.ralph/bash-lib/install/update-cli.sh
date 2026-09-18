#!/usr/bin/env bash
# Public CLI for updating an existing global Ralph install (ralph update).
#
# Re-runs the global installer either from the local clone recorded at
# install time (RALPH_HOME/.install-source) or from a fresh GitHub clone
# in a temp directory that is removed on exit either way.
set -euo pipefail

_update_cli_dir="${BASH_SOURCE[0]%/*}"
[[ "$_update_cli_dir" == "${BASH_SOURCE[0]}" ]] && _update_cli_dir="."
# shellcheck source=../help-render.sh
source "$_update_cli_dir/../help-render.sh"

RALPH_HOME="${RALPH_HOME:-${HOME:-}/.ralph}"
UPDATE_CLI_DEFAULT_REPO_URL="https://github.com/JoshJancula/ralph.git"
UPDATE_CLI_SOURCE_MARKER="$RALPH_HOME/.install-source"

update_cli_usage() {
  cat <<'USAGE' | ralph_help_render
Usage: ralph update [options]

Re-run the global Ralph installer to pick up the latest changes.

If a local clone used for the original install is still on disk, you will be
asked whether to update from that clone or fetch a fresh copy from GitHub.
Non-interactive shells default to the recorded local clone when one exists,
and to GitHub otherwise.

Options:
  --from-local        Update from the recorded local clone without prompting
                       (fails if none is recorded).
  --from-github       Clone a fresh copy from GitHub and update from that,
                       without prompting.
  --repo-url <url>    Override the GitHub URL to clone
                       (default: https://github.com/JoshJancula/ralph.git).
  --branch <name>     Clone this branch instead of the default branch.
                       Implies --from-github. For testing a specific
                       in-flight or PR branch; a branch moves, so this is
                       not a stability guarantee.
  --version <ref>     Clone this tag (or any git ref) instead of the
                       default branch. Implies --from-github. Use this to
                       pin a known-good release once tags exist.
  -h, --help          Show this help.

--branch and --version both resolve to a git ref passed to
`git clone --branch`, so either accepts anything git does (branch, tag, or
PR head ref) -- the two flags exist for intent, not mechanism. Passing both
is an error.

Any other options are forwarded to install.sh --global.
USAGE
}

update_cli_recorded_source() {
  [[ -f "$UPDATE_CLI_SOURCE_MARKER" ]] || return 1
  local path
  path="$(cat "$UPDATE_CLI_SOURCE_MARKER" 2>/dev/null || true)"
  [[ -n "$path" && -f "$path/install.sh" ]] || return 1
  printf '%s\n' "$path"
}

update_cli_from_local() {
  local src="$1"
  shift
  echo "Updating Ralph from local clone: $src" >&2
  bash "$src/install.sh" --global "$@"
  echo "Update complete." >&2
}

# Not `local`: the EXIT trap below fires after this function's local scope is
# torn down (e.g. when `set -e` unwinds the stack on a failed clone/install),
# and referencing a torn-down local under `set -u` aborts the trap itself.
update_cli_tmp=""

update_cli_from_github() {
  local repo_url="$1" ref="$2"
  shift 2
  command -v git >/dev/null 2>&1 || {
    echo "Error: git is required to update from GitHub." >&2
    exit 1
  }
  update_cli_tmp="$(mktemp -d)"
  trap 'rm -rf "$update_cli_tmp"' EXIT
  local -a clone_args=(--depth 1)
  if [[ -n "$ref" ]]; then
    clone_args+=(--branch "$ref")
    echo "Cloning $repo_url (ref: $ref) ..." >&2
  else
    echo "Cloning $repo_url ..." >&2
  fi
  git clone "${clone_args[@]}" "$repo_url" "$update_cli_tmp" >&2
  bash "$update_cli_tmp/install.sh" --global "$@"
  echo "Update complete." >&2
}

update_cli_repo_url="$UPDATE_CLI_DEFAULT_REPO_URL"
update_cli_ref=""
update_cli_mode=""
update_cli_forward_args=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help)
      update_cli_usage
      exit 0
      ;;
    --from-local)
      update_cli_mode="local"
      shift
      ;;
    --from-github)
      update_cli_mode="github"
      shift
      ;;
    --repo-url)
      [[ -n "${2:-}" ]] || { echo "Error: --repo-url requires a value" >&2; exit 1; }
      update_cli_repo_url="$2"
      shift 2
      ;;
    --branch)
      [[ -n "${2:-}" ]] || { echo "Error: --branch requires a value" >&2; exit 1; }
      [[ -z "$update_cli_ref" ]] || { echo "Error: cannot combine --branch and --version" >&2; exit 1; }
      update_cli_ref="$2"
      shift 2
      ;;
    --version)
      [[ -n "${2:-}" ]] || { echo "Error: --version requires a value" >&2; exit 1; }
      [[ -z "$update_cli_ref" ]] || { echo "Error: cannot combine --branch and --version" >&2; exit 1; }
      update_cli_ref="$2"
      shift 2
      ;;
    *)
      update_cli_forward_args+=("$1")
      shift
      ;;
  esac
done

if [[ -n "$update_cli_ref" ]]; then
  [[ "$update_cli_mode" != "local" ]] || {
    echo "Error: --branch/--version clone from GitHub and cannot be combined with --from-local" >&2
    exit 1
  }
  update_cli_mode="github"
fi

update_cli_recorded=""
if update_cli_recorded="$(update_cli_recorded_source)"; then
  :
else
  update_cli_recorded=""
fi

if [[ "$update_cli_mode" == "local" ]]; then
  [[ -n "$update_cli_recorded" ]] || {
    echo "Error: no local clone recorded at $UPDATE_CLI_SOURCE_MARKER" >&2
    exit 1
  }
  update_cli_from_local "$update_cli_recorded" "${update_cli_forward_args[@]}"
  exit 0
fi

if [[ "$update_cli_mode" == "github" ]]; then
  update_cli_from_github "$update_cli_repo_url" "$update_cli_ref" "${update_cli_forward_args[@]}"
  exit 0
fi

if [[ -n "$update_cli_recorded" ]]; then
  if [[ -t 0 && -t 1 ]]; then
    printf 'Local clone found at %s.\nUpdate from (l)ocal clone or (g)itHub? [l/g] ' "$update_cli_recorded" >&2
    read -r update_cli_answer
    case "$update_cli_answer" in
      g|G|github|GitHub)
        update_cli_from_github "$update_cli_repo_url" "$update_cli_ref" "${update_cli_forward_args[@]}"
        ;;
      *)
        update_cli_from_local "$update_cli_recorded" "${update_cli_forward_args[@]}"
        ;;
    esac
  else
    echo "Non-interactive shell: defaulting to recorded local clone at $update_cli_recorded (pass --from-github to override)." >&2
    update_cli_from_local "$update_cli_recorded" "${update_cli_forward_args[@]}"
  fi
else
  update_cli_from_github "$update_cli_repo_url" "$update_cli_ref" "${update_cli_forward_args[@]}"
fi
