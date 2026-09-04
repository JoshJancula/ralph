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
#
# Install packaging: ./install.sh copies validated packages to
# $RALPH_HOME/plugins/ralph-orchestrator/<runtime>/ as installer-owned assets.
# It never host-installs plugins. Each package must keep installable metadata in
# .ralph-plugin-generated.json (schemaVersion, pluginVersion, sourceDescriptor)
# with pluginVersion matching plugins/ralph-orchestrator/VERSION.
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

# Fail closed when Claude/Codex packaged roots lack marketplace metadata that
# resolves exactly ralph-orchestrator@ralph-plugins. Adapters must not synthesize
# this metadata at install time.
sync_plugin_assets_validate_marketplace_metadata() {
  local claude_market codex_market
  claude_market="$REPO_ROOT/plugins/ralph-orchestrator/claude/.claude-plugin/marketplace.json"
  codex_market="$REPO_ROOT/plugins/ralph-orchestrator/codex/.agents/plugins/marketplace.json"
  if [[ ! -f "$claude_market" ]]; then
    printf 'sync-plugin-assets: missing Claude marketplace metadata: %s\n' "$claude_market" >&2
    return 1
  fi
  if [[ ! -f "$codex_market" ]]; then
    printf 'sync-plugin-assets: missing Codex marketplace metadata: %s\n' "$codex_market" >&2
    return 1
  fi
  python3 - "$claude_market" "$codex_market" <<'PY'
import json
import sys

def check(path, label):
    try:
        with open(path, encoding="utf-8") as fh:
            data = json.load(fh)
    except (OSError, json.JSONDecodeError) as exc:
        print(f"sync-plugin-assets: invalid {label} marketplace JSON: {exc}", file=sys.stderr)
        sys.exit(1)
    plugins = data.get("plugins")
    if data.get("name") != "ralph-plugins":
        print(
            f"sync-plugin-assets: {label} marketplace name must be ralph-plugins",
            file=sys.stderr,
        )
        sys.exit(1)
    if not isinstance(plugins, list) or not any(
        isinstance(p, dict) and p.get("name") == "ralph-orchestrator" for p in plugins
    ):
        print(
            f"sync-plugin-assets: {label} marketplace must resolve "
            "ralph-orchestrator@ralph-plugins",
            file=sys.stderr,
        )
        sys.exit(1)

check(sys.argv[1], "Claude")
check(sys.argv[2], "Codex")
PY
}

# Fail closed when a generated package cannot be packaged by install.sh.
sync_plugin_assets_validate_install_metadata() {
  local version_file="$REPO_ROOT/plugins/ralph-orchestrator/VERSION"
  local expected=""
  local runtime meta
  if [[ ! -f "$version_file" ]]; then
    printf 'sync-plugin-assets: missing %s\n' "$version_file" >&2
    return 1
  fi
  expected="$(tr -d '[:space:]' <"$version_file")"
  if [[ -z "$expected" ]]; then
    printf 'sync-plugin-assets: empty VERSION file\n' >&2
    return 1
  fi
  for runtime in claude codex cursor opencode antigravity; do
    meta="$REPO_ROOT/plugins/ralph-orchestrator/$runtime/.ralph-plugin-generated.json"
    if [[ ! -f "$meta" ]]; then
      printf 'sync-plugin-assets: missing install metadata: %s\n' "$meta" >&2
      return 1
    fi
    python3 - "$meta" "$expected" "$runtime" <<'PY'
import json
import sys

path, expected, runtime = sys.argv[1], sys.argv[2], sys.argv[3]
try:
    with open(path, encoding="utf-8") as fh:
        data = json.load(fh)
except (OSError, json.JSONDecodeError) as exc:
    print(f"sync-plugin-assets: invalid JSON in {path}: {exc}", file=sys.stderr)
    sys.exit(1)

schema = data.get("schemaVersion")
version = data.get("pluginVersion")
source = data.get("sourceDescriptor")
errors = []
if not isinstance(schema, int) or schema < 1:
    errors.append("schemaVersion must be an int >= 1")
if not isinstance(version, str) or not version.strip():
    errors.append("pluginVersion must be a non-empty string")
elif version.strip() != expected:
    errors.append(f"pluginVersion {version!r} != VERSION {expected!r}")
if not isinstance(source, str) or not source.strip():
    errors.append("sourceDescriptor must be a non-empty string")
if errors:
    print(
        f"sync-plugin-assets: install metadata invalid for {runtime}: "
        + "; ".join(errors),
        file=sys.stderr,
    )
    sys.exit(1)
PY
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
sync_plugin_assets_validate_install_metadata
sync_plugin_assets_validate_marketplace_metadata
