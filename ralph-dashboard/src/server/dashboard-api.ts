import type { Express, Request, Response } from 'express';
import { type Dirent, existsSync, promises as fs } from 'node:fs';
import { basename, dirname, join } from 'node:path';

import {
  filterVisibleEntryNames,
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
}
