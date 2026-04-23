import { mkdirSync, mkdtempSync, readdirSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

import { filterVisibleEntryNames, getAllowedRoots, resolveUnderRoot } from '../src/paths';

describe('dashboard API hidden file handling', () => {
  let tempRoot = '';

  beforeEach(() => {
    tempRoot = mkdtempSync(join(tmpdir(), 'ralph-dashboard-hidden-files-'));
    mkdirSync(join(tempRoot, '.ralph-workspace', 'orchestration-plans'), { recursive: true });
    writeFileSync(join(tempRoot, 'visible.md'), 'visible plan');
    writeFileSync(join(tempRoot, '.secret.md'), 'hidden plan');
    mkdirSync(join(tempRoot, '.hidden-dir'), { recursive: true });
    writeFileSync(join(tempRoot, '.hidden-dir', 'nested.md'), 'nested hidden plan');
  });

  afterEach(() => {
    if (tempRoot) {
      rmSync(tempRoot, { recursive: true, force: true });
    }
  });

  it('omits hidden entries from listings', () => {
    const roots = getAllowedRoots({
      projectRoot: tempRoot,
      workspaceRoot: join(tempRoot, '.ralph-workspace'),
    });
    const plans = roots.plans;
    const names = readdirSync(plans.basePath);

    expect(filterVisibleEntryNames(names)).toEqual(['visible.md']);
    expect(names).toContain('.secret.md');
    expect(names).toContain('.hidden-dir');
  });

  it('blocks direct access to hidden paths', () => {
    const roots = getAllowedRoots({
      projectRoot: tempRoot,
      workspaceRoot: join(tempRoot, '.ralph-workspace'),
    });
    const plans = roots.plans;

    expect(() => resolveUnderRoot(plans, '.secret.md')).toThrow('invalid path');
    expect(() => resolveUnderRoot(plans, '.hidden-dir')).toThrow('invalid path');
    expect(() => resolveUnderRoot(plans, 'visible/.nested.md')).toThrow('invalid path');
  });
});
