#!/usr/bin/env bats

source "$BATS_TEST_DIRNAME/helper/load-lib.bash"

@test "orchestration wizard stage inputs can map earlier artifacts" {
  workspace="$(mktemp -d)"
  trap 'rm -rf "$workspace"' EXIT

  mkdir -p "$workspace/.cursor/agents/plan"
  cat <<'JSON' > "$workspace/.cursor/agents/plan/config.json"
{"model": "gpt-5.1"}
JSON

  mkdir -p "$workspace/.cursor/agents/qa"
  cat <<'JSON' > "$workspace/.cursor/agents/qa/config.json"
{"model": "gpt-5.1"}
JSON

  printf '%s' $'Test Pipeline\n\n\nplan,qa\n\n\n\n1\n\n\n\n1\ny\nnone\nplan\n\n' > "$workspace/wizard-input.txt"

  run bash -c "cd '$workspace' && cat wizard-input.txt | '$REPO_ROOT'/.ralph/orchestration-wizard.sh"
  [ "$status" -eq 0 ]

  orch_file="$workspace/.agents/orchestration-plans/test-pipeline/test-pipeline.orch.json"
  [ -f "$orch_file" ]

  run jq -r '.stages[1].id' "$orch_file"
  [ "$status" -eq 0 ]
  [ "$output" = "qa" ]

  run jq -r '.stages[1].inputArtifacts[0].path' "$orch_file"
  [ "$status" -eq 0 ]
  [ "$output" = ".agents/artifacts/test-pipeline/plan.md" ]
}
