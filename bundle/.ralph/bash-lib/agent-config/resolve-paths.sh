#!/usr/bin/env bash

resolve_artifact_path_template() {
  local path="$1"
  local artifact_ns="${RALPH_ARTIFACT_NS:-${RALPH_PLAN_KEY:-default}}"
  local plan_key="${RALPH_PLAN_KEY:-$artifact_ns}"
  local stage_id="${RALPH_STAGE_ID:-}"
  path="${path//\{\{ARTIFACT_NS\}\}/$artifact_ns}"
  path="${path//\{\{PLAN_KEY\}\}/$plan_key}"
  path="${path//\{\{STAGE_ID\}\}/$stage_id}"
  echo "$path"
}
