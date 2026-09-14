#!/usr/bin/env bash
# Pure workflow resource resolver (project / global / bundled).
#
# Call workflow_resource_init with explicit absolute-or-relative roots once.
# After init, all lookups use the stored roots only -- no cwd, no edits,
# no prompts, no materialization.
#
# Precedence (implicit lookup): project -> global -> bundled.
# RALPH_DISABLE_GLOBAL_FALLBACK=1 skips global on implicit lookup only.
# Explicit scoped lookup never falls through.
#
# Paths:
#   project  -> <state-root>/workflows/<id>.workflow.md
#   global   -> <ralph-home>/workflows/<id>.workflow.md
#   bundled  -> <bundle-root>/.ralph/workflows/<id>.workflow.md

if [[ -n "${RALPH_WORKFLOW_RESOURCE_LOADED:-}" ]]; then
  return 0
fi
RALPH_WORKFLOW_RESOURCE_LOADED=1

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  echo "This file is meant to be sourced, not executed." >&2
  exit 1
fi

_WORKFLOW_RESOURCE_INITIALIZED=0
_WORKFLOW_RESOURCE_PROJECT_ROOT=""
_WORKFLOW_RESOURCE_STATE_ROOT=""
_WORKFLOW_RESOURCE_RALPH_HOME=""
_WORKFLOW_RESOURCE_BUNDLE_ROOT=""

# Absolutize a path once at init. Relative inputs are resolved against the
# caller's cwd only here; later helpers never call pwd.
_workflow_resource_abs_path() {
  local path="${1:-}"
  local parent base abs_parent

  [[ -n "$path" ]] || return 1
  path="${path%/}"
  if [[ "$path" != /* ]]; then
    path="$(pwd -P)/$path"
  fi

  parent="$(dirname -- "$path")"
  base="$(basename -- "$path")"
  if [[ -d "$parent" ]]; then
    abs_parent="$(cd -- "$parent" && pwd -P)" || return 1
    printf '%s/%s\n' "$abs_parent" "$base"
  else
    # Parent may not exist yet (tests / fresh installs). Keep a cleaned abs form.
    printf '%s\n' "$path"
  fi
}

# Physical path for an existing file (follows symlinks). Used only for de-dup.
_workflow_resource_physical_path() {
  local path="${1:-}"
  [[ -n "$path" && -e "$path" ]] || return 1

  if command -v python3 >/dev/null 2>&1; then
    python3 -c 'import os, sys; print(os.path.realpath(sys.argv[1]))' "$path" 2>/dev/null && return 0
  fi
  if command -v realpath >/dev/null 2>&1; then
    realpath "$path" 2>/dev/null && return 0
  fi

  local parent base abs_parent
  parent="$(dirname -- "$path")"
  base="$(basename -- "$path")"
  abs_parent="$(cd -- "$parent" && pwd -P)" || return 1
  if [[ -L "$path" ]]; then
    local target
    target="$(readlink "$path" 2>/dev/null || true)"
    if [[ -n "$target" ]]; then
      if [[ "$target" != /* ]]; then
        target="$abs_parent/$target"
      fi
      _workflow_resource_physical_path "$target"
      return $?
    fi
  fi
  printf '%s/%s\n' "$abs_parent" "$base"
}

_workflow_resource_require_init() {
  if [[ "$_WORKFLOW_RESOURCE_INITIALIZED" != "1" ]]; then
    echo "Error: workflow_resource_init must be called before workflow resource lookup." >&2
    return 1
  fi
}

# workflow_resource_init <project_root> <state_root> <ralph_home> <bundle_root>
workflow_resource_init() {
  local project_root="${1:-}"
  local state_root="${2:-}"
  local ralph_home="${3:-}"
  local bundle_root="${4:-}"

  if [[ -z "$project_root" || -z "$state_root" || -z "$ralph_home" || -z "$bundle_root" ]]; then
    echo "Error: workflow_resource_init requires project_root, state_root, ralph_home, and bundle_root." >&2
    return 2
  fi

  _WORKFLOW_RESOURCE_PROJECT_ROOT="$(_workflow_resource_abs_path "$project_root")" || return 1
  _WORKFLOW_RESOURCE_STATE_ROOT="$(_workflow_resource_abs_path "$state_root")" || return 1
  _WORKFLOW_RESOURCE_RALPH_HOME="$(_workflow_resource_abs_path "$ralph_home")" || return 1
  _WORKFLOW_RESOURCE_BUNDLE_ROOT="$(_workflow_resource_abs_path "$bundle_root")" || return 1
  _WORKFLOW_RESOURCE_INITIALIZED=1
  return 0
}

workflow_resource_project_root() {
  _workflow_resource_require_init || return 1
  printf '%s\n' "$_WORKFLOW_RESOURCE_PROJECT_ROOT"
}

workflow_resource_state_root() {
  _workflow_resource_require_init || return 1
  printf '%s\n' "$_WORKFLOW_RESOURCE_STATE_ROOT"
}

workflow_resource_ralph_home() {
  _workflow_resource_require_init || return 1
  printf '%s\n' "$_WORKFLOW_RESOURCE_RALPH_HOME"
}

workflow_resource_bundle_root() {
  _workflow_resource_require_init || return 1
  printf '%s\n' "$_WORKFLOW_RESOURCE_BUNDLE_ROOT"
}

workflow_resource_project_dir() {
  _workflow_resource_require_init || return 1
  printf '%s/workflows\n' "$_WORKFLOW_RESOURCE_STATE_ROOT"
}

workflow_resource_global_dir() {
  _workflow_resource_require_init || return 1
  printf '%s/workflows\n' "$_WORKFLOW_RESOURCE_RALPH_HOME"
}

workflow_resource_bundled_dir() {
  _workflow_resource_require_init || return 1
  printf '%s/.ralph/workflows\n' "$_WORKFLOW_RESOURCE_BUNDLE_ROOT"
}

# Exit 0 when id matches ^[a-z0-9]+(-[a-z0-9]+)*$
workflow_resource_id_valid() {
  local id="${1:-}"
  [[ -n "$id" && "$id" =~ ^[a-z0-9]+(-[a-z0-9]+)*$ ]]
}

workflow_resource_scope_valid() {
  case "${1:-}" in
    project|global|bundled) return 0 ;;
    *) return 1 ;;
  esac
}

# Print absolute candidate path for id + scope (file need not exist).
workflow_resource_candidate_path() {
  local id="${1:-}"
  local scope="${2:-}"
  local dir

  _workflow_resource_require_init || return 1
  workflow_resource_id_valid "$id" || {
    echo "Error: invalid workflow id: ${id:-<empty>}" >&2
    return 2
  }
  workflow_resource_scope_valid "$scope" || {
    echo "Error: invalid workflow scope: ${scope:-<empty>}" >&2
    return 2
  }

  case "$scope" in
    project) dir="$(workflow_resource_project_dir)" ;;
    global) dir="$(workflow_resource_global_dir)" ;;
    bundled) dir="$(workflow_resource_bundled_dir)" ;;
  esac
  printf '%s/%s.workflow.md\n' "$dir" "$id"
}

# Classify an absolute path as project|global|bundled by stored roots.
# Symlink targets are matched by physical path against each scope dir.
workflow_resource_source_kind() {
  local path="${1:-}"
  local physical project_dir global_dir bundled_dir
  local project_phys global_phys bundled_phys

  _workflow_resource_require_init || return 1
  [[ -n "$path" ]] || return 1

  project_dir="$(workflow_resource_project_dir)"
  global_dir="$(workflow_resource_global_dir)"
  bundled_dir="$(workflow_resource_bundled_dir)"

  if [[ -e "$path" ]]; then
    physical="$(_workflow_resource_physical_path "$path")" || physical="$path"
  else
    physical="$path"
  fi

  if [[ -d "$project_dir" ]]; then
    project_phys="$(_workflow_resource_physical_path "$project_dir" 2>/dev/null || printf '%s' "$project_dir")"
  else
    project_phys="$project_dir"
  fi
  if [[ -d "$global_dir" ]]; then
    global_phys="$(_workflow_resource_physical_path "$global_dir" 2>/dev/null || printf '%s' "$global_dir")"
  else
    global_phys="$global_dir"
  fi
  if [[ -d "$bundled_dir" ]]; then
    bundled_phys="$(_workflow_resource_physical_path "$bundled_dir" 2>/dev/null || printf '%s' "$bundled_dir")"
  else
    bundled_phys="$bundled_dir"
  fi

  case "$physical" in
    "$project_phys"/*|"$project_dir"/*) printf 'project\n'; return 0 ;;
  esac
  case "$path" in
    "$project_dir"/*) printf 'project\n'; return 0 ;;
  esac
  case "$physical" in
    "$global_phys"/*|"$global_dir"/*) printf 'global\n'; return 0 ;;
  esac
  case "$path" in
    "$global_dir"/*) printf 'global\n'; return 0 ;;
  esac
  case "$physical" in
    "$bundled_phys"/*|"$bundled_dir"/*) printf 'bundled\n'; return 0 ;;
  esac
  case "$path" in
    "$bundled_dir"/*) printf 'bundled\n'; return 0 ;;
  esac
  return 1
}

_workflow_resource_file_exists() {
  local path="${1:-}"
  [[ -n "$path" && -f "$path" ]]
}

# Resolve id. Optional scope: project|global|bundled (no fallthrough).
# Without scope: project -> global (unless RALPH_DISABLE_GLOBAL_FALLBACK=1) -> bundled.
# Prints: <kind>\t<absolute-path>
workflow_resource_resolve() {
  local id="${1:-}"
  local scope="${2:-}"
  local path kind

  _workflow_resource_require_init || return 1
  workflow_resource_id_valid "$id" || {
    echo "Error: invalid workflow id: ${id:-<empty>}" >&2
    return 2
  }

  if [[ -n "$scope" ]]; then
    workflow_resource_scope_valid "$scope" || {
      echo "Error: invalid workflow scope: $scope" >&2
      return 2
    }
    path="$(workflow_resource_candidate_path "$id" "$scope")" || return $?
    if _workflow_resource_file_exists "$path"; then
      printf '%s\t%s\n' "$scope" "$path"
      return 0
    fi
    return 1
  fi

  for kind in project global bundled; do
    if [[ "$kind" == "global" && "${RALPH_DISABLE_GLOBAL_FALLBACK:-0}" == "1" ]]; then
      continue
    fi
    path="$(workflow_resource_candidate_path "$id" "$kind")" || return $?
    if _workflow_resource_file_exists "$path"; then
      printf '%s\t%s\n' "$kind" "$path"
      return 0
    fi
  done
  return 1
}

# Sorted winning enumeration: one row per logical id (and per unique physical
# path). Format: <id>\t<kind>\t<absolute-path>
# Higher-precedence scopes win; symlink duplicates of an already-listed
# physical path are skipped.
workflow_resource_list_winning() {
  local -a kinds=()
  local kind dir file base id path physical
  local -A seen_ids=()
  local -A seen_physical=()
  local -a rows=()
  local row

  _workflow_resource_require_init || return 1

  kinds=(project)
  if [[ "${RALPH_DISABLE_GLOBAL_FALLBACK:-0}" != "1" ]]; then
    kinds+=(global)
  fi
  kinds+=(bundled)

  for kind in "${kinds[@]}"; do
    case "$kind" in
      project) dir="$(workflow_resource_project_dir)" ;;
      global) dir="$(workflow_resource_global_dir)" ;;
      bundled) dir="$(workflow_resource_bundled_dir)" ;;
    esac
    [[ -d "$dir" ]] || continue

    # Null-delimited so spaces in roots are safe; sort for stable discovery.
    while IFS= read -r -d '' file; do
      base="$(basename -- "$file")"
      [[ "$base" == *.workflow.md ]] || continue
      id="${base%.workflow.md}"
      workflow_resource_id_valid "$id" || continue

      if [[ -n "${seen_ids[$id]:-}" ]]; then
        continue
      fi

      physical="$(_workflow_resource_physical_path "$file" 2>/dev/null || printf '%s' "$file")"
      if [[ -n "${seen_physical[$physical]:-}" ]]; then
        continue
      fi

      path="$file"
      # Prefer the canonical candidate path (absolute, no /./ noise).
      path="$(workflow_resource_candidate_path "$id" "$kind")" || path="$file"
      # If the candidate is a different symlink path to the same file, still
      # report the path that exists at this scope.
      if ! _workflow_resource_file_exists "$path"; then
        path="$file"
        if [[ "$path" != /* ]]; then
          path="$dir/$base"
        fi
      fi

      seen_ids["$id"]=1
      seen_physical["$physical"]=1
      rows+=("$id"$'\t'"$kind"$'\t'"$path")
    done < <(find "$dir" -maxdepth 1 \( -type f -o -type l \) -name '*.workflow.md' -print0 2>/dev/null \
      | sort -z)
  done

  if [[ ${#rows[@]} -eq 0 ]]; then
    return 0
  fi
  # Sort by id (field 1).
  printf '%s\n' "${rows[@]}" | LC_ALL=C sort -t $'\t' -k1,1
}
