# Ralph

**Ralph** helps you work with AI coding assistants in an organized way. You keep a simple to-do list in a markdown file; a script runs an agent via Cursor, Claude Code, or OpenAI Codex over and over until every item is checked off. For bigger projects, a separate orchestrator can chain several stages and pass files between them.

If you already use those tools and are comfortable in a terminal, Ralph adds structure. If you are newer to this, skim the sections below, then use [the docs folder](docs/README.md) when you need step-by-step detail.

## In short

| Idea | What it means |
|------|----------------|
| **Plan** | A markdown file with lines like `- [ ] Do this` and `- [x] Done`. Only that checkbox style counts as a task. |
| **Runner** | A shell script that reads the next open task, runs your chosen AI tool, updates the plan, and repeats. |
| **Orchestrator** | Optional multi-step pipelines (for example research, then design, then implementation) with checks between steps. |

Logs and output files usually go under `.agents/logs/` and `.agents/artifacts/`. Optional: a small local web UI in `ralph-dashboard/` to browse plans and logs.

## What gets installed

After you run the installer (below), these folders appear at **your project root** (not inside a `vendor/` folder unless you put the Ralph repo there yourself):

| Folder | Role |
|--------|------|
| [.ralph](bundle/.ralop) | Shared scripts: orchestrator, cleanup, plan template, MCP server, unified `run-plan.sh` |
| [.cursor/ralph](bundle/.cursor/ralph/) | Cursor-specific runner and config |
| [.claude/ralph](bundle/.claude/ralph) | Claude Code runner and config |
| [.codex/ralph](bundle/.codex/ralph) | Codex runner and config |
| [ralph-dashboard](ralph-dashboard) | Optional dashboard (Python 3) |
| [.cursor](bundle/.cursor), [.claude](bundle/.claude), [.codex](bundle/.codex) | also get rules, skills, and **agents** (research, architect, implementation, code-review, qa, security) where those stacks are installed |


**`repo-context`:** Each runtime ships a template skill describing your repo layout and commands. Edit the `skills/repo-context/SKILL.md` files after install so assistants know how to build and test your project.

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

Teammates after clone: `git submodule update --init` then `./vendor/ralph/install.sh` if the bundle changed.

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

With **no flags**, the installer copies the full stack (same as `--all`): `.ralph`, Cursor, Claude, and Codex pieces, plus the dashboard.

```text
./install.sh                      # full install (default)
./install.sh --all                # same as default
./install.sh --cursor             # Cursor runner + rules/skills/agents only (plus shared if you combine flags)
./install.sh --codex --claude     # Codex and Claude only
./install.sh --shared             # only .ralph/ (orchestrator, templates, shared runners)
./install.sh --no-dashboard       # skip ralph-dashboard/
./install.sh -n /path/to/repo     # dry-run: print actions only
```

Use `--cursor`, `--claude`, `--codex`, and/or `--shared` together to limit what is copied.

**Partial installs:** `--cursor` alone does **not** copy `.ralph/` (no orchestrator, unified `run-plan.sh`, or `.ralph/plan.template` in your tree). Add `--shared` if you want those. **Claude and Codex** runners require **`.ralph/agent-config-tool.sh`** for `--agent`; use `./install.sh --claude --shared` (or `--codex --shared`) or a full install so `.ralph/` is present.

## After install

1. **Plan file** -- Copy `.ralph/plan.template` to something like `PLAN.md`, then pass it with **`--plan`** when you run `.ralph/run-plan.sh` (see [.cursor/ralph/README.md](.cursor/ralph/README.md) for the Cursor stack).
2. **CLI tools** -- Install what you use: [Cursor CLI](https://cursor.com/docs/cli/installation), [Claude Code](https://code.claude.com/docs/en/quickstart) (`claude`), [Codex CLI](https://developers.openai.com/codex/cli) (`codex`).
3. **Extra agents** -- Run `bash .ralph/new-agent.sh` to scaffold more agent profiles.

### Dashboard

From your project root:

```bash
python3 ralph-dashboard/server.py
```

Open **http://127.0.0.1:8123** by default. The UI reads `.agents/orchestration-plans`, `.agents/artifacts`, and `.agents/logs` next to your repo root.

## Run a plan (typical commands)

**Typical invocations (repo root, after `.ralph/` is installed):**

- Cursor: `.ralph/run-plan.sh --runtime cursor --plan PLAN.md`
- Claude: `.ralph/run-plan.sh --runtime claude --plan PLAN.md --model claude-haiku-4-5`
- Codex: `.ralph/run-plan.sh --runtime codex --non-interactive --plan PLAN.md --agent architect`


**Checklist syntax:** Use `- [ ]` for open tasks (space before `]`). The form `- []` is ignored, so the run could stop early while lines still look unfinished.

### When the runner needs a human

- The runner follows an **interactive-first flow**: in a normal terminal session, it usually prompts you there and continues.
- When there is no interactive terminal, the runner writes files such as `pending-human.txt` and `operator-response.txt` and **waits** while you add your answer (it polls; you do not have to restart unless you choose the optional exit behavior). Exchanges are also recorded under `.agents/<artifact-namespace>/human`. Optional hooks (`RALPH_HUMAN_ACK_TOOL`, `.ralph/orchestrator.sh --human-ack`) and `RALPH_HUMAN_OFFLINE_EXIT=1` are covered in [docs/AGENT-WORKFLOW.md](docs/AGENT-WORKFLOW.md).

### Orchestration (multi-stage)

```bash
.ralph/orchestrator.sh --orchestration .agents/orchestration-plans/my-feature/my-feature.orch.json
```

You can also pass the `.orch.json` path as the first argument with no flag; see the header of [.ralph/orchestrator.sh](bundle/.ralph/orchestrator.sh). To generate starter files, run `.ralph/orchestration-wizard.sh`.

Full walkthroughs: [docs/orchestrated-ralph-example.md](docs/orchestrated-ralph-example.md), [docs/worker-ralph-example.md](docs/worker-ralph-example.md).

## Documentation

Start here for depth and copy-paste examples:

- **[docs/README.md](docs/README.md)** -- Index of all guides
- **[docs/AGENT-WORKFLOW.md](docs/AGENT-WORKFLOW.md)** -- Plan loop, orchestrator, cleanup, prompts, human-input details
- **[docs/MCP.md](docs/MCP.md)** -- MCP server and host configuration
- **[docs/CLAUDE-AGENT-TEAMS.md](docs/CLAUDE-AGENT-TEAMS.md)** -- Claude Code agent teams with Ralph

Runner-specific notes: [.cursor/ralph/README.md](bundle/.cursor/ralph/README.md), [.codex/ralph/README.md](bundle/.codex/ralph/README.md) (same content as `.codex/ralph/README.md` after install). Orchestration JSON shape: comments in `.ralph/orchestrator.sh` and `.ralph/orchestration.template.json`.

**MCP server:**

```bash
RALPH_MCP_WORKSPACE="$PWD" bash .ralph/mcp-server.sh
```

Requires `jq`. See [docs/MCP.md](docs/MCP.md).


## License

MIT -- see [LICENSE](LICENSE).

<img src="./public/ralph-coding.jpeg" alt="" />
