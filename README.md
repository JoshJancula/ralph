# Ralph

Ralph helps you work with AI coding assistants in an organized way. It supports Cursor, Claude, Codex, OpenCode, and Antigravity. The main entry point is `ralph create plan`: it can scaffold a zero-dependency `classic` markdown checklist or a `yaml` plan with YAML frontmatter. For staged, multi-agent workflows, use `ralph create orc`. When a job is too big for one pass, the orchestration path hands artifacts from one step to the next.

## In short

| Idea | What it means |
|------|----------------|
| **Plan** | `ralph create plan --format classic` creates the zero-dependency markdown checklist path. `ralph create plan --format yaml` creates the YAML-frontmatter TODO queue path. `ralph create orc` creates the staged multi-agent path. |
| **Runner** | Picks the next open task, runs your assistant, updates the plan, repeats. |
| **Orchestrator** | Optional multi-stage pipelines with artifact checks between steps across Cursor, Claude, Codex, OpenCode, and Antigravity. |

Logs and generated files land under **`.ralph-workspace/logs/`** and **`.ralph-workspace/artifacts/`**. Optional dashboard: **`.ralph/ralph-dashboard/`**.

## What gets installed

| Folder | Role |
|--------|------|
| [.ralph](bundle/.ralph) | Shared scripts (`run-plan.sh`, orchestrator, templates, MCP server, docs copy, optional dashboard) |
| [.cursor](bundle/.cursor), [.claude](bundle/.claude), [.codex](bundle/.codex), [.opencode](bundle/.opencode), [.agents](bundle/.agents) | Rules, skills, and six **agents** per runtime you install |

After install, edit **`skills/repo-context/SKILL.md`** under each runtime so assistants know your layout and commands.

### Managing agents

Ralph agents are resolved at runtime, supporting both single-file canonical profiles (Ralph-native) and traditional dual-file workflows (bundled):

- **Single-file (default):** `ralph agent new my-agent` creates `.ralph/agents/my-agent.md` with YAML frontmatter; no sync required.
- **Dual-file:** `ralph agent new my-agent --all` scaffolds all runtimes and runs `scripts/sync-runtime-assets.sh`.
- **List and inspect:** `ralph agent list` enumerates all agents; `ralph agent show <id>` prints the resolved profile.
- **Override location:** Set `RALPH_AGENT_SOURCE_ORDER=ralph-workspace,ralph-install,native-md,classic-config` to control probe precedence, or `RALPH_AGENT_SOURCE=/path/to/custom.md` to force a specific file.
- **Claude native passthrough:** Set `RALPH_AGENT_NATIVE_PASSTHROUGH=on` (auto-default) to pass `--agent <name>` directly to claude CLI for native agents; set to `off` to force context inlining.

See AGENTS.md for detailed agent development and architecture.

## Install

**Primary path — global install** (once per machine, shared configs):

```bash
git clone https://github.com/JoshJancula/ralph.git /tmp/ralph && /tmp/ralph/install.sh --global && rm -rf /tmp/ralph
```

Installs Ralph to **`~/.ralph/`**, puts the **`ralph`** command on **`PATH`** (typically `~/.local/bin/ralph`), and shares runtime configs and agents across projects. Projects reference the global install instead of carrying their own `.ralph/` copy. Full details and commands: **[docs/INSTALL.md](docs/INSTALL.md)**.

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

## Quickstart

1. `ralph create plan --format classic` — use this for the markdown checklist flow.
2. `.ralph/run-plan.sh --workspace . --plan PLAN.md --runtime cursor` — **`--plan` is required**; use `cursor`, `claude`, `codex`, `opencode`, or `antigravity`.
3. `ralph create plan --format yaml` — use this for the YAML-frontmatter TODO queue flow.
4. `ralph create orc` — use this for staged work that routes TODOs and artifacts across multiple agents.
5. Logs and artifacts appear under **`.ralph-workspace/logs/`** and **`.ralph-workspace/artifacts/`** as the runner completes each task. YAML-format runs use the normal plan-runner logs.
6. Optional dashboard: `cd .ralph/ralph-dashboard && npm ci && npm run build && npm start` (default **http://127.0.0.1:8123**).

**Orchestration:** Multi-stage pipelines run with **`ralph run --plan path/to/pipeline.plan.md`**. Walkthrough: **[docs/orchestrated-ralph-example.md](docs/orchestrated-ralph-example.md)**. Plan loop, human input, and advanced flags: **[docs/AGENT-WORKFLOW.md](docs/AGENT-WORKFLOW.md)**.

**Human input:** The runner uses an **interactive-first flow** -- TTY-attached sessions prompt inline; headless sessions pause and write files under **`.ralph-workspace/sessions/<plan-key>/`** until you provide an answer. Optional `RALPH_HUMAN_ACK_TOOL` lets external bridges intercept questions before the file-poll fallback kicks in.

## Documentation

| Guide | What you get |
|-------|----------------|
| [Index](docs/README.md) | Map of all topics and quick reference |
| [Installation](docs/INSTALL.md) | Global install (recommended), in-repo install, flags, uninstall |
| [Agent workflow](docs/AGENT-WORKFLOW.md) | Plan loop, human input, orchestration, cleanup, agent profile management |
| [MCP](docs/MCP.md) | Bash MCP server, host config, third-party MCP |
| [Tooling (optional)](docs/TOOLING.md) | Ralph mode (`--ralph-mode`: `no`, `native`, `ralph`, `hybrid`; default `no`), shell output compaction, native adapters |
| [Environment](docs/ENVIRONMENT.md) | Full environment variable reference, session/resume controls, models, feature gates |
| [Benchmarks](docs/BENCHMARKS.md) | Token and compaction benchmark report across Ralph optimization paths |
| [Security](docs/SECURITY.md) | Sandboxing, `.cursorignore`, practical caution, killswitch configuration |
| [AGENTS.md](AGENTS.md) | Agent contract for AI assistants: architecture, source resolution, configuration paths |

**Further reading:** [Ralph Cursor Guide](https://forum.cursor.com/t/ralph-cursor-guide/149998) | [Ralph Wiggum technique](https://ghuntley.com/ralph/) | [Awesome Claude](https://awesomeclaude.ai/ralph-wiggum)

## Be Safe

Ralph can run **many** agent turns without stopping. That is powerful and risky: bad prompts or bugs can change files, run shell commands, or expose disk contents. **[Security](docs/SECURITY.md)** explains what is sandboxed, what is not, and how to harden your workspace.

## Monitor your token usage

Cost comes from prompt size and growing runtime context. Keep TODOs concrete, prefer partial reads over huge logs, and watch provider billing. Metrics and dashboard details: **[docs/README.md](docs/README.md)**.

## License

MIT -- see [LICENSE](LICENSE).

## Support Ralph

Please take a moment to [leave a star](https://github.com/JoshJancula/ralph/stargazers) if you found this repository useful.

<img src="./public/ralph-coding.jpeg" alt="" />
