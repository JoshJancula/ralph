#!/usr/bin/env bats

source "$BATS_TEST_DIRNAME/helper/load-lib.bash"

@test "orchestration wizard runs its sanitize helper path end to end" {
  bundle_root="$(mktemp -d)"
  workspace="$(mktemp -d)"
  mkdir -p "$bundle_root/.ralph/bash-lib"
  mkdir -p "$workspace/.cursor/agents/research"
  cp "$REPO_ROOT/bundle/.ralph/orchestration-wizard.sh" "$bundle_root/.ralph/orchestration-wizard.sh"
  cp "$REPO_ROOT/bundle/.ralph/bash-lib/"*.sh "$bundle_root/.ralph/bash-lib/"
  cp "$REPO_ROOT/bundle/.ralph/plan.template" "$bundle_root/.ralph/plan.template"
  chmod +x "$bundle_root/.ralph/orchestration-wizard.sh"
  cat >"$workspace/.cursor/agents/research/config.json" <<'JSON'
{"model":"auto"}
JSON
  cat >"$workspace/input.txt" <<'EOF'
Demo Pipeline
demo-pipeline

n
!!!
EOF

  wizard="$bundle_root/.ralph/orchestration-wizard.sh"
  run bash -c 'cd "$1" && bash "$2" < "$3"' bash "$workspace" "$wizard" "$workspace/input.txt"
  [ "$status" -ne 0 ]
  [[ "$output" == *'sanitizes to empty; skip'* ]]
  [[ "$output" != *"command not found"* ]]

  rm -rf "$bundle_root"
  rm -rf "$workspace"
  [ "$status" -ne 0 ]
}

@test "orchestration wizard can configure parallelStages" {
  bundle_root="$(mktemp -d)"
  workspace="$(mktemp -d)"
  mkdir -p "$bundle_root/.ralph/bash-lib"
  mkdir -p "$workspace/.cursor/agents/research"
  mkdir -p "$workspace/.cursor/agents/implementation"
  cp "$REPO_ROOT/bundle/.ralph/orchestration-wizard.sh" "$bundle_root/.ralph/orchestration-wizard.sh"
  cp "$REPO_ROOT/bundle/.ralph/bash-lib/"*.sh "$bundle_root/.ralph/bash-lib/"
  cp "$REPO_ROOT/bundle/.ralph/plan.template" "$bundle_root/.ralph/plan.template"
  chmod +x "$bundle_root/.ralph/orchestration-wizard.sh"
  cat >"$workspace/.cursor/agents/research/config.json" <<'JSON'
{"model":"auto"}
JSON
  cat >"$workspace/.cursor/agents/implementation/config.json" <<'JSON'
{"model":"auto"}
JSON

  cat >"$workspace/input.txt" <<'EOF'
Demo Pipeline
demo

n
research,implementation
1
2

1
n

1
1

1
n

y
research,implementation

n
n
EOF

  wizard="$bundle_root/.ralph/orchestration-wizard.sh"
  run bash -c 'cd "$1" && bash "$2" < "$3"' bash "$workspace" "$wizard" "$workspace/input.txt"
  [ "$status" -eq 0 ]

  orch_file="$workspace/.ralph-workspace/orchestration-plans/demo/demo.orch.json"
  [ -f "$orch_file" ]
  grep -Fq -- '"parallelStages"' "$orch_file"
  grep -Fq -- '"research,implementation"' "$orch_file"

  rm -rf "$bundle_root"
  rm -rf "$workspace"
}
