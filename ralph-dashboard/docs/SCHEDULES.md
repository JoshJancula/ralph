# Schedules: automate work safely

Schedules run only while the Ralph Dashboard server is online. They can either run the built-in task worker against a board column or run one workflow with a fixed brief.

## Before you schedule anything

Run the workflow manually once. Confirm that it uses the right project, creates the expected evidence, and handles approvals as you expect. A schedule makes repeatable work convenient; it does not make an unclear workflow safe.

## Create a task worker

1. Open **Schedules** and choose **New schedule**.
2. Select **Task worker (built-in)**.
3. Choose whether it works **one task at a time** or all matching tasks up to a limit.
4. Select the source status, such as `ready`.
5. Optionally add extra instructions that should accompany every task.
6. Pick a preset or enter a five-field cron expression, set the timezone, and use **Preview next runs**.
7. Save the schedule.

Parallel task runs share the project working tree unless the workflow isolates its work. Start with one-at-a-time execution if tasks may touch the same files.

## Schedule one workflow

Instead of the task worker, select a workflow from **Runs**. Enter the fixed instructions that every scheduled run should receive, then choose timing and timezone. This is useful for repeatable jobs such as a weekday review or a regular maintenance check.

## Operate a schedule

Each schedule card shows whether it is enabled, what it runs, its cron expression and timezone, and its next and last run. Use:

- **Run now** to test the current configuration.
- **Pause** to stop future starts without deleting the setup.
- **Enable** to resume a paused schedule.
- **Edit** to change its target, instructions, timing, or concurrency.

Schedules enforce their configured concurrency limit and pause themselves after repeated failures. Read the failure notice, fix the underlying task or workflow, test with **Run now**, and then re-enable the schedule.
