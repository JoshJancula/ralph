#!/usr/bin/env bats
# Manifest-driven CI sweep: every plan listed in
# tests/fixtures/graph/schema-valid-fixtures.txt must compile and validate
# against bundle/.ralph/schemas/graph.schema.json.
#
# Intentionally invalid fixtures (cycle, duplicate producer, consensus, and
# missing-artifact failure cases) live in the same directory and must stay off
# the manifest.

source "$BATS_TEST_DIRNAME/../helper/load-lib.bash"
source "$BATS_TEST_DIRNAME/../../../bundle/.ralph/bash-lib/plan-todo.sh"

FIXTURE_DIR="$BATS_TEST_DIRNAME/../../fixtures/graph"
MANIFEST="$FIXTURE_DIR/schema-valid-fixtures.txt"
GRAPH_SCHEMA="$REPO_ROOT/bundle/.ralph/schemas/graph.schema.json"
VALIDATE_GRAPH_SCHEMA_SH="$REPO_ROOT/bundle/.ralph/bash-lib/graph/validate-graph-schema.sh"
ARTIFACT_SCHEMA_PY="$REPO_ROOT/bundle/.ralph/python/artifact_json_schema.py"

# Invalid fixtures covered by negative tests; must remain absent from the
# schema-valid manifest (do not glob the fixture directory into the sweep).
INTENTIONAL_INVALID_FIXTURES=(
  graph-cycle.plan.md
  graph-duplicate-producer.plan.md
  graph-unproduced-requires.plan.md
  graph-consensus-duplicate-voter-ids.plan.md
  graph-consensus-single-voter.plan.md
)

json_payload() {
  printf '%s\n' "$1" | awk 'END{print}'
}

manifest_entries() {
  awk '
    /^[[:space:]]*#/ { next }
    /^[[:space:]]*$/ { next }
    { gsub(/^[[:space:]]+|[[:space:]]+$/, ""); print }
  ' "$MANIFEST"
}

validate_compiled_graph() {
  local graph_file="$1"
  bash "$VALIDATE_GRAPH_SCHEMA_SH" "$graph_file" || return 1
  python3 "$ARTIFACT_SCHEMA_PY" validate-final-output \
    --schema "$GRAPH_SCHEMA" \
    --artifact "$graph_file"
}

@test "schema-valid-fixtures: manifest exists and lists at least one plan" {
  [ -f "$MANIFEST" ]
  local count=0
  while IFS= read -r entry; do
    [ -n "$entry" ] || continue
    count=$((count + 1))
  done < <(manifest_entries)
  [ "$count" -ge 1 ]
}

@test "schema-valid-fixtures: every manifest plan compiles and validates against graph.schema.json" {
  command -v python3 >/dev/null || skip "python3 required"
  [ -f "$MANIFEST" ]
  [ -f "$GRAPH_SCHEMA" ]
  [ -f "$ARTIFACT_SCHEMA_PY" ]

  local tmpd entry plan_path graph_file compile_out compile_status
  tmpd="$(mktemp -d)"

  while IFS= read -r entry; do
    [ -n "$entry" ] || continue
    plan_path="$FIXTURE_DIR/$entry"
    if [[ ! -f "$plan_path" ]]; then
      echo "schema-valid-fixtures: missing manifest entry: $entry" >&2
      rm -rf "$tmpd"
      return 1
    fi

    graph_file="$tmpd/${entry%.plan.md}.graph.json"
    compile_status=0
    compile_out="$(plan_pipeline_graph_json "$plan_path" 2>&1)" || compile_status=$?
    if [[ "$compile_status" -ne 0 ]]; then
      echo "schema-valid-fixtures: compile failed for $entry (exit $compile_status)" >&2
      printf '%s\n' "$compile_out" >&2
      rm -rf "$tmpd"
      return 1
    fi
    json_payload "$compile_out" >"$graph_file"

    if ! validate_compiled_graph "$graph_file"; then
      echo "schema-valid-fixtures: schema validation failed for $entry" >&2
      rm -rf "$tmpd"
      return 1
    fi
  done < <(manifest_entries)

  rm -rf "$tmpd"
}

@test "schema-valid-fixtures: undeclared field on a compiled graph fails schema validation" {
  command -v python3 >/dev/null || skip "python3 required"
  local tmpd plan_path graph_file scratch compile_out
  tmpd="$(mktemp -d)"
  plan_path="$FIXTURE_DIR/graph-edges.plan.md"
  [ -f "$plan_path" ]

  compile_out="$(plan_pipeline_graph_json "$plan_path")"
  graph_file="$tmpd/graph-edges.graph.json"
  json_payload "$compile_out" >"$graph_file"
  scratch="$tmpd/graph-edges-undeclared.graph.json"
  jq '. + {bogusField: true}' "$graph_file" >"$scratch"

  run python3 "$ARTIFACT_SCHEMA_PY" validate-final-output \
    --schema "$GRAPH_SCHEMA" \
    --artifact "$scratch"
  [ "$status" -ne 0 ]
  [[ "$output" == *"bogusField"* || "$output" == *"additional property"* ]]

  rm -rf "$tmpd"
}

@test "schema-valid-fixtures: intentionally invalid fixtures are absent from the manifest" {
  [ -f "$MANIFEST" ]
  local invalid entry found
  for invalid in "${INTENTIONAL_INVALID_FIXTURES[@]}"; do
    [ -f "$FIXTURE_DIR/$invalid" ] || {
      echo "schema-valid-fixtures: expected negative fixture missing on disk: $invalid" >&2
      return 1
    }
    found=0
    while IFS= read -r entry; do
      if [[ "$entry" == "$invalid" ]]; then
        found=1
        break
      fi
    done < <(manifest_entries)
    if [[ "$found" -eq 1 ]]; then
      echo "schema-valid-fixtures: invalid fixture must not be listed: $invalid" >&2
      return 1
    fi
  done
}
