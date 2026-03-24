#!/usr/bin/env bash

set -euo pipefail

workspace=".ralph-workspace"
checksum_file="$workspace/.fixture-checksums"

mkdir -p "$workspace/artifacts/dashboard"
mkdir -p "$workspace/logs"

dashboard_orch_json_generator() {
  cat <<'INNER'
{
  "name": "dashboard-three-runtime",
  "namespace": "dashboard",
  "description": "Single orchestration across Cursor (research), Codex (implementation), and Claude (code-review) for a local dashboard.",
  "stages": [
    {
      "id": "research",
      "agent": "research",
      "runtime": "cursor",
      "planTemplate": ".ralph/plan.template",
      "plan": "docs/orchestration-plans/dashboard-01-requirements.plan.md",
      "inputArtifacts": [],
      "outputArtifacts": [
        {
          "path": ".ralph-workspace/artifacts/{{ARTIFACT_NS}}/research.md",
          "required": true,
          "description": "Research and requirements for the dashboard."
        }
      ],
      "artifacts": [
        {
          "path": ".ralph-workspace/artifacts/{{ARTIFACT_NS}}/research.md",
          "required": true
        }
      ]
    },
    {
      "id": "implementation",
      "agent": "implementation",
      "runtime": "codex",
      "planTemplate": ".ralph/plan.template",
      "plan": "docs/orchestration-plans/dashboard-02-implementation.plan.md",
      "inputArtifacts": [
        {
          "path": ".ralph-workspace/artifacts/{{ARTIFACT_NS}}/research.md"
        }
      ],
      "outputArtifacts": [
        {
          "path": ".ralph-workspace/artifacts/{{ARTIFACT_NS}}/implementation-handoff.md",
          "required": true,
          "description": "Implementation handoff: what was built, paths, how to run and verify."
        }
      ],
      "artifacts": [
        {
          "path": ".ralph-workspace/artifacts/{{ARTIFACT_NS}}/implementation-handoff.md",
          "required": true
        }
      ]
    },
    {
      "id": "review",
      "agent": "code-review",
      "runtime": "claude",
      "planTemplate": ".ralph/plan.template",
      "plan": "docs/orchestration-plans/dashboard-03-review.plan.md",
      "inputArtifacts": [
        {
          "path": ".ralph-workspace/artifacts/{{ARTIFACT_NS}}/research.md"
        },
        {
          "path": ".ralph-workspace/artifacts/{{ARTIFACT_NS}}/implementation-handoff.md"
        }
      ],
      "outputArtifacts": [
        {
          "path": ".ralph-workspace/artifacts/{{ARTIFACT_NS}}/code-review.md",
          "required": true,
          "description": "Code review vs requirements and implementation handoff."
        }
      ],
      "artifacts": [
        {
          "path": ".ralph-workspace/artifacts/{{ARTIFACT_NS}}/code-review.md",
          "required": true
        }
      ]
    }
  ]
}
INNER
}

dashboard_research_md_generator() {
  cat <<'INNER'
# Research Output
Placeholder research artifact.
INNER
}

dashboard_implementation_md_generator() {
  cat <<'INNER'
# Implementation Handoff
Placeholder implementation artifact.
INNER
}

dashboard_code_review_md_generator() {
  cat <<'INNER'
# Code Review Output
Placeholder code review artifact.
INNER
}

fixtures_paths=(
  "dashboard.orch.json"
  "$workspace/artifacts/dashboard/research.md"
  "$workspace/artifacts/dashboard/implementation-handoff.md"
  "$workspace/artifacts/dashboard/code-review.md"
)

fixtures_generators=(
  "dashboard_orch_json_generator"
  "dashboard_research_md_generator"
  "dashboard_implementation_md_generator"
  "dashboard_code_review_md_generator"
)

if [[ -f "$checksum_file" ]]; then
  while IFS=$'\t' read -r checksum path; do
    if [[ -n "$checksum" && -n "$path" ]]; then
      :
    fi
  done < "$checksum_file"
fi

lookup_previous_checksum() {
  local path="$1"
  [[ -f "$checksum_file" ]] || return 1
  awk -F $'\t' -v target="$path" '$2 == target { print $1; found = 1; exit } END { exit(found ? 0 : 1) }' "$checksum_file"
}

generate_fixture() {
  local path="$1"
  local generator="$2"
  local tmpfile
  local previous_checksum
  local checksum
  tmpfile=$(mktemp "$workspace/.fixture-temp.XXXXXX")
  "$generator" > "$tmpfile"
  checksum=$(shasum -a 256 "$tmpfile" | cut -d ' ' -f 1)

  previous_checksum=$(lookup_previous_checksum "$path" || true)

  if [[ "$checksum" == "$previous_checksum" && -f "$path" ]]; then
    rm -f "$tmpfile"
  else
    mkdir -p "$(dirname "$path")"
    mv "$tmpfile" "$path"
  fi

  printf '%s\t%s\n' "$checksum" "$path" >> "$checksum_tmp"
}

checksum_tmp=$(mktemp "$workspace/.fixture-checksums.XXXXXX")

for i in "${!fixtures_paths[@]}"; do
  generate_fixture "${fixtures_paths[$i]}" "${fixtures_generators[$i]}"
done

mv "$checksum_tmp" "$checksum_file"
