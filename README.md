# Ralph

Ralph helps you work with AI coding assistants in an organized way. It supports Cursor, Claude, Codex, OpenCode, and Antigravity. Give a reusable workflow a task or an already refined plan; task-based SDLCs investigate and generate a granular plan, while plan-delivery starts execution immediately. Leaf plans remain first-class for one-off work.

## In short

| Idea | What it means |
|------|----------------|
| **Plan** | One concrete runnable leaf file. Use `ralph run --plan <path>`; discover managed plans with `ralph list plans`. |
| **Workflow** | A reusable SDLC shape. Use `ralph create workflow`, `ralph workflow list`, and `ralph workflow start <id> --task "..."` or `--plan <path>`. |
| **Runner** | Picks the next open TODO, runs your assistant, updates the plan with durable verification, repeats. |
| **Sequential** | Ordered multi-stage workflows (classic orchestration under the hood). |
| **Dependency** | DAG multi-stage workflows with isolated workspaces, review rework, integrate, and independent QA. |

Logs and generated files land under **`.ralph-workspace/logs/`** and **`.ralph-workspace/artifacts/`**. Optional dashboard: **`.ralph/ralph-dashboard/`**.

## Execution vocabulary

Ralph keeps the runtime that executes a task separate from workflow coordination:

- **Runtime agent:** The agent/session supplied by the selected runtime (Cursor, Claude, Codex, OpenCode, or Antigravity). It receives the assembled prompt, uses that runtime's tools, and owns the product changes it makes in its agent workspace.
- **Workflow stage:** An attributable step in a reusable SDLC—investigation, planner, plan-backed implementation, review, supervisor integrate/approval, or independent QA. Stage guidance lives as inline `instructions:` on the workflow, not as a separate public resource.
- **Runtime-native subagent:** A child assistant started by the runtime-native agent feature. Its lifecycle is controlled by the runtime; it is distinct from a Ralph workflow stage or delegated run. The parent runtime agent remains responsible for the Ralph TODO and its declared artifacts.
- **Delegated run:** A Ralph-supervised child execution requested by a runtime agent. It may use another runtime, has its own prompt and completion boundary, and owns only the result artifacts or changes explicitly assigned to it. The parent run owns the initiating TODO, final verification, and completion decision.

Ralph owns run state, logs, sessions, and completion checks. Runtime agents own task work in their assigned agent workspace. Treat **agent** as the runtime execution term and **subagent** as the runtime-native child term. These terms are intentionally retained in runtime CLI names, vendor documentation, `--agent-workspace`, and related operator surfaces.

## What gets installed

| Folder | Role |
|--------|------|
| [.ralph](bundle/.ralph) | Shared scripts (`run-plan.sh`, orchestrator, workflows, MCP server, docs copy, optional dashboard) |
| [.cursor](bundle/.cursor), [.claude](bundle/.claude), [.codex](bundle/.codex), [.opencode](bundle/.opencode), [.agents](bundle/.agents) | Rules, skills, and runtime-native configuration for each runtime you install |

After install, edit **`skills/repo-context/SKILL.md`** under each runtime so assistants know your layout and commands.

## Install

**Primary path — global install** (once per machine, shared configs):

```bash
git clone https://github.com/JoshJancula/ralph.git /tmp/ralph && /tmp/ralph/install.sh --global && rm -rf /tmp/ralph
```

Installs Ralph to **`~/.ralph/`**, puts the **`ralph`** command on **`PATH`** (typically `~/.local/bin/ralph`), and shares runtime configs across projects. Projects reference the global install instead of carrying their own `.ralph/` copy. Full details and commands: **[docs/INSTALL.md](docs/INSTALL.md)**.

### Local / in-repo install (alternative)

Use when you want Ralph **committed inside a project** (reviewable `.ralph/`, `.cursor/`, etc.):

```bash
git subtree add --prefix vendor/ralph https://github.com/JoshJancula/ralph.git main --squash && ./vendor/ralph/install.sh
```

Or clone Ralph once and run **`install.sh /path/to/your-repo`**. Submodule and subtree layouts, **`install.sh`** flags, partial installs, uninstall, and a global-vs-local comparison: **[docs/INSTALL.md](docs/INSTALL.md)**.

After install, use `ralph setup` to enable durable compaction hooks for normal IDE sessions. You can target either a project runtime dir or your user-home runtime dir:

```bash
cd /path/to/your-project
ralph setup --runtime claude --runtime-dir ~/.claude --hooks     # durable Claude compaction hooks for all projects
ralph setup --runtime cursor --runtime-dir ~/.cursor --hooks     # durable Cursor compaction hooks for all projects
ralph setup --runtime claude --runtime-dir /path/to/project/.claude --hooks --mcp
ralph setup --runtime codex --runtime-dir /path/to/project/.codex --all
ralph setup --runtime opencode --runtime-dir /path/to/project/.opencode --hooks
ralph setup --runtime antigravity --runtime-dir /path/to/project/.agents --all
```

See **[docs/INSTALL.md](docs/INSTALL.md)** (command reference) and **[docs/MCP.md](docs/MCP.md)** / **[docs/TOOLING.md](docs/TOOLING.md)** (runtime-specific paths and caveats).

After a global install, host plugins are a separate step: `ralph plugin list` then `ralph plugin install --runtime <runtime>`. Packaged assets land under `$RALPH_HOME/plugins/...`; install never host-installs automatically. Safety config uses `ralph safety status|validate|check|init|edit` (see **[docs/SECURITY.md](docs/SECURITY.md)**). Global user workflows live under `$RALPH_HOME/workflows/` and are never owned by the installer.

## Quickstart

1. `ralph workflow list` — browse project, global, and bundled workflows.
2. `ralph workflow start feature-delivery --task "Add CSV export"` — task-based SDLC (investigate, generate plan, execute, review, QA). On a TTY, start attaches the live viewer; `q` detaches without cancelling.
3. `ralph workflow start plan-delivery --plan path/to/leaf.plan.md` — execute an already refined leaf plan under review and independent QA.
4. `ralph workflow status <run-id>` for a static report; `ralph workflow watch <run-id>` (or `--plain`) to reattach the live viewer; `ralph workflow runs` / `runs --tsv` to list runs.
5. `ralph create plan --format classic` — one-off markdown checklist, then `ralph run --plan PLAN.md`.
6. `ralph create workflow --mode dependency` or `--mode sequential` — author a custom reusable workflow (only two create commands: `ralph create plan` and `ralph create workflow`).
7. Logs and artifacts appear under **`.ralph-workspace/logs/`** and **`.ralph-workspace/artifacts/`** as work completes.
8. Optional dashboard: `cd .ralph/ralph-dashboard && npm ci && npm run build && npm start` (default **http://127.0.0.1:8123**).

**Workflows:** Operating model, Sequential vs Dependency, status versus watch, terminal viewer, bundled SDLCs, planner/`planInput`, and authoring: **[docs/WORKFLOWS.md](docs/WORKFLOWS.md)**.

**Human input:** The runner uses an **interactive-first flow** -- TTY-attached sessions prompt inline; headless sessions pause and write files under **`.ralph-workspace/sessions/<plan-key>/`** until you provide an answer. Workflow stages use `ralph workflow actions request` / `respond` for structured input and approval. Optional `RALPH_HUMAN_ACK_TOOL` lets external bridges intercept questions before the file-poll fallback kicks in.

## Documentation

| Guide | What you get |
|-------|----------------|
| [Index](docs/README.md) | Map of all topics and quick reference |
| [Installation](docs/INSTALL.md) | Global install (recommended), in-repo install, flags, uninstall, plugins, workflows |
| [Agent workflow](docs/AGENT-WORKFLOW.md) | Plan loop, human input, prompts, and execution ownership |
| [Workflows](docs/WORKFLOWS.md) | Core operating model, Sequential/Dependency, status/watch terminal viewer, bundled SDLCs, authoring, plan handoff |
| [MCP](docs/MCP.md) | Bash MCP server, host config, third-party MCP |
| [Tooling (optional)](docs/TOOLING.md) | Ralph mode (`--ralph-mode`: `no`, `native`, `ralph`, `hybrid`; default `no`), shell output compaction, native adapters |
| [Environment](docs/ENVIRONMENT.md) | Full environment variable reference, session/resume controls, models, feature gates |
| [Benchmarks](docs/BENCHMARKS.md) | Token and compaction benchmark report across Ralph optimization paths |
| [Security](docs/SECURITY.md) | Sandboxing, `.cursorignore`, practical caution, `ralph safety` killswitch CLI |
| [AGENTS.md](AGENTS.md) | Agent contract for AI assistants: architecture, source resolution, configuration paths |

**Further reading:** [Ralph Cursor Guide](https://forum.cursor.com/t/ralph-cursor-guide/149998) | [Ralph Wiggum technique](https://ghuntley.com/ralph/) | [Awesome Claude](https://awesomeclaude.ai/ralph-wiggum)

## Be Safe

Ralph can run **many** agent turns without stopping. That is powerful and risky: bad prompts or bugs can change files, run shell commands, or expose disk contents. **[Security](docs/SECURITY.md)** explains what is sandboxed, what is not, and how to harden your workspace (`ralph safety` for killswitch status, validate, check, init, and edit).

## Monitor your token usage

Cost comes from prompt size and growing runtime context. Keep TODOs concrete, prefer partial reads over huge logs, and watch provider billing. Metrics and dashboard details: **[docs/README.md](docs/README.md)**.

## License

MIT -- see [LICENSE](LICENSE).

## Support Ralph

Please take a moment to [leave a star](https://github.com/JoshJancula/ralph/stargazers) if you found this repository useful.

<img src="./public/ralph-coding.jpeg" alt="" />
