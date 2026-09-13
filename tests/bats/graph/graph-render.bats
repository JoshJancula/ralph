#!/usr/bin/env bats

source "$BATS_TEST_DIRNAME/../helper/load-lib.bash"

GRAPH_RENDER_SH="$REPO_ROOT/bundle/.ralph/bash-lib/graph/graph-render.sh"
GRAPH_RUN_SH="$REPO_ROOT/bundle/.ralph/graph-run.sh"
FIXTURES_DIR="$REPO_ROOT/tests/fixtures/graph"
DIAMOND_GRAPH_JSON="$FIXTURES_DIR/graph-diamond.graph.json"
CONSENSUS_GRAPH_JSON="$FIXTURES_DIR/graph-consensus.graph.json"
DIAMOND_PLAN="$FIXTURES_DIR/graph-diamond.plan.md"
CONSENSUS_PLAN="$FIXTURES_DIR/graph-consensus.plan.md"

# Compile both fixtures into temp dir before any test.
setup() {
  TMPD="$(mktemp -d)"
  DIAMOND_JSON="$TMPD/diamond.graph.json"
  CONSENSUS_JSON="$TMPD/consensus.graph.json"
  bash "$GRAPH_RUN_SH" compile "$DIAMOND_PLAN" --out "$DIAMOND_JSON" >/dev/null 2>&1
  # The consensus fixture already has a pre-compiled .graph.json; use it directly.
  cp "$CONSENSUS_GRAPH_JSON" "$CONSENSUS_JSON"

  # Source render library.
  source "$GRAPH_RENDER_SH"
}

teardown() {
  rm -rf "$TMPD"
}

# ---------------------------------------------------------------------------
# Determinism: rendering twice produces byte-identical output.
# ---------------------------------------------------------------------------

@test "diamond mermaid render is deterministic" {
  first="$(graph_render_stub "$DIAMOND_JSON" mermaid)"
  second="$(graph_render_stub "$DIAMOND_JSON" mermaid)"
  [ "$first" = "$second" ]
}

@test "diamond dot render is deterministic" {
  first="$(graph_render_stub "$DIAMOND_JSON" dot)"
  second="$(graph_render_stub "$DIAMOND_JSON" dot)"
  [ "$first" = "$second" ]
}

@test "diamond ascii render is deterministic" {
  first="$(graph_render_stub "$DIAMOND_JSON" ascii)"
  second="$(graph_render_stub "$DIAMOND_JSON" ascii)"
  [ "$first" = "$second" ]
}

@test "consensus mermaid render is deterministic" {
  first="$(graph_render_stub "$CONSENSUS_JSON" mermaid)"
  second="$(graph_render_stub "$CONSENSUS_JSON" mermaid)"
  [ "$first" = "$second" ]
}

@test "consensus dot render is deterministic" {
  first="$(graph_render_stub "$CONSENSUS_JSON" dot)"
  second="$(graph_render_stub "$CONSENSUS_JSON" dot)"
  [ "$first" = "$second" ]
}

@test "consensus ascii render is deterministic" {
  first="$(graph_render_stub "$CONSENSUS_JSON" ascii)"
  second="$(graph_render_stub "$CONSENSUS_JSON" ascii)"
  [ "$first" = "$second" ]
}

# ---------------------------------------------------------------------------
# Mermaid format correctness.
# ---------------------------------------------------------------------------

@test "diamond mermaid output starts with flowchart TD" {
  run graph_render_stub "$DIAMOND_JSON" mermaid
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -q '^flowchart TD$'
}

@test "diamond mermaid includes all four node ids" {
  run graph_render_stub "$DIAMOND_JSON" mermaid
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -q 'source'
  printf '%s\n' "$output" | grep -q 'left'
  printf '%s\n' "$output" | grep -q 'right'
  printf '%s\n' "$output" | grep -q 'sink'
}

@test "diamond mermaid artifact edges carry artifact reason as comment" {
  run graph_render_stub "$DIAMOND_JSON" mermaid
  [ "$status" -eq 0 ]
  # source -> left edge should have artifact reason comment.
  printf '%s\n' "$output" | grep -q 'artifact:shared/input.md'
  # left -> sink edge should have artifact reason comment.
  printf '%s\n' "$output" | grep -q 'artifact:shared/left.md'
  # right -> sink edge should have artifact reason comment.
  printf '%s\n' "$output" | grep -q 'artifact:shared/right.md'
}

@test "diamond mermaid comments use mermaid comment syntax" {
  run graph_render_stub "$DIAMOND_JSON" mermaid
  [ "$status" -eq 0 ]
  # Mermaid line comments start with '%%'.
  printf '%s\n' "$output" | grep -q '^  %% '
}

@test "diamond mermaid edges use --> syntax" {
  run graph_render_stub "$DIAMOND_JSON" mermaid
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -q ' --> '
}

# ---------------------------------------------------------------------------
# DOT format correctness.
# ---------------------------------------------------------------------------

@test "diamond dot output starts with digraph" {
  run graph_render_stub "$DIAMOND_JSON" dot
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -q '^digraph '
}

@test "diamond dot artifact edges carry artifact reason as comment" {
  run graph_render_stub "$DIAMOND_JSON" dot
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -q 'artifact:shared/input.md'
  printf '%s\n' "$output" | grep -q 'artifact:shared/left.md'
}

@test "diamond dot uses slash-slash comments" {
  run graph_render_stub "$DIAMOND_JSON" dot
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -q '^\s*//'
}

@test "diamond dot output ends with closing brace" {
  run graph_render_stub "$DIAMOND_JSON" dot
  [ "$status" -eq 0 ]
  last="$(printf '%s\n' "$output" | tail -1)"
  [ "$last" = "}" ]
}

# ---------------------------------------------------------------------------
# ASCII format correctness.
# ---------------------------------------------------------------------------

@test "diamond ascii output lists all nodes" {
  run graph_render_stub "$DIAMOND_JSON" ascii
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -q 'source'
  printf '%s\n' "$output" | grep -q 'left'
  printf '%s\n' "$output" | grep -q 'right'
  printf '%s\n' "$output" | grep -q 'sink'
}

@test "diamond ascii output lists all edges with reasons" {
  run graph_render_stub "$DIAMOND_JSON" ascii
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -q 'artifact:shared/input.md'
  printf '%s\n' "$output" | grep -q 'artifact:shared/left.md'
  printf '%s\n' "$output" | grep -q 'artifact:shared/right.md'
}

# ---------------------------------------------------------------------------
# Consensus subgraph: all three voter runtimes must appear.
# ---------------------------------------------------------------------------

@test "consensus mermaid subgraph contains cursor voter" {
  run graph_render_stub "$CONSENSUS_JSON" mermaid
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -q 'cursor'
}

@test "consensus mermaid subgraph contains codex voter" {
  run graph_render_stub "$CONSENSUS_JSON" mermaid
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -q 'codex'
}

@test "consensus mermaid subgraph contains claude voter" {
  run graph_render_stub "$CONSENSUS_JSON" mermaid
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -q 'claude'
}

@test "consensus mermaid uses subgraph block" {
  run graph_render_stub "$CONSENSUS_JSON" mermaid
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -q '^  subgraph '
}

@test "consensus dot uses cluster subgraph for consensus group" {
  run graph_render_stub "$CONSENSUS_JSON" dot
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -q 'subgraph cluster_'
}

@test "consensus ascii labels group as consensus" {
  run graph_render_stub "$CONSENSUS_JSON" ascii
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -q '\[consensus:'
}

@test "consensus ascii lists all three voter runtimes" {
  run graph_render_stub "$CONSENSUS_JSON" ascii
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -q 'cursor'
  printf '%s\n' "$output" | grep -q 'codex'
  printf '%s\n' "$output" | grep -q 'claude'
}

# ---------------------------------------------------------------------------
# Node id escaping: consensus voter ids contain colons, which are not valid
# in mermaid node identifiers. The renderer must sanitize them.
# ---------------------------------------------------------------------------

@test "consensus mermaid sanitizes colon in voter node ids" {
  run graph_render_stub "$CONSENSUS_JSON" mermaid
  [ "$status" -eq 0 ]
  # The sanitized ids must use underscores, not colons, in node references.
  # review:alpha becomes review_alpha in node definitions and edge references.
  printf '%s\n' "$output" | grep -q 'review_alpha'
  printf '%s\n' "$output" | grep -q 'review_beta'
  printf '%s\n' "$output" | grep -q 'review_gamma'
  printf '%s\n' "$output" | grep -q 'review_barrier'
}

@test "consensus mermaid node labels still show original id with colon" {
  run graph_render_stub "$CONSENSUS_JSON" mermaid
  [ "$status" -eq 0 ]
  # The label inside quotes should preserve the original colon-containing id.
  printf '%s\n' "$output" | grep -q 'review:alpha'
}

@test "consensus dot preserves colon in quoted node ids" {
  run graph_render_stub "$CONSENSUS_JSON" dot
  [ "$status" -eq 0 ]
  # DOT quotes node names, so colons are safe.
  printf '%s\n' "$output" | grep -q '"review:alpha"'
  printf '%s\n' "$output" | grep -q '"review:beta"'
  printf '%s\n' "$output" | grep -q '"review:gamma"'
}

# ---------------------------------------------------------------------------
# Invalid format.
# ---------------------------------------------------------------------------

@test "unsupported format returns non-zero exit" {
  run graph_render_stub "$DIAMOND_JSON" svg
  [ "$status" -ne 0 ]
}

@test "missing graph json returns non-zero exit" {
  run graph_render_stub "/nonexistent/path.graph.json" mermaid
  [ "$status" -ne 0 ]
}
