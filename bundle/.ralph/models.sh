#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bash-lib/help-render.sh
source "$script_dir/bash-lib/help-render.sh"
# shellcheck source=bash-lib/select-model/model-store.sh
source "$script_dir/bash-lib/select-model/model-store.sh"

models_usage() {
  cat <<'USAGE' | ralph_help_render
Usage: models.sh <command> <runtime> [model-id]
       models.sh -h|--help

List available models for any supported runtime, or manage saved Claude and
Codex models in the Ralph global config (models.json).

Commands:
  list <runtime>              List models (one per line)
                              claude: saved models first, then missing
                                aliases (haiku, sonnet, opus, fable)
                              codex: saved models (default first)
                              cursor|opencode|antigravity: native CLI discovery
  add <runtime> <model-id>    Save a model (claude|codex only; moves to front)
  remove <runtime> <model-id> Remove a saved model (claude|codex only)

List runtimes:
  claude, codex, cursor, opencode, antigravity

Saved-store runtimes (add/remove):
  claude, codex

Environment:
  RALPH_CONFIG_HOME           Override Ralph config directory
                              (default: ${XDG_CONFIG_HOME:-$HOME/.config}/ralph)

Examples:
  models.sh list claude
  models.sh list cursor
  models.sh list opencode
  models.sh list antigravity
  models.sh add codex o4-mini
  models.sh remove claude claude-sonnet-4-20250514
USAGE
}

models_require_jq() {
  if ! command -v jq >/dev/null 2>&1; then
    echo "Error: jq is required for model management." >&2
    exit 2
  fi
}

models_validate_saved_runtime() {
  local runtime="${1:-}"
  if [[ -z "$runtime" ]]; then
    echo "Error: runtime is required (claude or codex)." >&2
    exit 2
  fi
  if ! ralph_model_store_runtime_is_valid "$runtime"; then
    echo "Error: invalid runtime: $runtime (expected claude or codex)." >&2
    exit 2
  fi
}

models_load_discovery_helpers() {
  local runtime="$1"
  case "$runtime" in
    cursor)
      # shellcheck source=bash-lib/select-model/select-model-cursor.sh
      source "$script_dir/bash-lib/select-model/select-model-cursor.sh"
      ;;
    opencode)
      # shellcheck source=bash-lib/select-model/select-model-opencode.sh
      source "$script_dir/bash-lib/select-model/select-model-opencode.sh"
      ;;
    antigravity)
      # shellcheck source=bash-lib/select-model/select-model-antigravity.sh
      source "$script_dir/bash-lib/select-model/select-model-antigravity.sh"
      ;;
    *)
      # shellcheck source=bash-lib/select-model/select-model-common.sh
      source "$script_dir/bash-lib/select-model/select-model-common.sh"
      ;;
  esac
}

models_list() {
  local runtime="${1:-}"
  if [[ -z "$runtime" ]]; then
    echo "Error: runtime is required (claude, codex, cursor, opencode, or antigravity)." >&2
    exit 2
  fi
  case "$runtime" in
    claude)
      models_load_discovery_helpers claude
      ralph_select_model_list_discovered claude
      ;;
    codex)
      ralph_model_store_list "$runtime"
      ;;
    cursor|opencode|antigravity)
      models_load_discovery_helpers "$runtime"
      if ! ralph_select_model_list_discovered "$runtime"; then
        echo "Error: unable to list models for runtime: $runtime (CLI unavailable)." >&2
        exit 1
      fi
      ;;
    *)
      echo "Error: invalid runtime: $runtime (expected claude, codex, cursor, opencode, or antigravity)." >&2
      exit 2
      ;;
  esac
}

cmd="${1:-}"
if [[ -z "$cmd" || "$cmd" == "-h" || "$cmd" == "--help" ]]; then
  models_usage
  [[ -z "$cmd" ]] && exit 2 || exit 0
fi
shift || true

models_require_jq

case "$cmd" in
  list)
    [[ $# -le 1 ]] || { echo "Error: list accepts only a runtime argument." >&2; exit 2; }
    models_list "${1:-}"
    ;;
  add)
    [[ $# -eq 2 ]] || { echo "Error: add requires <runtime> and <model-id>." >&2; exit 2; }
    models_validate_saved_runtime "${1:-}"
    [[ -n "${2:-}" ]] || { echo "Error: model-id is required." >&2; exit 2; }
    ralph_model_store_add "$1" "$2"
    ;;
  remove)
    [[ $# -eq 2 ]] || { echo "Error: remove requires <runtime> and <model-id>." >&2; exit 2; }
    models_validate_saved_runtime "${1:-}"
    [[ -n "${2:-}" ]] || { echo "Error: model-id is required." >&2; exit 2; }
    # Claude built-in aliases (haiku/sonnet/opus/fable) are runtime defaults
    # merged at list/select time; refuse exact-ID removal so the saved catalog
    # cannot drop them. Similarly named IDs, custom Claude IDs, and any Codex
    # model remain removable.
    if [[ "$1" == "claude" ]]; then
      case "$2" in
        haiku|sonnet|opus|fable)
          echo "Error: built-in Claude default aliases cannot be removed: $2" >&2
          exit 1
          ;;
      esac
    fi
    ralph_model_store_remove "$1" "$2"
    ;;
  *)
    echo "Error: unknown command: $cmd" >&2
    models_usage >&2
    exit 2
    ;;
esac
