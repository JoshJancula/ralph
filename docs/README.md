# Ralph documentation

**Audience:** These pages are human-facing documentation for operators. **AI agents** (Claude Code, Cursor, Codex, OpenCode, and others) should rely on [AGENTS.md](../AGENTS.md) and open a docs page only when AGENTS.md directs them to it.

These pages assume you have **installed Ralph into a project** using **`install.sh`** (see **[INSTALL.md](INSTALL.md)** for submodule, subtree, flags, and removal, or the quick start in the main **README**). Unless we say otherwise, paths are from **your project root**: the directory that contains **`.ralph/`**, **`.cursor/`**, and the rest.

Ralph keeps runtime state (logs, artifacts, sessions) under a **state root** that contains **`.ralph-workspace/`** (default: `<project-root>/.ralph-workspace`, overridable via `--workspace-root` or `RALPH_PLAN_WORKSPACE_ROOT`). The **agent workspace** (`--agent-workspace` / `RALPH_AGENT_WORKSPACE`) is the sandboxed work tree where assistants read and write project files; it defaults to the directory that invoked `run-plan.sh`. References to `.ralph-workspace` point at the state root, not the project or agent workspace. See [ENVIRONMENT.md](ENVIRONMENT.md#core-plan-runner-and-workspace).

The installer copies this documentation into **`.ralph/docs/`** in that project. Read it from either place; the content is the same.

## Guides

Pick what matches what you are doing. You can read them in any order.

| Guide | What it is for |
|-------|----------------|
| [INSTALL.md](INSTALL.md) | Installing Ralph: global install (recommended), in-repo install, `install.sh` flags, uninstall |
| [AGENT-WORKFLOW.md](AGENT-WORKFLOW.md) | Plan loop, human input, prompts, and execution ownership |
| [worker-ralph-example.md](worker-ralph-example.md) | One plan, one runtime, end to end: where logs and artifacts go |
| [orchestrated-ralph-example.md](orchestrated-ralph-example.md) | Sequential pipeline examples (classic orchestration as Sequential internals) |
| [WORKFLOWS.md](WORKFLOWS.md) | Core operating model, Sequential vs Dependency, status/watch terminal viewer, seven bundled SDLCs, planner/`planInput`, authoring |
| [CLAUDE-AGENT-TEAMS.md](CLAUDE-AGENT-TEAMS.md) | Claude Code **agent teams** next to Ralph: when teams help vs a single plan vs a workflow |
| [MCP.md](MCP.md) | Ralph bash MCP server (`jq`), host wiring, and **third-party MCP** (e.g. Playwright for QA) per runtime |
| [TOOLING.md](TOOLING.md) | Optional Ralph mode (`--ralph-mode` / `RALPH_MODE`): MCP proxy tools, shell output compaction, native adapters per runtime, overlay cleanup |
| [ENVIRONMENT.md](ENVIRONMENT.md) | Full environment variable reference, session/resume controls, workflow terminal UI, feature gates, models |
| [SECURITY.md](SECURITY.md) | Trust and scope: what Ralph sandboxes, what it does not, what it changes on disk, `.cursorignore`, hooks, Codex caveats, killswitch configuration |
| [BENCHMARKS.md](BENCHMARKS.md) | Token and compaction benchmark report across Ralph optimization paths (run `ralph benchmark`) |

## Quick reference

- **Open tasks:** `- [ ]` (space inside the brackets). **Done:** `- [x]`. **Not a task:** `- []`.
- **Create commands (only two):** `ralph create plan` scaffolds a leaf plan (`--format classic` or `yaml`). `ralph create workflow` scaffolds a reusable workflow (`--mode sequential` or `--mode dependency`). Older format tokens (`standard`, `structured`, `pipeline`, `cursor`) remain aliases for `yaml`.
- **Run a leaf plan:** `ralph run --plan <path>` runs classic or YAML checklists through `run-plan.sh`. Workflow-shaped inputs are refused with the workflow-start replacement.
- **Start a workflow:** Task-based `ralph workflow start feature-delivery --task "..."` or supplied-plan `ralph workflow start plan-delivery --plan <path>`. Inspect with `ralph workflow inspect`, list with `ralph workflow list`. See [WORKFLOWS.md](WORKFLOWS.md).
- **Models:** `ralph models list <claude|codex|cursor|opencode|antigravity>` lists models (saved store for Claude/Codex; native CLI discovery for Cursor/OpenCode/Antigravity). `ralph models add|remove <claude|codex> [id]` manages the saved store at `${RALPH_CONFIG_HOME:-${XDG_CONFIG_HOME:-$HOME/.config}/ralph}/models.json`. See [ENVIRONMENT.md](ENVIRONMENT.md#models).
- **Sequential workflows:** `ralph create workflow --mode sequential` uses classic orchestration as the Sequential implementation (ordered stages / parallel waves with artifact handoffs).

## Runtime vocabulary

- A **runtime agent** is the agent/session supplied by the selected provider runtime. It executes the prompt, uses native tools, and owns task changes in the assigned agent workspace.
- A **workflow stage** is an attributable step in a reusable SDLC. Stage guidance is inline `instructions:` on the workflow definition.
- A **runtime-native subagent** is a child assistant launched through the provider runtime's own subagent feature. The runtime controls it; the parent runtime agent remains responsible for the Ralph TODO and its declared artifacts.
- A **delegated run** is a Ralph-supervised child execution requested by a runtime agent. The child owns only explicitly assigned result artifacts or changes, while the parent owns the initiating TODO, final verification, and completion decision.

The word **agent** remains intentional for runtime agents, vendor-native terms, `--agent-workspace`, and related CLI surfaces. **Subagent** remains the runtime-native child term.

## CLI session resume

Out-of-process restarts and operator-driven re-invocations can pick up the most recent assistant session by continuing the same CLI context. When enabled, `.ralph/run-plan.sh` records the current `session-id` in **`.ralph-workspace/sessions/<RALPH_PLAN_KEY>/session-id.<runtime>.txt`** (for example `session-id.opencode.txt`; the plan key defaults to the plan file name) and replays a compact context block (TODO + plan path + human replies only) the next time the same runtime runs under that namespace. For non-Claude runtime agents, the block is compact by default and can also be requested with `RALPH_COMPACT_CONTEXT=1` or `--compact`.

**Enable CLI session resume (pick one):**

- Set `RALPH_PLAN_SESSION_STRATEGY=resume` (or `reset` or `compact`) before running `.ralph/run-plan.sh`, or pass `--session-strategy resume|reset|compact`.
- Set `RALPH_PLAN_CLI_RESUME=1` before running `.ralph/run-plan.sh`.
- Pass `--cli-resume` to the runner command.
- Answer `yes` when the interactive prompt appears (TTY-attached runs ask unless `RALPH_PLAN_CLI_RESUME`, `--cli-resume`, or `--no-cli-resume` is already provided). Interactive TTY runs also prompt for session strategy choice (fresh/resume/reset/compact) unless already set.

**Session strategy modes:**

- `fresh` mode (default) aka **The Meeseeks Technique**, if you've seen Rick and Morty, `fresh` mode is a Meeseeks box. Press the button (the runner picks the next open TODO), a Meeseeks pops into existence with one job and no history, does that job, and blinks out once it's confirmed complete. The next TODO summons a brand new Meeseeks that has never heard of the last one. This is a deliberate isolation strategy, not a limitation: each TODO gets a clean context window, no drift from earlier turns, no leftover assumptions from a task that isn't its own. If you want continuity across TODOs instead, that's what `resume`, `reset`, and `compact` are for. TODOs can be as vague or as broad as you write them, but we recommend keeping them simple and achievable, the same way you'd brief a Meeseeks: a clear, well-scoped task lets the agent finish cleanly, while a vague, open-ended one gives it room to thrash.
- `resume` mode keeps the same CLI session across TODOs with no reset or compact command injected: the agent retains full prior turns and accumulated context from every earlier TODO in the plan. Use it when later TODOs benefit from remembering decisions made earlier in the run; be aware context grows unbounded over a long plan.
- `reset` mode reuses the session ID but prefixes each TODO prompt with a reset command when configured (Claude defaults to `/clear`). Override with `RALPH_PLAN_RESET_COMMAND` globally or `RALPH_PLAN_RESET_COMMAND_<RUNTIME>` per runtime.
- `compact` mode is similar to `reset` but prefixes a compact-optimized command instead: `/compress` for Cursor (overridable with `RALPH_PLAN_COMPACT_COMMAND_CURSOR`), `/compact` for Codex (`RALPH_PLAN_COMPACT_COMMAND_CODEX`), or `/clear` for Claude (`RALPH_PLAN_RESET_COMMAND_CLAUDE`). OpenCode does not support compact mode; use fresh/resume/reset instead. Override all runtimes with `RALPH_PLAN_COMPACT_COMMAND`.

**Storage and prerequisites:**

- `session-id.<runtime>.txt` lives under `.ralph-workspace/sessions/<RALPH_PLAN_KEY>/`, so restarts always read the newest ID for that runtime when they resume.
- Python 3 is required for `.ralph/python/run-plan-cli-json-demux.py`, the helper that extracts the session ID from the CLI’s JSON demux output. If Python 3 is unavailable, CLI resume is skipped and the plan starts from a fresh session.

**Optional unsafe bare resume:**

In CI or isolated workflows where you trust there will be no session mix-up, you can resume without a stored ID:

- Set `RALPH_PLAN_ALLOW_UNSAFE_RESUME=1` or pass `--allow-unsafe-resume` when running `.ralph/run-plan.sh`.
- The runner attempts to resume without consulting `.ralph-workspace/sessions/.../session-id.<runtime>.txt` (e.g., Codex `--last` semantics).
- **Warning:** Bare resume without a session ID may attach to the wrong session on a shared box; prefer stored session files when possible.

## Shell output compaction

Ralph summarizes high-volume command output (test runs, git status, build logs, listing commands) to save tokens and context. Compaction is **reversible**: the full original output is stored and retrievable via `ralph_proxy_result_*` tools, so agents can drill down when needed.

**Enable shell output compaction (MCP mode, all runtimes):**

```bash
# hybrid mode auto-enables RALPH_PROXY_SHELL_COMPACT (Cursor recommended path)
.ralph/run-plan.sh --runtime cursor --plan PLAN.md --workspace . \
  --ralph-mode hybrid
```

With `--ralph-mode ralph` or `--ralph-mode no`, set `RALPH_PROXY_SHELL_COMPACT=1` explicitly before running to enable MCP compaction.

**Enable native Bash output compaction (Claude only):**

```bash
RALPH_BASH_COMPACT=1 \
.ralph/run-plan.sh --runtime claude --plan PLAN.md --workspace .
```

**Supported command families:** `git status`, `git diff`, `bats`, `grep`, `find`, `npm test`, `pytest`, `vitest`, `tsc`, `eslint`, `cargo test`, `go test`, `ls`, `tree`, `docker ps`, `docker logs`, `kubectl`, `gh pr view`, `gh pr list`, and more.

**Supported command families, defaults by mode, and the retrieval workflow:** [TOOLING.md#shell-output-compaction](TOOLING.md#shell-output-compaction).

If you want Ralph to compact repeated tool-turn history inside the plan loop, use `RALPH_PLAN_TRANSCRIPT_EVICTION` (`safe` by default in `ralph`/`hybrid`). That setting trims the runner-owned continuation summary, not the underlying runtime transcript.

## Telemetry and usage tracking

Ralph logs token usage, compaction savings, hook telemetry, and other metrics per plan invocation. Usage data lands in:

```
.ralph-workspace/logs/<plan-key>/invocation-usage.json
```

Per-run summary: `.ralph-workspace/runtime-config/<plan-key>/summary.json` (aggregate rebuilt from `summaries/<runtime>.json` when multiple runtimes share a `plan_key`; includes `native_hooks_effective`, overlay fields, `byte_savings_by_channel`, and mutation counts).

Plan-aggregate telemetry (discover report): `.ralph-workspace/logs/<plan-key>/discover-report.json` (includes compaction events, missed savings, low-value filters, and optimization opportunities).

These are local run artifacts, not uploaded. Dashboard visualization is optional; metrics are human-readable JSON. More on telemetry: [TOOLING.md#telemetry](TOOLING.md#telemetry).

Print a detailed usage report for the current workspace, or scope it to one
workflow's stage attempts:

```bash
ralph usage
ralph usage --run run-20260827T183012Z-feature-delivery-a1b2c3
```

Plan runners print their per-plan summary when they exit. Workflow lifecycle
commands print the run aggregate when they return to the terminal; a detached,
still-running workflow is explicitly marked as a partial report.

## Benchmark report

After you have run at least one plan, build the benchmark report from the usage logs:

```
ralph benchmark                 # print the Markdown report for the current workspace
ralph benchmark --full          # aggregate across all registered workspaces
ralph benchmark --format json   # machine-readable report JSON
ralph benchmark --write-doc     # also regenerate docs/BENCHMARKS.md
```

It aggregates every `.ralph-workspace/logs/<plan-key>/plan-usage-summary.json` into one report
(token and compaction figures per optimization path and per optimization channel) and is the source for [BENCHMARKS.md](BENCHMARKS.md).
Under the hood `ralph benchmark` runs `ralph-benchmark-report.py` (aggregate) then
`render-benchmark-markdown.py` (render) for you; unreadable summaries are skipped with a warning.

**Trust model:** For **new runs**, the report's **Optimization by channel** section is authoritative: each savings row names an exact channel id (`proxy_read_windowing`, `proxy_shell`, `stored_result_readback`, and others; see [TOOLING.md#optimization-channel-attribution](TOOLING.md#optimization-channel-attribution)). **Historical runs** without channel metadata appear under **Legacy / unknown attribution**; treat those totals as approximate until a new run records exact channels. Tool-adoption diagnostics (**Improvement opportunities**, native-read share, proxy adoption) are separate from optimization evidence and do not prove byte savings.
