#!/usr/bin/env bash
set -euo pipefail

print_usage() {
  cat <<'EOU'
Usage: usage-report.sh [OPTIONS]

Options:
  --workspace <path>                   Workspace root (default: current directory).
  --logs-dir <path>                    Directory containing usage logs (default: <workspace>/.ralph-workspace/logs).
  --format text|json                   Output format: text or json (default: text).
  -h, --help                           Show this message.
EOU
}

workspace="$PWD"
logs_dir=""
format="text"

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help)
      print_usage
      exit 0
      ;;
    --workspace)
      if [[ -z "${2:-}" ]]; then
        echo "Error: --workspace requires a workspace path." >&2
        exit 1
      fi
      workspace="$2"
      shift 2
      ;;
    --logs-dir)
      if [[ -z "${2:-}" ]]; then
        echo "Error: --logs-dir requires a directory path." >&2
        exit 1
      fi
      logs_dir="$2"
      shift 2
      ;;
    --format)
      if [[ -z "${2:-}" ]]; then
        echo "Error: --format requires text or json." >&2
        exit 1
      fi
      case "$2" in
        text|json)
          format="$2"
          ;;
        *)
          echo "Error: --format must be text or json." >&2
          exit 1
          ;;
      esac
      shift 2
      ;;
    *)
      echo "Error: unknown argument $1" >&2
      exit 1
      ;;
  esac
done

workspace="$(cd "$workspace" && pwd)"

if [[ -z "$logs_dir" ]]; then
  logs_dir="${workspace}/.ralph-workspace/logs"
fi

if ! command -v python3 >/dev/null 2>&1; then
  echo "Error: python3 not found on PATH" >&2
  exit 1
fi

exec python3 "${workspace}/.ralph/bash-lib/ralph-usage-summary-text.py" all --logs-dir "$logs_dir" --workspace "$workspace" --format "$format"
