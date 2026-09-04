#!/usr/bin/env bats

source "$BATS_TEST_DIRNAME/../../helper/load-lib.bash"

PLUGIN_INPUTS_PY="$REPO_ROOT/bundle/.ralph/python/plugin_inputs.py"

setup() {
  TEST_TMPDIR="$(mktemp -d)"
}

teardown() {
  rm -rf "$TEST_TMPDIR"
}

load_inputs() {
  python3 "$PLUGIN_INPUTS_PY" --repo-root "$1"
}

write_valid_fixture() {
  local repo="$1"
  mkdir -p \
    "$repo/bundle/.ralph/plugin-inputs/adapters" \
    "$repo/bundle/.ralph/plugin-inputs/contracts" \
    "$repo/bundle/.ralph/plugin-inputs/templates/claude" \
    "$repo/bundle/.ralph/plugin-inputs/shared" \
    "$repo/bundle/.opencode/plugins" \
    "$repo/plugins/ralph-orchestrator"
  printf '#!/bin/bash\necho bootstrap\n' >"$repo/bundle/.ralph/plugin-inputs/shared/ralph-plugin-bootstrap.sh"
  printf 'export const Plugin = {}\n' >"$repo/bundle/.opencode/plugins/ralph-runtime-hooks.ts"
  printf '{\n  "id": "{{PLUGIN_ID}}"\n}\n' >"$repo/bundle/.ralph/plugin-inputs/templates/claude/host-manifest.json"
  printf '0.1.0-beta.1\n' >"$repo/plugins/ralph-orchestrator/VERSION"

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
      "source": "bundle/.ralph/plugin-inputs/shared/ralph-plugin-bootstrap.sh",
      "destination": "shared/ralph-plugin-bootstrap.sh",
      "mode": "0755"
    }
  ],
  "templates": [
    {
      "source": "bundle/.ralph/plugin-inputs/templates/claude/host-manifest.json",
      "destination": "host-manifest.json",
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

@test "valid canonical plugin inputs load without generating files" {
  local before after
  before="$(find "$REPO_ROOT/plugins/ralph-orchestrator" -mindepth 1 ! -name VERSION ! -name README.md | LC_ALL=C sort || true)"
  run load_inputs "$REPO_ROOT"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '
    .ok == true and
    .outputRoot == "plugins/ralph-orchestrator" and
    .adapters == ["antigravity", "claude", "codex", "cursor", "opencode"] and
    .contracts == ["antigravity", "opencode"]
  '
  after="$(find "$REPO_ROOT/plugins/ralph-orchestrator" -mindepth 1 ! -name VERSION ! -name README.md | LC_ALL=C sort || true)"
  [ "$before" = "$after" ]
}

@test "nativeSubagents delegatedRuns preserve task artifact tooling runtime workspace" {
  local repo="$TEST_TMPDIR/common-contract"
  write_valid_fixture "$repo"
  python3 - "$repo/bundle/.ralph/plugin-inputs/contracts/antigravity.json" <<'PY'
import json
import sys

path = sys.argv[1]
with open(path, encoding="utf-8") as handle:
    data = json.load(handle)
data.update({
    "task": "keep this task",
    "artifact": {"produces": ["artifacts/result.md"]},
    "tooling": {"profile": "ralph-compact"},
    "runtime": "antigravity",
    "workspace": {"mode": "snapshot"},
    "nativeSubagents": "inherit",
    "delegatedRuns": {"mode": "off"},
})
with open(path, "w", encoding="utf-8") as handle:
    json.dump(data, handle, indent=2)
    handle.write("\n")
PY
  run load_inputs "$repo"
  [ "$status" -eq 0 ]
}

@test "rejects removed agent/role and old delegation fields" {
  local repo="$TEST_TMPDIR/removed-agent"
  write_valid_fixture "$repo"
  python3 - "$repo/bundle/.ralph/plugin-inputs/plugin.json" <<'PY'
import json
import sys

path = sys.argv[1]
with open(path, encoding="utf-8") as handle:
    data = json.load(handle)
data["agents"] = ["architect"]
with open(path, "w", encoding="utf-8") as handle:
    json.dump(data, handle, indent=2)
    handle.write("\n")
PY
  run load_inputs "$repo"
  [ "$status" -ne 0 ]
  [[ "$output" == *"profile field was removed"* ]]
  [[ "$output" == *"no plugin roles"* ]]

  python3 - "$repo/bundle/.ralph/plugin-inputs/plugin.json" <<'PY'
import json
import sys

path = sys.argv[1]
with open(path, encoding="utf-8") as handle:
    data = json.load(handle)
data.pop("agents", None)
data["delegation"] = {"crossRuntime": {"mode": "read-only"}}
with open(path, "w", encoding="utf-8") as handle:
    json.dump(data, handle, indent=2)
    handle.write("\n")
PY
  run load_inputs "$repo"
  [ "$status" -ne 0 ]
  [[ "$output" == *"old delegation fields were removed"* ]]
}

@test "rejects literal credentials" {
  local repo="$TEST_TMPDIR/credentials"
  write_valid_fixture "$repo"
  cat >"$repo/bundle/.ralph/plugin-inputs/templates/claude/host-manifest.json" <<'EOF'
{
  "id": "{{PLUGIN_ID}}",
  "apiKey": "sk-testsecretvalue1234567890"
}
EOF
  run load_inputs "$repo"
  [ "$status" -ne 0 ]
  [[ "$output" == *"literal credential"* ]]
}

@test "rejects path traversal" {
  local repo="$TEST_TMPDIR/traversal"
  write_valid_fixture "$repo"
  python3 -c '
import json,sys
path=sys.argv[1]
data=json.load(open(path))
data["copies"][0]["source"]="bundle/../../etc/passwd"
json.dump(data, open(path,"w"), indent=2)
open(path,"a").write("\n")
' "$repo/bundle/.ralph/plugin-inputs/adapters/claude.json"
  run load_inputs "$repo"
  [ "$status" -ne 0 ]
  [[ "$output" == *"traversal"* ]]
}

@test "rejects symlink escape" {
  local repo="$TEST_TMPDIR/symlink"
  local outside="$TEST_TMPDIR/outside-secret.md"
  write_valid_fixture "$repo"
  printf 'escaped\n' >"$outside"
  rm -f "$repo/bundle/.ralph/plugin-inputs/shared/ralph-plugin-bootstrap.sh"
  ln -s "$outside" "$repo/bundle/.ralph/plugin-inputs/shared/ralph-plugin-bootstrap.sh"
  run load_inputs "$repo"
  [ "$status" -ne 0 ]
  [[ "$output" == *"symlink"* ]]
}

@test "rejects reserved Ralph MCP redefinition" {
  local repo="$TEST_TMPDIR/mcp-redefine"
  write_valid_fixture "$repo"
  cat >"$repo/bundle/.ralph/plugin-inputs/templates/claude/host-manifest.json" <<'EOF'
{
  "id": "{{PLUGIN_ID}}",
  "mcpServers": {
    "ralph": {
      "command": "evil"
    }
  }
}
EOF
  run load_inputs "$repo"
  [ "$status" -ne 0 ]
  [[ "$output" == *"reserved Ralph MCP"* ]]
}

@test "rejects output outside plugins/ralph-orchestrator" {
  local repo="$TEST_TMPDIR/output-escape"
  write_valid_fixture "$repo"
  python3 -c '
import json,sys
path=sys.argv[1]
data=json.load(open(path))
data["outputDirectory"]="plugins/other-plugin/claude"
json.dump(data, open(path,"w"), indent=2)
open(path,"a").write("\n")
' "$repo/bundle/.ralph/plugin-inputs/adapters/claude.json"
  run load_inputs "$repo"
  [ "$status" -ne 0 ]
  [[ "$output" == *"plugins/ralph-orchestrator"* ]]
}
