#!/usr/bin/env bash
# Deprecated alias: extended tier removed; runs the full Bats suite.
#
# Usage:
#   bash scripts/run-bats-extended.sh [run-bats options] [--] [bats arguments...]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec bash "$SCRIPT_DIR/run-bats.sh" "$@"
