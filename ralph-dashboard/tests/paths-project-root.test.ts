import { mkdirSync, mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

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
  const repoRoot = resolve(dirname(fileURLToPath(import.meta.url)), '../..');

  for (const envKey of ['RALPH_DASHBOARD_PROJECT_ROOT', 'RALPH_PROJECT_ROOT'] as const) {
    it(`falls back to walk-up discovery when ${envKey} has no .ralph directory`, () => {
      const tempRoot = mkdtempSync(join(tmpdir(), 'ralph-dashboard-root-'));
      const invalidRoot = join(tempRoot, 'workspace');
      mkdirSync(invalidRoot, { recursive: true });

      try {
        withProjectRootEnv(envKey, invalidRoot, () => {
          expect(findWorkspaceProjectRoot()).toBe(repoRoot);
        });
      } finally {
        rmSync(tempRoot, { recursive: true, force: true });
      }
    });
  }
});
