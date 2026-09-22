# Runs and workflows: follow work to completion

A workflow is a reusable delivery process. A run is one execution of that process. Use **Workflows** to choose and start the process; use **Runs** to see what happened and take the next allowed action.

## Start and inspect a workflow

Open **Workflows** to browse available workflows by source. The detail page shows its purpose, stages, and recent runs. Start a run from there, provide a concrete brief, and confirm the command before it begins.

Bundled workflows are read-only. If the dashboard offers **Customize for this project** or **Customize globally**, it creates your own copy; it does not alter the bundled default. Project copies take precedence over global copies, which take precedence over bundled ones.

## Read run status

Open **Runs** and filter by active, waiting, failed, or completed. Select a run ID for its stage map, event timeline, artifacts, and next action.

| Status | What to do |
| --- | --- |
| **Active** | Let the run continue; inspect the timeline if it seems unexpectedly slow. |
| **Waiting** | Open the run and respond to its outstanding approval or input request. |
| **Failed** | Read the stage evidence and error, correct the cause, then use the action the page permits. |
| **Completed** | Review the final artifacts and outcome before considering the work done. |

The action panel is authoritative. It only presents actions Ralph allows for the current run state.

## Approvals, inputs, and rework

An approval or input request is a real operator action, not a request that an agent can satisfy in prose. Open the pending action card, choose the decision, add a message when required, and send it. If the page says the answer is awaiting consumption, select **Resume**.

For a change request, the run may require you to reset a specific stage. Add useful feedback, reset the named stage, and then resume as prompted. Do not cancel and restart just to give ordinary review feedback; doing so loses the durable context of the existing run.

## Plans and evidence

The **Plans** area shows checkbox progress, the current TODO, source, and related artifacts. A completed-looking plan is not enough by itself: use the run’s stage evidence and required gates to decide whether the requested outcome was actually delivered.
