# Cluster 7: Skills

Source cookbooks reviewed (2: custom skills development + skills intro;
financial-applications demo skipped as domain-specific). These map onto Ralph's
agent/rule/skill model defined in canonical frontmatter
(`bundle/.ralph/agents/<id>.md` and `agents/`), synced to runtime assets by
`scripts/sync-runtime-assets.sh` (see `.claude/rules/agent-dual-file-sync.md` and
`.claude/rules/bundle-vs-root.md`).

How Ralph handles this today: an agent is a canonical markdown file with YAML
frontmatter (`description`, `models`, `rules`, `skills`, `output_artifacts`) plus
an instruction body. Rules and skills are referenced by the frontmatter and
generated into each runtime's native format. So Ralph already has a
package-of-expertise abstraction --- but it loads the full instruction body up
front, with no progressive disclosure.

---

### Introduction to Claude Skills  (Oct 2025, relevance: med)
URL: https://platform.claude.com/cookbook/skills-notebooks-01-skills-introduction
What it teaches: A Skill is a higher-level abstraction than a tool --- a package
of instructions + code + resources Claude discovers and loads dynamically. The
core mechanism is **progressive disclosure**: Tier 1 metadata (name +
description, always visible, ~minimal tokens), Tier 2 full instructions (loaded
only when the skill is judged relevant, ~5k tokens), Tier 3 resources/scripts
(loaded on demand during execution). Many skills can be offered for near-zero
cost until actually used. Native skills require the code-execution tool +
`skills-2025-10-02` beta.
Ralph today: Ralph's agents/rules/skills are loaded as whole instruction bodies
when an agent runs --- there is no metadata-first, load-when-relevant tier. Every
referenced rule's full text enters context regardless of whether the todo needs
it.
Opportunity: Adopt progressive disclosure as a *context-cost* technique for
Ralph's own rule/skill loading. Inject only each rule's `description` (Tier 1) by
default, and pull the full body (Tier 2) into context only when the todo/stage is
relevant --- a judgment Ralph can make cheaply with its existing BM25 ranker over
rule descriptions vs the todo text. This is runtime-agnostic and directly attacks
context bloat (the same concern behind result windowing and compaction).
Runtime mapping: Shared layer (how Ralph assembles agent/rule/skill context for
every runtime). Runtime-agnostic.
Effort / risk: M, medium (loader change + relevance scoring; Bats tests; must
preserve the dual-file-sync contract).

### Building custom Skills for Claude  (Oct 2025, relevance: high)
URL: https://platform.claude.com/cookbook/skills-notebooks-03-skills-custom-development
What it teaches: Skill = a directory with a required `SKILL.md` (YAML
frontmatter: `name` lowercase-hyphen <=64 chars, `description` <=1024 chars) +
optional extra `.md` docs + `scripts/` + `resources/`. Keep instructions under
~5k tokens. Skills are versioned, composable (combine custom + Anthropic skills
in one request), and privacy-preserving. Lazy-loading keeps cost down.
Ralph today: This is almost exactly Ralph's agent model --- canonical `.md` +
frontmatter (`name` already constrained to lowercase-hyphens by the
agent-dual-file-sync rule) + referenced rules/skills + `output_artifacts`. Ralph
even has a scaffolder (`bash .ralph/new-agent.sh`). The gaps vs the Skill spec:
no bundled `scripts/`+`resources/` directory convention, no explicit versioning,
and the runtime-native generation is bespoke per runtime rather than a single
portable package format.
Opportunity: Two ideas. (1) Align Ralph's agent/skill package layout with the
SKILL.md convention (frontmatter limits, optional `scripts/`/`resources/`) so a
Ralph skill is portable --- on the Claude path it could be emitted directly as a
native Skill; on other runtimes it generates as today. (2) Add lightweight
versioning to the canonical frontmatter so skills/agents can be rolled back ---
which connects to the managed-agents "prompt versioning and rollback" pattern
(not in this cluster's deep-read set but adjacent). Keep the dual-file-sync
contract: edit canonical, regenerate, never hand-edit generated files.
Runtime mapping: Package format alignment = shared layer; native Skill emission =
Claude-only enhancement. Runtime-agnostic core.
Effort / risk: M, medium (frontmatter + layout convention + sync changes; tests).

---

## Cluster takeaways for the backlog

1. **Progressive disclosure for rule/skill loading.** Default to Tier-1
   descriptions; pull full bodies into context only when relevant (score with
   existing BM25). Directly cuts context bloat for every runtime. Source: skills
   intro.
2. **Align agent/skill packages with the SKILL.md convention** (frontmatter
   limits, optional `scripts/`/`resources/`, versioning); enables native Skill
   emission on Claude while keeping today's generation elsewhere. Source: custom
   skills development.
