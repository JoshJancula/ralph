import '@angular/compiler';
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';

import { createInMemoryRequester } from './support/in-memory-request';

import { clearDashboardRootsCache } from '../src/paths';
import { clearMergedWorkspaceAllowlistCache } from '../src/server/dashboard-api';

function listEntryNames(body: { entries: Array<{ name: string }> }): string[] {
  return body.entries.map((e) => e.name);
}

describe('dashboard API plans listing', () => {
  let tempRoot = '';
  let app: typeof import('../src/server').app;
  let originalWorkspaceRoot: string | undefined;
  let originalProjectRoot: string | undefined;
  let originalSkipListen: string | undefined;
  let originalLegacyBlocklist: string | undefined;
  let originalCwd: string | undefined;

  beforeAll(async () => {
    originalWorkspaceRoot = process.env['RALPH_DASHBOARD_WORKSPACE_ROOT'];
    originalProjectRoot = process.env['RALPH_DASHBOARD_PROJECT_ROOT'];
    originalSkipListen = process.env['RALPH_DASHBOARD_SKIP_LISTEN'];
    originalLegacyBlocklist = process.env['RALPH_DASHBOARD_PLANS_LEGACY_BLOCKLIST'];
    process.env['RALPH_DASHBOARD_SKIP_LISTEN'] = '1';
  });

  beforeEach(async () => {
    originalCwd = process.cwd();
    tempRoot = mkdtempSync(join(tmpdir(), 'ralph-dashboard-plans-list-'));
    process.chdir(tempRoot);
    mkdirSync(join(tempRoot, '.ralph'), { recursive: true });
    process.env['RALPH_DASHBOARD_PROJECT_ROOT'] = resolve(tempRoot);
    process.env['RALPH_DASHBOARD_WORKSPACE_ROOT'] = resolve(tempRoot);
    delete process.env['RALPH_DASHBOARD_PLANS_LEGACY_BLOCKLIST'];
    clearDashboardRootsCache();
    clearMergedWorkspaceAllowlistCache();
    ({ app } = await import('../src/server'));
  });

  afterEach(() => {
    if (originalCwd) {
      process.chdir(originalCwd);
    }
    if (tempRoot) {
      rmSync(tempRoot, { recursive: true, force: true });
    }
    clearDashboardRootsCache();
    clearMergedWorkspaceAllowlistCache();
  });

  afterAll(() => {
    if (originalWorkspaceRoot === undefined) {
      delete process.env['RALPH_DASHBOARD_WORKSPACE_ROOT'];
    } else {
      process.env['RALPH_DASHBOARD_WORKSPACE_ROOT'] = originalWorkspaceRoot;
    }
    if (originalProjectRoot === undefined) {
      delete process.env['RALPH_DASHBOARD_PROJECT_ROOT'];
    } else {
      process.env['RALPH_DASHBOARD_PROJECT_ROOT'] = originalProjectRoot;
    }
    if (originalSkipListen === undefined) {
      delete process.env['RALPH_DASHBOARD_SKIP_LISTEN'];
    } else {
      process.env['RALPH_DASHBOARD_SKIP_LISTEN'] = originalSkipListen;
    }
    if (originalLegacyBlocklist === undefined) {
      delete process.env['RALPH_DASHBOARD_PLANS_LEGACY_BLOCKLIST'];
    } else {
      process.env['RALPH_DASHBOARD_PLANS_LEGACY_BLOCKLIST'] = originalLegacyBlocklist;
    }
  });

  it('excludes src, lib, app, and config directories at plans root while keeping plan.md', async () => {
    for (const dir of ['src', 'lib', 'app', 'config']) {
      mkdirSync(join(tempRoot, dir), { recursive: true });
      writeFileSync(join(tempRoot, dir, 'module.ts'), '');
    }
    writeFileSync(join(tempRoot, 'plan.md'), '# plan');

    clearDashboardRootsCache();
    clearMergedWorkspaceAllowlistCache();

    const res = await createInMemoryRequester(app).get('/api/list?root=plans');
    expect(res.status).toBe(200);
    const names = listEntryNames(res.body);

    expect(names).toContain('plan.md');
    expect(names).not.toContain('src');
    expect(names).not.toContain('lib');
    expect(names).not.toContain('app');
    expect(names).not.toContain('config');
  });

  it('includes root plans/ and .ralph-workspace at plans root and excludes other directories', async () => {
    mkdirSync(join(tempRoot, 'plans'), { recursive: true });
    mkdirSync(join(tempRoot, '.ralph-workspace', 'plans'), { recursive: true });
    mkdirSync(join(tempRoot, 'src'), { recursive: true });
    mkdirSync(join(tempRoot, 'node_modules'), { recursive: true });
    writeFileSync(join(tempRoot, 'plans', 'bucket.md'), '');
    writeFileSync(join(tempRoot, '.ralph-workspace', 'plans', 'ws.md'), '');

    clearDashboardRootsCache();
    clearMergedWorkspaceAllowlistCache();

    const res = await createInMemoryRequester(app).get('/api/list?root=plans');
    expect(res.status).toBe(200);
    const names = listEntryNames(res.body);

    expect(names).toEqual(['.ralph-workspace', 'plans']);
    expect(names).not.toContain('src');
    expect(names).not.toContain('node_modules');
    expect(names).not.toContain('bucket.md');
    expect(names).not.toContain('ws.md');
  });

  it('lists only strict plan*.md files at project root and rejects lookalikes', async () => {
    writeFileSync(join(tempRoot, 'plan.md'), '# ok');
    writeFileSync(join(tempRoot, 'plan-feature.md'), '# ok');
    writeFileSync(join(tempRoot, 'planning.md'), '# wrong stem');
    writeFileSync(join(tempRoot, 'planet.md'), '# wrong stem');
    writeFileSync(join(tempRoot, 'plan-system.ts'), 'export {}');

    clearDashboardRootsCache();
    clearMergedWorkspaceAllowlistCache();

    const res = await createInMemoryRequester(app).get('/api/list?root=plans');
    expect(res.status).toBe(200);
    const names = listEntryNames(res.body);

    expect(names).toContain('plan.md');
    expect(names).toContain('plan-feature.md');
    expect(names).not.toContain('planning.md');
    expect(names).not.toContain('planet.md');
    expect(names).not.toContain('plan-system.ts');
  });

  it('filters plans root listing by directory allowlist and plan file stem rules', async () => {
    mkdirSync(join(tempRoot, 'src'), { recursive: true });
    mkdirSync(join(tempRoot, 'cli'), { recursive: true });
    writeFileSync(join(tempRoot, 'src', 'foo.ts'), '');
    writeFileSync(join(tempRoot, 'plan-good.md'), '# ok');
    writeFileSync(join(tempRoot, 'planning-wrong.md'), '# not');
    mkdirSync(join(tempRoot, '.ralph-workspace', 'logs'), { recursive: true });

    clearDashboardRootsCache();
    clearMergedWorkspaceAllowlistCache();

    const res = await createInMemoryRequester(app).get('/api/list?root=plans');
    expect(res.status).toBe(200);
    const names = (res.body.entries as Array<{ name: string }>).map((e) => e.name);

    expect(names).toContain('plan-good.md');
    expect(names).not.toContain('src');
    expect(names).not.toContain('cli');
    expect(names).not.toContain('planning-wrong.md');
    expect(names).toContain('.ralph-workspace');
  });

  it('does not apply PLAN_DIR_BLOCKLIST under plans/ unless legacy flag is set', async () => {
    mkdirSync(join(tempRoot, 'plans', 'feature'), { recursive: true });
    mkdirSync(join(tempRoot, 'plans', 'feature', 'node_modules'), { recursive: true });
    writeFileSync(join(tempRoot, 'plans', 'feature', 'node_modules', 'pkg.js'), '');

    clearDashboardRootsCache();
    clearMergedWorkspaceAllowlistCache();

    const resDefault = await createInMemoryRequester(app).get('/api/list?root=plans&path=plans/feature');
    expect(resDefault.status).toBe(200);
    expect(listEntryNames(resDefault.body)).toContain('node_modules');

    process.env['RALPH_DASHBOARD_PLANS_LEGACY_BLOCKLIST'] = '1';
    clearDashboardRootsCache();
    clearMergedWorkspaceAllowlistCache();
    ({ app } = await import('../src/server'));

    const resLegacy = await createInMemoryRequester(app).get('/api/list?root=plans&path=plans/feature');
    expect(resLegacy.status).toBe(200);
    expect(listEntryNames(resLegacy.body)).not.toContain('node_modules');
  });

  it('returns no visible entries when listing a non-plan subtree under plans root', async () => {
    mkdirSync(join(tempRoot, 'src'), { recursive: true });
    writeFileSync(join(tempRoot, 'src', 'foo.ts'), '');
    mkdirSync(join(tempRoot, '.ralph-workspace'), { recursive: true });

    clearDashboardRootsCache();
    clearMergedWorkspaceAllowlistCache();

    const res = await createInMemoryRequester(app).get('/api/list?root=plans&path=src');
    expect(res.status).toBe(200);
    expect((res.body.entries as unknown[])).toHaveLength(0);
  });

  it('lists only the plans directory inside .ralph-workspace for the plans explorer', async () => {
    mkdirSync(join(tempRoot, '.ralph-workspace', 'plans'), { recursive: true });
    mkdirSync(join(tempRoot, '.ralph-workspace', 'logs'), { recursive: true });
    writeFileSync(join(tempRoot, '.ralph-workspace', 'orphan.txt'), 'x');

    clearDashboardRootsCache();
    clearMergedWorkspaceAllowlistCache();

    const res = await createInMemoryRequester(app).get('/api/list?root=plans&path=.ralph-workspace');
    expect(res.status).toBe(200);
    const names = (res.body.entries as Array<{ name: string }>).map((e) => e.name);

    expect(names).toEqual(['plans']);
  });

  it('prefers .ralph-workspace/plans over deeper duplicate paths when opening by basename', async () => {
    mkdirSync(join(tempRoot, '.ralph-workspace', 'plans'), { recursive: true });
    writeFileSync(join(tempRoot, '.ralph-workspace', 'plans', 'dup.md'), 'from workspace plans');
    mkdirSync(join(tempRoot, 'src'), { recursive: true });
    writeFileSync(join(tempRoot, 'src', 'dup.md'), 'from src');

    clearDashboardRootsCache();
    clearMergedWorkspaceAllowlistCache();

    const res = await createInMemoryRequester(app).get('/api/file?root=plans&path=dup.md&offset=0');
    expect(res.status).toBe(200);
    expect(res.body.content).toContain('from workspace plans');
    expect(res.body.content).not.toContain('from src');
  });
});

describe('dashboard API plans listing global projectRoot scope', () => {
  let harnessRoot = '';
  let projA = '';
  let projB = '';
  let app: typeof import('../src/server').app;
  let originalWorkspaceRoot: string | undefined;
  let originalProjectRoot: string | undefined;
  let originalSkipListen: string | undefined;
  let originalWorkspacesFile: string | undefined;
  let originalCwd: string | undefined;

  beforeAll(async () => {
    originalWorkspaceRoot = process.env['RALPH_DASHBOARD_WORKSPACE_ROOT'];
    originalProjectRoot = process.env['RALPH_DASHBOARD_PROJECT_ROOT'];
    originalSkipListen = process.env['RALPH_DASHBOARD_SKIP_LISTEN'];
    originalWorkspacesFile = process.env['RALPH_WORKSPACES_FILE'];
    process.env['RALPH_DASHBOARD_SKIP_LISTEN'] = '1';
  });

  beforeEach(async () => {
    originalCwd = process.cwd();
    harnessRoot = mkdtempSync(join(tmpdir(), 'ralph-dashboard-plans-global-'));
    projA = join(harnessRoot, 'proj-a');
    projB = join(harnessRoot, 'proj-b');

    for (const proj of [projA, projB]) {
      mkdirSync(join(proj, '.ralph'), { recursive: true });
      mkdirSync(join(proj, '.ralph-workspace', 'plans'), { recursive: true });
    }

    writeFileSync(join(projA, 'plan-a.md'), 'from a');
    mkdirSync(join(projA, 'src'), { recursive: true });
    writeFileSync(join(projA, '.ralph-workspace', 'plans', 'only-a.md'), 'a bucket');

    writeFileSync(join(projB, 'plan-b.md'), 'from b');
    mkdirSync(join(projB, 'lib'), { recursive: true });
    writeFileSync(join(projB, '.ralph-workspace', 'plans', 'only-b.md'), 'b bucket');

    const registryPath = join(harnessRoot, 'workspaces.json');
    writeFileSync(
      registryPath,
      JSON.stringify([
        { path: projA, lastSeen: '2026-05-23T10:00:00Z', planKey: 'plan-a', runtime: 'cursor' },
        { path: projB, lastSeen: '2026-05-23T10:01:00Z', planKey: 'plan-b', runtime: 'claude' },
      ]),
    );

    process.chdir(harnessRoot);
    process.env['RALPH_DASHBOARD_PROJECT_ROOT'] = resolve(harnessRoot);
    process.env['RALPH_DASHBOARD_WORKSPACE_ROOT'] = resolve(harnessRoot);
    process.env['RALPH_WORKSPACES_FILE'] = registryPath;
    clearDashboardRootsCache();
    clearMergedWorkspaceAllowlistCache();
    ({ app } = await import('../src/server'));
  });

  afterEach(() => {
    if (originalCwd) {
      process.chdir(originalCwd);
    }
    if (harnessRoot) {
      rmSync(harnessRoot, { recursive: true, force: true });
    }
    clearDashboardRootsCache();
    clearMergedWorkspaceAllowlistCache();
  });

  afterAll(() => {
    if (originalWorkspaceRoot === undefined) {
      delete process.env['RALPH_DASHBOARD_WORKSPACE_ROOT'];
    } else {
      process.env['RALPH_DASHBOARD_WORKSPACE_ROOT'] = originalWorkspaceRoot;
    }
    if (originalProjectRoot === undefined) {
      delete process.env['RALPH_DASHBOARD_PROJECT_ROOT'];
    } else {
      process.env['RALPH_DASHBOARD_PROJECT_ROOT'] = originalProjectRoot;
    }
    if (originalSkipListen === undefined) {
      delete process.env['RALPH_DASHBOARD_SKIP_LISTEN'];
    } else {
      process.env['RALPH_DASHBOARD_SKIP_LISTEN'] = originalSkipListen;
    }
    if (originalWorkspacesFile === undefined) {
      delete process.env['RALPH_WORKSPACES_FILE'];
    } else {
      process.env['RALPH_WORKSPACES_FILE'] = originalWorkspacesFile;
    }
  });

  it('returns only each workspace plan content when projectRoot is scoped', async () => {
    const resA = await createInMemoryRequester(app).get(
      `/api/list?root=plans&projectRoot=${encodeURIComponent(projA)}`,
    );
    const resB = await createInMemoryRequester(app).get(
      `/api/list?root=plans&projectRoot=${encodeURIComponent(projB)}`,
    );

    expect(resA.status).toBe(200);
    expect(resB.status).toBe(200);

    const namesA = listEntryNames(resA.body);
    const namesB = listEntryNames(resB.body);

    expect(namesA).toContain('plan-a.md');
    expect(namesA).toContain('.ralph-workspace');
    expect(namesA).not.toContain('plan-b.md');
    expect(namesA).not.toContain('src');
    expect(namesA).not.toContain('lib');

    expect(namesB).toContain('plan-b.md');
    expect(namesB).toContain('.ralph-workspace');
    expect(namesB).not.toContain('plan-a.md');
    expect(namesB).not.toContain('src');
    expect(namesB).not.toContain('lib');
  });
});
