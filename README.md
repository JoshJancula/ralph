# Ralph

Ralph turns an AI coding assistant into a repeatable development loop. Give it a
small checklist or a reusable workflow; Ralph keeps the state, runs the selected
assistant, verifies progress, and leaves an audit trail.

It works with Cursor, Claude, Codex, OpenCode, and Antigravity.

## Choose your path

| You have | Use | Command |
| --- | --- | --- |
| A concrete checklist | A **leaf plan** | `ralph run --plan PLAN.md` |
| A task that still needs investigation or planning | A **workflow** | `ralph workflow start feature-delivery --task "Add CSV export"` |
| A finished leaf plan that needs review and QA | The **plan-delivery workflow** | `ralph workflow start plan-delivery --plan PLAN.md` |

A leaf plan is the smallest useful Ralph unit: one file, one TODO loop. A
workflow coordinates several attributable plan runs and supervisor checks, such
as review, approval, integration, and QA.

## Install

Install once for your user account:

```bash
git clone https://github.com/JoshJancula/ralph.git /tmp/ralph
/tmp/ralph/install.sh --global
```

Or vendor Ralph inside a project:

```bash
git subtree add --prefix vendor/ralph https://github.com/JoshJancula/ralph.git main --squash
./vendor/ralph/install.sh
```

The installer can add Ralph's shared scripts plus native configuration for
Cursor, Claude, Codex, OpenCode, and Antigravity. Existing runtime configuration
is preserved. See [Installation](docs/INSTALL.md) for partial installs, updates,
plugins, and removal.

## Five-minute tour

```bash
# See the bundled workflows
ralph workflow list

# Let Ralph investigate, plan, implement, review, and verify a task
ralph workflow start feature-delivery --task "Add CSV export"

# Reattach later
ralph workflow runs
ralph workflow watch <run-id>

# Or create and run a one-off checklist
ralph create plan --format classic
ralph run --plan PLAN.md
```

Workflow starts attach a live terminal view when a TTY is available. Press `q`
to detach without cancelling the run. If Ralph needs an approval or answer, it
persists the request; inspect it with `ralph workflow actions list <run-id>`.

Run state lives under `.ralph-workspace/`:

```text
.ralph-workspace/
  logs/             assistant and supervisor logs
  artifacts/        plans, handoffs, verdicts, and other outputs
  sessions/         leaf-plan session state
  workflow-runs/    durable workflow registry
```

## What Ralph guarantees

- A completed checkbox needs verification; assistant prose alone is not proof.
- Workflow inputs are frozen. Execution progresses on durable control copies.
- Review findings remain open until an evaluator explicitly closes them.
- Approval and input decisions are supervisor records with run and attempt
  identity.
- Runtime-native agents, subagents, teams, skills, hooks, and permissions remain
  owned by the selected runtime.

## Documentation

Start with the page that matches the job:

| Guide | Use it for |
| --- | --- |
| [Leaf plans](docs/AGENT-WORKFLOW.md) | Writing and running one checklist, human input, resume, and outputs |
| [Workflows](docs/WORKFLOWS.md) | Choosing, running, authoring, approving, and recovering multi-stage workflows |
| [Installation](docs/INSTALL.md) | Global and project installs, setup, plugins, and uninstall |
| [Tooling](docs/TOOLING.md) | Ralph modes, output compaction, hooks, and runtime adapters |
| [Environment](docs/ENVIRONMENT.md) | Complete flags and environment-variable reference |
| [MCP](docs/MCP.md) | MCP server and host wiring |
| [Security](docs/SECURITY.md) | Trust boundaries, sandboxing, and killswitch controls |
| [Benchmarks](docs/BENCHMARKS.md) | Latest measured token and tool-output results |

The [documentation index](docs/README.md) maps the remaining reference pages.
AI assistants working on Ralph itself should follow [AGENTS.md](AGENTS.md).

## Dashboard

The optional dashboard shows projects, plans, workflow runs, artifacts, and
operator actions:

```bash
cd .ralph/ralph-dashboard
npm ci
npm run build
npm start
```

It listens on `http://127.0.0.1:8123` by default.

## Safety and cost

Ralph can run many assistant turns. Review the [security guide](docs/SECURITY.md),
keep TODOs scoped, and monitor provider billing. `ralph safety status` shows the
active safety configuration. `ralph benchmark` summarizes recorded usage and
tool-output optimization for completed plan runs.

## License

MIT. See [LICENSE](LICENSE).

If Ralph helps your work, consider [starring the project](https://github.com/JoshJancula/ralph).

<img src="./public/ralph-coding.jpeg" alt="Ralph coding" />
