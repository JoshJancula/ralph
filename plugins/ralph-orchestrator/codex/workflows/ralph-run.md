<!-- GENERATED from bundle/.ralph/plugin-inputs/workflows/ralph-run.md by scripts/sync-plugin-assets.sh - edit the canonical file -->
---
name: ralph-run
description: Preview an exact Ralph plan, orchestration, or graph command and hand execution to an operator-confirmed terminal gate.
---

# ralph-run

Use this workflow only when the current user directly asks to run or resume
Ralph work. It is the sole executing workflow. Never call `ralph run`, `ralph
graph run`, `ralph graph resume`, or the orchestrator directly.

## Required operator journey

1. Collect the execution kind, absolute plan path, project root, state root,
   agent workspace, and any runtime, agent, model, namespace, or run id required
   by that kind. Never invent a runtime or model.
2. Resolve the shared scripts relative to this workflow or skill. Run the
   bootstrap `probe --json`. If it is not `usable` or `newer`, stop with its
   remediation; do not install automatically.
3. Run only the `preview` operation below. Show its complete text output,
   including the exact command and confirmation id, to the user.
4. Do not execute from a non-interactive agent shell. Give the user the
   copyable `execute` command printed below. The execution gate requires a real
   terminal and asks the operator to type the full confirmation id; piped input
   and `--yes` are rejected.
5. If the host provides a real operator-owned terminal, the user may run the
   execute command there. Never synthesize the request text or confirmation id.

## Preview command

Set the values from the user's request, omitting only options that do not apply:

```bash
_exec_rel="../shared/ralph-plugin-exec.sh"
if [[ "$_exec_rel" == /* ]]; then
  RALPH_PLUGIN_EXEC="$_exec_rel"
else
  RALPH_PLUGIN_EXEC="${RALPH_PLUGIN_ROOT:-.}/$_exec_rel"
fi

/bin/bash "$RALPH_PLUGIN_EXEC" preview \
  --kind "$RALPH_PLUGIN_KIND" \
  --plan "$RALPH_PLUGIN_PLAN_PATH" \
  --runtime "$RALPH_PLUGIN_RUNTIME" \
  --agent "$RALPH_PLUGIN_AGENT" \
  --model "$RALPH_PLUGIN_MODEL" \
  --workspace "$RALPH_PLUGIN_PROJECT_ROOT" \
  --workspace-root "$RALPH_PLUGIN_STATE_ROOT" \
  --agent-workspace "$RALPH_PLUGIN_AGENT_WORKSPACE"
```

For graph run, add `--namespace`. For graph resume, add both `--namespace` and
`--run`. Preserve model values byte-for-byte.

## Operator-terminal execution

After the user has reviewed the preview, print a command with the identical
tuple and these additional arguments:

```text
execute --confirmation-id <preview-id> --request '<current user request>'
```

Do not add `--yes`. The terminal gate reprints the preview and requires the
operator to type the complete preview id before invoking Ralph once.
