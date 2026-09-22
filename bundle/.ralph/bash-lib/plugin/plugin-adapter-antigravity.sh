#!/usr/bin/env bash
# Antigravity user-scope plugin install adapter.
#
# Fixed argv:
#   agy plugin install <antigravity-package>
#   agy plugin list
#   agy plugin uninstall ralph-orchestrator
#
# Package/model contract files (host-manifest.json, mcp_config.json, and
# .ralph-plugin-generated.json) are validated read-only and never rewritten.
# Install failure attempts uninstall rollback and never writes a journal.
# Uninstall failure preserves the existing journal.
set -euo pipefail

if [[ -n "${RALPH_PLUGIN_ADAPTER_ANTIGRAVITY_LOADED:-}" ]]; then
  return 0 2>/dev/null || exit 0
fi
RALPH_PLUGIN_ADAPTER_ANTIGRAVITY_LOADED=1

_PLUGIN_ANTIGRAVITY_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=plugin-common.sh
source "$_PLUGIN_ANTIGRAVITY_DIR/plugin-common.sh"

PLUGIN_ANTIGRAVITY_CLI="agy"
PLUGIN_ANTIGRAVITY_RUNTIME="antigravity"
PLUGIN_ANTIGRAVITY_PLUGIN_ID="${PLUGIN_COMMON_PLUGIN_ID}"
PLUGIN_ANTIGRAVITY_HOST_MANIFEST_REL="host-manifest.json"
PLUGIN_ANTIGRAVITY_MCP_REL="mcp_config.json"
PLUGIN_ANTIGRAVITY_GENERATED_REL=".ralph-plugin-generated.json"

plugin_antigravity_package_root() {
  local override="${1:-}"
  if [[ -n "$override" ]]; then
    printf '%s\n' "$override"
    return 0
  fi
  plugin_common_package_root "$PLUGIN_ANTIGRAVITY_RUNTIME"
}

# Read-only host-contract validation. Never mutates package bytes.
plugin_antigravity_validate_package() {
  local package_root="${1:-}"
  local manifest mcp generated
  package_root="$(plugin_antigravity_package_root "$package_root")"
  [[ -d "$package_root" ]] || {
    printf 'antigravity plugin: package root missing: %s\n' "$package_root" >&2
    return 1
  }
  manifest="$package_root/$PLUGIN_ANTIGRAVITY_HOST_MANIFEST_REL"
  mcp="$package_root/$PLUGIN_ANTIGRAVITY_MCP_REL"
  generated="$package_root/$PLUGIN_ANTIGRAVITY_GENERATED_REL"
  [[ -f "$manifest" ]] || {
    printf 'antigravity plugin: missing host contract %s\n' \
      "$PLUGIN_ANTIGRAVITY_HOST_MANIFEST_REL" >&2
    return 1
  }
  [[ -f "$mcp" ]] || {
    printf 'antigravity plugin: missing MCP contract %s\n' \
      "$PLUGIN_ANTIGRAVITY_MCP_REL" >&2
    return 1
  }
  [[ -f "$generated" ]] || {
    printf 'antigravity plugin: missing %s\n' \
      "$PLUGIN_ANTIGRAVITY_GENERATED_REL" >&2
    return 1
  }
  if command -v jq >/dev/null 2>&1; then
    if ! jq -e \
      --arg id "$PLUGIN_ANTIGRAVITY_PLUGIN_ID" \
      --arg rt "$PLUGIN_ANTIGRAVITY_RUNTIME" '
        .id == $id and .runtime == $rt
        and ((.version // "") | type == "string" and length > 0)
      ' "$manifest" >/dev/null 2>&1; then
      printf 'antigravity plugin: host-manifest must id=%s runtime=%s\n' \
        "$PLUGIN_ANTIGRAVITY_PLUGIN_ID" "$PLUGIN_ANTIGRAVITY_RUNTIME" >&2
      return 1
    fi
    if ! jq -e '.mcpServers | type == "object"' "$mcp" >/dev/null 2>&1; then
      printf 'antigravity plugin: mcp_config.json must declare mcpServers object\n' >&2
      return 1
    fi
    if ! jq -e '
      (.pluginVersion // "" | type == "string" and length > 0)
      and (.sourceDescriptor // "" | type == "string" and length > 0)
    ' "$generated" >/dev/null 2>&1; then
      printf 'antigravity plugin: invalid .ralph-plugin-generated.json meta\n' >&2
      return 1
    fi
  else
    if ! grep -Fq "\"id\": \"$PLUGIN_ANTIGRAVITY_PLUGIN_ID\"" "$manifest" \
      || ! grep -Fq "\"runtime\": \"$PLUGIN_ANTIGRAVITY_RUNTIME\"" "$manifest"; then
      printf 'antigravity plugin: host-manifest must id=%s runtime=%s\n' \
        "$PLUGIN_ANTIGRAVITY_PLUGIN_ID" "$PLUGIN_ANTIGRAVITY_RUNTIME" >&2
      return 1
    fi
  fi
  return 0
}

plugin_antigravity_preview() {
  local package_root scope
  package_root="$(plugin_antigravity_package_root "${1:-}")"
  scope="$(plugin_common_require_scope "$PLUGIN_ANTIGRAVITY_RUNTIME" "${2:-user}")" || return $?
  plugin_antigravity_validate_package "$package_root" || return 1
  printf 'preview: Antigravity user-scope plugin install\n'
  printf 'packageRoot: %s\n' "$package_root"
  printf 'pluginId: %s\n' "$PLUGIN_ANTIGRAVITY_PLUGIN_ID"
  printf 'commands:\n'
  plugin_common_preview_line \
    "$PLUGIN_ANTIGRAVITY_CLI" plugin install "$package_root"
}

plugin_antigravity_status() {
  local package_root scope commands_file list_out journal_json
  local version source host_ok=0 host_has=0 state meta_line
  package_root="$(plugin_antigravity_package_root "${1:-}")"
  scope="$(plugin_common_require_scope "$PLUGIN_ANTIGRAVITY_RUNTIME" "${2:-user}")" || return $?
  commands_file="$(mktemp)"
  printf '[]\n' >"$commands_file"

  if plugin_common_cli_missing "$PLUGIN_ANTIGRAVITY_CLI"; then
    rm -f "$commands_file"
    printf 'unverifiable\n'
    return 0
  fi

  set +e
  list_out="$(plugin_common_host_run "$commands_file" -- \
    "$PLUGIN_ANTIGRAVITY_CLI" plugin list)"
  host_ok=$?
  set -e
  if [[ "$host_ok" -eq 0 ]]; then
    host_ok=1
    if plugin_common_list_contains_ralph "$list_out"; then
      host_has=1
    fi
  else
    host_ok=0
  fi

  journal_json="$(plugin_common_journal_read "$PLUGIN_ANTIGRAVITY_RUNTIME" 2>/dev/null || true)"
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

# Best-effort host cleanup after a failed install. Never writes a journal.
plugin_antigravity_rollback_install() {
  local commands_file="${1:-}"
  if [[ -z "$commands_file" ]]; then
    commands_file="$(mktemp)"
    printf '[]\n' >"$commands_file"
  fi
  set +e
  plugin_common_host_run "$commands_file" -- \
    "$PLUGIN_ANTIGRAVITY_CLI" plugin uninstall "$PLUGIN_ANTIGRAVITY_PLUGIN_ID" >/dev/null
  set -e
  return 0
}

plugin_antigravity_install() {
  local package_root="${1:-}"
  local scope="${2:-user}"
  local dry_run="${3:-0}"
  local commands_file journal_tmp meta_line version source ec

  package_root="$(plugin_antigravity_package_root "$package_root")"
  scope="$(plugin_common_require_scope "$PLUGIN_ANTIGRAVITY_RUNTIME" "$scope")" || return $?
  # Validate host contract before any mutation; read-only (byte-preserving).
  plugin_antigravity_validate_package "$package_root" || return 1

  plugin_antigravity_preview "$package_root" "$scope"

  if [[ "$dry_run" == "1" ]]; then
    printf 'dry-run: no host mutation\n'
    return 0
  fi

  if plugin_common_cli_missing "$PLUGIN_ANTIGRAVITY_CLI"; then
    printf 'antigravity plugin: missing CLI (%s)\n' "$PLUGIN_ANTIGRAVITY_CLI" >&2
    return 1
  fi

  commands_file="$(mktemp)"
  printf '[]\n' >"$commands_file"

  set +e
  plugin_common_host_run "$commands_file" -- \
    "$PLUGIN_ANTIGRAVITY_CLI" plugin install "$package_root" >/dev/null
  ec=$?
  set -e
  if [[ "$ec" -ne 0 ]]; then
    printf 'antigravity plugin: install failed (exit %s); rolling back\n' "$ec" >&2
    plugin_antigravity_rollback_install "$commands_file"
    rm -f "$commands_file"
    return "$ec"
  fi

  meta_line="$(plugin_common_package_meta "$package_root")"
  version="${meta_line%%$'\t'*}"
  source="${meta_line#*$'\t'}"
  journal_tmp="$(mktemp)"
  jq -n \
    --arg runtime "$PLUGIN_ANTIGRAVITY_RUNTIME" \
    --arg scope "$scope" \
    --arg packageVersion "$version" \
    --arg packageSource "$source" \
    --arg packageRoot "$package_root" \
    --arg pluginId "$PLUGIN_ANTIGRAVITY_PLUGIN_ID" \
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
        targets: [$pluginId],
        registrations: {
          plugin: $pluginId
        },
        digests: {},
        commands: $commands[0]
      }
    ' >"$journal_tmp"
  plugin_common_journal_write "$PLUGIN_ANTIGRAVITY_RUNTIME" "$journal_tmp"
  rm -f "$commands_file" "$journal_tmp"
  printf 'antigravity plugin: installed %s\n' "$PLUGIN_ANTIGRAVITY_PLUGIN_ID"
}

plugin_antigravity_remove() {
  local package_root="${1:-}"
  local scope="${2:-user}"
  local dry_run="${3:-0}"
  local state commands_file ec

  package_root="$(plugin_antigravity_package_root "$package_root")"
  scope="$(plugin_common_require_scope "$PLUGIN_ANTIGRAVITY_RUNTIME" "$scope")" || return $?

  printf 'preview: Antigravity user-scope plugin remove\n'
  plugin_common_preview_line \
    "$PLUGIN_ANTIGRAVITY_CLI" plugin uninstall "$PLUGIN_ANTIGRAVITY_PLUGIN_ID"

  if [[ "$dry_run" == "1" ]]; then
    printf 'dry-run: no host mutation\n'
    return 0
  fi

  if plugin_common_cli_missing "$PLUGIN_ANTIGRAVITY_CLI"; then
    printf 'antigravity plugin: missing CLI (%s)\n' "$PLUGIN_ANTIGRAVITY_CLI" >&2
    return 1
  fi

  state="$(plugin_antigravity_status "$package_root" "$scope")"
  case "$state" in
    drifted)
      printf 'antigravity plugin: refuse remove (drifted / journal mismatch)\n' >&2
      return 1
      ;;
    unverifiable)
      printf 'antigravity plugin: refuse remove (unverifiable)\n' >&2
      return 1
      ;;
    absent)
      plugin_common_journal_clear "$PLUGIN_ANTIGRAVITY_RUNTIME" || true
      printf 'antigravity plugin: already absent\n'
      return 0
      ;;
  esac

  commands_file="$(mktemp)"
  printf '[]\n' >"$commands_file"
  set +e
  plugin_common_host_run "$commands_file" -- \
    "$PLUGIN_ANTIGRAVITY_CLI" plugin uninstall "$PLUGIN_ANTIGRAVITY_PLUGIN_ID" >/dev/null
  ec=$?
  set -e
  if [[ "$ec" -ne 0 ]]; then
    # Preserve journal on uninstall failure so ownership evidence remains.
    printf 'antigravity plugin: uninstall failed (exit %s); journal preserved\n' \
      "$ec" >&2
    rm -f "$commands_file"
    return "$ec"
  fi

  plugin_common_journal_clear "$PLUGIN_ANTIGRAVITY_RUNTIME"
  rm -f "$commands_file"
  printf 'antigravity plugin: removed %s\n' "$PLUGIN_ANTIGRAVITY_PLUGIN_ID"
}
