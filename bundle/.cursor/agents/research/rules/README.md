# Agent-local rules (research)

Add rule files here that apply only to the **research** agent. Use formats your toolchain accepts (for example `.mdc` or `.md`).

Reference them from `config.json` in the `rules` array with paths **relative to the repo root**, for example:

`.cursor/agents/research/rules/research-only.mdc`

Keeping rules in this directory lets teams extend behavior without changing core scripts under `.cursor/ralph/`.
