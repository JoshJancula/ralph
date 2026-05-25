import '../../../angular-test-env';
import type { MetricsSummary, MetricsSummaryItem } from '../../services/api.service';
import {
  buildPlanFolderMetricLookup,
  lookupFolderMetricRows,
  rollupFolderMetrics,
} from './plan-hub-folder-metrics';

function aggregateForFolderNaive(
  summary: MetricsSummary,
  folderName: string,
  workspaceScope?: string,
): MetricsSummaryItem | null {
  const seenPaths = new Set<string>();
  const matches: MetricsSummaryItem[] = [];

  const consider = (row: MetricsSummaryItem): void => {
    if (seenPaths.has(row.path)) {
      return;
    }
    if (workspaceScope && row.workspace_root !== workspaceScope) {
      return;
    }
    if (row.plan_key === folderName || row.artifact_ns === folderName) {
      seenPaths.add(row.path);
      matches.push(row);
    }
  };

  for (const row of summary.plans) {
    consider(row);
  }
  for (const row of summary.orchestrations) {
    consider(row);
  }

  return rollupFolderMetrics(matches, folderName);
}

describe('plan-hub-folder-metrics', () => {
  const wsA = '/p/a/.ralph-workspace';
  const wsB = '/p/b/.ralph-workspace';
  const projA = '/p/a';
  const projB = '/p/b';

  const richSummary: MetricsSummary = {
    overall: {
      input_tokens: 1,
      output_tokens: 1,
      cache_creation_input_tokens: 0,
      cache_read_input_tokens: 0,
      max_turn_total_tokens: 0,
      cache_hit_ratio: 0,
      elapsed_seconds: 1,
      count: 1,
    },
    plans: [
      {
        path: `${wsA}/logs/f1/plan-usage-summary.json`,
        plan_key: 'f1',
        artifact_ns: 'f1',
        workspace_root: wsA,
        project_root: projA,
        elapsed_seconds: 1,
        input_tokens: 10,
        output_tokens: 1,
        cache_creation_input_tokens: 0,
        cache_read_input_tokens: 2,
        max_turn_total_tokens: 100,
        cache_hit_ratio: 0,
        tool_calls_total: 1,
      },
      {
        path: `${wsB}/logs/f1/plan-usage-summary.json`,
        plan_key: 'f1',
        artifact_ns: 'f1',
        workspace_root: wsB,
        project_root: projB,
        elapsed_seconds: 2,
        input_tokens: 20,
        output_tokens: 2,
        cache_creation_input_tokens: 0,
        cache_read_input_tokens: 0,
        max_turn_total_tokens: 200,
        cache_hit_ratio: 0,
        tool_calls_total: 2,
      },
      {
        path: `${wsA}/logs/dual/plan-usage-summary.json`,
        plan_key: 'alpha',
        artifact_ns: 'beta',
        workspace_root: wsA,
        project_root: projA,
        elapsed_seconds: 3,
        input_tokens: 5,
        output_tokens: 5,
        cache_creation_input_tokens: 1,
        cache_read_input_tokens: 1,
        max_turn_total_tokens: 0,
        cache_hit_ratio: 0,
      },
    ],
    orchestrations: [
      {
        path: `${wsA}/logs/f1/orchestration-usage-summary.json`,
        plan_key: 'f1',
        artifact_ns: 'f1',
        workspace_root: wsA,
        project_root: projA,
        stage_id: 's1',
        elapsed_seconds: 4,
        input_tokens: 30,
        output_tokens: 3,
        cache_creation_input_tokens: 0,
        cache_read_input_tokens: 0,
        max_turn_total_tokens: 0,
        cache_hit_ratio: 0,
      },
    ],
    projects: [],
  };

  it('matches naive aggregation for unscoped and scoped folder lookups', () => {
    const lookup = buildPlanFolderMetricLookup(richSummary);
    const cases: { folder: string; ws?: string }[] = [
      { folder: 'f1' },
      { folder: 'f1', ws: wsA },
      { folder: 'f1', ws: wsB },
      { folder: 'alpha' },
      { folder: 'alpha', ws: wsA },
      { folder: 'beta' },
      { folder: 'beta', ws: wsA },
      { folder: 'missing' },
      { folder: 'missing', ws: wsA },
    ];

    for (const { folder, ws } of cases) {
      const naive = aggregateForFolderNaive(richSummary, folder, ws);
      const indexed = rollupFolderMetrics(lookupFolderMetricRows(lookup, folder, ws), folder);
      expect(indexed).toEqual(naive);
    }
  });
});
