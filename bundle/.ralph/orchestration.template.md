# Orchestration plan template

This document explains how to create an **orchestration plan** so the Ralph
runners can execute multiple agents in sequence. Use **`.ralph/orchestrator.sh`**
with a single JSON `.orch.json` file. Set each stage's `"runtime"` to `cursor`,
`claude`, or `codex` to run that stage via `.ralph/run-plan.sh --runtime <name> --plan <stage-plan-path>` (the orchestrator supplies `--plan` from each stage in the JSON).

Copy the JSON template to `my-feature.orch.json` at the repository root,
adjust the stage plan paths to point to your docs (e.g., `docs/orchestration-plans/my-feature-01-research.plan.md`), and then run one of the orchestrators:

```bash
.ralph/orchestrator.sh my-feature.orch.json
```

See `.ralph-workspace/artifacts/README.md` for the required sections inside each handoff
file. Stage plans should be kept in version control (e.g., under `docs/orchestration-plans/`)
since `.ralph-workspace/` is git-ignored and only contains generated outputs.

---

## Stages and explicit deliverables

Use the typical order: **research**, **architect**, **implementation**, **code-review**, **qa**.
Each stage should leave a concrete artifact so the next agent (or a human) can
continue without guessing.

| Order | Agent ID (`config.json` folder) | After this step, expect |
|-------|----------------------------------|-------------------------|
| 1 | `research` | `.ralph-workspace/artifacts/{{ARTIFACT_NS}}/research.md` |
| 2 | `architect` | `.ralph-workspace/artifacts/{{ARTIFACT_NS}}/architecture.md` |
| 3 | `implementation` | `.ralph-workspace/artifacts/{{ARTIFACT_NS}}/implementation-handoff.md` |

Deliverables are enforced when you list them on the orchestration line or when
the agent `config.json` declares `output_artifacts`. Paths are repo-relative
unless absolute.

---

## Line formats

- **JSON stages** (`.ralph/orchestrator.sh`): each stage is an entry in
  the `stages` array and should include the agent ID, plan path, and optionally
  any `artifacts` or `outputArtifacts` that must exist after the stage completes.
  (`planTemplate` points to `.ralph/plan.template` unless you override it
  per-stage.)

`PATH_TO_STAGE_PLAN` is the Ralph task plan (markdown with `- [ ]` TODOs). Use one
small plan per stage, for example under `docs/orchestration-plans/` so plans stay in version control.

---

## Per-stage task plans

Each stage plan should tell the agent exactly one slice of work and mention the
handoff file to write:

1. **Research stage** – deliver `.ralph-workspace/artifacts/{{ARTIFACT_NS}}/research.md`
   with summary, findings, decisions, and next steps.
2. **Architect stage** – read the research artifact; deliver
   `.ralph-workspace/artifacts/{{ARTIFACT_NS}}/architecture.md`.
3. **Implementation stage** – read the architecture artifact; deliver code plus
   `.ralph-workspace/artifacts/{{ARTIFACT_NS}}/implementation-handoff.md`.

---

## Example pipelines

JSON example (see `dashboard.orch.json` at the repository root as a complete example):

```json
{
  "name": "my-feature-pipeline",
  "namespace": "my-feature",
  "stages": [
    {
      "id": "research",
      "agent": "research",
      "runtime": "cursor",
      "plan": "docs/orchestration-plans/my-feature-01-research.plan.md",
      "artifacts": [
        {
          "path": ".ralph-workspace/artifacts/{{ARTIFACT_NS}}/research.md",
          "required": true
        }
      ]
    }
  ]
}
```

---

## Checklist before running

- [ ] Each stage plan exists and contains checkable TODOs (`- [ ]`).
- [ ] Agent IDs match directories under `.cursor/agents/`, `.claude/agents/`, or `.codex/agents/`.
- [ ] Deliverables line up with `.ralph-workspace/artifacts/README.md`.
- [ ] Run from the repository root so repo-relative paths resolve.
