# shellcheck shell=bash
#!/usr/bin/env bats

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  # shellcheck disable=SC1090
  source "$REPO_ROOT/bundle/.ralph/bash-lib/run-plan-env.sh"
}

teardown() {
  unset CURSOR_PLAN_DISABLE_HUMAN_PROMPT
  unset CURSOR_PLAN_NO_OPEN
  unset CLAUDE_PLAN_DISABLE_HUMAN_PROMPT
  unset CLAUDE_PLAN_NO_OPEN
  unset RALPH_PLAN_DISABLE_HUMAN_PROMPT
  unset RALPH_PLAN_NO_OPEN
  unset RALPH_WORKSPACES_FILE
  unset XDG_CONFIG_HOME
}

@test "cursor fallback populates RALPH human flags from CURSOR env" {
  export CURSOR_PLAN_DISABLE_HUMAN_PROMPT=1
  export CURSOR_PLAN_NO_OPEN=1

  ralph_run_plan_load_env_for_runtime cursor

  [ "$RALPH_PLAN_DISABLE_HUMAN_PROMPT" = "1" ]
  [ "$RALPH_PLAN_NO_OPEN" = "1" ]
}

@test "claude precedence respects CLAUDE human flags over CURSOR" {
  export CLAUDE_PLAN_DISABLE_HUMAN_PROMPT=1
  export CLAUDE_PLAN_NO_OPEN=1
  export CURSOR_PLAN_DISABLE_HUMAN_PROMPT=0
  export CURSOR_PLAN_NO_OPEN=0

  ralph_run_plan_load_env_for_runtime claude

  [ "$RALPH_PLAN_DISABLE_HUMAN_PROMPT" = "1" ]
  [ "$RALPH_PLAN_NO_OPEN" = "1" ]
}

@test "missing runtime fails validation" {
  run ralph_run_plan_load_env_for_runtime

  [ "$status" -ne 0 ]
  [[ "$output" == *"RUNTIME must be set before calling ralph_run_plan_load_env_for_runtime."* ]]
}

@test "workspace registry writer creates user registry entry" {
  command -v python3 >/dev/null 2>&1 || skip "python3 unavailable"

  local tmp_dir workspace registry_file
  tmp_dir="$(mktemp -d)"
  workspace="$tmp_dir/workspace"
  registry_file="$tmp_dir/config/ralph/workspaces.json"
  mkdir -p "$workspace"

  run env RALPH_WORKSPACES_FILE="$registry_file" bash -c '
    set -euo pipefail
    source "$1"
    ralph_run_plan_record_workspace_registry "$2" codex PLAN16
  ' _ "$REPO_ROOT/bundle/.ralph/bash-lib/run-plan-env.sh" "$workspace"

  [ "$status" -eq 0 ]
  [ -f "$registry_file" ]
  run python3 - "$registry_file" "$workspace" <<'PY'
import json, os, sys
records = json.load(open(sys.argv[1], encoding="utf-8"))
assert len(records) == 1, records
record = records[0]
assert record["path"] == os.path.abspath(sys.argv[2]), record
assert record["planKey"] == "PLAN16", record
assert record["runtime"] == "codex", record
assert record["lastSeen"].endswith("Z"), record
PY
  [ "$status" -eq 0 ]

  rm -rf "$tmp_dir"
}

@test "workspace registry writer deduplicates newest entry and caps at 100" {
  command -v python3 >/dev/null 2>&1 || skip "python3 unavailable"

  local tmp_dir workspace registry_file
  tmp_dir="$(mktemp -d)"
  workspace="$tmp_dir/workspace"
  registry_file="$tmp_dir/workspaces.json"
  mkdir -p "$workspace"

  python3 - "$registry_file" "$workspace" <<'PY'
import json, os, sys
registry, workspace = sys.argv[1], os.path.abspath(sys.argv[2])
records = [
    {"path": workspace, "lastSeen": "2000-01-01T00:00:00Z", "planKey": "old", "runtime": "cursor"}
]
for idx in range(101):
    records.append({
        "path": f"/tmp/ralph-workspace-{idx:03d}",
        "lastSeen": f"2000-01-01T00:00:{idx % 60:02d}Z",
        "planKey": f"old-{idx}",
        "runtime": "claude",
    })
with open(registry, "w", encoding="utf-8") as handle:
    json.dump(records, handle)
PY

  run env RALPH_WORKSPACES_FILE="$registry_file" bash -c '
    set -euo pipefail
    source "$1"
    ralph_run_plan_record_workspace_registry "$2" opencode current-plan
  ' _ "$REPO_ROOT/bundle/.ralph/bash-lib/run-plan-env.sh" "$workspace"

  [ "$status" -eq 0 ]
  run python3 - "$registry_file" "$workspace" <<'PY'
import json, os, sys
records = json.load(open(sys.argv[1], encoding="utf-8"))
workspace = os.path.abspath(sys.argv[2])
assert len(records) == 100, len(records)
assert records[-1]["path"] == workspace, records[-1]
assert records[-1]["planKey"] == "current-plan", records[-1]
assert records[-1]["runtime"] == "opencode", records[-1]
assert sum(1 for item in records if item.get("path") == workspace) == 1, records
assert records[0]["path"] == "/tmp/ralph-workspace-002", records[0]
PY
  [ "$status" -eq 0 ]

  rm -rf "$tmp_dir"
}

@test "workspace registry writer no-ops with warning when python3 is missing" {
  local tmp_dir workspace registry_file empty_path
  tmp_dir="$(mktemp -d)"
  workspace="$tmp_dir/workspace"
  registry_file="$tmp_dir/workspaces.json"
  empty_path="$tmp_dir/bin"
  mkdir -p "$workspace" "$empty_path"

  run env PATH="$empty_path" RALPH_WORKSPACES_FILE="$registry_file" /bin/bash -c '
    set -euo pipefail
    source "$1"
    ralph_run_plan_record_workspace_registry "$2" cursor no-python
  ' _ "$REPO_ROOT/bundle/.ralph/bash-lib/run-plan-env.sh" "$workspace"

  [ "$status" -eq 0 ]
  [[ "$output" == *"Warning: python3 not found; skipping Ralph workspace registry write."* ]]
  [ ! -e "$registry_file" ]

  rm -rf "$tmp_dir"
}
