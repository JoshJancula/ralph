import {
  concisePlanRunEvidencePath,
  groupPlanRunEvidence,
} from './plan-run-evidence-groups';
import type { PlanRunEvidenceEntry } from '../services/api.service';

function entry(category: string, path: string): PlanRunEvidenceEntry {
  return {
    id: path,
    path,
    label: path.split('/').pop() ?? path,
    category,
    kind: category,
    format: 'json',
    sizeBytes: 1,
    mtimeMs: 1,
    target: { root: 'logs', path: path.replace(/^logs\/PLAN\//, 'PLAN/') },
  };
}

describe('plan-run-evidence-groups', () => {
  it('groups metadata, execution, and other categories', () => {
    const groups = groupPlanRunEvidence([
      entry('usage-summary', 'logs/PLAN/plan-usage-summary.json'),
      entry('execution-output', 'logs/PLAN/plan-runner-output.log'),
      entry('other', 'logs/PLAN/misc.dat'),
    ]);
    expect(groups.map((g) => g.id)).toEqual(['metadata', 'execution', 'other']);
    expect(groups[0]?.entries).toHaveLength(1);
    expect(groups[1]?.entries[0]?.category).toBe('execution-output');
  });

  it('shortens paths for display', () => {
    expect(concisePlanRunEvidencePath('logs/PLAN/runs/run-1/manifest.json', 'PLAN')).toBe(
      'runs/run-1/manifest.json',
    );
  });
});
