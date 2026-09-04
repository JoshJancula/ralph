#!/usr/bin/env bats

source "$BATS_TEST_DIRNAME/../../helper/load-lib.bash"

PLUGIN_ROOT="$REPO_ROOT/plugins/ralph-orchestrator/opencode"
CONTRACT="$REPO_ROOT/bundle/.ralph/plugin-inputs/contracts/opencode.json"
DECLARATION="$REPO_ROOT/bundle/.opencode/node_modules/@opencode-ai/plugin/dist/index.d.ts"
GENERATOR="$REPO_ROOT/bundle/.ralph/python/sync_plugin_assets.py"
CANONICAL_WORKFLOWS=(ralph-doctor ralph-plan ralph-run ralph-status ralph-workflow)
OBSOLETE_WORKFLOWS=(ralph-agents ralph-graph ralph-orchestrate)

setup() {
  TEST_TMPDIR="$(mktemp -d)"
}

teardown() {
  rm -rf "$TEST_TMPDIR"
}

@test "OpenCode package contains the contract-backed module and generated assets" {
  [ -f "$PLUGIN_ROOT/host-manifest.json" ]
  [ -f "$PLUGIN_ROOT/plugins/ralph-runtime-hooks.ts" ]
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
    .runtime == "opencode" and
    .version == "0.1.0-beta.1" and
    .bootstrap == "shared/ralph-plugin-bootstrap.sh" and
    .exec == "shared/ralph-plugin-exec.sh"
  ' "$PLUGIN_ROOT/host-manifest.json"
  jq -e '
    .schemaVersion == 1 and
    .pluginVersion == "0.1.0-beta.1" and
    .sourceDescriptor == "bundle/.ralph/plugin-inputs/adapters/opencode.json" and
    (.generatedPaths | index("plugins/ralph-runtime-hooks.ts") != null)
  ' "$PLUGIN_ROOT/.ralph-plugin-generated.json"
}

@test "OpenCode module matches the pinned declaration and hook contract" {
  local expected_hash
  expected_hash="$(jq -r '.typeDeclarationSha256' "$CONTRACT")"
  [ "$(shasum -a 256 "$DECLARATION" | awk '{print $1}')" = "$expected_hash" ]

  local module="$REPO_ROOT/bundle/.opencode/plugins/ralph-runtime-hooks.ts"
  grep -Eq 'export[[:space:]]+const[[:space:]]+[A-Za-z0-9_]+[[:space:]]*:[[:space:]]*Plugin' "$module"
  local hook
  while IFS= read -r hook; do
    grep -Fq "\"$hook\"" "$module"
  done < <(jq -r '.requiredHooks[]' "$CONTRACT")
  tail -n +2 "$PLUGIN_ROOT/plugins/ralph-runtime-hooks.ts" | cmp -s - "$module"
}

@test "OpenCode renderer blocks an incompatible host declaration" {
  run python3 - "$GENERATOR" <<'PY'
import importlib.util
import os
import sys

spec = importlib.util.spec_from_file_location("sync_plugin_assets", sys.argv[1])
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
loaded = module.plugin_inputs.load_plugin_inputs(os.environ["REPO_ROOT"])
adapter = next(item for item in loaded["adapters"] if item["runtime"] == "opencode")
adapter["resolvedContract"] = dict(adapter["resolvedContract"])
adapter["resolvedContract"]["typeDeclarationSha256"] = "0" * 64
try:
    module._render_adapter(loaded, adapter)
except module.SyncPluginError as exc:
    message = str(exc)
    assert "detected" in message and "expected" in message, message
    raise SystemExit(0)
raise SystemExit("incompatible host was accepted")
PY
  [ "$status" -eq 0 ]
}

@test "OpenCode native JSONC layers retain bytes and later layers win" {
  local project="$TEST_TMPDIR/project"
  local xdg="$TEST_TMPDIR/xdg"
  local global_config="$xdg/opencode/config.jsonc"
  local project_config="$project/opencode.jsonc"
  mkdir -p "$project" "$(dirname "$global_config")"
  cat >"$global_config" <<'EOF'
{
  // operator-owned global comment
  "provider": { "selected": "global" },
  "native": { "keep": true }
}
EOF
  cat >"$project_config" <<'EOF'
{
  /* operator-owned project comment */
  "provider": { "selected": "project" },
  "projectOnly": true
}
EOF

  local global_before project_before merged
  global_before="$(shasum -a 256 "$global_config" | awk '{print $1}')"
  project_before="$(shasum -a 256 "$project_config" | awk '{print $1}')"

  # The OpenCode adapter reads layers in native precedence order while writing
  # only an ephemeral effective config.
  source "$REPO_ROOT/bundle/.ralph/bash-lib/run-plan/run-plan-invoke-opencode.sh"
  merged="$(_run_plan_invoke_opencode_merge_config_layers "$project" "$xdg")"
  jq -e '.provider.selected == "project" and .native.keep == true and .projectOnly == true' "$merged"
  [ "$(shasum -a 256 "$global_config" | awk '{print $1}')" = "$global_before" ]
  [ "$(shasum -a 256 "$project_config" | awk '{print $1}')" = "$project_before" ]
  grep -Fq 'operator-owned global comment' "$global_config"
  grep -Fq 'operator-owned project comment' "$project_config"
}

@test "OpenCode owned copy install and remove preserve unrelated project files" {
  local project="$TEST_TMPDIR/project"
  local target="$project/.opencode"
  local keep="$target/custom/user-config.json"

  mkdir -p "$target/plugins" "$target/skills" "$target/custom"
  printf 'keep-me\n' >"$keep"

  cp "$PLUGIN_ROOT/plugins/ralph-runtime-hooks.ts" "$target/plugins/ralph-runtime-hooks.ts"
  cp -R "$PLUGIN_ROOT/skills/." "$target/skills/"
  [ -f "$target/plugins/ralph-runtime-hooks.ts" ]
  [ -f "$target/skills/ralph-workflow/SKILL.md" ]
  [ ! -e "$target/agents" ]
  [ "$(cat "$keep")" = "keep-me" ]

  # Modified copied skill must not force removal of unrelated operator files.
  printf 'operator-edit\n' >>"$target/skills/ralph-plan/SKILL.md"
  rm -rf "$target/plugins" "$target/skills"
  [ -f "$keep" ]
  [ "$(cat "$keep")" = "keep-me" ]
}
