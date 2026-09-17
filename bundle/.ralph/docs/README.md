# Ralph documentation

Ralph has two main paths. Use a **leaf plan** when the work is already a concrete
checklist. Use a **workflow** when the work needs multiple stages, durable
handoffs, review, approval, integration, or independent QA.

```text
Concrete checklist    ->  ralph run --plan PLAN.md
Task or specification ->  ralph workflow start <id> --task|--plan ...
```

## Start here

| Goal | Guide |
| --- | --- |
| Run one checklist | [Leaf plans](AGENT-WORKFLOW.md) |
| Choose, run, or author a multi-stage process | [Workflows](WORKFLOWS.md) |
| Install or update Ralph | [Installation](INSTALL.md) |
| Understand trust boundaries | [Security](SECURITY.md) |

## Reference

| Page | What it contains |
| --- | --- |
| [Environment](ENVIRONMENT.md) | Flags, environment variables, model selection, session controls, and the three-root model |
| [Tooling](TOOLING.md) | Ralph modes, MCP proxy tools, compaction, hooks, and runtime adapters |
| [MCP](MCP.md) | MCP server setup, host wiring, and third-party MCP behavior |
| [Hooks](HOOKS.md) | Installed hook inventory and channel behavior |
| Benchmarks | Generated locally from recorded run telemetry with `ralph benchmark` |

The optional dashboard has its own [development and operation guide](../ralph-dashboard/README.md).
AI assistants changing Ralph itself should use [AGENTS.md](../AGENTS.md) as the
contract and open these operator pages only when needed.

## Commands you will use most

```bash
ralph create plan --format classic
ralph run --plan PLAN.md

ralph workflow list
ralph workflow show feature-delivery
ralph workflow start feature-delivery --task "Add CSV export"
ralph workflow start plan-delivery --plan PLAN.md
ralph workflow runs
ralph workflow watch <run-id>
ralph workflow actions list <run-id>
```

Open tasks use `- [ ]`; completed tasks use `- [x]`. Ralph ignores `- []`.
Logs and outputs live under `.ralph-workspace/logs/` and
`.ralph-workspace/artifacts/`.

## Three directories, three jobs

| Root | Default | Purpose |
| --- | --- | --- |
| Project root | current project | Ralph install and native runtime configuration |
| State root | `<project>/.ralph-workspace` | logs, artifacts, sessions, and workflow registry |
| Agent workspace | invoking directory | files the assistant may read and change |

Use `--workspace`, `--workspace-root`, and `--agent-workspace` when these are
different. The full contract is in [Environment](ENVIRONMENT.md#core-plan-runner-and-workspace).

## Benchmark report

`ralph benchmark` builds a report from completed plan summaries in the current
workspace. Use `--plan <key>` to publish a deliberate run instead of mixing
unrelated historical and fixture data.

```bash
ralph benchmark --plan <plan-key>
ralph benchmark --plan <plan-key> --write-doc
ralph benchmark --format json
```

The report separates provider-reported session usage from estimated tool-output
savings. Those numbers answer different questions and should not be combined.
