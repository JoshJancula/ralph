import type { Express, Request, Response } from 'express';
import { type Dirent, existsSync, readFileSync, promises as fs, realpathSync, statSync } from 'node:fs';
import { basename, dirname, join, resolve } from 'node:path';
import {
  clearDashboardRootsCache,
  clearWorkspaceRootsCache,
  filterVisibleEntryNames,
  findAllWorkspaceRoots,
  findDashboardRoots,
  findWorkspaceArtifactsRootsAsync,
  findWorkspaceLogsRootsAsync,
  findWorkspaceProjectRoot,
  getAllowedRoots,
  isHiddenEntryName,
  parentListingPath,
  resolveRalphInstallRoot,
  resolveUnderRoot,
  type DashboardRoots,
  type RootConfig,
} from '../paths';

const FILE_CHUNK_BYTES = 256 * 1024;
const SUMMARY_FILE_NAMES = new Set(['plan-usage-summary.json', 'orchestration-usage-summary.json']);

// The Python savings report reuses a simple "4 bytes per token" estimate; mirror it here so both endpoints agree.
const SAVINGS_BYTES_PER_TOKEN_ESTIMATE = 4;
const SAVINGS_PATH_NAMES = [
  'pre_tool_rewrite',
  'hook_compaction',
  'proxy_shell_compaction',
  'result_windowing',
] as const;
const SAVINGS_PATHS_WITH_HIDDEN = new Set(['hook_compaction', 'proxy_shell_compaction', 'result_windowing']);

const WINDOWING_CHANNEL_NAMES = [
  'native_shell_hook',
  'proxy_shell',
  'native_result_hook',
  'native_result_mcp_fallback',
  'proxy_read_windowing',
  'proxy_search_windowing',
  'stored_result_readback',
] as const;

const CHANNEL_SAVINGS_KEYS = [
  'pre_optimization_bytes',
  'post_optimization_bytes',
  'saved_bytes',
  'count',
  'pre_optimization_tokens',
  'post_optimization_tokens',
  'saved_tokens',
  'token_cap_triggers',
  'hidden_from_context',
  'hidden_from_context_tokens',
] as const;

type SavingsPathName = (typeof SAVINGS_PATH_NAMES)[number];
type WindowingChannelName = (typeof WINDOWING_CHANNEL_NAMES)[number];
type ChannelAttribution = 'exact' | 'legacy';

interface SessionUsage {
  input_tokens: number;
  output_tokens: number;
  cache_creation_input_tokens: number;
  cache_read_input_tokens: number;
  prompt_bytes: number;
  tool_calls_total: number;
}

interface ToolOutputCounterfactual {
  hypothetical_without_ralph_bytes: number;
  actual_with_ralph_bytes: number;
  net_savings_bytes: number;
  hypothetical_without_ralph_tokens: number;
  actual_with_ralph_tokens: number;
  net_savings_tokens: number;
  net_savings_percent: number;
  compaction_measured_not_applied_bytes: number;
  compaction_measured_not_applied_tokens: number;
}

interface SavingsBucket {
  pre_optimization_bytes: number;
  post_optimization_bytes: number;
  saved_bytes: number;
  count: number;
  pre_optimization_tokens: number;
  post_optimization_tokens: number;
  saved_tokens: number;
  token_cap_triggers: number;
  hidden_from_context?: number;
  hidden_from_context_tokens?: number;
  savings_percent?: number;
  savings_percent_tokens?: number;
  status?: string;
  status_label?: string;
  gross_hidden_bytes?: number;
  gross_hidden_tokens?: number;
  gross_readback_bytes?: number;
  gross_readback_tokens?: number;
  net_readback_cost_bytes?: number;
  effective_windowing_savings_rate?: number;
  compaction_measured_not_applied_bytes?: number;
  net_consumed_bytes?: number;
  net_consumed_tokens?: number;
}

interface ChannelBucket extends SavingsBucket {
  attribution: ChannelAttribution;
}

interface ReadbackSummary {
  envelope_count: number;
  readback_count: number;
  raw_readback_count: number;
  compacted_readback_count: number;
  readback_bytes: number;
  envelope_original_bytes: number;
  full_preview_rereads: number;
  raw_readback_share: number;
  readback_negation_rate: number;
  gross_readback_bytes: number;
  gross_readback_tokens: number;
  net_consumed_bytes: number;
  net_consumed_tokens: number;
  effective_windowing_savings_rate: number;
}

interface SavingsReportDateRange {
  started_at: string | null;
  ended_at: string | null;
}

interface SavingsReport {
  schema_version: number;
  kind: 'ralph_benchmark_report';
  run_count: number;
  date_range: SavingsReportDateRange;
  saved_bytes: number;
  saved_tokens: number;
  savings_percent: number;
  session_usage: SessionUsage;
  tool_output_counterfactual: ToolOutputCounterfactual;
  per_path: Record<SavingsPathName, SavingsBucket>;
  per_channel: Record<WindowingChannelName, ChannelBucket>;
  cache: {
    cache_read_tokens: number;
    cache_hit_ratio: number;
  };
  could_have_saved: {
    compaction_measured_not_applied_bytes: number;
  };
  readback_summary?: ReadbackSummary;
  optimization_opportunities?: Record<string, unknown> | null;
  optimization_opportunities_source?: { plan_key: string; ended_at: string | null } | null;
}

const DASHBOARD_EXPLORER_ROOT_KEYS = new Set([
  'logs',
  'artifacts',
  'sessions',
  'orchestration-plans',
  'docs',
  'plans',
]);

type MetricsSummaryKind = 'plan_usage_summary' | 'orchestration_usage_summary';

interface UsageSummaryRecord {
  schema_version?: number;
  kind?: MetricsSummaryKind;
  plan?: string;
  orchestration?: string;
  plan_key?: string;
  artifact_ns?: string;
  stage_id?: string;
  model?: string;
  runtime?: string;
  started_at?: string;
  ended_at?: string;
  elapsed_seconds?: number;
  input_tokens?: number;
  output_tokens?: number;
  cache_creation_input_tokens?: number;
  cache_read_input_tokens?: number;
  uncached_input_tokens?: number;
  total_input_tokens?: number;
  cache_efficiency_ratio?: number;
  measurement_source?: Record<string, string>;
  max_turn_total_tokens?: number;
  cache_hit_ratio?: number;
  prompt_bytes?: number;
  todo_bytes?: number;
  todo_continuation_lines?: number;
  direct_verification_count?: number;
  rate_limit_count?: number;
  tool_turns?: number;
  tool_calls_total?: number;
  compaction_measured_not_applied_bytes?: number;
  model_breakdown?: ModelBreakdownItem[];
  byte_savings_by_path?: Record<string, unknown>;
  byte_savings_by_channel?: Record<string, unknown>;
  invocations?: number;
  steps?: number;
  todos_done?: number;
  todos_total?: number;
  native_hooks_effective?: boolean;
  mcp_effective?: boolean;
  native_hook_events?: number;
  hook_compactions?: number;
  hook_rewrites?: number;
  hook_original_bytes?: number;
  hook_compacted_bytes?: number;
  runtime_overlay_mode?: string;
  runtime_overlay_warnings?: string[];
}

export interface RuntimeOverlayMetrics {
  native_hooks_effective: boolean;
  mcp_effective: boolean;
  native_hook_events: number;
  hook_compactions: number;
  hook_rewrites: number;
  hook_original_bytes: number;
  hook_compacted_bytes: number;
  hook_bytes_saved: number;
  runtime_overlay_mode: string;
  runtime_overlay_warnings: string[];
}

/** Per-category tool call counters emitted by Ralph usage accounting (legacy + granular). */
export const TOOL_CALL_ACCOUNTING_KEYS = [
  'ralph_proxy_calls',
  'ralph_knowledge_calls',
  'other_mcp_calls',
  'native_read_like_calls',
  'native_write_like_calls',
  'native_file_read_calls',
  'native_read_compatibility_calls',
  'native_search_calls',
  'native_shell_calls',
  'ralph_mcp_calls',
  'runtime_hook_rewrite_calls',
  'runtime_hook_compaction_calls',
  'unknown_tool_calls',
] as const;

export type ToolCallAccountingKey = (typeof TOOL_CALL_ACCOUNTING_KEYS)[number];

export type ToolCallClassificationMetrics = Record<ToolCallAccountingKey, number>;

interface ModelBreakdownItem {
  runtime: string;
  model: string;
  invocations: number;
  elapsed_seconds: number;
  input_tokens: number;
  output_tokens: number;
  cache_creation_input_tokens: number;
  cache_read_input_tokens: number;
  uncached_input_tokens?: number;
  total_input_tokens?: number;
  cache_efficiency_ratio?: number;
  measurement_source?: Record<string, string>;
  max_turn_total_tokens: number;
  cache_hit_ratio: number;
  prompt_bytes?: number;
  todo_bytes?: number;
  todo_continuation_lines?: number;
  direct_verification_count?: number;
  rate_limit_count?: number;
  tool_turns?: number;
  tool_calls_total?: number;
  overlay?: RuntimeOverlayMetrics;
  tool_calls?: ToolCallClassificationMetrics;
}

interface OverlayAccumulator {
  saw_overlay_fields: boolean;
  native_hooks_effective: boolean;
  mcp_effective: boolean;
  native_hook_events: number;
  hook_compactions: number;
  hook_rewrites: number;
  hook_original_bytes: number;
  hook_compacted_bytes: number;
  runtime_overlay_mode: string;
  runtime_overlay_warnings: Set<string>;
}

interface WorkspaceRegistryEntry {
  path: string;
  lastSeen?: string;
  planKey?: string;
  runtime?: string;
}

interface MetricsSummaryOverallShape {
  input_tokens: number;
  output_tokens: number;
  cache_creation_input_tokens: number;
  cache_read_input_tokens: number;
  max_turn_total_tokens: number;
  cache_hit_ratio: number;
  elapsed_seconds: number;
  count: number;
  tool_calls_total: number;
}

export interface DiscoverPatternSummary {
  pattern_id: string;
  count: number;
  description?: string;
}

export interface DiscoverReportPayload {
  schema_version: number;
  kind: string;
  generated_at?: string;
  plan_key?: string;
  data_sources?: string[];
  limitations?: string[];
  totals?: Record<string, unknown>;
  sequence_patterns?: DiscoverPatternSummary[];
  sequence_findings?: Record<string, unknown>[];
  aggregate_findings?: Record<string, unknown>[];
  runtime_tool_access?: Record<string, unknown>[];
  runtime_differences?: Record<string, unknown>[];
  high_token_low_cache_invocations?: Record<string, unknown>[];
}

interface MetricsSummaryItem {
  path: string;
  plan_key: string;
  artifact_ns: string;
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
  prompt_bytes?: number;
  todo_bytes?: number;
  todo_continuation_lines?: number;
  direct_verification_count?: number;
  rate_limit_count?: number;
  tool_turns?: number;
  tool_calls_total?: number;
  model_breakdown?: ModelBreakdownItem[];
  invocations?: number;
  overlay?: RuntimeOverlayMetrics;
  tool_calls?: ToolCallClassificationMetrics;
}

type AggregatedListingEntry = {
  name: string;
  path: string;
  type: 'file' | 'dir';
  size: number;
  mtime: number;
  /** Absolute path to `.ralph-workspace` when listing merges multiple aggregate roots. */
  workspaceRoot?: string;
};

function filterAggregateRootsByWorkspace(roots: string[], workspaceRootQuery: string): string[] {
  const trimmed = workspaceRootQuery.trim();
  if (!trimmed) {
    return roots;
  }
  const target = resolve(trimmed);
  return roots.filter((r) => resolve(dirname(r)) === target);
}

function workspacesRegistryPath(): string | null {
  if (process.env['RALPH_WORKSPACES_FILE']?.trim()) {
    return process.env['RALPH_WORKSPACES_FILE'];
  }

  const configHome = process.env['XDG_CONFIG_HOME']?.trim();
  if (configHome) {
    return join(configHome, 'ralph', 'workspaces.json');
  }

  const home = process.env['HOME']?.trim();
  if (home) {
    return join(home, '.config', 'ralph', 'workspaces.json');
  }

  return null;
}

export async function loadWorkspaces(): Promise<WorkspaceRegistryEntry[]> {
  const registryPath = workspacesRegistryPath();
  if (!registryPath) {
    return [];
  }

  let raw = '';
  try {
    raw = await fs.readFile(registryPath, 'utf8');
  } catch {
    return [];
  }

  let parsed: unknown;
  try {
    parsed = JSON.parse(raw);
  } catch {
    return [];
  }

  if (!Array.isArray(parsed)) {
    return [];
  }

  const seen = new Set<string>();
  const workspaces: WorkspaceRegistryEntry[] = [];
  for (const item of parsed) {
    if (!item || typeof item !== 'object') {
      continue;
    }
    const record = item as Record<string, unknown>;
    if (typeof record['path'] !== 'string' || record['path'].trim() === '') {
      continue;
    }
    const workspacePath = resolve(record['path']);
    if (seen.has(workspacePath)) {
      continue;
    }
    seen.add(workspacePath);
    workspaces.push({
      path: workspacePath,
      lastSeen: typeof record['lastSeen'] === 'string' ? record['lastSeen'] : undefined,
      planKey: typeof record['planKey'] === 'string' ? record['planKey'] : undefined,
      runtime: typeof record['runtime'] === 'string' ? record['runtime'] : undefined,
    });
  }

  return workspaces;
}

async function collectSummaryPathsFromLogs(logRoots: string[]): Promise<string[]> {
  const results = await Promise.all(logRoots.map((root) => collectSummaryFiles(root)));
  const seen = new Set<string>();
  for (const files of results) {
    for (const file of files) {
      seen.add(file);
    }
  }
  return Array.from(seen).sort();
}

function createEmptySavingsBucket(includeHidden: boolean): SavingsBucket {
  const bucket: SavingsBucket = {
    pre_optimization_bytes: 0,
    post_optimization_bytes: 0,
    saved_bytes: 0,
    count: 0,
    pre_optimization_tokens: 0,
    post_optimization_tokens: 0,
    saved_tokens: 0,
    token_cap_triggers: 0,
  };
  if (includeHidden) {
    bucket.hidden_from_context = 0;
    bucket.hidden_from_context_tokens = 0;
  }
  return bucket;
}

function createEmptySavingsBuckets(): Record<SavingsPathName, SavingsBucket> {
  const buckets = {} as Record<SavingsPathName, SavingsBucket>;
  for (const pathName of SAVINGS_PATH_NAMES) {
    buckets[pathName] = createEmptySavingsBucket(SAVINGS_PATHS_WITH_HIDDEN.has(pathName));
  }
  return buckets;
}

function isObject(value: unknown): value is Record<string, unknown> {
  return Boolean(value) && typeof value === 'object' && !Array.isArray(value);
}

function toInt(value: unknown): number {
  const coerced = toNumber(value);
  if (!Number.isFinite(coerced)) {
    return 0;
  }
  return Math.max(0, Math.round(coerced));
}

function roundOneDecimal(value: number): number {
  return Math.round(value * 10) / 10;
}

function estimateTokensFromBytes(bytes: number): number {
  if (bytes <= 0) {
    return 0;
  }
  return Math.ceil(bytes / SAVINGS_BYTES_PER_TOKEN_ESTIMATE);
}

function mergeSavingsBucket(target: SavingsBucket, source: Record<string, unknown>): void {
  if ('pre_optimization_bytes' in source) {
    target.pre_optimization_bytes += toInt(source['pre_optimization_bytes']);
  }
  if ('post_optimization_bytes' in source) {
    target.post_optimization_bytes += toInt(source['post_optimization_bytes']);
  }
  if ('saved_bytes' in source) {
    target.saved_bytes += toInt(source['saved_bytes']);
  }
  if ('count' in source) {
    target.count += toInt(source['count']);
  }
  if ('pre_optimization_tokens' in source) {
    target.pre_optimization_tokens += toInt(source['pre_optimization_tokens']);
  }
  if ('post_optimization_tokens' in source) {
    target.post_optimization_tokens += toInt(source['post_optimization_tokens']);
  }
  if ('saved_tokens' in source) {
    target.saved_tokens += toInt(source['saved_tokens']);
  }
  if ('token_cap_triggers' in source) {
    target.token_cap_triggers += toInt(source['token_cap_triggers']);
  }
  if ('hidden_from_context' in source && target.hidden_from_context !== undefined) {
    target.hidden_from_context! += toInt(source['hidden_from_context']);
  }
  if ('hidden_from_context_tokens' in source && target.hidden_from_context_tokens !== undefined) {
    target.hidden_from_context_tokens! += toInt(source['hidden_from_context_tokens']);
  }
  if ('gross_readback_bytes' in source) {
    target.gross_readback_bytes = (target.gross_readback_bytes ?? 0) + toInt(source['gross_readback_bytes']);
  }
  if ('gross_readback_tokens' in source) {
    target.gross_readback_tokens = (target.gross_readback_tokens ?? 0) + toInt(source['gross_readback_tokens']);
  }
  if ('net_readback_cost_bytes' in source) {
    target.net_readback_cost_bytes = (target.net_readback_cost_bytes ?? 0) + toInt(source['net_readback_cost_bytes']);
  }
  if ('effective_windowing_savings_rate' in source) {
    const rate = toNumber(source['effective_windowing_savings_rate']);
    if (target.effective_windowing_savings_rate === undefined || rate > target.effective_windowing_savings_rate) {
      target.effective_windowing_savings_rate = rate;
    }
  }
  if ('compaction_measured_not_applied_bytes' in source) {
    target.compaction_measured_not_applied_bytes =
      (target.compaction_measured_not_applied_bytes ?? 0) + toInt(source['compaction_measured_not_applied_bytes']);
  }
}

function mergeSavingsBuckets(
  target: Record<SavingsPathName, SavingsBucket>,
  source: Record<SavingsPathName, SavingsBucket>,
): void {
  for (const pathName of SAVINGS_PATH_NAMES) {
    const bucket = source[pathName];
    mergeSavingsBucket(target[pathName], (bucket as unknown) as Record<string, unknown>);
  }
}

function hasSavings(bucket: SavingsBucket): boolean {
  return bucket.saved_bytes > 0 || bucket.saved_tokens > 0;
}

function finalizeSavingsBucket(bucket: SavingsBucket): void {
  if (bucket.pre_optimization_tokens === 0 && bucket.pre_optimization_bytes > 0) {
    bucket.pre_optimization_tokens = estimateTokensFromBytes(bucket.pre_optimization_bytes);
  }
  if (bucket.post_optimization_tokens === 0 && bucket.post_optimization_bytes > 0) {
    bucket.post_optimization_tokens = estimateTokensFromBytes(bucket.post_optimization_bytes);
  }
  if (bucket.saved_tokens === 0) {
    const delta = bucket.pre_optimization_tokens - bucket.post_optimization_tokens;
    bucket.saved_tokens = Math.max(0, delta);
  }
  if (bucket.pre_optimization_bytes > 0) {
    bucket.savings_percent = roundOneDecimal((bucket.saved_bytes / bucket.pre_optimization_bytes) * 100);
  }
  if (bucket.pre_optimization_tokens > 0) {
    bucket.savings_percent_tokens = roundOneDecimal(
      (bucket.saved_tokens / bucket.pre_optimization_tokens) * 100,
    );
  }
}

function finalizeAllSavingsBuckets(buckets: Record<SavingsPathName, SavingsBucket>): void {
  for (const pathName of SAVINGS_PATH_NAMES) {
    finalizeSavingsBucket(buckets[pathName]);
  }
}

function createEmptyChannelBucket(attribution: ChannelAttribution = 'exact'): ChannelBucket {
  return {
    ...createEmptySavingsBucket(true),
    attribution,
  };
}

function createEmptyChannelBuckets(): Record<WindowingChannelName, ChannelBucket> {
  const buckets = {} as Record<WindowingChannelName, ChannelBucket>;
  for (const channelName of WINDOWING_CHANNEL_NAMES) {
    buckets[channelName] = createEmptyChannelBucket('exact');
  }
  return buckets;
}

function channelHasActivity(bucket: ChannelBucket): boolean {
  return bucket.pre_optimization_bytes > 0 || bucket.saved_bytes > 0 || bucket.count > 0;
}

function markChannelAttribution(bucket: ChannelBucket, attribution: ChannelAttribution): void {
  if (bucket.attribution === 'legacy' || attribution === 'legacy') {
    bucket.attribution = 'legacy';
  } else {
    bucket.attribution = 'exact';
  }
}

function mergeChannelBucket(target: ChannelBucket, source: Record<string, unknown>): void {
  for (const key of CHANNEL_SAVINGS_KEYS) {
    if (key in source) {
      const current = key === 'hidden_from_context' || key === 'hidden_from_context_tokens'
        ? (target[key] ?? 0)
        : (target[key as keyof ChannelBucket] as number);
      (target as unknown as Record<string, number>)[key] = toInt(current) + toInt(source[key]);
    }
  }
  const sourceAttribution = String(source['attribution'] ?? 'exact');
  markChannelAttribution(target, sourceAttribution === 'legacy' ? 'legacy' : 'exact');
}

function mergeChannelBuckets(
  target: Record<WindowingChannelName, ChannelBucket>,
  source: Record<WindowingChannelName, ChannelBucket>,
): void {
  for (const channelName of WINDOWING_CHANNEL_NAMES) {
    mergeChannelBucket(target[channelName], source[channelName] as unknown as Record<string, unknown>);
  }
}

function finalizeChannelBuckets(
  channels: Record<WindowingChannelName, ChannelBucket>,
): Record<WindowingChannelName, ChannelBucket> {
  const perChannel = {} as Record<WindowingChannelName, ChannelBucket>;
  for (const channelName of WINDOWING_CHANNEL_NAMES) {
    const bucket = { ...channels[channelName] };
    if (channelHasActivity(bucket)) {
      finalizeSavingsBucket(bucket);
    } else {
      delete bucket.savings_percent;
      delete bucket.savings_percent_tokens;
    }
    perChannel[channelName] = bucket;
  }
  return perChannel;
}

function accumulateChannelSavingsEvent(
  bucket: ChannelBucket,
  params: {
    preBytes: number;
    postBytes: number;
    preTokens: number;
    postTokens: number;
    tokenCapTrigger: boolean;
  },
): void {
  const { preBytes, postBytes, preTokens, postTokens, tokenCapTrigger } = params;
  bucket.pre_optimization_bytes += preBytes;
  bucket.post_optimization_bytes += postBytes;
  bucket.saved_bytes += Math.max(0, preBytes - postBytes);
  bucket.pre_optimization_tokens += preTokens;
  bucket.post_optimization_tokens += postTokens;
  bucket.saved_tokens += Math.max(0, preTokens - postTokens);
  bucket.count += 1;
  if (tokenCapTrigger) {
    bucket.token_cap_triggers += 1;
  }
  if (bucket.hidden_from_context !== undefined) {
    bucket.hidden_from_context += Math.max(0, preBytes - postBytes);
  }
  if (bucket.hidden_from_context_tokens !== undefined) {
    bucket.hidden_from_context_tokens += Math.max(0, preTokens - postTokens);
  }
}

function channelHasMeaningfulSavings(bucket: ChannelBucket | SavingsBucket | undefined): boolean {
  if (!bucket) {
    return false;
  }
  return bucket.saved_bytes > 0 || bucket.count > 0;
}

function hasMeaningfulOptimizationEvidence(
  perPath: Record<SavingsPathName, SavingsBucket>,
  perChannel: Record<WindowingChannelName, ChannelBucket>,
): boolean {
  for (const pathName of SAVINGS_PATH_NAMES) {
    if (channelHasMeaningfulSavings(perPath[pathName])) {
      return true;
    }
  }
  for (const channelName of WINDOWING_CHANNEL_NAMES) {
    if (channelHasMeaningfulSavings(perChannel[channelName])) {
      return true;
    }
  }
  return false;
}

function savingsPathFromFamily(family: string): SavingsPathName | null {
  const normalized = family.trim().toLowerCase();
  if (['hook_compaction', 'hook', 'bash'].includes(normalized)) {
    return 'hook_compaction';
  }
  if (['proxy_shell_compaction', 'proxy_shell', 'proxy-shell', 'proxy'].includes(normalized)) {
    return 'proxy_shell_compaction';
  }
  if (['result_windowing', 'result-windowing', 'windowing', 'result'].includes(normalized)) {
    return 'result_windowing';
  }
  if (['pre_tool_rewrite', 'pre-tool-rewrite', 'rewrite', 'bash-rewrite'].includes(normalized)) {
    return 'pre_tool_rewrite';
  }
  return null;
}

async function collectInvocationSavings(invocationsPath: string): Promise<Record<SavingsPathName, SavingsBucket>> {
  const buckets = createEmptySavingsBuckets();
  if (!existsSync(invocationsPath)) {
    return buckets;
  }
  let payload: unknown;
  try {
    payload = JSON.parse(await fs.readFile(invocationsPath, 'utf8'));
  } catch {
    return buckets;
  }
  if (!isObject(payload)) {
    return buckets;
  }
  const invocations = Array.isArray(payload['invocations']) ? payload['invocations'] : [];
  // The runtime overlay writes each invocation's byte_savings_by_path as a
  // cumulative running total. Summing those snapshots across iterations
  // multiplies real savings, so keep the final (largest) snapshot per
  // (plan_key, stage_id, path_name) rather than per-iteration.
  const latest = new Map<string, Record<string, unknown>>();
  for (const record of invocations) {
    if (!isObject(record)) {
      continue;
    }
    const byteSavings = record['byte_savings_by_path'];
    if (!isObject(byteSavings)) {
      continue;
    }
    const planKey = String(record['plan_key'] ?? '');
    const stageId = String(record['stage_id'] ?? '');
    for (const pathName of SAVINGS_PATH_NAMES) {
      const pathData = byteSavings[pathName];
      if (!isObject(pathData)) {
        continue;
      }
      const key = `${planKey}\u0000${stageId}\u0000${pathName}`;
      latest.set(key, pathData);
    }
  }
  for (const pathData of latest.values()) {
    const pathName = savingsPathFromFamily(String(pathData['path_name'] ?? pathData['name'] ?? ''));
    if (pathName) {
      mergeSavingsBucket(buckets[pathName], pathData);
    } else {
      // Fallback: try to infer the target bucket from any explicit path_name
      // field in the stored snapshot; otherwise the caller will not merge it.
      for (const name of SAVINGS_PATH_NAMES) {
        if (String(pathData['path_name'] ?? pathData['name'] ?? '').toLowerCase().includes(name.replace('_', ''))) {
          mergeSavingsBucket(buckets[name], pathData);
          break;
        }
      }
    }
  }
  return buckets;
}

async function collectCompactionTelemetrySavings(
  invocationsPath: string,
): Promise<Record<SavingsPathName, SavingsBucket>> {
  const buckets = createEmptySavingsBuckets();
  if (!existsSync(invocationsPath)) {
    return buckets;
  }
  let payload: unknown;
  try {
    payload = JSON.parse(await fs.readFile(invocationsPath, 'utf8'));
  } catch {
    return buckets;
  }
  if (!isObject(payload)) {
    return buckets;
  }
  const invocations = Array.isArray(payload['invocations']) ? payload['invocations'] : [];
  const seen = new Set<string>();
  for (const record of invocations) {
    if (!isObject(record)) {
      continue;
    }
    const telemetryList = Array.isArray(record['compaction_telemetry'])
      ? record['compaction_telemetry']
      : [];
    const planKey = String(record['plan_key'] ?? '');
    const stageId = String(record['stage_id'] ?? '');
    const iteration = String(record['iteration'] ?? '');
    for (const telemetry of telemetryList) {
      if (!isObject(telemetry)) {
        continue;
      }
      if (telemetry['compactionSkipped'] === true || telemetry['compaction_skipped'] === true) {
        continue;
      }
      const pathName = savingsPathFromFamily(String(telemetry['family'] ?? ''));
      if (!pathName) {
        continue;
      }
      const originalBytes = toInt(telemetry['originalBytes'] ?? telemetry['original_bytes']);
      if (originalBytes <= 0) {
        continue;
      }
      const compactedBytes = toInt(telemetry['compactedBytes'] ?? telemetry['compacted_bytes']);
      const key = `${planKey}\u0000${stageId}\u0000${iteration}\u0000${pathName}\u0000${originalBytes}\u0000${compactedBytes}`;
      if (seen.has(key)) {
        continue;
      }
      seen.add(key);
      const bucket = buckets[pathName];
      let originalTokens = toInt(telemetry['originalTokens'] ?? telemetry['original_tokens']);
      let compactedTokens = toInt(
        telemetry['compactedTokens'] ??
          telemetry['compacted_tokens'] ??
          telemetry['returnedTokens'] ??
          telemetry['returned_tokens'],
      );
      if (originalTokens <= 0) {
        originalTokens = estimateTokensFromBytes(originalBytes);
      }
      if (compactedTokens <= 0 && compactedBytes > 0) {
        compactedTokens = estimateTokensFromBytes(compactedBytes);
      }
      bucket.pre_optimization_bytes += originalBytes;
      bucket.post_optimization_bytes += compactedBytes;
      bucket.saved_bytes += Math.max(0, originalBytes - compactedBytes);
      bucket.pre_optimization_tokens += originalTokens;
      bucket.post_optimization_tokens += compactedTokens;
      bucket.saved_tokens += Math.max(0, originalTokens - compactedTokens);
      bucket.count += 1;
      if (telemetry['tokenCapTriggered'] === true || telemetry['token_cap_triggered'] === true) {
        bucket.token_cap_triggers += 1;
      }
      if (bucket.hidden_from_context !== undefined) {
        bucket.hidden_from_context += Math.max(0, originalBytes - compactedBytes);
      }
      if (bucket.hidden_from_context_tokens !== undefined) {
        bucket.hidden_from_context_tokens += Math.max(0, originalTokens - compactedTokens);
      }
    }
  }
  return buckets;
}

function mergeSavingsBucketsFromSummary(
  target: Record<SavingsPathName, SavingsBucket>,
  summaryRecord: UsageSummaryRecord,
): boolean {
  const bucketDescription = summaryRecord.byte_savings_by_path;
  if (!isObject(bucketDescription)) {
    return false;
  }
  let populated = false;
  for (const pathName of SAVINGS_PATH_NAMES) {
    const bucket = bucketDescription[pathName];
    if (!isObject(bucket)) {
      continue;
    }
    mergeSavingsBucket(target[pathName], bucket);
    if (hasSavings(target[pathName])) {
      populated = true;
    }
  }
  return populated;
}

async function collectSavingsForRecord(
  summaryPath: string,
  summaryRecord: UsageSummaryRecord,
): Promise<Record<SavingsPathName, SavingsBucket>> {
  const buckets = createEmptySavingsBuckets();
  if (mergeSavingsBucketsFromSummary(buckets, summaryRecord)) {
    return buckets;
  }
  const invocationsPath = join(dirname(summaryPath), 'invocation-usage.json');
  const invocationBuckets = await collectInvocationSavings(invocationsPath);
  mergeSavingsBuckets(buckets, invocationBuckets);
  if (Object.values(invocationBuckets).some(hasSavings)) {
    return buckets;
  }
  const compactionBuckets = await collectCompactionTelemetrySavings(invocationsPath);
  mergeSavingsBuckets(buckets, compactionBuckets);
  return buckets;
}

function parseTimestampMs(value: string | undefined): number | null {
  if (!value) {
    return null;
  }
  const parsed = Date.parse(value);
  return Number.isFinite(parsed) ? parsed : null;
}

function formatIsoDateMs(ms: number | null): string | null {
  if (ms === null) {
    return null;
  }
  const date = new Date(ms);
  return date.toISOString().replace(/\.\d{3}Z$/, 'Z');
}

function getBreakdownEntries(record: UsageSummaryRecord): ModelBreakdownItem[] {
  const breakdown = normalizeModelBreakdownRows(record.model_breakdown);
  if (breakdown && breakdown.length > 0) {
    return breakdown;
  }
  return [
    {
      runtime: record.runtime || '',
      model: record.model || '',
      invocations: toInt(record.invocations ?? record.steps ?? 1),
      elapsed_seconds: toNumber(record.elapsed_seconds),
      input_tokens: toNumber(record.input_tokens),
      output_tokens: toNumber(record.output_tokens),
      cache_creation_input_tokens: toNumber(record.cache_creation_input_tokens),
      cache_read_input_tokens: toNumber(record.cache_read_input_tokens),
      max_turn_total_tokens: toNumber(record.max_turn_total_tokens),
      cache_hit_ratio: toNumber(record.cache_hit_ratio),
      tool_calls_total: toNumber(record.tool_calls_total),
    },
  ];
}

function passesSavingsFilters(
  record: UsageSummaryRecord,
  summaryPath: string,
  runtimeFilter: string,
  modelFilter: string,
  planFilter: string,
): boolean {
  if (planFilter) {
    const planCandidates = new Set<string>();
    planCandidates.add(String(record.plan_key ?? '').trim());
    planCandidates.add(String(record.artifact_ns ?? '').trim());
    const directoryName = basename(dirname(summaryPath)).trim();
    if (directoryName) {
      planCandidates.add(directoryName);
    }
    if (![...planCandidates.values()].some((value) => value === planFilter)) {
      return false;
    }
  }
  const breakdown = getBreakdownEntries(record);
  if (runtimeFilter) {
    const matchesRuntime = breakdown.some((row) => String(row.runtime).trim() === runtimeFilter);
    if (!matchesRuntime) {
      return false;
    }
  }
  if (modelFilter) {
    const matchesModel = breakdown.some((row) => String(row.model).trim() === modelFilter);
    if (!matchesModel) {
      return false;
    }
  }
  return true;
}

function windowingLogForSummary(summaryPath: string): string | null {
  const logDir = dirname(summaryPath);
  const planKey = basename(logDir);
  if (!planKey) {
    return null;
  }
  const candidate = join(logDir, '..', '..', 'runtime-config', planKey, 'result-windowing.jsonl');
  return existsSync(candidate) ? candidate : null;
}

function recordPlanKey(record: Record<string, unknown>): string {
  return String(record['planKey'] ?? record['plan_key'] ?? '').trim();
}

function filterWindowingRecordsForPlanKey(
  records: Record<string, unknown>[],
  planKey?: string,
): Record<string, unknown>[] {
  const requested = String(planKey ?? '').trim();
  if (!requested) {
    return records;
  }
  const matching = records.filter((record) => recordPlanKey(record) === requested);
  return matching.length > 0 ? matching : records;
}

function analyzeResultWindowingLog(path: string, planKey?: string): ReadbackSummary {
  const empty: ReadbackSummary = {
    envelope_count: 0,
    readback_count: 0,
    raw_readback_count: 0,
    compacted_readback_count: 0,
    readback_bytes: 0,
    envelope_original_bytes: 0,
    full_preview_rereads: 0,
    raw_readback_share: 0,
    readback_negation_rate: 0,
    gross_readback_bytes: 0,
    gross_readback_tokens: 0,
    net_consumed_bytes: 0,
    net_consumed_tokens: 0,
    effective_windowing_savings_rate: 0,
  };
  let raw = '';
  try {
    raw = readFileSync(path, 'utf8');
  } catch {
    return empty;
  }
  const records: Record<string, unknown>[] = [];
  for (const line of raw.split('\n')) {
    const trimmed = line.trim();
    if (!trimmed) {
      continue;
    }
    try {
      const record = JSON.parse(trimmed) as Record<string, unknown>;
      records.push(record);
    } catch {
      continue;
    }
  }
  const envelopes = new Map<string, { original_bytes: number; returned_bytes: number; original_tokens: number; returned_tokens: number }>();
  const readbacks: Array<{ resultId?: string; view?: string; returnedBytes?: number; returnedTokens?: number }> = [];
  for (const record of filterWindowingRecordsForPlanKey(records, planKey)) {
    const event = String(record['event'] ?? '');
    const resultId = String(record['resultId'] ?? '');
    if (event === 'envelope' && resultId) {
      const originalBytes = toInt(record['originalBytes']);
      const returnedBytes = toInt(record['returnedBytes']);
      let originalTokens = toInt(record['originalTokens']);
      let returnedTokens = toInt(record['returnedTokens']);
      if (originalTokens <= 0 && returnedTokens <= 0 && originalBytes > 0) {
        originalTokens = estimateTokensFromBytes(originalBytes);
        returnedTokens = estimateTokensFromBytes(returnedBytes);
      }
      envelopes.set(resultId, {
        original_bytes: originalBytes,
        returned_bytes: returnedBytes,
        original_tokens: originalTokens,
        returned_tokens: returnedTokens,
      });
    } else if (event === 'readback' && resultId) {
      const returnedBytes = toInt(record['returnedBytes']);
      let returnedTokens = toInt(record['returnedTokens']);
      if (returnedTokens <= 0 && returnedBytes > 0) {
        returnedTokens = estimateTokensFromBytes(returnedBytes);
      }
      readbacks.push({
        resultId,
        view: String(record['view'] ?? 'compacted'),
        returnedBytes,
        returnedTokens,
      });
    }
  }
  let rawCount = 0;
  let compactedCount = 0;
  let readbackBytes = 0;
  let grossReadbackTokens = 0;
  let fullRereads = 0;
  for (const record of readbacks) {
    const returned = toInt(record.returnedBytes);
    const returnedTokens = toInt(record.returnedTokens);
    readbackBytes += returned;
    grossReadbackTokens += returnedTokens;
    if (record.view === 'raw') {
      rawCount += 1;
    } else {
      compactedCount += 1;
    }
    const envelope = record.resultId ? envelopes.get(record.resultId) : undefined;
    if (envelope && returned > 0) {
      const preview = envelope.returned_bytes;
      if (preview > 0 && returned >= Math.floor(preview * 0.95)) {
        fullRereads += 1;
      }
    }
  }
  const envelopeBytes = [...envelopes.values()].reduce(
    (sum, item) => sum + item.original_bytes,
    0,
  );
  const envelopeTokens = [...envelopes.values()].reduce(
    (sum, item) => sum + item.original_tokens,
    0,
  );
  let netConsumedBytes = 0;
  let netConsumedTokens = 0;
  for (const [resultId, envelope] of envelopes) {
    let extraBytes = 0;
    let extraTokens = 0;
    for (const readback of readbacks) {
      if (readback.resultId === resultId) {
        extraBytes += toInt(readback.returnedBytes);
        extraTokens += toInt(readback.returnedTokens);
      }
    }
    const consumedBytes = envelope.returned_bytes + extraBytes;
    const consumedTokens = envelope.returned_tokens + extraTokens;
    netConsumedBytes +=
      envelope.original_bytes > 0 ? Math.min(envelope.original_bytes, consumedBytes) : consumedBytes;
    netConsumedTokens +=
      envelope.original_tokens > 0
        ? Math.min(envelope.original_tokens, consumedTokens)
        : consumedTokens;
  }
  const totalReadbacks = rawCount + compactedCount;
  const rawShare = totalReadbacks > 0 ? Math.round((rawCount / totalReadbacks) * 10000) / 10000 : 0;
  const negationRate =
    envelopeBytes > 0 ? Math.round((readbackBytes / envelopeBytes) * 10000) / 10000 : 0;
  const effectiveRate =
    envelopeBytes > 0
      ? Math.round(((envelopeBytes - netConsumedBytes) / envelopeBytes) * 10000) / 10000
      : 0;
  return {
    envelope_count: envelopes.size,
    readback_count: totalReadbacks,
    raw_readback_count: rawCount,
    compacted_readback_count: compactedCount,
    readback_bytes: readbackBytes,
    envelope_original_bytes: envelopeBytes,
    full_preview_rereads: fullRereads,
    raw_readback_share: rawShare,
    readback_negation_rate: negationRate,
    gross_readback_bytes: readbackBytes,
    gross_readback_tokens: grossReadbackTokens,
    net_consumed_bytes: netConsumedBytes,
    net_consumed_tokens: netConsumedTokens,
    effective_windowing_savings_rate: effectiveRate,
  };
}

function savingsPathStatusLabel(status: string): string {
  switch (status) {
    case 'negated':
      return 'negated by readback';
    default:
      return status;
  }
}

function savingsPathStatus(
  pathName: SavingsPathName,
  bucket: SavingsBucket,
  readbackStats: ReadbackSummary,
): string {
  const preBytes = bucket.pre_optimization_bytes;
  const savedBytes = bucket.saved_bytes;
  const count = bucket.count;
  if (preBytes <= 0 && count <= 0) {
    return 'inactive';
  }
  if (savedBytes > 0) {
    return 'saved';
  }
  if (pathName === 'result_windowing' && readbackStats.readback_count > 0 && preBytes > 0) {
    return 'negated';
  }
  if (preBytes > 0 || count > 0) {
    return 'active';
  }
  return 'inactive';
}

function mergeReadbackSummary(target: ReadbackSummary, source: ReadbackSummary): void {
  target.envelope_count += source.envelope_count;
  target.readback_count += source.readback_count;
  target.raw_readback_count += source.raw_readback_count;
  target.compacted_readback_count += source.compacted_readback_count;
  target.readback_bytes += source.readback_bytes;
  target.envelope_original_bytes += source.envelope_original_bytes;
  target.full_preview_rereads += source.full_preview_rereads;
  target.gross_readback_bytes += source.gross_readback_bytes;
  target.gross_readback_tokens += source.gross_readback_tokens;
  target.net_consumed_bytes += source.net_consumed_bytes;
  target.net_consumed_tokens += source.net_consumed_tokens;
  // Recalculate derived ratios after aggregation.
  if (target.readback_count > 0) {
    target.raw_readback_share = Math.round((target.raw_readback_count / target.readback_count) * 10000) / 10000;
  }
  if (target.envelope_original_bytes > 0) {
    target.readback_negation_rate =
      Math.round((target.readback_bytes / target.envelope_original_bytes) * 10000) / 10000;
    target.effective_windowing_savings_rate =
      Math.round(
        ((target.envelope_original_bytes - target.net_consumed_bytes) / target.envelope_original_bytes) * 10000,
      ) / 10000;
  }
}

function emptyReadbackSummary(): ReadbackSummary {
  return {
    envelope_count: 0,
    readback_count: 0,
    raw_readback_count: 0,
    compacted_readback_count: 0,
    readback_bytes: 0,
    envelope_original_bytes: 0,
    full_preview_rereads: 0,
    raw_readback_share: 0,
    readback_negation_rate: 0,
    gross_readback_bytes: 0,
    gross_readback_tokens: 0,
    net_consumed_bytes: 0,
    net_consumed_tokens: 0,
    effective_windowing_savings_rate: 0,
  };
}

interface ParsedWindowingEnvelope {
  result_id: string;
  original_bytes: number;
  returned_bytes: number;
  original_tokens: number;
  returned_tokens: number;
  token_cap_triggered: number;
  channel: string | null;
}

interface ParsedWindowingReadback {
  result_id: string;
  view: string;
  returned_bytes: number;
  returned_tokens: number;
  source_result_channel: string | null;
}

interface ChannelReadbackStats {
  gross_readback_bytes: number;
  gross_readback_tokens: number;
  net_consumed_bytes: number;
  net_consumed_tokens: number;
}

function stateDirForSummary(summaryPath: string): string | null {
  const logDir = dirname(summaryPath);
  const planKey = basename(logDir);
  if (!planKey) {
    return null;
  }
  const candidate = join(logDir, '..', '..', 'runtime-config', planKey);
  return existsSync(candidate) ? candidate : null;
}

function loadWindowingRecords(path: string): Record<string, unknown>[] {
  let raw = '';
  try {
    raw = readFileSync(path, 'utf8');
  } catch {
    return [];
  }
  const records: Record<string, unknown>[] = [];
  for (const line of raw.split('\n')) {
    const trimmed = line.trim();
    if (!trimmed) {
      continue;
    }
    try {
      const record = JSON.parse(trimmed) as Record<string, unknown>;
      records.push(record);
    } catch {
      continue;
    }
  }
  return records;
}

function recordMatchesPlanKey(record: Record<string, unknown>, planKey: string): boolean {
  const planKeyForRecord = recordPlanKey(record);
  if (planKey && planKeyForRecord && planKeyForRecord !== planKey) {
    return false;
  }
  return true;
}

function parseWindowingEnvelope(record: Record<string, unknown>): ParsedWindowingEnvelope | null {
  const resultId = String(record['resultId'] ?? '').trim();
  if (!resultId) {
    return null;
  }
  const originalBytes = toInt(record['originalBytes']);
  const returnedBytes = toInt(record['returnedBytes']);
  let originalTokens = toInt(record['originalTokens']);
  let returnedTokens = toInt(record['returnedTokens']);
  if (originalTokens <= 0 && returnedTokens <= 0 && originalBytes > 0) {
    originalTokens = estimateTokensFromBytes(originalBytes);
    returnedTokens = estimateTokensFromBytes(returnedBytes);
  }
  return {
    result_id: resultId,
    original_bytes: originalBytes,
    returned_bytes: returnedBytes,
    original_tokens: originalTokens,
    returned_tokens: returnedTokens,
    token_cap_triggered: toInt(record['tokenCapTriggered'] ?? record['token_cap_triggered']),
    channel: String(record['channel'] ?? '').trim() || null,
  };
}

function parseWindowingReadback(record: Record<string, unknown>): ParsedWindowingReadback | null {
  const resultId = String(record['resultId'] ?? '').trim();
  if (!resultId) {
    return null;
  }
  const returnedBytes = toInt(record['returnedBytes']);
  let returnedTokens = toInt(record['returnedTokens']);
  if (returnedTokens <= 0 && returnedBytes > 0) {
    returnedTokens = estimateTokensFromBytes(returnedBytes);
  }
  const sourceChannel = String(
    record['sourceResultChannel'] ?? record['source_result_channel'] ?? '',
  ).trim();
  return {
    result_id: resultId,
    view: String(record['view'] ?? 'compacted').toLowerCase(),
    returned_bytes: returnedBytes,
    returned_tokens: returnedTokens,
    source_result_channel: sourceChannel || null,
  };
}

function resolveResultChannelTarget(
  envelope: ParsedWindowingEnvelope,
  readbacks: ParsedWindowingReadback[],
): [WindowingChannelName, ChannelAttribution] {
  const envelopeChannel = envelope.channel ?? '';
  if (!envelopeChannel) {
    return ['stored_result_readback', 'legacy'];
  }
  if (!readbacks.length) {
    const channel = WINDOWING_CHANNEL_NAMES.includes(envelopeChannel as WindowingChannelName)
      ? (envelopeChannel as WindowingChannelName)
      : 'stored_result_readback';
    return [channel, 'exact'];
  }
  for (const readback of readbacks) {
    const sourceChannel = readback.source_result_channel ?? '';
    if (!sourceChannel) {
      return ['stored_result_readback', 'legacy'];
    }
    if (sourceChannel !== envelopeChannel) {
      return ['stored_result_readback', 'legacy'];
    }
  }
  const channel = WINDOWING_CHANNEL_NAMES.includes(envelopeChannel as WindowingChannelName)
    ? (envelopeChannel as WindowingChannelName)
    : 'stored_result_readback';
  return [channel, 'exact'];
}

function emptyChannelReadbackStats(): Record<WindowingChannelName, ChannelReadbackStats> {
  const stats = {} as Record<WindowingChannelName, ChannelReadbackStats>;
  for (const channelName of WINDOWING_CHANNEL_NAMES) {
    stats[channelName] = {
      gross_readback_bytes: 0,
      gross_readback_tokens: 0,
      net_consumed_bytes: 0,
      net_consumed_tokens: 0,
    };
  }
  return stats;
}

function aggregateWindowingSavingsByChannel(
  path: string,
  planKey?: string,
): Record<WindowingChannelName, ChannelBucket> {
  const buckets = createEmptyChannelBuckets();
  const records = filterWindowingRecordsForPlanKey(loadWindowingRecords(path), planKey);
  const envelopes = new Map<string, ParsedWindowingEnvelope>();
  const readbacks: ParsedWindowingReadback[] = [];
  const legacyEvents: Array<{
    original_bytes: number;
    returned_bytes: number;
    original_tokens: number;
    returned_tokens: number;
    token_cap: number;
  }> = [];

  for (const record of records) {
    const event = String(record['event'] ?? '').trim().toLowerCase();
    const resultId = String(record['resultId'] ?? '').trim();
    if (event === 'envelope' && resultId) {
      const parsed = parseWindowingEnvelope(record);
      if (parsed) {
        envelopes.set(parsed.result_id, parsed);
      }
    } else if (event === 'readback' && resultId) {
      const parsed = parseWindowingReadback(record);
      if (parsed) {
        readbacks.push(parsed);
      }
    } else if (event !== 'envelope' && event !== 'readback' && !resultId) {
      const originalBytes = toInt(record['originalBytes']);
      const returnedBytes = toInt(record['returnedBytes'] ?? record['postBytes']);
      let originalTokens = toInt(record['originalTokens']);
      let returnedTokens = toInt(record['returnedTokens'] ?? record['returned_tokens']);
      const tokenCap = toInt(record['tokenCapTriggered'] ?? record['token_cap_triggered']);
      if (originalTokens <= 0 && returnedTokens <= 0 && originalBytes > 0) {
        originalTokens = estimateTokensFromBytes(originalBytes);
        returnedTokens = estimateTokensFromBytes(returnedBytes);
      }
      legacyEvents.push({
        original_bytes: originalBytes,
        returned_bytes: returnedBytes,
        original_tokens: originalTokens,
        returned_tokens: returnedTokens,
        token_cap: tokenCap,
      });
    }
  }

  const groupedReadbacks = new Map<string, ParsedWindowingReadback[]>();
  for (const readback of readbacks) {
    const group = groupedReadbacks.get(readback.result_id) ?? [];
    group.push(readback);
    groupedReadbacks.set(readback.result_id, group);
  }

  for (const [resultId, envelope] of envelopes) {
    const resultReadbacks = groupedReadbacks.get(resultId) ?? [];
    const extraBytes = resultReadbacks.reduce((sum, item) => sum + item.returned_bytes, 0);
    const extraTokens = resultReadbacks.reduce((sum, item) => sum + item.returned_tokens, 0);
    const consumedBytes = envelope.returned_bytes + extraBytes;
    const consumedTokens = envelope.returned_tokens + extraTokens;
    const netPostBytes =
      envelope.original_bytes > 0 ? Math.min(envelope.original_bytes, consumedBytes) : consumedBytes;
    const netPostTokens =
      envelope.original_tokens > 0
        ? Math.min(envelope.original_tokens, consumedTokens)
        : consumedTokens;
    const [channelName, attribution] = resolveResultChannelTarget(envelope, resultReadbacks);
    const bucket = buckets[channelName];
    accumulateChannelSavingsEvent(bucket, {
      preBytes: envelope.original_bytes,
      postBytes: netPostBytes,
      preTokens: envelope.original_tokens,
      postTokens: netPostTokens,
      tokenCapTrigger: envelope.token_cap_triggered > 0,
    });
    markChannelAttribution(bucket, attribution);
  }

  const legacyBucket = buckets['stored_result_readback'];
  for (const entry of legacyEvents) {
    accumulateChannelSavingsEvent(legacyBucket, {
      preBytes: entry.original_bytes,
      postBytes: entry.returned_bytes,
      preTokens: entry.original_tokens,
      postTokens: entry.returned_tokens,
      tokenCapTrigger: entry.token_cap > 0,
    });
    markChannelAttribution(legacyBucket, 'legacy');
  }

  return finalizeChannelBuckets(buckets);
}

function windowingReadbackByChannel(path: string, planKey?: string): Record<WindowingChannelName, ChannelReadbackStats> {
  const stats = emptyChannelReadbackStats();
  const records = filterWindowingRecordsForPlanKey(loadWindowingRecords(path), planKey);
  const envelopes = new Map<string, ParsedWindowingEnvelope>();
  const readbacks: ParsedWindowingReadback[] = [];

  for (const record of records) {
    const event = String(record['event'] ?? '').trim().toLowerCase();
    const resultId = String(record['resultId'] ?? '').trim();
    if (event === 'envelope' && resultId) {
      const parsed = parseWindowingEnvelope(record);
      if (parsed) {
        envelopes.set(parsed.result_id, parsed);
      }
    } else if (event === 'readback' && resultId) {
      const parsed = parseWindowingReadback(record);
      if (parsed) {
        readbacks.push(parsed);
      }
    }
  }

  const groupedReadbacks = new Map<string, ParsedWindowingReadback[]>();
  for (const readback of readbacks) {
    const group = groupedReadbacks.get(readback.result_id) ?? [];
    group.push(readback);
    groupedReadbacks.set(readback.result_id, group);
  }

  for (const [resultId, envelope] of envelopes) {
    const resultReadbacks = groupedReadbacks.get(resultId) ?? [];
    const extraBytes = resultReadbacks.reduce((sum, item) => sum + item.returned_bytes, 0);
    const extraTokens = resultReadbacks.reduce((sum, item) => sum + item.returned_tokens, 0);
    const consumedBytes = envelope.returned_bytes + extraBytes;
    const consumedTokens = envelope.returned_tokens + extraTokens;
    const netPostBytes =
      envelope.original_bytes > 0 ? Math.min(envelope.original_bytes, consumedBytes) : consumedBytes;
    const netPostTokens =
      envelope.original_tokens > 0
        ? Math.min(envelope.original_tokens, consumedTokens)
        : consumedTokens;
    const [channelName] = resolveResultChannelTarget(envelope, resultReadbacks);
    const bucket = stats[channelName];
    bucket.gross_readback_bytes += extraBytes;
    bucket.gross_readback_tokens += extraTokens;
    bucket.net_consumed_bytes += netPostBytes;
    bucket.net_consumed_tokens += netPostTokens;
  }

  return stats;
}

function enrichChannelDiagnostics(
  perChannel: Record<WindowingChannelName, ChannelBucket>,
  readbackByChannel: Record<WindowingChannelName, ChannelReadbackStats> | null,
): void {
  for (const channelName of WINDOWING_CHANNEL_NAMES) {
    const bucket = perChannel[channelName];
    if (['native_shell_hook', 'proxy_shell', 'native_result_hook'].includes(channelName)) {
      bucket.gross_hidden_bytes = bucket.hidden_from_context ?? 0;
      bucket.gross_hidden_tokens = bucket.hidden_from_context_tokens ?? 0;
    }

    if (readbackByChannel) {
      const channelStats = readbackByChannel[channelName];
      const grossReadbackBytes = channelStats.gross_readback_bytes;
      const netConsumedBytes = channelStats.net_consumed_bytes;
      if (grossReadbackBytes > 0) {
        bucket.gross_readback_bytes = grossReadbackBytes;
        bucket.gross_readback_tokens = channelStats.gross_readback_tokens;
      }
      if (netConsumedBytes > 0) {
        bucket.net_consumed_bytes = netConsumedBytes;
        bucket.net_consumed_tokens = channelStats.net_consumed_tokens;
      }
    }

    if (
      bucket.net_consumed_bytes === undefined &&
      ['proxy_read_windowing', 'proxy_search_windowing', 'native_result_mcp_fallback', 'stored_result_readback'].includes(
        channelName,
      ) &&
      bucket.count > 0
    ) {
      bucket.net_consumed_bytes = bucket.post_optimization_bytes;
      bucket.net_consumed_tokens = bucket.post_optimization_tokens;
    }
  }
}

function accumulateCompactJsonl(
  path: string,
  channelName: WindowingChannelName,
  planKey: string,
  buckets: Record<WindowingChannelName, ChannelBucket>,
): void {
  if (!existsSync(path)) {
    return;
  }
  const bucket = buckets[channelName];
  for (const record of loadWindowingRecords(path)) {
    if (!recordMatchesPlanKey(record, planKey)) {
      continue;
    }
    if (record['compactionSkipped'] === true) {
      continue;
    }
    const originalBytes = toInt(record['originalBytes']);
    const compactedBytes = toInt(record['compactedBytes']);
    let originalTokens = toInt(record['originalTokens'] ?? record['original_tokens']);
    let compactedTokens = toInt(
      record['compactedTokens'] ?? record['compacted_tokens'] ?? record['returnedTokens'] ?? record['returned_tokens'],
    );
    const tokenCap = toInt(record['tokenCapTriggered'] ?? record['token_cap_triggered']) > 0;
    if (originalTokens <= 0 && compactedTokens <= 0 && originalBytes > 0) {
      originalTokens = estimateTokensFromBytes(originalBytes);
      compactedTokens = estimateTokensFromBytes(compactedBytes);
    }
    accumulateChannelSavingsEvent(bucket, {
      preBytes: originalBytes,
      postBytes: compactedBytes,
      preTokens: originalTokens,
      postTokens: compactedTokens,
      tokenCapTrigger: tokenCap,
    });
  }
}

function aggregateByteSavingsByChannel(stateDir: string, planKey: string): Record<WindowingChannelName, ChannelBucket> {
  const buckets = createEmptyChannelBuckets();
  if (!stateDir) {
    return buckets;
  }

  accumulateCompactJsonl(join(stateDir, 'bash-compact.jsonl'), 'native_result_hook', planKey, buckets);
  accumulateCompactJsonl(join(stateDir, 'proxy-shell-compact.jsonl'), 'proxy_shell', planKey, buckets);

  const windowPath = join(stateDir, 'result-windowing.jsonl');
  if (existsSync(windowPath)) {
    const windowChannels = aggregateWindowingSavingsByChannel(windowPath, planKey || undefined);
    for (const channelName of WINDOWING_CHANNEL_NAMES) {
      mergeChannelBucket(buckets[channelName], windowChannels[channelName] as unknown as Record<string, unknown>);
    }
  }

  return finalizeChannelBuckets(buckets);
}

async function aggregateInvocationChannels(
  path: string,
  planKey: string,
): Promise<Record<WindowingChannelName, ChannelBucket>> {
  const out = createEmptyChannelBuckets();
  if (!existsSync(path)) {
    return out;
  }
  let payload: unknown;
  try {
    payload = JSON.parse(await fs.readFile(path, 'utf8'));
  } catch {
    return out;
  }
  if (!isObject(payload)) {
    return out;
  }
  const invocations = Array.isArray(payload['invocations']) ? payload['invocations'] : [];
  const targetPlanKey = planKey.trim();
  const latest = new Map<string, ChannelBucket>();

  for (const record of invocations) {
    if (!isObject(record)) {
      continue;
    }
    const channelSavings = record['byte_savings_by_channel'];
    if (!isObject(channelSavings)) {
      continue;
    }
    const recordPlan = String(record['plan_key'] ?? '').trim();
    if (targetPlanKey && recordPlan && recordPlan !== targetPlanKey) {
      continue;
    }
    for (const channelName of WINDOWING_CHANNEL_NAMES) {
      const pathData = channelSavings[channelName];
      if (!isObject(pathData)) {
        continue;
      }
      const bucket = createEmptyChannelBucket('exact');
      mergeChannelBucket(bucket, pathData);
      latest.set(`${targetPlanKey || recordPlan}\u0000${channelName}`, bucket);
    }
  }

  for (const [key, channelBucket] of latest) {
    const channelName = key.split('\u0000')[1] as WindowingChannelName;
    if (WINDOWING_CHANNEL_NAMES.includes(channelName)) {
      mergeChannelBucket(out[channelName], channelBucket as unknown as Record<string, unknown>);
    }
  }

  return finalizeChannelBuckets(out);
}

async function summaryChannels(
  summaryPath: string,
  summary: UsageSummaryRecord,
  planKey: string,
): Promise<Record<WindowingChannelName, ChannelBucket>> {
  const channelData = summary.byte_savings_by_channel;
  if (isObject(channelData)) {
    const out = createEmptyChannelBuckets();
    for (const channelName of WINDOWING_CHANNEL_NAMES) {
      const rawBucket = channelData[channelName];
      if (isObject(rawBucket)) {
        mergeChannelBucket(out[channelName], rawBucket);
      }
    }
    if (Object.values(out).some(channelHasActivity)) {
      return finalizeChannelBuckets(out);
    }
  }

  const invocationPath = join(dirname(summaryPath), 'invocation-usage.json');
  const invocationChannels = await aggregateInvocationChannels(invocationPath, planKey);
  if (Object.values(invocationChannels).some(channelHasActivity)) {
    return invocationChannels;
  }

  const stateDir = stateDirForSummary(summaryPath);
  if (stateDir) {
    return aggregateByteSavingsByChannel(stateDir, planKey);
  }

  return createEmptyChannelBuckets();
}

function loadDiscoverReportForSummary(summaryPath: string): Record<string, unknown> | null {
  const discoverPath = join(dirname(summaryPath), 'discover-report.json');
  if (!existsSync(discoverPath)) {
    return null;
  }
  try {
    const parsed = JSON.parse(readFileSync(discoverPath, 'utf8')) as unknown;
    return isObject(parsed) ? parsed : null;
  } catch {
    return null;
  }
}

function normalizeOptimizationOpportunities(
  discover: Record<string, unknown>,
): Record<string, unknown> | null {
  const out: Record<string, unknown> = {};

  const missed = discover['missed_compaction_opportunities'];
  if (Array.isArray(missed) && missed.length > 0) {
    const deduped: Record<string, unknown>[] = [];
    const seen = new Set<string>();
    for (const item of missed) {
      if (!isObject(item)) {
        continue;
      }
      const key = JSON.stringify(item, Object.keys(item).sort());
      if (seen.has(key)) {
        continue;
      }
      seen.add(key);
      deduped.push({ ...item });
    }
    if (deduped.length > 0) {
      out['missed_compaction_opportunities'] = deduped;
    }
  }

  const patterns = discover['sequence_patterns'];
  if (Array.isArray(patterns) && patterns.length > 0) {
    out['sequence_patterns'] = patterns;
  }

  const storedUsage = discover['stored_result_usage'];
  if (isObject(storedUsage)) {
    const recommendation = storedUsage['recommendation'];
    if (recommendation) {
      out['stored_result_usage'] = { recommendation };
    }
  }

  const findings = discover['aggregate_findings'];
  if (Array.isArray(findings)) {
    const nativeReadFindings = findings.filter(
      (item) => isObject(item) && String(item['pattern_id'] ?? '').startsWith('heavy_native_read'),
    );
    if (nativeReadFindings.length > 0) {
      out['native_read_findings'] = nativeReadFindings;
    }
  }

  return Object.keys(out).length > 0 ? out : null;
}

async function buildSavingsReport(summaryPaths: string[]): Promise<SavingsReport> {
  if (summaryPaths.length === 0) {
    return emptySavingsReport();
  }

  const aggregateBuckets = createEmptySavingsBuckets();
  let runCount = 0;
  let startedAtMs: number | null = null;
  let endedAtMs: number | null = null;
  let inputTokens = 0;
  let outputTokens = 0;
  let cacheCreationTokens = 0;
  let cacheReadTokens = 0;
  let promptBytes = 0;
  let toolCallsTotal = 0;
  let couldHaveSavedBytes = 0;
  const readbackTotals = emptyReadbackSummary();
  const aggregateChannels = createEmptyChannelBuckets();
  const aggregateReadbackByChannel = emptyChannelReadbackStats();
  const discoverCandidates: Array<{ endedAtMs: number | null; summaryPath: string; planKey: string; endedAtIso: string | null }> = [];

  for (const summaryPath of summaryPaths) {
    let record: UsageSummaryRecord;
    try {
      const raw = await fs.readFile(summaryPath, 'utf8');
      record = JSON.parse(raw) as UsageSummaryRecord;
    } catch {
      continue;
    }

    runCount += toInt(record.invocations ?? record.steps ?? 1);
    inputTokens += toNumber(record.input_tokens);
    outputTokens += toNumber(record.output_tokens);
    cacheCreationTokens += toNumber(record.cache_creation_input_tokens);
    cacheReadTokens += toNumber(record.cache_read_input_tokens);
    promptBytes += toInt(record.prompt_bytes);
    toolCallsTotal += toInt(record.tool_calls_total);
    couldHaveSavedBytes += toInt(record.compaction_measured_not_applied_bytes);

    const startMs = parseTimestampMs(record.started_at);
    if (startMs !== null && (startedAtMs === null || startMs < startedAtMs)) {
      startedAtMs = startMs;
    }
    const endMs = parseTimestampMs(record.ended_at);
    if (endMs !== null && (endedAtMs === null || endMs > endedAtMs)) {
      endedAtMs = endMs;
    }

    const recordBuckets = await collectSavingsForRecord(summaryPath, record);
    mergeSavingsBuckets(aggregateBuckets, recordBuckets);

    const windowingLog = windowingLogForSummary(summaryPath);
    const planKey = String(record.plan_key ?? '').trim() || basename(dirname(summaryPath)).trim();
    if (windowingLog) {
      mergeReadbackSummary(readbackTotals, analyzeResultWindowingLog(windowingLog, planKey));
    }

    const runChannels = await summaryChannels(summaryPath, record, planKey);
    const runReadbackByChannel = windowingLog
      ? windowingReadbackByChannel(windowingLog, planKey)
      : null;
    enrichChannelDiagnostics(runChannels, runReadbackByChannel);
    mergeChannelBuckets(aggregateChannels, runChannels);
    for (const channelName of WINDOWING_CHANNEL_NAMES) {
      const runBucket = runChannels[channelName];
      const target = aggregateReadbackByChannel[channelName];
      target.gross_readback_bytes += toInt(runBucket.gross_readback_bytes);
      target.gross_readback_tokens += toInt(runBucket.gross_readback_tokens);
      target.net_consumed_bytes += toInt(runBucket.net_consumed_bytes);
      target.net_consumed_tokens += toInt(runBucket.net_consumed_tokens);
    }

    discoverCandidates.push({
      endedAtMs: endMs,
      summaryPath,
      planKey,
      endedAtIso: formatIsoDateMs(endMs),
    });
  }

  discoverCandidates.sort((a, b) => {
    const aScore = a.endedAtMs ?? 0;
    const bScore = b.endedAtMs ?? 0;
    return bScore - aScore;
  });
  let optimizationOpportunities: Record<string, unknown> | null = null;
  let optimizationOpportunitiesSource: { plan_key: string; ended_at: string | null } | null = null;
  for (const candidate of discoverCandidates) {
    const discoverData = loadDiscoverReportForSummary(candidate.summaryPath);
    if (discoverData) {
      const normalized = normalizeOptimizationOpportunities(discoverData);
      if (normalized) {
        optimizationOpportunities = normalized;
        optimizationOpportunitiesSource = {
          plan_key: candidate.planKey,
          ended_at: candidate.endedAtIso,
        };
        break;
      }
    }
  }

  finalizeAllSavingsBuckets(aggregateBuckets);

  let savedBytes = 0;
  let savedTokens = 0;
  let preOptimizationBytes = 0;

  const perPath = {} as Record<SavingsPathName, SavingsBucket>;
  for (const pathName of SAVINGS_PATH_NAMES) {
    const bucket = aggregateBuckets[pathName];
    const status = savingsPathStatus(pathName, bucket, readbackTotals);
    bucket.status = status;
    bucket.status_label = savingsPathStatusLabel(status);
    perPath[pathName] = bucket;
    savedBytes += bucket.saved_bytes;
    savedTokens += bucket.saved_tokens;
    preOptimizationBytes += bucket.pre_optimization_bytes;
  }

  const savingsPercent =
    preOptimizationBytes > 0 ? roundOneDecimal((savedBytes / preOptimizationBytes) * 100) : 0;
  const cacheHitRatio = cacheEfficiencyRatio(inputTokens, cacheCreationTokens, cacheReadTokens);

  // Add diagnostic fields to per-path buckets to mirror Python schema v2.
  for (const pathName of SAVINGS_PATH_NAMES) {
    const bucket = perPath[pathName];
    if (SAVINGS_PATHS_WITH_HIDDEN.has(pathName)) {
      bucket.gross_hidden_bytes = bucket.hidden_from_context ?? 0;
      bucket.gross_hidden_tokens = bucket.hidden_from_context_tokens ?? 0;
    }
    if (pathName === 'result_windowing') {
      bucket.gross_readback_bytes = readbackTotals.gross_readback_bytes;
      bucket.gross_readback_tokens = readbackTotals.gross_readback_tokens;
      bucket.net_readback_cost_bytes = Math.max(
        0,
        readbackTotals.net_consumed_bytes - bucket.post_optimization_bytes,
      );
      bucket.effective_windowing_savings_rate = readbackTotals.effective_windowing_savings_rate;
    }
    if (pathName === 'proxy_shell_compaction') {
      bucket.compaction_measured_not_applied_bytes = couldHaveSavedBytes;
    }
  }

  const perChannel = finalizeChannelBuckets(aggregateChannels);
  enrichChannelDiagnostics(perChannel, aggregateReadbackByChannel);

  if (
    optimizationOpportunities &&
    hasMeaningfulOptimizationEvidence(perPath, perChannel) &&
    optimizationOpportunities['missed_compaction_opportunities']
  ) {
    delete optimizationOpportunities['missed_compaction_opportunities'];
    if (Object.keys(optimizationOpportunities).length === 0) {
      optimizationOpportunities = null;
      optimizationOpportunitiesSource = null;
    }
  }

  // Compute tool-output counterfactuals that mirror ralph-benchmark-report.py.
  let hypotheticalWithoutRalphBytes = 0;
  let actualWithRalphBytes = 0;
  for (const pathName of SAVINGS_PATH_NAMES) {
    const bucket = perPath[pathName];
    hypotheticalWithoutRalphBytes += bucket.pre_optimization_bytes;
    actualWithRalphBytes += bucket.post_optimization_bytes;
  }

  // Result-windowing buckets already reflect net post in saved_bytes; derive
  // aggregate counterfactual totals from the summary bucket's pre/post bytes
  // to stay aligned with ralph-benchmark-report.py's aggregate_windowing_totals.
  const windowOriginalBytes = perPath['result_windowing'].pre_optimization_bytes;
  const windowReturnedBytes = perPath['result_windowing'].post_optimization_bytes;
  if (windowOriginalBytes > 0) {
    hypotheticalWithoutRalphBytes +=
      windowOriginalBytes - perPath['result_windowing'].pre_optimization_bytes;
    actualWithRalphBytes += windowReturnedBytes - perPath['result_windowing'].post_optimization_bytes;
  }
  // When no windowing summary bucket is present but a readback log is, add
  // net readback cost so actual_with_ralph includes re-consumed bytes.
  else if (readbackTotals.envelope_original_bytes > 0) {
    actualWithRalphBytes += Math.max(
      0,
      perPath['result_windowing'].net_readback_cost_bytes ?? 0,
    );
  }
  hypotheticalWithoutRalphBytes = Math.max(0, hypotheticalWithoutRalphBytes);
  actualWithRalphBytes = Math.max(0, actualWithRalphBytes);

  const hypotheticalWithoutRalphTokens = estimateTokensFromBytes(hypotheticalWithoutRalphBytes);
  const actualWithRalphTokens = estimateTokensFromBytes(actualWithRalphBytes);
  const netSavingsBytes = Math.max(0, hypotheticalWithoutRalphBytes - actualWithRalphBytes);
  const netSavingsTokens = Math.max(0, hypotheticalWithoutRalphTokens - actualWithRalphTokens);
  const netSavingsPercent =
    hypotheticalWithoutRalphBytes > 0
      ? roundOneDecimal((netSavingsBytes / hypotheticalWithoutRalphBytes) * 100)
      : 0;

  const counterfactualOpportunityBytes = Math.max(0, couldHaveSavedBytes);
  const counterfactualOpportunityTokens = estimateTokensFromBytes(counterfactualOpportunityBytes);

  const sessionUsage: SessionUsage = {
    input_tokens: inputTokens,
    output_tokens: outputTokens,
    cache_creation_input_tokens: cacheCreationTokens,
    cache_read_input_tokens: cacheReadTokens,
    prompt_bytes: promptBytes,
    tool_calls_total: toolCallsTotal,
  };

  const toolOutputCounterfactual: ToolOutputCounterfactual = {
    hypothetical_without_ralph_bytes: hypotheticalWithoutRalphBytes,
    actual_with_ralph_bytes: actualWithRalphBytes,
    net_savings_bytes: netSavingsBytes,
    hypothetical_without_ralph_tokens: hypotheticalWithoutRalphTokens,
    actual_with_ralph_tokens: actualWithRalphTokens,
    net_savings_tokens: netSavingsTokens,
    net_savings_percent: netSavingsPercent,
    compaction_measured_not_applied_bytes: counterfactualOpportunityBytes,
    compaction_measured_not_applied_tokens: counterfactualOpportunityTokens,
  };

  return {
    schema_version: 2,
    kind: 'ralph_benchmark_report',
    run_count: runCount,
    date_range: {
      started_at: formatIsoDateMs(startedAtMs),
      ended_at: formatIsoDateMs(endedAtMs),
    },
    saved_bytes: savedBytes,
    saved_tokens: savedTokens,
    savings_percent: savingsPercent,
    session_usage: sessionUsage,
    tool_output_counterfactual: toolOutputCounterfactual,
    per_path: perPath,
    per_channel: perChannel,
    cache: {
      cache_read_tokens: cacheReadTokens,
      cache_hit_ratio: cacheHitRatio,
    },
    could_have_saved: {
      compaction_measured_not_applied_bytes: couldHaveSavedBytes,
    },
    readback_summary: {
      ...readbackTotals,
      raw_readback_share:
        readbackTotals.readback_count > 0
          ? Math.round((readbackTotals.raw_readback_count / readbackTotals.readback_count) * 10000) /
            10000
          : 0,
      readback_negation_rate:
        readbackTotals.envelope_original_bytes > 0
          ? Math.round(
              (readbackTotals.readback_bytes / readbackTotals.envelope_original_bytes) * 10000,
            ) / 10000
          : 0,
    },
    optimization_opportunities: optimizationOpportunities,
    optimization_opportunities_source: optimizationOpportunitiesSource,
  };
}

function normalizeAggregatePath(pathParam: string): string {
  return pathParam.replace(/^\/+/, '').replace(/\/+$/, '');
}

async function collectAggregatedEntriesFromRoots(
  roots: string[],
  relPath: string,
): Promise<AggregatedListingEntry[]> {
  const entriesMap = new Map<string, AggregatedListingEntry>();
  const normalized = normalizeAggregatePath(relPath);
  const multiRoot = roots.length > 1;

  for (const root of roots) {
    const target = normalized ? join(root, normalized) : root;
    const workspaceRootForEntry = dirname(root);
    let children: Dirent[];
    try {
      children = await fs.readdir(target, { withFileTypes: true });
    } catch {
      continue;
    }

    for (const child of children) {
      if (isHiddenEntryName(child.name)) {
        continue;
      }

      const childPath = join(target, child.name);
      let stat: Awaited<ReturnType<typeof fs.stat>>;
      try {
        stat = await fs.stat(childPath);
      } catch {
        continue;
      }

      const relativePath = normalized ? `${normalized}/${child.name}` : child.name;
      const displayPath = child.isDirectory() ? `${relativePath}/` : relativePath;
      const entry: AggregatedListingEntry = {
        name: child.name,
        path: displayPath,
        type: child.isDirectory() ? 'dir' : 'file',
        size: stat.size,
        mtime: Math.floor(stat.mtimeMs),
        ...(multiRoot ? { workspaceRoot: workspaceRootForEntry } : {}),
      };

      const mapKey = multiRoot ? `${workspaceRootForEntry}\u0000${displayPath}` : displayPath;
      const existing = entriesMap.get(mapKey);
      if (!existing || entry.mtime > existing.mtime) {
        entriesMap.set(mapKey, entry);
      }
    }
  }

  return Array.from(entriesMap.values()).sort((a, b) => a.path.localeCompare(b.path));
}

async function findFileInAggregatedRoots(roots: string[], relPath: string): Promise<string | null> {
  const normalized = normalizeAggregatePath(relPath);
  if (!normalized) {
    return null;
  }

  for (const root of roots) {
    const candidate = join(root, normalized);
    let stat: Awaited<ReturnType<typeof fs.stat>>;
    try {
      stat = await fs.stat(candidate);
    } catch {
      continue;
    }
    if (stat.isFile()) {
      return candidate;
    }
  }

  return null;
}

/** Opt-in via RALPH_DASHBOARD_PLANS_LEGACY_BLOCKLIST=1; root listing uses allowlist-only virtual entries. */
const PLAN_DIR_BLOCKLIST = new Set([
  'bundle',
  'dist',
  'build',
  'out',
  'coverage',
  'docs',
  'node_modules',
  '.cursor',
  '.claude',
  '.codex',
  '.ralph',
  '.git',
  'public',
  'ralph-dashboard',
  'scripts',
  'tests',
]);

function plansLegacyBlocklistEnabled(): boolean {
  const raw = process.env['RALPH_DASHBOARD_PLANS_LEGACY_BLOCKLIST']?.trim().toLowerCase();
  return raw === '1' || raw === 'true' || raw === 'yes';
}

function isPlanDirectoryBlocklisted(name: string): boolean {
  return plansLegacyBlocklistEnabled() && PLAN_DIR_BLOCKLIST.has(name.toLowerCase());
}

const PLAN_ROOT_FILE_DENYLIST = new Set(['agents.md', 'claude.md', 'readme.md']);

/** Basename without extension; lowercase. Matches PLAN.md, plan-1.md, PLAN10.md, plan_admin.md; rejects planet.md, planning-notes.md. */
const PLAN_FILE_STEM_STRICT_RE = /^plan(?:$|[\d_-].*)$/;

const PLAN_WS_DIR = '.ralph-workspace';
const PLAN_BUCKET_DIR = 'plans';

function normalizePlansListPathParam(raw: string): string {
  return raw.replace(/\\/g, '/').replace(/^\/+|\/+$/g, '');
}

function isUnderWorkspacePlansListingPath(normPath: string): boolean {
  const p = normPath.toLowerCase();
  const prefix = `${PLAN_WS_DIR}/${PLAN_BUCKET_DIR}`;
  return p === prefix || p.startsWith(`${prefix}/`);
}

function isUnderRootPlansListingPath(normPath: string): boolean {
  const p = normPath.toLowerCase();
  return p === PLAN_BUCKET_DIR || p.startsWith(`${PLAN_BUCKET_DIR}/`);
}

/** True when a non-root plans list path is under workspace plans, root plans/, or a plan-stem directory. */
function isAllowedPlansPrefix(normPath: string): boolean {
  if (normPath === '') {
    return true;
  }
  const lower = normPath.toLowerCase();
  const wsLower = PLAN_WS_DIR.toLowerCase();
  const bucketLower = PLAN_BUCKET_DIR.toLowerCase();

  if (lower === wsLower) {
    return true;
  }
  const wsPlansPrefix = `${wsLower}/${bucketLower}`;
  if (lower === wsPlansPrefix || lower.startsWith(`${wsPlansPrefix}/`)) {
    return true;
  }

  if (lower === bucketLower || lower.startsWith(`${bucketLower}/`)) {
    return true;
  }

  const firstSeg = normPath.split('/')[0] ?? '';
  return firstSeg !== '' && isPlanDirectoryStemLike(firstSeg);
}

function isPlanDirectoryStemLike(name: string): boolean {
  return PLAN_FILE_STEM_STRICT_RE.test(name.toLowerCase());
}

function isPlanDirectoryAllowed(normListPath: string, name: string): boolean {
  if (isPlanDirectoryBlocklisted(name)) {
    return false;
  }
  const lower = name.toLowerCase();
  const p = normListPath;

  if (p.toLowerCase() === PLAN_WS_DIR) {
    return lower === PLAN_BUCKET_DIR;
  }

  if (isUnderWorkspacePlansListingPath(p) || isUnderRootPlansListingPath(p)) {
    return true;
  }

  return isPlanDirectoryStemLike(name);
}

function planFileStemLower(name: string): string | null {
  const lower = name.toLowerCase();
  if (lower.endsWith('.md')) {
    return lower.slice(0, -'.md'.length);
  }
  if (lower.endsWith('.mdc')) {
    return lower.slice(0, -'.mdc'.length);
  }
  return null;
}

function isPlanListableFile(name: string): boolean {
  const lower = name.toLowerCase();
  if (PLAN_ROOT_FILE_DENYLIST.has(lower)) {
    return false;
  }
  const stem = planFileStemLower(name);
  if (stem === null) {
    return false;
  }
  return PLAN_FILE_STEM_STRICT_RE.test(stem);
}

/** Re-add `.ralph-workspace` at project root so the Plans tree can drill into workspace-backed plans. */
function filterEntryNamesForPlansListing(
  absDir: string,
  normPlansPath: string,
  diskNames: readonly string[],
): string[] {
  const visible = filterVisibleEntryNames(diskNames);
  if (normPlansPath !== '') {
    return visible;
  }
  if (!diskNames.includes(PLAN_WS_DIR) || visible.includes(PLAN_WS_DIR)) {
    return visible;
  }
  try {
    const candidate = join(absDir, PLAN_WS_DIR);
    if (existsSync(candidate) && statSync(candidate).isDirectory()) {
      return [...visible, PLAN_WS_DIR];
    }
  } catch {
    // ignore
  }
  return visible;
}

type PlansListEntry = {
  name: string;
  path: string;
  type: 'dir' | 'file';
  size: number;
  mtime: number;
};

/** Allowlist-only plans root: workspace bucket, root plans/, and plan*.md at project root. */
async function buildPlansRootVirtualListing(projectRoot: string): Promise<PlansListEntry[]> {
  const entries: PlansListEntry[] = [];

  const wsDir = join(projectRoot, PLAN_WS_DIR);
  try {
    const wsStat = await fs.stat(wsDir);
    if (wsStat.isDirectory()) {
      entries.push({
        name: PLAN_WS_DIR,
        path: `${PLAN_WS_DIR}/`,
        type: 'dir',
        size: wsStat.size,
        mtime: Math.floor(wsStat.mtimeMs),
      });
    }
  } catch {
    // missing workspace dir
  }

  const plansBucket = join(projectRoot, PLAN_BUCKET_DIR);
  try {
    const plansStat = await fs.stat(plansBucket);
    if (plansStat.isDirectory()) {
      entries.push({
        name: PLAN_BUCKET_DIR,
        path: `${PLAN_BUCKET_DIR}/`,
        type: 'dir',
        size: plansStat.size,
        mtime: Math.floor(plansStat.mtimeMs),
      });
    }
  } catch {
    // missing plans bucket
  }

  let dirents: Dirent[];
  try {
    dirents = await fs.readdir(projectRoot, { withFileTypes: true });
  } catch {
    entries.sort((a, b) => a.name.localeCompare(b.name));
    return entries;
  }

  for (const dirent of dirents) {
    if (!dirent.isFile() || !isPlanListableFile(dirent.name)) {
      continue;
    }
    const absFile = join(projectRoot, dirent.name);
    let fileStat: Awaited<ReturnType<typeof fs.stat>>;
    try {
      fileStat = await fs.stat(absFile);
    } catch {
      continue;
    }
    entries.push({
      name: dirent.name,
      path: dirent.name,
      type: 'file',
      size: fileStat.size,
      mtime: Math.floor(fileStat.mtimeMs),
    });
  }

  entries.sort((a, b) => a.name.localeCompare(b.name));
  return entries;
}

function jsonError(res: Response, status: number, message: string): void {
  res.status(status).json({ error: message });
}

function getRootsMap(): Record<string, RootConfig> {
  return getAllowedRoots(findDashboardRoots());
}

async function walkPlanTreeForBasename(
  startDir: string,
  fileName: string,
  maxDepth: number,
): Promise<string | null> {
  const skipDirs = new Set(['node_modules', 'dist', 'build', 'out', 'coverage']);

  async function walk(dir: string, depth: number): Promise<string | null> {
    if (depth > maxDepth) {
      return null;
    }

    let entries: Dirent[];
    try {
      entries = await fs.readdir(dir, { withFileTypes: true });
    } catch {
      return null;
    }

    for (const entry of entries) {
      if (isHiddenEntryName(entry.name)) {
        continue;
      }

      const absPath = join(dir, entry.name);
      if (entry.isFile()) {
        if (entry.name === fileName) {
          return absPath;
        }
        continue;
      }

      if (entry.isDirectory()) {
        if (skipDirs.has(entry.name)) {
          continue;
        }

        const found = await walk(absPath, depth + 1);
        if (found) {
          return found;
        }
      }
    }

    return null;
  }

  return walk(startDir, 0);
}

async function findPlanFileShallowInDir(dir: string, fileName: string): Promise<string | null> {
  let entries: Dirent[];
  try {
    entries = await fs.readdir(dir, { withFileTypes: true });
  } catch {
    return null;
  }
  for (const entry of entries) {
    if (isHiddenEntryName(entry.name)) {
      continue;
    }
    if (entry.isFile() && entry.name === fileName) {
      return join(dir, entry.name);
    }
  }
  return null;
}

async function findPlanByBasename(
  projectRoot: string,
  workspaceRoot: string,
  fileName: string,
): Promise<string | null> {
  const maxDepth = 8;
  const canonicalPlans = join(workspaceRoot, 'plans');
  if (existsSync(canonicalPlans) && statSync(canonicalPlans).isDirectory()) {
    const fromWorkspacePlans = await walkPlanTreeForBasename(canonicalPlans, fileName, maxDepth);
    if (fromWorkspacePlans) {
      return fromWorkspacePlans;
    }
  }

  const fromProjectRootTop = await findPlanFileShallowInDir(projectRoot, fileName);
  if (fromProjectRootTop) {
    return fromProjectRootTop;
  }

  const rootPlansBucket = join(projectRoot, 'plans');
  if (
    resolve(rootPlansBucket) !== resolve(canonicalPlans) &&
    existsSync(rootPlansBucket) &&
    statSync(rootPlansBucket).isDirectory()
  ) {
    const fromRootPlans = await walkPlanTreeForBasename(rootPlansBucket, fileName, maxDepth);
    if (fromRootPlans) {
      return fromRootPlans;
    }
  }

  return walkPlanTreeForBasename(projectRoot, fileName, maxDepth);
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

function cacheEfficiencyRatio(
  uncached: number,
  cacheCreate: number,
  cacheRead: number,
): number {
  const totalInput = uncached + cacheCreate + cacheRead;
  return totalInput > 0 ? Math.round((cacheRead / totalInput) * 10000) / 10000 : 0;
}

function canonicalUsageFromRecord(record: Record<string, unknown>): {
  uncached_input_tokens: number;
  cache_creation_input_tokens: number;
  cache_read_input_tokens: number;
  output_tokens: number;
  total_input_tokens: number;
  cache_efficiency_ratio: number;
  cache_hit_ratio: number;
  input_tokens: number;
} {
  const uncached = toNumber(record['uncached_input_tokens'] ?? record['input_tokens']);
  const cacheCreate = toNumber(record['cache_creation_input_tokens']);
  const cacheRead = toNumber(record['cache_read_input_tokens']);
  const output = toNumber(record['output_tokens']);
  const totalInput = toNumber(record['total_input_tokens']) || uncached + cacheCreate + cacheRead;
  const ratio =
    record['cache_efficiency_ratio'] !== undefined
      ? toNumber(record['cache_efficiency_ratio'])
      : record['cache_hit_ratio'] !== undefined
        ? toNumber(record['cache_hit_ratio'])
        : cacheEfficiencyRatio(uncached, cacheCreate, cacheRead);
  return {
    uncached_input_tokens: uncached,
    cache_creation_input_tokens: cacheCreate,
    cache_read_input_tokens: cacheRead,
    output_tokens: output,
    total_input_tokens: totalInput,
    cache_efficiency_ratio: ratio,
    cache_hit_ratio: ratio,
    input_tokens: uncached,
  };
}

function coerceBool(value: unknown): boolean {
  if (typeof value === 'boolean') {
    return value;
  }
  if (value === null || value === undefined) {
    return false;
  }
  const text = String(value).trim().toLowerCase();
  if (!text) {
    return false;
  }
  return text === '1' || text === 'true' || text === 'yes' || text === 'on';
}

function coerceWarnings(value: unknown): string[] {
  if (!Array.isArray(value)) {
    return [];
  }
  return value.map((item) => String(item).trim()).filter((item) => item.length > 0);
}

function emptyOverlayAccumulator(): OverlayAccumulator {
  return {
    saw_overlay_fields: false,
    native_hooks_effective: false,
    mcp_effective: false,
    native_hook_events: 0,
    hook_compactions: 0,
    hook_rewrites: 0,
    hook_original_bytes: 0,
    hook_compacted_bytes: 0,
    runtime_overlay_mode: '',
    runtime_overlay_warnings: new Set<string>(),
  };
}

const OVERLAY_INVOCATION_KEYS = [
  'native_hooks_effective',
  'mcp_effective',
  'hook_compactions',
  'hook_rewrites',
  'native_hook_events',
  'hook_original_bytes',
  'hook_compacted_bytes',
  'runtime_overlay_mode',
  'runtime_overlay_warnings',
] as const;

function invocationRecordHasOverlayFields(record: Record<string, unknown>): boolean {
  return OVERLAY_INVOCATION_KEYS.some((key) => record[key] !== undefined && record[key] !== null);
}

function accumulateOverlayFromRecord(acc: OverlayAccumulator, record: Record<string, unknown>): void {
  if (!invocationRecordHasOverlayFields(record)) {
    return;
  }
  acc.saw_overlay_fields = true;
  if (coerceBool(record['native_hooks_effective'])) {
    acc.native_hooks_effective = true;
  }
  if (coerceBool(record['mcp_effective'])) {
    acc.mcp_effective = true;
  }
  acc.native_hook_events += toNumber(record['native_hook_events']);
  acc.hook_compactions += toNumber(record['hook_compactions']);
  acc.hook_rewrites += toNumber(record['hook_rewrites']);
  acc.hook_original_bytes += toNumber(record['hook_original_bytes']);
  acc.hook_compacted_bytes += toNumber(record['hook_compacted_bytes']);
  const mode = String(record['runtime_overlay_mode'] ?? '').trim();
  if (mode) {
    acc.runtime_overlay_mode = mode;
  }
  for (const warning of coerceWarnings(record['runtime_overlay_warnings'])) {
    acc.runtime_overlay_warnings.add(warning);
  }
}

function finalizeOverlayMetrics(acc: OverlayAccumulator): RuntimeOverlayMetrics | undefined {
  if (!acc.saw_overlay_fields) {
    return undefined;
  }
  const hook_bytes_saved = Math.max(0, acc.hook_original_bytes - acc.hook_compacted_bytes);
  return {
    native_hooks_effective: acc.native_hooks_effective,
    mcp_effective: acc.mcp_effective,
    native_hook_events: acc.native_hook_events,
    hook_compactions: acc.hook_compactions,
    hook_rewrites: acc.hook_rewrites,
    hook_original_bytes: acc.hook_original_bytes,
    hook_compacted_bytes: acc.hook_compacted_bytes,
    hook_bytes_saved,
    runtime_overlay_mode: acc.runtime_overlay_mode,
    runtime_overlay_warnings: [...acc.runtime_overlay_warnings].sort(),
  };
}

function overlayMetricsFromSummaryRecord(record: UsageSummaryRecord): RuntimeOverlayMetrics | undefined {
  const acc = emptyOverlayAccumulator();
  const pseudo: Record<string, unknown> = {};
  if (record.native_hooks_effective !== undefined) {
    pseudo['native_hooks_effective'] = record.native_hooks_effective;
  }
  if (record.mcp_effective !== undefined) {
    pseudo['mcp_effective'] = record.mcp_effective;
  }
  if (record.native_hook_events !== undefined) {
    pseudo['native_hook_events'] = record.native_hook_events;
  }
  if (record.hook_compactions !== undefined) {
    pseudo['hook_compactions'] = record.hook_compactions;
  }
  if (record.hook_rewrites !== undefined) {
    pseudo['hook_rewrites'] = record.hook_rewrites;
  }
  if (record.hook_original_bytes !== undefined) {
    pseudo['hook_original_bytes'] = record.hook_original_bytes;
  }
  if (record.hook_compacted_bytes !== undefined) {
    pseudo['hook_compacted_bytes'] = record.hook_compacted_bytes;
  }
  if (record.runtime_overlay_mode !== undefined) {
    pseudo['runtime_overlay_mode'] = record.runtime_overlay_mode;
  }
  if (record.runtime_overlay_warnings !== undefined) {
    pseudo['runtime_overlay_warnings'] = record.runtime_overlay_warnings;
  }
  accumulateOverlayFromRecord(acc, pseudo);
  return finalizeOverlayMetrics(acc);
}

function emptyToolCallCounts(): ToolCallClassificationMetrics {
  const counts = {} as ToolCallClassificationMetrics;
  for (const key of TOOL_CALL_ACCOUNTING_KEYS) {
    counts[key] = 0;
  }
  return counts;
}

function recordHasToolCallClassification(record: Record<string, unknown>): boolean {
  return TOOL_CALL_ACCOUNTING_KEYS.some((key) => record[key] !== undefined && record[key] !== null);
}

function toolCallsFromRecord(record: Record<string, unknown>): ToolCallClassificationMetrics | undefined {
  if (!recordHasToolCallClassification(record)) {
    return undefined;
  }
  const counts = emptyToolCallCounts();
  for (const key of TOOL_CALL_ACCOUNTING_KEYS) {
    counts[key] = toNumber(record[key]);
  }
  return counts;
}

function mergeToolCallCounts(
  target: ToolCallClassificationMetrics,
  source: ToolCallClassificationMetrics,
): void {
  target.ralph_proxy_calls += source.ralph_proxy_calls;
  target.ralph_knowledge_calls += source.ralph_knowledge_calls;
  target.other_mcp_calls += source.other_mcp_calls;
  target.native_read_like_calls += source.native_read_like_calls;
  target.native_write_like_calls += source.native_write_like_calls;
  target.native_file_read_calls += source.native_file_read_calls;
  target.native_read_compatibility_calls += source.native_read_compatibility_calls;
  target.native_search_calls += source.native_search_calls;
  target.native_shell_calls += source.native_shell_calls;
  target.ralph_mcp_calls += source.ralph_mcp_calls;
  target.runtime_hook_rewrite_calls += source.runtime_hook_rewrite_calls;
  target.runtime_hook_compaction_calls += source.runtime_hook_compaction_calls;
  target.unknown_tool_calls += source.unknown_tool_calls;
}

function accumulateToolCallsFromRecord(
  acc: { saw: boolean; counts: ToolCallClassificationMetrics },
  record: Record<string, unknown>,
): void {
  const extracted = toolCallsFromRecord(record);
  if (!extracted) {
    return;
  }
  acc.saw = true;
  mergeToolCallCounts(acc.counts, extracted);
}

function finalizeToolCallMetrics(
  acc: { saw: boolean; counts: ToolCallClassificationMetrics },
): ToolCallClassificationMetrics | undefined {
  if (!acc.saw) {
    return undefined;
  }
  return { ...acc.counts };
}

function emptyToolCallAccumulator(): { saw: boolean; counts: ToolCallClassificationMetrics } {
  return { saw: false, counts: emptyToolCallCounts() };
}

function sumToolCallsFromBreakdownRows(rows: ModelBreakdownItem[]): ToolCallClassificationMetrics | undefined {
  const acc = emptyToolCallAccumulator();
  for (const row of rows) {
    if (row.tool_calls) {
      acc.saw = true;
      mergeToolCallCounts(acc.counts, row.tool_calls);
    }
  }
  return finalizeToolCallMetrics(acc);
}

function normalizeModelBreakdownRow(item: Record<string, unknown>): ModelBreakdownItem {
  const canonical = canonicalUsageFromRecord(item);
  const row: ModelBreakdownItem = {
    runtime: String(item['runtime'] ?? ''),
    model: String(item['model'] ?? ''),
    invocations: toNumber(item['invocations']),
    elapsed_seconds: toNumber(item['elapsed_seconds']),
    input_tokens: canonical.input_tokens,
    output_tokens: canonical.output_tokens,
    cache_creation_input_tokens: canonical.cache_creation_input_tokens,
    cache_read_input_tokens: canonical.cache_read_input_tokens,
    uncached_input_tokens: canonical.uncached_input_tokens,
    total_input_tokens: canonical.total_input_tokens,
    cache_efficiency_ratio: canonical.cache_efficiency_ratio,
    max_turn_total_tokens: toNumber(item['max_turn_total_tokens']),
    cache_hit_ratio: canonical.cache_hit_ratio,
    prompt_bytes: toNumber(item['prompt_bytes']),
    todo_bytes: toNumber(item['todo_bytes']),
    todo_continuation_lines: toNumber(item['todo_continuation_lines']),
    direct_verification_count: toNumber(item['direct_verification_count']),
    rate_limit_count: toNumber(item['rate_limit_count']),
    tool_turns: toNumber(item['tool_turns']),
    tool_calls_total: toNumber(item['tool_calls_total']),
  };
  const rowToolCalls = toolCallsFromRecord(item);
  if (rowToolCalls) {
    row.tool_calls = rowToolCalls;
  }
  const overlayAcc = emptyOverlayAccumulator();
  accumulateOverlayFromRecord(overlayAcc, item);
  const rowOverlayMetrics = finalizeOverlayMetrics(overlayAcc);
  if (rowOverlayMetrics) {
    row.overlay = rowOverlayMetrics;
  }
  return row;
}

function normalizeModelBreakdownRows(raw: unknown): ModelBreakdownItem[] | undefined {
  if (!Array.isArray(raw)) {
    return undefined;
  }
  const rows: ModelBreakdownItem[] = [];
  for (const entry of raw) {
    if (!entry || typeof entry !== 'object') {
      continue;
    }
    rows.push(normalizeModelBreakdownRow(entry as Record<string, unknown>));
  }
  return rows.length > 0 ? rows : undefined;
}

async function invocationUsageIsNewerThanSummary(
  summaryPath: string,
  usagePath: string,
): Promise<boolean> {
  try {
    const [summaryStat, usageStat] = await Promise.all([fs.stat(summaryPath), fs.stat(usagePath)]);
    return usageStat.mtimeMs > summaryStat.mtimeMs;
  } catch {
    return false;
  }
}

function workspaceRootsFromSummaryPath(summaryPath: string): { workspace_root: string; project_root: string } {
  const abs = resolve(summaryPath);
  const workspace_root = dirname(dirname(dirname(abs)));
  const project_root = dirname(workspace_root);
  return { workspace_root, project_root };
}

function rollupOverallFromItems(items: MetricsSummaryItem[]): MetricsSummaryOverallShape {
  const overall: MetricsSummaryOverallShape = {
    input_tokens: 0,
    output_tokens: 0,
    cache_creation_input_tokens: 0,
    cache_read_input_tokens: 0,
    max_turn_total_tokens: 0,
    cache_hit_ratio: 0,
    elapsed_seconds: 0,
    count: 0,
    tool_calls_total: 0,
  };
  for (const item of items) {
    overall.input_tokens += item.input_tokens;
    overall.output_tokens += item.output_tokens;
    overall.cache_creation_input_tokens += item.cache_creation_input_tokens;
    overall.cache_read_input_tokens += item.cache_read_input_tokens;
    overall.elapsed_seconds += item.elapsed_seconds;
    overall.tool_calls_total += toNumber(item.tool_calls_total);
    if (item.max_turn_total_tokens > overall.max_turn_total_tokens) {
      overall.max_turn_total_tokens = item.max_turn_total_tokens;
    }
    overall.count += 1;
  }
  const overallCanonical = canonicalUsageFromRecord({
    input_tokens: overall.input_tokens,
    cache_creation_input_tokens: overall.cache_creation_input_tokens,
    cache_read_input_tokens: overall.cache_read_input_tokens,
  });
  overall.cache_hit_ratio = overallCanonical.cache_hit_ratio;
  return overall;
}

interface MetricsProjectRollup {
  workspace_root: string;
  project_root: string;
  label: string;
  overall: MetricsSummaryOverallShape;
  plans: MetricsSummaryItem[];
  orchestrations: MetricsSummaryItem[];
}

function buildProjectsRollup(
  plans: MetricsSummaryItem[],
  orchestrations: MetricsSummaryItem[],
): MetricsProjectRollup[] {
  const byWs = new Map<string, { plans: MetricsSummaryItem[]; orchestrations: MetricsSummaryItem[] }>();
  for (const p of plans) {
    const bucket = byWs.get(p.workspace_root) ?? { plans: [], orchestrations: [] };
    bucket.plans.push(p);
    byWs.set(p.workspace_root, bucket);
  }
  for (const o of orchestrations) {
    const bucket = byWs.get(o.workspace_root) ?? { plans: [], orchestrations: [] };
    bucket.orchestrations.push(o);
    byWs.set(o.workspace_root, bucket);
  }
  const out: MetricsProjectRollup[] = [];
  for (const [workspace_root, bucket] of byWs) {
    const project_root = dirname(workspace_root);
    out.push({
      workspace_root,
      project_root,
      label: basename(project_root),
      overall: rollupOverallFromItems([...bucket.plans, ...bucket.orchestrations]),
      plans: bucket.plans,
      orchestrations: bucket.orchestrations,
    });
  }
  out.sort((a, b) => a.workspace_root.localeCompare(b.workspace_root));
  return out;
}

function normalizeSummaryRecord(
  record: UsageSummaryRecord,
  summaryPath: string,
): MetricsSummaryItem | null {
  const file = basename(summaryPath);
  const kind =
    record.kind === 'plan_usage_summary' || record.kind === 'orchestration_usage_summary'
      ? record.kind
      : file === 'plan-usage-summary.json'
        ? 'plan_usage_summary'
        : file === 'orchestration-usage-summary.json'
          ? 'orchestration_usage_summary'
          : null;

  if (!kind) {
    return null;
  }

  const inferredKey = basename(dirname(summaryPath));
  const { workspace_root, project_root } = workspaceRootsFromSummaryPath(summaryPath);
  const modelBreakdown = normalizeModelBreakdownRows(record.model_breakdown);
  const recordObj = record as Record<string, unknown>;

  return {
    path: summaryPath,
    plan_key: record.plan_key ?? inferredKey,
    artifact_ns: record.artifact_ns ?? inferredKey,
    workspace_root,
    project_root,
    stage_id: record.stage_id || undefined,
    model: record.model || undefined,
    runtime: record.runtime || undefined,
    started_at: record.started_at || undefined,
    ended_at: record.ended_at || undefined,
    elapsed_seconds: toNumber(record.elapsed_seconds),
    input_tokens: toNumber(record.input_tokens),
    output_tokens: toNumber(record.output_tokens),
    cache_creation_input_tokens: toNumber(record.cache_creation_input_tokens),
    cache_read_input_tokens: toNumber(record.cache_read_input_tokens),
    max_turn_total_tokens: toNumber(record.max_turn_total_tokens),
    cache_hit_ratio: toNumber(record.cache_hit_ratio),
    prompt_bytes: toNumber(record.prompt_bytes),
    todo_bytes: toNumber(record.todo_bytes),
    todo_continuation_lines: toNumber(record.todo_continuation_lines),
    direct_verification_count: toNumber(record.direct_verification_count),
    rate_limit_count: toNumber(record.rate_limit_count),
    tool_turns: toNumber(record.tool_turns),
    tool_calls_total: toNumber(record.tool_calls_total),
    model_breakdown: modelBreakdown,
    invocations: record.invocations === undefined ? undefined : toNumber(record.invocations),
    overlay: overlayMetricsFromSummaryRecord(record),
    tool_calls: toolCallsFromRecord(recordObj) ?? (modelBreakdown ? sumToolCallsFromBreakdownRows(modelBreakdown) : undefined),
  };
}

async function applyModelBreakdownFallback(
  normalized: MetricsSummaryItem,
  summaryPath: string,
): Promise<MetricsSummaryItem> {
  const usagePath = join(dirname(summaryPath), 'invocation-usage.json');

  if (!existsSync(usagePath)) {
    return normalized;
  }

  try {
    const raw = await fs.readFile(usagePath, 'utf8');
    const parsed = JSON.parse(raw) as { invocations?: unknown };
    if (!parsed || !Array.isArray(parsed.invocations)) {
      return normalized;
    }
    if (parsed.invocations.length === 0) {
      return normalized;
    }

    const stale = await invocationUsageIsNewerThanSummary(summaryPath, usagePath);
    const planOverlayAcc = emptyOverlayAccumulator();
    const planToolCallAcc = emptyToolCallAccumulator();

    const grouped = new Map<
      string,
      {
        runtime: string;
        model: string;
        invocations: number;
        elapsed_seconds: number;
        input_tokens: number;
        output_tokens: number;
        cache_creation_input_tokens: number;
        cache_read_input_tokens: number;
        max_turn_total_tokens: number;
        prompt_bytes: number;
        todo_bytes: number;
        todo_continuation_lines: number;
        direct_verification_count: number;
        rate_limit_count: number;
        tool_turns: number;
        tool_calls_total: number;
        overlay: OverlayAccumulator;
        tool_calls: { saw: boolean; counts: ToolCallClassificationMetrics };
      }
    >();

    for (const record of parsed.invocations) {
      if (!record || typeof record !== 'object') {
        continue;
      }

      const item = record as Record<string, unknown>;
      accumulateOverlayFromRecord(planOverlayAcc, item);
      accumulateToolCallsFromRecord(planToolCallAcc, item);
      const runtime = String(item['runtime'] ?? '');
      const model = String(item['model'] ?? '');
      const key = `${runtime}\u0000${model}`;
      const bucket = grouped.get(key) ?? {
        runtime,
        model,
        invocations: 0,
        elapsed_seconds: 0,
        input_tokens: 0,
        output_tokens: 0,
        cache_creation_input_tokens: 0,
        cache_read_input_tokens: 0,
        max_turn_total_tokens: 0,
        prompt_bytes: 0,
        todo_bytes: 0,
        todo_continuation_lines: 0,
        direct_verification_count: 0,
        rate_limit_count: 0,
        tool_turns: 0,
        tool_calls_total: 0,
        overlay: emptyOverlayAccumulator(),
        tool_calls: emptyToolCallAccumulator(),
      };

      bucket.invocations += 1;
      bucket.elapsed_seconds += toNumber(item['elapsed_seconds']);
      bucket.input_tokens += toNumber(item['input_tokens']);
      bucket.output_tokens += toNumber(item['output_tokens']);
      bucket.cache_creation_input_tokens += toNumber(item['cache_creation_input_tokens']);
      bucket.cache_read_input_tokens += toNumber(item['cache_read_input_tokens']);
      bucket.prompt_bytes += toNumber(item['prompt_bytes']);
      bucket.todo_bytes += toNumber(item['todo_bytes']);
      bucket.todo_continuation_lines += toNumber(item['todo_continuation_lines']);
      bucket.tool_turns += toNumber(item['tool_turns']);
      bucket.tool_calls_total += toNumber(item['tool_calls_total']);
      accumulateOverlayFromRecord(bucket.overlay, item);
      accumulateToolCallsFromRecord(bucket.tool_calls, item);
      if (item['direct_verification'] === true) {
        bucket.direct_verification_count += 1;
      }
      if (typeof item['rate_limit_status'] === 'string' && item['rate_limit_status'].trim()) {
        bucket.rate_limit_count += 1;
      }
      const invocationMaxTurn = toNumber(item['max_turn_total_tokens']);
      if (invocationMaxTurn > bucket.max_turn_total_tokens) {
        bucket.max_turn_total_tokens = invocationMaxTurn;
      }
      grouped.set(key, bucket);
    }

    const breakdown = Array.from(grouped.values())
      .sort((a, b) => `${a.runtime}\u0000${a.model}`.localeCompare(`${b.runtime}\u0000${b.model}`))
      .map((bucket) => {
        const canonical = canonicalUsageFromRecord({
          input_tokens: bucket.input_tokens,
          output_tokens: bucket.output_tokens,
          cache_creation_input_tokens: bucket.cache_creation_input_tokens,
          cache_read_input_tokens: bucket.cache_read_input_tokens,
        });
        const row: ModelBreakdownItem = {
          runtime: bucket.runtime,
          model: bucket.model,
          invocations: bucket.invocations,
          elapsed_seconds: bucket.elapsed_seconds,
          input_tokens: canonical.input_tokens,
          output_tokens: canonical.output_tokens,
          cache_creation_input_tokens: canonical.cache_creation_input_tokens,
          cache_read_input_tokens: canonical.cache_read_input_tokens,
          uncached_input_tokens: canonical.uncached_input_tokens,
          total_input_tokens: canonical.total_input_tokens,
          cache_efficiency_ratio: canonical.cache_efficiency_ratio,
          max_turn_total_tokens: bucket.max_turn_total_tokens,
          cache_hit_ratio: canonical.cache_hit_ratio,
          prompt_bytes: bucket.prompt_bytes,
          todo_bytes: bucket.todo_bytes,
          todo_continuation_lines: bucket.todo_continuation_lines,
          direct_verification_count: bucket.direct_verification_count,
          rate_limit_count: bucket.rate_limit_count,
          tool_turns: bucket.tool_turns,
          tool_calls_total: bucket.tool_calls_total,
        };
        const rowOverlay = finalizeOverlayMetrics(bucket.overlay);
        if (rowOverlay) {
          row.overlay = rowOverlay;
        }
        const rowToolCalls = finalizeToolCallMetrics(bucket.tool_calls);
        if (rowToolCalls) {
          row.tool_calls = rowToolCalls;
        }
        return row;
      });

    const totals = breakdown.reduce(
      (acc, item) => {
        acc.invocations += item.invocations;
        acc.elapsed_seconds += item.elapsed_seconds;
        acc.input_tokens += item.input_tokens;
        acc.output_tokens += item.output_tokens;
        acc.cache_creation_input_tokens += item.cache_creation_input_tokens;
        acc.cache_read_input_tokens += item.cache_read_input_tokens;
        acc.prompt_bytes += item.prompt_bytes ?? 0;
        acc.todo_bytes += item.todo_bytes ?? 0;
        acc.todo_continuation_lines += item.todo_continuation_lines ?? 0;
        acc.direct_verification_count += item.direct_verification_count ?? 0;
        acc.rate_limit_count += item.rate_limit_count ?? 0;
        acc.tool_turns += item.tool_turns ?? 0;
        acc.tool_calls_total += item.tool_calls_total ?? 0;
        if (item.max_turn_total_tokens > acc.max_turn_total_tokens) {
          acc.max_turn_total_tokens = item.max_turn_total_tokens;
        }
        return acc;
      },
      {
        invocations: 0,
        elapsed_seconds: 0,
        input_tokens: 0,
        output_tokens: 0,
        cache_creation_input_tokens: 0,
        cache_read_input_tokens: 0,
        max_turn_total_tokens: 0,
        prompt_bytes: 0,
        todo_bytes: 0,
        todo_continuation_lines: 0,
        direct_verification_count: 0,
        rate_limit_count: 0,
        tool_turns: 0,
        tool_calls_total: 0,
      },
    );
    const totalInput =
      totals.input_tokens + totals.cache_creation_input_tokens + totals.cache_read_input_tokens;

    const invocationOverlay = finalizeOverlayMetrics(planOverlayAcc);
    const overlay = stale
      ? invocationOverlay ?? normalized.overlay
      : normalized.overlay ?? invocationOverlay;

    const invocationToolCalls = finalizeToolCallMetrics(planToolCallAcc);
    const tool_calls = stale
      ? invocationToolCalls ?? normalized.tool_calls
      : normalized.tool_calls ?? invocationToolCalls;

    const useInvocationTotals =
      stale ||
      (normalized.input_tokens === 0 &&
        normalized.output_tokens === 0 &&
        totals.input_tokens + totals.output_tokens > 0);

    const model_breakdown =
      stale || !normalized.model_breakdown?.length
        ? breakdown
        : normalized.model_breakdown.map((row) => {
            if (row.tool_calls) {
              return row;
            }
            const fallback = breakdown.find(
              (candidate) => candidate.runtime === row.runtime && candidate.model === row.model,
            );
            return fallback?.tool_calls ? { ...row, tool_calls: fallback.tool_calls } : row;
          });

    if (!useInvocationTotals) {
      return {
        ...normalized,
        model_breakdown,
        ...(overlay ? { overlay } : {}),
        ...(tool_calls ? { tool_calls } : {}),
      };
    }

    return {
      ...normalized,
      invocations: totals.invocations,
      elapsed_seconds: totals.elapsed_seconds,
      input_tokens: totals.input_tokens,
      output_tokens: totals.output_tokens,
      cache_creation_input_tokens: totals.cache_creation_input_tokens,
      cache_read_input_tokens: totals.cache_read_input_tokens,
      max_turn_total_tokens: totals.max_turn_total_tokens,
      prompt_bytes: totals.prompt_bytes,
      todo_bytes: totals.todo_bytes,
      todo_continuation_lines: totals.todo_continuation_lines,
      direct_verification_count: totals.direct_verification_count,
      rate_limit_count: totals.rate_limit_count,
      tool_turns: totals.tool_turns,
      tool_calls_total: totals.tool_calls_total,
      cache_hit_ratio:
        totalInput > 0
          ? Math.round((totals.cache_read_input_tokens / totalInput) * 10000) / 10000
          : 0,
      model_breakdown,
      ...(overlay ? { overlay } : {}),
      ...(tool_calls ? { tool_calls } : {}),
    };
  } catch {
    return normalized;
  }
}

async function collectSummaryFiles(dir: string): Promise<string[]> {
  let entries: Dirent[];
  try {
    entries = await fs.readdir(dir, { withFileTypes: true, encoding: 'utf8' });
  } catch {
    return [];
  }

  const files: string[] = [];
  const subdirPromises: Promise<string[]>[] = [];

  for (const entry of entries) {
    const absPath = join(dir, entry.name);
    if (entry.isDirectory()) {
      subdirPromises.push(collectSummaryFiles(absPath));
    } else if (entry.isFile() && SUMMARY_FILE_NAMES.has(entry.name)) {
      files.push(absPath);
    }
  }

  if (subdirPromises.length > 0) {
    const subdirResults = await Promise.all(subdirPromises);
    for (const subFiles of subdirResults) {
      for (const f of subFiles) files.push(f);
    }
  }

  return files;
}

async function resolveDiscoverReportPath(
  planKey: string,
  logsRoots: string[],
  workspaceRootFilter?: string,
): Promise<string | null> {
  const normalizedFilter = workspaceRootFilter ? resolve(workspaceRootFilter) : '';

  for (const logsRoot of logsRoots) {
    const candidate = join(logsRoot, planKey, 'discover-report.json');
    if (!existsSync(candidate)) {
      continue;
    }
    if (normalizedFilter) {
      const workspaceRoot = dirname(dirname(candidate));
      if (resolve(workspaceRoot) !== normalizedFilter) {
        continue;
      }
    }
    return candidate;
  }

  return null;
}

export async function handleMetricsDiscoverRequest(req: Request, res: Response): Promise<void> {
  const planKey = req.params['planKey'];
  if (!planKey || typeof planKey !== 'string' || planKey.includes('..') || planKey.includes('/')) {
    return jsonError(res, 400, 'invalid plan key');
  }

  const workspaceRootQuery =
    typeof req.query['workspaceRoot'] === 'string' ? req.query['workspaceRoot'] : '';

  const logsRoots = await findWorkspaceLogsRootsAsync();
  if (logsRoots.length === 0) {
    return jsonError(res, 404, 'discover report not found');
  }

  const reportPath = await resolveDiscoverReportPath(planKey, logsRoots, workspaceRootQuery || undefined);
  if (!reportPath) {
    return jsonError(res, 404, 'discover report not found');
  }

  try {
    const raw = await fs.readFile(reportPath, 'utf8');
    const parsed = JSON.parse(raw) as DiscoverReportPayload;
    const { workspace_root, project_root } = workspaceRootsFromSummaryPath(
      join(dirname(reportPath), 'plan-usage-summary.json'),
    );
    res.json({
      plan_key: planKey,
      path: reportPath,
      workspace_root,
      project_root,
      report: parsed,
    });
  } catch {
    return jsonError(res, 500, 'failed to read discover report');
  }
}

export async function handleMetricsSummaryRequest(_req: Request, res: Response): Promise<void> {
  const logsRoots = await findWorkspaceLogsRootsAsync();
  if (logsRoots.length === 0) {
    res.json({
      overall: {
        input_tokens: 0,
        output_tokens: 0,
        cache_creation_input_tokens: 0,
        cache_read_input_tokens: 0,
        max_turn_total_tokens: 0,
        cache_hit_ratio: 0,
        elapsed_seconds: 0,
        count: 0,
        tool_calls_total: 0,
      },
      plans: [],
      orchestrations: [],
      projects: [],
    });
    return;
  }

  const summaryPaths = await collectSummaryPathsFromLogs(logsRoots);
  const plans: MetricsSummaryItem[] = [];
  const orchestrations: MetricsSummaryItem[] = [];
  const overall = {
    input_tokens: 0,
    output_tokens: 0,
    cache_creation_input_tokens: 0,
    cache_read_input_tokens: 0,
    max_turn_total_tokens: 0,
    cache_hit_ratio: 0,
    elapsed_seconds: 0,
    count: 0,
    tool_calls_total: 0,
  };

  for (const summaryPath of summaryPaths) {
    try {
      const raw = await fs.readFile(summaryPath, 'utf8');
      const parsed = JSON.parse(raw) as UsageSummaryRecord;
      const normalized = normalizeSummaryRecord(parsed, summaryPath);
      if (!normalized) {
        continue;
      }

      const withFallback = await applyModelBreakdownFallback(normalized, summaryPath);
      const isPlanSummary = basename(summaryPath) === 'plan-usage-summary.json';

      overall.input_tokens += withFallback.input_tokens;
      overall.output_tokens += withFallback.output_tokens;
      overall.cache_creation_input_tokens += withFallback.cache_creation_input_tokens;
      overall.cache_read_input_tokens += withFallback.cache_read_input_tokens;
      overall.elapsed_seconds += withFallback.elapsed_seconds;
      overall.tool_calls_total += toNumber(withFallback.tool_calls_total);
      if (withFallback.max_turn_total_tokens > overall.max_turn_total_tokens) {
        overall.max_turn_total_tokens = withFallback.max_turn_total_tokens;
      }
      overall.count += 1;

      if (isPlanSummary) {
        plans.push(withFallback);
      } else {
        orchestrations.push(withFallback);
      }
    } catch {
      continue;
    }
  }

  plans.sort((a, b) => (a.started_at ?? a.path).localeCompare(b.started_at ?? b.path));
  orchestrations.sort((a, b) => (a.started_at ?? a.path).localeCompare(b.started_at ?? b.path));

  // Compute overall cache_hit_ratio from accumulated token totals.
  const overallCanonical = canonicalUsageFromRecord({
    input_tokens: overall.input_tokens,
    cache_creation_input_tokens: overall.cache_creation_input_tokens,
    cache_read_input_tokens: overall.cache_read_input_tokens,
  });
  overall.cache_hit_ratio = overallCanonical.cache_hit_ratio;

  const projects = buildProjectsRollup(plans, orchestrations);

  res.json({
    overall,
    plans,
    orchestrations,
    projects,
  });
}

function emptySavingsReport(): SavingsReport {
  const buckets = createEmptySavingsBuckets();
  finalizeAllSavingsBuckets(buckets);
  return {
    schema_version: 2,
    kind: 'ralph_benchmark_report',
    run_count: 0,
    date_range: { started_at: null, ended_at: null },
    saved_bytes: 0,
    saved_tokens: 0,
    savings_percent: 0,
    session_usage: {
      input_tokens: 0,
      output_tokens: 0,
      cache_creation_input_tokens: 0,
      cache_read_input_tokens: 0,
      prompt_bytes: 0,
      tool_calls_total: 0,
    },
    tool_output_counterfactual: {
      hypothetical_without_ralph_bytes: 0,
      actual_with_ralph_bytes: 0,
      net_savings_bytes: 0,
      hypothetical_without_ralph_tokens: 0,
      actual_with_ralph_tokens: 0,
      net_savings_tokens: 0,
      net_savings_percent: 0,
      compaction_measured_not_applied_bytes: 0,
      compaction_measured_not_applied_tokens: 0,
    },
    per_path: buckets,
    per_channel: finalizeChannelBuckets(createEmptyChannelBuckets()),
    cache: {
      cache_read_tokens: 0,
      cache_hit_ratio: 0,
    },
    could_have_saved: {
      compaction_measured_not_applied_bytes: 0,
    },
    readback_summary: {
      envelope_count: 0,
      readback_count: 0,
      raw_readback_count: 0,
      compacted_readback_count: 0,
      readback_bytes: 0,
      envelope_original_bytes: 0,
      full_preview_rereads: 0,
      raw_readback_share: 0,
      readback_negation_rate: 0,
      gross_readback_bytes: 0,
      gross_readback_tokens: 0,
      net_consumed_bytes: 0,
      net_consumed_tokens: 0,
      effective_windowing_savings_rate: 0,
    },
  };
}

export async function handleSavingsRequest(req: Request, res: Response): Promise<void> {
  const workspaceRootQuery =
    typeof req.query['workspaceRoot'] === 'string' ? req.query['workspaceRoot'] : '';
  const runtimeFilter =
    typeof req.query['runtime'] === 'string' ? req.query['runtime'].trim() : '';
  const modelFilter = typeof req.query['model'] === 'string' ? req.query['model'].trim() : '';
  const planFilter = typeof req.query['plan'] === 'string' ? req.query['plan'].trim() : '';

  const logsRoots = await findWorkspaceLogsRootsAsync();
  if (logsRoots.length === 0) {
    res.json(emptySavingsReport());
    return;
  }

  const scopedLogsRoots = filterAggregateRootsByWorkspace(logsRoots, workspaceRootQuery);
  if (scopedLogsRoots.length === 0) {
    res.json(emptySavingsReport());
    return;
  }

  const aggregatedEntries = await collectAggregatedEntriesFromRoots(scopedLogsRoots, '');
  const planDirNames = new Set<string>();
  for (const entry of aggregatedEntries) {
    if (entry.type !== 'dir') {
      continue;
    }
    const normalized = normalizeAggregatePath(entry.path);
    if (!normalized) {
      continue;
    }
    planDirNames.add(normalized.split('/')[0]);
  }
  if (planFilter && planDirNames.size > 0 && !planDirNames.has(planFilter)) {
    res.json(emptySavingsReport());
    return;
  }

  const summaryPaths = await collectSummaryPathsFromLogs(scopedLogsRoots);
  const pathsToProcess = planFilter
    ? summaryPaths.filter((path) => basename(dirname(path)) === planFilter)
    : summaryPaths;
  if (pathsToProcess.length === 0) {
    res.json(emptySavingsReport());
    return;
  }

  const filteredSummaries: string[] = [];
  for (const summaryPath of pathsToProcess) {
    let record: UsageSummaryRecord;
    try {
      const raw = await fs.readFile(summaryPath, 'utf8');
      record = JSON.parse(raw) as UsageSummaryRecord;
    } catch {
      continue;
    }
    if (!record || typeof record !== 'object') {
      continue;
    }
    if (!passesSavingsFilters(record, summaryPath, runtimeFilter, modelFilter, planFilter)) {
      continue;
    }
    filteredSummaries.push(summaryPath);
  }

  if (filteredSummaries.length === 0) {
    res.json(emptySavingsReport());
    return;
  }

  try {
    const savingsReport = await buildSavingsReport(filteredSummaries);
    res.json(savingsReport);
  } catch (error) {
    console.error('Failed to build savings report:', error);
    res.json(emptySavingsReport());
  }
}

export async function handleListRequest(req: Request, res: Response): Promise<void> {
  const rootKey = req.query['root'] as string | undefined;
  const pathParam = (req.query['path'] as string | undefined) ?? '';
  if (!rootKey) {
    return jsonError(res, 400, 'missing root');
  }

  if (!DASHBOARD_EXPLORER_ROOT_KEYS.has(rootKey)) {
    return jsonError(res, 400, 'unknown root');
  }

  if (pathParam.includes('..')) {
    return jsonError(res, 400, 'invalid path');
  }

  const workspaceRootQuery = typeof req.query['workspaceRoot'] === 'string' ? req.query['workspaceRoot'] : '';

  if (rootKey === 'logs') {
    const logsRoots = await findWorkspaceLogsRootsAsync();
    const scopedLogsRoots = filterAggregateRootsByWorkspace(logsRoots, workspaceRootQuery);
    const entries = await collectAggregatedEntriesFromRoots(scopedLogsRoots, pathParam);
    res.json({
      root: rootKey,
      path: normalizeAggregatePath(pathParam),
      parent: parentListingPath(normalizeAggregatePath(pathParam)),
      entries,
    });
    return;
  }

  if (rootKey === 'artifacts') {
    const artifactRoots = await findWorkspaceArtifactsRootsAsync();
    const scopedArtifactRoots = filterAggregateRootsByWorkspace(artifactRoots, workspaceRootQuery);
    const entries = await collectAggregatedEntriesFromRoots(scopedArtifactRoots, pathParam);
    res.json({
      root: rootKey,
      path: normalizeAggregatePath(pathParam),
      parent: parentListingPath(normalizeAggregatePath(pathParam)),
      entries,
    });
    return;
  }

  const projectRootQuery =
    typeof req.query['projectRoot'] === 'string' ? req.query['projectRoot'] : undefined;
  const allowlist = await getMergedWorkspaceAllowlist();
  const dashboardRoots = resolveDashboardRootsForRequest(projectRootQuery, allowlist);
  if (dashboardRoots === null) {
    return jsonError(res, 400, 'invalid projectRoot');
  }
  const roots = getAllowedRoots(dashboardRoots);
  const config = roots[rootKey];
  if (!config) {
    return jsonError(res, 400, 'unknown root');
  }

  let absDir: string;
  try {
    absDir = resolveUnderRoot(config, pathParam);
  } catch {
    return jsonError(res, 400, 'invalid path');
  }

  let stat: Awaited<ReturnType<typeof fs.stat>>;
  try {
    stat = await fs.stat(absDir);
  } catch {
    return jsonError(res, 404, 'not found');
  }

  if (!stat.isDirectory()) {
    return jsonError(res, 400, 'not a directory');
  }

  const normPlansListPath = rootKey === 'plans' ? normalizePlansListPathParam(pathParam) : '';

  if (rootKey === 'plans' && normPlansListPath === '') {
    const entries = await buildPlansRootVirtualListing(absDir);
    res.json({
      root: rootKey,
      path: pathParam,
      parent: parentListingPath(pathParam),
      entries,
    });
    return;
  }

  if (rootKey === 'plans' && !isAllowedPlansPrefix(normPlansListPath)) {
    res.json({
      root: rootKey,
      path: pathParam,
      parent: parentListingPath(pathParam),
      entries: [],
    });
    return;
  }

  let dirents: Dirent[];
  try {
    dirents = await fs.readdir(absDir, { withFileTypes: true });
  } catch {
    return jsonError(res, 500, 'read failed');
  }
  const diskEntryNames = dirents.map((d) => d.name);
  const visibleNames =
    rootKey === 'plans'
      ? filterEntryNamesForPlansListing(absDir, normPlansListPath, diskEntryNames)
      : filterVisibleEntryNames(diskEntryNames);
  visibleNames.sort((a, b) => a.localeCompare(b));

  const relPrefix = pathParam ? (pathParam.endsWith('/') ? pathParam : `${pathParam}/`) : '';

  const entries = (
    await Promise.all(
      visibleNames.map(async (name) => {
        const absChild = join(absDir, name);
        let st: Awaited<ReturnType<typeof fs.stat>>;
        try {
          st = await fs.stat(absChild);
        } catch {
          return null;
        }
        const isDir = st.isDirectory();
        const relPath = isDir ? `${relPrefix}${name}/` : `${relPrefix}${name}`;
        return {
          name,
          path: relPath,
          type: isDir ? 'dir' : 'file',
          size: st.size,
          mtime: Math.floor(st.mtimeMs),
        };
      }),
    )
  ).filter((e): e is NonNullable<typeof e> => e !== null);

  let filteredEntries = entries;
  if (rootKey === 'plans') {
    filteredEntries = entries.filter((entry) => {
      if (entry.type === 'dir') {
        return isPlanDirectoryAllowed(normPlansListPath, entry.name);
      }
      return isPlanListableFile(entry.name);
    });
  }

  res.json({
    root: rootKey,
    path: pathParam,
    parent: parentListingPath(pathParam),
    entries: filteredEntries,
  });
}

export async function handleFileRequest(req: Request, res: Response): Promise<void> {
  const rootKey = req.query['root'] as string | undefined;
  const filePath = (req.query['path'] as string | undefined) ?? '';
  const offsetRaw = (req.query['offset'] as string | undefined) ?? '0';
  const offset = Number.parseInt(offsetRaw, 10);
  if (!rootKey || Number.isNaN(offset) || offset < 0) {
    return jsonError(res, 400, 'bad request');
  }

  if (!DASHBOARD_EXPLORER_ROOT_KEYS.has(rootKey)) {
    return jsonError(res, 400, 'unknown root');
  }

  if (filePath.includes('..')) {
    return jsonError(res, 400, 'invalid path');
  }

  let absFile: string | null = null;
  let stat: Awaited<ReturnType<typeof fs.stat>>;

  if (rootKey === 'logs' || rootKey === 'artifacts') {
    const aggregatedRoots = rootKey === 'logs'
      ? await findWorkspaceLogsRootsAsync()
      : await findWorkspaceArtifactsRootsAsync();
    if (aggregatedRoots.length === 0) {
      return jsonError(res, 404, 'file not found');
    }
    const workspaceRootQuery = typeof req.query['workspaceRoot'] === 'string' ? req.query['workspaceRoot'] : '';
    if (aggregatedRoots.length > 1 && !workspaceRootQuery.trim()) {
      return jsonError(res, 400, 'workspaceRoot query parameter is required when multiple workspaces are aggregated');
    }
    const scopedRoots = filterAggregateRootsByWorkspace(aggregatedRoots, workspaceRootQuery);
    let searchRoots: string[];
    if (workspaceRootQuery.trim()) {
      if (scopedRoots.length === 0) {
        return jsonError(res, 404, 'file not found');
      }
      searchRoots = scopedRoots;
    } else {
      searchRoots = aggregatedRoots;
    }
    const candidate = await findFileInAggregatedRoots(searchRoots, filePath);
    if (!candidate) {
      return jsonError(res, 404, 'file not found');
    }
    absFile = candidate;
    try {
      stat = await fs.stat(absFile);
    } catch {
      return jsonError(res, 404, 'file not found');
    }
  } else {
    const projectRootQuery =
      typeof req.query['projectRoot'] === 'string' ? req.query['projectRoot'] : undefined;
    const allowlist = await getMergedWorkspaceAllowlist();
    const dashboardRoots = resolveDashboardRootsForRequest(projectRootQuery, allowlist);
    if (dashboardRoots === null) {
      return jsonError(res, 400, 'invalid projectRoot');
    }
    const roots = getAllowedRoots(dashboardRoots);
    const config = roots[rootKey];
    if (!config) {
      return jsonError(res, 400, 'unknown root');
    }
    try {
      absFile = resolveUnderRoot(config, filePath);
      stat = await fs.stat(absFile);
    } catch {
      if (rootKey === 'plans' && !filePath.includes('/') && filePath.endsWith('.md')) {
        const found = await findPlanByBasename(
          dashboardRoots.projectRoot,
          dashboardRoots.workspaceRoot,
          filePath,
        );
        if (found) {
          absFile = found;
          try {
            stat = await fs.stat(absFile);
          } catch {
            return jsonError(res, 404, 'file not found');
          }
        } else {
          return jsonError(res, 404, 'file not found');
        }
      } else {
        return jsonError(res, 404, 'file not found');
      }
    }
  }

  if (!absFile) {
    return jsonError(res, 404, 'file not found');
  }

  if (!stat.isFile()) {
    return jsonError(res, 400, 'not a file');
  }

  const size = Number(stat.size);
  if (offset > size) {
    res.json({
      content: '',
      size,
      offset,
      nextOffset: size,
    });
    return;
  }

  const length = Math.min(FILE_CHUNK_BYTES, size - offset);
  const handle = await fs.open(absFile, 'r');
  try {
    const buf = Buffer.alloc(length);
    const { bytesRead } = await handle.read(buf, 0, length, offset);
    const content = buf.subarray(0, bytesRead).toString('utf8');
    const nextOffset = offset + bytesRead;
    res.json({
      content,
      size,
      offset,
      nextOffset,
    });
  } finally {
    await handle.close();
  }
}

export async function handleTemplateRequest(req: Request, res: Response): Promise<void> {
  const name = req.query['name'] as string | undefined;
  if (!name || (name !== 'plan' && name !== 'orchestration')) {
    return jsonError(res, 400, 'invalid template name');
  }

  const projectRootQuery =
    typeof req.query['projectRoot'] === 'string' ? req.query['projectRoot'] : undefined;
  const allowlist = await getMergedWorkspaceAllowlist();
  const dashboardRoots = resolveDashboardRootsForRequest(projectRootQuery, allowlist);
  if (dashboardRoots === null) {
    return jsonError(res, 400, 'invalid projectRoot');
  }
  const roots = getAllowedRoots(dashboardRoots);
  const plans = roots['plans'];
  if (!plans) {
    return jsonError(res, 500, 'config');
  }

  const rel = name === 'plan' ? '.ralph/plan.template' : '.ralph/orchestration.template.json';
  let absPath: string;
  try {
    absPath = resolveUnderRoot(plans, rel);
  } catch {
    return jsonError(res, 404, 'template not found');
  }

  try {
    const text = await fs.readFile(absPath, 'utf8');
    res.json({ name, content: text });
  } catch {
    return jsonError(res, 404, 'template not found');
  }
}

export interface MergedWorkspaceEntry {
  path: string;
  workspaceRoot: string;
  projectRoot: string;
  label: string;
  exists: boolean;
  sections: Record<string, boolean>;
  lastSeen?: string;
  planKey?: string;
  runtime?: string;
}

async function workspaceSectionsAsync(
  projectRoot: string,
  workspaceRoot: string,
): Promise<Record<string, boolean>> {
  const roots = getAllowedRoots({ projectRoot, workspaceRoot });
  const keys = Array.from(DASHBOARD_EXPLORER_ROOT_KEYS);
  const checks = await Promise.all(
    keys.map(async (key) => {
      const config = roots[key];
      if (!config) return [key, false] as const;
      try {
        const stat = await fs.stat(config.basePath);
        return [key, stat.isDirectory()] as const;
      } catch {
        return [key, false] as const;
      }
    }),
  );
  return Object.fromEntries(checks);
}

let mergedWorkspaceAllowlistCache: { expiresAt: number; data: MergedWorkspaceEntry[] } | null = null;
let mergedWorkspaceAllowlistInflight: Promise<MergedWorkspaceEntry[]> | null = null;

export function clearMergedWorkspaceAllowlistCache(): void {
  mergedWorkspaceAllowlistCache = null;
  mergedWorkspaceAllowlistInflight = null;
  clearWorkspaceRootsCache();
  clearDashboardRootsCache();
}

function mergedWorkspaceAllowlistTtlMs(): number {
  const raw = process.env['RALPH_DASHBOARD_WORKSPACE_ALLOWLIST_TTL_MS']?.trim();
  if (!raw) {
    return 30_000;
  }
  const n = Number.parseInt(raw, 10);
  return Number.isFinite(n) && n >= 0 ? n : 30_000;
}

async function computeMergedWorkspaceAllowlistBody(): Promise<MergedWorkspaceEntry[]> {
  const registry = await loadWorkspaces();
  const discovered = findAllWorkspaceRoots();
  const byProject = new Map<string, MergedWorkspaceEntry>();

  const discoveredEntries = await Promise.all(
    discovered.map(async (wsRoot) => {
      const workspaceRoot = resolve(wsRoot);
      const projectRoot = resolve(dirname(workspaceRoot));
      const reg = registry.find((r) => resolve(r.path) === projectRoot);
      return {
        path: projectRoot,
        workspaceRoot,
        projectRoot,
        label: basename(projectRoot),
        exists: existsSync(workspaceRoot),
        sections: await workspaceSectionsAsync(projectRoot, workspaceRoot),
        lastSeen: reg?.lastSeen,
        planKey: reg?.planKey,
        runtime: reg?.runtime,
      };
    }),
  );

  for (const entry of discoveredEntries) {
    byProject.set(entry.projectRoot, entry);
  }

  const registryOnlyWorkspaces = registry.filter(
    (workspace) => !byProject.has(resolve(workspace.path)),
  );

  const registryEntries = await Promise.all(
    registryOnlyWorkspaces.map(async (workspace) => {
      const projectRoot = resolve(workspace.path);
      const workspaceRoot = join(projectRoot, '.ralph-workspace');
      return {
        path: projectRoot,
        workspaceRoot,
        projectRoot,
        label: basename(projectRoot),
        exists: existsSync(workspaceRoot),
        sections: await workspaceSectionsAsync(projectRoot, workspaceRoot),
        lastSeen: workspace.lastSeen,
        planKey: workspace.planKey,
        runtime: workspace.runtime,
      };
    }),
  );

  for (const entry of registryEntries) {
    byProject.set(entry.projectRoot, entry);
  }

  for (const workspace of registry) {
    const projectRoot = resolve(workspace.path);
    const existing = byProject.get(projectRoot);
    if (existing) {
      existing.lastSeen = workspace.lastSeen ?? existing.lastSeen;
      existing.planKey = workspace.planKey ?? existing.planKey;
      existing.runtime = workspace.runtime ?? existing.runtime;
    }
  }

  const frameworkRoot = resolveRalphInstallRoot();
  if (frameworkRoot && existsSync(join(frameworkRoot, 'bundle', '.ralph'))) {
    const defaultWorkspace = join(frameworkRoot, '.ralph-workspace');
    const workspaceRoot =
      existsSync(defaultWorkspace) && statSync(defaultWorkspace).isDirectory()
        ? resolve(defaultWorkspace)
        : resolve(frameworkRoot);
    const prev = byProject.get(frameworkRoot);
    const sections = await workspaceSectionsAsync(frameworkRoot, workspaceRoot);
    byProject.set(frameworkRoot, {
      path: frameworkRoot,
      workspaceRoot,
      projectRoot: frameworkRoot,
      label: 'Ralph docs',
      exists: true,
      sections: {
        ...sections,
        logs: false,
        artifacts: false,
        sessions: false,
        'orchestration-plans': false,
        plans: false,
      },
      lastSeen: prev?.lastSeen,
      planKey: prev?.planKey,
      runtime: prev?.runtime,
    });
  }

  return Array.from(byProject.values())
    .filter((entry) => entry.exists)
    .sort((a, b) => a.projectRoot.localeCompare(b.projectRoot));
}

export async function getMergedWorkspaceAllowlist(): Promise<MergedWorkspaceEntry[]> {
  const now = Date.now();
  if (mergedWorkspaceAllowlistCache && now < mergedWorkspaceAllowlistCache.expiresAt) {
    return mergedWorkspaceAllowlistCache.data;
  }
  if (!mergedWorkspaceAllowlistInflight) {
    mergedWorkspaceAllowlistInflight = computeMergedWorkspaceAllowlistBody().finally(() => {
      mergedWorkspaceAllowlistInflight = null;
    });
  }
  const data = await mergedWorkspaceAllowlistInflight;
  mergedWorkspaceAllowlistCache = { expiresAt: Date.now() + mergedWorkspaceAllowlistTtlMs(), data };
  return data;
}

export function resolveDashboardRootsForRequest(
  projectRootQuery: string | undefined,
  allowlist: ReadonlyArray<{ projectRoot: string; workspaceRoot: string }>,
): DashboardRoots | null {
  const trimmed = typeof projectRootQuery === 'string' ? projectRootQuery.trim() : '';
  if (!trimmed) {
    return findDashboardRoots();
  }

  const target = resolve(trimmed);
  for (const entry of allowlist) {
    const entryRoot = resolve(entry.projectRoot);
    if (entryRoot === target) {
      return {
        projectRoot: entryRoot,
        workspaceRoot: resolve(entry.workspaceRoot),
      };
    }
  }

  const installRoot = resolveRalphInstallRoot();
  if (installRoot) {
    let matched = false;
    try {
      const canonicalTarget = existsSync(target) ? realpathSync(target) : target;
      matched = installRoot === canonicalTarget || resolve(installRoot) === resolve(canonicalTarget);
    } catch {
      matched = resolve(installRoot) === resolve(target);
    }
    if (matched) {
      const workspaceFallback = join(installRoot, '.ralph-workspace');
      return {
        projectRoot: installRoot,
        workspaceRoot:
          existsSync(workspaceFallback) && statSync(workspaceFallback).isDirectory()
            ? resolve(workspaceFallback)
            : installRoot,
      };
    }
  }

  return null;
}

export async function handleWorkspacesRequest(_req: Request, res: Response): Promise<void> {
  const body = await getMergedWorkspaceAllowlist();
  res.json(body);
}

export function registerDashboardApi(app: Express): void {
  app.get('/api/workspace', (_req: Request, res: Response) => {
    const root = findWorkspaceProjectRoot();
    res.json({ root });
  });

  app.get('/api/ralph-framework-root', (_req: Request, res: Response) => {
    res.json({ projectRoot: resolveRalphInstallRoot() });
  });

  app.get('/api/roots', (_req: Request, res: Response) => {
    const roots = getRootsMap();
    const body = Object.entries(roots).map(([key, config]) => ({
      key,
      label: config.label,
      exists: existsSync(config.basePath),
    }));
    res.json(body);
  });

  app.get('/api/list', handleListRequest);
  app.get('/api/file', handleFileRequest);
  app.get('/api/template', handleTemplateRequest);
  app.get('/api/metrics/summary', handleMetricsSummaryRequest);
  app.get('/api/benchmarks', handleSavingsRequest);
  app.get('/api/metrics/discover/:planKey', handleMetricsDiscoverRequest);
  app.get('/api/workspaces', handleWorkspacesRequest);
}
