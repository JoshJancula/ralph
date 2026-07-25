# Installing Ralph

There are two ways to install Ralph:

1. **Global install (recommended).** Install Ralph once on your machine. You get a `ralph` command that works in any project.
2. **In-repo install.** Copy Ralph's files into one project so they are committed and reviewed with the rest of that repo.

Start with the global install unless your team needs Ralph's files checked into the repository.

Ralph plan execution requires Python 3. The process guardian uses only the Python standard library; no Python packages are installed.

## Global install (recommended)

```bash
git clone https://github.com/JoshJancula/ralph.git /tmp/ralph
/tmp/ralph/install.sh --global
rm -rf /tmp/ralph
```

This does four things:

- Copies Ralph's scripts, docs, and dashboard to `~/.ralph/` (override with `RALPH_HOME`)
- Puts a `ralph` command at `~/.local/bin/ralph`
- Creates `~/.config/ralph/` for settings (workspace registry, saved models) and `~/.local/state/ralph/` for session state
- Creates `~/.cursor/`, `~/.claude/`, `~/.codex/`, `~/.opencode/`, and `~/.agents/` if they do not exist yet, so you can keep shared agents, rules, and skills there. Existing directories are left alone (pass `--force-global-runtime` to overwrite them with Ralph's defaults)

Global install never writes files into the project you ran it from. `--global` and a project directory argument cannot be combined.

### Put `ralph` on your PATH

The `ralph` command lives at `~/.local/bin/ralph`. If your shell cannot find it, add that directory to `PATH`:

```bash
# bash
printf '\nexport PATH="$HOME/.local/bin:$PATH"\n' >> ~/.bashrc && source ~/.bashrc

# zsh
printf '\nexport PATH="$HOME/.local/bin:$PATH"\n' >> ~/.zshrc && source ~/.zshrc
```

If the shell still cannot find `ralph` afterward, run `hash -r`.

### Using the `ralph` command

From any project directory:

```bash
ralph run-plan --runtime cursor --plan PLAN.md --workspace .   # run a plan
ralph run --plan path/to/pipeline.plan.md                      # run a multi-stage pipeline
ralph models add claude claude-sonnet-4-6                      # save a model id
ralph dashboard                                                # start the dashboard UI
ralph workspaces list                                          # list registered projects
ralph config killswitch init                                   # add per-project killswitch config
ralph config killswitch                                        # show active killswitch source and paths
ralph process list --workspace .                               # inspect managed runtime/stage processes
ralph process stop --all --workspace .                         # stop active Ralph runs safely
ralph setup --runtime claude --runtime-dir ~/.claude --hooks   # durable Claude compaction hooks in your user runtime
ralph setup --runtime claude --hooks --mcp                     # project-local hooks + MCP for a runtime
ralph install ...                                              # re-run the installer
```

Each command dispatches to the matching script under `$RALPH_HOME` (for example, `ralph run-plan` runs `$RALPH_HOME/bundle/.ralph/run-plan.sh`).

### Runtime setup (`ralph setup`)

Use `ralph setup` to install durable Ralph compaction hooks and MCP configuration into a runtime directory so they are available in normal IDE sessions, not only during `ralph run-plan`. Use `--hooks` when you want Ralph's compaction behavior outside Ralph runs. The installer copies the assets; `ralph setup` is the durable, repeatable activation command.

```bash
ralph setup --runtime <claude|cursor|codex|opencode|antigravity> [--runtime-dir <path>] [--hooks] [--mcp] [--all] [--dry-run] [--yes]
```

| Flag | Meaning |
|------|---------|
| `--runtime` | Required. One of `claude`, `cursor`, `codex`, `opencode`, `antigravity`. |
| `--runtime-dir` | Runtime directory to configure. Default: `$PWD/.$runtime` (for example `$PWD/.cursor`). Use `~/.claude`, `~/.cursor`, `~/.codex`, `~/.opencode`, or `~/.agents` for user-home installs. |
| `--hooks` | Copy durable compaction/native hook scripts and merge Ralph hook config into the runtime directory. |
| `--mcp` | Merge a durable Ralph MCP server entry (`RALPH_MODE=hybrid`). |
| `--all` | Both `--hooks` and `--mcp`. |
| `--dry-run` | Print targets without writing. |
| `--yes` | Skip prompts, including when `--runtime-dir` basename does not match the runtime (for example `.cursor` with `--runtime cursor`). |

At least one of `--hooks`, `--mcp`, or `--all` is required. Project root is inferred as the parent of `--runtime-dir`.

Examples:

```bash
# Claude: durable hooks in your user runtime
ralph setup --runtime claude --runtime-dir ~/.claude --hooks

# Cursor: durable hooks in your user runtime
ralph setup --runtime cursor --runtime-dir ~/.cursor --hooks

# Claude: project-local hooks under .claude/ and MCP at project-root .mcp.json (not inside .claude/)
ralph setup --runtime claude --hooks --mcp

# Cursor: explicit project runtime directory; --all installs hooks and MCP
ralph setup --runtime cursor --runtime-dir /path/to/project/.cursor --all

# Codex: user-home durable hooks
ralph setup --runtime codex --runtime-dir ~/.codex --hooks

# Codex: project-local hooks + MCP in .codex/config.toml (see trusted-project caveat in docs/MCP.md)
ralph setup --runtime codex --runtime-dir /path/to/project/.codex --all

# Preview only
ralph setup --runtime opencode --all --dry-run

# Antigravity: hooks + MCP in .agents/mcp_config.json
ralph setup --runtime antigravity --all
```

MCP and hook file paths differ by runtime; see [MCP.md](MCP.md#durable-mcp-setup-ralph-setup---mcp) and [TOOLING.md](TOOLING.md#durable-hooks-and-mcp-ralph-setup).

### Saved models

Ralph does not ship default model lists for Claude or Codex. Add the models you use:

```bash
ralph models add claude claude-sonnet-4-6
ralph models list codex
ralph models remove claude claude-sonnet-4-6
```

Antigravity does not use the saved-model store. Ralph lists available models via `agy models` and invokes `agy --model "<exact model string from agy models>"`, preserving the exact display string returned by `agy models`. Set `ANTIGRAVITY_PLAN_MODEL` for non-interactive runs.

Saved models live in `~/.config/ralph/models.json` (override the directory with `RALPH_CONFIG_HOME`). The first saved model per runtime is the default when a plan run has no `--model` flag, env override, or agent-config model. You can also set `CLAUDE_PLAN_MODEL`, `CODEX_PLAN_MODEL`, or `ANTIGRAVITY_PLAN_MODEL` directly. Full resolution order: [ENVIRONMENT.md](ENVIRONMENT.md#models).

### Where things live

| Purpose | Default path | Override |
|---------|--------------|----------|
| Install root (scripts, docs, dashboard) | `~/.ralph/` | `RALPH_HOME` |
| The `ralph` command | `~/.local/bin/ralph` | -- |
| Settings (workspace registry, models) | `~/.config/ralph/` | `XDG_CONFIG_HOME`, `RALPH_CONFIG_HOME` |
| Global session state | `~/.local/state/ralph/` | `XDG_STATE_HOME` |
| Shared runtime configs (optional) | `~/.cursor/`, `~/.claude/`, `~/.codex/`, `~/.opencode/`, `~/.agents/` | `RALPH_GLOBAL_RUNTIME_HOME` |

Plan logs and artifacts always stay in each project's own `.ralph-workspace/` directory unless you move them with `--workspace-root` or `RALPH_PLAN_WORKSPACE_ROOT`. When a project has no local `.ralph/`, session state defaults to `~/.local/state/ralph/sessions/` instead (an explicit `RALPH_PLAN_SESSION_HOME` always wins).

### How runtime config is resolved

For each runtime (Cursor, Claude, Codex, OpenCode, Antigravity), Ralph looks for agents, rules, and skills in this order. The first tier that exists wins:

1. **Project-local:** `<workspace>/.claude/` (and so on) -- always takes precedence
2. **User-level:** `~/.claude/` (or under `RALPH_GLOBAL_RUNTIME_HOME`)
3. **Bundled defaults:** `$RALPH_HOME/bundle/.claude/`

Set `RALPH_DISABLE_GLOBAL_FALLBACK=1` to use only the project-local tier (useful in strict or sandboxed environments). The global `ralph` command always runs framework scripts from `$RALPH_HOME/bundle/.ralph/`, even if the workspace still has a leftover `.ralph/` directory from an older local install.

Codex note: when a run uses a user-level runtime root, add only that resolved directory to the Codex sandbox, not all of `$HOME`.

### Workspace registry

Global mode tracks the projects you run plans in (`~/.config/ralph/workspaces.json`, capped at the 100 most recent). The registry powers `ralph workspaces list` and lets the global dashboard aggregate metrics across projects. A registry write failure warns but never fails a plan run.

### Migrating a project from local to global

If a project already has its own `.ralph/` and runtime directories, you can switch it to the global install:

```bash
bash "$RALPH_HOME/bundle/.ralph/migrate-to-global.sh" --dry-run /path/to/project   # preview
bash "$RALPH_HOME/bundle/.ralph/migrate-to-global.sh" /path/to/project             # confirm each removal
bash "$RALPH_HOME/bundle/.ralph/migrate-to-global.sh" --yes /path/to/project       # no prompts
```

The script registers the project in the workspace registry and, with confirmation (or `--yes`), removes the project-local Ralph directories. The project keeps working through the global install, and any runtime configs you leave in place still take precedence over global defaults.

## In-repo install (alternative)

Use this when Ralph should live inside the repository: committed, reviewable `.ralph/` and runtime directories that every teammate gets with `git clone`. Run `install.sh` from a Ralph checkout against your project root.

### One-time copy (simplest)

```bash
git clone https://github.com/JoshJancula/ralph.git /tmp/ralph
/tmp/ralph/install.sh /path/to/your-repo
rm -rf /tmp/ralph
```

To upgrade later, clone again and re-run `install.sh`.

### Submodule (easy updates)

```bash
cd /path/to/your-repo

git submodule add https://github.com/JoshJancula/ralph.git vendor/ralph
git submodule update --init

./vendor/ralph/install.sh

git add .ralph \
  .cursor/ralph .cursor/rules .cursor/skills .cursor/agents \
  .claude/ralph .claude/rules .claude/skills .claude/agents \
  .codex/ralph .codex/rules .codex/skills .codex/agents \
  .opencode/ralph .opencode/rules .opencode/skills .opencode/agents \
  .agents/agents.md .agents/ralph .agents/rules .agents/skills .agents/agents
git commit -m "Add Ralph agent workflows"
```

Teammates: after `git clone`, run `git submodule update --init` and, if the Ralph bundle changed, `./vendor/ralph/install.sh` again.

### Subtree

```bash
git subtree add --prefix vendor/ralph https://github.com/JoshJancula/ralph.git main --squash
./vendor/ralph/install.sh
git add -A
git commit -m "Add Ralph at repo root"
```

### About the vendor directory

The Ralph package keeps its installable files under `vendor/ralph/bundle/`. Always run `vendor/ralph/install.sh` (the script at the root of the vendored tree); the installer copies shared scripts into your project root as `.ralph/`.

After a successful install, the installer removes `vendor/ralph` when it is not its own Git checkout (the typical subtree case), so you commit only `.ralph/` and the runtime directories. If `vendor/ralph/.git` exists (submodule or full clone), the vendor tree is kept so you can update it with Git. Override with `RALPH_INSTALL_REMOVE_VENDOR=1` (always remove) or `RALPH_INSTALL_KEEP_VENDOR=1` (always keep).

## Installer options

These flags work in both modes: `install.sh --global` updates `$RALPH_HOME`, and `install.sh /path/to/project` copies into a project. With no flags you get the full stack: shared `.ralph/`, all five runtimes, and the dashboard.

```text
./install.sh                      # full install (default, same as --all)
./install.sh --global             # install to $RALPH_HOME instead of a project
./install.sh --cursor             # Cursor pieces only (rules, skills, agents)
./install.sh --codex --claude     # Codex and Claude only
./install.sh --opencode           # OpenCode only
./install.sh --antigravity        # Antigravity only
./install.sh --shared             # only .ralph/ (runner, orchestrator, templates, docs)
./install.sh --no-dashboard       # skip the dashboard copy
./install.sh -n /path/to/repo     # dry run: print actions without copying
```

Combine `--cursor`, `--claude`, `--codex`, `--opencode`, `--antigravity`, and `--shared` to trim what is copied.

**Partial installs:** a runtime flag alone (for example `--cursor`) does not install the shared `.ralph/` scripts. Add `--shared` when you need the runner, orchestrator, and templates -- the Claude and Codex runners also expect `.ralph/agent-config-tool.sh` when you use `--agent`. A default install still copies the dashboard into `.ralph/ralph-dashboard/`, so a `.ralph/` directory may exist that only contains the dashboard until you add `--shared`.

## Uninstall

| Command | What it removes |
|---------|-----------------|
| `--uninstall` | Files that ship in the Ralph package (your own files next to them stay). Combine with stack flags, for example `--uninstall --shared`. |
| `--cleanup` | The vendored Ralph directory under the project, when one still exists. |
| `--purge` | Both: full uninstall for all stacks plus vendor removal. |

```bash
./vendor/ralph/install.sh --uninstall -n         # dry run: show what would be removed
./vendor/ralph/install.sh --uninstall --silent   # no prompts (CI)
./vendor/ralph/install.sh --purge --silent       # full strip including vendor tree
```

Git bookkeeping for submodules (`git submodule deinit`, `git rm`) or subtree history is still on you; the installer only removes files on disk.

To remove a **global** install, delete `$RALPH_HOME` and the `~/.local/bin/ralph` shim. Use `migrate-to-global.sh` (above) when you only want to drop a project's local copies while keeping the project registered.

**Stale directories from old installs:** projects installed long ago may have `.cursor/ralph/`, `.claude/ralph/`, `.codex/ralph/`, `.opencode/ralph/`, or `.agents/ralph/` directories. Those scripts moved to `.ralph/` and the installer no longer touches the old locations -- the uninstaller warns when it sees them. Remove them by hand:

```bash
rm -rf .cursor/ralph .claude/ralph .codex/ralph .opencode/ralph .agents/ralph
```

## Global vs in-repo: which should I pick?

| Topic | Global install | In-repo install |
|-------|----------------|-----------------|
| Setup cost | Install once, run `ralph` anywhere | Copy files into every repo |
| Upgrades | One upgrade covers all projects | Upgrade each repo separately |
| Team consistency | Each user manages their own Ralph version | Files are committed and reviewed together |
| Customization | Project-local or user-level overrides | Edit the committed files directly |
| Sandboxing | Some files live under `$HOME` | Everything stays inside the workspace |

Short version: use global for personal workflows and lots of small repos; use in-repo when a team wants Ralph's exact behavior committed and reviewed.

## Dashboard (optional UI)

```bash
# Global install, from any directory
ralph dashboard

# In-repo install, from the project root
cd .ralph/ralph-dashboard && npm install && npm run build && PORT=8124 npm start
```

## See also

- [Documentation index](README.md)
- [Agent workflow](AGENT-WORKFLOW.md) -- how the plan loop works
- [Tooling](TOOLING.md) -- optional Ralph mode, compaction, native adapters
- [MCP](MCP.md) -- optional MCP server configuration after install
