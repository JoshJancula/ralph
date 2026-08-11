#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF' >&2
Usage: validate-graph-schema.sh <graph-file>
Validate the structure of a .graph.json plan against the expected schema.
EOF
  exit 1
}

if [[ $# -ne 1 ]]; then
  usage
fi

graph_file="$1"

if [[ "$graph_file" == --* ]]; then
  usage
fi

if [[ ! -f "$graph_file" ]]; then
  echo "Graph schema validation failed: file not found: $graph_file" >&2
  exit 1
fi

root_type="$(jq -r 'type' "$graph_file" 2>/dev/null || true)"
if [[ "$root_type" != "object" ]]; then
  echo "Graph schema validation failed: root must be an object" >&2
  exit 1
fi

for key in schemaVersion ralphVersion name namespace maxParallel failurePolicy nodes edges; do
  if ! jq -e "has(\"$key\")" "$graph_file" >/dev/null 2>&1; then
    echo "Graph schema validation failed: missing required field $key" >&2
    exit 1
  fi
done

schema_version="$(jq -r '.schemaVersion' "$graph_file")"
if [[ "$schema_version" != "1" ]]; then
  echo "Graph schema validation failed: schemaVersion must be 1" >&2
  exit 1
fi

if [[ "$(jq -r '.ralphVersion | type' "$graph_file")" != "string" ]] || [[ -z "$(jq -r '.ralphVersion' "$graph_file")" ]]; then
  echo "Graph schema validation failed: ralphVersion must be a non-empty string" >&2
  exit 1
fi
if [[ "$(jq -r '.name | type' "$graph_file")" != "string" ]] || [[ -z "$(jq -r '.name' "$graph_file")" ]]; then
  echo "Graph schema validation failed: name must be a non-empty string" >&2
  exit 1
fi
if [[ "$(jq -r '.namespace | type' "$graph_file")" != "string" ]] || [[ -z "$(jq -r '.namespace' "$graph_file")" ]]; then
  echo "Graph schema validation failed: namespace must be a non-empty string" >&2
  exit 1
fi
if ! jq -e '.maxParallel | type == "number" and floor == . and . >= 1' "$graph_file" >/dev/null 2>&1; then
  echo "Graph schema validation failed: maxParallel must be a positive integer" >&2
  exit 1
fi
if ! jq -e '.failurePolicy | IN("drain", "cancel")' "$graph_file" >/dev/null 2>&1; then
  echo "Graph schema validation failed: failurePolicy must be drain or cancel" >&2
  exit 1
fi
if ! jq -e '.nodes | type == "array" and length > 0' "$graph_file" >/dev/null 2>&1; then
  echo "Graph schema validation failed: nodes must be a non-empty array" >&2
  exit 1
fi
if jq -e 'has("verificationProfiles")' "$graph_file" >/dev/null 2>&1; then
  if ! jq -e '
    (.verificationProfiles | type) == "array" and
    (.verificationProfiles | length) > 0 and
    all(.verificationProfiles[]; (.name | type == "string" and length > 0) and
      ((.steps | type) == "array") and (.steps | length) > 0 and
        all(.steps[]; (.name | type == "string" and length > 0) and
          (.command | type == "string" and length > 0) and
          ((.timeout // 300) | type == "number" and floor == . and . > 0) and
          ((.continueOnFailure // false) | type == "boolean") and
          (((.requiredArtifacts // []) | type) == "array") and
          all(.requiredArtifacts[]?; type == "string" and length > 0)))
  ' "$graph_file" >/dev/null 2>&1; then
    echo "Graph schema validation failed: verificationProfiles must contain named non-empty executable steps" >&2
    exit 1
  fi
  if [[ "$(jq -r '[.verificationProfiles[].name] | length == (unique | length)' "$graph_file")" != "true" ]]; then
    echo "Graph schema validation failed: verificationProfiles names must be unique" >&2
    exit 1
  fi
fi
  if ! jq -e '.edges | type == "array"' "$graph_file" >/dev/null 2>&1; then
  echo "Graph schema validation failed: edges must be an array" >&2
  exit 1
fi

node_ids="$(jq -r '.nodes[].id' "$graph_file")"
consensus_root_ids="$(jq -r '.nodes[] | select(.type == "consensus-voter" or .type == "consensus-barrier") | .id | split(":")[0]' "$graph_file" | sort -u)"
while IFS= read -r node; do
  [ -n "$node" ] || continue
  node_id="$(printf '%s' "$node" | jq -r '.id // empty')"
  node_type="$(printf '%s' "$node" | jq -r '.type // empty')"
  if [[ -z "$node_id" ]]; then
    echo "Graph schema validation failed: node missing required field id" >&2
    exit 1
  fi
  if [[ -z "$node_type" ]]; then
    echo "Graph schema validation failed: node $node_id missing required field type" >&2
    exit 1
  fi
  case "$node_type" in
    agent|stage|join|router|checkpoint|integrate|gate|consensus-voter|consensus-barrier) ;;
    *) echo "Graph schema validation failed: node $node_id: unknown node type $node_type" >&2; exit 1 ;;
  esac
  if ! printf '%s' "$node" | jq -e 'has("dependsOn") and has("derivedFrom") and has("stage")' >/dev/null 2>&1; then
    echo "Graph schema validation failed: node $node_id missing required graph fields" >&2
    exit 1
  fi
  while IFS= read -r dep; do
    [ -n "$dep" ] || continue
    if printf '%s\n' "$node_ids" | awk -v d="$dep" 'BEGIN{ok=0} $0==d{ok=1} END{exit ok?0:1}'; then
      continue
    fi
    if printf '%s\n' "$consensus_root_ids" | awk -v d="$dep" 'BEGIN{ok=0} $0==d{ok=1} END{exit ok?0:1}'; then
      continue
    fi
    if [[ "$node_type" == "consensus-voter" && "$dep" == "${node_id%%:*}" ]]; then
      continue
    fi
    if [[ "$node_type" == "consensus-barrier" ]]; then
      echo "Graph schema validation failed: node $node_id dependsOn references absent node" >&2
      exit 1
    fi
    echo "Graph schema validation failed: node $node_id dependsOn references absent node" >&2
    exit 1
  done < <(printf '%s' "$node" | jq -r '.dependsOn[]?')
done < <(jq -c '.nodes[]' "$graph_file")

while IFS= read -r gate; do
  [ -n "$gate" ] || continue
  gate_id="$(printf '%s' "$gate" | jq -r '.id')"
  gate_profile="$(printf '%s' "$gate" | jq -r '.stage.profile // empty')"
  [ -n "$gate_profile" ] || continue
  if ! jq -e --arg profile "$gate_profile" \
    'any(.verificationProfiles[]?; .name == $profile)' "$graph_file" >/dev/null 2>&1; then
    echo "Graph schema validation failed: gate $gate_id references unknown verification profile $gate_profile" >&2
    exit 1
  fi
done < <(jq -c '.nodes[] | select(.type == "gate")' "$graph_file")

while IFS= read -r edge; do
  [ -n "$edge" ] || continue
  from="$(printf '%s' "$edge" | jq -r '.from // empty')"
  to="$(printf '%s' "$edge" | jq -r '.to // empty')"
  reasons_present="$(printf '%s' "$edge" | jq -r 'has("reasons")')"
  if [[ -z "$from" || -z "$to" || "$reasons_present" != "true" ]]; then
    echo "Graph schema validation failed: edge missing required field" >&2
    exit 1
  fi
  if ! printf '%s\n' "$node_ids" | awk -v d="$from" 'BEGIN{ok=0} $0==d{ok=1} END{exit ok?0:1}' && \
     ! printf '%s\n' "$consensus_root_ids" | awk -v d="$from" 'BEGIN{ok=0} $0==d{ok=1} END{exit ok?0:1}'; then
    echo "Graph schema validation failed: edge $from references absent node" >&2
    exit 1
  fi
  if ! printf '%s\n' "$node_ids" | awk -v d="$to" 'BEGIN{ok=0} $0==d{ok=1} END{exit ok?0:1}' && \
     ! printf '%s\n' "$consensus_root_ids" | awk -v d="$to" 'BEGIN{ok=0} $0==d{ok=1} END{exit ok?0:1}'; then
    echo "Graph schema validation failed: edge $from -> $to references absent node" >&2
    exit 1
  fi
done < <(jq -c '.edges[]?' "$graph_file")
