# Ralph documentation

These pages assume you have **installed Ralph into a project** using the installer in the Ralph repository (see the main **README** there for submodule, subtree, or one-shot copy). Unless we say otherwise, paths are from **your project root**: the directory that contains **`.ralph/`**, **`.cursor/`**, and the rest.

The installer copies this documentation into **`.ralph/docs/`** in that project. Read it from either place; the content is the same.

## Guides

Pick what matches what you are doing. You can read them in any order.

| Guide | What it is for |
|-------|----------------|
| [AGENT-WORKFLOW.md](AGENT-WORKFLOW.md) | How the plan loop works, how human input behaves (terminal vs offline files), orchestration stages, `loopControl`, cleanup, and copy-paste prompts |
| [worker-ralph-example.md](worker-ralph-example.md) | One plan, one runtime, end to end: where logs and artifacts go |
| [orchestrated-ralph-example.md](orchestrated-ralph-example.md) | Multi-stage pipelines: stage plans, `.orch.json`, running the orchestrator, checking artifacts |
| [CLAUDE-AGENT-TEAMS.md](CLAUDE-AGENT-TEAMS.md) | Claude Code **agent teams** next to Ralph: when teams help vs a single plan vs the orchestrator |
| [MCP.md](MCP.md) | The bash MCP server (`jq`), resources and prompts, wiring Cursor / Claude / Codex, path rules |
| [SECURITY.md](SECURITY.md) | Trust and scope: what Ralph sandboxes, what it does not, `.cursorignore`, hooks, Codex caveats |

## Quick reference

- **Open tasks:** `- [ ]` (space inside the brackets). **Done:** `- [x]`. **Not a task:** `- []`.
- **Plan file:** Usually **`PLAN.md`** from **`.ralph/plan.template`**. Pass it with **`--plan <path>`** to **`.ralph/run-plan.sh`**. Relative paths resolve against the workspace directory you pass last, or the current directory.
- **Runner:** `.ralph/run-plan.sh --runtime cursor|claude|codex --plan <path>` (**`--plan` is required**).
- **Orchestrator:** `.ralph/orchestrator.sh --orchestration path/to/file.orch.json` or the same path as the first argument only.
- **Wizard:** `.ralph/orchestration-wizard.sh` scaffolds a namespace, stage plans, and a starter **`.orch.json`**.
