#!/usr/bin/env bats

source "$BATS_TEST_DIRNAME/helper/load-lib.bash"

setup() {
  temp_files=()
  VALIDATOR="$REPO_ROOT/scripts/validate-orchestration-schema.sh"
}

teardown() {
  for f in "${temp_files[@]}"; do
    [[ -f "$f" ]] && rm "$f"
  done
}

generate_orch() {
  local target="$1"
  cat <<'EOF' > "$target"
{
  "name": "schema-test",
  "namespace": "schema-test",
  "description": "schema validation test",
  "stages": [
    {
      "id": "stage-one",
      "runtime": "cursor",
      "agent": "architect",
      "plan": ".agents/orchestration-plans/schema-test/schema-test-01-stage-one.plan.md",
      "artifacts": [
        {
          "path": ".agents/artifacts/schema-test/stage-one.md",
          "required": true
        }
      ],
      "inputArtifacts": [
        {
          "path": ".agents/artifacts/schema-test/seed.md"
        }
      ],
      "loopControl": {
        "loopBackTo": "stage-one",
        "maxIterations": 1
      }
    }
  ]
}
EOF
}

@test "validator accepts valid orchestration schema" {
  local orch
  orch="$(mktemp)"
  temp_files+=("$orch")
  generate_orch "$orch"
  run "$VALIDATOR" "$orch"
  [ "$status" -eq 0 ]
}

@test "validator rejects plans with inputFromStages" {
  local orch
  orch="$(mktemp)"
  temp_files+=("$orch")
  cat <<'EOF' > "$orch"
{
  "name": "schema-test",
  "namespace": "schema-test",
  "description": "schema validation test",
  "stages": [
    {
      "id": "stage-two",
      "runtime": "cursor",
      "agent": "research",
      "plan": ".agents/orchestration-plans/schema-test/schema-test-02-stage-two.plan.md",
      "artifacts": [
        {
          "path": ".agents/artifacts/schema-test/stage-two.md"
        }
      ],
      "inputFromStages": [
        "stage-one"
      ]
    }
  ]
}
EOF
  run "$VALIDATOR" "$orch"
  [ "$status" -ne 0 ]
  [[ "$output" == *"schema validation failed"* ]]
}
