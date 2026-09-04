#!/usr/bin/env bash
#
# Skill package validation helpers (sourced by sync-runtime-assets.sh).
#
# Public interface:
#   ralph_skill_package_validation_enabled -- rollout gate for package validation.
#   ralph_skill_package_py -- resolve skill_package.py path.
#   ralph_validate_skill_package -- validate canonical skill package; exits non-zero on failure.
#   ralph_validate_agent_version -- validate optional agent version frontmatter.
#   ralph_claude_native_skill_layout -- true when Claude should receive native Skill layout.
#   ralph_runtime_supports_skill_resources -- true when runtime copies scripts/resources.

if [[ -n "${RALPH_SKILL_PACKAGE_SH_LOADED:-}" ]]; then
  return 0
fi
RALPH_SKILL_PACKAGE_SH_LOADED=1

if ! declare -F ralph_warn >/dev/null 2>&1; then
  _skill_pkg_lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  # shellcheck source=/dev/null
  source "$_skill_pkg_lib_dir/error-handling.sh"
fi

ralph_skill_package_validation_enabled() {
  local gate="${RALPH_SKILL_PACKAGE_VALIDATION:-}"
  if [[ -n "$gate" ]]; then
    case "$gate" in
      0) return 1 ;;
      1) return 0 ;;
      *)
        ralph_warn "RALPH_SKILL_PACKAGE_VALIDATION: invalid value '$gate' (use 0 or 1)"
        return 2
        ;;
    esac
  fi
  case "${RALPH_MODE:-no}" in
    ralph | hybrid) return 0 ;;
    *) return 1 ;;
  esac
}

ralph_skill_package_py() {
  local candidate=""
  for candidate in \
    "${RALPH_ACTIVE_DIR:-}/python/skill_package.py" \
    "${RALPH_DIR:-}/python/skill_package.py" \
    "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/python/skill_package.py"; do
    if [[ -n "$candidate" && -f "$candidate" ]]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done
  ralph_warn "skill package validator not found under Ralph python helpers"
  return 1
}

ralph_validate_skill_package() {
  local package_dir="$1"
  local skill_id="$2"
  if ! ralph_skill_package_validation_enabled; then
    return 0
  fi
  if ! command -v python3 >/dev/null 2>&1; then
    ralph_warn "skill package validation requires python3"
    return 1
  fi
  local py_script
  py_script="$(ralph_skill_package_py)" || return 1
  python3 "$py_script" validate --package-dir "$package_dir" --skill-id "$skill_id"
}

ralph_validate_agent_version() {
  local agent_file="$1"
  local agent_id="${2:-}"
  if ! ralph_skill_package_validation_enabled; then
    return 0
  fi
  if ! command -v python3 >/dev/null 2>&1; then
    ralph_warn "agent version validation requires python3"
    return 1
  fi
  local py_script
  py_script="$(ralph_skill_package_py)" || return 1
  if [[ -n "$agent_id" ]]; then
    python3 "$py_script" validate-agent --agent-file "$agent_file" --agent-id "$agent_id"
  else
    python3 "$py_script" validate-agent --agent-file "$agent_file"
  fi
}

ralph_claude_native_skill_layout() {
  local layer="$1"
  local gate="${RALPH_CLAUDE_NATIVE_SKILLS:-}"
  if [[ -n "$gate" ]]; then
    case "$gate" in
      0) return 1 ;;
      1) return 0 ;;
      *)
        ralph_warn "RALPH_CLAUDE_NATIVE_SKILLS: invalid value '$gate' (use 0 or 1)"
        return 2
        ;;
    esac
  fi
  local prefix=""
  if [[ "$layer" == "bundle" ]]; then
    prefix="bundle/"
  fi
  local claude_root="${REPO_ROOT:-.}/${prefix}.claude"
  [[ -d "$claude_root" ]] || return 1
  local settings="$claude_root/settings.json"
  if [[ -f "$settings" ]] && command -v python3 >/dev/null 2>&1; then
    python3 -c "
import json, sys
path = sys.argv[1]
try:
    with open(path, encoding='utf-8') as handle:
        data = json.load(handle)
except Exception:
    sys.exit(0)
for key in ('skills', 'enableSkills', 'skillsEnabled'):
    value = data.get(key)
    if value is False:
        sys.exit(1)
sys.exit(0)
" "$settings"
    return $?
  fi
  return 0
}

ralph_runtime_supports_skill_resources() {
  local runtime="$1"
  case "$runtime" in
    claude | cursor | opencode | antigravity) return 0 ;;
    *) return 1 ;;
  esac
}
