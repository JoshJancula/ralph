import type { Express, Request, Response } from 'express';
import { type Dirent, existsSync, promises as fs } from 'node:fs';
import { basename, dirname, join } from 'node:path';

import {
  filterVisibleEntryNames,
  findDashboardRoots,
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
  invocations?: number;
  steps?: number;
  todos_done?: number;
  todos_total?: number;
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
  const kind =
    record.kind === 'plan_usage_summary' || record.kind === 'orchestration_usage_summary'
      ? record.kind
      : (() => {
          const file = basename(summaryPath);
          if (file === 'plan-usage-summary.json' && record.invocations !== undefined) {
            return 'plan_usage_summary' as const;
          }
          if (file === 'orchestration-usage-summary.json' && record.steps !== undefined) {
            return 'orchestration_usage_summary' as const;
          }
          return null;
        })();

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
  };
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
  const roots = getAllowedRoots(findDashboardRoots());
  const logsRoot = roots['logs']?.basePath;
  if (!logsRoot || !existsSync(logsRoot)) {
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

  const summaryPaths = await collectSummaryFiles(logsRoot);
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

      overall.input_tokens += normalized.input_tokens;
      overall.output_tokens += normalized.output_tokens;
      overall.cache_creation_input_tokens += normalized.cache_creation_input_tokens;
      overall.cache_read_input_tokens += normalized.cache_read_input_tokens;
      overall.elapsed_seconds += normalized.elapsed_seconds;
      if (normalized.max_turn_total_tokens > overall.max_turn_total_tokens) {
        overall.max_turn_total_tokens = normalized.max_turn_total_tokens;
      }
      overall.count += 1;

      if (parsed.kind === 'plan_usage_summary') {
        plans.push(normalized);
      } else {
        orchestrations.push(normalized);
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

    // Filter plan files to only show files with corresponding logs directories
    let filteredEntries = entries;
    if (rootKey === 'plans' && !pathParam) {
      const logsConfig = getRootsMap()['logs'];
      if (logsConfig && existsSync(logsConfig.basePath)) {
        filteredEntries = [];
        for (const entry of entries) {
          // Skip directories - only show files
          if (entry.type === 'dir') {
            continue;
          }
          // For files, check if there's a corresponding directory in logs with matching name
          const fileName = entry.name;
          // Try with the full filename (without extension) as directory name
          const fileNameWithoutExt = fileName.includes('.')
            ? fileName.substring(0, fileName.lastIndexOf('.'))
            : fileName;
          const logsPlanDir = join(logsConfig.basePath, fileNameWithoutExt);
          try {
            const logsStat = await fs.stat(logsPlanDir);
            if (logsStat.isDirectory()) {
              filteredEntries.push(entry);
            }
          } catch {
            // Corresponding logs directory doesn't exist, skip this file
          }
        }
      }
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

    const roots = getRootsMap();
    const config = roots[rootKey];
    if (!config) {
      return jsonError(res, 400, 'unknown root');
    }

    let absFile: string;
    try {
      absFile = resolveUnderRoot(config, filePath);
    } catch {
      return jsonError(res, 400, 'invalid path');
    }

    let stat: Awaited<ReturnType<typeof fs.stat>>;
    try {
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
