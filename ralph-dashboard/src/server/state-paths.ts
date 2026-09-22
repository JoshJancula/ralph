import { existsSync, lstatSync, readdirSync, readFileSync, realpathSync } from 'node:fs';
import { join, resolve, relative } from 'node:path';

export type StateLayoutVersion = 1 | 2;

function invalid(message: string): never { throw new Error(`Invalid state path: ${message}`); }
function safeSegment(value: string, label: string): string {
  if (!value || value.includes('/') || value.includes('\\') || value === '.' || value === '..' || value.includes('..')) invalid(`${label} is unsafe`);
  return value;
}

/** Resolve a read target without permitting traversal or a symlink escape. */
export function resolveStatePath(stateRoot: string, stateRelativePath: string): string {
  if (!stateRelativePath || stateRelativePath.startsWith('/') || stateRelativePath.split(/[\\/]/).some((part) => part === '..')) invalid(stateRelativePath);
  const root = resolve(stateRoot);
  const rootReal = existsSync(root) ? realpathSync(root) : root;
  let current = rootReal;
  for (const part of stateRelativePath.split('/').filter(Boolean)) {
    if (part === '.') continue;
    const next = join(current, part);
    if (existsSync(next) && lstatSync(next).isSymbolicLink()) {
      const actual = realpathSync(next);
      if (actual !== rootReal && !actual.startsWith(`${rootReal}/`)) invalid(`${stateRelativePath} escapes root`);
      current = actual;
    } else current = next;
  }
  const rel = relative(rootReal, current);
  if (rel === '..' || rel.split(/[\\/]/).includes('..')) invalid(`${stateRelativePath} escapes root`);
  // Containment is proved on physical paths above; return the path under the
  // caller's own root spelling, matching bash ralph_state_path_resolve.
  return join(root, stateRelativePath);
}

export type StateEngineKind = 'workflow' | 'graph' | 'sequential' | 'delegation';

/** The layout a run admitted right now would be recorded with. */
export function layoutForNewRun(envLayout = process.env['RALPH_STATE_LAYOUT']): StateLayoutVersion {
  if (envLayout === undefined || envLayout === '' || envLayout === '2') return 2;
  if (envLayout === '1') return 1;
  throw new Error(`Invalid RALPH_STATE_LAYOUT: ${envLayout}`);
}

/** The layout recorded in a run catalog, ignoring the environment entirely. */
export function runLayout(stateRoot: string, runId: string): StateLayoutVersion {
  const catalog = resolveStatePath(stateRoot, `runs/${safeSegment(runId, 'run id')}/run.json`);
  if (!existsSync(catalog)) return 1;
  try { return JSON.parse(readFileSync(catalog, 'utf8')).layoutVersion === 2 ? 2 : 1; } catch { return 1; }
}

/** The on-disk catalog wins over a current process default during resume. */
export function stateLayoutVersion(stateRoot: string, runId?: string, envLayout = process.env['RALPH_STATE_LAYOUT']): StateLayoutVersion {
  if (!runId) return layoutForNewRun(envLayout);
  return runLayout(stateRoot, runId);
}

/** Catalog first, then an existing layout-1 artifact, then the new-run default. */
function effectiveLayout(stateRoot: string, runId: string, legacyRelative: string, envLayout?: string): StateLayoutVersion {
  if (runLayout(stateRoot, runId) === 2) return 2;
  if (existsSync(resolveStatePath(stateRoot, legacyRelative))) return 1;
  return layoutForNewRun(envLayout);
}

export function runPath(stateRoot: string, runId: string): string {
  return resolveStatePath(stateRoot, `runs/${safeSegment(runId, 'run id')}`);
}
export function attemptPath(stateRoot: string, runId: string, stageId = 'plan', attemptId?: string): string {
  const attempt = safeSegment(attemptId ?? runId, 'attempt id');
  return resolveStatePath(stateRoot, `runs/${safeSegment(runId, 'run id')}/stages/${safeSegment(stageId, 'stage id')}/attempts/${attempt}`);
}
export function enginePath(stateRoot: string, runId: string, kind: StateEngineKind): string {
  return resolveStatePath(stateRoot, `runs/${safeSegment(runId, 'run id')}/engine/${safeSegment(kind, 'engine kind')}`);
}
export function workflowRunPath(stateRoot: string, runId: string, envLayout?: string): string {
  return effectiveLayout(stateRoot, runId, `workflow-runs/${safeSegment(runId, 'run id')}/run.json`, envLayout) === 2
    ? enginePath(stateRoot, runId, 'workflow')
    : resolveStatePath(stateRoot, `workflow-runs/${safeSegment(runId, 'run id')}`);
}
export function graphRunPath(stateRoot: string, namespace: string, runId: string, envLayout?: string): string {
  const legacy = `graph-runs/${safeSegment(namespace, 'namespace')}/${safeSegment(runId, 'run id')}`;
  return effectiveLayout(stateRoot, runId, `${legacy}/run.json`, envLayout) === 2
    ? enginePath(stateRoot, runId, 'graph')
    : resolveStatePath(stateRoot, legacy);
}
export function sequentialRunPath(stateRoot: string, runId: string, legacyDir: string, envLayout?: string): string {
  return effectiveLayout(stateRoot, runId, `workflow-runs/${safeSegment(runId, 'run id')}/run.json`, envLayout) === 2
    ? enginePath(stateRoot, runId, 'sequential')
    : legacyDir;
}
/** Parent-run layout selects delegated-runs/ (v1) or runs/<parent>/engine/delegation (v2). */
export function delegationRootPath(stateRoot: string, parentRunId: string, envLayout?: string): string {
  const id = safeSegment(parentRunId, 'run id');
  if (runLayout(stateRoot, id) === 2) return enginePath(stateRoot, id, 'delegation');
  const root = resolve(stateRoot);
  if (existsSync(root)) {
    try {
      const graphRuns = resolveStatePath(stateRoot, 'graph-runs');
      if (existsSync(graphRuns)) {
        for (const ns of readdirSync(graphRuns, { withFileTypes: true })) {
          if (!ns.isDirectory()) continue;
          if (existsSync(join(graphRuns, ns.name, id))) {
            return resolveStatePath(stateRoot, 'delegated-runs');
          }
        }
      }
    } catch {
      // fall through to new-run default
    }
  }
  return layoutForNewRun(envLayout) === 2
    ? enginePath(stateRoot, id, 'delegation')
    : resolveStatePath(stateRoot, 'delegated-runs');
}
export function delegationRunPath(stateRoot: string, parentRunId: string, delegatedRunId: string, envLayout?: string): string {
  return join(delegationRootPath(stateRoot, parentRunId, envLayout), safeSegment(delegatedRunId, 'delegated run id'));
}
export function planAttemptPath(stateRoot: string, planKey: string, runId: string, stageId = 'plan', attemptId?: string, envLayout?: string): string {
  const legacy = `logs/${planKey}/runs/${safeSegment(runId, 'run id')}`;
  return effectiveLayout(stateRoot, runId, legacy, envLayout) === 2
    ? attemptPath(stateRoot, runId, stageId, attemptId)
    : resolveStatePath(stateRoot, legacy);
}
export function stateSharedPath(stateRoot: string, category: string, envLayout?: string): string {
  safeSegment(category, 'category');
  const internal = new Set(['sessions', 'runtime-config', 'processes', 'memory', 'command-profiles', 'setup-journal']);
  const cache = new Set(['tool-results', 'repo-map', 'search-context', 'metrics']);
  const layout = layoutForNewRun(envLayout);
  return resolveStatePath(stateRoot, layout === 2 && internal.has(category) ? `internal/${category}` : layout === 2 && cache.has(category) ? `cache/${category}` : category);
}

/** Parent of per-plan session dirs; sticky to layout-1 when that plan already has sessions there. */
export function sessionsHomePath(stateRoot: string, planKey?: string, envLayout?: string): string {
  const shared = stateSharedPath(stateRoot, 'sessions', envLayout);
  if (!planKey) return shared;
  const key = safeSegment(planKey, 'plan key');
  const legacy = resolveStatePath(stateRoot, 'sessions');
  if (legacy !== shared && existsSync(join(legacy, key)) && !existsSync(join(shared, key))) return legacy;
  return shared;
}

export function sessionsDirPath(stateRoot: string, planKey: string, envLayout?: string): string {
  return join(sessionsHomePath(stateRoot, planKey, envLayout), safeSegment(planKey, 'plan key'));
}

/** Per-plan overlay journal home; sticky to layout-1 when that plan already has journals there. */
export function runtimeConfigDirPath(stateRoot: string, planKey: string, envLayout?: string): string {
  const key = safeSegment(planKey, 'plan key');
  const shared = stateSharedPath(stateRoot, 'runtime-config', envLayout);
  const legacy = resolveStatePath(stateRoot, 'runtime-config');
  if (legacy !== shared && existsSync(join(legacy, key)) && !existsSync(join(shared, key))) {
    return join(legacy, key);
  }
  return join(shared, key);
}

/** hooks-config.jsonl under the runtime-config shared root, with layout-1 top-level fallback. */
export function hooksConfigPath(stateRoot: string, envLayout?: string): string {
  const shared = join(stateSharedPath(stateRoot, 'runtime-config', envLayout), 'hooks-config.jsonl');
  const legacy = resolveStatePath(stateRoot, 'hooks-config.jsonl');
  if (!existsSync(shared) && existsSync(legacy)) return legacy;
  return shared;
}
