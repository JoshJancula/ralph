#!/usr/bin/env bash

if [[ -n "${RALPH_ORCHESTRATOR_ROUTER_LOADED:-}" ]]; then
  return
fi
RALPH_ORCHESTRATOR_ROUTER_LOADED=1

if ! declare -F ralph_warn >/dev/null 2>&1; then
  # shellcheck source=/dev/null
  source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/error-handling.sh"
fi

ORCH_ROUTER_SKIP_KEYS=()
ORCH_ROUTER_SKIP_VALS=()
ORCH_ROUTER_TERMINAL_ACTIVE=0

ralph_router_stage_enabled() {
  local gate="${RALPH_ROUTER_STAGE:-}"
  if [[ -n "$gate" ]]; then
    case "$gate" in
      0) return 1 ;;
      1) return 0 ;;
      *)
        ralph_warn "RALPH_ROUTER_STAGE: invalid value '$gate' (use 0 or 1)"
        return 2
        ;;
    esac
  fi
  case "${RALPH_MODE:-no}" in
    ralph|hybrid) return 0 ;;
    *) return 1 ;;
  esac
}

ralph_router_resolve_py() {
  local candidate="" dir
  for dir in "${RALPH_ACTIVE_DIR:-}" "${RALPH_DIR:-}"; do
    [[ -n "$dir" && -f "$dir/python/router_contract.py" ]] || continue
    candidate="$dir/python/router_contract.py"
    break
  done
  if [[ -z "$candidate" ]]; then
    ralph_warn "router contract helper not found under Ralph python helpers"
    return 1
  fi
  printf '%s\n' "$candidate"
}

orch_router_skip_map_set() {
  local key="$1"
  local val="${2:-1}"
  local idx=0
  for key_at in "${ORCH_ROUTER_SKIP_KEYS[@]}"; do
    if [[ "$key_at" == "$key" ]]; then
      ORCH_ROUTER_SKIP_VALS[$idx]="$val"
      return 0
    fi
    idx=$((idx + 1))
  done
  ORCH_ROUTER_SKIP_KEYS+=("$key")
  ORCH_ROUTER_SKIP_VALS+=("$val")
}

orch_router_skip_map_has() {
  local key="$1"
  local idx=0
  for key_at in "${ORCH_ROUTER_SKIP_KEYS[@]}"; do
    if [[ "$key_at" == "$key" ]]; then
      printf '%s' "${ORCH_ROUTER_SKIP_VALS[$idx]}"
      return 0
    fi
    idx=$((idx + 1))
  done
  return 1
}

orch_router_skip_map_clear() {
  ORCH_ROUTER_SKIP_KEYS=()
  ORCH_ROUTER_SKIP_VALS=()
}

orch_router_validate_orchestration() {
  local orch_file="$1"
  if ! ralph_router_stage_enabled; then
    return 0
  fi
  if ! echo "$(jq -c '.stages[]? | select(has("router"))' "$orch_file" 2>/dev/null || true)" | grep -q .; then
    return 0
  fi
  local py
  py="$(ralph_router_resolve_py)" || return 1
  if ! command -v python3 >/dev/null 2>&1; then
    ralph_warn "orch_router_validate_orchestration: python3 is required when router stages are declared"
    return 1
  fi
  python3 "$py" validate-orchestration --orchestration "$orch_file"
}

orch_router_stage_has_router() {
  local stage_json="$1"
  echo "$stage_json" | jq -e '.router | type == "object"' >/dev/null 2>&1
}

orch_router_find_artifact_path() {
  local stage_json="$1"
  local path=""
  path="$(echo "$stage_json" | jq -r '
    [(.artifacts // []), (.outputArtifacts // [])] | add
    | map(select((.schema // "") | test("router-decision\\.schema\\.json$")))
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

orch_router_record_skipped_stage() {
  local step_n="$1"
  local stage_id="$2"
  local agent="${3:-}"
  local runtime="${4:-}"
  _orch_stage_usages+="${_orch_stage_usages:+,}{\"step\":${step_n},\"stage\":\"${stage_id}\",\"agent\":\"${agent}\",\"runtime\":\"${runtime}\",\"status\":\"skipped\",\"input_tokens\":0,\"output_tokens\":0,\"cache_creation_input_tokens\":0,\"cache_read_input_tokens\":0}"
  ralph_orchestrator_log "step $step_n skipped by router dispatch: stage=$stage_id"
}

orch_router_apply_decision() {
  local stage_json="$1"
  local stage_id="$2"
  local stage_index="$3"
  local step_n="$4"
  local step_status_var="$5"

  if ! orch_router_stage_has_router "$stage_json"; then
    return 0
  fi
  if ! ralph_router_stage_enabled; then
    return 0
  fi

  local py artifact_rel artifact_abs router_json stage_ids_json waves_json resolved_json
  py="$(ralph_router_resolve_py)" || return 1
  if ! command -v python3 >/dev/null 2>&1; then
    ralph_warn "orch_router_apply_decision: python3 is required for router dispatch"
    return 1
  fi

  artifact_rel="$(orch_router_find_artifact_path "$stage_json")"
  if [[ -z "$artifact_rel" ]]; then
    ralph_orchestrator_log "FAIL step $step_n: router stage missing artifact path"
    echo -e "${C_R}${C_BOLD}Step $step_n failed (router missing artifact)${C_RST}" >&2
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
    ralph_orchestrator_log "FAIL step $step_n: router artifact not found: $artifact_abs"
    echo -e "${C_R}${C_BOLD}Step $step_n failed (router artifact missing)${C_RST}" >&2
    printf -v "$step_status_var" '%s' 1
    return 1
  fi

  router_json="$(echo "$stage_json" | jq -c '.router' 2>/dev/null || echo "{}")"
  stage_ids_json="$(jq -c '[.stages[].id]' "$ORCH_FILE" 2>/dev/null || echo "[]")"
  waves_json="$(jq -c '[.parallelStages[]? // empty]' "$ORCH_FILE" 2>/dev/null || echo "[]")"

  if ! resolved_json="$(python3 "$py" resolve-target \
    --artifact "$artifact_abs" \
    --router-json "$router_json" \
    --stage-index "$stage_index" \
    --stage-ids-json "$stage_ids_json" \
    --parallel-waves-json "$waves_json" 2>&1)"; then
    ralph_orchestrator_log "FAIL step $step_n: router dispatch failed: $resolved_json"
    echo -e "${C_R}${C_BOLD}Step $step_n router dispatch failed${C_RST}" >&2
    echo "  $resolved_json" >&2
    printf -v "$step_status_var" '%s' 1
    return 1
  fi

  local resolved_target resolved_kind
  resolved_target="$(printf '%s' "$resolved_json" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("target",""))' 2>/dev/null || echo "")"
  resolved_kind="$(printf '%s' "$resolved_json" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("kind",""))' 2>/dev/null || echo "")"

  case "$resolved_kind" in
    terminal|default-terminal)
      ORCH_ROUTER_TERMINAL_ACTIVE=1
      ralph_orchestrator_log "router step $step_n selected terminal outcome: $resolved_target"
      echo -e "${C_Y}Router selected terminal outcome: ${resolved_target}${C_RST}"
      ;;
    stage|default-stage)
      local allowed_target
      while IFS= read -r allowed_target; do
        [[ -z "$allowed_target" ]] && continue
        [[ "$allowed_target" == "$resolved_target" ]] && continue
        orch_router_skip_map_set "$allowed_target" 1
      done < <(echo "$stage_json" | jq -r '.router.allowedTargets[]?' 2>/dev/null)
      ralph_orchestrator_log "router step $step_n selected stage: $resolved_target (skipped others in allowedTargets)"
      echo -e "${C_Y}Router selected stage: ${resolved_target}${C_RST}"
      ;;
    *)
      ralph_orchestrator_log "FAIL step $step_n: unknown router resolution kind: $resolved_kind"
      printf -v "$step_status_var" '%s' 1
      return 1
      ;;
  esac
  return 0
}

ralph_router_prepare_prompt() {
  local router_json="$1"
  local py
  py="$(ralph_router_resolve_py)" || return 1
  python3 "$py" prompt-block --router-json "$router_json" --schema "bundle/.ralph/schemas/router-decision.schema.json"
}
