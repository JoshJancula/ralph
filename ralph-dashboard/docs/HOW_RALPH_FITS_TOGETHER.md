# How Ralph fits together

Ralph is a **command-line framework first**. The dashboard is optional. It helps you see state and trigger work; it does not replace the CLI or substitute for a well-configured agent environment in each project.

## What Ralph does (and does not do)

When you run `ralph run --plan …` or `ralph workflow start …`, Ralph is a **harness** around your chosen agent runtime (Cursor, Claude Code, Codex, OpenCode, or Antigravity). The runtime still owns the actual agent session.

Ralph's responsibilities are narrow and deliberate:

| Role | What it means in practice |
| --- | --- |
| **Runner** | Picks the next open TODO on a leaf plan or advances workflow stages, with durable logs and artifacts under `.ralph-workspace/`. |
| **Safety** | Applies the **killswitch** (`ralph safety`) so dangerous shell commands and file access are blocked before they execute. |
| **Context discipline** | Uses compaction and related hook integration to keep long runs within practical token limits. |
| **Supervision** | Records approvals, operator input, verification failures, and rework — model prose alone cannot fake completion. |

Ralph does **not** ship a separate brain, a fixed skill pack, or a universal MCP catalog for your codebase. Quality still comes from **your** rules, skills, prompts, and tool choices in **that project**.

## Configure agents per project

Skills, rules, hooks, plugins, permissions, memory, and MCP servers belong to the **runtime** and should be configured **per repository** (the Ralph project root — the tree that contains `.ralph/` and `.ralph-workspace/`).

On each invocation, Ralph **consumes** the runtime's existing configuration. It adds only its own integration layer (for example protected Ralph MCP wiring and reversible overlays) without wiping vendor defaults. Typical locations:

| Runtime | Project-local config (examples) |
| --- | --- |
| Cursor | `.cursor/rules`, `.cursor/skills`, `.cursor/mcp.json`, hooks |
| Claude Code | `.claude/settings.json`, rules, skills, hooks, plugins |
| Codex | `.codex/config.toml` when the project is trusted |
| OpenCode | `opencode.json` (project scope) |
| Antigravity | `.agents/` rules, skills, workflows, MCP |

Workflow and plan behavior live in Ralph's own surfaces: leaf plan files, `*.workflow.md` definitions, and state under `.ralph-workspace/`. Safety policy is edited with `ralph safety` or the dashboard **Safety** page (project `killswitch.json`). See the framework **Security** doc in **Docs → Ralph CLI** for precedence and validation.

If you run Ralph in multiple repos, expect to tune each one. Copying only `.ralph/` without the runtime dirs that shape agent behavior will feel hollow.

## What the dashboard is for

Ralph Dashboard is mainly a **visualizer and control surface** for work Ralph is already tracking:

- **Home** and **Runs** — follow workflow and plan execution, waiting states, and the next permitted operator action.
- **Plans** — inspect checkbox progress, source, and linked artifacts.
- **Workflows** — browse definitions, customize where allowed, and start runs (the UI confirms the resolved `ralph workflow start` command).
- **Insights** — token, time, and tool-call trends from recorded runs.
- **Browse** — raw trees for logs, artifacts, sessions, and project docs when the product sections are not enough.

**Tasks** and **Schedules** are conveniences: a human queue of outcomes and timed triggers. They sit on top of the same CLI execution path; they are not a replacement for clear plans, workflows, or agent configuration.

Starting or cancelling work in the UI still requires a local dashboard server and ultimately invokes the same `ralph` binary as the terminal. Treat the dashboard as the glass cockpit, not the engine.

## Fine-tune with skills — and trust your sources

The biggest leverage is outside Ralph's core: sharper rules, focused skills, minimal MCP surface, and verification commands on plan TODOs. Ralph keeps the run honest; **you** teach the agent how to work in the repo.

Skills, plugins, hooks, and MCP servers run with the privileges of your agent runtime on your machine. **Install only from sources you trust.** Read what they can read and write, prefer narrow tools over "full access" bundles, and keep project config in git when you can.

Ralph is open source. That is a reason to inspect the harness, not a guarantee that every third-party skill or plugin in the wild is safe. Apply the same skepticism you would for any installable automation — including things published on some random person's GitHub. (This project happens to be one of those.)

## Where to read next

| Goal | Guide |
| --- | --- |
| First steps in this UI | [Start here](START_HERE.md) |
| Runs, approvals, customize workflows | [Runs and workflows](RUNS_AND_WORKFLOWS.md) |
| Task queue | [Tasks](TASKS.md) |
| Cron-style automation | [Schedules](SCHEDULES.md) |
| Stuck runs or missing controls | [Help and troubleshooting](HELP_AND_TROUBLESHOOTING.md) |
| CLI, install, MCP, environment | **Docs → Ralph CLI** (framework `docs/` at the install root) |
