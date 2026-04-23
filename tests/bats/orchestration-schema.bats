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
      "plan": ".ralph-workspace/orchestration-plans/schema-test/schema-test-01-stage-one.plan.md",
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
      "agent": "research",
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
      "agent": "architect",
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
      "agent": "research",
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
      "agent": "qa",
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
      "agent": "architect",
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
      "agent": "research",
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
      "agent": "qa",
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
      "agent": "architect",
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
      "agent": "research",
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
      "agent": "architect",
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
      "agent": "architect",
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
      "agent": "implementation",
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
      "agent": "code-review",
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
      "agent": "architect",
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
      "agent": "architect",
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
      "agent": "architect",
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
      "agent": "architect",
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
      "agent": "architect",
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
      "agent": "implementation",
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
      "agent": "architect",
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
      "agent": "architect",
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
      "agent": "implementation",
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
      "agent": "code-review",
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
      "agent": "architect",
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
      "agent": "implementation",
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
      "agent": "code-review",
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
      "agent": "architect",
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
      "agent": "implementation",
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
      "agent": "code-review",
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
      "agent": "architect",
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
      "agent": "implementation",
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
      "agent": "code-review",
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
      "agent": "architect",
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
      "agent": "implementation",
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
