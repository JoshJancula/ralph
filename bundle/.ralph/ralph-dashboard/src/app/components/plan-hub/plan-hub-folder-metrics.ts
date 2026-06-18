import type {
  MetricsSummary,
  MetricsSummaryItem,
  RuntimeOverlayMetrics,
  ToolCallClassificationMetrics,
} from '../../services/api.service';

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

function rollupOverlayMetrics(matches: readonly MetricsSummaryItem[]): RuntimeOverlayMetrics | undefined {
  let saw = false;
  let native_hooks_effective = false;
  let mcp_effective = false;
  let native_hook_events = 0;
  let hook_compactions = 0;
  let hook_rewrites = 0;
  let hook_original_bytes = 0;
  let hook_compacted_bytes = 0;
  let runtime_overlay_mode = '';
  const warnings = new Set<string>();

  for (const row of matches) {
    const overlay = row.overlay;
    if (!overlay) {
      continue;
    }
    saw = true;
    if (overlay.native_hooks_effective) {
      native_hooks_effective = true;
    }
    if (overlay.mcp_effective) {
      mcp_effective = true;
    }
    native_hook_events += overlay.native_hook_events;
    hook_compactions += overlay.hook_compactions;
    hook_rewrites += overlay.hook_rewrites;
    hook_original_bytes += overlay.hook_original_bytes;
    hook_compacted_bytes += overlay.hook_compacted_bytes;
    if (overlay.runtime_overlay_mode.trim()) {
      runtime_overlay_mode = overlay.runtime_overlay_mode;
    }
    for (const warning of overlay.runtime_overlay_warnings) {
      if (warning.trim()) {
        warnings.add(warning);
      }
    }
  }

  if (!saw) {
    return undefined;
  }

  return {
    native_hooks_effective,
    mcp_effective,
    native_hook_events,
    hook_compactions,
    hook_rewrites,
    hook_original_bytes,
    hook_compacted_bytes,
    hook_bytes_saved: Math.max(0, hook_original_bytes - hook_compacted_bytes),
    runtime_overlay_mode,
    runtime_overlay_warnings: [...warnings].sort(),
  };
}

function rollupToolCallMetrics(
  matches: readonly MetricsSummaryItem[],
): ToolCallClassificationMetrics | undefined {
  let saw = false;
  const counts: ToolCallClassificationMetrics = {
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

  for (const row of matches) {
    const toolCalls = row.tool_calls;
    if (!toolCalls) {
      continue;
    }
    saw = true;
    counts.ralph_proxy_calls += toolCalls.ralph_proxy_calls;
    counts.ralph_knowledge_calls += toolCalls.ralph_knowledge_calls;
    counts.other_mcp_calls += toolCalls.other_mcp_calls;
    counts.native_read_like_calls += toolCalls.native_read_like_calls;
    counts.native_write_like_calls += toolCalls.native_write_like_calls;
    counts.native_file_read_calls += toolCalls.native_file_read_calls;
    counts.native_read_compatibility_calls += toolCalls.native_read_compatibility_calls;
    counts.native_search_calls += toolCalls.native_search_calls;
    counts.native_shell_calls += toolCalls.native_shell_calls;
    counts.ralph_mcp_calls += toolCalls.ralph_mcp_calls;
    counts.runtime_hook_rewrite_calls += toolCalls.runtime_hook_rewrite_calls;
    counts.runtime_hook_compaction_calls += toolCalls.runtime_hook_compaction_calls;
    counts.unknown_tool_calls += toolCalls.unknown_tool_calls;
  }

  return saw ? counts : undefined;
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

  const overlay = rollupOverlayMetrics(matches);
  const tool_calls = rollupToolCallMetrics(matches);

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
    ...(overlay ? { overlay } : {}),
    ...(tool_calls ? { tool_calls } : {}),
  };
}
