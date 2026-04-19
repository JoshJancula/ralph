#!/usr/bin/env bats

source "$BATS_TEST_DIRNAME/helper/load-lib.bash"

@test "orchestration wizard aborts on 'n' at summary prompt without creating files" {
  bundle_root="$(mktemp -d)"
  workspace="$(mktemp -d)"
  mkdir -p "$bundle_root/.ralph/bash-lib"
  mkdir -p "$workspace/.cursor/agents/research"
  cp "$REPO_ROOT/bundle/.ralph/orchestration-wizard.sh" "$bundle_root/.ralph/orchestration-wizard.sh"
  cp "$REPO_ROOT/bundle/.ralph/bash-lib/"*.sh "$bundle_root/.ralph/bash-lib/"
  cp "$REPO_ROOT/bundle/.ralph/plan.template" "$bundle_root/.ralph/plan.template"
  chmod +x "$bundle_root/.ralph/orchestration-wizard.sh"

  # Create agent config
  echo '{"model":"auto"}' > "$workspace/.cursor/agents/research/config.json"

  # Input: go through wizard, then 'n' at summary prompt to abort
  cat >"$workspace/input.txt" <<'EOF'
Demo Pipeline
demo

n
research


n


n


n


n

n
EOF

  wizard="$bundle_root/.ralph/orchestration-wizard.sh"
  run bash -c 'export LC_ALL=C LANG=C; cd "$1" && tr -d "\r" < "$3" | bash "$2"' bash "$workspace" "$wizard" "$workspace/input.txt"

  [ "$status" -eq 0 ]
  [ ! -d "$workspace/.ralph-workspace/orchestration-plans/demo" ]
  [ ! -d "$workspace/.ralph-workspace/artifacts/demo" ]
  [[ "$output" == *'aborted; no files created'* ]]

  rm -rf "$bundle_root" "$workspace"
}

@test "orchestration wizard creates files on 'y' at summary prompt" {
  bundle_root="$(mktemp -d)"
  workspace="$(mktemp -d)"
  mkdir -p "$bundle_root/.ralph/bash-lib"
  mkdir -p "$workspace/.cursor/agents/research"
  cp "$REPO_ROOT/bundle/.ralph/orchestration-wizard.sh" "$bundle_root/.ralph/orchestration-wizard.sh"
  cp "$REPO_ROOT/bundle/.ralph/bash-lib/"*.sh "$bundle_root/.ralph/bash-lib/"
  cp "$REPO_ROOT/bundle/.ralph/plan.template" "$bundle_root/.ralph/plan.template"
  chmod +x "$bundle_root/.ralph/orchestration-wizard.sh"

  # Create agent config
  echo '{"model":"auto"}' > "$workspace/.cursor/agents/research/config.json"

  # Input: go through wizard, then 'y' at summary prompt to confirm
  cat >"$workspace/input.txt" <<'EOF'
Demo Pipeline
demo

n
research


n


n


n


y

n
EOF

  wizard="$bundle_root/.ralph/orchestration-wizard.sh"
  run bash -c 'export LC_ALL=C LANG=C; cd "$1" && tr -d "\r" < "$3" | bash "$2"' bash "$workspace" "$wizard" "$workspace/input.txt"

  [ "$status" -eq 0 ]
  orch_file="$workspace/.ralph-workspace/orchestration-plans/demo/demo.orch.json"
  [ -f "$orch_file" ]
  grep -Fq -- '"research"' "$orch_file"
  grep -Fq -- '"namespace"' "$orch_file"

  rm -rf "$bundle_root" "$workspace"
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

  # Create agent configs
  echo '{"model":"auto"}' > "$workspace/.cursor/agents/research/config.json"
  echo '{"model":"auto"}' > "$workspace/.cursor/agents/implementation/config.json"

  # Input: configure 2 stages with parallelStages (both in wave 1)
  cat >"$workspace/input.txt" <<'EOF'
Demo Pipeline
demo

n
research,implementation


n


n


n


n

y
1,2

n

n

n

y
EOF

  wizard="$bundle_root/.ralph/orchestration-wizard.sh"
  run bash -c 'export LC_ALL=C LANG=C; cd "$1" && tr -d "\r" < "$3" | bash "$2"' bash "$workspace" "$wizard" "$workspace/input.txt"

  [ "$status" -eq 0 ]
  orch_file="$workspace/.ralph-workspace/orchestration-plans/demo/demo.orch.json"
  [ -f "$orch_file" ]
  grep -Fq -- '"parallelStages"' "$orch_file"
  grep -Fq -- '"research"' "$orch_file"
  grep -Fq -- '"implementation"' "$orch_file"

  rm -rf "$bundle_root" "$workspace"
}
