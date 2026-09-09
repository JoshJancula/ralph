#!/usr/bin/env bats

source "$BATS_TEST_DIRNAME/../../helper/load-lib.bash"

PLUGIN_ROOT="$REPO_ROOT/plugins/ralph-orchestrator/antigravity"
CONTRACT="$REPO_ROOT/bundle/.ralph/plugin-inputs/contracts/antigravity.json"
# The audit doc is a tracked reference, not runtime state: .ralph-workspace
# is gitignored, so a fixture there exists only on the machine that produced
# it and never in a fresh clone or CI.
AUDIT="$REPO_ROOT/docs/audits/antigravity-contract.md"
CANONICAL_WORKFLOWS=(ralph-doctor ralph-plan ralph-run ralph-status ralph-workflow)
OBSOLETE_WORKFLOWS=(ralph-agents ralph-graph ralph-orchestrate)

setup() {
  TEST_TMPDIR="$(mktemp -d)"
}

teardown() {
  rm -rf "$TEST_TMPDIR"
}

@test "Antigravity plugin contains .agents assets, MCP, and workflows without roles" {
  [ -f "$PLUGIN_ROOT/host-manifest.json" ]
  # Ralph no longer generates native agent definitions or an agents.md registry.
  [ ! -e "$PLUGIN_ROOT/agents.md" ]
  [ ! -d "$PLUGIN_ROOT/agents" ]
  [ ! -d "$PLUGIN_ROOT/roles" ]
  [ -f "$PLUGIN_ROOT/mcp_config.json" ]
  [ -f "$PLUGIN_ROOT/hooks.json" ]
  [ -f "$PLUGIN_ROOT/skills/repo-context/SKILL.md" ]
  [ -f "$PLUGIN_ROOT/.ralph-plugin-generated.json" ]

  local workflow
  for workflow in "${CANONICAL_WORKFLOWS[@]}"; do
    [ -f "$PLUGIN_ROOT/workflows/$workflow.md" ]
    [ -f "$PLUGIN_ROOT/skills/$workflow/SKILL.md" ]
  done
  for workflow in "${OBSOLETE_WORKFLOWS[@]}"; do
    [ ! -e "$PLUGIN_ROOT/workflows/$workflow.md" ]
    [ ! -e "$PLUGIN_ROOT/skills/$workflow/SKILL.md" ]
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
    --kind plan --plan "$plan" --runtime antigravity \
    --model "$exact_model" --workspace "$TEST_TMPDIR" \
    --workspace-root "$state" --agent-workspace "$agent"
  [ "$status" -eq 0 ]
  [[ "$output" == *"model: $exact_model"* ]]
  [[ "$output" == *"--model '$exact_model'"* ]]
}

@test "Antigravity closed stdin gates return without prompting or invoking" {
  local plan="$TEST_TMPDIR/plan.md" state="$TEST_TMPDIR/state" agent="$TEST_TMPDIR/agent"
  local fake_home="$TEST_TMPDIR/home"
  printf '%s\n' '# plan' >"$plan"
  mkdir -p "$state" "$agent" "$fake_home"

  # HOME/PATH are isolated so this exercises the closed-stdin gate itself
  # rather than short-circuiting on whatever ralph install happens to already
  # be usable on the machine running the suite.
  run bash -c 'exec </dev/null; exec "$@"' _ \
    env HOME="$fake_home" RALPH_HOME="$fake_home/.ralph" \
    PATH="/usr/bin:/bin:/usr/sbin:/sbin" \
    bash "$PLUGIN_ROOT/shared/ralph-plugin-bootstrap.sh" ensure --json
  [ "$status" -ne 0 ]
  [[ "$output" == *"Closed stdin"* || "$output" == *"no TTY"* ]]

  local preview confirmation_id
  preview="$(bash "$PLUGIN_ROOT/shared/ralph-plugin-exec.sh" preview \
    --kind plan --plan "$plan" --runtime antigravity \
    --model 'Exact Model (preview)' --workspace "$TEST_TMPDIR" \
    --workspace-root "$state" --agent-workspace "$agent")"
  confirmation_id="$(printf '%s\n' "$preview" | tail -n 1 | jq -r '.confirmationId')"
  [ -n "$confirmation_id" ]

  run bash -c 'exec </dev/null; bash "$1" execute \
    --kind plan --plan "$2" --runtime antigravity \
    --model "Exact Model (preview)" --workspace "$3" \
    --workspace-root "$4" --agent-workspace "$5" \
    --confirmation-id "$6" --request "Run this plan now"' _ \
    "$PLUGIN_ROOT/shared/ralph-plugin-exec.sh" "$plan" "$TEST_TMPDIR" "$state" "$agent" "$confirmation_id"
  [ "$status" -ne 0 ]
  [[ "$output" == *"real terminal"* || "$output" == *"operator terminal"* ]]
}
