#!/usr/bin/env bats

source "$BATS_TEST_DIRNAME/../helper/load-lib.bash"

RUN_PLAN_SH="$REPO_ROOT/bundle/.ralph/run-plan.sh"

run_overlay_cleanup_case() {
  local behavior="$1"
  local expect_status="$2"
  local workspace state_root plan_file stub_dir marker registry_file

  workspace="$(mktemp -d)"
  state_root="$workspace/.ralph-workspace"
  mkdir -p "$state_root"
  plan_file="$workspace/PLAN.md"
  printf '%s\n' "- [ ] overlay cleanup test" >"$plan_file"

  stub_dir="$workspace/stubs"
  mkdir -p "$stub_dir"
  cat <<'EOF' > "$stub_dir/cursor-agent"
#!/usr/bin/env bash
set -euo pipefail
case "${RUN_PLAN_CURSOR_BEHAVIOR:-success}" in
  success)
    python3 - <<'PY' || true
import os
import pathlib
path = pathlib.Path(os.environ.get("RALPH_CURRENT_PLAN_PATH", "PLAN.md"))
text = path.read_text()
path.write_text(text.replace("- [ ]", "- [x]", 1))
PY
    printf 'AGENT_INVOCATION_COMPLETE\n'
    exit 0
    ;;
  failure)
    exit 5
    ;;
  signal)
    kill -TERM $$
    ;;
  *)
    exit 2
    ;;
esac
EOF
  chmod +x "$stub_dir/cursor-agent"

  marker="$workspace/overlay-cleanup.marker"
  registry_file="$workspace/workspaces.json"
  rm -f "$marker"

  run env -u RALPH_AGENT_TOOL_ACCESS -u RALPH_LAUNCHER_PID \
    PATH="$stub_dir:$PATH" \
    RALPH_HOME="$REPO_ROOT" \
    RALPH_GLOBAL_RUNTIME_HOME="$REPO_ROOT" \
    RUN_PLAN_CURSOR_BEHAVIOR="$behavior" \
	    RALPH_PLAN_CAPTURE_USAGE=0 \
	    RALPH_PLAN_SESSION_HOME="$state_root/sessions" \
	    RALPH_PLAN_WORKSPACE_ROOT="$state_root" \
	    CURSOR_PLAN_NO_COLOR=1 \
    CLAUDE_PLAN_NO_COLOR=1 \
    CODEX_PLAN_NO_COLOR=1 \
	    RALPH_WORKSPACES_FILE="$registry_file" \
	    RALPH_RUNTIME_OVERLAY_TEST_CLEANUP_MARKER="$marker" \
	    bash "$RUN_PLAN_SH" --runtime cursor --plan "$plan_file" --workspace "$workspace" --workspace-root "$state_root" --model stub-model --non-interactive

  if [[ "$expect_status" == "zero" ]]; then
    if [[ "$status" -ne 0 ]]; then
      printf 'expected status 0, got %s\n%s\n' "$status" "$output" >&3
      [[ -f "$marker" ]] || printf 'cleanup marker missing: %s\n' "$marker" >&3
    fi
    [ "$status" -eq 0 ]
  else
    if [[ "$status" -eq 0 ]]; then
      printf 'expected nonzero status, got 0\n%s\n' "$output" >&3
      [[ -f "$marker" ]] || printf 'cleanup marker missing: %s\n' "$marker" >&3
    fi
    [ "$status" -ne 0 ]
  fi

  if [[ ! -f "$marker" ]]; then
    printf 'cleanup marker missing: %s\n%s\n' "$marker" "$output" >&3
  fi
  [ -f "$marker" ]
  ralph_test_rm_workspace "$workspace"
}

@test "runtime overlay cleanup runs after successful runtime" {
  run_overlay_cleanup_case "success" "zero"
}

@test "runtime overlay cleanup runs after runtime failure" {
  run_overlay_cleanup_case "failure" "nonzero"
}

@test "runtime overlay cleanup runs after signal-like runtime exit" {
  run_overlay_cleanup_case "signal" "nonzero"
}

@test "run-plan startup recovers stale runtime overlay journals before invocation" {
  local workspace state_root plan_file stub_dir registry_file plan_key cursor_dir cursor_target backup_dir journal_dir journal_path

  workspace="$(mktemp -d)"
  state_root="$workspace/.ralph-workspace"
  plan_file="$workspace/PLAN.md"
  plan_key="PLAN"
  printf '%s\n' "- [ ] overlay recovery test" >"$plan_file"

  stub_dir="$workspace/stubs"
  mkdir -p "$stub_dir"
  cat <<'EOF' > "$stub_dir/cursor-agent"
#!/usr/bin/env bash
set -euo pipefail
python3 - <<'PY'
import os
from pathlib import Path
path = Path(os.environ["RALPH_CURRENT_PLAN_PATH"])
path.write_text(path.read_text().replace("- [ ]", "- [x]", 1))
PY
printf 'AGENT_INVOCATION_COMPLETE\n'
EOF
  chmod +x "$stub_dir/cursor-agent"

  cursor_dir="$workspace/.cursor"
  cursor_target="$cursor_dir/mcp.json"
  backup_dir="$state_root/runtime-config/$plan_key/originals/.cursor"
  journal_dir="$state_root/runtime-config/$plan_key/journals"
  mkdir -p "$cursor_dir" "$backup_dir" "$journal_dir"
  printf '%s' '{"mutated":true}' >"$cursor_target"
  printf '%s' '{"original":true}' >"$backup_dir/mcp.json"
  journal_path="$journal_dir/journal-${plan_key}-999-1.json"
  python3 - <<'PY' "$journal_path" "$plan_key" "$workspace" "$cursor_target" "$backup_dir/mcp.json"
import json, sys
path, plan_key, workspace, target, backup = sys.argv[1:]
data = {
    "pid": 999,
    "start_time": 1,
    "runtime": "cursor",
    "plan_key": plan_key,
    "workspace_root": workspace,
    "cleanup_status": "pending",
    "cleanup_time": None,
    "generated_files": [],
    "mutated_files": [{"path": target, "backup": backup, "restored": False}]
}
with open(path, "w") as fh:
    json.dump(data, fh, indent=2)
PY

  registry_file="$workspace/workspaces.json"
  run env -u RALPH_AGENT_TOOL_ACCESS -u RALPH_LAUNCHER_PID \
    PATH="$stub_dir:$PATH" \
    RALPH_HOME="$REPO_ROOT" \
    RALPH_GLOBAL_RUNTIME_HOME="$REPO_ROOT" \
    RALPH_PLAN_CAPTURE_USAGE=0 \
    RALPH_PLAN_SESSION_HOME="$state_root/sessions" \
    RALPH_PLAN_WORKSPACE_ROOT="$state_root" \
    CURSOR_PLAN_NO_COLOR=1 \
    RALPH_WORKSPACES_FILE="$registry_file" \
    bash "$RUN_PLAN_SH" --runtime cursor --plan "$plan_file" --workspace "$workspace" --workspace-root "$state_root" --model stub-model --non-interactive

  [ "$status" -eq 0 ]
  [ "$(cat "$cursor_target")" = '{"original":true}' ]
  python3 - <<'PY' "$journal_path"
import json, sys
data = json.load(open(sys.argv[1]))
assert data["cleanup_status"] == "recovered_after_interruption"
assert data["recovered_after_interruption"] is True
PY

  ralph_test_rm_workspace "$workspace"
}
