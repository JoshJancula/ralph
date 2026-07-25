#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bash-lib/select-model/model-store.sh
source "$script_dir/bash-lib/select-model/model-store.sh"

models_usage() {
  cat <<'USAGE'
Usage: models.sh <command> <runtime> [model-id]
       models.sh -h|--help

Manage saved Claude and Codex models in the Ralph global config (models.json).

Commands:
  list <runtime>              List saved models (one per line, default first)
  add <runtime> <model-id>    Save a model (moves to front if already saved)
  remove <runtime> <model-id> Remove a saved model

Runtimes:
  claude, codex

Environment:
  RALPH_CONFIG_HOME           Override Ralph config directory
                              (default: ${XDG_CONFIG_HOME:-$HOME/.config}/ralph)

Examples:
  models.sh list claude
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

models_validate_runtime() {
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
    models_validate_runtime "${1:-}"
    ralph_model_store_list "$1"
    ;;
  add)
    [[ $# -eq 2 ]] || { echo "Error: add requires <runtime> and <model-id>." >&2; exit 2; }
    models_validate_runtime "${1:-}"
    [[ -n "${2:-}" ]] || { echo "Error: model-id is required." >&2; exit 2; }
    ralph_model_store_add "$1" "$2"
    ;;
  remove)
    [[ $# -eq 2 ]] || { echo "Error: remove requires <runtime> and <model-id>." >&2; exit 2; }
    models_validate_runtime "${1:-}"
    [[ -n "${2:-}" ]] || { echo "Error: model-id is required." >&2; exit 2; }
    ralph_model_store_remove "$1" "$2"
    ;;
  *)
    echo "Error: unknown command: $cmd" >&2
    models_usage >&2
    exit 2
    ;;
esac
