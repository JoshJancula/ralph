import '@angular/compiler';
import { mkdirSync, mkdtempSync, realpathSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { basename, join } from 'node:path';

import { createInMemoryRequester } from './support/in-memory-request';

import { clearDashboardRootsCache, findDashboardRoots, resolveRalphInstallRoot } from '../src/paths';
import {
  clearMergedWorkspaceAllowlistCache,
  getMergedWorkspaceAllowlist,
  resolveDashboardRootsForRequest,
} from '../src/server/dashboard-api';

const request = createInMemoryRequester;

describe('dashboard API workspaces endpoint', () => {
  let tempRoot = '';
  let app: typeof import('../src/server').app;
  let originalWorkspaceRoot: string | undefined;
  let originalSkipListen: string | undefined;
  let originalDashboardGlobal: string | undefined;
  let originalWorkspacesFile: string | undefined;
  let originalCwd: string | undefined;

  beforeAll(async () => {
    originalWorkspaceRoot = process.env['RALPH_DASHBOARD_WORKSPACE_ROOT'];
    originalSkipListen = process.env['RALPH_DASHBOARD_SKIP_LISTEN'];
    originalDashboardGlobal = process.env['RALPH_DASHBOARD_GLOBAL'];
    originalWorkspacesFile = process.env['RALPH_WORKSPACES_FILE'];
    process.env['RALPH_DASHBOARD_SKIP_LISTEN'] = '1';
  });

  beforeEach(async () => {
    clearMergedWorkspaceAllowlistCache();
    clearDashboardRootsCache();
    originalCwd = process.cwd();
    tempRoot = mkdtempSync(join(tmpdir(), 'ralph-dashboard-workspaces-'));
    process.chdir(tempRoot);
    mkdirSync(join(tempRoot, '.ralph-workspace'), { recursive: true });

    const emptyRegistryPath = join(tempRoot, 'empty-workspaces.json');
    writeFileSync(emptyRegistryPath, '[]');

    process.env['RALPH_DASHBOARD_WORKSPACE_ROOT'] = tempRoot;
    process.env['RALPH_WORKSPACES_FILE'] = emptyRegistryPath;
    delete process.env['RALPH_DASHBOARD_GLOBAL'];
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

    if (originalWorkspacesFile === undefined) {
      delete process.env['RALPH_WORKSPACES_FILE'];
    } else {
      process.env['RALPH_WORKSPACES_FILE'] = originalWorkspacesFile;
    }
  });

  it('GET /api/ralph-framework-root returns RALPH_HOME when set', async () => {
    const install = mkdtempSync(join(tmpdir(), 'ralph-api-fw-'));
    const prevHome = process.env['RALPH_HOME'];
    process.env['RALPH_HOME'] = install;
    try {
      const res = await request(app).get('/api/ralph-framework-root');
      expect(res.status).toBe(200);
      expect(res.body.projectRoot).toBe(realpathSync(install));
    } finally {
      if (prevHome === undefined) {
        delete process.env['RALPH_HOME'];
      } else {
        process.env['RALPH_HOME'] = prevHome;
      }
      rmSync(install, { recursive: true, force: true });
    }
  });

  it('returns discovered workspace when registry is empty', async () => {
    const res = await createInMemoryRequester(app).get('/api/workspaces');

    expect(res.status).toBe(200);
    const discovered = res.body.find((w: { projectRoot: string }) => w.projectRoot === tempRoot);
    expect(discovered).toBeDefined();
    const wsPath = join(tempRoot, '.ralph-workspace');
    expect(discovered).toMatchObject({
      path: tempRoot,
      workspaceRoot: wsPath,
      projectRoot: tempRoot,
      label: basename(tempRoot),
      exists: true,
      sections: expect.objectContaining({
        logs: false,
        artifacts: false,
        sessions: false,
        'orchestration-plans': false,
        plans: true,
      }),
    });
    expect(typeof discovered?.sections.docs).toBe('boolean');
  });

  it('returns workspace with exists: true when path exists', async () => {
    const workspacePath = join(tempRoot, 'my-project');
    mkdirSync(join(workspacePath, '.ralph-workspace'), { recursive: true });

    const registryPath = join(tempRoot, 'workspaces.json');
    writeFileSync(
      registryPath,
      JSON.stringify([
        {
          path: workspacePath,
          lastSeen: '2026-04-25T10:00:00Z',
          planKey: 'test-plan',
          runtime: 'claude',
        },
      ]),
    );

    process.env['RALPH_WORKSPACES_FILE'] = registryPath;
    ({ app } = await import('../src/server'));

    const res = await request(app).get('/api/workspaces');

    expect(res.status).toBe(200);
    const byPath = new Map(res.body.map((w: any) => [w.path, w]));
    expect(byPath.get(workspacePath)).toMatchObject({
      path: workspacePath,
      workspaceRoot: join(workspacePath, '.ralph-workspace'),
      projectRoot: workspacePath,
      label: 'my-project',
      exists: true,
      sections: expect.objectContaining({
        plans: true,
        logs: false,
      }),
      lastSeen: '2026-04-25T10:00:00Z',
      planKey: 'test-plan',
      runtime: 'claude',
    });
  });

  it('omits workspace when path was deleted', async () => {
    const deletedPath = join(tempRoot, 'deleted-project');
    const registryPath = join(tempRoot, 'workspaces.json');

    writeFileSync(
      registryPath,
      JSON.stringify([
        {
          path: deletedPath,
          lastSeen: '2026-04-25T09:00:00Z',
          planKey: 'old-plan',
          runtime: 'cursor',
        },
      ]),
    );

    process.env['RALPH_WORKSPACES_FILE'] = registryPath;
    ({ app } = await import('../src/server'));

    const res = await request(app).get('/api/workspaces');

    expect(res.status).toBe(200);
    expect(res.body.some((w: any) => w.path === deletedPath)).toBe(false);
  });

  it('returns existing registry projects and omits deleted paths', async () => {
    const existingPath = join(tempRoot, 'existing-project');
    const deletedPath = join(tempRoot, 'deleted-project');
    mkdirSync(join(existingPath, '.ralph-workspace'), { recursive: true });

    const registryPath = join(tempRoot, 'workspaces.json');
    writeFileSync(
      registryPath,
      JSON.stringify([
        {
          path: existingPath,
          lastSeen: '2026-04-25T10:00:00Z',
          planKey: 'existing-plan',
          runtime: 'claude',
        },
        {
          path: deletedPath,
          lastSeen: '2026-04-25T09:00:00Z',
          planKey: 'deleted-plan',
          runtime: 'cursor',
        },
      ]),
    );

    process.env['RALPH_WORKSPACES_FILE'] = registryPath;
    ({ app } = await import('../src/server'));

    const res = await request(app).get('/api/workspaces');

    expect(res.status).toBe(200);
    expect(res.body.length).toBeGreaterThanOrEqual(2);

    const byPath = new Map(res.body.map((w: any) => [w.path, w]));
    expect(byPath.get(existingPath)).toMatchObject({
      workspaceRoot: join(existingPath, '.ralph-workspace'),
      projectRoot: existingPath,
      label: 'existing-project',
      exists: true,
      planKey: 'existing-plan',
    });
    expect(byPath.has(deletedPath)).toBe(false);
  });

  it('calculates section availability per project', async () => {
    const projectA = join(tempRoot, 'project-a');
    const projectB = join(tempRoot, 'project-b');
    mkdirSync(join(projectA, '.ralph-workspace', 'logs'), { recursive: true });
    mkdirSync(join(projectA, '.ralph-workspace', 'artifacts'), { recursive: true });
    mkdirSync(join(projectA, 'docs'), { recursive: true });
    writeFileSync(join(projectA, 'docs', 'project-a.md'), '# project docs\n');
    mkdirSync(join(projectB, '.ralph-workspace', 'sessions'), { recursive: true });
    mkdirSync(join(projectB, '.ralph-workspace', 'orchestration-plans'), { recursive: true });

    const registryPath = join(tempRoot, 'workspaces.json');
    writeFileSync(
      registryPath,
      JSON.stringify([
        { path: projectA, planKey: 'a' },
        { path: projectB, planKey: 'b' },
      ]),
    );

    process.env['RALPH_WORKSPACES_FILE'] = registryPath;
    ({ app } = await import('../src/server'));

    const res = await request(app).get('/api/workspaces');

    expect(res.status).toBe(200);
    const byPath = new Map(res.body.map((w: any) => [w.path, w]));
    expect(byPath.get(projectA).sections).toMatchObject({
      logs: true,
      artifacts: true,
      sessions: false,
      'orchestration-plans': false,
      docs: true,
      plans: true,
    });
    expect(byPath.get(projectB).sections).toMatchObject({
      logs: false,
      artifacts: false,
      sessions: true,
      'orchestration-plans': true,
      plans: true,
    });
    expect(typeof byPath.get(projectB).sections.docs).toBe('boolean');
    expect(byPath.get(projectB).sections.docs).toBe(false);
  });

  it('does not expose RALPH_HOME docs on projects without their own docs', async () => {
    const install = mkdtempSync(join(tmpdir(), 'ralph-global-harness-'));
    mkdirSync(join(install, 'bundle', '.ralph'), { recursive: true });
    mkdirSync(join(install, 'docs'), { recursive: true });
    writeFileSync(join(install, 'docs', 'README.md'), '# Ralph docs\n');
    writeFileSync(join(install, 'docs', 'INSTALL.md'), '# install\n');

    const project = join(tempRoot, 'other-project');
    mkdirSync(join(project, '.ralph-workspace', 'logs'), { recursive: true });

    const registryPath = join(tempRoot, 'workspaces-global-docs.json');
    writeFileSync(registryPath, JSON.stringify([{ path: project, planKey: 'p' }]));
    process.env['RALPH_WORKSPACES_FILE'] = registryPath;
    const prevHome = process.env['RALPH_HOME'];
    process.env['RALPH_HOME'] = install;
    clearMergedWorkspaceAllowlistCache();
    ({ app } = await import('../src/server'));

    try {
      const res = await request(app).get('/api/workspaces');
      expect(res.status).toBe(200);
      const entry = res.body.find((w: { projectRoot: string }) => w.projectRoot === project);
      expect(entry).toBeDefined();
      expect(entry.sections.docs).toBe(false);
    } finally {
      if (prevHome === undefined) {
        delete process.env['RALPH_HOME'];
      } else {
        process.env['RALPH_HOME'] = prevHome;
      }
      clearMergedWorkspaceAllowlistCache();
    }
  });

  it('includes RALPH_HOME in /api/workspaces when install has bundle/.ralph', async () => {
    const install = mkdtempSync(join(tmpdir(), 'ralph-global-harness-'));
    mkdirSync(join(install, 'bundle', '.ralph'), { recursive: true });
    mkdirSync(join(install, 'docs'), { recursive: true });
    writeFileSync(join(install, 'bundle', '.ralph', 'run-plan.sh'), '# stub\n');
    writeFileSync(join(install, 'docs', 'README.md'), '# Ralph docs\n');
    const prevHome = process.env['RALPH_HOME'];
    process.env['RALPH_HOME'] = install;
    clearMergedWorkspaceAllowlistCache();
    try {
      const res = await request(app).get('/api/workspaces');
      expect(res.status).toBe(200);
      const resolvedInstall = realpathSync(install);
      const fw = res.body.find((w: { projectRoot: string }) => w.projectRoot === resolvedInstall);
      expect(fw).toBeDefined();
      expect(fw).toMatchObject({
        exists: true,
        projectRoot: resolvedInstall,
        label: 'Ralph docs',
        sections: expect.objectContaining({
          docs: true,
          logs: false,
          artifacts: false,
          sessions: false,
          'orchestration-plans': false,
          plans: false,
        }),
      });
    } finally {
      if (prevHome === undefined) {
        delete process.env['RALPH_HOME'];
      } else {
        process.env['RALPH_HOME'] = prevHome;
      }
      rmSync(install, { recursive: true, force: true });
      clearMergedWorkspaceAllowlistCache();
    }
  });

  describe('workspace allowlist helpers', () => {
    it('getMergedWorkspaceAllowlist matches /api/workspaces', async () => {
      const fromFn = await getMergedWorkspaceAllowlist();
      const res = await request(app).get('/api/workspaces');
      expect(res.status).toBe(200);
      expect(fromFn).toEqual(res.body);
    });

    it('resolveDashboardRootsForRequest uses findDashboardRoots when query blank', async () => {
      const allow = await getMergedWorkspaceAllowlist();
      const expected = findDashboardRoots();
      expect(resolveDashboardRootsForRequest(undefined, allow)).toEqual(expected);
      expect(resolveDashboardRootsForRequest('', allow)).toEqual(expected);
      expect(resolveDashboardRootsForRequest('  \t ', allow)).toEqual(expected);
    });

    it('resolveDashboardRootsForRequest resolves allowed project', async () => {
      const allow = await getMergedWorkspaceAllowlist();
      const resolved = resolveDashboardRootsForRequest(tempRoot, allow);
      expect(resolved).toEqual({
        projectRoot: tempRoot,
        workspaceRoot: join(tempRoot, '.ralph-workspace'),
      });
    });

    it('resolveDashboardRootsForRequest returns null for path outside allowlist', async () => {
      const allow = await getMergedWorkspaceAllowlist();
      const outside = join(tempRoot, 'outside');
      mkdirSync(outside, { recursive: true });
      expect(resolveDashboardRootsForRequest(outside, allow)).toBeNull();
    });

    it('resolveDashboardRootsForRequest accepts Ralph install root when not on allowlist', () => {
      const install = realpathSync(mkdtempSync(join(tmpdir(), 'ralph-fw-root-')));
      const prevHome = process.env['RALPH_HOME'];
      process.env['RALPH_HOME'] = install;
      try {
        const roots = resolveDashboardRootsForRequest(install, []);
        expect(roots).not.toBeNull();
        expect(roots!.projectRoot).toBe(resolveRalphInstallRoot());
      } finally {
        if (prevHome === undefined) {
          delete process.env['RALPH_HOME'];
        } else {
          process.env['RALPH_HOME'] = prevHome;
        }
        rmSync(install, { recursive: true, force: true });
      }
    });
  });

  describe('projectRoot on list file template', () => {
    it('rejects invalid projectRoot for plans list', async () => {
      const res = await request(app).get(
        `/api/list?root=plans&path=&projectRoot=${encodeURIComponent(join(tmpdir(), 'ralph-nonexistent-project-root'))}`,
      );
      expect(res.status).toBe(400);
      expect(res.body).toMatchObject({ error: 'invalid projectRoot' });
    });

    it('does not reject invalid projectRoot for aggregated logs list', async () => {
      const res = await request(app).get(
        `/api/list?root=logs&path=&projectRoot=${encodeURIComponent(join(tmpdir(), 'ralph-ignored-for-logs'))}`,
      );
      expect(res.status).toBe(200);
    });

    it('lists plans from a nested discovered workspace when projectRoot is set', async () => {
      const nestedProject = join(tempRoot, 'nested-proj');
      mkdirSync(join(nestedProject, '.ralph-workspace'), { recursive: true });
      writeFileSync(join(nestedProject, 'plan-nested.md'), '# nested');

      const res = await request(app).get(
        `/api/list?root=plans&path=&projectRoot=${encodeURIComponent(nestedProject)}`,
      );
      expect(res.status).toBe(200);
      const names = (res.body.entries as Array<{ name: string }>).map((e) => e.name);
      expect(names).toContain('plan-nested.md');
    });

    it('rejects invalid projectRoot for template', async () => {
      const res = await request(app).get(
        `/api/template?name=plan&projectRoot=${encodeURIComponent(join(tmpdir(), 'no-such-template-root'))}`,
      );
      expect(res.status).toBe(400);
      expect(res.body).toMatchObject({ error: 'invalid projectRoot' });
    });

    it('rejects invalid projectRoot for file', async () => {
      const res = await request(app).get(
        `/api/file?root=plans&path=any.md&offset=0&projectRoot=${encodeURIComponent(join(tmpdir(), 'no-such-file-root'))}`,
      );
      expect(res.status).toBe(400);
      expect(res.body).toMatchObject({ error: 'invalid projectRoot' });
    });

    it('rejects invalid projectRoot for docs list', async () => {
      const res = await request(app).get(
        `/api/list?root=docs&path=&projectRoot=${encodeURIComponent(join(tmpdir(), 'ralph-bad-docs-root'))}`,
      );
      expect(res.status).toBe(400);
      expect(res.body).toMatchObject({ error: 'invalid projectRoot' });
    });

    it('returns plan file content for /api/file when projectRoot matches nested project', async () => {
      const nestedProject = join(tempRoot, 'nested-proj');
      mkdirSync(join(nestedProject, '.ralph-workspace'), { recursive: true });
      writeFileSync(join(nestedProject, 'plan-nested.md'), '# nested body');

      const res = await request(app).get(
        `/api/file?root=plans&path=${encodeURIComponent('plan-nested.md')}&offset=0&projectRoot=${encodeURIComponent(nestedProject)}`,
      );
      expect(res.status).toBe(200);
      expect(res.body.content).toContain('nested body');
    });

    it('lists docs from nested project when projectRoot is set', async () => {
      const nestedProject = join(tempRoot, 'nested-proj');
      mkdirSync(join(nestedProject, '.ralph-workspace'), { recursive: true });
      mkdirSync(join(nestedProject, 'docs'), { recursive: true });
      writeFileSync(join(nestedProject, 'docs', 'scoped-doc.md'), '# doc');

      const res = await request(app).get(
        `/api/list?root=docs&path=&projectRoot=${encodeURIComponent(nestedProject)}`,
      );
      expect(res.status).toBe(200);
      const names = (res.body.entries as Array<{ name: string }>).map((e) => e.name);
      expect(names).toContain('scoped-doc.md');
    });
  });
});
