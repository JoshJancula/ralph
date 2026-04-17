#!/usr/bin/env bash

if [[ -n "${RALPH_ORCHESTRATOR_HANDOFFS_LOADED:-}" ]]; then
  return
fi
RALPH_ORCHESTRATOR_HANDOFFS_LOADED=1

if ! declare -F ralph_warn >/dev/null 2>&1; then
  # shellcheck source=/dev/null
  source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/error-handling.sh"
fi

# Public interface:
#   collect_incoming_handoffs -- scan orchestration JSON and return handoffs targeting a stage.
#   extract_handoff_tasks -- parse ## Tasks section of handoff markdown, emit unchecked items.
#   inject_handoffs_into_plan -- append/replace handoff blocks into plan file with idempotent guards.

# collect_incoming_handoffs <orch_file> <target_stage_id> [artifact_ns] [plan_key] [iteration]
#
# Scans the orchestration JSON for all stages, examines outputArtifacts entries where
# kind=handoff and to=<target_stage_id>, resolves template tokens in artifact paths
# ({{ARTIFACT_NS}}, {{PLAN_KEY}}, {{STAGE_ID}}, {{ITERATION}}), and prints one line per
# matching handoff in the format: from_stage<TAB>resolved_path
#
# Returns 0 on success (even if no handoffs found), 1 on fatal error (bad JSON, etc).
collect_incoming_handoffs() {
  local orch_file="$1"
  local target_stage_id="$2"
  local artifact_ns="${3:-}"
  local plan_key="${4:-}"
  local iteration="${5:-}"

  [[ -z "$orch_file" ]] && ralph_warn "collect_incoming_handoffs: orch_file required" && return 1
  [[ -z "$target_stage_id" ]] && ralph_warn "collect_incoming_handoffs: target_stage_id required" && return 1
  [[ ! -f "$orch_file" ]] && ralph_warn "collect_incoming_handoffs: orch_file not found: $orch_file" && return 1

  local jq_filter
  jq_filter='
    .stages[]? |
    select(.outputArtifacts? != null) |
    {
      from_id: .id,
      artifacts: .outputArtifacts[]?
    } |
    select(.artifacts.kind == "handoff" and .artifacts.to == $target) |
    . as $obj |
    {
      from_id: $obj.from_id,
      path: ($obj.artifacts.path |
        gsub("{{ARTIFACT_NS}}"; $artifact_ns) |
        gsub("{{PLAN_KEY}}"; $plan_key) |
        gsub("{{STAGE_ID}}"; $obj.from_id) |
        gsub("{{ITERATION}}"; $iteration)
      )
    } |
    "\(.from_id)\t\(.path)"
  '

  jq -r \
    --arg target "$target_stage_id" \
    --arg artifact_ns "$artifact_ns" \
    --arg plan_key "$plan_key" \
    --arg iteration "$iteration" \
    "$jq_filter" "$orch_file" 2>/dev/null || {
    ralph_warn "collect_incoming_handoffs: jq parse failed on $orch_file"
    return 1
  }

  return 0
}

# extract_handoff_tasks <handoff_file>
#
# Reads a handoff markdown file and extracts unchecked task lines (- [ ] ...) from the
# ## Tasks section. Stops parsing at the next heading (^##). Ignores checked items (- [x] ...).
# Emits each unchecked line verbatim (including the - [ ] prefix).
#
# Returns 0 on success (even if no tasks found), 1 on file not found or read error.
extract_handoff_tasks() {
  local handoff_file="$1"

  [[ -z "$handoff_file" ]] && ralph_warn "extract_handoff_tasks: handoff_file required" && return 1
  [[ ! -f "$handoff_file" ]] && ralph_warn "extract_handoff_tasks: handoff file not found: $handoff_file" && return 1

  local in_tasks_section=0
  local line_text

  while IFS= read -r line_text; do
    # Detect ## Tasks heading
    if [[ "$line_text" =~ ^##\ Tasks ]]; then
      in_tasks_section=1
      continue
    fi

    # If we find another heading while in tasks section, stop
    if [[ $in_tasks_section -eq 1 && "$line_text" =~ ^## ]]; then
      break
    fi

    # While in tasks section, emit unchecked task lines
    if [[ $in_tasks_section -eq 1 && "$line_text" =~ ^-\ \[\ \] ]]; then
      printf '%s\n' "$line_text"
    fi
  done < "$handoff_file"

  return 0
}

# inject_handoffs_into_plan <plan_file> <stage_id> <iteration>
#
# For each incoming handoff targeting <stage_id> (in current iteration), extract tasks
# from the handoff file and append/replace a guarded block in the plan file.
#
# Guarded block format:
#   <!-- RALPH_HANDOFF: from=<stage> iter=<iteration> sha=<10-char-hash> -->
#   ## Handoff from <stage> (iteration <iteration>)
#   - [ ] Task 1
#   - [ ] Task 2
#   <!-- /RALPH_HANDOFF -->
#
# Idempotency: if a handoff block with the same (from, iter, sha) already exists, skip.
# Sha change: if prior iteration's block exists but sha differs, replace it in-place.
#
# Returns 0 on success (even if no handoffs), 1 on fatal error.
inject_handoffs_into_plan() {
  local plan_file="$1"
  local stage_id="$2"
  local iteration="${3:-1}"

  [[ -z "$plan_file" ]] && ralph_warn "inject_handoffs_into_plan: plan_file required" && return 1
  [[ -z "$stage_id" ]] && ralph_warn "inject_handoffs_into_plan: stage_id required" && return 1
  [[ ! -f "$plan_file" ]] && ralph_warn "inject_handoffs_into_plan: plan_file not found: $plan_file" && return 1

  # Collect incoming handoffs (assumes ORCH_FILE is exported from orchestrator context)
  if [[ -z "${ORCH_FILE:-}" ]]; then
    ralph_warn "inject_handoffs_into_plan: ORCH_FILE not set in environment"
    return 1
  fi

  local handoffs_output
  handoffs_output="$(collect_incoming_handoffs "$ORCH_FILE" "$stage_id" "${RALPH_ARTIFACT_NS:-}" "${RALPH_PLAN_KEY:-}" "$iteration")" || {
    ralph_warn "inject_handoffs_into_plan: failed to collect incoming handoffs for stage $stage_id"
    return 1
  }

  # If no handoffs, return success
  [[ -z "$handoffs_output" ]] && return 0

  # Process each incoming handoff
  local from_stage handoff_path sha_str tasks_output guard_start guard_end temp_plan

  while IFS=$'\t' read -r from_stage handoff_path; do
    # Token resolution is now done in collect_incoming_handoffs, so handoff_path is already resolved

    # If handoff file does not exist, log warning and skip
    if [[ ! -f "$handoff_path" ]]; then
      ralph_warn "inject_handoffs_into_plan: handoff file not found (skipping): $handoff_path"
      continue
    fi

    # Compute sha of handoff content (first 10 chars). Prefer sha256sum, fall back to shasum on macOS.
    if command -v sha256sum >/dev/null 2>&1; then
      sha_str="$(sha256sum "$handoff_path" 2>/dev/null | cut -c1-10)" || {
        ralph_warn "inject_handoffs_into_plan: failed to compute sha for $handoff_path"
        continue
      }
    elif command -v shasum >/dev/null 2>&1; then
      sha_str="$(shasum -a 256 "$handoff_path" 2>/dev/null | cut -c1-10)" || {
        ralph_warn "inject_handoffs_into_plan: failed to compute sha for $handoff_path"
        continue
      }
    else
      ralph_warn "inject_handoffs_into_plan: no SHA-256 command available for $handoff_path"
      continue
    fi

    # Extract tasks from handoff
    tasks_output="$(extract_handoff_tasks "$handoff_path")" || {
      ralph_warn "inject_handoffs_into_plan: failed to extract tasks from $handoff_path"
      continue
    }

    # If no tasks found, log warning and skip
    if [[ -z "$tasks_output" ]]; then
      ralph_warn "inject_handoffs_into_plan: no tasks in $handoff_path (skipping)"
      continue
    fi

    # Define guard markers
    guard_start="<!-- RALPH_HANDOFF: from=$from_stage iter=$iteration sha=$sha_str -->"
    guard_end="<!-- /RALPH_HANDOFF -->"

    # Check if identical handoff block already exists
    if grep -q "<!-- RALPH_HANDOFF: from=$from_stage iter=$iteration sha=$sha_str -->" "$plan_file" 2>/dev/null; then
      continue
    fi

    # Check if a prior block for this handoff (same from/iter but different sha) exists; if so, replace it
    if grep -q "<!-- RALPH_HANDOFF: from=$from_stage iter=$iteration sha=" "$plan_file" 2>/dev/null; then
      # Replace the entire guarded block (from opening to closing guard)
      temp_plan="$plan_file.tmp.$$"
      cp "$plan_file" "$temp_plan"

      {
        # Print up to the old opening guard
        sed -n "/<!-- RALPH_HANDOFF: from=$from_stage iter=$iteration sha=/q;p" "$temp_plan"

        # Emit new block
        printf '%s\n' "$guard_start"
        printf '## Handoff from %s (iteration %s)\n' "$from_stage" "$iteration"
        printf '%s\n' "$tasks_output"
        printf '%s\n' "$guard_end"

        # Print everything after the old closing guard
        sed -n "/<!-- \/RALPH_HANDOFF -->/,\$p" "$temp_plan" | tail -n +2
      } > "$plan_file"

      rm -f "$temp_plan"
    else
      # Append new block
      {
        printf '\n%s\n' "$guard_start"
        printf '## Handoff from %s (iteration %s)\n' "$from_stage" "$iteration"
        printf '%s\n' "$tasks_output"
        printf '%s\n' "$guard_end"
      } >> "$plan_file"
    fi

  done <<< "$handoffs_output"

  return 0
}
