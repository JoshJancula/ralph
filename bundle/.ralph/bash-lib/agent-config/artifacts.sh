#!/usr/bin/env bash
#
# Declared output_artifacts from agent config (sourced by agent-config-tool.sh).
#
# Public interface:
#   required_artifacts -- prints required artifact path templates, one per line.
#   all_output_artifacts -- prints all declared artifact path templates, one per line.

all_output_artifacts() {
  local agents_root="$1" agent_id="$2"
  local cfg
  cfg="$(load_cfg_path "$agents_root" "$agent_id")"
  validate_config "$agents_root" "$agent_id" >/dev/null
  local path
  while IFS= read -r path || [[ -n "$path" ]]; do
    [[ -n "$path" ]] || continue
    printf '%s\n' "$(resolve_artifact_path_template "$path")"
  done < <(
    python3 - "$cfg" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as fh:
    data = json.load(fh)

for item in data.get("output_artifacts", []) or []:
    if isinstance(item, str):
        path = item
    elif isinstance(item, dict):
        path = str(item.get("path", "") or "")
    else:
        continue
    if path:
        print(path)
PY
  )
}

required_artifacts() {
  local agents_root="$1" agent_id="$2"
  local cfg
  cfg="$(load_cfg_path "$agents_root" "$agent_id")"
  validate_config "$agents_root" "$agent_id" >/dev/null
  local path
  while IFS= read -r path || [[ -n "$path" ]]; do
    [[ -n "$path" ]] || continue
    printf '%s\n' "$(resolve_artifact_path_template "$path")"
  done < <(
    python3 - "$cfg" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as fh:
    data = json.load(fh)

for item in data.get("output_artifacts", []) or []:
    if isinstance(item, str):
        path = item
        required = True
    elif isinstance(item, dict):
        path = str(item.get("path", "") or "")
        required = bool(item.get("required", True))
    else:
        continue
    if path and required:
        print(path)
PY
  )
}
