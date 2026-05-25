# Global install mode

This document is the design spec for Ralph's global install path. Local project installs remain the default and keep their current behavior. Global install is opt-in via `./install.sh --global`.

## Goals

Global install lets a user install Ralph once on a workstation, put a `ralph` command on `PATH`, and run Ralph in many project repositories without copying `.ralph/`, `.cursor/`, `.claude/`, `.codex/`, or `.opencode/` into each project. Project-local Ralph files still win whenever they exist, so existing repositories do not change behavior.

## Directory layout

Default paths:

| Purpose | Default | Override | Notes |
|---------|---------|----------|-------|
| Install root | `${RALPH_HOME:-$HOME/.ralph}/` | `RALPH_HOME` | Holds the Ralph checkout/copy used by the shim. |
| Config root | `${XDG_CONFIG_HOME:-$HOME/.config}/ralph/` | `XDG_CONFIG_HOME`, specific env vars | Holds registry and user defaults. |
| State root | `${XDG_STATE_HOME:-$HOME/.local/state}/ralph/` | `XDG_STATE_HOME`, specific env vars | Holds global-mode runtime state such as sessions. |
| Shim binary | `~/.local/bin/ralph` | future installer flag if needed | Dispatches to scripts under `RALPH_HOME`. |
| User runtime configs | `${RALPH_GLOBAL_RUNTIME_HOME:-$HOME}/.<runtime>/` | `RALPH_GLOBAL_RUNTIME_HOME` | Optional shared runtime agents/rules/skills. |

Directory diagram:

```text
$HOME/
  .ralph/                         # ${RALPH_HOME:-$HOME/.ralph}
    install.sh
    docs/                          # framework Markdown (GLOBAL-INSTALL, INSTALL, etc.); Ralph dashboard "Ralph docs"
    bundle/
      .ralph/
        run-plan.sh
        orchestrator.sh
        bash-lib/
      .cursor/
      .claude/
      .codex/
      .opencode/
    ralph-dashboard/
  .local/
    bin/
      ralph                       # shim
    state/
      ralph/                      # ${XDG_STATE_HOME:-$HOME/.local/state}/ralph
        sessions/
  .config/
    ralph/                        # ${XDG_CONFIG_HOME:-$HOME/.config}/ralph
      workspaces.json
      defaults.env
  .cursor/                        # optional user-level runtime config
  .claude/
  .codex/
  .opencode/
```

## Installer behavior

`./install.sh --global` installs into `${RALPH_HOME:-$HOME/.ralph}/` and must not write Ralph files into the current project. It copies the bundle and dashboard to the install root, copies this repository's `docs/` tree to `$RALPH_HOME/docs/` when the installer is run from a checkout that includes it, creates or updates the `ralph` shim at `~/.local/bin/ralph`, and initializes `${XDG_CONFIG_HOME:-$HOME/.config}/ralph/` and `${XDG_STATE_HOME:-$HOME/.local/state}/ralph/` as needed.

Global runtime config directories (`$HOME/.claude`, `$HOME/.cursor`, `$HOME/.codex`, `$HOME/.opencode`) are created only when missing. `--force-global-runtime` may overwrite/update those user runtime configs from the bundled defaults. Without that flag, existing user runtime configs are preserved.

`--global` and a positional `TARGET_DIR` are mutually exclusive. Dry-run output must enumerate each destination path, including `~/.local/bin/ralph`.

## Shim commands

The shim is a small executable shell script at `~/.local/bin/ralph`. It resolves `${RALPH_HOME:-$HOME/.ralph}` at runtime and dispatches:

| Command | Dispatch |
|---------|----------|
| `ralph run-plan ...` | `bash "$RALPH_HOME/bundle/.ralph/run-plan.sh" ...` |
| `ralph orchestrate ...` | `bash "$RALPH_HOME/bundle/.ralph/orchestrator.sh" ...` |
| `ralph dashboard ...` | start `$RALPH_HOME/ralph-dashboard` in global dashboard mode |
| `ralph install ...` | `bash "$RALPH_HOME/install.sh" ...` |
| `ralph workspaces ...` | workspace registry CLI |

The shim must be idempotent: reinstalling global Ralph replaces the shim atomically or leaves an equivalent shim in place.

## PATH setup

The installer should warn when `~/.local/bin` is not on `PATH`.

For bash:

```bash
printf '\nexport PATH="$HOME/.local/bin:$PATH"\n' >> ~/.bashrc
source ~/.bashrc
```

For zsh:

```bash
printf '\nexport PATH="$HOME/.local/bin:$PATH"\n' >> ~/.zshrc
source ~/.zshrc
```

After changing `PATH` in an existing shell, run `hash -r` if the shell still cannot find `ralph`.

## Runtime config resolution

Runtime config roots are resolved per runtime (`cursor`, `claude`, `codex`, `opencode`) and per workspace. Project-local config always takes precedence.

Precedence table:

| Rank | Location | Example for Claude | Used when |
|------|----------|--------------------|-----------|
| 1 | Project-local runtime root | `<workspace>/.claude/` | The project has local Ralph or custom Claude config. |
| 2 | User runtime root | `${RALPH_GLOBAL_RUNTIME_HOME:-$HOME}/.claude/` | No project-local runtime root exists and global fallback is enabled. |
| 3 | Bundled defaults | `${RALPH_HOME:-$HOME/.ralph}/bundle/.claude/` | Neither project nor user runtime root exists. |

Set `RALPH_DISABLE_GLOBAL_FALLBACK=1` to use only the project-local tier. This preserves pre-global behavior for strict or sandboxed environments.

Codex runs that use a user-level runtime root must add only that resolved runtime directory to the Codex sandbox. Do not add all of `$HOME`.

## Workspace registry

Global mode uses `${XDG_CONFIG_HOME:-$HOME/.config}/ralph/workspaces.json` to track recently used workspaces. Each run should update an entry like:

```json
{
  "path": "/path/to/project",
  "lastSeen": "2026-04-25T19:00:00Z",
  "planKey": "PLAN",
  "runtime": "codex"
}
```

Entries are deduplicated by absolute workspace path, newest wins, and the registry is capped to the 100 most recent workspaces. Registry write failures must warn but must not fail a plan run.

## Session and state storage

Local installs keep the current default session location under `<workspace>/.ralph-workspace/sessions/`.

When running from a global install and the workspace has no project-local `.ralph/`, default session state moves to `${XDG_STATE_HOME:-$HOME/.local/state}/ralph/sessions/`. An explicit `RALPH_PLAN_SESSION_HOME` always wins.

Logs and artifacts for a project still live under that project's `.ralph-workspace/` unless the user passes `--workspace-root` or sets `RALPH_PLAN_WORKSPACE_ROOT`.

## Dashboard behavior

Local dashboard mode reads one workspace's `.ralph-workspace/`, as it does today.

Global dashboard mode starts from `$RALPH_HOME/ralph-dashboard` with `RALPH_DASHBOARD_GLOBAL=1`. It reads the workspace registry and aggregates metrics across registered workspaces. The API response shapes should remain compatible with local mode; the UI can add workspace selection on top.

## Migrating an existing project to global install

If you have projects with project-local Ralph installations (`.ralph/` and `.<runtime>/` directories), you can migrate them to use the global install while keeping those projects registered for dashboard metrics.

Use the migration helper script:

```bash
# Register one or more projects; shows what would be removed (dry-run)
bash $RALPH_HOME/bundle/.ralph/migrate-to-global.sh --dry-run <project1> <project2> ...

# Register and interactively confirm removal of local files per project
bash $RALPH_HOME/bundle/.ralph/migrate-to-global.sh <project1> <project2> ...

# Register and auto-remove without prompting
bash $RALPH_HOME/bundle/.ralph/migrate-to-global.sh --yes <project1> <project2> ...
```

The script:
1. Validates each project exists and contains local Ralph files
2. Adds the project to the workspace registry
3. Optionally removes `.ralph/` and `.<runtime>/` directories with confirmation (or `--yes` to skip prompts)
4. Prints a summary of actions taken

After migration, the projects continue working with the global install and appear in `ralph workspaces list` and the global dashboard. Project-local runtime configs (if any remain) still take precedence over global defaults.

## Tradeoffs versus local install

| Topic | Local install | Global install |
|-------|---------------|----------------|
| Reproducibility | Ralph files are committed with the project. | Depends on each user's global Ralph version unless pinned operationally. |
| Setup cost per repo | Higher: copy `.ralph/` and runtime dirs into each repo. | Lower: install once and run `ralph ...` anywhere. |
| Team consistency | Strong when files are committed and reviewed. | Weaker unless the team standardizes `RALPH_HOME` contents. |
| Project customization | Straightforward: edit project-local files. | Use project-local overrides or user runtime config. |
| Sandbox clarity | All Ralph files are inside the workspace. | Some files may live under `$HOME`; runtimes need explicit access where required. |
| Upgrades | Per repository. | One upgrade affects all projects using the global install. |

Use local install when a repository needs fully committed, reviewable Ralph behavior. Use global install for personal workflows, many small repositories, or teams that manage Ralph as a workstation tool.
