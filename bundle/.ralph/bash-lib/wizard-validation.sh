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
  print_hint "- Parallelism cannot be combined with loopControl."
  print_hint "- Enter one wave per line as comma-separated stage ids (example: research,implementation)."
  print_hint "- Press Enter on an empty line to finish, or type 'none' to disable."

  read -rp "Enable parallel stage waves? (parallelStages) [y/N]: " parallel_choice
  if [[ ! "$parallel_choice" =~ ^[Yy] ]]; then
    return 0
  fi

  parallel_stages_enabled="true"
  print_info "Available stages for parallel waves:"
  for idx in "${!stage_ids[@]}"; do
    printf '  %2d) %s\n' "$((idx + 1))" "${stage_ids[$idx]}" >&2
  done

  while true; do
    read -rp "Wave stages (comma-separated ids or numbers; empty to finish): " wave_line
    wave_line="${wave_line:-}"
    if [[ -z "$wave_line" ]]; then
      break
    fi
    if [[ "$wave_line" =~ ^[Nn][Oo][Nn][Ee]$ ]]; then
      parallel_stage_waves=()
      parallel_stages_enabled="false"
      break
    fi

    local normalized candidate is_valid already_added
    local parsed_wave=()
    normalized="$(printf '%s' "$wave_line" | tr ',' ' ')"
    local tokens=()
    IFS=' ' read -r -a tokens <<< "$normalized"
    for token in "${tokens[@]-}"; do
      token="$(printf '%s' "$token" | tr -d '[:space:]')"
      [[ -n "$token" ]] || continue
      if [[ "$token" =~ ^[0-9]+$ ]] && (( token >= 1 && token <= ${#stage_ids[@]} )); then
        candidate="${stage_ids[$((token - 1))]}"
      else
        candidate="$(ralph_internal_wizard_sanitize "$token")"
      fi
      [[ -n "$candidate" ]] || continue
      is_valid=0
      for stage_opt in "${stage_ids[@]}"; do
        if [[ "$candidate" == "$stage_opt" ]]; then
          is_valid=1
          break
        fi
      done
      if (( is_valid == 0 )); then
        echo "Ignoring unknown stage id \"$candidate\" in wave." >&2
        continue
      fi
      already_added=0
      for existing in "${parsed_wave[@]-}"; do
        if [[ "$existing" == "$candidate" ]]; then
          already_added=1
          break
        fi
      done
      (( already_added == 0 )) && parsed_wave+=("$candidate")
    done

    if (( ${#parsed_wave[@]} == 0 )); then
      echo "Wave is empty after parsing; try again." >&2
      continue
    fi

    parallel_stage_waves+=("$(IFS=,; printf '%s' "${parsed_wave[*]}")")
  done

  if [[ "$parallel_stages_enabled" != "true" ]]; then
    return 0
  fi

  if (( ${#parallel_stage_waves[@]} == 0 )); then
    echo "Parallel waves enabled but none were provided; disabling." >&2
    parallel_stages_enabled="false"
    return 0
  fi

  local seen_ids=()
  local wave ids id already_seen
  for wave in "${parallel_stage_waves[@]}"; do
    IFS=',' read -r -a ids <<< "$wave"
    for id in "${ids[@]-}"; do
      already_seen=0
      for existing_id in "${seen_ids[@]-}"; do
        if [[ "$existing_id" == "$id" ]]; then
          already_seen=1
          break
        fi
      done
      if (( already_seen == 1 )); then
        ralph_die "Stage \"$id\" appears in parallel waves more than once."
      fi
      seen_ids+=("$id")
    done
  done

  for id in "${stage_ids[@]}"; do
    already_seen=0
    for existing_id in "${seen_ids[@]-}"; do
      if [[ "$existing_id" == "$id" ]]; then
        already_seen=1
        break
      fi
    done
    (( already_seen == 1 )) || ralph_die "Parallel waves must include every stage exactly once; missing \"$id\"."
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
