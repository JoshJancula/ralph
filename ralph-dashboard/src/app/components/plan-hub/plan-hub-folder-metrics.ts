import type { MetricsSummary, MetricsSummaryItem } from '../../services/api.service';

const SCOPED_KEY_SEP = '\u001e';

export interface PlanFolderMetricLookup {
  readonly unscoped: ReadonlyMap<string, readonly MetricsSummaryItem[]>;
  readonly scoped: ReadonlyMap<string, readonly MetricsSummaryItem[]>;
}

function pathOrderedMapsToArrays(
  maps: Map<string, Map<string, MetricsSummaryItem>>,
): Map<string, MetricsSummaryItem[]> {
  const out = new Map<string, MetricsSummaryItem[]>();
  for (const [key, pathMap] of maps) {
    out.set(key, [...pathMap.values()]);
  }
  return out;
}

/**
 * Single pass over metrics rows: index by log folder name (plan_key / artifact_ns) for O(1) lookups.
 */
export function buildPlanFolderMetricLookup(summary: MetricsSummary): PlanFolderMetricLookup {
  const unscopedMaps = new Map<string, Map<string, MetricsSummaryItem>>();
  const scopedMaps = new Map<string, Map<string, MetricsSummaryItem>>();

  const addFirstPath = (
    bucket: Map<string, Map<string, MetricsSummaryItem>>,
    compositeKey: string,
    row: MetricsSummaryItem,
  ): void => {
    let m = bucket.get(compositeKey);
    if (!m) {
      m = new Map();
      bucket.set(compositeKey, m);
    }
    if (!m.has(row.path)) {
      m.set(row.path, row);
    }
  };

  const processRow = (row: MetricsSummaryItem): void => {
    const folderKeys = new Set<string>();
    if (row.plan_key) {
      folderKeys.add(row.plan_key);
    }
    if (row.artifact_ns) {
      folderKeys.add(row.artifact_ns);
    }
    for (const folderName of folderKeys) {
      addFirstPath(unscopedMaps, folderName, row);
      if (row.workspace_root) {
        addFirstPath(scopedMaps, `${row.workspace_root}${SCOPED_KEY_SEP}${folderName}`, row);
      }
    }
  };

  for (const row of summary.plans) {
    processRow(row);
  }
  for (const row of summary.orchestrations) {
    processRow(row);
  }

  return {
    unscoped: pathOrderedMapsToArrays(unscopedMaps),
    scoped: pathOrderedMapsToArrays(scopedMaps),
  };
}

export function lookupFolderMetricRows(
  lookup: PlanFolderMetricLookup,
  folderName: string,
  workspaceScope?: string,
): readonly MetricsSummaryItem[] {
  const ws = workspaceScope?.trim();
  if (ws) {
    return lookup.scoped.get(`${ws}${SCOPED_KEY_SEP}${folderName}`) ?? [];
  }
  return lookup.unscoped.get(folderName) ?? [];
}

export function rollupFolderMetrics(
  matches: readonly MetricsSummaryItem[],
  folderName: string,
): MetricsSummaryItem | null {
  if (matches.length === 0) {
    return null;
  }

  const aggInput = matches.reduce((acc, m) => acc + m.input_tokens, 0);
  const aggCacheRead = matches.reduce((acc, m) => acc + m.cache_read_input_tokens, 0);
  const aggCacheCreate = matches.reduce((acc, m) => acc + m.cache_creation_input_tokens, 0);
  const aggTotal = aggInput + aggCacheRead + aggCacheCreate;
  const aggCacheHitRatio = aggTotal > 0 ? Math.round((aggCacheRead / aggTotal) * 10000) / 10000 : 0;
  const aggMaxTurn = matches.reduce((max, m) => Math.max(max, m.max_turn_total_tokens), 0);
  const wsRoot = matches[0]?.workspace_root ?? '';
  const projRoot = matches[0]?.project_root ?? '';

  return {
    path: matches.map((m) => m.path).join('|'),
    plan_key: folderName,
    artifact_ns: folderName,
    workspace_root: wsRoot,
    project_root: projRoot,
    elapsed_seconds: matches.reduce((acc, m) => acc + m.elapsed_seconds, 0),
    input_tokens: aggInput,
    output_tokens: matches.reduce((acc, m) => acc + m.output_tokens, 0),
    cache_creation_input_tokens: aggCacheCreate,
    cache_read_input_tokens: aggCacheRead,
    max_turn_total_tokens: aggMaxTurn,
    cache_hit_ratio: aggCacheHitRatio,
    tool_calls_total: matches.reduce((acc, m) => acc + (m.tool_calls_total ?? 0), 0),
  };
}
