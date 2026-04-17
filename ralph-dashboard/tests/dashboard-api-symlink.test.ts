import { mkdirSync, mkdtempSync, rmSync, symlinkSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

import { getAllowedRoots, resolveUnderRoot } from '../src/paths';

describe('resolveUnderRoot symlink containment', () => {
  let workspaceRoot = '';
  let outsideRoot = '';

  beforeEach(() => {
    workspaceRoot = mkdtempSync(join(tmpdir(), 'ralph-workspace-'));
    mkdirSync(workspaceRoot, { recursive: true });
  });

  afterEach(() => {
    if (workspaceRoot) {
      rmSync(workspaceRoot, { recursive: true, force: true });
      workspaceRoot = '';
    }
    if (outsideRoot) {
      rmSync(outsideRoot, { recursive: true, force: true });
      outsideRoot = '';
    }
  });

  it('throws when a symlink in the root points outside the workspace', () => {
    const roots = getAllowedRoots({
      projectRoot: workspaceRoot,
      workspaceRoot: join(workspaceRoot, '.ralph-workspace'),
    });
    const plansRoot = roots.plans;
    mkdirSync(plansRoot.basePath, { recursive: true });

    outsideRoot = mkdtempSync(join(tmpdir(), 'ralph-outside-'));
    const outsideFile = join(outsideRoot, 'secret.txt');
    writeFileSync(outsideFile, 'sensitive');

    const symlinkPath = join(plansRoot.basePath, 'escape');
    symlinkSync(outsideRoot, symlinkPath, 'dir');

    expect(() => resolveUnderRoot(plansRoot, 'escape/secret.txt')).toThrow('path escape');
  });
});
