---
name: PLAN_TITLE_HERE
overview: PLAN_OVERVIEW_HERE
execution: standard
instructions: Execute one TODO at a time. After each, run the verification steps this project expects (build, test, lint, or equivalents as documented in README or below); fix until they pass, then mark `[x]` and continue. If verification fails, end with `TODO_VERIFICATION: FAIL: <reason>` so the runner reopens the TODO and retries it within the existing budget. For additional context see the original plan at PATH_TO_PLAN (if exists)

todos:
  - id: example-task
    content: This is a task to do something.
    verification: Run the verification steps that prove this task is complete (build, test, lint, or equivalents). If they fail, end with `TODO_VERIFICATION: FAIL: <reason>` so the runner reopens the TODO and retries it within the existing budget.
    status: pending
  - id: example-task-2
    content: This is another task to do something else.
    verification: Run the verification steps that prove this task is complete (build, test, lint, or equivalents). If they fail, end with `TODO_VERIFICATION: FAIL: <reason>` so the runner reopens the TODO and retries it within the existing budget.
    status: pending
isProject: false
---
