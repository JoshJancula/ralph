# Ralph Savings Report

Across 1 plan run, Ralph saved **150 bytes (measured)** and an estimated **60 tokens**.

Of the tool output Ralph inspected, it trimmed 18.8% before the AI read it.

Bytes are measured from actual output differences; token figures are estimated at roughly 4 bytes per token.

> **Generated file -- do not hand-edit.** Regenerate via `ralph benchmark --write-doc`.

## Per run

| Run | Date | Bytes saved (measured) | Est. tokens saved | Trimmed % (of inspected output) |
| --- | --- | --- | --- | --- |
| savings-report | 2026-06-14T10:00:00Z to 2026-06-14T10:01:00Z | 150 | 60 | 18.8% |

## Savings by path

| What Ralph did | Bytes saved (measured) | Est. tokens saved | Share of total |
| --- | --- | --- | --- |
| Shortened commands before running them | 0 | 0 | 0.0% |
| Trimmed long command output | 100 | 40 | 66.7% |
| Trimmed long command output (proxy mode) | 50 | 20 | 33.3% |
| Sent only the relevant slice of big results | 0 | 0 | 0.0% |
| **Total** | **150** | **60** | **100.0%** |

## Cache (context reuse, not savings)

Context reuse: **100** cache-read tokens (hit ratio **50.0%**). This is not counted as savings above.

## How to read this

- **Bytes saved (measured)** are real byte counts from Ralph usage summaries stored in `.ralph-workspace/logs/` per plan run.
- **Est. tokens saved** are estimated from those byte counts using a ~4 bytes/token heuristic; they will not match exact billing.
- **Trimmed %** is measured only against tool output that passed through Ralph's cleanup steps, not the whole session. It is not a discount off the total bill.
- This report does not compare against a PLAN50 or any other baseline task.
- This report does not measure end-to-end wall-clock speedup.
- **Could have saved:** 133 bytes of compaction was measured but not applied (for example, native-mode runs without proxy).

Date range: 2026-06-14T10:00:00Z to 2026-06-14T10:01:00Z.
