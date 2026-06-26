# OpenCode plugin output mutation spike

Date: 2026-06-02 (updated 2026-06-04 for T6 local plugin staging)

## Official API

OpenCode plugins export hooks documented at https://opencode.ai/docs/plugins/.

Local project plugins are auto-discovered from workspace `.opencode/plugins/` directory. Plugin files must be `.js` or `.ts` (not `.mjs`). Ralph stages the bundled plugin as a `.ts` file into the workspace for each run.

Relevant hook events:

- `tool.execute.before` -- receives `(input, output)` where `output.args` can be mutated before execution.
- `tool.execute.after` -- receives `(input, output)` where `output.output`, `output.title`, and `output.metadata` can be mutated after execution.

The `@opencode-ai/plugin` TypeScript definitions in `bundle/.opencode/node_modules/@opencode-ai/plugin/dist/index.d.ts` match the docs: `tool.execute.after` exposes `output: { title: string; output: string; metadata: any }`.

## T6 Correction: Local Plugin Staging Model

PLAN49 T6 corrected the prior implementation to use the documented local plugin path instead of config-array injection. Ralph now:

1. Stages the bundled plugin (as `.ts`) into each workspace under `.opencode/plugins/`
2. Relies on OpenCode's automatic local plugin discovery
3. No longer injects the plugin via temp `OPENCODE_CONFIG` array

This aligns with the official documented model.

## T6 Correction: Local Plugin Staging Model (verified)

PLAN49 T6 corrected the prior implementation to use the documented local plugin path. Ralph now stages the plugin as `.ts` into each workspace under `.opencode/plugins/` and relies on OpenCode's automatic local plugin discovery. This aligns with the official documented model.

## T7 Revalidation on Documented Local Plugin Path

PLAN49 T7 revalidated the hook contract using the corrected local plugin path from T6.

**Status on OpenCode 1.14.35 (as of 2026-06-04):**

- Local plugin staging to workspace `.opencode/plugins/`: **PROVEN**
- Plugin auto-discovery from workspace: **DOCUMENTED** (OpenCode auto-discovers `.ts`, `.js` plugins in this directory)
- `tool.execute.before` hook contract (input, output): **DOCUMENTED** (API surface exists in type definitions)
- `tool.execute.after` hook contract (input, output): **DOCUMENTED** (API surface exists in type definitions)
- Headless invocation of `tool.execute.before`: **NOT PROVEN ON TESTED VERSION** (PLAN33 and T7 spikes showed hooks do not fire on `opencode run --agent build` headless path)
- Headless invocation of `tool.execute.after`: **NOT PROVEN ON TESTED VERSION** (T7 telemetry test did not record hook fire)
- Agent-visible `output.output` mutation via `tool.execute.after`: **NOT PROVEN** (upstream issues note hook lifecycle may not control model-visible output)

## Known Limitations

- Headless `opencode run --agent build` may not invoke plugin hooks in the current build
- Failed or denied tool runs may not invoke hooks with a mutable result
- OpenCode bash output is a single string (`output.output`), not separate stdout/stderr like Claude PostToolUse hooks
- Upstream OpenCode issues (13573, 13575) note that mutating `output.output` in `tool.execute.after` may not control the agent-visible result; the agent may read from `result.content` or `metadata.output` instead
- Local plugin staging uses workspace `.opencode/plugins/` directory; ambient user plugins in that directory are preserved
- Plugin must be `.js`, `.ts`, or `.mjs`; only `.js` and `.ts` are auto-scanned per official OpenCode docs

## Conclusion

Ralph stages the documented local plugin into the workspace. The plugin code implements the `tool.execute.before` and `tool.execute.after` hooks according to the API contract, and the local plugin path is correctly set up.

**However, on OpenCode 1.14.35 tested 2026-06-04, these hooks have not been proven to fire on headless `opencode run` invocations, and output mutation has not been proven to reach the model.**

Ralph records `native_hooks_reason=plugin_local_load_mutation_unproven` in the overlay summary. **MCP-proxy compaction** (`RALPH_NATIVE_RESULT_COMPACT=1`, `RALPH_PROXY_SHELL_COMPACT=1`, `--ralph-mode hybrid`) is the authoritative token-reduction path for OpenCode plan runs unless `.ralph-workspace/artifacts/PLAN13/opencode-hook-revalidation.md` records `headless_mutation_reaches_model: yes`, in which case plugin-hook mutation becomes authoritative. In `hybrid`, native OpenCode tools and Ralph MCP tools are both available.

To verify for your OpenCode build, run the opt-in real smoke test:

```bash
RALPH_OPENCODE_REAL_HOOK_SMOKE=1 bats tests/bats/runtime-overlay-opencode-hooks.bats -t "real hook smoke"
```

This test will stage the plugin to the workspace using the documented local plugin path and check whether `tool.execute.after` fires (by checking for telemetry logs).
