#!/usr/bin/env bash

if [[ -n "${RALPH_ORCHESTRATOR_PLANNER_LOADED:-}" ]]; then
  return
fi
RALPH_ORCHESTRATOR_PLANNER_LOADED=1

if ! declare -F ralph_warn >/dev/null 2>&1; then
  # shellcheck source=/dev/null
  source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/error-handling.sh"
fi

ORCH_PLANNER_QUEUE=()

ralph_planner_stage_enabled() {
  local gate="${RALPH_DYNAMIC_PLANNER:-}"
  if [[ -n "$gate" ]]; then
    case "$gate" in
      0) return 1 ;;
      1) return 0 ;;
      *)
        ralph_warn "RALPH_DYNAMIC_PLANNER: invalid value '$gate' (use 0 or 1)"
        return 2
        ;;
    esac
  fi
  case "${RALPH_MODE:-no}" in
    ralph|hybrid) return 0 ;;
    *) return 1 ;;
  esac
}

ralph_planner_resolve_py() {
  local candidate="" dir
  for dir in "${RALPH_ACTIVE_DIR:-}" "${RALPH_DIR:-}"; do
    [[ -n "$dir" && -f "$dir/python/planner_contract.py" ]] || continue
    candidate="$dir/python/planner_contract.py"
    break
  done
  if [[ -z "$candidate" ]]; then
    ralph_warn "planner contract helper not found under Ralph python helpers"
    return 1
  fi
  printf '%s\n' "$candidate"
}

orch_planner_queue_clear() {
  ORCH_PLANNER_QUEUE=()
  ORCH_PLANNER_QUEUE_INDEX=0
}

orch_planner_queue_length() {
  printf '%s' "${#ORCH_PLANNER_QUEUE[@]}"
}

orch_planner_queue_push_json() {
  local stage_json="$1"
  ORCH_PLANNER_QUEUE+=("$stage_json")
}

orch_planner_queue_next_json() {
  local _out_var="${1:-ORCH_PLANNER_QUEUE_CURRENT}"
  local index="${ORCH_PLANNER_QUEUE_INDEX:-0}"
  if (( index >= ${#ORCH_PLANNER_QUEUE[@]} )); then
    return 1
  fi
  printf -v "$_out_var" '%s' "${ORCH_PLANNER_QUEUE[$index]}"
  ORCH_PLANNER_QUEUE_INDEX=$((index + 1))
  return 0
}

orch_planner_queue_has_pending() {
  local index="${ORCH_PLANNER_QUEUE_INDEX:-0}"
  (( index < ${#ORCH_PLANNER_QUEUE[@]} ))
}

orch_planner_validate_orchestration() {
  local orch_file="$1"
  if ! ralph_planner_stage_enabled; then
    return 0
  fi
  if ! echo "$(jq -c '.stages[]? | select(has("planner"))' "$orch_file" 2>/dev/null || true)" | grep -q .; then
    return 0
  fi
  local py
  py="$(ralph_planner_resolve_py)" || return 1
  if ! command -v python3 >/dev/null 2>&1; then
    ralph_warn "orch_planner_validate_orchestration: python3 is required when planner stages are declared"
    return 1
  fi
  python3 "$py" validate-orchestration --orchestration "$orch_file"
}

orch_planner_stage_has_planner() {
  local stage_json="$1"
  echo "$stage_json" | jq -e '.planner | type == "object"' >/dev/null 2>&1
}

orch_planner_find_artifact_path() {
  local stage_json="$1"
  local path=""
  path="$(echo "$stage_json" | jq -r '
    [(.artifacts // []), (.outputArtifacts // [])] | add
    | map(select((.schema // "") | test("planner-output\\.schema\\.json$")))
    | .[0].path // empty
  ' 2>/dev/null || echo "")"
  if [[ -n "$path" ]]; then
    printf '%s' "$path"
    return 0
  fi
  path="$(echo "$stage_json" | jq -r '
    [(.artifacts // []), (.outputArtifacts // [])] | add
    | map(select((.path // "") | test("\\.json$")))
    | .[0].path // empty
  ' 2>/dev/null || echo "")"
  if [[ -n "$path" ]]; then
    printf '%s' "$path"
    return 0
  fi
  echo "$stage_json" | jq -r '(.artifacts[0].path // .outputArtifacts[0].path // empty)' 2>/dev/null
}

orch_planner_plan_key() {
  local orch_file="$1"
  local plan_key=""
  plan_key="$(jq -r '.namespace // .name // empty' "$orch_file" 2>/dev/null || echo "")"
  if [[ -z "$plan_key" ]]; then
    plan_key="$(basename "$orch_file" .orch.json)"
  fi
  printf '%s' "$plan_key"
}

orch_planner_show_manifest() {
  local manifest_json="$1"
  local py summary
  py="$(ralph_planner_resolve_py)" || return 1
  summary="$(printf '%s' "$manifest_json" | python3 -c '
import json, sys
sys.path.insert(0, sys.argv[1])
import planner_contract as pc
manifest = json.load(sys.stdin)
print(pc.format_dry_run_summary(manifest))
' "$(dirname "$py")" 2>/dev/null || echo "")"
  if [[ -n "$summary" ]]; then
    echo "$summary"
  else
    echo "$manifest_json" | python3 -c 'import json,sys; m=json.load(sys.stdin); print(json.dumps(m, indent=2))' 2>/dev/null || echo "$manifest_json"
  fi
}

orch_planner_apply_output() {
  local stage_json="$1"
  local stage_id="$2"
  local step_n="$3"
  local step_status_var="$4"

  if ! orch_planner_stage_has_planner "$stage_json"; then
    return 0
  fi
  if ! ralph_planner_stage_enabled; then
    return 0
  fi

  local py artifact_rel artifact_abs planner_json plan_key namespace manifest_json dry_flag=""
  py="$(ralph_planner_resolve_py)" || return 1
  if ! command -v python3 >/dev/null 2>&1; then
    ralph_warn "orch_planner_apply_output: python3 is required for planner dispatch"
    return 1
  fi

  artifact_rel="$(orch_planner_find_artifact_path "$stage_json")"
  if [[ -z "$artifact_rel" ]]; then
    ralph_orchestrator_log "FAIL step $step_n: planner stage missing artifact path"
    echo -e "${C_R}${C_BOLD}Step $step_n failed (planner missing artifact)${C_RST}" >&2
    printf -v "$step_status_var" '%s' 1
    return 1
  fi
  artifact_rel="$(expand_artifact_tokens "$artifact_rel")"
  if [[ "$artifact_rel" == /* ]]; then
    artifact_abs="$artifact_rel"
  else
    artifact_abs="$WORKSPACE/$artifact_rel"
  fi
  if [[ ! -f "$artifact_abs" ]]; then
    ralph_orchestrator_log "FAIL step $step_n: planner artifact not found: $artifact_abs"
    echo -e "${C_R}${C_BOLD}Step $step_n failed (planner artifact missing)${C_RST}" >&2
    printf -v "$step_status_var" '%s' 1
    return 1
  fi

  planner_json="$(echo "$stage_json" | jq -c '.planner' 2>/dev/null || echo "{}")"
  plan_key="$(orch_planner_plan_key "$ORCH_FILE")"
  namespace="$(jq -r '.namespace // empty' "$ORCH_FILE" 2>/dev/null || echo "")"
  local schema_rel schema_abs=""
  schema_rel="$(echo "$stage_json" | jq -r '
    [(.artifacts // []), (.outputArtifacts // [])] | add
    | map(select((.schema // "") | test("planner-output\\.schema\\.json$")))
    | .[0].schema // empty
  ' 2>/dev/null || echo "")"
  if [[ -z "$schema_rel" ]]; then
    schema_rel="bundle/.ralph/schemas/planner-output.schema.json"
  fi
  if [[ "$schema_rel" == /* ]]; then
    schema_abs="$schema_rel"
  elif [[ -f "$WORKSPACE/$schema_rel" ]]; then
    schema_abs="$WORKSPACE/$schema_rel"
  elif [[ -f "${RALPH_DIR:-}/../schemas/planner-output.schema.json" ]]; then
    schema_abs="$(cd "${RALPH_DIR:-}/../schemas" && pwd)/planner-output.schema.json"
  else
    schema_abs="$WORKSPACE/$schema_rel"
  fi
  if [[ "${ORCHESTRATOR_DRY_RUN:-0}" == "1" ]]; then
    dry_flag="--dry-run"
  fi

  if ! manifest_json="$(python3 "$py" apply-output \
    --artifact "$artifact_abs" \
    --planner-json "$planner_json" \
    --workspace "$WORKSPACE" \
    --plan-key "$plan_key" \
    --planner-stage-id "$stage_id" \
    --namespace "$namespace" \
    --schema "$schema_abs" \
    $dry_flag 2>&1)"; then
    ralph_orchestrator_log "FAIL step $step_n: planner apply failed: $manifest_json"
    echo -e "${C_R}${C_BOLD}Step $step_n planner apply failed${C_RST}" >&2
    echo "  $manifest_json" >&2
    printf -v "$step_status_var" '%s' 1
    return 1
  fi

  echo -e "${C_Y}$(orch_planner_show_manifest "$manifest_json")${C_RST}"

  local output_mode stage_line
  output_mode="$(printf '%s' "$manifest_json" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("outputMode",""))' 2>/dev/null || echo "")"
  if [[ "$output_mode" == "stages" && "${ORCHESTRATOR_DRY_RUN:-0}" != "1" ]]; then
    while IFS= read -r stage_line; do
      [[ -z "$stage_line" ]] && continue
      orch_planner_queue_push_json "$stage_line"
    done < <(printf '%s' "$manifest_json" | python3 -c '
import json, sys
manifest = json.load(sys.stdin)
for stage in manifest.get("stages") or []:
    print(json.dumps(stage, separators=(",", ":")))
' 2>/dev/null || true)
    ralph_orchestrator_log "planner step $step_n queued ${#ORCH_PLANNER_QUEUE[@]} generated stage(s)"
  fi
  return 0
}

ralph_planner_prepare_prompt() {
  local planner_json="$1"
  local plan_key="$2"
  local py
  py="$(ralph_planner_resolve_py)" || return 1
  python3 "$py" prompt-block \
    --planner-json "$planner_json" \
    --plan-key "$plan_key" \
    --schema "bundle/.ralph/schemas/planner-output.schema.json"
}
