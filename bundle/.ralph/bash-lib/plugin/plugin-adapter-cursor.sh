#!/usr/bin/env bash
# Cursor user-scope plugin install adapter.
#
# Fixed target: $HOME/.cursor/plugins/local/ralph-orchestrator
# Install atomically copies the complete packaged tree and journals SHA-256
# digests for every file. Status compares digests; remove deletes only matching
# owned files, prunes empty dirs, and refuses modified targets. An existing
# unjournaled target is refused.
set -euo pipefail

if [[ -n "${RALPH_PLUGIN_ADAPTER_CURSOR_LOADED:-}" ]]; then
  return 0 2>/dev/null || exit 0
fi
RALPH_PLUGIN_ADAPTER_CURSOR_LOADED=1

_PLUGIN_CURSOR_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=plugin-common.sh
source "$_PLUGIN_CURSOR_DIR/plugin-common.sh"

PLUGIN_CURSOR_RUNTIME="cursor"

plugin_cursor_package_root() {
  local override="${1:-}"
  if [[ -n "$override" ]]; then
    printf '%s\n' "$override"
    return 0
  fi
  plugin_common_package_root "$PLUGIN_CURSOR_RUNTIME"
}

plugin_cursor_target() {
  printf '%s/.cursor/plugins/local/ralph-orchestrator\n' "${HOME}"
}

plugin_cursor_validate_package() {
  local package_root="${1:-}"
  package_root="$(plugin_cursor_package_root "$package_root")"
  [[ -d "$package_root" ]] || {
    printf 'cursor plugin: package root missing: %s\n' "$package_root" >&2
    return 1
  }
  [[ -f "$package_root/.ralph-plugin-generated.json" ]] || {
    printf 'cursor plugin: missing .ralph-plugin-generated.json\n' >&2
    return 1
  }
  return 0
}

plugin_cursor_preview() {
  local package_root scope target
  package_root="$(plugin_cursor_package_root "${1:-}")"
  scope="$(plugin_common_require_scope "$PLUGIN_CURSOR_RUNTIME" "${2:-user}")" || return $?
  target="$(plugin_cursor_target)"
  plugin_cursor_validate_package "$package_root" || return 1
  printf 'preview: Cursor user-scope plugin install (owned copy)\n'
  printf 'packageRoot: %s\n' "$package_root"
  printf 'target: %s\n' "$target"
  printf 'commands:\n'
  plugin_common_preview_line atomic-copy "$package_root" "$target"
}

plugin_cursor_journal_digests() {
  local journal_json="${1:-}"
  if [[ -z "$journal_json" ]]; then
    printf '{}\n'
    return 0
  fi
  if command -v jq >/dev/null 2>&1; then
    printf '%s' "$journal_json" | jq -c '.digests // {}'
    return $?
  fi
  printf '{}\n'
}

plugin_cursor_status() {
  local package_root scope target journal_json digests version source
  local host_present=0 digests_ok=0 verify_ok=1 state meta_line
  package_root="$(plugin_cursor_package_root "${1:-}")"
  scope="$(plugin_common_require_scope "$PLUGIN_CURSOR_RUNTIME" "${2:-user}")" || return $?
  target="$(plugin_cursor_target)"

  journal_json="$(plugin_common_journal_read "$PLUGIN_CURSOR_RUNTIME" 2>/dev/null || true)"
  version=""
  source=""
  if meta_line="$(plugin_common_package_meta "$package_root" 2>/dev/null)"; then
    version="${meta_line%%$'\t'*}"
    source="${meta_line#*$'\t'}"
  fi

  if [[ -d "$target" ]] && find "$target" -type f -print -quit 2>/dev/null | grep -q .; then
    host_present=1
  fi

  if [[ "$host_present" -eq 1 && -n "$journal_json" ]]; then
    digests="$(plugin_cursor_journal_digests "$journal_json")"
    if plugin_common_digests_verify "$digests" "$target"; then
      digests_ok=1
    else
      digests_ok=0
    fi
  elif [[ "$host_present" -eq 1 ]]; then
    digests_ok=0
  fi

  state="$(plugin_common_resolve_file_state \
    "$host_present" "$digests_ok" "$journal_json" "$version" "$source" "$verify_ok")"
  printf '%s\n' "$state"
}

plugin_cursor_install() {
  local package_root="${1:-}"
  local scope="${2:-user}"
  local dry_run="${3:-0}"
  local target journal_tmp digests_tmp meta_line version source
  local journal_json digests

  package_root="$(plugin_cursor_package_root "$package_root")"
  scope="$(plugin_common_require_scope "$PLUGIN_CURSOR_RUNTIME" "$scope")" || return $?
  plugin_cursor_validate_package "$package_root" || return 1
  target="$(plugin_cursor_target)"

  plugin_cursor_preview "$package_root" "$scope"

  if [[ "$dry_run" == "1" ]]; then
    printf 'dry-run: no host mutation\n'
    return 0
  fi

  journal_json="$(plugin_common_journal_read "$PLUGIN_CURSOR_RUNTIME" 2>/dev/null || true)"
  if [[ -e "$target" ]]; then
    if [[ -z "$journal_json" ]]; then
      printf 'cursor plugin: refuse install (existing unjournaled target %s)\n' \
        "$target" >&2
      return 1
    fi
    digests="$(plugin_cursor_journal_digests "$journal_json")"
    if ! plugin_common_digests_verify "$digests" "$target"; then
      printf 'cursor plugin: refuse install (modified or drifted target %s)\n' \
        "$target" >&2
      return 1
    fi
  fi

  if ! plugin_common_atomic_copy_tree "$package_root" "$target"; then
    printf 'cursor plugin: atomic copy failed\n' >&2
    return 1
  fi

  digests_tmp="$(mktemp)"
  plugin_common_write_digests_json "$target" "$digests_tmp" || {
    rm -f "$digests_tmp"
    printf 'cursor plugin: failed to journal digests\n' >&2
    return 1
  }

  meta_line="$(plugin_common_package_meta "$package_root")"
  version="${meta_line%%$'\t'*}"
  source="${meta_line#*$'\t'}"
  journal_tmp="$(mktemp)"
  jq -n \
    --arg runtime "$PLUGIN_CURSOR_RUNTIME" \
    --arg scope "$scope" \
    --arg packageVersion "$version" \
    --arg packageSource "$source" \
    --arg packageRoot "$package_root" \
    --arg target "$target" \
    --arg at "$(plugin_common_utc_now)" \
    --slurpfile digests "$digests_tmp" '
      {
        schemaVersion: 1,
        runtime: $runtime,
        scope: $scope,
        packageVersion: $packageVersion,
        packageSource: $packageSource,
        packageRoot: $packageRoot,
        installedAt: $at,
        updatedAt: $at,
        targets: [$target],
        registrations: {
          target: $target
        },
        digests: $digests[0],
        commands: [
          {
            argv: ["atomic-copy", $packageRoot, $target],
            exitCode: 0,
            at: $at
          }
        ]
      }
    ' >"$journal_tmp"
  plugin_common_journal_write "$PLUGIN_CURSOR_RUNTIME" "$journal_tmp"
  rm -f "$digests_tmp" "$journal_tmp"
  printf 'cursor plugin: installed at %s\n' "$target"
}

plugin_cursor_remove() {
  local package_root="${1:-}"
  local scope="${2:-user}"
  local dry_run="${3:-0}"
  local target state journal_json digests

  package_root="$(plugin_cursor_package_root "$package_root")"
  scope="$(plugin_common_require_scope "$PLUGIN_CURSOR_RUNTIME" "$scope")" || return $?
  target="$(plugin_cursor_target)"

  printf 'preview: Cursor user-scope plugin remove\n'
  printf 'target: %s\n' "$target"
  plugin_common_preview_line remove-owned-files "$target"

  if [[ "$dry_run" == "1" ]]; then
    printf 'dry-run: no host mutation\n'
    return 0
  fi

  state="$(plugin_cursor_status "$package_root" "$scope")"
  case "$state" in
    drifted)
      printf 'cursor plugin: refuse remove (drifted / modified digests)\n' >&2
      return 1
      ;;
    unverifiable)
      printf 'cursor plugin: refuse remove (unverifiable)\n' >&2
      return 1
      ;;
    absent)
      plugin_common_journal_clear "$PLUGIN_CURSOR_RUNTIME" || true
      printf 'cursor plugin: already absent\n'
      return 0
      ;;
  esac

  journal_json="$(plugin_common_journal_read "$PLUGIN_CURSOR_RUNTIME" 2>/dev/null || true)"
  if [[ -z "$journal_json" ]]; then
    printf 'cursor plugin: refuse remove (no journal)\n' >&2
    return 1
  fi
  digests="$(plugin_cursor_journal_digests "$journal_json")"
  if ! plugin_common_remove_owned_files "$target" "$digests"; then
    return 1
  fi
  plugin_common_journal_clear "$PLUGIN_CURSOR_RUNTIME"
  printf 'cursor plugin: removed owned files under %s\n' "$target"
}
