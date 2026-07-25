#!/usr/bin/env bats

setup() {
  source bundle/.ralph/bash-lib/agent-source/frontmatter.sh
  FILE="agents/agents/architect.md"
}

expected_scalar() {
  local key="$1"
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
  ' "$FILE"
}

expected_model() {
  local runtime="$1"
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
  ' "$FILE"
}

expected_list() {
  local key="$1"
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
  ' "$FILE"
}

expected_body() {
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
  ' "$FILE"
}

expected_artifact_json() {
  local entry="$1"
  local path required kind to
  IFS='|' read -r path required kind to <<< "$entry"
  required="${required:-required}"
  kind="${kind:-}"
  to="${to:-}"

  printf '{'
  printf '"path": %s' "$(expected_json_string "$path")"
  if [[ "$required" == "optional" ]]; then
    printf ', "required": false'
  else
    printf ', "required": true'
  fi
  if [[ -n "$kind" ]]; then
    printf ', "kind": %s' "$(expected_json_string "$kind")"
  fi
  if [[ -n "$to" ]]; then
    printf ', "to": %s' "$(expected_json_string "$to")"
  fi
  printf '}'
}

expected_json_string() {
  local value="$1"
  if command -v python3 >/dev/null 2>&1; then
    python3 -c 'import json,sys; print(json.dumps(sys.argv[1]))' "$value"
  else
    local s="$value"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    s="${s//$'\n'/\\n}"
    printf '"%s"' "$s"
  fi
}

@test "scalar parser matches awk" {
  expected="$(expected_scalar description)"
  run agent_source_fm_scalar "$FILE" description
  [ "$status" -eq 0 ]
  [ "$output" = "$expected" ]
}

@test "model parser matches awk" {
  expected="$(expected_model claude)"
  run agent_source_fm_model "$FILE" claude
  [ "$status" -eq 0 ]
  [ "$output" = "$expected" ]
}

@test "list parser matches awk" {
  expected="$(expected_list rules)"
  run agent_source_fm_list "$FILE" rules
  [ "$status" -eq 0 ]
  [ "$output" = "$expected" ]
}

@test "body parser matches awk" {
  expected="$(expected_body)"
  run agent_source_fm_body "$FILE"
  [ "$status" -eq 0 ]
  [ "$output" = "$expected" ]
}

@test "artifact parser matches awk" {
  entry="$(agent_source_fm_list "$FILE" output_artifacts | head -n1)"
  expected="$(expected_artifact_json "$entry")"
  run agent_source_fm_artifact "$entry"
  [ "$status" -eq 0 ]
  [ "$output" = "$expected" ]
}
