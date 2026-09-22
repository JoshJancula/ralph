#!/usr/bin/env bats

source "$BATS_TEST_DIRNAME/../helper/load-lib.bash"

RESULT_STORE="$REPO_ROOT/bundle/.ralph/bash-lib/mcp-proxy/mcp-proxy-result-store.sh"
STATE_PATHS="$REPO_ROOT/bundle/.ralph/bash-lib/state-paths.sh"

setup() {
  command -v jq >/dev/null 2>&1 || skip "jq required"
  TEST_TMPDIR="$(mktemp -d)"
  WS="$TEST_TMPDIR/workspace"
  mkdir -p "$WS"
  export RALPH_MCP_WORKSPACE="$WS"
  unset RALPH_PLAN_WORKSPACE_ROOT
  # shellcheck source=/dev/null
  source "$STATE_PATHS"
  # shellcheck source=/dev/null
  source "$RESULT_STORE"
}

teardown() {
  [[ -n "${TEST_TMPDIR:-}" ]] && rm -rf "$TEST_TMPDIR"
}

@test "layout 2 stores MCP tool results under cache/tool-results" {
  export RALPH_STATE_LAYOUT=2
  export RALPH_PLAN_KEY="org-store-v2"
  local content result_id store_root result_path
  content="layout-2 tool result payload"
  result_id="$(ralph_mcp_proxy_result_store_write "$WS" "$RALPH_PLAN_KEY" "$content" "ralph_proxy_shell")"
  [ -n "$result_id" ]
  store_root="$(ralph_mcp_proxy_result_store_root "$WS")"
  [[ "$store_root" == *"/cache/tool-results" ]]
  # Same directory; the store root canonicalizes its workspace while the
  # resolver returns the caller's spelling, so compare physical paths.
  [[ "$(cd "$(ralph_state_shared_dir "$WS/.ralph-workspace" tool-results)" && pwd -P)" == "$(cd "$store_root" && pwd -P)" ]]
  result_path="$(ralph_mcp_proxy_result_store_resolve_result_path "$WS" "$RALPH_PLAN_KEY" "$result_id")"
  [[ "$result_path" == "$store_root/$RALPH_PLAN_KEY/results/${result_id}.txt" ]]
  [ -f "$result_path" ]
  [[ "$(ralph_mcp_proxy_result_store_read_bytes "$WS" "$RALPH_PLAN_KEY" "$result_id" 0 0 raw)" == "$content" ]]
  [ ! -e "$WS/.ralph-workspace/tool-results/$RALPH_PLAN_KEY/results/${result_id}.txt" ]
}

@test "layout 2 retrieves a tool result written under the legacy tool-results path" {
  export RALPH_STATE_LAYOUT=2
  export RALPH_PLAN_KEY="org-legacy-read"
  local result_id="0123456789abcdef" legacy_dir legacy_path resolved
  legacy_dir="$WS/.ralph-workspace/tool-results/$RALPH_PLAN_KEY/results"
  mkdir -p "$legacy_dir"
  legacy_path="$legacy_dir/${result_id}.txt"
  printf 'legacy stored result' >"$legacy_path"
  [[ "$(ralph_mcp_proxy_result_store_root "$WS")" == *"/cache/tool-results" ]]
  resolved="$(ralph_mcp_proxy_result_store_resolve_result_path "$WS" "$RALPH_PLAN_KEY" "$result_id")"
  [[ "$resolved" == *"/tool-results/$RALPH_PLAN_KEY/results/${result_id}.txt" ]]
  [[ "$resolved" != *"/cache/tool-results/"* ]]
  [ -f "$resolved" ]
  [[ "$(ralph_mcp_proxy_result_store_read_bytes "$WS" "$RALPH_PLAN_KEY" "$result_id" 0 0 raw)" == "legacy stored result" ]]
}

@test "layout 1 keeps MCP tool results at the historical tool-results path" {
  export RALPH_STATE_LAYOUT=1
  export RALPH_PLAN_KEY="org-store-v1"
  local content result_id store_root
  content="layout-1 tool result payload"
  result_id="$(ralph_mcp_proxy_result_store_write "$WS" "$RALPH_PLAN_KEY" "$content" "ralph_proxy_shell")"
  [ -n "$result_id" ]
  store_root="$(ralph_mcp_proxy_result_store_root "$WS")"
  [[ "$store_root" == "$WS/.ralph-workspace/tool-results" ]] || [[ "$store_root" == "$(cd "$WS/.ralph-workspace" && pwd -P)/tool-results" ]]
  [ -f "$store_root/$RALPH_PLAN_KEY/results/${result_id}.txt" ]
  [ ! -e "$WS/.ralph-workspace/cache/tool-results/$RALPH_PLAN_KEY/results/${result_id}.txt" ]
  [[ "$(ralph_mcp_proxy_result_store_read_bytes "$WS" "$RALPH_PLAN_KEY" "$result_id" 0 0 raw)" == "$content" ]]
}

@test "layout 2 stores repo-map cache under cache/repo-map" {
  export RALPH_STATE_LAYOUT=2
  local cache_root
  cache_root="$(ralph_state_shared_dir "$WS/.ralph-workspace" repo-map)"
  [[ "$cache_root" == *"/cache/repo-map" ]]
  [ ! -e "$WS/.ralph-workspace/repo-map" ]
  mkdir -p "$cache_root"
  [ -d "$cache_root" ]
}

@test "layout 2 stores search-context under cache/search-context" {
  export RALPH_STATE_LAYOUT=2
  command -v python3 >/dev/null 2>&1 || skip "python3 required"
  mkdir -p "$WS/src"
  printf 'def hello():\n    pass\n' >"$WS/src/hello.py"
  local state_root="$WS/.ralph-workspace" shared
  mkdir -p "$state_root"
  PYTHONPATH="$REPO_ROOT/bundle/.ralph/python${PYTHONPATH:+:$PYTHONPATH}" \
    python3 - "$WS" "$state_root" <<'PY'
import json
import os
import shutil
import sys
from pathlib import Path

from search_context import (
    _cache_path,
    _read_file_entry,
    _resolve_cache_path,
    load_file_index,
    search_context_legacy_root,
    search_context_root,
)

project = Path(sys.argv[1])
state = Path(sys.argv[2])

payload = load_file_index(project, state, "src/hello.py")
assert payload["relpath"] == "src/hello.py"
root = search_context_root(state)
assert root == state / "cache" / "search-context", root
assert any(root.rglob("*.json")), list(root.rglob("*"))
assert not (state / "search-context").exists()

mtime, _content, backend = _read_file_entry(project, "src/hello.py")
shutil.rmtree(root)
os.environ["RALPH_STATE_LAYOUT"] = "1"
legacy = _cache_path(state, project, "src/hello.py", mtime, backend)
legacy.parent.mkdir(parents=True, exist_ok=True)
legacy.write_text(json.dumps(payload, sort_keys=True), encoding="utf-8")
os.environ["RALPH_STATE_LAYOUT"] = "2"
resolved = _resolve_cache_path(state, project, "src/hello.py", mtime, backend)
assert resolved == legacy, (resolved, legacy)
assert search_context_legacy_root(state) == state / "search-context"
print(root)
PY
  shared="$(ralph_state_shared_dir "$state_root" search-context)"
  [[ "$shared" == *"/cache/search-context" ]]
  [ -d "$state_root/search-context" ]
}

@test "layout 2 stores metrics under cache/metrics" {
  export RALPH_STATE_LAYOUT=2
  local state_root="$WS/.ralph-workspace" metrics_root legacy_path resolved
  mkdir -p "$state_root"
  metrics_root="$(ralph_state_shared_dir "$state_root" metrics)"
  [[ "$metrics_root" == *"/cache/metrics" ]]
  mkdir -p "$metrics_root"
  printf '{"ok":true}\n' >"$metrics_root/sample.json"
  [ -f "$metrics_root/sample.json" ]
  [ ! -e "$state_root/metrics/sample.json" ]
  # Legacy-location read: prefer layout-aware when both could exist; fall back when only legacy is present.
  legacy_path="$state_root/metrics/legacy-only.json"
  mkdir -p "$(dirname "$legacy_path")"
  printf '{"legacy":true}\n' >"$legacy_path"
  if [[ -f "$metrics_root/legacy-only.json" ]]; then
    resolved="$metrics_root/legacy-only.json"
  elif [[ -f "$legacy_path" ]]; then
    resolved="$legacy_path"
  else
    resolved=""
  fi
  [[ "$resolved" == "$legacy_path" ]]
  [[ "$(ralph_state_shared_dir "$state_root" metrics)" == *"/cache/metrics" ]]
  export RALPH_STATE_LAYOUT=1
  [[ "$(ralph_state_shared_dir "$state_root" metrics)" == *"/metrics" ]]
  [[ "$(ralph_state_shared_dir "$state_root" metrics)" != *"/cache/metrics" ]]
}

@test "layout 2 stores plan-level sessions under internal/sessions" {
  export RALPH_STATE_LAYOUT=2
  export RALPH_PLAN_KEY="org-session-v2"
  unset RALPH_PLAN_SESSION_HOME RALPH_HOME
  # shellcheck source=/dev/null
  source "$REPO_ROOT/bundle/.ralph/bash-lib/run-plan/run-plan-session.sh"
  ralph_run_plan_log() { :; }
  ralph_session_init "$WS" "plan.log"
  [[ "$RALPH_PLAN_SESSION_HOME" == *"/internal/sessions" ]]
  [[ "$(ralph_state_shared_dir "$WS/.ralph-workspace" sessions)" == "$RALPH_PLAN_SESSION_HOME" ]]
  [[ "$RALPH_SESSION_DIR" == "$RALPH_PLAN_SESSION_HOME/$RALPH_PLAN_KEY" ]]
  [ -d "$RALPH_SESSION_DIR" ]
  [ ! -e "$WS/.ralph-workspace/sessions/$RALPH_PLAN_KEY" ]
  printf 'sess-plan-level\n' >"$SESSION_ID_FILE"
  [ -f "$SESSION_ID_FILE" ]
  # Fresh init again must reopen the same layout-2 session dir (plan-level continuation).
  local prior="$RALPH_SESSION_DIR"
  ralph_session_init "$WS" "plan.log"
  [[ "$RALPH_SESSION_DIR" == "$prior" ]]
  [[ "$(cat "$SESSION_ID_FILE")" == "sess-plan-level" ]]
}

@test "layout 2 stores per-TODO session manifests under internal/sessions" {
  export RALPH_STATE_LAYOUT=2
  export RALPH_PLAN_KEY="org-todo-session-v2"
  export RUNTIME="cursor"
  export RALPH_PROCESS_RUN_ID="run-org-todo"
  export RALPH_CURRENT_TODO_LINE="10"
  export RALPH_CURRENT_TODO_ORDINAL="1"
  export RALPH_CURRENT_TODO_ID="org-todo-session"
  export RALPH_CURRENT_TODO_HASH="hash-org-todo"
  unset RALPH_PLAN_SESSION_HOME RALPH_HOME
  # shellcheck source=/dev/null
  source "$REPO_ROOT/bundle/.ralph/bash-lib/run-plan/run-plan-session.sh"
  ralph_run_plan_log() { :; }
  ralph_session_init "$WS" "plan.log"
  [[ "$RALPH_SESSION_DIR" == *"/internal/sessions/$RALPH_PLAN_KEY" ]]
  local record manifest_key manifest_dir manifest_path
  record="$(ralph_session_todo_create "sess-todo-1" "exact")"
  [ -n "$record" ]
  manifest_key="$(jq -r '.manifest_key' <<<"$record")"
  manifest_dir="$(ralph_session_todo_manifest_dir)"
  [[ "$manifest_dir" == "$RALPH_SESSION_DIR/todo-sessions" ]]
  [[ "$manifest_dir" == *"/internal/sessions/"*"/todo-sessions" ]]
  manifest_path="$(ralph_session_todo_manifest_path "$manifest_key")"
  [ -f "$manifest_path" ]
  [[ "$(jq -r '.session_id' "$manifest_path")" == "sess-todo-1" ]]
  [ ! -e "$WS/.ralph-workspace/sessions/$RALPH_PLAN_KEY/todo-sessions" ]
}

@test "layout 2 resume keeps layout-1 sessions at the historical sessions path" {
  export RALPH_STATE_LAYOUT=2
  export RALPH_PLAN_KEY="org-session-resume-v1"
  unset RALPH_PLAN_SESSION_HOME RALPH_HOME
  local legacy_dir="$WS/.ralph-workspace/sessions/$RALPH_PLAN_KEY"
  mkdir -p "$legacy_dir/todo-sessions"
  printf 'legacy-session-id\n' >"$legacy_dir/session-id.cursor.txt"
  printf '%s\n' '{"schema_version":1,"manifest_key":"keep","state":"active","runtime":"cursor","session_id":"legacy-todo","capture":"exact","identity":{"runId":"run-legacy","todoId":"keep","todoHash":"h1"},"created_at":"t","updated_at":"t"}' \
    >"$legacy_dir/todo-sessions/keep.json"
  # shellcheck source=/dev/null
  source "$REPO_ROOT/bundle/.ralph/bash-lib/run-plan/run-plan-session.sh"
  ralph_run_plan_log() { :; }
  RUNTIME="cursor"
  ralph_session_init "$WS" "plan.log"
  [[ "$RALPH_PLAN_SESSION_HOME" == "$WS/.ralph-workspace/sessions" ]] || [[ "$RALPH_PLAN_SESSION_HOME" == "$(cd "$WS/.ralph-workspace" && pwd -P)/sessions" ]]
  [[ "$RALPH_SESSION_DIR" == *"/sessions/$RALPH_PLAN_KEY" ]]
  [[ "$RALPH_SESSION_DIR" != *"/internal/sessions/"* ]]
  [[ "$(cat "$SESSION_ID_FILE")" == "legacy-session-id" ]]
  [ -f "$RALPH_SESSION_DIR/todo-sessions/keep.json" ]
  [ ! -e "$WS/.ralph-workspace/internal/sessions/$RALPH_PLAN_KEY" ]
  [[ "$(ralph_state_sessions_dir "$WS/.ralph-workspace" "$RALPH_PLAN_KEY")" == "$RALPH_SESSION_DIR" ]] || \
    [[ "$(ralph_state_sessions_dir "$WS/.ralph-workspace" "$RALPH_PLAN_KEY")" == "$(cd "$RALPH_SESSION_DIR" && pwd -P)" ]]
}

@test "layout 2 restores overlay from a layout-2 journal" {
  export RALPH_STATE_LAYOUT=2
  export WORKSPACE="$WS"
  export RALPH_PROJECT_ROOT="$WS"
  export RALPH_PLAN_KEY="org-overlay-v2"
  unset RALPH_PLAN_WORKSPACE_ROOT
  # shellcheck source=/dev/null
  source "$REPO_ROOT/bundle/.ralph/bash-lib/runtime-overlay/runtime-overlay.sh"
  local plan_key="$RALPH_PLAN_KEY"
  local plan_dir="$WS/.ralph-workspace/internal/runtime-config/$plan_key"
  local journal_dir="$plan_dir/journals"
  local originals_dir="$plan_dir/originals"
  mkdir -p "$journal_dir" "$originals_dir/.cursor" "$WS/.cursor"
  local target="$WS/.cursor/mcp.json"
  local backup="$originals_dir/.cursor/mcp.json"
  printf '%s' '{"original":true}' >"$backup"
  printf '%s' '{"mutated":true}' >"$target"
  local journal_path="$journal_dir/journal-${plan_key}-1.json"
  python3 - <<'PY' "$journal_path" "$plan_key" "$WS" "$target" "$backup"
import json, sys
path, plan_key, workspace, target, backup = sys.argv[1:]
json.dump({
    "pid": 999999,
    "start_time": 1,
    "runtime": "cursor",
    "plan_key": plan_key,
    "workspace_root": workspace,
    "cleanup_status": "pending",
    "cleanup_time": None,
    "generated_files": [],
    "mutated_files": [{"path": target, "backup": backup}],
}, open(path, "w"), indent=2)
PY
  [[ "$(ralph_state_runtime_config_dir "$WS/.ralph-workspace" "$plan_key")" == *"/internal/runtime-config/$plan_key" ]]
  run runtime_overlay_restore_stale_runs "$WS" "$plan_key" 0
  [ "$status" -eq 0 ]
  [ "$(cat "$target")" = '{"original":true}' ]
  python3 - <<'PY' "$journal_path"
import json, sys
data = json.load(open(sys.argv[1]))
assert data["cleanup_status"] == "cleaned"
assert data["mutated_files"][0]["restored"] is True
PY
}

@test "layout 2 restores overlay from a layout-1 journal" {
  export RALPH_STATE_LAYOUT=2
  export WORKSPACE="$WS"
  export RALPH_PROJECT_ROOT="$WS"
  export RALPH_PLAN_KEY="org-overlay-legacy"
  unset RALPH_PLAN_WORKSPACE_ROOT
  # shellcheck source=/dev/null
  source "$REPO_ROOT/bundle/.ralph/bash-lib/runtime-overlay/runtime-overlay.sh"
  local plan_key="$RALPH_PLAN_KEY"
  local plan_dir="$WS/.ralph-workspace/runtime-config/$plan_key"
  local journal_dir="$plan_dir/journals"
  local originals_dir="$plan_dir/originals"
  mkdir -p "$journal_dir" "$originals_dir/.cursor" "$WS/.cursor"
  local target="$WS/.cursor/mcp.json"
  local backup="$originals_dir/.cursor/mcp.json"
  printf '%s' '{"original":true}' >"$backup"
  printf '%s' '{"mutated":true}' >"$target"
  local journal_path="$journal_dir/journal-${plan_key}-1.json"
  python3 - <<'PY' "$journal_path" "$plan_key" "$WS" "$target" "$backup"
import json, sys
path, plan_key, workspace, target, backup = sys.argv[1:]
json.dump({
    "pid": 999998,
    "start_time": 1,
    "runtime": "cursor",
    "plan_key": plan_key,
    "workspace_root": workspace,
    "cleanup_status": "pending",
    "cleanup_time": None,
    "generated_files": [],
    "mutated_files": [{"path": target, "backup": backup}],
}, open(path, "w"), indent=2)
PY
  # Sticky write home while only the layout-1 plan dir exists.
  [[ "$(ralph_state_runtime_config_dir "$WS/.ralph-workspace" "$plan_key")" == *"/runtime-config/$plan_key" ]]
  [[ "$(ralph_state_runtime_config_dir "$WS/.ralph-workspace" "$plan_key")" != *"/internal/runtime-config/"* ]]
  run runtime_overlay_restore_stale_runs "$WS" "$plan_key" 0
  [ "$status" -eq 0 ]
  [ "$(cat "$target")" = '{"original":true}' ]
  python3 - <<'PY' "$journal_path"
import json, sys
data = json.load(open(sys.argv[1]))
assert data["cleanup_status"] == "cleaned"
assert data["mutated_files"][0]["restored"] is True
PY
}

@test "layout 2 process teardown releases a layout-2 lease" {
  export RALPH_STATE_LAYOUT=2
  command -v python3 >/dev/null 2>&1 || skip "python3 required"
  local state_root="$WS/.ralph-workspace"
  local plan_path="$WS/org-process.plan.md"
  mkdir -p "$state_root" "$WS"
  printf '# plan\n- [ ] task\n' >"$plan_path"
  # shellcheck source=/dev/null
  source "$REPO_ROOT/bundle/.ralph/bash-lib/ralph-process-supervisor.sh"
  ralph_process_run_init "$state_root" "$WS" "$plan_path" plan
  [[ "$RALPH_PROCESS_RUN_DIR" == *"/internal/processes/active/"* ]]
  local leases_dir="$state_root/internal/processes/leases"
  [ -d "$leases_dir" ]
  local lease_count
  lease_count="$(find "$leases_dir" -maxdepth 1 -type f -name '*.json' | wc -l | tr -d ' ')"
  [[ "$lease_count" -ge 1 ]]
  [ ! -e "$state_root/processes/leases" ]
  ralph_process_run_close "org-layout2-teardown"
  lease_count="$(find "$leases_dir" -maxdepth 1 -type f -name '*.json' 2>/dev/null | wc -l | tr -d ' ')"
  [[ "$lease_count" -eq 0 ]]
  [[ "$(jq -r '.status' "$RALPH_PROCESS_RUN_DIR/run.json")" == "stopped" ]]
}
