# Ralph

Ralph helps you work with AI coding assistants in an organized way. You keep a markdown to-do list; a small shell loop calls **Cursor**, **Claude Code**, or **OpenAI Codex** for each open task until every box is checked. When a job is too big for one pass, an optional **orchestrator** runs stages in sequence (research, design, implementation, review) and hands artifacts from one step to the next.

For detailed breakdowns (human-in-the-loop behavior, MCP, security, worked examples), use the **[documentation index](docs/README.md)**. If you installed Ralph into your own repo, those guides are also copied to **`.ralph/docs/`** so they live next to `run-plan.sh` and the rest of the tooling.

## In short

| Idea | What it means |
|------|----------------|
| **Plan** | A markdown file with lines like `- [ ] Do this` and `- [x] Done`. Only that checkbox style counts as a task. |
| **Runner** | A script that picks the next open task, runs your chosen assistant, updates the plan, and repeats. |
| **Orchestrator** | Optional multi-stage pipelines with checks between steps. |

While plans run, logs and generated files usually land under **`.agents/logs/`** and **`.agents/artifacts/`**. The optional **ralph-dashboard** app (Python 3) gives you a simple local UI over plans and logs.

## What gets installed

After you run the installer, these pieces appear at **your project root** (the app or library you are building), not inside `vendor/ralph` unless you put Ralph there on purpose:

| Folder | Role |
|--------|------|
| [.ralph](bundle/.ralph) | Shared scripts: unified `run-plan.sh`, orchestrator, cleanup, plan templates, MCP server, and **`.ralph/docs/`** (the same guides as `docs/` in this package) |
| [.cursor/ralph](bundle/.cursor/ralph/) | Cursor-specific runner and config |
| [.claude/ralph](bundle/.claude/ralph) | Claude Code runner and config |
| [.codex/ralph](bundle/.codex/ralph) | Codex runner and config |
| [ralph-dashboard](ralph-dashboard) | Optional local dashboard |
| [.cursor](bundle/.cursor), [.claude](bundle/.claude), [.codex](bundle/.codex) | Rules, skills, and **agents** (research, architect, implementation, code-review, qa, security) for each stack you install |

**repo-context:** Each runtime includes a template skill so assistants know how your repo is laid out and how you build it. After install, edit **`skills/repo-context/SKILL.md`** under `.cursor`, `.claude`, or `.codex` to match your project.

## Install (pick one)

**Submodule (easy updates):**

```bash
cd /path/to/your-repo
git submodule add <YOUR_RALPH_REPO_URL> vendor/ralph
git submodule update --init
./vendor/ralph/install.sh
git add .ralph ralph-dashboard \
  .cursor/ralph .cursor/rules .cursor/skills .cursor/agents \
  .claude/ralph .claude/rules .claude/skills .claude/agents \
  .codex/ralph .codex/rules .codex/skills .codex/agents
git commit -m "Add Ralph agent workflows"
```

Teammates: after `git clone`, run `git submodule update --init` and, if the Ralph bundle changed, `./vendor/ralph/install.sh` again.

**One-time copy:**

```bash
git clone https://github.com/JoshJancula/ralph.git /tmp/ralph
/tmp/ralph/install.sh /path/to/your-repo
rm -rf /tmp/ralph
```

**Subtree:**

```bash
git subtree add --prefix vendor/ralph https://github.com/JoshJancula/ralph.git main --squash
./vendor/ralph/install.sh
```

### Installer options

With **no flags**, you get the full stack (same as **`--all`**): shared **`.ralph`**, Cursor, Claude, and Codex pieces, plus the dashboard.

```text
./install.sh                      # full install (default)
./install.sh --all                # same as default
./install.sh --cursor             # Cursor runner + rules/skills/agents (combine with --shared if you need .ralph)
./install.sh --codex --claude     # Codex and Claude only
./install.sh --shared             # only .ralph/ (orchestrator, templates, runners, docs)
./install.sh --no-dashboard       # skip ralph-dashboard/
./install.sh -n /path/to/repo     # dry-run: print actions only
```

You can combine **`--cursor`**, **`--claude`**, **`--codex`**, and **`--shared`** to trim what is copied.

**Partial installs:** **`--cursor`** alone does **not** install **`.ralph/`**, so you will not get the unified runner, orchestrator, plan template, or in-tree docs. Add **`--shared`** (or do a full install) when you need those. The Claude and Codex runners expect **`.ralph/agent-config-tool.sh`** when you use **`--agent`**; use **`./install.sh --claude --shared`**, **`./install.sh --codex --shared`**, or a full install.

## After install

1. **Plan file** -- Copy **`.ralph/plan.template`** to something like **`PLAN.md`**, then pass it with **`--plan`** whenever you run **`.ralph/run-plan.sh`**. Cursor-specific notes: [.cursor/ralph/README.md](.cursor/ralph/README.md).
2. **CLIs** -- Install the tools you actually use: [Cursor CLI](https://cursor.com/docs/cli/installation), [Claude Code](https://code.claude.com/docs/en/quickstart), [Codex CLI](https://developers.openai.com/codex/cli).
3. **More agents** -- From your project root: **`bash .ralph/new-agent.sh`** to scaffold extra agent profiles.

### Dashboard

```bash
python3 ralph-dashboard/server.py
```

By default the UI is at **http://127.0.0.1:8123**. It reads **`.agents/orchestration-plans`**, **`.agents/artifacts`**, and **`.agents/logs`** next to your repo root.

## Run a plan (typical commands)

- **Cursor:** `.ralph/run-plan.sh --runtime cursor --plan PLAN.md`
- **Claude:** `.ralph/run-plan.sh --runtime claude --plan PLAN.md --model claude-haiku-4-5`
- **Codex:** `.ralph/run-plan.sh --runtime codex --non-interactive --plan PLAN.md --agent architect`

**Checklist syntax:** Open tasks must look like **`- [ ]`** (space before **`]`**). The form **`- []`** is ignored, so the runner may stop while lines still look unfinished.

### When the runner needs you

In a normal terminal, it usually asks you there and continues. Without a TTY, it drops prompts into files such as **`pending-human.txt`** and **`operator-response.txt`** and waits while you edit them. Questions and answers are also kept under **`.agents/<artifact-namespace>/human`**. Optional hooks and exit behavior are described in **[Agent workflow](docs/AGENT-WORKFLOW.md)**.

### Orchestration (multi-stage)

```bash
.ralph/orchestrator.sh --orchestration .agents/orchestration-plans/my-feature/my-feature.orch.json
```

You can pass the **`.orch.json`** path as the first argument with no flag; details are in the header of **`.ralph/orchestrator.sh`** (see [bundle copy](bundle/.ralph/orchestrator.sh) on GitHub). To scaffold a pipeline, run **`.ralph/orchestration-wizard.sh`**.

**Walkthroughs:** [Orchestrated example](docs/orchestrated-ralph-example.md) and [single-runner example](docs/worker-ralph-example.md).

## Documentation

| Guide | What you get |
|-------|----------------|
| [Index](docs/README.md) | Map of all topics and quick reference |
| [Agent workflow](docs/AGENT-WORKFLOW.md) | Plan loop, human input, orchestration, cleanup, sample prompts |
| [MCP](docs/MCP.md) | Bash MCP server, host config, guard rails |
| [Claude agent teams](docs/CLAUDE-AGENT-TEAMS.md) | Using Claude Code teams alongside Ralph |
| [Security](docs/SECURITY.md) | Sandboxing reality, `.cursorignore`, hooks, practical caution |

Runtime-specific READMEs: [.cursor/ralph](bundle/.cursor/ralph/README.md), [.codex/ralph](bundle/.codex/ralph/README.md). Orchestration JSON shape: comments in **`.ralph/orchestrator.sh`** and **`.ralph/orchestration.template.json`**.

**MCP server (needs `jq`):**

```bash
RALPH_MCP_WORKSPACE="$PWD" bash .ralph/mcp-server.sh
```

Details: [MCP.md](docs/MCP.md).

## Be Safe

Ralph can run **many** agent turns in a row. That is powerful and risky: bad prompts or bugs can change files, run shell commands, or expose what is on disk. Use it when you understand that tradeoff. **[Security](docs/SECURITY.md)** explains what is actually sandboxed, what is not, and how to harden your workspace.

## Monitor your token usage

Cost depends on the **model** you choose (or that a prebuilt agent pins) and on **how big and vague each task is**. Prefer a model that fits the job, keep TODOs concrete, and watch Cursor, Anthropic, or OpenAI billing so you are not surprised.

## License

MIT -- see [LICENSE](LICENSE).

<img src="./public/ralph-coding.jpeg" alt="" />
