#!/usr/bin/env bash

set -euo pipefail

mkdir -p .agents/orchestration-plans/dashboard
mkdir -p .agents/artifacts/dashboard
mkdir -p .agents/logs

cat > .agents/orchestration-plans/dashboard/dashboard.orch.json << 'EOF'
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
      "plan": ".agents/orchestration-plans/dashboard/dashboard-01-requirements.plan.md",
      "inputArtifacts": [],
      "outputArtifacts": [
        {
          "path": ".agents/artifacts/{{ARTIFACT_NS}}/research.md",
          "required": true,
          "description": "Research and requirements for the dashboard."
        }
      ],
      "artifacts": [
        {
          "path": ".agents/artifacts/{{ARTIFACT_NS}}/research.md",
          "required": true
        }
      ]
    },
    {
      "id": "implementation",
      "agent": "implementation",
      "runtime": "codex",
      "planTemplate": ".ralph/plan.template",
      "plan": ".agents/orchestration-plans/dashboard/dashboard-02-implementation.plan.md",
      "inputArtifacts": [
        {
          "path": ".agents/artifacts/{{ARTIFACT_NS}}/research.md"
        }
      ],
      "outputArtifacts": [
        {
          "path": ".agents/artifacts/{{ARTIFACT_NS}}/implementation-handoff.md",
          "required": true,
          "description": "Implementation handoff: what was built, paths, how to run and verify."
        }
      ],
      "artifacts": [
        {
          "path": ".agents/artifacts/{{ARTIFACT_NS}}/implementation-handoff.md",
          "required": true
        }
      ]
    },
    {
      "id": "review",
      "agent": "code-review",
      "runtime": "claude",
      "planTemplate": ".ralph/plan.template",
      "plan": ".agents/orchestration-plans/dashboard/dashboard-03-review.plan.md",
      "inputArtifacts": [
        {
          "path": ".agents/artifacts/{{ARTIFACT_NS}}/research.md"
        },
        {
          "path": ".agents/artifacts/{{ARTIFACT_NS}}/implementation-handoff.md"
        }
      ],
      "outputArtifacts": [
        {
          "path": ".agents/artifacts/{{ARTIFACT_NS}}/code-review.md",
          "required": true,
          "description": "Code review vs requirements and implementation handoff."
        }
      ],
      "artifacts": [
        {
          "path": ".agents/artifacts/{{ARTIFACT_NS}}/code-review.md",
          "required": true
        }
      ]
    }
  ]
}
EOF

cat > .agents/orchestration-plans/dashboard/dashboard-01-requirements.plan.md << 'EOF'
# Dashboard Requirements Plan

## Overview
Research and document requirements for the dashboard.

## Objectives
- Analyze requirements
- Document constraints
- Plan implementation
EOF

cat > .agents/orchestration-plans/dashboard/dashboard-02-implementation.plan.md << 'EOF'
# Dashboard Implementation Plan

## Overview
Implement the dashboard based on requirements.

## Objectives
- Build dashboard components
- Implement functionality
- Prepare handoff
EOF

cat > .agents/orchestration-plans/dashboard/dashboard-03-review.plan.md << 'EOF'
# Dashboard Code Review Plan

## Overview
Review the dashboard implementation.

## Objectives
- Review code quality
- Verify requirements met
- Document findings
EOF

cat > .agents/artifacts/dashboard/research.md << 'EOF'
# Research Output
Placeholder research artifact.
EOF

cat > .agents/artifacts/dashboard/implementation-handoff.md << 'EOF'
# Implementation Handoff
Placeholder implementation artifact.
EOF

cat > .agents/artifacts/dashboard/code-review.md << 'EOF'
# Code Review Output
Placeholder code review artifact.
EOF
