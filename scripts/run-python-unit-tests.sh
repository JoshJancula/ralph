#!/usr/bin/env bash
# Run the Ralph Python unit test suite using stdlib unittest discovery.
#
# Usage:
#   bash scripts/run-python-unit-tests.sh [unittest arguments...]
#
# Examples:
#   bash scripts/run-python-unit-tests.sh
#   bash scripts/run-python-unit-tests.sh -v
#   bash scripts/run-python-unit-tests.sh -f

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

usage() {
  cat <<'EOF'
Usage: bash scripts/run-python-unit-tests.sh [unittest arguments...]

Run the Ralph Python unit test suite using stdlib unittest discovery
against tests/python.

Options (passed through to unittest):
  -v, --verbose         Verbose output
  -q, --quiet           Quiet output
  -f, --failfast        Stop on first fail or error
  -b, --buffer          Buffer stdout and stderr during tests
  -k TESTNAMEPATTERNS   Only run tests matching the given substring
  -h, --help            Show unittest help (or this help if no arguments)

Examples:
  bash scripts/run-python-unit-tests.sh
  bash scripts/run-python-unit-tests.sh -v
  bash scripts/run-python-unit-tests.sh -v -k token_estimate
EOF
}

# Check if help was requested
if [[ "$#" -eq 0 ]]; then
  :  # No arguments, continue to run tests
elif [[ "$1" == "-h" ]] || [[ "$1" == "--help" ]]; then
  usage
  exit 0
fi

cd "$REPO_ROOT"

# Run unittest discovery with all arguments passed through
exec python3 -m unittest discover -s tests/python -p 'test_*.py' "$@"
