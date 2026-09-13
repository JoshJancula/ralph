#!/usr/bin/env bats

source "$BATS_TEST_DIRNAME/../../helper/load-lib.bash"

PLUGIN_ROOT="$REPO_ROOT/plugins/ralph-orchestrator/codex"
CANONICAL_WORKFLOWS=(ralph-doctor ralph-plan ralph-run ralph-status ralph-workflow)
OBSOLETE_WORKFLOWS=(ralph-agents ralph-graph ralph-orchestrate)

setup() {
  TEST_TMPDIR="$(mktemp -d)"
}

teardown() {
  rm -rf "$TEST_TMPDIR"
}

@test "Codex plugin contains manifest, skill, hooks, MCP, workflows, and metadata" {
  [ -f "$PLUGIN_ROOT/host-manifest.json" ]
  [ -f "$PLUGIN_ROOT/.codex-plugin/plugin.json" ]
  [ -f "$PLUGIN_ROOT/skills/repo-context/SKILL.md" ]
  [ -f "$PLUGIN_ROOT/hooks.json" ]
  [ -f "$PLUGIN_ROOT/mcp.example.toml" ]
  [ -f "$PLUGIN_ROOT/.ralph-plugin-generated.json" ]

  [ ! -d "$PLUGIN_ROOT/agents" ]
  [ ! -d "$PLUGIN_ROOT/roles" ]

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
    .runtime == "codex" and
    .version == "0.1.0-beta.1" and
    .bootstrap == "shared/ralph-plugin-bootstrap.sh" and
    .exec == "shared/ralph-plugin-exec.sh"
  ' "$PLUGIN_ROOT/host-manifest.json"
  jq -e '
    .name == "ralph-orchestrator" and
    .version == "0.1.0-beta.1" and
    .skills == "./skills/" and
    .interface.displayName == "Ralph Orchestrator" and
    has("_generated") == false
  ' "$PLUGIN_ROOT/.codex-plugin/plugin.json"
  jq -e '
    .schemaVersion == 1 and
    .pluginVersion == "0.1.0-beta.1" and
    .sourceDescriptor == "bundle/.ralph/plugin-inputs/adapters/codex.json" and
    (.generatedPaths | index("skills/repo-context/SKILL.md") != null)
  ' "$PLUGIN_ROOT/.ralph-plugin-generated.json"
  grep -Fq '[mcp_servers.ralph]' "$PLUGIN_ROOT/mcp.example.toml"
  grep -Fq 'scripts/sync-plugin-assets.sh' "$PLUGIN_ROOT/skills/repo-context/SKILL.md"
}

@test "Codex install and removal preserve native config and explicit non-git repository roots" {
  local project="$TEST_TMPDIR/project"
  local repo_one="$TEST_TMPDIR/repo-one"
  local repo_two="$TEST_TMPDIR/repo-two"
  local state_root="$TEST_TMPDIR/state"
  local native_config="$project/.codex/config.toml"
  local cache_dir="$TEST_TMPDIR/home/.codex/plugins/ralph-orchestrator"
  local before after output plan

  mkdir -p "$project/.codex" "$repo_one" "$repo_two" "$state_root" "$cache_dir"
  cat >"$native_config" <<'EOF'
# operator-owned Codex configuration
[projects."/tmp/repo-one"]
trust_level = "trusted"

[mcp_servers.native]
command = "native-server"
EOF
  before="$(shasum -a 256 "$native_config" | awk '{print $1}')"

  cp -R "$PLUGIN_ROOT" "$cache_dir/codex"
  [ -f "$cache_dir/codex/host-manifest.json" ]
  after="$(shasum -a 256 "$native_config" | awk '{print $1}')"
  [ "$before" = "$after" ]

  rm -rf "$cache_dir/codex"
  [ ! -e "$cache_dir/codex" ]
  after="$(shasum -a 256 "$native_config" | awk '{print $1}')"
  [ "$before" = "$after" ]

  plan="$repo_one/plan.md"
  printf '%s\n' '# plan' >"$plan"
  ! git -C "$project" rev-parse --is-inside-work-tree >/dev/null 2>&1
  output="$(
    cd "$project"
    bash "$PLUGIN_ROOT/shared/ralph-plugin-exec.sh" preview \
      --kind plan \
      --plan "$plan" \
      --runtime codex \
      --workspace "$project" \
      --workspace-root "$state_root" \
      --agent-workspace "$repo_one"
  )"
  grep -Fq "projectRoot: $project" <<<"$output"
  grep -Fq "stateRoot: $state_root" <<<"$output"
  grep -Fq "agentRoot: $repo_one" <<<"$output"
  grep -Fq -- "--workspace '$project'" <<<"$output"
  grep -Fq -- "--workspace-root '$state_root'" <<<"$output"
  grep -Fq -- "--agent-workspace '$repo_one'" <<<"$output"
  [ -d "$repo_two" ]
}

@test "Codex hooks are allowlisted and resolve to generated files" {
  local command hook_path
  while IFS= read -r command; do
    [[ "$command" == .codex/hooks/* ]]
    hook_path="${command#.codex/}"
    [ -f "$PLUGIN_ROOT/$hook_path" ]
  done < <(jq -r '.. | objects | .command? // empty' "$PLUGIN_ROOT/hooks.json")

  [ "$(jq '[.. | objects | .command? // empty] | length' "$PLUGIN_ROOT/hooks.json")" -eq 9 ]
}
