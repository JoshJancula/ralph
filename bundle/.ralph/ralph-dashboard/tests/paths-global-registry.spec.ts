import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

import { dashboardGlobalMode, clearWorkspaceRootsCache, findAllWorkspaceRoots, readRegistryWorkspacePaths } from '../src/paths';

describe('dashboardGlobalMode', () => {
  const original = process.env['RALPH_DASHBOARD_GLOBAL'];

  afterEach(() => {
    if (original === undefined) {
      delete process.env['RALPH_DASHBOARD_GLOBAL'];
    } else {
      process.env['RALPH_DASHBOARD_GLOBAL'] = original;
    }
  });

  it('returns true when RALPH_DASHBOARD_GLOBAL=1', () => {
    process.env['RALPH_DASHBOARD_GLOBAL'] = '1';
    expect(dashboardGlobalMode()).toBe(true);
  });

  it('returns false when RALPH_DASHBOARD_GLOBAL is unset', () => {
    delete process.env['RALPH_DASHBOARD_GLOBAL'];
    expect(dashboardGlobalMode()).toBe(false);
  });

  it('returns false when RALPH_DASHBOARD_GLOBAL is set to something other than 1', () => {
    process.env['RALPH_DASHBOARD_GLOBAL'] = '0';
    expect(dashboardGlobalMode()).toBe(false);
  });
});

describe('readRegistryWorkspacePaths', () => {
  let tempDir = '';
  const originalWorkspacesFile = process.env['RALPH_WORKSPACES_FILE'];

  beforeEach(() => {
    tempDir = mkdtempSync(join(tmpdir(), 'ralph-registry-test-'));
  });

  afterEach(() => {
    rmSync(tempDir, { recursive: true, force: true });
    if (originalWorkspacesFile === undefined) {
      delete process.env['RALPH_WORKSPACES_FILE'];
    } else {
      process.env['RALPH_WORKSPACES_FILE'] = originalWorkspacesFile;
    }
  });

  it('returns empty array when registry file does not exist', () => {
    process.env['RALPH_WORKSPACES_FILE'] = join(tempDir, 'nonexistent.json');
    expect(readRegistryWorkspacePaths()).toEqual([]);
  });

  it('returns empty array for invalid JSON', () => {
    const regFile = join(tempDir, 'workspaces.json');
    writeFileSync(regFile, 'not json');
    process.env['RALPH_WORKSPACES_FILE'] = regFile;
    expect(readRegistryWorkspacePaths()).toEqual([]);
  });

  it('returns empty array for a non-array JSON value', () => {
    const regFile = join(tempDir, 'workspaces.json');
    writeFileSync(regFile, JSON.stringify({ path: '/tmp' }));
    process.env['RALPH_WORKSPACES_FILE'] = regFile;
    expect(readRegistryWorkspacePaths()).toEqual([]);
  });

  it('returns .ralph-workspace paths for valid registry entries that exist on disk', () => {
    const wsDir = join(tempDir, 'project');
    mkdirSync(join(wsDir, '.ralph-workspace', 'logs'), { recursive: true });
    const regFile = join(tempDir, 'workspaces.json');
    writeFileSync(regFile, JSON.stringify([
      { path: wsDir, lastSeen: '2026-04-17T00:00:00Z', planKey: 'p1', runtime: 'claude' },
    ]));
    process.env['RALPH_WORKSPACES_FILE'] = regFile;
    const paths = readRegistryWorkspacePaths();
    expect(paths).toHaveLength(1);
    expect(paths[0]).toContain('.ralph-workspace');
  });

  it('skips entries whose .ralph-workspace directory does not exist', () => {
    const regFile = join(tempDir, 'workspaces.json');
    writeFileSync(regFile, JSON.stringify([
      { path: join(tempDir, 'no-such-dir'), lastSeen: '2026-04-17T00:00:00Z' },
    ]));
    process.env['RALPH_WORKSPACES_FILE'] = regFile;
    expect(readRegistryWorkspacePaths()).toEqual([]);
  });

  it('deduplicates entries with the same resolved path', () => {
    const wsDir = join(tempDir, 'project');
    mkdirSync(join(wsDir, '.ralph-workspace', 'logs'), { recursive: true });
    const regFile = join(tempDir, 'workspaces.json');
    writeFileSync(regFile, JSON.stringify([
      { path: wsDir, lastSeen: '2026-04-17T00:00:00Z', planKey: 'p1', runtime: 'claude' },
      { path: wsDir, lastSeen: '2026-04-18T00:00:00Z', planKey: 'p2', runtime: 'codex' },
    ]));
    process.env['RALPH_WORKSPACES_FILE'] = regFile;
    const paths = readRegistryWorkspacePaths();
    expect(paths).toHaveLength(1);
  });

  it('skips entries with missing or non-string path field', () => {
    const wsDir = join(tempDir, 'project');
    mkdirSync(join(wsDir, '.ralph-workspace'), { recursive: true });
    const regFile = join(tempDir, 'workspaces.json');
    writeFileSync(regFile, JSON.stringify([
      { path: wsDir, lastSeen: '2026-04-17T00:00:00Z' },
      {},
      { lastSeen: '2026-04-17T00:00:00Z' },
      { path: 42, lastSeen: '2026-04-17T00:00:00Z' },
      { path: '', lastSeen: '2026-04-17T00:00:00Z' },
    ]));
    process.env['RALPH_WORKSPACES_FILE'] = regFile;
    const paths = readRegistryWorkspacePaths();
    expect(paths).toHaveLength(1);
  });
});

describe('findAllWorkspaceRoots', () => {
  let tempDir = '';
  const originalDashboardFull = process.env['RALPH_DASHBOARD_FULL'];
  const originalDashboardGlobal = process.env['RALPH_DASHBOARD_GLOBAL'];
  const originalDashboardProjectRoot = process.env['RALPH_DASHBOARD_PROJECT_ROOT'];
  const originalDashboardWorkspaceRoot = process.env['RALPH_DASHBOARD_WORKSPACE_ROOT'];
  const originalWorkspacesFile = process.env['RALPH_WORKSPACES_FILE'];
  const originalHome = process.env['HOME'];

  beforeEach(() => {
    tempDir = mkdtempSync(join(tmpdir(), 'ralph-full-roots-'));
    clearWorkspaceRootsCache();
  });

  afterEach(() => {
    rmSync(tempDir, { recursive: true, force: true });
    clearWorkspaceRootsCache();

    if (originalDashboardFull === undefined) {
      delete process.env['RALPH_DASHBOARD_FULL'];
    } else {
      process.env['RALPH_DASHBOARD_FULL'] = originalDashboardFull;
    }

    if (originalDashboardGlobal === undefined) {
      delete process.env['RALPH_DASHBOARD_GLOBAL'];
    } else {
      process.env['RALPH_DASHBOARD_GLOBAL'] = originalDashboardGlobal;
    }

    if (originalDashboardProjectRoot === undefined) {
      delete process.env['RALPH_DASHBOARD_PROJECT_ROOT'];
    } else {
      process.env['RALPH_DASHBOARD_PROJECT_ROOT'] = originalDashboardProjectRoot;
    }

    if (originalDashboardWorkspaceRoot === undefined) {
      delete process.env['RALPH_DASHBOARD_WORKSPACE_ROOT'];
    } else {
      process.env['RALPH_DASHBOARD_WORKSPACE_ROOT'] = originalDashboardWorkspaceRoot;
    }

    if (originalWorkspacesFile === undefined) {
      delete process.env['RALPH_WORKSPACES_FILE'];
    } else {
      process.env['RALPH_WORKSPACES_FILE'] = originalWorkspacesFile;
    }

    if (originalHome === undefined) {
      delete process.env['HOME'];
    } else {
      process.env['HOME'] = originalHome;
    }
  });

  it('includes registry and nested HOME workspaces in full mode', () => {
    const homeRoot = join(tempDir, 'home');
    const projectRoot = join(tempDir, 'project');
    const registryWorkspace = join(homeRoot, 'projects', 'alpha');
    const discoveredWorkspace = join(homeRoot, 'Documents', 'projects', 'team', 'beta');

    mkdirSync(join(projectRoot, '.ralph'), { recursive: true });
    mkdirSync(join(registryWorkspace, '.ralph-workspace', 'logs'), { recursive: true });
    mkdirSync(join(discoveredWorkspace, '.ralph-workspace', 'logs'), { recursive: true });

    const regFile = join(tempDir, 'workspaces.json');
    writeFileSync(
      regFile,
      JSON.stringify([
        { path: registryWorkspace, lastSeen: '2026-04-17T00:00:00Z', planKey: 'registry-plan', runtime: 'claude' },
      ]),
    );

    process.env['RALPH_DASHBOARD_FULL'] = '1';
    process.env['RALPH_DASHBOARD_PROJECT_ROOT'] = projectRoot;
    process.env['RALPH_WORKSPACES_FILE'] = regFile;
    process.env['HOME'] = homeRoot;

    const roots = findAllWorkspaceRoots();

    expect(roots).toEqual(
      expect.arrayContaining([
        join(registryWorkspace, '.ralph-workspace'),
        join(discoveredWorkspace, '.ralph-workspace'),
      ]),
    );
  });

  it('includes registry and nested HOME workspaces in global mode', () => {
    const homeRoot = join(tempDir, 'home');
    const projectRoot = join(tempDir, 'project');
    const registryWorkspace = join(homeRoot, 'projects', 'alpha');
    const discoveredWorkspace = join(homeRoot, 'Documents', 'projects', 'team', 'beta');

    mkdirSync(join(projectRoot, '.ralph'), { recursive: true });
    mkdirSync(join(registryWorkspace, '.ralph-workspace', 'logs'), { recursive: true });
    mkdirSync(join(discoveredWorkspace, '.ralph-workspace', 'logs'), { recursive: true });

    const regFile = join(tempDir, 'workspaces.json');
    writeFileSync(
      regFile,
      JSON.stringify([
        { path: registryWorkspace, lastSeen: '2026-04-17T00:00:00Z', planKey: 'registry-plan', runtime: 'claude' },
      ]),
    );

    delete process.env['RALPH_DASHBOARD_FULL'];
    process.env['RALPH_DASHBOARD_GLOBAL'] = '1';
    process.env['RALPH_DASHBOARD_PROJECT_ROOT'] = projectRoot;
    process.env['RALPH_WORKSPACES_FILE'] = regFile;
    process.env['HOME'] = homeRoot;

    const roots = findAllWorkspaceRoots();

    expect(roots).toEqual(
      expect.arrayContaining([
        join(registryWorkspace, '.ralph-workspace'),
        join(discoveredWorkspace, '.ralph-workspace'),
      ]),
    );
  });
});
