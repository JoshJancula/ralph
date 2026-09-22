/**
 * Pure safety (killswitch) config merge helpers for the dashboard.
 * No Express or filesystem I/O — unit-testable rules-only enforcement.
 */
import { createHash } from 'node:crypto';

/** Rule-list fields the dashboard may edit. schema_version / enabled / dry_run stay on-disk. */
export const EDITABLE_RULE_FIELDS = [
  'banned_tools',
  'tool_denylist',
  'allowed_tools',
  'banned_paths',
  'allowed_paths',
  'allowed_commands',
  'allowed_patterns',
  'denied_argument_patterns',
  'custom_rules',
] as const;

export type EditableRuleField = (typeof EDITABLE_RULE_FIELDS)[number];

const EDITABLE_RULE_FIELD_SET: ReadonlySet<string> = new Set(EDITABLE_RULE_FIELDS);

/** Wire-only keys accepted on a PUT body but never written into killswitch.json. */
const META_BODY_KEYS: ReadonlySet<string> = new Set(['sha256']);

export class SafetyConfigError extends Error {
  constructor(message: string) {
    super(message);
    this.name = 'SafetyConfigError';
  }
}

/** Same utf8 hex digest the workflow editor uses for optimistic concurrency. */
export function sha256Hex(content: string): string {
  return createHash('sha256').update(content, 'utf8').digest('hex');
}

/**
 * Build the outgoing killswitch object: lock schema_version / enabled / dry_run
 * from `existing`, and take only editable rule fields from `body`. Rejects
 * enabled, dry_run, and any unknown (non-meta) key so a direct API caller
 * cannot disable enforcement or smuggle extra keys.
 */
export function mergeSafetyConfig(
  existing: Record<string, unknown>,
  body: Record<string, unknown>,
): Record<string, unknown> {
  if (Object.prototype.hasOwnProperty.call(body, 'enabled')) {
    throw new SafetyConfigError(
      'enabled is read-only in the dashboard; use ralph safety edit',
    );
  }
  if (Object.prototype.hasOwnProperty.call(body, 'dry_run')) {
    throw new SafetyConfigError(
      'dry_run is read-only in the dashboard; use ralph safety edit',
    );
  }

  for (const key of Object.keys(body)) {
    if (META_BODY_KEYS.has(key)) {
      continue;
    }
    if (!EDITABLE_RULE_FIELD_SET.has(key)) {
      throw new SafetyConfigError(`unknown key: ${key}`);
    }
  }

  const out: Record<string, unknown> = {
    schema_version: existing['schema_version'],
    enabled: existing['enabled'],
    dry_run: existing['dry_run'],
  };
  for (const field of EDITABLE_RULE_FIELDS) {
    out[field] = Object.prototype.hasOwnProperty.call(body, field)
      ? body[field]
      : existing[field];
  }
  return out;
}
