#!/usr/bin/env bash
# Claude Code user-scope plugin install adapter.
#
# Fixed argv:
#   claude plugin marketplace add --scope user <claude-package-root>
#   claude plugin install --scope user ralph-orchestrator@ralph-plugins [--yes]
#   claude plugin list --json
#   claude plugin uninstall --scope user ralph-orchestrator@ralph-plugins
#   claude plugin marketplace remove --scope user ralph-plugins
#
# Marketplace metadata must already exist on the packaged root (generated);
# this adapter never synthesizes host marketplace JSON.
set -euo pipefail

if [[ -n "${RALPH_PLUGIN_ADAPTER_CLAUDE_LOADED:-}" ]]; then
  return 0 2>/dev/null || exit 0
fi
RALPH_PLUGIN_ADAPTER_CLAUDE_LOADED=1

_PLUGIN_CLAUDE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=plugin-common.sh
source "$_PLUGIN_CLAUDE_DIR/plugin-common.sh"

PLUGIN_CLAUDE_CLI="claude"
PLUGIN_CLAUDE_RUNTIME="claude"
PLUGIN_CLAUDE_MARKETPLACE_REL=".claude-plugin/marketplace.json"
PLUGIN_CLAUDE_PLUGIN_META_REL=".claude-plugin/plugin.json"

plugin_claude_package_root() {
  local override="${1:-}"
  if [[ -n "$override" ]]; then
    printf '%s\n' "$override"
    return 0
  fi
  plugin_common_package_root "$PLUGIN_CLAUDE_RUNTIME"
}

plugin_claude_validate_package() {
  local package_root="${1:-}"
  local market plugin_meta
  package_root="$(plugin_claude_package_root "$package_root")"
  [[ -d "$package_root" ]] || {
    printf 'claude plugin: package root missing: %s\n' "$package_root" >&2
    return 1
  }
  market="$package_root/$PLUGIN_CLAUDE_MARKETPLACE_REL"
  plugin_meta="$package_root/$PLUGIN_CLAUDE_PLUGIN_META_REL"
  [[ -f "$plugin_meta" ]] || {
    printf 'claude plugin: missing %s\n' "$PLUGIN_CLAUDE_PLUGIN_META_REL" >&2
    return 1
  }
  [[ -f "$market" ]] || {
    printf 'claude plugin: missing marketplace metadata %s\n' \
      "$PLUGIN_CLAUDE_MARKETPLACE_REL" >&2
    return 1
  }
  if ! plugin_common_marketplace_resolves_package_ref "$market"; then
    printf 'claude plugin: marketplace must resolve %s\n' \
      "$PLUGIN_COMMON_PACKAGE_REF" >&2
    return 1
  fi
  return 0
}

plugin_claude_marketplace_probe() {
  # Echo preexisting|absent. Uses marketplace list --json when available.
  local commands_file="${1:-}"
  local out ec
  out="$(mktemp)"
  set +e
  plugin_common_host_run "$commands_file" -- \
    "$PLUGIN_CLAUDE_CLI" plugin marketplace list --json >"$out"
  ec=$?
  set -e
  if [[ "$ec" -ne 0 ]]; then
    rm -f "$out"
    printf 'absent\n'
    return 0
  fi
  if grep -Eq "\"name\"[[:space:]]*:[[:space:]]*\"${PLUGIN_COMMON_MARKETPLACE_NAME}\"" "$out" \
    || grep -Fq "\"${PLUGIN_COMMON_MARKETPLACE_NAME}\"" "$out"; then
    rm -f "$out"
    printf 'preexisting\n'
    return 0
  fi
  rm -f "$out"
  printf 'absent\n'
}

plugin_claude_preview() {
  local package_root scope yes_flag=0
  package_root="$(plugin_claude_package_root "${1:-}")"
  scope="$(plugin_common_require_scope "$PLUGIN_CLAUDE_RUNTIME" "${2:-user}")" || return $?
  [[ "${3:-0}" == "1" ]] && yes_flag=1
  plugin_claude_validate_package "$package_root" || return 1
  printf 'preview: Claude user-scope plugin install\n'
  printf 'packageRoot: %s\n' "$package_root"
  printf 'packageRef: %s\n' "$PLUGIN_COMMON_PACKAGE_REF"
  printf 'commands:\n'
  plugin_common_preview_line \
    "$PLUGIN_CLAUDE_CLI" plugin marketplace add --scope "$scope" "$package_root"
  if [[ "$yes_flag" -eq 1 ]]; then
    plugin_common_preview_line \
      "$PLUGIN_CLAUDE_CLI" plugin install --scope "$scope" \
      "$PLUGIN_COMMON_PACKAGE_REF" --yes
  else
    plugin_common_preview_line \
      "$PLUGIN_CLAUDE_CLI" plugin install --scope "$scope" \
      "$PLUGIN_COMMON_PACKAGE_REF"
  fi
}

plugin_claude_status() {
  local package_root scope commands_file list_json journal_json
  local version source host_ok=0 host_has=0 state
  package_root="$(plugin_claude_package_root "${1:-}")"
  scope="$(plugin_common_require_scope "$PLUGIN_CLAUDE_RUNTIME" "${2:-user}")" || return $?
  commands_file="$(mktemp)"
  printf '[]\n' >"$commands_file"

  if plugin_common_cli_missing "$PLUGIN_CLAUDE_CLI"; then
    rm -f "$commands_file"
    printf 'unverifiable\n'
    return 0
  fi

  set +e
  list_json="$(plugin_common_host_run "$commands_file" -- \
    "$PLUGIN_CLAUDE_CLI" plugin list --json)"
  host_ok=$?
  set -e
  if [[ "$host_ok" -eq 0 ]]; then
    host_ok=1
    if plugin_common_list_contains_ralph "$list_json"; then
      host_has=1
    fi
  else
    host_ok=0
  fi

  journal_json="$(plugin_common_journal_read "$PLUGIN_CLAUDE_RUNTIME" 2>/dev/null || true)"
  version=""
  source=""
  if meta_line="$(plugin_common_package_meta "$package_root" 2>/dev/null)"; then
    version="${meta_line%%$'\t'*}"
    source="${meta_line#*$'\t'}"
  fi
  state="$(plugin_common_resolve_state "$host_ok" "$host_has" "$journal_json" "$version" "$source")"
  rm -f "$commands_file"
  printf '%s\n' "$state"
}

plugin_claude_install() {
  local package_root="${1:-}"
  local scope="${2:-user}"
  local dry_run="${3:-0}"
  local yes_flag="${4:-0}"
  local commands_file ownership journal_tmp meta_line version source ec

  package_root="$(plugin_claude_package_root "$package_root")"
  scope="$(plugin_common_require_scope "$PLUGIN_CLAUDE_RUNTIME" "$scope")" || return $?
  plugin_claude_validate_package "$package_root" || return 1

  plugin_claude_preview "$package_root" "$scope" "$yes_flag"

  if [[ "$dry_run" == "1" ]]; then
    printf 'dry-run: no host mutation\n'
    return 0
  fi

  if plugin_common_cli_missing "$PLUGIN_CLAUDE_CLI"; then
    printf 'claude plugin: missing CLI (%s)\n' "$PLUGIN_CLAUDE_CLI" >&2
    return 1
  fi

  commands_file="$(mktemp)"
  printf '[]\n' >"$commands_file"

  ownership="$(plugin_claude_marketplace_probe "$commands_file")"
  if [[ "$ownership" != "preexisting" ]]; then
    set +e
    plugin_common_host_run "$commands_file" -- \
      "$PLUGIN_CLAUDE_CLI" plugin marketplace add --scope "$scope" "$package_root" >/dev/null
    ec=$?
    set -e
    if [[ "$ec" -ne 0 ]]; then
      # Already registered mid-flight: treat as preexisting, do not claim ownership.
      ownership="preexisting"
    else
      ownership="ralph-created"
    fi
  fi

  set +e
  if [[ "$yes_flag" == "1" ]]; then
    plugin_common_host_run "$commands_file" -- \
      "$PLUGIN_CLAUDE_CLI" plugin install --scope "$scope" \
      "$PLUGIN_COMMON_PACKAGE_REF" --yes >/dev/null
    ec=$?
  else
    plugin_common_host_run "$commands_file" -- \
      "$PLUGIN_CLAUDE_CLI" plugin install --scope "$scope" \
      "$PLUGIN_COMMON_PACKAGE_REF" >/dev/null
    ec=$?
  fi
  set -e
  if [[ "$ec" -ne 0 ]]; then
    printf 'claude plugin: install failed (exit %s)\n' "$ec" >&2
    rm -f "$commands_file"
    return "$ec"
  fi

  meta_line="$(plugin_common_package_meta "$package_root")"
  version="${meta_line%%$'\t'*}"
  source="${meta_line#*$'\t'}"
  journal_tmp="$(mktemp)"
  jq -n \
    --arg runtime "$PLUGIN_CLAUDE_RUNTIME" \
    --arg scope "$scope" \
    --arg packageVersion "$version" \
    --arg packageSource "$source" \
    --arg packageRoot "$package_root" \
    --arg packageRef "$PLUGIN_COMMON_PACKAGE_REF" \
    --arg marketplaceName "$PLUGIN_COMMON_MARKETPLACE_NAME" \
    --arg ownership "$ownership" \
    --arg at "$(plugin_common_utc_now)" \
    --slurpfile commands "$commands_file" '
      {
        schemaVersion: 1,
        runtime: $runtime,
        scope: $scope,
        packageVersion: $packageVersion,
        packageSource: $packageSource,
        packageRoot: $packageRoot,
        installedAt: $at,
        updatedAt: $at,
        targets: [$packageRef],
        registrations: {
          plugin: $packageRef,
          marketplace: {
            name: $marketplaceName,
            ownership: $ownership
          }
        },
        digests: {},
        commands: $commands[0]
      }
    ' >"$journal_tmp"
  plugin_common_journal_write "$PLUGIN_CLAUDE_RUNTIME" "$journal_tmp"
  rm -f "$commands_file" "$journal_tmp"
  printf 'claude plugin: installed %s (marketplace %s)\n' \
    "$PLUGIN_COMMON_PACKAGE_REF" "$ownership"
}

plugin_claude_remove() {
  local package_root="${1:-}"
  local scope="${2:-user}"
  local dry_run="${3:-0}"
  local state journal_json ownership commands_file ec

  package_root="$(plugin_claude_package_root "$package_root")"
  scope="$(plugin_common_require_scope "$PLUGIN_CLAUDE_RUNTIME" "$scope")" || return $?

  printf 'preview: Claude user-scope plugin remove\n'
  plugin_common_preview_line \
    "$PLUGIN_CLAUDE_CLI" plugin uninstall --scope "$scope" "$PLUGIN_COMMON_PACKAGE_REF"
  plugin_common_preview_line \
    "$PLUGIN_CLAUDE_CLI" plugin marketplace remove --scope "$scope" \
    "$PLUGIN_COMMON_MARKETPLACE_NAME"

  if [[ "$dry_run" == "1" ]]; then
    printf 'dry-run: no host mutation\n'
    return 0
  fi

  if plugin_common_cli_missing "$PLUGIN_CLAUDE_CLI"; then
    printf 'claude plugin: missing CLI (%s)\n' "$PLUGIN_CLAUDE_CLI" >&2
    return 1
  fi

  state="$(plugin_claude_status "$package_root" "$scope")"
  case "$state" in
    drifted)
      printf 'claude plugin: refuse remove (drifted / journal mismatch)\n' >&2
      return 1
      ;;
    unverifiable)
      printf 'claude plugin: refuse remove (unverifiable)\n' >&2
      return 1
      ;;
    absent)
      plugin_common_journal_clear "$PLUGIN_CLAUDE_RUNTIME" || true
      printf 'claude plugin: already absent\n'
      return 0
      ;;
  esac

  journal_json="$(plugin_common_journal_read "$PLUGIN_CLAUDE_RUNTIME" 2>/dev/null || true)"
  ownership="preexisting"
  if [[ -n "$journal_json" ]]; then
    ownership="$(printf '%s' "$journal_json" | jq -r '.registrations.marketplace.ownership // "preexisting"')"
  fi

  commands_file="$(mktemp)"
  printf '[]\n' >"$commands_file"
  set +e
  plugin_common_host_run "$commands_file" -- \
    "$PLUGIN_CLAUDE_CLI" plugin uninstall --scope "$scope" \
    "$PLUGIN_COMMON_PACKAGE_REF" >/dev/null
  ec=$?
  set -e
  if [[ "$ec" -ne 0 ]]; then
    printf 'claude plugin: uninstall failed (exit %s)\n' "$ec" >&2
    rm -f "$commands_file"
    return "$ec"
  fi

  if [[ "$ownership" == "ralph-created" ]]; then
    set +e
    plugin_common_host_run "$commands_file" -- \
      "$PLUGIN_CLAUDE_CLI" plugin marketplace remove --scope "$scope" \
      "$PLUGIN_COMMON_MARKETPLACE_NAME" >/dev/null
    set -e
  else
    printf 'claude plugin: leaving preexisting marketplace %s\n' \
      "$PLUGIN_COMMON_MARKETPLACE_NAME"
  fi

  plugin_common_journal_clear "$PLUGIN_CLAUDE_RUNTIME"
  rm -f "$commands_file"
  printf 'claude plugin: removed %s\n' "$PLUGIN_COMMON_PACKAGE_REF"
}
