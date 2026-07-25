import '@angular/compiler';
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';

import { createInMemoryRequester } from './support/in-memory-request';
import { clearMergedWorkspaceAllowlistCache } from '../src/server/dashboard-api';

describe('dashboard API aggregated logs scope', () => {
  let tempRoot = '';
  let app: typeof import('../src/server').app;
  let originalWorkspaceRoot: string | undefined;
  let originalSkipListen: string | undefined;
  let originalDashboardGlobal: string | undefined;
  let originalPlanWorkspaceRoot: string | undefined;
  let originalCwd: string | undefined;

  beforeAll(async () => {
    originalWorkspaceRoot = process.env['RALPH_DASHBOARD_WORKSPACE_ROOT'];
    originalSkipListen = process.env['RALPH_DASHBOARD_SKIP_LISTEN'];
    originalDashboardGlobal = process.env['RALPH_DASHBOARD_GLOBAL'];
    originalPlanWorkspaceRoot = process.env['RALPH_PLAN_WORKSPACE_ROOT'];
    process.env['RALPH_DASHBOARD_SKIP_LISTEN'] = '1';
  });

  beforeEach(async () => {
    clearMergedWorkspaceAllowlistCache();
    originalCwd = process.cwd();
    tempRoot = mkdtempSync(join(tmpdir(), 'ralph-dashboard-aggregated-'));
    process.chdir(tempRoot);
    mkdirSync(join(tempRoot, '.ralph'), { recursive: true });

    const wsA = join(tempRoot, 'proj-a', '.ralph-workspace');
    const wsB = join(tempRoot, 'proj-b', '.ralph-workspace');
    mkdirSync(join(wsA, 'logs', 'same-folder'), { recursive: true });
    mkdirSync(join(wsB, 'logs', 'same-folder'), { recursive: true });
    writeFileSync(join(wsA, 'logs', 'same-folder', 'a.log'), 'a');
    writeFileSync(join(wsB, 'logs', 'same-folder', 'b.log'), 'b');

    process.env['RALPH_DASHBOARD_PROJECT_ROOT'] = tempRoot;
    process.env['RALPH_DASHBOARD_WORKSPACE_ROOT'] = tempRoot;
    delete process.env['RALPH_DASHBOARD_GLOBAL'];
    delete process.env['RALPH_PLAN_WORKSPACE_ROOT'];
    ({ app } = await import('../src/server'));
  });

  afterEach(() => {
    if (originalCwd) {
      process.chdir(originalCwd);
    }
    if (tempRoot) {
      rmSync(tempRoot, { recursive: true, force: true });
    }
  });

  afterAll(() => {
    if (originalWorkspaceRoot === undefined) {
      delete process.env['RALPH_DASHBOARD_WORKSPACE_ROOT'];
    } else {
      process.env['RALPH_DASHBOARD_WORKSPACE_ROOT'] = originalWorkspaceRoot;
    }
    if (originalSkipListen === undefined) {
      delete process.env['RALPH_DASHBOARD_SKIP_LISTEN'];
    } else {
      process.env['RALPH_DASHBOARD_SKIP_LISTEN'] = originalSkipListen;
    }
    if (originalDashboardGlobal === undefined) {
      delete process.env['RALPH_DASHBOARD_GLOBAL'];
    } else {
      process.env['RALPH_DASHBOARD_GLOBAL'] = originalDashboardGlobal;
    }
    if (originalPlanWorkspaceRoot === undefined) {
      delete process.env['RALPH_PLAN_WORKSPACE_ROOT'];
    } else {
      process.env['RALPH_PLAN_WORKSPACE_ROOT'] = originalPlanWorkspaceRoot;
    }
    delete process.env['RALPH_DASHBOARD_PROJECT_ROOT'];
  });

  it('lists duplicate relative folders separately with workspaceRoot metadata when multiple logs roots exist', async () => {
    const res = await createInMemoryRequester(app).get('/api/list?root=logs&path=');

    expect(res.status).toBe(200);
    const names = res.body.entries.map((e: { name: string }) => e.name);
    expect(names.filter((n: string) => n === 'same-folder').length).toBe(2);
    const workspaces = new Set(
      res.body.entries
        .filter((e: { name: string }) => e.name === 'same-folder')
        .map((e: { workspaceRoot: string }) => resolve(e.workspaceRoot)),
    );
    expect(workspaces.size).toBe(2);
  });

  it('scopes listing when workspaceRoot query matches one aggregate root', async () => {
    const wsA = resolve(join(tempRoot, 'proj-a', '.ralph-workspace'));
    const res = await createInMemoryRequester(app).get(
      `/api/list?root=logs&path=&workspaceRoot=${encodeURIComponent(wsA)}`,
    );

    expect(res.status).toBe(200);
    expect(res.body.entries.map((e: { name: string }) => e.name)).toContain('same-folder');
    for (const e of res.body.entries) {
      expect(e.workspaceRoot).toBeUndefined();
    }
  });

  it('returns 400 for file fetch when multiple roots and workspaceRoot is omitted', async () => {
    const res = await createInMemoryRequester(app).get(
      '/api/file?root=logs&path=same-folder/a.log&offset=0',
    );

    expect(res.status).toBe(400);
    expect(res.body.error).toContain('workspaceRoot');
  });

  it('reads file from the workspace selected by workspaceRoot', async () => {
    const wsA = resolve(join(tempRoot, 'proj-a', '.ralph-workspace'));
    const res = await createInMemoryRequester(app).get(
      `/api/file?root=logs&path=same-folder/a.log&offset=0&workspaceRoot=${encodeURIComponent(wsA)}`,
    );

    expect(res.status).toBe(200);
    expect(res.body.content).toBe('a');
  });
});
