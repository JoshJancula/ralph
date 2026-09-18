# Plan log layout test fixtures

Reference trees for `plan-log-layout-contract.md`. The authoritative behavioral
check is `plan-log-layout-contract.test.ts`, which builds equivalent directories
in a temp workspace at test time (these static descriptions stay in sync with
that helper).

## 1. manifest-run (`plan-key: manifest-fixture`)

```
logs/manifest-fixture/
  plan-usage-summary.json
  invocation-usage.json
  plan-runner-demo-output.log
  runs/run-20260101T000000Z-fixture/
    run-manifest.json
```

Expect: one list item, `source: manifest`, detail includes labeled manifest +
usage summary, output log in `files.raw`.

## 2. legacy-flat-output-only (`plan-key: flat-output-only`)

```
logs/flat-output-only/
  plan-runner-old-output.log
```

Expect: **no** plan-run list items (no summary, no manifest). File remains
openable via logs explorer (`root=logs`, path `flat-output-only/plan-runner-old-output.log`).

## 3. legacy-nested-subdir (`plan-key: nested-attempt`)

```
logs/nested-attempt/
  run-attempt-1/
    plan-runner-nested-output.log
```

Expect: **no** plan-run list items today. Nested resolution for "View logs" uses
newest subdir + `.log` (`PlanLogResolutionService`).

## 4. legacy-with-summary (`plan-key: summary-legacy`)

```
logs/summary-legacy/
  plan-usage-summary.json   # run_id: legacy-run-summary-1
  invocation-usage.json
  discover-report.json
  plan-runner-summary-output.log
```

Expect: one list item, `source: legacy`, `runId: legacy-run-summary-1`, summary
files labeled, output and discover report in raw (discover also via metrics API).

## Openability rule

Every path returned by plan-run detail `files.summary` or `files.raw` must be
readable through the dashboard file endpoint for the same `workspaceRoot` without
path traversal. Do not expose `processes/` or secrets (e.g. `run.json` token).
