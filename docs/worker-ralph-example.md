<!--- Documented example for single-agent loop workflow -->
# Worker Ralph walkthrough

This example walks through creating a worker plan, running it, and inspecting outputs with the Cursor/Claude/Codex loops shared in this bundle.

## 1. Draft the plan

1. Copy the template:

   ```bash
   cp .ralph/plan.template PLAN.md
   ```

2. Replace placeholder sections with TODOs specific to your task. A plan entry should look like:

   ```markdown
   - [ ] Update `server/modules/auth/session.ts` to include an `issuedAt` timestamp (lint: `npm run lint`; test: `npm run test:server`). Expected artifact: `.agents/artifacts/{{ARTIFACT_NS}}/implementation-handoff.md`.
   ```

3. Include verification steps, files touched, and artifact outputs so that rerunning the loop can clearly mark completion.

## 2. Run the plan

1. Pick a runtime:

   - Cursor: `.cursor/ralph/run-plan.sh --plan PLAN.md --agent ralph-starter`
   - Claude: `.claude/ralph/run-plan.sh --plan PLAN.md --agent ralph-starter`
   - Codex: `.codex/ralph/run-plan.sh --plan PLAN.md --agent ralph-starter --non-interactive`

2. Supply overrides as needed:

   - Use `--agent <id>` to select another agent folder (must exist under `.cursor/agents` / `.claude/agents` / `.codex/agents`).
   - Set `CURSOR_PLAN_MODEL`, `CLAUDE_PLAN_MODEL`, or `CODEX_PLAN_MODEL` to pin models.
   - Provide `--select-agent` to trigger an interactive chooser (if in a TTY).

3. If the runner stops for human input (files like `pending-human.txt` or `HUMAN-INPUT-REQUIRED.md`), answer the question in the provided file, then rerun the same command so the first unchecked checkbox is retried.

## 3. Review outputs

- Logs: `.agents/logs/plan-runner-<agent>-*.log` contains combined stdout/stderr from the agent run.
- Artifacts: `.agents/artifacts/{{ARTIFACT_NS}}/` stores research, implementation handoffs, QA notes, or other docs referenced by your plan.
- Cleanup: `.ralph/cleanup-plan.sh <namespace>` removes `.agents/logs/<namespace>` and `.agents/artifacts/<namespace>/`. Use this before repeated runs if you need a clean slate.

## 4. Sample plan snippet

```markdown
- [ ] Analyze existing notification flow (`server/modules/notifications/**/*`). Document findings in `.agents/artifacts/{{ARTIFACT_NS}}/research.md` (lint: none; tests: none; validation: review notes).
- [ ] Update `client/src/components/NotificationList.tsx` to support throttled refresh requests (lint: `npm run lint:ui`; tests: `npm run test:ui`).
- [ ] Write implementation handoff `.agents/artifacts/{{ARTIFACT_NS}}/implementation-handoff.md` summarizing changes and verification steps.
```
