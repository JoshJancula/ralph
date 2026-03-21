# Ralph (Cursor stack)

Cursor-specific Ralph assets live here: `select-model.sh`, agent definitions under `.cursor/agents/`, templates, and logs under this directory.

**Plan execution** uses the unified runner at **`.ralph/run-plan.sh`** with **`--runtime cursor`** and a required **`--plan <path>`** (same optional flags as other runtimes: `--agent`, `--non-interactive`, etc.).

Multi-stage pipelines use **`.ralph/orchestrator.sh`** with JSON `.orch.json`; each stage sets `"runtime"` to `cursor`, `claude`, or `codex`. The orchestrator always invokes `.ralph/run-plan.sh` with the matching **`--runtime`**, the stage's plan path as **`--plan`**, and the stage agent. Logs: `.agents/logs/<artifact-namespace>/plan-runner-*.log`.
