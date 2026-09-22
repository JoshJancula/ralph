# Start here: Ralph Dashboard

Ralph Dashboard is the place to queue work, run Ralph workflows, and see what needs your attention. Start with **Tasks** when you have work to describe; start with **Workflows** when you already know the workflow and want to run it now.

Ralph itself is **CLI-first**: plans and workflows run through `ralph` in the terminal, and the dashboard visualizes that state. Agent **skills, rules, and MCP servers are configured per project** in your runtime's native directories; Ralph consumes that configuration when it invokes the runtime. Read [How Ralph fits together](HOW_RALPH_FITS_TOGETHER.md) for what the harness does (killswitch, compaction, the plan/workflow runner) versus what you still need to tune yourself.

## Your first task

1. Choose the project in the project switcher at the top of the page.
2. Open **Tasks** and select **New task**.
3. Give the task a concrete title, useful context, and acceptance criteria that someone can verify.
4. Choose a workflow. Choose **Auto** only when you want triage to recommend one later.
5. Set a status and save the task.

The task board is your queue. Move a task by changing its status. The status columns are configurable from **Manage statuses**.

## Start a workflow now

1. Open **Workflows** and select a workflow.
2. Read its purpose and stage map. Use a workflow that fits the outcome, not just a similar name.
3. Choose **Start**, enter the work brief, and review the command shown in the confirmation step.
4. Confirm the start, then open the run to follow its progress.

Runs are durable: you can close the browser and return later. The **Home** page puts waiting approvals, failed verification, and stalled work ahead of ordinary active runs.

## What each area is for

| Area | Use it for |
| --- | --- |
| **Home** | The next thing that needs an operator decision or follow-up. |
| **Tasks** | A prioritized queue of outcomes to deliver. |
| **Schedules** | Run a task worker or a fixed workflow at a chosen time. |
| **Runs** | Inspect every workflow execution and take the permitted next action. |
| **Plans** | Inspect plan progress, current TODOs, source, and related artifacts. |
| **Workflows** | Browse, start, and—where allowed—customize reusable delivery flows. |
| **Insights** | Review tokens, elapsed time, tool calls, and usage trends. |

See also [How Ralph fits together](HOW_RALPH_FITS_TOGETHER.md) for CLI-first expectations, per-project agent configuration, and what the dashboard is (and is not) responsible for.

## A good operating rhythm

Check **Home** first. Resolve an approval or answer an input request before starting more work. Keep task descriptions specific, and put pass/fail expectations in acceptance criteria. Check **Runs** after a task worker or workflow begins, especially when a run is waiting or failed.

For unattended work, create a schedule only after you have successfully run the same workflow manually.
