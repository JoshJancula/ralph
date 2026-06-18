#!/usr/bin/env bash
#
# Compatibility wrapper around the canonical Ralph MCP server. The previous
# split fast-path implementation diverged from the main server and broke
# long-lived stdio sessions after the first delegated request.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FULL_SERVER="$SCRIPT_DIR/mcp-server.sh"
exec bash "$FULL_SERVER" "$@"
