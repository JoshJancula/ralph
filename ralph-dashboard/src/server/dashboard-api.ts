import type { Express, Request, Response } from 'express';
import { type Dirent, existsSync, promises as fs, realpathSync, statSync } from 'node:fs';
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
  max_turn_total_tokens?: number;
  cache_hit_ratio?: number;
  prompt_bytes?: number;
  todo_bytes?: number;
  todo_continuation_lines?: number;
  direct_verification_count?: number;
  rate_limit_count?: number;
  tool_turns?: number;
  tool_calls_total?: number;
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
  prompt_bytes?: number;
  todo_bytes?: number;
  todo_continuation_lines?: number;
  direct_verification_count?: number;
  rate_limit_count?: number;
  tool_turns?: number;
  tool_calls_total?: number;
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
  const overallTotalInput =
    overall.input_tokens + overall.cache_read_input_tokens + overall.cache_creation_input_tokens;
  overall.cache_hit_ratio =
    overallTotalInput > 0
      ? Math.round((overall.cache_read_input_tokens / overallTotalInput) * 10000) / 10000
      : 0;
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
    model_breakdown: record.model_breakdown,
    invocations: record.invocations === undefined ? undefined : toNumber(record.invocations),
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
        prompt_bytes: 0,
        todo_bytes: 0,
        todo_continuation_lines: 0,
        direct_verification_count: 0,
        rate_limit_count: 0,
        tool_turns: 0,
        tool_calls_total: 0,
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
        const totalInput =
          bucket.input_tokens + bucket.cache_creation_input_tokens + bucket.cache_read_input_tokens;
        const cache_hit_ratio =
          totalInput > 0
            ? Math.round((bucket.cache_read_input_tokens / totalInput) * 10000) / 10000
            : 0;
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
          prompt_bytes: bucket.prompt_bytes,
          todo_bytes: bucket.todo_bytes,
          todo_continuation_lines: bucket.todo_continuation_lines,
          direct_verification_count: bucket.direct_verification_count,
          rate_limit_count: bucket.rate_limit_count,
          tool_turns: bucket.tool_turns,
          tool_calls_total: bucket.tool_calls_total,
        };
      });

    const totals = breakdown.reduce(
      (acc, item) => {
        acc.invocations += item.invocations;
        acc.elapsed_seconds += item.elapsed_seconds;
        acc.input_tokens += item.input_tokens;
        acc.output_tokens += item.output_tokens;
        acc.cache_creation_input_tokens += item.cache_creation_input_tokens;
        acc.cache_read_input_tokens += item.cache_read_input_tokens;
        acc.prompt_bytes += item.prompt_bytes;
        acc.todo_bytes += item.todo_bytes;
        acc.todo_continuation_lines += item.todo_continuation_lines;
        acc.direct_verification_count += item.direct_verification_count;
        acc.rate_limit_count += item.rate_limit_count;
        acc.tool_turns += item.tool_turns;
        acc.tool_calls_total += item.tool_calls_total;
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
      model_breakdown: breakdown,
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

      const isPlanSummary = basename(summaryPath) === 'plan-usage-summary.json';
      const withFallback = isPlanSummary
        ? await applyModelBreakdownFallback(normalized, summaryPath)
        : normalized;

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
  const overallTotalInput =
    overall.input_tokens + overall.cache_read_input_tokens + overall.cache_creation_input_tokens;
  overall.cache_hit_ratio =
    overallTotalInput > 0
      ? Math.round((overall.cache_read_input_tokens / overallTotalInput) * 10000) / 10000
      : 0;

  const projects = buildProjectsRollup(plans, orchestrations);

  res.json({
    overall,
    plans,
    orchestrations,
    projects,
  });
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
  app.get('/api/workspaces', handleWorkspacesRequest);
}
