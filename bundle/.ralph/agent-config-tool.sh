#!/usr/bin/env bash
set -euo pipefail

MAX_DESCRIPTION_WARN=2000
MAX_RULE_INLINE_BYTES=65536

is_env_secret_basename() {
  local name="$1"
  [[ -n "$name" && "${name#".env"}" != "$name" ]]
}

rel_path_targets_env_secret() {
  local s="$1"
  s="${s//\\//}"
  s="${s%/}"
  [[ -z "$s" ]] && return 1
  local base="${s##*/}"
  is_env_secret_basename "$base"
}

valid_agent_name() {
  local n="$1"
  [[ -n "$n" ]] || return 1
  [[ "$n" =~ ^[a-z0-9]+$ || "$n" =~ ^[a-z0-9][a-z0-9-]*[a-z0-9]$ ]]
}

json_string_value() {
  local file="$1" key="$2"
  sed -n "s/^[[:space:]]*\"$key\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\"[[:space:]]*,\{0,1\}[[:space:]]*$/\1/p" "$file" | head -1
}

array_block() {
  local file="$1" key="$2"
  awk -v key="$key" '
    BEGIN{in_arr=0; depth=0}
    {
      if (!in_arr && $0 ~ "\""key"\"[[:space:]]*:[[:space:]]*\\[") {
        in_arr=1
      }
      if (in_arr) {
        print $0
        opens=gsub(/\[/,"[")
        closes=gsub(/\]/,"]")
        depth += opens - closes
        if (depth<=0 && $0 ~ /\]/) exit
      }
    }' "$file"
}

resolve_artifact_path_template() {
  local path="$1"
  local artifact_ns="${RALPH_ARTIFACT_NS:-${RALPH_PLAN_KEY:-default}}"
  local plan_key="${RALPH_PLAN_KEY:-$artifact_ns}"
  path="${path//\{\{ARTIFACT_NS\}\}/$artifact_ns}"
  path="${path//\{\{PLAN_KEY\}\}/$plan_key}"
  echo "$path"
}

list_agent_ids() {
  local agents_root="$1"
  [[ -d "$agents_root" ]] || return 0
  local d
  for d in "$agents_root"/*; do
    [[ -d "$d" && -f "$d/config.json" ]] || continue
    basename "$d"
  done | sort
}

load_cfg_path() {
  local agents_root="$1" agent_id="$2"
  echo "$agents_root/$agent_id/config.json"
}

validate_config() {
  local agents_root="$1" agent_id="$2"
  local cfg
  cfg="$(load_cfg_path "$agents_root" "$agent_id")"
  [[ -f "$cfg" ]] || { echo "config not found: $cfg" >&2; return 1; }

  local ok=1
  local key
  for key in name model description rules skills output_artifacts; do
    grep -Eq "^[[:space:]]*\"$key\"[[:space:]]*:" "$cfg" || { echo "missing required key: $key" >&2; ok=0; }
  done

  local name model desc
  name="$(json_string_value "$cfg" "name")"
  model="$(json_string_value "$cfg" "model")"
  desc="$(json_string_value "$cfg" "description")"

  valid_agent_name "$name" || { echo "name must match schema (lowercase, digits, hyphens; see agents README)" >&2; ok=0; }
  [[ "$name" == "$agent_id" ]] || { echo "name \"$name\" must match directory name \"$agent_id\"" >&2; ok=0; }
  [[ -n "$model" ]] || { echo "model must be a non-empty string" >&2; ok=0; }
  [[ -n "$desc" ]] || { echo "description must be a non-empty string" >&2; ok=0; }
  if ((${#desc} > MAX_DESCRIPTION_WARN)); then
    echo "warning: description length ${#desc} exceeds recommended $MAX_DESCRIPTION_WARN" >&2
  fi

  local rules skills arts
  rules="$(array_block "$cfg" "rules" || true)"
  skills="$(array_block "$cfg" "skills" || true)"
  arts="$(array_block "$cfg" "output_artifacts" || true)"
  [[ -n "$rules" ]] || { echo "rules must be an array" >&2; ok=0; }
  [[ -n "$skills" ]] || { echo "skills must be an array" >&2; ok=0; }
  [[ -n "$arts" ]] || { echo "output_artifacts must be an array" >&2; ok=0; }

  while IFS= read -r line; do
    [[ "$line" =~ ^[[:space:]]*\"([^\"]+)\"[[:space:]]*,?[[:space:]]*$ ]] || continue
    rel="${BASH_REMATCH[1]}"
    rel_path_targets_env_secret "$rel" && { echo "rules entry must not reference a .env* path (blocked for security)" >&2; ok=0; }
  done <<< "$rules"

  while IFS= read -r line; do
    [[ "$line" =~ ^[[:space:]]*\"([^\"]+)\"[[:space:]]*,?[[:space:]]*$ ]] || continue
    rel="${BASH_REMATCH[1]}"
    rel_path_targets_env_secret "$rel" && { echo "skills entry must not reference a .env* path (blocked for security)" >&2; ok=0; }
  done <<< "$skills"

  while IFS= read -r line; do
    [[ "$line" =~ \"path\"[[:space:]]*:[[:space:]]*\"([^\"]+)\" ]] || continue
    rel="${BASH_REMATCH[1]}"
    rel_path_targets_env_secret "$rel" && { echo "output_artifacts path must not be .env* (blocked)" >&2; ok=0; }
  done <<< "$arts"

  if grep -q '"allowed_tools"' "$cfg" 2>/dev/null; then
    if command -v python3 &>/dev/null; then
      python3 -c "
import json, sys
p = sys.argv[1]
with open(p) as f:
    c = json.load(f)
if 'allowed_tools' not in c:
    sys.exit(0)
v = c['allowed_tools']
if isinstance(v, str) and v.strip():
    sys.exit(0)
if isinstance(v, list) and v and all(isinstance(x, str) and x.strip() for x in v):
    sys.exit(0)
sys.exit(1)
" "$cfg" 2>/dev/null || { echo "allowed_tools must be a non-empty string or a non-empty array of non-empty strings (see agents README)" >&2; ok=0; }
    else
      echo "allowed_tools in config requires python3 for validation" >&2
      ok=0
    fi
  fi

  [[ "$ok" == "1" ]]
}

read_allowed_tools() {
  local agents_root="$1" agent_id="$2"
  local cfg
  cfg="$(load_cfg_path "$agents_root" "$agent_id")"
  [[ -f "$cfg" ]] || return 1
  command -v python3 &>/dev/null || return 1
  python3 -c "
import json, sys
with open(sys.argv[1]) as f:
    c = json.load(f)
v = c.get('allowed_tools')
if isinstance(v, str) and v.strip():
    print(v.strip())
elif isinstance(v, list):
    parts = [x.strip() for x in v if isinstance(x, str) and x.strip()]
    if parts:
        print(','.join(parts))
" "$cfg" 2>/dev/null || true
}

read_model() {
  local agents_root="$1" agent_id="$2"
  local cfg
  cfg="$(load_cfg_path "$agents_root" "$agent_id")"
  validate_config "$agents_root" "$agent_id" >/dev/null
  local m
  m="$(json_string_value "$cfg" "model")"
  [[ -n "$m" ]] || { echo "model missing" >&2; return 1; }
  echo "$m"
}

inline_rule_file() {
  local workspace="$1" rel="$2"
  local p="$workspace/${rel#/}"
  local base="${p##*/}"
  if is_env_secret_basename "$base"; then
    echo "(blocked: Ralph does not inline .env* files; use a non-secret rules path.)"
    return 0
  fi
  if [[ ! -f "$p" ]]; then
    echo "(file not found at repo path \`$rel\`; follow project conventions if path differs)"
    return 0
  fi
  local size
  size="$(wc -c < "$p" | tr -d ' ')"
  if (( size > MAX_RULE_INLINE_BYTES )); then
    dd if="$p" bs=1 count="$MAX_RULE_INLINE_BYTES" 2>/dev/null
    echo ""
    echo "[Truncated after $MAX_RULE_INLINE_BYTES bytes]"
    return 0
  fi
  sed -n '1,$p' "$p"
}

context_block() {
  local agents_root="$1" agent_id="$2" workspace="$3"
  local cfg
  cfg="$(load_cfg_path "$agents_root" "$agent_id")"
  validate_config "$agents_root" "$agent_id" >/dev/null

  local name desc
  name="$(json_string_value "$cfg" "name")"
  desc="$(json_string_value "$cfg" "description")"
  echo ""
  echo "**Prebuilt agent profile**"
  echo "- **name:** $name"
  echo "- **role:** $desc"
  echo ""
  echo "**Rules (read and follow; full text inlined below):**"
  local rules
  rules="$(array_block "$cfg" "rules" || true)"
  while IFS= read -r line; do
    [[ "$line" =~ ^[[:space:]]*\"([^\"]+)\"[[:space:]]*,?[[:space:]]*$ ]] || continue
    local rule="${BASH_REMATCH[1]}"
    echo "  - \`$rule\`"
  done <<< "$rules"
  echo ""
  while IFS= read -r line; do
    [[ "$line" =~ ^[[:space:]]*\"([^\"]+)\"[[:space:]]*,?[[:space:]]*$ ]] || continue
    local rule="${BASH_REMATCH[1]}"
    echo "--- Rule file: \`$rule\` ---"
    inline_rule_file "$workspace" "$rule"
    echo ""
  done <<< "$rules"

  echo "**Skill paths (read these files in the repo as needed):**"
  local skills had_skill=0
  skills="$(array_block "$cfg" "skills" || true)"
  while IFS= read -r line; do
    [[ "$line" =~ ^[[:space:]]*\"([^\"]+)\"[[:space:]]*,?[[:space:]]*$ ]] || continue
    had_skill=1
    echo "  - \`${BASH_REMATCH[1]}\`"
  done <<< "$skills"
  [[ "$had_skill" == "1" ]] || echo "  - (none configured)"
  echo ""

  echo "**Declared output artifacts:**"
  required_artifacts "$agents_root" "$agent_id" | while IFS= read -r a; do
    [[ -n "$a" ]] && echo "  - \`$a\`"
  done
  echo ""
  echo "**Agent config:** \`$cfg\` (validated)."
}

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

downstream_stages() {
  local orch_file="$1"
  local current_stage_id="$2"
  local artifact_ns="$3"

  [[ -n "$orch_file" ]] || { echo "orchestration file path required" >&2; return 1; }
  [[ -n "$current_stage_id" ]] || { echo "current stage id required" >&2; return 1; }

  local artifact_ns_value="$artifact_ns"
  if [[ -z "$artifact_ns_value" ]]; then
    artifact_ns_value="${RALPH_ARTIFACT_NS:-${RALPH_PLAN_KEY:-default}}"
  fi

  local jq_bin
  if ! jq_bin="$(command -v jq 2>/dev/null)"; then
    echo "jq is required for downstream_stages" >&2
    return 1
  fi

  [[ -f "$orch_file" ]] || { echo "orchestration file not found: $orch_file" >&2; return 1; }

  if ! "$jq_bin" -e --arg id "$current_stage_id" '.stages[] | select(.id == $id)' "$orch_file" >/dev/null; then
    echo "stage not found: $current_stage_id" >&2
    return 1
  fi

  local -a output_paths=()
  local path
  while IFS= read -r path; do
    [[ -z "$path" ]] && continue
    path="${path//\{\{ARTIFACT_NS\}\}/$artifact_ns_value}"
    output_paths+=("$path")
  done < <("$jq_bin" -r --arg id "$current_stage_id" '.stages[] | select(.id == $id) | (.outputArtifacts // [])[].path' "$orch_file")

  if (( ${#output_paths[@]} == 0 )); then
    return 0
  fi

  local found_current=0
  local stage_json
  while IFS= read -r stage_json; do
    local stage_id
    stage_id="$("$jq_bin" -r '.id // empty' <<< "$stage_json")"
    if [[ "$found_current" -eq 0 ]]; then
      if [[ "$stage_id" == "$current_stage_id" ]]; then
        found_current=1
      fi
      continue
    fi

    local -a input_paths=()
    local input_path
    while IFS= read -r input_path; do
      [[ -z "$input_path" ]] && continue
      input_path="${input_path//\{\{ARTIFACT_NS\}\}/$artifact_ns_value}"
      input_paths+=("$input_path")
    done < <("$jq_bin" -r '(.inputArtifacts // [])[].path' <<< "$stage_json")

    if (( ${#input_paths[@]} == 0 )); then
      continue
    fi

    local matched=0
    local output_path
    for output_path in "${output_paths[@]}"; do
      local input_path_check
      for input_path_check in "${input_paths[@]}"; do
        if [[ "$output_path" == "$input_path_check" ]]; then
          matched=1
          break 2
        fi
      done
    done

    if [[ "$matched" -eq 0 ]]; then
      continue
    fi

    local plan_path plan_template
    plan_path="$("$jq_bin" -r '.plan // ""' <<< "$stage_json")"
    plan_template="$("$jq_bin" -r '.planTemplate // ""' <<< "$stage_json")"

    echo "---"
    echo "STAGE_ID=$stage_id"
    echo "PLAN_PATH=$plan_path"
    echo "PLAN_TEMPLATE=$plan_template"
  done < <("$jq_bin" -c '.stages[]' "$orch_file")
}

usage() {
  echo "Usage: agent-config-tool.sh list <agents_root>" >&2
  echo "       agent-config-tool.sh validate <agents_root> <agent_id> <workspace>" >&2
  echo "       agent-config-tool.sh model <agents_root> <agent_id>" >&2
  echo "       agent-config-tool.sh context <agents_root> <agent_id> <workspace>" >&2
  echo "       agent-config-tool.sh required-artifacts <agents_root> <agent_id>" >&2
  echo "       agent-config-tool.sh allowed-tools <agents_root> <agent_id>   # Claude --allowedTools line or empty" >&2
  echo "       agent-config-tool.sh downstream-stages <orch_file> <current_stage_id> [artifact_ns]" >&2
  exit 2
}

cmd="${1:-}"
case "$cmd" in
  list)
    [[ $# -eq 2 ]] || usage
    list_agent_ids "$2"
    ;;
  validate)
    [[ $# -eq 4 ]] || usage
    validate_config "$2" "$3"
    ;;
  model)
    [[ $# -eq 3 ]] || usage
    read_model "$2" "$3"
    ;;
  context)
    [[ $# -eq 4 ]] || usage
    context_block "$2" "$3" "$4"
    ;;
  required-artifacts)
    [[ $# -eq 3 ]] || usage
    required_artifacts "$2" "$3"
    ;;
  allowed-tools)
    [[ $# -eq 3 ]] || usage
    validate_config "$2" "$3" || exit 1
    read_allowed_tools "$2" "$3"
    ;;
  downstream-stages)
    [[ $# -ge 3 && $# -le 4 ]] || usage
    downstream_stages "$2" "$3" "${4:-}"
    ;;
  *)
    usage
    ;;
esac
