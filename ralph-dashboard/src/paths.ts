import { dirname, join, relative, resolve } from 'node:path';
import { existsSync, realpathSync } from 'node:fs';
import { fileURLToPath } from 'node:url';

export interface RootConfig {
  label: string;
  basePath: string;
  writable: boolean;
}

export function findWorkspaceProjectRoot(): string {
  const fromEnv = process.env['RALPH_PLAN_WORKSPACE_ROOT'] ?? process.env['RALPH_DASHBOARD_WORKSPACE_ROOT'];
  if (fromEnv) {
    return resolve(fromEnv);
  }

  const fromCwd = walkUpForDotRalphWorkspace(process.cwd());
  if (fromCwd) {
    return fromCwd;
  }

  const here = dirname(fileURLToPath(import.meta.url));
  const fromModule = walkUpForDotRalphWorkspace(here);
  if (fromModule) {
    return fromModule;
  }

  return process.cwd();
}

function walkUpForDotRalphWorkspace(startDir: string): string | null {
  let dir = startDir;
  let found: string | null = null;
  for (let i = 0; i < 64; i++) {
    if (existsSync(join(dir, '.ralph-workspace'))) {
      found = dir;
    }
    const parent = dirname(dir);
    if (parent === dir) {
      break;
    }
    dir = parent;
  }
  return found;
}

export function getAllowedRoots(workspaceRoot: string): Record<string, RootConfig> {
  return {
    logs: {
      label: 'Logs',
      basePath: join(workspaceRoot, '.ralph-workspace', 'logs'),
      writable: false,
    },
    artifacts: {
      label: 'Artifacts',
      basePath: join(workspaceRoot, '.ralph-workspace', 'artifacts'),
      writable: false,
    },
    sessions: {
      label: 'Sessions',
      basePath: join(workspaceRoot, '.ralph-workspace', 'sessions'),
      writable: false,
    },
    'orchestration-plans': {
      label: 'Orchestration Plans',
      basePath: join(workspaceRoot, '.ralph-workspace', 'orchestration-plans'),
      writable: false,
    },
    docs: {
      label: 'Docs',
      basePath: join(workspaceRoot, 'docs'),
      writable: false,
    },
    plans: {
      label: 'Plans',
      basePath: join(workspaceRoot, '.ralph-workspace', 'logs'),
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
  assertContainedInRoot(base, candidate);
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
