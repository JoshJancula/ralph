import { mkdirSync, mkdtempSync, realpathSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

import { findWorkspaceProjectRoot } from '../src/paths';

function withProjectRootEnv(
  envKey: 'RALPH_DASHBOARD_PROJECT_ROOT' | 'RALPH_PROJECT_ROOT',
  envValue: string,
  callback: () => void,
): void {
  const originalDashboardRoot = process.env['RALPH_DASHBOARD_PROJECT_ROOT'];
  const originalProjectRoot = process.env['RALPH_PROJECT_ROOT'];

  try {
    if (envKey === 'RALPH_DASHBOARD_PROJECT_ROOT') {
      process.env['RALPH_DASHBOARD_PROJECT_ROOT'] = envValue;
      delete process.env['RALPH_PROJECT_ROOT'];
    } else {
      process.env['RALPH_PROJECT_ROOT'] = envValue;
      delete process.env['RALPH_DASHBOARD_PROJECT_ROOT'];
    }

    callback();
  } finally {
    if (originalDashboardRoot === undefined) {
      delete process.env['RALPH_DASHBOARD_PROJECT_ROOT'];
    } else {
      process.env['RALPH_DASHBOARD_PROJECT_ROOT'] = originalDashboardRoot;
    }

    if (originalProjectRoot === undefined) {
      delete process.env['RALPH_PROJECT_ROOT'];
    } else {
      process.env['RALPH_PROJECT_ROOT'] = originalProjectRoot;
    }
  }
}

describe('findWorkspaceProjectRoot', () => {
  for (const envKey of ['RALPH_DASHBOARD_PROJECT_ROOT', 'RALPH_PROJECT_ROOT'] as const) {
    it(`falls back to walk-up discovery when ${envKey} has no .ralph directory`, () => {
      const originalCwd = process.cwd();
      const tempRoot = realpathSync(mkdtempSync(join(tmpdir(), 'ralph-dashboard-root-')));
      const expectedProjectRoot = join(tempRoot, 'project');
      mkdirSync(join(expectedProjectRoot, '.ralph'), { recursive: true });
      const invalidRoot = join(tempRoot, 'workspace');
      mkdirSync(invalidRoot, { recursive: true });
      const nestedDir = join(expectedProjectRoot, 'nested');
      mkdirSync(nestedDir, { recursive: true });

      try {
        process.chdir(nestedDir);
        withProjectRootEnv(envKey, invalidRoot, () => {
          expect(findWorkspaceProjectRoot()).toBe(expectedProjectRoot);
        });
      } finally {
        process.chdir(originalCwd);
        rmSync(tempRoot, { recursive: true, force: true });
      }
    });
  }
});
