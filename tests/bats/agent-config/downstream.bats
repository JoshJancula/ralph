#!/usr/bin/env bats

source "$BATS_TEST_DIRNAME/../helper/load-lib.bash"

agent_config_tool_path() {
  echo "$REPO_ROOT/bundle/.ralph/agent-config-tool.sh"
}

@test "reports downstream stage info for matching input artifacts" {
  local orch_file
  orch_file="$(mktemp)"
  cat <<'JSON' > "$orch_file"
{
  "stages": [
    {
      "id": "current-stage",
      "outputArtifacts": [
        {
          "path": "artifacts/{{ARTIFACT_NS}}/current/output.txt"
        }
      ]
    },
    {
      "id": "downstream-stage",
      "inputArtifacts": [
        {
          "path": "artifacts/{{ARTIFACT_NS}}/current/output.txt"
        }
      ],
      "plan": "plans/downstream.md",
      "planTemplate": "templates/downstream.tpl"
    },
    {
      "id": "skip-stage",
      "inputArtifacts": [
        {
          "path": "artifacts/{{ARTIFACT_NS}}/current/missing.txt"
        }
      ],
      "plan": "plans/skip.md"
    }
  ]
}
JSON

  run env RALPH_ARTIFACT_NS="feature-123" bash "$(agent_config_tool_path)" downstream-stages "$orch_file" "current-stage"
  [ "$status" -eq 0 ]
  trimmed="${output%$'\n'}"
  [ "$trimmed" = $'---\nSTAGE_ID=downstream-stage\nPLAN_PATH=plans/downstream.md\nPLAN_TEMPLATE=templates/downstream.tpl' ]
  rm -f "$orch_file"
}

@test "falls back to plan key for artifact namespace resolution" {
  local orch_file
  orch_file="$(mktemp)"
  cat <<'JSON' > "$orch_file"
{
  "stages": [
    {
      "id": "one",
      "outputArtifacts": [
        {
          "path": "artifacts/{{ARTIFACT_NS}}/one.txt"
        }
      ]
    },
    {
      "id": "two",
      "inputArtifacts": [
        {
          "path": "artifacts/{{ARTIFACT_NS}}/one.txt"
        }
      ],
      "plan": "plans/two.md"
    }
  ]
}
JSON

  run env RALPH_ARTIFACT_NS= RALPH_PLAN_KEY="plan-key" bash "$(agent_config_tool_path)" downstream-stages "$orch_file" "one"
  [ "$status" -eq 0 ]
  trimmed="${output%$'\n'}"
  [ "$trimmed" = $'---\nSTAGE_ID=two\nPLAN_PATH=plans/two.md\nPLAN_TEMPLATE=' ]
  rm -f "$orch_file"
}
