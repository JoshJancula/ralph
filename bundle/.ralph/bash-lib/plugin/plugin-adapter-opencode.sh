#!/usr/bin/env bash
# OpenCode project-scope plugin install adapter.
#
# Copies only packaged plugins/ and skills/ trees into <project>/.opencode/,
# journals each created/replaced file at <state-root>/plugin-installs/opencode.json,
# and preserves preexisting unrelated files. Unjournaled differing files are never
# overwritten; identical unowned files remain unowned. Status compares digests;
# remove deletes only matching owned files, prunes empty dirs, refuses modified.
set -euo pipefail

if [[ -n "${RALPH_PLUGIN_ADAPTER_OPENCODE_LOADED:-}" ]]; then
  return 0 2>/dev/null || exit 0
fi
RALPH_PLUGIN_ADAPTER_OPENCODE_LOADED=1

_PLUGIN_OPENCODE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=plugin-common.sh
source "$_PLUGIN_OPENCODE_DIR/plugin-common.sh"

PLUGIN_OPENCODE_RUNTIME="opencode"

plugin_opencode_package_root() {
  local override="${1:-}"
  if [[ -n "$override" ]]; then
    printf '%s\n' "$override"
    return 0
  fi
  plugin_common_package_root "$PLUGIN_OPENCODE_RUNTIME"
}

plugin_opencode_project_root() {
  local override="${1:-}"
  if [[ -n "$override" ]]; then
    printf '%s\n' "${override%/}"
    return 0
  fi
  if [[ -n "${RALPH_PROJECT_ROOT:-}" ]]; then
    printf '%s\n' "${RALPH_PROJECT_ROOT%/}"
    return 0
  fi
  printf '%s\n' "$(pwd)"
}

plugin_opencode_state_root() {
  local project_root="${1:-}"
  local override="${2:-}"
  if [[ -n "$override" ]]; then
    printf '%s\n' "${override%/}"
    return 0
  fi
  plugin_common_state_root "$project_root"
}

plugin_opencode_target_root() {
  local project_root="${1:-}"
  project_root="$(plugin_opencode_project_root "$project_root")"
  printf '%s/.opencode\n' "$project_root"
}

plugin_opencode_validate_package() {
  local package_root="${1:-}"
  package_root="$(plugin_opencode_package_root "$package_root")"
  [[ -d "$package_root" ]] || {
    printf 'opencode plugin: package root missing: %s\n' "$package_root" >&2
    return 1
  }
  [[ -f "$package_root/.ralph-plugin-generated.json" ]] || {
    printf 'opencode plugin: missing .ralph-plugin-generated.json\n' >&2
    return 1
  }
  [[ -d "$package_root/plugins" || -d "$package_root/skills" ]] || {
    printf 'opencode plugin: package lacks plugins/ and skills/\n' >&2
    return 1
  }
  return 0
}

# List relative paths under package plugins/ and skills/ (NUL-delimited).
plugin_opencode_source_files() {
  local package_root="${1:-}"
  local sub
  for sub in plugins skills; do
    if [[ -d "${package_root%/}/$sub" ]]; then
      find "${package_root%/}/$sub" -type f -print0
    fi
  done
}

plugin_opencode_journal_digests() {
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

plugin_opencode_preview() {
  local package_root project_root scope state_root target
  package_root="$(plugin_opencode_package_root "${1:-}")"
  project_root="$(plugin_opencode_project_root "${2:-}")"
  scope="$(plugin_common_require_scope "$PLUGIN_OPENCODE_RUNTIME" "${3:-project}")" || return $?
  state_root="$(plugin_opencode_state_root "$project_root" "${4:-}")"
  target="$(plugin_opencode_target_root "$project_root")"
  plugin_opencode_validate_package "$package_root" || return 1
  printf 'preview: OpenCode project-scope plugin install (plugins/ + skills/)\n'
  printf 'packageRoot: %s\n' "$package_root"
  printf 'projectRoot: %s\n' "$project_root"
  printf 'stateRoot: %s\n' "$state_root"
  printf 'target: %s\n' "$target"
  printf 'commands:\n'
  plugin_common_preview_line copy-plugins-skills "$package_root" "$target"
}

plugin_opencode_status() {
  local package_root project_root scope state_root target
  local journal_json digests version source meta_line
  local host_present=0 digests_ok=0 verify_ok=1 state
  package_root="$(plugin_opencode_package_root "${1:-}")"
  project_root="$(plugin_opencode_project_root "${2:-}")"
  scope="$(plugin_common_require_scope "$PLUGIN_OPENCODE_RUNTIME" "${3:-project}")" || return $?
  state_root="$(plugin_opencode_state_root "$project_root" "${4:-}")"
  target="$(plugin_opencode_target_root "$project_root")"

  journal_json="$(plugin_common_journal_read "$PLUGIN_OPENCODE_RUNTIME" "$state_root" 2>/dev/null || true)"
  version=""
  source=""
  if meta_line="$(plugin_common_package_meta "$package_root" 2>/dev/null)"; then
    version="${meta_line%%$'\t'*}"
    source="${meta_line#*$'\t'}"
  fi

  if [[ -n "$journal_json" ]]; then
    digests="$(plugin_opencode_journal_digests "$journal_json")"
    if [[ "$digests" != "{}" ]] && command -v jq >/dev/null 2>&1; then
      if jq -e 'length > 0' >/dev/null 2>&1 <<<"$digests"; then
        # Present when any journaled path still exists (or should be verified).
        if [[ -d "$target" ]]; then
          host_present=1
        fi
        if plugin_common_digests_verify "$digests" "$target"; then
          digests_ok=1
        else
          # Missing files with a journal -> treat as not fully present / drifted
          if find "$target" -type f 2>/dev/null | grep -q .; then
            host_present=1
          else
            host_present=0
          fi
          digests_ok=0
        fi
      fi
    fi
  else
    # Unjournaled packaged paths under .opencode/{plugins,skills} => drifted host.
    if [[ -d "$target/plugins" || -d "$target/skills" ]]; then
      if find "$target/plugins" "$target/skills" -type f 2>/dev/null | grep -q .; then
        host_present=1
        digests_ok=0
      fi
    fi
  fi

  state="$(plugin_common_resolve_file_state \
    "$host_present" "$digests_ok" "$journal_json" "$version" "$source" "$verify_ok")"
  printf '%s\n' "$state"
}

plugin_opencode_install() {
  local package_root="${1:-}"
  local project_root="${2:-}"
  local scope="${3:-project}"
  local dry_run="${4:-0}"
  local state_root_override="${5:-}"
  local state_root target src_file rel dest src_digest dest_digest
  local journal_json owned_digests new_digests_tmp journal_tmp meta_line version source
  local at claims_tmp expected

  package_root="$(plugin_opencode_package_root "$package_root")"
  project_root="$(plugin_opencode_project_root "$project_root")"
  scope="$(plugin_common_require_scope "$PLUGIN_OPENCODE_RUNTIME" "$scope")" || return $?
  state_root="$(plugin_opencode_state_root "$project_root" "$state_root_override")"
  target="$(plugin_opencode_target_root "$project_root")"
  plugin_opencode_validate_package "$package_root" || return 1

  plugin_opencode_preview "$package_root" "$project_root" "$scope" "$state_root"

  if [[ "$dry_run" == "1" ]]; then
    printf 'dry-run: no host mutation\n'
    return 0
  fi

  journal_json="$(plugin_common_journal_read "$PLUGIN_OPENCODE_RUNTIME" "$state_root" 2>/dev/null || true)"
  owned_digests="{}"
  if [[ -n "$journal_json" ]]; then
    owned_digests="$(plugin_opencode_journal_digests "$journal_json")"
  fi

  new_digests_tmp="$(mktemp)"
  claims_tmp="$(mktemp)"
  : >"$claims_tmp"
  printf '{}\n' >"$new_digests_tmp"
  mkdir -p "$target"

  while IFS= read -r -d '' src_file; do
    rel="${src_file#"${package_root%/}"/}"
    dest="${target%/}/$rel"
    src_digest="$(plugin_common_file_sha256 "$src_file")" || {
      rm -f "$new_digests_tmp" "$claims_tmp"
      return 1
    }

    if [[ -f "$dest" ]]; then
      dest_digest="$(plugin_common_file_sha256 "$dest")" || {
        rm -f "$new_digests_tmp" "$claims_tmp"
        return 1
      }
      if command -v jq >/dev/null 2>&1 && \
        jq -e --arg p "$rel" 'has($p)' >/dev/null 2>&1 <<<"$owned_digests"; then
        # Journal-owned: may replace when matching journal digest, or when
        # reinstalling over a previously owned matching path.
        expected="$(jq -r --arg p "$rel" '.[$p]' <<<"$owned_digests")"
        if [[ "$dest_digest" != "$expected" && "$dest_digest" != "$src_digest" ]]; then
          printf 'opencode plugin: refuse overwrite of modified owned file %s\n' \
            "$rel" >&2
          rm -f "$new_digests_tmp" "$claims_tmp"
          return 1
        fi
        plugin_common_atomic_write_file "$src_file" "$dest" || {
          rm -f "$new_digests_tmp" "$claims_tmp"
          return 1
        }
        src_digest="$(plugin_common_file_sha256 "$dest")"
        printf '%s\t%s\n' "$rel" "$src_digest" >>"$claims_tmp"
      else
        # Unowned existing file.
        if [[ "$dest_digest" == "$src_digest" ]]; then
          # Identical unowned: leave in place, do not claim ownership.
          continue
        fi
        printf 'opencode plugin: refuse overwrite of unjournaled differing file %s\n' \
          "$rel" >&2
        rm -f "$new_digests_tmp" "$claims_tmp"
        return 1
      fi
    else
      plugin_common_atomic_write_file "$src_file" "$dest" || {
        rm -f "$new_digests_tmp" "$claims_tmp"
        return 1
      }
      printf '%s\t%s\n' "$rel" "$src_digest" >>"$claims_tmp"
    fi
  done < <(plugin_opencode_source_files "$package_root")

  # Merge prior owned digests that we still claim with newly written claims.
  # Drop paths we no longer ship only on explicit remove; reinstall keeps extras
  # that remain owned and unmodified under the previous journal when still present.
  if command -v jq >/dev/null 2>&1; then
    {
      # Keep previous owned entries that still match on disk and were not rewritten.
      if [[ "$owned_digests" != "{}" ]]; then
        while IFS=$'\t' read -r rel expected; do
          [[ -n "$rel" ]] || continue
          if grep -Fq "$rel"$'\t' "$claims_tmp" 2>/dev/null; then
            continue
          fi
          if [[ -f "${target%/}/$rel" ]]; then
            dest_digest="$(plugin_common_file_sha256 "${target%/}/$rel")" || continue
            if [[ "$dest_digest" == "$expected" ]]; then
              printf '%s\t%s\n' "$rel" "$expected"
            fi
          fi
        done < <(jq -r 'to_entries[] | "\(.key)\t\(.value)"' <<<"$owned_digests")
      fi
      cat "$claims_tmp"
    } | plugin_common_digests_tsv_to_json >"$new_digests_tmp"
  else
    plugin_common_digests_tsv_to_json <"$claims_tmp" >"$new_digests_tmp"
  fi

  meta_line="$(plugin_common_package_meta "$package_root")"
  version="${meta_line%%$'\t'*}"
  source="${meta_line#*$'\t'}"
  at="$(plugin_common_utc_now)"
  journal_tmp="$(mktemp)"
  jq -n \
    --arg runtime "$PLUGIN_OPENCODE_RUNTIME" \
    --arg scope "$scope" \
    --arg packageVersion "$version" \
    --arg packageSource "$source" \
    --arg packageRoot "$package_root" \
    --arg projectRoot "$project_root" \
    --arg stateRoot "$state_root" \
    --arg target "$target" \
    --arg at "$at" \
    --slurpfile digests "$new_digests_tmp" '
      {
        schemaVersion: 1,
        runtime: $runtime,
        scope: $scope,
        packageVersion: $packageVersion,
        packageSource: $packageSource,
        packageRoot: $packageRoot,
        projectRoot: $projectRoot,
        stateRoot: $stateRoot,
        installedAt: $at,
        updatedAt: $at,
        targets: [$target],
        registrations: {
          target: $target
        },
        digests: $digests[0],
        commands: [
          {
            argv: ["copy-plugins-skills", $packageRoot, $target],
            exitCode: 0,
            at: $at
          }
        ]
      }
    ' >"$journal_tmp"
  plugin_common_journal_write "$PLUGIN_OPENCODE_RUNTIME" "$journal_tmp" "$state_root"
  rm -f "$new_digests_tmp" "$claims_tmp" "$journal_tmp"
  printf 'opencode plugin: installed plugins/skills under %s\n' "$target"
}

plugin_opencode_remove() {
  local package_root="${1:-}"
  local project_root="${2:-}"
  local scope="${3:-project}"
  local dry_run="${4:-0}"
  local state_root_override="${5:-}"
  local state_root target state journal_json digests

  package_root="$(plugin_opencode_package_root "$package_root")"
  project_root="$(plugin_opencode_project_root "$project_root")"
  scope="$(plugin_common_require_scope "$PLUGIN_OPENCODE_RUNTIME" "$scope")" || return $?
  state_root="$(plugin_opencode_state_root "$project_root" "$state_root_override")"
  target="$(plugin_opencode_target_root "$project_root")"

  printf 'preview: OpenCode project-scope plugin remove\n'
  printf 'target: %s\n' "$target"
  printf 'journal: %s\n' "$(plugin_common_journal_path "$PLUGIN_OPENCODE_RUNTIME" "$state_root")"
  plugin_common_preview_line remove-owned-files "$target"

  if [[ "$dry_run" == "1" ]]; then
    printf 'dry-run: no host mutation\n'
    return 0
  fi

  state="$(plugin_opencode_status "$package_root" "$project_root" "$scope" "$state_root")"
  case "$state" in
    drifted)
      printf 'opencode plugin: refuse remove (drifted / modified digests)\n' >&2
      return 1
      ;;
    unverifiable)
      printf 'opencode plugin: refuse remove (unverifiable)\n' >&2
      return 1
      ;;
    absent)
      plugin_common_journal_clear "$PLUGIN_OPENCODE_RUNTIME" "$state_root" || true
      printf 'opencode plugin: already absent\n'
      return 0
      ;;
  esac

  journal_json="$(plugin_common_journal_read "$PLUGIN_OPENCODE_RUNTIME" "$state_root" 2>/dev/null || true)"
  if [[ -z "$journal_json" ]]; then
    printf 'opencode plugin: refuse remove (no journal)\n' >&2
    return 1
  fi
  digests="$(plugin_opencode_journal_digests "$journal_json")"
  if ! plugin_common_remove_owned_files "$target" "$digests"; then
    return 1
  fi
  plugin_common_journal_clear "$PLUGIN_OPENCODE_RUNTIME" "$state_root"
  printf 'opencode plugin: removed owned files under %s\n' "$target"
}
