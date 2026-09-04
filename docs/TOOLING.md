# Tooling: Ralph mode, compaction, and native adapters

By default, a plan run uses each assistant's own tools and nothing else. **Ralph mode** is an optional layer on top: it can add Ralph's MCP tools to the run (bounded reads, searches, and shell commands), shrink noisy command output before it reaches the model, and wire in runtime-specific hooks. In `hybrid`, those layers are meant to work together: MCP compaction is authoritative, native adapters are staged where the runtime supports them, and strict-proxy defaults on after preflight. Everything here is opt-in; the default mode is `no`.

This page covers Ralph mode on plan runs (`.ralph/run-plan.sh` / `ralph run-plan`). For wiring the Ralph MCP server into an IDE or other long-lived host, see [MCP.md](MCP.md).

## The four modes

| Mode | Ralph MCP tools | Native adapters (hooks) | When to use it |
|------|-----------------|-------------------------|----------------|
| `no` (default) | None | Off | You want the assistant's stock behavior |
| `native` | Result-retrieval tools only | On | You want hook-based compaction but the assistant's own tools |
| `ralph` | Full catalog | Off | You want Ralph's bounded tools without touching runtime config |
| `hybrid` | Full catalog | On | You want the full Ralph contract: bounded MCP tools, native adapters, and the default strict-proxy policy |

Two ideas to keep apart:

- **Ralph MCP tools** are extra tools served over MCP: `ralph_proxy_read`, `ralph_proxy_grep`, `ralph_proxy_glob`, `ralph_proxy_shell`, and friends. They bound how much output reaches the model and store full originals for later retrieval.
- **Native adapters** are runtime-specific hooks (Claude settings hooks, Cursor `hooks.json`, Codex `--config` hooks, an OpenCode plugin) that Ralph merges in for one run and restores afterward. What they can actually do differs per runtime; see [Native adapters per runtime](#native-adapters-per-runtime).

The plan log header shows `Ralph Mode: <mode>` so you always know what a run used.

## Turning it on

```bash
# Everything: Ralph MCP + native adapters (recommended when opting in)
.ralph/run-plan.sh --runtime claude --plan PLAN.md --workspace . --ralph-mode hybrid

# Ralph MCP tools only
.ralph/run-plan.sh --runtime claude --plan PLAN.md --workspace . --ralph-mode ralph

# Native adapters only; result tools available for stored output
.ralph/run-plan.sh --runtime claude --plan PLAN.md --workspace . --ralph-mode native
```

| Flag / env | Purpose |
|------------|---------|
| `--ralph-mode <no\|native\|ralph\|hybrid>` | Sets the mode for this run |
| `RALPH_MODE` | Same as the flag; set it to skip the interactive prompt |

You can also save a default in `.ralph-workspace/preferences.json`:

```json
{ "ralph_mode_default": "no" }
```

Interactive terminal runs prompt for a mode when nothing chose one (no flag, no env, no saved preference). Non-interactive runs never prompt; with nothing set they use `no`.

**Compaction defaults by mode:** in `ralph` or `hybrid` mode, Ralph sets `RALPH_PROXY_SHELL_COMPACT=1` (MCP shell compaction) unless you already exported the variable. In `native` or `hybrid` mode, it sets `RALPH_BASH_COMPACT=1` (Claude native Bash compaction) the same way. Export either as `0` to opt out. In `no` mode both stay off unless you enable them yourself.

**Transcript eviction defaults by mode:** `RALPH_PLAN_TRANSCRIPT_EVICTION` defaults to `safe` in `ralph` or `hybrid` mode and to `off` in `no` or `native` mode unless you override it. `safe` keeps the runner-owned continuation summary on and renders it more compactly so older repetitive tool-turn detail can be collapsed into a shorter prompt block; `aggressive` tightens the summary further and may lower the context budget. This is prompt pruning, not literal deletion of the runtime transcript.

## What tools you get

When Ralph MCP is active, `tools/list` always includes the orchestration and result tools. The proxy read/search/shell tools appear in `ralph` and `hybrid` modes only. Tool order is deterministic (sorted by name).

| Tool | Purpose | Modes |
|------|---------|-------|
| `ralph_run_plan`, `ralph_plan_status`, `ralph_orchestrator_run` | Run plans and pipelines, check plan status | `native`, `ralph`, `hybrid` |
| `ralph_proxy_result_read` / `_search` / `_summary` | Read, search, or summarize stored full outputs by `resultId` | `native`, `ralph`, `hybrid` |
| `ralph_proxy_read`, `ralph_proxy_grep`, `ralph_proxy_glob` | Bounded file read, search, and glob | `ralph`, `hybrid` |
| `ralph_proxy_shell` | Run a shell command with policy checks and bounded output | `ralph`, `hybrid` |
| `ralph_proxy_shell_start` / `_wait` / `_status` / `_read` / `_cancel` | Async job lifecycle for long-running commands (avoids MCP timeouts). Manual fallback when a human is monitoring a job — not the automation path for durable TODO waits (use opt-in `RALPH_BG_JOBS` + `.ralph/ralph-bg.sh` / Stop hooks; see [Background jobs and Stop hook continuation](#background-jobs-and-stop-hook-continuation)). Prefer `_wait` for blocking waits, treat `_status` as a manual follow-up, never short-interval polling loops. Hide with `RALPH_PROXY_SHELL_ASYNC=0`. Runner-first `verify:` remains the default completion path. | `ralph`, `hybrid` |

There are no `ralph_proxy_edit` or `ralph_proxy_write` tools; agents keep using runtime-native edit tools for modifications. The standalone MCP server refuses to start with `RALPH_MODE=no`.

MCP hosts namespace these names, so Claude and Codex advertise them as `mcp__ralph__ralph_proxy_read` and so on. Script against the names the runtime exposes.

In `ralph` and `hybrid` modes, the prompt also tells agents to prefer the proxy tools for exploration, to use the result tools whenever a response is truncated or contains a `resultId` (preview-first, then `view=compacted`, then `view=raw` only when needed), and to keep native edit/write tools for file changes. In `hybrid`, native hook compaction is an optimization layer, not the source of truth: if a runtime cannot prove its native hook path, MCP compaction remains the authoritative path.

## How injection works per runtime

In `ralph` or `hybrid` mode, each runtime gets an ephemeral MCP config pointing at the active install's `mcp-server.sh` (workspace-local `.ralph/mcp-server.sh`, or `$RALPH_HOME/bundle/.ralph/mcp-server.sh` for `ralph run-plan`; override with `RALPH_MCP_PROXY_SERVER_SCRIPT`). Whatever the mechanism, Ralph backs up any file it touches and restores it when the run ends.

**MCP precedence in Ralph mode (highest to lowest):**

1. Native ambient MCP servers from the runtime's own configuration chain
2. Ralph's protected `ralph` MCP server, layered only when the selected mode
   requires it

Workflow stage fields cannot define, override, or reference MCP servers. Ralph
adds only its protected server; native ambient MCP remains runtime-owned.

| Runtime | Mechanism | Notes |
|---------|-----------|-------|
| Claude | Temp config containing only the `ralph` server via `--mcp-config <temp>`, without `--strict-mcp-config`, so native MCP discovery stays on and ambient servers are never rebuilt into the temp file | Incompatible with `CLAUDE_PLAN_BARE=1`. Once the MCP preflight passes, Ralph strips native `Bash` so commands go through `ralph_proxy_shell` (`RALPH_CLAUDE_RALPH_STRICT_PROXY=0` keeps native Bash). Native `Read`/`Edit`/`Write` stay available. Outside a Ralph mode, Claude minimal mode may lock down with `--strict-mcp-config` and an empty catalog (`CLAUDE_PLAN_MINIMAL_DISABLE_MCP`; see ENVIRONMENT.md). |
| Cursor | Merges only `mcpServers.ralph` into `<workspace>/.cursor/mcp.json`, restores on exit | Requires `jq` when an existing config must be validated; invalid existing JSON fails before the run starts and is never modified. Runs with `--approve-mcps`. |
| Codex | Per-run `--config mcp_servers.ralph.*` overrides after native config load | Sets `enabled=true`, `required=true`, and the configured tools approval mode. Native tools and native MCP remain alongside Ralph tools. |
| OpenCode | Temp config via `OPENCODE_CONFIG` merging only Ralph's server with native config | JSONC comments survive. In `hybrid`, native OpenCode tools and Ralph MCP tools are both available; Ralph does not deny native tools to control context. Strict proxy enforcement is unsupported unless `RALPH_OPENCODE_ALLOW_STRICT_PROXY_BESTEFFORT=1` enables a post-run audit. See [OpenCode hybrid contract](#opencode-hybrid-contract). |
| Antigravity | Temp config via `ANTIGRAVITY_CONFIG` only when Ralph's server is needed | Preserves native `.agents/agents.md`, rules, skills, workflows, and existing `.agents/mcp_config.json`. |

**Strict proxy mode:** `RALPH_AGENT_TOOL_ACCESS_REQUIRE_PROXY=1` (alias `RALPH_STRICT_PROXY=1`) fails a run that bypasses Ralph proxy tools with native reads or searches, instead of just logging a warning. Codex strict runs add a live preflight that proves a real `ralph_proxy_read` works before the plan starts.

**Kill switch:** a fatal policy violation writes a sentinel under `.ralph-workspace/security/kill-switch.<plan-key>.json` and the run exits non-zero, so orchestrator stages fail instead of advancing. Stale sentinels from earlier runs are logged and ignored. See [SECURITY.md](SECURITY.md).

## Prompt layering and stage instructions

Ralph assembles prompts in this order:

1. Existing Ralph execution and safety preamble
2. Optional workflow stage instructions block (`WORKFLOW_STAGE_INSTRUCTIONS`)
   when the current stage declares inline `instructions:`
3. Resolved stage and TODO contracts
4. The current task

Ralph never inlines removed `role:` / profile-agent metadata, runtime rules,
skills, MCP definitions, or artifact contracts as a substitute identity.
Native runtime configuration supplies those native capabilities; Ralph supplies
declared stage/TODO contracts and any stage `instructions:` text.

## Native subagents

`nativeSubagents` is a runtime behavior setting, not a Ralph delegation
mechanism. It accepts `off` or `inherit`:

- Standard leaf TODOs default to `inherit`.
- Workflow agent stages (Sequential and Dependency) default to `off` where the
  runtime has a proven deny boundary.
- Consensus voters compile to `off`.
- `inherit` leaves ambient runtime-native subagents unchanged. Their activity
  is opaque and parent-owned; Ralph does not create a child ledger entry.
- **Native subagents never replace or satisfy plan TODOs or stage completion.**
  The parent runtime agent remains responsible for every write, verification
  step, declared artifact, and completion decision.
- `off` is enforced at the runtime boundary when that runtime supports a
  tested deny control. Prompt wording is never used as suppression.

The old `subagents` and `delegation.native` controls are removed. Use
delegated runs when Ralph-managed child execution, artifacts, or completion
evidence is required. See [DELEGATION.md](../bundle/.ralph/docs/DELEGATION.md).

## Shell output compaction

Test runs, `git status`, build logs, and listing commands can dump thousands of lines into the model's context. Compaction summarizes that output and stores the full original so nothing is lost.

The safety contract, in plain terms:

1. **Reversible.** When output is compacted (or a command fails), the complete raw stdout/stderr is stored under `.ralph-workspace/tool-results/<plan-key>/results/<resultId>.txt`. Agents fetch it with the `ralph_proxy_result_*` tools.
2. **Declared.** Compacted responses are a JSON envelope with `shellCompact: true`, a bounded `preview`, the `resultId`, and flags saying which streams were summarized. The agent always knows what it got.
3. **Fail open.** Binary output, empty output, and crashed compactors pass through raw. Compaction is rejected outright when it would not make the output smaller.

### What gets compacted

Single commands are classified into families; compound pipelines are not compacted. Families include:

| Group | Commands |
|-------|----------|
| Git | `git status`, `git diff` |
| Search and listing | `grep`/`rg`, `find`, `ls`, `tree` |
| Tests and builds | `bats`, `npm test`, `vitest`, `pytest`, `cargo test`, `go test`, `tsc`, `eslint` |
| Operations | `docker ps`, `docker logs`, `kubectl`, `gh pr view`, `gh pr list` |

Each family keeps what matters (failed test names, error lines, file paths, counts) and drops the noise. Source-bearing output such as `git diff`, `git show`, and `grep`/`rg` passes through unchanged. Unknown commands also pass through raw unless `RALPH_COMPACT_GENERIC_FALLBACK=1` explicitly enables the generic head-plus-tail-plus-errors fallback.

Beyond the built-in Python compactors, simple pattern-based rules can be added as JSON ("DSL rules") via `RALPH_COMPACTOR_DSL_RULES_PATH`; the built-ins live in `bundle/.ralph/bash-lib/compactor-dsl-builtin-rules.json`. Both kinds go through the same safety gate.

When no command is known at all (for example a stored result with no attached command text), Ralph will fall back to classifying output by shape alone. When a command *is* known but unsupported, shape-based classification never assigns it a semantic family (for example a `docker logs`-style summary) -- an unsupported command with log-like output either falls back to the generic size-triggered summary or passes through unchanged. This prevents an unrelated command from being silently misreported as something it is not.

### Bounded search source capture

`ralph_proxy_search`'s owned grep path additionally bounds how much raw source it will read from the underlying command (byte, line, and per-line-byte caps; see `RALPH_MCP_PROXY_POLICY_OWNED_GREP_SOURCE_*` in [ENVIRONMENT.md](ENVIRONMENT.md#grep-source-capture-caps-ralph_mcp_proxy_policy_owned_grep_source_)). These safety caps apply even though the normal response is direct source output. The legacy `RALPH_MCP_EXPLORATION_RESULT_COMPACT=1` envelope reports `sourceComplete: false` with a `capReason` when a cap is hit; otherwise narrow the search and re-run rather than assuming a capped stream is complete.

### Retrieving the original

1. Call `ralph_proxy_shell`; the response envelope includes `resultId`.
2. `ralph_proxy_result_read` with `{"resultId": "<id>"}` returns the stored JSON; `.stdout` and `.stderr` hold the full text.
3. `ralph_proxy_result_search` with `{"resultId": "<id>", "pattern": "FAILED"}` searches within it.
4. `ralph_proxy_result_summary` returns metadata and a preview.

### Enabling and disabling

| Setting | Effect |
|---------|--------|
| `--ralph-mode ralph` or `hybrid` | MCP compaction on by default (`RALPH_PROXY_SHELL_COMPACT=1` when unset) |
| `--ralph-mode native` or `hybrid` | Claude native Bash compaction on by default (`RALPH_BASH_COMPACT=1` when unset) |
| `RALPH_PROXY_SHELL_COMPACT=0` | Turn off MCP compaction even in `ralph`/`hybrid` |
| `RALPH_BASH_COMPACT=0` | Turn off Claude native Bash compaction even in `native`/`hybrid` |
| `RALPH_COMPACT_GENERIC_FALLBACK=1` | Opt into generic compaction for unknown large shell output |
| `RALPH_COMPACT_GENERIC_THRESHOLD_BYTES=<n>` | Resize the generic fallback threshold |
| `--ralph-mode no` | Everything off unless you set the variables yourself |

Native adapter compaction stores originals in the same place as MCP compaction, and the same retrieval tools work on both. That shared storage is what makes `hybrid` safe when a runtime's native hook path is only partially proven: the compacted transcript still points at the same stored originals.

## Named tooling profiles

Instead of setting `RALPH_MODE` and compaction knobs by hand on every stage,
orchestration and graph plans can declare a plan-wide `tooling` block. The
four named profiles live in `.ralph/tooling-profiles.json` (single source of
truth for names and env overlays):

```yaml
pipeline:
  tooling:
    defaultProfile: ralph-compact
    overrides:
      research: ralph-read-heavy
```

| Profile | Intent |
|---------|--------|
| `raw` | Stock assistant behavior: Ralph MCP off (`RALPH_MODE=no`), no proxy-shell or native-result compaction. Named `raw` rather than `native` because `RALPH_MODE=native` means native hooks on with MCP off. |
| `ralph-read-heavy` | Ralph MCP on with proxy-shell compaction for known-noise command families only. Generic fallback and native-result compaction stay off so unknown large output and source reads stay intact. |
| `ralph-compact` | Ralph MCP on, proxy-shell compaction on, and the generic fallback enabled at a 16384-byte threshold for unknown large shell output. Source reads (read/grep/glob) stay unwindowed. |
| `ralph-aggressive` | Same as `ralph-compact` but the generic threshold drops to 4096 bytes and `RALPH_NATIVE_RESULT_COMPACT=1` also windows native exploration output. The only profile that compacts source output. |

Rules:

- `defaultProfile` is required when `tooling` is present; every override key must
  name a declared stage id; every value must be one of the four names.
- Compilation emits a resolved `toolingProfile` on each stage. Dependency
  dispatch applies the overlay (plus `RALPH_TOOLING_PROFILE` / optional
  `RALPH_TOOLING_PROFILE_DEGRADED`) before the single-stage Sequential bridge /
  `run-plan` runs the node. Internal engine identifiers (`graph`,
  `orchestration`) may still appear in compiled formats and script names.
- A pipeline may declare either run-level `ralphMode` or `tooling`, not both.
  Plans that omit `tooling` keep prior behavior.
- Supervisor-owned nodes (`integrate`, `join`, `gate`, `checkpoint`, `router`,
  `approval`) are not agent stages; do not author tooling overrides for them.
- Public workflow modes are Sequential and Dependency; both engines accept the
  same `tooling` authoring block. Authored workflows use `mode:` rather than
  legacy engine labels.

Env-var detail and the capability matrix: [ENVIRONMENT.md](ENVIRONMENT.md#named-tooling-profiles).
Workflow authoring (including tooling profiles): [WORKFLOWS.md](WORKFLOWS.md).

### Context budget vs tooling profile

A stage's `toolingProfile` (`raw`, `ralph-read-heavy`, `ralph-compact`, `ralph-aggressive`)
and the context budget (`contextBudget` / `RALPH_PLAN_CONTEXT_BUDGET`: `full`, `standard`,
`lean`) are orthogonal. They govern opposite directions of the same run and neither one
composes with or overrides the other:

| Control | Direction | What it governs |
|---------|-----------|-----------------|
| `toolingProfile` | Inbound (tools to the model) | How tool output from reads, searches, and shell commands is bounded, compacted, and stored. |
| `contextBudget` / `RALPH_PLAN_CONTEXT_BUDGET` | Outbound (Ralph to the model) | How much context Ralph attaches to the prompt it sends for each TODO. |

Both stay independently settable per stage: a `raw` tooling profile still honors a `lean`
context budget, and a `ralph-aggressive` profile does not shrink the outbound prompt budget
on its own. See [ENVIRONMENT.md](ENVIRONMENT.md#context-budget-vs-tooling-profile).

## Shell command rewriting

Off by default. When enabled, Ralph rewrites a small allowlist of commands into quieter equivalents before running them:

| Agent ran | Ralph runs instead |
|-----------|--------------------|
| `git status` | `git status --porcelain=v2 --branch` |
| `pytest ...` | `pytest -q --tb=line ...` |
| `tsc ...` | `tsc --pretty false ...` |

Rewrite skips any command that already passes flags, and bails unchanged on anything non-trivial: pipelines, redirection, `&&`/`;`, env assignments, subshells, heredocs, reserved words, or anything `shlex` cannot parse. A rewrite can never broaden policy -- the rewritten command is validated against the allowlist again, after the original was.

| Path | Gate |
|------|------|
| MCP (`ralph_proxy_shell`, all runtimes) | `RALPH_PROXY_SHELL_REWRITE=1` |
| Claude native Bash hook | `RALPH_BASH_REWRITE=1` |
| Audit log (optional) | `RALPH_PROXY_SHELL_REWRITE_LOG` / `RALPH_BASH_REWRITE_LOG` (JSONL of every applied rewrite) |

The rules live in one shared registry (`bundle/.ralph/python/shell_command_registry.py`); the MCP path and the Claude hook both call it. Without `python3`, rewrite quietly does nothing.

## Durable hooks and MCP (`ralph setup`)

Plan runs can inject hooks and MCP for one session and restore afterward (see [Overlay state and cleanup](#overlay-state-and-cleanup)). Use **`ralph setup --hooks`** when you want Ralph's compaction/native-hook behavior in normal IDE sessions outside `ralph run-plan`. **`ralph setup`** writes the same Ralph-owned entries durably so normal IDE sessions also get hooks and MCP without `--ralph-mode`.

```bash
ralph setup --runtime <claude|cursor|codex|opencode> [--runtime-dir <path>] [--hooks] [--mcp] [--all] [--dry-run] [--yes]
```

| Example | Effect |
|---------|--------|
| `ralph setup --runtime claude --runtime-dir ~/.claude --hooks` | Durable Claude compaction hooks in your user runtime config. |
| `ralph setup --runtime cursor --runtime-dir ~/.cursor --hooks` | Durable Cursor compaction hooks in your user runtime config. |
| `ralph setup --runtime claude --hooks --mcp` | Claude hooks under `.claude/`; MCP at project-root `.mcp.json`. |
| `ralph setup --runtime cursor --runtime-dir /path/to/project/.cursor --all` | Cursor hooks and `.cursor/mcp.json` at the given path. |
| `ralph setup --runtime codex --all` | Codex hooks under `.codex/` plus `[mcp_servers.ralph]` in `.codex/config.toml`. |

Default `--runtime-dir` is `$PWD/.$runtime`. At least one of `--hooks`, `--mcp`, or `--all` is required. `--all` is equivalent to `--hooks --mcp`. Use `--dry-run` to preview targets; use `--yes` when the runtime-dir basename does not match the runtime name.

**Claude:** durable MCP is written to **project-root `.mcp.json`**, not inside `.claude/`, matching Claude Code's project-scoped MCP file.

**Codex trusted-project caveat:** project-scoped `.codex/config.toml` and `.codex/hooks.json` load only when Codex trusts the project. If hooks or MCP do not apply after `ralph setup`, add a trusted entry under `~/.codex/config.toml` (for example `[projects."/absolute/path/to/project"]` with `trust_level = "trusted"`) or trust the project in the Codex UI. User-level `~/.codex/config.toml` still loads when the project is untrusted, but project-local Ralph entries are skipped.

**OpenCode MCP-first recommendation:** `ralph setup --hooks` copies the Ralph runtime plugin into `.opencode/plugins/`, but headless hook invocation is unproven. Prefer `ralph setup --mcp` (project-root `opencode.json`) or plan runs with `--ralph-mode hybrid` so Ralph MCP tools are injected and noisy shell output can use MCP compaction. Native exploration output remains direct unless explicitly opted into legacy windowing. The setup command prints a note when installing OpenCode hooks.

Durable MCP details and per-runtime file paths: [MCP.md](MCP.md#durable-mcp-setup-ralph-setup---mcp). Per-run overlay behavior below still applies when you use `--ralph-mode native` or `hybrid` on `ralph run-plan`.

## Native adapters per runtime

Native adapters are merged for one run and restored afterward (see [Overlay state and cleanup](#overlay-state-and-cleanup)). What is actually proven differs by runtime; version-pinned results from 2026-06-04:

| Runtime | Status | Detail |
|---------|--------|--------|
| Claude | Proven | True PostToolUse:Bash output replacement (Claude Code 2.1.162). PreToolUse input rewrite also available. |
| Cursor | Proven (wrapper) | PreToolUse input rewrite and wrapper-based shell compaction (Cursor Agent 2026.06.03). Direct Shell output replacement is not available; MCP compaction covers that. |
| Codex | Proven (wrapper) | Wrapper-based shell compaction via PreToolUse (Codex CLI 0.136.0). PostToolUse output replacement not proven. |
| OpenCode | Unproven (plugin hooks) | Plugin staging works, but headless `opencode run` hook invocation is unproven (1.14.35). In `hybrid`, native OpenCode tools and Ralph MCP tools are both available; MCP-proxy shell compaction is authoritative for noisy command output and the plugin hook path is best-effort until revalidation proves headless mutation reaches the model. |

"Wrapper-based" means the hook rewrites the command to run through a Ralph wrapper that captures, compacts, and stores the output -- same storage and retrieval as everything else.

### Native configuration ownership

The selected runtime launches its normal primary/default agent. Native user,
project, and local/private configuration owns rules, skills, hooks, plugins,
MCP servers, permissions, memory, and runtime-native subagents. Ralph does not
inject workflow stage metadata into native configuration or treat a stage as a
native agent profile. Configurations are discovered from the Ralph project
root, not the state root or agent workspace. Ralph layers only its protected
`ralph` MCP server when the selected mode requires it.

| Runtime | Native config sources (precedence order) | Ralph additions |
|---------|------------------------------------------|-----------------|
| **Claude** | `~/.claude/settings.json`, `.claude/settings.json`, `.claude/settings.local.json`, user/global rules, skills, hooks, plugins, permissions, memory | Ralph layers its protected `ralph` server |
| **Cursor** | `.cursor/` rules, skills, hooks, settings, and existing `.cursor/mcp.json` | Ralph layers its protected `ralph` server |
| **Codex** | `~/.codex/config.toml` and trusted project `.codex/config.toml` | Ralph adds per-run `mcp_servers.ralph.*` overrides |
| **OpenCode** | Global, custom, and project `opencode.json` (JSONC preserved) | Ralph merges its protected `ralph` server into a temporary config |
| **Antigravity** | `.agents/agents.md`, rules, skills, workflows, and existing `.agents/mcp_config.json` | Ralph uses a temporary config only when its protected server is needed |

Workflow stage fields cannot define or override MCP servers. All mutations use
reversible workspace overlays or temporary config files. Byte-exact originals
are restored on success, failure, timeout, and signal cleanup via
runtime-config journals under `.ralph-workspace/runtime-config/<plan-key>/`.

Runtime processes are separately protected by the detached process guardian. Each launch is recorded under `.ralph-workspace/processes/active/` and isolated in an OS session before Ralph waits for it. This lets cleanup find runtime children even after nested shells create sibling process groups or the main runner is killed. See [ENVIRONMENT.md](ENVIRONMENT.md#process-lifecycle-and-orphan-prevention) for limits and operator commands.

### Claude

Ralph reads `<workspace>/.claude/settings.json`. If the Ralph hook entries are already installed (`block-env-reads.sh`, `rewrite-bash-command.sh`, `compact-bash-output.sh`), it leaves the file alone; otherwise it merges the hook groups in and restores the file on exit.

Requirements: run `./install.sh` (or `--claude`) so `.claude/hooks/` exists; `python3` to merge settings; `jq` for compaction telemetry. Do not set `CLAUDE_PLAN_BARE=1` -- bare mode skips hooks entirely.

### Cursor

Ralph merges Ralph-owned entries into `<workspace>/.cursor/hooks.json` per run (never `~/.cursor/hooks.json`) and restores it on exit. The wrapper path is gated by `RALPH_NATIVE_SHELL_WRAPPER=1` (default on when adapters are active). For Ralph MCP tool results, output compaction via the hook layer is also proven (`RALPH_PROXY_SHELL_COMPACT=1` or `RALPH_CURSOR_MCP_HOOK_COMPACT=1`).

### Codex

Ralph appends ephemeral `--config` overrides enabling hooks that point at `bundle/.codex/hooks/`. Requires Codex CLI 0.136.0+ with `exec --config` and `--dangerously-bypass-hook-trust`. The wrapper gate is the same `RALPH_NATIVE_SHELL_WRAPPER=1`.

Per-run hooks match both `Bash` and `command_execution` tool names. Codex `exec --json` surfaces shell calls as `command_execution` in turn telemetry; hook matchers must include that name or native wrapper compaction never fires (zero `hook_compactions` / `native_hook_events` despite injected config).

PostToolUse output mutation is unproven on Codex headless runs (`native_output_mutation_proven=false`). Hook telemetry may therefore show savings under `hook_compaction` while `compaction_saved_bytes` stays zero and `compaction_measured_not_applied_bytes` is non-zero. That split is expected: only MCP `ralph_proxy_shell` compaction counts as applied savings until post-tool mutation is proven.

**Compaction preconditions for Codex plan runs:**

| Path | Requires | Applied savings field |
|------|----------|----------------------|
| Native wrapper (PreToolUse) | `--ralph-mode native` or `hybrid` (not `no` or bare `ralph`) | Counts as measured-not-applied until post-tool mutation is proven |
| MCP proxy shell | `--ralph-mode ralph` or `hybrid`, Ralph MCP injected (`mcp_effective=true`), agent uses `ralph_proxy_shell` | `proxy_shell_compaction_events` / `compaction_saved_bytes` |

Use **`--ralph-mode hybrid`** when you want wrapper hooks plus MCP fallback (`fallback_path_active=true` when `RALPH_PROXY_SHELL_COMPACT=1`). Default `RALPH_MODE=no` disables both native hooks and MCP injection.

### OpenCode

<a id="opencode-hybrid-contract"></a>

Ralph stages `bundle/.opencode/plugins/ralph-runtime-hooks.ts` into the workspace's `.opencode/plugins/` for the run and removes it afterward. Investigation notes: `bundle/.opencode/plugins/SPIKE-output-mutation.md`.

**Hybrid tool access:** `--ralph-mode hybrid` injects Ralph MCP (`mcp.ralph.enabled=true`) and keeps native OpenCode exploration tools (`read`, `grep`, `glob`, `bash`) available. Ralph does not deny or hide native tools as a compaction strategy. Overlay summary records `tool_access_mode=hybrid` and capability `opencode-hybrid-native-and-ralph-mcp`.

**Native exploration compaction:** Native read/grep/glob/search results stay visible as returned. The legacy `RALPH_NATIVE_RESULT_COMPACT=1` path is an explicit opt-in only; it is not enabled by `native` or `hybrid` mode.

**Authoritative compaction path:** `ralph_proxy_shell` with `RALPH_PROXY_SHELL_COMPACT=1` is the authoritative OpenCode path for noisy shell output. Native exploration results are not compacted by default; the staged plugin remains best-effort/conditional and runs record `native_hooks_effective=false` until revalidation proves agent-visible mutation.

**Cache-read reporting:** Provider cache-read token fields (`cache_read_input_tokens`, `cache_read_per_tool_turn`) are model/provider dependent and are **telemetry only**. They inform optimization hints (for example `RALPH_CACHE_READ_PER_TURN_WARN`) but are not Ralph's primary context-control mechanism; bounded tool output and result windowing are.

## Background jobs and Stop hook continuation

When `RALPH_BG_JOBS=1` (opt-in; default `0` / off), a TODO can wait on a long command without agent-authored polling. Env vars: [ENVIRONMENT.md](ENVIRONMENT.md#background-jobs-and-durable-todo-continuations). Prefer strict plan/TODO `verify:` for completion checks; background only when waiting inside the agent turn would cost extra model turns.

### Two-tier model

| Tier | Mechanism | When |
|------|-----------|------|
| **1 — hook continuation (preferred)** | Agent runs `.ralph/ralph-bg.sh '<command>'`, ends the turn without a completion marker. The runtime Stop / stop hook blocks outside the model, waits for the job, injects a bounded result, and the **same session** continues (warm prompt cache). | Runtime has a usable end-of-turn hook **and** process-group isolation is available. |
| **2 — invocation boundary (fallback)** | Runner ends the invocation, waits outside the model, then starts a new invocation for the **same TODO** bound to its exact captured session id. | No usable hook, isolation unavailable, forced `RALPH_BG_TIER=invocation`, or human answers (always cross invocations). |

Tier selection is supervisor-owned (`RALPH_BG_TIER=auto|hook|invocation`), never inferred from model prose. Recorded in telemetry.

### Per-runtime Stop hook contract

Every registration sets an explicit per-hook `timeout` from `RALPH_BG_HOOK_TIMEOUT` (default `5400`). Vendor defaults are too short for long holds.

| Runtime | Event | Holds the turn | Injection field | Loop guard | Vendor default hook timeout |
|---------|-------|----------------|-----------------|------------|------------------------------|
| Claude Code | `Stop`, `SubagentStop` | yes, blocks | `decision:"block"` + `reason` | `stop_hook_active`; Ralph raises `CLAUDE_CODE_STOP_HOOK_BLOCK_CAP` for `RALPH_BG_MAX_PER_TODO` | `timeout` field, **60s** |
| Codex | `Stop` | yes, blocks | `decision:"block"` + `reason` (becomes a new user prompt) | `stop_hook_active` | **600s** |
| Antigravity | `Stop` | yes | `decision:"continue"` + `reason` | not documented; Ralph self-guards | **30s** |
| Cursor | `stop` | hook blocks while it runs but cannot prevent completion | `followup_message` (auto-submitted as next user message) | `loop_count` / `loop_limit` (default 5) | `timeout`, platform default |
| OpenCode | `session.idle` | unproven (event, not a gate) | plugin client SDK | n/a | n/a (async JS plugin) |

Ralph also self-guards: refuse more than `RALPH_BG_MAX_PER_TODO` continuations per logical attempt, and release when the runtime reports its own guard is active. A second Stop fire for an already-consumed job releases the turn.

### Detach and isolation

Background jobs launch through `ralph_native_shell_launch_process_group` (tries `setsid`, then `python3` `os.setsid()`, else non-isolated). Tier 1 **refuses** `isolated=false` launches: the job is terminated and Ralph falls back to tier 2. A non-isolated child dies when the agent turn ends; never silently background one.

### Job lifecycle, cancellation, recovery

State machine: `requested -> launched -> running -> terminal -> consumed` under `$RALPH_SESSION_DIR/bg-jobs/<job-id>/`. Terminal status is exactly one of `passed`, `failed`, `timed_out`, `cancelled`, `interrupted`, `unknown`. Results are consume-once. Plan teardown cancels outstanding jobs for the current identity; restart recovery adopts orphaned jobs whose owner died and writes `bg-jobs/recovery-report.json`.

### Exact-ID safety (tier 2) and cost model

Tier 2 resumes only the exact captured runtime session id for that TODO (manifest under `todo-sessions/`). Never bare `--last` / `--continue` / most-recent. If capture is `degraded`, Ralph starts a fresh invocation that still injects the bounded result once — it does not attach an unsafe wrong session.

Cheapest first:

1. One blocking foreground tool call (already optimal; progress heartbeats are not conversation turns).
2. Background job + tier 1 hook continuation (one extra turn) when work outlives the tool timeout.
3. Tier 2 when no hook/isolation.
4. Agent-authored polling loops are forbidden.

Converting a fine blocking call into a background job makes latency and context worse. Async MCP shell tools (`ralph_proxy_shell_start` / `_wait` / `_status` / `_read` / `_cancel`) stay a **manual** fallback for humans monitoring a job; they are not the automation path for durable TODO continuation (that path is `ralph-bg.sh` + Stop hooks / tier-2 wait). Prefer strict `verify:` for completion gates.

## Overlay state and cleanup

Everything Ralph mutates for a run is journaled so it can be undone. Per plan key:

```text
.ralph-workspace/runtime-config/<plan-key>/
  journals/          # recovery journals (PID, mutated files, backups)
  originals/         # byte backups of mutated workspace files
  summaries/         # per-runtime overlay summaries (one JSON file per runtime)
    <runtime>.json
  summary.json       # aggregate rebuilt from summaries/; compatibility entry point
  hook-telemetry/    # per-run hook event logs
```

Multi-runtime plans (orchestration stages, runtime switches under one `plan_key`) write one summary per runtime under `summaries/<runtime>.json` and rebuild the top-level `summary.json` from those files. The aggregate includes `runtimes_present` and a `runtime_overlays` map with per-runtime scalars so later invocations do not overwrite an earlier runtime's evidence.

Normal exits restore everything via `EXIT` traps. `SIGKILL` and force-quit skip traps, so the journals are the recovery source of truth:

- **Automatic:** every `run-plan.sh` start restores stale journals whose owner PID is dead or older than `RALPH_RUNTIME_OVERLAY_STALE_THRESHOLD_SECONDS` (default 3600).
- **Manual:** `.ralph/cleanup-plan.sh --runtime-config <plan-key>` restores one plan's overlays; add `--all` for every stale journal.

If a crash leaves `ralph` entries in `.cursor/mcp.json` or duplicate hooks in `.claude/settings.json`, run the manual cleanup; `originals/` holds byte-exact backups if you need to restore by hand. Do not delete `runtime-config/` while a plan is running.

### Reading `summary.json`

The most useful fields, written at cleanup and copied into usage records:

| Field | Meaning |
|-------|---------|
| `ralph_mode` | The mode this run used |
| `native_hooks_configured` | Ralph merged or injected hook config this run |
| `native_hooks_effective` | The runtime build is proven to support the adapters (capability flag) |
| `native_hooks_used_on_run` | At least one hook event actually fired this run |
| `native_output_mutation_proven` | Agent-visible output replacement is proven on this build |
| `mcp_effective`, `proxy_shell_compact_effective` | Whether MCP injection and MCP compaction ran |
| `hook_compactions`, `hook_rewrites`, `hook_original_bytes`, `hook_compacted_bytes` | Aggregated savings telemetry |
| `byte_savings_by_channel` | Per-channel optimization evidence (exact attribution on new runs) |
| `channel_activity_counts` | Event counts per optimization channel |
| `native_optimization_proven_channels` | Channels Ralph proved active for this runtime |
| `fallback_channels_active` | Channels that fell back to MCP when native hooks were unproven |
| `runtimes_present`, `runtime_overlays` | Present on aggregate `summary.json` when multiple runtimes contributed |
| `mutated_files`, `generated_files`, `warnings`, `capabilities` | Audit trail |

Per-runtime files under `summaries/<runtime>.json` carry the same channel fields for that runtime only. See [Optimization channel attribution](#optimization-channel-attribution) for channel id meanings.

If `native_hooks_effective` is `false` when you expected hooks: on Claude check for `CLAUDE_PLAN_BARE`; on Cursor check that `python3`/`jq` are installed; on Codex and OpenCode some surfaces are expected to be unproven (see the table above). `native_hooks_reason` says why.

## Stored tool results

Any Ralph MCP response that exceeds policy caps -- not just shell output -- is stored in full and returned as a compact envelope (`truncated: true`, compacted `preview`, `originalBytes`, `resultId`, dual-view refs, plus paging anchors and suggested follow-up calls). Treat the inline `preview` as the first-pass answer; use `ralph_proxy_result_read` with `view=compacted` (default) for normal follow-up and `view=raw` only when you need exact or full inspection. Storage layout:

```text
.ralph-workspace/tool-results/<plan-key>/
  index.jsonl          # one line of metadata per stored result
  results/<resultId>.txt          # raw full output
  results/<resultId>.compact.txt  # intelligent compacted view (same result id)
```

Stored results are local run artifacts. They can contain workspace content (file reads, grep matches, shell output), are not encrypted, and must not be committed. See [SECURITY.md](SECURITY.md).

Agents are prompted to treat the inline `preview` as the compacted first-pass answer and choose the follow-up view by information need:

- Use `ralph_proxy_result_read` with `view=compacted` first for build/test/lint output, package-manager installs, CI logs, server logs, watcher output, and long log files. The compacted view is intended to preserve recent failures, summaries, and useful tails.
- Use `ralph_proxy_result_search` before raw reads when the task needs specific errors, stack traces, filenames, warnings, test names, or one known section.
- Use byte or line ranges with `view=compacted` for paging through logs and command output.
- Use `view=raw` for source files, generated code, structured data, exact diffs, or when compacted/search output does not contain the exact content needed.

Retention runs automatically after each write:

| Variable | Default | Effect |
|----------|---------|--------|
| `RALPH_MCP_PROXY_RESULT_STORE_MAX_ENTRIES` | `100` | Max stored results per plan key |
| `RALPH_MCP_PROXY_RESULT_STORE_MAX_BYTES` | `52428800` (50 MiB) | Max total bytes per plan key |
| `RALPH_MCP_PROXY_RESULT_STORE_MAX_AGE_DAYS` | `7` | Drop older results (`0` disables) |

`.ralph/cleanup-plan.sh <plan-key>` removes a namespace's tool results, logs, sessions, and artifacts in one go.

## Policy and caps

The MCP server loads policy at startup from `RALPH_MCP_PROXY_POLICY_INLINE` (JSON string), else `RALPH_MCP_PROXY_POLICY_FILE`, else built-in defaults. `RALPH_MCP_PROXY_POLICY` selects a named profile from the policy file; orchestration stages can set `mcpProxyPolicy` per stage.

Policy caps apply only to Ralph MCP responses (`tools/call` and `resources/read`). They never truncate runtime-native tools like Claude `Read` or `Bash`.

Defaults when no policy is supplied:

| Setting | Default |
|---------|---------|
| `resultByteCap` | `16384` |
| `proxyOwnedTools.maxReadBytes` / `maxReadLines` | `32768` / `250` |
| `proxyOwnedTools.maxGrepMatches` / `maxGlobResults` | `50` / `100` |
| `proxyOwnedTools.maxShellOutputBytes` | `8192` |
| `proxyOwnedTools.shellTimeoutSeconds` | `600` |
| `proxyOwnedTools.allowAllCommands` / `allowShellOperators` | `true` / `true` |

The default is deliberately permissive: the proxy's promise is **output bounding, not sandboxing**, so in a trusted workspace `ralph_proxy_shell` runs arbitrary commands and pipelines while responses stay capped and stored. The kill switch still fires on real tripwires (tool denylists, denied argument patterns, path traversal). To tighten things, set `allowAllCommands: false` with an explicit `shellAllowlist`, or start from the `readonly` / `minimal` / `trusted-local` profiles in [`bundle/.ralph/mcp-proxy-policy.example.json`](../bundle/.ralph/mcp-proxy-policy.example.json).

Policy field names are camelCase; keys inside `toolResultByteCaps` are exact MCP identifiers (`ralph_proxy_read`, `resources/read`, ...).

### Three roots

Proxy path policy distinguishes the **project root** (`--workspace`; where `.ralph/` lives), the **state root** (`--workspace-root`; hosts `.ralph-workspace/`), and the **agent workspace** (`--agent-workspace`; the tree the model may write to). Full table and examples: [AGENTS.md](../AGENTS.md#three-root-model). `$HOME/.cursor/plans` and `$HOME/.claude/plans` are always readable so agents can reference original plan files; writes there are rejected.

## Telemetry

Compaction and hook activity land in `.ralph-workspace/logs/<plan-key>/discover-report.json` (per-event savings, families, skip reasons) and in the per-run `summary.json` (or `summaries/<runtime>.json`) and `invocation-usage.json`. All local files, nothing uploaded.

When reading the numbers, keep three layers apart:

| Layer | Source | What it measures |
|-------|--------|------------------|
| **Optimization evidence** | `byte_savings_by_channel`, benchmark `per_channel` | Bytes/tokens Ralph actually trimmed or windowed, with exact channel ids on new runs |
| **Coarse path totals** | `byte_savings_by_path`, benchmark `per_path` | Legacy rollups (`hook_compaction`, `proxy_shell_compaction`, `result_windowing`) kept for compatibility |
| **Tool-adoption diagnostics** | `ralph_proxy_calls`, `native_read_like_calls`, discover `sequence_patterns`, benchmark **Improvement opportunities** | Whether agents used proxy vs native tools and which usage patterns appeared; not proof of savings |

`hook_*` fields come from overlay journals. `native_hooks_effective` is a build capability flag, not proof anything fired this run (that is `native_hooks_used_on_run`).

Inspect savings after a run:

```bash
cat ".ralph-workspace/logs/<plan-key>/discover-report.json" | jq '.compaction_events[] | select(.savings_percent > 50)'
```

### Optimization channel attribution

New plan runs record **exact** optimization channels in overlay summaries and benchmark reports. Each channel id names one compaction or windowing path:

| Channel id | Meaning |
|------------|---------|
| `native_shell_hook` | Native shell hook compacted command output (for example Cursor/Codex Bash hooks) |
| `proxy_shell` | `ralph_proxy_shell` compacted allowlisted command output |
| `native_result_hook` | Native exploration hook windowed read/grep/glob/bash output |
| `native_result_mcp_fallback` | MCP fallback windowing when native result hooks are unproven |
| `proxy_read_windowing` | `ralph_proxy_read` bounded preview with stored full output |
| `proxy_search_windowing` | `ralph_proxy_grep` / search windowing with stored full output |
| `stored_result_readback` | Follow-up `ralph_proxy_result_*` reads after an envelope preview |

Channel buckets carry `attribution: exact` on new runs. **Historical runs** recorded before per-channel telemetry may appear with `attribution: legacy`; benchmark Markdown groups those under **Legacy / unknown attribution**. Treat legacy rows as approximate totals, not authoritative channel splits. Re-run the plan (or wait for new invocations) to get exact attribution.

The benchmark report's **Optimization by channel** section is the authoritative breakdown of where tool-output savings came from. **Improvement opportunities** (missed compaction, native-read-after-grep patterns, heavy native read share) are adoption hints only; they do not replace channel evidence.

`ralph benchmark` aggregates `plan-usage-summary.json` files into JSON/Markdown; regenerate [BENCHMARKS.md](BENCHMARKS.md) with `ralph benchmark --write-doc` (generated output; do not hand-edit).

## Post-TODO verification

Declared verification commands (plan frontmatter `verify:`, a TODO `Verify:` line, or `RALPH_VERIFY_AFTER_TODO`) run out-of-process after the model marks a TODO complete, keeping big test output out of the next prompt. Failures reopen the TODO with a compact summary and an artifact path, and the runner already stores the full transcript under `.ralph-workspace/artifacts/<PLAN_KEY>/verification/`. On by default when declared; `RALPH_POST_VERIFY=0` opts out. Variables: [ENVIRONMENT.md](ENVIRONMENT.md#post-todo-verification).

Runner-first policy: long-running verification commands belong in the plan/TODO metadata so the runner executes them out-of-process and keeps their large output out of the next prompt. Resist rerunning those commands through agent-side async loops; `ralph_proxy_shell_start`, `_wait`, and `_status` are a manual fallback surface for when a human is directly monitoring a job—they are not the primary verification or automation path.

- Prefer plan/TODO verification for every task-completion command so the runner handles the heavy work out-of-process and the next prompt stays focused on remaining TODOs.
- When rerunning a declared verification command manually, start it with `ralph_proxy_shell_start` and block on completion with `ralph_proxy_shell_wait` (optionally passing `waitSeconds`). The async shell tools are a manual fallback—`shell_wait` is the blocking call only when a human is directly monitoring a job.
- Treat `ralph_proxy_shell_status` as an occasional manual spot check and never use it as a polling loop. Inspect output with `ralph_proxy_shell_read` and cancel via `ralph_proxy_shell_cancel` if you must intervene.

## Knowledge tools

The experimental knowledge-graph tools (`ralph_knowledge_*`) are hidden unless the master gate `RALPH_KNOWLEDGE_FEATURE=on` is set, in addition to `--knowledge-tools on`. With the gate off (the default), `--knowledge-tools on` is ignored. Per-capability variables: [ENVIRONMENT.md](ENVIRONMENT.md#knowledge-graph-experimental-disabled-by-default).

## Troubleshooting

**MCP preflight failed / Claude: "Failed to connect: ralph".** Ralph runs an MCP handshake before each `ralph`-mode invocation and exits before the CLI starts if it fails. Check that `jq` is installed, the workspace path is valid, and `.ralph/mcp-server.sh` exists. Manual check: `RALPH_MCP_WORKSPACE="$PWD" bash .ralph/mcp-server.sh`. The preflight also rejects a `tools/list` response with a present-but-null `nextCursor`, because Claude Code 2.1.x silently drops every tool from such a server while still reporting it connected. For a true end-to-end check on Claude, `RALPH_MCP_CLI_PREFLIGHT=1` spawns the real CLI and aborts if it never calls a proxy tool.

**Claude says it cannot Edit/Write files.** Claude's `Edit`/`Write` require a prior native `Read` of the file; `ralph_proxy_read` does not satisfy that gate. Ralph keeps native `Read` precisely so edits work. If edits fail, confirm you have not set `RALPH_CLAUDE_RALPH_STRICT_PROXY_STRIP_READ=1` (read-only plans only).

## Ralph optimizations (Ralph/hybrid)

Tier 1 through Tier 3 Ralph features (stable prompt prefix, continuation summary, compact MCP catalog, contextual search, result reduce, structured output, and related gates) are **enabled in `ralph`/`hybrid` mode** unless their specific env var is `0`. They stay **off in `no`/`native`** unless explicitly set to `1`. See [ENVIRONMENT.md](ENVIRONMENT.md#feature-gates-tier-1-through-tier-3).

Offline regression: `tests/python/test_cookbook_offline_e2e.py`, retrieval eval (`bundle/.ralph/python/retrieval_eval.py`), and tool eval (`bundle/.ralph/python/tool_eval.py`).

**Claude: "incompatible with bare mode".** Unset `CLAUDE_PLAN_BARE` or use `--ralph-mode native`.

**Codex: unknown config field or cancelled MCP tool calls.** Older Codex builds reject `mcp_servers.ralph.type` or the tools-approval field; Ralph probes and omits them, or force it with `CODEX_PLAN_MCP_OMIT_TYPE=1` / `CODEX_PLAN_MCP_OMIT_TOOLS_APPROVAL_MODE=1`. Upgrading Codex is the simpler fix.

**Cursor: "existing Cursor MCP config is invalid JSON".** Fix `<workspace>/.cursor/mcp.json` by hand and re-run; Ralph never modifies an invalid config.

**Ralph mode is on but logs show only native Read calls.** Proxy tools only save tokens when agents call them. Plan logs include a per-invocation `Ralph mode breakdown: proxy=... native_read=...`. To enforce proxy usage, see strict proxy mode above.

**Stale files under `.ralph-workspace/runtime-config/`.** See [Overlay state and cleanup](#overlay-state-and-cleanup).

**Policy denied a tool call.** The JSON-RPC error names the rule. Adjust `RALPH_MCP_PROXY_POLICY*` or use `--ralph-mode native`.

## Related documentation

- [MCP.md](MCP.md) -- host configuration, resources, prompts
- [ENVIRONMENT.md](ENVIRONMENT.md) -- every environment variable in one place
- [SECURITY.md](SECURITY.md) -- trust model, what Ralph touches on disk
- [`.ralph/run-plan.sh`](../bundle/.ralph/run-plan.sh) -- plan runner and `--ralph-mode` flag
- [`.ralph/mcp-server.sh`](../bundle/.ralph/mcp-server.sh) -- unified MCP server
