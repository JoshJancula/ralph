# Ralph (Cursor stack)

Cursor-specific Ralph assets live here: `select-model.sh`, agent definitions under `.cursor/agents/`, templates, and logs under this directory.

**Plan execution** uses the unified runner at **`.ralph/run-plan.sh`** with **`--runtime cursor`** and a required **`--plan <path>`** (same optional flags as other runtimes: `--agent`, `--non-interactive`, etc.).

Multi-stage pipelines use **`.ralph/orchestrator.sh`** with JSON `.orch.json`; each stage sets `"runtime"` to `cursor`, `claude`, or `codex`. The orchestrator always invokes `.ralph/run-plan.sh` with the matching **`--runtime`**, the stage's plan path as **`--plan`**, and the stage agent. Logs: `.ralph-workspace/logs/<artifact-namespace>/plan-runner-*.log`.

## CLI session resume

Cursor runs can continue a previous CLI session by storing the assistant's session ID and passing it to the next invocation. Enable the feature by setting `RALPH_PLAN_CLI_RESUME=1`, passing `--cli-resume`, or answering **yes** when the interactive prompt appears while running `.ralph/run-plan.sh` in a TTY. The runner writes the session ID to `.ralph-workspace/sessions/<RALPH_PLAN_KEY>/session-id.txt` and reruns with `--resume` (or the stack-specific flags) using the JSON demux helper (`.ralph/bash-lib/run-plan-cli-json-demux.py`), which requires Python 3; without Python 3 present the runner warns and skips the resume attempt.

For environments where you want to resume without the stored file (for example trusted CI jobs), set `RALPH_PLAN_ALLOW_UNSAFE_RESUME=1` or pass `--allow-unsafe-resume`. This lets the CLI retry `--resume` without an existing session ID but may attach to someone else's session on shared workstations, so use it only when you control the environment.
