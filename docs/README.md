# Ralph documentation

These pages assume you have **installed Ralph into a project** using **`install.sh`** (see **[INSTALL.md](INSTALL.md)** for submodule, subtree, flags, and removal, or the quick start in the main **README**). Unless we say otherwise, paths are from **your project root**: the directory that contains **`.ralph/`**, **`.cursor/`**, and the rest.

Ralph keeps runtime state (logs, artifacts, sessions) under a workspace root that contains **`.ralph-workspace/`** (it defaults to the project root but can live elsewhere via `--workspace-root` or `RALPH_PLAN_WORKSPACE_ROOT`), so references to `.ralph-workspace` point at that workspace root rather than the project root itself.

The installer copies this documentation into **`.ralph/docs/`** in that project. Read it from either place; the content is the same.

## Guides

Pick what matches what you are doing. You can read them in any order.

| Guide | What it is for |
|-------|----------------|
| [INSTALL.md](INSTALL.md) | Submodule, subtree, one-time copy, **`install.sh`** flags, partial installs, uninstall |
| [AGENT-WORKFLOW.md](AGENT-WORKFLOW.md) | How the plan loop works, how human input behaves (terminal vs offline files), orchestration stages, `loopControl`, cleanup, and copy-paste prompts |
| [worker-ralph-example.md](worker-ralph-example.md) | One plan, one runtime, end to end: where logs and artifacts go |
| [orchestrated-ralph-example.md](orchestrated-ralph-example.md) | Multi-stage pipelines: stage plans, `.orch.json`, running the orchestrator, checking artifacts |
| [CLAUDE-AGENT-TEAMS.md](CLAUDE-AGENT-TEAMS.md) | Claude Code **agent teams** next to Ralph: when teams help vs a single plan vs the orchestrator |
| [MCP.md](MCP.md) | Ralph bash MCP server (`jq`), host wiring, and **third-party MCP** (e.g. Playwright for QA) per runtime |
| [SECURITY.md](SECURITY.md) | Trust and scope: what Ralph sandboxes, what it does not, `.cursorignore`, hooks, Codex caveats |

## Quick reference

- **Open tasks:** `- [ ]` (space inside the brackets). **Done:** `- [x]`. **Not a task:** `- []`.
- **Plan file:** Usually **`PLAN.md`** from **`.ralph/plan.template`**. Pass it with **`--plan <path>`** to **`.ralph/run-plan.sh`**. Relative paths resolve against the workspace directory you pass last, or the current directory.
- **Runner:** `.ralph/run-plan.sh --runtime cursor|claude|codex|opencode --plan <path>` (**`--plan` is required**).
- **Orchestrator:** `.ralph/orchestrator.sh --orchestration path/to/file.orch.json` or the same path as the first argument only.
- **Wizard:** `.ralph/orchestration-wizard.sh` scaffolds a namespace, stage plans, and a starter **`.orch.json`**.

## CLI session resume

Out-of-process restarts and operator-driven re-invocations can pick up the most recent assistant session by continuing the same CLI context. When enabled, `.ralph/run-plan.sh` records the current `session-id` in **`.ralph-workspace/sessions/<RALPH_PLAN_KEY>/session-id.txt`** (the plan key defaults to the plan file name) and replays a compact context block (TODO + plan path + human replies only) the next time the same runtime runs under that namespace. For non-Claude prebuilt agents, the block is compact by default and can also be requested with `RALPH_COMPACT_CONTEXT=1` or `--compact`.

**Enable CLI session resume (pick one):**

- Set `RALPH_PLAN_CLI_RESUME=1` before running `.ralph/run-plan.sh`.
- Pass `--cli-resume` to the runner command.
- Answer `yes` when the interactive prompt appears (TTY-attached runs ask unless `RALPH_PLAN_CLI_RESUME`, `--cli-resume`, or `--no-cli-resume` is already provided).

**Storage and prerequisites:**

- `session-id.txt` lives under `.ralph-workspace/sessions/<RALPH_PLAN_KEY>/session-id.txt`, so restarts always read the newest ID for that namespace when they resume.
- Python 3 is required for `.ralph/bash-lib/run-plan-cli-json-demux.py`, the helper that extracts the session ID from the CLI’s JSON demux output. If Python 3 is unavailable, CLI resume is skipped and the plan starts from a fresh session.

**Optional unsafe bare resume:**

In CI or isolated workflows where you trust there will be no session mix-up, you can resume without a stored ID:

- Set `RALPH_PLAN_ALLOW_UNSAFE_RESUME=1` or pass `--allow-unsafe-resume` when running `.ralph/run-plan.sh`.
- The runner attempts to resume without consulting `.ralph-workspace/sessions/.../session-id.txt` (e.g., Codex `--last` semantics).
- **Warning:** Bare resume without a session ID may attach to the wrong session on a shared box; prefer stored session files when possible.
