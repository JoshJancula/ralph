import {
  EDITABLE_RULE_FIELDS,
  mergeSafetyConfig,
  SafetyConfigError,
  sha256Hex,
} from './safety-config';

function existingConfig(overrides: Record<string, unknown> = {}): Record<string, unknown> {
  return {
    schema_version: 2,
    enabled: true,
    dry_run: false,
    banned_tools: [],
    tool_denylist: [],
    allowed_tools: [],
    banned_paths: ['.env*'],
    allowed_paths: [],
    allowed_commands: [],
    allowed_patterns: [],
    denied_argument_patterns: [],
    custom_rules: [{ name: 'no_sudo', pattern: '^sudo\\s', target: 'command' }],
    ...overrides,
  };
}

describe('EDITABLE_RULE_FIELDS', () => {
  it('lists the canonical rule fields and excludes lock fields', () => {
    expect(EDITABLE_RULE_FIELDS).toEqual([
      'banned_tools',
      'tool_denylist',
      'allowed_tools',
      'banned_paths',
      'allowed_paths',
      'allowed_commands',
      'allowed_patterns',
      'denied_argument_patterns',
      'custom_rules',
    ]);
    expect(EDITABLE_RULE_FIELDS).not.toContain('enabled');
    expect(EDITABLE_RULE_FIELDS).not.toContain('dry_run');
    expect(EDITABLE_RULE_FIELDS).not.toContain('schema_version');
  });
});

describe('mergeSafetyConfig', () => {
  it('merges rule-field edits while preserving schema_version, enabled, and dry_run from disk', () => {
    const existing = existingConfig({
      enabled: true,
      dry_run: false,
      banned_paths: ['.env*'],
      allowed_commands: [],
    });
    const merged = mergeSafetyConfig(existing, {
      sha256: 'ignored-meta',
      banned_paths: ['.env*', '**/secrets/**'],
      allowed_commands: ['ralph safety status'],
    });

    expect(merged['schema_version']).toBe(2);
    expect(merged['enabled']).toBe(true);
    expect(merged['dry_run']).toBe(false);
    expect(merged['banned_paths']).toEqual(['.env*', '**/secrets/**']);
    expect(merged['allowed_commands']).toEqual(['ralph safety status']);
    expect(merged['custom_rules']).toEqual(existing['custom_rules']);
    expect(merged['tool_denylist']).toEqual([]);
  });

  it('rejects a body that attempts to set enabled', () => {
    expect(() => mergeSafetyConfig(existingConfig(), { enabled: false })).toThrow(SafetyConfigError);
    expect(() => mergeSafetyConfig(existingConfig(), { enabled: false })).toThrow(/enabled/);
  });

  it('rejects a body that attempts to set dry_run', () => {
    expect(() => mergeSafetyConfig(existingConfig(), { dry_run: true })).toThrow(SafetyConfigError);
    expect(() => mergeSafetyConfig(existingConfig(), { dry_run: true })).toThrow(/dry_run/);
  });

  it('rejects a body carrying an unknown key', () => {
    expect(() =>
      mergeSafetyConfig(existingConfig(), { not_a_field: [] }),
    ).toThrow(SafetyConfigError);
    expect(() =>
      mergeSafetyConfig(existingConfig(), { not_a_field: [] }),
    ).toThrow(/unknown key/);
  });

  it('does not let a rule edit flip enabled even when existing was dry-run', () => {
    const existing = existingConfig({ enabled: true, dry_run: true });
    const merged = mergeSafetyConfig(existing, { banned_tools: ['Bash'] });
    expect(merged['enabled']).toBe(true);
    expect(merged['dry_run']).toBe(true);
    expect(merged['banned_tools']).toEqual(['Bash']);
  });
});

describe('sha256Hex', () => {
  it('matches the workflow editor utf8 hex digest', () => {
    expect(sha256Hex('')).toBe(
      'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855',
    );
    expect(sha256Hex('{"schema_version":2}\n')).toMatch(/^[a-f0-9]{64}$/);
  });
});
