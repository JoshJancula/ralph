# Dashboard local app: implementation (Codex, implementation agent)

Execute one TODO at a time. After each, run the verification steps this project expects (build, test, lint, or equivalents); fix until they pass, then mark `[x]` and continue.

Read `.agents/artifacts/dashboard/research.md` before starting. Final deliverable: working code plus `.agents/artifacts/dashboard/implementation-handoff.md` (required by orchestrator and **implementation** agent).

# Environment

- Runtime: Codex plan runner (`--non-interactive`) with **implementation** agent.
- **Mandatory:** Dashboard UI is plain HTML, CSS, and JavaScript only. Do **not** add `package.json`, `node_modules`, npm scripts, or any Node-based build. No React, no bundlers, no npm packages for the dashboard.

## TODOs

- [x] Re-read `.agents/artifacts/dashboard/research.md` (especially the Requirements section) and list files to create or change (optional Python stdlib server only if needed for listing or API; static `.html` / `.js` / `.css` for the UI).
- [x] Implement the dashboard: list or browse `.agents/orchestration-plans/` and `.agents/artifacts/`, display file contents where appropriate, and support tailing or refreshing content from `.agents/logs/`, without introducing Node or node_modules.
- [x] Add minimal run instructions in the implementation handoff.
- [x] Run project-appropriate checks (e.g. shellcheck on scripts, manual smoke test in browser). Fix failures.
- [x] Write `.agents/artifacts/dashboard/implementation-handoff.md` per agent expectations: what changed, how to verify, file paths, open risks, and any known limitations.
