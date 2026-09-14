---
name: artifact-contract
description: Read stage inputs and produce stage outputs through the Ralph artifact tools. Use whenever a workflow stage consumes or produces artifacts. Artifacts are addressed by name; paths, namespaces, and schema validation are the harness's job, not yours.
---
<!-- GENERATED from bundle/.ralph/skills/artifact-contract/SKILL.md by scripts/sync-runtime-assets.sh - edit the canonical file -->

# Artifact contract

A workflow stage does not choose where its output goes. The orchestrator
publishes a contract naming what this stage may read and must produce, and the
`ralph_artifact_contract`, `ralph_read_artifact`, and `ralph_write_artifact`
tools are how you act on it.

## How to work a stage

1. Call `ralph_artifact_contract` before doing the stage's work. It tells you
   the artifacts you may read, the ones you must produce, and which of those
   have a schema.
2. Read inputs with `ralph_read_artifact`, by name.
3. Do the stage's actual work.
4. Produce each declared output with `ralph_write_artifact`, by name — `data`
   for a JSON artifact, `content` for a text one.

## What this means for you

- **Address artifacts by name, never by path.** The contract's names are the
  interface. Paths carry a per-run namespace that is not yours to construct,
  and they can change without any stage prompt changing.
- **Never write under `.ralph-workspace/artifacts/` directly.** A direct file
  write bypasses schema validation and is a policy violation. If you believe a
  stage needs an output that the contract does not list, that is a workflow
  authoring gap — say so in your stage summary rather than writing the file
  anyway.
- **A schema error is yours to fix.** When `ralph_write_artifact` rejects your
  content it reports the exact location, and *nothing is written*. Correct the
  content and call the tool again. Do not report the stage as blocked, and do
  not try to satisfy the schema by writing the file some other way.
- **Emit only the fields the schema defines.** Schemas reject unknown
  properties, so extra "helpful" fields fail the write.

## When a stage declares no contract

`ralph_artifact_contract` reports that no contract is published when the stage
declares no artifacts, or when you are not running under the orchestrator. That
is not an error to work around — such a stage simply has no artifacts to
produce, and its result belongs in your stage summary.
