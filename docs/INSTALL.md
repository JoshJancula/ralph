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

# The installer removes vendor/ralph from disk when it is not a Git checkout (typical subtree).
# Commit the new project-root files and the vendor/ removal.
git add -A
git commit -m "Add Ralph at repo root"
```

## Vendored package layout

The committed Ralph tree uses **`vendor/ralph/bundle/`** (for example **`bundle/.ralph`**). There is no **`vendor/ralph/.ralph`** inside the Ralph package until you run **`install.sh`**, which copies the shared scripts into **your** project root as **`.ralph/`**.

Always run **`vendor/ralph/install.sh`** (the script at the root of the vendored tree), not a path under **`bundle/.ralph/`**.

### After install: vendor directory

When **`install.sh`** lives under your project (for example **`./vendor/ralph/install.sh`**) and that folder is **not** its own Git checkout (no **`vendor/ralph/.git`**), the installer **removes the vendored tree after a successful install** so you commit only **`.ralph/`** and the runtime dirs at the repo root. That matches a typical **git subtree** copy.

If **`vendor/ralph/.git`** exists (Git submodule gitlink or a full clone), the vendor tree is **kept** so you can update with **`git submodule`** or **`git pull`** inside **`vendor/ralph`**. To remove it anyway, set **`RALPH_INSTALL_REMOVE_VENDOR=1`**. To always keep vendor even without **`.git`**, set **`RALPH_INSTALL_KEEP_VENDOR=1`**.

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

## Uninstall and manual vendor removal

**`--uninstall`** (alias **`--remove-installed`**) removes only **files that ship in this Ralph package** (same manifest as install, including **`ralph-dashboard/`** when that applies), then prunes empty directories. Your own files next to Ralph rules, skills, or agents stay. Stack flags work like install (for example **`--uninstall --shared`** only touches **`.ralph/`**).

**`--cleanup`** is the same as **`--remove-vendor`**: delete the vendored Ralph directory under the project when it still exists (for example you used **`RALPH_INSTALL_KEEP_VENDOR=1`** or a submodule). Normal installs already drop subtree-style **`vendor/ralph`** when safe; you usually do not need **`--cleanup`**.

**`--purge`** runs a full **`--uninstall`** for all stacks plus **`--remove-vendor`**.

```bash
./vendor/ralph/install.sh --uninstall -n              # dry-run: sample file list
./vendor/ralph/install.sh --uninstall --silent      # no prompts (CI)
./vendor/ralph/install.sh --cleanup -n               # dry-run: rm vendored tree
./vendor/ralph/install.sh --purge --silent         # full strip + vendor
```

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
