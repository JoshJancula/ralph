---
name: test-design
description: What needs a test and what does not, where each kind belongs, and the speed rules for the default Bats suite (no blocking sleep, no long-running e2e).
globs: ["tests/**", "scripts/**", "**/*.bats", "bundle/.ralph/**/*.sh"]
alwaysApply: false
---

# Test design: what, where, and how fast

The Bats suite is a **shared gate**. Every second you add is paid by every
person and every agent run that touches this repo, forever. A suite that takes
hours does not get run, which means it stops catching anything. Treat suite
time as a budget you are spending on someone else's behalf.

This rule is about judgment. See [testing-workflow](testing-workflow.md) for the
commands.

## When something needs a test

Write a test when the change creates a **behavior someone could depend on and
someone else could break**:

- A new script, function, flag, or environment variable.
- A contract: an exact output field, exit code, file layout, or error message
  another component or an operator reads.
- A **fixed** decision: something the code must refuse, must not write, must
  not leak. Rejections are worth more than happy paths, because a happy path
  usually breaks loudly and a missing rejection breaks silently.
- A real defect you just fixed. Encode the failure, not the fix, so the test
  survives a rewrite of the implementation.

Do **not** add a test when:

- It restates the implementation line by line. That is a change detector: it
  fails on every refactor and catches no bug.
- It asserts an incidental detail (log wording nobody parses, ordering nothing
  depends on, an internal helper's signature).
- An existing test already covers the behavior through a public entry point.
  Extend that test instead of adding a near-duplicate file.
- The change is docs-only. It must still pass the existing suite.

When you remove a feature, remove its tests in the same change. A suite full of
tests for deleted behavior is worse than no tests: it fails for reasons that
teach nothing, and people learn to ignore red.

## Where it belongs

Pick the cheapest level that can actually observe the behavior:

| Level | Use when | Cost |
|-------|----------|------|
| Python stdlib unit test (`tests/python/`) | The logic is Ralph-owned Python | milliseconds |
| Bats against a **sourced function** | You can `source` the lib and call the function | ~10ms |
| Bats against a **script entry point** | The behavior only exists via argv/exit code | ~0.5-2s |
| Bats driving `run-plan.sh` / `orchestrator.sh` / `graph-run.sh` | The behavior genuinely spans the whole runner | **~13s minimum** |

That bottom row is not free. One no-op `run-plan.sh` invocation spawns roughly
60 `python3` processes and 20 `jq` processes before it does any of your work.
If you only need to prove a flag is parsed, source the args lib and call the
parser. Reach for the full runner only when the integration itself is the
thing under test.

## Speed rules

- **Target: a Bats test finishes in under 1 second.** Up to ~5s is acceptable
  for a script entry point. Past ~10s, justify it in a comment or move it out
  of the default tier.
- Reuse fixtures. Do not rebuild a whole workspace per test when `setup_file`
  or a shared helper can build it once.
- Stub the runtime CLI. Never let the default suite invoke a real agent CLI,
  hit the network, or wait on a real model.

## Never use a blocking sleep

`sleep` in a test is almost always a guess about someone else's timing. It is
either too short (flaky) or too long (slow), usually both on different
machines.

Instead:

- **Wait for the actual condition**, with a deadline and a small poll:

  ```bash
  deadline=$(( $(date +%s) + 5 ))
  until [[ -s "$expected_file" ]]; do
    [[ $(date +%s) -lt $deadline ]] || { echo "timed out waiting for $expected_file" >&2; return 1; }
    sleep 0.05
  done
  ```

- **Scale production pacing instead of enduring it.** Ralph's poll loops call
  `ralph_wait` (`bundle/.ralph/bash-lib/ralph-wait.sh`), not bare `sleep`. The
  Bats helper exports `RALPH_WAIT_SCALE=0`, which collapses those waits;
  production leaves it unset and keeps full pacing. If you add a poll loop to
  production code, use `ralph_wait` so tests are not forced to sit through it.
- **The one exception:** the duration itself is what you are asserting (a
  timeout firing, a backoff interval). Then call `sleep` directly, keep the
  configured duration as small as the assertion allows, and say why in a
  comment.

A backgrounded `sleep 120 &` used as a victim process for teardown tests is
fine: nothing waits on it.

## Never tear down a supervisor run you did not create

`run-plan` evals the process supervisor's exports, so **an agent shell inside a
live plan run inherits `RALPH_PROCESS_RUN_DIR` pointing at the runner's own
run.** A teardown like this looks harmless and kills the plan run that invoked
the test:

```bash
teardown() {                                   # WRONG
  if [[ -n "${RALPH_PROCESS_RUN_DIR:-}" && -d "${RALPH_PROCESS_RUN_DIR:-}" ]]; then
    python3 "$SUPERVISOR_PY" close --run-dir "$RALPH_PROCESS_RUN_DIR" --force
  fi
}
```

`close` calls `stop_run`, which terminates every registered scope in that run
and releases its leases. Pointed at the runner, it flips the plan's `run.json`
from `running` to `stopped` and kills its processes mid-run.

Scope teardown to runs the test itself created, under the test's own state root:

```bash
teardown() {                                   # RIGHT
  if [[ -n "${RALPH_PLAN_WORKSPACE_ROOT:-}" && -d "${RALPH_PLAN_WORKSPACE_ROOT}/processes/active" ]]; then
    local run_file
    while IFS= read -r run_file; do
      python3 "$SUPERVISOR_PY" close --run-dir "$(dirname "$run_file")" --reason test-teardown --force >/dev/null 2>&1 || true
    done < <(find "${RALPH_PLAN_WORKSPACE_ROOT}/processes/active" -mindepth 2 -maxdepth 2 -name run.json -type f 2>/dev/null)
  fi
  rm -rf "$TEST_TMPDIR"
}
```

`tests/bats/helper/load-lib.bash` now unsets the whole `RALPH_PROCESS_*` family
(as `scripts/run-bats.sh` already did), so a test that merely inherits the
variable is safe. That is a backstop, not a licence: a test that names
`RALPH_PROCESS_RUN_DIR` explicitly still has to scope its own cleanup.

## Long-running end-to-end tests

**Do not put a multi-minute end-to-end or "operator journey" test in the
default suite.** They are not banned; they are opt-in. Forcing them on
everyone is what turns a suite into something nobody runs.

The tiering already exists and the default already respects it:
`bash scripts/run-bats.sh` runs the fast tier, and `tests/bats/tiers.json`
classifies what is excluded. Use `--tier all` when you deliberately want
everything.

The fast tier has a measured cost budget, recorded under `measured` in
`tests/bats/tiers.json` and enforced by `run-bats.sh --tier fast`:

- a single `fast` test must stay **under 60 seconds**, and
- a `fast` file's tests must sum to **under one minute**.

`run-bats.sh --tier fast` refuses to run when the baseline records a fast file
at or above either limit, naming the file. The only sanctioned exemption is
listing that file in the `slow` or `acceptance` array, which removes it from the
fast tier by construction. Raising the budget, or deleting the file's baseline
entry, is not an exemption.

Re-measuring is a maintenance job, never part of an ordinary run:
`bash scripts/capture-bats-timing.sh -j 4` writes the per-test and per-file
baseline, then `bash scripts/update-bats-tiers.sh <baseline.json>` regenerates
the manifest from it.

Two things that make these tests disproportionately expensive, both measured in
this repo:

- Heavy e2e files saturate the machine and inflate *every other test's* wall
  clock. Files measured at 171s standalone were reported at 80 minutes inside a
  saturated run. Deleting six e2e files cut far more than their own runtime.
  Parallelism multiplies this: `bats -j N` runs N files each running N tests, so
  the effective concurrency is N*N. `run-bats.sh` passes
  `--no-parallelize-within-files` to cap it at N, and the timing capture refuses
  more than `-j 4`, because past that the numbers measure host contention rather
  than test cost.
- Coverage from a journey test is usually reachable more cheaply. Before
  writing one, ask which specific contract is only observable end to end, and
  test that contract directly.

If you believe a slow e2e test genuinely belongs in the default tier, say so
explicitly and give the reason. Do not let it drift in by default.
