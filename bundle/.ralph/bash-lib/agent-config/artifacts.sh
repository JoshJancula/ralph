#!/usr/bin/env bash
#
# Declared output_artifacts from agent config (sourced by agent-config-tool.sh).
#
# Public interface:
#   required_artifacts -- prints required artifact path templates, one per line.

required_artifacts() {
  local agents_root="$1" agent_id="$2"
  local cfg
  cfg="$(load_cfg_path "$agents_root" "$agent_id")"
  validate_config "$agents_root" "$agent_id" >/dev/null
  local block
  block="$(array_block "$cfg" "output_artifacts" || true)"
  local in_obj=0 obj_path="" obj_required="true"
  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ "$line" =~ ^[[:space:]]*\{ ]]; then
      in_obj=1
      obj_path=""
      obj_required="true"
      continue
    fi
    if [[ "$line" =~ \"required\"[[:space:]]*:[[:space:]]*(true|false) ]]; then
      obj_required="${BASH_REMATCH[1]}"
    fi
    if [[ "$line" =~ \"path\"[[:space:]]*:[[:space:]]*\"([^\"]+)\" ]]; then
      obj_path="${BASH_REMATCH[1]}"
    fi
    if [[ "$in_obj" == "1" && "$line" =~ \} ]]; then
      if [[ -n "$obj_path" && "$obj_required" == "true" ]]; then
        resolve_artifact_path_template "$obj_path"
      fi
      in_obj=0
      obj_path=""
      obj_required="true"
      continue
    fi
    if [[ "$line" =~ ^[[:space:]]*\"([^\"]+)\"[[:space:]]*,?[[:space:]]*$ ]]; then
      resolve_artifact_path_template "${BASH_REMATCH[1]}"
    fi
  done <<< "$block"
}
