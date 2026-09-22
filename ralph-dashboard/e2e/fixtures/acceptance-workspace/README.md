# Acceptance workspace fixture

Project root for Playwright journeys (`playwright.config.ts` sets
`RALPH_DASHBOARD_PROJECT_ROOT` here). Includes duplicate plan basenames,
classic/YAML plans, workflow overrides, and usage samples for PLAN18.

## View logs browser tests

Under `.ralph-workspace/plans/`:

- `view-logs-e2e.md` — legacy plan-level log tree with many openable
  evidence files (logs, JSON, JSONL, nested paths). Used by `e2e/plan-view-logs.spec.ts`.
- `view-logs-manifest-e2e.md` — manifest-backed run under
  `logs/view-logs-manifest-e2e/runs/run-e2e-20260101T000000Z-test/`.

Run:

```bash
npm run build
npm run test:e2e plan-view-logs
```

Requires Playwright browsers (`npx playwright install` once per machine).

## State navigation (layout 2)

`runs/run-nav-v2-failed/` — failed plan run with `failed-check.json`, child attempt, and related artifact for `e2e/state-navigation.spec.ts`.
