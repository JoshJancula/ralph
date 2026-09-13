#!/usr/bin/env bash
# Validate compiled .graph.json structure, including optional resilience and
# budget objects. Existing graphs that omit those objects remain valid and
# parse as fail-fast with no token/cost ceilings.
#
# This file is a CLI (`validate-graph-schema.sh <graph-file>`) and may also
# be sourced for parse helpers used by later scheduler work.

if [ "${BASH_SOURCE[0]}" != "$0" ]; then
  if [[ -n "${GRAPH_SCHEMA_VALIDATE_LOADED:-}" ]]; then
    return 0
  fi
  GRAPH_SCHEMA_VALIDATE_LOADED=1
fi

set -euo pipefail

GRAPH_SCHEMA_RESILIENCE_KEYS='transientRetries
correctiveRetries
denialRecoveryTurns
backoffSeconds
mode'

GRAPH_SCHEMA_BUDGET_KEYS_GRAPH='maxAttempts
maxActiveSeconds
maxRunActiveSeconds
maxInputTokens
maxOutputTokens
maxEstimatedCostUsd
missingUsage'

GRAPH_SCHEMA_BUDGET_KEYS_NODE='maxAttempts
maxActiveSeconds
maxInputTokens
maxOutputTokens
maxEstimatedCostUsd
missingUsage'

GRAPH_SCHEMA_RESILIENCE_MODES='bounded
fail-fast'

GRAPH_SCHEMA_MISSING_USAGE_POLICIES='warn
fail
zero'

usage() {
  cat <<'EOF' >&2
Usage: validate-graph-schema.sh <graph-file>
Validate the structure of a .graph.json plan against the expected schema.
EOF
  exit 1
}

graph_schema_fail() {
  echo "Graph schema validation failed: $1" >&2
  return 1
}

# graph_schema_unknown_keys <json> <allowed-newline-list>
# Prints unknown object keys, one per line.
graph_schema_unknown_keys() {
  local json="$1" allowed="$2" allowed_json
  allowed_json="$(printf '%s\n' "$allowed" | jq -R . | jq -s -c .)"
  printf '%s' "$json" | jq -r --argjson allowed "$allowed_json" '
    if type != "object" then empty
    else (keys - $allowed)[]
    end
  '
}

# graph_schema_has_nonneg_int <json> <key>
# Returns 0 when the key is absent or a nonnegative integer.
graph_schema_has_nonneg_int() {
  local json="$1" key="$2"
  printf '%s' "$json" | jq -e --arg key "$key" '
    (has($key) | not) or (
      (.[$key] | type == "number") and
      (.[$key] | floor == .) and
      (.[$key] >= 0)
    )
  ' >/dev/null 2>&1
}

# graph_schema_has_nonneg_number <json> <key>
# Returns 0 when the key is absent or a nonnegative number.
graph_schema_has_nonneg_number() {
  local json="$1" key="$2"
  printf '%s' "$json" | jq -e --arg key "$key" '
    (has($key) | not) or (
      (.[$key] | type == "number") and
      (.[$key] >= 0)
    )
  ' >/dev/null 2>&1
}

# graph_schema_validate_backoff <json> <label>
graph_schema_validate_backoff() {
  local json="$1" label="$2"
  if ! printf '%s' "$json" | jq -e 'has("backoffSeconds")' >/dev/null 2>&1; then
    return 0
  fi
  if ! printf '%s' "$json" | jq -e '
    (.backoffSeconds | type == "array") and
    (.backoffSeconds | length >= 1) and
    (.backoffSeconds | length <= 2) and
    all(.backoffSeconds[]; type == "number" and . >= 0)
  ' >/dev/null 2>&1; then
    graph_schema_fail "${label}.backoffSeconds must be an array of 1 or 2 nonnegative numbers"
    return 1
  fi
  return 0
}

# graph_schema_validate_enum <json> <key> <allowed-newline-list> <label> <message>
graph_schema_validate_enum() {
  local json="$1" key="$2" allowed="$3" label="$4" message="$5" allowed_json
  if ! printf '%s' "$json" | jq -e --arg key "$key" 'has($key)' >/dev/null 2>&1; then
    return 0
  fi
  allowed_json="$(printf '%s\n' "$allowed" | jq -R . | jq -s -c .)"
  if ! printf '%s' "$json" | jq -e --arg key "$key" --argjson allowed "$allowed_json" '
    (.[$key] | type == "string") and (.[$key] | IN($allowed[]) )
  ' >/dev/null 2>&1; then
    graph_schema_fail "${label}.${key} ${message}"
    return 1
  fi
  return 0
}

# graph_schema_validate_resilience_object <json> <label>
graph_schema_validate_resilience_object() {
  local json="$1" label="$2" unknown key
  if [[ -z "$json" || "$json" == "null" ]]; then
    graph_schema_fail "${label} must be an object"
    return 1
  fi
  if [[ "$(printf '%s' "$json" | jq -r 'type')" != "object" ]]; then
    graph_schema_fail "${label} must be an object"
    return 1
  fi
  unknown="$(graph_schema_unknown_keys "$json" "$GRAPH_SCHEMA_RESILIENCE_KEYS" || true)"
  if [[ -n "$unknown" ]]; then
    key="$(printf '%s\n' "$unknown" | head -n 1)"
    graph_schema_fail "${label} has unknown field ${key}"
    return 1
  fi
  for key in transientRetries correctiveRetries denialRecoveryTurns; do
    if ! graph_schema_has_nonneg_int "$json" "$key"; then
      graph_schema_fail "${label}.${key} must be a nonnegative integer"
      return 1
    fi
  done
  graph_schema_validate_backoff "$json" "$label" || return 1
  graph_schema_validate_enum "$json" "mode" "$GRAPH_SCHEMA_RESILIENCE_MODES" \
    "$label" "must be bounded or fail-fast" || return 1
  return 0
}

# graph_schema_validate_budgets_object <json> <label> [scope]
# scope is graph (default) or node. Node objects may not set maxRunActiveSeconds.
graph_schema_validate_budgets_object() {
  local json="$1" label="$2" scope="${3:-graph}" allowed unknown key
  if [[ -z "$json" || "$json" == "null" ]]; then
    graph_schema_fail "${label} must be an object"
    return 1
  fi
  if [[ "$(printf '%s' "$json" | jq -r 'type')" != "object" ]]; then
    graph_schema_fail "${label} must be an object"
    return 1
  fi
  if [[ "$scope" == "node" ]]; then
    allowed="$GRAPH_SCHEMA_BUDGET_KEYS_NODE"
  else
    allowed="$GRAPH_SCHEMA_BUDGET_KEYS_GRAPH"
  fi
  unknown="$(graph_schema_unknown_keys "$json" "$allowed" || true)"
  if [[ -n "$unknown" ]]; then
    key="$(printf '%s\n' "$unknown" | head -n 1)"
    graph_schema_fail "${label} has unknown field ${key}"
    return 1
  fi
  for key in maxAttempts maxActiveSeconds maxRunActiveSeconds maxInputTokens maxOutputTokens; do
    if [[ "$scope" == "node" && "$key" == "maxRunActiveSeconds" ]]; then
      continue
    fi
    if ! graph_schema_has_nonneg_int "$json" "$key"; then
      graph_schema_fail "${label}.${key} must be a nonnegative integer"
      return 1
    fi
  done
  if ! graph_schema_has_nonneg_number "$json" "maxEstimatedCostUsd"; then
    graph_schema_fail "${label}.maxEstimatedCostUsd must be a nonnegative number"
    return 1
  fi
  graph_schema_validate_enum "$json" "missingUsage" "$GRAPH_SCHEMA_MISSING_USAGE_POLICIES" \
    "$label" "must be warn, fail, or zero" || return 1
  return 0
}

# graph_schema_declared_object <graph-file> <top-key>
# Prints the compiled-graph object at .<key> or .pipeline.<key>, or null.
graph_schema_declared_object() {
  local graph_file="$1" key="$2"
  local cache_name value

  # Per-process memo. This is the hottest jq call in a graph run: a five-node
  # scheduler test resolved the same (file, key) pair 42 times, each one a
  # ~19ms jq fork against an identical file. The compiled graph is frozen for
  # the life of a run -- preflight refuses an unfrozen graph.json and nothing
  # in the scheduling path writes it -- so a memo cannot go stale. Each
  # dispatch is a fresh process, which bounds the cache lifetime naturally.
  #
  # bash 3.2 has no associative arrays, so the key is a sanitized dynamic
  # variable name. The sanitization is pure parameter expansion: adding a fork
  # here would defeat the point.
  cache_name="_GRAPH_SCHEMA_DECL_${graph_file}_${key}"
  cache_name="${cache_name//[^A-Za-z0-9_]/_}"
  if [[ -n "${!cache_name+set}" ]]; then
    printf '%s\n' "${!cache_name}"
    return 0
  fi

  value="$(jq -c --arg key "$key" '
    if has($key) then .[$key]
    elif (has("pipeline") and (.pipeline | type == "object") and (.pipeline | has($key))) then .pipeline[$key]
    else null
    end
  ' "$graph_file")" || return 1

  printf -v "$cache_name" '%s' "$value"
  printf '%s\n' "$value"
}

# graph_schema_parse_resilience_object <json-or-null>
# Resolves retry/backoff/mode. Omitted objects are fail-fast.
# A present object uses conservative bounded defaults for missing fields,
# unless mode is fail-fast (retry counts default to 0).
graph_schema_parse_resilience_object() {
  local declared="${1:-null}" defaults
  if [[ -z "$declared" || "$declared" == "null" ]]; then
    jq -nc '{
      transientRetries: 0,
      correctiveRetries: 0,
      denialRecoveryTurns: 0,
      backoffSeconds: [2, 10],
      mode: "fail-fast"
    }'
    return 0
  fi
  graph_schema_validate_resilience_object "$declared" "resilience" || return 1
  if [[ "$(printf '%s' "$declared" | jq -r '.mode // empty')" == "fail-fast" ]]; then
    defaults='{"transientRetries":0,"correctiveRetries":0,"denialRecoveryTurns":0,"backoffSeconds":[2,10],"mode":"fail-fast"}'
  else
    defaults='{"transientRetries":2,"correctiveRetries":2,"denialRecoveryTurns":1,"backoffSeconds":[2,10],"mode":"bounded"}'
  fi
  jq -nc --argjson d "$defaults" --argjson o "$declared" '$d + $o'
}

# graph_schema_parse_budgets_object <json-or-null> [scope]
# Omitted objects keep token/cost/active-time ceilings unset (null) and use
# missingUsage=warn. A present object applies conservative active-time
# defaults (3600 node / 21600 run) and still does not invent token/cost ceilings.
graph_schema_parse_budgets_object() {
  local declared="${1:-null}" scope="${2:-graph}" defaults
  if [[ -z "$declared" || "$declared" == "null" ]]; then
    # Compile-time constant: emit it directly rather than forking jq to render
    # a fixed literal. This is the single hottest jq call in a graph run (42 of
    # 683 forks in a five-node scheduler test), and the sibling default objects
    # below are already plain strings.
    printf '%s\n' '{"maxAttempts":null,"maxActiveSeconds":null,"maxRunActiveSeconds":null,"maxInputTokens":null,"maxOutputTokens":null,"maxEstimatedCostUsd":null,"missingUsage":"warn"}'
    return 0
  fi
  graph_schema_validate_budgets_object "$declared" "budgets" "$scope" || return 1
  if [[ "$scope" == "node" ]]; then
    defaults='{"maxAttempts":null,"maxActiveSeconds":3600,"maxInputTokens":null,"maxOutputTokens":null,"maxEstimatedCostUsd":null,"missingUsage":"warn"}'
  else
    defaults='{"maxAttempts":null,"maxActiveSeconds":3600,"maxRunActiveSeconds":21600,"maxInputTokens":null,"maxOutputTokens":null,"maxEstimatedCostUsd":null,"missingUsage":"warn"}'
  fi
  jq -nc --argjson d "$defaults" --argjson o "$declared" '$d + $o'
}

# graph_schema_parse_resilience <graph-file> [node-id]
graph_schema_parse_resilience() {
  local graph_file="$1" node_id="${2:-}" declared node_declared parsed
  declared="$(graph_schema_declared_object "$graph_file" "resilience")"
  parsed="$(graph_schema_parse_resilience_object "$declared")" || return 1
  if [[ -n "$node_id" ]]; then
    node_declared="$(jq -c --arg id "$node_id" '
      [.nodes[]? | select(.id == $id) | .resilience // empty] | first // null
    ' "$graph_file")"
    if [[ -n "$node_declared" && "$node_declared" != "null" ]]; then
      graph_schema_validate_resilience_object "$node_declared" "node ${node_id} resilience" || return 1
      parsed="$(jq -nc --argjson g "$parsed" --argjson n "$node_declared" '$g + $n')"
    fi
  fi
  printf '%s\n' "$parsed"
}

# graph_schema_parse_budgets <graph-file> [node-id]
graph_schema_parse_budgets() {
  local graph_file="$1" node_id="${2:-}" declared node_declared parsed
  declared="$(graph_schema_declared_object "$graph_file" "budgets")"
  parsed="$(graph_schema_parse_budgets_object "$declared" "graph")" || return 1
  if [[ -n "$node_id" ]]; then
    node_declared="$(jq -c --arg id "$node_id" '
      [.nodes[]? | select(.id == $id) | .budgets // empty] | first // null
    ' "$graph_file")"
    if [[ -n "$node_declared" && "$node_declared" != "null" ]]; then
      graph_schema_validate_budgets_object "$node_declared" "node ${node_id} budgets" "node" || return 1
      parsed="$(jq -nc --argjson g "$parsed" --argjson n "$node_declared" '$g + $n')"
    fi
  fi
  printf '%s\n' "$parsed"
}

# graph_schema_validate_limits <graph-file>
graph_schema_validate_limits() {
  local graph_file="$1" declared node node_id
  if jq -e 'has("resilience")' "$graph_file" >/dev/null 2>&1; then
    declared="$(jq -c '.resilience' "$graph_file")"
    graph_schema_validate_resilience_object "$declared" "resilience" || return 1
  fi
  if jq -e 'has("pipeline") and (.pipeline | type == "object") and (.pipeline | has("resilience"))' \
    "$graph_file" >/dev/null 2>&1; then
    declared="$(jq -c '.pipeline.resilience' "$graph_file")"
    graph_schema_validate_resilience_object "$declared" "pipeline.resilience" || return 1
  fi
  if jq -e 'has("budgets")' "$graph_file" >/dev/null 2>&1; then
    declared="$(jq -c '.budgets' "$graph_file")"
    graph_schema_validate_budgets_object "$declared" "budgets" "graph" || return 1
  fi
  if jq -e 'has("pipeline") and (.pipeline | type == "object") and (.pipeline | has("budgets"))' \
    "$graph_file" >/dev/null 2>&1; then
    declared="$(jq -c '.pipeline.budgets' "$graph_file")"
    graph_schema_validate_budgets_object "$declared" "pipeline.budgets" "graph" || return 1
  fi

  while IFS= read -r node; do
    [ -n "$node" ] || continue
    node_id="$(printf '%s' "$node" | jq -r '.id // empty')"
    [ -n "$node_id" ] || continue
    if printf '%s' "$node" | jq -e 'has("resilience")' >/dev/null 2>&1; then
      declared="$(printf '%s' "$node" | jq -c '.resilience')"
      graph_schema_validate_resilience_object "$declared" "node ${node_id} resilience" || return 1
    fi
    if printf '%s' "$node" | jq -e 'has("budgets")' >/dev/null 2>&1; then
      declared="$(printf '%s' "$node" | jq -c '.budgets')"
      graph_schema_validate_budgets_object "$declared" "node ${node_id} budgets" "node" || return 1
    fi
  done < <(jq -c '.nodes[]?' "$graph_file")
  return 0
}

# graph_schema_validate_file <graph-file>
graph_schema_validate_file() {
  local graph_file="$1"
  local root_type schema_version node_ids consensus_root_ids
  local node node_id node_type dep gate gate_id gate_profile
  local edge from to reasons_present

  if [[ ! -f "$graph_file" ]]; then
    graph_schema_fail "file not found: $graph_file"
    return 1
  fi

  root_type="$(jq -r 'type' "$graph_file" 2>/dev/null || true)"
  if [[ "$root_type" != "object" ]]; then
    graph_schema_fail "root must be an object"
    return 1
  fi

  local key
  for key in schemaVersion ralphVersion name namespace maxParallel failurePolicy nodes edges; do
    if ! jq -e "has(\"$key\")" "$graph_file" >/dev/null 2>&1; then
      graph_schema_fail "missing required field $key"
      return 1
    fi
  done

  schema_version="$(jq -r '.schemaVersion' "$graph_file")"
  if [[ "$schema_version" != "2" ]]; then
    graph_schema_fail "schemaVersion must be 2"
    return 1
  fi

  # Optional run-wide tool exposure. Never per node: it is a property of the
  # whole run, and the plan parser rejects it on a stage.
  if jq -e 'has("ralphMode")' "$graph_file" >/dev/null 2>&1; then
    case "$(jq -r '.ralphMode' "$graph_file")" in
      no | native | ralph | hybrid) ;;
      *)
        graph_schema_fail "ralphMode must be one of: no, native, ralph, hybrid"
        return 1
        ;;
    esac
  fi
  # Optional per-node tooling profile override. When present it must name one
  # of the profiles declared in tooling-profiles.json (single source of truth).
  if jq -e '[.nodes[] | select(.stage.toolingProfile != null)] | length > 0' "$graph_file" >/dev/null 2>&1; then
    local tooling_profiles_path
    tooling_profiles_path="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/tooling-profiles.json"
    if [[ -f "$tooling_profiles_path" ]]; then
      if ! jq -e --slurpfile profiles_doc "$tooling_profiles_path" '
          ($profiles_doc[0].profiles // {}) as $profiles |
          [.nodes[] | select(.stage.toolingProfile != null) | .stage.toolingProfile] |
          all(. as $name | $profiles | has($name))
        ' "$graph_file" >/dev/null 2>&1; then
        graph_schema_fail "toolingProfile on a node must be one of the declared tooling-profiles.json profile names"
        return 1
      fi
    fi
  fi

  if [[ "$(jq -r '.ralphVersion | type' "$graph_file")" != "string" ]] || [[ -z "$(jq -r '.ralphVersion' "$graph_file")" ]]; then
    graph_schema_fail "ralphVersion must be a non-empty string"
    return 1
  fi
  if [[ "$(jq -r '.name | type' "$graph_file")" != "string" ]] || [[ -z "$(jq -r '.name' "$graph_file")" ]]; then
    graph_schema_fail "name must be a non-empty string"
    return 1
  fi
  if [[ "$(jq -r '.namespace | type' "$graph_file")" != "string" ]] || [[ -z "$(jq -r '.namespace' "$graph_file")" ]]; then
    graph_schema_fail "namespace must be a non-empty string"
    return 1
  fi
  if ! jq -e '.maxParallel | type == "number" and floor == . and . >= 1' "$graph_file" >/dev/null 2>&1; then
    graph_schema_fail "maxParallel must be a positive integer"
    return 1
  fi
  if ! jq -e '.failurePolicy | IN("drain", "cancel")' "$graph_file" >/dev/null 2>&1; then
    graph_schema_fail "failurePolicy must be drain or cancel"
    return 1
  fi
  if ! jq -e '.nodes | type == "array" and length > 0' "$graph_file" >/dev/null 2>&1; then
    graph_schema_fail "nodes must be a non-empty array"
    return 1
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
      graph_schema_fail "verificationProfiles must contain named non-empty executable steps"
      return 1
    fi
    if [[ "$(jq -r '[.verificationProfiles[].name] | length == (unique | length)' "$graph_file")" != "true" ]]; then
      graph_schema_fail "verificationProfiles names must be unique"
      return 1
    fi
  fi
  if ! jq -e '.edges | type == "array"' "$graph_file" >/dev/null 2>&1; then
    graph_schema_fail "edges must be an array"
    return 1
  fi

  node_ids="$(jq -r '.nodes[].id' "$graph_file")"
  consensus_root_ids="$(jq -r '.nodes[] | select(.type == "consensus-voter" or .type == "consensus-barrier") | .id | split(":")[0]' "$graph_file" | sort -u)"
  while IFS= read -r node; do
    [ -n "$node" ] || continue
    node_id="$(printf '%s' "$node" | jq -r '.id // empty')"
    node_type="$(printf '%s' "$node" | jq -r '.type // empty')"
    if [[ -z "$node_id" ]]; then
      graph_schema_fail "node missing required field id"
      return 1
    fi
    if [[ -z "$node_type" ]]; then
      graph_schema_fail "node $node_id missing required field type"
      return 1
    fi
    case "$node_type" in
      agent|stage|join|router|checkpoint|integrate|gate|approval|consensus-voter|consensus-barrier) ;;
      *) graph_schema_fail "node $node_id: unknown node type $node_type"; return 1 ;;
    esac
    if ! printf '%s' "$node" | jq -e 'has("dependsOn") and has("derivedFrom") and has("stage")' >/dev/null 2>&1; then
      graph_schema_fail "node $node_id missing required graph fields"
      return 1
    fi
    if [[ "$node_type" == "approval" ]]; then
      # Public Dependency approval is a frozen supervisor boundary: never
      # checkpoint/humanAck vocabulary, never agent/runtime fields.
      if ! printf '%s' "$node" | jq -e '
          (.stage.type // "") == "approval"
          and ((.stage.question // "") | type == "string" and length > 0)
          and ((.stage.changesTarget // "") | type == "string" and length > 0)
          and ((.dependsOn | type) == "array" and (.dependsOn | length) > 0)
          and (
            ((.stage.inputArtifacts // []) | type == "array" and length > 0)
            or ((.stage.requires // []) | type == "array" and length > 0)
          )
          and (.stage.humanAck // null) == null
          and (.stage.runtime // null) == null
          and (.stage.model // null) == null
          and (.stage.agent // null) == null
          and (.stage.role // null) == null
          and (.stage.plan // null) == null
          and (.stage.planFile // null) == null
          and (.stage.planFrom // null) == null
        ' >/dev/null 2>&1; then
        graph_schema_fail "node $node_id: approval requires question, changesTarget, dependsOn, and required artifacts without agent/runtime/plan/humanAck fields"
        return 1
      fi
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
      graph_schema_fail "node $node_id dependsOn references absent node"
      return 1
    done < <(printf '%s' "$node" | jq -r '.dependsOn[]?')
  done < <(jq -c '.nodes[]' "$graph_file")

  while IFS= read -r gate; do
    [ -n "$gate" ] || continue
    gate_id="$(printf '%s' "$gate" | jq -r '.id')"
    gate_profile="$(printf '%s' "$gate" | jq -r '.stage.profile // empty')"
    [ -n "$gate_profile" ] || continue
    if ! jq -e --arg profile "$gate_profile" \
      'any(.verificationProfiles[]?; .name == $profile)' "$graph_file" >/dev/null 2>&1; then
      graph_schema_fail "gate $gate_id references unknown verification profile $gate_profile"
      return 1
    fi
  done < <(jq -c '.nodes[] | select(.type == "gate")' "$graph_file")

  while IFS= read -r edge; do
    [ -n "$edge" ] || continue
    from="$(printf '%s' "$edge" | jq -r '.from // empty')"
    to="$(printf '%s' "$edge" | jq -r '.to // empty')"
    reasons_present="$(printf '%s' "$edge" | jq -r 'has("reasons")')"
    if [[ -z "$from" || -z "$to" || "$reasons_present" != "true" ]]; then
      graph_schema_fail "edge missing required field"
      return 1
    fi
    if ! printf '%s\n' "$node_ids" | awk -v d="$from" 'BEGIN{ok=0} $0==d{ok=1} END{exit ok?0:1}' && \
       ! printf '%s\n' "$consensus_root_ids" | awk -v d="$from" 'BEGIN{ok=0} $0==d{ok=1} END{exit ok?0:1}'; then
      graph_schema_fail "edge $from references absent node"
      return 1
    fi
    if ! printf '%s\n' "$node_ids" | awk -v d="$to" 'BEGIN{ok=0} $0==d{ok=1} END{exit ok?0:1}' && \
       ! printf '%s\n' "$consensus_root_ids" | awk -v d="$to" 'BEGIN{ok=0} $0==d{ok=1} END{exit ok?0:1}'; then
      graph_schema_fail "edge $from -> $to references absent node"
      return 1
    fi
  done < <(jq -c '.edges[]?' "$graph_file")

  graph_schema_validate_limits "$graph_file" || return 1
  return 0
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  if [[ $# -ne 1 ]]; then
    usage
  fi
  graph_file="$1"
  if [[ "$graph_file" == --* ]]; then
    usage
  fi
  graph_schema_validate_file "$graph_file"
fi
