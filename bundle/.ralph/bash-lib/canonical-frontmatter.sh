#!/usr/bin/env bash
#
# Canonical markdown frontmatter parsers for rules/skills sync and residual
# profile helpers. Role files use bash-lib/role/role-frontmatter.sh instead.
#
## Source guard
if [[ -n "${RALPH_CANONICAL_FRONTMATTER_LOADED:-}" ]]; then
  return 0
fi
RALPH_CANONICAL_FRONTMATTER_LOADED=1

agent_source_fm_scalar() {
  local file="$1"
  local key="$2"
  awk -v key="$key" '
    BEGIN { in_frontmatter = 0 }
    /^---$/ {
      if (in_frontmatter == 0) {
        in_frontmatter = 1
        next
      }
      exit
    }
    in_frontmatter {
      if ($0 ~ "^[[:space:]]*" key ":[[:space:]]*") {
        sub("^[[:space:]]*" key ":[[:space:]]*", "", $0)
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", $0)
        if ($0 ~ /^".*"$/) {
          sub(/^"/, "", $0)
          sub(/"$/, "", $0)
        }
        print $0
        exit
      }
    }
  ' "$file"
}

agent_source_fm_model() {
  local file="$1"
  local runtime="$2"
  awk -v key="$runtime" '
    BEGIN { in_frontmatter = 0; in_models = 0 }
    /^---$/ {
      if (in_frontmatter == 0) {
        in_frontmatter = 1
        next
      }
      exit
    }
    in_frontmatter {
      if ($0 ~ "^[[:space:]]*models:[[:space:]]*$") {
        in_models = 1
        next
      }
      if (in_models) {
        if ($0 ~ "^[^[:space:]]") {
          exit
        }
        if ($0 ~ "^[[:space:]]*" key ":[[:space:]]*") {
          sub("^[[:space:]]*" key ":[[:space:]]*", "", $0)
          gsub(/^[[:space:]]+|[[:space:]]+$/, "", $0)
          if ($0 ~ /^".*"$/) {
            sub(/^"/, "", $0)
            sub(/"$/, "", $0)
          }
          print $0
          exit
        }
      }
    }
  ' "$file"
}

agent_source_fm_list() {
  local file="$1"
  local key="$2"
  awk -v key="$key" '
    BEGIN { in_frontmatter = 0; in_list = 0 }
    /^---$/ {
      if (in_frontmatter == 0) {
        in_frontmatter = 1
        next
      }
      exit
    }
    in_frontmatter {
      if ($0 ~ "^[[:space:]]*" key ":[[:space:]]*$") {
        in_list = 1
        next
      }
      if (in_list) {
        if ($0 ~ "^[^[:space:]]") {
          exit
        }
        if ($0 ~ "^[[:space:]]*-[[:space:]]*") {
          sub("^[[:space:]]*-[[:space:]]*", "", $0)
          gsub(/^[[:space:]]+|[[:space:]]+$/, "", $0)
          if ($0 ~ /^".*"$/) {
            sub(/^"/, "", $0)
            sub(/"$/, "", $0)
          }
          print $0
        }
      }
    }
  ' "$file"
}

agent_source_fm_body() {
  local file="$1"
  awk '
    BEGIN { in_frontmatter = 0; body = 0 }
    /^---$/ {
      if (in_frontmatter == 0) {
        in_frontmatter = 1
        next
      }
      body = 1
      next
    }
    body { print }
  ' "$file"
}

agent_source_fm_artifact() {
  local entry="$1"
  local path required kind="" to="" provenance=""
  local -a parts
  IFS='|' read -ra parts <<< "$entry"
  path="${parts[0]}"
  required="${parts[1]:-required}"
  local i seg
  for ((i=2; i<${#parts[@]}; i++)); do
    seg="${parts[i]}"
    [[ -z "$seg" ]] && continue
    if [[ "$seg" == provenance=* ]]; then
      provenance="${seg#provenance=}"
    elif [[ -z "$kind" ]]; then
      kind="$seg"
    elif [[ -z "$to" ]]; then
      to="$seg"
    fi
  done
  kind="${kind:-}"
  to="${to:-}"

  printf '{'
  printf '"path": %s' "$(agent_source_json_string "$path")"
  if [[ "$required" == "optional" ]]; then
    printf ', "required": false'
  else
    printf ', "required": true'
  fi
  if [[ -n "$kind" ]]; then
    printf ', "kind": %s' "$(agent_source_json_string "$kind")"
  fi
  if [[ -n "$to" ]]; then
    printf ', "to": %s' "$(agent_source_json_string "$to")"
  fi
  if [[ -n "$provenance" ]]; then
    printf ', "provenance": %s' "$(agent_source_json_string "$provenance")"
  fi
  printf '}'
}

agent_source_json_string() {
  local value="$1"
  # Fast path: for plain printable-ASCII values, pure-bash escaping is byte-identical
  # to python's json.dumps, so skip the ~80ms interpreter startup. Values containing
  # control bytes or non-ASCII still go through python3 so \uXXXX escaping matches.
  # LC_ALL is localized so the byte-range glob below uses C collation.
  local LC_ALL=C
  case "$value" in
    *[!\ -~]*) ;;
    *)
      local s="$value"
      s="${s//\\/\\\\}"
      s="${s//\"/\\\"}"
      printf '"%s"' "$s"
      return 0
      ;;
  esac
  if command -v python3 >/dev/null 2>&1; then
    python3 -c 'import json,sys; print(json.dumps(sys.argv[1]))' "$value"
  else
    local s="$value"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    s="${s//$'\n'/\n}"
    printf '"%s"' "$s"
  fi
}

# Profile mcp_servers parsing was removed. Fail closed when the key is present;
# otherwise emit nothing (no normalized MCP context fields).
agent_source_fm_mcp_servers() {
  local file="$1"
  if [[ ! -r "$file" ]]; then
    return 0
  fi
  if awk '
    NR == 1 && $0 == "---" { fm = 1; next }
    fm && $0 == "---" { exit }
    fm && /^mcp_servers[[:space:]]*:/ { found = 1; exit }
    END { exit found ? 0 : 1 }
  ' "$file"; then
    echo "mcp_servers was removed from Ralph profiles. Configure MCP in native runtime settings. Run: ralph migrate agents-to-roles" >&2
    return 1
  fi
  return 0
}
