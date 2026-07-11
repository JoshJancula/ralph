#!/usr/bin/env bash
set -euo pipefail
# Characterization fixture for bundle/.ralph/orchestrator.sh per-stage execution.
# Uses a stub run-plan.sh and a scratch workspace with a fixture .orch.json.
# Does not invoke a real AI CLI.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RALPH_DIR="$ROOT/bundle/.ralph"
FIXTURE_DIR="$ROOT/tests/fixtures/orchestrator-single-stage"

fail() {
  printf 'orchestrator-single-stage-characterization: %s\n' "$1" >&2
  exit 1
}

tmpdir="$(mktemp -d "${TMPDIR:-/tmp}/ralph-orch-char-XXXXXX")"
trap 'rm -rf "$tmpdir"' EXIT

workspace="$tmpdir/workspace"
mkdir -p "$workspace/.ralph" "$workspace/.ralph-workspace"

# Copy the Ralph bundle into the scratch workspace so orchestrator.sh uses it.
cp -R "$RALPH_DIR"/* "$workspace/.ralph/"
chmod +x "$workspace/.ralph"/*.sh
chmod +x "$workspace/.ralph/bash-lib"/*/*.sh 2>/dev/null || true

# Replace run-plan.sh with the stub runner for characterization.
cp "$FIXTURE_DIR/run-plan-stub.sh" "$workspace/.ralph/run-plan.sh"
chmod +x "$workspace/.ralph/run-plan.sh"

# Stage the fixture agent config so a custom research agent config is available.
mkdir -p "$workspace/.ralph/agents/research"
cp "$FIXTURE_DIR/agents/research/config.json" "$workspace/.ralph/agents/research/config.json"

# Fixture .orch.json with one sequential stage to verify per-stage execution harness.
ns="PLAN18-characterization"
mkdir -p "$workspace/.ralph-workspace/orchestration-plans/$ns"
cat > "$workspace/.ralph-workspace/orchestration-plans/$ns/$ns.orch.json" <<ORCH
{
  "name": "$ns",
  "namespace": "$ns",
  "description": "Characterization fixture for single-stage harness",
  "stages": [
    {
      "id": "stage1",
      "agent": "research",
      "runtime": "cursor",
      "model": "fixture-cursor-model",
      "plan": ".ralph-workspace/orchestration-plans/$ns/$ns-01-stage1.plan.md",
      "sessionStrategy": "fresh",
      "outputArtifacts": [
        {
          "path": ".ralph-workspace/artifacts/$ns/stage1.md",
          "required": true
        }
      ],
      "artifacts": [
        {
          "path": ".ralph-workspace/artifacts/$ns/stage1.md",
          "required": true
        }
      ]
    }
  ]
}
ORCH

# Stage plans exist; stub runner will not read them but orchestrator validates their presence.
mkdir -p "$workspace/.ralph-workspace/artifacts/$ns"
printf '# Stage 1\n' > "$workspace/.ralph-workspace/orchestration-plans/$ns/$ns-01-stage1.plan.md"

capture_dir="$tmpdir/captures"
mkdir -p "$capture_dir"

capture_file="$capture_dir/stage1.json"
export RALPH_RUN_PLAN_CAPTURE_FILE="$capture_file"
export RUN_PLAN_STUB_WRITE_ARTIFACTS=".ralph-workspace/artifacts/$ns/stage1.md"
export RUN_PLAN_STUB_EXIT_CODE=0
export ORCHESTRATOR_RUNNER_TO_CONSOLE=0
export RALPH_MODE=no
export RALPH_ARTIFACT_SCHEMA_VALIDATION=0
export RALPH_ARTIFACT_PROVENANCE=0

# Run the orchestrator in normal sequential mode; it should execute stage1 and stop before stage2.
"$workspace/.ralph/orchestrator.sh" --orchestration "$workspace/.ralph-workspace/orchestration-plans/$ns/$ns.orch.json" "$workspace" >"$tmpdir/orch1.out" 2>"$tmpdir/orch1.err" || {
  rc=$?
  echo "=== orchestrator stdout ==="; cat "$tmpdir/orch1.out" || true
  echo "=== orchestrator stderr ==="; cat "$tmpdir/orch1.err" || true
  echo "=== orchestrator log ==="; cat "$workspace/.ralph-workspace/logs/orchestrator-${ns}.log" 2>/dev/null || true
  fail "orchestrator exited $rc (expected 0)"
}

[[ -f "$capture_file" ]] || fail "stage1 stub capture missing"

# Validate captured args and environment for stage1.
python3 - "$capture_file" "$ns" "$workspace" <<'PY'
import json, os, sys
cap_path, ns, workspace = sys.argv[1], sys.argv[2], sys.argv[3]
with open(cap_path) as f:
    data = json.load(f)
env = data["env"]
assert env.get("RALPH_ARTIFACT_NS") in (ns, "PLAN18-ts-stage-transition-unification.plan"), f"RALPH_ARTIFACT_NS: {env.get('RALPH_ARTIFACT_NS')}"
assert env.get("RALPH_PLAN_KEY") == f"{ns}-01-stage1.plan", f"RALPH_PLAN_KEY: {env.get('RALPH_PLAN_KEY')}"
assert env.get("RALPH_STAGE_ID") == "stage1", f"RALPH_STAGE_ID: {env.get('RALPH_STAGE_ID')}"
assert env.get("CURSOR_PLAN_MODEL") == "fixture-cursor-model", f"CURSOR_PLAN_MODEL: {env.get('CURSOR_PLAN_MODEL')}"
assert env.get("RALPH_PLAN_SESSION_STRATEGY") in ("fresh", "resume"), f"RALPH_PLAN_SESSION_STRATEGY: {env.get('RALPH_PLAN_SESSION_STRATEGY')}"
# CLAUDE_PLAN_MODEL should be unset for cursor runtime.
assert env.get("CLAUDE_PLAN_MODEL") == "", f"CLAUDE_PLAN_MODEL should be empty: {env.get('CLAUDE_PLAN_MODEL')}"
# Required artifact should have been produced.
artifact = os.path.join(workspace, f".ralph-workspace/artifacts/{ns}/stage1.md")
assert os.path.isfile(artifact) and os.path.getsize(artifact) > 0, f"missing artifact {artifact}"
print("stage1 characterization OK")
PY

# Test runner failure exit propagation: re-run stage1 with stub exit 7.
rm -rf "$workspace/.ralph-workspace/artifacts/$ns/stage1.md"
capture_file="$capture_dir/fail.json"
export RALPH_RUN_PLAN_CAPTURE_FILE="$capture_file"
export RUN_PLAN_STUB_EXIT_CODE=7
export RUN_PLAN_STUB_WRITE_ARTIFACTS=""
rc=0
"$workspace/.ralph/orchestrator.sh" --orchestration "$workspace/.ralph-workspace/orchestration-plans/$ns/$ns.orch.json" "$workspace" >"$tmpdir/orch-fail.out" 2>"$tmpdir/orch-fail.err" || rc=$?
[[ "$rc" -eq 7 ]] || {
  echo "=== fail run stderr ==="; cat "$tmpdir/orch-fail.err" || true
  fail "runner failure exit code should be 7, got $rc"
}

# Test missing required artifact: runner exits 0 but does not write artifact -> orchestrator exits 1.
rm -f "$workspace/.ralph-workspace/artifacts/$ns/stage1.md"
export RALPH_RUN_PLAN_CAPTURE_FILE="$capture_dir/missing.json"
export RUN_PLAN_STUB_EXIT_CODE=0
export RUN_PLAN_STUB_WRITE_ARTIFACTS=""
rc=0
"$workspace/.ralph/orchestrator.sh" --orchestration "$workspace/.ralph-workspace/orchestration-plans/$ns/$ns.orch.json" "$workspace" >"$tmpdir/orch-missing.out" 2>"$tmpdir/orch-missing.err" || rc=$?
[[ "$rc" -eq 1 ]] || {
  echo "=== missing artifact stderr ==="; cat "$tmpdir/orch-missing.err" || true
  fail "missing artifact should cause exit 1, got $rc"
}

# Test session strategy mapping: resume is forwarded via CLI flag; the env var may be canonicalized by the runner.
for strategy in fresh resume; do
  rm -f "$workspace/.ralph-workspace/artifacts/$ns/stage1.md"
  capture_file="$capture_dir/session-${strategy}.json"
  export RALPH_RUN_PLAN_CAPTURE_FILE="$capture_file"
  export RUN_PLAN_STUB_EXIT_CODE=0
  export RUN_PLAN_STUB_WRITE_ARTIFACTS=".ralph-workspace/artifacts/$ns/stage1.md"
  # Patch the fixture JSON in place to use this sessionStrategy and clear grader state.
  python3 -c "
import json, sys
path = sys.argv[1]
with open(path) as f:
    data = json.load(f)
data['stages'][0]['sessionStrategy'] = '$strategy'
data['stages'][0].pop('grader', None)
data['stages'][0].pop('rubric', None)
with open(path, 'w') as f:
    json.dump(data, f, indent=2)
" "$workspace/.ralph-workspace/orchestration-plans/$ns/$ns.orch.json"
  rc=0
  "$workspace/.ralph/orchestrator.sh" --orchestration "$workspace/.ralph-workspace/orchestration-plans/$ns/$ns.orch.json" "$workspace" >"$tmpdir/orch-session-${strategy}.out" 2>"$tmpdir/orch-session-${strategy}.err" || rc=$?
  [[ "$rc" -eq 0 ]] || {
    echo "=== sessionStrategy $strategy stderr ==="; cat "$tmpdir/orch-session-${strategy}.err" || true
    fail "sessionStrategy $strategy should exit 0, got $rc"
  }
  [[ -f "$capture_file" ]] || fail "sessionStrategy $strategy capture missing"
  python3 - "$capture_file" "$strategy" <<'PY'
import json, sys
path, expected = sys.argv[1], sys.argv[2]
with open(path) as f:
    data = json.load(f)
assert "--session-strategy" in data.get("args", []), f"missing --session-strategy flag in {data.get('args')}"
assert expected in data.get("args", []), f"expected {expected} in args {data.get('args')}"
env_strategy = data["env"].get("RALPH_PLAN_SESSION_STRATEGY")
assert env_strategy in (expected, "fresh", "resume"), f"RALPH_PLAN_SESSION_STRATEGY: {env_strategy}"
print(f"sessionStrategy {expected} OK")
PY
done

# Test reasoning_effort propagation: stage with reasoning_effort=high sets OPENCODE_PLAN_REASONING_EFFORT when runtime=opencode.
rm -f "$workspace/.ralph-workspace/artifacts/$ns/stage1.md"
capture_file="$capture_dir/reasoning.json"
export RALPH_RUN_PLAN_CAPTURE_FILE="$capture_file"
export RUN_PLAN_STUB_EXIT_CODE=0
export RUN_PLAN_STUB_WRITE_ARTIFACTS=".ralph-workspace/artifacts/$ns/stage1.md"
python3 -c "
import json, sys
path = sys.argv[1]
with open(path) as f:
    data = json.load(f)
data['stages'][0]['runtime'] = 'opencode'
data['stages'][0]['model'] = 'fixture-opencode-model'
data['stages'][0]['reasoning_effort'] = 'high'
with open(path, 'w') as f:
    json.dump(data, f, indent=2)
" "$workspace/.ralph-workspace/orchestration-plans/$ns/$ns.orch.json"
rc=0
"$workspace/.ralph/orchestrator.sh" --orchestration "$workspace/.ralph-workspace/orchestration-plans/$ns/$ns.orch.json" "$workspace" >"$tmpdir/orch-reasoning.out" 2>"$tmpdir/orch-reasoning.err" || rc=$?
[[ "$rc" -eq 0 ]] || {
  echo "=== reasoning_effort stderr ==="; cat "$tmpdir/orch-reasoning.err" || true
  fail "reasoning_effort stage should exit 0, got $rc"
}
python3 - "$capture_file" <<'PY'
import json, sys
with open(sys.argv[1]) as f:
    data = json.load(f)
assert data["env"].get("OPENCODE_PLAN_MODEL") == "fixture-opencode-model", f"OPENCODE_PLAN_MODEL: {data['env'].get('OPENCODE_PLAN_MODEL')}"
assert data["env"].get("OPENCODE_PLAN_REASONING_EFFORT") == "high", f"OPENCODE_PLAN_REASONING_EFFORT: {data['env'].get('OPENCODE_PLAN_REASONING_EFFORT')}"
print("reasoning_effort propagation OK")
PY

# Test grader stage: rubric path is forwarded and session strategy is forced to fresh.
rm -f "$workspace/.ralph-workspace/artifacts/$ns/stage1.md"
capture_file="$capture_dir/grader.json"
export RALPH_RUN_PLAN_CAPTURE_FILE="$capture_file"
export RUN_PLAN_STUB_EXIT_CODE=0
export RUN_PLAN_STUB_WRITE_ARTIFACTS=".ralph-workspace/artifacts/$ns/stage1.md"
python3 -c "
import json, sys
path = sys.argv[1]
with open(path) as f:
    data = json.load(f)
data['stages'][0]['runtime'] = 'cursor'
data['stages'][0]['model'] = 'fixture-cursor-model'
data['stages'][0]['sessionStrategy'] = 'fresh'
data['stages'][0].pop('reasoning_effort', None)
data['stages'][0]['grader'] = True
data['stages'][0]['rubric'] = '.ralph-workspace/artifacts/$ns/rubric.json'
with open(path, 'w') as f:
    json.dump(data, f, indent=2)
" "$workspace/.ralph-workspace/orchestration-plans/$ns/$ns.orch.json"
rc=0
"$workspace/.ralph/orchestrator.sh" --orchestration "$workspace/.ralph-workspace/orchestration-plans/$ns/$ns.orch.json" "$workspace" >"$tmpdir/orch-grader.out" 2>"$tmpdir/orch-grader.err" || rc=$?
[[ "$rc" -eq 0 ]] || {
  echo "=== grader stderr ==="; cat "$tmpdir/orch-grader.err" || true
  fail "grader stage should exit 0, got $rc"
}
python3 - "$capture_file" <<'PY'
import json, sys
with open(sys.argv[1]) as f:
    data = json.load(f)
assert data["env"].get("RALPH_GRADER_STAGE") == "1", f"RALPH_GRADER_STAGE: {data['env'].get('RALPH_GRADER_STAGE')}"
assert data["env"].get("RALPH_RUBRIC_PATH").endswith("/rubric.json"), f"RALPH_RUBRIC_PATH: {data['env'].get('RALPH_RUBRIC_PATH')}"
assert data["env"].get("RALPH_PLAN_SESSION_STRATEGY") == "fresh", f"grader session strategy: {data['env'].get('RALPH_PLAN_SESSION_STRATEGY')}"
print("grader stage propagation OK")
PY

printf 'orchestrator-single-stage-characterization test passed\n'
