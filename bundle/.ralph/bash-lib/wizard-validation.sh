#!/usr/bin/env bash
#
# Validation helpers used by the orchestration wizard.
#
# Public interface:
#   configure_stage_input_dependencies -- interactive inputArtifacts wiring between stages.
#   configure_loop_rules -- loopControl defaults for review stages.

configure_stage_input_dependencies() {
  stage_input_sources=()
  print_step "4/6" "Stage input dependencies"
  print_info "Choose stage inputs (writes to: inputArtifacts in the JSON)"
  print_hint "- Use this so a stage knows which earlier artifacts to read."
  print_hint "- This is how one agent uses output from a previous agent."
  print_hint "- Example: plan stage artifacts -> implementation stage."
  print_hint "- Example: implementation artifacts -> qa or code-review stage."
  print_hint "- Type numbers or stage names, with commas or spaces."
  print_hint "- Type 'none' for no handoff, or Enter for the default."

  read -rp "Set custom stage inputs? (inputArtifacts) [y/N]: " handoff_choice
  if [[ "$handoff_choice" =~ ^[Yy] ]]; then
    print_info "Available stages for stage inputs (inputArtifacts)"
    for idx in "${!stage_ids[@]}"; do
      printf '  %2d) %s\n' "$((idx + 1))" "${stage_ids[$idx]}"
    done
    print_hint "Type numbers or stage names. Commas and spaces both work."
    for idx in "${!stage_ids[@]}"; do
      local current_stage default_input input_line normalized_input raw_inputs candidate is_valid already_added
      current_stage="${stage_ids[$idx]}"
      default_input=""
      if (( idx > 0 )); then
        default_input="${stage_ids[$((idx - 1))]}"
      fi
      read -rp "Which earlier stages should \"$current_stage\" read from? (inputArtifacts${default_input:+, default $default_input}; use 'none' for no input): " input_line
      if [[ -z "$input_line" ]]; then
        input_line="$default_input"
      fi
      local parsed_inputs=()
      normalized_input="$(printf '%s' "$input_line" | tr ',' ' ')"
      if [[ -n "$normalized_input" ]]; then
        IFS=' ' read -r -a raw_inputs <<< "$normalized_input"
        for raw_input in "${raw_inputs[@]-}"; do
          raw_input="$(printf '%s' "$raw_input" | tr -d '[:space:]')"
          if [[ "$raw_input" =~ ^[0-9]+$ ]] && (( raw_input >= 1 && raw_input <= ${#stage_ids[@]} )); then
            candidate="${stage_ids[$((raw_input - 1))]}"
          else
            candidate="$(ralph_internal_wizard_sanitize "$raw_input")"
          fi
          [[ -n "$candidate" ]] || continue
          if [[ "$candidate" == "none" || "$candidate" == "no-input" || "$candidate" == "no-inputs" ]]; then
            parsed_inputs=()
            break
          fi
          if [[ "$candidate" == "$current_stage" ]]; then
            echo "Ignoring self-reference for $current_stage in inputArtifacts." >&2
            continue
          fi
          is_valid=0
          for stage_opt in "${stage_ids[@]}"; do
            if [[ "$candidate" == "$stage_opt" ]]; then
              is_valid=1
              break
            fi
          done
          if (( is_valid == 1 )); then
            already_added=0
            for existing in "${parsed_inputs[@]-}"; do
              if [[ "$existing" == "$candidate" ]]; then
                already_added=1
                break
              fi
            done
            (( already_added == 0 )) && parsed_inputs+=("$candidate")
          else
            echo "Ignoring unknown stage id \"$candidate\" for $current_stage input mapping." >&2
          fi
        done
      fi
      if [[ ${#parsed_inputs[@]} -gt 0 ]]; then
        stage_input_sources+=("$(IFS=,; printf '%s' "${parsed_inputs[*]}")")
      else
        stage_input_sources+=("")
      fi
    done
  else
    for idx in "${!stage_ids[@]}"; do
      if (( idx == 0 )); then
        stage_input_sources+=("")
      else
        stage_input_sources+=("${stage_ids[$((idx - 1))]}")
      fi
    done
  fi
}

configure_loop_rules() {
  loop_sources=()
  loop_targets=()
  loop_max_iterations=()
  print_step "5/6" "Optional loop rules"
  print_hint "- Use loop rules for review/testing stages that may find issues."
  print_hint "- If a review/test stage finds a problem, it can send work back."
  print_hint "- If review/test says everything is good, pipeline moves forward."
  print_hint "- This writes to loopControl (loopBackTo + maxIterations) in JSON."
  print_hint "- You can set loops quickly with a list, or go stage-by-stage."
  print_hint "- Quick list examples: 2,4 or review,qa (choose loop source stages)."
  print_hint "- Then pick where each source stage should send work back."
  print_hint "- In loop prompts, Enter (or 0/none) means no loop."

  read -rp "Add loop rules? (loopControl) [y/N]: " loop_choice
  if [[ "$loop_choice" =~ ^[Yy] ]]; then
    print_info "Loop setup mode (loopControl)"
    print_hint "1) Pick source stages in one line, then configure each picked stage."
    print_hint "2) Walk every stage one-by-one and choose loop targets."
    read -rp "Choose mode [2]: " loop_mode
    loop_mode="${loop_mode:-2}"
    if [[ "$loop_mode" == "1" ]]; then
      echo "Available stages for loop sources:" >&2
      for idx in "${!stage_ids[@]}"; do
        printf '  %2d) %s\n' "$((idx + 1))" "${stage_ids[$idx]}" >&2
      done
      read -rp "Stages that should loop (numbers/names, comma or space; Enter/none for no loops): " loop_sources_line
      loop_sources_line="${loop_sources_line:-none}"
      local normalized_sources source_tokens source_token source_stage is_valid already_added
      normalized_sources="$(printf '%s' "$loop_sources_line" | tr ',' ' ')"
      local selected_loop_sources=()
      IFS=' ' read -r -a source_tokens <<< "$normalized_sources"
      for source_token in "${source_tokens[@]-}"; do
        source_token="$(printf '%s' "$source_token" | tr -d '[:space:]')"
        [[ -n "$source_token" ]] || continue
        if [[ "$source_token" =~ ^[Nn][Oo][Nn][Ee]$ ]]; then
          selected_loop_sources=()
          break
        fi
        if [[ "$source_token" =~ ^[0-9]+$ ]] && (( source_token >= 1 && source_token <= ${#stage_ids[@]} )); then
          source_stage="${stage_ids[$((source_token - 1))]}"
        else
          source_stage="$(ralph_internal_wizard_sanitize "$source_token")"
        fi
        is_valid=0
        for stage_opt in "${stage_ids[@]}"; do
          if [[ "$source_stage" == "$stage_opt" ]]; then
            is_valid=1
            break
          fi
        done
        if (( is_valid == 0 )); then
          echo "Ignoring unknown loop source \"$source_token\"." >&2
          continue
        fi
        already_added=0
        for existing_source in "${selected_loop_sources[@]-}"; do
          if [[ "$existing_source" == "$source_stage" ]]; then
            already_added=1
            break
          fi
        done
        (( already_added == 0 )) && selected_loop_sources+=("$source_stage")
      done

      for loop_stage in "${selected_loop_sources[@]-}"; do
        echo "" >&2
        local loop_back loop_iterations_input loop_iterations
        loop_back="$(choose_stage_id_from_list "Send \"$loop_stage\" back to which stage? (loopBackTo, number/id, Enter for none): " 1 "${stage_ids[@]}")"
        if [[ -z "$loop_back" ]]; then
          echo "No loop target set for $loop_stage. Skipping this loop rule." >&2
          continue
        fi
        read -rp "Max iterations for \"$loop_stage\" [default 2]: " loop_iterations_input
        loop_iterations="${loop_iterations_input:-2}"
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
        local loop_back loop_iterations_input loop_iterations
        loop_back="$(choose_stage_id_from_list "Send \"$loop_stage\" back to which stage? (loopBackTo, number/id, Enter for none): " 1 "${stage_ids[@]}")"
        if [[ -z "$loop_back" ]]; then
          continue
        fi
        read -rp "Max iterations for \"$loop_stage\" [default 2]: " loop_iterations_input
        loop_iterations="${loop_iterations_input:-2}"
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
