/**
 * Answer-oriented Insights builders for usage metrics.
 * Pure functions over already-normalized summary items.
 */

export interface InsightsTokenTotals {
  input_tokens: number;
  output_tokens: number;
  cache_creation_input_tokens: number;
  cache_read_input_tokens: number;
  tool_calls_total: number;
  elapsed_seconds: number;
  max_turn_total_tokens: number;
}

export interface InsightsRunItem {
  path: string;
  plan_key: string;
  kind: 'plan' | 'orchestration';
  workspace_root: string;
  project_root: string;
  stage_id?: string;
  model?: string;
  runtime?: string;
  started_at?: string;
  ended_at?: string;
  elapsed_seconds: number;
  input_tokens: number;
  output_tokens: number;
  cache_creation_input_tokens: number;
  cache_read_input_tokens: number;
  max_turn_total_tokens: number;
  cache_hit_ratio: number;
  tool_calls_total?: number;
  model_breakdown?: Array<{
    runtime?: string;
    model?: string;
    invocations?: number;
    elapsed_seconds?: number;
    input_tokens?: number;
    output_tokens?: number;
    cache_creation_input_tokens?: number;
    cache_read_input_tokens?: number;
    max_turn_total_tokens?: number;
    tool_calls_total?: number;
  }>;
}

export interface InsightsDriver {
  kind: 'runtime' | 'model';
  label: string;
  exact_value: string;
  total_tokens: number;
  share_percent: number;
  runs: number;
}

export interface InsightsAnomaly {
  code: string;
  severity: 'info' | 'warn';
  message: string;
}

export interface InsightsTrend {
  direction: 'up' | 'down' | 'flat' | 'unknown';
  recent_tokens: number;
  prior_tokens: number;
  delta_tokens: number;
  delta_percent: number | null;
  recent_run_count: number;
  prior_run_count: number;
}

export interface MetricsInsightsSummary {
  date_scope: {
    from: string | null;
    to: string | null;
    label: string;
    run_count: number;
  };
  units: {
    tokens: 'tokens';
    elapsed: 'seconds';
    tool_calls: 'calls';
  };
  headline: {
    total_tokens: number;
    input_tokens: number;
    output_tokens: number;
    cache_read_input_tokens: number;
    cache_hit_ratio: number;
    elapsed_seconds: number;
    tool_calls_total: number;
    run_count: number;
  };
  trend: InsightsTrend;
  drivers: InsightsDriver[];
  anomalies: InsightsAnomaly[];
  drilldowns: Array<{ id: string; label: string; target: 'breakdown' | 'detail' }>;
  filter_options: {
    runtimes: string[];
    models: Array<{ label: string; exact_value: string }>;
  };
}

export interface MetricsBreakdownRow {
  runtime: string;
  model?: string;
  model_label?: string;
  model_exact?: string;
  model_count?: number;
  runs: number;
  invocations: number;
  input_tokens: number;
  output_tokens: number;
  cache_creation_input_tokens: number;
  cache_read_input_tokens: number;
  total_tokens: number;
  tool_calls_total: number;
  cache_hit_ratio: number;
  max_turn_total_tokens: number;
  elapsed_seconds: number;
}

export interface MetricsRunModelRow {
  runtime: string;
  model: string;
  model_label: string;
  model_exact: string;
  invocations: number;
  input_tokens: number;
  output_tokens: number;
  cache_creation_input_tokens: number;
  cache_read_input_tokens: number;
  total_tokens: number;
  tool_calls_total: number;
  elapsed_seconds: number;
}

export interface MetricsBreakdownRunRow {
  kind: 'plan' | 'orchestration';
  path: string;
  plan_key: string;
  stage_id?: string;
  workspace_root: string;
  runtime: string;
  model_label: string;
  model_exact: string;
  model_count: number;
  models: MetricsRunModelRow[];
  started_at?: string;
  input_tokens: number;
  output_tokens: number;
  cache_read_input_tokens: number;
  total_tokens: number;
  tool_calls_total: number;
  cache_hit_ratio: number;
  elapsed_seconds: number;
}

export interface MetricsBreakdownResponse {
  date_scope: {
    from: string | null;
    to: string | null;
    label: string;
  };
  units: MetricsInsightsSummary['units'];
  filtered_run_count: number;
  total_run_count: number;
  runtime_rows: MetricsBreakdownRow[];
  model_rows: MetricsBreakdownRow[];
  run_rows: MetricsBreakdownRunRow[];
  page: {
    offset: number;
    limit: number;
    total: number;
  };
  sort: {
    by: string;
    dir: 'asc' | 'desc';
  };
}

export interface MetricsDetailResponse {
  plan_key: string;
  kind: 'plan' | 'orchestration' | null;
  item: InsightsRunItem | null;
  related: InsightsRunItem[];
}

export interface MetricsFilterQuery {
  workspaceRoot?: string;
  kind?: 'all' | 'plan' | 'orchestration';
  runtime?: string;
  model?: string;
  dateFrom?: string;
  dateTo?: string;
  offset?: number;
  limit?: number;
  sortBy?: string;
  sortDir?: 'asc' | 'desc';
}

function toNumber(value: unknown): number {
  if (typeof value === 'number') {
    return Number.isFinite(value) ? value : 0;
  }
  if (typeof value === 'string') {
    const n = Number(value);
    return Number.isFinite(n) ? n : 0;
  }
  return 0;
}

function round4(value: number): number {
  return Math.round(value * 10000) / 10000;
}

function round1(value: number): number {
  return Math.round(value * 10) / 10;
}

export function totalTokensForItem(item: {
  input_tokens: number;
  output_tokens: number;
  cache_creation_input_tokens: number;
  cache_read_input_tokens: number;
}): number {
  return (
    toNumber(item.input_tokens) +
    toNumber(item.output_tokens) +
    toNumber(item.cache_creation_input_tokens) +
    toNumber(item.cache_read_input_tokens)
  );
}

export function friendlyModelLabel(raw: string | undefined | null): string {
  const exact = (raw ?? '').trim();
  if (!exact || exact === '(unspecified)') {
    return 'Unspecified model';
  }
  const lower = exact.toLowerCase();
  if (lower.includes('claude') && lower.includes('opus')) {
    return 'Claude Opus';
  }
  if (lower.includes('claude') && lower.includes('sonnet')) {
    return 'Claude Sonnet';
  }
  if (lower.includes('claude') && lower.includes('haiku')) {
    return 'Claude Haiku';
  }
  if (lower.includes('gpt-5') || lower.includes('gpt5')) {
    return 'GPT-5 family';
  }
  if (lower.includes('gpt-4o') || lower.includes('gpt4o')) {
    return 'GPT-4o';
  }
  if (lower.includes('gpt-4') || lower.includes('gpt4')) {
    return 'GPT-4 family';
  }
  if (lower.includes('o3')) {
    return 'OpenAI o3';
  }
  if (lower.includes('o1')) {
    return 'OpenAI o1';
  }
  if (lower.includes('gemini')) {
    return 'Gemini';
  }
  if (lower.includes('composer')) {
    return 'Composer';
  }
  // Shorten long provider/model ids: take last path segment / strip date suffixes
  const leaf = exact.split('/').pop() ?? exact;
  const withoutDate = leaf.replace(/-\d{8}($|[-_])/g, '$1').replace(/-\d{4}-\d{2}-\d{2}/g, '');
  if (withoutDate.length <= 28) {
    return withoutDate;
  }
  return `${withoutDate.slice(0, 25)}...`;
}

function normalizeRuntime(value: string | undefined | null): string {
  const trimmed = (value ?? '').trim();
  return trimmed || '(unspecified)';
}

function normalizeModel(value: string | undefined | null): string {
  const trimmed = (value ?? '').trim();
  return trimmed || '(unspecified)';
}

function parseDateStartMs(value: string | undefined): number | null {
  if (!value?.trim()) {
    return null;
  }
  const ms = Date.parse(`${value.trim()}T00:00:00.000Z`);
  return Number.isFinite(ms) ? ms : null;
}

function parseDateEndMs(value: string | undefined): number | null {
  if (!value?.trim()) {
    return null;
  }
  const ms = Date.parse(`${value.trim()}T23:59:59.999Z`);
  return Number.isFinite(ms) ? ms : null;
}

function startedAtMs(item: InsightsRunItem): number | null {
  if (!item.started_at) {
    return null;
  }
  const ms = Date.parse(item.started_at);
  return Number.isFinite(ms) ? ms : null;
}

function cacheHitRatio(totals: InsightsTokenTotals): number {
  const totalInput =
    totals.input_tokens + totals.cache_creation_input_tokens + totals.cache_read_input_tokens;
  return totalInput > 0 ? round4(totals.cache_read_input_tokens / totalInput) : 0;
}

function emptyTotals(): InsightsTokenTotals {
  return {
    input_tokens: 0,
    output_tokens: 0,
    cache_creation_input_tokens: 0,
    cache_read_input_tokens: 0,
    tool_calls_total: 0,
    elapsed_seconds: 0,
    max_turn_total_tokens: 0,
  };
}

function addItemToTotals(totals: InsightsTokenTotals, item: InsightsRunItem): void {
  totals.input_tokens += toNumber(item.input_tokens);
  totals.output_tokens += toNumber(item.output_tokens);
  totals.cache_creation_input_tokens += toNumber(item.cache_creation_input_tokens);
  totals.cache_read_input_tokens += toNumber(item.cache_read_input_tokens);
  totals.tool_calls_total += toNumber(item.tool_calls_total);
  totals.elapsed_seconds += toNumber(item.elapsed_seconds);
  if (toNumber(item.max_turn_total_tokens) > totals.max_turn_total_tokens) {
    totals.max_turn_total_tokens = toNumber(item.max_turn_total_tokens);
  }
}

function formatDateLabel(from: string | null, to: string | null): string {
  if (from && to) {
    return `${from} to ${to}`;
  }
  if (from) {
    return `From ${from}`;
  }
  if (to) {
    return `Through ${to}`;
  }
  return 'All available runs';
}

function resolveBreakdownEntries(item: InsightsRunItem): Array<{
  runtime: string;
  model: string;
  invocations: number;
  elapsed_seconds: number;
  input_tokens: number;
  output_tokens: number;
  cache_creation_input_tokens: number;
  cache_read_input_tokens: number;
  max_turn_total_tokens: number;
  tool_calls_total: number;
}> {
  if (Array.isArray(item.model_breakdown) && item.model_breakdown.length > 0) {
    return item.model_breakdown.map((entry) => ({
      runtime: normalizeRuntime(entry.runtime ?? item.runtime),
      model: normalizeModel(entry.model ?? item.model),
      invocations: Math.max(1, toNumber(entry.invocations)),
      elapsed_seconds: toNumber(entry.elapsed_seconds),
      input_tokens: toNumber(entry.input_tokens),
      output_tokens: toNumber(entry.output_tokens),
      cache_creation_input_tokens: toNumber(entry.cache_creation_input_tokens),
      cache_read_input_tokens: toNumber(entry.cache_read_input_tokens),
      max_turn_total_tokens: toNumber(entry.max_turn_total_tokens),
      tool_calls_total: toNumber(entry.tool_calls_total),
    }));
  }
  return [
    {
      runtime: normalizeRuntime(item.runtime),
      model: normalizeModel(item.model),
      invocations: 1,
      elapsed_seconds: toNumber(item.elapsed_seconds),
      input_tokens: toNumber(item.input_tokens),
      output_tokens: toNumber(item.output_tokens),
      cache_creation_input_tokens: toNumber(item.cache_creation_input_tokens),
      cache_read_input_tokens: toNumber(item.cache_read_input_tokens),
      max_turn_total_tokens: toNumber(item.max_turn_total_tokens),
      tool_calls_total: toNumber(item.tool_calls_total),
    },
  ];
}

export function filterInsightsRuns(
  items: InsightsRunItem[],
  filters: MetricsFilterQuery,
): InsightsRunItem[] {
  const kind = filters.kind ?? 'all';
  const runtime = filters.runtime?.trim() && filters.runtime !== 'all' ? filters.runtime.trim() : '';
  const model = filters.model?.trim() && filters.model !== 'all' ? filters.model.trim() : '';
  const fromMs = parseDateStartMs(filters.dateFrom);
  const toMs = parseDateEndMs(filters.dateTo);
  const workspace = filters.workspaceRoot?.trim() ? filters.workspaceRoot.trim() : '';

  return items.filter((item) => {
    if (workspace && item.workspace_root !== workspace) {
      return false;
    }
    if (kind !== 'all' && item.kind !== kind) {
      return false;
    }
    const started = startedAtMs(item);
    if (fromMs !== null && (started === null || started < fromMs)) {
      return false;
    }
    if (toMs !== null && (started === null || started > toMs)) {
      return false;
    }
    if (!runtime && !model) {
      return true;
    }
    const entries = resolveBreakdownEntries(item);
    return entries.some((entry) => {
      if (runtime && entry.runtime !== runtime) {
        return false;
      }
      if (model && entry.model !== model) {
        return false;
      }
      return true;
    });
  });
}

function buildTrend(items: InsightsRunItem[]): InsightsTrend {
  if (items.length === 0) {
    return {
      direction: 'unknown',
      recent_tokens: 0,
      prior_tokens: 0,
      delta_tokens: 0,
      delta_percent: null,
      recent_run_count: 0,
      prior_run_count: 0,
    };
  }

  const dated = items
    .map((item) => ({ item, ms: startedAtMs(item) ?? 0 }))
    .sort((a, b) => a.ms - b.ms);
  const midpoint = Math.floor(dated.length / 2);
  const prior = dated.slice(0, midpoint);
  const recent = dated.slice(midpoint);

  const sumTokens = (rows: typeof dated): number =>
    rows.reduce((acc, row) => acc + totalTokensForItem(row.item), 0);

  const priorTokens = sumTokens(prior);
  const recentTokens = sumTokens(recent);
  const delta = recentTokens - priorTokens;
  let direction: InsightsTrend['direction'] = 'flat';
  if (priorTokens === 0 && recentTokens === 0) {
    direction = 'unknown';
  } else if (priorTokens === 0 && recentTokens > 0) {
    direction = 'up';
  } else if (Math.abs(delta) / Math.max(priorTokens, 1) < 0.05) {
    direction = 'flat';
  } else if (delta > 0) {
    direction = 'up';
  } else {
    direction = 'down';
  }

  const deltaPercent =
    priorTokens > 0 ? round1((delta / priorTokens) * 100) : recentTokens > 0 ? 100 : null;

  return {
    direction,
    recent_tokens: recentTokens,
    prior_tokens: priorTokens,
    delta_tokens: delta,
    delta_percent: deltaPercent,
    recent_run_count: recent.length,
    prior_run_count: prior.length,
  };
}

function buildDrivers(items: InsightsRunItem[]): InsightsDriver[] {
  const runtimeBuckets = new Map<string, { tokens: number; runs: Set<string> }>();
  const modelBuckets = new Map<string, { tokens: number; runs: Set<string>; exact: string }>();

  for (const item of items) {
    for (const entry of resolveBreakdownEntries(item)) {
      const tokens =
        entry.input_tokens +
        entry.output_tokens +
        entry.cache_creation_input_tokens +
        entry.cache_read_input_tokens;
      const runtimeBucket = runtimeBuckets.get(entry.runtime) ?? {
        tokens: 0,
        runs: new Set<string>(),
      };
      runtimeBucket.tokens += tokens;
      runtimeBucket.runs.add(item.path);
      runtimeBuckets.set(entry.runtime, runtimeBucket);

      const modelBucket = modelBuckets.get(entry.model) ?? {
        tokens: 0,
        runs: new Set<string>(),
        exact: entry.model,
      };
      modelBucket.tokens += tokens;
      modelBucket.runs.add(item.path);
      modelBuckets.set(entry.model, modelBucket);
    }
  }

  const totalTokens = Array.from(runtimeBuckets.values()).reduce((acc, b) => acc + b.tokens, 0);
  const drivers: InsightsDriver[] = [];

  const topRuntimes = Array.from(runtimeBuckets.entries())
    .sort((a, b) => b[1].tokens - a[1].tokens)
    .slice(0, 3);
  for (const [runtime, bucket] of topRuntimes) {
    drivers.push({
      kind: 'runtime',
      label: runtime === '(unspecified)' ? 'Unspecified runtime' : runtime,
      exact_value: runtime,
      total_tokens: bucket.tokens,
      share_percent: totalTokens > 0 ? round1((bucket.tokens / totalTokens) * 100) : 0,
      runs: bucket.runs.size,
    });
  }

  const topModels = Array.from(modelBuckets.entries())
    .sort((a, b) => b[1].tokens - a[1].tokens)
    .slice(0, 3);
  for (const [, bucket] of topModels) {
    drivers.push({
      kind: 'model',
      label: friendlyModelLabel(bucket.exact),
      exact_value: bucket.exact,
      total_tokens: bucket.tokens,
      share_percent: totalTokens > 0 ? round1((bucket.tokens / totalTokens) * 100) : 0,
      runs: bucket.runs.size,
    });
  }

  return drivers;
}

function buildAnomalies(items: InsightsRunItem[], totals: InsightsTokenTotals, trend: InsightsTrend): InsightsAnomaly[] {
  const anomalies: InsightsAnomaly[] = [];
  const totalTokens =
    totals.input_tokens +
    totals.output_tokens +
    totals.cache_creation_input_tokens +
    totals.cache_read_input_tokens;
  const hit = cacheHitRatio(totals);

  if (items.length >= 3 && hit < 0.1 && totalTokens > 1000) {
    anomalies.push({
      code: 'low-cache-hit',
      severity: 'warn',
      message: `Cache hit ratio is ${(hit * 100).toFixed(1)}% across ${items.length} runs (${totalTokens} tokens).`,
    });
  }

  if (items.length >= 2) {
    const ranked = [...items].sort((a, b) => totalTokensForItem(b) - totalTokensForItem(a));
    const top = ranked[0];
    const topShare = totalTokens > 0 ? totalTokensForItem(top) / totalTokens : 0;
    if (topShare >= 0.5) {
      anomalies.push({
        code: 'dominant-run',
        severity: 'info',
        message: `${top.plan_key} accounts for ${round1(topShare * 100)}% of token volume.`,
      });
    }
  }

  if (
    trend.direction === 'up' &&
    trend.delta_percent !== null &&
    trend.delta_percent >= 50 &&
    trend.prior_tokens > 0
  ) {
    anomalies.push({
      code: 'token-spike',
      severity: 'warn',
      message: `Recent runs used ${trend.delta_percent}% more tokens than the prior half of the date scope.`,
    });
  }

  if (items.length === 0) {
    anomalies.push({
      code: 'no-runs',
      severity: 'info',
      message: 'No usage summaries found for the selected project and date scope.',
    });
  }

  return anomalies;
}

export function buildInsightsSummary(
  items: InsightsRunItem[],
  filters: MetricsFilterQuery = {},
): MetricsInsightsSummary {
  const filtered = filterInsightsRuns(items, {
    workspaceRoot: filters.workspaceRoot,
    kind: filters.kind ?? 'all',
    dateFrom: filters.dateFrom,
    dateTo: filters.dateTo,
  });

  const totals = emptyTotals();
  for (const item of filtered) {
    addItemToTotals(totals, item);
  }

  const totalTokens =
    totals.input_tokens +
    totals.output_tokens +
    totals.cache_creation_input_tokens +
    totals.cache_read_input_tokens;

  const dates = filtered
    .map((item) => item.started_at?.slice(0, 10))
    .filter((value): value is string => Boolean(value))
    .sort();
  const inferredFrom = filters.dateFrom?.trim() || dates[0] || null;
  const inferredTo = filters.dateTo?.trim() || dates[dates.length - 1] || null;

  const trend = buildTrend(filtered);
  const drivers = buildDrivers(filtered);
  const anomalies = buildAnomalies(filtered, totals, trend);

  const runtimeSet = new Set<string>();
  const modelMap = new Map<string, string>();
  for (const item of filtered) {
    for (const entry of resolveBreakdownEntries(item)) {
      runtimeSet.add(entry.runtime);
      if (!modelMap.has(entry.model)) {
        modelMap.set(entry.model, friendlyModelLabel(entry.model));
      }
    }
  }

  return {
    date_scope: {
      from: inferredFrom,
      to: inferredTo,
      label: formatDateLabel(inferredFrom, inferredTo),
      run_count: filtered.length,
    },
    units: {
      tokens: 'tokens',
      elapsed: 'seconds',
      tool_calls: 'calls',
    },
    headline: {
      total_tokens: totalTokens,
      input_tokens: totals.input_tokens,
      output_tokens: totals.output_tokens,
      cache_read_input_tokens: totals.cache_read_input_tokens,
      cache_hit_ratio: cacheHitRatio(totals),
      elapsed_seconds: totals.elapsed_seconds,
      tool_calls_total: totals.tool_calls_total,
      run_count: filtered.length,
    },
    trend,
    drivers,
    anomalies,
    drilldowns: [
      { id: 'runtime', label: 'Runtime breakdown', target: 'breakdown' },
      { id: 'model', label: 'Model breakdown', target: 'breakdown' },
      { id: 'runs', label: 'Run table', target: 'breakdown' },
    ],
    filter_options: {
      runtimes: Array.from(runtimeSet).sort(),
      models: Array.from(modelMap.entries())
        .map(([exact_value, label]) => ({ exact_value, label }))
        .sort((a, b) => a.label.localeCompare(b.label) || a.exact_value.localeCompare(b.exact_value)),
    },
  };
}

function sortRunRows(
  rows: MetricsBreakdownRunRow[],
  sortBy: string,
  sortDir: 'asc' | 'desc',
): MetricsBreakdownRunRow[] {
  const dir = sortDir === 'asc' ? 1 : -1;
  const key = sortBy || 'total_tokens';
  return [...rows].sort((a, b) => {
    const av = (a as unknown as Record<string, unknown>)[key];
    const bv = (b as unknown as Record<string, unknown>)[key];
    if (typeof av === 'number' && typeof bv === 'number') {
      return (av - bv) * dir;
    }
    return String(av ?? '').localeCompare(String(bv ?? '')) * dir;
  });
}

/**
 * Per-model usage rows for a single run, sorted by total tokens descending.
 * Multi-model runs (subagents, model switches, orchestrated stages) report each
 * model separately in model_breakdown; the summary-level `model` field only
 * names one of them.
 */
function runModelRows(item: InsightsRunItem): MetricsRunModelRow[] {
  const buckets = new Map<string, MetricsRunModelRow>();
  for (const entry of resolveBreakdownEntries(item)) {
    const key = `${entry.runtime} ${entry.model}`;
    const bucket = buckets.get(key) ?? {
      runtime: entry.runtime,
      model: entry.model,
      model_label: friendlyModelLabel(entry.model),
      model_exact: entry.model,
      invocations: 0,
      input_tokens: 0,
      output_tokens: 0,
      cache_creation_input_tokens: 0,
      cache_read_input_tokens: 0,
      total_tokens: 0,
      tool_calls_total: 0,
      elapsed_seconds: 0,
    };
    bucket.invocations += entry.invocations;
    bucket.input_tokens += entry.input_tokens;
    bucket.output_tokens += entry.output_tokens;
    bucket.cache_creation_input_tokens += entry.cache_creation_input_tokens;
    bucket.cache_read_input_tokens += entry.cache_read_input_tokens;
    bucket.total_tokens +=
      entry.input_tokens +
      entry.output_tokens +
      entry.cache_creation_input_tokens +
      entry.cache_read_input_tokens;
    bucket.tool_calls_total += entry.tool_calls_total;
    bucket.elapsed_seconds += entry.elapsed_seconds;
    buckets.set(key, bucket);
  }
  return Array.from(buckets.values()).sort(
    (a, b) =>
      b.total_tokens - a.total_tokens ||
      b.invocations - a.invocations ||
      a.model_exact.localeCompare(b.model_exact),
  );
}

export function buildMetricsBreakdown(
  items: InsightsRunItem[],
  filters: MetricsFilterQuery = {},
): MetricsBreakdownResponse {
  const totalRunCount = filterInsightsRuns(items, {
    workspaceRoot: filters.workspaceRoot,
  }).length;
  const filtered = filterInsightsRuns(items, filters);

  const runtimeBuckets = new Map<
    string,
    {
      models: Set<string>;
      runs: Set<string>;
      invocations: number;
      input_tokens: number;
      output_tokens: number;
      cache_creation_input_tokens: number;
      cache_read_input_tokens: number;
      tool_calls_total: number;
      max_turn_total_tokens: number;
      elapsed_seconds: number;
    }
  >();
  const modelBuckets = new Map<
    string,
    {
      runtime: string;
      model: string;
      runs: Set<string>;
      invocations: number;
      input_tokens: number;
      output_tokens: number;
      cache_creation_input_tokens: number;
      cache_read_input_tokens: number;
      tool_calls_total: number;
      max_turn_total_tokens: number;
      elapsed_seconds: number;
    }
  >();

  for (const item of filtered) {
    for (const entry of resolveBreakdownEntries(item)) {
      const runtimeBucket = runtimeBuckets.get(entry.runtime) ?? {
        models: new Set<string>(),
        runs: new Set<string>(),
        invocations: 0,
        input_tokens: 0,
        output_tokens: 0,
        cache_creation_input_tokens: 0,
        cache_read_input_tokens: 0,
        tool_calls_total: 0,
        max_turn_total_tokens: 0,
        elapsed_seconds: 0,
      };
      runtimeBucket.models.add(entry.model);
      runtimeBucket.runs.add(item.path);
      runtimeBucket.invocations += entry.invocations;
      runtimeBucket.input_tokens += entry.input_tokens;
      runtimeBucket.output_tokens += entry.output_tokens;
      runtimeBucket.cache_creation_input_tokens += entry.cache_creation_input_tokens;
      runtimeBucket.cache_read_input_tokens += entry.cache_read_input_tokens;
      runtimeBucket.tool_calls_total += entry.tool_calls_total;
      runtimeBucket.elapsed_seconds += entry.elapsed_seconds;
      if (entry.max_turn_total_tokens > runtimeBucket.max_turn_total_tokens) {
        runtimeBucket.max_turn_total_tokens = entry.max_turn_total_tokens;
      }
      runtimeBuckets.set(entry.runtime, runtimeBucket);

      const modelKey = `${entry.runtime}\u0000${entry.model}`;
      const modelBucket = modelBuckets.get(modelKey) ?? {
        runtime: entry.runtime,
        model: entry.model,
        runs: new Set<string>(),
        invocations: 0,
        input_tokens: 0,
        output_tokens: 0,
        cache_creation_input_tokens: 0,
        cache_read_input_tokens: 0,
        tool_calls_total: 0,
        max_turn_total_tokens: 0,
        elapsed_seconds: 0,
      };
      modelBucket.runs.add(item.path);
      modelBucket.invocations += entry.invocations;
      modelBucket.input_tokens += entry.input_tokens;
      modelBucket.output_tokens += entry.output_tokens;
      modelBucket.cache_creation_input_tokens += entry.cache_creation_input_tokens;
      modelBucket.cache_read_input_tokens += entry.cache_read_input_tokens;
      modelBucket.tool_calls_total += entry.tool_calls_total;
      modelBucket.elapsed_seconds += entry.elapsed_seconds;
      if (entry.max_turn_total_tokens > modelBucket.max_turn_total_tokens) {
        modelBucket.max_turn_total_tokens = entry.max_turn_total_tokens;
      }
      modelBuckets.set(modelKey, modelBucket);
    }
  }

  const toRow = (bucket: {
    invocations: number;
    input_tokens: number;
    output_tokens: number;
    cache_creation_input_tokens: number;
    cache_read_input_tokens: number;
    tool_calls_total: number;
    max_turn_total_tokens: number;
    elapsed_seconds: number;
    runs: Set<string>;
  }): Omit<MetricsBreakdownRow, 'runtime' | 'model' | 'model_label' | 'model_exact' | 'model_count'> => {
    const totalInput =
      bucket.input_tokens + bucket.cache_creation_input_tokens + bucket.cache_read_input_tokens;
    const totalTokens =
      bucket.input_tokens +
      bucket.output_tokens +
      bucket.cache_creation_input_tokens +
      bucket.cache_read_input_tokens;
    return {
      runs: bucket.runs.size,
      invocations: bucket.invocations,
      input_tokens: bucket.input_tokens,
      output_tokens: bucket.output_tokens,
      cache_creation_input_tokens: bucket.cache_creation_input_tokens,
      cache_read_input_tokens: bucket.cache_read_input_tokens,
      total_tokens: totalTokens,
      tool_calls_total: bucket.tool_calls_total,
      cache_hit_ratio: totalInput > 0 ? round4(bucket.cache_read_input_tokens / totalInput) : 0,
      max_turn_total_tokens: bucket.max_turn_total_tokens,
      elapsed_seconds: bucket.elapsed_seconds,
    };
  };

  const runtime_rows: MetricsBreakdownRow[] = Array.from(runtimeBuckets.entries())
    .map(([runtime, bucket]) => ({
      runtime,
      model_count: bucket.models.size,
      ...toRow(bucket),
    }))
    .sort((a, b) => b.total_tokens - a.total_tokens || a.runtime.localeCompare(b.runtime));

  const model_rows: MetricsBreakdownRow[] = Array.from(modelBuckets.values())
    .map((bucket) => ({
      runtime: bucket.runtime,
      model: bucket.model,
      model_label: friendlyModelLabel(bucket.model),
      model_exact: bucket.model,
      ...toRow(bucket),
    }))
    .sort(
      (a, b) =>
        b.total_tokens - a.total_tokens ||
        a.runtime.localeCompare(b.runtime) ||
        (a.model_exact ?? '').localeCompare(b.model_exact ?? ''),
    );

  const run_rows_all: MetricsBreakdownRunRow[] = filtered.map((item) => {
    const models = runModelRows(item);
    const primaryExact = models[0]?.model_exact ?? normalizeModel(item.model);
    return {
      kind: item.kind,
      path: item.path,
      plan_key: item.plan_key,
      stage_id: item.stage_id,
      workspace_root: item.workspace_root,
      runtime: normalizeRuntime(item.runtime),
      model_label: friendlyModelLabel(primaryExact),
      model_exact: primaryExact,
      model_count: models.length,
      models,
      started_at: item.started_at,
      input_tokens: item.input_tokens,
      output_tokens: item.output_tokens,
      cache_read_input_tokens: item.cache_read_input_tokens,
      total_tokens: totalTokensForItem(item),
      tool_calls_total: toNumber(item.tool_calls_total),
      cache_hit_ratio: item.cache_hit_ratio,
      elapsed_seconds: item.elapsed_seconds,
    };
  });

  const sortBy = filters.sortBy?.trim() || 'total_tokens';
  const sortDir = filters.sortDir === 'asc' ? 'asc' : 'desc';
  const sorted = sortRunRows(run_rows_all, sortBy, sortDir);
  const offset = Math.max(0, Math.floor(toNumber(filters.offset)));
  const limitRaw = Math.floor(toNumber(filters.limit));
  const limit = limitRaw > 0 ? Math.min(limitRaw, 200) : 50;
  const pageRows = sorted.slice(offset, offset + limit);

  const dates = filtered
    .map((item) => item.started_at?.slice(0, 10))
    .filter((value): value is string => Boolean(value))
    .sort();
  const from = filters.dateFrom?.trim() || dates[0] || null;
  const to = filters.dateTo?.trim() || dates[dates.length - 1] || null;

  return {
    date_scope: {
      from,
      to,
      label: formatDateLabel(from, to),
    },
    units: {
      tokens: 'tokens',
      elapsed: 'seconds',
      tool_calls: 'calls',
    },
    filtered_run_count: filtered.length,
    total_run_count: totalRunCount,
    runtime_rows,
    model_rows,
    run_rows: pageRows,
    page: {
      offset,
      limit,
      total: sorted.length,
    },
    sort: { by: sortBy, dir: sortDir },
  };
}

export function buildMetricsDetail(
  items: InsightsRunItem[],
  planKey: string,
  workspaceRoot?: string,
): MetricsDetailResponse {
  const key = planKey.trim();
  const scoped = workspaceRoot?.trim()
    ? items.filter((item) => item.workspace_root === workspaceRoot.trim())
    : items;
  const matches = scoped.filter((item) => item.plan_key === key);
  const latest =
    matches.length === 0
      ? null
      : matches.reduce((best, candidate) => {
          const bestMs = startedAtMs(best) ?? 0;
          const candidateMs = startedAtMs(candidate) ?? 0;
          return candidateMs >= bestMs ? candidate : best;
        });

  return {
    plan_key: key,
    kind: latest?.kind ?? null,
    item: latest,
    related: matches.filter((item) => item.path !== latest?.path).slice(0, 10),
  };
}

export function toInsightsRunItem(
  item: Omit<InsightsRunItem, 'kind'> & { kind?: InsightsRunItem['kind'] },
  kind: 'plan' | 'orchestration',
): InsightsRunItem {
  return {
    ...item,
    kind,
  };
}
