import { mkdirSync, mkdtempSync, readdirSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

import { getAllowedRoots } from '../src/paths';

describe('plans root scope', () => {
  it('keeps plans listings inside .ralph-workspace/orchestration-plans', () => {
    const tempRoot = mkdtempSync(join(tmpdir(), 'ralph-dashboard-plans-root-'));

    try {
      mkdirSync(join(tempRoot, '.ralph-workspace', 'orchestration-plans'), { recursive: true });
      writeFileSync(
        join(tempRoot, '.ralph-workspace', 'orchestration-plans', 'alpha.md'),
        'alpha plan',
      );
      writeFileSync(join(tempRoot, 'outside.md'), 'outside plan');

      const plans = getAllowedRoots(tempRoot).plans;
      expect(plans.basePath).toBe(join(tempRoot, '.ralph-workspace', 'orchestration-plans'));

      const names = readdirSync(plans.basePath).filter((name) => !name.startsWith('.'));

      expect(names).toContain('alpha.md');
      expect(names).not.toContain('outside.md');
    } finally {
      rmSync(tempRoot, { recursive: true, force: true });
    }
  });
});
