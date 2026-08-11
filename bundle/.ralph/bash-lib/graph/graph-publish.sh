#!/usr/bin/env bash
# Guarded graph handoff and optional publication to the caller workspace.

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  echo "This file is meant to be sourced, not executed." >&2
  exit 1
fi

GRAPH_PUBLISH_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GRAPH_PUBLISH_RALPH_ROOT="$(cd "$GRAPH_PUBLISH_SCRIPT_DIR/../.." && pwd)"
GRAPH_PUBLISH_HELPER="$GRAPH_PUBLISH_RALPH_ROOT/python/graph_publish.py"
GRAPH_PUBLISH_CHANGESET_HELPER="$GRAPH_PUBLISH_RALPH_ROOT/python/graph_changeset.py"
GRAPH_PUBLISH_SNAPSHOT_HELPER="$GRAPH_PUBLISH_RALPH_ROOT/python/graph_source_snapshot.py"

if ! declare -F ralph_atomic_write_json >/dev/null 2>&1; then
  # shellcheck source=../atomic-json.sh
  source "$GRAPH_PUBLISH_SCRIPT_DIR/../atomic-json.sh"
fi
if ! declare -F graph_run_base_git_metadata >/dev/null 2>&1; then
  # shellcheck source=graph-run-base.sh
  source "$GRAPH_PUBLISH_SCRIPT_DIR/graph-run-base.sh"
fi
if ! declare -F graph_workspace_node_key >/dev/null 2>&1; then
  # shellcheck source=graph-workspace-manager.sh
  source "$GRAPH_PUBLISH_SCRIPT_DIR/graph-workspace-manager.sh"
fi

graph_publish_log() {
  local log_file="$1"
  shift
  mkdir -p "$(dirname "$log_file")" 2>/dev/null || true
  printf '%s graph-publish: %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*" >>"$log_file"
}

graph_publish_filesystem_identity() {
  local workspace="$1" state_root="$2" exclude_file="$3"
  python3 "$GRAPH_PUBLISH_SNAPSHOT_HELPER" identity \
    --source "$workspace" --state-root "$state_root" --exclude-file "$exclude_file" |
    jq -r '.filesystemIdentity'
}

graph_publish_recovery_command() {
  local plan_path="$1" namespace="$2" run_id="$3"
  printf 'ralph graph resume %q --namespace %q --run %q' "$plan_path" "$namespace" "$run_id"
}

graph_publish_update_run() {
  local run_file="$1" mode="$2" status="$3" handoff="$4" detail="$5"
  local base_json readiness_json
  base_json="$(jq -c . "$run_file")" || return 1
  readiness_json="$(jq -cn \
    --arg mode "$mode" \
    --arg status "$status" \
    --arg handoff "${handoff:-}" \
    --arg detail "${detail:-}" \
    '{
       mode: $mode,
       status: $status,
       handoffPath: (if $handoff == "" then null else $handoff end),
       detail: (if $detail == "" then null else $detail end)
     }')"
  ralph_atomic_write_json "$run_file" \
    '(($base | fromjson) // {}) + {
      publishReadiness: $readiness,
      publish: {
        schemaVersion: 1,
        mode: $mode,
        status: $status,
        handoffPath: $handoff,
        detail: (if $detail == "" then null else $detail end),
        updatedAt: $now
      }
    }' \
    --arg base "$base_json" --argjson readiness "$readiness_json" \
    --arg mode "$mode" --arg status "$status" \
    --arg handoff "$handoff" --arg detail "$detail" \
    --arg now "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
}

graph_publish_write_handoff() {
  local handoff="$1" mode="$2" status="$3" verified="$4" run_id="$5"
  local caller="$6" integration="$7" manifest="$8" bundle="$9" recovery="${10}"
  local command="${11}" detail="${12}"
  ralph_atomic_write_json "$handoff" \
    '{
      schemaVersion: 1,
      kind: "graph-publish-handoff",
      runId: $runId,
      publishMode: $mode,
      status: $status,
      verified: $verified,
      callerWorkspace: $caller,
      integrationWorkspace: (if $integration == "" then null else $integration end),
      changesetManifest: (if $manifest == "" then null else $manifest end),
      changesetBundle: (if $bundle == "" then null else $bundle end),
      recoveryArtifact: $recovery,
      retryCommand: $command,
      detail: (if $detail == "" then null else $detail end),
      updatedAt: $now
    }' \
    --arg runId "$run_id" --arg mode "$mode" --arg status "$status" \
    --argjson verified "$verified" --arg caller "$caller" \
    --arg integration "$integration" --arg manifest "$manifest" --arg bundle "$bundle" \
    --arg recovery "$recovery" --arg command "$command" --arg detail "$detail" \
    --arg now "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
}

graph_publish_refuse() {
  local run_dir="$1" mode="$2" handoff="$3" caller="$4" integration="$5"
  local manifest="$6" bundle="$7" recovery="$8" command="$9" detail="${10}" log_file="${11}"
  ralph_atomic_write_json "$recovery" \
    '{
      schemaVersion: 1,
      kind: "graph-publish-recovery",
      status: "refused",
      callerWorkspace: $caller,
      integrationWorkspace: (if $integration == "" then null else $integration end),
      detail: $detail,
      instructions: [
        "Do not reset, stash, checkout, overwrite, or delete caller changes.",
        "Preserve caller changes and resolve the stated refusal without altering the retained integration workspace.",
        ("Retry with: " + $command)
      ],
      updatedAt: $now
    }' \
    --arg caller "$caller" --arg integration "$integration" --arg detail "$detail" \
    --arg command "$command" --arg now "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" || return 1
  graph_publish_write_handoff "$handoff" "$mode" refused false \
    "$(jq -r '.runId' "$run_dir/run.json")" "$caller" "$integration" "$manifest" \
    "$bundle" "$recovery" "$command" "$detail" || return 1
  graph_publish_update_run "$run_dir/run.json" "$mode" refused "$handoff" "$detail" || return 1
  graph_publish_log "$log_file" "refused detail=$detail integration=$integration"
  echo "Error: graph publish refused: $detail" >&2
  echo "Recovery: $recovery" >&2
  return 1
}

graph_publish_delegations_complete() {
  local run_dir="$1"
  python3 - "$run_dir/nodes" <<'PY'
import json
import pathlib
import sys

root = pathlib.Path(sys.argv[1])
bad = []
for path in root.glob("*/delegations/*/status.json"):
    try:
        status = json.loads(path.read_text(encoding="utf-8")).get("status")
    except (OSError, ValueError):
        status = "invalid"
    # Cancellation is an explicit parent acknowledgement and the parent TODO
    # completion gate already proved that all non-cancelled children supplied
    # their required evidence. A replaceable cancelled request is therefore a
    # valid terminal child state for publish.
    if status not in {"succeeded", "cancelled"}:
        bad.append((str(path), status))
if bad:
    for path, status in bad:
        print(f"{status}:{path}", file=sys.stderr)
    raise SystemExit(1)
PY
}

# graph_publish_finalize <run-dir> <graph-json> <caller-workspace>
graph_publish_finalize() {
  local run_dir="$1" graph_json="$2" caller="$3"
  local run_file="$run_dir/run.json" mode namespace run_id state_root artifact_root publish_dir
  local handoff status_file recovery journal log_file command run_status node_bad delegation_bad
  local integration_id integration_key integration_manifest integration_workspace result_identity candidate safe_candidate
  local base_identity base_manifest changeset_dir changeset_manifest bundle bundle_tmp exclude_file
  local expected_git current_git current_identity detail existing_status
  [[ -f "$run_file" && -f "$graph_json" && -d "$caller" ]] || return 1
  mode="$(jq -r '.publishMode // "manual"' "$graph_json")"
  [[ "$mode" == "manual" || "$mode" == "on-verified" ]] || {
    echo "Error: invalid graph publish mode: $mode" >&2
    return 1
  }
  namespace="$(jq -r '.namespace' "$graph_json")"
  run_id="$(jq -r '.runId' "$run_file")"
  state_root="$(jq -r '.roots.stateRoot // empty' "$run_file")"
  if [[ -z "$state_root" || ! -d "$state_root" ]]; then
    echo "Error: graph publish requires a valid recorded state root" >&2
    return 1
  fi
  artifact_root="$state_root/artifacts/$namespace"
  publish_dir="$artifact_root/publish/$run_id"
  handoff="$publish_dir/handoff.json"
  status_file="$publish_dir/status.json"
  recovery="$publish_dir/recovery.json"
  journal="$publish_dir/publish-journal.jsonl"
  log_file="$artifact_root/publish-guard.log"
  command="$(graph_publish_recovery_command "$(jq -r '.planPath' "$run_file")" "$namespace" "$run_id")"
  mkdir -p "$publish_dir" || return 1
  graph_publish_log "$log_file" "guard-start run=$run_id mode=$mode caller=$caller"

  existing_status="$(jq -r '.status // empty' "$status_file" 2>/dev/null || true)"
  if [[ "$existing_status" == "published" ]]; then
    exclude_file="$(mktemp "${TMPDIR:-/tmp}/ralph-publish-excludes.XXXXXX")" || return 1
    jq -r '.sourceBase.secretExcludes[]? // empty' "$run_file" >"$exclude_file"
    current_identity="$(graph_publish_filesystem_identity "$caller" "$state_root" "$exclude_file")" || {
      rm -f "$exclude_file"; return 1;
    }
    rm -f "$exclude_file"
    if [[ "$current_identity" == "$(jq -r '.filesystemIdentity' "$status_file")" ]]; then
      graph_publish_log "$log_file" "already-published run=$run_id identity=$current_identity"
      return 0
    fi
    graph_publish_refuse "$run_dir" "$mode" "$handoff" "$caller" "" "" "" \
      "$recovery" "$command" "caller drift after completed publish; no action taken" "$log_file"
    return
  fi

  run_status="$(jq -r '.status // empty' "$run_file")"
  # A conditional branch not selected by a successful gate is terminally
  # skipped, not incomplete. Guarded publish accepts those scheduler-owned
  # skips while continuing to reject every other non-success state.
  node_bad="$(jq -r -s '[.[] | select(.status != "succeeded" and .status != "skipped") | (.nodeId + ":" + .status)] | join(",")' "$run_dir"/nodes/*.json 2>/dev/null || echo invalid-ledger)"
  if [[ "$run_status" != "succeeded" || -n "$node_bad" ]]; then
    detail="required gates incomplete or failed: run=$run_status nodes=${node_bad:-none}"
    graph_publish_refuse "$run_dir" "$mode" "$handoff" "$caller" "" "" "" \
      "$recovery" "$command" "$detail" "$log_file"
    return
  fi
  delegation_bad="$(graph_publish_delegations_complete "$run_dir" 2>&1)" || {
    detail="incomplete delegations: $delegation_bad"
    graph_publish_refuse "$run_dir" "$mode" "$handoff" "$caller" "" "" "" \
      "$recovery" "$command" "$detail" "$log_file"
    return
  }

  # Repair expansion can leave later integrate nodes terminally skipped after
  # the first gate passes. Publish the last integration that actually
  # succeeded, not merely the last integrate node in frozen graph order.
  integration_id=""
  while IFS= read -r candidate || [[ -n "$candidate" ]]; do
    [[ -n "$candidate" ]] || continue
    safe_candidate="$(printf '%s' "$candidate" | sed 's/[^A-Za-z0-9._-]/_/g')"
    if [[ "$(jq -r '.status // empty' "$run_dir/nodes/$safe_candidate.json" 2>/dev/null)" == "succeeded" ]]; then
      integration_id="$candidate"
    fi
  done < <(jq -r '.nodes[] | select(.type == "integrate") | .id' "$graph_json")
  if [[ -z "$integration_id" ]]; then
    if [[ "$mode" == "manual" ]]; then
      graph_publish_write_handoff "$handoff" "$mode" not-applicable true "$run_id" \
        "$caller" "" "" "" "$recovery" "$command" "graph has no integration node" || return 1
      graph_publish_update_run "$run_file" "$mode" not-applicable "$handoff" \
        "graph has no integration node" || return 1
      graph_publish_log "$log_file" "not-applicable run=$run_id no-integration-node"
      return 0
    fi
    graph_publish_refuse "$run_dir" "$mode" "$handoff" "$caller" "" "" "" \
      "$recovery" "$command" "on-verified publishing requires a successful integration node" "$log_file"
    return
  fi
  integration_key="$(graph_workspace_node_key "$integration_id")" || return 1
  integration_manifest="$artifact_root/integration/$integration_key.json"
  if [[ ! -f "$integration_manifest" ]]; then
    graph_publish_refuse "$run_dir" "$mode" "$handoff" "$caller" "" "" "" \
      "$recovery" "$command" "integration result manifest is missing" "$log_file"
    return
  fi
  integration_workspace="$(jq -r '.workspacePath // empty' "$integration_manifest")"
  result_identity="$(jq -r '.resultIdentity // empty' "$integration_manifest")"
  if [[ ! -d "$integration_workspace" || -z "$result_identity" ]]; then
    graph_publish_refuse "$run_dir" "$mode" "$handoff" "$caller" "$integration_workspace" "" "" \
      "$recovery" "$command" "verified integration workspace is missing" "$log_file"
    return
  fi
  if [[ -e "$artifact_root/integration/$integration_key.conflict.json" ]]; then
    graph_publish_refuse "$run_dir" "$mode" "$handoff" "$caller" "$integration_workspace" "" "" \
      "$recovery" "$command" "unresolved integration conflict artifact exists" "$log_file"
    return
  fi

  base_identity="$(jq -r '.sourceBase.filesystemIdentity // empty' "$run_file")"
  base_manifest="$(jq -r '.sourceBase.manifestPath // empty' "$run_file")"
  [[ -n "$base_identity" && -f "$base_manifest" ]] || {
    graph_publish_refuse "$run_dir" "$mode" "$handoff" "$caller" "$integration_workspace" "" "" \
      "$recovery" "$command" "publishing requires an immutable backend-neutral run base" "$log_file"
    return
  }
  exclude_file="$(mktemp "${TMPDIR:-/tmp}/ralph-publish-excludes.XXXXXX")" || return 1
  jq -r '.sourceBase.secretExcludes[]? // empty' "$run_file" >"$exclude_file"
  current_identity="$(graph_publish_filesystem_identity "$integration_workspace" "$state_root" "$exclude_file")" || {
    rm -f "$exclude_file"; return 1;
  }
  if [[ "$current_identity" != "$result_identity" ]]; then
    rm -f "$exclude_file"
    graph_publish_refuse "$run_dir" "$mode" "$handoff" "$caller" "$integration_workspace" "" "" \
      "$recovery" "$command" "integration workspace drifted after verification" "$log_file"
    return
  fi

  changeset_dir="$publish_dir/changeset"
  changeset_manifest="$changeset_dir/manifest.json"
  mkdir -p "$changeset_dir" || { rm -f "$exclude_file"; return 1; }
  python3 "$GRAPH_PUBLISH_CHANGESET_HELPER" capture \
    --workspace "$integration_workspace" --baseline "$base_manifest" \
    --output "$changeset_manifest" --node-id graph-publish \
    --attempt-id "$run_id-publish" --workspace-mode snapshot \
    --base-identity "$base_identity" --write-scopes-json '["**"]' >/dev/null || {
      rm -f "$exclude_file"
      graph_publish_refuse "$run_dir" "$mode" "$handoff" "$caller" "$integration_workspace" "" "" \
        "$recovery" "$command" "failed to create backend-neutral publish changeset" "$log_file"
      return
    }
  bundle="$publish_dir/changeset-bundle.tar"
  bundle_tmp="$bundle.tmp.$$"
  rm -f "$bundle_tmp"
  if ! tar -cf "$bundle_tmp" -C "$changeset_dir" . || ! mv -f "$bundle_tmp" "$bundle"; then
    rm -f "$bundle_tmp" "$exclude_file"
    graph_publish_refuse "$run_dir" "$mode" "$handoff" "$caller" "$integration_workspace" \
      "$changeset_manifest" "" "$recovery" "$command" "failed to create publish bundle" "$log_file"
    return
  fi

  if [[ "$mode" == "manual" ]]; then
    rm -f "$exclude_file"
    graph_publish_write_handoff "$handoff" "$mode" ready true "$run_id" "$caller" \
      "$integration_workspace" "$changeset_manifest" "$bundle" "$recovery" "$command" \
      "inspection required; caller workspace was not modified" || return 1
    ralph_atomic_write_json "$status_file" \
      '{schemaVersion:1,kind:"graph-publish-status",status:"manual-ready",
        filesystemIdentity:$identity,updatedAt:$now}' \
      --arg identity "$result_identity" --arg now "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" || return 1
    graph_publish_update_run "$run_file" "$mode" ready "$handoff" "" || return 1
    graph_publish_log "$log_file" "manual-ready run=$run_id integration=$integration_workspace bundle=$bundle"
    return 0
  fi

  expected_git="$(jq -c '.sourceBase.git' "$run_file")"
  current_git="$(graph_run_base_git_metadata "$caller" "$state_root" "$exclude_file" 0)" || {
    rm -f "$exclude_file"; return 1;
  }
  rm -f "$exclude_file"
  if [[ "$expected_git" != "$current_git" ]]; then
    detail="$(jq -cn --argjson expected "$expected_git" --argjson current "$current_git" \
      '{reason:"caller Git identity drifted",expected:$expected,current:$current}')"
    graph_publish_refuse "$run_dir" "$mode" "$handoff" "$caller" "$integration_workspace" \
      "$changeset_manifest" "$bundle" "$recovery" "$command" "$detail" "$log_file"
    return
  fi

  graph_publish_write_handoff "$handoff" "$mode" publishing true "$run_id" "$caller" \
    "$integration_workspace" "$changeset_manifest" "$bundle" "$recovery" "$command" "" || return 1
  if ! python3 "$GRAPH_PUBLISH_HELPER" \
    --workspace "$caller" --integration-workspace "$integration_workspace" \
    --manifest "$changeset_manifest" --expected-base-identity "$base_identity" \
    --expected-result-identity "$result_identity" --status "$status_file" \
    --journal "$journal" --recovery "$recovery" --recovery-command "$command"; then
    if [[ "$(jq -r '.status // empty' "$status_file" 2>/dev/null || true)" == "rolled-back" ]]; then
      detail="publish interrupted or failed; caller was rolled back to the frozen base"
      graph_publish_write_handoff "$handoff" "$mode" rolled-back true "$run_id" "$caller" \
        "$integration_workspace" "$changeset_manifest" "$bundle" "$recovery" "$command" "$detail" || true
      graph_publish_update_run "$run_file" "$mode" rolled-back "$handoff" "$detail" || true
      graph_publish_log "$log_file" "rolled-back run=$run_id recovery=$recovery"
      return 1
    fi
    graph_publish_refuse "$run_dir" "$mode" "$handoff" "$caller" "$integration_workspace" \
      "$changeset_manifest" "$bundle" "$recovery" "$command" \
      "caller filesystem identity drifted or publish preflight failed; no action taken" "$log_file"
    return
  fi
  graph_publish_write_handoff "$handoff" "$mode" published true "$run_id" "$caller" \
    "$integration_workspace" "$changeset_manifest" "$bundle" "$recovery" "$command" "" || return 1
  graph_publish_update_run "$run_file" "$mode" published "$handoff" "" || return 1
  graph_publish_log "$log_file" "published run=$run_id identity=$result_identity journal=$journal"
  return 0
}

graph_publish_should_retain() {
  local run_dir="$1" graph_json="$2" mode status
  mode="$(jq -r '.publishMode // "manual"' "$graph_json" 2>/dev/null || echo manual)"
  status="$(jq -r '.publish.status // empty' "$run_dir/run.json" 2>/dev/null || true)"
  [[ "$mode" == "manual" && "$status" == "ready" ]] && return 0
  [[ "$status" == "refused" || "$status" == "rolled-back" ]] && return 0
  return 1
}
