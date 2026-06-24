#!/usr/bin/env bash
#
# Markdown context for run-plan when using a prebuilt agent (sourced by agent-config-tool.sh).
#
# Public interface:
#   progressive_context_enabled -- rollout gate for RALPH_PROGRESSIVE_CONTEXT.
#   context_block -- emits agent summary, rules list or compact rule paths, skills, output artifacts.
#   context_block_progressive -- stable/volatile split via progressive_context.py.

progressive_context_enabled() {
  local gate="${RALPH_PROGRESSIVE_CONTEXT:-}"
  if [[ -n "$gate" ]]; then
    case "$gate" in
      0) return 1 ;;
      1) return 0 ;;
      *)
        echo "RALPH_PROGRESSIVE_CONTEXT: invalid value '$gate' (use 0 or 1)" >&2
        return 2
        ;;
    esac
  fi
  case "${RALPH_MODE:-no}" in
    ralph|hybrid) return 0 ;;
    *) return 1 ;;
  esac
}

_progressive_context_py() {
  local script_dir="${1:-}"
  if [[ -n "$script_dir" && -f "$script_dir/python/progressive_context.py" ]]; then
    printf '%s/python/progressive_context.py' "$script_dir"
    return 0
  fi
  if [[ -n "${BASH_SOURCE[1]:-}" ]]; then
    local root
    root="$(cd "$(dirname "${BASH_SOURCE[1]}")/../.." && pwd)"
    if [[ -f "$root/python/progressive_context.py" ]]; then
      printf '%s/python/progressive_context.py' "$root"
      return 0
    fi
  fi
  return 1
}

context_block_progressive() {
  local agents_root="$1" agent_id="$2" workspace="$3"
  local cfg part todo_text stage_desc compact_mode py_script result stable volatile
  cfg="$(load_cfg_path "$agents_root" "$agent_id")"
  validate_config "$agents_root" "$agent_id" >/dev/null

  part="${RALPH_PROGRESSIVE_CONTEXT_PART:-all}"
  todo_text="${RALPH_PROGRESSIVE_TODO_TEXT:-}"
  stage_desc="${RALPH_PROGRESSIVE_STAGE_DESC:-}"
  compact_mode="${RALPH_COMPACT_CONTEXT:-0}"

  if ! command -v python3 >/dev/null 2>&1; then
    echo "Warning: python3 unavailable; falling back to legacy full rule/skill loading" >&2
    RALPH_PROGRESSIVE_CONTEXT=0 context_block "$agents_root" "$agent_id" "$workspace"
    return 0
  fi

  py_script="$(_progressive_context_py "${script_dir:-}")" || {
    echo "Warning: progressive_context.py missing; falling back to legacy full rule/skill loading" >&2
    RALPH_PROGRESSIVE_CONTEXT=0 context_block "$agents_root" "$agent_id" "$workspace"
    return 0
  }

  local warn_file
  warn_file="$(mktemp)"
  result="$(python3 "$py_script" assemble \
    --workspace "$workspace" \
    --config-path "$cfg" \
    --agents-root "$agents_root" \
    --todo-text "$todo_text" \
    --stage-description "$stage_desc" \
    --compact-mode "$compact_mode" \
    --part "$part" \
    --progressive-context "${RALPH_PROGRESSIVE_CONTEXT:-}" \
    --ralph-mode "${RALPH_MODE:-no}" 2>"$warn_file")" || {
    if [[ -s "$warn_file" ]]; then
      cat "$warn_file" >&2
    fi
    rm -f "$warn_file"
    echo "Warning: progressive context assembly failed; falling back to legacy full rule/skill loading" >&2
    RALPH_PROGRESSIVE_CONTEXT=0 context_block "$agents_root" "$agent_id" "$workspace"
    return 0
  }
  if [[ -s "$warn_file" ]]; then
    cat "$warn_file" >&2
  fi
  rm -f "$warn_file"

  stable="$(python3 -c 'import json,sys; print(json.load(sys.stdin).get("stable",""))' <<<"$result")"
  volatile="$(python3 -c 'import json,sys; print(json.load(sys.stdin).get("volatile",""))' <<<"$result")"

  case "$part" in
    stable)
      printf '%s' "$stable"
      ;;
    volatile)
      printf '%s' "$volatile"
      return 0
      ;;
    *)
      if [[ -n "$volatile" ]]; then
        printf '%s\n\n%s' "$stable" "$volatile"
      else
        printf '%s' "$stable"
      fi
      ;;
  esac

  echo "**Declared output artifacts:**"
  local had_artifact=0
  while IFS= read -r a; do
    [[ -n "$a" ]] || continue
    had_artifact=1
    echo "  - \`$a\`"
  done < <(all_output_artifacts "$agents_root" "$agent_id")
  [[ "$had_artifact" == "1" ]] || echo "  - (none declared; see plan produces/requires)"
  echo ""
}

context_block() {
  local agents_root="$1" agent_id="$2" workspace="$3"
  local cfg
  cfg="$(load_cfg_path "$agents_root" "$agent_id")"
  validate_config "$agents_root" "$agent_id" >/dev/null

  if progressive_context_enabled; then
    RALPH_PROGRESSIVE_CONTEXT_PART="${RALPH_PROGRESSIVE_CONTEXT_PART:-all}"
    context_block_progressive "$agents_root" "$agent_id" "$workspace"
    return 0
  fi

  local name desc compact_mode
  name="$(json_string_value "$cfg" "name")"
  desc="$(json_string_value "$cfg" "description")"
  compact_mode="${RALPH_COMPACT_CONTEXT:-0}"
  echo ""
  echo "**Prebuilt agent profile**"
  echo "- **name:** $name"
  echo "- **role:** $desc"
  echo ""
  if [[ "$compact_mode" == "1" ]]; then
    echo "**Rules (read and follow; paths only):**"
  else
    echo "**Rules (read and follow; full text inlined below):**"
  fi
  local rules
  rules="$(array_block "$cfg" "rules" || true)"
  while IFS= read -r line; do
    [[ "$line" =~ ^[[:space:]]*\"([^\"]+)\"[[:space:]]*,?[[:space:]]*$ ]] || continue
    local rule="${BASH_REMATCH[1]}"
    echo "  - \`$rule\`"
  done <<< "$rules"
  echo ""
  if [[ "$compact_mode" != "1" ]]; then
    while IFS= read -r line; do
      [[ "$line" =~ ^[[:space:]]*\"([^\"]+)\"[[:space:]]*,?[[:space:]]*$ ]] || continue
      local rule="${BASH_REMATCH[1]}"
      echo "--- Rule file: \`$rule\` ---"
      inline_rule_file "$workspace" "$rule" "$agents_root"
      echo ""
    done <<< "$rules"
  fi

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
  local had_artifact=0
  while IFS= read -r a; do
    [[ -n "$a" ]] || continue
    had_artifact=1
    echo "  - \`$a\`"
  done < <(all_output_artifacts "$agents_root" "$agent_id")
  [[ "$had_artifact" == "1" ]] || echo "  - (none declared; see plan produces/requires)"
  echo ""
  echo "**Agent config:** \`$cfg\` (validated)."
}
