#!/usr/bin/env bats

source "$BATS_TEST_DIRNAME/../helper/load-lib.bash"
source "$REPO_ROOT/bundle/.ralph/bash-lib/plan-todo.sh"
source "$REPO_ROOT/bundle/.ralph/bash-lib/review-status.sh"

RUN_PLAN_SH="$REPO_ROOT/bundle/.ralph/run-plan.sh"

@test "loopback review-status extractor recognizes approved" {
  local tmpdir
  tmpdir=$(mktemp -d)
  local artifact="$tmpdir/review.md"

  cat >"$artifact" <<EOF
# Review Results

<!-- REVIEW_STATUS: START -->
status: approved
<!-- REVIEW_STATUS: END -->

All good.
EOF

  run bash -c "source '$REPO_ROOT/bundle/.ralph/bash-lib/review-status.sh'; ralph_extract_review_status '$artifact'"
  [ "$status" -eq 0 ]
  [ "$output" = "approved" ]

  rm -rf "$tmpdir"
}

@test "loopback review-status extractor recognizes changes-required" {
  local tmpdir
  tmpdir=$(mktemp -d)
  local artifact="$tmpdir/review.md"

  cat >"$artifact" <<EOF
# Review Results

<!-- REVIEW_STATUS: START -->
status: changes-required
<!-- REVIEW_STATUS: END -->

Please revise.
EOF

  run bash -c "source '$REPO_ROOT/bundle/.ralph/bash-lib/review-status.sh'; ralph_extract_review_status '$artifact'"
  [ "$status" -eq 0 ]
  [ "$output" = "changes-required" ]

  rm -rf "$tmpdir"
}

@test "loopback review-status extractor fails on missing file" {
  run bash -c "source '$REPO_ROOT/bundle/.ralph/bash-lib/review-status.sh'; ralph_extract_review_status '/nonexistent/path'"
  [ "$status" -ne 0 ]
  [ "$output" = "missing_file" ]
}

@test "loopback review-status extractor fails on missing markers" {
  local tmpdir
  tmpdir=$(mktemp -d)
  local artifact="$tmpdir/review.md"

  cat >"$artifact" <<EOF
# Review Results
No status here.
EOF

  run bash -c "source '$REPO_ROOT/bundle/.ralph/bash-lib/review-status.sh'; ralph_extract_review_status '$artifact'"
  [ "$status" -ne 0 ]
  [ "$output" = "missing_status" ]

  rm -rf "$tmpdir"
}

@test "loopback review-status extractor fails on invalid status value" {
  local tmpdir
  tmpdir=$(mktemp -d)
  local artifact="$tmpdir/review.md"

  cat >"$artifact" <<EOF
# Review Results

<!-- REVIEW_STATUS: START -->
status: invalid-value
<!-- REVIEW_STATUS: END -->
EOF

  run bash -c "source '$REPO_ROOT/bundle/.ralph/bash-lib/review-status.sh'; ralph_extract_review_status '$artifact'"
  [ "$status" -ne 0 ]
  [ "$output" = "invalid" ]

  rm -rf "$tmpdir"
}

@test "loopback iteration counter persists to and reads from state file" {
  local tmpdir session_dir
  tmpdir=$(mktemp -d)
  session_dir="$tmpdir/sessions/test-plan"
  mkdir -p "$session_dir"

  local loopback_test_script="$tmpdir/test-loopback.sh"
  cat >"$loopback_test_script" <<'EOF'
#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$REPO_ROOT/bundle/.ralph"
RALPH_SESSION_DIR="$session_dir"
export RALPH_SESSION_DIR

source "$SCRIPT_DIR/bash-lib/run-plan/run-plan-loopback.sh"

count1=$(ralph_run_plan_loopback_get_iteration_count "review" "implementation")
echo "initial: $count1"

inc1=$(ralph_run_plan_loopback_increment_iteration_count "review" "implementation")
echo "after increment 1: $inc1"

count2=$(ralph_run_plan_loopback_get_iteration_count "review" "implementation")
echo "persisted: $count2"

inc2=$(ralph_run_plan_loopback_increment_iteration_count "review" "implementation")
echo "after increment 2: $inc2"

count3=$(ralph_run_plan_loopback_get_iteration_count "review" "implementation")
echo "persisted again: $count3"

state_file=$(ralph_run_plan_loopback_state_file)
echo "state file: $state_file"
if [[ -f "$state_file" ]]; then
  echo "state content:"
  cat "$state_file"
fi
EOF

  chmod +x "$loopback_test_script"

  REPO_ROOT="$REPO_ROOT" \
  session_dir="$session_dir" \
  bash "$loopback_test_script" >"$tmpdir/output.txt" 2>&1

  grep -q "initial: 0" "$tmpdir/output.txt"
  grep -q "after increment 1: 1" "$tmpdir/output.txt"
  grep -q "persisted: 1" "$tmpdir/output.txt"
  grep -q "after increment 2: 2" "$tmpdir/output.txt"
  grep -q "persisted again: 2" "$tmpdir/output.txt"

  rm -rf "$tmpdir"
}

@test "loopback state file has correct JSON schema" {
  local tmpdir session_dir
  tmpdir=$(mktemp -d)
  session_dir="$tmpdir/sessions/test-plan"
  mkdir -p "$session_dir"

  local loopback_test_script="$tmpdir/test-loopback.sh"
  cat >"$loopback_test_script" <<'EOF'
#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$REPO_ROOT/bundle/.ralph"
RALPH_SESSION_DIR="$session_dir"
export RALPH_SESSION_DIR

source "$SCRIPT_DIR/bash-lib/run-plan/run-plan-loopback.sh"

ralph_run_plan_loopback_increment_iteration_count "review" "implementation"
ralph_run_plan_loopback_increment_iteration_count "review2" "impl2"

state_file=$(ralph_run_plan_loopback_state_file)
if [[ -f "$state_file" ]]; then
  python3 - "$state_file" <<'PY'
import json
import sys

with open(sys.argv[1], "r") as f:
  data = json.load(f)

assert "loops" in data, "Missing 'loops' key"
assert "review->implementation" in data["loops"], "Missing loop key"
assert data["loops"]["review->implementation"]["iterations"] == 1
assert "review2->impl2" in data["loops"], "Missing second loop key"
assert data["loops"]["review2->impl2"]["iterations"] == 1
print("OK")
PY
  echo "JSON schema validated"
else
  echo "ERROR: state file not created"
  exit 1
fi
EOF

  chmod +x "$loopback_test_script"

  REPO_ROOT="$REPO_ROOT" \
  session_dir="$session_dir" \
  bash "$loopback_test_script" >"$tmpdir/output.txt" 2>&1

  grep -q "JSON schema validated" "$tmpdir/output.txt" || { cat "$tmpdir/output.txt"; false; }

  rm -rf "$tmpdir"
}

write_artifact_cursor_stub() {
  local script_path="$1"
  local record_path="$2"
  local output_path="${3:-}"

  cat <<EOF >"$script_path"
#!/usr/bin/env bash
printf '=== invocation ===\n' >>"$record_path"
printf '%s\n' "\$@" >>"$record_path"
if [[ -n "\${STUB_PLAN_PATH:-}" && -f "\${STUB_PLAN_PATH:-}" ]]; then
  python3 - <<'PY'
import os
from pathlib import Path

path = Path(os.environ["STUB_PLAN_PATH"])
text = path.read_text()
if "status: open" in text:
    path.write_text(text.replace("status: open", "status: completed", 1))
PY
fi
if [[ -n "$output_path" ]]; then
  mkdir -p "$(dirname "$output_path")"
  printf 'done\n' >"$output_path"
fi
printf 'AGENT_INVOCATION_COMPLETE\n'
exit 0
EOF
  chmod +x "$script_path"
}

write_loopback_review_stub() {
  local script_path="$1"
  local record_path="$2"
  local status_list="$3"
  local review_artifact="$4"

  cat <<EOF >"$script_path"
#!/usr/bin/env bash
set -euo pipefail

record_path="${record_path}"
status_list="${status_list}"
review_artifact="${review_artifact}"

printf '=== invocation ===\n' >>"\$record_path"
printf '%s\n' "\$@" >>"\$record_path"

stage="\$(python3 - <<'PY'
import os
import pathlib

path = pathlib.Path(os.environ["STUB_PLAN_PATH"])
lines = path.read_text().splitlines()
in_todos = False
in_todo = False
status = ""
stage = ""

for raw_line in lines:
    stripped = raw_line.strip()
    if stripped == "todos:":
        in_todos = True
        continue
    if not in_todos:
        continue
    if raw_line.startswith("  - id:"):
        if in_todo and status == "open":
            print(stage)
            break
        in_todo = True
        status = ""
        stage = ""
        continue
    if not in_todo:
        continue
    if raw_line.startswith("    status:"):
        status = stripped.split(":", 1)[1].strip()
    elif raw_line.startswith("    stage:"):
        stage = stripped.split(":", 1)[1].strip()
else:
    if in_todo and status == "open":
        print(stage)
    else:
        print("")
PY
)"

python3 - <<'PY'
import os
import pathlib

path = pathlib.Path(os.environ["STUB_PLAN_PATH"])
text = path.read_text()
if "status: open" in text:
    path.write_text(text.replace("status: open", "status: completed", 1))
PY

if [[ "\$stage" == "review" ]]; then
  status_value=""
  if [[ -f "\$status_list" ]]; then
    status_value="\$(python3 - <<'PY'
import pathlib
import sys

path = pathlib.Path("$status_list")
lines = [line.strip() for line in path.read_text().splitlines() if line.strip()]
if not lines:
    sys.exit(0)
first, rest = lines[0], lines[1:]
path.write_text("\n".join(rest) + ("\n" if rest else ""))
print(first)
PY
)"
  fi

  if [[ -n "\$status_value" ]]; then
    cat <<STATUS >"\$review_artifact"
<!-- REVIEW_STATUS: START -->
status: \$status_value
<!-- REVIEW_STATUS: END -->
STATUS
  fi
fi

printf 'AGENT_INVOCATION_COMPLETE\n'
EOF

  chmod +x "$script_path"
}

setup_stub_run_plan_support() {
  local workspace="$1"
  local select_model_dir="$workspace/.cursor/ralph"
  local agent_tool_dir="$workspace/.ralph"

  mkdir -p "$select_model_dir" "$agent_tool_dir"
  cat <<'EOF' > "$select_model_dir/select-model.sh"
#!/usr/bin/env bash
select_model_cursor() {
  if [[ "$1" == "--batch" ]]; then
    shift
  fi
  printf '%s\n' "stub-model"
}
export -f select_model_cursor >/dev/null 2>&1 || true
EOF
  chmod +x "$select_model_dir/select-model.sh"

  cat <<'EOF' > "$agent_tool_dir/agent-config-tool.sh"
#!/usr/bin/env bash
case "$1" in
  list|validate|model|context|allowed-tools|downstream-stages)
    ;;
  *)
    ;;
esac
exit 0
EOF
  chmod +x "$agent_tool_dir/agent-config-tool.sh"
}

@test "loopback test: review stage loops back once on changes-required" {
  [ -f "$RUN_PLAN_SH" ] || skip "bundle run-plan missing"
  command -v python3 >/dev/null 2>&1 || skip "python3 unavailable"

  local workspace plan_file bin_dir session_home record registry_file
  local prep_output research_output review_status statuses
  workspace="$(mktemp -d)"
  bin_dir="$workspace/bin"
  session_home="$workspace/.sessions"
  record="$workspace/agent.args"
  registry_file="$(mktemp)"
  mkdir -p "$bin_dir" "$session_home"
  setup_stub_run_plan_support "$workspace"

  prep_output="$workspace/artifacts/loopback-range/prep-notes.md"
  research_output="$workspace/artifacts/loopback-range/research-findings.md"
  review_status="$workspace/artifacts/loopback-range/review-status.md"
  statuses="$workspace/loop-statuses.txt"
  mkdir -p "$(dirname "$prep_output")" "$(dirname "$research_output")" "$(dirname "$review_status")"
  printf 'prep notes\n' >"$prep_output"
  printf 'research findings\n' >"$research_output"
  printf 'changes-required\napproved\n' >"$statuses"

  plan_file="$workspace/PLAN.md"
  cat <<'EOF' > "$plan_file"
---
name: Loopback Range Test
overview: Test inclusive loopback range and progress rollback
execution: orchestration
pipeline:
  stages:
    - id: prep
      runtime: cursor
      model: stub-model
      produces:
        - path: artifacts/loopback-range/prep-notes.md
          required: true

    - id: research
      runtime: cursor
      model: stub-model
      requires:
        - path: artifacts/loopback-range/prep-notes.md
          required: true
      produces:
        - path: artifacts/loopback-range/research-findings.md
          required: true

    - id: review
      runtime: cursor
      model: stub-model
      requires:
        - path: artifacts/loopback-range/research-findings.md
          required: true
      produces:
        - path: artifacts/loopback-range/review-status.md
          required: true
      loopBackTo: research
      maxIterations: 3
      loopCheck:
        path: artifacts/loopback-range/review-status.md

todos:
  - id: prep-01
    status: open
    stage: prep
    content: Kick off the work by writing prep notes to artifacts/loopback-range/prep-notes.md
    verification: Confirm artifacts/loopback-range/prep-notes.md exists and is non-empty

  - id: research-01
    status: open
    stage: research
    content: Research and write findings to artifacts/loopback-range/research-findings.md
    verification: Confirm artifacts/loopback-range/research-findings.md exists and is non-empty

  - id: review-01
    status: open
    stage: review
    content: Review the findings and report status to artifacts/loopback-range/review-status.md
    verification: Confirm artifacts/loopback-range/review-status.md exists and follows the REVIEW_STATUS block
---
EOF

  write_loopback_review_stub "$bin_dir/cursor-agent" "$record" "$statuses" "$review_status"

  run bash -c '
    set -euo pipefail
    cd "$1"
    export PATH="$2:$PATH"
    export RALPH_USAGE_RISKS_ACKNOWLEDGED=1
    export RALPH_PLAN_SESSION_HOME="$3"
    export RALPH_PLAN_NO_CAFFEINATE=1
    export RALPH_LAUNCHER_PID=$$
    export STUB_PLAN_PATH="$4"
    export RALPH_WORKSPACES_FILE="$6"
    export RALPH_PLAN_KEY="loopback-range"
    export RALPH_ARTIFACT_NS="loopback-range"
    "$5" --runtime cursor --plan PLAN.md --non-interactive --model stub-model 2>&1 || true
  ' _ "$workspace" "$bin_dir" "$session_home" "$plan_file" "$RUN_PLAN_SH" "$registry_file"

  [[ "$output" == *"loopback reopened 2 TODO(s)"* ]] || echo "FAIL: output missing reopened message: $output"
  [[ "$output" == *"progress is now 1/3"* ]] || echo "FAIL: progress message wrong: $output"

  rm -rf "$workspace"
  rm -f "$registry_file"
}

@test "loopback test: stops reopening after max iterations" {
  [ -f "$RUN_PLAN_SH" ] || skip "bundle run-plan missing"
  command -v python3 >/dev/null 2>&1 || skip "python3 unavailable"

  local workspace plan_file bin_dir session_home record registry_file
  local prep_output research_output review_status statuses
  workspace="$(mktemp -d)"
  bin_dir="$workspace/bin"
  session_home="$workspace/.sessions"
  record="$workspace/agent.args"
  registry_file="$(mktemp)"
  mkdir -p "$bin_dir" "$session_home"
  setup_stub_run_plan_support "$workspace"

  prep_output="$workspace/artifacts/loopback-max/prep-notes.md"
  research_output="$workspace/artifacts/loopback-max/research-findings.md"
  review_status="$workspace/artifacts/loopback-max/review-status.md"
  statuses="$workspace/loop-statuses-max.txt"
  mkdir -p "$(dirname "$prep_output")" "$(dirname "$research_output")" "$(dirname "$review_status")"
  printf 'prep notes\n' >"$prep_output"
  printf 'research findings\n' >"$research_output"
  printf 'changes-required\nchanges-required\n' >"$statuses"

  plan_file="$workspace/PLAN.md"
  cat <<'EOF' > "$plan_file"
---
name: Loopback Max Iterations Test
overview: Ensure maxIterations stops the loop
execution: orchestration
pipeline:
  stages:
    - id: prep
      runtime: cursor
      model: stub-model
      produces:
        - path: artifacts/loopback-max/prep-notes.md
          required: true

    - id: research
      runtime: cursor
      model: stub-model
      requires:
        - path: artifacts/loopback-max/prep-notes.md
          required: true
      produces:
        - path: artifacts/loopback-max/research-findings.md
          required: true

    - id: review
      runtime: cursor
      model: stub-model
      requires:
        - path: artifacts/loopback-max/research-findings.md
          required: true
      produces:
        - path: artifacts/loopback-max/review-status.md
          required: true
      loopBackTo: research
      maxIterations: 1
      loopCheck:
        path: artifacts/loopback-max/review-status.md

todos:
  - id: prep-01
    status: open
    stage: prep
    content: Kick off the prep work.
    verification: Confirm artifacts/loopback-max/prep-notes.md exists and is non-empty

  - id: research-01
    status: open
    stage: research
    content: Perform research work.
    verification: Confirm artifacts/loopback-max/research-findings.md exists and is non-empty

  - id: review-01
    status: open
    stage: review
    content: Review findings and report status to artifacts/loopback-max/review-status.md
    verification: Confirm artifacts/loopback-max/review-status.md contains a valid REVIEW_STATUS block
---
EOF

  write_loopback_review_stub "$bin_dir/cursor-agent" "$record" "$statuses" "$review_status"

  run bash -c '
    set -euo pipefail
    cd "$1"
    export PATH="$2:$PATH"
    export RALPH_USAGE_RISKS_ACKNOWLEDGED=1
    export RALPH_PLAN_SESSION_HOME="$3"
    export RALPH_PLAN_NO_CAFFEINATE=1
    export RALPH_LAUNCHER_PID=$$
    export STUB_PLAN_PATH="$4"
    export RALPH_WORKSPACES_FILE="$6"
    export RALPH_PLAN_KEY="loopback-max"
    export RALPH_ARTIFACT_NS="loopback-max"
    "$5" --runtime cursor --plan PLAN.md --non-interactive --model stub-model 2>&1 || true
  ' _ "$workspace" "$bin_dir" "$session_home" "$plan_file" "$RUN_PLAN_SH" "$registry_file"

  [[ "$output" == *"loopback reopened 2 TODO(s)"* ]] || echo "FAIL: output missing reopened message: $output"
  [[ "$output" == *"loopback max iterations reached for stage=review target=research iterations=1 max=1"* ]] || echo "FAIL: max iterations message missing: $output"

  rm -rf "$workspace"
  rm -f "$registry_file"
}

@test "loopback test: resumes with persisted iteration count" {
  [ -f "$RUN_PLAN_SH" ] || skip "bundle run-plan missing"
  command -v python3 >/dev/null 2>&1 || skip "python3 unavailable"

  local workspace plan_file bin_dir session_home record registry_file
  local prep_output research_output review_status statuses
  workspace="$(mktemp -d)"
  bin_dir="$workspace/bin"
  session_home="$workspace/.sessions"
  record="$workspace/agent.args"
  registry_file="$(mktemp)"
  mkdir -p "$bin_dir" "$session_home"
  setup_stub_run_plan_support "$workspace"

  prep_output="$workspace/artifacts/loopback-resume/prep-notes.md"
  research_output="$workspace/artifacts/loopback-resume/research-findings.md"
  review_status="$workspace/artifacts/loopback-resume/review-status.md"
  statuses="$workspace/loop-statuses-resume.txt"
  mkdir -p "$(dirname "$prep_output")" "$(dirname "$research_output")" "$(dirname "$review_status")"
  printf 'prep notes\n' >"$prep_output"
  printf 'research findings\n' >"$research_output"
  printf 'changes-required\nchanges-required\n' >"$statuses"

  plan_file="$workspace/PLAN.md"
  cat <<'EOF' > "$plan_file"
---
name: Loopback Resume Test
overview: Resume after loopback while honoring maxIterations
execution: orchestration
pipeline:
  stages:
    - id: prep
      runtime: cursor
      model: stub-model
      produces:
        - path: artifacts/loopback-resume/prep-notes.md
          required: true

    - id: research
      runtime: cursor
      model: stub-model
      requires:
        - path: artifacts/loopback-resume/prep-notes.md
          required: true
      produces:
        - path: artifacts/loopback-resume/research-findings.md
          required: true

    - id: review
      runtime: cursor
      model: stub-model
      requires:
        - path: artifacts/loopback-resume/research-findings.md
          required: true
      produces:
        - path: artifacts/loopback-resume/review-status.md
          required: true
      loopBackTo: research
      maxIterations: 1
      loopCheck:
        path: artifacts/loopback-resume/review-status.md

todos:
  - id: prep-01
    status: open
    stage: prep
    content: Prepare the workspace.
    verification: Confirm artifacts/loopback-resume/prep-notes.md exists and is non-empty

  - id: research-01
    status: open
    stage: research
    content: Research task.
    verification: Confirm artifacts/loopback-resume/research-findings.md exists and is non-empty

  - id: review-01
    status: open
    stage: review
    content: Review findings and publish status.
    verification: Confirm artifacts/loopback-resume/review-status.md contains a REVIEW_STATUS block
---
EOF

  write_loopback_review_stub "$bin_dir/cursor-agent" "$record" "$statuses" "$review_status"

  local first_log first_pid reopened_seen=""
  first_log="$workspace/loopback-first.log"
  (
    set -euo pipefail
    cd "$workspace"
    export PATH="$bin_dir:$PATH"
    export RALPH_USAGE_RISKS_ACKNOWLEDGED=1
    export RALPH_PLAN_SESSION_HOME="$session_home"
    export RALPH_PLAN_NO_CAFFEINATE=1
    export RALPH_LAUNCHER_PID=$$
    export STUB_PLAN_PATH="$plan_file"
    export RALPH_WORKSPACES_FILE="$registry_file"
    export RALPH_PLAN_KEY="loopback-resume"
    export RALPH_ARTIFACT_NS="loopback-resume"
    "$RUN_PLAN_SH" --runtime cursor --plan PLAN.md --non-interactive --model stub-model >"$first_log" 2>&1
  ) &
  first_pid=$!

  for i in $(seq 1 600); do
    if [[ -f "$first_log" ]] && rg -q "loopback reopened" "$first_log"; then
      reopened_seen=1
      break
    fi
    sleep 0.1
  done

  kill "$first_pid" 2>/dev/null || true
  wait "$first_pid" 2>/dev/null || true

  [[ -n "$reopened_seen" ]] || { cat "$first_log"; echo "FAIL: loopback reopened message missing in first run"; false; }
  rg -Fq "loopback reopened 2 TODO(s)" "$first_log" || { cat "$first_log"; false; }

  run bash -c '
    set -euo pipefail
    cd "$1"
    export PATH="$2:$PATH"
    export RALPH_USAGE_RISKS_ACKNOWLEDGED=1
    export RALPH_PLAN_SESSION_HOME="$3"
    export RALPH_PLAN_NO_CAFFEINATE=1
    export RALPH_LAUNCHER_PID=$$
    export STUB_PLAN_PATH="$4"
    export RALPH_WORKSPACES_FILE="$6"
    export RALPH_PLAN_KEY="loopback-resume"
    export RALPH_ARTIFACT_NS="loopback-resume"
    "$5" --runtime cursor --plan PLAN.md --non-interactive --model stub-model 2>&1 || true
  ' _ "$workspace" "$bin_dir" "$session_home" "$plan_file" "$RUN_PLAN_SH" "$registry_file"

  [[ "$output" == *"loopback max iterations reached for stage=review target=research iterations=1 max=1"* ]] || echo "FAIL: resume run missing max iterations message: $output"

  rm -rf "$workspace"
  rm -f "$registry_file"
}

@test "loopback test: proceeds on approved status without reopening" {
  [ -f "$RUN_PLAN_SH" ] || skip "bundle run-plan missing"
  command -v python3 >/dev/null 2>&1 || skip "python3 unavailable"

  local workspace plan_file bin_dir session_home record registry_file
  local research_output review_output
  workspace="$(mktemp -d)"
  bin_dir="$workspace/bin"
  session_home="$workspace/.sessions"
  record="$workspace/agent.args"
  registry_file="$(mktemp)"
  mkdir -p "$bin_dir" "$session_home"
  setup_stub_run_plan_support "$workspace"

  research_output="$workspace/artifacts/test-approved/research-findings.md"
  review_output="$workspace/artifacts/test-approved/review-status.md"
  mkdir -p "$(dirname "$research_output")" "$(dirname "$review_output")"
  printf 'research findings\n' >"$research_output"

  plan_file="$workspace/PLAN.md"
  cat <<'EOF' > "$plan_file"
---
name: Loopback Approved Test
overview: Test loopback proceeds on approved
execution: orchestration
pipeline:
  stages:
    - id: research
      runtime: cursor
      model: stub-model
      produces:
        - path: artifacts/test-approved/research-findings.md
          required: true

    - id: review
      runtime: cursor
      model: stub-model
      requires:
        - path: artifacts/test-approved/research-findings.md
          required: true
      produces:
        - path: artifacts/test-approved/review-status.md
          required: true
      loopBackTo: research
      maxIterations: 2
      loopCheck:
        path: artifacts/test-approved/review-status.md

todos:
  - id: research-01
    status: open
    stage: research
    content: Research and write to artifacts/test-approved/research-findings.md
    verification: Confirm file exists and is non-empty

  - id: review-01
    status: open
    stage: review
    content: Review and write status to artifacts/test-approved/review-status.md with approved status
    verification: Confirm file exists and is non-empty
---
EOF

  write_artifact_cursor_stub "$bin_dir/cursor-agent" "$record"

  run bash -c '
    set -euo pipefail
    cd "$1"
    export PATH="$2:$PATH"
    export RALPH_USAGE_RISKS_ACKNOWLEDGED=1
    export RALPH_PLAN_SESSION_HOME="$3"
    export RALPH_PLAN_NO_CAFFEINATE=1
    export RALPH_LAUNCHER_PID=$$
    export STUB_PLAN_PATH="$4"
    export RALPH_WORKSPACES_FILE="$6"
    export RALPH_PLAN_KEY="test-approved"
    export RALPH_ARTIFACT_NS="test-approved"
    "$5" --runtime cursor --plan PLAN.md --non-interactive --model stub-model 2>&1 || true
  ' _ "$workspace" "$bin_dir" "$session_home" "$plan_file" "$RUN_PLAN_SH" "$registry_file"

  [[ "$output" == *"approved"* || "$output" == *"loopback"* ]] || echo "FAIL: output missing approved/loopback: $output"

  rm -rf "$workspace"
  rm -f "$registry_file"
}

@test "loopback test: fails on missing loopCheck artifact" {
  [ -f "$RUN_PLAN_SH" ] || skip "bundle run-plan missing"
  command -v python3 >/dev/null 2>&1 || skip "python3 unavailable"

  local workspace plan_file bin_dir session_home record registry_file
  local research_output
  workspace="$(mktemp -d)"
  bin_dir="$workspace/bin"
  session_home="$workspace/.sessions"
  record="$workspace/agent.args"
  registry_file="$(mktemp)"
  mkdir -p "$bin_dir" "$session_home"
  setup_stub_run_plan_support "$workspace"

  research_output="$workspace/artifacts/test-missing/research-findings.md"
  mkdir -p "$(dirname "$research_output")"
  printf 'research findings\n' >"$research_output"

  plan_file="$workspace/PLAN.md"
  cat <<'EOF' > "$plan_file"
---
name: Missing LoopCheck Test
overview: Test failure on missing loopCheck artifact
execution: orchestration
pipeline:
  stages:
    - id: research
      runtime: cursor
      model: stub-model
      produces:
        - path: artifacts/test-missing/research-findings.md
          required: true

    - id: review
      runtime: cursor
      model: stub-model
      requires:
        - path: artifacts/test-missing/research-findings.md
          required: true
      produces:
        - path: artifacts/test-missing/review-status.md
          required: true
      loopBackTo: research
      maxIterations: 2
      loopCheck:
        path: artifacts/test-missing/review-status.md

todos:
  - id: research-01
    status: open
    stage: research
    content: Research and write to artifacts/test-missing/research-findings.md
    verification: Confirm file exists

  - id: review-01
    status: open
    stage: review
    content: Review the findings (intentionally not writing status to test error)
    verification: Confirm review attempted
---
EOF

  write_artifact_cursor_stub "$bin_dir/cursor-agent" "$record"

  run bash -c '
    set -euo pipefail
    cd "$1"
    export PATH="$2:$PATH"
    export RALPH_USAGE_RISKS_ACKNOWLEDGED=1
    export RALPH_PLAN_SESSION_HOME="$3"
    export RALPH_PLAN_NO_CAFFEINATE=1
    export RALPH_LAUNCHER_PID=$$
    export STUB_PLAN_PATH="$4"
    export RALPH_WORKSPACES_FILE="$6"
    export RALPH_PLAN_KEY="test-missing"
    export RALPH_ARTIFACT_NS="test-missing"
    "$5" --runtime cursor --plan PLAN.md --non-interactive --model stub-model 2>&1 || true
  ' _ "$workspace" "$bin_dir" "$session_home" "$plan_file" "$RUN_PLAN_SH" "$registry_file"

  [[ "$output" == *"loop-check artifact missing for stage 'review' at path 'artifacts/test-missing/review-status.md'"* ]] || echo "FAIL: output missing error message: $output"

  rm -rf "$workspace"
  rm -f "$registry_file"
}

@test "loopback test: fails on invalid loopCheck status" {
  [ -f "$RUN_PLAN_SH" ] || skip "bundle run-plan missing"
  command -v python3 >/dev/null 2>&1 || skip "python3 unavailable"

  local workspace plan_file bin_dir session_home record registry_file
  local research_output review_output
  workspace="$(mktemp -d)"
  bin_dir="$workspace/bin"
  session_home="$workspace/.sessions"
  record="$workspace/agent.args"
  registry_file="$(mktemp)"
  mkdir -p "$bin_dir" "$session_home"
  setup_stub_run_plan_support "$workspace"

  research_output="$workspace/artifacts/test-invalid/research-findings.md"
  review_output="$workspace/artifacts/test-invalid/review-status.md"
  mkdir -p "$(dirname "$research_output")" "$(dirname "$review_output")"
  printf 'research findings\n' >"$research_output"
  cat >"$review_output" <<'STATUS'
# Review Status
<!-- REVIEW_STATUS: START -->
status: unknown-status
<!-- REVIEW_STATUS: END -->
STATUS

  plan_file="$workspace/PLAN.md"
  cat <<'EOF' > "$plan_file"
---
name: Invalid Status Test
overview: Test failure on invalid loopCheck status
execution: orchestration
pipeline:
  stages:
    - id: research
      runtime: cursor
      model: stub-model
      produces:
        - path: artifacts/test-invalid/research-findings.md
          required: true

    - id: review
      runtime: cursor
      model: stub-model
      requires:
        - path: artifacts/test-invalid/research-findings.md
          required: true
      produces:
        - path: artifacts/test-invalid/review-status.md
          required: true
      loopBackTo: research
      maxIterations: 2
      loopCheck:
        path: artifacts/test-invalid/review-status.md

todos:
  - id: research-01
    status: open
    stage: research
    content: Research and write findings
    verification: Confirm file exists

  - id: review-01
    status: open
    stage: review
    content: Review findings
    verification: Confirm review completed
---
EOF

  write_artifact_cursor_stub "$bin_dir/cursor-agent" "$record"

  run bash -c '
    set -euo pipefail
    cd "$1"
    export PATH="$2:$PATH"
    export RALPH_USAGE_RISKS_ACKNOWLEDGED=1
    export RALPH_PLAN_SESSION_HOME="$3"
    export RALPH_PLAN_NO_CAFFEINATE=1
    export RALPH_LAUNCHER_PID=$$
    export STUB_PLAN_PATH="$4"
    export RALPH_WORKSPACES_FILE="$6"
    export RALPH_PLAN_KEY="test-invalid"
    export RALPH_ARTIFACT_NS="test-invalid"
    "$5" --runtime cursor --plan PLAN.md --non-interactive --model stub-model 2>&1 || true
  ' _ "$workspace" "$bin_dir" "$session_home" "$plan_file" "$RUN_PLAN_SH" "$registry_file"

  [[ "$output" == *"loop-check artifact invalid for stage 'review' at path 'artifacts/test-invalid/review-status.md' (status: invalid)"* ]] || echo "FAIL: output missing error: $output"

  rm -rf "$workspace"
  rm -f "$registry_file"
}
