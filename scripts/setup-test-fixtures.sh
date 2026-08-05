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

savings_plan_key="savings-report"
savings_logs_dir="$workspace/logs/$savings_plan_key"

savings_plan_summary_generator() {
  cat <<JSON
{
  "schema_version": 1,
  "kind": "plan_usage_summary",
  "plan": "$savings_plan_key.md",
  "plan_key": "$savings_plan_key",
  "artifact_ns": "$savings_plan_key",
  "stage_id": "main",
  "model": "claude-sonnet-4-6",
  "runtime": "claude",
  "invocations": 1,
  "todos_done": 1,
  "todos_total": 1,
  "started_at": "2026-06-14T10:00:00Z",
  "ended_at": "2026-06-14T10:01:00Z",
  "elapsed_seconds": 60,
  "input_tokens": 100,
  "output_tokens": 50,
  "cache_creation_input_tokens": 0,
  "cache_read_input_tokens": 100,
  "tool_calls_total": 5,
  "cache_hit_ratio": 0.5,
  "compaction_measured_not_applied_bytes": 133,
  "verification_bytes_suppressed": 77,
  "byte_savings_by_path": {
    "hook_compaction": {
      "pre_optimization_bytes": 500,
      "post_optimization_bytes": 400,
      "saved_bytes": 100,
      "hidden_from_context": 0,
      "count": 2,
      "savings_percent": 20.0,
      "pre_optimization_tokens": 200,
      "post_optimization_tokens": 160,
      "saved_tokens": 40,
      "savings_percent_tokens": 20.0,
      "token_cap_triggers": 1
    },
    "proxy_shell_compaction": {
      "pre_optimization_bytes": 300,
      "post_optimization_bytes": 250,
      "saved_bytes": 50,
      "hidden_from_context": 0,
      "count": 1,
      "savings_percent": 16.7,
      "pre_optimization_tokens": 120,
      "post_optimization_tokens": 100,
      "saved_tokens": 20,
      "savings_percent_tokens": 16.7,
      "token_cap_triggers": 0
    }
  }
}
JSON
}

second_plan_key="other-plan"
second_logs_dir="$workspace/logs/$second_plan_key"

second_plan_summary_generator() {
  cat <<JSON
{
  "schema_version": 1,
  "kind": "plan_usage_summary",
  "plan": "$second_plan_key.md",
  "plan_key": "$second_plan_key",
  "artifact_ns": "$second_plan_key",
  "stage_id": "main",
  "model": "claude-sonnet-4-6",
  "runtime": "claude",
  "invocations": 1,
  "todos_done": 1,
  "todos_total": 1,
  "started_at": "2026-06-14T11:00:00Z",
  "ended_at": "2026-06-14T11:01:00Z",
  "elapsed_seconds": 60,
  "input_tokens": 50,
  "output_tokens": 25,
  "cache_creation_input_tokens": 0,
  "cache_read_input_tokens": 50,
  "tool_calls_total": 3,
  "cache_hit_ratio": 0.4,
  "compaction_measured_not_applied_bytes": 66,
  "verification_bytes_suppressed": 38,
  "byte_savings_by_path": {
    "hook_compaction": {
      "pre_optimization_bytes": 250,
      "post_optimization_bytes": 200,
      "saved_bytes": 50,
      "hidden_from_context": 0,
      "count": 1,
      "savings_percent": 20.0,
      "pre_optimization_tokens": 100,
      "post_optimization_tokens": 80,
      "saved_tokens": 20,
      "savings_percent_tokens": 20.0,
      "token_cap_triggers": 0
    }
  }
}
JSON
}

savings_invocations_generator() {
  cat <<JSON
{
  "schema_version": 1,
  "kind": "plan_invocation_usage_history",
  "invocations": [
    {
      "iteration": 1,
      "model": "claude-sonnet-4-6",
      "runtime": "claude",
      "plan_key": "$savings_plan_key",
      "stage_id": "main",
      "elapsed_seconds": 60,
      "input_tokens": 100,
      "output_tokens": 50,
      "cache_creation_input_tokens": 0,
      "cache_read_input_tokens": 100,
      "max_turn_total_tokens": 900,
      "tool_calls_total": 5,
      "native_read_like_calls": 2,
      "ralph_proxy_calls": 3,
      "byte_savings_by_path": {
        "hook_compaction": {
          "pre_optimization_bytes": 500,
          "post_optimization_bytes": 400,
          "saved_bytes": 100,
          "hidden_from_context": 0,
          "count": 2,
          "pre_optimization_tokens": 200,
          "post_optimization_tokens": 160,
          "saved_tokens": 40,
          "savings_percent": 20.0,
          "savings_percent_tokens": 20.0,
          "token_cap_triggers": 1
        },
        "proxy_shell_compaction": {
          "pre_optimization_bytes": 300,
          "post_optimization_bytes": 250,
          "saved_bytes": 50,
          "hidden_from_context": 0,
          "count": 1,
          "pre_optimization_tokens": 120,
          "post_optimization_tokens": 100,
          "saved_tokens": 20,
          "savings_percent": 16.7,
          "savings_percent_tokens": 16.7,
          "token_cap_triggers": 0
        }
      }
    }
  ]
}
JSON
}

second_invocations_generator() {
  cat <<JSON
{
  "schema_version": 1,
  "kind": "plan_invocation_usage_history",
  "invocations": [
    {
      "iteration": 1,
      "model": "claude-sonnet-4-6",
      "runtime": "claude",
      "plan_key": "$second_plan_key",
      "stage_id": "main",
      "elapsed_seconds": 60,
      "input_tokens": 50,
      "output_tokens": 25,
      "cache_creation_input_tokens": 0,
      "cache_read_input_tokens": 50,
      "max_turn_total_tokens": 900,
      "tool_calls_total": 3,
      "native_read_like_calls": 1,
      "ralph_proxy_calls": 2,
      "byte_savings_by_path": {
        "hook_compaction": {
          "pre_optimization_bytes": 250,
          "post_optimization_bytes": 200,
          "saved_bytes": 50,
          "hidden_from_context": 0,
          "count": 1,
          "pre_optimization_tokens": 100,
          "post_optimization_tokens": 80,
          "saved_tokens": 20,
          "savings_percent": 20.0,
          "savings_percent_tokens": 20.0,
          "token_cap_triggers": 0
        }
      }
    }
  ]
}
JSON
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

fixtures_paths+=(
  "$savings_logs_dir/plan-usage-summary.json"
  "$savings_logs_dir/invocation-usage.json"
  "$second_logs_dir/plan-usage-summary.json"
  "$second_logs_dir/invocation-usage.json"
)

fixtures_generators+=(
  "savings_plan_summary_generator"
  "savings_invocations_generator"
  "second_plan_summary_generator"
  "second_invocations_generator"
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
