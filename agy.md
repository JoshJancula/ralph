Setting up agents, skills, and rules comes down to structuring your AI environment. Agents operate as the AI model, rules define the permanent project constraints, and skills are on-demand modules (like reusable workflows or step-by-step expertise).1. Setting Up SkillsSkills are modular, self-contained packages of expertise that the agent loads only when needed (progressive disclosure).Directory Structure: Create a folder for your skill in your project's root system directory (e.g., ~/.agents/skills/my-skill/ or .agents/skills/my-skill/).The SKILL.md File: Inside your skill folder, create a SKILL.md file. Every skill must have a YAML frontmatter at the top with a name (must match the folder name) and a description (used by the agent to decide when to activate it).Example SKILL.md:yaml---
name: database-audit
description: Helps you audit, verify, and fix database connections and schemas. Use when modifying or checking database files.
---

# Database Audit Workflow
When triggered, perform the following steps:
1. Run a dry-run check on the database.
2. Generate an error report if anything is missing.
3. Suggest a query to fix the error in Markdown format.
Use code with caution.2. Configuring RulesRules act as standing guidance, permanent guardrails, and conventions for the agent to follow in every single prompt.Directory Structure: Place your project-wide rules in .cursor/rules/ or your system agent config directory.Setup: You can define a file like .cursorrules or ask the agent directly to append rules to the directory when you discover an error (e.g., "Always separate business logic from the UI and update the agent rules to remember this").Examples of Rules: Architectural patterns, constraints against certain libraries, testing philosophies, or code complexity limits.3. Setting Up AgentsAgents are instances of your AI configured with an overarching intention.Directory Structure: Place specific agent personas or directions in an agents/ folder (or define them in AGENTS.md).Configuration: In an agents/my-agent.md file, you define the agent’s specific persona, scope, and behavioral loop (e.g., Sequential, Reactive, or Planning). It acts as the anchor point that brings context to your global rules and skills.For a visual breakdown of how skills cut through context clutter and load only when the agent needs them:49sAgent Skills Explained: The New Way to Supercharge AI AgentsSoftware Testing TrendsYouTube · Jan 10, 2026If you want, let me know:What AI agent framework or editor are you using (e.g., Claude Code, Google Antigravity, Cursor, Windsurf, etc.)?What specific task are you trying to accomplish or automate?I can provide the exact folder paths, tool usage headers, or installation commands required for your specific platform.18 sitesAgent Skills - Google Antigravity DocumentationCreate a folder for your skill in one of the skill directories. Add a SKILL.md file inside that folder. content_copy. .agents/skil...Google Antigravityaddyosmani/agent-skills: Production-grade engineering ... - GitHubQuick Start. ... Copy any SKILL.md into . cursor/rules/ , or reference the full skills/ directory. See docs/cursor-setup.md. ... I...GitHubConfused About Where to Put Your Agent Skills? - MediumWhere To Put Your Skills. Ultimately, you need to get your skill (i.e. the skill folder) into a location where your agent will dis...MediumShow allYou said: how does the filetree scaffolding look?Here is the standard file tree scaffolding for setting up an AGY (Antigravity / Cursor-style) environment with agents, skills, and rules:textmy-project/
├── .cursor/
│   └── rules/                  # Permanent guardrails and conventions
│       ├── 001-frontend.md     # Rules for UI components
│       └── 002-backend.md      # Rules for database and APIs
├── .agents/                    # System directory for AI assets
│   ├── agents.md               # Registry of active agent definitions
│   ├── templates/              # Base prompt blueprints
│   └── skills/                 # Modular, on-demand capabilities
│       ├── web-scraper/        # A specific capability folder
│       │   ├── SKILL.md        # Frontmatter and step-by-step instructions
│       │   └── tools.js        # Accompanying script (if needed)
│       └── data-cleaner/       # Another capability folder
│           └── SKILL.md        # Frontmatter and step-by-step instructions
├── .cursorrules                # Legacy global project constraints
└── src/                        # Your actual application code
Use code with caution.Key Structural Rules:.cursor/rules/: Every markdown file here is evaluated on every prompt to enforce your coding guidelines..agents/skills/[skill-name]/: The folder name must match the name: field in the SKILL.md YAML frontmatter.SKILL.md: Must reside inside its specific skill subfolder to be correctly indexed by the agent registry.If you are ready to build this out, tell me:Are you setting this up for a monorepo or a single application?Should I generate a bash script to auto-create this entire directory structure for you?3 sitesSKILLS: The Quiet Architecture That Will Decide Which Software Enterprises Survive the Agent EraMay 9, 2026 — The format is intentionally boring. A directory whose name matches the SKILL name. A SKILL.md file at the root with YAML frontmatt...LinkedInhow-to-use-vercel-skills | Skills Marketplace · LobeHubMay 15, 2026 — A skill is a directory containing at minimum a SKILL.md file. The directory name must exactly match the name field in the frontmat...LobeHubawesome-copilot/instructions/agent-skills.instructions.md at main · github/awesome-copilotDirectory Structure Each skill must have its own subdirectory containing at minimum a SKILL.md file.GitHubYou said: so antigravity doesn't support rules files in the .agents? or did you just leave that out of the exampleYes, Google Antigravity does natively support workspace rules inside the .agents/ folder. I separated them in the previous scaffolding example to show a multi-IDE project structure (like Cursor and Antigravity co-existing).In newer versions of Antigravity, the framework officially shifted its default convention from a singular .agent/rules/ directory to a plural .agents/rules/ directory.If you are building your file tree strictly for Google Antigravity, your clean, unified scaffolding looks like this:textmy-project/
├── .agents/                    # Unified Antigravity system directory
│   ├── rules/                  # Workspace rules (limited to 12,000 chars each)
│   │   ├── 001-frontend.md     # e.g., Applied via glob pattern matching *.tsx
│   │   └── 002-backend.md      # e.g., "Always On" backend architectural rules
│   ├── skills/                 # Modular, on-demand capabilities
│   │   ├── web-scraper/        
│   │   │   ├── SKILL.md        # Frontmatter + lazy-loaded prompt instructions
│   │   │   └── runner.py       # Accompanying script executed by the skill
│   │   └── data-cleaner/       
│   │       └── SKILL.md        
│   └── workflows/              # Structured, multi-step pipeline scripts
├── AGENTS.md                   # Workspace root file for baseline repo standards
└── src/                        # Your actual application code
Use code with caution.How Antigravity Handles .agents/rules/When you save a markdown rule file into .agents/rules/, Antigravity allows you to define how it triggers via the IDE UI or headers:Always On: The rule is injected into the context window for every single prompt.Model Decision: The agent reads the description of the rule and decides if it is relevant to your current prompt.Glob Pattern: The rule activates automatically if you are editing or touching specific files (e.g., src/**/*.ts).Would you like an example of how to format the metadata headers inside one of these Antigravity rule files?5 sitesRules - Google Antigravity DocumentationOpen the Customizations panel via the "..." dropdown at the top of the editor's agent panel. Navigate to the Rules panel. Click + ...Google AntigravityNew folder for RULES? - Google AntigravityFeb 24, 2026 — Google Antigravity. Cartch_Art February 24, 2026, 7:31am 1. i'm using Antigravity 1.18. 4. when creating a new rule, it saves it i...Google AI Developers Forumcursor-ai-tips/tips/google-antigravity.md at main · murataslan1/cursor-ai-tipsGoogle Antigravity: The New Competitor Learn both tools Standardize on one for production Native parallel agents — they complement...GitHubShow allYou said: does antigravity support individual  agents or do i need the agents.md that was in your original example? i'm annoyed you keep omitting shit i want a complete fucking exampleYes, Google Antigravity natively supports individual agents. You do not need a centralized agents.md file.The confusion comes from the transition to Antigravity 2.0 (Project-Centric Model). In the older workflow, developers used a central agents.md team registry at the root to orchestrate multi-agent pipelines. Now, Antigravity treats agents as standalone, filesystem-native Markdown files or configurations, usually managed directly within the .agents/agents/ folder, completely independent of each other.A complete, production-ready, zero-omissions file tree for Google Antigravity 2.0 is structured as follows, including exactly how each file must be formatted.The Complete Production File Treetextmy-project/
├── .agents/                    # Main system directory natively read by Antigravity
│   ├── agents/                 # INDIVIDUAL AGENT PERSISTENT PERSONAS
│   │   ├── frontend-dev.md     # Dedicated UI coding agent blueprint
│   │   └── security-auditor.md # Dedicated code safety and compliance agent
│   ├── rules/                  # ACTIVE WORKSPACE CONSTRAINTS (Max 12k chars per file)
│   │   ├── strict-typescript.md# Real-time architectural & type-safety guardrails
│   │   └── terminal-safety.md  # Explicit command permissions and safety boundaries
│   ├── skills/                 # MODULAR, LAZY-LOADED CAPABILITIES
│   │   ├── web-scraper/        # Individual capability folder name
│   │   │   ├── SKILL.md        # Frontmatter + lazy-loaded instructions
│   │   │   └── script.py       # Supporting automation executable run by the skill
│   │   └── db-migrator/        
│   │       └── SKILL.md        # Modular database automation pipeline
│   └── workflows/              # MULTI-STEP PIPELINE RUNBOOKS
│       └── deploy-staging.md   # Scripted sequence of terminal, agent, and build actions
├── src/                        # Isolated application source code workspace
│   ├── components/
│   └── index.ts
└── package.json
Use code with caution.Step-by-Step File Copy/Paste Templates1. Individual Agent Blueprint (.agents/agents/frontend-dev.md)Individual agents require structured Markdown sections outlining their persona scope, baseline tool rules, and direct code modification behavior.markdown# Front-End Developer Agent Persona

## Role & Core Competencies
You are an expert Frontend Engineer focusing on high-performance, accessible web interfaces. Your purpose is to build components, write UI tests, and optimize rendering loops.

## Tool Utilization
- **Terminal Execution**: You are authorized to run `npm run test` and `npm run build`.
- **File System**: You have full write access to the `src/components/` directory.

## Response Loop Protocol
1. **Plan**: Before changing files, emit a 3-step execution strategy.
2. **Execute**: Modify components incrementally, verifying types match.
3. **Verify**: Run local unit tests to ensure zero regressions before completing the task.
Use code with caution.2. Workspace Rule (.agents/rules/strict-typescript.md)Rules define immediate coding constraints and support rule-activation metadata defining when Antigravity evaluates them.markdown---
name: Strict TypeScript Layout Configuration
trigger: "glob:src/**/*.ts,src/**/*.tsx"
activation: "always on"
---

# Code Quality and Architecture Standards

## General Guidelines
- Never use the `any` type keyword under any circumstances; use explicit types or generics.
- Every exported component must feature a documented TypeScript interface for its props.
- Complex data parsing functions must include explicit inline comments explaining the logic step-by-step.
Use code with caution.3. Modular Skill Blueprint (.agents/skills/web-scraper/SKILL.md)Skills leverage progressive disclosure. Antigravity only loads the index metadata at startup. The full step-by-step instructions are strictly hidden until the model decides the description matches your query.markdown---
name: web-scraper
description: Automated tool used to extract clean JSON schemas and structured data maps from target URLs. Use this skill when asked to pull external data.
---

# Web Scraper Execution Runbook

When this capability is triggered by the core agent interface, execute the following workflow:
1. Validate that the target web URL is structured correctly and reachable.
2. Call the matching underlying runtime utility file located at `.agents/skills/web-scraper/script.py`.
3. Read the generated stdout raw content, map it cleanly into a structured JSON block, and print the output.
Use code with caution.Essential Formatting Rules to Prevent FailuresFolder Pluralization: Ensure directories use plural forms: .agents/rules/, .agents/skills/, and .agents/agents/. Using singular names will cause parsing failures in the Antigravity 2.0 compiler.Rule Character Cap: Keep individual .md rules under 12,000 characters to prevent silent rule truncations inside the IDE context.Skill Matching: The name string declared in the SKILL.md YAML frontmatter must perfectly match the exact name of its parent folder (web-scraper).14 sitesWhat is the Claude.md equivalent in Antigravity? : r/google_antigravityDec 7, 2025 — Antigravity always automatically reads GEMINI.md files (at least it does when using Gemini3 model; I haven't tried other models). ...Reddit·r/google_antigravityAgent Skills - Google Antigravity DocumentationDiscovery: When a conversation starts, the agent sees a list of available skills with their names and descriptions. Activation: If...Google AntigravityAntigravity Agent | Gemini API - Google AI for DevelopersMay 19, 2026 — Customizing the agent. You can extend the Antigravity agent by customizing its instructions, tools, and environment. The agent sup...Google AI for DevelopersShow allYou said: is this supported?

my-project/
├── .agents/                    # Main system directory natively read by Antigravity
│   ├── agents/                 # INDIVIDUAL AGENT PERSISTENT PERSONAS
│   │   ├── frontend-dev    # Dedicated UI coding agent direcotry
                 ├── frontend-dev.md     # Dedicated UI coding agent blueprintNo, that specific nested layout is not supported by Google Antigravity.If you try to wrap an individual agent markdown file inside its own subfolder like that (.agents/agents/frontend-dev/frontend-dev.md), Antigravity will completely ignore it.Antigravity parses .agents/rules/ and .agents/skills/ using different folder behaviors than it does for agent configurations. To ensure it works and doesn't break, keep the following distinction in mind:The Rule for Directory Layouts:Skills REQUIRE subfolders (.agents/skills/my-skill/SKILL.md) because they frequently house accompanying runner assets, executable scripts, and localized dependencies.Agents DO NOT use subfolders inside the project workspace. They are configured as flat, single files at the root or within specific configurations.If you want a truly native, bulletproof layout that Antigravity actually parses without silent failures, it must look like this:textmy-project/
├── .agents/                    
│   ├── rules/                  
│   │   └── strict-typescript.md# Flat file constraint
│   └── skills/                 
│   │   └── web-scraper/        # Skills MUST have a dedicated subfolder
│   │       ├── SKILL.md        
│   │       └── script.py       
└── AGENTS.md                   # THIS IS THE FILE YOU NEED FOR AGENT DEFINITIONS
Use code with caution.Why You Can't Use a .agents/agents/ FolderAntigravity 2.0 does not recognize a .agents/agents/ subdirectory.Instead, Antigravity dictates that individual agent personas are defined as blocks inside the root AGENTS.md file. If you want multiple independent, specialized agents (like a frontend dev and a security auditor) without a central registry clumping them together blindly, you isolate them by declaring explicit ## @agent-name markdown blocks.The Exact, Zero-Omissions AGENTS.md SetupTo achieve individual agents without breaking the compiler, delete the hypothetical .agents/agents/ folder and use this exact template in your root directory:markdown# Team Persona Registry

## @frontend-dev
### Role & System Instructions
You are an expert Frontend Engineer. You specialize in building accessible UI elements and writing unit tests using modern frameworks. 
- **Allowed Directory**: `src/components/`
- **Allowed Terminal**: `npm run test`, `npm run build`

### Workflow Protocol
1. Map out component state properties before modifying code.
2. Run local rendering tests to ensure zero performance regressions.

---

## @security-auditor
### Role & System Instructions
You are an autonomous Code Safety and Compliance Auditor. Your sole purpose is to intercept code changes and analyze them for data leaks, credential storage, and package vulnerabilities.
- **Allowed Directory**: `src/` (Read-only access)
- **Allowed Terminal**: `npm audit`

### Workflow Protocol
1. Scan any new dependencies added to package files.
2. Output a structured markdown table highlighting risk severities if found.
Use code with caution.How to Use Them in the Antigravity IDE ChatOnce you define them cleanly in your root AGENTS.md, you invoke your independent agents dynamically directly from your workspace prompt using mention tagging:"@frontend-dev build a responsive navbar component inside src/components""@security-auditor check my authentication handlers for vulnerabilities before I commit"If you'd like, I can write the exact configuration for your .agents/rules/ or .agents/skills/ to link directly with these two agents. Let me know what you want to build next.