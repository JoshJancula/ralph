#!/usr/bin/env bash

if [[ -n "${RALPH_ORCHESTRATOR_VERIFY_LOADED:-}" ]]; then
  return
fi
RALPH_ORCHESTRATOR_VERIFY_LOADED=1

# Public interface:
#   artifact_remediation_text -- prints remediation steps for missing artifacts.
#   verify_step_artifacts -- asserts EXPECTED_ARTIFACT_PATHS exist and are non-empty after a stage.

artifact_remediation_text() {
  echo "  Remediation:"
  echo "    1. Open the step plan and ensure the agent finished every TODO (agent should write declared outputs)."
  echo "    2. Create or fill the missing path under the repo root (see .ralph-workspace/artifacts/ for handoff files)."
  echo "    3. To require different files for this step, edit artifacts or outputArtifacts in the JSON stage"
  echo "       or adjust output_artifacts in the agent config."
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
