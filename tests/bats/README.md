## Bats harness

This directory contains the minimal Bats harness that will exercise the shared bash helpers introduced for Ralph. Keep the layout flat under `tests/bats/` so the standard `bats tests/bats/*.bats` command can iterate over every specification file.

### Layout

- `tests/bats/*.bats`: Bats test files. Each one should run quickly, source any helpers needed for the script under test, and assert behavior with `run` and status/body checks.
- `tests/bats/helper/`: Optional helper scripts, e.g. `load-lib.bash`, that emit `RALPH_LIB_ROOT` or sourceable paths so tests can include library files without duplicating logic. Export `RALPH_LIB_ROOT` or set relative paths before sourcing so Bats can load `../../.ralph/bash-lib`.

### Installing Bats

Install a Bats runtime before running the harness:

- `brew install bats-core` (macOS, uses Homebrew and keeps up with `bats-core` releases)
- `npm install -g bats` (cross-platform, ships the same CLI)
- clone `https://github.com/bats-core/bats-core` and run `./install.sh /usr/local` if you need a vendored copy

After installing, verify `which bats` points to the expected binary and `bats --version` reports `bats-core`.

### Running the harness

```bash
bats tests/bats/*.bats
```

This command runs every spec in the `tests/bats` directory (including `tests/bats/smoke.bats`). Stub tests are acceptable until the bash helpers are refactored into libraries.

For operator-only runtime smoke tests that reach out to `cursor`, `claude`, or `codex`, see `tests/bats/local/README.md`. Those specs live under `tests/bats/local/` and are not executed by the default GitHub Actions harness.
