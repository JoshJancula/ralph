#!/usr/bin/env bats

source "$BATS_TEST_DIRNAME/../../helper/load-lib.bash"

RUNTIMES=(antigravity claude codex cursor opencode)
PLUGIN_REL="plugins/ralph-orchestrator"
GENERATOR_REL="bundle/.ralph/python/sync_plugin_assets.py"
INPUTS_REL="bundle/.ralph/python/plugin_inputs.py"

setup() {
  TEST_TMPDIR="$(mktemp -d)"
  MATRIX_REPO="$TEST_TMPDIR/repo"
  mkdir -p "$MATRIX_REPO/plugins/ralph-orchestrator"
  cp -R "$REPO_ROOT/bundle" "$MATRIX_REPO/bundle"
  cp "$REPO_ROOT/plugins/ralph-orchestrator/VERSION" \
    "$MATRIX_REPO/plugins/ralph-orchestrator/VERSION"
}

teardown() {
  rm -rf "$TEST_TMPDIR"
}

matrix_check() {
  local runtime="$1" check="$2"
  shift 2
  MATRIX_DETAIL=""
  if "$@"; then
    return 0
  fi
  printf 'adapter=%s check=%s: %s\n' \
    "$runtime" "$check" "${MATRIX_DETAIL:-command failed}" >&2
  return 1
}

generate_matrix_repo() {
  python3 "$MATRIX_REPO/$GENERATOR_REL" --repo-root "$MATRIX_REPO" >/dev/null
}

generated_checksum() {
  local runtime="$1"
  python3 - "$MATRIX_REPO/$PLUGIN_REL/$runtime" <<'PY'
import hashlib
import os
import stat
import sys

root = sys.argv[1]
rows = []
for directory, _, filenames in os.walk(root):
    for name in filenames:
        path = os.path.join(directory, name)
        rel = os.path.relpath(path, root).replace(os.sep, "/")
        with open(path, "rb") as handle:
            digest = hashlib.sha256(handle.read()).hexdigest()
        mode = stat.S_IMODE(os.stat(path).st_mode)
        rows.append(f"{rel} {digest} {mode:04o}")
print("\n".join(sorted(rows)))
PY
}

check_deterministic_output() {
  local runtime="$1" first second
  generate_matrix_repo
  first="$(generated_checksum "$runtime")"
  generate_matrix_repo
  second="$(generated_checksum "$runtime")"
  if [ "$first" != "$second" ]; then
    MATRIX_DETAIL="two generations produced different bytes or modes"
    return 1
  fi
}

check_version() {
  local runtime="$1" root="$MATRIX_REPO/$PLUGIN_REL/$1" expected
  expected="0.1.0-beta.1"
  if [ "$(cat "$MATRIX_REPO/$PLUGIN_REL/VERSION")" != "$expected" ]; then
    MATRIX_DETAIL="VERSION is not $expected"
    return 1
  fi
  if ! jq -e --arg runtime "$runtime" --arg expected "$expected" '
    .id == "ralph-orchestrator" and
    .runtime == $runtime and
    .version == $expected
  ' "$root/host-manifest.json" >/dev/null; then
    MATRIX_DETAIL="host-manifest.json has the wrong runtime or version"
    return 1
  fi
  if ! jq -e --arg expected "$expected" '
    .schemaVersion == 1 and .pluginVersion == $expected
  ' "$root/.ralph-plugin-generated.json" >/dev/null; then
    MATRIX_DETAIL="generation manifest has the wrong schema or plugin version"
    return 1
  fi
  if [ "$runtime" = "claude" ]; then
    if ! jq -e --arg expected "$expected" '.version == $expected' \
      "$root/.claude-plugin/plugin.json" >/dev/null ||
      ! jq -e --arg expected "$expected" '.plugins[0].version == $expected' \
        "$root/.claude-plugin/marketplace.json" >/dev/null; then
      MATRIX_DETAIL="Claude package metadata has the wrong version"
      return 1
    fi
  fi
}

check_native_schema() {
  local runtime="$1" root="$MATRIX_REPO/$PLUGIN_REL/$1"
  case "$runtime" in
    antigravity)
      jq -e '.mcpServers | type == "object"' "$root/mcp_config.json" >/dev/null || {
        MATRIX_DETAIL="mcp_config.json is not a native Antigravity object"; return 1;
      }
      [ ! -d "$root/agents" ] || {
        MATRIX_DETAIL="Antigravity package must not ship agents/"; return 1;
      }
      [ ! -d "$root/roles" ] || {
        MATRIX_DETAIL="Antigravity package must not ship roles/"; return 1;
      }
      [ -f "$root/workflows/ralph-workflow.md" ] || {
        MATRIX_DETAIL="Antigravity package missing ralph-workflow"; return 1;
      }
      jq -e . "$root/hooks.json" >/dev/null || {
        MATRIX_DETAIL="hooks.json is not valid JSON"; return 1;
      }
      ;;
    claude)
      jq -e '.name == "ralph-orchestrator" and (.description | type == "string")' \
        "$root/.claude-plugin/plugin.json" >/dev/null || {
        MATRIX_DETAIL=".claude-plugin/plugin.json is not a native Claude schema"; return 1;
      }
      jq -e '.name == "ralph-plugins" and (.plugins | type == "array")' \
        "$root/.claude-plugin/marketplace.json" >/dev/null || {
        MATRIX_DETAIL="marketplace.json is not a native Claude schema"; return 1;
      }
      jq -e '.mcpServers | type == "object"' "$root/.mcp.json" >/dev/null || {
        MATRIX_DETAIL=".mcp.json is not a native Claude MCP schema"; return 1;
      }
      jq -e . "$root/hooks/hooks.json" >/dev/null || {
        MATRIX_DETAIL="hooks/hooks.json is not valid JSON"; return 1;
      }
      ;;
    codex)
      if ! python3 - "$root" <<'PY'
import glob
import json
import os
import sys
import tomllib

root = sys.argv[1]
agents = glob.glob(os.path.join(root, "agents", "*.toml"))
assert not agents, "Codex package must not ship agents"
roles = glob.glob(os.path.join(root, "roles", "*.md"))
assert not roles, "Codex package must not ship roles"
with open(os.path.join(root, "mcp.example.toml"), "rb") as handle:
    data = tomllib.load(handle)
assert data["mcp_servers"]["ralph"]["command"] == "bash"
with open(os.path.join(root, "hooks.json"), encoding="utf-8") as handle:
    json.load(handle)
PY
      then
        MATRIX_DETAIL="Codex TOML or JSON assets are not native schemas"
        return 1
      fi
      ;;
    cursor)
      jq -e '.mcpServers | type == "array" and length == 1 and .[0].name == "ralph-mcp"' \
        "$root/mcp.example.json" >/dev/null || {
        MATRIX_DETAIL="mcp.example.json is not a native Cursor schema"; return 1;
      }
      jq -e . "$root/hooks.json" >/dev/null || {
        MATRIX_DETAIL="hooks.json is not valid JSON"; return 1;
      }
      ;;
    opencode)
      grep -Eq 'export[[:space:]]+const[[:space:]]+[A-Za-z0-9_]+[[:space:]]*:[[:space:]]*Plugin' \
        "$root/plugins/ralph-runtime-hooks.ts" || {
        MATRIX_DETAIL="runtime hook module does not match the native OpenCode Plugin schema"; return 1;
      }
      for hook in 'permission.ask' 'tool.execute.before' 'tool.execute.after'; do
        grep -Fq "\"$hook\"" "$root/plugins/ralph-runtime-hooks.ts" || {
          MATRIX_DETAIL="native OpenCode Plugin is missing $hook"; return 1;
        }
      done
      ;;
  esac
}

check_containment() {
  local runtime="$1" probe="$TEST_TMPDIR/containment-$runtime" output
  if ! python3 - "$MATRIX_REPO/$PLUGIN_REL/$runtime" <<'PY'
import json
import os
import sys

root = os.path.realpath(sys.argv[1])
with open(os.path.join(root, ".ralph-plugin-generated.json"), encoding="utf-8") as handle:
    paths = json.load(handle)["generatedPaths"]
for rel in paths:
    if os.path.isabs(rel) or ".." in rel.split("/"):
        raise SystemExit(1)
    path = os.path.join(root, *rel.split("/"))
    if not os.path.isfile(path) or os.path.islink(path):
        raise SystemExit(1)
    if os.path.commonpath((root, os.path.realpath(path))) != root:
        raise SystemExit(1)
PY
  then
    MATRIX_DETAIL="generated paths escape the adapter output directory"
    return 1
  fi

  cp -R "$MATRIX_REPO" "$probe"
  python3 - "$probe" "$runtime" <<'PY'
import json
import sys

root, runtime = sys.argv[1:]
path = f"{root}/bundle/.ralph/plugin-inputs/adapters/{runtime}.json"
with open(path, encoding="utf-8") as handle:
    data = json.load(handle)
data["copies"][0]["destination"] = "../escaped.txt"
with open(path, "w", encoding="utf-8") as handle:
    json.dump(data, handle, indent=2)
    handle.write("\n")
PY
  if output="$(python3 "$probe/$INPUTS_REL" --repo-root "$probe" 2>&1)"; then
    MATRIX_DETAIL="adapter accepted a destination outside its output directory"
    return 1
  fi
  if [[ "$output" != *"traversal"* && "$output" != *"outside"* && "$output" != *"escapes"* ]]; then
    MATRIX_DETAIL="containment rejection did not identify the escaped destination"
    return 1
  fi
}

check_secret_rejection() {
  local runtime="$1" probe="$TEST_TMPDIR/secret-$runtime" output
  cp -R "$MATRIX_REPO" "$probe"
  python3 - "$probe" "$runtime" <<'PY'
import json
import sys

root, runtime = sys.argv[1:]
path = f"{root}/bundle/.ralph/plugin-inputs/templates/{runtime}/host-manifest.json"
with open(path, encoding="utf-8") as handle:
    data = json.load(handle)
data["apiKey"] = "sk-testsecretvalue1234567890"
with open(path, "w", encoding="utf-8") as handle:
    json.dump(data, handle, indent=2)
    handle.write("\n")
PY
  if output="$(python3 "$probe/$INPUTS_REL" --repo-root "$probe" 2>&1)"; then
    MATRIX_DETAIL="literal credential was accepted"
    return 1
  fi
  if [[ "$output" != *"literal credentials"* ]]; then
    MATRIX_DETAIL="rejection did not identify literal credentials"
    return 1
  fi
}

check_mcp_validity() {
  local runtime="$1" root="$MATRIX_REPO/$PLUGIN_REL/$1"
  case "$runtime" in
    antigravity)
      jq -e '.mcpServers | type == "object"' "$root/mcp_config.json" >/dev/null || {
        MATRIX_DETAIL="Antigravity MCP config is invalid"; return 1;
      }
      ;;
    claude)
      jq -e '.mcpServers.ralph.command == "bash" and (.mcpServers.ralph.args | length == 1)' \
        "$root/.mcp.json" >/dev/null || {
        MATRIX_DETAIL="Claude MCP server entry is invalid"; return 1;
      }
      ;;
    codex)
      if ! python3 - "$root/mcp.example.toml" <<'PY'
import sys
import tomllib

with open(sys.argv[1], "rb") as handle:
    data = tomllib.load(handle)
entry = data["mcp_servers"]["ralph"]
assert entry["command"] == "bash"
assert len(entry["args"]) == 1
assert entry["env"]["RALPH_MCP_WORKSPACE"] == "/path/to/workspace"
PY
      then
        MATRIX_DETAIL="Codex MCP TOML entry is invalid"
        return 1
      fi
      ;;
    cursor)
      jq -e '
        .mcpServers[0].stdio == true and
        .mcpServers[0].command == ["bash", "/path/to/workspace/.ralph/mcp-server.sh"] and
        .mcpServers[0].name == "ralph-mcp"
      ' "$root/mcp.example.json" >/dev/null || {
        MATRIX_DETAIL="Cursor MCP server entry is invalid"; return 1;
      }
      ;;
    opencode)
      grep -Fq 'import type { Plugin } from "@opencode-ai/plugin"' \
        "$root/plugins/ralph-runtime-hooks.ts" || {
        MATRIX_DETAIL="OpenCode native plugin MCP bridge is missing its Plugin import"; return 1;
      }
      ;;
  esac
}

check_shared_gate_reference() {
  local runtime="$1" root="$MATRIX_REPO/$PLUGIN_REL/$1"
  if ! jq -e '
    .bootstrap == "shared/ralph-plugin-bootstrap.sh" and
    .exec == "shared/ralph-plugin-exec.sh"
  ' "$root/host-manifest.json" >/dev/null; then
    MATRIX_DETAIL="host manifest does not reference the shared bootstrap and execution gate"
    return 1
  fi
  for file in ralph-plugin-bootstrap.sh ralph-plugin-exec.sh; do
    [ -f "$root/shared/$file" ] || {
      MATRIX_DETAIL="shared/$file is missing"; return 1;
    }
  done
  jq -e --arg bootstrap "shared/ralph-plugin-bootstrap.sh" \
    --arg exec "shared/ralph-plugin-exec.sh" \
    '.generatedPaths | index($bootstrap) != null and index($exec) != null' \
    "$root/.ralph-plugin-generated.json" >/dev/null || {
    MATRIX_DETAIL="generation manifest omits the shared gate files"; return 1;
  }
}

check_no_vendored_engine() {
  local runtime="$1" root="$MATRIX_REPO/$PLUGIN_REL/$1"
  if [ -d "$root/.ralph" ] || [ -d "$root/bundle" ]; then
    MATRIX_DETAIL="package contains a vendored Ralph engine directory"
    return 1
  fi
  if find "$root" -type f \( \
    -name 'run-plan.sh' -o -name 'orchestrator.sh' -o -name 'graph-run.sh' -o -name '*.py' \
  \) -print -quit | grep -q .; then
    MATRIX_DETAIL="package contains a vendored engine executable or Python module"
    return 1
  fi
}

@test "generated adapter schema matrix is deterministic, native, contained, and engine-free" {
  for runtime in "${RUNTIMES[@]}"; do
    matrix_check "$runtime" "deterministic-output" check_deterministic_output "$runtime"
    matrix_check "$runtime" "native-schema" check_native_schema "$runtime"
    matrix_check "$runtime" "version-0.1.0-beta.1" check_version "$runtime"
    matrix_check "$runtime" "containment" check_containment "$runtime"
    matrix_check "$runtime" "secret-rejection" check_secret_rejection "$runtime"
    matrix_check "$runtime" "mcp-validity" check_mcp_validity "$runtime"
    matrix_check "$runtime" "shared-gate-reference" check_shared_gate_reference "$runtime"
    matrix_check "$runtime" "no-vendored-engine" check_no_vendored_engine "$runtime"
  done
}
