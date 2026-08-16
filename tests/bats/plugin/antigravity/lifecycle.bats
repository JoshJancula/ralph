#!/usr/bin/env bats

source "$BATS_TEST_DIRNAME/../../helper/load-lib.bash"

PLUGIN_ROOT="$REPO_ROOT/plugins/ralph-orchestrator/antigravity"
CONTRACT="$REPO_ROOT/bundle/.ralph/plugin-inputs/contracts/antigravity.json"
AUDIT="$REPO_ROOT/.ralph-workspace/artifacts/plugin-beta-finish/antigravity-contract.md"

setup() {
  TEST_TMPDIR="$(mktemp -d)"
}

teardown() {
  rm -rf "$TEST_TMPDIR"
}

@test "Antigravity plugin contains .agents assets, MCP, workflows, and persona routing" {
  [ -f "$PLUGIN_ROOT/host-manifest.json" ]
  [ -f "$PLUGIN_ROOT/agents.md" ]
  [ -f "$PLUGIN_ROOT/mcp_config.json" ]
  [ -f "$PLUGIN_ROOT/hooks.json" ]
  [ -f "$PLUGIN_ROOT/skills/repo-context/SKILL.md" ]
  [ -f "$PLUGIN_ROOT/.ralph-plugin-generated.json" ]

  local id workflow
  for id in architect code-review implementation qa research security; do
    [ -f "$PLUGIN_ROOT/agents/$id.md" ]
    [ -f "$PLUGIN_ROOT/agents/$id/config.json" ]
    jq -e --arg id "$id" '.name == $id and .model == "auto"' \
      "$PLUGIN_ROOT/agents/$id/config.json"
    grep -Fq ".agents/agents/$id/config.json" "$PLUGIN_ROOT/agents.md"
  done
  for workflow in ralph-agents ralph-doctor ralph-graph ralph-orchestrate ralph-plan ralph-run ralph-status; do
    [ -f "$PLUGIN_ROOT/workflows/$workflow.md" ]
    [ -f "$PLUGIN_ROOT/skills/$workflow/SKILL.md" ]
  done

  jq -e '
    .id == "ralph-orchestrator" and
    .runtime == "antigravity" and
    .version == "0.1.0-beta.1"
  ' "$PLUGIN_ROOT/host-manifest.json"
  jq -e '
    .schemaVersion == 1 and
    .pluginVersion == "0.1.0-beta.1" and
    .sourceDescriptor == "bundle/.ralph/plugin-inputs/adapters/antigravity.json" and
    (.generatedPaths | index("mcp_config.json") != null) and
    (.generatedPaths | index("skills/repo-context/SKILL.md") != null)
  ' "$PLUGIN_ROOT/.ralph-plugin-generated.json"
  jq -e '.mcpServers | type == "object"' \
    "$PLUGIN_ROOT/mcp_config.json"
}

@test "Antigravity contract pins and opaque model text are preserved" {
  jq -e '
    .schemaVersion == 1 and .runtime == "antigravity" and
    .configRoot == ".agents" and .mcpFile == "mcp_config.json" and
    .cli == "agy" and .printFlag == "--print" and
    .conversationFlag == "--conversation" and .modelFlag == "--model" and
    .modelsCommand == "agy models" and
    .pluginCommands == ["list", "import", "install", "uninstall", "enable", "disable", "validate", "link"] and
    .modelValuePolicy == "opaque-byte-preserved"
  ' "$CONTRACT"
  grep -Fq 'opaque-byte-preserved' "$AUDIT"

  local plan="$TEST_TMPDIR/plan.md" state="$TEST_TMPDIR/state" agent="$TEST_TMPDIR/agent"
  printf '%s\n' '# plan' >"$plan"
  mkdir -p "$state" "$agent"
  local exact_model='Gemini 3.1 Pro (high)'
  run bash "$PLUGIN_ROOT/shared/ralph-plugin-exec.sh" preview \
    --kind plan --plan "$plan" --runtime antigravity --agent implementation \
    --model "$exact_model" --workspace "$TEST_TMPDIR" \
    --workspace-root "$state" --agent-workspace "$agent"
  [ "$status" -eq 0 ]
  [[ "$output" == *"model: $exact_model"* ]]
  [[ "$output" == *"--model '$exact_model'"* ]]
}

@test "Antigravity closed stdin gates return without prompting or invoking" {
  local plan="$TEST_TMPDIR/plan.md" state="$TEST_TMPDIR/state" agent="$TEST_TMPDIR/agent"
  printf '%s\n' '# plan' >"$plan"
  mkdir -p "$state" "$agent"

  run bash -c 'exec </dev/null; bash "$1" ensure --json' _ \
    "$PLUGIN_ROOT/shared/ralph-plugin-bootstrap.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"Closed stdin"* || "$output" == *"no TTY"* ]]

  local preview confirmation_id
  preview="$(bash "$PLUGIN_ROOT/shared/ralph-plugin-exec.sh" preview \
    --kind plan --plan "$plan" --runtime antigravity --agent implementation \
    --model 'Exact Model (preview)' --workspace "$TEST_TMPDIR" \
    --workspace-root "$state" --agent-workspace "$agent")"
  confirmation_id="$(printf '%s\n' "$preview" | tail -n 1 | jq -r '.confirmationId')"
  [ -n "$confirmation_id" ]

  run bash -c 'exec </dev/null; bash "$1" execute \
    --kind plan --plan "$2" --runtime antigravity --agent implementation \
    --model "Exact Model (preview)" --workspace "$3" \
    --workspace-root "$4" --agent-workspace "$5" \
    --confirmation-id "$6" --request "Run this plan now"' _ \
    "$PLUGIN_ROOT/shared/ralph-plugin-exec.sh" "$plan" "$TEST_TMPDIR" "$state" "$agent" "$confirmation_id"
  [ "$status" -ne 0 ]
  [[ "$output" == *"real terminal"* || "$output" == *"operator terminal"* ]]
}
