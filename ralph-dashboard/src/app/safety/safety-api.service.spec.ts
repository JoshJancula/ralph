import '../../angular-test-env';
import { HttpClientTestingModule, HttpTestingController } from '@angular/common/http/testing';
import { TestBed } from '@angular/core/testing';
import { firstValueFrom } from 'rxjs';
import { afterEach, beforeEach, describe, expect, it } from 'vitest';
import { SafetyApi } from './safety-api.service';
import type { SafetyConfig, SafetyStatus } from './safety.types';

const SAMPLE_CONFIG: SafetyConfig = {
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
  custom_rules: [],
};

const SAMPLE_STATUS: SafetyStatus = {
  schemaVersion: 1,
  enabled: true,
  dryRun: false,
  source: 'bundle',
  path: '/bundle/.ralph/killswitch.json',
  precedence: [
    { source: 'override', path: null, present: false, selected: false },
    { source: 'project', path: '/ws/killswitch.json', present: false, selected: false },
    { source: 'global', path: null, present: false, selected: false },
    { source: 'bundle', path: '/bundle/.ralph/killswitch.json', present: true, selected: true },
  ],
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
    bannedTools: 0,
    toolDenylist: 0,
    allowedTools: 0,
    bannedPaths: 1,
    allowedPaths: 0,
    allowedCommands: 0,
    allowedPatterns: 0,
    deniedArgumentPatterns: 0,
    customRules: 0,
  },
  warnings: [],
};

describe('SafetyApi', () => {
  let service: SafetyApi;
  let httpMock: HttpTestingController;

  beforeEach(() => {
    TestBed.configureTestingModule({
      imports: [HttpClientTestingModule],
      providers: [SafetyApi],
    });
    service = TestBed.inject(SafetyApi);
    httpMock = TestBed.inject(HttpTestingController);
  });

  afterEach(() => {
    httpMock.verify();
  });

  it('fetchStatus: GET /api/safety/status, with and without workspaceRoot', async () => {
    const p1 = firstValueFrom(service.fetchStatus());
    const r1 = httpMock.expectOne((r) => r.url === '/api/safety/status');
    expect(r1.request.method).toBe('GET');
    expect(r1.request.params.has('workspaceRoot')).toBe(false);
    r1.flush(SAMPLE_STATUS);
    expect(await p1).toEqual(SAMPLE_STATUS);

    const p2 = firstValueFrom(service.fetchStatus('/repo/.ralph-workspace'));
    const r2 = httpMock.expectOne((r) => r.url === '/api/safety/status');
    expect(r2.request.method).toBe('GET');
    expect(r2.request.params.get('workspaceRoot')).toBe('/repo/.ralph-workspace');
    r2.flush(SAMPLE_STATUS);
    await p2;
  });

  it('fetchConfig: GET /api/safety/config, with and without workspaceRoot', async () => {
    const body = {
      config: SAMPLE_CONFIG,
      sha256: 'abc',
      exists: false,
      path: '/repo/.ralph-workspace/killswitch.json',
    };

    const p1 = firstValueFrom(service.fetchConfig());
    const r1 = httpMock.expectOne((r) => r.url === '/api/safety/config');
    expect(r1.request.method).toBe('GET');
    expect(r1.request.params.has('workspaceRoot')).toBe(false);
    r1.flush(body);
    expect(await p1).toEqual(body);

    const p2 = firstValueFrom(service.fetchConfig('/ws'));
    const r2 = httpMock.expectOne((r) => r.url === '/api/safety/config');
    expect(r2.request.params.get('workspaceRoot')).toBe('/ws');
    r2.flush(body);
    await p2;
  });

  it('checkCommand: POST /api/safety/check with body and workspaceRoot', async () => {
    const command = { command: 'sudo ls' };
    const result = {
      schemaVersion: 1,
      outcome: 'deny',
      source: 'bundle',
      matchedRule: 'no_sudo',
      precedence: SAMPLE_STATUS.precedence,
      dryRun: false,
    };

    const promise = firstValueFrom(service.checkCommand(command, '/ws'));
    const req = httpMock.expectOne((r) => r.url === '/api/safety/check' && r.method === 'POST');
    expect(req.request.body).toEqual(command);
    expect(req.request.params.get('workspaceRoot')).toBe('/ws');
    req.flush(result);
    expect(await promise).toEqual(result);
  });

  it('updateConfig: PUT /api/safety/config with sha256 body and workspaceRoot', async () => {
    const command = { sha256: 'abc', banned_paths: ['.env*', '**/secrets/**'] };
    const response = {
      sha256: 'def',
      exists: true,
      path: '/ws/killswitch.json',
    };

    const promise = firstValueFrom(service.updateConfig(command, '/ws'));
    const req = httpMock.expectOne((r) => r.url === '/api/safety/config' && r.method === 'PUT');
    expect(req.request.body).toEqual(command);
    expect(req.request.params.get('workspaceRoot')).toBe('/ws');
    req.flush(response);
    expect(await promise).toEqual(response);
  });
});
