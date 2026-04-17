import { dirname, join, relative, resolve } from 'node:path';
import { existsSync, realpathSync, statSync } from 'node:fs';
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
    if (hasDotRalphWorkspace(resolved)) {
      return resolved;
    }
  }

  const fromCwd = walkUpForEntry(process.cwd(), '.ralph-workspace');
  if (fromCwd) {
    return fromCwd;
  }

  const fromModule = walkUpForEntry(dirname(fileURLToPath(import.meta.url)), '.ralph-workspace');
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
