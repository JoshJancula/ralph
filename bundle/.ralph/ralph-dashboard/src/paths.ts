import { basename, dirname, join, relative, resolve } from 'node:path';
import { Dirent, existsSync, readFileSync, readdirSync, realpathSync, statSync, promises as fsPromises } from 'node:fs';
import { homedir } from 'node:os';
import { fileURLToPath } from 'node:url';

export interface RootConfig {
  label: string;
  basePath: string;
  writable: boolean;
}

export interface DashboardRoots {
  projectRoot: string;
  workspaceRoot: string;
}

export function isHiddenEntryName(name: string): boolean {
  return name.length > 1 && name.startsWith('.');
}

export function filterVisibleEntryNames(names: readonly string[]): string[] {
  return names.filter((name) => !isHiddenEntryName(name));
}

function hasEntry(dir: string, entry: string): boolean {
  const candidate = join(dir, entry);
  if (!existsSync(candidate)) {
    return false;
  }

  try {
    return statSync(candidate).isDirectory();
  } catch {
    return false;
  }
}

function hasDotRalphWorkspace(dir: string): boolean {
  return hasEntry(dir, '.ralph-workspace');
}

function hasDotRalphDir(dir: string): boolean {
  return hasEntry(dir, '.ralph');
}

const WORKSPACE_CONTENT_ENTRIES = ['logs', 'artifacts', 'sessions', 'orchestration-plans', 'handoffs'] as const;
const HOME_WORKSPACE_SEARCH_DEPTH = 5;

function isPopulatedWorkspace(workspaceDir: string): boolean {
  return WORKSPACE_CONTENT_ENTRIES.some((entry) => hasEntry(workspaceDir, entry));
}

function walkUpForEntry(startDir: string, entry: string): string | null {
  let dir = startDir;
  for (let i = 0; i < 64; i++) {
    if (hasEntry(dir, entry)) {
      return dir;
    }
    const parent = dirname(dir);
    if (parent === dir) {
      break;
    }
    dir = parent;
  }
  return null;
}

function walkUpForPopulatedWorkspace(startDir: string): string | null {
  let dir = startDir;
  let firstMatch: string | null = null;
  for (let i = 0; i < 64; i++) {
    if (hasDotRalphWorkspace(dir)) {
      const workspace = join(dir, '.ralph-workspace');
      if (isPopulatedWorkspace(workspace)) {
        return workspace;
      }
      if (firstMatch === null) {
        firstMatch = workspace;
      }
    }
    const parent = dirname(dir);
    if (parent === dir) {
      break;
    }
    dir = parent;
  }
  return firstMatch;
}

function determineProjectRoot(): string {
  const envRootKeys = ['RALPH_DASHBOARD_PROJECT_ROOT', 'RALPH_PROJECT_ROOT'] as const;
  for (const key of envRootKeys) {
    const envRoot = process.env[key];
    if (!envRoot) {
      continue;
    }
    const resolved = resolve(envRoot);
    if (hasDotRalphDir(resolved)) {
      return resolved;
    }
  }

  const fromCwd = walkUpForEntry(process.cwd(), '.ralph');
  if (fromCwd) {
    return fromCwd;
  }

  const fromModule = walkUpForEntry(dirname(fileURLToPath(import.meta.url)), '.ralph');
  if (fromModule) {
    return fromModule;
  }

  return process.cwd();
}

function determineWorkspaceRoot(projectRoot: string): string {
  const envRootKeys = ['RALPH_DASHBOARD_WORKSPACE_ROOT', 'RALPH_PLAN_WORKSPACE_ROOT'] as const;
  for (const key of envRootKeys) {
    const envRoot = process.env[key];
    if (!envRoot) {
      continue;
    }
    const resolved = resolve(envRoot);
    if (basename(resolved) === '.ralph-workspace') {
      return resolved;
    }
    if (hasDotRalphWorkspace(resolved)) {
      return join(resolved, '.ralph-workspace');
    }
  }

  if (dashboardGlobalMode()) {
    const registryPaths = readRegistryWorkspacePaths();
    if (registryPaths.length > 0) {
      return registryPaths[0];
    }
  }

  if (dashboardFullMode()) {
    const home = process.env['HOME']?.trim();
    if (home) {
      const discovered = new Set<string>();
      collectWorkspaceDirsUnderHome(home, HOME_WORKSPACE_SEARCH_DEPTH, discovered);
      const firstDiscovered = Array.from(discovered)[0];
      if (firstDiscovered) {
        return firstDiscovered;
      }
    }
  } else if (hasDotRalphWorkspace(process.cwd())) {
    return join(process.cwd(), '.ralph-workspace');
  }

  const fromCwd = walkUpForPopulatedWorkspace(process.cwd());
  if (fromCwd) {
    return fromCwd;
  }

  const fromModule = walkUpForPopulatedWorkspace(dirname(fileURLToPath(import.meta.url)));
  if (fromModule) {
    return fromModule;
  }

  return join(projectRoot, '.ralph-workspace');
}

let dashboardRootsCache: { expiresAt: number; data: DashboardRoots } | null = null;
const DASHBOARD_ROOTS_TTL_MS = 30_000;

export function findDashboardRoots(): DashboardRoots {
  const now = Date.now();
  if (dashboardRootsCache && now < dashboardRootsCache.expiresAt) {
    return dashboardRootsCache.data;
  }
  const projectRoot = determineProjectRoot();
  const workspaceRoot = determineWorkspaceRoot(projectRoot);
  const data = { projectRoot, workspaceRoot };
  dashboardRootsCache = { expiresAt: now + DASHBOARD_ROOTS_TTL_MS, data };
  return data;
}

export function clearDashboardRootsCache(): void {
  dashboardRootsCache = null;
}

export function findWorkspaceProjectRoot(): string {
  return findDashboardRoots().projectRoot;
}

function directoryHasVisibleEntries(dir: string): boolean {
  if (!existsSync(dir) || !statSync(dir).isDirectory()) {
    return false;
  }
  try {
    const names = filterVisibleEntryNames(readdirSync(dir));
    return names.length > 0;
  } catch {
    return false;
  }
}

/**
 * Global Ralph install directory: ${RALPH_HOME} when set and present, otherwise ~/.ralph when it exists.
 * Used as a synthetic `projectRoot` so the docs explorer resolves to framework docs under that tree.
 */
export function resolveRalphInstallRoot(): string | null {
  const env = process.env['RALPH_HOME']?.trim();
  const candidates: string[] = [];
  if (env) {
    candidates.push(resolve(env));
  }
  candidates.push(resolve(join(homedir(), '.ralph')));
  for (const dir of candidates) {
    try {
      if (existsSync(dir) && statSync(dir).isDirectory()) {
        return realpathSync(dir);
      }
    } catch {
      continue;
    }
  }
  return null;
}

function ralphDocsFromBundledInstall(): string | null {
  const home = process.env['RALPH_HOME']?.trim();
  if (!home) {
    return null;
  }
  const resolvedHome = resolve(home);
  const candidate = join(resolvedHome, 'docs');
  if (existsSync(candidate) && statSync(candidate).isDirectory()) {
    return resolve(candidate);
  }
  return null;
}

function ralphDocsFromRepositoryWalk(): string | null {
  let dir = dirname(fileURLToPath(import.meta.url));
  for (let i = 0; i < 14; i++) {
    const candidate = join(dir, 'docs');
    if (existsSync(candidate) && statSync(candidate).isDirectory()) {
      if (
        existsSync(join(candidate, 'GLOBAL-INSTALL.md')) ||
        existsSync(join(candidate, 'INSTALL.md'))
      ) {
        return resolve(candidate);
      }
    }
    const parent = dirname(dir);
    if (parent === dir) {
      break;
    }
    dir = parent;
  }
  return null;
}

function isSameResolvedPath(a: string, b: string): boolean {
  try {
    return realpathSync(resolve(a)) === realpathSync(resolve(b));
  } catch {
    return resolve(a) === resolve(b);
  }
}

function isRalphInstallProjectRoot(projectRoot: string): boolean {
  const installRoot = resolveRalphInstallRoot();
  if (!installRoot) {
    return false;
  }
  return isSameResolvedPath(installRoot, projectRoot);
}

function isRalphFrameworkDocumentationDir(dir: string): boolean {
  if (!existsSync(dir) || !statSync(dir).isDirectory()) {
    return false;
  }
  return (
    existsSync(join(dir, 'GLOBAL-INSTALL.md')) ||
    existsSync(join(dir, 'INSTALL.md'))
  );
}

function isRalphSourceRepositoryDocumentationDir(projectDocs: string): boolean {
  const fromWalk = ralphDocsFromRepositoryWalk();
  if (!fromWalk) {
    return false;
  }
  return isSameResolvedPath(fromWalk, projectDocs);
}

function resolveRalphFrameworkDocumentationDir(): string {
  const env = process.env['RALPH_DOCS_ROOT']?.trim();
  if (env) {
    return resolve(env);
  }

  const fromInstall = ralphDocsFromBundledInstall();
  if (fromInstall) {
    return fromInstall;
  }
  const fromWalk = ralphDocsFromRepositoryWalk();
  if (fromWalk) {
    return fromWalk;
  }

  const installRoot = resolveRalphInstallRoot();
  if (installRoot) {
    return join(installRoot, 'docs');
  }
  return join(homedir(), '.ralph', 'docs');
}

function hiddenProjectDocumentationDir(projectRoot: string): string {
  return join(projectRoot, '.ralph-workspace', '__ralph-hidden-docs__');
}

/**
 * Directory for the Docs explorer.
 * - Ralph install root (`RALPH_HOME` / `~/.ralph`): framework docs from the global install or repo.
 * - Other projects: only `<projectRoot>/docs` when it has project-specific content.
 *   Ralph framework docs copied at install (`.ralph/docs/` or mirrored `docs/`) are excluded here;
 *   use the dedicated "Ralph docs" workspace entry instead.
 * Override with `RALPH_DOCS_ROOT`.
 */
export function resolveRalphDocumentationDir(projectRoot: string): string {
  const env = process.env['RALPH_DOCS_ROOT']?.trim();
  if (env) {
    return resolve(env);
  }

  if (isRalphInstallProjectRoot(projectRoot)) {
    return resolveRalphFrameworkDocumentationDir();
  }

  const projectDocs = resolve(join(projectRoot, 'docs'));
  if (!directoryHasVisibleEntries(projectDocs)) {
    return hiddenProjectDocumentationDir(projectRoot);
  }

  if (
    isRalphFrameworkDocumentationDir(projectDocs) &&
    !isRalphSourceRepositoryDocumentationDir(projectDocs)
  ) {
    return hiddenProjectDocumentationDir(projectRoot);
  }

  return projectDocs;
}

export function getAllowedRoots(roots: DashboardRoots): Record<string, RootConfig> {
  return {
    logs: {
      label: 'Logs',
      basePath: join(roots.workspaceRoot, 'logs'),
      writable: false,
    },
    artifacts: {
      label: 'Artifacts',
      basePath: join(roots.workspaceRoot, 'artifacts'),
      writable: false,
    },
    sessions: {
      label: 'Sessions',
      basePath: join(roots.workspaceRoot, 'sessions'),
      writable: false,
    },
    'orchestration-plans': {
      label: 'Orchestration Plans',
      basePath: join(roots.workspaceRoot, 'orchestration-plans'),
      writable: false,
    },
    docs: {
      label: 'Docs',
      basePath: resolveRalphDocumentationDir(roots.projectRoot),
      writable: false,
    },
    plans: {
      label: 'Plans',
      basePath: roots.projectRoot,
      writable: false,
    },
  };
}

function normalizeRelPath(relPath: string): string[] {
  let stripped = relPath;
  if (stripped.startsWith('/') && !stripped.startsWith('//')) {
    throw new Error('invalid path');
  }
  while (stripped.startsWith('/')) {
    stripped = stripped.slice(1);
  }
  const segments = stripped.split('/').filter(Boolean);
  if (segments.some((seg) => seg === '..')) {
    throw new Error('invalid path');
  }
  if (
    segments.some(
      (seg) => isHiddenEntryName(seg) && seg !== '.ralph-workspace',
    )
  ) {
    throw new Error('invalid path');
  }
  return segments;
}

function assertContainedInRoot(rootDir: string, absolutePath: string): void {
  const resolvedRoot = existsSync(rootDir) ? realpathSync(rootDir) : resolve(rootDir);
  const resolvedTarget = resolve(absolutePath);
  const rel = relative(resolvedRoot, resolvedTarget);
  const normalized = rel.replace(/\\/g, '/');
  if (normalized === '..' || normalized.startsWith('../')) {
    throw new Error('path escape');
  }
}

export function resolveUnderRoot(rootConfig: RootConfig, relPath: string): string {
  const segments = normalizeRelPath(relPath);
  const base = resolve(rootConfig.basePath);
  const candidate = resolve(base, ...segments);
  const candidateToCheck = existsSync(candidate) ? realpathSync(candidate) : candidate;
  assertContainedInRoot(base, candidateToCheck);
  return candidate;
}

export function parentListingPath(relPath: string): string | null {
  const trimmed = relPath.replace(/\/$/, '');
  if (!trimmed) {
    return null;
  }
  const parts = trimmed.split('/').filter(Boolean);
  parts.pop();
  return parts.length ? parts.join('/') : null;
}

function findAncestorsWithEntry(startDir: string, entry: string): string[] {
  const paths: string[] = [];
  let dir = startDir;

  for (let i = 0; i < 64; i++) {
    if (hasEntry(dir, entry)) {
      paths.push(dir);
    }
    const parent = dirname(dir);
    if (parent === dir) {
      break;
    }
    dir = parent;
  }

  return paths;
}

function collectWorkspaceDirs(base: string, depth: number, collected: Set<string>): void {
  if (depth < 0) {
    return;
  }

  let entries: Dirent[];
  try {
    entries = readdirSync(base, { withFileTypes: true });
  } catch {
    return;
  }

  for (const entry of entries) {
    if (!entry.isDirectory()) {
      continue;
    }
    const candidate = join(base, entry.name);
    if (entry.name === '.ralph-workspace') {
      collected.add(candidate);
      continue;
    }
    if (isHiddenEntryName(entry.name)) {
      continue;
    }

    collectWorkspaceDirs(candidate, depth - 1, collected);
  }
}

function collectWorkspaceDirsUnderHome(base: string, depth: number, collected: Set<string>): void {
  if (depth < 0) {
    return;
  }

  let entries: Dirent[];
  try {
    entries = readdirSync(base, { withFileTypes: true });
  } catch {
    return;
  }

  for (const entry of entries) {
    if (!entry.isDirectory()) {
      continue;
    }
    const candidate = join(base, entry.name);
    if (entry.name === '.ralph-workspace') {
      collected.add(candidate);
      continue;
    }
    if (entry.name === '.git' || entry.name === 'node_modules') {
      continue;
    }

    collectWorkspaceDirsUnderHome(candidate, depth - 1, collected);
  }
}

async function collectWorkspaceDirsAsync(base: string, depth: number, collected: Set<string>): Promise<void> {
  if (depth < 0) return;

  let entries: Dirent[];
  try {
    entries = await fsPromises.readdir(base, { withFileTypes: true });
  } catch {
    return;
  }

  const subdirPromises: Promise<void>[] = [];
  for (const entry of entries) {
    if (!entry.isDirectory()) continue;
    const candidate = join(base, entry.name);
    if (entry.name === '.ralph-workspace') {
      collected.add(candidate);
      continue;
    }
    if (isHiddenEntryName(entry.name)) continue;
    subdirPromises.push(collectWorkspaceDirsAsync(candidate, depth - 1, collected));
  }
  if (subdirPromises.length > 0) await Promise.all(subdirPromises);
}

async function collectWorkspaceDirsUnderHomeAsync(base: string, depth: number, collected: Set<string>): Promise<void> {
  if (depth < 0) return;

  let entries: Dirent[];
  try {
    entries = await fsPromises.readdir(base, { withFileTypes: true });
  } catch {
    return;
  }

  const subdirPromises: Promise<void>[] = [];
  for (const entry of entries) {
    if (!entry.isDirectory()) continue;
    const candidate = join(base, entry.name);
    if (entry.name === '.ralph-workspace') {
      collected.add(candidate);
      continue;
    }
    if (entry.name === '.git' || entry.name === 'node_modules') continue;
    subdirPromises.push(collectWorkspaceDirsUnderHomeAsync(candidate, depth - 1, collected));
  }
  if (subdirPromises.length > 0) await Promise.all(subdirPromises);
}

const WORKSPACE_SEARCH_DEPTH = 2;

function hasExplicitWorkspaceRootEnv(): boolean {
  const dash = process.env['RALPH_DASHBOARD_WORKSPACE_ROOT']?.trim();
  const plan = process.env['RALPH_PLAN_WORKSPACE_ROOT']?.trim();
  return Boolean(dash || plan);
}

function dashboardFullMode(): boolean {
  return process.env['RALPH_DASHBOARD_FULL']?.trim() === '1';
}

export function dashboardGlobalMode(): boolean {
  return process.env['RALPH_DASHBOARD_GLOBAL']?.trim() === '1';
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

export function readRegistryWorkspacePaths(): string[] {
  const registryPath = workspacesRegistryPath();
  if (!registryPath) {
    return [];
  }
  let raw: string;
  try {
    raw = readFileSync(registryPath, 'utf8');
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
  const paths: string[] = [];
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
    const ralphWorkspace = join(workspacePath, '.ralph-workspace');
    if (existsSync(ralphWorkspace) && statSync(ralphWorkspace).isDirectory()) {
      paths.push(ralphWorkspace);
    }
  }
  return paths;
}

function explicitWorkspaceProjectBasesForNesting(): string[] {
  const bases = new Set<string>();
  const envRootKeys = ['RALPH_DASHBOARD_WORKSPACE_ROOT', 'RALPH_PLAN_WORKSPACE_ROOT'] as const;
  for (const key of envRootKeys) {
    const envRoot = process.env[key]?.trim();
    if (!envRoot) {
      continue;
    }
    const resolved = resolve(envRoot);
    if (basename(resolved) === '.ralph-workspace' && existsSync(resolved)) {
      bases.add(dirname(resolved));
      continue;
    }
    if (hasDotRalphWorkspace(resolved)) {
      bases.add(resolved);
    }
  }
  return Array.from(bases);
}

let workspaceRootsCache: { expiresAt: number; data: string[] } | null = null;

function workspaceRootsCacheTtlMs(): number {
  const raw = process.env['RALPH_DASHBOARD_WORKSPACE_ROOTS_TTL_MS']?.trim();
  if (!raw) return 30_000;
  const n = Number.parseInt(raw, 10);
  return Number.isFinite(n) && n >= 0 ? n : 30_000;
}

let workspaceRootsInflight: Promise<string[]> | null = null;

export function clearWorkspaceRootsCache(): void {
  workspaceRootsCache = null;
  workspaceRootsInflight = null;
}

export function findAllWorkspaceRoots(): string[] {
  const now = Date.now();
  if (workspaceRootsCache && now < workspaceRootsCache.expiresAt) {
    return workspaceRootsCache.data;
  }

  const { projectRoot, workspaceRoot } = findDashboardRoots();
  const results = new Set<string>();

  const addCandidate = (candidate: string | undefined): void => {
    if (!candidate) {
      return;
    }
    try {
      const resolved = resolve(candidate);
      if (!existsSync(resolved)) {
        return;
      }
      if (statSync(resolved).isDirectory()) {
        results.add(resolved);
      }
    } catch {
      // ignore invalid paths
    }
  };

  const envRootKeys = ['RALPH_DASHBOARD_WORKSPACE_ROOT', 'RALPH_PLAN_WORKSPACE_ROOT'] as const;
  for (const key of envRootKeys) {
    const envRoot = process.env[key];
    if (!envRoot) {
      continue;
    }
    const resolved = resolve(envRoot);
    if (basename(resolved) === '.ralph-workspace' && existsSync(resolved)) {
      addCandidate(resolved);
      continue;
    }
    if (hasDotRalphWorkspace(resolved)) {
      addCandidate(join(resolved, '.ralph-workspace'));
    }
  }

  if (dashboardGlobalMode()) {
    for (const registryPath of readRegistryWorkspacePaths()) {
      addCandidate(registryPath);
    }
    const envRootKeys2 = ['RALPH_DASHBOARD_WORKSPACE_ROOT', 'RALPH_PLAN_WORKSPACE_ROOT'] as const;
    for (const key of envRootKeys2) {
      const envRoot = process.env[key];
      if (!envRoot) {
        continue;
      }
      const resolved = resolve(envRoot);
      if (basename(resolved) === '.ralph-workspace' && existsSync(resolved)) {
        addCandidate(resolved);
        continue;
      }
      if (hasDotRalphWorkspace(resolved)) {
        addCandidate(join(resolved, '.ralph-workspace'));
      }
    }
    const home = process.env['HOME']?.trim();
    if (home) {
      collectWorkspaceDirsUnderHome(home, HOME_WORKSPACE_SEARCH_DEPTH, results);
    }
    addCandidate(workspaceRoot);
    const result = Array.from(results);
    workspaceRootsCache = { expiresAt: Date.now() + workspaceRootsCacheTtlMs(), data: result };
    return result;
  }

  if (hasExplicitWorkspaceRootEnv()) {
    const nestingBases = explicitWorkspaceProjectBasesForNesting();
    for (const base of nestingBases) {
      collectWorkspaceDirs(base, WORKSPACE_SEARCH_DEPTH, results);
    }
    if (nestingBases.length === 0) {
      collectWorkspaceDirs(projectRoot, WORKSPACE_SEARCH_DEPTH, results);
    }
  } else if (dashboardFullMode()) {
    const home = process.env['HOME']?.trim();
    for (const registryPath of readRegistryWorkspacePaths()) {
      addCandidate(registryPath);
    }
    if (home) {
      collectWorkspaceDirsUnderHome(home, HOME_WORKSPACE_SEARCH_DEPTH, results);
    }
    addCandidate(workspaceRoot);
  } else {
    addCandidate(workspaceRoot);
    for (const ancestor of findAncestorsWithEntry(process.cwd(), '.ralph-workspace')) {
      addCandidate(join(ancestor, '.ralph-workspace'));
    }

    for (const ancestor of findAncestorsWithEntry(dirname(fileURLToPath(import.meta.url)), '.ralph-workspace')) {
      addCandidate(join(ancestor, '.ralph-workspace'));
    }
    collectWorkspaceDirs(projectRoot, WORKSPACE_SEARCH_DEPTH, results);
  }

  const result = Array.from(results);
  workspaceRootsCache = { expiresAt: Date.now() + workspaceRootsCacheTtlMs(), data: result };
  return result;
}

async function findAllWorkspaceRootsAsync(): Promise<string[]> {
  const { projectRoot, workspaceRoot } = findDashboardRoots();
  const results = new Set<string>();

  const addCandidate = (candidate: string | undefined): void => {
    if (!candidate) return;
    try {
      const resolved = resolve(candidate);
      if (!existsSync(resolved)) return;
      if (statSync(resolved).isDirectory()) results.add(resolved);
    } catch {
      // ignore invalid paths
    }
  };

  const envRootKeys = ['RALPH_DASHBOARD_WORKSPACE_ROOT', 'RALPH_PLAN_WORKSPACE_ROOT'] as const;
  for (const key of envRootKeys) {
    const envRoot = process.env[key];
    if (!envRoot) continue;
    const resolved = resolve(envRoot);
    if (basename(resolved) === '.ralph-workspace' && existsSync(resolved)) {
      addCandidate(resolved);
      continue;
    }
    if (hasDotRalphWorkspace(resolved)) {
      addCandidate(join(resolved, '.ralph-workspace'));
    }
  }

  if (dashboardGlobalMode()) {
    for (const registryPath of readRegistryWorkspacePaths()) {
      addCandidate(registryPath);
    }
    const envRootKeys2 = ['RALPH_DASHBOARD_WORKSPACE_ROOT', 'RALPH_PLAN_WORKSPACE_ROOT'] as const;
    for (const key of envRootKeys2) {
      const envRoot = process.env[key];
      if (!envRoot) continue;
      const resolved = resolve(envRoot);
      if (basename(resolved) === '.ralph-workspace' && existsSync(resolved)) {
        addCandidate(resolved);
        continue;
      }
      if (hasDotRalphWorkspace(resolved)) {
        addCandidate(join(resolved, '.ralph-workspace'));
      }
    }
    const home = process.env['HOME']?.trim();
    if (home) {
      await collectWorkspaceDirsUnderHomeAsync(home, HOME_WORKSPACE_SEARCH_DEPTH, results);
    }
    addCandidate(workspaceRoot);
  } else if (hasExplicitWorkspaceRootEnv()) {
    const nestingBases = explicitWorkspaceProjectBasesForNesting();
    const bases = nestingBases.length > 0 ? nestingBases : [projectRoot];
    await Promise.all(bases.map((base) => collectWorkspaceDirsAsync(base, WORKSPACE_SEARCH_DEPTH, results)));
  } else if (dashboardFullMode()) {
    const home = process.env['HOME']?.trim();
    for (const registryPath of readRegistryWorkspacePaths()) {
      addCandidate(registryPath);
    }
    if (home) {
      await collectWorkspaceDirsUnderHomeAsync(home, HOME_WORKSPACE_SEARCH_DEPTH, results);
    }
    addCandidate(workspaceRoot);
  } else {
    addCandidate(workspaceRoot);
    for (const ancestor of findAncestorsWithEntry(process.cwd(), '.ralph-workspace')) {
      addCandidate(join(ancestor, '.ralph-workspace'));
    }
    for (const ancestor of findAncestorsWithEntry(dirname(fileURLToPath(import.meta.url)), '.ralph-workspace')) {
      addCandidate(join(ancestor, '.ralph-workspace'));
    }
    await collectWorkspaceDirsAsync(projectRoot, WORKSPACE_SEARCH_DEPTH, results);
  }

  const result = Array.from(results);
  workspaceRootsCache = { expiresAt: Date.now() + workspaceRootsCacheTtlMs(), data: result };
  return result;
}

export async function getCachedWorkspaceRoots(): Promise<string[]> {
  const now = Date.now();
  if (workspaceRootsCache && now < workspaceRootsCache.expiresAt) {
    return workspaceRootsCache.data;
  }
  if (!workspaceRootsInflight) {
    workspaceRootsInflight = findAllWorkspaceRootsAsync().finally(() => {
      workspaceRootsInflight = null;
    });
  }
  return workspaceRootsInflight;
}

export function findWorkspaceLogsRoots(): string[] {
  return findAllWorkspaceRoots()
    .map((workspace) => join(workspace, 'logs'))
    .filter((logsPath) => existsSync(logsPath) && statSync(logsPath).isDirectory());
}

export function findWorkspaceArtifactsRoots(): string[] {
  return findAllWorkspaceRoots()
    .map((workspace) => join(workspace, 'artifacts'))
    .filter((artifactsPath) => existsSync(artifactsPath) && statSync(artifactsPath).isDirectory());
}

export async function findWorkspaceLogsRootsAsync(): Promise<string[]> {
  const roots = await getCachedWorkspaceRoots();
  const checks = await Promise.all(
    roots.map(async (workspace) => {
      const logsPath = join(workspace, 'logs');
      try {
        const stat = await fsPromises.stat(logsPath);
        return stat.isDirectory() ? logsPath : null;
      } catch {
        return null;
      }
    }),
  );
  return checks.filter((p): p is string => p !== null);
}

export async function findWorkspaceArtifactsRootsAsync(): Promise<string[]> {
  const roots = await getCachedWorkspaceRoots();
  const checks = await Promise.all(
    roots.map(async (workspace) => {
      const artifactsPath = join(workspace, 'artifacts');
      try {
        const stat = await fsPromises.stat(artifactsPath);
        return stat.isDirectory() ? artifactsPath : null;
      } catch {
        return null;
      }
    }),
  );
  return checks.filter((p): p is string => p !== null);
}
