#!/usr/bin/env bash

set -euo pipefail

mkdir -p .ralph-workspace/artifacts/dashboard
mkdir -p .ralph-workspace/logs

cat > dashboard.orch.json << 'EOF'
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
EOF


cat > .ralph-workspace/artifacts/dashboard/research.md << 'EOF'
# Research Output
Placeholder research artifact.
EOF

cat > .ralph-workspace/artifacts/dashboard/implementation-handoff.md << 'EOF'
# Implementation Handoff
Placeholder implementation artifact.
EOF

cat > .ralph-workspace/artifacts/dashboard/code-review.md << 'EOF'
# Code Review Output
Placeholder code review artifact.
EOF
