#!/usr/bin/env bats

source "$BATS_TEST_DIRNAME/../helper/load-lib.bash"
source "$REPO_ROOT/bundle/.ralph/bash-lib/plan-todo.sh"

RUN_PLAN_SH="$REPO_ROOT/bundle/.ralph/run-plan.sh"
RUN_PLAN_ARGS_FILE="$REPO_ROOT/.ralph/bash-lib/run-plan/run-plan-args.sh"
RUN_PLAN_CORE_FILE="$REPO_ROOT/.ralph/bash-lib/run-plan/run-plan-core.sh"

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

write_stub_npm() {
  local bin_dir="$1"
  cat <<'EOF' > "$bin_dir/npm"
#!/usr/bin/env bash
exit 0
EOF
  chmod +x "$bin_dir/npm"
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
if "- [ ]" in text:
    path.write_text(text.replace("- [ ]", "- [x]", 1))
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

@test "unified runner entrypoint exists (bundle)" {
  [ -f "$RUN_PLAN_SH" ]
}

@test "missing runtime without TTY fails fast with guidance" {
  [ -f "$RUN_PLAN_SH" ] || skip "bundle run-plan missing"
  # Bats inherits a TTY when run from an interactive terminal; force non-TTY stdin
  # so we exercise the fast-fail branch instead of blocking on the runtime menu.
  unset RALPH_PLAN_RUNTIME
  run "$RUN_PLAN_SH" --plan "$REPO_ROOT/PLAN.md" </dev/null
  [ "$status" -ne 0 ]
  [[ "$output" == *"Error: runtime must be provided via --runtime or RALPH_PLAN_RUNTIME when stdin is not a terminal."* ]]
}

@test "missing runtime with non-interactive still requires explicit runtime" {
  [ -f "$RUN_PLAN_SH" ] || skip "bundle run-plan missing"
  run "$RUN_PLAN_SH" --non-interactive --plan "$REPO_ROOT/PLAN.md"
  [ "$status" -ne 0 ]
  [[ "$output" == *"Error: runtime must be provided via --runtime or RALPH_PLAN_RUNTIME (cursor, claude, codex, opencode, antigravity, or agy)."* ]]
}

@test "invalid runtime value fails fast with guidance" {
  [ -f "$RUN_PLAN_SH" ] || skip "bundle run-plan missing"
  run "$RUN_PLAN_SH" --runtime invalid --plan "$REPO_ROOT/PLAN.md"
  [ "$status" -ne 0 ]
  [[ "$output" == *"Error: --runtime must be one of cursor, claude, codex, opencode, or antigravity."* ]]
}

@test "--help and unknown flag exit quickly" {
  [ -f "$RUN_PLAN_SH" ] || skip "bundle run-plan missing"
  run /usr/bin/env bash "$RUN_PLAN_SH" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"Usage:"* ]]

  run /usr/bin/env bash "$RUN_PLAN_SH" --invalid-flag
  [ "$status" -ne 0 ]
  [[ "$output" == *"unknown argument"* ]]
}

@test "non-interactive gate includes --model (PLAN_MODEL_CLI)" {
  [ -f "$RUN_PLAN_SH" ] || skip "bundle run-plan missing"
  grep -Fq 'PLAN_MODEL_CLI' "$RUN_PLAN_ARGS_FILE"
  # The prebuilt-agent wording was removed with the profile surface; the gate
  # now names the model inputs only.
  run grep -F 'Non-interactive mode requires --model <id>' "$RUN_PLAN_CORE_FILE"
  [ "$status" -eq 0 ]
  [[ "$output" == *"--model <id>"* ]]
  ! grep -Fq 'prebuilt agent' "$RUN_PLAN_CORE_FILE"
}

@test "--model requires a value" {
  [ -f "$RUN_PLAN_SH" ] || skip "bundle run-plan missing"
  run /usr/bin/env bash "$RUN_PLAN_SH" --runtime cursor --plan "$REPO_ROOT/PLAN.md" --model
  [ "$status" -ne 0 ]
  [[ "$output" == *"Error: --model requires a model id string."* ]]
}

@test "non-interactive run-plan stops with stubbed CLI" {
  [ -f "$RUN_PLAN_SH" ] || skip "bundle run-plan missing"
  command -v python3 >/dev/null 2>&1 || skip "python3 unavailable"

  local workspace plan_file bin_dir cursor_record claude_record codex_record registry_file
  workspace="$(mktemp -d)"
  registry_file="$(mktemp)"
  bin_dir="$workspace/bin"
  mkdir -p "$bin_dir"

  plan_file="$workspace/PLAN.md"
  cat <<'EOF' > "$plan_file"
# Non-interactive stub plan
- [ ] stub non-interactive invocation
EOF

  local select_model_dir session_home
  select_model_dir="$workspace/.cursor/ralph"
  mkdir -p "$select_model_dir"
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

  local agent_tool_dir
  agent_tool_dir="$workspace/.ralph"
  mkdir -p "$agent_tool_dir"
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

  cursor_record="$workspace/cursor.args"
  claude_record="$workspace/claude.args"
  codex_record="$workspace/codex.args"

  cat <<EOF > "$bin_dir/cursor-agent"
#!/usr/bin/env bash
printf '%s\n' "\$@" >>"$cursor_record"
if [[ -n "\$STUB_PLAN_PATH" && -f "\$STUB_PLAN_PATH" ]]; then
  if command -v python3 &>/dev/null; then
    python3 - <<'PY'
import os, pathlib
path = pathlib.Path(os.environ["STUB_PLAN_PATH"])
text = path.read_text()
target = "- [ ]"
if target in text:
    path.write_text(text.replace(target, "- [x]", 1))
PY
  fi
fi
exit 0
EOF

  cat <<EOF > "$bin_dir/claude"
#!/usr/bin/env bash
printf '%s\n' "\$@" >>"$claude_record"
exit 0
EOF

  cat <<EOF > "$bin_dir/codex"
#!/usr/bin/env bash
printf '%s\n' "\$@" >>"$codex_record"
exit 0
EOF

  chmod +x "$bin_dir/cursor-agent" "$bin_dir/claude" "$bin_dir/codex"

  session_home="$workspace/.sessions"
  mkdir -p "$session_home"

  run bash -c '
    set -euo pipefail
    cd "$1"
    export PATH="$2:$PATH"
    export RALPH_MODE=hybrid
    export RALPH_USAGE_RISKS_ACKNOWLEDGED=1
    export RALPH_PLAN_SESSION_HOME="$5"
    export STUB_PLAN_PATH="$4"
    export RALPH_WORKSPACES_FILE="$6"
    unset RALPH_PLAN_KEY RALPH_ARTIFACT_NS
    "$3" --runtime cursor --plan PLAN.md --non-interactive --model stub-model
  ' _ "$workspace" "$bin_dir" "$RUN_PLAN_SH" "$plan_file" "$session_home" "$registry_file"

  [ "$status" -eq 0 ]
  grep -Fq -- "--model" "$cursor_record"
  grep -Fq -- "stub-model" "$cursor_record"
  grep -Fq -- "- [x]" "$plan_file"
  run python3 - "$registry_file" "$workspace" <<'PY'
import json, os, sys
records = json.load(open(sys.argv[1], encoding="utf-8"))
assert records[0]["path"] == os.path.abspath(sys.argv[2]), records
assert records[0]["planKey"] == "PLAN", records
assert records[0]["runtime"] == "cursor", records
PY
  [ "$status" -eq 0 ]

  ralph_test_rm_workspace "$workspace"
  rm -f "$registry_file"
}

@test "run-plan accepts verification completion without blocking gates" {
  [ -f "$RUN_PLAN_SH" ] || skip "bundle run-plan missing"

  local workspace plan_file bin_dir session_home
  workspace="$(mktemp -d)"
  bin_dir="$workspace/bin"
  session_home="$workspace/.sessions"
  mkdir -p "$bin_dir" "$session_home"
  setup_stub_run_plan_support "$workspace"
  write_stub_npm "$bin_dir"

  plan_file="$workspace/PLAN.md"
  cat <<'EOF' > "$plan_file"
# Verification block test
- [ ] Verification: run npm test
EOF

  cat <<'EOF' > "$bin_dir/cursor-agent"
#!/usr/bin/env bash
printf '%s\n' "retrying completion with no evidence"
python3 - <<'PY'
import os
from pathlib import Path

path = Path(os.environ["STUB_PLAN_PATH"])
text = path.read_text()
path.write_text(text.replace("- [ ]", "- [x]", 1))
PY
exit 0
EOF
  chmod +x "$bin_dir/cursor-agent"

  run bash -c '
    set -euo pipefail
    cd "$1"
    export PATH="$2:$PATH"
    export RALPH_MODE=hybrid
    export RALPH_USAGE_RISKS_ACKNOWLEDGED=1
    export RALPH_PLAN_SESSION_HOME="$5"
    export CURSOR_PLAN_MAX_ITER=1
    export STUB_PLAN_PATH="$4"
    "$3" --runtime cursor --plan PLAN.md --non-interactive --model stub-model
  ' _ "$workspace" "$bin_dir" "$RUN_PLAN_SH" "$plan_file" "$session_home"

  [ "$status" -eq 0 ]
  grep -Fq -- "- [x] Verification: run npm test" "$plan_file"

  ralph_test_rm_workspace "$workspace"
}

@test "run-plan accepts verified completion when evidence is present" {
  [ -f "$RUN_PLAN_SH" ] || skip "bundle run-plan missing"

  local workspace plan_file bin_dir session_home
  workspace="$(mktemp -d)"
  bin_dir="$workspace/bin"
  session_home="$workspace/.sessions"
  mkdir -p "$bin_dir" "$session_home"
  setup_stub_run_plan_support "$workspace"
  write_stub_npm "$bin_dir"

  plan_file="$workspace/PLAN.md"
  cat <<'EOF' > "$plan_file"
# Verification success test
- [ ] Verification: run npm test
EOF

  cat <<'EOF' > "$bin_dir/cursor-agent"
#!/usr/bin/env bash
printf '%s\n' "VERIFIED: run npm test (exit 0)"
python3 - <<'PY'
import os
from pathlib import Path

path = Path(os.environ["STUB_PLAN_PATH"])
text = path.read_text()
path.write_text(text.replace("- [ ]", "- [x]", 1))
PY
exit 0
EOF
  chmod +x "$bin_dir/cursor-agent"

  run bash -c '
    set -euo pipefail
    cd "$1"
    export PATH="$2:$PATH"
    export RALPH_MODE=hybrid
    export RALPH_USAGE_RISKS_ACKNOWLEDGED=1
    export RALPH_PLAN_SESSION_HOME="$5"
    export STUB_PLAN_PATH="$4"
    "$3" --runtime cursor --plan PLAN.md --non-interactive --model stub-model
  ' _ "$workspace" "$bin_dir" "$RUN_PLAN_SH" "$plan_file" "$session_home"

  [ "$status" -eq 0 ]
  grep -Fq -- "- [x] Verification: run npm test" "$plan_file"

  ralph_test_rm_workspace "$workspace"
}

@test "run-plan accepts implementation completion without repo-delta gate" {
  [ -f "$RUN_PLAN_SH" ] || skip "bundle run-plan missing"

  local workspace plan_file bin_dir session_home
  workspace="$(mktemp -d)"
  bin_dir="$workspace/bin"
  session_home="$workspace/.sessions"
  mkdir -p "$bin_dir" "$session_home"
  setup_stub_run_plan_support "$workspace"

  plan_file="$workspace/PLAN.md"
  cat <<'EOF' > "$plan_file"
# Implementation block test
- [ ] Implement the helper validation guardrails
EOF

  cat <<'EOF' > "$bin_dir/cursor-agent"
#!/usr/bin/env bash
printf '%s\n' "done"
python3 - <<'PY'
import os
from pathlib import Path

path = Path(os.environ["STUB_PLAN_PATH"])
text = path.read_text()
path.write_text(text.replace("- [ ]", "- [x]", 1))
PY
exit 0
EOF
  chmod +x "$bin_dir/cursor-agent"

  run bash -c '
    set -euo pipefail
    cd "$1"
    export PATH="$2:$PATH"
    export RALPH_MODE=hybrid
    export RALPH_USAGE_RISKS_ACKNOWLEDGED=1
    export RALPH_PLAN_SESSION_HOME="$5"
    export CURSOR_PLAN_MAX_ITER=1
    export STUB_PLAN_PATH="$4"
    "$3" --runtime cursor --plan PLAN.md --non-interactive --model stub-model
  ' _ "$workspace" "$bin_dir" "$RUN_PLAN_SH" "$plan_file" "$session_home"

  [ "$status" -eq 0 ]
  grep -Fq -- "- [x] Implement the helper validation guardrails" "$plan_file"

  ralph_test_rm_workspace "$workspace"
}

@test "artifact inputs fail fast when a required input file is missing" {
  [ -f "$RUN_PLAN_SH" ] || skip "bundle run-plan missing"
  command -v python3 >/dev/null 2>&1 || skip "python3 unavailable"

  local workspace plan_file bin_dir session_home record output_path registry_file
  workspace="$(mktemp -d)"
  bin_dir="$workspace/bin"
  session_home="$workspace/.sessions"
  record="$workspace/cursor.args"
  output_path="$workspace/outputs/artifact-plan/build-stage/stage-output.txt"
  registry_file="$(mktemp)"
  mkdir -p "$bin_dir" "$session_home"
  setup_stub_run_plan_support "$workspace"

  plan_file="$workspace/PLAN.md"
  cat <<'EOF' > "$plan_file"
---
pipeline:
  stages:
    - id: build-stage
      runtime: cursor
      model: stub-model
      requires:
        - path: inputs/{{PLAN_KEY}}/{{STAGE_ID}}/shared-input.txt
          required: false
      produces:
        - path: outputs/{{PLAN_KEY}}/{{STAGE_ID}}/stage-output.txt
          required: false
todos:
  - id: build-task
    stage: build-stage
    status: open
    content: Build the missing-input artifact
    requires:
      - path: inputs/{{ARTIFACT_NS}}/{{STAGE_ID}}/shared-input.txt
        required: true
    produces:
      - path: outputs/{{ARTIFACT_NS}}/{{STAGE_ID}}/stage-output.txt
        required: true
---
EOF

  write_artifact_cursor_stub "$bin_dir/cursor-agent" "$record" "$output_path"

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
    export RALPH_PLAN_KEY="artifact-plan"
    export RALPH_ARTIFACT_NS="artifact-plan"
    "$5" --runtime cursor --plan PLAN.md --non-interactive --model stub-model
  ' _ "$workspace" "$bin_dir" "$session_home" "$plan_file" "$RUN_PLAN_SH" "$registry_file"

  [ "$status" -ne 0 ]
  [[ "$output" == *"Missing required input artifact(s) for TODO line 1:"* ]]
  [[ ! -f "$record" ]]

  ralph_test_rm_workspace "$workspace"
  rm -f "$registry_file"
}

@test "artifact outputs fail when a required output file stays missing after completion" {
  [ -f "$RUN_PLAN_SH" ] || skip "bundle run-plan missing"
  command -v python3 >/dev/null 2>&1 || skip "python3 unavailable"

  local workspace plan_file bin_dir session_home record input_path registry_file
  workspace="$(mktemp -d)"
  bin_dir="$workspace/bin"
  session_home="$workspace/.sessions"
  record="$workspace/cursor.args"
  input_path="$workspace/inputs/artifact-plan/build-stage/shared-input.txt"
  registry_file="$(mktemp)"
  mkdir -p "$(dirname "$input_path")" "$bin_dir" "$session_home"
  setup_stub_run_plan_support "$workspace"

  plan_file="$workspace/PLAN.md"
  cat <<'EOF' > "$plan_file"
---
pipeline:
  stages:
    - id: build-stage
      runtime: cursor
      model: stub-model
      requires:
        - path: inputs/{{PLAN_KEY}}/{{STAGE_ID}}/shared-input.txt
          required: false
      produces:
        - path: outputs/{{PLAN_KEY}}/{{STAGE_ID}}/stage-output.txt
          required: false
todos:
  - id: build-task
    stage: build-stage
    status: open
    content: Build the missing-output artifact
    requires:
      - path: inputs/{{ARTIFACT_NS}}/{{STAGE_ID}}/shared-input.txt
        required: true
    produces:
      - path: outputs/{{ARTIFACT_NS}}/{{STAGE_ID}}/stage-output.txt
        required: true
---
EOF

  printf 'input\n' >"$input_path"
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
    export RALPH_PLAN_KEY="artifact-plan"
    export RALPH_ARTIFACT_NS="artifact-plan"
    "$5" --runtime cursor --plan PLAN.md --non-interactive --model stub-model
  ' _ "$workspace" "$bin_dir" "$session_home" "$plan_file" "$RUN_PLAN_SH" "$registry_file"

  [ "$status" -ne 0 ]
  [[ "$output" == *"Missing required output artifact(s) for TODO line 1:"* ]]
  [[ -s "$record" ]]
  grep -Fq -- "AGENT_INVOCATION_COMPLETE" "$record"

  ralph_test_rm_workspace "$workspace"
  rm -f "$registry_file"
}

@test "artifact checks succeed when resolved input and output paths exist" {
  [ -f "$RUN_PLAN_SH" ] || skip "bundle run-plan missing"
  command -v python3 >/dev/null 2>&1 || skip "python3 unavailable"

  local workspace plan_file bin_dir session_home record input_path output_path registry_file
  workspace="$(mktemp -d)"
  bin_dir="$workspace/bin"
  session_home="$workspace/.sessions"
  record="$workspace/cursor.args"
  input_path="$workspace/inputs/artifact-plan/build-stage/shared-input.txt"
  output_path="$workspace/outputs/artifact-plan/build-stage/stage-output.txt"
  registry_file="$(mktemp)"
  mkdir -p "$(dirname "$input_path")" "$(dirname "$output_path")" "$bin_dir" "$session_home"
  setup_stub_run_plan_support "$workspace"

  plan_file="$workspace/PLAN.md"
  cat <<'EOF' > "$plan_file"
---
pipeline:
  stages:
    - id: build-stage
      runtime: cursor
      model: stub-model
      requires:
        - path: inputs/{{PLAN_KEY}}/{{STAGE_ID}}/shared-input.txt
          required: false
      produces:
        - path: outputs/{{PLAN_KEY}}/{{STAGE_ID}}/stage-output.txt
          required: false
todos:
  - id: build-task
    stage: build-stage
    status: open
    content: Build the artifact successfully
    requires:
      - path: inputs/{{ARTIFACT_NS}}/{{STAGE_ID}}/shared-input.txt
        required: true
    produces:
      - path: outputs/{{ARTIFACT_NS}}/{{STAGE_ID}}/stage-output.txt
        required: true
---
EOF

  printf 'input\n' >"$input_path"
  write_artifact_cursor_stub "$bin_dir/cursor-agent" "$record" "$output_path"

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
    export RALPH_PLAN_KEY="artifact-plan"
    export RALPH_ARTIFACT_NS="artifact-plan"
    "$5" --runtime cursor --plan PLAN.md --non-interactive --model stub-model
  ' _ "$workspace" "$bin_dir" "$session_home" "$plan_file" "$RUN_PLAN_SH" "$registry_file"

  [ "$status" -eq 0 ]
  [ -s "$output_path" ]
  grep -Fq -- "AGENT_INVOCATION_COMPLETE" "$record"

  ralph_test_rm_workspace "$workspace"
  rm -f "$registry_file"
}

@test "artifact prompt surfaces input artifacts once and omits the section for TODOs without requires" {
  [ -f "$RUN_PLAN_SH" ] || skip "bundle run-plan missing"
  command -v python3 >/dev/null 2>&1 || skip "python3 unavailable"

  local workspace plan_file bin_dir session_home record input_path output_path registry_file
  workspace="$(mktemp -d)"
  bin_dir="$workspace/bin"
  session_home="$workspace/.sessions"
  record="$workspace/cursor.args"
  input_path="$workspace/inputs/artifact-plan/inputs-stage/shared-input.txt"
  output_path="$workspace/outputs/artifact-plan/inputs-stage/stage-output.txt"
  registry_file="$(mktemp)"
  mkdir -p "$(dirname "$input_path")" "$(dirname "$output_path")" "$bin_dir" "$session_home"
  setup_stub_run_plan_support "$workspace"

  plan_file="$workspace/PLAN.md"
  cat <<'EOF' > "$plan_file"
---
pipeline:
  stages:
    - id: inputs-stage
      runtime: cursor
      model: stub-model
      requires:
        - path: inputs/{{PLAN_KEY}}/{{STAGE_ID}}/shared-input.txt
          required: false
      produces:
        - path: outputs/{{PLAN_KEY}}/{{STAGE_ID}}/stage-output.txt
          required: false
    - id: plain-stage
      runtime: cursor
      model: stub-model
todos:
  - id: first-task
    stage: inputs-stage
    status: open
    content: First TODO with inputs
    requires:
      - path: inputs/{{ARTIFACT_NS}}/{{STAGE_ID}}/shared-input.txt
        required: true
    produces:
      - path: outputs/{{ARTIFACT_NS}}/{{STAGE_ID}}/stage-output.txt
        required: true
  - id: second-task
    stage: plain-stage
    status: open
    content: Second TODO without inputs
---
EOF

  printf 'input\n' >"$input_path"
  write_artifact_cursor_stub "$bin_dir/cursor-agent" "$record" "$output_path"

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
    export RALPH_PLAN_KEY="artifact-plan"
    export RALPH_ARTIFACT_NS="artifact-plan"
    "$5" --runtime cursor --plan PLAN.md --non-interactive --model stub-model
  ' _ "$workspace" "$bin_dir" "$session_home" "$plan_file" "$RUN_PLAN_SH" "$registry_file"

  [ "$status" -eq 0 ]
  [ "$(grep -c '^=== invocation ===$' "$record")" -eq 2 ]
  [ "$(grep -c '^Input artifacts$' "$record")" -eq 1 ]
  grep -Fq -- "- inputs/artifact-plan/inputs-stage/shared-input.txt" "$record"
  grep -Fq -- "Second TODO without inputs" "$record"

  ralph_test_rm_workspace "$workspace"
  rm -f "$registry_file"
}

@test "strict proxy violation stops run-plan and records incomplete usage" {
  [ -f "$RUN_PLAN_SH" ] || skip "bundle run-plan missing"
  command -v python3 >/dev/null 2>&1 || skip "python3 unavailable"

  local workspace plan_file bin_dir session_home
  workspace="$(mktemp -d)"
  bin_dir="$workspace/bin"
  session_home="$workspace/.sessions"
  mkdir -p "$bin_dir" "$session_home"
  setup_stub_run_plan_support "$workspace"

  plan_file="$workspace/PLAN.md"
  cat <<'EOF' > "$plan_file"
# Strict proxy guard
- [ ] Strictly proxy this invocation
EOF

  cat <<'EOF' > "$bin_dir/cursor-agent"
#!/usr/bin/env bash
python3 - <<'PY'
import os
from pathlib import Path

path = Path(os.environ["STUB_PLAN_PATH"])
text = path.read_text()
path.write_text(text.replace("- [ ]", "- [x]", 1))
PY

printf '%s\n' '{"type":"tool_call","tool_call":{"grep":{"callID":"1"}}}'

exit 0
EOF
  chmod +x "$bin_dir/cursor-agent"

  run bash -c '
    set -euo pipefail
    cd "$1"
    export PATH="$2:$PATH"
    export RALPH_USAGE_RISKS_ACKNOWLEDGED=1
    export RALPH_PLAN_SESSION_HOME="$5"
    export STUB_PLAN_PATH="$4"
    export RALPH_MODE="ralph"
    export RALPH_AGENT_TOOL_ACCESS_REQUIRE_PROXY="1"
    export CURSOR_PLAN_MAX_ITER=1
    "$3" --runtime cursor --plan PLAN.md --non-interactive --model stub-model
  ' _ "$workspace" "$bin_dir" "$RUN_PLAN_SH" "$plan_file" "$session_home"

  plan_status=$status
  plan_output="$output"
  [ "$plan_status" -ne 0 ]
  [[ "$plan_output" == *"Strict proxy policy violation detected; stopping plan run."* ]]
  [[ "$plan_output" != *"All TODOs complete"* ]]

  usage_file="$(find "$workspace/.ralph-workspace/logs" -name invocation-usage.json -print | head -n 1)"
  [ -n "$usage_file" ]

  run python3 - "$usage_file" <<'PY'
import json, sys

doc = json.load(open(sys.argv[1], encoding="utf-8"))
record = doc["invocations"][0]
assert record["todo_completed"] is False
PY
  [ "$status" -eq 0 ]

  ralph_test_rm_workspace "$workspace"
}

@test "generic CLI failure is not labeled a strict proxy violation" {
  [ -f "$RUN_PLAN_SH" ] || skip "bundle run-plan missing"

  local workspace plan_file bin_dir session_home
  workspace="$(mktemp -d)"
  bin_dir="$workspace/bin"
  session_home="$workspace/.sessions"
  mkdir -p "$bin_dir" "$session_home"
  setup_stub_run_plan_support "$workspace"

  plan_file="$workspace/PLAN.md"
  cat <<'EOF' > "$plan_file"
# Generic failure
- [ ] TODO that fails without any policy violation
EOF

  cat <<'EOF' > "$bin_dir/cursor-agent"
#!/usr/bin/env bash
echo "unexpected internal failure while contacting model backend"
exit 3
EOF
  chmod +x "$bin_dir/cursor-agent"

  run bash -c '
    set -euo pipefail
    cd "$1"
    export PATH="$2:$PATH"
    export RALPH_USAGE_RISKS_ACKNOWLEDGED=1
    export RALPH_PLAN_SESSION_HOME="$5"
    export STUB_PLAN_PATH="$4"
    export CURSOR_PLAN_MAX_ITER=1
    "$3" --runtime cursor --plan PLAN.md --non-interactive --model stub-model
  ' _ "$workspace" "$bin_dir" "$RUN_PLAN_SH" "$plan_file" "$session_home"

  plan_status=$status
  plan_output="$output"
  [ "$plan_status" -ne 0 ]
  [[ "$plan_output" != *"Strict proxy policy violation"* ]]
  [[ "$plan_output" == *"Runtime CLI failed; stopping plan run."* ]]
  [[ "$plan_output" == *"Exit code: 3"* ]]

  ralph_test_rm_workspace "$workspace"
}

@test "MCP transport death is classified in the failure report" {
  [ -f "$RUN_PLAN_SH" ] || skip "bundle run-plan missing"

  local workspace plan_file bin_dir session_home
  workspace="$(mktemp -d)"
  bin_dir="$workspace/bin"
  session_home="$workspace/.sessions"
  mkdir -p "$bin_dir" "$session_home"
  setup_stub_run_plan_support "$workspace"

  plan_file="$workspace/PLAN.md"
  cat <<'EOF' > "$plan_file"
# Transport failure
- [ ] TODO that loses the ralph MCP server
EOF

  cat <<'EOF' > "$bin_dir/cursor-agent"
#!/usr/bin/env bash
echo "Error: No such tool available: mcp__ralph__ralph_proxy_shell"
exit 1
EOF
  chmod +x "$bin_dir/cursor-agent"

  run bash -c '
    set -euo pipefail
    cd "$1"
    export PATH="$2:$PATH"
    export RALPH_USAGE_RISKS_ACKNOWLEDGED=1
    export RALPH_PLAN_SESSION_HOME="$5"
    export STUB_PLAN_PATH="$4"
    export CURSOR_PLAN_MAX_ITER=1
    "$3" --runtime cursor --plan PLAN.md --non-interactive --model stub-model
  ' _ "$workspace" "$bin_dir" "$RUN_PLAN_SH" "$plan_file" "$session_home"

  plan_status=$status
  plan_output="$output"
  [ "$plan_status" -ne 0 ]
  [[ "$plan_output" != *"Strict proxy policy violation"* ]]
  [[ "$plan_output" == *"Ralph MCP transport failed during the invocation"* ]]
  [[ "$plan_output" == *"No such tool available: mcp__ralph__ralph_proxy_shell"* ]]

  ralph_test_rm_workspace "$workspace"
}

@test "run-plan accepts manual ack for a final manual TODO" {
  [ -f "$RUN_PLAN_SH" ] || skip "bundle run-plan missing"

  local workspace plan_file bin_dir session_home ack_dir ack_file todo_hash ack_ns
  workspace="$(mktemp -d)"
  bin_dir="$workspace/bin"
  session_home="$workspace/.sessions"
  ack_ns="${RALPH_PLAN_KEY:-PLAN}"
  ack_dir="$session_home/$ack_ns"
  ack_file="$ack_dir/manual-ack.txt"
  mkdir -p "$bin_dir" "$session_home" "$ack_dir"
  setup_stub_run_plan_support "$workspace"

  plan_file="$workspace/PLAN.md"
  cat <<'EOF' > "$plan_file"
# Manual gate test
- [ ] Ask the user to approve deployment
EOF

  todo_hash="$(plan_todo_hash 'Ask the user to approve deployment')"
  cat <<EOF > "$ack_file"
plan_key=$ack_ns
todo_hash=$todo_hash
todo_line=2
todo_ordinal=1
todo_class=manual_gate
approved_at=2026-04-28T00:00:00Z
reason=operator approved release
EOF

  cat <<'EOF' > "$bin_dir/cursor-agent"
#!/usr/bin/env bash
printf '%s\n' "ack received"
python3 - <<'PY'
import os
from pathlib import Path

path = Path(os.environ["STUB_PLAN_PATH"])
text = path.read_text()
path.write_text(text.replace("- [ ]", "- [x]", 1))
PY
exit 0
EOF
  chmod +x "$bin_dir/cursor-agent"

  run bash -c '
    set -euo pipefail
    cd "$1"
    export PATH="$2:$PATH"
    export RALPH_USAGE_RISKS_ACKNOWLEDGED=1
    export RALPH_PLAN_SESSION_HOME="$5"
    export STUB_PLAN_PATH="$4"
    "$3" --runtime cursor --plan PLAN.md --non-interactive --model stub-model
  ' _ "$workspace" "$bin_dir" "$RUN_PLAN_SH" "$plan_file" "$session_home"

  [ "$status" -eq 0 ]
  grep -Fq -- "- [x] Ask the user to approve deployment" "$plan_file"
  [ ! -f "$ack_file" ]

  ralph_test_rm_workspace "$workspace"
}

@test "run-plan accepts manual TODO completion without autonomous-evidence gate" {
  [ -f "$RUN_PLAN_SH" ] || skip "bundle run-plan missing"

  local workspace plan_file bin_dir session_home
  workspace="$(mktemp -d)"
  bin_dir="$workspace/bin"
  session_home="$workspace/.sessions"
  mkdir -p "$bin_dir" "$session_home"
  setup_stub_run_plan_support "$workspace"

  plan_file="$workspace/PLAN.md"
  cat <<'EOF' > "$plan_file"
# Manual gate failure test
- [ ] Ask the user to approve deployment
EOF

  cat <<'EOF' > "$bin_dir/cursor-agent"
#!/usr/bin/env bash
printf '%s\n' "retrying completion with no evidence"
python3 - <<'PY'
import os
from pathlib import Path

path = Path(os.environ["STUB_PLAN_PATH"])
text = path.read_text()
path.write_text(text.replace("- [ ]", "- [x]", 1))
PY
exit 0
EOF
  chmod +x "$bin_dir/cursor-agent"

  run bash -c '
    set -euo pipefail
    cd "$1"
    export PATH="$2:$PATH"
    export RALPH_USAGE_RISKS_ACKNOWLEDGED=1
    export RALPH_PLAN_SESSION_HOME="$5"
    export RALPH_HUMAN_OFFLINE_EXIT=1
    export CURSOR_PLAN_MAX_ITER=1
    export STUB_PLAN_PATH="$4"
    "$3" --runtime cursor --plan PLAN.md --non-interactive --model stub-model
  ' _ "$workspace" "$bin_dir" "$RUN_PLAN_SH" "$plan_file" "$session_home"

  [ "$status" -eq 0 ]
  grep -Fq -- "- [x] Ask the user to approve deployment" "$plan_file"
  [ ! -f "$session_home/PLAN/pending-human.txt" ]

  ralph_test_rm_workspace "$workspace"
}

@test "run-plan does not reopen completed manual TODOs for operator prompts" {
  [ -f "$RUN_PLAN_SH" ] || skip "bundle run-plan missing"

  local workspace plan_file bin_dir session_home
  workspace="$(mktemp -d)"
  bin_dir="$workspace/bin"
  session_home="$workspace/.sessions"
  mkdir -p "$bin_dir" "$session_home"
  setup_stub_run_plan_support "$workspace"

  plan_file="$workspace/PLAN.md"
  cat <<'EOF' > "$plan_file"
# Human gate test
- [ ] Ask the user to approve deployment
EOF

  cat <<'EOF' > "$bin_dir/cursor-agent"
#!/usr/bin/env bash
printf '%s\n' "marked complete; no further action"
python3 - <<'PY'
import os
from pathlib import Path

path = Path(os.environ["STUB_PLAN_PATH"])
text = path.read_text()
path.write_text(text.replace("- [ ]", "- [x]", 1))
PY
exit 0
EOF
  chmod +x "$bin_dir/cursor-agent"

  run bash -c '
    set -euo pipefail
    cd "$1"
    export PATH="$2:$PATH"
    export RALPH_USAGE_RISKS_ACKNOWLEDGED=1
    export RALPH_PLAN_SESSION_HOME="$5"
    export RALPH_PLAN_REQUIRE_HUMAN_PROMPT=1
    export RALPH_HUMAN_OFFLINE_EXIT=1
    export CURSOR_PLAN_MAX_ITER=1
    export STUB_PLAN_PATH="$4"
    "$3" --runtime cursor --plan PLAN.md --non-interactive --model stub-model
  ' _ "$workspace" "$bin_dir" "$RUN_PLAN_SH" "$plan_file" "$session_home"

  [ "$status" -eq 0 ]
  grep -Fq -- "- [x] Ask the user to approve deployment" "$plan_file"
  [ ! -f "$session_home/PLAN/pending-human.txt" ]

  ralph_test_rm_workspace "$workspace"
}

@test "long-plan resume hint fires once per run" {
  [ -f "$RUN_PLAN_SH" ] || skip "bundle run-plan missing"

  local workspace plan_file bin_dir cursor_record session_home
  workspace="$(mktemp -d)"
  bin_dir="$workspace/bin"
  mkdir -p "$bin_dir"

  plan_file="$workspace/PLAN.md"
  cat <<'EOF' > "$plan_file"
# Long plan hint test
- [ ] complete first task
- [ ] complete second task
- [ ] complete third task
EOF

  local select_model_dir
  select_model_dir="$workspace/.cursor/ralph"
  mkdir -p "$select_model_dir"
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

  local agent_tool_dir
  agent_tool_dir="$workspace/.ralph"
  mkdir -p "$agent_tool_dir"
  cat <<'EOF' > "$agent_tool_dir/agent-config-tool.sh"
#!/usr/bin/env bash
exit 0
EOF
  chmod +x "$agent_tool_dir/agent-config-tool.sh"

  cursor_record="$workspace/cursor.args"
  cat <<EOF > "$bin_dir/cursor-agent"
#!/usr/bin/env bash
printf '%s\n' "\$@" >>"$cursor_record"
python3 - <<'PY'
import os
from pathlib import Path
path = Path(os.environ["STUB_PLAN_PATH"])
text = path.read_text()
path.write_text(text.replace("- [ ]", "- [x]", 1))
PY
exit 0
EOF
  chmod +x "$bin_dir/cursor-agent"

  session_home="$workspace/.sessions"
  mkdir -p "$session_home"

  run bash -c '
    set -euo pipefail
    cd "$1"
    export PATH="$2:$PATH"
    export RALPH_USAGE_RISKS_ACKNOWLEDGED=1
    export RALPH_PLAN_SESSION_HOME="$5"
    export RALPH_PLAN_SESSION_STRATEGY=fresh
    export RALPH_PLAN_CLI_RESUME=0
    export RALPH_PLAN_RESUME_HINT_THRESHOLD=1
    export STUB_PLAN_PATH="$4"
    "$3" --runtime cursor --plan PLAN.md --non-interactive --model stub-model
  ' _ "$workspace" "$bin_dir" "$RUN_PLAN_SH" "$plan_file" "$session_home"

  [ "$status" -eq 0 ]
  local hint_count
  hint_count="$(printf '%s\n' "$output" | grep -F "Set RALPH_PLAN_CLI_RESUME=1" | wc -l | tr -d ' ' || true)"
  [ "$hint_count" = "1" ]
  grep -Fq -- "- [x] complete third task" "$plan_file"

  ralph_test_rm_workspace "$workspace"
}

@test "bundle run-plan.sh is valid bash" {
  [ -f "$RUN_PLAN_SH" ] || skip "bundle run-plan missing"
  run bash -n "$RUN_PLAN_SH"
  [ "$status" -eq 0 ]
}

@test "run-plan sources menu-select helper for prebuilt agent TTY menu" {
  [ -f "$RUN_PLAN_SH" ] || skip "bundle run-plan missing"
  grep -Fq 'bash-lib/menu-select.sh' "$RUN_PLAN_SH"
}

@test "menu-select library defines ralph_menu_select" {
  local lib="$REPO_ROOT/bundle/.ralph/bash-lib/menu-select.sh"
  [ -f "$lib" ] || skip "menu-select lib missing"
  run bash -c 'source "$1"; type -t ralph_menu_select' _ "$lib"
  [ "$status" -eq 0 ]
  [[ "$output" == function ]]
}

@test "run-plan fails early when shared layout is missing" {
  [ -f "$RUN_PLAN_SH" ] || skip "bundle run-plan missing"
  local bad_layout
  bad_layout="$(mktemp -d)"
  cp "$RUN_PLAN_SH" "$bad_layout/run-plan.sh"
  chmod +x "$bad_layout/run-plan.sh"

  run bash "$bad_layout/run-plan.sh" --runtime cursor --plan "$REPO_ROOT/PLAN.md"
  [ "$status" -ne 0 ]
  [[ "$output" == *"bash-lib/run-plan/run-plan-runtime.sh: No such file or directory"* ]]

  rm -rf "$bad_layout"
}

@test "timeout defaults to 30m when not specified via --timeout" {
  [ -f "$RUN_PLAN_SH" ] || skip "bundle run-plan missing"

  local workspace plan_file bin_dir session_home
  workspace="$(mktemp -d)"
  bin_dir="$workspace/bin"
  mkdir -p "$bin_dir"
  session_home="$workspace/.sessions"
  mkdir -p "$session_home"

  plan_file="$workspace/PLAN.md"
  cat <<'EOF' > "$plan_file"
# Timeout default test
- [x] verify timeout defaulting
EOF

  local select_model_dir
  select_model_dir="$workspace/.cursor/ralph"
  mkdir -p "$select_model_dir"
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

  local agent_tool_dir
  agent_tool_dir="$workspace/.ralph"
  mkdir -p "$agent_tool_dir"
  cat <<'EOF' > "$agent_tool_dir/agent-config-tool.sh"
#!/usr/bin/env bash
exit 0
EOF
  chmod +x "$agent_tool_dir/agent-config-tool.sh"

  cat <<EOF > "$bin_dir/cursor-agent"
#!/usr/bin/env bash
exit 0
EOF
  chmod +x "$bin_dir/cursor-agent"

  run bash -c '
    set -euo pipefail
    cd "$1"
    export PATH="$2:$PATH"
    export RALPH_USAGE_RISKS_ACKNOWLEDGED=1
    export RALPH_PLAN_SESSION_HOME="$3"
    "$4" --runtime cursor --plan PLAN.md --non-interactive --model stub-model
    exit_code=$?

    # Check the log files for default timeout (1800s = 30m)
    found=0
    for log_file in "$1"/.ralph-workspace/logs/*/plan-runner-PLAN.log; do
      if [ -f "$log_file" ] && grep -q "1800s.*30m" "$log_file"; then
        found=1
        break
      fi
    done
    exit "$((1 - found))"
  ' _ "$workspace" "$bin_dir" "$session_home" "$RUN_PLAN_SH"

  [ "$status" -eq 0 ]
  ralph_test_rm_workspace "$workspace"
}
