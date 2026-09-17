# Help and troubleshooting

## A control is missing or disabled

Starting, cancelling, responding to, or editing workflow work requires the dashboard server to be running on its local loopback address. If the run controls are disabled, open the dashboard locally rather than through a remote hostname or proxy.

## I cannot find my project

Use the project switcher in the header. The dashboard only shows registered projects and their visible workspaces. Select the intended project before creating a task, customizing a workflow, or starting a project-scoped run.

## My run is waiting

Open the run from **Home** or **Runs**. Find the highlighted next action or pending action card, make the decision, and use **Resume** if the page asks you to. Waiting is expected for an approval or a request for information; it is not a failed run.

## My run failed

Open the run detail and find the failed stage and its timeline evidence. Fix the stated problem in the task, workflow, project, or environment. Then use the available **Resume** or **Reset** action. Reset is used when the workflow requires a fresh attempt at a particular stage.

## My schedule did not run

Check that the dashboard server was online at the scheduled time, the schedule is enabled, and its timezone and next run are correct. Review its failure notice and use **Run now** to test after making a change. A paused schedule remains saved but does not start work.

## I do not see recent usage

**Insights** fills in after plans or workflows have run in the selected scope. Confirm the selected project and any filters, then use **Refresh**. It tracks tokens, elapsed time, and tool calls from recorded runs; it cannot show activity that never reached the dashboard’s workspace.

## I need help interpreting the current state

Use the **Ask** button in the lower-right corner. The assistant starts from the live workflows, runs, tasks, and schedules in this installation. It can read more detail when needed. Any action that changes state is shown as a confirmation card; assistant text alone never starts, cancels, schedules, or creates work.
