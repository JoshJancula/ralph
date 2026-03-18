# Agent-local rules (architect)

Add rule files here that apply only to the **architect** agent. Use formats your toolchain accepts (for example `.md`).

Reference them from `config.json` in the `rules` array with paths **relative to the repo root**, for example:

`.claude/agents/architect/rules/architect-only.md`

Keeping rules in this directory lets teams extend behavior without changing core scripts under `.claude/ralph/` when that runner exists.
