#!/usr/bin/env bats

source "$BATS_TEST_DIRNAME/../../helper/load-lib.bash"

GENERATOR_PY="$REPO_ROOT/bundle/.ralph/python/sync_plugin_assets.py"
GENERATOR_SH="$REPO_ROOT/scripts/sync-plugin-assets.sh"
RUNTIME_SYNC="$REPO_ROOT/scripts/sync-runtime-assets.sh"

setup() {
  TEST_TMPDIR="$(mktemp -d)"
}

teardown() {
  rm -rf "$TEST_TMPDIR"
}

generate() {
  python3 "$GENERATOR_PY" --repo-root "$1"
}

check_generate() {
  python3 "$GENERATOR_PY" --repo-root "$1" --check
}

tree_checksum() {
  (
    cd "$1/plugins/ralph-orchestrator/claude"
    find . -type f ! -name '.DS_Store' | LC_ALL=C sort | while IFS= read -r path; do
      printf '%s ' "$path"
      if command -v shasum >/dev/null 2>&1; then
        shasum -a 256 "$path" | awk '{print $1}'
      else
        sha256sum "$path" | awk '{print $1}'
      fi
      python3 -c 'import os,stat,sys; print("%04o"%stat.S_IMODE(os.stat(sys.argv[1]).st_mode))' "$path"
    done
  )
}

write_valid_fixture() {
  local repo="$1"
  mkdir -p \
    "$repo/bundle/.ralph/plugin-inputs/adapters" \
    "$repo/bundle/.ralph/plugin-inputs/contracts" \
    "$repo/bundle/.ralph/plugin-inputs/templates/claude" \
    "$repo/bundle/.ralph/plugin-inputs/workflows" \
    "$repo/bundle/.ralph/plugin-inputs/shared" \
    "$repo/bundle/.claude/agents/architect" \
    "$repo/bundle/.opencode/plugins" \
    "$repo/plugins/ralph-orchestrator"
  printf 'agent body\n' >"$repo/bundle/.claude/agents/architect/architect.md"
  printf 'export const Plugin = {}\n' >"$repo/bundle/.opencode/plugins/ralph-runtime-hooks.ts"
  printf '#!/bin/bash\necho bootstrap\n' >"$repo/bundle/.ralph/plugin-inputs/shared/ralph-plugin-bootstrap.sh"
  printf '#!/bin/bash\necho exec\n' >"$repo/bundle/.ralph/plugin-inputs/shared/ralph-plugin-exec.sh"
  printf '{\n  "id": "{{PLUGIN_ID}}",\n  "runtime": "{{RUNTIME}}",\n  "version": "{{PLUGIN_VERSION}}",\n  "bootstrap": "{{SHARED_BOOTSTRAP_REL}}",\n  "exec": "{{SHARED_EXEC_REL}}"\n}\n' \
    >"$repo/bundle/.ralph/plugin-inputs/templates/claude/host-manifest.json"
  printf '# status\nbootstrap={{SHARED_BOOTSTRAP_REL}}\nruntime={{RUNTIME}}\n' \
    >"$repo/bundle/.ralph/plugin-inputs/workflows/ralph-status.md"
  printf '0.1.0-beta.1\n' >"$repo/plugins/ralph-orchestrator/VERSION"
  printf 'readme\n' >"$repo/plugins/ralph-orchestrator/README.md"

  cat >"$repo/bundle/.ralph/plugin-inputs/plugin.json" <<'EOF'
{
  "schemaVersion": 1,
  "id": "ralph-orchestrator",
  "displayName": "Ralph Orchestrator",
  "versionFile": "plugins/ralph-orchestrator/VERSION",
  "outputRoot": "plugins/ralph-orchestrator",
  "engine": {
    "delivery": "external-cli",
    "command": "ralph",
    "pluginApi": 1
  },
  "workflows": ["ralph-status"],
  "contracts": {
    "antigravity": "bundle/.ralph/plugin-inputs/contracts/antigravity.json",
    "opencode": "bundle/.ralph/plugin-inputs/contracts/opencode.json"
  },
  "adapters": ["claude"]
}
EOF

  cat >"$repo/bundle/.ralph/plugin-inputs/adapters/claude.json" <<'EOF'
{
  "schemaVersion": 1,
  "runtime": "claude",
  "outputDirectory": "plugins/ralph-orchestrator/claude",
  "contract": null,
  "capabilities": {
    "nativeAgents": true,
    "nativeHooks": true,
    "mcp": true,
    "rules": false,
    "skills": true,
    "workflows": true
  },
  "copies": [
    {
      "source": "bundle/.claude/agents/architect/architect.md",
      "destination": "agents/architect.md",
      "mode": "0644"
    },
    {
      "source": "bundle/.ralph/plugin-inputs/shared/ralph-plugin-bootstrap.sh",
      "destination": "shared/ralph-plugin-bootstrap.sh",
      "mode": "0755"
    },
    {
      "source": "bundle/.ralph/plugin-inputs/shared/ralph-plugin-exec.sh",
      "destination": "shared/ralph-plugin-exec.sh",
      "mode": "0755"
    }
  ],
  "templates": [
    {
      "source": "bundle/.ralph/plugin-inputs/templates/claude/host-manifest.json",
      "destination": "host-manifest.json",
      "mode": "0644"
    },
    {
      "source": "bundle/.ralph/plugin-inputs/workflows/ralph-status.md",
      "destination": "workflows/ralph-status.md",
      "mode": "0644"
    }
  ]
}
EOF

  cat >"$repo/bundle/.ralph/plugin-inputs/contracts/opencode.json" <<'EOF'
{
  "schemaVersion": 1,
  "runtime": "opencode",
  "cliVersion": "1.3.17",
  "pluginPackageVersion": "1.3.15",
  "moduleFormat": "ESM",
  "pluginExport": "Plugin",
  "typeDeclaration": "@opencode-ai/plugin/dist/index.d.ts",
  "typeDeclarationSha256": "ea181db7cd8f13c626356b7982066cae9f7acf0f27934e738620b441b97bde76",
  "requiredHooks": [
    "permission.ask",
    "tool.execute.before",
    "tool.execute.after"
  ],
  "moduleSource": "bundle/.opencode/plugins/ralph-runtime-hooks.ts"
}
EOF

  cat >"$repo/bundle/.ralph/plugin-inputs/contracts/antigravity.json" <<'EOF'
{
  "schemaVersion": 1,
  "runtime": "antigravity",
  "configRoot": ".agents",
  "mcpFile": "mcp_config.json",
  "cli": "agy",
  "printFlag": "--print",
  "conversationFlag": "--conversation",
  "modelFlag": "--model",
  "modelsCommand": "agy models",
  "pluginCommands": [
    "list",
    "import",
    "install",
    "uninstall",
    "enable",
    "disable",
    "validate",
    "link"
  ],
  "modelValuePolicy": "opaque-byte-preserved"
}
EOF
}

@test "two identical generations are byte-identical and leave a clean no-op check" {
  local repo="$TEST_TMPDIR/identical"
  write_valid_fixture "$repo"

  run generate "$repo"
  [ "$status" -eq 0 ]
  [ -z "$output" ]

  local first
  first="$(tree_checksum "$repo")"

  run generate "$repo"
  [ "$status" -eq 0 ]
  [ -z "$output" ]

  local second
  second="$(tree_checksum "$repo")"
  [ "$first" = "$second" ]

  run check_generate "$repo"
  [ "$status" -eq 0 ]
  [ -z "$output" ]

  grep -q 'by scripts/sync-plugin-assets.sh' "$repo/plugins/ralph-orchestrator/claude/agents/architect.md"
  grep -q 'by scripts/sync-plugin-assets.sh' "$repo/plugins/ralph-orchestrator/claude/shared/ralph-plugin-bootstrap.sh"
  grep -q 'by scripts/sync-plugin-assets.sh' "$repo/plugins/ralph-orchestrator/claude/workflows/ralph-status.md"
  jq -e '
    (._generated | test("by scripts/sync-plugin-assets.sh")) and
    .id == "ralph-orchestrator" and
    .runtime == "claude" and
    .version == "0.1.0-beta.1" and
    .bootstrap == "shared/ralph-plugin-bootstrap.sh" and
    .exec == "shared/ralph-plugin-exec.sh"
  ' "$repo/plugins/ralph-orchestrator/claude/host-manifest.json"
  jq -e '
    .schemaVersion == 1 and
    .pluginVersion == "0.1.0-beta.1" and
    .sourceDescriptor == "bundle/.ralph/plugin-inputs/adapters/claude.json" and
    .generatedPaths == [
      ".ralph-plugin-generated.json",
      "agents/architect.md",
      "host-manifest.json",
      "shared/ralph-plugin-bootstrap.sh",
      "shared/ralph-plugin-exec.sh",
      "workflows/ralph-status.md"
    ]
  ' "$repo/plugins/ralph-orchestrator/claude/.ralph-plugin-generated.json"
  grep -q 'bootstrap=../shared/ralph-plugin-bootstrap.sh' "$repo/plugins/ralph-orchestrator/claude/workflows/ralph-status.md"
}

@test "controlled drift is reported and a clean tree is a no-op" {
  local repo="$TEST_TMPDIR/drift"
  write_valid_fixture "$repo"
  run generate "$repo"
  [ "$status" -eq 0 ]

  run check_generate "$repo"
  [ "$status" -eq 0 ]
  [ -z "$output" ]

  printf 'drifted\n' >>"$repo/plugins/ralph-orchestrator/claude/workflows/ralph-status.md"
  run check_generate "$repo"
  [ "$status" -eq 1 ]
  [[ "$output" == *"changed: plugins/ralph-orchestrator/claude/workflows/ralph-status.md"* ]]
  [[ "$output" != *"added:"* ]]

  printf 'operator-owned\n' >"$repo/plugins/ralph-orchestrator/claude/operator-notes.txt"
  run generate "$repo"
  [ "$status" -eq 0 ]
  [ -f "$repo/plugins/ralph-orchestrator/claude/operator-notes.txt" ]
  if grep -q 'drifted' "$repo/plugins/ralph-orchestrator/claude/workflows/ralph-status.md"; then
    echo "write mode left drifted content in place" >&2
    return 1
  fi

  run check_generate "$repo"
  [ "$status" -eq 1 ]
  [[ "$output" == *"removed: plugins/ralph-orchestrator/claude/operator-notes.txt"* ]]
}

@test "write mode removes only previous-manifest paths" {
  local repo="$TEST_TMPDIR/manifest-remove"
  write_valid_fixture "$repo"
  run generate "$repo"
  [ "$status" -eq 0 ]

  printf 'stale generated\n' >"$repo/plugins/ralph-orchestrator/claude/obsolete.md"
  python3 -c '
import json,sys
path=sys.argv[1]
data=json.load(open(path))
paths=list(data["generatedPaths"])
if "obsolete.md" not in paths:
    paths.append("obsolete.md")
data["generatedPaths"]=sorted(paths)
json.dump(data, open(path,"w"), indent=2, sort_keys=True)
open(path,"a").write("\n")
' "$repo/plugins/ralph-orchestrator/claude/.ralph-plugin-generated.json"
  printf 'keep me\n' >"$repo/plugins/ralph-orchestrator/claude/operator-notes.txt"

  run generate "$repo"
  [ "$status" -eq 0 ]
  [ ! -f "$repo/plugins/ralph-orchestrator/claude/obsolete.md" ]
  [ -f "$repo/plugins/ralph-orchestrator/claude/operator-notes.txt" ]
}

@test "path containment rejects output outside plugins/ralph-orchestrator" {
  local repo="$TEST_TMPDIR/containment"
  write_valid_fixture "$repo"
  python3 -c '
import json,sys
path=sys.argv[1]
data=json.load(open(path))
data["outputDirectory"]="plugins/other-plugin/claude"
json.dump(data, open(path,"w"), indent=2)
open(path,"a").write("\n")
' "$repo/bundle/.ralph/plugin-inputs/adapters/claude.json"
  run generate "$repo"
  [ "$status" -ne 0 ]
  [[ "$output" == *"plugins/ralph-orchestrator"* ]]
  [ ! -d "$repo/plugins/other-plugin" ]
}

@test "path containment rejects destination escape from the adapter directory" {
  local repo="$TEST_TMPDIR/adapter-escape"
  write_valid_fixture "$repo"
  python3 -c '
import json,sys
path=sys.argv[1]
data=json.load(open(path))
data["copies"][0]["destination"]="../README.md"
json.dump(data, open(path,"w"), indent=2)
open(path,"a").write("\n")
' "$repo/bundle/.ralph/plugin-inputs/adapters/claude.json"
  local before
  before="$(cat "$repo/plugins/ralph-orchestrator/README.md")"
  run generate "$repo"
  [ "$status" -ne 0 ]
  [[ "$output" == *"escape"* || "$output" == *"outside"* || "$output" == *"containment"* || "$output" == *"traversal"* ]]
  [ "$(cat "$repo/plugins/ralph-orchestrator/README.md")" = "$before" ]
}

@test "runtime sync never calls plugin sync and plugin sync only checks runtime assets" {
  if grep -E 'sync-plugin-assets' "$RUNTIME_SYNC"; then
    echo "runtime sync must not invoke plugin sync" >&2
    return 1
  fi
  grep -q 'sync-runtime-assets.sh" --check' "$GENERATOR_SH"
  grep -q 'sync_plugin_assets.py' "$GENERATOR_SH"
  run bash "$GENERATOR_SH" --help
  [ "$status" -eq 1 ]
  [[ "$output" == *"--check"* ]]
  [[ "$output" == *"--skip-runtime-check"* ]]
}
