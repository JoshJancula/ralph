#!/usr/bin/env bash
#
# Markdown context for run-plan when using a prebuilt agent (sourced by agent-config-tool.sh).
#
# Public interface:
#   context_block -- emits agent summary, rules list or compact rule paths, skills, output artifacts.

context_block() {
  local agents_root="$1" agent_id="$2" workspace="$3"
  local cfg
  cfg="$(load_cfg_path "$agents_root" "$agent_id")"
  validate_config "$agents_root" "$agent_id" >/dev/null

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
      inline_rule_file "$workspace" "$rule"
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
  required_artifacts "$agents_root" "$agent_id" | while IFS= read -r a; do
    [[ -n "$a" ]] && echo "  - \`$a\`"
  done
  echo ""
  echo "**Agent config:** \`$cfg\` (validated)."
}
