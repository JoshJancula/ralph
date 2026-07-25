#!/usr/bin/env bash
#
# Ralph canonical .md adapter -- parses a canonical agent .md, resolves
# models.<runtime> to a scalar model string, maps bare rule tokens to
# runtime rule paths, and renders a normalized config.json into a per-run
# cache under .ralph-workspace/artifacts/<ns>/agent-cache/<name>.config.json.
#
# The rendered config.json is byte-identical to what sync-runtime-assets.sh
# compiles for the same agent+runtime+layer combination.
#
# Public interface:
#   agent_adapter_ralph_md_resolve <name> <runtime> <workspace>
#     Prints "ralph-md<TAB><path>" and exits 0.
#
#   agent_adapter_ralph_md_to_config_json <name> <runtime> <workspace> <cache_dir> [<layer> [<canonical_rel>]]
#     Parses the canonical .md, resolves model/rules/skills, and writes
#     <cache_dir>/<name>.config.json.  Prints the cache path and exits 0.
#     <layer> defaults to "bundle"; <canonical_rel> defaults to
#     bundle/.ralph/agents/<name>.md.

if [[ -n "${RALPH_ADAPTER_RALPH_MD_LOADED:-}" ]]; then
  return 0
fi
RALPH_ADAPTER_RALPH_MD_LOADED=1

_agent_source_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# shellcheck source=/dev/null
source "$_agent_source_dir/frontmatter.sh"

_agent_ralph_md_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$_agent_ralph_md_dir/../../runtime-normalize.sh"

# Provide a JSON-output helper for mcp_servers.
# frontmatter.sh exposes agent_source_fm_mcp_servers when python3 is available.
_agent_ralph_md_mcp_json() {
  local file="$1"
  local out=""
  out="$(agent_source_fm_mcp_servers "$file" 2>/dev/null || true)"
  printf '%s\n' "$out"
}

agent_adapter_ralph_md_resolve() {
  local name="${1:-}"
  local runtime="${2:-}"
  local workspace="${3:-}"

  if [[ -z "$name" || -z "$runtime" || -z "$workspace" ]]; then
    echo "Error: name, runtime, and workspace are required" >&2
    return 2
  fi

  local candidate
  for candidate in \
    "$workspace/.ralph-workspace/agents/$name.md" \
    "$workspace/.ralph/agents/$name.md" \
    "${RALPH_HOME:-$HOME/.ralph}/bundle/.ralph/agents/$name.md"; do
    if [[ -r "$candidate" ]]; then
      printf 'ralph-md\t%s\n' "$candidate"
      return 0
    fi
  done

  echo "Error: no ralph-md source found for '$name' (runtime=$runtime)" >&2
  return 1
}

_agent_adapter_rule_dest_basename() {
  local runtime="$1"
  local rule_name="$2"
  local base="${rule_name%.md}"
  if [[ "$runtime" == "cursor" ]]; then
    printf '%s.mdc\n' "$base"
  else
    printf '%s.md\n' "$base"
  fi
}

_agent_adapter_rule_path() {
  local layer="$1"
  local runtime="$2"
  local rule_name="$3"
  local prefix runtime_dir
  if [[ "$layer" == "root" ]]; then
    prefix=""
  else
    prefix="bundle/"
  fi
  runtime_dir="$(ralph_runtime_config_dirname "$runtime")"
  printf '%s%s/rules/%s\n' "$prefix" "$runtime_dir" "$(_agent_adapter_rule_dest_basename "$runtime" "$rule_name")"
}

_agent_adapter_skill_path() {
  local layer="$1"
  local runtime="$2"
  local skill_id="$3"
  local prefix runtime_dir
  if [[ "$layer" == "root" ]]; then
    prefix=""
  else
    prefix="bundle/"
  fi
  runtime_dir="$(ralph_runtime_config_dirname "$runtime")"
  printf '%s%s/skills/%s/SKILL.md\n' "$prefix" "$runtime_dir" "$skill_id"
}

agent_adapter_ralph_md_to_config_json() {
  local name="${1:-}"
  local runtime="${2:-}"
  local workspace="${3:-}"
  local cache_dir="${4:-}"
  local layer="${5:-bundle}"
  local canonical_rel="${6:-}"

  if [[ -z "$name" || -z "$runtime" || -z "$workspace" || -z "$cache_dir" ]]; then
    echo "Error: name, runtime, workspace, and cache_dir are required" >&2
    return 2
  fi

  runtime="$(ralph_normalize_runtime_name "$runtime")"

  local canonical_abs=""
  local found_rel=""

  if [[ -n "$canonical_rel" ]]; then
    canonical_abs="$workspace/$canonical_rel"
    found_rel="$canonical_rel"
  fi

  if [[ -z "$canonical_abs" || ! -r "$canonical_abs" ]]; then
    local default_rel
    if [[ "$layer" == "root" ]]; then
      default_rel="agents/agents/$name.md"
    else
      default_rel="bundle/.ralph/agents/$name.md"
    fi

    for candidate in \
      "$workspace/.ralph-workspace/agents/$name.md" \
      "$workspace/.ralph/agents/$name.md" \
      "$workspace/$default_rel" \
      "${RALPH_HOME:-$HOME/.ralph}/bundle/.ralph/agents/$name.md"; do
      if [[ -r "$candidate" ]]; then
        canonical_abs="$candidate"
        local real_candidate
        real_candidate="$(cd -P "$(dirname "$candidate")" && pwd -P)/$(basename "$candidate")" 2>/dev/null || real_candidate="$candidate"
        local real_workspace
        real_workspace="$(cd -P "$workspace" && pwd -P)" 2>/dev/null || real_workspace="$workspace"
        if [[ "$real_candidate" == "$real_workspace/"* ]]; then
          found_rel="${real_candidate#"$real_workspace/"}"
        else
          found_rel="$default_rel"
        fi
        break
      fi
    done
  fi

  if [[ -z "$canonical_abs" || ! -r "$canonical_abs" ]]; then
    echo "Error: no ralph-md source found for '$name'" >&2
    return 1
  fi

  if [[ -z "$found_rel" ]]; then
    if [[ "$layer" == "root" ]]; then
      found_rel="agents/agents/$name.md"
    else
      found_rel="bundle/.ralph/agents/$name.md"
    fi
  fi

  local description model max_budget reasoning_effort version rules skills artifacts allowed_tools mcp_servers
  description="$(agent_source_fm_scalar "$canonical_abs" "description")"
  model="$(agent_source_fm_model "$canonical_abs" "$runtime")"
  max_budget="$(agent_source_fm_scalar "$canonical_abs" "max_budget_usd")"
  reasoning_effort="$(agent_source_fm_scalar "$canonical_abs" "reasoning_effort")"
  version="$(agent_source_fm_scalar "$canonical_abs" "version")"

  local list_key="rules"
  if [[ "$runtime" == "antigravity" ]]; then
    if [[ -n "$(agent_source_fm_list "$canonical_abs" "rules_antigravity" | head -1)" ]]; then
      list_key="rules_antigravity"
    fi
  fi
  rules="$(agent_source_fm_list "$canonical_abs" "$list_key")"
  skills="$(agent_source_fm_list "$canonical_abs" "skills")"
  artifacts="$(agent_source_fm_list "$canonical_abs" "output_artifacts")"
  allowed_tools="$(agent_source_fm_list "$canonical_abs" "allowed_tools")"
  mcp_servers="$(agent_source_fm_mcp_servers "$canonical_abs")"

  local dest
  mkdir -p "$cache_dir"
  dest="$cache_dir/$name.config.json"

  {
    printf '{\n'
    printf '  "name": %s,\n' "$(agent_source_json_string "$name")"
    printf '  "_generated": %s,\n' "$(agent_source_json_string "GENERATED from $found_rel by scripts/sync-runtime-assets.sh - edit the canonical file")"
    printf '  "model": %s,\n' "$(agent_source_json_string "$model")"
    if [[ -n "$max_budget" ]]; then
      printf '  "max_budget_usd": %s,\n' "$(agent_source_json_string "$max_budget")"
    fi
    if [[ -n "$reasoning_effort" ]]; then
      printf '  "reasoning_effort": %s,\n' "$(agent_source_json_string "$reasoning_effort")"
    fi
    if [[ -n "$version" ]]; then
      printf '  "version": %s,\n' "$(agent_source_json_string "$version")"
    fi
    printf '  "description": %s,\n' "$(agent_source_json_string "$description")"
    printf '  "rules": [\n'
    local first=1 rule
    while IFS= read -r rule; do
      [[ -n "$rule" ]] || continue
      if [[ "$first" -eq 0 ]]; then
        printf ',\n'
      fi
      printf '    %s' "$(agent_source_json_string "$(_agent_adapter_rule_path "$layer" "$runtime" "$rule")")"
      first=0
    done <<< "$rules"
    if [[ "$first" -eq 1 ]]; then
      :
    fi
    printf '\n  ],\n'
    printf '  "skills": [\n'
    first=1
    local skill
    while IFS= read -r skill; do
      [[ -n "$skill" ]] || continue
      if [[ "$first" -eq 0 ]]; then
        printf ',\n'
      fi
      printf '    %s' "$(agent_source_json_string "$(_agent_adapter_skill_path "$layer" "$runtime" "$skill")")"
      first=0
    done <<< "$skills"
    printf '\n  ]'
    if [[ -n "$allowed_tools" ]]; then
      printf ',\n  "allowed_tools": [\n'
      first=1
      local tool
      while IFS= read -r tool; do
        [[ -n "$tool" ]] || continue
        if [[ "$first" -eq 0 ]]; then
          printf ',\n'
        fi
        printf '    %s' "$(agent_source_json_string "$tool")"
        first=0
      done <<< "$allowed_tools"
      printf '\n  ]'
    fi
    if [[ -n "$artifacts" ]]; then
      printf ',\n  "output_artifacts": [\n'
      first=1
      local artifact
      while IFS= read -r artifact; do
        [[ -n "$artifact" ]] || continue
        if [[ "$first" -eq 0 ]]; then
          printf ',\n'
        fi
        printf '    %s' "$(agent_source_fm_artifact "$artifact")"
        first=0
      done <<< "$artifacts"
      printf '\n  ]'
    fi
    if [[ -n "$mcp_servers" ]]; then
      printf ',\n  "mcp_servers": [\n'
      first=1
      local entry
      while IFS= read -r entry; do
        [[ -n "$entry" ]] || continue
        if [[ "$first" -eq 0 ]]; then
          printf ',\n'
        fi
        printf '    %s' "$entry"
        first=0
      done <<< "$mcp_servers"
      printf '\n  ]'
    fi
    printf '\n}\n'
  } > "$dest"

  printf '%s\n' "$dest"
}