import { mkdirSync, mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

import { findWorkspaceProjectRoot } from '../src/paths';

function withWorkspaceRootEnv(
  envKey: 'RALPH_PLAN_WORKSPACE_ROOT' | 'RALPH_DASHBOARD_WORKSPACE_ROOT',
  envValue: string,
  callback: () => void,
): void {
  const originalPlanRoot = process.env['RALPH_PLAN_WORKSPACE_ROOT'];
  const originalDashboardRoot = process.env['RALPH_DASHBOARD_WORKSPACE_ROOT'];

  try {
    if (envKey === 'RALPH_PLAN_WORKSPACE_ROOT') {
      process.env['RALPH_PLAN_WORKSPACE_ROOT'] = envValue;
      delete process.env['RALPH_DASHBOARD_WORKSPACE_ROOT'];
    } else {
      process.env['RALPH_DASHBOARD_WORKSPACE_ROOT'] = envValue;
      delete process.env['RALPH_PLAN_WORKSPACE_ROOT'];
    }

    callback();
  } finally {
    if (originalPlanRoot === undefined) {
      delete process.env['RALPH_PLAN_WORKSPACE_ROOT'];
    } else {
      process.env['RALPH_PLAN_WORKSPACE_ROOT'] = originalPlanRoot;
    }

    if (originalDashboardRoot === undefined) {
      delete process.env['RALPH_DASHBOARD_WORKSPACE_ROOT'];
    } else {
      process.env['RALPH_DASHBOARD_WORKSPACE_ROOT'] = originalDashboardRoot;
    }
  }
}

describe('findWorkspaceProjectRoot', () => {
  const repoRoot = resolve(dirname(fileURLToPath(import.meta.url)), '../..');

  for (const envKey of ['RALPH_PLAN_WORKSPACE_ROOT', 'RALPH_DASHBOARD_WORKSPACE_ROOT'] as const) {
    it(`falls back to walk-up discovery when ${envKey} has no .ralph-workspace directory`, () => {
      const tempRoot = mkdtempSync(join(tmpdir(), 'ralph-dashboard-root-'));
      const invalidRoot = join(tempRoot, 'workspace');
      mkdirSync(invalidRoot, { recursive: true });

      try {
        withWorkspaceRootEnv(envKey, invalidRoot, () => {
          expect(findWorkspaceProjectRoot()).toBe(repoRoot);
        });
      } finally {
        rmSync(tempRoot, { recursive: true, force: true });
      }
    });
  }
});
