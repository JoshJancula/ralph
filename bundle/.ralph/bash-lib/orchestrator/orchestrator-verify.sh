#!/usr/bin/env bash

if [[ -n "${RALPH_ORCHESTRATOR_VERIFY_LOADED:-}" ]]; then
  return
fi
RALPH_ORCHESTRATOR_VERIFY_LOADED=1

# Public interface:
#   orch_stage_collect_expected_artifacts -- stage-only required output paths into EXPECTED_ARTIFACT_PATHS.
#   artifact_remediation_text -- prints remediation steps for missing artifacts.
#   verify_step_artifacts -- asserts EXPECTED_ARTIFACT_PATHS exist and are non-empty after a stage.

# Collect required output paths exclusively from the stage JSON (artifacts +
# outputArtifacts with required=true). Template tokens are expanded via
# artifact_paths_append_unique. Roles and profile output_artifacts are never
# consulted.
orch_stage_collect_expected_artifacts() {
  local stage_json="$1"
  local artifacts_array artifact_path

  EXPECTED_ARTIFACT_PATHS=()
  artifacts_array="$(echo "$stage_json" | jq '.artifacts // []' 2>/dev/null)" || artifacts_array="[]"
  while IFS= read -r artifact_path; do
    [[ -z "$artifact_path" ]] && continue
    artifact_paths_append_unique "$artifact_path"
  done < <(echo "$artifacts_array" | jq -r '.[] | select(.required == true) | .path' 2>/dev/null)
  while IFS= read -r artifact_path; do
    [[ -z "$artifact_path" ]] && continue
    artifact_paths_append_unique "$artifact_path"
  done < <(echo "$stage_json" | jq -r '.outputArtifacts[]? | select(.required == true) | .path' 2>/dev/null)
}

artifact_remediation_text() {
  echo "  Remediation:"
  echo "    1. Open the step plan and ensure the agent finished every TODO (agent should write declared outputs)."
  echo "    2. Create or fill the missing path under the repo root (see .ralph-workspace/artifacts/ for handoff files)."
  echo "    3. To require different files for this step, edit artifacts or outputArtifacts in the JSON stage."
  echo "    4. Re-run from repo root: $0 --orchestration \"$ORCH_FILE\" \"$WORKSPACE\""
}

# After each successful delegated run: each expected artifact must exist and be non-empty.
verify_step_artifacts() {
  local step_n="$1"
  local ap abs
  if ((${#EXPECTED_ARTIFACT_PATHS[@]} > 0)); then
    for ap in "${EXPECTED_ARTIFACT_PATHS[@]}"; do
      if [[ "$ap" == /* ]]; then
        abs="$ap"
      elif [[ "$ap" == .ralph-workspace/* && -n "${RALPH_PLAN_WORKSPACE_ROOT:-}" ]]; then
        abs="${RALPH_PLAN_WORKSPACE_ROOT%/}/${ap#.ralph-workspace/}"
      else
        abs="$WORKSPACE/$ap"
      fi
      if [[ ! -f "$abs" ]]; then
        ralph_orchestrator_log "FAIL step $step_n artifact check: missing file: $ap (resolved: $abs)"
        {
          echo ""
          echo "======== artifact verification failure ========"
          echo "Step: $step_n"
          echo "Reason: expected file missing"
          echo "Path (repo-relative or as given): $ap"
          echo "Resolved: $abs"
          artifact_remediation_text
          echo "=============================================="
        } >>"$LOG_FILE"
        echo -e "${C_R}${C_BOLD}Step $step_n artifact check failed (file missing)${C_RST}" >&2
        echo "  Expected file missing: $ap" >&2
        echo "  Resolved path: $abs" >&2
        artifact_remediation_text >&2
        echo "  Log: $LOG_FILE" >&2
        return 1
      fi
      if [[ ! -s "$abs" ]]; then
        ralph_orchestrator_log "FAIL step $step_n artifact check: empty file: $ap (resolved: $abs)"
        {
          echo ""
          echo "======== artifact verification failure ========"
          echo "Step: $step_n"
          echo "Reason: file exists but is empty (size 0)"
          echo "Path (repo-relative or as given): $ap"
          echo "Resolved: $abs"
          artifact_remediation_text
          echo "=============================================="
        } >>"$LOG_FILE"
        echo -e "${C_R}${C_BOLD}Step $step_n artifact check failed (empty file)${C_RST}" >&2
        echo "  Expected non-empty file: $ap" >&2
        echo "  Resolved path: $abs" >&2
        artifact_remediation_text >&2
        echo "  Log: $LOG_FILE" >&2
        return 1
      fi
    done
  fi
  return 0
}
