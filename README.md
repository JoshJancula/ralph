# Ralph

Ralph helps you work with AI coding assistants in an organized way. You keep a markdown to-do list; a small shell loop calls **Cursor**, **Claude Code**, **OpenAI Codex**, or **OpenCode** for each open task until every box is checked. When a job is too big for one pass, an optional **orchestrator** runs stages in sequence (research, design, implementation, review) and hands artifacts from one step to the next.

Ralph is meant to become **part of your codebase**, not a separate app you drive from the side. You install it into the repository you are building; it adds **`.ralph/`** and layers onto **`.cursor/`**, **`.claude/`**, **`.opencode/`** and **`.codex/`** with runners, rules, skills, and prebuilt **agents** so those tools share the same plans, handoffs, and guard rails.

## In short

| Idea | What it means |
|------|----------------|
| **Plan** | A markdown file with lines like `- [ ] Do this` and `- [x] Done`. Only that checkbox style counts as a task. |
| **Runner** | A script that picks the next open task, runs your chosen assistant, updates the plan, and repeats. |
| **Orchestrator** | Optional multi-stage pipelines with checks between steps. |

While plans run, logs and generated files will appear under **`.ralph-workspace/logs/`** and **`.ralph-workspace/artifacts/`**. The optional dashboard (Node.js/Angular) installs under **`.ralph/ralph-dashboard/`** and gives you a simple local UI over plans and logs.

## What gets installed

After you run the installer, these pieces appear at **your project root** (the app or library you are building), not inside `vendor/ralph` unless you put Ralph there on purpose:

| Folder | Role |
|--------|------|
| [.ralph](bundle/.ralph) | Shared scripts: unified `run-plan.sh`, orchestrator, cleanup, plan templates, MCP server, **`.ralph/docs/`** (same guides as `docs/` in this package), and optional **`.ralph/ralph-dashboard/`** |
| [.cursor/ralph](bundle/.cursor/ralph/) | Cursor config |
| [.claude/ralph](bundle/.claude/ralph) | Claude Code config |
| [.codex/ralph](bundle/.codex/ralph) | Codex config |
| [.opencode/ralph](bundle/.opencode/ralph) | OpenCode config |
| [.cursor](bundle/.cursor), [.claude](bundle/.claude), [.codex](bundle/.codex), [.opencode](bundle/.opencode) | Rules, skills, and **agents** (research, architect, implementation, code-review, qa, security) for each stack you install |

**repo-context:** Each runtime includes a template skill so assistants know how your repo is laid out and how you build it. After install, edit **`skills/repo-context/SKILL.md`** under `.cursor`, `.claude`, or `.codex` to match your project.

## Install

Quick install
```bash
git subtree add --prefix vendor/ralph https://github.com/JoshJancula/ralph.git main --squash && ./vendor/ralph/install.sh
```

Alternatively run **`install.sh`** from a checkout of this repository. Pass your project directory as the argument, or run it from inside that directory so the target defaults to **`.`**.

```bash
# Clone Ralph to a throwaway directory (not inside your project).
git clone https://github.com/JoshJancula/ralph.git /tmp/ralph

# Install from that clone into your project root; adjust the path as needed.
/tmp/ralph/install.sh /path/to/your-repo

# Remove the temporary clone when finished.
rm -rf /tmp/ralph
```

That copies **`.ralph/`**, runtime runners and agents under **`.cursor/`**, **`.claude/`**, and **`.codex/`**, and (by default) the dashboard under **`.ralph/ralph-dashboard/`**. A **subtree-style** **`vendor/ralph`** tree (no **`.git`** inside it) is removed automatically after install. Uninstall and **`--purge`** are documented in [docs/INSTALL.md](docs/INSTALL.md).

## After install

1. **Plan file** -- Copy **`.ralph/plan.template`** to something like **`PLAN.md`**, then pass it with **`--plan`** whenever you run **`.ralph/run-plan.sh`**. Cursor-specific notes: [.cursor/ralph/README.md](.cursor/ralph/README.md).
2. **CLIs** -- Install the tools you actually use: [Cursor CLI](https://cursor.com/docs/cli/installation), [Claude Code](https://code.claude.com/docs/en/quickstart), [Codex CLI](https://developers.openai.com/codex/cli).
3. **More agents** -- From your project root: **`bash .ralph/new-agent.sh`** to scaffold extra agent profiles.

### Dashboard

**After install into another project (from the target project root):**
```bash
cd .ralph/ralph-dashboard
npm ci
npm run build
npm run start
```

Use `PORT=8124 npm run start` to run on a different port. By default the UI is at **http://127.0.0.1:8123**. It reads **`.ralph-workspace/orchestration-plans`**, **`.ralph-workspace/artifacts`**, and **`.ralph-workspace/logs`** next to your repo root.

## Run a plan (typical commands)

- **Cursor:** `.ralph/run-plan.sh --runtime cursor --plan PLAN.md --workspace .`
- **Claude:** `.ralph/run-plan.sh --runtime claude --plan PLAN.md --workspace . --model claude-haiku-4-5`
- **Codex:** `.ralph/run-plan.sh --runtime codex --non-interactive --plan PLAN.md --workspace . --agent architect`
- **OpenCode:** `.ralph/run-plan.sh --runtime opencode --plan PLAN.md --workspace . --model opencode/nemotron-3-super-free`

Ralph now treats the project root (where your `.ralph/` copy and plans live) as separate from the workspace root (where `.ralph-workspace/` stores logs, artifacts, and session files). Use `--workspace` (or the alias `--project-root`) to point at the project directory and `--workspace-root` to place `.ralph-workspace` elsewhere (it defaults to `<project>/.ralph-workspace` when you omit it). You can also override the workspace root with `RALPH_PLAN_WORKSPACE_ROOT` when you prefer environment variables to flags.

**CLI contracting:** `run-plan.sh` uses the strict parser in `bundle/.ralph/bash-lib/run-plan-args.sh`: only documented flags are accepted (unknown flags are an error), and plan and workspace paths are not positional. You must pass `--plan <path>`. Pass `--workspace <path>` for an explicit repo root; if you omit it, the workspace defaults to the current working directory. Orchestration and docs usually show all three flags for clarity.

### Canonical run-plan invocation

Invoke the runner by explicitly passing the workspace root, plan file, and runtime. A canonical command looks like:

```bash
cd /path/to/project
./.ralph/run-plan.sh --workspace /path/to/project --plan plans/feature.md --runtime cursor
```

Add `--workspace-root /path/to/.ralph-workspace` to that command whenever you need to keep logs/artifacts/sessions outside the project folder.

Each invocation must supply the same flags because the parser in `bundle/.ralph/bash-lib/run-plan-args.sh` refuses positional workspace arguments.

### How orchestration invokes the runner

`.ralph/orchestrator.sh` executes `.ralph/run-plan.sh` once per stage, reusing the stage’s `plan`, `runtime`, and the workspace path. For example, a stage definition such as:

```json
{
  "id": "design",
  "runtime": "cursor",
  "plan": ".ralph-workspace/orchestration-plans/feature/design.md"
}
```

results in an orchestrator command similar to:

```bash
RALPH_ARTIFACT_NS=feature \
./.ralph/run-plan.sh --workspace /path/to/project --plan .ralph-workspace/orchestration-plans/feature/design.md --runtime cursor
```
Add `--workspace-root /path/to/.ralph-workspace` when the workspace state lives outside the project directory so the runner and dashboard stay in sync.

Stage overrides like `--agent`, `--model`, or `--cli-resume` are layered on top of this base invocation before the orchestrator starts each stage.

When you define `artifacts` or `outputArtifacts` in an orchestration file, those paths are the authoritative outputs for the run. The agent config `output_artifacts` field is only a fallback when a stage does not define its own artifact declarations. Keep generated logs and artifacts under the workspace root’s `.ralph-workspace/logs/` and `.ralph-workspace/artifacts/` so the dashboard and orchestration checks can discover them consistently.

**Checklist syntax:** Open tasks must look like **`- [ ]`** (space before **`]`**). The form **`- []`** is ignored, so the runner may stop while lines still look unfinished.

### When the runner needs you

**`.ralph/run-plan.sh`** follows an **interactive-first** human flow: in a normal terminal it usually asks you there and continues. Without a TTY, it drops prompts into files such as **`pending-human.txt`** and **`operator-response.txt`** under the workspace root’s **`.ralph-workspace/sessions/<RALPH_PLAN_KEY>/`** (default; override with **`--workspace-root`** or **`RALPH_PLAN_WORKSPACE_ROOT`**) and waits while you edit them. That directory also holds **`human-replies.md`**. Orchestrated runs can escalate human input through a helper script configured via **`RALPH_HUMAN_ACK_TOOL`** (the orchestrator script itself does not provide `--human-ack`). Optional hooks and exit behavior are described in **[Agent workflow](docs/AGENT-WORKFLOW.md)**.

### CLI session resume

Out-of-process restarts and operator-driven re-invocations can pick up the most recent assistant session by reusing the CLI context. When enabled, `.ralph/run-plan.sh` writes the current `session-id` to the workspace root’s **`.ralph-workspace/sessions/<RALPH_PLAN_KEY>/session-id.txt`** (the plan key defaults to the plan file name) and supplies that ID plus a compact context block to the next runtime invocation so the session continues where it left off. For non-Claude prebuilt agents, that block is compact by default and can be forced with `RALPH_COMPACT_CONTEXT=1` or the equivalent `--compact` context mode.

**Enable CLI session resume (pick one):**

- Set `RALPH_PLAN_CLI_RESUME=1` before invoking `.ralph/run-plan.sh`.
- Pass `--cli-resume` to the runner command.
- Answer `yes` to the interactive prompt (TTY-attached runs ask unless you already set `RALPH_PLAN_CLI_RESUME`, supplied `--cli-resume`, or explicitly opt out with `--no-cli-resume`).

**Storage and prerequisites:**

- `session-id.txt` lives under `.ralph-workspace/sessions/<RALPH_PLAN_KEY>/session-id.txt`, and each invocation rewrites or updates the file so future restarts always read the newest ID for that namespace.
- Python 3 is required for `.ralph/bash-lib/run-plan-cli-json-demux.py`, the helper that pulls the session ID from the CLI’s JSON demux stream. If Python 3 is unavailable, the runner logs `Warning: RALPH_PLAN_CLI_RESUME needs python3 ... running without it.` (per `bundle/.ralph/bash-lib/run-plan-invoke-*.sh`) and skips resume, starting a fresh session.

**Manual resume from a known session id:**

If you already captured a session id (for example from `.ralph-workspace/sessions/<RALPH_PLAN_KEY>/session-id.txt` or the earlier prompt that confirmed session reuse), pass `--resume <session-id>` to `.ralph/run-plan.sh`. The runner reuses that CLI session without requiring `--cli-resume`, and it writes whichever session id you use back into `.ralph-workspace/sessions/<RALPH_PLAN_KEY>/session-id.txt` so it stays available for future runs or automation.

**Optional unsafe bare resume:**

In CI or isolated environments where you trust there will not be session mix-ups, you can resume without relying on the stored ID:

- Set `RALPH_PLAN_ALLOW_UNSAFE_RESUME=1` or pass `--allow-unsafe-resume` to `.ralph/run-plan.sh`.
- The runner will attempt to resume directly (e.g., Codex `--last` semantics) even if `.ralph-workspace/sessions/<RALPH_PLAN_KEY>/session-id.txt` is absent.
- **Warning:** Bare resume without a stored session ID may attach to the wrong session on a shared workstation; prefer isolated CI or the session files above for safety.

### Orchestration (multi-stage)

```bash
.ralph/orchestrator.sh --orchestration .ralph-workspace/orchestration-plans/my-feature/my-feature.orch.json
```

You can pass the **`.orch.json`** path as the first argument with no flag; details are in the header of **`.ralph/orchestrator.sh`** (see [bundle copy](bundle/.ralph/orchestrator.sh) on GitHub). To scaffold a pipeline, run **`.ralph/orchestration-wizard.sh`**.

**Walkthroughs:** [Orchestrated example](docs/orchestrated-ralph-example.md) and [single-runner example](docs/worker-ralph-example.md).

## Documentation

| Guide | What you get |
|-------|----------------|
| [Index](docs/README.md) | Map of all topics and quick reference |
| [Installation](docs/INSTALL.md) | Submodule, subtree, flags, partial installs, cleanup |
| [Agent workflow](docs/AGENT-WORKFLOW.md) | Plan loop, human input, orchestration, cleanup, sample prompts |
| [MCP](docs/MCP.md) | Bash MCP server, host config, guard rails, third-party MCP for plan agents (e.g. browser) |
| [Claude agent teams](docs/CLAUDE-AGENT-TEAMS.md) | Using Claude Code teams alongside Ralph |
| [Security](docs/SECURITY.md) | Sandboxing reality, `.cursorignore`, hooks, practical caution |

**Further reading (Ralph technique):** 

- [Ralph Cursor Guide](https://forum.cursor.com/t/ralph-cursor-guide/149998) -- Cursor Community Forum
- [Ralph Wiggum as a "software engineer"](https://ghuntley.com/ralph/) -- Geoffrey Huntley
- [Ralph Wiggum: AI loop technique](https://awesomeclaude.ai/ralph-wiggum) -- Awesome Claude

Runtime-specific READMEs: [.cursor/ralph](bundle/.cursor/ralph/README.md), [.codex/ralph](bundle/.codex/ralph/README.md), [.opencode/ralph](bundle/.opencode/ralph/README.md). Orchestration JSON shape: comments in **`.ralph/orchestrator.sh`** and **`.ralph/orchestration.template.json`**.

**MCP server (needs `jq`):**

```bash
RALPH_MCP_WORKSPACE="$PWD" bash .ralph/mcp-server.sh
```

Details: [MCP.md](docs/MCP.md).

## Be Safe

Ralph can run **many** agent turns in a row, repeatedly without human intervention. That is powerful and risky: bad prompts or bugs can change files, run shell commands, or expose what is on disk. Use it when you understand that tradeoff. **[Security](docs/SECURITY.md)** explains what is actually sandboxed, what is not, and how to harden your workspace.

## Monitor your token usage

Cost comes from two places: the **prompt bytes** sent at the start of each turn, and the **runtime context/tool-output** that can accumulate as the session grows. Keep prompts short and targeted, prefer partial reads over full logs or huge files, and write TODOs that point at the smallest relevant path or line range so the next turn does not have to re-read unnecessary data. Also choose a model that fits the job, keep TODOs concrete, and watch Cursor, Anthropic, or OpenAI billing so you are not surprised.

## License

MIT -- see [LICENSE](LICENSE).

## Support Ralph
Please take a moment to [leave a star](https://github.com/JoshJancula/ralph/stargazers) if you found this repository useful.

<img src="./public/ralph-coding.jpeg" alt="" />
