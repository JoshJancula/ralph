#!/usr/bin/env bash
# Generate host plugin packages from canonical plugin inputs.
#
# Usage:
#   bash scripts/sync-plugin-assets.sh [--check] [--skip-runtime-check]
#
# Default writes adapter trees under plugins/ralph-orchestrator/. --check
# compares without writing and exits nonzero when any generated file is
# missing, differs, or is stale. Unless --skip-runtime-check is set, this
# script runs scripts/sync-runtime-assets.sh --check first. Runtime sync never
# calls this script.
set -euo pipefail

SCRIPT_DIR="${SCRIPT_DIR:-}"
if [[ -z "$SCRIPT_DIR" ]]; then
  _sync_script_ref="${BASH_SOURCE[0]}"
  if [[ -L "$_sync_script_ref" ]]; then
    _sync_script_dir="$(cd "$(dirname "$_sync_script_ref")" && pwd)"
    _sync_script_ref="$(cd "$_sync_script_dir" && cd "$(dirname "$(readlink "$_sync_script_ref")")" && pwd)/$(basename "$(readlink "${BASH_SOURCE[0]}")")"
  fi
  SCRIPT_DIR="$(cd "$(dirname "$_sync_script_ref")" && pwd)"
fi
if [[ -z "${REPO_ROOT:-}" ]]; then
  REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
fi

CHECK_MODE=0
SKIP_RUNTIME_CHECK=0

sync_plugin_assets_usage() {
  cat <<'EOF' >&2
Usage: sync-plugin-assets.sh [--check] [--skip-runtime-check]

Regenerate host plugin packages from canonical plugin inputs.

Options:
  --check                 Compare generated files without writing; exit nonzero on drift.
  --skip-runtime-check    Do not run sync-runtime-assets.sh --check first.
  -h, --help              Show this help.
EOF
  exit 1
}

sync_plugin_assets_parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --check)
        CHECK_MODE=1
        ;;
      --skip-runtime-check)
        SKIP_RUNTIME_CHECK=1
        ;;
      -h | --help)
        sync_plugin_assets_usage
        ;;
      *)
        sync_plugin_assets_usage
        ;;
    esac
    shift
  done
}

sync_plugin_assets_parse_args "$@"

if [[ "$SKIP_RUNTIME_CHECK" -eq 0 ]]; then
  bash "$SCRIPT_DIR/sync-runtime-assets.sh" --check
fi

if ! command -v python3 >/dev/null 2>&1; then
  printf 'python3 is required for sync-plugin-assets.sh\n' >&2
  exit 1
fi

PYTHON_GENERATOR="$REPO_ROOT/bundle/.ralph/python/sync_plugin_assets.py"
if [[ ! -f "$PYTHON_GENERATOR" ]]; then
  printf 'missing generator: %s\n' "$PYTHON_GENERATOR" >&2
  exit 1
fi

python_args=(--repo-root "$REPO_ROOT")
if [[ "$CHECK_MODE" -eq 1 ]]; then
  python_args+=(--check)
fi

python3 "$PYTHON_GENERATOR" "${python_args[@]}"
