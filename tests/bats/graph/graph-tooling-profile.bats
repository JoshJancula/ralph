#!/usr/bin/env bats
# Per-node toolingProfile validation. A node's stage.toolingProfile, when
# present, must name one of the profiles declared in
# bundle/.ralph/tooling-profiles.json.

source "$BATS_TEST_DIRNAME/../helper/load-lib.bash"
source "$BATS_TEST_DIRNAME/../../../bundle/.ralph/bash-lib/graph/validate-graph-schema.sh"

VALIDATE_GRAPH_SCHEMA_SH="$BATS_TEST_DIRNAME/../../../bundle/.ralph/bash-lib/graph/validate-graph-schema.sh"

setup() {
  TMPD="$(mktemp -d)"
}

teardown() {
  rm -rf "$TMPD" 2>/dev/null || true
}

write_base_graph() {
  local dest="$1" tooling_profile_json="$2"
  jq -n --argjson stage "$tooling_profile_json" '{
    schemaVersion: 2,
    ralphVersion: "1.0.0",
    name: "demo",
    namespace: "demo",
    maxParallel: 2,
    failurePolicy: "drain",
    nodes: [
      {id: "n1", type: "stage", dependsOn: [], derivedFrom: "stage", stage: $stage}
    ],
    edges: []
  }' >"$dest"
}

@test "validate-graph-schema.sh accepts a node with toolingProfile ralph-compact" {
  local graph_file="$TMPD/tooling-valid.graph.json"
  write_base_graph "$graph_file" '{"toolingProfile":"ralph-compact"}'

  run bash "$VALIDATE_GRAPH_SCHEMA_SH" "$graph_file"
  [ "$status" -eq 0 ]
}

@test "validate-graph-schema.sh rejects a node with an unknown toolingProfile" {
  local graph_file="$TMPD/tooling-bogus.graph.json"
  write_base_graph "$graph_file" '{"toolingProfile":"bogus"}'

  run bash "$VALIDATE_GRAPH_SCHEMA_SH" "$graph_file"
  [ "$status" -ne 0 ]
  [[ "$output" == *"toolingProfile"* ]]
}
