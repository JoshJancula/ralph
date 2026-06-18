## Python unit tests

This directory also contains Python unit tests under `tests/python/` for pure helper logic in the Ralph framework. These tests use only the Python standard library (`unittest`) and require no third-party dependencies.

### Running Python unit tests

```bash
# Run the full Python unit test suite
bash scripts/run-python-unit-tests.sh

# Run with verbose output
bash scripts/run-python-unit-tests.sh -v

# Run with fail-fast (stop on first failure)
bash scripts/run-python-unit-tests.sh -f

# Run tests matching a specific pattern
bash scripts/run-python-unit-tests.sh -v -k token_estimate

# Show help
bash scripts/run-python-unit-tests.sh --help
```

The Python unit tests cover pure helper logic in `bundle/.ralph/python/` such as:
- Token estimation utilities
- Tool call classification
- Shell command registry and safe rewrite rules
- MCP proxy search ranking
- Compactor DSL rule parsing
- Workspace registry management

## Bats harness

This directory contains the Bats harness for Ralph. Tests are grouped by subsystem under `tests/bats/`, with agent configuration validation tests organized under `tests/bats/agent-config/`.

### Layout

- `tests/bats/*/*.bats` plus selected top-level `tests/bats/*.bats`: Bats test files grouped by subsystem.
- `tests/bats/smoke-core.bats`: Consolidated MCP, tool-access, overlay, and proxy smokes (replaces the former extended-tier matrices).
- `tests/bats/agent-config/*.bats`: Agent configuration validation tests (schema, artifacts, downstream stages).
- `tests/bats/helper/`: Shared helpers (`load-lib.bash`, etc.).
- `tests/bats/local/`: Operator-only runtime smoke tests (real CLIs). Not run by CI.

### Installing Bats

- `brew install bats-core` (macOS)
- `npm install -g bats` (cross-platform)
- clone `https://github.com/bats-core/bats-core` and run `./install.sh /usr/local`

For parallel execution, install GNU `parallel` or `rush`. The `-j` flag requires one of them.

### Running the suite

```bash
# Full suite with fixtures and auto-detected parallelism
bash scripts/run-bats.sh

# Explicit parallelism
bash scripts/run-bats.sh -j 8

# List files in the suite
bash scripts/run-bats.sh --list-suite

# CI (see .github/workflows/bats.yml)
bash scripts/run-bats.sh -j 4
```

`bash scripts/run-bats-extended.sh` is a deprecated alias for `run-bats.sh` (the extended tier was removed).

### Running specific files

```bash
bash scripts/run-bats.sh tests/bats/smoke-core.bats
bash scripts/run-bats.sh -j 4 tests/bats/mcp/mcp-setup.bats tests/bats/orchestrator/orchestrator.bats
bin/bats -T tests/bats/run-plan/run-plan-unified.bats
```

### Timing capture

```bash
bash scripts/capture-bats-timing.sh
bash scripts/capture-bats-timing.sh -j 8
```

Output: `.ralph-workspace/logs/bats-timing/runs/<timestamp>/` with symlinks at `latest.json` and `latest.txt`.

### Parallelism

| Condition | Behavior |
| --- | --- |
| `-j N` given, `parallel` or `rush` on PATH | N parallel workers |
| No `-j`, parallel runner available | `min(8, ncpus)` workers |
| No parallel runner | Serial execution |

CI installs GNU `parallel` before `bash scripts/run-bats.sh -j 4`.

### Speedups

`tests/bats/helper/load-lib.bash` sets `RALPH_PLAN_AGENT_POLL_INTERVAL=0.1` to shorten run-plan polling in tests.

### Local / operator-only tests

See `tests/bats/local/README.md`. Not executed by the automated suite.

## Test coverage split

| Test type | Scope | Location | Framework |
| --- | --- | --- | --- |
| **Python unit tests** | Pure helper logic | `tests/python/` | `unittest` (stdlib) |
| **Bats integration tests** | Shell CLI, orchestration, filesystem | `tests/bats/` | Bats |

Use Python unit tests for algorithmic logic (token estimates, DSL parsing, classification). Use Bats for shell scripts, plan execution, and integration paths that need subprocesses.

Both suites run in CI (`.github/workflows/bats.yml`): Python first, then Bats.
