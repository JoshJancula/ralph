# Installation and setup

This guide covers how to get Ralph into **your** application or library repository: vendoring (submodule or subtree), a one-time copy, what the installer puts on disk, flags, and removal.

Unless noted, run commands from **your project root** (the directory that will contain **`.ralph/`** after install).

## Submodule (easy updates)

The examples use the main Ralph repository; if you use a fork, substitute its URL in **`git submodule add`**.

```bash
# Go to your project repository (the app or library you are wiring up).
cd /path/to/your-repo

# Register Ralph as a submodule and fetch it.
git submodule add https://github.com/JoshJancula/ralph.git vendor/ralph
git submodule update --init

# Copy Ralph runners, agents, and .ralph/ into this repo (from vendor/ralph).
./vendor/ralph/install.sh

# Stage the new files, then commit.
git add .ralph \
  .cursor/ralph .cursor/rules .cursor/skills .cursor/agents \
  .claude/ralph .claude/rules .claude/skills .claude/agents \
  .codex/ralph .codex/rules .codex/skills .codex/agents
git commit -m "Add Ralph agent workflows"
```

Teammates: after **`git clone`**, run **`git submodule update --init`** and, if the Ralph bundle changed, **`./vendor/ralph/install.sh`** again.

## One-time copy (no vendor directory)

```bash
# Clone Ralph to a throwaway directory (not inside your project).
git clone https://github.com/JoshJancula/ralph.git /tmp/ralph

# Install from that clone into your project root; adjust the path as needed.
/tmp/ralph/install.sh /path/to/your-repo

# Remove the temporary clone when finished.
rm -rf /tmp/ralph
```

Reinstall or upgrade by cloning again and re-running **`install.sh`** against your repo.

## Subtree

```bash
# From your project repository: merge Ralph history under vendor/ralph.
git subtree add --prefix vendor/ralph https://github.com/JoshJancula/ralph.git main --squash

# Copy Ralph into .ralph/, .cursor/, .claude/, .codex/ at your repo root.
./vendor/ralph/install.sh
```

## Vendored package layout

The committed Ralph tree uses **`vendor/ralph/bundle/`** (for example **`bundle/.ralph`**). There is no **`vendor/ralph/.ralph`** inside the Ralph package until you run **`install.sh`**, which copies the shared scripts into **your** project root as **`.ralph/`**.

Always run **`vendor/ralph/install.sh`** (the script at the root of the vendored tree), not a path under **`bundle/.ralph/`**.

## Installer options

With **no flags**, **`install.sh`** installs the full stack (same as **`--all`**): shared **`.ralph/`**, Cursor, Claude, and Codex pieces, plus the dashboard under **`.ralph/ralph-dashboard/`**.

```text
./install.sh                      # full install (default)
./install.sh --all                # same as default
./install.sh --cursor             # Cursor runner + rules/skills/agents (combine with --shared if you need .ralph)
./install.sh --codex --claude     # Codex and Claude only
./install.sh --shared             # only .ralph/ (orchestrator, templates, runners, docs)
./install.sh --no-dashboard       # skip .ralph/ralph-dashboard/
./install.sh -n /path/to/repo     # dry-run: print actions only
```

You can combine **`--cursor`**, **`--claude`**, **`--codex`**, and **`--shared`** to trim what is copied.

### Partial installs

**`--cursor`** alone does **not** install shared **`.ralph/`** scripts (unified runner, orchestrator, plan template, in-tree docs). A default install still copies the dashboard into **`.ralph/ralph-dashboard/`**, which may create a **`.ralph/`** directory that only contains the dashboard until you add **`--shared`**. Add **`--shared`** (or do a full install) when you need the rest of **`.ralph/`**.

The Claude and Codex runners expect **`.ralph/agent-config-tool.sh`** when you use **`--agent`**; use **`./install.sh --claude --shared`**, **`./install.sh --codex --shared`**, or a full install.

## Uninstall / cleanup

From your project root, when Ralph is vendored as **`vendor/ralph`** (or another path under the repo):

```bash
./vendor/ralph/install.sh --cleanup -n              # dry-run: list paths only
./vendor/ralph/install.sh --cleanup --silent        # no prompts (scripts / CI)
```

**`--cleanup`** removes the same trees a full install would add (including the dashboard under **`.ralph/ralph-dashboard/`**, or all of **`.ralph/`** when shared tooling is removed) and then deletes the vendored Ralph directory (the folder that contains **`install.sh`**, only if it lies under the target directory). Use **`--remove-installed`** or **`--remove-vendor`** alone for a single step. For **`--remove-installed`**, stack flags apply the same way as install (for example **`--remove-installed --shared`** drops only **`.ralph/`**).

**Warning:** **`--remove-installed`** deletes whole directories such as **`.cursor/rules`** and **`.cursor/skills`** when that stack is selected. If you added non-Ralph files there, move them before cleanup.

You still need normal Git steps for submodules (**`git submodule deinit`**, **`git rm`**) or subtree history; the installer only removes files on disk.

## What gets installed (summary)

After **`install.sh`** runs, typical paths at your project root include:

- **`.ralph/`** -- **`run-plan.sh`**, orchestrator, templates, MCP server, **`.ralph/docs/`**, optional **`.ralph/ralph-dashboard/`**
- **`.cursor/`**, **`.claude/`**, **`.codex/`** -- per-runtime **`ralph/`** runners plus rules, skills, and agents (depending on flags)

See the main repository **README** for a compact table and **repo-context** notes.

## See also

- [Documentation index](README.md)
- [Agent workflow](AGENT-WORKFLOW.md)
- [MCP](MCP.md) (optional MCP server configuration after install)
