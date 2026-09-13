# Antigravity CLI/config/plugin-command contract audit (P14)

Frozen-architecture audit only. Sources compared in-repo:

- architecture P14: `.ralph-workspace/artifacts/plugin-beta-finish/architecture.md`
- canonical contract: `bundle/.ralph/plugin-inputs/contracts/antigravity.json`
- loader closed schema: `bundle/.ralph/python/plugin_inputs.py` (`ANTIGRAVITY_CONTRACT_KEYS`, `ANTIGRAVITY_PLUGIN_COMMANDS`)
- schema pin test: `tests/bats/plugin/canonical-inputs/schema.bats`
- security fixture copy of the same pin: `tests/bats/plugin/canonical-inputs/security.bats`
- opaque-model fixture: `tests/bats/runtime/select-model-antigravity.bats`
- flag fixtures: `tests/bats/run-plan/run-plan-invoke-antigravity.bats`
- config/MCP fixtures: `tests/bats/mcp/mcp-setup-antigravity.bats`, `tests/bats/runtime/antigravity-runtime.bats`

`agy` was not invoked. No user-home Antigravity state was read (`~/.agents`, Gemini/agy cache, live `agy models`). Canonical inputs and adapters were not edited. No model string was normalized, aliased, inferred, or guessed.

## Verdict

**MATCH.** Architecture P14, the canonical contract, the loader closed schema, and the schema-test pins are identical. No `ARCHITECTURE_CONFLICT`.

Live `agy models` catalog proof is recorded as an **operator qualification prerequisite**, not a generation prerequisite, and was not collected in this packet.

## Asserted pins

| Field | Frozen P14 / contract value |
|---|---|
| configRoot | `.agents` |
| mcpFile | `mcp_config.json` |
| cli | `agy` |
| printFlag | `--print` |
| conversationFlag | `--conversation` |
| modelFlag | `--model` |
| modelsCommand | `agy models` |
| pluginCommands | `list`, `import`, `install`, `uninstall`, `enable`, `disable`, `validate`, `link` |
| modelValuePolicy | `opaque-byte-preserved` |

Contract schema contains exactly: `schemaVersion`, `runtime`, `configRoot`, `mcpFile`, `cli`, `printFlag`, `conversationFlag`, `modelFlag`, `modelsCommand`, `pluginCommands`, `modelValuePolicy`. Observed `schemaVersion` is `1` and `runtime` is `antigravity`.

Exact project MCP path is `<project>/.agents/mcp_config.json` (`configRoot` + `mcpFile`).

## Contract-to-architecture field check

| Pin | architecture.md P14 | contracts/antigravity.json | result |
|---|---|---|---|
| configRoot | `.agents` | `.agents` | MATCH |
| mcpFile | `mcp_config.json` | `mcp_config.json` | MATCH |
| cli | `agy` | `agy` | MATCH |
| printFlag | `--print` | `--print` | MATCH |
| conversationFlag | `--conversation` | `--conversation` | MATCH |
| modelFlag | `--model` | `--model` | MATCH |
| modelsCommand | `agy models` | `agy models` | MATCH |
| pluginCommands | `plugin list\|import\|install\|uninstall\|enable\|disable\|validate\|link` | same eight verbs, that order | MATCH |
| modelValuePolicy | `opaque-byte-preserved` | `opaque-byte-preserved` | MATCH |

`plugin_inputs.py` requires the same eleven keys, the same eight plugin command strings in that order, and rejects any `modelValuePolicy` other than `opaque-byte-preserved`. `schema.bats` asserts the same closed key list and the same field values. Adapter descriptor `bundle/.ralph/plugin-inputs/adapters/antigravity.json` only references the contract path; it was not modified. `plugin.json` maps `contracts.antigravity` to that same path.

## Local help evidence (not live qualification)

These in-repo artifacts prove CLI/config/plugin-command pins without starting `agy` or a model:

- P14 text: the eight plugin verbs are **locally proved**. This packet does not re-run `agy plugin --help` or `agy --help`.
- Invoke header in `bundle/.ralph/bash-lib/run-plan/run-plan-invoke-antigravity.sh` records the flag contract against `agy 1.1.9`: `--print`, `--conversation`, `--model`. That comment is local evidence, not a live catalog.
- `tests/bats/run-plan/run-plan-invoke-antigravity.bats` uses a stub `agy` and asserts `--print`, `--conversation`, and `--model` on recorded argv. It also forbids removed flags (`--format`, `--session`, `--session-id`).
- `tests/bats/graph/graph-approval-antigravity.bats` and `graph-runtime-capabilities.sh` treat `agy --help` as **help-only native-control proof**. Help probes never send a prompt and never start a model. Help text that mentions `--print`/`--model` is not `agy models` catalog proof.
- `tests/bats/mcp/mcp-setup-antigravity.bats` writes `<project>/.agents/mcp_config.json`. `tests/bats/runtime/antigravity-runtime.bats` resolves the Antigravity root to `.agents`.
- `tests/bats/runtime/select-model-antigravity.bats` stubs `agy models` and asserts the helper prints those fixture lines unchanged and that `ANTIGRAVITY_PLAN_MODEL` is preserved byte-for-byte. Those stub lines are **not** a live catalog and must not be treated as real model ids.

## Live catalog proof (operator prerequisite)

P14: generation and lifecycle accept a fixture or live `agy models` line and preserve it byte-for-byte. They never sort, normalize, alias, or infer it.

Live catalog proof is an **operator qualification**, not a generation prerequisite. A sandboxed `agy models` probe may fail because the CLI starts a local language-server listener and writes native logs. That failure is recorded as an operator prerequisite. It is not bypassed with a permission or sandbox override, and this packet did not attempt the probe.

No live display string is recorded here. Downstream packets must copy an operator-supplied or fixture line unchanged into `agy --model "<exact model string from agy models>"`.

## Opaque model policy

`modelValuePolicy` is `opaque-byte-preserved`.

- Accept a fixture line or an operator-qualified `agy models` line as opaque bytes.
- Pass that exact string to `--model`.
- Do not sort, remap, alias, trim identifiers, or invent a default from help text.
- Interactive fallbacks such as `auto` in `select-model-antigravity.sh` are menu placeholders when the CLI is absent; they are not catalog entries and must not be guessed as live models.

## Generation rule (unchanged)

A later generator must consume these frozen CLI/config/plugin-command pins. It may use in-repo fixtures for model-string preservation tests. It must not invoke live `agy models` as a generation step, must not update the pin from a sandbox failure, and must not silently rewrite plugin command names. On contract mismatch it blocks with detected vs expected values.
