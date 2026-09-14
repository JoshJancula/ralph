<!-- GENERATED from bundle/.ralph/plugin-inputs/workflows/ralph-workflow.md by scripts/sync-plugin-assets.sh - edit the canonical file -->
---
name: ralph-workflow
description: Author, inspect, and operate Ralph Sequential and Dependency workflows with public create/inspect/start/runs/status/actions/resume/reset/recover commands.
---

# ralph-workflow

Ralph plugin workflow for reusable SDLC workflows. Prefer public verbs only.
Do not invent graph/orchestrate/role routes. Never call `ensure`, never run
`install.sh`, and never call `ralph-plugin-exec.sh`. Confirmed execution of a
previewed start or resume belongs to the `ralph-run` skill and its terminal
gate.

## Modes

- **Sequential**: ordered stages (maps to the orchestration engine). Use
  `ralph create workflow --mode sequential`.
- **Dependency**: DAG-shaped stages (maps to the graph engine). Use
  `ralph create workflow --mode dependency`.

## Public commands

Authoring and inspection:

```text
ralph create workflow [--mode sequential|dependency] [--global]
ralph workflow inspect --file <workflow-path>
ralph workflow inspect <workflow-id>
```

Start (task entry, optional provided leaf plan, or both):

```text
ralph workflow start <id> --task "<work request>"
ralph workflow start --file <workflow-path> --task "<work request>"
ralph workflow start <id> --plan <leaf-plan-path> [--task "<text>"]
ralph workflow start --file <workflow-path> --plan <leaf-plan-path> [--task "<text>"]
```

Lifecycle and operator actions:

```text
ralph workflow runs [--all] [--state <state>] [--workflow <id>] [--json]
ralph workflow status <run-id> [--json]
ralph workflow actions list <run-id> [--json]
ralph workflow actions respond <run-id> <request-id> --decision <choice> [--message <text>] [--yes]
ralph workflow resume <run-id>
ralph workflow reset <run-id> [--stage <id>|--all] [--dry-run] [--yes]
ralph workflow recover <run-id>
```

`--plan` is always a leaf Ralph plan (classic or yaml checkboxes), never a
workflow definition. Combine `--plan` with `--file` / workflow id when the
workflow accepts a supplied plan.

## Generated versus supplied immutable plans

- A **generated** plan is produced by a planner stage during a run. The runner
  freezes it under the workflow-run registry (`plans/...` source + mutable
  control copy). Reset/rework may recreate a control plan from the immutable
  source; it must not rewrite the reusable workflow definition.
- A **supplied** plan is an operator-provided leaf plan passed with `--plan`.
  The run freezes an immutable copy and manifest; changing the plan requires a
  **new** workflow run. Never regenerate or delete the supplied source on reset.
- Plan TODO progress (`completedTodos` / `totalTodos` / `currentTodoId`) lives
  on the mutable control plan for that stage. Resume continues the same control
  plan; do not open a fresh unchecked plan for the same stage.

## Autonomous versus human-verified SDLCs

- **Autonomous** workflows have no approval node. Stages run until success,
  failure, or an input request.
- **Human-verified** workflows include an approval stage. On approval wait,
  list outstanding requests, respond with `approve`, `request-changes`, or
  `cancel`, then resume or reset as status directs. Do not invent a parallel
  ack file or bypass the common actions path.

## Responding to approval and input requests

When status is non-retryable `waiting` for approval or input:

1. Run `ralph workflow actions list <run-id>`.
2. Respond with `ralph workflow actions respond ...` (approval:
   `approve|request-changes|cancel`; input: `answer|cancel` with `--message`
   when required).
3. Resume only when status says the response is ready and resume is the safe
   next action. Unresolved requests refuse resume.

Agents that need operator input mid-TODO call
`ralph workflow actions request --question "..."` and stop without completing
the TODO. Do not guess.

## Resuming existing control plans

`ralph workflow resume <run-id>` retries eligible stages and continues the same
mutable control plan and TODO progress. It never reruns `succeeded` stages and
refuses live `running`, `cancelled`, and `succeeded` runs. For clean
interruptions or answered input, resume injects the answer once into the same
TODO. Prefer resume/reset/recover over starting a second run for the same work.

## Never replace a plan run with an untracked one-turn implementation

A workflow coordinates attributable plan runs. Do not bypass the runner by
implementing TODOs in a one-shot chat, editing the control plan checkboxes by
hand without a plan run, or starting an untracked `ralph run --plan` that
duplicates an active workflow stage. Use status/actions/resume/reset so
progress stays in the registry.

## Category and bootstrap

Category: workflow lifecycle (authoring + read-only ops). Allowed bootstrap
operation is `probe` only. After a usable/newer probe, compose the public
verbs above. Never invoke `ralph run` from this skill; hand confirmed start or
resume preview to `ralph-run` with kind `workflow-start` or `workflow-resume`.

```bash
set -euo pipefail

_rel="../../shared/ralph-plugin-bootstrap.sh"
if [[ "$_rel" == /* ]]; then
  BOOTSTRAP="$_rel"
else
  BOOTSTRAP="${CLAUDE_PLUGIN_ROOT:-.}/$_rel"
fi

operation="${RALPH_PLUGIN_OPERATION:-inspect}"
mode="${RALPH_PLUGIN_WORKFLOW_MODE:-}"
workflow_path="${RALPH_PLUGIN_WORKFLOW_PATH:-${RALPH_PLUGIN_PLAN_PATH:-}}"
workflow_id="${RALPH_PLUGIN_WORKFLOW_ID:-}"
run_id="${RALPH_PLUGIN_RUN_ID:-}"
task_text="${RALPH_PLUGIN_TASK:-}"
leaf_plan="${RALPH_PLUGIN_LEAF_PLAN:-}"

probe_ec=0
probe_json=""
probe_json="$(/bin/bash "$BOOTSTRAP" probe --json)" || probe_ec=$?
printf '%s\n' "$probe_json"

outcome="$(printf '%s\n' "$probe_json" | jq -r '.outcome // empty')"
remediation="$(printf '%s\n' "$probe_json" | jq -r '.remediation // empty')"

printf 'workflow: ralph-workflow\n'
printf 'category: workflow-lifecycle\n'
printf 'modes: Sequential Dependency\n'
if [[ -n "$remediation" ]]; then
  printf 'remediation: %s\n' "$remediation"
fi

case "$outcome" in
  usable|newer)
    ;;
  *)
    printf 'status: blocked\n'
    if [[ "$probe_ec" -ne 0 ]]; then
      exit "$probe_ec"
    fi
    exit 1
    ;;
esac

if [[ "$outcome" == "newer" ]]; then
  printf 'status: newer-cli-warning\n'
else
  printf 'status: healthy\n'
fi

case "$operation" in
  run|execute|preview)
    printf 'rejected-operation: %s\n' "$operation"
    printf 'reason: use ralph-run for confirmed preview/execute of workflow-start or workflow-resume\n'
    exit 1
    ;;
  scaffold|inspect|runs|status|actions|print-start|print-resume|print-reset|print-recover)
    ;;
  *)
    printf 'rejected-operation: %s\n' "$operation"
    printf 'reason: allowed operations are scaffold, inspect, runs, status, actions, print-start, print-resume, print-reset, print-recover\n'
    exit 1
    ;;
esac

printf 'operation: %s\n' "$operation"
printf 'guidance: generated-vs-supplied-immutable-plans; control-plan-TODO-progress; autonomous-vs-human-verified; actions-then-resume; never-untracked-one-turn\n'

case "$operation" in
  scaffold)
    args=(create workflow)
    if [[ -n "$mode" ]]; then
      args+=(--mode "$mode")
    fi
    printf 'author: ralph create workflow\n'
    if [[ -n "$mode" ]]; then
      printf 'mode: %s\n' "$mode"
    else
      printf 'mode: interactive\n'
    fi
    ralph "${args[@]}"
    ;;
  inspect)
    if [[ -n "$workflow_path" ]]; then
      printf 'inspect: ralph workflow inspect --file\n'
      ralph workflow inspect --file "$workflow_path"
    elif [[ -n "$workflow_id" ]]; then
      printf 'inspect: ralph workflow inspect\n'
      ralph workflow inspect "$workflow_id"
    else
      printf 'inspect: workflow path or id required\n'
      exit 1
    fi
    ;;
  runs)
    printf 'inspect: ralph workflow runs\n'
    ralph workflow runs --all || true
    ;;
  status)
    if [[ -z "$run_id" ]]; then
      printf 'status: run id required\n'
      exit 1
    fi
    printf 'inspect: ralph workflow status\n'
    ralph workflow status "$run_id"
    ;;
  actions)
    if [[ -z "$run_id" ]]; then
      printf 'actions: run id required\n'
      exit 1
    fi
    printf 'inspect: ralph workflow actions list\n'
    ralph workflow actions list "$run_id"
    ;;
  print-start)
    printf 'print: start command for operator or ralph-run kind workflow-start\n'
    if [[ -n "$workflow_path" ]]; then
      printf 'ralph workflow start --file %s' "$workflow_path"
    elif [[ -n "$workflow_id" ]]; then
      printf 'ralph workflow start %s' "$workflow_id"
    else
      printf 'print-start: workflow path or id required\n'
      exit 1
    fi
    if [[ -n "$task_text" ]]; then
      printf ' --task %s' "$task_text"
    fi
    if [[ -n "$leaf_plan" ]]; then
      printf ' --plan %s' "$leaf_plan"
    fi
    printf '\n'
    ;;
  print-resume)
    if [[ -z "$run_id" ]]; then
      printf 'print-resume: run id required\n'
      exit 1
    fi
    printf 'print: ralph workflow resume %s\n' "$run_id"
    printf 'note: resume continues the same control plan; do not replace with an untracked one-turn implementation\n'
    ;;
  print-reset)
    if [[ -z "$run_id" ]]; then
      printf 'print-reset: run id required\n'
      exit 1
    fi
    printf 'print: ralph workflow reset %s\n' "$run_id"
    ;;
  print-recover)
    if [[ -z "$run_id" ]]; then
      printf 'print-recover: run id required\n'
      exit 1
    fi
    printf 'print: ralph workflow recover %s\n' "$run_id"
    ;;
esac

printf 'execute-via-plugin-exec: never\n'
exit 0
```
