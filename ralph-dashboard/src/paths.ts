import { basename, dirname, join, relative, resolve } from 'node:path';
import { Dirent, existsSync, readdirSync, realpathSync, statSync } from 'node:fs';
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

export function findDashboardRoots(): DashboardRoots {
  const projectRoot = determineProjectRoot();
  const workspaceRoot = determineWorkspaceRoot(projectRoot);
  return { projectRoot, workspaceRoot };
}

export function findWorkspaceProjectRoot(): string {
  return findDashboardRoots().projectRoot;
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
      basePath: join(roots.projectRoot, 'docs'),
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
  if (segments.some((seg) => isHiddenEntryName(seg))) {
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

const WORKSPACE_SEARCH_DEPTH = 2;

function hasExplicitWorkspaceRootEnv(): boolean {
  const dash = process.env['RALPH_DASHBOARD_WORKSPACE_ROOT']?.trim();
  const plan = process.env['RALPH_PLAN_WORKSPACE_ROOT']?.trim();
  return Boolean(dash || plan);
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

export function findAllWorkspaceRoots(): string[] {
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

  addCandidate(workspaceRoot);

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

  if (!hasExplicitWorkspaceRootEnv()) {
    for (const ancestor of findAncestorsWithEntry(process.cwd(), '.ralph-workspace')) {
      addCandidate(join(ancestor, '.ralph-workspace'));
    }

    for (const ancestor of findAncestorsWithEntry(dirname(fileURLToPath(import.meta.url)), '.ralph-workspace')) {
      addCandidate(join(ancestor, '.ralph-workspace'));
    }
  }

  if (hasExplicitWorkspaceRootEnv()) {
    const nestingBases = explicitWorkspaceProjectBasesForNesting();
    for (const base of nestingBases) {
      collectWorkspaceDirs(base, WORKSPACE_SEARCH_DEPTH, results);
    }
    if (nestingBases.length === 0) {
      collectWorkspaceDirs(projectRoot, WORKSPACE_SEARCH_DEPTH, results);
    }
  } else {
    collectWorkspaceDirs(projectRoot, WORKSPACE_SEARCH_DEPTH, results);
  }

  return Array.from(results);
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
