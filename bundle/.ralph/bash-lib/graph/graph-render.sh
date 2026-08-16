#!/usr/bin/env bash
# Graph renderer: mermaid, dot, and ascii output from a compiled .graph.json.
# Replaces the Phase 1 stub. Called by graph_compile_cli when --render is
# specified; the function name and signature are kept stable so graph-compile.sh
# callers do not change.

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  echo "This file is meant to be sourced, not executed." >&2
  exit 1
fi

# graph_render_sanitize_mermaid_id <id>
# Return a mermaid-safe node identifier (alphanumeric, underscore, hyphen only).
# Colons, slashes, spaces, and other problematic characters are replaced with _.
graph_render_sanitize_mermaid_id() {
  printf '%s' "$1" | tr -c 'a-zA-Z0-9_-' '_'
}

# graph_render_escape_mermaid_label <str>
# Escape a string for use inside mermaid double-quoted node labels.
# Mermaid renders quotes inside labels as-is when escaped with a backslash, but
# the safest approach is to replace embedded double-quotes with single-quotes.
graph_render_escape_mermaid_label() {
  printf '%s' "$1" | sed 's/"/'"'"'/g'
}

# graph_render_escape_dot_string <str>
# Escape a string for use inside DOT double-quoted identifiers or labels.
graph_render_escape_dot_string() {
  printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

# graph_render_reasons_comment <comma-separated-reasons>
# Return a human-readable comma-separated reasons string.
graph_render_reasons_comment() {
  printf '%s' "$1" | sed 's/,/, /g'
}

# _graph_render_node_annotation <graph-json-path> <node-id>
# Return a compact annotation for a node label when v2 fields are present:
# workspace mode, write scopes, native subagent mode, cross-runtime mode,
# repair epoch, changeset hash, publish readiness, and concurrency-reduction
# hints.  Empty when no annotation field is present.
_graph_render_node_annotation() {
  local graph_json="$1" nid="$2"
  local mode scopes native_mode cross_mode repair_epoch changeset_hash publish reduction
  local annotations=""
  mode="$(jq -r --arg id "$nid" '.nodes[] | select(.id == $id) | .stage.workspaceMode // ""' "$graph_json" 2>/dev/null)"
  scopes="$(jq -r --arg id "$nid" '.nodes[] | select(.id == $id) | (.stage.writeScopes // []) | if length == 0 then "" else (.[0] + if length > 1 then "+" else "" end) end' "$graph_json" 2>/dev/null)"
  native_mode="$(jq -r --arg id "$nid" '.nodes[] | select(.id == $id) | .stage.delegation.native.mode // ""' "$graph_json" 2>/dev/null)"
  cross_mode="$(jq -r --arg id "$nid" '.nodes[] | select(.id == $id) | .stage.delegation.crossRuntime.mode // ""' "$graph_json" 2>/dev/null)"
  repair_epoch="$(jq -r --arg id "$nid" '.nodes[] | select(.id == $id) | .derivedFrom // ""' "$graph_json" 2>/dev/null)"
  changeset_hash="$(jq -r --arg id "$nid" '.nodes[] | select(.id == $id) | .stage.changesetHash // ""' "$graph_json" 2>/dev/null)"
  publish="$(jq -r --arg id "$nid" '.nodes[] | select(.id == $id) | .stage.publishReadiness.status // ""' "$graph_json" 2>/dev/null)"
  reduction="$(jq -r --arg id "$nid" '.nodes[] | select(.id == $id) | .stage.concurrencyReduction // ""' "$graph_json" 2>/dev/null)"
  [[ -n "$mode" ]] && annotations="${annotations}mode=${mode}\n"
  [[ -n "$scopes" ]] && annotations="${annotations}scopes=${scopes}\n"
  [[ -n "$native_mode" && "$native_mode" != "off" && "$native_mode" != "inherit" ]] && annotations="${annotations}native=${native_mode}\n"
  [[ -n "$cross_mode" && "$cross_mode" != "off" && "$cross_mode" != "inherit" ]] && annotations="${annotations}cross=${cross_mode}\n"
  [[ -n "$repair_epoch" && "$repair_epoch" != "stage" ]] && annotations="${annotations}epoch=${repair_epoch}\n"
  [[ -n "$changeset_hash" ]] && annotations="${annotations}hash=${changeset_hash:0:16}\n"
  [[ -n "$publish" ]] && annotations="${annotations}publish=${publish}\n"
  [[ -n "$reduction" ]] && annotations="${annotations}reduction=${reduction}\n"
  if [[ -n "$annotations" ]]; then
    printf '%s' "${annotations%\n}"
  fi
}

# _graph_render_virtual_ids <graph-json-path>
# Print a newline-separated list of virtual (pre-expansion) ids that appear in
# edges.to but not in any node id.
_graph_render_virtual_ids() {
  local graph_json="$1"
  jq -r '
    (.nodes | map(.id) | unique) as $real_ids |
    [.edges[].to | select(. as $t | ($real_ids | index($t)) == null)] |
    unique | sort[]
  ' "$graph_json"
}

# _graph_render_voters_for_virtual <graph-json-path> <virtual-id>
# Print sorted voter node ids whose dependsOn contains the virtual id.
_graph_render_voters_for_virtual() {
  local graph_json="$1" virtual_id="$2"
  jq -r --arg vid "$virtual_id" '
    [.nodes[] |
      select(.type == "consensus-voter") |
      select(.dependsOn | map(. == $vid) | any) |
      .id
    ] | sort[]
  ' "$graph_json"
}

# _graph_render_consensus_groups <graph-json-path>
# Print sorted list of virtual consensus stage ids (one per line).
# These are ids that appear in .edges[].to but not in any real node.id,
# and have consensus-voter nodes that depend on them.
_graph_render_consensus_groups() {
  local graph_json="$1"
  jq -r '
    (.nodes | map(.id) | unique) as $real_ids |
    [.nodes[] |
      select(.type == "consensus-voter") |
      .dependsOn[] |
      select(. as $d | ($real_ids | index($d)) == null)
    ] | unique | sort[]
  ' "$graph_json"
}

# _graph_render_barrier_for_group <graph-json-path> <virtual-id>
# Print the barrier node id for a consensus group identified by its virtual id.
# The barrier is the consensus-barrier node whose dependsOn includes at least
# one voter node that depends on the given virtual id.
_graph_render_barrier_for_group() {
  local graph_json="$1" virtual_id="$2"
  jq -r --arg vid "$virtual_id" '
    # Collect voter ids for this virtual id.
    [.nodes[] |
      select(.type == "consensus-voter") |
      select(.dependsOn | map(. == $vid) | any) |
      .id
    ] as $voters |
    # Find the barrier node whose dependsOn intersects $voters.
    [.nodes[] |
      select(.type == "consensus-barrier") |
      select(.dependsOn | map(. as $d | ($voters | index($d)) != null) | any) |
      .id
    ] | sort | first // empty
  ' "$graph_json"
}

# graph_render_mermaid <graph-json-path>
graph_render_mermaid() {
  local graph_json="$1"

  if ! command -v jq >/dev/null 2>&1; then
    echo "Error: jq is required for graph rendering" >&2
    return 1
  fi

  local graph_name
  graph_name="$(jq -r '.name // "graph"' "$graph_json")"

  printf '%%%% Graph: %s\n' "$graph_name"
  printf 'flowchart TD\n'

  # Determine which node ids belong to consensus subgraphs.
  # Build a flat list: "id" lines for all nodes in subgraphs.
  local subgraph_members=""
  subgraph_members="$(jq -r '
    [.nodes[] |
      select(.type == "consensus-voter" or .type == "consensus-barrier") |
      .id
    ] | sort[]
  ' "$graph_json")"

  # Render consensus subgraphs (sorted by group name).
  local consensus_groups
  consensus_groups="$(_graph_render_consensus_groups "$graph_json")"
  if [[ -n "$consensus_groups" ]]; then
    while IFS= read -r group; do
      [[ -z "$group" ]] && continue
      local safe_group escaped_group
      safe_group="$(graph_render_sanitize_mermaid_id "$group")"
      escaped_group="$(graph_render_escape_mermaid_label "$group")"
      printf '  subgraph %s_group["%s (consensus)"]\n' "$safe_group" "$escaped_group"

      # Voter nodes sorted by id (grouped by virtual id).
      local voter_ids
      voter_ids="$(_graph_render_voters_for_virtual "$graph_json" "$group")"

      while IFS= read -r nid; do
        [[ -z "$nid" ]] && continue
        local safe_nid escaped_nid runtime agent extra_label
        safe_nid="$(graph_render_sanitize_mermaid_id "$nid")"
        escaped_nid="$(graph_render_escape_mermaid_label "$nid")"
        runtime="$(jq -r --arg id "$nid" '.nodes[] | select(.id == $id) | .stage.runtime // ""' "$graph_json")"
        agent="$(jq -r --arg id "$nid" '.nodes[] | select(.id == $id) | .stage.agent // ""' "$graph_json")"
        extra_label="$(_graph_render_node_annotation "$graph_json" "$nid")"
        if [[ -n "$extra_label" ]]; then
          printf '    %s["%s\n%s/%s\n%s"]\n' "$safe_nid" "$escaped_nid" "$runtime" "$agent" "$extra_label"
        else
          printf '    %s["%s\n%s/%s"]\n' "$safe_nid" "$escaped_nid" "$runtime" "$agent"
        fi
      done <<< "$voter_ids"

      # Barrier node.
      local barrier_id
      barrier_id="$(_graph_render_barrier_for_group "$graph_json" "$group")"
      if [[ -n "$barrier_id" ]]; then
        local safe_barrier escaped_barrier
        safe_barrier="$(graph_render_sanitize_mermaid_id "$barrier_id")"
        escaped_barrier="$(graph_render_escape_mermaid_label "$barrier_id")"
        printf '    %s["%s\n(barrier)"]\n' "$safe_barrier" "$escaped_barrier"

        # Internal edges from each voter to the barrier.
        while IFS= read -r nid; do
          [[ -z "$nid" ]] && continue
          local safe_nid
          safe_nid="$(graph_render_sanitize_mermaid_id "$nid")"
          printf '    %s --> %s\n' "$safe_nid" "$safe_barrier"
        done <<< "$voter_ids"
      fi

      printf '  end\n'
    done <<< "$consensus_groups"
  fi

  # Render non-consensus nodes (sorted by id).
  local all_node_ids
  all_node_ids="$(jq -r '[.nodes[].id] | sort[]' "$graph_json")"
  while IFS= read -r nid; do
    [[ -z "$nid" ]] && continue
    # Skip nodes that are inside a consensus subgraph.
    if printf '%s\n' "$subgraph_members" | grep -qx "$nid"; then
      continue
    fi
    local safe_nid escaped_nid runtime agent extra_label
    safe_nid="$(graph_render_sanitize_mermaid_id "$nid")"
    escaped_nid="$(graph_render_escape_mermaid_label "$nid")"
    runtime="$(jq -r --arg id "$nid" '.nodes[] | select(.id == $id) | .stage.runtime // ""' "$graph_json")"
    agent="$(jq -r --arg id "$nid" '.nodes[] | select(.id == $id) | .stage.agent // ""' "$graph_json")"
    extra_label="$(_graph_render_node_annotation "$graph_json" "$nid")"
    if [[ -n "$extra_label" ]]; then
      printf '  %s["%s\n%s/%s\n%s"]\n' "$safe_nid" "$escaped_nid" "$runtime" "$agent" "$extra_label"
    else
      printf '  %s["%s\n%s/%s"]\n' "$safe_nid" "$escaped_nid" "$runtime" "$agent"
    fi
  done <<< "$all_node_ids"

  # Render edges sorted by from+to, expanding virtual consensus ids.
  # Each row: from<TAB>to<TAB>reasons<TAB>condition (condition may be empty).
  local edges_tsv
  edges_tsv="$(jq -r '
    [.edges[] | {from: .from, to: .to, reasons: (.reasons | join(",")), condition: (.condition // "")}] |
    sort_by(.from + .to + .condition) | .[] |
    "\(.from)\t\(.to)\t\(.reasons)\t\(.condition)"
  ' "$graph_json")"

  if [[ -z "$edges_tsv" ]]; then
    return 0
  fi

  local real_node_ids
  real_node_ids="$(jq -r '[.nodes[].id] | sort | join("\n")' "$graph_json")"

  while IFS=$'\t' read -r from to reasons condition; do
    [[ -z "$from" ]] && continue
    local safe_from comment label
    safe_from="$(graph_render_sanitize_mermaid_id "$from")"
    comment="$(graph_render_reasons_comment "$reasons")"
    # Append condition to the label when present.
    if [[ -n "$condition" ]]; then
      label="${condition}|${comment}"
    else
      label="$comment"
    fi

    # Check if 'to' is a real node id.
    if printf '%s\n' "$real_node_ids" | grep -qx "$to"; then
      local safe_to
      safe_to="$(graph_render_sanitize_mermaid_id "$to")"
      printf '  %%%% %s -> %s: %s\n' "$from" "$to" "$label"
      if [[ -n "$condition" ]]; then
        printf '  %s -->|%s| %s\n' "$safe_from" "$condition" "$safe_to"
      else
        printf '  %s --> %s\n' "$safe_from" "$safe_to"
      fi
    else
      # Virtual consensus id: fan out to all voter nodes that depend on it.
      local voter_ids_for_virtual
      voter_ids_for_virtual="$(_graph_render_voters_for_virtual "$graph_json" "$to")"
      while IFS= read -r vid; do
        [[ -z "$vid" ]] && continue
        local safe_vid
        safe_vid="$(graph_render_sanitize_mermaid_id "$vid")"
        printf '  %%%% %s -> %s: %s\n' "$from" "$vid" "$label"
        if [[ -n "$condition" ]]; then
          printf '  %s -->|%s| %s\n' "$safe_from" "$condition" "$safe_vid"
        else
          printf '  %s --> %s\n' "$safe_from" "$safe_vid"
        fi
      done <<< "$voter_ids_for_virtual"
    fi
  done <<< "$edges_tsv"
}

# graph_render_dot <graph-json-path>
graph_render_dot() {
  local graph_json="$1"

  if ! command -v jq >/dev/null 2>&1; then
    echo "Error: jq is required for graph rendering" >&2
    return 1
  fi

  local graph_name
  graph_name="$(jq -r '.name // "graph"' "$graph_json")"
  local safe_graph_name
  safe_graph_name="$(graph_render_escape_dot_string "$graph_name")"

  printf 'digraph "%s" {\n' "$safe_graph_name"
  printf '  rankdir=TD;\n'
  printf '  node [shape=box];\n'

  # Consensus subgraphs.
  local consensus_groups
  consensus_groups="$(_graph_render_consensus_groups "$graph_json")"
  local subgraph_counter=0
  if [[ -n "$consensus_groups" ]]; then
    while IFS= read -r group; do
      [[ -z "$group" ]] && continue
      local esc_group
      esc_group="$(graph_render_escape_dot_string "$group")"
      subgraph_counter=$((subgraph_counter + 1))
      printf '  subgraph cluster_%d {\n' "$subgraph_counter"
      printf '    label="%s (consensus)";\n' "$esc_group"
      printf '    style=dashed;\n'

      # Voter nodes sorted (grouped by virtual id).
      local voter_ids
      voter_ids="$(_graph_render_voters_for_virtual "$graph_json" "$group")"

      while IFS= read -r nid; do
        [[ -z "$nid" ]] && continue
        local esc_nid runtime agent annotation
        esc_nid="$(graph_render_escape_dot_string "$nid")"
        runtime="$(jq -r --arg id "$nid" '.nodes[] | select(.id == $id) | .stage.runtime // ""' "$graph_json")"
        agent="$(jq -r --arg id "$nid" '.nodes[] | select(.id == $id) | .stage.agent // ""' "$graph_json")"
        annotation="$(_graph_render_node_annotation "$graph_json" "$nid")"
        if [[ -n "$annotation" ]]; then
          printf '    "%s" [label="%s\n%s/%s\n%s"];\n' "$esc_nid" "$esc_nid" "$runtime" "$agent" "$annotation"
        else
          printf '    "%s" [label="%s\n%s/%s"];\n' "$esc_nid" "$esc_nid" "$runtime" "$agent"
        fi
      done <<< "$voter_ids"

      # Barrier node.
      local barrier_id
      barrier_id="$(_graph_render_barrier_for_group "$graph_json" "$group")"
      if [[ -n "$barrier_id" ]]; then
        local esc_barrier
        esc_barrier="$(graph_render_escape_dot_string "$barrier_id")"
        printf '    "%s" [label="%s\n(barrier)"];\n' "$esc_barrier" "$esc_barrier"

        # Internal voter -> barrier edges.
        while IFS= read -r nid; do
          [[ -z "$nid" ]] && continue
          local esc_nid
          esc_nid="$(graph_render_escape_dot_string "$nid")"
          printf '    "%s" -> "%s";\n' "$esc_nid" "$esc_barrier"
        done <<< "$voter_ids"
      fi

      printf '  }\n'
    done <<< "$consensus_groups"
  fi

  # Non-consensus nodes (sorted).
  local subgraph_members
  subgraph_members="$(jq -r '
    [.nodes[] |
      select(.type == "consensus-voter" or .type == "consensus-barrier") |
      .id
    ] | sort[]
  ' "$graph_json")"

  local all_node_ids
  all_node_ids="$(jq -r '[.nodes[].id] | sort[]' "$graph_json")"
  while IFS= read -r nid; do
    [[ -z "$nid" ]] && continue
    if printf '%s\n' "$subgraph_members" | grep -qx "$nid"; then
      continue
    fi
    local esc_nid runtime agent annotation
    esc_nid="$(graph_render_escape_dot_string "$nid")"
    runtime="$(jq -r --arg id "$nid" '.nodes[] | select(.id == $id) | .stage.runtime // ""' "$graph_json")"
    agent="$(jq -r --arg id "$nid" '.nodes[] | select(.id == $id) | .stage.agent // ""' "$graph_json")"
    annotation="$(_graph_render_node_annotation "$graph_json" "$nid")"
    if [[ -n "$annotation" ]]; then
      printf '  "%s" [label="%s\n%s/%s\n%s"];\n' "$esc_nid" "$esc_nid" "$runtime" "$agent" "$annotation"
    else
      printf '  "%s" [label="%s\n%s/%s"];\n' "$esc_nid" "$esc_nid" "$runtime" "$agent"
    fi
  done <<< "$all_node_ids"

  # Edges (sorted by from+to+condition), expanding virtual ids.
  # Each row: from<TAB>to<TAB>reasons<TAB>condition (condition may be empty).
  local edges_tsv
  edges_tsv="$(jq -r '
    [.edges[] | {from: .from, to: .to, reasons: (.reasons | join(",")), condition: (.condition // "")}] |
    sort_by(.from + .to + .condition) | .[] |
    "\(.from)\t\(.to)\t\(.reasons)\t\(.condition)"
  ' "$graph_json")"

  if [[ -n "$edges_tsv" ]]; then
    local real_node_ids
    real_node_ids="$(jq -r '[.nodes[].id] | sort | join("\n")' "$graph_json")"

    while IFS=$'\t' read -r from to reasons condition; do
      [[ -z "$from" ]] && continue
      local esc_from comment
      esc_from="$(graph_render_escape_dot_string "$from")"
      comment="$(graph_render_reasons_comment "$reasons")"

      if printf '%s\n' "$real_node_ids" | grep -qx "$to"; then
        local esc_to
        esc_to="$(graph_render_escape_dot_string "$to")"
        if [[ -n "$condition" ]]; then
          printf '  // %s -> %s: [%s] %s\n' "$from" "$to" "$condition" "$comment"
          printf '  "%s" -> "%s" [label="%s"];\n' "$esc_from" "$esc_to" "$condition"
        else
          printf '  // %s -> %s: %s\n' "$from" "$to" "$comment"
          printf '  "%s" -> "%s";\n' "$esc_from" "$esc_to"
        fi
      else
        local voter_ids_for_virtual
        voter_ids_for_virtual="$(_graph_render_voters_for_virtual "$graph_json" "$to")"
        while IFS= read -r vid; do
          [[ -z "$vid" ]] && continue
          local esc_vid
          esc_vid="$(graph_render_escape_dot_string "$vid")"
          if [[ -n "$condition" ]]; then
            printf '  // %s -> %s: [%s] %s\n' "$from" "$vid" "$condition" "$comment"
            printf '  "%s" -> "%s" [label="%s"];\n' "$esc_from" "$esc_vid" "$condition"
          else
            printf '  // %s -> %s: %s\n' "$from" "$vid" "$comment"
            printf '  "%s" -> "%s";\n' "$esc_from" "$esc_vid"
          fi
        done <<< "$voter_ids_for_virtual"
      fi
    done <<< "$edges_tsv"
  fi

  printf '}\n'
}

# graph_render_ascii <graph-json-path>
graph_render_ascii() {
  local graph_json="$1"

  if ! command -v jq >/dev/null 2>&1; then
    echo "Error: jq is required for graph rendering" >&2
    return 1
  fi

  local graph_name node_count edge_count
  graph_name="$(jq -r '.name // "graph"' "$graph_json")"
  node_count="$(jq '.nodes | length' "$graph_json")"
  edge_count="$(jq '.edges | length' "$graph_json")"

  printf 'Graph: %s\n' "$graph_name"
  printf 'Nodes (%d):\n' "$node_count"

  # Consensus groups first, then regular nodes.
  local consensus_groups
  consensus_groups="$(_graph_render_consensus_groups "$graph_json")"
  local subgraph_members=""
  if [[ -n "$consensus_groups" ]]; then
    while IFS= read -r group; do
      [[ -z "$group" ]] && continue
      printf '  [consensus: %s]\n' "$group"

      local voter_ids
      voter_ids="$(_graph_render_voters_for_virtual "$graph_json" "$group")"

      while IFS= read -r nid; do
        [[ -z "$nid" ]] && continue
        local runtime agent annotation
        runtime="$(jq -r --arg id "$nid" '.nodes[] | select(.id == $id) | .stage.runtime // ""' "$graph_json")"
        agent="$(jq -r --arg id "$nid" '.nodes[] | select(.id == $id) | .stage.agent // ""' "$graph_json")"
        annotation="$(_graph_render_node_annotation "$graph_json" "$nid")"
        if [[ -n "$annotation" ]]; then
          printf '    %s  [voter, %s/%s, %s]\n' "$nid" "$runtime" "$agent" "$annotation"
        else
          printf '    %s  [voter, %s/%s]\n' "$nid" "$runtime" "$agent"
        fi
        subgraph_members="$subgraph_members
$nid"
      done <<< "$voter_ids"

      local barrier_id
      barrier_id="$(_graph_render_barrier_for_group "$graph_json" "$group")"
      if [[ -n "$barrier_id" ]]; then
        printf '    %s  [barrier]\n' "$barrier_id"
        subgraph_members="$subgraph_members
$barrier_id"
      fi
    done <<< "$consensus_groups"
  fi

  local all_node_ids
  all_node_ids="$(jq -r '[.nodes[].id] | sort[]' "$graph_json")"
  while IFS= read -r nid; do
    [[ -z "$nid" ]] && continue
    if printf '%s\n' "$subgraph_members" | grep -qx "$nid"; then
      continue
    fi
    local ntype runtime agent annotation
    ntype="$(jq -r --arg id "$nid" '.nodes[] | select(.id == $id) | .type' "$graph_json")"
    runtime="$(jq -r --arg id "$nid" '.nodes[] | select(.id == $id) | .stage.runtime // ""' "$graph_json")"
    agent="$(jq -r --arg id "$nid" '.nodes[] | select(.id == $id) | .stage.agent // ""' "$graph_json")"
    annotation="$(_graph_render_node_annotation "$graph_json" "$nid")"
    if [[ -n "$annotation" ]]; then
      printf '  %s  [%s, %s/%s, %s]\n' "$nid" "$ntype" "$runtime" "$agent" "$annotation"
    else
      printf '  %s  [%s, %s/%s]\n' "$nid" "$ntype" "$runtime" "$agent"
    fi
  done <<< "$all_node_ids"

  printf '\nEdges (%d):\n' "$edge_count"

  # Each row: from<TAB>to<TAB>reasons<TAB>condition (condition may be empty).
  local edges_tsv
  edges_tsv="$(jq -r '
    [.edges[] | {from: .from, to: .to, reasons: (.reasons | join(",")), condition: (.condition // "")}] |
    sort_by(.from + .to + .condition) | .[] |
    "\(.from)\t\(.to)\t\(.reasons)\t\(.condition)"
  ' "$graph_json")"

  if [[ -n "$edges_tsv" ]]; then
    local real_node_ids
    real_node_ids="$(jq -r '[.nodes[].id] | sort | join("\n")' "$graph_json")"

    while IFS=$'\t' read -r from to reasons condition; do
      [[ -z "$from" ]] && continue
      local comment
      comment="$(graph_render_reasons_comment "$reasons")"

      if printf '%s\n' "$real_node_ids" | grep -qx "$to"; then
        if [[ -n "$condition" ]]; then
          printf '  %s -[%s]-> %s  [%s]\n' "$from" "$condition" "$to" "$comment"
        else
          printf '  %s -> %s  [%s]\n' "$from" "$to" "$comment"
        fi
      else
        local voter_ids_for_virtual
        voter_ids_for_virtual="$(_graph_render_voters_for_virtual "$graph_json" "$to")"
        while IFS= read -r vid; do
          [[ -z "$vid" ]] && continue
          if [[ -n "$condition" ]]; then
            printf '  %s -[%s]-> %s  [%s]\n' "$from" "$condition" "$vid" "$comment"
          else
            printf '  %s -> %s  [%s]\n' "$from" "$vid" "$comment"
          fi
        done <<< "$voter_ids_for_virtual"
      fi
    done <<< "$edges_tsv"
  fi
}

# graph_render_stub <graph-json-path> <format>
# format is one of mermaid, dot, ascii. This is the public entry point called
# by graph_compile_cli after a successful compile. The name is kept stable for
# backward compatibility with graph-compile.sh.
graph_render_stub() {
  local graph_json_path="$1"
  local format="$2"

  if [[ ! -f "$graph_json_path" ]]; then
    echo "Error: graph JSON not found: $graph_json_path" >&2
    return 1
  fi

  case "$format" in
    mermaid) graph_render_mermaid "$graph_json_path" ;;
    dot)     graph_render_dot     "$graph_json_path" ;;
    ascii)   graph_render_ascii   "$graph_json_path" ;;
    *)
      echo "Error: unsupported render format '$format' (expected mermaid, dot, or ascii)" >&2
      return 1
      ;;
  esac
}

graph_render_cli_usage() {
  cat <<'EOF' >&2
Usage: graph-run.sh render <plan-path> [--format mermaid|dot|ascii] [--out <path>]

Render a compiled graph as mermaid, dot, or ascii. This is a pre-run static
view of the graph shape, not the live run state (see: graph-run.sh status).
Compiles the plan first if no fresh cached .graph.json exists beside it.

Options:
  --format <mermaid|dot|ascii>   Output format (default: mermaid).
  --out <path>                    Write rendered output to <path> instead of
                                   stdout.
  -h, --help                      Show this help.
EOF
}

# graph_render_cli <plan-path> [--format mermaid|dot|ascii] [--out <path>]
# Argument parsing and reporting for `ralph graph render`. Compiles the plan
# (reusing a fresh cached .graph.json when present) and prints the rendered
# graph to stdout, or writes it to --out when given.
graph_render_cli() {
  local plan_path="" format="mermaid" out_path=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --format)
        if [[ $# -lt 2 ]]; then
          echo "Error: --format requires a value" >&2
          graph_render_cli_usage
          return 1
        fi
        format="$2"
        shift 2
        ;;
      --format=*)
        format="${1#--format=}"
        shift
        ;;
      --out)
        if [[ $# -lt 2 ]]; then
          echo "Error: --out requires a value" >&2
          graph_render_cli_usage
          return 1
        fi
        out_path="$2"
        shift 2
        ;;
      --out=*)
        out_path="${1#--out=}"
        shift
        ;;
      -h|--help)
        graph_render_cli_usage
        return 0
        ;;
      --)
        shift
        break
        ;;
      -*)
        echo "Error: unknown option '$1'" >&2
        graph_render_cli_usage
        return 1
        ;;
      *)
        if [[ -n "$plan_path" ]]; then
          echo "Error: unexpected extra argument '$1'" >&2
          graph_render_cli_usage
          return 1
        fi
        plan_path="$1"
        shift
        ;;
    esac
  done

  if [[ -z "$plan_path" ]]; then
    echo "Error: graph render requires a plan path" >&2
    graph_render_cli_usage
    return 1
  fi

  case "$format" in
    mermaid|dot|ascii) ;;
    *)
      echo "Error: --format must be mermaid, dot, or ascii" >&2
      return 1
      ;;
  esac

  local cache_path
  cache_path="$(graph_compile_cache_path_for_plan "$plan_path")"
  if ! graph_compile_plan "$plan_path" "$cache_path" 0 >/dev/null; then
    return 1
  fi

  local rendered
  if ! rendered="$(graph_render_stub "$cache_path" "$format")"; then
    return 1
  fi

  if [[ -n "$out_path" ]]; then
    printf '%s\n' "$rendered" >"$out_path"
  else
    printf '%s\n' "$rendered"
  fi
}
