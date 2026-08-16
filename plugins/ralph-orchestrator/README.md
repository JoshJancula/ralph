# Ralph orchestrator beta operator guide

`ralph-orchestrator` is a repository-hosted beta plugin package for Claude
Code, Codex, Cursor, OpenCode, and Antigravity. This package is version
`0.1.0-beta.1`. It is not GA, is not published to a marketplace, and does
not include a second Ralph execution engine. The host adapters call one
independently installed `ralph` CLI.

## Install from this repository

Keep the checkout at a stable path because the host plugin is loaded from the
checkout. From a shell:

```bash
git clone <repository-url> /path/to/ralph
cd /path/to/ralph
bash scripts/sync-plugin-assets.sh
bash ./install.sh --global
```

`sync-plugin-assets.sh` regenerates the five host packages under this
directory. `bash ./install.sh --global` installs the Ralph CLI and bundle for
use by projects; it is the engine installation required by the plugin. The
plugin itself does not silently install it. Before installing a generated
package into a host, choose the matching directory:

| Host | Package |
| --- | --- |
| Claude Code | [`claude/`](./claude) |
| Codex | [`codex/`](./codex) |
| Cursor | [`cursor/`](./cursor) |
| OpenCode | [`opencode/`](./opencode) |
| Antigravity | [`antigravity/`](./antigravity) |

Install the matching package with the host-native flow below. Replace
`/path/to/ralph` with the absolute checkout path.

Claude Code:

```bash
claude plugin marketplace add /path/to/ralph/plugins/ralph-orchestrator/claude
claude plugin install ralph-orchestrator@ralph-plugins
```

Codex:

```bash
codex plugin marketplace add /path/to/ralph/plugins/ralph-orchestrator
codex plugin add ralph-orchestrator@ralph-plugins
codex plugin list
```

Cursor currently loads repository-local packages by copying the real package
directory into its local plugin root. Do not use a symlink:

```bash
mkdir -p "$HOME/.cursor/plugins/local"
cp -R /path/to/ralph/plugins/ralph-orchestrator/cursor \
  "$HOME/.cursor/plugins/local/ralph-orchestrator"
```

Reload Cursor after copying. OpenCode discovers local project extensions from
`.opencode`; copy the generated module, skills, and agents into the target
project:

```bash
project=/absolute/path/to/project
package=/path/to/ralph/plugins/ralph-orchestrator/opencode
mkdir -p "$project/.opencode/plugins" "$project/.opencode/skills" "$project/.opencode/agents"
cp "$package/plugins/ralph-runtime-hooks.ts" "$project/.opencode/plugins/ralph-runtime-hooks.ts"
cp -R "$package/skills/." "$project/.opencode/skills/"
cp -R "$package/agents/." "$project/.opencode/agents/"
```

Antigravity has a native local-directory plugin installer:

```bash
agy plugin install /path/to/ralph/plugins/ralph-orchestrator/antigravity
agy plugin list
```

There is intentionally no cross-host installer. Keep each package intact so
its native manifest, skills, agents, shared gate, and host-specific files stay
together.

For a generated-package check without changing files, run:

```bash
bash scripts/sync-plugin-assets.sh --check
```

## First command: read-only diagnosis

After the host has loaded the package, invoke the `ralph-status` workflow
first. It performs a read-only compatibility probe. It does not install
anything, change runtime configuration, or execute a plan. The probe checks
the existing CLI help and `ralph --bundle-path` interfaces and reads the installed
`plugin-api-version` marker.

The `ralph-doctor` workflow is also read-only. It may inspect the bundle path,
graph status, agent list, and runtime directories after a successful probe.
The `ralph-agents` workflow lists the six shared profiles. These are workflow
names supplied by the host plugin, not additional Ralph CLI commands.

## Compatibility remediation

The plugin requires Ralph ABI `1`. The probe reports one of these outcomes:

| Outcome | Meaning | Action |
| --- | --- | --- |
| `usable` | The installed marker is `1`. | Continue. |
| `newer` | The marker is greater than `1`; required CLI verbs were checked from help. | Continue only after reviewing the warning. |
| `missing` | No `ralph` executable was found. | Review the printed repository install command and install Ralph. |
| `legacy` or `too-old` | The bundle-path interface or ABI marker is missing/old. | Upgrade with the repository's `install.sh --global`. |
| `incompatible` | The ABI marker is malformed, or a newer ABI omits a required command verb. | Do not execute; inspect the reported path/value or missing verbs and reinstall from the repository. |

The read-only workflows never run the installer. When remediation is offered,
review the exact command and destination first, then run the repository
command yourself or use the plugin's consented install path. Installation consent authorizes only installation; it never authorizes a plan run.

## Authoring and execution

The `ralph-plan`, `ralph-orchestrate`, and `ralph-graph` workflows author or
validate plans. They do not execute them. The `ralph-run` workflow is the only
executing workflow, and it must use the shared two-call gate.

First request a preview. Substitute absolute paths and the values selected for
this run:

```bash
bash /path/to/ralph/plugins/ralph-orchestrator/<host>/shared/ralph-plugin-exec.sh preview \
  --kind plan \
  --plan /absolute/path/to/PLAN.md \
  --runtime cursor \
  --agent implementation \
  --model '<exact model value>' \
  --workspace /absolute/path/to/project \
  --workspace-root /absolute/path/to/project/.ralph-workspace \
  --agent-workspace /absolute/path/to/project
```

The preview is read-only. It prints the normalized kind, absolute plan path,
project/state/agent roots, resolved runtime/agent/model, the shell-escaped
command that would run, and a SHA-256 `confirmationId`. Check every field and
copy the exact id. A plan execution command is `ralph run --plan ...`; a graph
run or resume is represented by the corresponding graph command in the
preview. Do not hand-edit the displayed command or id.

Immediately after reviewing the preview, make the separate execution call with
the same tuple:

```bash
bash /path/to/ralph/plugins/ralph-orchestrator/<host>/shared/ralph-plugin-exec.sh execute \
  --kind plan \
  --plan /absolute/path/to/PLAN.md \
  --runtime cursor \
  --agent implementation \
  --model '<exact model value>' \
  --workspace /absolute/path/to/project \
  --workspace-root /absolute/path/to/project/.ralph-workspace \
  --agent-workspace /absolute/path/to/project \
  --confirmation-id <id-from-preview> \
  --request 'Run this plan now'
```

The request must be a direct, current-user request. The gate recomputes the
tuple and rejects a stale or mismatched id. Execution requires a real operator
terminal and asks the operator to type the full confirmation id. Piped input
and `--yes` are rejected. If the host's tool shell is non-interactive, copy the
displayed execute command into your own terminal. Installation consent, a
quoted or hypothetical request, and an authoring request are not execution
consent.

## Removing legacy Ralph setup and rolling back

There is one removal path: the existing `ralph setup` command. Preview the
mutation set first:

```bash
ralph setup --runtime claude --runtime-dir /path/to/project/.claude --remove --all --dry-run
```

If the set is correct, repeat without `--dry-run`. Interactive removal asks
for confirmation. For a non-TTY removal, pass `--yes` only after reviewing the
dry-run output:

```bash
ralph setup --runtime claude --runtime-dir /path/to/project/.claude --remove --all --yes
```

Replace `claude` and `.claude` with the selected host's runtime directory.
Removal recognizes only Ralph-owned entries and byte-identical Ralph files;
modified or unrelated files are preserved and a refusal names the path. A
mutation journal is stored under
`.ralph-workspace/setup-journal/<operation-id>/`. If removal is interrupted or
fails, the journal restores entries in reverse order. Do not create a second
uninstaller or delete runtime configuration by hand. For a complete Ralph
installation removal, use the repository installer with
`--remove-installed` after its dry-run, following [`install.sh`](../../install.sh)
and [`docs/INSTALL.md`](../../docs/INSTALL.md).

## Supported host versions and beta limits

This is a beta qualification matrix, not a GA support promise:

| Host | Repository qualification |
| --- | --- |
| Claude Code | No host version is pinned in this repository; qualify the installed host before use. |
| Codex | No host version is pinned in this repository; qualify the installed host before use. |
| Cursor | No host version is pinned in this repository; qualify the installed host before use. |
| OpenCode | Contract target: CLI `1.3.17` and `@opencode-ai/plugin` `1.3.15`; generation fails closed if the local contract differs. |
| Antigravity | Flag contract was recorded against `agy 1.1.9`; a live `agy models` catalog check is still an operator prerequisite, and model values must be copied byte-for-byte. |

The installed Ralph compatibility contract is ABI `1`, independent of host
version. A newer ABI may produce a warning only when the required verbs are
present; it is not proof of host compatibility. Local tests and fixtures do
not replace authenticated host qualification, and this guide does not claim
GA.

## Troubleshooting

- `ralph` is missing: run the read-only workflow, confirm the printed
  repository path, then run `bash /path/to/ralph/install.sh --global`.
- The probe reports `legacy`, `too-old`, or a missing marker: reinstall from
  the same repository checkout and run the read-only workflow again.
- The probe reports `incompatible`: preserve the reported path and value for
  diagnosis; do not bypass the ABI check.
- A preview id is rejected: regenerate the preview immediately. Any changed
  path, root, runtime, agent, model, graph namespace, or run id changes the
  confirmation tuple.
- A headless execution stops for confirmation: copy the displayed execute
  command to an operator terminal and type the full confirmation id there.
  Installation consent cannot be reused for execution.
- Removal refuses a file: stop and inspect the named file. A modified
  Ralph-owned file is intentionally not overwritten; use the journal for
  rollback evidence.
- OpenCode or Antigravity fails contract validation: compare the pinned host
  contract and package files in the repository before changing versions.

For repository details, see the [main README](../../README.md),
[installation guide](../../docs/INSTALL.md), and
[`sync-plugin-assets.sh`](../../scripts/sync-plugin-assets.sh).
