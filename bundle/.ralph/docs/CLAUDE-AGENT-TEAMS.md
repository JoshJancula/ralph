# Claude Code agent teams with Ralph

This guide explains how to use [Claude Code agent teams](https://code.claude.com/docs/en/agent-teams) together with the Ralph plan-driven workflow: spawning teammates for parallel tasks, aligning with Ralph plans and artifacts, and when to use agent teams versus the Ralph orchestrator or subagents.

## What are agent teams?

Agent teams let you coordinate **multiple Claude Code instances** in a single workflow. One session is the **team lead**; it creates the team, spawns **teammates**, and coordinates work. Teammates run in separate context windows, share a **task list**, and can **message each other** directly (unlike subagents, which only report back to the caller).

| Concept | Description |
|--------|--------------|
| **Team lead** | The main Claude Code session that creates the team, assigns tasks, and synthesizes results |
| **Teammates** | Separate Claude Code instances, each with its own context; they claim tasks and communicate via a mailbox |
| **Task list** | Shared list of work items (pending, in progress, completed) with optional dependencies |
| **Subagents (contrast)** | Spawned by one agent, do work, report results back only to that agent; no direct teammate-to-teammate messaging |

Agent teams are **experimental** and must be enabled (see [Enable agent teams](#enable-agent-teams)). They require Claude Code v2.1.32 or later (`claude --version`).

## Enable agent teams

Set the environment variable in your Claude Code [settings](https://code.claude.com/docs/en/settings). In the project `.claude/settings.json`:

```json
{
  "env": {
    "CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS": "1"
  }
}
```

Or in your shell before starting Claude Code:

```bash
export CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1
```

After enabling, you can ask Claude to create an agent team in natural language; it will spawn teammates and manage the shared task list.

## Using agent teams with Ralph

Ralph provides **plan-driven runs** (one markdown plan with `- [ ]` / `- [x]` TODOs, driven by `.ralph/run-plan.sh` with required **`--plan`**) and **multi-stage orchestration** (`.ralph/orchestrator.sh` with JSON stages and artifact handoffs). Agent teams add **parallel, multi-agent work inside a single Claude Code session**, with a shared task list and direct communication between teammates.

### How they fit together

- **Ralph plan / run-plan**: One agent (or one human) works through a single plan file; the runner loops until all TODOs are done. Good for sequential work and clear checkpoints.
- **Ralph orchestrator**: Runs multiple stages (e.g. research, then architecture, then implementation), each stage often a different runtime or agent, with required artifacts between stages. Good for pipelines that must pass strict gates.
- **Claude agent teams**: One lead plus several teammates working in parallel, with a shared task list and messaging. Good when parallel exploration or multi-perspective review adds value and you want teammates to discuss or challenge each other.

You can combine them: for example, the **lead** runs or follows a Ralph plan and **spawns teammates** to handle specific tasks or perspectives in parallel, then synthesizes results and updates the plan or artifacts.

### Pattern 1: Lead runs a Ralph plan and spawns teammates for parallel tasks

1. You (or the lead) have a Ralph plan (e.g. `PLAN.md` or a stage plan under `.ralph-workspace/orchestration-plans/`).
2. Ask Claude to create an agent team and break the plan into parallel tasks. For example:

   ```text
   I'm using the Ralph plan in PLAN.md. Create an agent team that works through it in parallel:
   - One teammate focuses on the research TODOs and writes findings to .ralph-workspace/artifacts/{{ARTIFACT_NS}}/research.md
   - One teammate focuses on implementation TODOs and runs the verification commands (lint/test) from the plan
   - One teammate does security review and documents issues in .ralph-workspace/artifacts/{{ARTIFACT_NS}}/security-review.md
   ```

3. The lead creates the team, populates the shared task list (aligned with plan TODOs or sub-goals), and assigns or lets teammates self-claim. Teammates write to Ralph-style artifact paths so the lead (or a later orchestrator stage) can consume them.
4. When the team is done, the lead can mark plan items complete, run the Ralph runner to continue the loop, or hand off to the next orchestrator stage.

### Pattern 2: Ralph agent roles as teammate roles

Ralph ships prebuilt agents (e.g. `research`, `architect`, `implementation`, `code-review`, `qa`, `security`) under `.claude/agents/`. Each has a `config.json` for Ralph tooling and a peer `.md` file with YAML frontmatter for Claude Code. You can spawn teammates that mirror these roles:

```text
Create an agent team to review PR #142. Spawn three teammates:
- One focused on security (use the same scope as .claude/agents/security): token handling, session management, input validation
- One focused on performance impact
- One focused on test coverage

Have them each write findings to .ralph-workspace/artifacts/pr-142/review-<focus>.md and then discuss to produce a single .ralph-workspace/artifacts/pr-142/synthesis.md.
```

Give each teammate enough context in the spawn prompt: paths to relevant files, artifact locations (e.g. `.ralph-workspace/artifacts/{{ARTIFACT_NS}}/...`), and any Ralph conventions (e.g. no emoji, repo-context skill). Teammates load project context (e.g. CLAUDE.md, MCP, skills) but not the lead’s conversation history, so include task-specific details in the prompt.

### Pattern 3: Parallel research or competing hypotheses

For exploration or debugging, use the team so that teammates can challenge each other (see [code.claude.com agent teams – use case examples](https://code.claude.com/docs/en/agent-teams#use-case-examples)):

```text
We need to implement the notification feature described in .ralph-workspace/orchestration-plans/notifications-01-research.plan.md. Create an agent team: one teammate researches backend options, one researches frontend patterns, one plays devil’s advocate and pokes holes in both. They should message each other and agree on .ralph-workspace/artifacts/notifications/research.md before we move to the architecture stage.
```

The lead can then run the next Ralph stage (e.g. architecture) using that artifact, via `.ralph/run-plan.sh --plan <path> ...` or the orchestrator (which passes `--plan` per stage).

### Artifacts and handoffs

- **Ralph artifact paths**: Use `.ralph-workspace/artifacts/{{ARTIFACT_NS}}/...` (or a fixed namespace) so outputs are in the same place the orchestrator and run-plan expect. Replace `{{ARTIFACT_NS}}` with your pipeline or plan namespace (e.g. `notifications`, `pr-142`).
- **Required artifacts**: If a teammate must produce a file for a later stage, say so in the spawn prompt and, if you use the orchestrator, ensure the next stage’s `inputArtifacts` / `artifacts` point to those paths.
- **Cleanup**: After a run, use `.ralph/cleanup-plan.sh <artifact-namespace>` to remove logs and artifacts for that namespace if you want a fresh run.

## When to use which

| Use case | Prefer |
|----------|--------|
| Sequential stages with strict artifact gates (research -> architecture -> implementation) | Ralph orchestrator + run-plan per stage |
| Single plan, one agent (or human) doing all TODOs | Ralph run-plan with one agent |
| Parallel exploration, multi-perspective review, or debate between agents | Claude agent teams |
| Quick delegated subtask; only the result matters | Claude (or Cursor/Codex) subagents |

Agent teams use more tokens than a single session (each teammate has its own context). Use them when parallel work and inter-teammate communication clearly add value.

## Similar workflows with Cursor and Codex

While Claude Code agent teams provide native multi-agent coordination within a single Claude instance, Cursor and Codex offer alternative approaches for parallel, coordinated workflows using subagents, agents, and multi-stage orchestration.

### Cursor subagents

Cursor supports **subagents** that run in parallel with independent context. Unlike Claude Code teammates, Cursor subagents do not have a shared task list or direct messaging, but you can coordinate work through:

- **Result aggregation**: Launch multiple subagents with `Task` tool, wait for results, then synthesize in your main session.
- **Artifact handoffs**: Have each subagent write to Ralph-style artifact paths (e.g. `.ralph-workspace/artifacts/<namespace>/`) so results are discoverable and can feed into later stages.
- **Sequential orchestration**: Use `.ralph/orchestrator.sh` to run Cursor stages in sequence, with each stage as a separate subagent or agent run.

Example: three Cursor subagents in parallel (security review, performance analysis, test coverage):

```bash
# Pseudocode: launch three subagents concurrently
Task(description="Security review", prompt="Review PR #142 for token handling, session management, input validation. Write findings to .ralph-workspace/artifacts/pr-142/review-security.md")
Task(description="Performance analysis", prompt="Profile PR #142 for performance impact. Write findings to .ralph-workspace/artifacts/pr-142/review-performance.md")
Task(description="Test coverage analysis", prompt="Check test coverage for PR #142. Write findings to .ralph-workspace/artifacts/pr-142/review-coverage.md")

# Wait for all to complete, then synthesize results in the main session
```

**Pros**: No special configuration needed; each subagent loads project context (CLAUDE.md, skills, MCP) independently; results written to shared artifact paths.

**Cons**: No direct inter-agent messaging or shared task list; each subagent run uses separate tokens/context; coordination is manual (you orchestrate the results).

### Cursor agents as team roles

Cursor's agent system (via `.cursor/agents/`) mirrors Ralph's multi-role architecture. You can create Cursor agents analogous to Ralph roles (architect, implementation, code-review, security, qa, research) and:

- Spawn them as subagents for focused work on specific tasks.
- Chain them via the orchestrator: research agent produces artifact -> architect agent consumes it -> implementation agent consumes architecture.
- Have each agent load role-specific skills and rules (e.g. security agent loads security-review skills).

This is conceptually similar to Claude Code agent teams but uses separate agent **runs** instead of concurrent teammates within a single session.

### Codex agents and orchestration

Codex (the Cursor/Codex plugin for VS Code and other IDEs) supports **agents** defined in `.codex/agents/*.toml`. Codex agents can:

- Be invoked from a PLAN.md via the Codex CLI or IDE integration.
- Write artifacts following Ralph conventions (`.ralph-workspace/artifacts/...`).
- Run in sequence via `.ralph/orchestrator.sh`, handing off artifacts between stages.

Codex also supports **skills** (`.codex/skills/`) that can be shared across agents, enabling consistent practices across your team.

Example `.codex/orchestrator.sh` stage using Codex agents:

```toml
[[stages]]
name = "research"
type = "codex_agent"
config = { agent = "research", plan = ".ralph-workspace/orchestration-plans/notifications/notifications-01-research.plan.md" }
outputArtifacts = ["notifications/research.md"]

[[stages]]
name = "architect"
type = "codex_agent"
config = { agent = "architect", inputArtifacts = ["notifications/research.md"] }
outputArtifacts = ["notifications/architecture.md"]
```

**Pros**: Declarative multi-stage pipelines; artifact visibility and traceability; works across different IDEs and contexts.

**Cons**: Stages run sequentially (no native parallel work within orchestrator); less real-time inter-agent communication than Claude Code teammates.

### Comparison: Claude Code teams vs. Cursor/Codex orchestration

| Aspect | Claude Code Teams | Cursor Subagents | Codex Orchestrator |
|--------|-------------------|------------------|-------------------|
| **Parallel work** | Yes; teammates work concurrently | Yes; subagents can run in parallel | No; stages are sequential |
| **Shared task list** | Yes; teammates claim tasks | No; manual coordination | No; orchestrator controls flow |
| **Inter-agent messaging** | Yes; teammates message each other | No; only result aggregation | No; handoff via artifacts |
| **Context per agent** | Separate context per teammate | Separate context per subagent | Separate context per stage |
| **Token efficiency** | Higher (multiple contexts) | Higher (multiple contexts) | Lower (stages run one at a time, but less context duplication) |
| **Setup complexity** | Enable flag + natural language spawn | Use Task tool; no special setup | Define .toml stages and agent configs |
| **Best for** | Parallel exploration, multi-perspective debate, parallel review | Quick delegated tasks, simple result aggregation | Strict pipelines with clear stage gates and artifact handoffs |

### Practical workflow: mixing Claude Code and Cursor/Codex

You can also combine approaches in a single project:

1. **Use Claude Code teams for exploratory work**: Research, design options, debate trade-offs in parallel with teammates.
2. **Export team results to Ralph artifacts**: Teammates write findings to `.ralph-workspace/artifacts/<namespace>/...`.
3. **Hand off to Cursor/Codex orchestrator for implementation**: Run multi-stage orchestrator starting with the Claude Code teams' output, using Cursor or Codex agents for subsequent stages (architecture, implementation, testing).
4. **Use Ralph run-plan for final integration and verification**: A single agent or human works through the final checklist.

This hybrid approach leverages Claude Code's strength in parallel exploration and Cursor/Codex's strength in structured, sequential pipelines and IDE integration.

## Best practices

1. **Enable in settings**: Set `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1` in `.claude/settings.json` or your environment so you don’t have to remember it each time.
2. **Align tasks with the plan**: If the lead is driving from a Ralph plan, make the shared task list map to plan TODOs or clear sub-goals so completion is easy to reconcile.
3. **Give teammates context**: In the spawn prompt, include the plan path, artifact paths (e.g. `.ralph-workspace/artifacts/<namespace>/...`), and any Ralph rules/skills (e.g. no emoji, repo-context). Mention which files or areas each teammate owns to avoid conflicts.
4. **Avoid file conflicts**: Assign different files or modules to different teammates so two agents don’t edit the same file and overwrite each other.
5. **Shut down and clean up**: Ask the lead to shut down teammates when done, then “Clean up the team” so the shared team resources are removed. Use the lead for cleanup; teammates should not run cleanup themselves

## References

- **Claude Code agent teams**: [Orchestrate teams of Claude Code sessions](https://code.claude.com/docs/en/agent-teams) (enable, control, best practices, limitations)
- **Ralph workflow**: [AGENT-WORKFLOW.md](AGENT-WORKFLOW.md) (plan-first loop, orchestrator, runners, subagents/teams overview)
- **Ralph MCP**: [MCP.md](MCP.md) (Ralph MCP server and workspace config)
- **Claude agents in your workspace**: `.claude/agents/README.md` (dual-purpose config: `config.json` for Ralph, `.md` for Claude Code)
