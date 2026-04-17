import type { Express, Request, Response } from 'express';
import { type Dirent, existsSync, promises as fs } from 'node:fs';
import { basename, dirname, join } from 'node:path';

import {
  filterVisibleEntryNames,
  findDashboardRoots,
  findWorkspaceArtifactsRoots,
  findWorkspaceLogsRoots,
  findWorkspaceProjectRoot,
  getAllowedRoots,
  isHiddenEntryName,
  parentListingPath,
  resolveUnderRoot,
  type RootConfig,
} from '../paths';

const FILE_CHUNK_BYTES = 256 * 1024;
const SUMMARY_FILE_NAMES = new Set(['plan-usage-summary.json', 'orchestration-usage-summary.json']);

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
  max_turn_total_tokens?: number;
  cache_hit_ratio?: number;
  model_breakdown?: ModelBreakdownItem[];
  invocations?: number;
  steps?: number;
  todos_done?: number;
  todos_total?: number;
}

interface ModelBreakdownItem {
  runtime: string;
  model: string;
  invocations: number;
  elapsed_seconds: number;
  input_tokens: number;
  output_tokens: number;
  cache_creation_input_tokens: number;
  cache_read_input_tokens: number;
  max_turn_total_tokens: number;
  cache_hit_ratio: number;
}

interface MetricsSummaryItem {
  path: string;
  plan_key: string;
  artifact_ns: string;
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
  model_breakdown?: ModelBreakdownItem[];
}

type AggregatedListingEntry = {
  name: string;
  path: string;
  type: 'file' | 'dir';
  size: number;
  mtime: number;
};

async function collectSummaryPathsFromLogs(logRoots: string[]): Promise<string[]> {
  const seen = new Set<string>();

  for (const root of logRoots) {
    const files = await collectSummaryFiles(root);
    for (const file of files) {
      seen.add(file);
    }
  }

  return Array.from(seen).sort();
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

  for (const root of roots) {
    const target = normalized ? join(root, normalized) : root;
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
      };

      const existing = entriesMap.get(displayPath);
      if (!existing || entry.mtime > existing.mtime) {
        entriesMap.set(displayPath, entry);
      }
    }
  }

  return Array.from(entriesMap.values()).sort((a, b) => a.path.localeCompare(b.path));
}

async function findFileInAggregatedRoots(
  roots: string[],
  relPath: string,
): Promise<string | null> {
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
  '.ralph-workspace',
  '.git',
  'public',
  'ralph-dashboard',
  'scripts',
  'tests',
]);

const PLAN_ROOT_FILE_DENYLIST = new Set(['agents.md', 'claude.md', 'readme.md']);

function isPlanDirectoryAllowed(name: string): boolean {
  return !PLAN_DIR_BLOCKLIST.has(name.toLowerCase());
}

function isPlanRootFile(name: string): boolean {
  const lower = name.toLowerCase();
  if (PLAN_ROOT_FILE_DENYLIST.has(lower)) {
    return false;
  }
  if (lower.endsWith('.md')) {
    const base = lower.slice(0, -3);
    return base.startsWith('plan');
  }
  if (lower.endsWith('.mdc')) {
    const base = lower.slice(0, -4);
    return base.startsWith('plan');
  }
  return false;
}


function jsonError(res: Response, status: number, message: string): void {
  res.status(status).json({ error: message });
}

function getRootsMap(): Record<string, RootConfig> {
  return getAllowedRoots(findDashboardRoots());
}

async function findPlanByBasename(workspaceRoot: string, fileName: string): Promise<string | null> {
  const maxDepth = 8;
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

  return await walk(workspaceRoot, 0);
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

function normalizeSummaryRecord(record: UsageSummaryRecord, summaryPath: string): MetricsSummaryItem | null {
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

  return {
    path: summaryPath,
    plan_key: record.plan_key ?? inferredKey,
    artifact_ns: record.artifact_ns ?? inferredKey,
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
    model_breakdown: record.model_breakdown,
  };
}

async function applyModelBreakdownFallback(
  normalized: MetricsSummaryItem,
  summaryPath: string,
): Promise<MetricsSummaryItem> {
  if (Array.isArray(normalized.model_breakdown) && normalized.model_breakdown.length > 0) {
    return normalized;
  }

  const allTokensZero =
    normalized.input_tokens === 0 &&
    normalized.output_tokens === 0 &&
    normalized.cache_creation_input_tokens === 0 &&
    normalized.cache_read_input_tokens === 0;

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
      }
    >();

    for (const record of parsed.invocations) {
      if (!record || typeof record !== 'object') {
        continue;
      }

      const item = record as Record<string, unknown>;
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
      };

      bucket.invocations += 1;
      bucket.elapsed_seconds += toNumber(item['elapsed_seconds']);
      bucket.input_tokens += toNumber(item['input_tokens']);
      bucket.output_tokens += toNumber(item['output_tokens']);
      bucket.cache_creation_input_tokens += toNumber(item['cache_creation_input_tokens']);
      bucket.cache_read_input_tokens += toNumber(item['cache_read_input_tokens']);
      const invocationMaxTurn = toNumber(item['max_turn_total_tokens']);
      if (invocationMaxTurn > bucket.max_turn_total_tokens) {
        bucket.max_turn_total_tokens = invocationMaxTurn;
      }
      grouped.set(key, bucket);
    }

    const breakdown = Array.from(grouped.values())
      .sort((a, b) => `${a.runtime}\u0000${a.model}`.localeCompare(`${b.runtime}\u0000${b.model}`))
      .map((bucket) => {
        const totalInput =
          bucket.input_tokens + bucket.cache_creation_input_tokens + bucket.cache_read_input_tokens;
        const cache_hit_ratio = totalInput > 0 ? Math.round((bucket.cache_read_input_tokens / totalInput) * 10000) / 10000 : 0;
        return {
          runtime: bucket.runtime,
          model: bucket.model,
          invocations: bucket.invocations,
          elapsed_seconds: bucket.elapsed_seconds,
          input_tokens: bucket.input_tokens,
          output_tokens: bucket.output_tokens,
          cache_creation_input_tokens: bucket.cache_creation_input_tokens,
          cache_read_input_tokens: bucket.cache_read_input_tokens,
          max_turn_total_tokens: bucket.max_turn_total_tokens,
          cache_hit_ratio,
        };
      });

    if (!allTokensZero) {
      return {
        ...normalized,
        model_breakdown: breakdown,
      };
    }

    const totals = breakdown.reduce(
      (acc, item) => {
        acc.input_tokens += item.input_tokens;
        acc.output_tokens += item.output_tokens;
        acc.cache_creation_input_tokens += item.cache_creation_input_tokens;
        acc.cache_read_input_tokens += item.cache_read_input_tokens;
        if (item.max_turn_total_tokens > acc.max_turn_total_tokens) {
          acc.max_turn_total_tokens = item.max_turn_total_tokens;
        }
        return acc;
      },
      {
        input_tokens: 0,
        output_tokens: 0,
        cache_creation_input_tokens: 0,
        cache_read_input_tokens: 0,
        max_turn_total_tokens: 0,
      },
    );
    const totalInput =
      totals.input_tokens + totals.cache_creation_input_tokens + totals.cache_read_input_tokens;

    return {
      ...normalized,
      input_tokens: totals.input_tokens,
      output_tokens: totals.output_tokens,
      cache_creation_input_tokens: totals.cache_creation_input_tokens,
      cache_read_input_tokens: totals.cache_read_input_tokens,
      max_turn_total_tokens: totals.max_turn_total_tokens,
      cache_hit_ratio: totalInput > 0 ? Math.round((totals.cache_read_input_tokens / totalInput) * 10000) / 10000 : 0,
      model_breakdown: breakdown,
    };
  } catch {
    return normalized;
  }
}

async function collectSummaryFiles(dir: string, output: string[] = []): Promise<string[]> {
  let entries: Dirent[];
  try {
    entries = await fs.readdir(dir, { withFileTypes: true, encoding: 'utf8' });
  } catch {
    return output;
  }

  for (const entry of entries) {
    const absPath = join(dir, entry.name);
    if (entry.isDirectory()) {
      await collectSummaryFiles(absPath, output);
      continue;
    }

    if (entry.isFile() && SUMMARY_FILE_NAMES.has(entry.name)) {
      output.push(absPath);
    }
  }

  return output;
}

export async function handleMetricsSummaryRequest(_req: Request, res: Response): Promise<void> {
  const logsRoots = findWorkspaceLogsRoots();
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
      },
      plans: [],
      orchestrations: [],
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
  };

  for (const summaryPath of summaryPaths) {
    try {
      const raw = await fs.readFile(summaryPath, 'utf8');
      const parsed = JSON.parse(raw) as UsageSummaryRecord;
      const normalized = normalizeSummaryRecord(parsed, summaryPath);
      if (!normalized) {
        continue;
      }

      const isPlanSummary = basename(summaryPath) === 'plan-usage-summary.json';
      const withFallback = isPlanSummary ? await applyModelBreakdownFallback(normalized, summaryPath) : normalized;

      overall.input_tokens += withFallback.input_tokens;
      overall.output_tokens += withFallback.output_tokens;
      overall.cache_creation_input_tokens += withFallback.cache_creation_input_tokens;
      overall.cache_read_input_tokens += withFallback.cache_read_input_tokens;
      overall.elapsed_seconds += withFallback.elapsed_seconds;
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
  const overallTotalInput =
    overall.input_tokens + overall.cache_read_input_tokens + overall.cache_creation_input_tokens;
  overall.cache_hit_ratio =
    overallTotalInput > 0
      ? Math.round((overall.cache_read_input_tokens / overallTotalInput) * 10000) / 10000
      : 0;

  res.json({
    overall,
    plans,
    orchestrations,
  });
}

export async function handleListRequest(req: Request, res: Response): Promise<void> {
    const rootKey = req.query['root'] as string | undefined;
    const pathParam = (req.query['path'] as string | undefined) ?? '';
    if (!rootKey) {
      return jsonError(res, 400, 'missing root');
    }

    const roots = getRootsMap();
    const config = roots[rootKey];
    if (!config) {
      return jsonError(res, 400, 'unknown root');
    }

  if (pathParam.includes('..')) {
    return jsonError(res, 400, 'invalid path');
  }

  const logsRoots = findWorkspaceLogsRoots();
  const artifactRoots = findWorkspaceArtifactsRoots();
  if (rootKey === 'logs') {
    if (logsRoots.length === 0) {
      return jsonError(res, 404, 'not found');
    }
    const entries = await collectAggregatedEntriesFromRoots(logsRoots, pathParam);
    res.json({
      root: rootKey,
      path: normalizeAggregatePath(pathParam),
      parent: parentListingPath(normalizeAggregatePath(pathParam)),
      entries,
    });
    return;
  }

  if (rootKey === 'artifacts') {
    if (artifactRoots.length === 0) {
      return jsonError(res, 404, 'not found');
    }
    const entries = await collectAggregatedEntriesFromRoots(artifactRoots, pathParam);
    res.json({
      root: rootKey,
      path: normalizeAggregatePath(pathParam),
      parent: parentListingPath(normalizeAggregatePath(pathParam)),
      entries,
    });
    return;
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

    let names: string[];
    try {
      names = await fs.readdir(absDir);
    } catch {
      return jsonError(res, 500, 'read failed');
    }

    const visibleNames = filterVisibleEntryNames(names);
    visibleNames.sort((a, b) => a.localeCompare(b));

    const entries: Array<{
      name: string;
      path: string;
      type: 'file' | 'dir';
      size: number;
      mtime: number;
    }> = [];

    const relPrefix = pathParam ? (pathParam.endsWith('/') ? pathParam : `${pathParam}/`) : '';

    for (const name of visibleNames) {
      const absChild = join(absDir, name);
      let st: Awaited<ReturnType<typeof fs.stat>>;
      try {
        st = await fs.stat(absChild);
      } catch {
        continue;
      }
      const isDir = st.isDirectory();
      const relPath = isDir ? `${relPrefix}${name}/` : `${relPrefix}${name}`;
      entries.push({
        name,
        path: relPath,
        type: isDir ? 'dir' : 'file',
        size: st.size,
        mtime: Math.floor(st.mtimeMs),
      });
    }

    let filteredEntries = entries;
    if (rootKey === 'plans') {
      const isRootPath = !pathParam;
      filteredEntries = entries.filter((entry) => {
        if (entry.type === 'dir') {
          return isPlanDirectoryAllowed(entry.name);
        }
        if (!isRootPath) {
          return true;
        }
        return isPlanRootFile(entry.name);
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

    if (filePath.includes('..')) {
      return jsonError(res, 400, 'invalid path');
    }

    const logsRoots = findWorkspaceLogsRoots();
    const artifactRoots = findWorkspaceArtifactsRoots();
    let absFile: string | null = null;
    let stat: Awaited<ReturnType<typeof fs.stat>>;

    if (rootKey === 'logs' || rootKey === 'artifacts') {
      const aggregatedRoots = rootKey === 'logs' ? logsRoots : artifactRoots;
      if (aggregatedRoots.length === 0) {
        return jsonError(res, 404, 'file not found');
      }
      const candidate = await findFileInAggregatedRoots(aggregatedRoots, filePath);
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
      const roots = getRootsMap();
      const config = roots[rootKey];
      if (!config) {
        return jsonError(res, 400, 'unknown root');
      }
      try {
        absFile = resolveUnderRoot(config, filePath);
        stat = await fs.stat(absFile);
      } catch {
        if (rootKey === 'plans' && !filePath.includes('/') && filePath.endsWith('.md')) {
          const { projectRoot } = findDashboardRoots();
          const found = await findPlanByBasename(projectRoot, filePath);
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

    const dashboardRoots = findDashboardRoots();
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

export function registerDashboardApi(app: Express): void {
  app.get('/api/workspace', (_req: Request, res: Response) => {
    const root = findWorkspaceProjectRoot();
    res.json({ root });
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
}
