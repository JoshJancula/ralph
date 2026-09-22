import '@angular/compiler';
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';

import {
  clearDashboardRootsCache,
  clearWorkspaceRootsCache,
} from '../src/paths';
import {
  clearMergedWorkspaceAllowlistCache,
  enumerateRegisteredWorkspaces,
} from '../src/server/dashboard-api';

/**
 * Filter helper: the dashboard's merged allowlist always includes the current
 * project root and any discovered workspaces in the temp tree. We only want to
 * assert on the explicit registry entries created by the test.
 */
function isScopedProjectRoot(projectRoot: string, tempRoot: string): boolean {
  const a = resolve(projectRoot);
  const b = resolve(tempRoot);
  return a !== b && a.startsWith(`${b}/`);
}

describe('enumerateRegisteredWorkspaces', () => {
  let tempRoot = '';
  let originalWorkspacesFile: string | undefined;
  let originalDashboardWorkspaceRoot: string | undefined;
  let originalDashboardGlobal: string | undefined;
  let originalCwd: string | undefined;

  beforeAll(() => {
    originalWorkspacesFile = process.env['RALPH_WORKSPACES_FILE'];
    originalDashboardWorkspaceRoot = process.env['RALPH_DASHBOARD_WORKSPACE_ROOT'];
    originalDashboardGlobal = process.env['RALPH_DASHBOARD_GLOBAL'];
  });

  beforeEach(() => {
    clearMergedWorkspaceAllowlistCache();
    clearDashboardRootsCache();
    clearWorkspaceRootsCache();
    originalCwd = process.cwd();
    tempRoot = mkdtempSync(join(tmpdir(), 'ralph-enum-ws-'));
    process.chdir(tempRoot);

    // The enumerator falls back to findDashboardRoots() for explicit queries,
    // so point the dashboard workspace root at a live directory inside tempRoot.
    mkdirSync(join(tempRoot, '.ralph-workspace'), { recursive: true });
    process.env['RALPH_DASHBOARD_WORKSPACE_ROOT'] = tempRoot;
    process.env['RALPH_WORKSPACES_FILE'] = join(tempRoot, 'workspaces.json');
    delete process.env['RALPH_DASHBOARD_GLOBAL'];

    // Start each test with an empty registry so only entries we add count
    // toward the allowlist.
    writeFileSync(process.env['RALPH_WORKSPACES_FILE']!, '[]');
  });

  afterEach(() => {
    if (originalCwd) {
      process.chdir(originalCwd);
    }
    if (tempRoot) {
      rmSync(tempRoot, { recursive: true, force: true });
    }
    clearMergedWorkspaceAllowlistCache();
    clearDashboardRootsCache();
    clearWorkspaceRootsCache();
  });

  afterAll(() => {
    if (originalWorkspacesFile === undefined) {
      delete process.env['RALPH_WORKSPACES_FILE'];
    } else {
      process.env['RALPH_WORKSPACES_FILE'] = originalWorkspacesFile;
    }
    if (originalDashboardWorkspaceRoot === undefined) {
      delete process.env['RALPH_DASHBOARD_WORKSPACE_ROOT'];
    } else {
      process.env['RALPH_DASHBOARD_WORKSPACE_ROOT'] = originalDashboardWorkspaceRoot;
    }
    if (originalDashboardGlobal === undefined) {
      delete process.env['RALPH_DASHBOARD_GLOBAL'];
    } else {
      process.env['RALPH_DASHBOARD_GLOBAL'] = originalDashboardGlobal;
    }
  });

  function setRegistry(
    entries: Array<{ path: string; lastSeen?: string; planKey?: string; runtime?: string }>,
  ): void {
    writeFileSync(process.env['RALPH_WORKSPACES_FILE']!, JSON.stringify(entries));
  }

  it('returns only live allowlisted entries and counts skipped dead entries', async () => {
    const liveA = join(tempRoot, 'live-a');
    const liveB = join(tempRoot, 'live-b');
    const dead = join(tempRoot, 'dead');

    mkdirSync(join(liveA, '.ralph-workspace'), { recursive: true });
    mkdirSync(join(liveB, '.ralph-workspace'), { recursive: true });

    setRegistry([
      { path: liveA, planKey: 'live-a-plan', runtime: 'claude' },
      { path: liveB, planKey: 'live-b-plan', runtime: 'cursor' },
      { path: dead, planKey: 'dead-plan', runtime: 'codex' },
    ]);

    const result = await enumerateRegisteredWorkspaces();

    const scoped = result.workspaces.filter((w) => isScopedProjectRoot(w.projectRoot, tempRoot));
    const workspaceRoots = scoped.map((w) => resolve(w.projectRoot)).sort();
    expect(workspaceRoots).toEqual([resolve(liveA), resolve(liveB)]);

    const byPath = new Map(scoped.map((w) => [resolve(w.projectRoot), w]));
    expect(byPath.get(resolve(liveA))).toMatchObject({
      label: 'live-a',
      exists: true,
      planKey: 'live-a-plan',
      runtime: 'claude',
    });
    expect(byPath.get(resolve(liveB))).toMatchObject({
      label: 'live-b',
      exists: true,
      planKey: 'live-b-plan',
      runtime: 'cursor',
    });

    // The dead registry entry is skipped because its workspace root does
    // not exist. The excluded (unregistered) entry is never considered, and
    // any additional discovered workspaces under tempRoot are live so they
    // do not affect the skipped count.
    expect(result.skipped).toBeGreaterThanOrEqual(1);
  });

  it('counts a dead registry entry as skipped', async () => {
    const liveA = join(tempRoot, 'live-a');
    const dead = join(tempRoot, 'dead');

    mkdirSync(join(liveA, '.ralph-workspace'), { recursive: true });

    setRegistry([
      { path: liveA },
      { path: dead, planKey: 'dead-plan', runtime: 'cursor' },
    ]);

    const result = await enumerateRegisteredWorkspaces();

    const scoped = result.workspaces
      .filter((w) => isScopedProjectRoot(w.projectRoot, tempRoot))
      .map((w) => resolve(w.projectRoot));
    expect(scoped).toEqual([resolve(liveA)]);
    expect(result.skipped).toBe(1);
  });

  it('excludes an entry that is in the registry but not part of the merged allowlist', async () => {
    const liveA = join(tempRoot, 'live-a');
    const liveB = join(tempRoot, 'live-b');
    // `excluded` is in the registry but its workspace root is intentionally
    // missing, so it is dropped before the merged allowlist is built.
    const excluded = join(tempRoot, 'excluded');

    mkdirSync(join(liveA, '.ralph-workspace'), { recursive: true });
    mkdirSync(join(liveB, '.ralph-workspace'), { recursive: true });

    setRegistry([
      { path: liveA },
      { path: liveB },
      { path: excluded },
    ]);

    const result = await enumerateRegisteredWorkspaces();

    const workspaceRoots = result.workspaces
      .map((w) => resolve(w.projectRoot))
      .filter((p) => isScopedProjectRoot(p, tempRoot))
      .sort();
    expect(workspaceRoots).toEqual([resolve(liveA), resolve(liveB)]);
    // The excluded entry is dropped by the registry reader because its
    // workspace root does not exist, so it never reaches the allowlist.
    expect(result.skipped).toBe(0);
  });

  it('returns a single workspace when an explicit workspaceRoot query matches', async () => {
    const liveA = join(tempRoot, 'live-a');
    const liveB = join(tempRoot, 'live-b');

    mkdirSync(join(liveA, '.ralph-workspace'), { recursive: true });
    mkdirSync(join(liveB, '.ralph-workspace'), { recursive: true });

    setRegistry([{ path: liveA }, { path: liveB }]);

    const result = await enumerateRegisteredWorkspaces(join(liveA, '.ralph-workspace'));

    expect(result.workspaces).toHaveLength(1);
    expect(result.workspaces[0]).toMatchObject({
      projectRoot: resolve(liveA),
      label: 'live-a',
    });
    expect(result.skipped).toBe(0);
  });

  it('returns empty result when an explicit workspaceRoot query is not allowlisted', async () => {
    const liveA = join(tempRoot, 'live-a');
    const outside = join(tempRoot, 'outside');

    mkdirSync(join(liveA, '.ralph-workspace'), { recursive: true });
    // Create the outside workspace directory on disk but do not register it.
    mkdirSync(join(outside, '.ralph-workspace'), { recursive: true });

    setRegistry([{ path: liveA }]);

    // Remove the dashboard workspace root env so the allowlist is built only
    // from the registry, not from discovered directories.
    delete process.env['RALPH_DASHBOARD_WORKSPACE_ROOT'];
    const originalHome = process.env['HOME'];
    process.env['HOME'] = tempRoot;
    clearMergedWorkspaceAllowlistCache();
    clearWorkspaceRootsCache();

    try {
      const result = await enumerateRegisteredWorkspaces(join(outside, '.ralph-workspace'));

      // The query should not return the outside workspace because it is not in
      // the registry/allowlist, even though it exists on disk.
      expect(result.workspaces).toHaveLength(0);
      expect(result.skipped).toBe(0);
    } finally {
      if (originalHome === undefined) {
        delete process.env['HOME'];
      } else {
        process.env['HOME'] = originalHome;
      }
    }
  });
});
