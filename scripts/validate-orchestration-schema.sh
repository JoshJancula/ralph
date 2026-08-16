#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF' >&2
Usage: validate-orchestration-schema.sh <orchestration-file> [workspace]
Validate the structure of a .orch.json plan against the expected schema.
When workspace is provided, artifact schema paths are also validated.
EOF
  exit 1
}

if [[ $# -lt 1 || $# -gt 2 ]]; then
  usage
fi

orch_file="$1"
workspace="${2:-}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SCHEMA_PY="$REPO_ROOT/bundle/.ralph/python/artifact_json_schema.py"
if [[ ! -f "$SCHEMA_PY" && -f "$REPO_ROOT/.ralph/python/artifact_json_schema.py" ]]; then
  SCHEMA_PY="$REPO_ROOT/.ralph/python/artifact_json_schema.py"
fi

if [[ ! -f "$orch_file" ]]; then
  echo "Orchestration schema validation failed: file not found: $orch_file" >&2
  exit 1
fi

schema_filter='
  def stage_index($root; $target_id):
    [($root | .stages[] | .id)] as $ids |
    ($ids | index($target_id));

  def stage_wave($root; $target_id):
    if ($root | has("parallelStages")) then
      first(
        range(0; ($root | .parallelStages | length)) as $wave_idx |
        select(
          [($root | .parallelStages[$wave_idx] | split(",")[] | gsub("^\\s+|\\s+$"; ""))] | index($target_id) != null
        ) | $wave_idx
      )
    else
      null
    end;

  def handoff_ordering_ok($root; $producer_stage_id; $has_parallel_stages):
    if has("kind") and .kind == "handoff" and has("to") then
      .to as $target_id |
      if $has_parallel_stages then
        (stage_wave($root; $producer_stage_id)) as $producer_wave |
        (stage_wave($root; $target_id)) as $target_wave |
        (
          ($producer_wave != null and $target_wave != null) and
          ($producer_wave < $target_wave)
        )
      else
        (stage_index($root; $producer_stage_id)) as $producer_idx |
        (stage_index($root; $target_id)) as $target_idx |
        (
          ($producer_idx != null and $target_idx != null) and
          ($producer_idx < $target_idx)
        )
      end
    else
      true
    end;

  def artifact_entry_ok($root; $all_stage_ids; $producer_stage_id; $has_parallel_stages):
    type == "object" and has("path") and
    ((has("schema") | not) or (.schema | type == "string" and length > 0)) and
    ((has("provenance") | not) or (.provenance | type == "string" and (. == "required" or . == "optional" or . == "none"))) and
    ((has("kind") | not) or (.kind | type == "string" and (. == "handoff" or . == "design" or . == "review" or . == "research" or . == "notes"))) and
    (
      if has("kind") and .kind == "handoff" then
        (has("to") and (.to | type == "string" and IN($all_stage_ids[])) and handoff_ordering_ok($root; $producer_stage_id; $has_parallel_stages))
      else
        ((has("to") | not) or (.to | type == "string"))
      end
    );

  def artifacts_ok($root; $all_stage_ids; $producer_stage_id; $has_parallel_stages):
    (type == "array") and (all(.[]; artifact_entry_ok($root; $all_stage_ids; $producer_stage_id; $has_parallel_stages)));

  def stage_ids:
    [.stages[].id];

  def parallel_stage_ids:
    [.parallelStages[] | split(",")[] | gsub("^\\s+|\\s+$"; "")];

  def loop_control_ok:
    ((.loopControl? // null) as $loop |
      ($loop == null) or (
        ($loop | has("loopBackTo") and ($loop.loopBackTo | type == "string")) and
        ($loop | has("maxIterations") and ($loop.maxIterations | type == "number")) and
        (($loop | has("evaluatorSchema") | not) or (($loop.evaluatorSchema | type == "string") and ($loop.evaluatorSchema | length > 0))) and
        (($loop | has("onExhausted") | not) or (($loop.onExhausted | type == "string") and ($loop.onExhausted | (. == "proceed" or . == "fail"))))
      )
    );

  def session_resume_ok:
    ((.sessionResume? // null) as $sr |
      ($sr == null) or ($sr | type == "boolean")
    );

  def session_strategy_ok:
    ((.sessionStrategy? // null) as $ss |
      ($ss == null) or (
        ($ss | type == "string") and
        ($ss == "fresh" or $ss == "resume" or $ss == "reset")
      )
    );

  def reasoning_effort_ok:
    ((.reasoning_effort? // null) as $re |
      ($re == null) or (
        ($re | type == "string") and
        ($re | IN("low", "medium", "high", "xhigh", "max", "inherit"))
      )
    );

  def grader_ok:
    ((.grader? // null) as $grader |
      ($grader == null or $grader == false) or (
        ($grader | type == "boolean") and
        ($grader == true) and
        has("rubric") and
        (.rubric | type == "string") and
        (.rubric | length > 0) and
        (
          if has("sessionStrategy") then
            (.sessionStrategy | type == "string") and (.sessionStrategy == "fresh")
          elif has("sessionResume") then
            (.sessionResume | type == "boolean") and (.sessionResume == false)
          else
            true
          end
        )
      )
    );

  def router_ok($root; $all_stage_ids):
    ((.router? // null) as $router |
      ($router == null) or (
        ($router | type == "object") and
        ($router | has("allowedTargets") and ($router.allowedTargets | type == "array") and ($router.allowedTargets | length > 0)) and
        ($router | has("defaultTarget") and ($router.defaultTarget | type == "string") and ($router.defaultTarget | length > 0)) and
        (($router | has("terminalOutcomes") | not) or (($router.terminalOutcomes | type == "array"))) and
        (($router | has("onInvalid") | not) or (($router.onInvalid | type == "string") and ($router.onInvalid | IN("fail", "default")))) and
        (($router.defaultTarget | IN($router.allowedTargets[])) or
          ((($router.terminalOutcomes? // []) | index($router.defaultTarget)) != null))
      )
    );

  def mcp_proxy_policy_ok:
    ((.mcpProxyPolicy? // null) as $policy |
      ($policy == null) or (
        ($policy | type == "string") and
        ($policy | length > 0)
      )
    );

  def stage_id_ok:
    ((.id? // null) as $id |
      ($id | type == "string") and
      ($id | test("^[a-z0-9_]+(-[a-z0-9_]+)*$"))
    );

  def final_output_schema_ok:
    ((.finalOutputSchema? // null) as $fos |
      ($fos == null) or (($fos | type == "string") and ($fos | length > 0))
    );

  def planner_ok:
    ((.planner? // null) as $planner |
      ($planner == null) or (
        ($planner | type == "object") and
        ($planner | has("outputMode")) and
        ($planner.outputMode | IN("plan-file", "stages")) and
        ($planner | has("maxTodos")) and
        ($planner.maxTodos | type == "number") and
        ($planner | has("maxStages")) and
        ($planner.maxStages | type == "number") and
        ($planner | has("allowedRuntimes")) and
        ($planner.allowedRuntimes | type == "array") and
        ($planner.allowedRuntimes | length > 0) and
        ($planner | has("allowedAgents")) and
        ($planner.allowedAgents | type == "array") and
        ($planner.allowedAgents | length > 0) and
        ($planner | has("allowedModels")) and
        ($planner.allowedModels | type == "array") and
        ($planner.allowedModels | length > 0)
      )
    );

  def stage_ok($root; $all_stage_ids; $has_parallel_stages):
    (.id) as $stage_id |
    has("id") and has("runtime") and has("agent") and has("plan") and
    stage_id_ok and
    (.artifacts | artifacts_ok($root; $all_stage_ids; $stage_id; $has_parallel_stages)) and
    ((.inputArtifacts? // []) | artifacts_ok($root; $all_stage_ids; $stage_id; $has_parallel_stages)) and
    ((.outputArtifacts? // []) | artifacts_ok($root; $all_stage_ids; $stage_id; $has_parallel_stages)) and
    (has("inputFromStages") | not) and
    mcp_proxy_policy_ok and
    grader_ok and
    router_ok($root; $all_stage_ids) and
    planner_ok and
    final_output_schema_ok and
    loop_control_ok and
    session_resume_ok and
    session_strategy_ok and
    reasoning_effort_ok;

  def parallel_stages_ok:
    ((.parallelStages? // null) as $parallel_stages |
      ($parallel_stages == null) or (
        ($parallel_stages | type == "array") and
        (all(.parallelStages[]; type == "string" and test("^\\s*[a-z0-9_]+(-[a-z0-9_]+)*(\\s*,\\s*[a-z0-9_]+(-[a-z0-9_]+)*)*\\s*$"))) and
        ((parallel_stage_ids | unique | length) == (parallel_stage_ids | length)) and
        ((parallel_stage_ids - stage_ids | length) == 0) and
        ((stage_ids - parallel_stage_ids | length) == 0)
      )
    );

  . as $root |
  (stage_ids) as $all_stage_ids |
  ((.parallelStages? // null) != null) as $has_parallel_stages |
  type == "object" and
  has("name") and has("namespace") and
  has("stages") and
  (.stages | type == "array" and length > 0 and all(stage_ok($root; $all_stage_ids; $has_parallel_stages))) and
  parallel_stages_ok
'

if ! jq -e "$schema_filter" "$orch_file" >/dev/null; then
  echo "Orchestration schema validation failed: $orch_file does not match the schema" >&2
  exit 1
fi

if jq -e 'has("ralphMode")' "$orch_file" >/dev/null 2>&1; then
  if ! jq -e '.ralphMode | IN("no", "native", "ralph", "hybrid")' "$orch_file" >/dev/null 2>&1; then
    echo "Orchestration schema validation failed: ralphMode must be one of: no, native, ralph, hybrid" >&2
    exit 1
  fi
fi

if jq -e '[.stages[]? | select(has("ralphMode"))] | length > 0' "$orch_file" >/dev/null 2>&1; then
  echo "Orchestration schema validation failed: ralphMode is not allowed on a stage. Tool exposure applies to the whole run -- declare it once at the top level" >&2
  exit 1
fi

if jq -e '[.stages[]? | select(has("router"))] | length > 0' "$orch_file" >/dev/null 2>&1; then
  ROUTER_PY="$REPO_ROOT/bundle/.ralph/python/router_contract.py"
  if [[ ! -f "$ROUTER_PY" && -f "$REPO_ROOT/.ralph/python/router_contract.py" ]]; then
    ROUTER_PY="$REPO_ROOT/.ralph/python/router_contract.py"
  fi
  if ! command -v python3 >/dev/null 2>&1; then
    echo "Orchestration schema validation failed: python3 is required when router stages are declared" >&2
    exit 1
  fi
  if [[ ! -f "$ROUTER_PY" ]]; then
    echo "Orchestration schema validation failed: router contract helper not found: $ROUTER_PY" >&2
    exit 1
  fi
  if ! python3 "$ROUTER_PY" validate-orchestration --orchestration "$orch_file"; then
    echo "Orchestration schema validation failed: router reachability validation failed for $orch_file" >&2
    exit 1
  fi
fi

if jq -e '[.stages[]? | select(has("planner"))] | length > 0' "$orch_file" >/dev/null 2>&1; then
  PLANNER_PY="$REPO_ROOT/bundle/.ralph/python/planner_contract.py"
  if [[ ! -f "$PLANNER_PY" && -f "$REPO_ROOT/.ralph/python/planner_contract.py" ]]; then
    PLANNER_PY="$REPO_ROOT/.ralph/python/planner_contract.py"
  fi
  if ! command -v python3 >/dev/null 2>&1; then
    echo "Orchestration schema validation failed: python3 is required when planner stages are declared" >&2
    exit 1
  fi
  if [[ ! -f "$PLANNER_PY" ]]; then
    echo "Orchestration schema validation failed: planner contract helper not found: $PLANNER_PY" >&2
    exit 1
  fi
  if ! python3 "$PLANNER_PY" validate-orchestration --orchestration "$orch_file"; then
    echo "Orchestration schema validation failed: planner validation failed for $orch_file" >&2
    exit 1
  fi
fi

if jq -e '[.stages[]? | (.artifacts // []), (.inputArtifacts // []), (.outputArtifacts // [])] | add | map(select(has("schema"))) | length > 0' "$orch_file" >/dev/null 2>&1 || \
   jq -e '[.stages[]? | select(has("finalOutputSchema"))] | length > 0' "$orch_file" >/dev/null 2>&1; then
  if [[ -z "$workspace" ]]; then
    echo "Orchestration schema validation failed: workspace is required when artifact schema paths are declared" >&2
    exit 1
  fi
  if [[ ! -d "$workspace" ]]; then
    echo "Orchestration schema validation failed: workspace not found: $workspace" >&2
    exit 1
  fi
  if ! command -v python3 >/dev/null 2>&1; then
    echo "Orchestration schema validation failed: python3 is required to validate artifact schema paths" >&2
    exit 1
  fi
  if [[ ! -f "$SCHEMA_PY" ]]; then
    echo "Orchestration schema validation failed: schema validator not found: $SCHEMA_PY" >&2
    exit 1
  fi
  artifact_ns="$(jq -r '.namespace // empty' "$orch_file" 2>/dev/null || echo "")"
  if ! python3 "$SCHEMA_PY" validate-orch-paths \
    --workspace "$workspace" \
    --orchestration "$orch_file" \
    --artifact-ns "$artifact_ns"; then
    exit 1
  fi
fi
