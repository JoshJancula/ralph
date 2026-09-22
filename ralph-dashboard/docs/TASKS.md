# Tasks: turn an outcome into runnable work

A task is a short work request that the dashboard can route into a Ralph workflow. It is not a chat prompt: the clearer the task, the more reliable the resulting run.

## Create a useful task

In **Tasks**, choose **New task** and fill in:

- **Title:** the outcome in one line. For example, “Add CSV export to the report page.”
- **Description:** the relevant context, constraints, and desired behavior.
- **Acceptance criteria:** observable checks, one per line. For example, “Export includes the currently filtered rows” and “`npm test` passes.”
- **Workflow:** select the delivery flow that should execute the work. **Auto** sends the task through triage before it is worked.
- **Status:** the board column that describes where the task is now.
- **Queue and target:** choose the project queue and the project where work should happen.

Use **This project** for work that belongs to the selected project. Use the global inbox only for work you intend to route later.

## Work the board

Board view is best for prioritizing work; List view is better for scanning details. Changing a task’s status moves it immediately. Use **Manage statuses** to add or remove columns. Move tasks out of a column before deleting that status.

Blocked tasks can show an automatic recommendation or the outcome of their most recent attempt. Open the task to refine its description, acceptance criteria, workflow, or target before trying again.

## Ready means ready to automate

The built-in task worker can pull tasks from one chosen status, normally `ready`. It runs the oldest eligible work first.

- A task with a selected workflow runs through that workflow.
- A task with **Auto** or no workflow is triaged first, then returned with a recommendation for a later pass.
- A failed task returns to the worker’s source status until it has failed three times.

Do not put incomplete briefs in the worker’s source column. If someone cannot tell what success looks like from the task, leave it in backlog and refine it first.
