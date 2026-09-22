import { existsSync, realpathSync, statSync } from 'node:fs';
import { basename, relative, resolve } from 'node:path';

import { FILE_ROLE_LABELS } from './plan-run-detail';
import { resolveStatePath } from './state-paths';

export type PlanRunEvidenceCategory =
  | 'run-metadata'
  | 'usage-summary'
  | 'execution-output'
  | 'tool-telemetry'
  | 'overlay'
  | 'runtime-config'
  | 'other';

export type PlanRunEvidenceFormat = 'json' | 'jsonl' | 'log' | 'text' | 'markdown' | 'binary';

export interface PlanRunOpenTarget {
  root: string;
  path: string;
}

export interface PlanRunEvidenceEntry {
  id: string;
  path: string;
  label: string;
  category: PlanRunEvidenceCategory;
  kind: string;
  format: PlanRunEvidenceFormat;
  sizeBytes: number | null;
  mtimeMs: number | null;
  target: PlanRunOpenTarget;
}

export interface PlanRunFilesModel {
  evidence: PlanRunEvidenceEntry[];
  summary: Array<{ path: string; label: string }>;
  raw: string[];
}

const EXPLORER_ROOT_PREFIXES = [
  'logs/',
  'runs/',
  'runtime-config/',
  'internal/runtime-config/',
  'internal/sessions/',
  'sessions/',
  'cache/tool-results/',
  'tool-results/',
] as const;

export function normalizePlanRunStatePath(path: string): string {
  return path.replace(/\\/g, '/').replace(/^\/+/, '');
}

export function isSafePlanRunStatePath(path: string): boolean {
  const normalized = normalizePlanRunStatePath(path);
  if (!normalized || normalized.includes('..')) {
    return false;
  }
  const segments = normalized.split('/');
  if (segments.some((segment) => segment === 'processes')) {
    return false;
  }
  if (segments.some((segment) => segment.startsWith('.') && segment.length > 1)) {
    return false;
  }
  return true;
}

export function isPathUnderWorkspaceRoot(absPath: string, workspaceRoot: string): boolean {
  const rootResolved = resolve(workspaceRoot);
  const rootReal = existsSync(rootResolved) ? realpathSync(rootResolved) : rootResolved;
  const absResolved = resolve(absPath);
  let absNorm = absResolved;
  if (absResolved === rootResolved || absResolved.startsWith(`${rootResolved}/`)) {
    // join()/resolve() keep the pre-realpath root; map onto the physical root.
    absNorm = `${rootReal}${absResolved.slice(rootResolved.length)}`;
  } else if (existsSync(absResolved)) {
    try {
      absNorm = realpathSync(absResolved);
    } catch {
      // keep absResolved
    }
  }
  const rel = relative(rootReal, absNorm);
  return rel !== '' && !rel.startsWith('..') && !rel.split(/[/\\]/).includes('..');
}

export function planRunOpenTarget(stateRelativePath: string): PlanRunOpenTarget | null {
  const normalized = normalizePlanRunStatePath(stateRelativePath);
  if (!isSafePlanRunStatePath(normalized)) {
    return null;
  }
  if (normalized.startsWith('cache/tool-results/')) {
    return { root: 'tool-results', path: normalized.slice('cache/tool-results/'.length) };
  }
  if (normalized.startsWith('internal/sessions/')) {
    return { root: 'sessions', path: normalized.slice('internal/sessions/'.length) };
  }
  if (normalized.startsWith('internal/runtime-config/')) {
    return { root: 'runtime-config', path: normalized.slice('internal/runtime-config/'.length) };
  }
  for (const prefix of EXPLORER_ROOT_PREFIXES) {
    if (
      prefix === 'cache/tool-results/' ||
      prefix === 'internal/sessions/' ||
      prefix === 'internal/runtime-config/'
    ) {
      continue;
    }
    if (normalized.startsWith(prefix)) {
      return { root: prefix.slice(0, -1), path: normalized.slice(prefix.length) };
    }
  }
  return null;
}

function inferFormat(name: string): PlanRunEvidenceFormat {
  if (name.endsWith('.jsonl')) {
    return 'jsonl';
  }
  if (name.endsWith('.json')) {
    return 'json';
  }
  if (name.endsWith('.log') || name.endsWith('.ansi.log')) {
    return 'log';
  }
  if (name.endsWith('.md') || name.endsWith('.mdc')) {
    return 'markdown';
  }
  if (name.endsWith('.txt')) {
    return 'text';
  }
  return 'binary';
}

function executionOutputLabel(name: string): string {
  if (name === 'agent.log') {
    return 'Agent output log';
  }
  if (name.endsWith('-output.ansi.log')) {
    return 'CLI output (ANSI)';
  }
  if (name.endsWith('-output.log') || name.endsWith('output.log')) {
    return 'CLI output log';
  }
  if (name.startsWith('plan-runner-') && name.endsWith('.log')) {
    return 'Plan runner log';
  }
  if (name.endsWith('.log')) {
    return 'Log file';
  }
  return name;
}

export function classifyPlanRunEvidencePath(stateRelativePath: string): {
  label: string;
  category: PlanRunEvidenceCategory;
  kind: string;
  format: PlanRunEvidenceFormat;
} {
  const normalized = normalizePlanRunStatePath(stateRelativePath);
  const name = basename(normalized);
  const format = inferFormat(name);
  const roleLabel = FILE_ROLE_LABELS[name];
  if (roleLabel) {
    const category: PlanRunEvidenceCategory =
      name === 'run-manifest.json'
        ? 'run-metadata'
        : name === 'overlay-timeline.jsonl'
          ? 'overlay'
          : 'usage-summary';
    return { label: roleLabel, category, kind: name.replace(/\.[^.]+$/, ''), format };
  }
  if (normalized.startsWith('runtime-config/')) {
    return {
      label: name || 'Runtime config file',
      category: 'runtime-config',
      kind: 'runtime-config',
      format,
    };
  }
  if (normalized.startsWith('internal/runtime-config/')) {
    return {
      label: name || 'Runtime config file',
      category: 'runtime-config',
      kind: 'runtime-config',
      format,
    };
  }
  if (name === 'discover-report.json') {
    return { label: 'Discover report', category: 'usage-summary', kind: 'discover-report', format: 'json' };
  }
  if (name === 'tool-catalog-telemetry.jsonl') {
    return {
      label: 'Tool catalog telemetry',
      category: 'tool-telemetry',
      kind: 'tool-catalog-telemetry',
      format: 'jsonl',
    };
  }
  if (name.startsWith('iter-') && normalized.includes('/overlay/')) {
    return { label: 'Overlay iteration snapshot', category: 'overlay', kind: 'overlay-iter', format: 'json' };
  }
  if (name === 'index.jsonl' && normalized.includes('/runs/')) {
    return { label: 'Run index', category: 'run-metadata', kind: 'run-index', format: 'jsonl' };
  }
  if (name.endsWith('.log')) {
    return {
      label: executionOutputLabel(name),
      category: 'execution-output',
      kind: 'execution-log',
      format: 'log',
    };
  }
  if (name === 'post-verification-tracking.txt' || name === 'compression-audit-results.json') {
    return {
      label: name === 'post-verification-tracking.txt' ? 'Post-verification tracking' : 'Compression audit',
      category: 'usage-summary',
      kind: name.split('.')[0] ?? 'audit',
      format,
    };
  }
  return {
    label: name || 'Other file',
    category: 'other',
    kind: 'other',
    format,
  };
}

function absUnderStateRoot(workspaceRoot: string, stateRelativePath: string): string {
  return resolveStatePath(workspaceRoot, normalizePlanRunStatePath(stateRelativePath));
}

function statEvidenceFile(workspaceRoot: string, stateRelativePath: string): {
  sizeBytes: number | null;
  mtimeMs: number | null;
} {
  try {
    const stat = statSync(absUnderStateRoot(workspaceRoot, stateRelativePath));
    if (!stat.isFile()) {
      return { sizeBytes: null, mtimeMs: null };
    }
    return { sizeBytes: stat.size, mtimeMs: stat.mtimeMs };
  } catch {
    return { sizeBytes: null, mtimeMs: null };
  }
}

export function buildPlanRunEvidenceEntry(
  workspaceRoot: string,
  stateRelativePath: string,
): PlanRunEvidenceEntry | null {
  const path = normalizePlanRunStatePath(stateRelativePath);
  if (!isSafePlanRunStatePath(path)) {
    return null;
  }
  let abs: string;
  try {
    abs = absUnderStateRoot(workspaceRoot, path);
  } catch {
    return null;
  }
  if (!isPathUnderWorkspaceRoot(abs, workspaceRoot)) {
    return null;
  }
  const target = planRunOpenTarget(path);
  if (!target) {
    return null;
  }
  const meta = classifyPlanRunEvidencePath(path);
  const { sizeBytes, mtimeMs } = statEvidenceFile(workspaceRoot, path);
  return {
    id: path,
    path,
    label: meta.label,
    category: meta.category,
    kind: meta.kind,
    format: meta.format,
    sizeBytes,
    mtimeMs,
    target,
  };
}

export function buildPlanRunFilesModel(workspaceRoot: string, paths: string[]): PlanRunFilesModel {
  const evidence: PlanRunEvidenceEntry[] = [];
  const seen = new Set<string>();
  for (const candidate of paths) {
    const entry = buildPlanRunEvidenceEntry(workspaceRoot, candidate);
    if (!entry || seen.has(entry.path)) {
      continue;
    }
    seen.add(entry.path);
    evidence.push(entry);
  }
  evidence.sort((a, b) => a.path.localeCompare(b.path));

  const summary: Array<{ path: string; label: string }> = [];
  const raw: string[] = [];
  for (const entry of evidence) {
    const name = basename(entry.path);
    if (FILE_ROLE_LABELS[name]) {
      summary.push({ path: entry.path, label: entry.label });
    } else {
      raw.push(entry.path);
    }
  }
  return { evidence, summary, raw };
}

export function filterSafePlanRunStatePaths(workspaceRoot: string, paths: Iterable<string>): string[] {
  const out: string[] = [];
  const seen = new Set<string>();
  for (const candidate of paths) {
    const normalized = normalizePlanRunStatePath(candidate);
    if (!isSafePlanRunStatePath(normalized)) {
      continue;
    }
    let abs: string;
    try {
      abs = absUnderStateRoot(workspaceRoot, normalized);
    } catch {
      continue;
    }
    if (!isPathUnderWorkspaceRoot(abs, workspaceRoot)) {
      continue;
    }
    if (seen.has(normalized)) {
      continue;
    }
    seen.add(normalized);
    out.push(normalized);
  }
  return out.sort((a, b) => a.localeCompare(b));
}
