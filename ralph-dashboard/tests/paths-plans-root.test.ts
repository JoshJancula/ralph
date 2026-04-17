import { mkdirSync, mkdtempSync, readdirSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

import { getAllowedRoots } from '../src/paths';

describe('plans root scope', () => {
  it('treats workspace root as plans basePath', () => {
    const tempRoot = mkdtempSync(join(tmpdir(), 'ralph-dashboard-plans-root-'));

    try {
      mkdirSync(join(tempRoot, '.ralph-workspace', 'orchestration-plans'), { recursive: true });
      writeFileSync(join(tempRoot, 'alpha.md'), 'alpha plan');
      writeFileSync(join(tempRoot, '.ralph-workspace', 'orchestration-plans', 'nested.md'), 'nested plan');

      const roots = getAllowedRoots({
        projectRoot: tempRoot,
        workspaceRoot: join(tempRoot, '.ralph-workspace'),
      });
      const plans = roots.plans;
      expect(plans.basePath).toBe(tempRoot);

      const names = readdirSync(plans.basePath).filter((name) => !name.startsWith('.'));

      expect(names).toContain('alpha.md');
      expect(names).not.toContain('nested.md');
    } finally {
      rmSync(tempRoot, { recursive: true, force: true });
    }
  });
});
