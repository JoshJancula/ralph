#!/usr/bin/env bash
set -euo pipefail
# Stub runner for orchestrator characterization tests.
# Captures the resolved plan, environment, and CLI arguments into a JSON file,
# then optionally creates declared output artifacts and exits with a configured code.

resolve_out() {
  local path="${1:-}"
  path="${path//\{\{ARTIFACT_NS\}\}/$RALPH_ARTIFACT_NS}"
  path="${path//\{\{PLAN_KEY\}\}/${RALPH_PLAN_KEY:-$RALPH_ARTIFACT_NS}}"
  path="${path//\{\{STAGE_ID\}\}/${RALPH_STAGE_ID:-}}"
  printf '%s' "$path"
}

# Emulate run-plan.sh: the orchestrator forwards session strategy via the
# --session-strategy CLI flag, and the real runner converts that flag into the
# exported RALPH_PLAN_SESSION_STRATEGY env var (see
# bash-lib/run-plan/run-plan-args.sh). Mirror that conversion so the captured
# environment reflects real end-to-end propagation instead of a runner internal.
_stub_session_strategy="${RALPH_PLAN_SESSION_STRATEGY:-}"
_stub_prev_arg=""
for _stub_arg in "$@"; do
  if [[ "$_stub_prev_arg" == "--session-strategy" ]]; then
    _stub_session_strategy="$_stub_arg"
  fi
  _stub_prev_arg="$_stub_arg"
done
if [[ -n "$_stub_session_strategy" ]]; then
  RALPH_PLAN_SESSION_STRATEGY="$_stub_session_strategy"
  export RALPH_PLAN_SESSION_STRATEGY
fi

run_out="${RALPH_RUN_PLAN_CAPTURE_FILE:-}"
if [[ -z "$run_out" ]]; then
  echo "run-plan-stub: RALPH_RUN_PLAN_CAPTURE_FILE not set" >&2
  exit 2
fi

mkdir -p "$(dirname "$run_out")"

{
  echo '{'
  echo '  "args": ["'"$0"'"'
  for arg in "$@"; do
    printf '    ,%s' "$(printf '%s' "$arg" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))')"
  done
  echo ''
  echo '  ],'
  echo '  "env": {'
  echo '    "RALPH_ARTIFACT_NS": '"$(printf '%s' "${RALPH_ARTIFACT_NS:-}" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))')"
  echo '    ,"RALPH_PLAN_KEY": '"$(printf '%s' "${RALPH_PLAN_KEY:-}" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))')"
  echo '    ,"RALPH_ORCH_FILE": '"$(printf '%s' "${RALPH_ORCH_FILE:-}" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))')"
  echo '    ,"RALPH_STAGE_ID": '"$(printf '%s' "${RALPH_STAGE_ID:-}" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))')"
  echo '    ,"CURSOR_PLAN_MODEL": '"$(printf '%s' "${CURSOR_PLAN_MODEL:-}" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))')"
  echo '    ,"CLAUDE_PLAN_MODEL": '"$(printf '%s' "${CLAUDE_PLAN_MODEL:-}" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))')"
  echo '    ,"CODEX_PLAN_MODEL": '"$(printf '%s' "${CODEX_PLAN_MODEL:-}" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))')"
  echo '    ,"OPENCODE_PLAN_MODEL": '"$(printf '%s' "${OPENCODE_PLAN_MODEL:-}" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))')"
  echo '    ,"ANTIGRAVITY_PLAN_MODEL": '"$(printf '%s' "${ANTIGRAVITY_PLAN_MODEL:-}" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))')"
  echo '    ,"RALPH_MCP_PROXY_POLICY": '"$(printf '%s' "${RALPH_MCP_PROXY_POLICY:-}" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))')"
  echo '    ,"RALPH_PLAN_SESSION_STRATEGY": '"$(printf '%s' "${RALPH_PLAN_SESSION_STRATEGY:-}" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))')"
  echo '    ,"RALPH_GRADER_STAGE": '"$(printf '%s' "${RALPH_GRADER_STAGE:-}" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))')"
  echo '    ,"RALPH_RUBRIC_PATH": '"$(printf '%s' "${RALPH_RUBRIC_PATH:-}" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))')"
  echo '    ,"OPENCODE_PLAN_REASONING_EFFORT": '"$(printf '%s' "${OPENCODE_PLAN_REASONING_EFFORT:-}" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))')"
  echo '    ,"ANTIGRAVITY_PLAN_REASONING_EFFORT": '"$(printf '%s' "${ANTIGRAVITY_PLAN_REASONING_EFFORT:-}" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))')"
  echo '  }'
  echo '}'
} > "$run_out"

# If RUN_PLAN_STUB_WRITE_ARTIFACTS is a list of paths, create each as a non-empty file.
if [[ -n "${RUN_PLAN_STUB_WRITE_ARTIFACTS:-}" ]]; then
  IFS=',' read -r -a artifact_paths <<< "$RUN_PLAN_STUB_WRITE_ARTIFACTS"
  for rel in "${artifact_paths[@]}"; do
    rel="$(resolve_out "$rel")"
    [[ -z "$rel" ]] && continue
    abs="$rel"
    if [[ "$rel" != /* ]]; then
      abs="${RALPH_PROJECT_ROOT:-$(pwd)}/$rel"
    fi
    mkdir -p "$(dirname "$abs")"
    printf 'stub artifact\n' > "$abs"
  done
fi

exit "${RUN_PLAN_STUB_EXIT_CODE:-0}"
