# Ralph documentation

These guides assume Ralph is already [installed in your project](../README.md#install-pick-one). Paths like `.ralph/` and `.cursor/ralph/` mean your **workspace root** (the root of the repo where you ran `install.sh`).

## Guides (read in any order)

| Document | What it covers |
|----------|----------------|
| [AGENT-WORKFLOW.md](AGENT-WORKFLOW.md) | Plan-first loop, per-runtime runners, human input (TTY vs offline, polling, optional exit codes), orchestrator stages, `loopControl`, cleanup, sample prompts for plans and JSON |
| [worker-ralph-example.md](worker-ralph-example.md) | End-to-end: one plan file, one agent/runtime, where logs and artifacts land |
| [orchestrated-ralph-example.md](orchestrated-ralph-example.md) | Multi-stage pipeline: stage plans under `.agents/orchestration-plans/`, `.orch.json`, running `orchestrator.sh`, checking artifacts |
| [CLAUDE-AGENT-TEAMS.md](CLAUDE-AGENT-TEAMS.md) | Using Claude Code **agent teams** next to Ralph (parallel teammates vs single plan vs orchestrator) |
| [MCP.md](MCP.md) | Bash MCP server (`jq`), resources and prompts, Cursor / Claude / Codex configuration, path guard rails |
| [SECURITY.md](SECURITY.md) | Workspace trust, `.cursorignore`, Claude hooks example, Codex caveats |

## Quick reference

- **Open tasks in markdown:** `- [ ]` (with a space). Completed: `- [x]`. Lines like `- []` are not tasks.
- **Plan file:** Usually `PLAN.md` from a copied template; pass it explicitly with **`--plan <path>`** to `.ralph/run-plan.sh` (relative paths resolve against the workspace directory you pass as the final argument, or the current directory).
- **Plan runner:** `.ralph/run-plan.sh --runtime cursor|claude|codex --plan <path>` (single entry point; **`--plan` is required**).
- **Orchestrator:** `.ralph/orchestrator.sh --orchestration path/to/file.orch.json` or `.ralph/orchestrator.sh path/to/file.orch.json`.
- **Wizard:** `.ralph/orchestration-wizard.sh` scaffolds namespace, stage plans, and a starter `.orch.json`.
