## Threat Model: Bash Runtime & MCP Surface

### Assets
- **Runner invocations:** `run-plan.sh`, `orchestrator.sh` (`bundle/.ralph/run-plan.sh`, `bundle/.ralph/orchestrator.sh`)
- **MCP API surface:** `mcp-server.sh` (`bundle/.ralph/mcp-server.sh`) plus supporting libs such as `bash-lib/mcp-tools.sh` and `bash-lib/mcp-resources.sh`
- **Agent runtime context:** Plan files, environment overrides, session files (`.ralph-workspace/sessions`)
- **Agent tool invocations:** Cursor/Claude/Codex/OpenCode subprocesses via `run-plan-invoke-*.sh`

### Threat Sources
1. **Local adversary** running `run-plan`/`orchestrator` with crafted `--plan`/`--workspace` paths, environment variables, or plan content.
2. **Remote MCP client** (e.g., dashboard, automation) exploiting path resolution, auth bypass, or tool arguments.
3. **Malicious plan content** leaking secrets or injecting commands when sent to downstream CLIs.

### Trust Boundaries
- **CLI boundary:** User-supplied args (`run-plan-args.sh`), environment (`run-plan-env.sh`), templates reused as prompts for agent invocations.
- **Filesystem:** Workspace root + `.ralph-workspace`; `plan_normalize_path` and MCP helpers control canonicalization.
- **MCP network:** stdio JSON-RPC server (`mcp-server.sh`) that runs `execute_tool_command` with tool arguments.
- **Subprocesses:** Agent runtimes executed via arrays constructed in `run-plan-invoke-common.sh` and runtime-specific wrappers.

### Attack Vectors & OWASP ASVS Controls
- **Command injection:** Ensure array construction never rejoins user data via `eval`. Guard `run-plan-invoke-common` helpers (V5.1.1, V5.1.2). Add defensive comments/tests around `eval` usage.
- **Path traversal / file access:** `plan_normalize_path` allows absolute paths; MCP `resolve_plan_path` ensures workspace containment. Treat unvalidated `--plan` inputs per ASVS V4.1.1 and V4.4.2.
- **Auth / access control:** MCP optionally enforced via `RALPH_MCP_AUTH_TOKEN` but defaults to open access (V1.1, V1.7). Document and harden default to deny.
- **Secret leakage:** Logs (`plan-usage-summary`, `.ralph-workspace/logs`) contain CLI tokens; ensure JSON writers escape values (V6.5.2) and avoid writing debug metrics to `.cursor/debug-*.log`.
- **Race/confidentiality:** Temp files created via `mktemp` (Codex prompts, MCP caches) should be `chmod 600` and cleaned on traps (V6.5.1).

### Notable Assumptions
- MCP server traditionally bound to localhost; exposing `RALPH_MCP_WORKSPACE` and `RALPH_MCP_ALLOWLIST` to multi-tenant contexts is a configuration decision.
- Agent CLIs are treated as high-privilege; any prompt-level secrets must never leak into dash logs or `plan-usage-summary`.

### Visibility & Logging
- Usage summaries written via here-docs (`run-plan-core.sh`) must escape JSON to avoid injection/dump (V10.6).
- Debug logging under `.cursor/debug-*.log` should be gated or removed to prevent high-volume secret capture.

## Threat Model: Ralph Dashboard (Angular + Express)

### Assets
- **Dashboard API:** routes defined in `ralph-dashboard/src/server/dashboard-api.ts`
- **Path helpers:** `ralph-dashboard/src/paths.ts` controlling roots, traversal, hidden file filtering.
- **Client rendering:** Angular components in `src/app/components` (notably file/log viewers) plus `markdown-to-html`.
- **Static assets:** built Angular application served from `scripts/start-server.cjs`.

### Threat Sources
1. **Authenticated or unauthenticated browser** with network access to the Express API (could be localhost or wider depending on host binding).
2. **Malicious workspace file** containing crafted markdown/logs rendered via `FileViewer` or `LogViewer`.
3. **External monitoring** hitting `/api/*` endpoints to enumerate workspace files and sessions.

### Trust Boundaries
- **HTTP boundary:** Express server exposes GET-only APIs; no authentication is enforced (ASVS V1.1, V1.4).
- **Filesystem boundary:** `resolveUnderRoot` ensures normalized paths under allowed roots but does not prevent symlink escapes (V4.4.2).
- **Rendering boundary:** Markdown sanitized manually and then marked safe via `DomSanitizer.bypassSecurityTrustHtml` (V6.3).

### Vulnerability Hypotheses & ASVS Mapping
- **Broken access control:** `/api/roots` + `/api/file` expose workspace contents to any caller (V1.2.1). Review host binding (default 127.0.0.1 but configurable) and consider authentication or network restrictions.
- **Sensitive data exposure:** `/api/workspace` leaks absolute paths, `/api/list` shows metadata from `.ralph-workspace`. Classify under V6.5.1.
- **XSS via markdown/log renderer:** Custom sanitizer may miss vectors; `bypassSecurityTrustHtml` amplifies risk (V6.3.1). Evaluate sanitization rules and test with edge cases.
- **Path traversal & symlink:** `resolveUnderRoot` prevents `..`, but symlink traversal via `fs.readFile` could leak outside root (V4.4.1). Document assumption and consider `realpath` on resolved targets.
- **Denial of service / large files:** APIs can stream large files; cooling off required? aligns with V9.2.

### Monitoring & Hardening
- Add security headers (`Content-Security-Policy`, `Referrer-Policy`) when serving SPA to limit script sources (V13).
- Document host binding restrictions in deployment notes (`scripts/start-server.cjs`).
- Provide explicit `allowed-roots` configuration to limit exposure; highlight existing CLI tests verifying hidden files.

### Test Requirements
- Validate `resolveUnderRoot` across symlinked directories and odd unicode/nul bytes to ensure attacker cannot escape root.
- Exercise markdown pipeline with `FileViewer` using crafted input to confirm no script execution.
- Verify `/api/metrics/summary` parsing handles malformed JSON gracefully (V10.6).

### Remaining Assumptions
- The dashboard is intended to run locally; threat model presumes adversary gains access to the host's network interface.
