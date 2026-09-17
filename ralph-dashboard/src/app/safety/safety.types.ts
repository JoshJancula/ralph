/** Wire types for the dashboard safety (killswitch) HTTP API. */

export type SafetySourceKind = 'override' | 'project' | 'global' | 'bundle';

export interface SafetyPrecedenceEntry {
  readonly source: SafetySourceKind | string;
  readonly path: string | null;
  readonly present: boolean;
  readonly selected: boolean;
}

export interface SafetyStatusCounts {
  readonly bannedTools: number;
  readonly toolDenylist: number;
  readonly allowedTools: number;
  readonly bannedPaths: number;
  readonly allowedPaths: number;
  readonly allowedCommands: number;
  readonly allowedPatterns: number;
  readonly deniedArgumentPatterns: number;
  readonly customRules: number;
}

export interface SafetyEnvironmentOverrides {
  readonly RALPH_KILLSWITCH_DISABLED: string | null;
  readonly RALPH_KILLSWITCH_OVERRIDE_FILE: string | null;
  readonly RALPH_BANNED_TOOLS: string | null;
  readonly RALPH_BANNED_PATHS: string | null;
  readonly RALPH_BANNED_PATTERNS: string | null;
  readonly RALPH_ALLOWED_TOOLS: string | null;
  readonly RALPH_ALLOWED_PATHS: string | null;
  readonly RALPH_ALLOWED_COMMANDS: string | null;
  readonly RALPH_ALLOWED_PATTERNS: string | null;
  readonly RALPH_MCP_TOOL_DENYLIST: string | null;
}

/** `ralph safety status --json` / GET /api/safety/status. */
export interface SafetyStatus {
  readonly schemaVersion: number;
  readonly enabled: boolean;
  readonly dryRun: boolean;
  readonly source: SafetySourceKind | string;
  readonly path: string;
  readonly precedence: readonly SafetyPrecedenceEntry[];
  readonly environmentOverrides: SafetyEnvironmentOverrides;
  readonly counts: SafetyStatusCounts;
  readonly warnings: readonly string[];
}

export type SafetyCheckOutcome = 'allow' | 'deny' | 'fatal' | string;

/** `ralph safety check --command … --json` / POST /api/safety/check. */
export interface SafetyCheckResult {
  readonly schemaVersion: number;
  readonly outcome: SafetyCheckOutcome;
  readonly source: SafetySourceKind | string;
  readonly matchedRule: string | null;
  readonly precedence: readonly SafetyPrecedenceEntry[];
  readonly dryRun: boolean;
}

export interface SafetyCustomRule {
  readonly name: string;
  readonly match?: string;
  readonly pattern?: string;
  readonly target?: string;
}

export interface SafetyDeniedArgumentPattern {
  readonly tool?: string;
  readonly argument?: string;
  readonly pattern: string;
  readonly mode?: string;
}

/** Canonical killswitch.json object (schema version 2). */
export interface SafetyConfig {
  readonly schema_version: number;
  readonly enabled: boolean;
  readonly dry_run: boolean;
  readonly banned_tools: readonly string[];
  readonly tool_denylist: readonly string[];
  readonly allowed_tools: readonly string[];
  readonly banned_paths: readonly string[];
  readonly allowed_paths: readonly string[];
  readonly allowed_commands: readonly string[];
  readonly allowed_patterns: readonly string[];
  readonly denied_argument_patterns: readonly SafetyDeniedArgumentPattern[];
  readonly custom_rules: readonly SafetyCustomRule[];
}

/** GET /api/safety/config — project file or unsaved bundle seed. */
export interface SafetyConfigResponse {
  readonly config: SafetyConfig;
  readonly sha256: string;
  readonly exists: boolean;
  readonly path: string;
}

/**
 * PUT /api/safety/config body: concurrency token plus optional rule-field edits.
 * enabled / dry_run are rejected server-side.
 */
export interface UpdateSafetyConfigCommand {
  readonly sha256: string;
  readonly banned_tools?: readonly string[];
  readonly tool_denylist?: readonly string[];
  readonly allowed_tools?: readonly string[];
  readonly banned_paths?: readonly string[];
  readonly allowed_paths?: readonly string[];
  readonly allowed_commands?: readonly string[];
  readonly allowed_patterns?: readonly string[];
  readonly denied_argument_patterns?: readonly SafetyDeniedArgumentPattern[];
  readonly custom_rules?: readonly SafetyCustomRule[];
}

export interface UpdateSafetyConfigResponse {
  readonly sha256: string;
  readonly exists: boolean;
  readonly path: string;
}

export interface SafetyCheckCommand {
  readonly command: string;
}
