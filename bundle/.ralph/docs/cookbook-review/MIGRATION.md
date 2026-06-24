# Cookbook Tier 1 through Tier 3 migration and compatibility

This document covers backward compatibility for PLAN12 cookbook features. All
behavior-changing optimizations remain **Ralph/hybrid-only by default** until
promotion criteria in [IMPLEMENTATION-RESULTS.md](./IMPLEMENTATION-RESULTS.md)
are met. Native/no mode defaults are unchanged in this rollout.

## Rollout convention (shared by every cookbook gate)

| Mode | Default for a cookbook feature | Override |
|------|----------------------------------|----------|
| `RALPH_MODE=ralph` or `hybrid` | **Enabled** unless the feature env var is `0` | Set feature var to `0` to opt out |
| Unset, `no`, `native`, or any other value | **Disabled** unless the feature env var is `1` | Set feature var to `1` to opt in |
| Invalid boolean (`2`, `yes`, empty after trim, etc.) | Fail early with an actionable error | Use `0`, `1`, or unset |

See [BACKLOG.md](./BACKLOG.md) for per-item gates, implementation paths, and tests.

## Artifact JSON schemas versus legacy handoff markdown

**Before:** Orchestration stages validated only that required artifact paths exist
and are non-empty. Review loops used free-form `<!-- REVIEW_STATUS -->` markdown
with a `status:` line.

**After (opt-in by mode):** Stages may declare `schema` on artifact entries.
Ralph validates produced JSON with the stdlib subset validator
(`bundle/.ralph/python/artifact_json_schema.py`) when
`RALPH_ARTIFACT_SCHEMA_VALIDATION` is enabled. Loop-check artifacts may declare
`loopCheck.schema` / `loopControl.evaluatorSchema` pointing at
`bundle/.ralph/schemas/evaluator-verdict.schema.json`.

**Compatibility:**

- Omitting `schema` on artifacts preserves legacy behavior (existence + non-empty
  checks only).
- When no evaluator schema is declared, the markdown `REVIEW_STATUS` parser
  remains the sole loopback signal.
- When a schema **is** declared and `RALPH_EVALUATOR_JSON_CONTRACT=1` (or
  Ralph/hybrid default), Ralph parses only validated JSON
  `{status, feedback[]}`; markdown status blocks in that artifact are ignored.
- Invalid JSON or schema violations fail the stage with stage id, artifact path,
  schema path, and JSON pointer.

## Compact versus full MCP tool catalogs

**Full catalog (legacy):** `tools/list` advertises every Ralph proxy tool. Set
`RALPH_MCP_COMPACT_TOOL_CATALOG=0` to restore this surface in Ralph/hybrid mode.

**Compact catalog (Ralph/hybrid default):** `tools/list` advertises a small core
set (`RALPH_MCP_CORE_TOOLS` overrides the default list in
`bundle/.ralph/bash-lib/mcp-proxy/mcp-proxy-tools.sh`) plus
`ralph_proxy_tool_search` for lexical discovery. Full tool definitions remain
available through search results; embeddings are never required.

**Compatibility:**

- Native/no mode keeps the historical full-catalog injection path unless
  `RALPH_MCP_COMPACT_TOOL_CATALOG=1` is set explicitly.
- `tools/list` must never emit `nextCursor: null` (Claude Code 2.1.x silently
  drops all tools when that field is present).
- Compare serialized byte counts against
  `tests/fixtures/cookbook-roadmap/mcp-tools-list-baseline.json` only when
  intentionally changing catalog policy.

## Usage schema v2 and compatibility readers

**Legacy records** used `input_tokens`, optional cache fields, and ad hoc
`cache_hit_ratio` keys across consumers.

**Canonical writers** (`bundle/.ralph/python/usage_accounting.py`) emit schema
version 2 fields: `uncached_input_tokens`, `cache_creation_input_tokens`,
`cache_read_input_tokens`, `total_input_tokens`, `cache_efficiency_ratio`, and
per-bucket `measurement_source` labels (`measured`, `estimated`, `unavailable`,
`mixed`).

**Compatibility readers** (`normalize_usage`, benchmark report, orchestrator
summary) accept legacy `input_tokens` as uncached input and never rewrite
historical JSONL files. Admin API reconciliation remains future opt-in; estimates
stay labelled. There is no `RALPH_USAGE_SCHEMA_V2` runtime gate -- readers are
always backward compatible.

## Progressive disclosure fallback

When `RALPH_PROGRESSIVE_CONTEXT=1` (Ralph/hybrid default), optional rules and
skills expose Tier 1 metadata in the stable prompt; full bodies load into the
volatile prompt only when BM25-ranked relevant or explicitly mentioned in the
TODO. Rules with `alwaysApply: true` always load in full.

**Fallback:** Malformed or missing rule/skill metadata triggers a one-time
warning and **legacy full loading** for that entry so agents never lose context
silently. Native Claude `--agent` passthrough skips Ralph context assembly
entirely (unchanged).

## Continuation state rebuild

Between-TODO state lives at
`.ralph-workspace/sessions/<plan-key>/continuation-summary.json`. Ralph never
invents model-generated summaries; all entries come from runner-verifiable
sources (completed TODO excerpts, verification outcomes, human decisions,
structured completion footers).

**Rebuild:** `continuation_summary.py` migrates older schema versions via
`migrate_state`, then renders Markdown with `rebuild_markdown`. Hierarchical
consolidation (`RALPH_CONTINUATION_SUMMARY_HIERARCHICAL`) groups older completed
TODOs deterministically; recent detail, unresolved failures, errors, and human
decisions are preserved. Deleting the JSON file and re-running the plan rebuilds
state from subsequent TODO completions (prior history is lost -- operators should
treat the file as session state, not source of truth for the plan file itself).

**Compatibility:** With `RALPH_CONTINUATION_SUMMARY=0` or native/no default,
prompts match the pre-cookbook shape and no summary file is written.

## Reasoning effort on unsupported runtimes

Portable values: `low`, `medium`, `high`, `xhigh`, `max`, `inherit`. Precedence:
CLI flag > runtime env > agent frontmatter > `inherit`.

| Runtime | When supported | When unsupported |
|---------|----------------|------------------|
| Claude | Maps to `--effort` after capability detection | Logs once; uses `inherit` |
| Codex | Maps to `model_reasoning_effort` via `exec --config` when CLI accepts the key | Logs once; uses `inherit` |
| Cursor, OpenCode, Antigravity | N/A today | Logs once per runtime; uses `inherit` |

Invocation usage records include `reasoning_effort_resolved` and
`reasoning_effort_applied` for observability. No raw thinking-token API is
assumed.

## Promotion criteria (Ralph/hybrid-only until met)

Cookbook optimizations stay gated to `RALPH_MODE=ralph` or `hybrid` until **all**
of the following hold on the main branch:

1. **Offline task accuracy** -- tool-eval offline harness does not regress versus
   `tests/fixtures/tool-eval/baseline-report.json`.
2. **Retrieval safety** -- contextual BM25 passes per-query safety gates in
   `tests/fixtures/retrieval-eval/baseline-metrics.json`.
3. **Catalog bytes** -- default compact `tools/list` serialized size is strictly
   below the full-catalog baseline in
   `tests/fixtures/cookbook-roadmap/mcp-tools-list-baseline.json`.
4. **Bounded context** -- prompt stable-prefix fingerprints and continuation
   summary byte metrics stay within documented caps (see
   `tests/fixtures/cookbook-roadmap/prompt-byte-order-baseline.json` and
   continuation summary env limits in [ENVIRONMENT.md](../ENVIRONMENT.md)).

Until promotion, do **not** change default `RALPH_MODE` from `no` for
non-interactive runs or enable cookbook features in native/no mode by default.

## End-to-end offline fixture

`tests/fixtures/cookbook-roadmap/offline-e2e/` plus
`tests/python/test_cookbook_offline_e2e.py` exercise stable prompt ordering,
continuation rebuild, compact tool discovery, contextual retrieval,
schema-validated evaluator feedback, and loopback rendering without a live model.
Run:

```bash
python3 -m unittest tests.python.test_cookbook_offline_e2e -v
```
