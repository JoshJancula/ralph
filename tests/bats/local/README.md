# Local smoke harness
These specs exercise the real runtime CLIs (Cursor, Claude, Codex) from the same host as the runner. Because they reach across the network or expect installed binaries, **CI does not run this directory**; operators invoke it manually when verifying runtime updates.

## Running the smoke tests
```
bats tests/bats/local/integration-smoke.bats
```
Add `bats-core` to your system (Homebrew, npm, or the upstream installer) before running this command.

## Selecting runtimes
- `RALPH_E2E_RUNTIMES` (comma-separated list) chooses which runtimes to include. If it is unset or empty, the harness starts with `cursor,claude,codex`.
- `RALPH_E2E_SKIP` removes runtimes from that include list. The precedence is “include first, then subtract skips” so you can start with a shortlist and still omit individual binaries.

### Examples
- Run all available runtimes (default behavior):
  ```
  bats tests/bats/local/integration-smoke.bats
  ```
- Run Claude only:
  ```
  RALPH_E2E_RUNTIMES=claude bats tests/bats/local/integration-smoke.bats
  ```
- Skip Codex while exercising the other runtimes:
  ```
  RALPH_E2E_SKIP=codex bats tests/bats/local/integration-smoke.bats
  ```
- Combine include and skip to focus on Cursor despite a broader set:
  ```
  RALPH_E2E_RUNTIMES=cursor,claude RALPH_E2E_SKIP=claude bats tests/bats/local/integration-smoke.bats
  ```

## Expected skips
Each `@test` calls `require_runtime` before executing and uses `skip` to avoid failure when its runtime is not enabled.
