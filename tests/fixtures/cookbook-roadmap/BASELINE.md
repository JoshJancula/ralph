# Cookbook roadmap baseline metrics

Checked-in fixtures under this directory capture pre-implementation behavior for
Tier 1 through Tier 3 cookbook work. Later TODOs must compare against these
metrics instead of re-measuring ad hoc.

## Fixtures

| File | What it captures |
|------|------------------|
| `prompt-byte-order-baseline.json` | Stable vs volatile prompt block bytes and per-runtime merge order |
| `mcp-tools-list-baseline.json` | Full hybrid-mode `tools/list` count, serialized byte size, and tool names |
| `bm25-rankings-baseline.json` | Deterministic lexical search ordering for labelled fixture queries |
| `tool-call-telemetry-baseline.json` | Classification buckets and optimization hints for a fixed proxy call sequence |

## Metrics later TODOs must compare against

### Prompt ordering (backlog item 1)

- `stable_precedes_volatile_in_model_context` must become `true` for cursor, codex,
  and antigravity after the stable-prefix refactor.
- `prompt_static_bytes` / `merged_prompt_bytes` for the canonical fixture inputs
  must remain byte-identical across repeated invocations within one plan.
- New usage telemetry must report stable-prefix fingerprints and byte counts without
  logging full prompt text.

### Compact MCP catalog (backlog item 3)

- Default advertised `tool_count` and `serialized_bytes` must decrease from
  `mcp-tools-list-baseline.json` while full-catalog compatibility mode restores
  the baseline values.
- `tools/list` must never emit `nextCursor: null`.

### Contextual BM25 and retrieval eval (items 6 and 7)

- `bm25-rankings-baseline.json` is the pre-contextual ordering gate.
- Item 7 must add aggregate precision/recall/MRR fixtures; item 6 may update
  per-query rankings only when retrieval safety gates pass.

### Tool-eval harness (backlog item 8)

- Reuse `tool-call-telemetry-baseline.json` classification buckets and
  `optimization_hint` patterns as the starting antipattern set.
- New harness scores must not regress offline task accuracy relative to the
  baseline fixture tasks added in item 8.

### Canonical usage schema (backlog item 11)

- Baseline usage records today expose `input_tokens`, `cache_creation_input_tokens`,
  and `cache_read_input_tokens` inconsistently across consumers.
- Item 11 must define `uncached_input_tokens`, keep compatibility readers, and
  compute `cache_efficiency_ratio` as `cache_read_input_tokens / total_input_tokens`.

## Regenerating fixtures

Only update checked-in baseline files when behavior intentionally changes and the
cookbook plan documents the rationale. Regeneration commands:

```bash
# BM25 ordering for fixture queries
fixture=tests/fixtures/mcp-proxy/search-ranking
for q in uniqueZebraHandler noop10; do
  rg -n --no-heading -S "$q" "$fixture" \
    | python3 bundle/.ralph/python/mcp-proxy-search-rank.py --query "$q" --max-results 5
done

# MCP tools/list size (hybrid, full proxy catalog)
export RALPH_MODE=hybrid \
  RALPH_MCP_PROXY_POLICY_OWNED_TOOLS_ENABLED=1 \
  RALPH_MCP_PROXY_OWNED_TOOLS_FORCE=1 \
  RALPH_MCP_PROXY_POLICY_OWNED_SEARCH_ENABLED=1 \
  RALPH_MCP_PROXY_POLICY_OWNED_REPOMAP_ENABLED=1 \
  RALPH_PROXY_SHELL_ASYNC=1
# Merge bundle/.ralph/mcp-server.sh base tools with proxy + result tools via jq.
```

Do not store absolute paths, timestamps, credentials, or live model outputs in
baseline artifacts.
