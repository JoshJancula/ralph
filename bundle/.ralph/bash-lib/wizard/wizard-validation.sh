#!/usr/bin/env bash
#
# Validation helpers used by the orchestration wizard.
#
# Public interface:
#   configure_parallel_stages -- optional parallelStages waves (before input deps and loops).
#   configure_stage_input_dependencies -- interactive inputArtifacts wiring between stages.
#   configure_loop_rules -- loopControl defaults for review stages.

# Scratch array for parallel wave tokenization (configure_parallel_stages only).
_wizard_parallel_wave_toks=()

# Split a wave CSV into _wizard_parallel_wave_toks (trim whitespace; skip empties).
_wizard_parallel_wave_split() {
  local raw="${1-}"
  _wizard_parallel_wave_toks=()
  [[ -n "${raw// }" ]] || return 0
  local IFS=','
  local -a _parts
  read -ra _parts <<< "$raw"
  unset IFS
  local p trimmed
  for p in "${_parts[@]}"; do
    trimmed="$(printf '%s' "$p" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
    [[ -n "$trimmed" ]] || continue
    local w
    for w in $trimmed; do
      [[ -n "$w" ]] || continue
      _wizard_parallel_wave_toks+=("$w")
    done
  done
}

# Return 0 if _wizard_parallel_wave_toks contains duplicate ids.
_wizard_parallel_wave_toks_have_duplicates() {
  local i j
  (( ${#_wizard_parallel_wave_toks[@]} <= 1 )) && return 1
  for ((i = 0; i < ${#_wizard_parallel_wave_toks[@]}; i++)); do
    for ((j = i + 1; j < ${#_wizard_parallel_wave_toks[@]}; j++)); do
      if [[ "${_wizard_parallel_wave_toks[i]}" == "${_wizard_parallel_wave_toks[j]}" ]]; then
        return 0
      fi
    done
  done
  return 1
}

# Return 0 if id appears in wave CSV (comma tokens, trimmed).
_wizard_parallel_wave_csv_contains_id() {
  local id="$1" wave_csv="$2"
  _wizard_parallel_wave_split "$wave_csv"
  local t
  for t in "${_wizard_parallel_wave_toks[@]}"; do
    [[ "$t" == "$id" ]] && return 0
  done
  return 1
}

configure_stage_input_dependencies() {
  stage_input_sources=()
  print_step "5/7" "Stage input dependencies"
  print_info "Choose stage inputs (writes to: inputArtifacts in the JSON)"
  print_hint "- Use this so a stage knows which earlier artifacts to read."
  print_hint "- This is how one agent uses output from a previous agent."
  print_hint "- Example: plan stage artifacts -> implementation stage."
  print_hint "- Example: implementation artifacts -> qa or code-review stage."
  print_hint "- Type numbers or stage names, with commas or spaces."
  print_hint "- Type 'none' for no handoff, or Enter for the default."

  handoff_choice="$(ralph_prompt_yesno "Set custom stage inputs (inputArtifacts)" "n")"
  if [[ "$handoff_choice" == "y" ]]; then
    for idx in "${!stage_ids[@]}"; do
      local current_stage default_input known_csv
      current_stage="${stage_ids[$idx]}"
      default_input=""
      if (( idx > 0 )); then
        default_input="${stage_ids[$((idx - 1))]}"
      fi

      # Build known-csv of stages before current (earlier stages only).
      # Use array slicing so the first stage naturally gets an empty list.
      local earlier_stages=()
      if (( idx > 0 )); then
        earlier_stages=("${stage_ids[@]:0:idx}")
      fi

      if (( ${#earlier_stages[@]} == 0 )); then
        # First stage has no earlier stages to depend on
        stage_input_sources+=("")
        continue
      fi

      local IFS=','
      known_csv="${earlier_stages[*]}"
      unset IFS

      local result
      result="$(ralph_prompt_list "Which earlier stages should \"$current_stage\" read from (inputArtifacts)" "$default_input" "$known_csv")"

      # ralph_prompt_list handles validation and echo-back; self-references and
      # downstream stages automatically land in "ignored" because they're not in known_csv
      stage_input_sources+=("$result")
    done
  else
    # Populate empty strings for each stage when not setting custom inputs
    for _ in "${!stage_ids[@]}"; do
      stage_input_sources+=("")
    done
  fi
}

configure_parallel_stages() {
  parallel_stage_waves=()
  parallel_stages_enabled="false"

  print_step "4/7" "Parallel stages (optional)"
  print_hint "- Use this to run independent stages in parallel waves."
  print_hint "- Each wave runs all listed stages concurrently; waves run in order."
  print_hint "- parallelStages in JSON is a string array: one JSON string per wave, comma-separated stage ids (same wave order as below)."
  print_hint "- Commas or spaces in answers are accepted; ids are trimmed and stored as comma-separated strings."
  print_hint "- Enter one wave per line as comma-separated stage ids (example: research,implementation)."
  print_hint "- Press Enter on an empty line to use all remaining stages for the current wave."

  parallel_choice="$(ralph_prompt_yesno "Enable parallel stage waves (parallelStages)" "n")"
  if [[ "$parallel_choice" == "n" ]]; then
    return 0
  fi

  parallel_stages_enabled="true"

  # Build the pool of stages available for waves (start with all stages)
  local available_stages=()
  for s in "${stage_ids[@]}"; do
    available_stages+=("$s")
  done

  local wave_num=1
  while (( ${#available_stages[@]} > 0 )); do
    # Build comma-separated known list for this wave
    local known_csv=""
    local IFS=','
    known_csv="${available_stages[*]}"
    unset IFS

    local wave_result
    wave_result="$(ralph_prompt_list "Wave $wave_num stages" "$known_csv" "$known_csv")"

    # Empty input should expand to the remaining stages for this wave.
    if [[ -z "$wave_result" ]]; then
      wave_result="$known_csv"
    fi

    _wizard_parallel_wave_split "$wave_result"
    if (( ${#_wizard_parallel_wave_toks[@]} == 0 )); then
      ralph_die "Wave $wave_num: no stage ids in this wave (use ids from the remaining list: $known_csv)."
    fi
    if _wizard_parallel_wave_toks_have_duplicates; then
      ralph_die "Wave $wave_num: duplicate stage id in the same wave; each stage id must appear once across all waves."
    fi

    local tok
    for tok in "${_wizard_parallel_wave_toks[@]}"; do
      local in_pool=0
      for stage in "${available_stages[@]}"; do
        if [[ "$stage" == "$tok" ]]; then
          in_pool=1
          break
        fi
      done
      if (( in_pool == 0 )); then
        ralph_die "Wave $wave_num: stage \"$tok\" is not in the remaining pool ($known_csv). Unknown ids and ids already placed in an earlier wave are rejected."
      fi
    done

    local joined_wave=""
    joined_wave="$(IFS=','; printf '%s' "${_wizard_parallel_wave_toks[*]}")"
    parallel_stage_waves+=("$joined_wave")

    # Update available stages (remove assigned ones)
    local new_available=()
    for stage in "${available_stages[@]}"; do
      local in_wave=0
      for tok in "${_wizard_parallel_wave_toks[@]}"; do
        if [[ "$stage" == "$tok" ]]; then
          in_wave=1
          break
        fi
      done
      if (( in_wave == 0 )); then
        new_available+=("$stage")
      fi
    done
    if (( ${#new_available[@]} > 0 )); then
      available_stages=("${new_available[@]}")
    else
      available_stages=()
    fi

    wave_num=$((wave_num + 1))
  done

  if [[ "$parallel_stages_enabled" != "true" ]]; then
    return 0
  fi

  if (( ${#parallel_stage_waves[@]} == 0 )); then
    echo "Parallel waves enabled but none were provided; disabling." >&2
    parallel_stages_enabled="false"
    return 0
  fi

  # Validate that all stages were assigned exactly once across waves
  for id in "${stage_ids[@]}"; do
    local found=0
    for wave in "${parallel_stage_waves[@]}"; do
      if _wizard_parallel_wave_csv_contains_id "$id" "$wave"; then
        found=$((found + 1))
      fi
    done
    if (( found == 0 )); then
      ralph_die "Parallel waves must include every stage; missing \"$id\"."
    fi
    if (( found > 1 )); then
      ralph_die "Parallel waves: stage \"$id\" appears in more than one wave."
    fi
  done
}

configure_loop_rules() {
  loop_sources=()
  loop_targets=()
  loop_max_iterations=()
  print_step "6/7" "Optional loop rules"
  print_hint "- Use loop rules for review/testing stages that may find issues."
  print_hint "- If a review/test stage finds a problem, it can send work back."
  print_hint "- If review/test says everything is good, pipeline moves forward."
  print_hint "- This writes to loopControl (loopBackTo + maxIterations) in JSON."
  print_hint "- You can set loops quickly with a list, or go stage-by-stage."
  print_hint "- Quick list examples: 2,4 or review,qa (choose loop source stages)."
  print_hint "- Then pick where each source stage should send work back."
  print_hint "- In loop prompts, Enter (or 0/none) means no loop."

  loop_choice="$(ralph_prompt_yesno "Add loop rules (loopControl)" "n")"
  if [[ "$loop_choice" == "y" ]]; then
    print_info "Loop setup mode (loopControl)"
    local loop_mode
    loop_mode="$(ralph_menu_select --prompt "loop source mode" --default 2 -- "pick source stages once, then configure each" "walk every stage one-by-one")"
    if [[ "$loop_mode" == "pick source stages once, then configure each" ]]; then
      # Build known-csv from all stage_ids
      local known_csv=""
      local IFS=','
      known_csv="${stage_ids[*]}"
      unset IFS

      local sources_result
      sources_result="$(ralph_prompt_list "Stages that should loop (loop sources)" "" "$known_csv")"

      # Empty or "none" means no loop sources
      if [[ -z "$sources_result" || "$sources_result" == "none" ]]; then
        selected_loop_sources=()
      else
        # Parse comma-separated result
        local IFS=','
        for stage in $sources_result; do
          [[ -n "$stage" ]] || continue
          selected_loop_sources+=("$stage")
        done
        unset IFS
      fi

      for loop_stage in "${selected_loop_sources[@]-}"; do
        echo "" >&2
        local loop_back loop_iterations
        loop_back="$(choose_stage_id_from_list "Send \"$loop_stage\" back to which stage? (loopBackTo, number/id, Enter for none): " 1 "${stage_ids[@]}")"
        if [[ -z "$loop_back" ]]; then
          echo "No loop target set for $loop_stage. Skipping this loop rule." >&2
          continue
        fi
        loop_iterations="$(ralph_prompt_text "Max iterations for \"$loop_stage\"" "2")"
        if ! [[ "$loop_iterations" =~ ^[0-9]+$ ]]; then
          echo "Invalid number. Using 2." >&2
          loop_iterations=2
        fi
        loop_sources+=("$loop_stage")
        loop_targets+=("$loop_back")
        loop_max_iterations+=("$loop_iterations")
      done
    else
      for loop_stage in "${stage_ids[@]}"; do
        echo "" >&2
        local loop_back loop_iterations
        loop_back="$(choose_stage_id_from_list "Send \"$loop_stage\" back to which stage? (loopBackTo, number/id, Enter for none): " 1 "${stage_ids[@]}")"
        if [[ -z "$loop_back" ]]; then
          continue
        fi
        loop_iterations="$(ralph_prompt_text "Max iterations for \"$loop_stage\"" "2")"
        if ! [[ "$loop_iterations" =~ ^[0-9]+$ ]]; then
          echo "Invalid number. Using 2." >&2
          loop_iterations=2
        fi
        loop_sources+=("$loop_stage")
        loop_targets+=("$loop_back")
        loop_max_iterations+=("$loop_iterations")
      done
    fi
  fi
}
