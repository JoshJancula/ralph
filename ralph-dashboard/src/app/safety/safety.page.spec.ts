import '../../angular-test-env';
import { HttpErrorResponse } from '@angular/common/http';
import { ComponentFixture, TestBed } from '@angular/core/testing';
import { signal } from '@angular/core';
import { of, throwError } from 'rxjs';
import { describe, expect, it, vi } from 'vitest';
import { CapabilitiesService } from '../workflows/capabilities.service';
import { WorkspaceSelectorService } from '../services/workspace-selector.service';
import { SafetyApi } from './safety-api.service';
import { SafetyPageComponent } from './safety.page';
import type { SafetyConfig, SafetyConfigResponse, SafetyStatus } from './safety.types';

const SAMPLE_CONFIG: SafetyConfig = {
  schema_version: 2,
  enabled: true,
  dry_run: false,
  banned_tools: ['Bash'],
  tool_denylist: [],
  allowed_tools: [],
  banned_paths: ['.env*'],
  allowed_paths: [],
  allowed_commands: [],
  allowed_patterns: [],
  denied_argument_patterns: [{ pattern: 'secret', mode: 'substring' }],
  custom_rules: [{ name: 'no_sudo', pattern: '^sudo\\s', target: 'command' }],
};

const SAMPLE_STATUS: SafetyStatus = {
  schemaVersion: 1,
  enabled: true,
  dryRun: false,
  source: 'project',
  path: '/ws/killswitch.json',
  precedence: [],
  environmentOverrides: {
    RALPH_KILLSWITCH_DISABLED: null,
    RALPH_KILLSWITCH_OVERRIDE_FILE: null,
    RALPH_BANNED_TOOLS: null,
    RALPH_BANNED_PATHS: null,
    RALPH_BANNED_PATTERNS: null,
    RALPH_ALLOWED_TOOLS: null,
    RALPH_ALLOWED_PATHS: null,
    RALPH_ALLOWED_COMMANDS: null,
    RALPH_ALLOWED_PATTERNS: null,
    RALPH_MCP_TOOL_DENYLIST: null,
  },
  counts: {
    bannedTools: 1,
    toolDenylist: 0,
    allowedTools: 0,
    bannedPaths: 1,
    allowedPaths: 0,
    allowedCommands: 0,
    allowedPatterns: 0,
    deniedArgumentPatterns: 1,
    customRules: 1,
  },
  warnings: [],
};

const SAMPLE_CONFIG_RESPONSE: SafetyConfigResponse = {
  config: SAMPLE_CONFIG,
  sha256: 'abc123',
  exists: true,
  path: '/ws/killswitch.json',
};

function fakeCapabilities(safetyWrites = true) {
  return {
    load: vi.fn(),
    capabilities: signal({
      workflowWrites: safetyWrites,
      workflowRuns: safetyWrites,
      assistant: safetyWrites,
      safetyWrites,
    }),
  };
}

function fakeWorkspace() {
  return {
    selectedWorkspacePath: signal<string | null>(null),
    workspaces: signal([]),
  };
}

function fakeApi(overrides: Partial<SafetyApi> = {}) {
  return {
    fetchStatus: vi.fn(() => of(SAMPLE_STATUS)),
    fetchConfig: vi.fn(() => of(SAMPLE_CONFIG_RESPONSE)),
    updateConfig: vi.fn(() => of({ sha256: 'def', exists: true, path: '/ws/killswitch.json' })),
    checkCommand: vi.fn(),
    ...overrides,
  };
}

describe('SafetyPageComponent', () => {
  async function build(
    api: ReturnType<typeof fakeApi> = fakeApi(),
    capabilities: ReturnType<typeof fakeCapabilities> = fakeCapabilities(true),
  ): Promise<ComponentFixture<SafetyPageComponent>> {
    await TestBed.configureTestingModule({
      imports: [SafetyPageComponent],
      providers: [
        { provide: SafetyApi, useValue: api },
        { provide: CapabilitiesService, useValue: capabilities },
        { provide: WorkspaceSelectorService, useValue: fakeWorkspace() },
      ],
    }).compileComponents();
    const fixture = TestBed.createComponent(SafetyPageComponent);
    fixture.detectChanges();
    await fixture.whenStable();
    fixture.detectChanges();
    return fixture;
  }

  it('renders rule editors for chip lists, custom rules, and denied argument patterns', async () => {
    const fixture = await build();
    const el: HTMLElement = fixture.nativeElement;
    expect(el.querySelector('[data-testid="safety-chips-banned-paths"]')).not.toBeNull();
    expect(el.querySelector('[data-testid="safety-chips-banned-tools"]')).not.toBeNull();
    expect(el.querySelector('[data-testid="safety-chips-tool-denylist"]')).not.toBeNull();
    expect(el.querySelector('[data-testid="safety-chips-allowed-tools"]')).not.toBeNull();
    expect(el.querySelector('[data-testid="safety-chips-allowed-paths"]')).not.toBeNull();
    expect(el.querySelector('[data-testid="safety-chips-allowed-commands"]')).not.toBeNull();
    expect(el.querySelector('[data-testid="safety-chips-allowed-patterns"]')).not.toBeNull();
    expect(el.querySelector('[data-testid="safety-custom-rules"]')).not.toBeNull();
    const customName = el.querySelector('[data-testid="safety-custom-rule-name-0"]') as HTMLInputElement | null;
    expect(customName?.value).toBe('no_sudo');
    expect(el.querySelector('[data-testid="safety-denied-args"]')).not.toBeNull();
    expect(el.querySelector('[data-testid="safety-denied-0"]')).not.toBeNull();
    const deniedPattern = el.querySelector('[data-testid="safety-denied-pattern-0"]') as HTMLInputElement | null;
    expect(deniedPattern?.value).toBe('secret');
    expect(el.querySelector('[data-testid="safety-status-banner"]')?.textContent).toMatch(/enforcement on/i);
  });

  it('shows enabled and dry_run as read-only controls with a terminal edit hint', async () => {
    const fixture = await build();
    const el: HTMLElement = fixture.nativeElement;
    const enabled = el.querySelector('[data-testid="safety-enabled"]') as HTMLInputElement;
    const dryRun = el.querySelector('[data-testid="safety-dry-run"]') as HTMLInputElement;
    expect(enabled).not.toBeNull();
    expect(dryRun).not.toBeNull();
    expect(enabled.readOnly).toBe(true);
    expect(dryRun.readOnly).toBe(true);
    expect(enabled.value).toBe('true');
    expect(dryRun.value).toBe('false');
    expect(el.querySelector('[data-testid="safety-edit-hint-command"]')?.textContent).toContain(
      'ralph safety edit --project',
    );
  });

  it('hides save controls when safetyWrites is false', async () => {
    const fixture = await build(fakeApi(), fakeCapabilities(false));
    const el: HTMLElement = fixture.nativeElement;
    expect(el.querySelector('[data-testid="safety-save"]')).toBeNull();
    expect(el.querySelector('[data-testid="safety-writes-disabled"]')).not.toBeNull();
  });

  it('shows save when safetyWrites is true', async () => {
    const fixture = await build(fakeApi(), fakeCapabilities(true));
    expect(fixture.nativeElement.querySelector('[data-testid="safety-save"]')).not.toBeNull();
  });

  it('adds a protection profile to the draft without removing existing rules or saving', async () => {
    const api = fakeApi();
    const fixture = await build(api);
    const component = fixture.componentInstance;
    const credentialProfile = component.safetyProfiles.find((profile) => profile.id === 'credentials');
    expect(credentialProfile).toBeDefined();

    component.applyProfile(credentialProfile!);
    fixture.detectChanges();

    expect(component.stringLists().banned_paths).toEqual(
      expect.arrayContaining(['.env*', '**/*.pem', '**/*.key', '**/credentials/**']),
    );
    expect(component.hasUnsavedChanges()).toBe(true);
    expect(component.lastAppliedProfile()).toBe('credentials');
    expect(api.updateConfig).not.toHaveBeenCalled();
    expect(fixture.nativeElement.querySelector('[data-testid="safety-unsaved-changes"]')?.textContent).toMatch(
      /unsaved rule changes/i,
    );
  });

  it('keeps exceptions visually separate from ordinary blocking rules', async () => {
    const fixture = await build();
    const el: HTMLElement = fixture.nativeElement;
    const advanced = el.querySelector('[data-testid="safety-advanced-rules"]');
    expect(advanced?.textContent).toMatch(/narrow exceptions/i);
    expect(advanced?.querySelector('[data-testid="safety-chips-allowed-paths"]')).not.toBeNull();
    expect(el.querySelector('[data-testid="safety-chips-banned-paths"]')).not.toBeNull();
  });

  it('surfaces validator diagnostics verbatim on a 422', async () => {
    const api = fakeApi({
      updateConfig: vi.fn(() =>
        throwError(
          () =>
            new HttpErrorResponse({
              status: 422,
              statusText: 'Unprocessable Entity',
              error: {
                error: 'Safety config failed validation',
                diagnostics: '$.allowed_patterns[0]: invalid regex: missing )',
              },
            }),
        ),
      ),
    });
    const fixture = await build(api, fakeCapabilities(true));
    await fixture.componentInstance.save();
    fixture.detectChanges();
    const diagnostics = fixture.nativeElement.querySelector('[data-testid="safety-invalid-diagnostics"]');
    expect(diagnostics).not.toBeNull();
    expect(diagnostics?.textContent).toContain('$.allowed_patterns[0]: invalid regex: missing )');
  });

  it('submits command text and renders a deny outcome with the matched rule name', async () => {
    const api = fakeApi({
      checkCommand: vi.fn(() =>
        of({
          schemaVersion: 1,
          outcome: 'deny',
          source: 'project',
          matchedRule: 'no_sudo',
          precedence: [],
          dryRun: false,
        }),
      ),
    });
    const fixture = await build(api);
    const el: HTMLElement = fixture.nativeElement;
    expect(el.querySelector('[data-testid="safety-check-panel"]')).not.toBeNull();
    expect(el.querySelector('[data-testid="safety-check-copy"]')?.textContent).toMatch(/never executed/i);

    const panel = el.querySelector('[data-testid="safety-check-panel"]');
    const rules = el.querySelector('[data-testid="safety-rules-panel"]');
    expect(panel).not.toBeNull();
    expect(rules).not.toBeNull();
    expect(
      Boolean(panel && rules && !!(panel.compareDocumentPosition(rules) & Node.DOCUMENT_POSITION_FOLLOWING)),
    ).toBe(true);

    fixture.componentInstance.checkCommandText.set('sudo ls');
    fixture.detectChanges();
    await fixture.componentInstance.runCheck();
    fixture.detectChanges();

    expect(api.checkCommand).toHaveBeenCalledWith({ command: 'sudo ls' }, undefined);
    expect(el.querySelector('[data-testid="safety-check-outcome"]')?.textContent?.trim()).toBe('deny');
    expect(el.querySelector('[data-testid="safety-check-matched-rule"]')?.textContent).toContain('no_sudo');
    expect(el.querySelector('[data-testid="safety-check-result-source"]')?.textContent).toContain('project');
  });

  it('renders an allow outcome for a permitted command', async () => {
    const api = fakeApi({
      checkCommand: vi.fn(() =>
        of({
          schemaVersion: 1,
          outcome: 'allow',
          source: 'bundled',
          matchedRule: null,
          precedence: [],
          dryRun: false,
        }),
      ),
    });
    const fixture = await build(api);
    fixture.componentInstance.checkCommandText.set('echo ok');
    fixture.detectChanges();
    await fixture.componentInstance.runCheck();
    fixture.detectChanges();

    const el: HTMLElement = fixture.nativeElement;
    expect(el.querySelector('[data-testid="safety-check-outcome"]')?.textContent?.trim()).toBe('allow');
    expect(el.querySelector('[data-testid="safety-check-matched-rule"]')).toBeNull();
    expect(el.querySelector('[data-testid="safety-check-result"]')?.getAttribute('data-outcome')).toBe('allow');
  });

  it('shows a create-project-config empty state when no project file exists', async () => {
    const api = fakeApi({
      fetchConfig: vi.fn(() =>
        of({
          ...SAMPLE_CONFIG_RESPONSE,
          exists: false,
          path: '/ws/.ralph-workspace/killswitch.json',
        }),
      ),
      fetchStatus: vi.fn(() =>
        of({
          ...SAMPLE_STATUS,
          source: 'bundle',
          path: '/bundle/.ralph/killswitch.json',
        }),
      ),
    });
    const fixture = await build(api);
    const el: HTMLElement = fixture.nativeElement;
    const cta = el.querySelector('[data-testid="safety-create-project-cta"]');
    expect(cta).not.toBeNull();
    expect(cta?.textContent).toMatch(/shipped bundle defaults/i);
    expect(cta?.textContent).toContain('state-root/killswitch.json');
    expect(el.querySelector('[data-testid="safety-create-project-path"]')?.textContent).toContain(
      '/ws/.ralph-workspace/killswitch.json',
    );
    expect(el.querySelector('[data-testid="safety-override-banner"]')).toBeNull();
  });

  it('shows an override-source banner when status source is override', async () => {
    const api = fakeApi({
      fetchStatus: vi.fn(() =>
        of({
          ...SAMPLE_STATUS,
          source: 'override',
          path: '/tmp/override-killswitch.json',
        }),
      ),
    });
    const fixture = await build(api);
    const banner = fixture.nativeElement.querySelector('[data-testid="safety-override-banner"]');
    expect(banner).not.toBeNull();
    expect(banner?.textContent).toMatch(/will not take effect/i);
    expect(banner?.textContent).toMatch(/override is active/i);
  });

  it('shows a read-only environmentOverrides banner when env vars are set', async () => {
    const api = fakeApi({
      fetchStatus: vi.fn(() =>
        of({
          ...SAMPLE_STATUS,
          environmentOverrides: {
            ...SAMPLE_STATUS.environmentOverrides,
            RALPH_BANNED_TOOLS: 'Bash,Write',
            RALPH_BANNED_PATHS: '.env*',
          },
        }),
      ),
    });
    const fixture = await build(api);
    const el: HTMLElement = fixture.nativeElement;
    const panel = el.querySelector('[data-testid="safety-env-overrides"]');
    expect(panel).not.toBeNull();
    expect(panel?.textContent).toMatch(/cannot remove/i);
    expect(el.querySelector('[data-testid="safety-env-RALPH_BANNED_TOOLS"]')?.textContent).toContain('Bash,Write');
    expect(el.querySelector('[data-testid="safety-env-RALPH_BANNED_PATHS"]')?.textContent).toContain('.env*');
  });
});
