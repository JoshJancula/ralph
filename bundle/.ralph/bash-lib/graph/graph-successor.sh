#!/usr/bin/env bash
# Successor reuse comparison and linked-run creation for graph runs.
#
# Compares an old frozen graph (the predecessor run) with a new frozen graph
# and the predecessor's completion fingerprints. A node is reusable only when
# it succeeded and its definition, ancestors, inputs, artifacts, changeset
# evidence, and gates are unchanged. Every nonreused node receives one or
# more stable reason tokens.
#
# graph_successor_reuse_report is read-only and never writes ledger, graph,
# artifact, or workspace files. graph_successor_create writes only a new
# successor run directory: it freezes the new graph, records predecessor
# id/digests, and copies validated reusable evidence. The predecessor run
# is left byte-stable.

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  echo "This file is meant to be sourced, not executed." >&2
  exit 1
fi

if [[ -n "${GRAPH_SUCCESSOR_LOADED:-}" ]]; then
  return 0
fi
GRAPH_SUCCESSOR_LOADED=1

GRAPH_SUCCESSOR_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GRAPH_SUCCESSOR_SCHEMA_VERSION=1

if ! declare -F graph_state_run_dir >/dev/null 2>&1; then
  # shellcheck source=./graph-state.sh
  source "$GRAPH_SUCCESSOR_SCRIPT_DIR/graph-state.sh"
fi

# graph_successor_sha256_text <string>
graph_successor_sha256_text() {
  local value="$1"
  if command -v sha256sum >/dev/null 2>&1; then
    printf '%s' "$value" | sha256sum | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    printf '%s' "$value" | shasum -a 256 | awk '{print $1}'
  elif command -v openssl >/dev/null 2>&1; then
    printf '%s' "$value" | openssl dgst -sha256 | awk '{print $NF}'
  else
    echo "Error: no sha256 tool available" >&2
    return 1
  fi
}

# graph_successor_sha256_file <path>
# Prints "missing" when the path is absent; "unreadable" when hashing fails.
graph_successor_sha256_file() {
  local path="$1"
  if [[ -z "$path" || ! -f "$path" ]]; then
    printf 'missing\n'
    return 0
  fi
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$path" | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$path" | awk '{print $1}'
  elif command -v openssl >/dev/null 2>&1; then
    openssl dgst -sha256 "$path" | awk '{print $NF}'
  else
    printf 'unreadable\n'
  fi
}

# graph_successor_safe_id <node_id>
graph_successor_safe_id() {
  printf '%s' "$1" | sed 's/[^A-Za-z0-9._-]/_/g'
}

# graph_successor_node_ids <graph_json>
graph_successor_node_ids() {
  local graph_json="$1"
  [[ -n "$graph_json" && -f "$graph_json" ]] || return 1
  jq -r '.nodes[]?.id // empty' "$graph_json" 2>/dev/null
}

# graph_successor_node_exists <graph_json> <node_id>
graph_successor_node_exists() {
  local graph_json="$1" node_id="$2"
  [[ -n "$graph_json" && -f "$graph_json" && -n "$node_id" ]] || return 1
  jq -e --arg id "$node_id" 'any(.nodes[]?; .id == $id)' "$graph_json" >/dev/null 2>&1
}

# graph_successor_definition_json <graph_json> <node_id>
# Canonical node work contract: id, type, and stage.
graph_successor_definition_json() {
  local graph_json="$1" node_id="$2"
  [[ -n "$graph_json" && -f "$graph_json" && -n "$node_id" ]] || return 1
  jq -cS --arg id "$node_id" '
    (.nodes[] | select(.id == $id) | {id, type: (.type // "agent"), stage: (.stage // {})}) // empty
  ' "$graph_json" 2>/dev/null
}

# graph_successor_definition_digest <graph_json> <node_id>
graph_successor_definition_digest() {
  local graph_json="$1" node_id="$2" def
  def="$(graph_successor_definition_json "$graph_json" "$node_id")" || return 1
  [[ -n "$def" ]] || return 1
  graph_successor_sha256_text "$def"
}

# graph_successor_ancestor_ids <graph_json> <node_id>
# Prints sorted ancestor ids (inbound transitive closure over edges, with
# dependsOn as a fallback when an inbound edge is absent).
graph_successor_ancestor_ids() {
  local graph_json="$1" node_id="$2"
  [[ -n "$graph_json" && -f "$graph_json" && -n "$node_id" ]] || return 1
  jq -r --arg id "$node_id" '
    def inbound($start; $edges; $nodes):
      {seen: [], frontier: [$start]}
      | until(
          .frontier | length == 0;
          . as $s
          | $s.frontier as $f
          | (
              [ $f[] as $n | $edges[] | select(.to == $n) | .from ]
              + [ $f[] as $n
                  | ($nodes[] | select(.id == $n) | .dependsOn // [])[]
                  | if type == "string" then .
                    else (.id // .node // empty) end ]
            ) as $next
          | (($s.seen + $f) | unique) as $seen2
          | {seen: $seen2, frontier: ($next | unique | map(select(. != "")) | . - $seen2)}
        )
      | .seen;
    inbound($id; (.edges // []); (.nodes // []))
    | map(select(. != $id and . != ""))
    | unique
    | sort
    | .[]
  ' "$graph_json" 2>/dev/null
}

# graph_successor_exchange_path <state_root> <namespace> <declared>
graph_successor_exchange_path() {
  local state_root="$1" namespace="$2" declared="$3"
  printf '%s/artifacts/%s/exchange/%s\n' "$state_root" "$namespace" "$declared"
}

# graph_successor_declared_artifacts <graph_json> <node_id> <field>
# field is inputArtifacts or output. "output" unions outputArtifacts + artifacts.
# Prints canonical JSON array of {path, required, sha256} with sha256 "pending"
# (caller fills hashes).
graph_successor_declared_artifact_specs() {
  local graph_json="$1" node_id="$2" field="$3"
  [[ -n "$graph_json" && -f "$graph_json" && -n "$node_id" ]] || return 1
  case "$field" in
    input|inputArtifacts)
      jq -cS --arg id "$node_id" '
        [.nodes[] | select(.id == $id) | (.stage.inputArtifacts // [])[]
          | if type == "string" then {path: ., required: true}
            else {path: (.path // ""), required: (.required // true)} end
          | select(.path != "")]
        | unique_by(.path)
        | sort_by(.path)
      ' "$graph_json" 2>/dev/null
      ;;
    output|artifacts)
      jq -cS --arg id "$node_id" '
        [.nodes[] | select(.id == $id)
          | ((.stage.outputArtifacts // []) + (.stage.artifacts // []))[]
          | if type == "string" then {path: ., required: true}
            else {path: (.path // ""), required: (.required // true)} end
          | select(.path != "")]
        | unique_by(.path)
        | sort_by(.path)
      ' "$graph_json" 2>/dev/null
      ;;
    *)
      return 1
      ;;
  esac
}

# graph_successor_resolve_artifact_records <specs_json> <state_root> <namespace>
graph_successor_resolve_artifact_records() {
  local specs="$1" state_root="$2" namespace="$3"
  local records path required digest resolved
  records='[]'
  [[ -n "$specs" ]] || { printf '[]\n'; return 0; }
  while IFS=$'\t' read -r path required || [[ -n "$path" ]]; do
    [[ -n "$path" ]] || continue
    resolved="$(graph_successor_exchange_path "$state_root" "$namespace" "$path")"
    digest="$(graph_successor_sha256_file "$resolved")"
    records="$(jq -c --arg p "$path" --argjson req "$required" --arg h "$digest" \
      '. + [{path:$p, required:$req, sha256:$h}]' <<<"$records")" || return 1
  done < <(printf '%s' "$specs" | jq -r '.[] | [.path, (.required|tostring)] | @tsv')
  jq -cS . <<<"$records"
}

# graph_successor_changeset_path <run_dir> <node_id>
# Resolves the predecessor changeset manifest. Prefers a filename matching the
# sanitized id, then any manifest whose nodeId matches.
graph_successor_changeset_path() {
  local run_dir="$1" node_id="$2" safe candidate
  [[ -n "$run_dir" && -n "$node_id" ]] || return 1
  safe="$(graph_successor_safe_id "$node_id")"
  candidate="$run_dir/changesets/nodes/${safe}.json"
  if [[ -f "$candidate" ]]; then
    printf '%s\n' "$candidate"
    return 0
  fi
  if [[ -d "$run_dir/changesets/nodes" ]]; then
    for candidate in "$run_dir/changesets/nodes"/*.json; do
      [[ -f "$candidate" ]] || continue
      if jq -e --arg id "$node_id" '.nodeId == $id' "$candidate" >/dev/null 2>&1; then
        printf '%s\n' "$candidate"
        return 0
      fi
    done
  fi
  return 1
}

# graph_successor_gate_result_path <state_root> <namespace> <node_id>
graph_successor_gate_result_path() {
  local state_root="$1" namespace="$2" node_id="$3" safe
  safe="$(graph_successor_safe_id "$node_id")"
  printf '%s/artifacts/%s/gate/%s/gate-result.json\n' "$state_root" "$namespace" "$safe"
}

# graph_successor_node_ledger_field <workspace> <namespace> <run_id> <node_id> <field>
graph_successor_node_ledger_field() {
  local workspace="$1" namespace="$2" run_id="$3" node_id="$4" field="$5"
  local node_file
  node_file="$(graph_state_node_file "$workspace" "$namespace" "$run_id" "$node_id")" || return 1
  [[ -f "$node_file" ]] || return 1
  jq -r --arg f "$field" '
    (.[$f] // .attempts[-1][$f] // empty)
  ' "$node_file" 2>/dev/null
}

# graph_successor_changeset_fingerprint <graph_json> <workspace> <namespace> <run_id> <node_id>
graph_successor_changeset_fingerprint() {
  local graph_json="$1" workspace="$2" namespace="$3" run_id="$4" node_id="$5"
  local run_dir scopes ledger_hash path file_hash identity
  run_dir="$(graph_state_run_dir "$workspace" "$namespace" "$run_id")" || return 1
  scopes="$(jq -cS --arg id "$node_id" '
    (.nodes[] | select(.id == $id) | .stage.writeScopes // []) // []
  ' "$graph_json" 2>/dev/null)" || scopes='[]'
  ledger_hash="$(graph_successor_node_ledger_field "$workspace" "$namespace" "$run_id" "$node_id" "changesetHash" 2>/dev/null || true)"
  path=""
  path="$(graph_successor_changeset_path "$run_dir" "$node_id" 2>/dev/null || true)"
  file_hash="missing"
  identity=""
  if [[ -n "$path" && -f "$path" ]]; then
    file_hash="$(graph_successor_sha256_file "$path")"
    identity="$(jq -r '.contentIdentity // empty' "$path" 2>/dev/null || true)"
  fi
  if [[ -z "$ledger_hash" ]]; then
    ledger_hash="$file_hash"
  fi
  if [[ "$file_hash" == "missing" && "$ledger_hash" != "missing" && -n "$ledger_hash" ]]; then
    file_hash="$ledger_hash"
  fi
  jq -cnS --argjson scopes "$scopes" --arg hash "$file_hash" --arg ident "$identity" --arg ledger "$ledger_hash" \
    '{writeScopes:$scopes, sha256:$hash, contentIdentity:$ident, ledgerHash:$ledger}'
}

# graph_successor_gate_required <graph_json> <node_id>
graph_successor_gate_required() {
  local graph_json="$1" node_id="$2"
  jq -e --arg id "$node_id" '
    .nodes[] | select(.id == $id) |
    ((.type // "agent") == "gate") or ((.stage.verificationProfile // "") != "")
  ' "$graph_json" >/dev/null 2>&1
}

# graph_successor_gate_fingerprint <graph_json> <workspace> <namespace> <run_id> <node_id>
graph_successor_gate_fingerprint() {
  local graph_json="$1" workspace="$2" namespace="$3" run_id="$4" node_id="$5"
  local state_root profile profile_json profile_digest outcome result_path result_hash
  state_root="$(graph_state_state_root "$workspace")" || return 1
  profile="$(jq -r --arg id "$node_id" '
    (.nodes[] | select(.id == $id) | .stage.verificationProfile // "")
  ' "$graph_json" 2>/dev/null)"
  profile_json="$(jq -cS --arg name "$profile" '
    if $name == "" then {}
    else (.verificationProfiles // [] | map(select(.name == $name)) | .[0] // {})
    end
  ' "$graph_json" 2>/dev/null)" || profile_json='{}'
  if [[ "$profile_json" == "{}" ]]; then
    profile_digest="none"
  else
    profile_digest="$(graph_successor_sha256_text "$profile_json")" || return 1
  fi
  outcome="$(graph_successor_node_ledger_field "$workspace" "$namespace" "$run_id" "$node_id" "gateOutcome" 2>/dev/null || true)"
  [[ -n "$outcome" ]] || outcome="none"
  result_path="$(graph_successor_gate_result_path "$state_root" "$namespace" "$node_id")"
  result_hash="$(graph_successor_sha256_file "$result_path")"
  jq -cnS --arg profile "$profile" --arg digest "$profile_digest" --arg outcome "$outcome" --arg hash "$result_hash" \
    '{profile:$profile, profileDigest:$digest, outcome:$outcome, sha256:$hash}'
}

# graph_successor_completion_fingerprint <graph_json> <workspace> <namespace> <run_id> <node_id>
# Prints one canonical JSON object covering definition, ancestors, inputs,
# artifacts, changeset evidence, and gates, plus a digest over that object.
graph_successor_completion_fingerprint() {
  local graph_json="$1" workspace="$2" namespace="$3" run_id="$4" node_id="$5"
  local state_root definition ancestors_json ancestor_id ancestor_def
  local input_specs output_specs inputs artifacts changeset gates digest body

  [[ -n "$graph_json" && -f "$graph_json" && -n "$workspace" && -n "$namespace" && -n "$run_id" && -n "$node_id" ]] || return 1
  command -v jq >/dev/null 2>&1 || return 1
  state_root="$(graph_state_state_root "$workspace")" || return 1

  definition="$(graph_successor_definition_digest "$graph_json" "$node_id")" || return 1

  ancestors_json='[]'
  while IFS= read -r ancestor_id || [[ -n "$ancestor_id" ]]; do
    [[ -n "$ancestor_id" ]] || continue
    ancestor_def="$(graph_successor_definition_digest "$graph_json" "$ancestor_id" 2>/dev/null || true)"
    [[ -n "$ancestor_def" ]] || ancestor_def="missing"
    ancestors_json="$(jq -c --arg id "$ancestor_id" --arg d "$ancestor_def" \
      '. + [{id:$id, definition:$d}]' <<<"$ancestors_json")" || return 1
  done < <(graph_successor_ancestor_ids "$graph_json" "$node_id")
  ancestors_json="$(jq -cS 'sort_by(.id)' <<<"$ancestors_json")" || return 1

  input_specs="$(graph_successor_declared_artifact_specs "$graph_json" "$node_id" "input")" || input_specs='[]'
  output_specs="$(graph_successor_declared_artifact_specs "$graph_json" "$node_id" "output")" || output_specs='[]'
  inputs="$(graph_successor_resolve_artifact_records "$input_specs" "$state_root" "$namespace")" || return 1
  artifacts="$(graph_successor_resolve_artifact_records "$output_specs" "$state_root" "$namespace")" || return 1
  changeset="$(graph_successor_changeset_fingerprint "$graph_json" "$workspace" "$namespace" "$run_id" "$node_id")" || return 1
  gates="$(graph_successor_gate_fingerprint "$graph_json" "$workspace" "$namespace" "$run_id" "$node_id")" || return 1

  body="$(jq -cnS --arg definition "$definition" --argjson ancestors "$ancestors_json" \
    --argjson inputs "$inputs" --argjson artifacts "$artifacts" \
    --argjson changeset "$changeset" --argjson gates "$gates" \
    '{definition:$definition, ancestors:$ancestors, inputs:$inputs, artifacts:$artifacts, changeset:$changeset, gates:$gates}')" || return 1
  digest="$(graph_successor_sha256_text "$body")" || return 1
  jq -cnS --argjson body "$body" --arg digest "$digest" '$body + {digest:$digest}'
}

# graph_successor_required_evidence_missing <graph_json> <fingerprint_json> <node_id>
# Prints zero or more missing-evidence reason tokens.
graph_successor_required_evidence_missing() {
  local graph_json="$1" fingerprint="$2" node_id="$3"
  local scopes_len
  scopes_len="$(printf '%s' "$fingerprint" | jq -r '.changeset.writeScopes | length')"
  if [[ "$scopes_len" -gt 0 ]]; then
    if [[ "$(printf '%s' "$fingerprint" | jq -r '.changeset.sha256')" == "missing" ]]; then
      printf 'missing-evidence:changeset\n'
    fi
  fi
  if graph_successor_gate_required "$graph_json" "$node_id"; then
    if [[ "$(printf '%s' "$fingerprint" | jq -r '.gates.sha256')" == "missing" ]]; then
      printf 'missing-evidence:gate\n'
    fi
  fi
  printf '%s' "$fingerprint" | jq -r '
    (.inputs + .artifacts)[]
    | select(.required == true and .sha256 == "missing")
    | "missing-evidence:artifact:" + .path
  '
}

# _graph_successor_dim_changed <old_fp> <new_fp> <jq_path>
_graph_successor_dim_changed() {
  local old_fp="$1" new_fp="$2" path="$3" old_v new_v
  old_v="$(printf '%s' "$old_fp" | jq -cS "$path")"
  new_v="$(printf '%s' "$new_fp" | jq -cS "$path")"
  [[ "$old_v" != "$new_v" ]]
}

# graph_successor_compare_fingerprints <old_fp> <new_fp>
# Prints reason tokens for dimensions that differ.
graph_successor_compare_fingerprints() {
  local old_fp="$1" new_fp="$2"
  _graph_successor_dim_changed "$old_fp" "$new_fp" '.definition' && printf 'definition-changed\n'
  _graph_successor_dim_changed "$old_fp" "$new_fp" '.ancestors' && printf 'ancestors-changed\n'
  _graph_successor_dim_changed "$old_fp" "$new_fp" '.inputs' && printf 'inputs-changed\n'
  _graph_successor_dim_changed "$old_fp" "$new_fp" '.artifacts' && printf 'artifacts-changed\n'
  _graph_successor_dim_changed "$old_fp" "$new_fp" '.changeset' && printf 'changeset-changed\n'
  _graph_successor_dim_changed "$old_fp" "$new_fp" '.gates' && printf 'gates-changed\n'
}

# graph_successor_reuse_report <old_graph> <new_graph> <workspace> <namespace> <run_id>
# Prints a deterministic JSON report. Exit 0 on a successful comparison.
# Never writes predecessor state.
graph_successor_reuse_report() {
  local old_graph="$1" new_graph="$2" workspace="$3" namespace="$4" run_id="$5"
  local tmp run_file run_id_field old_sha new_sha
  local node_id status node_file stored_fp old_fp new_fp
  local reasons_file nodes_file report reasons_json reuse ancestor_id

  if [[ -z "$old_graph" || ! -f "$old_graph" || -z "$new_graph" || ! -f "$new_graph" ]]; then
    echo "Error: graph_successor_reuse_report requires existing old and new frozen graphs" >&2
    return 1
  fi
  if [[ -z "$workspace" || -z "$namespace" || -z "$run_id" ]]; then
    echo "Error: graph_successor_reuse_report requires workspace, namespace, and run_id" >&2
    return 1
  fi
  command -v jq >/dev/null 2>&1 || return 1

  state_root="$(graph_state_state_root "$workspace")" || return 1
  run_file="$(graph_state_run_file "$workspace" "$namespace" "$run_id")" || return 1
  run_id_field="$run_id"
  if [[ -f "$run_file" ]]; then
    run_id_field="$(jq -r '.runId // empty' "$run_file" 2>/dev/null)"
    [[ -n "$run_id_field" ]] || run_id_field="$run_id"
  fi
  old_sha="$(graph_state_compute_graph_sha "$old_graph" 2>/dev/null || true)"
  new_sha="$(graph_state_compute_graph_sha "$new_graph" 2>/dev/null || true)"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/ralph-successor.XXXXXX")" || return 1
  reasons_file="$tmp/reasons"
  nodes_file="$tmp/nodes.jsonl"
  mkdir -p "$reasons_file"
  : >"$nodes_file"

  # Pass 1: local reasons for every node in the new graph.
  while IFS= read -r node_id || [[ -n "$node_id" ]]; do
    [[ -n "$node_id" ]] || continue
    : >"$reasons_file/$node_id"

    if ! graph_successor_node_exists "$old_graph" "$node_id"; then
      printf 'added\n' >>"$reasons_file/$node_id"
      continue
    fi

    node_file="$(graph_state_node_file "$workspace" "$namespace" "$run_id" "$node_id" 2>/dev/null || true)"
    status=""
    if [[ -z "$node_file" || ! -f "$node_file" ]]; then
      printf 'missing-ledger\n' >>"$reasons_file/$node_id"
      printf 'not-succeeded\n' >>"$reasons_file/$node_id"
    else
      status="$(jq -r '.status // empty' "$node_file" 2>/dev/null || true)"
      if [[ "$status" != "succeeded" ]]; then
        if [[ -n "$status" ]]; then
          printf 'not-succeeded:%s\n' "$status" >>"$reasons_file/$node_id"
        else
          printf 'not-succeeded\n' >>"$reasons_file/$node_id"
        fi
      fi
    fi

    old_fp="$(graph_successor_completion_fingerprint "$old_graph" "$workspace" "$namespace" "$run_id" "$node_id" 2>/dev/null || true)"
    new_fp="$(graph_successor_completion_fingerprint "$new_graph" "$workspace" "$namespace" "$run_id" "$node_id" 2>/dev/null || true)"
    if [[ -z "$old_fp" || -z "$new_fp" ]]; then
      printf 'missing-evidence\n' >>"$reasons_file/$node_id"
    else
      graph_successor_compare_fingerprints "$old_fp" "$new_fp" >>"$reasons_file/$node_id" || true
      graph_successor_required_evidence_missing "$new_graph" "$new_fp" "$node_id" >>"$reasons_file/$node_id" || true
      stored_fp=""
      if [[ -n "$node_file" && -f "$node_file" ]]; then
        stored_fp="$(jq -c '.completionFingerprint // empty' "$node_file" 2>/dev/null || true)"
      fi
      if [[ -n "$stored_fp" && "$stored_fp" != "null" ]]; then
        graph_successor_compare_fingerprints "$stored_fp" "$old_fp" >>"$reasons_file/$node_id" || true
      fi
    fi
  done < <(graph_successor_node_ids "$new_graph" | sort)

  # Pass 2: a nonreused ancestor invalidates every descendant. Pass-1
  # reasons are already complete, including transitive ancestor definition
  # mismatches, so this pass only needs those local files.
  while IFS= read -r node_id || [[ -n "$node_id" ]]; do
    [[ -n "$node_id" ]] || continue
    while IFS= read -r ancestor_id || [[ -n "$ancestor_id" ]]; do
      [[ -n "$ancestor_id" ]] || continue
      if [[ -s "$reasons_file/$ancestor_id" ]]; then
        printf 'ancestor-not-reused:%s\n' "$ancestor_id" >>"$reasons_file/$node_id"
      fi
    done < <(graph_successor_ancestor_ids "$new_graph" "$node_id")
  done < <(graph_successor_node_ids "$new_graph" | sort)

  # Pass 3: emit deterministic node objects.
  while IFS= read -r node_id || [[ -n "$node_id" ]]; do
    [[ -n "$node_id" ]] || continue
    reasons_json="$(sort -u "$reasons_file/$node_id" 2>/dev/null | sed '/^$/d' | jq -Rsc 'split("\n") | map(select(length > 0))')"
    [[ -n "$reasons_json" ]] || reasons_json='[]'
    if [[ "$reasons_json" == "[]" ]]; then
      reuse="true"
    else
      reuse="false"
    fi
    jq -cn --arg id "$node_id" --argjson reuse "$reuse" --argjson reasons "$reasons_json" \
      '{id:$id, reuse:$reuse, reasons:$reasons}' >>"$nodes_file"
  done < <(graph_successor_node_ids "$new_graph" | sort)

  report="$(jq -nS --argjson sv "$GRAPH_SUCCESSOR_SCHEMA_VERSION" \
    --arg run "$run_id_field" --arg ns "$namespace" \
    --arg oldsha "${old_sha:-}" --arg newsha "${new_sha:-}" \
    --slurpfile nodes "$nodes_file" \
    '{
      schemaVersion: $sv,
      readOnly: true,
      predecessorRunId: $run,
      namespace: $ns,
      oldGraphSha: (if $oldsha == "" then null else $oldsha end),
      newGraphSha: (if $newsha == "" then null else $newsha end),
      reusable: [$nodes[] | select(.reuse == true) | .id],
      nodes: $nodes
    }')" || {
    rm -rf "$tmp"
    return 1
  }
  rm -rf "$tmp"
  printf '%s\n' "$report"
}

# graph_successor_node_reusable <report_json> <node_id>
# Returns 0 when the named node is marked reusable in a prior report.
graph_successor_node_reusable() {
  local report="$1" node_id="$2"
  printf '%s' "$report" | jq -e --arg id "$node_id" \
    'any(.nodes[]; .id == $id and .reuse == true)' >/dev/null 2>&1
}

# graph_successor_copy_file <src> <dst>
# Byte-preserving copy via temp+rename in the destination directory.
graph_successor_copy_file() {
  local src="$1" dst="$2" dest_dir tmp
  [[ -n "$src" && -f "$src" && -n "$dst" ]] || return 1
  dest_dir="$(dirname "$dst")"
  mkdir -p "$dest_dir" || return 1
  tmp="$(mktemp "$dest_dir/.succ-copy-XXXXXX")" || return 1
  if ! cp "$src" "$tmp"; then
    rm -f "$tmp"
    return 1
  fi
  if ! mv -f "$tmp" "$dst"; then
    rm -f "$tmp"
    return 1
  fi
}

# graph_successor_record_predecessor <run_file> <predecessor_run_id>
#   <predecessor_graph_sha> <predecessor_run_sha>
# Merges predecessor id/digests into an already-written successor run.json.
graph_successor_record_predecessor() {
  local run_file="$1" pred_run_id="$2" pred_graph_sha="$3" pred_run_sha="$4"
  local base
  [[ -n "$run_file" && -f "$run_file" && -n "$pred_run_id" ]] || return 1
  command -v jq >/dev/null 2>&1 || return 1
  if ! declare -F ralph_atomic_write_json >/dev/null 2>&1; then
    echo "Error: ralph_atomic_write_json is required to record predecessor metadata" >&2
    return 1
  fi
  base="$(jq -c . "$run_file")" || return 1
  ralph_atomic_write_json "$run_file" \
    '($base | fromjson) + {
      predecessorRunId: $pid,
      predecessorGraphSha: (if $pgs == "" then null else $pgs end),
      predecessorRunSha: (if $prs == "" then null else $prs end)
    }' \
    --arg base "$base" \
    --arg pid "$pred_run_id" \
    --arg pgs "${pred_graph_sha:-}" \
    --arg prs "${pred_run_sha:-}"
}

# graph_successor_copy_reusable_evidence <workspace> <namespace>
#   <predecessor_run_id> <successor_run_id> <report_json>
# Copies node ledgers and changeset manifests for reusable nodes only.
# Never writes into the predecessor run directory.
graph_successor_copy_reusable_evidence() {
  local workspace="$1" namespace="$2" pred_run_id="$3" new_run_id="$4" report="$5"
  local pred_run_dir new_run_dir node_id src dst

  [[ -n "$workspace" && -n "$namespace" && -n "$pred_run_id" && -n "$new_run_id" && -n "$report" ]] || return 1
  pred_run_dir="$(graph_state_run_dir "$workspace" "$namespace" "$pred_run_id")" || return 1
  new_run_dir="$(graph_state_run_dir "$workspace" "$namespace" "$new_run_id")" || return 1
  if [[ "$pred_run_dir" == "$new_run_dir" ]]; then
    echo "Error: successor run directory must differ from predecessor" >&2
    return 1
  fi

  while IFS= read -r node_id || [[ -n "$node_id" ]]; do
    [[ -n "$node_id" ]] || continue
    src="$(graph_state_node_file "$workspace" "$namespace" "$pred_run_id" "$node_id")" || return 1
    dst="$(graph_state_node_file "$workspace" "$namespace" "$new_run_id" "$node_id")" || return 1
    if [[ ! -f "$src" ]]; then
      echo "Error: reusable node $node_id is missing predecessor ledger evidence" >&2
      return 1
    fi
    case "$dst" in
      "$new_run_dir"/*) ;;
      *)
        echo "Error: refused to write node ledger outside successor run" >&2
        return 1
        ;;
    esac
    graph_successor_copy_file "$src" "$dst" || {
      echo "Error: failed to copy reusable node ledger for $node_id" >&2
      return 1
    }

    src=""
    src="$(graph_successor_changeset_path "$pred_run_dir" "$node_id" 2>/dev/null || true)"
    if [[ -n "$src" && -f "$src" ]]; then
      dst="$new_run_dir/changesets/nodes/$(basename "$src")"
      case "$dst" in
        "$new_run_dir"/*) ;;
        *)
          echo "Error: refused to write changeset outside successor run" >&2
          return 1
          ;;
      esac
      graph_successor_copy_file "$src" "$dst" || {
        echo "Error: failed to copy reusable changeset for $node_id" >&2
        return 1
      }
    fi
  done < <(printf '%s' "$report" | jq -r '.reusable[]? // empty')
}

# graph_successor_create <workspace> <namespace> <predecessor_run_id>
#   <new_graph_path> <plan_path> [new_run_id] [max_parallel]
#
# Creates a linked successor run. Writes a new run directory, freezes
# <new_graph_path>, records predecessorRunId plus graph/run digests, copies
# only reusable node ledgers and changeset manifests, and leaves changed or
# added nodes pending. Never mutates the predecessor. Prints a JSON result
# with successorRunId, predecessor digests, reusable/pending ids, and the
# reuse report nodes.
graph_successor_create() {
  local workspace="$1" namespace="$2" pred_run_id="$3" new_graph="$4" plan_path="$5"
  local new_run_id="${6:-}" max_parallel="${7:-}"
  local pred_run_dir pred_run_file pred_graph new_run_dir new_run_file
  local pred_graph_sha pred_run_sha new_graph_sha report result

  if [[ -z "$workspace" || -z "$namespace" || -z "$pred_run_id" || -z "$new_graph" || -z "$plan_path" ]]; then
    echo "Error: graph_successor_create requires workspace, namespace, predecessor_run_id, new_graph, and plan_path" >&2
    return 1
  fi
  if [[ ! -f "$new_graph" ]]; then
    echo "Error: graph_successor_create new graph not found: $new_graph" >&2
    return 1
  fi
  command -v jq >/dev/null 2>&1 || return 1

  pred_run_dir="$(graph_state_run_dir "$workspace" "$namespace" "$pred_run_id")" || return 1
  pred_run_file="$(graph_state_run_file "$workspace" "$namespace" "$pred_run_id")" || return 1
  pred_graph="$(graph_state_graph_file "$workspace" "$namespace" "$pred_run_id")" || return 1
  if [[ ! -d "$pred_run_dir" || ! -f "$pred_run_file" || ! -f "$pred_graph" ]]; then
    echo "Error: predecessor run $pred_run_id is missing a frozen graph or run ledger" >&2
    return 1
  fi

  if [[ -z "$new_run_id" ]]; then
    new_run_id="$(graph_state_mint_run_id)" || return 1
  fi
  if [[ "$new_run_id" == "$pred_run_id" ]]; then
    echo "Error: successor run id must differ from predecessor $pred_run_id" >&2
    return 1
  fi

  new_run_dir="$(graph_state_run_dir "$workspace" "$namespace" "$new_run_id")" || return 1
  new_run_file="$(graph_state_run_file "$workspace" "$namespace" "$new_run_id")" || return 1
  if [[ -f "$new_run_file" || -f "$(graph_state_graph_file "$workspace" "$namespace" "$new_run_id")" ]]; then
    echo "Error: successor run already exists: $new_run_id" >&2
    return 1
  fi
  if [[ "$new_run_dir" == "$pred_run_dir" ]]; then
    echo "Error: successor run directory must differ from predecessor" >&2
    return 1
  fi

  pred_run_sha="$(graph_successor_sha256_file "$pred_run_file")" || return 1
  if [[ "$pred_run_sha" == "missing" || "$pred_run_sha" == "unreadable" ]]; then
    echo "Error: cannot digest predecessor run ledger $pred_run_file" >&2
    return 1
  fi

  report="$(graph_successor_reuse_report "$pred_graph" "$new_graph" "$workspace" "$namespace" "$pred_run_id")" || {
    echo "Error: graph_successor_create failed to compute reuse report" >&2
    return 1
  }
  pred_graph_sha="$(printf '%s' "$report" | jq -r '.oldGraphSha // empty')"
  new_graph_sha="$(printf '%s' "$report" | jq -r '.newGraphSha // empty')"
  [[ -n "$pred_graph_sha" ]] || pred_graph_sha="$(graph_state_compute_graph_sha "$pred_graph" 2>/dev/null || true)"
  [[ -n "$new_graph_sha" ]] || new_graph_sha="$(graph_state_compute_graph_sha "$new_graph" 2>/dev/null || true)"

  if [[ -z "$max_parallel" ]]; then
    max_parallel="$(jq -r '.maxParallel // empty' "$new_graph" 2>/dev/null || true)"
  fi
  if [[ -z "$max_parallel" ]]; then
    max_parallel="$(jq -r '.maxParallel // empty' "$pred_run_file" 2>/dev/null || true)"
  fi
  [[ "$max_parallel" =~ ^[1-9][0-9]*$ ]] || max_parallel=2

  if ! graph_state_init_run_v2 "$workspace" "$namespace" "$new_run_id" "$plan_path" "$new_graph" "$max_parallel"; then
    echo "Error: failed to initialize successor run $new_run_id" >&2
    return 1
  fi

  if ! graph_successor_record_predecessor "$new_run_file" "$pred_run_id" "$pred_graph_sha" "$pred_run_sha"; then
    echo "Error: failed to record predecessor metadata on successor run $new_run_id" >&2
    return 1
  fi

  if ! graph_successor_copy_reusable_evidence "$workspace" "$namespace" "$pred_run_id" "$new_run_id" "$report"; then
    echo "Error: failed to copy reusable evidence into successor run $new_run_id" >&2
    return 1
  fi

  result="$(jq -nS --argjson report "$report" --arg sid "$new_run_id" --arg prid "$pred_run_id" \
    --arg pgs "${pred_graph_sha:-}" --arg prs "$pred_run_sha" --arg gs "${new_graph_sha:-}" \
    '{
      schemaVersion: $report.schemaVersion,
      successorRunId: $sid,
      predecessorRunId: $prid,
      predecessorGraphSha: (if $pgs == "" then null else $pgs end),
      predecessorRunSha: $prs,
      graphSha: (if $gs == "" then null else $gs end),
      reusable: $report.reusable,
      pending: [($report.nodes // [])[] | select(.reuse == false) | .id],
      nodes: ($report.nodes // [])
    }')" || {
    echo "Error: failed to build successor create result" >&2
    return 1
  }
  printf '%s\n' "$result"
}
