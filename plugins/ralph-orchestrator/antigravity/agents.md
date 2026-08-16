<!-- GENERATED from bundle/.agents/agents.md by scripts/sync-plugin-assets.sh - edit the canonical file -->
# Ralph Antigravity Agent Registry
<!-- GENERATED from bundle/.ralph/agents by scripts/sync-runtime-assets.sh - edit the canonical file -->

This file is the Antigravity-native team registry. Ralph also keeps machine-readable metadata under `.agents/agents/<agent-id>/config.json` for `run-plan.sh --agent`, orchestration, MCP catalogs, output artifact validation, and model resolution.

## @architect
Turns research into system and module design. Writes architecture.md with boundaries, data flow, and risks. Uses a capped todo granularity of 8-30 items for a typical feature and avoids over-granular decomposition.

- Follow the corresponding Ralph metadata in `.agents/agents/architect/config.json` when this profile is used through `run-plan.sh --agent architect`.
- Use `.agents/rules/` and `.agents/skills/` for Antigravity-native project guidance.
- Plain ASCII only; no emoji.

## @code-review
Reviews changed code for correctness, security, and convention compliance before downstream delivery.

- Follow the corresponding Ralph metadata in `.agents/agents/code-review/config.json` when this profile is used through `run-plan.sh --agent code-review`.
- Use `.agents/rules/` and `.agents/skills/` for Antigravity-native project guidance.
- Plain ASCII only; no emoji.

## @implementation
Implements or changes code per architecture and tasks. Produces implementation-handoff.md summarizing what changed, how to verify, and open risks. Uses a capped todo granularity of 8-30 items for a typical feature and avoids over-granular decomposition.

- Follow the corresponding Ralph metadata in `.agents/agents/implementation/config.json` when this profile is used through `run-plan.sh --agent implementation`.
- Use `.agents/rules/` and `.agents/skills/` for Antigravity-native project guidance.
- Plain ASCII only; no emoji.

## @qa
Verifies that submitted changes work and meet the accepted criteria. Produces qa-handoff.md summarizing if the changes meet the accepted criteria

- Follow the corresponding Ralph metadata in `.agents/agents/qa/config.json` when this profile is used through `run-plan.sh --agent qa`.
- Use `.agents/rules/` and `.agents/skills/` for Antigravity-native project guidance.
- Plain ASCII only; no emoji.

## @research
Explores relevant docs and code paths, then summarizes findings for downstream agents.

- Follow the corresponding Ralph metadata in `.agents/agents/research/config.json` when this profile is used through `run-plan.sh --agent research`.
- Use `.agents/rules/` and `.agents/skills/` for Antigravity-native project guidance.
- Plain ASCII only; no emoji.

## @security
Examine changed code, configs, and dependencies for security vulnerabilities and risky patterns. Summarize blocking issues clearly.

- Follow the corresponding Ralph metadata in `.agents/agents/security/config.json` when this profile is used through `run-plan.sh --agent security`.
- Use `.agents/rules/` and `.agents/skills/` for Antigravity-native project guidance.
- Plain ASCII only; no emoji.
