#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF' >&2
Usage: validate-orchestration-schema.sh <orchestration-file>
Validate the structure of a .orch.json plan against the expected schema.
EOF
  exit 1
}

if [[ $# -ne 1 ]]; then
  usage
fi

orch_file="$1"

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
        ($loop | has("maxIterations") and ($loop.maxIterations | type == "number"))
      )
    );

  def session_resume_ok:
    ((.sessionResume? // null) as $sr |
      ($sr == null) or ($sr | type == "boolean")
    );

  def stage_id_ok:
    ((.id? // null) as $id |
      ($id | type == "string") and
      ($id | test("^[a-z0-9_]+(-[a-z0-9_]+)*$"))
    );

  def stage_ok($root; $all_stage_ids; $has_parallel_stages):
    (.id) as $stage_id |
    has("id") and has("runtime") and has("agent") and has("plan") and
    stage_id_ok and
    (.artifacts | artifacts_ok($root; $all_stage_ids; $stage_id; $has_parallel_stages)) and
    ((.inputArtifacts? // []) | artifacts_ok($root; $all_stage_ids; $stage_id; $has_parallel_stages)) and
    ((.outputArtifacts? // []) | artifacts_ok($root; $all_stage_ids; $stage_id; $has_parallel_stages)) and
    (has("inputFromStages") | not) and
    loop_control_ok and
    session_resume_ok;

  def parallel_stages_ok:
    ((.parallelStages? // null) as $parallel_stages |
      ($parallel_stages == null) or (
        ($parallel_stages | type == "array") and
        (all(.parallelStages[]; type == "string" and test("^\\s*[a-z0-9_]+(-[a-z0-9_]+)*(\\s*,\\s*[a-z0-9_]+(-[a-z0-9_]+)*)*\\s*$"))) and
        ((parallel_stage_ids | unique | length) == (parallel_stage_ids | length)) and
        ((parallel_stage_ids - stage_ids | length) == 0) and
        ((stage_ids - parallel_stage_ids | length) == 0) and
        (all(.stages[]; has("loopControl") | not))
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
