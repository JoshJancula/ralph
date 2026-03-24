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
  def artifacts_ok:
    (type == "array") and (all(type == "object" and has("path")));

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

  def stage_ok:
    has("id") and has("runtime") and has("agent") and has("plan") and
    stage_id_ok and
    (.artifacts | artifacts_ok) and
    ((.inputArtifacts? // []) | artifacts_ok) and
    ((.outputArtifacts? // []) | artifacts_ok) and
    (has("inputFromStages") | not) and
    loop_control_ok and
    session_resume_ok;

  type == "object" and
  has("name") and has("namespace") and
  has("stages") and
  (.stages | type == "array" and length > 0 and all(stage_ok))
'

if ! jq -e "$schema_filter" "$orch_file" >/dev/null; then
  echo "Orchestration schema validation failed: $orch_file does not match the schema" >&2
  exit 1
fi
