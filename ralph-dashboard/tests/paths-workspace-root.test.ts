import { mkdirSync, mkdtempSync, realpathSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

import { findDashboardRoots } from '../src/paths';

describe('determineWorkspaceRoot populated-workspace preference', () => {
  let tempRoot = '';
  let originalCwd = '';
  let originalDashboardProjectRoot: string | undefined;
  let originalProjectRoot: string | undefined;
  let originalDashboardWorkspaceRoot: string | undefined;
  let originalWorkspaceRoot: string | undefined;

  beforeEach(() => {
    originalCwd = process.cwd();
    originalDashboardProjectRoot = process.env['RALPH_DASHBOARD_PROJECT_ROOT'];
    originalProjectRoot = process.env['RALPH_PROJECT_ROOT'];
    originalDashboardWorkspaceRoot = process.env['RALPH_DASHBOARD_WORKSPACE_ROOT'];
    originalWorkspaceRoot = process.env['RALPH_PLAN_WORKSPACE_ROOT'];

    delete process.env['RALPH_DASHBOARD_PROJECT_ROOT'];
    delete process.env['RALPH_PROJECT_ROOT'];
    delete process.env['RALPH_DASHBOARD_WORKSPACE_ROOT'];
    delete process.env['RALPH_PLAN_WORKSPACE_ROOT'];

    tempRoot = realpathSync(mkdtempSync(join(tmpdir(), 'ralph-dashboard-workspace-')));
  });

  afterEach(() => {
    process.chdir(originalCwd);
    if (tempRoot) {
      rmSync(tempRoot, { recursive: true, force: true });
    }
    const restore = (key: string, value: string | undefined) => {
      if (value === undefined) {
        delete process.env[key];
      } else {
        process.env[key] = value;
      }
    };
    restore('RALPH_DASHBOARD_PROJECT_ROOT', originalDashboardProjectRoot);
    restore('RALPH_PROJECT_ROOT', originalProjectRoot);
    restore('RALPH_DASHBOARD_WORKSPACE_ROOT', originalDashboardWorkspaceRoot);
    restore('RALPH_PLAN_WORKSPACE_ROOT', originalWorkspaceRoot);
  });

  it('prefers a populated .ralph-workspace over a stray empty one when walking up from CWD', () => {
    const populatedProject = join(tempRoot, 'populated');
    mkdirSync(join(populatedProject, '.ralph'), { recursive: true });
    mkdirSync(join(populatedProject, '.ralph-workspace', 'logs'), { recursive: true });

    const strayChild = join(populatedProject, 'subdir');
    mkdirSync(join(strayChild, '.ralph-workspace'), { recursive: true });

    process.chdir(strayChild);
    const { workspaceRoot } = findDashboardRoots();
    expect(workspaceRoot).toBe(join(populatedProject, '.ralph-workspace'));
  });

  it('returns the matched .ralph-workspace path itself, not its parent directory', () => {
    const projectDir = join(tempRoot, 'project');
    mkdirSync(join(projectDir, '.ralph'), { recursive: true });
    mkdirSync(join(projectDir, '.ralph-workspace', 'artifacts'), { recursive: true });

    process.chdir(projectDir);
    const { workspaceRoot } = findDashboardRoots();
    expect(workspaceRoot).toBe(join(projectDir, '.ralph-workspace'));
  });

  it('falls back to the first (empty) match if no populated workspace exists on the path', () => {
    const projectDir = join(tempRoot, 'only-empty');
    mkdirSync(join(projectDir, '.ralph'), { recursive: true });
    mkdirSync(join(projectDir, '.ralph-workspace'), { recursive: true });

    process.chdir(projectDir);
    const { workspaceRoot } = findDashboardRoots();
    expect(workspaceRoot).toBe(join(projectDir, '.ralph-workspace'));
  });
});
