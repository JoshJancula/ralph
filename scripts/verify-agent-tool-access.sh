#!/usr/bin/env bash
# Verify Agent Tool Access (native vs ralph) for Ralph plan runs.
#
# Creates a small read/search-heavy temporary plan, exercises Ralph MCP tools
# (tools/list, bounded previews, resultId paging), and optionally runs
# available runtime CLIs in native and ralph modes.
#
# Usage:
#   bash scripts/verify-agent-tool-access.sh [--test|--dry-run] [--live] [--runtime RUNTIME]...
#
# Modes:
#   --test / --dry-run   MCP verification only; print planned runtime runs without invoking CLIs.
#   --live               Explicitly run live plan invocations for installed runtime CLIs.
#   (default)            MCP verification only; never invokes a runtime CLI.
#
# Requires: bash, jq. Live runs also need runtime CLIs and credentials.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
RUN_PLAN="$REPO_ROOT/.ralph/run-plan.sh"
MCP_SERVER="$REPO_ROOT/.ralph/mcp-server.sh"
CLI_HELPERS="$REPO_ROOT/.ralph/bash-lib/run-plan-cli-helpers.sh"
POLICY_LIB="$REPO_ROOT/.ralph/bash-lib/mcp-proxy/mcp-proxy-policy.sh"
RESULT_LIB="$REPO_ROOT/.ralph/bash-lib/mcp-proxy/mcp-proxy-result.sh"
TOOLS_LIB="$REPO_ROOT/.ralph/bash-lib/mcp-proxy/mcp-proxy-tools.sh"

ALL_RUNTIMES=(cursor claude codex opencode)
DRY_RUN=1
LIVE_RUN=0
SELECTED_RUNTIMES=()
KEEP_WORKSPACE=0
WORKSPACE=""
PLAN_KEY="verify-tool-access"
NS="verify-tool-access"
FAILURES=0
PASS_COUNT=0

usage() {
  cat <<'EOF'
Usage: verify-agent-tool-access.sh [options]

Verify Agent Tool Access: Ralph MCP tools, bounded previews, resultId paging,
and optional live plan runs in native and ralph modes.

Options:
  --test, --dry-run       MCP checks only; skip live runtime invocations.
  --live                  Run live plan invocations for installed CLIs.
  --runtime RUNTIME       Limit live runs to RUNTIME (repeatable).
  --workspace PATH        Use PATH instead of a temporary workspace.
  --keep-workspace        Do not remove a temporary workspace on exit.
  -h, --help              Show this help.

When neither --test nor --live is given, this script performs MCP-only verification
and never invokes a runtime CLI. Pass --live deliberately to spend provider usage.
EOF
}

log() {
  printf 'verify-agent-tool-access: %s\n' "$*"
}

log_skip() {
  log "skip: $*"
}

log_ok() {
  log "ok: $*"
}

log_fail() {
  log "FAIL: $*"
  FAILURES=$((FAILURES + 1))
}

check_ok() {
  PASS_COUNT=$((PASS_COUNT + 1))
  log_ok "$1"
}

require_cmd() {
  local cmd="$1"
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "verify-agent-tool-access: error: required command not found: $cmd" >&2
    exit 2
  fi
}

bash_supports_run_plan() {
  [[ "${BASH_VERSINFO[0]:-0}" -ge 4 ]]
}

parse_args() {
  local arg
  while [[ $# -gt 0 ]]; do
    arg="$1"
    case "$arg" in
      --test | --dry-run)
        DRY_RUN=1
        LIVE_RUN=0
        ;;
      --live)
        LIVE_RUN=1
        DRY_RUN=0
        ;;
      --runtime)
        shift
        [[ $# -gt 0 ]] || { echo "verify-agent-tool-access: error: --runtime requires a value" >&2; exit 2; }
        SELECTED_RUNTIMES+=("$1")
        ;;
      --workspace)
        shift
        [[ $# -gt 0 ]] || { echo "verify-agent-tool-access: error: --workspace requires a path" >&2; exit 2; }
        WORKSPACE="$1"
        ;;
      --keep-workspace)
        KEEP_WORKSPACE=1
        ;;
      -h | --help)
        usage
        exit 0
        ;;
      *)
        echo "verify-agent-tool-access: error: unknown argument: $arg" >&2
        usage >&2
        exit 2
        ;;
    esac
    shift
  done

}

runtime_in_selection() {
  local runtime="$1"
  local selected
  if [[ ${#SELECTED_RUNTIMES[@]} -eq 0 ]]; then
    return 0
  fi
  for selected in "${SELECTED_RUNTIMES[@]}"; do
    [[ "$selected" == "$runtime" ]] && return 0
  done
  return 1
}

resolve_runtime_cli() {
  local runtime="$1"
  case "$runtime" in
    cursor)
      # shellcheck source=/dev/null
      source "$CLI_HELPERS"
      ralph_resolve_cursor_cli 2>/dev/null || return 1
      ;;
    claude)
      local cli="${CLAUDE_PLAN_CLI:-claude}"
      command -v "$cli" >/dev/null 2>&1 || return 1
      printf '%s' "$cli"
      ;;
    codex)
      local cli="${CODEX_PLAN_CLI:-codex}"
      command -v "$cli" >/dev/null 2>&1 || return 1
      printf '%s' "$cli"
      ;;
    opencode)
      # shellcheck source=/dev/null
      source "$CLI_HELPERS"
      ralph_resolve_opencode_cli 2>/dev/null || return 1
      ;;
    *)
      return 1
      ;;
  esac
}

setup_workspace() {
  local temp_root=""
  if [[ -z "$WORKSPACE" ]]; then
    temp_root="$(mktemp -d "${TMPDIR:-/tmp}/ralph-verify-tool-access.XXXXXX")"
    WORKSPACE="$temp_root/workspace"
    mkdir -p "$WORKSPACE"
    export VATA_TEMP_ROOT="$temp_root"
  fi
  WORKSPACE="$(cd "$WORKSPACE" && pwd)"

  local fixture_dir="$WORKSPACE/verify-fixtures"
  mkdir -p "$fixture_dir"
  cp "$REPO_ROOT/tests/fixtures/mcp-proxy/grep-many-matches.txt" "$fixture_dir/grep-target.txt"

  local i
  : >"$fixture_dir/large-read.txt"
  for i in $(seq 1 80); do
    printf 'line-%03d content for read verification\n' "$i" >>"$fixture_dir/large-read.txt"
  done

  mkdir -p "$WORKSPACE/.ralph-workspace/logs/$NS"
}

create_plan() {
  local plan_path="$WORKSPACE/verify-agent-tool-access.plan.md"
  cat >"$plan_path" <<'EOF'
# Agent Tool Access verification

Temporary read/search-heavy plan for scripts/verify-agent-tool-access.sh.

- [ ] Search verify-fixtures/grep-target.txt for lines containing VERIFY_MATCH and report the match count.
- [ ] Read the first 10 lines of verify-fixtures/large-read.txt and state how many lines begin with "line-".
EOF
  printf '%s' "$plan_path"
}

mcp_server_call() {
  local payload="$1"
  shift
  local -a env_args=(env "RALPH_MCP_WORKSPACE=$WORKSPACE" "RALPH_PLAN_KEY=$PLAN_KEY")
  local item
  for item in "$@"; do
    env_args+=("$item")
  done
  env_args+=("bash" "$MCP_SERVER")
  local stderr_log
  stderr_log="$(mktemp)"
  local response status
  set +e
  response="$("${env_args[@]}" 2>"$stderr_log" <<< "$payload")"
  status=$?
  set -e
  if [[ "$status" -ne 0 ]]; then
    log_fail "mcp-server exited $status ($(tr -d '\n' <"$stderr_log" | head -c 200))"
    rm -f "$stderr_log"
    return 1
  fi
  rm -f "$stderr_log"
  printf '%s' "$response"
}

verify_tools_list() {
  log "checking tools/list for Ralph proxy and result tools"
  local payload=$'{"jsonrpc":"2.0","id":1,"method":"tools/list"}\n{"jsonrpc":"2.0","id":2,"method":"exit"}\n'
  local response first_line
  response="$(mcp_server_call "$payload")" || return 1
  first_line="$(printf '%s\n' "$response" | jq -s '.[0]')"
  local -a required_tools=(
    ralph_proxy_read
    ralph_proxy_grep
    ralph_proxy_glob
    ralph_proxy_shell
    ralph_proxy_result_read
    ralph_proxy_result_search
    ralph_proxy_result_summary
    ralph_plan_status
  )
  local tool
  for tool in "${required_tools[@]}"; do
    if ! printf '%s\n' "$first_line" | jq -e --arg t "$tool" '[.result.tools[]?.name] | index($t) != null' >/dev/null; then
      log_fail "tools/list missing tool: $tool"
      return 1
    fi
  done
  check_ok "tools/list exposes Ralph MCP proxy and result tools"
}

verify_knowledge_tools_list() {
  log "checking tools/list for Ralph knowledge tools when RALPH_KNOWLEDGE_TOOLS=on"
  local payload=$'{"jsonrpc":"2.0","id":1,"method":"tools/list"}\n{"jsonrpc":"2.0","id":2,"method":"exit"}\n'
  local response first_line
  response="$(mcp_server_call "$payload" \
    "RALPH_KNOWLEDGE_FEATURE=on" \
    "RALPH_KNOWLEDGE_TOOLS=on" \
    "RALPH_KNOWLEDGE_ENABLED=1" \
    "RALPH_KNOWLEDGE_RECORD_ENABLED=1" \
    "RALPH_KNOWLEDGE_QUERY_ENABLED=1")" || return 1
  first_line="$(printf '%s\n' "$response" | jq -s '.[0]')"
  local -a required_tools=(
    ralph_knowledge_record
    ralph_knowledge_query
    ralph_knowledge_status
  )
  local tool
  for tool in "${required_tools[@]}"; do
    if ! printf '%s\n' "$first_line" | jq -e --arg t "$tool" '[.result.tools[]?.name] | index($t) != null' >/dev/null; then
      log_fail "tools/list missing knowledge tool: $tool"
      return 1
    fi
  done
  check_ok "tools/list exposes Ralph knowledge tools when enabled"
}

verify_tools_callable() {
  log "checking ralph_proxy_grep is callable"
  local payload
  payload="$(jq -nc \
    '{jsonrpc:"2.0",id:1,method:"tools/call",params:{name:"ralph_proxy_grep",arguments:{pattern:"MATCHME",path:"verify-fixtures/grep-target.txt",head_limit:3}}}')"
  payload+=$'\n{"jsonrpc":"2.0","id":2,"method":"exit"}\n'
  local response first_line
  response="$(mcp_server_call "$payload")" || return 1
  first_line="$(printf '%s\n' "$response" | jq -s '.[0]')"
  if ! printf '%s\n' "$first_line" | jq -e '.result.isError == false and (.result.content[0].text | test("MATCHME"))' >/dev/null; then
    log_fail "ralph_proxy_grep call did not return expected matches"
    return 1
  fi
  check_ok "ralph_proxy_grep is callable via MCP server"
}

verify_preview_caps() {
  log "checking truncated previews stay under policy caps"
  local response cap preview_bytes returned_bytes
  cap=4096
  response="$(env \
    RALPH_MCP_WORKSPACE="$WORKSPACE" \
    RALPH_PLAN_KEY="$PLAN_KEY" \
    RALPH_MCP_PROXY_POLICY_INLINE='{"name":"verify-cap","proxyOwnedTools":{"enabled":true,"maxGrepMatches":5},"resultByteCap":4096,"toolResultByteCaps":{"ralph_proxy_grep":4096}}' \
    bash -c '
      source "$1"
      source "$2"
      source "$3"
      ralph_mcp_proxy_load_policy "$4" "$5" >/dev/null || exit 1
      ralph_mcp_proxy_call_owned_tool "$6" "ralph_proxy_grep" "{\"pattern\":\"MATCHME\",\"path\":\"verify-fixtures/grep-target.txt\"}"
    ' _ "$POLICY_LIB" "$RESULT_LIB" "$TOOLS_LIB" "$REPO_ROOT" "$MCP_SERVER" "$WORKSPACE" 2>/dev/null)"
  if ! printf '%s\n' "$response" | jq -e '.isError == false and (.content[0].text | fromjson | .truncated) == true' >/dev/null; then
    log_fail "ralph_proxy_grep did not return a truncated envelope"
    return 1
  fi
  preview_bytes="$(printf '%s\n' "$response" | jq -r '.content[0].text | fromjson | .returnedBytes')"
  returned_bytes="$(printf '%s\n' "$response" | jq -r '.content[0].text | fromjson | .preview | length')"
  if [[ "$preview_bytes" -gt "$cap" || "$returned_bytes" -gt "$cap" ]]; then
    log_fail "preview exceeded cap ($preview_bytes / $returned_bytes > $cap)"
    return 1
  fi
  if ! printf '%s\n' "$response" | jq -e '.content[0].text | fromjson | .resultId | test("^[a-f0-9]{16}$")' >/dev/null; then
    log_fail "truncated envelope missing valid resultId"
    return 1
  fi
  check_ok "result previews stay under configured caps (cap=$cap, returnedBytes=$preview_bytes)"
}

verify_result_paging() {
  log "checking resultId paging via ralph_proxy_result_read"
  local grep_response result_id page_response
  grep_response="$(env \
    RALPH_MCP_WORKSPACE="$WORKSPACE" \
    RALPH_PLAN_KEY="$PLAN_KEY" \
    RALPH_MCP_PROXY_POLICY_INLINE='{"name":"verify-paging","proxyOwnedTools":{"enabled":true,"maxGrepMatches":5},"resultByteCap":4096,"toolResultByteCaps":{"ralph_proxy_grep":4096}}' \
    bash -c '
      source "$1"
      source "$2"
      source "$3"
      ralph_mcp_proxy_load_policy "$4" "$5" >/dev/null || exit 1
      ralph_mcp_proxy_call_owned_tool "$6" "ralph_proxy_grep" "{\"pattern\":\"MATCHME\",\"path\":\"verify-fixtures/grep-target.txt\"}"
    ' _ "$POLICY_LIB" "$RESULT_LIB" "$TOOLS_LIB" "$REPO_ROOT" "$MCP_SERVER" "$WORKSPACE" 2>/dev/null)"
  result_id="$(printf '%s\n' "$grep_response" | jq -r '.content[0].text | fromjson | .resultId')"
  if [[ ! "$result_id" =~ ^[a-f0-9]{16}$ ]]; then
    log_fail "could not obtain resultId from truncated grep response"
    return 1
  fi

  page_response="$(env \
    RALPH_MCP_WORKSPACE="$WORKSPACE" \
    RALPH_PLAN_KEY="$PLAN_KEY" \
    bash -c '
      source "$1"
      source "$2"
      source "$3"
      ralph_mcp_proxy_load_policy "$4" "$5" >/dev/null || exit 1
      ralph_mcp_proxy_call_owned_tool "$6" "ralph_proxy_result_read" "$7"
    ' _ "$POLICY_LIB" "$RESULT_LIB" "$TOOLS_LIB" "$REPO_ROOT" "$MCP_SERVER" "$WORKSPACE" \
    "$(jq -nc --arg id "$result_id" '{resultId:$id,byteStart:0,byteEnd:80}')" 2>/dev/null)"
  if ! printf '%s\n' "$page_response" | jq -e '.isError == false and (.content[0].text | length) > 0' >/dev/null; then
    log_fail "ralph_proxy_result_read did not return paged content for resultId=$result_id"
    return 1
  fi

  page_response="$(env \
    RALPH_MCP_WORKSPACE="$WORKSPACE" \
    RALPH_PLAN_KEY="$PLAN_KEY" \
    bash -c '
      source "$1"
      source "$2"
      source "$3"
      ralph_mcp_proxy_load_policy "$4" "$5" >/dev/null || exit 1
      ralph_mcp_proxy_call_owned_tool "$6" "ralph_proxy_result_search" "$7"
    ' _ "$POLICY_LIB" "$RESULT_LIB" "$TOOLS_LIB" "$REPO_ROOT" "$MCP_SERVER" "$WORKSPACE" \
    "$(jq -nc --arg id "$result_id" '{resultId:$id,pattern:"grep-fixture-line-010"}')" 2>/dev/null)"
  if ! printf '%s\n' "$page_response" | jq -e '.isError == false and (.content[0].text | test("grep-fixture-line-010"))' >/dev/null; then
    log_fail "ralph_proxy_result_search did not find expected match in stored result"
    return 1
  fi

  check_ok "resultId paging and search work (resultId=$result_id)"
}

print_plan_metrics() {
  local runtime="$1"
  local mode="$2"
  local log_dir="$WORKSPACE/.ralph-workspace/logs/$NS"
  local summary="$log_dir/plan-usage-summary.json"
  local invocations="$log_dir/invocation-usage.json"

  if [[ -f "$summary" ]]; then
    log "metrics ($runtime/$mode): $(jq -c \
      '{input_tokens,output_tokens,cache_read_input_tokens,cache_creation_input_tokens,cache_hit_ratio,invocations}' \
      "$summary" 2>/dev/null || echo '{}')"
    return 0
  fi
  if [[ -f "$invocations" ]] && command -v python3 >/dev/null 2>&1; then
    python3 - "$invocations" "$runtime" "$mode" <<'PY'
import json, sys
path, runtime, mode = sys.argv[1:4]
with open(path, encoding="utf-8") as fh:
    doc = json.load(fh)
rows = doc.get("invocations") or []
if not rows:
    print(f"metrics ({runtime}/{mode}): no invocation rows in {path}")
    raise SystemExit(0)
last = rows[-1]
print(
    "metrics ({}/{}): input={} output={} cache_read={} cache_create={} cache_hit_ratio={}".format(
        runtime,
        mode,
        last.get("input_tokens", 0),
        last.get("output_tokens", 0),
        last.get("cache_read_input_tokens", 0),
        last.get("cache_creation_input_tokens", 0),
        last.get("cache_hit_ratio", 0),
    )
)
PY
    return 0
  fi
  log "metrics ($runtime/$mode): not available (no usage files under $log_dir)"
}

run_live_plan() {
  local runtime="$1"
  local mode="$2"
  local plan_path="$3"
  local cli

  if ! cli="$(resolve_runtime_cli "$runtime")"; then
    log_skip "$runtime CLI not installed (would run --tool-access $mode)"
    return 0
  fi

  if [[ "$DRY_RUN" -eq 1 ]]; then
    log "dry-run: would run $runtime ($cli) with --tool-access $mode on $plan_path"
    return 0
  fi

  log "running $runtime ($cli) with Agent Tool Access: $mode"
  local -a run_env=(
    "RALPH_USAGE_RISKS_ACKNOWLEDGED=1"
    "RALPH_AGENT_TOOL_ACCESS=$mode"
    "RALPH_ARTIFACT_NS=$NS"
    "RALPH_PLAN_KEY=$NS"
    "RALPH_PLAN_WORKSPACE_ROOT=$WORKSPACE/.ralph-workspace"
    "CURSOR_PLAN_MAX_ITER=1"
    "CLAUDE_PLAN_MAX_ITER=1"
    "CODEX_PLAN_MAX_ITER=1"
    "OPENCODE_PLAN_MAX_ITER=1"
  )

  local status=0
  set +e
  env "${run_env[@]}" bash "$RUN_PLAN" \
    --runtime "$runtime" \
    --plan "$plan_path" \
    --workspace "$WORKSPACE" \
    --tool-access "$mode" \
    --non-interactive \
    --max-iterations 1
  status=$?
  set -e

  if [[ "$status" -ne 0 ]]; then
    log_fail "$runtime plan run failed with exit $status (mode=$mode)"
    return 1
  fi

  check_ok "$runtime plan run completed (mode=$mode)"
  print_plan_metrics "$runtime" "$mode"
}

verify_runtime_modes() {
  local plan_path="$1"
  local runtime cli

  if [[ "$DRY_RUN" -eq 0 ]] && ! bash_supports_run_plan; then
    log_skip "live plan runs require bash 4+ (current: ${BASH_VERSION}); use --test for MCP-only verification"
    return 0
  fi

  for runtime in "${ALL_RUNTIMES[@]}"; do
    if ! runtime_in_selection "$runtime"; then
      continue
    fi
    if ! cli="$(resolve_runtime_cli "$runtime" 2>/dev/null)"; then
      log_skip "$runtime CLI not installed"
      continue
    fi
    log "runtime $runtime available ($cli)"
    run_live_plan "$runtime" "native" "$plan_path" || true
    run_live_plan "$runtime" "ralph" "$plan_path" || true
  done
}

cleanup_workspace() {
  if [[ -n "${VATA_TEMP_ROOT:-}" && "$KEEP_WORKSPACE" -eq 0 ]]; then
    rm -rf "$VATA_TEMP_ROOT"
  elif [[ -n "${VATA_TEMP_ROOT:-}" && "$KEEP_WORKSPACE" -eq 1 ]]; then
    log "kept temporary workspace at $WORKSPACE"
  fi
}

main() {
  parse_args "$@"

  require_cmd jq
  require_cmd bash
  [[ -x "$RUN_PLAN" ]] || { echo "verify-agent-tool-access: error: run-plan not found: $RUN_PLAN" >&2; exit 2; }
  [[ -x "$MCP_SERVER" ]] || { echo "verify-agent-tool-access: error: mcp-server not found: $MCP_SERVER" >&2; exit 2; }

  if [[ "$DRY_RUN" -eq 1 ]]; then
    log "mode: test/dry-run (MCP checks only; no live runtime invocations)"
  else
    log "mode: live (MCP checks plus runtime plan runs for installed CLIs)"
  fi

  setup_workspace
  trap cleanup_workspace EXIT

  local plan_path
  plan_path="$(create_plan)"
  log "temporary plan: $plan_path"
  log "workspace: $WORKSPACE"

  verify_tools_list || true
  verify_knowledge_tools_list || true
  verify_tools_callable || true
  verify_preview_caps || true
  verify_result_paging || true

  if [[ "$LIVE_RUN" -eq 1 || "$DRY_RUN" -eq 1 ]]; then
    verify_runtime_modes "$plan_path"
  fi

  log "checks passed: $PASS_COUNT (failures=$FAILURES)"
  if [[ "$FAILURES" -gt 0 ]]; then
    exit 1
  fi
}

main "$@"
