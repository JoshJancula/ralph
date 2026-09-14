#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF' >&2
Usage: validate-consensus-result.sh <result-file>
Validate a consensus aggregation result JSON against the consensus-result schema.
EOF
  exit 1
}

if [[ $# -ne 1 ]]; then
  usage
fi

result_file="$1"

if [[ "$result_file" == --* ]]; then
  usage
fi

if [[ ! -f "$result_file" ]]; then
  echo "Consensus result validation failed: file not found: $result_file" >&2
  exit 1
fi

root_type="$(jq -r 'type' "$result_file" 2>/dev/null || true)"
if [[ "$root_type" != "object" ]]; then
  echo "Consensus result validation failed: root must be an object" >&2
  exit 1
fi

for key in schemaVersion nodeId policy decision voters; do
  if ! jq -e "has(\"$key\")" "$result_file" >/dev/null 2>&1; then
    echo "Consensus result validation failed: missing required field $key" >&2
    exit 1
  fi
done

schema_version="$(jq -r '.schemaVersion' "$result_file")"
if [[ "$schema_version" != "1" ]]; then
  echo "Consensus result validation failed: schemaVersion must be 1" >&2
  exit 1
fi

if ! jq -e '.nodeId | type == "string" and length > 0' "$result_file" >/dev/null 2>&1; then
  echo "Consensus result validation failed: nodeId must be a non-empty string" >&2
  exit 1
fi

if ! jq -e '.policy | type == "string" and length > 0' "$result_file" >/dev/null 2>&1; then
  echo "Consensus result validation failed: policy must be a non-empty string" >&2
  exit 1
fi

if ! jq -e '.decision | IN("approved", "changes-required", "escalate")' "$result_file" >/dev/null 2>&1; then
  echo "Consensus result validation failed: decision must be one of approved, changes-required, escalate" >&2
  exit 1
fi

if ! jq -e '.voters | type == "array" and length > 0' "$result_file" >/dev/null 2>&1; then
  echo "Consensus result validation failed: voters must be a non-empty array" >&2
  exit 1
fi

while IFS= read -r voter; do
  [ -n "$voter" ] || continue
  voter_id="$(printf '%s' "$voter" | jq -r '.voterId // empty')"
  if [[ -z "$voter_id" ]]; then
    echo "Consensus result validation failed: voter missing required field voterId" >&2
    exit 1
  fi
  if ! printf '%s' "$voter" | jq -e 'has("runtime") and (.runtime | type == "string" and length > 0)' >/dev/null 2>&1; then
    echo "Consensus result validation failed: voter $voter_id missing required field runtime" >&2
    exit 1
  fi
  if ! printf '%s' "$voter" | jq -e '.status | IN("approved", "changes-required", "error")' >/dev/null 2>&1; then
    echo "Consensus result validation failed: voter $voter_id status must be one of approved, changes-required, error" >&2
    exit 1
  fi
  if printf '%s' "$voter" | jq -e 'has("confidence")' >/dev/null 2>&1; then
    if ! printf '%s' "$voter" | jq -e '.confidence | type == "number" and . >= 0 and . <= 1' >/dev/null 2>&1; then
      echo "Consensus result validation failed: voter $voter_id confidence must be a number between 0 and 1 inclusive" >&2
      exit 1
    fi
  fi
done < <(jq -c '.voters[]' "$result_file")

if jq -e 'has("agreement")' "$result_file" >/dev/null 2>&1; then
  if ! jq -e '.agreement | type == "number" and . >= 0 and . <= 1' "$result_file" >/dev/null 2>&1; then
    echo "Consensus result validation failed: agreement must be a number between 0 and 1 inclusive" >&2
    exit 1
  fi
fi

if jq -e 'has("dissent")' "$result_file" >/dev/null 2>&1; then
  if ! jq -e '.dissent | type == "array"' "$result_file" >/dev/null 2>&1; then
    echo "Consensus result validation failed: dissent must be an array" >&2
    exit 1
  fi
fi
