/**
 * Catalog-first run listing and operator navigation summaries.
 *
 * Layout 2: shallow-read runs/<id>/run.json only — never recurse into
 * engine/workspaces, base/, or candidate trees to discover runs.
 * Layout 1: legacy readers under logs/, workflow-runs/, graph-runs/.
 */
import { existsSync, readdirSync, readFileSync, statSync } from 'node:fs';
import { basename, join, relative } from 'node:path';

import { resolveStatePath, runLayout, runPath } from './state-paths';

export type RunCatalogKind = 'plan' | 'workflow' | 'graph';

export interface RunCatalogParent {
  runId: string;
  stageId: string | null;
}

export interface RunCatalogStage {
  stageId: string;
  latestAttemptId: string | null;
  status: string;
}

export interface RunCatalogEntry {
  runId: string;
  runKind: RunCatalogKind;
  layoutVersion: 1 | 2;
  status: string;
  task: string | null;
  artifactNamespace: string | null;
  parent: RunCatalogParent | null;
  stages: RunCatalogStage[];
  createdAt: string | null;
  updatedAt: string | null;
  endedAt: string | null;
  catalogPath: string | null;
}

export interface FailedCheckNav {
  id: string;
  path: string;
  command: string;
  output: string;
  relatedArtifact: string | null;
}

export interface RunNavigationSummary {
  runId: string;
  task: string | null;
  status: string;
  currentWork: { stageId: string; attemptId: string | null; status: string } | null;
  results: Array<{ label: string; path: string }>;
  decisions: Array<{ label: string; path: string }>;
  verification: Array<{ label: string; path: string }>;
  failedChecks: FailedCheckNav[];
}

export interface GroupedRunListItem extends RunCatalogEntry {
  children: RunCatalogEntry[];
}

function readJsonRecord(path: string): Record<string, unknown> | null {
  try {
    const raw = JSON.parse(readFileSync(path, 'utf8')) as unknown;
    return raw && typeof raw === 'object' && !Array.isArray(raw) ? (raw as Record<string, unknown>) : null;
  } catch {
    return null;
  }
}

function asString(value: unknown): string | null {
  return typeof value === 'string' && value.trim() ? value : null;
}

function parseParent(raw: unknown): RunCatalogParent | null {
  if (!raw || typeof raw !== 'object' || Array.isArray(raw)) {
    return null;
  }
  const rec = raw as Record<string, unknown>;
  const runId = asString(rec['runId']) ?? asString(rec['workflow_run_id']) ?? asString(rec['graph_run_id']);
  if (!runId) {
    return null;
  }
  return {
    runId,
    stageId: asString(rec['stageId']) ?? asString(rec['stage_id']),
  };
}

function parseStages(raw: unknown): RunCatalogStage[] {
  if (!Array.isArray(raw)) {
    return [];
  }
  const out: RunCatalogStage[] = [];
  for (const entry of raw) {
    if (!entry || typeof entry !== 'object' || Array.isArray(entry)) {
      continue;
    }
    const rec = entry as Record<string, unknown>;
    const stageId = asString(rec['stageId']) ?? asString(rec['id']);
    if (!stageId) {
      continue;
    }
    out.push({
      stageId,
      latestAttemptId: asString(rec['latestAttemptId']) ?? asString(rec['attemptId']),
      status: asString(rec['status']) ?? 'unknown',
    });
  }
  return out;
}

function parseCatalogFile(catalogPath: string, runId: string): RunCatalogEntry | null {
  const raw = readJsonRecord(catalogPath);
  if (!raw) {
    return null;
  }
  if (raw['layoutVersion'] !== 2 && raw['kind'] !== 'ralph_run_catalog') {
    return null;
  }
  const runKindRaw = asString(raw['runKind']) ?? 'plan';
  const runKind: RunCatalogKind =
    runKindRaw === 'workflow' || runKindRaw === 'graph' || runKindRaw === 'plan' ? runKindRaw : 'plan';
  return {
    runId: asString(raw['runId']) ?? runId,
    runKind,
    layoutVersion: 2,
    status: asString(raw['status']) ?? 'unknown',
    task: asString(raw['task']),
    artifactNamespace: asString(raw['artifactNamespace']),
    parent: parseParent(raw['parent']),
    stages: parseStages(raw['stages']),
    createdAt: asString(raw['createdAt']),
    updatedAt: asString(raw['updatedAt']),
    endedAt: asString(raw['endedAt']),
    catalogPath: catalogPath,
  };
}

/** Shallow list of layout-2 catalog entries under runs/. Does not walk engine trees. */
export function listCatalogRuns(stateRoot: string): RunCatalogEntry[] {
  let runsRoot: string;
  try {
    runsRoot = resolveStatePath(stateRoot, 'runs');
  } catch {
    return [];
  }
  if (!existsSync(runsRoot)) {
    return [];
  }
  let entries: string[] = [];
  try {
    entries = readdirSync(runsRoot, { withFileTypes: true })
      .filter((ent) => ent.isDirectory() && !ent.name.startsWith('.'))
      .map((ent) => ent.name);
  } catch {
    return [];
  }
  const found: RunCatalogEntry[] = [];
  for (const runId of entries) {
    let catalogPath: string;
    try {
      catalogPath = resolveStatePath(stateRoot, `runs/${runId}/run.json`);
    } catch {
      continue;
    }
    if (!existsSync(catalogPath)) {
      continue;
    }
    const parsed = parseCatalogFile(catalogPath, runId);
    if (parsed) {
      found.push(parsed);
    }
  }
  return found;
}

/** Legacy layout-1 workflow + graph run ids (no recursion into workspaces). */
export function listLegacyOuterRuns(stateRoot: string): RunCatalogEntry[] {
  const found: RunCatalogEntry[] = [];

  const workflowRoot = join(stateRoot, 'workflow-runs');
  if (existsSync(workflowRoot)) {
    try {
      for (const ent of readdirSync(workflowRoot, { withFileTypes: true })) {
        if (!ent.isDirectory() || ent.name.startsWith('.')) {
          continue;
        }
        const ledger = join(workflowRoot, ent.name, 'run.json');
        if (!existsSync(ledger)) {
          continue;
        }
        const raw = readJsonRecord(ledger) ?? {};
        found.push({
          runId: ent.name,
          runKind: 'workflow',
          layoutVersion: 1,
          status: asString(raw['state']) ?? asString(raw['status']) ?? 'unknown',
          task: asString(raw['task']),
          artifactNamespace: asString(raw['artifactNamespace']),
          parent: null,
          stages: [],
          createdAt: asString(raw['createdAt']),
          updatedAt: asString(raw['updatedAt']),
          endedAt: asString(raw['endedAt']),
          catalogPath: ledger,
        });
      }
    } catch {
      // ignore
    }
  }

  const graphRoot = join(stateRoot, 'graph-runs');
  if (existsSync(graphRoot)) {
    try {
      for (const nsEnt of readdirSync(graphRoot, { withFileTypes: true })) {
        if (!nsEnt.isDirectory() || nsEnt.name === 'latest' || nsEnt.name.startsWith('.')) {
          continue;
        }
        const nsDir = join(graphRoot, nsEnt.name);
        for (const runEnt of readdirSync(nsDir, { withFileTypes: true })) {
          if (!runEnt.isDirectory() || runEnt.name === 'latest' || runEnt.name.startsWith('.')) {
            continue;
          }
          const ledger = join(nsDir, runEnt.name, 'run.json');
          if (!existsSync(ledger)) {
            continue;
          }
          const raw = readJsonRecord(ledger) ?? {};
          found.push({
            runId: runEnt.name,
            runKind: 'graph',
            layoutVersion: 1,
            status: asString(raw['status']) ?? 'unknown',
            task: null,
            artifactNamespace: nsEnt.name,
            parent: null,
            stages: [],
            createdAt: asString(raw['startedAt']),
            updatedAt: null,
            endedAt: null,
            catalogPath: ledger,
          });
        }
      }
    } catch {
      // ignore
    }
  }

  return found;
}

/**
 * Combined catalog + legacy outer runs. Child catalogs (parent != null) stay in
 * the flat list; use groupRunsByParent to nest them for UI cards.
 */
export function listNavigableRuns(stateRoot: string): RunCatalogEntry[] {
  const catalog = listCatalogRuns(stateRoot);
  const seen = new Set(catalog.map((r) => r.runId));
  const legacy = listLegacyOuterRuns(stateRoot).filter((r) => !seen.has(r.runId));
  return [...catalog, ...legacy];
}

/** Nest child catalogs under their parent; orphans stay as top-level cards. */
export function groupRunsByParent(runs: readonly RunCatalogEntry[]): GroupedRunListItem[] {
  const byId = new Map(runs.map((r) => [r.runId, r]));
  const childrenByParent = new Map<string, RunCatalogEntry[]>();
  const topLevel: RunCatalogEntry[] = [];

  for (const run of runs) {
    const parentId = run.parent?.runId;
    if (parentId && byId.has(parentId) && parentId !== run.runId) {
      const list = childrenByParent.get(parentId) ?? [];
      list.push(run);
      childrenByParent.set(parentId, list);
    } else {
      topLevel.push(run);
    }
  }

  return topLevel.map((run) => ({
    ...run,
    children: childrenByParent.get(run.runId) ?? [],
  }));
}

function stateRelative(stateRoot: string, abs: string): string {
  return relative(stateRoot, abs).replace(/\\/g, '/');
}

function listDirFiles(dir: string): string[] {
  if (!existsSync(dir)) {
    return [];
  }
  try {
    return readdirSync(dir)
      .filter((name) => !name.startsWith('.'))
      .map((name) => join(dir, name))
      .filter((abs) => {
        try {
          return statSync(abs).isFile() || statSync(abs).isSymbolicLink();
        } catch {
          return false;
        }
      });
  } catch {
    return [];
  }
}

function parseFailedCheckFile(absPath: string, stateRoot: string): FailedCheckNav | null {
  const name = basename(absPath);
  const rel = stateRelative(stateRoot, absPath);
  if (name.endsWith('.json')) {
    const raw = readJsonRecord(absPath);
    if (!raw) {
      return null;
    }
    const command = asString(raw['command']) ?? '';
    const output =
      asString(raw['output']) ??
      asString(raw['summary']) ??
      asString(raw['stderr']) ??
      '';
    if (!command && !output) {
      return null;
    }
    return {
      id: rel,
      path: rel,
      command: command || '(command not recorded)',
      output: output || '(no output recorded)',
      relatedArtifact:
        asString(raw['relatedArtifact']) ??
        asString(raw['artifact']) ??
        asString(raw['related_artifact']),
    };
  }
  try {
    const text = readFileSync(absPath, 'utf8');
    const commandMatch = text.match(/^command:\s*(.+)$/im);
    const command = commandMatch?.[1]?.trim() ?? '';
    return {
      id: rel,
      path: rel,
      command: command || `(from ${name})`,
      output: text.slice(0, 4000),
      relatedArtifact: null,
    };
  } catch {
    return null;
  }
}

function collectFailedChecks(stateRoot: string, runId: string, stages: RunCatalogStage[]): FailedCheckNav[] {
  const checks: FailedCheckNav[] = [];
  const seen = new Set<string>();
  const attemptDirs: string[] = [];

  if (runLayout(stateRoot, runId) === 2) {
    for (const stage of stages) {
      const attemptId = stage.latestAttemptId ?? runId;
      try {
        attemptDirs.push(
          resolveStatePath(stateRoot, `runs/${runId}/stages/${stage.stageId}/attempts/${attemptId}`),
        );
      } catch {
        // skip
      }
    }
    if (attemptDirs.length === 0) {
      try {
        attemptDirs.push(resolveStatePath(stateRoot, `runs/${runId}/stages/plan/attempts/${runId}`));
      } catch {
        // skip
      }
    }
  } else {
    // Layout 1: only the run's own attempt dir via known legacy homes — no tree walk.
    try {
      const root = resolveStatePath(stateRoot, 'logs');
      if (existsSync(root)) {
        for (const planKey of readdirSync(root, { withFileTypes: true })) {
          if (!planKey.isDirectory()) {
            continue;
          }
          const attempt = join(root, planKey.name, 'runs', runId);
          if (existsSync(attempt)) {
            attemptDirs.push(attempt);
          }
        }
      }
    } catch {
      // skip
    }
  }

  for (const attemptDir of attemptDirs) {
    const candidates = [
      ...listDirFiles(attemptDir).filter((p) => {
        const base = basename(p);
        return base.startsWith('verify-') || base.startsWith('failed-check');
      }),
      ...listDirFiles(join(attemptDir, 'manual-verification')),
    ];
    for (const abs of candidates) {
      const parsed = parseFailedCheckFile(abs, stateRoot);
      if (!parsed || seen.has(parsed.id)) {
        continue;
      }
      seen.add(parsed.id);
      checks.push(parsed);
    }
  }
  return checks;
}

/** Operator navigation summary: task/status/current work/results/decisions/verification/failed checks. */
export function buildRunNavigationSummary(stateRoot: string, runId: string): RunNavigationSummary | null {
  let entry: RunCatalogEntry | null = null;
  if (runLayout(stateRoot, runId) === 2) {
    try {
      const catalogPath = resolveStatePath(stateRoot, `runs/${runId}/run.json`);
      entry = parseCatalogFile(catalogPath, runId);
    } catch {
      entry = null;
    }
  }
  if (!entry) {
    entry = listLegacyOuterRuns(stateRoot).find((r) => r.runId === runId) ?? null;
  }
  if (!entry) {
    return null;
  }

  const results: Array<{ label: string; path: string }> = [];
  const decisions: Array<{ label: string; path: string }> = [];
  const verification: Array<{ label: string; path: string }> = [];

  if (entry.artifactNamespace) {
    const artifactsRel = `artifacts/${entry.artifactNamespace}`;
    try {
      const artifactsAbs = resolveStatePath(stateRoot, artifactsRel);
      if (existsSync(artifactsAbs)) {
        results.push({ label: 'Artifacts', path: artifactsRel });
        for (const file of listDirFiles(artifactsAbs)) {
          const base = basename(file);
          if (/verdict/i.test(base)) {
            verification.push({ label: base, path: stateRelative(stateRoot, file) });
          }
        }
        const verifyDir = join(artifactsAbs, 'verification');
        for (const file of listDirFiles(verifyDir)) {
          verification.push({ label: basename(file), path: stateRelative(stateRoot, file) });
        }
      }
    } catch {
      // missing artifacts stay absent rather than inventing paths
    }
  }

  if (entry.layoutVersion === 2) {
    try {
      const decisionsDir = resolveStatePath(stateRoot, `runs/${runId}/engine/workflow/actions/decisions`);
      for (const file of listDirFiles(decisionsDir)) {
        decisions.push({ label: basename(file), path: stateRelative(stateRoot, file) });
      }
    } catch {
      // no decisions
    }
  } else {
    const decisionsDir = join(stateRoot, 'workflow-runs', runId, 'actions', 'decisions');
    for (const file of listDirFiles(decisionsDir)) {
      decisions.push({ label: basename(file), path: stateRelative(stateRoot, file) });
    }
  }

  const currentStage = entry.stages.find((s) => s.status === 'running' || s.status === 'failed') ?? entry.stages[0] ?? null;
  const failedChecks = collectFailedChecks(stateRoot, runId, entry.stages);

  return {
    runId: entry.runId,
    task: entry.task,
    status: entry.status,
    currentWork: currentStage
      ? {
          stageId: currentStage.stageId,
          attemptId: currentStage.latestAttemptId,
          status: currentStage.status,
        }
      : null,
    results,
    decisions,
    verification,
    failedChecks,
  };
}

/** True when a path sits under a candidate/workspace/base tree that listing must not scan. */
export function isCandidateWorkspaceTreePath(stateRelativePath: string): boolean {
  const normalized = stateRelativePath.replace(/\\/g, '/');
  return (
    /\/engine\/graph\/workspaces\//.test(normalized) ||
    /\/engine\/graph\/base\//.test(normalized) ||
    /\/workspaces\/candidate/.test(normalized)
  );
}

export function catalogRunDir(stateRoot: string, runId: string): string {
  return runPath(stateRoot, runId);
}
