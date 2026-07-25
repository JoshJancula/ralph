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

  it('returns null when there are no matching rows', () => {
    expect(rollupFolderMetrics([], 'anything')).toBeNull();
  });

  function baseRow(overrides: Partial<MetricsSummaryItem>): MetricsSummaryItem {
    return {
      path: 'p',
      plan_key: 'agg',
      artifact_ns: 'agg',
      workspace_root: wsA,
      project_root: projA,
      elapsed_seconds: 0,
      input_tokens: 0,
      output_tokens: 0,
      cache_creation_input_tokens: 0,
      cache_read_input_tokens: 0,
      max_turn_total_tokens: 0,
      cache_hit_ratio: 0,
      ...overrides,
    };
  }

  it('rolls up overlay metrics across rows, ignoring rows without overlay', () => {
    const rows: MetricsSummaryItem[] = [
      baseRow({
        path: 'r1',
        overlay: {
          native_hooks_effective: true,
          mcp_effective: false,
          native_hook_events: 2,
          hook_compactions: 1,
          hook_rewrites: 3,
          hook_original_bytes: 100,
          hook_compacted_bytes: 40,
          hook_bytes_saved: 60,
          runtime_overlay_mode: 'hybrid',
          runtime_overlay_warnings: ['   ', 'w1'],
        },
      }),
      baseRow({
        path: 'r2',
        overlay: {
          native_hooks_effective: false,
          mcp_effective: true,
          native_hook_events: 5,
          hook_compactions: 2,
          hook_rewrites: 1,
          hook_original_bytes: 10,
          hook_compacted_bytes: 50,
          hook_bytes_saved: 0,
          runtime_overlay_mode: '   ',
          runtime_overlay_warnings: ['w1', 'w2'],
        },
      }),
      baseRow({ path: 'r3' }),
    ];

    const rolled = rollupFolderMetrics(rows, 'agg');
    expect(rolled?.overlay).toEqual({
      native_hooks_effective: true,
      mcp_effective: true,
      native_hook_events: 7,
      hook_compactions: 3,
      hook_rewrites: 4,
      hook_original_bytes: 110,
      hook_compacted_bytes: 90,
      // clamped: 110 - 90 = 20, never negative
      hook_bytes_saved: 20,
      // blank mode from r2 does not overwrite r1's mode
      runtime_overlay_mode: 'hybrid',
      // blanks dropped, duplicates collapsed, sorted
      runtime_overlay_warnings: ['w1', 'w2'],
    });
  });

  it('rolls up tool-call metrics across rows, ignoring rows without tool_calls', () => {
    const emptyToolCalls = {
      ralph_proxy_calls: 0,
      ralph_knowledge_calls: 0,
      other_mcp_calls: 0,
      native_read_like_calls: 0,
      native_write_like_calls: 0,
      native_file_read_calls: 0,
      native_read_compatibility_calls: 0,
      native_search_calls: 0,
      native_shell_calls: 0,
      ralph_mcp_calls: 0,
      runtime_hook_rewrite_calls: 0,
      runtime_hook_compaction_calls: 0,
      unknown_tool_calls: 0,
    };
    const rows: MetricsSummaryItem[] = [
      baseRow({ path: 'r1', tool_calls: { ...emptyToolCalls, ralph_proxy_calls: 2, native_shell_calls: 1 } }),
      baseRow({ path: 'r2', tool_calls: { ...emptyToolCalls, ralph_proxy_calls: 3, unknown_tool_calls: 4 } }),
      baseRow({ path: 'r3' }),
    ];

    const rolled = rollupFolderMetrics(rows, 'agg');
    expect(rolled?.tool_calls).toEqual({
      ...emptyToolCalls,
      ralph_proxy_calls: 5,
      native_shell_calls: 1,
      unknown_tool_calls: 4,
    });
  });

  it('omits overlay and tool_calls when no row carries them and reports zero cache-hit ratio', () => {
    const rolled = rollupFolderMetrics([baseRow({ path: 'r1' }), baseRow({ path: 'r2' })], 'agg');
    expect(rolled).not.toBeNull();
    expect(rolled?.overlay).toBeUndefined();
    expect(rolled?.tool_calls).toBeUndefined();
    // aggTotal is 0, so the ratio short-circuits to 0 rather than dividing
    expect(rolled?.cache_hit_ratio).toBe(0);
  });
});
