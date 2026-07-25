#!/usr/bin/env bats

source "$BATS_TEST_DIRNAME/../helper/load-lib.bash"

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
      "agent": "architect",
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
      "agent": "architect",
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
      "agent": "architect",
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
      "agent": "architect",
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
      "agent": "architect",
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
      "agent": "architect",
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
      "agent": "architect",
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
      "agent": "qa",
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
      "agent": "code-review",
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
      "agent": "code-review",
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
      "agent": "qa",
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
      "agent": "qa",
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
      "agent": "research",
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
      "agent": "implementation",
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
      "agent": "implementation",
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
      "agent": "implementation",
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
      "agent": "research",
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
      "agent": "research",
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
      "agent": "implementation",
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
      "agent": "implementation",
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

@test "validator accepts planner stage with full config" {
  command -v python3 >/dev/null || skip "python3 required"
  local orch
  orch="$(mktemp)"
  temp_files+=("$orch")
  cat <<'EOF' > "$orch"
{
  "name": "schema-test",
  "namespace": "schema-test",
  "description": "planner schema validation test",
  "stages": [
    {
      "id": "planner",
      "runtime": "cursor",
      "agent": "architect",
      "plan": ".ralph-workspace/orchestration-plans/schema-test/schema-test-planner.plan.md",
      "planner": {
        "outputMode": "stages",
        "maxTodos": 8,
        "maxStages": 3,
        "allowedRuntimes": ["cursor"],
        "allowedAgents": ["implementation"],
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
  run "$VALIDATOR" "$orch" "$REPO_ROOT"
  [ "$status" -eq 0 ]
}

@test "validator rejects planner stage missing allowedModels" {
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
      "agent": "architect",
      "plan": ".ralph-workspace/orchestration-plans/schema-test/schema-test-planner.plan.md",
      "planner": {
        "outputMode": "plan-file",
        "maxTodos": 8,
        "maxStages": 3,
        "allowedRuntimes": ["cursor"],
        "allowedAgents": ["implementation"]
      }
    }
  ]
}
EOF
  run "$VALIDATOR" "$orch"
  [ "$status" -ne 0 ]
  [[ "$output" == *"schema validation failed"* ]]
}
