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
        (($planner | keys - ["outputMode", "maxTodos"]) | length == 0) and
        ($planner | has("outputMode")) and
        ($planner.outputMode == "plan-file") and
        (
          ($planner | has("maxTodos") | not) or (
            ($planner.maxTodos | type == "number") and
            ($planner.maxTodos == ($planner.maxTodos | floor)) and
            ($planner.maxTodos >= 1) and
            ($planner.maxTodos <= 200)
          )
        )
      )
    );

  def plan_source_ok:
    (
      (
        has("plan") and (has("planFrom") | not) and
        (.plan | type == "string") and (.plan | length > 0)
      ) or (
        has("planFrom") and (has("plan") | not) and
        (.planFrom | type == "string") and (.planFrom | length > 0)
      )
    );

  def native_subagents_ok:
    ((has("nativeSubagents") | not) or (
      (.nativeSubagents | type == "string") and
      (.nativeSubagents | IN("off", "inherit"))
    ));

  def approval_forbidden_ok:
    (has("runtime") | not) and
    (has("model") | not) and
    (has("agent") | not) and
    (has("agentSource") | not) and
    (has("role") | not) and
    (has("instructions") | not) and
    (has("plan") | not) and
    (has("planFrom") | not) and
    (has("planner") | not) and
    (has("workspaceMode") | not) and
    (has("writeScopes") | not) and
    (has("parallelMutation") | not) and
    (has("acknowledgeSharedMutationRisk") | not) and
    (has("agentGitAccess") | not) and
    (has("setupProfile") | not) and
    (has("toolingProfile") | not) and
    (has("contextBudget") | not) and
    (has("sessionStrategy") | not) and
    (has("nativeSubagents") | not) and
    (has("subagents") | not) and
    (has("delegation") | not) and
    (has("router") | not) and
    (has("voters") | not) and
    (has("humanAck") | not) and
    (has("_inlineTodos") | not) and
    (has("artifacts") | not) and
    (has("outputArtifacts") | not) and
    (has("grader") | not) and
    (has("loopControl") | not);

  def approval_stage_ok:
    ((.type // "") == "approval") and
    stage_id_ok and
    ((.question | type == "string") and (.question | length > 0)) and
    ((.changesTarget | type == "string") and (.changesTarget | length > 0) and
      (.changesTarget | test("^[a-z0-9_]+(-[a-z0-9_]+)*$"))) and
    ((.dependsOn | type == "array") and (.dependsOn | length > 0) and
      (all(.dependsOn[]; type == "string" and length > 0))) and
    ((.inputArtifacts | type == "array") and (.inputArtifacts | length > 0)) and
    approval_forbidden_ok;

  def stage_ok($root; $all_stage_ids; $has_parallel_stages):
    (.id) as $stage_id |
    if ((.type // "") == "approval") then
      approval_stage_ok and
      ((.inputArtifacts? // []) | artifacts_ok($root; $all_stage_ids; $stage_id; $has_parallel_stages))
    else
      has("id") and has("runtime") and
      plan_source_ok and
      (has("agent") | not) and
      (has("agentSource") | not) and
      (has("subagents") | not) and
      (has("role") | not) and
      ((.delegation? // null | type != "object") or ((.delegation | has("native")) | not)) and
      native_subagents_ok and
      stage_id_ok and
      ((.artifacts? // []) | artifacts_ok($root; $all_stage_ids; $stage_id; $has_parallel_stages)) and
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
      reasoning_effort_ok
    end;

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

if jq -e '[.stages[]? | select(has("agent"))] | length > 0' "$orch_file" >/dev/null 2>&1; then
  echo "Orchestration schema validation failed: stage agent was removed. Use inline workflow instructions (instructions: text)." >&2
  exit 1
fi

if jq -e '[.stages[]? | select(has("agentSource"))] | length > 0' "$orch_file" >/dev/null 2>&1; then
  echo "Orchestration schema validation failed: stage agentSource was removed. Use inline workflow instructions (instructions: text)." >&2
  exit 1
fi

if jq -e '[.stages[]? | select(has("subagents"))] | length > 0' "$orch_file" >/dev/null 2>&1; then
  echo "Orchestration schema validation failed: stage subagents was removed. Use nativeSubagents: off|inherit. Run: ralph migrate agents-to-roles" >&2
  exit 1
fi

if jq -e '[.stages[]? | select((.delegation? // null | type == "object") and (.delegation | has("native")))] | length > 0' "$orch_file" >/dev/null 2>&1; then
  echo "Orchestration schema validation failed: stage delegation.native was removed. Use nativeSubagents: off|inherit. Run: ralph migrate agents-to-roles" >&2
  exit 1
fi

if jq -e '[.stages[]? | select(has("nativeSubagents") and ((.nativeSubagents | type != "string") or (.nativeSubagents | IN("off", "inherit") | not)))] | length > 0' "$orch_file" >/dev/null 2>&1; then
  echo "Orchestration schema validation failed: stage nativeSubagents must be off or inherit" >&2
  exit 1
fi

if jq -e '[.stages[]? | select(has("role"))] | length > 0' "$orch_file" >/dev/null 2>&1; then
  echo "Orchestration schema validation failed: stage role was removed. Use inline workflow instructions (instructions: text)." >&2
  exit 1
fi

# planInput is workflow-source only; strip after materialization records binding.
if jq -e 'has("planInput")' "$orch_file" >/dev/null 2>&1; then
  echo "Orchestration schema validation failed: planInput is only valid on workflow sources (kind: workflow); reject on non-workflows and legacy materialized plans" >&2
  exit 1
fi

# Legacy planner role/runtime/model caps were removed; authored planners use plan-file only.
if jq -e '
  [.stages[]? | select(.planner != null) | .planner |
    select(
      has("allowedRoles") or has("allowedRuntimes") or has("allowedModels") or
      has("maxStages") or has("defaultRole")
    )
  ] | length > 0
' "$orch_file" >/dev/null 2>&1; then
  echo "Orchestration schema validation failed: planner allowedRoles|allowedRuntimes|allowedModels|maxStages|defaultRole was removed. Use planner: {outputMode: plan-file, maxTodos: <n>} for a generated Ralph plan." >&2
  exit 1
fi

if ! jq -e "$schema_filter" "$orch_file" >/dev/null; then
  echo "Orchestration schema validation failed: $orch_file does not match the schema" >&2
  exit 1
fi

# Approval stages: changesTarget must be one upstream executable/planner ancestor.
if jq -e '[.stages[]? | select((.type // "") == "approval")] | length > 0' "$orch_file" >/dev/null 2>&1; then
  if ! jq -e '
    def ancestors($by_id; $id):
      (($by_id[$id].dependsOn // []) | map(.) | unique) as $direct |
      reduce $direct[] as $dep (
        [];
        . + [$dep] + (if $by_id[$dep] == null then [] else ancestors($by_id; $dep) end)
      ) | unique;
    def is_resettable_target($stage):
      (
        (($stage.planner // null) | type == "object") and
        (($stage.type // "agent") | IN("agent", "stage", "") )
      ) or (
        (($stage.type // "agent") | IN("agent", "stage", "")) and
        (($stage.grader // false) | not) and
        (($stage.router // null) == null) and
        (($stage.planner // null) == null)
      );
    ([.stages[] | {key: .id, value: .}] | from_entries) as $by_id |
    all(
      .stages[]? | select((.type // "") == "approval");
      (.id) as $gate |
      (.changesTarget) as $target |
      ($target != $gate) and
      ($by_id[$target] != null) and
      ((($by_id[$target].type // "") | IN("integrate", "join", "gate", "checkpoint", "router", "approval", "consensus", "adjudicator")) | not) and
      is_resettable_target($by_id[$target]) and
      ((ancestors($by_id; $gate) | index($target)) != null)
    )
  ' "$orch_file" >/dev/null 2>&1; then
    echo "Orchestration schema validation failed: approval changesTarget must name one upstream executable or planner ancestor whose downstream closure includes the gate" >&2
    exit 1
  fi
fi

# planFrom: ordinary agent stages only; mutual exclusion with plan; direct planner dependency.
if jq -e '[.stages[]? | select(has("planFrom"))] | length > 0' "$orch_file" >/dev/null 2>&1; then
  if ! jq -e '
    . as $root |
    ([.stages[] | {key: .id, value: .}] | from_entries) as $by_id |
    (
      [.stages[] | select(has("planFrom")) | .planFrom] |
      group_by(.) | map(select(length > 1)) | length == 0
    ) and
    all(
      .stages[]?;
      (has("planFrom") | not) or (
        (.planFrom | type == "string") and
        (.planFrom | test("^[a-z0-9_]+(-[a-z0-9_]+)*$")) and
        (has("plan") | not) and
        ((.type? // "agent") | IN("agent", "stage")) and
        ((.grader? // false) | not) and
        ((.router? // null) == null) and
        ((.type? // "") | IN("integrate", "join", "gate", "checkpoint", "router", "consensus", "adjudicator", "approval") | not) and
        ($by_id[.planFrom] != null) and
        (((.dependsOn // []) | index(.planFrom)) != null) and
        (($by_id[.planFrom].planner // null) | type == "object") and
        ($by_id[.planFrom].planner.outputMode == "plan-file") and
        (
          [($by_id[.planFrom].artifacts // []), ($by_id[.planFrom].outputArtifacts // [])] | add |
          map(select(
            (.required != false) and
            ((.path // "") | test("\\.json$")) and
            ((.schema // "") == "bundle/.ralph/schemas/planner-output.schema.json")
          )) | length == 1
        )
      )
    )
  ' "$orch_file" >/dev/null 2>&1; then
    echo "Orchestration schema validation failed: planFrom must name exactly one direct dependency whose planner is plan-file with a unique required planner-output .json artifact, and at most one consumer per planner" >&2
    exit 1
  fi
fi

# Planner stages must declare exactly one required planner-output .json artifact.
if jq -e '[.stages[]? | select(.planner != null)] | length > 0' "$orch_file" >/dev/null 2>&1; then
  if ! jq -e '
    all(
      .stages[]? | select(.planner != null);
      (
        [(.artifacts? // []), (.outputArtifacts? // [])] | add |
        map(select(
          (.required != false) and
          ((.path // "") | test("\\.json$")) and
          ((.schema // "") == "bundle/.ralph/schemas/planner-output.schema.json")
        )) | length == 1
      )
    )
  ' "$orch_file" >/dev/null 2>&1; then
    echo "Orchestration schema validation failed: planner stages must declare exactly one required .json artifact with schema bundle/.ralph/schemas/planner-output.schema.json" >&2
    exit 1
  fi
fi

if jq -e 'has("ralphMode")' "$orch_file" >/dev/null 2>&1; then
  if ! jq -e '.ralphMode | IN("no", "native", "ralph", "hybrid")' "$orch_file" >/dev/null 2>&1; then
    echo "Orchestration schema validation failed: ralphMode must be one of: no, native, ralph, hybrid" >&2
    exit 1
  fi
fi

if jq -e '[.stages[]? | select(has("toolingProfile"))] | length > 0' "$orch_file" >/dev/null 2>&1; then
  TOOLING_PROFILES_JSON="$REPO_ROOT/bundle/.ralph/tooling-profiles.json"
  if [[ ! -f "$TOOLING_PROFILES_JSON" && -f "$REPO_ROOT/.ralph/tooling-profiles.json" ]]; then
    TOOLING_PROFILES_JSON="$REPO_ROOT/.ralph/tooling-profiles.json"
  fi
  if [[ -f "$TOOLING_PROFILES_JSON" ]]; then
    if ! jq -e --slurpfile profiles_doc "$TOOLING_PROFILES_JSON" '
        ($profiles_doc[0].profiles // {}) as $profiles |
        [.stages[]? | select(has("toolingProfile")) | .toolingProfile] |
        all(. as $name | $profiles | has($name))
      ' "$orch_file" >/dev/null 2>&1; then
      echo "Orchestration schema validation failed: toolingProfile on a stage must be one of the declared tooling-profiles.json profile names" >&2
      exit 1
    fi
  fi
fi

if jq -e 'has("ralphMode") and ([.stages[]? | select(has("toolingProfile"))] | length > 0)' "$orch_file" >/dev/null 2>&1; then
  echo "Orchestration schema validation failed: ralphMode and stage toolingProfile cannot coexist" >&2
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

# Authored planner config is validated above (plan-file / maxTodos). Do not call the
# legacy dynamic-planner Python contract here; that path remains for RALPH_DYNAMIC_PLANNER.

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
