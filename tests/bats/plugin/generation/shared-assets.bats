#!/usr/bin/env bats

source "$BATS_TEST_DIRNAME/../../helper/load-lib.bash"

GENERATOR="$REPO_ROOT/scripts/sync-plugin-assets.sh"
OUTPUT_ROOT="$REPO_ROOT/plugins/ralph-orchestrator"
VERSION_FILE="$OUTPUT_ROOT/VERSION"

RUNTIMES=(antigravity claude codex cursor opencode)
WORKFLOWS=(ralph-doctor ralph-plan ralph-run ralph-status ralph-workflow)

generated_checksum() {
  (
    cd "$OUTPUT_ROOT"
    find antigravity claude codex cursor opencode -type f ! -name '.DS_Store' -print0 |
      LC_ALL=C sort -z |
      while IFS= read -r -d '' path; do
        printf '%s ' "$path"
        shasum -a 256 "$path" | awk '{print $1}'
        # Mode digits, portably: GNU coreutils first, then BSD. Probing BSD
        # first would emit a filesystem block on Linux before failing, which the
        # command substitution folds into the checksum input.
        stat -c '%a' "$path" 2>/dev/null || stat -f '%Mp%Lp' "$path"
      done
  )
}

@test "shared plugin assets are deterministic, versioned, and engine-free" {
  run bash "$GENERATOR" --skip-runtime-check
  [ "$status" -eq 0 ]
  [ -z "$output" ]

  local first second runtime id workflow manifest
  first="$(generated_checksum)"

  for runtime in "${RUNTIMES[@]}"; do
    [ -f "$OUTPUT_ROOT/$runtime/host-manifest.json" ]
    jq -e --arg runtime "$runtime" --arg version "$(cat "$VERSION_FILE")" '
      .id == "ralph-orchestrator" and
      .runtime == $runtime and
      .version == $version and
      (._generated | contains("scripts/sync-plugin-assets.sh"))
    ' "$OUTPUT_ROOT/$runtime/host-manifest.json"

    [ ! -d "$OUTPUT_ROOT/$runtime/roles" ]
    [ ! -d "$OUTPUT_ROOT/$runtime/agents" ]
    [ -f "$OUTPUT_ROOT/$runtime/skills/repo-context/SKILL.md" ]
    for workflow in "${WORKFLOWS[@]}"; do
      [ -f "$OUTPUT_ROOT/$runtime/workflows/$workflow.md" ]
      [ -f "$OUTPUT_ROOT/$runtime/skills/$workflow/SKILL.md" ]
      grep -Fq 'scripts/sync-plugin-assets.sh' \
        "$OUTPUT_ROOT/$runtime/workflows/$workflow.md"
      grep -Fq 'scripts/sync-plugin-assets.sh' \
        "$OUTPUT_ROOT/$runtime/skills/$workflow/SKILL.md"
    done
    [ ! -f "$OUTPUT_ROOT/$runtime/workflows/ralph-agents.md" ]
    [ ! -f "$OUTPUT_ROOT/$runtime/workflows/ralph-graph.md" ]
    [ ! -f "$OUTPUT_ROOT/$runtime/workflows/ralph-orchestrate.md" ]
    ! find "$OUTPUT_ROOT/$runtime" -type f \
      \( -name 'run-plan.sh' -o -name 'orchestrator.sh' -o -name 'graph-run.sh' \
         -o -name '*.py' \) -print -quit | grep -q .

    manifest="$OUTPUT_ROOT/$runtime/.ralph-plugin-generated.json"
    jq -e --arg version "$(cat "$VERSION_FILE")" '
      .schemaVersion == 1 and
      .pluginVersion == $version and
      (.generatedPaths | index(".ralph-plugin-generated.json") != null)
    ' "$manifest"
  done

  run bash "$GENERATOR" --skip-runtime-check
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  second="$(generated_checksum)"
  [ "$first" = "$second" ]

  ! rg -n --fixed-strings "$(cat "$VERSION_FILE")" \
    "$REPO_ROOT/bundle/.ralph/plugin-inputs" >/dev/null
}
