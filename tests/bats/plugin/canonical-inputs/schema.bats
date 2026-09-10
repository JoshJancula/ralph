#!/usr/bin/env bats

source "$BATS_TEST_DIRNAME/../../helper/load-lib.bash"

INPUT_ROOT="$REPO_ROOT/bundle/.ralph/plugin-inputs"
PLUGIN_JSON="$INPUT_ROOT/plugin.json"
VERSION_FILE="$REPO_ROOT/plugins/ralph-orchestrator/VERSION"
VERSION_SOURCE="plugins/ralph-orchestrator/VERSION"
ABI_FILE="$REPO_ROOT/bundle/.ralph/plugin-api-version"
EXPECTED_VERSION="0.1.0-beta.1"

ADAPTER_RUNTIMES=(antigravity claude codex cursor opencode)
WORKFLOW_IDS=(ralph-doctor ralph-plan ralph-run ralph-status ralph-workflow)
PLUGIN_KEYS=(schemaVersion id displayName versionFile outputRoot engine workflows contracts adapters)
ADAPTER_KEYS=(schemaVersion runtime outputDirectory contract capabilities copies templates)
OPENCODE_CONTRACT_KEYS=(schemaVersion runtime cliVersion pluginPackageVersion moduleFormat pluginExport typeDeclaration typeDeclarationSha256 requiredHooks moduleSource)
ANTIGRAVITY_CONTRACT_KEYS=(schemaVersion runtime configRoot mcpFile cli printFlag conversationFlag modelFlag modelsCommand pluginCommands modelValuePolicy)

json_keys() {
  jq -r 'keys_unsorted | join(" ")' "$1"
}

assert_exact_keys() {
  local actual expected
  actual="$(json_keys "$1")"
  expected="$2"
  [ "$actual" = "$expected" ]
}

canonical_json_files() {
  find "$INPUT_ROOT" -type f -name '*.json' | LC_ALL=C sort
}

@test "canonical tree has five adapters, two contracts, and shared workflows outside generated host packages" {
  [ -f "$PLUGIN_JSON" ]
  [ -f "$INPUT_ROOT/adapters/antigravity.json" ]
  [ -f "$INPUT_ROOT/adapters/claude.json" ]
  [ -f "$INPUT_ROOT/adapters/codex.json" ]
  [ -f "$INPUT_ROOT/adapters/cursor.json" ]
  [ -f "$INPUT_ROOT/adapters/opencode.json" ]
  [ -f "$INPUT_ROOT/contracts/antigravity.json" ]
  [ -f "$INPUT_ROOT/contracts/opencode.json" ]
  [ -d "$INPUT_ROOT/templates/antigravity" ]
  [ -d "$INPUT_ROOT/templates/claude" ]
  [ -d "$INPUT_ROOT/templates/codex" ]
  [ -d "$INPUT_ROOT/templates/cursor" ]
  [ -d "$INPUT_ROOT/templates/opencode" ]
  [ -f "$INPUT_ROOT/shared/ralph-plugin-bootstrap.sh" ]
  [ -f "$INPUT_ROOT/shared/ralph-plugin-exec.sh" ]
  [[ "$INPUT_ROOT" != "$REPO_ROOT/plugins/ralph-orchestrator"* ]]
}

@test "plugin descriptor is the closed P03 schema with five adapters and five workflows" {
  assert_exact_keys "$PLUGIN_JSON" "${PLUGIN_KEYS[*]}"

  run jq -e '
    .schemaVersion == 1 and
    .id == "ralph-orchestrator" and
    .displayName == "Ralph Orchestrator" and
    .versionFile == "plugins/ralph-orchestrator/VERSION" and
    .outputRoot == "plugins/ralph-orchestrator" and
    .engine.delivery == "external-cli" and
    .engine.command == "ralph" and
    .engine.pluginApi == 1 and
    (.engine | keys_unsorted) == ["delivery", "command", "pluginApi"] and
    (has("roles") | not) and
    .workflows == ["ralph-doctor", "ralph-plan", "ralph-run", "ralph-status", "ralph-workflow"] and
    .adapters == ["antigravity", "claude", "codex", "cursor", "opencode"] and
    .contracts.antigravity == "bundle/.ralph/plugin-inputs/contracts/antigravity.json" and
    .contracts.opencode == "bundle/.ralph/plugin-inputs/contracts/opencode.json" and
    ((.contracts | keys) | length) == 2
  ' "$PLUGIN_JSON"
  [ "$status" -eq 0 ]
}

@test "plugin descriptor does not ship roles and adapters do not copy role files" {
  local adapter
  run jq -e 'has("roles") | not' "$PLUGIN_JSON"
  [ "$status" -eq 0 ]
  [ ! -d "$INPUT_ROOT/roles" ]
  for adapter in "$INPUT_ROOT/adapters/"*.json; do
    ! jq -e '
      any(
        (.copies[]?, .templates[]?);
        (.source | test("bundle/\\.ralph/roles/")) or
        (.destination | test("^roles/"))
      )
    ' "$adapter"
  done
}

@test "shared workflow inputs exist for every declared workflow id" {
  local id
  [ "$(jq -r '.workflows | length' "$PLUGIN_JSON")" -eq 5 ]
  for id in "${WORKFLOW_IDS[@]}"; do
    [ -f "$INPUT_ROOT/workflows/${id}.md" ]
    [ ! -L "$INPUT_ROOT/workflows/${id}.md" ]
  done
}

@test "adapter descriptors use the closed P04 schema and required contract paths" {
  local runtime adapter contract expected_contract
  [ "$(jq -r '.adapters | length' "$PLUGIN_JSON")" -eq 5 ]

  for runtime in "${ADAPTER_RUNTIMES[@]}"; do
    adapter="$INPUT_ROOT/adapters/${runtime}.json"
    [ -f "$adapter" ]
    assert_exact_keys "$adapter" "${ADAPTER_KEYS[*]}"

    run jq -e --arg runtime "$runtime" '
      .schemaVersion == 1 and
      .runtime == $runtime and
      .outputDirectory == ("plugins/ralph-orchestrator/" + $runtime) and
      (.capabilities | keys_unsorted) == ["nativeAgents", "nativeHooks", "mcp", "rules", "skills", "workflows"] and
      (.copies | type == "array" and length > 0) and
      (.templates | type == "array" and length > 0) and
      all(.copies[]; (. | keys_unsorted) == ["source", "destination", "mode"]) and
      all(.templates[]; (. | keys_unsorted) == ["source", "destination", "mode"])
    ' "$adapter"
    [ "$status" -eq 0 ]

    if [ "$runtime" = "opencode" ] || [ "$runtime" = "antigravity" ]; then
      expected_contract="bundle/.ralph/plugin-inputs/contracts/${runtime}.json"
      contract="$(jq -r '.contract' "$adapter")"
      [ "$contract" = "$expected_contract" ]
      [ -f "$REPO_ROOT/$contract" ]
    else
      [ "$(jq -r '.contract' "$adapter")" = "null" ]
    fi
  done
}

@test "adapter copy and template sources are regular repository files" {
  local adapter source dest mode prefix
  while IFS= read -r adapter; do
    while IFS=$'\t' read -r source dest mode; do
      [ -n "$source" ]
      [ -n "$dest" ]
      [ "$mode" = "0644" ] || [ "$mode" = "0755" ]
      case "$source" in
        /*|../*|*/../*) false ;;
      esac
      case "$dest" in
        /*|../*|*/../*) false ;;
      esac
      [ -f "$REPO_ROOT/$source" ]
      [ ! -L "$REPO_ROOT/$source" ]
    done < <(
      jq -r '
        (.copies[]?, .templates[]?) |
        [.source, .destination, .mode] | @tsv
      ' "$adapter"
    )
  done < <(printf '%s\n' "$INPUT_ROOT/adapters/"*.json | LC_ALL=C sort)
}

@test "OpenCode and Antigravity host contracts match P13 and P14" {
  local opencode antigravity
  opencode="$INPUT_ROOT/contracts/opencode.json"
  antigravity="$INPUT_ROOT/contracts/antigravity.json"
  [ "$(jq -r '.contracts | keys | length' "$PLUGIN_JSON")" -eq 2 ]
  assert_exact_keys "$opencode" "${OPENCODE_CONTRACT_KEYS[*]}"
  assert_exact_keys "$antigravity" "${ANTIGRAVITY_CONTRACT_KEYS[*]}"

  run jq -e '
    .schemaVersion == 1 and
    .runtime == "opencode" and
    .cliVersion == "1.3.17" and
    .pluginPackageVersion == "1.3.15" and
    .moduleFormat == "ESM" and
    .pluginExport == "Plugin" and
    .typeDeclaration == "@opencode-ai/plugin/dist/index.d.ts" and
    .typeDeclarationSha256 == "ea181db7cd8f13c626356b7982066cae9f7acf0f27934e738620b441b97bde76" and
    .requiredHooks == ["permission.ask", "tool.execute.before", "tool.execute.after"] and
    .moduleSource == "bundle/.opencode/plugins/ralph-runtime-hooks.ts"
  ' "$opencode"
  [ "$status" -eq 0 ]

  run jq -e '
    .schemaVersion == 1 and
    .runtime == "antigravity" and
    .configRoot == ".agents" and
    .mcpFile == "mcp_config.json" and
    .cli == "agy" and
    .printFlag == "--print" and
    .conversationFlag == "--conversation" and
    .modelFlag == "--model" and
    .modelsCommand == "agy models" and
    .pluginCommands == ["list", "import", "install", "uninstall", "enable", "disable", "validate", "link"] and
    .modelValuePolicy == "opaque-byte-preserved"
  ' "$antigravity"
  [ "$status" -eq 0 ]
}

@test "VERSION is the sole plugin version source and ABI is 1" {
  local expected source_count
  expected="$BATS_TEST_TMPDIR/expected-version"
  printf '%s\n' "$EXPECTED_VERSION" > "$expected"
  [ -f "$VERSION_FILE" ]
  cmp -s "$expected" "$VERSION_FILE"

  expected="$BATS_TEST_TMPDIR/expected-abi"
  printf '%s\n' "1" > "$expected"
  [ -f "$ABI_FILE" ]
  cmp -s "$expected" "$ABI_FILE"

  [ "$(jq -r '.versionFile' "$PLUGIN_JSON")" = "$VERSION_SOURCE" ]
  run jq -e 'has("version") | not' "$PLUGIN_JSON"
  [ "$status" -eq 0 ]

  source_count="$(
    while IFS= read -r input; do
      jq -r '.. | strings' "$input"
    done < <(canonical_json_files) |
      awk -v source="$VERSION_SOURCE" '$0 == source { count++ } END { print count + 0 }'
  )"
  [ "$source_count" -eq 1 ]

  # -E and --fixed-strings are conflicting matchers: GNU grep rejects the
  # combination with exit 2, while BSD grep silently honors the last one. The
  # intent is a literal search, so ask for exactly that.
  run grep -Rn --fixed-strings "$EXPECTED_VERSION" "$INPUT_ROOT"
  [ "$status" -eq 1 ]
}

@test "canonical inputs do not duplicate the runtime-owned repo-context asset" {
  ! find "$INPUT_ROOT" -path '*repo-context*' -print -quit | grep -q .

  run jq -e '
    [
      .. |
      strings
    ] |
    all(contains("repo-context") | not)
  ' "$PLUGIN_JSON"
  [ "$status" -eq 0 ]
}
