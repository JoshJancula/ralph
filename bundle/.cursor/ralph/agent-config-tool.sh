#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}" )" && pwd)"
WORKSPACE="$(cd "$SCRIPT_DIR/../.." && pwd)"
exec "$WORKSPACE/.ralph/agent-config-tool.sh" "$@"
