# Orchestration plan template

This document explains how to create an **orchestration plan** so the Ralph
runners can execute multiple agents in sequence. Use **`.ralph/orchestrator.sh`**
with a single JSON `.orch.json` file. Set each stage's `"runtime"` to `cursor`,
`claude`, or `codex` to run that stage with the matching `run-plan.sh`.

Copy the JSON template to `.agents/orchestration-plans/my-feature.orch.json`,
adjust the stage plan paths, and then run one of the orchestrators:

```bash
.ralph/orchestrator.sh --orchestration .agents/orchestration-plans/my-feature.orch.json
```

See `.agents/artifacts/README.md` for the required sections inside each handoff
file.

---

## Stages and explicit deliverables

Use the typical order: **research**, **architect**, **implementation**, **code-review**, **qa**.
Each stage should leave a concrete artifact so the next agent (or a human) can
continue without guessing.

| Order | Agent ID (`config.json` folder) | After this step, expect |
|-------|----------------------------------|-------------------------|
| 1 | `research` | `.agents/artifacts/{{ARTIFACT_NS}}/research.md` |
| 2 | `architect` | `.agents/artifacts/{{ARTIFACT_NS}}/architecture.md` |
| 3 | `implementation` | `.agents/artifacts/{{ARTIFACT_NS}}/implementation-handoff.md` |

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
small plan per stage, for example under `.agents/orchestration-plans/`.

---

## Per-stage task plans

Each stage plan should tell the agent exactly one slice of work and mention the
handoff file to write:

1. **Research stage** – deliver `.agents/artifacts/{{ARTIFACT_NS}}/research.md`
   with summary, findings, decisions, and next steps.
2. **Architect stage** – read the research artifact; deliver
   `.agents/artifacts/{{ARTIFACT_NS}}/architecture.md`.
3. **Implementation stage** – read the architecture artifact; deliver code plus
   `.agents/artifacts/{{ARTIFACT_NS}}/implementation-handoff.md`.

---

## Example pipelines

JSON example (copy from `.ralph/orchestration.template.json` and edit):

```json
{
  "name": "my-feature-pipeline",
  "namespace": "my-feature",
  "stages": [
    {
      "id": "research",
      "agent": "research",
      "runtime": "cursor",
      "plan": ".agents/orchestration-plans/my-feature-01-research.plan.md",
      "artifacts": [
        {
          "path": ".agents/artifacts/{{ARTIFACT_NS}}/research.md",
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
- [ ] Deliverables line up with `.agents/artifacts/README.md`.
- [ ] Run from the repository root so repo-relative paths resolve.
