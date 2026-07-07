# Benchmark channel attribution baseline fixtures

Offline fixtures that pin current channel-blind telemetry behavior before the
channel-attribution overhaul. Tests load these files and assert today's failure
modes; later TODOs flip the marked assertions.

| Fixture | Purpose |
|---------|---------|
| `mixed-runtime-overlay-stale-summary.json` | PLAN8-style mixed-runtime contamination via mutable `summary.json` |
| `native-heavy-with-real-optimization.json` | Native-heavy tool mix coexists with real optimization savings |
| `e2e/manifest.json` | Full-stack synthetic run: two runtimes, windowing channels, readback, overlay summaries |

## Later TODO assertion flips

See `.ralph-workspace/artifacts/benchmark-channel-attribution.plan/baseline-handoff.md`
for the full list of assertions that must change once per-runtime summaries and
exact channel ids land.
