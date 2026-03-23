# Security and workspace trust

Ralph drives **Cursor**, **Claude Code**, or **Codex** against a workspace you choose. There is no substitute for knowing what those tools can read, write, and execute.

## Workspace sandboxing (what Ralph does)

**Codex:** Ralph always invokes the Codex CLI through **`.codex/ralph/codex-exec-prompt.sh`**, which runs `codex exec` with **`--sandbox`** (default mode **`workspace-write`**). Override the mode with **`CODEX_PLAN_SANDBOX`** if your CLI supports other values. By default the script also passes **`--add-dir`** for **`.ralph-workspace/`** so logs, sessions, and human-prompt files stay reachable inside the sandbox. Details: **`.codex/ralph/README.md`** and **`.codex/ralph/codex-exec-prompt.sh`** under your workspace after install.

That is **Codex-specific**. It does not stop every way secrets could leave the machine; it is the one path where Ralph wires in the vendor’s sandbox flag for you.

**Cursor and Claude:** Ralph calls **`cursor-agent` / `agent`** and **`claude`** normally. It does **not** wrap them in an extra OS-level sandbox. For those runtimes, “sandboxing” means **how you set up the repo** (throwaway clone, no production credentials on disk), **tool allowlists** (Claude), **`.cursorignore`** (Cursor), **hooks** (Claude), and **human review**.

**Simplest pattern:** run plans against a **copy** of the project, merge back only after you are happy.

## Protecting sensitive files and prompts

### Cursor: `.cursorignore`

Add **`.cursorignore`** at the repo root (`.gitignore`-style patterns). Cursor uses it for indexing and for Agent / Tab / inline edit. Full reference: [Ignore file (Cursor docs)](https://cursor.com/docs/reference/ignore-file).

**Caveat:** Cursor documents that **terminal and MCP tools** used by Agent are **not** fully governed by `.cursorignore` in the same way, so this is **partial** coverage.

### Claude Code: hooks

Use **hooks** (e.g. pre-tool-use) to block reads or edits you care about. Ralph ships an example at **`.claude/hooks/block-env-reads.sh`** (blocks reads of `.env*`). Copy or adapt it in your project, make it executable, register it in **`.claude/settings.json`**: [Claude Code hooks](https://code.claude.com/docs/en/hooks).

### Codex: ignore lists vs sandbox

`--sandbox` limits how Codex can touch the workspace **per Codex’s rules**; it is not the same as “never read `.env`.” There is still no great repo-local “never send this path to the model” story; see discussion in **[openai/codex#2847](https://github.com/openai/codex/issues/2847#issuecomment-4095749783)**. Combine **`CODEX_PLAN_SANDBOX`**, a clean tree, and minimal secrets on disk.
