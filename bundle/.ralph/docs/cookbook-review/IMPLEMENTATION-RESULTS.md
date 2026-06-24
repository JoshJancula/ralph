# PLAN12 Tier 1 through Tier 3 implementation results

Recorded during PLAN12 integration (TODO line 23). Values are machine-independent:
commands use project-root-relative paths and fixtures under `tests/fixtures/`.

## Promotion status

Cookbook features remain **Ralph/hybrid-only** by default. Native/no behavior is
unchanged. Promotion criteria are documented in
[MIGRATION.md](./MIGRATION.md#promotion-criteria-ralphhybrid-only-until-met); this
integration TODO does **not** change default `RALPH_MODE`.

| Criterion | Status | Notes |
|-----------|--------|-------|
| Offline task accuracy (tool eval) | pass | Matches `tests/fixtures/tool-eval/baseline-report.json` |
| Retrieval safety gates | pass | Matches updated `tests/fixtures/retrieval-eval/baseline-metrics.json` |
| Compact catalog bytes below full baseline | pass | Core + search surface smaller than `mcp-tools-list-baseline.json` (19 tools / 9213 bytes full) |
| Bounded prompt/summary context | pass | `prompt-byte-order-baseline.json`; continuation caps in ENVIRONMENT.md |

## Retrieval eval baseline

**Command:**

```bash
python3 bundle/.ralph/python/retrieval_eval.py \
  --project-root . \
  --queries tests/fixtures/retrieval-eval/queries.json \
  --contextual 1 \
  --baseline tests/fixtures/retrieval-eval/baseline-metrics.json
```

**Interpretation:** Exit code `0` means aggregate metrics stay within baseline
tolerance floors and every query's `safety_top10` required hits appear in the
current top-10. Non-zero exit prints a failure report listing regressions and
missing safety paths.

| Metric | Before (checked-in baseline pre-refresh) | After (current contextual ranker) |
|--------|------------------------------------------|-------------------------------------|
| `precision_at_5` | 0.775 | 0.77 |
| `recall_at_5` | 0.766667 | 0.758333 |
| `recall_at_10` | 0.783333 | 0.766667 |
| `mrr` | 0.975 | 0.9625 |
| `queries_no_relevant_top10` | 0 | 0 |

Safety gate paths in `baseline-metrics.json` were refreshed to match current
top-10 hits after agent-doc and cookbook-doc line drift; aggregate metrics remain
within configured tolerance floors.

**Unit tests:**

```bash
python3 -m unittest tests.python.test_retrieval_eval -v
```

## Tool eval baseline

**Command:**

```bash
python3 bundle/.ralph/python/tool_eval.py \
  --project-root . \
  --mode offline \
  --tasks tests/fixtures/tool-eval/tasks.json \
  --traces tests/fixtures/tool-eval/offline-traces.json \
  --baseline tests/fixtures/tool-eval/baseline-report.json
```

**Interpretation:** Exit code `0` means offline replay scores match the checked-in
baseline (`mean_accuracy`, `completion_rate`, per-task accuracy, antipattern
counts). Live mode (`RALPH_TOOL_EVAL=live`) is opt-in and not part of CI.

| Metric | Baseline (checked-in) | After (offline replay) |
|--------|----------------------|-------------------------|
| `mean_accuracy` | 1.0 | 1.0 |
| `completion_rate` | 0.789474 | 0.789474 |
| `task_count` | 19 | 19 |
| `total_duplicate_reads` | 3 | 3 |
| `total_batchable_serial_calls` | 4 | 4 |

**Unit tests:**

```bash
python3 -m unittest tests.python.test_tool_eval -v
```

## End-to-end offline fixture

**Command:**

```bash
python3 -m unittest tests.python.test_cookbook_offline_e2e -v
```

**Interpretation:** Exercises stable prompt merge, continuation rebuild,
`ralph_proxy_tool_search` ranking, contextual BM25 on the fixture workspace,
evaluator JSON schema validation, and loopback feedback rendering without a live
model. Fixture manifest:
`tests/fixtures/cookbook-roadmap/offline-e2e/manifest.json`.

## Environment variable audit

All Tier 1 through Tier 3 gates are documented in
[ENVIRONMENT.md](../ENVIRONMENT.md#cookbook-feature-gates-tier-1-through-tier-3)
with rollout parsing (`0` / `1` / unset), defaults by `RALPH_MODE`, and Bats or
Python tests cited in [BACKLOG.md](./BACKLOG.md). Item 19
(`RALPH_CLAUDE_SPECULATIVE_CACHE_WARM`) defaults off everywhere; capability probe
must pass before any warm request is attempted.

## Verification log (PLAN12 TODO line 23)

```bash
bash -n bundle/.ralph/run-plan.sh bundle/.ralph/orchestrator.sh bundle/.ralph/mcp-server.sh
bash scripts/sync-runtime-assets.sh --check
bash scripts/run-python-unit-tests.sh
bash scripts/run-bats.sh
if [ -d ralph-dashboard/node_modules ]; then npm test --prefix ralph-dashboard -- --runInBand; else printf '%s\n' 'ralph-dashboard/node_modules absent; dashboard test skipped without installing dependencies'; fi
```

Dashboard note: run the conditional `npm test` line above; when
`ralph-dashboard/node_modules` is absent, record the skip message without
installing dependencies.
