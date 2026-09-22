#!/usr/bin/env bash
# Deterministic ralph CLI stub for PLAN18 acceptance journeys.
#
# Delegates every subcommand to the real `ralph` binary (resolved via
# RALPH_ACCEPTANCE_REAL_RALPH, falling back to the first `ralph` on PATH other
# than this script) EXCEPT:
#   - `workflow runs`, `workflow status`, and `workflow actions list`
#   - `safety status|check|validate` (fixture workspace is not a full Ralph
#     install; real safety resolution can miss the dashboard's state-root)
# Those surfaces return canned / local-file behavior so e2e stays offline.
set -euo pipefail

FIXTURE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REAL_RALPH="${RALPH_ACCEPTANCE_REAL_RALPH:-}"
if [ -z "$REAL_RALPH" ]; then
  REAL_RALPH="$(command -v ralph || true)"
fi

emit() {
  cat "$FIXTURE_DIR/run-states/$1"
}

# --- safety (fixture-local; never execute command text) --------------------

safety_project_path() {
  local ws="${RALPH_PLAN_WORKSPACE_ROOT:-}"
  if [ -n "$ws" ]; then
    printf '%s\n' "${ws%/}/killswitch.json"
    return 0
  fi
  printf '%s\n' "$FIXTURE_DIR/acceptance-workspace/.ralph-workspace/killswitch.json"
}

safety_empty_env_overrides() {
  cat <<'EOF'
{"RALPH_KILLSWITCH_DISABLED":null,"RALPH_KILLSWITCH_OVERRIDE_FILE":null,"RALPH_BANNED_TOOLS":null,"RALPH_BANNED_PATHS":null,"RALPH_BANNED_PATTERNS":null,"RALPH_ALLOWED_TOOLS":null,"RALPH_ALLOWED_PATHS":null,"RALPH_ALLOWED_COMMANDS":null,"RALPH_ALLOWED_PATTERNS":null,"RALPH_MCP_TOOL_DENYLIST":null}
EOF
}

safety_status_json() {
  local project_path source path present selected warnings bundle_selected
  project_path="$(safety_project_path)"
  if [ -f "$project_path" ]; then
    source="project"
    path="$project_path"
    present="true"
    selected="true"
    bundle_selected="false"
    warnings="[]"
  else
    source="bundle"
    path="$FIXTURE_DIR/bundle-seed-killswitch.json"
    present="false"
    selected="false"
    bundle_selected="true"
    warnings='["Using bundle default; project and global configs are absent"]'
  fi
  cat <<EOF
{"schemaVersion":1,"enabled":true,"dryRun":false,"source":"$source","path":"$path","precedence":[{"source":"override","path":null,"present":false,"selected":false},{"source":"project","path":"$project_path","present":$present,"selected":$selected},{"source":"global","path":null,"present":false,"selected":false},{"source":"bundle","path":"$FIXTURE_DIR/bundle-seed-killswitch.json","present":true,"selected":$bundle_selected}],"environmentOverrides":$(safety_empty_env_overrides),"counts":{"bannedTools":0,"toolDenylist":0,"allowedTools":0,"bannedPaths":5,"allowedPaths":0,"allowedCommands":0,"allowedPatterns":0,"deniedArgumentPatterns":0,"customRules":3},"warnings":$warnings}
EOF
}

safety_check_json() {
  local command="$1"
  local project_path source matched=""
  project_path="$(safety_project_path)"
  if [ -f "$project_path" ]; then
    source="project"
  else
    source="bundle"
  fi
  case "$command" in
    sudo\ *|sudo) matched="no_sudo" ;;
    *'rm -rf /'*) matched="no_rm_rf_root" ;;
    *'git push --force'*) matched="no_force_push" ;;
  esac
  if [ -n "$matched" ]; then
    printf '%s\n' "{\"schemaVersion\":1,\"outcome\":\"deny\",\"source\":\"$source\",\"matchedRule\":\"$matched\",\"precedence\":[],\"dryRun\":false}"
  else
    printf '%s\n' "{\"schemaVersion\":1,\"outcome\":\"allow\",\"source\":\"$source\",\"matchedRule\":null,\"precedence\":[],\"dryRun\":false}"
  fi
}

safety_validate_file() {
  local file="$1"
  if [ ! -f "$file" ]; then
    echo "Error: file not found: $file" >&2
    return 1
  fi
  if ! python3 -c '
import json, sys
path = sys.argv[1]
with open(path, encoding="utf-8") as f:
    data = json.load(f)
if not isinstance(data, dict):
    raise SystemExit("killswitch.json must be a JSON object")
if data.get("schema_version") != 2:
    raise SystemExit("schema_version must be 2")
print("Valid:", path)
' "$file"; then
    return 1
  fi
  return 0
}

if [ "${1:-}" = "safety" ]; then
  case "${2:-}" in
    status)
      if [ "${3:-}" = "--json" ] || [ "${3:-}" = "" ]; then
        safety_status_json
        exit 0
      fi
      ;;
    check)
      cmd=""
      shift 2
      while [ "$#" -gt 0 ]; do
        case "$1" in
          --command)
            cmd="${2:-}"
            shift 2
            ;;
          --json)
            shift
            ;;
          *)
            shift
            ;;
        esac
      done
      if [ -z "$cmd" ]; then
        echo "Error: --command is required" >&2
        exit 1
      fi
      safety_check_json "$cmd"
      exit 0
      ;;
    validate)
      file=""
      shift 2
      while [ "$#" -gt 0 ]; do
        case "$1" in
          --file)
            file="${2:-}"
            shift 2
            ;;
          *)
            file="$1"
            shift
            ;;
        esac
      done
      if [ -z "$file" ]; then
        echo "Error: --file is required" >&2
        exit 1
      fi
      safety_validate_file "$file"
      exit $?
      ;;
  esac
  echo "ralph-stub.sh: unsupported safety subcommand: ${2:-}" >&2
  exit 1
fi

if [ "${1:-}" = "workflow" ] && [ "${2:-}" = "runs" ]; then
  emit "runs-list.json"
  exit 0
fi

if [ "${1:-}" = "workflow" ] && [ "${2:-}" = "status" ]; then
  case "${3:-}" in
    run-waiting-approval) emit "status-waiting-approval.json" ;;
    run-failed-verification) emit "status-failed-verification.json" ;;
    run-rework) emit "status-rework.json" ;;
    run-completed) emit "status-completed.json" ;;
    *) echo "Error: run not found: ${3:-}" >&2; exit 1 ;;
  esac
  exit 0
fi

if [ "${1:-}" = "workflow" ] && [ "${2:-}" = "actions" ] && [ "${3:-}" = "list" ]; then
  case "${4:-}" in
    run-waiting-approval) emit "actions-waiting-approval.json" ;;
    run-failed-verification) emit "actions-empty.json" ;;
    run-rework) emit "actions-empty.json" ;;
    run-completed) emit "actions-empty.json" ;;
    *) echo "Error: run not found: ${4:-}" >&2; exit 1 ;;
  esac
  exit 0
fi

if [ -z "$REAL_RALPH" ]; then
  echo "ralph-stub.sh: no real ralph binary found to delegate to" >&2
  exit 1
fi

exec "$REAL_RALPH" "$@"
