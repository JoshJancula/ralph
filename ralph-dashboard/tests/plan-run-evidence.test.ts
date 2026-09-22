import {
  buildPlanRunEvidenceEntry,
  buildPlanRunFilesModel,
  classifyPlanRunEvidencePath,
  isSafePlanRunStatePath,
  planRunOpenTarget,
} from '../src/server/plan-run-evidence';

describe('plan-run-evidence classification', () => {
  it('maps known basenames to categories and labels', () => {
    expect(classifyPlanRunEvidencePath('logs/plan/plan-usage-summary.json').category).toBe('usage-summary');
    expect(classifyPlanRunEvidencePath('logs/plan/run-manifest.json').category).toBe('run-metadata');
    expect(classifyPlanRunEvidencePath('logs/plan/plan-runner-x-output.log').category).toBe('execution-output');
    expect(classifyPlanRunEvidencePath('logs/plan/tool-catalog-telemetry.jsonl').category).toBe('tool-telemetry');
    expect(classifyPlanRunEvidencePath('runtime-config/plan/journal.json').category).toBe('runtime-config');
  });

  it('rejects unsafe state paths', () => {
    expect(isSafePlanRunStatePath('logs/plan/../secrets')).toBe(false);
    expect(isSafePlanRunStatePath('processes/run-1/run.json')).toBe(false);
    expect(isSafePlanRunStatePath('logs/plan/.hidden')).toBe(false);
  });

  it('builds open targets for explorer roots', () => {
    expect(planRunOpenTarget('logs/demo/plan-runner-output.log')).toEqual({
      root: 'logs',
      path: 'demo/plan-runner-output.log',
    });
    expect(planRunOpenTarget('runtime-config/demo/overlay.json')).toEqual({
      root: 'runtime-config',
      path: 'demo/overlay.json',
    });
    expect(planRunOpenTarget('artifacts/demo/x.md')).toBeNull();
  });

  it('buildPlanRunFilesModel keeps legacy summary and raw buckets', () => {
    const model = buildPlanRunFilesModel('/tmp/ws', [
      'logs/p/plan-usage-summary.json',
      'logs/p/plan-runner-a-output.log',
      'processes/x/run.json',
      'logs/p/../escape.log',
    ]);
    expect(model.evidence).toHaveLength(2);
    expect(model.summary).toHaveLength(1);
    expect(model.raw).toEqual(['logs/p/plan-runner-a-output.log']);
    expect(model.evidence[0]?.target.root).toBe('logs');
  });

  it('returns null for entries outside workspace root', () => {
    expect(buildPlanRunEvidenceEntry('/tmp/ws', 'logs/plan/file.log')?.path).toBe('logs/plan/file.log');
  });
});
