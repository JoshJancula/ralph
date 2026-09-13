#!/usr/bin/env bats

source "$BATS_TEST_DIRNAME/../helper/load-lib.bash"

setup() {
  temp_files=()
  VALIDATOR="$REPO_ROOT/scripts/validate-orchestration-schema.sh"
}

teardown() {
  local f
  for f in "${temp_files[@]+"${temp_files[@]}"}"; do
    [[ -n "$f" && -f "$f" ]] || continue
    rm -f "$f" || true
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
      "plan": ".ralph-workspace/orchestration-plans/schema-test/schema-test-01-stage-one.plan.md",
      "mcpProxyPolicy": "readonly",
      "artifacts": [
        {
          "path": ".ralph-workspace/artifacts/schema-test/stage-one.md",
          "required": true
        }
      ],
      "inputArtifacts": [
        {
          "path": ".ralph-workspace/artifacts/schema-test/seed.md"
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
      "plan": ".ralph-workspace/orchestration-plans/schema-test/schema-test-02-stage-two.plan.md",
      "artifacts": [
        {
          "path": ".ralph-workspace/artifacts/schema-test/stage-two.md"
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

@test "validator rejects non-string mcpProxyPolicy values" {
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
      "id": "stage-one",
      "runtime": "cursor",
      "plan": ".ralph-workspace/orchestration-plans/schema-test/schema-test-01-stage-one.plan.md",
      "mcpProxyPolicy": 123,
      "artifacts": [
        {
          "path": ".ralph-workspace/artifacts/schema-test/stage-one.md"
        }
      ]
    }
  ]
}
EOF
  run "$VALIDATOR" "$orch"
  [ "$status" -ne 0 ]
  [[ "$output" == *"schema validation failed"* ]]
}

@test "validator accepts valid parallelStages schema" {
  local orch
  orch="$(mktemp)"
  temp_files+=("$orch")
  cat <<'EOF' > "$orch"
{
  "name": "schema-test",
  "namespace": "schema-test",
  "description": "schema validation test",
  "parallelStages": [
    "stage-one, stage-two",
    "stage-three"
  ],
  "stages": [
    {
      "id": "stage-one",
      "runtime": "cursor",
      "plan": ".ralph-workspace/orchestration-plans/schema-test/schema-test-01-stage-one.plan.md",
      "artifacts": [
        {
          "path": ".ralph-workspace/artifacts/schema-test/stage-one.md"
        }
      ]
    },
    {
      "id": "stage-two",
      "runtime": "cursor",
      "plan": ".ralph-workspace/orchestration-plans/schema-test/schema-test-02-stage-two.plan.md",
      "artifacts": [
        {
          "path": ".ralph-workspace/artifacts/schema-test/stage-two.md"
        }
      ]
    },
    {
      "id": "stage-three",
      "runtime": "cursor",
      "plan": ".ralph-workspace/orchestration-plans/schema-test/schema-test-03-stage-three.plan.md",
      "artifacts": [
        {
          "path": ".ralph-workspace/artifacts/schema-test/stage-three.md"
        }
      ]
    }
  ]
}
EOF
  run "$VALIDATOR" "$orch"
  [ "$status" -eq 0 ]
}

@test "validator rejects malformed parallelStages entries" {
  local orch
  orch="$(mktemp)"
  temp_files+=("$orch")
  cat <<'EOF' > "$orch"
{
  "name": "schema-test",
  "namespace": "schema-test",
  "description": "schema validation test",
  "parallelStages": [
    123
  ],
  "stages": [
    {
      "id": "stage-one",
      "runtime": "cursor",
      "plan": ".ralph-workspace/orchestration-plans/schema-test/schema-test-01-stage-one.plan.md",
      "artifacts": [
        {
          "path": ".ralph-workspace/artifacts/schema-test/stage-one.md"
        }
      ]
    }
  ]
}
EOF
  run "$VALIDATOR" "$orch"
  [ "$status" -ne 0 ]
  [[ "$output" == *"schema validation failed"* ]]
}

@test "validator rejects parallelStages with unknown stage ids" {
  local orch
  orch="$(mktemp)"
  temp_files+=("$orch")
  cat <<'EOF' > "$orch"
{
  "name": "schema-test",
  "namespace": "schema-test",
  "description": "schema validation test",
  "parallelStages": [
    "stage-one, stage-missing"
  ],
  "stages": [
    {
      "id": "stage-one",
      "runtime": "cursor",
      "plan": ".ralph-workspace/orchestration-plans/schema-test/schema-test-01-stage-one.plan.md",
      "artifacts": [
        {
          "path": ".ralph-workspace/artifacts/schema-test/stage-one.md"
        }
      ]
    }
  ]
}
EOF
  run "$VALIDATOR" "$orch"
  [ "$status" -ne 0 ]
  [[ "$output" == *"schema validation failed"* ]]
}

@test "validator rejects duplicate stage ids across parallel waves" {
  local orch
  orch="$(mktemp)"
  temp_files+=("$orch")
  cat <<'EOF' > "$orch"
{
  "name": "schema-test",
  "namespace": "schema-test",
  "description": "schema validation test",
  "parallelStages": [
    "stage-one, stage-two",
    "stage-two, stage-three"
  ],
  "stages": [
    {
      "id": "stage-one",
      "runtime": "cursor",
      "plan": ".ralph-workspace/orchestration-plans/schema-test/schema-test-01-stage-one.plan.md",
      "artifacts": [
        {
          "path": ".ralph-workspace/artifacts/schema-test/stage-one.md"
        }
      ]
    },
    {
      "id": "stage-two",
      "runtime": "cursor",
      "plan": ".ralph-workspace/orchestration-plans/schema-test/schema-test-02-stage-two.plan.md",
      "artifacts": [
        {
          "path": ".ralph-workspace/artifacts/schema-test/stage-two.md"
        }
      ]
    },
    {
      "id": "stage-three",
      "runtime": "cursor",
      "plan": ".ralph-workspace/orchestration-plans/schema-test/schema-test-03-stage-three.plan.md",
      "artifacts": [
        {
          "path": ".ralph-workspace/artifacts/schema-test/stage-three.md"
        }
      ]
    }
  ]
}
EOF
  run "$VALIDATOR" "$orch"
  [ "$status" -ne 0 ]
  [[ "$output" == *"schema validation failed"* ]]
}

@test "validator rejects parallelStages missing stage coverage" {
  local orch
  orch="$(mktemp)"
  temp_files+=("$orch")
  cat <<'EOF' > "$orch"
{
  "name": "schema-test",
  "namespace": "schema-test",
  "description": "schema validation test",
  "parallelStages": [
    "stage-one"
  ],
  "stages": [
    {
      "id": "stage-one",
      "runtime": "cursor",
      "plan": ".ralph-workspace/orchestration-plans/schema-test/schema-test-01-stage-one.plan.md",
      "artifacts": [
        {
          "path": ".ralph-workspace/artifacts/schema-test/stage-one.md"
        }
      ]
    },
    {
      "id": "stage-two",
      "runtime": "cursor",
      "plan": ".ralph-workspace/orchestration-plans/schema-test/schema-test-02-stage-two.plan.md",
      "artifacts": [
        {
          "path": ".ralph-workspace/artifacts/schema-test/stage-two.md"
        }
      ]
    }
  ]
}
EOF
  run "$VALIDATOR" "$orch"
  [ "$status" -ne 0 ]
  [[ "$output" == *"schema validation failed"* ]]
}

@test "validator accepts parallelStages when loopControl is present" {
  local orch
  orch="$(mktemp)"
  temp_files+=("$orch")
  cat <<'EOF' > "$orch"
{
  "name": "schema-test",
  "namespace": "schema-test",
  "description": "schema validation test",
  "parallelStages": [
    "stage-one"
  ],
  "stages": [
    {
      "id": "stage-one",
      "runtime": "cursor",
      "plan": ".ralph-workspace/orchestration-plans/schema-test/schema-test-01-stage-one.plan.md",
      "artifacts": [
        {
          "path": ".ralph-workspace/artifacts/schema-test/stage-one.md"
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
  run "$VALIDATOR" "$orch"
  [ "$status" -eq 0 ]
}

@test "validator accepts valid handoff artifact with kind and to" {
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
      "id": "stage-one",
      "runtime": "cursor",
      "plan": ".ralph-workspace/orchestration-plans/schema-test/schema-test-01-stage-one.plan.md",
      "artifacts": [
        {
          "path": ".ralph-workspace/artifacts/schema-test/stage-one.md"
        }
      ]
    },
    {
      "id": "stage-two",
      "runtime": "cursor",
      "plan": ".ralph-workspace/orchestration-plans/schema-test/schema-test-02-stage-two.plan.md",
      "inputArtifacts": [
        {
          "path": ".ralph-workspace/artifacts/schema-test/stage-one.md"
        }
      ],
      "outputArtifacts": [
        {
          "path": ".ralph-workspace/artifacts/schema-test/handoff.md",
          "kind": "handoff",
          "to": "stage-three"
        }
      ],
      "artifacts": [
        {
          "path": ".ralph-workspace/artifacts/schema-test/stage-two.md"
        }
      ]
    },
    {
      "id": "stage-three",
      "runtime": "cursor",
      "plan": ".ralph-workspace/orchestration-plans/schema-test/schema-test-03-stage-three.plan.md",
      "artifacts": [
        {
          "path": ".ralph-workspace/artifacts/schema-test/stage-three.md"
        }
      ]
    }
  ]
}
EOF
  run "$VALIDATOR" "$orch"
  [ "$status" -eq 0 ]
}

@test "validator rejects handoff artifact without to field" {
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
      "id": "stage-one",
      "runtime": "cursor",
      "plan": ".ralph-workspace/orchestration-plans/schema-test/schema-test-01-stage-one.plan.md",
      "artifacts": [
        {
          "path": ".ralph-workspace/artifacts/schema-test/stage-one.md",
          "kind": "handoff"
        }
      ]
    }
  ]
}
EOF
  run "$VALIDATOR" "$orch"
  [ "$status" -ne 0 ]
  [[ "$output" == *"schema validation failed"* ]]
}

@test "validator rejects handoff artifact with invalid target stage" {
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
      "id": "stage-one",
      "runtime": "cursor",
      "plan": ".ralph-workspace/orchestration-plans/schema-test/schema-test-01-stage-one.plan.md",
      "artifacts": [
        {
          "path": ".ralph-workspace/artifacts/schema-test/stage-one.md",
          "kind": "handoff",
          "to": "nonexistent-stage"
        }
      ]
    }
  ]
}
EOF
  run "$VALIDATOR" "$orch"
  [ "$status" -ne 0 ]
  [[ "$output" == *"schema validation failed"* ]]
}

@test "validator rejects unknown kind values" {
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
      "id": "stage-one",
      "runtime": "cursor",
      "plan": ".ralph-workspace/orchestration-plans/schema-test/schema-test-01-stage-one.plan.md",
      "artifacts": [
        {
          "path": ".ralph-workspace/artifacts/schema-test/stage-one.md",
          "kind": "invalid-kind"
        }
      ]
    }
  ]
}
EOF
  run "$VALIDATOR" "$orch"
  [ "$status" -ne 0 ]
  [[ "$output" == *"schema validation failed"* ]]
}

@test "validator accepts all valid kind values without to" {
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
      "id": "stage-one",
      "runtime": "cursor",
      "plan": ".ralph-workspace/orchestration-plans/schema-test/schema-test-01-stage-one.plan.md",
      "outputArtifacts": [
        {
          "path": ".ralph-workspace/artifacts/schema-test/design.md",
          "kind": "design"
        },
        {
          "path": ".ralph-workspace/artifacts/schema-test/review.md",
          "kind": "review"
        },
        {
          "path": ".ralph-workspace/artifacts/schema-test/research.md",
          "kind": "research"
        },
        {
          "path": ".ralph-workspace/artifacts/schema-test/notes.md",
          "kind": "notes"
        }
      ],
      "artifacts": [
        {
          "path": ".ralph-workspace/artifacts/schema-test/stage-one.md"
        }
      ]
    }
  ]
}
EOF
  run "$VALIDATOR" "$orch"
  [ "$status" -eq 0 ]
}

@test "validator rejects handoff pointing to earlier stage in sequential mode" {
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
      "id": "stage-one",
      "runtime": "cursor",
      "plan": ".ralph-workspace/orchestration-plans/schema-test/schema-test-01-stage-one.plan.md",
      "artifacts": [
        {
          "path": ".ralph-workspace/artifacts/schema-test/stage-one.md"
        }
      ]
    },
    {
      "id": "stage-two",
      "runtime": "cursor",
      "plan": ".ralph-workspace/orchestration-plans/schema-test/schema-test-02-stage-two.plan.md",
      "outputArtifacts": [
        {
          "path": ".ralph-workspace/artifacts/schema-test/handoff.md",
          "kind": "handoff",
          "to": "stage-one"
        }
      ],
      "artifacts": [
        {
          "path": ".ralph-workspace/artifacts/schema-test/stage-two.md"
        }
      ]
    }
  ]
}
EOF
  run "$VALIDATOR" "$orch"
  [ "$status" -ne 0 ]
  [[ "$output" == *"schema validation failed"* ]]
}

@test "validator rejects handoff pointing to same stage in sequential mode" {
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
      "id": "stage-one",
      "runtime": "cursor",
      "plan": ".ralph-workspace/orchestration-plans/schema-test/schema-test-01-stage-one.plan.md",
      "outputArtifacts": [
        {
          "path": ".ralph-workspace/artifacts/schema-test/handoff.md",
          "kind": "handoff",
          "to": "stage-one"
        }
      ],
      "artifacts": [
        {
          "path": ".ralph-workspace/artifacts/schema-test/stage-one.md"
        }
      ]
    }
  ]
}
EOF
  run "$VALIDATOR" "$orch"
  [ "$status" -ne 0 ]
  [[ "$output" == *"schema validation failed"* ]]
}

@test "validator accepts valid handoff to later stage in sequential mode" {
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
      "id": "stage-one",
      "runtime": "cursor",
      "plan": ".ralph-workspace/orchestration-plans/schema-test/schema-test-01-stage-one.plan.md",
      "outputArtifacts": [
        {
          "path": ".ralph-workspace/artifacts/schema-test/handoff.md",
          "kind": "handoff",
          "to": "stage-three"
        }
      ],
      "artifacts": [
        {
          "path": ".ralph-workspace/artifacts/schema-test/stage-one.md"
        }
      ]
    },
    {
      "id": "stage-two",
      "runtime": "cursor",
      "plan": ".ralph-workspace/orchestration-plans/schema-test/schema-test-02-stage-two.plan.md",
      "artifacts": [
        {
          "path": ".ralph-workspace/artifacts/schema-test/stage-two.md"
        }
      ]
    },
    {
      "id": "stage-three",
      "runtime": "cursor",
      "plan": ".ralph-workspace/orchestration-plans/schema-test/schema-test-03-stage-three.plan.md",
      "artifacts": [
        {
          "path": ".ralph-workspace/artifacts/schema-test/stage-three.md"
        }
      ]
    }
  ]
}
EOF
  run "$VALIDATOR" "$orch"
  [ "$status" -eq 0 ]
}

@test "validator accepts valid handoff in parallel stages to later wave" {
  local orch
  orch="$(mktemp)"
  temp_files+=("$orch")
  cat <<'EOF' > "$orch"
{
  "name": "schema-test",
  "namespace": "schema-test",
  "description": "schema validation test",
  "parallelStages": [
    "stage-one, stage-two",
    "stage-three"
  ],
  "stages": [
    {
      "id": "stage-one",
      "runtime": "cursor",
      "plan": ".ralph-workspace/orchestration-plans/schema-test/schema-test-01-stage-one.plan.md",
      "outputArtifacts": [
        {
          "path": ".ralph-workspace/artifacts/schema-test/handoff.md",
          "kind": "handoff",
          "to": "stage-three"
        }
      ],
      "artifacts": [
        {
          "path": ".ralph-workspace/artifacts/schema-test/stage-one.md"
        }
      ]
    },
    {
      "id": "stage-two",
      "runtime": "cursor",
      "plan": ".ralph-workspace/orchestration-plans/schema-test/schema-test-02-stage-two.plan.md",
      "artifacts": [
        {
          "path": ".ralph-workspace/artifacts/schema-test/stage-two.md"
        }
      ]
    },
    {
      "id": "stage-three",
      "runtime": "cursor",
      "plan": ".ralph-workspace/orchestration-plans/schema-test/schema-test-03-stage-three.plan.md",
      "artifacts": [
        {
          "path": ".ralph-workspace/artifacts/schema-test/stage-three.md"
        }
      ]
    }
  ]
}
EOF
  run "$VALIDATOR" "$orch"
  [ "$status" -eq 0 ]
}

@test "validator rejects handoff in parallel stages to same wave" {
  local orch
  orch="$(mktemp)"
  temp_files+=("$orch")
  cat <<'EOF' > "$orch"
{
  "name": "schema-test",
  "namespace": "schema-test",
  "description": "schema validation test",
  "parallelStages": [
    "stage-one, stage-two",
    "stage-three"
  ],
  "stages": [
    {
      "id": "stage-one",
      "runtime": "cursor",
      "plan": ".ralph-workspace/orchestration-plans/schema-test/schema-test-01-stage-one.plan.md",
      "outputArtifacts": [
        {
          "path": ".ralph-workspace/artifacts/schema-test/handoff.md",
          "kind": "handoff",
          "to": "stage-two"
        }
      ],
      "artifacts": [
        {
          "path": ".ralph-workspace/artifacts/schema-test/stage-one.md"
        }
      ]
    },
    {
      "id": "stage-two",
      "runtime": "cursor",
      "plan": ".ralph-workspace/orchestration-plans/schema-test/schema-test-02-stage-two.plan.md",
      "artifacts": [
        {
          "path": ".ralph-workspace/artifacts/schema-test/stage-two.md"
        }
      ]
    },
    {
      "id": "stage-three",
      "runtime": "cursor",
      "plan": ".ralph-workspace/orchestration-plans/schema-test/schema-test-03-stage-three.plan.md",
      "artifacts": [
        {
          "path": ".ralph-workspace/artifacts/schema-test/stage-three.md"
        }
      ]
    }
  ]
}
EOF
  run "$VALIDATOR" "$orch"
  [ "$status" -ne 0 ]
  [[ "$output" == *"schema validation failed"* ]]
}

@test "validator rejects handoff in parallel stages to earlier wave" {
  local orch
  orch="$(mktemp)"
  temp_files+=("$orch")
  cat <<'EOF' > "$orch"
{
  "name": "schema-test",
  "namespace": "schema-test",
  "description": "schema validation test",
  "parallelStages": [
    "stage-one, stage-two",
    "stage-three"
  ],
  "stages": [
    {
      "id": "stage-one",
      "runtime": "cursor",
      "plan": ".ralph-workspace/orchestration-plans/schema-test/schema-test-01-stage-one.plan.md",
      "artifacts": [
        {
          "path": ".ralph-workspace/artifacts/schema-test/stage-one.md"
        }
      ]
    },
    {
      "id": "stage-two",
      "runtime": "cursor",
      "plan": ".ralph-workspace/orchestration-plans/schema-test/schema-test-02-stage-two.plan.md",
      "artifacts": [
        {
          "path": ".ralph-workspace/artifacts/schema-test/stage-two.md"
        }
      ]
    },
    {
      "id": "stage-three",
      "runtime": "cursor",
      "plan": ".ralph-workspace/orchestration-plans/schema-test/schema-test-03-stage-three.plan.md",
      "outputArtifacts": [
        {
          "path": ".ralph-workspace/artifacts/schema-test/handoff.md",
          "kind": "handoff",
          "to": "stage-one"
        }
      ],
      "artifacts": [
        {
          "path": ".ralph-workspace/artifacts/schema-test/stage-three.md"
        }
      ]
    }
  ]
}
EOF
  run "$VALIDATOR" "$orch"
  [ "$status" -ne 0 ]
  [[ "$output" == *"schema validation failed"* ]]
}

@test "validator accepts artifact without kind/to (backward compatibility)" {
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
      "id": "stage-one",
      "runtime": "cursor",
      "plan": ".ralph-workspace/orchestration-plans/schema-test/schema-test-01-stage-one.plan.md",
      "artifacts": [
        {
          "path": ".ralph-workspace/artifacts/schema-test/stage-one.md"
        }
      ]
    }
  ]
}
EOF
  run "$VALIDATOR" "$orch"
  [ "$status" -eq 0 ]
}

@test "validator accepts multiple artifact styles mixed (backward compatibility)" {
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
      "id": "stage-one",
      "runtime": "cursor",
      "plan": ".ralph-workspace/orchestration-plans/schema-test/schema-test-01-stage-one.plan.md",
      "outputArtifacts": [
        {
          "path": ".ralph-workspace/artifacts/schema-test/old-style.md"
        },
        {
          "path": ".ralph-workspace/artifacts/schema-test/with-required.md",
          "required": true
        },
        {
          "path": ".ralph-workspace/artifacts/schema-test/with-kind.md",
          "kind": "research"
        },
        {
          "path": ".ralph-workspace/artifacts/schema-test/with-description.md",
          "description": "A documented artifact"
        }
      ],
      "artifacts": [
        {
          "path": ".ralph-workspace/artifacts/schema-test/stage-one.md"
        }
      ]
    },
    {
      "id": "stage-two",
      "runtime": "cursor",
      "plan": ".ralph-workspace/orchestration-plans/schema-test/schema-test-02-stage-two.plan.md",
      "artifacts": [
        {
          "path": ".ralph-workspace/artifacts/schema-test/stage-two.md"
        }
      ]
    }
  ]
}
EOF
  run "$VALIDATOR" "$orch"
  [ "$status" -eq 0 ]
}

@test "validator accepts artifact schema field on outputArtifacts" {
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
      "id": "stage-one",
      "runtime": "cursor",
      "plan": ".ralph-workspace/orchestration-plans/schema-test/schema-test-01-stage-one.plan.md",
      "outputArtifacts": [
        {
          "path": ".ralph-workspace/artifacts/schema-test/verdict.json",
          "schema": "bundle/.ralph/schemas/evaluator-verdict.schema.json"
        }
      ],
      "artifacts": [
        {
          "path": ".ralph-workspace/artifacts/schema-test/stage-one.md"
        }
      ]
    }
  ]
}
EOF
  run "$VALIDATOR" "$orch" "$REPO_ROOT"
  [ "$status" -eq 0 ]
}

@test "validator rejects empty schema field" {
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
      "id": "stage-one",
      "runtime": "cursor",
      "plan": ".ralph-workspace/orchestration-plans/schema-test/schema-test-01-stage-one.plan.md",
      "artifacts": [
        {
          "path": ".ralph-workspace/artifacts/schema-test/stage-one.json",
          "schema": ""
        }
      ]
    }
  ]
}
EOF
  run "$VALIDATOR" "$orch"
  [ "$status" -ne 0 ]
  [[ "$output" == *"schema validation failed"* ]]
}

@test "validator rejects absolute artifact schema paths" {
  local orch schema_file
  orch="$(mktemp)"
  schema_file="$(mktemp)"
  temp_files+=("$orch" "$schema_file")
  printf '{"type":"object"}' > "$schema_file"
  cat <<EOF > "$orch"
{
  "name": "schema-test",
  "namespace": "schema-test",
  "description": "schema validation test",
  "stages": [
    {
      "id": "stage-one",
      "runtime": "cursor",
      "plan": ".ralph-workspace/orchestration-plans/schema-test/schema-test-01-stage-one.plan.md",
      "artifacts": [
        {
          "path": ".ralph-workspace/artifacts/schema-test/stage-one.json",
          "schema": "$schema_file"
        }
      ]
    }
  ]
}
EOF
  run "$VALIDATOR" "$orch" "$REPO_ROOT"
  [ "$status" -ne 0 ]
  [[ "$output" == *"schema validation failed"* ]]
}

@test "validator requires workspace when schema paths are declared" {
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
      "id": "stage-one",
      "runtime": "cursor",
      "plan": ".ralph-workspace/orchestration-plans/schema-test/schema-test-01-stage-one.plan.md",
      "artifacts": [
        {
          "path": ".ralph-workspace/artifacts/schema-test/stage-one.json",
          "schema": "bundle/.ralph/schemas/evaluator-verdict.schema.json"
        }
      ]
    }
  ]
}
EOF
  run "$VALIDATOR" "$orch"
  [ "$status" -ne 0 ]
  [[ "$output" == *"workspace is required"* ]]
}

@test "validator accepts valid reasoning_effort on stage" {
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
      "id": "stage-one",
      "runtime": "claude",
      "plan": ".ralph-workspace/orchestration-plans/schema-test/schema-test-01-stage-one.plan.md",
      "reasoning_effort": "high",
      "artifacts": [
        {
          "path": ".ralph-workspace/artifacts/schema-test/stage-one.md"
        }
      ]
    }
  ]
}
EOF
  run "$VALIDATOR" "$orch"
  [ "$status" -eq 0 ]
}

@test "validator rejects invalid reasoning_effort on stage" {
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
      "id": "stage-one",
      "runtime": "claude",
      "plan": ".ralph-workspace/orchestration-plans/schema-test/schema-test-01-stage-one.plan.md",
      "reasoning_effort": "turbo",
      "artifacts": [
        {
          "path": ".ralph-workspace/artifacts/schema-test/stage-one.md"
        }
      ]
    }
  ]
}
EOF
  run "$VALIDATOR" "$orch"
  [ "$status" -ne 0 ]
  [[ "$output" == *"schema validation failed"* ]]
}

@test "validator accepts grader stage with fresh sessionStrategy and rubric" {
  local orch
  orch="$(mktemp)"
  temp_files+=("$orch")
  cat <<'EOF' > "$orch"
{
  "name": "schema-test",
  "namespace": "schema-test",
  "description": "grader schema validation test",
  "stages": [
    {
      "id": "grade",
      "runtime": "cursor",
      "plan": ".ralph-workspace/orchestration-plans/schema-test/schema-test-grade.plan.md",
      "sessionStrategy": "fresh",
      "grader": true,
      "rubric": "bundle/.ralph/schemas/rubric.schema.json",
      "artifacts": [
        {
          "path": ".ralph-workspace/artifacts/schema-test/grade-result.json",
          "schema": "bundle/.ralph/schemas/rubric-result.schema.json"
        }
      ]
    }
  ]
}
EOF
  run "$VALIDATOR" "$orch" "$REPO_ROOT"
  [ "$status" -eq 0 ]
}

@test "validator accepts explicit finalOutputSchema on stage" {
  local orch
  orch="$(mktemp)"
  temp_files+=("$orch")
  cat <<'EOF' > "$orch"
{
  "name": "schema-test",
  "namespace": "schema-test",
  "description": "finalOutputSchema validation test",
  "stages": [
    {
      "id": "review",
      "runtime": "cursor",
      "plan": ".ralph-workspace/orchestration-plans/schema-test/schema-test-review.plan.md",
      "finalOutputSchema": "bundle/.ralph/schemas/evaluator-verdict.schema.json",
      "artifacts": [
        {
          "path": ".ralph-workspace/artifacts/schema-test/review.json"
        }
      ]
    }
  ]
}
EOF
  run "$VALIDATOR" "$orch" "$REPO_ROOT"
  [ "$status" -eq 0 ]
}

@test "validator rejects invalid finalOutputSchema on stage" {
  local orch
  orch="$(mktemp)"
  temp_files+=("$orch")
  cat <<'EOF' > "$orch"
{
  "name": "schema-test",
  "namespace": "schema-test",
  "description": "finalOutputSchema validation test",
  "stages": [
    {
      "id": "review",
      "runtime": "cursor",
      "plan": ".ralph-workspace/orchestration-plans/schema-test/schema-test-review.plan.md",
      "finalOutputSchema": "",
      "artifacts": [
        {
          "path": ".ralph-workspace/artifacts/schema-test/review.json"
        }
      ]
    }
  ]
}
EOF
  run "$VALIDATOR" "$orch" "$REPO_ROOT"
  [ "$status" -ne 0 ]
  [[ "$output" == *"schema validation failed"* ]]
}

@test "validator rejects grader stage with resume sessionStrategy" {
  local orch
  orch="$(mktemp)"
  temp_files+=("$orch")
  cat <<'EOF' > "$orch"
{
  "name": "schema-test",
  "namespace": "schema-test",
  "description": "grader schema validation test",
  "stages": [
    {
      "id": "grade",
      "runtime": "cursor",
      "plan": ".ralph-workspace/orchestration-plans/schema-test/schema-test-grade.plan.md",
      "sessionStrategy": "resume",
      "grader": true,
      "rubric": "bundle/.ralph/schemas/rubric.schema.json",
      "artifacts": [
        {
          "path": ".ralph-workspace/artifacts/schema-test/grade-result.json"
        }
      ]
    }
  ]
}
EOF
  run "$VALIDATOR" "$orch"
  [ "$status" -ne 0 ]
  [[ "$output" == *"schema validation failed"* ]]
}

@test "validator rejects grader stage without rubric path" {
  local orch
  orch="$(mktemp)"
  temp_files+=("$orch")
  cat <<'EOF' > "$orch"
{
  "name": "schema-test",
  "namespace": "schema-test",
  "description": "grader schema validation test",
  "stages": [
    {
      "id": "grade",
      "runtime": "cursor",
      "plan": ".ralph-workspace/orchestration-plans/schema-test/schema-test-grade.plan.md",
      "sessionStrategy": "fresh",
      "grader": true,
      "artifacts": [
        {
          "path": ".ralph-workspace/artifacts/schema-test/grade-result.json"
        }
      ]
    }
  ]
}
EOF
  run "$VALIDATOR" "$orch"
  [ "$status" -ne 0 ]
  [[ "$output" == *"schema validation failed"* ]]
}

@test "validator accepts router stage with forward targets" {
  local orch
  orch="$(mktemp)"
  temp_files+=("$orch")
  cat <<'EOF' > "$orch"
{
  "name": "schema-test",
  "namespace": "schema-test",
  "description": "router schema validation test",
  "stages": [
    {
      "id": "router",
      "runtime": "cursor",
      "plan": ".ralph-workspace/orchestration-plans/schema-test/schema-test-router.plan.md",
      "router": {
        "allowedTargets": ["branch-a", "branch-b"],
        "terminalOutcomes": ["done"],
        "defaultTarget": "branch-a",
        "onInvalid": "fail"
      },
      "artifacts": [
        {
          "path": ".ralph-workspace/artifacts/schema-test/route.json",
          "schema": "bundle/.ralph/schemas/router-decision.schema.json"
        }
      ]
    },
    {
      "id": "branch-a",
      "runtime": "cursor",
      "plan": ".ralph-workspace/orchestration-plans/schema-test/schema-test-branch-a.plan.md",
      "artifacts": [
        {
          "path": ".ralph-workspace/artifacts/schema-test/branch-a.md"
        }
      ]
    },
    {
      "id": "branch-b",
      "runtime": "cursor",
      "plan": ".ralph-workspace/orchestration-plans/schema-test/schema-test-branch-b.plan.md",
      "artifacts": [
        {
          "path": ".ralph-workspace/artifacts/schema-test/branch-b.md"
        }
      ]
    }
  ]
}
EOF
  run "$VALIDATOR" "$orch" "$REPO_ROOT"
  [ "$status" -eq 0 ]
}

@test "validator rejects router stage with backward target" {
  local orch
  orch="$(mktemp)"
  temp_files+=("$orch")
  cat <<'EOF' > "$orch"
{
  "name": "schema-test",
  "namespace": "schema-test",
  "description": "router schema validation test",
  "stages": [
    {
      "id": "branch-a",
      "runtime": "cursor",
      "plan": ".ralph-workspace/orchestration-plans/schema-test/schema-test-branch-a.plan.md",
      "artifacts": [
        {
          "path": ".ralph-workspace/artifacts/schema-test/branch-a.md"
        }
      ]
    },
    {
      "id": "router",
      "runtime": "cursor",
      "plan": ".ralph-workspace/orchestration-plans/schema-test/schema-test-router.plan.md",
      "router": {
        "allowedTargets": ["branch-a"],
        "defaultTarget": "branch-a",
        "onInvalid": "fail"
      },
      "artifacts": [
        {
          "path": ".ralph-workspace/artifacts/schema-test/route.json",
          "schema": "bundle/.ralph/schemas/router-decision.schema.json"
        }
      ]
    }
  ]
}
EOF
  run "$VALIDATOR" "$orch"
  [ "$status" -ne 0 ]
  [[ "$output" == *"schema validation failed"* ]]
}

@test "validator rejects router target inside parallel wave middle" {
  local orch
  orch="$(mktemp)"
  temp_files+=("$orch")
  cat <<'EOF' > "$orch"
{
  "name": "schema-test",
  "namespace": "schema-test",
  "description": "router schema validation test",
  "stages": [
    {
      "id": "router",
      "runtime": "cursor",
      "plan": ".ralph-workspace/orchestration-plans/schema-test/schema-test-router.plan.md",
      "router": {
        "allowedTargets": ["wave-b"],
        "defaultTarget": "wave-b",
        "onInvalid": "fail"
      },
      "artifacts": [
        {
          "path": ".ralph-workspace/artifacts/schema-test/route.json"
        }
      ]
    },
    {
      "id": "wave-a",
      "runtime": "cursor",
      "plan": ".ralph-workspace/orchestration-plans/schema-test/schema-test-wave-a.plan.md",
      "artifacts": [
        {
          "path": ".ralph-workspace/artifacts/schema-test/wave-a.md"
        }
      ]
    },
    {
      "id": "wave-b",
      "runtime": "cursor",
      "plan": ".ralph-workspace/orchestration-plans/schema-test/schema-test-wave-b.plan.md",
      "artifacts": [
        {
          "path": ".ralph-workspace/artifacts/schema-test/wave-b.md"
        }
      ]
    }
  ],
  "parallelStages": [
    "wave-a, wave-b"
  ]
}
EOF
  run "$VALIDATOR" "$orch"
  [ "$status" -ne 0 ]
  [[ "$output" == *"schema validation failed"* ]]
}

@test "validator accepts planner config plan-file with optional maxTodos" {
  local orch
  orch="$(mktemp)"
  temp_files+=("$orch")
  cat <<'EOF' > "$orch"
{
  "name": "schema-test",
  "namespace": "schema-test",
  "description": "planner config validation test",
  "stages": [
    {
      "id": "planner",
      "runtime": "cursor",
      "plan": ".ralph-workspace/orchestration-plans/schema-test/schema-test-planner.plan.md",
      "planner": {
        "outputMode": "plan-file",
        "maxTodos": 40
      },
      "artifacts": [
        {
          "path": ".ralph-workspace/artifacts/schema-test/planner-output.json",
          "schema": "bundle/.ralph/schemas/planner-output.schema.json",
          "required": true
        }
      ]
    }
  ]
}
EOF
  run "$VALIDATOR" "$orch" "$REPO_ROOT"
  [ "$status" -eq 0 ]
}

@test "removed planner roles keys are rejected with generated Ralph plan guidance" {
  local orch
  orch="$(mktemp)"
  temp_files+=("$orch")
  cat <<'EOF' > "$orch"
{
  "name": "schema-test",
  "namespace": "schema-test",
  "stages": [
    {
      "id": "planner",
      "runtime": "cursor",
      "plan": ".ralph-workspace/orchestration-plans/schema-test/schema-test-planner.plan.md",
      "planner": {
        "outputMode": "plan-file",
        "maxTodos": 8,
        "maxStages": 3,
        "allowedRuntimes": ["cursor"],
        "allowedRoles": ["implementation"],
        "allowedModels": ["auto"]
      },
      "artifacts": [
        {
          "path": ".ralph-workspace/artifacts/schema-test/planner-output.json",
          "schema": "bundle/.ralph/schemas/planner-output.schema.json"
        }
      ]
    }
  ]
}
EOF
  run "$VALIDATOR" "$orch"
  [ "$status" -ne 0 ]
  [[ "$output" == *"allowedRoles"* ]] || [[ "$output" == *"maxStages"* ]]
  [[ "$output" == *"generated Ralph plan"* ]]
}

@test "planFrom projection compiles planner and planFrom unchanged into orch JSON" {
  source "$BATS_TEST_DIRNAME/../../../bundle/.ralph/bash-lib/plan-todo.sh"
  local plan_file
  plan_file="$(mktemp)"
  temp_files+=("$plan_file")
  cat <<'EOF' > "$plan_file"
---
name: Orch PlanFrom Projection
execution: orchestration
pipeline:
  stages:
    - id: plan-implementation
      runtime: cursor
      planner:
        outputMode: plan-file
        maxTodos: 40
      produces:
        - path: .ralph-workspace/artifacts/{{ARTIFACT_NS}}/impl-plan.json
          schema: bundle/.ralph/schemas/planner-output.schema.json
          required: true
    - id: implement
      runtime: cursor
      planFrom: plan-implementation
      dependsOn:
        - plan-implementation
      produces:
        - path: .ralph-workspace/artifacts/{{ARTIFACT_NS}}/implementation-handoff.md
          required: true
todos:
  - id: plan-1
    stage: plan-implementation
    content: Write the implementation plan JSON.
    status: pending
---
EOF
  run plan_pipeline_orch_json "$plan_file"
  [ "$status" -eq 0 ]
  planner_mode="$(printf '%s\n' "$output" | jq -r '.stages[0].planner.outputMode')"
  [ "$planner_mode" = "plan-file" ]
  max_todos="$(printf '%s\n' "$output" | jq -r '.stages[0].planner.maxTodos')"
  [ "$max_todos" = "40" ]
  plan_from="$(printf '%s\n' "$output" | jq -r '.stages[1].planFrom')"
  [ "$plan_from" = "plan-implementation" ]
  has_plan="$(printf '%s\n' "$output" | jq -r '.stages[1] | has("plan")')"
  [ "$has_plan" = "false" ]
}

@test "validator accepts stage toolingProfile ralph-compact" {
  local orch
  orch="$(mktemp)"
  temp_files+=("$orch")
  cat <<'EOF' > "$orch"
{
  "name": "schema-test",
  "namespace": "schema-test",
  "stages": [
    {
      "id": "stage-one",
      "runtime": "cursor",
      "plan": ".ralph-workspace/orchestration-plans/schema-test/schema-test-01-stage-one.plan.md",
      "toolingProfile": "ralph-compact",
      "artifacts": [
        {
          "path": ".ralph-workspace/artifacts/schema-test/stage-one.md"
        }
      ]
    }
  ]
}
EOF
  run "$VALIDATOR" "$orch"
  [ "$status" -eq 0 ]
}

@test "validator rejects stage toolingProfile bogus" {
  local orch
  orch="$(mktemp)"
  temp_files+=("$orch")
  cat <<'EOF' > "$orch"
{
  "name": "schema-test",
  "namespace": "schema-test",
  "stages": [
    {
      "id": "stage-one",
      "runtime": "cursor",
      "plan": ".ralph-workspace/orchestration-plans/schema-test/schema-test-01-stage-one.plan.md",
      "toolingProfile": "bogus",
      "artifacts": [
        {
          "path": ".ralph-workspace/artifacts/schema-test/stage-one.md"
        }
      ]
    }
  ]
}
EOF
  run "$VALIDATOR" "$orch"
  [ "$status" -ne 0 ]
  [[ "$output" == *"toolingProfile"* ]]
}

@test "removed role field: rejects stage role naming inline workflow instructions" {
  local orch
  orch="$(mktemp)"
  temp_files+=("$orch")
  cat <<'EOF' > "$orch"
{
  "name": "schema-test",
  "namespace": "schema-test",
  "stages": [
    {
      "id": "stage-one",
      "role": "implementation",
      "runtime": "cursor",
      "plan": ".ralph-workspace/orchestration-plans/schema-test/schema-test-01-stage-one.plan.md",
      "artifacts": [
        {
          "path": ".ralph-workspace/artifacts/schema-test/stage-one.md",
          "required": true
        }
      ]
    }
  ]
}
EOF
  run "$VALIDATOR" "$orch"
  [ "$status" -ne 0 ]
  [[ "$output" == *"role was removed"* ]]
  [[ "$output" == *"inline workflow instructions"* ]]
}

@test "removed role field: accepts roleless stage omitting role" {
  local orch
  orch="$(mktemp)"
  temp_files+=("$orch")
  cat <<'EOF' > "$orch"
{
  "name": "schema-test",
  "namespace": "schema-test",
  "stages": [
    {
      "id": "stage-one",
      "runtime": "cursor",
      "plan": ".ralph-workspace/orchestration-plans/schema-test/schema-test-01-stage-one.plan.md",
      "artifacts": [
        {
          "path": ".ralph-workspace/artifacts/schema-test/stage-one.md",
          "required": true
        }
      ]
    }
  ]
}
EOF
  run "$VALIDATOR" "$orch"
  [ "$status" -eq 0 ]
}

@test "removed role field: normalized orch JSON omits role and agent" {
  source "$BATS_TEST_DIRNAME/../../../bundle/.ralph/bash-lib/plan-todo.sh"
  local plan_file
  plan_file="$(mktemp)"
  temp_files+=("$plan_file")
  cat <<'EOF' > "$plan_file"
---
name: Orch Role Normalize
execution: orchestration
pipeline:
  stages:
    - id: research
      runtime: cursor
      instructions: Investigate the request.
      produces:
        - path: .ralph-workspace/artifacts/{{ARTIFACT_NS}}/research.md
          required: true
todos:
  - id: research-1
    stage: research
    content: Do the research.
    status: pending
---
EOF
  run plan_pipeline_orch_json "$plan_file"
  [ "$status" -eq 0 ]
  has_role="$(printf '%s\n' "$output" | jq -r '.stages[0] | has("role")')"
  [ "$has_role" = "false" ]
  has_agent="$(printf '%s\n' "$output" | jq -r '.stages[0] | has("agent")')"
  [ "$has_agent" = "false" ]
  instructions="$(printf '%s\n' "$output" | jq -r '.stages[0].instructions')"
  [ "$instructions" = "Investigate the request." ]
}

@test "removed role field: bridge dry-run omits --role" {
  local orch workspace orchestrator
  workspace="$(mktemp -d)"
  orch="$workspace/bridge-role.orch.json"
  mkdir -p "$workspace/.ralph-workspace/orchestration-plans/bridge-role"
  cat > "$workspace/.ralph-workspace/orchestration-plans/bridge-role/stage.plan.md" <<'EOF'
---
todos:
  - id: t1
    content: noop
    status: pending
---
EOF
  cat <<'EOF' > "$orch"
{
  "name": "bridge-role",
  "namespace": "bridge-role",
  "stages": [
    {
      "id": "stage-one",
      "runtime": "cursor",
      "plan": ".ralph-workspace/orchestration-plans/bridge-role/stage.plan.md",
      "artifacts": [
        {
          "path": ".ralph-workspace/artifacts/bridge-role/out.md",
          "required": true
        }
      ]
    }
  ]
}
EOF
  orchestrator="$REPO_ROOT/.ralph/orchestrator.sh"
  run env RALPH_ALLOW_NESTED_RUNS=1 ORCHESTRATOR_DRY_RUN=1 ORCHESTRATOR_NO_COLOR=1 bash "$orchestrator" --orchestration "$orch" "$workspace"
  [ "$status" -eq 0 ]
  [[ "$output" != *"--role "* ]]
  [[ "$output" != *"--agent "* ]]
  ralph_test_rm_workspace "$workspace"
}

@test "removed agent: rejects stage agent with instructions guidance" {
  local orch
  orch="$(mktemp)"
  temp_files+=("$orch")
  cat <<'EOF' > "$orch"
{
  "name": "schema-test",
  "namespace": "schema-test",
  "stages": [
    {
      "id": "stage-one",
      "runtime": "cursor",
      "agent": "architect",
      "plan": ".ralph-workspace/orchestration-plans/schema-test/schema-test-01-stage-one.plan.md",
      "artifacts": [
        {
          "path": ".ralph-workspace/artifacts/schema-test/stage-one.md"
        }
      ]
    }
  ]
}
EOF
  run "$VALIDATOR" "$orch"
  [ "$status" -ne 0 ]
  [[ "$output" == *"agent was removed"* ]]
  [[ "$output" == *"inline workflow instructions"* ]]
}

@test "removed agent: rejects stage agentSource with instructions guidance" {
  local orch
  orch="$(mktemp)"
  temp_files+=("$orch")
  cat <<'EOF' > "$orch"
{
  "name": "schema-test",
  "namespace": "schema-test",
  "stages": [
    {
      "id": "stage-one",
      "runtime": "cursor",
      "agentSource": "prebuilt",
      "plan": ".ralph-workspace/orchestration-plans/schema-test/schema-test-01-stage-one.plan.md",
      "artifacts": [
        {
          "path": ".ralph-workspace/artifacts/schema-test/stage-one.md"
        }
      ]
    }
  ]
}
EOF
  run "$VALIDATOR" "$orch"
  [ "$status" -ne 0 ]
  [[ "$output" == *"agentSource was removed"* ]]
  [[ "$output" == *"inline workflow instructions"* ]]
}

@test "nativeSubagents: accepts off on a stage" {
  local orch
  orch="$(mktemp)"
  temp_files+=("$orch")
  cat <<'EOF' > "$orch"
{
  "name": "schema-test",
  "namespace": "schema-test",
  "stages": [
    {
      "id": "stage-one",
      "runtime": "cursor",
      "nativeSubagents": "off",
      "plan": ".ralph-workspace/orchestration-plans/schema-test/schema-test-01-stage-one.plan.md",
      "artifacts": [
        {
          "path": ".ralph-workspace/artifacts/schema-test/stage-one.md",
          "required": true
        }
      ]
    }
  ]
}
EOF
  run "$VALIDATOR" "$orch"
  [ "$status" -eq 0 ]
}

@test "nativeSubagents: accepts inherit on a stage" {
  local orch
  orch="$(mktemp)"
  temp_files+=("$orch")
  cat <<'EOF' > "$orch"
{
  "name": "schema-test",
  "namespace": "schema-test",
  "stages": [
    {
      "id": "stage-one",
      "runtime": "cursor",
      "nativeSubagents": "inherit",
      "plan": ".ralph-workspace/orchestration-plans/schema-test/schema-test-01-stage-one.plan.md",
      "artifacts": [
        {
          "path": ".ralph-workspace/artifacts/schema-test/stage-one.md",
          "required": true
        }
      ]
    }
  ]
}
EOF
  run "$VALIDATOR" "$orch"
  [ "$status" -eq 0 ]
}

@test "nativeSubagents: omitted stage is valid (default off at compile)" {
  local orch
  orch="$(mktemp)"
  temp_files+=("$orch")
  generate_orch "$orch"
  run "$VALIDATOR" "$orch"
  [ "$status" -eq 0 ]
}

@test "nativeSubagents: rejects invalid value" {
  local orch
  orch="$(mktemp)"
  temp_files+=("$orch")
  cat <<'EOF' > "$orch"
{
  "name": "schema-test",
  "namespace": "schema-test",
  "stages": [
    {
      "id": "stage-one",
      "runtime": "cursor",
      "nativeSubagents": "on",
      "plan": ".ralph-workspace/orchestration-plans/schema-test/schema-test-01-stage-one.plan.md",
      "artifacts": [
        {
          "path": ".ralph-workspace/artifacts/schema-test/stage-one.md"
        }
      ]
    }
  ]
}
EOF
  run "$VALIDATOR" "$orch"
  [ "$status" -ne 0 ]
  [[ "$output" == *"nativeSubagents"* ]]
}

@test "nativeSubagents: rejects removed subagents with migration guidance" {
  local orch
  orch="$(mktemp)"
  temp_files+=("$orch")
  cat <<'EOF' > "$orch"
{
  "name": "schema-test",
  "namespace": "schema-test",
  "stages": [
    {
      "id": "stage-one",
      "runtime": "cursor",
      "subagents": "inherit",
      "plan": ".ralph-workspace/orchestration-plans/schema-test/schema-test-01-stage-one.plan.md",
      "artifacts": [
        {
          "path": ".ralph-workspace/artifacts/schema-test/stage-one.md"
        }
      ]
    }
  ]
}
EOF
  run "$VALIDATOR" "$orch"
  [ "$status" -ne 0 ]
  [[ "$output" == *"subagents was removed"* ]]
  [[ "$output" == *"nativeSubagents"* ]]
  [[ "$output" == *"ralph migrate"* ]]
}

@test "nativeSubagents: rejects removed delegation.native with migration guidance" {
  local orch
  orch="$(mktemp)"
  temp_files+=("$orch")
  cat <<'EOF' > "$orch"
{
  "name": "schema-test",
  "namespace": "schema-test",
  "stages": [
    {
      "id": "stage-one",
      "runtime": "cursor",
      "delegation": {
        "maxChildren": 1,
        "native": {
          "mode": "read-only",
          "allowedRoles": ["research"],
          "maxParallel": 1
        }
      },
      "plan": ".ralph-workspace/orchestration-plans/schema-test/schema-test-01-stage-one.plan.md",
      "artifacts": [
        {
          "path": ".ralph-workspace/artifacts/schema-test/stage-one.md"
        }
      ]
    }
  ]
}
EOF
  run "$VALIDATOR" "$orch"
  [ "$status" -ne 0 ]
  [[ "$output" == *"delegation.native was removed"* ]]
  [[ "$output" == *"nativeSubagents"* ]]
  [[ "$output" == *"ralph migrate"* ]]
}

@test "nativeSubagents: normalized orch JSON emits nativeSubagents default off" {
  local plan_file
  plan_file="$(mktemp)"
  temp_files+=("$plan_file")
  cat <<'EOF' >"$plan_file"
---
execution: orchestration
pipeline:
  stages:
    - id: stage-one
      runtime: cursor
todos:
  - id: t1
    stage: stage-one
    content: do work
    status: pending
---
EOF
  # shellcheck source=/dev/null
  source "$REPO_ROOT/bundle/.ralph/bash-lib/plan-todo.sh"
  run plan_pipeline_orch_json "$plan_file"
  [ "$status" -eq 0 ]
  mode="$(printf '%s\n' "$output" | awk 'END{print}' | jq -r '.stages[0].nativeSubagents')"
  # A staged agent stage defaults to off only on a runtime with a proven deny
  # boundary (claude, codex). cursor has none, so the ambient inherit stands
  # rather than a value that would refuse to invoke.
  [ "$mode" = "inherit" ]
  has_subagents="$(printf '%s\n' "$output" | awk 'END{print}' | jq -r '.stages[0] | has("subagents")')"
  [ "$has_subagents" = "false" ]

  # Same stage on an enforcing runtime does default to off.
  sed -i.bak 's/runtime: cursor/runtime: claude/' "$plan_file"
  run plan_pipeline_orch_json "$plan_file"
  [ "$status" -eq 0 ]
  mode="$(printf '%s\n' "$output" | awk 'END{print}' | jq -r '.stages[0].nativeSubagents')"
  [ "$mode" = "off" ]
}

# Planner-output v2 + generated plan manifest contracts
# (define-generated-ralph-plan-contract)

PLANNER_OUTPUT_SCHEMA="$REPO_ROOT/bundle/.ralph/schemas/planner-output.schema.json"
PLAN_MANIFEST_SCHEMA="$REPO_ROOT/bundle/.ralph/schemas/workflow-plan-manifest.schema.json"
ARTIFACT_SCHEMA_PY="$REPO_ROOT/bundle/.ralph/python/artifact_json_schema.py"
PLANNER_CONTRACT_PY="$REPO_ROOT/bundle/.ralph/python/planner_contract.py"

validate_json_schema() {
  local schema="$1"
  local artifact="$2"
  python3 "$ARTIFACT_SCHEMA_PY" validate-final-output --schema "$schema" --artifact "$artifact"
}

@test "planner output v2 schema accepts pending todos with optional overrides" {
  command -v python3 >/dev/null || skip "python3 required"
  local artifact
  artifact="$(mktemp)"
  temp_files+=("$artifact")
  cat <<'EOFJSON' > "$artifact"
{
  "schemaVersion": 2,
  "name": "v2-demo",
  "overview": "Cover the change",
  "rationale": "Fewest independently verifiable TODOs.",
  "todos": [
    {
      "id": "implement-core",
      "content": "Edit owned files.",
      "verification": "true",
      "status": "pending"
    },
    {
      "id": "model-only",
      "content": "Model override.",
      "verification": "true",
      "status": "pending",
      "model": "gpt-5"
    },
    {
      "id": "runtime-only",
      "content": "Runtime override.",
      "verification": "true",
      "status": "pending",
      "runtime": "codex"
    }
  ]
}
EOFJSON
  run validate_json_schema "$PLANNER_OUTPUT_SCHEMA" "$artifact"
  [ "$status" -eq 0 ]
  run python3 "$PLANNER_CONTRACT_PY" validate-output --artifact "$artifact" --max-todos 40
  [ "$status" -eq 0 ]
}

@test "planner output v2 rejects sessionStrategy and completed status" {
  command -v python3 >/dev/null || skip "python3 required"
  local artifact
  artifact="$(mktemp)"
  temp_files+=("$artifact")
  cat <<'EOFJSON' > "$artifact"
{
  "schemaVersion": 2,
  "name": "bad",
  "overview": "x",
  "rationale": "y",
  "sessionStrategy": "fresh",
  "todos": [
    {
      "id": "one",
      "content": "Do it",
      "verification": "true",
      "status": "pending"
    }
  ]
}
EOFJSON
  run validate_json_schema "$PLANNER_OUTPUT_SCHEMA" "$artifact"
  [ "$status" -ne 0 ]
  cat <<'EOFJSON' > "$artifact"
{
  "schemaVersion": 2,
  "name": "bad",
  "overview": "x",
  "rationale": "y",
  "todos": [
    {
      "id": "one",
      "content": "Do it",
      "verification": "true",
      "status": "completed"
    }
  ]
}
EOFJSON
  run validate_json_schema "$PLANNER_OUTPUT_SCHEMA" "$artifact"
  [ "$status" -ne 0 ]
}

@test "plan manifest schema accepts version-1 generated plan manifest" {
  command -v python3 >/dev/null || skip "python3 required"
  local artifact
  artifact="$(mktemp)"
  temp_files+=("$artifact")
  cat <<'EOFJSON' > "$artifact"
{
  "schemaVersion": 1,
  "producerStageId": "plan-implementation",
  "producerAttempt": 1,
  "sourceArtifact": "/tmp/project/.ralph-workspace/artifacts/ns/impl-plan.json",
  "planPath": "/tmp/project/.ralph-workspace/workflow-runs/run-1/plans/plan-implementation/attempt-1.plan.md",
  "planSha256": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
  "todoCount": 3,
  "createdAt": "2026-01-01T00:00:00Z"
}
EOFJSON
  run validate_json_schema "$PLAN_MANIFEST_SCHEMA" "$artifact"
  [ "$status" -eq 0 ]
  run python3 "$PLANNER_CONTRACT_PY" validate-manifest --manifest "$artifact"
  [ "$status" -eq 0 ]
}

@test "removed dynamic stages planner outputMode is rejected" {
  local orch
  orch="$(mktemp)"
  temp_files+=("$orch")
  cat <<'EOF' > "$orch"
{
  "name": "schema-test",
  "namespace": "schema-test",
  "stages": [
    {
      "id": "planner",
      "runtime": "cursor",
      "plan": ".ralph-workspace/orchestration-plans/schema-test/schema-test-planner.plan.md",
      "planner": {
        "outputMode": "stages",
        "maxTodos": 8
      },
      "artifacts": [
        {
          "path": ".ralph-workspace/artifacts/schema-test/planner-output.json",
          "schema": "bundle/.ralph/schemas/planner-output.schema.json",
          "required": true
        }
      ]
    }
  ]
}
EOF
  run "$VALIDATOR" "$orch"
  [ "$status" -ne 0 ]
  [[ "$output" == *"does not match the schema"* ]] || [[ "$output" == *"plan-file"* ]] || [[ "$output" == *"outputMode"* ]]
}

@test "planner config max 200 is enforced by orchestration schema" {
  local orch
  orch="$(mktemp)"
  temp_files+=("$orch")
  cat <<'EOF' > "$orch"
{
  "name": "schema-test",
  "namespace": "schema-test",
  "stages": [
    {
      "id": "planner",
      "runtime": "cursor",
      "plan": ".ralph-workspace/orchestration-plans/schema-test/schema-test-planner.plan.md",
      "planner": {
        "outputMode": "plan-file",
        "maxTodos": 201
      },
      "artifacts": [
        {
          "path": ".ralph-workspace/artifacts/schema-test/planner-output.json",
          "schema": "bundle/.ralph/schemas/planner-output.schema.json",
          "required": true
        }
      ]
    }
  ]
}
EOF
  run "$VALIDATOR" "$orch"
  [ "$status" -ne 0 ]
  [[ "$output" == *"does not match the schema"* ]] || [[ "$output" == *"maxTodos"* ]] || [[ "$output" == *"200"* ]]
}

# --- Workflow routing through sequential orch JSON + stub argv ----------------
# Prove materialized fallbacks become concrete stage routing on orch JSON while
# explicit stage/TODO overrides, provided-plan header order, and instructions
# stay local. Sourced instantiate/routing/orchestrator dry-run + stub run-plan.

SEQ_ROUTING_LIB="$REPO_ROOT/bundle/.ralph/bash-lib/workflow/workflow-routing.sh"
SEQ_ENGINE_LIB="$REPO_ROOT/bundle/.ralph/bash-lib/workflow/workflow-engine-sequential.sh"
SEQ_STATE_LIB="$REPO_ROOT/bundle/.ralph/bash-lib/workflow/workflow-state.sh"

@test "workflow routing: sequential stage materialize and instructions into orch JSON" {
  source "$BATS_TEST_DIRNAME/../../../bundle/.ralph/bash-lib/plan-todo.sh"
  local tmpd wf plan_file
  tmpd="$(mktemp -d)"
  wf="$tmpd/wf.md"
  plan_file="$tmpd/out.plan.md"
  cat >"$wf" <<'EOF'
---
name: seq-routing
kind: workflow
mode: sequential
pipeline:
  stages:
    - id: research
      instructions: Research guidance stays.
    - id: plan-implementation
      planner:
        outputMode: plan-file
        maxTodos: 20
      produces:
        - path: .ralph-workspace/artifacts/{{ARTIFACT_NS}}/impl-plan.json
          schema: bundle/.ralph/schemas/planner-output.schema.json
          required: true
    - id: implement
      planFrom: plan-implementation
      dependsOn:
        - plan-implementation
      produces:
        - path: .ralph-workspace/artifacts/{{ARTIFACT_NS}}/handoff.md
          required: true
    - id: ship
      runtime: cursor
      instructions: Different runtime stage.
      produces:
        - path: .ralph-workspace/artifacts/{{ARTIFACT_NS}}/ship.md
          required: true
todos:
  - id: research-1
    stage: research
    content: Investigate {{TASK}}
    status: pending
  - id: plan-1
    stage: plan-implementation
    content: Plan {{TASK}}
    status: pending
---
EOF

  run plan_workflow_instantiate "$wf" "fix login" "$plan_file" \
    fallback_runtime=claude fallback_model=sonnet
  [ "$status" -eq 0 ]
  grep -qx 'execution: orchestration' "$plan_file"

  run plan_pipeline_orch_json "$plan_file"
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | jq -r '.stages[] | select(.id=="research") | .runtime')" = "claude" ]
  [ "$(printf '%s\n' "$output" | jq -r '.stages[] | select(.id=="research") | .model')" = "sonnet" ]
  [ "$(printf '%s\n' "$output" | jq -r '.stages[] | select(.id=="research") | .instructions')" = "Research guidance stays." ]
  [ "$(printf '%s\n' "$output" | jq -r '.stages[] | select(.id=="plan-implementation") | .runtime')" = "claude" ]
  [ "$(printf '%s\n' "$output" | jq -r '.stages[] | select(.id=="plan-implementation") | .model')" = "sonnet" ]
  [ "$(printf '%s\n' "$output" | jq -r '.stages[] | select(.id=="implement") | .runtime')" = "claude" ]
  [ "$(printf '%s\n' "$output" | jq -r '.stages[] | select(.id=="implement") | .planFrom')" = "plan-implementation" ]
  [ "$(printf '%s\n' "$output" | jq -r '.stages[] | select(.id=="ship") | .runtime')" = "cursor" ]
  [ "$(printf '%s\n' "$output" | jq -r '.stages[] | select(.id=="ship") | has("model")')" = "false" ]
  [ "$(printf '%s\n' "$output" | jq -r '.stages[] | select(.id=="ship") | .instructions')" = "Different runtime stage." ]

  # Skipped-model path: fallback_runtime alone leaves model absent.
  plan_file2="$tmpd/out2.plan.md"
  run plan_workflow_instantiate "$wf" "fix login" "$plan_file2" fallback_runtime=opencode
  [ "$status" -eq 0 ]
  run plan_pipeline_orch_json "$plan_file2"
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | jq -r '.stages[] | select(.id=="research") | .runtime')" = "opencode" ]
  [ "$(printf '%s\n' "$output" | jq -r '.stages[] | select(.id=="research") | has("model")')" = "false" ]
  rm -rf "$tmpd"
}

@test "workflow routing: sequential stub argv carries concrete runtime and model" {
  source "$BATS_TEST_DIRNAME/../../../bundle/.ralph/bash-lib/plan-todo.sh"
  local workspace orch plan_rel capture capture_env orchestrator
  workspace="$(mktemp -d)"
  mkdir -p "$workspace/.ralph" \
    "$workspace/.ralph-workspace/orchestration-plans/seq-routing" \
    "$workspace/.ralph-workspace/artifacts/seq-routing"
  # Activate workspace tooling so the stub run-plan is used (requires
  # ralph-env-safety.sh beside run-plan.sh); share bash-lib/python via symlink.
  cp "$REPO_ROOT/.ralph/ralph-env-safety.sh" "$workspace/.ralph/"
  ln -s "$REPO_ROOT/.ralph/bash-lib" "$workspace/.ralph/bash-lib"
  ln -s "$REPO_ROOT/.ralph/python" "$workspace/.ralph/python"
  capture="$workspace/run-plan.argv"
  capture_env="$workspace/run-plan.env"
  : >"$capture"
  : >"$capture_env"

  cat >"$workspace/.ralph/run-plan.sh" <<EOF
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "\$@" >>"$capture"
printenv | grep -E '^(PLAN_STAGE_MODEL|RALPH_MODEL_SCOPE|RALPH_WORKFLOW_STAGE_INSTRUCTIONS)=' >>"$capture_env" || true
mkdir -p "$workspace/.ralph-workspace/artifacts/seq-routing"
printf 'ok\n' >"$workspace/.ralph-workspace/artifacts/seq-routing/out.md"
exit 0
EOF
  chmod +x "$workspace/.ralph/run-plan.sh"

  plan_rel=".ralph-workspace/orchestration-plans/seq-routing/stage.plan.md"
  cat >"$workspace/$plan_rel" <<'EOF'
---
todos:
  - id: t1
    content: noop
    status: pending
---
EOF

  orch="$workspace/seq-routing.orch.json"
  cat >"$orch" <<EOF
{
  "name": "seq-routing",
  "namespace": "seq-routing",
  "stages": [
    {
      "id": "research",
      "runtime": "claude",
      "model": "sonnet",
      "instructions": "Research guidance stays.",
      "plan": "$plan_rel",
      "artifacts": [
        {
          "path": ".ralph-workspace/artifacts/seq-routing/out.md",
          "required": true
        }
      ]
    }
  ]
}
EOF

  orchestrator="$REPO_ROOT/.ralph/orchestrator.sh"
  run env RALPH_ALLOW_NESTED_RUNS=1 ORCHESTRATOR_NO_COLOR=1 \
    bash "$orchestrator" --orchestration "$orch" "$workspace"
  [ "$status" -eq 0 ]
  grep -Fq -- '--runtime' "$capture"
  grep -Fq -- 'claude' "$capture"
  grep -Fq 'PLAN_STAGE_MODEL=sonnet' "$capture_env"
  grep -Fq 'RALPH_MODEL_SCOPE=staged' "$capture_env"
  grep -Fq 'RALPH_WORKFLOW_STAGE_INSTRUCTIONS=Research guidance stays.' "$capture_env"
  ralph_test_rm_workspace "$workspace"
}

@test "workflow routing: provided plan header under stage/invocation for sequential orch" {
  # shellcheck source=/dev/null
  source "$SEQ_ROUTING_LIB"
  # shellcheck source=/dev/null
  source "$SEQ_ENGINE_LIB"
  # shellcheck source=/dev/null
  source "$SEQ_STATE_LIB"

  local tmpd run_id orch source_plan binding control before after registry_run
  tmpd="$(mktemp -d)"
  export WORKFLOW_STATE_SKIP_FSYNC=1
  export WORKFLOW_SEQ_SKIP_FSYNC=1
  export WORKFLOW_STATE_FIXED_NOW="2026-08-27T17:00:00Z"
  export RALPH_PLAN_WORKSPACE_ROOT="$tmpd"

  mkdir -p "$tmpd/project/plans" "$tmpd/inputs"
  printf '%s\n' '---' 'kind: workflow' 'mode: sequential' '---' >"$tmpd/inputs/wf.md"
  cat >"$tmpd/project/plans/feature.plan.md" <<'EOF'
---
name: Provided Feature
overview: Ship it
runtime: claude
model: plan-header-model
todos:
  - id: one
    content: Do one
    verification: true
    status: pending
  - id: two
    content: Do two
    verification: true
    status: pending
    model: todo-model-only
  - id: three
    content: Do three
    verification: true
    status: pending
    runtime: codex
---
EOF

  orch="$tmpd/provided.orch.json"
  cat >"$orch" <<'EOF'
{
  "name": "pd",
  "namespace": "pd",
  "stages": [
    {
      "id": "implement",
      "runtime": "cursor",
      "model": "stage-model",
      "sessionStrategy": "fresh",
      "instructions": "Use the supplied plan."
    },
    {
      "id": "review",
      "runtime": "cursor",
      "instructions": "Review only."
    }
  ]
}
EOF

  run_id="$(
    workflow_state_create \
      --state-root "$tmpd" \
      --source-path "$tmpd/inputs/wf.md" \
      --source-kind project \
      --mode sequential \
      --entry-kind plan \
      --task "Execute the supplied feature plan" \
      --task-provenance plan-overview \
      --input-file "$orch" \
      --workflow-id plan-delivery
  )"
  registry_run="$tmpd/workflow-runs/$run_id"
  workflow_seq_init_engine \
    --registry-run "$registry_run" \
    --input-file "$orch" \
    --run-id "$run_id" >/dev/null
  workflow_seq_set_plan_input_stage implement

  workflow_state_import_provided_plan \
    --state-root "$tmpd" \
    --run-id "$run_id" \
    --plan "$tmpd/project/plans/feature.plan.md" \
    --project-root "$tmpd/project" >/dev/null
  source_plan="$registry_run/plans/input/source.plan.md"
  before="$(cksum "$source_plan" | awk '{print $1" "$2}')"

  binding="$(
    workflow_seq_bind_provided_plan_control \
      --registry-run "$registry_run" \
      --orch-path "$orch" \
      --stage-id implement \
      --workflow-runtime opencode \
      --workflow-model wf-model
  )"
  control="$(printf '%s' "$binding" | jq -r '.controlPlanPath')"
  [ -f "$control" ]
  [ "$(jq -r '.stages[] | select(.id=="implement") | .plan' "$orch")" = "$control" ]
  [ "$(jq -r '.stages[] | select(.id=="implement") | .runtime' "$orch")" = "cursor" ]
  [ "$(jq -r '.stages[] | select(.id=="implement") | .model' "$orch")" = "stage-model" ]
  [ "$(jq -r '.stages[] | select(.id=="implement") | .instructions' "$orch")" = "Use the supplied plan." ]
  # Non-consumer untouched (no plan path projected).
  [ "$(jq -r '.stages[] | select(.id=="review") | .runtime' "$orch")" = "cursor" ]
  [ "$(jq -r '.stages[] | select(.id=="review") | .plan // empty' "$orch")" = "" ]

  # Invocation above provided-plan header; header above workflow default.
  jq '.stages |= map(if .id == "implement" then del(.runtime, .model) else . end)' "$orch" \
    >"$orch.tmp" && mv "$orch.tmp" "$orch"
  workflow_seq_apply_provided_routing_order "$orch" implement "$source_plan" \
    --invocation-runtime antigravity \
    --workflow-runtime opencode \
    --workflow-model wf-model
  [ "$(jq -r '.stages[] | select(.id=="implement") | .runtime' "$orch")" = "antigravity" ]

  jq '.stages |= map(if .id == "implement" then del(.runtime, .model) else . end)' "$orch" \
    >"$orch.tmp" && mv "$orch.tmp" "$orch"
  workflow_seq_apply_provided_routing_order "$orch" implement "$source_plan" \
    --workflow-runtime opencode \
    --workflow-model wf-model
  [ "$(jq -r '.stages[] | select(.id=="implement") | .runtime' "$orch")" = "claude" ]
  [ "$(jq -r '.stages[] | select(.id=="implement") | .model' "$orch")" = "plan-header-model" ]

  grep -q 'model: todo-model-only' "$control"
  grep -q 'runtime: codex' "$control"
  python3 - "$control" <<'PY'
from pathlib import Path
import sys
p = Path(sys.argv[1])
text = p.read_text(encoding="utf-8")
p.write_text(text.replace("status: pending", "status: completed", 1), encoding="utf-8")
PY
  after="$(cksum "$source_plan" | awk '{print $1" "$2}')"
  [ "$before" = "$after" ]
  [ ! -w "$source_plan" ]
  ! grep -q 'status: completed' "$source_plan"
  grep -q 'status: completed' "$control"
  rm -rf "$tmpd"
}

@test "workflow routing: generated TODO overrides remain local with frozen sequential defaults" {
  command -v python3 >/dev/null || skip "python3 required"
  local tmpd artifact plan_out
  tmpd="$(mktemp -d)"
  artifact="$tmpd/planner.json"
  plan_out="$tmpd/frozen.plan.md"
  cat >"$artifact" <<'EOF'
{
  "schemaVersion": 2,
  "name": "seq-freeze",
  "overview": "Cover generated TODO override matrix",
  "rationale": "Fewest independently verifiable TODOs.",
  "todos": [
    {
      "id": "baseline",
      "content": "Use plan defaults.",
      "verification": "true",
      "status": "pending"
    },
    {
      "id": "model-only",
      "content": "Model-only generated TODO.",
      "verification": "true",
      "status": "pending",
      "model": "gpt-5"
    },
    {
      "id": "runtime-only",
      "content": "Runtime-only generated TODO.",
      "verification": "true",
      "status": "pending",
      "runtime": "codex"
    },
    {
      "id": "paired",
      "content": "Paired override.",
      "verification": "true",
      "status": "pending",
      "runtime": "claude",
      "model": "opus"
    }
  ]
}
EOF
  [ "$(jq -r 'has("runtime"),has("model"),has("sessionStrategy")' "$artifact" | paste -sd, -)" = "false,false,false" ]
  run python3 "$PLANNER_CONTRACT_PY" render-plan \
    --artifact "$artifact" \
    --default-runtime claude \
    --default-model sonnet \
    --output "$plan_out" \
    --max-todos 40
  [ "$status" -eq 0 ]
  grep -qE '^runtime: claude$' "$plan_out"
  grep -qE '^model: sonnet$' "$plan_out"
  awk '/^  - id: model-only$/{p=1;next} p && /^  - id:/{exit} p' "$plan_out" | grep -qx '    model: gpt-5'
  ! awk '/^  - id: model-only$/{p=1;next} p && /^  - id:/{exit} p && /^[[:space:]]+runtime:/{found=1} END{exit found?0:1}' "$plan_out"
  awk '/^  - id: runtime-only$/{p=1;next} p && /^  - id:/{exit} p' "$plan_out" | grep -qx '    runtime: codex'
  ! awk '/^  - id: runtime-only$/{p=1;next} p && /^  - id:/{exit} p && /^[[:space:]]+model:/{found=1} END{exit found?0:1}' "$plan_out"
  awk '/^  - id: paired$/{p=1;next} p && /^  - id:/{exit} p' "$plan_out" | grep -qx '    runtime: claude'
  awk '/^  - id: paired$/{p=1;next} p && /^  - id:/{exit} p' "$plan_out" | grep -qx '    model: opus'
  [ "$(jq -r 'has("runtime"),has("model")' "$artifact" | paste -sd, -)" = "false,false" ]
  rm -rf "$tmpd"
}
