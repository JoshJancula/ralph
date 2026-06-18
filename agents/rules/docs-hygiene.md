---
name: docs-hygiene
description: Documentation must describe current behavior only, use correct plan-format names, and keep RALPH_MODE opt-in.
globs: ["**/*"]
alwaysApply: true
---

# Documentation hygiene

## No deprecated references

- **Never mention deprecated or removed flags** in docs, comments, or examples.
- When a flag or feature is removed, delete every reference to it rather than adding a "deprecated" note.
- Descriptions of current behavior must match the current code. If the code changed, the doc must change.

## Plan-format naming

- In user-facing text, Ralph plan formats are **"classic"** (markdown checkboxes) and **"yaml"** (YAML frontmatter).
- **Do not** use removed format tokens (`structured`, `pipeline`, `standard`, `cursor`) as current syntax in docs or examples. Older tokens remain accepted as silent aliases in the CLI; mention that only when documenting backward compatibility.
- Example: "The classic format uses free-form Markdown checkboxes; the yaml format adds YAML frontmatter."

## RALPH_MODE examples

- Any example that includes `RALPH_MODE` must treat it as **opt-in**.
- The default in examples should be the absence of the variable, or an explicit `RALPH_MODE=no` or unset value, unless the example is specifically about enabling a mode.
- Do not write examples that imply `RALPH_MODE` is on by default.

## Editing generated docs

- When updating docs that describe generated files, update the canonical source first, then regenerate the downstream copies.
- Never hand-edit a generated file and leave the canonical source stale.
