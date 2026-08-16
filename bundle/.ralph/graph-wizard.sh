#!/usr/bin/env bash
# Thin shim: `ralph create graph` pre-selects graph mode on the shared
# wizard engine. See pipeline-wizard.sh for the actual flow.
set -euo pipefail
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec bash "$script_dir/pipeline-wizard.sh" --mode graph "$@"
