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

_stub_env_json="$(printf '%s\0' \
  "$(pwd)" "${RALPH_PROJECT_ROOT:-}" "${RALPH_PLAN_WORKSPACE_ROOT:-}" "${RALPH_AGENT_WORKSPACE:-}" \
  "${RALPH_CONFIG_DISCOVERY_ROOT:-}" "${RALPH_GRAPH_NODE_LOG_PATH:-}" \
  "${RALPH_ARTIFACT_NS:-}" "${RALPH_PLAN_KEY:-}" "${RALPH_GRAPH_NODE_ID:-}" "${RALPH_ORCH_FILE:-}" \
  "${RALPH_STAGE_ID:-}" "${CURSOR_PLAN_MODEL:-}" "${CLAUDE_PLAN_MODEL:-}" "${CODEX_PLAN_MODEL:-}" \
  "${OPENCODE_PLAN_MODEL:-}" "${ANTIGRAVITY_PLAN_MODEL:-}" "${RALPH_MCP_PROXY_POLICY:-}" \
  "${RALPH_PLAN_SUBAGENTS:-}" \
  "${RALPH_PLAN_SESSION_STRATEGY:-}" "${RALPH_GRADER_STAGE:-}" "${RALPH_RUBRIC_PATH:-}" \
  "${OPENCODE_PLAN_REASONING_EFFORT:-}" "${ANTIGRAVITY_PLAN_REASONING_EFFORT:-}" | \
  python3 -c 'import json,sys; names=["PWD","RALPH_PROJECT_ROOT","RALPH_PLAN_WORKSPACE_ROOT","RALPH_AGENT_WORKSPACE","RALPH_CONFIG_DISCOVERY_ROOT","RALPH_GRAPH_NODE_LOG_PATH","RALPH_ARTIFACT_NS","RALPH_PLAN_KEY","RALPH_GRAPH_NODE_ID","RALPH_ORCH_FILE","RALPH_STAGE_ID","CURSOR_PLAN_MODEL","CLAUDE_PLAN_MODEL","CODEX_PLAN_MODEL","OPENCODE_PLAN_MODEL","ANTIGRAVITY_PLAN_MODEL","RALPH_MCP_PROXY_POLICY","RALPH_PLAN_SUBAGENTS","RALPH_PLAN_SESSION_STRATEGY","RALPH_GRADER_STAGE","RALPH_RUBRIC_PATH","OPENCODE_PLAN_REASONING_EFFORT","ANTIGRAVITY_PLAN_REASONING_EFFORT"]; vals=sys.stdin.buffer.read().split(b"\0")[:-1]; print(json.dumps(dict(zip(names, (v.decode() for v in vals)))) )')"

{
  echo '{'
  echo '  "args": ["'"$0"'"'
  for arg in "$@"; do
    printf '    ,%s' "$(printf '%s' "$arg" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))')"
  done
  echo ''
  echo '  ],'
  echo '  "env": '"$_stub_env_json"
  echo '}'
} > "$run_out"

# Optional delay so a caller can deliver a signal while the stage is "running".
# Touch a readiness marker first so tests can wait for the stub to be active.
if [[ -n "${RUN_PLAN_STUB_READY_FILE:-}" ]]; then
  : > "$RUN_PLAN_STUB_READY_FILE" 2>/dev/null || true
fi
if [[ -n "${RUN_PLAN_STUB_SLEEP_SECONDS:-}" ]]; then
  sleep "$RUN_PLAN_STUB_SLEEP_SECONDS"
fi

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
