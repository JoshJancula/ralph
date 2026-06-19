#!/usr/bin/env bash
#
# Canonical frontmatter parsers shared by the agent-source resolver.
#
## Source guard
if [[ -n "${RALPH_AGENT_SOURCE_FRONTMATTER_LOADED:-}" ]]; then
  return 0
fi
RALPH_AGENT_SOURCE_FRONTMATTER_LOADED=1

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
  local path required kind to
  IFS='|' read -r path required kind to <<< "$entry"
  required="${required:-required}"
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
  printf '}'
}

agent_source_json_string() {
  local value="$1"
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

# Read the raw mcp_servers YAML frontmatter and emit one compact JSON object per
# entry using the canonical parser. Returns empty output when the key is absent.
agent_source_fm_mcp_servers() {
  local file="$1"
  local mcp_script
  mcp_script="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/python/agent-config-mcp.py"
  if [[ ! -r "$file" ]] || [[ ! -f "$mcp_script" ]]; then
    return 0
  fi
  if command -v python3 >/dev/null 2>&1; then
    python3 "$mcp_script" --frontmatter "$file" 2>/dev/null || true
  fi
}
