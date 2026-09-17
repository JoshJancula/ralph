/**
 * Catalog metadata derived from a resolved workflow definition.
 * Used by GET /api/workflows so the Angular catalog never re-parses YAML.
 */

import { parseWorkflowFrontmatter } from './workflow-frontmatter';
import type { WorkflowScope } from './ralph-cli';

export interface WorkflowCatalogMeta {
  readonly purpose: string;
  readonly expectedOutcome: string;
  readonly mode: string | null;
  readonly stageCount: number;
  readonly executableStageCount: number;
  readonly supervisorStageCount: number;
  readonly requiresSuppliedPlan: boolean;
  readonly writes: boolean;
  readonly hasHumanGates: boolean;
}

export interface WorkflowInheritRef {
  readonly scope: WorkflowScope;
  readonly explanation: string;
}

const HUMAN_GATE_TYPES = new Set(['approval', 'input']);

function frontmatterBlock(raw: string): string {
  if (!raw.startsWith('---')) {
    return '';
  }
  const end = raw.indexOf('\n---', 3);
  if (end < 0) {
    return raw.slice(3);
  }
  return raw.slice(3, end);
}

/** planInput.required: true means task-only start is refused. */
export function extractRequiresSuppliedPlan(frontmatter: string): boolean {
  const lines = frontmatter.split('\n');
  let inPlanInput = false;
  let planInputIndent = 0;
  for (const line of lines) {
    if (!inPlanInput) {
      if (/^planInput:\s*$/.test(line) || /^planInput:\s+\S/.test(line)) {
        inPlanInput = true;
        planInputIndent = 0;
        if (/required:\s*true\b/.test(line)) {
          return true;
        }
      }
      continue;
    }
    const indent = line.match(/^(\s*)/)?.[1]?.length ?? 0;
    if (line.trim().length === 0) {
      continue;
    }
    if (indent <= planInputIndent && !/^\s/.test(line) && !/^planInput:/.test(line)) {
      break;
    }
    if (planInputIndent === 0 && indent > 0) {
      planInputIndent = indent;
    }
    if (/^\s*required:\s*true\b/.test(line)) {
      return true;
    }
    if (/^\s*required:\s*false\b/.test(line)) {
      return false;
    }
  }
  return false;
}

function extractPublishMode(frontmatter: string): string | null {
  const match = frontmatter.match(/^\s*publishMode:\s*(\S+)\s*$/m);
  return match?.[1] ?? null;
}

function extractWrites(frontmatter: string): boolean {
  return /^\s*writeScopes:\s*/m.test(frontmatter);
}

function deriveExpectedOutcome(options: {
  readonly publishMode: string | null;
  readonly writes: boolean;
  readonly hasHumanGates: boolean;
  readonly requiresSuppliedPlan: boolean;
  readonly hasIntegrate: boolean;
}): string {
  if (options.publishMode === 'on-verified') {
    return 'Independently verified delivery';
  }
  if (options.publishMode === 'manual' || !options.writes) {
    return 'Read-only findings (no publication)';
  }
  if (options.hasIntegrate) {
    return 'Integrated changeset';
  }
  if (options.requiresSuppliedPlan) {
    return 'Executed supplied plan';
  }
  if (options.hasHumanGates) {
    return 'Human-gated delivery';
  }
  return 'Completed stage outputs';
}

export function deriveWorkflowCatalogMeta(raw: string, overviewFallback = ''): WorkflowCatalogMeta {
  const frontmatter = frontmatterBlock(raw);
  const parsed = parseWorkflowFrontmatter(raw);
  const stages = parsed.ok ? parsed.model.stages : [];
  const executableStageCount = stages.filter((stage) => stage.kind === 'ordinary').length;
  const supervisorStageCount = stages.filter((stage) => stage.kind === 'supervisor').length;
  const hasHumanGates = stages.some(
    (stage) => stage.kind === 'supervisor' && HUMAN_GATE_TYPES.has(stage.type),
  );
  const hasIntegrate = stages.some((stage) => stage.kind === 'supervisor' && stage.type === 'integrate');
  const writes = extractWrites(frontmatter);
  const requiresSuppliedPlan = extractRequiresSuppliedPlan(frontmatter);
  const publishMode = extractPublishMode(frontmatter);
  const purpose =
    (parsed.ok ? parsed.model.overview : undefined)?.trim() || overviewFallback.trim() || 'No overview';
  const mode = parsed.ok ? parsed.model.mode ?? null : null;

  return {
    purpose,
    expectedOutcome: deriveExpectedOutcome({
      publishMode,
      writes,
      hasHumanGates,
      requiresSuppliedPlan,
      hasIntegrate,
    }),
    mode,
    stageCount: stages.length,
    executableStageCount,
    supervisorStageCount,
    requiresSuppliedPlan,
    writes,
    hasHumanGates,
  };
}

export function emptyWorkflowCatalogMeta(overviewFallback = ''): WorkflowCatalogMeta {
  return {
    purpose: overviewFallback.trim() || 'No overview',
    expectedOutcome: 'Completed stage outputs',
    mode: null,
    stageCount: 0,
    executableStageCount: 0,
    supervisorStageCount: 0,
    requiresSuppliedPlan: false,
    writes: false,
    hasHumanGates: false,
  };
}

/**
 * Compact override relationship for project/global winners that shadow a lower
 * layer. Bundled definitions never inherit — they are the base and stay read-only.
 */
export function deriveInheritRef(
  effectiveScope: string,
  availableScopes: readonly { readonly scope: string }[],
): WorkflowInheritRef | null {
  if (effectiveScope === 'bundled') {
    return null;
  }
  const scopes = new Set(availableScopes.map((entry) => entry.scope));
  if (effectiveScope === 'project' && scopes.has('bundled')) {
    return {
      scope: 'bundled',
      explanation: 'Project override of the bundled definition. The bundled original stays read-only.',
    };
  }
  if (effectiveScope === 'project' && scopes.has('global')) {
    return {
      scope: 'global',
      explanation: 'Project override of the global definition.',
    };
  }
  if (effectiveScope === 'global' && scopes.has('bundled')) {
    return {
      scope: 'bundled',
      explanation: 'Global override of the bundled definition. The bundled original stays read-only.',
    };
  }
  return null;
}
