# Stage plan: qa

## Execution instructions
Use the toolchain this repository documents, then run the test or QA commands specified in this plan or in the project README / AGENTS.md so checks validate the latest changes.

## Todo granularity
Each todo must represent one logical, independently verifiable unit of work, not one keystroke.
- Good: `Update plan-todo.sh to preserve yaml-frontmatter outside the todo block while adding consolidation logging.`
- Bad: `Change one line in plan-todo.sh.`

## Context
Describe how this QA stage uses the information captured in `implementation-handoff.md` to confirm the implementation works as expected.

Artifact namespace: {{ARTIFACT_NS}}

## TODOs
{{TODOS}}

## Additional context
{{ADDITIONAL_CONTEXT}}

## Output artifact
Write `qa-report.md` with these sections: Test coverage summary, Findings, Pass/fail status, and Recommended follow-up actions.
