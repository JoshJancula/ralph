#!/usr/bin/env bash
# Codex user-scope plugin install adapter.
#
# Fixed argv:
#   codex plugin marketplace add <codex-marketplace-root> --json
#   codex plugin add ralph-orchestrator@ralph-plugins --json
#   codex plugin list --json
#   codex plugin remove ralph-orchestrator@ralph-plugins --json
#   codex plugin marketplace remove ralph-plugins --json
#
# Marketplace metadata must already exist on the packaged root (generated at
# .agents/plugins/marketplace.json); this adapter never synthesizes it.
set -euo pipefail

if [[ -n "${RALPH_PLUGIN_ADAPTER_CODEX_LOADED:-}" ]]; then
  return 0 2>/dev/null || exit 0
fi
RALPH_PLUGIN_ADAPTER_CODEX_LOADED=1

_PLUGIN_CODEX_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=plugin-common.sh
source "$_PLUGIN_CODEX_DIR/plugin-common.sh"

PLUGIN_CODEX_CLI="codex"
PLUGIN_CODEX_RUNTIME="codex"
PLUGIN_CODEX_MARKETPLACE_REL=".agents/plugins/marketplace.json"
PLUGIN_CODEX_PLUGIN_META_REL=".codex-plugin/plugin.json"

plugin_codex_package_root() {
  local override="${1:-}"
  if [[ -n "$override" ]]; then
    printf '%s\n' "$override"
    return 0
  fi
  plugin_common_package_root "$PLUGIN_CODEX_RUNTIME"
}

# Packaged Codex root is the marketplace root (local source for marketplace add).
plugin_codex_marketplace_root() {
  plugin_codex_package_root "${1:-}"
}

plugin_codex_validate_package() {
  local package_root="${1:-}"
  local market plugin_meta
  package_root="$(plugin_codex_package_root "$package_root")"
  [[ -d "$package_root" ]] || {
    printf 'codex plugin: package root missing: %s\n' "$package_root" >&2
    return 1
  }
  market="$package_root/$PLUGIN_CODEX_MARKETPLACE_REL"
  plugin_meta="$package_root/$PLUGIN_CODEX_PLUGIN_META_REL"
  [[ -f "$plugin_meta" ]] || {
    printf 'codex plugin: missing %s\n' "$PLUGIN_CODEX_PLUGIN_META_REL" >&2
    return 1
  }
  [[ -f "$market" ]] || {
    printf 'codex plugin: missing marketplace metadata %s\n' \
      "$PLUGIN_CODEX_MARKETPLACE_REL" >&2
    return 1
  }
  if ! plugin_common_marketplace_resolves_package_ref "$market"; then
    printf 'codex plugin: marketplace must resolve %s\n' \
      "$PLUGIN_COMMON_PACKAGE_REF" >&2
    return 1
  fi
  return 0
}

plugin_codex_marketplace_probe() {
  local commands_file="${1:-}"
  local out ec
  out="$(mktemp)"
  set +e
  plugin_common_host_run "$commands_file" -- \
    "$PLUGIN_CODEX_CLI" plugin marketplace list --json >"$out"
  ec=$?
  set -e
  if [[ "$ec" -ne 0 ]]; then
    rm -f "$out"
    printf 'absent\n'
    return 0
  fi
  if grep -Eq "\"name\"[[:space:]]*:[[:space:]]*\"${PLUGIN_COMMON_MARKETPLACE_NAME}\"" "$out" \
    || grep -Fq "$PLUGIN_COMMON_MARKETPLACE_NAME" "$out"; then
    rm -f "$out"
    printf 'preexisting\n'
    return 0
  fi
  rm -f "$out"
  printf 'absent\n'
}

plugin_codex_preview() {
  local package_root marketplace_root scope
  package_root="$(plugin_codex_package_root "${1:-}")"
  marketplace_root="$(plugin_codex_marketplace_root "$package_root")"
  scope="$(plugin_common_require_scope "$PLUGIN_CODEX_RUNTIME" "${2:-user}")" || return $?
  plugin_codex_validate_package "$package_root" || return 1
  printf 'preview: Codex user-scope plugin install\n'
  printf 'marketplaceRoot: %s\n' "$marketplace_root"
  printf 'packageRef: %s\n' "$PLUGIN_COMMON_PACKAGE_REF"
  printf 'commands:\n'
  plugin_common_preview_line \
    "$PLUGIN_CODEX_CLI" plugin marketplace add "$marketplace_root" --json
  plugin_common_preview_line \
    "$PLUGIN_CODEX_CLI" plugin add "$PLUGIN_COMMON_PACKAGE_REF" --json
}

plugin_codex_status() {
  local package_root scope commands_file list_json journal_json
  local version source host_ok=0 host_has=0 state meta_line
  package_root="$(plugin_codex_package_root "${1:-}")"
  scope="$(plugin_common_require_scope "$PLUGIN_CODEX_RUNTIME" "${2:-user}")" || return $?
  commands_file="$(mktemp)"
  printf '[]\n' >"$commands_file"

  if plugin_common_cli_missing "$PLUGIN_CODEX_CLI"; then
    rm -f "$commands_file"
    printf 'unverifiable\n'
    return 0
  fi

  set +e
  list_json="$(plugin_common_host_run "$commands_file" -- \
    "$PLUGIN_CODEX_CLI" plugin list --json)"
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

  journal_json="$(plugin_common_journal_read "$PLUGIN_CODEX_RUNTIME" 2>/dev/null || true)"
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

plugin_codex_install() {
  local package_root="${1:-}"
  local scope="${2:-user}"
  local dry_run="${3:-0}"
  local commands_file ownership journal_tmp meta_line version source ec
  local marketplace_root

  package_root="$(plugin_codex_package_root "$package_root")"
  marketplace_root="$(plugin_codex_marketplace_root "$package_root")"
  scope="$(plugin_common_require_scope "$PLUGIN_CODEX_RUNTIME" "$scope")" || return $?
  plugin_codex_validate_package "$package_root" || return 1

  plugin_codex_preview "$package_root" "$scope"

  if [[ "$dry_run" == "1" ]]; then
    printf 'dry-run: no host mutation\n'
    return 0
  fi

  if plugin_common_cli_missing "$PLUGIN_CODEX_CLI"; then
    printf 'codex plugin: missing CLI (%s)\n' "$PLUGIN_CODEX_CLI" >&2
    return 1
  fi

  commands_file="$(mktemp)"
  printf '[]\n' >"$commands_file"

  ownership="$(plugin_codex_marketplace_probe "$commands_file")"
  if [[ "$ownership" != "preexisting" ]]; then
    set +e
    plugin_common_host_run "$commands_file" -- \
      "$PLUGIN_CODEX_CLI" plugin marketplace add "$marketplace_root" --json >/dev/null
    ec=$?
    set -e
    if [[ "$ec" -ne 0 ]]; then
      ownership="preexisting"
    else
      ownership="ralph-created"
    fi
  fi

  set +e
  plugin_common_host_run "$commands_file" -- \
    "$PLUGIN_CODEX_CLI" plugin add "$PLUGIN_COMMON_PACKAGE_REF" --json >/dev/null
  ec=$?
  set -e
  if [[ "$ec" -ne 0 ]]; then
    printf 'codex plugin: install failed (exit %s)\n' "$ec" >&2
    rm -f "$commands_file"
    return "$ec"
  fi

  meta_line="$(plugin_common_package_meta "$package_root")"
  version="${meta_line%%$'\t'*}"
  source="${meta_line#*$'\t'}"
  journal_tmp="$(mktemp)"
  jq -n \
    --arg runtime "$PLUGIN_CODEX_RUNTIME" \
    --arg scope "$scope" \
    --arg packageVersion "$version" \
    --arg packageSource "$source" \
    --arg packageRoot "$package_root" \
    --arg marketplaceRoot "$marketplace_root" \
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
        marketplaceRoot: $marketplaceRoot,
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
  plugin_common_journal_write "$PLUGIN_CODEX_RUNTIME" "$journal_tmp"
  rm -f "$commands_file" "$journal_tmp"
  printf 'codex plugin: installed %s (marketplace %s)\n' \
    "$PLUGIN_COMMON_PACKAGE_REF" "$ownership"
}

plugin_codex_remove() {
  local package_root="${1:-}"
  local scope="${2:-user}"
  local dry_run="${3:-0}"
  local state journal_json ownership commands_file ec

  package_root="$(plugin_codex_package_root "$package_root")"
  scope="$(plugin_common_require_scope "$PLUGIN_CODEX_RUNTIME" "$scope")" || return $?

  printf 'preview: Codex user-scope plugin remove\n'
  plugin_common_preview_line \
    "$PLUGIN_CODEX_CLI" plugin remove "$PLUGIN_COMMON_PACKAGE_REF" --json
  plugin_common_preview_line \
    "$PLUGIN_CODEX_CLI" plugin marketplace remove "$PLUGIN_COMMON_MARKETPLACE_NAME" --json

  if [[ "$dry_run" == "1" ]]; then
    printf 'dry-run: no host mutation\n'
    return 0
  fi

  if plugin_common_cli_missing "$PLUGIN_CODEX_CLI"; then
    printf 'codex plugin: missing CLI (%s)\n' "$PLUGIN_CODEX_CLI" >&2
    return 1
  fi

  state="$(plugin_codex_status "$package_root" "$scope")"
  case "$state" in
    drifted)
      printf 'codex plugin: refuse remove (drifted / journal mismatch)\n' >&2
      return 1
      ;;
    unverifiable)
      printf 'codex plugin: refuse remove (unverifiable)\n' >&2
      return 1
      ;;
    absent)
      plugin_common_journal_clear "$PLUGIN_CODEX_RUNTIME" || true
      printf 'codex plugin: already absent\n'
      return 0
      ;;
  esac

  journal_json="$(plugin_common_journal_read "$PLUGIN_CODEX_RUNTIME" 2>/dev/null || true)"
  ownership="preexisting"
  if [[ -n "$journal_json" ]]; then
    ownership="$(printf '%s' "$journal_json" | jq -r '.registrations.marketplace.ownership // "preexisting"')"
  fi

  commands_file="$(mktemp)"
  printf '[]\n' >"$commands_file"
  set +e
  plugin_common_host_run "$commands_file" -- \
    "$PLUGIN_CODEX_CLI" plugin remove "$PLUGIN_COMMON_PACKAGE_REF" --json >/dev/null
  ec=$?
  set -e
  if [[ "$ec" -ne 0 ]]; then
    printf 'codex plugin: remove failed (exit %s)\n' "$ec" >&2
    rm -f "$commands_file"
    return "$ec"
  fi

  if [[ "$ownership" == "ralph-created" ]]; then
    set +e
    plugin_common_host_run "$commands_file" -- \
      "$PLUGIN_CODEX_CLI" plugin marketplace remove \
      "$PLUGIN_COMMON_MARKETPLACE_NAME" --json >/dev/null
    set -e
  else
    printf 'codex plugin: leaving preexisting marketplace %s\n' \
      "$PLUGIN_COMMON_MARKETPLACE_NAME"
  fi

  plugin_common_journal_clear "$PLUGIN_CODEX_RUNTIME"
  rm -f "$commands_file"
  printf 'codex plugin: removed %s\n' "$PLUGIN_COMMON_PACKAGE_REF"
}
