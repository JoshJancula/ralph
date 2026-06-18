# OpenCode integration (Ralph development repo)

This directory is **project-owned runtime config** for Ralph's own development workflow in this repository. Downstream projects receive installable defaults from `bundle/.opencode/` via `./install.sh`.

The canonical source for the OpenCode agents is `bundle/.ralph/agents/<id>.md`; `scripts/sync-runtime-assets.sh` generates the runtime `config.json` and `.md` files from that frontmatter.

## Layout

| Path | Role |
|------|------|
| `agents/` | Ralph orchestration agent profiles for OpenCode plan runs |
| `plugins/ralph-runtime-hooks.mjs` | Bundled plugin Ralph injects via temp `OPENCODE_CONFIG` when native adapters (via `--ralph-mode native` or `hybrid`) |
| `rules/` | OpenCode rules for this repo |
| `skills/repo-context/` | Repo layout and command hints for agents |

Edit files here for Ralph dev workflow changes. Edit `bundle/.opencode/plugins/` for install templates.

## Native plugin contract (headless)

Verified on **OpenCode `1.14.35`** (2026-06-04). Ralph injects the plugin through a per-run temp `OPENCODE_CONFIG`, but `tool.execute.before` and `tool.execute.after` **do not fire** on the headless `opencode run` path. Overlay summary records `native_hooks_configured=true`, `native_hooks_effective=false`, and `native_hooks_reason=plugin_injected_mutation_unproven`.

Use **`--ralph-mode hybrid`** so MCP `ralph_proxy_shell` compaction remains the authoritative token-reduction path. See [docs/TOOLING.md](../docs/TOOLING.md#opencode) and `plugins/SPIKE-output-mutation.md`.

## Cache strategy

Ralph optimizes OpenCode plan runs for provider-side prompt caching.

- **`setCacheKey` injection:** Runs in every `--ralph-mode` (`native`, `hybrid`, `ralph`, or unset), independent of MCP or native-hooks gating. When the merged ambient OpenCode config declares no cache settings for the selected provider, Ralph deep-merges `provider.<id>.options.setCacheKey: true` into the per-run temp `OPENCODE_CONFIG`. The provider id is derived from the model before the first `/` (e.g. `ollama-cloud/kimi-k2.6` -> `ollama-cloud`; models without a slash get no injection). Gate: `RALPH_OPENCODE_SET_CACHE_KEY` (default `1`, set `0` to opt out).
- **Passthrough provider routing (verified chain):**
  1. OpenCode `setCacheKey` produces camelCase `promptCacheKey` in the outgoing request.
  2. The openai-compatible package passes unknown keys through verbatim.
  3. Ollama Cloud ignores the camelCase field.
  4. Therefore Ralph additionally injects snake_case `prompt_cache_key` per-model for passthrough providers (currently `ollama-cloud`). The injected value is `ralph-<plan-slug>` (derived from `RALPH_PLAN_KEY`).
- **Ollama Cloud zero-reporting limitation:** Ollama Cloud still reports 0 cached tokens ([upstream ollama/ollama issue 15758](https://github.com/ollama/ollama/issues/15758)), so usage records cannot show cache reads even when caching works. Ollama documents no cached-token billing discount, making input-token reduction the primary cost lever.
- **Prompt prefix ordering:** For the `opencode` runtime only, the static prompt block is placed before the per-TODO variable portion so consecutive invocations share a byte-identical prefix, maximizing cache hits. Other runtimes' prompt assembly is unchanged.
- **Cache reporting classification:** When cache settings exist (injected or ambient) but no cache tokens are observed, Ralph emits an informational `cache-enabled-not-reported` note instead of the hard "may not support caching" warning (`run-plan-opencode-cache-warning.sh`). The plan usage summary exposes this as `cache_reporting: "none" | "unavailable" | "observed"`.
